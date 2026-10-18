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
  });

  factory SessionDto.fromJson(Map<String, dynamic> j) => SessionDto(
        id: j['id'] as String,
        title: j['title'] as String?,
        mode: j['mode'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        updatedAt: DateTime.parse(j['updatedAt'] as String),
      );

  final String id;
  final String? title;
  final String mode;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// `MessageDto` (rest.ts). `role` is "user" | "assistant" | "system" | "tool".
class MessageDto {
  const MessageDto({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    required this.createdAt,
  });

  factory MessageDto.fromJson(Map<String, dynamic> j) => MessageDto(
        id: j['id'] as String,
        sessionId: j['sessionId'] as String,
        role: j['role'] as String,
        content: j['content'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
      );

  final String id;
  final String sessionId;
  final String role;
  final String content;
  final DateTime createdAt;
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
  });

  factory SendMessageResponse.fromJson(Map<String, dynamic> j) =>
      SendMessageResponse(
        runId: j['runId'] as String,
        userMessageId: j['userMessageId'] as String,
        status: j['status'] as String,
      );

  final String runId;
  final String userMessageId;

  /// Always "queued" — the run executes async over WS.
  final String status;
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
class OutboxEntry {
  const OutboxEntry({
    required this.clientMsgId,
    required this.sessionId,
    required this.content,
    this.attachmentIds = const <String>[],
    required this.createdAt,
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

  OutboxEntry copyWith({
    String? sessionId,
    List<String>? attachmentIds,
  }) =>
      OutboxEntry(
        clientMsgId: clientMsgId,
        sessionId: sessionId ?? this.sessionId,
        content: content,
        attachmentIds: attachmentIds ?? this.attachmentIds,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'clientMsgId': clientMsgId,
        'sessionId': sessionId,
        'content': content,
        if (attachmentIds.isNotEmpty) 'attachmentIds': attachmentIds,
        // The server's zod `.datetime()` wants a Z-terminated stamp.
        'createdAt': createdAt.toUtc().toIso8601String(),
      };
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

  ApprovalRequest({
    required this.tool,
    required this.summary,
    required this.detail,
    this.questions,
    this.planBody,
    this.allowAlways = false,
    this.modeName = '',
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
