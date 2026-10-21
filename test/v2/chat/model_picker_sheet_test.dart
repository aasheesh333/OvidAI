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
    tag: 'Balanced',
  ),
  V2ModelOption(
    id: 'claude',
    name: 'Claude 3.7 Sonnet',
    subtitle: 'Advanced architecture & synthesis',
    speed: 'Moderate',
    costHint: 'Paid plan',
    locked: true,
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
    tag: 'Balanced',
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

void main() {
  testWidgets('renders the picker in light', (tester) async {
    await tester.pumpWidget(_app(_sheet()));
    await tester.pumpAndSettle();

    expect(find.text('Select model'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Recommended'), findsOneWidget);
    expect(find.text('Ovid Flash 2.5'), findsOneWidget);
    expect(find.text('Ovid Pro 1.5'), findsOneWidget);
    expect(find.text('Claude 3.7 Sonnet'), findsOneWidget);
    expect(find.text('Plus plan'), findsNWidgets(3));
    expect(find.text('Manage models'), findsOneWidget);
    expect(find.text('Free plan uses Auto only.'), findsOneWidget);
  });

  testWidgets('renders the picker in dark', (tester) async {
    await tester.pumpWidget(_app(_sheet(), dark: true));
    await tester.pumpAndSettle();

    expect(find.text('Select model'), findsOneWidget);
    expect(find.text('Ovid Flash 2.5'), findsOneWidget);
  });

  testWidgets('search filters models and can be cleared', (tester) async {
    await tester.pumpWidget(_app(_sheet()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Flash');
    await tester.pumpAndSettle();

    expect(find.text('Ovid Flash 2.5'), findsOneWidget);
    expect(find.text('Ovid Pro 1.5'), findsNothing);
    expect(find.text('Auto'), findsNothing);

    await tester.enterText(find.byType(TextField), 'no such model');
    await tester.pumpAndSettle();
    expect(find.text('No models found'), findsOneWidget);

    await tester.tap(find.text('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Ovid Flash 2.5'), findsOneWidget);
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
          home: _sheet(),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: 'dark: $dark');
      expect(find.text('Select model'), findsOneWidget);
      expect(find.text('Ovid Flash 2.5'), findsOneWidget);
      expect(find.text('Manage models'), findsOneWidget);
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

  testWidgets('unlocked row reports its id', (tester) async {
    String? selected;
    await tester.pumpWidget(
      _app(
        _sheet(
          data: const V2ModelPickerData(models: _mixedModels),
          onSelect: (id) => selected = id,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('STANDARD MODELS'), findsOneWidget);
    expect(find.text('ADVANCED REASONING'), findsOneWidget);

    await tester.tap(find.text('Ovid Mini 1.0'));
    expect(selected, 'standard');
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

  testWidgets('selection state is announced', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        _sheet(
          data: const V2ModelPickerData(
            models: _mixedModels,
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
}
