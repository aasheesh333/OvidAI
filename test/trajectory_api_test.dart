import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/event_projection.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/cloud/trajectory_api.dart';

class _FakeRest extends CloudRestClient {
  _FakeRest() : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  final List<Map<String, String>> requests = <Map<String, String>>[];
  int summaryCalls = 0;
  bool completeWorker = false;
  bool includeParentLifecycle = false;
  bool subagentsMissing = false;

  @override
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    final q = query ?? const <String, String>{};
    requests.add(<String, String>{'path': path, ...q});
    if (path == '/sessions/session-1/subagents') {
      if (subagentsMissing) {
        throw CloudApiException(
          status: 404,
          code: 'not_found',
          message: 'Subagent projection is not available.',
        );
      }
      summaryCalls += 1;
      final second = q['after'] == 'workers-page-2';
      return <String, dynamic>{
        'counts': <String, dynamic>{
          'total': 2,
          'running': completeWorker ? 0 : 1,
          'awaiting_next_user_task': 1,
          'completed': completeWorker ? 1 : 0,
          'failed': 0,
          'cancelled': 0,
          'timeout': 0,
        },
        'items': <Map<String, dynamic>>[
          if (!second)
            <String, dynamic>{
              'requestId': 'request-1',
              'logicalWorkerId': 'worker-1',
              'childSessionId': 'child-1',
              'childRunId': 'child-run-1',
              'status': completeWorker ? 'completed' : 'running',
              'startKnown': true,
              'startedAt': '2026-10-24T12:00:02.000Z',
              if (completeWorker) ...<String, dynamic>{
                'endedAt': '2026-10-24T12:09:00.000Z',
                'summary': 'finished',
                'structuredReport': <String, dynamic>{
                  'subagent_id': 'child-1',
                  'status': 'completed',
                  'files_modified': <String>[],
                  'artifacts_created': <String>[],
                  'key_findings': 'actual report',
                  'error_if_any': null,
                },
              },
              'lastCursor': '4',
            }
          else
            <String, dynamic>{
              'requestId': 'deferred-1',
              'deferredRequestId': 'deferred-1',
              'logicalWorkerId': null,
              'childSessionId': null,
              'childRunId': null,
              'status': 'awaiting_next_user_task',
              'startKnown': false,
              'admittedAt': null,
              'startedAt': null,
              'endedAt': null,
            },
        ],
        'nextCursor': second ? null : 'workers-page-2',
      };
    }
    if (path == '/sessions/session-1/events') {
      return <String, dynamic>{
        'events': <Map<String, dynamic>>[
          <String, dynamic>{
            'sessionId': 'session-1',
            'seq': '1',
            'type': 'message_completed',
            'ts': '2026-10-24T12:00:00.000Z',
            'payload': <String, dynamic>{
              'runId': 'root-1',
              'content': 'canonical main answer',
            },
          },
          if (includeParentLifecycle) ...<Map<String, dynamic>>[
            <String, dynamic>{
              'sessionId': 'session-1',
              'seq': '2',
              'type': 'subagent_started',
              'ts': '2026-10-24T12:00:01.000Z',
              'payload': <String, dynamic>{
                'runId': 'root-1',
                'logicalWorkerId': 'worker-2',
                'childSessionId': 'child-2',
                'childRunId': 'child-run-2',
              },
            },
            <String, dynamic>{
              'sessionId': 'session-1',
              'seq': '3',
              'type': 'subagent_completed',
              'ts': '2026-10-24T12:00:02.000Z',
              'payload': <String, dynamic>{
                'runId': 'root-1',
                'logicalWorkerId': 'worker-2',
                'childSessionId': 'child-2',
                'childRunId': 'child-run-2',
                'status': 'completed',
                'summary': 'parent lifecycle summary',
              },
            },
            <String, dynamic>{
              'sessionId': 'session-1',
              'seq': '4',
              'type': 'subagent_compacted',
              'ts': '2026-10-24T12:00:03.000Z',
              'payload': <String, dynamic>{
                'runId': 'root-1',
                'workerId': 'worker-1',
                'compactionId': 'compaction-worker-1',
                'checkpointId': 'checkpoint-worker-1',
                'model': 'fixture',
                'contextLimit': 128000,
                'beforeTokens': 102400,
                'afterTokens': 24000,
                'usageSource': 'measured',
                'continuation': 'continuing_existing_task',
              },
            },
          ],
        ],
      };
    }
    if (path == '/sessions/child-1/events') {
      return <String, dynamic>{
        'events': <Map<String, dynamic>>[
          <String, dynamic>{
            'sessionId': 'child-1',
            'seq': '8',
            'type': 'tool_completed',
            'ts': '2026-10-24T12:08:00.000Z',
            'payload': <String, dynamic>{
              'runId': 'child-run-1',
              'callId': 'call-8',
              'name': 'read_file',
              'content': 'child output',
            },
          },
        ],
      };
    }
    throw StateError('Unexpected path: $path');
  }
}

void main() {
  test('legacy exact-recall DTOs expose chunks and nullable cursors', () {
    final projection = SubagentSessionProjection.fromJson(<String, dynamic>{
      'counts': <String, dynamic>{
        'total': 0,
        'running': 0,
        'awaiting_next_user_task': 0,
        'completed': 0,
        'failed': 0,
        'cancelled': 0,
        'timeout': 0,
      },
      'items': <Map<String, dynamic>>[],
      'nextCursor': null,
    });
    expect(projection.counts.total, 0);
    expect(projection.nextCursor, isNull);

    final raw = RawHistoryPage.fromJson(<String, dynamic>{
      'chunks': <Map<String, dynamic>>[
        <String, dynamic>{
          'item': <String, dynamic>{'stableId': 'raw'},
          'offset': 0,
          'data': '{}',
          'nextOffset': null,
        },
      ],
      'nextCursor': null,
    });
    expect(raw.chunks.single.data, '{}');
    expect(raw.chunks.single.nextOffset, isNull);
  });

  test('canonical API consumes event mirror and every summary page', () async {
    final rest = _FakeRest();
    final api = TrajectoryApi(rest);

    final root = await api.root('session-1');

    expect(root.counts.total, 2);
    expect(root.counts.running, 1);
    expect(root.counts.awaitingNextUserTask, 1);
    expect(root.workers, hasLength(2));
    expect(root.mainSteps.single.output, 'canonical main answer');
    expect(rest.summaryCalls, 2);
    expect(
      rest.requests.where((r) => r['path'] == '/sessions/session-1/events'),
      hasLength(1),
    );
    expect(rest.requests[2]['tail'], '1');
    final deferred = root.workers.singleWhere(
      (worker) => worker.deferredRequestId == 'deferred-1',
    );
    expect(deferred.childRunId, isNull);
    expect(deferred.startedAt, isNull);
    expect(deferred.startKnown, isFalse);
  });

  test(
    'canonical roster ignores parent lifecycle phantoms and cursors',
    () async {
      final rest = _FakeRest()..includeParentLifecycle = true;
      final root = await TrajectoryApi(rest).root('session-1');

      expect(root.counts.total, 2);
      expect(root.workers, hasLength(2));
      expect(root.mainSteps.map((step) => step.type), <String>[
        'message_completed',
        'subagent_started',
        'subagent_completed',
      ]);
      expect(
        root.workers.where((worker) => worker.status == 'unknown'),
        isEmpty,
      );
      expect(root.workers.map((worker) => worker.lastCursor), <String?>[
        '4',
        null,
      ]);

      final fallbackRest = _FakeRest()
        ..includeParentLifecycle = true
        ..subagentsMissing = true;
      final fallbackApi = TrajectoryApi(fallbackRest);
      final fallback = await fallbackApi.root('session-1');

      // Without the roster capability, raw lifecycle remains a read-only
      // fallback. It may reconstruct workers, but parent-session seq values
      // still must not become child-stream cursors.
      expect(fallback.workers, hasLength(2));
      expect(
        fallback.workers.map((worker) => worker.logicalWorkerId),
        containsAll(<String?>['worker-1', 'worker-2']),
      );
      expect(
        fallback.workers.every((worker) => worker.lastCursor == null),
        isTrue,
      );

      // Refolding this raw-fallback root must not reclassify it as canonical.
      final refolded = await fallbackApi.root('session-1');
      final merged = foldTrajectoryPages(<Object?>[fallback, refolded]);
      expect(merged.workers, hasLength(2));
      expect(
        merged.workers.every((worker) => worker.lastCursor == null),
        isTrue,
      );
    },
  );

  test(
    'fresh parent completion merges with real child-only activity',
    () async {
      final rest = _FakeRest();
      final api = TrajectoryApi(rest);
      final root = await api.root('session-1');
      final worker = root.workers.singleWhere(
        (w) => w.logicalWorkerId == 'worker-1',
      );
      rest.completeWorker = true;
      final parentRefresh = await api.root('session-1');

      final child = await api.workerEvents('child-1', after: worker.lastCursor);
      expect(rest.requests.last['after'], '4');
      expect(child.events, hasLength(1));
      expect(child.events.single['sessionId'], 'child-1');
      expect(child.nextCursor, '8');
      final merged = foldTrajectoryPages(<Object?>[
        parentRefresh,
        <String, dynamic>{
          'events': child.events,
          'childSessionId': 'child-1',
          'nextCursor': child.nextCursor,
        },
      ]);
      final expanded = merged.workers.singleWhere(
        (w) => w.logicalWorkerId == 'worker-1',
      );
      expect(expanded.status, 'completed');
      expect(expanded.report!.keyFindings, 'actual report');
      expect(expanded.lastCursor, '8');
    },
  );

  test(
    'missing subagent roster falls back to the durable event mirror',
    () async {
      final rest = _FakeRest()..subagentsMissing = true;

      final root = await TrajectoryApi(rest).root('session-1');

      expect(root.mainSteps.single.output, 'canonical main answer');
      expect(rest.requests.first['path'], '/sessions/session-1/subagents');
      expect(
        rest.requests.any((r) => r['path'] == '/sessions/session-1/events'),
        isTrue,
      );
      expect(
        rest.requests.any((r) => r['path'] == '/sessions/session-1/trajectory'),
        isFalse,
      );
    },
  );

  test(
    'raw reads the committed durable event mirror with owner pagination',
    () async {
      final rest = _FakeRest();

      final raw = await TrajectoryApi(rest).showRaw('session-1', after: '25');

      expect(raw.entries.single.id, '1');
      expect(raw.displayText, contains('canonical main answer'));
      expect(rest.requests.single['path'], '/sessions/session-1/events');
      expect(rest.requests.single['after'], '25');
      expect(rest.requests.single.containsKey('tail'), isFalse);
      expect(rest.requests.single['limit'], '50');
    },
  );

  test(
    'rich main compaction is diagnostics-only in the ordinary chat projector',
    () {
      final projection = TranscriptProjection();
      final projector = EventTranscriptProjector(projection);
      projector.apply(
        CloudSessionEvent(
          sessionId: 'session-1',
          seq: '1',
          type: 'compaction_completed',
          ts: DateTime.utc(2026, 10, 24, 12),
          payload: <String, dynamic>{
            'type': 'compaction_completed',
            'actorKind': 'main',
            'sessionId': 'session-1',
            'runId': 'root-1',
            'compactionId': 'compaction-main-1',
            'checkpointId': 'checkpoint-main-1',
            'ts': '2026-10-24T12:00:00.000Z',
            'model': 'fixture',
            'contextLimit': 32000,
            'beforeTokens': 25600,
            'afterTokens': 6000,
            'usageSource': 'measured',
            'continuation': 'continuing_existing_task',
            'thoughts': 'never show',
          },
        ),
      );

      expect(projection.messages, isEmpty);
      expect(
        projection.messages.any((m) => m.content.contains('never show')),
        isFalse,
      );
      projection.dispose();
    },
  );

  test(
    'hidden controller stops fallback and never polls a collapsed child',
    () async {
      final api = _ControllerApi();
      final controller = TrajectoryController(api: api, sessionId: 'session-1');
      await controller.start();
      expect(api.rootCalls, 1);
      controller.setVisible(false);
      await controller.refresh();
      expect(api.rootCalls, 1);
      expect(api.childCalls, 0);
      controller.collapseWorker();
      controller.dispose();
    },
  );
}

class _ControllerApi extends TrajectoryApi {
  _ControllerApi()
    : super(
        CloudRestClient(
          headers: CloudHeaders.forTest(),
          restBase: 'http://test',
        ),
      );

  int rootCalls = 0;
  int childCalls = 0;

  @override
  Future<TrajectoryRoot> root(String sessionId, {String? before}) async {
    rootCalls += 1;
    return const TrajectoryRoot();
  }

  @override
  Future<TrajectoryEventPage> workerEvents(
    String childSessionId, {
    String? after,
  }) async {
    childCalls += 1;
    return const TrajectoryEventPage(events: <Map<String, dynamic>>[]);
  }
}
