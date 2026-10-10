import 'package:http/http.dart' as http;

import 'client.dart';
import 'coordinator.dart';
import 'store.dart';

/// Injected Firebase/account-readiness view; never initializes global services.
abstract interface class FirebaseAccountContext {
  bool get isAvailable;
  bool get accountReady;
  int get accountGeneration;
  String? get accountId;
}

typedef CollaborationStoreProvider =
    Future<CollaborationStore> Function(String accountId);

class CollaborationComposition {
  CollaborationComposition._({
    required this.accountId,
    required this.client,
    required this.store,
    required this.coordinator,
    required this.invalidate,
  });

  final String accountId;
  final CollaborationClient client;
  final CollaborationStore store;
  final CollaborationCoordinator coordinator;
  final void Function() invalidate;

  void dispose() {
    invalidate();
    coordinator.dispose();
    store.fence();
  }
}

/// Creates an idle account/session runtime without calling load or start.
/// Storage providers must return inert account-scoped projection stores.
/// The caller retains ownership of the injected HTTP client.
class CollaborationCompositionFactory {
  Future<CollaborationComposition?> create({
    required FirebaseAccountContext account,
    required Uri baseUri,
    required http.Client httpClient,
    required Future<String?> Function() accessToken,
    required Future<String?> Function() appCheckToken,
    required String sessionToken,
    required CollaborationStoreProvider store,
    required CollaborationTimerScheduler scheduler,
    double Function()? random,
  }) async {
    final accountId = account.accountId;
    if (!account.isAvailable ||
        !account.accountReady ||
        accountId == null ||
        accountId.isEmpty ||
        sessionToken.isEmpty) {
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
    final client = CollaborationClient(
      baseUri: baseUri,
      accessToken: () async {
        if (!owns()) return null;
        final token = await accessToken();
        return owns() ? token : null;
      },
      appCheckToken: () async {
        if (!owns()) return null;
        final token = await appCheckToken();
        return owns() ? token : null;
      },
      httpClient: httpClient,
    );
    final openedStore = await store(accountId);
    if (!owns()) {
      openedStore.fence();
      return null;
    }
    if (openedStore.ownerFence != accountId) {
      throw StateError('Collaboration storage account mismatch');
    }
    final coordinator = CollaborationCoordinator(
      client: client,
      store: openedStore,
      accountId: accountId,
      sessionToken: sessionToken,
      scheduler: scheduler,
      random: random,
    );
    return CollaborationComposition._(
      accountId: accountId,
      client: client,
      store: openedStore,
      coordinator: coordinator,
      invalidate: () => active = false,
    );
  }
}
