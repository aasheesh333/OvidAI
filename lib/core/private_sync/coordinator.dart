import 'dart:async';

import 'dto.dart';
import 'outbox.dart' as delivery;
import 'protocol.dart' as wire;

/// Timer abstraction used by the foreground coordinator and deterministic tests.
abstract interface class SyncTimer {
  void cancel();
}

abstract interface class SyncClock {
  DateTime get now;
  SyncTimer schedule(Duration delay, void Function() callback);
}

abstract interface class SyncJitter {
  Duration delay(Duration cap);
}

abstract interface class PrivateSyncCoordinatorOutbox {
  Future<List<delivery.OutboxEntry>> entries();
  Future<void> acknowledge(String idempotencyKey);
  Future<void> clearAccount();
}

/// Durable delivery result processing for production outboxes. Each submitted
/// envelope keeps its own key, quarantine state, and retry deadline.
abstract interface class PrivateSyncResultOutbox {
  Future<void> applyResults(
    List<delivery.OutboxEntry> submitted,
    wire.SyncBatchResult result,
  );
  Future<Duration?> nextRetryDelay();
}

abstract interface class PrivateSyncCoordinatorStore {
  String get cursor;
  Future<void> applyPage(Object page);
  Future<void> installState(Object page);
  Future<void> clearAccount();
}

abstract interface class PrivateSyncCoordinatorClient {
  Future<wire.SyncBatchResult> upload(
    String idempotencyKey,
    List<SyncUploadRecord> records,
  );
  Future<wire.SyncChangePage> changes({required String cursor});
  Future<wire.SyncStatePage> state();
}

typedef SyncResetRequired = wire.SyncResetRequired;

class SyncTransientFailure implements Exception {
  const SyncTransientFailure();
}

class SyncDeliveryStatus {
  const SyncDeliveryStatus({
    required this.foreground,
    required this.retrying,
    required this.isStale,
    required this.revision,
  });

  final bool foreground;
  final bool retrying;
  final bool isStale;
  final int revision;
}

class PrivateSyncCoordinator {
  PrivateSyncCoordinator({
    required this._client,
    required this._store,
    required this._outbox,
    required this._clock,
    required this._jitter,
    this.onStatusChanged,
  });

  static const cadence = Duration(seconds: 15);
  static const staleAfter = Duration(seconds: 45);
  static const minRetry = Duration(seconds: 2);
  static const maxRetry = Duration(seconds: 60);
  static const maxPageRecords = 100;
  static const maxPageBytes = 256 * 1024;
  static const repaintWindow = Duration(milliseconds: 250);

  final PrivateSyncCoordinatorClient _client;
  final PrivateSyncCoordinatorStore _store;
  final PrivateSyncCoordinatorOutbox _outbox;
  final SyncClock _clock;
  final SyncJitter _jitter;
  final void Function(SyncDeliveryStatus status)? onStatusChanged;

  String? _accountId;
  int? _generation;
  bool _foreground = false;
  bool _disposed = false;
  bool _retrying = false;
  int _retryAttempt = 0;
  int _revision = 0;
  DateTime? _lastSuccess;
  DateTime? _boundAt;
  Future<void>? _inFlight;
  SyncTimer? _pollTimer;
  SyncTimer? _retryTimer;
  SyncTimer? _statusTimer;
  SyncDeliveryStatus? _pendingStatus;
  SyncDeliveryStatus get status => SyncDeliveryStatus(
    foreground: _foreground,
    retrying: _retrying,
    isStale:
        _clock.now.difference(_lastSuccess ?? _boundAt ?? _clock.now) >=
        staleAfter,
    revision: _revision,
  );

  Future<void> bindAccount({
    required String accountId,
    required int generation,
  }) async {
    if (_accountId == accountId && _generation == generation) return;
    _cancelWork();
    if (_accountId != null) {
      await _store.clearAccount();
      await _outbox.clearAccount();
    }
    if (_disposed) return;
    _accountId = accountId;
    _generation = generation;
    _lastSuccess = null;
    _boundAt = _clock.now;
    _retryAttempt = 0;
    _retrying = false;
    _revision++;
    _publish();
  }

  Future<void> setForeground(bool value) async {
    if (_disposed || _foreground == value) return;
    _foreground = value;
    if (!value) {
      _cancelWork();
    } else if (_accountId != null) {
      await refresh();
      _inFlight = null;
      if (_foreground) _pollTimer = _schedule(cadence, _onCadence);
    }
    _publish();
  }

  Future<void> refresh() {
    if (_disposed || _accountId == null) {
      return Future<void>.value();
    }
    final current = _inFlight;
    if (current != null) return current;
    final future = _reconcile();
    _inFlight = future;
    future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
    return future;
  }

  Future<void> revoke() async {
    _cancelWork();
    await _store.clearAccount();
    await _outbox.clearAccount();
    _accountId = null;
    _generation = null;
    _lastSuccess = null;
    _boundAt = null;
    _revision++;
    _publish();
  }

  Future<void> stop() async {
    _foreground = false;
    _cancelWork();
    _publish();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelWork();
    _accountId = null;
    _generation = null;
  }

  Future<void> _reconcile() async {
    final generation = _generation;
    try {
      final pending = await _outbox.entries();
      if (!_owns(generation)) return;
      if (pending.isNotEmpty) {
        final result = await _client.upload(
          pending.first.idempotencyKey,
          pending.map((entry) => entry.envelope).toList(growable: false),
        );
        if (!_owns(generation)) return;
        if (_outbox case final PrivateSyncResultOutbox durable) {
          await durable.applyResults(pending, result);
        } else if (result.results.every(
          (item) =>
              item.status == wire.SyncRecordOutcomeStatus.accepted ||
              item.status == wire.SyncRecordOutcomeStatus.duplicate,
        )) {
          await _outbox.acknowledge(pending.first.idempotencyKey);
        }
      }
      try {
        await _drainChanges(generation);
      } on SyncResetRequired {
        if (!_owns(generation)) return;
        final state = await _client.state();
        if (!_owns(generation)) return;
        await _store.installState(state);
        _revision++;
        // State is bounded. Its cursor is the last included change, so replay
        // the remainder before declaring this reconciliation successful.
        await _drainChanges(generation);
      }
      if (_owns(generation)) {
        _lastSuccess = _clock.now;
        _retryAttempt = 0;
        _retrying = false;
        if (_outbox case final PrivateSyncResultOutbox durable) {
          final delay = await durable.nextRetryDelay();
          if (!_owns(generation)) return;
          _retryTimer?.cancel();
          if (delay != null && _foreground) {
            _retrying = true;
            _retryTimer = _schedule(delay, () {
              _retryTimer = null;
              unawaited(refresh());
            });
          }
        }
        _publish();
      }
    } on SyncTransientFailure {
      if (!_owns(generation) || !_foreground) return;
      _retryAttempt++;
      final multiplier = 1 << (_retryAttempt - 1).clamp(0, 5);
      final cap = Duration(
        seconds: (minRetry.inSeconds * multiplier).clamp(
          minRetry.inSeconds,
          maxRetry.inSeconds,
        ),
      );
      _retrying = true;
      _publish();
      _retryTimer?.cancel();
      _retryTimer = _schedule(_jitter.delay(cap), () {
        _retryTimer = null;
        unawaited(refresh());
      });
    }
  }

  Future<void> _drainChanges(int? generation) async {
    var hasMore = true;
    while (hasMore && _owns(generation)) {
      final cursor = _store.cursor;
      final page = await _client.changes(cursor: cursor);
      if (!_owns(generation)) return;
      if (page.hasMore && page.nextCursor == cursor) {
        throw const SyncTransientFailure();
      }
      await _store.applyPage(page);
      _revision++;
      hasMore = page.hasMore;
    }
  }

  bool _owns(int? generation) =>
      !_disposed && generation != null && generation == _generation;

  void _onCadence() {
    if (!_foreground || _disposed) return;
    unawaited(refresh());
    _pollTimer = _schedule(cadence, _onCadence);
  }

  SyncTimer _schedule(Duration delay, void Function() callback) =>
      _clock.schedule(delay, callback);

  void _cancelWork() {
    _pollTimer?.cancel();
    _retryTimer?.cancel();
    _statusTimer?.cancel();
    _pollTimer = null;
    _retryTimer = null;
    _statusTimer = null;
    _retrying = false;
  }

  void _publish() {
    final next = status;
    _pendingStatus = next;
    if (_statusTimer != null) return;
    _statusTimer = _schedule(repaintWindow, () {
      _statusTimer = null;
      final pending = _pendingStatus;
      _pendingStatus = null;
      if (pending != null) {
        onStatusChanged?.call(pending);
      }
    });
  }
}
