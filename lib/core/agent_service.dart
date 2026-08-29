import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons, Color;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import '../core/theme.dart';
import 'state.dart';
import 'sandbox_service.dart';
import 'github_service.dart';
import 'repo_cache.dart';
import 'mcp_service.dart';

/// A persistent browser tab — owns its WebView controller lazily so the
/// page state survives across BrowserScreen open/close cycles.
class BrowserTab {
  String url;
  String? title;
  bool loading = false;
  int progress = 0;
  WebViewController? controller;
  bool loadedOnce = false;

  BrowserTab({required this.url});
}

/// ═══════════════════════════════════════════════════════════════════
/// AGENT ACCESS MODES (DSH-web style)
/// ───────────────────────────────────────────────────────────────────
/// READ-ONLY → har action pe user se poochhe (shell/write/commit sab)
/// GENERAL   → shell + browser free; file writes & commits poochhe
/// FULL      → sab kuch free, no confirmation (DSH/Codex full-send)
/// STUDIO    → general + full Studio access: files edit, terminal, repo
///             sync free; sirf publish/commit confirm karta hai
/// ═══════════════════════════════════════════════════════════════════
enum AgentMode { safe, auto, drive, studio }

extension AgentModeX on AgentMode {
  String get label => switch (this) {
    AgentMode.safe => 'Read-Only',
    AgentMode.auto => 'General',
    AgentMode.drive => 'Full Access',
    AgentMode.studio => 'Studio',
  };
  String get hint => switch (this) {
    AgentMode.safe =>
      'Read-only. Har shell / browser / write se pehle permission maangega.',
    AgentMode.auto =>
      'Shell aur browser khud chalayega. Repo me push se pehle poochega.',
    AgentMode.drive =>
      'Full autonomous — kuch bhi, kahin bhi, no confirmation.',
    AgentMode.studio =>
      'Studio mode — files edit, terminal run, repo access free. '
      'Publish/commit se pehle confirm karega.',
  };
  IconData get icon => switch (this) {
    AgentMode.safe => Icons.visibility_outlined,
    AgentMode.auto => Icons.tune_outlined,
    AgentMode.drive => Icons.rocket_launch_outlined,
    AgentMode.studio => Icons.code_rounded,
  };
  Color get color => switch (this) {
    AgentMode.safe => Aether.success,
    AgentMode.auto => Aether.accent,
    AgentMode.drive => Aether.warn,
    AgentMode.studio => const Color(0xFF9B7EDE),
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

/// Strips raw special characters that models emit inside reasoning traces:
/// `<think>`/`</think>` wrapper tags, unrendered markdown markers that would
/// otherwise show as literal glyphs (`**`, `##`, leading bullets), and
/// dangling ellipsizers. The UI renders reasoning as markdown anyway, so we
/// only remove the tags markdown cannot handle and normalize whitespace.
String cleanReasoningText(String raw) {
  var t = raw;
  // <think>…</think> wrappers (DeepSeek/Qwen raw traces)
  t = t.replaceAll('<think>', '').replaceAll('</think>', '');
  // Absolutely-positioned no-width marks that leak from some providers.
  t = t.replaceAll('\u{200B}', '').replaceAll('\u{FEFF}', '');
  // Collapse 3+ blank lines into one.
  t = t.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return t.trim();
}

/// Boundary-aware truncation that never strands a half-cut character or a
/// dangling ellipsis inside a word. Returns text no longer than [max].
String cleanTruncate(String text, int max) {
  if (text.length <= max) return text;
  final cut = text.substring(0, max);
  // Avoid cutting inside a surrogate pair.
  final safe = cut.codeUnits.last >= 0xD800 && cut.codeUnits.last <= 0xDBFF
      ? cut.substring(0, cut.length - 1)
      : cut;
  return '$safe…';
}

class ApprovalRequest {
  final String tool;
  final String summary;
  final String detail;
  final Completer<bool> completer = Completer<bool>();
  ApprovalRequest({
    required this.tool,
    required this.summary,
    required this.detail,
  });
}

/// Per-session Studio state — open tabs, editor buffers, active path.
/// Keyed by ChatSession.sandboxId inside AgentService so each chat session
/// has its own Studio view (DSH-style workspace isolation).
class _SessionStudio {
  final Map<String, String> fileBuffer = {};
  final List<String> openFiles = [];
  String? activeFilePath;
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

  // ── CANCELLATION (DSH-web stop button) ────────────────────────────────
  HttpClientRequest? _activeRequest;
  bool _cancelRequested = false;
  bool get cancelRequested => _cancelRequested;

  // ── MESSAGE QUEUE (DSH-web QueueDock) ─────────────────────────────────
  // When the user submits while a run is active, the message is enqueued
  // and auto-started after the current run finishes (FIFO).
  final List<String> _queue = [];
  List<String> get queuedMessages => List.unmodifiable(_queue);

  /// Stop the current run: aborts the in-flight HTTP request and flags
  /// every loop turn to exit at the next checkpoint. DSH-web "Stop" UX.
  void cancelRun() {
    if (activeRunId == null) return;
    _cancelRequested = true;
    try {
      _activeRequest?.abort();
    } catch (_) {}
    _emit('think', 'stop requested — finishing current turn');
    notifyListeners();
  }

  /// Enqueue a message to run after the current turn completes.
  void enqueueMessage(String text) {
    if (text.trim().isEmpty) return;
    _queue.add(text);
    _emit('think', 'queued message ${_queue.length}');
    notifyListeners();
  }

  /// Edit a queued message in place.
  void editQueuedMessage(int index, String newText) {
    if (index < 0 || index >= _queue.length) return;
    if (newText.trim().isEmpty) return;
    _queue[index] = newText;
    notifyListeners();
  }

  /// Remove a message from the queue.
  void removeQueuedMessage(int index) {
    if (index < 0 || index >= _queue.length) return;
    _queue.removeAt(index);
    notifyListeners();
  }

  /// Test-only helper to reset the queue between tests.
  @visibleForTesting
  void clearQueueForTest() {
    _queue.clear();
    _cancelRequested = false;
    activeRunId = null;
    notifyListeners();
  }

  /// Browser live state
  String? browserUrl;
  String? browserPageText;
  String? previewFile; // local path to index.html for WebView

  // ── PERSISTENT BROWSER (singleton tabs owned by the agent service) ────
  // The WebView controllers live here — OUTLIVES any BrowserScreen route.
  // The browser is pre-warmed once on first launch and never reloads when
  // the user re-opens the panel (state survives), DSH-web style.
  final List<BrowserTab> browserTabs = [];
  int activeTabIndex = 0;
  bool browserBusy = false; // true while an agent browser tool is running
  static const _kBrowserTabs = 'ovid_browser_tabs';
  static const _kBrowserActiveTab = 'ovid_browser_active_tab';
  static const _defaultBrowserUrl = 'https://www.google.com';

  /// True once the browser has ever been opened/pre-warmed in this launch.
  bool get browserReady => browserTabs.isNotEmpty;

  BrowserTab get _activeTab {
    if (browserTabs.isEmpty) _newTabInternal(_defaultBrowserUrl);
    if (activeTabIndex >= browserTabs.length) activeTabIndex = 0;
    return browserTabs[activeTabIndex];
  }

  BrowserTab _newTabInternal(String url) {
    final tab = BrowserTab(url: url);
    browserTabs.add(tab);
    activeTabIndex = browserTabs.length - 1;
    return tab;
  }

  /// Pre-warm the browser once at app launch so it's instantly ready.
  /// Called from main() — safe to call repeatedly (no-op after first).
  Future<void> prewarmBrowser() async {
    if (browserTabs.isNotEmpty) return;
    try {
      // Restore last-session tabs if available.
      final restored = await _restoreBrowserTabs();
      if (restored) return;
      _newTabInternal(_defaultBrowserUrl);
    } catch (_) {
      if (browserTabs.isEmpty) _newTabInternal(_defaultBrowserUrl);
    }
  }

  Future<bool> _restoreBrowserTabs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final urls = prefs.getStringList(_kBrowserTabs);
      if (urls == null || urls.isEmpty) return false;
      for (final u in urls) {
        browserTabs.add(BrowserTab(url: u));
      }
      activeTabIndex = prefs.getInt(_kBrowserActiveTab) ?? 0;
      if (activeTabIndex >= browserTabs.length) activeTabIndex = 0;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _persistBrowserTabs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _kBrowserTabs,
        browserTabs.map((t) => t.url).toList(),
      );
      await prefs.setInt(_kBrowserActiveTab, activeTabIndex);
    } catch (_) {}
  }

  /// User-facing: open a new tab.
  void newBrowserTab([String url = _defaultBrowserUrl]) {
    _newTabInternal(url);
    _persistBrowserTabs();
    notifyListeners();
  }

  /// User-facing: close tab at index. Keeps at least one tab alive.
  void closeBrowserTab(int index) {
    if (index < 0 || index >= browserTabs.length) return;
    browserTabs.removeAt(index);
    if (browserTabs.isEmpty) {
      _newTabInternal(_defaultBrowserUrl);
    } else if (activeTabIndex >= browserTabs.length) {
      activeTabIndex = browserTabs.length - 1;
    }
    _persistBrowserTabs();
    notifyListeners();
  }

  /// User/agent-facing: switch the active tab (agent tools target this).
  void selectBrowserTab(int index) {
    if (index < 0 || index >= browserTabs.length) return;
    activeTabIndex = index;
    _persistBrowserTabs();
    notifyListeners();
  }

  /// Agent-facing: get (creating if needed) the controller for a tab.
  WebViewController controllerForTab(BrowserTab tab) {
    tab.controller ??= WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            tab.url = url;
            tab.loading = true;
            tab.progress = 0;
            notifyListeners();
          },
          onProgress: (p) {
            tab.progress = p;
            notifyListeners();
          },
          onPageFinished: (url) {
            tab
              ..url = url
              ..loading = false;
            browserUrl = url;
            notifyListeners();
            _persistBrowserTabs();
          },
          onWebResourceError: (_) {
            tab.loading = false;
          },
        ),
      );
    if (!tab.loadedOnce) {
      tab.loadedOnce = true;
      tab.controller!.loadRequest(Uri.parse(tab.url));
    }
    return tab.controller!;
  }

  /// Back-compat for existing agent tools (browser_open etc.).
  void bindWebView(WebViewController controller) {
    // No-op: controllers are now owned by AgentService tabs directly.
  }

  void unbindWebView(WebViewController controller) {
    // No-op: see bindWebView.
  }

  // ── PER-SESSION STUDIO STATE ──────────────────────────────────────────
  // Each chat session owns its own Studio buffers (open-file tabs, editor
  // content, active path). Session A's files never leak into session B —
  // the AI's view is scoped to the active session's workspace. The old
  // global `fileBuffer`/`studioOpenFiles`/`activeFilePath` were the source
  // of the "same input in new session" bug.

  /// Studio state bucket keyed by session.sandboxId (== session.id).
  final Map<String, _SessionStudio> _studios = {};

  _SessionStudio _studioFor(String key) =>
      _studios.putIfAbsent(key, _SessionStudio.new);

  /// Current session's studio (falls back to a throwaway bucket when no
  /// session is active yet — e.g. before persistence loads).
  _SessionStudio get _studio {
    final sid = AppState.I.activeSession?.sandboxId ??
        AppState.I.activeSession?.id ??
        '__none__';
    return _studioFor(sid);
  }

  /// Studio live buffers (path → content) — scoped to the ACTIVE session.
  Map<String, String> get fileBuffer => _studio.fileBuffer;
  String? get activeFilePath => _studio.activeFilePath;
  set activeFilePath(String? v) => _studio.activeFilePath = v;
  String? repoFull; // e.g. "aasheesh333/Ovid"

  /// Open-file tab list — scoped to the ACTIVE session.
  List<String> get studioOpenFiles => _studio.openFiles;

  void openStudioFile(String path, String content) {
    final st = _studio;
    st.fileBuffer[path] = content;
    if (!st.openFiles.contains(path)) st.openFiles.add(path);
    st.activeFilePath = path;
    notifyListeners();
  }

  void newStudioFile(String path) {
    openStudioFile(path, '');
    // If the repo is synced, mark it created so commit() picks it up.
    RepoCache.I.create(path, '');
    notifyListeners();
  }

  void closeStudioFile(String path) {
    final st = _studio;
    st.openFiles.remove(path);
    if (st.activeFilePath == path) {
      st.activeFilePath = st.openFiles.isEmpty ? null : st.openFiles.last;
    }
    notifyListeners();
  }

  void selectStudioFile(String path) {
    if (!_studio.openFiles.contains(path)) return;
    _studio.activeFilePath = path;
    notifyListeners();
  }

  /// Per-session sandbox workspace (host dir). AI shell/code commands run
  /// with this as `cwd` bound to /work inside the jail.
  Future<Directory> _sessionWorkDir() async {
    final s = AppState.I.activeSession;
    final sid = s?.sandboxId ?? s?.id ?? 'default';
    return SandboxService.I.workDirFor(sid);
  }

  /// Elapsed milliseconds of the last completed/failed run — shown on the
  /// final assistant bubble (DSH "2.1s" metadata).
  int? lastRunElapsedMs;

  DateTime? _runStart;

  /// Surface of the last model-layer failure (HTTP status, network error,
  /// timeout) so the UI can show the REAL error instead of a dummy string.
  String? lastError;

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
    final app = AppState.I;
    final session = app.activeSession;
    final provider = app.providerForSession(session);
    if (session == null || provider == null || !provider.isConfigured) {
      return null;
    }
    if (session.model.isEmpty || session.model == 'Select a provider') {
      return null;
    }
    provider.selectedModel = session.model;
    return provider;
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
        'name': 'browser_click',
        'description':
            'Click an element on the current page. selector = CSS selector. '
            'Returns whether the click succeeded.',
        'parameters': {
          'type': 'object',
          'properties': {
            'selector': {'type': 'string'},
          },
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
          'properties': {
            'expression': {'type': 'string'},
          },
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
    // ── Tab management (user sees the strip in the Browser screen) ──
    {
      'type': 'function',
      'function': {
        'name': 'browser_new_tab',
        'description':
            'Open a NEW browser tab with a URL and make it active. '
            'The user sees the tab in the Browser screen strip.',
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
        'name': 'browser_switch_tab',
        'description':
            'Switch the active browser tab by 0-based index '
            '(use browser_list_tabs to see them).',
        'parameters': {
          'type': 'object',
          'properties': {'index': {'type': 'integer'}},
          'required': ['index'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'browser_list_tabs',
        'description': 'List all open browser tabs with index, url, title.',
        'parameters': {'type': 'object', 'properties': {}},
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'browser_close_tab',
        'description': 'Close a browser tab by 0-based index.',
        'parameters': {
          'type': 'object',
          'properties': {'index': {'type': 'integer'}},
          'required': ['index'],
        },
      },
    },
    // ── Core agent tools ──
    {
      'type': 'function',
      'function': {
        'name': 'run_shell',
        'description':
            'Run a shell command. TWO execution tiers depending on the '
            'user\'s access mode:\n'
            '• Studio mode → full Ubuntu sandbox (bash, python, node, git, '
            'npm, gcc — commands run in the session workspace /work).\n'
            '• Other modes → phone terminal (Android device shell: ls, cat, '
            'grep, cp, mv, ps, uname, toybox utilities — instant, no '
            'install).\n'
            'If a phone-terminal command reports "not found", tell the user '
            'to switch to Studio mode and install the Ubuntu sandbox for '
            'full tooling. Commands always run in the CURRENT SESSION '
            'workspace — you cannot see other sessions\' files.',
        'parameters': {
          'type': 'object',
          'properties': {
            'command': {'type': 'string'},
          },
          'required': ['command'],
        },
      },
    },
    // Device permission trigger (user consent gate). The agent calls this
    // whenever it needs a device-level capability (notifications, camera,
    // storage, contacts, calendar, sms, phone, bluetooth, sensors, ...).
    // In safe mode the user is asked even for read-only ops; in other modes
    // the user is ALWAYS asked for device perms.
    {
      'type': 'function',
      'function': {
        'name': 'request_permission',
        'description':
            'Ask the user for a device permission BEFORE using a '
            'device-backed capability. ALWAYS call this first when a task '
            'needs any device access: notifications, camera, microphone, '
            'media files (photos/videos/audio), storage, contacts, calendar, '
            'location, phone/calls, SMS, bluetooth, activity recognition, '
            'or body sensors. Returns granted/denied. If denied, tell the '
            'user what the permission was for and let them decide.',
        'parameters': {
          'type': 'object',
          'properties': {
            'permission': {
              'type': 'string',
              'enum': [
                'notifications',
                'camera',
                'microphone',
                'storage',
                'photos',
                'videos',
                'audio',
                'contacts',
                'calendar',
                'location',
                'phone',
                'sms',
                'bluetooth',
                'activity_recognition',
                'sensors',
              ],
            },
            'reason': {'type': 'string'},
          },
          'required': ['permission', 'reason'],
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
        'description':
            'Install a plugin by name. Use when the user asks to add a plugin/tool.',
        'parameters': {
          'type': 'object',
          'properties': {
            'plugin_name': {'type': 'string'},
          },
          'required': ['plugin_name'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'agent_install_mcp',
        'description':
            'Connect an MCP server by name. Use when the user asks to add an MCP.',
        'parameters': {
          'type': 'object',
          'properties': {
            'server_name': {'type': 'string'},
          },
          'required': ['server_name'],
        },
      },
    },

    // ── DSH-harness catalog management (providers/plugins/MCP/marketplace) ──
    {
      'type': 'function',
      'function': {
        'name': 'catalog_list_providers',
        'description':
            'List all configured AI providers with their status (key present, '
            'model count). Use when the user asks about providers.',
        'parameters': {'type': 'object', 'properties': {}},
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'catalog_add_provider',
        'description':
            'Add a custom OpenAI-compatible provider. Use when the user asks '
            'to add/set up a new provider (e.g. "add OpenRouter", "use a '
            'custom API endpoint"). The api_key comes from the user message.',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'base_url': {
              'type': 'string',
              'description': 'OpenAI-compatible base URL, e.g. https://api.example.com/v1',
            },
            'api_key': {
              'type': 'string',
              'description': 'API key from the user (optional for local servers)',
            },
            'models': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Initial model IDs to register',
            },
          },
          'required': ['name', 'base_url'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'catalog_remove_provider',
        'description':
            'Remove a custom provider by id. Use when the user asks to delete '
            'a provider they added.',
        'parameters': {
          'type': 'object',
          'properties': {
            'provider_id': {'type': 'string'},
          },
          'required': ['provider_id'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'catalog_list_plugins',
        'description': 'List all plugins with install/enable status.',
        'parameters': {'type': 'object', 'properties': {}},
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'catalog_list_mcp',
        'description': 'List all MCP servers with connection status.',
        'parameters': {'type': 'object', 'properties': {}},
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'catalog_add_mcp',
        'description':
            'Add a custom MCP server (command + args). Use when the user asks '
            'to add an MCP server not in the catalog.',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'command': {
              'type': 'string',
              'description': 'e.g. npx, uvx, python3',
            },
            'args': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'e.g. ["-y", "@modelcontextprotocol/server-github"]',
            },
          },
          'required': ['name', 'command'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'catalog_remove_mcp',
        'description':
            'Remove a custom MCP server by name (built-in servers can only '
            'be disconnected).',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
          },
          'required': ['name'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'catalog_add_marketplace',
        'description':
            'Import a plugin marketplace from a GitHub repo (owner/repo with '
            'a marketplace.json). Use when the user asks to import plugins '
            'from a GitHub repository.',
        'parameters': {
          'type': 'object',
          'properties': {
            'repo': {
              'type': 'string',
              'description': 'owner/repo, e.g. ovidai/ovid-plugins',
            },
          },
          'required': ['repo'],
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
      'description':
          'Search the web. Returns top results with titles and URLs.',
      'parameters': {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
        },
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
        'properties': {
          'prompt': {'type': 'string'},
        },
        'required': ['prompt'],
      },
    },
  };

  static const _fileReadTool = {
    'type': 'function',
    'function': {
      'name': 'read_attachment',
      'description':
          'Read a user-attached file (PDF, doc, code, CSV) and return its text content.',
      'parameters': {
        'type': 'object',
        'properties': {
          'filename': {'type': 'string'},
        },
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
        'properties': {
          'url': {'type': 'string'},
        },
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
          'lang': {
            'type': 'string',
            'enum': ['python', 'javascript'],
          },
        },
        'required': ['code'],
      },
    },
  };

  static const _memoryTool = {
    'type': 'function',
    'function': {
      'name': 'memory_search',
      'description':
          'Search long-term memory for relevant facts, preferences, or project context.',
      'parameters': {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
        },
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

  /// DSH/opencode queue behavior: messages queued while a run is active
  /// join the NEXT LLM request of the CURRENT run — not a separate run
  /// after full completion. Drains the queue into [msgs] as user turns
  /// and records them in the session so the chat bubble shows immediately.
  void _drainQueueIntoMsgs(List<Map<String, dynamic>> msgs) {
    if (_queue.isEmpty) return;
    while (_queue.isNotEmpty) {
      final queued = _queue.removeAt(0);
      AppState.I.sendMessage(queued);
      msgs.add({'role': 'user', 'content': queued});
    }
    _emit('think', 'queued message joined this run');
  }

  Future<void> runTask(String prompt) async {
    final p = _provider;
    final s = AppState.I.activeSession;
    if (s == null) {
      _emit('err', 'No active chat session');
      return;
    }
    if (p == null) {
      final selected = AppState.I.providerForSession(s);
      final error = selected == null
          ? 'Select a provider and model before sending a message.'
          : selected.requiresApiKey && !selected.hasKey
          ? 'Add an API key for ${selected.name} before sending a message.'
          : 'The selected provider is not configured correctly.';
      _emit('err', error);
      _appendAssistant('Provider setup required: $error');
      return;
    }

    final runId = DateTime.now().millisecondsSinceEpoch.toString();
    activeRunId = runId;
    _runStart = DateTime.now();
    lastError = null;
    events.clear();
    _emit('think', 'planning with ${p.selectedModel} · ${mode.label} mode');

    final sys =
        '''
You are Ovid's on-device coding & browsing agent running INSIDE a Flutter app.
Environment: Android device with an Ubuntu proot sandbox (python3/node/git/gcc),
a live Browser panel, and the user's connected GitHub repo (${GitHubService.I.login ?? 'github'}).
Access mode: ${mode.label.toUpperCase()} — ${mode.hint}
Session isolation: this chat has its OWN sandbox workspace (id: ${AppState.I.activeSession?.sandboxId ?? 'default'}).
Other chats' files are NOT visible to you — don't ask about them, they're
inaccessible here. ${AppState.I.shareSessionMemory ? 'The user enabled "Share session memory" — you may search across all chats via memory_search.' : ''}

RESPONSE STYLE (default): Be concise and lightweight, like a fast coding assistant.
Lead with the answer or result. Skip long preambles, restating the question, and
filler. Use short bullet points or code blocks only when they help. Match the
user's language (Hindi/English). Only give long explanations, step-by-step
reasoning, or extra detail when the user explicitly asks for it or the task truly
requires it. When a task needs commands, pages or file changes, CALL THE TOOLS
instead of describing them. Prefer many small steps. Verify results before finishing.
If the user asks to install a plugin or MCP, use agent_install_plugin or agent_install_mcp.
Catalog management: you can list/add/remove providers (catalog_list_providers,
catalog_add_provider, catalog_remove_provider), list plugins/MCP servers
(catalog_list_plugins, catalog_list_mcp), add/remove MCP servers
(catalog_add_mcp, catalog_remove_mcp), and import plugin marketplaces from
GitHub repos (catalog_add_marketplace). When the user asks to change provider
settings, add a provider with their key, or manage plugins/MCP — use these
tools to do it live, don't just explain how.
Device permissions: if a task needs any device capability (notifications,
camera, microphone, media/photos/videos/audio, storage, contacts, calendar,
location, phone/calls, SMS, bluetooth, activity, sensors) — call
request_permission FIRST with a clear reason. The user approves in-chat,
then the system dialog appears. Never claim a permission was granted
without calling the tool. If denied, tell the user and offer alternatives.
Execution tiers: run_shell adapts to the user's access mode.
• Studio mode → full Ubuntu sandbox (bash/python/node/git/npm/gcc) in the
  session workspace /work.
• Any other mode → instant phone terminal (Android device shell + toybox:
  ls/cat/grep/cp/mv/ps/uname...). No python/gcc/apt here — if a command
  is "not found", suggest switching to Studio mode + one-time Ubuntu
  sandbox install (~320 MB). Provider/plugin/MCP management works the
  same in every tier via the catalog_* tools.
''';

    final historyStart = s.messages.length > 12 ? s.messages.length - 12 : 0;
    final msgs = <Map<String, dynamic>>[
      {'role': 'system', 'content': sys},
      ...s.messages
          .skip(historyStart)
          .map(
            (m) => {
              'role': m.role == 'user' ? 'user' : 'assistant',
              'content': cleanTruncate(m.content, 800),
            },
          ),
    ];

    try {
      for (var turn = 0; turn < 12; turn++) {
        if (_cancelRequested) {
          _emit('done', 'stopped by user');
          break;
        }
        _resetLiveBuffers();
        final msg = await _callLlm(p, msgs, s);
        // Meter tokens for the Usage screen (real data, DSH StatsLine style).
        if (msg != null) {
          final u = msg['usage'] as Map<String, dynamic>?;
          AppState.I.appendUsage(
            UsageEntry(
              time: DateTime.now(),
              providerId: p.id,
              providerName: p.name,
              model: _baseModelOf(p.selectedModel ?? ''),
              promptTokens: (u?['prompt_tokens'] as num?)?.toInt() ?? 0,
              completionTokens: (u?['completion_tokens'] as num?)?.toInt() ?? 0,
              totalTokens: (u?['total_tokens'] as num?)?.toInt() ?? 0,
              duration: Duration.zero,
            ),
          );
        }
        if (_cancelRequested) {
          // Surface a clean "stopped" message instead of the failure text.
          _finalizeLiveStopped();
          _emit('done', 'stopped by user');
          break;
        }
        if (msg == null) {
          _emit('err', lastError ?? 'unknown model error');
          _appendAssistant(
            '⚠️ ${lastError ?? "The model request failed."}\n\n'
            'Agar model/provider already configured hai to Settings → AI response timeout badhao, ya dobara try karo.',
            session: s,
          );
          lastRunElapsedMs = DateTime.now().difference(_runStart ?? DateTime.now()).inMilliseconds;
          break;
        }

        // Stamp elapsed on the live message bubble.
        if (_liveMsg != null) {
          _liveMsg!.elapsedMs =
              DateTime.now().difference(_runStart ?? DateTime.now()).inMilliseconds;
          lastRunElapsedMs = _liveMsg!.elapsedMs;
        }

        final toolCalls = msg['tool_calls'] as List?;
        if (toolCalls == null || toolCalls.isEmpty) {
          // FINAL answer — already streamed to the bubble live.  But if the
          // user queued messages mid-run (opencode behavior), fold them in
          // here so the model answers them in the NEXT request of THIS run
          // instead of the user waiting for a whole new run to spin up.
          if (_queue.isNotEmpty) {
            msgs.add({
              'role': 'assistant',
              'content': msg['content'] ?? '',
            });
            _finalizeLive();
            _drainQueueIntoMsgs(msgs);
            continue;
          }
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
            'content': cleanTruncate(result, 6000),
          });
        }
        // Queued mid-run messages join the very next request (opencode
        // behavior) — injected right after tool results, before the loop's
        // next _callLlm.
        _drainQueueIntoMsgs(msgs);
      }
      _finalizeLive();
    } catch (e) {
      _emit('err', '$e');
      _appendAssistant('Agent error: $e', session: s);
    } finally {
      activeRunId = null;
      _cancelRequested = false;
      notifyListeners();
      // Auto-start the next queued message (DSH queue behavior). A cancel
      // clears nothing — queued messages still run after the stop.
      if (_queue.isNotEmpty) {
        final next = _queue.removeAt(0);
        // Delay so the UI can settle; also lets listeners see "idle" state.
        Future.delayed(const Duration(milliseconds: 250), () {
          // Record the queued message as a user message in the session
          // (the normal send path does this via AppState.sendMessage).
          AppState.I.sendMessage(next);
          runTask(next);
        });
      }
    }
  }

  /// Clear per-run streaming buffers (new turn = fresh bubble).
  void _resetLiveBuffers() {
    _liveContent.clear();
    _liveReasoning.clear();
    _liveMsg = null;
    _liveSession = null;
  }

  /// On user stop: promote whatever streamed so far (partial content kept,
  /// partial reasoning becomes a kept reasoning note) and close the bubble.
  void _finalizeLiveStopped() {
    final s = _liveSession;
    final m = _liveMsg;
    if (s == null || m == null) {
      _appendAssistant('⏹ Stopped by user.');
      return;
    }
    if (_liveContent.isNotEmpty) {
      m.kind = MsgKind.text;
      m.thinking = false;
      m.content = '${_liveContent.toString()}\n\n*⏹ stopped by user*';
    } else if (_liveReasoning.isNotEmpty) {
      m.kind = MsgKind.reasoning;
      m.thinking = true;
      m.content =
          '${cleanReasoningText(_liveReasoning.toString())}\n\n*⏹ stopped by user*';
    } else {
      m.content = '*⏹ stopped by user*';
    }
    _liveSession = null;
    _liveMsg = null;
    AppState.I.refresh();
    AppState.I.persistSessions();
  }

  Future<Map<String, dynamic>?> _callLlm(
    ProviderConfig p,
    List<Map<String, dynamic>> msgs,
    ChatSession session, {
    bool includeTools = true,
  }) async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 20);
      final req = await client
          .postUrl(_endpoint(p))
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw Exception('connect timeout'),
          );
      _activeRequest = req;
      if (_cancelRequested) {
        client.close(force: true);
        _activeRequest = null;
        return null;
      }
      final key = p.cleanApiKey;
      if (key.isNotEmpty) {
        req.headers.set('Authorization', 'Bearer $key');
      }
      req.headers.set('Content-Type', 'application/json');
      req.headers.set('Accept', 'text/event-stream');

      // Strip effort suffix (e.g. "gpt-5.2 · High") → real model id + effort
      final raw = p.selectedModel ?? '';
      final effMatch = RegExp(
        r'·\s*(low|medium|high)$',
        caseSensitive: false,
      ).firstMatch(raw);
      final modelId = effMatch != null
          ? raw.substring(0, effMatch.start).trim()
          : raw;
      final effort = effMatch?.group(1)?.toLowerCase();

      final body = <String, dynamic>{
        'model': modelId,
        'messages': msgs,
        'stream': true,
      };
      final toolList = includeTools ? _tools : const <Map<String, dynamic>>[];
      if (toolList.isNotEmpty) body['tools'] = toolList;
      if (effort != null) body['reasoning_effort'] = effort;

      final bodyStr = jsonEncode(body);
      final bodyBytes = utf8.encode(bodyStr);
      req.headers.contentLength = bodyBytes.length;
      req.add(bodyBytes);

      // Total stream deadline — user-configurable in Settings (default 2 min).
      final streamDeadline = DateTime.now().add(Duration(seconds: AppState.I.responseTimeoutSec));
      // Time-to-first-response (headers) — also respects the settings value;
      // slow/reasoning models often take >30s before the first SSE byte.
      final res = await req.close().timeout(
        Duration(seconds: AppState.I.responseTimeoutSec),
        onTimeout: () {
          lastError = 'no response from ${p.name} for '
              '${AppState.I.responseTimeoutSec}s — Settings me '
              '"AI response timeout" badhao ya provider check karo';
          throw TimeoutException(lastError ?? 'first-byte timeout');
        },
      );
      if (res.statusCode != 200) {
        final data = <int>[];
        await for (final c in res) {
          data.addAll(c);
          if (data.length > 65536) break; // bounded error read
        }
        final txt = utf8.decode(data, allowMalformed: true);
        client.close(force: true);
        // ── Auto-fallback for providers that reject tool schemas ──
        // Many compatible endpoints (older OpenRouter models, some
        // providers' BYOK gateways) return 400/404/422 with
        // "tools"/"tool_calls"/"function" in the error body. The DSH-web
        // behaviour is to retry WITHOUT tools so the model still answers.
        final mightBeToolRejection = (res.statusCode == 400 ||
                res.statusCode == 404 ||
                res.statusCode == 422) &&
            includeTools &&
            toolList.isNotEmpty &&
            (txt.contains('tool') ||
                txt.contains('function') ||
                txt.contains('tool_choice') ||
                txt.contains('not supported'));
        if (mightBeToolRejection) {
          _emit('think',
              'provider rejected tool schema — retrying without tools');
          return _callLlm(p, msgs, session, includeTools: false);
        }
        final hint = switch (res.statusCode) {
          401 || 403 => 'API key invalid/expired — Settings → ${p.name} me key dobara daalo.',
          404 => 'Model "$modelId" endpoint pe nahi mila — model picker se dobara choose karo.',
          429 => 'Rate limit — thoda wait karke retry karo.',
          >= 500 => 'Provider server issue (${p.name}) — thodi der baad retry.',
          _ => '',
        };
        lastError = 'HTTP ${res.statusCode} ${p.name} · $modelId\n'
            '${hint.isNotEmpty ? '$hint\n' : ''}${cleanTruncate(txt, 180)}';
        _emit('err', 'LLM ${res.statusCode}: ${txt.substring(0, txt.length.clamp(0, 300))}');
        return null;
      }

      // ── SSE parse: bounded buffers, resilient to malformed lines ──
      final contentBuf = StringBuffer();
      final reasoningBuf = StringBuffer();
      final tcAcc = <int, Map<String, dynamic>>{};
      String? finishReason;
      Map<String, dynamic>? usage;

      await for (final raw
          in res
              .cast<List<int>>()
              .transform(SseLineSplitter(maxBytes: 8 * 1024 * 1024))
              .timeout(
                streamDeadline.difference(DateTime.now()),
                onTimeout: (sink) {
                  lastError = 'model stream exceeded ${AppState.I.responseTimeoutSec}s — Settings me timeout badhayein';
                  throw TimeoutException(lastError ?? 'model stream timeout');
                },
              )) {
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
        // Usage chunk — some providers send it with empty choices, so
        // parse it BEFORE the choices guard.
        final u = j['usage'];
        if (u is Map<String, dynamic>) usage = u;
        final choices = j['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final choice = choices[0] as Map<String, dynamic>;
        final delta =
            (choice['delta'] ?? choice['message'] ?? {})
                as Map<String, dynamic>;
        finishReason = choice['finish_reason'] as String? ?? finishReason;

        final c = delta['content'];
        if (c is String && c.isNotEmpty) {
          contentBuf.write(c);
          _streamToBubble(session, c);
        }
        // Reasoning tokens — DeepSeek `reasoning_content` / OpenRouter `reasoning`
        final r = delta['reasoning_content'] ?? delta['reasoning'];
        if (r is String && r.isNotEmpty) {
          reasoningBuf.write(r);
          _streamReasoning(session, r);
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
      _activeRequest = null;

      if (contentBuf.isEmpty && reasoningBuf.isEmpty && tcAcc.isEmpty) {
        lastError ??= 'empty response from ${modelId.isEmpty ? 'model' : modelId}';
        _emit('err', lastError!);
        return null;
      }
      return {
        'role': 'assistant',
        'content': contentBuf.toString(),
        if (reasoningBuf.isNotEmpty)
          'reasoning_content': reasoningBuf.toString(),
        if (tcAcc.isNotEmpty) 'tool_calls': tcAcc.values.toList(),
        'finish_reason': ?finishReason,
        'usage': ?usage,
        'elapsedMs': DateTime.now().difference(_runStart ?? DateTime.now()).inMilliseconds,
      };
    } catch (e) {
      // A user-initiated cancel aborts the request — surface it as stopped,
      // not as an error.
      if (_cancelRequested) {
        return null;
      }
      lastError = 'stream error: $e';
      _emit('err', lastError!);
      return null;
    } finally {
      _activeRequest = null;
      client?.close(force: true);
    }
  }

  // ── LIVE BUBBLE streaming (DSH-web style) ─────────────────────────────
  final StringBuffer _liveContent = StringBuffer();
  final StringBuffer _liveReasoning = StringBuffer();
  ChatSession? _liveSession;
  Message? _liveMsg;

  void _ensureLiveMsg(ChatSession s) {
    if (_liveSession == s &&
        _liveMsg != null &&
        s.messages.contains(_liveMsg)) {
      return; // reuse
    }
    _liveMsg = Message(
      role: 'assistant',
      kind: MsgKind.reasoning,
      thinking: true,
      content: '',
    );
    s.messages.add(_liveMsg!);
    _liveSession = s;
  }

  void _streamToBubble(ChatSession s, String tok) {
    _ensureLiveMsg(s);
    _liveContent.write(tok);
    _liveMsg!.content = _liveContent.toString();
    _liveMsg!.thinking = _liveContent.isEmpty;
    AppState.I.refresh();
  }

  void _streamReasoning(ChatSession s, String tok) {
    _ensureLiveMsg(s);
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
      m.content = cleanReasoningText(_liveReasoning.toString());
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
          'run_shell',
          cmd,
          'Command ${mode == AgentMode.studio ? "Ubuntu sandbox me" : "phone terminal (device shell) me"} chlega:\n\$ $cmd',
        );
        if (!ok) return 'DENIED by user';
        _emit('shell', cmd);
        try {
          final work = await _sessionWorkDir();
          if (mode == AgentMode.studio) {
            // Studio tier — full Ubuntu proot sandbox.
            final out = await SandboxService.I
                .exec(['bash', '-lc', cmd], hostWorkDir: work)
                .timeout(const Duration(seconds: 60));
            for (final l in const LineSplitter().convert(out.trim())) {
              _emit('shellOut', l);
            }
            return out.isEmpty ? '(no output)' : out;
          }
          // Phone terminal tier — device shell, no install needed.
          final out = await SandboxService.I
              .execHost(cmd, hostWorkDir: work)
              .timeout(const Duration(seconds: 60));
          for (final l in const LineSplitter().convert(out.trim())) {
            _emit('shellOut', l);
          }
          final hint = out.contains('not found') || out.contains('not: found')
              ? '\n\n[phone terminal: sirf Android toybox commands hain — '
                  'python/gcc/apt ke liye Studio mode me Ubuntu sandbox '
                  'install karo]'
              : '';
          return (out.isEmpty ? '(no output)' : out) + hint;
        } catch (e) {
          // Friendly actionable message — the model relays this to the user.
          if ('$e'.contains('not installed')) {
            return mode == AgentMode.studio
                ? 'sandbox not installed yet. Tell the user: "Studio kholke '
                    'sandbox install karo (one-time, ~320 MB), phir command '
                    'chalega."'
                : 'phone terminal error: $e';
          }
          return 'sandbox error: $e';
        }

      case 'request_permission':
        final perm = args['permission'] as String;
        final reason = args['reason'] as String? ?? '';
        final label = _permissionLabel(perm);
        _emit('think', 'requesting device permission: $perm');
        // ALWAYS ask the user — device permissions are never auto-approved,
        // even in full-access mode (Play-Store policy compliance).
        final granted = await _askUser(
          'request_permission',
          perm,
          'AI ko device permission chahiye: $label\n'
              '• Permission: $perm\n'
              '• Reason: ${reason.isEmpty ? '(AI ne reason nahi diya)' : reason}\n\n'
              'Allow karne par Android system dialog aayegi.',
        );
        if (!granted) {
          _emit('shellOut', '$perm → DENIED by user');
          return '$perm: DENIED by user';
        }
        try {
          final result = await _requestSystemPermission(perm);
          _emit('shellOut', '$perm → $result');
          return '$perm: $result';
        } catch (e) {
          return '$perm: request failed: $e';
        }

      case 'browser_open':
        final url = args['url'] as String;
        final ok = await _maybeApprove(
          'browser_open',
          url,
          'Browser panel me ye page khulega:\n$url',
        );
        if (!ok) return 'DENIED by user';
        _emit('nav', url);
        browserBusy = true;
        notifyListeners();
        try {
          // Drive the persistent browser tab (creates one if needed).
          final tab = _activeTab;
          tab.controller ??= controllerForTab(tab);
          tab.controller!.loadRequest(Uri.parse(url));
          tab.url = url;
          browserUrl = url;
          notifyListeners();
          _emit('page', 'loading $url');
          // Give the webview time to load before reading text.
          await Future.delayed(const Duration(seconds: 2));
          final r = await HttpShim.get(
            Uri.parse(url),
            headers: {'User-Agent': 'OvidAgent/1.0'},
          );
          var body = utf8.decode(r.bytes, allowMalformed: true);
          body = body
              .replaceAll(
                RegExp(r'<script[\s\S]*?</script>', multiLine: true),
                '',
              )
              .replaceAll(
                RegExp(r'<style[\s\S]*?</style>', multiLine: true),
                '',
              )
              .replaceAll(RegExp(r'<[^>]+>'), ' ')
              .replaceAll(RegExp(r'\s{2,}'), '\n')
              .trim();
          browserUrl = url;
          browserPageText = cleanTruncate(body, 5000);
          notifyListeners();
          _emit('page', '${r.status} · ${body.length} chars');
          return browserPageText!;
        } catch (e) {
          return 'fetch failed: $e';
        } finally {
          browserBusy = false;
          notifyListeners();
        }

      // ─── Chrome DevTools MCP tools (inbuilt WebView) ─────────────────
      case 'browser_navigate':
        final url = args['url'] as String;
        final ok = await _maybeApprove(
          'browser_navigate',
          url,
          'Browser me ye page khulega:\n$url',
        );
        if (!ok) return 'DENIED by user';
        final tab = _activeTab;
        tab.controller ??= controllerForTab(tab);
        tab.controller!.loadRequest(Uri.parse(url));
        tab.url = url;
        browserUrl = url;
        _emit('nav', url);
        await Future.delayed(const Duration(seconds: 2));
        final title = await tab.controller!.getTitle();
        return 'Navigated to $url\nTitle: ${title ?? "unknown"}';

      // ── Tab management so the model can drive the user-visible strip ──
      case 'browser_new_tab':
        final url = args['url'] as String;
        final ok = await _maybeApprove(
          'browser_new_tab',
          url,
          'AI naya browser tab kholega:\n$url',
        );
        if (!ok) return 'DENIED by user';
        newBrowserTab(url); // creates tab + loads url, persists to prefs
        _emit('nav', 'new tab → $url');
        return 'Opened tab #${browserTabs.length - 1}: $url '
            '(${browserTabs.length} tabs total)';
      case 'browser_switch_tab':
        final idx = (args['index'] as num).toInt();
        if (idx < 0 || idx >= browserTabs.length) {
          return 'invalid tab index $idx — call browser_list_tabs first '
              '(${browserTabs.length} tabs open)';
        }
        selectBrowserTab(idx);
        _emit('nav', 'switched to tab #$idx');
        return 'Active tab #$idx: ${browserTabs[idx].url}';
      case 'browser_list_tabs':
        if (browserTabs.isEmpty) return 'No tabs open.';
        final b = StringBuffer();
        for (var i = 0; i < browserTabs.length; i++) {
          final t = browserTabs[i];
          b.writeln(
            '[${i == activeTabIndex ? "*" : " "}] #$i '
            '${t.title?.isNotEmpty == true ? '${t.title} — ' : ''}${t.url}',
          );
        }
        return b.toString();
      case 'browser_close_tab':
        final ci = (args['index'] as num).toInt();
        if (ci < 0 || ci >= browserTabs.length) return 'invalid tab index $ci';
        final gone = browserTabs[ci].url;
        closeBrowserTab(ci);
        _emit('nav', 'closed tab #$ci');
        return 'Closed tab #$ci ($gone)';

      // ─── Plugin tools (dynamic, installed plugins) ────────────────────
      case 'web_search':
        final q = args['query'] as String;
        _emit('nav', 'searching: $q');
        try {
          return await _webSearch(q);
        } catch (e) {
          return 'web search failed: $e';
        }
      case 'generate_image':
        final prompt = args['prompt'] as String;
        _emit('shell', 'image gen: $prompt');
        try {
          return await _generateImage(prompt);
        } catch (e) {
          return 'image generation failed: $e';
        }
      case 'read_attachment':
        final fname = args['filename'] as String;
        _emit('shell', 'reading: $fname');
        // Real check — file must exist in the session workspace.
        try {
          final work = await _sessionWorkDir();
          final f = File('${work.path}/$fname');
          if (!f.existsSync()) {
            return 'No file "$fname" in the session workspace. Ask the user '
                'to share the file path, or create it first with run_shell.';
          }
          final bytes = await f.readAsBytes();
          if (bytes.length > 512 * 1024) {
            return 'File too large to read directly (${bytes.length} bytes). '
                'Use run_shell with head/tail instead.';
          }
          return utf8.decode(bytes, allowMalformed: true);
        } catch (e) {
          return 'read failed: $e';
        }
      case 'fetch_url':
        final u = args['url'] as String;
        _emit('nav', 'fetching: $u');
        try {
          final r = await HttpShim.get(
            Uri.parse(u),
            headers: {'User-Agent': 'OvidAgent/1.0'},
          );
          var body = utf8.decode(r.bytes, allowMalformed: true);
          body = body
              .replaceAll(
                RegExp(r'<script[\s\S]*?</script>', multiLine: true),
                '',
              )
              .replaceAll(
                RegExp(r'<style[\s\S]*?</style>', multiLine: true),
                '',
              )
              .replaceAll(RegExp(r'<[^>]+>'), ' ')
              .replaceAll(RegExp(r'\s{2,}'), '\n')
              .trim();
          return cleanTruncate(body, 5000);
        } catch (e) {
          return 'fetch failed: $e';
        }
      case 'run_code':
        final code = args['code'] as String;
        final lang = args['lang'] as String? ?? 'python';
        final ok2 = await _maybeApprove(
          'run_code',
          code,
          'Code will run in sandbox:\n$lang\n$code',
        );
        if (!ok2) return 'DENIED by user';
        _emit('shell', 'run_code ($lang)');
        try {
          final work = await _sessionWorkDir();
          final out = await SandboxService.I
              .exec([lang == 'python' ? 'python3' : 'node', '-e', code],
                    hostWorkDir: work)
              .timeout(const Duration(seconds: 60));
          _emit('shellOut', out);
          return out;
        } catch (e) {
          return 'exec error: $e';
        }
      case 'memory_search':
        final q2 = (args['query'] as String).toLowerCase();
        _emit('think', 'searching memory: $q2');
        final app = AppState.I;
        final share = app.shareSessionMemory;
        final current = app.activeSession;
        if (current == null) return 'no active session';
        // Which messages to search:
        //   share OFF → only THIS session's messages
        //   share ON  → ALL sessions' messages (user explicitly enabled it)
        final hits = <String>[];
        final pool = share
            ? app.sessions.cast<ChatSession>()
            : <ChatSession>[current];
        for (final sess in pool) {
          for (final m in sess.messages) {
            if (m.content.toLowerCase().contains(q2)) {
              final label = share ? '[${sess.title}] ' : '';
              hits.add(
                  '$label${m.role}: ${cleanTruncate(m.content.replaceAll('\n', ' '), 120)}');
              if (hits.length >= 8) break;
            }
          }
          if (hits.length >= 8) break;
        }
        if (hits.isEmpty) {
          return share
              ? 'No matches for "$q2" across all sessions.'
              : 'No matches for "$q2" in this session. (Enable "Share session memory" in Settings to search across chats.)';
        }
        return hits.join('\n');
      case String() when name.startsWith('mcp_'):
        // Real MCP proxy — call through McpService (spawns/connects as needed).
        final mcpName = name.substring(4).replaceAll('_', ' ');
        final action = args['action'] as String? ?? 'execute';
        final mcpArgs = args['args'] as Map<String, dynamic>? ?? {};
        _emit('shell', 'MCP: $mcpName → $action');
        if (!McpService.I.isConnected(mcpName)) {
          // Find the matching McpServer config and connect for real.
          final match = AppState.I.mcpServers
              .where((s) => s.name.toLowerCase().contains(mcpName))
              .firstOrNull;
          if (match == null) {
            return 'MCP server "$mcpName" not configured. Add it in Settings → MCP servers.';
          }
          final res = await McpService.I.connect(match);
          if (!res.contains('connected')) return res;
        }
        return await McpService.I.callTool(mcpName, action, mcpArgs);
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

      // ─── DSH-harness catalog management (providers/plugins/MCP) ──────
      case 'catalog_list_providers':
        _emit('think', 'listing providers');
        final app = AppState.I;
        return (app.providers.map((p) {
          final key = p.hasKey ? 'key ✓' : 'no key';
          return '${p.name} (${p.id}) — $key · ${p.models.length} models '
              '${p.isConfigured ? '' : '· NOT CONFIGURED'}';
        }).join('\n'));

      case 'catalog_add_provider':
        final name = args['name'] as String;
        final baseUrl = args['base_url'] as String;
        final apiKey = args['api_key'] as String? ?? '';
        final models = (args['models'] as List?)
                ?.whereType<String>()
                .toList() ??
            <String>[];
        _emit('think', 'adding provider: $name');
        final err = await AppState.I.addCustomProvider(
          name: name,
          baseUrl: baseUrl,
          apiKey: apiKey,
        );
        if (err != null) return 'Provider add failed: $err';
        // Optionally append models to the newly created provider.
        if (models.isNotEmpty) {
          final p = AppState.I.providerById('custom-${_slugFor(name)}');
          if (p != null) {
            for (final m in models) {
              if (!p.models.contains(m)) p.models.add(m);
            }
            await AppState.I.persistProviderState();
            AppState.I.refresh();
          }
        }
        _emit('done', 'provider added: $name');
        return 'Provider "$name" added (${models.length} models). '
            'User can now select it in the model picker.';

      case 'catalog_remove_provider':
        final pid = args['provider_id'] as String;
        _emit('think', 'removing provider: $pid');
        final ok = await AppState.I.removeCustomProvider(pid);
        if (ok != null) return 'Remove failed: $ok';
        _emit('done', 'provider removed: $pid');
        return 'Provider "$pid" removed.';

      case 'catalog_list_plugins':
        _emit('think', 'listing plugins');
        final app = AppState.I;
        return (app.plugins.map((p) =>
                '${p.name} — ${p.installed ? 'installed' : 'available'}'
                '${p.enabled ? ' · enabled' : ''}'))
            .join('\n');

      case 'catalog_list_mcp':
        _emit('think', 'listing MCP servers');
        final app = AppState.I;
        return (app.mcpServers.map((s) =>
                '${s.name} — ${s.connected ? 'connected' : 'disconnected'}'
                ' · ${s.command} ${s.args.join(' ')}'))
            .join('\n');

      case 'catalog_add_mcp':
        final name = args['name'] as String;
        final command = args['command'] as String;
        final mArgs = (args['args'] as List?)?.whereType<String>().toList() ??
            <String>[];
        _emit('think', 'adding MCP server: $name');
        AppState.I.addCustomMcpServer(
          name: name,
          command: command,
          args: mArgs,
        );
        _emit('done', 'MCP server added: $name');
        return 'MCP server "$name" added. Connect it from the Plugins → MCP '
            'section (or ask me to connect it).';

      case 'catalog_remove_mcp':
        final name = args['name'] as String;
        _emit('think', 'removing MCP server: $name');
        final match = AppState.I.mcpServers
            .where((s) => s.name.toLowerCase() == name.toLowerCase())
            .firstOrNull;
        if (match == null) return 'MCP server not found: $name';
        if (!match.custom) {
          return '"$name" is a built-in server — it can be disconnected but not removed.';
        }
        AppState.I.removeMcpServer(match);
        _emit('done', 'MCP server removed: $name');
        return 'MCP server "$name" removed.';

      case 'catalog_add_marketplace':
        final repo = args['repo'] as String;
        _emit('think', 'importing marketplace: $repo');
        final msg = await AppState.I.fetchMarketplaceCatalog(repo);
        AppState.I.addMarketplace(repo);
        _emit('done', 'marketplace imported: $repo');
        return msg;
      case 'browser_click':
        final sel = args['selector'] as String;
        final tab = _activeTab;
        tab.controller ??= controllerForTab(tab);
        final js = 'document.querySelector(${jsonEncode(sel)})?.click()';
        await tab.controller!.runJavaScript(js);
        _emit('shell', 'click: $sel');
        return 'Clicked $sel (or attempted)';
      case 'browser_evaluate':
        final expr = args['expression'] as String;
        final tab = _activeTab;
        tab.controller ??= controllerForTab(tab);
        try {
          final result = await tab.controller!.runJavaScriptReturningResult(
            expr,
          );
          final text = result.toString();
          _emit('shellOut', 'eval: $expr');
          return cleanTruncate(text, 4000);
        } catch (e) {
          return 'JS error: $e';
        }
      case 'browser_read':
        final tab = _activeTab;
        tab.controller ??= controllerForTab(tab);
        try {
          final title = await tab.controller!.getTitle();
          final result = await tab.controller!.runJavaScriptReturningResult(
            'document.body.innerText.substring(0,5000)',
          );
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
        openStudioFile(path, c);
        _emit('file', 'read $path');
        return cleanTruncate(c, 6000);

      case 'file_write':
        final path = args['path'] as String;
        final content = args['content'] as String;
        final ok = await _maybeApprove(
          'file_write',
          path,
          'LOCAL EDIT (no push yet):\n$path\n${content.length} chars',
        );
        if (!ok) return 'DENIED by user';
        RepoCache.I.write(path, content);
        openStudioFile(path, content);
        _emit('file', 'edited $path');
        return 'written locally ✓ · $path · ${content.length} chars\n'
            'call commit() to push, or preview() to see web build.';

      case 'commit':
        final message = (args['message'] ?? 'Ovid agent update') as String;
        if (!RepoCache.I.hasPending) return 'no pending changes';
        final ok = await _maybeApprove(
          'commit',
          message,
          'PUSH TO GITHUB\n"${RepoCache.I.repoFull}"\n'
              '${RepoCache.I.dirtyCount} files · "$message"',
        );
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
  Future<bool> _maybeApprove(String tool, String summary, String detail) async {
    switch (mode) {
      case AgentMode.drive:
        return true;
      case AgentMode.auto:
      case AgentMode.studio:
        return tool != 'commit' ? true : await _askUser(tool, summary, detail);
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

  void _appendAssistant(
    String text, {
    MsgKind kind = MsgKind.text,
    ChatSession? session,
  }) {
    final s = session ?? AppState.I.activeSession;
    if (s == null || text.trim().isEmpty) return;
    s.messages.add(Message(role: 'assistant', kind: kind, content: text));
    AppState.I.refresh();
  }

  // ── Device permission bridge (permission_handler, Play-policy compliant) ──
  // Permissions are pre-declared in AndroidManifest.xml; at runtime the
  // system dialog fires from here after the in-chat user consent gate.
  static const Map<String, String> _permLabels = {
    'notifications': 'Notifications',
    'camera': 'Camera',
    'microphone': 'Microphone',
    'storage': 'Storage (files)',
    'photos': 'Photos',
    'videos': 'Videos',
    'audio': 'Music & audio files',
    'contacts': 'Contacts',
    'calendar': 'Calendar',
    'location': 'Location',
    'phone': 'Phone / calls',
    'sms': 'SMS',
    'bluetooth': 'Bluetooth (nearby devices)',
    'activity_recognition': 'Physical activity',
    'sensors': 'Body sensors',
  };

  String _permissionLabel(String perm) =>
      _permLabels[perm] ?? perm.toUpperCase();

  Future<String> _requestSystemPermission(String name) async {
    final Permission? p;
    switch (name) {
      case 'notifications':
        p = Permission.notification;
      case 'camera':
        p = Permission.camera;
      case 'microphone':
        p = Permission.microphone;
      case 'storage':
        // Legacy storage (≤ Android 12) — on 13+ this maps to media perms.
        p = Permission.storage;
      case 'photos':
        p = Permission.photos;
      case 'videos':
        p = Permission.videos;
      case 'audio':
        p = Permission.audio;
      case 'contacts':
        p = Permission.contacts;
      case 'calendar':
        // Full access (READ + WRITE) — both declared in the manifest.
        p = Permission.calendarFullAccess;
      case 'location':
        p = Permission.locationWhenInUse;
      case 'phone':
        // permission_handler's "phone" group covers CALL_PHONE +
        // READ_PHONE_STATE (both declared in the manifest).
        p = Permission.phone;
      case 'sms':
        p = Permission.sms;
      case 'bluetooth':
        // SCAN + CONNECT both declared; request the connect one (it also
        // triggers the nearby-devices dialog).
        p = Permission.bluetoothConnect;
      case 'activity_recognition':
        p = Permission.activityRecognition;
      case 'sensors':
        p = Permission.sensors;
      default:
        return 'unknown permission';
    }
    // If already granted, short-circuit without a system dialog.
    if (await p.isGranted) return 'granted';
    final status = await p.request();
    if (status.isGranted) return 'granted';
    if (status.isPermanentlyDenied) {
      // Send the user to system settings so they can flip it on there.
      await openAppSettings();
      return 'denied permanently — opened Settings so you can enable it';
    }
    return 'denied';
  }

  // ── REAL TOOL HANDLERS (no stubs) ─────────────────────────────────────

  /// Free web search via DuckDuckGo HTML — no API key needed.
  /// Scrapes the top result titles + snippets.
  Future<String> _webSearch(String query) async {
    final url = Uri.parse(
      'https://html.duckduckgo.com/html/?q=${Uri.encodeQueryComponent(query)}',
    );
    final r = await HttpShim.get(
      url,
      headers: {'User-Agent': 'OvidAgent/1.0'},
    );
    if (r.status != 200) return 'search failed (${r.status})';
    final html = utf8.decode(r.bytes, allowMalformed: true);
    // Parse result titles + snippets from the HTML (DuckDuckGo layout).
    final results = <String>[];
    final resultRegex = RegExp(
      r'<a[^>]+class="result__a"[^>]*>(.*?)</a>.*?'
      r'<a[^>]+class="result__snippet"[^>]*>(.*?)</a>',
      dotAll: true,
    );
    for (final m in resultRegex.allMatches(html)) {
      if (results.length >= 8) break;
      final title = _stripHtml(m.group(1) ?? '');
      final snippet = _stripHtml(m.group(2) ?? '');
      if (title.isNotEmpty) {
        results.add('• $title\n  $snippet');
      }
    }
    if (results.isEmpty) return 'No results found for "$query".';
    return 'Web search: "$query"\n\n${results.join('\n\n')}';
  }

  /// Free image generation via Pollinations.ai — no key, no signup.
  /// Returns a markdown image link the chat renderer shows inline.
  Future<String> _generateImage(String prompt) async {
    final encoded = Uri.encodeQueryComponent(prompt);
    final url = 'https://image.pollinations.ai/prompt/$encoded';
    // Pollinations generates on-demand — the URL IS the image. We just
    // emit a markdown image so the chat bubble renders it.
    _emit('done', 'image generated: $prompt');
    return '![generated image]($url)\n\n*Generated via Pollinations.ai (free, no key).*';
  }

  /// Strip HTML tags from a snippet for plain-text display.
  String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
  }

  /// Mirror of the private _slug in state.dart — used to locate custom
  /// providers by display name ("custom-" + slug).
  String _slugFor(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  /// Strip the " · High/Low/Medium" effort suffix from a model label.
  String _baseModelOf(String raw) {
    final m = RegExp(r'·\s*(low|medium|high)$', caseSensitive: false)
        .firstMatch(raw);
    return m != null ? raw.substring(0, m.start).trim() : raw;
  }
}

/// Splits a byte stream into UTF-8 lines with a hard total-byte cap.
/// Unlike `LineSplitter`, no single newline-free line can grow without bound.
class SseLineSplitter extends StreamTransformerBase<List<int>, String> {
  final int maxBytes;

  const SseLineSplitter({required this.maxBytes});

  @override
  Stream<String> bind(Stream<List<int>> stream) {
    var totalBytes = 0;
    var pending = BytesBuilder(copy: false);
    late StreamController<String> controller;
    StreamSubscription<List<int>>? sub;

    void fail(String message) {
      controller.addError(HttpException(message));
      unawaited(sub?.cancel());
      unawaited(controller.close());
    }

    void flushLines({required bool endOfStream}) {
      final bytes = pending.takeBytes();
      if (bytes.isEmpty) return;
      final decoded = utf8.decode(bytes, allowMalformed: true);
      var start = 0;
      for (var i = 0; i < decoded.length; i++) {
        final code = decoded.codeUnitAt(i);
        if (code == 0x0A || code == 0x0D) {
          if (i > start) controller.add(decoded.substring(start, i));
          if (code == 0x0D &&
              i + 1 < decoded.length &&
              decoded.codeUnitAt(i + 1) == 0x0A) {
            i++; // CRLF
          }
          start = i + 1;
        }
      }
      if (start < decoded.length) {
        if (endOfStream) {
          controller.add(decoded.substring(start));
        } else {
          pending = BytesBuilder(copy: false)
            ..add(utf8.encode(decoded.substring(start)));
        }
      }
    }

    controller = StreamController<String>(
      onListen: () {
        sub = stream.listen(
          (chunk) {
            if (controller.isClosed) return;
            totalBytes += chunk.length;
            if (totalBytes > maxBytes) {
              fail('response exceeded $maxBytes bytes');
              return;
            }
            pending.add(chunk);
            flushLines(endOfStream: false);
          },
          onError: controller.addError,
          onDone: () {
            flushLines(endOfStream: true);
            unawaited(controller.close());
          },
          cancelOnError: true,
        );
      },
      onCancel: () => sub?.cancel(),
    );
    return controller.stream;
  }
}

class HttpShim {
  static const _requestTimeout = Duration(seconds: 20);
  static const _maxResponseBytes = 8 * 1024 * 1024;

  static Future<({int status, String bodyText, List<int> bytes})> post(
    Uri u, {
    Map<String, String>? headers,
    Object? body,
    Duration timeout = _requestTimeout,
    int maxResponseBytes = _maxResponseBytes,
  }) async {
    final client = HttpClient();
    try {
      return await _postInner(
        client,
        u,
        headers: headers,
        body: body,
        timeout: timeout,
        maxResponseBytes: maxResponseBytes,
      ).timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  static Future<({int status, String bodyText, List<int> bytes})> _postInner(
    HttpClient client,
    Uri u, {
    Map<String, String>? headers,
    Object? body,
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    client.connectionTimeout = timeout;
    final req = await client.postUrl(u);
    headers?.forEach((k, v) => req.headers.set(k, v));
    final bodyBytes = utf8.encode(body as String);
    req.headers.contentLength = bodyBytes.length;
    req.add(bodyBytes);
    final res = await req.close();
    final data = await _readBounded(res, maxResponseBytes);
    return (
      status: res.statusCode,
      bodyText: utf8.decode(data, allowMalformed: true),
      bytes: data,
    );
  }

  static Future<({int status, String bodyText, List<int> bytes})> get(
    Uri u, {
    Map<String, String>? headers,
    Duration timeout = _requestTimeout,
    int maxResponseBytes = _maxResponseBytes,
  }) async {
    final client = HttpClient();
    try {
      return await _getInner(
        client,
        u,
        headers: headers,
        timeout: timeout,
        maxResponseBytes: maxResponseBytes,
      ).timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  static Future<({int status, String bodyText, List<int> bytes})> _getInner(
    HttpClient client,
    Uri u, {
    Map<String, String>? headers,
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    client.connectionTimeout = timeout;
    final req = await client.getUrl(u);
    headers?.forEach((k, v) => req.headers.set(k, v));
    final res = await req.close();
    final data = await _readBounded(res, maxResponseBytes);
    return (
      status: res.statusCode,
      bodyText: utf8.decode(data, allowMalformed: true),
      bytes: data,
    );
  }

  static Future<List<int>> _readBounded(
    HttpClientResponse response,
    int maxResponseBytes,
  ) async {
    if (maxResponseBytes <= 0) {
      throw ArgumentError.value(
        maxResponseBytes,
        'maxResponseBytes',
        'Must be positive',
      );
    }
    if (response.contentLength > maxResponseBytes) {
      throw HttpException('Response exceeds $maxResponseBytes bytes');
    }
    final data = <int>[];
    await for (final chunk in response) {
      if (data.length + chunk.length > maxResponseBytes) {
        throw HttpException('Response exceeds $maxResponseBytes bytes');
      }
      data.addAll(chunk);
    }
    return data;
  }
}
