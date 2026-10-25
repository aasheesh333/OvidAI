import { randomUUID } from "node:crypto";
import { isIP } from "node:net";
import { billingUsers } from "@ovid/db";
import { PLAN_TIERS } from "@ovid/shared";
import {
  AdminActionError,
  createAdminActions,
  createAdminKeyRotator,
  createPostgresAdminAudit,
  type AdminActor,
  type AdminKeyRotatorDeps,
  type AdminPlatform,
  type ProvisionedKeySnapshot,
} from "./adminActions.js";
import { setKeyBlocked } from "./antiAbuse.js";
import { HttpContractError, type MintDeps } from "./app.js";
import { createTierSink, type TierSink } from "./billing/tierSink.js";
import { createProtocolKeyLifecycle } from "./billing/keyLifecycle.js";
import { catalogFor } from "./catalog.js";
import { litellmMintOrGet, webTeamId } from "./keyMint.js";
import { createProjection, type Projection } from "./projection.js";
import { requireAdmin } from "./adminRoutes.js";
import {
  currentBillingProjectionGeneration,
  dropUsageCache,
  effectiveTier,
  executeBillingRemoteOperation,
  isoUtc,
  poolRateLimits,
  reapplyUser,
  tierBudget,
  withBillingAccountWrite,
} from "./windows.js";

export type ComposedAdminActions = ReturnType<typeof createAdminActions>;

/**
 * Existing-owner seams. Defaults stay on mint's canonical implementations;
 * the gateway anomaly/rate reset has no mint-local authority and is required
 * for that action. Small structural seams keep external systems out of tests.
 */
export interface AdminCompositionPorts {
  projection?: Pick<Projection, "publishUserState" | "publishUserTier">;
  /** Clears gateway-owned IP observations and UID rate buckets, not IP-shared state. */
  resetAnomalyAndRate?: (input: { uid: string }) => Promise<void>;
  tierSink?: TierSink;
  reapplyUser?: (uid: string) => Promise<unknown>;
  creationBody?: AdminKeyRotatorDeps["creationBody"];
  /** The billing account writer; supplied fakes must preserve its serialization contract. */
  accountWrite?: <T>(uid: string, operation: () => Promise<T>) => Promise<T>;
}

export interface AdminComposition {
  /** Bind only route-resolved proxy/socket metadata, never an action-body field. */
  forRequest(context: { trustedRequestIp: string }): ComposedAdminActions;
}

const PUBLIC_ERRORS = new Map<string, { status: number; detail: string }>([
  ["400:uid is invalid", { status: 400, detail: "uid is invalid" }],
  ["400:platform is invalid", { status: 400, detail: "platform is invalid" }],
  ["400:plan is invalid", { status: 400, detail: "plan is invalid" }],
  ["400:reason is invalid or contains sensitive content", {
    status: 400,
    detail: "reason is invalid or contains sensitive content",
  }],
  ["401:missing admin authorization", { status: 401, detail: "missing admin authorization" }],
  ["403:not an administrator", { status: 403, detail: "not an administrator" }],
  ["502:admin action failed", { status: 502, detail: "admin action failed" }],
  ["502:admin audit failed", { status: 502, detail: "admin audit failed" }],
  ["503:admin anomaly/rate reset is not configured", {
    status: 503,
    detail: "admin anomaly/rate reset is not configured",
  }],
]);

/** Route boundary: only exact, known public pairs; all other text is discarded. */
export function toAdminHttpError(error: unknown): HttpContractError {
  if (error instanceof AdminActionError) {
    const known = PUBLIC_ERRORS.get(`${error.status}:${error.message}`);
    if (known !== undefined) return new HttpContractError(known.status, known.detail);
  }
  return new HttpContractError(500, "admin action failed");
}

function public400(message: string): AdminActionError {
  return new AdminActionError(400, message);
}

function missingResetPort(): AdminActionError {
  return new AdminActionError(503, "admin anomaly/rate reset is not configured");
}

const SAFE_REASON_CODES = new Set([
  "confirmed-abuse",
  "appeal-accepted",
  "false-positive",
  "support-grant",
  "first-key-recovery",
]);

/**
 * Structured reason codes, not free text. This is deliberately an allowlist:
 * no URL parser or secret-regex can prove that arbitrary operator prose is
 * non-sensitive. Only known constant text (or a numeric incident id) can reach
 * the reviewed service's audit/log records. Everything else is rejected with
 * the fixed public 400 before any effect or durable audit.
 */
function safeAuditReason(value: unknown): string {
  const reason = typeof value === "string" ? value.trim() : "";
  if (SAFE_REASON_CODES.has(reason) || /^incident-[0-9]{1,12}$/.test(reason)) return reason;
  throw public400("reason is invalid or contains sensitive content");
}

function keyNames(uid: string, platform: AdminPlatform): {
  id: string;
  plaintext: string;
  generation: string;
  lock: string;
} {
  const ns = platform === "web" ? "web:" : "";
  return {
    id: `user:${uid}:${ns}keyid`,
    plaintext: `user:${uid}:${ns}key`,
    generation: `user:${uid}:${ns}key_generation`,
    lock: `mintlock:${ns}${uid}`,
  };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

interface ActionInput {
  authorization: string;
  reason: string;
}

/**
 * The only composition between owner routes and the reviewed action service.
 * It adds no Firebase identity, ban authority, entitlement ledger, key response
 * field, or privileged logging sink. Create it once so its queues are shared.
 */
export function createAdminComposition(
  deps: MintDeps,
  ports: AdminCompositionPorts = {},
): AdminComposition {
  const projection = ports.projection ?? createProjection({ db: deps.db, redis: deps.redis });
  const resetAnomalyAndRate = ports.resetAnomalyAndRate;
  const applyTier = ports.reapplyUser ?? ((uid: string) => reapplyUser(deps, uid));
  const tierSink = ports.tierSink ?? createTierSink({
    db: deps.db,
    redis: deps.redis,
    projection,
    reapplyUser: applyTier,
  });
  const accountWrite = ports.accountWrite ?? (<T>(
    uid: string,
    operation: () => Promise<T>,
  ): Promise<T> => withBillingAccountWrite(deps, uid, operation));
  const appendAudit = createPostgresAdminAudit(deps.db);
  const rotationTails = new Map<string, Promise<void>>();

  async function setBlocked(input: { uid: string; blocked: boolean }): Promise<void> {
    const { uid, blocked } = input;
    // Ban and rotation join the SAME per-UID billing/mint protocol. A ban can
    // never enumerate only the old key while a replacement is being installed.
    await accountWrite(uid, async () => {
      const generation = currentBillingProjectionGeneration();
      if (generation === undefined) throw new Error("ban generation unavailable");
      const at = isoUtc(new Date((deps.clock ?? (() => new Date()))().getTime()));
      // Match adminRoutes: unban never inserts a row for a typo'd uid.
      if (!(await billingUsers.setBannedForRefresh(
        deps.db,
        uid,
        blocked,
        blocked ? "admin" : "",
        at,
        generation,
      ))) {
        throw new Error("stale ban generation");
      }

      let projectionFailed = false;
      let remoteFailed = false;
      try {
        await projection.publishUserState(uid, { clearBan: !blocked });
      } catch {
        projectionFailed = true;
      }
      try {
        await setKeyBlocked(deps, uid, blocked);
      } catch {
        // The canonical operation records unresolved remote work. Never turn it
        // into a successful action or expose its provider error.
        remoteFailed = true;
      }

      if (projectionFailed || remoteFailed) {
        if (!blocked) {
          // Unblock is security-sensitive: any unresolved half means restore
          // the prior standing, then prove re-blocking again when possible.
          // Compensation failures remain failures and durable remote intents;
          // they are never converted to success or logged with provider text.
          try {
            await billingUsers.setBannedForRefresh(deps.db, uid, true, "admin", at, generation);
          } catch {
            // Keep attempting live projection/key recovery below.
          }
          try {
            await projection.publishUserState(uid, { clearBan: false });
          } catch {
            // The durable ban remains authoritative; still re-block keys.
          }
          try {
            await setKeyBlocked(deps, uid, true);
          } catch {
            // The canonical unresolved outbox is the recovery handoff.
          }
        }
        throw new Error("admin standing projection unresolved");
      }
    });
  }

  const creationBody: AdminKeyRotatorDeps["creationBody"] = ports.creationBody ?? (async (input) => {
    const tier = await effectiveTier(deps, input.uid);
    const [{ budget, duration }, limits, catalog] = await Promise.all([
      tierBudget(deps, input.uid, tier),
      poolRateLimits(deps, input.uid),
      catalogFor(deps),
    ]);
    const models = Object.keys(catalog.groups);
    if (models.length === 0) throw new Error("public model scope unavailable");
    if (!models.includes("ovid-image")) models.push("ovid-image");
    const body: Record<string, unknown> = {
      user_id: input.uid,
      max_budget: budget,
      budget_duration: duration,
      metadata: { tier, ovid_uid: input.uid, platform: input.platform },
      ...limits,
      models,
    };
    if (input.platform === "web") body.team_id = await webTeamId(deps);
    return body;
  });

  const store: AdminKeyRotatorDeps["store"] = {
    async read(uid, platform): Promise<ProvisionedKeySnapshot | null> {
      const names = keyNames(uid, platform);
      const [keyId, plaintext, rawGeneration] = await Promise.all([
        deps.redis.get(names.id),
        deps.redis.get(names.plaintext),
        deps.redis.get(names.generation),
      ]);
      if (keyId === null && plaintext === null && rawGeneration === null) return null;
      if (keyId === null || plaintext === null || keyId === "" || plaintext === "") {
        throw new Error("incomplete stored key reference");
      }
      // Existing pre-rotation keys are generation 1. Once present, malformed
      // generation state fails preflight instead of causing privileged churn.
      const generation = rawGeneration === null
        ? 1
        : /^[1-9]\d*$/.test(rawGeneration)
          ? Number(rawGeneration)
          : Number.NaN;
      return { keyId, plaintext, generation };
    },

    async write(uid, platform, value): Promise<void> {
      const names = keyNames(uid, platform);
      // One Redis evaluation installs id + plaintext + generation atomically.
      const generation = currentBillingProjectionGeneration();
      if (generation === undefined) throw new Error("key store generation unavailable");
      const result = await deps.redis.eval(
        `if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
         redis.call('SET', KEYS[2], ARGV[2])
         redis.call('SET', KEYS[3], ARGV[3])
         redis.call('SET', KEYS[4], ARGV[4])
         return 1`,
        4,
        `user:${uid}:billing_refresh_generation`,
        names.id,
        names.plaintext,
        names.generation,
        String(generation),
        value.keyId,
        value.plaintext,
        String(value.generation),
      );
      if (Number(result) !== 1) throw new Error("key store write failed");
    },
  };

  /** Read the durable/live ban and old key state; never infer it from a body. */
  async function mustBlockReplacement(uid: string, platform: AdminPlatform): Promise<boolean> {
    const names = keyNames(uid, platform);
    const [rows, redisBan, keyId] = await Promise.all([
      deps.db.$client`
        SELECT banned_at IS NOT NULL AS banned FROM users WHERE uid = ${uid}`,
      deps.redis.get(`user:${uid}:banned`),
      deps.redis.get(names.id),
    ]);
    const durableBan = (rows as Array<{ banned?: unknown }>)[0]?.banned === true;
    if (durableBan || (redisBan !== null && redisBan !== "")) return true;
    if (keyId === null || keyId === "") return false;

    const { status, info } = await deps.litellm.keyInfoStatus(keyId);
    if (status === 404) return false;
    // Only 404 is terminal. Auth failures/outages must not rotate into a
    // definitely usable replacement or be treated as an unblocked old key.
    if (status !== 200 || info === null || typeof info.blocked !== "boolean") {
      throw new Error("key block state unavailable");
    }
    return info.blocked;
  }

  async function generateReplacement(
    input: { uid: string; platform: AdminPlatform },
    body: Record<string, unknown>,
  ): Promise<{ key: string; token?: string }> {
    const blocked = await mustBlockReplacement(input.uid, input.platform);
    const litellm = Object.create(deps.litellm) as MintDeps["litellm"];
    litellm.keyGenerate = (creation) =>
      deps.litellm.keyGenerate(blocked ? { ...creation, blocked: true } : creation);
    // Ask for a blocked key at creation AND verify that state independently.
    // The durable desired body remains unchanged, so a provider that ignores
    // the creation flag is caught by the explicit block operation below.
    const lifecycle = createProtocolKeyLifecycle({ ...deps, litellm }, input.uid);
    const created = await lifecycle.keyGenerate(body);
    const keyId = created.token ?? created.key;
    if (blocked) {
      // The replacement is still server-local and uninstalled. Verify its
      // restrictive state before createAdminKeyRotator may persist a reference.
      try {
        await executeBillingRemoteOperation(
          deps,
          input.uid,
          "key",
          keyId,
          { key: keyId },
          { effect: "block" },
        );
        // The generic protocol accepts terminal-404 for block/unblock, but a
        // deleted replacement is NOT a successful rotation. Require a fresh
        // live blocked===true readback before returning to the store/revoke
        // lifecycle. Unknown/deleted/unblocked states all take cleanup+failure.
        const current = await deps.litellm.keyInfoStatus(keyId);
        if (current.status !== 200 || current.info?.blocked !== true) {
          throw new Error("replacement key block readback unresolved");
        }
      } catch {
        // Do not leave a definitely usable uninstalled credential behind when
        // the required block is unresolved. Cleanup is also readback-verified;
        // if it remains unresolved, the action is still a failure, never success.
        try {
          await lifecycle.keyDelete([keyId]);
        } catch {
          // The canonical unresolved outbox remains the recovery handoff.
        }
        throw new Error("replacement key block unresolved");
      }
    }
    return created;
  }

  async function withMintLock<T>(
    input: { uid: string; platform: AdminPlatform },
    operation: () => Promise<T>,
  ): Promise<T> {
    const names = keyNames(input.uid, input.platform);
    const owner = randomUUID();
    const pollMs = deps.mintLock?.pollMs ?? 250;
    const polls = deps.mintLock?.polls ?? 20;
    for (let attempt = 0; attempt <= polls; attempt += 1) {
      const acquired = await deps.redis.set(names.lock, owner, "EX", 30, "NX");
      if (acquired === "OK") {
        try {
          return await operation();
        } finally {
          // Compare-and-delete: an expired lock must not delete its next owner.
          await deps.redis.eval(
            `if redis.call('GET', KEYS[1]) == ARGV[1] then
               return redis.call('DEL', KEYS[1])
             end
             return 0`,
            1,
            names.lock,
            owner,
          );
        }
      }
      if (attempt < polls) await sleep(pollMs);
    }
    throw new Error("key rotation lock unavailable");
  }

  async function generateFirstKey(
    input: { uid: string; platform: AdminPlatform },
    body: Record<string, unknown>,
  ): Promise<{ key: string; token?: string }> {
    const blocked = await mustBlockReplacement(input.uid, input.platform);
    const created = await deps.litellm.keyGenerate(blocked ? { ...body, blocked: true } : body);
    if (blocked) {
      const keyId = created.token ?? created.key;
      try {
        if (keyId === "") throw new Error("missing first-key target");
        // The canonical mint operation installs its reference only after this
        // wrapper returns. Block and read back BEFORE that installation, so a
        // banned first key is never registered as a definitely usable key.
        const status = await deps.litellm.keyBlock(keyId);
        if (status < 200 || status >= 300) throw new Error("first-key block unresolved");
        const current = await deps.litellm.keyInfoStatus(keyId);
        if (current.status !== 200 || current.info?.blocked !== true) {
          throw new Error("first-key block readback unresolved");
        }
      } catch {
        try {
          await deps.litellm.keyDelete([keyId]);
        } catch {
          // Best-effort cleanup; the outer canonical generate remains unresolved.
        }
        throw new Error("first-key block unresolved");
      }
    }
    return created;
  }

  async function provisionFirstKey(input: {
    uid: string;
    platform: AdminPlatform;
  }): Promise<{ generation: number }> {
    // Empty storage is canonical mint, never a generation-zero direct create.
    // Wrap only transport generation to prove blocked state before canonical
    // registration; breaker, registry, provisioning and budget stay canonical.
    const litellm = Object.create(deps.litellm) as MintDeps["litellm"];
    litellm.keyGenerate = (body) => generateFirstKey(input, body);
    const firstDeps: MintDeps = { ...deps, litellm };
    const tier = await effectiveTier(deps, input.uid);
    await litellmMintOrGet(firstDeps, input.uid, tier, input.platform, deps.mintLock);
    if (await mustBlockReplacement(input.uid, input.platform)) {
      await setKeyBlocked(deps, input.uid, true);
    }
    const generationKey = keyNames(input.uid, input.platform).generation;
    const generation = currentBillingProjectionGeneration();
    if (generation === undefined) throw new Error("first-key generation unavailable");
    const initialized = await deps.redis.eval(
      `if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
       local current = redis.call('GET', KEYS[2])
       if current and current ~= '1' then return 0 end
       redis.call('SET', KEYS[2], '1', 'NX')
       return redis.call('GET', KEYS[2]) == '1' and 1 or 0`,
      2,
      `user:${input.uid}:billing_refresh_generation`,
      generationKey,
      String(generation),
    );
    if (Number(initialized) !== 1) throw new Error("first-key generation conflict");
    return { generation: 1 };
  }

  async function rotateKey(input: {
    uid: string;
    platform: AdminPlatform;
  }): Promise<{ generation: number }> {
    const queueKey = `${input.uid}\u0000${input.platform}`;
    const previous = rotationTails.get(queueKey) ?? Promise.resolve();
    let release!: () => void;
    const current = new Promise<void>((resolve) => { release = resolve; });
    const tail = previous.then(() => current);
    rotationTails.set(queueKey, tail);
    await previous;
    try {
      return await accountWrite(input.uid, async () => {
        const existing = await store.read(input.uid, input.platform);
        if (existing === null) return provisionFirstKey(input);
        return withMintLock(input, () => {
          const rotator = createAdminKeyRotator({
            litellm: {
              keyGenerate: (body) => generateReplacement(input, body),
              keyDelete: (keys) => createProtocolKeyLifecycle(deps, input.uid).keyDelete(keys),
            },
            store,
            creationBody: async (rotationInput) => {
              const [body, previous] = await Promise.all([
                creationBody(rotationInput),
                store.read(rotationInput.uid, rotationInput.platform),
              ]);
              if (previous === null) throw new Error("rotation storage changed");
              return {
                ...body,
                key_alias: `ovid:rotate:${rotationInput.uid}:${rotationInput.platform}:${previous.generation + 1}`,
              };
            },
          });
          return rotator(input);
        });
      });
    } finally {
      release();
      if (rotationTails.get(queueKey) === tail) rotationTails.delete(queueKey);
    }
  }

  return {
    forRequest({ trustedRequestIp }) {
      async function ownerActor(authorization: string): Promise<AdminActor> {
        try {
          requireAdmin(deps.env, authorization);
        } catch (error) {
          if (error instanceof HttpContractError && error.status === 401) {
            throw new AdminActionError(401, "missing admin authorization");
          }
          throw new AdminActionError(403, "not an administrator");
        }
        if (isIP(trustedRequestIp) === 0) {
          throw new AdminActionError(403, "not an administrator");
        }
        return { actor: "master-key", ip: trustedRequestIp };
      }

      function serviceFor(actor: AdminActor): ComposedAdminActions {
        return createAdminActions({
          // Every public method below calls ownerActor BEFORE this service is
          // entered, so uid/platform/plan/reason/configuration checks cannot
          // bypass the real requireAdmin gate. The reviewed service repeats
          // that same owner check at its own authorize boundary.
          authorize: async ({ authorization }) => {
            await ownerActor(authorization);
            return actor;
          },
          appendAudit,
          setBlocked,
          rotateKey,
          async resetAnomalyAndRate({ uid }) {
            if (resetAnomalyAndRate === undefined) throw missingResetPort();
            await resetAnomalyAndRate({ uid });
            // IP-shared counters, spend, bans and keys remain untouched.
            await deps.redis.del(`abuse:uid:${uid}`);
          },
          async adjustPlan({ uid, plan }) {
            // The billing owner's sole users.tier -> projection -> LiteLLM sink.
            await tierSink(uid, plan, null);
            await dropUsageCache(deps, [uid]);
          },
          ...(deps.clock === undefined ? {} : { now: deps.clock }),
        });
      }

      async function authorized<TInput extends ActionInput, T>(
        input: TInput,
        operation: (service: ComposedAdminActions, safeInput: TInput) => Promise<T>,
      ): Promise<T> {
        const actor = await ownerActor(input.authorization);
        const safeInput = { ...input, reason: safeAuditReason(input.reason) };
        return operation(serviceFor(actor), safeInput);
      }

      return {
        block: (input) => authorized(input, (service, safe) => service.block(safe)),
        unblock: (input) => authorized(input, (service, safe) => service.unblock(safe)),
        rotateKey: (input) => authorized(input, (service, safe) => service.rotateKey(safe)),
        resetAnomalyAndRate: (input) => authorized(input, (service, safe) => {
          // Auth and actor/IP validation have already run; no unauthenticated
          // caller can discover this configuration state.
          if (resetAnomalyAndRate === undefined) throw missingResetPort();
          return service.resetAnomalyAndRate(safe);
        }),
        adjustPlan: (input) => authorized(input, (service, safe) => {
          // Canonical-id validation is likewise strictly post-authorization.
          if (!(PLAN_TIERS as readonly string[]).includes(input.plan)) {
            throw public400("plan is invalid");
          }
          return service.adjustPlan(safe);
        }),
      };
    },
  };
}
