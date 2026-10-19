import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Brightness, WidgetsBinding;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud/cloud_agent_facade.dart';
import 'cloud/cloud_session_store.dart';
import 'cloud/studio_remote_client.dart';
import 'firebase_service.dart';
import 'cloud_app_check.dart';
import 'github_service.dart';
import 'html_artifact.dart';
import 'image_receipt_store.dart';
import 'image_studio.dart';
import 'model_limits.dart';
import 'composer_drafts.dart';
import 'studio_drafts.dart';
import 'secure_store.dart';
import 'security_service.dart';
import 'theme.dart';
import 'conversation_share_service.dart';
import 'session_history_store.dart';
import 'session_search.dart';
import 'settings_actions.dart';
import 'settings_backup_service.dart';
import 'presets.dart';
import 'reset_coordinator.dart';
import 'collaboration/production.dart';
import 'diag.dart';

part 'settings_state_integration.dart';

/// Friendly UI label for a model id. The Ovid Cloud managed alias `auto`
/// renders as `Auto` (one clean option in the picker/chip); every other model
/// shows exactly as named — owner-chosen names in LiteLLM appear verbatim.
String ovidModelLabel(String model) {
  return model.trim() == 'auto' ? 'Auto' : model;
}

/// Exact model families known to accept the OpenAI-compatible
/// `reasoning_effort` parameter. Matched against the model id's last path
/// segment (`openai/o3-mini` → `o3-mini`). Anything else gets a plain tile
/// and never sends `reasoning_effort`, so non-reasoning models are not
/// rejected and retried.
final List<RegExp> _reasoningEffortFamilies = [
  // OpenAI o-series (o1-mini / o1-preview predate reasoning_effort).
  RegExp(r'^o1(-pro)?(-\d{4}-\d{2}-\d{2})?$'),
  RegExp(
    r'^o[34](-mini|-pro)?(-(high|low|deep-research))?(-\d{4}-\d{2}-\d{2})?$',
  ),
  // GPT-5 reasoning models (the -chat variants are non-reasoning).
  RegExp(
    r'^gpt-5(\.\d+)?(-(mini|nano|pro|codex(-mini)?))?(-\d{4}-\d{2}-\d{2})?$',
  ),
  RegExp(r'^gpt-oss-\d+b$'),
  // Gemini thinking models via the OpenAI-compatible endpoint.
  RegExp(r'^gemini-2\.5-(pro|flash)(-lite)?(-preview.*)?$'),
  RegExp(r'^gemini-3(\.\d+)?-(pro|flash)(-preview.*)?$'),
  // xAI: only grok-3-mini accepts reasoning_effort.
  RegExp(r'^grok-3-mini(-fast)?(-beta)?$'),
];

/// Whether [model] (optionally carrying a `· Low/Medium/High` variant)
/// belongs to a family that supports `reasoning_effort`.
bool modelSupportsReasoningEffort(String model) {
  var id = model.split('·').first.trim().toLowerCase();
  final slash = id.lastIndexOf('/');
  if (slash >= 0) id = id.substring(slash + 1);
  final colon = id.indexOf(':');
  if (colon >= 0) id = id.substring(0, colon);
  return _reasoningEffortFamilies.any((re) => re.hasMatch(id));
}

/// ---------- Models ----------

/// Wire format a provider speaks. OpenAI-compatible is the default; Anthropic
/// uses a different endpoint, auth header, body shape, SSE events and tool
/// schema, so the transport must know which one to build.
enum ApiFormat {
  openai,
  anthropic;

  static ApiFormat parse(String? raw) {
    final v = (raw ?? '').trim().toLowerCase();
    if (v == 'anthropic' || v == 'claude' || v == 'messages') {
      return ApiFormat.anthropic;
    }
    return ApiFormat.openai;
  }

  String get wire => name;
}

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

  /// OpenAI-compatible vs native Anthropic Messages API. Defaults to
  /// [ApiFormat.openai]. Legacy rows without this field are migrated from
  /// their base URL when loaded; an explicitly saved value always wins.
  ApiFormat apiFormat;
  bool _hasExplicitApiFormat;

  /// Per-model vision override. `true` = force vision-capable, `false` =
  /// force text-only, absent = auto-detect. Lets a user enable a model whose
  /// id the allowlist cannot parse (custom/aggregator endpoints) without
  /// loosening detection for every other model.
  final Map<String, bool> _visionOverrides = {};

  /// Model ids that came from the provider's `/models` endpoint (as opposed
  /// to ids added by hand or shipped with the app). A later fetch that no
  /// longer lists one of these drops it, so retired models do not linger
  /// and fail at send time; manual ids are never touched by a fetch.
  final Set<String> fetchedModels = {};

  /// When the stored key last passed a `/models` probe (null = never).
  DateTime? verifiedAt;

  bool? modelVisionSupport(String model) {
    final key = model.trim();
    final manual = _visionOverrides[key];
    if (manual != null) return manual;
    // No manual toggle: ask the numbers this provider published for that
    // exact route (modality / input_types, read live off its /v1/models).
    return ModelLimits.acceptsImages(key, id);
  }

  /// Set (or clear, with `null`) the vision override for [model].
  void setModelVisionSupport(String model, bool? supported) {
    final key = model.trim();
    if (key.isEmpty) return;
    if (supported == null) {
      _visionOverrides.remove(key);
    } else {
      _visionOverrides[key] = supported;
    }
  }

  Map<String, bool> get visionOverrides => Map.unmodifiable(_visionOverrides);

  /// Merge a persisted provider row (used by [AppState.loadProviderState]).
  void applyPersistedJson(Map<String, dynamic> entry) {
    final persistedBaseUrl = entry['baseUrl'] as String?;
    if (persistedBaseUrl != null) {
      baseUrl = id == AppState.ovidCloudProviderId
          ? normalizeOvidCloudBaseUrl(persistedBaseUrl)
          : persistedBaseUrl;
    }
    final fmt = entry['apiFormat'];
    if (fmt is String && fmt.isNotEmpty) {
      apiFormat = ApiFormat.parse(fmt);
      _hasExplicitApiFormat = true;
    } else if (!_hasExplicitApiFormat) {
      apiFormat = _legacyApiFormat(baseUrl);
    }
    if (custom && _usesGeneratedDescription) {
      description = _protocolDescription;
    }
    final fetched = entry['fetchedModels'];
    if (fetched is List) {
      fetchedModels
        ..clear()
        ..addAll(fetched.whereType<String>().where((m) => m.isNotEmpty));
    }
    final verified = entry['verifiedAt'];
    verifiedAt = verified is String ? DateTime.tryParse(verified) : null;
    final raw = entry['visionOverrides'];
    if (raw is Map) {
      _visionOverrides.clear();
      for (final e in raw.entries) {
        final v = e.value;
        if (v is bool) _visionOverrides[e.key.toString()] = v;
      }
    }
  }

  static String normalizeOvidCloudBaseUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host != 'cloud.dhanuksoftwares.com') return value;
    return uri.replace(host: 'api.ovidsi.com').toString();
  }

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
    ApiFormat? apiFormat,
  }) : id = id ?? _slug(name),
       _hasExplicitApiFormat = apiFormat != null,
       models = models ?? [],
       apiFormat = apiFormat ?? ApiFormat.openai;

  static ApiFormat _legacyApiFormat(String baseUrl) =>
      baseUrl.toLowerCase().contains('anthropic.com')
      ? ApiFormat.anthropic
      : ApiFormat.openai;

  bool get _usesGeneratedDescription =>
      description == 'Custom OpenAI-compatible provider' ||
      description == 'Custom Anthropic Messages provider';

  String get _protocolDescription => apiFormat == ApiFormat.anthropic
      ? 'Custom Anthropic Messages provider'
      : 'Custom OpenAI-compatible provider';

  bool get hasKey => apiKey.trim().isNotEmpty;
  bool get isConfigured => !requiresApiKey || hasKey;

  /// Effective wire format. Explicit choices win; rows created before the
  /// field existed retain the legacy Anthropic-host inference.
  ApiFormat get effectiveApiFormat =>
      _hasExplicitApiFormat ? apiFormat : _legacyApiFormat(baseUrl);

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
    'apiFormat': apiFormat.wire,
    if (_visionOverrides.isNotEmpty)
      'visionOverrides': Map<String, bool>.from(_visionOverrides),
    if (fetchedModels.isNotEmpty) 'fetchedModels': fetchedModels.toList(),
    if (verifiedAt != null) 'verifiedAt': verifiedAt!.toUtc().toIso8601String(),
  };
}

String _slug(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

String _baseModel(String value) => value.split('·').first.trim();

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
  turnTail, // passive turn-tail lane rows: settlement notices, dropped-queue notes
  compact,
  imageGen,
  htmlArtifact,
  // Live streaming bubble: the in-progress assistant message. Born as
  // `streaming` (never `reasoning`) so the answer is never hidden behind
  // a collapsed thinking card; finalized to `text` (or `reasoning` when
  // only thinking tokens arrived) when the stream ends.
  streaming,
}

/// Attachment metadata rendered as a chip under a user message.
class MessageAttachment {
  final String name;
  final int size;

  /// Actual workspace path, retained for later turns and process restarts.
  /// Null on messages written before attachment paths were persisted.
  final String? path;

  /// Presigned R2 download URL (P7/P8): cloud artifacts are fetched by URL,
  /// not from a local workspace.
  final String? url;
  MessageAttachment({required this.name, required this.size, this.path, this.url});

  factory MessageAttachment.fromJson(Map<String, dynamic> j) =>
      MessageAttachment(
        name: j['name'] as String? ?? 'file',
        size: (j['size'] as num?)?.toInt() ?? 0,
        path: j['path'] as String?,
        url: j['url'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'name': name,
    'size': size,
    if (path != null) 'path': path,
    if (url != null) 'url': url,
  };
}

/// Locally generated stable message identity. Cloud rows carry the server's
/// message id instead (see `CloudAgentFacade`/`EventTranscriptProjector`).
String _newMessageId() => List.generate(
  24,
  (_) => Random.secure().nextInt(256),
).map((n) => n.toRadixString(16).padLeft(2, '0')).join();

class Message {
  /// Stable across pagination, persistence, and edits. Cloud rows use the
  /// server's message id; local rows use a locally generated id.
  final String privateSyncId;
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

  /// Lossless compaction: the small identifying args of a tool card (path,
  /// command, URL, …) as JSON, recorded at dispatch. Never file bodies.
  String? toolInput;

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
    this.toolInput,
    this.attachments = const [],
    this.imagePath,
    this.imageUrl,
    this.imageRequestId,
    this.htmlArtifact,
    this.feedback,
    this.feedbackNote,
    DateTime? time,
    String? privateSyncId,
  }) : time = time ?? DateTime.now(),
       privateSyncId = privateSyncId ?? _newMessageId();

  /// Local file path for `MsgKind.imageGen` rows — the generated image
  /// saved into the session workspace (rendered in-chat, tappable to open).
  final String? imagePath;

  /// Presigned R2 URL for a generated image (cloud result). Local builds
  /// carried an on-disk [imagePath]; cloud results are URL-backed.
  final String? imageUrl;

  /// Ovid Cloud image request id behind an `imageGen` row, so Image receipts
  /// can show the saved result instead of "unavailable".
  final String? imageRequestId;

  final HtmlArtifact? htmlArtifact;

  /// User feedback on a FINAL assistant message (the chat feedback tracker message-feedback):
  /// 'up' | 'down' | null. Re-clicking the same value retracts (null).
  String? feedback;

  /// Optional note attached to a down-vote (why it was bad).
  String? feedbackNote;

  factory Message.fromJson(Map<String, dynamic> j) => Message(
    privateSyncId:
        j['privateSyncId'] as String? ??
        sha256
            .convert(
              utf8.encode(
                jsonEncode([
                  j['time'],
                  j['role'],
                  j['kind'],
                  j['content'],
                  j['toolName'],
                  j['toolTitle'],
                  j['toolSummary'],
                  j['toolDetail'],
                ]),
              ),
            )
            .toString(),
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
    toolInput: j['toolInput'] as String?,
    imagePath: j['imagePath'] as String?,
    imageUrl: j['imageUrl'] as String?,
    imageRequestId: j['imageRequestId'] is String
        ? j['imageRequestId'] as String
        : null,
    htmlArtifact: HtmlArtifact.tryFromJson(j['htmlArtifact']),
    feedback: j['feedback'] as String?,
    feedbackNote: j['feedbackNote'] as String?,
    attachments: [
      for (final a in (j['attachments'] as List? ?? []))
        if (a is Map<String, dynamic>) MessageAttachment.fromJson(a),
    ],
    time: j['time'] != null ? DateTime.tryParse(j['time'] as String) : null,
  );

  Map<String, dynamic> toJson() => {
    'privateSyncId': privateSyncId,
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
    if (toolInput != null) 'toolInput': toolInput,
    if (imagePath != null) 'imagePath': imagePath,
    if (imageUrl != null) 'imageUrl': imageUrl,
    if (imageRequestId != null) 'imageRequestId': imageRequestId,
    if (htmlArtifact != null) 'htmlArtifact': htmlArtifact!.toJson(),
    if (feedback != null) 'feedback': feedback,
    if (feedbackNote != null && feedbackNote!.isNotEmpty)
      'feedbackNote': feedbackNote,
    if (attachments.isNotEmpty)
      'attachments': [for (final a in attachments) a.toJson()],
    'time': time.toIso8601String(),
  };
}


class SessionAnalytics {
  int inputTokens;
  int outputTokens;
  int turns;
  int toolCalls;
  int toolMs;
  int llmMs;
  int ttftMs;
  int ttftSamples;
  int decodeTokens;
  int cacheReadTokens;
  int cacheWriteTokens;
  int contextTokens;
  int contextLimit;
  int contextSystemTokens;
  int contextToolTokens;
  int contextMessageTokens;
  double estimatedCostUsd;

  SessionAnalytics({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.turns = 0,
    this.toolCalls = 0,
    this.toolMs = 0,
    this.llmMs = 0,
    this.ttftMs = 0,
    this.ttftSamples = 0,
    this.decodeTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.contextTokens = 0,
    this.contextLimit = 0,
    this.contextSystemTokens = 0,
    this.contextToolTokens = 0,
    this.contextMessageTokens = 0,
    this.estimatedCostUsd = 0,
  });

  int get averageTtftMs => ttftSamples == 0 ? 0 : ttftMs ~/ ttftSamples;
  double get decodeTokensPerSecond =>
      llmMs <= 0 ? 0 : decodeTokens / (llmMs / 1000);
  /// Share of input tokens served from the provider prompt cache (0..100).
  double get cachedPercent =>
      inputTokens <= 0 ? 0 : (cacheReadTokens / inputTokens * 100).clamp(0, 100);
  double get contextFraction =>
      contextLimit <= 0 ? 0 : (contextTokens / contextLimit).clamp(0.0, 1.0);

  void add({
    int inputTokens = 0,
    int outputTokens = 0,
    int turns = 0,
    int toolCalls = 0,
    int toolMs = 0,
    int llmMs = 0,
    int ttftMs = 0,
    int ttftSamples = 0,
    int decodeTokens = 0,
    int cacheReadTokens = 0,
    int cacheWriteTokens = 0,
    int contextTokens = 0,
    int contextLimit = 0,
    int contextSystemTokens = 0,
    int contextToolTokens = 0,
    int contextMessageTokens = 0,
    double estimatedCostUsd = 0,
  }) {
    this.inputTokens += inputTokens;
    this.outputTokens += outputTokens;
    this.turns += turns;
    this.toolCalls += toolCalls;
    this.toolMs += toolMs;
    this.llmMs += llmMs;
    this.ttftMs += ttftMs;
    this.ttftSamples += ttftSamples;
    this.decodeTokens += decodeTokens;
    this.cacheReadTokens += cacheReadTokens;
    this.cacheWriteTokens += cacheWriteTokens;
    if (contextTokens > 0) this.contextTokens = contextTokens;
    if (contextLimit > 0) this.contextLimit = contextLimit;
    if (contextSystemTokens > 0) this.contextSystemTokens = contextSystemTokens;
    if (contextToolTokens > 0) this.contextToolTokens = contextToolTokens;
    if (contextMessageTokens > 0) {
      this.contextMessageTokens = contextMessageTokens;
    }
    this.estimatedCostUsd += estimatedCostUsd;
  }

  Map<String, dynamic> toJson() => {
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'turns': turns,
    'toolCalls': toolCalls,
    'toolMs': toolMs,
    'llmMs': llmMs,
    'ttftMs': ttftMs,
    'ttftSamples': ttftSamples,
    'decodeTokens': decodeTokens,
    'cacheReadTokens': cacheReadTokens,
    'cacheWriteTokens': cacheWriteTokens,
    'contextTokens': contextTokens,
    'contextLimit': contextLimit,
    'contextSystemTokens': contextSystemTokens,
    'contextToolTokens': contextToolTokens,
    'contextMessageTokens': contextMessageTokens,
    'estimatedCostUsd': estimatedCostUsd,
  };

  factory SessionAnalytics.fromJson(Map<String, dynamic>? json) {
    final j = json ?? const <String, dynamic>{};
    int i(String key) => (j[key] as num?)?.toInt() ?? 0;
    return SessionAnalytics(
      inputTokens: i('inputTokens'),
      outputTokens: i('outputTokens'),
      turns: i('turns'),
      toolCalls: i('toolCalls'),
      toolMs: i('toolMs'),
      llmMs: i('llmMs'),
      ttftMs: i('ttftMs'),
      ttftSamples: i('ttftSamples'),
      decodeTokens: i('decodeTokens'),
      cacheReadTokens: i('cacheReadTokens'),
      cacheWriteTokens: i('cacheWriteTokens'),
      contextTokens: i('contextTokens'),
      contextLimit: i('contextLimit'),
      contextSystemTokens: i('contextSystemTokens'),
      contextToolTokens: i('contextToolTokens'),
      contextMessageTokens: i('contextMessageTokens'),
      estimatedCostUsd: (j['estimatedCostUsd'] as num?)?.toDouble() ?? 0,
    );
  }
}

class ChatSession {
  /// Persisted session JSON schema. v2 (P8 Task 18) dropped the local
  /// agent-core fields: `grants`, `compactedSummary`, `compactionState`,
  /// `compactedAtCount`, `planPreMode`, `agentAllowedTools`. `fromJson`
  /// silently ignores unknown/removed keys, so a v1 row still loads.
  static const int schemaVersion = 2;

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
  /// or 'studio' (Studio). 'control' was retired (spec D5). Parallel
  /// sessions keep INDEPENDENT modes — no cross-session mode bleed.
  /// Persisted with the session.
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

  /// Whether [workspaceFolder] was chosen FOR THIS CHAT (composer picker or
  /// Studio bind) rather than carried over from the user's last selection.
  ///
  /// The distinction exists because of a real report: a brand-new chat
  /// inherited the previous Studio folder, and the system prompt then told the
  /// model "the user pinned this chat to the folder above". The model duly
  /// announced a repo and location the owner had never selected in that chat —
  /// a binding stated as fact that nobody had actually set up. Inheritance is
  /// intentional (spec §5.2: a restart must not force a fresh selection); the
  /// LIE about who chose it was not. Persisted with the session; absent/false
  /// for sessions written before this flag existed, which makes the prompt
  /// under-claim rather than over-claim.
  bool workspaceFolderPinned;

  /// Per-session Studio repo (owner/name).  Each session can work on a
  /// different repo; new sessions start with the global default (the last
  /// connected repo).  Persisted with the session.
  String? repo;

  /// Per-session Studio branch. Null falls back to the persisted [lastBranch]
  /// (default `main`) at the point of use, so the repo binding is the pair
  /// `(repo, branch)`. Persisted with the session.
  String? branch;

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

  bool get isSubagent => parentId != null;

  /// Session todo/task list — written by todo_write tool, rendered as a
  /// live checklist above the chat input.  Persisted with the session.
  final List<Map<String, String>> todos;

  /// Active goal (the goal manager goal-round equivalent) — created by create_goal,
  /// advanced by update_goal.  One goal per session at a time.  Persisted.
  Map<String, dynamic>? goal;

  /// Plan mode (the plan mode coordinator /plan parity) — persisted per session so a restart or
  /// session switch keeps the amber planning state.
  bool planMode;

  /// G2: a plan-mode transition the user requested while a turn was OPEN,
  /// waiting for the next turn boundary (dsh's `queued` state). Null = nothing
  /// queued. Persisted so a restart mid-turn does not lose the intent.
  bool? planModePending;

  final List<Message> messages;
  final DateTime createdAt;

  // [hasImage] cache: the scan covered `messages[0.._imageScanLength)` and
  // `_imageScanLast` was the last message it saw.
  int _imageScanLength = 0;
  Message? _imageScanLast;
  bool _hasImageCache = false;

  /// True when the transcript contains a generated image (the sidebar icon).
  ///
  /// [messages] is mutated in place everywhere, so this cannot be a stored
  /// flag. Appends only scan the new tail; any other change (truncation,
  /// edit, replace) triggers one full rescan. A list row reading this no
  /// longer walks the whole transcript on every rebuild.
  bool get hasImage {
    final length = messages.length;
    final last = length == 0 ? null : messages[length - 1];
    if (length == _imageScanLength && identical(last, _imageScanLast)) {
      return _hasImageCache;
    }
    final appended =
        length > _imageScanLength &&
        (_imageScanLength == 0 ||
            identical(messages[_imageScanLength - 1], _imageScanLast));
    var found = appended && _hasImageCache;
    for (var i = appended ? _imageScanLength : 0; !found && i < length; i++) {
      if (messages[i].kind == MsgKind.imageGen) found = true;
    }
    _imageScanLength = length;
    _imageScanLast = last;
    _hasImageCache = found;
    return found;
  }

  /// Last user-visible activity (F-046): touched on send and on reply
  /// completion. Null for sessions persisted before it existed; see
  /// [lastActivityAt] for the derived value the sidebar sorts by.
  DateTime? updatedAt;

  /// Most recent of [updatedAt], the newest message time and [createdAt].
  DateTime get lastActivityAt {
    var latest = createdAt;
    final touched = updatedAt;
    if (touched != null && touched.isAfter(latest)) latest = touched;
    if (messages.isNotEmpty && messages.last.time.isAfter(latest)) {
      latest = messages.last.time;
    }
    return latest;
  }

  /// Mark new activity now (send / reply complete).
  void touch([DateTime? at]) => updatedAt = at ?? DateTime.now();

  /// The assembled system prompt sent on this session's most recent turn.
  /// Surfaced as a collapsible "System prompt" disclosure so the user can
  /// see exactly what the model was told (context visibility parity).
  String? systemPromptSnapshot;

  /// Durable per-session analytics. This is intentionally separate from the
  /// global usage ledger: the composer must never show another session's data.
  final SessionAnalytics analytics;

  /// True once an LLM title has been generated for this session. Persisted so
  /// a restart never re-titles (and a manual regenerate can force it again).
  bool titleGenerated;

  /// Read-only transcript grants created by explicit user @session references.
  /// They belong to this chat, never to its children or other root chats.
  final Set<String> referencedSessionIds;
  final List<String> pendingAgentNotices;

  ChatSession({
    required this.id,
    required this.title,
    required this.model,
    this.providerId,
    this.sandboxId,
    this.repo,
    this.branch,
    this.mode = 'auto',
    this.presetId = 'standard',
    this.workspaceFolder,
    this.workspaceFolderPinned = false,
    this.systemPromptSnapshot,
    this.goal,
    this.planMode = false,
    this.planModePending,
    this.parentId,
    this.agentLabel,
    this.agentState,
    this.agentContinuable = false,
    this.agentResult,
    this.agentId,
    this.agentPersona,
    this.agentOutputHint,
    List<Message>? messages,
    List<Map<String, String>>? todos,
    DateTime? createdAt,
    this.updatedAt,
    SessionAnalytics? analytics,
    this.titleGenerated = false,
    Iterable<String> referencedSessionIds = const [],
    Iterable<String> pendingAgentNotices = const [],
  }) : referencedSessionIds = Set.of(referencedSessionIds),
       pendingAgentNotices = List.of(pendingAgentNotices),
       messages = messages ?? [],
       todos = todos ?? [],
       createdAt = createdAt ?? DateTime.now(),
       analytics = analytics ?? SessionAnalytics() {
    sandboxId ??= id;
  }

  factory ChatSession.fromJson(Map<String, dynamic> j) => ChatSession(
    id: j['id'] as String,
    title: j['title'] as String? ?? 'New chat',
    model: j['model'] as String? ?? 'Select a provider',
    providerId: j['providerId'] as String?,
    sandboxId: j['sandboxId'] as String?,
    repo: j['repo'] as String?,
    branch: j['branch'] as String?,
    mode: AppState.sanitizeColdStartMode(j['mode'] as String? ?? 'auto'),
    presetId: j['presetId'] as String? ?? 'standard',
    workspaceFolder: j['workspaceFolder'] as String?,
    workspaceFolderPinned: j['workspaceFolderPinned'] as bool? ?? false,
    systemPromptSnapshot: j['systemPromptSnapshot'] as String?,
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
    goal: j['goal'] == null
        ? null
        : Map<String, dynamic>.from(j['goal'] as Map),
    planMode: j['planMode'] as bool? ?? false,
    planModePending: j['planModePending'] as bool?,
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
    createdAt: j['createdAt'] != null
        ? DateTime.tryParse(j['createdAt'] as String) ?? DateTime.now()
        : DateTime.now(),
    updatedAt: j['updatedAt'] is String
        ? DateTime.tryParse(j['updatedAt'] as String)
        : null,
    analytics: SessionAnalytics.fromJson(
      j['analytics'] is Map
          ? Map<String, dynamic>.from(j['analytics'] as Map)
          : null,
    ),
    titleGenerated: j['titleGenerated'] as bool? ?? false,
    referencedSessionIds:
        (j['referencedSessionIds'] as List?)?.whereType<String>() ?? const [],
    pendingAgentNotices:
        (j['pendingAgentNotices'] as List?)?.whereType<String>() ?? const [],
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'title': title,
    'model': model,
    if (providerId != null) 'providerId': providerId,
    'sandboxId': sandboxId ?? id,
    if (repo != null) 'repo': repo,
    if (branch != null) 'branch': branch,
    'mode': mode,
    if (presetId != 'standard') 'presetId': presetId,
    if (workspaceFolder != null && workspaceFolder!.isNotEmpty)
      'workspaceFolder': workspaceFolder,
    if (workspaceFolderPinned) 'workspaceFolderPinned': true,
    if (systemPromptSnapshot != null)
      'systemPromptSnapshot': systemPromptSnapshot,
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
    if (goal != null) 'goal': goal,
    if (planMode) 'planMode': planMode,
    if (planModePending != null) 'planModePending': planModePending,
    'todos': todos,
    'messages': messages.map((m) => m.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
    'analytics': analytics.toJson(),
    if (titleGenerated) 'titleGenerated': true,
    if (referencedSessionIds.isNotEmpty)
      'referencedSessionIds': referencedSessionIds.toList(),
    if (pendingAgentNotices.isNotEmpty)
      'pendingAgentNotices': pendingAgentNotices,
  };

  void recordAnalytics({
    int inputTokens = 0,
    int outputTokens = 0,
    int turns = 0,
    int toolCalls = 0,
    int toolMs = 0,
    int llmMs = 0,
    int ttftMs = 0,
    int ttftSamples = 0,
    int decodeTokens = 0,
    int cacheReadTokens = 0,
    int cacheWriteTokens = 0,
    int contextTokens = 0,
    int contextLimit = 0,
    int contextSystemTokens = 0,
    int contextToolTokens = 0,
    int contextMessageTokens = 0,
    double estimatedCostUsd = 0,
  }) => analytics.add(
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    turns: turns,
    toolCalls: toolCalls,
    toolMs: toolMs,
    llmMs: llmMs,
    ttftMs: ttftMs,
    ttftSamples: ttftSamples,
    decodeTokens: decodeTokens,
    cacheReadTokens: cacheReadTokens,
    cacheWriteTokens: cacheWriteTokens,
    contextTokens: contextTokens,
    contextLimit: contextLimit,
    contextSystemTokens: contextSystemTokens,
    contextToolTokens: contextToolTokens,
    contextMessageTokens: contextMessageTokens,
    estimatedCostUsd: estimatedCostUsd,
  );
}

/// ---------- App state ----------

typedef StartupStageDelegate = Future<void> Function();
typedef PersistedSessionDecoder = ChatSession Function(String encoded);
typedef SessionBootstrapDecoder = Map<String, dynamic> Function(String encoded);
typedef WorkspaceDeleter = Future<void> Function(String sandboxId);

/// Observe failures immediately while retaining the operation for explicit
/// retries. A fire-and-forget deletion must never lose its failure to a drain.
class _SessionCleanup {
  _SessionCleanup(this.operation) {
    retry();
  }

  final Future<void> Function() operation;
  late Future<void> pending;
  Object? error;
  bool running = false;

  void retry() {
    if (running) return;
    running = true;
    pending = Future<void>.sync(operation).then<void>(
      (_) {
        error = null;
        running = false;
      },
      onError: (Object failure) {
        error = failure;
        running = false;
      },
    );
  }
}

class _AccountHandoff {
  _AccountHandoff(this.account, this.rows, this.active);
  final String account;
  final List<String> rows;
  final String? active;
}

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

/// Full decode of every stored row for hydration (runs in an isolate for
/// large histories). Null marks a row that must stay opaque.
List<ChatSession?> _decodePersistedSessions(List<String> rows) => [
  for (final encoded in rows)
    () {
      try {
        final json = jsonDecode(encoded) as Map<String, dynamic>;
        final id = json['id'];
        if (id is! String || id.isEmpty) return null;
        return ChatSession.fromJson(json);
      } catch (_) {
        return null;
      }
    }(),
];

// Top-level so the isolate closure captures only [rows], never AppState.
Future<List<ChatSession?>> _decodePersistedSessionsInIsolate(
  List<String> rows,
) => Isolate.run(() => _decodePersistedSessions(rows));

/// Per-session local scratch directory.
///
/// The on-device Termux/proot sandbox was removed in P8 Task 13. Surviving
/// local-only paths (the legacy agent loop until Task 19, hook execution,
/// Studio drafts) still need a per-session working directory; this is
/// app-cache scratch space, NOT a Linux userland.
Directory localWorkspaceDirFor(String id) {
  // A user-pinned working folder still wins (workspace authority): the
  // on-device sandbox is gone, but the session's selected folder is a real
  // path on disk and remains the single source of truth for tool cwd.
  //
  // The provider is installed by the AppState constructor. It is null during
  // the very first local-workspace resolution (AppState's own singleton is
  // still initializing), in which case scratch space is the only safe answer.
  final pinned = AppState.workspaceDirProvider?.call(id);
  if (pinned != null) return pinned;
  final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final dir = Directory('${Directory.systemTemp.path}/ovid_workspaces/$safe');
  try {
    dir.createSync(recursive: true);
  } catch (_) {
    // Best effort: callers surface their own filesystem errors.
  }
  return dir;
}

/// Default workspace deleter (the sandbox's userland deleter is gone).
Future<void> _deleteLocalWorkspace(String id) async {
  try {
    final dir = localWorkspaceDirFor(id);
    if (dir.existsSync()) await dir.delete(recursive: true);
  } catch (_) {
    // Reset must never fail on a missing/locked scratch dir.
  }
}

String _sessionSourceFingerprint(String encoded) =>
    sha256.convert(utf8.encode(encoded)).toString();

/// Why [AppState.addMarketplaceChecked] refused an input.
enum MarketplaceAddError { invalid, duplicate }

/// Outcome of one marketplace sync (moved from the deleted startup_tasks in
/// P8 Task 13).
enum MarketplaceSyncOutcome { ready, degraded, failed }

/// Prefix of the fetch message when no marketplace host could be reached.
const kMarketplaceOfflinePrefix = "Couldn't reach GitHub for";

/// Per-repo outcome of one marketplace sync.
class MarketplaceSyncReport {
  final int fetched;

  /// Normalized repo → failure message.
  final Map<String, String> failures;

  const MarketplaceSyncReport({required this.fetched, required this.failures});

  /// Every failure was "no host reachable": the device is offline.
  bool get offline =>
      failures.isNotEmpty &&
      failures.values.every((m) => m.startsWith(kMarketplaceOfflinePrefix));
}

class AppState extends ChangeNotifier {
  /// Singleton — everything is user-side / on-device.
  static AppState? _testInstance;

  /// Resolves a session's pinned working folder for [localWorkspaceDirFor].
  /// Installed by the constructor; null while the singleton is initializing.
  static Directory? Function(String id)? workspaceDirProvider;
  static AppState get I => _testInstance ?? _singleton;
  static final AppState _singleton = AppState._();

  /// Cold-start mode normalization. Previously downgraded a persisted
  /// `control` session to `drive`; that made the agent silently lose its
  /// device_* tools after every app restart (they are hard-denied outside
  /// Control mode) even though the OS accessibility service was healthy —
  /// the "accessibility stopped working after restart" report. The mode is
  /// now restored as-is: no run auto-resumes after a restart (a persisted
  /// `running` agentState is restored as `stopped`), so restoring `control`
  /// is safe — the user must still explicitly start a task before anything
  /// can drive the device.
  static String sanitizeColdStartMode(String mode) {
    return mode;
  }

  @visibleForTesting
  factory AppState.createForTest({
    Directory? memoryRootForTest,
    String? sessionAccountIdForTest,
    void Function(String stage)? startupStageRecorder,
    Map<String, StartupStageDelegate> startupStageDelegates = const {},
    PersistedSessionDecoder? persistedSessionDecoder,
    SessionBootstrapDecoder? sessionBootstrapDecoder,
    WorkspaceDeleter? workspaceDeleter,
    AccountLifecycleIntegration? accountLifecycle,
    Duration sessionPersistDebounce = Duration.zero,
  }) {
    final instance = AppState._(
      memoryRootForTest: memoryRootForTest,
      sessionAccountIdForTest: sessionAccountIdForTest,
      startupStageRecorder: startupStageRecorder,
      startupStageDelegates: startupStageDelegates,
      persistedSessionDecoder: persistedSessionDecoder,
      sessionBootstrapDecoder: sessionBootstrapDecoder,
      workspaceDeleter: workspaceDeleter,
      accountLifecycle: accountLifecycle,
      sessionPersistDebounce: sessionPersistDebounce,
    );
    _testInstance = instance;
    return instance;
  }

  @visibleForTesting
  static AccountLifecycleIntegration productionAccountLifecycleForTest({
    required bool accountAvailable,
  }) => AccountLifecycleIntegration.production(
    dependencies: accountAvailable
        ? AccountLifecycleDependencies(
            onFence: () {},
            onRevoke: () async {},
            onBind: (_, _) async {},
            onClear: () async {},
            onVerifyEmpty: () async => true,
          )
        : null,
  );

  /// Enable the production trailing debounce for session writes. Never called
  /// from tests, which keep a zero window (microtask) so no Timer is left
  /// pending after a `testWidgets` tree is disposed.
  static void enableSessionPersistDebounce([
    Duration window = _productionSessionPersistDebounce,
  ]) {
    _singleton._sessionPersistDebounce = window;
  }

  @visibleForTesting
  static void resetTestInstance() {
    _testInstance?.sessionEncodeCountsForTest.clear();
    _testInstance?._cancelPersistDebounce();
    _testInstance = null;
    _singleton._bindSettingsActions();
    // ignore: invalid_use_of_visible_for_testing_member
    ComposerDraftStore.I.resetForTest();
    // Title generation is server-owned on the thin client (the local
    // title state died with the retired service).
  }

  AppState._({
    Directory? memoryRootForTest,
    String? sessionAccountIdForTest,
    this._startupStageRecorder,
    Map<String, StartupStageDelegate> startupStageDelegates = const {},
    PersistedSessionDecoder? persistedSessionDecoder,
    SessionBootstrapDecoder? sessionBootstrapDecoder,
    WorkspaceDeleter? workspaceDeleter,
    AccountLifecycleIntegration? accountLifecycle,
    Duration? sessionPersistDebounce,
  }) : _startupStageDelegates = Map.unmodifiable(startupStageDelegates),
       _memoryRootOverride = memoryRootForTest {
    _sessionPersistDebounce = sessionPersistDebounce ?? Duration.zero;
    _sessionAccountId = sessionAccountIdForTest ?? 'guest';
    _persistedSessionDecoderForTest = persistedSessionDecoder;
    _sessionBootstrapDecoder =
        sessionBootstrapDecoder ??
        (encoded) => jsonDecode(encoded) as Map<String, dynamic>;
    _workspaceDeleter = workspaceDeleter ?? _deleteLocalWorkspace;
    _accountLifecycle =
        accountLifecycle ?? AccountLifecycleIntegration.production();
    _seed();
    _ensureActiveSession();
    _bindSettingsActions();
    workspaceDirProvider = (id) {
      final session = sessions
          .where((s) => (s.sandboxId ?? s.id) == id)
          .firstOrNull;
      final pinned = session?.workspaceFolder;
      if (pinned != null &&
          pinned.trim().isNotEmpty &&
          Directory(pinned).existsSync()) {
        return Directory(pinned);
      }
      return null;
    };
  }

  final void Function(String stage)? _startupStageRecorder;
  final Map<String, StartupStageDelegate> _startupStageDelegates;
  PersistedSessionDecoder? _persistedSessionDecoderForTest;
  late final SessionBootstrapDecoder _sessionBootstrapDecoder;
  late final WorkspaceDeleter _workspaceDeleter;
  late AccountLifecycleIntegration _accountLifecycle;
  CollaborationProduction? collaboration;
  Future<void>? _featureBinding;
  bool _featureBindQueued = false;

  /// Shown when a live-collaboration turn is attempted on the thin client.
  /// Collab EXECUTION is flag-gated OFF here (owner question Q6; the default
  /// is reversible in Task 20 — collab v2 lands in P9).
  static const String kCollaborationReadOnlyNotice =
      'Collaboration is moving to the cloud — read-only for now';

  /// Called by main before readiness begins. Registers the actual singleton
  /// owners with account transitions and verified per-feature reset.
  void registerProductionAccountFeatures({FirebaseService? firebaseService}) {
    if (collaboration != null) return;
    final firebase = firebaseService ?? FirebaseService.I;
    final appCheck = CloudAppCheck(
      initializeFirebase: firebase.initialize,
      activatedByFirebase: () => firebase.accountService.enabled,
    );
    collaboration = CollaborationProduction(
      // Each participant's turns run on THEIR device, model and key — except
      // on the thin client, where collab execution is read-only for now.
      turnRunner: _collaborationTurnRunner,
      rootDirectory: getApplicationSupportDirectory,
      accountReady: () => firebase.isAvailable && firebase.accountReady,
      currentUid: () => firebase.uid,
      accessToken: () => firebase.getIdToken(),
      appCheckToken: appCheck.getToken,
    );
    final collab = collaboration!;
    _accountLifecycle = AccountLifecycleIntegration.production(
      dependencies: AccountLifecycleDependencies(
        onFence: collab.fence,
        onRevoke: () async {
          await _featureBinding;
          await collab.release();
        },
        onBind: (_, _) => _queueProductionAccountBind(),
        onClear: collab.clear,
        onVerifyEmpty: collab.verifyEmpty,
      ),
      resetDependencies: {
        ResetStoreKind.collaboration.id: collab.lifecycle,
      },
    );
    addListener(_queueProductionAccountBind);
    firebase.addListener(_queueProductionAccountBind);
    _queueProductionAccountBind();
  }

  /// Collab-turn path shared by the production runner and the gate test.
  /// On the thin client it appends the read-only notice as a turn-tail row
  /// and performs NO agent execution.
  Future<String> _collaborationTurnRunner({
    required String providerId,
    required String model,
    required List<Map<String, dynamic>> messages,
  }) async {
    // Local provider execution died with the retired local service (P8 Task 19).
    // Live collaboration replies are server-owned; the thin client cannot
    // call a user's provider from this device.
    _appendCollabReadOnlyNotice();
    throw StateError(kCollaborationReadOnlyNotice);
  }

  void _appendCollabReadOnlyNotice() {
    final session = activeSession;
    if (session == null) return;
    session.messages.add(
      Message(
        role: 'assistant',
        kind: MsgKind.turnTail,
        content: kCollaborationReadOnlyNotice,
      ),
    );
    _markSessionDirty(session.id);
    notifyListeners();
    unawaited(persistSessions());
  }

  /// Test seam: drives the same collab-turn path the production runner uses.
  @visibleForTesting
  Future<String> collaborationTurnForTest({
    required String providerId,
    required String model,
    required List<Map<String, dynamic>> messages,
  }) => _collaborationTurnRunner(
    providerId: providerId,
    model: model,
    messages: messages,
  );

  void _queueProductionAccountBind() {
    if (_settingsBusy || _featureBindQueued || collaboration == null) return;
    if (!FirebaseService.I.accountReady || !sessionAccountReady) return;
    _featureBindQueued = true;
    scheduleMicrotask(() {
      _featureBindQueued = false;
      if (_settingsBusy ||
          !FirebaseService.I.accountReady ||
          _featureBinding != null) {
        return;
      }
      final uid = FirebaseService.I.uid;
      if (uid == null) return;
      _featureBinding = () async {
        try {
          await collaboration!.bind(uid, _deferredSessionGeneration);
        } finally {
          _featureBinding = null;
        }
      }();
    });
  }

  void setAccountFeaturesForeground(bool value) {
    collaboration?.setForeground(value);
    if (value) _queueProductionAccountBind();
  }

  static final _secureStorage = ovidSecureStorage();

  static const _providerKeyPrefix = 'ovid_provider_key_';
  Future<void>? _initialization;
  Future<void>? _firstFrameInitialization;
  Future<void>? _readinessInitialization;
  final Object _bootToken = Object();
  final Completer<void> _bootActivationSettled = Completer<void>();
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
  final List<_SessionCleanup> _pendingWorkspaceDeletions = [];
  String? _deferredActiveSessionId;
  ChatSession? _deferredActiveSession;
  final Map<String, ({ChatSession owner, int? prefixLength})>
  _deferredProjections = {};
  int _deferredActiveTailLength = 0;
  var _deferredSessionGeneration = 0;

  String _sessionAccountId = 'guest';
  Object _sessionAccountToken = Object();
  // Cleanup ownership changes only on an actual account handoff. A settings
  // barrier invalidates producers, but must still drain already-owned deletes.
  Object _sessionCleanupToken = Object();
  bool _sessionAccountReady = true;
  bool _sessionNamespaceLoaded = false;
  Future<void>? _accountTransition;
  bool _settingsBusy = false;

  /// Test seam: simulates a settings operation holding the session stores.
  @visibleForTesting
  set settingsBusyForTest(bool value) => _settingsBusy = value;
  Future<void>? _settingsOperation;
  final List<_SessionCleanup> _pendingAccountCleanup = [];
  final Map<String, _AccountHandoff> _retainedHandoffs = {};
  String get sessionAccountId => _sessionAccountId;
  Object get sessionAccountToken => _sessionAccountToken;
  bool get sessionAccountReady => _sessionAccountReady && !_settingsBusy;
  String _accountKey(String key, [String? account]) {
    final owner = account ?? _sessionAccountId;
    return owner == 'guest'
        ? key
        : '${key}_owner_${Uri.encodeComponent(owner)}';
  }

  /// The prefs key for [key] under [account] (the current account when
  /// omitted). Guest keeps the plain key, matching every `_accountKey` use
  /// above. Stores that persist per-account rows off the session namespace
  /// (e.g. the cloud prompt outbox) derive their keys through this so the
  /// `_owner_` spelling stays single-sourced.
  String accountScopedPrefKey(String key, [String? account]) =>
      _accountKey(key, account);

  /// Revoke old ownership synchronously, then restore only the explicitly
  /// named local namespace. Legacy rows have no UID provenance and stay guest.
  Future<void> transitionSessionAccount(String account) {
    if (account == _sessionAccountId && _accountTransition != null) {
      return _accountTransition!;
    }
    final oldAccount = _sessionAccountId;
    final oldRows =
        _sessionAccountReady &&
            _sessionNamespaceLoaded &&
            (sessions.isNotEmpty || _deferredSessionJson != null)
        ? _sessionJsonForPersistence()
        : null;
    final oldActive = activeSessionId;
    if (oldRows != null) {
      _retainedHandoffs[oldAccount] = _AccountHandoff(
        oldAccount,
        oldRows,
        oldActive,
      );
    }
    final previous = _accountTransition;
    final settingsOperation = _settingsOperation;
    final writing = _persistWriteInFlight;
    final oldCleanup = _pendingWorkspaceDeletions.toList();
    // Start outstanding retries while their original account is still
    // current. Once the token changes an old retry must never act on B.
    for (final task in oldCleanup) {
      if (!task.running && task.error != null) task.retry();
    }
    _cancelPersistDebounce();
    _persistScheduled = false;
    _completeScheduledPersistence();
    final token = _sessionAccountToken = Object();
    _sessionCleanupToken = Object();
    _sessionAccountId = account;
    _sessionAccountReady = false;
    _sessionNamespaceLoaded = false;
    _clearDeferredSessions();
    _dirtySessionIds.clear();
    _notifiedDeletedSessionIds.clear();
    _pendingWorkspaceDeletions.clear();
    _pendingAccountCleanup.addAll(oldCleanup);
    sessions.clear();
    activeSessionId = null;
    _accountLifecycle.fenceSynchronously();
    CloudAgentFacade.resetAccountStateIfInstalled();
    final cleanup = _SessionCleanup(() async {
      if (!identical(token, _sessionAccountToken)) return;
      try {
        await SessionSearch.I.setAccount(account);
      } on ArgumentError catch (error) {
        // FTS is derived data and is unavailable in SDK-free desktop/test
        // environments without the sqlite native library. Account hydration
        // must still reach the durable account stores in that case.
        if (!error.toString().contains('libsqlite3.so')) rethrow;
      }
    });
    _pendingWorkspaceDeletions.add(cleanup);
    notifyListeners();
    late final Future<void> transition;
    transition = () async {
      try {
        try {
          await previous;
        } catch (_) {
          /* a newer owner may retry */
        }
        await writing;
        // A failed restore must roll back its captured namespace before any
        // account (including A -> B -> A) can hydrate or write that namespace.
        await settingsOperation;
        for (final task in List<_SessionCleanup>.of(_pendingAccountCleanup)) {
          await task.pending;
          if (task.error != null) {
            throw StateError('Previous account cleanup incomplete');
          }
          _pendingAccountCleanup.remove(task);
        }
        await _accountLifecycle.revoke();
        final prefs = await SharedPreferences.getInstance();
        for (final handoff in List.of(_retainedHandoffs.values)) {
          await _writeAccountHandoff(prefs, handoff);
          if (identical(_retainedHandoffs[handoff.account], handoff)) {
            _retainedHandoffs.remove(handoff.account);
          }
        }
        await cleanup.pending;
        if (!identical(token, _sessionAccountToken)) return;
        if (cleanup.error != null) {
          // FTS is derived data, but a failed handoff must still block the
          // replacement account from publishing. Callers observe the
          // contract error, never the raw store failure underneath.
          throw StateError('Account search cleanup incomplete');
        }
        // No provisional guest transcript is ever attributed to a Firebase UID.
        final storedRows = await SessionHistoryRepository.I.readRows(
          prefs,
          _accountKey(_kSessions),
        );
        if (!identical(token, _sessionAccountToken)) return;
        _deferredSessionJson = List.of(storedRows ?? const <String>[]);
        activeSessionId = prefs.getString(_accountKey(_kActive));
        await _hydrateDeferredSessions();
        if (!identical(token, _sessionAccountToken)) return;
        await _accountLifecycle.onBind(account, _deferredSessionGeneration);
        _sessionAccountReady = true;
        _sessionNamespaceLoaded = true;
        lastSessionPersistFailed = false;
        notifyListeners();
      } catch (_) {
        if (identical(token, _sessionAccountToken)) {
          lastSessionPersistFailed = true;
          notifyListeners();
        }
        rethrow;
      } finally {
        if (identical(_accountTransition, transition)) {
          _accountTransition = null;
        }
      }
    }();
    _accountTransition = transition;
    return transition;
  }

  Future<void> _writeAccountHandoff(
    SharedPreferences prefs,
    _AccountHandoff handoff,
  ) async {
    if (handoff.rows.isNotEmpty) {
      if (!await SessionHistoryRepository.I.writeRows(
        prefs,
        _accountKey(_kSessions, handoff.account),
        handoff.rows,
      )) {
        throw StateError('Account session storage rejected write');
      }
      final saved = handoff.active == null
          ? await prefs.remove(_accountKey(_kActive, handoff.account))
          : await prefs.setString(
              _accountKey(_kActive, handoff.account),
              handoff.active!,
            );
      if (!saved) {
        throw StateError('Account active session storage rejected write');
      }
    }
  }

  // ── Coalesced per-session persistence (spec §5.4) ────────────────────────
  /// Ids whose content changed since the last successful write. Mutations mark
  /// here; unchanged sessions reuse their last encoded raw.
  final Set<String> _dirtySessionIds = {};

  /// Forces the next build to re-encode every session (list membership or a
  /// wholesale reset invalidated the derivative raw cache).
  var _persistFullRewrite = true;

  /// Last successfully written raw JSON per in-memory session id.
  final Map<String, String> _persistedSessionRaw = {};

  /// Content signature captured with [_persistedSessionRaw]; a mismatch means
  /// the session changed in place without an explicit dirty mark.
  final Map<String, Object?> _persistedSessionSignature = {};
  List<String> _persistedSessionIds = [];
  String? _persistedActiveSessionId;
  int _persistedDeferredGeneration = 0;
  Set<String> _persistedDeferredDeletedIds = {};

  var _persistScheduled = false;
  Completer<void>? _persistCompleter;
  Future<void>? _persistScheduledFuture;
  Future<bool>? _persistWriteInFlight;

  /// B4: true when the most recent session write failed. Chat history is not
  /// durable while this is set; the UI can surface it and a later successful
  /// write clears it.
  bool lastSessionPersistFailed = false;

  /// Test seam: force the next `_writeSessionsNow` to throw so the failure
  /// path (flag + cache invalidation + notifyListeners) can be exercised.
  /// One-shot — it clears itself as it fires so the following write succeeds.
  @visibleForTesting
  bool failNextSessionWriteForTest = false;

  /// Trailing debounce window for coalescing session writes. Defaults to zero
  /// (microtask) so tests leave no wall-clock Timer pending; production opts in
  /// via [enableSessionPersistDebounce] from `main`.
  static const _productionSessionPersistDebounce = Duration(milliseconds: 200);
  Duration _sessionPersistDebounce = Duration.zero;
  Timer? _persistDebounceTimer;
  Timer? _persistMaxWaitTimer;

  /// Test seam: count of full-session encodes performed, keyed by session id.
  @visibleForTesting
  final Map<String, int> sessionEncodeCountsForTest = {};

  /// Test seam: when true, [persistSessions] marks changes but holds the
  /// coalesced write until an explicit [flushSessionPersistence].
  @visibleForTesting
  var suspendCoalescedPersistenceForTest = false;
  var _sessionRestoreFinished = false;
  var _sessionRestoreRequested = false;
  var _skillMountSettled = false;
  var _skillMountSucceeded = false;
  String? _pendingActiveRootId;
  final List<Future<void>> _pendingSessionLifecycles = [];

  /// Process-local boot identity (Task 2). The session lifecycle service keys
  /// its exactly-once reservations by this token; a resume/reconnect reuses it.
  Object get bootToken => _bootToken;

  /// Completes once boot activation has settled (success, failure, or skip).
  /// Session creation awaits this barrier before firing `session_start` so a
  /// restored session never observes an unactivated runtime.
  Future<void> get bootActivationSettled => _bootActivationSettled.future;

  /// Track a fire-and-forget session lifecycle dispatch (test seam).
  @visibleForTesting
  Future<void> drainSessionLifecycleForTest() async {
    while (_pendingSessionLifecycles.isNotEmpty) {
      await Future.wait(List<Future<void>>.of(_pendingSessionLifecycles));
    }
  }

  void _trackSessionLifecycle(Future<void> future) {
    _pendingSessionLifecycles.add(future);
    future.whenComplete(() {
      _pendingSessionLifecycles.remove(future);
    });
  }

  /// Persist [session] before the run can start (the local lifecycle service
  /// died with the agent-core satellite strip; cloud session lifecycle is
  /// server-owned).
  Future<void> _dispatchSessionStart(ChatSession session) {
    final future = () async {
      try {
        await flushSessionPersistence();
      } catch (e) {
        Diag.swallow('state', e);
      }
    }();
    _trackSessionLifecycle(future);
    return future;
  }

  Future<void> initialize() => _initialization ??= initializeReadiness();

  Future<void> initializeForFirstFrame() =>
      _firstFrameInitialization ??= _initializeForFirstFrame();

  Future<void> _initializeForFirstFrame() async {
    _startupStageRecorder?.call('local.firstFrame');
    await loadProviderState();
    await _loadSessionsForFirstFrame();
    await _loadLastSelection();
    await _loadShellPreferences();
  }



  Future<bool> _initializeFirebaseForStartup() async {
    bool? available;
    final overridden = await _runStartupStage('firebase.initialize', () async {
      try {
        await FirebaseService.I.initialize();
      } catch (_) {
        // Firebase is optional; the startup task maps unavailable to degraded.
      }
      available = FirebaseService.I.isAvailable;
    });
    if (overridden) return true;
    return available ?? false;
  }

  Future<void> initializeReadiness() =>
      _readinessInitialization ??= _initializeReadiness();

  Future<void> _initializeReadiness() async {
    _readinessStarted = true;
    if (!_readinessStartedSignal.isCompleted) {
      _readinessStartedSignal.complete();
    }
    await initializeForFirstFrame();
    // Device integrity probe (root / hooking framework / debugger). Best
    // effort and non-blocking for the rest of readiness — a missing native
    // handler degrades to an empty result, never a failure.
    unawaited(refreshDeviceSecurity());
    // P8 Task 13: the StartupCoordinator/task dashboard was removed with the
    // on-device runtime install. The boot stages it orchestrated are still
    // required by the local plugin/MCP/skill stack (until Task 17), so they
    // now run sequentially here, honouring the same stage seams.
    try {
      await _runStartupStage('local.hydrate', _hydrateRemainingLocalState);
      _localHydrationSettled = true;
      _localHydrationReady = _unparsedSessionJson.isEmpty;
      // The local plugin runtime is gone (P8 Task 17); release the session
      // lifecycle activation barrier immediately.
      if (!_bootActivationSettled.isCompleted) {
        _bootActivationSettled.complete();
      }
      _skillMountSettled = false;
      _skillMountSucceeded = false;
      try {
        await _runStartupStage('skill.mount', _mountRuntimeSkills);
        _skillMountSucceeded = true;
      } catch (_) {
      } finally {
        _skillMountSettled = true;
      }
      _sessionRestoreRequested = true;
      await _maybeFinishSessionRestore();
      await _runStartupStage('github.initialize', GitHubService.I.initialize);
      await _initializeFirebaseForStartup();
    } finally {
      _readinessComplete = true;
    }
  }

  Future<bool> _runStartupStage(String id, StartupStageDelegate body) async {
    _startupStageRecorder?.call(id);
    final override = _startupStageDelegates[id];
    try {
      if (override != null) {
        await override();
        return true;
      }
      await body();
      return false;
    } finally {
      // Keep the activation barrier settled for session creation.
      if (!_bootActivationSettled.isCompleted) {
        _bootActivationSettled.complete();
      }
    }
  }

  Future<void> _hydrateRemainingLocalState() async {
    await loadProviderCredentials();
    await loadSessions();
    await _loadOvidCloudTier();
    await _loadCustomPresets();
  }

  Future<void> _mountRuntimeSkills() async {
    // Skills are mounted server-side on the thin client (P8 Tasks 17/19);
    // the local skill runtime is gone, so the startup stage is a no-op.
  }

  Future<bool> _maybeFinishSessionRestore() async {
    if (_sessionRestoreFinished) return true;
    if (!_sessionRestoreRequested ||
        !_localHydrationSettled ||
        !_localHydrationReady ||
        !_bootActivationSettled.isCompleted ||
        !_skillMountSettled ||
        !_skillMountSucceeded) {
      return false;
    }
    // Run checkpoints were a local-loop resume mechanism; the server owns
    // run lifecycle now, so there is nothing local to restore.
    onSessionsLoaded?.call();
    _sessionRestoreFinished = true;
    // Dispatch the CAPTURED boot-active root, not whatever is active now.
    // Startup can take seconds while the shell is interactive; a user
    // newSession()/selectSession() in that window must not steal the restored
    // event or receive a mislabel.
    final root = sessionById(_pendingActiveRootId);
    if (root != null && !root.isSubagent) {
    }
    return true;
  }

  bool get startupSafeToReconnect => _readinessComplete;

  Future<void> reconnectServicesAfterResume() {
    if (startupSafeToReconnect) return _runResumeReconnect();
    return _pendingResumeReconnect ??= _reconnectWhenStartupSettles();
  }

  Future<void> _reconnectWhenStartupSettles() async {
    try {
      if (!_readinessStarted) await _readinessStartedSignal.future;
      await (_readinessInitialization ?? Future<void>.value());
      await _runResumeReconnect();
    } finally {
      _pendingResumeReconnect = null;
    }
  }

  Future<void> _runResumeReconnect() async {
    // Cloud services reconnect through the WS multiplexer (shell lifecycle);
    // there is no local runtime left to respawn.
  }

  /// Test seam: re-run the shell-preferences load (simulates a restart).
  @visibleForTesting
  Future<void> reloadShellPreferencesForTest() => _loadShellPreferences();

  Future<void> _loadShellPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final t = prefs.getInt(_kResponseTimeout);
      if (t != null && t >= 5 && t <= maxResponseTimeoutSec) {
        responseTimeoutSec = t < minResponseTimeoutSec
            ? minResponseTimeoutSec
            : t;
      }
      contextWindowOverride = prefs.getInt(_kContextWindowOverride) ?? 0;
      maxOutputTokens = prefs.getInt(_kMaxOutputTokens) ?? 0;
      shareSessionMemory = prefs.getBool(_kShareMemory) ?? false;
      final savedThemeMode = prefs.getString(_kThemeMode);
      if (savedThemeMode == null || savedThemeMode.isEmpty) {
        final legacyLight = prefs.getBool(_kTheme);
        themeMode = legacyLight == null
            ? 'system'
            : (legacyLight ? 'light' : 'dark');
      } else {
        themeMode = savedThemeMode;
      }
      if (themeMode == 'light') {
        lightTheme = true;
      } else if (themeMode == 'dark') {
        lightTheme = false;
      }
      memoryEnabled = prefs.getBool(_kMemoryEnabled) ?? true;
      showReasoning = prefs.getBool(_kShowReasoning) ?? true;
      githubSync = prefs.getBool(_kGithubSync) ?? true;
      workflowEnabled = prefs.getBool(_kWorkflowEnabled) ?? true;
      autoRunSafeCommands = prefs.getBool(_kAutoRunSafe) ?? true;
      sendWhileBusy = prefs.getString(_kSendWhileBusy) ?? 'queue';
      conversationDisplay = prefs.getString(_kConversationDisplay) ?? 'compact';
      localePref = prefs.getString(_kLocale) ?? 'system';
      seenWelcomeVersion = prefs.getString(_kWelcome) ?? '';
      _notificationsEnabled = prefs.getBool(_kNotificationsPref) ?? true;
      chatFontScale = (prefs.getDouble(_kChatFontScale) ?? 1.0).clamp(
        chatFontScaleMin,
        chatFontScaleMax,
      );
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  /// Last model the user picked — carried into new sessions (Ovid-style
  /// default model) and restored across app restarts.
  String lastSelectedModel = '';
  String? lastSelectedProviderId;

  /// Most-recently selected models, newest first. Identity is
  /// `(providerId, model)` so the same model id exposed by two providers
  /// never collides. Surfaced at the top of the model picker.
  final List<({String providerId, String model})> recentModels = [];

  @visibleForTesting
  static File? recentModelsFileOverrideForTest;

  static Future<File?> _recentModelsJsonFile() async {
    if (recentModelsFileOverrideForTest != null) {
      return recentModelsFileOverrideForTest!;
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      return File('${dir.path}/recent_models.json');
    } catch (_) {
      return null;
    }
  }

  /// Last Studio repo (owner/name) and pinned workspace folder — carried into
  /// new sessions so a restart never forces fresh repo/folder selection.
  String? lastRepoFull;
  String lastBranch = 'main';
  String? lastWorkspaceFolder;

  Future<void> _loadLastSelection() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      lastSelectedModel = prefs.getString(_kLastModel) ?? '';
      lastSelectedProviderId = prefs.getString(_kLastProvider);
      await _loadRecentModels(prefs);
      lastRepoFull = prefs.getString(_kLastRepo);
      final storedBranch = prefs.getString(_kLastBranch);
      lastBranch = storedBranch ?? 'main';
      lastWorkspaceFolder = prefs.getString(_kLastWorkspace);
      // Backfill from the currently-restored active session if nothing
      // was persisted yet (upgrade path for existing installs).
      final s = activeSession;
      if (lastSelectedModel.isEmpty) {
        if (s != null && s.model != 'Select a provider') {
          lastSelectedModel = s.model;
          lastSelectedProviderId = s.providerId;
        }
      }
      // Owner directive 2026-10-18: Auto is ALWAYS pre-selected — a cloud-only
      // app has no "unconfigured" state. An empty backfill (fresh install)
      // and the legacy 'Select a provider' sentinel both resolve to Ovid
      // Cloud's `auto` alias so the header can never read "Select model".
      if (lastSelectedModel.isEmpty || lastSelectedModel == 'Select a provider') {
        lastSelectedModel = 'auto';
        lastSelectedProviderId = ovidCloudProviderId;
      }
      // Sessions still carrying the sentinel (created before the directive)
      // migrate on this same bootstrap.
      for (final session in sessions) {
        if (session.model == 'Select a provider' || session.model.trim().isEmpty) {
          session.model = 'auto';
          session.providerId ??= ovidCloudProviderId;
          _markSessionDirty(session.id);
        }
      }
      if (lastSelectedModel.isNotEmpty &&
          lastSelectedModel != 'Select a provider') {
        final pId =
            (lastSelectedProviderId != null &&
                lastSelectedProviderId!.isNotEmpty)
            ? lastSelectedProviderId
            : _inferProviderId(lastSelectedModel);
        if (pId != null &&
            pId.isNotEmpty &&
            !recentModels.any(
              (r) => r.providerId == pId && r.model == lastSelectedModel,
            )) {
          recentModels.insert(0, (providerId: pId, model: lastSelectedModel));
        }
      }
      if (lastRepoFull == null || lastRepoFull!.isEmpty) {
        final repo = s?.repo;
        if (repo != null && repo.isNotEmpty) lastRepoFull = repo;
      }
      // Spec §8: backfill the branch from the restored active session when
      // nothing was persisted yet (upgrade path for existing installs).
      if (storedBranch == null || storedBranch.isEmpty) {
        final branch = s?.branch;
        if (branch != null && branch.isNotEmpty) lastBranch = branch;
      }
      if (lastWorkspaceFolder == null || lastWorkspaceFolder!.isEmpty) {
        final folder = s?.workspaceFolder;
        if (folder != null && folder.isNotEmpty) {
          lastWorkspaceFolder = folder;
        }
      }
    } catch (e) {
      Diag.swallow('state', e);
    }
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
      if (lastRepoFull != null && lastRepoFull!.isNotEmpty) {
        await prefs.setString(_kLastRepo, lastRepoFull!);
      } else {
        await prefs.remove(_kLastRepo);
      }
      if (lastBranch.isNotEmpty) {
        await prefs.setString(_kLastBranch, lastBranch);
      }
      if (lastWorkspaceFolder != null && lastWorkspaceFolder!.isNotEmpty) {
        await prefs.setString(_kLastWorkspace, lastWorkspaceFolder!);
      } else {
        await prefs.remove(_kLastWorkspace);
      }
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  Future<void> _loadRecentModels(SharedPreferences prefs) async {
    try {
      recentModels.clear();
      String? raw;
      try {
        final file = await _recentModelsJsonFile();
        if (file != null && await file.exists()) {
          final content = await file.readAsString();
          if (content.trim().isNotEmpty) {
            raw = content;
          }
        }
      } catch (e) {
        Diag.swallow('state', e);
      }
      raw ??= prefs.getString(_kRecentModels);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final e in decoded) {
          if (e is Map && e['p'] is String && e['m'] is String) {
            final p = e['p'] as String;
            final m = e['m'] as String;
            if (m.isNotEmpty &&
                !recentModels.any((r) => r.providerId == p && r.model == m)) {
              recentModels.add((providerId: p, model: m));
            }
          }
          if (recentModels.length >= 50) break;
        }
      } else if (decoded is Map) {
        if (decoded['current'] is Map) {
          final cur = decoded['current'] as Map;
          final m = cur['model'] as String?;
          final p = cur['providerId'] as String?;
          if (m != null && m.isNotEmpty && lastSelectedModel.isEmpty) {
            lastSelectedModel = m;
            lastSelectedProviderId = p;
          }
        }
        final list = decoded['recent'];
        if (list is List) {
          for (final e in list) {
            if (e is Map) {
              final p = (e['providerId'] ?? e['p']) as String?;
              final m = (e['model'] ?? e['m']) as String?;
              if (p != null &&
                  m != null &&
                  m.isNotEmpty &&
                  !recentModels.any((r) => r.providerId == p && r.model == m)) {
                recentModels.add((providerId: p, model: m));
              }
            }
            if (recentModels.length >= 50) break;
          }
        }
      }
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  Future<void> persistRecentModels() => _persistRecentModels();

  Future<void> _persistRecentModels() async {
    final payload = {
      'current': {
        'providerId': lastSelectedProviderId ?? '',
        'model': lastSelectedModel,
      },
      'recent': [
        for (final r in recentModels)
          {
            'providerId': r.providerId,
            'model': r.model,
            'selectedAt': DateTime.now().toIso8601String(),
          },
      ],
    };
    final jsonStr = jsonEncode(payload);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kRecentModels, jsonStr);
    } catch (e) {
      Diag.swallow('state', e);
    }
    try {
      final file = await _recentModelsJsonFile();
      if (file != null) {
        if (!file.parent.existsSync()) {
          file.parent.createSync(recursive: true);
        }
        await file.writeAsString(jsonStr);
      }
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  /// Record a `(providerId, model)` selection as most-recent (newest first,
  /// de-duplicated, capped at 50 to track all past selections).
  void _rememberRecentModel(String providerId, String model) {
    if (model.isEmpty || model == 'Select a provider') return;
    recentModels.removeWhere(
      (r) => r.providerId == providerId && r.model == model,
    );
    recentModels.insert(0, (providerId: providerId, model: model));
    if (recentModels.length > 50) {
      recentModels.removeRange(50, recentModels.length);
    }
    unawaited(_persistRecentModels());
  }

  /// A persisted workspace folder is only reused while it still exists on
  /// disk; a vanished path (deleted dir / unmounted drive) falls back to the
  /// per-session sandbox by returning null.
  String? _resolvedLastWorkspaceFolder() {
    final folder = lastWorkspaceFolder;
    if (folder == null || folder.trim().isEmpty) return null;
    try {
      return Directory(folder).existsSync() ? folder : null;
    } catch (_) {
      return null;
    }
  }

  static const _kSessions = 'ovid_sessions';
  static const _kActive = 'ovid_active_session';
  static const _kSessionBootstrap = 'ovid_session_bootstrap_v1';
  static const _kProviders = 'ovid_provider_configs_v1';
  static const _kLastModel = 'ovid_last_model';
  static const _kLastProvider = 'ovid_last_provider';
  static const _kRecentModels = 'ovid_recent_models';
  static const _kLastRepo = 'ovid_last_repo';
  static const _kLastBranch = 'ovid_last_branch';
  static const _kLastWorkspace = 'ovid_last_workspace';
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
          existing.applyPersistedJson(entry);
          continue;
        }
        if (entry['custom'] != true) continue;
        final baseUrl = entry['baseUrl'] as String? ?? '';
        final storedFormat = entry['apiFormat'] as String?;
        final format = storedFormat == null
            ? ProviderConfig._legacyApiFormat(baseUrl)
            : ApiFormat.parse(storedFormat);
        providers.add(
          ProviderConfig(
            id: id,
            name: entry['name'] as String? ?? 'Custom provider',
            description:
                entry['description'] as String? ??
                (format == ApiFormat.anthropic
                    ? 'Custom Anthropic Messages provider'
                    : 'Custom OpenAI-compatible provider'),
            baseUrl: baseUrl,
            custom: true,
            isFree: entry['isFree'] as bool? ?? false,
            models: models,
            requiresApiKey: entry['requiresApiKey'] as bool? ?? true,
            apiFormat: format,
          ),
        );
        providers.last.applyPersistedJson(entry);
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
      } catch (e) {
        Diag.swallow('state', e);
      }
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

  /// Stored history size (UTF-16 code units) from which hydration decodes in
  /// a background isolate. Tests lower it to exercise that path.
  @visibleForTesting
  static int hydrationIsolateThreshold = 512 * 1024;

  /// Finish only deferred history; never reload over live edits for a query.
  Future<void> loadSessionsForSearch() => _hydrateDeferredSessions();

  Future<void> loadSessions() async {
    await _settingsOperation;
    final token = _sessionAccountToken;
    if (_deferredSessionJson != null || _deferredSessionsPending) {
      await _hydrateDeferredSessions();
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!identical(token, _sessionAccountToken)) return;
      final raw = await SessionHistoryRepository.I.readRows(
        prefs,
        _accountKey(_kSessions),
      );
      if (!identical(token, _sessionAccountToken)) return;
      _sessionNamespaceLoaded = true;
      if (raw != null && raw.isNotEmpty) {
        final loaded = raw.map(_decodeSessionSync).toList();
        sessions
          ..clear()
          ..addAll(loaded);
      }
      activeSessionId = prefs.getString(_accountKey(_kActive));
      // Never restore INTO a subagent session — the app opens on a user chat.
      final active = sessionById(activeSessionId);
      if (active == null || active.isSubagent) {
        activeSessionId = rootSessions.isEmpty ? null : rootSessions.first.id;
      }
      if (raw != null && raw.isNotEmpty) {
        final resolved = sessionById(activeSessionId);
        if (resolved != null && !resolved.isSubagent) {
          // A loaded persisted root is the boot-active root for restore.
          _pendingActiveRootId = resolved.id;
        }
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
    // Parse rather than prefix-match: the v2 schema writes `schemaVersion`
    // before `id`, so a positional prefix is no longer stable.
    for (final encoded in raw) {
      try {
        if ((jsonDecode(encoded) as Map<String, dynamic>)['id'] == activeId) {
          return encoded;
        }
      } catch (_) {
        // Opaque/deferred rows are skipped; they never match an id.
      }
    }
    return null;
  }

  Future<void> _loadSessionsForFirstFrame() async {
    await _settingsOperation;
    final token = _sessionAccountToken;
    List<String>? raw;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!identical(token, _sessionAccountToken)) return;
      final requestedActiveId = prefs.getString(_accountKey(_kActive));
      raw = await SessionHistoryRepository.I.readRows(
        prefs,
        _accountKey(_kSessions),
      );
      if (!identical(token, _sessionAccountToken)) return;
      _sessionNamespaceLoaded = true;
      final requestedActiveRaw = _activeRawSession(
        raw ?? const [],
        requestedActiveId,
      );
      final cached = prefs.getString(_accountKey(_kSessionBootstrap));
      if (cached != null &&
          requestedActiveId != null &&
          requestedActiveRaw != null) {
        try {
          final envelope = _sessionBootstrapDecoder(cached);
          final fingerprint = await Isolate.run(
            () => _sessionSourceFingerprint(requestedActiveRaw),
          );
          if (!identical(token, _sessionAccountToken)) return;
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
        for (final encoded in raw) {
          try {
            final decodedId =
                (jsonDecode(encoded) as Map<String, dynamic>)['id'];
            if (decodedId != requestedActiveId) continue;
            final candidate = await _decodeSessionForFirstFrame(encoded);
            if (!identical(token, _sessionAccountToken)) return;
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
            if (!identical(token, _sessionAccountToken)) return;
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
        await prefs.setString(_accountKey(_kActive), active.id);
      }
      await _writeSessionBootstrapFromSession(
        prefs,
        active,
        _activeRawSession(raw, active.id),
      );
    } catch (_) {
      if (!identical(token, _sessionAccountToken)) return;
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
    _deferredActiveSession = active;
    _deferredActiveTailLength = active.messages.length;
    // A persisted root replaces the provisional constructor session: capture
    // its id so restore dispatches THAT session (not a later active switch)
    // with reason `restored`, never `implicit`.
    _pendingActiveRootId = active.id;
    notifyListeners();
  }

  Future<void> _loadDeferredSessionSnapshot() async {
    if (!_deferredSessionsPending) return;
    final generation = _deferredSessionGeneration;
    final prefs = await SharedPreferences.getInstance();
    if (generation != _deferredSessionGeneration || !_deferredSessionsPending) {
      return;
    }
    final rows = await SessionHistoryRepository.I.readRows(
      prefs,
      _accountKey(_kSessions),
    );
    if (generation != _deferredSessionGeneration || !_deferredSessionsPending) {
      return;
    }
    _deferredSessionJson = List<String>.of(rows ?? const <String>[]);
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
        } catch (e) {
          Diag.swallow('state', e);
        }
      }
    }
  }

  void _scheduleSessionDeletion(String id, String? sandboxId) {
    if (!_notifiedDeletedSessionIds.add(id)) return;
    final token = _sessionCleanupToken;
    bool current() => identical(token, _sessionCleanupToken);
    // The local ledger is gone (P8 Task 20); the remaining stores are enqueued
    // synchronously so late lifecycle callbacks cannot race a session switch.
    _pendingWorkspaceDeletions.add(
      _SessionCleanup(() async {
        if (current()) await SessionSearch.I.deleteSession(id);
      }),
    );
    _pendingWorkspaceDeletions.add(
      _SessionCleanup(() async {
        if (current()) await _deleteSessionMemory(id);
      }),
    );
    if (sandboxId != null) {
      _pendingWorkspaceDeletions.add(
        _SessionCleanup(() async {
          if (current()) await _workspaceDeleter(sandboxId);
        }),
      );
    }
    onSessionDeleted?.call(id);
    // Server half of the delete: if the chat has a cloud counterpart,
    // DELETE it there too (fire-and-forget — an offline delete stays local
    // and CloudSessionStore's tombstone keeps the next refresh from
    // resurrecting the row).
    _deleteServerSession(id);
  }

  /// DELETEs [localOrServerId]'s cloud copy when one exists. Errors never
  /// surface: a delete must not fail because the server is unreachable.
  void _deleteServerSession(String localOrServerId) {
    unawaited(() async {
      try {
        await CloudSessionStore.I.deleteServerSession(localOrServerId);
      } catch (e) {
        Diag.swallow('state.deleteServerSession', e);
      }
    }());
  }

  Future<void> _awaitWorkspaceDeletions() async {
    final observed = <_SessionCleanup>{};
    while (true) {
      final pending = _pendingWorkspaceDeletions
          .where((task) => !observed.contains(task))
          .toList();
      if (pending.isEmpty) break;
      observed.addAll(pending);
      await Future.wait(pending.map((task) => task.pending));
      _pendingWorkspaceDeletions.removeWhere(
        (task) =>
            observed.contains(task) && !task.running && task.error == null,
      );
    }
    if (_pendingWorkspaceDeletions.any(
      (task) => task.running || task.error != null,
    )) {
      throw StateError('Session cleanup incomplete');
    }
  }

  /// Await every remaining deletion task. Retry only failed operations;
  /// completed lifecycle callbacks are never repeated. Owners captured by each
  /// task reject a retry after an account transition.
  Future<void> awaitSessionDeletions({bool retryFailed = false}) async {
    final token = _sessionAccountToken;
    await _loadDeferredSessionSnapshot();
    if (!identical(token, _sessionAccountToken)) return;
    if (retryFailed) {
      for (final task in _pendingWorkspaceDeletions.toList()) {
        await task.pending;
        if (!identical(token, _sessionAccountToken)) return;
        if (task.error != null) task.retry();
      }
    }
    await _awaitWorkspaceDeletions();
  }

  Future<void> _hydrateDeferredSessions() async {
    final token = _sessionAccountToken;
    await _loadDeferredSessionSnapshot();
    if (!identical(token, _sessionAccountToken)) return;
    final raw = _deferredSessionJson;
    if (raw == null) return;
    final generation = _deferredSessionGeneration;
    // Large histories decode off the UI isolate in one batch (F-045); small
    // ones keep the incremental, yielding decode below.
    List<ChatSession?>? predecoded;
    if (raw.fold<int>(0, (n, row) => n + row.length) >=
        hydrationIsolateThreshold) {
      final rows = List<String>.of(raw);
      predecoded = await _decodePersistedSessionsInIsolate(rows);
      if (!identical(token, _sessionAccountToken) ||
          generation != _deferredSessionGeneration) {
        return;
      }
    }
    final loaded = <ChatSession>[];
    final unparsed = <String>[];
    for (var index = 0; index < raw.length; index++) {
      if (generation != _deferredSessionGeneration) return;
      final encoded = raw[index];
      try {
        final ChatSession full;
        if (predecoded != null) {
          full =
              predecoded[index] ??
              (throw const FormatException('Unreadable session row'));
          if (_deferredDeletedSessionIds.contains(full.id)) continue;
        } else {
          final fullJson = jsonDecode(encoded) as Map<String, dynamic>;
          final id = fullJson['id'] as String?;
          if (id == null || id.isEmpty) {
            throw const FormatException('Missing session identity');
          }
          if (_deferredDeletedSessionIds.contains(id)) continue;
          full = ChatSession.fromJson(fullJson);
        }
        final id = full.id;
        final live = sessionById(id);
        if (live != null && id != _deferredActiveSessionId) {
          _deferredProjectionPrefix(full, live);
        }
        loaded.add(full);
      } catch (_) {
        unparsed.add(encoded);
        _startupStageRecorder?.call('local.hydrate.corrupt');
      }
      if (predecoded == null && index % 20 == 19) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (generation != _deferredSessionGeneration) return;
    // Resolve membership only after the last yield. Live objects (including
    // nonactive sessions and sessions created during decoding) own all edits.
    // Known projections receive their saved prefix in place; replacing an
    // observed object creates a new owner that must not inherit that prefix.
    final current = {for (final session in sessions) session.id: session};
    current.removeWhere((id, _) => _deferredDeletedSessionIds.contains(id));
    final reconciled = <ChatSession>[];
    for (final full in loaded) {
      if (_deferredDeletedSessionIds.contains(full.id)) continue;
      final live = current.remove(full.id);
      if (live == null) {
        reconciled.add(full);
        continue;
      }
      if (identical(live, _deferredActiveSession)) {
        final prefixLength = (full.messages.length - _deferredActiveTailLength)
            .clamp(0, full.messages.length);
        live.messages.insertAll(0, full.messages.take(prefixLength));
      } else if (live.id != _deferredActiveSessionId) {
        final prefixLength = _deferredProjectionPrefix(full, live) ?? 0;
        live.messages.insertAll(0, full.messages.take(prefixLength));
      }
      reconciled.add(live);
    }
    reconciled.addAll(current.values);
    sessions
      ..clear()
      ..addAll(reconciled);
    _unparsedSessionJson
      ..clear()
      ..addAll(unparsed);
    // A completed merge consumes this snapshot. Other callers decoding the
    // same generation must not publish after its deletion fences are cleared.
    _deferredSessionGeneration++;
    _deferredSessionJson = null;
    _deferredActiveSessionId = null;
    _deferredActiveSession = null;
    _deferredProjections.clear();
    _deferredActiveTailLength = 0;
    _deferredDeletedSessionIds.clear();
    _invalidateSessionPersistenceCache();
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
    // Live metadata is authoritative, including absent optional keys (a
    // cleared grant/branch must not be restored by a map overlay).
    final merged = partial.toJson()
      ..['messages'] = [
        ...oldMessages.take(prefixLength),
        ...partial.messages.map((message) => message.toJson()),
      ];
    return ChatSession.fromJson(merged);
  }

  int? _deferredProjectionPrefix(ChatSession full, ChatSession live) {
    final known = _deferredProjections[live.id];
    if (known != null) {
      // Replacement of an observed object is an explicit new transcript owner.
      return identical(known.owner, live) ? known.prefixLength : 0;
    }
    // Zero is a recognized complete transcript; null is unknown provenance.
    int? prefixLength = full.messages.isEmpty ? 0 : null;
    if (live.messages.isNotEmpty) {
      // Capture an exact saved suffix before yielding; later edits/appends on
      // this very object must not change its provenance. This runs once per
      // deferred owner, never in the streamed-token enqueue/fingerprint path.
      final first = jsonEncode(live.messages.first.toJson());
      for (var start = 0; start < full.messages.length; start++) {
        if (jsonEncode(full.messages[start].toJson()) != first) continue;
        final count = full.messages.length - start;
        if (live.messages.length < count) continue;
        var matches = true;
        for (var i = 1; i < count; i++) {
          if (jsonEncode(full.messages[start + i].toJson()) !=
              jsonEncode(live.messages[i].toJson())) {
            matches = false;
            break;
          }
        }
        if (matches) {
          prefixLength = start;
          break;
        }
      }
    }
    // Same persisted creation identity but no provable overlap: retain all
    // saved history rather than silently truncate an already-edited projection.
    if (prefixLength == null &&
        live.createdAt == full.createdAt &&
        live.messages.length < full.messages.length) {
      prefixLength = full.messages.length;
    }
    _deferredProjections[live.id] = (owner: live, prefixLength: prefixLength);
    return prefixLength;
  }

  /// Mark [id]'s in-memory content as changed. A null [id] forces a full
  /// re-encode (list membership changed).
  void _markSessionDirty(String? id) {
    if (id == null) {
      _persistFullRewrite = true;
    } else {
      _dirtySessionIds.add(id);
    }
  }

  /// Drop the derivative encode caches so the next write rebuilds from live
  /// state. Used when the session list is replaced wholesale.
  void _invalidateSessionPersistenceCache() {
    _persistedSessionRaw.clear();
    _persistedSessionSignature.clear();
    _persistFullRewrite = true;
  }

  /// A cheap content fingerprint for [session]. It folds a per-message
  /// structural hash (identity + kind + content + tool/feedback fields) with
  /// every mutable metadata field, so in-place edits and agent tool-card
  /// updates are detected without re-encoding the message list to JSON.
  Object? _sessionContentSignature(ChatSession session) {
    var messageHash = 0;
    for (final message in session.messages) {
      messageHash = Object.hash(
        messageHash,
        identityHashCode(message),
        message.kind,
        message.thinking,
        message.content,
        message.elapsedMs,
        message.toolState,
        message.toolDetail,
        message.toolSummary,
        message.toolTitle,
        message.toolSessionId,
        message.feedback,
        message.feedbackNote,
        Object.hashAll(message.attachments),
      );
    }
    return Object.hashAll([
      // Final fields (including createdAt and immutable message artifacts)
      // can change only by object replacement, which identity captures.
      identityHashCode(session),
      session.messages.length,
      messageHash,
      session.title,
      session.model,
      session.providerId,
      session.mode,
      session.presetId,
      session.workspaceFolder,
      session.workspaceFolderPinned,
      session.repo,
      session.branch,
      session.parentId,
      session.agentLabel,
      session.agentState,
      session.agentResult,
      session.agentId,
      session.agentContinuable,
      session.agentPersona,
      session.agentOutputHint,
      Object.hashAll(session.referencedSessionIds),
      Object.hashAll(session.pendingAgentNotices),
      session.planMode,
      session.planModePending,
      session.sandboxId,
      session.systemPromptSnapshot,
      session.titleGenerated,
      session.updatedAt,
      _sessionNestedSignature(session.analytics.toJson()),
      _sessionNestedSignature(session.goal),
      _sessionNestedSignature(session.todos),
    ]);
  }

  // Preserve collection boundaries and scalar types; toString() can give the
  // same text for distinct persisted structures. Run only at write boundaries,
  // never while enqueueing streamed tokens. No transcript JSON is allocated.
  Object? _sessionNestedSignature(Object? value) {
    if (value is Map) {
      return Object.hash(
        'map',
        Object.hashAll(
          value.entries.map(
            (entry) =>
                Object.hash(entry.key, _sessionNestedSignature(entry.value)),
          ),
        ),
      );
    }
    if (value is Iterable) {
      return Object.hash(
        'list',
        Object.hashAll(value.map(_sessionNestedSignature)),
      );
    }
    return Object.hash(value.runtimeType, value);
  }

  /// Coalesce rapid writes with a trailing debounce. The first call in a burst
  /// arms a timer; later calls (including across `await` boundaries) push it
  /// out, so one turn lands as one write. The returned future completes once
  /// the coalesced write settles.
  Future<void> persistSessions() {
    _persistScheduled = true;
    final existing = _persistScheduledFuture;
    if (existing != null) {
      _armPersistDebounce();
      return existing;
    }
    final completer = Completer<void>();
    _persistCompleter = completer;
    _persistScheduledFuture = completer.future;
    _armPersistDebounce();
    return completer.future;
  }

  /// (Re)arm the trailing debounce. A zero window falls back to a microtask
  /// (the test default) so no wall-clock Timer is left pending in widget tests.
  void _armPersistDebounce() {
    if (_settingsBusy) return;
    if (suspendCoalescedPersistenceForTest) return;
    _persistDebounceTimer?.cancel();
    if (_sessionPersistDebounce <= Duration.zero) {
      scheduleMicrotask(_flushScheduledPersistence);
      return;
    }
    _persistDebounceTimer = Timer(_sessionPersistDebounce, () {
      _persistDebounceTimer = null;
      unawaited(_flushScheduledPersistence());
    });
    // A continuously streaming turn must still become durable. Later tokens
    // may move the trailing timer, but cannot move this burst's deadline.
    _persistMaxWaitTimer ??= Timer(const Duration(seconds: 1), () {
      unawaited(_flushScheduledPersistence());
    });
  }

  void _cancelPersistDebounce() {
    _persistDebounceTimer?.cancel();
    _persistDebounceTimer = null;
    _persistMaxWaitTimer?.cancel();
    _persistMaxWaitTimer = null;
  }

  Future<void> _flushScheduledPersistence() async {
    if (_settingsBusy) return;
    _cancelPersistDebounce();
    if (!_persistScheduled) return;
    _persistScheduled = false;
    final wrote = await _ensureSessionWrite();
    _completeScheduledPersistence();
    if (wrote && _hasUnpersistedSessionChanges()) {
      unawaited(persistSessions());
    }
  }

  /// Run a pending coalesced write immediately and await it. Called on session
  /// switch and lifecycle pause so a pending change is never dropped.
  Future<void> flushSessionPersistence() async {
    if (_settingsBusy) return;
    _cancelPersistDebounce();
    _persistScheduled = false;
    final wrote = await _ensureSessionWrite();
    _completeScheduledPersistence();
    if (wrote && _hasUnpersistedSessionChanges()) {
      await flushSessionPersistence();
    }
  }

  /// Test seam: force any pending write and await it.
  @visibleForTesting
  Future<void> flushSessionPersistenceForTest() => flushSessionPersistence();

  /// Test seam: perform exactly one write (no coalescing loop) and report
  /// whether unpersisted changes remain. Used to prove the dirty tracker
  /// settles instead of scheduling writes forever.
  @visibleForTesting
  Future<bool> writeSessionsOnceForTest() async {
    await _writeSessionsNow();
    return _hasUnpersistedSessionChanges();
  }

  /// Test seam: await in-flight / automatically scheduled writes without
  /// forcing one. Proves a switch/pause flush actually started.
  @visibleForTesting
  Future<void> awaitPendingSessionWritesForTest() async {
    _cancelPersistDebounce();
    if (_persistScheduled) {
      _persistScheduled = false;
      await _ensureSessionWrite();
    }
    while (_persistWriteInFlight != null) {
      await _persistWriteInFlight;
    }
    _completeScheduledPersistence();
  }

  Future<bool> _ensureSessionWrite() {
    final inFlight = _persistWriteInFlight;
    if (inFlight != null) return inFlight;
    final future = _writeSessionsNow();
    _persistWriteInFlight = future.whenComplete(() {
      _persistWriteInFlight = null;
    });
    return _persistWriteInFlight!;
  }

  void _completeScheduledPersistence() {
    final completer = _persistCompleter;
    _persistCompleter = null;
    _persistScheduledFuture = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  bool _hasUnpersistedSessionChanges() {
    if (_persistFullRewrite || _dirtySessionIds.isNotEmpty) return true;
    if (_persistedDeferredGeneration != _deferredSessionGeneration ||
        !setEquals(_persistedDeferredDeletedIds, _deferredDeletedSessionIds)) {
      return true;
    }
    if (_persistedActiveSessionId != activeSessionId ||
        !listEquals(_persistedSessionIds, sessions.map((s) => s.id).toList())) {
      return true;
    }
    for (final session in sessions) {
      final raw = _persistedSessionRaw[session.id];
      if (raw == null ||
          _persistedSessionSignature[session.id] !=
              _sessionContentSignature(session)) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _writeSessionsNow() async {
    if (!sessionAccountReady) return false;
    final token = _sessionAccountToken;
    final sessionsKey = _accountKey(_kSessions);
    final activeKey = _accountKey(_kActive);
    final bootstrapKey = _accountKey(_kSessionBootstrap);
    try {
      if (failNextSessionWriteForTest) {
        failNextSessionWriteForTest = false;
        throw StateError('forced session-write failure (test)');
      }
      final prefs = await SharedPreferences.getInstance();
      await _loadDeferredSessionSnapshot();
      if (!identical(token, _sessionAccountToken)) return false;
      _sessionNamespaceLoaded = true;
      final dirtySnapshot = Set<String>.of(_dirtySessionIds);
      final deferredGeneration = _deferredSessionGeneration;
      final deletedSnapshot = Set<String>.of(_deferredDeletedSessionIds);
      final encoded = _sessionJsonForPersistence();
      final active = activeSession;
      final activeIdWritten = activeSessionId;
      final activeRaw = _activeRawSession(encoded, active?.id);
      // The cache is a derivative of exact session-list truth. Either interrupted
      // write order produces a fingerprint mismatch and a safe fallback.
      try {
        await _writeSessionBootstrapFromSession(
          prefs,
          active,
          activeRaw,
          key: bootstrapKey,
        );
      } catch (e) {
        Diag.swallow('state', e);
      }
      if (!await SessionHistoryRepository.I.writeRows(
        prefs,
        sessionsKey,
        encoded,
      )) {
        throw StateError('Session storage rejected write');
      }
      final activeSaved = activeIdWritten != null
          ? await prefs.setString(activeKey, activeIdWritten)
          : await prefs.remove(activeKey);
      if (!activeSaved) {
        throw StateError('Active session storage rejected write');
      }
      if (!identical(token, _sessionAccountToken)) return false;
      _persistedActiveSessionId = activeIdWritten;
      // A delete can affect only opaque/deferred rows, leaving live membership
      // unchanged. Acknowledge precisely the fences included in this write.
      _persistedDeferredGeneration = deferredGeneration;
      _persistedDeferredDeletedIds = deletedSnapshot;
      _dirtySessionIds.removeAll(dirtySnapshot);
      await awaitSessionDeletions();
      if (lastSessionPersistFailed) {
        lastSessionPersistFailed = false;
        notifyListeners();
      }
      return true;
    } catch (_) {
      if (!identical(token, _sessionAccountToken)) return false;
      // A failed write must not leave the derivative caches claiming the
      // changes are durable; force a full re-encode next time. Returning false
      // stops the coalescing loop from retrying forever.
      _invalidateSessionPersistenceCache();
      // B4: record the failure so callers/UI can tell chat history is not
      // durable (previously the awaited future always completed as success).
      lastSessionPersistFailed = true;
      notifyListeners();
      return false;
    }
  }

  Future<void> _writeSessionBootstrapFromSession(
    SharedPreferences prefs,
    ChatSession? active,
    String? activeRaw, {
    String? key,
  }) async {
    key ??= _accountKey(_kSessionBootstrap);
    if (active == null || active.isSubagent || activeRaw == null) {
      await prefs.remove(key);
      return;
    }
    final json = active.toJson();
    final messages = json['messages'] as List;
    final tailStart = messages.length > _firstFrameMessageTailSize
        ? messages.length - _firstFrameMessageTailSize
        : 0;
    json['messages'] = messages.sublist(tailStart);
    await prefs.setString(
      key,
      jsonEncode({
        'version': 1,
        'sourceFingerprint': _sessionSourceFingerprint(activeRaw),
        'session': json,
      }),
    );
  }

  List<String> _sessionJsonForPersistence() {
    final force = _persistFullRewrite;
    final dirtySnapshot = Set<String>.of(_dirtySessionIds);
    final rawById = <String, String>{};
    final signatureById = <String, Object?>{};
    final encoded = <String>[];

    bool needsEncode(ChatSession session) {
      if (force || dirtySnapshot.contains(session.id)) return true;
      return _persistedSessionRaw[session.id] == null ||
          _persistedSessionSignature[session.id] !=
              _sessionContentSignature(session);
    }

    String encode(ChatSession session) {
      final raw = jsonEncode(session.toJson());
      rawById[session.id] = raw;
      signatureById[session.id] = _sessionContentSignature(session);
      sessionEncodeCountsForTest[session.id] =
          (sessionEncodeCountsForTest[session.id] ?? 0) + 1;
      return raw;
    }

    String encodeMerged(ChatSession partial, Map<String, dynamic> fullJson) {
      final raw = jsonEncode(
        _mergeDeferredActiveSession(fullJson, partial).toJson(),
      );
      rawById[partial.id] = raw;
      signatureById[partial.id] = _sessionContentSignature(partial);
      sessionEncodeCountsForTest[partial.id] =
          (sessionEncodeCountsForTest[partial.id] ?? 0) + 1;
      return raw;
    }

    String encodeDeferredMetadata(
      ChatSession session,
      Map<String, dynamic> fullJson,
    ) {
      // Recognize saved tails before persisting metadata. Keep the owner and
      // prefix for hydration so a later flush cannot truncate the saved history.
      final known = _deferredProjections[session.id];
      if (known != null && !identical(known.owner, session)) {
        return encode(session);
      }
      final full = ChatSession.fromJson(fullJson);
      final prefix = _deferredProjectionPrefix(full, session);
      final raw = jsonEncode(
        session.toJson()
          ..['messages'] = prefix != null
              ? [
                  ...((fullJson['messages'] as List?) ?? const []).take(prefix),
                  ...session.messages.map((m) => m.toJson()),
                ]
              : fullJson['messages'] ?? const [],
      );
      rawById[session.id] = raw;
      signatureById[session.id] = _sessionContentSignature(session);
      sessionEncodeCountsForTest[session.id] =
          (sessionEncodeCountsForTest[session.id] ?? 0) + 1;
      return raw;
    }

    String reuse(ChatSession session) {
      final raw = _persistedSessionRaw[session.id]!;
      rawById[session.id] = raw;
      signatureById[session.id] = _persistedSessionSignature[session.id];
      return raw;
    }

    final raw = _deferredSessionJson;
    if (raw == null) {
      for (final session in sessions) {
        encoded.add(needsEncode(session) ? encode(session) : reuse(session));
      }
      encoded.addAll(_unparsedSessionJson);
    } else {
      final current = {for (final session in sessions) session.id: session};
      for (final original in raw) {
        try {
          final fullJson = jsonDecode(original) as Map<String, dynamic>;
          final id = fullJson['id'] as String?;
          if (id != null && _deferredDeletedSessionIds.contains(id)) continue;
          final partial = id == null ? null : current.remove(id);
          if (partial != null && id == _deferredActiveSessionId) {
            encoded.add(
              needsEncode(partial)
                  ? identical(partial, _deferredActiveSession)
                        ? encodeMerged(partial, fullJson)
                        : encode(partial)
                  : reuse(partial),
            );
          } else if (partial != null) {
            encoded.add(
              needsEncode(partial)
                  ? encodeDeferredMetadata(partial, fullJson)
                  : reuse(partial),
            );
          } else {
            encoded.add(original);
          }
        } catch (_) {
          encoded.add(original);
        }
      }
      encoded.addAll(
        current.values.map(
          (session) => needsEncode(session) ? encode(session) : reuse(session),
        ),
      );
    }

    _persistedSessionRaw
      ..clear()
      ..addAll(rawById);
    _persistedSessionSignature
      ..clear()
      ..addAll(signatureById);
    _persistFullRewrite = false;
    _persistedSessionIds = sessions.map((s) => s.id).toList();
    return encoded;
  }

  void _clearDeferredSessions() {
    _deferredSessionGeneration++;
    _deferredSessionJson = null;
    _deferredSessionsPending = false;
    _deferredActiveSessionId = null;
    _deferredActiveSession = null;
    _deferredProjections.clear();
    _deferredActiveTailLength = 0;
    _deferredDeletedSessionIds.clear();
    _unparsedSessionJson.clear();
    _invalidateSessionPersistenceCache();
  }

  /// Legacy best-effort local reset, retained for existing callers. This does
  /// not establish verified all-store completion and must not be bound to the
  /// SettingsActions reset capability. Its historical partial-failure semantics
  /// are separate from the transactional transcript restore contract.
  Future<void> deleteAllData() async {
    if (_settingsBusy) throw StateError('Settings operation in progress.');
    try {
      try {
        // Memory is server-owned; delete the pre-cloud Markdown directory
        // directly so the local cleanup guarantee survives the store removal.
        await _deleteMemoryRoot();
      } catch (e) {
        Diag.swallow('memory.deleteAll', e);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      try {
        await SessionHistoryRepository.I.deleteAll();
      } catch (e) {
        Diag.swallow('history.deleteAll', e);
      }
      await ComposerDraftStore.I.clearAll();
      StudioRemoteClient.I.clearAll();
      await StudioDraftStore.I.deleteAll('');
      _clearDeferredSessions();
      for (final s in List.of(sessions)) {
        final sid = s.sandboxId;
        if (sid != null) unawaited(_deleteLocalWorkspace(sid));
      }
      sessions.clear();
      activeSessionId = null;
      providers.clear();
      _seed();
        memoryEnabled = true;
      showReasoning = true;
      githubSync = true;
      workflowEnabled = true;
      autoRunSafeCommands = true;
        shareSessionMemory = false;
      lastSelectedModel = '';
      lastSelectedProviderId = null;
      try {
        await GitHubService.I.signOut();
      } catch (e) {
        Diag.swallow('state', e);
      }
      try {
        await _secureStorage.deleteAll();
      } catch (e) {
        Diag.swallow('state', e);
      }
      _ensureActiveSession();
      notifyListeners();
      await persistSessions();
      await persistProviderState();
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  int navIndex = 0; // 0 Chat, 1 Studio, 2 Browser, 3 Plugins, 4 Settings
  /// Share memory across sessions (persisted, default OFF).
  ///
  /// OFF → the AI only sees the current session's messages/workspace.
  /// ON  → the AI (via memory_search) can search across ALL sessions' chat
  /// history ("poori app history", user-opted).
  static const _kShareMemory = 'ovid_share_session_memory';
  static const _kCustomPresets = 'ovid_custom_presets';
  bool shareSessionMemory = false;

  /// Cross-chat sharing only applies while Memory itself is on: turning
  /// Memory off is the user saying "no saved context", so the share switch
  /// is greyed out ("Requires Memory") and every cross-chat path follows
  /// this getter rather than the raw preference.
  bool get effectiveShareSessionMemory => memoryEnabled && shareSessionMemory;

  // ── Light/dark theme (the theme controller light/dark preference parity) ──
  static const _kTheme = 'ovid_light_theme';
  static const _kThemeMode = 'ovid_theme_mode';
  bool lightTheme = false;

  /// Theme mode: 'system', 'light', or 'dark'. Fresh installs follow the OS.
  String themeMode = 'system';

  /// Native device-integrity probe results (root / hooking framework /
  /// debugger). Refreshed at readiness; drives the Settings integrity row
  /// and a compromise warning. Empty until the first probe settles.
  Map<String, dynamic> deviceSecurity = const {};
  bool securityChecked = false;

  /// True when the native probe reports a rooted device, an active hooking
  /// framework, or an attached debugger — the conditions under which stored
  /// secrets can be extracted by another process.
  bool get deviceEnvironmentCompromised =>
      deviceSecurity['isRooted'] == true ||
      deviceSecurity['isHookingFrameworkPresent'] == true ||
      deviceSecurity['isDebuggerAttached'] == true;

  Future<void> refreshDeviceSecurity() async {
    try {
      deviceSecurity = await SecurityService.I.refresh();
    } catch (_) {
      deviceSecurity = const {};
    }
    securityChecked = true;
    notifyListeners();
  }

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

  /// Auto-run safe commands: read-only shell commands skip confirmation.
  static const _kAutoRunSafe = 'ovid_auto_run_safe';
  bool autoRunSafeCommands = true;

  /// Send behavior while the agent is running: `queue` (default) appends the
  /// text to the active run; `interrupt` stops the current run first, then
  /// sends. Mirrors the reference's send-while-busy selector.
  static const _kSendWhileBusy = 'ovid_send_while_busy';
  String sendWhileBusy = 'queue';
  bool get sendWhileBusyInterrupt => sendWhileBusy == 'interrupt';
  Future<void> setSendWhileBusy(String v) async {
    if (v != 'queue' && v != 'interrupt') return;
    sendWhileBusy = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kSendWhileBusy, v);
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  /// Conversation display for completed turns: `compact` (default) folds the
  /// process run into a disclosure strip; `full` shows every tool/reasoning
  /// row. Mirrors the reference's conversation-display selector.
  static const _kConversationDisplay = 'ovid_conversation_display';
  String conversationDisplay = 'compact';
  bool get conversationFull => conversationDisplay == 'full';
  Future<void> setConversationDisplay(String v) async {
    if (v != 'compact' && v != 'full') return;
    conversationDisplay = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kConversationDisplay, v);
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  static const _kNotificationsPref = 'ovid_notifications_enabled';
  bool _notificationsEnabled = true;

  /// Master switch for result notifications. OFF means the app never posts
  /// them (FCM delivery is still received; it is simply not surfaced).
  bool get notificationsEnabled => _notificationsEnabled;
  Future<void> setNotificationsEnabled(bool v) async {
    if (_notificationsEnabled == v) return;
    _notificationsEnabled = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kNotificationsPref, v);
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  /// Whether the user has accepted the Control-mode disclosure. Once true,
  /// switching to Control no longer re-shows the dialog.
  static const _kControlDisclosure = 'ovid_control_disclosure_accepted';
  bool _controlDisclosureAccepted = false;
  bool get controlDisclosureAccepted => _controlDisclosureAccepted;
  set controlDisclosureAccepted(bool v) {
    if (_controlDisclosureAccepted == v) return;
    _controlDisclosureAccepted = v;
    unawaited(_saveControlDisclosure(v));
    notifyListeners();
  }

  Future<void> _saveControlDisclosure(bool v) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kControlDisclosure, v);
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  /// Battery-exemption prompt shown once on first Control-mode enable, so
  /// we never nag. Loaded with the other control prefs at startup.
  static const _kControlBatteryPrompt = 'ovid_control_battery_prompt_shown';
  bool controlBatteryPromptShown = false;

  Future<void> markControlBatteryPromptShown() async {
    controlBatteryPromptShown = true;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kControlBatteryPrompt, true);
    } catch (e) {
      Diag.swallow('state', e);
    }
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
    } catch (e) {
      Diag.swallow('state', e);
    }
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
    } catch (e) {
      Diag.swallow('state', e);
    }
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
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  /// Toggle and persist. The app shell listens and rebuilds the whole
  /// tree so every Aether.* getter resolves to the new palette.
  Future<void> setLightTheme(bool v) async {
    lightTheme = v;
    Aether.dark = !v;
    // A manual light/dark toggle implies leaving system mode.
    themeMode = v ? 'light' : 'dark';
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kTheme, v);
      await prefs.setString(_kThemeMode, themeMode);
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  /// Set the theme mode: 'system', 'light', or 'dark'.
  Future<void> setThemeMode(String mode) async {
    themeMode = mode;
    if (mode == 'system') {
      // Resolve from platform brightness.
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      final isLight = brightness == Brightness.light;
      lightTheme = isLight;
      Aether.dark = !isLight;
    } else {
      final isLight = mode == 'light';
      lightTheme = isLight;
      Aether.dark = !isLight;
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kThemeMode, mode);
      await prefs.setBool(_kTheme, lightTheme);
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  Future<void> setShareSessionMemory(bool v) async {
    shareSessionMemory = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kShareMemory, v);
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  Future<void> setMemoryEnabled(bool v) async {
    memoryEnabled = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kMemoryEnabled, v);
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  Future<void> setShowReasoning(bool v) async {
    showReasoning = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kShowReasoning, v);
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  Future<void> setWorkflowEnabled(bool v) async {
    workflowEnabled = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kWorkflowEnabled, v);
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  Future<void> setGithubSync(bool v) async {
    githubSync = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kGithubSync, v);
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  Future<void> setAutoRunSafeCommands(bool v) async {
    autoRunSafeCommands = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoRunSafe, v);
    } catch (e) {
      Diag.swallow('state', e);
    }
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
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  Future<void> setMaxOutputTokens(int tokens) async {
    maxOutputTokens = tokens;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kMaxOutputTokens, tokens);
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  /// The response timeout is a first-byte / idle limit, so anything below
  /// this would fail every turn of a reasoning model that thinks quietly.
  static const minResponseTimeoutSec = 30;
  static const maxResponseTimeoutSec = 3600;

  /// Below this the Settings screen warns that slow models may time out.
  static const responseTimeoutWarnBelowSec = 60;

  Future<void> setResponseTimeout(int sec) async {
    sec = sec.clamp(minResponseTimeoutSec, maxResponseTimeoutSec);
    responseTimeoutSec = sec;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kResponseTimeout, sec);
    } catch (e) {
      Diag.swallow('state', e);
    }
  }

  final List<ProviderConfig> providers = [];
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

  final Directory? _memoryRootOverride;

  /// Per-account Markdown memory root.
  ///
  /// Memory is server-owned since P8 Task 18. The local directory survives
  /// only as a cleanup target for pre-cloud files, so reset and session
  /// deletion remove it directly (below) instead of opening a local store.
  Future<Directory> _memoryRootForAccount(String account) async {
    final baseRoot =
        _memoryRootOverride ??
        Directory(
          '${(await getApplicationDocumentsDirectory()).path}/personal-memory',
        );
    return account == 'guest'
        ? baseRoot
        : Directory(
            '${baseRoot.path}/account-${sha256.convert(utf8.encode(account)).toString()}',
          );
  }

  /// Reset path: remove the whole per-account memory directory. Bounded to
  /// the resolved root; a missing directory is already empty.
  Future<void> _deleteMemoryRoot() async {
    final root = await _memoryRootForAccount(_sessionAccountId);
    if (await root.exists()) await root.delete(recursive: true);
  }

  /// Session-deletion path: remove that session's memory scope only.
  Future<void> _deleteSessionMemory(String owner) async {
    final root = await _memoryRootForAccount(_sessionAccountId);
    final scope = Directory(
      '${root.path}/session-${sha256.convert(utf8.encode(owner))}',
    );
    if (await scope.exists()) await scope.delete(recursive: true);
  }

  // [activeSession] memo. [sessions] is mutated in place all over the app, so
  // the hit is only trusted after an O(1) check that the slot still holds the
  // same session with the active id; anything else falls back to a scan.
  ChatSession? _activeSessionMemo;
  int _activeSessionMemoIndex = -1;

  ChatSession? get activeSession {
    final id = activeSessionId;
    if (id == null) return null;
    final memo = _activeSessionMemo;
    final index = _activeSessionMemoIndex;
    if (memo != null &&
        memo.id == id &&
        index >= 0 &&
        index < sessions.length &&
        identical(sessions[index], memo)) {
      return memo;
    }
    final found = sessions.indexWhere((s) => s.id == id);
    _activeSessionMemoIndex = found;
    _activeSessionMemo = found < 0 ? null : sessions[found];
    return _activeSessionMemo;
  }

  /// Session lookup by id (used by the agent to keep a RUNNING run's
  /// writes bound to its own session even if the user switches chats).
  ChatSession? sessionById(String? id) =>
      id == null ? null : sessions.where((s) => s.id == id).firstOrNull;

  // ── Subagent lineage helpers ───────────────────────────────────────────
  /// User-facing chats only — subagent sessions never appear in the sidebar.
  List<ChatSession> get rootSessions =>
      sessions.where((s) => !s.isSubagent).toList();

  /// Message-content search for the sidebar (F-047): the SQLite FTS5 index
  /// when available (off the UI isolate), else a bounded in-memory scan.
  /// One hit per root chat, best first; deleted/hidden chats are dropped.
  Future<List<SessionContentHit>> searchSessionContent(
    String query, {
    int limit = 20,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    List<SessionContentHit>? hits;
    try {
      final prefs = await SharedPreferences.getInstance();
      hits = await SessionHistoryRepository.I.searchContent(
        prefs,
        _accountKey(_kSessions),
        trimmed,
        limit: limit,
      );
    } catch (e) {
      Diag.swallow('history.search', e);
    }
    if (hits != null) {
      return [
        for (final hit in hits)
          if (sessionById(hit.sessionId) case final s? when !s.isSubagent) hit,
      ];
    }
    return _scanSessionContent(trimmed, limit);
  }

  List<SessionContentHit> _scanSessionContent(String query, int limit) {
    final needle = query.toLowerCase();
    final out = <SessionContentHit>[];
    for (final session in rootSessionsByRecency) {
      for (var i = session.messages.length - 1; i >= 0; i--) {
        final m = session.messages[i];
        if (m.kind != MsgKind.text ||
            (m.role != 'user' && m.role != 'assistant')) {
          continue;
        }
        final lower = m.content.toLowerCase();
        final at = lower.indexOf(needle);
        if (at < 0) continue;
        if (lower.length != m.content.length) {
          // Case folding changed offsets; show the head without highlight.
          out.add(
            SessionContentHit(
              sessionId: session.id,
              messageIndex: i,
              role: m.role,
              snippet: m.content.length > 100
                  ? '${m.content.substring(0, 100)}…'
                  : m.content,
            ),
          );
          break;
        }
        final start = (at - 40).clamp(0, m.content.length);
        final end = (at + needle.length + 60).clamp(0, m.content.length);
        out.add(
          SessionContentHit(
            sessionId: session.id,
            messageIndex: i,
            role: m.role,
            snippet:
                '${start > 0 ? '…' : ''}${m.content.substring(start, at)}'
                '${SessionHistoryRepository.highlightStart}'
                '${m.content.substring(at, at + needle.length)}'
                '${SessionHistoryRepository.highlightEnd}'
                '${m.content.substring(at + needle.length, end)}'
                '${end < m.content.length ? '…' : ''}',
          ),
        );
        break;
      }
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Root sessions, most recent activity first (sidebar order, F-046).
  /// Compared at one-second resolution and stable for ties, so chats touched
  /// in the same second keep their stored (newest-created-first) order.
  List<ChatSession> get rootSessionsByRecency {
    final roots = rootSessions;
    final order = {for (var i = 0; i < roots.length; i++) roots[i]: i};
    int second(ChatSession s) =>
        s.lastActivityAt.millisecondsSinceEpoch ~/ 1000;
    return roots..sort((a, b) {
      final byTime = second(b).compareTo(second(a));
      return byTime != 0 ? byTime : order[a]!.compareTo(order[b]!);
    });
  }

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
    String persona = '',
    String outputSchemaHint = '',
    String? model,
    bool notify = true,
  }) {
    final child = ChatSession(
      id: 'sub-${DateTime.now().microsecondsSinceEpoch}',
      title: label.isEmpty ? 'Subagent' : label,
      // A Claude Code agent may pin its own model (frontmatter `model:`); when
      // provided and non-empty it wins, else the child inherits the parent's
      // (audit 2026-09-25 — plugin agents run as real subagents now).
      model: (model != null && model.trim().isNotEmpty)
          ? model.trim()
          : parent.model,
      providerId: parent.providerId,
      mode: mode,
      presetId: parent.presetId,
      parentId: parent.id,
      agentLabel: label,
      agentState: 'running',
      agentContinuable: continuable,
      agentPersona: persona,
      agentOutputHint: outputSchemaHint,
      // Children share the parent's working folder so their edits land in
      // the same project; without a pinned folder they get their own
      // sandbox workspace (sandboxId defaults to the child id).
      workspaceFolder: parent.workspaceFolder,
      workspaceFolderPinned: parent.workspaceFolderPinned,
      repo: parent.repo,
      // Children share the parent's `(repo, branch)` binding so their edits
      // land on the same ref, not the default branch.
      branch: parent.branch,
    );
    sessions.insert(0, child);
    _markSessionDirty(child.id);
    if (notify) notifyListeners();
    persistSessions();
    return child;
  }

  /// Update a subagent's lifecycle state (and optionally its final answer).
  void setAgentState(String sessionId, String state, {String? result}) {
    final s = sessionById(sessionId);
    if (s == null) return;
    s.agentState = state;
    if (result != null) s.agentResult = result;
    _markSessionDirty(sessionId);
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

  /// Resolve a bare model id to its provider **only when unambiguous**.
  /// Two providers can expose the same model id; silently picking the first
  /// would send a session's request to the wrong provider. On ambiguity this
  /// returns null and callers keep the stored `providerId` (or surface a
  /// chooser) rather than guessing.
  String? _inferProviderId(String model) {
    final modelId = model.split('·').first.trim();
    if (modelId.isEmpty || modelId == 'Select a provider') return null;
    final matches = providers
        .where((provider) => provider.models.contains(modelId))
        .toList();
    if (matches.length != 1) return null;
    return matches.first.id;
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
    if (_localHydrationSettled) {
      // A real root created after hydration is an implicit session start.
      _dispatchSessionStart(session);
    } else {
      // Constructor/hydration provisional root: capture the id, but never
      // clobber an already-captured restored marker (M3). Only the surviving
      // active root fires, once local hydration confirms no persisted root
      // replaced it (`_maybeFinishSessionRestore`); this prevents ghost events
      // for a discarded provisional ID.
      _pendingActiveRootId ??= session.id;
    }
    return session;
  }

  void setNav(int i) {
    navIndex = i;
    notifyListeners();
  }

  void selectSession(String id) {
    activeSessionId = id;
    // NOTE: runs are per-session (parallel) — switching NEVER stops a
    // running session (the session scheduler multi-session behavior).
    // PR23/M1: make sure the workspace dir exists for the mention menu.
    _warmWorkspace(id);
    notifyListeners();
    persistSessions();
    // A pending coalesced write must land before the user moves on.
    unawaited(flushSessionPersistence());
  }

  /// Set the ACTIVE session's agent mode (per-session, persisted). Other
  /// sessions' modes are untouched — parallel sessions never bleed.
  void setSessionMode(String m) {
    final s = activeSession;
    if (s == null || s.mode == m) return;
    s.mode = m;
    _markSessionDirty(s.id);
    notifyListeners();
    persistSessions();
  }

  /// Pin the ACTIVE session's working folder (composer folder picker).
  /// Null/empty clears it — the agent falls back to the sandbox workspace.
  /// Pins a session's working folder.
  ///
  /// [sessionId] defaults to the foreground session for UI callers. Agent code
  /// MUST pass its run session: with 10+ sessions able to run in parallel, an
  /// agent clone that pinned "the active session" would repoint whichever chat
  /// the user happened to be looking at.
  void setSessionWorkspaceFolder(String? path, {String? sessionId}) {
    final s = sessionId == null ? activeSession : sessionById(sessionId);
    if (s == null) return;
    final normalized = (path == null || path.trim().isEmpty)
        ? null
        : path.trim();
    if (s.workspaceFolder == normalized &&
        s.workspaceFolderPinned == (normalized != null)) {
      return;
    }
    s.workspaceFolder = normalized;
    // A picker (or a Studio bind) choosing a folder is what makes it THIS
    // chat's folder; clearing it drops the claim back to "no pinned folder".
    s.workspaceFolderPinned = normalized != null;
    lastWorkspaceFolder = normalized;
    unawaited(_persistLastSelection());
    _markSessionDirty(s.id);
    notifyListeners();
    persistSessions();
  }

  void newSession() {
    // Auto is the floor (owner directive 2026-10-18): a new chat NEVER
    // carries a "Select a provider" sentinel — the last selection or Auto.
    final newModel = lastSelectedModel.isEmpty || lastSelectedModel == 'Select a provider'
        ? 'auto'
        : lastSelectedModel;
    final s = ChatSession(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: 'New chat',
      model: newModel,
    );
    s.providerId = lastSelectedModel == newModel && lastSelectedModel.isNotEmpty
        ? (lastSelectedProviderId ?? _inferProviderId(lastSelectedModel))
        : ovidCloudProviderId;
    if (s.providerId == null || s.providerId!.isEmpty) {
      s.providerId = ovidCloudProviderId;
    }
    // New session starts with the last Studio repo/folder so a restart never
    // forces fresh selection. A vanished folder falls back to the sandbox.
    s.repo = lastRepoFull;
    s.branch = lastBranch;
    s.workspaceFolder = _resolvedLastWorkspaceFolder();
    // Carried over from the last selection (spec §5.2) — deliberately NOT
    // pinned. `workspaceFolderPinned` stays false so the prompt can say so.
    s.workspaceFolderPinned = false;
    sessions.insert(0, s);
    activeSessionId = s.id;
    // PR23/M1: the @file mention menu lists workspace files — the dir
    // must exist BEFORE the first agent run, else the menu is empty and
    // "@" looks dead. Best-effort warm-up.
    _warmWorkspace(s.id);
    // No provider.selectedModel mutation here — the provider field is
    // shared. Session A's in-flight run must never observe a model
    // selection that came from creating/switching to session B.
    notifyListeners();
    // Persist first, then dispatch exactly-once `created` lifecycle. The
    // method stays synchronous; the tracked future owns persistence.
    _dispatchSessionStart(s);
  }

  /// Fork the conversation: create a new session that copies messages
  /// `0..throughIndex` (inclusive) from [sessionId] and becomes active. The
  /// branch inherits the source's model, provider, mode, preset, and Studio
  /// binding, but gets its own transcript + workspace. Returns the new
  /// session, or null when the source or index is invalid.
  ChatSession? branchSessionFrom(String sessionId, int throughIndex) {
    final src = sessions.where((x) => x.id == sessionId).firstOrNull;
    if (src == null) return null;
    final end = (throughIndex + 1).clamp(0, src.messages.length);
    if (end <= 0) return null;
    final branch = ChatSession(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: '${src.title} (branch)',
      model: src.model,
      providerId: src.providerId,
      repo: src.repo,
      branch: src.branch,
      mode: src.mode,
      presetId: src.presetId,
      workspaceFolder: src.workspaceFolder,
      workspaceFolderPinned: src.workspaceFolderPinned,
      messages: [
        for (var i = 0; i < end; i++)
          Message.fromJson(src.messages[i].toJson()),
      ],
    );
    sessions.insert(0, branch);
    activeSessionId = branch.id;
    notifyListeners();
    persistSessions();
    return branch;
  }

  ChatSession? importSharedMessages(String sessionId, List<Message> safe) {
    if (safe.isEmpty) return null;
    final existing = sessions
        .where((session) => session.id == sessionId)
        .firstOrNull;
    final imported =
        existing ??
        ChatSession(
          id: sessionId,
          title: 'Shared conversation',
          model: lastSelectedModel.isEmpty
              ? 'Select a provider'
              : lastSelectedModel,
          providerId:
              lastSelectedProviderId ??
              (lastSelectedModel.isEmpty
                  ? null
                  : _inferProviderId(lastSelectedModel)),
        );
    if (existing == null) sessions.insert(0, imported);
    for (final message in safe) {
      final duplicate = imported.messages.any(
        (old) => old.role == message.role && old.content == message.content,
      );
      if (!duplicate) imported.messages.add(message);
    }
    activeSessionId = imported.id;
    notifyListeners();
    persistSessions();
    return imported;
  }

  /// Async workspace resolution used by surviving local-only paths (hooks,
  /// Studio drafts, legacy agent loop). Honours a pinned folder first, then
  /// the app-documents `workspaces/ws_<id>` layout, falling back to scratch
  /// space when path_provider is unavailable (unit tests without a mock).
  Future<Directory> workspaceDirForSession(String id) async {
    final pinned = workspaceDirProvider?.call(id);
    if (pinned != null) return pinned;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final dir = Directory('${docs.path}/workspaces/ws_$safe');
      await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return localWorkspaceDirFor(id);
    }
  }

  /// Ensure a session's workspace dir exists (mention menu + agent runs
  /// both rely on it). Best-effort + async — never blocks UI.
  void _warmWorkspace(String sessionId) {
    unawaited(() async {
      try {
        await workspaceDirForSession(sessionId);
      } catch (e) {
        Diag.swallow('state', e);
      }
    }());
  }

  Future<void> deleteSession(String id) async {
    if (_settingsBusy) throw StateError('Settings operation in progress.');
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
      activeSessionId = rootSessions
          .where((x) => !_pendingDeletionIds.contains(x.id))
          .firstOrNull
          ?.id;
    }
    for (final dead in doomed) {
      _scheduleSessionDeletion(dead.id, dead.sandboxId);
      ComposerDraftStore.I.remove(dead.id);
    }
    notifyListeners();
    persistSessions();
  }

  /// Set by the cloud facade at startup — drops the deleted session's run
  /// (avoids a circular import; parallel runs for other sessions live on).
  void Function(String sessionId)? onSessionDeleted;

  /// Called once after sessions load from disk — the agent service
  /// rebuilds its subagent handle registry from persisted lineage.
  void Function()? onSessionsLoaded;

  /// Remove all messages from [index] onward in the named session
  /// (the session revert action "Revert"/"Edit & resend" semantics). Clearing from index 0 also
  /// resets the compacted summary so the agent truly starts fresh.
  ///
  /// Returns the removed messages so callers can offer Undo through
  /// [restoreMessagesAt].
  Future<List<Message>> deleteMessagesFrom(String sessionId, int index) async {
    if (_settingsBusy) throw StateError('Settings operation in progress.');
    final s = sessions.where((x) => x.id == sessionId).firstOrNull;
    if (s == null) throw StateError('The conversation is no longer available.');
    final idx = index.clamp(0, s.messages.length);
    final removed = s.messages.skip(idx).toList();
    s.messages.removeWhere(removed.contains);
    _markSessionDirty(s.id);
    notifyListeners();
    persistSessions();
    return removed;
  }

  /// Undo for [deleteMessagesFrom]: re-appends [removed] at [index] when the
  /// conversation has not changed since (nothing was appended after the
  /// truncation). Restored rows get fresh local identities. Returns false
  /// when the undo is no longer safe.
  bool restoreMessagesAt(
    String sessionId,
    int index,
    List<Message> removed,
  ) {
    if (_settingsBusy || removed.isEmpty) return false;
    final s = sessionById(sessionId);
    if (s == null || s.messages.length != index) return false;
    s.messages.addAll([
      for (final m in removed)
        Message.fromJson({...m.toJson(), 'privateSyncId': _newMessageId()}),
    ]);
    _markSessionDirty(s.id);
    notifyListeners();
    persistSessions();
    return true;
  }

  /// Removes [sessionId]'s goal (UI "Clear goal"). Returns the cleared goal
  /// so the caller can offer Undo via [restoreGoal].
  Map<String, dynamic>? clearGoal(String sessionId) {
    final s = sessionById(sessionId);
    final goal = s?.goal;
    if (s == null || goal == null) return null;
    s.goal = null;
    _markSessionDirty(s.id);
    notifyListeners();
    persistSessions();
    return goal;
  }

  /// Undo for [clearGoal]; never overwrites a goal created meanwhile.
  bool restoreGoal(String sessionId, Map<String, dynamic> goal) {
    final s = sessionById(sessionId);
    if (s == null || s.goal != null) return false;
    s.goal = goal;
    _markSessionDirty(s.id);
    notifyListeners();
    persistSessions();
    return true;
  }

  // ── Soft delete (sidebar Undo window) ──
  final Set<String> _pendingDeletionIds = {};
  final Map<String, bool> _pendingDeletionWasActive = {};

  /// True while [sessionId] is hidden awaiting its durable deletion.
  bool isSessionDeletionPending(String sessionId) =>
      _pendingDeletionIds.contains(sessionId);

  /// Hides [sessionId] from the chat list immediately (optimistic delete);
  /// the durable [deleteSession] runs after the Undo window. When it was the
  /// active chat another visible chat becomes active.
  void hideSessionPending(String sessionId) {
    if (!_pendingDeletionIds.add(sessionId)) return;
    final wasActive = activeSessionId == sessionId;
    _pendingDeletionWasActive[sessionId] = wasActive;
    if (wasActive) {
      activeSessionId = rootSessions
          .where((s) => !_pendingDeletionIds.contains(s.id))
          .firstOrNull
          ?.id;
    }
    notifyListeners();
  }

  /// Reverses [hideSessionPending] (Undo, or a failed durable delete).
  void unhideSession(String sessionId) {
    if (!_pendingDeletionIds.remove(sessionId)) return;
    final wasActive = _pendingDeletionWasActive.remove(sessionId) ?? false;
    if (wasActive && sessionById(sessionId) != null) {
      activeSessionId = sessionId;
    }
    notifyListeners();
  }

  /// Durably deletes a session hidden by [hideSessionPending]. On failure the
  /// row is restored and the error rethrown for the caller to report.
  Future<void> commitPendingSessionDeletion(String sessionId) async {
    if (!_pendingDeletionIds.contains(sessionId)) return;
    try {
      await deleteSession(sessionId);
    } catch (_) {
      unhideSession(sessionId);
      rethrow;
    }
    _pendingDeletionIds.remove(sessionId);
    _pendingDeletionWasActive.remove(sessionId);
    notifyListeners();
  }

  /// Replace the content of an existing message (the message editor "Edit" of a user turn).
  void editMessage(String sessionId, int index, String newContent) {
    final s = sessions.where((x) => x.id == sessionId).firstOrNull;
    if (s == null || index < 0 || index >= s.messages.length) return;
    s.messages[index].content = newContent;
    _markSessionDirty(s.id);
    notifyListeners();
    persistSessions();
  }

  void renameSession(String id, String title) {
    // A rename can arrive for a session that was deleted in the same
    // frame (search results, ledger replay, queued rename). The previous
    // `sessions.firstWhere(...)` had no orElse and threw StateError.
    final s = sessionById(id);
    if (s == null) return;
    s.title = title;
    _markSessionDirty(id);
    // A cloud session's title is server-authoritative: without this PATCH
    // the next refresh overwrites the rename with the stale server title
    // (CloudSessionStore._applyDto). Fire-and-forget — the optimistic local
    // title above stands when the PATCH fails.
    CloudAgentFacade.renameSessionIfInstalled(id, title);
    notifyListeners();
    persistSessions();
  }

  void sendMessage(String text) {
    final s = _ensureActiveSession();
    s.messages.add(Message(role: 'user', content: text));
    s.touch();
    // Auto-name session from first message (smart: strip markdown/prompt fluff)
    if (s.title == 'New chat' || s.title.isEmpty) {
      s.title = _autoTitle(text);
    }
    _markSessionDirty(s.id);
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
        _markSessionDirty(session.id);
      }
    }
    refresh();
    persistProviderState();
    persistSessions();
  }

  /// Ovid Cloud provider id (built-in managed gateway, auto-slugged).
  static const ovidCloudProviderId = 'ovid-cloud';

  /// The user's current Ovid Cloud plan tier, as reported by the mint endpoint.
  /// One of 'free', '3x', '7x', '15x'. Drives the usage-screen display rule:
  /// free tier is Zen-style (no usage shown), paid tiers show plan usage.
  /// Persisted so the UI knows the tier before the next mint refresh.
  String ovidCloudTier = 'free';
  static const _kOvidTier = 'ovid_cloud_tier_v1';

  /// Whether the Ovid Cloud plan is a paid tier (usage visible) vs free (Zen).
  bool get ovidCloudIsPaid => ovidCloudTier != 'free';

  void setOvidCloudTier(String tier) {
    final t = const {'free', '3x', '7x', '15x'}.contains(tier) ? tier : 'free';
    if (t == ovidCloudTier) return;
    ovidCloudTier = t;
    SharedPreferences.getInstance()
        .then((p) => p.setString(_kOvidTier, t))
        .catchError((Object e) {
          Diag.swallow('state.setOvidCloudTier', e);
          return false;
        });
    notifyListeners();
  }

  Future<void> _loadOvidCloudTier() async {
    try {
      final p = await SharedPreferences.getInstance();
      final t = p.getString(_kOvidTier);
      if (t != null && const {'free', '3x', '7x', '15x'}.contains(t)) {
        ovidCloudTier = t;
      }
    } catch (e) {
      Diag.swallow('state._loadOvidCloudTier', e);
    }
  }

  /// One-shot notice when a remembered Ovid Cloud model left the catalog and
  /// was replaced by Auto. The chat screen shows it once and clears it.
  final ValueNotifier<String?> ovidCloudModelFallbackNotice = ValueNotifier(
    null,
  );

  void reconcileProviderModels(String providerId) {
    final provider = providerById(providerId);
    if (provider == null) return;
    if (provider.selectedModel != null &&
        !provider.models.contains(_baseModel(provider.selectedModel!))) {
      provider.selectedModel = null;
    }
    // Ovid Cloud always serves the server-side `auto` alias, so a model that
    // left its catalog falls back to Auto instead of 'Select a provider'.
    final cloudFallback =
        providerId == ovidCloudProviderId && provider.models.contains('auto');
    final removed = <String>{};
    for (final session in sessions) {
      if (session.providerId == providerId &&
          !provider.models.contains(_baseModel(session.model))) {
        if (cloudFallback) {
          removed.add(_baseModel(session.model));
          session.model = 'auto';
        } else {
          session
            ..providerId = null
            ..model = 'Select a provider';
        }
        _markSessionDirty(session.id);
      }
    }
    if (cloudFallback &&
        lastSelectedProviderId == providerId &&
        lastSelectedModel.isNotEmpty &&
        !provider.models.contains(_baseModel(lastSelectedModel))) {
      removed.add(_baseModel(lastSelectedModel));
      lastSelectedModel = 'auto';
      unawaited(_persistLastSelection());
    }
    if (removed.isNotEmpty) {
      ovidCloudModelFallbackNotice.value = removed.length == 1
          ? '${removed.single} is no longer available — switched to Auto.'
          : 'Some models are no longer available — switched to Auto.';
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
    _rememberRecentModel(providerId, model);
    _persistLastSelection();
    _markSessionDirty(s.id);
    notifyListeners();
    persistSessions();
  }

  Future<String?> addCustomProvider({
    required String name,
    required String baseUrl,
    String apiKey = '',
    ApiFormat? apiFormat,
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
      description: apiFormat == ApiFormat.anthropic
          ? 'Custom Anthropic Messages provider'
          : 'Custom OpenAI-compatible provider',
      baseUrl: normalizedUrl,
      apiKey: apiKey.trim(),
      custom: true,
      requiresApiKey: apiKey.trim().isNotEmpty,
      apiFormat: apiFormat,
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

  // ── Agent full-control helpers (catalog_* tools) ──────────────────────
  // The agent must be able to do everything the UI can: read a provider,
  // rename it, repoint its base URL, flip the wire format, set/clear the
  // key, and add/remove individual model ids. Each helper returns an error
  // string or null so the tool layer can surface a real reason.

  /// Update a provider's display name (id is stable, never renamed).
  Future<String?> updateProviderName(
    ProviderConfig provider,
    String value,
  ) async {
    final v = value.trim();
    if (v.isEmpty) return 'Provider name cannot be empty.';
    provider.name = v;
    refresh();
    await persistProviderState();
    return null;
  }

  /// Update a provider's description.
  Future<String?> updateProviderDescription(
    ProviderConfig provider,
    String value,
  ) async {
    provider.description = value.trim();
    refresh();
    await persistProviderState();
    return null;
  }

  /// Repoint a provider's base URL, validating it is an absolute URL.
  Future<String?> updateProviderBaseUrlChecked(
    ProviderConfig provider,
    String value,
  ) async {
    final v = value.trim();
    final uri = Uri.tryParse(v);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      return 'Enter a valid absolute base URL.';
    }
    provider.baseUrl = v;
    refresh();
    await persistProviderState();
    return null;
  }

  /// Flip the wire format (OpenAI-compatible vs native Anthropic).
  Future<String?> updateProviderApiFormat(
    ProviderConfig provider,
    ApiFormat format,
  ) async {
    provider.apiFormat = format;
    provider._hasExplicitApiFormat = true;
    if (provider.custom && provider._usesGeneratedDescription) {
      provider.description = provider._protocolDescription;
    }
    refresh();
    await persistProviderState();
    return null;
  }

  /// Replace the fetched model ids of [provider] with [ids] from a fresh
  /// `/models` call. Ids that an earlier fetch added but this one no longer
  /// lists are removed; with [keepManual] (the default) ids the user added
  /// by hand, or that shipped with the app, are kept. Persists once and
  /// returns the ids that were dropped.
  Future<List<String>> replaceProviderModels(
    ProviderConfig provider,
    Iterable<String> ids, {
    bool keepManual = true,
  }) async {
    final fresh = <String>[];
    final seen = <String>{};
    for (final raw in ids) {
      final id = raw.trim();
      if (id.isNotEmpty && seen.add(id)) fresh.add(id);
    }
    final previous = provider.fetchedModels.toSet();
    final kept = <String>[
      for (final m in provider.models)
        if (seen.contains(m) || (keepManual && !previous.contains(m))) m,
    ];
    final removed = [
      for (final m in provider.models)
        if (!kept.contains(m)) m,
    ];
    final keptSet = kept.toSet();
    provider.models = [
      ...kept,
      for (final id in fresh)
        if (!keptSet.contains(id)) id,
    ];
    provider.fetchedModels
      ..clear()
      ..addAll(fresh);
    // reconcileProviderModels refreshes and persists provider + sessions.
    reconcileProviderModels(provider.id);
    await _providerWrite;
    return removed;
  }

  /// Record that [provider]'s stored key passed a `/models` probe.
  Future<void> markProviderVerified(ProviderConfig provider) async {
    provider.verifiedAt = DateTime.now();
    refresh();
    await persistProviderState();
  }

  /// Add a model id to a provider (dedup). Empty ids are rejected.
  Future<String?> addProviderModel(
    ProviderConfig provider,
    String modelId,
  ) async {
    final m = modelId.trim();
    if (m.isEmpty) return 'Model id cannot be empty.';
    if (provider.models.contains(m)) {
      return '"$m" is already listed for ${provider.name}.';
    }
    provider.models.add(m);
    provider.fetchedModels.remove(m);
    refresh();
    await persistProviderState();
    return null;
  }

  /// Remove a model id. If it is the active session model, clear the
  /// selection so no session is left pointing at a removed model.
  Future<String?> removeProviderModel(
    ProviderConfig provider,
    String modelId,
  ) async {
    final m = modelId.trim();
    if (!provider.models.remove(m)) {
      return '"$m" is not listed for ${provider.name}.';
    }
    if (provider.selectedModel == m) provider.selectedModel = null;
    for (final s in sessions) {
      if (s.providerId == provider.id && s.model == m) {
        s.model = 'Select a provider';
        _markSessionDirty(s.id);
      }
    }
    refresh();
    await persistProviderState();
    await persistSessions();
    return null;
  }

  /// Clear a stored API key for any provider (built-in or custom).
  Future<String?> clearProviderApiKey(ProviderConfig provider) async {
    provider.apiKey = '';
    refresh();
    try {
      await _secureStorage.delete(key: '$_providerKeyPrefix${provider.id}');
    } catch (_) {
      return 'The stored key could not be removed from secure storage.';
    }
    await persistProviderState();
    return null;
  }

  /// Resolve a provider by id OR case-insensitive name, so the agent can
  /// say `provider_id: "Anthropic"` without knowing the slug.
  ProviderConfig? resolveProvider(String ref) {
    final r = ref.trim();
    if (r.isEmpty) return null;
    final byId = providerById(r);
    if (byId != null) return byId;
    final lower = r.toLowerCase();
    for (final p in providers) {
      if (p.name.toLowerCase() == lower) return p;
    }
    for (final p in providers) {
      if (p.name.toLowerCase().contains(lower) || p.id.contains(lower)) {
        return p;
      }
    }
    return null;
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
    } catch (e) {
      Diag.swallow('state', e);
    }
    // Clear the model from any session using it.
    for (final s in sessions) {
      if (s.providerId == p.id) {
        s
          ..providerId = null
          ..model = 'Select a provider';
        _markSessionDirty(s.id);
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

  // ── Custom Presets ──────────────────────────────────────────────────
  Future<void> _persistCustomPresets() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = PresetRegistry.customPresets.map((p) => p.toJson()).toList();
      await prefs.setString(_kCustomPresets, jsonEncode(list));
    } catch (e) {
      Diag.swallow('state', e);
    }
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
          // PER-ENTRY guard, deliberately INSIDE the outer try: `fromJson`
          // casts fields (`json['model'] as String`, `json['temperature'] as
          // num?`), so ONE wrong-typed field used to throw out of the whole
          // load — the tail never loaded and the next _persistCustomPresets
          // wrote only the loaded prefix, permanently deleting every later
          // custom preset. A corrupt entry is now skipped; the rest survive.
          try {
            if (item is Map<String, dynamic>) {
              PresetRegistry.saveCustom(AgentPreset.fromJson(item));
            } else if (item is Map) {
              PresetRegistry.saveCustom(
                AgentPreset.fromJson(item.cast<String, dynamic>()),
              );
            }
          } catch (e) {
            Diag.swallow('state', e);
          }
        }
      }
    } catch (e) {
      Diag.swallow('state', e);
    }
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


  // ── Per-session repo selection (Studio) ─────────────────────────────
  /// Repo bound to a session.  Falls back to [fallback] (the caller's
  /// global default — passed to avoid a circular import) when the session
  /// has no repo of its own, then to the persisted [lastRepoFull] so agent
  /// tools resolve after a restart.
  String? getRepoForSession(String sessionId, {String? fallback}) {
    final session = sessions.where((s) => s.id == sessionId).firstOrNull;
    return session?.repo ?? fallback ?? lastRepoFull;
  }

  void setRepoForSession(String sessionId, String repoFull) {
    final session = sessions.where((s) => s.id == sessionId).firstOrNull;
    if (session != null) {
      session.repo = repoFull;
      _markSessionDirty(session.id);
      lastRepoFull = repoFull;
      unawaited(_persistLastSelection());
      persistSessions();
      refresh();
    }
  }

  /// Branch bound to a session.  Falls back to [fallback] (the caller's
  /// global default) then to the persisted [lastBranch]; the repo binding
  /// is the pair `(repo, branch)`, so a null branch means `main`.
  String getBranchForSession(String sessionId, {String? fallback}) {
    final session = sessions.where((s) => s.id == sessionId).firstOrNull;
    return session?.branch ?? fallback ?? lastBranch;
  }

  void setBranchForSession(String sessionId, String branch) {
    final session = sessions.where((s) => s.id == sessionId).firstOrNull;
    if (session != null) {
      session.branch = branch;
      _markSessionDirty(session.id);
      lastBranch = branch;
      unawaited(_persistLastSelection());
      persistSessions();
      refresh();
    }
  }

  /// ---------- Built-in catalog ----------
  void _seed() {
    providers.addAll([
      ProviderConfig(
        name: 'Ovid Cloud',
        description:
            'Built-in models provided by Ovid. Auto mode picks the best '
            'model for you; manual models are also available. Sign in — no '
            'API key to manage.',
        // Public gateway (behind Cloudflare → LiteLLM). The real provider
        // base URLs/keys live server-side only; the app never sees them.
        baseUrl: 'https://api.ovidsi.com/v1',
        isFree: true,
        // Model list is fetched live from the gateway's /v1/models, so models
        // the owner adds in the LiteLLM dashboard appear here automatically.
        // 'auto' is seeded so Auto mode works before the first fetch.
        models: ['auto'],
      ),
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
        apiFormat: ApiFormat.anthropic,
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
            'Free credits for hosted open models on build.nvidia.com. '
            '82 models are live on the endpoint; context windows for the '
            'flagship Nemotron routes were read out of the API\'s own 400 '
            'responses (see ModelLimits).',
        baseUrl: 'https://integrate.api.nvidia.com/v1',
        isFree: true,
        // Every id here was checked against the live endpoint's model list
        // (2026-09-23). llama-3.3-70b-instruct, deepseek-r1 and
        // qwen2.5-coder-32b-instruct used to be seeded and now answer 404, so
        // they are gone rather than left as dead buttons.
        models: [
          'nvidia/nemotron-3-super-120b-a12b',
          'nvidia/nemotron-3-ultra-550b-a55b',
          'nvidia/nemotron-3.5-lightning-30b-a3b',
          'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning',
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

  }
}
