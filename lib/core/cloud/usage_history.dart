import 'package:flutter/foundation.dart';

import '../diag.dart';
import 'cloud_rest.dart';

int? _measurement(Object? value) {
  if (value is! num || !value.isFinite || value < 0) return null;
  return value.toInt();
}

/// Formats a nullable measured count without turning an unknown into zero.
String formatUsageValue(int? value) => value == null ? '—' : '$value';

/// Explicit empty sessions are a real zero; missing/malformed aggregates are
/// unknown and must never be rendered as zero sessions.
String formatUsageSessionCount(UsageHistory history) =>
    history.sessionsKnown ? '${history.sessions.length}' : '—';

/// Formats provider-reported USD micros. No currency conversion or inference
/// is performed: an unknown value stays a dash and a recorded zero stays zero.
String formatUsageCostMicros(int? micros) {
  if (micros == null || micros < 0) return '—';
  final whole = micros ~/ 1000000;
  final fractional = (micros % 1000000).toString().padLeft(6, '0');
  final trimmed = fractional.replaceFirst(RegExp(r'0+$'), '');
  final decimals = trimmed.length < 2 ? trimmed.padRight(2, '0') : trimmed;
  return '\$$whole.$decimals';
}

/// Token counters shared by every bucket of `GET /usage/history`.
class UsageCounts {
  const UsageCounts({
    this.runs = 0,
    this.modelCalls = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.costMicros,
    this.imagesGenerated,
    this.imagesEdited,
  });

  final int runs;
  final int modelCalls;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

  /// Measured provider cost and image operations. Null means the provider did
  /// not report them; zero is reserved for a real recorded zero.
  final int? costMicros;
  final int? imagesGenerated;
  final int? imagesEdited;

  int get totalTokens => inputTokens + outputTokens;

  static int _n(Map<String, dynamic> j, String k) {
    final v = j[k];
    return v is num && v.isFinite && v >= 0 ? v.toInt() : 0;
  }

  factory UsageCounts.fromJson(Map<String, dynamic> j) => UsageCounts(
    runs: _n(j, 'runs'),
    modelCalls: _n(j, 'modelCalls'),
    inputTokens: _n(j, 'inputTokens'),
    outputTokens: _n(j, 'outputTokens'),
    cacheReadTokens: _n(j, 'cacheReadTokens'),
    cacheWriteTokens: _n(j, 'cacheWriteTokens'),
    costMicros: _measurement(j['costMicros']),
    imagesGenerated: _measurement(j['imagesGenerated']),
    imagesEdited: _measurement(j['imagesEdited']),
  );
}

class UsageDay {
  const UsageDay(this.date, this.counts);

  /// The client's local calendar day (`YYYY-MM-DD`, bucketed server-side by
  /// the offset the client sent).
  final String date;
  final UsageCounts counts;

  DateTime? get day => DateTime.tryParse(date);
}

class UsageModelRow {
  const UsageModelRow(this.model, this.counts);

  /// The model id the agent requested (e.g. `auto`).
  final String model;
  final UsageCounts counts;
}

class UsageSessionRow {
  const UsageSessionRow({
    required this.sessionId,
    required this.title,
    required this.counts,
    required this.lastAt,
  });

  /// SERVER session id.
  final String sessionId;

  /// Null for a deleted chat (still counted).
  final String? title;
  final UsageCounts counts;
  final DateTime? lastAt;

  int? get costMicros => counts.costMicros;
  int? get imagesGenerated => counts.imagesGenerated;
  int? get imagesEdited => counts.imagesEdited;
}

class UsageRunRow {
  const UsageRunRow({
    required this.runId,
    required this.sessionId,
    required this.sessionTitle,
    required this.status,
    required this.startedAt,
    required this.finishedAt,
    required this.models,
    required this.counts,
    this.requestedModels,
    this.providerModels,
    this.costMicros,
    this.imagesGenerated,
    this.imagesEdited,
  });

  final String runId;
  final String sessionId;
  final String? sessionTitle;
  final String? status;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final List<String> models;
  final UsageCounts counts;

  /// Models asked for and models the provider actually reported using. Both
  /// are nullable: `auto` is not evidence of the provider's concrete model.
  final List<String>? requestedModels;
  final List<String>? providerModels;
  final int? costMicros;
  final int? imagesGenerated;
  final int? imagesEdited;

  factory UsageRunRow.fromJson(Map<String, dynamic> json) {
    final requested = _modelList(json['requestedModels'] ?? json['models']);
    final counts = UsageCounts.fromJson(json);
    return UsageRunRow(
      runId: '${json['runId'] ?? ''}',
      sessionId: '${json['sessionId'] ?? ''}',
      sessionTitle: json['sessionTitle'] is String
          ? json['sessionTitle'] as String
          : null,
      status: json['status'] is String ? json['status'] as String : null,
      startedAt: UsageHistory._t(json['startedAt']),
      finishedAt: UsageHistory._t(json['finishedAt']),
      models: requested ?? const [],
      requestedModels: requested,
      providerModels: _modelList(json['providerModels']),
      counts: counts,
      costMicros: counts.costMicros,
      imagesGenerated: counts.imagesGenerated,
      imagesEdited: counts.imagesEdited,
    );
  }

  static List<String>? _modelList(Object? raw) {
    if (raw is! List) return null;
    return [
      for (final model in raw)
        if (model is String) model,
    ];
  }
}

/// `GET /cloud/v1/usage/history` — the per-day / per-model / per-chat /
/// per-run token ledger recorded by the worker for every model call
/// (owner ask: very detailed usage).
class UsageHistory {
  const UsageHistory({
    required this.since,
    required this.until,
    required this.totals,
    required this.days,
    required this.models,
    required this.sessions,
    required this.runs,
    required this.nextBefore,
    this.sessionsKnown = true,
  });

  final DateTime? since;
  final DateTime? until;
  final UsageCounts totals;

  /// Every day in range, newest first, zero-filled.
  final List<UsageDay> days;
  final List<UsageModelRow> models;
  final List<UsageSessionRow> sessions;
  final List<UsageRunRow> runs;
  final String? nextBefore;

  /// Whether the server supplied a valid sessions array. The list remains
  /// convenient for callers, but only this flag distinguishes empty from
  /// unknown.
  final bool sessionsKnown;

  static DateTime? _t(Object? v) =>
      v is String ? DateTime.tryParse(v)?.toUtc() : null;

  static List<Map<String, dynamic>> _list(Object? v) => [
    for (final e in (v is List ? v : const []))
      if (e is Map) Map<String, dynamic>.from(e),
  ];

  static UsageRunRow runFromJson(Map<String, dynamic> r) =>
      UsageRunRow.fromJson(r);

  factory UsageHistory.fromJson(Map<String, dynamic> j) {
    final rawSessions = j['sessions'];
    var sessionsKnown = rawSessions is List;
    final sessions = <UsageSessionRow>[];
    if (sessionsKnown) {
      for (final raw in rawSessions) {
        if (raw is! Map ||
            raw['sessionId'] is! String ||
            (raw['sessionId'] as String).trim().isEmpty) {
          sessionsKnown = false;
          break;
        }
        final session = Map<String, dynamic>.from(raw);
        sessions.add(
          UsageSessionRow(
            sessionId: session['sessionId'] as String,
            title: session['title'] is String
                ? session['title'] as String
                : null,
            counts: UsageCounts.fromJson(session),
            lastAt: _t(session['lastAt']),
          ),
        );
      }
    }
    return UsageHistory(
      since: _t(j['since']),
      until: _t(j['until']),
      totals: UsageCounts.fromJson(
        j['totals'] is Map
            ? Map<String, dynamic>.from(j['totals'] as Map)
            : const {},
      ),
      days: [
        for (final d in _list(j['days']))
          if (d['date'] is String)
            UsageDay(d['date'] as String, UsageCounts.fromJson(d)),
      ],
      models: [
        for (final m in _list(j['models']))
          if (m['model'] is String)
            UsageModelRow(m['model'] as String, UsageCounts.fromJson(m)),
      ],
      sessions: sessionsKnown ? sessions : const [],
      sessionsKnown: sessionsKnown,
      runs: [for (final r in _list(j['runs'])) runFromJson(r)],
      nextBefore: j['nextBefore'] is String ? j['nextBefore'] as String : null,
    );
  }
}

/// Loads [UsageHistory] for the Usage screen: range changes, refresh, and
/// paging older runs. A 404 means the gateway predates the endpoint; the
/// screen then explains that history is not available yet, instead of
/// failing.
class UsageHistoryStore extends ChangeNotifier {
  UsageHistoryStore({CloudRestClient? rest, int Function()? utcOffsetMinutes})
    : _rest = rest ?? CloudRestClient.I,
      _offset =
          utcOffsetMinutes ?? (() => DateTime.now().timeZoneOffset.inMinutes);

  final CloudRestClient _rest;
  final int Function() _offset;

  int days = 30;
  UsageHistory? history;
  bool loading = false;
  bool loadingMore = false;
  bool unsupported = false;
  String? error;
  int _generation = 0;

  Future<void> setDays(int value) async {
    if (value == days) return;
    days = value;
    await refresh();
  }

  Future<void> refresh() async {
    final generation = ++_generation;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final json = await _rest.getJson(
        '/usage/history',
        query: {
          'days': '$days',
          'utcOffsetMinutes': '${_offset().clamp(-840, 840)}',
          'limit': '50',
        },
      );
      if (generation != _generation) return;
      history = UsageHistory.fromJson(json);
      unsupported = false;
    } on CloudApiException catch (e) {
      if (generation != _generation) return;
      if (e.status == 404) {
        unsupported = true;
      } else {
        error = e.status == 0
            ? "Couldn't reach Ovid Cloud. Pull to retry."
            : 'Usage history is unavailable right now. Pull to retry.';
      }
    } catch (e) {
      Diag.swallow('usage_history.refresh', e);
      if (generation != _generation) return;
      error = 'Usage history is unavailable right now. Pull to retry.';
    } finally {
      if (generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// Appends the next page of older runs.
  Future<void> loadMoreRuns() async {
    final current = history;
    final cursor = current?.nextBefore;
    if (current == null || cursor == null || loadingMore) return;
    final generation = _generation;
    loadingMore = true;
    notifyListeners();
    try {
      final json = await _rest.getJson(
        '/usage/history',
        query: {
          'days': '$days',
          'utcOffsetMinutes': '${_offset().clamp(-840, 840)}',
          'limit': '50',
          'before': cursor,
        },
      );
      if (generation != _generation) return;
      final page = UsageHistory.fromJson(json);
      history = UsageHistory(
        since: current.since,
        until: current.until,
        totals: current.totals,
        days: current.days,
        models: current.models,
        sessions: current.sessions,
        sessionsKnown: current.sessionsKnown,
        runs: [
          ...current.runs,
          for (final r in page.runs)
            if (!current.runs.any((c) => c.runId == r.runId)) r,
        ],
        nextBefore: page.nextBefore,
      );
    } catch (e) {
      Diag.swallow('usage_history.more', e);
    } finally {
      loadingMore = false;
      notifyListeners();
    }
  }
}
