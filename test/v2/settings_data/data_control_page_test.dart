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

void _useNarrowPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

V2DataControlPageData _data({
  bool hasData = true,
  VoidCallback? onExportImport,
  VoidCallback? onExport,
  V2ExportFileWriter? onSaveExport,
  VoidCallback? onChooseImport,
  VoidCallback? onImport,
  VoidCallback? onDeleteData,
  VoidCallback? onClearCache,
  Future<int> Function()? onClearCacheAndReport,
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
    onSaveExport: onSaveExport,
    onChooseImport: onChooseImport,
    onImport: onImport,
    onDeleteData: onDeleteData,
    onClearCache: onClearCache,
    onClearCacheAndReport: onClearCacheAndReport,
    onRetry: onRetry,
  );
}

void main() {
  testWidgets('renders one header and the four rows', (tester) async {
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            onExport: () {},
            onChooseImport: () {},
            onDeleteData: () {},
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Data control'), findsOneWidget);
    expect(find.text('Export backup'), findsOneWidget);
    expect(find.text('Import'), findsOneWidget);
    expect(find.text('Clear cache'), findsOneWidget);
    expect(find.text('Delete data'), findsOneWidget);

    // The section cards, the account rows and the bottom button are gone.
    expect(find.text('BACKUP'), findsNothing);
    expect(find.text('ACCOUNT'), findsNothing);
    expect(find.text('DANGER'), findsNothing);
    expect(find.text('Save to device'), findsNothing);
    expect(find.text('Choose backup'), findsNothing);
    expect(find.text('Storage'), findsNothing);
    expect(find.text('Permissions'), findsNothing);
    expect(find.text('Crash reports'), findsNothing);
    expect(find.text('Reset memory'), findsNothing);
    expect(find.text('Delete your data'), findsNothing);
    expect(find.text('Export data'), findsNothing);
    expect(find.byType(Switch), findsNothing);
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

  testWidgets('export backup runs the export callback', (tester) async {
    var exports = 0;
    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(onExport: () => exports++)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Export backup'));
    expect(exports, 1);
  });

  testWidgets('a host that only saves files still gets an export row', (
    tester,
  ) async {
    var saves = 0;
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(onSaveExport: () async {
            saves++;
            return null;
          }),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Export backup'));
    await tester.pumpAndSettle();
    expect(saves, 1);
  });

  testWidgets('without an export path the export row is omitted', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(DataControlPage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Export backup'), findsNothing);
    expect(find.text('Import'), findsNothing);
    // The cache row always works: the page owns the temp-directory clear.
    expect(find.text('Clear cache'), findsOneWidget);
    // A delete row without a deletion service is removed, not disabled.
    expect(find.text('Delete data'), findsNothing);
  });

  testWidgets('import runs the choose callback', (tester) async {
    var picked = 0;
    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(onChooseImport: () => picked++)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Import'));
    expect(picked, 1);
  });

  testWidgets('clear cache fires the injected callback', (tester) async {
    var cleared = 0;
    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(onClearCache: () => cleared++)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clear cache'));
    await tester.pump();
    expect(cleared, 1);
    expect(find.text('Cache cleared.'), findsOneWidget);
  });

  testWidgets('clear cache reports the bytes actually freed', (tester) async {
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(onClearCacheAndReport: () async => 142 * 1024 * 1024),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clear cache'));
    await tester.pump();
    expect(find.text('Freed 142 MB of cache.'), findsOneWidget);
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

    await tester.tap(find.text('Delete data'));
    await tester.pumpAndSettle();

    expect(find.text('Delete all your data?'), findsOneWidget);
    expect(deleted, 0, reason: 'nothing may be deleted before confirmation');

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(deleted, 0);
  });

  testWidgets('the checked backup keeps its import action under the row', (
    tester,
  ) async {
    var imported = 0;
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: V2DataControlPageData(
            importValidation: const V2ImportValidation(
              fileName: 'ovid-backup-2026-10-21.zip',
              message: 'Ready to import: 12 MB · 42 chats · 860 messages.',
              valid: true,
              planQuotaLabel: 'Needs 12 MB · 1.8 GB free on your plan.',
            ),
            onImport: () => imported++,
            onChooseImport: () {},
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ovid-backup-2026-10-21.zip'), findsOneWidget);
    // The Import row and the import action share the label.
    expect(find.text('Import'), findsNWidgets(2));

    await tester.tap(find.byType(OButton));
    await tester.pump();
    expect(imported, 1);
  });

  testWidgets('loading state renders skeletons', (tester) async {
    await tester.pumpWidget(
      _app(DataControlPage(data: _data(loading: true)), theme: OTheme.light()),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Export backup'), findsNothing);
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
              onDeleteData: () {},
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
    expect(find.byType(OButton), findsOneWidget);
    expect(find.text('Import'), findsNWidgets(2));
  });

  testWidgets('content is centred and capped at 600 dp', (tester) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(onExport: () {}, onDeleteData: () {})),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final row = tester.getRect(find.byKey(const ValueKey('export-backup-row')));
    expect(row.width, lessThanOrEqualTo(640));
    expect(row.left, greaterThan(0));
    expect(row.right, lessThan(600));
  });

  testWidgets('content is centred and capped at 900 dp', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(onExport: () {}, onDeleteData: () {})),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final row = tester.getRect(find.byKey(const ValueKey('export-backup-row')));
    expect(row.width, lessThanOrEqualTo(720));
    expect(row.left, greaterThan(0));
    expect(row.right, lessThan(900));
  });
}
