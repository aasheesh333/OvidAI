import 'dart:convert';
import 'dart:io';

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
import 'package:ovid_ai/core/usage_attempt.dart';
import 'package:ovid_ai/ui/usage_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-model usage redesign: header (plan, reset, overall bar, today) and the
/// per-model remaining list, with old-server and offline fallbacks. Prices are
/// never rendered: every payload below carries `*_usd` / cost fields.

int _seq = 0;

UsageAttempt _attempt({
  String provider = AppState.ovidCloudProviderId,
  String requested = 'auto',
  String? reported = 'ovid-lite',
  UsageTokenCount? input,
  UsageTokenCount? output,
  UsageOutcome outcome = UsageOutcome.succeeded,
}) {
  final id = 'per-model-${_seq++}';
  final at = DateTime.now().toUtc();
  return UsageAttempt(
    attemptId: id,
    requestId: 'request-$id',
    revision: 2,
    sourceDevice: 'test',
    provider: provider,
    requestedModel: requested,
    reportedModel: reported,
    purpose: 'agent',
    startedAt: at,
    completedAt: at,
    dispatchStage: UsageDispatchStage.completed,
    outcome: outcome,
    inputTokens: input,
    outputTokens: output,
  );
}

Map<String, dynamic> _payload({bool perModel = true, bool today = true}) => {
  'tier': '3x',
  'is_paid': true,
  'daily_spent_usd': 1.25,
  'daily_budget_usd': 9.99,
  'daily_remaining_usd': 8.74,
  'month_free_spent_usd': 0.5,
  'month_free_cap_usd': 10,
  'requests_today': 0,
  'budget_window': '30d',
  'remaining_pct': 0.9,
  if (perModel) ...{
    'window': '30d',
    'remaining_fraction': 0.62,
    'resets_at': DateTime.now()
        .toUtc()
        .add(const Duration(hours: 4, minutes: 12, seconds: 30))
        .toIso8601String(),
  },
  if (today)
    'today': {
      'requests': 12,
      'input_tokens': 34000,
      'output_tokens': 5600,
      'images': 2,
    },
  'models': perModel
      ? [
          {
            'id': 'ovid-pro',
            'name': 'Ovid Pro',
            'kind': 'chat',
            'priced': true,
            'remaining_messages': 40,
            'input_cost_per_token': 0.00001,
          },
          {
            'id': 'ovid-image:img-std',
            'name': 'Image Studio',
            'kind': 'image',
            'priced': true,
            'remaining_images': 8,
          },
          {
            'id': 'ovid-lite',
            'name': 'Ovid Lite',
            'kind': 'chat',
            'priced': true,
            'remaining_messages': 900,
          },
          {
            'id': 'custom-unpriced',
            'name': 'Custom model',
            'kind': 'chat',
            'priced': false,
            'remaining_messages': null,
          },
          {
            'id': 'auto',
            'name': 'Auto',
            'kind': 'chat',
            'priced': true,
            'remaining_messages': 120,
            'auto': true,
            'estimate': 'conservative',
          },
        ]
      : [
          {
            'model': 'auto',
            'input_cost_per_token': 0.000002,
            'output_cost_per_token': 0.000008,
            'remaining_pct': 0.9,
          },
        ],
};

/// Every string a user could see or hear: Text, RichText and semantics.
String _allCopy(WidgetTester tester) {
  final texts = [
    for (final w in tester.widgetList<Text>(find.byType(Text)))
      w.data ?? w.textSpan?.toPlainText() ?? '',
    for (final w in tester.widgetList<RichText>(find.byType(RichText)))
      w.text.toPlainText(),
  ];
  final semantics = <String>[];
  void visit(SemanticsNode node) {
    semantics.add(node.label);
    semantics.add(node.value);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  for (final scaffold in find.byType(Scaffold).evaluate()) {
    visit(tester.getSemantics(find.byWidget(scaffold.widget)));
  }
  return [...texts, ...semantics].join('\n');
}

final _currency = RegExp(
  r'\$|USD|€|£|₹|\bcost\b|\bprice',
  caseSensitive: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory usageRoot;
  late http.Response Function() respond;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    usageRoot = await Directory.systemTemp.createTemp('usage-per-model-');
    AppState.createForTest(usageRoot: usageRoot);
    await AppState.I.prepareUsageAttempts(
      owner: AppState.I.sessionAccountToken,
    );
    AgentService.I.debugPauseScheduleTimerForTest(true);
    OvidCloudService.idTokenOverrideForTest = () async => 'per-model-token';
    respond = () => http.Response(jsonEncode(_payload()), 200);
    OvidCloudService.httpClientFactoryForTest = () =>
        MockClient((_) async => respond());
  });

  tearDown(() async {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
    await usageRoot.delete(recursive: true);
  });

  Future<void> record(WidgetTester tester, List<UsageAttempt> rows) =>
      tester.runAsync(() async {
        for (final row in rows) {
          await AppState.I.recordUsageAttempt(
            row,
            owner: AppState.I.sessionAccountToken,
          );
        }
      });

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(420, 2400),
    double textScale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const UsageScreen(),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Finder inCell(String key, String text) =>
      find.descendant(of: find.byKey(ValueKey(key)), matching: find.text(text));

  testWidgets('header: plan, reset, overall bar and server today counters', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await mount(tester);
    expect(find.text('PLUS'), findsOneWidget);
    expect(find.text('Resets in 4h 12m'), findsOneWidget);
    expect(find.text('62% remaining'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.62,
    );
    expect(inCell('usage-requests-today', '12'), findsOneWidget);
    expect(inCell('usage-input-today', '34K'), findsOneWidget);
    expect(inCell('usage-output-today', '5.6K'), findsOneWidget);
    expect(inCell('usage-images-today', '2'), findsOneWidget);
    expect(find.text('Counted on this device'), findsNothing);
    expect(find.bySemanticsLabel(RegExp('Plan: PLUS')), findsOneWidget);
    handle.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('per-model list: own remaining counts, sorted, Auto estimate, '
      'unknown as a dash', (tester) async {
    final handle = tester.ensureSemantics();
    await mount(tester);
    expect(find.text('REMAINING BY MODEL'), findsOneWidget);
    expect(find.text('≈ 900 messages left'), findsOneWidget);
    expect(find.text('≈ 120 messages left'), findsOneWidget);
    expect(find.text('≈ 40 messages left'), findsOneWidget);
    expect(find.text('≈ 8 images left'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Remaining usage not known')),
      findsOneWidget,
    );
    expect(
      find.text('Estimate · Auto picks a model for each request'),
      findsOneWidget,
    );
    // No shared percentage per model any more.
    expect(find.textContaining('% remaining'), findsOneWidget);

    double y(String id) =>
        tester.getTopLeft(find.byKey(ValueKey('usage-model-$id'))).dy;
    final order = [
      'ovid-lite',
      'auto',
      'ovid-pro',
      'custom-unpriced',
      'ovid-image:img-std',
    ];
    for (var i = 1; i < order.length; i++) {
      expect(y(order[i]), greaterThan(y(order[i - 1])), reason: order[i]);
    }
    handle.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('no price or currency anywhere on usage screens', (tester) async {
    final handle = tester.ensureSemantics();
    await record(tester, [
      _attempt(
        input: UsageTokenCount.reported(1000),
        output: UsageTokenCount.reported(100),
      ),
      _attempt(
        provider: 'custom',
        requested: 'gpt-4o',
        reported: 'gpt-4o',
        input: UsageTokenCount.reported(5000),
        output: UsageTokenCount.reported(800),
      ),
    ]);
    await mount(tester);
    expect(_allCopy(tester), isNot(matches(_currency)));
    // Provider detail too.
    await tester.tap(find.byKey(const ValueKey('custom')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ProviderUsageScreen), findsOneWidget);
    expect(_allCopy(tester), isNot(matches(_currency)));
    handle.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('user-facing UI source formats no currency', () {
    // Golden-free guard: no "$<amount>" formatting in any screen.
    final money = RegExp(
      r"""\\\$\$\{|\\\$[0-9]|toStringAsFixed\(2\)\}?\s*USD""",
    );
    for (final file in Directory('lib/ui').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        expect(
          money.hasMatch(lines[i]),
          isFalse,
          reason: '${file.path}:${i + 1}: ${lines[i].trim()}',
        );
      }
    }
  });

  testWidgets('old server: device journal counts today incl. Auto, '
      'per-model list hidden', (tester) async {
    respond = () =>
        http.Response(jsonEncode(_payload(perModel: false, today: false)), 200);
    await record(tester, [
      _attempt(
        input: UsageTokenCount.reported(1200),
        output: UsageTokenCount.reported(300),
      ),
      _attempt(
        requested: 'ovid-pro',
        reported: 'ovid-pro',
        input: UsageTokenCount.estimated(100),
        output: UsageTokenCount.estimated(20),
      ),
      _attempt(outcome: UsageOutcome.failed),
    ]);
    await mount(tester);
    expect(find.text('90% remaining'), findsOneWidget);
    expect(inCell('usage-requests-today', '2'), findsOneWidget);
    expect(inCell('usage-input-today', '≈ 1.3K'), findsOneWidget);
    expect(inCell('usage-output-today', '≈ 320'), findsOneWidget);
    expect(find.text('Counted on this device'), findsOneWidget);
    expect(find.text('Includes 1 request in Auto mode'), findsOneWidget);
    expect(
      find.text('≈ Includes estimates where the model sent no token counts'),
      findsOneWidget,
    );
    expect(find.text('REMAINING BY MODEL'), findsNothing);
    expect(find.textContaining('requests today'), findsNothing);
    // Header never says "unavailable" when local data exists.
    final header = find.byKey(const ValueKey('usage-requests-today'));
    expect(header, findsOneWidget);
    expect(find.textContaining('Unavailable'), findsNothing);
    // Auto is attributed to Auto and to the served model on the cloud card.
    // (The provider card counts every observed attempt, the failed one too.)
    await tester.scrollUntilVisible(find.text('2 requests in Auto mode'), 200);
    expect(find.text('2 requests in Auto mode'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('offline: allowance unknown, today still from this device', (
    tester,
  ) async {
    respond = () => http.Response('down', 503);
    await record(tester, [
      _attempt(
        input: UsageTokenCount.reported(40),
        output: UsageTokenCount.reported(10),
      ),
    ]);
    await mount(tester);
    expect(find.text('Usage unavailable'), findsOneWidget);
    expect(inCell('usage-requests-today', '1'), findsOneWidget);
    expect(inCell('usage-input-today', '40'), findsOneWidget);
    expect(find.text('Counted on this device'), findsOneWidget);
    expect(find.text('REMAINING BY MODEL'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (size, scale) in [
    (const Size(320, 640), 2.0),
    (const Size(320, 640), 1.0),
    (const Size(360, 780), 1.3),
  ]) {
    testWidgets('fits ${size.width.toInt()}dp at ${scale}x', (tester) async {
      await record(tester, [
        _attempt(
          input: UsageTokenCount.reported(123456),
          output: UsageTokenCount.reported(7890),
        ),
      ]);
      await mount(tester, size: size, textScale: scale);
      expect(tester.takeException(), isNull);
      for (final id in ['ovid-lite', 'ovid-image:img-std']) {
        final row = find.byKey(ValueKey('usage-model-$id'));
        await tester.scrollUntilVisible(row, 120);
        await tester.pump();
        expect(tester.takeException(), isNull);
        final rect = tester.getRect(row);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(size.width));
      }
      expect(find.text('≈ 8 images left'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
