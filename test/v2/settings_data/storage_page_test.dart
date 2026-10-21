import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
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
  String? offlineLabel =
      'Cached offline data uses 142 MB on this device. Cloud sync runs automatically.',
  VoidCallback? onClearPreviews,
  VoidCallback? onClearCache,
  VoidCallback? onDeleteOldChats,
  VoidCallback? onEmptyTrash,
  ValueChanged<String>? onLargestItemTap,
  VoidCallback? onGoUpgrade,
}) {
  return V2StoragePageData(
    usedGb: 1.2,
    totalGb: 3,
    slices: const [
      V2StorageSlice(label: 'Chats', sizeLabel: '620 MB', valueGb: 0.62),
      V2StorageSlice(label: 'Artifacts', sizeLabel: '410 MB', valueGb: 0.41),
      V2StorageSlice(label: 'Memory', sizeLabel: '90 MB', valueGb: 0.09),
      V2StorageSlice(label: 'Previews', sizeLabel: '80 MB', valueGb: 0.08),
    ],
    previewSizeLabel: '80 MB',
    cacheSizeLabel: '60 MB',
    trashItems: 12,
    trashSizeLabel: '140 MB',
    largestItems: const [
      V2StorageItem(
        id: 'chat-1',
        name: 'Q3 launch plan',
        detail: 'Chat · 42 files',
        sizeLabel: '180 MB',
      ),
    ],
    offlineLabel: offlineLabel,
    onClearPreviews: onClearPreviews,
    onClearCache: onClearCache,
    onDeleteOldChats: onDeleteOldChats,
    onEmptyTrash: onEmptyTrash,
    onLargestItemTap: onLargestItemTap,
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
  testWidgets('renders the storage donut and legend in light mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(StoragePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    expect(
      find.text('1.2 GB of 3.0 GB cloud storage used · 1.8 GB free'),
      findsOneWidget,
    );
    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('Artifacts'), findsOneWidget);
    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('Previews'), findsOneWidget);
    expect(find.text('620 MB'), findsOneWidget);
    expect(find.text('LARGEST ITEMS'), findsOneWidget);
    expect(find.text('Q3 launch plan'), findsOneWidget);
    expect(find.text('Need more room?'), findsOneWidget);
    expect(find.text('Trash · 12 items'), findsOneWidget);
    expect(
      find.text(
        'Cached offline data uses 142 MB on this device. Cloud sync runs automatically.',
      ),
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
    expect(find.text('See plans'), findsOneWidget);
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
            totalGb: 3,
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

  testWidgets('an un-wired data object shows the empty state', (tester) async {
    await tester.pumpWidget(
      _app(StoragePage(data: const V2StoragePageData()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Storage is empty'), findsOneWidget);
    expect(find.text('40%'), findsNothing);
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

    await tester.ensureVisible(find.text('Clear'));
    await tester.tap(find.text('Clear'));
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

    await tester.ensureVisible(find.text('Clear cache'));
    await tester.tap(find.text('Clear cache'));
    expect(cleared, isTrue);
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

  testWidgets('tapping a largest item reports its id', (tester) async {
    String? tapped;
    await tester.pumpWidget(
      _app(
        StoragePage(data: _data(onLargestItemTap: (id) => tapped = id)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Q3 launch plan'));
    await tester.tap(find.text('Q3 launch plan'));
    expect(tapped, 'chat-1');
  });

  testWidgets('hides the sync note when no label is supplied', (tester) async {
    await tester.pumpWidget(
      _app(StoragePage(data: _data(offlineLabel: null)), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Cached offline data'), findsNothing);
  });

  testWidgets('a missing callback leaves the action disabled and announced', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(StoragePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    final node = tester.getSemantics(find.byType(OutlinedButton).first);
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
          onLargestItemTap: (_) {},
          onGoUpgrade: () {},
        ),
        theme: dark ? OTheme.dark() : OTheme.light(),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Storage'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);
      expect(find.text('Empty'), findsOneWidget);
      expect(find.text('See plans'), findsOneWidget);
    });

    testWidgets(
      '200% text keeps row labels readable (${dark ? 'dark' : 'light'})',
      (tester) async {
        await _pumpAt320(
          tester,
          _data(
            onClearPreviews: () {},
            onEmptyTrash: () {},
            onGoUpgrade: () {},
          ),
          theme: dark ? OTheme.dark() : OTheme.light(),
        );

        // Before the responsive row the trailing button took almost the whole
        // row and these labels were squeezed to a couple of pixels wide.
        final trash = tester.renderObject<RenderParagraph>(
          find.text('Trash · 12 items'),
        );
        expect(trash.size.width, greaterThan(80));
        final heading = tester.renderObject<RenderParagraph>(
          find.text('Need more room?'),
        );
        expect(heading.size.width, greaterThan(80));
      },
    );
  }

  for (final dark in [false, true]) {
    testWidgets(
      'empty and error states fit 320 dp at 200% (${dark ? 'dark' : 'light'})',
      (tester) async {
        await _pumpAt320(
          tester,
          const V2StoragePageData(totalGb: 3, onGoUpgrade: null, onRetry: null),
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
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('Clear previews'), findsOneWidget);
    expect(find.text('Delete old chats'), findsOneWidget);
    expect(find.text('Need more room?'), findsOneWidget);
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
}
