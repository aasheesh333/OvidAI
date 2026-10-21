import 'dart:ui' show Tristate;

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

void main() {
  testWidgets('renders the workspace in light and dark', (tester) async {
    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(
        _app(const V2StudioWorkspacePage(data: _data), dark: dark),
      );
      await tester.pumpAndSettle();

      expect(find.text('acme/landing-page'), findsOneWidget);
      expect(find.text('main'), findsOneWidget);
      expect(find.text('Bound to acme/landing-page @ main'), findsOneWidget);
      expect(find.text('Change branch'), findsOneWidget);
      expect(find.text('Remote has 3 new changes'), findsOneWidget);
      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('3 files changed'), findsOneWidget);
      expect(find.text('Hero.tsx'), findsWidgets);
    }
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

  testWidgets('loading state shows a skeleton without the commit dock', (
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
    expect(find.text('Commit'), findsNothing);
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

    expect(find.text('Something went wrong'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('Preview button reports the primary action', (tester) async {
    var previews = 0;
    await tester.pumpWidget(
      _app(V2StudioWorkspacePage(data: _data, onPreview: () => previews++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Preview'));
    expect(previews, 1);
  });

  testWidgets('sync chip and file taps report their callbacks', (tester) async {
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

    expect(find.byKey(const Key('studio-sync-chip')), findsOneWidget);
    await tester.tap(find.text('Sync latest changes'));
    expect(syncs, 1);

    await tester.ensureVisible(find.text('index.html'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('index.html'));
    expect(selected, 'index.html');
  });

  testWidgets('the binding chip names the repo and branch', (tester) async {
    await tester.pumpWidget(_app(const V2StudioWorkspacePage(data: _data)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('studio-binding-chip')), findsOneWidget);
    expect(find.text('Bound to acme/landing-page @ main'), findsOneWidget);
  });

  testWidgets('change branch reports and the sync chip hides when up to date', (
    tester,
  ) async {
    var branchTaps = 0;
    await tester.pumpWidget(
      _app(V2StudioWorkspacePage(data: _data, onBranchTap: () => branchTaps++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('studio-change-branch')));
    expect(branchTaps, 1);

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

    expect(find.byKey(const Key('studio-sync-chip')), findsNothing);
    expect(find.text('Sync latest changes'), findsNothing);
    expect(find.text('Bound to acme/landing-page @ main'), findsOneWidget);
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

  testWidgets('a missing commit callback is announced as disabled', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(_app(const V2StudioWorkspacePage(data: _data)));
    await tester.pumpAndSettle();

    final flags = tester.getSemantics(find.text('Commit')).flagsCollection;
    expect(flags.isEnabled, Tristate.isFalse);

    handle.dispose();
  });

  testWidgets('fits a 320 dp screen at 200 % text with long labels', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

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
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

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

      expect(find.text('No file open'), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason:
            'no-file-open state overflowed at 320 dp / 200% text '
            '(${dark ? 'dark' : 'light'})',
      );
    }
  });

  testWidgets('the explorer is the shared file tree with change badges', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const V2StudioWorkspacePage(data: _data)));
    await tester.pumpAndSettle();

    expect(find.byType(V2FileTree), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey<String>('v2-file-tree-row-src/components/Hero.tsx'),
      ),
      findsOneWidget,
    );
    // V2FileNode.changed maps to V2FileChange.modified.
    expect(find.text('M'), findsOneWidget);
  });

  testWidgets('tapping the open file opens the code viewer', (tester) async {
    String? selected;
    await tester.pumpWidget(
      _app(
        V2StudioWorkspacePage(
          data: _data,
          onSelectFile: (path) => selected = path,
        ),
      ),
    );
    await tester.pumpAndSettle();

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

    expect(selected, 'src/components/Hero.tsx');
    expect(find.byType(V2CodeViewerPage), findsOneWidget);
    expect(find.text('Read only'), findsOneWidget);
    expect(find.text("import React from 'react';"), findsOneWidget);
    expect(find.text('6 lines'), findsOneWidget);
  });

  testWidgets('a file selected by the host opens once its code arrives', (
    tester,
  ) async {
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

  testWidgets('the editor header opens the viewer and forwards copy', (
    tester,
  ) async {
    var copies = 0;
    await tester.pumpWidget(
      _app(V2StudioWorkspacePage(data: _data, onCopyFile: () => copies++)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const Key('studio-open-code-viewer')),
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
    expect(find.text('Cloud workspace connected'), findsOneWidget);
    expect(
      find.text('Edits save to your branch as you type.'),
      findsNothing,
    );
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
      expect(find.text('Cloud workspace connected'), findsNothing);

      await tester.ensureVisible(find.text('Pick a folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pick a folder'));
      expect(picked, 1);
    },
  );

  testWidgets('the studio gate fits 320 dp at 200 % text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

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
