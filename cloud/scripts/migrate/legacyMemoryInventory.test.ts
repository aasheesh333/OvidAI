import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  assessLegacyFile,
  attachSessionVerdicts,
  buildLegacyMemoryInventory,
  walkLegacyMemoryFiles,
  type InventoryEntry,
  type LegacyMemoryFile,
} from "./legacyMemoryInventory.js";

/**
 * The read-only legacy-memory inventory (R1 release blocker follow-up).
 * These tests pin the store guards the manifest applies and — the part that
 * matters most — that the walker NEVER reads file contents: every tree here
 * plants poison contents and asserts only metadata ever leaves the walker.
 */

const ws = (root: string, uid: string) => join(root, uid, "workspace");

describe("assessLegacyFile (store guards)", () => {
  const f = (o: Partial<LegacyMemoryFile>): LegacyMemoryFile => ({
    userId: "u1", source: "shared", sessionId: null, legacyPath: ".ovid/memory/x", name: "x.md", sizeBytes: 10, kind: "file", ...o,
  });
  const codes = (file: LegacyMemoryFile) => assessLegacyFile(file).map((i) => i.code);

  it("accepts a canonical in-bounds file with no issues", () => {
    expect(assessLegacyFile(f({ name: "MEMORY.md", sizeBytes: 32768 }))).toEqual([]);
    expect(assessLegacyFile(f({ name: "notes-v2.md", sizeBytes: 0 }))).toEqual([]);
  });

  it("flags names, sizes and layouts the private store would refuse", () => {
    expect(codes(f({ name: "memory.md" }))).toContain("entrypoint_case");
    expect(codes(f({ name: "Memory.md" }))).toContain("entrypoint_case");
    expect(codes(f({ name: "memory.json" }))).toContain("non_canonical_name");
    expect(codes(f({ name: "../escape.md" }))).toContain("non_canonical_name");
    expect(codes(f({ name: `${"a".repeat(78)}.md` }))).toContain("name_too_long");
    expect(codes(f({ sizeBytes: 32769 }))).toContain("oversize");
    expect(codes(f({ kind: "symlink", sizeBytes: -1 }))).toContain("symlink");
    expect(codes(f({ kind: "directory", sizeBytes: -1 }))).toContain("unexpected_layout");
  });
});

describe("buildLegacyMemoryInventory (pure)", () => {
  const f = (o: Partial<LegacyMemoryFile> & { name: string; userId?: string; sessionId?: string | null; source?: "shared" | "session" }): LegacyMemoryFile => ({
    userId: "u1", source: "shared", sessionId: null, legacyPath: `.ovid/memory/${o.name}`, sizeBytes: 10, kind: "file", ...o,
  });

  it("maps entries to their target scopes and splits namespaces", () => {
    const inv = buildLegacyMemoryInventory([
      f({ name: "MEMORY.md" }),
      f({ name: "a.md", sessionId: "s-1", source: "session", legacyPath: ".ovid/session-memory/s-1/a.md" }),
      f({ name: "b.md", userId: "u2" }),
    ]);
    expect(inv.entries.map((e) => e.targetScope)).toEqual(["shared", "s-1", "shared"]);
    expect(inv.namespaces.map((n) => `${n.userId}:${n.scope}:${n.files}`).sort()).toEqual(["u1:s-1:1", "u1:shared:1", "u2:shared:1"]);
    expect(inv.totals).toMatchObject({ users: 2, files: 3, sharedFiles: 2, sessionFiles: 1 });
  });

  it("case-conflicts mark BOTH files unimportable; the cap flags pressure without blocking existing names", () => {
    const files = [
      f({ name: "NOTES.md" }),
      f({ name: "notes.md" }),
      ...Array.from({ length: 30 }, (_, i) => f({ name: `f${i}.md` })),
    ];
    const inv = buildLegacyMemoryInventory(files);
    const notes = inv.entries.filter((e) => e.name.toLowerCase() === "notes.md");
    expect(notes.every((e) => !e.importable)).toBe(true);
    expect(notes.every((e) => e.issues.some((i) => i.code === "case_conflict"))).toBe(true);
    // NOTES.md + notes.md are DISTINCT names to the store's Set-counting
    // (faithful to privateMemory.save), so counted = 2 case-variants +
    // virtual MEMORY.md + f0..f29 = 33 > 32.
    const ns = inv.namespaces[0]!;
    expect(ns.countedWithVirtual).toBe(33);
    expect(ns.atCountCap).toBe(true);
    // Existing well-formed files stay importable despite cap pressure.
    expect(inv.entries.find((e) => e.name === "f0.md")!.importable).toBe(true);
    expect(inv.entries.find((e) => e.name === "f0.md")!.issues.map((i) => i.code)).toContain("count_cap_pressure");
  });

  it("counts the virtual MEMORY.md only over store-admissible names", () => {
    const inv = buildLegacyMemoryInventory([
      f({ name: "memory.json" }), // not admissible — not counted
      f({ name: "a.md" }),
    ]);
    expect(inv.namespaces[0]!.countedWithVirtual).toBe(2); // a.md + virtual MEMORY.md
    expect(inv.totals.importableFiles).toBe(1); // only a.md
  });
});

describe("attachSessionVerdicts (pure join)", () => {
  const entry = (sessionId: string): InventoryEntry => ({
    userId: "u1", source: "session", sessionId, legacyPath: `.ovid/session-memory/${sessionId}/MEMORY.md`,
    name: "MEMORY.md", sizeBytes: 5, kind: "file", targetScope: sessionId, importable: true, issues: [],
  });

  it("marks unknown, foreign-owned and soft-deleted sessions", () => {
    const a = entry("s-live");
    const b = entry("s-gone");
    const c = entry("s-foreign");
    const d = entry("s-dead");
    attachSessionVerdicts([a, b, c, d], [
      { id: "s-live", userId: "u1", deletedAt: null },
      { id: "s-foreign", userId: "someone-else", deletedAt: null },
      { id: "s-dead", userId: "u1", deletedAt: new Date("2026-01-01T00:00:00Z") },
    ]);
    expect(a.importable).toBe(true);
    expect(b.issues.map((i) => i.code)).toEqual(["session_unknown"]);
    expect(c.issues.map((i) => i.code)).toEqual(["session_not_owned"]);
    expect(d.issues.map((i) => i.code)).toEqual(["session_soft_deleted"]);
    expect([b, c, d].every((e) => !e.importable)).toBe(true);
  });

  it("leaves shared-scope entries untouched", () => {
    const shared: InventoryEntry = {
      userId: "u1", source: "shared", sessionId: null, legacyPath: ".ovid/memory/MEMORY.md",
      name: "MEMORY.md", sizeBytes: 5, kind: "file", targetScope: "shared", importable: true, issues: [],
    };
    attachSessionVerdicts([shared], []);
    expect(shared.issues).toEqual([]);
    expect(shared.importable).toBe(true);
  });
});

describe("walkLegacyMemoryFiles (read-only fs walker)", () => {
  let root: string;

  beforeAll(async () => {
    root = await mkdtemp(join(tmpdir(), "ovid-legacy-mem-"));
    // u1: the full legacy shape, with poison contents everywhere.
    await mkdir(ws(root, "u1") + "/.ovid/memory", { recursive: true });
    await mkdir(ws(root, "u1") + "/.ovid/session-memory/s-1", { recursive: true });
    await mkdir(ws(root, "u1") + "/.ovid/session-memory/s-2", { recursive: true });
    await writeFile(ws(root, "u1") + "/.ovid/memory/MEMORY.md", "POISON shared fact");
    await writeFile(ws(root, "u1") + "/.ovid/memory/memory.json", "POISON mcp graph");
    await writeFile(ws(root, "u1") + "/.ovid/session-memory/s-1/notes.md", "POISON session fact");
    await writeFile(ws(root, "u1") + "/.ovid/session-memory/s-2/MEMORY.md", "x".repeat(32769)); // oversize
    // A nested dir and a symlink inside the legacy tree.
    await mkdir(ws(root, "u1") + "/.ovid/memory/nested-dir");
    await symlink("/etc/passwd", ws(root, "u1") + "/.ovid/memory/evil.md");
    // A file directly under session-memory (no session dir) — layout finding.
    await writeFile(ws(root, "u1") + "/.ovid/session-memory/stray.md", "POISON stray");
    // u2: no .ovid at all.
    await mkdir(ws(root, "u2"), { recursive: true });
    await writeFile(ws(root, "u2") + "/normal.txt", "POISON workspace file");
    // u3: an .ovid with only foreign children.
    await mkdir(ws(root, "u3") + "/.ovid/state", { recursive: true });
  }, 30_000);

  afterAll(async () => {
    await rm(root, { recursive: true, force: true });
  });

  it("collects metadata only — contents never leave the walker, symlinks never followed", async () => {
    const files = await walkLegacyMemoryFiles(root);
    // Nothing anywhere in the manifest exposes file contents.
    const json = JSON.stringify(files);
    expect(json).not.toContain("POISON");
    // u2 (no .ovid) contributes nothing.
    expect(files.every((f) => f.userId !== "u2")).toBe(true);

    const u1 = files.filter((f) => f.userId === "u1");
    const byPath = new Map(u1.map((f) => [f.legacyPath, f]));

    expect(byPath.get(".ovid/memory/MEMORY.md")).toMatchObject({ source: "shared", kind: "file", sizeBytes: 18, sessionId: null });
    expect(byPath.get(".ovid/memory/memory.json")).toMatchObject({ kind: "file" });
    expect(byPath.get(".ovid/session-memory/s-1/notes.md")).toMatchObject({ source: "session", sessionId: "s-1" });
    expect(byPath.get(".ovid/session-memory/s-2/MEMORY.md")).toMatchObject({ sizeBytes: 32769 });
    expect(byPath.get(".ovid/memory/evil.md")).toMatchObject({ kind: "symlink", sizeBytes: -1 });
    expect(byPath.get(".ovid/memory/nested-dir")).toMatchObject({ kind: "directory" });
    expect(byPath.get(".ovid/session-memory/stray.md")).toMatchObject({ source: "session", sessionId: null });
    // Foreign .ovid children are surfaced under their own user, never hidden.
    const u3 = files.filter((f) => f.userId === "u3");
    expect(u3.find((f) => f.legacyPath === ".ovid/state")).toMatchObject({ kind: "directory", source: "shared" });

    const inv = buildLegacyMemoryInventory(u1);
    expect(inv.totals.filesWithIssues).toBeGreaterThan(0);
    // The only clean files in u1's tree are MEMORY.md (shared) and s-1/notes.md.
    expect(inv.entries.filter((e) => e.importable).map((e) => e.legacyPath).sort()).toEqual([
      ".ovid/memory/MEMORY.md",
      ".ovid/session-memory/s-1/notes.md",
    ]);
    // Session verdicts arrive through the pure join, not the walker.
    attachSessionVerdicts(inv.entries, [{ id: "s-1", userId: "u1", deletedAt: null }]);
    expect(inv.entries.find((e) => e.legacyPath === ".ovid/session-memory/s-1/notes.md")!.importable).toBe(true);
    expect(inv.entries.find((e) => e.legacyPath === ".ovid/session-memory/s-2/MEMORY.md")!.importable).toBe(false); // oversize
  });

  it("fails closed on an unreadable root", async () => {
    await expect(walkLegacyMemoryFiles(join(root, "nope"))).rejects.toThrow(/unreadable/);
  });
});
