import {
  ModelQuotaExceededError,
  type AgentRequest,
  type AgentResponse,
  type AgentTransport,
  type LegacyModelTransport,
} from "@ovid/agent-core";
import {
  runUsage,
  type Db,
  type QuotaBillingClass,
  type QuotaUsage,
  type RunQuotaService,
} from "@ovid/db";

/** One model call's authoritative usage identity. */
export interface UsageRecord {
  userId: string;
  sessionId: string;
  runId: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
}

export type ModelCallQuota = Pick<
  RunQuotaService,
  "reserveModelCall" | "settleModelCall" | "releaseModelCall"
>;

export interface UsageRecordingIdentity {
  userId: string;
  sessionId: string;
  runId: string;
  billingClass?: QuotaBillingClass;
}

export interface UsageRecordingOptions {
  userId: string;
  sessionId: string;
  runId: string;
  /** Auxiliary/child calls override the root identity through this live binding. */
  current?: () => UsageRecordingIdentity;
  billingClass?: QuotaBillingClass;
  record(row: UsageRecord): Promise<unknown>;
  log?: (message: string) => void;
  quota?: ModelCallQuota;
  inputTokens?: (request: AgentRequest) => number;
  /**
   * Supplies the durable logical-call identity when requests can be rebuilt or
   * replayed outside this decorator. The default is stable for retries of the
   * same request object and current actor/session/run identity.
   */
  reservationKey?: (
    request: AgentRequest,
    identity: UsageRecordingIdentity,
  ) => string;
}

/** The production binding for legacy callers without quota composition. */
export function usageFor(
  db: Db,
  userId: string,
  sessionId: string,
  runId: string,
): UsageRecordingOptions {
  return { userId, sessionId, runId, record: (row) => runUsage.record(db, row) };
}

const DEFAULT_MAX_OUTPUT_TOKENS = 8_192;

type ResolvedUsageIdentity = UsageRecordingIdentity & { billingClass: QuotaBillingClass };
type LegacyRequest = Parameters<LegacyModelTransport["stream"]>[0];
type LegacyReservationIdentity = { userId: string; runId: string };

function currentIdentity(o: UsageRecordingOptions): ResolvedUsageIdentity {
  const current = o.current?.();
  return {
    userId: current?.userId ?? o.userId,
    sessionId: current?.sessionId ?? o.sessionId,
    runId: current?.runId ?? o.runId,
    billingClass: current?.billingClass ?? o.billingClass ?? "ovid_allowance",
  };
}

/**
 * A retry of one logical request reuses its key; a distinct request receives a
 * fresh key. The identity dimension prevents an auxiliary/current-context
 * switch from reusing the root's reservation. Durable reconstruction/replay
 * uses the explicit reservationKey callback instead of relying on object life.
 */
function createReservationKeyAllocator() {
  let sequence = 0;
  const requests = new WeakMap<object, Map<string, string>>();
  return (
    request: object,
    identity: { userId: string; runId: string; sessionId?: string },
  ): string => {
    let identities = requests.get(request);
    if (identities === undefined) {
      identities = new Map<string, string>();
      requests.set(request, identities);
    }
    const identityKey = JSON.stringify([
      identity.userId,
      identity.sessionId ?? null,
      identity.runId,
    ]);
    let key = identities.get(identityKey);
    if (key === undefined) {
      sequence += 1;
      key = `${identity.runId}:model-call:${sequence}`;
      identities.set(identityKey, key);
    }
    return key;
  };
}

function boundedRequest<T extends { maxTokens?: number }>(
  request: T,
): T & { maxTokens: number } {
  return { ...request, maxTokens: request.maxTokens ?? DEFAULT_MAX_OUTPUT_TOKENS };
}

/** Conservative deterministic estimate used only for the pre-call allowance. */
export function estimateAgentRequestTokens(request: AgentRequest): number {
  const serialized = JSON.stringify({
    system: request.system,
    messages: request.messages,
    tools: request.tools,
  });
  return Buffer.byteLength(serialized, "utf8") +
    1_024 + 16 * (request.system.length + request.messages.length + request.tools.length);
}

function estimateLegacyRequestTokens(request: LegacyRequest): number {
  const serialized = JSON.stringify({
    messages: request.messages,
    tools: request.tools ?? [],
  });
  return Buffer.byteLength(serialized, "utf8") +
    1_024 + 16 * (request.messages.length + (request.tools?.length ?? 0));
}

function actualUsage(
  request: AgentRequest,
  usage: NonNullable<AgentResponse["usage"]>,
  billingClass: QuotaBillingClass,
): QuotaUsage {
  return {
    inputTokens: usage.inputTokens,
    outputTokens: usage.outputTokens,
    cacheReadTokens: usage.cacheReadTokens ?? 0,
    cacheWriteTokens: usage.cacheWriteTokens ?? 0,
    requestedModel: request.model,
    ...(usage.providerModel !== undefined ? { providerModel: usage.providerModel } : {}),
    ...(usage.costUsd !== undefined ? { costUsd: usage.costUsd } : {}),
    ...(usage.costSource !== undefined ? { costSource: usage.costSource } : {}),
    billingClass,
  };
}

export function withLegacyQuotaReservations(
  base: LegacyModelTransport,
  o: {
    userId: string;
    runId: string;
    quota: Pick<ModelCallQuota, "reserveModelCall" | "releaseModelCall">;
    billingClass?: QuotaBillingClass;
    inputTokens?: (request: LegacyRequest) => number;
    reservationKey?: (
      request: LegacyRequest,
      identity: LegacyReservationIdentity,
    ) => string;
  },
): LegacyModelTransport {
  const allocateReservationKey = createReservationKeyAllocator();
  return {
    async stream(req, h, signal) {
      const identity = { userId: o.userId, runId: o.runId };
      const request = boundedRequest(req);
      const reservation = await o.quota.reserveModelCall({
        actorUserId: identity.userId,
        runId: identity.runId,
        reservationKey: o.reservationKey?.(req, identity) ?? allocateReservationKey(req, identity),
        inputTokens: (o.inputTokens ?? estimateLegacyRequestTokens)(req),
        maxOutputTokens: request.maxTokens,
        requestedModel: req.model,
        billingClass: o.billingClass ?? "ovid_allowance",
      });
      if (!reservation.ok) {
        throw new ModelQuotaExceededError(reservation.window, reservation.resetsAt);
      }
      try {
        return await base.stream(request, h, signal);
      } finally {
        // Legacy responses expose no usage telemetry. Unknown is not zero.
        await o.quota.releaseModelCall(reservation.reservationId);
      }
    },
  };
}

export function withUsageRecording(base: AgentTransport, o: UsageRecordingOptions): AgentTransport {
  const log = o.log ?? ((message: string) => console.warn(message));
  const allocateReservationKey = createReservationKeyAllocator();
  return {
    apiFormat: base.apiFormat,
    async stream(req, h, signal) {
      const identity = currentIdentity(o);
      if (o.quota !== undefined) {
        const request = boundedRequest(req);
        const reservation = await o.quota.reserveModelCall({
          actorUserId: identity.userId,
          runId: identity.runId,
          reservationKey: o.reservationKey?.(req, identity) ?? allocateReservationKey(req, identity),
          inputTokens: (o.inputTokens ?? estimateAgentRequestTokens)(req),
          maxOutputTokens: request.maxTokens,
          requestedModel: req.model,
          billingClass: identity.billingClass,
        });
        if (!reservation.ok) {
          throw new ModelQuotaExceededError(reservation.window, reservation.resetsAt);
        }
        let res: AgentResponse;
        try {
          // Handlers pass through as-is (onThinkingDelta presence is preserved).
          res = await base.stream(request, h, signal);
        } catch (error) {
          await o.quota.releaseModelCall(reservation.reservationId);
          throw error;
        }
        if (res.usage === null || res.usage === undefined) {
          // Unknown telemetry is not zero usage and must not create a charge.
          await o.quota.releaseModelCall(reservation.reservationId);
          return res;
        }
        try {
          await o.quota.settleModelCall({
            reservationId: reservation.reservationId,
            usage: actualUsage(req, res.usage, identity.billingClass),
          });
        } catch (error) {
          // The provider call already happened. Releasing here would erase its
          // bounded consumption from the ledger. Keep the reservation pending
          // for idempotent settlement/recovery instead of reporting no call.
          log(`[worker] model usage settlement pending (run ${identity.runId}): ${error instanceof Error ? error.name : "unknown"}`);
          throw error;
        }
        return res;
      }

      const res = await base.stream(req, h, signal);
      const usage = res.usage;
      if (usage !== null && usage !== undefined) {
        try {
          await o.record({
            userId: identity.userId,
            sessionId: identity.sessionId,
            runId: identity.runId,
            model: req.model,
            inputTokens: usage.inputTokens ?? 0,
            outputTokens: usage.outputTokens ?? 0,
            cacheReadTokens: usage.cacheReadTokens ?? 0,
            cacheWriteTokens: usage.cacheWriteTokens ?? 0,
          });
        } catch (err) {
          log(
            `[worker] run_usage record failed (run ${identity.runId}): ${err instanceof Error ? err.message : String(err)}`,
          );
        }
      }
      return res;
    },
  };
}
