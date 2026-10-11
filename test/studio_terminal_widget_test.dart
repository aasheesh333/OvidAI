import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/pty_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_terminal.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_screen.dart';

String _bash() =>
    File('/bin/bash').existsSync() ? '/bin/bash' : '/usr/bin/bash';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppState.resetTestInstance();
    AppState.createForTest();
  });

  tearDown(() async {
    studioPtySpawnerOverrideForTest = null;
    await PtyPool.I.discardAllShells();
    AppState.resetTestInstance();
  });

  testWidgets('terminal tab streams output and persists cd', (tester) async {
    final dir = Directory.systemTemp.createTempSync('ovid-widget-tab-');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    studioPtySpawnerOverrideForTest = () =>
        Process.start(_bash(), ['--norc'], workingDirectory: '/tmp');

    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(body: StudioTerminalTabs()),
      ),
    );
    await tester.pump();

    final input = find.byType(TextField).first;
    await _send(tester, input, 'cd ${dir.path}');
    await _send(tester, input, 'pwd');

    await _settle(
      tester,
      () => _terminalTexts(tester).any((s) => s.trim() == dir.path),
      debug: () => _terminalTexts(tester).toList().toString(),
    );

    expect(
      _terminalTexts(tester).any((s) => s.trim() == dir.path),
      isTrue,
      reason: 'pwd must show the cwd persisted from the previous command',
    );
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'busy clears when the command completes',
    );
  });

  testWidgets('Stop is tappable while a command runs and clears busy', (
    tester,
  ) async {
    studioPtySpawnerOverrideForTest = () =>
        Process.start(_bash(), ['--norc'], workingDirectory: '/tmp');
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(body: StudioTerminalTabs()),
      ),
    );
    await tester.pump();

    final input = find.byType(TextField).first;
    await tester.enterText(input, 'sleep 30');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await Future<void>.delayed(const Duration(milliseconds: 700));
    });
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(studioTerminalStopKey), findsOneWidget);
    expect(
      tester.widget<TextField>(input).enabled ?? true,
      isTrue,
      reason: 'the field stays enabled so stdin can be typed',
    );

    await tester.tap(find.byKey(studioTerminalStopKey));
    await tester.pump();
    await _settle(
      tester,
      () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      reason: 'Stop to end the command',
      debug: () => _terminalTexts(tester).toList().toString(),
    );
    expect(find.byKey(studioTerminalStopKey), findsNothing);
  });

  testWidgets('an unclosed quote is refused, not dispatched', (tester) async {
    studioPtySpawnerOverrideForTest = () =>
        Process.start(_bash(), ['--norc'], workingDirectory: '/tmp');
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(body: StudioTerminalTabs()),
      ),
    );
    await tester.pump();
    final input = find.byType(TextField).first;
    await tester.enterText(input, 'echo "foo');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect(
      _terminalTexts(tester).any((s) => s.contains('Unclosed quote')),
      isTrue,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(StudioShellSession.incompleteReason('echo "foo'), isNotNull);
  });
}

Iterable<String> _terminalTexts(WidgetTester tester) => tester
    .widgetList<SelectableText>(find.byType(SelectableText))
    .map((w) => w.data ?? '');

Future<void> _send(WidgetTester tester, Finder input, String cmd) async {
  await tester.enterText(input, cmd);
  await tester.pump();
  // Trigger the submit inside runAsync so the real Process I/O runs on the
  // real event loop rather than the widget-test fake async zone.
  await tester.runAsync(() async {
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await Future<void>.delayed(const Duration(milliseconds: 700));
  });
  await tester.pump();
  // Wait for the tab to leave the busy state before dispatching the next
  // command; `_run` drops commands while busy.
  await _settle(
    tester,
    () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
    reason: 'command "$cmd" to finish',
  );
}

Future<void> _settle(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 5),
  String Function()? debug,
  String reason = 'terminal',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out settling $reason${debug == null ? '' : ': ${debug()}'}');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}
