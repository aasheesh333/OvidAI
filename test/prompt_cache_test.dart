import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/prompt_cache.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

Map<String, dynamic> tool(String name, {String desc = 'd'}) => {
  'type': 'function',
  'function': {
    'name': name,
    'description': desc,
    'parameters': {
      'type': 'object',
      'required': ['b', 'a'],
      'properties': {
        'z': {'type': 'string'},
        'a': {'type': 'string'},
      },
    },
  },
};

/// Strips markers and normalises string content to a single text block: the
/// provider hashes content, not its JSON representation, so a message sent
/// as a marked block one turn and a plain string the next is the same prefix.
dynamic stripCc(dynamic v) {
  if (v is Map) {
    if (v['content'] is String && v.containsKey('role')) {
      return stripCc({
        ...v,
        'content': [
          {'type': 'text', 'text': v['content']},
        ],
      });
    }
    return {
      for (final e in v.entries)
        if (e.key != 'cache_control') e.key: stripCc(e.value),
    };
  }
  if (v is List) return [for (final e in v) stripCc(e)];
  return v;
}

int countCc(Object? v) => jsonEncode(v).split('"cache_control"').length - 1;

PromptCacheCaps caps({
  bool global = true,
  PromptCacheOverride o = PromptCacheOverride.auto,
  ApiFormat f = ApiFormat.openai,
  String model = 'claude-sonnet-4.6',
  String url = 'https://api.ovidsi.com/v1',
  bool cloud = true,
}) => PromptCache.resolve(
  globalEnabled: global,
  override: o,
  format: f,
  model: model,
  baseUrl: url,
  isOvidCloud: cloud,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('prompt-cache-');
    SessionLedger.rootOverrideForTest = tmp;
    SessionSearch.dbPathOverrideForTest = '${tmp.path}/search.db';
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux, () {
        try {
          return ffi.DynamicLibrary.open('libsqlite3.so.0');
        } catch (_) {
          return ffi.DynamicLibrary.open(
            '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
          );
        }
      });
    }
    await AppState.I.initialize();
  });

  tearDownAll(() {
    SessionLedger.rootOverrideForTest = null;
    SessionSearch.dbPathOverrideForTest = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('capability gating', () {
    test('Ovid Cloud Claude gets blocks + tool markers', () {
      final c = caps();
      expect(c.mode, PromptCacheMode.openaiBlocks);
      expect(c.toolMarkers, isTrue);
    });
    test('OpenRouter Claude gets blocks, no tool markers', () {
      final c = caps(
        model: 'anthropic/claude-sonnet-4.6',
        url: 'https://openrouter.ai/api/v1',
        cloud: false,
      );
      expect(c.mode, PromptCacheMode.openaiBlocks);
      expect(c.toolMarkers, isFalse);
    });
    test('BYOK custom endpoint defaults to no markers', () {
      final c = caps(
        model: 'claude-sonnet-4.6',
        url: 'https://my-proxy.example.com/v1',
        cloud: false,
      );
      expect(c.mode, PromptCacheMode.implicit);
      expect(c.marks, isFalse);
    });
    test('per-provider override on forces markers, off disables', () {
      expect(
        caps(
          o: PromptCacheOverride.on,
          url: 'https://my-proxy.example.com/v1',
          cloud: false,
          model: 'my-model',
        ).mode,
        PromptCacheMode.openaiBlocks,
      );
      expect(caps(o: PromptCacheOverride.off).mode, PromptCacheMode.none);
      expect(caps(global: false).mode, PromptCacheMode.none);
    });
    test('non-Claude models on Ovid Cloud never get markers', () {
      expect(caps(model: 'gpt-5.6-mini').marks, isFalse);
      expect(caps(model: 'gemini-3-pro').marks, isFalse);
    });
    test('Anthropic format endpoints are native', () {
      expect(
        caps(f: ApiFormat.anthropic, cloud: false, model: 'x').mode,
        PromptCacheMode.anthropicNative,
      );
    });
    test('provider override persists and defaults to auto', () {
      final p = ProviderConfig(
        id: 'x',
        name: 'x',
        description: '',
        baseUrl: 'https://a.test',
      );
      expect(p.promptCache, PromptCacheOverride.auto);
      expect(p.toPersistedJson().containsKey('promptCache'), isFalse);
      p.promptCache = PromptCacheOverride.on;
      final q = ProviderConfig(
        id: 'x',
        name: 'x',
        description: '',
        baseUrl: 'https://a.test',
      )..applyPersistedJson(p.toPersistedJson());
      expect(q.promptCache, PromptCacheOverride.on);
    });
  });

  group('stable tools', () {
    test('sorted by name with canonical key order, load-order independent', () {
      final a = PromptCache.canonicalTools([tool('b'), tool('a'), tool('c')]);
      final b = PromptCache.canonicalTools([tool('c'), tool('b'), tool('a')]);
      expect(jsonEncode(a), jsonEncode(b));
      expect(a.map((t) => (t['function'] as Map)['name']), ['a', 'b', 'c']);
      final props = (((a.first['function'] as Map)['parameters'] as Map)
          ['properties'] as Map);
      expect(props.keys.toList(), ['a', 'z']);
      // arrays keep their order (semantic)
      expect(
        ((a.first['function'] as Map)['parameters'] as Map)['required'],
        ['b', 'a'],
      );
    });
  });

  List<Map<String, dynamic>> convo(int turns, {bool volatileTail = true}) {
    final m = <Map<String, dynamic>>[
      {'role': 'system', 'content': 'SYSTEM PROMPT'},
      {'role': 'user', 'content': 'u0'},
    ];
    for (var i = 0; i < turns; i++) {
      m.add({
        'role': 'assistant',
        'content': 'thinking $i',
        'tool_calls': [
          {
            'id': 'c$i',
            'type': 'function',
            'function': {'name': 'a', 'arguments': '{}'},
          },
        ],
      });
      m.add({'role': 'tool', 'tool_call_id': 'c$i', 'content': 'result $i'});
    }
    return m;
  }

  group('OpenAI-format request shape', () {
    test('max 4 breakpoints: tools, system, rolling messages', () {
      final msgs = convo(6);
      final r = PromptCache.applyOpenAi(
        caps: caps(),
        messages: msgs,
        tools: [tool('b'), tool('a')],
      );
      expect(r.breakpoints, lessThanOrEqualTo(4));
      expect(countCc(r.messages) + countCc(r.tools), r.breakpoints);
      expect(countCc(r.tools), 1);
      // last tool carries the marker
      expect((r.tools.last).containsKey('cache_control'), isTrue);
      // system block marked
      expect(jsonEncode(r.messages.first), contains('cache_control'));
      // last message marked
      expect(jsonEncode(r.messages.last), contains('cache_control'));
      // inputs not mutated
      expect(countCc(msgs), 0);
    });

    test('1h TTL flag only when requested', () {
      final five = PromptCache.applyOpenAi(
        caps: caps(),
        messages: convo(2),
        tools: [tool('a')],
      );
      expect(jsonEncode(five.messages), isNot(contains('"ttl"')));
      final hour = PromptCache.applyOpenAi(
        caps: caps(),
        messages: convo(2),
        tools: [tool('a')],
        ttl1h: true,
      );
      expect(jsonEncode(hour.messages), contains('"ttl":"1h"'));
      expect(jsonEncode(hour.tools), contains('"ttl":"1h"'));
    });

    test('unsupported provider: no cache_control anywhere', () {
      for (final c in [
        caps(model: 'gpt-5.6-mini'),
        caps(
          url: 'https://byok.example/v1',
          cloud: false,
          model: 'claude-sonnet-4.6',
        ),
        caps(global: false),
      ]) {
        final r = PromptCache.applyOpenAi(
          caps: c,
          messages: convo(3),
          tools: [tool('a')],
        );
        expect(countCc(r.messages) + countCc(r.tools), 0);
      }
    });

    test('disabled caching leaves tools and messages untouched', () {
      final tools = [tool('b'), tool('a')];
      final r = PromptCache.applyOpenAi(
        caps: caps(global: false),
        messages: convo(1),
        tools: tools,
      );
      expect(identical(r.tools, tools), isTrue);
    });

    test('OpenRouter: 3 message breakpoints, none on tools', () {
      final r = PromptCache.applyOpenAi(
        caps: caps(
          model: 'anthropic/claude-sonnet-4.6',
          url: 'https://openrouter.ai/api/v1',
          cloud: false,
        ),
        messages: convo(6),
        tools: [tool('a')],
      );
      expect(countCc(r.tools), 0);
      expect(r.breakpoints, lessThanOrEqualTo(4));
    });
  });

  group('Anthropic-native request shape', () {
    ({
      Object? system,
      List<Map<String, dynamic>> messages,
      List<Map<String, dynamic>> tools,
      int breakpoints,
    })
    shape(List<Map<String, dynamic>> msgs, {bool ttl1h = false}) {
      final map = <int>[];
      final conv = AgentService.I.anthropicRequestMessagesForTest(
        msgs,
        volatileAsUser: true,
        sourceToOut: map,
      );
      return PromptCache.applyAnthropic(
        caps: caps(f: ApiFormat.anthropic, cloud: false, model: 'claude-x'),
        system: conv.system,
        source: msgs,
        converted: conv.messages,
        sourceToOut: map,
        tools: AgentService.I.anthropicToolsForTest(
          PromptCache.canonicalTools([tool('b'), tool('a')]),
        ),
        ttl1h: ttl1h,
      );
    }

    test('at most 4 breakpoints; system is a cached block', () {
      final r = shape(convo(5));
      expect(r.breakpoints, lessThanOrEqualTo(4));
      expect(r.breakpoints, greaterThanOrEqualTo(3));
      expect(r.system, isA<List>());
      expect(
        countCc(r.system) + countCc(r.tools) + countCc(r.messages),
        r.breakpoints,
      );
    });

    test('volatile system row is not hoisted into the cached system', () {
      final msgs = convo(1)
        ..add(PromptCache.markVolatile({'role': 'user', 'content': 'MEM'}))
        ..add(
          PromptCache.markVolatile({'role': 'system', 'content': 'TODO NOW'}),
        );
      final r = shape(msgs);
      expect(jsonEncode(r.system), isNot(contains('TODO NOW')));
      expect(jsonEncode(r.messages), contains('TODO NOW'));
    });

    test('1h ttl flag', () {
      expect(jsonEncode(shape(convo(2), ttl1h: true).system), contains('1h'));
      expect(jsonEncode(shape(convo(2)).system), isNot(contains('1h')));
    });
  });

  group('golden: prefix stability across turns', () {
    List<Map<String, dynamic>> turnRows(int turns) {
      final rows = convo(turns);
      return rows;
    }

    test('OpenAI-format: turn N+1 body extends turn N byte-for-byte', () {
      final tools = [tool('zeta'), tool('alpha'), tool('mid')];
      Map<String, dynamic> body(List<Map<String, dynamic>> msgs) {
        final r = PromptCache.applyOpenAi(
          caps: caps(),
          messages: msgs,
          tools: tools,
        );
        return {'tools': r.tools, 'messages': r.messages};
      }

      final t1 = turnRows(3);
      final t2 = turnRows(4);
      final b1 = stripCc(body(t1)) as Map;
      final b2 = stripCc(body(t2)) as Map;
      expect(jsonEncode(b2['tools']), jsonEncode(b1['tools']));
      final m1 = (b1['messages'] as List).map(jsonEncode).toList();
      final m2 = (b2['messages'] as List).map(jsonEncode).toList();
      expect(m2.sublist(0, m1.length), m1);
    });

    test('tool load order does not change the serialised prefix', () {
      String sig(List<Map<String, dynamic>> tools) {
        final r = PromptCache.applyOpenAi(
          caps: caps(),
          messages: convo(2),
          tools: tools,
        );
        return PromptCache.prefixThroughLastBreakpoint({
          'tools': r.tools,
          'messages': r.messages,
        });
      }

      expect(
        sig([tool('c'), tool('a'), tool('b')]),
        sig([tool('b'), tool('c'), tool('a')]),
      );
    });
  });

  group('usage parsing', () {
    test('Anthropic raw and normalised', () {
      final raw = PromptCache.parseUsage({
        'input_tokens': 10,
        'cache_creation_input_tokens': 500,
        'cache_read_input_tokens': 4000,
      });
      expect((raw.read, raw.write), (4000, 500));
      final norm = PromptCache.parseUsage({
        'prompt_tokens': 4510,
        'cache_read_tokens': 4000,
        'cache_write_tokens': 500,
      });
      expect((norm.read, norm.write), (4000, 500));
    });
    test('OpenAI prompt_tokens_details.cached_tokens', () {
      final u = PromptCache.parseUsage({
        'prompt_tokens': 3000,
        'prompt_tokens_details': {'cached_tokens': 2048},
      });
      expect((u.read, u.write), (2048, 0));
    });
    test('LiteLLM / OpenRouter / DeepSeek variants', () {
      final l = PromptCache.parseUsage({
        'cache_read_input_tokens': 7,
        'cache_creation_input_tokens': 3,
      });
      expect((l.read, l.write), (7, 3));
      final o = PromptCache.parseUsage({
        'prompt_tokens_details': {'cached_tokens': 9, 'cache_write_tokens': 4},
      });
      expect((o.read, o.write), (9, 4));
      expect(PromptCache.parseUsage({'prompt_cache_hit_tokens': 5}).read, 5);
      expect(PromptCache.parseUsage(null).any, isFalse);
      expect(PromptCache.parseUsage({'prompt_tokens': 1}).any, isFalse);
    });
  });

  group('cost estimate', () {
    test('Claude: reads 0.1x, 5m writes 1.25x, 1h writes 2x', () {
      // sonnet $3/MTok, 1M prompt: 400k read, 100k write, 500k fresh
      double c({bool h = false}) => AgentService.estimatedCostForModel(
        'claude-sonnet-4.6',
        1000000,
        0,
        cacheReadTokens: 400000,
        cacheWriteTokens: 100000,
        cacheTtl1h: h,
      )!;
      expect(c(), closeTo(0.5 * 3 + 0.4 * 0.3 + 0.1 * 3.75, 1e-9));
      expect(c(h: true), closeTo(0.5 * 3 + 0.4 * 0.3 + 0.1 * 6, 1e-9));
    });
    test('no cache fields = legacy price', () {
      expect(
        AgentService.estimatedCostForModel('claude-sonnet-4.6', 1000000, 0),
        closeTo(3, 1e-9),
      );
    });
    test('cachedPercent', () {
      expect(PromptCache.cachedPercent(50, 200), 25);
      expect(PromptCache.cachedPercent(0, 0), 0);
      final a = SessionAnalytics()
        ..add(inputTokens: 1000, cacheReadTokens: 900);
      expect(a.cachedPercent, 90);
    });
  });

  group('real request rows + compaction', () {
    ChatSession session() {
      final s = ChatSession(id: 'pc-1', title: 't', model: 'm', mode: 'auto');
      for (var i = 0; i < 12; i++) {
        s.messages.add(Message(role: 'user', content: 'ask $i'));
        s.messages.add(Message(role: 'assistant', content: 'answer $i'));
      }
      return s;
    }

    test('volatile block and memory are tagged and come last', () {
      final s = session();
      final rows = AgentService.I.buildRequestMessages(
        s,
        'SYS',
        volatile: 'GOAL: x\nTODO: y',
      );
      expect(PromptCache.isVolatile(rows.last), isTrue);
      expect(rows.last['content'], contains('GOAL'));
      expect(PromptCache.isVolatile(rows.first), isFalse);
      // boundary mark lands before the volatile row
      final marks = PromptCache.messageMarks(rows, budget: 2);
      expect(marks.last, lessThan(rows.length - 1));
    });

    test('per-turn volatile changes do not alter the cached prefix', () {
      final s = session();
      String prefix(String vol) {
        final rows = AgentService.I.buildRequestMessages(
          s,
          'SYS',
          volatile: vol,
        );
        final r = PromptCache.applyOpenAi(
          caps: caps(),
          messages: rows,
          tools: [tool('a')],
        );
        // Prefix = everything before the volatile tail row.
        return jsonEncode(
          stripCc([r.tools, r.messages.sublist(0, r.messages.length - 1)]),
        );
      }

      expect(prefix('clock 10:00 todo A'), prefix('clock 10:05 todo B'));
    });

    test('after compaction the checkpoint is stable and caching resumes', () {
      final s = session();
      s.compactedSummary = 'summary of earlier work';
      s.messages.insert(
        0,
        Message(role: 'assistant', content: 'cp', kind: MsgKind.compact),
      );
      s.compactedAtCount = 0;
      List<Map<String, dynamic>> turn(int extra) {
        final rows = AgentService.I.buildRequestMessages(
          s,
          'SYS',
          volatile: 'clock frozen',
        );
        // same turn's tail growth inside the run
        for (var i = 0; i < extra; i++) {
          rows.add({'role': 'assistant', 'content': 'a$i'});
          rows.add({'role': 'user', 'content': 'r$i'});
        }
        return rows;
      }

      final a = turn(1);
      final b = turn(2);
      expect(a[1]['content'], contains('<compacted-summary>'));
      expect(b[1]['content'], a[1]['content']);
      final ra = PromptCache.applyOpenAi(
        caps: caps(),
        messages: a,
        tools: [tool('a')],
      );
      final rb = PromptCache.applyOpenAi(
        caps: caps(),
        messages: b,
        tools: [tool('a')],
      );
      final la = (stripCc(ra.messages) as List).map(jsonEncode).toList();
      final lb = (stripCc(rb.messages) as List).map(jsonEncode).toList();
      // frozen volatile row + earlier rows are the identical prefix
      expect(lb.sublist(0, la.length - 2), la.sublist(0, la.length - 2));
      expect(countCc(rb.messages), greaterThan(0));
    });
  });
}
