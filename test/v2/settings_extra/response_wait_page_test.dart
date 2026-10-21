import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_motion.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings_extra/response_wait_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  testWidgets('renders the current wait and presets in light', (tester) async {
    await _pump(tester, const V2ResponseWaitPageData());

    expect(find.text('Response wait limit'), findsOneWidget);
    expect(find.text('2 min'), findsNWidgets(2));
    expect(
      find.text('Ovid waits this long for a reply before it asks you.'),
      findsOneWidget,
    );
    expect(find.text('5 min'), findsOneWidget);
    expect(find.text('What happens at the limit'), findsOneWidget);
  });

  testWidgets('renders in dark', (tester) async {
    await _pump(tester, const V2ResponseWaitPageData(), dark: true);

    expect(find.text('Auto-extend'), findsOneWidget);
    expect(find.text('Notify me'), findsOneWidget);
  });

  testWidgets('applies a preset wait', (tester) async {
    int? preset;
    await _pump(
      tester,
      V2ResponseWaitPageData(onPreset: (seconds) => preset = seconds),
    );

    final chip = find.text('5 min');
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pumpAndSettle();

    expect(preset, 300);
  });

  testWidgets('changes the wait with the slider', (tester) async {
    final changes = <int>[];
    await _pump(tester, V2ResponseWaitPageData(onChanged: changes.add));

    await tester.tapAt(tester.getCenter(find.byType(Slider)));
    await tester.pumpAndSettle();

    expect(changes, isNotEmpty);
  });

  testWidgets('toggles auto-extend', (tester) async {
    bool? autoExtend;
    await _pump(
      tester,
      V2ResponseWaitPageData(onAutoExtend: (value) => autoExtend = value),
    );

    final toggle = find.byType(Switch).first;
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(autoExtend, isTrue);
  });

  testWidgets('toggles notify me', (tester) async {
    bool? notify;
    await _pump(
      tester,
      V2ResponseWaitPageData(onNotify: (value) => notify = value),
    );

    final toggle = find.byType(Switch).last;
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(notify, isFalse);
  });

  testWidgets('shows the skeleton while loading', (tester) async {
    await _pump(
      tester,
      const V2ResponseWaitPageData(loading: true),
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

  testWidgets('fits 320 dp at 200 % text in light', (tester) async {
    await _pump(
      tester,
      const V2ResponseWaitPageData(),
      size: const Size(320, 700),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Response wait limit'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('This applies to every chat.'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('This applies to every chat.'), findsOneWidget);
  });

  testWidgets('fits 320 dp at 200 % text in dark', (tester) async {
    await _pump(
      tester,
      const V2ResponseWaitPageData(seconds: 600),
      dark: true,
      size: const Size(320, 700),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('This applies to every chat.'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion keeps every control on screen', (tester) async {
    await _pump(
      tester,
      const V2ResponseWaitPageData(),
      disableAnimations: true,
    );

    expect(find.byType(AnimatedSlide), findsNothing);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byType(Switch), findsNWidgets(2));
    expect(find.text('What happens at the limit'), findsOneWidget);
  });

  testWidgets('disabled controls do not fire and are announced as disabled', (
    tester,
  ) async {
    await _pump(tester, const V2ResponseWaitPageData());

    final chip = find.text('5 min');
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final chipSemantics = tester.widget<Semantics>(
      find
          .descendant(
            of: find
                .ancestor(of: chip, matching: find.byType(OPressable))
                .first,
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(chipSemantics.properties.enabled, isFalse);
    expect(chipSemantics.properties.label, '5 min wait time');

    final sliderSemantics = tester.widget<Semantics>(
      find
          .ancestor(of: find.byType(Slider), matching: find.byType(Semantics))
          .first,
    );
    expect(sliderSemantics.properties.enabled, isFalse);

    final toggleSemantics = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.byType(Switch).first,
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(toggleSemantics.properties.enabled, isFalse);
    expect(toggleSemantics.properties.toggled, isFalse);
  });

  testWidgets('enabled controls report enabled', (tester) async {
    await _pump(
      tester,
      V2ResponseWaitPageData(
        onPreset: (_) {},
        onChanged: (_) {},
        onAutoExtend: (_) {},
      ),
    );

    final chip = find.text('5 min');
    final chipSemantics = tester.widget<Semantics>(
      find
          .descendant(
            of: find
                .ancestor(of: chip, matching: find.byType(OPressable))
                .first,
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(chipSemantics.properties.enabled, isTrue);

    final sliderSemantics = tester.widget<Semantics>(
      find
          .ancestor(of: find.byType(Slider), matching: find.byType(Semantics))
          .first,
    );
    expect(sliderSemantics.properties.enabled, isTrue);

    final toggleSemantics = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.byType(Switch).first,
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(toggleSemantics.properties.enabled, isTrue);
  });

  testWidgets('the slider keeps its new value (no silent revert)', (
    tester,
  ) async {
    final changes = <int>[];
    await _pump(tester, V2ResponseWaitPageData(onChanged: changes.add));

    await tester.tapAt(tester.getCenter(find.byType(Slider)));
    await tester.pumpAndSettle();

    expect(changes, isNotEmpty);
    final seconds = changes.last;
    final expected = seconds < 60
        ? '$seconds s'
        : seconds % 60 == 0
        ? '${seconds ~/ 60} min'
        : '${seconds ~/ 60} min ${seconds % 60} s';
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('response-wait-current')),
          )
          .data,
      expected,
    );
  });

  testWidgets('choosing a preset updates the display at once', (tester) async {
    await _pump(tester, V2ResponseWaitPageData(onPreset: (_) {}));

    expect(find.text('2 min'), findsNWidgets(2));

    await tester.ensureVisible(find.text('5 min').last);
    await tester.tap(find.text('5 min').last);
    await tester.pumpAndSettle();

    expect(find.text('5 min'), findsNWidgets(2));
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('response-wait-current')),
          )
          .data,
      '5 min',
    );
  });

  testWidgets('the option switches keep their new value', (tester) async {
    await _pump(
      tester,
      V2ResponseWaitPageData(onAutoExtend: (_) {}, onNotify: (_) {}),
    );

    final autoExtend = find.byType(Switch).first;
    await tester.ensureVisible(autoExtend);
    expect(tester.widget<Switch>(autoExtend).value, isFalse);
    await tester.tap(autoExtend);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(autoExtend).value, isTrue);

    final notify = find.byType(Switch).last;
    expect(tester.widget<Switch>(notify).value, isTrue);
    await tester.tap(notify);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(notify).value, isFalse);
  });

  testWidgets('the chosen wait persists where the chat reads it', (
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
        onPreset: AppState.I.setResponseTimeout,
      ),
    );

    await tester.ensureVisible(find.text('5 min').last);
    await tester.tap(find.text('5 min').last);
    await tester.pumpAndSettle();

    // `CloudAgentFacade._responseTimeoutStallWindow` reads this field; the
    // chat's "Still working…" label is driven by it.
    expect(AppState.I.responseTimeoutSec, 300);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('ovid_response_timeout_sec'), 300);
    expect(find.text('5 min'), findsNWidgets(2));
  });
}
