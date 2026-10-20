/// Wire DTOs for the Ovid Cloud thin client (P8 Task 5), plus the surviving
/// agent-surface value types (P8 Task 19).
///
/// Every shape mirrors the BUILT server contract exactly (camelCase JSON):
/// `cloud/packages/shared/src/rest.ts` for the DTOs, plus the built
/// `GET /health` wire shape `{status, checks:{db, redisQ}}`
/// (cloud/apps/gateway/src/routes/health.ts). The server is the contract —
/// when this file and the server disagree, fix this file.
///
/// The value types at the bottom (`AgentMode`, `ApprovalRequest`,
/// `UserQuestion`, `QuestionOption`, `BgJob`, `SubagentInfo`) moved here from
/// the retired local service in Task 19. They are the shapes
/// `AgentSurface` and the UI exchange; the local execution stack that used
/// to define them is gone.
library;

import 'dart:async' show Completer;
import 'dart:io' show Process;

import 'package:flutter/material.dart' show Color, IconData, Icons;

import '../theme.dart' show Aether;

/// `SessionDto` (rest.ts). `mode` is "safe" | "auto" | "drive" | "studio"
/// (spec D5 — "control" was retired; never re-add it).
class SessionDto {
  const SessionDto({
    required this.id,
    required this.title,
    required this.mode,
    required this.createdAt,
    required this.updatedAt,
    this.projectId,
  });

  factory SessionDto.fromJson(Map<String, dynamic> j) => SessionDto(
        id: j['id'] as String,
        title: j['title'] as String?,
        mode: j['mode'] as String,
        projectId: j['projectId'] as String?,
        createdAt: DateTime.parse(j['createdAt'] as String),
        updatedAt: DateTime.parse(j['updatedAt'] as String),
      );

  final String id;
  final String? title;
  final String mode;

  /// W1: the project this chat belongs to (null = ungrouped).
  final String? projectId;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// W1 project row (`GET /projects`). Counts and the plan cap are computed by
/// the server; the sidebar only renders them.
class ProjectDto {
  const ProjectDto({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.sessionCount,
    required this.fileCount,
    required this.fileCap,
  });

  factory ProjectDto.fromJson(Map<String, dynamic> j) => ProjectDto(
        id: j['id'] as String,
        name: j['name'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        updatedAt: DateTime.parse(j['updatedAt'] as String),
        sessionCount: (j['sessionCount'] as num?)?.toInt() ?? 0,
        fileCount: (j['fileCount'] as num?)?.toInt() ?? 0,
        fileCap: (j['fileCap'] as num?)?.toInt() ?? 80,
      );

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int sessionCount;
  final int fileCount;
  final int fileCap;
}

/// `MessageDto` (rest.ts). `role` is "user" | "assistant" | "system" | "tool".
class MessageDto {
  const MessageDto({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    required this.createdAt,
    this.attachments = const <MessageAttachmentDto>[],
  });

  factory MessageDto.fromJson(Map<String, dynamic> j) => MessageDto(
        id: j['id'] as String,
        sessionId: j['sessionId'] as String,
        role: j['role'] as String,
        content: j['content'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        attachments: <MessageAttachmentDto>[
          for (final a in (j['attachments'] as List? ?? const <dynamic>[]))
            if (a is Map<String, dynamic>) MessageAttachmentDto.fromJson(a),
        ],
      );

  final String id;
  final String sessionId;
  final String role;
  final String content;
  final DateTime createdAt;

  /// Wave 1b (CH-006): files sent with this user message (metadata only).
  final List<MessageAttachmentDto> attachments;
}

/// Wave 1b: one file sent with a message (`MessageAttachmentDto`, rest.ts).
class MessageAttachmentDto {
  const MessageAttachmentDto({
    required this.id,
    required this.name,
    required this.sizeBytes,
  });

  factory MessageAttachmentDto.fromJson(Map<String, dynamic> j) =>
      MessageAttachmentDto(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? 'file',
        sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
      );

  final String id;
  final String name;
  final int sizeBytes;
}

/// Wave 1b (`MessagePage`, rest.ts): the history page plus the snapshot's
/// event watermark, the session's active run and — when asked with
/// `events=1` — the page's settled agent activity (raw event JSON; the
/// store decodes it). [hasWatermark] is false on a pre-Wave-1b server that
/// answered no `lastEventSeq` key at all (distinct from a null watermark,
/// which means "no events yet").
class MessagePage extends CloudPage<MessageDto> {
  const MessagePage({
    required super.items,
    required super.nextCursor,
    this.hasWatermark = false,
    this.lastEventSeq,
    this.activeRunId,
    this.activeRunStatus,
    this.rawEvents,
  });

  factory MessagePage.fromJson(Map<String, dynamic> j) => MessagePage(
        items: <MessageDto>[
          for (final item in (j['items'] as List? ?? const <dynamic>[])
              .whereType<Map<String, dynamic>>())
            MessageDto.fromJson(item),
        ],
        nextCursor: j['nextCursor'] as String?,
        hasWatermark: j.containsKey('lastEventSeq'),
        lastEventSeq: j['lastEventSeq'] as String?,
        activeRunId: (j['activeRun'] as Map?)?['runId'] as String?,
        activeRunStatus: (j['activeRun'] as Map?)?['status'] as String?,
        rawEvents: j['events'] is List
            ? <Map<String, dynamic>>[
                for (final e in j['events'] as List)
                  if (e is Map) Map<String, dynamic>.from(e),
              ]
            : null,
      );

  final bool hasWatermark;
  final String? lastEventSeq;
  final String? activeRunId;
  final String? activeRunStatus;

  /// Null when the server sent no `events` (old server or not asked).
  final List<Map<String, dynamic>>? rawEvents;
}

/// Wave 1b: `RegenerateResponse` (rest.ts) — the 202 of
/// POST /sessions/:id/messages/:messageId/regenerate.
class RegenerateResponse {
  const RegenerateResponse({required this.runId, required this.promptMessageId});

  factory RegenerateResponse.fromJson(Map<String, dynamic> j) =>
      RegenerateResponse(
        runId: j['runId'] as String,
        promptMessageId: j['promptMessageId'] as String,
      );

  final String runId;
  final String promptMessageId;
}

/// `Page<T>` (rest.ts) — named CloudPage here because Flutter already has a
/// `Page` class. Keyset page: `nextCursor` is null when the page is the last.
class CloudPage<T> {
  const CloudPage({required this.items, required this.nextCursor});

  factory CloudPage.fromJson(
    Map<String, dynamic> j,
    T Function(Map<String, dynamic>) parse,
  ) =>
      CloudPage(
        items: [
          for (final item in (j['items'] as List? ?? <dynamic>[])
              .whereType<Map<String, dynamic>>())
            parse(item),
        ],
        nextCursor: j['nextCursor'] as String?,
      );

  final List<T> items;
  final String? nextCursor;
}

/// `SendMessageResponse` (rest.ts) — the 202 answer of POST
/// /sessions/:id/messages (and of a clientMsgId replay, verbatim).
class SendMessageResponse {
  const SendMessageResponse({
    required this.runId,
    required this.userMessageId,
    required this.status,
    this.model,
  });

  factory SendMessageResponse.fromJson(Map<String, dynamic> j) =>
      SendMessageResponse(
        runId: j['runId'] as String,
        userMessageId: j['userMessageId'] as String,
        status: j['status'] as String,
        model: j['model'] as String?,
      );

  final String runId;
  final String userMessageId;

  /// Always "queued" — the run executes async over WS.
  final String status;

  /// The model the server will route this session to after the send: the
  /// pinned catalog id, or "auto". Null from servers that predate the
  /// per-turn settings (Wave 1a).
  final String? model;
}

/// The per-turn settings that ride `POST /sessions/:id/messages` (Wave 1a,
/// CT-001 / CH-001 / CH-007 / CH-008): the header model pick, the access
/// mode chip, plan mode, the preset, and the sessions the user @-tagged.
///
/// The send body is the single source of truth: the gateway validates every
/// field (model against the allowed catalog, preset against the built-in
/// ids, session refs against the caller's own sessions) and persists the
/// settings into the session's agent state before the run is queued, so the
/// worker routes and gates the run with exactly what the user saw.
class CloudTurnOptions {
  const CloudTurnOptions({
    this.model,
    this.mode,
    this.planMode,
    this.presetId,
    this.sessionRefs = const <String>[],
  });

  factory CloudTurnOptions.fromJson(Map<String, dynamic> j) => CloudTurnOptions(
        model: j['model'] as String?,
        mode: j['mode'] as String?,
        planMode: j['planMode'] as bool?,
        presetId: j['presetId'] as String?,
        sessionRefs: <String>[
          for (final id in (j['sessionRefs'] as List? ?? const <dynamic>[]))
            if (id is String && id.isNotEmpty) id,
        ],
      );

  static const CloudTurnOptions none = CloudTurnOptions();

  /// A catalog id (optionally with an effort suffix `· high`) or "auto".
  final String? model;

  /// "safe" | "auto" | "drive" | "studio" — the [AgentMode] names.
  final String? mode;
  final bool? planMode;
  final String? presetId;

  /// Server ids of sessions the user explicitly @-tagged in this message.
  /// Session context never crosses chats otherwise (owner rule R1).
  final List<String> sessionRefs;

  /// The wire fields (absent keys are omitted, never sent as null).
  Map<String, Object> toJson() => <String, Object>{
        if (model != null && model!.trim().isNotEmpty) 'model': model!,
        'mode': ?mode,
        'planMode': ?planMode,
        if (presetId != null && presetId!.isNotEmpty) 'presetId': presetId!,
        if (sessionRefs.isNotEmpty) 'sessionRefs': sessionRefs,
      };
}

/// `GET/PATCH /cloud/v1/preferences` (Wave 1a, SE-005 / owner rule R1): the
/// per-user memory switches the worker enforces on every run.
class CloudUserPreferences {
  const CloudUserPreferences({
    required this.memoryEnabled,
    required this.shareSessionMemory,
  });

  factory CloudUserPreferences.fromJson(Map<String, dynamic> j) =>
      CloudUserPreferences(
        memoryEnabled: j['memoryEnabled'] as bool? ?? true,
        shareSessionMemory: j['shareSessionMemory'] as bool? ?? false,
      );

  /// Saved personal memory (memory_* tools) is available to the agent.
  final bool memoryEnabled;

  /// Cross-chat recall: the agent may search the user's OTHER chats. Off by
  /// default — a chat's context never leaks into another chat unless the
  /// user @-tags it or turns this on.
  final bool shareSessionMemory;
}

/// `RunCancelResponse` (rest.ts, P8 Task 1) — the 202 answer of POST
/// /runs/:id/cancel. "cancelled" = the gateway terminalized a queued run
/// inline; "cancelling" = a worker already claimed it and the cooperative
/// cancel flag will terminalize it as it streams.
class RunCancelResponse {
  const RunCancelResponse({required this.runId, required this.status});

  factory RunCancelResponse.fromJson(Map<String, dynamic> j) =>
      RunCancelResponse(
        runId: j['runId'] as String,
        status: j['status'] as String,
      );

  final String runId;
  final String status;
}

/// `AttachmentUploadResponse` (rest.ts, P8 Task 3) — the 201 answer of POST
/// /sessions/:id/attachments. [uploadUrl] is a presigned R2 PUT the client
/// uploads bytes to directly (no auth headers — the URL is the credential);
/// [path] is the workspace-relative path the worker materializes the file at
/// and the path to show the agent; [expiresAt] is when the presign dies.
class AttachmentUpload {
  const AttachmentUpload({
    required this.attachmentId,
    required this.uploadUrl,
    required this.path,
    required this.expiresAt,
  });

  factory AttachmentUpload.fromJson(Map<String, dynamic> j) => AttachmentUpload(
        attachmentId: j['attachmentId'] as String,
        uploadUrl: j['uploadUrl'] as String,
        path: j['path'] as String,
        expiresAt: DateTime.parse(j['expiresAt'] as String),
      );

  final String attachmentId;
  final String uploadUrl;
  final String path;
  final DateTime expiresAt;
}

/// `ArtifactUrlResponse` (workspace.ts) — the 200 answer of GET
/// /sessions/:id/artifacts/:artifactId/url. [url] is a presigned download
/// URL: a bearer capability valid until [expiresAt] (default TTL 1h), never
/// to be logged or persisted as if permanent.
class MintedArtifactUrl {
  const MintedArtifactUrl({required this.url, required this.expiresAt});

  factory MintedArtifactUrl.fromJson(Map<String, dynamic> j) =>
      MintedArtifactUrl(
        url: j['url'] as String,
        expiresAt: DateTime.parse(j['expiresAt'] as String),
      );

  final String url;
  final DateTime expiresAt;
}

/// One row of the bulk-history import batch (P8 Task 4). [clientMsgId] is the
/// idempotency key: a (session, clientMsgId) that already exists is skipped,
/// never duplicated. Wire form: strict camelCase, `createdAt` as ISO UTC.
class ImportMessage {
  const ImportMessage({
    required this.clientMsgId,
    required this.role,
    required this.content,
    required this.createdAt,
  });

  factory ImportMessage.fromJson(Map<String, dynamic> j) => ImportMessage(
        clientMsgId: j['clientMsgId'] as String,
        role: j['role'] as String,
        content: j['content'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
      );

  final String clientMsgId;
  final String role;
  final String content;
  final DateTime createdAt;

  Map<String, String> toJson() => <String, String>{
        'clientMsgId': clientMsgId,
        'role': role,
        'content': content,
        // The server's zod `.datetime()` wants a Z/offset-terminated ISO
        // stamp; Dart's local toIso8601String() has neither, so pin UTC.
        'createdAt': createdAt.toUtc().toIso8601String(),
      };
}

/// `ImportReport` (rest.ts, P8 Task 4) — the 201 answer of POST
/// /import/sessions. `sessionId` is the imported-into session (freshly created
/// when the request omitted one; re-sends return the SAME id).
class ImportReport {
  const ImportReport({
    required this.sessionId,
    required this.imported,
    required this.skipped,
  });

  factory ImportReport.fromJson(Map<String, dynamic> j) => ImportReport(
        sessionId: j['sessionId'] as String,
        imported: j['imported'] as int,
        skipped: j['skipped'] as int,
      );

  final String sessionId;
  final int imported;
  final int skipped;
}

/// The `checks` object of the built health route.
class CloudHealthChecks {
  const CloudHealthChecks({required this.db, required this.redisQ});

  factory CloudHealthChecks.fromJson(Map<String, dynamic> j) =>
      CloudHealthChecks(
        db: j['db'] as bool,
        redisQ: j['redisQ'] as bool,
      );

  final bool db;
  final bool redisQ;
}

/// The built `GET /health` wire shape: 200 `{status:"ok",…}` /
/// 503 `{status:"degraded",…}` — same body either way, only the status code
/// differs, so the client parses both identically.
class CloudHealth {
  const CloudHealth({required this.status, required this.checks});

  factory CloudHealth.fromJson(Map<String, dynamic> j) => CloudHealth(
        status: j['status'] as String,
        checks: CloudHealthChecks.fromJson(j['checks'] as Map<String, dynamic>),
      );

  /// "ok" | "degraded"
  final String status;
  final CloudHealthChecks checks;
}

/// One prompt composed while offline, queued for a FIFO flush on reconnect
/// (P8 Task 9, spec §12). [clientMsgId] is the Task 4 idempotency key: a
/// replayed flush returns the ORIGINAL run/user message, so the entry is
/// removed without creating a second run or optimistic row.
///
/// [account] is the `AppState.sessionAccountId` that composed the prompt
/// (P0 privacy): the queue is only ever delivered to, or surfaced by, its
/// owner. Null exists ONLY for rows persisted before the stamp — the store's
/// legacy migration attributes them to the current account at load.
class OutboxEntry {
  const OutboxEntry({
    required this.clientMsgId,
    required this.sessionId,
    required this.content,
    this.attachmentIds = const <String>[],
    required this.createdAt,
    this.maxOutputTokens,
    this.account,
    this.turn = CloudTurnOptions.none,
    this.attachmentFiles = const <OutboxFile>[],
    this.failedCode,
    this.failedMessage,
    this.attempts = 0,
  });

  factory OutboxEntry.fromJson(Map<String, dynamic> j) => OutboxEntry(
        clientMsgId: j['clientMsgId'] as String? ?? '',
        sessionId: j['sessionId'] as String? ?? '',
        content: j['content'] as String? ?? '',
        attachmentIds: <String>[
          for (final id in (j['attachmentIds'] as List? ?? const <dynamic>[]))
            if (id is String && id.isNotEmpty) id,
        ],
        createdAt:
            DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
        maxOutputTokens: j['maxOutputTokens'] as int?,
        account: j['account'] as String?,
        turn: j['turn'] is Map
            ? CloudTurnOptions.fromJson(
                Map<String, dynamic>.from(j['turn'] as Map))
            : CloudTurnOptions.none,
        attachmentFiles: <OutboxFile>[
          for (final f in (j['attachmentFiles'] as List? ?? const <dynamic>[]))
            if (f is Map) OutboxFile.fromJson(Map<String, dynamic>.from(f)),
        ],
        failedCode: j['failedCode'] as String?,
        failedMessage: j['failedMessage'] as String?,
        attempts: j['attempts'] as int? ?? 0,
      );

  final String clientMsgId;

  /// Local session id until [CloudSessionStore.ensureServerSession] maps it;
  /// the flush resolves it before sending.
  final String sessionId;
  final String content;

  /// Attachment ids already uploaded to the gateway. Empty when the files
  /// were staged while offline (the facade uploads them on reconnect before
  /// calling `flushOutbox`).
  final List<String> attachmentIds;
  final DateTime createdAt;

  /// The Settings "Max output tokens" pick captured at enqueue time, or
  /// null (auto). Rides the flush's sendMessage exactly like
  /// [CloudAgentFacade] passes it on the online path, so an offline send
  /// honors the same cap a direct one does.
  final int? maxOutputTokens;

  /// The owning `AppState.sessionAccountId` (see the class comment). Null
  /// only on pre-stamp rows, before the legacy migration runs.
  final String? account;

  /// The per-turn settings captured when the user pressed Send (model, mode,
  /// plan, preset, @-tagged sessions) — a later flush sends exactly these.
  final CloudTurnOptions turn;

  /// Files the user attached that are not uploaded yet (CH-033 / CH-035):
  /// the flush uploads each one to the resolved server session and records
  /// its id in [attachmentIds] before the send, so a prompt composed in a
  /// brand-new or offline chat keeps its files.
  final List<OutboxFile> attachmentFiles;

  /// Non-null once the server REFUSED this prompt for a reason a retry
  /// cannot fix by itself (a 4xx such as 400/402/403/404/413). The entry is
  /// KEPT (never silently dropped — CH-009) and shown as "Not sent" with
  /// Retry / Discard until the user decides.
  final String? failedCode;
  final String? failedMessage;

  /// Delivery attempts that hit a transient failure (network, timeout, 429,
  /// 5xx) — drives the retry backoff.
  final int attempts;

  bool get failed => failedCode != null;

  OutboxEntry copyWith({
    String? sessionId,
    List<String>? attachmentIds,
    int? maxOutputTokens,
    String? account,
    List<OutboxFile>? attachmentFiles,
    String? failedCode,
    String? failedMessage,
    bool clearFailure = false,
    int? attempts,
  }) =>
      OutboxEntry(
        clientMsgId: clientMsgId,
        sessionId: sessionId ?? this.sessionId,
        content: content,
        attachmentIds: attachmentIds ?? this.attachmentIds,
        createdAt: createdAt,
        maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
        account: account ?? this.account,
        turn: turn,
        attachmentFiles: attachmentFiles ?? this.attachmentFiles,
        failedCode: clearFailure ? null : (failedCode ?? this.failedCode),
        failedMessage:
            clearFailure ? null : (failedMessage ?? this.failedMessage),
        attempts: attempts ?? this.attempts,
      );

  Map<String, dynamic> toJson() {
    final turnJson = turn.toJson();
    return <String, dynamic>{
      'clientMsgId': clientMsgId,
      'sessionId': sessionId,
      'content': content,
      if (attachmentIds.isNotEmpty) 'attachmentIds': attachmentIds,
      // The server's zod `.datetime()` wants a Z-terminated stamp.
      'createdAt': createdAt.toUtc().toIso8601String(),
      if (maxOutputTokens != null) 'maxOutputTokens': maxOutputTokens,
      if (account != null) 'account': account,
      if (turnJson.isNotEmpty) 'turn': turnJson,
      if (attachmentFiles.isNotEmpty)
        'attachmentFiles': [for (final f in attachmentFiles) f.toJson()],
      'failedCode': ?failedCode,
      'failedMessage': ?failedMessage,
      if (attempts > 0) 'attempts': attempts,
    };
  }
}

/// A not-yet-uploaded attachment of an [OutboxEntry]: the staged file on
/// disk. Uploaded at flush time, once the target server session exists.
class OutboxFile {
  const OutboxFile({required this.name, required this.path, required this.size});

  factory OutboxFile.fromJson(Map<String, dynamic> j) => OutboxFile(
        name: j['name'] as String? ?? 'file',
        path: j['path'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
      );

  final String name;
  final String path;
  final int size;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'name': name, 'path': path, 'size': size};
}

/// Client-side run state assembled from WS session events (P8 later tasks
/// feed it from `run_started` / `run_started_retry` / `run_completed` /
/// `run_failed`). Tolerant of missing fields — it is a snapshot, not a wire
/// DTO the server sends as one piece.
class CloudRunState {
  const CloudRunState({
    this.runId,
    this.busy = false,
    this.stopRequested = false,
    this.statusLine,
    this.retryAttempt,
    this.retryNextBackoffMs,
    this.lastErrorCode,
    this.lastErrorMessage,
  });

  factory CloudRunState.fromJson(Map<String, dynamic> j) => CloudRunState(
        runId: j['runId'] as String?,
        busy: j['busy'] as bool? ?? false,
        stopRequested: j['stopRequested'] as bool? ?? false,
        statusLine: j['statusLine'] as String?,
        retryAttempt: j['retryAttempt'] as int?,
        retryNextBackoffMs: j['retryNextBackoffMs'] as int?,
        lastErrorCode: j['lastErrorCode'] as String?,
        lastErrorMessage: j['lastErrorMessage'] as String?,
      );

  final String? runId;
  final bool busy;
  final bool stopRequested;
  final String? statusLine;
  final int? retryAttempt;
  final int? retryNextBackoffMs;
  final String? lastErrorCode;
  final String? lastErrorMessage;
}

/// A queued message removed by `AgentSurface.takeQueuedMessages`.
typedef QueuedMessageSnapshot = ({
  int id,
  String text,
  bool userReferences,
  bool nextDispatch,
  List<({String name, String path, int size})> attachments,
});

/// ═══════════════════════════════════════════════════════════════════
/// AGENT ACCESS MODES (web-IDE style)
/// ───────────────────────────────────────────────────────────────────
/// READ-ONLY → asks user before every action (shell/write/commit all)
/// GENERAL   → shell + browser free; asks for file writes & commits
/// FULL      → sab kuch free, no confirmation (Codex full-send)
/// STUDIO    → general + full Studio access: files edit, terminal, repo
///             sync free; sirf publish/commit confirm karta hai
///
/// `control` was retired in P8 Task 13 (spec D5) and removed from the enum
/// in Task 19; never re-add it.
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
      'Full access. Runs anything, anywhere, without asking.',
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

/// The modes every picker offers. Read-Only stays reachable internally —
/// legacy sessions persisted as `safe` keep working and
/// `/permission read-only` stays functional — but it is never a direct
/// pick: the read-only policy is selected through the `plan` preset.
List<AgentMode> modeOptionsForPicker() => AgentMode.values
    .where((m) => m != AgentMode.safe)
    .toList(growable: false);

class ApprovalRequest {
  final String tool;
  final String summary;
  final String detail;
  final Completer<bool> completer = Completer<bool>();
  // ── ask_user_question extension (the question gate user-questions seam) ──
  /// When non-null, the UI renders structured questions instead of
  /// approve/deny.  The completer resolves true when the user submits
  /// answers; [answers] holds the question-id → answer map.
  final List<UserQuestion>? questions;
  final Map<String, String> answers = {};

  /// Plan text without the surrounding framing prose, for the plan-review
  /// card (the card must not re-parse [detail] to find it).
  final String? planBody;

  /// Free-text note the user attached when refusing (e.g. "Chat about it"),
  /// handed back to the model so it can revise instead of guessing.
  String? note;

  /// When true the approval card offers a third "Always allow" action that
  /// remembers the tool for the rest of the session. Only plain tool
  /// approvals set this — destructive commands, plugin installs, device
  /// permissions, questions and plan reviews never do.
  final bool allowAlways;

  /// Set by the UI; persistence happens back in the requesting run's context.
  bool remember = false;

  /// AgentMode name of the run that raised this prompt, captured at creation.
  ///
  /// `approveAlways` runs from the UI, OUTSIDE any run zone, so reading the
  /// `mode` getter there would resolve to whichever session happens to be
  /// foreground — and tag the grant with the wrong mode. Capturing it on the
  /// request is what makes per-mode grants correct with parallel sessions.
  final String modeName;

  /// The cloud approval gate's answer key (the `approval_requested` payload's
  /// `approvalId`): what the `approval_resolved` fold clears by and what the
  /// facade's `approval_response` op echoes back to the worker's bridge.
  /// Null on prompts the test seams construct — those never reach the wire,
  /// and [CloudAgentFacade.approveRequest] answers them with false.
  final String? approvalId;

  /// 'tool' | 'question' | 'plan' — the gate's prompt kind (CH-017). A
  /// `plan` prompt renders the plan-review card, never a generic tool card.
  final String kind;

  /// When the server auto-denies an unanswered prompt (null = it waits).
  final DateTime? expiresAt;

  /// True between the user's tap and the server confirming the decision
  /// (CH-017): the card stays up in a "Sending…" state and is restored if
  /// the answer never reaches the server.
  bool sending = false;

  ApprovalRequest({
    required this.tool,
    required this.summary,
    required this.detail,
    this.questions,
    this.planBody,
    this.allowAlways = false,
    this.modeName = '',
    this.approvalId,
    this.kind = 'tool',
    this.expiresAt,
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

/// Background job (the process manager ctx.jobs equivalent) — a running Process with a
/// name, output buffer, and lifecycle state.
class BgJob {
  final int id;
  final String name;
  final String command;
  Process? process;
  bool started = false;
  bool finished = false;
  bool killed = false;
  int? exitCode;
  final DateTime startedAt = DateTime.now();
  final StringBuffer output = StringBuffer();
  BgJob({required this.id, required this.name, required this.command});

  Duration get elapsed => DateTime.now().difference(startedAt);
  String get state => killed
      ? 'stopping'
      : (!started
            ? 'pending'
            : !finished
            ? 'running'
            : 'done');
}

/// A dispatched subagent, tracked by the parent that spawned it.
///
/// The child is a REAL `ChatSession` (its own transcript, tool cards, live
/// streaming and workspace), so opening it shows exactly what the child did
/// instead of an opaque "subagent finished" line. This object is just the
/// parent-side handle: lifecycle, follow-up inbox, and the reported result.
class SubagentInfo {
  final String id;
  final String label;
  final String sessionId;
  final String parentSessionId;
  final AgentMode parentMode;
  final String prompt;

  /// Follow-up instructions queued by `send_message` (FIFO inbox).
  final List<String> messages = [];
  final Set<int> userReferenceMessages = {};
  bool interrupted = false;
  bool finished = false;
  String result = '';

  /// True when started via `run_in_background` — such children deliver a
  /// settlement notice to the parent when they end (the subagent coordinator parity); foreground
  /// children return their result as the tool result instead.
  final bool background;
  final DateTime startedAt = DateTime.now();
  DateTime? finishedAt;

  /// [CC] `agent_type`: the definition name (`general-purpose` for an
  /// ad-hoc dispatch, `plugin:agent` for a plugin-shipped agent). Hooks
  /// receive it and SubagentStart/SubagentStop matchers filter on it.
  String agentType;

  /// `hookSpecificOutput.additionalContext` returned by SubagentStart hooks —
  /// added to the subagent's context before its first prompt.
  String startContext = '';

  SubagentInfo({
    required this.id,
    required this.label,
    required this.sessionId,
    required this.parentSessionId,
    required this.parentMode,
    required this.prompt,
    this.background = false,
    this.agentType = 'general-purpose',
  });

  String get state => finished
      ? (interrupted ? 'stopped' : 'finished')
      : (interrupted ? 'stopping' : 'running');

  Duration get elapsed => (finishedAt ?? DateTime.now()).difference(startedAt);
}
