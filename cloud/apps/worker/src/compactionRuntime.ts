import type {
  AgentMessage,
  CompactionInput,
  CompactionOutcome as CoreCompactionOutcome,
  CompactNowResult as CoreCompactNowResult,
  CompactorWithManual,
  EventSink,
} from "@ovid/agent-core";
import { isCheckpointRow } from "@ovid/agent-core";
import {
  createCompactionRepository,
  type CompactionActor,
  type CompactionExactObjectReader,
  type CompactionOutcome as DbCompactionOutcome,
  type Db,
  type FoldCheckpointInput,
} from "@ovid/db";
import {
  mainCompactionDiagnosticsSchema,
  subagentCompactedPayloadSchema,
} from "@ovid/shared";

// contextPolicy is a dependency-free module. The package root does not export
// it yet, so consume its built declaration/module directly rather than copying
// the policy or importing a second copy of agent-core's stateful source.
import {
  contextUsageFor,
  isSafeCompactionBoundary,
  nextRequestWithinLimit,
  resolveModelContextProfile,
  shouldCompact,
  type CompactionBoundary,
  type ConfiguredModelContextFallback,
  type ContextUsage,
  type DeterministicFallbackOptions,
  type ModelContextCatalogRow,
  type ModelContextProfile,
} from "../../../packages/agent-core/dist/compaction/contextPolicy.js";

export interface CanonicalCompactionRequestSnapshot {
  /** Exact JSON-ready provider request body; never an AgentRequest with keys/URLs. */
  readonly body: unknown;
  /** Internal rows from which body was canonically serialized. */
  readonly sourceMessages: readonly AgentMessage[];
}

export interface CanonicalCompactionRequest extends CanonicalCompactionRequestSnapshot {
  /** Rebuild the same provider body with only the conversation rows replaced. */
  rebuild(messages: readonly AgentMessage[]): CanonicalCompactionRequestSnapshot;
}

export interface WorkerCompactionResolution {
  /** Canonical main root or current logical-worker attempt lineage. */
  actor: CompactionActor;
  /** Main root run, or the worker's actual current child-turn run. */
  runId: string;
  /**
   * Existing event/mirror scope. Main uses actor.sessionId; a worker uses its
   * evidenced PARENT session, never the child fold session.
   */
  eventSessionId: string;
  /** Actual selected route/deployment id, never an unresolved auto alias. */
  model: string;
  catalog: readonly ModelContextCatalogRow[] | null;
  requestMaxOutputTokens?: number;
  measuredInputTokens?: number | null;
  imageTokenUpperBound?: number;
  request: CanonicalCompactionRequest;
  boundary: CompactionBoundary;
}

export interface WorkerCompactionResolveInput {
  sessionId: string;
  messages: AgentMessage[];
  windowTokens: number;
  foldBoundary?: number;
  manual: boolean;
  focus?: string;
}

export interface CompactionOperationalEventIdentity {
  /** Main session for diagnostics; parent session for worker operations. */
  sessionId: string;
  type: "compaction_completed" | "subagent_compacted";
  compactionId: string;
}

export interface WorkerCompactionIdempotentSink {
  /**
   * An integration MUST implement this as an atomic durable emit-or-dedupe
   * operation (or transactional outbox). "duplicate" is valid only after that
   * exact scoped identity was durably committed. Partial failures must reject.
   * Merely implementing this interface cannot itself provide that guarantee.
   */
  emitOnce(
    identity: CompactionOperationalEventIdentity,
    payload: Record<string, unknown>,
  ): Promise<"emitted" | "duplicate">;
}

export interface WorkerCompactionBinding {
  /** Resolve fresh route, catalog, lineage, and exact request on every call. */
  resolve(
    input: WorkerCompactionResolveInput,
  ): Promise<WorkerCompactionResolution | null>;
  /** Event/trajectory diagnostics only. This runtime has no ordinary chat writer. */
  sink: EventSink;
  /** Required for concurrent exactly-once composition; optional only for the unwired/sequential port. */
  idempotentSink?: WorkerCompactionIdempotentSink;
  now?: () => Date;
}

export interface WorkerCompactionRepository {
  foldCheckpoint(input: FoldCheckpointInput): Promise<DbCompactionOutcome>;
}

export interface CreateWorkerCompactionRuntimeOptions {
  db: Db;
  repository?: WorkerCompactionRepository;
  objects?: CompactionExactObjectReader;
  fallback: ConfiguredModelContextFallback;
}

export type WorkerCompactionOutcome = CoreCompactionOutcome & DbCompactionOutcome;
export type WorkerCompactNowResult = CoreCompactNowResult & DbCompactionOutcome;
export type ManualCompactionInput = Parameters<CompactorWithManual["compactNow"]>[0];

export interface WorkerCompactor extends CompactorWithManual {
  maybeCompact(input: CompactionInput): Promise<WorkerCompactionOutcome>;
  compactNow(input: ManualCompactionInput): Promise<WorkerCompactNowResult>;
}

export type WorkerCompactionErrorCode =
  | "compaction_context_unavailable"
  | "actual_model_unprovable"
  | "actor_lineage_unprovable"
  | "event_scope_unprovable"
  | "canonical_input_unprovable"
  | "next_request_over_limit"
  | "invalid_fold_boundary"
  | "invalid_fold_outcome"
  | "invalid_clock";

export interface WorkerCompactionRunOutcome {
  code: WorkerCompactionErrorCode;
  kind: "context_proof_unavailable" | "context_limit_exceeded" | "composition_invalid";
  /** Required integration interpretation: finish honestly; never send this request. */
  terminal: true;
  providerRequest: "suppress";
  retrySameRequest: false;
  legacyFallback: "forbidden";
}

const PROOF_FAILURE_CODES: ReadonlySet<WorkerCompactionErrorCode> = new Set([
  "compaction_context_unavailable",
  "actual_model_unprovable",
  "actor_lineage_unprovable",
  "event_scope_unprovable",
  "canonical_input_unprovable",
]);

function runOutcome(code: WorkerCompactionErrorCode): WorkerCompactionRunOutcome {
  return {
    code,
    kind: code === "next_request_over_limit"
      ? "context_limit_exceeded"
      : PROOF_FAILURE_CODES.has(code)
        ? "context_proof_unavailable"
        : "composition_invalid",
    terminal: true,
    providerRequest: "suppress",
    retrySameRequest: false,
    legacyFallback: "forbidden",
  };
}

export class WorkerCompactionError extends Error {
  readonly name = "WorkerCompactionError";
  readonly outcome: WorkerCompactionRunOutcome;

  constructor(readonly code: WorkerCompactionErrorCode) {
    super(code);
    this.outcome = runOutcome(code);
  }
}

/** Null means an unrelated error: propagate it; never relabel it or fall back. */
export function workerCompactionOutcomeFor(error: unknown): WorkerCompactionRunOutcome | null {
  return error instanceof WorkerCompactionError ? error.outcome : null;
}

function fail(code: WorkerCompactionErrorCode): never {
  throw new WorkerCompactionError(code);
}

function nonEmpty(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function nonNegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function foldBoundaryOf(input: { messages: AgentMessage[]; foldBoundary?: number }): number {
  const leading = isCheckpointRow(input.messages[0]) ? 1 : 0;
  const requested = input.foldBoundary ?? leading;
  if (!Number.isInteger(requested)) fail("invalid_fold_boundary");
  return Math.min(input.messages.length, Math.max(leading, requested));
}

function sameJson(left: unknown, right: unknown): boolean {
  try {
    return JSON.stringify(left) === JSON.stringify(right);
  } catch {
    return false;
  }
}

function assertRequestSnapshot(
  snapshot: CanonicalCompactionRequestSnapshot,
  sourceMessages: readonly AgentMessage[],
  model: string,
): void {
  if (typeof snapshot !== "object" || snapshot === null) fail("canonical_input_unprovable");
  if (typeof snapshot.body !== "object" || snapshot.body === null || Array.isArray(snapshot.body)) {
    fail("canonical_input_unprovable");
  }
  const body = snapshot.body as Record<string, unknown>;
  // These fields identify the internal AgentRequest container, not a provider
  // JSON body. Never estimate or persist transport credentials as context.
  if (Object.hasOwn(body, "apiKey") || Object.hasOwn(body, "baseUrl")) {
    fail("canonical_input_unprovable");
  }
  if (body.model !== model || !sameJson(snapshot.sourceMessages, sourceMessages)) {
    fail("canonical_input_unprovable");
  }
  try {
    if (JSON.stringify(snapshot.body) === undefined) fail("canonical_input_unprovable");
  } catch {
    fail("canonical_input_unprovable");
  }
}

function assertResolution(
  input: { sessionId: string },
  resolution: WorkerCompactionResolution | null,
): asserts resolution is WorkerCompactionResolution {
  if (resolution === null || !nonEmpty(resolution.runId) || !nonEmpty(resolution.model)) {
    fail("compaction_context_unavailable");
  }
  const selected = resolution.model.trim().toLowerCase();
  if (selected === "auto" || selected === "ovid-cloud/auto") {
    fail("actual_model_unprovable");
  }
  const { actor } = resolution;
  if (
    actor.sessionId !== input.sessionId ||
    !nonEmpty(actor.rootTaskRunId) ||
    (actor.kind !== "main" && actor.kind !== "worker")
  ) {
    fail("actor_lineage_unprovable");
  }
  if (actor.kind === "main") {
    if (
      actor.logicalWorkerId !== null ||
      actor.attemptId !== null ||
      actor.rootTaskRunId !== resolution.runId
    ) {
      fail("actor_lineage_unprovable");
    }
  } else if (
    !nonEmpty(actor.logicalWorkerId) ||
    !nonEmpty(actor.attemptId) ||
    actor.rootTaskRunId === resolution.runId
  ) {
    fail("actor_lineage_unprovable");
  }
  if (
    !nonEmpty(resolution.eventSessionId) ||
    (actor.kind === "main" && resolution.eventSessionId !== actor.sessionId) ||
    (actor.kind === "worker" && resolution.eventSessionId === actor.sessionId)
  ) {
    fail("event_scope_unprovable");
  }
  assertRequestSnapshot(resolution.request, resolution.request.sourceMessages, resolution.model);
}

function fallbackOptions(resolution: WorkerCompactionResolution): DeterministicFallbackOptions {
  return resolution.imageTokenUpperBound === undefined
    ? {}
    : { imageTokenUpperBound: resolution.imageTokenUpperBound };
}

function assertCompleteFold(outcome: DbCompactionOutcome): asserts outcome is DbCompactionOutcome & {
  compactionId: string;
  checkpointId: string;
  cutoffCursor: string;
  contextLimit: number;
  beforeTokens: number;
  afterTokens: number;
  usageSource: ContextUsage["usageSource"];
  continuation: "continuing_existing_task";
} {
  if (
    !outcome.compacted ||
    !nonEmpty(outcome.compactionId) ||
    !nonEmpty(outcome.checkpointId) ||
    !nonEmpty(outcome.cutoffCursor) ||
    !nonNegativeInteger(outcome.contextLimit) ||
    outcome.contextLimit <= 0 ||
    !nonNegativeInteger(outcome.beforeTokens) ||
    !nonNegativeInteger(outcome.afterTokens) ||
    (outcome.usageSource !== "measured" && outcome.usageSource !== "deterministic_fallback") ||
    outcome.continuation !== "continuing_existing_task"
  ) {
    fail("invalid_fold_outcome");
  }
}

/**
 * Compose the durable Task 9 fold with the existing compactor port. An
 * intentionally unbound wrapper is a legacy fake/base compatibility seam only;
 * production composition must always supply a binding. A bound call never
 * falls back to the legacy lossy fold when proof is missing.
 */
export function createWorkerCompactionRuntime(options: CreateWorkerCompactionRuntimeOptions) {
  const repository = options.repository ?? createCompactionRepository(options.db, options.objects);

  function wrapCompactor(
    base: CompactorWithManual,
    binding?: WorkerCompactionBinding,
  ): WorkerCompactor {
    if (binding === undefined) return base;

    const compacting = new Set<string>();
    const emitted = new Set<string>();
    const now = binding.now ?? (() => new Date());

    async function prepare(
      input: WorkerCompactionResolveInput,
    ): Promise<{
      resolution: WorkerCompactionResolution;
      profile: ModelContextProfile;
      usage: ContextUsage;
    }> {
      let resolution: WorkerCompactionResolution | null;
      try {
        resolution = await binding.resolve(input);
      } catch (error) {
        if (error instanceof WorkerCompactionError) throw error;
        fail("compaction_context_unavailable");
      }
      assertResolution(input, resolution);
      assertRequestSnapshot(resolution.request, input.messages, resolution.model);
      const profile = resolveModelContextProfile({
        model: resolution.model,
        catalog: resolution.catalog,
        fallback: options.fallback,
        ...(resolution.requestMaxOutputTokens !== undefined
          ? { requestMaxOutputTokens: resolution.requestMaxOutputTokens }
          : {}),
      });
      const usage = contextUsageFor(
        resolution.request.body,
        resolution.measuredInputTokens,
        fallbackOptions(resolution),
      );
      return { resolution, profile, usage };
    }

    async function alreadyMirrored(identity: CompactionOperationalEventIdentity): Promise<boolean> {
      const rows = await options.db.$client.unsafe(
        "SELECT type FROM session_event_mirror " +
        "WHERE session_id = $1 AND type = $2 AND payload->>'compactionId' = $3 LIMIT 1",
        [identity.sessionId, identity.type, identity.compactionId],
      ) as Array<{ type?: unknown }>;
      return rows.length > 0;
    }

    async function emitOperational(
      resolution: WorkerCompactionResolution,
      outcome: DbCompactionOutcome & {
        compactionId: string;
        checkpointId: string;
        cutoffCursor: string;
        contextLimit: number;
        beforeTokens: number;
        afterTokens: number;
        usageSource: ContextUsage["usageSource"];
        continuation: "continuing_existing_task";
      },
    ): Promise<void> {
      const type: CompactionOperationalEventIdentity["type"] = resolution.actor.kind === "main"
        ? "compaction_completed"
        : "subagent_compacted";
      const identity: CompactionOperationalEventIdentity = {
        sessionId: resolution.eventSessionId,
        type,
        compactionId: outcome.compactionId,
      };
      const emissionKey = JSON.stringify(identity);
      if (emitted.has(emissionKey)) return;
      if (binding.idempotentSink === undefined && await alreadyMirrored(identity)) {
        emitted.add(emissionKey);
        return;
      }
      const at = now();
      if (!Number.isFinite(at.getTime())) fail("invalid_clock");
      const payload: Record<string, unknown> = {
        runId: resolution.runId,
        compactionId: outcome.compactionId,
        checkpointId: outcome.checkpointId,
        ts: at.toISOString(),
        model: resolution.model,
        contextLimit: outcome.contextLimit,
        beforeTokens: outcome.beforeTokens,
        afterTokens: outcome.afterTokens,
        usageSource: outcome.usageSource,
        continuation: outcome.continuation,
      };
      if (resolution.actor.kind === "main") {
        payload.actorKind = "main";
        mainCompactionDiagnosticsSchema.parse({
          type,
          sessionId: resolution.eventSessionId,
          ...payload,
        });
      } else {
        payload.workerId = resolution.actor.logicalWorkerId;
        subagentCompactedPayloadSchema.parse({
          type,
          sessionId: resolution.eventSessionId,
          ...payload,
        });
      }
      // Deliberately no messages.append / ordinary-chat writer. Strict schemas
      // exclude raw prompts, reasoning, request bodies, thoughts, and secrets.
      if (binding.idempotentSink !== undefined) {
        await binding.idempotentSink.emitOnce(identity, payload);
      } else {
        // Sequential suppression only: concurrent wrappers can both pass the
        // lookup, and an append/mirror partial-sink failure can replay a duplicate.
        await binding.sink.emit(type, payload);
      }
      emitted.add(emissionKey);
    }

    async function finishFold(
      outcome: DbCompactionOutcome,
      prepared: {
        resolution: WorkerCompactionResolution;
        profile: ModelContextProfile;
        usage: ContextUsage;
      },
    ): Promise<DbCompactionOutcome> {
      assertCompleteFold(outcome);
      if (
        outcome.contextLimit !== prepared.profile.contextLimit ||
        outcome.beforeTokens !== prepared.usage.beforeTokens ||
        outcome.usageSource !== prepared.usage.usageSource
      ) {
        fail("invalid_fold_outcome");
      }
      await emitOperational(prepared.resolution, outcome);

      // No provider measurement exists for a newly rebuilt request. Recompute
      // deterministic whole-request usage and fail closed before the engine can
      // send an over-budget request or repeatedly fold an unknown image cost.
      const rebuilt = prepared.resolution.request.rebuild(outcome.messages);
      assertRequestSnapshot(rebuilt, outcome.messages, prepared.resolution.model);
      const afterUsage = contextUsageFor(rebuilt.body, undefined, fallbackOptions(prepared.resolution));
      if (!nextRequestWithinLimit({ profile: prepared.profile, usage: afterUsage })) {
        fail("next_request_over_limit");
      }
      return outcome;
    }

    async function maybeCompact(input: CompactionInput): Promise<WorkerCompactionOutcome> {
      const foldBoundary = foldBoundaryOf(input);
      if (compacting.has(input.sessionId)) {
        return { compacted: false, messages: input.messages, foldBoundary };
      }
      compacting.add(input.sessionId);
      try {
        const prepared = await prepare({ ...input, manual: false });
        if (!shouldCompact({
          profile: prepared.profile,
          usage: prepared.usage,
          boundary: prepared.resolution.boundary,
        })) {
          return { compacted: false, messages: input.messages, foldBoundary };
        }

        // Preserve the existing compactor's cost-free relief and base-shaped
        // prune-only outcome. A changed request invalidates measured usage.
        const pruned = await base.pruneOversizedToolResults({
          sessionId: input.sessionId,
          messages: input.messages,
          thresholdTokens: 0,
        });
        let messagesForFold = input.messages;
        if (pruned.pruned > 0) {
          messagesForFold = pruned.messages;
          const snapshot = prepared.resolution.request.rebuild(messagesForFold);
          assertRequestSnapshot(snapshot, messagesForFold, prepared.resolution.model);
          prepared.usage = contextUsageFor(snapshot.body, undefined, fallbackOptions(prepared.resolution));
          if (!shouldCompact({
            profile: prepared.profile,
            usage: prepared.usage,
            boundary: prepared.resolution.boundary,
          })) {
            return { compacted: false, messages: messagesForFold, foldBoundary };
          }
        }

        const outcome = await repository.foldCheckpoint({
          messages: messagesForFold,
          foldBoundary,
          profile: prepared.profile,
          usage: prepared.usage,
          actor: prepared.resolution.actor,
        });
        if (!outcome.compacted) {
          return {
            compacted: false,
            messages: outcome.messages,
            foldBoundary: outcome.foldBoundary,
          };
        }
        return await finishFold(outcome, prepared);
      } finally {
        compacting.delete(input.sessionId);
      }
    }

    async function compactNow(input: ManualCompactionInput): Promise<WorkerCompactNowResult> {
      const foldBoundary = foldBoundaryOf(input);
      const unchanged = (status: string): WorkerCompactNowResult => ({
        compacted: false,
        messages: input.messages,
        narrative: false,
        foldBoundary,
        status,
      });
      if (compacting.has(input.sessionId)) {
        return unchanged("Compaction is already running in this chat.");
      }
      if ((input.focus ?? "").trim() !== "") {
        return unchanged("Focused compaction is unavailable for this checkpoint; history was not folded.");
      }
      compacting.add(input.sessionId);
      try {
        let prepared: Awaited<ReturnType<typeof prepare>>;
        try {
          prepared = await prepare({ ...input, manual: true });
        } catch (error) {
          const code = error instanceof WorkerCompactionError ? error.code : "compaction_context_unavailable";
          return unchanged(`Compaction unavailable (${code}); history was not folded.`);
        }
        if (!isSafeCompactionBoundary(prepared.resolution.boundary)) {
          return unchanged("Compaction requires a terminal pre-model-request boundary; history was not folded.");
        }
        if (!shouldCompact({
          profile: prepared.profile,
          usage: prepared.usage,
          boundary: prepared.resolution.boundary,
        })) {
          return unchanged("Manual lossless compaction currently requires 80% context pressure; history was not folded.");
        }
        const outcome = await repository.foldCheckpoint({
          messages: input.messages,
          foldBoundary,
          profile: prepared.profile,
          usage: prepared.usage,
          actor: prepared.resolution.actor,
        });
        if (!outcome.compacted) {
          return {
            ...unchanged("Nothing to compact yet — at least 4 foldable messages and a retained tail are required."),
            messages: outcome.messages,
            foldBoundary: outcome.foldBoundary,
          };
        }
        const completed = await finishFold(outcome, prepared);
        return {
          ...completed,
          narrative: false,
          status: `Session compacted — lossless checkpoint ${completed.checkpointId}; continuing existing task.`,
        };
      } finally {
        compacting.delete(input.sessionId);
      }
    }

    return {
      maybeCompact,
      compactNow,
      pruneOversizedToolResults: (input) => base.pruneOversizedToolResults(input),
    };
  }

  return { wrapCompactor };
}
