import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/chat/model_chip_menu.dart';

Widget _app(
  Widget home, {
  bool dark = false,
  Size size = const Size(420, 800),
  double textScale = 1,
  bool disableAnimations = false,
}) => MaterialApp(
  theme: dark ? OTheme.dark() : OTheme.light(),
  home: MediaQuery(
    data: MediaQueryData(
      size: size,
      textScaler: TextScaler.linear(textScale),
      disableAnimations: disableAnimations,
    ),
    child: home,
  ),
);

const _data = V2ModelChipMenuData(
  lockedModels: [
    V2ChipModel(
      id: 'flash',
      name: 'Ovid Flash 2.5',
      subtitle: 'Fast responses for simple questions',
      icon: Icons.bolt_rounded,
    ),
    V2ChipModel(
      id: 'pro',
      name: 'Ovid Pro 1.5',
      subtitle: 'Deep reasoning for complex code',
      icon: Icons.psychology_rounded,
    ),
    V2ChipModel(
      id: 'claude',
      name: 'the model Sonnet',
      subtitle: 'Advanced architecture & synthesis',
      icon: Icons.terminal_rounded,
    ),
  ],
);

const _upgradeHint =
    'Upgrade to Plus or Pro to pick a model manually. '
    'Auto is included on every plan.';

/// Pumps the menu on its own, the way a gallery or a preview would.
Future<void> _pumpMenu(
  WidgetTester tester, {
  V2ModelChipMenuData data = _data,
  bool dark = false,
  Size size = const Size(420, 800),
  double textScale = 1,
  bool disableAnimations = false,
  ValueChanged<String>? onSelect,
  VoidCallback? onManageModels,
  VoidCallback? onComparePlans,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    _app(
      Scaffold(
        body: Center(
          child: V2ModelChipMenu(
            data: data,
            onSelect: onSelect ?? (_) {},
            onManageModels: onManageModels ?? () {},
            onComparePlans: onComparePlans ?? () {},
          ),
        ),
      ),
      dark: dark,
      size: size,
      textScale: textScale,
      disableAnimations: disableAnimations,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets('renders the compact menu in light', (tester) async {
    await _pumpMenu(tester);

    expect(find.text('MODEL SELECTION'), findsOneWidget);
    expect(find.text('Tier: Free'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Included free'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsNothing);
    expect(find.text('Ovid Flash 2.5'), findsOneWidget);
    expect(find.text('Ovid Pro 1.5'), findsOneWidget);
    expect(find.text('the model Sonnet'), findsOneWidget);
    expect(find.text('Plus plan'), findsNWidgets(3));
    expect(find.text('Manage models'), findsOneWidget);
    expect(find.text('Compare plans'), findsOneWidget);
    expect(find.text(r'From $18/mo'), findsOneWidget);
    expect(find.text('Free plan uses Auto only.'), findsOneWidget);
    expect(find.text(_upgradeHint), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Nothing in the header or the action row is clipped at the card edge.
    final menu = tester.getRect(find.byType(V2ModelChipMenu));
    for (final label in ['Tier: Free', 'Compare plans', r'From $18/mo']) {
      final rect = tester.getRect(find.text(label));
      expect(rect.left, greaterThanOrEqualTo(menu.left), reason: label);
      expect(rect.right, lessThanOrEqualTo(menu.right), reason: label);
      expect(rect.bottom, lessThanOrEqualTo(menu.bottom), reason: label);
    }
  });

  testWidgets('renders in dark with theme colours only', (tester) async {
    await _pumpMenu(tester, dark: true);

    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Ovid Flash 2.5'), findsOneWidget);
    expect(find.text('Manage models'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The card paints itself from OColors, never from a literal colour.
    final card = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(V2ModelChipMenu),
            matching: find.byType(Container),
          )
          .first,
    );
    expect((card.decoration! as BoxDecoration).color, OColors.dark.surface);
  });

  testWidgets('light card uses the light surface colour', (tester) async {
    await _pumpMenu(tester);

    final card = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(V2ModelChipMenu),
            matching: find.byType(Container),
          )
          .first,
    );
    expect((card.decoration! as BoxDecoration).color, OColors.light.surface);
  });

  testWidgets('Auto is checked, locked rows are inert, actions fire', (
    tester,
  ) async {
    String? selected;
    var managed = 0;
    var compared = 0;
    await _pumpMenu(
      tester,
      onSelect: (id) => selected = id,
      onManageModels: () => managed++,
      onComparePlans: () => compared++,
    );

    await tester.tap(find.text('Ovid Flash 2.5'));
    await tester.pump();
    expect(selected, isNull);

    await tester.tap(find.text('Auto'));
    await tester.pump();
    expect(selected, 'auto');

    await tester.tap(find.text('Manage models'));
    expect(managed, 1);

    await tester.tap(find.text('Compare plans'));
    expect(compared, 1);
  });

  for (final tier in ['Free', 'Go']) {
    testWidgets('$tier gates manual rows behind an upgrade hint', (
      tester,
    ) async {
      String? selected;
      var compared = 0;
      await _pumpMenu(
        tester,
        data: V2ModelChipMenuData(
          lockedModels: _data.lockedModels,
          tierLabel: tier,
        ),
        onSelect: (id) => selected = id,
        onComparePlans: () => compared++,
      );

      expect(find.text(_upgradeHint), findsOneWidget);
      expect(find.text('Plus plan'), findsNWidgets(3));
      expect(find.byIcon(Icons.lock_outline_rounded), findsWidgets);

      await tester.tap(find.text('Ovid Flash 2.5'));
      await tester.pump();
      expect(selected, isNull, reason: '$tier must not pick manual models');

      // Auto stays available on every plan.
      await tester.tap(find.text('Auto'));
      await tester.pump();
      expect(selected, 'auto');

      // The upgrade path is always one tap away.
      await tester.tap(find.text('Compare plans'));
      expect(compared, 1);
    });
  }

  for (final tier in ['Plus', 'Pro']) {
    testWidgets('$tier allows every manual row', (tester) async {
      final picks = <String>[];
      var compared = 0;
      await _pumpMenu(
        tester,
        data: V2ModelChipMenuData(
          lockedModels: _data.lockedModels,
          tierLabel: tier,
          manualModelsAllowed: true,
          selectedId: 'pro',
        ),
        onSelect: picks.add,
        onComparePlans: () => compared++,
      );

      expect(find.text(_upgradeHint), findsNothing);
      expect(find.text('Plus plan'), findsNothing);
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);

      await tester.tap(find.text('Ovid Flash 2.5'));
      await tester.tap(find.text('the model Sonnet'));
      expect(picks, ['flash', 'claude']);

      await tester.tap(find.text('Compare plans'));
      expect(compared, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a Go tier label overrides an allowed flag', (tester) async {
    String? selected;
    await _pumpMenu(
      tester,
      data: V2ModelChipMenuData(
        lockedModels: _data.lockedModels,
        tierLabel: 'Go',
        manualModelsAllowed: true,
      ),
      onSelect: (id) => selected = id,
    );

    expect(find.text(_upgradeHint), findsOneWidget);
    expect(find.text('Plus plan'), findsNWidgets(3));

    await tester.tap(find.text('Ovid Flash 2.5'));
    await tester.pump();
    expect(selected, isNull);
  });

  testWidgets('no locked models still shows Auto and the next action', (
    tester,
  ) async {
    var compared = 0;
    await _pumpMenu(
      tester,
      data: const V2ModelChipMenuData(lockedModels: []),
      onComparePlans: () => compared++,
    );

    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Plus plan'), findsNothing);
    expect(find.text('Compare plans'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Compare plans'));
    expect(compared, 1);
  });

  testWidgets('selecting a model in the popover closes it and reports', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    String? selected;
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: OButton(
                label: 'Open models',
                onPressed: () => showV2ModelChipMenu(
                  context,
                  data: _data,
                  onSelect: (id) => selected = id,
                  onManageModels: () {},
                  onComparePlans: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open models'));
    await tester.pumpAndSettle();
    expect(find.text('MODEL SELECTION'), findsOneWidget);
    expect(find.text('Compare plans'), findsOneWidget);

    await tester.tap(find.text('Auto'));
    await tester.pumpAndSettle();
    expect(selected, 'auto');
    expect(find.text('MODEL SELECTION'), findsNothing);
  });

  testWidgets('fits 320 dp at 200 % text in light', (tester) async {
    await _pumpMenu(tester, size: const Size(320, 640), textScale: 2);

    expect(tester.takeException(), isNull);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Compare plans'), findsOneWidget);
    expect(find.text(_upgradeHint), findsOneWidget);
  });

  testWidgets('fits 320 dp at 200 % text in dark', (tester) async {
    await _pumpMenu(
      tester,
      dark: true,
      size: const Size(320, 640),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Compare plans'), findsOneWidget);
    expect(find.text(_upgradeHint), findsOneWidget);
  });

  testWidgets('paid menu fits 320 dp at 200 % text in light and dark', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await _pumpMenu(
        tester,
        data: V2ModelChipMenuData(
          lockedModels: _data.lockedModels,
          tierLabel: 'Plus',
          manualModelsAllowed: true,
        ),
        dark: dark,
        size: const Size(320, 640),
        textScale: 2,
      );

      expect(tester.takeException(), isNull, reason: 'dark: $dark');
      expect(find.text('Ovid Flash 2.5'), findsOneWidget);
      expect(find.text('Compare plans'), findsOneWidget);
      expect(find.text(_upgradeHint), findsNothing);
    }
  });

  testWidgets('the popover stays on screen and scrolls at 320 dp 200 % text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: OButton(
                label: 'Open models',
                onPressed: () => showV2ModelChipMenu(
                  context,
                  data: _data,
                  onSelect: (_) {},
                  onManageModels: () {},
                  onComparePlans: () {},
                ),
              ),
            ),
          ),
        ),
        size: const Size(320, 568),
        textScale: 2,
      ),
    );

    await tester.tap(find.text('Open models'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final menu = tester.getRect(find.byType(V2ModelChipMenu));
    expect(menu.top, greaterThanOrEqualTo(0));
    expect(menu.bottom, lessThanOrEqualTo(568));

    // Everything below the fold is reachable by scrolling, not clipped away.
    await tester.scrollUntilVisible(
      find.text('Free plan uses Auto only.'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Free plan uses Auto only.'), findsOneWidget);
  });

  testWidgets('reduced motion hides nothing', (tester) async {
    await _pumpMenu(tester, disableAnimations: true);

    expect(find.text('MODEL SELECTION'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Compare plans'), findsOneWidget);
    expect(find.text('Free plan uses Auto only.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Auto is announced as a selected button', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpMenu(tester);

    expect(
      tester.getSemantics(find.bySemanticsLabel('Auto, Included free')),
      matchesSemantics(
        label: 'Auto, Included free',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('locked rows are announced as disabled', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpMenu(tester);

    expect(
      tester.getSemantics(
        find.bySemanticsLabel(
          'Ovid Flash 2.5, Fast responses for simple questions, locked, '
          'Plus plan',
        ),
      ),
      matchesSemantics(
        label:
            'Ovid Flash 2.5, Fast responses for simple questions, locked, '
            'Plus plan',
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    handle.dispose();
  });

  testWidgets('action rows are buttons with a spoken label and 48 dp height', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pumpMenu(tester);

    expect(
      tester.getSemantics(find.bySemanticsLabel('Manage models')),
      matchesSemantics(
        label: 'Manage models',
        isButton: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel(r'Compare plans, From $18/mo')),
      matchesSemantics(
        label: r'Compare plans, From $18/mo',
        isButton: true,
        hasTapAction: true,
      ),
    );

    for (final label in ['Manage models', 'Compare plans']) {
      final row = tester.getSize(
        find.ancestor(of: find.text(label), matching: find.byType(InkWell)),
      );
      expect(row.height, greaterThanOrEqualTo(48), reason: '$label is 48 dp');
    }
    final auto = tester.getSize(
      find
          .ancestor(
            of: find.text('Auto'),
            matching: find.byType(GestureDetector),
          )
          .first,
    );
    expect(auto.height, greaterThanOrEqualTo(48));

    handle.dispose();
  });
}
