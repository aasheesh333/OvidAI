import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/sidebar/project_detail_page.dart';

const _chat = V2ProjectChat(
  id: 'c1',
  title: 'Brand palette chat',
  modelLabel: 'Auto',
  timeLabel: '2h ago',
);

const _file = V2ProjectMemoryFile(
  id: 'm1',
  name: 'brand.md',
  sizeLabel: '12 KB',
  updatedLabel: 'Updated 2h ago',
  preview: 'Primary colour is violet.',
);

V2ProjectDetailData _contentData() => const V2ProjectDetailData(
  projectName: 'Mobile App Redesign',
  shared: true,
  chatCount: 3,
  chats: <V2ProjectChat>[_chat],
  memoryFiles: <V2ProjectMemoryFile>[_file],
  storageLabel: '340 MB of 3 GB',
  storageFraction: 0.11,
);

Widget _app(Widget child, {ThemeData? theme}) =>
    MaterialApp(theme: theme ?? OTheme.light(), home: child);

/// Phone-width surface at 200 % text, the accessibility stress case.
Widget _narrow(Widget child, {ThemeData? theme, double textScale = 2}) {
  return MaterialApp(
    theme: theme ?? OTheme.light(),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child,
      ),
    ),
  );
}

void _useNarrowScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('project detail renders chats, memory and storage in light', (
    tester,
  ) async {
    await tester.pumpWidget(_app(ProjectDetailPage(data: _contentData())));
    await tester.pumpAndSettle();

    expect(find.text('Project'), findsOneWidget);
    expect(find.text('Mobile App Redesign'), findsOneWidget);
    expect(find.text('Shared'), findsOneWidget);
    expect(find.text('3 chats · 1 memory file'), findsOneWidget);
    expect(find.text('Storage used'), findsOneWidget);
    expect(find.text('340 MB of 3 GB'), findsOneWidget);
    expect(find.text('CHATS'), findsOneWidget);
    expect(find.text('MEMORY'), findsOneWidget);
    expect(find.text('Brand palette chat'), findsOneWidget);
    expect(find.text('Auto · 2h ago'), findsOneWidget);
    expect(find.text('brand.md'), findsOneWidget);
    expect(find.text('12 KB · Updated 2h ago'), findsOneWidget);
    expect(find.byType(OProgressBar), findsOneWidget);
  });

  testWidgets('project detail renders in dark', (tester) async {
    await tester.pumpWidget(
      _app(ProjectDetailPage(data: _contentData()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mobile App Redesign'), findsOneWidget);
    expect(find.text('brand.md'), findsOneWidget);
    expect(find.text('Storage used'), findsOneWidget);
  });

  testWidgets('empty project offers Add memory and opens the editor', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        ProjectDetailPage(
          data: const V2ProjectDetailData(projectName: 'Empty project'),
          onSaveMemory: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(
      find.text('Start a chat in this project or add a memory file.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('v2-project-detail-empty-add')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('v2-memory-editor-name')), findsOneWidget);
    expect(find.byKey(const Key('v2-memory-editor-content')), findsOneWidget);
  });

  testWidgets('loading state shows skeletons', (tester) async {
    await tester.pumpWidget(
      _app(
        const ProjectDetailPage(
          data: V2ProjectDetailData(status: V2ProjectDetailStatus.loading),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  testWidgets('error state explains and retries', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _app(
        ProjectDetailPage(
          data: const V2ProjectDetailData(
            status: V2ProjectDetailStatus.error,
            errorMessage: 'Offline.',
          ),
          onRetry: () => retried++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Project did not load'), findsOneWidget);
    expect(find.text('Offline.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, 1);
  });

  testWidgets('tapping a chat reports it to the caller', (tester) async {
    V2ProjectChat? tapped;
    await tester.pumpWidget(
      _app(
        ProjectDetailPage(
          data: _contentData(),
          onChatTap: (chat) => tapped = chat,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Brand palette chat'));
    expect(tapped?.id, 'c1');
  });

  testWidgets('add memory collects a draft', (tester) async {
    final semantics = tester.ensureSemantics();
    V2ProjectMemoryDraft? saved;
    await tester.pumpWidget(
      _app(
        ProjectDetailPage(
          data: _contentData(),
          onSaveMemory: (draft) => saved = draft,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Add memory'));
    await tester.pumpAndSettle();

    // Save stays disabled until the file has a name and a body.
    expect(
      tester
          .widget<OButton>(find.byKey(const Key('v2-memory-editor-save')))
          .onPressed,
      isNull,
    );
    expect(saved, isNull);

    await tester.enterText(
      find.byKey(const Key('v2-memory-editor-name')),
      'Launch notes',
    );
    await tester.enterText(
      find.byKey(const Key('v2-memory-editor-content')),
      'Ship on the 12th.',
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('v2-memory-editor-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('v2-memory-editor-save')));
    await tester.pumpAndSettle();

    expect(saved?.id, isNull);
    // The shared editor normalises a bare name to a Markdown file.
    expect(saved?.name, 'Launch notes.md');
    expect(saved?.content, 'Ship on the 12th.');
    semantics.dispose();
  });

  testWidgets('editing a memory file prefills and keeps its id', (
    tester,
  ) async {
    V2ProjectMemoryDraft? saved;
    await tester.pumpWidget(
      _app(
        ProjectDetailPage(
          data: _contentData(),
          onSaveMemory: (draft) => saved = draft,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('brand.md'));
    await tester.pumpAndSettle();

    expect(find.text('Edit memory file'), findsOneWidget);
    expect(find.text('brand.md'), findsWidgets);
    expect(find.text('Primary colour is violet.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('v2-memory-editor-content')),
      'Primary colour is indigo.',
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('v2-memory-editor-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('v2-memory-editor-save')));
    await tester.pumpAndSettle();

    expect(saved?.id, 'm1');
    expect(saved?.name, 'brand.md');
    expect(saved?.content, 'Primary colour is indigo.');
  });

  testWidgets('deleting a memory file asks first', (tester) async {
    final semantics = tester.ensureSemantics();
    V2ProjectMemoryFile? deleted;
    await tester.pumpWidget(
      _app(
        ProjectDetailPage(
          data: _contentData(),
          onDeleteMemory: (file) => deleted = file,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Delete memory brand.md'));
    await tester.pumpAndSettle();

    expect(find.text('Delete memory?'), findsOneWidget);
    // Keeping the file leaves it alone.
    await tester.tap(find.text('Keep file'));
    await tester.pumpAndSettle();
    expect(deleted, isNull);

    await tester.tap(find.bySemanticsLabel('Delete memory brand.md'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('v2-delete-memory-confirm')));
    await tester.pumpAndSettle();

    expect(deleted?.id, 'm1');
    semantics.dispose();
  });

  testWidgets('the memory editor deletes the open file after confirmation', (
    tester,
  ) async {
    V2ProjectMemoryFile? deleted;
    await tester.pumpWidget(
      _app(
        ProjectDetailPage(
          data: _contentData(),
          onSaveMemory: (_) {},
          onDeleteMemory: (file) => deleted = file,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('brand.md'));
    await tester.pumpAndSettle();

    final delete = find.byKey(const Key('v2-memory-editor-delete'));
    await tester.ensureVisible(delete);
    await tester.pumpAndSettle();
    await tester.tap(delete);
    await tester.pumpAndSettle();

    expect(find.text('Delete memory file?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('v2-memory-editor-delete-confirm')));
    await tester.pumpAndSettle();

    expect(deleted?.id, 'm1');
    expect(deleted?.name, 'brand.md');
    expect(find.text('Edit memory file'), findsNothing);
  });

  testWidgets('the memory editor refuses a duplicate file name', (
    tester,
  ) async {
    const second = V2ProjectMemoryFile(
      id: 'm2',
      name: 'voice.md',
      sizeLabel: '4 KB',
      preview: 'Warm and direct.',
    );
    await tester.pumpWidget(
      _app(
        ProjectDetailPage(
          data: const V2ProjectDetailData(
            projectName: 'Mobile App Redesign',
            memoryFiles: <V2ProjectMemoryFile>[_file, second],
          ),
          onSaveMemory: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('brand.md'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('v2-memory-editor-name')),
      'voice.md',
    );
    await tester.pumpAndSettle();

    expect(
      find.text('This project already has a file with that name.'),
      findsOneWidget,
    );
    final save = tester.widget<OButton>(
      find.byKey(const Key('v2-memory-editor-save')),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('memory hint invites the first file', (tester) async {
    await tester.pumpWidget(
      _app(
        ProjectDetailPage(
          data: const V2ProjectDetailData(
            projectName: 'Mobile App Redesign',
            chatCount: 1,
            chats: <V2ProjectChat>[_chat],
            storageLabel: '12 MB of 3 GB',
          ),
          onSaveMemory: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No memory files yet'), findsOneWidget);
    expect(find.textContaining('No memory files'), findsWidgets);
    await tester.tap(find.text('Add memory'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('v2-memory-editor-name')), findsOneWidget);
  });

  testWidgets('content fits 320 dp at 200 % text in both themes', (
    tester,
  ) async {
    _useNarrowScreen(tester);

    for (final theme in <ThemeData>[OTheme.light(), OTheme.dark()]) {
      await tester.pumpWidget(
        _narrow(ProjectDetailPage(data: _contentData()), theme: theme),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.text('Mobile App Redesign', skipOffstage: false),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('brand.md', skipOffstage: false));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('empty and error fit 320 dp at 200 % text', (tester) async {
    _useNarrowScreen(tester);

    await tester.pumpWidget(
      _narrow(
        ProjectDetailPage(
          data: const V2ProjectDetailData(projectName: 'Empty project'),
          onSaveMemory: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Nothing here yet', skipOffstage: false), findsOneWidget);

    await tester.pumpWidget(
      _narrow(
        const ProjectDetailPage(
          data: V2ProjectDetailData(
            status: V2ProjectDetailStatus.error,
            errorMessage: 'Offline.',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Project did not load'), findsOneWidget);
  });

  testWidgets('memory add and delete only render when wired', (tester) async {
    await tester.pumpWidget(_app(ProjectDetailPage(data: _contentData())));
    await tester.pumpAndSettle();

    // No callbacks: the rows stay readable, but nothing offers a write.
    expect(find.text('brand.md'), findsOneWidget);
    expect(find.byIcon(Icons.add_rounded), findsNothing);
    expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);

    await tester.pumpWidget(
      _app(
        const ProjectDetailPage(
          data: V2ProjectDetailData(projectName: 'Empty project'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(find.text('Add memory'), findsNothing);
  });
}
