/// Durable, account-fenced collaboration projection storage.
///
/// This layer deliberately depends only on the typed inert reducer and models.
/// The backend owns durable I/O and must replace its record atomically.
library;

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

  /// Loads and validates the last complete account/session record.
  Future<void> load() async {
    final raw = await backend.read();
    if (raw == null) return;
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
  }

  Future<void> installBootstrap({
    required String accountId,
    required int sessionGeneration,
    required CollaborationState state,
  }) async {
    if (accountId != ownerFence || sessionGeneration < 0) {
      throw const CollaborationStoreException('owner fence mismatch');
    }
    final record = _recordFor(
      accountId: accountId,
      sessionGeneration: sessionGeneration,
      state: state,
      bootstrap: state,
      events: const [],
    );
    await _commit(record, accountId, sessionGeneration, state, const []);
  }

  /// Reduces the complete page first, then atomically commits both projection
  /// and cursor. A false result means the captured owner/session lease is stale.
  Future<bool> applyPage({
    required String ownerFence,
    required int sessionGeneration,
    required Iterable<CollaborationEvent> page,
  }) async {
    final current = state;
    final account = accountId;
    final generation = this.sessionGeneration;
    if (current == null || account == null || generation == null ||
        account != this.ownerFence || ownerFence != account || generation != sessionGeneration) {
      return false;
    }
    final pageEvents = List<CollaborationEvent>.unmodifiable(page);
    final next = _reducer.applyPage(current, pageEvents);
    final allEvents = List<CollaborationEvent>.unmodifiable([..._events, ...pageEvents]);
    final record = _recordFor(
      accountId: account,
      sessionGeneration: sessionGeneration,
      state: next,
      bootstrap: _decodeBootstrap(Map<String, Object?>.from(_record!['bootstrap'] as Map)),
      events: allEvents,
    );
    await _commit(record, account, sessionGeneration, next, allEvents);
    return true;
  }

  Future<void> clearSession({required String ownerFence, required int sessionGeneration}) async {
    if (ownerFence != this.ownerFence || this.sessionGeneration != sessionGeneration) return;
    await backend.clear();
    _record = null;
    accountId = null;
    this.sessionGeneration = null;
    state = null;
    cursor = 0;
    _events = const [];
  }

  /// Invalidates callbacks admitted under the current session generation.
  /// The next session must install a bootstrap with a new generation.
  void fence() {
    sessionGeneration = null;
    state = null;
    accountId = null;
    cursor = 0;
    _events = const [];
    _record = null;
  }

  Future<void> _commit(
    Map<String, Object?> record,
    String account,
    int generation,
    CollaborationState next,
    List<CollaborationEvent> events,
  ) async {
    try {
      await backend.write(record);
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
    );
  }
}
