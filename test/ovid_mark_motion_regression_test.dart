import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/widgets/ovid_mark.dart';

Widget host(Widget child, {bool reduced = false}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reduced),
  child: Directionality(textDirection: TextDirection.ltr, child: Center(child: child)),
);

CustomPainter painter(WidgetTester tester) => tester.widget<CustomPaint>(find.byType(CustomPaint)).painter!;

Future<List<int>> pixels(CustomPainter painter) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), const Size(80, 80));
  final picture = recorder.endRecording();
  final image = await picture.toImage(80, 80);
  try {
    final bytes = await image.toByteData();
    return bytes!.buffer.asUint8List().toList();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  for (final animation in OvidMarkAnimation.values) {
    testWidgets('$animation reduced motion paints the complete static mark and stays idle', (tester) async {
      for (final variant in OvidMarkVariant.values) {
        await tester.pumpWidget(host(OvidMark(size: 80, variant: variant)));
        final expected = await tester.runAsync(() => pixels(painter(tester)));
        await tester.pumpWidget(host(OvidMarkAnimated(size: 80, variant: variant, animation: animation), reduced: true));
        final actual = await tester.runAsync(() => pixels(painter(tester)));
        expect(actual, expected);
        await tester.pump(const Duration(seconds: 4));
        expect(tester.binding.transientCallbackCount, 0);
      }
    });
  }

  testWidgets('changing animation restarts with its new period and repaints at equal progress', (tester) async {
    await tester.pumpWidget(host(const OvidMarkAnimated(animation: OvidMarkAnimation.drawOn)));
    final oldPainter = painter(tester);
    await tester.pumpWidget(host(const OvidMarkAnimated(animation: OvidMarkAnimation.blink)));
    expect(painter(tester).shouldRepaint(oldPainter), isTrue);
    final controller = tester.widget<AnimatedBuilder>(find.byType(AnimatedBuilder)).animation as AnimationController;
    await tester.pump(const Duration(milliseconds: 550));
    expect(controller.value, closeTo(0.5, 0.01));
    await tester.pumpWidget(host(const OvidMarkAnimated(animation: OvidMarkAnimation.reveal)));
    expect(controller.value, 0);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(controller.value, closeTo(0.5, 0.01));
    await tester.pumpWidget(const SizedBox());
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('motion preference toggles stop and resume the current animation', (tester) async {
    await tester.pumpWidget(host(const OvidMarkAnimated()));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(host(const OvidMarkAnimated(animation: OvidMarkAnimation.reveal), reduced: true));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(host(const OvidMarkAnimated(animation: OvidMarkAnimation.blink), reduced: true));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(host(const OvidMarkAnimated(animation: OvidMarkAnimation.blink)));
    await tester.pump(const Duration(milliseconds: 550));
    final controller = tester.widget<AnimatedBuilder>(find.byType(AnimatedBuilder)).animation as AnimationController;
    expect(controller.isAnimating, isTrue);
    expect(controller.value, closeTo(0.5, 0.01));
    await tester.pumpWidget(const SizedBox());
    expect(tester.binding.transientCallbackCount, 0);
  });
}
