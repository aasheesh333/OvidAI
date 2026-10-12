import 'dart:convert';

import 'state.dart' show ApiFormat;

/// Provider-aware prompt caching (request shaping + usage parsing + cost).
///
/// Long agent sessions resend system prompt + tool schemas + history every
/// turn. This file keeps that prefix byte-stable and, for providers that need
/// explicit markers (Anthropic native, Claude behind LiteLLM/OpenRouter),
/// places up to [maxBreakpoints] `cache_control` breakpoints. Providers that
/// cache a stable prefix automatically (OpenAI, Gemini, DeepSeek...) get no
/// markers, only the stable ordering.
///
/// Pure functions only: no I/O, no AppState reads, so every rule is unit
/// testable.

/// Per-provider user override (Provider settings).
enum PromptCacheOverride {
  auto,
  on,
  off;

  static PromptCacheOverride parse(Object? raw) {
    final v = (raw is String ? raw : '').trim().toLowerCase();
    for (final o in PromptCacheOverride.values) {
      if (o.name == v) return o;
    }
    return PromptCacheOverride.auto;
  }
}

enum PromptCacheMode {
  /// Caching disabled (global switch or provider override): legacy request.
  none,

  /// Stable ordering only; provider caches the prefix by itself.
  implicit,

  /// `cache_control` content blocks inside an OpenAI-format request
  /// (Claude via LiteLLM / OpenRouter).
  openaiBlocks,

  /// Anthropic Messages API native.
  anthropicNative,
}

class PromptCacheCaps {
  const PromptCacheCaps(this.mode, {this.toolMarkers = false});
  final PromptCacheMode mode;

  /// Whether a marker may be put on the last tool definition (LiteLLM and
  /// Anthropic accept it; OpenRouter only documents message content blocks,
  /// where the system breakpoint already covers the tools before it).
  final bool toolMarkers;

  bool get marks =>
      mode == PromptCacheMode.openaiBlocks ||
      mode == PromptCacheMode.anthropicNative;
  bool get stable => mode != PromptCacheMode.none;
}

/// Token pricing multipliers relative to the base input price.
class CacheRates {
  const CacheRates(this.read, this.write5m, this.write1h);
  final double read;
  final double write5m;
  final double write1h;
}

class CacheUsage {
  const CacheUsage({this.read = 0, this.write = 0});
  final int read;
  final int write;
  bool get any => read > 0 || write > 0;
}

class PromptCache {
  PromptCache._();

  /// Anthropic allows at most four breakpoints per request.
  static const maxBreakpoints = 4;

  // Identity-keyed tags: never serialised into the request body.
  static final Expando<bool> _volatile = Expando<bool>('promptCacheVolatile');

  /// Tag a request row as volatile (memory, todos/goal/clock block). Such
  /// rows sit after the history boundary and never in the system prefix.
  static Map<String, dynamic> markVolatile(Map<String, dynamic> row) {
    _volatile[row] = true;
    return row;
  }

  static bool isVolatile(Map row) => _volatile[row] == true;

  static String baseModel(String model) =>
      model.split('·').first.trim().toLowerCase();

  /// Capability gate. Unknown / custom endpoints never receive markers
  /// unless the user turns them on for that provider.
  static PromptCacheCaps resolve({
    required bool globalEnabled,
    required PromptCacheOverride override,
    required ApiFormat format,
    required String model,
    required String baseUrl,
    required bool isOvidCloud,
  }) {
    if (!globalEnabled || override == PromptCacheOverride.off) {
      return const PromptCacheCaps(PromptCacheMode.none);
    }
    if (format == ApiFormat.anthropic) {
      // An explicitly Anthropic-format endpoint speaks the Messages API,
      // which defines cache_control.
      return const PromptCacheCaps(
        PromptCacheMode.anthropicNative,
        toolMarkers: true,
      );
    }
    final m = baseModel(model);
    final claude = m.contains('claude');
    final host = (Uri.tryParse(baseUrl)?.host ?? '').toLowerCase();
    final openRouter = host.endsWith('openrouter.ai');
    if (override == PromptCacheOverride.on) {
      return PromptCacheCaps(
        PromptCacheMode.openaiBlocks,
        toolMarkers: isOvidCloud,
      );
    }
    if (claude && (isOvidCloud || openRouter)) {
      return PromptCacheCaps(
        PromptCacheMode.openaiBlocks,
        toolMarkers: isOvidCloud,
      );
    }
    return const PromptCacheCaps(PromptCacheMode.implicit);
  }

  static Map<String, dynamic> cacheControl({required bool ttl1h}) => {
    'type': 'ephemeral',
    if (ttl1h) 'ttl': '1h',
  };

  // ── stable serialisation ────────────────────────────────────────────

  /// Recursively key-sorted copy (object key order is not semantic JSON).
  static dynamic canonicalize(dynamic v) {
    if (v is Map) {
      final keys = v.keys.map((k) => k.toString()).toList()..sort();
      return {for (final k in keys) k: canonicalize(v[k])};
    }
    if (v is List) return [for (final e in v) canonicalize(e)];
    return v;
  }

  static String _toolName(Map t) {
    final fn = t['function'];
    final n = fn is Map ? fn['name'] : t['name'];
    return n?.toString() ?? '';
  }

  /// Tools sorted by name (stable for equal names) with canonical key order,
  /// so the serialised roster is identical turn to turn regardless of
  /// plugin/MCP load order.
  static List<Map<String, dynamic>> canonicalTools(
    List<Map<String, dynamic>> tools,
  ) {
    final idx = List<int>.generate(tools.length, (i) => i);
    idx.sort((a, b) {
      final c = _toolName(tools[a]).compareTo(_toolName(tools[b]));
      return c != 0 ? c : a.compareTo(b);
    });
    return [
      for (final i in idx) canonicalize(tools[i]) as Map<String, dynamic>,
    ];
  }

  // ── breakpoint placement ────────────────────────────────────────────

  static bool _hasContent(Map m) {
    final c = m['content'];
    if (c is String) return c.trim().isNotEmpty;
    if (c is List) return c.isNotEmpty;
    return false;
  }

  /// Number of leading non-volatile system rows (the system prefix).
  static int systemPrefixLength(List<Map<String, dynamic>> msgs) {
    var i = 0;
    while (i < msgs.length && msgs[i]['role'] == 'system' && !isVolatile(msgs[i])) {
      i++;
    }
    return i;
  }

  /// Source indexes (into [msgs]) that receive a rolling breakpoint, in
  /// priority order: the last message (extends the prefix every turn), the
  /// end of stable history (before memory/volatile rows, so the next run
  /// still hits), then the second-to-last message.
  static List<int> messageMarks(
    List<Map<String, dynamic>> msgs, {
    required int budget,
    bool Function(Map<String, dynamic>)? eligible,
  }) {
    if (budget <= 0) return const [];
    final skip = systemPrefixLength(msgs);
    bool ok(int i) =>
        i >= skip &&
        _hasContent(msgs[i]) &&
        (eligible == null || eligible(msgs[i]));
    final elig = [
      for (var i = 0; i < msgs.length; i++)
        if (ok(i)) i,
    ];
    if (elig.isEmpty) return const [];
    final picks = <int>[];
    void add(int i) {
      if (!picks.contains(i) && picks.length < budget) picks.add(i);
    }

    add(elig.last);
    final firstVol = msgs.indexWhere(isVolatile);
    if (firstVol > 0) {
      final before = elig.where((i) => i < firstVol);
      if (before.isNotEmpty) add(before.last);
    }
    if (elig.length >= 2) add(elig[elig.length - 2]);
    return picks;
  }

  static Map<String, dynamic> _markContent(
    Map<String, dynamic> m,
    Map<String, dynamic> cc,
  ) {
    final c = m['content'];
    final out = Map<String, dynamic>.from(m);
    if (c is String) {
      out['content'] = [
        {'type': 'text', 'text': c, 'cache_control': cc},
      ];
    } else if (c is List && c.isNotEmpty) {
      final blocks = [
        for (final b in c) b is Map ? Map<String, dynamic>.from(b) : b,
      ];
      final last = blocks.last;
      if (last is Map<String, dynamic>) last['cache_control'] = cc;
      out['content'] = blocks;
    }
    return out;
  }

  /// OpenAI-format request: returns marked copies; inputs are not mutated.
  static ({
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools,
    int breakpoints,
  })
  applyOpenAi({
    required PromptCacheCaps caps,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    bool ttl1h = false,
  }) {
    if (!caps.stable) {
      return (messages: messages, tools: tools, breakpoints: 0);
    }
    final outTools = canonicalTools(tools);
    if (!caps.marks) {
      return (messages: messages, tools: outTools, breakpoints: 0);
    }
    final cc = cacheControl(ttl1h: ttl1h);
    var used = 0;
    if (caps.toolMarkers && outTools.isNotEmpty) {
      outTools[outTools.length - 1] = {...outTools.last, 'cache_control': cc};
      used++;
    }
    final out = [...messages];
    final sysLen = systemPrefixLength(messages);
    if (sysLen > 0 && _hasContent(messages[sysLen - 1])) {
      out[sysLen - 1] = _markContent(messages[sysLen - 1], cc);
      used++;
    }
    for (final i in messageMarks(messages, budget: maxBreakpoints - used)) {
      out[i] = _markContent(messages[i], cc);
      used++;
    }
    return (messages: out, tools: outTools, breakpoints: used);
  }

  /// Anthropic-native request. [system] is the joined stable system text,
  /// [converted] the converted messages, [sourceToOut] maps each source row
  /// to the converted row that carries it (-1 for hoisted system rows).
  static ({
    Object? system,
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools,
    int breakpoints,
  })
  applyAnthropic({
    required PromptCacheCaps caps,
    required String system,
    required List<Map<String, dynamic>> source,
    required List<Map<String, dynamic>> converted,
    required List<int> sourceToOut,
    required List<Map<String, dynamic>> tools,
    bool ttl1h = false,
  }) {
    if (!caps.marks) {
      return (
        system: system.isEmpty ? null : system,
        messages: converted,
        tools: tools,
        breakpoints: 0,
      );
    }
    final cc = cacheControl(ttl1h: ttl1h);
    var used = 0;
    final outTools = [...tools];
    if (caps.toolMarkers && outTools.isNotEmpty) {
      outTools[outTools.length - 1] = {...outTools.last, 'cache_control': cc};
      used++;
    }
    Object? sys = system.isEmpty ? null : system;
    if (system.isNotEmpty) {
      sys = [
        {'type': 'text', 'text': system, 'cache_control': cc},
      ];
      used++;
    }
    final out = [...converted];
    final marked = <int>{};
    final marks = messageMarks(
      source,
      budget: maxBreakpoints - used,
      eligible: (m) => m['role'] != 'system' || isVolatile(m),
    );
    for (final si in marks) {
      final oi = si < sourceToOut.length ? sourceToOut[si] : -1;
      if (oi < 0 || oi >= out.length || !marked.add(oi)) continue;
      out[oi] = _markAnthropicMessage(out[oi], cc);
      used++;
    }
    return (system: sys, messages: out, tools: outTools, breakpoints: used);
  }

  static Map<String, dynamic> _markAnthropicMessage(
    Map<String, dynamic> m,
    Map<String, dynamic> cc,
  ) {
    final c = m['content'];
    final out = Map<String, dynamic>.from(m);
    if (c is String) {
      out['content'] = [
        {'type': 'text', 'text': c, 'cache_control': cc},
      ];
    } else if (c is List && c.isNotEmpty) {
      final blocks = [
        for (final b in c) b is Map ? Map<String, dynamic>.from(b) : b,
      ];
      (blocks.last as Map<String, dynamic>)['cache_control'] = cc;
      out['content'] = blocks;
    }
    return out;
  }

  /// Serialised request prefix up to and including the last breakpoint, used
  /// by the golden stability test.
  static String prefixThroughLastBreakpoint(Map<String, dynamic> body) {
    final msgs = (body['messages'] as List?) ?? const [];
    var last = -1;
    for (var i = 0; i < msgs.length; i++) {
      if (jsonEncode(msgs[i]).contains('"cache_control"')) last = i;
    }
    return jsonEncode({
      'tools': body['tools'],
      'system': body['system'],
      'messages': last < 0 ? const [] : msgs.sublist(0, last + 1),
    });
  }

  // ── usage parsing ───────────────────────────────────────────────────

  static int? _int(Object? v) => v is num ? v.toInt() : null;

  /// Reads cache read/write token counts from any supported usage shape:
  /// Anthropic raw (`cache_read_input_tokens`/`cache_creation_input_tokens`),
  /// the app-normalised `cache_read_tokens`/`cache_write_tokens`, OpenAI
  /// `prompt_tokens_details.cached_tokens`, LiteLLM/OpenRouter variants and
  /// DeepSeek `prompt_cache_hit_tokens`.
  static CacheUsage parseUsage(Map<String, dynamic>? u) {
    if (u == null) return const CacheUsage();
    final d = u['prompt_tokens_details'];
    final details = d is Map ? d : const {};
    final read =
        _int(u['cache_read_tokens']) ??
        _int(u['cache_read_input_tokens']) ??
        _int(details['cached_tokens']) ??
        _int(u['prompt_cache_hit_tokens']) ??
        0;
    final write =
        _int(u['cache_write_tokens']) ??
        _int(u['cache_creation_input_tokens']) ??
        _int(details['cache_write_tokens']) ??
        _int(details['cache_creation_tokens']) ??
        _int(u['cache_creation_tokens']) ??
        0;
    return CacheUsage(read: read < 0 ? 0 : read, write: write < 0 ? 0 : write);
  }

  // ── cost ────────────────────────────────────────────────────────────

  static CacheRates ratesFor(String model) {
    final m = baseModel(model);
    if (m.contains('claude')) return const CacheRates(0.1, 1.25, 2.0);
    if (m.contains('deepseek')) return const CacheRates(0.1, 1, 1);
    if (m.contains('gemini')) return const CacheRates(0.25, 1, 1);
    if (m.contains('gpt-4.1') || m.contains('gpt-5')) {
      return const CacheRates(0.25, 1, 1);
    }
    return const CacheRates(0.5, 1, 1);
  }

  /// Input-side cost in USD. [inputTokens] is the TOTAL prompt size
  /// (including cached tokens, as every provider reports it).
  static double inputCost({
    required String model,
    required double pricePerMTok,
    required int inputTokens,
    int cacheRead = 0,
    int cacheWrite = 0,
    bool ttl1h = false,
  }) {
    final r = ratesFor(model);
    final read = cacheRead.clamp(0, inputTokens);
    final write = cacheWrite.clamp(0, inputTokens - read);
    final fresh = inputTokens - read - write;
    final wm = ttl1h ? r.write1h : r.write5m;
    return (fresh + read * r.read + write * wm) / 1e6 * pricePerMTok;
  }

  /// Share of input tokens served from cache, 0..100.
  static double cachedPercent(int cacheRead, int inputTokens) =>
      inputTokens <= 0 ? 0 : (cacheRead / inputTokens * 100).clamp(0, 100);
}
