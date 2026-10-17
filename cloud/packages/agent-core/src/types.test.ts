import { describe, expect, it } from "vitest";

import type { Tool } from "./types.js";
import { createMemoryStateStore, createToolRegistry } from "./index.js";

function fakeTool(name: string): Tool {
  return {
    spec: { name, description: name, parameters: { type: "object" } },
    timeoutMs: 1000,
    execute: async () => ({ content: name }),
  };
}

describe("createToolRegistry", () => {
  it("get() returns the registered tool by name", () => {
    const a = fakeTool("a");
    const r = createToolRegistry([a, fakeTool("b")]);
    expect(r.get("a")).toBe(a);
  });

  it("get() returns undefined for a missing tool", () => {
    const r = createToolRegistry([fakeTool("a"), fakeTool("b")]);
    expect(r.get("missing")).toBeUndefined();
  });

  it("all() preserves insertion order (roster ordering is a later task's job)", () => {
    const tools = [fakeTool("c"), fakeTool("a"), fakeTool("b")];
    const r = createToolRegistry(tools);
    expect(r.all().map((t) => t.spec.name)).toEqual(["c", "a", "b"]);
  });

  it("all() returns a readonly copy that does not alias the input array", () => {
    const tools = [fakeTool("a")];
    const r = createToolRegistry(tools);
    expect(r.all()).not.toBe(tools);
    expect(r.all().length).toBe(1);
  });
});

describe("createMemoryStateStore", () => {
  it("get() on an unknown session returns the zero state with mode 'auto'", async () => {
    const store = createMemoryStateStore();
    expect(await store.get("unknown-session")).toEqual({
      todos: [],
      goal: null,
      presetId: null,
      planMode: false,
      planPreMode: null,
      pendingPlanMode: null,
      compaction: null,
      mode: "auto",
      modelPin: null,
      activeSkillScopes: [],
    });
  });

  it("get() returns the same zero state on distinct unknown sessions", async () => {
    const store = createMemoryStateStore();
    const a = await store.get("s1");
    const b = await store.get("s2");
    expect(a).not.toBe(b);
    expect(a.mode).toBe("auto");
    expect(b.mode).toBe("auto");
  });

  it("patch() merges shallowly and persists for the session", async () => {
    const store = createMemoryStateStore();
    await store.patch("s1", { planMode: true, modelPin: "opus" });
    const state = await store.get("s1");
    expect(state.planMode).toBe(true);
    expect(state.modelPin).toBe("opus");
    expect(state.mode).toBe("auto");
  });

  it("patch() is shallow: an array field replaces wholesale, other fields survive", async () => {
    const store = createMemoryStateStore();
    await store.patch("s1", {
      todos: [{ content: "x", status: "pending" }],
      presetId: "p1",
    });
    await store.patch("s1", {
      todos: [{ content: "y", status: "in_progress" }],
    });
    const state = await store.get("s1");
    expect(state.todos).toEqual([{ content: "y", status: "in_progress" }]);
    expect(state.presetId).toBe("p1");
  });

  it("patch() on one session does not leak into another", async () => {
    const store = createMemoryStateStore();
    await store.patch("s1", { planMode: true });
    const other = await store.get("s2");
    expect(other.planMode).toBe(false);
  });
});
