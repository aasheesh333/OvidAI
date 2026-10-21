import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/sidebar/session_actions_sheet.dart';

const _data = V2SessionActionsData(
  title: 'Landing page redesign',
  modelLabel: 'Auto',
  timeLabel: 'Today at 10:24 AM',
  messageCount: 14,
  projectName: 'Mobile App Redesign',
);

Widget _app(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? OTheme.light(),
  home: Scaffold(body: child),
);

/// Pumps [child] on a 320 dp wide screen with [scale] text scaling.
Future<void> _pumpNarrow(
  WidgetTester tester,
  Widget child, {
  double scale = 1,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = const Size(320, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? OTheme.light(),
      builder: (context, widget) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: widget!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('session actions sheet renders every action in light', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const SessionActionsSheet(data: _data)));
    await tester.pumpAndSettle();

    expect(find.text('Landing page redesign'), findsOneWidget);
    expect(
      find.text('Today at 10:24 AM · 14 messages · Auto model'),
      findsOneWidget,
    );
    expect(find.text('Pin to top of drawer'), findsOneWidget);
    expect(find.text('Rename chat'), findsOneWidget);
    expect(find.text('Move to project'), findsOneWidget);
    expect(find.text('Share chat'), findsOneWidget);
    expect(find.text('Duplicate chat'), findsOneWidget);
    expect(find.text('Export as Markdown'), findsOneWidget);
    expect(find.text('Delete chat'), findsOneWidget);
    expect(
      find.text(
        "Deleting removes this chat's files, artifacts, and learned memory from your cloud account. This cannot be undone.",
      ),
      findsOneWidget,
    );
  });

  testWidgets('session actions sheet renders in dark', (tester) async {
    await tester.pumpWidget(
      _app(const SessionActionsSheet(data: _data), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pin to top of drawer'), findsOneWidget);
    expect(find.text('Delete chat'), findsOneWidget);
  });

  testWidgets('empty state closes the sheet', (tester) async {
    var closes = 0;
    await tester.pumpWidget(
      _app(
        SessionActionsSheet(
          data: const V2SessionActionsData(
            status: V2SessionActionsStatus.empty,
          ),
          onClose: () => closes++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Chat not found'), findsOneWidget);
    await tester.tap(find.text('Close'));
    expect(closes, 1);
  });

  testWidgets('tapping Rename reports the action', (tester) async {
    var renames = 0;
    await tester.pumpWidget(
      _app(SessionActionsSheet(data: _data, onRename: () => renames++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Rename chat'));
    expect(renames, 1);
  });

  testWidgets('pin switch toggles', (tester) async {
    bool? pinned;
    await tester.pumpWidget(
      _app(
        SessionActionsSheet(
          data: _data,
          onTogglePin: (value) => pinned = value,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(pinned, isTrue);
  });

  testWidgets('opens in the shared bottom sheet and closes', (tester) async {
    var closes = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showSessionActionsSheet(
                  context,
                  data: _data,
                  onClose: () => closes++,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Pin to top of drawer'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(closes, 1);
    expect(find.text('Pin to top of drawer'), findsNothing);
  });

  testWidgets('loading state shows skeleton rows', (tester) async {
    await tester.pumpWidget(
      _app(
        const SessionActionsSheet(
          data: V2SessionActionsData(
            status: V2SessionActionsStatus.loading,
          ),
        ),
      ),
    );
    // The skeleton shimmers, so pump once instead of settling.
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Pin to top of drawer'), findsNothing);
  });

  testWidgets('error state retries', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        SessionActionsSheet(
          data: const V2SessionActionsData(
            status: V2SessionActionsStatus.error,
            errorMessage: 'Check your connection and try again.',
          ),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Chat actions did not load'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('delete reports the action', (tester) async {
    var deletes = 0;
    await tester.pumpWidget(
      _app(SessionActionsSheet(data: _data, onDelete: () => deletes++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete chat'));
    expect(deletes, 1);
  });

  testWidgets('320 dp at 200% text does not overflow', (tester) async {
    await _pumpNarrow(
      tester,
      const SessionActionsSheet(data: _data),
      scale: 2,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Move to project'), findsOneWidget);
    expect(find.text('Duplicate chat'), findsOneWidget);
    expect(find.text('Delete chat'), findsOneWidget);

    // Same width with no project assigned: the row falls back to a chevron.
    await _pumpNarrow(
      tester,
      const SessionActionsSheet(
        data: V2SessionActionsData(title: 'Landing page redesign'),
      ),
      scale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Move to project'), findsOneWidget);
  });

  testWidgets('320 dp at 200% text keeps empty and error readable', (
    tester,
  ) async {
    await _pumpNarrow(
      tester,
      SessionActionsSheet(
        data: const V2SessionActionsData(status: V2SessionActionsStatus.empty),
        onClose: () {},
      ),
      scale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Chat not found'), findsOneWidget);

    await _pumpNarrow(
      tester,
      SessionActionsSheet(
        data: const V2SessionActionsData(status: V2SessionActionsStatus.error),
        onRetry: () {},
      ),
      scale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('narrow rows leave room for the title', (tester) async {
    await _pumpNarrow(tester, const SessionActionsSheet(data: _data));

    // The project chip and the "Branch" pill shrink instead of pushing the
    // row title into a narrow column.
    final moveRow = tester.getSize(
      find.ancestor(
        of: find.text('Move to project'),
        matching: find.byType(OListRow),
      ),
    );
    expect(moveRow.height, lessThan(160));
    expect(tester.getSize(find.text('Move to project')).width, greaterThan(90));
  });
}
