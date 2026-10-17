/// Wire DTOs for the Ovid Cloud thin client (P8 Task 5).
///
/// Every shape mirrors the BUILT server contract exactly (camelCase JSON):
/// `cloud/packages/shared/src/rest.ts` for the DTOs, plus the built
/// `GET /health` wire shape `{status, checks:{db, redisQ}}`
/// (cloud/apps/gateway/src/routes/health.ts). The server is the contract —
/// when this file and the server disagree, fix this file.
library;

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
