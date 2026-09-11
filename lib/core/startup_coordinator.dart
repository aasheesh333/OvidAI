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
  unsupported,
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
    this.ownerId,
  }) : updatedAt = updatedAt ?? DateTime.now();

  factory StartupItemStatus.queued(
    String id,
    StartupItemKind kind,
    String label, {
    int attempt = 0,
    String? ownerId,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.queued,
    attempt: attempt,
    ownerId: ownerId,
  );

  factory StartupItemStatus.running(
    String id,
    StartupItemKind kind,
    String label, {
    required int attempt,
    String? ownerId,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.running,
    attempt: attempt,
    ownerId: ownerId,
  );

  factory StartupItemStatus.ready(
    String id,
    StartupItemKind kind,
    String label, {
    int attempt = 1,
    String? ownerId,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.ready,
    attempt: attempt,
    ownerId: ownerId,
  );

  factory StartupItemStatus.needsSetup(
    String id,
    StartupItemKind kind,
    String label, {
    String? reason,
    int attempt = 1,
    String? ownerId,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.needsSetup,
    reason: reason,
    attempt: attempt,
    ownerId: ownerId,
  );

  factory StartupItemStatus.migrationRequired(
    String id,
    StartupItemKind kind,
    String label, {
    String? reason,
    int attempt = 1,
    String? ownerId,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.migrationRequired,
    reason: reason,
    attempt: attempt,
    ownerId: ownerId,
  );

  factory StartupItemStatus.unsupported(
    String id,
    StartupItemKind kind,
    String label, {
    String? reason,
    int attempt = 1,
    String? ownerId,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.unsupported,
    reason: reason,
    attempt: attempt,
    ownerId: ownerId,
  );

  factory StartupItemStatus.degraded(
    String id,
    StartupItemKind kind,
    String label, {
    String? reason,
    int attempt = 1,
    String? ownerId,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.degraded,
    reason: reason,
    attempt: attempt,
    ownerId: ownerId,
  );

  factory StartupItemStatus.failed(
    String id,
    StartupItemKind kind,
    String label, {
    String? reason,
    int attempt = 1,
    String? ownerId,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.failed,
    reason: reason,
    attempt: attempt,
    ownerId: ownerId,
  );

  factory StartupItemStatus.disabled(
    String id,
    StartupItemKind kind,
    String label, {
    String? reason,
    int attempt = 1,
    String? ownerId,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.disabled,
    reason: reason,
    attempt: attempt,
    ownerId: ownerId,
  );

  factory StartupItemStatus.skipped(
    String id,
    StartupItemKind kind,
    String label, {
    String? reason,
    int attempt = 0,
    String? ownerId,
  }) => StartupItemStatus(
    id: id,
    kind: kind,
    label: label,
    state: StartupItemState.skipped,
    reason: reason,
    attempt: attempt,
    ownerId: ownerId,
  );

  final String id;
  final StartupItemKind kind;
  final String label;
  final StartupItemState state;
  final String? reason;
  final DateTime updatedAt;
  final int attempt;

  /// Canonical plugin/MCP id this item owns, when it is a per-runtime item.
  /// Supplied by [StartupOwnedTask] implementations so the startup dashboard
  /// can deep-link `Open Plugins` by canonical id instead of display name.
  final String? ownerId;
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

/// Terminal status of one startup item, plus the canonical plugin/MCP owner
/// id when the item is owned. A null [ownerId] means the item is not a
/// per-plugin/MCP item (local state, marketplace, firebase, sandbox, …).
typedef StartupStatusSink =
    void Function(StartupItemStatus status, String? ownerId);

abstract interface class StartupTask {
  String get id;
  StartupItemKind get kind;
  String get label;
  Duration get timeout;
  StartupDisable? get onDisable;
  Future<StartupItemStatus> run();
}

/// Optional marker for startup tasks that own a canonical plugin/MCP id.
/// Implemented by [McpConnectTask] and available to plugin-owned tasks, so
/// the coordinator can attribute a terminal transition to that owner without
/// forcing every [StartupTask] to carry a new member.
abstract interface class StartupOwnedTask {
  String get ownerId;
}

class StartupCoordinator extends ChangeNotifier {
  StartupCoordinator({
    this._deadline = const Duration(seconds: 120),
    this.statusSink,
  });

  @visibleForTesting
  StartupCoordinator.forTest({required this._deadline, this.statusSink});

  static final StartupCoordinator I = StartupCoordinator();

  final Duration _deadline;
  final Map<String, StartupTask> _tasks = {};
  final List<StartupItemStatus> _items = [];
  final Set<String> _runningItemIds = {};

  /// Last terminal status emitted per item for the current run, so the sink
  /// only sees actually-changed transitions.
  final Map<String, StartupItemStatus> _emitted = {};

  /// Durable-status sink (Task 7). Set by production wiring; null in unit
  /// tests that do not need persistence.
  StartupStatusSink? statusSink;

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
    final seenIds = <String>{};
    for (final task in tasks) {
      if (!seenIds.add(task.id)) {
        throw ArgumentError('Duplicate startup task id: ${task.id}');
      }
    }
    final runToken = ++_runToken;
    _deadlineExceeded = false;
    _emitted.clear();
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
            final degraded = StartupItemStatus.degraded(
              item.id,
              item.kind,
              item.label,
              reason: 'Startup readiness deadline exceeded',
              attempt: item.attempt,
              ownerId: item.ownerId,
            );
            _items[i] = degraded;
            _emitStatus(degraded);
          } else if (item.state == StartupItemState.queued &&
              item.kind != StartupItemKind.localState) {
            final skipped = StartupItemStatus.skipped(
              item.id,
              item.kind,
              item.label,
              reason: 'Startup readiness deadline exceeded',
              attempt: item.attempt,
              ownerId: item.ownerId,
            );
            _items[i] = skipped;
            _emitStatus(skipped);
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
            ownerId: current.ownerId,
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
        reason: redactStartupError(error.toString()),
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
            : redactStartupError(result.reason!),
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
        reason: redactStartupError(error.toString()),
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
    final resolved = _withOwner(status);
    _items[index] = resolved;
    notifyListeners();
    _emitStatus(resolved);
  }

  /// Attributes a status to the canonical owner id carried by its
  /// [StartupOwnedTask], unless the status already names one.
  StartupItemStatus _withOwner(StartupItemStatus status) {
    if (status.ownerId != null) return status;
    final task = _tasks[status.id];
    if (task is! StartupOwnedTask) return status;
    final ownerId = (task as StartupOwnedTask).ownerId;
    if (ownerId.isEmpty) return status;
    return StartupItemStatus(
      id: status.id,
      kind: status.kind,
      label: status.label,
      state: status.state,
      reason: status.reason,
      updatedAt: status.updatedAt,
      attempt: status.attempt,
      ownerId: ownerId,
    );
  }

  /// Notifies the durable-status sink for an actually-changed terminal
  /// transition. Non-terminal states and repeated identical terminal states
  /// are never emitted; the canonical owner id is supplied by tasks that
  /// implement [StartupOwnedTask].
  void _emitStatus(StartupItemStatus status) {
    if (!status.state.isTerminal) return;
    final previous = _emitted[status.id];
    if (previous != null &&
        previous.state == status.state &&
        previous.reason == status.reason) {
      return;
    }
    _emitted[status.id] = status;
    final sink = statusSink;
    if (sink == null) return;
    var ownerId = status.ownerId;
    if (ownerId == null) {
      final task = _tasks[status.id];
      if (task is StartupOwnedTask) {
        ownerId = (task as StartupOwnedTask).ownerId;
      }
    }
    sink(status, ownerId);
  }

  StartupItemStatus _item(String id) =>
      _items.singleWhere((item) => item.id == id);
}

/// Conservative secret-safe scrubber for startup reasons and status details.
/// Shared by the coordinator (task reasons) and by producers that write
/// service status directly (e.g. the MCP startup connect).
String redactStartupError(String value) {
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
