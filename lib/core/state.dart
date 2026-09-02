import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'mcp_service.dart';
import 'theme.dart';
import 'sandbox_service.dart';

/// ---------- Models ----------

class ProviderConfig {
  final String id;
  String name;
  String description;
  String baseUrl;
  String apiKey;
  bool isFree; // ships free out of the box
  bool custom; // user-added provider
  List<String> models;
  String? selectedModel;
  bool connected;
  final bool requiresApiKey;

  ProviderConfig({
    String? id,
    required this.name,
    required this.description,
    required this.baseUrl,
    this.apiKey = '',
    this.isFree = false,
    this.custom = false,
    List<String>? models,
    this.selectedModel,
    this.connected = false,
    this.requiresApiKey = true,
  }) : id = id ?? _slug(name),
       models = models ?? [];

  bool get hasKey => apiKey.trim().isNotEmpty;
  bool get isConfigured => !requiresApiKey || hasKey;

  /// Returns the API key with all whitespace and control characters
  /// removed.  This is the value that should be used in HTTP headers —
  /// the raw [apiKey] field may contain newlines or other junk if the
  /// user accidentally pasted a multi-line blob (e.g. an error message)
  /// into the key field, which would cause a [FormatException] from
  /// the HTTP layer ("Invalid HTTP header field value").
  String get cleanApiKey => apiKey.replaceAll(RegExp(r'[\s\x00-\x1f\x7f]'), '');

  Map<String, dynamic> toPersistedJson() => {
    'id': id,
    'name': name,
    'description': description,
    'baseUrl': baseUrl,
    'isFree': isFree,
    'custom': custom,
    'models': models,
    'requiresApiKey': requiresApiKey,
  };
}

String _slug(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

String _baseModel(String value) => value.split('·').first.trim();

/// One metered model call — appended by the agent loop per request.
/// Persisted (capped history) and aggregated by the Usage screen.
class UsageEntry {
  final DateTime time;
  final String providerId;
  final String providerName;
  final String model;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final Duration duration;

  UsageEntry({
    required this.time,
    required this.providerId,
    required this.providerName,
    required this.model,
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.duration,
  });

  Map<String, dynamic> toJson() => {
    't': time.toIso8601String(),
    'pid': providerId,
    'pn': providerName,
    'm': model,
    'pt': promptTokens,
    'ct': completionTokens,
    'tt': totalTokens,
    'd': duration.inMilliseconds,
  };

  factory UsageEntry.fromJson(Map<String, dynamic> j) => UsageEntry(
    time: DateTime.tryParse(j['t'] as String? ?? '') ?? DateTime.now(),
    providerId: j['pid'] as String? ?? '',
    providerName: j['pn'] as String? ?? '',
    model: j['m'] as String? ?? '',
    promptTokens: j['pt'] as int? ?? 0,
    completionTokens: j['ct'] as int? ?? 0,
    totalTokens: j['tt'] as int? ?? 0,
    duration: Duration(milliseconds: j['d'] as int? ?? 0),
  );
}

class PluginItem {
  final String name;
  final String author;
  final String description;
  final String version;
  final String category; // Agent, MCP, Tool, Runtime
  bool installed;
  bool enabled;
  final int installs;

  PluginItem({
    required this.name,
    required this.author,
    required this.description,
    required this.version,
    required this.category,
    this.installed = false,
    this.enabled = false,
    required this.installs,
  });
}

/// MCP server entry — separate from plugins because lifecycle is different
/// (running process, JSON-RPC over stdin/stdout, on-demand connect).
class McpServer {
  String name;
  final String author;
  final String description;
  final String category; // Official / Community / Custom
  String command; // e.g. npx
  List<String> args; // e.g. ['-y', '@modelcontextprotocol/server-filesystem']
  final String? envHint; // env var needed, e.g. 'GITHUB_TOKEN'
  final String source; // registry.modelcontextprotocol.io | mcp.so | custom
  bool connected;
  bool custom;

  McpServer({
    required this.name,
    required this.author,
    required this.description,
    required this.category,
    required this.command,
    this.args = const [],
    this.envHint,
    this.source = 'registry.modelcontextprotocol.io',
    this.connected = false,
    this.custom = false,
  });
}

enum MsgKind { text, code, imageGen, reasoning, tool, turnTail, compact }

/// Attachment metadata rendered as a chip under a user message.
class MessageAttachment {
  final String name;
  final int size;
  MessageAttachment({required this.name, required this.size});

  factory MessageAttachment.fromJson(Map<String, dynamic> j) =>
      MessageAttachment(
        name: j['name'] as String? ?? 'file',
        size: (j['size'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {'name': name, 'size': size};
}

class Message {
  final String role; // 'user' | 'assistant'
  MsgKind kind; // mutable — reasoning → text promote
  String content; // mutable — live streaming updates
  final String? lang; // for code blocks
  final DateTime time;
  bool thinking; // mutable — live state
  int? elapsedMs; // assistant: how long this response took

  /// Files attached to this user message (chatbox + button). Rendered as
  /// chips under the bubble; the agent reads them from the workspace.
  List<MessageAttachment> attachments;

  // ── Tool-card fields (MsgKind.tool) — DSH ToolRow parity ──
  /// Tool name ('run_shell', 'fs_edit', 'dispatch_agent', …).
  final String? toolName;

  /// One-line title shown on the collapsed row ("bash", "Edit lib/x.dart").
  String? toolTitle;

  /// Ellipsized summary on the collapsed row (command / path / output line).
  String? toolSummary;

  /// Full detail body (command + output / diff / result) for the expanded
  /// state.  Mutated while the tool streams output.
  String? toolDetail;

  /// running | ok | error | stopped — drives the row's state dot + sweep.
  String toolState;

  /// For a `dispatch_agent` card: the child session this call created, so the
  /// row can open the subagent's full transcript. Persisted, so an old chat's
  /// subagent card still opens its child after a restart. Assigned once the
  /// child session exists (the card is created before the dispatch runs).
  String? toolSessionId;

  Message({
    required this.role,
    this.kind = MsgKind.text,
    this.content = '',
    this.lang,
    this.thinking = false,
    this.elapsedMs,
    this.toolName,
    this.toolTitle,
    this.toolSummary,
    this.toolDetail,
    this.toolState = 'running',
    this.toolSessionId,
    this.attachments = const [],
    DateTime? time,
  }) : time = time ?? DateTime.now();

  factory Message.fromJson(Map<String, dynamic> j) => Message(
    role: j['role'] as String? ?? 'user',
    kind: MsgKind.values.firstWhere(
      (k) => k.name == j['kind'],
      orElse: () => MsgKind.text,
    ),
    content: j['content'] as String? ?? '',
    lang: j['lang'] as String?,
    thinking: j['thinking'] as bool? ?? false,
    elapsedMs: (j['elapsedMs'] as num?)?.toInt(),
    toolName: j['toolName'] as String?,
    toolTitle: j['toolTitle'] as String?,
    toolSummary: j['toolSummary'] as String?,
    toolDetail: j['toolDetail'] as String?,
    toolState: j['toolState'] as String? ?? 'ok',
    toolSessionId: j['toolSessionId'] as String?,
    attachments: [
      for (final a in (j['attachments'] as List? ?? []))
        if (a is Map<String, dynamic>)
          MessageAttachment.fromJson(a),
    ],
    time: j['time'] != null ? DateTime.tryParse(j['time'] as String) : null,
  );

  Map<String, dynamic> toJson() => {
    'role': role,
    'kind': kind.name,
    'content': content,
    if (lang != null) 'lang': lang,
    if (thinking) 'thinking': thinking,
    if (elapsedMs != null) 'elapsedMs': elapsedMs,
    if (toolName != null) 'toolName': toolName,
    if (toolTitle != null) 'toolTitle': toolTitle,
    if (toolSummary != null) 'toolSummary': toolSummary,
    if (toolDetail != null) 'toolDetail': toolDetail,
    if (toolState != 'ok') 'toolState': toolState,
    if (toolSessionId != null) 'toolSessionId': toolSessionId,
    if (attachments.isNotEmpty)
      'attachments': [for (final a in attachments) a.toJson()],
    'time': time.toIso8601String(),
  };
}

/// A durable memory snippet — saved via memory_save, searchable via
/// memory_search, persisted across sessions (DSH memory equivalent).
class MemoryItem {
  final String id;
  final String content;
  final DateTime createdAt;
  MemoryItem({required this.id, required this.content, DateTime? createdAt})
    : createdAt = createdAt ?? DateTime.now();

  factory MemoryItem.fromJson(Map<String, dynamic> j) => MemoryItem(
    id: j['id'] as String,
    content: j['content'] as String,
    createdAt:
        DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'content': content,
    'createdAt': createdAt.toIso8601String(),
  };
}

class ChatSession {
  final String id;
  String title;
  String model;
  String? providerId;

  /// Per-session sandbox workspace id — used as the working directory inside
  /// the native sandbox (per-session workspace dirs). Generated once per
  /// session; old persisted sessions fall back to [id] (fromJson migration).
  /// The AI/agent NEVER sees another session's workspace unless the user
  /// enables "Share session memory" in Settings.
  String? sandboxId;

  /// Per-session agent access mode (DSH per-conversation mode parity).
  /// One of 'safe' (Read-Only), 'auto' (General), 'drive' (Full Access),
  /// 'studio' (Studio). Parallel sessions keep INDEPENDENT modes — no
  /// cross-session mode bleed. Persisted with the session.
  String mode;

  /// User-pinned working folder (picked from the composer). When set and
  /// the directory exists, ALL agent work happens inside it — shell cwd,
  /// file edits, jobs, attachments, skills roots. Null = per-session
  /// sandbox workspace. Persisted with the session.
  String? workspaceFolder;

  /// Per-session Studio repo (owner/name).  Each session can work on a
  /// different repo; new sessions start with the global default (the last
  /// connected repo).  Persisted with the session.
  String? repo;

  // ── Subagent lineage ────────────────────────────────────────────────────
  // A subagent is a REAL session with its own transcript, tool cards and
  // workspace, parented to the session that dispatched it. Child sessions
  // are hidden from the sidebar; you reach them from the parent's subagent
  // card, the descendants menu, or a breadcrumb.

  /// Id of the session that dispatched this one. Null for user chats.
  String? parentId;

  /// Short task label for a subagent session (shown in cards and menus).
  String? agentLabel;

  /// running | finished | stopped | failed — lifecycle of a subagent run.
  /// Null for user chats.
  String? agentState;

  /// True when the parent may keep feeding this child new instructions
  /// (`send_message`). One-shot children are a completed execution record.
  bool agentContinuable;

  /// Final answer the child reported back to its parent.
  String? agentResult;

  /// When set, the child may only call these tools (parent-imposed filter).
  List<String> agentAllowedTools;

  bool get isSubagent => parentId != null;

  /// Session todo/task list — written by todo_write tool, rendered as a
  /// live checklist above the chat input.  Persisted with the session.
  final List<Map<String, String>> todos;

  /// Compacted summary of older conversation — set when history exceeds
  /// the compaction threshold (~30 messages).  The AI sees this instead of
  /// the full history.  Persisted.
  String? compactedSummary;

  /// Active goal (DSH goal-round equivalent) — created by create_goal,
  /// advanced by update_goal.  One goal per session at a time.  Persisted.
  Map<String, dynamic>? goal;

  /// Session-local reminders (DSH schedule equivalent) — created by
  /// schedule_create, fired by AgentService's timer.  Persisted.
  List<Map<String, dynamic>> schedules;

  /// Message count at the time of last compaction — re-compact only when
  /// this many NEW messages have arrived since.
  int compactedAtCount;

  final List<Message> messages;
  final DateTime createdAt;

  ChatSession({
    required this.id,
    required this.title,
    required this.model,
    this.providerId,
    this.sandboxId,
    this.repo,
    this.mode = 'auto',
    this.workspaceFolder,
    this.compactedSummary,
    this.goal,
    this.compactedAtCount = 0,
    this.parentId,
    this.agentLabel,
    this.agentState,
    this.agentContinuable = false,
    this.agentResult,
    List<String>? agentAllowedTools,
    List<Message>? messages,
    List<Map<String, String>>? todos,
    List<Map<String, dynamic>>? schedules,
    DateTime? createdAt,
  }) : agentAllowedTools = agentAllowedTools ?? [],
       messages = messages ?? [],
       todos = todos ?? [],
       schedules = schedules ?? [],
       createdAt = createdAt ?? DateTime.now() {
    sandboxId ??= id;
  }

  factory ChatSession.fromJson(Map<String, dynamic> j) => ChatSession(
    id: j['id'] as String,
    title: j['title'] as String? ?? 'New chat',
    model: j['model'] as String? ?? 'Select a provider',
    providerId: j['providerId'] as String?,
    sandboxId: j['sandboxId'] as String?,
    repo: j['repo'] as String?,
    mode: j['mode'] as String? ?? 'auto',
    workspaceFolder: j['workspaceFolder'] as String?,
    compactedSummary: j['compactedSummary'] as String?,
    compactedAtCount: (j['compactedAtCount'] as num?)?.toInt() ?? 0,
    parentId: j['parentId'] as String?,
    agentLabel: j['agentLabel'] as String?,
    // A child persisted while still running was killed by app death.
    agentState: j['agentState'] == 'running'
        ? 'stopped'
        : j['agentState'] as String?,
    agentContinuable: j['agentContinuable'] as bool? ?? false,
    agentResult: j['agentResult'] as String?,
    agentAllowedTools:
        (j['agentAllowedTools'] as List?)?.whereType<String>().toList() ??
        const [],
    goal: j['goal'] == null
        ? null
        : Map<String, dynamic>.from(j['goal'] as Map),
    messages:
        (j['messages'] as List?)
            ?.map((m) => Message.fromJson(m as Map<String, dynamic>))
            .toList() ??
        [],
    todos:
        (j['todos'] as List?)
            ?.map((t) => Map<String, String>.from(t as Map))
            .toList() ??
        [],
    schedules:
        (j['schedules'] as List?)
            ?.map((t) => Map<String, dynamic>.from(t as Map))
            .toList() ??
        [],
    createdAt: j['createdAt'] != null
        ? DateTime.tryParse(j['createdAt'] as String) ?? DateTime.now()
        : DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'model': model,
    if (providerId != null) 'providerId': providerId,
    'sandboxId': sandboxId ?? id,
    if (repo != null) 'repo': repo,
    'mode': mode,
    if (workspaceFolder != null && workspaceFolder!.isNotEmpty)
      'workspaceFolder': workspaceFolder,
    if (compactedSummary != null) 'compactedSummary': compactedSummary,
    if (compactedAtCount > 0) 'compactedAtCount': compactedAtCount,
    if (parentId != null) 'parentId': parentId,
    if (agentLabel != null) 'agentLabel': agentLabel,
    if (agentState != null) 'agentState': agentState,
    if (agentContinuable) 'agentContinuable': agentContinuable,
    if (agentResult != null) 'agentResult': agentResult,
    if (agentAllowedTools.isNotEmpty) 'agentAllowedTools': agentAllowedTools,
    if (goal != null) 'goal': goal,
    'schedules': schedules,
    'todos': todos,
    'messages': messages.map((m) => m.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
  };
}

/// ---------- App state ----------

class AppState extends ChangeNotifier {
  /// Singleton — everything is user-side / on-device.
  static final AppState I = AppState._();
  AppState._() {
    _seed();
    _ensureActiveSession();
  }

  static const _secureStorage = FlutterSecureStorage();
  static const _providerKeyPrefix = 'ovid_provider_key_';
  Future<void>? _initialization;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    await loadProviderState();
    await loadProviderCredentials();
    await loadSessions();
    await _loadLastSelection();
    await _loadUsage();
    // Custom MCP servers + plugin install state survive restarts.
    await _loadCustomMcpServers();
    await _loadCustomPlugins();
    await _loadPluginState();
    await _loadMarketplaces();
    // Check if the sandbox was installed on a previous launch so the
    // user is never asked to re-install the ~200 MB rootfs.
    if (await SandboxService.I.checkExisting()) {
      sandboxInstalled = true;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final t = prefs.getInt(_kResponseTimeout);
      if (t != null && t >= 5 && t <= 3600) responseTimeoutSec = t;
      contextWindowOverride = prefs.getInt(_kContextWindowOverride) ?? 0;
      maxOutputTokens = prefs.getInt(_kMaxOutputTokens) ?? 0;
      shareSessionMemory = prefs.getBool(_kShareMemory) ?? false;
      lightTheme = prefs.getBool(_kTheme) ?? false;
      memoryEnabled = prefs.getBool(_kMemoryEnabled) ?? true;
      showReasoning = prefs.getBool(_kShowReasoning) ?? true;
      githubSync = prefs.getBool(_kGithubSync) ?? true;
      autoRunSafeCommands = prefs.getBool(_kAutoRunSafe) ?? true;
      chatFontScale = (prefs.getDouble(_kChatFontScale) ?? 1.0).clamp(
        chatFontScaleMin,
        chatFontScaleMax,
      );
      await _loadMemories();
    } catch (_) {}
  }

  /// Last model the user picked — carried into new sessions (DSH-style
  /// default model) and restored across app restarts.
  String lastSelectedModel = '';
  String? lastSelectedProviderId;

  Future<void> _loadLastSelection() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      lastSelectedModel = prefs.getString(_kLastModel) ?? '';
      lastSelectedProviderId = prefs.getString(_kLastProvider);
      // Backfill from the currently-restored active session if nothing
      // was persisted yet (upgrade path for existing installs).
      if (lastSelectedModel.isEmpty) {
        final s = activeSession;
        if (s != null && s.model != 'Select a provider') {
          lastSelectedModel = s.model;
          lastSelectedProviderId = s.providerId;
        }
      }
    } catch (_) {}
  }

  Future<void> _persistLastSelection() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (lastSelectedModel.isNotEmpty) {
        await prefs.setString(_kLastModel, lastSelectedModel);
      }
      if (lastSelectedProviderId != null) {
        await prefs.setString(_kLastProvider, lastSelectedProviderId!);
      }
    } catch (_) {}
  }

  static const _kSessions = 'ovid_sessions';
  static const _kActive = 'ovid_active_session';
  static const _kProviders = 'ovid_provider_configs_v1';
  static const _kLastModel = 'ovid_last_model';
  static const _kLastProvider = 'ovid_last_provider';
  Future<void> _providerWrite = Future<void>.value();
  Future<void> _credentialWrite = Future<void>.value();

  Future<void> loadProviderState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kProviders);
      if (raw == null || raw.isEmpty) return;
      final stored = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      for (final entry in stored) {
        final id = entry['id'] as String?;
        if (id == null || id.isEmpty) continue;
        final existing = providerById(id);
        final hasStoredModels = entry.containsKey('models');
        final models =
            (entry['models'] as List?)
                ?.whereType<String>()
                .where((model) => model.isNotEmpty)
                .toList() ??
            <String>[];
        if (existing != null) {
          existing
            ..baseUrl = entry['baseUrl'] as String? ?? existing.baseUrl
            ..models = hasStoredModels ? models : existing.models;
          continue;
        }
        if (entry['custom'] != true) continue;
        providers.add(
          ProviderConfig(
            id: id,
            name: entry['name'] as String? ?? 'Custom provider',
            description:
                entry['description'] as String? ??
                'Custom OpenAI-compatible provider',
            baseUrl: entry['baseUrl'] as String? ?? '',
            custom: true,
            isFree: entry['isFree'] as bool? ?? false,
            models: models,
            requiresApiKey: entry['requiresApiKey'] as bool? ?? true,
          ),
        );
      }
    } catch (_) {
      // Invalid provider metadata must not prevent the app from starting.
    }
  }

  Future<void> persistProviderState() async {
    final encoded = jsonEncode(
      providers.map((provider) => provider.toPersistedJson()).toList(),
    );
    _providerWrite = _providerWrite.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kProviders, encoded);
      } catch (_) {}
    });
    await _providerWrite;
  }

  Future<void> loadProviderCredentials() async {
    try {
      final credentials = await _secureStorage.readAll();
      for (final provider in providers) {
        provider.apiKey =
            credentials['$_providerKeyPrefix${provider.id}']?.trim() ?? '';
      }
      notifyListeners();
    } catch (_) {
      // A device keystore failure must not prevent the app from starting.
    }
  }

  Future<void> loadSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kSessions);
      if (raw != null && raw.isNotEmpty) {
        final loaded = raw
            .map(
              (session) => ChatSession.fromJson(
                jsonDecode(session) as Map<String, dynamic>,
              ),
            )
            .toList();
        sessions
          ..clear()
          ..addAll(loaded);
      }
      activeSessionId = prefs.getString(_kActive);
      // Never restore INTO a subagent session — the app opens on a user chat.
      final active = sessionById(activeSessionId);
      if (active == null || active.isSubagent) {
        activeSessionId = rootSessions.isEmpty ? null : rootSessions.first.id;
      }
      for (final session in sessions) {
        session.providerId ??= _inferProviderId(session.model);
      }
      _restoreSelectedModel();
      notifyListeners();
    } catch (_) {
      _ensureActiveSession();
    }
  }

  Future<void> persistSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _kSessions,
        sessions.map((s) => jsonEncode(s.toJson())).toList(),
      );
      if (activeSessionId != null) {
        await prefs.setString(_kActive, activeSessionId!);
      } else {
        await prefs.remove(_kActive);
      }
    } catch (_) {}
  }

  /// Delete all user data: sessions, workspaces, providers, keys, plugin
  /// state, usage log, memories, and app preferences. Resets in-memory
  /// state to defaults and seeds a fresh session.
  Future<void> deleteAllData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      // Secure-storage keys (API credentials, MCP env) are cleared below.
      for (final s in List.of(sessions)) {
        final sid = s.sandboxId;
        if (sid != null) unawaited(SandboxService.I.deleteWorkspace(sid));
      }
      sessions.clear();
      activeSessionId = null;
      providers.clear();
      plugins.clear();
      mcpServers.clear();
      _seed();
      memories.clear();
      usageLog.clear();
      memoryEnabled = true;
      showReasoning = true;
      githubSync = true;
      autoRunSafeCommands = true;
      shareSessionMemory = false;
      lastSelectedModel = '';
      lastSelectedProviderId = null;
      try {
        await _secureStorage.deleteAll();
      } catch (_) {}
      _ensureActiveSession();
      notifyListeners();
      await persistSessions();
      await persistProviderState();
      await persistPluginState();
    } catch (_) {}
  }

  int navIndex = 0; // 0 Chat, 1 Studio, 2 Browser, 3 Plugins, 4 Settings
  bool sandboxInstalled = false; // native bionic sandbox on-device

  /// Share memory across sessions (persisted, default OFF).
  ///
  /// OFF → the AI only sees the current session's messages/workspace.
  /// ON  → the AI (via memory_search) can search across ALL sessions' chat
  /// history ("poori app history", user-opted).
  static const _kShareMemory = 'ovid_share_session_memory';
  static const _kCustomMcpServers = 'ovid_custom_mcp_servers_v1';
  static const _kPluginState = 'ovid_plugin_state_v1';
  static const _kMcpEnvPrefix = 'ovid_mcp_env_';
  bool shareSessionMemory = false;

  // ── Light/dark theme (DSH light/dark preference parity) ──
  static const _kTheme = 'ovid_light_theme';
  bool lightTheme = false;

  // ── User settings that gate REAL features (persisted, Settings screen) ──
  /// Memory plugin (RAG "Memory" toggle): writes + searches across sessions.
  static const _kMemoryEnabled = 'ovid_memory_enabled';
  bool memoryEnabled = true;

  /// Show reasoning/thinking cards in chat (off = hide the chips entirely).
  static const _kShowReasoning = 'ovid_show_reasoning';
  bool showReasoning = true;

  /// GitHub sync: agent file edits/commits push to the connected repo.
  static const _kGithubSync = 'ovid_github_sync';
  bool githubSync = true;

  /// Auto-run safe commands: read-only shell commands skip confirmation.
  static const _kAutoRunSafe = 'ovid_auto_run_safe';
  bool autoRunSafeCommands = true;

  // ── Chat font scale (pinch-to-zoom on the message list) ──
  // Scales ONLY the message content text — the header/AppBar and the
  // composer chatbox stay fixed (per UX requirement). Width stays
  // responsive (text reflows, never horizontal-scrolls). Persisted.
  static const _kChatFontScale = 'ovid_chat_font_scale';
  double chatFontScale = 1.0;
  static const double chatFontScaleMin = 0.75;
  static const double chatFontScaleMax = 1.8;

  Future<void> setChatFontScale(double v) async {
    final clamped = v.clamp(chatFontScaleMin, chatFontScaleMax);
    if ((clamped - chatFontScale).abs() < 0.001) return;
    chatFontScale = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kChatFontScale, chatFontScale);
    } catch (_) {}
  }

  /// Toggle and persist. The app shell listens and rebuilds the whole
  /// tree so every Aether.* getter resolves to the new palette.
  Future<void> setLightTheme(bool v) async {
    lightTheme = v;
    Aether.dark = !v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kTheme, v);
    } catch (_) {}
  }

  Future<void> setShareSessionMemory(bool v) async {
    shareSessionMemory = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kShareMemory, v);
    } catch (_) {}
  }

  Future<void> setMemoryEnabled(bool v) async {
    memoryEnabled = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kMemoryEnabled, v);
    } catch (_) {}
  }

  Future<void> setShowReasoning(bool v) async {
    showReasoning = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kShowReasoning, v);
    } catch (_) {}
  }

  Future<void> setGithubSync(bool v) async {
    githubSync = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kGithubSync, v);
    } catch (_) {}
  }

  Future<void> setAutoRunSafeCommands(bool v) async {
    autoRunSafeCommands = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoRunSafe, v);
    } catch (_) {}
  }

  /// AI response timeout (seconds, user-configurable in Settings).
  static const _kResponseTimeout = 'ovid_response_timeout_sec';
  /// Per-EVENT idle timeout (never-stop semantics: as long as chunks keep
  /// arriving the stream runs indefinitely; this is the max silence).
  int responseTimeoutSec = 300;
  static const timeoutPresets = [120, 300, 600, 1800, 3600];

  // ── Context window + output caps (user-configurable, DSH settings) ─
  /// 0 = auto (per-model table, 1M fallback).  Any positive value is the
  /// user's explicit override for the ACTIVE model's context window —
  /// used by compaction pressure and the "% of context" ring.  Never a
  /// random value: auto unless the user picked a number in Settings.
  static const _kContextWindowOverride = 'ovid_context_window_override';
  int contextWindowOverride = 0;

  /// 0 = auto (no max_tokens field sent).  Positive = max completion
  /// tokens requested from the provider.
  static const _kMaxOutputTokens = 'ovid_max_output_tokens';
  int maxOutputTokens = 0;

  Future<void> setContextWindowOverride(int tokens) async {
    contextWindowOverride = tokens;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kContextWindowOverride, tokens);
    } catch (_) {}
  }

  Future<void> setMaxOutputTokens(int tokens) async {
    maxOutputTokens = tokens;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kMaxOutputTokens, tokens);
    } catch (_) {}
  }

  Future<void> setResponseTimeout(int sec) async {
    responseTimeoutSec = sec;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kResponseTimeout, sec);
    } catch (_) {}
  }

  final List<ProviderConfig> providers = [];
  final List<PluginItem> plugins = [];
  final List<McpServer> mcpServers = [];
  final List<String> marketplaces =
      []; // user-added git marketplaces (Claude Code style)
  final List<ChatSession> sessions = [];
  String? activeSessionId;

  /// Durable memories saved via memory_save — survive across sessions
  /// (DSH memory tool equivalent).  Persisted as JSON in SharedPreferences.
  final List<MemoryItem> memories = [];
  static const _kMemories = 'ovid_memories';

  Future<void> saveMemory(MemoryItem m) async {
    memories.add(m);
    if (memories.length > 200) memories.removeRange(0, memories.length - 200);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kMemories,
        jsonEncode(memories.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> _loadMemories() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kMemories);
      if (raw == null) return;
      final list = jsonDecode(raw) as List;
      memories
        ..clear()
        ..addAll(
          list.map((e) => MemoryItem.fromJson(e as Map<String, dynamic>)),
        );
    } catch (_) {}
  }

  ChatSession? get activeSession =>
      sessions.where((s) => s.id == activeSessionId).firstOrNull;

  /// Session lookup by id (used by the agent to keep a RUNNING run's
  /// writes bound to its own session even if the user switches chats).
  ChatSession? sessionById(String? id) =>
      id == null ? null : sessions.where((s) => s.id == id).firstOrNull;

  // ── Subagent lineage helpers ───────────────────────────────────────────
  /// User-facing chats only — subagent sessions never appear in the sidebar.
  List<ChatSession> get rootSessions =>
      sessions.where((s) => !s.isSubagent).toList();

  /// Direct children of [sessionId], oldest first.
  List<ChatSession> childrenOf(String sessionId) =>
      sessions.where((s) => s.parentId == sessionId).toList().reversed.toList();

  /// Every descendant of [sessionId] (children, grandchildren, …).
  List<ChatSession> descendantsOf(String sessionId) {
    final out = <ChatSession>[];
    final queue = <String>[sessionId];
    while (queue.isNotEmpty) {
      final id = queue.removeAt(0);
      for (final child in childrenOf(id)) {
        out.add(child);
        queue.add(child.id);
      }
    }
    return out;
  }

  /// Path from the root chat down to [sessionId] (inclusive).
  List<ChatSession> lineageOf(String sessionId) {
    final chain = <ChatSession>[];
    var current = sessionById(sessionId);
    final seen = <String>{};
    while (current != null && seen.add(current.id)) {
      chain.insert(0, current);
      current = sessionById(current.parentId);
    }
    return chain;
  }

  /// Register a subagent session parented to [parent] and return it. The
  /// child inherits the parent's provider/model so it can run immediately.
  ChatSession createSubagentSession({
    required ChatSession parent,
    required String label,
    required String mode,
    bool continuable = false,
    List<String> allowedTools = const [],
  }) {
    final child = ChatSession(
      id: 'sub-${DateTime.now().microsecondsSinceEpoch}',
      title: label.isEmpty ? 'Subagent' : label,
      model: parent.model,
      providerId: parent.providerId,
      mode: mode,
      parentId: parent.id,
      agentLabel: label,
      agentState: 'running',
      agentContinuable: continuable,
      agentAllowedTools: allowedTools,
      // Children share the parent's working folder so their edits land in
      // the same project; without a pinned folder they get their own
      // sandbox workspace (sandboxId defaults to the child id).
      workspaceFolder: parent.workspaceFolder,
      repo: parent.repo,
    );
    sessions.insert(0, child);
    notifyListeners();
    persistSessions();
    return child;
  }

  /// Update a subagent's lifecycle state (and optionally its final answer).
  void setAgentState(String sessionId, String state, {String? result}) {
    final s = sessionById(sessionId);
    if (s == null) return;
    s.agentState = state;
    if (result != null) s.agentResult = result;
    notifyListeners();
    persistSessions();
  }

  ProviderConfig get defaultProvider => providers.first;

  ProviderConfig? providerById(String? id) {
    if (id == null) return null;
    for (final provider in providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  ProviderConfig? providerForSession([ChatSession? session]) =>
      providerById((session ?? activeSession)?.providerId);

  String? _inferProviderId(String model) {
    final modelId = model.split('·').first.trim();
    if (modelId.isEmpty || modelId == 'Select a provider') return null;
    for (final provider in providers) {
      if (provider.models.contains(modelId)) return provider.id;
    }
    return null;
  }

  void _restoreSelectedModel() {
    // Session switching no longer mutates the shared provider's
    // selectedModel. The session's own `model` is the single source of
    // truth; provider.selectedModel is only a "last used" convenience
    // for future sessions. Writing it here used to make switching from
    // session A (model X) to session B (model Y) silently change the
    // provider field that A's in-flight run could read back.
  }

  ChatSession _ensureActiveSession() {
    final existing = activeSession;
    // A subagent session is never the implicit target for user input.
    if (existing != null && !existing.isSubagent) return existing;
    final reuse = rootSessions.firstOrNull;
    if (reuse != null) {
      activeSessionId = reuse.id;
      return reuse;
    }
    final session = ChatSession(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: 'New chat',
      model: lastSelectedModel.isEmpty
          ? 'Select a provider'
          : lastSelectedModel,
    );
    if (lastSelectedModel.isNotEmpty) {
      session.providerId =
          lastSelectedProviderId ?? _inferProviderId(lastSelectedModel);
    }
    sessions.insert(0, session);
    activeSessionId = session.id;
    return session;
  }

  void setNav(int i) {
    navIndex = i;
    notifyListeners();
  }

  void selectSession(String id) {
    activeSessionId = id;
    // NOTE: runs are per-session (parallel) — switching NEVER stops a
    // running session (DSH multi-session behavior).  Lazy-restore the
    // newly-active session's browser tabs (per-session browsers).
    onSessionSwitched?.call(id);
    notifyListeners();
    persistSessions();
  }

  /// Hook for AgentService to lazy-restore per-session browser tabs on
  /// session switch.  Set in AgentService's constructor (avoids a
  /// circular import).
  void Function(String sessionId)? onSessionSwitched;

  /// Set the ACTIVE session's agent mode (per-session, persisted). Other
  /// sessions' modes are untouched — parallel sessions never bleed.
  void setSessionMode(String m) {
    final s = activeSession;
    if (s == null || s.mode == m) return;
    s.mode = m;
    notifyListeners();
    persistSessions();
  }

  /// Pin the ACTIVE session's working folder (composer folder picker).
  /// Null/empty clears it — the agent falls back to the sandbox workspace.
  void setSessionWorkspaceFolder(String? path) {
    final s = activeSession;
    if (s == null) return;
    final normalized = (path == null || path.trim().isEmpty)
        ? null
        : path.trim();
    if (s.workspaceFolder == normalized) return;
    s.workspaceFolder = normalized;
    notifyListeners();
    persistSessions();
  }

  void newSession() {
    final s = ChatSession(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: 'New chat',
      model: lastSelectedModel.isEmpty
          ? 'Select a provider'
          : lastSelectedModel,
    );
    if (lastSelectedModel.isNotEmpty) {
      s.providerId =
          lastSelectedProviderId ?? _inferProviderId(lastSelectedModel);
    }
    // New session starts with its own default browser tab + the global
    // repo as its Studio repo (fresh per-session state, cookies shared).
    s.repo = null;
    sessions.insert(0, s);
    activeSessionId = s.id;
    onSessionSwitched?.call(s.id);
    // No provider.selectedModel mutation here — the provider field is
    // shared. Session A's in-flight run must never observe a model
    // selection that came from creating/switching to session B.
    notifyListeners();
    persistSessions();
  }

  void deleteSession(String id) {
    final s = sessions.where((x) => x.id == id).firstOrNull;
    // A chat owns its subagents: deleting it deletes their transcripts and
    // workspaces too, otherwise orphan children linger invisibly forever.
    final doomed = <ChatSession>[?s, ...descendantsOf(id)];
    sessions.removeWhere((x) => doomed.any((d) => d.id == x.id));
    if (activeSessionId == null ||
        doomed.any((d) => d.id == activeSessionId)) {
      activeSessionId = rootSessions.isEmpty ? null : rootSessions.first.id;
    }
    for (final dead in doomed) {
      // The deleted session's run dies with it (its jobs, queue, stream).
      onSessionDeleted?.call(dead.id);
      // Its workspace dies with it too — files dir was never cleaned
      // before, so deleted sessions leaked their ws_<id> dirs forever.
      final sid = dead.sandboxId;
      if (sid != null) unawaited(SandboxService.I.deleteWorkspace(sid));
    }
    notifyListeners();
    persistSessions();
  }

  /// Set by AgentService at startup — drops the deleted session's run
  /// (avoids a circular import; parallel runs for other sessions live on).
  void Function(String sessionId)? onSessionDeleted;

  /// Remove all messages from [index] onward in the named session
  /// (DSH "Revert"/"Edit & resend" semantics). Clearing from index 0 also
  /// resets the compacted summary so the agent truly starts fresh.
  void deleteMessagesFrom(String sessionId, int index) {
    final s = sessions.where((x) => x.id == sessionId).firstOrNull;
    if (s == null) return;
    final idx = index.clamp(0, s.messages.length);
    s.messages.removeRange(idx, s.messages.length);
    if (idx == 0) {
      s.compactedSummary = null;
      s.compactedAtCount = 0;
    }
    notifyListeners();
    persistSessions();
  }

  /// Replace the content of an existing message (DSH "Edit" of a user turn).
  void editMessage(String sessionId, int index, String newContent) {
    final s = sessions.where((x) => x.id == sessionId).firstOrNull;
    if (s == null || index < 0 || index >= s.messages.length) return;
    s.messages[index].content = newContent;
    notifyListeners();
    persistSessions();
  }

  void renameSession(String id, String title) {
    sessions.firstWhere((s) => s.id == id).title = title;
    notifyListeners();
    persistSessions();
  }

  void sendMessage(String text) {
    final s = _ensureActiveSession();
    s.messages.add(Message(role: 'user', content: text));
    // Auto-name session from first message (smart: strip markdown/prompt fluff)
    if (s.title == 'New chat' || s.title.isEmpty) {
      s.title = _autoTitle(text);
    }
    notifyListeners();
    persistSessions();
  }

  static String _autoTitle(String text) {
    var t = text.trim();
    // strip markdown headers, code fences, common prefixes
    t = t.replaceAll(RegExp(r'^[#>`*\-\s]+'), '');
    t = t.replaceFirst(
      RegExp(
        r'^(hey|hi|hello|please|plz|can you|could you|help me|i want|i need|write|make|build|create|generate|explain)\b[,: ]*',
        caseSensitive: false,
      ),
      '',
    );
    t = t.trim();
    if (t.isEmpty) return 'New chat';
    final words = t.split(RegExp(r'\s+'));
    final take = words.take(6).join(' ');
    final title = take.length > 40 ? '${take.substring(0, 40)}…' : take;
    return words.length > 6 && !title.endsWith('…') ? '$title…' : title;
  }

  /// Public wrapper (agent uses it for queued-continuation messages).
  static String autoTitle(String text) => _autoTitle(text);

  void removeModel(String providerId, String model) {
    final p = providerById(providerId);
    if (p == null) return;
    p.models.remove(model);
    if (p.selectedModel != null && _baseModel(p.selectedModel!) == model) {
      p.selectedModel = null;
    }
    for (final session in sessions) {
      if (session.providerId == providerId &&
          _baseModel(session.model) == model) {
        session
          ..providerId = null
          ..model = 'Select a provider';
      }
    }
    refresh();
    persistProviderState();
    persistSessions();
  }

  void reconcileProviderModels(String providerId) {
    final provider = providerById(providerId);
    if (provider == null) return;
    if (provider.selectedModel != null &&
        !provider.models.contains(_baseModel(provider.selectedModel!))) {
      provider.selectedModel = null;
    }
    for (final session in sessions) {
      if (session.providerId == providerId &&
          !provider.models.contains(_baseModel(session.model))) {
        session
          ..providerId = null
          ..model = 'Select a provider';
      }
    }
    refresh();
    persistProviderState();
    persistSessions();
  }

  void setModel(String providerId, String model) {
    final provider = providerById(providerId);
    if (provider == null) return;
    provider.selectedModel = model;
    final s = _ensureActiveSession();
    s
      ..providerId = providerId
      ..model = model;
    // Remember as the default for future sessions + restarts.
    lastSelectedModel = model;
    lastSelectedProviderId = providerId;
    _persistLastSelection();
    notifyListeners();
    persistSessions();
  }

  Future<String?> addCustomProvider({
    required String name,
    required String baseUrl,
    String apiKey = '',
  }) async {
    final normalizedName = name.trim();
    final normalizedUrl = baseUrl.trim();
    if (normalizedName.isEmpty) return 'Provider name is required.';
    final uri = Uri.tryParse(normalizedUrl);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      return 'Enter a valid absolute base URL.';
    }
    final id = 'custom-${_slug(normalizedName)}';
    if (providers.any((provider) => provider.id == id)) {
      return 'A provider with this name already exists.';
    }
    final provider = ProviderConfig(
      id: id,
      name: normalizedName,
      description: 'Custom OpenAI-compatible provider',
      baseUrl: normalizedUrl,
      apiKey: apiKey.trim(),
      custom: true,
      requiresApiKey: apiKey.trim().isNotEmpty,
    );
    try {
      await updateProviderApiKey(provider, provider.apiKey);
    } catch (_) {
      return 'The API key could not be stored securely on this device.';
    }
    providers.add(provider);
    refresh();
    await persistProviderState();
    return null;
  }

  void updateProviderBaseUrl(ProviderConfig provider, String value) {
    provider.baseUrl = value.trim();
    persistProviderState();
  }

  /// Remove a custom provider by id. Returns an error string on failure,
  /// null on success.
  Future<String?> removeCustomProvider(String providerId) async {
    final p = providerById(providerId);
    if (p == null) return 'Provider not found: $providerId';
    if (!p.custom) {
      return '"${p.name}" is a built-in provider — it cannot be removed, '
          'only its API key can be cleared.';
    }
    // Clean up the stored API key.
    try {
      await _secureStorage.delete(key: '$_providerKeyPrefix${p.id}');
    } catch (_) {}
    // Clear the model from any session using it.
    for (final s in sessions) {
      if (s.providerId == p.id) {
        s
          ..providerId = null
          ..model = 'Select a provider';
      }
    }
    providers.remove(p);
    refresh();
    await persistProviderState();
    await persistSessions();
    return null;
  }

  Future<void> updateProviderApiKey(
    ProviderConfig provider,
    String value,
  ) async {
    provider.apiKey = value.trim();
    refresh();
    final key = '$_providerKeyPrefix${provider.id}';
    final secret = provider.apiKey;
    final write = _credentialWrite.then((_) async {
      if (secret.isEmpty) {
        await _secureStorage.delete(key: key);
      } else {
        await _secureStorage.write(key: key, value: secret);
      }
    });
    _credentialWrite = write.then<void>((_) {}, onError: (_) {});
    await write;
  }

  void refresh() => notifyListeners();

  String fmtInstalls(int n) =>
      n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

  /// ---------- Usage log (real token metering) ----------
  static const _kUsage = 'ovid_usage_log';
  final List<UsageEntry> usageLog = [];
  static const _maxUsageEntries = 2000;

  Future<void> _loadUsage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kUsage);
      if (raw == null) return;
      usageLog
        ..clear()
        ..addAll(
          raw.map((e) {
            try {
              return UsageEntry.fromJson(jsonDecode(e) as Map<String, dynamic>);
            } catch (_) {
              return null;
            }
          }).whereType<UsageEntry>(),
        );
    } catch (_) {}
  }

  Future<void> _persistUsage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Keep the most recent [_maxUsageEntries].
      final recent = usageLog.length > _maxUsageEntries
          ? usageLog.sublist(usageLog.length - _maxUsageEntries)
          : usageLog;
      await prefs.setStringList(
        _kUsage,
        recent.map((e) => jsonEncode(e.toJson())).toList(),
      );
    } catch (_) {}
  }

  void appendUsage(UsageEntry e) {
    usageLog.add(e);
    _persistUsage();
    refresh();
  }

  /// Last N days of relative daily activity (heights 0..1) for a provider,
  /// used by the usage charts.
  List<double> dailyActivityFor(String providerId, {int days = 14}) {
    final now = DateTime.now();
    final counts = List<int>.filled(days, 0);
    for (final e in usageLog) {
      if (providerId.isNotEmpty && e.providerId != providerId) continue;
      final age = now.difference(e.time).inDays;
      if (age < 0 || age >= days) continue;
      counts[days - 1 - age] += e.totalTokens.clamp(1, 1 << 40);
    }
    final max = counts.reduce((a, b) => a > b ? a : b);
    if (max == 0) return List<double>.filled(days, 0.05);
    return counts.map((c) => (c / max).clamp(0.05, 1.0)).toList();
  }

  /// ---------- Marketplaces (git-repo plugin catalogs) ----------

  void sandboxReady() {
    sandboxInstalled = SandboxService.I.isInstalled;
    refresh();
  }

  static const _kMarketplaces = 'ovid_marketplaces_v1';

  /// Marketplace repos whose catalog has already been merged this launch, so
  /// the Plugins screen can refresh without re-fetching on every rebuild.
  final Set<String> _fetchedMarketplaces = {};

  /// Normalize a marketplace reference to `owner/repo`.
  static String normalizeMarketplace(String repo) => repo
      .trim()
      .replaceFirst(RegExp(r'^https?://'), '')
      .replaceFirst(RegExp(r'^www\.'), '')
      .replaceFirst(RegExp(r'^github\.com/'), '')
      .replaceFirst(RegExp(r'\.git$'), '')
      .replaceFirst(RegExp(r'/+$'), '');

  /// Register a marketplace. Returns the normalized `owner/repo` on success,
  /// or null when the input is empty/invalid/already present. The caller is
  /// expected to follow up with [fetchMarketplaceCatalog] — registering alone
  /// imports nothing.
  String? addMarketplace(String repo) {
    final normalized = normalizeMarketplace(repo);
    if (normalized.isEmpty) return null;
    if (normalized.split('/').length < 2) return null;
    if (marketplaces.contains(normalized)) return null;
    marketplaces.add(normalized);
    _persistMarketplaces();
    refresh();
    return normalized;
  }

  void removeMarketplace(String repo) {
    marketplaces.remove(repo);
    _fetchedMarketplaces.remove(repo);
    _persistMarketplaces();
    refresh();
  }

  Future<void> _persistMarketplaces() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kMarketplaces, marketplaces);
    } catch (_) {}
  }

  Future<void> _loadMarketplaces() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_kMarketplaces);
      if (list == null || list.isEmpty) return;
      for (final m in list) {
        if (!marketplaces.contains(m)) marketplaces.add(m);
      }
      refresh();
    } catch (_) {}
  }

  /// Merge every registered marketplace catalog that has not been merged yet
  /// this launch. Returns the number of repos actually fetched.
  Future<int> syncMarketplaceCatalogs({bool force = false}) async {
    var fetched = 0;
    for (final repo in List.of(marketplaces)) {
      if (!force && _fetchedMarketplaces.contains(repo)) continue;
      _fetchedMarketplaces.add(repo);
      await fetchMarketplaceCatalog(repo);
      fetched++;
    }
    return fetched;
  }

  /// Fetch a marketplace catalog from a GitHub repo and merge plugin/MCP
  /// entries into the local catalog. Returns a message describing what was
  /// imported.
  ///
  /// Supported formats (Claude Code AND Codex/Desktop style):
  /// 1. `.claude-plugin/marketplace.json` — Claude Code marketplaces:
  ///    `{"name":"...","plugins":[{"name","source","description",...}]}`
  ///    where a `source` can be `"./plugin"` (local dir, UI-only here) or
  ///    `"owner/repo"` (a GitHub plugin repo). MCP entries may appear under
  ///    `mcpServers` either as a list or the map form.
  /// 2. `marketplace.json` / `plugins.json` at the repo root — our native
  ///    format plus the Codex/Claude Desktop `mcpServers` **map** form:
  ///    `"mcpServers": {"github": {"command":"npx","args":[...],"env":{...}}}`
  ///    alongside the list form we already supported.
  ///
  /// Fetch order: raw.githubusercontent.com (main, master), then
  /// `.claude-plugin/marketplace.json`, then the jsdelivr and githack
  /// mirrors for every path (some networks block raw.githubusercontent).
  Future<String> fetchMarketplaceCatalog(String repo) async {
    final normalized = repo.trim();
    if (normalized.isEmpty) return 'Repository name is empty';
    final parts = normalized.split('/');
    if (parts.length < 2) {
      return 'Expected owner/repo (e.g. ovidai/ovid-plugins)';
    }
    final owner = parts[0];
    final name = parts[1];
    final paths = [
      'marketplace.json',
      'plugins.json',
      '.claude-plugin/marketplace.json',
    ];
    final urls = <String>[
      // Test override (a local mock server) wins over the real network.
      if (marketplaceBaseOverrideForTest != null) ...[
        for (final path in paths)
          '$marketplaceBaseOverrideForTest/$path',
      ] else ...[
        // raw.githubusercontent — canonical (both default branches).
        for (final branch in ['main', 'master'])
          for (final path in paths)
            'https://raw.githubusercontent.com/$owner/$name/$branch/$path',
        // Mirrors — raw.githubusercontent is blocked on some networks.
        for (final path in paths)
          'https://cdn.jsdelivr.net/gh/$owner/$name@main/$path',
        for (final path in paths)
          'https://raw.githack.com/$owner/$name/main/$path',
      ],
    ];
    for (final url in urls) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        final req = await client
            .getUrl(Uri.parse(url))
            .timeout(const Duration(seconds: 15));
        final res = await req.close().timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) continue;
        // Bounded read (2 MB cap) — marketplace files are small.
        final builder = BytesBuilder();
        await for (final chunk in res) {
          builder.add(chunk);
          if (builder.length > 2 * 1024 * 1024) {
            throw Exception('marketplace.json too large');
          }
        }
        final j =
            jsonDecode(utf8.decode(builder.takeBytes()))
                as Map<String, dynamic>;
        return _mergeMarketplaceCatalog(j, owner, name);
      } catch (_) {
        continue;
      } finally {
        client.close(force: true);
      }
    }
    return 'No marketplace.json found in $owner/$name '
        '(tried main, master, .claude-plugin/marketplace.json and mirrors). '
        'Check the repo exists and has a marketplace.json, plugins.json or '
        '.claude-plugin/marketplace.json on its default branch.';
  }

  /// Test seam: when set, marketplace fetches try this base before GitHub
  /// (e.g. `http://127.0.0.1:PORT` serving `<path>` from the mock server).
  @visibleForTesting
  static String? marketplaceBaseOverrideForTest;

  /// Test seam: merge a parsed marketplace document directly (no network).
  @visibleForTesting
  String mergeMarketplaceCatalogForTest(
    Map<String, dynamic> j,
    String owner,
    String repo,
  ) => _mergeMarketplaceCatalog(j, owner, repo);

  /// Merge a parsed marketplace JSON document into the catalog. Accepts
  /// both list-form and map-form (Claude Desktop / Codex / Cursor shape)
  /// `mcpServers`, plus Claude Code `plugins` entries.
  String _mergeMarketplaceCatalog(
    Map<String, dynamic> j,
    String owner,
    String repoName,
  ) {
    var importedPlugins = 0;
    var importedMcps = 0;

    // ── plugins (list form — ours + Claude Code) ──
    final pluginList = j['plugins'];
    if (pluginList is List) {
      for (final p in pluginList) {
        if (p is! Map) continue;
        final pname = p['name'] as String?;
        if (pname == null || pname.isEmpty) continue;
        if (plugins.any((e) => e.name == pname)) continue;
        plugins.add(
          PluginItem(
            name: pname,
            author: p['author'] as String? ?? owner,
            description: p['description'] as String? ?? '',
            version: p['version'] as String? ?? '1.0',
            category: p['category'] as String? ?? 'Tool',
            installed: false,
            enabled: false,
            installs: p['installs'] as int? ?? 0,
          ),
        );
        importedPlugins++;
      }
    }

    // ── mcpServers — list form AND map form (Codex/Claude Desktop) ──
    void importMcp(Map m, String? fallbackName) {
      final mname =
          (m['name'] as String?) ?? fallbackName ?? '';
      if (mname.isEmpty) return;
      if (mcpServers.any((e) => e.name == mname)) return;
      mcpServers.add(
        McpServer(
          name: mname,
          author: m['author'] as String? ?? owner,
          description: m['description'] as String? ?? '',
          category: m['category'] as String? ?? 'Community',
          command: (m['command'] as String?) ??
              (m['cmd'] as String?) ??
              'npx',
          args: (m['args'] as List?)?.whereType<String>().toList() ??
              const [],
          envHint: (m['envHint'] as String?) ??
              ((m['env'] as Map?)?.keys.isNotEmpty == true
                  ? (m['env'] as Map).keys.first as String?
                  : null),
          source: 'marketplace:$owner/$repoName',
          custom: true,
        ),
      );
      importedMcps++;
    }

    final mcpList = j['mcpServers'];
    if (mcpList is List) {
      for (final m in mcpList) {
        if (m is Map) importMcp(m.cast<String, dynamic>(), null);
      }
    } else if (mcpList is Map) {
      // Codex / Claude Desktop / Cursor config shape:
      // {"mcpServers":{"github":{"command":"npx","args":[...],"env":{...}}}}
      mcpList.forEach((key, value) {
        if (value is Map) {
          importMcp(value.cast<String, dynamic>(), key as String);
        }
      });
    }

    refresh();
    if (importedPlugins == 0 && importedMcps == 0) {
      return 'Fetched $owner/$repoName but found no new plugins or MCP '
          'servers (already imported, or the file has neither "plugins" nor '
          '"mcpServers" entries).';
    }
    return 'Imported $importedPlugins plugin(s) and $importedMcps MCP '
        'server(s) from $owner/$repoName';
  }

  /// ---------- MCP servers ----------
  void toggleMcpServer(McpServer s) {
    s.connected = !s.connected;
    if (s.connected) {
      // Spawn the real MCP server process in the sandbox.
      unawaited(
        McpService.I.connect(s).then((msg) {
          s.connected = McpService.I.isConnected(s.name);
          refresh();
        }),
      );
    } else {
      unawaited(McpService.I.disconnect(s.name));
    }
    _persistMcpConnectedIntent();
    refresh();
  }

  // ── MCP auto-reconnect (DSH tier-2 lifecycle parity) ──
  /// Names of servers the user wants connected. Survives restarts so the
  /// app can respawn them on launch/resume (spawn-on-demand otherwise).
  static const _kMcpConnectedIntent = 'ovid_mcp_connected_v1';

  Future<void> _persistMcpConnectedIntent() async {
    final names = mcpServers
        .where((s) => s.connected)
        .map((s) => s.name)
        .toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kMcpConnectedIntent, names);
    } catch (_) {}
  }

  /// Reconnect every server the user had connected (app resume/launch).
  /// Failures are silent — servers stay "disconnected" until the user
  /// retries; lazy connect covers them on tool call.
  Future<void> reconnectMcpServers() async {
    List<String> names;
    try {
      final prefs = await SharedPreferences.getInstance();
      names = prefs.getStringList(_kMcpConnectedIntent) ?? [];
    } catch (_) {
      return;
    }
    if (names.isEmpty) return;
    for (final name in names) {
      final s = mcpServers.where((s) => s.name == name).firstOrNull;
      if (s == null || McpService.I.isConnected(name)) continue;
      await McpService.I.connect(s);
      s.connected = McpService.I.isConnected(name);
    }
    refresh();
  }

  void addCustomMcpServer({
    required String name,
    required String command,
    List<String> args = const [],
    String? envHint,
  }) {
    mcpServers.add(
      McpServer(
        name: name.trim(),
        author: 'you',
        description: 'Custom MCP server — connects on demand.',
        category: 'Custom',
        command: command.trim(),
        args: args,
        envHint: envHint,
        source: 'custom',
        custom: true,
      ),
    );
    _persistCustomMcpServers();
    refresh();
  }

  void removeMcpServer(McpServer s) {
    mcpServers.remove(s);
    _persistCustomMcpServers();
    refresh();
  }

  /// Update an existing custom MCP server's command/args from edited JSON.
  void updateCustomMcpServer(
    McpServer s, {
    required String command,
    required List<String> args,
  }) {
    s.command = command;
    s.args = args;
    _persistCustomMcpServers();
    refresh();
  }

  // ── Custom MCP server + plugin persistence ─────────────────────────
  Future<void> _persistCustomMcpServers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final customs = mcpServers
          .where((s) => s.custom)
          .map(
            (s) => jsonEncode({
              'name': s.name,
              'command': s.command,
              'args': s.args,
              'envHint': s.envHint,
            }),
          )
          .toList();
      await prefs.setStringList(_kCustomMcpServers, customs);
    } catch (_) {}
  }

  Future<void> _loadCustomMcpServers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_kCustomMcpServers);
      if (list == null || list.isEmpty) return;
      for (final j in list) {
        final m = jsonDecode(j) as Map<String, dynamic>;
        final name = m['name'] as String;
        if (mcpServers.any((s) => s.name == name)) continue;
        mcpServers.add(
          McpServer(
            name: name,
            author: 'you',
            description: 'Custom MCP server — connects on demand.',
            category: 'Custom',
            command: m['command'] as String? ?? 'npx',
            args: (m['args'] as List?)?.cast<String>() ?? const [],
            envHint: m['envHint'] as String?,
            source: 'custom',
            custom: true,
          ),
        );
      }
      refresh();
    } catch (_) {}
  }

  /// Public persist hook — the Plugins UI and agent tools call this after
  /// mutating PluginItem.installed / .enabled so state survives restarts.
  Future<void> persistPluginState() => _persistPluginState();

  /// Add a custom plugin (agent-created or user-defined).  Custom plugins
  /// persist across restarts (full definition, not just enabled state)
  /// and can add tools to the agent.
  void addCustomPlugin({
    required String name,
    required String description,
    String category = 'Custom',
  }) {
    if (plugins.any((p) => p.name.toLowerCase() == name.toLowerCase())) {
      return; // already exists — no dupes
    }
    plugins.insert(
      0,
      PluginItem(
        name: name,
        author: 'you',
        description: description,
        version: '1.0.0',
        category: category,
        installed: true,
        enabled: true,
        installs: 1,
      ),
    );
    _persistCustomPlugins();
    refresh();
  }

  static const _kCustomPlugins = 'ovid_custom_plugins_v1';

  Future<void> _persistCustomPlugins() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final customs = plugins
          .where((p) => p.author == 'you')
          .map(
            (p) => jsonEncode({
              'name': p.name,
              'description': p.description,
              'category': p.category,
              'installed': p.installed,
              'enabled': p.enabled,
            }),
          )
          .toList();
      await prefs.setStringList(_kCustomPlugins, customs);
    } catch (_) {}
  }

  Future<void> _loadCustomPlugins() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_kCustomPlugins);
      if (list == null || list.isEmpty) return;
      for (final j in list) {
        final m = jsonDecode(j) as Map<String, dynamic>;
        final name = m['name'] as String;
        if (plugins.any((p) => p.name == name)) continue;
        plugins.insert(
          0,
          PluginItem(
            name: name,
            author: 'you',
            description: m['description'] as String? ?? 'Custom plugin.',
            version: '1.0.0',
            category: m['category'] as String? ?? 'Custom',
            installed: m['installed'] as bool? ?? true,
            enabled: m['enabled'] as bool? ?? true,
            installs: 1,
          ),
        );
      }
      refresh();
    } catch (_) {}
  }

  Future<void> _persistPluginState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final state = <String, String>{};
      for (final p in plugins) {
        state[p.name] = jsonEncode({
          'installed': p.installed,
          'enabled': p.enabled,
        });
      }
      await prefs.setString(_kPluginState, jsonEncode(state));
    } catch (_) {}
  }

  Future<void> _loadPluginState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPluginState);
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      for (final p in plugins) {
        final v = m[p.name];
        if (v == null) continue;
        final ps = jsonDecode(v as String) as Map<String, dynamic>;
        p.installed = ps['installed'] as bool? ?? p.installed;
        p.enabled = ps['enabled'] as bool? ?? p.enabled;
      }
      refresh();
    } catch (_) {}
  }

  // ── MCP server env vars (secure storage) ────────────────────────────
  Future<void> setMcpEnv(String serverName, Map<String, String> env) async {
    try {
      await _secureStorage.write(
        key: '$_kMcpEnvPrefix$serverName',
        value: jsonEncode(env),
      );
    } catch (_) {}
  }

  Future<Map<String, String>> getMcpEnv(String serverName) async {
    try {
      final raw = await _secureStorage.read(key: '$_kMcpEnvPrefix$serverName');
      if (raw == null || raw.isEmpty) return {};
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return {};
    }
  }

  // ── Per-session repo selection (Studio) ─────────────────────────────
  /// Repo bound to a session.  Falls back to [fallback] (the global
  /// AgentService.repoFull — passed by the caller to avoid a circular
  /// import) when the session has no repo of its own.
  String? getRepoForSession(String sessionId, {String? fallback}) {
    final session = sessions.where((s) => s.id == sessionId).firstOrNull;
    return session?.repo ?? fallback;
  }

  void setRepoForSession(String sessionId, String repoFull) {
    final session = sessions.where((s) => s.id == sessionId).firstOrNull;
    if (session != null) {
      session.repo = repoFull;
      persistSessions();
      refresh();
    }
  }

  /// ---------- Built-in catalog ----------
  void _seed() {
    providers.addAll([
      ProviderConfig(
        name: 'OpenAI',
        description: 'GPT and o-series models from the OpenAI platform.',
        baseUrl: 'https://api.openai.com/v1',
        models: ['gpt-4o', 'gpt-4o-mini', 'o3-mini'],
      ),
      ProviderConfig(
        name: 'Anthropic',
        description: 'Claude Opus, Sonnet and Haiku family.',
        baseUrl: 'https://api.anthropic.com/v1',
        models: [
          'claude-sonnet-4-20250514',
          'claude-opus-4-20250514',
          'claude-3-7-sonnet-20250219',
          'claude-3-5-haiku-20241022',
        ],
      ),
      ProviderConfig(
        name: 'Google Gemini',
        description: 'Gemini series via AI Studio (free tier available).',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        isFree: true, // AI Studio free tier — bas API key daalo
        models: ['gemini-2.5-pro', 'gemini-2.5-flash', 'gemini-2.0-flash'],
      ),
      ProviderConfig(
        name: 'DeepSeek',
        description: 'DeepSeek chat & reasoner, direct API.',
        baseUrl: 'https://api.deepseek.com/v1',
        models: ['deepseek-chat', 'deepseek-reasoner'],
      ),
      ProviderConfig(
        name: 'xAI',
        description: 'Grok family from xAI.',
        baseUrl: 'https://api.x.ai/v1',
        models: ['grok-3', 'grok-3-mini'],
      ),
      ProviderConfig(
        name: 'Mistral AI',
        description: 'Mistral Large, Codestral and open weights.',
        baseUrl: 'https://api.mistral.ai/v1',
        models: ['mistral-large-latest', 'codestral-latest'],
      ),
      ProviderConfig(
        name: 'NVIDIA NIM',
        description:
            'Free credits for hosted open models: Llama, DeepSeek, Qwen, Mistral on build.nvidia.com.',
        baseUrl: 'https://integrate.api.nvidia.com/v1',
        isFree: true,
        models: [
          'nvidia/nemotron-3.5-lightning-30b-a3b',
          'meta/llama-3.3-70b-instruct',
          'deepseek-ai/deepseek-r1',
          'qwen/qwen2.5-coder-32b-instruct',
          'mistralai/mistral-nemotron',
        ],
      ),
      ProviderConfig(
        name: 'Groq',
        description: 'Ultra-fast LPU inference. Free tier available.',
        baseUrl: 'https://api.groq.com/openai/v1',
        isFree: true,
        models: ['llama-3.3-70b-versatile', 'openai/gpt-oss-120b'],
      ),
      ProviderConfig(
        name: 'Cerebras',
        description: 'Wafer-scale speed. Free tier available.',
        baseUrl: 'https://api.cerebras.ai/v1',
        isFree: true,
        models: ['llama-3.3-70b'],
      ),
      ProviderConfig(
        name: 'GitHub Models',
        description: 'Free tier models with a GitHub token.',
        baseUrl: 'https://models.github.ai/inference',
        isFree: true,
        models: ['gpt-4.1', 'DeepSeek-R1'],
      ),
      ProviderConfig(
        name: 'OpenRouter',
        description: 'One key, 300+ models including free variants.',
        baseUrl: 'https://openrouter.ai/api/v1',
        isFree: true, // :free suffix models — free tier available
        models: ['deepseek/deepseek-chat-v3.1', 'meta-llama/llama-4-maverick'],
      ),
      ProviderConfig(
        name: 'Together AI',
        description: 'Fast inference for open models.',
        baseUrl: 'https://api.together.xyz/v1',
        models: [],
      ),
      ProviderConfig(
        name: 'Fireworks AI',
        description: 'Serverless open-model inference.',
        baseUrl: 'https://api.fireworks.ai/inference/v1',
        models: [],
      ),
      ProviderConfig(
        name: 'Perplexity',
        description: 'Sonar models with live web access.',
        baseUrl: 'https://api.perplexity.ai',
        models: ['sonar-pro', 'sonar'],
      ),
      ProviderConfig(
        name: 'Cohere',
        description: 'Command and Embed models.',
        baseUrl: 'https://api.cohere.ai/compatibility/v1',
        models: [],
      ),
      ProviderConfig(
        name: 'Ollama (local)',
        description: 'Models fully on-device or LAN, no key needed.',
        baseUrl: 'http://localhost:11434/v1',
        requiresApiKey: false,
        models: [],
      ),
    ]);

    plugins.addAll([
      // --- Core tools (DeepSeek web style: everything works out of the box) ---
      PluginItem(
        name: 'Web Search',
        author: 'ovidai',
        description:
            'Live web results with citations inside every chat. Free, no key.',
        version: '1.4.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 482000,
      ),
      PluginItem(
        name: 'DeepThink Reasoning',
        author: 'ovidai',
        description:
            'Chain-of-thought mode — model thinks step-by-step before replying, shown as collapsible reasoning.',
        version: '1.2.1',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 368000,
      ),
      PluginItem(
        name: 'Image Studio',
        author: 'ovidai',
        description:
            'In-chat image generation and edit via free endpoints (Pollinations / HF Spaces).',
        version: '1.2.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 419000,
      ),
      PluginItem(
        name: 'File Reader',
        author: 'ovidai',
        description:
            'Attach PDFs, docs, code files, CSVs — ask questions about them in chat.',
        version: '1.0.9',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 301000,
      ),
      PluginItem(
        name: 'Sandbox Runtime',
        author: 'termux',
        description:
            'Full Linux userland on-device: python, node, gcc — isolated and instant.',
        version: '3.1.0',
        category: 'Runtime',
        installed: true,
        enabled: true,
        installs: 90300,
      ),
      PluginItem(
        name: 'MCP Server Hub',
        author: 'modelcontextprotocol',
        description:
            'Connect any Model Context Protocol server: filesystem, github, postgres, puppeteer…',
        version: '2.1.0',
        category: 'MCP',
        installs: 345000,
      ),
      PluginItem(
        name: 'Web Fetch & Reader',
        author: 'ovidai',
        description:
            'Turn any URL into clean markdown for the model — articles, docs, threads.',
        version: '1.0.6',
        category: 'Tool',
        installed: true,
        installs: 517000,
      ),
      PluginItem(
        name: 'Voice Input',
        author: 'ovidai',
        description:
            'Dictate prompts hands-free, on-device speech recognition.',
        version: '0.9.8',
        category: 'Tool',
        installs: 66000,
      ),
      PluginItem(
        name: 'Multi-Model Compare',
        author: 'ovidai',
        description:
            'Send one prompt to up to 3 models side-by-side, pick the best answer.',
        version: '0.7.2',
        category: 'Tool',
        installs: 128000,
      ),
      PluginItem(
        name: 'RAG Memory',
        author: 'ovidai',
        description:
            'Long-term vector memory — the agent remembers your projects and prefs.',
        version: '1.3.0',
        category: 'Tool',
        installs: 228000,
      ),
      PluginItem(
        name: 'Code Runner',
        author: 'sandbox',
        description:
            'Run python/js snippets in chat with output preview — powered by sandbox.',
        version: '1.1.4',
        category: 'Runtime',
        installs: 154000,
      ),
      PluginItem(
        name: 'Git Workbench',
        author: 'ovidai',
        description: 'Clone, branch, commit and push from the Studio IDE.',
        version: '0.8.3',
        category: 'Tool',
        installs: 93000,
      ),
      PluginItem(
        name: 'PR Reviewer',
        author: 'ovidai',
        description: 'Auto-review GitHub PRs with inline fix suggestions.',
        version: '1.0.2',
        category: 'Agent',
        installs: 151000,
      ),
      PluginItem(
        name: 'Web Clipper',
        author: 'ovidai',
        description:
            'Save pages, snippets and notes to a searchable knowledge base.',
        version: '1.1.0',
        category: 'Tool',
        installs: 87000,
      ),
      PluginItem(
        name: 'Translate Pro',
        author: 'ovidai',
        description:
            'Document translation with layout preserved, 100+ languages.',
        version: '2.0.1',
        category: 'Tool',
        installs: 264000,
      ),
      PluginItem(
        name: 'PDF Tools',
        author: 'ovidai',
        description: 'Merge, split, compress, summarize PDFs right in chat.',
        version: '1.5.2',
        category: 'Tool',
        installs: 198000,
      ),
      PluginItem(
        name: 'Data Analyst',
        author: 'ovidai',
        description:
            'Upload CSV/Excel, get charts, trends and insights automatically.',
        version: '1.2.8',
        category: 'Tool',
        installs: 176000,
      ),
      PluginItem(
        name: 'Study Mode',
        author: 'ovidai',
        description:
            'Turn any chat into flashcards, quizzes and spaced-repetition decks.',
        version: '0.9.1',
        category: 'Tool',
        installs: 143000,
      ),
      PluginItem(
        name: 'Meeting Notes',
        author: 'ovidai',
        description:
            'Record or upload audio, get clean minutes and action items.',
        version: '1.1.6',
        category: 'Tool',
        installs: 118000,
      ),
      PluginItem(
        name: 'Prompt Library',
        author: 'ovidai',
        description: 'Community prompts with one-tap use — sorted by task.',
        version: '1.6.0',
        category: 'Tool',
        installs: 231000,
      ),
      PluginItem(
        name: 'Screen Awareness',
        author: 'ovidai',
        description:
            'Ask about anything on your screen — share a screenshot into chat.',
        version: '0.8.5',
        category: 'Tool',
        installs: 74000,
      ),
      PluginItem(
        name: 'Calendar & Tasks',
        author: 'ovidai',
        description:
            'Plan, schedule and get reminders from plain-language chat.',
        version: '1.0.7',
        category: 'Tool',
        installs: 102000,
      ),
    ]);

    // community library (dummy bulk)
    const extra = <(String, String, String, String, int)>[
      // ── Top CLI-used plugins/MCP ──
      (
        'Puppeteer MCP',
        'mcp-community',
        'Headless browser automation for agents.',
        'MCP',
        18200,
      ),
      (
        'Postgres Tools',
        'mcp-community',
        'Query and inspect Postgres databases.',
        'MCP',
        9400,
      ),
      ('Figma Bridge', 'figma', 'Read design frames and tokens.', 'MCP', 12600),
      (
        'Slack Notify',
        'community',
        'Send agent updates to Slack channels.',
        'Tool',
        5100,
      ),
      (
        'Docker-in-Sandbox',
        'sandbox',
        'OCI containers inside the sandbox.',
        'Runtime',
        7700,
      ),
      (
        'Shell History',
        'ovidai',
        'Searchable sandbox terminal history.',
        'Tool',
        3400,
      ),
      (
        'Rust Toolchain',
        'sandbox',
        'cargo + rustc prebuilt for the sandbox.',
        'Runtime',
        4100,
      ),
      (
        'Go Toolchain',
        'sandbox',
        'Go 1.23 toolchain, one tap install.',
        'Runtime',
        3900,
      ),
      (
        'Linear Sync',
        'community',
        'Create and update Linear issues from chat.',
        'Tool',
        2800,
      ),
      (
        'Sentry Watch',
        'community',
        'Pull errors into chat and let agents fix them.',
        'Tool',
        3300,
      ),
      (
        'Stripe MCP',
        'stripe',
        'Payments, invoices and customers via MCP.',
        'MCP',
        5400,
      ),
      (
        'Vercel Deploy',
        'vercel',
        'Ship previews straight from the sandbox.',
        'Tool',
        11300,
      ),
      (
        'DB Designer',
        'community',
        'Draw and migrate schemas in chat.',
        'Tool',
        4700,
      ),
      (
        'Audio Notes',
        'community',
        'Transcribe meetings into sessions.',
        'Tool',
        3600,
      ),
      (
        'Tailwind Helper',
        'community',
        'Tailwind-aware UI generation.',
        'Tool',
        9800,
      ),
      (
        'Terraform MCP',
        'hashicorp',
        'Plan and apply infra safely.',
        'MCP',
        2500,
      ),
      (
        'Notion Sync',
        'community',
        'Two-way sync with Notion databases.',
        'Tool',
        8600,
      ),
      (
        'WhatsApp Bridge',
        'community',
        'Let the agent reply on WhatsApp via template.',
        'Tool',
        6200,
      ),
      (
        'YouTube Summarizer',
        'community',
        'Paste a link, get a summary + chapters.',
        'Tool',
        14700,
      ),
      (
        'Email Drafts',
        'community',
        'Generate and queue emails from chat.',
        'Tool',
        7900,
      ),
      // ── Batch 2: More popular tools/MCP ──
      (
        'Exa Search MCP',
        'exa',
        'Semantic web search — find docs, APIs, papers.',
        'MCP',
        22100,
      ),
      (
        'Playwright MCP',
        'playwright',
        'Modern browser automation with smart waiting.',
        'MCP',
        19800,
      ),
      (
        'Discord MCP',
        'discord-mcp',
        'Read/send Discord messages, manage servers.',
        'MCP',
        8900,
      ),
      (
        'Telegram MCP',
        'telegram',
        'Bot API — send messages, listen to channels.',
        'MCP',
        7200,
      ),
      (
        'Obsidian MCP',
        'obsidian',
        'Read/write Obsidian vault notes.',
        'MCP',
        6600,
      ),
      (
        'Firebase MCP',
        'firebase',
        'Firestore, Auth, Storage — full Firebase access.',
        'MCP',
        5800,
      ),
      (
        'Supabase MCP',
        'supabase',
        'Postgres + Auth + Storage from Supabase.',
        'MCP',
        9100,
      ),
      (
        'Airtable MCP',
        'airtable',
        'Read/write Airtable bases and tables.',
        'MCP',
        4700,
      ),
      (
        'Google Drive MCP',
        'google',
        'Search, read, and upload files to Drive.',
        'MCP',
        12300,
      ),
      (
        'GitLab MCP',
        'gitlab',
        'GitLab repos, MRs, issues — full DevOps.',
        'MCP',
        6100,
      ),
      (
        'Jira MCP',
        'atlassian',
        'Create and update Jira issues and sprints.',
        'MCP',
        8400,
      ),
      (
        'Trello MCP',
        'atlassian',
        'Boards, cards, lists — Trello automation.',
        'MCP',
        3900,
      ),
      (
        'Redis MCP',
        'redis',
        'Key-value store operations and pub/sub.',
        'MCP',
        2100,
      ),
      (
        'MongoDB MCP',
        'mongodb',
        'Document queries, aggregations, indexes.',
        'MCP',
        5400,
      ),
      (
        'S3 MCP',
        'aws',
        'S3 buckets — upload, list, download, presigned URLs.',
        'MCP',
        7600,
      ),
      (
        'Cloudflare MCP',
        'cloudflare',
        'Workers, KV, R2, DNS — edge compute.',
        'MCP',
        4800,
      ),
      (
        'Docker MCP',
        'docker',
        'Manage containers, images, volumes, networks.',
        'MCP',
        9200,
      ),
      (
        'Kubernetes MCP',
        'k8s',
        'Pods, services, deployments — cluster control.',
        'MCP',
        6800,
      ),
      (
        'OpenAI DALL·E MCP',
        'openai',
        'Image generation via DALL·E 3.',
        'MCP',
        11200,
      ),
      (
        'ElevenLabs MCP',
        'elevenlabs',
        'Text-to-speech with realistic voices.',
        'MCP',
        7100,
      ),
      (
        'LangChain MCP',
        'langchain',
        'Chains, agents, memory — full LangChain.',
        'MCP',
        4400,
      ),
      (
        'AutoGPT Bridge',
        'agpt',
        'Chain multiple agents for complex tasks.',
        'MCP',
        3800,
      ),
      (
        'Vector DB MCP',
        'pinecone',
        'Pinecone/Weaviate — vector search & memory.',
        'MCP',
        5200,
      ),
      (
        'Appwrite MCP',
        'appwrite',
        'Auth, DB, storage, functions — backend suite.',
        'MCP',
        3600,
      ),
      (
        'PocketBase MCP',
        'pocketbase',
        'Lightweight backend in a single binary.',
        'MCP',
        2900,
      ),
      (
        'Cal.com MCP',
        'cal',
        'Scheduling, bookings, calendar management.',
        'MCP',
        4100,
      ),
      (
        'Zapier MCP',
        'zapier',
        'Trigger zaps and read automation results.',
        'MCP',
        6300,
      ),
      (
        'Make.com MCP',
        'make',
        'Run Make.com scenarios from agent.',
        'MCP',
        3400,
      ),
      (
        'Bitbucket MCP',
        'atlassian',
        'Repos, PRs, pipelines for Bitbucket.',
        'MCP',
        4200,
      ),
      (
        'Vercel MCP',
        'vercel',
        'Deploy, manage projects, domains via API.',
        'MCP',
        8100,
      ),
      (
        'Railway MCP',
        'railway',
        'Deploy and manage Railway services.',
        'MCP',
        3200,
      ),
      (
        'Heroku MCP',
        'heroku',
        'Dyno management, config vars, addons.',
        'MCP',
        2600,
      ),
      (
        'DigitalOcean MCP',
        'digitalocean',
        'Droplets, App Platform, Spaces, DNS.',
        'MCP',
        5700,
      ),
      (
        'Twilio MCP',
        'twilio',
        'SMS, calls, WhatsApp — messaging APIs.',
        'MCP',
        5100,
      ),
      (
        'Discord Bot Builder',
        'discord-mcp',
        'Build and deploy Discord bots from chat.',
        'Agent',
        7800,
      ),
      (
        'Web Scraper Pro',
        'ovidai',
        'Visual CSS selector → structured data.',
        'Tool',
        12500,
      ),
      (
        'API Tester',
        'ovidai',
        'Build and test REST APIs from chat.',
        'Tool',
        8900,
      ),
      (
        'Regex Builder',
        'ovidai',
        'Natural language → regex with tests.',
        'Tool',
        6700,
      ),
      (
        'SQL Formatter',
        'ovidai',
        'Pretty-print and optimize SQL queries.',
        'Tool',
        5400,
      ),
      (
        'JSON Visualizer',
        'ovidai',
        'Paste JSON → interactive tree explorer.',
        'Tool',
        7600,
      ),
      (
        'Env Manager',
        'ovidai',
        'Manage .env files across repos safely.',
        'Tool',
        4300,
      ),
      (
        'Log Analyzer',
        'ovidai',
        'Parse and explain log files with patterns.',
        'Tool',
        5100,
      ),
      (
        'Git Diff Explain',
        'ovidai',
        'AI explanation of what a diff actually does.',
        'Tool',
        6800,
      ),
      (
        'File Converter',
        'ovidai',
        'Convert between formats: CSV/JSON/YAML/XML.',
        'Tool',
        8200,
      ),
      (
        'QR Generator',
        'ovidai',
        'Generate QR codes for URLs, WiFi, contact cards.',
        'Tool',
        9700,
      ),
      (
        'Password Vault',
        'ovidai',
        'Secure local password manager with autofill.',
        'Tool',
        11400,
      ),
      (
        'SSH Key Manager',
        'ovidai',
        'Generate and manage SSH keys for servers.',
        'Tool',
        5600,
      ),
      (
        'Cron Designer',
        'ovidai',
        'Visual cron schedule builder and explainer.',
        'Tool',
        4600,
      ),
      (
        'Markdown Editor',
        'ovidai',
        'Live-preview markdown editor with export.',
        'Tool',
        6900,
      ),
      (
        'Mermaid Diagrams',
        'ovidai',
        'Flowcharts, sequence diagrams from text.',
        'Tool',
        10300,
      ),
      (
        'Excalidraw Bridge',
        'excalidraw',
        'Draw diagrams in Excalidraw, sync to repo.',
        'Tool',
        4800,
      ),
      (
        'Color Palette Gen',
        'ovidai',
        'Generate accessible color palettes from descriptions.',
        'Tool',
        7900,
      ),
      (
        'Icon Library',
        'ovidai',
        'Search 200k+ icons (Lucide, Material, Feather).',
        'Tool',
        6200,
      ),
      (
        'Font Preview',
        'ovidai',
        'Preview Google Fonts with custom text.',
        'Tool',
        5500,
      ),
      (
        'Code Review AI',
        'ovidai',
        'AI-powered code review with fix suggestions.',
        'Agent',
        13800,
      ),
      (
        'Test Writer',
        'ovidai',
        'Generate unit tests for any function/class.',
        'Agent',
        9400,
      ),
      (
        'README Writer',
        'ovidai',
        'Auto-generate professional README files.',
        'Agent',
        8700,
      ),
      (
        'Changelog Gen',
        'ovidai',
        'Generate changelog from git history.',
        'Agent',
        4500,
      ),
      (
        'Commit Msg Helper',
        'ovidai',
        'AI commit messages following Conventional Commits.',
        'Agent',
        7300,
      ),
      (
        'Issue Triager',
        'ovidai',
        'Categorize and prioritize GitHub issues.',
        'Agent',
        5600,
      ),
      (
        'Release Notes',
        'ovidai',
        'Draft release notes from merged PRs.',
        'Agent',
        6100,
      ),
    ];
    plugins.addAll([
      for (final (n, a, d, c, i) in extra)
        PluginItem(
          name: n,
          author: a,
          description: d,
          version: '1.${(i % 9) + 0}.${i % 7}',
          category: c,
          installs: i,
        ),
    ]);

    // --- MCP servers (official registry + community) ---
    mcpServers.addAll([
      McpServer(
        name: 'Chrome DevTools',
        author: 'ovidai',
        description:
            'Browser automation for the inbuilt browser — navigate, click, type, evaluate JS, read pages. Powers agent web browsing.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@ovidai/chrome-devtools-mcp'],
        connected: true,
      ),
      McpServer(
        name: 'Filesystem',
        author: 'modelcontextprotocol',
        description:
            'Read, write and search files in folders you share with the agent.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@modelcontextprotocol/server-filesystem'],
      ),
      McpServer(
        name: 'GitHub',
        author: 'modelcontextprotocol',
        description:
            'Repos, issues, PRs and actions — full GitHub access for your agent.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@modelcontextprotocol/server-github'],
        envHint: 'GITHUB_TOKEN',
      ),
      McpServer(
        name: 'Fetch',
        author: 'modelcontextprotocol',
        description:
            'Fetch web pages and convert them to clean markdown for the model.',
        category: 'Official',
        command: 'uvx',
        args: ['mcp-server-fetch'],
      ),
      McpServer(
        name: 'Memory',
        author: 'modelcontextprotocol',
        description:
            'Long-term memory graph — the agent remembers across sessions.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@modelcontextprotocol/server-memory'],
      ),
      McpServer(
        name: 'Puppeteer',
        author: 'modelcontextprotocol',
        description:
            'Headless browser automation — click, scroll, screenshot, scrape.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@modelcontextprotocol/server-puppeteer'],
      ),
      McpServer(
        name: 'Postgres',
        author: 'modelcontextprotocol',
        description:
            'Read-only schema inspection and safe queries on your database.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@modelcontextprotocol/server-postgres'],
        envHint: 'DATABASE_URL',
      ),
      McpServer(
        name: 'Brave Search',
        author: 'smithery-ai',
        description: 'Live web search results straight into the chat.',
        category: 'Community',
        command: 'npx',
        args: ['-y', '@smithery/brave-search'],
        envHint: 'BRAVE_API_KEY',
      ),
      McpServer(
        name: 'Slack',
        author: 'community',
        description: 'Send and read Slack messages from your workspace.',
        category: 'Community',
        command: 'npx',
        args: ['-y', '@smithery/slack-mcp'],
        envHint: 'SLACK_TOKEN',
      ),
      McpServer(
        name: 'Playwright',
        author: 'playwright',
        description:
            'Modern browser automation with smart waiting — faster than Puppeteer.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@playwright/mcp'],
      ),
      McpServer(
        name: 'GitLab',
        author: 'gitlab',
        description: 'GitLab repos, merge requests, CI pipelines.',
        category: 'Community',
        command: 'npx',
        args: ['-y', '@smithery/gitlab-mcp'],
        envHint: 'GITLAB_TOKEN',
      ),
      McpServer(
        name: 'Google Drive',
        author: 'google',
        description: 'Search, read, and upload files to Google Drive.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@google/mcp-drive'],
        envHint: 'GOOGLE_TOKEN',
      ),
      McpServer(
        name: 'Firebase',
        author: 'firebase',
        description: 'Firestore, Auth, Storage — full Firebase SDK access.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@firebase/mcp'],
        envHint: 'FIREBASE_CONFIG',
      ),
      McpServer(
        name: 'Supabase',
        author: 'supabase',
        description: 'Postgres + Auth + Storage from Supabase.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@supabase/mcp'],
        envHint: 'SUPABASE_URL,SUPABASE_KEY',
      ),
      McpServer(
        name: 'Vercel',
        author: 'vercel',
        description: 'Deploy, manage projects, domains via Vercel API.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@vercel/mcp'],
        envHint: 'VERCEL_TOKEN',
      ),
      McpServer(
        name: 'Docker',
        author: 'docker',
        description: 'Manage containers, images, volumes, networks.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@docker/mcp'],
      ),
      McpServer(
        name: 'Kubernetes',
        author: 'k8s',
        description: 'Pods, services, deployments — cluster control.',
        category: 'Community',
        command: 'npx',
        args: ['-y', '@k8s/mcp'],
      ),
      McpServer(
        name: 'MongoDB',
        author: 'mongodb',
        description: 'Document queries, aggregations, indexes.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@mongodb/mcp'],
        envHint: 'MONGODB_URI',
      ),
      McpServer(
        name: 'Redis',
        author: 'redis',
        description: 'Key-value store operations and pub/sub.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@redis/mcp'],
        envHint: 'REDIS_URL',
      ),
      McpServer(
        name: 'S3',
        author: 'aws',
        description: 'S3 buckets — upload, list, download, presigned URLs.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@aws/mcp-s3'],
        envHint: 'AWS_ACCESS_KEY,AWS_SECRET_KEY',
      ),
      McpServer(
        name: 'Notion',
        author: 'notion',
        description: 'Two-way sync with Notion databases and pages.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@notion/mcp'],
        envHint: 'NOTION_TOKEN',
      ),
      McpServer(
        name: 'Linear',
        author: 'linear',
        description: 'Create and update Linear issues and projects.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@linear/mcp'],
        envHint: 'LINEAR_API_KEY',
      ),
      McpServer(
        name: 'Figma',
        author: 'figma',
        description: 'Read design frames, tokens, and export assets.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@figma/mcp'],
        envHint: 'FIGMA_TOKEN',
      ),
      McpServer(
        name: 'OpenAI DALL·E',
        author: 'openai',
        description: 'Image generation via DALL·E 3.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@openai/mcp-dalle'],
        envHint: 'OPENAI_API_KEY',
      ),
      McpServer(
        name: 'ElevenLabs',
        author: 'elevenlabs',
        description: 'Text-to-speech with realistic AI voices.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@elevenlabs/mcp'],
        envHint: 'ELEVENLABS_API_KEY',
      ),
      McpServer(
        name: 'Twilio',
        author: 'twilio',
        description: 'SMS, calls, WhatsApp — messaging APIs.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@twilio/mcp'],
        envHint: 'TWILIO_ACCOUNT_SID,TWILIO_AUTH_TOKEN',
      ),
      McpServer(
        name: 'Discord',
        author: 'discord',
        description: 'Read/send Discord messages, manage servers.',
        category: 'Community',
        command: 'npx',
        args: ['-y', '@discord/mcp'],
        envHint: 'DISCORD_TOKEN',
      ),
      McpServer(
        name: 'Jira',
        author: 'atlassian',
        description: 'Create and update Jira issues and sprints.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@atlassian/mcp-jira'],
        envHint: 'JIRA_TOKEN',
      ),
      McpServer(
        name: 'Obsidian',
        author: 'obsidian',
        description: 'Read/write Obsidian vault notes.',
        category: 'Community',
        command: 'npx',
        args: ['-y', '@obsidian/mcp'],
      ),
    ]);

    // user-added marketplaces (Claude Code style)
    marketplaces.addAll(['ovidai/ovid-plugins']);
  }
}
