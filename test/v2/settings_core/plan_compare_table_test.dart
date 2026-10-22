import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/settings/plan_compare_table.dart';

const _plans = V2PlanComparePlan.canonical;

V2PlanCompareData _data({
  List<V2PlanComparePlan> plans = _plans,
  String? currentPlanId = 'free',
  V2PlanCompareStatus status = V2PlanCompareStatus.ready,
  String errorMessage =
      'Plan details could not load. Check your connection and try again.',
  VoidCallback? onRetry,
}) {
  return V2PlanCompareData(
    status: status,
    plans: plans,
    currentPlanId: currentPlanId,
    errorMessage: errorMessage,
    onRetry: onRetry,
  );
}

Widget _app(
  Widget child, {
  required ThemeData theme,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return MaterialApp(
    theme: theme,
    home: MediaQuery(
      data: MediaQueryData(textScaler: textScaler),
      child: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: child,
        ),
      ),
    ),
  );
}

Future<void> _pumpAt320(
  WidgetTester tester,
  V2PlanCompareData data, {
  required ThemeData theme,
}) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    _app(
      PlanCompareTable(data: data),
      theme: theme,
      textScaler: const TextScaler.linear(2),
    ),
  );
  await tester.pump();
}

ScrollableState _tableScrollable(WidgetTester tester) {
  return tester.state<ScrollableState>(
    find.descendant(
      of: find.byKey(const ValueKey<String>('plan-compare-scroll')),
      matching: find.byType(Scrollable),
    ),
  );
}

void main() {
  testWidgets('renders every comparison row and the canonical limits', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(PlanCompareTable(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('plan-compare-table')), findsOneWidget);

    for (final label in [
      'Storage',
      'Files / day',
      'Files / project',
      'Model access',
      'Auto multiplier',
      'Custom connectors',
      'Token caps',
      'Price',
    ]) {
      expect(find.text(label), findsOneWidget, reason: 'row $label');
    }

    for (final name in ['Free', 'Ovid Go', 'Ovid Plus', 'Ovid Pro']) {
      expect(find.text(name), findsOneWidget, reason: 'plan $name');
    }

    expect(find.text('3 GB'), findsOneWidget);
    expect(find.text('5 GB'), findsOneWidget);
    expect(find.text('15 GB'), findsOneWidget);
    expect(find.text('75 GB'), findsOneWidget);

    // Go, Plus and Pro accept 80 files every 3 h: 640 files a day.
    expect(find.text('50 / day'), findsOneWidget);
    expect(find.text('640 / day'), findsNWidgets(3));
    expect(find.text('80 / 3 h'), findsNWidgets(3));

    expect(find.text('80 max'), findsOneWidget);
    expect(find.text('100 max'), findsOneWidget);
    expect(find.text('150 max'), findsOneWidget);
    expect(find.text('250 max'), findsOneWidget);

    expect(find.text('Auto only'), findsNWidgets(2));
    expect(find.text('Auto + manual'), findsNWidgets(2));
    expect(find.text('1×'), findsOneWidget);
    expect(find.text('1.5×'), findsOneWidget);
    expect(find.text('5×'), findsOneWidget);
    expect(find.text('20×'), findsOneWidget);

    expect(find.text('None'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(find.text('20'), findsNWidgets(2));

    expect(find.text('50M / 24 h'), findsOneWidget);
    expect(find.text('1.5B / 30 d'), findsOneWidget);
    expect(find.text('75M / 24 h'), findsOneWidget);
    expect(find.text('2.25B / 30 d'), findsOneWidget);
    expect(find.text('250M / 24 h'), findsOneWidget);
    expect(find.text('7.5B / 30 d'), findsOneWidget);
    expect(find.text('1B / 24 h'), findsOneWidget);
    expect(find.text('30B / 30 d'), findsOneWidget);

    expect(find.text(r'$0'), findsOneWidget);
    expect(find.text(r'$5'), findsOneWidget);
    expect(find.text(r'$18'), findsOneWidget);
    expect(find.text(r'$99'), findsOneWidget);
    expect(find.text('/ month'), findsNWidgets(4));

    expect(tester.takeException(), isNull);
  });

  testWidgets('marks the whole current-plan column', (tester) async {
    await tester.pumpWidget(
      _app(
        PlanCompareTable(data: _data(currentPlanId: 'plus')),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Current'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('plan-compare-current-plus')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('plan-compare-current-free')),
      findsNothing,
    );

    final strip = tester.widget<Container>(
      find.byKey(const ValueKey('plan-compare-current-plus')),
    );
    final decoration = strip.decoration! as BoxDecoration;
    expect(decoration.color, OColors.light.accentSoft);

    final price = tester.widget<Text>(find.text(r'$18'));
    expect(price.style?.color, OColors.light.accent);

    final header = tester.widget<Text>(find.text('Ovid Plus'));
    expect(header.style?.color, OColors.light.accent);
  });

  testWidgets('current plan is announced as selected for screen readers', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        PlanCompareTable(data: _data(currentPlanId: 'go')),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final header = tester.getSemantics(
      find.byKey(const ValueKey('plan-compare-header-go')),
    );
    expect(header.label, 'Ovid Go, current plan');
    expect(header.flagsCollection.isSelected, Tristate.isTrue);
    expect(header.flagsCollection.isHeader, isTrue);

    final freeHeader = tester.getSemantics(
      find.byKey(const ValueKey('plan-compare-header-free')),
    );
    expect(freeHeader.flagsCollection.isSelected, Tristate.isFalse);

    final storage = tester.getSemantics(
      find.byKey(const ValueKey('plan-compare-cell-free-storage')),
    );
    expect(storage.label, 'Free, Storage: 3 GB of cloud storage');

    final models = tester.getSemantics(
      find.byKey(const ValueKey('plan-compare-cell-go-models')),
    );
    expect(models.label, contains('manual models are not available'));

    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('plan-compare-label-storage')),
          )
          .label,
      'Storage',
    );

    semantics.dispose();
  });

  testWidgets('pins the first column while the plan columns scroll', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(PlanCompareTable(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    final labelBefore = tester.getTopLeft(
      find.byKey(const ValueKey('plan-compare-label-storage')),
    );
    final valueBefore = tester.getTopLeft(
      find.byKey(const ValueKey('plan-compare-cell-pro-storage')),
    );
    expect(
      find.byKey(const ValueKey('plan-compare-scroll')),
      findsOneWidget,
    );

    _tableScrollable(tester).position.jumpTo(220);
    await tester.pump();

    final labelAfter = tester.getTopLeft(
      find.byKey(const ValueKey('plan-compare-label-storage')),
    );
    final valueAfter = tester.getTopLeft(
      find.byKey(const ValueKey('plan-compare-cell-pro-storage')),
    );

    expect(labelAfter.dx, closeTo(labelBefore.dx, 0.01));
    expect(labelAfter.dy, closeTo(labelBefore.dy, 0.01));
    // The values move with the scroll, the pinned label does not.
    expect(valueAfter.dx, closeTo(valueBefore.dx - 220, 0.01));
    expect(_tableScrollable(tester).position.pixels, 220);
  });

  testWidgets('can be dragged horizontally on a phone', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(PlanCompareTable(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    final labelBefore = tester.getTopLeft(
      find.byKey(const ValueKey('plan-compare-label-storage')),
    );

    await tester.drag(
      find.byKey(const ValueKey('plan-compare-scroll')),
      const Offset(-180, 0),
    );
    await tester.pumpAndSettle();

    expect(_tableScrollable(tester).position.pixels, greaterThan(0));
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('plan-compare-label-storage')))
          .dx,
      closeTo(labelBefore.dx, 0.01),
    );
  });

  testWidgets('every column fits without scrolling on a wide window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(PlanCompareTable(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(_tableScrollable(tester).position.maxScrollExtent, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders in dark mode', (tester) async {
    await tester.pumpWidget(
      _app(
        PlanCompareTable(data: _data(currentPlanId: 'pro')),
        theme: OTheme.dark(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ovid Pro'), findsOneWidget);
    expect(find.text('Current'), findsOneWidget);
    expect(find.text(r'$99'), findsOneWidget);
    expect(find.text('Token caps'), findsOneWidget);

    final strip = tester.widget<Container>(
      find.byKey(const ValueKey('plan-compare-current-pro')),
    );
    final decoration = strip.decoration! as BoxDecoration;
    expect(decoration.color, OColors.dark.accentSoft);
  });

  for (final dark in [false, true]) {
    testWidgets('fits 320 dp at 200% text (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      await _pumpAt320(
        tester,
        _data(currentPlanId: 'pro'),
        theme: dark ? OTheme.dark() : OTheme.light(),
      );

      expect(tester.takeException(), isNull);
      for (final label in [
        'Storage',
        'Files / day',
        'Files / project',
        'Model access',
        'Auto multiplier',
        'Custom connectors',
        'Token caps',
        'Price',
      ]) {
        expect(find.text(label), findsOneWidget, reason: 'row $label');
      }
      expect(find.text('75 GB'), findsOneWidget);
      expect(find.text('50 / day'), findsOneWidget);
      expect(find.text('640 / day'), findsNWidgets(3));
      expect(find.text('Current'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('plan-compare-current-pro')),
        findsOneWidget,
      );
    });
  }

  testWidgets('empty table offers a retry action', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _app(
        PlanCompareTable(
          data: _data(
            plans: const [],
            currentPlanId: null,
            onRetry: () {
              retried++;
            },
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No plans to compare'), findsOneWidget);
    await tester.tap(find.text('Check plans again'));
    await tester.pump();

    expect(retried, 1);
  });

  testWidgets('loading table shows skeletons', (tester) async {
    await tester.pumpWidget(
      _app(
        PlanCompareTable(data: _data(status: V2PlanCompareStatus.loading)),
        theme: OTheme.light(),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Storage'), findsNothing);
  });

  testWidgets('error table explains the failure and retries', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _app(
        PlanCompareTable(
          data: _data(
            status: V2PlanCompareStatus.error,
            errorMessage: 'The plan table could not load.',
            onRetry: () => retried++,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('The plan table could not load.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();

    expect(retried, 1);
  });
}
