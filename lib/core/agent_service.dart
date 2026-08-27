import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart'
    show IconData, Icons, Color;
import 'package:webview_flutter/webview_flutter.dart';
import '../core/theme.dart';
import 'state.dart';
import 'sandbox_service.dart';
import 'github_service.dart';
import 'repo_cache.dart';

/// ═══════════════════════════════════════════════════════════════════
/// AGENT ACCESS MODES (Codex-style)
/// ───────────────────────────────────────────────────────────────────
/// SAFE  → sirf read kare; har action pe user se poochhe
/// AUTO  → sandbox + browser free; repo writes poochhe
/// DRIVE → sab kuch free, no confirmation (DSH/Codex full-send)
/// ═══════════════════════════════════════════════════════════════════
enum AgentMode { safe, auto, drive }

extension AgentModeX on AgentMode {
  String get label => switch (this) {
        AgentMode.safe => 'Safe',
        AgentMode.auto => 'Auto',
        AgentMode.drive => 'Drive',
      };
  String get hint => switch (this) {
        AgentMode.safe =>
          'Read-only. Har shell / browser / write se pehle permission maangega.',
        AgentMode.auto =>
          'Shell aur browser khud chalayega. Repo me push se pehle poochega.',
        AgentMode.drive =>
          'Full autonomous — kuch bhi, kahin bhi, no confirmation.',
      };
  IconData get icon => switch (this) {
        AgentMode.safe => Icons.shield_outlined,
        AgentMode.auto => Icons.bolt_outlined,
        AgentMode.drive => Icons.rocket_launch_outlined,
      };
  Color get color => switch (this) {
        AgentMode.safe => Aether.success,
        AgentMode.auto => Aether.accent,
        AgentMode.drive => Aether.warn,
      };
}

/// Live event jisse screens subscribe hote hain.
/// kind: think | shell | shellOut | nav | page | file | err | done
class AgentEvent {
  final String kind;
  final String text;
  final DateTime time;
  AgentEvent(this.kind, this.text) : time = DateTime.now();
}

class ApprovalRequest {
  final String tool;
  final String summary;
  final String detail;
  final Completer<bool> completer = Completer<bool>();
  ApprovalRequest({required this.tool, required this.summary, required this.detail});
}

/// ═════════════════════════════ OpenAI-compatible LLM bridge ═══════════
/// SSE streaming + tool-calling agent loop — DSH-web harness style.
///
/// Response chunk schema (SSE `data:` lines):
///   {"choices":[{"delta":{
///     "role":"assistant",
///     "content": "...",                  ← final answer token → bubble
///     "reasoning" | "reasoning_content": "...",  ← thinking tokens → live
///     "tool_calls":[{"index":0,"id":"...","function":{"name":"...","arguments":"fragment"}}]
///   }}]}
///
/// Final usage: {"usage":{"prompt_tokens","completion_tokens","total_tokens"}}
/// Non-stream fallback: choices[0].message.* with reasoning_content support.

///                  ← tool results loop back to model till final answer
class AgentService extends ChangeNotifier {
  AgentService._();
  static final AgentService I = AgentService._();

  AgentMode mode = AgentMode.auto;

  final List<AgentEvent> events = [];
  String? activeRunId;
  ApprovalRequest? pendingApproval;

  /// Browser live state
  String? browserUrl;
  String? browserPageText;
  String? previewFile; // local path to index.html for WebView

  /// Live WebView binding (set by BrowserScreen) — agent can drive it.
  WebViewController? _webView;
  void bindWebView(WebViewController c) { _webView = c; }
  void unbindWebView() { _webView = null; }

  /// Studio live buffers (path → content) written by repo_write,
  /// ya repo_read se load hua. Studio isko render karta hai.
  final Map<String, String> fileBuffer = {};
  String? activeFilePath;
  String? repoFull; // e.g. "aasheesh333/Ovid"

  bool get busy => activeRunId != null;

  void setMode(AgentMode m) {
    mode = m;
    events.add(AgentEvent('think', 'access mode → ${m.label}'));
    notifyListeners();
  }

  void _emit(String kind, String text) {
    events.add(AgentEvent(kind, text));
    if (events.length > 120) events.removeRange(0, events.length - 120);
    notifyListeners();
  }

  void refreshNow() => notifyListeners();

  void approve(bool ok) {
    pendingApproval?.completer.complete(ok);
    pendingApproval = null;
    notifyListeners();
  }

  // ── Provider / endpoint resolution ────────────────────────────────────
  ProviderConfig? get _provider {
    for (final p in AppState.I.providers) {
      if (p.hasKey &&
          p.apiKey.isNotEmpty &&
          p.selectedModel != null &&
          p.selectedModel!.isNotEmpty) {
        return p;
      }
    }
    return null;
  }

  Uri _endpoint(ProviderConfig p) {
    var b = p.baseUrl;
    if (!b.endsWith('/')) b += '/';
    // Gemini OpenAI-compat layer
    if (b.contains('generativelanguage')) b = '${b}openai/';
    return Uri.parse('${b}chat/completions');
  }

  // ── TOOLS (OpenAI function-calling schema) ────────────────────────────
  // Dynamic: installed plugins add their own tools.
  List<Map<String, dynamic>> get _tools {
    final tools = <Map<String, dynamic>>[];
    // Core agent tools — always available
    tools.addAll(_coreTools);
    // Installed plugin tools — dynamically appended
    final app = AppState.I;
    for (final p in app.plugins.where((p) => p.installed && p.enabled)) {
      if (p.name == 'Web Search') tools.add(_webSearchTool);
      if (p.name == 'Image Studio') tools.add(_imageGenTool);
      if (p.name == 'File Reader') tools.add(_fileReadTool);
      if (p.name == 'Web Fetch & Reader') tools.add(_webFetchTool);
      if (p.name == 'Code Runner') tools.add(_codeRunnerTool);
      if (p.name == 'RAG Memory') tools.add(_memoryTool);
      if (p.category == 'MCP' && p.installed && p.enabled) {
        tools.add(_mcpProxyTool(p));
      }
    }
    return tools;
  }

  // Core tools — always available to the agent
  static const _coreTools = [
        // ── Chrome DevTools MCP-style browser tools (inbuilt WebView) ──
        {
          'type': 'function',
          'function': {
            'name': 'browser_navigate',
            'description':
                'Navigate the inbuilt browser to a URL. Returns page title + first chunk of text. Use instead of browser_open.',
            'parameters': {
              'type': 'object',
              'properties': {'url': {'type': 'string'}},
              'required': ['url'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'browser_click',
            'description':
                'Click an element on the current page. selector = CSS selector. '
                'Returns whether the click succeeded.',
            'parameters': {
              'type': 'object',
              'properties': {'selector': {'type': 'string'}},
              'required': ['selector'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'browser_evaluate',
            'description':
                'Run JavaScript on the current page and return the result. '
                'Use for reading values, extracting data, or interacting with the page.',
            'parameters': {
              'type': 'object',
              'properties': {'expression': {'type': 'string'}},
              'required': ['expression'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'browser_read',
            'description':
                'Read the current page content as clean text (title + visible text). '
                'Use after navigate/click to see what the page shows now.',
            'parameters': {'type': 'object', 'properties': {}},
          },
        },
        // ── Core agent tools ──
        {
          'type': 'function',
          'function': {
            'name': 'run_shell',
            'description':
                'Run any bash command inside the on-device Ubuntu sandbox. '
                'Full freedom: ls, cat, python, node, git, npm, curl...',
            'parameters': {
              'type': 'object',
              'properties': {
                'command': {'type': 'string'},
              },
              'required': ['command'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'browser_open',
            'description':
                'Open a URL in the Ovid browser panel. Page text is returned '
                'to you so you can read/act on it (research, docs, APIs...).',
            'parameters': {
              'type': 'object',
              'properties': {
                'url': {'type': 'string'},
              },
              'required': ['url'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'repo_sync',
            'description':
                'Sync the user\'s whole connected GitHub repo into the local '
                'workspace. Call this FIRST when a coding task starts — after '
                'it you can read/write any file offline.',
            'parameters': {'type': 'object', 'properties': {}},
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'repo_tree',
            'description':
                'List all file paths in the synced workspace (the whole repo). '
                'Use it to explore project structure.',
            'parameters': {'type': 'object', 'properties': {}},
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'file_read',
            'description': 'Read a file from the synced workspace.',
            'parameters': {
              'type': 'object',
              'properties': {
                'path': {'type': 'string'},
              },
              'required': ['path'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'file_write',
            'description':
                'Create or update a file in the local workspace. Changes show '
                'LIVE in the Studio editor immediately. NOT pushed to GitHub '
                'until commit is called.',
            'parameters': {
              'type': 'object',
              'properties': {
                'path': {'type': 'string'},
                'content': {'type': 'string'},
              },
              'required': ['path', 'content'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'commit',
            'description':
                'Commit all pending local changes and push to the connected '
                'GitHub repo (one commit, all files).',
            'parameters': {
              'type': 'object',
              'properties': {
                'message': {'type': 'string'},
              },
              'required': ['message'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'agent_install_plugin',
            'description': 'Install a plugin by name. Use when the user asks to add a plugin/tool.',
            'parameters': {
              'type': 'object',
              'properties': {'plugin_name': {'type': 'string'}},
              'required': ['plugin_name'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'agent_install_mcp',
            'description': 'Connect an MCP server by name. Use when the user asks to add an MCP.',
            'parameters': {
              'type': 'object',
              'properties': {'server_name': {'type': 'string'}},
              'required': ['server_name'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'preview',
            'description':
                'Render the web project (index.html + assets) in the live '
                'preview panel. Use after writing HTML/CSS/JS so the user can '
                'SEE the app being built (vibe coding).',
            'parameters': {'type': 'object', 'properties': {}},
          },
        },
      ];

  // ── Plugin tool definitions (added dynamically when installed) ──
  static const _webSearchTool = {
    'type': 'function',
    'function': {
      'name': 'web_search',
      'description': 'Search the web. Returns top results with titles and URLs.',
      'parameters': {
        'type': 'object',
        'properties': {'query': {'type': 'string'}},
        'required': ['query'],
      },
    },
  };

  static const _imageGenTool = {
    'type': 'function',
    'function': {
      'name': 'generate_image',
      'description': 'Generate an image from a text description.',
      'parameters': {
        'type': 'object',
        'properties': {'prompt': {'type': 'string'}},
        'required': ['prompt'],
      },
    },
  };

  static const _fileReadTool = {
    'type': 'function',
    'function': {
      'name': 'read_attachment',
      'description': 'Read a user-attached file (PDF, doc, code, CSV) and return its text content.',
      'parameters': {
        'type': 'object',
        'properties': {'filename': {'type': 'string'}},
        'required': ['filename'],
      },
    },
  };

  static const _webFetchTool = {
    'type': 'function',
    'function': {
      'name': 'fetch_url',
      'description': 'Fetch a URL and return clean markdown/text content.',
      'parameters': {
        'type': 'object',
        'properties': {'url': {'type': 'string'}},
        'required': ['url'],
      },
    },
  };

  static const _codeRunnerTool = {
    'type': 'function',
    'function': {
      'name': 'run_code',
      'description': 'Run a Python or JavaScript snippet and return output.',
      'parameters': {
        'type': 'object',
        'properties': {
          'code': {'type': 'string'},
          'lang': {'type': 'string', 'enum': ['python', 'javascript']},
        },
        'required': ['code'],
      },
    },
  };

  static const _memoryTool = {
    'type': 'function',
    'function': {
      'name': 'memory_search',
      'description': 'Search long-term memory for relevant facts, preferences, or project context.',
      'parameters': {
        'type': 'object',
        'properties': {'query': {'type': 'string'}},
        'required': ['query'],
      },
    },
  };

  // MCP proxy — generic tool for any installed MCP server
  Map<String, dynamic> _mcpProxyTool(PluginItem p) {
    final safe = p.name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return {
      'type': 'function',
      'function': {
        'name': 'mcp_$safe',
        'description': '${p.description} (${p.name} MCP)',
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {'type': 'string'},
            'args': {'type': 'object'},
          },
          'required': ['action'],
        },
      },
    };
  }

  // ── MAIN LOOP ─────────────────────────────────────────────────────────
  Future<void> runTask(String prompt) async {
    final p = _provider;
    final s = AppState.I.activeSession;
    if (p == null || s == null) return;

    final runId = DateTime.now().millisecondsSinceEpoch.toString();
    activeRunId = runId;
    events.clear();
    _emit('think', 'planning with ${p.selectedModel} · ${mode.label} mode');

    final sys = '''
You are Ovid's on-device coding & browsing agent running INSIDE a Flutter app.
Environment: Android device with an Ubuntu proot sandbox (python3/node/git/gcc),
a live Browser panel, and the user's connected GitHub repo (${GitHubService.I.login ?? 'github'}).
Access mode: ${mode.label.toUpperCase()} — ${mode.hint}
When a task needs commands, pages or file changes, CALL THE TOOLS instead of
describing them. Prefer many small steps. Always verify results before finishing.
If the user asks to install a plugin or MCP, use agent_install_plugin or agent_install_mcp.
Available plugins and MCPs appear dynamically in your tool list based on what the user has installed.
''';

    final msgs = <Map<String, dynamic>>[
      {'role': 'system', 'content': sys},
      ...s.messages.take(12).map((m) => {
            'role': m.role == 'user' ? 'user' : 'assistant',
            'content': m.content.length > 800
                ? '${m.content.substring(0, 800)}…'
                : m.content,
          }),
      {'role': 'user', 'content': prompt},
    ];

    try {
      for (var turn = 0; turn < 12; turn++) {
        _resetLiveBuffers();
        final msg = await _callLlm(p, msgs);
        if (msg == null) break;

        final toolCalls = msg['tool_calls'] as List?;
        if (toolCalls == null || toolCalls.isEmpty) {
          // FINAL answer — already streamed to the bubble live.
          _finalizeLive();
          _emit('done', 'completed');
          break;
        }

        // Tool round: freeze current bubble as reasoning, keep streaming next.
        _finalizeLive();

        msgs.add({
          'role': 'assistant',
          'content': msg['content'] ?? '',
          'tool_calls': toolCalls,
        });

        for (final tc in toolCalls) {
          final fn = tc['function'];
          final name = fn['name'];
          final args =
              jsonDecode(fn['arguments'] ?? '{}') as Map<String, dynamic>;
          final result = await _dispatch(name, args);
          msgs.add({
            'role': 'tool',
            'tool_call_id': tc['id'],
            'content': result.length > 6000
                ? '${result.substring(0, 6000)}…'
                : result,
          });
        }
      }
      _finalizeLive();
    } catch (e) {
      _emit('err', '$e');
      _appendAssistant('⚠️ Agent error: $e');
    } finally {
      activeRunId = null;
      notifyListeners();
    }
  }

  /// Clear per-run streaming buffers (new turn = fresh bubble).
  void _resetLiveBuffers() {
    _liveContent.clear();
    _liveReasoning.clear();
    _liveMsg = null;
    _liveSession = null;
  }

  Future<Map<String, dynamic>?> _callLlm(
      ProviderConfig p, List<Map<String, dynamic>> msgs) async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 20);
      final req = await client.postUrl(_endpoint(p)).timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw Exception('connect timeout'),
          );
      req.headers.set('Authorization', 'Bearer ${p.apiKey}');
      req.headers.set('Content-Type', 'application/json');
      req.headers.set('Accept', 'text/event-stream');

      // Strip effort suffix (e.g. "gpt-5.2 · High") → real model id + effort
      final raw = p.selectedModel ?? '';
      final effMatch = RegExp(r'·\s*(low|medium|high)$', caseSensitive: false)
          .firstMatch(raw);
      final modelId =
          effMatch != null ? raw.substring(0, effMatch.start).trim() : raw;
      final eff = (effMatch?.group(1) ?? 'medium').toLowerCase();

      final body = <String, dynamic>{
        'model': modelId,
        'messages': msgs,
        'stream': true,
      };
      if (_tools.isNotEmpty) body['tools'] = _tools;
      // Reasoning effort — OpenAI/o-series & DeepSeek/Qwen-compatible param.
      // Only models that support it; others ignore it server-side.
      body['reasoning_effort'] = eff;

      final bodyStr = jsonEncode(body);
      req.headers.contentLength = utf8.encode(bodyStr).length;
      req.write(bodyStr);

      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        final data = <int>[];
        await for (final c in res) {
          data.addAll(c);
          if (data.length > 65536) break; // bounded error read
        }
        final txt = utf8.decode(data, allowMalformed: true);
        _emit('err',
            'LLM ${res.statusCode}: ${txt.substring(0, txt.length.clamp(0, 300))}');
        client.close(force: true);
        return null;
      }

      // ── SSE parse: bounded buffers, resilient to malformed lines ──
      final contentBuf = StringBuffer();
      final reasoningBuf = StringBuffer();
      final tcAcc = <int, Map<String, dynamic>>{};
      int totalBytes = 0;
      String? finishReason;

      await for (final raw in res
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        totalBytes += raw.length;
        if (totalBytes > 8 * 1024 * 1024) break; // 8MB hard cap — runaway guard
        final line = raw.trim();
        if (line.isEmpty || !line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload == '[DONE]') break;

        Map<String, dynamic>? j;
        try {
          j = jsonDecode(payload) as Map<String, dynamic>;
        } catch (_) {
          continue; // malformed chunk — skip, keep stream alive
        }
        final choices = j['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final choice = choices[0] as Map<String, dynamic>;
        final delta = (choice['delta'] ?? choice['message'] ?? {})
            as Map<String, dynamic>;
        finishReason = choice['finish_reason'] as String? ?? finishReason;

        final c = delta['content'];
        if (c is String && c.isNotEmpty) {
          contentBuf.write(c);
          _streamToBubble(c);
        }
        // Reasoning tokens — DeepSeek `reasoning_content` / OpenRouter `reasoning`
        final r = delta['reasoning_content'] ?? delta['reasoning'];
        if (r is String && r.isNotEmpty) {
          reasoningBuf.write(r);
          _streamReasoning(r);
        }
        // Tool-call argument fragments — accumulate by index
        final tcs = delta['tool_calls'] as List?;
        if (tcs != null) {
          for (final t in tcs) {
            if (t is! Map) continue;
            final idx = (t['index'] as num?)?.toInt() ?? 0;
            final acc = tcAcc.putIfAbsent(idx, () {
              return {
                'id': (t['id'] as String?) ?? 'call_$idx',
                'type': 'function',
                'function': {'name': '', 'arguments': ''},
              };
            });
            if (t['id'] is String && (t['id'] as String).isNotEmpty) {
              acc['id'] = t['id'];
            }
            final fn = t['function'];
            if (fn is Map) {
              final n = fn['name'];
              if (n is String && n.isNotEmpty) acc['function']['name'] = n;
              final a = fn['arguments'];
              if (a is String) acc['function']['arguments'] += a;
            }
          }
        }
      }

      client.close();
      client = null;

      if (contentBuf.isEmpty && tcAcc.isEmpty) {
        _emit('err', 'empty response from ${modelId.isEmpty ? 'model' : modelId}');
        return null;
      }
      return {
        'role': 'assistant',
        'content': contentBuf.toString(),
        if (reasoningBuf.isNotEmpty)
          'reasoning_content': reasoningBuf.toString(),
        if (tcAcc.isNotEmpty) 'tool_calls': tcAcc.values.toList(),
        if (finishReason != null) 'finish_reason': finishReason,
      };
    } catch (e) {
      _emit('err', 'stream error: $e');
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  // ── LIVE BUBBLE streaming (DSH-web style) ─────────────────────────────
  final StringBuffer _liveContent = StringBuffer();
  final StringBuffer _liveReasoning = StringBuffer();
  ChatSession? _liveSession;
  Message? _liveMsg;

  void _ensureLiveMsg() {
    final s = AppState.I.activeSession;
    if (s == null) return;
    if (_liveSession == s && _liveMsg != null && s.messages.contains(_liveMsg)) {
      return; // reuse
    }
    _liveMsg = Message(
        role: 'assistant',
        kind: MsgKind.reasoning,
        thinking: true,
        content: '');
    s.messages.add(_liveMsg!);
    _liveSession = s;
  }

  void _streamToBubble(String tok) {
    final s = AppState.I.activeSession;
    if (s == null) return;
    _ensureLiveMsg();
    _liveContent.write(tok);
    _liveMsg!.content = _liveContent.toString();
    _liveMsg!.thinking = _liveContent.isEmpty;
    AppState.I.refresh();
  }

  void _streamReasoning(String tok) {
    final s = AppState.I.activeSession;
    if (s == null) return;
    _ensureLiveMsg();
    _liveReasoning.write(tok);
    _liveMsg!.content = _liveReasoning.toString();
    _liveMsg!.thinking = true;
    AppState.I.refresh();
  }

  /// Promote the streaming bubble to a permanent text message.
  void _finalizeLive() {
    final s = _liveSession;
    final m = _liveMsg;
    if (s == null || m == null) return;
    if (_liveContent.isNotEmpty) {
      m.kind = MsgKind.text; // kind is non-final? check Message class
      m.thinking = false;
      m.content = _liveContent.toString();
    } else if (_liveReasoning.isNotEmpty) {
      m.kind = MsgKind.reasoning;
      m.thinking = true;
      m.content = _liveReasoning.toString();
    }
    _liveSession = null;
    _liveMsg = null;
    AppState.I.refresh();
    AppState.I.persistSessions();
  }

  // ── TOOL DISPATCH (with mode-based approvals) ─────────────────────────
  Future<String> _dispatch(String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'run_shell':
        final cmd = args['command'] as String;
        final ok = await _maybeApprove(
            'run_shell', cmd, 'Command sandbox me chlega:\n\$ $cmd');
        if (!ok) return 'DENIED by user';
        _emit('shell', cmd);
        try {
          final out = await SandboxService.I
              .exec(['bash', '-lc', cmd])
              .timeout(const Duration(seconds: 60));
          for (final l in const LineSplitter().convert(out.trim())) {
            _emit('shellOut', l);
          }
          return out.isEmpty ? '(no output)' : out;
        } catch (e) {
          return 'sandbox error: $e';
        }

      case 'browser_open':
        final url = args['url'] as String;
        final ok = await _maybeApprove('browser_open', url,
            'Browser panel me ye page khulega:\n$url');
        if (!ok) return 'DENIED by user';
        _emit('nav', url);
        try {
          // Drive the live WebView if the Browser screen is open.
          if (_webView != null) {
            _webView!.loadRequest(Uri.parse(url));
            browserUrl = url;
            notifyListeners();
            _emit('page', 'loading $url');
            // Give the webview time to load before reading text.
            await Future.delayed(const Duration(seconds: 2));
          }
          final r = await HttpShim.get(Uri.parse(url),
              headers: {'User-Agent': 'OvidAgent/1.0'});
          var body = utf8.decode(r.bytes, allowMalformed: true);
          body = body
              .replaceAll(RegExp(r'<script[\s\S]*?</script>', multiLine: true), '')
              .replaceAll(RegExp(r'<style[\s\S]*?</style>', multiLine: true), '')
              .replaceAll(RegExp(r'<[^>]+>'), ' ')
              .replaceAll(RegExp(r'\s{2,}'), '\n')
              .trim();
          browserUrl = url;
          browserPageText =
              body.length > 5000 ? body.substring(0, 5000) : body;
          notifyListeners();
          _emit('page', '${r.status} · ${body.length} chars');
          return browserPageText!;
        } catch (e) {
          return 'fetch failed: $e';
        }

      // ─── Chrome DevTools MCP tools (inbuilt WebView) ─────────────────
      case 'browser_navigate':
        final url = args['url'] as String;
        final ok = await _maybeApprove('browser_navigate', url,
            'Browser me ye page khulega:\n$url');
        if (!ok) return 'DENIED by user';
        if (_webView == null) return 'Browser screen not open. Open the Browser panel first.';
        _webView!.loadRequest(Uri.parse(url));
        browserUrl = url;
        _emit('nav', url);
        await Future.delayed(const Duration(seconds: 2));
        final title = await _webView!.getTitle();
        return 'Navigated to $url\nTitle: ${title ?? "unknown"}';

      // ─── Plugin tools (dynamic, installed plugins) ────────────────────
      case 'web_search':
        final q = args['query'] as String;
        _emit('nav', 'searching: $q');
        return 'Web search results for "$q" would appear here. Install a search MCP for real results.';
      case 'generate_image':
        final prompt = args['prompt'] as String;
        _emit('shell', 'image gen: $prompt');
        return 'Image generation for "$prompt" — use the Image Studio plugin UI for visual output.';
      case 'read_attachment':
        final fname = args['filename'] as String;
        _emit('shell', 'reading: $fname');
        return 'Attached file "$fname" would be read here.';
      case 'fetch_url':
        final u = args['url'] as String;
        _emit('nav', 'fetching: $u');
        try {
          final r = await HttpShim.get(Uri.parse(u),
              headers: {'User-Agent': 'OvidAgent/1.0'});
          var body = utf8.decode(r.bytes, allowMalformed: true);
          body = body
              .replaceAll(RegExp(r'<script[\s\S]*?</script>', multiLine: true), '')
              .replaceAll(RegExp(r'<style[\s\S]*?</style>', multiLine: true), '')
              .replaceAll(RegExp(r'<[^>]+>'), ' ')
              .replaceAll(RegExp(r'\s{2,}'), '\n')
              .trim();
          return body.length > 5000 ? '${body.substring(0, 5000)}…' : body;
        } catch (e) {
          return 'fetch failed: $e';
        }
      case 'run_code':
        final code = args['code'] as String;
        final lang = args['lang'] as String? ?? 'python';
        final ok2 = await _maybeApprove('run_code', code,
            'Code will run in sandbox:\n$lang\n$code');
        if (!ok2) return 'DENIED by user';
        _emit('shell', 'run_code ($lang)');
        try {
          final out = await SandboxService.I
              .exec([lang == 'python' ? 'python3' : 'node', '-e', code])
              .timeout(const Duration(seconds: 60));
          _emit('shellOut', out);
          return out;
        } catch (e) {
          return 'exec error: $e';
        }
      case 'memory_search':
        final q2 = args['query'] as String;
        _emit('think', 'searching memory: $q2');
        return 'Memory search for "$q2" — no entries found. Long-term memory builds as you chat.';
      case String() when name.startsWith('mcp_'):
        // Generic MCP proxy — forward to the MCP server
        final mcpName = name.substring(4).replaceAll('_', ' ');
        final action = args['action'] as String? ?? 'execute';
        final mcpArgs = args['args'] as Map<String, dynamic>? ?? {};
        _emit('shell', 'MCP: $mcpName → $action');
        return 'MCP call to $mcpName: $action. Install the actual MCP server for real functionality.';
      case 'agent_install_plugin':
        final pluginName = args['plugin_name'] as String;
        _emit('think', 'installing plugin: $pluginName');
        try {
          final app = AppState.I;
          final match = app.plugins
              .where((p) => p.name.toLowerCase() == pluginName.toLowerCase())
              .firstOrNull;
          if (match == null) return 'Plugin not found: $pluginName';
          match.installed = true;
          match.enabled = true;
          app.refresh();
          _emit('done', 'installed $pluginName');
          return 'Plugin "$pluginName" installed and enabled ✓';
        } catch (e) {
          return 'install failed: $e';
        }
      case 'agent_install_mcp':
        final mcpName2 = args['server_name'] as String;
        _emit('think', 'installing MCP: $mcpName2');
        try {
          final app = AppState.I;
          final match = app.mcpServers
              .where((s) => s.name.toLowerCase() == mcpName2.toLowerCase())
              .firstOrNull;
          if (match == null) return 'MCP server not found: $mcpName2';
          match.connected = true;
          app.refresh();
          _emit('done', 'connected $mcpName2');
          return 'MCP server "$mcpName2" connected ✓';
        } catch (e) {
          return 'MCP connect failed: $e';
        }
      case 'browser_click':
        final sel = args['selector'] as String;
        if (_webView == null) return 'Browser screen not open.';
        final js = 'document.querySelector(${jsonEncode(sel)})?.click()';
        await _webView!.runJavaScript(js);
        _emit('shell', 'click: $sel');
        return 'Clicked $sel (or attempted)';
      case 'browser_evaluate':
        final expr = args['expression'] as String;
        if (_webView == null) return 'Browser screen not open.';
        try {
          final result = await _webView!.runJavaScriptReturningResult(expr);
          final text = result.toString();
          _emit('shellOut', 'eval: $expr');
          return text.length > 4000 ? '${text.substring(0, 4000)}…' : text;
        } catch (e) {
          return 'JS error: $e';
        }
      case 'browser_read':
        if (_webView == null) {
          return 'Browser screen not open. Call browser_navigate first.';
        }
        try {
          final title = await _webView!.getTitle();
          final result = await _webView!.runJavaScriptReturningResult(
              'document.body.innerText.substring(0,5000)');
          final raw = result.toString();
          // runJavaScriptReturningResult returns JSON-quoted string — decode it.
          final text = raw.startsWith('"') && raw.endsWith('"')
              ? jsonDecode(raw) as String
              : raw;
          _emit('page', title ?? 'page read');
          return 'Title: ${title ?? "unknown"}\n\n$text';
        } catch (e) {
          return 'read failed: $e';
        }

      // ─── DSH-grade repo tools ─────────────────────────────────────────

      case 'repo_sync':
        if (repoFull == null) return 'no repo connected';
        _emit('think', 'syncing repo $repoFull …');
        try {
          // bind cache
          RepoCache.I.bind(repoFull!, GitHubService.I.token!);
          await RepoCache.I.sync(onLine: (l) => _emit('shellOut', l));
          notifyListeners();
          return 'repo synced · ${RepoCache.I.files.length} files ready in '
              'workspace. call repo_tree to explore.';
        } catch (e) {
          return 'sync failed: $e';
        }

      case 'repo_tree':
        final paths = RepoCache.I.treePaths;
        if (paths.isEmpty) {
          return 'workspace empty. call repo_sync first.';
        }
        final tree = paths.take(120).join('\n');
        _emit('file', 'tree · ${paths.length} paths');
        return 'TREE (${paths.length} files, showing 120):\n$tree';

      case 'file_read':
        final path = args['path'] as String;
        final c = RepoCache.I.read(path);
        if (c == null) return 'file not found: $path';
        fileBuffer[path] = c;
        activeFilePath = path;
        notifyListeners();
        _emit('file', 'read $path');
        return c.length > 6000 ? '${c.substring(0, 6000)}…' : c;

      case 'file_write':
        final path = args['path'] as String;
        final content = args['content'] as String;
        final ok = await _maybeApprove(
            'file_write', path, 'LOCAL EDIT (no push yet):\n$path\n${content.length} chars');
        if (!ok) return 'DENIED by user';
        RepoCache.I.write(path, content);
        fileBuffer[path] = content;
        activeFilePath = path;
        notifyListeners();
        _emit('file', 'edited $path');
        return 'written locally ✓ · $path · ${content.length} chars\n'
            'call commit() to push, or preview() to see web build.';

      case 'commit':
        final message = (args['message'] ?? 'Ovid agent update') as String;
        if (!RepoCache.I.hasPending) return 'no pending changes';
        final ok = await _maybeApprove(
            'commit', message, 'PUSH TO GITHUB\n"${RepoCache.I.repoFull}"\n'
                '${RepoCache.I.dirtyCount} files · "$message"');
        if (!ok) return 'DENIED by user';
        _emit('file', 'committing ${RepoCache.I.dirtyCount} files…');
        try {
          final n = await RepoCache.I.commitAll(message);
          _emit('file', 'pushed ✓ $n files');
          notifyListeners();
          return 'committed $n files ✓';
        } catch (e) {
          return 'commit failed: $e';
        }

      case 'preview':
        _emit('think', 'rendering preview…');
        try {
          final path = await RepoCache.I.exportPreview('');
          if (path == null) return 'no index.html found in workspace';
          previewFile = path;
          notifyListeners();
          _emit('page', 'preview ready');
          return 'preview rendered in Browser panel ✓';
        } catch (e) {
          return 'preview failed: $e';
        }

      // legacy single-file tools kept for compat
      case 'repo_read':
        return await _dispatch('file_read', args);
      case 'repo_write':
        return await _dispatch('file_write', args);
    }
    return 'unknown tool';
  }

  // ── APPROVALS (safe / auto mode) ──────────────────────────────────────
  Future<bool> _maybeApprove(
      String tool, String summary, String detail) async {
    switch (mode) {
      case AgentMode.drive:
        return true;
      case AgentMode.auto:
        return tool != 'commit'
            ? true
            : await _askUser(tool, summary, detail);
      case AgentMode.safe:
        return await _askUser(tool, summary, detail);
    }
  }

  Future<bool> _askUser(String t, String s, String d) async {
    final req = ApprovalRequest(tool: t, summary: s, detail: d);
    pendingApproval = req;
    notifyListeners();
    return req.completer.future;
  }

  void _appendAssistant(String text, {MsgKind kind = MsgKind.text}) {
    final s = AppState.I.activeSession;
    if (s == null || text.trim().isEmpty) return;
    s.messages.add(Message(role: 'assistant', kind: kind, content: text));
    AppState.I.refresh();
  }
}

class HttpShim {
  static Future<({int status, String bodyText, List<int> bytes})> post(
      Uri u,
      {Map<String, String>? headers,
      Object? body}) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(u);
      headers?.forEach((k, v) => req.headers.set(k, v));
      req.headers.contentLength = utf8.encode(body as String).length;
      req.write(body);
      final res = await req.close();
      final data = <int>[];
      await for (final c in res) {
        data.addAll(c);
      }
      return (
        status: res.statusCode,
        bodyText: utf8.decode(data, allowMalformed: true),
        bytes: data,
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<({int status, String bodyText, List<int> bytes})> get(
      Uri u,
      {Map<String, String>? headers}) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(u);
      headers?.forEach((k, v) => req.headers.set(k, v));
      final res = await req.close();
      final data = <int>[];
      await for (final c in res) {
        data.addAll(c);
      }
      return (
        status: res.statusCode,
        bodyText: utf8.decode(data, allowMalformed: true),
        bytes: data,
      );
    } finally {
      client.close(force: true);
    }
  }
}
