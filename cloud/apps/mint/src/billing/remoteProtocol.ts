import {
  createBillingRemoteAuthority,
  createLiteLlmBillingTransport,
  billingRemoteBody,
  type BillingRemoteEffect,
  type BillingRemoteExecuteOptions,
  type BillingRemoteExecution,
  type BillingRemoteOperation,
  type BillingRemoteOperationKind,
  type BillingRemoteSendResult,
  type BillingRemoteTransport,
} from "@ovid/db";
import type { MintDeps } from "../app.js";

export interface MintRemoteOperationOptions {
  effect?: BillingRemoteEffect;
  idempotencyKey?: string;
  restartBudgetClock?: boolean;
}

/** Build the complete persisted projection; no plaintext key field is allowed. */
export function mintRemoteOperation(
  uid: string,
  generation: number,
  kind: BillingRemoteOperationKind,
  target: string,
  body: Record<string, unknown>,
  opts: MintRemoteOperationOptions = {},
): BillingRemoteOperation {
  const effect = opts.effect ?? "update";
  const operation: BillingRemoteOperation = {
    uid,
    generation,
    kind,
    target,
    effect,
    ...(opts.idempotencyKey === undefined ? {} : { idempotencyKey: opts.idempotencyKey }),
    restartBudgetClock: opts.restartBudgetClock === true,
    ...(body.max_budget !== undefined ? { maxBudget: body.max_budget as number | null } : {}),
    ...(body.budget_duration !== undefined
      ? { budgetDuration: body.budget_duration as string | null } : {}),
    ...(body.spend !== undefined ? { spend: Number(body.spend) } : {}),
    ...(body.rpm_limit !== undefined ? { rpmLimit: body.rpm_limit as number | null } : {}),
    ...(body.tpm_limit !== undefined ? { tpmLimit: body.tpm_limit as number | null } : {}),
    ...(body.max_parallel_requests !== undefined
      ? { maxParallelRequests: body.max_parallel_requests as number | null } : {}),
    ...(effect === "block" ? { blocked: true } : effect === "unblock" ? { blocked: false } : {}),
  };
  const projectedFields = new Set([
    "key",
    "keys",
    "max_budget",
    "budget_duration",
    "spend",
    "rpm_limit",
    "tpm_limit",
    "max_parallel_requests",
  ]);
  // Key metadata retains its user/team linkage for readback. The primary
  // user/team selector is already bound by target and is not duplicated.
  if (kind === "user") projectedFields.add("user_id");
  if (kind === "team") projectedFields.add("team_id");
  const extra = Object.fromEntries(
    Object.entries(body).filter(([field]) => !projectedFields.has(field)),
  );
  if (Object.keys(extra).length > 0) operation.extra = extra;
  if (effect === "update" && operation.maxBudget === undefined &&
      operation.budgetDuration === undefined && operation.spend === undefined &&
      operation.rpmLimit === undefined && operation.tpmLimit === undefined &&
      operation.maxParallelRequests === undefined && operation.extra === undefined) {
    throw new Error("billing remote operation requires a mutation field");
  }
  return operation;
}

function thrownStatus(error: unknown): number {
  // The legacy create wrappers intentionally expose only `path STATUS`. Never
  // forward their text; a network/parse failure is ambiguous status 0.
  if (!(error instanceof Error)) return 0;
  const match = /(?:key|team)\/(?:generate|new) (\d{3})$/.exec(error.message);
  return match === null ? 0 : Number(match[1]);
}

function mintTransport(deps: MintDeps): BillingRemoteTransport {
  const direct = createLiteLlmBillingTransport({
    baseUrl: deps.env.litellmBaseUrl,
    masterKey: deps.env.litellmMasterKey,
    ...(deps.fetchImpl === undefined ? {} : { fetchImpl: deps.fetchImpl }),
  });
  return {
    read: (operation) => direct.read(operation),
    async send(operation): Promise<BillingRemoteSendResult> {
      const body = billingRemoteBody(operation);
      const effect = operation.effect ?? "update";
      try {
        if (operation.kind === "user") return { status: await deps.litellm.userUpdate(body) };
        if (operation.kind === "team") {
          if (effect === "generate") {
            const response = await deps.litellm.teamNew(body);
            return { status: 200, response: response as unknown as Record<string, unknown> };
          }
          return { status: await deps.litellm.teamUpdate(body) };
        }
        if (effect === "generate") {
          const response = await deps.litellm.keyGenerate(body);
          return { status: 200, response: response as unknown as Record<string, unknown> };
        }
        if (effect === "delete") return { status: await deps.litellm.keyDelete([operation.target]) };
        if (effect === "block") return { status: await deps.litellm.keyBlock(operation.target) };
        if (effect === "unblock") return { status: await deps.litellm.keyUnblock(operation.target) };
        return { status: await deps.litellm.keyUpdateStatus(body) };
      } catch (error) {
        return { status: thrownStatus(error) };
      }
    },
  };
}

export async function executeMintRemoteOperation(
  deps: MintDeps,
  operation: BillingRemoteOperation,
  opts: BillingRemoteExecuteOptions = {},
): Promise<BillingRemoteExecution> {
  const authority = createBillingRemoteAuthority({
    db: deps.db,
    transport: mintTransport(deps),
    onUnresolved: async (pending) => {
      // Metadata only: no uid, key id/token, request body, URL, or response.
      console.log(
        `[mint] unresolved ${pending.kind}/${pending.effect ?? "update"} phase ${pending.phase ?? "prepared"}`,
      );
      await deps.alerter(
        "billing_remote_unresolved",
        `billing ${pending.kind}/${pending.effect ?? "update"} requires reconciliation (${pending.phase ?? "prepared"})`,
        300,
      );
    },
  });
  return authority.execute(operation, opts);
}
