import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/private_sync/client.dart';
import 'package:ovid_ai/core/private_sync/coordinator.dart';
import 'package:ovid_ai/core/private_sync/integration.dart';
import 'package:ovid_ai/core/private_sync/outbox.dart';
import 'package:ovid_ai/core/private_sync/store.dart';

class _Account implements FirebaseAccountContext {
  _Account({required this.ready});
  bool ready;
  String? uid = 'account-a';
  @override
  bool get isAvailable => true;
  @override
  bool get accountReady => ready;
  @override
  int get accountGeneration => 7;
  @override
  String? get accountId => uid;
}

class _Clock implements SyncClock {
  @override
  DateTime get now => DateTime.utc(2026, 1, 1);
  @override
  SyncTimer schedule(Duration delay, void Function() callback) => _Timer();
}

class _Timer implements SyncTimer {
  @override
  void cancel() {}
}

class _Jitter implements SyncJitter {
  @override
  Duration delay(Duration cap) => cap;
}

void main() {
  test(
    'returns no composition when the Firebase account is unavailable',
    () async {
      final account = _Account(ready: false);
      final result = await PrivateSyncCompositionFactory().create(
        account: account,
        baseUri: Uri.parse('https://sync.example/'),
        httpClient: http.Client(),
        idToken: (_) async => 'token',
        appCheckToken: () async => 'app-check',
        deviceId: 'device-a',
        store: (_) async => throw StateError('must not open storage'),
        outbox: (_) async => throw StateError('must not open storage'),
        clock: _Clock(),
        jitter: _Jitter(),
      );
      expect(result, isNull);
    },
  );

  test(
    'composes account-scoped client, store, outbox, and coordinator without starting',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sync-integration',
      );
      addTearDown(() => directory.delete(recursive: true));
      final account = _Account(ready: true);
      var storeOpened = 0;
      var outboxOpened = 0;
      final result = await PrivateSyncCompositionFactory().create(
        account: account,
        baseUri: Uri.parse('https://sync.example/'),
        httpClient: http.Client(),
        idToken: (_) async => 'token',
        appCheckToken: () async => 'app-check',
        deviceId: 'device-a',
        store: (id) async {
          storeOpened++;
          return PrivateSyncStore.open(
            accountRoot: Directory('${directory.path}/$id'),
            accountId: id,
          );
        },
        outbox: (id) async {
          outboxOpened++;
          return PrivateSyncOutbox.open(
            _MemoryPersistence(),
            accountId: id,
            ownerId: 'device-a',
          );
        },
        clock: _Clock(),
        jitter: _Jitter(),
      );

      expect(result, isNotNull);
      expect(result!.accountId, 'account-a');
      addTearDown(result.dispose);
      expect(result.client, isA<PrivateSyncClient>());
      expect(result.store, isA<PrivateSyncStore>());
      expect(result.outbox, isA<PrivateSyncOutbox>());
      expect(result.coordinator, isA<PrivateSyncCoordinator>());
      expect(storeOpened, 1);
      expect(outboxOpened, 1);
      expect(result.coordinator.status.foreground, isFalse);
      account.uid = 'account-b';
      expect(await result.client.idToken(false), isNull);
      expect(await result.client.appCheckToken(), isNull);
    },
  );

  test(
    'drops a composition if account readiness changes while opening storage',
    () async {
      final directory = await Directory.systemTemp.createTemp('sync-race');
      addTearDown(() => directory.delete(recursive: true));
      final account = _Account(ready: true);
      final pending = Completer<PrivateSyncStore>();
      final creation = PrivateSyncCompositionFactory().create(
        account: account,
        baseUri: Uri.parse('https://sync.example/'),
        httpClient: http.Client(),
        idToken: (_) async => 'token',
        appCheckToken: () async => 'app-check',
        deviceId: 'device-a',
        store: (_) => pending.future,
        outbox: (_) async => throw StateError('stale outbox must not open'),
        clock: _Clock(),
        jitter: _Jitter(),
      );
      account.ready = false;
      pending.complete(
        await PrivateSyncStore.open(
          accountRoot: directory,
          accountId: 'account-a',
        ),
      );
      expect(await creation, isNull);
    },
  );

  test('ready composition binds the coordinator for explicit refresh', () async {
    final directory = await Directory.systemTemp.createTemp('sync-bind');
    addTearDown(() => directory.delete(recursive: true));
    final result = await PrivateSyncCompositionFactory().create(
      account: _Account(ready: true),
      baseUri: Uri.parse('https://sync.example/'),
      httpClient: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer token');
        expect(request.headers['X-Firebase-AppCheck'], 'app-check');
        return http.Response(
          '{"schemaVersion":1,"records":[],"nextCursor":"next","hasMore":false}',
          200,
          headers: {'cache-control': 'no-store'},
        );
      }),
      idToken: (_) async => 'token',
      appCheckToken: () async => 'app-check',
      deviceId: 'device-a',
      store: (id) =>
          PrivateSyncStore.open(accountRoot: directory, accountId: id),
      outbox: (id) => PrivateSyncOutbox.open(
        _MemoryPersistence(),
        accountId: id,
        ownerId: 'device-a',
      ),
      clock: _Clock(),
      jitter: _Jitter(),
    );
    addTearDown(result!.dispose);
    await result.coordinator.refresh();
    expect(result.store.cursor, 'next');
  });
}

class _MemoryPersistence implements OutboxPersistence {
  List<int>? bytes;
  @override
  Future<List<int>?> read() async => bytes;
  @override
  Future<void> writeAtomically(List<int> value) async => bytes = value;
}
