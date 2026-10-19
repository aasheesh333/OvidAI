import 'package:flutter/foundation.dart';

import '../diag.dart';
import 'cloud_rest.dart';

/// Token counters shared by every bucket of `GET /usage/history`.
class UsageCounts {
  const UsageCounts({
    this.runs = 0,
    this.modelCalls = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
  });

  final int runs;
  final int modelCalls;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

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
  });

  final String runId;
  final String sessionId;
  final String? sessionTitle;
  final String? status;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final List<String> models;
  final UsageCounts counts;
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

  static DateTime? _t(Object? v) =>
      v is String ? DateTime.tryParse(v)?.toUtc() : null;

  static List<Map<String, dynamic>> _list(Object? v) => [
    for (final e in (v is List ? v : const []))
      if (e is Map) Map<String, dynamic>.from(e),
  ];

  static UsageRunRow runFromJson(Map<String, dynamic> r) => UsageRunRow(
    runId: '${r['runId'] ?? ''}',
    sessionId: '${r['sessionId'] ?? ''}',
    sessionTitle: r['sessionTitle'] is String
        ? r['sessionTitle'] as String
        : null,
    status: r['status'] is String ? r['status'] as String : null,
    startedAt: _t(r['startedAt']),
    finishedAt: _t(r['finishedAt']),
    models: [
      for (final m in (r['models'] is List ? r['models'] as List : const []))
        if (m is String) m,
    ],
    counts: UsageCounts.fromJson(r),
  );

  factory UsageHistory.fromJson(Map<String, dynamic> j) => UsageHistory(
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
    sessions: [
      for (final s in _list(j['sessions']))
        UsageSessionRow(
          sessionId: '${s['sessionId'] ?? ''}',
          title: s['title'] is String ? s['title'] as String : null,
          counts: UsageCounts.fromJson(s),
          lastAt: _t(s['lastAt']),
        ),
    ],
    runs: [for (final r in _list(j['runs'])) runFromJson(r)],
    nextBefore: j['nextBefore'] is String ? j['nextBefore'] as String : null,
  );
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
