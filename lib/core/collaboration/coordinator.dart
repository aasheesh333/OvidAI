import 'dart:async';

import 'client.dart' as client;
import 'reducer.dart';
import 'store.dart';

const collaborationPollCadence = Duration(seconds: 15);
const collaborationStaleAfter = Duration(seconds: 45);

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
    double Function()? random,
  }) : _random = random ?? (() => 0.5);

  client.CollaborationClient _client;
  CollaborationStore _store;
  String _accountId;
  String _sessionToken;
  final CollaborationTimerScheduler scheduler;
  final void Function(client.CollaborationClientException)? onTerminal;
  final double Function() _random;
  int _generation = 0;
  bool _started = false;
  bool _busy = false;
  bool _bootstrapped = false;
  bool _refreshPending = false;
  bool _stale = false;
  int _failures = 0;
  CollaborationTimer? _pollTimer;
  CollaborationTimer? _staleTimer;
  CollaborationTimer? _reconnectTimer;
  Duration? reconnectDelay;
  client.CollaborationCursor? cursor;

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

  void _finish(int generation) {
    if (!_valid(generation)) return;
    _busy = false;
    if (_refreshPending) {
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
      final state = await _client.state(_sessionToken);
      if (!_valid(generation)) return;
      final projection = CollaborationState.bootstrap(
        session: state.session,
        members: state.initialMembers ?? state.members,
        localParticipantId: state.member.participantId,
        lastSequence: 0,
        replayThroughSequence: state.replayThroughSequence,
      );
      await _store.installBootstrap(
        accountId: _accountId,
        sessionGeneration: generation,
        state: projection,
      );
      if (!_valid(generation)) return;
      cursor = state.cursor;
      _bootstrapped = true;
      await _replay(generation);
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

  Future<void> _poll(int generation) async {
    if (!_valid(generation) || _busy) return;
    _busy = true;
    try {
      await _replay(generation);
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
    cursor = null;
    reconnectDelay = null;
    _setStale(true);
    _cancelTimers();
    _store.fence();
    onTerminal?.call(error);
  }

  Future<void> _replay(int generation) async {
    var pages = 0;
    var more = true;
    while (more && pages++ < 4) {
      final page = await _client.replay(_sessionToken, cursor: cursor);
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
    _pollTimer = scheduler.schedule(collaborationPollCadence, () {
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
