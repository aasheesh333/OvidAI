import 'dart:ui' show Tristate;

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
  ),
  V2MemoryFileEntry(
    id: 'project-1',
    name: 'ovid-app.md',
    group: V2MemoryFileGroup.project,
    sizeLabel: '48 KB',
    updatedLabel: 'Yesterday',
    preview: 'The app uses a violet accent and Inter type.',
  ),
  V2MemoryFileEntry(
    id: 'session-1',
    name: 'session-408.md',
    group: V2MemoryFileGroup.session,
    sizeLabel: '24 KB',
    updatedLabel: 'Just now',
    preview: 'Working on the settings screens for v2.',
  ),
];

V2MemoryFilesPageData _data({
  V2MemoryFilesStatus status = V2MemoryFilesStatus.ready,
  List<V2MemoryFileEntry> files = _files,
  ValueChanged<String>? onOpen,
  ValueChanged<String>? onDelete,
  VoidCallback? onExportAll,
  VoidCallback? onRetry,
}) {
  return V2MemoryFilesPageData(
    status: status,
    files: files,
    totalSizeLabel: '84 KB',
    onOpen: onOpen,
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
    preview:
        'Prefers short answers, code samples and a calm, plain tone in every '
        'reply.',
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
  bool disableAnimations = false,
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
        builder: (context) => textScaler == null && !disableAnimations
            ? MemoryFilesPage(data: data)
            : MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: textScaler,
                  disableAnimations: disableAnimations,
                ),
                child: MemoryFilesPage(data: data),
              ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  testWidgets('renders grouped files and total size in light', (tester) async {
    await _pump(tester, _data());

    expect(find.text('Memory files'), findsOneWidget);
    expect(find.text('Total 84 KB'), findsOneWidget);
    expect(find.text('GLOBAL FILES'), findsOneWidget);
    expect(find.text('PROJECT FILES'), findsOneWidget);
    expect(find.text('SESSION FILES'), findsOneWidget);
    expect(find.text('global.md'), findsOneWidget);
  });

  testWidgets('renders in dark', (tester) async {
    await _pump(tester, _data(), dark: true);

    expect(find.text('session-408.md'), findsOneWidget);
    expect(find.text('Export all'), findsOneWidget);
  });

  testWidgets('opens a memory file', (tester) async {
    String? opened;
    await _pump(tester, _data(onOpen: (id) => opened = id));

    final file = find.text('global.md');
    await tester.ensureVisible(file);
    await tester.tap(file);
    await tester.pumpAndSettle();

    expect(opened, 'global-1');
  });

  testWidgets('deletes a file after confirmation', (tester) async {
    String? deleted;
    var opened = 0;
    await _pump(
      tester,
      _data(onOpen: (_) => opened++, onDelete: (id) => deleted = id),
    );

    final menu = find.byTooltip('File options for global.md');
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();

    // Opening the menu must not also open the row underneath it.
    expect(opened, 0);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(deleted, isNull);
    expect(find.text('Delete this memory file?'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(deleted, 'global-1');
  });

  testWidgets('exports all files', (tester) async {
    var exports = 0;
    await _pump(tester, _data(onExportAll: () => exports++));

    final button = find.text('Export all');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(exports, 1);
  });

  testWidgets('renders the empty state and retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      _data(
        status: V2MemoryFilesStatus.empty,
        files: const [],
        onRetry: () => retries++,
      ),
    );

    expect(find.text('No memory files yet'), findsOneWidget);
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    expect(retries, 1);
  });

  for (final dark in <bool>[false, true]) {
    testWidgets('fits 320 dp at 200% text (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      await _pump(
        tester,
        _data(files: _longFiles, onOpen: (_) {}, onExportAll: () {}),
        dark: dark,
        size: const Size(320, 640),
        textScaler: const TextScaler.linear(2),
      );

      expect(
        tester.takeException(),
        isNull,
        reason: 'content overflowed at 320 dp / 200 % text',
      );
    });
  }

  testWidgets('every state fits 320 dp at 200% text', (tester) async {
    final scenarios = <String, V2MemoryFilesPageData>{
      'loading': const V2MemoryFilesPageData(
        status: V2MemoryFilesStatus.loading,
      ),
      'empty': const V2MemoryFilesPageData(
        status: V2MemoryFilesStatus.empty,
        onRetry: _noop,
      ),
      'error': const V2MemoryFilesPageData(
        status: V2MemoryFilesStatus.error,
        errorMessage:
            'We could not load your memory files. Check your connection and '
            'try again.',
        onRetry: _noop,
      ),
      'ready but empty': const V2MemoryFilesPageData(),
    };

    for (final entry in scenarios.entries) {
      await _pump(
        tester,
        entry.value,
        size: const Size(320, 640),
        textScaler: const TextScaler.linear(2),
        settle: entry.key != 'loading',
      );
      expect(
        tester.takeException(),
        isNull,
        reason: '${entry.key} overflowed at 320 dp / 200 % text',
      );
    }
  });

  testWidgets('renders the loading skeleton', (tester) async {
    await _pump(
      tester,
      _data(status: V2MemoryFilesStatus.loading),
      settle: false,
    );

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('global.md'), findsNothing);
  });

  testWidgets('renders the error state and retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      _data(
        status: V2MemoryFilesStatus.error,
        files: const [],
        onRetry: () => retries++,
      ),
    );

    expect(find.text('We could not load your memory files.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(retries, 1);
  });

  testWidgets('reduced motion keeps every file', (tester) async {
    await _pump(
      tester,
      _data(),
      disableAnimations: true,
      size: const Size(320, 640),
      textScaler: const TextScaler.linear(2),
    );

    expect(find.text('global.md'), findsOneWidget);
    expect(find.text('ovid-app.md'), findsOneWidget);
    expect(find.text('session-408.md'), findsOneWidget);
    expect(find.text('Export all'), findsOneWidget);
  });

  testWidgets('the row reports a disabled state without an open callback', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _data());

    final semantics = tester.getSemantics(
      find.bySemanticsLabel(
        'global.md, 12 KB, updated 2 hours ago, '
        'Prefers short answers and code samples.',
      ),
    );

    expect(semantics.flagsCollection.isButton, isFalse);
    expect(semantics.flagsCollection.isEnabled, Tristate.isFalse);
    handle.dispose();
  });

  testWidgets('the row is one labelled, enabled button when it can open', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _data(onOpen: (_) {}));

    final semantics = tester.getSemantics(
      find.bySemanticsLabel(
        'global.md, 12 KB, updated 2 hours ago, '
        'Prefers short answers and code samples.',
      ),
    );

    expect(
      semantics.label,
      'global.md, 12 KB, updated 2 hours ago, '
      'Prefers short answers and code samples.',
      reason: 'the row label must not repeat the child text',
    );
    expect(semantics.flagsCollection.isButton, isTrue);
    expect(semantics.flagsCollection.isEnabled, Tristate.isTrue);
    expect(
      find.byTooltip('File options for global.md'),
      findsOneWidget,
      reason: 'each row menu needs its own label',
    );
    handle.dispose();
  });

  testWidgets('the delete dialog fits 320 dp at 200% text', (tester) async {
    await _pump(
      tester,
      _data(onDelete: (_) {}),
      size: const Size(320, 640),
      textScaler: const TextScaler.linear(2),
    );

    final menu = find.byTooltip('File options for global.md');
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete this memory file?'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

void _noop() {}
