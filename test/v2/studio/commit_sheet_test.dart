import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/studio/commit_sheet.dart';

Widget _app(Widget child, {bool dark = false, double textScale = 1.0}) =>
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, home) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: home!,
      ),
      home: Scaffold(body: child),
    );

const _files = <V2CommitFile>[
  V2CommitFile(path: 'src/pages/index.html', additions: 32, deletions: 4),
  V2CommitFile(path: 'src/theme/styles.css', additions: 14, deletions: 6),
  V2CommitFile(path: 'src/core/app.js', additions: 2, deletions: 2),
];

const _data = V2CommitSheetData(
  files: _files,
  branchLabel: 'feature/hero-revamp',
  initialMessage: 'feat: update hero typography & branding',
);

const _submitKey = ValueKey('v2-commit-submit');
const _messageKey = ValueKey('v2-commit-message');
const _syncKey = ValueKey('v2-commit-sync');

OButton _submit(WidgetTester tester) =>
    tester.widget<OButton>(find.byKey(_submitKey));

void main() {
  testWidgets('renders branch, file summary and message in light and dark', (
    tester,
  ) async {
    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(
        _app(V2CommitSheet(data: _data, onCommit: (_) {}), dark: dark),
      );
      await tester.pumpAndSettle();

      expect(find.text('Commit changes'), findsOneWidget);
      expect(find.text('feature/hero-revamp'), findsOneWidget);
      expect(find.text('3 changed files'), findsOneWidget);
      expect(find.text('+48'), findsOneWidget);
      expect(find.text('−12'), findsOneWidget);
      expect(find.text('src/pages/index.html'), findsOneWidget);
      expect(find.text('src/theme/styles.css'), findsOneWidget);
      expect(find.text('39/72'), findsOneWidget);
      expect(find.text('Commit & push'), findsOneWidget);

      // The sheet is a form, not an essay.
      expect(find.text('origin'), findsNothing);
      expect(find.textContaining('Keep it short'), findsNothing);
      expect(find.text('Push protected'), findsNothing);
      expect(find.textContaining('.git/config'), findsNothing);
    }
  });

  testWidgets('commit stays disabled until the message is valid', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var committed = <String>[];

    await tester.pumpWidget(
      _app(
        V2CommitSheet(
          data: const V2CommitSheetData(
            files: _files,
            branchLabel: 'feature/hero-revamp',
          ),
          onCommit: committed.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_submit(tester).onPressed, isNull);
    expect(
      _submit(tester).semanticLabel,
      'Commit & push, write a message first',
    );
    expect(find.textContaining('write a message first'), findsNothing);
    expect(find.text('0/72'), findsOneWidget);

    // Whitespace alone is not a valid message.
    await tester.enterText(find.byKey(_messageKey), '   ');
    await tester.pump();
    expect(_submit(tester).onPressed, isNull);

    await tester.enterText(find.byKey(_messageKey), '  feat: tune hero  ');
    await tester.pump();
    expect(find.text('19/72'), findsOneWidget);
    expect(_submit(tester).onPressed, isNotNull);

    await tester.tap(find.byKey(_submitKey));
    expect(committed, <String>['feat: tune hero']);
    handle.dispose();
  });

  testWidgets('a message past 72 characters blocks the commit', (tester) async {
    await tester.pumpWidget(_app(V2CommitSheet(data: _data, onCommit: (_) {})));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(_messageKey), 'a' * 73);
    await tester.pump();

    expect(find.text('73/72'), findsOneWidget);
    expect(_submit(tester).onPressed, isNull);
    expect(
      _submit(tester).semanticLabel,
      'Commit & push, shorten the message to 72 characters',
    );

    await tester.enterText(find.byKey(_messageKey), 'a' * 72);
    await tester.pump();
    expect(find.text('72/72'), findsOneWidget);
    expect(_submit(tester).onPressed, isNotNull);
  });

  testWidgets('behind remote shows one sync line and syncs', (tester) async {
    var synced = 0;
    await tester.pumpWidget(
      _app(
        V2CommitSheet(
          data: const V2CommitSheetData(
            files: _files,
            branchLabel: 'feature/hero-revamp',
            behindCount: 2,
            initialMessage: 'feat: tune hero',
          ),
          onSync: () => synced++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 commits behind'), findsOneWidget);
    expect(
      tester.widget<OButton>(find.byKey(_syncKey)).semanticLabel,
      'Sync latest changes, 2 behind',
    );

    await tester.tap(find.byKey(_syncKey));
    expect(synced, 1);
  });

  testWidgets('singular sync copy and hidden line when in sync', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const V2CommitSheet(
          data: V2CommitSheetData(files: _files, behindCount: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 commit behind'), findsOneWidget);

    await tester.pumpWidget(_app(const V2CommitSheet(data: _data)));
    await tester.pumpAndSettle();
    expect(find.textContaining('behind'), findsNothing);
  });

  testWidgets('summary collapses extra files', (tester) async {
    const many = <V2CommitFile>[
      V2CommitFile(path: 'a.dart', additions: 1),
      V2CommitFile(path: 'b.dart', additions: 1),
      V2CommitFile(path: 'c.dart', additions: 1),
      V2CommitFile(path: 'd.dart', additions: 1),
      V2CommitFile(path: 'e.dart', additions: 1),
      V2CommitFile(path: 'f.dart', additions: 1),
    ];
    await tester.pumpWidget(
      _app(const V2CommitSheet(data: V2CommitSheetData(files: many))),
    );
    await tester.pumpAndSettle();

    expect(find.text('6 changed files'), findsOneWidget);
    expect(find.text('+2 more'), findsOneWidget);
    expect(find.text('e.dart'), findsNothing);
  });

  testWidgets('loading shows skeletons', (tester) async {
    await tester.pumpWidget(
      _app(
        const V2CommitSheet(
          data: V2CommitSheetData(status: V2CommitSheetStatus.loading),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.byKey(_submitKey), findsNothing);
  });

  testWidgets('empty state offers a way back', (tester) async {
    var closed = 0;
    await tester.pumpWidget(
      _app(
        V2CommitSheet(
          data: const V2CommitSheetData(status: V2CommitSheetStatus.empty),
          onClose: () => closed++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No changes to commit'), findsOneWidget);
    expect(find.byKey(_submitKey), findsNothing);
    await tester.tap(find.text('Back to workspace'));
    expect(closed, 1);
  });

  testWidgets('error state retries', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _app(
        V2CommitSheet(
          data: const V2CommitSheetData(
            status: V2CommitSheetStatus.error,
            errorMessage: 'The working tree is unavailable.',
          ),
          onRetry: () => retried++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('The working tree is unavailable.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, 1);
  });

  testWidgets('branch, summary and counter carry semantic labels', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(V2CommitSheet(data: _data, onCommit: (_) {})),
    );
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel('Branch, feature/hero-revamp'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('3 changed files, +48 added, −12 removed'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('39 of 72 characters'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('an unwired commit shows neither a field nor a submit', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const V2CommitSheet(
          data: V2CommitSheetData(
            files: _files,
            initialMessage: 'feat: tune hero',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A read-only review: no message input, no submit control.
    expect(find.byKey(_submitKey), findsNothing);
    expect(find.byKey(_messageKey), findsNothing);
    expect(find.text('Commit & push'), findsNothing);
    expect(find.textContaining('unavailable'), findsNothing);
  });

  testWidgets('an unwired sync shows no dead button and no excuse', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const V2CommitSheet(
          data: V2CommitSheetData(files: _files, behindCount: 2),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 commits behind'), findsOneWidget);
    expect(find.byKey(_syncKey), findsNothing);
    expect(find.textContaining('not available'), findsNothing);
  });

  testWidgets('fits 320 dp at 200% text and scrolls to the commit action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(
        V2CommitSheet(
          data: const V2CommitSheetData(
            files: _files,
            branchLabel: 'feature/hero-revamp',
            behindCount: 1,
            initialMessage:
                'feat: update hero typography & branding across the landing '
                'page',
          ),
          onCommit: (_) {},
        ),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -900),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(_submitKey), findsOneWidget);
  });

  testWidgets('every state fits 320 dp at 200% text', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final status in <V2CommitSheetStatus>[
      V2CommitSheetStatus.empty,
      V2CommitSheetStatus.error,
      V2CommitSheetStatus.loading,
    ]) {
      for (final dark in <bool>[false, true]) {
        await tester.pumpWidget(
          _app(
            V2CommitSheet(
              data: V2CommitSheetData(
                status: status,
                errorMessage: status == V2CommitSheetStatus.error
                    ? 'The working tree is unavailable.'
                    : null,
              ),
              onClose: () {},
              onRetry: () {},
            ),
            dark: dark,
            textScale: 2,
          ),
        );
        // The skeleton shimmer never settles, so pump a frame instead.
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
      }
    }
  });
}
