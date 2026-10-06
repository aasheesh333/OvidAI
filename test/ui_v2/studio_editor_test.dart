import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_editor.dart';

/// Studio editor v2 (premium editor surface).
///
/// The code field grew a line-number gutter, syntax highlighting, indent
/// guides, a current-line band, Ctrl/Cmd+S save and Tab=2-space indent —
/// while per-file buffers, caret/scroll, undo, the conflict bar and the
/// save→RepoCache pending/dirty pipeline had to keep working untouched.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    RepoCache.I.unbind();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    for (final p in AgentService.I.studioOpenFiles.toList()) {
      AgentService.I.closeStudioFile(p);
    }
    AgentService.I.fileBuffer.clear();
    AgentService.I.activeFilePath = null;
  });

  tearDown(() {
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    RepoCache.I.unbind();
    AppState.resetTestInstance();
  });

  /// Pumps the editor. With [wrap] the editor is boxed (legacy harness); with
  /// [surface]/[dpr] the whole test surface is sized instead (device tests).
  Future<void> pumpEditor(
    WidgetTester tester, {
    Size wrap = const Size(700, 500),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Scaffold(
          body: SizedBox(
            width: wrap.width,
            height: wrap.height,
            child: const Column(
              children: [
                StudioEditorTabs(),
                Expanded(child: StudioEditor()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
  }

  Future<void> pumpOnSurface(
    WidgetTester tester, {
    required Size logical,
    double dpr = 1.0,
  }) async {
    tester.view.physicalSize = Size(logical.width * dpr, logical.height * dpr);
    tester.view.devicePixelRatio = dpr;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(
          body: Column(
            children: [
              StudioEditorTabs(),
              Expanded(child: StudioEditor()),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
  }

  TextEditingController controller(WidgetTester tester) =>
      tester.widget<TextField>(find.byKey(studioEditorFieldKey)).controller!;

  StudioGutterPainter gutterPainter(WidgetTester tester) =>
      tester.widget<CustomPaint>(find.byKey(studioEditorGutterKey)).painter!
          as StudioGutterPainter;

  StudioGuidesPainter guidesPainter(WidgetTester tester) =>
      tester.widget<CustomPaint>(find.byKey(studioEditorGuidesKey)).painter!
          as StudioGuidesPainter;

  ScrollableState editorScrollable(WidgetTester tester) =>
      tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(studioEditorFieldKey),
              matching: find.byType(Scrollable),
            )
            .first,
      );

  /// Sends Ctrl (or Cmd) + S through the real keyboard pipeline.
  Future<void> pressSave(WidgetTester tester, {bool meta = false}) async {
    final mod = meta ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(mod);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(mod);
  }

  Future<void> pressTab(WidgetTester tester, {bool shift = false}) async {
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }

  group('line-number gutter', () {
    testWidgets('renders with one number per line and tracks the caret line',
        (tester) async {
      AgentService.I.openStudioFile('lib/a.dart', 'one\ntwo\nthree');
      await pumpEditor(tester);

      expect(find.byKey(studioEditorGutterKey), findsOneWidget);
      expect(gutterPainter(tester).lineCount, 3);
      expect(gutterPainter(tester).caretLine, 1,
          reason: 'a fresh open parks the caret on line 1');

      controller(tester).selection = const TextSelection.collapsed(offset: 5);
      await tester.pump();
      expect(gutterPainter(tester).caretLine, 2,
          reason: 'the gutter highlights the line the caret sits on');
    });

    testWidgets('gutter width stays modest on a phone surface', (tester) async {
      AgentService.I.openStudioFile(
          'a.dart', List.generate(40, (i) => 'line $i').join('\n'));
      await pumpOnSurface(tester, logical: const Size(360, 640), dpr: 2.0);
      final width = tester.getSize(find.byKey(studioEditorGutterKey)).width;
      expect(width, greaterThan(20));
      expect(width, lessThan(120),
          reason: 'two digits of line numbers must not eat the code area');
      expect(tester.takeException(), isNull);
    });
  });

  group('syntax highlighting', () {
    test('tokenizes keywords, strings, comments and numbers', () {
      const code = 'void main() {\n  // greet\n  final s = "hi";\n  final n = 42;\n}';
      final tokens = tokenizeStudioCode(code, filePath: 'lib/a.dart');
      String textOf(StudioCodeToken t) =>
          tokens.where((s) => s.token == t).map((s) => s.text).join();
      expect(textOf(StudioCodeToken.keyword), contains('void'));
      expect(textOf(StudioCodeToken.keyword), contains('final'));
      expect(textOf(StudioCodeToken.comment), contains('// greet'));
      expect(textOf(StudioCodeToken.string), contains('"hi"'));
      expect(textOf(StudioCodeToken.number), contains('42'));
      // Nothing is lost: concatenating every token rebuilds the source.
      expect(tokens.map((s) => s.text).join(), code);
    });

    test('comment rules follow the file extension', () {
      final py = tokenizeStudioCode('# hi\nx = 1', filePath: 'a.py');
      expect(py.firstWhere((s) => s.text.startsWith('#')).token,
          StudioCodeToken.comment);
      final dart = tokenizeStudioCode('// hi\nint x = 1;', filePath: 'a.dart');
      expect(dart.firstWhere((s) => s.text.startsWith('//')).token,
          StudioCodeToken.comment);
      // A # outside a string is a symbol in Dart, not a comment.
      final symbol = tokenizeStudioCode('a # b', filePath: 'a.dart');
      expect(symbol.where((s) => s.token == StudioCodeToken.comment), isEmpty);
      // But a # inside a string is still string content everywhere.
      final str = tokenizeStudioCode("var s = '#x';", filePath: 'a.dart');
      expect(str.firstWhere((s) => s.text.contains('#x')).token,
          StudioCodeToken.string);
    });

    testWidgets('the rendered field paints highlighted spans', (tester) async {
      AgentService.I.openStudioFile(
          'lib/a.dart', 'void main() {\n  final n = 42; // answer\n}');
      await pumpEditor(tester);

      // This Flutter paints editables through RenderEditable (no RichText in
      // the widget tree), so read the exact span the render object paints.
      final render = tester
          .elementList(find.descendant(
            of: find.byKey(studioEditorFieldKey),
            matching: find.byWidgetPredicate((_) => true),
          ))
          .map((e) => e.renderObject)
          .whereType<RenderEditable>()
          .first;
      final root = render.text;
      expect(root, isA<TextSpan>());
      expect((root! as TextSpan).toPlainText(), contains('void main'));
      final leaves = <TextSpan>[];
      void walk(InlineSpan span) {
        if (span is TextSpan) {
          if (span.children != null) {
            span.children!.forEach(walk);
          } else if (span.text != null && span.text!.isNotEmpty) {
            leaves.add(span);
          }
        }
      }
      walk(root);
      TextSpan leaf(String text) =>
          leaves.firstWhere((s) => s.text == text, orElse: () => const TextSpan());
      expect(leaf('void').style?.color, Aether.accentC,
          reason: 'keywords take the accent');
      expect(leaf('42').style?.color, Aether.warnLight,
          reason: 'numbers take the warning hue');
      expect(leaf('// answer').style?.color, Aether.textFaint,
          reason: 'comments fade back');
    });
  });

  group('keyboard: save shortcut and tab indent', () {
    testWidgets(
        'Ctrl+S saves to disk and leaves the RepoCache pending with a dirty count',
        (tester) async {
      final root = Directory.systemTemp.createTempSync('editor-ctrl-s-');
      addTearDown(() => root.deleteSync(recursive: true));
      final file = File('${root.path}/a.txt')..writeAsStringSync('disk');
      AppState.I.setSessionWorkspaceFolder(root.path);
      RepoCache.I.bind('o/r', '',
          sessionId: AppState.I.activeSession!.id,
          workspaceFolder: root.path);
      AgentService.I.openStudioFile('a.txt', 'disk');
      await pumpEditor(tester);
      expect(RepoCache.I.dirtyCount, 0);

      await tester.enterText(find.byKey(studioEditorFieldKey), 'draft');
      await tester.pump();
      await pressSave(tester);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 10),
      );

      expect(file.readAsStringSync(), 'draft',
          reason: 'Ctrl+S must run the same save as the button');
      expect(RepoCache.I.read('a.txt'), 'draft');
      expect(RepoCache.I.hasPending, isTrue,
          reason: 'a saved file becomes a pending (uncommitted) edit');
      expect(RepoCache.I.dirtyCount, 1);
      expect(RepoCache.I.pendingPaths, contains('a.txt'));
      expect(find.textContaining('Saved a.txt'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Cmd+S saves too', (tester) async {
      final root = Directory.systemTemp.createTempSync('editor-cmd-s-');
      addTearDown(() => root.deleteSync(recursive: true));
      final file = File('${root.path}/a.txt')..writeAsStringSync('disk');
      AppState.I.setSessionWorkspaceFolder(root.path);
      RepoCache.I.bind('o/r', '',
          sessionId: AppState.I.activeSession!.id,
          workspaceFolder: root.path);
      AgentService.I.openStudioFile('a.txt', 'disk');
      await pumpEditor(tester);
      await tester.enterText(find.byKey(studioEditorFieldKey), 'draft');
      await tester.pump();
      await pressSave(tester, meta: true);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 10),
      );
      expect(file.readAsStringSync(), 'draft');
    });

    testWidgets('Tab inserts two spaces at the caret', (tester) async {
      AgentService.I.openStudioFile('a.dart', 'x = 1;');
      await pumpEditor(tester);
      await tester.tap(find.byKey(studioEditorFieldKey));
      await tester.pump();
      controller(tester).selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();

      await pressTab(tester);
      await tester.pump();

      expect(controller(tester).text, '  x = 1;',
          reason: 'Tab must indent by two spaces, not move focus');
      expect(controller(tester).selection.baseOffset, 2);
    });

    testWidgets('Tab indents every selected line, Shift+Tab outdents',
        (tester) async {
      AgentService.I.openStudioFile('a.dart', 'a\nb');
      await pumpEditor(tester);
      await tester.tap(find.byKey(studioEditorFieldKey));
      await tester.pump();
      controller(tester).selection =
          const TextSelection(baseOffset: 0, extentOffset: 3);
      await tester.pump();

      await pressTab(tester);
      await tester.pump();
      expect(controller(tester).text, '  a\n  b');
      expect(controller(tester).selection.baseOffset, 2);
      expect(controller(tester).selection.extentOffset, 7);

      await pressTab(tester, shift: true);
      await tester.pump();
      expect(controller(tester).text, 'a\nb');
      expect(controller(tester).selection.baseOffset, 0);
      expect(controller(tester).selection.extentOffset, 3);
    });
  });

  group('indent guides and the current-line band', () {
    testWidgets('guides render over indented code', (tester) async {
      AgentService.I.openStudioFile(
          'a.dart', 'void main() {\n  if (true) {\n    return;\n  }\n}');
      await pumpEditor(tester);
      expect(find.byKey(studioEditorGuidesKey), findsOneWidget);
      expect(guidesPainter(tester).indentLevels, [0, 1, 2, 1, 0],
          reason: 'guide depth follows each line\'s 2-space indentation');
    });

    test('the guides painter actually draws lines for indented lines', () {
      int bytesFor(List<int> levels) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        StudioGuidesPainter(
          indentLevels: levels,
          caretLine: 1,
          lineHeight: 20,
          charWidth: 8,
          leftPadding: 12,
          topPadding: 12,
          scrollOffset: () => 0,
          guideColor: const Color(0xFF3A3A40),
          currentLineColor: const Color(0x1F679EFE),
        ).paint(canvas, const Size(400, 600));
        final picture = recorder.endRecording();
        final bytes = picture.approximateBytesUsed;
        picture.dispose();
        return bytes;
      }

      expect(bytesFor(const [0, 2, 3]), greaterThan(bytesFor(const [0, 0, 0])),
          reason: 'indented lines must produce drawLine calls');
    });
  });

  group('caret and scroll survive tab switches', () {
    testWidgets('returning to a tab restores caret offset and scroll pixels',
        (tester) async {
      final many =
          List.generate(60, (i) => 'line ${i + 1} of the file body').join('\n');
      AgentService.I.openStudioFile('a.dart', many);
      AgentService.I.openStudioFile('b.dart', 'short');
      await pumpEditor(tester);
      AgentService.I.selectStudioFile('a.dart');
      await tester.pump();

      final ctrlA = controller(tester);
      ctrlA.selection = const TextSelection.collapsed(offset: 40);
      editorScrollable(tester).position.jumpTo(200);
      await tester.pump();
      expect(editorScrollable(tester).position.pixels, 200);

      AgentService.I.selectStudioFile('b.dart');
      await tester.pump();
      AgentService.I.selectStudioFile('a.dart');
      await tester.pump();

      expect(controller(tester).selection.baseOffset, 40,
          reason: 'the caret must come back with the tab');
      expect(editorScrollable(tester).position.pixels, 200,
          reason: 'the scroll offset must come back with the tab');
      expect(tester.takeException(), isNull);
    });
  });

  group('conflict bar', () {
    testWidgets('an external rewrite over a dirty draft still raises the bar',
        (tester) async {
      AgentService.I.openStudioFile('a.dart', 'original');
      await pumpEditor(tester);
      await tester.enterText(find.byKey(studioEditorFieldKey), 'my draft');
      await tester.pump();

      AgentService.I.openStudioFile('a.dart', 'external rewrite');
      await tester.pump();

      expect(
        find.text('This file changed externally. Your draft has been kept.'),
        findsOneWidget,
      );
      expect(controller(tester).text, 'my draft');

      await tester.tap(find.text('Keep draft'));
      await tester.pump();
      expect(find.byType(MaterialBanner), findsNothing);
      expect(controller(tester).text, 'my draft',
          reason: 'Keep draft preserves the buffer through the new chrome');
      expect(tester.takeException(), isNull);
    });
  });

  group('surfaces: 360x640 @2x and wide', () {
    testWidgets('phone surface renders gutter, field and chrome', (tester) async {
      AgentService.I.openStudioFile(
          'lib/a.dart', 'void main() {\n  final n = 42;\n}');
      await pumpOnSurface(tester, logical: const Size(360, 640), dpr: 2.0);

      expect(find.byKey(studioEditorGutterKey), findsOneWidget);
      expect(find.byKey(studioEditorFieldKey), findsOneWidget);
      expect(find.text('SAVED'), findsOneWidget,
          reason: 'the state pill survives the new editor body');
      final gutterRight =
          tester.getTopRight(find.byKey(studioEditorGutterKey)).dx;
      final fieldLeft = tester.getTopLeft(find.byKey(studioEditorFieldKey)).dx;
      expect(fieldLeft, greaterThanOrEqualTo(gutterRight),
          reason: 'the code area starts where the gutter ends');
      expect(tester.takeException(), isNull);
    });

    testWidgets('wide surface renders the readout next to the gutter',
        (tester) async {
      AgentService.I.openStudioFile('lib/a.dart', 'one\ntwo\nthree');
      await pumpOnSurface(tester, logical: const Size(1100, 700));

      expect(find.byKey(studioEditorGutterKey), findsOneWidget);
      expect(find.textContaining('Ln 1, Col 1'), findsOneWidget,
          reason: 'the roomy header keeps the Ln/Col readout');
      expect(tester.takeException(), isNull);
    });
  });
}
