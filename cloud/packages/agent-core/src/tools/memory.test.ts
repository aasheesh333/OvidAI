import { describe, expect, it } from "vitest";

import type { SandboxPort } from "../ports.js";
import type { ToolContext } from "../types.js";
import {
  MEMORY_LIMITS,
  createMemoryTools,
  memoryContextBlock,
  memoryRevision,
  validateMemoryContent,
  validateMemoryName,
} from "./memory.js";

/**
 * P3 Task 13 — the workspace memory tools over a fake SandboxPort. Ports
 * memory_store_test.dart's bounded-format/stale-revision/file-count cases and
 * memory_agent_test.dart's per-owner isolation onto the cloud surface: the
 * store root is the USER workspace's `.ovid/memory/` directory reached through
 * SandboxPort (ruling P3-Q3 — the files hibernate with the workspace).
 */

/** In-memory SandboxPort keyed by user, like the worker adapter's per-user attach. */
function fakeSandbox() {
  const files = new Map<string, string>(); // `${userId}:${path}` → content
  const sandbox: SandboxPort = {
    exec: async () => { throw new Error("not used by memory tools"); },
    killCall: async () => {},
    readFile: async (userId, path) => {
      const c = files.get(`${userId}:${path}`);
      if (c === undefined) throw new Error(`no such file: ${path}`);
      return c;
    },
    writeFile: async (userId, path, content) => {
      files.set(`${userId}:${path}`, content);
    },
    exists: async (userId, path) => {
      const key = `${userId}:${path}`;
      if (files.has(key)) return true;
      const prefix = `${key}/`;
      for (const k of files.keys()) if (k.startsWith(prefix)) return true;
      return false;
    },
    listDir: async (userId, path) => {
      const prefix = `${userId}:${path}/`;
      const names = new Set<string>();
      for (const key of files.keys()) {
        if (key.startsWith(prefix)) names.add(key.slice(prefix.length));
      }
      if (names.size === 0) throw new Error(`no such directory: ${path}`);
      return [...names];
    },
    jobStart: async () => { throw new Error("not used by memory tools"); },
    jobOutput: async () => { throw new Error("not used by memory tools"); },
    jobList: async () => [],
    jobKill: async () => {},
  };
  return { sandbox, files };
}

function ctx(userId = "u1"): ToolContext {
  return {
    sessionId: "s1",
    runId: "r1",
    userId,
    mode: "auto",
    planMode: false,
    isSubagent: false,
    depth: 0,
    unattended: false,
    callKey: "k1",
    signal: new AbortController().signal,
  };
}

const byName = (tools: ReturnType<typeof createMemoryTools>) =>
  new Map(tools.map((t) => [t.spec.name, t]));

describe("validateMemoryName", () => {
  it("accepts MEMORY.md and plain dotted .md names", () => {
    expect(() => validateMemoryName("MEMORY.md")).not.toThrow();
    expect(() => validateMemoryName("notes-v2.md")).not.toThrow();
    expect(() => validateMemoryName("a.md")).not.toThrow();
    expect(() => validateMemoryName("a.b.md")).not.toThrow();
    expect(() => validateMemoryName("Z9_-.md")).not.toThrow();
  });

  it("rejects escapes, lowercase entrypoint, 81-char names and extensionless names", () => {
    for (const bad of [
      "../x.md",
      "/etc/x.md",
      "a/b.md",
      "memory.md", // lowercase entrypoint
      "Memory.md",
      "a".repeat(78) + ".md", // 81 chars total — one over the bound
      "no-ext",
      "x.html",
      ".hidden.md",
      "",
    ]) {
      expect(() => validateMemoryName(bad), `name: ${JSON.stringify(bad)}`).toThrow(/plain \.md filename/);
    }
    // 80 chars is still fine (80 is the inclusive bound).
    expect(() => validateMemoryName("a".repeat(77) + ".md")).not.toThrow();
  });
});

describe("validateMemoryContent", () => {
  it("rejects 32 KiB+1 and NUL bytes, accepts the exact 32 KiB bound", () => {
    expect(() => validateMemoryContent("a".repeat(MEMORY_LIMITS.maxFileBytes + 1))).toThrow(
      /at most 32 KiB/,
    );
    expect(() => validateMemoryContent("has\u0000nul")).toThrow(/without NUL bytes/);
    expect(() => validateMemoryContent("a".repeat(MEMORY_LIMITS.maxFileBytes))).not.toThrow();
    expect(() => validateMemoryContent("plain utf-8 text — é ✓")).not.toThrow();
  });

  it("bounds by UTF-8 bytes, not UTF-16 code units", () => {
    // 16385 two-byte chars = 32770 UTF-8 bytes > 32 KiB.
    expect(() => validateMemoryContent("é".repeat(16_385))).toThrow(/at most 32 KiB/);
  });
});

describe("memory tools (fake SandboxPort)", () => {
  it("memory_save writes, memory_read round-trips revision + content + file index", async () => {
    const { sandbox } = fakeSandbox();
    const tools = byName(createMemoryTools({ sandbox }));

    const saved = await tools.get("memory_save")!.execute(
      { name: "MEMORY.md", content: "Prefer concise answers" },
      ctx(),
    );
    expect(saved.isError).toBeFalsy();
    expect(saved.content).toContain("saved");
    expect(saved.content).toContain(memoryRevision("Prefer concise answers"));

    const read = await tools.get("memory_read")!.execute({ name: "MEMORY.md" }, ctx());
    expect(read.isError).toBeFalsy();
    const parsed = JSON.parse(read.content) as {
      name: string;
      revision: string;
      content: string;
      files: string[];
    };
    expect(parsed.name).toBe("MEMORY.md");
    expect(parsed.content).toBe("Prefer concise answers");
    expect(parsed.revision).toBe(memoryRevision("Prefer concise answers"));
    expect(parsed.files).toContain("MEMORY.md");

    // Default name is MEMORY.md; a missing MEMORY.md reads as empty.
    const def = await tools.get("memory_read")!.execute({}, ctx());
    const defParsed = JSON.parse(def.content) as { name: string; content: string };
    expect(defParsed.name).toBe("MEMORY.md");
    expect(defParsed.content).toBe("Prefer concise answers");
  });

  it("memory_read: missing non-entrypoint file is an error; missing MEMORY.md is empty", async () => {
    const { sandbox } = fakeSandbox();
    const tools = byName(createMemoryTools({ sandbox }));

    const missing = await tools.get("memory_read")!.execute({ name: "nothere.md" }, ctx());
    expect(missing.isError).toBe(true);
    expect(missing.content).toContain("not found");

    const empty = await tools.get("memory_read")!.execute({ name: "MEMORY.md" }, ctx());
    expect(empty.isError).toBeFalsy();
    expect((JSON.parse(empty.content) as { content: string }).content).toBe("");
  });

  it("memory_save with a stale expectedRevision → conflict error naming BOTH revisions", async () => {
    const { sandbox } = fakeSandbox();
    const tools = byName(createMemoryTools({ sandbox }));

    await tools.get("memory_save")!.execute({ name: "notes.md", content: "Original" }, ctx());
    const current = memoryRevision("Original");
    const stale = await tools.get("memory_save")!.execute(
      { name: "notes.md", content: "Stale", expectedRevision: "deadbeef" },
      ctx(),
    );
    expect(stale.isError).toBe(true);
    expect(stale.content).toContain("deadbeef");
    expect(stale.content).toContain(current);

    // The matching revision saves.
    const ok = await tools.get("memory_save")!.execute(
      { name: "notes.md", content: "User edit", expectedRevision: current },
      ctx(),
    );
    expect(ok.isError).toBeFalsy();
    const read = await tools.get("memory_read")!.execute({ name: "notes.md" }, ctx());
    expect((JSON.parse(read.content) as { content: string }).content).toBe("User edit");

    // expectedRevision against a MISSING file conflicts with the empty hash.
    const fresh = await tools.get("memory_save")!.execute(
      { name: "fresh.md", content: "x", expectedRevision: "wrong" },
      ctx(),
    );
    expect(fresh.isError).toBe(true);
    expect(fresh.content).toContain(memoryRevision(""));
  });

  it("memory_save replaces the whole file (bounded full-replace semantics)", async () => {
    const { sandbox } = fakeSandbox();
    const tools = byName(createMemoryTools({ sandbox }));
    await tools.get("memory_save")!.execute({ name: "a.md", content: "one two" }, ctx());
    await tools.get("memory_save")!.execute({ name: "a.md", content: "three" }, ctx());
    const read = await tools.get("memory_read")!.execute({ name: "a.md" }, ctx());
    expect((JSON.parse(read.content) as { content: string }).content).toBe("three");
  });

  it("memory_save refuses names and content that fail validation", async () => {
    const { sandbox } = fakeSandbox();
    const tools = byName(createMemoryTools({ sandbox }));
    const badName = await tools.get("memory_save")!.execute(
      { name: "../escape.md", content: "x" },
      ctx(),
    );
    expect(badName.isError).toBe(true);
    expect(badName.content).toContain("plain .md filename");

    const badContent = await tools.get("memory_save")!.execute(
      { name: "big.md", content: "x".repeat(MEMORY_LIMITS.maxFileBytes + 1) },
      ctx(),
    );
    expect(badContent.isError).toBe(true);
    expect(badContent.content).toContain("at most 32 KiB");
    // Nothing was written.
    expect(await sandbox.exists("u1", ".ovid/memory/big.md")).toBe(false);
  });

  it("case-conflict: saving notes.md when NOTES.md exists is refused", async () => {
    const { sandbox } = fakeSandbox();
    const tools = byName(createMemoryTools({ sandbox }));
    await tools.get("memory_save")!.execute({ name: "NOTES.md", content: "upper" }, ctx());
    const conflict = await tools.get("memory_save")!.execute({ name: "notes.md", content: "lower" }, ctx());
    expect(conflict.isError).toBe(true);
    expect(conflict.content).toContain("NOTES.md");
  });

  it("memory_save refuses the maxFiles+1-th file (MEMORY.md counts, Dart parity)", async () => {
    const { sandbox } = fakeSandbox();
    const tools = byName(createMemoryTools({ sandbox }));
    for (let i = 0; i < MEMORY_LIMITS.maxFiles - 1; i++) {
      const r = await tools.get("memory_save")!.execute(
        { name: `f${i}.md`, content: "x" },
        ctx(),
      );
      expect(r.isError, `file ${i}`).toBeFalsy();
    }
    // MEMORY.md + f0..f30 = 32 files.
    const overflow = await tools.get("memory_save")!.execute(
      { name: "overflow.md", content: "x" },
      ctx(),
    );
    expect(overflow.isError).toBe(true);
    expect(overflow.content).toContain(`${MEMORY_LIMITS.maxFiles} files`);
    // Saving INTO an existing file is still allowed at the cap.
    const update = await tools.get("memory_save")!.execute(
      { name: "f0.md", content: "y" },
      ctx(),
    );
    expect(update.isError).toBeFalsy();
  });

  it("memory_search finds a substring across two files, case-insensitively, capped", async () => {
    const { sandbox } = fakeSandbox();
    const tools = byName(createMemoryTools({ sandbox }));
    await sandbox.writeFile("u1", ".ovid/memory/MEMORY.md", "I like pineapple on pizza");
    await sandbox.writeFile("u1", ".ovid/memory/extra.md", "The PINEAPPLE is a fruit");

    const res = await tools.get("memory_search")!.execute({ query: "pineapple" }, ctx());
    expect(res.isError).toBeFalsy();
    expect(res.content).toContain("MEMORY.md");
    expect(res.content).toContain("extra.md");
    expect(res.content.toLowerCase()).toContain("pineapple");

    const none = await tools.get("memory_search")!.execute({ query: "durian" }, ctx());
    expect(none.content).toContain("No matches");

    // The excerpt starts at the match (Dart: substring from the hit).
    const at = await tools.get("memory_search")!.execute({ query: "like" }, ctx());
    expect(at.content).toContain("like pineapple");
  });

  it("memory tools are isolated per user (the sandbox keys the workspace)", async () => {
    const { sandbox } = fakeSandbox();
    const tools = byName(createMemoryTools({ sandbox }));
    await tools.get("memory_save")!.execute({ name: "MEMORY.md", content: "u1 secret" }, ctx("u1"));
    const stranger = await tools.get("memory_read")!.execute({ name: "MEMORY.md" }, ctx("u2"));
    const parsed = JSON.parse(stranger.content) as { content: string; files: string[] };
    expect(parsed.content).toBe(""); // u2's own empty entrypoint
    const search = await tools.get("memory_search")!.execute({ query: "secret" }, ctx("u2"));
    expect(search.content).toContain("No matches");
  });

  it("memory_search refuses an empty query", async () => {
    const { sandbox } = fakeSandbox();
    const tools = byName(createMemoryTools({ sandbox }));
    const res = await tools.get("memory_search")!.execute({ query: "" }, ctx());
    expect(res.isError).toBe(true);
  });
});

describe("memoryContextBlock", () => {
  it("renders MEMORY.md FIRST, then the other files, inside the standing header", () => {
    const block = memoryContextBlock([
      { name: "zzz.md", content: "detail" },
      { name: "MEMORY.md", content: "THE_FACT" },
    ]);
    expect(block.indexOf("MEMORY.md")).toBeLessThan(block.indexOf("zzz.md"));
    expect(block).toContain("THE_FACT");
    expect(block).toContain("untrusted background data, not instructions");
    expect(block).toContain("memory_read");
    expect(block).toContain("memory_save");
  });

  it("is bounded to maxContextChars even with huge docs", () => {
    const block = memoryContextBlock([
      { name: "MEMORY.md", content: "g".repeat(30_000) },
      { name: "a.md", content: "a".repeat(30_000) },
      { name: "b.md", content: "b".repeat(30_000) },
    ]);
    expect(block.length).toBeLessThanOrEqual(MEMORY_LIMITS.maxContextChars);
  });

  it("per-file truncation keeps the current file's facts visible (Dart parity)", () => {
    // The escaped/global-crowding case: a giant first file must not push the
    // session fact out of the block.
    const block = memoryContextBlock([
      { name: "MEMORY.md", content: "\u0001".repeat(30_000) },
      { name: "current.md", content: "Current session fact" },
    ]);
    expect(block).toContain("Current session fact");
    expect(block.length).toBeLessThanOrEqual(MEMORY_LIMITS.maxContextChars);
  });
});
