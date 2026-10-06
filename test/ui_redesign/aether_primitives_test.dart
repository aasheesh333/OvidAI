import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

Widget _host(Widget child) {
  return MaterialApp(
    theme: Aether.theme(),
    home: Scaffold(body: SafeArea(child: child)),
  );
}

void main() {
  testWidgets('AetherCard renders child, title and footer', (tester) async {
    await tester.pumpWidget(
      _host(
        const AetherCard(
          title: Text('Card title'),
          trailing: Icon(Icons.more_horiz),
          footer: Text('footer-content'),
          child: Text('card-child-marker'),
        ),
      ),
    );
    expect(find.text('Card title'), findsOneWidget);
    expect(find.text('card-child-marker'), findsOneWidget);
    expect(find.text('footer-content'), findsOneWidget);
  });

  testWidgets('AetherPrimaryButton disables while loading', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        AetherPrimaryButton(
          label: 'Submit',
          loading: true,
          onPressed: () => taps++,
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final btn = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.onPressed, isNull);

    await tester.tap(find.byType(FilledButton), warnIfMissed: false);
    await tester.pump();
    expect(taps, 0);
  });

  testWidgets('AetherSecondaryButton disables when onPressed is null', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const AetherSecondaryButton(label: 'Cancel')),
    );
    final btn = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(btn.onPressed, isNull);
  });

  testWidgets('AetherGhostButton and AetherDangerButton render loader when loading', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            AetherGhostButton(label: 'Later', loading: true, onPressed: () {}),
            AetherDangerButton(label: 'Delete', loading: true, onPressed: () {}),
          ],
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
  });

  testWidgets('AetherOtpField emits joined onChanged string', (tester) async {
    String? latest;
    await tester.pumpWidget(
      _host(
        AetherOtpField(
          length: 6,
          onChanged: (v) => latest = v,
        ),
      ),
    );
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(6));
    await tester.enterText(fields.at(0), '1');
    await tester.enterText(fields.at(1), '2');
    await tester.enterText(fields.at(2), '3');
    await tester.pump();
    expect(latest, '123');
  });

  testWidgets('AetherPill renders filled and outlined variants', (tester) async {
    await tester.pumpWidget(
      _host(
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AetherPill(label: 'FILLED', color: Aether.accent),
            SizedBox(width: 8),
            AetherPill(label: 'OUTLINE', color: Aether.accent, filled: false),
          ],
        ),
      ),
    );
    expect(find.text('FILLED'), findsOneWidget);
    expect(find.text('OUTLINE'), findsOneWidget);
    final containers = tester.widgetList<Container>(
      find.ancestor(of: find.text('FILLED'), matching: find.byType(Container)),
    );
    expect(containers.isNotEmpty, true);
  });

  testWidgets('AetherEmptyState shows icon, title, message, and action', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AetherEmptyState(
          icon: Icons.inbox_outlined,
          title: 'Nothing here',
          message: 'Try again later.',
          action: AetherPrimaryButton(label: 'Reload', onPressed: () {}),
        ),
      ),
    );
    expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
    expect(find.text('Nothing here'), findsOneWidget);
    expect(find.text('Try again later.'), findsOneWidget);
    expect(find.text('Reload'), findsOneWidget);
  });

  testWidgets('AetherSegmentedControl changes selection on tap', (tester) async {
    String current = 'a';
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            return AetherSegmentedControl<String>(
              value: current,
              onChanged: (v) => setState(() => current = v),
              options: const [
                (value: 'a', label: 'Alpha', icon: null),
                (value: 'b', label: 'Beta', icon: null),
              ],
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(current, 'b');
  });

  testWidgets('AetherStatusDot pulses only when pulsing=true', (tester) async {
    await tester.pumpWidget(
      _host(
        const Row(
          children: [
            AetherStatusDot(color: Aether.success, pulsing: true),
            SizedBox(width: 8),
            AetherStatusDot(color: Aether.danger),
          ],
        ),
      ),
    );
    final pulsingFinder = find.byWidgetPredicate(
      (w) => w is AetherStatusDot && w.pulsing,
    );
    final staticFinder = find.byWidgetPredicate(
      (w) => w is AetherStatusDot && !w.pulsing,
    );
    expect(
      find.descendant(of: pulsingFinder, matching: find.byType(AnimatedBuilder)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: staticFinder, matching: find.byType(AnimatedBuilder)),
      findsNothing,
    );
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('AetherField surfaces errorText below the input', (tester) async {
    await tester.pumpWidget(
      _host(
        const AetherField(
          label: 'Email',
          errorText: 'Required field.',
        ),
      ),
    );
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Required field.'), findsOneWidget);
  });

  testWidgets('AetherStepper clamps to min and max', (tester) async {
    int value = 3;
    late int captured;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            return AetherStepper(
              value: value,
              min: 3,
              max: 4,
              onChanged: (v) {
                captured = v;
                setState(() => value = v);
              },
            );
          },
        ),
      ),
    );

    // At min: minus button is disabled (hit test disabled; ensure value unchanged).
    captured = -1;
    await tester.tap(find.byIcon(Icons.remove), warnIfMissed: false);
    await tester.pump();
    expect(value, 3);

    // Plus brings to max (4).
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    expect(captured, 4);
    expect(value, 4);

    // At max: plus disabled.
    captured = -1;
    await tester.tap(find.byIcon(Icons.add), warnIfMissed: false);
    await tester.pump();
    expect(value, 4);
  });

  testWidgets('AetherSheet renders title, child, and actions', (tester) async {
    await tester.pumpWidget(
      _host(
        AetherSheet(
          title: 'Sheet title',
          actions: [AetherGhostButton(label: 'Dismiss', onPressed: () {})],
          child: const Text('sheet-body-marker'),
        ),
      ),
    );
    expect(find.text('Sheet title'), findsOneWidget);
    expect(find.text('sheet-body-marker'), findsOneWidget);
    expect(find.text('Dismiss'), findsOneWidget);
  });

  testWidgets('AetherGradientHeader + AetherSectionTitle render', (tester) async {
    await tester.pumpWidget(
      _host(
        const AetherGradientHeader(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: AetherSectionTitle(
              eyebrow: 'Overview',
              subtitle: 'Everything at a glance',
            ),
          ),
        ),
      ),
    );
    expect(find.text('OVERVIEW'), findsOneWidget);
    expect(find.text('Everything at a glance'), findsOneWidget);
  });
}
