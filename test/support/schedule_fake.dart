import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/schedule_client.dart';

/// Shared fake for the Schedule screen suites (P8 Task 14).
///
/// Mirrors the BUILT P4 wire shapes:
///   GET    /schedules              → `Page<ScheduleDto>`
///   PATCH  /schedules/:id          → `ScheduleDto`
///   DELETE /schedules/:id          → 204 (soft-cancel)
///   GET    /schedules/:id/runs     → `Page<ScheduleRunDto>`
const String scheduleRestBase = 'https://cloud.test/cloud/v1';

Map<String, dynamic> scheduleJson({
  String id = 'sc1',
  String sessionId = 's',
  String title = 'Morning brief',
  String description = 'Check the inbox and summarise',
  Map<String, dynamic>? trigger,
  String autonomy = 'safe',
  String status = 'pending',
  String? pausedReason,
  int maxRetries = 1,
  String? nextRunAt,
  Map<String, dynamic>? lastResult,
}) => {
      'id': id,
      'sessionId': sessionId,
      'title': title,
      'description': description,
      'trigger': trigger ??
          {'kind': 'daily_at', 'time': '09:00', 'tz': 'UTC'},
      'autonomy': autonomy,
      'status': status,
      'pausedReason': pausedReason,
      'maxRetries': maxRetries,
      'nextRunAt': nextRunAt ??
          DateTime.now().toUtc().add(const Duration(hours: 2)).toIso8601String(),
      'lastResult': lastResult,
      'createdAt': '2026-10-17T08:00:00.000Z',
      'updatedAt': '2026-10-17T08:05:00.000Z',
    };

Map<String, dynamic> lastResultJson({
  String status = 'succeeded',
  String? message = 'Posted the digest',
  bool ranLate = false,
  String finishedAt = '2026-10-17T09:03:00.000Z',
}) => {
      'status': status,
      'code': null,
      'message': message,
      'finishedAt': finishedAt,
      'ranLate': ranLate,
    };

class FakeScheduleGateway {
  FakeScheduleGateway(this.schedules, {this.runs = const {}});

  /// Mutable rows; PATCH/DELETE apply to these maps so assertions can read
  /// the same state the screen reloads.
  final List<Map<String, dynamic>> schedules;
  final Map<String, List<Map<String, dynamic>>> runs;

  int listCalls = 0;
  int patchCalls = 0;
  int deleteCalls = 0;
  Map<String, dynamic>? lastPatchBody;
  final List<http.Request> requests = <http.Request>[];

  /// When set, the next list call answers this status instead of 200.
  int? failListStatus;

  /// When set, PATCH answers this status with [failPatchMessage].
  int? failPatchStatus;
  String failPatchMessage = 'Schedule is not editable.';

  late final ScheduleClient client = ScheduleClient(
    CloudRestClient(
      httpClient: MockClient(_handle),
      headers: CloudHeaders.forTest(),
      restBase: scheduleRestBase,
    ),
  );

  Map<String, dynamic>? byId(String id) {
    for (final row in schedules) {
      if (row['id'] == id) return row;
    }
    return null;
  }

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    final segments = request.url.pathSegments;

    if (request.method == 'GET' && path.endsWith('/schedules')) {
      listCalls++;
      if (failListStatus != null) {
        return _json({
          'error': {'code': 'internal', 'message': 'Schedules unavailable.'}
        }, failListStatus!);
      }
      return _json({'items': schedules, 'nextCursor': null});
    }

    if (request.method == 'GET' && path.endsWith('/runs')) {
      final id = segments[segments.length - 2];
      return _json({'items': runs[id] ?? const [], 'nextCursor': null});
    }

    if (request.method == 'PATCH' && segments.length >= 2) {
      final id = segments.last;
      final row = byId(id);
      if (row == null) {
        return _json({
          'error': {'code': 'not_found', 'message': 'Schedule not found.'}
        }, 404);
      }
      if (failPatchStatus != null) {
        return _json({
          'error': {'code': 'bad_request', 'message': failPatchMessage}
        }, failPatchStatus!);
      }
      patchCalls++;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      lastPatchBody = body;
      row.addAll(body);
      row['updatedAt'] = DateTime.now().toUtc().toIso8601String();
      return _json(row);
    }

    if (request.method == 'DELETE') {
      final row = byId(segments.last);
      if (row == null) {
        return _json({
          'error': {'code': 'not_found', 'message': 'Schedule not found.'}
        }, 404);
      }
      deleteCalls++;
      row['status'] = 'cancelled';
      row['pausedReason'] = null;
      return http.Response('', 204);
    }

    return _json({
      'error': {'code': 'not_found', 'message': 'No route.'}
    }, 404);
  }

  http.Response _json(Object body, [int status = 200]) => http.Response(
        body is String ? body : jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );
}
