import 'dart:async';

import 'client.dart' as client;
import 'reducer.dart';
import 'store.dart';

const collaborationPollCadence = Duration(seconds: 15);
const collaborationStaleAfter = Duration(seconds: 45);

/// Server hold for live (foreground, on-screen) long polls.
const collaborationLiveWaitSeconds = 25;

/// Gap between consecutive live long polls.
const collaborationLiveGap = Duration(milliseconds: 300);

abstract interface class CollaborationTimer {
  void cancel();
}

abstract interface class CollaborationTimerScheduler {
  CollaborationTimer schedule(Duration delay, void Function() callback);
}

class CollaborationCoordinator {
  CollaborationCoordinator({
    required this._client,
    required this._store,
    required this._accountId,
    required this._sessionToken,
    required this.scheduler,
    this.onTerminal,
    this.onChanged,
    double Function()? random,
  }) : _random = random ?? (() => 0.5);

  client.CollaborationClient _client;
  CollaborationStore _store;
  String _accountId;
  String _sessionToken;
  final CollaborationTimerScheduler scheduler;
  final void Function(client.CollaborationClientException)? onTerminal;
  final void Function()? onChanged;
  final double Function() _random;
  int _generation = 0;
  bool _started = false;
  bool _busy = false;
  bool _bootstrapped = false;
  bool _refreshPending = false;
  bool _roomFactsRefreshPending = false;
  bool _roomFactsStartScheduled = false;
  bool _stale = false;
  int _failures = 0;
  CollaborationTimer? _pollTimer;
  CollaborationTimer? _staleTimer;
  CollaborationTimer? _reconnectTimer;
  Duration? reconnectDelay;
  client.CollaborationCursor? cursor;

  /// When true, polls long-poll the server (~1 s delivery) instead of
  /// sleeping [collaborationPollCadence] between short polls.
  bool _live = false;
  bool get live => _live;
  set live(bool value) {
    if (_live == value) return;
    _live = value;
    if (_started && value && !_busy && _bootstrapped) {
      _pollTimer?.cancel();
      unawaited(_poll(_generation));
    }
  }

  bool get isStale => _stale;

  /// Replay from the existing cursor. A send never resets the bootstrap.
  void refresh() {
    if (!_started) return;
    if (_busy) {
      _refreshPending = true;
    } else {
      unawaited(_bootstrapped ? _poll(_generation) : _bootstrapAndPoll(_generation));
    }
  }

  /// Forces an authoritative state read even after bootstrap. Same-tick calls
  /// coalesce. A later call during any poll/read is never folded into a
  /// potentially pre-confirmation response: it leaves a trailing forced read.
  void refreshRoomFacts() {
    if (!_started) return;
    if (_busy) {
      _roomFactsRefreshPending = true;
      return;
    }
    if (_roomFactsStartScheduled) return;
    _roomFactsStartScheduled = true;
    final generation = _generation;
    scheduleMicrotask(() {
      if (!_valid(generation)) return;
      _roomFactsStartScheduled = false;
      if (_busy) {
        _roomFactsRefreshPending = true;
        return;
      }
      _roomFactsRefreshPending = false;
      unawaited(_bootstrapAndPoll(generation));
    });
  }

  void _finish(int generation) {
    if (!_valid(generation)) return;
    _busy = false;
    if (_roomFactsRefreshPending) {
      _roomFactsRefreshPending = false;
      _refreshPending = false;
      refreshRoomFacts();
    } else if (_refreshPending) {
      _refreshPending = false;
      refresh();
    }
  }

  void start() {
    if (_started) return;
    _started = true;
    unawaited(_bootstrapAndPoll(_generation));
    _armStale(_generation);
  }

  void bind({
    required String accountId,
    required String sessionToken,
    required CollaborationStore store,
    client.CollaborationClient? client,
  }) {
    _store.fence();
    _generation++;
    _accountId = accountId;
    _sessionToken = sessionToken;
    _store = store;
    if (client != null) _client = client;
    _busy = false;
    _bootstrapped = false;
    _refreshPending = false;
    _roomFactsRefreshPending = false;
    _roomFactsStartScheduled = false;
    cursor = null;
    _failures = 0;
    reconnectDelay = null;
    _cancelTimers();
    _setStale(false);
    if (_started) {
      unawaited(_bootstrapAndPoll(_generation));
      _armStale(_generation);
    }
  }

  void dispose() {
    _started = false;
    _generation++;
    _cancelTimers();
    _store.fence();
  }

  Future<void> _bootstrapAndPoll(int generation) async {
    if (!_valid(generation) || _busy) return;
    _busy = true;
    try {
      await _readAndApplyRoomFacts(generation);
      if (!_valid(generation)) return;
      await _replay(generation);
      if (!_valid(generation)) return;
      // The first drain can admit/finish work. Refresh only volatile room
      // facts afterwards, matching the Web replay-then-state ordering.
      await _readAndApplyRoomFacts(generation);
      if (_valid(generation)) {
        _failures = 0;
        reconnectDelay = null;
        _setStale(false);
        _armStale(generation);
        _schedulePoll(generation);
      }
    } on client.CollaborationClientException catch (error) {
      if (!_valid(generation)) return;
      if (_terminal(error)) {
        _stopAndFence(error);
      } else {
        if (error.statusCode == 410) {
          _bootstrapped = false;
          cursor = null;
        }
        _scheduleReconnect(generation);
      }
    } catch (_) {
      if (_valid(generation)) _scheduleReconnect(generation);
    } finally {
      _finish(generation);
    }
  }

  Future<void> _readAndApplyRoomFacts(int generation) async {
    final fresh = await _client.state(_sessionToken);
    if (!_valid(generation)) return;
    final current = _store.state;
    if (_bootstrapped &&
        current != null &&
        current.status == CollaborationStatus.live) {
      if (_store.accountId != _accountId ||
          _store.sessionGeneration != generation) {
        throw const CollaborationStoreException('room facts fence mismatch');
      }
      // CollaborationStore's durable cursor API is intentionally unchanged.
      // This synchronous, generation-checked merge changes no cursor, event,
      // bootstrap record, or persisted replay position.
      _store.state = current.refreshServerFacts(
        session: fresh.session,
        members: fresh.members,
        turn: fresh.turn,
      );
      onChanged?.call();
      return;
    }
    final projection = CollaborationState.bootstrap(
      session: fresh.session.withTurn(fresh.turn),
      // Zero-history rooms have no membership replay that could prove a local
      // departure. Use the authorized FULL roster before localRemoved is
      // classified; legacy non-empty history retains its owner-only boundary.
      members: fresh.replayThroughSequence == 0
          ? fresh.members
          : (fresh.initialMembers ?? fresh.members),
      localParticipantId: fresh.member.participantId,
      lastSequence: 0,
      replayThroughSequence: fresh.replayThroughSequence,
    );
    await _store.installBootstrap(
      accountId: _accountId,
      sessionGeneration: generation,
      state: projection,
    );
    if (!_valid(generation)) return;
    cursor = fresh.cursor;
    _bootstrapped = true;
    onChanged?.call();
  }

  Future<void> _poll(int generation) async {
    if (!_valid(generation) || _busy) return;
    _busy = true;
    try {
      await _replay(generation, wait: _live);
      if (!_valid(generation)) return;
      await _readAndApplyRoomFacts(generation);
      if (_valid(generation)) {
        _failures = 0;
        reconnectDelay = null;
        _setStale(false);
        _armStale(generation);
        _schedulePoll(generation);
      }
    } on client.CollaborationClientException catch (error) {
      if (!_valid(generation)) return;
      if (error.statusCode == 410) {
        _bootstrapped = false;
        cursor = null;
        _busy = false;
        await _bootstrapAndPoll(generation);
      } else if (_terminal(error)) {
        _stopAndFence(error);
      } else {
        _scheduleReconnect(generation);
      }
    } catch (_) {
      if (_valid(generation)) _scheduleReconnect(generation);
    } finally {
      _finish(generation);
    }
  }

  bool _terminal(client.CollaborationClientException error) =>
      error.isTerminalSessionError;

  void _stopAndFence(client.CollaborationClientException error) {
    _started = false;
    _generation++;
    _busy = false;
    _bootstrapped = false;
    _refreshPending = false;
    _roomFactsRefreshPending = false;
    _roomFactsStartScheduled = false;
    cursor = null;
    reconnectDelay = null;
    _setStale(true);
    _cancelTimers();
    _store.fence();
    onTerminal?.call(error);
  }

  Future<void> _replay(int generation, {bool wait = false}) async {
    var pages = 0;
    var more = true;
    while (more && pages++ < 4) {
      final page = await _client.replay(
        _sessionToken,
        cursor: cursor,
        // Only an up-to-date first page may wait; catch-up pages never hold.
        waitSeconds: wait && pages == 1 ? collaborationLiveWaitSeconds : 0,
      );
      if (!_valid(generation)) return;
      final applied = await _store.applyPage(
        ownerFence: _accountId,
        sessionGeneration: generation,
        page: page.events,
      );
      if (!_valid(generation)) return;
      if (!applied) {
        throw const CollaborationStoreException('replay page not committed');
      }
      cursor = page.nextCursor;
      more = page.hasMore;
    }
  }

  void _schedulePoll(int generation) {
    _pollTimer?.cancel();
    _pollTimer = scheduler.schedule(
        _live ? collaborationLiveGap : collaborationPollCadence, () {
      unawaited(_poll(generation));
    });
  }

  void _scheduleReconnect(int generation) {
    _setStale(true);
    final base = 2 << _failures.clamp(0, 5);
    final max = base > 60 ? 60 : base;
    final span = max - 2;
    final seconds = 2 + (_random().clamp(0.0, 1.0) * span).floor();
    reconnectDelay = Duration(seconds: seconds);
    _failures++;
    _reconnectTimer?.cancel();
    _reconnectTimer = scheduler.schedule(reconnectDelay!, () {
      if (_valid(generation)) {
        unawaited(_bootstrapped ? _poll(generation) : _bootstrapAndPoll(generation));
      }
    });
  }

  void _armStale(int generation) {
    _staleTimer?.cancel();
    _staleTimer = scheduler.schedule(collaborationStaleAfter, () {
      if (_valid(generation)) _setStale(true);
    });
  }

  void _setStale(bool value) => _stale = value;
  bool _valid(int generation) => _started && generation == _generation;

  void _cancelTimers() {
    _pollTimer?.cancel();
    _staleTimer?.cancel();
    _reconnectTimer?.cancel();
    _pollTimer = _staleTimer = _reconnectTimer = null;
  }
}
