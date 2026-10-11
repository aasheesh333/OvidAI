import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diag.dart';
import 'subagent_tools.dart';

/// What produced one recorded call.
enum ToolUsageKind { mcp, pluginTool }

/// Rolled-up usage for one key over a time window.
class ToolUsageSummary {
  final int calls;
  final int errors;

  /// Latency percentiles in milliseconds (nearest rank over the retained
  /// samples). Null when nothing was recorded.
  final int? p50Ms;
  final int? p95Ms;
  final int? avgMs;
  final DateTime? lastUsed;
  final String? lastError;
  final DateTime? lastErrorAt;

  const ToolUsageSummary({
    this.calls = 0,
    this.errors = 0,
    this.p50Ms,
    this.p95Ms,
    this.avgMs,
    this.lastUsed,
    this.lastError,
    this.lastErrorAt,
  });

  static const empty = ToolUsageSummary();

  bool get isEmpty => calls == 0;
}

/// One day's rollup for one key. Samples are capped so a busy tool cannot
/// grow the persisted blob without bound; percentiles use what is kept.
class _Bucket {
  int calls = 0;
  int errors = 0;
  int totalMs = 0;
  final List<int> samples = [];
  int lastUsedMs = 0;
  String? lastError;
  int lastErrorMs = 0;

  /// Calls made from inside a subagent, by Claude Code `agent_type`.
  final Map<String, int> agents = {};

  static const maxSamples = 200;
  static const maxAgents = 32;

  void add({
    required bool ok,
    required int ms,
    required int at,
    String? error,
    String? agentType,
  }) {
    if (agentType != null &&
        (agents.containsKey(agentType) || agents.length < maxAgents)) {
      agents[agentType] = (agents[agentType] ?? 0) + 1;
    }
    calls++;
    totalMs += ms;
    if (samples.length >= maxSamples) samples.removeAt(0);
    samples.add(ms);
    if (at > lastUsedMs) lastUsedMs = at;
    if (!ok) {
      errors++;
      if (at >= lastErrorMs) {
        lastErrorMs = at;
        lastError = error;
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'c': calls,
    'e': errors,
    't': totalMs,
    's': samples,
    'l': lastUsedMs,
    if (lastError != null) 'le': lastError,
    if (lastErrorMs > 0) 'lt': lastErrorMs,
    if (agents.isNotEmpty) 'a': agents,
  };

  static _Bucket fromJson(Map<String, dynamic> j) {
    final b = _Bucket()
      ..calls = (j['c'] as num?)?.toInt() ?? 0
      ..errors = (j['e'] as num?)?.toInt() ?? 0
      ..totalMs = (j['t'] as num?)?.toInt() ?? 0
      ..lastUsedMs = (j['l'] as num?)?.toInt() ?? 0
      ..lastError = j['le'] as String?
      ..lastErrorMs = (j['lt'] as num?)?.toInt() ?? 0;
    final a = j['a'];
    if (a is Map) {
      for (final e in a.entries) {
        if (e.value is num) b.agents['${e.key}'] = (e.value as num).toInt();
      }
    }
    final s = j['s'];
    if (s is List) {
      for (final v in s) {
        if (v is num) b.samples.add(v.toInt());
      }
    }
    return b;
  }
}

/// Usage tracking for MCP tools and plugin contributions (product
/// requirement: MCP/plugin usage must be tracked and visible).
///
/// Each call is recorded under a key `{kind, pluginId, mcpServerId, tool}`
/// into a daily rollup (calls, errors, latency samples, last used, last
/// error). Rollups are kept for [retentionDays] and persisted to
/// SharedPreferences (debounced). The plugin and MCP detail screens read
/// [summary] / [toolSummaries]; this store holds no arguments or results.
class ToolUsageStore extends ChangeNotifier {
  ToolUsageStore._();

  static final ToolUsageStore I = ToolUsageStore._();

  static const prefsKey = 'ovid_tool_usage_v1';
  static const retentionDays = 30;
  static const _maxErrorChars = 300;

  /// Test seam: the clock used for new records and the retention window.
  @visibleForTesting
  static DateTime Function() clockForTest = DateTime.now;

  /// Test seam: debounce before a write. Zero writes on the next microtask.
  @visibleForTesting
  static Duration saveDelayForTest = const Duration(seconds: 2);

  /// day (`yyyy-mm-dd`) → key → bucket.
  final Map<String, Map<String, _Bucket>> _days = {};
  Timer? _saveTimer;
  bool _loaded = false;

  static String _day(DateTime t) {
    final l = t.toLocal();
    return '${l.year.toString().padLeft(4, '0')}-'
        '${l.month.toString().padLeft(2, '0')}-'
        '${l.day.toString().padLeft(2, '0')}';
  }

  /// Keys are JSON arrays so ids containing any separator stay unambiguous.
  static String _key(
    ToolUsageKind kind,
    String? pluginId,
    String? mcpServerId,
    String tool,
  ) => jsonEncode([kind.name, pluginId ?? '', mcpServerId ?? '', tool]);

  static ({ToolUsageKind kind, String? pluginId, String? serverId, String tool})?
  _parseKey(String key) {
    try {
      final l = jsonDecode(key);
      if (l is! List || l.length != 4) return null;
      final kind = ToolUsageKind.values
          .where((k) => k.name == l[0])
          .firstOrNull;
      if (kind == null) return null;
      String? opt(Object? v) => v is String && v.isNotEmpty ? v : null;
      return (
        kind: kind,
        pluginId: opt(l[1]),
        serverId: opt(l[2]),
        tool: l[3] is String ? l[3] as String : '',
      );
    } catch (_) {
      return null;
    }
  }

  /// Record one finished call.
  void record({
    required ToolUsageKind kind,
    required String tool,
    String? pluginId,
    String? mcpServerId,
    required bool ok,
    required Duration elapsed,
    String? error,
    String? agentType,
  }) {
    // Work done inside a subagent is attributed to it (Claude Code parity:
    // a subagent's MCP / plugin tool use is its own, visible per agent).
    agentType ??= SubagentScope.current?.agentType;
    final now = clockForTest();
    final bucket = (_days[_day(now)] ??= {}).putIfAbsent(
      _key(kind, pluginId, mcpServerId, tool),
      _Bucket.new,
    );
    final err = error == null
        ? null
        : error.length > _maxErrorChars
        ? '${error.substring(0, _maxErrorChars)}…'
        : error;
    bucket.add(
      ok: ok,
      ms: elapsed.inMilliseconds,
      at: now.millisecondsSinceEpoch,
      error: err,
      agentType: agentType,
    );
    _prune(now);
    _scheduleSave();
    notifyListeners();
  }

  Iterable<_Bucket> _matching({
    String? pluginId,
    String? mcpServerId,
    String? tool,
    ToolUsageKind? kind,
    required int days,
  }) sync* {
    final now = clockForTest();
    final cutoff = _day(now.subtract(Duration(days: days - 1)));
    for (final day in _days.entries) {
      if (day.key.compareTo(cutoff) < 0) continue;
      for (final e in day.value.entries) {
        final k = _parseKey(e.key);
        if (k == null) continue;
        if (kind != null && k.kind != kind) continue;
        if (pluginId != null && k.pluginId != pluginId) continue;
        if (mcpServerId != null && k.serverId != mcpServerId) continue;
        if (tool != null && k.tool != tool) continue;
        yield e.value;
      }
    }
  }

  static ToolUsageSummary _rollup(Iterable<_Bucket> buckets) {
    var calls = 0, errors = 0, total = 0, last = 0, lastErrAt = 0;
    String? lastError;
    final samples = <int>[];
    for (final b in buckets) {
      calls += b.calls;
      errors += b.errors;
      total += b.totalMs;
      samples.addAll(b.samples);
      last = math.max(last, b.lastUsedMs);
      if (b.errors > 0 && b.lastErrorMs >= lastErrAt) {
        lastErrAt = b.lastErrorMs;
        lastError = b.lastError;
      }
    }
    if (calls == 0) return ToolUsageSummary.empty;
    samples.sort();
    int? rank(double p) {
      if (samples.isEmpty) return null;
      final i = (p * samples.length).ceil() - 1;
      return samples[i.clamp(0, samples.length - 1)];
    }

    return ToolUsageSummary(
      calls: calls,
      errors: errors,
      p50Ms: rank(0.50),
      p95Ms: rank(0.95),
      avgMs: (total / calls).round(),
      lastUsed: last == 0 ? null : DateTime.fromMillisecondsSinceEpoch(last),
      lastError: lastError,
      lastErrorAt: lastErrAt == 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastErrAt),
    );
  }

  /// Rollup over the last [days] days, filtered by any given dimension.
  /// `pluginId` matches both a plugin's own tools and its MCP servers.
  ToolUsageSummary summary({
    String? pluginId,
    String? mcpServerId,
    String? tool,
    ToolUsageKind? kind,
    int days = retentionDays,
  }) => _rollup(
    _matching(
      pluginId: pluginId,
      mcpServerId: mcpServerId,
      tool: tool,
      kind: kind,
      days: days,
    ),
  );

  /// Calls made from inside subagents over the last [days] days, by
  /// `agent_type`, filtered by any given dimension. Main-conversation calls
  /// are not included.
  Map<String, int> agentCalls({
    String? pluginId,
    String? mcpServerId,
    String? tool,
    ToolUsageKind? kind,
    int days = retentionDays,
  }) {
    final out = <String, int>{};
    for (final b in _matching(
      pluginId: pluginId,
      mcpServerId: mcpServerId,
      tool: tool,
      kind: kind,
      days: days,
    )) {
      for (final e in b.agents.entries) {
        out[e.key] = (out[e.key] ?? 0) + e.value;
      }
    }
    return out;
  }

  /// Per-tool rollups for one MCP server (or one plugin), most-used first.
  Map<String, ToolUsageSummary> toolSummaries({
    String? mcpServerId,
    String? pluginId,
    int days = retentionDays,
  }) {
    final byTool = <String, List<_Bucket>>{};
    final now = clockForTest();
    final cutoff = _day(now.subtract(Duration(days: days - 1)));
    for (final day in _days.entries) {
      if (day.key.compareTo(cutoff) < 0) continue;
      for (final e in day.value.entries) {
        final k = _parseKey(e.key);
        if (k == null) continue;
        if (mcpServerId != null && k.serverId != mcpServerId) continue;
        if (pluginId != null && k.pluginId != pluginId) continue;
        (byTool[k.tool] ??= []).add(e.value);
      }
    }
    final out = {
      for (final e in byTool.entries) e.key: _rollup(e.value),
    };
    final sorted = out.entries.toList()
      ..sort((a, b) => b.value.calls.compareTo(a.value.calls));
    return {for (final e in sorted) e.key: e.value};
  }

  void _prune(DateTime now) {
    final cutoff = _day(now.subtract(const Duration(days: retentionDays - 1)));
    _days.removeWhere((day, _) => day.compareTo(cutoff) < 0);
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDelayForTest, () => unawaited(flush()));
  }

  /// Persist now (also called by the debounce timer).
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        prefsKey,
        jsonEncode({
          'v': 1,
          'days': {
            for (final d in _days.entries)
              d.key: {
                for (final b in d.value.entries) b.key: b.value.toJson(),
              },
          },
        }),
      );
    } catch (e) {
      Diag.swallow('tool_usage', e);
    }
  }

  /// Restore persisted rollups (once per process; boot).
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw);
      final days = j is Map ? j['days'] : null;
      if (days is! Map) return;
      for (final d in days.entries) {
        if (d.key is! String || d.value is! Map) continue;
        final target = _days[d.key as String] ??= {};
        for (final b in (d.value as Map).entries) {
          if (b.key is! String || b.value is! Map) continue;
          // Records made before load finished win over persisted copies.
          target.putIfAbsent(
            b.key as String,
            () => _Bucket.fromJson((b.value as Map).cast<String, dynamic>()),
          );
        }
      }
      _prune(clockForTest());
      notifyListeners();
    } catch (e) {
      Diag.swallow('tool_usage', e);
    }
  }

  /// Delete every recorded rollup (memory and disk).
  Future<void> clear() async {
    _days.clear();
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsKey);
    } catch (e) {
      Diag.swallow('tool_usage', e);
    }
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _days.clear();
    _saveTimer?.cancel();
    _saveTimer = null;
    _loaded = false;
    clockForTest = DateTime.now;
    saveDelayForTest = const Duration(seconds: 2);
  }
}

/// "2h ago"-style relative time for usage rows.
String usageRelativeTime(DateTime t, {DateTime? now}) {
  final d = (now ?? ToolUsageStore.clockForTest()).difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}
