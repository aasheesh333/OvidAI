/**
 * Pure collaboration moderation policy.
 *
 * Callers must supply fresh server lookups for membership, target access,
 * current state, IDs, and time. This module performs no I/O and emits desired
 * mutations only; durable stores must apply those mutations and their fences
 * atomically. Target-access objects are proofs derived from the canonical room,
 * never client-provided target content.
 */

export const COLLAB_REPORT_DAILY_LIMIT = 50;
export const COLLAB_REPORT_MAX_DETAILS = 1000;
export const COLLAB_REPORT_MAX_EXCERPT = 4000;

export const COLLAB_MODERATION_REASONS = [
  "sexual",
  "child_safety",
  "hate",
  "violence",
  "self_harm",
  "illegal",
  "misleading",
  "privacy",
  "spam",
  "other",
] as const;

export type CollabModerationReason = (typeof COLLAB_MODERATION_REASONS)[number];
export type CollabReportKind = "collab_message" | "collab_participant";
export type CollabModeratorAction =
  | "dismiss"
  | "suppress_message"
  | "remove_participant"
  | "suppress_room";

export type CollabModerationErrorCode =
  | "invalid_request"
  | "not_member"
  | "session_closed"
  | "target_not_found"
  | "member_not_found"
  | "owner_not_removable"
  | "request_already_used"
  | "report_limit_reached"
  | "moderator_required"
  | "invalid_transition";

export class CollabModerationError extends Error {
  constructor(readonly code: CollabModerationErrorCode) {
    super(code);
    this.name = "CollabModerationError";
  }
}

export interface CollabReportRequest {
  schemaVersion: 1;
  requestId: string;
  kind: CollabReportKind;
  targetId: string;
  reason: CollabModerationReason;
  details: string;
}

export interface CollabModeratorActionRequest {
  schemaVersion: 1;
  requestId: string;
  action: CollabModeratorAction;
  reason: CollabModerationReason;
}

/** Mirrors the server-derived authorization/generation membership model. */
export interface CollabMemberAuthority {
  uid: string;
  roomId: string;
  participantId: string;
  ownerUserId: string;
  role: "owner" | "participant";
  status: "active" | "left" | "revoked";
  lifecycle: "active" | "closing" | "closed";
  roomGeneration: number;
  membershipGeneration: number;
}

export interface CollabMessageTargetAccess {
  kind: "collab_message";
  roomId: string;
  targetId: string;
  participantId: string;
  /** Canonical message text, visible to the authorized reporter. */
  text: string;
}

export interface CollabParticipantTargetAccess {
  kind: "collab_participant";
  roomId: string;
  targetId: string;
  role: "owner" | "participant";
  status: "active" | "left" | "revoked";
}

export type CollabTargetAccess =
  | CollabMessageTargetAccess
  | CollabParticipantTargetAccess;

export interface CollabReportRecord {
  reportId: string;
  requestId: string;
  reporterUid: string;
  roomId: string;
  kind: CollabReportKind;
  targetId: string;
  reason: CollabModerationReason;
  details: string;
  excerpt: string;
  createdAt: string;
  status: "open" | "dismissed" | "actioned";
}

export type CollabModerationReportTarget = Pick<
  CollabReportRecord,
  "reportId" | "roomId" | "kind" | "targetId" | "status"
>;

/** A separately verified internal grant, not a collab/Firebase membership role. */
export interface CollabModeratorAuthority {
  uid: string;
  permission: string;
  active: boolean;
}

export interface CollabAuditServerContext {
  auditId: string;
  now: Date;
}

export interface CollabReportServerContext extends CollabAuditServerContext {
  reportId: string;
}

export type CollabModerationAuditAction =
  | "report"
  | "block_participant"
  | "unblock_participant"
  | "remove_participant"
  | "remove_message"
  | "dismiss_report"
  | "suppress_message"
  | "suppress_room";

export type CollabModerationAuditOutcome =
  | "applied"
  | "replayed"
  | "unchanged"
  | "denied";

export interface CollabModerationAuditTarget {
  roomId: string;
  kind: "message" | "participant" | "room";
  id: string;
}

/** Closed, secret-free value suitable for an append-only privileged audit. */
export interface CollabModerationAuditRecord {
  readonly auditId: string;
  readonly actorUid: string;
  readonly actorAuthority: "member" | "owner" | "moderator";
  readonly target: Readonly<CollabModerationAuditTarget>;
  readonly action: CollabModerationAuditAction;
  readonly reason: CollabModerationReason;
  readonly createdAt: string;
  readonly outcome: CollabModerationAuditOutcome;
  readonly reportId?: string;
}

export interface CollabModerationAuditInput {
  auditId: string;
  actorUid: string;
  actorAuthority: "member" | "owner" | "moderator";
  target: CollabModerationAuditTarget;
  action: CollabModerationAuditAction;
  reason: CollabModerationReason;
  outcome: CollabModerationAuditOutcome;
  now: Date;
  reportId?: string;
}

export interface CollabModerationDecision<T> {
  outcome: "applied" | "replayed" | "unchanged";
  /** Semantic result, including the original result on an idempotent replay. */
  result: T;
  /** Non-null only when new durable work is required. */
  mutation: T | null;
  /** Non-null only for a newly applied mutation. */
  audit: CollabModerationAuditRecord | null;
}

export interface CollabViewerBlockEffect {
  type: "set_viewer_block";
  scope: "viewer";
  viewerUid: string;
  roomId: string;
  targetParticipantId: string;
  blocked: boolean;
}

export interface CollabOwnerMessageRemovalEffect {
  type: "tombstone_message";
  scope: "room";
  roomId: string;
  messageId: string;
  canonicalHistory: "preserved";
}

export interface CollabParticipantRemovalEffect {
  readonly type: "remove_participant";
  readonly scope: "room";
  readonly authority: "owner" | "moderator";
  readonly actorUid: string;
  readonly roomId: string;
  readonly targetParticipantId: string;
  readonly expectedRoomGeneration: number;
  readonly expectedActorParticipantId: string | null;
  readonly expectedActorMembershipGeneration: number | null;
  readonly nextRoomGeneration: number;
  readonly cancelParticipantTurns: true;
  readonly revokeMembership: true;
  readonly reportId?: string;
}

export interface CollabDismissReportEffect {
  readonly type: "dismiss_report";
  readonly scope: "moderation";
  readonly reportId: string;
  readonly roomId: string;
}

export interface CollabSuppressMessageEffect {
  readonly type: "suppress_message";
  readonly scope: "global";
  readonly reportId: string;
  readonly roomId: string;
  readonly messageId: string;
}

export interface CollabSuppressRoomEffect {
  readonly type: "suppress_room";
  readonly scope: "global";
  readonly reportId: string;
  readonly roomId: string;
  readonly messageId: null;
}

export type CollabModeratorSuppression =
  | CollabSuppressMessageEffect
  | CollabSuppressRoomEffect;

export type CollabModeratorEffect =
  | CollabDismissReportEffect
  | CollabSuppressMessageEffect
  | CollabSuppressRoomEffect
  | CollabParticipantRemovalEffect;

export interface CollabModeratorActionReceipt {
  readonly schemaVersion: 1;
  readonly actorUid: string;
  readonly requestId: string;
  readonly reportId: string;
  readonly action: CollabModeratorAction;
  readonly reason: CollabModerationReason;
  readonly effect: CollabModeratorEffect;
}

/** Immutable durable request record, including accepted desired-state no-ops. */
export interface CollabModeratorActionIdempotencyRecord
  extends CollabModeratorActionReceipt {
  readonly outcome: "applied" | "unchanged";
  readonly createdAt: string;
}

export interface CollabModeratorActionDecision
  extends CollabModerationDecision<CollabModeratorEffect> {
  /** The original receipt on replay; otherwise the receipt to persist and return. */
  readonly receipt: CollabModeratorActionIdempotencyRecord;
  /** Non-null for every newly accepted request, including mutation/audit no-ops. */
  readonly receiptMutation: CollabModeratorActionIdempotencyRecord | null;
}

/**
 * Durable composition port. `commit` atomically inserts the immutable receipt
 * under (actorUid, reportId, requestId), applies mutation/audit when present,
 * and returns the stored record. An identical existing receipt is a no-op;
 * different content for the key fails with request_already_used. Every newly
 * accepted decision must be committed, even when mutation and audit are null.
 * Persisted values are unknown until deriveCollabModeratorActionReceipt has
 * validated and defensively reconstructed them for the current request/report.
 */
export interface CollabModeratorActionIdempotencyPort {
  find(key: {
    actorUid: string;
    reportId: string;
    requestId: string;
  }): Promise<unknown>;
  commit(input: {
    receipt: CollabModeratorActionIdempotencyRecord;
    mutation: CollabModeratorEffect | null;
    audit: CollabModerationAuditRecord | null;
  }): Promise<unknown>;
}

export interface CollabRemovalFenceEvidence {
  roomId: string;
  roomGeneration: number;
  actorParticipantId: string | null;
  actorMembershipGeneration: number | null;
  cancelledParticipantId: string | null;
}

const REQUEST_ID_RE = /^[A-Za-z0-9_-]{16,64}$/;
const REPORT_KINDS: readonly CollabReportKind[] = ["collab_message", "collab_participant"];
const MODERATOR_ACTIONS: readonly CollabModeratorAction[] = [
  "dismiss",
  "suppress_message",
  "remove_participant",
  "suppress_room",
];
const MODERATOR_RECEIPT_FIELDS = [
  "schemaVersion",
  "actorUid",
  "requestId",
  "reportId",
  "action",
  "reason",
  "effect",
  "outcome",
  "createdAt",
] as const;
const DISMISS_EFFECT_FIELDS = ["type", "scope", "reportId", "roomId"] as const;
const SUPPRESS_MESSAGE_EFFECT_FIELDS = [
  "type",
  "scope",
  "reportId",
  "roomId",
  "messageId",
] as const;
const SUPPRESS_ROOM_EFFECT_FIELDS = SUPPRESS_MESSAGE_EFFECT_FIELDS;
const REMOVE_PARTICIPANT_EFFECT_FIELDS = [
  "type",
  "scope",
  "authority",
  "actorUid",
  "roomId",
  "targetParticipantId",
  "expectedRoomGeneration",
  "expectedActorParticipantId",
  "expectedActorMembershipGeneration",
  "nextRoomGeneration",
  "cancelParticipantTurns",
  "revokeMembership",
  "reportId",
] as const;
const AUDIT_ACTIONS: readonly CollabModerationAuditAction[] = [
  "report",
  "block_participant",
  "unblock_participant",
  "remove_participant",
  "remove_message",
  "dismiss_report",
  "suppress_message",
  "suppress_room",
];
const AUDIT_OUTCOMES: readonly CollabModerationAuditOutcome[] = [
  "applied",
  "replayed",
  "unchanged",
  "denied",
];
const AUDIT_TARGET_FIELDS = ["roomId", "kind", "id"] as const;
const AUDIT_RECORD_FIELDS = [
  "auditId",
  "actorUid",
  "actorAuthority",
  "target",
  "action",
  "reason",
  "createdAt",
  "outcome",
] as const;
const AUDIT_INPUT_FIELDS = [
  "auditId",
  "actorUid",
  "actorAuthority",
  "target",
  "action",
  "reason",
  "outcome",
  "now",
] as const;

/** Only factory-created records may be appended as new history entries. */
const factoryAuditRecords = new WeakSet<CollabModerationAuditRecord>();

function fail(code: CollabModerationErrorCode): never {
  throw new CollabModerationError(code);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function exactFields(
  value: Record<string, unknown>,
  required: readonly string[],
  optional: readonly string[] = [],
): boolean {
  const allowed = [...required, ...optional];
  return required.every((field) => Object.hasOwn(value, field)) &&
    Reflect.ownKeys(value).every((key) =>
      typeof key === "string" && allowed.includes(key)
    );
}

function includes<T extends string>(values: readonly T[], value: unknown): value is T {
  return typeof value === "string" && (values as readonly string[]).includes(value);
}

function isOpaqueId(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 128 &&
    value.trim() === value && !/[\u0000-\u001f\u007f]/.test(value);
}

function opaqueId(value: unknown): string {
  if (!isOpaqueId(value)) fail("invalid_request");
  return value;
}

function requestId(value: unknown): string {
  if (typeof value !== "string" || !REQUEST_ID_RE.test(value)) fail("invalid_request");
  return value;
}

function strictBody(value: unknown, allowed: readonly string[]): Record<string, unknown> {
  if (!isRecord(value) || value.schemaVersion !== 1 ||
      Object.keys(value).some((key) => !allowed.includes(key))) {
    fail("invalid_request");
  }
  return value;
}

function codePointsWithin(value: string, maximum: number): boolean {
  let count = 0;
  for (const _point of value) {
    count += 1;
    if (count > maximum) return false;
  }
  return true;
}

function codePointPrefix(value: string, maximum: number): string {
  const points: string[] = [];
  for (const point of value) {
    if (points.length >= maximum) break;
    points.push(point);
  }
  return points.join("");
}

function isoNow(value: Date): string {
  if (!(value instanceof Date) || !Number.isFinite(value.getTime())) fail("invalid_request");
  return value.toISOString();
}

function isCanonicalIsoTime(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const time = new Date(value);
  return Number.isFinite(time.getTime()) && time.toISOString() === value;
}

function generation(value: number): number {
  if (!Number.isSafeInteger(value) || value < 1) fail("invalid_request");
  return value;
}

export function parseCollabReportBody(body: unknown): CollabReportRequest {
  const value = strictBody(body, [
    "schemaVersion",
    "requestId",
    "kind",
    "targetId",
    "reason",
    "details",
  ]);
  if (!includes(REPORT_KINDS, value.kind) || !includes(COLLAB_MODERATION_REASONS, value.reason)) {
    fail("invalid_request");
  }
  const details = value.details === undefined ? "" : value.details;
  if (typeof details !== "string" || !codePointsWithin(details, COLLAB_REPORT_MAX_DETAILS)) {
    fail("invalid_request");
  }
  return {
    schemaVersion: 1,
    requestId: requestId(value.requestId),
    kind: value.kind,
    targetId: opaqueId(value.targetId),
    reason: value.reason,
    details,
  };
}

export function parseCollabModeratorActionBody(body: unknown): CollabModeratorActionRequest {
  const value = strictBody(body, ["schemaVersion", "requestId", "action", "reason"]);
  if (!includes(MODERATOR_ACTIONS, value.action) ||
      !includes(COLLAB_MODERATION_REASONS, value.reason)) {
    fail("invalid_request");
  }
  return {
    schemaVersion: 1,
    requestId: requestId(value.requestId),
    action: value.action,
    reason: value.reason,
  };
}

function requireActiveMember(actor: CollabMemberAuthority): void {
  if (!isOpaqueId(actor.uid) || !isOpaqueId(actor.roomId) ||
      !isOpaqueId(actor.participantId) || !isOpaqueId(actor.ownerUserId)) {
    fail("not_member");
  }
  generation(actor.roomGeneration);
  generation(actor.membershipGeneration);
  if (actor.status !== "active" || !includes(["owner", "participant"] as const, actor.role)) {
    fail("not_member");
  }
  if (actor.lifecycle !== "active") fail("session_closed");
}

function requireOwner(actor: CollabMemberAuthority): void {
  requireActiveMember(actor);
  if (actor.role !== "owner" || actor.uid !== actor.ownerUserId) fail("not_member");
}

function requireMessageTarget(
  roomId: string,
  target: CollabTargetAccess | null,
  targetId: string,
  code: "target_not_found" | "member_not_found" = "target_not_found",
): CollabMessageTargetAccess {
  if (target === null || target.kind !== "collab_message" ||
      target.roomId !== roomId || target.targetId !== targetId ||
      !isOpaqueId(target.participantId) || typeof target.text !== "string") {
    fail(code);
  }
  return target;
}

function requireParticipantTarget(
  roomId: string,
  target: CollabTargetAccess | null,
  targetId: string,
  code: "target_not_found" | "member_not_found" = "target_not_found",
): CollabParticipantTargetAccess {
  if (target === null || target.kind !== "collab_participant" ||
      target.roomId !== roomId || target.targetId !== targetId ||
      !includes(["owner", "participant"] as const, target.role) ||
      !includes(["active", "left", "revoked"] as const, target.status)) {
    fail(code);
  }
  return target;
}

function actorAuthority(actor: CollabMemberAuthority): "member" | "owner" {
  return actor.role === "owner" ? "owner" : "member";
}

function reportAuditTarget(
  roomId: string,
  kind: CollabReportKind,
  targetId: string,
): CollabModerationAuditTarget {
  return {
    roomId,
    kind: kind === "collab_message" ? "message" : "participant",
    id: targetId,
  };
}

export function createCollabModerationAudit(
  input: CollabModerationAuditInput,
): CollabModerationAuditRecord {
  if (!isRecord(input) || !exactFields(input, AUDIT_INPUT_FIELDS, ["reportId"]) ||
      !isRecord(input.target) || !exactFields(input.target, AUDIT_TARGET_FIELDS) ||
      !includes(AUDIT_ACTIONS, input.action) ||
      !includes(AUDIT_OUTCOMES, input.outcome) ||
      !includes(COLLAB_MODERATION_REASONS, input.reason) ||
      !includes(["member", "owner", "moderator"] as const, input.actorAuthority) ||
      !includes(["message", "participant", "room"] as const, input.target.kind)) {
    fail("invalid_request");
  }
  const target = Object.freeze({
    roomId: opaqueId(input.target.roomId),
    kind: input.target.kind,
    id: opaqueId(input.target.id),
  });
  const hasReportId = Object.hasOwn(input, "reportId");
  const reportId = hasReportId ? opaqueId(input.reportId) : undefined;
  const record: CollabModerationAuditRecord = Object.freeze({
    auditId: opaqueId(input.auditId),
    actorUid: opaqueId(input.actorUid),
    actorAuthority: input.actorAuthority,
    target,
    action: input.action,
    reason: input.reason,
    createdAt: isoNow(input.now),
    outcome: input.outcome,
    ...(reportId === undefined ? {} : { reportId }),
  });
  factoryAuditRecords.add(record);
  return record;
}

function copyCollabModerationAudit(
  record: CollabModerationAuditRecord,
): CollabModerationAuditRecord {
  if (!isRecord(record) || !exactFields(record, AUDIT_RECORD_FIELDS, ["reportId"]) ||
      !isRecord(record.target) || !exactFields(record.target, AUDIT_TARGET_FIELDS) ||
      !isCanonicalIsoTime(record.createdAt)) {
    fail("invalid_request");
  }
  const hasReportId = Object.hasOwn(record, "reportId");
  return createCollabModerationAudit({
    auditId: record.auditId,
    actorUid: record.actorUid,
    actorAuthority: record.actorAuthority,
    target: {
      roomId: record.target.roomId,
      kind: record.target.kind,
      id: record.target.id,
    },
    action: record.action,
    reason: record.reason,
    outcome: record.outcome,
    now: new Date(record.createdAt),
    ...(hasReportId ? { reportId: record.reportId } : {}),
  });
}

function sameAudit(
  left: CollabModerationAuditRecord,
  right: CollabModerationAuditRecord,
): boolean {
  return left.auditId === right.auditId &&
    left.actorUid === right.actorUid &&
    left.actorAuthority === right.actorAuthority &&
    left.target.roomId === right.target.roomId &&
    left.target.kind === right.target.kind &&
    left.target.id === right.target.id &&
    left.action === right.action &&
    left.reason === right.reason &&
    left.createdAt === right.createdAt &&
    left.outcome === right.outcome &&
    left.reportId === right.reportId;
}

/**
 * Persistent-value append. New entries must come from the audited factory;
 * persisted trail entries are revalidated and defensively copied at the trust
 * boundary. Neither caller objects nor extra runtime fields enter the result.
 */
export function appendCollabModerationAudit(
  trail: readonly CollabModerationAuditRecord[],
  audit: CollabModerationAuditRecord | null,
): readonly CollabModerationAuditRecord[] {
  if (!Array.isArray(trail)) fail("invalid_request");
  if (audit !== null && (!isRecord(audit) || !factoryAuditRecords.has(audit))) {
    fail("invalid_request");
  }
  const copiedTrail = trail.map((record) => copyCollabModerationAudit(record));
  if (audit === null) return Object.freeze(copiedTrail);

  const copiedAudit = copyCollabModerationAudit(audit);
  const existing = copiedTrail.find((record) => record.auditId === copiedAudit.auditId);
  if (existing !== undefined) {
    if (!sameAudit(existing, copiedAudit)) fail("request_already_used");
    return Object.freeze(copiedTrail);
  }
  return Object.freeze([...copiedTrail, copiedAudit]);
}

function applied<T>(
  result: T,
  audit: CollabModerationAuditRecord,
): CollabModerationDecision<T> {
  return { outcome: "applied", result, mutation: result, audit };
}

function noMutation<T>(
  outcome: "replayed" | "unchanged",
  result: T,
): CollabModerationDecision<T> {
  return { outcome, result, mutation: null, audit: null };
}

interface ReportDraft {
  requestId: string;
  reporterUid: string;
  roomId: string;
  kind: CollabReportKind;
  targetId: string;
  reason: CollabModerationReason;
  details: string;
  excerpt: string;
}

function sameReportDraft(record: CollabReportRecord, draft: ReportDraft): boolean {
  return record.requestId === draft.requestId &&
    record.reporterUid === draft.reporterUid &&
    record.roomId === draft.roomId &&
    record.kind === draft.kind &&
    record.targetId === draft.targetId &&
    record.reason === draft.reason &&
    record.details === draft.details &&
    record.excerpt === draft.excerpt;
}

export function decideCollabReport(input: {
  actor: CollabMemberAuthority;
  request: CollabReportRequest;
  target: CollabTargetAccess | null;
  existing: CollabReportRecord | null;
  reportsInLast24Hours: number;
  server: CollabReportServerContext;
}): CollabModerationDecision<CollabReportRecord> {
  requireActiveMember(input.actor);
  const request = parseCollabReportBody(input.request);
  if (!Number.isSafeInteger(input.reportsInLast24Hours) || input.reportsInLast24Hours < 0) {
    fail("invalid_request");
  }

  // Current access precedes both replay and quota, so a stale report cannot
  // become an oracle for a target in another room or a newly revoked room.
  const target = request.kind === "collab_message"
    ? requireMessageTarget(input.actor.roomId, input.target, request.targetId)
    : requireParticipantTarget(input.actor.roomId, input.target, request.targetId);
  const draft: ReportDraft = {
    requestId: request.requestId,
    reporterUid: input.actor.uid,
    roomId: input.actor.roomId,
    kind: request.kind,
    targetId: request.targetId,
    reason: request.reason,
    details: request.details,
    excerpt: target.kind === "collab_message"
      ? codePointPrefix(target.text, COLLAB_REPORT_MAX_EXCERPT)
      : "",
  };

  if (input.existing !== null) {
    if (!sameReportDraft(input.existing, draft)) fail("request_already_used");
    return noMutation("replayed", input.existing);
  }
  if (input.reportsInLast24Hours >= COLLAB_REPORT_DAILY_LIMIT) {
    fail("report_limit_reached");
  }

  const result: CollabReportRecord = {
    ...draft,
    reportId: opaqueId(input.server.reportId),
    createdAt: isoNow(input.server.now),
    status: "open",
  };
  const audit = createCollabModerationAudit({
    auditId: input.server.auditId,
    actorUid: input.actor.uid,
    actorAuthority: actorAuthority(input.actor),
    target: reportAuditTarget(result.roomId, result.kind, result.targetId),
    action: "report",
    reason: result.reason,
    outcome: "applied",
    now: input.server.now,
    reportId: result.reportId,
  });
  return applied(result, audit);
}

export function decideCollabViewerBlock(input: {
  actor: CollabMemberAuthority;
  target: CollabTargetAccess | null;
  blocked: boolean;
  currentlyBlocked: boolean;
  server: CollabAuditServerContext;
}): CollabModerationDecision<CollabViewerBlockEffect> {
  requireActiveMember(input.actor);
  if (typeof input.blocked !== "boolean" || typeof input.currentlyBlocked !== "boolean") {
    fail("invalid_request");
  }
  const target = requireParticipantTarget(
    input.actor.roomId,
    input.target,
    input.target?.targetId ?? "",
  );
  if (input.blocked && target.targetId === input.actor.participantId) fail("invalid_request");
  const result: CollabViewerBlockEffect = {
    type: "set_viewer_block",
    scope: "viewer",
    viewerUid: input.actor.uid,
    roomId: input.actor.roomId,
    targetParticipantId: target.targetId,
    blocked: input.blocked,
  };
  if (input.currentlyBlocked === input.blocked) return noMutation("unchanged", result);
  const audit = createCollabModerationAudit({
    auditId: input.server.auditId,
    actorUid: input.actor.uid,
    actorAuthority: actorAuthority(input.actor),
    target: { roomId: result.roomId, kind: "participant", id: result.targetParticipantId },
    action: input.blocked ? "block_participant" : "unblock_participant",
    reason: "other",
    outcome: "applied",
    now: input.server.now,
  });
  return applied(result, audit);
}

export type CollabContentVisibility =
  | "visible"
  | "viewer_blocked"
  | "owner_room_removed"
  | "moderator_globally_suppressed";

/** Pure visibility rule shared by message/model/object projection consumers. */
export function collabContentVisibility(input: {
  viewerUid: string;
  roomId: string;
  messageId: string;
  subjectParticipantId: string;
  viewerBlock: Pick<
    CollabViewerBlockEffect,
    "viewerUid" | "roomId" | "targetParticipantId" | "blocked"
  > | null;
  ownerRemoval: Pick<CollabOwnerMessageRemovalEffect, "roomId" | "messageId"> | null;
  moderatorSuppression: Pick<CollabModeratorSuppression, "roomId" | "messageId"> | null;
}): CollabContentVisibility {
  if (input.moderatorSuppression !== null &&
      input.moderatorSuppression.roomId === input.roomId &&
      (input.moderatorSuppression.messageId === null ||
       input.moderatorSuppression.messageId === input.messageId)) {
    return "moderator_globally_suppressed";
  }
  if (input.ownerRemoval !== null && input.ownerRemoval.roomId === input.roomId &&
      input.ownerRemoval.messageId === input.messageId) {
    return "owner_room_removed";
  }
  if (input.viewerBlock !== null && input.viewerBlock.blocked &&
      input.viewerBlock.viewerUid === input.viewerUid &&
      input.viewerBlock.roomId === input.roomId &&
      input.viewerBlock.targetParticipantId === input.subjectParticipantId) {
    return "viewer_blocked";
  }
  return "visible";
}

function removalEffect(input: {
  authority: "owner" | "moderator";
  actorUid: string;
  roomId: string;
  targetParticipantId: string;
  roomGeneration: number;
  actorParticipantId: string | null;
  actorMembershipGeneration: number | null;
  reportId?: string;
}): CollabParticipantRemovalEffect {
  return {
    type: "remove_participant",
    scope: "room",
    authority: input.authority,
    actorUid: input.actorUid,
    roomId: input.roomId,
    targetParticipantId: input.targetParticipantId,
    expectedRoomGeneration: input.roomGeneration,
    expectedActorParticipantId: input.actorParticipantId,
    expectedActorMembershipGeneration: input.actorMembershipGeneration,
    nextRoomGeneration: generation(input.roomGeneration + 1),
    cancelParticipantTurns: true,
    revokeMembership: true,
    ...(input.reportId === undefined ? {} : { reportId: input.reportId }),
  };
}

/** Checks the transaction's generation and completed-cancellation evidence. */
export function collabRemovalFenceSatisfied(
  effect: CollabParticipantRemovalEffect,
  evidence: CollabRemovalFenceEvidence,
): boolean {
  return effect.revokeMembership && effect.cancelParticipantTurns &&
    Number.isSafeInteger(effect.expectedRoomGeneration) &&
    effect.expectedRoomGeneration >= 1 &&
    Number.isSafeInteger(effect.nextRoomGeneration) &&
    effect.nextRoomGeneration === effect.expectedRoomGeneration + 1 &&
    evidence.roomId === effect.roomId &&
    evidence.roomGeneration === effect.expectedRoomGeneration &&
    evidence.actorParticipantId === effect.expectedActorParticipantId &&
    evidence.actorMembershipGeneration === effect.expectedActorMembershipGeneration &&
    evidence.cancelledParticipantId === effect.targetParticipantId;
}

export function decideCollabOwnerParticipantRemoval(input: {
  actor: CollabMemberAuthority;
  target: CollabTargetAccess | null;
  server: CollabAuditServerContext;
}): CollabModerationDecision<CollabParticipantRemovalEffect> {
  requireOwner(input.actor);
  const target = requireParticipantTarget(
    input.actor.roomId,
    input.target,
    input.target?.targetId ?? "",
    "member_not_found",
  );
  if (target.role === "owner") fail("owner_not_removable");
  const result = removalEffect({
    authority: "owner",
    actorUid: input.actor.uid,
    roomId: input.actor.roomId,
    targetParticipantId: target.targetId,
    roomGeneration: input.actor.roomGeneration,
    actorParticipantId: input.actor.participantId,
    actorMembershipGeneration: input.actor.membershipGeneration,
  });
  if (target.status === "revoked") return noMutation("unchanged", result);
  const audit = createCollabModerationAudit({
    auditId: input.server.auditId,
    actorUid: input.actor.uid,
    actorAuthority: "owner",
    target: { roomId: result.roomId, kind: "participant", id: result.targetParticipantId },
    action: "remove_participant",
    reason: "other",
    outcome: "applied",
    now: input.server.now,
  });
  return applied(result, audit);
}

export function decideCollabOwnerMessageRemoval(input: {
  actor: CollabMemberAuthority;
  target: CollabTargetAccess | null;
  currentlyRemoved: boolean;
  server: CollabAuditServerContext;
}): CollabModerationDecision<CollabOwnerMessageRemovalEffect> {
  requireOwner(input.actor);
  if (typeof input.currentlyRemoved !== "boolean") fail("invalid_request");
  const target = requireMessageTarget(
    input.actor.roomId,
    input.target,
    input.target?.targetId ?? "",
  );
  const result: CollabOwnerMessageRemovalEffect = {
    type: "tombstone_message",
    scope: "room",
    roomId: input.actor.roomId,
    messageId: target.targetId,
    canonicalHistory: "preserved",
  };
  if (input.currentlyRemoved) return noMutation("unchanged", result);
  const audit = createCollabModerationAudit({
    auditId: input.server.auditId,
    actorUid: input.actor.uid,
    actorAuthority: "owner",
    target: { roomId: result.roomId, kind: "message", id: result.messageId },
    action: "remove_message",
    reason: "other",
    outcome: "applied",
    now: input.server.now,
  });
  return applied(result, audit);
}

function requireModerator(
  authority: CollabModeratorAuthority | null,
): asserts authority is CollabModeratorAuthority {
  if (authority === null || !authority.active ||
      authority.permission !== "collab_moderator" || !isOpaqueId(authority.uid)) {
    fail("moderator_required");
  }
}

function requireReportTarget(report: CollabModerationReportTarget): void {
  if (!isOpaqueId(report.reportId) || !isOpaqueId(report.roomId) ||
      !isOpaqueId(report.targetId) || !includes(REPORT_KINDS, report.kind) ||
      !includes(["open", "dismissed", "actioned"] as const, report.status)) {
    fail("invalid_request");
  }
}

function deriveModeratorEffect(
  value: unknown,
  action: CollabModeratorAction,
  actorUid: string,
  reportId: string,
): CollabModeratorEffect {
  if (!isRecord(value)) fail("invalid_request");
  switch (action) {
    case "dismiss": {
      if (!exactFields(value, DISMISS_EFFECT_FIELDS) ||
          value.type !== "dismiss_report" || value.scope !== "moderation" ||
          !isOpaqueId(value.reportId) || value.reportId !== reportId ||
          !isOpaqueId(value.roomId)) {
        fail("invalid_request");
      }
      return Object.freeze({
        type: "dismiss_report",
        scope: "moderation",
        reportId,
        roomId: value.roomId,
      });
    }
    case "suppress_message": {
      if (!exactFields(value, SUPPRESS_MESSAGE_EFFECT_FIELDS) ||
          value.type !== "suppress_message" || value.scope !== "global" ||
          !isOpaqueId(value.reportId) || value.reportId !== reportId ||
          !isOpaqueId(value.roomId) || !isOpaqueId(value.messageId)) {
        fail("invalid_request");
      }
      return Object.freeze({
        type: "suppress_message",
        scope: "global",
        reportId,
        roomId: value.roomId,
        messageId: value.messageId,
      });
    }
    case "suppress_room": {
      if (!exactFields(value, SUPPRESS_ROOM_EFFECT_FIELDS) ||
          value.type !== "suppress_room" || value.scope !== "global" ||
          !isOpaqueId(value.reportId) || value.reportId !== reportId ||
          !isOpaqueId(value.roomId) || value.messageId !== null) {
        fail("invalid_request");
      }
      return Object.freeze({
        type: "suppress_room",
        scope: "global",
        reportId,
        roomId: value.roomId,
        messageId: null,
      });
    }
    case "remove_participant": {
      if (!exactFields(value, REMOVE_PARTICIPANT_EFFECT_FIELDS) ||
          value.type !== "remove_participant" || value.scope !== "room" ||
          value.authority !== "moderator" || value.actorUid !== actorUid ||
          !isOpaqueId(value.roomId) || !isOpaqueId(value.targetParticipantId) ||
          !isOpaqueId(value.reportId) || value.reportId !== reportId ||
          typeof value.expectedRoomGeneration !== "number" ||
          typeof value.nextRoomGeneration !== "number" ||
          value.expectedActorParticipantId !== null ||
          value.expectedActorMembershipGeneration !== null ||
          value.cancelParticipantTurns !== true || value.revokeMembership !== true) {
        fail("invalid_request");
      }
      const expectedRoomGeneration = generation(value.expectedRoomGeneration);
      const nextRoomGeneration = generation(value.nextRoomGeneration);
      if (nextRoomGeneration !== generation(expectedRoomGeneration + 1)) {
        fail("invalid_request");
      }
      return Object.freeze(removalEffect({
        authority: "moderator",
        actorUid,
        roomId: value.roomId,
        targetParticipantId: value.targetParticipantId,
        roomGeneration: expectedRoomGeneration,
        actorParticipantId: null,
        actorMembershipGeneration: null,
        reportId,
      }));
    }
    default:
      fail("invalid_request");
  }
}

function moderatorEffectTargetsReport(
  effect: CollabModeratorEffect,
  report: CollabModerationReportTarget,
): boolean {
  if (effect.roomId !== report.roomId) return false;
  switch (effect.type) {
    case "dismiss_report":
    case "suppress_room":
      return true;
    case "suppress_message":
      return report.kind === "collab_message" && effect.messageId === report.targetId;
    case "remove_participant":
      return report.kind === "collab_participant" &&
        effect.targetParticipantId === report.targetId;
    default:
      return false;
  }
}

/**
 * Validates and reconstructs a versioned persisted receipt for this exact
 * moderator/request/report context. No caller-owned effect reference survives.
 */
export function deriveCollabModeratorActionReceipt(input: {
  record: unknown;
  moderator: CollabModeratorAuthority;
  request: CollabModeratorActionRequest;
  report: CollabModerationReportTarget;
}): CollabModeratorActionIdempotencyRecord {
  requireModerator(input.moderator);
  const request = parseCollabModeratorActionBody(input.request);
  requireReportTarget(input.report);
  const value = input.record;
  if (!isRecord(value) || !exactFields(value, MODERATOR_RECEIPT_FIELDS) ||
      value.schemaVersion !== 1) {
    fail("invalid_request");
  }
  const actorUid = opaqueId(value.actorUid);
  const storedRequestId = requestId(value.requestId);
  const reportId = opaqueId(value.reportId);
  const action = value.action;
  const reason = value.reason;
  const outcome = value.outcome;
  const createdAt = value.createdAt;
  if (!includes(MODERATOR_ACTIONS, action) ||
      !includes(COLLAB_MODERATION_REASONS, reason) ||
      !includes(["applied", "unchanged"] as const, outcome) ||
      !isCanonicalIsoTime(createdAt)) {
    fail("invalid_request");
  }
  const effect = deriveModeratorEffect(value.effect, action, actorUid, reportId);
  if (actorUid !== input.moderator.uid || storedRequestId !== request.requestId ||
      reportId !== input.report.reportId || action !== request.action ||
      reason !== request.reason || !moderatorEffectTargetsReport(effect, input.report)) {
    fail("request_already_used");
  }
  return Object.freeze({
    schemaVersion: 1,
    actorUid,
    requestId: storedRequestId,
    reportId,
    action,
    reason,
    effect,
    outcome,
    createdAt,
  });
}

export function decideCollabModeratorAction(input: {
  moderator: CollabModeratorAuthority | null;
  request: CollabModeratorActionRequest;
  report: CollabModerationReportTarget;
  target: CollabTargetAccess | null;
  /** Raw persisted value; null means no receipt exists. */
  existing: unknown;
  current: {
    roomGeneration: number;
    messageSuppressed: boolean;
    roomSuppressed: boolean;
  };
  server: CollabAuditServerContext;
}): CollabModeratorActionDecision {
  requireModerator(input.moderator);
  const request = parseCollabModeratorActionBody(input.request);
  requireReportTarget(input.report);
  generation(input.current.roomGeneration);
  if (typeof input.current.messageSuppressed !== "boolean" ||
      typeof input.current.roomSuppressed !== "boolean") {
    fail("invalid_request");
  }

  if (input.existing !== null) {
    const receipt = deriveCollabModeratorActionReceipt({
      record: input.existing,
      moderator: input.moderator,
      request,
      report: input.report,
    });
    return {
      ...noMutation("replayed", receipt.effect),
      receipt,
      receiptMutation: null,
    };
  }

  let result: CollabModeratorEffect;
  let unchanged = false;
  switch (request.action) {
    case "dismiss": {
      if (input.report.status === "actioned") fail("invalid_transition");
      result = {
        type: "dismiss_report",
        scope: "moderation",
        reportId: input.report.reportId,
        roomId: input.report.roomId,
      };
      unchanged = input.report.status === "dismissed";
      break;
    }
    case "suppress_message": {
      if (input.report.kind !== "collab_message") fail("invalid_request");
      const target = requireMessageTarget(
        input.report.roomId,
        input.target,
        input.report.targetId,
      );
      result = {
        type: "suppress_message",
        scope: "global",
        reportId: input.report.reportId,
        roomId: input.report.roomId,
        messageId: target.targetId,
      };
      unchanged = input.current.messageSuppressed;
      break;
    }
    case "suppress_room": {
      result = {
        type: "suppress_room",
        scope: "global",
        reportId: input.report.reportId,
        roomId: input.report.roomId,
        messageId: null,
      };
      unchanged = input.current.roomSuppressed;
      break;
    }
    case "remove_participant": {
      if (input.report.kind !== "collab_participant") fail("invalid_request");
      const target = requireParticipantTarget(
        input.report.roomId,
        input.target,
        input.report.targetId,
        "member_not_found",
      );
      if (target.role === "owner") fail("owner_not_removable");
      result = removalEffect({
        authority: "moderator",
        actorUid: input.moderator.uid,
        roomId: input.report.roomId,
        targetParticipantId: target.targetId,
        roomGeneration: input.current.roomGeneration,
        actorParticipantId: null,
        actorMembershipGeneration: null,
        reportId: input.report.reportId,
      });
      unchanged = target.status === "revoked";
      break;
    }
    default:
      fail("invalid_request");
  }
  result = deriveModeratorEffect(
    result,
    request.action,
    input.moderator.uid,
    input.report.reportId,
  );
  const receipt = deriveCollabModeratorActionReceipt({
    record: {
      schemaVersion: 1,
      actorUid: input.moderator.uid,
      requestId: request.requestId,
      reportId: input.report.reportId,
      action: request.action,
      reason: request.reason,
      effect: result,
      outcome: unchanged ? ("unchanged" as const) : ("applied" as const),
      createdAt: isoNow(input.server.now),
    },
    moderator: input.moderator,
    request,
    report: input.report,
  });
  if (unchanged) {
    return {
      ...noMutation("unchanged", result),
      receipt,
      receiptMutation: receipt,
    };
  }

  const action: CollabModerationAuditAction = request.action === "dismiss"
    ? "dismiss_report"
    : request.action;
  const target = request.action === "suppress_room"
    ? { roomId: input.report.roomId, kind: "room" as const, id: input.report.roomId }
    : reportAuditTarget(input.report.roomId, input.report.kind, input.report.targetId);
  const audit = createCollabModerationAudit({
    auditId: input.server.auditId,
    actorUid: input.moderator.uid,
    actorAuthority: "moderator",
    target,
    action,
    reason: request.reason,
    outcome: "applied",
    now: input.server.now,
    reportId: input.report.reportId,
  });
  return {
    ...applied(result, audit),
    receipt,
    receiptMutation: receipt,
  };
}
