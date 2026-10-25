import { createHash } from "node:crypto";
import { and, eq, like, or } from "drizzle-orm";
import type { Db } from "./client.js";
import type { PurchaseRow } from "./moneyRepos.js";
import { billingPurchases as billingPurchasesTable } from "./schema.js";

export type BillingRemoteOperationKind = "user" | "key" | "team";
export type BillingRemoteEffect = "update" | "block" | "unblock" | "delete" | "generate";
export type BillingRemotePhase = "prepared" | "uncertain" | "acknowledged" | "rejected";
export type BillingRemoteResolution =
  | "readback"
  | "not-required"
  | "terminal-404"
  | "operator-drained"
  | "superseded-not-sent"
  | "definite-rejection";

/**
 * A durable remote intent. `extra` never contains plaintext key material or
 * the LiteLLM master key. Lifecycle operations use idempotencyKey so a fresh
 * billing generation cannot turn one logical create into a second credential.
 */
export interface BillingRemoteOperation {
  uid: string;
  generation: number;
  kind: BillingRemoteOperationKind;
  target: string;
  effect?: BillingRemoteEffect;
  idempotencyKey?: string;
  maxBudget?: number | null;
  budgetDuration?: string | null;
  spend?: number;
  rpmLimit?: number | null;
  tpmLimit?: number | null;
  maxParallelRequests?: number | null;
  blocked?: boolean;
  restartBudgetClock?: boolean;
  extra?: Record<string, unknown>;
  /** Recovered generate/team-new target id; never a plaintext credential. */
  createdTarget?: string;
  phase?: BillingRemotePhase;
  attempts?: number;
  retryable?: boolean;
  resolution?: BillingRemoteResolution;
}

export interface BillingRemoteOperationRecord extends BillingRemoteOperation {
  id: string;
  token: string;
  status: string;
  updatedAt: number;
}

const REMOTE_META_PREFIX = "rc-remote-v2:";
const LEGACY_REMOTE_META_PREFIX = "rc-remote:";
const remotePrefix = (uid: string): string => `revenuecat:remote:${uid}`;
const remoteHeadToken = (uid: string): string => remotePrefix(uid);
const refreshToken = (uid: string): string => `revenuecat:refresh:${uid}`;
const nowSeconds = (): number => Math.floor(Date.now() / 1000);
type BillingRemoteTransaction = Parameters<Parameters<Db["transaction"]>[0]>[0];
type BillingRemoteDb = Db | BillingRemoteTransaction;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (isRecord(value)) {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${canonical(value[key])}`
    ).join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}

function logicalValue(operation: BillingRemoteOperation): Record<string, unknown> {
  if (operation.idempotencyKey === undefined) return semanticValue(operation);
  return {
    uid: operation.uid,
    idempotencyKey: operation.idempotencyKey,
    kind: operation.kind,
    target: operation.target,
    effect: operation.effect ?? "update",
  };
}

function semanticValue(operation: BillingRemoteOperation): Record<string, unknown> {
  return {
    uid: operation.uid,
    // Logical lookup is stable across generations; this payload remains a
    // separate binding used for conflict checks and request verification.
    ...(operation.idempotencyKey === undefined ? { generation: operation.generation } : {}),
    idempotencyKey: operation.idempotencyKey ?? null,
    kind: operation.kind,
    target: operation.target,
    effect: operation.effect ?? "update",
    maxBudget: operation.maxBudget ?? null,
    hasMaxBudget: operation.maxBudget !== undefined,
    budgetDuration: operation.budgetDuration ?? null,
    hasBudgetDuration: operation.budgetDuration !== undefined,
    spend: operation.spend ?? null,
    hasSpend: operation.spend !== undefined,
    rpmLimit: operation.rpmLimit ?? null,
    hasRpmLimit: operation.rpmLimit !== undefined,
    tpmLimit: operation.tpmLimit ?? null,
    hasTpmLimit: operation.tpmLimit !== undefined,
    maxParallelRequests: operation.maxParallelRequests ?? null,
    hasMaxParallelRequests: operation.maxParallelRequests !== undefined,
    blocked: operation.blocked ?? null,
    hasBlocked: operation.blocked !== undefined,
    restartBudgetClock: operation.restartBudgetClock === true,
    extra: operation.extra ?? null,
  };
}

export class BillingRemoteOperationConflictError extends Error {
  readonly code = "billing_remote_operation_conflict";
  constructor() {
    super("billing remote logical operation payload conflicts with durable intent");
    this.name = "BillingRemoteOperationConflictError";
  }
}

export function billingRemoteOperationId(operation: BillingRemoteOperation): string {
  return createHash("sha256").update(canonical(logicalValue(operation))).digest("hex").slice(0, 40);
}

export function billingRemoteOperationToken(operation: BillingRemoteOperation): string {
  return `${remotePrefix(operation.uid)}:${billingRemoteOperationId(operation)}`;
}

function sameSemanticOperation(
  left: BillingRemoteOperation,
  right: BillingRemoteOperation,
): boolean {
  return canonical(semanticValue(left)) === canonical(semanticValue(right));
}

function sameLogicalOperation(
  left: BillingRemoteOperation,
  right: BillingRemoteOperation,
): boolean {
  return canonical(logicalValue(left)) === canonical(logicalValue(right));
}

function mayRecoverDifferentPayload(
  current: BillingRemoteOperationRecord,
  desired: BillingRemoteOperation,
): boolean {
  return desired.idempotencyKey !== undefined &&
    (current.status === "replaced" ||
      current.status === "expired" && current.resolution === "operator-drained");
}

function metadata(operation: BillingRemoteOperation): string {
  return `${REMOTE_META_PREFIX}${JSON.stringify({
    version: 2,
    operationId: billingRemoteOperationId(operation),
    ...semanticValue(operation),
    currentGeneration: operation.generation,
    createdTarget: operation.createdTarget ?? null,
    phase: operation.phase ?? "prepared",
    attempts: operation.attempts ?? 0,
    retryable: operation.retryable === true,
    resolution: operation.resolution ?? null,
  })}`;
}

function numberField(value: unknown): number | null | undefined {
  return value === null || typeof value === "number" ? value : undefined;
}

function readOperation(row: PurchaseRow, uid: string): BillingRemoteOperationRecord | null {
  if (typeof row.accountHash !== "string") return null;
  const legacy = row.accountHash.startsWith(LEGACY_REMOTE_META_PREFIX) &&
    !row.accountHash.startsWith(REMOTE_META_PREFIX);
  const prefix = legacy ? LEGACY_REMOTE_META_PREFIX : REMOTE_META_PREFIX;
  if (!row.accountHash.startsWith(prefix)) return null;
  try {
    const parsed = JSON.parse(row.accountHash.slice(prefix.length)) as Record<string, unknown>;
    const kind = parsed.kind;
    if ((kind !== "user" && kind !== "key" && kind !== "team") ||
        typeof parsed.target !== "string" ||
        (legacy && !Number.isSafeInteger(parsed.generation))) return null;
    const generation = legacy ? parsed.generation : parsed.currentGeneration;
    if (!Number.isSafeInteger(generation)) return null;
    const extra = isRecord(parsed.extra) ? parsed.extra : undefined;
    const operationUid = !legacy && typeof parsed.uid === "string" ? parsed.uid : uid;
    const operation: BillingRemoteOperation = {
      uid: operationUid,
      generation: generation as number,
      kind,
      target: parsed.target,
      effect: parsed.effect === "block" || parsed.effect === "unblock" ||
          parsed.effect === "delete" || parsed.effect === "generate"
        ? parsed.effect
        : "update",
      ...(typeof parsed.idempotencyKey === "string" ? { idempotencyKey: parsed.idempotencyKey } : {}),
      ...(parsed.hasMaxBudget === true || legacy && parsed.maxBudget !== undefined
        ? { maxBudget: numberField(parsed.maxBudget) } : {}),
      ...(parsed.hasBudgetDuration === true || legacy && parsed.budgetDuration !== undefined
        ? { budgetDuration: typeof parsed.budgetDuration === "string" || parsed.budgetDuration === null
          ? parsed.budgetDuration : undefined } : {}),
      ...(parsed.hasSpend === true || legacy && typeof parsed.spend === "number"
        ? { spend: typeof parsed.spend === "number" ? parsed.spend : undefined } : {}),
      ...(parsed.hasRpmLimit === true || legacy && parsed.rpmLimit !== undefined
        ? { rpmLimit: numberField(parsed.rpmLimit) } : {}),
      ...(parsed.hasTpmLimit === true || legacy && parsed.tpmLimit !== undefined
        ? { tpmLimit: numberField(parsed.tpmLimit) } : {}),
      ...(parsed.hasMaxParallelRequests === true || legacy && parsed.maxParallelRequests !== undefined
        ? { maxParallelRequests: numberField(parsed.maxParallelRequests) } : {}),
      ...(parsed.hasBlocked === true && typeof parsed.blocked === "boolean"
        ? { blocked: parsed.blocked } : {}),
      restartBudgetClock: parsed.restartBudgetClock === true,
      ...(extra === undefined ? {} : { extra }),
      ...(typeof parsed.createdTarget === "string" ? { createdTarget: parsed.createdTarget } : {}),
      phase: parsed.phase === "prepared" || parsed.phase === "acknowledged" || parsed.phase === "rejected"
        ? parsed.phase
        : "uncertain",
      attempts: Number.isSafeInteger(parsed.attempts) && Number(parsed.attempts) >= 0
        ? Number(parsed.attempts) : legacy ? 1 : 0,
      retryable: parsed.retryable === true || parsed.phase === "rejected",
      ...(parsed.resolution === "readback" || parsed.resolution === "not-required" ||
          parsed.resolution === "terminal-404" || parsed.resolution === "operator-drained" ||
          parsed.resolution === "superseded-not-sent" || parsed.resolution === "definite-rejection"
        ? { resolution: parsed.resolution } : {}),
    };
    const id = legacy && row.token === remoteHeadToken(uid)
      ? `legacy:${billingRemoteOperationId(operation)}`
      : billingRemoteOperationId(operation);
    return { ...operation, id, token: row.token, status: row.status, updatedAt: row.updatedAt };
  } catch {
    return null;
  }
}

function valuesFor(token: string, operation: BillingRemoteOperation, status: string) {
  return {
    token,
    uid: null,
    productId: "litellm_remote_v2",
    tier: "free",
    status,
    expiresAt: null,
    autoRenewing: false,
    linkedToken: token === remoteHeadToken(operation.uid) ? null : billingRemoteOperationId(operation),
    accountHash: metadata(operation),
    updatedAt: nowSeconds(),
  } satisfies typeof billingPurchasesTable.$inferInsert;
}

async function lockRefreshAndGetGeneration(
  tx: BillingRemoteDb,
  operation: BillingRemoteOperation,
): Promise<boolean> {
  const [refresh] = await tx
    .select({ accountHash: billingPurchasesTable.accountHash })
    .from(billingPurchasesTable)
    .where(eq(billingPurchasesTable.token, refreshToken(operation.uid)))
    .limit(1)
    .for("update");
  return refresh?.accountHash === String(operation.generation);
}

async function writeHead(tx: BillingRemoteDb, operation: BillingRemoteOperation, status: string): Promise<void> {
  const token = remoteHeadToken(operation.uid);
  const values = valuesFor(token, operation, status);
  await tx.insert(billingPurchasesTable).values(values).onConflictDoUpdate({
    target: billingPurchasesTable.token,
    set: {
      productId: values.productId,
      status,
      accountHash: values.accountHash,
      updatedAt: values.updatedAt,
    },
  });
}

async function writeOperation(
  tx: BillingRemoteDb,
  operation: BillingRemoteOperation,
  status: string,
): Promise<void> {
  const values = valuesFor(billingRemoteOperationToken(operation), operation, status);
  await tx.insert(billingPurchasesTable).values(values).onConflictDoUpdate({
    target: billingPurchasesTable.token,
    set: {
      status,
      accountHash: values.accountHash,
      updatedAt: values.updatedAt,
    },
  });
  await writeHead(tx, operation, status);
}

async function rowsForUid(db: BillingRemoteDb, uid: string, lock = false): Promise<PurchaseRow[]> {
  const base = db.select().from(billingPurchasesTable).where(or(
    eq(billingPurchasesTable.token, remoteHeadToken(uid)),
    like(billingPurchasesTable.token, `${remotePrefix(uid)}:%`),
  ));
  return lock ? base.for("update") : base;
}

function decodeRows(rows: PurchaseRow[], uid: string): BillingRemoteOperationRecord[] {
  const headToken = remoteHeadToken(uid);
  const operations = rows.filter((row) => row.token !== headToken)
    .map((row) => readOperation(row, uid));
  if (operations.some((operation) => operation === null)) {
    throw new Error("billing remote outbox is malformed");
  }
  if (operations.length === 0) {
    const head = rows.find((row) => row.token === headToken);
    if (head !== undefined && head.productId === "litellm_remote") {
      const legacy = readOperation(head, uid);
      if (legacy === null) throw new Error("billing remote outbox is malformed");
      return [legacy];
    }
  }
  return operations as BillingRemoteOperationRecord[];
}

async function transition(
  db: Db,
  operation: BillingRemoteOperation,
  expected: (current: BillingRemoteOperationRecord) => boolean,
  change: (current: BillingRemoteOperationRecord) => {
    operation: BillingRemoteOperation;
    status: string;
  },
): Promise<boolean> {
  return db.transaction(async (tx) => {
    const token = (operation as Partial<BillingRemoteOperationRecord>).token ??
      billingRemoteOperationToken(operation);
    const [row] = await tx.select().from(billingPurchasesTable)
      .where(eq(billingPurchasesTable.token, token)).limit(1).for("update");
    if (row === undefined) return false;
    const current = readOperation(row, operation.uid);
    if (current === null || !sameSemanticOperation(current, operation) || !expected(current)) return false;
    const next = change(current);
    await writeOperation(tx, next.operation, next.status);
    return true;
  });
}

export const billingRemote = {
  operationId: billingRemoteOperationId,
  operationToken: billingRemoteOperationToken,
  same: sameSemanticOperation,

  async list(db: Db, uid: string): Promise<BillingRemoteOperationRecord[]> {
    return decodeRows(await rowsForUid(db, uid), uid)
      .sort((left, right) => left.updatedAt - right.updatedAt || left.id.localeCompare(right.id));
  },

  async listUnresolved(db: Db, uid?: string): Promise<BillingRemoteOperationRecord[]> {
    if (uid !== undefined) {
      return (await this.list(db, uid)).filter((operation) => operation.status === "pending");
    }
    const rows = await db.select().from(billingPurchasesTable).where(and(
      like(billingPurchasesTable.token, "revenuecat:remote:%"),
      eq(billingPurchasesTable.status, "pending"),
    ));
    const unresolved = rows
      .filter((row) => row.linkedToken !== null || row.productId === "litellm_remote")
      .map((row) => readOperation(row, row.token.slice("revenuecat:remote:".length)));
    if (unresolved.some((operation) => operation === null)) {
      throw new Error("billing remote outbox is malformed");
    }
    return unresolved as BillingRemoteOperationRecord[];
  },

  async get(db: Db, operation: BillingRemoteOperation): Promise<BillingRemoteOperationRecord | null> {
    const [row] = await db.select().from(billingPurchasesTable)
      .where(eq(billingPurchasesTable.token, billingRemoteOperationToken(operation))).limit(1);
    if (row === undefined) return null;
    const current = readOperation(row, operation.uid);
    if (current === null || !sameLogicalOperation(current, operation)) {
      throw new BillingRemoteOperationConflictError();
    }
    if (sameSemanticOperation(current, operation) || mayRecoverDifferentPayload(current, operation)) {
      return current;
    }
    throw new BillingRemoteOperationConflictError();
  },

  async getCompleted(db: Db, operation: BillingRemoteOperation): Promise<BillingRemoteOperationRecord | null> {
    const current = await this.get(db, operation);
    return current?.status === "replaced" ? current : null;
  },

  async getPending(db: Db, uid: string): Promise<BillingRemoteOperationRecord | null> {
    return (await this.list(db, uid)).find((operation) => operation.status === "pending") ?? null;
  },

  /** Insert write-ahead intent and the operator-visible account head. */
  async begin(db: Db, operation: BillingRemoteOperation): Promise<"begun" | "completed" | "blocked"> {
    return db.transaction(async (tx) => {
      if (!(await lockRefreshAndGetGeneration(tx, operation))) return "blocked";
      const existingRows = await rowsForUid(tx, operation.uid, true);
      const existing = decodeRows(existingRows, operation.uid);
      const token = billingRemoteOperationToken(operation);
      const exactRow = existingRows.find((row) => row.token === token);
      let restartDrainedOperation = false;
      if (exactRow !== undefined) {
        const exact = readOperation(exactRow, operation.uid);
        if (exact === null || !sameLogicalOperation(exact, operation)) {
          throw new BillingRemoteOperationConflictError();
        }
        if (exact.status === "replaced") return "completed";
        restartDrainedOperation = exact.status === "expired" &&
          exact.resolution === "operator-drained";
        // A drained operation may bind the latest desired payload (never the
        // stale paid intent). Any other unresolved payload mismatch is a real
        // idempotency conflict, not a new operation under another body hash.
        if (!sameSemanticOperation(exact, operation) && !restartDrainedOperation) {
          throw new BillingRemoteOperationConflictError();
        }
        if (exact.status !== "pending" && !restartDrainedOperation) return "blocked";
      }
      const blocker = existing.find((candidate) =>
        candidate.status === "pending" && candidate.token !== token
      );
      if (blocker !== undefined) return "blocked";
      if (exactRow !== undefined && !restartDrainedOperation) return "begun";
      await writeOperation(tx, { ...operation, phase: "prepared", attempts: 0, retryable: false }, "pending");
      return "begun";
    });
  },

  /** Durable point after which a crash must be treated as remote ambiguity. */
  async markAttempted(db: Db, operation: BillingRemoteOperation): Promise<boolean> {
    return transition(db, operation,
      (current) => current.status === "pending" &&
        ((current.phase ?? "prepared") === "prepared" || current.phase === "rejected"),
      (current) => ({
        operation: { ...current, phase: "uncertain", attempts: (current.attempts ?? 0) + 1, retryable: false },
        status: "pending",
      }),
    );
  },

  /** A definite HTTP response ended the request; only readback remains. */
  async markAcknowledged(db: Db, operation: BillingRemoteOperation): Promise<boolean> {
    return transition(db, operation,
      (current) => current.status === "pending" && current.phase === "uncertain" && (current.attempts ?? 0) > 0,
      (current) => ({ operation: { ...current, phase: "acknowledged", retryable: false }, status: "pending" }),
    );
  },

  async markRejected(db: Db, operation: BillingRemoteOperation): Promise<boolean> {
    return transition(db, operation,
      (current) => current.status === "pending" && current.phase === "uncertain",
      (current) => ({ operation: { ...current, phase: "rejected", retryable: true }, status: "pending" }),
    );
  },

  async bindCreatedTarget(db: Db, operation: BillingRemoteOperation, createdTarget: string): Promise<boolean> {
    if (createdTarget === "") return false;
    return transition(db, operation,
      (current) => current.status === "pending" && current.effect === "generate" &&
        (current.createdTarget === undefined || current.createdTarget === createdTarget),
      (current) => ({ operation: { ...current, createdTarget }, status: "pending" }),
    );
  },

  /** Only a verified desired terminal state becomes durable completion. */
  async complete(
    db: Db,
    operation: BillingRemoteOperation,
    resolution: "readback" | "not-required" | "terminal-404",
  ): Promise<boolean> {
    return transition(db, operation,
      (current) => {
        if (current.status !== "pending") return false;
        const phase = current.phase ?? "prepared";
        if (phase === "uncertain") return resolution === "terminal-404" && current.kind === "key";
        if (phase === "rejected") return resolution === "not-required" || resolution === "terminal-404";
        return resolution === "readback" || resolution === "not-required" || resolution === "terminal-404";
      },
      (current) => ({ operation: { ...current, resolution, retryable: false }, status: "replaced" }),
    );
  },

  /** Retire without claiming the requested remote state was applied. */
  async retire(
    db: Db,
    operation: BillingRemoteOperation,
    resolution: "terminal-404" | "operator-drained" | "superseded-not-sent" | "definite-rejection",
  ): Promise<boolean> {
    return transition(db, operation,
      (current) => {
        if (current.status !== "pending") return false;
        const phase = current.phase ?? "prepared";
        if (resolution === "operator-drained") return phase === "uncertain";
        if (resolution === "superseded-not-sent") return phase === "prepared";
        if (resolution === "definite-rejection") return phase === "rejected";
        return current.kind === "key" && current.effect !== "generate";
      },
      (current) => ({ operation: { ...current, resolution, retryable: false }, status: "expired" }),
    );
  },

  /**
   * Owner-only recovery boundary. The caller must have external evidence that
   * the original request drained; this method never invents remote proof and
   * never marks its old desired state applied. The next writer sends only the
   * latest desired operation after acquiring the same account lock.
   */
  async markDrained(db: Db, uid: string, operationId: string, generation: number): Promise<boolean> {
    const operations = await this.list(db, uid);
    const pending = operations.find((operation) =>
      operation.id === operationId && operation.status === "pending" && operation.phase === "uncertain"
    );
    if (pending === undefined || !(await lockCurrentGeneration(db, uid, generation))) return false;
    return this.retire(db, pending, "operator-drained");
  },
};

async function lockCurrentGeneration(db: Db, uid: string, generation: number): Promise<boolean> {
  const [row] = await db.select({ accountHash: billingPurchasesTable.accountHash })
    .from(billingPurchasesTable).where(eq(billingPurchasesTable.token, refreshToken(uid))).limit(1);
  return row?.accountHash === String(generation);
}
