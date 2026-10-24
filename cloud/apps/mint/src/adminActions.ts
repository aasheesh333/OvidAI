import { randomUUID } from "node:crypto";
import { isIP } from "node:net";
import { schema, type Db } from "@ovid/db";
import type { LiteLlmAdmin } from "./litellmAdmin.js";

/** Separately authorized administrative actions; no client identity is an admin. */
export class AdminActionError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
    this.name = "AdminActionError";
  }
}

export type AdminPlatform = "android" | "web";
export type AdminOutcome =
  | { status: "succeeded"; generation?: number; plan?: string }
  | { status: "failed" };

export interface AdminActor {
  actor: string;
  /** Trusted proxy/socket resolution only; never an action-body field. */
  ip?: string;
}

export interface AdminAuditEntry {
  action: "block" | "unblock" | "rotate-key" | "reset-anomaly-rate" | "adjust-plan";
  actor: string;
  target: { uid: string; platform?: AdminPlatform };
  reason: string;
  time: string;
  outcome: AdminOutcome;
  ip?: string;
}

export interface ProvisionedKeySnapshot {
  /** LiteLLM's hashed token id; never an action response or audit value. */
  keyId: string;
  /** Existing mint storage needs this to restore a reference on failed rotation. */
  plaintext: string;
  generation: number;
}

export interface AdminActionsDeps {
  authorize(input: {
    authorization: string;
    action: AdminAuditEntry["action"];
    target: { uid: string; platform?: AdminPlatform };
  }): Promise<string | AdminActor>;
  appendAudit(entry: AdminAuditEntry): Promise<void>;
  setBlocked(input: { uid: string; blocked: boolean }): Promise<void>;
  rotateKey(input: { uid: string; platform: AdminPlatform }): Promise<{ generation: number }>;
  resetAnomalyAndRate(input: { uid: string }): Promise<void>;
  adjustPlan(input: { uid: string; plan: string }): Promise<void>;
  now?: () => Date;
  /** Optional structured sink; receives the same bounded record as the audit. */
  log?: (entry: AdminAuditEntry) => void;
}

interface ActionInput {
  authorization: string;
  uid: string;
  reason: string;
}

function safeIdentifier(value: string, label: string): string {
  const trimmed = value.trim();
  if (!/^[A-Za-z0-9][A-Za-z0-9_.:@-]{0,127}$/.test(trimmed)) {
    throw new AdminActionError(400, `${label} is invalid`);
  }
  return trimmed;
}

function safeReason(value: string): string {
  const reason = value.trim();
  if (
    reason.length === 0 ||
    reason.length > 200 ||
    /[\x00-\x1f\x7f]/.test(reason) ||
    /(?:\bsk-|bearer\s|https?:\/\/|api[_-]?key|access[_-]?token|signed[_-]?url|base[_-]?url|secret|signature=)/i.test(reason)
  ) {
    throw new AdminActionError(400, "reason is invalid or contains sensitive content");
  }
  return reason;
}

function safePlan(value: string): string {
  if (!/^[a-z0-9][a-z0-9_-]{0,31}$/.test(value)) {
    throw new AdminActionError(400, "plan is invalid");
  }
  return value;
}

export function createAdminActions(deps: AdminActionsDeps) {
  const now = () => new Date((deps.now ?? (() => new Date()))().getTime());

  async function actorFor(
    input: ActionInput,
    action: AdminAuditEntry["action"],
    target: AdminAuditEntry["target"],
  ): Promise<AdminActor> {
    try {
      const resolved = await deps.authorize({ authorization: input.authorization, action, target });
      const principal = typeof resolved === "string" ? { actor: resolved } : resolved;
      if (
        !/^[A-Za-z0-9][A-Za-z0-9_.:@-]{0,127}$/.test(principal.actor) ||
        (principal.ip !== undefined && isIP(principal.ip) === 0)
      ) {
        throw new AdminActionError(403, "not an administrator");
      }
      return {
        actor: principal.actor,
        ...(principal.ip === undefined ? {} : { ip: principal.ip }),
      };
    } catch (error) {
      if (error instanceof AdminActionError && error.status === 401) {
        throw new AdminActionError(401, "missing admin authorization");
      }
      // Authorizer messages can contain credentials or privileged endpoints.
      // Only the status crosses this boundary; public text is always fixed.
      throw new AdminActionError(403, "not an administrator");
    }
  }

  async function execute<T, V>({
    input,
    action,
    target,
    effect,
    outcome,
    result,
  }: {
    input: ActionInput;
    action: AdminAuditEntry["action"];
    target: AdminAuditEntry["target"];
    effect: (uid: string) => Promise<V>;
    outcome: (value: V) => AdminOutcome;
    result: (value: V) => T;
  }): Promise<T> {
    const safeTarget = {
      uid: safeIdentifier(input.uid, "uid"),
      ...(target.platform === undefined ? {} : { platform: target.platform }),
    } as AdminAuditEntry["target"];
    const principal = await actorFor(input, action, safeTarget);
    const reason = safeReason(input.reason);
    const base = {
      action,
      actor: principal.actor,
      target: safeTarget,
      reason,
      time: now().toISOString(),
      ...(principal.ip === undefined ? {} : { ip: principal.ip }),
    } as const;

    let value: V;
    try {
      value = await effect(safeTarget.uid);
    } catch {
      const failed: AdminAuditEntry = { ...base, outcome: { status: "failed" } };
      try {
        await deps.appendAudit(failed);
        deps.log?.(failed);
      } catch {
        // The original privileged/provider error is never substituted into a
        // response or log. The caller still receives a failed outcome.
      }
      throw new AdminActionError(502, "admin action failed");
    }

    const succeeded: AdminAuditEntry = { ...base, outcome: outcome(value) };
    try {
      await deps.appendAudit(succeeded);
    } catch {
      // A side effect without its required durable audit is not reported as a
      // successful administrative action.
      throw new AdminActionError(502, "admin audit failed");
    }
    try {
      deps.log?.(succeeded);
    } catch {
      // The append-only audit is authoritative; a secondary log sink cannot
      // turn a completed action into a misleading client failure.
    }
    return result(value);
  }

  return {
    async block(input: ActionInput): Promise<{ ok: true }> {
      return execute({
        input,
        action: "block",
        target: { uid: input.uid },
        effect: (uid) => deps.setBlocked({ uid, blocked: true }),
        outcome: () => ({ status: "succeeded" }),
        result: () => ({ ok: true }),
      });
    },

    async unblock(input: ActionInput): Promise<{ ok: true }> {
      return execute({
        input,
        action: "unblock",
        target: { uid: input.uid },
        effect: (uid) => deps.setBlocked({ uid, blocked: false }),
        outcome: () => ({ status: "succeeded" }),
        result: () => ({ ok: true }),
      });
    },

    async rotateKey(input: ActionInput & { platform: AdminPlatform }): Promise<{
      ok: true;
      platform: AdminPlatform;
      generation: number;
    }> {
      if (input.platform !== "android" && input.platform !== "web") {
        throw new AdminActionError(400, "platform is invalid");
      }
      return execute({
        input,
        action: "rotate-key",
        target: { uid: input.uid, platform: input.platform },
        effect: async (uid) => {
          const rotated = await deps.rotateKey({ uid, platform: input.platform });
          if (!Number.isSafeInteger(rotated.generation) || rotated.generation < 1) {
            throw new AdminActionError(502, "invalid rotation generation");
          }
          return rotated;
        },
        outcome: ({ generation }) => ({ status: "succeeded", generation }),
        result: ({ generation }) => ({ ok: true, platform: input.platform, generation }),
      });
    },

    async resetAnomalyAndRate(input: ActionInput): Promise<{ ok: true }> {
      return execute({
        input,
        action: "reset-anomaly-rate",
        target: { uid: input.uid },
        effect: (uid) => deps.resetAnomalyAndRate({ uid }),
        outcome: () => ({ status: "succeeded" }),
        result: () => ({ ok: true }),
      });
    },

    async adjustPlan(input: ActionInput & { plan: string }): Promise<{ ok: true; plan: string }> {
      const plan = safePlan(input.plan);
      return execute({
        input,
        action: "adjust-plan",
        target: { uid: input.uid },
        effect: (uid) => deps.adjustPlan({ uid, plan }),
        outcome: () => ({ status: "succeeded", plan }),
        result: () => ({ ok: true, plan }),
      });
    },
  };
}

export interface AdminKeyRotatorDeps {
  litellm: Pick<LiteLlmAdmin, "keyGenerate" | "keyDelete">;
  store: {
    read(uid: string, platform: AdminPlatform): Promise<ProvisionedKeySnapshot | null>;
    write(uid: string, platform: AdminPlatform, value: ProvisionedKeySnapshot): Promise<void>;
  };
  /** Reuse mint's current budget/model/team body builder at composition time. */
  creationBody(input: { uid: string; platform: AdminPlatform }): Promise<Record<string, unknown>>;
}

/**
 * Server-side generate → install → revoke lifecycle. Replacement material is
 * written only through the injected mint store and is absent from the result.
 * A failed old-key revoke restores the old reference and removes the unused
 * replacement when possible; it never returns a false generation success.
 */
export function createAdminKeyRotator(deps: AdminKeyRotatorDeps) {
  const deleteStatus = async (keyId: string): Promise<number> => {
    try {
      return await deps.litellm.keyDelete([keyId]);
    } catch {
      return 0;
    }
  };
  const revoked = (status: number): boolean => (status >= 200 && status < 300) || status === 404;

  return async (input: { uid: string; platform: AdminPlatform }): Promise<{ generation: number }> => {
    try {
      const previous = await deps.store.read(input.uid, input.platform);
      // Generation preflight is before creationBody/keyGenerate/store writes or
      // revokes: corrupt storage must never trigger privileged key churn.
      if (
        previous !== null &&
        (!Number.isSafeInteger(previous.generation) || previous.generation < 1)
      ) {
        throw new Error("invalid stored generation");
      }
      const generation = (previous?.generation ?? 0) + 1;
      if (!Number.isSafeInteger(generation) || generation < 1) {
        throw new Error("invalid next generation");
      }
      const body = await deps.creationBody(input);
      const created = await deps.litellm.keyGenerate(body);
      const keyId = created.token ?? created.key;
      if (created.key === "" || keyId === "" || keyId === previous?.keyId) {
        if (keyId !== "" && keyId !== previous?.keyId) await deleteStatus(keyId);
        throw new Error("invalid rotation result");
      }
      const replacement: ProvisionedKeySnapshot = {
        keyId,
        plaintext: created.key,
        generation,
      };
      try {
        await deps.store.write(input.uid, input.platform, replacement);
      } catch (error) {
        await deleteStatus(keyId);
        throw error;
      }

      if (previous !== null && !revoked(await deleteStatus(previous.keyId))) {
        let restored = false;
        try {
          await deps.store.write(input.uid, input.platform, previous);
          restored = true;
        } catch {
          // Keep the new reference if restoration itself failed; do not delete
          // the only credential the store can still reach.
        }
        if (restored) await deleteStatus(keyId);
        throw new Error("old key revocation failed");
      }
      return { generation };
    } catch (error) {
      if (error instanceof AdminActionError) throw error;
      throw new AdminActionError(502, "key rotation failed");
    }
  };
}

/** Existing mint_audit stores reason/outcome in its JSONB before/after columns. */
export function createPostgresAdminAudit(
  db: Db,
  id: () => string = randomUUID,
): (entry: AdminAuditEntry) => Promise<void> {
  return async (entry) => {
    await db.insert(schema.mintAudit).values({
      id: id(),
      at: new Date(entry.time),
      actor: entry.actor,
      action: entry.action,
      target: { ...entry.target },
      before: { reason: entry.reason },
      after: { ...entry.outcome },
      ip: entry.ip ?? null,
    });
  };
}
