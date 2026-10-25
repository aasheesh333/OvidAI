import { createHash } from "node:crypto";

/**
 * Pure, deterministic deep-fork planning for one accepted published revision.
 *
 * No DB/storage/queue imports live here. A builder consumes revision-approved
 * canonical rows in bounded source pages and produces idempotent operations.
 * Publication admission and the recipient quota snapshot belong to job
 * creation; resume uses the fingerprint-pinned plan, never a silently changed
 * live revision. An executor must atomically persist each page's successful
 * operation receipts with checkpointAfterPage. Object replay must verify
 * target bytes/hash before treating an existing target as applied. No plan is
 * evidence that a DB/object copy, durable charge, or source deletion ran.
 */

export const DEEP_FORK_PLAN_VERSION = 1 as const;
export const DEFAULT_DEEP_FORK_PAGE_SIZE = 100;
export const MAX_DEEP_FORK_PAGE_SIZE = 500;

export type DeepForkPlanErrorCode =
  | "share_unavailable"
  | "invalid_input"
  | "invalid_published_revision"
  | "private_source_not_copyable"
  | "object_not_copyable"
  | "actual_bytes_required"
  | "storage_quota_exceeded"
  | "checkpoint_mismatch"
  | "invalid_checkpoint";

export class DeepForkPlanError extends Error {
  constructor(readonly code: DeepForkPlanErrorCode) {
    // Never echo source content, object keys, credentials, or recipient data.
    super(code);
    this.name = "DeepForkPlanError";
  }
}

export interface DeepForkPublishedRevision {
  shareId: string;
  revisionId: string;
  state: "published" | "draft" | "revoked" | "expired" | "purged";
  sessionId: string;
  /** Exact server-side visibility allowlists, not the bounded public preview. */
  messageIds: readonly string[];
  runIds: readonly string[];
  eventSeqs: readonly string[];
  artifactIds: readonly string[];
  attachmentIds: readonly string[];
}

export interface DeepForkSourceSession {
  id: string;
  title: string | null;
  mode?: string;
  createdAt: string;
  updatedAt?: string;
}

export interface DeepForkSourceMessage {
  id: string;
  sessionId: string;
  role: string;
  content: string;
  createdAt: string;
  reasoning?: string | null;
  clientMsgId?: string | null;
}

export interface DeepForkSourceRun {
  id: string;
  sessionId: string;
  promptMessageId: string;
  status: string;
  createdAt: string;
  startedAt?: string | null;
  finishedAt?: string | null;
}

export interface DeepForkSourceEvent {
  sessionId: string;
  seq: string;
  type: string;
  payload: Record<string, unknown>;
  ts: string;
}

export interface DeepForkSourceArtifact {
  id: string;
  sessionId: string;
  kind: string;
  status: string;
  r2Key: string;
  /** Actual registered bytes from workspace_objects.bytes. */
  bytes: number;
  sha256: string;
  contentType: string | null;
  meta?: Record<string, unknown> | null;
  createdAt: string;
}

export interface DeepForkSourceAttachment {
  id: string;
  sessionId: string;
  name: string;
  uploadStatus: string;
  r2Key: string;
  /** Declared size is display metadata only; it is never a quota input. */
  size: number;
  /** Actual storage-HEAD bytes. Ready + null is not copyable. */
  actualBytes: number | null;
  sha256?: string | null;
  contentType?: string | null;
  actualContentType?: string | null;
  contentTypeDeclared?: boolean;
  messageId: string | null;
  createdAt: string;
  finalizedAt?: string | null;
}

export type DeepForkSourceObject =
  | { kind: "artifact"; artifact: DeepForkSourceArtifact }
  | { kind: "attachment"; attachment: DeepForkSourceAttachment };

/** Legacy synchronous input; new callers can stream pages into the builder. */
export interface DeepForkSource {
  session: DeepForkSourceSession;
  messages: readonly DeepForkSourceMessage[];
  runs: readonly DeepForkSourceRun[];
  events: readonly DeepForkSourceEvent[];
  artifacts: readonly DeepForkSourceArtifact[];
  attachments: readonly DeepForkSourceAttachment[];
}

export interface DeepForkRecipientQuota {
  usedBytes: number;
  reservedBytes?: number;
  limitBytes: number;
}

export interface DeepForkPlanInput {
  jobId: string;
  recipientUserId: string;
  published: DeepForkPublishedRevision;
  source: DeepForkSource;
  quota: DeepForkRecipientQuota;
  pageSize?: number;
}

export interface DeepForkPlanBuilderInput {
  jobId: string;
  recipientUserId: string;
  published: DeepForkPublishedRevision;
  session: DeepForkSourceSession;
  quota: DeepForkRecipientQuota;
  pageSize?: number;
}

/**
 * Incremental plan construction. Each source stream is canonical and ordered:
 * messages by UUIDv7 id; runs by (createdAt,id); objects by
 * (createdAt,kind,id); events by numeric Redis-style seq. `complete` means the
 * source's terminal page, not merely the end of the currently supplied array.
 */
export interface DeepForkPlanBuilder {
  appendMessages(rows: readonly DeepForkSourceMessage[], complete: boolean): void;
  appendRuns(rows: readonly DeepForkSourceRun[], complete: boolean): void;
  appendObjects(rows: readonly DeepForkSourceObject[], complete: boolean): void;
  appendEvents(rows: readonly DeepForkSourceEvent[], complete: boolean): void;
  finish(): DeepForkPlan;
}

export interface DeepForkTargetSession {
  id: string;
  userId: string;
  title: string | null;
  mode: string;
  projectId: null;
  createdAt: string;
  updatedAt: string;
  archivedAt: null;
  pinnedAt: null;
  deletedAt: null;
}

export interface DeepForkTargetMessage {
  id: string;
  sessionId: string;
  role: "user" | "assistant";
  content: string;
  createdAt: string;
  /** Hidden provider reasoning and send/idempotency lineage never cross. */
  reasoning: null;
  clientMsgId: null;
}

export type DeepForkTerminalRunStatus = "completed" | "failed" | "cancelled";

export interface DeepForkTargetRun {
  id: string;
  sessionId: string;
  promptMessageId: string;
  status: DeepForkTerminalRunStatus;
  createdAt: string;
  startedAt: string | null;
  finishedAt: string | null;
  /** A historical terminal row is never queue-admissible or heartbeating. */
  attempts: 0;
  lastError: null;
  cancelRequested: false;
  lastActiveAt: null;
}

export interface DeepForkTargetArtifact {
  id: string;
  userId: string;
  sessionId: string;
  projectId: null;
  kind: "artifact";
  status: "active";
  r2Key: string;
  bytes: number;
  sha256: string;
  contentType: string;
  meta: { name: string };
  createdAt: string;
}

export interface DeepForkTargetAttachment {
  id: string;
  userId: string;
  sessionId: string;
  name: string;
  projectId: null;
  messageId: string | null;
  uploadStatus: "ready";
  r2Key: string;
  size: number;
  actualBytes: number;
  contentType: string;
  actualContentType: string | null;
  contentTypeDeclared: boolean;
  createdAt: string;
  finalizedAt: string | null;
}

interface DeepForkObjectCopyBase {
  sourceId: string;
  sourceKey: string;
  targetObjectId: string;
  targetKey: string;
  actualBytes: number;
  sha256: string | null;
}

export type DeepForkObjectCopy =
  | (DeepForkObjectCopyBase & {
      kind: "artifact";
      sha256: string;
      artifact: DeepForkTargetArtifact;
    })
  | (DeepForkObjectCopyBase & {
      kind: "attachment";
      attachment: DeepForkTargetAttachment;
    });

export interface DeepForkTargetEvent {
  sessionId: string;
  /** The new session has an independent seq namespace; source order is kept. */
  seq: string;
  type: string;
  payload: Record<string, unknown>;
  ts: string;
}

export interface DeepForkQuotaCharge {
  reservationId: string;
  ownerUserId: string;
  actorUserId: string;
  sessionId: string;
  /** One job-level charge derived from actual source bytes, never declared bytes. */
  actualBytes: number;
}

export interface DeepForkCounts {
  sessions: number;
  messages: number;
  runs: number;
  artifacts: number;
  attachments: number;
  objects: number;
  events: number;
}

interface DeepForkOperationBase {
  /** Stable successful-execution receipt key; retry means verify/upsert, never insert-twice. */
  key: string;
}

export type DeepForkOperation =
  | (DeepForkOperationBase & { kind: "create_session"; session: DeepForkTargetSession })
  | (DeepForkOperationBase & { kind: "reserve_quota"; charge: DeepForkQuotaCharge })
  | (DeepForkOperationBase & { kind: "copy_message"; message: DeepForkTargetMessage })
  | (DeepForkOperationBase & { kind: "copy_run"; run: DeepForkTargetRun })
  | (DeepForkOperationBase & { kind: "copy_object"; object: DeepForkObjectCopy })
  | (DeepForkOperationBase & { kind: "copy_event"; event: DeepForkTargetEvent })
  | (DeepForkOperationBase & { kind: "finalize_quota"; charge: DeepForkQuotaCharge })
  | (DeepForkOperationBase & {
      kind: "complete_fork";
      completion: {
        sessionId: string;
        expectedCounts: DeepForkCounts;
        actualBytes: number;
      };
    });

export interface DeepForkIdMap {
  session: { sourceId: string; targetId: string };
  messages: Readonly<Record<string, string>>;
  /** Terminal historical source runs only. Active source runs have no target ID. */
  runs: Readonly<Record<string, string>>;
  artifacts: Readonly<Record<string, string>>;
  attachments: Readonly<Record<string, string>>;
  /** Source immutable r2Key -> new storage object identity. */
  objects: Readonly<Record<string, string>>;
}

export interface DeepForkCheckpoint {
  version: typeof DEEP_FORK_PLAN_VERSION;
  planFingerprint: string;
  /** Exclusive operation offset; always a page boundary (or complete). */
  nextOperation: number;
}

export interface DeepForkPlan {
  version: typeof DEEP_FORK_PLAN_VERSION;
  planId: string;
  fingerprint: string;
  jobId: string;
  recipientUserId: string;
  shareId: string;
  revisionId: string;
  targetSessionId: string;
  quotaReservationId: string;
  requiredActualBytes: number;
  pageSize: number;
  pageCount: number;
  idMap: DeepForkIdMap;
  totals: DeepForkCounts;
  operations: readonly DeepForkOperation[];
  initialCheckpoint: DeepForkCheckpoint;
}

export interface DeepForkPage {
  index: number;
  startOperation: number;
  endOperation: number;
  /** Every key in this page, including already-applied operations. */
  operationKeys: readonly string[];
  /** Only operations not yet receipted as successfully applied. */
  operations: readonly DeepForkOperation[];
  /** Persist only with successful application of every operationKeys entry. */
  checkpointAfterPage: DeepForkCheckpoint;
}

export interface DeepForkProgress {
  copied: DeepForkCounts;
  total: DeepForkCounts;
  requiredActualBytes: number;
  chargedActualBytes: number;
  complete: boolean;
}

export interface DeepForkResumeInput {
  plan: DeepForkPlan;
  checkpoint?: DeepForkCheckpoint | null;
  /** Successful operation receipts; unknown keys and duplicates have no effect. */
  appliedOperationKeys?: readonly string[];
}

export interface DeepForkResume {
  checkpoint: DeepForkCheckpoint;
  page: DeepForkPage | null;
  progress: DeepForkProgress;
}

const REQUEST_ID_RE = /^[A-Za-z0-9_-]{1,128}$/;
const HEX_64_RE = /^[0-9a-f]{64}$/i;
const EVENT_SEQ_RE = /^(?:0|[1-9]\d*)-(?:0|[1-9]\d*)$/;
const MAX_UUID_ORDINAL = 0xffff_ffff;
const MAX_UUID_TIMESTAMP = 0xffff_ffff_ffff;

function fail(code: DeepForkPlanErrorCode): never {
  throw new DeepForkPlanError(code);
}

function hash(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function requiredString(value: unknown, code: DeepForkPlanErrorCode = "invalid_input"): string {
  if (typeof value !== "string" || value.length === 0 || value.length > 4096) fail(code);
  return value;
}

function isoTime(value: unknown): string {
  if (typeof value !== "string" || value.length === 0) fail("invalid_published_revision");
  const ms = new Date(value).getTime();
  if (!Number.isFinite(ms)) fail("invalid_published_revision");
  return new Date(ms).toISOString();
}

function optionalIsoTime(value: unknown): string | null {
  return value === null || value === undefined ? null : isoTime(value);
}

function byteCount(value: unknown, nullCode: DeepForkPlanErrorCode = "invalid_input"): number {
  if (value === null || value === undefined) fail(nullCode);
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    fail("invalid_input");
  }
  return value;
}

function contentType(value: unknown): string {
  return typeof value === "string" && value.length > 0 ? value : "application/octet-stream";
}

function displayName(value: unknown, fallback: string): string {
  return typeof value === "string" && value.length > 0 ? value : fallback;
}

function compareText(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

function compareDigits(a: string, b: string): number {
  const left = a.replace(/^0+(?=\d)/, "");
  const right = b.replace(/^0+(?=\d)/, "");
  return left.length === right.length ? compareText(left, right) : left.length - right.length;
}

function compareEventSeq(a: string, b: string): number {
  const [ams, asub] = a.split("-") as [string, string];
  const [bms, bsub] = b.split("-") as [string, string];
  return compareDigits(ams, bms) || compareDigits(asub, bsub);
}

function assertSourceSession(sessionId: string, expected: string): void {
  if (sessionId !== expected) fail("invalid_published_revision");
}

/** Deterministic UUIDv7-shaped ID; ordinal is the final keyset discriminator. */
function orderedUuid(namespace: string, kind: string, createdAt: string, ordinal: number): string {
  if (!Number.isSafeInteger(ordinal) || ordinal < 0 || ordinal > MAX_UUID_ORDINAL) {
    fail("invalid_input");
  }
  const sourceMs = new Date(createdAt).getTime();
  const timestamp = Math.max(0, Math.min(MAX_UUID_TIMESTAMP, Math.trunc(sourceMs)));
  const namespaceBits = BigInt(`0x${hash(`${namespace}\0${kind}`).slice(0, 16)}`);
  const upper42 = namespaceBits >> 22n;
  const payload74 = (upper42 << 32n) | BigInt(ordinal);
  const randA = payload74 >> 62n;
  const randB = payload74 & ((1n << 62n) - 1n);
  const raw =
    (BigInt(timestamp) << 80n) |
    (7n << 76n) |
    (randA << 64n) |
    (2n << 62n) |
    randB;
  const hex = raw.toString(16).padStart(32, "0");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function operationKey(namespace: string, kind: string, sourceId: string): string {
  return `df1_${hash(`${namespace}\0${kind}\0${sourceId}`).slice(0, 32)}`;
}

function payloadRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    fail("invalid_published_revision");
  }
  return value as Record<string, unknown>;
}

function requiredPayloadString(payload: Record<string, unknown>, key: string): string {
  const value = payload[key];
  if (typeof value !== "string" || value.length === 0) fail("invalid_published_revision");
  return value;
}

function optionalPayloadString(payload: Record<string, unknown>, key: string): string | null {
  const value = payload[key];
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") fail("invalid_published_revision");
  return value;
}

function zeroCounts(): DeepForkCounts {
  return { sessions: 0, messages: 0, runs: 0, artifacts: 0, attachments: 0, objects: 0, events: 0 };
}

function addOperation(counts: DeepForkCounts, operation: DeepForkOperation): void {
  if (operation.kind === "create_session") counts.sessions += 1;
  else if (operation.kind === "copy_message") counts.messages += 1;
  else if (operation.kind === "copy_run") counts.runs += 1;
  else if (operation.kind === "copy_event") counts.events += 1;
  else if (operation.kind === "copy_object") {
    counts.objects += 1;
    if (operation.object.kind === "artifact") counts.artifacts += 1;
    else counts.attachments += 1;
  }
}

interface PlannedMessage {
  sourceId: string;
  target: DeepForkTargetMessage;
}

interface PlannedRun {
  sourceId: string;
  target: DeepForkTargetRun;
}

interface PlannedEvent {
  sourceSeq: string;
  target: DeepForkTargetEvent;
}

type BuilderStage = "messages" | "runs" | "objects" | "events" | "complete";

class IncrementalDeepForkPlanBuilder implements DeepForkPlanBuilder {
  private readonly input: DeepForkPlanBuilderInput;
  private readonly namespace: string;
  private readonly sourceSessionId: string;
  private readonly sessionCreatedAt: string;
  private readonly targetSessionId: string;
  private readonly quotaReservationId: string;
  private readonly pageSize: number;
  private readonly usedBytes: number;
  private readonly reservedBytes: number;
  private readonly limitBytes: number;
  private readonly messageAllow: ReadonlySet<string>;
  private readonly runAllow: ReadonlySet<string>;
  private readonly eventAllow: ReadonlySet<string>;
  private readonly artifactAllow: ReadonlySet<string>;
  private readonly attachmentAllow: ReadonlySet<string>;

  private stage: BuilderStage = "messages";
  private result: DeepForkPlan | null = null;
  private latestVisibleTime: string;
  private requiredBytesBig = 0n;
  private requiredActualBytes = 0;

  private readonly seenMessages = new Set<string>();
  private readonly seenRuns = new Set<string>();
  private readonly seenEvents = new Set<string>();
  private readonly seenArtifacts = new Set<string>();
  private readonly seenAttachments = new Set<string>();
  private readonly sourceKeys = new Set<string>();

  private readonly messages: PlannedMessage[] = [];
  private readonly messageBySource = new Map<string, DeepForkTargetMessage>();
  private readonly messageIds: Record<string, string> = {};
  private lastMessageId: string | null = null;
  private messageOrdinal = 0;

  private readonly runs: PlannedRun[] = [];
  private readonly sourceRuns = new Map<string, "active" | "terminal">();
  private readonly runIds: Record<string, string> = {};
  private lastRunKey: string | null = null;
  private terminalRunOrdinal = 0;

  private readonly objectCopies: DeepForkObjectCopy[] = [];
  private readonly artifactCopies = new Map<string, DeepForkObjectCopy & { kind: "artifact" }>();
  private readonly artifactIds: Record<string, string> = {};
  private readonly attachmentIds: Record<string, string> = {};
  private readonly objectIds: Record<string, string> = {};
  private lastObjectKey: string | null = null;
  private artifactOrdinal = 0;
  private attachmentOrdinal = 0;
  private objectOrdinal = 0;

  private readonly events: PlannedEvent[] = [];
  private lastEventSeq: string | null = null;

  constructor(input: DeepForkPlanBuilderInput) {
    if (!REQUEST_ID_RE.test(input.jobId) || !REQUEST_ID_RE.test(input.recipientUserId)) {
      fail("invalid_input");
    }
    requiredString(input.published.shareId);
    requiredString(input.published.revisionId);
    if (input.published.state !== "published") fail("share_unavailable");
    if (input.published.sessionId !== input.session.id) fail("invalid_published_revision");
    const pageSize = input.pageSize ?? DEFAULT_DEEP_FORK_PAGE_SIZE;
    if (!Number.isSafeInteger(pageSize) || pageSize < 1 || pageSize > MAX_DEEP_FORK_PAGE_SIZE) {
      fail("invalid_input");
    }

    this.input = input;
    this.pageSize = pageSize;
    this.usedBytes = byteCount(input.quota.usedBytes);
    this.reservedBytes = byteCount(input.quota.reservedBytes ?? 0);
    this.limitBytes = byteCount(input.quota.limitBytes);
    this.messageAllow = new Set(input.published.messageIds);
    this.runAllow = new Set(input.published.runIds);
    this.eventAllow = new Set(input.published.eventSeqs);
    this.artifactAllow = new Set(input.published.artifactIds);
    this.attachmentAllow = new Set(input.published.attachmentIds);
    this.namespace = hash([
      "ovid-deep-fork-v1",
      input.jobId,
      input.recipientUserId,
      input.published.shareId,
      input.published.revisionId,
    ].join("\0"));
    this.sourceSessionId = requiredString(input.session.id, "invalid_published_revision");
    this.sessionCreatedAt = isoTime(input.session.createdAt);
    this.latestVisibleTime = this.sessionCreatedAt;
    this.targetSessionId = orderedUuid(this.namespace, "session", this.sessionCreatedAt, 0);
    this.quotaReservationId = `dfq1_${this.namespace.slice(0, 32)}`;
  }

  private assertStage(expected: BuilderStage): void {
    if (this.stage !== expected || this.result !== null) fail("invalid_published_revision");
  }

  private assertExposed(allow: ReadonlySet<string>, id: string): void {
    if (!allow.has(id)) fail("invalid_published_revision");
  }

  private assertNew(seen: Set<string>, id: string): void {
    if (seen.has(id)) fail("invalid_published_revision");
    seen.add(id);
  }

  private assertComplete(allow: ReadonlySet<string>, seen: ReadonlySet<string>): void {
    if (allow.size !== seen.size) fail("invalid_published_revision");
    for (const id of allow) if (!seen.has(id)) fail("invalid_published_revision");
  }

  private updateLatest(value: string): void {
    if (compareText(value, this.latestVisibleTime) > 0) this.latestVisibleTime = value;
  }

  appendMessages(rows: readonly DeepForkSourceMessage[], complete: boolean): void {
    this.assertStage("messages");
    for (const source of rows) {
      const sourceId = requiredString(source.id, "invalid_published_revision");
      this.assertExposed(this.messageAllow, sourceId);
      this.assertNew(this.seenMessages, sourceId);
      if (this.lastMessageId !== null && compareText(this.lastMessageId, sourceId) >= 0) {
        // Canonical messages.page/upTo use UUIDv7 ID keysets, never createdAt.
        fail("invalid_published_revision");
      }
      assertSourceSession(source.sessionId, this.sourceSessionId);
      if (source.role !== "user" && source.role !== "assistant") fail("private_source_not_copyable");
      if (typeof source.content !== "string") fail("invalid_published_revision");
      const createdAt = isoTime(source.createdAt);
      // A single logical ID timestamp is intentional: imported display times
      // may decrease, while target keyset IDs must increase in source-ID order.
      const id = orderedUuid(this.namespace, "message", this.sessionCreatedAt, this.messageOrdinal);
      this.messageOrdinal += 1;
      const target: DeepForkTargetMessage = {
        id,
        sessionId: this.targetSessionId,
        role: source.role,
        content: source.content,
        createdAt,
        reasoning: null,
        clientMsgId: null,
      };
      this.messages.push({ sourceId, target });
      this.messageBySource.set(sourceId, target);
      this.messageIds[sourceId] = id;
      this.lastMessageId = sourceId;
      this.updateLatest(createdAt);
    }
    if (complete) {
      this.assertComplete(this.messageAllow, this.seenMessages);
      this.stage = "runs";
    }
  }

  appendRuns(rows: readonly DeepForkSourceRun[], complete: boolean): void {
    this.assertStage("runs");
    for (const source of rows) {
      const sourceId = requiredString(source.id, "invalid_published_revision");
      this.assertExposed(this.runAllow, sourceId);
      this.assertNew(this.seenRuns, sourceId);
      const createdAt = isoTime(source.createdAt);
      const key = `${createdAt}\0${sourceId}`;
      if (this.lastRunKey !== null && compareText(this.lastRunKey, key) >= 0) {
        fail("invalid_published_revision");
      }
      assertSourceSession(source.sessionId, this.sourceSessionId);
      requiredString(source.promptMessageId, "invalid_published_revision");
      const active = source.status === "queued" || source.status === "running";
      const terminal = source.status === "completed" || source.status === "failed" ||
        source.status === "cancelled";
      if (!active && !terminal) fail("invalid_published_revision");

      if (active) {
        // Revision-approved visible history may reference this run, but there
        // is no recipient run row/ID, terminal fabrication, lease, or outbox.
        this.sourceRuns.set(sourceId, "active");
      } else {
        const promptMessageId = this.messageIds[source.promptMessageId];
        if (promptMessageId === undefined) fail("invalid_published_revision");
        const id = orderedUuid(this.namespace, "run", createdAt, this.terminalRunOrdinal);
        this.terminalRunOrdinal += 1;
        const target: DeepForkTargetRun = {
          id,
          sessionId: this.targetSessionId,
          promptMessageId,
          status: source.status as DeepForkTerminalRunStatus,
          createdAt,
          startedAt: optionalIsoTime(source.startedAt),
          finishedAt: optionalIsoTime(source.finishedAt),
          attempts: 0,
          lastError: null,
          cancelRequested: false,
          lastActiveAt: null,
        };
        this.runs.push({ sourceId, target });
        this.runIds[sourceId] = id;
        this.sourceRuns.set(sourceId, "terminal");
      }
      this.lastRunKey = key;
      this.updateLatest(createdAt);
    }
    if (complete) {
      this.assertComplete(this.runAllow, this.seenRuns);
      this.stage = "objects";
    }
  }

  appendObjects(rows: readonly DeepForkSourceObject[], complete: boolean): void {
    this.assertStage("objects");
    for (const entry of rows) {
      const kind = entry.kind;
      const source: DeepForkSourceArtifact | DeepForkSourceAttachment = entry.kind === "artifact"
        ? entry.artifact
        : entry.attachment;
      const sourceId = requiredString(source.id, "invalid_published_revision");
      const allow = kind === "artifact" ? this.artifactAllow : this.attachmentAllow;
      const seen = kind === "artifact" ? this.seenArtifacts : this.seenAttachments;
      this.assertExposed(allow, sourceId);
      this.assertNew(seen, sourceId);
      const createdAt = isoTime(source.createdAt);
      const key = `${createdAt}\0${kind}:${sourceId}`;
      if (this.lastObjectKey !== null && compareText(this.lastObjectKey, key) >= 0) {
        fail("invalid_published_revision");
      }
      assertSourceSession(source.sessionId, this.sourceSessionId);
      const sourceKey = requiredString(source.r2Key, "invalid_published_revision");
      if (this.sourceKeys.has(sourceKey)) fail("invalid_published_revision");
      const targetObjectId = orderedUuid(this.namespace, "object", createdAt, this.objectOrdinal);
      this.objectOrdinal += 1;
      const targetKey = `users/${this.input.recipientUserId}/sessions/${this.targetSessionId}/${kind === "artifact" ? "artifacts" : "uploads"}/${targetObjectId}`;

      if (entry.kind === "artifact") {
        const artifactSource = entry.artifact;
        if (artifactSource.kind !== "artifact" || artifactSource.status !== "active") {
          fail("object_not_copyable");
        }
        const actualBytes = byteCount(artifactSource.bytes, "actual_bytes_required");
        const sha256 = requiredString(artifactSource.sha256, "invalid_published_revision").toLowerCase();
        if (!HEX_64_RE.test(sha256)) fail("invalid_published_revision");
        const id = orderedUuid(this.namespace, "artifact", createdAt, this.artifactOrdinal);
        this.artifactOrdinal += 1;
        const artifact: DeepForkTargetArtifact = {
          id,
          userId: this.input.recipientUserId,
          sessionId: this.targetSessionId,
          projectId: null,
          kind: "artifact",
          status: "active",
          r2Key: targetKey,
          bytes: actualBytes,
          sha256,
          contentType: contentType(artifactSource.contentType),
          meta: { name: displayName(artifactSource.meta?.name, "artifact") },
          createdAt,
        };
        const copy: DeepForkObjectCopy & { kind: "artifact" } = {
          kind: "artifact",
          sourceId,
          sourceKey,
          targetObjectId,
          targetKey,
          actualBytes,
          sha256,
          artifact,
        };
        this.objectCopies.push(copy);
        this.artifactCopies.set(sourceId, copy);
        this.artifactIds[sourceId] = id;
        this.requiredBytesBig += BigInt(actualBytes);
      } else {
        const attachmentSource = entry.attachment;
        if (attachmentSource.uploadStatus !== "ready") fail("object_not_copyable");
        const actualBytes = byteCount(attachmentSource.actualBytes, "actual_bytes_required");
        const sourceHash = attachmentSource.sha256 === null || attachmentSource.sha256 === undefined
          ? null
          : requiredString(attachmentSource.sha256, "invalid_published_revision").toLowerCase();
        if (sourceHash !== null && !HEX_64_RE.test(sourceHash)) fail("invalid_published_revision");
        const messageId = attachmentSource.messageId === null
          ? null
          : this.messageIds[attachmentSource.messageId];
        if (attachmentSource.messageId !== null && messageId === undefined) {
          fail("invalid_published_revision");
        }
        const id = orderedUuid(this.namespace, "attachment", createdAt, this.attachmentOrdinal);
        this.attachmentOrdinal += 1;
        const attachment: DeepForkTargetAttachment = {
          id,
          userId: this.input.recipientUserId,
          sessionId: this.targetSessionId,
          name: displayName(attachmentSource.name, "attachment"),
          projectId: null,
          messageId: messageId ?? null,
          uploadStatus: "ready",
          r2Key: targetKey,
          size: actualBytes,
          actualBytes,
          contentType: contentType(attachmentSource.contentType),
          actualContentType: typeof attachmentSource.actualContentType === "string"
            ? attachmentSource.actualContentType
            : null,
          contentTypeDeclared: attachmentSource.contentTypeDeclared ?? false,
          createdAt,
          finalizedAt: optionalIsoTime(attachmentSource.finalizedAt),
        };
        this.objectCopies.push({
          kind: "attachment",
          sourceId,
          sourceKey,
          targetObjectId,
          targetKey,
          actualBytes,
          sha256: sourceHash,
          attachment,
        });
        this.attachmentIds[sourceId] = id;
        this.requiredBytesBig += BigInt(actualBytes);
      }
      this.objectIds[sourceKey] = targetObjectId;
      this.sourceKeys.add(sourceKey);
      this.lastObjectKey = key;
      this.updateLatest(createdAt);
    }
    if (complete) {
      this.assertComplete(this.artifactAllow, this.seenArtifacts);
      this.assertComplete(this.attachmentAllow, this.seenAttachments);
      if (BigInt(this.usedBytes) + BigInt(this.reservedBytes) + this.requiredBytesBig >
          BigInt(this.limitBytes)) {
        fail("storage_quota_exceeded");
      }
      if (this.requiredBytesBig > BigInt(Number.MAX_SAFE_INTEGER)) fail("invalid_input");
      this.requiredActualBytes = Number(this.requiredBytesBig);
      this.stage = "events";
    }
  }

  /** Resolve only terminal target links; active links become honestly unknown. */
  private eventRunId(payload: Record<string, unknown>, required: boolean): string | null {
    const sourceId = payload.runId;
    if (sourceId === undefined || sourceId === null) {
      if (required) fail("invalid_published_revision");
      return null;
    }
    if (typeof sourceId !== "string") fail("invalid_published_revision");
    const targetId = this.runIds[sourceId];
    if (targetId !== undefined) return targetId;
    if (this.sourceRuns.get(sourceId) === "active") return null;
    // Unknown, unpublished, or inconsistent terminal links never get guessed.
    fail("invalid_published_revision");
  }

  private eventPayload(source: DeepForkSourceEvent): Record<string, unknown> {
    const payload = payloadRecord(source.payload);
    if (source.type === "run_started" || source.type === "run_completed") {
      const runId = this.eventRunId(payload, true);
      const model = optionalPayloadString(payload, "model");
      return {
        ...(runId === null ? {} : { runId }),
        ...(model === null ? {} : { model }),
      };
    }
    if (source.type === "run_failed") {
      // Agent loop, gateway queued-cancel, and attachment producers may omit
      // runId. Preserve code:"cancelled" verbatim; never rewrite it as failed.
      // Provider/infra messages are not needed for modelStatus presentation.
      const runId = this.eventRunId(payload, false);
      const code = requiredPayloadString(payload, "code");
      const model = optionalPayloadString(payload, "model");
      return {
        ...(runId === null ? {} : { runId }),
        code,
        ...(model === null ? {} : { model }),
      };
    }
    if (source.type === "run_cancelled") {
      const runId = this.eventRunId(payload, false);
      const code = optionalPayloadString(payload, "code");
      const model = optionalPayloadString(payload, "model");
      return {
        ...(runId === null ? {} : { runId }),
        ...(code === null ? {} : { code }),
        ...(model === null ? {} : { model }),
      };
    }
    if (source.type === "run_started_retry") {
      const runId = this.eventRunId(payload, false);
      const model = optionalPayloadString(payload, "model");
      return {
        ...(runId === null ? {} : { runId }),
        ...(model === null ? {} : { model }),
      };
    }
    if (source.type === "tool_started" || source.type === "tool_completed") {
      const runId = this.eventRunId(payload, false);
      const callId = requiredPayloadString(payload, "callId");
      const name = requiredPayloadString(payload, "name");
      const isError = source.type === "tool_completed" && typeof payload.isError === "boolean"
        ? payload.isError
        : null;
      return {
        ...(runId === null ? {} : { runId }),
        callId,
        name,
        ...(isError === null ? {} : { isError }),
      };
    }
    if (source.type === "message_completed") {
      const sourceMessageId = requiredPayloadString(payload, "messageId");
      const target = this.messageBySource.get(sourceMessageId);
      if (target === undefined) fail("invalid_published_revision");
      const runId = this.eventRunId(payload, false);
      return {
        messageId: target.id,
        ...(runId === null ? {} : { runId }),
        role: target.role,
        content: target.content,
      };
    }
    if (source.type === "message_segment") {
      const runId = this.eventRunId(payload, true);
      if (typeof payload.content !== "string") fail("invalid_published_revision");
      return {
        ...(runId === null ? {} : { runId }),
        content: payload.content,
      };
    }
    if (source.type === "artifact_created") {
      const sourceArtifactId = requiredPayloadString(payload, "artifactId");
      const copy = this.artifactCopies.get(sourceArtifactId);
      if (copy === undefined) fail("invalid_published_revision");
      const runId = this.eventRunId(payload, false);
      return {
        artifactId: copy.artifact.id,
        sessionId: this.targetSessionId,
        ...(runId === null ? {} : { runId }),
        name: copy.artifact.meta.name,
        sizeBytes: copy.artifact.bytes,
        contentType: copy.artifact.contentType,
      };
    }
    // Streaming deltas, private scratch, approvals, subagents, workspace state,
    // compaction, credentials and unknown future envelopes never cross by default.
    fail("private_source_not_copyable");
  }

  appendEvents(rows: readonly DeepForkSourceEvent[], complete: boolean): void {
    this.assertStage("events");
    for (const source of rows) {
      const sourceSeq = requiredString(source.seq, "invalid_published_revision");
      this.assertExposed(this.eventAllow, sourceSeq);
      this.assertNew(this.seenEvents, sourceSeq);
      if (!EVENT_SEQ_RE.test(sourceSeq)) fail("invalid_published_revision");
      if (this.lastEventSeq !== null && compareEventSeq(this.lastEventSeq, sourceSeq) >= 0) {
        fail("invalid_published_revision");
      }
      assertSourceSession(source.sessionId, this.sourceSessionId);
      const ts = isoTime(source.ts);
      const target: DeepForkTargetEvent = {
        sessionId: this.targetSessionId,
        seq: sourceSeq,
        type: source.type,
        payload: this.eventPayload(source),
        ts,
      };
      this.events.push({ sourceSeq, target });
      this.lastEventSeq = sourceSeq;
      this.updateLatest(ts);
    }
    if (complete) {
      this.assertComplete(this.eventAllow, this.seenEvents);
      this.stage = "complete";
    }
  }

  finish(): DeepForkPlan {
    if (this.stage !== "complete") fail("invalid_published_revision");
    if (this.result !== null) return this.result;
    const idMap: DeepForkIdMap = {
      session: { sourceId: this.sourceSessionId, targetId: this.targetSessionId },
      messages: this.messageIds,
      runs: this.runIds,
      artifacts: this.artifactIds,
      attachments: this.attachmentIds,
      objects: this.objectIds,
    };
    const totals: DeepForkCounts = {
      sessions: 1,
      messages: this.messages.length,
      runs: this.runs.length,
      artifacts: this.seenArtifacts.size,
      attachments: this.seenAttachments.size,
      objects: this.objectCopies.length,
      events: this.events.length,
    };
    const targetSession: DeepForkTargetSession = {
      id: this.targetSessionId,
      userId: this.input.recipientUserId,
      title: this.input.session.title,
      mode: this.input.session.mode ?? "auto",
      projectId: null,
      createdAt: this.sessionCreatedAt,
      updatedAt: this.latestVisibleTime,
      archivedAt: null,
      pinnedAt: null,
      deletedAt: null,
    };
    const charge: DeepForkQuotaCharge = {
      reservationId: this.quotaReservationId,
      ownerUserId: this.input.recipientUserId,
      actorUserId: this.input.recipientUserId,
      sessionId: this.targetSessionId,
      actualBytes: this.requiredActualBytes,
    };
    const operations: DeepForkOperation[] = [
      {
        key: operationKey(this.namespace, "create_session", this.sourceSessionId),
        kind: "create_session",
        session: targetSession,
      },
      {
        key: operationKey(this.namespace, "reserve_quota", "quota"),
        kind: "reserve_quota",
        charge,
      },
      ...this.messages.map((row): DeepForkOperation => ({
        key: operationKey(this.namespace, "copy_message", row.sourceId),
        kind: "copy_message",
        message: row.target,
      })),
      ...this.runs.map((row): DeepForkOperation => ({
        key: operationKey(this.namespace, "copy_run", row.sourceId),
        kind: "copy_run",
        run: row.target,
      })),
      ...this.objectCopies.map((object): DeepForkOperation => ({
        key: operationKey(this.namespace, "copy_object", `${object.kind}:${object.sourceId}`),
        kind: "copy_object",
        object,
      })),
      ...this.events.map((row): DeepForkOperation => ({
        key: operationKey(this.namespace, "copy_event", row.sourceSeq),
        kind: "copy_event",
        event: row.target,
      })),
      {
        key: operationKey(this.namespace, "finalize_quota", "quota"),
        kind: "finalize_quota",
        charge,
      },
      {
        key: operationKey(this.namespace, "complete_fork", "complete"),
        kind: "complete_fork",
        completion: {
          sessionId: this.targetSessionId,
          expectedCounts: { ...totals },
          actualBytes: this.requiredActualBytes,
        },
      },
    ];
    const fingerprint = hash(JSON.stringify({
      version: DEEP_FORK_PLAN_VERSION,
      namespace: this.namespace,
      sourceSessionId: this.sourceSessionId,
      pageSize: this.pageSize,
      requiredActualBytes: this.requiredActualBytes,
      idMap,
      operations,
    }));
    this.result = {
      version: DEEP_FORK_PLAN_VERSION,
      planId: `dfp1_${fingerprint.slice(0, 32)}`,
      fingerprint,
      jobId: this.input.jobId,
      recipientUserId: this.input.recipientUserId,
      shareId: this.input.published.shareId,
      revisionId: this.input.published.revisionId,
      targetSessionId: this.targetSessionId,
      quotaReservationId: this.quotaReservationId,
      requiredActualBytes: this.requiredActualBytes,
      pageSize: this.pageSize,
      pageCount: Math.ceil(operations.length / this.pageSize),
      idMap,
      totals,
      operations,
      initialCheckpoint: {
        version: DEEP_FORK_PLAN_VERSION,
        planFingerprint: fingerprint,
        nextOperation: 0,
      },
    };
    return this.result;
  }
}

export function createDeepForkPlanBuilder(input: DeepForkPlanBuilderInput): DeepForkPlanBuilder {
  return new IncrementalDeepForkPlanBuilder(input);
}

function exposed<T>(rows: readonly T[], allow: ReadonlySet<string>, id: (row: T) => string): T[] {
  return rows.filter((row) => allow.has(id(row)));
}

/** Compatibility wrapper; the source-page path does not require these arrays. */
export function createDeepForkPlan(input: DeepForkPlanInput): DeepForkPlan {
  const builder = createDeepForkPlanBuilder({
    jobId: input.jobId,
    recipientUserId: input.recipientUserId,
    published: input.published,
    session: input.source.session,
    quota: input.quota,
    ...(input.pageSize === undefined ? {} : { pageSize: input.pageSize }),
  });
  const messageAllow = new Set(input.published.messageIds);
  const runAllow = new Set(input.published.runIds);
  const eventAllow = new Set(input.published.eventSeqs);
  const artifactAllow = new Set(input.published.artifactIds);
  const attachmentAllow = new Set(input.published.attachmentIds);
  const messages = exposed(input.source.messages, messageAllow, (row) => row.id)
    .sort((a, b) => compareText(a.id, b.id));
  const runs = exposed(input.source.runs, runAllow, (row) => row.id)
    .sort((a, b) => compareText(`${isoTime(a.createdAt)}\0${a.id}`, `${isoTime(b.createdAt)}\0${b.id}`));
  const objects: DeepForkSourceObject[] = [
    ...exposed(input.source.artifacts, artifactAllow, (row) => row.id)
      .map((artifact): DeepForkSourceObject => ({ kind: "artifact", artifact })),
    ...exposed(input.source.attachments, attachmentAllow, (row) => row.id)
      .map((attachment): DeepForkSourceObject => ({ kind: "attachment", attachment })),
  ].sort((a, b) => {
    const aRow = a.kind === "artifact" ? a.artifact : a.attachment;
    const bRow = b.kind === "artifact" ? b.artifact : b.attachment;
    return compareText(
      `${isoTime(aRow.createdAt)}\0${a.kind}:${aRow.id}`,
      `${isoTime(bRow.createdAt)}\0${b.kind}:${bRow.id}`,
    );
  });
  const events = exposed(input.source.events, eventAllow, (row) => row.seq)
    .sort((a, b) => compareEventSeq(a.seq, b.seq));
  builder.appendMessages(messages, true);
  builder.appendRuns(runs, true);
  builder.appendObjects(objects, true);
  builder.appendEvents(events, true);
  return builder.finish();
}

function checkedCheckpoint(plan: DeepForkPlan, checkpoint: DeepForkCheckpoint): DeepForkCheckpoint {
  if (checkpoint.planFingerprint !== plan.fingerprint) fail("checkpoint_mismatch");
  const offset = checkpoint.nextOperation;
  if (
    checkpoint.version !== DEEP_FORK_PLAN_VERSION ||
    !Number.isSafeInteger(offset) ||
    offset < 0 ||
    offset > plan.operations.length ||
    (offset !== plan.operations.length && offset % plan.pageSize !== 0)
  ) {
    fail("invalid_checkpoint");
  }
  return {
    version: DEEP_FORK_PLAN_VERSION,
    planFingerprint: plan.fingerprint,
    nextOperation: offset,
  };
}

function progressAt(plan: DeepForkPlan, offset: number, complete: boolean): DeepForkProgress {
  const copied = zeroCounts();
  let chargedActualBytes = 0;
  for (let index = 0; index < offset; index += 1) {
    const operation = plan.operations[index]!;
    addOperation(copied, operation);
    if (operation.kind === "finalize_quota") chargedActualBytes = operation.charge.actualBytes;
  }
  return {
    copied,
    total: { ...plan.totals },
    requiredActualBytes: plan.requiredActualBytes,
    chargedActualBytes,
    complete,
  };
}

export function resumeDeepForkPlan(input: DeepForkResumeInput): DeepForkResume {
  const plan = input.plan;
  if (plan.version !== DEEP_FORK_PLAN_VERSION) fail("invalid_input");
  let offset = checkedCheckpoint(plan, input.checkpoint ?? plan.initialCheckpoint).nextOperation;
  const applied = new Set(input.appliedOperationKeys ?? []);

  // A crash after COMMIT but before checkpoint persistence is repaired from
  // successful receipts: skip every fully applied page, never just one row.
  while (offset < plan.operations.length) {
    const end = Math.min(offset + plan.pageSize, plan.operations.length);
    let complete = true;
    for (let index = offset; index < end; index += 1) {
      if (!applied.has(plan.operations[index]!.key)) {
        complete = false;
        break;
      }
    }
    if (!complete) break;
    offset = end;
  }

  const checkpoint: DeepForkCheckpoint = {
    version: DEEP_FORK_PLAN_VERSION,
    planFingerprint: plan.fingerprint,
    nextOperation: offset,
  };
  if (offset === plan.operations.length) {
    return { checkpoint, page: null, progress: progressAt(plan, offset, true) };
  }

  const end = Math.min(offset + plan.pageSize, plan.operations.length);
  const pageOperations = plan.operations.slice(offset, end);
  // Progress may include a partial current page, but only its contiguous
  // successful prefix. Merely planned or out-of-order future work is not copied.
  let progressOffset = offset;
  while (progressOffset < plan.operations.length && applied.has(plan.operations[progressOffset]!.key)) {
    progressOffset += 1;
  }
  return {
    checkpoint,
    page: {
      index: offset / plan.pageSize,
      startOperation: offset,
      endOperation: end,
      operationKeys: pageOperations.map((operation) => operation.key),
      operations: pageOperations.filter((operation) => !applied.has(operation.key)),
      checkpointAfterPage: {
        version: DEEP_FORK_PLAN_VERSION,
        planFingerprint: plan.fingerprint,
        nextOperation: end,
      },
    },
    progress: progressAt(plan, progressOffset, false),
  };
}
