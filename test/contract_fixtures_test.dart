import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> fixture(String name) {
  final raw = File('test/fixtures/contracts/$name.json').readAsStringSync();
  return (jsonDecode(raw) as Map).cast<String, dynamic>();
}

List<Map<String, dynamic>> maps(Object? value) => (value! as List)
    .map((entry) => (entry as Map).cast<String, dynamic>())
    .toList();

void expectNoProgress95(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      expect(
        entry.key == 'progress' && entry.value == 95,
        isFalse,
        reason: 'A fixture must not invent 95 percent progress',
      );
      expectNoProgress95(entry.value);
    }
  } else if (value is List) {
    for (final entry in value) {
      expectNoProgress95(entry);
    }
  }
}

void main() {
  group('shared attachment and connection fixtures', () {
    test('legacy attachment requests remain valid beside typed signed uploads', () {
      final attachments = fixture('attachments-v1');
      expect(attachments['contractVersion'], 1);
      final create = (attachments['create'] as Map).cast<String, dynamic>();
      expect((create['legacy'] as Map).keys, ['name', 'size']);
      expect((create['typed'] as Map)['contentType'], 'application/pdf');
      final responses =
          (attachments['uploadResponses'] as Map).cast<String, dynamic>();
      expect((responses['legacy'] as Map).containsKey('contentType'), isFalse);
      expect(
        (responses['typed'] as Map)['uploadHeaders'],
        {'Content-Type': 'application/pdf'},
      );
    });

    test('legacy server arrays and configured envelopes remain distinct', () {
      final connections = fixture('connections-v1');
      expect(connections['legacyListResponse'], isA<List>());
      final configured =
          (connections['configuredResponse'] as Map).cast<String, dynamic>();
      final items = maps(configured['items']);
      expect(items.single['providerId'], 'google-drive');
      expect(items.single['agentEnabled'], isFalse);
      expect(items.single['healthState'], 'never_checked');
      expect(items.single.containsKey('plaintextSecret'), isFalse);
    });
  });

  group('versioned MCP connection fixtures', () {
    test('stable state and approved source metadata contain no secret or config payloads', () {
      final connections = fixture('mcp-connections-v1');
      expect(connections['contractVersion'], 1);
      final items = maps(connections['items']);
      expect(items, hasLength(2));
      final configured = items[0];
      expect(configured['connectionId'], '019a0000-0000-7000-8000-000000000001');
      expect(configured['providerId'], 'google-drive');
      expect(configured['userId'], 'fixture-user');
      expect(configured['agentEnabled'], isFalse);
      expect(configured['authState'], 'configured');
      expect(configured['healthState'], 'never_checked');
      expect(configured['configVersion'], 1);
      expect(configured['disconnectGeneration'], 0);
      final revoked = items[1];
      expect(revoked['authState'], 'revoked');
      expect(revoked['healthState'], 'revoked');
      expect(revoked['approvedSourceId'], 'source-fixture');
      expect(revoked['approvedDigest'], 'sha256:approved-fixture');
      for (final item in items) {
        for (final forbidden in [
          'config',
          'secrets',
          'secretsSealed',
          'secrets_sealed',
          'authorization',
          'refreshToken',
          'id',
          'curatedId',
        ]) {
          expect(item.containsKey(forbidden), isFalse, reason: 'forbidden $forbidden');
        }
      }
    });
  });

  group('shared subagent fixtures', () {
    test('all lifecycle examples and exactly six report keys are present', () {
      final subagents = fixture('subagents-v1');
      final events = maps(subagents['events']);
      expect(
        events.map((event) => event['type']),
        [
          'subagent_requested',
          'subagent_deferred',
          'subagent_admitted',
          'subagent_started',
          'subagent_controlled',
          'subagent_completed',
          'root_finalized',
        ],
      );
      final legacy =
          (subagents['legacyCurrentEmissions'] as Map).cast<String, dynamic>();
      expect(legacy['started'], {
        'runId': 'parent-run',
        'childSessionId': 'child-session',
        'childRunId': 'child-run',
        'prompt': 'Inspect the current contract fixture',
        'agentType': 'general-purpose',
      });
      expect(legacy['completed'], {
        'childRunId': 'child-run',
        'status': 'completed',
        'childSessionId': 'child-session',
        'agentType': 'general-purpose',
        'summary': 'child answer',
      });
      expect((legacy['started'] as Map).containsKey('batchId'), isFalse);
      expect(
        (legacy['completed'] as Map).containsKey('structuredReport'),
        isFalse,
      );
      expect(events[0].containsKey('childRunId'), isFalse);
      expect(events[0].containsKey('childSessionId'), isFalse);
      expect(events[1]['childRunId'], isNull);
      expect(events[1]['childSessionId'], isNull);
      for (final report in maps(subagents['terminalReports'])) {
        expect(report.keys, hasLength(6));
        expect(
          report.keys.toSet(),
          {
            'subagent_id',
            'status',
            'files_modified',
            'artifacts_created',
            'key_findings',
            'error_if_any',
          },
        );
        expect(report['key_findings'], isA<String>());
      }
    });

    test('ordinary and self-described urgent messages do not preempt', () {
      final subagents = fixture('subagents-v1');
      final scenarios = maps(subagents['nonPreemption']);
      expect(
        scenarios.map((scenario) => scenario['name']),
        ['ordinary', 'self-described-urgent'],
      );
      for (final scenario in scenarios) {
        expect(scenario['newRootAccepted'], isTrue);
        expect(scenario['rootCancelled'], isFalse);
        expect(scenario['executionEpochChanged'], isFalse);
        expect(scenario['cancelledWorkerIds'], isEmpty);
        expect(scenario['finalResponseEmitted'], isFalse);
      }
      expectNoProgress95(subagents);
    });
  });

  group('shared compaction fixtures', () {
    test('79 percent does not compact and 80 percent does for each model', () {
      final boundaries = maps(fixture('compaction-v1')['thresholdBoundaries']);
      expect(boundaries, hasLength(6));
      expect(
        boundaries.map((row) => row['contextLimit']).toSet(),
        {1000, 32000, 128000},
      );
      for (final row in boundaries) {
        final before = row['beforeTokens'] as int;
        final limit = row['contextLimit'] as int;
        expect(before * 100 >= limit * 80, row['shouldCompact']);
        expect(row['percent'], before * 100 / limit);
      }
    });

    test('worker/main metadata is operational and exact recall stays isolated', () {
      final compaction = fixture('compaction-v1');
      final main = (compaction['main'] as Map).cast<String, dynamic>();
      final worker = (compaction['worker'] as Map).cast<String, dynamic>();
      final mainEvent = (main['event'] as Map).cast<String, dynamic>();
      final workerEvent = (worker['event'] as Map).cast<String, dynamic>();
      final diagnostics =
          (compaction['legacyDiagnostics'] as Map).cast<String, dynamic>();
      expect(diagnostics['withRunId'], {
        'type': 'compaction_completed',
        'sessionId': 'session-1',
        'runId': 'root-main',
        'folded': 12,
        'retained': 3,
        'narrative': true,
      });
      expect(
        (diagnostics['withoutRunId'] as Map).containsKey('runId'),
        isFalse,
      );
      final workerDiagnostic =
          (diagnostics['workerRichDiagnostic'] as Map).cast<String, dynamic>();
      expect(workerDiagnostic['actorKind'], 'worker');
      expect(workerDiagnostic['type'], 'compaction_completed');
      expect(workerEvent['type'], 'subagent_compacted');
      expect(workerEvent['continuation'], 'continuing_existing_task');
      expect(workerEvent.containsKey('thoughts'), isFalse);
      expect(mainEvent['actorKind'], 'main');
      expect(main['ordinaryChatEmitted'], isFalse);
      final mainCursor = (main['cursor'] as Map).cast<String, dynamic>();
      final workerCursor = (worker['cursor'] as Map).cast<String, dynamic>();
      expect(mainCursor['logicalWorkerId'], isNull);
      expect(workerCursor['logicalWorkerId'], 'worker-1');
      expect(mainCursor['compactionId'], isNot(workerCursor['compactionId']));
      for (final actor in [main, worker]) {
        final page = (actor['exactRecallPage'] as Map).cast<String, dynamic>();
        expect(page.keys.toSet(), {'chunks', 'nextCursor'});
        expect(page['nextCursor'], isNull);
        final chunks = maps(page['chunks']);
        expect(chunks, hasLength(2));
        expect(
          chunks.map((chunk) => (chunk['item'] as Map)['stableId']),
          [
            '${(actor['cursor'] as Map)['actorKind']}-message-1',
            '${(actor['cursor'] as Map)['actorKind']}-tool-1',
          ],
        );
        for (final chunk in chunks) {
          expect(chunk.keys.toSet(), {'item', 'offset', 'data', 'nextOffset'});
          expect(chunk['offset'], 0);
          expect(chunk['nextOffset'], isNull);
          expect(chunk['data'], isA<String>());
          final item = (chunk['item'] as Map).cast<String, dynamic>();
          expect(utf8.encode(chunk['data'] as String), hasLength(item['byteLength'] as int));
          expect(item['sessionId'], 'session-1');
          expect(item['rootTaskRunId'], (actor['cursor'] as Map)['rootTaskRunId']);
          expect(item['eventCursor'], isA<String>());
          expect(item.containsKey('payload'), isFalse);
          final payloadForms = ['inlinePayload', 'objectRef']
              .where(item.containsKey)
              .toList();
          expect(payloadForms, hasLength(1));
          expect(
            item.keys.toSet(),
            {
              'stableId',
              'kind',
              'sessionId',
              'rootTaskRunId',
              'logicalWorkerId',
              'attemptId',
              'eventCursor',
              'byteLength',
              payloadForms.single,
            },
          );
          if (payloadForms.single == 'inlinePayload') {
            expect(jsonDecode(chunk['data'] as String), item['inlinePayload']);
          } else {
            expect(item['objectRef'], isA<String>());
            expect(
              (jsonDecode(chunk['data'] as String) as Map)['toolCallId'],
              item['stableId'],
            );
          }
        }
      }
    });
  });
}
