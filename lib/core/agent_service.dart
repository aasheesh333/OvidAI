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
/// READ-ONLY → asks user before every action (shell/write/commit all)
/// GENERAL   → shell + browser free; asks for file writes & commits
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
      'Read-only. Asks for permission before every shell, browser, or write action.',
    AgentMode.auto =>
      'Runs shell and browser freely. Asks before pushing to the repo.',
    AgentMode.drive =>
      'Full autonomous — kuch bhi, kahin bhi, no confirmation.',
    AgentMode.studio =>
      'Studio mode — files edit, terminal run, repo access free. '
      'Asks for confirmation before publishing or committing.',
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
  // ── ask_user_question extension (DSH user-questions seam) ──
  /// When non-null, the UI renders structured questions instead of
  /// approve/deny.  The completer resolves true when the user submits
  /// answers; [answers] holds the question-id → answer map.
  final List<UserQuestion>? questions;
  final Map<String, String> answers = {};
  ApprovalRequest({
    required this.tool,
    required this.summary,
    required this.detail,
    this.questions,
  });
}

/// One structured question for ask_user_question — Gemini-web style.
class UserQuestion {
  final String id;
  final String question;
  final String? header;
  final List<QuestionOption> options;
  final bool multi;
  UserQuestion({
    required this.id,
    required this.question,
    this.header,
    this.options = const [],
    this.multi = false,
  });
}

class QuestionOption {
  final String label;
  final String? description;
  const QuestionOption({required this.label, this.description});
}

/// Background job (DSH ctx.jobs equivalent) — a running Process with a
/// name, output buffer, and lifecycle state.
class _BgJob {
  final int id;
  final String name;
  final String command;
  Process? process;
  bool started = false;
  bool finished = false;
  int? exitCode;
  final StringBuffer output = StringBuffer();
  _BgJob({required this.id, required this.name, required this.command});
}

/// Per-session agent run state — one per ChatSession so many sessions run
/// in parallel without interfering (DSH multi-session parity).  Switching
/// sessions NEVER stops another session's run.
class _AgentRun {
  String? activeRunId;
  bool cancelRequested = false;
  HttpClientRequest? activeRequest;
  final List<String> queue = [];
  ApprovalRequest? pendingApproval;
  bool planMode = false;
  final Map<int, _BgJob> jobs = {};
  int jobCounter = 0;
  Message? activeToolMsg;
  DateTime? runStart;
  int? lastRunElapsedMs;
  // Live streaming buffers for this session's bubble.
  final StringBuffer liveContent = StringBuffer();
  final StringBuffer liveReasoning = StringBuffer();
  ChatSession? liveSession;
  Message? liveMsg;
}

/// Session event (DSH SessionEvent equivalent) — durable facts about what
/// happened in a session (tool calls, mode changes, errors, approvals).
class SessionEvent {
  final String type;
  final String data;
  final DateTime timestamp;
  SessionEvent({
    required this.type,
    required this.data,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
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
  AgentService._() {
    // Session-local reminder engine (DSH schedule delivery) — ticks
    // every second, no-ops when no schedules exist.
    _startScheduleTimer();
    // Deleted sessions lose their run; all others keep running in parallel.
    AppState.I.onSessionDeleted = dropSessionRun;
    // Per-session browser tabs: lazy-restore on session switch.
    AppState.I.onSessionSwitched = onSessionSwitched;
  }
  /// Named private constructor for subagent children (same body as [_]).
  AgentService._internal() : this._();
  static final AgentService I = AgentService._();

  AgentMode mode = AgentMode.auto;

  final List<AgentEvent> events = [];

  // ── PER-SESSION RUN STATE (parallel sessions, DSH parity) ────────────
  // Every session owns an independent _AgentRun (cancel flag, HTTP
  // request, queue, approval, jobs, plan mode, live streaming buffers).
  // 10+ sessions can run at once; switching sessions NEVER stops a run.
  final Map<String, _AgentRun> _runs = {};

  /// The run bound to the current target session.  Subagents (no session)
  /// use a detached run keyed to ''.
  _AgentRun get _run => _runs.putIfAbsent(_currentRunKey(), () => _AgentRun());

  String _currentRunKey() => AppState.I.activeSession?.id ?? '';

  // ── Compatibility accessors (UI reads the ACTIVE session's run) ───────
  String? get activeRunId => _run.activeRunId;
  set activeRunId(String? v) => _run.activeRunId = v;
  ApprovalRequest? get pendingApproval => _run.pendingApproval;
  set pendingApproval(ApprovalRequest? v) => _run.pendingApproval = v;
  bool get planMode => _run.planMode;
  set planMode(bool v) => _run.planMode = v;
  bool get cancelRequested => _run.cancelRequested;
  bool get _cancelRequested => _run.cancelRequested;
  set _cancelRequested(bool v) => _run.cancelRequested = v;
  set _activeRequest(HttpClientRequest? v) => _run.activeRequest = v;
  List<String> get _queue => _run.queue;
  List<String> get queuedMessages => List.unmodifiable(_run.queue);
  Map<int, _BgJob> get _jobs => _run.jobs;
  int get _jobCounter => _run.jobCounter;
  set _jobCounter(int v) => _run.jobCounter = v;
  Message? get _activeToolMsg => _run.activeToolMsg;
  set _activeToolMsg(Message? v) => _run.activeToolMsg = v;
  DateTime? get _runStart => _run.runStart;
  set _runStart(DateTime? v) => _run.runStart = v;
  int? get lastRunElapsedMs => _run.lastRunElapsedMs;
  set lastRunElapsedMs(int? v) => _run.lastRunElapsedMs = v;

  /// Stop the current session's run: aborts the in-flight HTTP request
  /// and flags every loop turn to exit at the next checkpoint.
  void cancelRun() {
    final r = _run;
    if (r.activeRunId == null) return;
    r.cancelRequested = true;
    // Abort the in-flight request — works while connecting AND while
    // streaming (abort() errors the socket, which surfaces in the SSE
    // loop; the per-chunk cancel check then breaks cleanly).
    try {
      r.activeRequest?.abort();
    } catch (_) {}
    _emit('think', 'stop requested — finishing current turn');
    notifyListeners();
  }

  /// Drop a session's run entirely (called from AppState.deleteSession).
  void dropSessionRun(String sessionId) {
    final r = _runs.remove(sessionId);
    if (r == null) return;
    r.cancelRequested = true;
    try {
      r.activeRequest?.abort();
    } catch (_) {}
    if (r.pendingApproval != null) {
      try {
        r.pendingApproval!.completer.complete(false);
      } catch (_) {}
    }
    for (final job in r.jobs.values) {
      if (!job.finished) {
        try {
          job.process?.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    }
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

  // ── PER-SESSION BROWSER (each session owns its tabs + active index) ──
  // The WebView controllers live here — OUTLIVES any BrowserScreen route.
  // Cookies/logins are SHARED across all sessions (WebView CookieManager
  // is app-global): a login done in session A works in sessions B…Z too.
  // Tabs themselves are per-session: switching sessions switches tab sets;
  // old sessions keep their tabs and pages alive as-is.
  static const _kBrowserTabs = 'ovid_browser_tabs';
  static const _kBrowserActiveTab = 'ovid_browser_active_tab';
  static const _kBrowserSessionPrefix = 'ovid_browser_session_';
  static const _defaultBrowserUrl = 'https://www.google.com';

  /// Per-session browser bucket: tab list + active index.
  final Map<String, List<BrowserTab>> _sessionBrowsers = {};
  final Map<String, int> _sessionActiveTab = {};

  bool browserBusy = false; // true while an agent browser tool is running

  /// Tabs of the ACTIVE session (created empty on first access).
  List<BrowserTab> get browserTabs => _browserBucketFor(_currentRunKey());

  /// Active tab index of the ACTIVE session.
  int get activeTabIndex =>
      _sessionActiveTab[_currentRunKey()] ?? 0;
  set activeTabIndex(int v) => _sessionActiveTab[_currentRunKey()] = v;

  List<BrowserTab> _browserBucketFor(String key) =>
      _sessionBrowsers.putIfAbsent(key, () => <BrowserTab>[]);

  /// Tabs belonging to an explicit session id (not the current one).
  List<BrowserTab> browserTabsFor(String sessionId) =>
      _browserBucketFor(sessionId);

  /// True once the browser has ever been opened/pre-warmed in this launch.
  bool get browserReady => browserTabs.isNotEmpty;

  BrowserTab get _activeTab {
    final tabs = browserTabs;
    if (tabs.isEmpty) _newTabInternal(_defaultBrowserUrl);
    if (activeTabIndex >= tabs.length) activeTabIndex = 0;
    return browserTabs[activeTabIndex];
  }

  BrowserTab _newTabInternal(String url) {
    final tabs = browserTabs;
    final tab = BrowserTab(url: url);
    tabs.add(tab);
    activeTabIndex = tabs.length - 1;
    return tab;
  }

  /// Pre-warm the browser once at app launch so it's instantly ready.
  /// Called from main() — safe to call repeatedly (no-op after first).
  /// Restores the ACTIVE session's tabs; other sessions restore lazily
  /// on first access (switching to them).
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

  /// Restore tabs for a session id — called lazily when the user switches
  /// to a session whose tabs were never materialized this launch.
  Future<void> _restoreSessionTabsIfNeeded(String sessionId) async {
    final tabs = _browserBucketFor(sessionId);
    if (tabs.isNotEmpty) return; // already alive this launch
    try {
      final prefs = await SharedPreferences.getInstance();
      final urls = prefs.getStringList('$_kBrowserSessionPrefix$sessionId');
      if (urls != null && urls.isNotEmpty) {
        for (final u in urls) {
          tabs.add(BrowserTab(url: u));
        }
        _sessionActiveTab[sessionId] =
            (prefs.getInt('$_kBrowserActiveTab$sessionId') ?? 0)
                .clamp(0, tabs.length - 1);
      }
    } catch (_) {}
    if (tabs.isEmpty) {
      tabs.add(BrowserTab(url: _defaultBrowserUrl));
    }
  }

  /// Called by AppState.selectSession — brings the newly-active session's
  /// tabs to life (lazy restore) so switching is instant and isolated.
  Future<void> onSessionSwitched(String sessionId) async {
    await _restoreSessionTabsIfNeeded(sessionId);
    notifyListeners();
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
      // Global (last-active) copy for next-launch restore of the
      // then-active session…
      await prefs.setStringList(
        _kBrowserTabs,
        browserTabs.map((t) => t.url).toList(),
      );
      await prefs.setInt(_kBrowserActiveTab, activeTabIndex);
      // …and the per-session copy keyed by this session's id.
      final key = _currentRunKey();
      if (key.isNotEmpty) {
        await prefs.setStringList(
          '$_kBrowserSessionPrefix$key',
          browserTabs.map((t) => t.url).toList(),
        );
        await prefs.setInt('$_kBrowserActiveTab$key', activeTabIndex);
      }
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
    final tabs = browserTabs;
    if (index < 0 || index >= tabs.length) return;
    tabs.removeAt(index);
    if (tabs.isEmpty) {
      _newTabInternal(_defaultBrowserUrl);
    } else if (activeTabIndex >= tabs.length) {
      activeTabIndex = tabs.length - 1;
    }
    _persistBrowserTabs();
    notifyListeners();
  }

  /// User/agent-facing: switch the active tab (agent tools target this).
  void selectBrowserTab(int index) {
    final tabs = browserTabs;
    if (index < 0 || index >= tabs.length) return;
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

  /// Global repo (owner/name) — the last one the user connected in Studio.
  String? repoFull; // e.g. "aasheesh333/Ovid"

  /// Repo for the ACTIVE session — per-session Studio repos.  Falls back
  /// to the global [repoFull] when the session never picked one, so old
  /// sessions keep working exactly as before (as-is).
  String? get sessionRepoFull =>
      AppState.I.getRepoForSession(_currentRunKey(), fallback: repoFull);

  /// Set the repo for the ACTIVE session (Studio pick) — also updates the
  /// global default so future sessions inherit the latest choice.
  set sessionRepoFull(String? v) {
    final key = _currentRunKey();
    if (key.isNotEmpty && v != null) {
      AppState.I.setRepoForSession(key, v);
    }
    repoFull = v; // global default for new sessions
  }

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


  // ── fs tools state (read-before-write policy, DSH observation gate) ──
  /// Paths the AI has read via file_read/fs_edit view — str_replace/insert
  /// require a prior read.  Keyed by session id so sessions don't leak.
  final Map<String, Set<String>> _readPaths = {};
  Set<String> _readPathsFor(String sid) =>
      _readPaths.putIfAbsent(sid, () => {});


  /// Surface of the last model-layer failure (HTTP status, network error,
  /// timeout) so the UI can show the REAL error instead of a dummy string.
  String? lastError;

  /// True while the ACTIVE session has a run in flight — drives the
  /// typing bubble + stop/send button.  Per-session: another session
  /// running does NOT make this session look busy.
  bool get busy => _run.activeRunId != null;

  /// True while ANY session has a run — for global indicators.
  bool get anyBusy => _runs.values.any((r) => r.activeRunId != null);

  void setMode(AgentMode m) {
    mode = m;
    events.add(AgentEvent('think', 'access mode → ${m.label}'));
    notifyListeners();
  }

  void _emit(String kind, String text) {
    events.add(AgentEvent(kind, text));
    if (events.length > 120) events.removeRange(0, events.length - 120);
    // Mirror into the session event log (session_search queries this).
    _sessionEvents.add(SessionEvent(type: kind, data: text));
    if (_sessionEvents.length > 500) {
      _sessionEvents.removeRange(0, _sessionEvents.length - 500);
    }
    // DSH ToolRow parity: shell output streams into the live tool card.
    if (kind == 'shellOut' && _activeToolMsg != null) {
      _toolStream('$text\n');
    }
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
    // ── Real MCP server tools (discovered via tools/list) ──
    // Each connected MCP server advertises tools with full input schemas.
    // We inject them as `mcp__<server>__<tool>` so the model can call them
    // directly with typed arguments instead of the generic mcp_* proxy.
    for (final entry in McpService.I.connectedTools.entries) {
      final serverKey = entry.key
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
          .replaceAll(RegExp(r'^_|_$'), '');
      for (final t in entry.value) {
        tools.add(t.toOpenAiTool(serverKey));
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
            '• Studio mode → native Linux sandbox (bash, python, node, git '
            'via apt — commands run in the session workspace).\n'
            '• Other modes → phone terminal (Android device shell: ls, cat, '
            'grep, cp, mv, ps, uname, toybox utilities — instant, no '
            'install).\n'
            'If a phone-terminal command reports "not found", tell the user '
            'to switch to Studio mode and install the native sandbox for '
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
        'name': 'fs_edit',
        'description':
            'Precise file editing — view, create, or replace an exact '
            'string in a workspace file.  The read-before-write policy '
            'applies: you must file_read a file before str_replace/insert '
            'on it.  For create, the file must not already exist.\n'
            'Ops: view (show file with line numbers), create (new file), '
            'str_replace (old_str must match EXACTLY once in the file), '
            'insert (insert text after line N).',
        'parameters': {
          'type': 'object',
          'properties': {
            'command': {
              'type': 'string',
              'enum': ['view', 'create', 'str_replace', 'insert'],
            },
            'path': {'type': 'string'},
            'file_text': {
              'type': 'string',
              'description': 'Content for create op',
            },
            'old_str': {
              'type': 'string',
              'description': 'Exact string to replace (str_replace op)',
            },
            'new_str': {
              'type': 'string',
              'description': 'Replacement string (str_replace op)',
            },
            'insert_line': {
              'type': 'integer',
              'description': 'Line number after which to insert (insert op)',
            },
          },
          'required': ['command', 'path'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'fs_glob',
        'description':
            'Find files by glob pattern in the workspace.  '
            '** matches any depth, * matches one segment.  '
            'Example: "**/*.dart", "lib/**/*.yaml", "src/*.js".  '
            'Returns up to 100 matching paths (sorted).',
        'parameters': {
          'type': 'object',
          'properties': {
            'pattern': {'type': 'string'},
            'path': {
              'type': 'string',
              'description':
                  'Directory to search in (default: session workspace root)',
            },
          },
          'required': ['pattern'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'fs_grep',
        'description':
            'Search file contents for a regex pattern in the workspace.  '
            'Returns matching lines with file:line:content format.  '
            'Cap: 50 matches.  Skips binary files.',
        'parameters': {
          'type': 'object',
          'properties': {
            'pattern': {'type': 'string'},
            'path': {
              'type': 'string',
              'description':
                  'Directory or file to search (default: session workspace)',
            },
            'context': {
              'type': 'integer',
              'description': 'Lines of context before/after each match',
            },
          },
          'required': ['pattern'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'todo_write',
        'description':
            'Write the session\'s todo/task list — a checklist the user '
            'sees live above the chat input.  Each call REPLACES the whole '
            'list.  Use it to track multi-step work: mark items '
            'in_progress as you work on them, completed when done.',
        'parameters': {
          'type': 'object',
          'properties': {
            'todos': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'content': {'type': 'string'},
                  'status': {
                    'type': 'string',
                    'enum': ['pending', 'in_progress', 'completed'],
                  },
                },
                'required': ['content', 'status'],
              },
            },
          },
          'required': ['todos'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'ask_user_question',
        'description':
            'Ask the user structured questions with clickable options — '
            'use when you need a decision or missing info before '
            'proceeding.  Each question can have multiple choice options '
            'or be free-form.  Returns a JSON map of {questionId: answer}.',
        'parameters': {
          'type': 'object',
          'properties': {
            'questions': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'id': {'type': 'string'},
                  'question': {'type': 'string'},
                  'header': {'type': 'string'},
                  'options': {
                    'type': 'array',
                    'items': {
                      'type': 'object',
                      'properties': {
                        'label': {'type': 'string'},
                        'description': {'type': 'string'},
                      },
                      'required': ['label'],
                    },
                  },
                  'multi': {
                    'type': 'boolean',
                    'description': 'Allow multiple selections (default false)',
                  },
                },
                'required': ['id', 'question'],
              },
            },
          },
          'required': ['questions'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'exit_plan_mode',
        'description':
            'Present your plan to the user for approval BEFORE executing '
            'it.  Call this when you have thought through a complex task '
            'and have a multi-step plan.  The user sees the plan card and '
            'can approve (you then execute) or give feedback (you revise '
            'the plan).  Present plans as numbered steps.',
        'parameters': {
          'type': 'object',
          'properties': {
            'plan': {
              'type': 'string',
              'description':
                  'Your plan as numbered steps (e.g. "1. Read the file\\n'
                  '2. Fix the bug\\n3. Test the fix")',
            },
          },
          'required': ['plan'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'create_goal',
        'description':
            'Create one persistent goal when the user\'s request is a '
            'long-running objective that should continue across multiple '
            'autonomous rounds (e.g. "build and test this whole feature"). '
            'While a goal is ACTIVE, each new user message (or "continue") '
            'starts a new round toward it; update_goal records progress. '
            'Do NOT create goals for trivial single-turn work.',
        'parameters': {
          'type': 'object',
          'properties': {
            'objective': {
              'type': 'string',
              'description': 'The immutable objective statement',
            },
          },
          'required': ['objective'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'get_goal',
        'description':
            'Read the current session goal: objective, status, round, '
            'and the progress log.',
        'parameters': {'type': 'object', 'properties': {}},
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'update_goal',
        'description':
            'Update the session goal.  status: "active" (keep working), '
            '"complete" (objective done — say so to the user), or '
            '"blocked" (cannot proceed — explain what you need).  Append '
            'a short progress note each round.',
        'parameters': {
          'type': 'object',
          'properties': {
            'status': {
              'type': 'string',
              'enum': ['active', 'complete', 'blocked'],
            },
            'progress': {
              'type': 'string',
              'description': 'Short note about this round\'s progress',
            },
          },
          'required': ['status'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'schedule_create',
        'description':
            'Create a reminder in this session.  Supply a prompt and '
            'exactly one selector: after_seconds (delay), at (local '
            'date-time "YYYY-MM-DD HH:MM"), or every_seconds (repeating, '
            'min 300).  Delivery is session-local: fires only while this '
            'chat is open; missed reminders run when you return.',
        'parameters': {
          'type': 'object',
          'properties': {
            'prompt': {
              'type': 'string',
              'description': 'What to do when the reminder fires',
            },
            'after_seconds': {'type': 'integer'},
            'at': {'type': 'string', 'description': '"YYYY-MM-DD HH:MM"'},
            'every_seconds': {'type': 'integer'},
          },
          'required': ['prompt'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'schedule_list',
        'description': 'List this session\'s active reminders.',
        'parameters': {'type': 'object', 'properties': {}},
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'schedule_delete',
        'description':
            'Delete one reminder by the exact id from schedule_create/'
            'schedule_list.',
        'parameters': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
          },
          'required': ['id'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'job_start',
        'description':
            'Start a background shell job (long-running command).  Use for '
            'dev servers, watchers, installs — anything that keeps running '
            'or takes a while.  Returns a job id immediately.  Use '
            'job_output to poll its output and job_kill to stop it.',
        'parameters': {
          'type': 'object',
          'properties': {
            'command': {'type': 'string'},
            'name': {
              'type': 'string',
              'description': 'Short label for the job (e.g. "dev-server")',
            },
          },
          'required': ['command'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'job_list',
        'description':
            'List all background jobs with their status (running/finished/'
            'failed) and last few output lines.',
        'parameters': {'type': 'object', 'properties': {}},
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'job_output',
        'description':
            'Read the latest output of a background job.  Returns the last '
            'N lines (default 30).',
        'parameters': {
          'type': 'object',
          'properties': {
            'id': {'type': 'integer'},
            'lines': {
              'type': 'integer',
              'description': 'Number of trailing lines to return (default 30)',
            },
          },
          'required': ['id'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'job_kill',
        'description': 'Stop a running background job by id.',
        'parameters': {
          'type': 'object',
          'properties': {
            'id': {'type': 'integer'},
          },
          'required': ['id'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'session_search',
        'description':
            'Search past and current session events — tool calls, shell '
            'commands, file edits, mode changes, approvals, errors.  Use '
            'this to recall what happened earlier (e.g. "what commands '
            'have I run?", "which files were edited?").',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {'type': 'string'},
            'limit': {
              'type': 'integer',
              'description': 'Max results (default 20)',
            },
          },
          'required': ['query'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'dispatch_agent',
        'description':
            'Launch a subagent — a fresh AI agent instance with its own '
            'context window and tool access.  Use for complex subtasks '
            'that need focused exploration (e.g. "search the codebase '
            'for all API endpoints and summarize their auth patterns"). '
            'The subagent runs to completion and returns its final '
            'answer.  The subagent does NOT see this chat\'s history — '
            'pass everything it needs in the prompt.',
        'parameters': {
          'type': 'object',
          'properties': {
            'prompt': {
              'type': 'string',
              'description': 'Detailed task description for the subagent',
            },
            'mode': {
              'type': 'string',
              'description': 'Agent mode: "studio" (full sandbox) or '
                  '"quick" (phone terminal). Default: current mode.',
              'enum': ['studio', 'quick'],
            },
          },
          'required': ['prompt'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'memory_save',
        'description':
            'Save a durable memory snippet (a fact, preference, or '
            'context) that persists across sessions.  Use for user '
            'preferences, project facts, or important decisions.  '
            'Search memories with memory_search.',
        'parameters': {
          'type': 'object',
          'properties': {
            'content': {
              'type': 'string',
              'description': 'The memory to store (a concise fact)',
            },
          },
          'required': ['content'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'memory_search',
        'description':
            'Search saved memories (user preferences, project facts). '
            'Returns matching memories with timestamps.',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {'type': 'string'},
          },
          'required': ['query'],
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
        'name': 'catalog_add_plugin',
        'description':
            'Create a custom plugin definition (name + description + '
            'category). Use when the user wants to add a plugin that is '
            'not in the catalog. The plugin appears in Plugins and '
            'persists across restarts.',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'description': {'type': 'string'},
            'category': {
              'type': 'string',
              'description': 'Agent / Tool / MCP / Runtime / Custom',
            },
          },
          'required': ['name', 'description'],
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

  /// Context compaction — summarize older messages into a dense summary
  /// when history exceeds the threshold.  Uses a non-tool LLM call.
  /// Re-compacts only after 20+ new messages since last compaction.
  Future<void> _maybeCompact(ChatSession s, ProviderConfig p) async {
    // Skip if recently compacted (fewer than 20 new messages).
    if (s.compactedSummary != null &&
        s.messages.length - s.compactedAtCount < 20) {
      return;
    }
    _emit('think', 'compacting conversation context…');
    // Take messages from last compaction point to current - 15 (keep
    // recent 15 verbatim for continuity).
    final cutoff = s.messages.length > 15 ? s.messages.length - 15 : 0;
    final toSummarize = s.messages
        .sublist(s.compactedAtCount, cutoff)
        .map((m) =>
            '${m.role == 'user' ? 'User' : 'Assistant'}: ${cleanTruncate(m.content, 400)}')
        .join('\n');
    if (toSummarize.isEmpty) return;
    try {
      final summary = await _callLlm(
        p,
        [
          {
            'role': 'system',
            'content':
                'You are a conversation summarizer. Compress the following '
                    'conversation into a dense summary (max 500 words). '
                    'Preserve: all facts, decisions made, file paths '
                    'mentioned, code snippets, pending tasks, user '
                    'preferences. Write in the same language as the '
                    'conversation.'
          },
          {
            'role': 'user',
            'content':
                '${s.compactedSummary != null ? '[Previous summary]\n${s.compactedSummary}\n\n' : ''}'
                    '[New messages to incorporate]\n$toSummarize',
          },
        ],
        s,
        includeTools: false,
      );
      if (summary != null && summary['content'] != null) {
        s.compactedSummary = summary['content'] as String;
        s.compactedAtCount = cutoff;
        AppState.I.persistSessions();
        _emit('think', 'context compacted ✓ '
            '(${s.messages.length} msgs → summary)');
      }
    } catch (e) {
      // Compaction failure is non-fatal — continue with full history.
      _emit('think', 'compaction skipped: $e');
    }
  }

  /// Compact subagent loop (no UI events, no session message storage,
  /// no approval prompts).  Runs the model with tool calls and returns
  /// the final assistant text.  Used by dispatch_agent.
  Future<String> runSubagent(String prompt) async {
    final p = _provider;
    if (p == null) {
      final sel = AppState.I.providerForSession(AppState.I.activeSession);
      if (sel == null) return 'No provider configured for subagent.';
      return await _runSubagentLoop(sel, prompt);
    }
    return await _runSubagentLoop(p, prompt);
  }

  Future<String> _runSubagentLoop(ProviderConfig p, String prompt) async {
    final session = AppState.I.activeSession;
    if (session == null) return 'No active session for subagent.';
    final sys =
        'You are a focused subagent. Do the task and give a final answer. '
        'You have the same tools as the parent agent. Be concise. Match '
        'the task language. Do not call exit_plan_mode (subagents execute).';
    final msgs = <Map<String, dynamic>>[
      {'role': 'system', 'content': sys},
      {'role': 'user', 'content': prompt},
    ];
    for (var turn = 0; turn < 8; turn++) {
      final msg = await _callLlm(p, msgs, session);
      if (msg == null) {
        return 'Subagent model error: ${lastError ?? "unknown"}';
      }
      final toolCalls = msg['tool_calls'] as List?;
      if (toolCalls == null || toolCalls.isEmpty) {
        return (msg['content'] as String?) ?? '(no answer)';
      }
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
        // Subagents auto-approve all tools (no UI).
        final result = await _dispatchSubagent(name, args);
        msgs.add({
          'role': 'tool',
          'tool_call_id': tc['id'] ?? name,
          'name': name,
          'content': result,
        });
      }
    }
    return 'Subagent reached turn limit without final answer.';
  }

  /// Subagent dispatch — auto-approves (no user UI for child agents).
  /// Child INHERITS parent's planMode so it cannot bypass plan
  /// restrictions via dispatch_agent (read-only tools only while
  /// the parent is planning).
  Future<String> _dispatchSubagent(String name, Map<String, dynamic> args) async {
    final req = pendingApproval;
    final parentPlanMode = planMode;
    pendingApproval = null;
    try {
      return await _dispatch(name, args);
    } finally {
      pendingApproval = req;
      planMode = parentPlanMode;
    }
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
Environment: Android device with a native Linux sandbox (python3/node/git via apt),
a live Browser panel, and the user's connected GitHub repo (${GitHubService.I.login ?? 'github'}).
Access mode: ${mode.label.toUpperCase()} — ${mode.hint}
Session isolation: this chat has its OWN sandbox workspace (id: ${AppState.I.activeSession?.sandboxId ?? 'default'}).
Other chats' files are NOT visible to you — don't ask about them, they're
inaccessible here. ${AppState.I.shareSessionMemory ? 'The user enabled "Share session memory" — you may search across all chats via memory_search.' : ''}

RESPONSE STYLE (default): Be concise and lightweight, like a fast coding assistant.
Lead with the answer or result. Skip long preambles, restating the question, and
filler. Use short bullet points or code blocks only when they help. Reply in
the same language the user writes in (default English). Only give long
explanations, step-by-step
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
• Studio mode → native Linux sandbox (bash/python/node/git via apt) in the
  session workspace.
• Any other mode → instant phone terminal (Android device shell + toybox:
  ls/cat/grep/cp/mv/ps/uname...). No python/gcc/apt here — if a command
  is "not found", suggest switching to Studio mode + one-time native
  sandbox setup (fast, bundled). Provider/plugin/MCP management works the
  same in every tier via the catalog_* tools.
${s.goal != null && s.goal!['status'] == 'active' ? '\nACTIVE GOAL (round ${s.goal!['round']}): "${s.goal!['objective']}". This user message is a goal round — work toward the objective, then update_goal with progress. Do not restate the goal; just advance it.' : ''}
${s.schedules.isNotEmpty ? '\nSESSION REMINDERS (${s.schedules.length}): When a [reminder] message arrives, treat its prompt as a user request and act on it.' : ''}
''';

    // ── Context compaction (DSH compaction package equivalent) ──
    // If history is long, summarize older messages into a dense context
    // block so the model sees less tokens but keeps all facts.
    if (s.messages.length > 30) {
      await _maybeCompact(s, p);
    }

    final historyStart = s.messages.length > 12 ? s.messages.length - 12 : 0;
    final msgs = <Map<String, dynamic>>[
      {'role': 'system', 'content': sys},
      // Compacted summary as system-level context (DSH injection style).
      if (s.compactedSummary != null && s.compactedSummary!.isNotEmpty)
        {
          'role': 'system',
          'content':
              '[Earlier conversation summary — treat as established context]\n'
                  '${s.compactedSummary}',
        },
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
            'If the model/provider is already configured, increase "AI response timeout" in Settings, or try again.',
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
          // DSH ToolRow parity: live tool card in the chat stream.
          final toolMsg = _silentTools.contains(name)
              ? null
              : _toolStart(name, _toolArgSummary(name, args));
          String result;
          try {
            result = await _dispatch(name, args);
            if (toolMsg != null) {
              _toolFinish(
                state: result.startsWith('DENIED')
                    ? 'stopped'
                    : _looksLikeToolError(result)
                        ? 'error'
                        : 'ok',
                detail: toolMsg.toolDetail ?? cleanTruncate(result, 8000),
              );
            }
          } catch (e) {
            result = 'tool error: $e';
            if (toolMsg != null) _toolFinish(state: 'error', detail: result);
          }
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
      }      final key = p.cleanApiKey;
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
              'Increase "AI response timeout" or check the provider';
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
          // VISIBLE warning (was invisible before — users had no idea why
          // plugins/MCP/catalog tools "weren't working").
          _appendAssistant(
            '⚠️ This provider/model does not support tool calling — '
            'terminal, plugins, MCP, and catalog tools are unavailable '
            'for this reply. Switch to a tool-capable model '
            '(e.g. DeepSeek, GPT-4o, Claude, Gemini) to use them.',
            session: session,
          );
          return _callLlm(p, msgs, session, includeTools: false);
        }
        final hint = switch (res.statusCode) {
          401 || 403 => 'API key invalid or expired — re-enter the key in Settings → ${p.name}.',
          404 => 'Model "$modelId" not found on this endpoint — pick it again from the model picker.',
          429 => 'Rate limited — wait a moment and retry.',
          >= 500 => 'Provider server issue (${p.name}) — retry in a moment.',
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
        // Per-chunk cancel check — stop button kills the stream mid-flight,
        // not just between turns.  Keeps whatever streamed so far.
        if (_cancelRequested) {
          break;
        }

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
  // Buffers live on the per-session _AgentRun so parallel sessions keep
  // independent streaming bubbles.
  StringBuffer get _liveContent => _run.liveContent;
  StringBuffer get _liveReasoning => _run.liveReasoning;
  ChatSession? get _liveSession => _run.liveSession;
  set _liveSession(ChatSession? v) => _run.liveSession = v;
  Message? get _liveMsg => _run.liveMsg;
  set _liveMsg(Message? v) => _run.liveMsg = v;

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
    // ── Plan mode enforcement (DSH exit_plan_mode flow) ──
    // While planning, only read-only tools are allowed.  The AI must
    // present its plan via exit_plan_mode and get user approval first.
    if (planMode && _isMutatingTool(name)) {
      return 'PLAN MODE ACTIVE: "$name" is a mutating tool. Use read-only '
          '(read/list/search/browse) tools to explore, finalize your plan, '
          'and call exit_plan_mode for user approval. After approval, '
          'execution tools unlock.';
    }
    switch (name) {
      case 'run_shell':
        final cmd = args['command'] as String;
        final ok = await _maybeApprove(
          'run_shell',
          cmd,
          'Command will run in ${mode == AgentMode.studio ? "the native sandbox" : "the phone terminal (device shell)"}:\n\$ $cmd',
        );
        if (!ok) return 'DENIED by user';
        _emit('shell', cmd);
        try {
          final work = await _sessionWorkDir();
          if (mode == AgentMode.studio) {
            // Studio tier — native bionic sandbox (bash/python/node/apt).
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
              ? '\n\n[phone terminal: only Android toybox commands here — '
                  'use Studio mode + the native sandbox for python/node/apt]'
              : '';
          return (out.isEmpty ? '(no output)' : out) + hint;
        } catch (e) {
          // Friendly actionable message — the model relays this to the user.
          if ('$e'.contains('not installed')) {
            return mode == AgentMode.studio
                ? 'sandbox not installed yet. Tell the user: "Open Studio and install the sandbox (one-time, ~320 MB), then the command will work."'
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
              '• Reason: ${reason.isEmpty ? '(no reason given)' : reason}\n\n'
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
      case 'dispatch_agent':
        return await _handleDispatchAgent(args);

      case 'memory_save':
        final content = args['content'] as String;
        final item = MemoryItem(
          id: 'mem-${DateTime.now().millisecondsSinceEpoch}',
          content: content,
        );
        await AppState.I.saveMemory(item);
        _emit('think', 'memory saved');
        return 'Memory saved ✓ — "${cleanTruncate(content, 120)}"';

      case 'memory_search':
        final q2 = (args['query'] as String).toLowerCase();
        _emit('think', 'searching memory: $q2');
        final app = AppState.I;
        final share = app.shareSessionMemory;
        final current = app.activeSession;
        if (current == null) return 'no active session';
        final hits = <String>[];
        // Durable saved memories first (memory_save items).
        for (final mem in app.memories.take(50)) {
          if (mem.content.toLowerCase().contains(q2)) {
            hits.add('[memory] ${cleanTruncate(mem.content, 120)}');
            if (hits.length >= 8) break;
          }
        }
        // Then session messages.
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
              ? 'No matches for "$q2" across memories + all sessions.'
              : 'No matches for "$q2" in memories + this session. (Enable "Share session memory" in Settings to search across chats.)';
        }
        return hits.join('\n');
      case String() when name.startsWith('mcp__'):
        // Real discovered MCP tool call: mcp__<server>__<tool>.
        // The tool schema came from tools/list (McpService.connectedTools).
        final parts = name.split('__');
        if (parts.length < 3) {
          return 'Malformed MCP tool name "$name" (expected mcp__<server>__<tool>).';
        }
        final serverKey = parts[1];
        final toolName = parts.sublist(2).join('__');
        // Resolve the server by fuzzy-matching the sanitized key against
        // configured server names (same normalization as _tools).
        String? norm(String s) => s
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
            .replaceAll(RegExp(r'^_|_$'), '');
        final match = AppState.I.mcpServers
            .where((s) => norm(s.name) == serverKey)
            .firstOrNull;
        if (match == null) {
          return 'No MCP server matches key "$serverKey". '
              'Connected tools come from a configured server — check Plugins → MCP.';
        }
        if (!McpService.I.isConnected(match.name)) {
          final res = await McpService.I.connect(match);
          if (!res.contains('connected')) return res;
        }
        _emit('shell', 'MCP: ${match.name} → $toolName');
        return await McpService.I.callTool(match.name, toolName, args);
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
          app.persistPluginState();
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
          // REAL connect — spawns the process, runs the MCP handshake,
          // discovers tools.  (Previously this only flipped a bool, so
          // the UI said "connected" but nothing actually ran.)
          final res = await McpService.I.connect(match);
          match.connected = McpService.I.isConnected(match.name);
          app.refresh();
          _emit('done', res);
          return res;
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

      case 'catalog_add_plugin':
        final name = args['name'] as String;
        final desc = args['description'] as String;
        final category = args['category'] as String? ?? 'Custom';
        _emit('think', 'creating plugin: $name');
        AppState.I.addCustomPlugin(
          name: name,
          description: desc,
          category: category,
        );
        _emit('done', 'plugin created: $name');
        return 'Plugin "$name" created and enabled ✓ — visible in Plugins, '
            'persists across restarts.';

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
        if (sessionRepoFull == null) return 'no repo connected';
        _emit('think', 'syncing repo $sessionRepoFull …');
        try {
          // bind cache
          RepoCache.I.bind(sessionRepoFull!, GitHubService.I.token!);
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
        final sid = AppState.I.activeSession?.sandboxId ??
            AppState.I.activeSession?.id ??
            'default';
        _readPathsFor(sid).add(path);
        openStudioFile(path, c);
        _emit('file', 'read $path');
        return cleanTruncate(c, 6000);

      case 'fs_edit':
        return await _handleFsEdit(args);

      case 'fs_glob':
        return await _handleFsGlob(args);

      case 'fs_grep':
        return await _handleFsGrep(args);

      case 'todo_write':
        return await _handleTodoWrite(args);

      case 'ask_user_question':
        return await _handleAskUserQuestion(args);

      case 'exit_plan_mode':
        return await _handleExitPlanMode(args);

      case 'create_goal':
        return _handleCreateGoal(args);

      case 'get_goal':
        return _handleGetGoal();

      case 'update_goal':
        return _handleUpdateGoal(args);

      case 'schedule_create':
        return _handleScheduleCreate(args);

      case 'schedule_list':
        return _handleScheduleList();

      case 'schedule_delete':
        return _handleScheduleDelete(args);

      case 'job_start':
        return await _handleJobStart(args);

      case 'job_list':
        return _handleJobList();

      case 'job_output':
        return _handleJobOutput(args);

      case 'job_kill':
        return _handleJobKill(args);

      case 'session_search':
        return _handleSessionSearch(args);

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

  /// One-line arg summary for the collapsed tool row (command / path /
  /// prompt — whatever best identifies the call).
  String _toolArgSummary(String name, Map<String, dynamic> args) {
    final pick = switch (name) {
      'run_shell' || 'job_start' => args['command'],
      'run_code' => args['code'] ?? args['program'],
      'fetch_url' || 'browser_open' || 'browser_navigate' => args['url'],
      'web_search' || 'memory_search' || 'session_search' => args['query'],
      'dispatch_agent' => args['prompt'],
      'commit' => args['message'],
      'generate_image' => args['prompt'],
      'browser_evaluate' => args['script'] ?? args['expression'],
      'browser_click' => args['selector'],
      'create_goal' => args['objective'],
      'schedule_create' => args['prompt'],
      'memory_save' => args['content'],
      _ => args['path'] ?? args['pattern'] ?? args['file'],
    };
    return (pick as String?) ?? '';
  }

  /// Heuristic: tool result text that reads as a failure → error state dot.
  bool _looksLikeToolError(String result) {
    final l = result.toLowerCase();
    return l.startsWith('error') ||
        l.startsWith('tool error') ||
        l.contains('not found') ||
        l.contains('permission denied') ||
        l.contains('failed:') ||
        l.contains('exception:');
  }

  // ── Tool-call chat cards (DSH ToolRow parity) ──────────────────────────
  // Every _dispatch call creates a live tool message in the chat stream:
  // it starts as state 'running' (sweep animation) and settles to
  // ok/error/stopped with the final output in toolDetail.  The UI renders
  // it as a 24px collapsed row (icon + title · summary) that expands to a
  // Terminal/Diff/Read block.


  /// Tool rows that should NOT create a chat card (UI-interactive tools
  /// have their own surfaces — approval dock, questions card, todo dock).
  static const _silentTools = {
    'ask_user_question', 'todo_write', 'exit_plan_mode', 'request_permission',
  };

  /// Row presentation per tool — icon + how to title it.
  static String toolIcon(String toolName) {
    if (toolName.startsWith('browser_')) return 'web';
    if (toolName.startsWith('fs_') || toolName.startsWith('file_')) {
      return toolName.contains('edit') || toolName.contains('write')
          ? 'edit'
          : 'read';
    }
    return switch (toolName) {
      'run_shell' => 'terminal',
      'run_code' => 'code',
      'job_start' || 'job_kill' || 'job_list' || 'job_output' => 'terminal',
      'web_search' || 'fs_grep' || 'fs_glob' || 'session_search' ||
      'memory_search' => 'search',
      'fetch_url' => 'web',
      'generate_image' => 'sparkle',
      'dispatch_agent' => 'agent',
      'commit' || 'repo_sync' || 'repo_tree' => 'git',
      'create_goal' || 'update_goal' || 'get_goal' => 'goal',
      'schedule_create' || 'schedule_list' || 'schedule_delete' => 'schedule',
      'memory_save' => 'memory',
      'read_attachment' || 'preview' => 'read',
      _ => 'api',
    };
  }

  /// Human title for the collapsed row.
  static String toolTitleFor(String toolName) => switch (toolName) {
        'run_shell' => 'bash',
        'run_code' => 'Run code',
        'file_read' => 'Read',
        'file_write' => 'Write',
        'fs_edit' => 'Edit',
        'fs_glob' => 'Glob',
        'fs_grep' => 'Grep',
        'web_search' => 'Search',
        'fetch_url' => 'Fetch',
        'session_search' => 'Search session',
        'memory_search' => 'Search memory',
        'memory_save' => 'Save memory',
        'dispatch_agent' => 'Subagent',
        'commit' => 'Commit',
        'repo_sync' => 'Sync repo',
        'repo_tree' => 'Repo tree',
        'job_start' => 'Start job',
        'job_output' => 'Job output',
        'job_list' => 'Jobs',
        'job_kill' => 'Kill job',
        'create_goal' => 'Create goal',
        'update_goal' => 'Update goal',
        'get_goal' => 'Goal',
        'schedule_create' => 'Create reminder',
        'schedule_list' => 'Reminders',
        'schedule_delete' => 'Delete reminder',
        'generate_image' => 'Generate image',
        'read_attachment' => 'Read attachment',
        'preview' => 'Preview',
        _ => toolName.startsWith('mcp_')
            ? toolName.replaceAll('mcp_', '').replaceAll('_', ' ')
            : toolName.replaceAll('_', ' '),
      };

  Message _toolStart(String toolName, String summary) {
    final s = AppState.I.activeSession;
    if (s == null) return Message(role: 'assistant', kind: MsgKind.tool);
    final m = Message(
      role: 'assistant',
      kind: MsgKind.tool,
      toolName: toolName,
      toolTitle: toolTitleFor(toolName),
      toolSummary: cleanTruncate(summary.replaceAll('\n', ' '), 140),
      toolState: 'running',
    );
    s.messages.add(m);
    _activeToolMsg = m;
    AppState.I.refresh();
    return m;
  }

  void _toolStream(String chunk) {
    final m = _activeToolMsg;
    if (m == null) return;
    m.toolDetail = '${m.toolDetail ?? ''}$chunk';
    if ((m.toolDetail?.length ?? 0) > 12000) {
      m.toolDetail = '…(earlier output trimmed)…\n'
          '${m.toolDetail!.substring(m.toolDetail!.length - 10000)}';
    }
    // Keep the collapsed-row summary current with the latest output line.
    final lastLine = m.toolDetail!.trim().split('\n').lastOrNull;
    if (lastLine != null && lastLine.isNotEmpty) {
      m.toolSummary = cleanTruncate(lastLine, 140);
    }
    AppState.I.refresh();
  }

  void _toolFinish({String state = 'ok', String? detail, String? summary}) {
    final m = _activeToolMsg;
    _activeToolMsg = null;
    if (m == null) return;
    if (detail != null && m.toolDetail == null) m.toolDetail = detail;
    if (summary != null) m.toolSummary = cleanTruncate(summary.replaceAll('\n', ' '), 140);
    m.toolState = state;
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

  // ── WAVE 1 HANDLERS — fs tools, todo, ask_user_question ─────────────

  /// Resolve a workspace-relative path.  Repo files take precedence; falls
  /// back to the session's sandbox workdir on the host filesystem.
  Future<String?> _resolveFsPath(String rel) async {
    // Repo cache hit?
    if (RepoCache.I.files.containsKey(rel)) return 'repo:$rel';
    // Host filesystem under session workdir.
    final work = await _sessionWorkDir();
    final f = File('${work.path}/$rel');
    if (f.existsSync()) return f.path;
    return null;
  }

  Future<String> _handleFsEdit(Map<String, dynamic> args) async {
    final cmd = args['command'] as String;
    final path = args['path'] as String;
    final sid = AppState.I.activeSession?.sandboxId ??
        AppState.I.activeSession?.id ??
        'default';

    switch (cmd) {
      case 'view':
        // Repo file?
        final repoContent = RepoCache.I.read(path);
        if (repoContent != null) {
          _readPathsFor(sid).add(path);
          _emit('file', 'view $path');
          return _numberedLines(repoContent, 6000);
        }
        // Host file?
        final host = await _resolveFsPath(path);
        if (host == null) return 'file not found: $path';
        final content = await File(host).readAsString();
        _readPathsFor(sid).add(path);
        _emit('file', 'view $path');
        return _numberedLines(content, 6000);

      case 'create':
        final content = args['file_text'] as String? ?? '';
        if (RepoCache.I.files.containsKey(path)) {
          return 'file already exists: $path — use str_replace to edit it';
        }
        final work = await _sessionWorkDir();
        final f = File('${work.path}/$path');
        if (f.existsSync()) {
          return 'file already exists: $path — use str_replace to edit it';
        }
        final ok = await _maybeApprove(
          'fs_edit create',
          path,
          'CREATE FILE:\n$path\n${content.length} chars',
        );
        if (!ok) return 'DENIED by user';
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(content);
        _readPathsFor(sid).add(path);
        _emit('file', 'created $path');
        return 'created $path ✓ · ${content.length} chars';

      case 'str_replace':
        final oldStr = args['old_str'] as String? ?? '';
        final newStr = args['new_str'] as String? ?? '';
        if (oldStr.isEmpty) return 'old_str must not be empty';
        // Read-before-write gate.
        if (!_readPathsFor(sid).contains(path)) {
          return 'read-before-write: file_read ya fs_edit view se pehle '
              '"$path" read it first, then edit.';
        }
        // Repo file?
        final repoContent = RepoCache.I.read(path);
        if (repoContent != null) {
          final count = _countOccurrences(repoContent, oldStr);
          if (count == 0) return 'old_str not found in $path';
          if (count > 1) {
            return 'old_str matches $count times in $path — make it more '
                'unique (add surrounding context).';
          }
          final updated = repoContent.replaceFirst(oldStr, newStr);
          final ok = await _maybeApprove(
            'fs_edit str_replace',
            path,
            'EDIT $path:\nold: ${oldStr.length} chars → new: ${newStr.length} chars',
          );
          if (!ok) return 'DENIED by user';
          RepoCache.I.write(path, updated);
          openStudioFile(path, updated);
          _emit('file', 'edited $path');
          return 'edited $path ✓ (str_replace)';
        }
        // Host file?
        final host = await _resolveFsPath(path);
        if (host == null) return 'file not found: $path';
        final content = await File(host).readAsString();
        final count = _countOccurrences(content, oldStr);
        if (count == 0) return 'old_str not found in $path';
        if (count > 1) {
          return 'old_str matches $count times in $path — make it more '
              'unique (add surrounding context).';
        }
        final ok = await _maybeApprove(
          'fs_edit str_replace',
          path,
          'EDIT $path:\nold: ${oldStr.length} chars → new: ${newStr.length} chars',
        );
        if (!ok) return 'DENIED by user';
        File(host).writeAsStringSync(content.replaceFirst(oldStr, newStr));
        _emit('file', 'edited $path');
        return 'edited $path ✓ (str_replace)';

      case 'insert':
        final insertLine = args['insert_line'] as int? ?? 0;
        final newStr = args['new_str'] as String? ?? '';
        if (newStr.isEmpty) return 'new_str must not be empty';
        if (!_readPathsFor(sid).contains(path)) {
          return 'read-before-write: file_read ya fs_edit view se pehle '
              '"$path" read it first, then edit.';
        }
        final repoContent = RepoCache.I.read(path);
        final host = await _resolveFsPath(path);
        final raw = repoContent ??
            (host != null ? await File(host).readAsString() : null);
        if (raw == null) return 'file not found: $path';
        final lines = raw.split('\n');
        if (insertLine < 0 || insertLine > lines.length) {
          return 'insert_line $insertLine out of range (0..${lines.length})';
        }
        lines.insert(insertLine, newStr);
        final updated = lines.join('\n');
        final ok = await _maybeApprove(
          'fs_edit insert',
          path,
          'INSERT at line $insertLine in $path:\n$newStr',
        );
        if (!ok) return 'DENIED by user';
        if (repoContent != null) {
          RepoCache.I.write(path, updated);
          openStudioFile(path, updated);
        } else if (host != null) {
          File(host).writeAsStringSync(updated);
        }
        _emit('file', 'edited $path');
        return 'inserted at line $insertLine in $path ✓';

      default:
        return 'unknown fs_edit command: $cmd';
    }
  }

  String _numberedLines(String content, int max) {
    final lines = content.split('\n');
    final buf = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      buf.writeln('${(i + 1).toString().padLeft(4)}: ${lines[i]}');
      if (buf.length > max) {
        buf.writeln('… (${lines.length - i - 1} more lines)');
        break;
      }
    }
    return buf.toString();
  }

  int _countOccurrences(String text, String sub) {
    var count = 0;
    var start = 0;
    while (true) {
      final idx = text.indexOf(sub, start);
      if (idx < 0) break;
      count++;
      start = idx + 1;
    }
    return count;
  }

  /// Convert a glob pattern to a RegExp.  ** matches any depth,
  /// * matches one path segment, ? matches one character.
  RegExp _globToRegExp(String pattern) {
    final buf = StringBuffer('^');
    var i = 0;
    while (i < pattern.length) {
      final c = pattern[i];
      if (c == '*') {
        if (i + 1 < pattern.length && pattern[i + 1] == '*') {
          buf.write('.*');
          i += 2;
        } else {
          buf.write('[^/]*');
          i++;
        }
      } else if (c == '?') {
        buf.write('.');
        i++;
      } else if (c == '.') {
        buf.write(r'\.');
        i++;
      } else {
        buf.write(RegExp.escape(c));
        i++;
      }
    }
    buf.write('\$');
    return RegExp(buf.toString(), caseSensitive: false);
  }

  Future<String> _handleFsGlob(Map<String, dynamic> args) async {
    final pattern = args['pattern'] as String;
    final basePath = args['path'] as String?;
    final re = _globToRegExp(pattern);
    final results = <String>[];

    // Search repo cache (fast, in-memory).
    if (basePath == null || basePath.isEmpty || basePath == '.') {
      for (final p in RepoCache.I.treePaths) {
        if (re.hasMatch(p)) results.add(p);
        if (results.length >= 100) break;
      }
    }
    // Search host filesystem under session workdir.
    final work = await _sessionWorkDir();
    final searchRoot = basePath != null && basePath.isNotEmpty
        ? Directory('${work.path}/$basePath')
        : work;
    if (searchRoot.existsSync()) {
      await for (final entity in searchRoot.list(recursive: true)) {
        if (entity is File) {
          final rel = entity.path.substring(work.path.length + 1);
          if (re.hasMatch(rel) && !results.contains(rel)) {
            results.add(rel);
            if (results.length >= 100) break;
          }
        }
      }
    }
    if (results.isEmpty) return 'no files matching "$pattern"';
    results.sort();
    return 'glob "$pattern" → ${results.length} match${results.length > 1 ? 'es' : ''}:\n'
        '${results.take(100).join('\n')}';
  }

  Future<String> _handleFsGrep(Map<String, dynamic> args) async {
    final pattern = args['pattern'] as String;
    final basePath = args['path'] as String?;
    final ctxLines = (args['context'] as num?)?.toInt() ?? 0;
    final re = RegExp(pattern, caseSensitive: false);
    final results = <String>[];
    const maxResults = 50;

    // Search repo cache.
    if (basePath == null || basePath.isEmpty || basePath == '.') {
      for (final entry in RepoCache.I.files.entries) {
        if (results.length >= maxResults) break;
        final lines = entry.value.split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (results.length >= maxResults) break;
          if (re.hasMatch(lines[i])) {
            _appendGrepMatch(results, entry.key, lines, i, ctxLines);
          }
        }
      }
    }
    // Search host filesystem.
    final work = await _sessionWorkDir();
    final searchRoot = basePath != null && basePath.isNotEmpty
        ? Directory('${work.path}/$basePath')
        : work;
    if (searchRoot.existsSync() && results.length < maxResults) {
      await for (final entity in searchRoot.list(recursive: true)) {
        if (results.length >= maxResults) break;
        if (entity is! File) continue;
        // Skip binary files (heuristic: no valid UTF-8 decode).
        String content;
        try {
          content = await entity.readAsString();
        } catch (_) {
          continue;
        }
        final rel = entity.path.substring(work.path.length + 1);
        final lines = content.split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (results.length >= maxResults) break;
          if (re.hasMatch(lines[i])) {
            _appendGrepMatch(results, rel, lines, i, ctxLines);
          }
        }
      }
    }
    if (results.isEmpty) return 'no matches for "$pattern"';
    return 'grep "$pattern" → ${results.length} match${results.length > 1 ? 'es' : ''}:\n'
        '${results.join('\n')}';
  }

  void _appendGrepMatch(
    List<String> results,
    String file,
    List<String> lines,
    int lineIdx,
    int ctx,
  ) {
    for (var c = (lineIdx - ctx).clamp(0, lines.length - 1);
        c <= (lineIdx + ctx).clamp(0, lines.length - 1);
        c++) {
      results.add('$file:${c + 1}: ${lines[c]}');
    }
  }

  Future<String> _handleTodoWrite(Map<String, dynamic> args) async {
    final rawTodos = args['todos'] as List? ?? [];
    final todos = [
      for (final t in rawTodos)
        if (t is Map<String, dynamic>)
          {
            'content': t['content'] as String? ?? '',
            'status': t['status'] as String? ?? 'pending',
          },
    ];
    final s = AppState.I.activeSession;
    if (s == null) return 'no active session';
    s.todos.clear();
    s.todos.addAll(todos);
    AppState.I.refresh();
    AppState.I.persistSessions();
    final done = todos.where((t) => t['status'] == 'completed').length;
    final inProg = todos.where((t) => t['status'] == 'in_progress').length;
    _emit('think', 'todo: $done done, $inProg in progress, '
        '${todos.length - done - inProg} pending');
    return 'todo list updated: ${todos.length} items '
        '($done completed, $inProg in progress)';
  }

  Future<String> _handleAskUserQuestion(Map<String, dynamic> args) async {
    final rawQs = args['questions'] as List? ?? [];
    if (rawQs.isEmpty) return 'no questions provided';
    final questions = [
      for (final q in rawQs)
        if (q is Map<String, dynamic>)
          UserQuestion(
            id: q['id'] as String? ?? '',
            question: q['question'] as String? ?? '',
            header: q['header'] as String?,
            options: [
              for (final o in (q['options'] as List? ?? []))
                if (o is Map<String, dynamic>)
                  QuestionOption(
                    label: o['label'] as String? ?? '',
                    description: o['description'] as String?,
                  ),
            ],
            multi: q['multi'] as bool? ?? false,
          ),
    ];
    _emit('think', 'asking user ${questions.length} question'
        '${questions.length > 1 ? 's' : ''}…');
    final answers = await _askQuestions(questions);
    if (answers == null) return 'user cancelled the questions';
    final buf = StringBuffer();
    for (final e in answers.entries) {
      buf.writeln('${e.key}: ${e.value}');
    }
    return 'User answered:\n$buf';
  }

  Future<Map<String, String>?> _askQuestions(
      List<UserQuestion> questions) async {
    final req = ApprovalRequest(
      tool: 'ask_user_question',
      summary: 'The AI asked ${questions.length} question(s)',
      detail: questions.map((q) => q.question).join('\n'),
      questions: questions,
    );
    pendingApproval = req;
    notifyListeners();
    final ok = await req.completer.future;
    if (!ok) return null;
    return req.answers;
  }

  // ── WAVE 2 HANDLERS — plan mode, background jobs, session events ────

  /// Tools that modify state — blocked during plan mode.
  static const _mutatingTools = {
    'file_write', 'fs_edit', 'run_shell', 'commit', 'git_clone',
    'git_push', 'request_permission', 'catalog_add_provider',
    'catalog_remove_provider', 'catalog_add_mcp', 'catalog_remove_mcp',
    'catalog_add_plugin',
    'agent_install_plugin', 'agent_install_mcp', 'catalog_add_marketplace',
    'todo_write', 'job_start', 'job_kill',
  };

  bool _isMutatingTool(String name) => _mutatingTools.contains(name);

  Future<String> _handleExitPlanMode(Map<String, dynamic> args) async {
    final plan = args['plan'] as String? ?? '';
    _emit('think', 'presenting plan for approval…');
    final ok = await _askUser(
      'exit_plan_mode',
      'Approve this plan?',
      'The AI\'s plan:\n\n$plan\n\nApproving runs the plan; declining asks the AI to revise it.',
    );
    if (!ok) {
      planMode = true; // stay in plan mode
      return 'The user rejected the plan. Revise it and call exit_plan_mode again.';
    }
    planMode = false;
    _emit('done', 'plan approved ✓ — executing');
    return 'Plan approved ✓ — now execute it.';
  }

  // ── GOALS (DSH goal-round equivalent) ──
  String _handleCreateGoal(Map<String, dynamic> args) {
    final objective = (args['objective'] as String).trim();
    final s = AppState.I.activeSession;
    if (s == null) return 'No active session.';
    if (s.goal != null && s.goal!['status'] == 'active') {
      return 'A goal is already ACTIVE in this session: '
          '"${s.goal!['objective']}". Complete or block it first '
          '(update_goal).';
    }
    s.goal = {
      'objective': objective,
      'status': 'active',
      'round': 0,
      'progressLog': <String>[],
      'createdAt': DateTime.now().toIso8601String(),
    };
    AppState.I.persistSessions();
    _emit('think', 'goal created: ${cleanTruncate(objective, 60)}');
    notifyListeners();
    return 'Goal created ✓ (round 0). Now work toward it this round; '
        'call update_goal with a progress note. Future "continue" '
        'messages start new rounds.';
  }

  String _handleGetGoal() {
    final s = AppState.I.activeSession;
    final g = s?.goal;
    if (g == null) return 'No goal in this session.';
    final log = (g['progressLog'] as List?)?.join('\n  ') ?? '';
    return 'Goal: "${g['objective']}"\nStatus: ${g['status']} · '
        'Round: ${g['round']}\nProgress log:\n  $log';
  }

  String _handleUpdateGoal(Map<String, dynamic> args) {
    final status = args['status'] as String;
    final progress = args['progress'] as String?;
    final s = AppState.I.activeSession;
    final g = s?.goal;
    if (g == null) return 'No goal in this session.';
    if (!['active', 'complete', 'blocked'].contains(status)) {
      return 'Invalid status "$status" — use active/complete/blocked.';
    }
    if (progress != null && progress.isNotEmpty) {
      (g['progressLog'] as List?)?.add('r${g['round']}: $progress');
      if ((g['progressLog'] as List?)!.length > 50) {
        (g['progressLog'] as List?)!.removeRange(0, 1);
      }
    }
    g['round'] = ((g['round'] as num?)?.toInt() ?? 0) + 1;
    g['status'] = status;
    AppState.I.persistSessions();
    _emit(
        'think', 'goal → $status (round ${g['round']})');
    notifyListeners();
    return status == 'complete'
        ? 'Goal marked complete ✓ (round ${g['round']}).'
        : status == 'blocked'
            ? 'Goal marked blocked (round ${g['round']}). Tell the user '
                'what you need to continue.'
            : 'Goal active, round ${g['round']} recorded. Keep going or '
                'report to the user.';
  }

  // ── SCHEDULES (DSH schedule equivalent) ──
  String _handleScheduleCreate(Map<String, dynamic> args) {
    final prompt = (args['prompt'] as String).trim();
    final s = AppState.I.activeSession;
    if (s == null) return 'No active session.';
    final after = (args['after_seconds'] as num?)?.toInt();
    final at = args['at'] as String?;
    final every = (args['every_seconds'] as num?)?.toInt();
    final selectors = [after, at, every].where((e) => e != null).length;
    if (prompt.isEmpty) return 'prompt is required.';
    if (selectors != 1) {
      return 'Supply exactly ONE of after_seconds, at, every_seconds.';
    }
    if (every != null && every < 300) {
      return 'every_seconds must be ≥ 300.';
    }
    DateTime? fireAt;
    int? repeatSec;
    if (after != null && after > 0) {
      fireAt = DateTime.now().add(Duration(seconds: after));
    } else if (at != null) {
      fireAt = DateTime.tryParse(at.replaceAll(' ', 'T'));
      if (fireAt == null) return 'at must be "YYYY-MM-DD HH:MM".';
      if (fireAt.isBefore(DateTime.now())) {
        // DSH semantics: overdue one-shot fires soon after resume.
        fireAt = DateTime.now().add(const Duration(seconds: 2));
      }
    } else {
      repeatSec = every;
      fireAt = DateTime.now().add(Duration(seconds: every!));
    }
    final id = 'sch-${DateTime.now().millisecondsSinceEpoch}';
    s.schedules.add({
      'id': id,
      'prompt': prompt,
      'fireAt': fireAt.toIso8601String(),
      'every': repeatSec,
    });
    AppState.I.persistSessions();
    _startScheduleTimer();
    _emit('think', 'reminder set: ${cleanTruncate(prompt, 50)}');
    notifyListeners();
    return 'Reminder $id created ✓ — fires '
        '${repeatSec != null ? 'every ${repeatSec}s' : fireAt.toLocal().toString()}';
  }

  String _handleScheduleList() {
    final s = AppState.I.activeSession;
    if (s == null || s.schedules.isEmpty) {
      return 'No reminders in this session.';
    }
    return s.schedules
        .map((r) => '${r['id']} — '
            '${r['every'] != null ? 'every ${r['every']}s' : DateTime.parse(r['fireAt'] as String).toLocal()}'
            ' — ${r['prompt']}')
        .join('\n');
  }

  String _handleScheduleDelete(Map<String, dynamic> args) {
    final id = args['id'] as String;
    final s = AppState.I.activeSession;
    if (s == null) return 'No active session.';
    final before = s.schedules.length;
    s.schedules.removeWhere((r) => r['id'] == id);
    AppState.I.persistSessions();
    if (s.schedules.length == before) {
      return 'Reminder $id not found (already finished?).';
    }
    notifyListeners();
    return 'Reminder $id deleted ✓';
  }

  // Fires due reminders into the chat as [schedule] user messages while
  // the session is live (DSH session-local delivery).
  Timer? _scheduleTimer;

  void _startScheduleTimer() {
    _scheduleTimer?.cancel();
    _scheduleTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _fireDueSchedules();
    });
  }

  void _fireDueSchedules() {
    final s = AppState.I.activeSession;
    if (s == null || s.schedules.isEmpty) return;
    final now = DateTime.now();
    for (final r in List.of(s.schedules)) {
      final fireAt = DateTime.tryParse(r['fireAt'] as String? ?? '');
      if (fireAt == null || fireAt.isAfter(now)) continue;
      final prompt = r['prompt'] as String;
      final id = r['id'] as String;
      final every = r['every'] as num?;
      if (every != null) {
        // Fixed-rate: creation-aligned, skip missed occurrences.
        r['fireAt'] = DateTime.now()
            .add(Duration(seconds: every.toInt()))
            .toIso8601String();
      } else {
        s.schedules.removeWhere((x) => x['id'] == id);
      }
      AppState.I.persistSessions();
      _emit('think', 'reminder $id fired');
      // Session-local delivery: only inject if this session is active.
      if (activeRunId == null) {
        AppState.I.sendMessage('⏰ [reminder $id] $prompt');
      } else {
        // Busy — queue joins the current run (DSH queue behavior).
        enqueueMessage('⏰ [reminder $id] $prompt');
      }
    }
  }

  // ── Subagent (DSH dispatch_agent equivalent) ──
  // A fresh AgentService child instance with its own context window runs
  // the task to completion and returns its final answer as the tool
  // result.  The child never touches the parent chat's session.
  int _subagentDepth = 0;
  static const _maxSubagentDepth = 2;

  Future<String> _handleDispatchAgent(Map<String, dynamic> args) async {
    final prompt = args['prompt'] as String;
    final modeName = args['mode'] as String?;
    _emit('think', 'dispatching subagent…');
    if (_subagentDepth >= _maxSubagentDepth) {
      return 'Subagent depth limit ($_maxSubagentDepth) reached — '
          'do the task yourself with the tools you have.';
    }
    final parentMode = mode;
    final child = AgentService._internal();
    child._subagentDepth = _subagentDepth + 1;
    // Child inherits planMode → mutating tools stay blocked while the
    // parent agent is planning (no plan-mode escape via subagent).
    child.planMode = planMode;
    if (modeName != null) {
      for (final m in AgentMode.values) {
        if (m.name == modeName) child.mode = m;
      }
    }
    // Pipe the child's internal events into the parent's live subagent
    // tool card so the user sees what the subagent is doing.
    child.addListener(() {
      if (_activeToolMsg != null && child.events.isNotEmpty) {
        final e = child.events.last;
        _toolStream('${e.kind}: ${e.text}\n');
      }
    });
    child._emit('think', 'subagent task: ${cleanTruncate(prompt, 80)}');
    try {
      final answer = await child.runSubagent(prompt);
      _emit('think', 'subagent finished (${answer.length} chars)');
      return answer;
    } catch (e) {
      return 'Subagent failed: $e';
    } finally {
      child.dispose();
      mode = parentMode;
    }
  }

  // ── Background jobs (DSH ctx.jobs equivalent) — state lives on _run ──

  Future<String> _handleJobStart(Map<String, dynamic> args) async {
    final cmd = args['command'] as String;
    final name = args['name'] as String? ?? 'job';
    final id = ++_jobCounter;
    final work = await _sessionWorkDir();
    final job = _BgJob(id: id, name: name, command: cmd);
    _jobs[id] = job;
    _emit('shell', 'job #$id started: $name');
    try {
      if (mode == AgentMode.studio && SandboxService.I.isInstalled) {
        // Same env/loader setup as exec() — PROOT_LOADER is required or
        // every guest execve hits EACCES (noexec temp fallback).
        job.process = await SandboxService.I.spawn(
          ['bash', '-lc', cmd],
          hostWorkDir: work,
          env: {
            'HOME': '/root',
            'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
            'TERM': 'xterm-256color',
          },
        );
      } else {
        job.process = await Process.start(
          '/system/bin/sh', ['-c', cmd],
          workingDirectory: work.path,
        );
      }
      job.started = true;
      // Stream output into a buffer (capped at 10K chars).
      job.process!.stdout.transform(utf8.decoder).listen((data) {
        job.output.write(data);
        _trimJobOutput(job);
      });
      job.process!.stderr.transform(utf8.decoder).listen((data) {
        job.output.write(data);
        _trimJobOutput(job);
      });
      job.process!.exitCode.then((code) {
        job.exitCode = code;
        job.finished = true;
        _emit('think', 'job #$id finished (exit $code)');
        notifyListeners();
      });
    } catch (e) {
      job.finished = true;
      job.exitCode = -1;
      job.output.write('job start failed: $e');
    }
    notifyListeners();
    return 'Job #$id started: "$name" — $cmd\n'
        'Use job_output {id: $id} to read output, '
        'job_kill {id: $id} to stop.';
  }

  void _trimJobOutput(_BgJob job) {
    final s = job.output.toString();
    if (s.length > 10000) {
      job.output.clear();
      job.output.write('…(earlier output trimmed)…\n${s.substring(s.length - 8000)}');
    }
  }

  String _handleJobList() {
    if (_jobs.isEmpty) return 'No background jobs running.';
    final lines = <String>[];
    for (final j in _jobs.values) {
      final status = j.finished
          ? 'finished (exit ${j.exitCode})'
          : j.started
              ? 'running'
              : 'starting';
      final lastLines = j.output.toString().trim().split('\n');
      final preview = lastLines.isEmpty || lastLines.last.isEmpty
          ? '(no output yet)'
          : lastLines.reversed.take(3).toList().reversed.join(' | ');
      lines.add('#${j.id} ${j.name} [$status] $preview');
    }
    return 'Jobs (${_jobs.length}):\n${lines.join('\n')}';
  }

  String _handleJobOutput(Map<String, dynamic> args) {
    final id = (args['id'] as num?)?.toInt() ?? -1;
    final lines = (args['lines'] as num?)?.toInt() ?? 30;
    final job = _jobs[id];
    if (job == null) return 'Job #$id not found.';
    final out = job.output.toString().trim();
    if (out.isEmpty) return 'Job #$id has no output yet.';
    final allLines = const LineSplitter().convert(out);
    final tail = allLines.length > lines
        ? allLines.sublist(allLines.length - lines)
        : allLines;
    return 'Job #$id (${job.name}) output:\n${tail.join('\n')}';
  }

  String _handleJobKill(Map<String, dynamic> args) {
    final id = (args['id'] as num?)?.toInt() ?? -1;
    final job = _jobs[id];
    if (job == null) return 'Job #$id not found.';
    if (job.finished) return 'Job #$id already finished.';
    try {
      job.process?.kill(ProcessSignal.sigkill);
      job.finished = true;
      job.exitCode = -9;
      _emit('shell', 'job #$id killed');
      notifyListeners();
      return 'Job #$id killed ✓';
    } catch (e) {
      return 'Job #$id kill failed: $e';
    }
  }

  // ── Session event log (DSH SessionEvent equivalent) ──
  // _emit() mirrors every agent event into _sessionEvents (capped 500),
  // so session_search queries both messages and the event log.
  final List<SessionEvent> _sessionEvents = [];

  String _handleSessionSearch(Map<String, dynamic> args) {
    final query = (args['query'] as String).toLowerCase();
    final limit = (args['limit'] as num?)?.toInt() ?? 20;
    // Search session messages + event log.
    final s = AppState.I.activeSession;
    final results = <String>[];
    // Messages.
    if (s != null) {
      for (final m in s.messages) {
        if (m.content.toLowerCase().contains(query)) {
          results.add('[${m.role}] ${cleanTruncate(m.content, 120)}');
          if (results.length >= limit) break;
        }
      }
    }
    // Events.
    for (final e in _sessionEvents) {
      if (e.data.toLowerCase().contains(query) ||
          e.type.toLowerCase().contains(query)) {
        results.add('[${e.type}] ${e.data}');
        if (results.length >= limit) break;
      }
    }
    if (results.isEmpty) return 'No matches for "$query".';
    return 'session_search "$query" → ${results.length} results:\n'
        '${results.join('\n')}';
  }

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
