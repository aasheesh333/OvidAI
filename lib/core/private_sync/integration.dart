import 'package:http/http.dart' as http;

import 'client.dart';
import 'coordinator.dart';
import 'dto.dart';
import 'outbox.dart';
import 'protocol.dart';
import 'store.dart';

/// Injected Firebase/account-readiness view; never initializes global services.
abstract interface class FirebaseAccountContext {
  bool get isAvailable;
  bool get accountReady;
  int get accountGeneration;
  String? get accountId;
}

typedef PrivateSyncStoreProvider =
    Future<PrivateSyncStore> Function(String accountId);
typedef PrivateSyncOutboxProvider =
    Future<PrivateSyncOutbox> Function(String accountId);

class PrivateSyncComposition {
  PrivateSyncComposition._({
    required this.accountId,
    required this.client,
    required this.store,
    required this.outbox,
    required this.coordinator,
    required this.invalidate,
  });

  final String accountId;
  final PrivateSyncClient client;
  final PrivateSyncStore store;
  final PrivateSyncOutbox outbox;
  final PrivateSyncCoordinator coordinator;
  final void Function() invalidate;

  Future<void> dispose() async {
    invalidate();
    coordinator.dispose();
    await store.close();
  }
}

/// Creates an idle runtime only for a ready account. Storage providers must
/// return account-scoped projections/outboxes, never hydrate execution state.
/// The caller owns the injected HTTP client and storage-provider I/O policy.
class PrivateSyncCompositionFactory {
  Future<PrivateSyncComposition?> create({
    required FirebaseAccountContext account,
    required Uri baseUri,
    required http.Client httpClient,
    required IdTokenProvider idToken,
    required AppCheckProvider appCheckToken,
    required String deviceId,
    required PrivateSyncStoreProvider store,
    required PrivateSyncOutboxProvider outbox,
    required SyncClock clock,
    required SyncJitter jitter,
    void Function(SyncDeliveryStatus status)? onStatusChanged,
  }) async {
    final accountId = account.accountId;
    if (!account.isAvailable ||
        !account.accountReady ||
        accountId == null ||
        accountId.isEmpty) {
      return null;
    }
    final generation = account.accountGeneration;
    var active = true;
    bool owns() =>
        active &&
        account.isAvailable &&
        account.accountReady &&
        account.accountId == accountId &&
        account.accountGeneration == generation;
    final client = PrivateSyncClient(
      baseUri: baseUri,
      httpClient: httpClient,
      idToken: (forceRefresh) async {
        if (!owns()) return null;
        final token = await idToken(forceRefresh);
        return owns() ? token : null;
      },
      appCheckToken: () async {
        if (!owns()) return null;
        final token = await appCheckToken();
        return owns() ? token : null;
      },
      deviceId: deviceId,
      generation: () => account.accountGeneration,
    );
    final openedStore = await store(accountId);
    if (!owns()) {
      await openedStore.close();
      return null;
    }
    late PrivateSyncOutbox openedOutbox;
    try {
      openedOutbox = await outbox(accountId);
    } catch (_) {
      await openedStore.close();
      rethrow;
    }
    if (!owns()) {
      await openedStore.close();
      return null;
    }
    if (openedStore.accountId != accountId) {
      await openedStore.close();
      throw StateError('Private sync storage account mismatch');
    }
    final coordinator = PrivateSyncCoordinator(
      client: _ClientAdapter(client),
      store: _StoreAdapter(openedStore, owns),
      outbox: _OutboxAdapter(openedOutbox),
      clock: clock,
      jitter: jitter,
      onStatusChanged: onStatusChanged,
    );
    await coordinator.bindAccount(accountId: accountId, generation: generation);
    return PrivateSyncComposition._(
      accountId: accountId,
      client: client,
      store: openedStore,
      outbox: openedOutbox,
      coordinator: coordinator,
      invalidate: () => active = false,
    );
  }
}

class _StoreAdapter implements PrivateSyncCoordinatorStore {
  _StoreAdapter(this.value, this.owns);
  final PrivateSyncStore value;
  final bool Function() owns;
  @override
  String get cursor => value.cursor;
  @override
  Future<void> applyPage(Object page) async {
    if (!owns()) return;
    if (page is SyncChangePage) {
      await value.applyPage({...page.toWire(), 'accountId': value.accountId});
    } else {
      await value.applyPage(page);
    }
  }

  @override
  Future<void> installState(Object page) async {
    if (owns()) await value.installState(page);
  }

  @override
  Future<void> clearAccount() => value.clearAccount();
}

class _ClientAdapter implements PrivateSyncCoordinatorClient {
  _ClientAdapter(this.value);
  final PrivateSyncClient value;
  @override
  Future<SyncBatchResult> upload(
    String idempotencyKey,
    List<SyncUploadRecord> records,
  ) => value.upload(idempotencyKey, records);
  @override
  Future<SyncChangePage> changes({required String cursor}) =>
      value.changes(cursor: cursor);
  @override
  Future<SyncStatePage> state() => value.state();
}

class _OutboxAdapter implements PrivateSyncCoordinatorOutbox {
  _OutboxAdapter(this.value);
  final PrivateSyncOutbox value;
  @override
  Future<List<OutboxEntry>> entries() => value.entries();
  @override
  Future<void> acknowledge(String idempotencyKey) async {
    await value.acknowledge(idempotencyKey);
  }

  @override
  Future<void> clearAccount() => value.clearAccount();
}
