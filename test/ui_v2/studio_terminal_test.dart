import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/pty_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_layout.dart';
import 'package:ovid_ai/ui/studio_terminal_tabs.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// v2-12: premium terminal pane — scrollback search, renameable tabs,
/// per-tab command history, queued input while busy, ANSI-lite colours —
/// on top of the preserved persistent-shell behaviour (real host bash via
/// the spawner override, Stop ownership, follow-mode scroll).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppState.resetTestInstance();
    AppState.createForTest();
    studioPtySpawnerOverrideForTest = () => Process.start(
          _bash(),
          ['--norc'],
          workingDirectory: '/tmp',
        );
  });

  tearDown(() async {
    studioPtySpawnerOverrideForTest = null;
    await PtyPool.I.discardAllShells();
    AppState.resetTestInstance();
  });

  testWidgets('scrollback search filters lines and close restores them',
      (tester) async {
    await _pumpTerminal(tester);
    await _sendAndWaitIdle(tester, "printf '%s\\n' alpha beta gamma");
    await _waitFor(
      tester,
      () => _lines(tester).any((l) => l.trim() == 'gamma'),
      reason: 'printf output',
    );

    await tester.tap(find.byTooltip('Search terminal output'));
    await tester.pump();
    await tester.enterText(_filterField(), 'bet');
    await tester.pump();

    var lines = _lines(tester).toList();
    expect(lines.any((l) => l.trim() == 'beta'), isTrue,
        reason: 'matching line survives the filter');
    expect(lines.any((l) => l.trim() == 'alpha'), isFalse,
        reason: 'non-matching line filtered out');
    expect(lines.any((l) => l.trim() == 'gamma'), isFalse,
        reason: 'non-matching line filtered out');

    await tester.tap(find.byTooltip('Close search'));
    await tester.pump();
    lines = _lines(tester).toList();
    expect(lines.any((l) => l.trim() == 'alpha'), isTrue,
        reason: 'closing search restores the full scrollback');
    expect(lines.any((l) => l.trim() == 'gamma'), isTrue);
  });

  testWidgets('long-press on the tab strip renames the active tab',
      (tester) async {
    await _pumpTerminal(tester);
    expect(find.text('bash 1'), findsOneWidget);

    await tester.longPress(find.byType(AetherSegmentedControl<int>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(dialogField, findsOneWidget, reason: 'rename dialog opens');
    await tester.enterText(dialogField, 'deploy');
    await tester.tap(find.text('Rename'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('deploy'), findsOneWidget,
        reason: 'the tab pill shows the new name');
    expect(find.text('bash 1'), findsNothing);
  });

  testWidgets('up/down recalls command history per tab and restores the draft',
      (tester) async {
    await _pumpTerminal(tester);
    await _sendAndWaitIdle(tester, 'echo first-cmd');
    await _sendAndWaitIdle(tester, 'echo second-cmd');

    await tester.tap(_commandField());
    await tester.pump();

    Future<void> expectInput(String expected) async {
      expect(tester.widget<TextField>(_commandField()).controller!.text,
          expected);
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await expectInput('echo second-cmd');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await expectInput('echo first-cmd');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await expectInput('echo second-cmd');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await expectInput('');
  });

  testWidgets('input stays unlocked while busy and queued commands run after',
      (tester) async {
    await _pumpTerminal(tester);
    await _send(tester, 'sleep 2');
    await _waitFor(
      tester,
      () => find.byTooltip('Stop command').evaluate().isNotEmpty,
      reason: 'sleep to mark the tab busy',
    );

    final field = tester.widget<TextField>(_commandField());
    expect(field.enabled ?? true, isTrue,
        reason: 'the command field must not lock while a command runs');

    await _send(tester, 'echo queued-run');
    await _waitIdle(tester, reason: 'sleep 2 to finish and drain the queue');
    await _waitFor(
      tester,
      () => _lines(tester).any((l) => l.trim() == 'queued-run'),
      reason: 'queued command output',
    );
    expect(_lines(tester).any((l) => l.trim() == '\$ echo queued-run'), isTrue,
        reason: 'the queued command ran through the shell after the busy one');
  });

  testWidgets('a queued line is marked in the scrollback while busy',
      (tester) async {
    await _pumpTerminal(tester);
    await _send(tester, 'sleep 30');
    await _waitFor(
      tester,
      () => find.byTooltip('Stop command').evaluate().isNotEmpty,
      reason: 'sleep to mark the tab busy',
    );

    await _send(tester, 'echo marked');
    await tester.pump();
    expect(
      _lines(tester)
          .any((l) => l.startsWith('» queued:') && l.contains('echo marked')),
      isTrue,
      reason: 'input submitted while busy is echoed with a queued marker',
    );

    // Clean up the 30s sleep so the test stays fast. The queued command
    // then drains into the fresh shell Stop leaves behind.
    await tester.tap(find.byTooltip('Stop command'));
    await _waitIdle(tester, reason: 'stop to clear the busy state');
    await _waitFor(
      tester,
      () => _lines(tester).any((l) => l.trim() == 'marked'),
      reason: 'the queued command to drain and run after Stop',
    );
  });

  testWidgets('stop button cancels a running command and the tab recovers',
      (tester) async {
    await _pumpTerminal(tester);
    await _send(tester, 'sleep 30');
    await _waitFor(
      tester,
      () => find.byTooltip('Stop command').evaluate().isNotEmpty,
      reason: 'sleep to mark the tab busy',
    );

    await tester.tap(find.byTooltip('Stop command'));
    await _waitIdle(tester, reason: 'stop to clear the busy state');
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'the busy spinner stops with the command');

    await _sendAndWaitIdle(tester, 'echo after-stop');
    await _waitFor(
      tester,
      () => _lines(tester).any((l) => l.trim() == 'after-stop'),
      reason: 'a fresh shell answers after Stop',
    );
  });

  testWidgets('ANSI SGR sequences render coloured spans, escapes stripped',
      (tester) async {
    await _pumpTerminal(tester);
    await _sendAndWaitIdle(tester, r"printf '\033[31mhot-red\033[0m tail\n'");
    await _waitFor(
      tester,
      () => _lines(tester).any((l) => l.contains('hot-red')),
      reason: 'printf output',
    );

    final rich = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .where((w) => w.textSpan != null)
        .map((w) => w.textSpan!)
        .where((s) => s.toPlainText().contains('hot-red'))
        .toList();
    expect(rich, hasLength(1),
        reason: 'the SGR line renders through the rich (ANSI) path');
    final plain = rich.single.toPlainText();
    expect(plain, contains('tail'));
    expect(plain, isNot(contains('\x1B')),
        reason: 'escape sequences are stripped from the rendered text');

    Color? spanColor(String text) {
      for (final child in rich.single.children ?? const <InlineSpan>[]) {
        if (child is TextSpan && child.text == text) {
          return child.style?.color;
        }
      }
      return null;
    }

    expect(spanColor('hot-red'), Aether.danger,
        reason: 'SGR 31 maps to the danger token');
    expect(spanColor(' tail'), isNot(Aether.danger),
        reason: 'SGR 0 resets back to the base style');
  });

  testWidgets('clear scrollback and close-active-tab are preserved',
      (tester) async {
    await _pumpTerminal(tester);
    await _sendAndWaitIdle(tester, 'echo keep-me');
    await _waitFor(
      tester,
      () => _lines(tester).any((l) => l.trim() == 'keep-me'),
      reason: 'echo output',
    );

    await tester.tap(find.byTooltip('Clear terminal output'));
    await tester.pump();
    expect(_lines(tester).any((l) => l.contains('keep-me')), isFalse,
        reason: 'clear empties this terminal\'s scrollback');

    await tester.tap(find.byTooltip('New terminal'));
    await tester.pump();
    expect(find.text('bash 2'), findsOneWidget);
    await tester.tap(find.byTooltip('Close terminal 2'));
    await tester.pump();
    expect(find.text('bash 2'), findsNothing,
        reason: 'closing the active tab falls back to the remaining one');
    expect(find.byTooltip('Close terminal 1'), findsOneWidget);
  });

  testWidgets('compact 360x640 @2x layout has no overflow', (tester) async {
    await _pumpTerminal(
      tester,
      physicalSize: const Size(720, 1280),
      devicePixelRatio: 2.0,
    );
    final strip = tester.getSize(find.byKey(studioTerminalHandleKey));
    expect(strip.height, greaterThanOrEqualTo(kStudioTapTarget));
    expect(_commandField(), findsOneWidget);
    expect(find.byTooltip('New terminal'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('New terminal'));
    await tester.pump();
    expect(find.text('bash 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide layout keeps the header and has no overflow',
      (tester) async {
    await _pumpTerminal(
      tester,
      physicalSize: const Size(1440, 900),
      devicePixelRatio: 1.0,
    );
    expect(find.text('TERMINALS'), findsOneWidget);
    expect(find.text('bash 1'), findsOneWidget);
    expect(_commandField(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

String _bash() => File('/bin/bash').existsSync() ? '/bin/bash' : '/usr/bin/bash';

Finder _commandField() => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == r'bash $ …',
    );

Finder _filterField() => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'Filter scrollback…',
    );

Iterable<String> _lines(WidgetTester tester) => tester
    .widgetList<SelectableText>(find.byType(SelectableText))
    .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '');

Future<void> _pumpTerminal(
  WidgetTester tester, {
  Size physicalSize = const Size(720, 1280),
  double devicePixelRatio = 2.0,
}) async {
  tester.view.physicalSize = physicalSize;
  tester.view.devicePixelRatio = devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: Aether.theme(),
      home: const Scaffold(body: StudioTerminalTabs()),
    ),
  );
  await tester.pump();
}

/// Dispatches [cmd] to the active terminal without waiting for it to finish.
Future<void> _send(WidgetTester tester, String cmd) async {
  await tester.enterText(_commandField(), cmd);
  await tester.pump();
  // The submit (and the real Process I/O it triggers) must run on the real
  // event loop, not the widget-test fake async zone.
  await tester.runAsync(() async {
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pump();
}

Future<void> _sendAndWaitIdle(WidgetTester tester, String cmd) async {
  await _send(tester, cmd);
  await _waitIdle(tester, reason: '"$cmd" to finish');
}

Future<void> _waitIdle(
  WidgetTester tester, {
  String reason = 'the terminal to go idle',
}) =>
    _waitFor(
      tester,
      () => find.byTooltip('Stop command').evaluate().isEmpty,
      reason: reason,
    );

/// Bounded settle loop: real event-loop slices plus frame pumps, never an
/// unbounded pumpAndSettle.
Future<void> _waitFor(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 8),
  String reason = 'terminal',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $reason; lines=${_lines(tester).toList()}');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    // Elapse a fake millisecond as well: a queue drain dispatched from a
    // post-frame callback runs in the fake zone, and dart:io's Process
    // startup needs its zero-duration timer to fire before the spawned
    // shell accepts the command.
    await tester.pump(const Duration(milliseconds: 1));
  }
}
