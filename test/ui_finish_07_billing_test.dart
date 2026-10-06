import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/billing_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _usage(String tier, {double? remaining = .37}) => {
  'tier': tier,
  'is_paid': tier != 'free',
  'remaining_pct': ?remaining,
  'models': const [],
};

// Bound animation pumping so an accidentally stuck checkout spinner fails
// assertions instead of hanging the suite.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _mount(
  WidgetTester tester, {
  Size size = const Size(360, 640),
  double scale = 2,
  bool dark = true,
  GlobalKey? captureKey,
}) async {
  final previousDark = Aether.dark;
  Aether.dark = dark;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    Aether.dark = previousDark;
  });
  await tester.pumpWidget(
    RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        theme: Aether.theme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
        home: const BillingScreen(),
      ),
    ),
  );
  await _frames(tester);
}

Future<void> _reveal(WidgetTester tester, Finder finder,
    {double delta = 180}) async {
  await tester.scrollUntilVisible(
    finder, delta, maxScrolls: 80,
    scrollable: find.byType(Scrollable).last,
  );
  await _frames(tester);
  expect(tester.takeException(), isNull);
}

void _honestCopy(WidgetTester tester) {
  final copy = tester.widgetList<Text>(find.byType(Text))
      .map((text) => text.data ?? '').join(' ');
  expect(copy, isNot(matches(RegExp(
    r'USD|\$|Renews on|auto-renew|GST|Google Play|/ month|'
    r'Priority routing|faster response|models unlocked|Pro-tier|Max-tier',
    caseSensitive: false,
  ))));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    OvidCloudService.idTokenOverrideForTest = () async => 'billing-test-token';
    OvidCloudService.httpClientFactoryForTest = () => MockClient((request) async {
      if (request.url.path.endsWith('/models')) {
        return http.Response('{"data":[{"id":"ovid-base"}]}', 200);
      }
      return http.Response(jsonEncode(_usage('free')), 200);
    });
  });

  tearDown(() {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  for (final viewport in [
    (const Size(360, 640), 2.0),
    (const Size(320, 640), 1.0),
    (const Size(1024, 768), 1.0),
  ]) {
    for (final dark in [true, false]) {
      testWidgets('plans and checkout ${viewport.$1} ${viewport.$2}x dark=$dark',
          (tester) async {
        await _mount(tester, size: viewport.$1, scale: viewport.$2, dark: dark);
        expect(find.text('37% remaining'), findsOneWidget);
        expect(tester.takeException(), isNull);
        for (final entry in [
          ('free', 'Free', '×1'),
          ('3x', '₹499', '×3'),
          ('7x', '₹899', '×7'),
          ('15x', '₹1699', '×15'),
        ]) {
          final card = find.byKey(ValueKey('plan-${entry.$1}'));
          await _reveal(tester, card);
          expect(find.descendant(of: card, matching: find.text(entry.$2)),
              findsWidgets);
          expect(find.descendant(of: card, matching: find.text(entry.$3)),
              findsOneWidget);
          _honestCopy(tester);
          if (entry.$1 == 'free') {
            final current = find.widgetWithText(FilledButton, 'Current plan');
            await _reveal(tester, current);
            expect(tester.widget<FilledButton>(current).onPressed, isNull);
            final label = find.descendant(of: current, matching: find.text('Current plan'));
            expect(tester.getRect(current).contains(tester.getRect(label).bottomRight), isTrue);
          }
        }
        final upgrade = find.byKey(const ValueKey('upgrade-15x'));
        await _reveal(tester, upgrade);
        await tester.tap(upgrade);
        await _frames(tester);
        expect(find.text('Upgrade to Max'), findsOneWidget);
        _honestCopy(tester);
        expect(find.descendant(
          of: find.byType(BottomSheet),
          matching: find.textContaining('when enabled by the server'),
        ), findsOneWidget);
        final pay = find.widgetWithText(FilledButton, 'Pay now · ₹1699');
        await _reveal(tester, pay);
        expect(tester.getSize(pay).height, greaterThanOrEqualTo(48));
        await _reveal(tester, find.text('Cancel'));
        await tester.tap(find.text('Cancel'));
        await _frames(tester);
        expect(find.text('Upgrade to Max'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('unknown tier and absent allowance stay unknown', (tester) async {
    OvidCloudService.httpClientFactoryForTest = () => MockClient((_) async =>
        http.Response(jsonEncode(_usage('future-tier', remaining: null)), 200));
    await _mount(tester);
    expect(find.text('Plan unavailable'), findsOneWidget);
    expect(find.text('UNKNOWN'), findsOneWidget);
    expect(find.text('Usage unavailable'), findsOneWidget);
    expect(find.textContaining('% remaining'), findsNothing);
    expect(find.byKey(const ValueKey('upgrade-header')), findsNothing);
    _honestCopy(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final success in [true, false]) {
    testWidgets('card checkout ${success ? 'confirms' : 'rejects'} only server result',
        (tester) async {
      var tier = 'free';
      var calls = 0;
      final response = Completer<http.Response>();
      OvidCloudService.httpClientFactoryForTest = () => MockClient((request) async {
        if (request.url.path == '/upgrade') {
          calls++;
          expect(jsonDecode(request.body), {'tier': '3x'});
          return response.future;
        }
        if (request.url.path.endsWith('/models')) {
          return http.Response('{"data":[{"id":"ovid-base"}]}', 200);
        }
        return http.Response(jsonEncode(_usage(tier)), 200);
      });
      await _mount(tester);
      final upgrade = find.byKey(const ValueKey('upgrade-3x'));
      await _reveal(tester, upgrade);
      await tester.tap(upgrade);
      await _frames(tester);
      final pay = find.byKey(const ValueKey('billing-pay-now'));
      await _reveal(tester, pay);
      await tester.tap(pay);
      await _frames(tester);
      expect(tester.widget<FilledButton>(pay).onPressed, isNull);
      await tester.tap(pay);
      await tester.pump();
      expect(calls, 1);
      expect(AppState.I.ovidCloudTier, 'free');
      if (success) tier = '3x';
      response.complete(http.Response(
        jsonEncode({'ok': success, 'tier': tier}), success ? 200 : 403,
      ));
      await _frames(tester);
      expect(AppState.I.ovidCloudTier, tier);
      expect(find.byKey(const ValueKey('billing-pay-now')), findsNothing);
      expect(find.text(success
          ? 'You are now on the Plus plan.'
          : 'Could not complete the upgrade. Try again.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('paid account distinguishes current, lower and higher choices', (tester) async {
    OvidCloudService.httpClientFactoryForTest = () => MockClient((_) async =>
        http.Response(jsonEncode(_usage('7x')), 200));
    await _mount(tester);
    expect(find.text('PRO'), findsOneWidget);
    _honestCopy(tester);
    await _reveal(tester, find.byKey(const ValueKey('plan-free')));
    expect(find.byKey(const ValueKey('upgrade-free')), findsNothing);
    final change = find.byKey(const ValueKey('upgrade-3x'));
    await _reveal(tester, change);
    expect(find.descendant(of: change, matching: find.text('Change plan')), findsOneWidget);
    await tester.tap(change);
    await _frames(tester);
    expect(find.text('Change to Plus'), findsOneWidget);
    await _reveal(tester, find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await _frames(tester);
    await _reveal(tester, find.widgetWithText(FilledButton, 'Current plan'));
    expect(find.byKey(const ValueKey('upgrade-7x')), findsNothing);
    await _reveal(tester, find.byKey(const ValueKey('upgrade-15x')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('loading and server failure expose retry without inventing usage', (tester) async {
    final response = Completer<http.Response>();
    var calls = 0;
    OvidCloudService.httpClientFactoryForTest = () => MockClient((_) async {
      calls++;
      if (calls == 1) return response.future;
      return http.Response(jsonEncode(_usage('free', remaining: .62)), 200);
    });
    await _mount(tester);
    expect(find.text('Refreshing allowance…'), findsOneWidget);
    expect(find.textContaining('% remaining'), findsNothing);
    expect(tester.takeException(), isNull);
    response.complete(http.Response('{}', 503));
    await _frames(tester);
    expect(find.textContaining('(503)'), findsOneWidget);
    expect(find.textContaining('% remaining'), findsNothing);
    await _reveal(tester, find.text('Retry'));
    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(seconds: 2));
    await _frames(tester);
    expect(calls, 2);
    // Revealing Retry scrolls the tall 2x error header upward. Once the
    // error clears that header shrinks and can leave the lazy viewport;
    // return to it before asserting the server's recovered allowance.
    await _reveal(tester, find.text('62% remaining'), delta: -180);
    expect(find.text('62% remaining'), findsOneWidget);
    expect(find.textContaining('(503)'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('opt-in billing screenshot', (tester) async {
    final key = GlobalKey();
    await _mount(tester, captureKey: key);
    expect(find.text('37% remaining'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('UI_REVIEW_CAPTURE')) {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/opencode/ui-finish-07.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
