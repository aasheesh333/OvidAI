import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/image_receipt_store.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/usage_attempt.dart';
import 'package:ovid_ai/core/usage_attempt_recorder.dart';
import 'package:ovid_ai/core/usage_today.dart';

const _fingerprint =
    '9495588e5c1a00c192e7f3d969984477c8f0018a06cea41e73d244a20e70b454';

Map<String, dynamic> _newPayload() => {
  'tier': '3x',
  'is_paid': true,
  'daily_spent_usd': 0.4,
  'daily_budget_usd': 3,
  'requests_today': 0,
  'budget_window': '30d',
  'remaining_pct': 0.9,
  'window': '30d',
  'resets_at': '2026-11-01T00:00:00Z',
  'today': {
    'requests': 12,
    'input_tokens': 34000,
    'output_tokens': 5600,
    'images': 2,
  },
  'remaining_fraction': 0.62,
  'models': [
    {
      'id': 'ovid-pro',
      'name': 'Ovid Pro',
      'kind': 'chat',
      'priced': true,
      'remaining_messages': 40,
      'remaining_images': null,
      'auto': false,
      'estimate': null,
    },
    {
      'id': 'ovid-image:img-std',
      'name': 'Image Studio',
      'kind': 'image',
      'priced': true,
      'remaining_messages': null,
      'remaining_images': 8,
      'auto': false,
      'estimate': null,
    },
    {
      'id': 'ovid-lite',
      'name': 'Ovid Lite',
      'kind': 'chat',
      'priced': true,
      'remaining_messages': 900,
      'auto': false,
    },
    {
      'id': 'custom-unpriced',
      'name': 'Custom',
      'kind': 'chat',
      'priced': false,
      'remaining_messages': null,
      'auto': false,
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
  ],
};

UsageAttempt _attempt(
  String id, {
  required DateTime at,
  String provider = AppState.ovidCloudProviderId,
  String requested = 'auto',
  String? reported = 'ovid-lite',
  UsageOutcome outcome = UsageOutcome.succeeded,
  UsageTokenCount? input,
  UsageTokenCount? output,
}) => UsageAttempt(
  attemptId: 'attempt-$id',
  requestId: 'request-$id',
  revision: 2,
  sourceDevice: 'android',
  provider: provider,
  requestedModel: requested,
  reportedModel: reported,
  purpose: 'agent',
  startedAt: at.toUtc(),
  dispatchStage: UsageDispatchStage.completed,
  outcome: outcome,
  inputTokens: input,
  outputTokens: output,
);

void main() {
  group('OvidUsage contract', () {
    test('parses the new per-model payload', () {
      final usage = OvidUsage.fromJson(_newPayload());
      expect(usage.window, '30d');
      expect(usage.resetsAt, DateTime.utc(2026, 11));
      // remaining_fraction wins over the legacy remaining_pct.
      expect(usage.remainingFraction, 0.62);
      expect(usage.today!.requests, 12);
      expect(usage.today!.inputTokens, 34000);
      expect(usage.today!.outputTokens, 5600);
      expect(usage.today!.images, 2);
      final auto = usage.models.firstWhere((m) => m.model == 'auto');
      expect(auto.auto, isTrue);
      expect(auto.estimate, 'conservative');
      expect(auto.remaining, 120);
      final image = usage.models.firstWhere((m) => m.isImage);
      expect(image.remaining, 8);
      expect(image.label, 'Image Studio');
      final unpriced = usage.models.firstWhere(
        (m) => m.model == 'custom-unpriced',
      );
      expect(unpriced.remaining, isNull);
    });

    test('per-model list: chat before image, most remaining first, '
        'unknown last', () {
      final usage = OvidUsage.fromJson(_newPayload());
      expect(usage.perModel.map((m) => m.model).toList(), [
        'ovid-lite',
        'auto',
        'ovid-pro',
        'custom-unpriced',
        'ovid-image:img-std',
      ]);
    });

    test('legacy payload keeps parsing and hides the per-model list', () {
      final usage = OvidUsage.fromJson({
        'tier': 'free',
        'remaining_pct': 0.4,
        'requests_today': 0,
        'budget_window': '24h',
        'models': [
          {
            'model': 'auto',
            'input_cost_per_token': 0.000001,
            'remaining_pct': 0.4,
          },
        ],
      });
      expect(usage.remainingFraction, 0.4);
      expect(usage.today, isNull);
      expect(usage.window, isNull);
      expect(usage.models, hasLength(1));
      expect(usage.models.single.hasPerModelRemaining, isFalse);
      expect(usage.perModel, isEmpty);
    });

    test('malformed today counters read as zero, non-object as absent', () {
      expect(OvidUsageToday.tryParse('x'), isNull);
      final t = OvidUsageToday.tryParse({
        'requests': -3,
        'input_tokens': 'many',
        'output_tokens': 7,
      })!;
      expect(
        (t.requests, t.inputTokens, t.outputTokens, t.images),
        (0, 0, 7, 0),
      );
    });
  });

  group('today counters', () {
    final now = DateTime(2026, 10, 13, 15);

    test('device journal counts Ovid Cloud requests today, incl. Auto', () {
      final today = UsageToday.fromDevice(
        provider: AppState.ovidCloudProviderId,
        now: now,
        attempts: [
          _attempt(
            'a',
            at: DateTime(2026, 10, 13, 9),
            input: UsageTokenCount.reported(1000),
            output: UsageTokenCount.reported(200),
          ),
          _attempt(
            'b',
            at: DateTime(2026, 10, 13, 10),
            requested: 'ovid-pro',
            reported: null,
            input: UsageTokenCount.estimated(50),
            output: UsageTokenCount.estimated(10),
          ),
          // Not counted: yesterday, failed, other provider, pending.
          _attempt('c', at: DateTime(2026, 10, 12, 23, 59)),
          _attempt(
            'd',
            at: DateTime(2026, 10, 13, 11),
            outcome: UsageOutcome.failed,
          ),
          _attempt('e', at: DateTime(2026, 10, 13, 11), provider: 'byok'),
          _attempt(
            'f',
            at: DateTime(2026, 10, 13, 12),
            outcome: UsageOutcome.pending,
          ),
        ],
        receipts: [
          ImageRequestRecord(
            accountId: 'alice',
            requestId: 'image-request-1',
            fingerprint: _fingerprint,
            state: 'confirmed',
            createdAt: DateTime(2026, 10, 13, 8).toUtc(),
          ),
          ImageRequestRecord(
            accountId: 'alice',
            requestId: 'image-request-2',
            fingerprint: _fingerprint,
            state: 'failed',
            createdAt: DateTime(2026, 10, 13, 8).toUtc(),
          ),
        ],
      );
      expect(today.source, UsageTodaySource.device);
      expect(today.requests, 2);
      expect(today.autoRequests, 1);
      expect(today.inputTokens, 1050);
      expect(today.outputTokens, 210);
      expect(today.tokensEstimated, isTrue);
      expect(today.images, 1);
    });

    test('server today wins; legacy always-zero requests_today never hides '
        'device activity', () {
      final device = UsageToday.fromDevice(
        provider: AppState.ovidCloudProviderId,
        now: now,
        attempts: [
          _attempt(
            'a',
            at: DateTime(2026, 10, 13, 9),
            input: UsageTokenCount.reported(10),
            output: UsageTokenCount.reported(5),
          ),
        ],
        receipts: const [],
      );
      final fromServer = UsageToday.resolve(
        OvidUsage.fromJson(_newPayload()),
        device,
      );
      expect(fromServer.source, UsageTodaySource.server);
      expect(fromServer.requests, 12);
      expect(fromServer.images, 2);

      final legacy = UsageToday.resolve(
        OvidUsage.fromJson({'requests_today': 0, 'remaining_pct': 0.5}),
        device,
      );
      expect(legacy.source, UsageTodaySource.device);
      expect(legacy.requests, 1);
      expect(legacy.inputTokens, 10);

      final offline = UsageToday.resolve(null, device);
      expect(offline.requests, 1);
    });
  });

  group('recorder estimates', () {
    test(
      'unreported usage is journaled as a labelled local estimate',
      () async {
        final writes = <UsageAttempt>[];
        final recorder = UsageAttemptRecorder(
          owner: Object(),
          write: (attempt, {owner}) async {
            writes.add(attempt);
            return true;
          },
        );
        final handle = (await recorder.begin(
          requestId: 'request-estimate',
          provider: AppState.ovidCloudProviderId,
          requestedModel: 'auto',
          purpose: 'agent',
          sessionId: null,
          runId: null,
        ))!;
        await handle.complete(
          outcome: UsageOutcome.succeeded,
          reportedModel: 'ovid-lite',
          estimatedInput: 40,
          estimatedOutput: 8,
        );
        final last = writes.last;
        expect(last.inputTokens, UsageTokenCount.estimated(40));
        expect(last.outputTokens, UsageTokenCount.estimated(8));
        expect(last.totalTokens, UsageTokenCount.estimated(48));
        expect(last.reportedModel, 'ovid-lite');
      },
    );

    test('reported usage always beats the estimate', () async {
      final writes = <UsageAttempt>[];
      final recorder = UsageAttemptRecorder(
        owner: Object(),
        write: (attempt, {owner}) async {
          writes.add(attempt);
          return true;
        },
      );
      final handle = (await recorder.begin(
        requestId: 'request-reported',
        provider: AppState.ovidCloudProviderId,
        requestedModel: 'auto',
        purpose: 'agent',
        sessionId: null,
        runId: null,
      ))!;
      await handle.complete(
        outcome: UsageOutcome.succeeded,
        usage: {
          'prompt_tokens': 100,
          'completion_tokens': 20,
          'total_tokens': 120,
        },
        estimatedInput: 40,
        estimatedOutput: 8,
      );
      expect(writes.last.inputTokens, UsageTokenCount.reported(100));
      expect(writes.last.outputTokens, UsageTokenCount.reported(20));
      expect(writes.last.totalTokens, UsageTokenCount.reported(120));
    });
  });

  group('agent transport', () {
    late Directory usageRoot;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      usageRoot = await Directory.systemTemp.createTemp('ovid-usage-auto-');
      AppState.usageRootOverrideForTest = usageRoot;
      AgentNotificationService.I.resetForTest();
      AppState.resetTestInstance();
      AppState.createForTest().seenWelcomeVersion = AppState.welcomeVersion;
      AgentService.I.debugPauseScheduleTimerForTest(true);
    });

    tearDown(() async {
      AgentService.I.debugPauseScheduleTimerForTest(false);
      AgentService.I.resetUsageAttemptRecorderForTest();
      AgentNotificationService.I.resetForTest();
      AppState.usageRootOverrideForTest = null;
      AppState.resetTestInstance();
      await usageRoot.delete(recursive: true);
    });

    test('an Auto request with no usage block counts today with estimated '
        'tokens and the served model', () async {
      final app = AppState.I;
      await app.prepareUsageAttempts();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      unawaited(() async {
        await for (final request in server) {
          await utf8.decoder.bind(request).join();
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          // A gateway that dropped stream_options: content, no usage chunk.
          request.response.write(
            'data: ${jsonEncode({
              'model': 'ovid-lite',
              'choices': [
                {
                  'delta': {'content': 'hello there, how can I help?'},
                  'finish_reason': 'stop',
                },
              ],
            })}\n\n',
          );
          request.response.write('data: [DONE]\n\n');
          await request.response.close();
        }
      }());
      final provider = ProviderConfig(
        id: AppState.ovidCloudProviderId,
        name: 'Ovid Cloud',
        description: '',
        baseUrl: 'http://${server.address.host}:${server.port}',
        models: ['auto'],
        selectedModel: 'auto',
        requiresApiKey: false,
      );
      final session = ChatSession(
        id: 'auto-session',
        title: 'Auto',
        model: 'auto',
        providerId: provider.id,
        messages: [Message(role: 'user', content: 'hi')],
      );
      final settled = Completer<void>();
      void onChange() {
        final done = app.usageAttempts.where(
          (a) =>
              a.provider == provider.id && a.outcome == UsageOutcome.succeeded,
        );
        if (done.isNotEmpty && !settled.isCompleted) settled.complete();
      }

      app.addListener(onChange);
      addTearDown(() => app.removeListener(onChange));
      final result = await AgentService.I.callLlmForTest(provider, [
        {'role': 'user', 'content': 'hi'},
      ], session);
      expect(result?['content'], 'hello there, how can I help?');
      await settled.future.timeout(const Duration(seconds: 10));

      final attempt = app.usageAttempts.singleWhere(
        (a) => a.provider == provider.id,
      );
      expect(attempt.requestedModel, 'auto');
      expect(attempt.reportedModel, 'ovid-lite');
      expect(attempt.inputTokens?.provenance, UsageProvenance.locallyEstimated);
      expect(attempt.inputTokens?.value, greaterThan(0));
      expect(attempt.outputTokens?.value, greaterThan(0));

      final today = UsageToday.fromDevice(
        attempts: app.usageAttempts,
        receipts: const [],
        provider: AppState.ovidCloudProviderId,
      );
      expect(today.requests, 1);
      expect(today.autoRequests, 1);
      expect(today.inputTokens, greaterThan(0));
      expect(today.tokensEstimated, isTrue);
    });
  });
}
