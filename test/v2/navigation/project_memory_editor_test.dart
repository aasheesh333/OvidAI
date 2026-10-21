import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/sidebar/project_memory_editor.dart';

const _saveKey = Key('v2-memory-editor-save');
const _nameKey = Key('v2-memory-editor-name');
const _contentKey = Key('v2-memory-editor-content');

const _newFile = V2ProjectMemoryEditorData(projectName: 'Mobile App Redesign');

const _savedFile = V2ProjectMemoryEditorData(
  fileId: 'm1',
  name: 'brand-voice.md',
  content: 'Use sentence case for every heading.',
  projectName: 'Mobile App Redesign',
);

/// Pumps the sheet on its own, matching how the a11y ratchet mounts sheets.
Future<void> _pumpSheet(
  WidgetTester tester,
  V2ProjectMemoryEditorData data, {
  bool dark = false,
  double scale = 1,
  ValueChanged<V2ProjectMemoryFileDraft>? onSave,
  ValueChanged<String>? onDelete,
  VoidCallback? onRetry,
  Size size = const Size(400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: ProjectMemoryEditorSheet(
          data: data,
          onSave: onSave,
          onDelete: onDelete,
          onRetry: onRetry,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

OButton _saveButton(WidgetTester tester) =>
    tester.widget<OButton>(find.byKey(_saveKey));

void main() {
  testWidgets('new file shows the fields, cap and project-only note', (
    tester,
  ) async {
    await _pumpSheet(tester, _newFile);

    expect(find.text('New memory file'), findsOneWidget);
    expect(find.text('New file · Mobile App Redesign'), findsOneWidget);
    expect(find.text('File name'), findsOneWidget);
    expect(find.text('Content'), findsOneWidget);
    expect(
      find.text(
        'This memory is used only in this project. Chats in other projects '
        'cannot read it.',
      ),
      findsOneWidget,
    );
    expect(find.text('0 bytes of 8 KB used'), findsOneWidget);
    expect(
      find.text(
        'Memory files are capped at 8 KB so every chat in the project can read '
        'them.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('v2-memory-editor-delete')), findsNothing);
  });

  testWidgets('content field uses the monospace type style', (tester) async {
    await _pumpSheet(tester, _newFile);

    final field = tester.widget<TextField>(find.byKey(_contentKey));
    expect(field.style?.fontFamily, 'JetBrainsMono');
  });

  testWidgets('save stays disabled until the name and content are valid', (
    tester,
  ) async {
    V2ProjectMemoryFileDraft? saved;
    await _pumpSheet(tester, _newFile, onSave: (draft) => saved = draft);

    expect(_saveButton(tester).onPressed, isNull);
    expect(
      find.text('Add a file name to save.'),
      findsOneWidget,
      reason: 'the disabled reason is visible, not just implied',
    );

    await tester.enterText(find.byKey(_contentKey), 'Use sentence case.');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNull);

    await tester.enterText(find.byKey(_nameKey), 'brand-voice');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNotNull);
    expect(find.text('Saved as brand-voice.md'), findsOneWidget);

    await tester.ensureVisible(find.byKey(_saveKey));
    await tester.tap(find.byKey(_saveKey));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.isNew, isTrue);
    expect(saved!.name, 'brand-voice.md');
    expect(saved!.content, 'Use sentence case.');
  });

  testWidgets('duplicate names block the save', (tester) async {
    await _pumpSheet(
      tester,
      const V2ProjectMemoryEditorData(
        projectName: 'Mobile App Redesign',
        content: 'Rule one.',
        takenNames: ['Brand-Voice.md'],
      ),
      onSave: (_) {},
    );

    await tester.enterText(find.byKey(_nameKey), 'brand-voice');
    await tester.pump();

    expect(
      find.text('This project already has a file with that name.'),
      findsOneWidget,
    );
    expect(_saveButton(tester).onPressed, isNull);

    await tester.enterText(find.byKey(_nameKey), 'tone-of-voice');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNotNull);
  });

  testWidgets('a file over the cap explains how much to trim', (tester) async {
    await _pumpSheet(
      tester,
      const V2ProjectMemoryEditorData(projectName: 'Mobile App Redesign'),
    );

    await tester.enterText(find.byKey(_nameKey), 'brand-voice.md');
    await tester.enterText(find.byKey(_contentKey), 'a' * 9000);
    await tester.pump();

    expect(find.text('8.8 KB of 8 KB used'), findsOneWidget);
    expect(find.textContaining('808 bytes over the 8 KB cap'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNull);
  });

  testWidgets('editing prefills the saved file and offers delete', (
    tester,
  ) async {
    await _pumpSheet(tester, _savedFile, onDelete: (_) {}, onSave: (_) {});

    expect(find.text('Edit memory file'), findsOneWidget);
    expect(find.text('Saved in Mobile App Redesign'), findsOneWidget);
    final name = tester.widget<TextField>(find.byKey(_nameKey));
    final content = tester.widget<TextField>(find.byKey(_contentKey));
    expect(name.controller?.text, 'brand-voice.md');
    expect(content.controller?.text, 'Use sentence case for every heading.');
    expect(_saveButton(tester).onPressed, isNotNull);
    expect(find.byKey(const Key('v2-memory-editor-delete')), findsOneWidget);
  });

  testWidgets('delete asks first, then reports the file id', (tester) async {
    String? deleted;
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showProjectMemoryEditor(
                  context,
                  data: _savedFile,
                  onSave: (_) {},
                  onDelete: (id) => deleted = id,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('v2-memory-editor-sheet')), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const Key('v2-memory-editor-delete')),
    );
    await tester.tap(find.byKey(const Key('v2-memory-editor-delete')));
    await tester.pumpAndSettle();

    expect(find.text('Delete memory file?'), findsOneWidget);
    expect(
      find.textContaining(
        '"brand-voice.md" will be removed from Mobile App Redesign memory.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('v2-memory-editor-delete-cancel')));
    await tester.pumpAndSettle();
    expect(deleted, isNull);
    expect(find.byKey(const Key('v2-memory-editor-sheet')), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const Key('v2-memory-editor-delete')),
    );
    await tester.tap(find.byKey(const Key('v2-memory-editor-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('v2-memory-editor-delete-confirm')));
    await tester.pumpAndSettle();

    expect(deleted, 'm1');
    expect(find.byKey(const Key('v2-memory-editor-sheet')), findsNothing);
  });

  testWidgets('closing the sheet reports close without saving', (tester) async {
    var closes = 0;
    // Host the sheet so the close action has a route to pop.
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showProjectMemoryEditor(
                  context,
                  data: _newFile,
                  onClose: () => closes++,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    expect(closes, 1);
    expect(find.byKey(const Key('v2-memory-editor-sheet')), findsNothing);
  });

  testWidgets('save failure shows a retry without losing the text', (
    tester,
  ) async {
    var retries = 0;
    await _pumpSheet(
      tester,
      const V2ProjectMemoryEditorData(
        projectName: 'Mobile App Redesign',
        errorMessage: 'The file did not save. Check your connection.',
      ),
      onSave: (_) {},
      onRetry: () => retries++,
    );

    expect(
      find.text('The file did not save. Check your connection.'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Try again'));
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('disabled save announces its reason to screen readers', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pumpSheet(tester, _newFile, onSave: (_) {});

    expect(
      find.bySemanticsLabel(
        'Save memory file, unavailable. Add a file name to save.',
      ),
      findsOneWidget,
    );

    await tester.enterText(find.byKey(_nameKey), 'brand-voice.md');
    await tester.enterText(find.byKey(_contentKey), 'Rule one.');
    await tester.pump();

    expect(find.bySemanticsLabel('Save memory file'), findsWidgets);
    handle.dispose();
  });

  testWidgets('renders in dark mode', (tester) async {
    await _pumpSheet(tester, _savedFile, dark: true, onDelete: (_) {});

    await tester.ensureVisible(find.byKey(_saveKey));
    expect(find.text('Edit memory file'), findsOneWidget);
    expect(
      find.byKey(const Key('v2-memory-editor-scope-note')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('v2-memory-editor-size-note')), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets('survives 320 dp at 200% text (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        _savedFile,
        dark: dark,
        scale: 2,
        size: const Size(320, 640),
        onDelete: (_) {},
      );

      expect(
        tester.takeException(),
        isNull,
        reason: 'the editor overflows at 320 dp / 200% text',
      );
      expect(
        find.byKey(const Key('v2-memory-editor-scope-note')),
        findsOneWidget,
      );

      await tester.ensureVisible(find.byKey(_saveKey));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(_saveKey), findsOneWidget);
      expect(find.byKey(const Key('v2-memory-editor-delete')), findsOneWidget);
    });
  }

  testWidgets('long header, cap warning and error stack without overflow', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      V2ProjectMemoryEditorData(
        projectName: 'A very long project name that keeps going',
        errorMessage:
            'The file did not save because the cloud could not be reached.',
        content: 'a' * 9000,
      ),
      scale: 2,
      size: const Size(320, 640),
      onSave: (_) {},
      onDelete: (_) {},
    );

    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const Key('v2-memory-editor-error')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
