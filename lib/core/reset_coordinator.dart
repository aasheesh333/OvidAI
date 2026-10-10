import 'dart:async';

import 'settings_actions.dart';

/// The canonical, ordered set of app-owned stores that a verified all-store
/// reset must cover. [ResetCoordinator.canonical] enumerates exactly these, so a
/// missing or renamed store is a programming error rather than a silent gap.
enum ResetStoreKind {
  sessions('sessions'),
  search('search'),
  ledger('ledger'),
  memory('memory'),
  usage('usage'),
  account('account'),
  imageReceipts('image-receipts'),
  shares('shares'),
  privateSync('private-sync'),
  collaboration('collaboration');

  const ResetStoreKind(this.id);
  final String id;
}

typedef AccountLifecycleFence = void Function();
typedef AccountLifecycleBind =
    FutureOr<void> Function(String accountId, int generation);
typedef AccountLifecycleVerify = FutureOr<bool> Function();
typedef AccountLifecycleClear = FutureOr<void> Function();

/// The concrete account-scoped owners supplied by an enabled feature bundle.
/// Keeping this boundary callback-based lets guest/offline builds compose the
/// app without constructing authenticated transports or durable stores.
class AccountLifecycleDependencies {
  const AccountLifecycleDependencies({
    required this.onFence,
    required this.onRevoke,
    required this.onBind,
    required this.onClear,
    required this.onVerifyEmpty,
  });

  final AccountLifecycleFence onFence;
  final AccountLifecycleClear onRevoke;
  final AccountLifecycleBind onBind;
  final AccountLifecycleClear onClear;
  final AccountLifecycleVerify onVerifyEmpty;
}

/// Shared lifecycle seam for account-scoped projections.
///
/// The fence is deliberately separate from [bind]. It is invoked immediately
/// when ownership changes, while [bind] runs only after the account namespace
/// has been restored. No hydration callback is part of this contract: replay
/// and bootstrap remain coordinator-owned foreground work, never execution
/// state hydration.
class AccountLifecycleIntegration {
  const AccountLifecycleIntegration({
    required this.onFence,
    required this.onRevoke,
    required this.onBind,
    required this.onClear,
    required this.onVerifyEmpty,
  });

  final AccountLifecycleFence onFence;
  final AccountLifecycleClear onRevoke;
  final AccountLifecycleBind onBind;
  final AccountLifecycleClear onClear;
  final AccountLifecycleVerify onVerifyEmpty;

  /// Composes a real feature bundle only when its dependencies are present.
  /// Missing auth, endpoint, credentials, or offline setup intentionally
  /// produces the same safe inert integration used by guest sessions.
  factory AccountLifecycleIntegration.production({
    AccountLifecycleDependencies? dependencies,
  }) {
    final value = dependencies;
    if (value == null) {
      return AccountLifecycleIntegration(
        onFence: () {},
        onRevoke: () async {},
        onBind: (_, _) async {},
        onClear: () async {},
        onVerifyEmpty: () async => true,
      );
    }
    return AccountLifecycleIntegration(
      onFence: value.onFence,
      onRevoke: value.onRevoke,
      onBind: value.onBind,
      onClear: value.onClear,
      onVerifyEmpty: value.onVerifyEmpty,
    );
  }

  /// Runs synchronously at the ownership boundary. Implementations should
  /// cancel timers and invalidate generations here; durable clearing happens
  /// later through [asResetStore] or the transition drain.
  void fenceSynchronously() {
    onFence();
  }

  Future<void> fenceAndBind(String accountId, int generation) async {
    onFence();
    await onBind(accountId, generation);
  }

  Future<void> revoke() async => await onRevoke();

  Future<void> clearAccount() async => await onClear();

  ResetStore asResetStore(String name) => FunctionalResetStore(
    name: name,
    onStage: () async {},
    onDelete: () async => await onClear(),
    onVerifyDeleted: () async => await onVerifyEmpty(),
  );
}

/// One app-owned store participating in a verified reset.
///
/// Lifecycle is deliberately split so the coordinator — not the store — owns
/// the commit boundary:
///   • [stage] captures whatever is needed to verify or roll back. It MUST NOT
///     destroy or mutate durable data.
///   • [delete] performs the destructive cleanup. Only [ResetCoordinator.commit]
///     calls it.
///   • [verifyDeleted] reads storage back and proves no user data remains. A
///     store that merely returns without throwing is not trusted.
///   • [restore] reverses a stage side effect when a reset is aborted or a
///     prepare fails. A non-destructive stage may leave this a no-op.
abstract class ResetStore {
  String get name;
  Future<void> stage();
  Future<void> delete();
  Future<bool> verifyDeleted();
  Future<void> restore();
}

/// A [ResetStore] assembled from callbacks. Used for stores whose owners expose
/// private or test-only seams (session persistence, the SQLite search index, the
/// ledger, image receipts, share state).
class FunctionalResetStore implements ResetStore {
  const FunctionalResetStore({
    required this.name,
    required this.onStage,
    required this.onDelete,
    required this.onVerifyDeleted,
    this.onRestore,
  });

  @override
  final String name;
  final Future<void> Function() onStage;
  final Future<void> Function() onDelete;
  final Future<bool> Function() onVerifyDeleted;
  final Future<void> Function()? onRestore;

  @override
  Future<void> stage() => onStage();

  @override
  Future<void> delete() => onDelete();

  @override
  Future<bool> verifyDeleted() => onVerifyDeleted();

  @override
  Future<void> restore() async {
    final restore = onRestore;
    if (restore != null) await restore();
  }
}

/// Truthful outcome for a single store. [verified] is the only signal that the
/// store is actually empty; [deleted] only means `delete()` did not throw.
class ResetStoreReport {
  const ResetStoreReport({
    required this.name,
    required this.deleted,
    required this.verified,
    this.error,
  });

  final String name;
  final bool deleted;
  final bool verified;
  final String? error;
}

/// Per-store result of a commit. [success] is true only when every store was
/// read back and proven empty — never merely because deletion did not throw.
class ResetReport {
  const ResetReport(this.stores);

  final List<ResetStoreReport> stores;

  bool get verifiedComplete =>
      stores.isNotEmpty && stores.every((store) => store.verified);

  bool get success => verifiedComplete;

  List<String> get completed => [
    for (final store in stores)
      if (store.verified) store.name,
  ];

  List<ResetStoreReport> get failures => [
    for (final store in stores)
      if (!store.verified) store,
  ];

  Map<String, String> get errors => {
    for (final store in failures)
      store.name: store.error ?? 'readback did not prove deletion',
  };

  /// Bridge onto the [SettingsActions] reset contract. The UI may only treat
  /// this as READY when [SettingsResetResult.success] is true.
  SettingsResetResult toSettingsResult() => SettingsResetResult(
    completed: completed,
    failures: errors,
    verifiedComplete: verifiedComplete,
  );
}

/// Opaque handle returned by [ResetCoordinator.prepare]. Holding it is the only
/// way to [ResetCoordinator.commit]; until then the reset can be aborted with no
/// durable change.
class ResetPlan {
  ResetPlan._();

  bool _committed = false;

  bool get committed => _committed;
}

/// Prepare → commit → readback reset across an enumerated set of stores.
///
/// Guarantees:
///   • [prepare] stages every store without destroying data. If staging fails,
///     already-staged stores are restored and the error is rethrown.
///   • [commit] is the commit boundary. It deletes and then reads back every
///     store, producing a per-store report. It returns success only when every
///     readback proves deletion.
///   • [abort] is only valid before commit and restores staged stores.
class ResetCoordinator {
  ResetCoordinator(List<ResetStore> stores)
    : stores = List.unmodifiable(stores) {
    if (stores.isEmpty) {
      throw ArgumentError.value(
        stores,
        'stores',
        'At least one store required.',
      );
    }
    final names = <String>{};
    for (final store in stores) {
      if (!names.add(store.name)) {
        throw ArgumentError.value(
          store.name,
          'stores',
          'Duplicate reset store name.',
        );
      }
    }
  }

  /// Enumerates the canonical stores in [ResetStoreKind] order, rejecting a
  /// missing store or a store whose [ResetStore.name] does not match its kind.
  factory ResetCoordinator.canonical(Map<ResetStoreKind, ResetStore> stores) {
    final ordered = <ResetStore>[];
    for (final kind in ResetStoreKind.values) {
      final store = stores[kind];
      if (store == null) {
        throw ArgumentError.value(
          stores,
          'stores',
          'Missing store: ${kind.id}',
        );
      }
      if (store.name != kind.id) {
        throw ArgumentError.value(
          store.name,
          'stores',
          'Store name must match its kind (${kind.id}).',
        );
      }
      ordered.add(store);
    }
    return ResetCoordinator(ordered);
  }

  final List<ResetStore> stores;

  ResetPlan? _plan;

  bool get prepared => _plan != null && !_plan!._committed;

  Future<ResetPlan> prepare() async {
    if (_plan != null) {
      throw StateError('Reset already prepared.');
    }
    final staged = <ResetStore>[];
    try {
      for (final store in stores) {
        await store.stage();
        staged.add(store);
      }
    } catch (_) {
      for (final store in staged.reversed) {
        try {
          await store.restore();
        } catch (_) {
          // Best-effort rollback of a stage that never touched durable data.
        }
      }
      rethrow;
    }
    return _plan = ResetPlan._();
  }

  Future<ResetReport> commit() async {
    final plan = _plan;
    if (plan == null) {
      throw StateError('Prepare the reset before committing.');
    }
    if (plan._committed) {
      throw StateError('Reset already committed.');
    }
    plan._committed = true;
    final reports = <ResetStoreReport>[];
    for (final store in stores) {
      var deleted = false;
      var verified = false;
      String? error;
      try {
        await store.delete();
        deleted = true;
      } catch (e) {
        error = 'delete failed: $e';
      }
      if (deleted) {
        try {
          verified = await store.verifyDeleted();
          if (!verified) {
            error = 'readback still found data';
          }
        } catch (e) {
          error = 'readback failed: $e';
        }
      }
      reports.add(
        ResetStoreReport(
          name: store.name,
          deleted: deleted,
          verified: verified,
          error: error,
        ),
      );
    }
    return ResetReport(reports);
  }

  Future<void> abort() async {
    final plan = _plan;
    if (plan == null) {
      throw StateError('Prepare the reset before aborting.');
    }
    if (plan._committed) {
      throw StateError('Reset already committed.');
    }
    _plan = null;
    Object? firstError;
    for (final store in stores.reversed) {
      try {
        await store.restore();
      } catch (e) {
        firstError ??= e;
      }
    }
    if (firstError != null) throw firstError;
  }
}
