import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/studio/changes_page.dart';
import 'package:ovid_ai/ui/v2/studio/commit_sheet.dart';

Widget _app(Widget child, {bool dark = false}) =>
    MaterialApp(theme: dark ? OTheme.dark() : OTheme.light(), home: child);

const _files = <V2ChangedFile>[
  V2ChangedFile(
    path: 'index.html',
    directory: 'src/pages',
    additions: 32,
    deletions: 4,
    initiallyExpanded: true,
    hunks: <V2DiffHunk>[
      V2DiffHunk(
        header: '@@ -42,6 +42,7 @@',
        lines: <V2DiffLine>[
          V2DiffLine(
            kind: V2DiffKind.context,
            text: '<section class="hero-container">',
            oldNumber: 42,
            newNumber: 42,
          ),
          V2DiffLine(
            kind: V2DiffKind.removed,
            text: '<h1 class="hero-title">Old Platform Title</h1>',
            oldNumber: 44,
          ),
          V2DiffLine(
            kind: V2DiffKind.added,
            text: '<h1 class="hero-title">Ovid Si</h1>',
            newNumber: 44,
          ),
        ],
      ),
    ],
  ),
  V2ChangedFile(
    path: 'styles.css',
    directory: 'src/theme',
    additions: 14,
    deletions: 6,
    hunks: <V2DiffHunk>[
      V2DiffHunk(
        header: '@@ -1,4 +1,6 @@',
        lines: <V2DiffLine>[
          V2DiffLine(
            kind: V2DiffKind.added,
            text: '.hero { color: white; }',
            newNumber: 1,
          ),
        ],
      ),
    ],
  ),
  V2ChangedFile(
    path: 'app.js',
    directory: 'src/core',
    additions: 2,
    deletions: 2,
  ),
];

const _data = V2ChangesData(
  files: _files,
  branchLabel: 'main ← feature/hero-revamp',
  behindCount: 3,
);

const _openSheetKey = Key('studio-open-commit-sheet');
const _submitKey = ValueKey('v2-commit-submit');
const _messageKey = ValueKey('v2-commit-message');

Future<void> _openCommitSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(_openSheetKey));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders changes and diffs in light and dark', (tester) async {
    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(
        _app(const V2ChangesPage(data: _data), dark: dark),
      );
      await tester.pumpAndSettle();

      expect(find.text('Changes'), findsOneWidget);
      expect(find.text('3 changed · +48 −12'), findsOneWidget);
      expect(find.text('3 changed files'), findsOneWidget);
      expect(find.text('index.html'), findsOneWidget);
      expect(find.text('styles.css'), findsOneWidget);
      expect(find.text('@@ -42,6 +42,7 @@'), findsOneWidget);
    }
  });

  testWidgets('empty state goes back to the workspace', (tester) async {
    var backs = 0;
    await tester.pumpWidget(
      _app(
        V2ChangesPage(
          data: const V2ChangesData(status: V2ChangesStatus.empty),
          onBack: () => backs++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No changes to review'), findsOneWidget);
    await tester.tap(find.text('Back to workspace'));
    expect(backs, 1);
  });

  testWidgets('commit and push reports the message', (tester) async {
    String? message;
    await tester.pumpWidget(
      _app(V2ChangesPage(data: _data, onCommit: (value) => message = value)),
    );
    await tester.pumpAndSettle();

    await _openCommitSheet(tester);
    await tester.enterText(find.byKey(_messageKey), '  fix: hero typography  ');
    await tester.pump();
    await tester.tap(find.byKey(_submitKey));
    await tester.pumpAndSettle();

    expect(message, 'fix: hero typography');
    expect(find.byType(V2CommitSheet), findsNothing);
  });

  testWidgets('320 dp wide at 200 % text does not overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: _app(const V2ChangesPage(data: _data)),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Changes'), findsOneWidget);
    expect(find.text('Behind remote'), findsOneWidget);
  });

  testWidgets('loading state shows skeletons', (tester) async {
    await tester.pumpWidget(
      _app(
        const V2ChangesPage(
          data: V2ChangesData(status: V2ChangesStatus.loading),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Commit & push'), findsNothing);
  });

  testWidgets('error state retries', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        V2ChangesPage(
          data: const V2ChangesData(
            status: V2ChangesStatus.error,
            errorMessage: 'Changes could not load.',
          ),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Changes could not load.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('sync row asks to pull upstream commits', (tester) async {
    var syncs = 0;
    await tester.pumpWidget(
      _app(V2ChangesPage(data: _data, onSync: () => syncs++)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Sync latest first'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync latest first'));
    expect(syncs, 1);
  });

  testWidgets('commit stays disabled until a message is typed', (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      _app(V2ChangesPage(data: _data, onCommit: (_) {})),
    );
    await tester.pumpAndSettle();
    await _openCommitSheet(tester);

    expect(
      tester.getSemantics(find.byKey(_submitKey)),
      isSemantics(isButton: true, isEnabled: false),
    );

    await tester.enterText(find.byKey(_messageKey), 'fix: hero typography');
    await tester.pump();

    expect(
      tester.getSemantics(find.byKey(_submitKey)),
      isSemantics(isButton: true, isEnabled: true),
    );
    handle.dispose();
  });

  testWidgets('a file without hunks is not expandable and says so', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const V2ChangesPage(data: _data)));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('v2-diff-unavailable-app.js')),
      findsOneWidget,
    );
    expect(find.text('No diff available'), findsOneWidget);

    await tester.ensureVisible(find.text('app.js'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('app.js'));
    await tester.pumpAndSettle();

    // No chevron means no empty diff body appears.
    expect(find.text('No diff available'), findsOneWidget);
  });

  testWidgets('the diff shows the real before and after lines', (tester) async {
    await tester.pumpWidget(_app(const V2ChangesPage(data: _data)));
    await tester.pumpAndSettle();

    expect(
      find.text('<h1 class="hero-title">Old Platform Title</h1>'),
      findsOneWidget,
    );
    expect(find.text('<h1 class="hero-title">Ovid Si</h1>'), findsOneWidget);
  });

  testWidgets('an unwired commit can be reviewed but never submitted', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(_app(const V2ChangesPage(data: _data)));
    await tester.pumpAndSettle();
    await _openCommitSheet(tester);

    await tester.enterText(find.byKey(_messageKey), 'fix: hero typography');
    await tester.pump();

    expect(
      tester.getSemantics(find.byKey(_submitKey)),
      isSemantics(isButton: true, isEnabled: false),
    );
    expect(
      find.textContaining('committing is not available yet'),
      findsNothing,
    );
    handle.dispose();
  });

  testWidgets('collapsed file expands to show its diff', (tester) async {
    await tester.pumpWidget(_app(const V2ChangesPage(data: _data)));
    await tester.pumpAndSettle();

    expect(find.text('@@ -1,4 +1,6 @@'), findsNothing);

    await tester.ensureVisible(find.text('styles.css'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('styles.css'));
    await tester.pumpAndSettle();

    expect(find.text('@@ -1,4 +1,6 @@'), findsOneWidget);
  });

  testWidgets('the commit action opens the shared commit sheet', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const V2ChangesPage(data: _data)));
    await tester.pumpAndSettle();

    await _openCommitSheet(tester);

    expect(find.byType(V2CommitSheet), findsOneWidget);
    expect(find.text('Commit changes'), findsOneWidget);
    expect(find.text('3 changed files'), findsWidgets);
  });

  testWidgets('the sheet maps changed files, branch and sync state', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const V2ChangesPage(data: _data)));
    await tester.pumpAndSettle();
    await _openCommitSheet(tester);

    // Directory + name are joined into the full path the sheet lists.
    expect(find.text('src/pages/index.html'), findsOneWidget);
    expect(find.text('src/theme/styles.css'), findsOneWidget);
    expect(find.text('src/core/app.js'), findsOneWidget);
    // The page's branch and behind count seed the sheet.
    expect(find.text('main ← feature/hero-revamp'), findsWidgets);
    expect(find.text('Sync first'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(V2CommitSheet),
        matching: find.text('+48'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(V2CommitSheet),
        matching: find.text('−12'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('closing the commit sheet returns without committing', (
    tester,
  ) async {
    var commits = 0;
    await tester.pumpWidget(
      _app(V2ChangesPage(data: _data, onCommit: (_) => commits++)),
    );
    await tester.pumpAndSettle();
    await _openCommitSheet(tester);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    expect(find.byType(V2CommitSheet), findsNothing);
    expect(commits, 0);
    expect(find.text('Changes'), findsOneWidget);
  });
}
