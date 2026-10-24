import 'dart:async';

import 'package:flutter/foundation.dart';

import 'cloud_rest.dart';
import 'trajectory_projection.dart';

@immutable
class TrajectoryEventPage {
  const TrajectoryEventPage({required this.events, this.nextCursor});

  final List<Map<String, dynamic>> events;
  final String? nextCursor;
}

typedef TrajectoryTimerFactory =
    Timer Function(Duration duration, void Function() callback);

/// Read-only gateway surface for canonical trajectory data. Every call goes
/// through [CloudRestClient], so current auth, owner checks and the one 401
/// refresh/retry apply to summaries, child activity and every raw page alike.
class TrajectoryApi {
  TrajectoryApi([CloudRestClient? rest]) : _rest = rest ?? CloudRestClient.I;

  final CloudRestClient _rest;

  static const int rootPageSize = 200;
  static const int rawPageSize = 50;

  Future<TrajectoryRoot> root(String sessionId, {String? before}) async {
    final id = Uri.encodeComponent(sessionId);
    final summary = await _rest.getJson(
      '/sessions/$id/subagents',
      query: <String, String>{'limit': '$rootPageSize'},
    );
    final events = await _rest.getJson(
      '/sessions/$id/events',
      query: <String, String>{
        'limit': '$rootPageSize',
        if (before == null) 'tail': '1' else 'before': before,
      },
    );
    final decoded = _events(events);
    String? earlierCursor;
    if (decoded.length >= rootPageSize && decoded.isNotEmpty) {
      final oldest = decoded.first['seq'];
      final repeatsBound =
          before != null && decoded.any((event) => '${event['seq']}' == before);
      if (oldest != null && '$oldest' != before && !repeatsBound) {
        // The real route returns only {events}. A full page's oldest real seq
        // is the next exclusive `before`; short/empty/exhausted pages end.
        earlierCursor = '$oldest';
      }
    }
    return foldTrajectoryPages(<Object?>[
      summary,
      <String, dynamic>{'events': decoded, 'earlierCursor': earlierCursor},
    ]);
  }

  Future<TrajectoryEventPage> workerEvents(
    String childSessionId, {
    String? after,
  }) async {
    final json = await _rest.getJson(
      '/sessions/${Uri.encodeComponent(childSessionId)}/events',
      query: <String, String>{'limit': '$rootPageSize', 'after': ?after},
    );
    final events = _events(json);
    String? nextCursor;
    if (events.isNotEmpty) {
      final last = events.last['seq'];
      final repeatsAfter =
          after != null && events.any((event) => '${event['seq']}' == after);
      if (last != null && '$last' != after && !repeatsAfter) {
        nextCursor = '$last';
      }
    }
    return TrajectoryEventPage(events: events, nextCursor: nextCursor);
  }

  static List<Map<String, dynamic>> _events(
    Map<String, dynamic> json,
  ) => <Map<String, dynamic>>[
    for (final event
        in json['events'] is List ? json['events'] as List : const <Object?>[])
      if (event is Map) Map<String, dynamic>.from(event),
  ];

  /// Raw history is fetched only when the caller explicitly invokes this
  /// method. There is no local raw-event substitute and no mutation method.
  Future<RawTrajectoryPage> showRaw(String sessionId, {String? after}) async {
    final json = await _rest.getJson(
      '/sessions/${Uri.encodeComponent(sessionId)}/history/raw',
      query: <String, String>{'limit': '$rawPageSize', 'after': ?after},
    );
    return RawTrajectoryPage.fromJson(json);
  }
}

/// Visible-only root refresh and one explicit expanded-child cursor. Child
/// requests are made on expansion and visible fallback refreshes only;
/// collapsing a child fences late expansion work and stops its polling.
class TrajectoryController extends ChangeNotifier {
  TrajectoryController({
    required this.api,
    required this.sessionId,
    this.refreshInterval = const Duration(seconds: 30),
    TrajectoryTimerFactory? timerFactory,
  }) : _timerFactory = timerFactory ?? Timer.new;

  final TrajectoryApi api;
  final String sessionId;
  final Duration refreshInterval;
  final TrajectoryTimerFactory _timerFactory;

  TrajectoryRoot _root = const TrajectoryRoot();
  TrajectoryRoot get root => _root;

  bool loading = false;
  bool loadingEarlier = false;
  String? error;

  bool _visible = false;
  bool _disposed = false;
  Timer? _timer;
  Future<void>? _refreshing;
  Future<void>? _expanding;
  String? _expandedKey;
  int _expansionGeneration = 0;
  final Set<String> _attemptedEarlierBounds = <String>{};

  bool get visible => _visible;

  Future<void> start() async {
    if (_disposed) return;
    _visible = true;
    await refresh();
  }

  void setVisible(bool value) {
    if (_disposed) return;
    final changed = _visible != value;
    _visible = value;
    if (!value) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (changed) unawaited(refresh());
  }

  Future<void> refresh() {
    if (!_visible || _disposed) return Future<void>.value();
    final pending = _refreshing;
    if (pending != null) return pending;
    return _refreshing = _refreshNow();
  }

  Future<void> _refreshNow() async {
    loading = true;
    error = null;
    _notify();
    try {
      final page = await api.root(sessionId);
      if (_disposed) return;
      final previousEarlierCursor = _root.earlierCursor;
      final merged = foldTrajectoryPages(<Object?>[_root, page]);
      _root = _withEarlierCursor(
        merged,
        // A tail refresh does not consume older history. Preserve the current
        // unconsumed continuation even when its tail bound was attempted by a
        // previous older-page request; only loadEarlier marks newly loaded bounds.
        _usableEarlierCursor(previousEarlierCursor) ??
            _usableEarlierCursor(page.earlierCursor),
      );
      if (_visible && _expandedKey != null) {
        final pending = _expanding;
        if (pending != null) {
          await pending;
        } else {
          final worker = _workerForKey(_expandedKey!);
          if (worker != null) await expandWorker(worker);
        }
      }
    } catch (_) {
      if (!_disposed) error = 'We could not load this trajectory.';
    } finally {
      _refreshing = null;
      if (!_disposed) {
        loading = false;
        _notify();
        _schedule();
      }
    }
  }

  void _schedule() {
    if (!_visible || _disposed || _timer != null) return;
    _timer = _timerFactory(refreshInterval, () {
      _timer = null;
      if (_visible && !_disposed) unawaited(refresh());
    });
  }

  Future<void> loadEarlier() async {
    final before = _root.earlierCursor;
    if (!_visible ||
        _disposed ||
        before == null ||
        loadingEarlier ||
        _root.mainSteps.isEmpty && _root.workers.isEmpty) {
      return;
    }
    if (_attemptedEarlierBounds.contains(before)) {
      _root = _withEarlierCursor(_root, null);
      _notify();
      return;
    }
    loadingEarlier = true;
    error = null;
    _notify();
    try {
      final page = await api.root(sessionId, before: before);
      if (!_disposed) {
        _attemptedEarlierBounds.add(before);
        final merged = foldTrajectoryPages(<Object?>[_root, page]);
        _root = _withEarlierCursor(
          merged,
          _usableEarlierCursor(page.earlierCursor),
        );
      }
    } catch (_) {
      if (!_disposed) error = 'We could not load earlier trajectory events.';
    } finally {
      if (!_disposed) {
        loadingEarlier = false;
        _notify();
      }
    }
  }

  String? _usableEarlierCursor(String? cursor) {
    if (cursor == null || _attemptedEarlierBounds.contains(cursor)) {
      return null;
    }
    return cursor;
  }

  TrajectoryRoot _withEarlierCursor(TrajectoryRoot root, String? cursor) =>
      TrajectoryRoot(
        counts: root.counts,
        mainSteps: root.mainSteps,
        workers: root.workers,
        diagnostics: root.diagnostics,
        nextCursor: root.nextCursor,
        earlierCursor: cursor,
      );

  Future<void> expandWorker(TrajectoryWorker worker) {
    final childSessionId = worker.childSessionId;
    if (childSessionId == null || worker.isDeferred || _disposed) {
      return Future<void>.value();
    }
    final key = worker.logicalWorkerId ?? worker.childRunId ?? childSessionId;
    if (_expandedKey != key) {
      _expandedKey = key;
      _expansionGeneration += 1;
      _expanding = null;
    }
    final pending = _expanding;
    if (pending != null) return pending;
    return _expanding = _loadExpanded();
  }

  Future<void> _loadExpanded() async {
    final key = _expandedKey;
    if (key == null || _disposed) return;
    final generation = _expansionGeneration;
    final worker = _workerForKey(key);
    final childSessionId = worker?.childSessionId;
    if (worker == null || childSessionId == null || worker.isDeferred) return;
    try {
      final page = await api.workerEvents(
        childSessionId,
        after: worker.lastCursor,
      );
      if (_disposed ||
          generation != _expansionGeneration ||
          _expandedKey != key) {
        return;
      }
      _root = foldTrajectoryPages(<Object?>[
        _root,
        <String, dynamic>{
          'events': page.events,
          'childSessionId': childSessionId,
          'nextCursor': page.nextCursor,
        },
      ]);
      _notify();
    } catch (_) {
      if (!_disposed && generation == _expansionGeneration) {
        error = 'We could not load this worker activity.';
        _notify();
      }
    } finally {
      if (generation == _expansionGeneration) _expanding = null;
    }
  }

  TrajectoryWorker? _workerForKey(String key) {
    for (final worker in _root.workers) {
      if ((worker.logicalWorkerId ??
              worker.childRunId ??
              worker.childSessionId) ==
          key) {
        return worker;
      }
    }
    return null;
  }

  void collapseWorker() {
    _expandedKey = null;
    _expanding = null;
    _expansionGeneration += 1;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _visible = false;
    _timer?.cancel();
    _timer = null;
    _expansionGeneration += 1;
    super.dispose();
  }
}
