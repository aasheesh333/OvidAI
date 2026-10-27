import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/trajectory_projection.dart';

Map<String, dynamic> _event(
  String seq,
  String type,
  Map<String, dynamic> payload, {
  String sessionId = 'session-1',
  String ts = '2026-10-24T12:00:00.000Z',
}) => <String, dynamic>{
  'sessionId': sessionId,
  'seq': seq,
  'type': type,
  'ts': ts,
  'payload': <String, dynamic>{'sessionId': sessionId, ...payload},
};

Map<String, dynamic> _counts() => <String, dynamic>{
  'total': 7,
  'running': 1,
  'awaiting_next_user_task': 2,
  'completed': 1,
  'failed': 1,
  'cancelled': 1,
  'timeout': 1,
};

Map<String, dynamic> _deferredFixture() => <String, dynamic>{
  'counts': _counts(),
  'workers': <Map<String, dynamic>>[
    <String, dynamic>{
      'logicalWorkerId': 'worker-1',
      'deferredRequestId': 'deferred-1',
      'rootTaskRunId': 'root-1',
      'status': 'awaiting_next_user_task',
      'requestedAt': '2026-10-24T12:00:00.000Z',
      'deferredAt': '2026-10-24T12:00:01.000Z',
      'admittedAt': null,
      'startedAt': null,
      'endedAt': null,
      'startKnown': false,
      'childSessionId': null,
      'childRunId': null,
      'logAvailable': false,
    },
  ],
};

Map<String, dynamic> _compactionFixture() => <String, dynamic>{
  'events': <Map<String, dynamic>>[
    _event('11', 'subagent_compacted', <String, dynamic>{
      'type': 'subagent_compacted',
      'sessionId': 'session-1',
      'workerId': 'worker-1',
      'runId': 'attempt-worker-1',
      'compactionId': 'compaction-worker-1',
      'checkpointId': 'checkpoint-worker-1',
      'ts': '2026-10-24T12:11:00.000Z',
      'model': 'fixture-large',
      'contextLimit': 128000,
      'beforeTokens': 102400,
      'afterTokens': 24000,
      'usageSource': 'measured',
      'continuation': 'continuing_existing_task',
    }, ts: '2026-10-24T12:11:00.000Z'),
  ],
};

void main() {
  test(
    'deferred orphan and worker compaction never invent execution facts',
    () {
      final root = foldTrajectoryPages([
        _deferredFixture(),
        _compactionFixture(),
      ]);

      expect(root.workers.single.startKnown, isFalse);
      expect(root.workers.single.childSessionId, isNull);
      expect(root.workers.single.childRunId, isNull);
      expect(root.workers.single.startedAt, isNull);
      expect(root.workers.single.admittedAt, isNull);
      expect(root.workers.single.endedAt, isNull);
      expect(root.workers.single.logAvailable, isFalse);
      expect(root.workers.single.compaction!.beforeTokens, 102400);
      expect(root.workers.single.compaction!.afterTokens, 24000);
      expect(
        root.workers.single.compaction!.checkpointId,
        'checkpoint-worker-1',
      );
      expect(
        root.workers.single.compaction!.continuation,
        'continuing_existing_task',
      );
      expect(
        root.mainSteps.where((s) => s.type == 'subagent_compacted'),
        isEmpty,
      );
      expect(workerRuntimeDuration(root.workers.single), isNull);
      expect(root.counts.total, 7);
      expect(root.counts.running, 1);
      expect(root.counts.awaitingNextUserTask, 2);
      expect(root.counts.completed, 1);
      expect(root.counts.failed, 1);
      expect(root.counts.cancelled, 1);
      expect(root.counts.timeout, 1);
    },
  );

  test('mid-page orphan and completion merge by session and sequence', () {
    final completion = _event('20', 'subagent_completed', <String, dynamic>{
      'runId': 'root-run',
      'rootTaskRunId': 'root-run',
      'childRunId': 'child-run',
      'childSessionId': 'child-session',
      'logicalWorkerId': 'logical-worker',
      'attemptId': 'attempt-1',
      'agentType': 'researcher',
      'endedAt': '2026-10-24T12:20:00.000Z',
      'status': 'failed',
      'summary': 'Partial result; completion is unverified.',
      'logAvailable': false,
    }, ts: '2026-10-24T12:20:00.000Z');
    final duplicate = _event('20', 'subagent_completed', <String, dynamic>{
      ...((completion['payload'] as Map).cast<String, dynamic>()),
      'summary': 'This duplicate sequence must not replace the first event.',
    }, ts: '2026-10-24T12:20:00.000Z');
    final root = foldTrajectoryPages([
      <String, dynamic>{
        'events': <Map<String, dynamic>>[completion],
      },
      <String, dynamic>{
        'events': <Map<String, dynamic>>[
          duplicate,
          _event('21', 'tool_completed', <String, dynamic>{
            'runId': 'root-run',
            'callId': 'call-21',
            'name': 'read',
            'content': 'ok',
          }),
        ],
      },
    ]);

    expect(root.workers, hasLength(1));
    final worker = root.workers.single;
    expect(worker.logicalWorkerId, 'logical-worker');
    expect(worker.childRunId, 'child-run');
    expect(worker.childSessionId, 'child-session');
    expect(worker.startKnown, isFalse);
    expect(worker.startedAt, isNull);
    expect(worker.rootTaskRunId, 'root-run');
    expect(worker.parentRunId, 'root-run');
    expect(worker.summary, 'Partial result; completion is unverified.');
    expect(worker.status, 'failed');
    expect(workerRuntimeDuration(worker), isNull);
    expect(root.mainSteps.map((step) => step.seq), <String>['20', '21']);
    expect(root.mainSteps.where((step) => step.seq == '20'), hasLength(1));
  });

  test(
    'later start and completion-during-expansion preserve actual lineage',
    () {
      final root = foldTrajectoryPages([
        <String, dynamic>{
          'events': <Map<String, dynamic>>[
            _event('8', 'subagent_completed', <String, dynamic>{
              'childRunId': 'child-run',
              'childSessionId': 'child-session',
              'status': 'completed',
              'summary': 'done',
            }, ts: '2026-10-24T12:20:00.000Z'),
          ],
        },
        <String, dynamic>{
          'events': <Map<String, dynamic>>[
            _event('2', 'subagent_admitted', <String, dynamic>{
              'runId': 'root-run',
              'rootTaskRunId': 'root-run',
              'childRunId': 'child-run',
              'childSessionId': 'child-session',
              'logicalWorkerId': 'logical-worker',
              'attemptId': 'attempt-1',
              'deferredRequestId': 'deferred-1',
              'requestedAt': '2026-10-24T12:00:00.000Z',
              'admittedAt': '2026-10-24T12:04:00.000Z',
              'startedAt': null,
              'schedulingReason': 'Selected after the next user task',
            }),
            _event('3', 'subagent_started', <String, dynamic>{
              'runId': 'root-run',
              'rootTaskRunId': 'root-run',
              'childRunId': 'child-run',
              'childSessionId': 'child-session',
              'logicalWorkerId': 'logical-worker',
              'attemptId': 'attempt-1',
              'attemptNumber': 1,
              'agentType': 'researcher',
              'requestedAt': '2026-10-24T12:00:00.000Z',
              'admittedAt': '2026-10-24T12:04:00.000Z',
              'startedAt': '2026-10-24T12:05:00.000Z',
              'status': 'running',
              'launchReason': 'Independent research',
              'prompt': 'Read the canonical contracts',
              'logAvailable': false,
            }),
          ],
        },
      ]);

      final worker = root.workers.single;
      expect(worker.startKnown, isTrue);
      expect(worker.logicalWorkerId, 'logical-worker');
      expect(worker.attemptId, 'attempt-1');
      expect(worker.attemptNumber, 1);
      expect(worker.rootTaskRunId, 'root-run');
      expect(worker.requestedAt, DateTime.utc(2026, 10, 24, 12));
      expect(worker.admittedAt, DateTime.utc(2026, 10, 24, 12, 4));
      expect(worker.startedAt, DateTime.utc(2026, 10, 24, 12, 5));
      expect(worker.endedAt, isNotNull);
      expect(worker.status, 'completed');
      expect(worker.launchReason, 'Independent research');
      expect(worker.schedulingReason, 'Selected after the next user task');
      expect(worker.prompt, 'Read the canonical contracts');
    },
  );

  test(
    'admission exposes real child IDs without inventing an execution start',
    () {
      final root = foldTrajectoryPages([
        _deferredFixture(),
        <String, dynamic>{
          'events': <Map<String, dynamic>>[
            _event('4', 'subagent_admitted', <String, dynamic>{
              'runId': 'root-1',
              'rootTaskRunId': 'root-1',
              'logicalWorkerId': 'worker-1',
              'deferredRequestId': 'deferred-1',
              'childSessionId': 'child-after-admission',
              'childRunId': 'run-after-admission',
              'requestedAt': '2026-10-24T12:00:00.000Z',
              'admittedAt': '2026-10-24T12:05:00.000Z',
              'startedAt': null,
              'logAvailable': false,
            }),
          ],
        },
      ]);

      final worker = root.workers.single;
      expect(worker.status == 'running', isTrue);
      expect(worker.childSessionId, 'child-after-admission');
      expect(worker.childRunId, 'run-after-admission');
      expect(worker.admittedAt, DateTime.utc(2026, 10, 24, 12, 5));
      expect(worker.startedAt, isNull);
      expect(worker.startKnown, isFalse);
      expect(worker.hasTranscript, isTrue);
      expect(workerRuntimeDuration(worker), isNull);
      expect(workerDeferredAge(worker), isNull);
    },
  );

  test(
    'deferred age stays separate from actual runtime and no timeout is inferred',
    () {
      final root = foldTrajectoryPages([_deferredFixture()]);
      final worker = root.workers.single;
      final now = DateTime.utc(2026, 10, 24, 13);

      expect(
        workerDeferredAge(worker, now: now),
        const Duration(minutes: 59, seconds: 59),
      );
      expect(workerRuntimeDuration(worker, now: now), isNull);

      final running = foldTrajectoryPages([
        <String, dynamic>{
          'workers': <Map<String, dynamic>>[
            <String, dynamic>{
              'logicalWorkerId': 'worker-running',
              'status': 'running',
              'startedAt': '2026-10-24T04:00:00.000Z',
              'startKnown': true,
              'logAvailable': null,
            },
          ],
        },
      ]).workers.single;
      expect(running.status, 'running');
      expect(
        workerRuntimeDuration(running, now: now),
        const Duration(hours: 9),
      );
      expect(workerDeferredAge(running, now: now), isNull);
      expect(running.logAvailable, isNull);
    },
  );

  test('runtime stays unknown without start evidence', () {
    final worker = TrajectoryWorker(
      logicalWorkerId: 'worker-unproven',
      status: 'running',
      startedAt: DateTime.utc(2026, 10, 24, 12),
      startKnown: false,
    );
    expect(
      workerRuntimeDuration(worker, now: DateTime.utc(2026, 10, 24, 13)),
      isNull,
    );
    final running = TrajectoryWorker(
      logicalWorkerId: 'worker-proven',
      status: 'running',
      startedAt: DateTime.utc(2026, 10, 24, 12),
      startKnown: true,
    );
    expect(
      workerRuntimeDuration(running, now: DateTime.utc(2026, 10, 24, 13)),
      const Duration(hours: 1),
    );
  });

  test(
    'full steps stay chronological and render only unknown values as dashes',
    () {
      final root = foldTrajectoryPages([
        <String, dynamic>{
          'steps': <Map<String, dynamic>>[
            <String, dynamic>{
              'cursor': 'cursor-2',
              'sessionId': 'session-1',
              'runId': 'root-run',
              'seq': '2',
              'actorKind': 'main',
              'kind': 'model',
              'type': 'message_completed',
              'ts': '2026-10-24T12:02:00.000Z',
              'prompt': null,
              'output': 'Second step',
              'evidence': null,
              'files': null,
              'diffs': null,
              'artifacts': null,
              'preview': null,
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
            <String, dynamic>{
              'cursor': 'cursor-1',
              'sessionId': 'session-1',
              'runId': 'root-run',
              'seq': '1',
              'actorKind': 'main',
              'kind': 'tool',
              'type': 'tool_completed',
              'ts': '2026-10-24T12:01:00.000Z',
              'prompt': 'Read input',
              'output': 'First step',
              'evidence': 'tool result',
              'files': <Map<String, dynamic>>[
                <String, dynamic>{'path': 'lib/a.dart', 'operation': 'write'},
              ],
              'diffs': <Map<String, dynamic>>[
                <String, dynamic>{'id': 'diff-1', 'diff': '+ actual change'},
              ],
              'artifacts': <Map<String, dynamic>>[
                <String, dynamic>{'artifactId': 'artifact-1'},
              ],
              'preview': null,
              'requestedModel': 'auto',
              'providerModel': 'fixture-large',
              'usage': <String, dynamic>{
                'inputTokens': 0,
                'outputTokens': 12,
                'cacheReadTokens': 3,
                'cacheWriteTokens': 0,
                'costUsd': 0,
              },
            },
          ],
        },
      ]);

      expect(root.mainSteps.map((step) => step.seq), <String>['1', '2']);
      final actual = root.mainSteps.first;
      expect(actual.filesLabel, 'lib/a.dart');
      expect(actual.diffsLabel, 'diff-1');
      expect(actual.artifactsLabel, 'artifact-1');
      expect(actual.requestedModelLabel, 'auto');
      expect(actual.providerModelLabel, 'fixture-large');
      expect(actual.usage.inputTokensLabel, '0');
      expect(actual.usage.outputTokensLabel, '12');
      expect(actual.usage.cacheReadTokensLabel, '3');
      expect(actual.usage.cacheWriteTokensLabel, '0');
      expect(actual.usage.costLabel, '0');

      final unknown = root.mainSteps.last;
      expect(unknown.filesLabel, '—');
      expect(unknown.diffsLabel, '—');
      expect(unknown.artifactsLabel, '—');
      expect(unknown.requestedModelLabel, '—');
      expect(unknown.providerModelLabel, '—');
      expect(unknown.usage.inputTokensLabel, '—');
      expect(unknown.usage.outputTokensLabel, '—');
      expect(unknown.usage.cacheReadTokensLabel, '—');
      expect(unknown.usage.cacheWriteTokensLabel, '—');
      expect(unknown.usage.costLabel, '—');
    },
  );

  test(
    'six-key reports are exact and five-key legacy mappings are rejected',
    () {
      final report = TrajectoryReport.fromJson(<String, dynamic>{
        'subagent_id': 'child-session',
        'status': 'failed',
        'files_modified': <String>['lib/a.dart'],
        'artifacts_created': <String>['artifact-1'],
        'key_findings': 'Bounded actual findings',
        'error_if_any': 'Unverified partial work',
      });

      expect(report.subagentId, 'child-session');
      expect(report.keyFindings, 'Bounded actual findings');
      expect(TrajectoryReport.keys, <String>{
        'subagent_id',
        'status',
        'files_modified',
        'artifacts_created',
        'key_findings',
        'error_if_any',
      });
      expect(
        () => TrajectoryReport.fromJson(<String, dynamic>{
          'subagent_id': 'child-session',
          'status': 'completed',
          'files_modified': <String>[],
          'artifacts_created': <String>[],
          'key_findings': <String>['legacy list'],
          'error_if_any': null,
        }),
        throwsFormatException,
      );
      expect(
        () => TrajectoryReport.fromJson(<String, dynamic>{
          'subagent_id': 'child-session',
          'status': 'completed',
          'files_modified': <String>[],
          'artifacts_created': <String>[],
          'key_findings': 'text',
          'error_if_any': null,
          'extra': true,
        }),
        throwsFormatException,
      );

      final root = foldTrajectoryPages([
        <String, dynamic>{
          'events': <Map<String, dynamic>>[
            _event('30', 'subagent_completed', <String, dynamic>{
              'childRunId': 'child-run',
              'childSessionId': 'child-session',
              'status': 'failed',
              'summary': 'failed',
              'structuredReport': <String, dynamic>{
                'subagent_id': 'child-session',
                'status': 'failed',
                'files_modified': <String>['lib/a.dart'],
                'artifacts_created': <String>['artifact-1'],
                'key_findings': 'Bounded actual findings',
                'error_if_any': 'Unverified partial work',
              },
            }),
          ],
        },
      ]);
      expect(root.workers.single.report, isNotNull);
      expect(
        root.workers.single.report!.keyFindings,
        'Bounded actual findings',
      );
    },
  );

  test(
    'main compaction is diagnostics-only and worker metadata has no thoughts',
    () {
      final mainEvent = _event('40', 'compaction_completed', <String, dynamic>{
        'type': 'compaction_completed',
        'actorKind': 'main',
        'sessionId': 'session-1',
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
        'thoughts': 'must never be projected',
      });
      final root = foldTrajectoryPages([
        <String, dynamic>{
          'events': <Map<String, dynamic>>[mainEvent],
        },
        _deferredFixture(),
        _compactionFixture(),
      ]);

      expect(root.mainSteps, isEmpty);
      expect(root.diagnostics.single.actorKind, 'main');
      expect(root.diagnostics.single.compactionId, 'compaction-main-1');
      expect(root.workers.single.compaction!.model, 'fixture-large');
      expect(
        root.workers.single.compaction!.toJson().containsKey('thoughts'),
        isFalse,
      );
      expect(
        root.workers.single.compaction!.toJson().containsKey('cutoffCursor'),
        isFalse,
      );
    },
  );

  test(
    'raw owner view redacts PAT keys and signed URL canaries recursively',
    () {
      // Deliberately assembled at runtime: no credential-shaped literal is
      // persisted in this test, source, command lines, or successful logs.
      final pat = <String>['github', 'pat', 'fixture', 'canary'].join('_');
      final signedUrl = Uri(
        scheme: 'https',
        host: 'objects.example.invalid',
        path: '/history.json',
        queryParameters: <String, String>{'X-Amz-Signature': pat},
      ).toString();
      final secondPat = <String>['github', 'pat', 'other', 'canary'].join('_');
      final secretObject = <String, dynamic>{
        'authorization': 'Bearer $pat',
        pat: 'secret-bearing property name',
        secondPat: 'second secret property value',
        'nested': <String, dynamic>{'download': signedUrl},
        'providerBaseUrl': 'https://provider.example.invalid/v1',
      };
      final page = RawTrajectoryPage.fromJson(<String, dynamic>{
        'chunks': <Map<String, dynamic>>[
          <String, dynamic>{
            'item': <String, dynamic>{
              'stableId': 'raw-1',
              'kind': 'compaction',
              'sessionId': 'session-1',
              'rootTaskRunId': 'root-main',
              'logicalWorkerId': null,
              'attemptId': 'attempt-main',
              'eventCursor': '40',
              'inlinePayload': secretObject,
              'byteLength': 100,
            },
            'offset': 0,
            'data': jsonEncode(secretObject),
            'nextOffset': null,
          },
        ],
        'nextCursor': 'raw-next',
        'truncated': true,
      });

      final projected = page.displayText;
      expect(projected.contains(pat), isFalse);
      expect(projected.contains(secondPat), isFalse);
      expect(projected.contains('secret-bearing property name'), isTrue);
      expect(projected.contains('second secret property value'), isTrue);
      expect(projected.contains('X-Amz-Signature'), isFalse);
      expect(projected.contains('provider.example.invalid'), isFalse);
      expect(projected.contains('[redacted]'), isTrue);
      expect(page.nextCursor, 'raw-next');
      expect(page.truncated, isTrue);

      final credentialIdentifiers = RawTrajectoryPage.fromJson(
        <String, dynamic>{
          'items': <Map<String, dynamic>>[
            <String, dynamic>{'id': signedUrl, 'value': 'safe'},
          ],
          'nextCursor': pat,
        },
      );
      // Boolean assertions keep even a failing redaction test from printing the
      // generated canary into evidence logs.
      expect(credentialIdentifiers.nextCursor == null, isTrue);
      expect(credentialIdentifiers.entries.single.id == 'raw-0', isTrue);
      expect(credentialIdentifiers.displayText.contains(pat), isFalse);
      expect(
        credentialIdentifiers.displayText.contains('X-Amz-Signature'),
        isFalse,
      );
    },
  );

  test('second raw redactor closes token JWT cookie header and thought gaps', () {
    final jwt = <String>[
      'eyJ',
      'header',
      'payload',
      'signature',
    ].map((part) => '${part}Value').join('.');
    final page = RawTrajectoryPage.fromJson(<String, dynamic>{
      'items': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'sensitive-fixture',
          'value': <String, dynamic>{
            'sessionToken': 'session-secret',
            'X-Figma-Token': 'figma-secret',
            'ordinaryJwt': jwt,
            'headers':
                'Cookie: cookie-secret\nX-Figma-Token: figma-secret\nAuthorization: Bearer bearer-secret',
            'thoughts': 'private thought',
            'reasoning': 'private reasoning',
            'ordinary': 'keep this text',
          },
        },
      ],
      'nextCursor': null,
    });

    final projected = page.displayText;
    expect(projected.contains('session-secret'), isFalse);
    expect(projected.contains('figma-secret'), isFalse);
    expect(projected.contains(jwt), isFalse);
    expect(projected.contains('cookie-secret'), isFalse);
    expect(projected.contains('bearer-secret'), isFalse);
    expect(projected.contains('private thought'), isFalse);
    expect(projected.contains('private reasoning'), isFalse);
    expect(projected.contains('ordinary'), isTrue);
    expect(projected.contains('keep this text'), isTrue);
    expect(projected.contains('[redacted]'), isTrue);
  });

  test('fragmented canonical raw chunks fail closed without showing slices', () {
    String jwtPart(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final jwt =
        '${jwtPart(<String, dynamic>{'alg': 'none', 'typ': 'JWT'})}.'
        '${jwtPart(<String, dynamic>{'sub': 'fixture-user'})}.'
        '${base64Url.encode(utf8.encode('fixture-signature')).replaceAll('=', '')}';
    final fragments = <String>[
      '{"sessionToken":"session-secret",',
      '"thoughts":"private-thought",',
      '"headers":"Cookie: cookie-secret\\nX-Figma-Token: figma-secret",',
      '"splitCanary":"split-',
      'secret"}',
    ];
    Map<String, dynamic> item() => <String, dynamic>{
      'stableId': 'fragmented-1',
      'kind': 'tool_call',
      'sessionId': 'session-1',
      'rootTaskRunId': 'root-1',
      'logicalWorkerId': null,
      'attemptId': null,
      'eventCursor': 'cursor-1',
      'objectRef': 'objects/exact/1',
      'byteLength': 100,
    };
    Map<String, dynamic> chunk(int offset, String data, int? nextOffset) =>
        <String, dynamic>{
          'item': item(),
          'offset': offset,
          'data': data,
          'nextOffset': nextOffset,
        };
    final page = RawTrajectoryPage.fromJson(<String, dynamic>{
      'chunks': <Map<String, dynamic>>[
        for (var i = 0; i < fragments.length; i++)
          chunk(i, fragments[i], i + 1),
        chunk(90, jsonEncode(<String, dynamic>{'jwt': jwt}), 91),
        chunk(91, jsonEncode('"sessionToken":"primitive-secret"'), 92),
        chunk(92, jsonEncode(<String, dynamic>{'ordinary': 'keep'}), null),
      ],
      'nextCursor': 'raw-next',
      'truncated': true,
    });

    final projected = page.displayText;
    for (final secret in <String>[
      'session-secret',
      'private-thought',
      'cookie-secret',
      'figma-secret',
      'split-secret',
      'primitive-secret',
      jwt,
    ]) {
      expect(projected.contains(secret), isFalse);
    }
    final withheld = page.entries.where((entry) {
      final value = entry.value;
      return value is Map && value['withheld'] == true;
    }).toList();
    expect(withheld, hasLength(fragments.length + 1));
    for (final entry in withheld) {
      expect((entry.value as Map)['data'], isNull);
    }
    expect(projected.contains('withheld'), isTrue);
    expect(projected.contains('ordinary'), isTrue);
    expect(projected.contains('keep'), isTrue);
    expect(projected.contains('raw-next'), isTrue);
    expect(projected.contains('truncated'), isTrue);
  });

  test(
    'complete JSON redacts exact sensitive primitives and fragmented slices stay withheld',
    () {
      const jwt = 'eyJhbGciOiJub25lIn0.eyJzdWIiOiJmaXh0dXJlIn0.c2lnbmF0dXJl';
      final firstPat = <String>['github', 'pat', 'first', 'canary'].join('_');
      final secondPat = <String>['github', 'pat', 'second', 'canary'].join('_');
      Map<String, dynamic> item() => <String, dynamic>{
        'stableId': 'complete-1',
        'kind': 'message',
        'sessionId': 'session-1',
        'rootTaskRunId': 'root-1',
        'logicalWorkerId': null,
        'attemptId': null,
        'eventCursor': 'cursor-1',
        'inlinePayload': <String, dynamic>{'safe': true},
        'byteLength': 100,
      };
      Map<String, dynamic> chunk(int offset, Object? data, int? nextOffset) =>
          <String, dynamic>{
            'item': item(),
            'offset': offset,
            'data': data,
            'nextOffset': nextOffset,
          };
      final complete = <String, dynamic>{
        'thought': 'private-singular-thought',
        'privateThought': 'private-camel-thought',
        'inputTokens': 42,
        'nested': <Object?>[
          <String, dynamic>{'token': 'primitive-token'},
          <Object?>['"sessionToken":"primitive-session"', jwt],
        ],
        firstPat: 'first secret property value',
        secondPat: 'second secret property value',
        'ordinary': 'keep this content',
      };
      final page = RawTrajectoryPage.fromJson(<String, dynamic>{
        'chunks': <Map<String, dynamic>>[
          chunk(0, jsonEncode(complete), 1),
          chunk(1, jsonEncode('"token":"primitive-token"'), 2),
          chunk(2, jsonEncode('"sessionToken":"primitive-session"'), 3),
          chunk(3, jsonEncode(jwt), 4),
          chunk(4, jsonEncode('"inputTokens":7'), 5),
          chunk(5, '{"thought":"fragment-secret"', 6),
          chunk(6, jsonEncode(<String, dynamic>{'ordinary': 'keep'}), null),
        ],
        'nextCursor': 'raw-next',
        'truncated': true,
      });

      final completeData = (page.entries[0].value as Map)['data'] as String;
      final projected = jsonDecode(completeData) as Map<String, dynamic>;
      expect(projected['thought'], '[redacted]');
      expect(projected['privateThought'], '[redacted]');
      expect(projected['inputTokens'], 42);
      expect(projected['nested'][0], <String, dynamic>{'token': '[redacted]'});
      expect(projected['nested'][1], <Object?>['[redacted]', '[redacted]']);
      expect(
        projected.keys.where((key) => key.startsWith('[redacted]')),
        hasLength(2),
      );
      expect(projected['ordinary'], 'keep this content');

      final token = page.entries[1].value as Map;
      final session = page.entries[2].value as Map;
      final primitiveJwt = page.entries[3].value as Map;
      final benignCount = page.entries[4].value as Map;
      final fragment = page.entries[5].value as Map;
      expect(token['withheld'], isTrue);
      expect(token['data'], isNull);
      expect(session['withheld'], isTrue);
      expect(session['data'], isNull);
      expect(jsonDecode(primitiveJwt['data'] as String), '[redacted]');
      expect(benignCount['withheld'], isNull);
      expect(jsonDecode(benignCount['data'] as String), '"inputTokens":7');
      expect(fragment['withheld'], isTrue);
      expect(fragment['data'], isNull);

      final display = page.displayText;
      for (final secret in <String>[
        jwt,
        firstPat,
        secondPat,
        'primitive-token',
        'primitive-session',
        'private-singular-thought',
        'private-camel-thought',
        'fragment-secret',
      ]) {
        expect(display.contains(secret), isFalse);
      }
      expect(display.contains('keep this content'), isTrue);
      expect(display.contains('ordinary'), isTrue);
      expect(display.contains('raw-next'), isTrue);
      expect(display.contains('truncated'), isTrue);
    },
  );

  test(
    'normalized sensitive keys and embedded encoded signed URLs never project',
    () {
      final exactCredential = <String>[
        'fixture',
        'exact',
        'credential',
      ].join('-');
      final signedCredential = <String>[
        'fixture',
        'signed',
        'credential',
      ].join('-');
      final signedUrl = Uri(
        scheme: 'https',
        host: 'objects.example.invalid',
        path: '/history.json',
        queryParameters: <String, String>{
          'safe': 'retained',
          'X-Amz-Signature': Uri.encodeQueryComponent(signedCredential),
        },
      ).toString();
      final embedded = 'Before $signedUrl after';
      final encoded = Uri.encodeComponent(signedUrl);
      final page = RawTrajectoryPage.fromJson(<String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'sensitive-fixture',
            'value': <String, dynamic>{
              'x-api-key': exactCredential,
              'client_secret': exactCredential,
              'nested': <Object?>[
                <String, dynamic>{'note': embedded},
                <String, dynamic>{'encoded': encoded},
              ],
              'ordinary': 'keep this text',
            },
          },
        ],
        'nextCursor': null,
      });

      final projected = page.displayText;
      // Never print either generated credential in an assertion failure.
      expect(projected.contains(exactCredential), isFalse);
      expect(projected.contains(signedCredential), isFalse);
      expect(projected.contains('X-Amz-Signature'), isFalse);
      expect(projected.contains('ordinary'), isTrue);
      expect(projected.contains('keep this text'), isTrue);
      expect(projected.contains('Before'), isTrue);
      expect(projected.contains('after'), isTrue);
      expect(projected.contains('safe=retained'), isTrue);
      expect(projected.contains('[redacted]'), isTrue);
      expect(jsonDecode(projected), isA<Map<String, dynamic>>());
    },
  );

  test(
    'shared fixture correlates requested deferred admitted and started without a phantom',
    () {
      final decoded =
          jsonDecode(
                File(
                  'test/fixtures/contracts/subagents-v1.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final events = <Map<String, dynamic>>[
        for (var i = 0; i < (decoded['events'] as List).length; i++)
          <String, dynamic>{
            'sessionId': 'session-1',
            'seq': '${i + 1}',
            'type': (decoded['events'] as List)[i]['type'] as String,
            'ts': '2026-10-24T12:00:${i.toString().padLeft(2, '0')}.000Z',
            'payload': Map<String, dynamic>.from(
              (decoded['events'] as List)[i] as Map,
            ),
          },
      ];

      final root = foldTrajectoryPages([
        <String, dynamic>{'events': events},
      ]);

      // One real worker plus the separately controlled worker. The unaliased
      // requested event must not become a third, parentless phantom row.
      expect(root.workers, hasLength(2));
      final worker = root.workers
          .where((row) => row.childSessionId == 'worker-1')
          .single;
      expect(worker.logicalWorkerId, 'worker-1');
      expect(worker.deferredRequestId, 'deferred-1');
      expect(worker.childRunId, 'child-run-1');
      expect(worker.startedAt, DateTime.utc(2026, 10, 24, 12, 5, 1));
      expect(worker.status, 'completed');
      expect(
        root.workers.any((row) => row.childSessionId == 'worker-3'),
        isTrue,
      );
    },
  );

  test('producer completion without runId remains in main chronology', () {
    final decoded =
        jsonDecode(
              File(
                'test/fixtures/contracts/subagents-v1.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final legacy = Map<String, dynamic>.from(
      (decoded['legacyCurrentEmissions'] as Map)['completed'] as Map,
    );
    expect(legacy.containsKey('runId'), isFalse);
    final root = foldTrajectoryPages([
      <String, dynamic>{
        'events': <Map<String, dynamic>>[
          _event('90', 'subagent_completed', legacy),
        ],
      },
    ]);

    expect(root.mainSteps.map((step) => step.type), <String>[
      'subagent_completed',
    ]);
    expect(root.mainSteps.single.actorKind, 'main');
    expect(root.mainSteps.single.kind, 'subagent');
    expect(root.mainSteps.single.runId, isEmpty);
    expect(root.workers.single.startKnown, isFalse);
    expect(root.workers.single.parentRunId, isNull);
    expect(root.workers.single.steps, isEmpty);
  });

  test('real start evidence overrides stale summary startKnown false', () {
    final started = _event('2', 'subagent_started', <String, dynamic>{
      'runId': 'root-1',
      'rootTaskRunId': 'root-1',
      'logicalWorkerId': 'worker-1',
      'childSessionId': 'child-1',
      'childRunId': 'child-run-1',
      'requestedAt': '2026-10-24T12:00:00.000Z',
      'admittedAt': '2026-10-24T12:00:30.000Z',
      'startedAt': '2026-10-24T12:01:00.000Z',
      'status': 'running',
      'prompt': 'preview',
    }, ts: '2026-10-24T12:01:00.000Z');
    final root = foldTrajectoryPages([
      <String, dynamic>{
        'workers': <Map<String, dynamic>>[
          <String, dynamic>{
            'logicalWorkerId': 'worker-1',
            'childSessionId': 'child-1',
            'childRunId': 'child-run-1',
            'status': 'running',
            'startKnown': false,
          },
        ],
      },
      <String, dynamic>{
        'events': <Map<String, dynamic>>[started],
      },
      <String, dynamic>{
        'workers': <Map<String, dynamic>>[
          <String, dynamic>{
            'logicalWorkerId': 'worker-1',
            'status': 'running',
            'startKnown': false,
          },
        ],
      },
    ]);

    expect(root.workers.single.startedAt, DateTime.utc(2026, 10, 24, 12, 1));
    expect(root.workers.single.startKnown, isTrue);
  });

  test(
    'legacy real start without timestamp survives stale summaries without inventing runtime',
    () {
      final decoded =
          jsonDecode(
                File(
                  'test/fixtures/contracts/subagents-v1.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final legacy = Map<String, dynamic>.from(
        (decoded['legacyCurrentEmissions'] as Map)['started'] as Map,
      );
      expect(legacy.containsKey('startedAt'), isFalse);

      Map<String, dynamic> staleSummary() => <String, dynamic>{
        'workers': <Map<String, dynamic>>[
          <String, dynamic>{
            'childSessionId': 'child-session',
            'childRunId': 'child-run',
            'status': 'running',
            'startKnown': false,
            'startedAt': null,
          },
        ],
      };
      final root = foldTrajectoryPages([
        staleSummary(),
        <String, dynamic>{
          'events': <Map<String, dynamic>>[
            _event('2', 'subagent_started', legacy),
          ],
        },
        staleSummary(),
      ]);

      final worker = root.workers.single;
      expect(worker.parentRunId, 'parent-run');
      expect(worker.startKnown, isTrue);
      expect(worker.startedAt, isNull);
      expect(
        workerRuntimeDuration(worker, now: DateTime.utc(2026, 10, 24, 13)),
        isNull,
      );
    },
  );

  test('parent lifecycle sequence never advances a child stream cursor', () {
    final root = foldTrajectoryPages([
      <String, dynamic>{
        'workers': <Map<String, dynamic>>[
          <String, dynamic>{
            'logicalWorkerId': 'worker-1',
            'childSessionId': 'child-session',
            'childRunId': 'child-run',
            'status': 'running',
            'startKnown': true,
            'startedAt': '2026-10-24T12:00:05.000Z',
            'lastCursor': 'child-stream-4',
          },
        ],
      },
      <String, dynamic>{
        'events': <Map<String, dynamic>>[
          _event('10', 'subagent_started', <String, dynamic>{
            'runId': 'root-run',
            'logicalWorkerId': 'worker-1',
            'childSessionId': 'child-session',
            'childRunId': 'child-run',
            'startedAt': '2026-10-24T12:00:05.000Z',
          }),
          _event('11', 'subagent_completed', <String, dynamic>{
            'runId': 'root-run',
            'logicalWorkerId': 'worker-1',
            'childSessionId': 'child-session',
            'childRunId': 'child-run',
            'status': 'completed',
            'endedAt': '2026-10-24T12:10:05.000Z',
          }),
          _event('12', 'subagent_compacted', <String, dynamic>{
            'runId': 'child-run',
            'workerId': 'worker-1',
            'compactionId': 'compaction-1',
            'checkpointId': 'checkpoint-1',
            'model': 'fixture',
            'contextLimit': 128000,
            'beforeTokens': 102400,
            'afterTokens': 24000,
            'usageSource': 'measured',
            'continuation': 'continuing_existing_task',
          }),
        ],
      },
    ]);

    final worker = root.workers.single;
    expect(worker.logicalWorkerId, 'worker-1');
    expect(worker.lastCursor, 'child-stream-4');
    expect(worker.lastCursor, isNot(anyOf('10', '11', '12')));
  });
}
