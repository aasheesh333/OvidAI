import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  VoidCallback? onClearPreviews,
  VoidCallback? onClearCache,
  Future<int> Function()? onClearCacheAndReport,
  VoidCallback? onDeleteOldChats,
  VoidCallback? onEmptyTrash,
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
    previewSizeLabel: '80 MB',
    trashItems: 12,
    trashSizeLabel: '140 MB',
    onClearPreviews: onClearPreviews,
    onClearCache: onClearCache,
    onClearCacheAndReport: onClearCacheAndReport,
    onDeleteOldChats: onDeleteOldChats,
    onEmptyTrash: onEmptyTrash,
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
  testWidgets('renders one bar, its legend and the clean-up list', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(StoragePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('Free plan'), findsOneWidget);
    expect(find.text('WHAT USES SPACE'), findsOneWidget);
    expect(find.text('1.2 GB'), findsOneWidget);
    expect(find.text('of 3.0 GB'), findsOneWidget);

    expect(find.text('Artifacts'), findsOneWidget);
    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('Cache'), findsOneWidget);
    expect(find.text('410 MB'), findsOneWidget);
    expect(find.text('620 MB'), findsOneWidget);
    expect(find.text('170 MB'), findsWidgets);

    expect(find.text('Clear previews'), findsOneWidget);
    expect(find.text('Clear cache'), findsOneWidget);
    expect(find.text('Delete old chats'), findsOneWidget);
    expect(find.text('Trash'), findsOneWidget);
    expect(find.text('140 MB'), findsOneWidget);
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
    expect(breakdown.data.totalLabel, '3.0 GB');
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
    expect(find.text('Clear previews'), findsOneWidget);
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
    expect(find.text('Clear previews'), findsNothing);
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

  testWidgets('a known plan with no usage keeps the clean-up list', (
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
    expect(find.text('Clear previews'), findsOneWidget);
    expect(find.text('Clear cache'), findsOneWidget);
  });

  testWidgets('clear previews falls back to the real image cache', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(StoragePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Clear').first);
    await tester.tap(find.text('Clear').first);
    await tester.pump();

    expect(find.text('Previews cleared.'), findsOneWidget);
  });

  testWidgets('an un-wired data object shows the empty state', (tester) async {
    await tester.pumpWidget(
      _app(StoragePage(data: const V2StoragePageData()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Storage is empty'), findsOneWidget);
  });

  testWidgets('clear previews fires the primary callback', (tester) async {
    var cleared = false;
    await tester.pumpWidget(
      _app(
        StoragePage(data: _data(onClearPreviews: () => cleared = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Clear').first);
    await tester.tap(find.text('Clear').first);
    expect(cleared, isTrue);
  });

  testWidgets('empty trash fires its callback', (tester) async {
    var emptied = false;
    await tester.pumpWidget(
      _app(
        StoragePage(data: _data(onEmptyTrash: () => emptied = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Empty'));
    await tester.tap(find.text('Empty'));
    expect(emptied, isTrue);
  });

  testWidgets('clear cache fires its callback', (tester) async {
    var cleared = false;
    await tester.pumpWidget(
      _app(
        StoragePage(data: _data(onClearCache: () => cleared = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Clear').at(1));
    await tester.tap(find.text('Clear').at(1));
    expect(cleared, isTrue);
  });

  testWidgets('clear cache is hidden when the device has no local cache', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(StoragePage(data: _data(showCache: false)), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Clear cache'), findsNothing);
    expect(find.text('Clear'), findsOneWidget);
    // The cache category still explains where the space went.
    expect(find.text('Cache'), findsOneWidget);
  });

  testWidgets('delete old chats fires its callback', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _app(
        StoragePage(data: _data(onDeleteOldChats: () => tapped = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Delete old chats'));
    await tester.tap(find.text('Delete old chats'));
    expect(tapped, isTrue);
  });

  testWidgets('a missing callback leaves the action disabled and announced', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(StoragePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    final node = tester.getSemantics(
      find.widgetWithText(OutlinedButton, 'Empty'),
    );
    expect(node.flagsCollection.isEnabled, Tristate.isFalse);
    expect(node.flagsCollection.isButton, isTrue);
    semantics.dispose();
  });

  for (final dark in [false, true]) {
    testWidgets('fits 320 dp at 200% text (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      await _pumpAt320(
        tester,
        _data(
          onClearPreviews: () {},
          onClearCache: () {},
          onDeleteOldChats: () {},
          onEmptyTrash: () {},
          onGoUpgrade: () {},
        ),
        theme: dark ? OTheme.dark() : OTheme.light(),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Storage'), findsOneWidget);
      expect(find.text('Clear previews'), findsOneWidget);
      expect(find.text('Empty'), findsOneWidget);
      expect(find.text('Artifacts'), findsOneWidget);
      expect(find.text('Chats'), findsOneWidget);
      expect(find.text('Cache'), findsOneWidget);
    });

    testWidgets(
      '200% text keeps row labels readable (${dark ? 'dark' : 'light'})',
      (tester) async {
        await _pumpAt320(
          tester,
          _data(onClearPreviews: () {}, onEmptyTrash: () {}),
          theme: dark ? OTheme.dark() : OTheme.light(),
        );

        // Before the responsive row the trailing button took almost the whole
        // row and these labels were squeezed to a couple of pixels wide.
        final trash = tester.renderObject<RenderParagraph>(
          find.text('Delete old chats'),
        );
        expect(trash.size.width, greaterThan(80));
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
    expect(find.text('Clear previews'), findsOneWidget);
    expect(find.text('Delete old chats'), findsOneWidget);
    expect(find.text('WHAT USES SPACE'), findsOneWidget);
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
    expect(v2PlanStorageQuotaGb('Enterprise'), isNull);
  });

  testWidgets('the shown quota comes from the plan, not a stale total', (
    tester,
  ) async {
    const expected = <String, String>{
      'Free plan': '3.0',
      'Go plan': '5.0',
      'Plus plan': '15.0',
      'Pro plan': '75.0',
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
    expect(find.text('of 3.0 GB'), findsOneWidget);
    expect(find.text('Other'), findsNothing);
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

    await tester.ensureVisible(find.text('Clear').at(1));
    await tester.tap(find.text('Clear').at(1));
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

    await tester.ensureVisible(find.text('Clear').at(1));
    await tester.tap(find.text('Clear').at(1));
    await tester.pump();

    expect(find.text('Cache is already empty.'), findsOneWidget);
  });
}
