import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/studio/code_viewer.dart';
import 'package:ovid_ai/ui/v2/studio/file_tree.dart';
import 'package:ovid_ai/ui/v2/studio/studio_workspace_page.dart';

Widget _app(Widget child, {bool dark = false, double textScale = 1}) =>
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: textScale == 1
          ? null
          : (context, content) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: content!,
            ),
      home: child,
    );

const _tree = <V2FileNode>[
  V2FileNode(
    name: 'src',
    children: <V2FileNode>[
      V2FileNode(
        name: 'components',
        children: <V2FileNode>[
          V2FileNode(name: 'Button.tsx', path: 'src/components/Button.tsx'),
          V2FileNode(
            name: 'Hero.tsx',
            path: 'src/components/Hero.tsx',
            changed: true,
          ),
        ],
      ),
    ],
  ),
  V2FileNode(name: 'index.html', path: 'index.html'),
];

const _lines = <V2CodeLine>[
  V2CodeLine(number: 1, text: "import React from 'react';"),
  V2CodeLine(number: 2, text: "import { Button } from './Button';"),
  V2CodeLine(number: 3, text: ''),
  V2CodeLine(number: 4, text: 'export const Hero = () => {'),
  V2CodeLine(number: 5, text: '  return <section>Hero</section>;'),
  V2CodeLine(number: 6, text: '};'),
];

const _data = V2StudioWorkspaceData(
  repoName: 'acme/landing-page',
  branch: 'main',
  filesChanged: 3,
  additions: 42,
  deletions: 12,
  syncCount: 3,
  fileTree: _tree,
  openFileName: 'Hero.tsx',
  openFilePath: 'src/components/Hero.tsx',
  codeLines: _lines,
);

void _setSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('renders the workspace in light and dark', (tester) async {
    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(
        _app(const V2StudioWorkspacePage(data: _data), dark: dark),
      );
      await tester.pumpAndSettle();

      expect(find.text('acme/landing-page'), findsOneWidget);
      expect(find.text('main'), findsOneWidget);
      expect(find.text('Hero.tsx'), findsWidgets);
      expect(find.text("import React from 'react';"), findsOneWidget);

      // No status bar: the workspace is the tree and the editor, nothing else.
      expect(find.byKey(const Key('studio-open-changes')), findsNothing);
      expect(find.byKey(const Key('studio-open-preview')), findsNothing);
      expect(find.text('3 changes'), findsNothing);
      expect(find.text('+42 −12'), findsNothing);
    }
  });

  testWidgets('the tree and branch chip announce their state', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(const V2StudioWorkspacePage(data: _data)));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Branch main'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'src/components/Hero.tsx, TypeScript file, modified',
      ),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey<String>('v2-file-tree-row-src')),
      ),
      isSemantics(hasExpandedState: true, isExpanded: true),
    );
    handle.dispose();
  });

  testWidgets('a pushed workspace header shows back, branch and sync', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const V2StudioWorkspacePage(data: _data),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    expect(find.text('acme/landing-page'), findsOneWidget);
    expect(find.byKey(const Key('studio-branch-chip')), findsOneWidget);
    expect(find.byKey(const Key('studio-sync')), findsOneWidget);
  });

  testWidgets('no git transport draws no sync control and no branch tap', (
    tester,
  ) async {
    var syncs = 0;
    var branchTaps = 0;
    await tester.pumpWidget(
      _app(
        V2StudioWorkspacePage(
          data: const V2StudioWorkspaceData(
            repoName: 'acme/landing-page',
            branch: 'main',
            gitAvailable: false,
          ),
          onSync: () => syncs++,
          onBranchTap: () => branchTaps++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The branch is still named (it is a fact), but nothing suggests the
    // deployment can act on it: no sync icon at all, and the chip is inert.
    expect(find.byKey(const Key('studio-branch-chip')), findsOneWidget);
    expect(find.byKey(const Key('studio-sync')), findsNothing);
    await tester.tap(find.byKey(const Key('studio-branch-chip')));
    await tester.pump();
    expect(branchTaps, 0);
    expect(syncs, 0);
  });

  testWidgets('empty state picks a repository', (tester) async {
    var picked = 0;
    await tester.pumpWidget(
      _app(
        V2StudioWorkspacePage(
          data: const V2StudioWorkspaceData(
            status: V2WorkspaceStatus.empty,
            repoName: '',
            branch: '',
          ),
          onPickRepo: () => picked++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No repository open'), findsOneWidget);
    await tester.tap(find.text('Pick a repository'));
    expect(picked, 1);
  });

  testWidgets('loading state shows a skeleton without the status bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const V2StudioWorkspacePage(
          data: V2StudioWorkspaceData(
            status: V2WorkspaceStatus.loading,
            repoName: '',
            branch: '',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Commit & push'), findsNothing);
    expect(find.byKey(const Key('studio-open-changes')), findsNothing);
  });

  testWidgets('error state retries', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        V2StudioWorkspacePage(
          data: const V2StudioWorkspaceData(
            status: V2WorkspaceStatus.error,
            repoName: '',
            branch: '',
          ),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('That did not work'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('there is no status bar, even with the callbacks wired', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        V2StudioWorkspacePage(data: _data, onCommit: () {}, onPreview: () {}),
      ),
    );
    await tester.pumpAndSettle();

    // Changes and preview are separate pushed pages; the workspace spends no
    // chrome on them.
    expect(find.byKey(const Key('studio-open-changes')), findsNothing);
    expect(find.byKey(const Key('studio-open-preview')), findsNothing);
    expect(find.text('Preview'), findsNothing);
    expect(find.text('3 changes'), findsNothing);
  });

  testWidgets('sync and file taps report their callbacks', (tester) async {
    var syncs = 0;
    String? selected;
    await tester.pumpWidget(
      _app(
        V2StudioWorkspacePage(
          data: _data,
          onSync: () => syncs++,
          onSelectFile: (path) => selected = path,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('studio-sync')));
    expect(syncs, 1);

    await tester.tap(find.text('index.html'));
    expect(selected, 'index.html');
  });

  testWidgets('the branch chip names the branch and opens the picker', (
    tester,
  ) async {
    var branchTaps = 0;
    await tester.pumpWidget(
      _app(V2StudioWorkspacePage(data: _data, onBranchTap: () => branchTaps++)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('studio-branch-chip')), findsOneWidget);
    expect(find.text('main'), findsOneWidget);
    await tester.tap(find.byKey(const Key('studio-branch-chip')));
    expect(branchTaps, 1);
  });

  testWidgets('the sync badge only appears when the remote is ahead', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const V2StudioWorkspacePage(data: _data)));
    await tester.pumpAndSettle();

    final synced = tester.widget<OIconButton>(
      find.byKey(const Key('studio-sync')),
    );
    expect(synced.badge, isNotNull);

    await tester.pumpWidget(
      _app(
        const V2StudioWorkspacePage(
          data: V2StudioWorkspaceData(
            repoName: 'acme/landing-page',
            branch: 'main',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final upToDate = tester.widget<OIconButton>(
      find.byKey(const Key('studio-sync')),
    );
    expect(upToDate.badge, isNull);
  });

  testWidgets('file tree collapses and expands folders', (tester) async {
    await tester.pumpWidget(_app(const V2StudioWorkspacePage(data: _data)));
    await tester.pumpAndSettle();

    expect(find.text('components'), findsOneWidget);

    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();
    expect(find.text('components'), findsNothing);

    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();
    expect(find.text('components'), findsOneWidget);
  });

  testWidgets('600 dp and 900 dp keep the tree beside the editor', (
    tester,
  ) async {
    const widths = <MapEntry<double, double>>[
      MapEntry(600, 280),
      MapEntry(900, 320),
    ];
    for (final entry in widths) {
      _setSurface(tester, Size(entry.key, 900));
      await tester.pumpWidget(_app(const V2StudioWorkspacePage(data: _data)));
      await tester.pumpAndSettle();

      final tree = tester.getSize(find.byKey(const Key('studio-tree-column')));
      expect(tree.width, entry.value, reason: '${entry.key} dp tree width');

      // The editor sits to the right of the fixed tree column; the code
      // viewer is not pushed on a split layout.
      final viewer = tester.getTopLeft(
        find.byKey(const Key('studio-open-code-viewer')),
      );
      expect(viewer.dx, greaterThan(tree.width));
      expect(find.text("import React from 'react';"), findsOneWidget);
      expect(find.byType(V2CodeViewerPage), findsNothing);
    }
  });

  testWidgets('599 dp keeps the tree full screen with no editor column', (
    tester,
  ) async {
    _setSurface(tester, const Size(599, 900));
    await tester.pumpWidget(_app(const V2StudioWorkspacePage(data: _data)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('studio-tree-column')), findsNothing);
    expect(find.byKey(const Key('studio-open-code-viewer')), findsNothing);
  });

  testWidgets('the split view survives 600 dp at 200 % text in both themes', (
    tester,
  ) async {
    const longData = V2StudioWorkspaceData(
      repoName: 'acme/landing-page-with-a-very-long-repository-name',
      branch: 'feature/hero-revamp-with-a-very-long-branch-name',
      openFileName: 'VeryLongComponentNameThatKeepsGoing.tsx',
      openFilePath: 'src/components/VeryLongComponentNameThatKeepsGoing.tsx',
      saved: false,
      fileTree: <V2FileNode>[
        V2FileNode(
          name: 'a-very-long-folder-name-that-keeps-going',
          children: <V2FileNode>[
            V2FileNode(
              name: 'a-very-long-file-name-that-keeps-going.tsx',
              path: 'src/components/VeryLongComponentNameThatKeepsGoing.tsx',
            ),
          ],
        ),
      ],
      codeLines: _lines,
    );

    for (final width in <double>[600, 900, 1280]) {
      _setSurface(tester, Size(width, 900));
      for (final dark in <bool>[false, true]) {
        await tester.pumpWidget(
          _app(
            const V2StudioWorkspacePage(data: longData),
            dark: dark,
            textScale: 2,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('studio-tree-column')), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason:
              'split view overflowed at $width dp / 200% text '
              '(${dark ? 'dark' : 'light'})',
        );
      }
    }
  });

  testWidgets('an open file with no lines says so instead of going blank', (
    tester,
  ) async {
    _setSurface(tester, const Size(900, 900));
    await tester.pumpWidget(
      _app(
        const V2StudioWorkspacePage(
          data: V2StudioWorkspaceData(
            repoName: 'acme/landing-page',
            branch: 'main',
            openFileName: 'empty.dart',
            openFilePath: 'lib/empty.dart',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Empty file'), findsOneWidget);
    expect(find.byKey(const Key('studio-open-code-viewer')), findsNothing);
  });

  testWidgets('below 600 dp the tree fills the screen and opens the viewer', (
    tester,
  ) async {
    _setSurface(tester, const Size(320, 720));
    await tester.pumpWidget(_app(const V2StudioWorkspacePage(data: _data)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('studio-tree-column')), findsNothing);
    expect(find.byKey(const Key('studio-open-code-viewer')), findsNothing);

    await tester.ensureVisible(
      find.byKey(
        const ValueKey<String>('v2-file-tree-row-src/components/Hero.tsx'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('v2-file-tree-row-src/components/Hero.tsx'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(V2CodeViewerPage), findsOneWidget);
    expect(find.text("import React from 'react';"), findsOneWidget);
  });

  testWidgets('fits a 320 dp screen at 200 % text with long labels', (
    tester,
  ) async {
    _setSurface(tester, const Size(320, 640));

    const longData = V2StudioWorkspaceData(
      repoName: 'acme/landing-page-with-a-very-long-repository-name',
      branch: 'feature/hero-revamp-with-a-very-long-branch-name',
      filesChanged: 128,
      additions: 10240,
      deletions: 9876,
      syncCount: 12,
      openFileName: 'VeryLongComponentNameThatKeepsGoing.tsx',
      openFilePath: 'src/components/VeryLongComponentNameThatKeepsGoing.tsx',
      saved: false,
      fileTree: <V2FileNode>[
        V2FileNode(
          name: 'a-very-long-folder-name-that-keeps-going',
          children: <V2FileNode>[
            V2FileNode(
              name: 'a-very-long-file-name-that-keeps-going.tsx',
              path: 'src/components/VeryLongComponentNameThatKeepsGoing.tsx',
            ),
          ],
        ),
      ],
      codeLines: _lines,
    );

    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(
        _app(
          const V2StudioWorkspacePage(data: longData),
          dark: dark,
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason:
            'long labels overflowed at 320 dp / 200% text '
            '(${dark ? 'dark' : 'light'})',
      );
    }
  });

  testWidgets('fits a 320 dp screen at 200 % text with no file open', (
    tester,
  ) async {
    _setSurface(tester, const Size(320, 640));

    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(
        _app(
          const V2StudioWorkspacePage(
            data: V2StudioWorkspaceData(
              repoName: 'acme/landing-page',
              branch: 'main',
              fileTree: _tree,
            ),
          ),
          dark: dark,
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('studio-file-tree')), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason:
            'no-file-open state overflowed at 320 dp / 200% text '
            '(${dark ? 'dark' : 'light'})',
      );
    }
  });

  testWidgets('the explorer is the shared file tree', (tester) async {
    await tester.pumpWidget(_app(const V2StudioWorkspacePage(data: _data)));
    await tester.pumpAndSettle();

    expect(find.byType(V2FileTree), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey<String>('v2-file-tree-row-src/components/Hero.tsx'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the explorer owns a lazy scroll, not a page-wide column', (
    tester,
  ) async {
    _setSurface(tester, const Size(900, 900));
    await tester.pumpWidget(_app(const V2StudioWorkspacePage(data: _data)));
    await tester.pumpAndSettle();

    // A real tree in a fixed pane: CustomScrollView + SliverList, so a large
    // repository builds only the visible rows.
    expect(find.byKey(const Key('v2-file-tree-scroll')), findsOneWidget);
    expect(
      tester
          .widget<V2FileTree>(find.byKey(const Key('studio-file-tree')))
          .scrollable,
      isTrue,
    );
  });

  testWidgets('a wide editor header opens the viewer and forwards copy', (
    tester,
  ) async {
    var copies = 0;
    await tester.pumpWidget(
      _app(V2StudioWorkspacePage(data: _data, onCopyFile: () => copies++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('studio-open-code-viewer')));
    await tester.pumpAndSettle();

    expect(find.byType(V2CodeViewerPage), findsOneWidget);
    await tester.tap(find.byKey(const Key('v2-code-viewer-copy')));
    expect(copies, 1);
  });

  testWidgets('unwired chrome renders no dead icons', (tester) async {
    await tester.pumpWidget(_app(const V2StudioWorkspacePage(data: _data)));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Workspace options'), findsNothing);
    expect(find.byKey(const Key('studio-copy-file')), findsNothing);
    expect(find.text('Cloud workspace connected'), findsNothing);
  });

  testWidgets(
    'an unbound workspace shows the studio gate instead of the editor',
    (tester) async {
      var picked = 0;
      await tester.pumpWidget(
        _app(
          V2StudioWorkspacePage(
            data: const V2StudioWorkspaceData(
              repoName: 'acme/landing-page',
              branch: '',
              fileTree: _tree,
              openFileName: 'Hero.tsx',
              openFilePath: 'src/components/Hero.tsx',
              codeLines: _lines,
            ),
            onPickRepo: () => picked++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('studio-gate')), findsOneWidget);
      expect(find.text('Pick a folder to start coding'), findsOneWidget);
      expect(find.text('No file open'), findsNothing);

      await tester.tap(find.text('Pick a folder'));
      expect(picked, 1);
    },
  );

  testWidgets('the studio gate fits 320 dp at 200 % text', (tester) async {
    _setSurface(tester, const Size(320, 640));

    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(
        _app(
          const V2StudioWorkspacePage(
            data: V2StudioWorkspaceData(
              repoName: 'acme/landing-page-with-a-very-long-repository-name',
              branch: '',
              fileTree: _tree,
            ),
          ),
          dark: dark,
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason:
            'studio gate overflowed at 320 dp / 200% text '
            '(${dark ? 'dark' : 'light'})',
      );
    }
  });

  testWidgets('a file selected by the host opens once its code arrives', (
    tester,
  ) async {
    _setSurface(tester, const Size(320, 720));
    await tester.pumpWidget(_app(const _WorkspaceHarness()));
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(
        const ValueKey<String>('v2-file-tree-row-src/components/Button.tsx'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('v2-file-tree-row-src/components/Button.tsx'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(V2CodeViewerPage), findsOneWidget);
    expect(find.text('Button.tsx'), findsWidgets);
    expect(find.text('export const Button = () => null;'), findsOneWidget);
  });
}

class _WorkspaceHarness extends StatefulWidget {
  const _WorkspaceHarness();

  @override
  State<_WorkspaceHarness> createState() => _WorkspaceHarnessState();
}

class _WorkspaceHarnessState extends State<_WorkspaceHarness> {
  V2StudioWorkspaceData _current = _data;

  @override
  Widget build(BuildContext context) {
    return V2StudioWorkspacePage(
      data: _current,
      onSelectFile: (path) {
        setState(() {
          _current = V2StudioWorkspaceData(
            repoName: _data.repoName,
            branch: _data.branch,
            fileTree: _data.fileTree,
            openFileName: 'Button.tsx',
            openFilePath: path,
            codeLines: const <V2CodeLine>[
              V2CodeLine(number: 1, text: 'export const Button = () => null;'),
            ],
          );
        });
      },
    );
  }
}
