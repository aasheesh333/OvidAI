import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/private_sync/dto.dart';
import 'package:ovid_ai/core/private_sync/production.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _created = '2026-10-10T00:00:00Z';

class _Harness {
  _Harness(this.root);
  final Directory root;
  final sent = <Map<String, dynamic>>[];
  final remote = <Map<String, dynamic>>[];
  String? failure;
  bool reset = false;
  int stateReads = 0;

  PrivateSyncProduction owner(
    Iterable<SyncUploadRecord> Function(String) snapshot,
  ) => PrivateSyncProduction(
    endpoint: 'https://sync.example',
    rootDirectory: () async => root,
    accountReady: () => true,
    currentUid: () => 'alice',
    idToken: (_) async => 'token',
    appCheckToken: () async => 'check',
    snapshot: snapshot,
    httpClientFactory: () => MockClient((request) async {
      Object body;
      var status = 200;
      if (request.url.path.endsWith('/devices')) {
        body = {
          'schemaVersion': 1,
          'deviceId': 'device',
          'deviceName': 'Ovid',
          'createdAt': _created,
          'status': 'active',
        };
      } else if (request.method == 'POST') {
        final batch =
            jsonDecode(utf8.decode(gzip.decode(request.bodyBytes)))
                as Map<String, dynamic>;
        sent.add(batch);
        final record =
            (batch['records'] as List).single as Map<String, dynamic>;
        if (failure == null) {
          remote.add({
            ...record,
            'accountId': 'alice',
            'changeSequence': remote.length + 1,
          });
        }
        body = {
          'schemaVersion': 1,
          'results': [
            {
              'recordId': record['recordId'],
              'status': failure == null
                  ? 'accepted'
                  : failure == 'integrity_conflict'
                  ? 'conflict'
                  : 'retryable',
              'revision': failure == null ? record['revision'] : null,
              'changeSequence': failure == null ? remote.length : null,
              'error': failure == null
                  ? null
                  : {
                      'schemaVersion': 1,
                      'code': failure,
                      'message': failure == 'integrity_conflict'
                          ? 'The record conflicts with the stored canonical record.'
                          : 'The sync quota is exhausted.',
                      'retryAfterSeconds': null,
                    },
            },
          ],
        };
      } else if (request.url.path.endsWith('/state')) {
        stateReads++;
        body = {
          'schemaVersion': 1,
          'accountId': 'alice',
          'currentCursor': '${remote.length}',
          'records': remote,
          'enrollmentStatus': 'active',
          'retentionMarkers': <String>[],
        };
      } else if (reset) {
        reset = false;
        status = 409;
        body = {
          'schemaVersion': 1,
          'code': 'reset_required',
          'message': 'The sync state must be reset.',
          'retryAfterSeconds': null,
        };
      } else {
        final cursor =
            int.tryParse(request.url.queryParameters['cursor'] ?? '') ?? 0;
        body = {
          'schemaVersion': 1,
          'nextCursor': '${remote.length}',
          'hasMore': false,
          'records': remote.skip(cursor).toList(),
        };
      }
      return http.Response(
        jsonEncode(body),
        status,
        headers: {'cache-control': 'no-store'},
      );
    }),
  );

  Future<List<dynamic>> entries() async =>
      (jsonDecode(
                await File(
                  '${root.path}/private-sync/'
                  '${accountDirectoryName('alice')}/outbox.json',
                ).readAsString(),
              )
              as Map)['entries']
          as List;
}

SyncUploadRecord _transcript(
  String device, {
  String text = 'original',
  int revision = 1,
}) => SyncUploadRecord(
  recordId: 'message',
  sourceDeviceId: device,
  conversationId: 'chat',
  createdAt: _created,
  revision: revision,
  payload: TranscriptPayload(
    messageId: 'message',
    parentMessageId: null,
    kind: TranscriptKind.user,
    text: text,
    providerMetadataRecordId: null,
    requestPurpose: null,
    displayTitle: 'Chat',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Harness harness;
  late AppState app;
  final owners = <PrivateSyncProduction>[];
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('export-lifecycle-');
    harness = _Harness(root);
    app = AppState.createForTest(workspaceDeleter: (_) async {});
  });
  tearDown(() async {
    for (final owner in owners) {
      await owner.release();
    }
    owners.clear();
    await app.flushSessionPersistenceForTest();
    AppState.resetTestInstance();
    await root.delete(recursive: true);
  });
  Future<PrivateSyncProduction> start(
    Iterable<SyncUploadRecord> Function(String) snapshot,
  ) async {
    final owner = harness.owner(snapshot);
    owners.add(owner);
    await owner.bind('alice', 1);
    await owner.enroll();
    await owner.setForeground(true);
    return owner;
  }

  test(
    'immutable transcript edits preserve original and surface conflict across restart',
    () async {
      var text = 'original';
      var owner = await start((device) => [_transcript(device, text: text)]);
      text = 'edited draft';
      await owner.refresh();
      expect(harness.sent, hasLength(1));
      expect(owner.error, contains('conflict'));
      expect(
        (owner.records.single.payload as TranscriptPayload).text,
        'original',
      );
      await owner.release();
      owner = await start((device) => [_transcript(device, text: text)]);
      expect(harness.sent, hasLength(1));
      expect(owner.error, contains('conflict'));
      expect(text, 'edited draft');
    },
  );

  test(
    'quota retries retain identical envelope and error with bounded pending capture',
    () async {
      harness.failure = 'quota_exhausted';
      var revision = 7;
      final owner = await start(
        (device) => [
          for (var i = 0; i < 300; i++)
            SyncUploadRecord(
              recordId: 'activity-$i',
              sourceDeviceId: device,
              conversationId: 'chat',
              createdAt: _created,
              revision: revision,
              payload: ActivityPayload(
                logicalRequestId: null,
                attemptId: null,
                kind: ActivityKind.system,
                status: ActivityStatus.started,
                updatedAt: _created,
                title: 'Draft $revision',
                detail: '',
                usageRecordId: null,
              ),
            ),
        ],
      );
      final initial = await harness.entries();
      expect(initial.length, lessThan(300));
      expect(owner.error, isNotNull);
      for (var i = 0; i < 3; i++) {
        revision++;
        await owner.refresh();
      }
      expect(await harness.entries(), hasLength(initial.length));
      // Delayed records no longer block independent later entries. Every
      // submitted envelope still uses its original captured revision/key.
      final original = {
        for (final entry in initial) entry['idempotencyKey']: entry['envelope'],
      };
      for (final batch in harness.sent) {
        expect(
          (batch['records'] as List).single,
          original[batch['idempotencyKey']],
        );
      }
      expect(
        harness.sent.map((b) => b['idempotencyKey']).toSet(),
        hasLength(harness.sent.length),
      );
      expect((harness.sent.first['records'] as List).first['revision'], 7);
      expect(owner.error, isNotNull);
    },
  );

  test(
    'server conflict is terminal and original local envelope survives retry',
    () async {
      harness.failure = 'integrity_conflict';
      final owner = await start((device) => [_transcript(device)]);
      await owner.refresh();
      expect(harness.sent, hasLength(1));
      expect(owner.error, contains('conflict'));
      final entry = (await harness.entries()).single as Map;
      expect(entry['state'], 'terminal');
      expect(entry['envelope']['payload']['text'], 'original');
    },
  );

  Iterable<SyncUploadRecord> Function(String) appSnapshot() {
    app.registerProductionAccountFeatures();
    return app.privateSync!.snapshot!;
  }

  ProviderConfig provider({String endpoint = 'https://EXAMPLE.com:443/v1'}) =>
      ProviderConfig(
        id: 'custom-safe',
        name: 'Safe provider',
        description: 'PRIVATE DESCRIPTION',
        baseUrl: endpoint,
        apiKey: 'PRIVATE API KEY',
        custom: true,
        connected: true,
        models: ['model'],
        selectedModel: 'model',
      );

  test(
    'production provider export is explicit and rejects credential endpoints',
    () async {
      final p = provider();
      p.setModelVisionSupport('model', true);
      app.providers
        ..clear()
        ..add(p);
      final snapshot = appSnapshot();
      final owner = await start(snapshot);
      final payload = (owner.records.single.payload as ProviderMetadataPayload)
          .toWire();
      expect(payload, {
        'providerId': 'custom-safe',
        'modelId': 'model',
        'endpoint': 'https://example.com/v1',
        'requestPurpose': null,
        'displayName': 'Safe provider',
        'supportsStreaming': true,
      });
      expect(jsonEncode(harness.sent), isNot(contains('PRIVATE')));
      expect(jsonEncode(harness.sent), isNot(contains('visionOverrides')));
      p.baseUrl = 'https://example.com/v1?api_key=PRIVATE';
      await owner.refresh();
      expect(harness.sent, hasLength(1));
      p.baseUrl = 'https://user:PRIVATE@example.com/v1';
      await owner.refresh();
      expect(harness.sent, hasLength(1));
    },
  );

  test('enrollment gates every export and explicit deletion', () async {
    app.providers
      ..clear()
      ..add(provider());
    final snapshot = appSnapshot();
    var captures = 0;
    final owner = harness.owner((device) {
      captures++;
      return snapshot(device);
    });
    owners.add(owner);
    app.privateSync = owner;
    await owner.bind('alice', 1);
    await owner.setForeground(true);
    await owner.refresh();
    await owner.recordLocalDeletion(providerId: 'custom-safe');
    expect(captures, 0);
    expect(await harness.entries(), isEmpty);
    expect(harness.sent, isEmpty);
    await owner.enroll();
    expect(harness.sent, hasLength(1));
  });

  test(
    'history prefix changes and restart preserve message record identity',
    () async {
      app.providers.clear();
      final session = app.activeSession!;
      session.messages.add(Message(role: 'user', content: 'tail'));
      final snapshot = appSnapshot();
      final before = snapshot('device').single;
      session.messages.insert(0, Message(role: 'user', content: 'prefix'));
      expect(snapshot('device').last.recordId, before.recordId);
      final restored = ChatSession.fromJson(session.toJson());
      app.sessions
        ..clear()
        ..add(restored);
      expect(snapshot('device').last.recordId, before.recordId);
      restored.messages.removeAt(0); // history eviction, not user deletion
      final owner = await start(snapshot);
      restored.messages.clear();
      await owner.refresh();
      expect(harness.sent, hasLength(1));
      expect(owner.records.single.recordId, before.recordId);
    },
  );

  test(
    'real message deletion persists tombstones in background and replay removes original',
    () async {
      app.providers.clear();
      final session = app.activeSession!;
      session.messages.add(Message(role: 'user', content: 'delete me'));
      final snapshot = appSnapshot();
      var owner = await start(snapshot);
      app.privateSync = owner;
      final target = owner.records.single.recordId;
      await owner.setForeground(false);
      await Future<void>.sync(() => app.deleteMessagesFrom(session.id, 0));
      expect(session.messages, isEmpty);
      expect(
        (await harness.entries()).where(
          (e) => e['envelope']['recordType'] == 'tombstone',
        ),
        hasLength(1),
      );
      await owner.release();
      owner = await start(snapshot);
      app.privateSync = owner;
      expect(owner.records, isEmpty);
      final tombstone = (harness.sent.last['records'] as List).single;
      expect(tombstone['payload']['targetRecordId'], target);
      expect(tombstone['payload']['reason'], 'user');
      await owner.refresh();
      expect(harness.sent, hasLength(2));
    },
  );

  test(
    'session deletion covers exported history omitted from current snapshot',
    () async {
      app.providers.clear();
      final session = app.activeSession!;
      session.messages.addAll([
        Message(role: 'user', content: 'prefix'),
        Message(role: 'assistant', content: 'tail'),
      ]);
      final snapshot = appSnapshot();
      final owner = await start(snapshot);
      app.privateSync = owner;
      await owner.refresh();
      expect(owner.records, hasLength(2));
      session.messages.removeAt(0);
      await owner.refresh();
      expect(harness.sent, hasLength(2));
      await Future<void>.sync(() => app.deleteSession(session.id));
      await owner.refresh();
      await owner.refresh();
      expect(owner.records, isEmpty);
      expect(harness.sent, hasLength(4));
    },
  );

  test(
    'provider deletion tombstones every exported version but key clearing does not',
    () async {
      final p = provider();
      app.providers
        ..clear()
        ..add(p);
      final snapshot = appSnapshot();
      final owner = await start(snapshot);
      app.privateSync = owner;
      p.name = 'Renamed';
      await owner.refresh();
      expect(owner.records, hasLength(2));
      p.apiKey = '';
      await owner.refresh();
      expect(harness.sent, hasLength(2));
      await app.removeCustomProvider(p.id);
      await owner.refresh();
      await owner.refresh();
      expect(owner.records, isEmpty);
      expect(harness.sent, hasLength(4));
    },
  );

  test(
    'reset performs state readback and disk clear verifies actual account directory',
    () async {
      final owner = await start((device) => [_transcript(device)]);
      harness.reset = true;
      await owner.refresh();
      expect(harness.stateReads, 1);
      expect(
        (owner.records.single.payload as TranscriptPayload).text,
        'original',
      );
      await owner.clear();
      expect(await owner.verifyEmpty(), true);
      final directory = Directory(
        '${root.path}/private-sync/${accountDirectoryName('alice')}',
      );
      await directory.create(recursive: true);
      await File('${directory.path}/leftover').writeAsString('data');
      expect(await owner.verifyEmpty(), false);
    },
  );

  test(
    'deleting a quota-blocked transcript delivers tombstone ahead of content',
    () async {
      app.providers.clear();
      final session = app.activeSession!;
      session.messages.add(Message(role: 'user', content: 'pending delete'));
      final snapshot = appSnapshot();
      harness.failure = 'quota_exhausted';
      final owner = await start(snapshot);
      app.privateSync = owner;
      await app.deleteMessagesFrom(session.id, 0);
      harness.failure = null;
      await owner.refresh();
      expect(
        (harness.sent.last['records'] as List).single['recordType'],
        'tombstone',
      );
      await owner.refresh();
      expect(harness.sent, hasLength(2));
      expect(owner.records, isEmpty);
    },
  );

  test(
    'failed deletion write preserves local content and an actionable error',
    () async {
      app.providers.clear();
      final session = app.activeSession!;
      session.messages.add(Message(role: 'user', content: 'keep me'));
      final owner = await start(appSnapshot());
      app.privateSync = owner;
      final file = File(
        '${root.path}/private-sync/${accountDirectoryName('alice')}/outbox.json',
      );
      final bytes = await file.readAsBytes();
      await file.delete();
      await Directory(file.path).create();
      await expectLater(
        app.deleteMessagesFrom(session.id, 0),
        throwsA(anything),
      );
      expect(session.messages.single.content, 'keep me');
      expect(owner.error, contains('retry'));
      await Directory(file.path).delete();
      await file.writeAsBytes(bytes);
    },
  );

  test('root deletion tombstones exported deferred descendants', () async {
    app.providers.clear();
    final parent = ChatSession(id: 'parent', title: 'Parent', model: 'model');
    final child = ChatSession(
      id: 'child',
      title: 'Child',
      model: 'model',
      parentId: 'parent',
      messages: [Message(role: 'user', content: 'child text')],
    );
    app.sessions
      ..clear()
      ..addAll([parent, child]);
    final snapshot = appSnapshot();
    final owner = await start(snapshot);
    app.privateSync = owner;
    SharedPreferences.setMockInitialValues({
      'ovid_active_session': parent.id,
      'ovid_sessions': [
        jsonEncode(parent.toJson()),
        jsonEncode(child.toJson()),
      ],
    });
    await app.initializeForFirstFrame();
    expect(app.sessionById('child'), isNull);
    await app.deleteSession('parent');
    await owner.refresh();
    expect(owner.records, isEmpty);
  });

  test(
    'conflicting replay revision preserves original restored content',
    () async {
      final owner = await start((device) => [_transcript(device)]);
      harness.remote.add({
        ...harness.remote.single,
        'revision': 2,
        'changeSequence': 2,
        'payload': {
          ...harness.remote.single['payload'] as Map,
          'text': 'overwrite',
        },
      });
      await owner.refresh();
      expect(
        (owner.records.single.payload as TranscriptPayload).text,
        'original',
      );
      expect(owner.error, contains('conflict'));
    },
  );

  test('fresh owner reset readback discovers residual account data', () async {
    var owner = await start((device) => [_transcript(device)]);
    await owner.release();
    owner = harness.owner((_) => []);
    owners.add(owner);
    await owner.bind('alice', 2);
    expect(await owner.verifyEmpty(), false);
    await owner.clear();
    expect(await owner.verifyEmpty(), true);
  });
}
