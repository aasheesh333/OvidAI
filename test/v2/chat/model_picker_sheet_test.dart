import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/model_picker_sheet.dart';

Widget _app(Widget home, {bool dark = false}) =>
    MaterialApp(theme: dark ? OTheme.dark() : OTheme.light(), home: home);

const _models = <V2ModelOption>[
  V2ModelOption(
    id: 'flash',
    name: 'Ovid Flash 2.5',
    subtitle: 'Quick chats · Light reasoning',
    speed: 'Very fast',
    costHint: 'Low token use',
    locked: true,
    tag: 'Speed',
    tagTone: OPillTone.success,
  ),
  V2ModelOption(
    id: 'pro',
    name: 'Ovid Pro 1.5',
    subtitle: 'Deep thinking · Coding & math',
    speed: 'Moderate',
    costHint: '2x tokens',
    locked: true,
    advanced: true,
    tag: 'Balanced',
  ),
  V2ModelOption(
    id: 'claude',
    name: 'the model Sonnet',
    subtitle: 'Advanced architecture & synthesis',
    speed: 'Moderate',
    costHint: 'Paid plan',
    locked: true,
    advanced: true,
    icon: Icons.terminal_rounded,
  ),
];

const _data = V2ModelPickerData(models: _models);

const _mixedModels = <V2ModelOption>[
  V2ModelOption(
    id: 'standard',
    name: 'Ovid Mini 1.0',
    subtitle: 'Short answers',
    speed: 'Very fast',
    costHint: 'Low token use',
    tag: 'Free',
    tagTone: OPillTone.neutral,
  ),
  V2ModelOption(
    id: 'pro',
    name: 'Ovid Pro 1.5',
    subtitle: 'Deep thinking · Coding & math',
    speed: 'Moderate',
    costHint: '2x tokens',
    locked: true,
    advanced: true,
    tag: 'Balanced',
  ),
];

/// Manual models with no per-row lock, so the plan gate is the only thing
/// standing between the user and a manual pick.
const _manualModels = <V2ModelOption>[
  V2ModelOption(
    id: 'mini',
    name: 'Ovid Mini 1.0',
    subtitle: 'Short answers',
    speed: 'Very fast',
    costHint: 'Low token use',
  ),
  V2ModelOption(
    id: 'pro',
    name: 'Ovid Pro 1.5',
    subtitle: 'Deep thinking · Coding & math',
    speed: 'Moderate',
    costHint: '2x tokens',
  ),
];

Widget _sheet({
  V2ModelPickerData data = _data,
  ValueChanged<String>? onSelect,
  VoidCallback? onManage,
  VoidCallback? onRetry,
}) {
  return Scaffold(
    body: V2ModelPickerSheet(
      data: data,
      onSelect: onSelect ?? (_) {},
      onManageModels: onManage ?? () {},
      onRetry: onRetry,
    ),
  );
}

/// The capped surface, not the `Center` that hosts it.
Finder _surface() => find
    .descendant(
      of: find.byType(V2ModelPickerSheet),
      matching: find.byType(Material),
    )
    .first;

void main() {
  testWidgets('renders the picker in light', (tester) async {
    await tester.pumpWidget(_app(_sheet()));
    await tester.pumpAndSettle();

    expect(find.text('Select model'), findsOneWidget);
    expect(
      find.text('Free plan uses Auto only.'),
      findsOneWidget,
      reason: 'the gate is explained once, in the header subtitle',
    );
    expect(find.text('Auto'), findsOneWidget);
    expect(
      find.text('Recommended'),
      findsNothing,
      reason: 'the Auto card keeps one description line, not a tag',
    );
    expect(find.text('Smart routing'), findsOneWidget);
    expect(find.text('Ovid Flash 2.5'), findsOneWidget);
    expect(find.text('Ovid Pro 1.5'), findsOneWidget);
    expect(find.text('the model Sonnet'), findsOneWidget);
    expect(find.text('Plus plan'), findsNWidgets(3));
    expect(find.text('Manage models'), findsOneWidget);
    expect(
      find.text('Speed'),
      findsNothing,
      reason: 'a row is name, one meta line and cost; the gate is the only tag',
    );
    expect(
      find.text('Upgrade to Plus or Pro to pick a model manually. '
          'Auto is included on every plan.'),
      findsNothing,
      reason: 'the upgrade copy is spoken, not drawn as a paragraph',
    );
  });

  testWidgets('renders the picker in dark', (tester) async {
    await tester.pumpWidget(_app(_sheet(), dark: true));
    await tester.pumpAndSettle();

    expect(find.text('Select model'), findsOneWidget);
    expect(find.text('Ovid Flash 2.5'), findsOneWidget);
  });

  testWidgets('a paid plan draws no gate subtitle', (tester) async {
    await tester.pumpWidget(
      _app(
        _sheet(
          data: const V2ModelPickerData(
            models: _manualModels,
            planLabel: 'Plus',
            manualModelsAllowed: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Free plan uses Auto only.'), findsNothing);
    expect(find.text('Plus plan'), findsNothing);
  });

  testWidgets('a caller-supplied gate note wins over the plan default', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        _sheet(
          data: const V2ModelPickerData(
            models: _manualModels,
            planLabel: 'Free plan',
            freePlanNote: 'Auto only on this plan.',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Auto only on this plan.'), findsOneWidget);
    expect(find.text('Free plan uses Auto only.'), findsNothing);
  });

  testWidgets('search filters by name, subtitle, speed and cost', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_sheet()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Flash');
    await tester.pumpAndSettle();
    expect(find.text('Ovid Flash 2.5'), findsOneWidget);
    expect(find.text('Ovid Pro 1.5'), findsNothing);
    expect(find.text('Auto'), findsNothing);

    await tester.enterText(find.byType(TextField), 'Deep thinking');
    await tester.pumpAndSettle();
    expect(find.text('Ovid Pro 1.5'), findsOneWidget);
    expect(find.text('Ovid Flash 2.5'), findsNothing);

    await tester.enterText(find.byType(TextField), 'Very fast');
    await tester.pumpAndSettle();
    expect(find.text('Ovid Flash 2.5'), findsOneWidget);
    expect(find.text('Ovid Pro 1.5'), findsNothing);

    await tester.enterText(find.byType(TextField), 'Low token use');
    await tester.pumpAndSettle();
    expect(find.text('Ovid Flash 2.5'), findsOneWidget);
    expect(find.text('the model Sonnet'), findsNothing);

    // Surrounding whitespace and case must not defeat the match.
    await tester.enterText(find.byType(TextField), '  FLASH  ');
    await tester.pumpAndSettle();
    expect(find.text('Ovid Flash 2.5'), findsOneWidget);
  });

  testWidgets('an empty search result is honest and clearable', (tester) async {
    await tester.pumpWidget(_app(_sheet()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'no such model');
    await tester.pumpAndSettle();
    expect(find.text('No models found'), findsOneWidget);
    expect(find.text('Try a name, speed or cost.'), findsOneWidget);
    expect(find.text('Ovid Flash 2.5'), findsNothing);
    expect(find.text('Auto'), findsNothing);

    await tester.tap(find.text('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Ovid Flash 2.5'), findsOneWidget);
    expect(find.text('No models found'), findsNothing);
  });

  testWidgets('locked model is disabled and Auto can be selected', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(_app(_sheet(onSelect: (id) => selected = id)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ovid Flash 2.5'));
    await tester.pump();
    expect(selected, isNull);

    await tester.tap(find.text('Auto'));
    await tester.pump();
    expect(selected, 'auto');
  });

  testWidgets('manage models action fires', (tester) async {
    var managed = 0;
    await tester.pumpWidget(_app(_sheet(onManage: () => managed++)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Manage models'));
    expect(managed, 1);
  });

  testWidgets('fits 320 dp at 200% text without overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const plans = <String, V2ModelPickerData>{
      'free': _data,
      'plus': V2ModelPickerData(models: _manualModels, planLabel: 'Plus'),
    };

    for (final dark in [false, true]) {
      for (final entry in plans.entries) {
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? OTheme.dark() : OTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: _sheet(data: entry.value),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          tester.takeException(),
          isNull,
          reason: '${entry.key} dark: $dark',
        );
        expect(find.text('Select model'), findsOneWidget);
        expect(find.text('Ovid Pro 1.5'), findsOneWidget);
        expect(find.text('Manage models'), findsOneWidget);
      }
    }
  });

  testWidgets('stays inside the layout from 320 dp to 1280 dp', (tester) async {
    addTearDown(tester.view.reset);

    const widths = <double>[320, 360, 412, 600, 800, 1024, 1280];
    for (final width in widths) {
      for (final scale in [1.0, 2.0]) {
        for (final dark in [false, true]) {
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1;

          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? OTheme.dark() : OTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: _sheet(),
            ),
          );
          await tester.pumpAndSettle();

          final reason = '${width.toInt()} dp @ ${scale}x dark: $dark';
          expect(tester.takeException(), isNull, reason: reason);
          expect(find.text('Select model'), findsOneWidget, reason: reason);
          expect(find.text('Manage models'), findsOneWidget, reason: reason);

          // The surface never stretches past the contract's 560 dp cap.
          expect(
            tester.getSize(_surface()).width,
            lessThanOrEqualTo(560),
            reason: reason,
          );
        }
      }
    }
  });

  testWidgets('shows a skeleton while models load', (tester) async {
    await tester.pumpWidget(
      _app(
        _sheet(data: const V2ModelPickerData(models: _models, loading: true)),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Ovid Flash 2.5'), findsNothing);
  });

  testWidgets('error state retries', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        _sheet(
          data: const V2ModelPickerData(
            models: _models,
            errorMessage: 'Could not load models.',
          ),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could not load models.'), findsOneWidget);
    expect(find.text('Ovid Flash 2.5'), findsNothing);

    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('unlocked row reports its id and draws its tag', (tester) async {
    String? selected;
    await tester.pumpWidget(
      _app(
        _sheet(
          data: const V2ModelPickerData(
            models: _mixedModels,
            planLabel: 'Plus',
          ),
          onSelect: (id) => selected = id,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('STANDARD MODELS'), findsOneWidget);
    expect(find.text('ADVANCED REASONING'), findsOneWidget);
    expect(find.text('Free'), findsOneWidget);
    expect(
      find.text('Balanced'),
      findsNothing,
      reason: 'a locked row shows the gate instead of the recommendation',
    );

    await tester.tap(find.text('Ovid Mini 1.0'));
    expect(selected, 'standard');
  });

  for (final plan in ['Free plan', 'Go']) {
    testWidgets('$plan keeps manual models visible but locked', (tester) async {
      String? selected;
      await tester.pumpWidget(
        _app(
          _sheet(
            data: V2ModelPickerData(
              models: _manualModels,
              planLabel: plan,
              manualModelsAllowed: false,
            ),
            onSelect: (id) => selected = id,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Manual models stay visible, greyed, with the plan they need.
      expect(find.text('Ovid Mini 1.0'), findsOneWidget);
      expect(find.text('Ovid Pro 1.5'), findsOneWidget);
      expect(find.text('Plus plan'), findsNWidgets(2));
      expect(find.byIcon(Icons.lock_outline_rounded), findsNWidgets(2));
      expect(
        find.text(
          plan == 'Go' ? 'Go plan uses Auto only.' : 'Free plan uses Auto only.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Ovid Mini 1.0'));
      await tester.pump();
      expect(selected, isNull, reason: '$plan must not pick manual models');

      // Auto is always selectable.
      await tester.tap(find.text('Auto'));
      await tester.pump();
      expect(selected, 'auto');
    });
  }

  for (final plan in ['Plus', 'Pro']) {
    testWidgets('$plan allows every manual model', (tester) async {
      final picks = <String>[];
      await tester.pumpWidget(
        _app(
          _sheet(
            data: V2ModelPickerData(
              models: _manualModels,
              planLabel: plan,
              manualModelsAllowed: true,
            ),
            onSelect: picks.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Plus plan'), findsNothing);
      expect(find.byIcon(Icons.lock_outline_rounded), findsNothing);

      await tester.tap(find.text('Ovid Mini 1.0'));
      await tester.tap(find.text('Ovid Pro 1.5'));
      expect(picks, ['mini', 'pro']);
    });
  }

  testWidgets('a Free plan label alone forces Auto only', (tester) async {
    String? selected;
    await tester.pumpWidget(
      _app(
        _sheet(
          data: const V2ModelPickerData(
            models: _manualModels,
            planLabel: 'Free plan',
          ),
          onSelect: (id) => selected = id,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Plus plan'), findsNWidgets(2));

    await tester.tap(find.text('Ovid Mini 1.0'));
    await tester.pump();
    expect(selected, isNull);

    await tester.tap(find.text('Auto'));
    await tester.pump();
    expect(selected, 'auto');
  });

  testWidgets('Auto is available on every plan', (tester) async {
    for (final plan in ['Free plan', 'Go', 'Plus', 'Pro', 'Starter']) {
      final picks = <String>[];
      await tester.pumpWidget(
        _app(
          _sheet(
            data: V2ModelPickerData(
              models: _manualModels,
              planLabel: plan,
              manualModelsAllowed: plan == 'Plus' || plan == 'Pro',
            ),
            onSelect: picks.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Auto'), findsOneWidget, reason: plan);
      await tester.tap(find.text('Auto'));
      await tester.pump();
      expect(picks, ['auto'], reason: plan);
    }
  });

  testWidgets('a remembered locked pick falls back to Auto', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        _sheet(
          data: const V2ModelPickerData(
            models: _manualModels,
            planLabel: 'Free plan',
            selectedId: 'pro',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final auto = tester.getSemantics(find.text('Auto'));
    expect(auto.flagsCollection.isSelected, Tristate.isTrue);
    expect(
      tester
          .getSemantics(find.text('Ovid Pro 1.5'))
          .flagsCollection
          .isSelected,
      isNot(Tristate.isTrue),
    );
    handle.dispose();
  });

  testWidgets('auto-only plan announces locked rows', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        _sheet(
          data: const V2ModelPickerData(
            models: _manualModels,
            manualModelsAllowed: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final node = tester.getSemantics(find.text('Ovid Mini 1.0'));
    expect(node.label, contains('Ovid Mini 1.0, Short answers, locked'));
    expect(node.label, contains('Plus plan'));
    expect(node.flagsCollection.isEnabled, Tristate.isFalse);
    expect(node.hint, contains('Upgrade to Plus or Pro'));
    handle.dispose();
  });

  testWidgets('auto-only picker fits 320 dp at 200 % text in light and dark', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final dark in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? OTheme.dark() : OTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: _sheet(
            data: const V2ModelPickerData(
              models: _manualModels,
              manualModelsAllowed: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: 'dark: $dark');
      expect(find.text('Select model'), findsOneWidget);
      expect(find.text('Ovid Mini 1.0'), findsOneWidget);
      expect(find.text('Manage models'), findsOneWidget);
    }
  });

  testWidgets('controls meet the 48 dp touch target', (tester) async {
    await tester.pumpWidget(_app(_sheet()));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byType(OIconButton)).height,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester.getSize(find.widgetWithText(OButton, 'Manage models')).height,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester.getSize(find.byType(TextField)).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('locked row is announced as disabled', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(_sheet()));
    await tester.pumpAndSettle();

    final node = tester.getSemantics(find.text('Ovid Flash 2.5'));
    expect(node.label, contains('locked, Plus plan'));
    final flags = node.flagsCollection;
    expect(flags.isEnabled, isNot(Tristate.none));
    expect(flags.isEnabled, Tristate.isFalse);
    handle.dispose();
  });

  testWidgets('available row announces name, availability and selection', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        _sheet(
          data: const V2ModelPickerData(
            models: _mixedModels,
            planLabel: 'Plus',
            selectedId: 'standard',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.text('Ovid Mini 1.0')),
      matchesSemantics(
        label: 'Ovid Mini 1.0, Short answers, available',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasSelectedState: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.text('Auto')),
      matchesSemantics(
        label: 'Auto, Smart routing, available',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasSelectedState: true,
        isSelected: false,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('selection state is announced', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        _sheet(
          data: const V2ModelPickerData(
            models: _mixedModels,
            planLabel: 'Plus',
            selectedId: 'standard',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.text('Auto')).flagsCollection.isSelected,
      Tristate.isFalse,
    );
    expect(
      tester
          .getSemantics(find.text('Ovid Mini 1.0'))
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    handle.dispose();
  });

  testWidgets('selection state is drawn on the selected row only', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        _sheet(
          data: const V2ModelPickerData(
            models: _mixedModels,
            planLabel: 'Plus',
            selectedId: 'standard',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    final row = find
        .ancestor(of: find.text('Ovid Mini 1.0'), matching: find.byType(Row))
        .first;
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.check_rounded)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Ovid Pro 1.5'),
          matching: find.byType(Row),
        ).first,
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsNothing,
    );
  });

  testWidgets('rows keep their title and meta line to one line', (tester) async {
    await tester.pumpWidget(_app(_sheet()));
    await tester.pumpAndSettle();

    for (final label in [
      'Ovid Flash 2.5',
      'Quick chats · Light reasoning',
      'Low token use',
    ]) {
      final text = tester.widget<Text>(find.text(label));
      expect(text.maxLines, 1, reason: label);
      expect(text.overflow, TextOverflow.ellipsis, reason: label);
    }
  });

  testWidgets('opens as a bottom sheet with a grabber and a close control', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showV2ModelPickerSheet(
                  context,
                  data: _data,
                  onSelect: (_) {},
                  onManageModels: () {},
                ),
                child: const Text('Open models'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open models'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Select model'), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);

    final grabbers = tester.widgetList<Container>(find.byType(Container)).where(
      (container) =>
          container.constraints?.maxWidth == 36 &&
          container.constraints?.maxHeight == 4,
    );
    expect(grabbers, isNotEmpty, reason: 'the sheet has a grabber');

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Select model'), findsNothing);
  });

  for (final width in [600.0, 900.0, 1280.0]) {
    testWidgets('opens as a centred 560 dp dialog at ${width.toInt()} dp', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showV2ModelPickerSheet(
                    context,
                    data: _data,
                    onSelect: (_) {},
                    onManageModels: () {},
                  ),
                  child: const Text('Open models'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open models'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);

      final surface = tester.getRect(_surface());
      expect(surface.width, lessThanOrEqualTo(560));
      expect(surface.center.dx, closeTo(width / 2, 1));
      expect(find.text('Select model'), findsOneWidget);
      expect(find.text('Ovid Flash 2.5'), findsOneWidget);
    });
  }
}
