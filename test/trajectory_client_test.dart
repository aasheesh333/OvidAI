import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/trajectory_client.dart';
import 'package:ovid_ai/core/cloud/trajectory_projection.dart';

class _FakeRest extends CloudRestClient {
  _FakeRest() : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  final List<Map<String, String>> requests = <Map<String, String>>[];
  Map<String, dynamic> summary = <String, dynamic>{
    'counts': <String, dynamic>{
      'total': 3,
      'running': 1,
      'awaiting_next_user_task': 1,
      'completed': 1,
      'failed': 0,
      'cancelled': 0,
      'timeout': 0,
    },
    'items': <Map<String, dynamic>>[
      <String, dynamic>{
        'logicalWorkerId': 'worker-1',
        'childSessionId': 'child-1',
        'childRunId': 'child-run-1',
        'status': 'running',
        'startKnown': true,
        'startedAt': '2026-10-24T12:00:00.000Z',
        'lastCursor': 'child-cursor-4',
        'logAvailable': false,
      },
    ],
    'nextCursor': null,
  };
  List<Map<String, dynamic>> events = <Map<String, dynamic>>[
    <String, dynamic>{
      'sessionId': 'server/session',
      'seq': '1',
      'type': 'message_completed',
      'ts': '2026-10-24T12:00:00.000Z',
      'payload': <String, dynamic>{'runId': 'root-1', 'content': 'hello'},
    },
  ];
  List<Map<String, dynamic>> childEvents = <Map<String, dynamic>>[];
  bool repeatRootEvents = false;
  bool repeatRawEvents = false;

  @override
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    requests.add(<String, String>{'path': path, ...?query});
    if (path == '/sessions/server%2Fsession/subagents') return summary;
    if (path == '/sessions/server%2Fsession/events') {
      final q = query ?? const <String, String>{};
      final limit = int.tryParse(q['limit'] ?? '') ?? events.length;
      if (repeatRootEvents || (repeatRawEvents && q.containsKey('after'))) {
        return <String, dynamic>{'events': events.take(limit).toList()};
      }
      if (q['tail'] == '1') {
        final start = events.length > limit ? events.length - limit : 0;
        return <String, dynamic>{'events': events.sublist(start)};
      }
      final before = q['before'];
      if (before != null) {
        final index = events.indexWhere((event) => '${event['seq']}' == before);
        final end = index < 0 ? 0 : index;
        final start = end > limit ? end - limit : 0;
        return <String, dynamic>{'events': events.sublist(start, end)};
      }
      return <String, dynamic>{'events': events.take(limit).toList()};
    }
    if (path == '/sessions/child-1/events') {
      return <String, dynamic>{'events': childEvents};
    }
    throw StateError('Unexpected path: $path');
  }
}

class _FakeApi extends TrajectoryApi {
  _FakeApi(this.rootPage)
    : super(
        CloudRestClient(
          headers: CloudHeaders.forTest(),
          restBase: 'http://test',
        ),
      );

  final TrajectoryRoot rootPage;
  final List<String?> rootBefore = <String?>[];
  final List<String?> childAfter = <String?>[];
  int rootCalls = 0;
  int childCalls = 0;
  bool completeOnExpand = false;
  Completer<TrajectoryEventPage>? childGate;

  @override
  Future<TrajectoryRoot> root(String sessionId, {String? before}) async {
    rootCalls += 1;
    rootBefore.add(before);
    if (!completeOnExpand) return rootPage;
    return foldTrajectoryPages(<Object?>[
      rootPage,
      <String, dynamic>{
        'counts': <String, dynamic>{
          'total': 1,
          'running': 0,
          'awaiting_next_user_task': 0,
          'completed': 1,
          'failed': 0,
          'cancelled': 0,
          'timeout': 0,
        },
        'workers': <Map<String, dynamic>>[
          <String, dynamic>{
            'logicalWorkerId': 'worker-1',
            'childSessionId': 'child-1',
            'childRunId': 'child-run-1',
            'status': 'completed',
            'startKnown': true,
            'startedAt': '2026-10-24T12:00:00.000Z',
            'endedAt': '2026-10-24T12:09:00.000Z',
            'summary': 'finished while expanded',
            'structuredReport': <String, dynamic>{
              'subagent_id': 'child-1',
              'status': 'completed',
              'files_modified': <String>[],
              'artifacts_created': <String>[],
              'key_findings': 'actual report',
              'error_if_any': null,
            },
          },
        ],
      },
    ]);
  }

  @override
  Future<TrajectoryEventPage> workerEvents(
    String childSessionId, {
    String? after,
  }) async {
    completeOnExpand = true;
    childAfter.add(after);
    childCalls += 1;
    final page = TrajectoryEventPage(
      events: <Map<String, dynamic>>[
        <String, dynamic>{
          'sessionId': childSessionId,
          'seq': '8',
          'type': 'tool_completed',
          'ts': '2026-10-24T12:08:00.000Z',
          'payload': <String, dynamic>{
            'sessionId': childSessionId,
            'runId': 'child-run-1',
            'callId': 'child-call-8',
            'name': 'read_file',
            'content': 'child tool output',
          },
        },
      ],
      nextCursor: 'child-cursor-8',
    );
    final gate = childGate;
    if (gate != null) return gate.future;
    return page;
  }
}

class _ManualTimer implements Timer {
  _ManualTimer(this.callback);

  final void Function() callback;
  bool active = true;
  int ticks = 0;

  @override
  void cancel() => active = false;

  @override
  bool get isActive => active;

  @override
  int get tick => ticks;

  void fire() {
    if (!active) return;
    ticks += 1;
    callback();
  }
}

TrajectoryRoot _controllerRoot() => foldTrajectoryPages([
  <String, dynamic>{
    'counts': <String, dynamic>{
      'total': 1,
      'running': 1,
      'awaiting_next_user_task': 0,
      'completed': 0,
      'failed': 0,
      'cancelled': 0,
      'timeout': 0,
    },
    'workers': <Map<String, dynamic>>[
      <String, dynamic>{
        'logicalWorkerId': 'worker-1',
        'childSessionId': 'child-1',
        'childRunId': 'child-run-1',
        'status': 'running',
        'startKnown': true,
        'startedAt': '2026-10-24T12:00:00.000Z',
        'lastCursor': 'child-cursor-4',
      },
    ],
    'earlierCursor': 'root-before-1',
  },
]);

TrajectoryRoot _parentLifecycleControllerRoot() => foldTrajectoryPages([
  _controllerRoot(),
  <String, dynamic>{
    'steps': <Map<String, dynamic>>[
      <String, dynamic>{
        'cursor': 'session-1:1',
        'sessionId': 'session-1',
        'runId': 'root-1',
        'seq': '1',
        'actorKind': 'main',
        'kind': 'model',
        'type': 'message_completed',
        'ts': '2026-10-24T12:00:00.000Z',
        'output': 'main answer',
      },
      <String, dynamic>{
        'cursor': 'session-1:2',
        'sessionId': 'session-1',
        'runId': 'root-1',
        'seq': '2',
        'actorKind': 'main',
        'kind': 'subagent',
        'type': 'subagent_started',
        'ts': '2026-10-24T12:00:01.000Z',
      },
      <String, dynamic>{
        'cursor': 'session-1:3',
        'sessionId': 'session-1',
        'runId': 'root-1',
        'seq': '3',
        'actorKind': 'main',
        'kind': 'subagent',
        'type': 'subagent_completed',
        'ts': '2026-10-24T12:00:02.000Z',
        'summary': 'parent lifecycle summary',
      },
      <String, dynamic>{
        'cursor': 'session-1:4',
        'sessionId': 'session-1',
        'runId': 'root-1',
        'seq': '4',
        'actorKind': 'worker',
        'kind': 'system',
        'type': 'subagent_compacted',
        'ts': '2026-10-24T12:00:03.000Z',
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
    ],
  },
]);

void main() {
  test(
    'root uses canonical counts and tail event reads without deriving totals',
    () async {
      final rest = _FakeRest();
      final api = TrajectoryApi(rest);

      final root = await api.root('server/session');

      expect(root.counts.total, 3);
      expect(root.counts.awaitingNextUserTask, 1);
      expect(root.workers.single.childSessionId, 'child-1');
      expect(root.mainSteps.single.output, 'hello');
      expect(root.earlierCursor, isNull);
      expect(rest.requests[0]['path'], '/sessions/server%2Fsession/subagents');
      expect(rest.requests[1]['path'], '/sessions/server%2Fsession/events');
      expect(rest.requests[1]['tail'], '1');
      expect(rest.requests[1]['limit'], '200');

      await api.root('server/session', before: 'root-before-1');
      expect(rest.requests[3]['before'], 'root-before-1');
      expect(rest.requests[3].containsKey('tail'), isFalse);
    },
  );

  test(
    'worker expansion forwards the last cursor and raw uses event pagination',
    () async {
      final rest = _FakeRest();
      rest.childEvents = <Map<String, dynamic>>[
        <String, dynamic>{
          'sessionId': 'child-1',
          'seq': '5',
          'type': 'tool_completed',
          'ts': '2026-10-24T12:01:00.000Z',
          'payload': <String, dynamic>{'name': 'read', 'content': 'ok'},
        },
      ];
      final api = TrajectoryApi(rest);

      final child = await api.workerEvents('child-1', after: 'child-cursor-4');
      expect(child.events.single['seq'], '5');
      expect(child.nextCursor, '5');
      expect(rest.requests.single['path'], '/sessions/child-1/events');
      expect(rest.requests.single['after'], 'child-cursor-4');

      final raw = await api.showRaw('server/session', after: 'raw-page-1');
      expect(raw.entries.single.id, '1');
      expect(raw.nextCursor, isNull);
      expect(rest.requests[1]['path'], '/sessions/server%2Fsession/events');
      expect(rest.requests[1]['after'], 'raw-page-1');
      expect(rest.requests[1]['limit'], '50');
    },
  );

  test(
    'every raw page reauthorizes and retries once with a refreshed ID token',
    () async {
      var mints = 0;
      final authorization = <String>[];
      final client = MockClient((request) async {
        authorization.add(request.headers['Authorization'] ?? '');
        if (authorization.length == 1) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'error': <String, dynamic>{
                'code': 'unauthenticated',
                'message': 'expired',
              },
            }),
            401,
          );
        }
        return http.Response(
          jsonEncode(<String, dynamic>{
            'events': <Map<String, dynamic>>[
              <String, dynamic>{
                'sessionId': 'session-1',
                'seq': '7',
                'type': 'tool_completed',
                'payload': <String, dynamic>{'redacted': true},
              },
            ],
            'nextCursor': null,
          }),
          200,
        );
      });
      final rest = CloudRestClient(
        httpClient: client,
        restBase: 'https://gateway.example.invalid/cloud/v1',
        headers: CloudHeaders(idToken: () async => 'test-token-${++mints}'),
      );
      final api = TrajectoryApi(rest);

      final page = await api.showRaw('session-1');

      expect(page.entries.single.id, '7');
      expect(
        (page.entries.single.value as Map)['payload'],
        <String, dynamic>{'redacted': true},
      );
      expect(mints, 2);
      expect(authorization, <String>[
        'Bearer test-token-1',
        'Bearer test-token-2',
      ]);
    },
  );

  test('raw event pagination never repeats a consumed bound', () async {
    final rest = _FakeRest()..repeatRawEvents = true;
    rest.events = <Map<String, dynamic>>[
      for (var i = 1; i <= TrajectoryApi.rawPageSize; i++)
        <String, dynamic>{
          'sessionId': 'server/session',
          'seq': '$i',
          'type': 'message_completed',
          'ts': '2026-10-24T12:00:00.000Z',
          'payload': <String, dynamic>{'content': 'event-$i'},
        },
    ];

    final raw = await TrajectoryApi(rest).showRaw('server/session', after: '1');

    expect(raw.nextCursor, isNull);
    expect(rest.requests.single['path'], '/sessions/server%2Fsession/events');
    expect(rest.requests.single['after'], '1');
  });

  test(
    'hidden controller stops fallback and real parent/child expansion reconciles',
    () async {
      final api = _FakeApi(_controllerRoot());
      final timers = <_ManualTimer>[];
      final controller = TrajectoryController(
        api: api,
        sessionId: 'session-1',
        timerFactory: (_, callback) {
          final timer = _ManualTimer(callback);
          timers.add(timer);
          return timer;
        },
      );

      await controller.start();
      expect(api.rootCalls, 1);
      expect(timers, hasLength(1));
      expect(api.childAfter, isEmpty);

      controller.setVisible(false);
      expect(timers.single.isActive, isFalse);
      timers.single.fire();
      await Future<void>.delayed(Duration.zero);
      expect(api.rootCalls, 1);

      await controller.expandWorker(rootPageWorkerWithoutChild());
      expect(api.childAfter, isEmpty);

      controller.setVisible(true);
      await controller.refresh();
      await controller.expandWorker(_controllerRoot().workers.single);
      expect(api.childAfter, <String?>['child-cursor-4']);
      expect(controller.root.workers.single.status, 'completed');
      expect(
        controller.root.workers.single.report!.keyFindings,
        'actual report',
      );
      expect(controller.root.workers.single.lastCursor, 'child-cursor-8');
      expect(
        controller.root.workers.single.steps.map((step) => step.type),
        <String>['tool_completed'],
      );
      expect(
        controller.root.workers.single.steps.first.output,
        'child tool output',
      );

      controller.collapseWorker();
      timers.last.fire();
      await Future<void>.delayed(Duration.zero);
      expect(api.childAfter, hasLength(1));
      controller.dispose();
    },
  );

  test(
    'hidden expansion starts no reads and late hidden results are fenced',
    () async {
      final api = _FakeApi(_controllerRoot());
      final controller = TrajectoryController(api: api, sessionId: 'session-1');
      await controller.start();
      final initialRootCalls = api.rootCalls;
      final gate = Completer<TrajectoryEventPage>();
      api.childGate = gate;

      final expanding = controller.expandWorker(
        _controllerRoot().workers.single,
      );
      await Future<void>.delayed(Duration.zero);
      expect(api.childCalls, 1);
      expect(api.rootCalls, initialRootCalls + 1);

      controller.setVisible(false);
      final hiddenRootCalls = api.rootCalls;
      await controller.expandWorker(_controllerRoot().workers.single);
      expect(api.childCalls, 1);
      expect(api.rootCalls, hiddenRootCalls);

      gate.complete(
        const TrajectoryEventPage(
          events: <Map<String, dynamic>>[],
          nextCursor: 'child-cursor-8',
        ),
      );
      await expanding;
      expect(controller.root.workers.single.status, 'running');
      expect(controller.root.workers.single.steps, isEmpty);
      expect(api.childCalls, 1);
      expect(api.rootCalls, hiddenRootCalls);
      controller.dispose();
    },
  );

  test(
    'controller start refresh expansion preserves canonical main provenance',
    () async {
      final api = _FakeApi(_parentLifecycleControllerRoot());
      final controller = TrajectoryController(api: api, sessionId: 'session-1');
      const mainTypes = <String>[
        'message_completed',
        'subagent_started',
        'subagent_completed',
        'subagent_compacted',
      ];

      await controller.start();
      expect(controller.root.counts.total, 1);
      expect(controller.root.workers, hasLength(1));
      expect(controller.root.workers.single.lastCursor, 'child-cursor-4');
      expect(controller.root.mainSteps.map((step) => step.type), mainTypes);
      expect(
        controller.root.mainSteps.every((step) => step.canonicalMain),
        isTrue,
      );
      expect(
        controller.root.workers.where((worker) => worker.status == 'unknown'),
        isEmpty,
      );

      await controller.refresh();
      expect(controller.root.workers, hasLength(1));
      expect(controller.root.mainSteps.map((step) => step.type), mainTypes);
      expect(
        controller.root.mainSteps.every((step) => step.canonicalMain),
        isTrue,
      );

      await controller.expandWorker(controller.root.workers.single);
      expect(controller.root.workers, hasLength(1));
      expect(controller.root.workers.single.status, 'completed');
      expect(controller.root.workers.single.lastCursor, 'child-cursor-8');
      expect(
        controller.root.workers.single.steps.map((step) => step.type),
        <String>['tool_completed'],
      );
      expect(controller.root.mainSteps.map((step) => step.type), mainTypes);
      expect(controller.root.mainSteps.last.actorKind, 'worker');
      expect(
        controller.root.mainSteps.every((step) => step.canonicalMain),
        isTrue,
      );
      expect(
        controller.root.workers.where((worker) => worker.status == 'unknown'),
        isEmpty,
      );
      expect(api.rootCalls, greaterThanOrEqualTo(3));
      controller.dispose();
    },
  );

  test('visible refresh shares an in-flight expanded-child request', () async {
    final api = _FakeApi(_controllerRoot());
    final controller = TrajectoryController(api: api, sessionId: 'session-1');
    await controller.start();
    final gate = Completer<TrajectoryEventPage>();
    api.childGate = gate;

    final expanding = controller.expandWorker(_controllerRoot().workers.single);
    final refreshing = controller.refresh();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final callsWhileRefreshing = api.childCalls;
    gate.complete(
      const TrajectoryEventPage(
        events: <Map<String, dynamic>>[],
        nextCursor: 'child-cursor-9',
      ),
    );
    await Future.wait(<Future<void>>[expanding, refreshing]);

    expect(callsWhileRefreshing, 1);
    expect(api.childAfter, <String?>['child-cursor-4']);
    controller.dispose();
  });

  test(
    'real {events} root pages derive an exclusive older bound and terminate on a short page',
    () async {
      final rest = _FakeRest();
      rest.events = <Map<String, dynamic>>[
        for (var i = 1; i <= 250; i++)
          <String, dynamic>{
            'sessionId': 'server/session',
            'seq': '$i',
            'type': 'message_completed',
            'ts': '2026-10-24T12:00:00.000Z',
            'payload': <String, dynamic>{
              'runId': 'root-1',
              'content': 'event-$i',
            },
          },
      ];
      final controller = TrajectoryController(
        api: TrajectoryApi(rest),
        sessionId: 'server/session',
      );

      await controller.start();
      expect(controller.root.mainSteps, hasLength(200));
      expect(controller.root.earlierCursor, '51');

      await controller.loadEarlier();
      expect(controller.root.mainSteps, hasLength(250));
      expect(controller.root.earlierCursor, isNull);
      expect(
        rest.requests.where((request) => request['before'] == '51'),
        hasLength(1),
      );

      final requestCount = rest.requests.length;
      await controller.loadEarlier();
      expect(rest.requests, hasLength(requestCount));
      controller.dispose();
    },
  );

  test(
    '450 events preserve unconsumed older cursor across tail refresh and terminate exhausted pages',
    () async {
      final rest = _FakeRest();
      rest.events = <Map<String, dynamic>>[
        for (var i = 1; i <= 450; i++)
          <String, dynamic>{
            'sessionId': 'server/session',
            'seq': '$i',
            'type': 'message_completed',
            'ts': '2026-10-24T12:00:00.000Z',
            'payload': <String, dynamic>{
              'runId': 'root-1',
              'content': 'event-$i',
            },
          },
      ];
      final controller = TrajectoryController(
        api: TrajectoryApi(rest),
        sessionId: 'server/session',
      );

      await controller.start();
      expect(controller.root.mainSteps.first.seq, '251');
      expect(controller.root.mainSteps, hasLength(200));
      expect(controller.root.earlierCursor, '251');

      await controller.loadEarlier();
      expect(controller.root.mainSteps.first.seq, '51');
      expect(controller.root.mainSteps, hasLength(400));
      expect(controller.root.earlierCursor, '51');

      await controller.refresh();
      expect(controller.root.mainSteps, hasLength(400));
      expect(
        controller.root.earlierCursor,
        '51',
        reason:
            'refresh must not replace unconsumed continuation with the attempted tail bound 251',
      );

      await controller.loadEarlier();
      expect(controller.root.mainSteps, hasLength(450));
      expect(controller.root.earlierCursor, isNull);

      // Even another tail refresh cannot reopen an already exhausted bound,
      // and no exhausted `before` request may be sent again.
      await controller.refresh();
      await controller.loadEarlier();
      final beforeRequests = <String>[
        for (final request in rest.requests)
          if (request['path'] == '/sessions/server%2Fsession/events' &&
              request.containsKey('before'))
            request['before']!,
      ];
      expect(beforeRequests, <String>['251', '51']);
      controller.dispose();
    },
  );

  test(
    'a full repeated {events} page cannot repeat the same older bound',
    () async {
      final rest = _FakeRest();
      rest.repeatRootEvents = true;
      rest.events = <Map<String, dynamic>>[
        for (var i = 1; i <= 200; i++)
          <String, dynamic>{
            'sessionId': 'server/session',
            'seq': '$i',
            'type': 'message_completed',
            'ts': '2026-10-24T12:00:00.000Z',
            'payload': <String, dynamic>{'content': 'event-$i'},
          },
      ];
      final controller = TrajectoryController(
        api: TrajectoryApi(rest),
        sessionId: 'server/session',
      );

      await controller.start();
      expect(controller.root.earlierCursor, '1');
      await controller.loadEarlier();
      expect(controller.root.earlierCursor, isNull);
      expect(
        rest.requests.where((request) => request['before'] == '1'),
        hasLength(1),
      );

      final requestCount = rest.requests.length;
      await controller.loadEarlier();
      expect(rest.requests, hasLength(requestCount));
      controller.dispose();
    },
  );

  test(
    'older root pages merge without replacing canonical summary counts',
    () async {
      final api = _FakeApi(_controllerRoot());
      final controller = TrajectoryController(api: api, sessionId: 'session-1');
      await controller.start();
      await controller.loadEarlier();

      expect(api.rootBefore, <String?>[null, 'root-before-1']);
      expect(controller.root.counts.total, 1);
      expect(controller.root.workers, hasLength(1));
      controller.dispose();
    },
  );

  test('refresh and Load earlier dedupe canonical diagnostics', () async {
    final withDiagnostic = foldTrajectoryPages(<Object?>[
      _controllerRoot(),
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
              'model': 'fixture',
              'contextLimit': 32000,
              'beforeTokens': 25600,
              'afterTokens': 6000,
              'usageSource': 'measured',
              'continuation': 'continuing_existing_task',
            },
          },
        ],
      },
    ]);
    final api = _FakeApi(withDiagnostic);
    final controller = TrajectoryController(api: api, sessionId: 'session-1');
    await controller.start();
    await controller.refresh();
    await controller.loadEarlier();

    expect(controller.root.diagnostics, hasLength(1));
    expect(
      controller.root.diagnostics.single.compactionId,
      'compaction-main-1',
    );
    expect(
      controller.root.diagnostics.single.timestamp,
      DateTime.utc(2026, 10, 24, 12, 10),
    );
    controller.dispose();
  });

  test('diagnostics-only root can Load earlier and stays content', () async {
    final diagnosticsOnly = foldTrajectoryPages(<Object?>[
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
              'model': 'fixture',
              'contextLimit': 32000,
              'beforeTokens': 25600,
              'afterTokens': 6000,
              'usageSource': 'measured',
              'continuation': 'continuing_existing_task',
            },
          },
        ],
      },
    ]);
    expect(diagnosticsOnly.mainSteps, isEmpty);
    expect(diagnosticsOnly.workers, isEmpty);
    expect(diagnosticsOnly.diagnostics, hasLength(1));

    final api = _FakeApi(diagnosticsOnly);
    final controller = TrajectoryController(api: api, sessionId: 'session-1');
    await controller.start();
    await controller.loadEarlier();

    expect(api.rootBefore, <String?>[null, 'root-before-1']);
    expect(controller.root.diagnostics, hasLength(1));
    expect(
      controller.root.diagnostics.single.timestamp,
      DateTime.utc(2026, 10, 24, 12, 10),
    );
    controller.dispose();
  });
}

TrajectoryWorker rootPageWorkerWithoutChild() => const TrajectoryWorker(
  logicalWorkerId: 'deferred-worker',
  deferredRequestId: 'deferred-1',
  status: 'awaiting_next_user_task',
  startKnown: false,
  childSessionId: null,
  childRunId: null,
  logAvailable: false,
);
