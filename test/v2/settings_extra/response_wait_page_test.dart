import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_motion.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings_extra/response_wait_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _consequence = 'Ovid shows "Still working…" and keeps waiting.';

/// The node a screen reader visits, with merged data — the same view TalkBack
/// gets, unlike `getSemantics`, which stops at the merge boundary.
SemanticsData _spokenNode(
  WidgetTester tester,
  bool Function(SemanticsData) test,
) {
  return tester.semantics
      .simulatedAccessibilityTraversal()
      .map((node) => node.getSemanticsData())
      .firstWhere(test);
}

Future<void> _pump(
  WidgetTester tester,
  V2ResponseWaitPageData data, {
  bool dark = false,
  Size size = const Size(420, 1000),
  double textScale = 1,
  bool disableAnimations = false,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations,
        ),
        child: child!,
      ),
      home: ResponseWaitPage(data: data),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  testWidgets('shows the stored value, one slider and the three presets', (
    tester,
  ) async {
    await _pump(tester, const V2ResponseWaitPageData(seconds: 120));

    expect(find.text('Response wait'), findsOneWidget);
    expect(find.text('When a reply goes quiet'), findsOneWidget);
    expect(find.text('2 min'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byType(OChip), findsNWidgets(3));
    expect(find.text('Fast · 15 s'), findsOneWidget);
    expect(find.text('Balanced · 45 s'), findsOneWidget);
    expect(find.text('Deep · 2 min'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('states the consequence once, under the value', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, const V2ResponseWaitPageData(seconds: 120));

    expect(find.text(_consequence), findsOneWidget);

    final valueY = tester
        .getTopLeft(find.byKey(const ValueKey('response-wait-current')))
        .dy;
    final consequenceY = tester
        .getTopLeft(find.byKey(const ValueKey('response-wait-consequence')))
        .dy;
    final sliderY = tester.getTopLeft(find.byType(Slider)).dy;
    expect(valueY, lessThan(consequenceY));
    expect(consequenceY, lessThan(sliderY));

    // TalkBack hears the value first, then the consequence.
    final spoken = _spokenNode(
      tester,
      (data) => data.label.contains(_consequence),
    );
    final lines = spoken.label.split('\n');
    expect(lines.first.trim(), '2 min');
    expect(lines.last.trim(), _consequence);

    handle.dispose();
  });

  testWidgets('renders in dark', (tester) async {
    await _pump(tester, const V2ResponseWaitPageData(seconds: 120), dark: true);

    expect(find.byType(Slider), findsOneWidget);
    expect(find.byType(OChip), findsNWidgets(3));
  });

  testWidgets('a preset snaps the slider, selects the chip and writes', (
    tester,
  ) async {
    final writes = <int>[];
    await _pump(
      tester,
      V2ResponseWaitPageData(
        seconds: 120,
        onPreset: (seconds) async => writes.add(seconds),
      ),
    );

    await tester.tap(find.widgetWithText(OPressable, 'Fast · 15 s'));
    await tester.pumpAndSettle();

    expect(writes, <int>[15]);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 15);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('response-wait-current')))
          .data,
      '15 s',
    );
    expect(
      tester.getSemantics(find.widgetWithText(OPressable, 'Fast · 15 s')),
      isSemantics(
        label: 'Fast, 15 s wait time',
        isButton: true,
        isEnabled: true,
        isSelected: true,
      ),
    );
    expect(
      tester.getSemantics(find.widgetWithText(OPressable, 'Deep · 2 min')),
      isSemantics(isSelected: false),
    );
  });

  testWidgets('the slider writes a value inside the real bounds', (
    tester,
  ) async {
    final writes = <int>[];
    await _pump(
      tester,
      V2ResponseWaitPageData(
        seconds: 120,
        onChanged: (seconds) async => writes.add(seconds),
      ),
    );

    await tester.tapAt(tester.getCenter(find.byType(Slider)));
    await tester.pumpAndSettle();

    expect(writes, isNotEmpty);
    final seconds = writes.last;
    expect(seconds, greaterThanOrEqualTo(15));
    expect(seconds, lessThanOrEqualTo(600));
    expect((seconds - 15) % 15, 0);
    expect(
      tester.widget<Slider>(find.byType(Slider)).value,
      seconds.toDouble(),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('response-wait-current')))
          .data,
      seconds < 60
          ? '$seconds s'
          : seconds % 60 == 0
          ? '${seconds ~/ 60} min'
          : '${seconds ~/ 60} min ${seconds % 60} s',
    );
  });

  testWidgets('the slider announces its value and its range', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      V2ResponseWaitPageData(seconds: 120, onChanged: (_) async {}),
    );

    final slider = _spokenNode(tester, (data) => data.flagsCollection.isSlider);
    expect(slider.label, 'Response wait limit, 15 seconds to 10 minutes');
    expect(slider.value, '2 min');
    expect(slider.flagsCollection.isEnabled, ui.Tristate.isTrue);
    expect(slider.hasAction(SemanticsAction.increase), isTrue);
    expect(slider.hasAction(SemanticsAction.decrease), isTrue);

    handle.dispose();
  });

  testWidgets('the slider uses the product bounds and the presets are stops', (
    tester,
  ) async {
    await _pump(tester, const V2ResponseWaitPageData(seconds: 120));

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.min, AppState.minResponseTimeoutSec.toDouble());
    expect(slider.max, AppState.maxResponseTimeoutSec.toDouble());
    expect(
      slider.divisions,
      (AppState.maxResponseTimeoutSec - AppState.minResponseTimeoutSec) ~/ 15,
    );
    for (final preset in <int>[15, 45, 120]) {
      expect(preset, greaterThanOrEqualTo(AppState.minResponseTimeoutSec));
      expect(preset, lessThanOrEqualTo(AppState.maxResponseTimeoutSec));
      expect((preset - slider.min) % 15, 0);
    }
  });

  testWidgets('an unset value is loading, never a made-up choice', (
    tester,
  ) async {
    await _pump(
      tester,
      const V2ResponseWaitPageData(),
      size: const Size(320, 700),
      textScale: 2,
      settle: false,
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.byKey(const ValueKey('response-wait-current')), findsNothing);
    expect(find.text('2 min'), findsNothing);
  });

  testWidgets('a value outside the product bounds is not shown as chosen', (
    tester,
  ) async {
    await _pump(
      tester,
      const V2ResponseWaitPageData(seconds: 0),
      settle: false,
    );

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('shows the error state and retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      V2ResponseWaitPageData(
        errorMessage: 'Could not load your wait time.',
        onRetry: () => retries++,
      ),
    );

    expect(find.text('Could not load your wait time.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(retries, 1);
  });

  testWidgets('a failed save rolls back and reports inline', (tester) async {
    var fail = true;
    final writes = <int>[];
    Future<void> save(int seconds) async {
      if (fail) throw StateError('disk full');
      writes.add(seconds);
    }

    await _pump(
      tester,
      V2ResponseWaitPageData(seconds: 120, onChanged: save, onPreset: save),
    );

    await tester.tap(find.widgetWithText(OPressable, 'Fast · 15 s'));
    await tester.pumpAndSettle();

    // The thumb and the readout go back to the last saved value.
    expect(tester.widget<Slider>(find.byType(Slider)).value, 120);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('response-wait-current')))
          .data,
      '2 min',
    );
    expect(find.text('Could not save. Still 2 min.'), findsOneWidget);
    expect(writes, isEmpty);

    // The next attempt clears the message and keeps the new value.
    fail = false;
    await tester.tap(find.widgetWithText(OPressable, 'Fast · 15 s'));
    await tester.pumpAndSettle();

    expect(writes, <int>[15]);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('response-wait-current')))
          .data,
      '15 s',
    );
    expect(find.text('Could not save. Still 2 min.'), findsNothing);
  });

  testWidgets('a failed slider save rolls back to the saved value', (
    tester,
  ) async {
    await _pump(
      tester,
      V2ResponseWaitPageData(
        seconds: 120,
        onChanged: (_) async => throw StateError('disk full'),
      ),
    );

    await tester.tapAt(tester.getCenter(find.byType(Slider)));
    await tester.pumpAndSettle();

    expect(tester.widget<Slider>(find.byType(Slider)).value, 120);
    expect(find.textContaining('Could not save.'), findsOneWidget);
  });

  testWidgets('the chosen wait persists and survives a restart', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    addTearDown(AppState.resetTestInstance);

    await _pump(
      tester,
      V2ResponseWaitPageData(
        seconds: AppState.I.responseTimeoutSec,
        onChanged: AppState.I.setResponseTimeout,
        onPreset: AppState.I.setResponseTimeout,
      ),
    );

    await tester.tap(find.widgetWithText(OPressable, 'Fast · 15 s'));
    await tester.pumpAndSettle();

    expect(AppState.I.responseTimeoutSec, 15);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('ovid_response_timeout_sec'), 15);

    // Restart: a fresh state reads the same key back.
    AppState.resetTestInstance();
    AppState.createForTest();
    await AppState.I.reloadShellPreferencesForTest();
    expect(AppState.I.responseTimeoutSec, 15);

    await _pump(
      tester,
      V2ResponseWaitPageData(seconds: AppState.I.responseTimeoutSec),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('response-wait-current')))
          .data,
      '15 s',
    );
  });

  testWidgets('the slider writes through the same persisted seam', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    addTearDown(AppState.resetTestInstance);

    await _pump(
      tester,
      V2ResponseWaitPageData(
        seconds: AppState.I.responseTimeoutSec,
        onChanged: AppState.I.setResponseTimeout,
        onPreset: AppState.I.setResponseTimeout,
      ),
    );

    await tester.tapAt(tester.getCenter(find.byType(Slider)));
    await tester.pumpAndSettle();

    final seconds = AppState.I.responseTimeoutSec;
    expect(seconds, greaterThanOrEqualTo(15));
    expect(seconds, lessThanOrEqualTo(600));
    expect((seconds - 15) % 15, 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('ovid_response_timeout_sec'), seconds);
  });

  testWidgets('the save error fits 320 dp at 200 % text', (tester) async {
    await _pump(
      tester,
      V2ResponseWaitPageData(
        seconds: 120,
        onPreset: (_) async => throw StateError('disk full'),
      ),
      size: const Size(320, 700),
      textScale: 2,
    );

    await tester.ensureVisible(find.widgetWithText(OPressable, 'Fast · 15 s'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OPressable, 'Fast · 15 s'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('response-wait-save-error')),
      findsOneWidget,
    );
  });

  testWidgets('chips keep a 48 dp touch target', (tester) async {
    await _pump(
      tester,
      V2ResponseWaitPageData(seconds: 120, onPreset: (_) async {}),
    );

    expect(find.byType(OPressable), findsNWidgets(3));
    for (final chip in find.byType(OPressable).evaluate()) {
      final size = tester.getSize(find.byWidget(chip.widget));
      expect(size.height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('disabled controls do not fire and are announced as disabled', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, const V2ResponseWaitPageData(seconds: 120));

    await tester.tap(find.widgetWithText(OPressable, 'Fast · 15 s'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(
      tester.getSemantics(find.widgetWithText(OPressable, 'Fast · 15 s')),
      isSemantics(isEnabled: false, label: 'Fast, 15 s wait time'),
    );
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    expect(
      tester.getSemantics(find.byType(Slider)),
      isSemantics(isEnabled: false),
    );

    handle.dispose();
  });

  testWidgets('enabled controls report enabled', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      V2ResponseWaitPageData(
        seconds: 120,
        onPreset: (_) async {},
        onChanged: (_) async {},
      ),
    );

    expect(
      tester.getSemantics(find.widgetWithText(OPressable, 'Fast · 15 s')),
      isSemantics(isButton: true, isEnabled: true),
    );
    expect(
      tester.getSemantics(find.byType(Slider)),
      isSemantics(isEnabled: true),
    );

    handle.dispose();
  });

  testWidgets('centres the card at 600 dp', (tester) async {
    await _pump(
      tester,
      const V2ResponseWaitPageData(seconds: 120),
      size: const Size(600, 1000),
    );

    final card = find.byType(OCard).first;
    expect(tester.getSize(card).width, lessThanOrEqualTo(640));
    expect(tester.getCenter(card).dx, closeTo(300, 0.5));
  });

  testWidgets('survives 320-1280 dp at 100 % and 200 % text, both themes', (
    tester,
  ) async {
    const sizes = <Size>[
      Size(320, 700),
      Size(360, 760),
      Size(412, 900),
      Size(600, 1000),
      Size(800, 1000),
      Size(1024, 1000),
      Size(1280, 1000),
    ];

    for (final size in sizes) {
      for (final scale in <double>[1, 2]) {
        for (final dark in <bool>[false, true]) {
          final reason =
              '${size.width} dp at ${scale}x '
              '(${dark ? 'dark' : 'light'})';
          await _pump(
            tester,
            const V2ResponseWaitPageData(seconds: 120),
            size: size,
            textScale: scale,
            dark: dark,
          );
          expect(tester.takeException(), isNull, reason: reason);

          final card = find.byType(OCard).first;
          expect(
            tester.getSize(card).width,
            lessThanOrEqualTo(size.width >= 900 ? 720 : 640),
            reason: reason,
          );
          expect(
            tester.getCenter(card).dx,
            closeTo(size.width / 2, 0.5),
            reason: reason,
          );
        }
      }
    }
  });

  testWidgets('reduced motion keeps every control on screen', (tester) async {
    await _pump(
      tester,
      const V2ResponseWaitPageData(seconds: 120),
      disableAnimations: true,
    );

    expect(find.byType(AnimatedSlide), findsNothing);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byType(OChip), findsNWidgets(3));
  });
}
