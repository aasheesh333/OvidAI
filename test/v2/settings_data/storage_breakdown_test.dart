import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/settings/storage_breakdown.dart';

// Sample numbers for the tests only. The widget itself ships zero defaults.
const _entries = <V2StorageCategoryBytes>[
  V2StorageCategoryBytes(
    category: V2StorageCategory.chats,
    bytes: 1288490189, // 1.2 GiB
  ),
  V2StorageCategoryBytes(
    category: V2StorageCategory.artifacts,
    bytes: 858993459, // 0.8 GiB
  ),
  V2StorageCategoryBytes(
    category: V2StorageCategory.memory,
    bytes: 644245094, // 0.6 GiB
  ),
  V2StorageCategoryBytes(
    category: V2StorageCategory.previews,
    bytes: 429496730, // 0.4 GiB
  ),
];

/// The five categories the breakdown is specified to report.
const _fiveCategoryEntries = <V2StorageCategoryBytes>[
  V2StorageCategoryBytes(
    category: V2StorageCategory.chats,
    bytes: 536870912, // 512 MiB
  ),
  V2StorageCategoryBytes(
    category: V2StorageCategory.artifacts,
    bytes: 268435456, // 256 MiB
  ),
  V2StorageCategoryBytes(
    category: V2StorageCategory.uploads,
    bytes: 134217728, // 128 MiB
  ),
  V2StorageCategoryBytes(
    category: V2StorageCategory.memory,
    bytes: 67108864, // 64 MiB
  ),
  V2StorageCategoryBytes(
    category: V2StorageCategory.cache,
    bytes: 67108864, // 64 MiB
  ),
];

V2StorageBreakdownData _data({
  int usedBytes = 3221225472, // 3 GiB
  int totalBytes = 5368709120, // 5 GiB
  List<V2StorageCategoryBytes> entries = _entries,
  V2StorageBreakdownStatus status = V2StorageBreakdownStatus.content,
  String? errorMessage,
  String amountLabel = '',
  String totalLabel = '',
  V2StorageCategory? selectedCategory,
  VoidCallback? onRetry,
  VoidCallback? onEmptyAction,
  ValueChanged<V2StorageCategory>? onCategoryTap,
}) {
  return V2StorageBreakdownData(
    usedBytes: usedBytes,
    totalBytes: totalBytes,
    entries: entries,
    status: status,
    amountLabel: amountLabel,
    totalLabel: totalLabel,
    selectedCategory: selectedCategory,
    errorMessage:
        errorMessage ??
        'Storage could not be loaded. Check your connection and try again.',
    onRetry: onRetry,
    onEmptyAction: onEmptyAction,
    onCategoryTap: onCategoryTap,
  );
}

Widget _app(Widget child, {ThemeData? theme, double textScale = 1}) {
  return MaterialApp(
    theme: theme ?? OTheme.light(),
    builder: textScale == 1
        ? null
        : (context, content) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: content!,
          ),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(OSpace.l),
        child: child,
      ),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
  double textScale = 1,
}) async {
  await tester.pumpWidget(_app(child, theme: theme, textScale: textScale));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// Pumps on a 320 dp phone at 200 % text with reduced motion.
Future<void> _pumpNarrow(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
}) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? OTheme.light(),
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 640),
          textScaler: TextScaler.linear(2),
          disableAnimations: true,
        ),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(OSpace.l),
            child: child,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  group('formatStorageBytes', () {
    test('rounds to short, readable units', () {
      expect(formatStorageBytes(0), '0 B');
      expect(formatStorageBytes(-10), '0 B');
      expect(formatStorageBytes(512), '512 B');
      expect(formatStorageBytes(1536), '1.5 KB');
      expect(formatStorageBytes(1024 * 1024), '1 MB');
      expect(formatStorageBytes(3221225472), '3 GB');
      expect(formatStorageBytes(1099511627776), '1 TB');
    });

    test('never leaves a trailing .0', () {
      expect(formatStorageBytes(2048), '2 KB');
      expect(formatStorageBytes(10 * 1024), '10 KB');
    });
  });

  group('storagePercentageSplit', () {
    test('always adds up to 100', () {
      expect(storagePercentageSplit([1, 1, 1, 0]), [34, 33, 33, 0]);
      expect(storagePercentageSplit([40, 27, 20, 13]), [40, 27, 20, 13]);
      expect(storagePercentageSplit([0, 0, 0, 0]), [0, 0, 0, 0]);
      expect(storagePercentageSplit(const []), const <int>[]);
    });

    test('clamps negative bytes and gives the remainder to the largest', () {
      expect(storagePercentageSplit([-1, 1, 0]), [0, 100, 0]);
    });
  });

  testWidgets('renders the bar, total and four-category legend', (
    tester,
  ) async {
    await _pump(tester, StorageBreakdown(data: _data()));

    // No header chrome: the bar and the legend are the breakdown.
    expect(find.text('STORAGE'), findsNothing);
    expect(find.text('3 GB'), findsOneWidget);
    expect(find.text('of 5 GB'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('storage-breakdown-chart')),
      findsOneWidget,
    );

    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('Artifacts'), findsOneWidget);
    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('Previews'), findsOneWidget);

    expect(find.text('1.2 GB'), findsOneWidget);
    expect(find.text('819 MB'), findsOneWidget);
    expect(find.text('614 MB'), findsOneWidget);
    expect(find.text('410 MB'), findsOneWidget);

    expect(find.text('40%'), findsOneWidget);
    expect(find.text('27%'), findsOneWidget);
    expect(find.text('20%'), findsOneWidget);
    expect(find.text('13%'), findsOneWidget);
  });

  testWidgets('renders in dark theme', (tester) async {
    await _pump(tester, StorageBreakdown(data: _data()), theme: OTheme.dark());

    // No header chrome: the bar and the legend are the breakdown.
    expect(find.text('STORAGE'), findsNothing);
    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('Previews'), findsOneWidget);
    expect(find.text('13%'), findsOneWidget);
  });

  testWidgets('announces the whole breakdown in one chart label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, StorageBreakdown(data: _data()));

    final chart = tester.getSemantics(
      find.byKey(const ValueKey('storage-breakdown-chart')),
    );
    expect(chart.label, contains('Storage: 3 GB used of 5 GB'));
    expect(chart.label, contains('Chats 1.2 GB, 40%'));
    expect(chart.label, contains('Previews 410 MB, 13%'));

    expect(find.bySemanticsLabel('Chats, 1.2 GB, 40%'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('tapping a legend row reports the category', (tester) async {
    V2StorageCategory? tapped;
    await _pump(
      tester,
      StorageBreakdown(
        data: _data(onCategoryTap: (category) => tapped = category),
      ),
    );

    await tester.ensureVisible(find.text('Memory'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Memory'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tapped, V2StorageCategory.memory);
  });

  testWidgets('the selected category highlights its legend row', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      StorageBreakdown(data: _data(selectedCategory: V2StorageCategory.chats)),
    );

    // One bar and one legend: the selected row is marked, not duplicated.
    expect(find.text('1.2 GB'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Chats, 1.2 GB, 40%, selected'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('un-wired data shows the empty state and its next action', (
    tester,
  ) async {
    var starts = 0;
    await _pump(
      tester,
      StorageBreakdown(
        data: V2StorageBreakdownData(onEmptyAction: () => starts++),
      ),
    );

    // No header chrome: the bar and the legend are the breakdown.
    expect(find.text('STORAGE'), findsNothing);
    expect(find.text('Nothing stored yet'), findsOneWidget);
    expect(
      find.text(
        'Chats, artifacts, uploads, memory, and cache appear here as you use '
        'Ovid.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('storage-breakdown-chart')), findsNothing);

    await tester.tap(find.text('Start a chat'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(starts, 1);
  });

  testWidgets('content with zero usage falls back to the empty state', (
    tester,
  ) async {
    await _pump(
      tester,
      StorageBreakdown(
        data: _data(
          usedBytes: 0,
          totalBytes: 3 * 1024 * 1024 * 1024,
          entries: const <V2StorageCategoryBytes>[],
        ),
      ),
    );

    expect(find.text('Nothing stored yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-breakdown-chart')), findsNothing);
  });

  testWidgets('an explicit empty status hides the chart', (tester) async {
    await _pump(
      tester,
      StorageBreakdown(data: _data(status: V2StorageBreakdownStatus.empty)),
    );

    expect(find.text('Nothing stored yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-breakdown-chart')), findsNothing);
  });

  testWidgets('loading shows skeletons instead of zero usage', (tester) async {
    await _pump(
      tester,
      StorageBreakdown(data: _data(status: V2StorageBreakdownStatus.loading)),
    );

    expect(
      find.byKey(const ValueKey('storage-breakdown-loading')),
      findsOneWidget,
    );
    expect(find.byType(OSkeleton), findsWidgets);
    expect(find.byKey(const ValueKey('storage-breakdown-chart')), findsNothing);
    expect(find.text('Chats'), findsNothing);
  });

  testWidgets('error state explains the failure and retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      StorageBreakdown(
        data: _data(
          status: V2StorageBreakdownStatus.error,
          errorMessage: 'The storage service is offline.',
          onRetry: () => retries++,
        ),
      ),
    );

    expect(find.text('Storage unavailable'), findsOneWidget);
    expect(find.text('The storage service is offline.'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(retries, 1);
  });

  testWidgets('a zero-fraction category still gets a legend row', (
    tester,
  ) async {
    await _pump(
      tester,
      StorageBreakdown(
        data: _data(
          usedBytes: 3,
          totalBytes: 0,
          entries: const [
            V2StorageCategoryBytes(category: V2StorageCategory.chats, bytes: 1),
            V2StorageCategoryBytes(
              category: V2StorageCategory.artifacts,
              bytes: 1,
            ),
            V2StorageCategoryBytes(
              category: V2StorageCategory.memory,
              bytes: 1,
            ),
            V2StorageCategoryBytes(
              category: V2StorageCategory.previews,
              bytes: 0,
            ),
          ],
        ),
      ),
    );

    expect(find.text('34%'), findsOneWidget);
    expect(find.text('33%'), findsNWidgets(2));
    expect(find.text('0%'), findsOneWidget);
    expect(find.text('0 B'), findsOneWidget);
  });

  testWidgets('renders the five specified categories with sizes and shares', (
    tester,
  ) async {
    await _pump(
      tester,
      StorageBreakdown(
        data: _data(
          usedBytes: 1073741824, // 1 GiB
          totalBytes: 3221225472, // 3 GiB
          entries: _fiveCategoryEntries,
        ),
      ),
    );

    for (final label in ['Chats', 'Artifacts', 'Uploads', 'Memory', 'Cache']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Previews'), findsNothing);

    expect(find.text('512 MB'), findsOneWidget);
    expect(find.text('256 MB'), findsOneWidget);
    expect(find.text('128 MB'), findsOneWidget);
    expect(find.text('64 MB'), findsNWidgets(2));
    expect(find.text('1 GB'), findsOneWidget);
    expect(find.text('of 3 GB'), findsOneWidget);

    expect(find.text('50%'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    expect(find.text('13%'), findsOneWidget);
    expect(find.text('6%'), findsNWidgets(2));
  });

  testWidgets('uploads and cache get their own accessible slice labels', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      StorageBreakdown(
        data: _data(usedBytes: 1073741824, entries: _fiveCategoryEntries),
      ),
    );

    expect(find.bySemanticsLabel('Uploads, 128 MB, 13%'), findsOneWidget);
    expect(find.bySemanticsLabel('Cache, 64 MB, 6%'), findsOneWidget);

    final chart = tester.widget<Semantics>(
      find.byKey(const ValueKey('storage-breakdown-chart')),
    );
    expect(chart.properties.label, contains('Uploads 128 MB, 13%'));
    expect(chart.properties.label, contains('Cache 64 MB, 6%'));
    semantics.dispose();
  });

  testWidgets('pre-formatted labels override the byte formatter', (
    tester,
  ) async {
    await _pump(
      tester,
      StorageBreakdown(
        data: _data(amountLabel: '1.2 GB', totalLabel: '3 GB'),
      ),
    );

    expect(find.text('1.2 GB'), findsWidgets);
    expect(find.text('of 3 GB'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets(
      'five categories fit 320 dp at 200 % text (${dark ? 'dark' : 'light'})',
      (tester) async {
        await _pumpNarrow(
          tester,
          StorageBreakdown(
            data: _data(usedBytes: 1073741824, entries: _fiveCategoryEntries),
          ),
          theme: dark ? OTheme.dark() : OTheme.light(),
        );

        expect(tester.takeException(), isNull);
        for (final label in [
          'Chats',
          'Artifacts',
          'Uploads',
          'Memory',
          'Cache',
        ]) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
        expect(find.text('50%'), findsOneWidget);
        expect(find.text('6%'), findsNWidgets(2));
      },
    );
  }

  testWidgets('320 dp at 200 % text lays out without overflow (light)', (
    tester,
  ) async {
    await _pumpNarrow(tester, StorageBreakdown(data: _data()));

    expect(tester.takeException(), isNull);
    // No header chrome: the bar and the legend are the breakdown.
    expect(find.text('STORAGE'), findsNothing);
    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('Artifacts'), findsOneWidget);
    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('Previews'), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('13%'), findsOneWidget);
  });

  testWidgets('320 dp at 200 % text lays out without overflow (dark)', (
    tester,
  ) async {
    await _pumpNarrow(
      tester,
      StorageBreakdown(data: _data()),
      theme: OTheme.dark(),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('Previews'), findsOneWidget);
  });

  testWidgets('loading, empty and error states fit 320 dp at 200 % text', (
    tester,
  ) async {
    for (final status in <V2StorageBreakdownStatus>[
      V2StorageBreakdownStatus.loading,
      V2StorageBreakdownStatus.empty,
      V2StorageBreakdownStatus.error,
    ]) {
      await _pumpNarrow(
        tester,
        StorageBreakdown(
          data: _data(status: status, onRetry: () {}),
        ),
      );
      expect(tester.takeException(), isNull, reason: 'status $status');
    }
  });

  testWidgets('empty and error states fit 320 dp at 200 % text in dark', (
    tester,
  ) async {
    for (final status in <V2StorageBreakdownStatus>[
      V2StorageBreakdownStatus.empty,
      V2StorageBreakdownStatus.error,
    ]) {
      await _pumpNarrow(
        tester,
        StorageBreakdown(
          data: _data(status: status, onRetry: () {}),
        ),
        theme: OTheme.dark(),
      );
      expect(tester.takeException(), isNull, reason: 'status $status');
    }
  });

  test('defaults carry no sample usage', () {
    const data = V2StorageBreakdownData();
    expect(data.usedBytes, 0);
    expect(data.totalBytes, 0);
    expect(data.entries, isEmpty);
    expect(data.amountLabel, isEmpty);
    expect(data.totalLabel, isEmpty);
    expect(data.selectedCategory, isNull);
    expect(data.onEmptyAction, isNull);
    expect(data.onRetry, isNull);
    expect(data.onCategoryTap, isNull);
  });

  group('reconcileStorageBreakdown', () {
    test('adds an Other bucket when categories under-report the total', () {
      const used = 4 * 1024 * 1024 * 1024;
      final result = reconcileStorageBreakdown(_entries, used);

      expect(result.usedBytes, used);
      expect(result.addsUp, isTrue);
      expect(result.entries.last.category, V2StorageCategory.other);
      expect(result.entries.last.safeBytes, used - 3221225472);
    });

    test('keeps a category list that already adds up unchanged', () {
      final sum = _entries.fold<int>(0, (total, entry) => total + entry.bytes);
      final result = reconcileStorageBreakdown(_entries, sum);

      expect(result.entries.length, _entries.length);
      expect(result.usedBytes, sum);
      expect(result.addsUp, isTrue);
    });

    test('never lets the heading hide bytes the categories do report', () {
      final sum = _entries.fold<int>(0, (total, entry) => total + entry.bytes);
      final result = reconcileStorageBreakdown(_entries, sum - 1);

      expect(result.usedBytes, sum);
      expect(result.entries.any((entry) => entry.category == V2StorageCategory.other),
          isFalse);
      expect(result.addsUp, isTrue);
    });
  });

  testWidgets('an under-reported breakdown renders Other and still sums to '
      '100 %', (tester) async {
    await _pump(
      tester,
      StorageBreakdown(
        data: _data(
          usedBytes: 4 * 1024 * 1024 * 1024,
          totalBytes: 5 * 1024 * 1024 * 1024,
        ),
      ),
    );

    expect(find.text('Other'), findsOneWidget);
    expect(find.text('4 GB'), findsOneWidget);

    // The shares are computed from the reconciled buckets, so they always add
    // up to 100 including the Other remainder.
    final breakdown = tester.widget<StorageBreakdown>(
      find.byType(StorageBreakdown),
    );
    final entries = reconcileStorageBreakdown(
      breakdown.data.entries,
      breakdown.data.usedBytes,
    ).entries;
    final shares = storagePercentageSplit([
      for (final entry in entries) entry.safeBytes,
    ]);
    expect(shares.fold<int>(0, (sum, share) => sum + share), 100);
    expect(shares.length, entries.length);
  });
}
