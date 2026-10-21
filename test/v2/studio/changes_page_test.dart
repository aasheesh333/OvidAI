import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/studio/changes_page.dart';

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

    await tester.enterText(find.byType(TextField), 'fix: hero typography');
    await tester.pump();
    await tester.tap(find.text('Commit & push'));
    expect(message, 'fix: hero typography');
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
    expect(find.text('Sync latest first'), findsOneWidget);
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
    await tester.pumpWidget(_app(const V2ChangesPage(data: _data)));
    await tester.pumpAndSettle();

    final button = find.text('Commit & push');
    expect(
      tester.getSemantics(button),
      isSemantics(isButton: true, isEnabled: false),
    );

    await tester.enterText(find.byType(TextField), 'fix: hero typography');
    await tester.pump();

    expect(
      tester.getSemantics(button),
      isSemantics(isButton: true, isEnabled: true),
    );
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
}
