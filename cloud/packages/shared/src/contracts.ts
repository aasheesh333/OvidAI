import { z } from "zod";
import type { McpServerDto } from "./mcpRest.js";
import type { AttachmentUploadResponse } from "./rest.js";

export const CONTRACT_VERSION = 1 as const;

const nonEmptyString = z.string().min(1);
const nullableTimestamp = z.string().min(1).nullable().optional();

export const attachmentCreateContractSchema = z
  .object({
    name: nonEmptyString,
    size: z.number().int().positive(),
    contentType: z.string().min(1).max(255).optional(),
  })
  .strict();

export interface AttachmentUploadResponseContract extends AttachmentUploadResponse {
  contentType?: string;
  uploadHeaders?: Record<string, string>;
}

export const attachmentUploadResponseContractSchema: z.ZodType<AttachmentUploadResponseContract> = z
  .object({
    attachmentId: nonEmptyString,
    uploadUrl: nonEmptyString,
    path: nonEmptyString,
    expiresAt: nonEmptyString,
    contentType: nonEmptyString.optional(),
    uploadHeaders: z.record(z.string(), z.string()).optional(),
  })
  .strict();

export interface McpConnectionContract extends McpServerDto {
  connectionId: string;
  providerId: string;
  agentEnabled: boolean;
  authState: string;
  healthState:
    | "never_checked"
    | "checking"
    | "healthy"
    | "degraded"
    | "needs_auth"
    | "refreshing"
    | "revoked"
    | "unavailable"
    | "disabled";
  lastCheckedAt: string | null;
  lastSuccessAt: string | null;
  configVersion: number;
  disconnectGeneration: number;
  approvedSourceId?: string;
  approvedDigest?: string;
}

export const mcpConnectionContractSchema: z.ZodType<McpConnectionContract> = z
  .object({
    id: nonEmptyString,
    name: nonEmptyString,
    transport: z.enum(["stdio", "http", "sse", "native"]),
    curatedId: nonEmptyString.nullable(),
    url: z.string().optional(),
    command: z.string().optional(),
    enabled: z.boolean(),
    hasSecrets: z.boolean(),
    needsAuth: z.boolean(),
    createdAt: nonEmptyString,
    updatedAt: nonEmptyString,
    connectionId: nonEmptyString,
    providerId: nonEmptyString,
    agentEnabled: z.boolean(),
    authState: nonEmptyString,
    healthState: z.enum([
      "never_checked",
      "checking",
      "healthy",
      "degraded",
      "needs_auth",
      "refreshing",
      "revoked",
      "unavailable",
      "disabled",
    ]),
    lastCheckedAt: z.string().min(1).nullable(),
    lastSuccessAt: z.string().min(1).nullable(),
    configVersion: z.number().int().nonnegative(),
    disconnectGeneration: z.number().int().nonnegative(),
    approvedSourceId: nonEmptyString.optional(),
    approvedDigest: nonEmptyString.optional(),
  })
  .strict();

export const mcpConnectionsResponseContractSchema = z
  .object({ items: z.array(mcpConnectionContractSchema) })
  .strict();

export const subagentStatusSchema = z.enum([
  "awaiting_next_user_task",
  "running",
  "completed",
  "failed",
  "cancelled",
  "timeout",
]);
export type SubagentStatus = z.infer<typeof subagentStatusSchema>;

export const structuredSubagentReportSchema = z
  .object({
    subagent_id: nonEmptyString,
    status: z.enum(["completed", "failed", "cancelled", "timeout"]),
    files_modified: z.array(nonEmptyString),
    artifacts_created: z.array(nonEmptyString),
    key_findings: z.string().max(4000),
    error_if_any: z.string().max(4000).nullable(),
  })
  .strict();
export type StructuredSubagentReport = z.infer<typeof structuredSubagentReportSchema>;

export const ADDITIVE_SUBAGENT_EVENT_TYPES = [
  "subagent_requested",
  "subagent_deferred",
  "subagent_admitted",
  "subagent_controlled",
  "subagent_compacted",
  "root_finalized",
] as const;

const compactionMetadataShape = {
  sessionId: nonEmptyString,
  runId: nonEmptyString,
  compactionId: nonEmptyString,
  checkpointId: nonEmptyString,
  ts: nonEmptyString,
  model: nonEmptyString,
  contextLimit: z.number().int().positive(),
  beforeTokens: z.number().int().nonnegative(),
  afterTokens: z.number().int().nonnegative(),
  usageSource: z.enum(["measured", "deterministic_fallback"]),
  continuation: z.literal("continuing_existing_task"),
};

const subagentCompactedShape = {
  type: z.literal("subagent_compacted"),
  workerId: nonEmptyString,
  ...compactionMetadataShape,
};

export const subagentCompactedPayloadSchema = z.object(subagentCompactedShape).strict();
export type SubagentCompactedPayload = z.infer<typeof subagentCompactedPayloadSchema>;

export const mainCompactionDiagnosticsSchema = z
  .object({
    type: z.literal("compaction_completed"),
    actorKind: z.literal("main"),
    ...compactionMetadataShape,
  })
  .strict();

// Existing Compactor.maybeCompact emits folded/retained/narrative with an
// optional runId. Rich additive diagnostics may add the approved operational
// metadata, but neither the old minimal nor new subagent_compacted event is
// required to carry the other shape's fields.
export const compactionCompletedDiagnosticsSchema = z
  .object({
    type: z.literal("compaction_completed"),
    sessionId: nonEmptyString,
    runId: nonEmptyString.optional(),
    folded: z.number().int().nonnegative(),
    retained: z.number().int().nonnegative(),
    narrative: z.boolean(),
    actorKind: z.enum(["main", "worker"]).optional(),
    workerId: nonEmptyString.optional(),
    compactionId: nonEmptyString.optional(),
    checkpointId: nonEmptyString.optional(),
    ts: nonEmptyString.optional(),
    model: nonEmptyString.optional(),
    contextLimit: z.number().int().positive().optional(),
    beforeTokens: z.number().int().nonnegative().optional(),
    afterTokens: z.number().int().nonnegative().optional(),
    usageSource: z.enum(["measured", "deterministic_fallback"]).optional(),
    continuation: z.literal("continuing_existing_task").optional(),
  })
  .passthrough();

const lifecycleRootShape = {
  sessionId: nonEmptyString,
  runId: nonEmptyString,
  rootTaskRunId: nonEmptyString,
};
const lifecycleTerminalStatusSchema = z.enum(["completed", "failed", "cancelled", "timeout"]);
const checkpointSchema = z.unknown().nullable();
const logAvailableSchema = z.boolean();

// Each variant enforces its stable production fields. passthrough() is the
// old-reader compatibility boundary: a newer server's optional additive fields
// survive parsing instead of making the whole event unreadable.
export const subagentLifecycleEventSchema = z.discriminatedUnion("type", [
  z
    .object({
      type: z.literal("subagent_requested"),
      ...lifecycleRootShape,
      childRunId: z.literal(null).optional(),
      childSessionId: z.literal(null).optional(),
      batchId: nonEmptyString,
      agentType: nonEmptyString,
      launchReason: z.string().min(1).max(4000),
      requestedAt: nonEmptyString,
      admittedAt: z.literal(null).optional(),
      startedAt: z.literal(null).optional(),
      prompt: z.string().min(1).max(4000),
      status: subagentStatusSchema.optional(),
      capacity: z
        .object({
          active: z.number().int().nonnegative(),
          limit: z.literal(50),
          available: z.number().int().nonnegative(),
          awaiting: z.number().int().nonnegative(),
        })
        .strict(),
      checkpoint: checkpointSchema,
      logAvailable: logAvailableSchema,
    })
    .passthrough(),
  z
    .object({
      type: z.literal("subagent_deferred"),
      ...lifecycleRootShape,
      childRunId: z.literal(null).optional(),
      childSessionId: z.literal(null).optional(),
      batchId: nonEmptyString,
      deferredRequestId: nonEmptyString,
      requestedAt: nonEmptyString,
      admittedAt: z.literal(null).optional(),
      startedAt: z.literal(null).optional(),
      status: z.literal("awaiting_next_user_task"),
      reason: nonEmptyString,
      provenance: z
        .object({ platform: nonEmptyString, actorUserId: nonEmptyString })
        .passthrough(),
      checkpoint: checkpointSchema,
      logAvailable: logAvailableSchema,
    })
    .passthrough(),
  z
    .object({
      type: z.literal("subagent_admitted"),
      ...lifecycleRootShape,
      childRunId: nonEmptyString,
      childSessionId: nonEmptyString,
      batchId: nonEmptyString,
      deferredRequestId: nonEmptyString.optional(),
      decisionActorRunId: nonEmptyString,
      schedulingReason: z.string().min(1).max(4000),
      requestedAt: nonEmptyString,
      admittedAt: nonEmptyString,
      startedAt: nullableTimestamp,
      availableSlotsBefore: z.number().int().nonnegative(),
      availableSlotsAfter: z.number().int().nonnegative(),
      checkpoint: checkpointSchema,
      logAvailable: logAvailableSchema,
    })
    .passthrough(),
  z
    .object({
      type: z.literal("subagent_started"),
      sessionId: nonEmptyString,
      runId: nonEmptyString,
      rootTaskRunId: nonEmptyString.optional(),
      childRunId: nonEmptyString,
      childSessionId: nonEmptyString,
      batchId: nonEmptyString.optional(),
      agentType: nonEmptyString,
      launchReason: z.string().min(1).max(4000).optional(),
      requestedAt: nonEmptyString.optional(),
      admittedAt: nonEmptyString.optional(),
      startedAt: nonEmptyString.optional(),
      prompt: z.string().min(1).max(4000),
      status: z.literal("running").optional(),
      logicalWorkerId: nonEmptyString.optional(),
      attemptId: nonEmptyString.optional(),
      attemptNumber: z.number().int().positive().optional(),
      checkpoint: checkpointSchema.optional(),
      logAvailable: logAvailableSchema.optional(),
    })
    .passthrough(),
  z
    .object({
      type: z.literal("subagent_controlled"),
      ...lifecycleRootShape,
      childRunId: nonEmptyString,
      childSessionId: nonEmptyString,
      logicalWorkerId: nonEmptyString,
      attemptId: nonEmptyString,
      action: z.enum(["continue", "resume", "stop"]),
      actorKind: z.literal("main"),
      actorRunId: nonEmptyString,
      reason: z.string().min(1).max(4000),
      controlledAt: nonEmptyString,
      status: subagentStatusSchema,
      requestedTransition: nonEmptyString,
      performedTransition: nonEmptyString,
      checkpoint: checkpointSchema,
      logAvailable: logAvailableSchema,
    })
    .passthrough(),
  z
    .object({
      type: z.literal("subagent_completed"),
      sessionId: nonEmptyString,
      runId: nonEmptyString.optional(),
      rootTaskRunId: nonEmptyString.optional(),
      childRunId: nonEmptyString,
      childSessionId: nonEmptyString,
      batchId: nonEmptyString.optional(),
      agentType: nonEmptyString,
      requestedAt: nonEmptyString.optional(),
      admittedAt: nonEmptyString.optional(),
      startedAt: nonEmptyString.optional(),
      endedAt: nonEmptyString.optional(),
      status: lifecycleTerminalStatusSchema,
      summary: z.string().max(4000),
      structuredReport: structuredSubagentReportSchema.optional(),
      logicalWorkerId: nonEmptyString.optional(),
      attemptId: nonEmptyString.optional(),
      attemptNumber: z.number().int().positive().optional(),
      checkpoint: checkpointSchema.optional(),
      logAvailable: logAvailableSchema.optional(),
    })
    .passthrough(),
  z.object(subagentCompactedShape).passthrough(),
  z
    .object({
      type: z.literal("root_finalized"),
      ...lifecycleRootShape,
      executionEpoch: z.number().int().positive(),
      activeWorkerCount: z.literal(0),
      reportsIncluded: z.array(nonEmptyString),
      finalSynthesisCount: z.literal(1),
      finalizedAt: nonEmptyString,
    })
    .passthrough(),
]).superRefine((event, context) => {
  if (event.type !== "subagent_completed" || event.structuredReport === undefined) return;
  if (event.structuredReport.status !== event.status) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["structuredReport", "status"],
      message: "Structured report status must match the terminal event status",
    });
  }
  if (event.structuredReport.subagent_id !== event.childSessionId) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["structuredReport", "subagent_id"],
      message: "Structured report subagent_id must match childSessionId",
    });
  }
});
export type SubagentLifecycleEvent = z.infer<typeof subagentLifecycleEventSchema>;

export const historyItemKindSchema = z.enum([
  "message",
  "tool_call",
  "approval",
  "artifact",
  "file",
  "logical_worker",
  "attempt",
  "checkpoint",
  "compaction",
  "event",
  "control",
]);
export type HistoryItemKind = z.infer<typeof historyItemKindSchema>;

export const exactHistoryItemSchema = z
  .object({
    stableId: nonEmptyString,
    kind: historyItemKindSchema,
    sessionId: nonEmptyString,
    rootTaskRunId: nonEmptyString,
    logicalWorkerId: nonEmptyString.nullable(),
    attemptId: nonEmptyString.nullable(),
    eventCursor: nonEmptyString,
    inlinePayload: z.unknown().optional(),
    objectRef: nonEmptyString.optional(),
    byteLength: z.number().int().nonnegative(),
  })
  .strict()
  .superRefine((item, context) => {
    const inline = Object.hasOwn(item, "inlinePayload");
    const reference = Object.hasOwn(item, "objectRef");
    if (inline === reference) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: "Exactly one of inlinePayload or objectRef is required",
      });
    }
  });
export type ExactHistoryItem = z.infer<typeof exactHistoryItemSchema>;

export const exactRecallChunkSchema = z
  .object({
    item: exactHistoryItemSchema,
    offset: z.number().int().nonnegative(),
    data: z.string(),
    nextOffset: z.number().int().nonnegative().nullable(),
  })
  .strict();
export type ExactRecallChunk = z.infer<typeof exactRecallChunkSchema>;

export const exactRecallPageSchema = z
  .object({
    chunks: z.array(exactRecallChunkSchema),
    nextCursor: nonEmptyString.nullable(),
  })
  .strict();
export type ExactRecallPage = z.infer<typeof exactRecallPageSchema>;
