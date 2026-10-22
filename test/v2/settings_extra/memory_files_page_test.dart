import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/account_settings_client.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/projects.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings_extra/memory_files_page.dart';

const _files = <V2MemoryFileEntry>[
  V2MemoryFileEntry(
    id: 'global-1',
    name: 'global.md',
    group: V2MemoryFileGroup.global,
    sizeLabel: '12 KB',
    sizeBytes: 12288,
    preview: 'Prefers short answers and code samples.',
    content: 'Prefers short answers and code samples.',
    revision: 'r1',
  ),
  V2MemoryFileEntry(
    id: 'project-1',
    name: 'ovid-app.md',
    group: V2MemoryFileGroup.project,
    sizeLabel: '48 KB',
    sizeBytes: 49152,
    preview: 'The app uses a violet accent and Inter type.',
    content: 'The app uses a violet accent and Inter type.',
    revision: 'r1',
  ),
  V2MemoryFileEntry(
    id: 'session-1',
    name: 'session-408.md',
    group: V2MemoryFileGroup.session,
    sizeLabel: '24 KB',
    sizeBytes: 24576,
    preview: 'Working on the settings screens for v2.',
    content: 'Working on the settings screens for v2.',
    revision: 'r1',
  ),
];

V2MemoryFilesPageData _data({
  V2MemoryFilesStatus status = V2MemoryFilesStatus.ready,
  List<V2MemoryFileEntry> files = _files,
  ValueChanged<String>? onOpen,
  V2MemoryFileRead? onRead,
  V2MemoryFileSave? onSave,
  ValueChanged<String>? onDelete,
  V2MemoryFilesExport? onExport,
  VoidCallback? onExportAll,
  VoidCallback? onRetry,
}) {
  return V2MemoryFilesPageData(
    status: status,
    files: files,
    totalSizeLabel: '84 KB',
    onOpen: onOpen,
    onRead: onRead,
    onSave: onSave,
    onDelete: onDelete,
    onExport: onExport,
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
    sizeBytes: 1258291,
    preview: 'Prefers short answers, code samples and a calm, plain tone.',
    content: 'Prefers short answers, code samples and a calm, plain tone.',
  ),
  V2MemoryFileEntry(
    id: 'project-long',
    name: 'ovid-si-rebuild-project-memory.md',
    group: V2MemoryFileGroup.project,
    sizeLabel: '948 KB',
    sizeBytes: 970752,
    preview: 'The app uses a violet accent, Inter type and a dark-first look.',
    content: 'The app uses a violet accent, Inter type and a dark-first look.',
  ),
  V2MemoryFileEntry(
    id: 'session-long',
    name: 'session-408-settings-screens.md',
    group: V2MemoryFileGroup.session,
    sizeLabel: '24 KB',
    sizeBytes: 24576,
    preview: 'Working on the settings screens for the second version.',
    content: 'Working on the settings screens for the second version.',
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

Future<void> _pumpLive(
  WidgetTester tester,
  V2MemoryFilesSource source, {
  Size size = const Size(420, 1000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: OTheme.light(),
      home: MemoryFilesPage.live(source: source),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('list', () {
    testWidgets('shows only the real file names, with scope and size', (
      tester,
    ) async {
      await _pump(tester, _data());

      expect(find.text('Memory files'), findsOneWidget);
      expect(find.text('global.md'), findsOneWidget);
      expect(find.text('ovid-app.md'), findsOneWidget);
      expect(find.text('session-408.md'), findsOneWidget);
      // One meta line, exactly the facts the service returned.
      expect(find.text('Global · 12 KB'), findsOneWidget);
      expect(find.text('Project · 48 KB'), findsOneWidget);
      expect(find.text('Chat · 24 KB'), findsOneWidget);
      // No invented entrypoint, no second heading, no total chrome.
      expect(find.text('MEMORY.md'), findsNothing);
      expect(find.text('What Ovid remembers'), findsNothing);
      expect(find.text('Total 84 KB'), findsNothing);
      expect(find.textContaining('Updated'), findsNothing);
    });

    testWidgets('scope chips carry honest counts and really filter', (
      tester,
    ) async {
      await _pump(tester, _data());

      for (final (key, label) in [
        ('all', 'All 3'),
        ('global', 'Global 1'),
        ('project', 'Project 1'),
        ('chat', 'Chat 1'),
      ]) {
        expect(
          find.byKey(ValueKey<String>('memory-files-filter-$key')),
          findsOneWidget,
        );
        expect(find.text(label), findsOneWidget);
      }

      await tester.tap(
        find.byKey(const ValueKey<String>('memory-files-filter-project')),
      );
      await tester.pumpAndSettle();
      expect(find.text('ovid-app.md'), findsOneWidget);
      expect(find.text('global.md'), findsNothing);
      expect(find.text('session-408.md'), findsNothing);
      // Counts stay the true totals, not the visible subset.
      expect(find.text('All 3'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('memory-files-filter-chat')),
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

    testWidgets('a scope with no files still shows its honest zero', (
      tester,
    ) async {
      await _pump(tester, _data(files: [_files.first]));

      expect(find.text('Project 0'), findsOneWidget);
      expect(find.text('Chat 0'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('memory-files-filter-chat')),
      );
      await tester.pumpAndSettle();

      expect(find.text('No files in this scope'), findsOneWidget);
      expect(find.text('global.md'), findsNothing);
    });
  });

  group('viewer', () {
    testWidgets('reads the real body and stays read-only without a writer', (
      tester,
    ) async {
      await _pump(
        tester,
        _data(
          onRead: (file) async => const V2MemoryFileDocument(
            content: 'Real body from the service.',
            revision: 'r9',
          ),
        ),
      );

      await tester.tap(find.text('global.md'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('memory-file-viewer-content')),
        findsOneWidget,
      );
      expect(find.text('Real body from the service.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('memory-file-viewer-edit')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('memory-file-editor-field')),
        findsNothing,
      );
    });

    testWidgets('announces the file name as the viewer heading', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        _data(
          onRead: (file) async => V2MemoryFileDocument(
            content: 'Body of ${file.name}',
          ),
        ),
      );

      await tester.tap(find.text('global.md'));
      await tester.pumpAndSettle();

      final header = find.descendant(
        of: find.byType(OSheetHeader),
        matching: find.text('global.md'),
      );
      expect(header, findsOneWidget);
      expect(
        tester.getSemantics(header).flagsCollection.isHeader,
        isTrue,
      );
      handle.dispose();
    });

    testWidgets('shows a skeleton while the body loads', (tester) async {
      final body = Completer<V2MemoryFileDocument>();
      await _pump(
        tester,
        _data(onRead: (file) => body.future),
        settle: false,
      );

      await tester.tap(find.text('global.md'));
      await tester.pump();

      expect(
        find.byType(OSkeletonList),
        findsOneWidget,
      );

      body.complete(const V2MemoryFileDocument(content: 'Loaded body.'));
      await tester.pumpAndSettle();
      expect(find.text('Loaded body.'), findsOneWidget);
    });

    testWidgets('shows the read error and retries it', (tester) async {
      var attempts = 0;
      await _pump(
        tester,
        _data(
          onRead: (file) async {
            attempts++;
            if (attempts == 1) throw StateError('offline');
            return const V2MemoryFileDocument(content: 'Body on retry.');
          },
        ),
      );

      await tester.tap(find.text('global.md'));
      await tester.pumpAndSettle();
      expect(find.text('Could not open this file.'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Body on retry.'), findsOneWidget);
      expect(attempts, 2);
    });
  });

  group('editor', () {
    testWidgets('saves through the handler with the loaded revision', (
      tester,
    ) async {
      String? savedContent;
      String? savedRevision;
      await _pump(
        tester,
        _data(
          onRead: (file) async => const V2MemoryFileDocument(
            content: 'Old body.',
            revision: 'r1',
          ),
          onSave: (file, content, revision) async {
            savedContent = content;
            savedRevision = revision;
            return 'r2';
          },
        ),
      );

      await tester.tap(find.text('global.md'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('memory-file-viewer-edit')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Edit memory file'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey<String>('memory-file-editor-field')),
            )
            .controller!
            .text,
        'Old body.',
      );

      await tester.enterText(
        find.byKey(const ValueKey<String>('memory-file-editor-field')),
        'New body.',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('memory-file-editor-save')),
      );
      await tester.pumpAndSettle();

      expect(savedContent, 'New body.');
      expect(savedRevision, 'r1');
      expect(
        find.byKey(const ValueKey<String>('memory-file-editor-field')),
        findsNothing,
      );
      expect(find.text('Global · 9 B'), findsOneWidget);
    });

    testWidgets('shows saving, keeps the text and rolls back on failure', (
      tester,
    ) async {
      final save = Completer<String>();
      await _pump(
        tester,
        _data(
          onRead: (file) async => const V2MemoryFileDocument(
            content: 'Old body.',
            revision: 'r1',
          ),
          onSave: (file, content, revision) => save.future,
        ),
      );

      await tester.tap(find.text('global.md'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('memory-file-viewer-edit')),
      );
      await tester.pumpAndSettle();

      final long = 'x' * 2048;
      await tester.enterText(
        find.byKey(const ValueKey<String>('memory-file-editor-field')),
        long,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('memory-file-editor-save')),
      );
      await tester.pump();

      // Saving state, and the optimistic size behind the sheet.
      expect(find.text('Saving…'), findsOneWidget);
      expect(find.text('Global · 2.0 KB'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey<String>('memory-file-editor-field')),
            )
            .enabled,
        isFalse,
      );

      save.completeError(StateError('The server refused it.'));
      await tester.pumpAndSettle();

      // Rolled back, sheet still open, typed text preserved.
      expect(find.text('Global · 12 KB'), findsOneWidget);
      expect(find.text('Global · 2.0 KB'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('memory-file-editor-error')),
        findsOneWidget,
      );
      expect(find.text('The server refused it.'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey<String>('memory-file-editor-field')),
            )
            .controller!
            .text,
        long,
      );
    });
  });

  group('export', () {
    testWidgets('sends every file and reports the real outcome', (
      tester,
    ) async {
      List<V2MemoryFileEntry>? exported;
      await _pump(
        tester,
        _data(
          onExport: (files) async {
            exported = files;
            return const V2MemoryFilesExportOutcome(
              message: 'Exported 3 memory files.',
            );
          },
        ),
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('memory-files-export')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('memory-files-export')),
      );
      await tester.pumpAndSettle();

      expect(exported, isNotNull);
      expect(exported!.map((file) => file.name), [
        'global.md',
        'ovid-app.md',
        'session-408.md',
      ]);
      expect(find.text('Exported 3 memory files.'), findsOneWidget);
    });

    testWidgets('shows exporting, then the failure outcome', (tester) async {
      final export = Completer<V2MemoryFilesExportOutcome>();
      await _pump(
        tester,
        _data(onExport: (files) => export.future),
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('memory-files-export')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('memory-files-export')),
      );
      await tester.pump();

      expect(find.text('Exporting…'), findsOneWidget);

      export.completeError(StateError('no disk'));
      await tester.pumpAndSettle();

      expect(find.text('Export failed. Try again.'), findsOneWidget);
      expect(find.text('Export all'), findsOneWidget);
    });

    testWidgets('has no export control without an export path', (
      tester,
    ) async {
      await _pump(tester, _data());

      expect(
        find.byKey(const ValueKey<String>('memory-files-export')),
        findsNothing,
      );
      expect(find.text('Export all'), findsNothing);
    });

    testWidgets('a legacy void export is not shown as an archive action', (
      tester,
    ) async {
      await _pump(tester, _data(onExportAll: () {}));

      // A callback that cannot report whether an archive was produced is not
      // an export path the screen can stand behind.
      expect(
        find.byKey(const ValueKey<String>('memory-files-export')),
        findsNothing,
      );
    });
  });

  group('states', () {
    testWidgets('renders the loading skeleton', (tester) async {
      await _pump(
        tester,
        _data(status: V2MemoryFilesStatus.loading, files: const []),
        settle: false,
      );

      expect(find.byType(OSkeletonList), findsOneWidget);
      expect(find.text('global.md'), findsNothing);
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
  });

  group('delete', () {
    testWidgets('asks first and calls the handler with the file id', (
      tester,
    ) async {
      final deleted = <String>[];
      await _pump(tester, _data(onDelete: deleted.add));

      await tester.tap(
        find.byKey(const ValueKey<String>('memory-file-delete-project-1')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Delete file?'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('memory-file-delete-confirm')),
      );
      await tester.pumpAndSettle();

      expect(deleted, ['project-1']);
    });

    testWidgets('is absent when no delete path exists', (tester) async {
      await _pump(tester, _data());

      expect(
        find.byKey(const ValueKey<String>('memory-file-delete-global-1')),
        findsNothing,
      );
    });
  });

  group('semantics', () {
    testWidgets('rows announce name, scope and size; export is labelled', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, _data(onExport: (files) async {
        return const V2MemoryFilesExportOutcome(message: 'Exported.');
      }));

      expect(
        find.bySemanticsLabel('global.md, Global · 12 KB'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Export all memory files'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('a row with nothing to open is not a button', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        _data(
          files: const [
            V2MemoryFileEntry(
              id: 'empty',
              name: 'empty.md',
              group: V2MemoryFileGroup.global,
              sizeLabel: '0 B',
            ),
          ],
        ),
      );

      final semantics = tester.getSemantics(find.text('empty.md'));
      expect(semantics.getSemanticsData().flagsCollection.isButton, isNot(true));
      handle.dispose();
    });
  });

  group('layout', () {
    testWidgets('rows keep the 48 dp floor and the body caps at 640', (
      tester,
    ) async {
      await _pump(
        tester,
        _data(onDelete: (_) {}),
        size: const Size(1280, 1000),
      );

      final row = find.byKey(const ValueKey<String>('memory-file-global-1'));
      expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
      expect(tester.getRect(row).width, lessThanOrEqualTo(640));
    });

    for (final width in [320.0, 640.0, 1280.0]) {
      for (final scale in [1.0, 2.0]) {
        for (final dark in [false, true]) {
          testWidgets(
            'fits ${width.toInt()} dp at ${scale}x (${dark ? 'dark' : 'light'})',
            (tester) async {
              await _pump(
                tester,
                _data(
                  files: _longFiles,
                  onDelete: (_) {},
                  onRead: (file) async =>
                      V2MemoryFileDocument(content: file.content),
                  onSave: (file, content, revision) async => 'r2',
                  onExport: (files) async =>
                      const V2MemoryFilesExportOutcome(message: 'Exported.'),
                ),
                dark: dark,
                size: Size(width, 900),
                textScaler: TextScaler.linear(scale),
              );

              expect(tester.takeException(), isNull);
              expect(find.text('Memory files'), findsOneWidget);
            },
          );
        }
      }
    }

    testWidgets('viewer and editor fit 320 dp at 200% text', (tester) async {
      await _pump(
        tester,
        _data(
          files: _longFiles,
          onRead: (file) async =>
              V2MemoryFileDocument(content: file.content),
          onSave: (file, content, revision) async => 'r2',
        ),
        size: const Size(320, 640),
        textScaler: const TextScaler.linear(2),
      );

      await tester.tap(
        find.text('global-preferences-and-tone-notes.md'),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final edit = find.byKey(
        const ValueKey<String>('memory-file-viewer-edit'),
      );
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Edit memory file'), findsOneWidget);
    });
  });

  group('live screen', () {
    testWidgets('lists all three scopes from the source with counts', (
      tester,
    ) async {
      final source = _FakeSource(_files);
      await _pumpLive(tester, source);

      expect(find.text('global.md'), findsOneWidget);
      expect(find.text('ovid-app.md'), findsOneWidget);
      expect(find.text('session-408.md'), findsOneWidget);
      expect(find.text('All 3'), findsOneWidget);
      expect(find.text('Global 1'), findsOneWidget);
      expect(find.text('Project 1'), findsOneWidget);
      expect(find.text('Chat 1'), findsOneWidget);
    });

    testWidgets('opens, saves and exports through the source', (tester) async {
      final source = _FakeSource(_files);
      await _pumpLive(tester, source);

      await tester.tap(find.text('global.md'));
      await tester.pumpAndSettle();
      expect(find.text('Body of global.md'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('memory-file-viewer-edit')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('memory-file-editor-field')),
        'Saved through the service.',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('memory-file-editor-save')),
      );
      await tester.pumpAndSettle();

      expect(source.lastSaved, 'Saved through the service.');

      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('memory-files-export')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('memory-files-export')),
      );
      await tester.pumpAndSettle();

      expect(source.exported, hasLength(3));
      expect(find.text('Exported 3 memory files.'), findsOneWidget);
    });

    testWidgets('deletes through the source and reloads', (tester) async {
      final source = _FakeSource(_files);
      await _pumpLive(tester, source);

      await tester.tap(
        find.byKey(const ValueKey<String>('memory-file-delete-project-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('memory-file-delete-confirm')),
      );
      await tester.pumpAndSettle();

      expect(source.deleted, ['project-1']);
      expect(find.text('ovid-app.md'), findsNothing);
      expect(find.text('All 2'), findsOneWidget);
    });

    testWidgets('shows the source error and retries', (tester) async {
      final source = _FakeSource(_files)..failList = true;
      await _pumpLive(tester, source);

      expect(find.text('We could not load your memory files.'), findsOneWidget);

      source.failList = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.text('global.md'), findsOneWidget);
    });
  });

  group('service', () {
    test('lists the real global and project files with sizes', () async {
      final service = V2MemoryFilesService(
        client: _FakeSettingsClient(
          shared: true,
          files: {'MEMORY.md': '- Likes short answers.'},
        ),
        rest: _FakeRest(),
        projects: ProjectsController(rest: _FakeRest()),
        sessionId: () async => 's1',
      );

      final files = await service.list();

      expect(files.map((file) => file.name), ['MEMORY.md', 'brand.md']);
      expect(files.first.group, V2MemoryFileGroup.global);
      expect(files.first.sizeBytes, 22);
      expect(files.first.sizeLabel, '22 B');
      expect(files.last.group, V2MemoryFileGroup.project);
      expect(files.last.sizeLabel, '2.0 KB');
      expect(files.last.projectId, 'p1');
    });

    test('a chat-scope listing keeps the chat scope', () async {
      final service = V2MemoryFilesService(
        client: _FakeSettingsClient(
          shared: false,
          files: {'MEMORY.md': '- One fact.'},
        ),
        rest: _FakeRest(withProjects: false),
        projects: ProjectsController(rest: _FakeRest(withProjects: false)),
        sessionId: () async => 's1',
      );

      final files = await service.list();

      expect(files, hasLength(1));
      expect(files.single.group, V2MemoryFileGroup.session);
      expect(files.single.id, 'chat:MEMORY.md');
    });

    test('reads, writes and deletes a project file on its own routes', () async {
      final rest = _FakeRest();
      final service = V2MemoryFilesService(
        client: _FakeSettingsClient(shared: false, files: const {}),
        rest: rest,
        projects: ProjectsController(rest: rest),
        sessionId: () async => 's1',
      );
      const project = V2MemoryFileEntry(
        id: 'project:p1:brand.md',
        name: 'brand.md',
        group: V2MemoryFileGroup.project,
        sizeLabel: '2.0 KB',
        projectId: 'p1',
        revision: 'pr1',
      );

      final doc = await service.read(project);
      expect(doc.content, 'Project body.');
      expect(doc.revision, 'pr1');

      final revision = await service.save(
        project,
        'New body.',
        revision: 'pr1',
      );
      expect(revision, 'pr2');
      expect(rest.lastPutPath, '/projects/p1/memory/brand.md');
      expect(rest.lastPutBody?['ifRevision'], 'pr1');

      await service.delete(project);
      expect(rest.deleted, ['/projects/p1/memory/brand.md']);
    });
  });
}

class _FakeSource implements V2MemoryFilesSource {
  _FakeSource(List<V2MemoryFileEntry> files) : files = [...files];

  List<V2MemoryFileEntry> files;
  bool failList = false;
  String? lastSaved;
  final List<String> deleted = <String>[];
  final List<V2MemoryFileEntry> exported = <V2MemoryFileEntry>[];

  @override
  Future<List<V2MemoryFileEntry>> list() async {
    if (failList) throw StateError('offline');
    return [...files];
  }

  @override
  Future<V2MemoryFileDocument> read(V2MemoryFileEntry file) async {
    return V2MemoryFileDocument(
      content: 'Body of ${file.name}',
      revision: file.revision,
    );
  }

  @override
  Future<String> save(
    V2MemoryFileEntry file,
    String content, {
    String revision = '',
  }) async {
    lastSaved = content;
    files = [
      for (final entry in files)
        entry.id == file.id
            ? entry.copyWith(
                content: content,
                sizeLabel: '${content.length} B',
              )
            : entry,
    ];
    return 'r2';
  }

  @override
  Future<void> delete(V2MemoryFileEntry file) async {
    deleted.add(file.id);
    files = files.where((entry) => entry.id != file.id).toList();
  }

  @override
  Future<V2MemoryFilesExportOutcome> export(
    List<V2MemoryFileEntry> files,
  ) async {
    exported
      ..clear()
      ..addAll(files);
    return V2MemoryFilesExportOutcome(
      message: 'Exported ${files.length} memory files.',
    );
  }
}

class _FakeSettingsClient extends AccountSettingsClient {
  _FakeSettingsClient({required this.shared, required this.files})
    : super(rest: CloudRestClient());

  bool shared;
  final Map<String, String> files;

  @override
  Future<MemoryListing> memoryFiles(String sessionId) async {
    return MemoryListing(
      [
        for (final entry in files.entries)
          MemoryFileSummary(name: entry.key, sizeBytes: entry.value.length),
      ],
      shared: shared,
    );
  }

  @override
  Future<MemoryFile> readMemory(String sessionId, String name) async {
    return MemoryFile(
      name: name,
      content: files[name] ?? '',
      revision: 'r1',
    );
  }

  @override
  Future<MemoryFile> writeMemory(
    String sessionId,
    String name,
    String content, {
    String? ifRevision,
  }) async {
    files[name] = content;
    return MemoryFile(name: name, content: content, revision: 'r2');
  }

  @override
  Future<void> deleteMemory(String sessionId, String name) async {
    files.remove(name);
  }
}

class _FakeRest extends CloudRestClient {
  _FakeRest({this.withProjects = true});

  final bool withProjects;
  String? lastPutPath;
  Map<String, Object?>? lastPutBody;
  final List<String> deleted = <String>[];

  @override
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    if (path == '/projects') {
      if (!withProjects) {
        return <String, dynamic>{
          'items': const <Object>[],
          'capabilities': const <String, Object>{'turnProjectRefs': true},
        };
      }
      return <String, dynamic>{
        'items': <Object>[
          <String, Object>{
            'id': 'p1',
            'name': 'Ovid',
            'createdAt': '2026-01-01T00:00:00.000Z',
            'updatedAt': '2026-01-01T00:00:00.000Z',
            'sessionCount': 0,
            'fileCount': 1,
            'fileCap': 80,
            'fileBytes': 2048,
            'fileBreakdown': <String, Object>{
              'memory': 1,
              'attachments': 0,
              'artifacts': 0,
            },
          },
        ],
        'capabilities': <String, Object>{'turnProjectRefs': true},
      };
    }
    if (path == '/projects/p1/memory') {
      return <String, dynamic>{
        'items': <Object>[
          <String, Object>{'name': 'brand.md', 'sizeBytes': 2048},
        ],
        'scope': 'project',
      };
    }
    if (path == '/projects/p1/memory/brand.md') {
      return <String, dynamic>{
        'name': 'brand.md',
        'content': 'Project body.',
        'revision': 'pr1',
      };
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> putJson(
    String path, {
    Object? body,
    Duration? timeout,
  }) async {
    lastPutPath = path;
    final map = body is Map ? body : null;
    lastPutBody = map?.cast<String, Object?>();
    return <String, dynamic>{
      'name': 'brand.md',
      'content': map?['content'],
      'revision': 'pr2',
    };
  }

  @override
  Future<void> delete(String path, {Object? body, Duration? timeout}) async {
    deleted.add(path);
  }
}
