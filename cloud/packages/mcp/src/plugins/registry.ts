// ── Contribution registry (the P3 seam) ──────────────────────────────────────
//
// Registration only — hook EXECUTION is P3's engine. Records are keyed by
// canonical id `plugin:<id>/<kind>:<name>` (hooks carry their ordinal), which
// is version-independent BY DESIGN: a reinstall or upgrade re-registers the
// same ids, so register() is an IDEMPOTENT UPSERT (the record is replaced,
// never a throw). A duplicate canonicalId WITHIN one register() call is a
// caller bug and throws before anything is written.

import { canonicalContributionId } from "./manifest.js";
import type { NormalizedPluginManifest } from "./manifest.js";

export interface ContributionRecord {
  canonicalId: string;
  kind: string;
  pluginId: string;
  name: string;
  rootPath: string;
  data: Record<string, unknown>;
}

export interface ContributionRegistry {
  /**
   * Register contributions. Existing canonicalIds are UPSERTED (replaced —
   * reinstall/upgrade parity), and each plugin present in the batch has its
   * PRIOR records not carried by the batch removed first
   * (unregister-before-re-register guard): a re-register is a full
   * per-plugin sync, so a REMOVED contribution never survives a bare
   * upsert as a stale record. Plugins absent from the batch are untouched.
   * A duplicate canonicalId within THIS call throws and nothing is written.
   */
  register(recs: ContributionRecord[]): void;
  /** Remove every record of one plugin; returns the removed count. */
  unregisterPlugin(pluginId: string): number;
  list(filter?: { kind?: string; pluginId?: string }): ContributionRecord[];
  get(canonicalId: string): ContributionRecord | undefined;
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
      // never half-registers.
      const seen = new Set<string>();
      for (const r of recs) {
        validate(r);
        if (seen.has(r.canonicalId)) {
          throw new Error(
            `duplicate contribution id within register() call: ${r.canonicalId}`,
          );
        }
        seen.add(r.canonicalId);
      }
      // Unregister-before-re-register guard: a re-register is a full
      // per-plugin sync, so records of a batch plugin that the batch no
      // longer carries are dropped before the upsert. Without this, a
      // removed (or re-keyed) contribution survived a bare upsert as a
      // stale record the engine would keep dispatching.
      const batchPluginIds = new Set(recs.map((r) => r.pluginId));
      for (let i = order.length - 1; i >= 0; i--) {
        const id = order[i]!;
        const existing = byId.get(id)!;
        if (batchPluginIds.has(existing.pluginId) && !seen.has(id)) {
          byId.delete(id);
          order.splice(i, 1);
        }
      }
      for (const r of recs) {
        if (!byId.has(r.canonicalId)) order.push(r.canonicalId);
        byId.set(r.canonicalId, copy(r));
      }
    },

    unregisterPlugin(pluginId: string): number {
      let removed = 0;
      for (let i = order.length - 1; i >= 0; i--) {
        const id = order[i]!;
        if (byId.get(id)?.pluginId === pluginId) {
          byId.delete(id);
          order.splice(i, 1);
          removed++;
        }
      }
      return removed;
    },

    list(filter?: { kind?: string; pluginId?: string }): ContributionRecord[] {
      let out = order.map((id) => byId.get(id)!);
      if (filter?.kind !== undefined) {
        out = out.filter((r) => r.kind === filter.kind);
      }
      if (filter?.pluginId !== undefined) {
        out = out.filter((r) => r.pluginId === filter.pluginId);
      }
      return out.map(copy);
    },

    get(canonicalId: string): ContributionRecord | undefined {
      const r = byId.get(canonicalId);
      return r === undefined ? undefined : copy(r);
    },
  };
}

/**
 * Derive the registry records for every contribution a manifest carries
 * (canonical ids per kind; hooks carry their per-event ordinal).
 */
export function contributionsFromManifest(
  m: NormalizedPluginManifest,
): ContributionRecord[] {
  const recs: ContributionRecord[] = [];
  const base = { pluginId: m.pluginId, rootPath: m.rootPath };

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
