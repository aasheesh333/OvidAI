import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/chat/model_chip.dart';

Widget _app(
  Widget home, {
  bool dark = false,
  Size size = const Size(420, 800),
  double textScale = 1,
}) => MaterialApp(
  theme: dark ? OTheme.dark() : OTheme.light(),
  home: MediaQuery(
    data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: Center(child: home)),
  ),
);

Future<void> _pumpChip(
  WidgetTester tester, {
  String label = 'Auto',
  IconData icon = Icons.auto_awesome_rounded,
  VoidCallback? onTap,
  bool tappable = true,
  bool enabled = true,
  bool autoOnly = false,
  int subagentCount = 0,
  String? semanticLabel,
  bool dark = false,
  Size size = const Size(420, 800),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    _app(
      V2ModelChip(
        label: label,
        icon: icon,
        onTap: tappable ? (onTap ?? () {}) : null,
        enabled: enabled,
        autoOnly: autoOnly,
        subagentCount: subagentCount,
        semanticLabel: semanticLabel,
      ),
      dark: dark,
      size: size,
      textScale: textScale,
    ),
  );
  await tester.pump();
  // MaterialApp animates between light and dark theme data.
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets('renders model icon, label and chevron on a 48 dp target', (
    tester,
  ) async {
    await _pumpChip(tester);

    expect(find.byIcon(Icons.auto_awesome_rounded), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);

    final size = tester.getSize(find.byType(V2ModelChip));
    expect(size.height, greaterThanOrEqualTo(48));
    expect(size.width, lessThanOrEqualTo(v2ModelChipMaxWidth));
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses a custom model icon and semantic label', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpChip(
      tester,
      label: 'Ovid Flash 2.5',
      icon: Icons.bolt_rounded,
      semanticLabel: 'Ovid Flash 2.5 selected',
    );

    expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Ovid Flash 2.5 selected')),
      matchesSemantics(
        label: 'Ovid Flash 2.5 selected',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('the enabled chip is a button and reports its tap', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await _pumpChip(tester, onTap: () => taps++);

    expect(
      tester.getSemantics(find.bySemanticsLabel('Model: Auto. Change model')),
      matchesSemantics(
        label: 'Model: Auto. Change model',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );

    await tester.tap(find.byType(V2ModelChip));
    await tester.pump();
    expect(taps, 1);
    handle.dispose();
  });

  testWidgets('long labels ellipsize at 120 dp', (tester) async {
    const longLabel = 'Ovid Pro 1.5 Extended Reasoning';
    await _pumpChip(tester, label: longLabel, size: const Size(320, 800));

    final chip = tester.getSize(find.byType(V2ModelChip));
    expect(chip.width, lessThanOrEqualTo(v2ModelChipMaxWidth));
    expect(chip.height, greaterThanOrEqualTo(48));

    final text = tester.widget<Text>(find.text(longLabel));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });

  testWidgets('auto-only plans show a lock and stay tappable', (tester) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await _pumpChip(tester, autoOnly: true, onTap: () => taps++);

    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    expect(
      tester.getSemantics(
        find.bySemanticsLabel('Model: Auto. Auto only. Change model'),
      ),
      matchesSemantics(
        label: 'Model: Auto. Auto only. Change model',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );

    // The lock explains the plan, but the upgrade menu must still open.
    await tester.tap(find.byType(V2ModelChip));
    expect(taps, 1);
    handle.dispose();
  });

  testWidgets('manual plans show no lock', (tester) async {
    await _pumpChip(tester, label: 'Ovid Pro 1.5');

    expect(find.byIcon(Icons.lock_outline_rounded), findsNothing);
    expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);
  });

  testWidgets('subagent count badge appears only when above zero', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pumpChip(tester, subagentCount: 3);

    expect(find.text('3'), findsOneWidget);
    expect(
      tester.getSemantics(
        find.bySemanticsLabel('Model: Auto. 3 subagents. Change model'),
      ),
      matchesSemantics(
        label: 'Model: Auto. 3 subagents. Change model',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();

    await _pumpChip(tester, subagentCount: 0);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('one subagent is announced in the singular', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpChip(tester, subagentCount: 1);

    expect(find.text('1'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Model: Auto. 1 subagent. Change model'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('a count of 50 fits the chip at 320 dp and 200 % text', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await _pumpChip(
        tester,
        label: 'Ovid Pro 1.5 Extended Reasoning',
        autoOnly: true,
        subagentCount: 50,
        dark: dark,
        size: const Size(320, 640),
        textScale: 2,
      );

      expect(tester.takeException(), isNull, reason: 'dark: $dark');
      final chip = tester.getRect(find.byType(V2ModelChip));
      expect(chip.width, lessThanOrEqualTo(v2ModelChipMaxWidth));
      expect(chip.height, greaterThanOrEqualTo(48));

      for (final finder in [
        find.byIcon(Icons.auto_awesome_rounded),
        find.byIcon(Icons.lock_outline_rounded),
        find.text('50'),
        find.byIcon(Icons.expand_more_rounded),
      ]) {
        final rect = tester.getRect(finder);
        expect(rect.left, greaterThanOrEqualTo(chip.left), reason: '$dark');
        expect(rect.right, lessThanOrEqualTo(chip.right), reason: '$dark');
      }
    }
  });

  testWidgets('disabled chip is announced and ignores taps', (tester) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await _pumpChip(tester, onTap: () => taps++, enabled: false);

    expect(
      tester.getSemantics(
        find.bySemanticsLabel('Model: Auto. Model selection unavailable'),
      ),
      matchesSemantics(
        label: 'Model: Auto. Model selection unavailable',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        hasTapAction: false,
      ),
    );

    await tester.tap(find.byType(V2ModelChip), warnIfMissed: false);
    await tester.pump();
    expect(taps, 0);
    handle.dispose();
  });

  testWidgets('a null callback disables the chip', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpChip(tester, tappable: false);

    expect(
      find.bySemanticsLabel('Model: Auto. Model selection unavailable'),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(
        find.bySemanticsLabel('Model: Auto. Model selection unavailable'),
      ),
      matchesSemantics(
        label: 'Model: Auto. Model selection unavailable',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        hasTapAction: false,
      ),
    );
    handle.dispose();
  });

  testWidgets('light and dark use the theme surface colours', (tester) async {
    await _pumpChip(tester);
    final lightPill = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(V2ModelChip),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(
      (lightPill.decoration! as BoxDecoration).color,
      OColors.light.surfaceAlt,
    );

    await _pumpChip(tester, dark: true);
    final darkPill = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(V2ModelChip),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(
      (darkPill.decoration! as BoxDecoration).color,
      OColors.dark.surfaceAlt,
    );
  });

  testWidgets('disabled chip uses the quieter surface', (tester) async {
    await _pumpChip(tester, enabled: false);

    final pill = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(V2ModelChip),
            matching: find.byType(Container),
          )
          .first,
    );
    expect((pill.decoration! as BoxDecoration).color, OColors.light.surface);
    expect(tester.takeException(), isNull);
  });
}
