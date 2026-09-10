import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/startup_coordinator.dart';

void main() {
  test('startup tasks run one-by-one and continue after a failure', () async {
    final calls = <String>[];
    final coordinator = StartupCoordinator.forTest(
      deadline: const Duration(seconds: 120),
    );

    await coordinator.start([
      FakeStartupTask(
        'a',
        kind: StartupItemKind.localState,
        label: 'A',
        run: () async {
          calls.add('a:start');
          await Future<void>.delayed(Duration.zero);
          calls.add('a:end');
          return StartupItemStatus.ready('a', StartupItemKind.localState, 'A');
        },
      ),
      FakeStartupTask(
        'b',
        kind: StartupItemKind.plugin,
        label: 'B',
        run: () async {
          calls.add('b:start');
          throw StateError('broken');
        },
      ),
      FakeStartupTask(
        'c',
        kind: StartupItemKind.plugin,
        label: 'C',
        run: () async {
          calls.add('c:start');
          return StartupItemStatus.ready('c', StartupItemKind.plugin, 'C');
        },
      ),
    ]);

    expect(calls, ['a:start', 'a:end', 'b:start', 'c:start']);
    expect(
      coordinator.snapshot.items.singleWhere((item) => item.id == 'b').state,
      StartupItemState.failed,
    );
    expect(coordinator.snapshot.readinessComplete, isTrue);
  });

  test(
    'item timeout is reported as degraded and does not stop queue',
    () async {
      final never = Completer<StartupItemStatus>();
      final coordinator = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 1),
      );

      await coordinator.start([
        FakeStartupTask(
          'slow',
          kind: StartupItemKind.plugin,
          label: 'Slow plugin',
          timeout: const Duration(milliseconds: 10),
          run: () => never.future,
        ),
        FakeStartupTask(
          'next',
          kind: StartupItemKind.plugin,
          label: 'Next plugin',
          run: () async => StartupItemStatus.ready(
            'next',
            StartupItemKind.plugin,
            'Next plugin',
          ),
        ),
      ]);

      final slow = coordinator.snapshot.items.first;
      expect(slow.state, StartupItemState.degraded);
      expect(slow.reason, 'Timed out after 10ms');
      expect(coordinator.snapshot.items.last.state, StartupItemState.ready);
    },
  );

  test(
    'deadline degrades running task, skips external queue, and runs local safety work',
    () async {
      final blocked = Completer<StartupItemStatus>();
      var skippedRuns = 0;
      var localRuns = 0;
      final coordinator = StartupCoordinator.forTest(
        deadline: const Duration(milliseconds: 20),
      );

      await coordinator.start([
        FakeStartupTask(
          'blocked',
          kind: StartupItemKind.mcp,
          label: 'Blocked MCP',
          timeout: const Duration(seconds: 1),
          run: () => blocked.future,
        ),
        FakeStartupTask(
          'external',
          kind: StartupItemKind.marketplace,
          label: 'Marketplace',
          run: () async {
            skippedRuns++;
            return StartupItemStatus.ready(
              'external',
              StartupItemKind.marketplace,
              'Marketplace',
            );
          },
        ),
        FakeStartupTask(
          'migration',
          kind: StartupItemKind.localState,
          label: 'Migration',
          run: () async {
            localRuns++;
            return StartupItemStatus.ready(
              'migration',
              StartupItemKind.localState,
              'Migration',
            );
          },
        ),
      ]);

      expect(skippedRuns, 0);
      expect(localRuns, 1);
      expect(coordinator.snapshot.deadlineExceeded, isTrue);
      expect(coordinator.snapshot.readinessComplete, isTrue);
      expect(_status(coordinator, 'blocked').state, StartupItemState.degraded);
      expect(
        _status(coordinator, 'blocked').reason,
        'Startup readiness deadline exceeded',
      );
      expect(_status(coordinator, 'external').state, StartupItemState.skipped);
      expect(_status(coordinator, 'migration').state, StartupItemState.ready);

      blocked.complete(
        StartupItemStatus.ready('blocked', StartupItemKind.mcp, 'Blocked MCP'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(_status(coordinator, 'blocked').state, StartupItemState.degraded);
    },
  );

  test(
    'retry reruns only a terminal item and rejects a duplicate retry',
    () async {
      var firstRuns = 0;
      var secondRuns = 0;
      final retryStarted = Completer<void>();
      final releaseRetry = Completer<void>();
      final coordinator = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 1),
      );

      await coordinator.start([
        FakeStartupTask(
          'first',
          kind: StartupItemKind.plugin,
          label: 'First',
          run: () async {
            firstRuns++;
            if (firstRuns == 1) throw StateError('initial failure');
            retryStarted.complete();
            await releaseRetry.future;
            return StartupItemStatus.ready(
              'first',
              StartupItemKind.plugin,
              'First',
            );
          },
        ),
        FakeStartupTask(
          'second',
          kind: StartupItemKind.plugin,
          label: 'Second',
          run: () async {
            secondRuns++;
            return StartupItemStatus.ready(
              'second',
              StartupItemKind.plugin,
              'Second',
            );
          },
        ),
      ]);

      final retry = coordinator.retry('first');
      await retryStarted.future;
      final duplicate = coordinator.retry('first');
      await duplicate;
      expect(firstRuns, 2);
      expect(secondRuns, 1);
      expect(_status(coordinator, 'first').state, StartupItemState.running);

      releaseRetry.complete();
      await retry;
      expect(_status(coordinator, 'first').state, StartupItemState.ready);
      expect(_status(coordinator, 'first').attempt, 2);
    },
  );

  test('disable invokes only supplied plugin or MCP callback once', () async {
    var pluginDisables = 0;
    var localDisables = 0;
    final coordinator = StartupCoordinator.forTest(
      deadline: const Duration(seconds: 1),
    );

    await coordinator.start([
      FakeStartupTask(
        'plugin',
        kind: StartupItemKind.plugin,
        label: 'Plugin',
        onDisable: () async => pluginDisables++,
        run: () async => StartupItemStatus.failed(
          'plugin',
          StartupItemKind.plugin,
          'Plugin',
          reason: 'Unavailable',
        ),
      ),
      FakeStartupTask(
        'local',
        kind: StartupItemKind.localState,
        label: 'Local',
        onDisable: () async => localDisables++,
        run: () async => StartupItemStatus.failed(
          'local',
          StartupItemKind.localState,
          'Local',
        ),
      ),
      FakeStartupTask(
        'mcp-without-callback',
        kind: StartupItemKind.mcp,
        label: 'MCP',
        run: () async => StartupItemStatus.failed(
          'mcp-without-callback',
          StartupItemKind.mcp,
          'MCP',
        ),
      ),
    ]);

    await coordinator.disable('plugin');
    await coordinator.disable('plugin');
    await coordinator.disable('local');
    await coordinator.disable('mcp-without-callback');

    expect(pluginDisables, 1);
    expect(localDisables, 0);
    expect(_status(coordinator, 'plugin').state, StartupItemState.disabled);
    expect(_status(coordinator, 'local').state, StartupItemState.failed);
    expect(
      _status(coordinator, 'mcp-without-callback').state,
      StartupItemState.failed,
    );
  });

  test('failure reasons are capped and scrub common secret forms', () async {
    final coordinator = StartupCoordinator.forTest(
      deadline: const Duration(seconds: 1),
    );
    final longTail = List.filled(600, 'x').join();

    await coordinator.start([
      FakeStartupTask(
        'secret',
        kind: StartupItemKind.plugin,
        label: 'Secret plugin',
        run: () async {
          throw StateError(
            'authorization: Bearer visible-token '
            'api_key=sk-visible password=hunter2 '
            '{"token":"json-visible"} $longTail',
          );
        },
      ),
    ]);

    final reason = _status(coordinator, 'secret').reason!;
    expect(reason, isNot(contains('visible-token')));
    expect(reason, isNot(contains('sk-visible')));
    expect(reason, isNot(contains('hunter2')));
    expect(reason, isNot(contains('json-visible')));
    expect(reason, contains('[REDACTED]'));
    expect(reason.length, lessThanOrEqualTo(500));
  });

  test('a task cannot leave readiness in a non-terminal state', () async {
    final coordinator = StartupCoordinator.forTest(
      deadline: const Duration(seconds: 1),
    );

    await coordinator.start([
      FakeStartupTask(
        'invalid',
        kind: StartupItemKind.plugin,
        label: 'Invalid plugin',
        run: () async => StartupItemStatus.running(
          'invalid',
          StartupItemKind.plugin,
          'Invalid plugin',
          attempt: 1,
        ),
      ),
    ]);

    expect(_status(coordinator, 'invalid').state, StartupItemState.failed);
    expect(coordinator.snapshot.readinessComplete, isTrue);
  });
}

StartupItemStatus _status(StartupCoordinator coordinator, String id) =>
    coordinator.snapshot.items.singleWhere((item) => item.id == id);

final class FakeStartupTask implements StartupTask {
  // Named `run` keeps test task declarations aligned with StartupTask.run().
  FakeStartupTask(
    this.id, {
    required this.kind,
    required this.label,
    required Future<StartupItemStatus> Function() run,
    this.timeout = const Duration(seconds: 15),
    this.onDisable,
    // ignore: prefer_initializing_formals
  }) : _run = run;

  @override
  final String id;

  @override
  final StartupItemKind kind;

  @override
  final String label;

  @override
  final Duration timeout;

  @override
  final StartupDisable? onDisable;

  final Future<StartupItemStatus> Function() _run;

  @override
  Future<StartupItemStatus> run() => _run();
}
