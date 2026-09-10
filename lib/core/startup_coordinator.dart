import 'dart:async';

import 'package:flutter/foundation.dart';

enum StartupItemKind {
  localState,
  plugin,
  skillMount,
  sessionHook,
  marketplace,
  mcp,
  firebase,
  sandbox,
}

enum StartupItemState {
  queued,
  running,
  ready,
  needsSetup,
  migrationRequired,
  degraded,
  failed,
  disabled,
  skipped,
}

extension StartupItemStateTerminal on StartupItemState {
  bool get isTerminal =>
      this != StartupItemState.queued && this != StartupItemState.running;
}

class StartupItemStatus {
  StartupItemStatus({
    required this.id,
    required this.kind,
    required this.label,
    required this.state,
    this.reason,
    DateTime? updatedAt,
    this.attempt = 0,
  }) : updatedAt = updatedAt ?? DateTime.now();

  factory StartupItemStatus.queued(
    String id,
    StartupItemKind kind,
    String label, {
    int attempt = 0,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.queued,
    attempt: attempt,
  );

  factory StartupItemStatus.running(
    String id,
    StartupItemKind kind,
    String label, {
    required int attempt,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.running,
    attempt: attempt,
  );

  factory StartupItemStatus.ready(
    String id,
    StartupItemKind kind,
    String label, {
    int attempt = 1,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.ready,
    attempt: attempt,
  );

  factory StartupItemStatus.needsSetup(
    String id,
    StartupItemKind kind,
    String label, {
    String? reason,
    int attempt = 1,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.needsSetup,
    reason: reason,
    attempt: attempt,
  );

  factory StartupItemStatus.migrationRequired(
    String id,
    StartupItemKind kind,
    String label, {
    String? reason,
    int attempt = 1,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.migrationRequired,
    reason: reason,
    attempt: attempt,
  );

  factory StartupItemStatus.degraded(
    String id,
    StartupItemKind kind,
    String label, {
    String? reason,
    int attempt = 1,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.degraded,
    reason: reason,
    attempt: attempt,
  );

  factory StartupItemStatus.failed(
    String id,
    StartupItemKind kind,
    String label, {
    String? reason,
    int attempt = 1,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.failed,
    reason: reason,
    attempt: attempt,
  );

  factory StartupItemStatus.disabled(
    String id,
    StartupItemKind kind,
    String label, {
    String? reason,
    int attempt = 1,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.disabled,
    reason: reason,
    attempt: attempt,
  );

  factory StartupItemStatus.skipped(
    String id,
    StartupItemKind kind,
    String label, {
    String? reason,
    int attempt = 0,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.skipped,
    reason: reason,
    attempt: attempt,
  );

  final String id;
  final StartupItemKind kind;
  final String label;
  final StartupItemState state;
  final String? reason;
  final DateTime updatedAt;
  final int attempt;
}

class StartupSnapshot {
  StartupSnapshot({
    required this.shellReady,
    required this.readinessComplete,
    required this.deadlineExceeded,
    required this.completed,
    required this.total,
    required List<StartupItemStatus> items,
  }) : items = List<StartupItemStatus>.unmodifiable(items);

  final bool shellReady;
  final bool readinessComplete;
  final bool deadlineExceeded;
  final int completed;
  final int total;
  final List<StartupItemStatus> items;
}

typedef StartupDisable = Future<void> Function();

abstract interface class StartupTask {
  String get id;
  StartupItemKind get kind;
  String get label;
  Duration get timeout;
  StartupDisable? get onDisable;
  Future<StartupItemStatus> run();
}

class StartupCoordinator extends ChangeNotifier {
  StartupCoordinator({this._deadline = const Duration(seconds: 120)});

  @visibleForTesting
  StartupCoordinator.forTest({required this._deadline});

  static final StartupCoordinator I = StartupCoordinator();

  final Duration _deadline;
  final Map<String, StartupTask> _tasks = {};
  final List<StartupItemStatus> _items = [];
  final Set<String> _runningItemIds = {};
  Completer<void>? _invocationsSettled;
  var _runToken = 0;
  var _deadlineExceeded = false;

  bool get hasActiveInvocations => _runningItemIds.isNotEmpty;

  Future<void> whenInvocationsSettled() =>
      _invocationsSettled?.future ?? Future<void>.value();

  StartupSnapshot get snapshot => StartupSnapshot(
    shellReady: true,
    readinessComplete: _items.every((item) => item.state.isTerminal),
    deadlineExceeded: _deadlineExceeded,
    completed: _items.where((item) => item.state.isTerminal).length,
    total: _items.length,
    items: _items,
  );

  Future<void> start(List<StartupTask> tasks) async {
    final runToken = ++_runToken;
    _deadlineExceeded = false;
    final orderedTasks = [
      ...tasks.where((task) => task.kind == StartupItemKind.localState),
      ...tasks.where((task) => task.kind != StartupItemKind.localState),
    ];
    _tasks
      ..clear()
      ..addEntries(tasks.map((task) => MapEntry(task.id, task)));
    _items
      ..clear()
      ..addAll(
        orderedTasks.map(
          (task) => StartupItemStatus.queued(task.id, task.kind, task.label),
        ),
      );
    notifyListeners();

    final deadlineReached = Completer<void>();
    final deadlineTimer = Timer(_deadline, () {
      if (runToken == _runToken) {
        _deadlineExceeded = true;
        for (var i = 0; i < _items.length; i++) {
          final item = _items[i];
          if (item.state == StartupItemState.running ||
              (item.state == StartupItemState.queued &&
                  item.kind == StartupItemKind.localState)) {
            _items[i] = StartupItemStatus.degraded(
              item.id,
              item.kind,
              item.label,
              reason: 'Startup readiness deadline exceeded',
              attempt: item.attempt,
            );
          } else if (item.state == StartupItemState.queued &&
              item.kind != StartupItemKind.localState) {
            _items[i] = StartupItemStatus.skipped(
              item.id,
              item.kind,
              item.label,
              reason: 'Startup readiness deadline exceeded',
              attempt: item.attempt,
            );
          }
        }
        notifyListeners();
      }
      deadlineReached.complete();
    });

    for (final task in orderedTasks) {
      if (runToken != _runToken) {
        deadlineTimer.cancel();
        return;
      }
      final current = _item(task.id);
      if (current.state.isTerminal) continue;
      if (_runningItemIds.contains(task.id)) {
        _replace(
          StartupItemStatus.degraded(
            task.id,
            task.kind,
            task.label,
            reason: 'Startup task is still running',
            attempt: current.attempt,
          ),
        );
        continue;
      }

      _replace(
        StartupItemStatus.running(task.id, task.kind, task.label, attempt: 1),
      );
      final run = _invoke(task, attempt: 1);
      final StartupItemStatus? result;
      if (_deadlineExceeded) {
        result = await run;
      } else {
        result = await Future.any<StartupItemStatus?>([
          run,
          deadlineReached.future.then<StartupItemStatus?>((_) => null),
        ]);
      }
      if (result == null) {
        deadlineTimer.cancel();
        return;
      }
      if (runToken == _runToken) {
        _replace(result);
      }
    }
    deadlineTimer.cancel();
  }

  Future<void> retry(String itemId) async {
    final task = _tasks[itemId];
    if (task == null || _runningItemIds.contains(itemId)) return;
    final current = _item(itemId);
    if (!current.state.isTerminal) return;

    final attempt = current.attempt + 1;
    final runToken = _runToken;
    _replace(
      StartupItemStatus.running(
        task.id,
        task.kind,
        task.label,
        attempt: attempt,
      ),
    );
    final result = await _invoke(task, attempt: attempt);
    if (runToken == _runToken) {
      _replace(result);
    }
  }

  Future<void> disable(String itemId) async {
    final task = _tasks[itemId];
    if (task == null ||
        task.onDisable == null ||
        (task.kind != StartupItemKind.plugin &&
            task.kind != StartupItemKind.mcp) ||
        _runningItemIds.contains(itemId)) {
      return;
    }
    final current = _item(itemId);
    if (!current.state.isTerminal ||
        current.state == StartupItemState.disabled) {
      return;
    }

    final runToken = _runToken;
    _markInvocationStarted(itemId);
    StartupItemStatus? result;
    try {
      await task.onDisable!();
      result = StartupItemStatus.disabled(
        task.id,
        task.kind,
        task.label,
        attempt: current.attempt,
      );
    } catch (error) {
      result = StartupItemStatus.failed(
        task.id,
        task.kind,
        task.label,
        reason: _redactStartupError(error.toString()),
        attempt: current.attempt,
      );
    } finally {
      final ownedLock = _markInvocationSettled(itemId);
      if (runToken == _runToken && ownedLock && result != null) {
        _replace(result);
      }
    }
  }

  Future<StartupItemStatus> _runOne(
    StartupTask task, {
    required int attempt,
    required Future<StartupItemStatus> invocation,
  }) async {
    try {
      final result = await invocation.timeout(task.timeout);
      if (!result.state.isTerminal) {
        return StartupItemStatus.failed(
          task.id,
          task.kind,
          task.label,
          reason: 'Startup task returned a non-terminal state',
          attempt: attempt,
        );
      }
      return StartupItemStatus(
        id: task.id,
        kind: task.kind,
        label: task.label,
        state: result.state,
        reason: result.reason == null
            ? null
            : _redactStartupError(result.reason!),
        attempt: attempt,
      );
    } on TimeoutException {
      return StartupItemStatus.degraded(
        task.id,
        task.kind,
        task.label,
        reason: 'Timed out after ${_formatDuration(task.timeout)}',
        attempt: attempt,
      );
    } catch (error) {
      return StartupItemStatus.failed(
        task.id,
        task.kind,
        task.label,
        reason: _redactStartupError(error.toString()),
        attempt: attempt,
      );
    }
  }

  Future<StartupItemStatus> _invoke(StartupTask task, {required int attempt}) {
    _markInvocationStarted(task.id);
    final invocation = Future<StartupItemStatus>.sync(task.run);
    unawaited(
      invocation.then<void>(
        (_) => _markInvocationSettled(task.id),
        onError: (Object _, StackTrace _) {
          _markInvocationSettled(task.id);
        },
      ),
    );
    return _runOne(task, attempt: attempt, invocation: invocation);
  }

  void _markInvocationStarted(String itemId) {
    if (_runningItemIds.isEmpty) {
      _invocationsSettled = Completer<void>();
    }
    _runningItemIds.add(itemId);
  }

  bool _markInvocationSettled(String itemId) {
    final removed = _runningItemIds.remove(itemId);
    if (removed && _runningItemIds.isEmpty) {
      _invocationsSettled?.complete();
      _invocationsSettled = null;
    }
    return removed;
  }

  void _replace(StartupItemStatus status) {
    final index = _items.indexWhere((item) => item.id == status.id);
    if (index == -1) return;
    _items[index] = status;
    notifyListeners();
  }

  StartupItemStatus _item(String id) =>
      _items.singleWhere((item) => item.id == id);
}

String _redactStartupError(String value) {
  var scrubbed = value
      .replaceAllMapped(
        RegExp(
          r'(["\x27]?(?:authorization|api[_-]?key|token|password|secret)["\x27]?\s*:\s*["\x27])[^"\x27]*',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}[REDACTED]',
      )
      .replaceAllMapped(
        RegExp(
          r'(authorization\s*[:=]\s*)(?:bearer\s+)?[^\s,;]+',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}[REDACTED]',
      )
      .replaceAllMapped(
        RegExp(
          r'((?:api[_-]?key|token|password|secret)\s*[:=]\s*)[^\s,;]+',
          caseSensitive: false,
        ),
        (match) => '${match.group(1)}[REDACTED]',
      )
      .replaceAll(
        RegExp(r'bearer\s+[a-z0-9._~+/=-]+', caseSensitive: false),
        'Bearer [REDACTED]',
      )
      .replaceAll(RegExp(r'\bsk-[A-Za-z0-9_-]+\b'), '[REDACTED]');
  const maxLength = 500;
  if (scrubbed.length > maxLength) {
    scrubbed = '${scrubbed.substring(0, maxLength - 3)}...';
  }
  return scrubbed;
}

String _formatDuration(Duration duration) {
  if (duration.inMilliseconds % 1000 == 0) {
    return '${duration.inSeconds}s';
  }
  return '${duration.inMilliseconds}ms';
}
