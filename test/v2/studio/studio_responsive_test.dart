import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/studio/branch_picker_sheet.dart';
import 'package:ovid_ai/ui/v2/studio/changes_page.dart';
import 'package:ovid_ai/ui/v2/studio/repo_picker_page.dart';
import 'package:ovid_ai/ui/v2/studio/studio_workspace_page.dart';

/// The four Studio screens at every band, both text scales, both themes.
///
/// 320 is the phone floor, 600 the split-view threshold, 900 the wide band and
/// 1280 a desktop window. The only acceptable result at any cell is no
/// overflow and no clipped row.
Widget _app(Widget child, {required bool dark, required double textScale}) {
  return MaterialApp(
    theme: dark ? OTheme.dark() : OTheme.light(),
    builder: (context, content) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: content!,
    ),
    home: child,
  );
}

const _repos = <V2Repo>[
  V2Repo(
    id: '1',
    name: 'landing-page-with-a-very-long-repository-name',
    owner: 'acme',
    language: 'TypeScript',
    defaultBranch: 'main',
    branches: <V2RepoBranch>[
      V2RepoBranch(name: 'main', isDefault: true),
      V2RepoBranch(
        name: 'feature/hero-revamp-with-a-very-long-branch-name',
      ),
    ],
  ),
  V2Repo(id: '2', name: 'api-server', owner: 'acme'),
];

const _workspace = V2StudioWorkspaceData(
  repoName: 'acme/landing-page-with-a-very-long-repository-name',
  branch: 'feature/hero-revamp-with-a-very-long-branch-name',
  fileTree: <V2FileNode>[
    V2FileNode(
      name: 'src',
      children: <V2FileNode>[
        V2FileNode(
          name: 'components',
          children: <V2FileNode>[
            V2FileNode(
              name: 'VeryLongComponentNameThatKeepsGoing.tsx',
              path:
                  'src/components/VeryLongComponentNameThatKeepsGoing.tsx',
              changed: true,
            ),
          ],
        ),
      ],
    ),
    V2FileNode(name: 'README.md', path: 'README.md'),
  ],
  openFileName: 'VeryLongComponentNameThatKeepsGoing.tsx',
  openFilePath: 'src/components/VeryLongComponentNameThatKeepsGoing.tsx',
  codeLines: <V2CodeLine>[
    V2CodeLine(number: 1, text: "import React from 'react';"),
    V2CodeLine(
      number: 2,
      text:
          'export const VeryLongComponentNameThatKeepsGoing = () => null;',
    ),
  ],
  saved: false,
  syncCount: 12,
);

const _branches = V2BranchPickerData(
  current: V2Branch(
    name: 'feature/hero-revamp-with-a-very-long-branch-name',
    lastCommitLabel: '12m ago by Priya',
  ),
  branches: <V2Branch>[
    V2Branch(name: 'main', lastCommitLabel: '2h ago by Aarav'),
    V2Branch(name: 'develop', lastCommitLabel: 'Yesterday'),
    V2Branch(
      name: 'release/2026-10-22-with-a-very-long-name',
      lastCommitLabel: '3 days ago',
    ),
  ],
);

const _changes = V2ChangesData(
  files: <V2ChangedFile>[
    V2ChangedFile(
      path: 'VeryLongComponentNameThatKeepsGoing.tsx',
      directory: 'src/components',
      additions: 128,
      deletions: 96,
      initiallyExpanded: true,
      hunks: <V2DiffHunk>[
        V2DiffHunk(
          header: '@@ -1,2 +1,2 @@',
          lines: <V2DiffLine>[
            V2DiffLine(
              kind: V2DiffKind.removed,
              text: 'export const old = () => null;',
              oldNumber: 1,
            ),
            V2DiffLine(
              kind: V2DiffKind.added,
              text: 'export const current = () => null;',
              newNumber: 1,
            ),
          ],
        ),
      ],
    ),
    V2ChangedFile(path: 'README.md', additions: 2, deletions: 0),
  ],
  branchLabel: 'main ← feature/hero-revamp',
  behindCount: 3,
);

void main() {
  const widths = <double>[320, 600, 900, 1280];
  const scales = <double>[1, 2];
  const themes = <bool>[false, true];

  void setSurface(WidgetTester tester, double width) {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('repo picker fits every band, scale and theme', (tester) async {
    for (final width in widths) {
      setSurface(tester, width);
      for (final scale in scales) {
        for (final dark in themes) {
          await tester.pumpWidget(
            _app(
              V2RepoPickerPage(
                data: const V2RepoPickerData(repos: _repos),
                onConfirm: (_, _) {},
                onRetry: () {},
              ),
              dark: dark,
              textScale: scale,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'repo picker at $width dp / $scale x / dark=$dark',
          );

          // The branch step is the state with the primary action bar.
          await tester.tap(
            find.text('acme/landing-page-with-a-very-long-repository-name'),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'branch step at $width dp / $scale x / dark=$dark',
          );
        }
      }
    }
  });

  testWidgets('workspace fits every band, scale and theme', (tester) async {
    for (final width in widths) {
      setSurface(tester, width);
      for (final scale in scales) {
        for (final dark in themes) {
          await tester.pumpWidget(
            _app(
              V2StudioWorkspacePage(
                data: _workspace,
                onBranchTap: () {},
                onSync: () {},
                onSelectFile: (_) {},
                onPickRepo: () {},
                onRetry: () {},
                onCopyFile: () {},
              ),
              dark: dark,
              textScale: scale,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'workspace at $width dp / $scale x / dark=$dark',
          );
        }
      }
    }
  });

  testWidgets('branch picker fits every band, scale and theme', (tester) async {
    for (final width in widths) {
      setSurface(tester, width);
      for (final scale in scales) {
        for (final dark in themes) {
          await tester.pumpWidget(
            _app(
              Scaffold(
                body: V2BranchPickerSheet(
                  data: _branches,
                  onSelectBranch: (_) {},
                  onCreateBranch: () {},
                  onRetry: () {},
                ),
              ),
              dark: dark,
              textScale: scale,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'branch picker at $width dp / $scale x / dark=$dark',
          );
        }
      }
    }
  });

  testWidgets('changes fits every band, scale and theme', (tester) async {
    for (final width in widths) {
      setSurface(tester, width);
      for (final scale in scales) {
        for (final dark in themes) {
          await tester.pumpWidget(
            _app(
              V2ChangesPage(
                data: _changes,
                onCommit: (_) {},
                onBack: () {},
                onSync: () {},
                onCopyDiff: (_) {},
              ),
              dark: dark,
              textScale: scale,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'changes at $width dp / $scale x / dark=$dark',
          );
        }
      }
    }
  });
}
