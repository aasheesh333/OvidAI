import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/studio/file_tree.dart';

Widget _app(Widget child, {bool dark = false, bool disableAnimations = false}) {
  Widget host = Scaffold(body: SingleChildScrollView(child: child));
  if (disableAnimations) {
    host = MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: host,
    );
  }
  return MaterialApp(theme: dark ? OTheme.dark() : OTheme.light(), home: host);
}

const _treeNodes = <V2FileTreeEntry>[
  V2FileTreeEntry(
    name: 'lib',
    path: 'lib',
    isFolder: true,
    children: <V2FileTreeEntry>[
      V2FileTreeEntry(
        name: 'main.dart',
        path: 'lib/main.dart',
        change: V2FileChange.modified,
      ),
      V2FileTreeEntry(
        name: 'app.dart',
        path: 'lib/app.dart',
        change: V2FileChange.added,
      ),
      V2FileTreeEntry(
        name: 'widgets',
        path: 'lib/widgets',
        isFolder: true,
        children: <V2FileTreeEntry>[
          V2FileTreeEntry(name: 'button.dart', path: 'lib/widgets/button.dart'),
        ],
      ),
    ],
  ),
  V2FileTreeEntry(
    name: 'assets',
    path: 'assets',
    isFolder: true,
    children: <V2FileTreeEntry>[
      V2FileTreeEntry(
        name: 'hero_banner.png',
        path: 'assets/hero_banner.png',
        change: V2FileChange.removed,
      ),
    ],
  ),
  V2FileTreeEntry(name: 'README.md', path: 'README.md'),
];

final _tree = V2FileTreeData(
  expandedPaths: <String>{'lib', 'assets'},
  nodes: _treeNodes,
);

const _languages = V2FileTreeData(
  nodes: <V2FileTreeEntry>[
    V2FileTreeEntry(name: 'main.dart', path: 'main.dart'),
    V2FileTreeEntry(name: 'app.ts', path: 'app.ts'),
    V2FileTreeEntry(name: 'index.html', path: 'index.html'),
    V2FileTreeEntry(name: 'styles.css', path: 'styles.css'),
    V2FileTreeEntry(name: 'config.json', path: 'config.json'),
    V2FileTreeEntry(name: 'hero.png', path: 'hero.png'),
    V2FileTreeEntry(name: 'run.sh', path: 'run.sh'),
    V2FileTreeEntry(name: 'NOTES.md', path: 'NOTES.md'),
  ],
);

/// Deeply nested, long-named tree used for the 320 dp / 200 % stress case.
const _narrow = V2FileTreeData(
  selectedPath:
      'apps/mobile/lib/features/authentication/sign_in_with_phone_number_screen.dart',
  expandedPaths: <String>{
    'apps',
    'apps/mobile',
    'apps/mobile/lib',
    'apps/mobile/lib/features',
    'apps/mobile/lib/features/authentication',
  },
  nodes: <V2FileTreeEntry>[
    V2FileTreeEntry(
      name: 'apps',
      path: 'apps',
      isFolder: true,
      children: <V2FileTreeEntry>[
        V2FileTreeEntry(
          name: 'mobile',
          path: 'apps/mobile',
          isFolder: true,
          children: <V2FileTreeEntry>[
            V2FileTreeEntry(
              name: 'lib',
              path: 'apps/mobile/lib',
              isFolder: true,
              children: <V2FileTreeEntry>[
                V2FileTreeEntry(
                  name: 'features',
                  path: 'apps/mobile/lib/features',
                  isFolder: true,
                  children: <V2FileTreeEntry>[
                    V2FileTreeEntry(
                      name: 'authentication',
                      path: 'apps/mobile/lib/features/authentication',
                      isFolder: true,
                      children: <V2FileTreeEntry>[
                        V2FileTreeEntry(
                          name: 'sign_in_with_phone_number_screen.dart',
                          path:
                              'apps/mobile/lib/features/authentication/sign_in_with_phone_number_screen.dart',
                          change: V2FileChange.modified,
                        ),
                        V2FileTreeEntry(
                          name: 'verify_one_time_passcode_screen.dart',
                          path:
                              'apps/mobile/lib/features/authentication/verify_one_time_passcode_screen.dart',
                          change: V2FileChange.added,
                        ),
                        V2FileTreeEntry(
                          name: 'resend_passcode_button.dart',
                          path:
                              'apps/mobile/lib/features/authentication/resend_passcode_button.dart',
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    ),
  ],
);

Finder _row(String id) => find.byKey(ValueKey<String>('v2-file-tree-row-$id'));

void main() {
  testWidgets('renders the tree in light and dark with language icons', (
    tester,
  ) async {
    expect(_tree.fileCount, 5);
    expect(_tree.changedFileCount, 3);
    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(_app(V2FileTree(data: _tree), dark: dark));
      await tester.pumpAndSettle();

      expect(find.text('main.dart'), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('hero_banner.png'), findsOneWidget);
      expect(find.byIcon(Icons.flutter_dash), findsNWidgets(2));
      expect(find.byIcon(Icons.description_outlined), findsNothing);
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
      expect(find.byIcon(Icons.article_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('changes render as letter badges and folders aggregate them', (
    tester,
  ) async {
    await tester.pumpWidget(_app(V2FileTree(data: _tree)));
    await tester.pumpAndSettle();

    expect(find.text('M'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('D'), findsOneWidget);
    // lib contains main.dart + app.dart; assets contains the removed image.
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);

    expect(
      tester.getSemantics(_row('lib/main.dart')),
      isSemantics(label: 'main.dart, Dart file, modified', isButton: false),
    );
    expect(
      tester.getSemantics(_row('lib')),
      isSemantics(
        label: 'Folder lib, 3 files, 2 changed',
        isButton: true,
        hasExpandedState: true,
        isExpanded: true,
      ),
    );
    expect(
      tester.getSemantics(_row('assets')),
      isSemantics(
        label: 'Folder assets, 1 file, 1 changed',
        hasExpandedState: true,
        isExpanded: true,
      ),
    );
  });

  testWidgets('folders expand and collapse from the row, not a keyboard', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const V2FileTree(
          data: V2FileTreeData(
            expandedPaths: <String>{'lib'},
            nodes: _treeNodes,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('button.dart'), findsNothing);

    await tester.tap(_row('lib'));
    await tester.pumpAndSettle();

    expect(find.text('main.dart'), findsNothing);
    expect(
      tester.getSemantics(_row('lib')),
      isSemantics(hasExpandedState: true, isExpanded: false),
    );

    await tester.tap(_row('lib'));
    await tester.pumpAndSettle();

    expect(find.text('main.dart'), findsOneWidget);
    expect(
      tester.getSemantics(_row('lib')),
      isSemantics(hasExpandedState: true, isExpanded: true),
    );
  });

  testWidgets('a folder with no children shows no expander and cannot open', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var opened = 0;
    await tester.pumpWidget(
      _app(
        V2FileTree(
          data: const V2FileTreeData(
            nodes: <V2FileTreeEntry>[
              V2FileTreeEntry(
                name: 'empty',
                path: 'empty',
                isFolder: true,
              ),
              V2FileTreeEntry(
                name: 'src',
                path: 'src',
                isFolder: true,
                children: <V2FileTreeEntry>[
                  V2FileTreeEntry(name: 'main.dart', path: 'src/main.dart'),
                ],
              ),
            ],
          ),
          onSelectFile: (_) => opened++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The real folder keeps its chevron; the empty one never gets one.
    expect(
      find.byKey(const Key('v2-file-tree-expander-src')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('v2-file-tree-expander-empty')),
      findsNothing,
    );
    expect(
      tester.getSemantics(_row('empty')),
      isSemantics(label: 'Folder empty, empty', hasExpandedState: false),
    );

    await tester.tap(_row('empty'));
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(find.text('main.dart'), findsNothing);

    handle.dispose();
  });

  testWidgets('an empty folder fits 320 dp at 200 % text in both themes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: _app(
            const V2FileTree(
              data: V2FileTreeData(
                nodes: <V2FileTreeEntry>[
                  V2FileTreeEntry(
                    name: 'an-empty-folder-with-a-long-name',
                    path: 'empty',
                    isFolder: true,
                  ),
                  V2FileTreeEntry(
                    name: 'src',
                    path: 'src',
                    isFolder: true,
                    children: <V2FileTreeEntry>[
                      V2FileTreeEntry(name: 'main.dart', path: 'src/main.dart'),
                    ],
                  ),
                ],
              ),
            ),
            dark: dark,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'empty folder overflowed (${dark ? 'dark' : 'light'})',
      );
    }
  });

  testWidgets('a selected file reveals its ancestors and is announced', (
    tester,
  ) async {
    String? opened;
    await tester.pumpWidget(
      _app(
        V2FileTree(
          data: const V2FileTreeData(
            selectedPath: 'lib/widgets/button.dart',
            nodes: _treeNodes,
          ),
          onSelectFile: (path) => opened = path,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('button.dart'), findsOneWidget);
    expect(
      tester.getSemantics(_row('lib/widgets/button.dart')),
      isSemantics(
        label: 'button.dart, Dart file',
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
      ),
    );

    await tester.tap(_row('lib/widgets/button.dart'));
    expect(opened, 'lib/widgets/button.dart');
  });

  testWidgets('rows are at least 48 dp tall at the default text scale', (
    tester,
  ) async {
    await tester.pumpWidget(_app(V2FileTree(data: _tree)));
    await tester.pumpAndSettle();

    for (final id in <String>[
      'lib',
      'lib/main.dart',
      'lib/app.dart',
      'lib/widgets',
      'assets/hero_banner.png',
      'README.md',
    ]) {
      expect(
        tester.getSize(_row(id)).height,
        greaterThanOrEqualTo(OSpace.touch),
        reason: '$id should keep a 48 dp target',
      );
    }
  });

  testWidgets('search filters by name and path without a keyboard', (
    tester,
  ) async {
    final queries = <String>[];
    String? opened;
    await tester.pumpWidget(
      _app(
        V2FileTree(
          data: _tree,
          onSelectFile: (path) => opened = path,
          onQueryChanged: queries.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<OSearchField>(find.byType(OSearchField)).autofocus,
      isFalse,
    );
    expect(find.text('main.dart'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'button');
    await tester.pumpAndSettle();

    expect(find.text('1 file found'), findsOneWidget);
    expect(find.text('lib'), findsOneWidget);
    expect(find.text('widgets'), findsOneWidget);
    expect(find.text('button.dart'), findsOneWidget);
    expect(find.text('main.dart'), findsNothing);
    expect(find.text('README.md'), findsNothing);

    // The field is focused from typing, but tapping a result works directly and
    // drops the keyboard so the tree stays usable.
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isTrue);
    await tester.tap(_row('lib/widgets/button.dart'));
    await tester.pump();

    expect(opened, 'lib/widgets/button.dart');
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isFalse,
    );

    // Path fragments match too.
    await tester.enterText(find.byType(TextField), 'widgets/button');
    await tester.pumpAndSettle();
    expect(find.text('button.dart'), findsOneWidget);
    expect(find.text('main.dart'), findsNothing);

    // Clearing restores the pre-search expansion state.
    await tester.tap(find.bySemanticsLabel('Clear search'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('README.md'), findsOneWidget);
    expect(queries, <String>['button', 'widgets/button', '']);
  });

  testWidgets('searching for a folder keeps its whole subtree', (tester) async {
    await tester.pumpWidget(_app(V2FileTree(data: _tree)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'assets');
    await tester.pumpAndSettle();

    expect(find.text('1 file found'), findsOneWidget);
    expect(_row('assets'), findsOneWidget);
    expect(find.text('hero_banner.png'), findsOneWidget);
    expect(find.text('lib'), findsNothing);
  });

  testWidgets('tapping a folder in results clears the query and shows it', (
    tester,
  ) async {
    await tester.pumpWidget(_app(V2FileTree(data: _tree)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'button');
    await tester.pumpAndSettle();

    await tester.tap(_row('lib'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('1 file found'), findsNothing);
  });

  testWidgets('no-match state offers a clear action', (tester) async {
    await tester.pumpWidget(_app(V2FileTree(data: _tree)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pumpAndSettle();

    expect(find.text('No matching files'), findsOneWidget);
    expect(
      find.text('Nothing matches “zzzz”. Try a different name or path.'),
      findsOneWidget,
    );
    expect(find.textContaining('files found'), findsNothing);

    await tester.tap(find.text('Clear search'));
    await tester.pumpAndSettle();

    expect(find.text('No matching files'), findsNothing);
    expect(find.text('main.dart'), findsOneWidget);
  });

  testWidgets('empty tree and empty status both offer a next action', (
    tester,
  ) async {
    var refreshes = 0;
    await tester.pumpWidget(
      _app(
        V2FileTree(
          data: const V2FileTreeData(
            emptyTitle: 'This branch has no files',
            emptyMessage: 'Push a commit, then refresh.',
          ),
          onRefresh: () => refreshes++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('This branch has no files'), findsOneWidget);
    await tester.tap(find.text('Refresh'));
    expect(refreshes, 1);

    await tester.pumpWidget(
      _app(
        V2FileTree(
          data: const V2FileTreeData(status: V2FileTreeStatus.empty),
          onRefresh: () => refreshes++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No files yet'), findsOneWidget);
    await tester.tap(find.text('Refresh'));
    expect(refreshes, 2);
  });

  testWidgets('loading shows skeletons and error retries', (tester) async {
    await tester.pumpWidget(
      _app(
        const V2FileTree(
          data: V2FileTreeData(status: V2FileTreeStatus.loading),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.byType(OSearchField), findsNothing);

    var retries = 0;
    await tester.pumpWidget(
      _app(
        V2FileTree(
          data: const V2FileTreeData(
            status: V2FileTreeStatus.error,
            errorMessage: 'The workspace is waking up.',
          ),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('The workspace is waking up.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('language icons map common Studio file types', (tester) async {
    await tester.pumpWidget(_app(const V2FileTree(data: _languages)));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.flutter_dash), findsOneWidget);
    expect(find.byIcon(Icons.code_rounded), findsOneWidget); // TypeScript
    expect(find.byIcon(Icons.html_rounded), findsOneWidget);
    expect(find.byIcon(Icons.css_rounded), findsOneWidget);
    expect(find.byIcon(Icons.data_object_rounded), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.byIcon(Icons.terminal_rounded), findsOneWidget);
    expect(find.byIcon(Icons.article_outlined), findsOneWidget);
  });

  testWidgets('320 dp at 200 % text and reduced motion do not overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? OTheme.dark() : OTheme.light(),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: V2FileTree(key: ValueKey<bool>(dark), data: _narrow),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.text('sign_in_with_phone_number_screen.dart'),
        findsOneWidget,
      );
      expect(
        tester.getSize(_row('apps')).height,
        greaterThanOrEqualTo(OSpace.touch),
      );

      await tester.tap(_row('apps/mobile/lib/features/authentication'));
      await tester.pumpAndSettle();
      expect(find.text('sign_in_with_phone_number_screen.dart'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}
