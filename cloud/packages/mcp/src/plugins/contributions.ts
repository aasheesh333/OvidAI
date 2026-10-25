// Durable approved-contribution primitives. The store is authoritative on
// every read/activation check; the existing ContributionRegistry is only a
// per-user cache of active approved projections. No runtime/gateway/queue/DB
// composition lives here.

import {
  createContributionRegistry,
  type ContributionRecord,
  type ContributionRegistry,
} from "./registry.js";

/** A readable persisted row, including legacy rows without review metadata. */
export interface PersistedContribution extends ContributionRecord {
  userId: string;
  installationId?: string;
  approvedSourceId?: string;
  digest?: string;
  generation?: number;
  active?: boolean;
}

/** A persisted contribution bound to the exact approved installed content. */
export interface ApprovedContribution extends PersistedContribution {
  installationId: string;
  approvedSourceId: string;
  digest: string;
  generation: number;
  active: boolean;
}

/** Authoritative durable reads. Implementations MUST scope every query by user. */
export interface ApprovedContributionStore {
  listByUser(userId: string): Promise<readonly PersistedContribution[]>;
}

export type ContributionActivationErrorCode =
  | "not_found"
  | "unreviewed"
  | "inactive"
  | "stale_generation"
  | "installation_mismatch"
  | "digest_mismatch";

/** Value-free activation denial; persisted config/secret values are not echoed. */
export class ContributionActivationError extends Error {
  constructor(readonly code: ContributionActivationErrorCode) {
    super(code);
    this.name = "ContributionActivationError";
  }
}

export interface ContributionActivationQuery {
  userId: string;
  canonicalId: string;
  installationId: string;
  expectedDigest: string;
  expectedGeneration: number;
}

export interface ContributionTransactionContext {
  userId: string;
  installationId: string;
  approvedSourceId: string;
  digest: string;
  generation: number;
}

/** Inactive staged rows; commit, not stage/probe, is the activation boundary. */
export interface StagedApprovedContributions
  extends ContributionTransactionContext {
  contributions: ApprovedContribution[];
}

/**
 * Required rollback report from the later install-composition port.
 * `previousVersionPreserved` is true when the old version is untouched or
 * restored (and when there was no old version to damage). The `new*` fields
 * cover only resources owned by this transaction, never the previous version.
 */
export interface ContributionRollbackOutcome {
  previousVersionPreserved: boolean;
  stagingRemoved: boolean;
  spawnedProcessesStopped: boolean;
  newConnectionsRemoved: boolean;
  newSealedConfigRemoved: boolean;
  newRegistrationsRemoved: boolean;
}

/**
 * Side-effecting implementations are intentionally left to install composition.
 * `commit` must atomically persist manifest/grants/contributions/MCP linkage
 * and activate them. `rollback` receives the context even when stage threw
 * before returning, so it can clean partially created staging/resources.
 */
export interface ContributionTransactionPort {
  stage(context: ContributionTransactionContext): Promise<StagedApprovedContributions>;
  probe(staged: StagedApprovedContributions): Promise<void>;
  commit(staged: StagedApprovedContributions): Promise<void>;
  rollback(
    context: ContributionTransactionContext,
    staged: StagedApprovedContributions | null,
    phase: "stage" | "probe" | "commit",
  ): Promise<ContributionRollbackOutcome>;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function nonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function copyString(
  source: Record<string, unknown>,
  target: Record<string, unknown>,
  key: string,
): void {
  if (typeof source[key] === "string") target[key] = source[key];
}

function stringArray(value: unknown): string[] | undefined {
  return Array.isArray(value) && value.every((entry) => typeof entry === "string")
    ? [...value]
    : undefined;
}

/**
 * Project only persisted manifest metadata. In particular, imported MCP env
 * and header VALUES never survive; only their names remain for later sealing.
 * This function expects persisted refs, never a runtime config-substituted row.
 */
function projectData(kind: string, data: Record<string, unknown>): Record<string, unknown> {
  if (kind === "command" || kind === "skill" || kind === "agent") {
    const projected: Record<string, unknown> = {};
    copyString(data, projected, "file");
    copyString(data, projected, "description");
    return projected;
  }
  if (kind === "hook") {
    const projected: Record<string, unknown> = {};
    copyString(data, projected, "type");
    copyString(data, projected, "command");
    if (typeof data.canBlock === "boolean") projected.canBlock = data.canBlock;
    if (typeof data.ordinal === "number") projected.ordinal = data.ordinal;
    return projected;
  }
  if (kind !== "mcp" || !isRecord(data.imported)) return {};

  const imported = data.imported;
  const projectedImport: Record<string, unknown> = {};
  for (const key of ["name", "transport", "command", "cwd", "url"] as const) {
    copyString(imported, projectedImport, key);
  }
  const args = stringArray(imported.args);
  if (args !== undefined) projectedImport.args = args;
  if (isRecord(imported.oauth)) {
    const oauth: Record<string, unknown> = {};
    for (const key of [
      "authorizationUrl",
      "tokenUrl",
      "clientId",
      "redirectUri",
    ] as const) {
      copyString(imported.oauth, oauth, key);
    }
    const scopes = stringArray(imported.oauth.scopes);
    if (scopes !== undefined) oauth.scopes = scopes;
    projectedImport.oauth = oauth;
  }

  const envNames = new Set<string>(
    isRecord(imported.env) ? Object.keys(imported.env) : [],
  );
  for (const name of stringArray(data.envNames) ?? []) envNames.add(name);
  const headerNames = new Set<string>(
    isRecord(imported.headers) ? Object.keys(imported.headers) : [],
  );
  for (const name of stringArray(data.headerNames) ?? []) headerNames.add(name);

  return {
    imported: projectedImport,
    envNames: [...envNames].sort(),
    headerNames: [...headerNames].sort(),
  };
}

/** Strip unknown top-level fields while retaining partial legacy review data. */
function projectPersistedContribution(
  row: PersistedContribution,
): PersistedContribution {
  const projected: PersistedContribution = {
    canonicalId: row.canonicalId,
    kind: row.kind,
    pluginId: row.pluginId,
    name: row.name,
    rootPath: row.rootPath,
    data: projectData(row.kind, row.data),
    userId: row.userId,
  };
  if (typeof row.installationId === "string") {
    projected.installationId = row.installationId;
  }
  if (typeof row.approvedSourceId === "string") {
    projected.approvedSourceId = row.approvedSourceId;
  }
  if (typeof row.digest === "string") projected.digest = row.digest;
  if (typeof row.generation === "number") projected.generation = row.generation;
  if (typeof row.active === "boolean") projected.active = row.active;
  return projected;
}

/**
 * Return null for malformed or unreviewed rows. An old `active:true` flag is
 * readable through the store but is not a substitute for approval metadata.
 */
export function projectApprovedContribution(
  row: PersistedContribution,
): ApprovedContribution | null {
  if (
    !isRecord(row) ||
    !nonEmptyString(row.canonicalId) ||
    !nonEmptyString(row.kind) ||
    !nonEmptyString(row.pluginId) ||
    !nonEmptyString(row.name) ||
    typeof row.rootPath !== "string" ||
    !isRecord(row.data) ||
    !nonEmptyString(row.userId) ||
    !nonEmptyString(row.installationId) ||
    !nonEmptyString(row.approvedSourceId) ||
    !nonEmptyString(row.digest) ||
    !Number.isInteger(row.generation) ||
    (row.generation ?? -1) < 0 ||
    typeof row.active !== "boolean"
  ) {
    return null;
  }
  return projectPersistedContribution(row) as ApprovedContribution;
}

export interface ApprovedContributionReader {
  /** Read every projected row (including unreviewed) and refresh this user's cache. */
  list(userId: string): Promise<PersistedContribution[]>;
  /** Authorize one active generation from a fresh durable read, never a cache hit. */
  requireActive(query: ContributionActivationQuery): Promise<ApprovedContribution>;
  /** Non-authoritative active cache view for later runtime composition. */
  cached(userId: string): ContributionRecord[];
}

export function createApprovedContributionReader(deps: {
  store: ApprovedContributionStore;
  registry?: ContributionRegistry;
}): ApprovedContributionReader {
  const registry = deps.registry ?? createContributionRegistry();

  function replaceUserCache(userId: string, rows: PersistedContribution[]): void {
    const pluginIds = new Set<string>([
      ...registry.list({ userId }).map((row) => row.pluginId),
      ...rows.map((row) => row.pluginId),
    ]);
    for (const pluginId of pluginIds) registry.unregisterPlugin(pluginId, userId);
    const active = rows
      .map(projectApprovedContribution)
      .filter((row): row is ApprovedContribution => row?.active === true);
    registry.register(active);
  }

  async function list(userId: string): Promise<PersistedContribution[]> {
    // Defense in depth: even an incorrectly broad store result cannot enter
    // another user's projection/cache. The store contract remains per-user.
    const stored = await deps.store.listByUser(userId);
    const rows = stored
      .filter((row) => row.userId === userId)
      .map(projectPersistedContribution);
    replaceUserCache(userId, rows);
    return rows;
  }

  return {
    list,
    async requireActive(query) {
      const rows = await list(query.userId);
      const persisted = rows.find((row) => row.canonicalId === query.canonicalId);
      if (persisted === undefined) throw new ContributionActivationError("not_found");
      const row = projectApprovedContribution(persisted);
      if (row === null) throw new ContributionActivationError("unreviewed");
      if (!row.active) throw new ContributionActivationError("inactive");
      if (row.generation !== query.expectedGeneration) {
        throw new ContributionActivationError("stale_generation");
      }
      if (row.installationId !== query.installationId) {
        throw new ContributionActivationError("installation_mismatch");
      }
      if (row.digest !== query.expectedDigest) {
        throw new ContributionActivationError("digest_mismatch");
      }
      return row;
    },
    cached(userId) {
      return registry.list({ userId });
    },
  };
}

export type ContributionTransactionOutcome =
  | { status: "activated"; generation: number }
  | {
      status: "rolled_back";
      reason: "stage" | "probe" | "commit";
      rollback: ContributionRollbackOutcome;
    }
  | {
      status: "rollback_incomplete";
      reason: "stage" | "probe" | "commit";
      rollback: ContributionRollbackOutcome | null;
    };

const CONTEXT_KEYS = [
  "userId",
  "installationId",
  "approvedSourceId",
  "digest",
  "generation",
] as const;

function sameContext(
  left: ContributionTransactionContext,
  right: ContributionTransactionContext,
): boolean {
  return CONTEXT_KEYS.every((key) => left[key] === right[key]);
}

function normalizeStaged(
  candidate: StagedApprovedContributions,
  context: ContributionTransactionContext,
): StagedApprovedContributions {
  if (!sameContext(candidate, context) || !Array.isArray(candidate.contributions)) {
    throw new Error("staged approval binding mismatch");
  }
  const contributions = candidate.contributions.map((row) => {
    const projected = projectApprovedContribution(row);
    if (
      projected === null ||
      projected.active ||
      projected.userId !== context.userId ||
      projected.installationId !== context.installationId ||
      projected.approvedSourceId !== context.approvedSourceId ||
      projected.digest !== context.digest ||
      projected.generation !== context.generation
    ) {
      throw new Error("staged contribution approval mismatch");
    }
    return projected;
  });
  // Exact projection: unexpected staging fields cannot carry pasted config or
  // secrets into a later persistence adapter.
  return { ...context, contributions };
}

function rollbackComplete(outcome: ContributionRollbackOutcome): boolean {
  return (
    outcome.previousVersionPreserved === true &&
    outcome.stagingRemoved === true &&
    outcome.spawnedProcessesStopped === true &&
    outcome.newConnectionsRemoved === true &&
    outcome.newSealedConfigRemoved === true &&
    outcome.newRegistrationsRemoved === true
  );
}

/**
 * Pure transaction orchestration over the port above. This proves ordering and
 * truthful outcomes only; it does NOT itself remove files/processes/
 * connections/sealed config/registrations or preserve an on-disk version.
 */
export async function runApprovedContributionTransaction(
  context: ContributionTransactionContext,
  port: ContributionTransactionPort,
): Promise<ContributionTransactionOutcome> {
  // Rebuild rather than spread the caller object so an unchecked extra field
  // cannot reach staging, commit, rollback, or their persistence adapters.
  const expected: ContributionTransactionContext = {
    userId: context.userId,
    installationId: context.installationId,
    approvedSourceId: context.approvedSourceId,
    digest: context.digest,
    generation: context.generation,
  };
  let staged: StagedApprovedContributions | null = null;
  let phase: "stage" | "probe" | "commit" = "stage";
  try {
    // Keep the untrusted candidate out of the rollback-bound variable. If
    // normalization rejects it, rollback still receives the safe context but
    // `staged` remains null rather than the stager-owned object.
    const candidate = await port.stage(expected);
    staged = normalizeStaged(candidate, expected);
    phase = "probe";
    await port.probe(staged);
    phase = "commit";
    await port.commit(staged);
    return { status: "activated", generation: expected.generation };
  } catch {
    let rollback: ContributionRollbackOutcome | null = null;
    try {
      rollback = await port.rollback(expected, staged, phase);
    } catch {
      return { status: "rollback_incomplete", reason: phase, rollback: null };
    }
    return rollbackComplete(rollback)
      ? { status: "rolled_back", reason: phase, rollback }
      : { status: "rollback_incomplete", reason: phase, rollback };
  }
}
