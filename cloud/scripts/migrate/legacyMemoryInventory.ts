/**
 * legacyMemoryInventory.ts — owner-run, READ-ONLY inventory of legacy
 * workspace memory (the R1 release blocker in
 * docs/audit-2026-10-19/RECOVERY-SETTINGS-MEMORY.md).
 *
 * What it does: walk `{workspacesRoot}/{uid}/workspace/.ovid` on the worker
 * host and report every legacy memory file — `.ovid/memory/*` (the old
 * shared surface, including the MCP graph's memory.json, which is flagged
 * non-canonical rather than dropped) and `.ovid/session-memory/<sessionId>/*`
 * (the old per-chat surface) — with the metadata a future owner decision
 * needs: the private_memory_files scope it would map to, and every guard
 * the private store would apply (canonical name, ≤80 chars, ≤32 KiB, ≤32
 * files counting the virtual MEMORY.md, case-conflicts, session
 * liveness/ownership).
 *
 * What it deliberately does NOT do: no import, no delete, no move, no rename,
 * no content reads. Only readdir/lstat metadata — the private facts inside
 * these files are never opened, hashed, printed or persisted by this tool.
 * Symlinks and unexpected layouts are lstat'd and FLAGGED, never followed.
 * It writes nothing to Postgres/Redis/workspaces; the only write is the
 * optional --out report the owner asked for.
 *
 * The eventual owner decision (consented import into private memory + scrub,
 * scrub-only, or leave) is then one command over this manifest: every entry
 * already carries its target scope and its store-admission verdict.
 *
 * Usage (owner-gated, from the repo root, after `pnpm --filter @ovid/db build`
 * when using --db-url):
 *   node cloud/scripts/migrate/legacyMemoryInventory.ts \
 *     --root /var/lib/ovid/workspaces \
 *     [--db-url postgres://…] [--out manifest.json] [--quiet]
 * Exit codes: 0 = walk completed (issues found are DATA, not errors);
 * 1 = bad arguments or the workspaces root is unreadable.
 */

import { lstat, readdir } from "node:fs/promises";
import { join } from "node:path";

/** True when this file is the Node entry point (inlined: the script is self-contained and runs under plain `node` type-stripping). */
function isMain(metaUrl: string): boolean {
  const entry = process.argv[1];
  if (entry === undefined) return false;
  try {
    return metaUrl === new URL(`file://${entry}`).href || metaUrl.endsWith(entry);
  } catch {
    return false;
  }
}

/** Mirror of the private store's canonical-name rule (agent-core memory.ts). */
const CANONICAL_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+)*\.md$/;
export const LEGACY_MEMORY_LIMITS = { maxFileBytes: 32 * 1024, maxFiles: 32 } as const;

export type LegacyEntryKind = "file" | "symlink" | "directory";

export interface LegacyMemoryFile {
  userId: string;
  source: "shared" | "session";
  sessionId: string | null;
  /** Legacy workspace-relative path, e.g. ".ovid/session-memory/<sid>/notes.md". */
  legacyPath: string;
  name: string;
  sizeBytes: number;
  /** "symlink"/"directory" entries are layout findings, never read through. */
  kind: LegacyEntryKind;
}

export type LegacyIssueCode =
  | "non_canonical_name"
  | "entrypoint_case"
  | "name_too_long"
  | "oversize"
  | "symlink"
  | "unexpected_layout"
  | "case_conflict"
  | "count_cap_pressure"
  | "session_unknown"
  | "session_not_owned"
  | "session_soft_deleted";

export interface LegacyMemoryIssue {
  code: LegacyIssueCode;
  detail: string;
}

export interface InventoryEntry extends LegacyMemoryFile {
  /** The private_memory_files scope this file would map to ("shared" or the sessionId). */
  targetScope: string;
  /** True when every store guard passes, so a future import could take it as-is. */
  importable: boolean;
  issues: LegacyMemoryIssue[];
}

export interface NamespaceSummary {
  userId: string;
  scope: string;
  source: "shared" | "session";
  sessionId: string | null;
  /** Real file count; the store additionally counts a virtual MEMORY.md when absent. */
  files: number;
  /** Store-admissible names + the virtual MEMORY.md — what the 32-cap compares against. */
  countedWithVirtual: number;
  /** Case-variant name groups the store would refuse between these files. */
  caseConflictGroups: string[][];
  /** True when adding any NEW name to this namespace would hit the 32 cap. */
  atCountCap: boolean;
}

export interface LegacyMemoryInventory {
  generatedAt: string;
  workspacesRoot: string;
  entries: InventoryEntry[];
  namespaces: NamespaceSummary[];
  totals: {
    users: number;
    files: number;
    sharedFiles: number;
    sessionFiles: number;
    importableFiles: number;
    filesWithIssues: number;
  };
}

/** Per-file store guards (name, size, layout). Pure. */
export function assessLegacyFile(file: LegacyMemoryFile): LegacyMemoryIssue[] {
  const issues: LegacyMemoryIssue[] = [];
  if (file.kind === "symlink") {
    issues.push({ code: "symlink", detail: "Symlink in the legacy tree — never followed or read" });
  }
  if (file.kind === "directory") {
    issues.push({ code: "unexpected_layout", detail: "Directory where the legacy layout holds flat .md files" });
  }
  if (file.source === "session" && file.sessionId === null) {
    // A file directly under .ovid/session-memory maps to NO session scope.
    issues.push({ code: "unexpected_layout", detail: "File directly under .ovid/session-memory — no session directory, no import target" });
  }
  if (file.name === "memory.md" || (file.name.toLowerCase() === "memory.md" && file.name !== "MEMORY.md")) {
    issues.push({ code: "entrypoint_case", detail: `Case variant of the MEMORY.md entrypoint: ${file.name}` });
  } else if (!CANONICAL_NAME_RE.test(file.name)) {
    issues.push({ code: "non_canonical_name", detail: `Not a plain .md filename: ${file.name}` });
  }
  if (file.name.length > 80) issues.push({ code: "name_too_long", detail: `${file.name.length} characters (max 80)` });
  if (file.kind === "file" && file.sizeBytes > LEGACY_MEMORY_LIMITS.maxFileBytes) {
    issues.push({ code: "oversize", detail: `${file.sizeBytes} bytes (max ${LEGACY_MEMORY_LIMITS.maxFileBytes})` });
  }
  return issues;
}

export interface SessionVerdictRow {
  id: string;
  userId: string;
  /** A Date, or the raw driver string when unparsable — either way non-null means soft-deleted. */
  deletedAt: Date | string | null;
}

/**
 * Join pre-fetched session rows onto session-scoped entries. Pure — the
 * caller owns how rows were read (none, some, all).
 */
export function attachSessionVerdicts(
  entries: InventoryEntry[],
  sessionRows: readonly SessionVerdictRow[],
): void {
  const byId = new Map(sessionRows.map((r) => [r.id, r]));
  for (const e of entries) {
    if (e.source !== "session" || e.sessionId === null) continue;
    const row = byId.get(e.sessionId);
    if (row === undefined) e.issues.push({ code: "session_unknown", detail: "No such session in the database" });
    else if (row.userId !== e.userId) {
      e.issues.push({ code: "session_not_owned", detail: `Session belongs to ${row.userId}` });
    } else if (row.deletedAt !== null) {
      const when = row.deletedAt instanceof Date ? row.deletedAt.toISOString() : String(row.deletedAt);
      e.issues.push({ code: "session_soft_deleted", detail: `Soft-deleted at ${when}` });
    }
    e.importable = e.issues.length === 0;
  }
}

/** Build the full inventory (namespaces, conflicts, cap pressure). Pure. */
export function buildLegacyMemoryInventory(
  files: readonly LegacyMemoryFile[],
): Omit<LegacyMemoryInventory, "generatedAt" | "workspacesRoot"> {
  const scopeOf = (f: LegacyMemoryFile) => (f.source === "shared" ? "shared" : f.sessionId ?? "");
  const entries: InventoryEntry[] = files.map((f) => {
    const issues = assessLegacyFile(f);
    return { ...f, targetScope: scopeOf(f), issues, importable: issues.length === 0 };
  });

  const groups = new Map<string, InventoryEntry[]>();
  for (const e of entries) {
    const key = `${e.userId}:${e.targetScope}`;
    const group = groups.get(key) ?? [];
    group.push(e);
    groups.set(key, group);
  }

  const namespaces: NamespaceSummary[] = [];
  for (const [, group] of [...groups.entries()].sort(([a], [b]) => a.localeCompare(b))) {
    const first = group[0]!;
    const names = group.map((e) => e.name);
    const byLower = new Map<string, string[]>();
    for (const n of names) {
      const k = n.toLowerCase();
      byLower.set(k, [...(byLower.get(k) ?? []), n]);
    }
    const caseConflictGroups = [...byLower.values()]
      .filter((g) => g.length > 1)
      .map((g) => [...new Set(g)].sort());
    for (const conflict of caseConflictGroups) {
      for (const e of group) {
        if (conflict.includes(e.name)) {
          e.issues.push({ code: "case_conflict", detail: `Case-conflicts with ${conflict.filter((n) => n !== e.name).join(", ")}` });
          e.importable = false;
        }
      }
    }
    // Cap pressure counts store-admissible names + the virtual MEMORY.md;
    // existing files stay importable — the cap only blocks NEW names.
    const countedWithVirtual =
      new Set(["MEMORY.md", ...names.filter((n) => CANONICAL_NAME_RE.test(n) && n.toLowerCase() !== "memory.md")]).size;
    const atCountCap = countedWithVirtual + 1 > LEGACY_MEMORY_LIMITS.maxFiles;
    if (atCountCap) {
      for (const e of group) {
        e.issues.push({
          code: "count_cap_pressure",
          detail: `Namespace already holds ${countedWithVirtual} counted files (cap ${LEGACY_MEMORY_LIMITS.maxFiles}); no new file could be added`,
        });
      }
    }
    namespaces.push({
      userId: first.userId,
      scope: first.targetScope,
      source: first.source,
      sessionId: first.sessionId,
      files: group.length,
      countedWithVirtual,
      caseConflictGroups,
      atCountCap,
    });
  }

  return {
    entries,
    namespaces,
    totals: {
      users: new Set(entries.map((e) => e.userId)).size,
      files: entries.length,
      sharedFiles: entries.filter((e) => e.source === "shared").length,
      sessionFiles: entries.filter((e) => e.source === "session").length,
      importableFiles: entries.filter((e) => e.importable).length,
      filesWithIssues: entries.filter((e) => e.issues.length > 0).length,
    },
  };
}

/**
 * Walk the workspaces root READ-ONLY. Metadata only: readdir + lstat. No
 * content is ever read; symlinks are flagged, never followed. Layout
 * deviations from the two legacy shapes (nested dirs, files directly under
 * session-memory, foreign .ovid children) become directory/kind pseudo-
 * entries so the manifest is complete without ever opening anything.
 */
export async function walkLegacyMemoryFiles(workspacesRoot: string): Promise<LegacyMemoryFile[]> {
  let uids: string[];
  try {
    uids = (await readdir(workspacesRoot, { withFileTypes: true })).filter((d) => d.isDirectory()).map((d) => d.name);
  } catch {
    throw new Error(`workspaces root unreadable: ${workspacesRoot}`);
  }
  const out: LegacyMemoryFile[] = [];
  for (const uid of uids) {
    const ovidDir = join(workspacesRoot, uid, "workspace", ".ovid");
    try {
      await readdir(ovidDir, { withFileTypes: true });
    } catch {
      continue; // no .ovid at all — nothing legacy for this user
    }
    await collectFlatDir(join(ovidDir, "memory"), uid, "shared", null, ".ovid/memory", out);
    await collectSessionMemory(ovidDir, uid, out);
    // Any other .ovid child (e.g. MCP state) is surfaced, never hidden.
    for (const ent of await readdir(ovidDir, { withFileTypes: true })) {
      if (ent.name !== "memory" && ent.name !== "session-memory") {
        out.push(await pseudoEntry(join(ovidDir, ent.name), uid, "shared", null, `.ovid/${ent.name}`, ent.name));
      }
    }
  }
  return out;
}

async function collectSessionMemory(ovidDir: string, uid: string, out: LegacyMemoryFile[]): Promise<void> {
  const sessionRoot = join(ovidDir, "session-memory");
  let sessionEntries;
  try {
    sessionEntries = await readdir(sessionRoot, { withFileTypes: true });
  } catch {
    return;
  }
  for (const ent of sessionEntries) {
    const rel = `.ovid/session-memory/${ent.name}`;
    if (ent.isDirectory()) {
      await collectFlatDir(join(sessionRoot, ent.name), uid, "session", ent.name, rel, out);
    } else {
      // A file directly under session-memory matches no legacy surface.
      out.push(await pseudoEntry(join(sessionRoot, ent.name), uid, "session", null, rel, ent.name));
    }
  }
}

async function collectFlatDir(
  dir: string,
  uid: string,
  source: "shared" | "session",
  sessionId: string | null,
  relDir: string,
  out: LegacyMemoryFile[],
): Promise<void> {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return; // the legacy dir simply does not exist for this user
  }
  for (const ent of entries) {
    out.push(await pseudoEntry(join(dir, ent.name), uid, source, sessionId, `${relDir}/${ent.name}`, ent.name));
  }
}

/** One readdir entry → LegacyMemoryFile. lstat, never readlink/readFile. */
async function pseudoEntry(
  full: string,
  uid: string,
  source: "shared" | "session",
  sessionId: string | null,
  legacyPath: string,
  name: string,
): Promise<LegacyMemoryFile> {
  let kind: LegacyEntryKind = "file";
  let sizeBytes = -1;
  try {
    const st = await lstat(full);
    kind = st.isDirectory() ? "directory" : st.isSymbolicLink() ? "symlink" : "file";
    if (kind === "file") sizeBytes = st.size;
  } catch {
    kind = "symlink"; // unreadable: flagged, never followed
  }
  return { userId: uid, source, sessionId, legacyPath, name, sizeBytes, kind };
}

function argValue(argv: string[], name: string): string | undefined {
  const at = argv.indexOf(`--${name}`);
  return at !== -1 && at + 1 < argv.length ? argv[at + 1] : undefined;
}

export async function main(argv: string[]): Promise<number> {
  const root = argValue(argv, "root");
  if (root === undefined) {
    process.stderr.write("usage: legacyMemoryInventory.ts --root <workspacesRoot> [--db-url postgres://…] [--out file.json] [--quiet]\n");
    return 1;
  }
  let files: LegacyMemoryFile[];
  try {
    files = await walkLegacyMemoryFiles(root);
  } catch (err) {
    process.stderr.write(`[FAIL] ${err instanceof Error ? err.message : String(err)}\n`);
    return 1;
  }
  const inventory = buildLegacyMemoryInventory(files);

  // Optional session liveness join. Read-only; a failure surfaces as a
  // warning, never a crash — entries just stay unverified.
  const dbUrl = argValue(argv, "db-url");
  if (dbUrl !== undefined) {
    try {
      const { createDb } = await import("../../packages/db/dist/index.js");
      const db = createDb(dbUrl);
      const ids = [...new Set(inventory.entries.filter((e) => e.source === "session" && e.sessionId !== null).map((e) => e.sessionId!))];
      const rows: SessionVerdictRow[] = [];
      for (let i = 0; i < ids.length; i += 500) {
        const chunk = ids.slice(i, i + 500);
        const res = await db.$client`SELECT id, user_id, deleted_at FROM sessions WHERE id = ANY(${chunk})`;
        for (const r of res as Array<{ id: string; user_id: string; deleted_at: Date | string | null }>) {
          // The drizzle-configured driver returns timestamptz as a STRING;
          // keep it raw — the verdict only needs null vs non-null plus display.
          rows.push({ id: r.id, userId: r.user_id, deletedAt: r.deleted_at });
        }
      }
      await db.$client.end({ timeout: 5 });
      attachSessionVerdicts(inventory.entries, rows);
      inventory.totals.importableFiles = inventory.entries.filter((e) => e.importable).length;
      inventory.totals.filesWithIssues = inventory.entries.filter((e) => e.issues.length > 0).length;
    } catch (err) {
      process.stderr.write(`[warn] session join skipped (db unreadable): ${err instanceof Error ? err.message : String(err)}\n`);
    }
  }

  const manifest: LegacyMemoryInventory = { generatedAt: new Date().toISOString(), workspacesRoot: root, ...inventory };
  const json = JSON.stringify(manifest, null, 2);
  const outPath = argValue(argv, "out");
  if (outPath !== undefined) {
    const { writeFile } = await import("node:fs/promises");
    await writeFile(outPath, `${json}\n`, "utf8");
  }
  if (outPath === undefined || argv.includes("--quiet") !== true) {
    process.stdout.write(json);
  }
  const t = manifest.totals;
  process.stderr.write(
    `\n[ok] ${t.users} user(s), ${t.files} legacy file(s): ${t.sharedFiles} shared, ${t.sessionFiles} session-scoped; ` +
      `${t.importableFiles} importable as-is, ${t.filesWithIssues} with issues (issues are data, not errors)\n`,
  );
  return 0;
}

if (isMain(import.meta.url)) {
  void main(process.argv.slice(2)).then((code) => {
    process.exitCode = code;
  });
}
