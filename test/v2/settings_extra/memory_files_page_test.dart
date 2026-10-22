import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings_extra/memory_files_page.dart';

const _files = <V2MemoryFileEntry>[
  V2MemoryFileEntry(
    id: 'global-1',
    name: 'global.md',
    group: V2MemoryFileGroup.global,
    sizeLabel: '12 KB',
    updatedLabel: '2 hours ago',
    preview: 'Prefers short answers and code samples.',
    content: 'Prefers short answers and code samples.',
  ),
  V2MemoryFileEntry(
    id: 'project-1',
    name: 'ovid-app.md',
    group: V2MemoryFileGroup.project,
    sizeLabel: '48 KB',
    updatedLabel: 'Yesterday',
    preview: 'The app uses a violet accent and Inter type.',
    content: 'The app uses a violet accent and Inter type.',
  ),
  V2MemoryFileEntry(
    id: 'session-1',
    name: 'session-408.md',
    group: V2MemoryFileGroup.session,
    sizeLabel: '24 KB',
    updatedLabel: 'Just now',
    preview: 'Working on the settings screens for v2.',
    content: 'Working on the settings screens for v2.',
  ),
];

V2MemoryFilesPageData _data({
  V2MemoryFilesStatus status = V2MemoryFilesStatus.ready,
  List<V2MemoryFileEntry> files = _files,
  ValueChanged<String>? onOpen,
  V2MemoryFileSave? onSave,
  ValueChanged<String>? onDelete,
  VoidCallback? onExportAll,
  VoidCallback? onRetry,
}) {
  return V2MemoryFilesPageData(
    status: status,
    files: files,
    totalSizeLabel: '84 KB',
    onOpen: onOpen,
    onSave: onSave,
    onDelete: onDelete,
    onExportAll: onExportAll,
    onRetry: onRetry,
  );
}

/// Long values for the narrowest / largest-text probe.
const _longFiles = <V2MemoryFileEntry>[
  V2MemoryFileEntry(
    id: 'global-long',
    name: 'global-preferences-and-tone-notes.md',
    group: V2MemoryFileGroup.global,
    sizeLabel: '1.2 MB',
    updatedLabel: '2 hours ago',
    preview: 'Prefers short answers, code samples and a calm, plain tone.',
  ),
  V2MemoryFileEntry(
    id: 'project-long',
    name: 'ovid-si-rebuild-project-memory.md',
    group: V2MemoryFileGroup.project,
    sizeLabel: '948 KB',
    updatedLabel: 'Yesterday at 18:42',
    preview: 'The app uses a violet accent, Inter type and a dark-first look.',
  ),
  V2MemoryFileEntry(
    id: 'session-long',
    name: 'session-408-settings-screens.md',
    group: V2MemoryFileGroup.session,
    sizeLabel: '24 KB',
    updatedLabel: 'Just now',
    preview: 'Working on the settings screens for the second version.',
  ),
];

Future<void> _pump(
  WidgetTester tester,
  V2MemoryFilesPageData data, {
  bool dark = false,
  Size size = const Size(420, 1000),
  TextScaler? textScaler,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      home: Builder(
        builder: (context) => textScaler == null
            ? MemoryFilesPage(data: data)
            : MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                child: MemoryFilesPage(data: data),
              ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

void main() {
  testWidgets('one list, one filter, one delete per row', (tester) async {
    await _pump(
      tester,
      _data(onDelete: (_) {}, onExportAll: () {}),
    );

    expect(find.text('Memory files'), findsOneWidget);
    // One list, not three grouped sections.
    expect(find.text('global.md'), findsOneWidget);
    expect(find.text('ovid-app.md'), findsOneWidget);
    expect(find.text('session-408.md'), findsOneWidget);
    expect(find.text('GLOBAL FILES'), findsNothing);
    expect(find.text('PROJECT FILES'), findsNothing);
    expect(find.text('SESSION FILES'), findsNothing);

    // One scope filter.
    for (final key in ['all', 'global', 'project', 'session']) {
      expect(
        find.byKey(ValueKey<String>('memory-files-filter-$key')),
        findsOneWidget,
      );
    }

    // One delete per row, and export as the single bottom action.
    for (final id in ['global-1', 'project-1', 'session-1']) {
      expect(
        find.byKey(ValueKey<String>('memory-file-delete-$id')),
        findsOneWidget,
      );
    }
    expect(find.text('Export all'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('memory-files-export')),
      findsOneWidget,
    );

    // Explainer and total-size chrome are gone.
    expect(find.text('What Ovid remembers'), findsNothing);
    expect(find.text('Total 84 KB'), findsNothing);
    expect(find.textContaining('Exports every memory file'), findsNothing);
  });

  testWidgets('rows show scope, size and updated time', (tester) async {
    await _pump(tester, _data());

    expect(find.text('Global · 12 KB · Updated 2 hours ago'), findsOneWidget);
    expect(find.text('Project · 48 KB · Updated Yesterday'), findsOneWidget);
    expect(find.text('Session · 24 KB · Updated Just now'), findsOneWidget);
  });

  testWidgets('scope chips really filter the list', (tester) async {
    await _pump(tester, _data());

    await tester.tap(
      find.byKey(const ValueKey<String>('memory-files-filter-project')),
    );
    await tester.pumpAndSettle();
    expect(find.text('ovid-app.md'), findsOneWidget);
    expect(find.text('global.md'), findsNothing);
    expect(find.text('session-408.md'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('memory-files-filter-session')),
    );
    await tester.pumpAndSettle();
    expect(find.text('session-408.md'), findsOneWidget);
    expect(find.text('ovid-app.md'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('memory-files-filter-all')),
    );
    await tester.pumpAndSettle();
    expect(find.text('global.md'), findsOneWidget);
    expect(find.text('ovid-app.md'), findsOneWidget);
    expect(find.text('session-408.md'), findsOneWidget);
  });

  testWidgets('a filter with no files says so', (tester) async {
    await _pump(
      tester,
      _data(files: [_files.first]),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('memory-files-filter-session')),
    );
    await tester.pumpAndSettle();

    expect(find.text('No files in this scope'), findsOneWidget);
    expect(find.text('global.md'), findsNothing);
  });

  testWidgets('tapping a row opens it read-only without a save callback', (
    tester,
  ) async {
    String? opened;
    await _pump(tester, _data(onOpen: (id) => opened = id));

    await tester.tap(find.text('global.md'));
    await tester.pumpAndSettle();

    expect(opened, 'global-1');
  });

  testWidgets('the built-in viewer shows the file body', (tester) async {
    await _pump(tester, _data(onDelete: (_) {}));

    await tester.tap(find.text('global.md'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('memory-file-viewer-content')),
      findsOneWidget,
    );
    expect(find.text('Prefers short answers and code samples.'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey<String>('memory-file-viewer-close')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('memory-file-viewer-content')),
        findsNothing);
  });

  testWidgets('edits a file and saves the new content', (tester) async {
    final saved = <String, String>{};
    await _pump(tester, _data(onSave: (id, content) => saved[id] = content));

    await tester.tap(find.text('global.md'));
    await tester.pumpAndSettle();
    expect(find.text('Edit memory file'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('memory-file-editor-field')),
      'Prefers very short answers.',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(saved['global-1'], 'Prefers very short answers.');
  });

  testWidgets('deletes a file after confirmation', (tester) async {
    final deleted = <String>[];
    await _pump(tester, _data(onDelete: deleted.add));

    await tester.tap(
      find.byKey(const ValueKey<String>('memory-file-delete-project-1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Delete this memory file?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(deleted, ['project-1']);
  });

  testWidgets('the bottom action exports every file', (tester) async {
    var exported = 0;
    await _pump(tester, _data(onExportAll: () => exported++));

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('memory-files-export')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('memory-files-export')),
    );
    await tester.pump();

    expect(exported, 1);
  });

  testWidgets('renders the empty state and retries', (tester) async {
    var retried = 0;
    await _pump(
      tester,
      _data(
        status: V2MemoryFilesStatus.empty,
        files: const [],
        onRetry: () => retried++,
      ),
    );

    expect(find.text('No memory files yet'), findsOneWidget);
    await tester.tap(find.text('Refresh'));
    await tester.pump();

    expect(retried, 1);
  });

  testWidgets('renders the loading skeleton', (tester) async {
    await _pump(
      tester,
      _data(status: V2MemoryFilesStatus.loading, files: const []),
      settle: false,
    );

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('global.md'), findsNothing);
  });

  testWidgets('renders the error state and retries', (tester) async {
    var retried = 0;
    await _pump(
      tester,
      _data(
        status: V2MemoryFilesStatus.error,
        files: const [],
        onRetry: () => retried++,
      ),
    );

    expect(find.text('We could not load your memory files.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();

    expect(retried, 1);
  });

  testWidgets('a row without an open callback is not a button', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      _data(
        files: const [
          V2MemoryFileEntry(
            id: 'empty',
            name: 'empty.md',
            group: V2MemoryFileGroup.global,
            sizeLabel: '0 KB',
            updatedLabel: '',
            preview: '',
          ),
        ],
      ),
    );

    final semantics = tester.getSemantics(find.text('empty.md'));
    expect(semantics.getSemanticsData().flagsCollection.isButton, isNot(true));
    handle.dispose();
  });

  for (final dark in [false, true]) {
    testWidgets('fits 320 dp at 200% text (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      await _pump(
        tester,
        _data(files: _longFiles, onDelete: (_) {}, onSave: (_, _) {}),
        dark: dark,
        size: const Size(320, 640),
        textScaler: const TextScaler.linear(2),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Memory files'), findsOneWidget);
    });
  }
}
