// ── Contribution registry (the P3 seam) ──────────────────────────────────────
//
// Registration only — hook EXECUTION is P3's engine. Records are keyed by
// canonical id `plugin:<id>/<kind>:<name>` (hooks carry their ordinal), which
// is version-independent BY DESIGN: a reinstall or upgrade re-registers the
// same ids, so register() is an IDEMPOTENT UPSERT (the record is replaced,
// never a throw). A duplicate canonicalId WITHIN one register() call is a
// caller bug and throws before anything is written.
//
// USER SCOPING (P5 Task 14 fix I3): the registry is worker-global, so the
// same canonical id can belong to two users who installed the same plugin.
// Records therefore carry an optional `userId` and are stored under
// `userId + canonicalId`; every mutation/read accepts an optional userId.
// With userId supplied, an uninstall can only remove that user's records
// (a forged/foreign uninstall is a no-op), and re-registering one user's
// plugin never drops another user's records. Calls without userId keep the
// original worker-global semantics for single-tenant consumers/tests.
// The engine (T16) must pass userId when it resolves a contribution.

import { canonicalContributionId } from "./manifest.js";
import type { NormalizedPluginManifest } from "./manifest.js";

export interface ContributionRecord {
  canonicalId: string;
  kind: string;
  pluginId: string;
  name: string;
  rootPath: string;
  data: Record<string, unknown>;
  /** Owner scope (P5 fix I3); absent = legacy unscoped record. */
  userId?: string;
}

export interface RegistryFilter {
  kind?: string;
  pluginId?: string;
  /** Owner scope; absent = all users (legacy behavior). */
  userId?: string;
}

export interface ContributionRegistry {
  /**
   * Register contributions. Existing canonicalIds are UPSERTED (replaced —
   * reinstall/upgrade parity), and each plugin present in the batch has its
   * PRIOR records not carried by the batch removed first
   * (unregister-before-re-register guard): a re-register is a full
   * per-(user, plugin) sync, so a REMOVED contribution never survives a bare
   * upsert as a stale record. Plugins/users absent from the batch are
   * untouched. A duplicate canonicalId within THIS call throws and nothing
   * is written.
   */
  register(recs: ContributionRecord[]): void;
  /** Remove every record of one plugin (optionally one user); returns the removed count. */
  unregisterPlugin(pluginId: string, userId?: string): number;
  list(filter?: RegistryFilter): ContributionRecord[];
  /** Exact match when userId is given; otherwise the first matching record. */
  get(canonicalId: string, userId?: string): ContributionRecord | undefined;
}

/** Storage key: userId (or empty) + NUL + canonicalId. */
function storageKey(canonicalId: string, userId: string | undefined): string {
  return `${userId ?? ""}\u0000${canonicalId}`;
}

function copy(r: ContributionRecord): ContributionRecord {
  return { ...r, data: { ...r.data } };
}

function validate(r: ContributionRecord): void {
  if (
    typeof r.canonicalId !== "string" ||
    r.canonicalId === "" ||
    typeof r.pluginId !== "string" ||
    r.pluginId === "" ||
    typeof r.kind !== "string" ||
    r.kind === "" ||
    typeof r.name !== "string" ||
    r.name === ""
  ) {
    throw new Error("invalid contribution record: missing identity fields");
  }
  if (r.userId !== undefined && (typeof r.userId !== "string" || r.userId === "")) {
    throw new Error(`invalid contribution record: ${r.canonicalId}: bad userId`);
  }
  if (r.data === null || typeof r.data !== "object") {
    throw new Error(`invalid contribution record: ${r.canonicalId}: data must be an object`);
  }
}

export function createContributionRegistry(): ContributionRegistry {
  const byId = new Map<string, ContributionRecord>();
  const order: string[] = [];

  return {
    register(recs: ContributionRecord[]): void {
      // Intra-call duplicates throw BEFORE any mutation: a failed batch
      // never half-registers. The key includes userId: the same canonical id
      // for two different users is legitimate.
      const seen = new Set<string>();
      for (const r of recs) {
        validate(r);
        const key = storageKey(r.canonicalId, r.userId);
        if (seen.has(key)) {
          throw new Error(
            `duplicate contribution id within register() call: ${r.canonicalId}`,
          );
        }
        seen.add(key);
      }
      // Unregister-before-re-register guard: a re-register is a full
      // per-(user, plugin) sync, so records of a batch (user, plugin) that
      // the batch no longer carries are dropped before the upsert. Without
      // this, a removed (or re-keyed) contribution survived a bare upsert as
      // a stale record the engine would keep dispatching.
      const batchScopes = new Set(
        recs.map((r) => storageKey(r.pluginId, r.userId)),
      );
      for (let i = order.length - 1; i >= 0; i--) {
        const id = order[i]!;
        const existing = byId.get(id)!;
        if (
          batchScopes.has(storageKey(existing.pluginId, existing.userId)) &&
          !seen.has(id)
        ) {
          byId.delete(id);
          order.splice(i, 1);
        }
      }
      for (const r of recs) {
        const key = storageKey(r.canonicalId, r.userId);
        if (!byId.has(key)) order.push(key);
        byId.set(key, copy(r));
      }
    },

    unregisterPlugin(pluginId: string, userId?: string): number {
      let removed = 0;
      for (let i = order.length - 1; i >= 0; i--) {
        const id = order[i]!;
        const record = byId.get(id)!;
        if (
          record.pluginId === pluginId &&
          (userId === undefined || record.userId === userId)
        ) {
          byId.delete(id);
          order.splice(i, 1);
          removed++;
        }
      }
      return removed;
    },

    list(filter: RegistryFilter = {}): ContributionRecord[] {
      let out = order.map((id) => byId.get(id)!);
      if (filter.kind !== undefined) {
        out = out.filter((r) => r.kind === filter.kind);
      }
      if (filter.pluginId !== undefined) {
        out = out.filter((r) => r.pluginId === filter.pluginId);
      }
      if (filter.userId !== undefined) {
        out = out.filter((r) => r.userId === filter.userId);
      }
      return out.map(copy);
    },

    get(canonicalId: string, userId?: string): ContributionRecord | undefined {
      const r =
        userId !== undefined
          ? byId.get(storageKey(canonicalId, userId))
          : order
              .map((id) => byId.get(id)!)
              .find((rec) => rec.canonicalId === canonicalId);
      return r === undefined ? undefined : copy(r);
    },
  };
}

/**
 * Derive the registry records for every contribution a manifest carries
 * (canonical ids per kind; hooks carry their per-event ordinal). Pass
 * `userId` to scope the records to their owner (P5 fix I3).
 */
export function contributionsFromManifest(
  m: NormalizedPluginManifest,
  userId?: string,
): ContributionRecord[] {
  const recs: ContributionRecord[] = [];
  const base = {
    pluginId: m.pluginId,
    rootPath: m.rootPath,
    ...(userId !== undefined ? { userId } : {}),
  };

  for (const c of m.commands) {
    recs.push({
      ...base,
      canonicalId: canonicalContributionId(m.pluginId, "command", c.name),
      kind: "command",
      name: c.name,
      data: { file: c.file, description: c.description },
    });
  }
  for (const s of m.skills) {
    recs.push({
      ...base,
      canonicalId: canonicalContributionId(m.pluginId, "skill", s.name),
      kind: "skill",
      name: s.name,
      data: { file: s.file, description: s.description },
    });
  }
  for (const a of m.agents) {
    recs.push({
      ...base,
      canonicalId: canonicalContributionId(m.pluginId, "agent", a.name),
      kind: "agent",
      name: a.name,
      data: { file: a.file, description: a.description },
    });
  }
  for (const h of m.hooks) {
    recs.push({
      ...base,
      canonicalId: canonicalContributionId(m.pluginId, "hook", h.event, h.ordinal),
      kind: "hook",
      name: h.event,
      data: { type: h.type, command: h.command, canBlock: h.canBlock, ordinal: h.ordinal },
    });
  }
  for (const s of m.mcpServers) {
    recs.push({
      ...base,
      canonicalId: canonicalContributionId(m.pluginId, "mcp", s.name),
      kind: "mcp",
      name: s.name,
      data: { imported: s.imported },
    });
  }
  return recs;
}
