import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/data_control_page.dart';

Widget _app(Widget home, {required ThemeData theme}) =>
    MaterialApp(theme: theme, home: home);

Widget _narrowApp(Widget home, {required ThemeData theme}) => MaterialApp(
  theme: theme,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: const TextScaler.linear(2)),
    child: child!,
  ),
  home: home,
);

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void _useNarrowPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

V2DataControlPageData _data({
  bool hasData = true,
  VoidCallback? onExportImport,
  VoidCallback? onExport,
  VoidCallback? onChooseImport,
  VoidCallback? onPermissions,
  ValueChanged<bool>? onCrashReportsChanged,
  VoidCallback? onStorage,
  VoidCallback? onDeleteData,
  VoidCallback? onResetMemory,
  VoidCallback? onRetry,
  String? errorMessage,
  bool loading = false,
}) {
  return V2DataControlPageData(
    hasData: hasData,
    loading: loading,
    errorMessage: errorMessage,
    onExportImport: onExportImport,
    onExport: onExport,
    onChooseImport: onChooseImport,
    onPermissions: onPermissions,
    onCrashReportsChanged: onCrashReportsChanged,
    onStorage: onStorage,
    onDeleteData: onDeleteData,
    onResetMemory: onResetMemory,
    onRetry: onRetry,
  );
}

void main() {
  testWidgets('renders one header and action-only sections', (tester) async {
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            onExport: () {},
            onChooseImport: () {},
            onStorage: () {},
            onPermissions: () {},
            onDeleteData: () {},
            onResetMemory: () {},
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Data control'), findsOneWidget);
    expect(find.text('BACKUP'), findsOneWidget);
    expect(find.text('ACCOUNT'), findsOneWidget);
    expect(find.text('DANGER'), findsOneWidget);
    expect(find.text('Save to device'), findsOneWidget);
    expect(find.text('Choose backup'), findsOneWidget);
    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('Crash reports'), findsOneWidget);
    expect(find.text('Delete your data'), findsOneWidget);
    expect(find.text('Reset memory'), findsOneWidget);
    await _reveal(tester, find.text('Export data'));
    expect(find.text('Export data'), findsOneWidget);
  });

  testWidgets('deleted explanatory blocks are gone', (tester) async {
    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(onExport: () {})),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Privacy & Data Control'), findsNothing);
    expect(find.textContaining('Heavy artifacts'), findsNothing);
    expect(find.textContaining('Take full ownership'), findsNothing);
    expect(find.textContaining('Encrypted'), findsNothing);
  });

  testWidgets('choose backup runs the import callback', (tester) async {
    var picked = 0;
    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(onChooseImport: () => picked++)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose backup'));
    expect(picked, 1);
  });

  testWidgets('storage and permissions rows run their callbacks', (
    tester,
  ) async {
    var storage = 0;
    var permissions = 0;
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            onStorage: () => storage++,
            onPermissions: () => permissions++,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Storage'));
    await tester.tap(find.text('Permissions'));
    expect(storage, 1);
    expect(permissions, 1);
  });

  testWidgets('crash reports switch reports the new value', (tester) async {
    bool? next;
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(onCrashReportsChanged: (value) => next = value),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    expect(next, isFalse);
  });

  testWidgets('delete asks for confirmation before running', (tester) async {
    var deleted = 0;
    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(onDeleteData: () => deleted++)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await _reveal(tester, find.text('Delete your data'));
    await tester.tap(find.text('Delete your data'));
    await tester.pumpAndSettle();

    expect(find.text('Delete all your data?'), findsOneWidget);
    expect(deleted, 0, reason: 'nothing may be deleted before confirmation');

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(deleted, 0);
  });

  testWidgets('reset memory confirms, then runs the callback', (tester) async {
    var resets = 0;
    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(onResetMemory: () => resets++)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await _reveal(tester, find.text('Reset memory'));
    await tester.tap(find.text('Reset memory'));
    await tester.pumpAndSettle();

    expect(find.text('Reset all memory?'), findsOneWidget);
    expect(resets, 0);

    await tester.tap(find.byKey(const ValueKey('reset-memory-confirm')));
    await tester.pumpAndSettle();
    expect(resets, 1);
  });

  testWidgets('loading state renders skeletons', (tester) async {
    await tester.pumpWidget(
      _app(DataControlPage(data: _data(loading: true)), theme: OTheme.light()),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Save to device'), findsNothing);
  });

  testWidgets('error state offers a retry', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            errorMessage: 'Could not load data control.',
            onRetry: () => retried = true,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could not load data control.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, isTrue);
  });

  testWidgets('empty state offers the real export action', (tester) async {
    var exports = 0;
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(hasData: false, onExportImport: () => exports++),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No data to manage'), findsOneWidget);
    await tester.tap(find.text('Export data'));
    expect(exports, 1);
  });

  testWidgets('fits 320 dp at 200% text in light and dark', (tester) async {
    _useNarrowPhone(tester);
    for (final theme in <ThemeData>[OTheme.light(), OTheme.dark()]) {
      await tester.pumpWidget(
        _narrowApp(
          DataControlPage(
            data: _data(
              onExport: () {},
              onChooseImport: () {},
              onStorage: () {},
              onPermissions: () {},
              onDeleteData: () {},
              onResetMemory: () {},
            ),
          ),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('checked backup action fits 320 dp at 200% text', (tester) async {
    _useNarrowPhone(tester);
    await tester.pumpWidget(
      _narrowApp(
        DataControlPage(
          data: V2DataControlPageData(
            importValidation: const V2ImportValidation(
              fileName: 'ovid-backup-2026-10-21.zip',
              message: 'Ready to import: 12 MB · 42 chats · 860 messages.',
              valid: true,
              planQuotaLabel: 'Needs 12 MB · 1.8 GB free on your plan.',
            ),
            onImport: () {},
            onChooseImport: () {},
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    // The action used to sit beside the long file name and overflowed the
    // row by 11 px at 200 % text; it now sits below the text.
    expect(tester.takeException(), isNull);
    await _reveal(tester, find.text('Import'));
    expect(find.text('Import'), findsOneWidget);
  });

  testWidgets('content is centred and capped at 600 dp', (tester) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(onExport: () {})),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final card = tester.getRect(find.byType(OCard).first);
    expect(card.width, lessThanOrEqualTo(640));
    expect(card.left, greaterThan(0));
    expect(card.right, lessThan(600));
  });

  testWidgets('content is centred and capped at 900 dp', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(onExport: () {})),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final card = tester.getRect(find.byType(OCard).first);
    expect(card.width, lessThanOrEqualTo(720));
    expect(card.left, greaterThan(0));
    expect(card.right, lessThan(900));
  });
}
