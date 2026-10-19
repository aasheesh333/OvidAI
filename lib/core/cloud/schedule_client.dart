/// P4 scheduler REST client — the wire contract is the BUILT gateway, not the
/// plan sketch:
///   cloud/apps/gateway/src/routes/schedules.ts
///   cloud/packages/shared/src/schedules.ts
///   cloud/packages/shared/src/triggers.ts
///
/// Deviations from the Task 14 interface sketch (documented in the task
/// report):
///   * `GET /schedules` is `Page<ScheduleDto>` (`{items, nextCursor}`); this
///     client follows the cursor and returns the flattened list.
///   * Trigger JSON keys are `{kind, at|seconds|time+tz|expr+tz}` — the server
///     rejected `everySeconds`/`dailyAt`/`cron`.
///   * `lastResult` is `{status, code, message, finishedAt, ranLate}`; there is
///     no `summary` field (`message` is the summary-equivalent).
///   * `ScheduleRunDto` has no `summary`.
///   * `create` defaults `maxRetries` to 0 (the service default), not 1.
///
/// Wave 5 additions: `GET /schedules/:id` ([ScheduleClient.get], CT-015),
/// `POST /schedules/:id/run` ([ScheduleClient.runNow], FE-012), a failed
/// schedule is editable and resumable (FE-013), trigger equality so an edit
/// sends only what changed (FE-017), and [ScheduleLiveFeed] — the WS system
/// channel the Schedule screen refreshes from (CT-014).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cloud_rest.dart';
import 'cloud_ws.dart';
import 'models.dart';


/// One trigger variant, serialised with the server's discriminated-union
/// keys. Exactly one of [at], [seconds], [time], [expr] is set, per [kind].
@immutable
class ScheduleTrigger {
  const ScheduleTrigger._({
    required this.kind,
    this.at,
    this.seconds,
    this.time,
    this.tz,
    this.expr,
  });

  factory ScheduleTrigger.at(DateTime at) =>
      ScheduleTrigger._(kind: 'at', at: at.toUtc());

  factory ScheduleTrigger.every(int seconds) =>
      ScheduleTrigger._(kind: 'every', seconds: seconds);

  factory ScheduleTrigger.dailyAt(String time, {required String tz}) =>
      ScheduleTrigger._(kind: 'daily_at', time: time, tz: tz);

  factory ScheduleTrigger.cron(String expr, {required String tz}) =>
      ScheduleTrigger._(kind: 'cron', expr: expr, tz: tz);

  factory ScheduleTrigger.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String? ?? '';
    switch (kind) {
      case 'at':
        final raw = json['at'] as String?;
        return ScheduleTrigger._(
          kind: kind,
          at: raw == null ? null : DateTime.tryParse(raw)?.toUtc(),
        );
      case 'every':
        return ScheduleTrigger._(
          kind: kind,
          seconds: (json['seconds'] as num?)?.toInt(),
        );
      case 'daily_at':
        return ScheduleTrigger._(
          kind: kind,
          time: json['time'] as String?,
          tz: json['tz'] as String?,
        );
      case 'cron':
        return ScheduleTrigger._(
          kind: kind,
          expr: json['expr'] as String?,
          tz: json['tz'] as String?,
        );
      default:
        return ScheduleTrigger._(kind: kind);
    }
  }

  /// 'at' | 'every' | 'daily_at' | 'cron'.
  final String kind;
  final DateTime? at;
  final int? seconds;

  /// 'HH:mm' for [kind] == 'daily_at'.
  final String? time;

  /// IANA zone for 'daily_at' / 'cron'.
  final String? tz;

  /// 5-field expression for [kind] == 'cron'.
  final String? expr;

  bool get isRecurring => kind != 'at';

  /// The same trigger with another IANA zone (daily/cron only).
  ScheduleTrigger withTimeZone(String zone) => switch (kind) {
        'daily_at' => ScheduleTrigger.dailyAt(time ?? '', tz: zone),
        'cron' => ScheduleTrigger.cron(expr ?? '', tz: zone),
        _ => this,
      };

  @override
  bool operator ==(Object other) =>
      other is ScheduleTrigger &&
      other.kind == kind &&
      other.at?.toUtc() == at?.toUtc() &&
      other.seconds == seconds &&
      other.time == time &&
      other.tz == tz &&
      other.expr == expr;

  @override
  int get hashCode => Object.hash(kind, at?.toUtc(), seconds, time, tz, expr);

  Map<String, Object?> toJson() => switch (kind) {
        'at' => {'kind': 'at', 'at': at!.toUtc().toIso8601String()},
        'every' => {'kind': 'every', 'seconds': seconds},
        'daily_at' => {'kind': 'daily_at', 'time': time, 'tz': tz},
        'cron' => {'kind': 'cron', 'expr': expr, 'tz': tz},
        _ => {'kind': kind},
      };

  /// Human-readable echo, matching the server's `describeTrigger` templates
  /// closely enough for the card/details rows.
  String describe() => switch (kind) {
        'at' => 'Once at ${at?.toLocal()}',
        'every' => 'Every ${seconds ?? 0} seconds',
        'daily_at' => 'Daily at ${time ?? '—'} (${tz ?? '—'})',
        'cron' => "Cron '${expr ?? '—'}' (${tz ?? '—'})",
        _ => kind,
      };
}

/// The schedule-level result embedded in [ScheduleDto.lastResult].
@immutable
class ScheduleLastResult {
  const ScheduleLastResult({
    required this.status,
    required this.ranLate,
    this.code,
    this.message,
    this.finishedAt,
  });

  factory ScheduleLastResult.fromJson(Map<String, dynamic> json) =>
      ScheduleLastResult(
        status: json['status'] as String? ?? '',
        code: json['code'] as String?,
        message: json['message'] as String?,
        finishedAt: _date(json['finishedAt']),
        ranLate: json['ranLate'] as bool? ?? false,
      );

  /// 'succeeded' | 'failed' | 'skipped'.
  final String status;
  final String? code;
  final String? message;
  final DateTime? finishedAt;

  /// Spec §8: a one-off that ran inside its 24 h grace is flagged.
  final bool ranLate;
}

/// `ScheduleDto` (P4). `sessionId` is always present; the server materialises
/// a dedicated session when the caller omits one.
@immutable
class ScheduleDto {
  const ScheduleDto({
    required this.id,
    required this.sessionId,
    required this.title,
    required this.description,
    required this.trigger,
    required this.autonomy,
    required this.status,
    required this.maxRetries,
    this.pausedReason,
    this.nextRunAt,
    this.lastResult,
    this.createdAt,
    this.updatedAt,
  });

  factory ScheduleDto.fromJson(Map<String, dynamic> json) => ScheduleDto(
        id: json['id'] as String,
        sessionId: json['sessionId'] as String,
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        trigger: ScheduleTrigger.fromJson(
          (json['trigger'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{},
        ),
        autonomy: json['autonomy'] as String? ?? 'safe',
        status: json['status'] as String? ?? 'pending',
        pausedReason: json['pausedReason'] as String?,
        maxRetries: (json['maxRetries'] as num?)?.toInt() ?? 0,
        nextRunAt: _date(json['nextRunAt']),
        lastResult: json['lastResult'] is Map
            ? ScheduleLastResult.fromJson(
                (json['lastResult'] as Map).cast<String, dynamic>(),
              )
            : null,
        createdAt: _date(json['createdAt']),
        updatedAt: _date(json['updatedAt']),
      );

  final String id;
  final String sessionId;
  final String title;
  final String description;
  final ScheduleTrigger trigger;

  /// 'safe' | 'auto'.
  final String autonomy;

  /// 'pending' | 'paused' | 'completed' | 'failed' | 'cancelled'.
  final String status;
  final String? pausedReason;
  final int maxRetries;
  final DateTime? nextRunAt;
  final ScheduleLastResult? lastResult;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isTerminal =>
      status == 'cancelled' || status == 'completed' || status == 'failed';

  /// Wave 5 FE-013: a failed schedule is reviewed, edited and resumed;
  /// only completed and cancelled rows are read-only.
  bool get isEditable => status != 'cancelled' && status != 'completed';

  /// Paused, or failed after review.
  bool get canResume => status == 'paused' || status == 'failed';

  /// "Run now" claims one immediate occurrence (pending/paused/failed).
  bool get canRunNow => isEditable;
}

/// `POST /schedules/:id/run` → 202 (Wave 5 FE-012).
@immutable
class ScheduleRunNowResult {
  const ScheduleRunNowResult({required this.runId, required this.scheduleRun});

  factory ScheduleRunNowResult.fromJson(Map<String, dynamic> json) =>
      ScheduleRunNowResult(
        runId: json['runId'] as String? ?? '',
        scheduleRun: ScheduleRunDto.fromJson(
          (json['scheduleRun'] as Map).cast<String, dynamic>(),
        ),
      );

  final String runId;
  final ScheduleRunDto scheduleRun;
}

/// One occurrence in the results feed (`GET /schedules/:id/runs`).
@immutable
class ScheduleRunDto {
  const ScheduleRunDto({
    required this.id,
    required this.scheduleId,
    required this.status,
    required this.attempt,
    required this.ranLate,
    this.scheduledFor,
    this.runId,
    this.error,
    this.startedAt,
    this.finishedAt,
  });

  factory ScheduleRunDto.fromJson(Map<String, dynamic> json) => ScheduleRunDto(
        id: json['id'] as String,
        scheduleId: json['scheduleId'] as String? ?? '',
        scheduledFor: _date(json['scheduledFor']),
        runId: json['runId'] as String?,
        status: json['status'] as String? ?? '',
        attempt: (json['attempt'] as num?)?.toInt() ?? 1,
        ranLate: json['ranLate'] as bool? ?? false,
        error: json['error'] as String?,
        startedAt: _date(json['startedAt']),
        finishedAt: _date(json['finishedAt']),
      );

  final String id;
  final String scheduleId;
  final DateTime? scheduledFor;
  final String? runId;

  /// 'running' | 'retry_scheduled' | 'succeeded' | 'failed' | 'skipped'.
  final String status;
  final int attempt;
  final bool ranLate;
  final String? error;
  final DateTime? startedAt;
  final DateTime? finishedAt;
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

/// P4 scheduler CRUD + results feed.
class ScheduleClient {
  ScheduleClient(this._rest);

  final CloudRestClient _rest;

  static ScheduleClient? _instance;

  /// Process-wide client (prod REST base + real auth headers).
  static ScheduleClient get I => _instance ??= ScheduleClient(CloudRestClient.I);

  /// Replaces the singleton — test wiring only.
  @visibleForTesting
  static void installForTest(ScheduleClient client) => _instance = client;

  /// Test seam for the device IANA zone (Android supplies it natively).
  @visibleForTesting
  static String? timeZoneOverrideForTest;

  static const MethodChannel _native = MethodChannel('ovid/native');

  /// GET /schedules — every page, most recently updated first.
  ///
  /// The server hides cancelled rows unless [includeCancelled] is true; the
  /// Schedule screen asks for them so a cancelled task remains visible.
  Future<List<ScheduleDto>> list({
    bool includeCancelled = false,
    int pageSize = 100,
  }) async {
    final out = <ScheduleDto>[];
    String? cursor;
    final seen = <String>{};
    do {
      final json = await _rest.getJson('/schedules', query: <String, String>{
        'limit': '$pageSize',
        'cursor': ?cursor,
        if (includeCancelled) 'includeCancelled': 'true',
      });
      final page = CloudPage.fromJson(json, ScheduleDto.fromJson);
      out.addAll(page.items);
      cursor = page.nextCursor;
      if (cursor != null && !seen.add(cursor)) break;
    } while (cursor != null);
    return out;
  }

  /// POST /schedules. The service materialises a dedicated session when
  /// [sessionId] is omitted.
  Future<ScheduleDto> create({
    required String title,
    required String description,
    required ScheduleTrigger trigger,
    String autonomy = 'safe',
    String? sessionId,
    int maxRetries = 0,
  }) async {
    return ScheduleDto.fromJson(await _rest.postJson('/schedules',
        body: <String, Object?>{
          'title': title,
          'description': description,
          'trigger': trigger.toJson(),
          'autonomy': autonomy,
          'maxRetries': maxRetries,
          'sessionId': ?sessionId,
        }));
  }

  /// PATCH /schedules/:id — only the supplied fields are sent (the server
  /// rejects an empty patch and unknown keys).
  Future<ScheduleDto> update(
    String id, {
    String? title,
    String? description,
    ScheduleTrigger? trigger,
    String? autonomy,
    String? status,
    int? maxRetries,
    String? sessionId,
  }) async {
    return ScheduleDto.fromJson(await _rest.patchJson('/schedules/$id',
        body: <String, Object?>{
          'title': ?title,
          'description': ?description,
          'trigger': ?trigger?.toJson(),
          'autonomy': ?autonomy,
          'status': ?status,
          'maxRetries': ?maxRetries,
          'sessionId': ?sessionId,
        }));
  }

  /// GET /schedules/:id — one schedule (a deep link opens without paging the
  /// whole list; CT-015).
  Future<ScheduleDto> get(String id) async =>
      ScheduleDto.fromJson(await _rest.getJson('/schedules/$id'));

  /// POST /schedules/:id/run — run one occurrence now. The schedule's own
  /// next run and status are unchanged; a busy chat answers 409
  /// `session_busy` (surfaced as [CloudApiException]).
  Future<ScheduleRunNowResult> runNow(String id) async =>
      ScheduleRunNowResult.fromJson(await _rest.postJson('/schedules/$id/run'));

  /// DELETE /schedules/:id — the server soft-cancels (204, empty body).
  Future<void> delete(String id) => _rest.delete('/schedules/$id');

  /// GET /schedules/:id/runs — the results feed, newest first.
  Future<List<ScheduleRunDto>> runs(String id, {int pageSize = 100}) async {
    final out = <ScheduleRunDto>[];
    String? before;
    final seen = <String>{};
    do {
      final json =
          await _rest.getJson('/schedules/$id/runs', query: <String, String>{
        'limit': '$pageSize',
        'before': ?before,
      });
      final page = CloudPage.fromJson(json, ScheduleRunDto.fromJson);
      out.addAll(page.items);
      before = page.nextCursor;
      if (before != null && !seen.add(before)) break;
    } while (before != null);
    return out;
  }

  /// The device's IANA zone id, for `daily_at` / `cron` triggers.
  ///
  /// Android's `TimeZone.getDefault().id` is the only reliable source in this
  /// app (Dart exposes an abbreviation, not an IANA id). Non-Android runtimes
  /// fall back to UTC.
  static Future<String> deviceTimeZone() async {
    final override = timeZoneOverrideForTest;
    if (override != null && override.isNotEmpty) return override;
    try {
      final id = await _native.invokeMethod<String>('timeZoneId');
      if (id != null && id.trim().isNotEmpty) return id.trim();
    } on MissingPluginException {
      // Desktop/tests: no Android channel.
    } catch (_) {
      // Any platform failure degrades to UTC rather than blocking a save.
    }
    return 'UTC';
  }

  /// Ported VERBATIM from `ScheduleCoordinator.parseDate` (AG4): same
  /// regexes, same calendar validation, same `FormatException` messages.
  /// UI-facing parsing stays client-side.
  static DateTime parseDate(String value) {
    final m = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::([0-5]\d)(?:\.\d{1,6})?)?(Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)?$',
    ).firstMatch(value);
    if (m == null) {
      throw const FormatException(
        'Use YYYY-MM-DD HH:mm or ISO-8601 with offset',
      );
    }
    final year = int.parse(m[1]!);
    final month = int.parse(m[2]!);
    final day = int.parse(m[3]!);
    final date = DateTime.utc(year, month, day);
    if (date.year != year ||
        date.month != month ||
        date.day != day ||
        int.parse(m[4]!) > 23 ||
        int.parse(m[5]!) > 59) {
      throw const FormatException('Invalid calendar date/time');
    }
    return DateTime.parse(value.replaceAll(' ', 'T'));
  }
}

/// One scheduler event from the WS system channel (`{op:'system', event}`).
@immutable
class ScheduleSystemEvent {
  const ScheduleSystemEvent({
    required this.type,
    required this.scheduleId,
    this.payload = const <String, dynamic>{},
  });

  /// schedule_created | schedule_updated | schedule_deleted |
  /// schedule_run_started | schedule_run_succeeded | schedule_run_failed |
  /// schedule_run_paused.
  final String type;
  final String scheduleId;
  final Map<String, dynamic> payload;
}

/// Live scheduler updates (CT-014): `subscribe_system` on the shared socket
/// while a consumer is started, re-sent after every reconnect (the gateway
/// drops the subscription with the socket), `unsubscribe_system` on stop.
///
/// It never opens the socket itself — the app shell keeps the link up; a
/// subscription simply starts the next time the link is online.
class ScheduleLiveFeed {
  ScheduleLiveFeed({
    required WsMultiplexer ws,
    Stream<Map<String, dynamic>>? rawFramesOverride,
    Future<void> Function(Map<String, Object?> frame)? sendOverride,
  })  : _ws = ws,
        _rawFrames = rawFramesOverride ?? ws.rawServerFrames,
        // ignore: prefer_initializing_formals
        _sendOverride = sendOverride;

  static ScheduleLiveFeed? _instance;

  /// Process-wide default over [WsMultiplexer.I].
  static ScheduleLiveFeed get I =>
      _instance ??= ScheduleLiveFeed(ws: WsMultiplexer.I);

  @visibleForTesting
  static void installForTest(ScheduleLiveFeed feed) => _instance = feed;

  @visibleForTesting
  static void resetForTest() => _instance = null;

  final WsMultiplexer _ws;
  final Stream<Map<String, dynamic>> _rawFrames;
  final Future<void> Function(Map<String, Object?> frame)? _sendOverride;

  final StreamController<ScheduleSystemEvent> _events =
      StreamController<ScheduleSystemEvent>.broadcast();
  StreamSubscription<Map<String, dynamic>>? _rawSub;
  WsLinkState? _lastLink;
  int _starts = 0;

  /// Scheduler events while started.
  Stream<ScheduleSystemEvent> get events => _events.stream;

  /// True while at least one consumer has started the feed.
  bool get active => _starts > 0;

  Future<void> _send(Map<String, Object?> frame) async {
    try {
      final override = _sendOverride;
      if (override != null) {
        await override(frame);
      } else {
        await _ws.sendRaw(frame);
      }
    } catch (err) {
      debugPrint('schedule live feed: send failed: $err');
    }
  }

  /// Starts (ref-counted) the subscription.
  void start() {
    _starts++;
    if (_starts > 1) return;
    _rawSub = _rawFrames.listen(_onRaw, onError: (Object _) {});
    _lastLink = _ws.linkState;
    _ws.addListener(_onLink);
    if (_ws.linkState == WsLinkState.online) {
      unawaited(_send(<String, Object?>{'op': 'subscribe_system'}));
    }
  }

  /// Stops one consumer; the last one unsubscribes.
  void stop() {
    if (_starts == 0) return;
    _starts--;
    if (_starts > 0) return;
    _ws.removeListener(_onLink);
    unawaited(_rawSub?.cancel());
    _rawSub = null;
    if (_ws.linkState == WsLinkState.online) {
      unawaited(_send(<String, Object?>{'op': 'unsubscribe_system'}));
    }
  }

  void _onLink() {
    final link = _ws.linkState;
    final previous = _lastLink;
    _lastLink = link;
    if (_starts == 0) return;
    if (link == WsLinkState.online && previous != WsLinkState.online) {
      unawaited(_send(<String, Object?>{'op': 'subscribe_system'}));
    }
  }

  void _onRaw(Map<String, dynamic> frame) {
    if (frame['op'] != 'system') return;
    final raw = frame['event'];
    if (raw is! Map) return;
    final type = raw['type'];
    final id = raw['scheduleId'];
    if (type is! String || id is! String) return;
    final payload = raw['payload'];
    if (_events.isClosed) return;
    _events.add(ScheduleSystemEvent(
      type: type,
      scheduleId: id,
      payload: payload is Map
          ? payload.cast<String, dynamic>()
          : const <String, dynamic>{},
    ));
  }

  void dispose() {
    if (_starts > 0) {
      _starts = 1;
      stop();
    }
    unawaited(_events.close());
  }
}
