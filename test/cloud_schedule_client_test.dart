// P8 Task 14 — ScheduleClient against the BUILT P4 REST routes.
//
// The wire shapes asserted here come from
//   cloud/apps/gateway/src/routes/schedules.ts
//   cloud/packages/shared/src/schedules.ts
//   cloud/packages/shared/src/triggers.ts
// — the server is the contract. Notable deviations from the plan sketch:
//   * GET /schedules is a Page<ScheduleDto> ({items,nextCursor}), not a list.
//   * trigger uses {kind, at|seconds|time+tz|expr+tz}, not everySeconds/dailyAt/cron.
//   * lastResult is {status,code,message,finishedAt,ranLate}; no `summary`.
//   * runs are {id,scheduleId,scheduledFor,runId,status,attempt,ranLate,error,
//     startedAt,finishedAt}; no `summary`.
//   * DELETE answers 204 with an empty body.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/schedule_client.dart';

const String _base = 'https://cloud.test/cloud/v1';

Map<String, dynamic> _scheduleJson({
  String id = 'sc1',
  String sessionId = 's1',
  String title = 'Morning brief',
  String description = 'Check the inbox and summarise',
  String status = 'pending',
  Map<String, dynamic>? trigger,
  Map<String, dynamic>? lastResult,
  int maxRetries = 1,
}) => {
      'id': id,
      'sessionId': sessionId,
      'title': title,
      'description': description,
      'trigger': trigger ??
          {'kind': 'daily_at', 'time': '09:00', 'tz': 'UTC'},
      'autonomy': 'safe',
      'status': status,
      'pausedReason': status == 'paused' ? 'user' : null,
      'maxRetries': maxRetries,
      'nextRunAt': '2026-10-18T09:00:00.000Z',
      'lastResult': lastResult,
      'createdAt': '2026-10-17T08:00:00.000Z',
      'updatedAt': '2026-10-17T08:05:00.000Z',
    };

Map<String, dynamic> _runJson({
  String id = 'run1',
  String status = 'succeeded',
  bool ranLate = false,
}) => {
      'id': id,
      'scheduleId': 'sc1',
      'scheduledFor': '2026-10-17T09:00:00.000Z',
      'runId': 'r1',
      'status': status,
      'attempt': 1,
      'ranLate': ranLate,
      'error': null,
      'startedAt': '2026-10-17T09:00:02.000Z',
      'finishedAt': '2026-10-17T09:00:30.000Z',
    };

String _page(List<Map<String, dynamic>> items, {String? nextCursor}) =>
    jsonEncode({'items': items, 'nextCursor': nextCursor});

String _error(String code, String message) =>
    jsonEncode({'error': {'code': code, 'message': message}});

class _Gateway {
  _Gateway(this.handler);

  final Future<http.Response> Function(http.Request request) handler;
  final List<http.Request> requests = [];

  CloudRestClient client() => CloudRestClient(
        httpClient: MockClient((request) {
          requests.add(request);
          return handler(request);
        }),
        headers: CloudHeaders.forTest(),
        restBase: _base,
      );
}

http.Response _json(Object body, [int status = 200]) => http.Response(
      body is String ? body : jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  group('list()', () {
    test('parses the camelCase Page and follows the cursor', () async {
      final gateway = _Gateway((request) async {
        final cursor = request.url.queryParameters['cursor'];
        if (cursor == null) {
          return _json(_page([_scheduleJson()], nextCursor: 'c2'));
        }
        expect(cursor, 'c2');
        return _json(_page([
          _scheduleJson(id: 'sc2', status: 'paused', title: 'Second'),
        ]));
      });
      final client = ScheduleClient(gateway.client());

      final schedules = await client.list();

      expect(schedules, hasLength(2));
      expect(schedules.first.id, 'sc1');
      expect(schedules.first.sessionId, 's1');
      expect(schedules.first.title, 'Morning brief');
      expect(schedules.first.description, 'Check the inbox and summarise');
      expect(schedules.first.trigger.kind, 'daily_at');
      expect(schedules.first.trigger.time, '09:00');
      expect(schedules.first.trigger.tz, 'UTC');
      expect(schedules.first.autonomy, 'safe');
      expect(schedules.first.status, 'pending');
      expect(schedules.first.maxRetries, 1);
      expect(schedules.first.nextRunAt, DateTime.utc(2026, 10, 18, 9));
      expect(schedules.last.id, 'sc2');
      expect(schedules.last.pausedReason, 'user');
      expect(gateway.requests, hasLength(2));
      expect(gateway.requests.first.url.path, '/cloud/v1/schedules');
      expect(gateway.requests.first.url.queryParameters['limit'], '100');
    });

    test('parses lastResult including the ran_late flag', () async {
      final gateway = _Gateway((_) async => _json(_page([
            _scheduleJson(
              lastResult: {
                'status': 'succeeded',
                'code': null,
                'message': 'Posted the digest',
                'finishedAt': '2026-10-17T09:03:00.000Z',
                'ranLate': true,
              },
            ),
          ])));
      final client = ScheduleClient(gateway.client());

      final schedule = (await client.list()).single;

      expect(schedule.lastResult, isNotNull);
      expect(schedule.lastResult!.status, 'succeeded');
      expect(schedule.lastResult!.message, 'Posted the digest');
      expect(schedule.lastResult!.ranLate, isTrue);
      expect(schedule.lastResult!.finishedAt, DateTime.utc(2026, 10, 17, 9, 3));
    });

    test('includeCancelled is sent only when requested', () async {
      final gateway = _Gateway((_) async => _json(_page([])));
      final client = ScheduleClient(gateway.client());

      await client.list();
      expect(
        gateway.requests.last.url.queryParameters.containsKey('includeCancelled'),
        isFalse,
      );

      await client.list(includeCancelled: true);
      expect(
        gateway.requests.last.url.queryParameters['includeCancelled'],
        'true',
      );
    });

    test('surfaces the gateway error envelope', () async {
      final gateway = _Gateway(
          (_) async => _json(_error('unauthenticated', 'Sign in.'), 401));
      final client = ScheduleClient(gateway.client());

      await expectLater(
        client.list(),
        throwsA(isA<CloudApiException>()
            .having((e) => e.status, 'status', 401)
            .having((e) => e.code, 'code', 'unauthenticated')),
      );
    });
  });

  group('create()', () {
    test('POSTs the built P4 body and parses the created DTO', () async {
      Map<String, dynamic>? body;
      final gateway = _Gateway((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/cloud/v1/schedules');
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return _json(_scheduleJson(id: 'new'), 201);
      });
      final client = ScheduleClient(gateway.client());

      final created = await client.create(
        title: 'Morning brief',
        description: 'Check the inbox and summarise',
        trigger: ScheduleTrigger.dailyAt('09:00', tz: 'UTC'),
        sessionId: 's1',
        maxRetries: 1,
      );

      expect(body, {
        'title': 'Morning brief',
        'description': 'Check the inbox and summarise',
        'trigger': {'kind': 'daily_at', 'time': '09:00', 'tz': 'UTC'},
        'autonomy': 'safe',
        'maxRetries': 1,
        'sessionId': 's1',
      });
      expect(created.id, 'new');
    });

    test('omits optional fields the server would reject as null', () async {
      Map<String, dynamic>? body;
      final gateway = _Gateway((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return _json(_scheduleJson(), 201);
      });
      final client = ScheduleClient(gateway.client());

      await client.create(
        title: 'One off',
        description: 'Do it once',
        trigger: ScheduleTrigger.at(DateTime.utc(2026, 12, 1, 9, 30)),
      );

      expect(body, {
        'title': 'One off',
        'description': 'Do it once',
        'trigger': {'kind': 'at', 'at': '2026-12-01T09:30:00.000Z'},
        'autonomy': 'safe',
        'maxRetries': 0,
      });
      expect(body!.containsKey('sessionId'), isFalse);
    });
  });

  group('update()', () {
    test('PATCHes only the provided fields', () async {
      Map<String, dynamic>? body;
      final gateway = _Gateway((request) async {
        expect(request.method, 'PATCH');
        expect(request.url.path, '/cloud/v1/schedules/sc1');
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return _json(_scheduleJson(status: 'paused'));
      });
      final client = ScheduleClient(gateway.client());

      final updated = await client.update('sc1', status: 'paused');

      expect(body, {'status': 'paused'});
      expect(updated.status, 'paused');
    });

    test('serialises a trigger patch with the server keys', () async {
      Map<String, dynamic>? body;
      final gateway = _Gateway((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return _json(_scheduleJson());
      });
      final client = ScheduleClient(gateway.client());

      await client.update(
        'sc1',
        trigger: ScheduleTrigger.every(3600),
        maxRetries: 2,
      );

      expect(body, {
        'trigger': {'kind': 'every', 'seconds': 3600},
        'maxRetries': 2,
      });
    });
  });

  group('delete()', () {
    test('DELETE accepts the 204 empty body', () async {
      final gateway = _Gateway((request) async {
        expect(request.method, 'DELETE');
        expect(request.url.path, '/cloud/v1/schedules/sc1');
        return http.Response('', 204);
      });
      final client = ScheduleClient(gateway.client());

      await client.delete('sc1');
    });

    test('DELETE surfaces a 404 envelope', () async {
      final gateway = _Gateway(
          (_) async => _json(_error('not_found', 'Schedule not found.'), 404));
      final client = ScheduleClient(gateway.client());

      await expectLater(
        client.delete('gone'),
        throwsA(isA<CloudApiException>()
            .having((e) => e.status, 'status', 404)
            .having((e) => e.code, 'code', 'not_found')),
      );
    });
  });

  group('runs()', () {
    test('parses the runs feed with the ran_late flag', () async {
      final gateway = _Gateway((request) async {
        expect(request.url.path, '/cloud/v1/schedules/sc1/runs');
        return _json(_page([
          _runJson(ranLate: true),
          _runJson(id: 'run2', status: 'failed'),
        ]));
      });
      final client = ScheduleClient(gateway.client());

      final runs = await client.runs('sc1');

      expect(runs, hasLength(2));
      expect(runs.first.id, 'run1');
      expect(runs.first.scheduleId, 'sc1');
      expect(runs.first.status, 'succeeded');
      expect(runs.first.attempt, 1);
      expect(runs.first.ranLate, isTrue);
      expect(runs.first.startedAt, DateTime.utc(2026, 10, 17, 9, 0, 2));
      expect(runs.first.finishedAt, DateTime.utc(2026, 10, 17, 9, 0, 30));
      expect(runs.last.status, 'failed');
    });
  });

  group('parseDate (ported verbatim from ScheduleCoordinator)', () {
    test('accepts a space or T separator and optional seconds', () {
      expect(
        ScheduleClient.parseDate('2026-10-03 10:00'),
        DateTime(2026, 10, 3, 10),
      );
      expect(
        ScheduleClient.parseDate('2026-10-03T10:00:30'),
        DateTime(2026, 10, 3, 10, 0, 30),
      );
    });

    test('preserves the offset instant and normalises to UTC', () {
      final parsed = ScheduleClient.parseDate('2026-10-04T09:30:00+05:30');
      expect(parsed.toUtc(), DateTime.utc(2026, 10, 4, 4));
    });

    test('accepts Z and 1-6 fractional-second digits', () {
      expect(
        ScheduleClient.parseDate('2026-10-04T09:30:00Z').toUtc(),
        DateTime.utc(2026, 10, 4, 9, 30),
      );
      expect(
        ScheduleClient.parseDate('2026-10-04T09:30:00.123456Z').toUtc(),
        DateTime.utc(2026, 10, 4, 9, 30, 0, 123, 456),
      );
    });

    test('rejects a non-existent calendar date with the specific message', () {
      for (final value in [
        '2026-02-30 09:00',
        '2026-13-01 09:00', // month out of range
        '2026-10-04T24:00', // hour out of range
        '2026-10-04T09:60', // minute out of range
      ]) {
        expect(
          () => ScheduleClient.parseDate(value),
          throwsA(isA<FormatException>().having(
            (e) => e.message,
            'message',
            'Invalid calendar date/time',
          )),
          reason: value,
        );
      }
    });

    test('rejects malformed input with the format hint', () {
      for (final value in [
        '2026-10-04', // no time
        '25:00', // no date
        '2026-10-04T09:30+24:00', // offset hour out of range
      ]) {
        expect(
          () => ScheduleClient.parseDate(value),
          throwsA(isA<FormatException>().having(
            (e) => e.message,
            'message',
            'Use YYYY-MM-DD HH:mm or ISO-8601 with offset',
          )),
          reason: value,
        );
      }
    });
  });
}
