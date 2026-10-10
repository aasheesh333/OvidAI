import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/private_sync/production.dart';
import 'package:ovid_ai/core/private_sync/dto.dart';
import 'package:ovid_ai/core/collaboration/production.dart';
import 'package:ovid_ai/core/private_sync/coordinator.dart';
import 'package:ovid_ai/core/reset_coordinator.dart';

class ManualClock implements SyncClock {
  DateTime time = DateTime.utc(2026, 10, 10);
  @override
  DateTime get now => time;
  @override
  SyncTimer schedule(Duration delay, void Function() callback) => _IdleTimer();
}

class _IdleTimer implements SyncTimer {
  @override
  void cancel() {}
}

const created = '2026-10-10T00:00:00Z';
SyncUploadRecord transcript(String device, String id, {int revision = 1}) =>
    SyncUploadRecord(
      recordId: id,
      sourceDeviceId: device,
      conversationId: 'chat',
      createdAt: created,
      revision: revision,
      payload: TranscriptPayload(
        messageId: id,
        parentMessageId: null,
        kind: TranscriptKind.user,
        text: 'secret-like text $id',
        providerMetadataRecordId: null,
        requestPurpose: null,
        displayTitle: 'Chat',
      ),
    );

// Only the external HTTP boundary is replaced. Production client, coordinator,
// DTO validation, file store, outbox, and enrollment are all exercised together.
class Harness {
  Harness(this.root);
  final Directory root;
  final sent = <Map<String, dynamic>>[];
  final remote = <Map<String, dynamic>>[];
  final cursors = <String>[];
  String uid = 'alice';
  String device = 'device-one';
  String? outcome;
  bool revoked = false;
  bool failRevoke = false;
  int deletes = 0;
  final revokeRequests = <({String device, String key})>[];
  int emptyCursor = 0;
  int retrySeconds = 60;
  bool realTimers = false;
  int revision = 1;
  Future<void> Function()? onEnroll;
  void Function()? onUpload;
  List<String> ids = ['first'];
  final clock = ManualClock();
  PrivateSyncProduction owner() => PrivateSyncProduction(
    endpoint: 'https://sync.example',
    rootDirectory: () async => root,
    accountReady: () => true,
    currentUid: () => uid,
    idToken: (_) async => 'id-token',
    appCheckToken: () async => 'app-check',
    snapshot: (device) =>
        ids.map((id) => transcript(device, id, revision: revision)),
    clock: realTimers ? ProductionSyncClock() : clock,
    httpClientFactory: client,
  );
  http.Client client() => MockClient((request) async {
    Object body;
    var status = 200;
    if (request.method == 'DELETE') {
      deletes++;
      revokeRequests.add((
        device: request.url.pathSegments.last,
        key: request.headers['X-Sync-Idempotency-Key']!,
      ));
      if (failRevoke) throw const SocketException('offline');
      body = {};
    } else if (request.url.path.endsWith('/devices')) {
      await onEnroll?.call();
      body = {
        'schemaVersion': 1,
        'deviceId': device,
        'deviceName': 'Ovid',
        'createdAt': created,
        'status': 'active',
      };
    } else if (revoked) {
      status = 403;
      body = {
        'schemaVersion': 1,
        'code': 'device_revoked',
        'message': 'This device is no longer authorized for private sync.',
        'retryAfterSeconds': null,
      };
    } else if (request.method == 'POST') {
      final batch =
          jsonDecode(utf8.decode(gzip.decode(request.bodyBytes)))
              as Map<String, dynamic>;
      sent.add(batch);
      onUpload?.call();
      final record = (batch['records'] as List).single as Map<String, dynamic>;
      final result = record['recordId'] == 'first' ? outcome : null;
      if (result == null) {
        remote.add({
          ...record,
          'accountId': uid,
          'changeSequence': remote.length + 1,
        });
      }
      body = {
        'schemaVersion': 1,
        'results': [
          {
            'recordId': record['recordId'],
            'status': result ?? 'accepted',
            'revision': result == null ? record['revision'] : null,
            'changeSequence': result == null ? remote.length : null,
            'error': result == null
                ? null
                : {
                    'schemaVersion': 1,
                    'code': result == 'retryable'
                        ? 'quota_exhausted'
                        : 'integrity_conflict',
                    'message': result == 'retryable'
                        ? 'The sync quota is exhausted.'
                        : 'The record conflicts with the stored canonical record.',
                    'retryAfterSeconds': result == 'retryable'
                        ? retrySeconds
                        : null,
                  },
          },
        ],
      };
    } else {
      final cursor = request.url.queryParameters['cursor'] ?? '';
      cursors.add(cursor);
      final from = int.tryParse(cursor.split(':').first) ?? 0;
      body = {
        'schemaVersion': 1,
        'nextCursor': '${remote.length}:$emptyCursor',
        'hasMore': false,
        'records': remote.skip(from).toList(),
      };
    }
    return http.Response(
      jsonEncode(body),
      status,
      headers: {'cache-control': 'no-store'},
    );
  });
  Future<List<dynamic>> entries() async =>
      (jsonDecode(
                await File(
                  '${root.path}/private-sync/${accountDirectoryName(uid)}/outbox.json',
                ).readAsString(),
              )
              as Map)['entries']
          as List;
}

void main() {
  late Directory root;
  late Harness h;
  final owners = <PrivateSyncProduction>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('sync-review-');
    h = Harness(root);
  });
  tearDown(() async {
    for (final owner in owners) {
      await owner.release();
    }
    owners.clear();
    await root.delete(recursive: true);
  });
  Future<PrivateSyncProduction> start() async {
    final owner = h.owner();
    owners.add(owner);
    await owner.bind(h.uid, 1);
    await owner.enroll();
    await owner.setForeground(true);
    return owner;
  }

  test(
    'empty new cursor persists without resetting sequence and survives reopen',
    () async {
      var owner = await start();
      h.emptyCursor = 9;
      await owner.refresh();
      await owner.refresh();
      expect(h.cursors.last, '1:9');
      await owner.release();
      owner = await start();
      expect(h.cursors.last, '1:9');
      final disk =
          jsonDecode(
                await File(
                  '${root.path}/private-sync/${accountDirectoryName(h.uid)}/private_sync_store.json',
                ).readAsString(),
              )
              as Map;
      expect(disk['maxSequence'], 1);
      expect(owner.records, hasLength(1));
    },
  );
  for (final outcome in ['rejected', 'conflict', 'retryable']) {
    test(
      '$outcome first entry does not block later entry or hot retry',
      () async {
        h.outcome = outcome;
        h.ids = ['first', 'second'];
        final owner = await start();
        await owner.refresh();
        expect(
          h.sent.map((b) => (b['records'] as List).single['recordId']),
          contains('second'),
        );
        final first = (await h.entries()).first as Map;
        expect(
          first['state'],
          outcome == 'retryable' ? 'retryable' : 'terminal',
        );
        expect(owner.error, isNotNull);
        final count = h.sent.length;
        await owner.refresh();
        expect(h.sent.length, count);
      },
    );
  }
  test(
    'reenrollment quarantines old backlog and portable copy has fresh identity',
    () async {
      h.outcome = 'retryable';
      final owner = await start();
      h.revoked = true;
      await owner.refresh();
      expect(owner.enrolled, false);
      h.revoked = false;
      h.device = 'device-two';
      h.outcome = null;
      await owner.enroll();
      await owner.refresh();
      final latest = (h.sent.last['records'] as List).single as Map;
      expect(latest['sourceDeviceId'], 'device-two');
      expect(latest['recordId'], isNot('first'));
      expect(latest['payload']['text'], 'secret-like text first');
      final entries = await h.entries();
      expect(entries.first['state'], 'terminal');
      expect(entries.first['envelope']['sourceDeviceId'], 'device-one');
      final count = h.sent.length;
      await owner.refresh();
      expect(h.sent.length, count);
    },
  );
  test(
    'retry deadline survives restart and retry uses identical key and bytes',
    () async {
      h.outcome = 'retryable';
      var owner = await start();
      final initial = jsonEncode(h.sent.single);
      await owner.release();
      owner = await start();
      expect(h.sent, hasLength(1));
      h.clock.time = h.clock.time.add(const Duration(seconds: 61));
      h.outcome = null;
      await owner.refresh();
      expect(jsonEncode(h.sent.last), initial);
      expect((await h.entries()).single['state'], 'acknowledged');
    },
  );
  test(
    'pending deletion migrates across reenrollment and restart without resurrection',
    () async {
      h.revision = 7;
      var owner = await start();
      final original = Map<String, dynamic>.from(h.remote.single);
      await owner.setForeground(false);
      await owner.recordLocalDeletion(recordIds: {'first'});
      final oldDeletion = (await h.entries()).last['envelope'];
      await owner.revokeDevice(reauthenticate: () async => true);
      h.device = 'device-two';
      await owner.enroll();
      final migrated = (await h.entries())
          .where(
            (e) =>
                e['envelope']['recordType'] == 'tombstone' &&
                e['envelope']['sourceDeviceId'] == 'device-two',
          )
          .toList();
      expect(migrated, hasLength(1));
      expect(
        migrated.single['envelope']['recordId'],
        isNot(oldDeletion['recordId']),
      );
      expect(migrated.single['envelope']['payload'], oldDeletion['payload']);
      expect(migrated.single['envelope']['payload']['deletionRevision'], 8);
      await owner.revokeDevice(reauthenticate: () async => true);
      h.device = 'device-three';
      await owner.enroll();
      expect(
        (await h.entries()).where(
          (e) =>
              e['envelope']['recordType'] == 'tombstone' &&
              e['envelope']['sourceDeviceId'] == 'device-three',
        ),
        hasLength(1),
      );
      await owner.release();
      owner = await start();
      expect(owner.records, isEmpty);
      expect(h.remote.first, original);
      expect(h.remote.last['payload']['targetRecordId'], 'first');
      final count = h.sent.length;
      await owner.refresh();
      expect(h.sent, hasLength(count));
    },
  );

  test(
    'local original id deletes accepted portable copy and preserves original revisions',
    () async {
      h.outcome = 'retryable';
      final owner = await start();
      final original = (await h.entries()).first['envelope'];
      await owner.revokeDevice(reauthenticate: () async => true);
      h.device = 'device-two';
      h.outcome = null;
      await owner.enroll();
      final portable = Map<String, dynamic>.from(h.remote.single);
      expect(portable['recordId'], isNot('first'));
      await owner.recordLocalDeletion(recordIds: {'first'});
      await owner.refresh();
      await owner.refresh();
      expect(owner.records, isEmpty);
      expect(
        h.remote
            .where((r) => r['recordType'] == 'tombstone')
            .map((r) => r['payload']['targetRecordId']),
        containsAll(['first', portable['recordId']]),
      );
      expect((await h.entries()).first['envelope'], original);
      expect(h.remote.first, portable);
      expect(owner.error, isNot(contains('secret-like text')));
    },
  );

  test(
    'revoke keys survive same-device retry and rotate on new enrollment',
    () async {
      var owner = await start();
      h.failRevoke = true;
      await expectLater(
        owner.revokeDevice(reauthenticate: () async => true),
        throwsA(anything),
      );
      await owner.release();
      owner = await start();
      h.failRevoke = false;
      await owner.revokeDevice(reauthenticate: () async => true);
      expect(h.revokeRequests[0], h.revokeRequests[1]);
      h.device = 'device-two';
      await owner.enroll();
      await owner.revokeDevice(reauthenticate: () async => true);
      expect(h.revokeRequests.last.device, 'device-two');
      expect(h.revokeRequests.last.key, isNot(h.revokeRequests.first.key));
    },
  );

  test(
    'reenrollment retries interrupted deletion migration with server device identity',
    () async {
      final owner = await start();
      await owner.setForeground(false);
      await owner.recordLocalDeletion(recordIds: {'first'});
      await owner.revokeDevice(reauthenticate: () async => true);
      final file = File(
        '${root.path}/private-sync/${accountDirectoryName(h.uid)}/outbox.json',
      );
      final bytes = await file.readAsBytes();
      h.device = 'device-two';
      h.onEnroll = () async {
        await file.delete();
        await Directory(file.path).create();
      };
      await expectLater(owner.enroll(), throwsA(anything));
      await Directory(file.path).delete();
      await file.writeAsBytes(bytes);
      h.onEnroll = null;
      await owner.enroll();
      expect(owner.deviceId, 'device-two');
      await owner.setForeground(true);
      expect(owner.records, isEmpty);
      expect(h.remote.last['sourceDeviceId'], 'device-two');
      expect(h.remote.last['payload']['targetRecordId'], 'first');
    },
  );
  test(
    'real Timer retries deferred envelope with stable key without manual refresh',
    () async {
      h.realTimers = true;
      h.retrySeconds = 0;
      h.outcome = 'retryable';
      final owner = await start();
      final initial = jsonEncode(h.sent.single);
      final retried = Completer<void>();
      h.outcome = null;
      h.onUpload = () {
        if (!retried.isCompleted) retried.complete();
      };
      await retried.future.timeout(const Duration(seconds: 6));
      expect(jsonEncode(h.sent.last), initial);
      await owner.setForeground(false);
    },
  );
  test(
    'failed revoke leaves enabled delivery working and disable works offline',
    () async {
      final owner = await start();
      h.failRevoke = true;
      await expectLater(
        owner.revokeDevice(reauthenticate: () async => true),
        throwsA(anything),
      );
      expect(owner.enrolled, true);
      h.ids.add('second');
      await owner.refresh();
      expect(h.sent, hasLength(2));
      final disabled = owner.disable();
      expect(owner.enrolled, false);
      await disabled;
      expect(h.deletes, 1);
      expect(owner.records, hasLength(2));
      await owner.release();
      final restored = h.owner();
      owners.add(restored);
      await restored.bind('alice', 2);
      expect(restored.enrolled, false);
      expect(restored.records, hasLength(2));
      await restored.setForeground(true);
      await restored.refresh();
      expect(h.sent, hasLength(2));
    },
  );
  test('cancelled verification never sends revoke', () async {
    final owner = await start();
    await owner.revokeDevice(reauthenticate: () async => false);
    expect(h.deletes, 0);
    expect(owner.enrolled, true);
  });
  test(
    'reenrollment preserves accepted original identity and copies unloaded backlog',
    () async {
      h.ids = ['second', 'first'];
      h.outcome = 'retryable';
      final owner = await start();
      await owner.refresh();
      final accepted = (await h.entries()).first['envelope'];
      h.revoked = true;
      await owner.refresh();
      h.ids = ['second']; // pending transcript no longer in hydrated snapshot
      h.revoked = false;
      h.device = 'device-two';
      h.outcome = null;
      await owner.enroll();
      await owner.refresh();
      expect((await h.entries()).first['envelope'], accepted);
      final copies = h.sent.where(
        (b) => (b['records'] as List).single['sourceDeviceId'] == 'device-two',
      );
      expect(copies, hasLength(1));
      expect(
        (copies.single['records'] as List).single['payload']['text'],
        'secret-like text first',
      );
    },
  );
  test(
    'cold guest all-store clear discovers all accounts and readback checks disk',
    () async {
      final first = await start();
      await first.release();
      h.uid = 'bob';
      final second = await start();
      await second.release();
      final cold = h.owner();
      owners.add(cold);
      final collab = CollaborationProduction(
        endpoint: '',
        rootDirectory: () async => root,
        accountReady: () => false,
        currentUid: () => null,
        accessToken: () async => null,
        appCheckToken: () async => null,
      );
      await Directory(
        '${root.path}/collaboration/alice',
      ).create(recursive: true);
      await File(
        '${root.path}/collaboration/alice/state',
      ).writeAsString('private');
      expect(await cold.verifyEmpty(), false);
      expect(await collab.verifyEmpty(), false);
      final integration = AccountLifecycleIntegration.production(
        dependencies: cold.lifecycle,
        resetDependencies: {
          'private-sync': cold.lifecycle,
          'collaboration': collab.lifecycle,
        },
      );
      final reset = ResetCoordinator([
        integration.asResetStore('private-sync'),
        integration.asResetStore('collaboration'),
      ]);
      await reset.prepare();
      await reset.commit();
      expect(await cold.verifyEmpty(), true);
      expect(await collab.verifyEmpty(), true);
      await Directory(
        '${root.path}/private-sync/residual',
      ).create(recursive: true);
      expect(await cold.verifyEmpty(), false);
    },
  );
}
