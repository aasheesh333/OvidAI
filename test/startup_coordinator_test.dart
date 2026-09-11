import 'dart:async';

// fake_async is available through flutter_test and keeps deadline tests exact.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
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

  test('item timeout is reported as degraded and does not stop queue', () {
    fakeAsync((async) {
      final never = Completer<StartupItemStatus>();
      final coordinator = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 120),
      );

      var complete = false;
      coordinator
          .start([
            FakeStartupTask(
              'slow',
              kind: StartupItemKind.plugin,
              label: 'Slow plugin',
              timeout: const Duration(seconds: 30),
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
          ])
          .then((_) => complete = true);

      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();

      final slow = coordinator.snapshot.items.first;
      expect(slow.state, StartupItemState.degraded);
      expect(slow.reason, 'Timed out after 30s');
      expect(coordinator.snapshot.items.last.state, StartupItemState.ready);
      expect(complete, isTrue);
    });
  });

  test(
    'local safety work runs before external work and deadline returns exactly at 120 seconds',
    () {
      fakeAsync((async) {
        final blocked = Completer<StartupItemStatus>();
        final calls = <String>[];
        var localRuns = 0;
        var queuedExternalRuns = 0;
        final coordinator = StartupCoordinator.forTest(
          deadline: const Duration(seconds: 120),
        );

        var complete = false;
        coordinator
            .start([
              FakeStartupTask(
                'blocked',
                kind: StartupItemKind.mcp,
                label: 'Blocked MCP',
                timeout: const Duration(seconds: 300),
                run: () async {
                  calls.add('external');
                  return blocked.future;
                },
              ),
              FakeStartupTask(
                'migration',
                kind: StartupItemKind.localState,
                label: 'Migration',
                run: () async {
                  localRuns++;
                  calls.add('local');
                  return StartupItemStatus.ready(
                    'migration',
                    StartupItemKind.localState,
                    'Migration',
                  );
                },
              ),
              FakeStartupTask(
                'queued-external',
                kind: StartupItemKind.marketplace,
                label: 'Queued marketplace',
                run: () async {
                  queuedExternalRuns++;
                  return StartupItemStatus.ready(
                    'queued-external',
                    StartupItemKind.marketplace,
                    'Queued marketplace',
                  );
                },
              ),
            ])
            .then((_) => complete = true);

        async.flushMicrotasks();
        expect(calls, ['local', 'external']);
        async.elapse(const Duration(seconds: 119));
        async.elapse(const Duration(milliseconds: 999));
        expect(complete, isFalse);
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();

        expect(localRuns, 1);
        expect(queuedExternalRuns, 0);
        expect(complete, isTrue);
        expect(coordinator.snapshot.deadlineExceeded, isTrue);
        expect(coordinator.snapshot.readinessComplete, isTrue);
        expect(
          _status(coordinator, 'blocked').state,
          StartupItemState.degraded,
        );
        expect(
          _status(coordinator, 'blocked').reason,
          'Startup readiness deadline exceeded',
        );
        expect(_status(coordinator, 'migration').state, StartupItemState.ready);
        expect(
          _status(coordinator, 'queued-external').state,
          StartupItemState.skipped,
        );

        blocked.complete(
          StartupItemStatus.ready(
            'blocked',
            StartupItemKind.mcp,
            'Blocked MCP',
          ),
        );
        async.flushMicrotasks();
        expect(
          _status(coordinator, 'blocked').state,
          StartupItemState.degraded,
        );
      });
    },
  );

  test(
    'deadline terminalizes a hanging local task and its queued local task',
    () {
      fakeAsync((async) {
        final blocked = Completer<StartupItemStatus>();
        var queuedRuns = 0;
        final coordinator = StartupCoordinator.forTest(
          deadline: const Duration(seconds: 120),
        );

        var complete = false;
        coordinator
            .start([
              FakeStartupTask(
                'hanging-local',
                kind: StartupItemKind.localState,
                label: 'Hanging migration',
                timeout: const Duration(seconds: 300),
                run: () => blocked.future,
              ),
              FakeStartupTask(
                'queued-local',
                kind: StartupItemKind.localState,
                label: 'Queued migration',
                run: () async {
                  queuedRuns++;
                  return StartupItemStatus.ready(
                    'queued-local',
                    StartupItemKind.localState,
                    'Queued migration',
                  );
                },
              ),
            ])
            .then((_) => complete = true);

        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 120));
        async.flushMicrotasks();

        expect(complete, isTrue);
        expect(queuedRuns, 0);
        expect(coordinator.snapshot.readinessComplete, isTrue);
        expect(
          coordinator.snapshot.items.map((item) => item.state),
          everyElement(StartupItemState.degraded),
        );
      });
    },
  );

  test('global deadline wins when item timeout has the same boundary', () {
    fakeAsync((async) {
      final coordinator = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 120),
      );
      coordinator.start([
        FakeStartupTask(
          'same-boundary',
          kind: StartupItemKind.mcp,
          label: 'Same boundary',
          timeout: const Duration(seconds: 120),
          run: () => Completer<StartupItemStatus>().future,
        ),
      ]);

      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 120));
      async.flushMicrotasks();

      expect(coordinator.snapshot.deadlineExceeded, isTrue);
      expect(
        _status(coordinator, 'same-boundary').reason,
        'Startup readiness deadline exceeded',
      );
    });
  });

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

  test(
    'deadline keeps retry locked until the timed-out invocation settles',
    () {
      fakeAsync((async) {
        var runs = 0;
        final firstRun = Completer<StartupItemStatus>();
        final coordinator = StartupCoordinator.forTest(
          deadline: const Duration(seconds: 120),
        );
        coordinator.start([
          FakeStartupTask(
            'locked',
            kind: StartupItemKind.plugin,
            label: 'Locked plugin',
            timeout: const Duration(seconds: 300),
            run: () {
              runs++;
              if (runs == 1) return firstRun.future;
              return Future.value(
                StartupItemStatus.ready(
                  'locked',
                  StartupItemKind.plugin,
                  'Locked plugin',
                ),
              );
            },
          ),
        ]);

        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 120));
        async.flushMicrotasks();
        coordinator.retry('locked');
        async.flushMicrotasks();
        expect(runs, 1);

        firstRun.complete(
          StartupItemStatus.ready(
            'locked',
            StartupItemKind.plugin,
            'Locked plugin',
          ),
        );
        async.flushMicrotasks();
        expect(_status(coordinator, 'locked').state, StartupItemState.degraded);

        coordinator.retry('locked');
        async.flushMicrotasks();
        expect(runs, 2);
        expect(_status(coordinator, 'locked').state, StartupItemState.ready);
      });
    },
  );

  test(
    'item timeout keeps retry and disable locked until invocation settles',
    () {
      fakeAsync((async) {
        var runs = 0;
        var disables = 0;
        final firstRun = Completer<StartupItemStatus>();
        final coordinator = StartupCoordinator.forTest(
          deadline: const Duration(seconds: 120),
        );
        coordinator.start([
          FakeStartupTask(
            'timed-out',
            kind: StartupItemKind.plugin,
            label: 'Timed-out plugin',
            timeout: const Duration(seconds: 30),
            onDisable: () async => disables++,
            run: () {
              runs++;
              if (runs == 1) return firstRun.future;
              return Future.value(
                StartupItemStatus.ready(
                  'timed-out',
                  StartupItemKind.plugin,
                  'Timed-out plugin',
                ),
              );
            },
          ),
        ]);

        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(
          _status(coordinator, 'timed-out').state,
          StartupItemState.degraded,
        );

        coordinator.retry('timed-out');
        coordinator.disable('timed-out');
        async.flushMicrotasks();
        expect(runs, 1);
        expect(disables, 0);

        firstRun.complete(
          StartupItemStatus.ready(
            'timed-out',
            StartupItemKind.plugin,
            'Timed-out plugin',
          ),
        );
        async.flushMicrotasks();
        coordinator.retry('timed-out');
        async.flushMicrotasks();
        expect(runs, 2);
      });
    },
  );

  test('a second start does not duplicate an unresolved invocation', () {
    fakeAsync((async) {
      var runs = 0;
      final firstRun = Completer<StartupItemStatus>();
      final coordinator = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 120),
      );
      final task = FakeStartupTask(
        'shared',
        kind: StartupItemKind.plugin,
        label: 'Shared plugin',
        timeout: const Duration(seconds: 300),
        run: () {
          runs++;
          return firstRun.future;
        },
      );

      var firstComplete = false;
      coordinator.start([task]).then((_) => firstComplete = true);
      async.flushMicrotasks();
      coordinator.start([task]);
      async.flushMicrotasks();

      expect(runs, 1);
      expect(_status(coordinator, 'shared').state, StartupItemState.degraded);
      async.elapse(const Duration(seconds: 120));
      async.flushMicrotasks();
      expect(firstComplete, isTrue);
    });
  });

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

  test(
    'stale disable settles without overwriting new run and releases lock',
    () {
      fakeAsync((async) {
        var runs = 0;
        var disables = 0;
        final releaseDisable = Completer<void>();
        final coordinator = StartupCoordinator.forTest(
          deadline: const Duration(seconds: 120),
        );
        final task = FakeStartupTask(
          'plugin',
          kind: StartupItemKind.plugin,
          label: 'Plugin',
          onDisable: () async {
            disables++;
            if (disables == 1) await releaseDisable.future;
          },
          run: () async {
            runs++;
            return StartupItemStatus.failed(
              'plugin',
              StartupItemKind.plugin,
              'Plugin',
              reason: 'Still enabled',
            );
          },
        );

        coordinator.start([task]);
        async.flushMicrotasks();
        coordinator.disable('plugin');
        async.flushMicrotasks();
        expect(disables, 1);

        coordinator.start([task]);
        async.flushMicrotasks();
        expect(runs, 1);
        expect(_status(coordinator, 'plugin').state, StartupItemState.degraded);

        releaseDisable.complete();
        async.flushMicrotasks();
        expect(_status(coordinator, 'plugin').state, StartupItemState.degraded);

        coordinator.disable('plugin');
        async.flushMicrotasks();
        expect(disables, 2);
        expect(_status(coordinator, 'plugin').state, StartupItemState.disabled);
      });
    },
  );

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

  test(
    'task-returned reasons are capped and scrubbed for every state',
    () async {
      final coordinator = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 120),
      );
      final tail = List.filled(600, 'x').join();
      const states = [
        StartupItemState.ready,
        StartupItemState.needsSetup,
        StartupItemState.migrationRequired,
        StartupItemState.degraded,
        StartupItemState.failed,
        StartupItemState.disabled,
        StartupItemState.skipped,
      ];

      await coordinator.start([
        for (var i = 0; i < states.length; i++)
          FakeStartupTask(
            'returned-$i',
            kind: StartupItemKind.plugin,
            label: 'Returned $i',
            run: () async => StartupItemStatus(
              id: 'returned-$i',
              kind: StartupItemKind.plugin,
              label: 'Returned $i',
              state: states[i],
              reason:
                  'token=token-$i api_key=key-$i '
                  'Authorization: Bearer auth-$i password=pass-$i $tail',
            ),
          ),
      ]);

      for (final item in coordinator.snapshot.items) {
        expect(item.reason, contains('[REDACTED]'));
        expect(item.reason, isNot(contains('token-')));
        expect(item.reason, isNot(contains('key-')));
        expect(item.reason, isNot(contains('auth-')));
        expect(item.reason, isNot(contains('pass-')));
        expect(item.reason!.length, lessThanOrEqualTo(500));
      }
    },
  );

  test('task-returned null and ordinary reasons are preserved', () async {
    final coordinator = StartupCoordinator.forTest(
      deadline: const Duration(seconds: 120),
    );

    await coordinator.start([
      FakeStartupTask(
        'null-reason',
        kind: StartupItemKind.plugin,
        label: 'Null reason',
        run: () async => StartupItemStatus.ready(
          'null-reason',
          StartupItemKind.plugin,
          'Null reason',
        ),
      ),
      FakeStartupTask(
        'ordinary-reason',
        kind: StartupItemKind.plugin,
        label: 'Ordinary reason',
        run: () async => StartupItemStatus.degraded(
          'ordinary-reason',
          StartupItemKind.plugin,
          'Ordinary reason',
          reason: 'Cached catalog is available',
        ),
      ),
    ]);

    expect(_status(coordinator, 'null-reason').reason, isNull);
    expect(
      _status(coordinator, 'ordinary-reason').reason,
      'Cached catalog is available',
    );
  });

  test(
    'unsupported is a terminal state preserved by the coordinator',
    () async {
      final coordinator = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 1),
      );

      await coordinator.start([
        FakeStartupTask(
          'unsupported',
          kind: StartupItemKind.mcp,
          label: 'Unsupported MCP',
          run: () async => StartupItemStatus.unsupported(
            'unsupported',
            StartupItemKind.mcp,
            'Unsupported MCP',
            reason: 'SSE transport is not supported',
          ),
        ),
      ]);

      final status = _status(coordinator, 'unsupported');
      expect(status.state, StartupItemState.unsupported);
      expect(status.state.isTerminal, isTrue);
      expect(status.reason, 'SSE transport is not supported');
      expect(coordinator.snapshot.readinessComplete, isTrue);
    },
  );

  test('duplicate task ids are rejected', () async {
    final coordinator = StartupCoordinator.forTest(
      deadline: const Duration(seconds: 1),
    );
    StartupTask duplicate(String id) => FakeStartupTask(
      id,
      kind: StartupItemKind.plugin,
      label: 'Duplicate',
      run: () async =>
          StartupItemStatus.ready(id, StartupItemKind.plugin, 'Duplicate'),
    );

    await expectLater(
      coordinator.start([duplicate('dup'), duplicate('dup')]),
      throwsArgumentError,
    );
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

  test('timed-out source invocation remains observable until it settles', () {
    fakeAsync((async) {
      final source = Completer<StartupItemStatus>();
      final coordinator = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 120),
      );
      var settled = false;

      coordinator.start([
        FakeStartupTask(
          'slow-local',
          kind: StartupItemKind.localState,
          label: 'Slow local state',
          timeout: const Duration(seconds: 15),
          run: () => source.future,
        ),
      ]);
      async.flushMicrotasks();
      expect(coordinator.hasActiveInvocations, isTrue);
      coordinator.whenInvocationsSettled().then((_) => settled = true);

      async.elapse(const Duration(seconds: 15));
      async.flushMicrotasks();
      expect(coordinator.snapshot.readinessComplete, isTrue);
      expect(coordinator.hasActiveInvocations, isTrue);
      expect(settled, isFalse);

      source.complete(
        StartupItemStatus.ready(
          'slow-local',
          StartupItemKind.localState,
          'Slow local state',
        ),
      );
      async.flushMicrotasks();
      expect(coordinator.hasActiveInvocations, isFalse);
      expect(settled, isTrue);
    });
  });

  test('deadline-skipped owned items keep their canonical owner id', () {
    fakeAsync((async) {
      final never = Completer<StartupItemStatus>();
      final emitted = <String, String?>{};
      final coordinator = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 120),
        statusSink: (status, ownerId) => emitted[status.id] = ownerId,
      );

      coordinator.start([
        FakeStartupTask(
          'blocker',
          kind: StartupItemKind.localState,
          label: 'Blocker',
          timeout: const Duration(seconds: 300),
          run: () => never.future,
        ),
        _OwnedStartupTask(
          'mcp.connect:acme/server',
          ownerId: 'acme/server',
          kind: StartupItemKind.mcp,
          label: 'Server',
        ),
      ]);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 120));
      async.flushMicrotasks();

      expect(emitted['mcp.connect:acme/server'], 'acme/server');
    });
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

final class _OwnedStartupTask implements StartupTask, StartupOwnedTask {
  _OwnedStartupTask(
    this.id, {
    required this.ownerId,
    required this.kind,
    required this.label,
  });

  @override
  final String id;
  @override
  final String ownerId;
  @override
  final StartupItemKind kind;
  @override
  final String label;
  @override
  Duration get timeout => const Duration(seconds: 15);
  @override
  StartupDisable? get onDisable => null;

  @override
  Future<StartupItemStatus> run() async =>
      StartupItemStatus.ready(id, kind, label);
}
