import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'agent_notification_service.dart';
import 'agent_service.dart' show AgentService;
import 'firebase_service.dart';
import 'github_service.dart';
import 'hook_service.dart';
import 'mcp_service.dart';
import 'plugin_adapters.dart';
import 'plugin_manifest.dart';
import 'plugin_permissions.dart';
import 'plugin_registry.dart';
import 'plugin_runtime.dart';
import 'plugin_source_resolver.dart';
import 'theme.dart';
import 'sandbox_service.dart';
import 'presets.dart';
import 'startup_coordinator.dart';

const kDeniedControlDomains = <String>[
  'paypal.com',
  'wise.com',
  'chase.com',
  'bankofamerica.com',
  'wellsfargo.com',
  'citigroup.com',
  'capitalone.com',
];
const kDeniedControlPackages = <String>[
  'com.paypal.android.p2pmobile',
  'com.transferwise.android',
  'com.chase.sig.android',
  'com.infonow.bofa',
  'com.wf.wellsfargomobile',
  'com.citi.citimobile',
  'com.konylabs.capitalone',
];
const kControlModeDisclosure =
    'Control mode lets Ovid use your device the way you would. With your permission '
    'it can read what is on screen and tap, type, swipe, and use Back / Home / Recents '
    'in this app and in others, so it can finish tasks for you end to end.\n\n'
    'Ovid reads the screen only while Control mode is on, and only to do what you asked. '
    'Screen structure and screenshots may be stored in this chat or its workspace and '
    'sent to the selected AI provider; provider retention follows their policy. '
    'Ovid will not act on banking or payment screens, and password fields are blocked. '
    'Every action appears in this chat.\n\n'
    'You turn this on yourself in Settings > Accessibility, and you can turn it off there at any time.';

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

  /// Cache accounting (PR18, token-meter parity): prompt_tokens
  /// decomposed into cache-read (KV reused) and cache-write (new KV).
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final Duration duration;

  UsageEntry({
    required this.time,
    required this.providerId,
    required this.providerName,
    required this.model,
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
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
    if (cacheReadTokens > 0) 'cr': cacheReadTokens,
    if (cacheWriteTokens > 0) 'cw': cacheWriteTokens,
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
    cacheReadTokens: j['cr'] as int? ?? 0,
    cacheWriteTokens: j['cw'] as int? ?? 0,
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
  final bool installsKnown;

  /// PR40: marketplace `source` for a Claude-Code-shaped plugin —
  /// `"owner/repo"` (a GitHub plugin repo) or `"./local-dir"` (a path
  /// inside the marketplace's own repo, UI-only — no separate fetch).
  /// Only an `owner/repo` source is ever dereferenced by
  /// [AppState.fetchPluginContent]; null means this plugin has no
  /// separate content to mount (our native seeded catalog rows, or a
  /// marketplace entry that never declared one).
  String? source;

  /// Marketplace origin repo (`owner/repo`), if imported from one.
  final String? marketplace;

  /// PR24: plugin hooks — event name → shell command. Declared in the
  /// plugin manifest (`"hooks": {"on_turn_start": "make snapshot"}`) and
  /// fired by HookService at the matching agent lifecycle point. The
  /// command runs inside the sandbox with OVID_HOOK_EVENT/OVID_HOOK_
  /// PAYLOAD env vars; stdout ≤2 KB can be injected as request context.
  /// (the plugin hook runner hooks are in-process JS callbacks — on mobile, sandbox shell
  /// commands are the honest equivalent.)
  Map<String, String> hooks;

  /// Task 3: optional per-hook matcher regex (event name → regex pattern).
  /// When present, the hook fires only when the tool name (payload `tool`)
  /// matches the pattern. Populated from `hooks/hooks.json`; empty means the
  /// hook fires for every tool.
  Map<String, String> hookMatchers;

  /// Task 8 (spec §8): the normalized ordered hook list (canonical event
  /// names, per-hook matcher/timeout). Legacy rows persisted only the
  /// `hooks` map — those migrate into this list on parse (via the frozen
  /// alias map in plugin_adapters), and the map itself stays populated so
  /// old readers keep working. Empty when the plugin declares no hooks.
  List<PluginHook> pluginHooks;

  /// Production-plugin compatibility (design spec §4.3/§7): runtime identity
  /// and activation state persisted alongside the catalog row.
  ///
  /// Canonical runtime id of the installed [NormalizedPluginManifest]
  /// (`publisher/name`). Null for catalog-only rows that have no normalized
  /// executable manifest.
  String? runtimeId;

  /// Honest lifecycle state (spec §7). Defaults to
  /// [PluginActivation.disabled] — including for legacy persisted rows that
  /// predate this field: existing installed rows are never auto-promoted to
  /// `globalActive`; that only happens once the production audit (Task 9)
  /// verifies real capability.
  PluginActivation activation;

  /// When [activation] is [PluginActivation.sessionActive]: the only session
  /// that sees the plugin before restart promotion (agent installs).
  String? immediateSessionId;

  /// Set when installed during the current boot; `activateForBoot()` promotes
  /// the plugin to [PluginActivation.globalActive] exactly once on the next
  /// restart and clears this flag (spec §7).
  bool promoteOnNextBoot;

  /// Digest of the installed normalized manifest — permission grants are
  /// keyed by plugin id + this digest (spec §5.1).
  String? manifestDigest;

  /// Optional-severity [CompatibilityIssue]s surfaced in the UI as visible
  /// warnings (degraded behavior — spec §4.3/§13). Required-severity findings
  /// fail install instead of landing here.
  List<CompatibilityIssue> compatibilityWarnings;

  /// Fail-closed marker for installs that need normalized inspection and a
  /// fresh explicit grant before they can execute again.
  bool migrationRequired;

  /// Actionable runtime/migration detail shown by startup and plugin UI.
  String? runtimeReason;

  PluginItem({
    required this.name,
    required this.author,
    required this.description,
    required this.version,
    required this.category,
    this.installed = false,
    this.enabled = false,
    this.installs = 0,
    this.installsKnown = false,
    this.hooks = const {},
    this.hookMatchers = const {},
    this.pluginHooks = const [],
    this.source,
    this.marketplace,
    this.runtimeId,
    this.activation = PluginActivation.disabled,
    this.immediateSessionId,
    this.promoteOnNextBoot = false,
    this.manifestDigest,
    this.compatibilityWarnings = const [],
    this.migrationRequired = false,
    this.runtimeReason,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'author': author,
    'description': description,
    'version': version,
    'category': category,
    'installed': installed,
    'enabled': enabled,
    'installs': installs,
    'installsKnown': installsKnown,
    if (source != null) 'source': source,
    if (marketplace != null) 'marketplace': marketplace,
    if (hooks.isNotEmpty) 'hooks': hooks,
    if (hookMatchers.isNotEmpty) 'hookMatchers': hookMatchers,
    // Task 8 (spec §8): the ordered normalized hook list — emitted only
    // when non-empty so untouched rows serialize byte-identical to the
    // pre-existing shape (old readers never see unexpected keys). A row
    // still carrying only the legacy map derives its ordered list here
    // (migration: map → ordered PluginHook list on write).
    if (pluginHooks.isNotEmpty || hooks.isNotEmpty)
      'pluginHooks': _effectivePluginHooks(
        pluginHooks,
        hooks,
        hookMatchers,
        name,
      ).map((h) => h.toJson()).toList(),
    // Runtime fields are emitted only when non-default, so untouched rows
    // serialize byte-identical to the pre-existing shape (old readers never
    // see unexpected keys; old rows parse with honest inert defaults).
    if (runtimeId != null) 'runtimeId': runtimeId,
    if (activation != PluginActivation.disabled) 'activation': activation.name,
    if (immediateSessionId != null) 'immediateSessionId': immediateSessionId,
    if (promoteOnNextBoot) 'promoteOnNextBoot': promoteOnNextBoot,
    if (manifestDigest != null) 'manifestDigest': manifestDigest,
    if (compatibilityWarnings.isNotEmpty)
      'compatibilityWarnings': compatibilityWarnings
          .map((i) => i.toJson())
          .toList(),
    if (migrationRequired) 'migrationRequired': true,
    if (runtimeReason != null) 'runtimeReason': runtimeReason,
  };

  factory PluginItem.fromJson(Map<String, dynamic> j) => PluginItem(
    name: j['name'] as String? ?? '',
    author: j['author'] as String? ?? '',
    description: j['description'] as String? ?? '',
    version: j['version'] as String? ?? '1.0',
    category: j['category'] as String? ?? 'Tool',
    installed: j['installed'] as bool? ?? false,
    enabled: j['enabled'] as bool? ?? false,
    installs: (j['installs'] as num?)?.toInt() ?? 0,
    installsKnown: j['installsKnown'] as bool? ?? false,
    source: j['source'] as String?,
    marketplace: j['marketplace'] as String?,
    hooks:
        (j['hooks'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ) ??
        const {},
    hookMatchers:
        (j['hookMatchers'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ) ??
        const {},
    pluginHooks: _effectivePluginHooks(
      _pluginHooksFromJson(j),
      (j['hooks'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          ) ??
          const {},
      (j['hookMatchers'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          ) ??
          const {},
      j['name'] as String? ?? '',
    ),
    runtimeId: j['runtimeId'] as String?,
    activation:
        pluginActivationFromName(j['activation']) ?? PluginActivation.disabled,
    immediateSessionId: j['immediateSessionId'] as String?,
    promoteOnNextBoot: j['promoteOnNextBoot'] as bool? ?? false,
    manifestDigest: j['manifestDigest'] as String?,
    compatibilityWarnings:
        (j['compatibilityWarnings'] as List?)
            ?.whereType<Map>()
            .map((i) => CompatibilityIssue.fromJson(i.cast<String, dynamic>()))
            .toList() ??
        const [],
    migrationRequired: j['migrationRequired'] as bool? ?? false,
    runtimeReason: j['runtimeReason'] as String?,
  );

  /// Valid hook event names (mirrors the wired points in AgentService).
  /// PR39: `on_pre_tool` is a GATING event ([CC] PreToolUse
  /// parity) — its command's exit code can DENY the tool call, not just
  /// observe it. Every other event is fire-and-observe only.
  static const hookEvents = [
    'on_session_start',
    'on_turn_start',
    'on_pre_tool',
    'on_turn_end',
    'on_pre_request',
    'on_post_tool',
  ];

  /// Task 8 (spec §8): parse the ordered hook list from row JSON. New
  /// rows carry `pluginHooks` (normalized [PluginHook] JSON); legacy rows
  /// carry only the `hooks` map (+ optional `hookMatchers`) — those
  /// migrate through the frozen alias map so old installs keep firing,
  /// with the map's insertion order preserved as hook order.
  static List<PluginHook> _pluginHooksFromJson(Map<String, dynamic> j) {
    final raw = j['pluginHooks'];
    if (raw is List) {
      final out = <PluginHook>[];
      for (final h in raw) {
        if (h is Map) {
          try {
            out.add(PluginHook.fromJson(h.cast<String, dynamic>()));
          } catch (_) {}
        }
      }
      return out;
    }
    // Legacy migration: `hooks` map (+ `hookMatchers`).
    return _migrateLegacyHooks(
      j['hooks'],
      j['hookMatchers'],
      (j['name'] as String? ?? '').isEmpty
          ? 'legacy-plugin'
          : (j['name'] as String),
    );
  }

  /// Legacy `hooks` map (+ optional matchers) → ordered canonical list.
  /// Unmapped event names are dropped; empty commands are dropped.
  static List<PluginHook> _migrateLegacyHooks(
    dynamic rawHooks,
    dynamic rawMatchers,
    String pluginId,
  ) {
    if (rawHooks is! Map) return const [];
    final matchers = rawMatchers is Map
        ? rawMatchers.map((k, v) => MapEntry(k.toString(), v.toString()))
        : const <String, String>{};
    final out = <PluginHook>[];
    for (final e in rawHooks.entries) {
      final canonical = canonicalHookEvent(e.key.toString());
      if (canonical == null) continue;
      final cmd = e.value.toString().trim();
      if (cmd.isEmpty) continue;
      out.add(
        PluginHook(
          pluginId: pluginId,
          event: canonical,
          ordinal: out.length,
          type: 'command',
          payload: cmd,
          matcher: matchers[e.key.toString()],
          timeoutS: 30,
        ),
      );
    }
    return out;
  }

  /// The ordered hook list a row FIRES with: the normalized list when
  /// present, else the migrated legacy map (spec §8 migration ruling —
  /// old JSON must still parse and fire).
  static List<PluginHook> _effectivePluginHooks(
    List<PluginHook> normalized,
    Map<String, String> legacyHooks,
    Map<String, String> legacyMatchers,
    String pluginId,
  ) {
    if (normalized.isNotEmpty) return normalized;
    return _migrateLegacyHooks(legacyHooks, legacyMatchers, pluginId);
  }
}

/// MCP server entry — separate from plugins because lifecycle is different
/// (running process, JSON-RPC over stdin/stdout, on-demand connect).
class McpServer {
  String name;

  /// Null for legacy/user-owned servers. Plugin-owned rows keep the source
  /// name for display and persistence, while this field supplies ownership
  /// and the collision-free internal identity.
  final String? ownerPluginId;
  final String author;
  final String description;
  final String category; // Official / Community / Custom
  String command; // e.g. npx
  List<String> args; // e.g. ['-y', '@modelcontextprotocol/server-filesystem']
  final String? envHint; // env var needed, e.g. 'GITHUB_TOKEN'
  final String source; // registry.modelcontextprotocol.io | mcp.so | custom
  bool connected;
  bool custom;

  /// PR41: transport — 'stdio' (spawn [command]/[args] in the sandbox,
  /// speak JSON-RPC over stdin/stdout — the only transport Ovid supported
  /// before this) or 'http' (Streamable HTTP: POST JSON-RPC to [url], no
  /// sandbox needed). The MCP client library `ovid-mcp-client` supports both; a remote MCP
  /// server (an API a team runs centrally) only ever offers 'http'.
  String transport;

  /// Streamable-HTTP endpoint — required when [transport] is 'http',
  /// unused for 'stdio'. Mutable so [AppState.updateCustomMcpServer] can
  /// round-trip a config edit that adds/removes/renames the endpoint.
  String? url;

  /// Extra HTTP headers (auth tokens etc.) for the 'http' transport.
  /// Mutable for the same round-trip reason; persisted in SECURE storage
  /// (never plaintext prefs) via [AppState.setMcpHeaders].
  Map<String, String> headers;

  /// Credential names required before an owned server may be connected.
  /// Values are read from secure storage under [canonicalId].
  List<String> requiredEnvNames;
  List<String> requiredHeaderNames;
  String? pluginRuntimeRoot;

  /// Working directory for the spawned process (stdio transport). Relative
  /// paths resolve against the sandbox home; absolute paths are used as-is.
  String? cwd;

  /// Startup (handshake: initialize → tools/list) timeout in seconds.
  /// Production default 30; distinct from the per-call timeout.
  int startupTimeoutS;

  McpServer({
    required this.name,
    required this.author,
    required this.description,
    required this.category,
    required this.command,
    this.ownerPluginId,
    this.args = const [],
    this.envHint,
    this.source = 'registry.modelcontextprotocol.io',
    this.connected = false,
    this.custom = false,
    this.transport = 'stdio',
    this.url,
    this.headers = const {},
    List<String>? requiredEnvNames,
    List<String>? requiredHeaderNames,
    this.pluginRuntimeRoot,
    this.cwd,
    this.startupTimeoutS = 30,
  }) : requiredEnvNames = List.unmodifiable(requiredEnvNames ?? const []),
       requiredHeaderNames = List.unmodifiable(requiredHeaderNames ?? const []);

  /// Stable internal key. Legacy custom/imported servers intentionally keep
  /// their bare name so persisted behavior and display remain unchanged.
  String get canonicalId => ownerPluginId == null || ownerPluginId!.isEmpty
      ? name
      : '$ownerPluginId/$name';

  /// The config-file `type` spelling ('stdio' | 'http' | 'sse'). Kept as an
  /// alias for [transport] so importers can map `type` → transport directly.
  String get type => transport;
  set type(String? v) => transport = v ?? 'stdio';
}

enum ServiceHealth { connecting, working, failed }

class ServiceStatus {
  final ServiceHealth health;
  final String detail;
  final DateTime updatedAt;

  const ServiceStatus({
    required this.health,
    this.detail = '',
    required this.updatedAt,
  });
}

/// Split a shell-style argument string into tokens, preserving single and
/// double quotes plus simple backslash escapes. Used to accept a raw
/// `command`/`args` string from a pasted MCP config instead of requiring a
/// JSON array.
List<String> shellSplitArgs(String input) {
  final out = <String>[];
  final buf = StringBuffer();
  String? quote; // either "'" or '"' while inside a quoted span
  var escaped = false;
  var hasToken = false;
  for (var i = 0; i < input.length; i++) {
    final c = input[i];
    if (escaped) {
      buf.write(c);
      escaped = false;
      hasToken = true;
      continue;
    }
    if (c == r'\' && quote != "'") {
      escaped = true;
      hasToken = true;
      continue;
    }
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else {
        buf.write(c);
      }
      hasToken = true;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      hasToken = true;
      continue;
    }
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      if (hasToken) {
        out.add(buf.toString());
        buf.clear();
        hasToken = false;
      }
      continue;
    }
    buf.write(c);
    hasToken = true;
  }
  if (hasToken) out.add(buf.toString());
  return out;
}

/// Test seam for the pure shell-splitter (no I/O).
@visibleForTesting
List<String> shellSplitArgsForTest(String input) => shellSplitArgs(input);

enum MsgKind {
  text,
  reasoning,
  tool,
  turnTail, // reserved: turn-tail lane rows (not constructed today)
  compact,
  imageGen,
}

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

  // ── Tool-card fields (MsgKind.tool) — ToolRow parity ──
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
    this.imagePath,
    this.feedback,
    this.feedbackNote,
    DateTime? time,
  }) : time = time ?? DateTime.now();

  /// Local file path for `MsgKind.imageGen` rows — the generated image
  /// saved into the session workspace (rendered in-chat, tappable to open).
  final String? imagePath;

  /// User feedback on a FINAL assistant message (the chat feedback tracker message-feedback):
  /// 'up' | 'down' | null. Re-clicking the same value retracts (null).
  String? feedback;

  /// Optional note attached to a down-vote (why it was bad).
  String? feedbackNote;

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
    imagePath: j['imagePath'] as String?,
    feedback: j['feedback'] as String?,
    feedbackNote: j['feedbackNote'] as String?,
    attachments: [
      for (final a in (j['attachments'] as List? ?? []))
        if (a is Map<String, dynamic>) MessageAttachment.fromJson(a),
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
    if (imagePath != null) 'imagePath': imagePath,
    if (feedback != null) 'feedback': feedback,
    if (feedbackNote != null && feedbackNote!.isNotEmpty)
      'feedbackNote': feedbackNote,
    if (attachments.isNotEmpty)
      'attachments': [for (final a in attachments) a.toJson()],
    'time': time.toIso8601String(),
  };
}

/// A durable memory snippet — saved via memory_save, searchable via
/// memory_search, persisted across sessions (the long-term memory store equivalent).
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

  /// Per-session agent access mode (the session policy gate per-conversation mode parity).
  /// One of 'safe' (Read-Only), 'auto' (General), 'drive' (Full Access),
  /// 'studio' (Studio), or 'control' (Control). Parallel sessions keep
  /// INDEPENDENT modes — no cross-session mode bleed. Persisted with the
  /// session.
  String mode;

  /// Agent preset — a named composition of a tool roster + a persona
  /// preamble (the preset coordinator agent-presets parity: standard / minimal / studio /
  /// code). Sessions join a preset; a child inherits its parent's.
  /// Persisted with the session; changing it on a session with no turns
  /// is allowed (the session manager "switch the blank session" semantics).
  String presetId;

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

  /// Durable handle id (`sub-N`) of this subagent — lets the handle
  /// registry be rebuilt after an app restart (cold resume, parity).
  String? agentId;

  /// Optional per-child role persona (dispatch_agent `persona` arg).
  String? agentPersona;

  /// Optional required shape of the child's FINAL message
  /// (dispatch_agent `output_schema_hint` arg).
  String? agentOutputHint;

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

  /// Active goal (the goal manager goal-round equivalent) — created by create_goal,
  /// advanced by update_goal.  One goal per session at a time.  Persisted.
  Map<String, dynamic>? goal;

  /// Plan mode (the plan mode coordinator /plan parity) — persisted per session so a restart or
  /// session switch keeps the amber planning state.
  bool planMode;

  /// Session-local reminders (the reminder scheduler schedule equivalent) — created by
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
    this.presetId = 'standard',
    this.workspaceFolder,
    this.compactedSummary,
    this.goal,
    this.planMode = false,
    this.compactedAtCount = 0,
    this.parentId,
    this.agentLabel,
    this.agentState,
    this.agentContinuable = false,
    this.agentResult,
    this.agentId,
    this.agentPersona,
    this.agentOutputHint,
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
    mode: AppState.sanitizeColdStartMode(j['mode'] as String? ?? 'auto'),
    presetId: j['presetId'] as String? ?? 'standard',
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
    agentId: j['agentId'] as String?,
    agentPersona: j['agentPersona'] as String?,
    agentOutputHint: j['agentOutputHint'] as String?,
    agentAllowedTools:
        (j['agentAllowedTools'] as List?)?.whereType<String>().toList() ??
        const [],
    goal: j['goal'] == null
        ? null
        : Map<String, dynamic>.from(j['goal'] as Map),
    planMode: j['planMode'] as bool? ?? false,
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
    if (presetId != 'standard') 'presetId': presetId,
    if (workspaceFolder != null && workspaceFolder!.isNotEmpty)
      'workspaceFolder': workspaceFolder,
    if (compactedSummary != null) 'compactedSummary': compactedSummary,
    if (compactedAtCount > 0) 'compactedAtCount': compactedAtCount,
    if (parentId != null) 'parentId': parentId,
    if (agentLabel != null) 'agentLabel': agentLabel,
    if (agentState != null) 'agentState': agentState,
    if (agentContinuable) 'agentContinuable': agentContinuable,
    if (agentResult != null) 'agentResult': agentResult,
    if (agentId != null) 'agentId': agentId,
    if (agentPersona != null && agentPersona!.isNotEmpty)
      'agentPersona': agentPersona,
    if (agentOutputHint != null && agentOutputHint!.isNotEmpty)
      'agentOutputHint': agentOutputHint,
    if (agentAllowedTools.isNotEmpty) 'agentAllowedTools': agentAllowedTools,
    if (goal != null) 'goal': goal,
    if (planMode) 'planMode': planMode,
    'schedules': schedules,
    'todos': todos,
    'messages': messages.map((m) => m.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
  };
}

/// ---------- App state ----------

typedef StartupStageDelegate = Future<void> Function();
typedef PluginBootActivator =
    Future<void> Function(Object bootToken, bool connectMcp);
typedef PersistedSessionDecoder = ChatSession Function(String encoded);
typedef SessionBootstrapDecoder = Map<String, dynamic> Function(String encoded);
typedef WorkspaceDeleter = Future<void> Function(String sandboxId);
const _sessionBootstrapTailSize = 50;

ChatSession _decodePersistedSession(String encoded) =>
    ChatSession.fromJson(jsonDecode(encoded) as Map<String, dynamic>);

ChatSession _decodePersistedSessionTail(String encoded) {
  final json = jsonDecode(encoded) as Map<String, dynamic>;
  final messages = (json['messages'] as List?) ?? const [];
  final start = messages.length > _sessionBootstrapTailSize
      ? messages.length - _sessionBootstrapTailSize
      : 0;
  return ChatSession.fromJson(
    Map<String, dynamic>.from(json)..['messages'] = messages.sublist(start),
  );
}

String _sessionSourceFingerprint(String encoded) =>
    sha256.convert(utf8.encode(encoded)).toString();

class _AppStartupTask implements StartupTask {
  const _AppStartupTask({
    required this.id,
    required this.kind,
    required this.label,
    required this.timeout,
    required this.runStage,
  });

  @override
  final String id;
  @override
  final StartupItemKind kind;
  @override
  final String label;
  @override
  final Duration timeout;
  final StartupStageDelegate runStage;

  @override
  StartupDisable? get onDisable => null;

  @override
  Future<StartupItemStatus> run() async {
    await runStage();
    return StartupItemStatus.ready(id, kind, label);
  }
}

class _LocalHydrationStartupTask implements StartupTask {
  const _LocalHydrationStartupTask(this.app);

  final AppState app;

  @override
  String get id => 'local.hydrate';
  @override
  StartupItemKind get kind => StartupItemKind.localState;
  @override
  String get label => 'Load local data';
  @override
  Duration get timeout => app._startupTimeout(id, const Duration(seconds: 15));
  @override
  StartupDisable? get onDisable => null;

  @override
  Future<StartupItemStatus> run() async {
    try {
      await app._runStartupStage(id, app._hydrateRemainingLocalState);
      app._localHydrationReady = app._unparsedSessionJson.isEmpty;
    } finally {
      app._localHydrationSettled = true;
      await app._maybeFinishSessionRestore();
    }
    if (!app._localHydrationReady) {
      return StartupItemStatus.degraded(
        id,
        kind,
        label,
        reason: 'Some saved sessions could not be read and were preserved',
      );
    }
    return StartupItemStatus.ready(id, kind, label);
  }
}

class _SessionRestoreStartupTask implements StartupTask {
  const _SessionRestoreStartupTask(this.app);

  final AppState app;

  @override
  String get id => 'session.restore';
  @override
  StartupItemKind get kind => StartupItemKind.sessionHook;
  @override
  String get label => 'Restore session runtime';
  @override
  Duration get timeout => app._startupTimeout(id, const Duration(seconds: 15));
  @override
  StartupDisable? get onDisable => null;

  @override
  Future<StartupItemStatus> run() async {
    app._sessionRestoreRequested = true;
    final restored = await app._maybeFinishSessionRestore();
    if (!restored) {
      return StartupItemStatus.degraded(
        id,
        kind,
        label,
        reason: 'Waiting for local hydration, plugin activation, and skills',
      );
    }
    return StartupItemStatus.ready(id, kind, label);
  }
}

class _SkillMountStartupTask implements StartupTask {
  const _SkillMountStartupTask(this.app);

  final AppState app;

  @override
  String get id => 'skill.mount';
  @override
  StartupItemKind get kind => StartupItemKind.skillMount;
  @override
  String get label => 'Mount session skills';
  @override
  Duration get timeout => app._startupTimeout(id, const Duration(seconds: 15));
  @override
  StartupDisable? get onDisable => null;

  @override
  Future<StartupItemStatus> run() async {
    app._skillMountSettled = false;
    app._skillMountSucceeded = false;
    try {
      await app._runStartupStage(id, app._mountRuntimeSkills);
      app._skillMountSucceeded = true;
      return StartupItemStatus.ready(id, kind, label);
    } finally {
      app._skillMountSettled = true;
      await app._maybeFinishSessionRestore();
    }
  }
}

class _PluginSafetyStartupTask implements StartupTask {
  const _PluginSafetyStartupTask(this.app);

  final AppState app;

  @override
  String get id => 'localSafety.migrate';
  @override
  StartupItemKind get kind => StartupItemKind.localState;
  @override
  String get label => 'Check local plugin safety';
  @override
  Duration get timeout => const Duration(seconds: 15);
  @override
  StartupDisable? get onDisable => null;

  @override
  Future<StartupItemStatus> run() async {
    await app._runStartupStage(id, app._reconcilePluginSafety);
    final statuses = app.pluginSafetyStatuses;
    if (statuses.isEmpty) return StartupItemStatus.ready(id, kind, label);
    var aggregate = StartupItemState.ready;
    for (final status in statuses) {
      if (status.state == StartupItemState.failed) {
        aggregate = StartupItemState.failed;
        break;
      }
      if (status.state == StartupItemState.migrationRequired) {
        aggregate = StartupItemState.migrationRequired;
      } else if (status.state == StartupItemState.degraded &&
          aggregate == StartupItemState.ready) {
        aggregate = StartupItemState.degraded;
      }
    }
    return StartupItemStatus(
      id: id,
      kind: kind,
      label: label,
      state: aggregate,
      reason: statuses
          .where((status) => status.state == aggregate)
          .map((status) => status.reason)
          .whereType<String>()
          .firstOrNull,
      attempt: 1,
    );
  }
}

class AppState extends ChangeNotifier {
  /// Singleton — everything is user-side / on-device.
  static AppState? _testInstance;
  static AppState get I => _testInstance ?? _singleton;
  static final AppState _singleton = AppState._();

  static String sanitizeColdStartMode(String mode) {
    return mode == 'control' ? 'drive' : mode;
  }

  @visibleForTesting
  factory AppState.createForTest({
    void Function(String stage)? startupStageRecorder,
    Map<String, StartupStageDelegate> startupStageDelegates = const {},
    Map<String, Duration> startupStageTimeouts = const {},
    PluginBootActivator? pluginBootActivator,
    PersistedSessionDecoder? persistedSessionDecoder,
    SessionBootstrapDecoder? sessionBootstrapDecoder,
    WorkspaceDeleter? workspaceDeleter,
  }) {
    final instance = AppState._(
      startupStageRecorder: startupStageRecorder,
      startupStageDelegates: startupStageDelegates,
      startupStageTimeouts: startupStageTimeouts,
      pluginBootActivator: pluginBootActivator,
      persistedSessionDecoder: persistedSessionDecoder,
      sessionBootstrapDecoder: sessionBootstrapDecoder,
      workspaceDeleter: workspaceDeleter,
    );
    _testInstance = instance;
    return instance;
  }

  @visibleForTesting
  static void resetTestInstance() {
    _testInstance = null;
  }

  AppState._({
    this._startupStageRecorder,
    Map<String, StartupStageDelegate> startupStageDelegates = const {},
    Map<String, Duration> startupStageTimeouts = const {},
    PluginBootActivator? pluginBootActivator,
    PersistedSessionDecoder? persistedSessionDecoder,
    SessionBootstrapDecoder? sessionBootstrapDecoder,
    WorkspaceDeleter? workspaceDeleter,
  }) : _startupStageDelegates = Map.unmodifiable(startupStageDelegates),
       _startupStageTimeouts = Map.unmodifiable(startupStageTimeouts) {
    _pluginBootActivator =
        pluginBootActivator ??
        ((bootToken, connectMcp) => PluginRuntimeManager.I.activateForBoot(
          connectMcp: connectMcp,
          bootToken: bootToken,
          reportFailure: true,
        ));
    _persistedSessionDecoderForTest = persistedSessionDecoder;
    _sessionBootstrapDecoder =
        sessionBootstrapDecoder ??
        (encoded) => jsonDecode(encoded) as Map<String, dynamic>;
    _workspaceDeleter = workspaceDeleter ?? SandboxService.I.deleteWorkspace;
    _seed();
    _ensureActiveSession();
  }

  final void Function(String stage)? _startupStageRecorder;
  final Map<String, StartupStageDelegate> _startupStageDelegates;
  final Map<String, Duration> _startupStageTimeouts;
  late final PluginBootActivator _pluginBootActivator;
  PersistedSessionDecoder? _persistedSessionDecoderForTest;
  late final SessionBootstrapDecoder _sessionBootstrapDecoder;
  late final WorkspaceDeleter _workspaceDeleter;

  Future<void> setPluginInstalled(
    String name,
    bool installed, {
    bool? enabled,
  }) async {
    final p = plugins.where((x) => x.name == name).firstOrNull;
    if (p == null) return;
    if (!installed) {
      await uninstallPlugin(p);
    } else {
      p.installed = true;
      p.enabled = enabled ?? true;
      await persistPluginState();
      refresh();
    }
  }

  Future<void> setPluginEnabled(String name, bool enabled) async {
    final p = plugins.where((x) => x.name == name).firstOrNull;
    if (p == null) return;
    if (!enabled) {
      await disablePlugin(p);
    } else {
      await enablePlugin(p);
    }
  }

  bool isPluginInstalled(String name) =>
      plugins.where((x) => x.name == name).firstOrNull?.installed ?? false;

  String? pluginSource(String name) =>
      plugins.where((x) => x.name == name).firstOrNull?.source;

  /// Hook for AgentService to refresh skills on plugin install/uninstall/toggle
  /// without a circular import.
  static Future<void> Function(String? pluginId)? onRefreshSkills;

  /// Task 7 (spec §4.1/§5.2/§7): the production install transaction —
  /// resolve → inspect → grant → dependencies → probe → persist →
  /// registry activation → atomic rename. On success the runtime
  /// identity/activation fields are applied to [plugin] and persisted.
  ///
  /// Pass an already-approved [inspection] (the UI's single-resolve flow)
  /// to install with ZERO re-resolve — exactly one inspection per
  /// install, no leaked staging. When omitted the source is inspected
  /// here (agent path). Returns null when no typed [PluginSource] is
  /// derivable (source-less legacy catalog rows keep the flag-flip
  /// path); a failed result (or a [PluginRuntimeException]) means the
  /// transaction rolled back and nothing changed.
  Future<PluginInstallResult?> installPlugin(
    PluginItem plugin, {
    PluginSource? source,
    PluginInspection? inspection,
    required PluginInstallOrigin origin,
    String? sessionId,
    void Function(String line)? onProgress,
  }) async {
    final PluginInspection owned;
    if (inspection != null) {
      owned = inspection;
    } else {
      final src =
          source ??
          (plugin.source != null
              ? githubPluginSourceFromSourceString(plugin.source!)
              : null);
      if (src == null) return null;
      try {
        owned = await PluginRuntimeManager.I.inspect(src);
      } catch (e) {
        return PluginInstallResult.failed(
          error: 'source resolution failed: $e',
        );
      }
    }
    final grant = await pluginPermissions.effectiveRuntimeGrant(
      pluginId: owned.manifest.id,
      manifest: owned.manifest,
    );
    // Fail-closed WITHOUT touching the passed inspection on the no-grant
    // path: the caller (UI flow) still owns its staging and discards it
    // (cancel leaves NO state; exactly one inspect total).
    PluginInstallResult result;
    try {
      result = await PluginRuntimeManager.I.install(
        owned,
        grant: grant,
        origin: origin,
        sessionId: sessionId,
        onProgress: onProgress,
      );
    } on PluginRuntimeException catch (e) {
      if (e.code == PluginRuntimeErrorCode.capabilityApprovalRequired ||
          e.code == PluginRuntimeErrorCode.digestMismatch) {
        return PluginInstallResult.failed(error: e.message);
      }
      rethrow;
    }
    if (result.status != PluginInstallStatus.failed) {
      plugin.installed = true;
      plugin.enabled = true;
      plugin.runtimeId = result.manifest!.id;
      plugin.activation = result.record!.state;
      plugin.immediateSessionId = result.record!.immediateSessionId;
      plugin.promoteOnNextBoot = result.record!.promoteOnNextBoot;
      plugin.manifestDigest = result.manifestDigest;
      plugin.migrationRequired = false;
      plugin.runtimeReason = null;
      plugin.compatibilityWarnings = [
        for (final c in result.manifest!.compatibility)
          if (c.severity == CompatibilitySeverity.optional) c,
      ];
      await persistPluginState();
      await persistMergedMarketplaceCatalog();
      await PluginRuntimeManager.I.persistRuntimeRow(result.manifest!.id);
      try {
        await onRefreshSkills?.call(result.manifest!.id);
      } catch (_) {}
      refresh();
    }
    return result;
  }

  Future<void> uninstallPlugin(PluginItem plugin) async {
    final runtimeId = plugin.runtimeId;
    final runtimeManaged = runtimeId != null;
    plugin.installed = false;
    plugin.enabled = false;
    if (runtimeId != null) {
      // Task 7: runtime-managed rows tear down the atomic install
      // (registry, committed content, dependency sandbox, activation
      // record, grant + owned secrets) before the legacy surfaces below.
      try {
        await PluginRuntimeManager.I.uninstall(runtimeId);
      } catch (_) {}
    }
    await persistPluginState();

    if (plugin.source != null) {
      await removePluginContent(plugin.source!);
    }

    final owned = mcpServers.where((s) {
      if (runtimeManaged && s.ownerPluginId == runtimeId) return false;
      if (s.source == 'plugin:${plugin.name}') return true;
      // Runtime-owned rows: PluginRuntimeManager.I.uninstall above has
      // already NULLed plugin.runtimeId (_clearRowRuntime), so this must
      // match against the method-entry capture — the live field is dead
      // here and the Task 9 `plugin:<runtimeId>` rows would survive.
      if (runtimeId != null && s.source == 'plugin:$runtimeId') {
        return true;
      }
      if (plugin.source != null &&
          (s.source == 'plugin:${plugin.source}' ||
              s.source == 'plugin:${plugin.source!.replaceAll('/', '_')}')) {
        return true;
      }
      return false;
    }).toList();

    for (final s in owned) {
      s.connected = false;
      try {
        await McpService.I.disconnect(s.canonicalId);
      } catch (_) {}
      mcpServers.remove(s);
      await Future.wait([
        deleteMcpEnv(s.canonicalId),
        deleteMcpHeaders(s.canonicalId),
      ]);
    }

    if (owned.isNotEmpty) {
      await _persistCustomMcpServers();
      await _persistMcpConnectedIntent();
    }

    try {
      await onRefreshSkills?.call(runtimeId);
    } catch (_) {}

    refresh();
  }

  Future<void> disablePlugin(PluginItem plugin) async {
    final runtimeId = plugin.runtimeId;
    final runtimeManaged = runtimeId != null;
    plugin.enabled = false;
    if (plugin.runtimeId != null) {
      // Task 7: runtime-managed rows unmount their registry
      // contributions and persist the disabled activation.
      try {
        await PluginRuntimeManager.I.disable(plugin.runtimeId!);
      } catch (_) {}
    }
    await persistPluginState();

    final owned = mcpServers.where((s) {
      if (runtimeManaged && s.ownerPluginId == runtimeId) return false;
      if (s.source == 'plugin:${plugin.name}') return true;
      if (plugin.runtimeId != null &&
          s.source == 'plugin:${plugin.runtimeId}') {
        return true;
      }
      if (plugin.source != null &&
          (s.source == 'plugin:${plugin.source}' ||
              s.source == 'plugin:${plugin.source!.replaceAll('/', '_')}')) {
        return true;
      }
      return false;
    }).toList();

    for (final s in owned) {
      s.connected = false;
      try {
        await McpService.I.disconnect(s.canonicalId);
      } catch (_) {}
    }

    if (owned.isNotEmpty) {
      await _persistMcpConnectedIntent();
    }

    try {
      await onRefreshSkills?.call(runtimeId);
    } catch (_) {}

    refresh();
  }

  Future<void> enablePlugin(PluginItem plugin) async {
    final runtimeId = plugin.runtimeId;
    if (plugin.runtimeId != null) {
      // Task 7: runtime-managed rows re-register their contributions
      // (applying any promotion that came due while disabled).
      try {
        await PluginRuntimeManager.I.enable(plugin.runtimeId!);
      } catch (_) {}
      final current = plugins
          .where((row) => row.runtimeId == plugin.runtimeId)
          .firstOrNull;
      plugin.enabled = current?.enabled ?? false;
    } else if (!plugin.migrationRequired) {
      plugin.enabled = true;
    }
    await persistPluginState();
    try {
      await onRefreshSkills?.call(runtimeId);
    } catch (_) {}
    refresh();
  }

  Future<PluginActivation> retryPlugin(PluginItem plugin) async {
    final runtimeId = plugin.runtimeId;
    if (runtimeId == null) return PluginActivation.failed;
    final activation = await PluginRuntimeManager.I.retry(runtimeId);
    try {
      await onRefreshSkills?.call(runtimeId);
    } catch (_) {}
    refresh();
    return activation;
  }

  // ── Plugin capability grants (spec §5.1 — Task 5) ──────────────────
  // One consolidated approval per plugin manifest digest. The store is
  // standalone (Task 7's install transaction calls into it); these
  // helpers keep the UI/agent wiring one-liners.

  /// The process-wide permission-grant store.
  static final PluginPermissionStore pluginPermissions =
      PluginPermissionStore();

  /// The grant currently effective for [plugin]'s registered manifest:
  /// a stored grant whose digest matches the manifest (unchanged
  /// manifest → stored grant; changed manifest → null, delta approval
  /// required — spec §5.1). Null when nothing is registered/approved.
  Future<PluginPermissionGrant?> effectivePluginGrant(PluginItem plugin) async {
    final runtimeId = plugin.runtimeId;
    if (runtimeId == null) return null;
    final manifest = PluginContributionRegistry.I.manifestFor(runtimeId);
    if (manifest == null) return null;
    return pluginPermissions.effectiveRuntimeGrant(
      pluginId: runtimeId,
      manifest: manifest,
    );
  }

  /// Revokes [plugin]'s grant and its owned secrets, then disables the
  /// plugin so its contributions stop applying immediately (spec §5.1:
  /// "removing a grant immediately disables affected contributions").
  Future<void> revokePluginGrant(PluginItem plugin) async {
    final runtimeId = plugin.runtimeId;
    if (runtimeId != null) {
      await pluginPermissions.revoke(runtimeId);
    }
    if (plugin.enabled) {
      await disablePlugin(plugin);
    }
  }

  static const _secureStorage = FlutterSecureStorage();
  static const _providerKeyPrefix = 'ovid_provider_key_';
  Future<void>? _initialization;
  Future<void>? _firstFrameInitialization;
  Future<List<StartupTask>>? _readinessTasks;
  Future<void>? _readinessInitialization;
  Future<List<StartupItemStatus>>? _pluginSafetyReconciliation;
  List<StartupItemStatus> _pluginSafetyStatuses = const [];
  var _pluginSafetyReconciled = false;
  Future<void>? _pluginBootActivation;
  var _pluginBootActivated = false;
  final Object _bootToken = Object();
  var _readinessStarted = false;
  var _readinessComplete = false;
  final Completer<void> _readinessStartedSignal = Completer<void>();
  Future<void>? _pendingResumeReconnect;
  var _localHydrationSettled = false;
  var _localHydrationReady = false;
  List<String>? _deferredSessionJson;
  var _deferredSessionsPending = false;
  final List<String> _unparsedSessionJson = [];
  final Set<String> _deferredDeletedSessionIds = {};
  final Set<String> _notifiedDeletedSessionIds = {};
  final List<Future<void>> _pendingWorkspaceDeletions = [];
  String? _deferredActiveSessionId;
  int _deferredActiveTailLength = 0;
  var _deferredSessionGeneration = 0;
  var _sessionRestoreFinished = false;
  var _sessionRestoreRequested = false;
  var _skillMountSettled = false;
  var _skillMountSucceeded = false;

  List<StartupItemStatus> get pluginSafetyStatuses =>
      List.unmodifiable(_pluginSafetyStatuses);

  bool get legacyPluginExecutionAllowed => _pluginSafetyReconciled;

  Future<void> initialize() => _initialization ??= initializeReadiness();

  Future<void> initializeForFirstFrame() =>
      _firstFrameInitialization ??= _initializeForFirstFrame();

  Future<void> _initializeForFirstFrame() async {
    _startupStageRecorder?.call('local.firstFrame');
    await loadProviderState();
    await _loadSessionsForFirstFrame();
    await _loadLastSelection();
    await _loadShellPreferences();
    sandboxInstalled = await SandboxService.I.checkExisting();
  }

  Future<List<StartupTask>> buildReadinessTasks() =>
      _readinessTasks ??= Future.value([
        _LocalHydrationStartupTask(this),
        _PluginSafetyStartupTask(this),
        _startupTask(
          id: 'plugin.activate',
          kind: StartupItemKind.plugin,
          label: 'Activate plugins',
          timeout: const Duration(seconds: 15),
          body: _activatePluginsForBoot,
        ),
        _SkillMountStartupTask(this),
        _SessionRestoreStartupTask(this),
        _startupTask(
          id: 'marketplace.refresh',
          kind: StartupItemKind.marketplace,
          label: 'Refresh plugin marketplaces',
          timeout: const Duration(seconds: 20),
          body: () async => syncMarketplaceCatalogs(),
        ),
        _startupTask(
          id: 'mcp.connect',
          kind: StartupItemKind.mcp,
          label: 'Connect services',
          timeout: const Duration(seconds: 30),
          body: reconnectServices,
        ),
        _startupTask(
          id: 'firebase.initialize',
          kind: StartupItemKind.firebase,
          label: 'Initialize optional services',
          timeout: const Duration(seconds: 10),
          body: FirebaseService.I.initialize,
        ),
        _startupTask(
          id: 'github.initialize',
          kind: StartupItemKind.marketplace,
          label: 'Restore GitHub connection',
          timeout: const Duration(seconds: 20),
          body: GitHubService.I.initialize,
        ),
        _startupTask(
          id: 'sandbox.selfHeal',
          kind: StartupItemKind.sandbox,
          label: 'Maintain local sandbox',
          timeout: const Duration(seconds: 30),
          body: _runSandboxMaintenance,
        ),
      ]);

  Future<void> initializeReadiness() =>
      _readinessInitialization ??= _initializeReadiness();

  Future<void> _initializeReadiness() async {
    _readinessStarted = true;
    if (!_readinessStartedSignal.isCompleted) {
      _readinessStartedSignal.complete();
    }
    await initializeForFirstFrame();
    final tasks = await buildReadinessTasks();
    try {
      await StartupCoordinator.I.start(tasks);
    } finally {
      _readinessComplete = true;
    }
  }

  StartupTask _startupTask({
    required String id,
    required StartupItemKind kind,
    required String label,
    required Duration timeout,
    required StartupStageDelegate body,
  }) => _AppStartupTask(
    id: id,
    kind: kind,
    label: label,
    timeout: _startupTimeout(id, timeout),
    runStage: () => _runStartupStage(id, body),
  );

  Duration _startupTimeout(String id, Duration fallback) =>
      _startupStageTimeouts[id] ?? fallback;

  Future<void> _runStartupStage(String id, StartupStageDelegate body) async {
    _startupStageRecorder?.call(id);
    await (_startupStageDelegates[id] ?? body)();
  }

  Future<void> _hydrateRemainingLocalState() async {
    await loadProviderCredentials();
    await loadSessions();
    await _loadUsage();
    // Custom MCP servers + plugin install state survive restarts.
    await _loadCustomMcpServers();
    await _loadCustomPlugins();
    await _loadCustomPresets();
    await _loadMarketplaces();
    await PluginRuntimeManager.I.restoreCanonicalRows();
    await restoreMergedMarketplaceCatalog();
    await _loadPluginState();
    await _loadMemories();
    await HookService.I.loadEnabled();
  }

  Future<void> _reconcilePluginSafety() async {
    final existing = _pluginSafetyReconciliation;
    if (existing != null) {
      await existing;
      return;
    }
    late final Future<List<StartupItemStatus>> attempt;
    attempt = PluginRuntimeManager.I.reconcileRowsAndGrants().catchError((
      Object error,
      StackTrace stack,
    ) {
      if (identical(_pluginSafetyReconciliation, attempt)) {
        _pluginSafetyReconciliation = null;
      }
      Error.throwWithStackTrace(error, stack);
    });
    _pluginSafetyReconciliation = attempt;
    _pluginSafetyStatuses = await attempt;
    _pluginSafetyReconciled = true;
  }

  Future<void> _activatePluginsForBoot() async {
    await _reconcilePluginSafety();
    if (_pluginBootActivated) return;
    final existing = _pluginBootActivation;
    if (existing != null) {
      await existing;
      return;
    }
    late final Future<void> attempt;
    attempt = _pluginBootActivator(_bootToken, false)
        .then<void>((_) => _pluginBootActivated = true)
        .whenComplete(() {
          if (identical(_pluginBootActivation, attempt)) {
            _pluginBootActivation = null;
          }
        });
    _pluginBootActivation = attempt;
    await attempt;
    await _maybeFinishSessionRestore();
  }

  Future<void> _mountRuntimeSkills() async {
    for (final session in List<ChatSession>.of(sessions)) {
      await AgentService.I.refreshSkills(sessionId: session.id);
    }
  }

  Future<bool> _maybeFinishSessionRestore() async {
    if (_sessionRestoreFinished) return true;
    if (!_sessionRestoreRequested ||
        !_localHydrationSettled ||
        !_localHydrationReady ||
        !_pluginBootActivated ||
        !_skillMountSettled ||
        !_skillMountSucceeded) {
      return false;
    }
    await AgentService.I.restoreRunCheckpoints();
    onSessionsLoaded?.call();
    _sessionRestoreFinished = true;
    return true;
  }

  bool get startupSafeToReconnect =>
      _readinessComplete && !StartupCoordinator.I.hasActiveInvocations;

  Future<void> reconnectServicesAfterResume() {
    if (startupSafeToReconnect) return _runResumeReconnect();
    return _pendingResumeReconnect ??= _reconnectWhenStartupSettles();
  }

  Future<void> _reconnectWhenStartupSettles() async {
    try {
      if (!_readinessStarted) await _readinessStartedSignal.future;
      await (_readinessInitialization ?? Future<void>.value());
      while (!startupSafeToReconnect) {
        await StartupCoordinator.I.whenInvocationsSettled();
      }
      await _runResumeReconnect();
    } finally {
      _pendingResumeReconnect = null;
    }
  }

  Future<void> _runResumeReconnect() async {
    const stage = 'mcp.resume';
    _startupStageRecorder?.call(stage);
    final delegate = _startupStageDelegates[stage];
    if (delegate != null) {
      await delegate();
    } else {
      await reconnectServices();
    }
  }

  Future<void> _runSandboxMaintenance() async {
    if (!sandboxInstalled) return;
    await SandboxService.I.selfHealInBackground();
    unawaited(AgentService.I.prewarmBrowser());
    if (!await SandboxService.I.runtimesVerified()) {
      await SandboxService.I.installCoreRuntimes((_, _, _) {});
    }
    await SandboxService.I.enforceWorkspaceQuota(
      activeSandboxIds: sessions
          .map((session) => session.sandboxId)
          .whereType<String>()
          .toSet(),
    );
  }

  Future<void> _loadShellPreferences() async {
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
      workflowEnabled = prefs.getBool(_kWorkflowEnabled) ?? true;
      browserDesktopMode = prefs.getBool(_kBrowserDesktopMode) ?? false;
      autoRunSafeCommands = prefs.getBool(_kAutoRunSafe) ?? true;
      sandboxSkipped = prefs.getBool(_kSandboxSkipped) ?? false;
      localePref = prefs.getString(_kLocale) ?? 'system';
      seenWelcomeVersion = prefs.getString(_kWelcome) ?? '';
      _keepAliveEnabled = prefs.getBool(_kKeepAlivePref) ?? true;
      chatFontScale = (prefs.getDouble(_kChatFontScale) ?? 1.0).clamp(
        chatFontScaleMin,
        chatFontScaleMax,
      );
    } catch (_) {}
  }

  /// Last model the user picked — carried into new sessions (Ovid-style
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
  static const _kSessionBootstrap = 'ovid_session_bootstrap_v1';
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
    if (_deferredSessionJson != null || _deferredSessionsPending) {
      await _hydrateDeferredSessions();
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kSessions);
      if (raw != null && raw.isNotEmpty) {
        final loaded = raw.map(_decodeSessionSync).toList();
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

  static const _firstFrameMessageTailSize = _sessionBootstrapTailSize;

  ChatSession _decodeSessionSync(String encoded) =>
      (_persistedSessionDecoderForTest ?? _decodePersistedSession)(encoded);

  Future<ChatSession> _decodeSessionForFirstFrame(String encoded) {
    final override = _persistedSessionDecoderForTest;
    if (override != null) return Future.value(override(encoded));
    return Isolate.run(() => _decodePersistedSessionTail(encoded));
  }

  String? _activeRawSession(List<String> raw, String? activeId) {
    if (activeId == null) return null;
    final prefix = '{"id":${jsonEncode(activeId)},';
    return raw.where((encoded) => encoded.startsWith(prefix)).firstOrNull;
  }

  Future<void> _loadSessionsForFirstFrame() async {
    List<String>? raw;
    try {
      final prefs = await SharedPreferences.getInstance();
      final requestedActiveId = prefs.getString(_kActive);
      raw = prefs.getStringList(_kSessions);
      final requestedActiveRaw = _activeRawSession(
        raw ?? const [],
        requestedActiveId,
      );
      final cached = prefs.getString(_kSessionBootstrap);
      if (cached != null &&
          requestedActiveId != null &&
          requestedActiveRaw != null) {
        try {
          final envelope = _sessionBootstrapDecoder(cached);
          final fingerprint = await Isolate.run(
            () => _sessionSourceFingerprint(requestedActiveRaw),
          );
          if (envelope['version'] != 1 ||
              envelope['sourceFingerprint'] != fingerprint) {
            throw const FormatException('stale session bootstrap');
          }
          final active = ChatSession.fromJson(
            (envelope['session'] as Map).cast<String, dynamic>(),
          );
          if (active.id == requestedActiveId && !active.isSubagent) {
            _setFirstFrameActiveSession(active);
            _deferredSessionJson = List<String>.of(raw!);
            return;
          }
        } catch (_) {
          _startupStageRecorder?.call('local.firstFrame.bootstrapCorrupt');
        }
      }

      if (raw == null || raw.isEmpty) {
        activeSessionId = requestedActiveId;
        _ensureActiveSession();
        return;
      }

      _deferredSessionJson = List<String>.of(raw);
      Map<String, dynamic>? activeJson;
      if (requestedActiveId != null) {
        final idPrefix = '{"id":${jsonEncode(requestedActiveId)},';
        for (final encoded in raw) {
          if (!encoded.startsWith(idPrefix)) continue;
          try {
            final candidate = await _decodeSessionForFirstFrame(encoded);
            if (candidate.id == requestedActiveId && !candidate.isSubagent) {
              activeJson = candidate.toJson();
              break;
            }
          } catch (_) {
            continue;
          }
        }
      }
      if (activeJson == null) {
        for (final encoded in raw) {
          try {
            final candidate = await _decodeSessionForFirstFrame(encoded);
            if (!candidate.isSubagent) {
              activeJson = candidate.toJson();
              break;
            }
          } catch (_) {
            continue;
          }
        }
        if (activeJson == null) {
          _startupStageRecorder?.call('local.firstFrame.noRoot');
          _ensureActiveSession();
          return;
        }
      }
      final messages = (activeJson['messages'] as List?) ?? const [];
      final tailStart = messages.length > _firstFrameMessageTailSize
          ? messages.length - _firstFrameMessageTailSize
          : 0;
      final tailJson = Map<String, dynamic>.from(activeJson)
        ..['messages'] = messages.sublist(tailStart);
      final active = ChatSession.fromJson(tailJson);
      _setFirstFrameActiveSession(active);
      if (requestedActiveId != active.id) {
        await prefs.setString(_kActive, active.id);
      }
      await _writeSessionBootstrapFromSession(
        prefs,
        active,
        _activeRawSession(raw, active.id),
      );
    } catch (_) {
      if (raw != null) {
        _deferredSessionJson ??= List<String>.of(raw);
      }
      _startupStageRecorder?.call('local.firstFrame.corrupt');
      _ensureActiveSession();
    }
  }

  void _setFirstFrameActiveSession(ChatSession active) {
    sessions
      ..clear()
      ..add(active);
    activeSessionId = active.id;
    _deferredActiveSessionId = active.id;
    _deferredActiveTailLength = active.messages.length;
    notifyListeners();
  }

  Future<void> _loadDeferredSessionSnapshot() async {
    if (!_deferredSessionsPending) return;
    final generation = _deferredSessionGeneration;
    final prefs = await SharedPreferences.getInstance();
    if (generation != _deferredSessionGeneration || !_deferredSessionsPending) {
      return;
    }
    _deferredSessionJson = List<String>.of(
      prefs.getStringList(_kSessions) ?? const [],
    );
    _deferredSessionsPending = false;
    _expandDeferredDeletedSessionIds();
  }

  void _expandDeferredDeletedSessionIds() {
    final raw = _deferredSessionJson;
    if (raw == null || _deferredDeletedSessionIds.isEmpty) return;
    var changed = true;
    while (changed) {
      changed = false;
      for (final encoded in raw) {
        try {
          final json = jsonDecode(encoded) as Map<String, dynamic>;
          final id = json['id'] as String?;
          final parentId = json['parentId'] as String?;
          if (id != null) {
            if (parentId != null &&
                _deferredDeletedSessionIds.contains(parentId) &&
                _deferredDeletedSessionIds.add(id)) {
              changed = true;
            }
            if (_deferredDeletedSessionIds.contains(id)) {
              final rawSandboxId = json['sandboxId'];
              final sandboxId =
                  rawSandboxId is String && rawSandboxId.isNotEmpty
                  ? rawSandboxId
                  : id;
              _scheduleSessionDeletion(id, sandboxId);
            }
          }
        } catch (_) {}
      }
    }
  }

  void _scheduleSessionDeletion(String id, String? sandboxId) {
    if (!_notifiedDeletedSessionIds.add(id)) return;
    onSessionDeleted?.call(id);
    if (sandboxId != null) {
      _pendingWorkspaceDeletions.add(_workspaceDeleter(sandboxId));
    }
  }

  Future<void> _awaitWorkspaceDeletions() async {
    while (_pendingWorkspaceDeletions.isNotEmpty) {
      final pending = List<Future<void>>.of(_pendingWorkspaceDeletions);
      _pendingWorkspaceDeletions.removeRange(0, pending.length);
      await Future.wait(pending);
    }
  }

  Future<void> _hydrateDeferredSessions() async {
    await _loadDeferredSessionSnapshot();
    final raw = _deferredSessionJson;
    if (raw == null) return;
    final generation = _deferredSessionGeneration;
    final current = {for (final session in sessions) session.id: session};
    final loaded = <ChatSession>[];
    final unparsed = <String>[];
    for (var index = 0; index < raw.length; index++) {
      if (generation != _deferredSessionGeneration) return;
      final encoded = raw[index];
      try {
        final fullJson = jsonDecode(encoded) as Map<String, dynamic>;
        final id = fullJson['id'] as String?;
        if (id == null || _deferredDeletedSessionIds.contains(id)) continue;
        final partial = current.remove(id);
        if (partial != null && id == _deferredActiveSessionId) {
          loaded.add(_mergeDeferredActiveSession(fullJson, partial));
        } else {
          loaded.add(ChatSession.fromJson(fullJson));
        }
      } catch (_) {
        unparsed.add(encoded);
        _startupStageRecorder?.call('local.hydrate.corrupt');
      }
      if (index % 20 == 19) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (generation != _deferredSessionGeneration) return;
    loaded.removeWhere(
      (session) => _deferredDeletedSessionIds.contains(session.id),
    );
    current.removeWhere((id, _) => _deferredDeletedSessionIds.contains(id));
    loaded.addAll(current.values);
    sessions
      ..clear()
      ..addAll(loaded);
    _unparsedSessionJson
      ..clear()
      ..addAll(unparsed);
    _deferredSessionJson = null;
    _deferredActiveSessionId = null;
    _deferredActiveTailLength = 0;
    _deferredDeletedSessionIds.clear();
    final active = sessionById(activeSessionId);
    if (active == null || active.isSubagent) {
      activeSessionId = rootSessions.firstOrNull?.id;
    }
    for (final session in sessions) {
      session.providerId ??= _inferProviderId(session.model);
    }
    _restoreSelectedModel();
    notifyListeners();
  }

  ChatSession _mergeDeferredActiveSession(
    Map<String, dynamic> fullJson,
    ChatSession partial,
  ) {
    final oldMessages = List<dynamic>.of(
      (fullJson['messages'] as List?) ?? const [],
    );
    final prefixLength = (oldMessages.length - _deferredActiveTailLength).clamp(
      0,
      oldMessages.length,
    );
    final merged = Map<String, dynamic>.from(fullJson)
      ..addAll(partial.toJson())
      ..['messages'] = [
        ...oldMessages.take(prefixLength),
        ...partial.messages.map((message) => message.toJson()),
      ];
    return ChatSession.fromJson(merged);
  }

  Future<void> persistSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _loadDeferredSessionSnapshot();
      final encoded = _sessionJsonForPersistence();
      final active = activeSession;
      final activeRaw = _activeRawSession(encoded, active?.id);
      // The cache is a derivative of exact session-list truth. Either interrupted
      // write order produces a fingerprint mismatch and a safe fallback.
      try {
        await _writeSessionBootstrapFromSession(prefs, active, activeRaw);
      } catch (_) {}
      await prefs.setStringList(_kSessions, encoded);
      if (activeSessionId != null) {
        await prefs.setString(_kActive, activeSessionId!);
      } else {
        await prefs.remove(_kActive);
      }
      await _awaitWorkspaceDeletions();
    } catch (_) {}
  }

  Future<void> _writeSessionBootstrapFromSession(
    SharedPreferences prefs,
    ChatSession? active,
    String? activeRaw,
  ) async {
    if (active == null || active.isSubagent || activeRaw == null) {
      await prefs.remove(_kSessionBootstrap);
      return;
    }
    final json = active.toJson();
    final messages = json['messages'] as List;
    final tailStart = messages.length > _firstFrameMessageTailSize
        ? messages.length - _firstFrameMessageTailSize
        : 0;
    json['messages'] = messages.sublist(tailStart);
    await prefs.setString(
      _kSessionBootstrap,
      jsonEncode({
        'version': 1,
        'sourceFingerprint': _sessionSourceFingerprint(activeRaw),
        'session': json,
      }),
    );
  }

  List<String> _sessionJsonForPersistence() {
    final raw = _deferredSessionJson;
    if (raw == null) {
      return [
        ...sessions.map((session) => jsonEncode(session.toJson())),
        ..._unparsedSessionJson,
      ];
    }
    final current = {for (final session in sessions) session.id: session};
    final encoded = <String>[];
    for (final original in raw) {
      try {
        final fullJson = jsonDecode(original) as Map<String, dynamic>;
        final id = fullJson['id'] as String?;
        if (id != null && _deferredDeletedSessionIds.contains(id)) continue;
        final partial = id == null ? null : current.remove(id);
        if (partial != null && id == _deferredActiveSessionId) {
          encoded.add(
            jsonEncode(_mergeDeferredActiveSession(fullJson, partial).toJson()),
          );
        } else {
          encoded.add(original);
        }
      } catch (_) {
        encoded.add(original);
      }
    }
    encoded.addAll(
      current.values.map((session) => jsonEncode(session.toJson())),
    );
    return encoded;
  }

  void _clearDeferredSessions() {
    _deferredSessionGeneration++;
    _deferredSessionJson = null;
    _deferredSessionsPending = false;
    _deferredActiveSessionId = null;
    _deferredActiveTailLength = 0;
    _deferredDeletedSessionIds.clear();
    _unparsedSessionJson.clear();
  }

  /// Delete all user data: sessions, workspaces, providers, keys, plugin
  /// state, usage log, memories, and app preferences. Resets in-memory
  /// state to defaults and seeds a fresh session.
  Future<void> deleteAllData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      _clearDeferredSessions();
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
      workflowEnabled = true;
      browserDesktopMode = false;
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

  /// User chose to run WITHOUT the sandbox (device can't support it) —
  /// the first-launch gate must not trap them out of the app. Cleared
  /// automatically when an install later succeeds.
  bool sandboxSkipped = false;
  static const _kSandboxSkipped = 'ovid_sandbox_skipped';

  Future<void> setSandboxSkipped(bool v) async {
    sandboxSkipped = v;
    refresh();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (v) {
        await prefs.setBool(_kSandboxSkipped, true);
      } else {
        await prefs.remove(_kSandboxSkipped);
      }
    } catch (_) {}
  }

  /// Share memory across sessions (persisted, default OFF).
  ///
  /// OFF → the AI only sees the current session's messages/workspace.
  /// ON  → the AI (via memory_search) can search across ALL sessions' chat
  /// history ("poori app history", user-opted).
  static const _kShareMemory = 'ovid_share_session_memory';
  static const _kCustomMcpServers = 'ovid_custom_mcp_servers_v1';
  static const _kPluginState = 'ovid_plugin_state_v1';
  static const _kCustomPresets = 'ovid_custom_presets';
  static const _kMcpEnvPrefix = 'ovid_mcp_env_';
  bool shareSessionMemory = false;

  // ── Light/dark theme (the theme controller light/dark preference parity) ──
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

  /// Workflow orchestration tools (workflow/ralph): multi-agent fan-out.
  /// Off = those tools leave the roster entirely.
  static const _kWorkflowEnabled = 'ovid_workflow_enabled';
  bool workflowEnabled = true;

  /// PR27/B3: default browser mode — false = MOBILE viewport (default),
  /// true = DESKTOP logical viewport (1280px wide via zoom). New tabs
  /// apply it at controller creation; browser_resize still overrides
  /// per-call.
  static const _kBrowserDesktopMode = 'ovid_browser_desktop_mode';
  bool browserDesktopMode = false;

  /// Auto-run safe commands: read-only shell commands skip confirmation.
  static const _kAutoRunSafe = 'ovid_auto_run_safe';
  bool autoRunSafeCommands = true;

  static const _kKeepAlivePref = 'ovid_keep_alive';
  bool _keepAliveEnabled = true;
  bool get keepAliveEnabled => _keepAliveEnabled;
  set keepAliveEnabled(bool v) {
    if (_keepAliveEnabled == v) return;
    _keepAliveEnabled = v;
    unawaited(_saveKeepAlivePref(v));
    if (!v) {
      AgentNotificationService.I.agentIdle();
    }
    notifyListeners();
  }

  Future<void> _saveKeepAlivePref(bool v) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kKeepAlivePref, v);
    } catch (_) {}
  }

  // ── Locale preference (the locale coordinator client-locale parity: zh/en reply language) ──
  // 'system' follows the device language; 'en'/'zh' pin the reply hint.
  static const _kLocale = 'ovid_locale';
  String localePref = 'system';

  Future<void> setLocalePref(String v) async {
    if (v != 'system' && v != 'en' && v != 'zh') return;
    localePref = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLocale, v);
    } catch (_) {}
  }

  /// System-prompt line for the locale pref (empty = default English).
  String replyLanguageHint() {
    switch (localePref) {
      case 'zh':
        return 'REPLY LANGUAGE: reply in Chinese (简体中文) unless the user writes in another language.';
      case 'en':
        return 'REPLY LANGUAGE: reply in English unless the user writes in another language.';
      default:
        return '';
    }
  }

  // ── First-run welcome notice (the onboarding flow welcomeNoticeVersion) ──
  static const _kWelcome = 'ovid_welcome';
  static const welcomeVersion = '2026-09-05.1';
  String seenWelcomeVersion = '';

  bool get welcomeSeen => seenWelcomeVersion == welcomeVersion;

  Future<void> markWelcomeSeen() async {
    seenWelcomeVersion = welcomeVersion;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kWelcome, welcomeVersion);
    } catch (_) {}
  }

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

  Future<void> setWorkflowEnabled(bool v) async {
    workflowEnabled = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kWorkflowEnabled, v);
    } catch (_) {}
  }

  Future<void> setBrowserDesktopMode(bool v) async {
    browserDesktopMode = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kBrowserDesktopMode, v);
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

  // ── Context window + output caps (user-configurable, settings) ─
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
  final Map<String, ServiceStatus> serviceStatus = {};

  void updateServiceStatus(
    String key,
    ServiceHealth health, {
    String detail = '',
  }) {
    serviceStatus[key] = ServiceStatus(
      health: health,
      detail: detail,
      updatedAt: DateTime.now(),
    );
    notifyListeners();
  }

  @visibleForTesting
  ServiceStatus? serviceStatusForTest(String key) => serviceStatus[key];

  final List<String> marketplaces =
      []; // user-added git marketplaces (Claude Code style)
  final List<ChatSession> sessions = [];
  String? activeSessionId;

  /// Durable memories saved via memory_save — survive across sessions
  /// (the persistent memory store memory tool equivalent).  Persisted as JSON in SharedPreferences.
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
    String persona = '',
    String outputSchemaHint = '',
  }) {
    final child = ChatSession(
      id: 'sub-${DateTime.now().microsecondsSinceEpoch}',
      title: label.isEmpty ? 'Subagent' : label,
      model: parent.model,
      providerId: parent.providerId,
      mode: mode,
      presetId: parent.presetId,
      parentId: parent.id,
      agentLabel: label,
      agentState: 'running',
      agentContinuable: continuable,
      agentAllowedTools: allowedTools,
      agentPersona: persona,
      agentOutputHint: outputSchemaHint,
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
    // PR23/M1: workspace exists from the first moment (see newSession).
    _warmWorkspace(session.id);
    return session;
  }

  void setNav(int i) {
    navIndex = i;
    notifyListeners();
  }

  void selectSession(String id) {
    activeSessionId = id;
    // NOTE: runs are per-session (parallel) — switching NEVER stops a
    // running session (the session scheduler multi-session behavior).  Lazy-restore the
    // newly-active session's browser tabs (per-session browsers).
    onSessionSwitched?.call(id);
    // PR23/M1: make sure the workspace dir exists for the mention menu.
    _warmWorkspace(id);
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
    // PR23/M1: the @file mention menu lists workspace files — the dir
    // must exist BEFORE the first agent run, else the menu is empty and
    // "@" looks dead. Best-effort warm-up.
    _warmWorkspace(s.id);
    // No provider.selectedModel mutation here — the provider field is
    // shared. Session A's in-flight run must never observe a model
    // selection that came from creating/switching to session B.
    notifyListeners();
    persistSessions();
  }

  /// Ensure a session's workspace dir exists (mention menu + agent runs
  /// both rely on it). Best-effort + async — never blocks UI.
  void _warmWorkspace(String sessionId) {
    unawaited(() async {
      try {
        await SandboxService.I.workDirFor(sessionId);
      } catch (_) {}
    }());
  }

  void deleteSession(String id) {
    final s = sessions.where((x) => x.id == id).firstOrNull;
    // A chat owns its subagents: deleting it deletes their transcripts and
    // workspaces too, otherwise orphan children linger invisibly forever.
    final doomed = <ChatSession>[?s, ...descendantsOf(id)];
    if (_deferredSessionJson != null || _deferredSessionsPending) {
      _deferredDeletedSessionIds.add(id);
      _expandDeferredDeletedSessionIds();
    }
    sessions.removeWhere((x) => doomed.any((d) => d.id == x.id));
    if (activeSessionId == null || doomed.any((d) => d.id == activeSessionId)) {
      activeSessionId = rootSessions.isEmpty ? null : rootSessions.first.id;
    }
    for (final dead in doomed) {
      _scheduleSessionDeletion(dead.id, dead.sandboxId);
    }
    notifyListeners();
    persistSessions();
  }

  /// Set by AgentService at startup — drops the deleted session's run
  /// (avoids a circular import; parallel runs for other sessions live on).
  void Function(String sessionId)? onSessionDeleted;

  /// Called once after sessions load from disk — the agent service
  /// rebuilds its subagent handle registry from persisted lineage.
  void Function()? onSessionsLoaded;

  /// Remove all messages from [index] onward in the named session
  /// (the session revert action "Revert"/"Edit & resend" semantics). Clearing from index 0 also
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

  /// Replace the content of an existing message (the message editor "Edit" of a user turn).
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
    // A successful install revokes any earlier "continue without sandbox".
    if (sandboxInstalled && sandboxSkipped) {
      sandboxSkipped = false;
      unawaited(setSandboxSkipped(false));
    }
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

  Future<void> removeMarketplace(String repo) async {
    final normalized = normalizeMarketplace(repo);
    marketplaces.remove(repo);
    marketplaces.remove(normalized);
    _fetchedMarketplaces.remove(repo);
    _fetchedMarketplaces.remove(normalized);
    await _persistMarketplaces();

    // Prune merged plugins belonging to this marketplace
    final toRemovePlugins = plugins
        .where(
          (p) =>
              p.marketplace == repo ||
              p.marketplace == normalized ||
              p.source == repo ||
              p.source == normalized,
        )
        .toList();
    for (final p in toRemovePlugins) {
      if (p.installed) {
        await uninstallPlugin(p);
      }
      plugins.remove(p);
    }

    // Prune merged MCP servers belonging to this marketplace
    final toRemoveMcps = mcpServers
        .where(
          (s) =>
              s.source == 'marketplace:$repo' ||
              s.source == 'marketplace:$normalized',
        )
        .toList();
    for (final s in toRemoveMcps) {
      if (s.connected) {
        try {
          await McpService.I.disconnect(s.canonicalId);
        } catch (_) {}
      }
      mcpServers.remove(s);
    }

    await _persistPluginState();
    await persistMergedMarketplaceCatalog();
    await _persistCustomMcpServers();
    refresh();
  }

  Future<void> _persistMarketplaces() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kMarketplaces, marketplaces);
    } catch (_) {}
  }

  static const _kMarketplaceMerged = 'ovid_marketplace_merged_v1';

  Future<void> persistMergedMarketplaceCatalog({
    bool reportFailure = false,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rows = plugins
          .where(
            (p) =>
                p.runtimeId == null &&
                (p.source != null || p.marketplace != null),
          )
          .toList();
      final written = await prefs.setString(
        _kMarketplaceMerged,
        jsonEncode(rows.map((e) => e.toJson()).toList()),
      );
      if (!written && reportFailure) {
        throw StateError('Failed to persist legacy marketplace rows');
      }
    } catch (error, stack) {
      if (reportFailure) Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> restoreMergedMarketplaceCatalog() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kMarketplaceMerged);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw);
      if (list is List) {
        for (final item in list) {
          if (item is! Map) continue;
          final p = PluginItem.fromJson(item.cast<String, dynamic>());
          if (p.runtimeId != null) {
            final idx = plugins.indexWhere((e) => e.runtimeId == p.runtimeId);
            if (idx >= 0) {
              plugins[idx] = _mergeRuntimeDisplayMetadata(plugins[idx], p);
            }
            continue;
          }
          final idx = plugins.indexWhere(
            (e) => e.runtimeId == null && e.name == p.name,
          );
          if (idx < 0) {
            plugins.add(p);
          } else {
            if (plugins[idx].source == null && p.source != null) {
              plugins[idx].source = p.source;
            }
          }
        }
      }
      refresh();
    } catch (_) {}
  }

  static PluginItem _mergeRuntimeDisplayMetadata(
    PluginItem runtime,
    PluginItem metadata,
  ) {
    final useMetadataInstalls =
        !runtime.installsKnown && metadata.installsKnown;
    return PluginItem(
      name: runtime.name.isNotEmpty ? runtime.name : metadata.name,
      author: runtime.author.isNotEmpty ? runtime.author : metadata.author,
      description: runtime.description.isNotEmpty
          ? runtime.description
          : metadata.description,
      version: runtime.version,
      category: runtime.category.isNotEmpty
          ? runtime.category
          : metadata.category,
      installed: runtime.installed,
      enabled: runtime.enabled,
      installs: useMetadataInstalls ? metadata.installs : runtime.installs,
      installsKnown: runtime.installsKnown || metadata.installsKnown,
      hooks: runtime.hooks,
      hookMatchers: runtime.hookMatchers,
      pluginHooks: runtime.pluginHooks,
      source: runtime.source ?? metadata.source,
      marketplace: runtime.marketplace ?? metadata.marketplace,
      runtimeId: runtime.runtimeId,
      activation: runtime.activation,
      immediateSessionId: runtime.immediateSessionId,
      promoteOnNextBoot: runtime.promoteOnNextBoot,
      manifestDigest: runtime.manifestDigest,
      compatibilityWarnings: runtime.compatibilityWarnings,
      migrationRequired: runtime.migrationRequired,
      runtimeReason: runtime.runtimeReason,
    );
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
        for (final path in paths) '$marketplaceBaseOverrideForTest/$path',
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

  /// Test seam: when set, plugin-content fetches try this base (a local
  /// mock server) instead of GitHub's tree/raw APIs.
  @visibleForTesting
  static String? pluginContentBaseOverrideForTest;

  /// PR44 test seam: override the plugin-content cache root so tests can
  /// pre-write a `.mcp.json` without touching real documents dir.
  static Directory? pluginCacheRootOverrideForTest;

  /// Local cache root for fetched plugin content — one directory per
  /// `owner_repo`, holding whatever `commands/`/`skills/` it fetched.
  /// Public so the UI (uninstall) and tests can resolve the same path.
  Future<Directory> pluginCacheDirFor(String source) async {
    final safe = source.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    if (pluginCacheRootOverrideForTest != null) {
      return Directory(
        '${pluginCacheRootOverrideForTest!.path}/plugin-content/$safe',
      );
    }
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    return Directory('${base.path}/plugin-content/$safe');
  }

  /// PR40: fetch [source]'s (`owner/repo`) OWN `commands/*.md` and
  /// `skills/*/SKILL.md` — the actual capability a Claude-Code-shaped
  /// plugin contributes, as opposed to the one-line description the
  /// marketplace listing carries. Cached under [pluginCacheDirFor]; a
  /// plugin with neither directory fetches nothing and mounts nothing
  /// (not every plugin has model-visible content — some are MCP-only or
  /// hook-only, which already work through their own paths).
  ///
  /// Task 3 delegates the network work to [PluginSourceResolver]: the
  /// repo is resolved into app-private staging (unauthenticated GitHub
  /// tree API + raw fetches, same shape as [fetchMarketplaceCatalog]),
  /// then this method copies the legacy selective allowlist subset into
  /// the plugin-content cache and discards staging. Returns the number
  /// of files cached (0 on any failure — best-effort, install must never
  /// hard-fail because a plugin repo is unreachable).
  Future<int> fetchPluginContent(String source) async {
    final parts = source.split('/');
    if (parts.length < 2) return 0;
    final owner = parts[0];
    final repo = parts[1];
    final cacheDir = await pluginCacheDirFor(source);

    // If source is owner/repo/raw/branch/path, extract subpath + pinned ref
    String? subPath;
    String? ref;
    if (parts.length >= 4 && parts[2] == 'raw') {
      if (parts[3] != 'branch' && parts[3].isNotEmpty) ref = parts[3];
      if (parts.length > 4) {
        final sp = parts.sublist(4).join('/');
        if (sp.isNotEmpty) subPath = sp;
      }
    }

    final resolver = PluginSourceResolver(
      stagingRootOverride: pluginCacheRootOverrideForTest,
      githubBaseOverride: pluginContentBaseOverrideForTest,
    );
    ResolvedPluginSource? resolved;
    try {
      resolved = await resolver.resolve(
        GithubPluginSource(
          owner: owner,
          repo: repo,
          ref: ref,
          subPath: subPath,
          include: _isLegacyPluginContentPath,
        ),
      );
    } catch (_) {
      return 0;
    }
    try {
      var fetched = 0;
      final staged = resolved.stagingDir.listSync(
        recursive: true,
        followLinks: false,
      );
      for (final entity in staged) {
        if (entity is! File) continue;
        final rel = entity.path.substring(resolved.stagingDir.path.length + 1);
        final target = File('${cacheDir.path}/$rel');
        try {
          target.parent.createSync(recursive: true);
          // Streaming byte-identical copy — no payload materialization in
          // memory; the resolver never modifies content.
          entity.copySync(target.path);
          fetched++;
        } catch (_) {
          continue;
        }
      }
      return fetched;
    } catch (_) {
      return 0;
    } finally {
      resolved.discard();
    }
  }

  /// The legacy selective allowlist for the plugin-content cache (PR40 +
  /// PR44 behavior): the files the chat/skills/hook mounts consume from
  /// a fetched plugin repo.
  static bool _isLegacyPluginContentPath(String relPath) {
    return relPath.startsWith('commands/') ||
        (relPath.startsWith('skills/') && relPath.endsWith('SKILL.md')) ||
        (relPath.startsWith('agents/') && relPath.endsWith('.md')) ||
        relPath == 'hooks/hooks.json' ||
        relPath == '.claude-plugin/plugin.json' ||
        relPath == '.mcp.json';
  }

  /// Mount and optionally connect every MCP declaration in a normalized
  /// plugin manifest. Ownership, secrets, process slots, and reconnect state
  /// all use `<plugin-id>/<server-name>`; [McpServer.name] stays source-local
  /// for display and persisted compatibility.
  Future<int> mountPluginOwnedMcpServers(
    NormalizedPluginManifest manifest, {
    bool connect = true,
  }) async {
    var mounted = 0;
    final declaredIds = {
      if (isCanonicalPluginId(manifest.id))
        for (final server in manifest.mcpServers)
          '${manifest.id}/${server.name}',
    };
    if (!isCanonicalPluginId(manifest.id)) return 0;
    final removed = mcpServers
        .where(
          (server) =>
              server.ownerPluginId == manifest.id &&
              !declaredIds.contains(server.canonicalId),
        )
        .toList();
    for (final server in removed) {
      await McpService.I.disconnect(server.canonicalId);
      await Future.wait([
        deleteMcpEnv(server.canonicalId),
        deleteMcpHeaders(server.canonicalId),
      ]);
      serviceStatus.remove('mcp:${server.canonicalId}');
      mcpServers.remove(server);
    }
    for (final declared in manifest.mcpServers) {
      final canonicalId = '${manifest.id}/${declared.name}';
      var server = mcpServers
          .where((s) => s.canonicalId == canonicalId)
          .firstOrNull;
      String? cwd;
      final declaredCwd = declared.cwd;
      if (declaredCwd == null || declaredCwd.isEmpty) {
        cwd = manifest.rootPath;
      } else if (isLexicallySafeRelPath(declaredCwd)) {
        cwd = '${manifest.rootPath}/$declaredCwd';
      }
      final contentDir = Directory(manifest.rootPath);
      if (server == null) {
        server = McpServer(
          name: declared.name,
          ownerPluginId: manifest.id,
          author: manifest.id.split('/').first,
          description: 'declared by plugin ${manifest.id}',
          category: 'Plugin',
          command: declared.command,
          args: declared.args,
          source: 'plugin:${manifest.id}',
          custom: true,
          transport: declared.transport,
          url: declared.url,
          headers: await getMcpHeaders(canonicalId),
          requiredEnvNames: declared.envNames,
          requiredHeaderNames: declared.headerNames,
          cwd: cwd,
          pluginRuntimeRoot: contentDir.parent.path,
        );
        mcpServers.add(server);
        mounted++;
      } else {
        await McpService.I.disconnect(server.canonicalId);
        server.command = declared.command;
        server.args = declared.args;
        server.transport = declared.transport;
        server.url = declared.url;
        server.cwd = cwd;
        server.pluginRuntimeRoot = contentDir.parent.path;
        server.requiredEnvNames = List.unmodifiable(declared.envNames);
        server.requiredHeaderNames = List.unmodifiable(declared.headerNames);
        server.headers = await getMcpHeaders(canonicalId);
      }
      if (!connect) continue;
      final status = await McpService.I.connect(server);
      server.connected = McpService.I.isConnected(server.canonicalId);
      updateServiceStatus(
        'mcp:${server.canonicalId}',
        server.connected ? ServiceHealth.working : ServiceHealth.failed,
        detail: status,
      );
    }
    if (mounted > 0 || removed.isNotEmpty) await _persistCustomMcpServers();
    if (connect) await _persistMcpConnectedIntent();
    if (mounted > 0 || removed.isNotEmpty || connect) refresh();
    return mounted;
  }

  Future<void> unmountPluginOwnedMcpServers(
    String pluginId, {
    required bool uninstall,
  }) async {
    final owned = mcpServers.where((s) => s.ownerPluginId == pluginId).toList();
    for (final server in owned) {
      server.connected = false;
      await McpService.I.disconnect(server.canonicalId);
      if (uninstall) {
        await Future.wait([
          deleteMcpEnv(server.canonicalId),
          deleteMcpHeaders(server.canonicalId),
        ]);
        mcpServers.remove(server);
      }
    }
    await _persistCustomMcpServers();
    await _persistMcpConnectedIntent();
    if (owned.isNotEmpty) refresh();
  }

  /// P3 (the MCP config parser plugin .mcp.json parity): read the plugin's `.mcp.json` from
  /// its cache dir and register the declared `mcpServers` as connected-
  /// intent items (so plugins shipping MCP servers auto-mount on install).
  /// Returns the number of new servers registered. Never throws.
  Future<int> mountPluginMcpServers(String source) async {
    try {
      final cache = await pluginCacheDirFor(source);
      final f = File('${cache.path}/.mcp.json');
      if (!f.existsSync()) return 0;
      final raw = f.readAsStringSync();
      if (raw.trim().isEmpty) return 0;
      final j = (jsonDecode(raw) as Map?)?.cast<String, dynamic>();
      if (j == null) return 0;
      final servers = j['mcpServers'];
      if (servers is! Map) return 0;
      var mounted = 0;
      for (final entry in servers.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value is! Map) continue;
        if (mcpServers.any((e) => e.name == key)) continue; // dedupe by name
        final m = value;
        final args =
            (m['args'] as List?)?.whereType<String>().toList() ?? const [];
        final url = m['url'] as String?;
        final transport =
            (m['transport'] as String?) ??
            (m['type'] as String?) ??
            ((url != null && url.isNotEmpty) ? 'http' : 'stdio');
        final headers =
            (m['headers'] as Map?)?.map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            ) ??
            const <String, String>{};

        if (m['env'] is Map) {
          final envMap = (m['env'] as Map).map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          );
          if (envMap.isNotEmpty) {
            await setMcpEnv(key, envMap);
          }
        }
        if (headers.isNotEmpty) {
          await setMcpHeaders(key, headers);
        }

        mcpServers.add(
          McpServer(
            name: key,
            author: source,
            description:
                (m['description'] as String?) ??
                'declared by plugin ${source.replaceAll('_', '/')}',
            category: 'Plugin',
            command:
                (m['command'] as String?) ?? (transport == 'http' ? '' : 'npx'),
            args: args,
            envHint: (m['env'] as Map?)?.keys.isNotEmpty == true
                ? (m['env'] as Map).keys.first as String?
                : null,
            source: 'plugin:$source',
            custom: true,
            transport: transport,
            url: url,
            headers: headers,
            cwd: m['cwd'] as String?,
            startupTimeoutS: (m['startupTimeoutS'] as num?)?.toInt() ?? 30,
          ),
        );
        mounted++;
      }
      if (mounted > 0) {
        refresh();
        await _persistCustomMcpServers();
        await _persistMcpConnectedIntent();
      }
      return mounted;
    } catch (_) {
      return 0;
    }
  }

  /// Remove a plugin's fetched content cache (uninstall).
  Future<void> removePluginContent(String source) async {
    try {
      final dir = await pluginCacheDirFor(source);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  /// Task 3: read the plugin's `hooks/hooks.json` from its installed content
  /// cache and register the declared hooks onto the plugin — including the
  /// optional per-hook `matcher` regex (event → pattern). Accepts the
  /// Claude-Code map form (`event → command` string, or `event →
  /// {command, matcher}`) and the list form (`[{event, command, matcher}]`).
  /// Returns the number of hooks registered. Never throws.
  Future<int> registerPluginHooks(PluginItem plugin) async {
    try {
      final source = plugin.source;
      if (source == null) return 0;
      final cache = await pluginCacheDirFor(source);
      final f = File('${cache.path}/hooks/hooks.json');
      if (!f.existsSync()) return 0;
      final raw = f.readAsStringSync();
      if (raw.trim().isEmpty) return 0;
      final j = (jsonDecode(raw) as Map?)?.cast<String, dynamic>();
      if (j == null) return 0;
      final collected = _collectHookDefs(j['hooks']);
      plugin.hooks = Map<String, String>.from(plugin.hooks)
        ..addAll(collected.hooks);
      plugin.hookMatchers = Map<String, String>.from(plugin.hookMatchers)
        ..addAll(collected.matchers);
      if (collected.hooks.isNotEmpty) {
        await _persistPluginState();
        refresh();
      }
      return collected.hooks.length;
    } catch (_) {
      return 0;
    }
  }

  /// Parse a `hooks` document into event → command + event → matcher maps.
  /// Accepts map form (value is a bare command string or {command, matcher})
  /// and list form ({event, command, matcher}). Only known event names are
  /// kept; empty commands are skipped.
  ({Map<String, String> hooks, Map<String, String> matchers}) _collectHookDefs(
    dynamic raw,
  ) {
    final hooks = <String, String>{};
    final matchers = <String, String>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        final ev = (k as String).trim();
        if (!PluginItem.hookEvents.contains(ev)) return;
        String? cmd;
        String? matcher;
        if (v is String) {
          cmd = v;
        } else if (v is Map) {
          cmd = v['command'] as String?;
          matcher = v['matcher'] as String?;
        }
        if (cmd == null || cmd.trim().isEmpty) return;
        hooks[ev] = cmd.trim();
        if (matcher != null && matcher.trim().isNotEmpty) {
          matchers[ev] = matcher.trim();
        }
      });
    } else if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        final ev = (e['event'] as String?)?.trim();
        final cmd = e['command'] as String?;
        if (ev == null || !PluginItem.hookEvents.contains(ev)) continue;
        if (cmd == null || cmd.trim().isEmpty) continue;
        hooks[ev] = cmd.trim();
        final m = e['matcher'] as String?;
        if (m != null && m.trim().isNotEmpty) matchers[ev] = m.trim();
      }
    }
    return (hooks: hooks, matchers: matchers);
  }

  /// Merge a parsed marketplace JSON document into the catalog. Accepts
  /// both list-form and map-form (Claude Desktop / Codex / Cursor shape)
  /// Parse a plugin manifest `hooks` map — event → shell command. Only
  /// known event names are kept (typos die silently at import, not at
  /// fire time). Map AND list-of-{event,command} forms are accepted.
  Map<String, String> _parsePluginHooks(dynamic raw) {
    final out = <String, String>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        final ev = (k as String).trim();
        final cmd = v as String?;
        if (cmd == null || cmd.trim().isEmpty) return;
        if (PluginItem.hookEvents.contains(ev)) out[ev] = cmd.trim();
      });
    } else if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        final ev = (e['event'] as String?)?.trim();
        final cmd = e['command'] as String?;
        if (ev == null || cmd == null || cmd.trim().isEmpty) continue;
        if (PluginItem.hookEvents.contains(ev)) out[ev] = cmd.trim();
      }
    }
    return out;
  }

  /// PR40/Task2: normalize a marketplace plugin-entry `source` to a fetchable
  /// `owner/repo` or resolve relative `./dir` / `/dir` paths against the marketplace
  /// repository (`owner/repo/raw/branch/path`).
  static String? _githubPluginSource(String? raw, {String? marketplaceRepo}) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('.') || s.startsWith('/')) {
      if (marketplaceRepo == null || marketplaceRepo.isEmpty) return null;
      final cleanMarketplace = normalizeMarketplace(marketplaceRepo);
      if (cleanMarketplace.split('/').length != 2) return null;
      final cleanPath = s.replaceFirst(RegExp(r'^\.?/+'), '');
      // `^\.?/+` alone leaves `../foo` intact — a `..` segment would end up
      // spliced into the raw URL and traverse outside the repo. Normalize it
      // away (rejecting any walk that escapes the marketplace root).
      final resolved = _resolveRelativePath(cleanPath);
      if (resolved == null) return null;
      return '$cleanMarketplace/raw/branch/$resolved';
    }
    final normalized = normalizeMarketplace(s);
    if (normalized.split('/').length != 2) return null;
    return normalized;
  }

  /// Normalize a relative path, dropping `.` segments and resolving `..`
  /// against prior segments. Returns null when a `..` escapes the root (so a
  /// marketplace entry can't craft a raw URL that walks outside its repo).
  static String? _resolveRelativePath(String raw) {
    final out = <String>[];
    for (final seg in raw.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (out.isEmpty) return null;
        out.removeLast();
      } else {
        out.add(seg);
      }
    }
    final joined = out.join('/');
    return joined.isEmpty ? null : joined;
  }

  @visibleForTesting
  static String? githubPluginSourceForTest(
    String? raw, {
    String? marketplaceRepo,
  }) => _githubPluginSource(raw, marketplaceRepo: marketplaceRepo);

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
        if (plugins.any((e) => e.runtimeId == null && e.name == pname)) {
          final existing = plugins.firstWhere(
            (e) => e.runtimeId == null && e.name == pname,
          );
          if (existing.source == null && p['source'] != null) {
            existing.source = _githubPluginSource(
              p['source'] as String?,
              marketplaceRepo: '$owner/$repoName',
            );
          }
          continue;
        }
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
            installsKnown: (p['installs'] is int && (p['installs'] as int) > 0),
            // PR24: hook declarations survive the marketplace import.
            hooks: _parsePluginHooks(p['hooks']),
            // PR40/Task2: an `owner/repo` source or relative `./dir` source
            // resolved against the marketplace repo allows fetching plugin content.
            source: _githubPluginSource(
              p['source'] as String?,
              marketplaceRepo: '$owner/$repoName',
            ),
            marketplace: '$owner/$repoName',
          ),
        );
        importedPlugins++;
      }
    }

    // ── mcpServers — list form AND map form (Codex/Claude Desktop) ──
    void importMcp(Map m, String? fallbackName) {
      final mname = (m['name'] as String?) ?? fallbackName ?? '';
      if (mname.isEmpty) return;
      if (mcpServers.any((e) => e.name == mname)) return;
      // PR41: an entry with `url` (and no `command`) is a Streamable-HTTP
      // server — Claude Desktop / Codex all use this exact shape
      // for a remote MCP server (`{"url": "https://...", "headers": {…}}`).
      final urlValue = m['url'] as String?;
      final isHttp = urlValue != null && urlValue.isNotEmpty;
      final headers =
          (m['headers'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          ) ??
          const <String, String>{};
      mcpServers.add(
        McpServer(
          name: mname,
          author: m['author'] as String? ?? owner,
          description: m['description'] as String? ?? '',
          category: m['category'] as String? ?? 'Community',
          command: (m['command'] as String?) ?? (m['cmd'] as String?) ?? 'npx',
          args: (m['args'] as List?)?.whereType<String>().toList() ?? const [],
          envHint:
              (m['envHint'] as String?) ??
              ((m['env'] as Map?)?.keys.isNotEmpty == true
                  ? (m['env'] as Map).keys.first as String?
                  : null),
          source: 'marketplace:$owner/$repoName',
          custom: true,
          transport: isHttp ? 'http' : 'stdio',
          url: isHttp ? urlValue : null,
          headers: headers,
          cwd: m['cwd'] as String?,
          startupTimeoutS: (m['startupTimeoutS'] as num?)?.toInt() ?? 30,
        ),
      );
      // Auth headers are a secret — secure storage, never plaintext prefs.
      if (headers.isNotEmpty) {
        unawaited(setMcpHeaders(mname, headers));
      }
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

    if (importedPlugins > 0) {
      unawaited(persistMergedMarketplaceCatalog());
    }
    if (importedMcps > 0) {
      unawaited(_persistCustomMcpServers());
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
      updateServiceStatus(
        'mcp:${s.canonicalId}',
        ServiceHealth.connecting,
        detail: 'connecting…',
      );
      unawaited(
        McpService.I
            .connect(s)
            .then((msg) {
              final isOk = McpService.I.isConnected(s.canonicalId);
              s.connected = isOk;
              updateServiceStatus(
                'mcp:${s.canonicalId}',
                isOk ? ServiceHealth.working : ServiceHealth.failed,
                detail: msg,
              );
              refresh();
            })
            .catchError((e) {
              s.connected = false;
              updateServiceStatus(
                'mcp:${s.canonicalId}',
                ServiceHealth.failed,
                detail: '$e',
              );
              refresh();
            }),
      );
    } else {
      serviceStatus.remove('mcp:${s.canonicalId}');
      unawaited(McpService.I.disconnect(s.canonicalId));
    }
    _persistMcpConnectedIntent();
    refresh();
  }

  // ── MCP auto-reconnect (the MCP supervisor tier-2 lifecycle parity) ──
  /// Names of servers the user wants connected. Survives restarts so the
  /// app can respawn them on launch/resume (spawn-on-demand otherwise).
  static const _kMcpConnectedIntent = 'ovid_mcp_connected_v1';

  /// Public wrapper: persist the connected-server intent (agent-tool and
  /// UI install paths both call it so a restart keeps them connected).
  Future<void> persistMcpIntent() => _persistMcpConnectedIntent();

  Future<void> _persistMcpConnectedIntent() async {
    final names = mcpServers
        .where((s) => s.connected)
        .map((s) => s.canonicalId)
        .toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kMcpConnectedIntent, names);
    } catch (_) {}
  }

  /// Reconnect both MCP servers and enabled plugins on app launch / resume.
  Future<void> reconnectServices({List<String>? targetServers}) async {
    List<String> names = targetServers ?? [];
    if (targetServers == null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        names = prefs.getStringList(_kMcpConnectedIntent) ?? [];
      } catch (_) {
        names = [];
      }
    }

    for (final name in names) {
      final s = mcpServers
          .where((s) => s.canonicalId == name || s.name == name)
          .firstOrNull;
      if (s == null) continue;
      updateServiceStatus(
        'mcp:$name',
        ServiceHealth.connecting,
        detail: 'connecting…',
      );
      try {
        final res = await McpService.I.connect(s);
        final isOk = McpService.I.isConnected(s.canonicalId);
        s.connected = isOk;
        updateServiceStatus(
          'mcp:$name',
          isOk ? ServiceHealth.working : ServiceHealth.failed,
          detail: res,
        );
      } catch (e) {
        s.connected = false;
        updateServiceStatus('mcp:$name', ServiceHealth.failed, detail: '$e');
      }
    }

    // Re-verify enabled plugins (Task 10, spec §10): startup health is
    // derived from a real capability probe — never a hardcoded 'working'
    // stamp. A plugin that resolves at least one real contribution
    // (tool/skill/hook/MCP) is working; an installed+enabled row with
    // nothing mounted fails honestly so the Plugins screen shows an
    // actionable state.
    for (final p in plugins.where((p) => p.installed && p.enabled)) {
      final tools = AgentService.I.pluginToolNames(p);
      if (tools.isNotEmpty) {
        updateServiceStatus(
          'plugin:${p.name}',
          ServiceHealth.working,
          detail: 'probe ok · tools: ${tools.join(', ')}',
        );
      } else {
        updateServiceStatus(
          'plugin:${p.name}',
          ServiceHealth.failed,
          detail:
              'probe failed: installed+enabled but contributes no agent '
              'tools, skills, hooks, or MCP servers',
        );
      }
    }
    refresh();
  }

  /// Reconnect every server the user had connected (app resume/launch).
  /// Failures are silent — servers stay "disconnected" until the user
  /// retries; lazy connect covers them on tool call.
  Future<void> reconnectMcpServers() => reconnectServices();

  void addCustomMcpServer({
    required String name,
    required String command,
    List<String> args = const [],
    String? envHint,
    // PR41: an explicit http/https url makes this an HTTP-transport
    // server instead of a spawned stdio process; command/args are then
    // ignored by McpService.connect.
    String? url,
    Map<String, String> headers = const {},
    // Task 4: explicit transport/cwd/startup timeout round-trip.
    String? transport,
    String? cwd,
    int? startupTimeoutS,
  }) {
    final isHttp =
        transport == 'sse' ||
        ((url != null && url.isNotEmpty) && transport != 'stdio');
    final resolvedTransport = transport ?? (isHttp ? 'http' : 'stdio');
    final server = McpServer(
      name: name.trim(),
      author: 'you',
      description: resolvedTransport == 'http'
          ? 'Custom MCP server (HTTP) — connects on demand.'
          : 'Custom MCP server — connects on demand.',
      category: 'Custom',
      command: command.trim(),
      args: args,
      envHint: envHint,
      source: 'custom',
      custom: true,
      transport: resolvedTransport,
      url: url != null && url.isNotEmpty ? url : null,
      headers: headers,
      cwd: cwd,
      startupTimeoutS: startupTimeoutS ?? 30,
    );
    mcpServers.add(server);
    if (headers.isNotEmpty) {
      unawaited(setMcpHeaders(server.canonicalId, headers));
    }
    _persistCustomMcpServers();
    refresh();
  }

  Future<void> removeMcpServer(McpServer s) async {
    mcpServers.remove(s);
    // Task 4: full teardown — kill the process, cancel any pending
    // reconnect, wipe secure env/headers, and prune the connected intent
    // so a restart never auto-respawns a removed server.
    await McpService.I.disconnect(s.canonicalId);
    await Future.wait([
      deleteMcpEnv(s.canonicalId),
      deleteMcpHeaders(s.canonicalId),
    ]);
    await _persistCustomMcpServers();
    await _persistMcpConnectedIntent();
    refresh();
  }

  /// Update an existing custom MCP server from an edited config — round-trips
  /// command/args/url/transport/headers/cwd/startup timeout. HTTP auth
  /// headers go to secure storage (never plaintext prefs).
  void updateCustomMcpServer(
    McpServer s, {
    required String command,
    required List<String> args,
    String? url,
    String? transport,
    Map<String, String> headers = const {},
    String? cwd,
    int? startupTimeoutS,
  }) {
    s.command = command.trim();
    s.args = args;
    s.url = url != null && url.isNotEmpty ? url : null;
    s.transport =
        transport ?? (s.url != null && s.url!.isNotEmpty ? 'http' : 'stdio');
    s.headers = headers;
    s.cwd = cwd;
    if (startupTimeoutS != null) s.startupTimeoutS = startupTimeoutS;
    if (headers.isNotEmpty) {
      unawaited(setMcpHeaders(s.canonicalId, headers));
    }
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
              if (s.ownerPluginId != null) 'ownerPluginId': s.ownerPluginId,
              'author': s.author,
              'description': s.description,
              'category': s.category,
              'command': s.command,
              'args': s.args,
              'envHint': s.envHint,
              'source': s.source,
              if (s.requiredEnvNames.isNotEmpty)
                'requiredEnvNames': s.requiredEnvNames,
              if (s.requiredHeaderNames.isNotEmpty)
                'requiredHeaderNames': s.requiredHeaderNames,
              if (s.pluginRuntimeRoot != null)
                'pluginRuntimeRoot': s.pluginRuntimeRoot,
              // PR41: transport/url — without these a custom HTTP server
              // reloads as a broken stdio ('npx') entry. Headers are a
              // secret and are persisted in secure storage instead.
              'transport': s.transport,
              if (s.url != null) 'url': s.url,
              if (s.cwd != null) 'cwd': s.cwd,
              if (s.startupTimeoutS != 30) 'startupTimeoutS': s.startupTimeoutS,
            }),
          )
          .toList();
      await prefs.setStringList(_kCustomMcpServers, customs);
    } catch (_) {}
  }

  /// Test seam: re-run the persisted-custom-MCP-servers load (simulates a
  /// restart without tearing down the whole AppState singleton).
  @visibleForTesting
  Future<void> reloadCustomMcpServersForTest() => _loadCustomMcpServers();

  Future<void> _loadCustomMcpServers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_kCustomMcpServers);
      if (list == null || list.isEmpty) return;
      for (final j in list) {
        final m = jsonDecode(j) as Map<String, dynamic>;
        final name = m['name'] as String;
        final ownerPluginId = m['ownerPluginId'] as String?;
        final canonicalId = ownerPluginId == null
            ? name
            : '$ownerPluginId/$name';
        if (mcpServers.any((s) => s.canonicalId == canonicalId)) continue;
        final transport = m['transport'] as String? ?? 'stdio';
        final source = m['source'] as String? ?? 'custom';
        mcpServers.add(
          McpServer(
            name: name,
            ownerPluginId: ownerPluginId,
            author: m['author'] as String? ?? 'you',
            description:
                (m['description'] as String?) ??
                (transport == 'http'
                    ? 'Custom MCP server (HTTP) — connects on demand.'
                    : 'Custom MCP server — connects on demand.'),
            category: m['category'] as String? ?? 'Custom',
            command: m['command'] as String? ?? 'npx',
            args: (m['args'] as List?)?.cast<String>() ?? const [],
            envHint: m['envHint'] as String?,
            source: source,
            custom: true,
            transport: transport,
            url: m['url'] as String?,
            // Headers are a secret — read back from secure storage, not
            // from plaintext prefs (they are no longer persisted there).
            headers: await getMcpHeaders(canonicalId),
            requiredEnvNames: (m['requiredEnvNames'] as List?)
                ?.whereType<String>()
                .toList(),
            requiredHeaderNames: (m['requiredHeaderNames'] as List?)
                ?.whereType<String>()
                .toList(),
            pluginRuntimeRoot: m['pluginRuntimeRoot'] as String?,
            cwd: m['cwd'] as String?,
            startupTimeoutS: (m['startupTimeoutS'] as num?)?.toInt() ?? 30,
          ),
        );
      }
      refresh();
    } catch (_) {}
  }

  /// Public persist hook — the Plugins UI and agent tools call this after
  /// mutating PluginItem.installed / .enabled so state survives restarts.
  Future<void> persistPluginState() => _persistPluginState();

  Future<void> persistLegacyPluginMigrationState() async {
    await _persistPluginState(reportFailure: true);
    await _persistCustomPlugins(reportFailure: true);
    await persistMergedMarketplaceCatalog(reportFailure: true);
  }

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
        installs: 0,
        installsKnown: false,
      ),
    );
    _persistCustomPlugins();
    refresh();
  }

  static const _kCustomPlugins = 'ovid_custom_plugins_v1';

  Future<void> _persistCustomPlugins({bool reportFailure = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final customs = plugins
          .where((p) => p.author == 'you' && p.runtimeId == null)
          .map(
            (p) => jsonEncode({
              'name': p.name,
              'description': p.description,
              'category': p.category,
              'installed': p.installed,
              'enabled': p.enabled,
              if (p.hooks.isNotEmpty) 'hooks': p.hooks,
              if (p.migrationRequired) 'migrationRequired': true,
              if (p.runtimeReason != null) 'runtimeReason': p.runtimeReason,
            }),
          )
          .toList();
      final written = await prefs.setStringList(_kCustomPlugins, customs);
      if (!written && reportFailure) {
        throw StateError('Failed to persist custom legacy plugin rows');
      }
    } catch (error, stack) {
      if (reportFailure) Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> _loadCustomPlugins() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_kCustomPlugins);
      if (list == null || list.isEmpty) return;
      final loaded = <PluginItem>[];
      final names = plugins.map((plugin) => plugin.name).toSet();
      for (final j in list) {
        final m = jsonDecode(j) as Map<String, dynamic>;
        final name = m['name'] as String;
        if (!names.add(name)) continue;
        loaded.add(
          PluginItem(
            name: name,
            author: 'you',
            description: m['description'] as String? ?? 'Custom plugin.',
            version: '1.0.0',
            category: m['category'] as String? ?? 'Custom',
            installed: m['installed'] as bool? ?? true,
            enabled: m['enabled'] as bool? ?? true,
            installs: 0,
            installsKnown: false,
            hooks:
                (m['hooks'] as Map?)?.map(
                  (k, v) => MapEntry(k as String, v as String),
                ) ??
                const {},
            migrationRequired: m['migrationRequired'] as bool? ?? false,
            runtimeReason: m['runtimeReason'] as String?,
          ),
        );
      }
      plugins.insertAll(0, loaded);
      refresh();
    } catch (_) {}
  }

  Future<void> _persistPluginState({bool reportFailure = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final state = <String, String>{};
      for (final p in plugins) {
        if (p.runtimeId != null) continue;
        state[p.name] = jsonEncode({
          'installed': p.installed,
          'enabled': p.enabled,
          if (p.hooks.isNotEmpty) 'hooks': p.hooks,
          if (p.hookMatchers.isNotEmpty) 'hookMatchers': p.hookMatchers,
          // PR40: persist source too — without it, a marketplace plugin's
          // fetched commands/skills root can no longer be resolved after
          // a restart (the seed list has no source; only a live
          // marketplace re-sync would have recreated it in memory).
          if (p.source != null) 'source': p.source,
          // Task 7 (spec §7): runtime fields survive restarts on the
          // same row — the activation records themselves live under
          // their own prefs key (PluginRuntimeManager).
          if (p.runtimeId != null) 'runtimeId': p.runtimeId,
          if (p.activation != PluginActivation.disabled)
            'activation': p.activation.name,
          if (p.immediateSessionId != null)
            'immediateSessionId': p.immediateSessionId,
          if (p.promoteOnNextBoot) 'promoteOnNextBoot': p.promoteOnNextBoot,
          if (p.manifestDigest != null) 'manifestDigest': p.manifestDigest,
          if (p.compatibilityWarnings.isNotEmpty)
            'compatibilityWarnings': p.compatibilityWarnings
                .map((i) => i.toJson())
                .toList(),
          if (p.migrationRequired) 'migrationRequired': true,
          if (p.runtimeReason != null) 'runtimeReason': p.runtimeReason,
        });
      }
      final written = await prefs.setString(_kPluginState, jsonEncode(state));
      if (!written && reportFailure) {
        throw StateError('Failed to persist legacy plugin state');
      }
    } catch (error, stack) {
      if (reportFailure) Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> _loadPluginState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPluginState);
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      for (final p in plugins) {
        if (p.runtimeId != null) continue;
        final v = m[p.name];
        if (v == null) continue;
        final ps = jsonDecode(v as String) as Map<String, dynamic>;
        p.installed = ps['installed'] as bool? ?? p.installed;
        p.enabled = ps['enabled'] as bool? ?? p.enabled;
        final hk = ps['hooks'];
        if (hk is Map) {
          p.hooks = hk.map((k, v) => MapEntry(k as String, v as String));
        }
        final hm = ps['hookMatchers'];
        if (hm is Map) {
          p.hookMatchers = hm.map((k, v) => MapEntry(k as String, v as String));
        }
        if (ps.containsKey('source')) {
          final s = ps['source'] as String?;
          if (s != null && s.isNotEmpty) {
            p.source = s;
          }
        }
        p.migrationRequired = ps['migrationRequired'] as bool? ?? false;
        p.runtimeReason = ps['runtimeReason'] as String?;
      }
      refresh();
    } catch (_) {}
  }

  // ── Custom Presets ──────────────────────────────────────────────────
  Future<void> _persistCustomPresets() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = PresetRegistry.customPresets.map((p) => p.toJson()).toList();
      await prefs.setString(_kCustomPresets, jsonEncode(list));
    } catch (_) {}
  }

  Future<void> _loadCustomPresets() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCustomPresets);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw);
      if (list is List) {
        PresetRegistry.clearCustom();
        for (final item in list) {
          if (item is Map<String, dynamic>) {
            PresetRegistry.saveCustom(AgentPreset.fromJson(item));
          } else if (item is Map) {
            PresetRegistry.saveCustom(
              AgentPreset.fromJson(item.cast<String, dynamic>()),
            );
          }
        }
      }
    } catch (_) {}
  }

  Future<void> saveCustomPreset(AgentPreset preset) async {
    PresetRegistry.saveCustom(preset);
    await _persistCustomPresets();
    refresh();
  }

  Future<void> deleteCustomPreset(String id) async {
    PresetRegistry.deleteCustom(id);
    await _persistCustomPresets();
    refresh();
  }

  void saveCustomPresetForTest(Map<String, dynamic> data) {
    final p = AgentPreset.fromJson(data);
    PresetRegistry.saveCustom(p);
    unawaited(_persistCustomPresets());
  }

  void deleteCustomPresetForTest(String id) {
    PresetRegistry.deleteCustom(id);
    unawaited(_persistCustomPresets());
  }

  // ── MCP server env vars (secure storage) ────────────────────────────
  static const _kMcpHeadersPrefix = 'ovid_mcp_headers_';

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

  /// Delete a server's env var blob from secure storage (on remove/reset).
  Future<void> deleteMcpEnv(String serverName) async {
    try {
      await _secureStorage.delete(key: '$_kMcpEnvPrefix$serverName');
    } catch (_) {}
  }

  // ── MCP server HTTP auth headers (secure storage) ───────────────────
  // Task 4 / security: auth headers (Bearer tokens etc.) must never hit
  // SharedPreferences plaintext. They live alongside env in secure storage.
  Future<void> setMcpHeaders(
    String serverName,
    Map<String, String> headers,
  ) async {
    try {
      if (headers.isEmpty) {
        await _secureStorage.delete(key: '$_kMcpHeadersPrefix$serverName');
      } else {
        await _secureStorage.write(
          key: '$_kMcpHeadersPrefix$serverName',
          value: jsonEncode(headers),
        );
      }
    } catch (_) {}
  }

  Future<Map<String, String>> getMcpHeaders(String serverName) async {
    try {
      final raw = await _secureStorage.read(
        key: '$_kMcpHeadersPrefix$serverName',
      );
      if (raw == null || raw.isEmpty) return {};
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return {};
    }
  }

  /// Delete a server's auth-headers blob from secure storage.
  Future<void> deleteMcpHeaders(String serverName) async {
    try {
      await _secureStorage.delete(key: '$_kMcpHeadersPrefix$serverName');
    } catch (_) {}
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
      ),
      PluginItem(
        name: 'DeepThink Reasoning',
        author: 'ovidai',
        description:
            'Chain-of-thought mode — model thinks step-by-step before replying, shown as collapsible reasoning.',
        version: '1.2.1',
        category: 'Tool',
        // Task 10 (spec §10): the reasoning display is gated by the
        // showReasoning preference, never by this row — it mounts no
        // agent tool, so it must not seed as installed (honest catalog:
        // discoverable rows are labeled Available, not Installed).
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
      ),
      PluginItem(
        name: 'MCP Server Hub',
        author: 'modelcontextprotocol',
        description:
            'Connect any Model Context Protocol server: filesystem, github, postgres, puppeteer…',
        version: '2.1.0',
        category: 'MCP',
      ),
      PluginItem(
        name: 'Web Fetch & Reader',
        author: 'ovidai',
        description:
            'Turn any URL into clean markdown for the model — articles, docs, threads.',
        version: '1.0.6',
        category: 'Tool',
        installed: true,
      ),
      PluginItem(
        name: 'Voice Input',
        author: 'ovidai',
        description:
            'Dictate prompts hands-free, on-device speech recognition.',
        version: '0.9.8',
        category: 'Tool',
      ),
      PluginItem(
        name: 'Multi-Model Compare',
        author: 'ovidai',
        description:
            'Send one prompt to up to 3 models side-by-side, pick the best answer.',
        version: '0.7.2',
        category: 'Tool',
      ),
      PluginItem(
        name: 'RAG Memory',
        author: 'ovidai',
        description:
            'Long-term vector memory — the agent remembers your projects and prefs.',
        version: '1.3.0',
        category: 'Tool',
      ),
      PluginItem(
        name: 'Code Runner',
        author: 'sandbox',
        description:
            'Run python/js snippets in chat with output preview — powered by sandbox.',
        version: '1.1.4',
        category: 'Runtime',
      ),
      PluginItem(
        name: 'Git Workbench',
        author: 'ovidai',
        description: 'Clone, branch, commit and push from the Studio IDE.',
        version: '0.8.3',
        category: 'Tool',
      ),
      PluginItem(
        name: 'PR Reviewer',
        author: 'ovidai',
        description: 'Auto-review GitHub PRs with inline fix suggestions.',
        version: '1.0.2',
        category: 'Agent',
      ),
      PluginItem(
        name: 'Web Clipper',
        author: 'ovidai',
        description:
            'Save pages, snippets and notes to a searchable knowledge base.',
        version: '1.1.0',
        category: 'Tool',
      ),
      PluginItem(
        name: 'Translate Pro',
        author: 'ovidai',
        description:
            'Document translation with layout preserved, 100+ languages.',
        version: '2.0.1',
        category: 'Tool',
      ),
      PluginItem(
        name: 'PDF Tools',
        author: 'ovidai',
        description: 'Merge, split, compress, summarize PDFs right in chat.',
        version: '1.5.2',
        category: 'Tool',
      ),
      PluginItem(
        name: 'Data Analyst',
        author: 'ovidai',
        description:
            'Upload CSV/Excel, get charts, trends and insights automatically.',
        version: '1.2.8',
        category: 'Tool',
      ),
      PluginItem(
        name: 'Study Mode',
        author: 'ovidai',
        description:
            'Turn any chat into flashcards, quizzes and spaced-repetition decks.',
        version: '0.9.1',
        category: 'Tool',
      ),
      PluginItem(
        name: 'Meeting Notes',
        author: 'ovidai',
        description:
            'Record or upload audio, get clean minutes and action items.',
        version: '1.1.6',
        category: 'Tool',
      ),
      PluginItem(
        name: 'Prompt Library',
        author: 'ovidai',
        description: 'Community prompts with one-tap use — sorted by task.',
        version: '1.6.0',
        category: 'Tool',
      ),
      PluginItem(
        name: 'Screen Awareness',
        author: 'ovidai',
        description:
            'Ask about anything on your screen — share a screenshot into chat.',
        version: '0.8.5',
        category: 'Tool',
      ),
      PluginItem(
        name: 'Calendar & Tasks',
        author: 'ovidai',
        description:
            'Plan, schedule and get reminders from plain-language chat.',
        version: '1.0.7',
        category: 'Tool',
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
          installs: 0,
          installsKnown: false,
        ),
    ]);

    // --- MCP servers (official registry + community) ---
    // Task 10 (spec §10) production audit: bundled MCP seeds carry ONLY
    // pinned, registry-verified coordinates (the pinned tested manifest
    // is docs/superpowers/audits/2026-09-06-preinstalled-plugin-mcp-runtime.md).
    // 22 previously-seeded rows pointed at nonexistent npm packages and
    // were removed; every remaining row starts disconnected — connected
    // state is derived only after a real MCP handshake. Deprecated
    // upstream packages say so in their description.
    mcpServers.addAll([
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
            'Repos, issues, PRs and actions — full GitHub access for your '
            'agent. (Pinned @modelcontextprotocol/server-github is '
            'deprecated upstream; kept because it still installs and '
            'works. A GITHUB_TOKEN is required.)',
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
            'Headless browser automation — click, scroll, screenshot, scrape. '
            '(Pinned @modelcontextprotocol/server-puppeteer is deprecated '
            'upstream in favor of Playwright; kept because it still '
            'installs and works.)',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@modelcontextprotocol/server-puppeteer'],
      ),
      McpServer(
        name: 'Postgres',
        author: 'modelcontextprotocol',
        description:
            'Read-only schema inspection and safe queries on your database. '
            '(Pinned @modelcontextprotocol/server-postgres is deprecated '
            'upstream; kept because it still installs and works. A '
            'DATABASE_URL is required.)',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@modelcontextprotocol/server-postgres'],
        envHint: 'DATABASE_URL',
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
    ]);

    // user-added marketplaces (Claude Code style)
    marketplaces.addAll(['ovidai/ovid-plugins']);
  }
}
