import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/private_sync/production.dart';
import 'package:ovid_ai/core/private_sync/dto.dart';
import 'package:ovid_ai/core/usage_attempt.dart' as local;

void main() {
  late Directory root;
  setUp(
    () async =>
        root = await Directory.systemTemp.createTemp('sync-production-'),
  );
  tearDown(() async => root.delete(recursive: true));

  test(
    'usage projection preserves unknown counts and emits inert activity',
    () {
      final rows = privateUsageSnapshot('device', [
        local.UsageAttempt(
          attemptId: 'attempt',
          requestId: 'request',
          revision: 1,
          sourceDevice: 'device',
          provider: 'provider',
          requestedModel: 'model',
          purpose: 'chat',
          startedAt: DateTime.utc(2026, 10, 10),
          dispatchStage: local.UsageDispatchStage.completed,
          outcome: local.UsageOutcome.failed,
        ),
      ]).toList();
      expect(rows, hasLength(2));
      final usage = rows.first.payload as UsagePayload;
      expect(usage.inputTokens, isNull);
      expect(usage.usageProvenance, UsageProvenance.unknown);
      expect(usage.outcome, UsageOutcome.failed);
      final activity = rows.last.payload as ActivityPayload;
      expect(activity.usageRecordId, 'attempt');
      expect(activity.status, ActivityStatus.failed);
    },
  );

  test('unconfigured builds never open storage or enroll', () async {
    var opened = false;
    final owner = PrivateSyncProduction(
      endpoint: '',
      rootDirectory: () async {
        opened = true;
        return root;
      },
      accountReady: () => true,
      currentUid: () => 'alice',
      idToken: (_) async => 'id-token',
      appCheckToken: () async => 'app-check',
    );
    await owner.bind('alice', 1);
    expect(owner.available, false);
    expect(opened, false);
    await expectLater(owner.enroll(), throwsStateError);
    await owner.release();
  });

  test('enrollment retry and restart retain account device identity', () async {
    final keys = <String>[];
    var fail = true;
    PrivateSyncProduction make() => PrivateSyncProduction(
      endpoint: 'https://sync.example',
      rootDirectory: () async => root,
      accountReady: () => true,
      currentUid: () => 'alice',
      idToken: (_) async => 'id-token',
      appCheckToken: () async => 'app-check',
      httpClientFactory: () => MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer id-token');
        expect(request.headers['X-Firebase-AppCheck'], 'app-check');
        keys.add((jsonDecode(request.body) as Map)['idempotencyKey'] as String);
        if (fail) {
          fail = false;
          throw const SocketException('offline');
        }
        return http.Response(
          jsonEncode({
            'schemaVersion': 1,
            'deviceId': 'server-device',
            'deviceName': 'Ovid',
            'createdAt': '2026-10-10T00:00:00Z',
            'status': 'active',
          }),
          200,
          headers: {'cache-control': 'no-store'},
        );
      }),
    );
    var owner = make();
    await owner.bind('alice', 1);
    await expectLater(owner.enroll(), throwsA(anything));
    await owner.enroll();
    expect(keys.toSet(), hasLength(1));
    expect(owner.deviceId, 'server-device');
    expect(owner.enrolled, true);
    await owner.release();
    owner = make();
    await owner.bind('alice', 2);
    expect(owner.deviceId, 'server-device');
    expect(owner.enrolled, true);
    expect(keys, hasLength(2));
    owner.fence();
    expect(owner.enrolled, false);
    await owner.clear();
    expect(await owner.verifyEmpty(), true);
    await owner.release();
  });

  test(
    'foreground uploads persisted transcript once and background stops polling',
    () async {
      final uploaded = <Map<String, dynamic>>[];
      final replayed = Completer<void>();
      final owner = PrivateSyncProduction(
        endpoint: 'https://sync.example',
        rootDirectory: () async => root,
        accountReady: () => true,
        currentUid: () => 'alice',
        idToken: (_) async => 'id-token',
        appCheckToken: () async => 'app-check',
        snapshot: (device) => [
          SyncUploadRecord(
            recordId: 'message-one',
            sourceDeviceId: device,
            conversationId: 'chat-one',
            createdAt: '2026-10-10T00:00:00Z',
            revision: 1,
            payload: TranscriptPayload(
              messageId: 'message-one',
              parentMessageId: null,
              kind: TranscriptKind.user,
              text: 'password=verbatim secret',
              providerMetadataRecordId: null,
              requestPurpose: null,
              displayTitle: 'Test',
            ),
          ),
        ],
        httpClientFactory: () => MockClient((request) async {
          Map<String, Object?> body;
          if (request.url.path.endsWith('/devices')) {
            body = {
              'schemaVersion': 1,
              'deviceId': 'server-device',
              'deviceName': 'Ovid',
              'createdAt': '2026-10-10T00:00:00Z',
              'status': 'active',
            };
          } else if (request.method == 'POST') {
            final sent =
                jsonDecode(utf8.decode(gzip.decode(request.bodyBytes)))
                    as Map<String, dynamic>;
            uploaded.add(sent);
            body = {
              'schemaVersion': 1,
              'results': [
                {
                  'recordId': 'message-one',
                  'status': 'accepted',
                  'revision': 1,
                  'changeSequence': 1,
                  'error': null,
                },
              ],
            };
          } else {
            body = {
              'schemaVersion': 1,
              'nextCursor': 'cursor-one',
              'hasMore': false,
              'records': request.url.queryParameters['cursor'] == 'cursor-one'
                  ? []
                  : [
                      ...((uploaded.single['records'] as List).map(
                        (r) => {
                          ...r as Map,
                          'accountId': 'alice',
                          'changeSequence': 1,
                        },
                      )),
                    ],
            };
            if (!replayed.isCompleted) replayed.complete();
          }
          return http.Response(
            jsonEncode(body),
            200,
            headers: {'cache-control': 'no-store'},
          );
        }),
      );
      await owner.bind('alice', 1);
      await owner.enroll();
      expect(uploaded, isEmpty);
      await owner.setForeground(true);
      await replayed.future;
      expect(uploaded, hasLength(1));
      final record = (uploaded.single['records'] as List).single as Map;
      expect((record['payload'] as Map)['text'], 'password=verbatim secret');
      expect(owner.records.single.payload, isA<TranscriptPayload>());
      await owner.refresh();
      expect(uploaded, hasLength(1));
      await owner.setForeground(false);
      await owner.refresh();
      expect(uploaded, hasLength(1));
      await owner.release();
    },
  );

  test(
    'account fence rejects enrollment completion already in flight',
    () async {
      final response = Completer<http.Response>();
      final sent = Completer<void>();
      final owner = PrivateSyncProduction(
        endpoint: 'https://sync.example',
        rootDirectory: () async => root,
        accountReady: () => true,
        currentUid: () => 'alice',
        idToken: (_) async => 'id-token',
        appCheckToken: () async => 'app-check',
        httpClientFactory: () => MockClient((_) {
          sent.complete();
          return response.future;
        }),
      );
      await owner.bind('alice', 1);
      final enrolling = owner.enroll();
      final rejected = expectLater(enrolling, throwsA(anything));
      await sent.future;
      owner.fence();
      expect(owner.available, false);
      expect(owner.records, isEmpty);
      response.complete(
        http.Response(
          jsonEncode({
            'schemaVersion': 1,
            'deviceId': 'late-device',
            'deviceName': 'Ovid',
            'createdAt': '2026-10-10T00:00:00Z',
            'status': 'active',
          }),
          200,
          headers: {'cache-control': 'no-store'},
        ),
      );
      await rejected;
      expect(owner.enrolled, false);
      await owner.clear();
      expect(await owner.verifyEmpty(), true);
    },
  );
}
