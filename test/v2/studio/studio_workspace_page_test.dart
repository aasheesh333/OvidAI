import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
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

  testWidgets('sync banner and file taps report their callbacks', (
    tester,
  ) async {
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

    await tester.tap(find.text('Sync latest changes'));
    expect(syncs, 1);

    await tester.ensureVisible(find.text('index.html'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('index.html'));
    expect(selected, 'index.html');
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

    await tester.pumpWidget(
      _app(
        const V2StudioWorkspacePage(data: longData),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('fits a 320 dp screen at 200 % text with no file open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        const V2StudioWorkspacePage(
          data: V2StudioWorkspaceData(
            repoName: 'acme/landing-page',
            branch: 'main',
            fileTree: _tree,
          ),
        ),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No file open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
