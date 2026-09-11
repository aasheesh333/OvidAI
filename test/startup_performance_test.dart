import 'dart:async';
import 'dart:convert';

// fake_async keeps the 120-second readiness deadline exact and deterministic.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/startup_coordinator.dart';
import 'package:ovid_ai/core/startup_tasks.dart';
import 'package:ovid_ai/core/state.dart';

/// The spec §8 first-frame budget: under three seconds on the synthetic
/// worst-case local fixture. This test necessarily uses a wall clock because
/// the fixture drives real `dart:io` session decode / preference IO, which
/// `fake_async` cannot virtualize. It is disclosed as the one wall-clock
/// assertion in this file; every deadline assertion below is fake-time exact.
const _firstFrameBudget = Duration(seconds: 3);

const _optionalStages = <String>[
  'marketplace.refresh',
  'mcp.connect',
  'firebase.initialize',
  'github.initialize',
  'sandbox.selfHeal',
];

Map<String, Future<void> Function()> _hangingStages(Completer<void> never) => {
  for (final stage in _optionalStages) stage: () => never.future,
  'plugin.activate': () => never.future,
};

String _sessionJson(
  String id,
  List<String> messages, {
  String title = 'Saved chat',
  String? parentId,
}) => jsonEncode(
  ChatSession(
    id: id,
    title: title,
    model: 'saved-model',
    parentId: parentId,
    messages: [
      for (final message in messages) Message(role: 'user', content: message),
    ],
  ).toJson(),
);

/// A worst-case local fixture: many archived sessions plus one large active
/// transcript. This is the same shape the first-frame architecture was
/// designed to defer (spec §8).
Map<String, Object> _worstCaseFixture() => {
  'ovid_sessions': [
    'not-json',
    for (var i = 0; i < 100; i++)
      _sessionJson('archive-$i', ['archived-$i ${'y' * 2000}']),
    _sessionJson('active', [
      for (var i = 0; i < 5000; i++) 'history-$i ${'x' * 200}',
    ]),
  ],
  'ovid_active_session': 'active',
};

McpConnectTask _hangingMcpTask(String canonicalId, {int startupTimeoutS = 30}) =>
    McpConnectTask(
      canonicalId: canonicalId,
      label: 'Connect $canonicalId',
      resolveBudget: () => McpConnectTask.budgetFor(startupTimeoutS),
      connect: (_) => Completer<McpConnectOutcome>().future,
      isConnected: () => false,
      onDisable: () async {},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
  });

  tearDown(() async {
    McpService.I.httpClientForTest = null;
    await McpService.I.disconnectAll();
    AppState.resetTestInstance();
  });

  group('first frame performance', () {
    test(
      'first frame completes under the 3s budget with hanging optional tasks',
      () async {
        SharedPreferences.setMockInitialValues(_worstCaseFixture());
        final never = Completer<void>();
        final calls = <String>[];
        final app = AppState.createForTest(
          startupStageRecorder: calls.add,
          startupStageDelegates: _hangingStages(never),
        );

        final stopwatch = Stopwatch()..start();
        await app.initializeForFirstFrame().timeout(
          const Duration(seconds: 10),
        );
        stopwatch.stop();

        // Wall-clock (disclosed): the fixture performs real local IO.
        expect(stopwatch.elapsed, lessThan(_firstFrameBudget));
        // The deferred stages never ran, so first frame is independent of
        // hanging network/runtime work.
        expect(calls, ['local.firstFrame']);
        expect(never.isCompleted, isFalse);
        expect(app.activeSession!.id, 'active');
        // Only the active tail is hydrated on the first frame.
        expect(app.activeSession!.messages, hasLength(50));
      },
    );

    test(
      'first frame never starts a deferred stage even with a huge fixture',
      () async {
        SharedPreferences.setMockInitialValues(_worstCaseFixture());
        final calls = <String>[];
        final never = Completer<void>();
        final app = AppState.createForTest(
          startupStageRecorder: calls.add,
          startupStageDelegates: _hangingStages(never),
        );

        await app.initializeForFirstFrame().timeout(
          const Duration(seconds: 10),
        );

        for (final stage in _optionalStages) {
          expect(calls, isNot(contains(stage)), reason: stage);
        }
        expect(calls, isNot(contains('plugin.activate')));
        expect(calls, isNot(contains('mcp.connect')));
        expect(calls, isNot(contains('marketplace.refresh')));
      },
    );
  });

  group('120s readiness deadline (fake time)', () {
    test(
      'hanging marketplace and MCP reach terminal degraded at exactly 120s',
      () {
        fakeAsync((async) {
          final coordinator = StartupCoordinator.forTest(
            deadline: const Duration(seconds: 120),
          );
          var complete = false;

          coordinator
              .start([
                _AppLikeLocalTask('local.migrate'),
                // A marketplace item whose own timeout far exceeds the global
                // deadline, so it is genuinely still running at 120s.
                MarketplaceRefreshTask(
                  id: 'marketplace.refresh',
                  label: 'Refresh plugin marketplaces',
                  timeout: const Duration(seconds: 300),
                  repos: () => const ['slow/market'],
                  refresh: (_) => Completer<MarketplaceSyncOutcome>().future,
                ),
                _hangingMcpTask('acme/slow-mcp'),
                FirebaseStartupTask(
                  id: 'firebase.initialize',
                  label: 'Initialize optional services',
                  timeout: const Duration(seconds: 10),
                  initialize: () async => true,
                ),
              ])
              .then((_) => complete = true);

          async.flushMicrotasks();
          expect(_state(coordinator, 'local.migrate'), StartupItemState.ready);
          expect(
            _state(coordinator, 'marketplace.refresh'),
            StartupItemState.running,
          );

          async.elapse(const Duration(seconds: 119));
          async.elapse(const Duration(milliseconds: 999));
          expect(complete, isFalse, reason: 'not terminal before 120s');

          async.elapse(const Duration(milliseconds: 1));
          async.flushMicrotasks();

          expect(complete, isTrue, reason: 'terminal exactly at 120s');
          expect(coordinator.snapshot.deadlineExceeded, isTrue);
          expect(coordinator.snapshot.readinessComplete, isTrue);
          expect(
            _status(coordinator, 'marketplace.refresh').state,
            StartupItemState.degraded,
          );
          expect(
            _status(coordinator, 'marketplace.refresh').reason,
            'Startup readiness deadline exceeded',
          );
          // Queued network items after the deadline are skipped with Retry.
          expect(
            _status(coordinator, 'mcp.connect:acme/slow-mcp').state,
            StartupItemState.skipped,
          );
          expect(
            _status(coordinator, 'mcp.connect:acme/slow-mcp').reason,
            'Startup readiness deadline exceeded',
          );
          expect(
            _status(coordinator, 'firebase.initialize').state,
            StartupItemState.skipped,
          );
          expect(
            _status(coordinator, 'mcp.connect:acme/slow-mcp').ownerId,
            'acme/slow-mcp',
          );
        });
      },
    );

    test('local safety work is never skipped by the global deadline', () {
      fakeAsync((async) {
        final coordinator = StartupCoordinator.forTest(
          deadline: const Duration(seconds: 120),
        );
        var localRuns = 0;
        var queuedLocalRuns = 0;
        var complete = false;

        coordinator
            .start([
              _HangingLocalTask(() => localRuns++),
              _AppLikeLocalTask(
                'localSafety.migrate',
                onRun: () => queuedLocalRuns++,
              ),
              _hangingMcpTask('acme/slow-mcp'),
            ])
            .then((_) => complete = true);

        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 120));
        async.flushMicrotasks();

        expect(complete, isTrue);
        expect(localRuns, 1, reason: 'the running local item ran');
        expect(
          queuedLocalRuns,
          0,
          reason: 'queued local work is terminalized, not executed',
        );
        expect(
          _status(coordinator, 'localSafety.migrate').state,
          StartupItemState.degraded,
        );
        expect(coordinator.snapshot.readinessComplete, isTrue);
      });
    });
  });

  group('per-item isolation', () {
    test('a hanging item degrades at its own timeout and later items run', () {
      fakeAsync((async) {
        final coordinator = StartupCoordinator.forTest(
          deadline: const Duration(seconds: 120),
        );

        coordinator.start([
          _hangingMcpTask('acme/slow-mcp', startupTimeoutS: 30),
          MarketplaceRefreshTask(
            id: 'marketplace.refresh',
            label: 'Refresh plugin marketplaces',
            timeout: const Duration(seconds: 20),
            repos: () => const ['fast/market'],
            refresh: (_) async => MarketplaceSyncOutcome.ready,
          ),
        ]);

        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 31));
        async.flushMicrotasks();

        expect(
          _status(coordinator, 'mcp.connect:acme/slow-mcp').state,
          StartupItemState.degraded,
        );
        expect(
          _status(coordinator, 'mcp.connect:acme/slow-mcp').reason,
          'Timed out after 31s',
        );
        expect(
          _status(coordinator, 'marketplace.refresh').state,
          StartupItemState.ready,
          reason: 'one hanging item never blocks a later item',
        );
        expect(coordinator.snapshot.readinessComplete, isTrue);
        expect(coordinator.snapshot.deadlineExceeded, isFalse);
      });
    });
  });
}

StartupItemStatus _status(StartupCoordinator coordinator, String id) =>
    coordinator.snapshot.items.singleWhere((item) => item.id == id);

StartupItemState _state(StartupCoordinator coordinator, String id) =>
    _status(coordinator, id).state;

/// A local-state item that completes ready, matching the real
/// `localSafety.migrate` ordering contract.
class _AppLikeLocalTask implements StartupTask {
  _AppLikeLocalTask(this.id, {this.onRun});

  @override
  final String id;
  final void Function()? onRun;

  @override
  StartupItemKind get kind => StartupItemKind.localState;
  @override
  String get label => id;
  @override
  Duration get timeout => const Duration(seconds: 15);
  @override
  StartupDisable? get onDisable => null;

  @override
  Future<StartupItemStatus> run() async {
    onRun?.call();
    return StartupItemStatus.ready(id, kind, label);
  }
}

/// A local-state item that hangs past the global deadline.
class _HangingLocalTask implements StartupTask {
  _HangingLocalTask(this.onRun);

  @override
  String get id => 'local.hydrate';
  final void Function() onRun;

  @override
  StartupItemKind get kind => StartupItemKind.localState;
  @override
  String get label => 'Load local data';
  @override
  Duration get timeout => const Duration(seconds: 300);
  @override
  StartupDisable? get onDisable => null;

  @override
  Future<StartupItemStatus> run() async {
    onRun();
    return Completer<StartupItemStatus>().future;
  }
}
