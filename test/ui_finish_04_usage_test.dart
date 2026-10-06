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
import 'package:ovid_ai/core/cloud_usage_store.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/image_receipt_panel.dart';
import 'package:ovid_ai/ui/usage_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _provider = 'Acme Models with a long provider name';
const _model =
    'acme/research-reasoning-model-with-a-very-long-version-2026-10-preview';
const _captureKey = ValueKey('usage-review-boundary');

UsageEntry _entry({
  String provider = 'custom-acme',
  String name = _provider,
  String model = _model,
  DateTime? time,
  int input = 20,
  int output = 10,
}) => UsageEntry(
  time: time ?? DateTime.now(),
  providerId: provider,
  providerName: name,
  model: model,
  promptTokens: input,
  completionTokens: output,
  totalTokens: input + output,
  duration: const Duration(seconds: 1),
);

http.Response _usage({double remaining = .37, String tier = '15x'}) =>
    http.Response(
      jsonEncode({
        'tier': tier,
        'is_paid': tier != 'free',
        'remaining_pct': remaining,
        'models': [
          {'model': 'ovid-pro-1', 'remaining_pct': .23},
        ],
      }),
      200,
    );

Future<void> _frames(WidgetTester tester) async {
  // Bounded pumps also work while a controlled request remains pending.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _mount(
  WidgetTester tester, {
  Size size = const Size(360, 640),
  double scale = 1,
  bool dark = true,
  Widget screen = const UsageScreen(),
}) async {
  Aether.dark = dark;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: Aether.theme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: RepaintBoundary(key: _captureKey, child: child!),
      ),
      home: screen,
    ),
  );
  await _frames(tester);
}

Future<void> _show(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(target, 180, maxScrolls: 60);
  await tester.ensureVisible(target);
  await _frames(tester);
  expect(tester.takeException(), isNull);
}

void _expectReadable(WidgetTester tester, String value) {
  final paragraph = tester.renderObject<RenderParagraph>(find.text(value));
  expect(paragraph.didExceedMaxLines, isFalse, reason: value);
  final lines = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: value.length),
  ).map((box) => box.top).toSet();
  expect(lines.length, greaterThan(1), reason: value);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    OvidCloudService.idTokenOverrideForTest = () async => 'usage-review-account';
    OvidCloudService.httpClientFactoryForTest = () =>
        MockClient((_) async => _usage());
  });

  tearDown(() {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
    Aether.dark = true;
  });

  testWidgets('pending first fetch does not invent remaining allowance', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    OvidCloudService.httpClientFactoryForTest = () =>
        MockClient((_) => pending.future);
    await _mount(tester, scale: 2);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Saved plan · awaiting server confirmation'), findsOneWidget);
    expect(find.textContaining('updated now'), findsNothing);
    pending.complete(_usage());
    await _frames(tester);
    expect(find.text('37% remaining'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cached allowance and plan never claim fresh during failure or retry', (
    tester,
  ) async {
    AppState.I.setOvidCloudTier('free');
    await _mount(tester, scale: 2);
    expect(find.text('MAX'), findsOneWidget);
    expect(find.text('37% remaining'), findsOneWidget);
    expect(find.text('Server-confirmed plan and allowance'), findsOneWidget);
    expect(find.textContaining('updated now'), findsNothing);

    final pending = Completer<http.Response>();
    OvidCloudService.httpClientFactoryForTest = () =>
        MockClient((_) => pending.future);
    final store = CloudUsageStore.acquire(AppState.I);
    store.refresh();
    await tester.pump(const Duration(seconds: 3));
    await _frames(tester);
    expect(find.text('37% remaining'), findsOneWidget);
    expect(find.text('Last known plan and allowance'), findsOneWidget);
    expect(find.textContaining('updated now'), findsNothing);

    pending.complete(http.Response('down', 503));
    await _frames(tester);
    expect(find.text('MAX'), findsOneWidget);
    expect(find.textContaining('may be out of date'), findsOneWidget);
    await _show(tester, find.text('Retry'));
    OvidCloudService.httpClientFactoryForTest = () =>
        MockClient((_) async => _usage(remaining: .61, tier: '3x'));
    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(seconds: 3));
    await _frames(tester);
    await tester.drag(find.byType(ListView).first, const Offset(0, 1200));
    await _frames(tester);
    expect(find.text('61% remaining'), findsOneWidget);
    expect(find.text('PLUS'), findsOneWidget);
    expect(find.textContaining('may be out of date'), findsNothing);
    expect(tester.takeException(), isNull);
    store.release();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('first-load failure distinguishes saved plan from unavailable usage', (
    tester,
  ) async {
    AppState.I.setOvidCloudTier('7x');
    OvidCloudService.httpClientFactoryForTest = () =>
        MockClient((_) async => http.Response('down', 503));
    await _mount(tester);
    expect(find.text('PRO'), findsOneWidget);
    expect(find.text('Usage unavailable'), findsOneWidget);
    expect(find.text('Saved plan · awaiting server confirmation'), findsOneWidget);
    expect(find.textContaining('updated now'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await _show(tester, find.text('No usage yet'));
    expect(find.text('Start a chat to see per-provider usage here.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cloud-only usage leaves local totals and local empty state empty', (
    tester,
  ) async {
    AppState.I.usageLog.add(_entry(
      provider: AppState.ovidCloudProviderId,
      name: 'Ovid Cloud',
      input: 900000,
    ));
    await _mount(tester, scale: 2);
    expect(find.text('37% remaining'), findsOneWidget);
    await _show(tester, find.text('0'));
    expect(find.text('0 in · 0 out'), findsOneWidget);
    await _show(tester, find.text('No usage yet'));
    expect(find.text('Show 1 model'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final viewport in [
    (const Size(320, 640), 1.0),
    (const Size(360, 640), 2.0),
    (const Size(1024, 768), 1.0),
  ]) {
    for (final dark in [true, false]) {
      testWidgets('counts, readable models and receipts ${viewport.$1} '
          '${viewport.$2}x ${dark ? 'dark' : 'light'}', (tester) async {
        AppState.I.usageLog.addAll([
          _entry(provider: AppState.ovidCloudProviderId, name: 'Ovid Cloud', input: 900000),
          _entry(),
          _entry(),
        ]);
        await _mount(tester, size: viewport.$1, scale: viewport.$2, dark: dark);
        expect(find.text('37% remaining'), findsOneWidget);
        expect(find.text('MAX'), findsOneWidget);
        expect(find.text('Ovid Cloud'), findsOneWidget);
        await _show(tester, find.text('60'));
        expect(find.text('40 in · 20 out'), findsOneWidget);
        await _show(tester, find.text('Show 1 model'));
        expect(find.text('2 requests · 40 in · 20 out'), findsOneWidget);
        await tester.tap(find.text('Show 1 model'));
        await _frames(tester);
        await _show(tester, find.text(_model));
        expect(find.text('2 req · 60 tok'), findsOneWidget);
        if (viewport.$1.width < 400) _expectReadable(tester, _model);
        final text = tester.widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? '').join(' ');
        expect(text, isNot(matches(RegExp(r'\$|USD', caseSensitive: false))));
        await _show(tester, find.text('Hide models'));
        await tester.tap(find.text('Hide models'));
        await _frames(tester);
        expect(find.text(_model), findsNothing);

        await tester.tap(find.byTooltip('More actions'));
        await _frames(tester);
        await tester.tap(find.text('Image receipts'));
        await _frames(tester);
        expect(find.byType(ImageReceiptsScreen), findsOneWidget);
        expect(find.byType(ImageReceiptPanel), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  ProviderUsage seed() => ProviderUsage(
    providerId: 'custom-acme', providerName: _provider, tier: 'BYOK',
    icon: Icons.cloud, color: Aether.accent, requests: 3,
    tokensIn: 60, tokensOut: 30, models: [(_model, 3, 90)],
  );

  testWidgets('detail does not invent an activity chart from snapshot counts', (
    tester,
  ) async {
    await _mount(tester, scale: 2, screen: ProviderUsageScreen(provider: seed()));
    await _show(tester, find.text('Not enough recent activity for a trend.'));
    expect(find.byKey(const ValueKey('usage-activity-chart')), findsNothing);
    await _show(tester, find.text(_model));
    _expectReadable(tester, _model);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('activity uses timestamped calendar days and leaves empty days at zero', (
    tester,
  ) async {
    final now = DateTime.now();
    AppState.I.usageLog.addAll([
      _entry(time: DateTime(now.year, now.month, now.day - 2, 12)),
      _entry(time: DateTime(now.year, now.month, now.day, 0), input: 50),
      _entry(time: DateTime(now.year, now.month, now.day + 1), input: 999),
    ]);
    await _mount(tester, screen: ProviderUsageScreen(provider: seed()));
    await _show(tester, find.byKey(const ValueKey('usage-activity-chart')));
    final bars = tester.widgetList<FractionallySizedBox>(find.descendant(
      of: find.byKey(const ValueKey('usage-activity-chart')),
      matching: find.byType(FractionallySizedBox),
    )).map((bar) => bar.heightFactor).toList();
    expect(bars, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, .5, 0, 1]);
    expect(find.text('13 days ago'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('capture usage review', (tester) async {
    AppState.I.usageLog.add(_entry());
    await _mount(tester, size: const Size(1024, 768));
    expect(find.text('37% remaining'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('UI_REVIEW_CAPTURE')) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/opencode/ui-finish-04.png').writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
