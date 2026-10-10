import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:ovid_ai/core/collaboration/client.dart';
import 'package:ovid_ai/core/collaboration/coordinator.dart';
import 'package:ovid_ai/core/collaboration/integration.dart';
import 'package:ovid_ai/core/collaboration/store.dart';

class _Account implements FirebaseAccountContext {
  _Account(this.ready);
  bool ready;
  @override
  bool get isAvailable => true;
  @override
  bool get accountReady => ready;
  @override
  int get accountGeneration => 3;
  @override
  String get accountId => 'account-a';
}

class _Scheduler implements CollaborationTimerScheduler {
  int scheduled = 0;
  @override
  CollaborationTimer schedule(Duration delay, void Function() callback) {
    scheduled++;
    return _Timer();
  }
}

class _Timer implements CollaborationTimer {
  @override
  void cancel() {}
}

class _NoHydrationBackend extends MemoryCollaborationStoreBackend {
  @override
  Future<Map<String, Object?>?> read() async =>
      throw StateError('Composition must not hydrate persisted state');
}

void main() {
  test('returns no composition before Firebase account readiness', () async {
    final result = await CollaborationCompositionFactory().create(
      account: _Account(false),
      baseUri: Uri.parse('https://collaboration.example/chat'),
      httpClient: http.Client(),
      accessToken: () async => 'token',
      appCheckToken: () async => 'app-check',
      sessionToken: 'session-token',
      store: (_) async => throw StateError('must not open storage'),
      scheduler: _Scheduler(),
    );
    expect(result, isNull);
  });

  test(
    'composes an account-fenced collaboration runtime without execution hydration',
    () async {
      final scheduler = _Scheduler();
      var opened = 0;
      final result = await CollaborationCompositionFactory().create(
        account: _Account(true),
        baseUri: Uri.parse('https://collaboration.example/chat'),
        httpClient: http.Client(),
        accessToken: () async => 'token',
        appCheckToken: () async => 'app-check',
        sessionToken: 'session-token',
        store: (id) async {
          opened++;
          return CollaborationStore(_NoHydrationBackend(), ownerFence: id);
        },
        scheduler: scheduler,
      );

      expect(result, isNotNull);
      expect(result!.accountId, 'account-a');
      addTearDown(result.dispose);
      expect(result.client, isA<CollaborationClient>());
      expect(result.store, isA<CollaborationStore>());
      expect(result.coordinator, isA<CollaborationCoordinator>());
      expect(opened, 1);
      expect(scheduler.scheduled, 0);
      expect(result.store.state, isNull);
      final token = await result.client.accessToken();
      expect(token, 'token');
    },
  );

  test(
    'rejects credentials completed after account readiness is lost',
    () async {
      final account = _Account(true);
      final pending = Completer<String?>();
      final result = await CollaborationCompositionFactory().create(
        account: account,
        baseUri: Uri.parse('https://collaboration.example/chat'),
        httpClient: http.Client(),
        accessToken: () => pending.future,
        appCheckToken: () async => 'app-check',
        sessionToken: 'session-token',
        store: (id) async => CollaborationStore(
          MemoryCollaborationStoreBackend(),
          ownerFence: id,
        ),
        scheduler: _Scheduler(),
      );
      addTearDown(result!.dispose);
      final token = result.client.accessToken();
      account.ready = false;
      pending.complete('token');
      expect(await token, isNull);
      expect(await result.client.appCheckToken(), isNull);
    },
  );

  test('drops storage opened after account readiness is lost', () async {
    final account = _Account(true);
    final pending = Completer<CollaborationStore>();
    final creation = CollaborationCompositionFactory().create(
      account: account,
      baseUri: Uri.parse('https://collaboration.example/chat'),
      httpClient: http.Client(),
      accessToken: () async => 'token',
      appCheckToken: () async => 'app-check',
      sessionToken: 'session-token',
      store: (_) => pending.future,
      scheduler: _Scheduler(),
    );
    account.ready = false;
    pending.complete(
      CollaborationStore(
        MemoryCollaborationStoreBackend(),
        ownerFence: 'account-a',
      ),
    );
    expect(await creation, isNull);
  });
}
