import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_editor.dart';
import 'package:ovid_ai/ui/studio_layout.dart';

/// Studio editor (2026-09-30 audit).
///
/// The code editor shipped with `autocorrect` and `enableSuggestions` left ON,
/// so the soft keyboard rewrote identifiers; `_bind` dumped the caret at end
/// of file on every fresh open *and* mutated the controller from inside
/// `build`; and there was no find, no line/column readout and no undo.
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

  Future<void> pumpEditor(
    WidgetTester tester, {
    double width = 700,
    double height = 500,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Scaffold(
          body: SizedBox(
            width: width,
            height: height,
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
    await tester.pumpAndSettle();
  }

  TextEditingController controller(WidgetTester tester) =>
      tester.widget<TextField>(find.byKey(studioEditorFieldKey)).controller!;

  /// `Tooltip` is a descendant of the button, so the button is found by
  /// walking up from the tooltip.
  Finder button(String tooltip) => find.ancestor(
        of: find.byTooltip(tooltip),
        matching: find.byType(StudioIconButton),
      );

  group('the editor is configured for code, not prose', () {
    testWidgets('failed local Save retains the draft and reports the error', (tester) async {
      final root = Directory.systemTemp.createTempSync('editor-refuse-');
      final outside = Directory.systemTemp.createTempSync('editor-outside-');
      addTearDown(() { root.deleteSync(recursive: true); outside.deleteSync(recursive: true); });
      final file = File('${outside.path}/a.txt')..writeAsStringSync('outside');
      Link('${root.path}/a.txt').createSync(file.path);
      AppState.I.setSessionWorkspaceFolder(root.path);
      AgentService.I.openStudioFile('a.txt', 'initial');
      await pumpEditor(tester);
      await tester.enterText(find.byKey(studioEditorFieldKey), 'draft');
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();
      expect(controller(tester).text, 'draft');
      expect(file.readAsStringSync(), 'outside');
      expect(tester.widget<StudioIconButton>(button('Save changes')).onPressed, isNotNull);
      expect(find.textContaining('Saved a.txt'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('local draft survives sync and Save writes the selected workspace', (tester) async {
      final root = Directory.systemTemp.createTempSync('editor-save-');
      addTearDown(() => root.deleteSync(recursive: true));
      final file = File('${root.path}/a.txt')..writeAsStringSync('disk');
      final app = AppState.I;
      app.setSessionWorkspaceFolder(root.path);
      RepoCache.I.bind('o/r', '', sessionId: app.activeSession!.id,
        workspaceFolder: root.path);
      AgentService.I.openStudioFile('a.txt', 'disk');
      await pumpEditor(tester);
      await tester.enterText(find.byKey(studioEditorFieldKey), 'draft');
      await tester.runAsync(() => RepoCache.I.sync());
      await tester.pump();
      expect(controller(tester).text, 'draft');
      expect(file.readAsStringSync(), 'disk');
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pumpAndSettle();
      expect(file.readAsStringSync(), 'draft');
      expect(RepoCache.I.read('a.txt'), 'draft');
    });

    testWidgets('autocorrect and suggestions are off', (tester) async {
      AgentService.I.openStudioFile('lib/a.dart', 'void main() {}');
      await pumpEditor(tester);

      final field = tester.widget<TextField>(find.byKey(studioEditorFieldKey));
      expect(field.autocorrect, isFalse,
          reason: 'the soft keyboard must not rewrite identifiers');
      expect(field.enableSuggestions, isFalse);
      expect(field.enableInteractiveSelection, isTrue,
          reason: 'selection is how you copy code — keep it');
    });

    testWidgets('smart quotes and smart dashes cannot mangle source',
        (tester) async {
      AgentService.I.openStudioFile('lib/a.dart', 'void main() {}');
      await pumpEditor(tester);

      final field = tester.widget<TextField>(find.byKey(studioEditorFieldKey));
      expect(field.smartQuotesType, SmartQuotesType.disabled);
      expect(field.smartDashesType, SmartDashesType.disabled);
    });

    testWidgets('monospace, multiline keyboard, newline action',
        (tester) async {
      AgentService.I.openStudioFile('lib/a.dart', 'void main() {}');
      await pumpEditor(tester);

      final field = tester.widget<TextField>(find.byKey(studioEditorFieldKey));
      expect(field.style?.fontFamily, Aether.mono);
      // `Aether.mono` names JetBrainsMono, which pubspec.yaml does not bundle,
      // so without a generic fallback the code field renders in the platform's
      // proportional face.
      expect(field.style?.fontFamilyFallback, isNotNull);
      expect(field.style!.fontFamilyFallback!, containsAll(kStudioMonoFallback));
      expect(field.keyboardType, TextInputType.multiline);
      expect(field.textInputAction, TextInputAction.newline);
      expect(field.maxLines, isNull, reason: 'expands: true needs maxLines null');
      expect(field.expands, isTrue);
      expect(
        (field.style?.fontSize ?? 0) >= kStudioMinFontSize,
        isTrue,
        reason: 'sub-11px mono is unreadable on a phone',
      );
    });
  });

  group('caret placement', () {
    testWidgets('a freshly opened file starts at the top, not at EOF',
        (tester) async {
      AgentService.I.openStudioFile('lib/a.dart', 'line one\nline two');
      await pumpEditor(tester);

      expect(controller(tester).selection.baseOffset, 0,
          reason: 'the caret used to be dumped at content.length');
      expect(controller(tester).selection.isCollapsed, isTrue);
    });

    testWidgets('switching tabs resets to the top of the new file',
        (tester) async {
      AgentService.I.openStudioFile('a.dart', 'aaaa\nbbbb');
      AgentService.I.openStudioFile('b.dart', 'cccc\ndddd');
      await pumpEditor(tester);

      AgentService.I.selectStudioFile('a.dart');
      await tester.pumpAndSettle();

      expect(controller(tester).selection.baseOffset, 0);
    });

    testWidgets('an external rewrite keeps the caret instead of moving it',
        (tester) async {
      AgentService.I.openStudioFile('lib/a.dart', 'line one\nline two');
      await pumpEditor(tester);

      final ctrl = controller(tester);
      ctrl.selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();

      // The agent writes the file behind the user's back.
      AgentService.I.openStudioFile('lib/a.dart', 'line ONE!\nline two');
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'the controller must not be mutated during build');
      expect(ctrl.text, 'line ONE!\nline two');
      expect(ctrl.selection.baseOffset, 3,
          reason: 'a caret the user placed must survive a background write');
    });

    testWidgets('a shorter external rewrite clamps the caret into range',
        (tester) async {
      AgentService.I.openStudioFile('lib/a.dart', 'a very long line of code');
      await pumpEditor(tester);

      final ctrl = controller(tester);
      ctrl.selection = const TextSelection.collapsed(offset: 20);
      await tester.pump();

      AgentService.I.openStudioFile('lib/a.dart', 'short');
      await tester.pumpAndSettle();

      expect(ctrl.selection.baseOffset, lessThanOrEqualTo(5));
      expect(ctrl.selection.isValid, isTrue);
    });
  });

  group('find in file', () {
    testWidgets('a changed query starts at its first result', (tester) async {
      AgentService.I.openStudioFile('a.dart', 'alpha beta alpha beta');
      await pumpEditor(tester);
      await tester.tap(find.byTooltip('Find in file'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(studioFindFieldKey), 'alpha');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(studioFindFieldKey), 'beta');
      await tester.pumpAndSettle();
      expect(find.text('1 / 2'), findsOneWidget);
      expect(controller(tester).selection,
          const TextSelection(baseOffset: 6, extentOffset: 10));
    });

    testWidgets('moving the query caret does not reset match navigation', (tester) async {
      AgentService.I.openStudioFile('a.dart', 'foo foo');
      await pumpEditor(tester);
      await tester.tap(find.byTooltip('Find in file'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(studioFindFieldKey), 'foo');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      final query = tester.widget<TextField>(find.byKey(studioFindFieldKey)).controller!;
      query.selection = const TextSelection.collapsed(offset: 0);
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      expect(controller(tester).selection,
          const TextSelection(baseOffset: 4, extentOffset: 7));
    });

    testWidgets('Unicode case folding preserves original source offsets',
        (tester) async {
      AgentService.I.openStudioFile('a.dart', 'İ foo FOO');
      await pumpEditor(tester);
      await tester.tap(find.byTooltip('Find in file'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(studioFindFieldKey), 'foo');
      await tester.pumpAndSettle();
      expect(controller(tester).selection,
          const TextSelection(baseOffset: 2, extentOffset: 5));
      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      expect(controller(tester).selection,
          const TextSelection(baseOffset: 6, extentOffset: 9));
      expect(tester.takeException(), isNull);
    });

    testWidgets('opens, counts matches and moves the selection',
        (tester) async {
      AgentService.I.openStudioFile('a.dart', 'line1\nline2\nline3');
      await pumpEditor(tester);

      expect(find.byKey(studioFindFieldKey), findsNothing);
      await tester.tap(find.byTooltip('Find in file'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(studioFindFieldKey), 'line');
      await tester.pumpAndSettle();

      expect(find.text('1 / 3'), findsOneWidget);
      expect(controller(tester).selection,
          const TextSelection(baseOffset: 0, extentOffset: 4));

      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      expect(find.text('2 / 3'), findsOneWidget);
      expect(controller(tester).selection,
          const TextSelection(baseOffset: 6, extentOffset: 10));

      await tester.tap(find.byTooltip('Previous match'));
      await tester.pumpAndSettle();
      expect(find.text('1 / 3'), findsOneWidget);
      expect(controller(tester).selection,
          const TextSelection(baseOffset: 0, extentOffset: 4));
    });

    testWidgets('wraps around the end of the file', (tester) async {
      AgentService.I.openStudioFile('a.dart', 'line1\nline2');
      await pumpEditor(tester);
      await tester.tap(find.byTooltip('Find in file'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(studioFindFieldKey), 'line');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();

      expect(find.text('1 / 2'), findsOneWidget, reason: 'next wraps to 1');
    });

    testWidgets('reports no matches and disables navigation', (tester) async {
      AgentService.I.openStudioFile('a.dart', 'line1\nline2');
      await pumpEditor(tester);
      await tester.tap(find.byTooltip('Find in file'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(studioFindFieldKey), 'zzz');
      await tester.pumpAndSettle();

      expect(find.text('No matches'), findsOneWidget);
      expect(tester.widget<StudioIconButton>(button('Next match')).onPressed,
          isNull);
    });

    testWidgets('closes and restores the caret', (tester) async {
      AgentService.I.openStudioFile('a.dart', 'line1\nline2');
      await pumpEditor(tester);
      await tester.tap(find.byTooltip('Find in file'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(studioFindFieldKey), 'line2');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Close find'));
      await tester.pumpAndSettle();

      expect(find.byKey(studioFindFieldKey), findsNothing);
      expect(controller(tester).selection.isCollapsed, isTrue);
    });
  });

  group('undo and the Ln/Col readout', () {
    testWidgets('undo is disabled until there is something to undo',
        (tester) async {
      AgentService.I.openStudioFile('a.dart', 'original');
      await pumpEditor(tester);
      // Let UndoHistory's throttled initial push land: the pristine document
      // is the undo floor, so there is nothing to undo yet.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Undo'), findsOneWidget);
      expect(tester.widget<StudioIconButton>(button('Undo')).onPressed, isNull);
    });

    testWidgets('undo reverts the last edit and redo replays it',
        (tester) async {
      AgentService.I.openStudioFile('a.dart', 'original');
      await pumpEditor(tester);
      // UndoHistory throttles stack pushes at 500ms and *replaces* a pending
      // push, so the pristine document must land before the first keystroke or
      // there is nothing to undo back to.
      await tester.pump(const Duration(milliseconds: 600));

      await tester.enterText(find.byKey(studioEditorFieldKey), 'edited');
      // UndoHistory debounces stack pushes.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(controller(tester).text, 'edited');
      await tester.tap(find.byTooltip('Undo'));
      await tester.pumpAndSettle();
      expect(controller(tester).text, 'original');

      await tester.tap(find.byTooltip('Redo'));
      await tester.pumpAndSettle();
      expect(controller(tester).text, 'edited');
    });

    testWidgets('the caret position is reported as Ln/Col', (tester) async {
      AgentService.I.openStudioFile('a.dart', 'one\ntwo\nthree');
      await pumpEditor(tester);

      expect(find.textContaining('Ln 1, Col 1'), findsOneWidget);

      controller(tester).selection = const TextSelection.collapsed(offset: 6);
      await tester.pumpAndSettle();

      expect(find.textContaining('Ln 2, Col 3'), findsOneWidget);
      expect(find.textContaining('3 lines'), findsOneWidget);
    });
  });

  group('editor chrome a11y', () {
    testWidgets('Save is a 44dp labelled target', (tester) async {
      AgentService.I.openStudioFile('a.dart', 'original');
      await pumpEditor(tester);
      // UndoHistory throttles stack pushes at 500ms and *replaces* a pending
      // push, so the pristine document must land before the first keystroke or
      // there is nothing to undo back to.
      await tester.pump(const Duration(milliseconds: 600));

      await tester.enterText(find.byKey(studioEditorFieldKey), 'edited');
      await tester.pumpAndSettle();

      final save = find.byTooltip('Save changes');
      expect(save, findsOneWidget);
      final size = tester.getSize(save);
      expect(size.width, greaterThanOrEqualTo(kStudioTapTarget));
      expect(size.height, greaterThanOrEqualTo(kStudioTapTarget));
    });

    testWidgets('tab close buttons are 44dp and labelled', (tester) async {
      AgentService.I.openStudioFile('lib/a.dart', 'a');
      AgentService.I.openStudioFile('lib/b.dart', 'b');
      await pumpEditor(tester);

      final close = find.byTooltip('Close tab a.dart');
      expect(close, findsOneWidget);
      final size = tester.getSize(close);
      expect(size.width, greaterThanOrEqualTo(kStudioTapTarget));
      expect(size.height, greaterThanOrEqualTo(kStudioTapTarget));

      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(AgentService.I.studioOpenFiles, isNot(contains('lib/a.dart')));
    });

    testWidgets('the tabs strip is at least 44dp tall', (tester) async {
      AgentService.I.openStudioFile('lib/a.dart', 'a');
      await pumpEditor(tester);
      final size = tester.getSize(find.byType(StudioEditorTabs));
      expect(size.height, greaterThanOrEqualTo(kStudioTapTarget));
    });

    testWidgets('the open file path is exposed to semantics', (tester) async {
      AgentService.I.openStudioFile('lib/a.dart', 'a');
      await pumpEditor(tester);
      final labels = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .map((s) => s.properties.label ?? '')
          .where((l) => l.contains('lib/a.dart'))
          .toList();
      expect(labels, isNotEmpty);
    });
  });
}
