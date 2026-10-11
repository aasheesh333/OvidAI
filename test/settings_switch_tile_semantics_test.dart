import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/settings_action_widgets.dart';

void main() {
  testWidgets('SettingsSwitchTile is one semantics node with label and state', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final value = ValueNotifier(false);
    addTearDown(value.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsSwitchTile(
            icon: Icons.memory,
            title: 'Memory',
            subtitleOn: 'On',
            subtitleOff: 'Off',
            listenable: value,
            getter: () => value.value,
            setter: (v) async => value.value = v,
          ),
        ),
      ),
    );
    final node = tester.getSemantics(find.byType(Switch));
    final data = node.getSemanticsData();
    // The switch merges into the tile: one node carries title, subtitle,
    // the toggled flag and the tap action.
    expect(node, same(tester.getSemantics(find.text('Memory'))));
    expect(data.label, contains('Memory'));
    expect(data.label, contains('Off'));
    expect(data.flagsCollection.isToggled, Tristate.isFalse);
    expect(data.hasAction(SemanticsAction.tap), isTrue);

    await tester.tap(find.text('Memory'));
    await tester.pumpAndSettle();
    expect(value.value, isTrue);
    expect(
      tester
          .getSemantics(find.byType(Switch))
          .getSemanticsData()
          .flagsCollection
          .isToggled,
      Tristate.isTrue,
    );
    handle.dispose();
  });
}
