/// Durable, account-fenced collaboration projection storage.
///
/// This layer deliberately depends only on the typed inert reducer and models.
/// The backend owns durable I/O and must replace its record atomically.
library;

import 'dart:async';
import 'dart:convert';

import 'models.dart';
import 'reducer.dart';

class CollaborationStoreException implements Exception {
  const CollaborationStoreException(this.message);

  final String message;

  @override
  String toString() => 'CollaborationStoreException($message)';
}

/// Persistence boundary for one account-scoped collaboration record.
abstract interface class CollaborationStoreBackend {
  Future<Map<String, Object?>?> read();

  /// Implementations must make this replacement atomic with respect to [record].
  Future<void> write(Map<String, Object?> record);

  Future<void> clear();
}

/// Disk implementations check the lease immediately before atomic replacement.
abstract interface class GuardedCollaborationStoreBackend implements CollaborationStoreBackend {
  Future<void> writeGuarded(Map<String, Object?> record, bool Function() owns);
}

/// Small durable-boundary test backend. It clones through JSON so callers
/// cannot mutate a committed record, and a failed write leaves it untouched.
class MemoryCollaborationStoreBackend implements CollaborationStoreBackend {
  Map<String, Object?>? _record;
  bool failNextWrite = false;

  @override
  Future<Map<String, Object?>?> read() async => _clone(_record);

  @override
  Future<void> write(Map<String, Object?> record) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw const CollaborationStoreException('persistence failed');
    }
    _record = _clone(record);
  }

  @override
  Future<void> clear() async => _record = null;

  static Map<String, Object?>? _clone(Map<String, Object?>? value) {
    if (value == null) return null;
    final decoded = jsonDecode(jsonEncode(value));
    return Map<String, Object?>.from(decoded as Map);
  }
}

class CollaborationStore {
  CollaborationStore(this.backend, {required this.ownerFence});

  final CollaborationStoreBackend backend;
  final String ownerFence;
  final CollaborationReducer _reducer = const CollaborationReducer();

  String? accountId;
  int? sessionGeneration;
  int cursor = 0;
  CollaborationState? state;
  List<CollaborationEvent> _events = const [];
  Map<String, Object?>? _record;

  int _epoch = 0;
  Future<void> _tail = Future.value();
  Future<void> get drained => _tail;

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  /// Loads and validates the last complete account/session record.
  Future<void> load() async {
    final epoch = _epoch;
    await _enqueue(() async {
    final raw = await backend.read();
    if (raw == null || epoch != _epoch) return;
    try {
      final account = raw['accountId'];
      final generation = raw['sessionGeneration'];
      final bootstrap = raw['bootstrap'];
      final events = raw['events'];
      if (account is! String || generation is! int || bootstrap is! Map || events is! List) {
        throw const FormatException('invalid collaboration record');
      }
      if (account != ownerFence || generation < 0) {
        throw const CollaborationStoreException('owner fence mismatch');
      }
      var next = _decodeBootstrap(Map<String, Object?>.from(bootstrap));
      final decodedEvents = <CollaborationEvent>[];
      for (final rawEvent in events) {
        if (rawEvent is! Map) throw const FormatException('invalid event record');
        final event = CollaborationEvent.fromWire(Map<String, Object?>.from(rawEvent));
        decodedEvents.add(event);
        next = _reducer.apply(next, event);
      }
      _record = raw;
      accountId = account;
      sessionGeneration = generation;
      state = next;
      cursor = next.lastSequence;
      _events = List.unmodifiable(decodedEvents);
    } on CollaborationStoreException {
      rethrow;
    } catch (_) {
      throw const CollaborationStoreException('invalid collaboration record');
    }
    });
  }

  Future<void> installBootstrap({
    required String accountId,
    required int sessionGeneration,
    required CollaborationState state,
  }) async {
    if (accountId != ownerFence || sessionGeneration < 0) {
      throw const CollaborationStoreException('owner fence mismatch');
    }
    final epoch = ++_epoch;
    await _enqueue(() async {
    if (epoch != _epoch) return;
    final record = _recordFor(
      accountId: accountId,
      sessionGeneration: sessionGeneration,
      state: state,
      bootstrap: state,
      events: const [],
    );
    await _commit(record, accountId, sessionGeneration, state, const [], epoch);
    });
  }

  /// Reduces the complete page first, then atomically commits both projection
  /// and cursor. A false result means the captured owner/session lease is stale.
  Future<bool> applyPage({
    required String ownerFence,
    required int sessionGeneration,
    required Iterable<CollaborationEvent> page,
  }) => _applyPage(ownerFence: ownerFence, sessionGeneration: sessionGeneration, page: page);

  /// An append response is not replay: it may skip events accepted concurrently.
  /// Check its lease and contiguity against the projection inside the write queue.
  Future<bool> applyAcknowledgement({
    required String ownerFence,
    required int sessionGeneration,
    required Iterable<CollaborationEvent> page,
  }) => _applyPage(ownerFence: ownerFence, sessionGeneration: sessionGeneration,
      page: page, acknowledgement: true);

  Future<bool> _applyPage({
    required String ownerFence,
    required int sessionGeneration,
    required Iterable<CollaborationEvent> page,
    bool acknowledgement = false,
  }) async {
    final epoch = _epoch;
    final pageEvents = List<CollaborationEvent>.unmodifiable(page);
    return _enqueue(() async {
    if (epoch != _epoch) return false;
    final current = state;
    final account = accountId;
    final generation = this.sessionGeneration;
    if (current == null || account == null || generation == null ||
        account != this.ownerFence || ownerFence != account || generation != sessionGeneration) {
      return false;
    }
    if (current.status != CollaborationStatus.live) return false;
    if (acknowledgement) {
      if (pageEvents.isEmpty) return false;
      var expected = current.lastSequence + 1;
      for (final event in pageEvents) {
        if (event.sessionId != current.session.sessionId || event.sequence != expected++) return false;
      }
    }
    final next = _reducer.applyPage(current, pageEvents);
    if (next.status == CollaborationStatus.resyncRequired || pageEvents.any(
        (event) => event.sessionId != current.session.sessionId || event.sequence > next.lastSequence)) {
      return false;
    }
    final allEvents = List<CollaborationEvent>.unmodifiable([..._events, ...pageEvents]);
    final record = _recordFor(
      accountId: account,
      sessionGeneration: sessionGeneration,
      state: next,
      bootstrap: _decodeBootstrap(Map<String, Object?>.from(_record!['bootstrap'] as Map)),
      events: allEvents,
    );
    return _commit(record, account, sessionGeneration, next, allEvents, epoch);
    });
  }

  Future<void> clearSession({required String ownerFence, required int sessionGeneration}) async {
    if (ownerFence != this.ownerFence || this.sessionGeneration != sessionGeneration) return;
    fence();
    await drained;
  }

  /// Invalidates callbacks admitted under the current session generation.
  /// The next session must install a bootstrap with a new generation.
  void fence() {
    _epoch++;
    sessionGeneration = null;
    state = null;
    accountId = null;
    cursor = 0;
    _events = const [];
    _record = null;
    unawaited(_enqueue(backend.clear).catchError((Object _) {}));
  }

  Future<bool> _commit(
    Map<String, Object?> record,
    String account,
    int generation,
    CollaborationState next,
    List<CollaborationEvent> events,
    int epoch,
  ) async {
    if (epoch != _epoch || account != ownerFence) return false;
    try {
      final persistence = backend;
      if (persistence is GuardedCollaborationStoreBackend) {
        await persistence.writeGuarded(record, () => epoch == _epoch && account == ownerFence);
      } else {
        await persistence.write(record);
      }
      if (epoch != _epoch || account != ownerFence) {
        await backend.clear();
        return false;
      }
    } catch (error) {
      if (error is CollaborationStoreException) rethrow;
      throw const CollaborationStoreException('persistence failed');
    }
    _record = record;
    accountId = account;
    sessionGeneration = generation;
    state = next;
    cursor = next.lastSequence;
    _events = List.unmodifiable(events);
    return true;
  }

  Map<String, Object?> _recordFor({
    required String accountId,
    required int sessionGeneration,
    required CollaborationState state,
    required CollaborationState bootstrap,
    required List<CollaborationEvent> events,
  }) => {
        'schemaVersion': collaborationSchemaVersion,
        'accountId': accountId,
        'sessionGeneration': sessionGeneration,
        'cursor': state.lastSequence,
        'bootstrap': _encodeBootstrap(bootstrap),
        'projection': state.debugSnapshot(),
        'events': [for (final event in events) event.toWire()],
      };

  Map<String, Object?> _encodeBootstrap(CollaborationState value) => {
        'session': value.session.toWire(),
        'members': [for (final member in value.members.values) member.toWire()],
        'localParticipantId': value.localParticipantId,
        'lastSequence': value.lastSequence,
        'replayThroughSequence': value.replayThroughSequence,
      };

  CollaborationState _decodeBootstrap(Map<String, Object?> raw) {
    final session = CollaborationSession.fromWire(Map<String, Object?>.from(raw['session'] as Map));
    final members = (raw['members'] as List)
        .map((member) => Member.fromWire(Map<String, Object?>.from(member as Map)))
        .toList();
    return CollaborationState.bootstrap(
      session: session,
      members: members,
      localParticipantId: raw['localParticipantId'] as String,
      lastSequence: raw['lastSequence'] as int,
      replayThroughSequence: raw['replayThroughSequence'] as int? ?? 0,
    );
  }
}
