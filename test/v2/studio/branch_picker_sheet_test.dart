import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/studio/branch_picker_sheet.dart';

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

const _current = V2Branch(
  name: 'main',
  lastCommitLabel: 'Default · Synced with remote',
  isDefault: true,
  isCurrent: true,
);

const _branches = <V2Branch>[
  V2Branch(name: 'develop', lastCommitLabel: '12m ago by Priya'),
  V2Branch(name: 'feat/hero', lastCommitLabel: '1h ago by Aarav'),
  V2Branch(name: 'fix/nav', lastCommitLabel: 'Yesterday'),
];

const _data = V2BranchPickerData(current: _current, branches: _branches);

void main() {
  testWidgets('renders branches in light and dark', (tester) async {
    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(
        _app(const V2BranchPickerSheet(data: _data), dark: dark),
      );
      await tester.pumpAndSettle();

      expect(find.text('Switch branch'), findsOneWidget);
      expect(find.text('main'), findsOneWidget);
      expect(find.text('develop'), findsOneWidget);
      expect(find.text('12m ago by Priya'), findsOneWidget);
      expect(find.textContaining('Nothing will be lost'), findsOneWidget);
    }
  });

  testWidgets('empty state creates a branch', (tester) async {
    var created = 0;
    await tester.pumpWidget(
      _app(
        V2BranchPickerSheet(
          data: const V2BranchPickerData(status: V2BranchPickerStatus.empty),
          onCreateBranch: () => created++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No branches yet'), findsOneWidget);
    await tester.tap(find.text('Create new branch'));
    expect(created, 1);
  });

  testWidgets('selecting a branch reports it', (tester) async {
    V2Branch? selected;
    await tester.pumpWidget(
      _app(
        V2BranchPickerSheet(
          data: _data,
          onSelectBranch: (branch) => selected = branch,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('develop'));
    expect(selected?.name, 'develop');
  });

  testWidgets('search filters the branch list', (tester) async {
    await tester.pumpWidget(_app(const V2BranchPickerSheet(data: _data)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'feat');
    await tester.pumpAndSettle();

    expect(find.text('feat/hero'), findsOneWidget);
    expect(find.text('develop'), findsNothing);
  });

  testWidgets('loading shows skeletons', (tester) async {
    await tester.pumpWidget(
      _app(
        const V2BranchPickerSheet(
          data: V2BranchPickerData(status: V2BranchPickerStatus.loading),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  testWidgets('error state retries', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _app(
        V2BranchPickerSheet(
          data: const V2BranchPickerData(
            status: V2BranchPickerStatus.error,
            errorMessage: 'Branches are offline right now.',
          ),
          onRetry: () => retried++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Branches are offline right now.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, 1);
  });

  testWidgets('no-match search offers a clear action', (tester) async {
    await tester.pumpWidget(_app(const V2BranchPickerSheet(data: _data)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No branches found'), findsOneWidget);

    await tester.tap(find.text('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('develop'), findsOneWidget);
    expect(find.text('No branches found'), findsNothing);
  });

  testWidgets('branch rows carry a semantic label', (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(_app(const V2BranchPickerSheet(data: _data)));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('develop, 12m ago by Priya'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('fits a 320 dp screen at 200% text without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(const V2BranchPickerSheet(data: _data), textScale: 2),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Switch branch'), findsOneWidget);
    expect(find.text('main'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Nothing will be lost'), findsOneWidget);
  });

  testWidgets('every state fits 320 dp at 200% text', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final status in <V2BranchPickerStatus>[
      V2BranchPickerStatus.empty,
      V2BranchPickerStatus.error,
      V2BranchPickerStatus.loading,
    ]) {
      for (final dark in <bool>[false, true]) {
        await tester.pumpWidget(
          _app(
            V2BranchPickerSheet(
              data: V2BranchPickerData(
                status: status,
                errorMessage: status == V2BranchPickerStatus.error
                    ? 'Branches are offline right now.'
                    : null,
              ),
              onCreateBranch: () {},
              onRetry: () {},
            ),
            dark: dark,
            textScale: 2,
          ),
        );
        // Skeleton shimmer never settles, so pump a frame instead of settling.
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
      }
    }
  });
}
