import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/widgets/ovid_mark.dart';

Widget host(Widget child) => MaterialApp(
  theme: Aether.theme(),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('OvidMark paints the ring + agent square for every variant', (
    tester,
  ) async {
    for (final v in OvidMarkVariant.values) {
      await tester.pumpWidget(host(OvidMark(size: 48, variant: v)));
      expect(find.byType(CustomPaint), findsWidgets);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('OvidWordmark renders "Ovid Si" with the Si in Signal Red', (
    tester,
  ) async {
    await tester.pumpWidget(host(const OvidWordmark(size: 26)));
    final text = tester.widget<Text>(
      find.descendant(
        of: find.byType(OvidWordmark),
        matching: find.byType(Text),
      ),
    );
    final span = text.textSpan! as TextSpan;
    final children = span.children!.cast<TextSpan>();
    expect(children.first.text, 'Ovid ');
    expect(children.first.style!.color, Aether.ink);
    expect(children.last.text, 'Si');
    expect(children.last.style!.color, Aether.signalRed);
  });

  testWidgets('OvidLockup scales down instead of overflowing at 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const Scaffold(body: Center(child: OvidLockup(markSize: 42, textSize: 28))),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('OvidMarkAnimated animates and never leaks (bounded pumps)', (
    tester,
  ) async {
    for (final a in OvidMarkAnimation.values) {
      await tester.pumpWidget(host(OvidMarkAnimated(size: 80, animation: a)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(CustomPaint), findsWidgets);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('OvidMarkAnimated freezes under reduce-motion', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const Scaffold(
          body: Center(
            child: OvidMarkAnimated(size: 80, animation: OvidMarkAnimation.reveal),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
