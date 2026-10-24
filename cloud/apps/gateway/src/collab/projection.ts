import type { Db } from "@ovid/db";

export type CollabProjectionErrorCode =
  | "not_member"
  | "session_closed"
  | "cursor_reset";

export class CollabProjectionError extends Error {
  readonly code: CollabProjectionErrorCode;

  constructor(code: CollabProjectionErrorCode) {
    super(code);
    this.name = "CollabProjectionError";
    this.code = code;
  }
}

export interface CollabMemberDto {
  participantId: string;
  role: "owner" | "participant";
  status: "active" | "left" | "revoked";
  displayName?: string;
}

export interface CollabSessionDto {
  schemaVersion: 1;
  sessionId: string;
  ownerParticipantId: string;
  lifecycle: "active" | "closing" | "closed";
}

export interface CollabTurnDto {
  holderParticipantId: string;
  runId: string;
  startedAt: string;
  heartbeatAt: string;
}

export interface CollabWireEvent {
  schemaVersion: 1;
  eventId: string;
  sessionId: string;
  eventSequence: number;
  senderParticipantId: string;
  kind: string;
  createdAt: string;
  payload: Record<string, unknown>;
  senderDisplayName?: string;
}

export interface CollabEventPage {
  schemaVersion: 1;
  events: CollabWireEvent[];
  nextCursor: string;
  hasMore: boolean;
}

export interface CollabStateDto {
  schemaVersion: 1;
  session: CollabSessionDto;
  member: CollabMemberDto;
  members: CollabMemberDto[];
  initialMembers: CollabMemberDto[];
  replayThroughSequence: number;
  cursor: string;
  turn: CollabTurnDto | null;
}

export interface CollabPageInput {
  roomId: string;
  viewerUid: string;
  cursor: string | null;
  limit: number;
}

export interface CollabStateInput {
  roomId: string;
  viewerUid: string;
}

export interface CollabProjectionReader {
  page(input: CollabPageInput): Promise<CollabEventPage>;
}

interface RoomContext {
  roomId: string;
  sessionId: string;
  lifecycle: CollabSessionDto["lifecycle"];
  ownerParticipantId: string;
  member: CollabMemberDto;
}

interface SourceRow {
  source_id: string;
  kind: string;
  occurred_at: string;
  sort_ms: string;
  sort_sub: string;
  sender_participant_id: string;
  sender_display_name: string | null;
  message_role: "user" | "assistant" | null;
  message_content: string | null;
  model: string | null;
  event_payload: Record<string, unknown> | null;
  mirror_type: string | null;
  run_id: string | null;
}

interface ProjectionRows {
  head: number;
  prefix: string;
  nextPrefix: string;
  hasMore: boolean;
  rows: SourceRow[];
}

const PROJECTION_SQL = `
WITH sources AS (
  SELECT
    'message:' || m.id AS source_id,
    'message' AS kind,
    m.created_at AS occurred_at,
    '-1'::text AS sort_ms,
    '-1'::text AS sort_sub,
    m.id AS tie_id,
    CASE WHEN m.role = 'user'
      THEN COALESCE(sender.participant_id, owner.participant_id)
      ELSE COALESCE(sender.participant_id, '') END AS sender_participant_id,
    CASE WHEN m.role = 'user'
      THEN COALESCE(sender.display_name, owner.display_name)
      ELSE sender.display_name END AS sender_display_name,
    m.role AS message_role,
    m.content AS message_content,
    CASE WHEN m.role = 'assistant'
      THEN COALESCE(assistant_turn.model, assistant_usage.model)
      ELSE NULL END AS model,
    NULL::jsonb AS event_payload,
    NULL::text AS mirror_type,
    NULL::text AS run_id
  FROM messages m
  JOIN collab_rooms room
    ON room.session_id = m.session_id AND room.id = $1
  JOIN collab_members owner
    ON owner.room_id = room.id AND owner.role = 'owner' AND owner.status = 'active'
  LEFT JOIN collab_turns user_turn
    ON user_turn.room_id = room.id AND user_turn.user_message_id = m.id
  LEFT JOIN LATERAL (
    SELECT candidate.participant_id, candidate.model, candidate_run.id AS run_id
    FROM runs candidate_run
    JOIN collab_turns candidate
      ON candidate.room_id = room.id AND candidate.run_id = candidate_run.id
    WHERE candidate_run.session_id = m.session_id
      AND candidate_run.prompt_message_id < m.id
      AND NOT EXISTS (
        SELECT 1 FROM messages intervening
        WHERE intervening.session_id = m.session_id
          AND intervening.role = 'user'
          AND intervening.id > candidate_run.prompt_message_id
          AND intervening.id < m.id
      )
    ORDER BY candidate_run.prompt_message_id DESC, candidate_run.id DESC
    LIMIT 1
  ) assistant_turn ON m.role = 'assistant'
  LEFT JOIN LATERAL (
    SELECT usage.model
    FROM run_usage usage
    WHERE usage.run_id = assistant_turn.run_id
    ORDER BY usage.created_at DESC, usage.id DESC
    LIMIT 1
  ) assistant_usage ON m.role = 'assistant'
  LEFT JOIN collab_members sender
    ON sender.room_id = room.id
    AND sender.participant_id = COALESCE(user_turn.participant_id, assistant_turn.participant_id)
  WHERE m.role IN ('user', 'assistant')

  UNION ALL

  SELECT
    'mirror:' || mirror.seq AS source_id,
    CASE WHEN mirror.type IN ('run_started', 'run_started_retry', 'run_completed', 'run_failed', 'run_cancelled')
      THEN 'modelStatus' ELSE mirror.type END AS kind,
    mirror.ts AS occurred_at,
    split_part(mirror.seq, '-', 1) AS sort_ms,
    COALESCE(NULLIF(split_part(mirror.seq, '-', 2), ''), '0') AS sort_sub,
    mirror.seq AS tie_id,
    COALESCE(sender.participant_id, '') AS sender_participant_id,
    sender.display_name AS sender_display_name,
    NULL::text AS message_role,
    NULL::text AS message_content,
    COALESCE(turn.model, usage.model) AS model,
    mirror.payload AS event_payload,
    mirror.type AS mirror_type,
    COALESCE(run.id, turn.run_id, lease.run_id, NULLIF(mirror.payload->>'runId', '')) AS run_id
  FROM session_event_mirror mirror
  JOIN collab_rooms room
    ON room.session_id = mirror.session_id AND room.id = $1
  LEFT JOIN LATERAL (
    SELECT candidate_lease.run_id
    FROM collab_sender_leases candidate_lease
    WHERE candidate_lease.room_id = room.id
      AND NULLIF(mirror.payload->>'runId', '') IS NULL
      AND candidate_lease.started_at <= mirror.ts
      AND (candidate_lease.released_at IS NULL OR mirror.ts <= candidate_lease.released_at)
    ORDER BY candidate_lease.started_at DESC, candidate_lease.id DESC
    LIMIT 1
  ) lease ON TRUE
  LEFT JOIN runs run
    ON run.session_id = mirror.session_id
    AND run.id = COALESCE(NULLIF(mirror.payload->>'runId', ''), lease.run_id)
  LEFT JOIN collab_turns turn
    ON turn.room_id = room.id
    AND turn.run_id = COALESCE(NULLIF(mirror.payload->>'runId', ''), lease.run_id)
  LEFT JOIN LATERAL (
    SELECT candidate_usage.model
    FROM run_usage candidate_usage
    WHERE candidate_usage.run_id = COALESCE(NULLIF(mirror.payload->>'runId', ''), lease.run_id)
    ORDER BY candidate_usage.created_at DESC, candidate_usage.id DESC
    LIMIT 1
  ) usage ON TRUE
  LEFT JOIN collab_members sender
    ON sender.room_id = room.id AND sender.participant_id = turn.participant_id
  WHERE mirror.type IN (
    'run_started', 'run_started_retry', 'run_completed', 'run_failed', 'run_cancelled',
    'tool_started', 'tool_completed', 'artifact_created'
  )
), ordered AS (
  SELECT sources.* FROM sources
), head AS (
  SELECT COUNT(*)::int AS value FROM ordered
), current_prefix AS (
  SELECT md5(COALESCE(string_agg(source_id, E'\n' ORDER BY occurred_at, sort_ms::numeric, sort_sub::numeric, source_id), '')) AS value
  FROM (
    SELECT source_id, occurred_at, sort_ms, sort_sub
    FROM ordered
    ORDER BY occurred_at, sort_ms::numeric, sort_sub::numeric, source_id
    LIMIT $2
  ) delivered
), page AS MATERIALIZED (
  SELECT * FROM ordered
  WHERE $2 = 0 OR
    occurred_at > $4::timestamptz OR
    (occurred_at = $4::timestamptz AND sort_ms::numeric > $5::numeric) OR
    (occurred_at = $4::timestamptz AND sort_ms::numeric = $5::numeric AND sort_sub::numeric > $6::numeric) OR
    (occurred_at = $4::timestamptz AND sort_ms::numeric = $5::numeric AND sort_sub::numeric = $6::numeric AND source_id > $7)
  ORDER BY occurred_at, sort_ms::numeric, sort_sub::numeric, source_id
  LIMIT $3
), answer AS (
  SELECT * FROM page LIMIT ($3 - 1)
), next_prefix AS (
  SELECT md5(COALESCE(string_agg(source_id, E'\n' ORDER BY occurred_at, sort_ms::numeric, sort_sub::numeric, source_id), '')) AS value
  FROM (
    SELECT source_id, occurred_at, sort_ms, sort_sub
    FROM ordered
    ORDER BY occurred_at, sort_ms::numeric, sort_sub::numeric, source_id
    LIMIT ($2 + (SELECT count(*) FROM answer))
  ) delivered
)
SELECT
  head.value AS head,
  current_prefix.value AS prefix,
  next_prefix.value AS next_prefix,
  ((SELECT count(*) FROM page) > ($3 - 1)) AS has_more,
  COALESCE(
    jsonb_agg(to_jsonb(answer) ORDER BY answer.occurred_at, answer.sort_ms::numeric, answer.sort_sub::numeric, answer.source_id)
      FILTER (WHERE answer.source_id IS NOT NULL),
    '[]'::jsonb
  ) AS rows
FROM head
CROSS JOIN current_prefix
CROSS JOIN next_prefix
LEFT JOIN answer ON TRUE
GROUP BY head.value, current_prefix.value, next_prefix.value
`;

function clampLimit(value: number): number {
  if (value === Number.POSITIVE_INFINITY) return 100;
  const integer = Math.trunc(value);
  if (!Number.isFinite(integer)) return 1;
  return Math.min(100, Math.max(1, integer));
}

interface CanonicalCursor {
  sequence: number;
  prefix: string;
  after: {
    occurredAt: string;
    sortMs: string;
    sortSub: string;
    sourceId: string;
  } | null;
}

const EMPTY_PREFIX = "d41d8cd98f00b204e9800998ecf8427e";

function initialCursor(): CanonicalCursor {
  return { sequence: 0, prefix: EMPTY_PREFIX, after: null };
}

function decodeCursor(cursor: string | null): CanonicalCursor {
  if (cursor === null || cursor === "v1:0") return initialCursor();
  if (cursor.length > 4096 || !cursor.startsWith("v1:")) {
    throw new CollabProjectionError("cursor_reset");
  }
  try {
    const decoded: unknown = JSON.parse(
      Buffer.from(cursor.slice(3), "base64url").toString("utf8"),
    );
    if (!Array.isArray(decoded) || decoded.length !== 3) throw new Error("shape");
    const [sequence, prefix, after] = decoded as [unknown, unknown, unknown];
    if (
      !Number.isSafeInteger(sequence) ||
      (sequence as number) < 1 ||
      typeof prefix !== "string" ||
      !/^[a-f0-9]{32}$/.test(prefix) ||
      !Array.isArray(after) ||
      after.length !== 4
    ) {
      throw new Error("shape");
    }
    const [occurredAt, sortMs, sortSub, sourceId] = after as unknown[];
    if (
      typeof occurredAt !== "string" ||
      new Date(occurredAt).toISOString() !== occurredAt ||
      typeof sortMs !== "string" ||
      !/^-?\d+$/.test(sortMs) ||
      typeof sortSub !== "string" ||
      !/^-?\d+$/.test(sortSub) ||
      typeof sourceId !== "string" ||
      sourceId.length < 1 ||
      sourceId.length > 512
    ) {
      throw new Error("shape");
    }
    return {
      sequence: sequence as number,
      prefix,
      after: { occurredAt, sortMs, sortSub, sourceId },
    };
  } catch {
    throw new CollabProjectionError("cursor_reset");
  }
}

function encodeCursor(sequence: number, prefix: string, row: SourceRow): string {
  const payload = JSON.stringify([
    sequence,
    prefix,
    [isoTime(row.occurred_at), row.sort_ms, row.sort_sub, row.source_id],
  ]);
  return `v1:${Buffer.from(payload, "utf8").toString("base64url")}`;
}

function isoTime(value: unknown): string {
  if (value instanceof Date) return value.toISOString();
  return new Date(String(value)).toISOString();
}

function text(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function memberDto(row: Record<string, unknown>): CollabMemberDto {
  const displayName = text(row.display_name);
  return {
    participantId: String(row.participant_id),
    role: row.role === "owner" ? "owner" : "participant",
    status: row.status === "left" || row.status === "revoked" ? row.status : "active",
    ...(displayName === null ? {} : { displayName }),
  };
}

function modelStatus(type: string, payload: Record<string, unknown>): "queued" | "running" | "completed" | "failed" | "cancelled" {
  if (type === "run_started") return "running";
  if (type === "run_started_retry") return "queued";
  if (type === "run_completed") return "completed";
  if (type === "run_cancelled" || payload.code === "cancelled") return "cancelled";
  return "failed";
}

function eventPayload(row: SourceRow): Record<string, unknown> {
  if (row.kind === "message") {
    const role = row.message_role === "assistant" ? "assistant" : "user";
    return {
      text: row.message_content ?? "",
      role,
      ...(role === "assistant" ? { model: row.model } : {}),
    };
  }

  const source = row.event_payload ?? {};
  if (row.kind === "modelStatus") {
    const type = row.mirror_type ?? "run_failed";
    const status = modelStatus(type, source);
    return {
      runId: row.run_id ?? text(source.runId),
      status,
      streaming: status === "running",
      model: row.model,
    };
  }
  if (row.kind === "tool_started" || row.kind === "tool_completed") {
    const completed = row.kind === "tool_completed";
    return {
      runId: row.run_id ?? text(source.runId),
      callId: text(source.callId),
      name: text(source.name),
      ...(completed
        ? { isError: typeof source.isError === "boolean" ? source.isError : null }
        : {}),
      status: completed ? "completed" : "running",
    };
  }
  if (row.kind === "artifact_created") {
    const size = Number(source.sizeBytes);
    return {
      runId: row.run_id ?? text(source.runId),
      artifactId: text(source.artifactId),
      name: text(source.name),
      sizeBytes: Number.isSafeInteger(size) && size >= 0 ? size : null,
      contentType: text(source.contentType),
    };
  }
  return {};
}

function toEvent(room: RoomContext, row: SourceRow, eventSequence: number): CollabWireEvent {
  return {
    schemaVersion: 1,
    eventId: row.source_id,
    sessionId: room.sessionId,
    eventSequence,
    senderParticipantId: row.sender_participant_id,
    kind: row.kind,
    createdAt: isoTime(row.occurred_at),
    payload: eventPayload(row),
    ...(row.sender_display_name === null
      ? {}
      : { senderDisplayName: row.sender_display_name }),
  };
}

export class CollabProjection implements CollabProjectionReader {
  constructor(private readonly db: Db) {}

  private async authorize(roomId: string, viewerUid: string): Promise<RoomContext> {
    const rows = (await this.db.$client.unsafe(
      `SELECT
         room.id AS room_id,
         room.session_id,
         room.lifecycle,
         owner.participant_id AS owner_participant_id,
         member.participant_id,
         member.role,
         member.status,
         member.display_name
       FROM collab_rooms room
       JOIN sessions session
         ON session.id = room.session_id AND session.deleted_at IS NULL
       JOIN collab_members member
         ON member.room_id = room.id
        AND member.user_id = $2
        AND member.status = 'active'
       JOIN users viewer ON viewer.uid = member.user_id
       LEFT JOIN account_deletions deletion
         ON deletion.uid = member.user_id
        AND deletion.state NOT IN ('active', 'cancelled')
       JOIN collab_members owner
         ON owner.room_id = room.id
        AND owner.role = 'owner'
        AND owner.status = 'active'
       WHERE room.id = $1 AND deletion.uid IS NULL
       LIMIT 1`,
      [roomId, viewerUid],
    )) as unknown as Array<Record<string, unknown>>;
    const row = rows[0];
    if (row === undefined) throw new CollabProjectionError("not_member");
    const lifecycle = String(row.lifecycle);
    if (lifecycle !== "active") throw new CollabProjectionError("session_closed");
    return {
      roomId: String(row.room_id),
      sessionId: String(row.session_id),
      lifecycle: "active",
      ownerParticipantId: String(row.owner_participant_id),
      member: memberDto(row),
    };
  }

  private async readRows(
    roomId: string,
    cursor: CanonicalCursor,
    limit: number,
  ): Promise<ProjectionRows> {
    const result = (await this.db.$client.unsafe(PROJECTION_SQL, [
      roomId,
      cursor.sequence,
      limit + 1,
      cursor.after?.occurredAt ?? null,
      cursor.after?.sortMs ?? null,
      cursor.after?.sortSub ?? null,
      cursor.after?.sourceId ?? null,
    ])) as unknown as Array<{
      head: number | string;
      prefix: string;
      next_prefix: string;
      has_more: boolean;
      rows: SourceRow[] | string;
    }>;
    const row = result[0];
    if (row === undefined) throw new Error("collaboration projection returned no head");
    return {
      head: Number(row.head),
      prefix: row.prefix,
      nextPrefix: row.next_prefix,
      hasMore: row.has_more,
      rows: typeof row.rows === "string" ? JSON.parse(row.rows) as SourceRow[] : row.rows,
    };
  }

  async page(input: CollabPageInput): Promise<CollabEventPage> {
    const room = await this.authorize(input.roomId, input.viewerUid);
    const cursor = decodeCursor(input.cursor);
    const limit = clampLimit(input.limit);
    const projected = await this.readRows(room.roomId, cursor, limit);
    if (
      cursor.sequence > projected.head ||
      cursor.prefix !== projected.prefix
    ) {
      // A source was inserted, deleted, or hidden inside the already-delivered
      // prefix. Position-only replay would silently renumber its successor.
      throw new CollabProjectionError("cursor_reset");
    }

    // Membership/lifecycle can change while the canonical union is read. Fence
    // the answer as well as the entry so a revoked waiter receives no tail.
    await this.authorize(input.roomId, input.viewerUid);

    const rows = projected.rows;
    const last = rows.at(-1);
    return {
      schemaVersion: 1,
      events: rows.map((row, index) =>
        toEvent(room, row, cursor.sequence + index + 1),
      ),
      nextCursor: last === undefined
        ? input.cursor ?? "v1:0"
        : encodeCursor(cursor.sequence + rows.length, projected.nextPrefix, last),
      hasMore: projected.hasMore,
    };
  }

  async state(input: CollabStateInput): Promise<CollabStateDto> {
    const room = await this.authorize(input.roomId, input.viewerUid);
    const projected = await this.readRows(room.roomId, initialCursor(), 1);
    const memberRows = (await this.db.$client.unsafe(
      `SELECT participant_id, role, status, display_name
       FROM collab_members
       WHERE room_id = $1 AND status = 'active'
       ORDER BY joined_at, participant_id`,
      [room.roomId],
    )) as unknown as Array<Record<string, unknown>>;
    const leaseRows = (await this.db.$client.unsafe(
      `SELECT holder_participant_id, run_id, started_at, heartbeat_at
       FROM collab_sender_leases
       WHERE room_id = $1 AND released_at IS NULL
       ORDER BY started_at DESC, id DESC
       LIMIT 1`,
      [room.roomId],
    )) as unknown as Array<Record<string, unknown>>;
    await this.authorize(input.roomId, input.viewerUid);

    const members = memberRows.map(memberDto);
    const lease = leaseRows[0];
    return {
      schemaVersion: 1,
      session: {
        schemaVersion: 1,
        sessionId: room.sessionId,
        ownerParticipantId: room.ownerParticipantId,
        lifecycle: room.lifecycle,
      },
      member: room.member,
      members,
      initialMembers: members.filter((member) => member.role === "owner"),
      replayThroughSequence: projected.head,
      cursor: "v1:0",
      turn: lease === undefined ? null : {
        holderParticipantId: String(lease.holder_participant_id),
        runId: String(lease.run_id),
        startedAt: isoTime(lease.started_at),
        heartbeatAt: isoTime(lease.heartbeat_at),
      },
    };
  }
}
