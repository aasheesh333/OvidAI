import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/storage_breakdown.dart';
import 'package:ovid_ai/ui/v2/settings/storage_page.dart';

Widget _app(
  Widget home, {
  required ThemeData theme,
  TextScaler textScaler = TextScaler.noScaling,
  bool disableAnimations = false,
}) => MaterialApp(
  theme: theme,
  home: MediaQuery(
    data: MediaQueryData(
      textScaler: textScaler,
      disableAnimations: disableAnimations,
    ),
    child: home,
  ),
);

V2StoragePageData _data({
  String planName = 'Free plan',
  bool showCache = true,
  VoidCallback? onClearCache,
  Future<int> Function()? onClearCacheAndReport,
  VoidCallback? onGoUpgrade,
}) {
  return V2StoragePageData(
    usedGb: 1.2,
    totalGb: 3,
    planName: planName,
    slices: const [
      V2StorageSlice(label: 'Artifacts', sizeLabel: '410 MB', valueGb: 0.41),
      V2StorageSlice(label: 'Sessions', sizeLabel: '620 MB', valueGb: 0.62),
      V2StorageSlice(label: 'Cache', sizeLabel: '170 MB', valueGb: 0.17),
    ],
    cacheGb: 0.17,
    cacheSizeLabel: '170 MB',
    showCache: showCache,
    onClearCache: onClearCache,
    onClearCacheAndReport: onClearCacheAndReport,
    onGoUpgrade: onGoUpgrade,
  );
}

Future<void> _pumpAt320(
  WidgetTester tester,
  V2StoragePageData data, {
  required ThemeData theme,
  bool disableAnimations = false,
}) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    _app(
      StoragePage(data: data),
      theme: theme,
      textScaler: const TextScaler.linear(2),
      disableAnimations: disableAnimations,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets('renders one bar, the legend and one clean-up row', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(StoragePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('Free plan'), findsOneWidget);
    expect(find.text('1.2 GB'), findsOneWidget);
    expect(find.text('of 3 GB'), findsOneWidget);

    // The legend is the breakdown.
    expect(find.text('Artifacts'), findsOneWidget);
    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('Cache'), findsOneWidget);
    expect(find.text('410 MB'), findsOneWidget);
    expect(find.text('620 MB'), findsOneWidget);
    expect(find.text('170 MB'), findsWidgets);

    // One clean-up row, no card chrome.
    expect(find.text('Clear cache'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('storage-clear-cache-row')),
      findsOneWidget,
    );
  });

  testWidgets('deleted dashboard sections are gone', (tester) async {
    await tester.pumpWidget(
      _app(StoragePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Need more room?'), findsNothing);
    expect(find.text('ITEMS BY SIZE'), findsNothing);
    expect(find.text('Q3 launch plan'), findsNothing);
    expect(find.byKey(const ValueKey('storage-quota-bar')), findsNothing);
    expect(find.textContaining('Cached offline data'), findsNothing);
    expect(find.text('3 GB included'), findsNothing);
    expect(find.text('WHAT USES SPACE'), findsNothing);
    expect(find.text('Clear previews'), findsNothing);
    expect(find.text('Delete old chats'), findsNothing);
    expect(find.text('Trash'), findsNothing);
    expect(find.text('Empty'), findsNothing);
  });

  testWidgets('renders the shared breakdown with the page slices', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(StoragePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.byType(StorageBreakdown), findsOneWidget);
    final breakdown = tester.widget<StorageBreakdown>(
      find.byType(StorageBreakdown),
    );
    expect(breakdown.data.amountLabel, isEmpty);
    expect(breakdown.data.totalLabel, '3 GB');
    expect(breakdown.data.entries.map((entry) => entry.category), [
      V2StorageCategory.artifacts,
      V2StorageCategory.chats,
      V2StorageCategory.cache,
    ]);
    expect(breakdown.data.entries.map((entry) => entry.sizeLabel), [
      '410 MB',
      '620 MB',
      '170 MB',
    ]);
    expect(
      find.byKey(const ValueKey('storage-breakdown-chart')),
      findsOneWidget,
    );
  });

  testWidgets('renders in dark mode', (tester) async {
    await tester.pumpWidget(
      _app(StoragePage(data: _data()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('Clear cache'), findsOneWidget);
    expect(find.text('Chats'), findsOneWidget);
  });

  testWidgets('shows a skeleton while loading', (tester) async {
    await tester.pumpWidget(
      _app(
        StoragePage(data: V2StoragePageData(loading: true, onRetry: () {})),
        theme: OTheme.light(),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Clear cache'), findsNothing);
    expect(find.text('Storage'), findsOneWidget);
  });

  testWidgets('empty storage offers the plans action', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      _app(
        StoragePage(
          data: V2StoragePageData(
            usedGb: 0,
            totalGb: 0,
            onGoUpgrade: () => opened = true,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Storage is empty'), findsOneWidget);
    await tester.tap(find.text('See plans'));
    expect(opened, isTrue);
  });

  testWidgets('a known plan with no usage keeps the clean-up row', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        StoragePage(
          data: const V2StoragePageData(
            planName: 'Free plan',
            usedGb: 0,
            totalGb: 3,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Storage is empty'), findsNothing);
    expect(find.text('Nothing stored yet'), findsOneWidget);
    expect(find.text('Clear cache'), findsOneWidget);
  });

  testWidgets('a known plan alone is not the page-level empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        StoragePage(data: const V2StoragePageData(planName: 'Plus plan')),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    // The plan table supplies 15 GB even when the caller omits the total.
    expect(find.text('Storage is empty'), findsNothing);
    expect(find.text('Nothing stored yet'), findsOneWidget);
    expect(find.text('Clear cache'), findsOneWidget);
  });

  testWidgets('an un-wired data object shows the empty state', (tester) async {
    await tester.pumpWidget(
      _app(StoragePage(data: const V2StoragePageData()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Storage is empty'), findsOneWidget);
  });

  testWidgets('clear cache fires the injected callback', (tester) async {
    var cleared = false;
    await tester.pumpWidget(
      _app(
        StoragePage(data: _data(onClearCache: () => cleared = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clear cache'));
    await tester.pump();
    expect(cleared, isTrue);
    expect(find.text('Cache cleared.'), findsOneWidget);
  });

  testWidgets('clear cache reports the bytes actually freed', (tester) async {
    const freedBytes = 142 * 1024 * 1024;
    await tester.pumpWidget(
      _app(
        StoragePage(data: _data(onClearCacheAndReport: () async => freedBytes)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clear cache'));
    await tester.pump();

    expect(find.text('Freed 142 MB of cache.'), findsOneWidget);
  });

  testWidgets('a fully clear cache says so instead of claiming fake bytes', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        StoragePage(data: _data(onClearCacheAndReport: () async => 0)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clear cache'));
    await tester.pump();

    expect(find.text('Cache is already empty.'), findsOneWidget);
  });

  testWidgets('the clean-up row drops the size value without a local cache', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(StoragePage(data: _data(showCache: false)), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    // The row stays — the phone still has a temporary directory — but the
    // size value is only shown when the caller tracks a local cache.
    final row = find.byKey(const ValueKey('storage-clear-cache-row'));
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text('170 MB')),
      findsNothing,
    );
    // The cache category still explains where the space went.
    expect(find.text('Cache'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets('fits 320 dp at 200% text (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      await _pumpAt320(
        tester,
        _data(onClearCache: () {}, onGoUpgrade: () {}),
        theme: dark ? OTheme.dark() : OTheme.light(),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Storage'), findsOneWidget);
      expect(find.text('Clear cache'), findsOneWidget);
      expect(find.text('Artifacts'), findsOneWidget);
      expect(find.text('Chats'), findsOneWidget);
      expect(find.text('Cache'), findsOneWidget);
    });

    testWidgets(
      '200% text keeps the clean-up row readable (${dark ? 'dark' : 'light'})',
      (tester) async {
        await _pumpAt320(
          tester,
          _data(onClearCache: () {}),
          theme: dark ? OTheme.dark() : OTheme.light(),
        );

        final label = tester.renderObject<RenderParagraph>(
          find.text('Clear cache'),
        );
        expect(label.size.width, greaterThan(80));
      },
    );
  }

  for (final dark in [false, true]) {
    testWidgets(
      'empty and error states fit 320 dp at 200% (${dark ? 'dark' : 'light'})',
      (tester) async {
        await _pumpAt320(
          tester,
          const V2StoragePageData(totalGb: 0, onGoUpgrade: null, onRetry: null),
          theme: dark ? OTheme.dark() : OTheme.light(),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('Storage is empty'), findsOneWidget);

        await _pumpAt320(
          tester,
          V2StoragePageData(
            errorMessage: 'Storage details could not load.',
            onRetry: () {},
          ),
          theme: dark ? OTheme.dark() : OTheme.light(),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('Try again'), findsOneWidget);
      },
    );
  }

  testWidgets('reduced motion keeps every section visible', (tester) async {
    await _pumpAt320(
      tester,
      _data(onGoUpgrade: () {}),
      theme: OTheme.light(),
      disableAnimations: true,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('1.2 GB'), findsOneWidget);
    expect(find.text('Clear cache'), findsOneWidget);
    expect(find.text('Artifacts'), findsOneWidget);
  });

  testWidgets('error state offers a retry', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      _app(
        StoragePage(
          data: V2StoragePageData(
            errorMessage: 'Storage details could not load.',
            onRetry: () => retried = true,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Storage details could not load.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, isTrue);
  });

  test('plan quotas match Free 3, Go 5, Plus 15 and Pro 75 GB', () {
    expect(v2PlanStorageQuotaGb('Free plan'), 3);
    expect(v2PlanStorageQuotaGb('Go plan'), 5);
    expect(v2PlanStorageQuotaGb('Plus plan'), 15);
    expect(v2PlanStorageQuotaGb('Pro plan'), 75);
    expect(v2PlanStorageQuotaGb('3x'), 5);
    expect(v2PlanStorageQuotaGb('7x'), 15);
    expect(v2PlanStorageQuotaGb('15x'), 75);
    expect(v2PlanStorageQuotaGb('Ovid Plus'), 15);
    expect(v2PlanStorageQuotaGb('Enterprise'), isNull);
  });

  testWidgets('the shown quota comes from the plan, not a stale total', (
    tester,
  ) async {
    const expected = <String, String>{
      'Free plan': '3',
      'Go plan': '5',
      'Plus plan': '15',
      'Pro plan': '75',
    };
    for (final entry in expected.entries) {
      await tester.pumpWidget(
        _app(
          StoragePage(
            data: V2StoragePageData(
              planName: entry.key,
              usedGb: 1,
              // A stale caller value that must not win over the plan.
              totalGb: 3,
              slices: const [
                V2StorageSlice(label: 'Chats', sizeLabel: '1 GB', valueGb: 1),
              ],
            ),
          ),
          theme: OTheme.light(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('of ${entry.value} GB'), findsOneWidget);
      expect(find.text('1 GB'), findsWidgets);
    }
  });

  testWidgets('a breakdown that under-reports gets an Other bucket so it '
      'adds up to the shown total', (tester) async {
    await tester.pumpWidget(
      _app(
        StoragePage(
          data: V2StoragePageData(
            planName: 'Go plan',
            usedGb: 1.5,
            totalGb: 5,
            slices: const [
              V2StorageSlice(
                label: 'Artifacts',
                sizeLabel: '410 MB',
                valueGb: 0.41,
              ),
              V2StorageSlice(
                label: 'Sessions',
                sizeLabel: '620 MB',
                valueGb: 0.62,
              ),
              V2StorageSlice(
                label: 'Cache',
                sizeLabel: '170 MB',
                valueGb: 0.17,
              ),
            ],
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final breakdown = tester.widget<StorageBreakdown>(
      find.byType(StorageBreakdown),
    );
    final reconciled = reconcileStorageBreakdown(
      breakdown.data.entries,
      breakdown.data.usedBytes,
    );

    expect(reconciled.addsUp, isTrue);
    expect(reconciled.usedBytes, 1.5 * 1024 * 1024 * 1024);
    expect(breakdown.data.entries.last.category, V2StorageCategory.other);
    expect(
      breakdown.data.entries.fold<int>(0, (sum, entry) => sum + entry.bytes),
      breakdown.data.usedBytes,
    );
    expect(find.text('Other'), findsOneWidget);
  });

  testWidgets('a breakdown that reports more than the total wins in both '
      'places', (tester) async {
    await tester.pumpWidget(
      _app(
        StoragePage(
          data: V2StoragePageData(
            planName: 'Free plan',
            usedGb: 1,
            totalGb: 3,
            slices: const [
              V2StorageSlice(
                label: 'Artifacts',
                sizeLabel: '700 MB',
                valueGb: 0.7,
              ),
              V2StorageSlice(
                label: 'Sessions',
                sizeLabel: '500 MB',
                valueGb: 0.5,
              ),
            ],
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    // The detail sums to 1.2 GB, so the heading uses 1.2 GB too instead of
    // contradicting the legend with the stale 1.0 GB total.
    expect(find.text('1.2 GB'), findsOneWidget);
    expect(find.text('of 3 GB'), findsOneWidget);
    expect(find.text('Other'), findsNothing);
  });

  testWidgets('missing data renders a dash, never a zero', (tester) async {
    await tester.pumpWidget(
      _app(
        StoragePage(
          data: const V2StoragePageData(
            usedGb: 0.5,
            slices: [
              V2StorageSlice(label: 'Chats', sizeLabel: '512 MB', valueGb: 0.5),
            ],
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    // No plan and no total: capacity is unknown, not "0 GB".
    expect(find.text('of —'), findsOneWidget);
    // No cache figure: the row says so instead of claiming "0 MB".
    final row = find.byKey(const ValueKey('storage-clear-cache-row'));
    expect(find.descendant(of: row, matching: find.text('—')), findsOneWidget);
  });

  testWidgets('a category with no data is omitted from the bar and legend', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        StoragePage(
          data: const V2StoragePageData(
            planName: 'Free plan',
            usedGb: 1,
            totalGb: 3,
            slices: [
              V2StorageSlice(label: 'Chats', sizeLabel: '1 GB', valueGb: 1),
              V2StorageSlice(label: 'Artifacts', sizeLabel: '0 MB', valueGb: 0),
            ],
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('Artifacts'), findsNothing);
    expect(find.text('0%'), findsNothing);
  });

  testWidgets('clear cache updates the real size in the row and the legend', (
    tester,
  ) async {
    const freed = 142 * 1024 * 1024;
    await tester.pumpWidget(
      _app(
        StoragePage(data: _data(onClearCacheAndReport: () async => freed)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('storage-clear-cache-row'));
    expect(
      find.descendant(of: row, matching: find.text('170 MB')),
      findsOneWidget,
    );

    await tester.tap(find.text('Clear cache'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Freed 142 MB of cache.'), findsOneWidget);
    // 0.17 GiB − 142 MB = 32 MB, shown in the row and in the legend.
    expect(
      find.descendant(of: row, matching: find.text('32 MB')),
      findsOneWidget,
    );
    expect(find.text('32 MB'), findsWidgets);
    expect(find.text('170 MB'), findsNothing);
  });

  testWidgets('clearing shows progress and blocks a second tap', (
    tester,
  ) async {
    final completer = Completer<int>();
    var calls = 0;
    await tester.pumpWidget(
      _app(
        StoragePage(
          data: _data(
            onClearCacheAndReport: () {
              calls++;
              return completer.future;
            },
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('storage-clear-cache-row'));
    await tester.tap(find.text('Clear cache'));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('storage-clear-cache-progress')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.text('170 MB')),
      findsNothing,
    );

    await tester.tap(row, warnIfMissed: false);
    await tester.pump();
    expect(calls, 1);

    completer.complete(142 * 1024 * 1024);
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('storage-clear-cache-progress')),
      findsNothing,
    );
    expect(find.text('Freed 142 MB of cache.'), findsOneWidget);
  });

  testWidgets('the clear row announces what it will free', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        StoragePage(data: _data(onClearCache: () {})),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel('Clear cache, 170 MB will be freed'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('fits 320 to 1280 at 1x and 2x, light and dark', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final width in [320.0, 360.0, 412.0, 600.0, 800.0, 1024.0, 1280.0]) {
      for (final scale in [1.0, 2.0]) {
        for (final dark in [false, true]) {
          tester.view.physicalSize = Size(width, 900);
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? OTheme.dark() : OTheme.light(),
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 900),
                  textScaler: TextScaler.linear(scale),
                ),
                child: StoragePage(data: _data(onClearCache: () {})),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));

          expect(
            tester.takeException(),
            isNull,
            reason: '$width @ ${scale}x ${dark ? 'dark' : 'light'}',
          );
          if (width >= 600) {
            expect(
              tester
                  .getSize(find.byKey(const ValueKey('storage-breakdown')))
                  .width,
              lessThanOrEqualTo(640),
              reason: '$width content cap',
            );
          }
        }
      }
    }
  });

  testWidgets('a long GB string does not overflow at 320 dp', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        StoragePage(
          data: const V2StoragePageData(
            totalGb: 999999.9,
            usedGb: 123456.7,
            slices: [
              V2StorageSlice(
                label: 'Artifacts',
                sizeLabel: '123456.7 GB',
                valueGb: 123456.7,
              ),
            ],
            cacheGb: 12345.6,
            cacheSizeLabel: '12345.6 GB',
            onClearCache: _noop,
          ),
        ),
        theme: OTheme.dark(),
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);
  });
}

void _noop() {}
