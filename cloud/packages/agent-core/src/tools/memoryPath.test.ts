// Spec §2.B.1: "Session Memory (/workspace/.ovid/session_memory.md):
// auto-created and auto-maintained per session".
//
// Memory facts live in the authenticated private store (that is the durable,
// concurrency-safe copy — a sandbox file alone would vanish on hibernation).
// What was missing is the SPEC PATH: the agent's own file tools never saw a
// session memory file at /workspace/.ovid/session_memory.md, so the documented
// location did not exist.

import { describe, expect, it } from "vitest";

import type { PrivateMemoryNamespace, PrivateMemoryStore } from "@ovid/shared";
import type { ToolContext } from "../types.js";
import {
  SESSION_MEMORY_PATH,
  createMemoryTools,
  mirrorSessionMemory,
} from "./memory.js";

const ctx = (): ToolContext => ({
  sessionId: "chat-1",
  runId: "run-1",
  userId: "u1",
  mode: "auto",
  planMode: false,
  isSubagent: false,
  depth: 0,
  unattended: false,
  callKey: "call-1",
  signal: new AbortController().signal,
});

/** An in-memory PrivateMemoryStore good enough for the entrypoint. */
function store(): PrivateMemoryStore & { rows: Map<string, string> } {
  const rows = new Map<string, string>();
  const key = (ns: PrivateMemoryNamespace, name: string) =>
    `${ns.sessionId ?? ns.projectId ?? "shared"}:${name}`;
  return {
    rows,
    async read(_uid, ns, name) {
      const content = rows.get(key(ns, name));
      return content === undefined
        ? null
        : { name, content, revision: `rev-${content.length}` };
    },
    async save(_uid, ns, name, content) {
      rows.set(key(ns, name), content);
      return { name, revision: `rev-${content.length}` };
    },
    async list(_uid, ns) {
      const prefix = `${ns.sessionId ?? ns.projectId ?? "shared"}:`;
      return [...rows.keys()]
        .filter((k) => k.startsWith(prefix))
        .map((k) => ({ name: k.slice(prefix.length), sizeBytes: 0 }));
    },
    async remove(_uid, ns, name) {
      return rows.delete(key(ns, name));
    },
    async search() {
      return [];
    },
  } as unknown as PrivateMemoryStore & { rows: Map<string, string> };
}

function tools(s: PrivateMemoryStore, mirror?: (c: ToolContext, content: string) => Promise<void>) {
  const list = createMemoryTools({
    store: s,
    ...(mirror !== undefined ? { mirrorEntrypoint: mirror } : {}),
  });
  const byName = (n: string) => {
    const t = list.find((x) => x.spec.name === n);
    if (t === undefined) throw new Error(`missing ${n}`);
    return t;
  };
  return { read: byName("memory_read"), save: byName("memory_save") };
}

describe("session memory at the spec path", () => {
  it("is the path the spec names", () => {
    expect(SESSION_MEMORY_PATH).toBe("/workspace/.ovid/session_memory.md");
  });

  it("writes the entrypoint through to the spec path on save", async () => {
    const s = store();
    const written: Array<{ ctx: ToolContext; content: string }> = [];
    const t = tools(s, async (c, content) => {
      written.push({ ctx: c, content });
    });

    await t.save.execute({ content: "# Session\n- user prefers TS" }, ctx());

    expect(written).toHaveLength(1);
    expect(written[0]!.ctx.sessionId).toBe("chat-1");
    expect(written[0]!.content).toContain("user prefers TS");
  });

  it("does not mirror a NON-entrypoint file to the entrypoint path", async () => {
    const s = store();
    const written: string[] = [];
    const t = tools(s, async (_c, content) => {
      written.push(content);
    });

    await t.save.execute({ name: "notes.md", content: "scratch" }, ctx());

    expect(written).toEqual([]);
  });

  it("a mirror failure never fails the save (the durable copy is the record)", async () => {
    const s = store();
    const t = tools(s, async () => {
      throw new Error("sandbox is down");
    });

    const result = await t.save.execute({ content: "important" }, ctx());

    expect(result.isError).not.toBe(true);
    expect(result.content).toContain("saved");
  });
});

describe("materializeSessionMemory", () => {
  it("writes the stored entrypoint to the spec path before the first turn", async () => {
    const s = store();
    const written: Array<{ path: string; content: string }> = [];
    await mirrorSessionMemory({
      store: s,
      userId: "u1",
      sessionId: "chat-1",
      write: async (path, content) => {
        written.push({ path, content });
      },
    }).catch(() => undefined);
    // Nothing stored yet: no file is invented.
    expect(written).toEqual([]);

    await s.save("u1", { sessionId: "chat-1", shared: false }, "MEMORY.md", "- knows TS");
    await mirrorSessionMemory({
      store: s,
      userId: "u1",
      sessionId: "chat-1",
      write: async (path, content) => {
        written.push({ path, content });
      },
    });

    expect(written).toEqual([
      { path: SESSION_MEMORY_PATH, content: "- knows TS" },
    ]);
  });
});
