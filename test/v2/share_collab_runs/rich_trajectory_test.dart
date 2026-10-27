import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/trajectory_client.dart';
import 'package:ovid_ai/core/cloud/trajectory_projection.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/trajectory_screen.dart';
import 'package:ovid_ai/ui/v2/app/v2_run_routes.dart';
import 'package:ovid_ai/ui/v2/runs/run_trajectory_page.dart';
import 'package:ovid_ai/ui/v2/runs/subagent_page.dart';

import '../../support/fake_cloud_events.dart';
import '_harness.dart';

TrajectoryRoot _root() => foldTrajectoryPages([
  <String, dynamic>{
    'counts': <String, dynamic>{
      'total': 2,
      'running': 1,
      'awaiting_next_user_task': 1,
      'completed': 0,
      'failed': 0,
      'cancelled': 0,
      'timeout': 0,
    },
    'steps': <Map<String, dynamic>>[
      <String, dynamic>{
        'cursor': 'main-1',
        'sessionId': 'session-1',
        'runId': 'root-1',
        'seq': '1',
        'actorKind': 'main',
        'kind': 'tool',
        'type': 'tool_completed',
        'ts': '2026-10-24T12:00:00.000Z',
        'prompt': 'Read the canonical event',
        'output': 'Main tool output',
        'files': null,
        'diffs': null,
        'artifacts': null,
        'requestedModel': null,
        'providerModel': null,
        'usage': <String, dynamic>{
          'inputTokens': null,
          'outputTokens': null,
          'cacheReadTokens': null,
          'cacheWriteTokens': null,
          'costUsd': null,
        },
      },
    ],
    'workers': <Map<String, dynamic>>[
      <String, dynamic>{
        'logicalWorkerId': 'deferred-worker',
        'deferredRequestId': 'deferred-1',
        'agentType': 'researcher',
        'status': 'awaiting_next_user_task',
        'requestedAt': '2026-10-24T12:00:00.000Z',
        'deferredAt': '2026-10-24T12:00:01.000Z',
        'startKnown': false,
        'childSessionId': null,
        'childRunId': null,
        'logAvailable': false,
      },
      <String, dynamic>{
        'logicalWorkerId': 'worker-1',
        'childSessionId': 'child-1',
        'childRunId': 'child-run-1',
        'attemptId': 'attempt-1',
        'rootTaskRunId': 'root-1',
        'agentType': 'builder',
        'status': 'running',
        'requestedAt': '2026-10-24T12:01:00.000Z',
        'admittedAt': '2026-10-24T12:02:00.000Z',
        'startedAt': '2026-10-24T12:03:00.000Z',
        'startKnown': true,
        'lastActivity': 'read_file',
        'lastActivityAt': '2026-10-24T12:04:00.000Z',
        'lastCursor': 'child-4',
        'steps': <Map<String, dynamic>>[
          <String, dynamic>{
            'cursor': 'child-step-4',
            'sessionId': 'child-1',
            'runId': 'child-run-1',
            'seq': '4',
            'actorKind': 'worker',
            'kind': 'tool',
            'type': 'tool_completed',
            'ts': '2026-10-24T12:04:00.000Z',
            'output': 'Child tool output',
          },
        ],
        'logAvailable': false,
      },
    ],
  },
  <String, dynamic>{
    'events': <Map<String, dynamic>>[
      <String, dynamic>{
        'sessionId': 'session-1',
        'seq': '5',
        'type': 'subagent_compacted',
        'ts': '2026-10-24T12:05:00.000Z',
        'payload': <String, dynamic>{
          'type': 'subagent_compacted',
          'sessionId': 'session-1',
          'workerId': 'worker-1',
          'runId': 'attempt-1',
          'compactionId': 'compaction-worker-1',
          'checkpointId': 'checkpoint-worker-1',
          'ts': '2026-10-24T12:05:00.000Z',
          'model': 'fixture-large',
          'contextLimit': 128000,
          'beforeTokens': 102400,
          'afterTokens': 24000,
          'usageSource': 'measured',
          'continuation': 'continuing_existing_task',
          'thoughts': 'private thought text must not appear',
        },
      },
    ],
  },
]);

class _RouteApi extends TrajectoryApi {
  _RouteApi()
    : super(
        CloudRestClient(
          headers: CloudHeaders.forTest(),
          restBase: 'http://test',
        ),
      );

  final List<String?> rawAfter = <String?>[];
  int rootCalls = 0;
  int childCalls = 0;

  @override
  Future<TrajectoryRoot> root(String sessionId, {String? before}) async {
    rootCalls += 1;
    return _root();
  }

  @override
  Future<TrajectoryEventPage> workerEvents(
    String childSessionId, {
    String? after,
  }) async {
    childCalls += 1;
    return const TrajectoryEventPage(events: <Map<String, dynamic>>[]);
  }

  @override
  Future<RawTrajectoryPage> showRaw(String sessionId, {String? after}) async {
    rawAfter.add(after);
    return RawTrajectoryPage.fromJson(<String, dynamic>{
      'items': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'route-raw',
          'value': <String, dynamic>{
            'type': 'compaction_completed',
            'actorKind': 'main',
            'compactionId': 'compaction-main-1',
          },
        },
      ],
      'nextCursor': null,
    });
  }
}

class _DiagnosticsOnlyApi extends TrajectoryApi {
  _DiagnosticsOnlyApi()
    : super(
        CloudRestClient(
          headers: CloudHeaders.forTest(),
          restBase: 'http://test',
        ),
      );

  final List<String?> before = <String?>[];

  @override
  Future<TrajectoryRoot> root(String sessionId, {String? before}) async {
    this.before.add(before);
    return foldTrajectoryPages(<Object?>[
      <String, dynamic>{
        'earlierCursor': 'root-before-1',
        'events': <Map<String, dynamic>>[
          <String, dynamic>{
            'sessionId': 'session-1',
            'seq': '40',
            'type': 'compaction_completed',
            'ts': '2026-10-24T12:10:00.000Z',
            'payload': <String, dynamic>{
              'type': 'compaction_completed',
              'actorKind': 'main',
              'sessionId': 'session-1',
              'runId': 'root-1',
              'compactionId': 'compaction-main-1',
              'checkpointId': 'checkpoint-main-1',
              'ts': '2026-10-24T12:10:00.000Z',
              'model': 'fixture-medium',
              'contextLimit': 32000,
              'beforeTokens': 25600,
              'afterTokens': 6000,
              'usageSource': 'deterministic_fallback',
              'continuation': 'continuing_existing_task',
            },
          },
        ],
      },
    ]);
  }
}

void main() {
  testWidgets(
    'live canonical route loads rich data and fetches raw only on action',
    (tester) async {
      final api = _RouteApi();
      await pumpAt(
        tester,
        CanonicalTrajectoryPage(
          api: api,
          sessionId: 'session-1',
          title: 'Canonical run',
        ),
        size: const Size(900, 1200),
      );

      expect(find.text('Main tool output'), findsOneWidget);
      expect(find.text('Stop'), findsNothing);
      expect(find.text('Resume'), findsNothing);
      expect(find.text('Continue'), findsNothing);
      expect(api.rawAfter, isEmpty);

      await tester.tap(find.text('Show raw'));
      await tester.pump();
      await tester.pump();
      expect(api.rawAfter, <String?>[null]);
      expect(
        find.byKey(const ValueKey<String>('trajectory-raw-content')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'rich trajectory shows main steps counts and truthful worker states',
    (tester) async {
      String? expanded;
      String? opened;
      await pumpAt(
        tester,
        RunTrajectoryPage(
          data: V2RunTrajectoryPageData(
            title: 'Canonical run',
            runLabel: '',
            trajectory: _root(),
          ),
          onExpandWorker: (worker) => expanded = worker.logicalWorkerId,
          onOpenSubagent: (id) => opened = id,
        ),
        size: const Size(900, 1200),
      );

      final semantics = tester.ensureSemantics();
      expect(find.text('Main steps'), findsOneWidget);
      expect(find.text('Main tool output'), findsOneWidget);
      expect(find.text('Main · Tool'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          RegExp('Main step 1 of 1.*Main tool output.*Main · Tool'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('2 total'), findsOneWidget);
      expect(find.textContaining('1 running'), findsOneWidget);
      expect(find.textContaining('1 awaiting next user task'), findsOneWidget);
      expect(find.text('Awaiting next user task'), findsOneWidget);
      expect(find.text('private thought text must not appear'), findsNothing);
      expect(find.text('Stop'), findsNothing);
      expect(find.text('Resume'), findsNothing);
      expect(find.text('Continue'), findsNothing);
      expect(find.text('Open transcript'), findsNothing);
      expect(find.text('View log'), findsNothing);

      await tester.tap(find.text('Main tool output'));
      await tester.pump();
      expect(find.text('Files'), findsOneWidget);
      expect(find.text('Diffs'), findsOneWidget);
      expect(find.text('Artifacts'), findsOneWidget);
      expect(find.text('Requested model'), findsOneWidget);
      expect(find.text('Provider model'), findsOneWidget);
      expect(find.text('Input tokens'), findsOneWidget);
      expect(find.text('Cost'), findsOneWidget);
      expect(find.text('—'), findsWidgets);

      await tester.tap(find.text('builder'));
      await tester.pump();
      expect(expanded, 'worker-1');
      expect(find.text('Child tool output'), findsOneWidget);
      expect(find.text('Worker · Tool · #4'), findsOneWidget);
      expect(find.text('Open transcript'), findsOneWidget);
      expect(find.text('Log unavailable'), findsOneWidget);
      expect(find.text('Compaction'), findsOneWidget);
      expect(find.text('Compacted at'), findsOneWidget);
      expect(find.text('compaction-worker-1'), findsOneWidget);
      expect(find.text('102400'), findsOneWidget);
      expect(find.text('24000'), findsOneWidget);
      expect(find.text('checkpoint-worker-1'), findsOneWidget);
      expect(find.text('continuing_existing_task'), findsOneWidget);
      expect(find.text('private thought text must not appear'), findsNothing);

      await tester.ensureVisible(find.text('Open transcript'));
      await tester.pump();
      await tester.tap(find.text('Open transcript'));
      await tester.pump();
      expect(opened, 'child-1');

      await tester.drag(
        find.byKey(const ValueKey<String>('rich-trajectory-list')),
        const Offset(0, 2000),
      );
      await tester.pump();
      await tester.ensureVisible(find.text('researcher'));
      await tester.pump();
      await tester.tap(find.text('researcher'));
      await tester.pump();
      expect(find.text('Open transcript'), findsNothing);
      expect(find.text('View log'), findsNothing);
      expect(find.text('Deferred age'), findsOneWidget);
      expect(find.text('Runtime'), findsWidgets);
      semantics.dispose();
    },
  );

  testWidgets(
    'Show raw is explicit paginated and main compaction stays out of ordinary steps',
    (tester) async {
      final after = <String?>[];
      final root = _root();
      expect(
        root.mainSteps.where((step) => step.type == 'compaction_completed'),
        isEmpty,
      );

      await pumpAt(
        tester,
        RunTrajectoryPage(
          data: V2RunTrajectoryPageData(
            title: 'Canonical run',
            runLabel: '',
            trajectory: root,
          ),
          onShowRaw: (cursor) async {
            after.add(cursor);
            return RawTrajectoryPage.fromJson(<String, dynamic>{
              'items': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'main-compaction',
                  'value': <String, dynamic>{
                    'type': 'compaction_completed',
                    'actorKind': 'main',
                    'compactionId': 'compaction-main-1',
                  },
                },
              ],
              'nextCursor': cursor == null ? 'raw-next' : null,
              'truncated': true,
            });
          },
        ),
        size: const Size(900, 1200),
      );

      expect(after, isEmpty);
      expect(find.text('compaction-main-1'), findsNothing);
      await tester.tap(find.text('Show raw'));
      await tester.pump();
      await tester.pump();
      expect(after, <String?>[null]);
      expect(find.text('compaction-main-1'), findsNothing);
      final raw = tester.widget<SelectableText>(
        find.byKey(const ValueKey<String>('trajectory-raw-content')),
      );
      expect(raw.data!.contains('compaction-main-1'), isTrue);
      expect(find.text('Truncated by server'), findsOneWidget);

      await tester.tap(find.text('Load more raw'));
      await tester.pump();
      await tester.pump();
      expect(after, <String?>[null, 'raw-next']);
    },
  );

  testWidgets('canonical main diagnostics retain timestamp without thoughts', (
    tester,
  ) async {
    final root = foldTrajectoryPages(<Object?>[
      _root(),
      <String, dynamic>{
        'events': <Map<String, dynamic>>[
          <String, dynamic>{
            'sessionId': 'session-1',
            'seq': '40',
            'type': 'compaction_completed',
            'ts': '2026-10-24T12:10:00.000Z',
            'payload': <String, dynamic>{
              'type': 'compaction_completed',
              'actorKind': 'main',
              'sessionId': 'session-1',
              'runId': 'root-1',
              'compactionId': 'compaction-main-1',
              'checkpointId': 'checkpoint-main-1',
              'ts': '2026-10-24T12:10:00.000Z',
              'model': 'fixture-medium',
              'contextLimit': 32000,
              'beforeTokens': 25600,
              'afterTokens': 6000,
              'usageSource': 'deterministic_fallback',
              'continuation': 'continuing_existing_task',
              'thoughts': 'never project',
            },
          },
        ],
      },
    ]);
    await pumpAt(
      tester,
      RunTrajectoryPage(
        data: V2RunTrajectoryPageData(
          title: 'Canonical run',
          runLabel: '',
          trajectory: root,
        ),
      ),
      size: const Size(900, 1200),
    );

    expect(find.text('Compaction diagnostics'), findsOneWidget);
    expect(find.text('compaction-main-1'), findsOneWidget);
    expect(find.textContaining('2026-10-24T12:10'), findsWidgets);
    expect(find.text('never project'), findsNothing);
  });

  testWidgets(
    'diagnostics-only host offers Load earlier instead of empty state',
    (tester) async {
      final api = _DiagnosticsOnlyApi();
      await pumpAt(
        tester,
        CanonicalTrajectoryPage(
          api: api,
          sessionId: 'session-1',
          title: 'Diagnostics only',
        ),
        size: const Size(900, 1200),
      );

      expect(find.text('No trajectory events yet'), findsNothing);
      expect(find.text('Compaction diagnostics'), findsOneWidget);
      expect(find.text('Load earlier events'), findsOneWidget);
      await tester.tap(find.text('Load earlier events'));
      await tester.pump();
      await tester.pump();
      expect(api.before, <String?>[null, 'root-before-1']);
    },
  );

  testWidgets(
    'canonical worker report has six keys and deferred has no transcript or log action',
    (tester) async {
      final deferred = _root().workers.first;
      await pumpAt(
        tester,
        SubagentPage(
          data: V2SubagentPageData(
            name: 'researcher',
            instanceLabel: '',
            stepLabel: '',
            goal: '',
            startedLabel: '',
            elapsedLabel: '',
            timeLimitLabel: '—',
            remainingLabel: '',
            totalLogLines: 0,
            trajectoryWorker: deferred,
          ),
          onViewLog: () {},
        ),
      );

      expect(find.text('Awaiting next user task'), findsOneWidget);
      expect(find.text('Open transcript'), findsNothing);
      expect(find.text('View log'), findsNothing);
      expect(find.text('Log unavailable'), findsOneWidget);
      expect(find.text('Stop subagent'), findsNothing);

      final report = TrajectoryReport.fromJson(<String, dynamic>{
        'subagent_id': 'child-1',
        'status': 'completed',
        'files_modified': <String>['lib/a.dart'],
        'artifacts_created': <String>[],
        'key_findings': 'Bounded actual findings',
        'error_if_any': null,
      });
      final completed = TrajectoryWorker(
        logicalWorkerId: 'worker-1',
        childSessionId: 'child-1',
        childRunId: 'child-run-1',
        status: 'completed',
        startKnown: true,
        startedAt: DateTime.utc(2026, 10, 24, 12),
        endedAt: DateTime.utc(2026, 10, 24, 12, 1),
        report: report,
        logAvailable: false,
      );
      await pumpAt(
        tester,
        SubagentPage(
          data: V2SubagentPageData(
            name: 'builder',
            instanceLabel: '',
            stepLabel: '',
            goal: '',
            startedLabel: '',
            elapsedLabel: '',
            timeLimitLabel: '—',
            remainingLabel: '',
            totalLogLines: 0,
            trajectoryWorker: completed,
          ),
          onViewLog: () {},
        ),
      );

      expect(find.text('SUBAGENT ID'), findsOneWidget);
      expect(find.text('child-1'), findsOneWidget);
      expect(find.text('FILES MODIFIED'), findsOneWidget);
      expect(find.text('ARTIFACTS CREATED'), findsOneWidget);
      expect(find.text('KEY FINDINGS'), findsOneWidget);
      expect(find.text('ERROR IF ANY'), findsOneWidget);
      expect(find.text('Bounded actual findings'), findsOneWidget);
      expect(find.text('View log'), findsNothing);
    },
  );

  testWidgets(
    'event mirror keeps main compaction diagnostics in explicit server raw only',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      addTearDown(AppState.resetTestInstance);
      app.sessions.add(
        ChatSession(id: 'raw-session', title: 'Raw', model: 'm', mode: 'auto'),
      );
      final rest = FakeCloudEventsRest();
      rest.events = <Map<String, dynamic>>[
        cloudEvent('1', 'compaction_completed', <String, dynamic>{
          'type': 'compaction_completed',
          'actorKind': 'main',
          'sessionId': 'server-session',
          'runId': 'root-main',
          'compactionId': 'compaction-main-1',
          'checkpointId': 'checkpoint-main-1',
          'ts': '2026-10-24T12:10:00.000Z',
          'model': 'fixture-medium',
          'contextLimit': 32000,
          'beforeTokens': 25600,
          'afterTokens': 6000,
          'usageSource': 'deterministic_fallback',
          'continuation': 'continuing_existing_task',
        }),
      ];
      installFakeCloudEvents(rest);
      final api = _RouteApi();

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: Aether.theme(),
            home: TrajectoryScreen(sessionId: 'raw-session', api: api),
          ),
        );
        await settleTrajectory(tester);
      });

      expect(find.text('#1 · Compaction completed'), findsNothing);
      expect(find.text('No events yet'), findsOneWidget);
      expect(api.rawAfter, isEmpty);

      await tester.runAsync(() async {
        await tester.tap(find.text('Show raw').first);
        await tester.pump();
        await tester.pump();
      });
      expect(api.rawAfter, <String?>[null]);
      final raw = tester.widget<SelectableText>(
        find.byKey(const ValueKey<String>('trajectory-raw-content')),
      );
      expect(raw.data!.contains('compaction-main-1'), isTrue);
    },
  );

  testWidgets(
    'final raw page hides continuation and keeps earlier truncation',
    (tester) async {
      var calls = 0;
      Map<String, dynamic> chunk(int offset, String data, int? nextOffset) =>
          <String, dynamic>{
            'item': <String, dynamic>{
              'stableId': 'same-entry',
              'kind': 'message',
              'sessionId': 'session-1',
              'rootTaskRunId': 'root-1',
              'logicalWorkerId': null,
              'attemptId': null,
              'eventCursor': 'cursor-1',
              'inlinePayload': <String, dynamic>{'safe': true},
              'byteLength': 20,
            },
            'offset': offset,
            'data': data,
            'nextOffset': nextOffset,
          };
      await pumpAt(
        tester,
        RunTrajectoryPage(
          data: V2RunTrajectoryPageData(
            title: 'Raw chunks',
            runLabel: '',
            trajectory: _root(),
          ),
          onShowRaw: (after) async {
            calls += 1;
            return RawTrajectoryPage.fromJson(<String, dynamic>{
              'chunks': <Map<String, dynamic>>[
                if (calls == 1)
                  chunk(0, 'chunk-0', 120)
                else
                  chunk(120, 'chunk-1', null),
              ],
              'nextCursor': calls == 1 ? 'next' : null,
              'truncated': calls == 1,
            });
          },
        ),
        size: const Size(900, 1200),
      );

      await tester.tap(find.text('Show raw'));
      await tester.pump();
      await tester.pump();
      expect(
        find.text(
          'Raw history continues on the next page; nothing is clipped.',
        ),
        findsOneWidget,
      );
      expect(find.text('Truncated by server'), findsOneWidget);

      await tester.ensureVisible(find.text('Load more raw'));
      await tester.tap(find.text('Load more raw'));
      await tester.pump();
      await tester.pump();
      expect(
        find.text(
          'Raw history continues on the next page; nothing is clipped.',
        ),
        findsNothing,
      );
      expect(find.text('Load more raw'), findsNothing);
      expect(find.text('Truncated by server'), findsOneWidget);
      expect(calls, 2);
    },
  );

  testWidgets('raw exact-history continuations dedupe by entry and offset', (
    tester,
  ) async {
    var calls = 0;
    await pumpAt(
      tester,
      RunTrajectoryPage(
        data: V2RunTrajectoryPageData(
          title: 'Raw chunks',
          runLabel: '',
          trajectory: _root(),
        ),
        onShowRaw: (after) async {
          final call = calls++;
          return RawTrajectoryPage.fromJson(<String, dynamic>{
            'chunks': <Map<String, dynamic>>[
              <String, dynamic>{
                'item': <String, dynamic>{
                  'stableId': 'same-entry',
                  'kind': 'message',
                  'sessionId': 'session-1',
                  'rootTaskRunId': 'root-1',
                  'logicalWorkerId': null,
                  'attemptId': null,
                  'eventCursor': 'cursor-1',
                  'inlinePayload': <String, dynamic>{'safe': true},
                  'byteLength': 20,
                },
                'offset': call == 0 ? 0 : 120,
                'data': '"chunk-$call"',
                'nextOffset': call == 0 ? 120 : null,
              },
            ],
            // The second page deliberately keeps a cursor so its replay can
            // prove offset-aware deduplication on the third request.
            'nextCursor': call < 2 ? 'next' : null,
          });
        },
      ),
      size: const Size(900, 1200),
    );

    Future<void> loadNext() async {
      await tester.ensureVisible(find.text('Load more raw'));
      await tester.pump();
      await tester.tap(find.text('Load more raw'));
      await tester.pump();
      await tester.pump();
    }

    await tester.tap(find.text('Show raw'));
    await tester.pump();
    await tester.pump();
    await loadNext();
    await loadNext();

    final raw = tester.widget<SelectableText>(
      find.byKey(const ValueKey<String>('trajectory-raw-content')),
    );
    expect(raw.data!.contains('chunk-0'), isTrue);
    expect(raw.data!.contains('chunk-1'), isTrue);
    // The third response replays offset 120 and must not duplicate it.
    expect(raw.data!.contains('chunk-2'), isFalse);
    expect('offset": 120'.allMatches(raw.data!), hasLength(1));
    expect(calls, 3);
  });

  testWidgets(
    'bounded worker prompt is labelled preview or unavailable, never a full goal',
    (tester) async {
      final preview = List<String>.filled(250, 'x').join().substring(0, 200);
      final root = foldTrajectoryPages([
        <String, dynamic>{
          'events': <Map<String, dynamic>>[
            <String, dynamic>{
              'sessionId': 'session-1',
              'seq': '1',
              'type': 'subagent_started',
              'ts': '2026-10-24T12:00:00.000Z',
              'payload': <String, dynamic>{
                'runId': 'root-1',
                'childSessionId': 'child-1',
                'childRunId': 'child-run-1',
                'agentType': 'general-purpose',
                'prompt': preview,
              },
            },
          ],
        },
      ]);
      final worker = root.workers.single;
      expect(worker.prompt, hasLength(200));

      await pumpAt(
        tester,
        SubagentPage(
          data: V2SubagentPageData(
            name: 'Worker',
            instanceLabel: '',
            stepLabel: '',
            // Match the route input: even when the host calls this a goal, the
            // canonical page must identify it as only the bounded preview.
            goal: worker.prompt!,
            startedLabel: '',
            elapsedLabel: '',
            timeLimitLabel: '—',
            remainingLabel: '',
            totalLogLines: 0,
            trajectoryWorker: worker,
          ),
        ),
      );
      expect(find.text('PROMPT PREVIEW'), findsOneWidget);
      expect(find.text('GOAL'), findsNothing);
      expect(find.text('FULL PROMPT'), findsNothing);

      await pumpAt(
        tester,
        SubagentPage(
          data: V2SubagentPageData(
            name: 'Worker',
            instanceLabel: '',
            stepLabel: '',
            goal: '',
            startedLabel: '',
            elapsedLabel: '',
            timeLimitLabel: '—',
            remainingLabel: '',
            totalLogLines: 0,
            trajectoryWorker: const TrajectoryWorker(
              logicalWorkerId: 'worker-no-prompt',
              status: 'completed',
            ),
          ),
        ),
      );
      expect(find.text('PROMPT UNAVAILABLE'), findsOneWidget);
      expect(find.text('PROMPT PREVIEW'), findsNothing);
    },
  );

  testWidgets('nested trajectory keeps a real outer-route back action', (
    tester,
  ) async {
    var backs = 0;
    await pumpAt(
      tester,
      RunTrajectoryPage(
        data: V2RunTrajectoryPageData(
          title: 'Nested run',
          runLabel: '',
          trajectory: _root(),
        ),
        onBack: () => backs++,
      ),
    );
    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pump();
    expect(backs, 1);
  });

  testWidgets(
    'RouteAware covered drill-down stops root and child fallback refresh',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final observer = RouteObserver<ModalRoute<void>>();
      final api = _RouteApi();

      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          navigatorObservers: <NavigatorObserver>[observer],
          home: CanonicalTrajectoryPage(
            api: api,
            sessionId: 'session-1',
            title: 'Canonical run',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(api.rootCalls, 1);

      await tester.tap(find.text('builder'));
      await tester.pump();
      await tester.pump();
      expect(api.childCalls, 1);
      await tester.ensureVisible(find.text('Open transcript'));
      await tester.pump();
      await tester.tap(find.text('Open transcript'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(SubagentPage), findsOneWidget);

      final coveredRootCalls = api.rootCalls;
      final coveredChildCalls = api.childCalls;
      await tester.pump(const Duration(seconds: 31));
      await tester.pump(const Duration(seconds: 31));
      expect(api.rootCalls, coveredRootCalls);
      expect(api.childCalls, coveredChildCalls);

      Navigator.of(tester.element(find.byType(SubagentPage))).pop();
      await tester.pump();
      await tester.pump();
      expect(api.rootCalls, greaterThan(coveredRootCalls));
      expect(api.childCalls, greaterThan(coveredChildCalls));
    },
  );
}
