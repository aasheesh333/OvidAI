import { describe, expect, it } from "vitest";

import type { AgentMessage, ToolSpec } from "./types.js";
import {
  MAX_CACHE_BREAKPOINTS,
  cacheModeFor,
  canonicalJson,
  canonicalToolJson,
  canonicalTools,
  markCacheBreakpoints,
  parsePromptCacheOverride,
} from "./promptCache.js";

// ── fixtures (ported from test/prompt_cache_test.dart) ─────────────────────

function tool(name: string, description = "d"): ToolSpec {
  return {
    name,
    description,
    // key order deliberately unsorted; `required` array order is semantic
    parameters: {
      type: "object",
      required: ["b", "a"],
      properties: {
        z: { type: "string" },
        a: { type: "string" },
      },
    },
  };
}

/** Number of cacheControl marks in a serialised value. */
function countMarks(v: unknown): number {
  return JSON.stringify(v).split('"cacheControl"').length - 1;
}

/** Strips cacheControl marks (the prefix comparison is content-based). */
function stripMarks<T>(v: T): T {
  return JSON.parse(
    JSON.stringify(v, (k, val) => (k === "cacheControl" ? undefined : val)),
  ) as T;
}

const SYSTEM: AgentMessage[] = [{ role: "system", content: "STABLE SYSTEM" }];

/** Conversation rows in request order: u0, then N × (assistant tool-call + tool result). */
function convo(turns: number): AgentMessage[] {
  const m: AgentMessage[] = [{ role: "user", content: "u0" }];
  for (let i = 0; i < turns; i++) {
    m.push({
      role: "assistant",
      content: `thinking ${i}`,
      toolCalls: [{ id: `c${i}`, name: "a", args: {} }],
    });
    m.push({ role: "tool", toolCallId: `c${i}`, content: `result ${i}` });
  }
  return m;
}

function volatileMsg(content: string): AgentMessage {
  return { role: "user", content, volatile: true };
}

// ── parsePromptCacheOverride ────────────────────────────────────────────────

describe("parsePromptCacheOverride", () => {
  it("accepts the three names case-insensitively and trims", () => {
    expect(parsePromptCacheOverride("auto")).toBe("auto");
    expect(parsePromptCacheOverride("AUTO")).toBe("auto");
    expect(parsePromptCacheOverride("on")).toBe("on");
    expect(parsePromptCacheOverride("OFF")).toBe("off");
    expect(parsePromptCacheOverride("  off  ")).toBe("off");
  });

  it("unknown or missing values fall back to auto", () => {
    expect(parsePromptCacheOverride(null)).toBe("auto");
    expect(parsePromptCacheOverride(undefined)).toBe("auto");
    expect(parsePromptCacheOverride("")).toBe("auto");
    expect(parsePromptCacheOverride("garbage")).toBe("auto");
    expect(parsePromptCacheOverride("sometimes")).toBe("auto");
  });
});

// ── cacheModeFor ────────────────────────────────────────────────────────────

describe("cacheModeFor", () => {
  it('"off" always disables (pinned)', () => {
    expect(cacheModeFor("anthropic", true, "off")).toBe("none");
    expect(cacheModeFor("openai", true, "off")).toBe("none");
    expect(cacheModeFor("openai", false, "off")).toBe("none");
  });

  it("anthropic-format endpoints are anthropicNative for on/auto (pinned)", () => {
    expect(cacheModeFor("anthropic", true, "auto")).toBe("anthropicNative");
    expect(cacheModeFor("anthropic", true, "on")).toBe("anthropicNative");
    // Dart resolve(): the FORMAT check alone decides — an explicitly
    // anthropic-format endpoint speaks the Messages API, which defines
    // cache_control. isNativeAnthropic only carries meaning for openai-format
    // routes (the claude-route marker).
    expect(cacheModeFor("anthropic", false, "auto")).toBe("anthropicNative");
  });

  it("openai-format without the claude-route marker stays implicit on auto (pinned)", () => {
    expect(cacheModeFor("openai", false, "auto")).toBe("implicit");
  });

  it("openai-format with claude-route marker + on → openaiBlocks (pinned)", () => {
    expect(cacheModeFor("openai", true, "on")).toBe("openaiBlocks");
  });

  it("openai-format with claude-route marker + auto → openaiBlocks (B3 ruling)", () => {
    // Dart prompt_cache.dart resolve(), auto branch: a KNOWN Claude route
    // (model contains "claude" AND isOvidCloud || openRouter host) gets
    // openaiBlocks even on auto. The isNativeAnthropic marker stands for
    // exactly that "known claude route behind an openai-format proxy" fact,
    // so Dart's logic dictates openaiBlocks here, not implicit.
    expect(cacheModeFor("openai", true, "auto")).toBe("openaiBlocks");
  });

  it('openai-format + explicit "on" → openaiBlocks even without the marker', () => {
    // Dart resolve(): override == on → openaiBlocks on ANY openai-format
    // endpoint ("unknown/custom endpoints never receive markers unless the
    // user turns them on for that provider" — turning them on means markers).
    expect(cacheModeFor("openai", false, "on")).toBe("openaiBlocks");
  });
});

// ── canonicalTools / canonicalJson / canonicalToolJson ─────────────────────

describe("canonicalTools", () => {
  it("sorts by name regardless of input order", () => {
    const a = canonicalTools([tool("b"), tool("a"), tool("c")]);
    const b = canonicalTools([tool("c"), tool("b"), tool("a")]);
    expect(a.map((t) => t.name)).toEqual(["a", "b", "c"]);
    expect(JSON.stringify(a)).toBe(JSON.stringify(b));
  });

  it("recursively sorts object keys (properties: z,a → a,z)", () => {
    const [first] = canonicalTools([tool("x")]);
    const props = first.parameters.properties as Record<string, unknown>;
    expect(Object.keys(props)).toEqual(["a", "z"]);
  });

  it("keeps array order (semantic) — required stays [b,a]", () => {
    const [first] = canonicalTools([tool("x")]);
    expect(first.parameters.required).toEqual(["b", "a"]);
  });

  it("preserves input order for equal names (stable tiebreak, Dart parity)", () => {
    const a = tool("same", "first");
    const b = tool("same", "second");
    expect(canonicalTools([b, a]).map((t) => t.description)).toEqual([
      "second",
      "first",
    ]);
  });

  it("does not mutate its input", () => {
    const tools = [tool("b"), tool("a")];
    canonicalTools(tools);
    expect(JSON.stringify(tools)).toBe(JSON.stringify([tool("b"), tool("a")]));
  });
});

describe("canonicalJson", () => {
  it("is byte-identical for recursively swapped key orders", () => {
    expect(canonicalJson({ a: { y: 1, x: 2 } })).toBe(
      canonicalJson({ a: { x: 2, y: 1 } }),
    );
  });

  it("sorts keys at every nesting depth", () => {
    expect(canonicalJson({ b: { d: 1, c: 2 }, a: 3 })).toBe(
      '{"a":3,"b":{"c":2,"d":1}}',
    );
  });

  it("is byte-identical for arbitrary tool-arg objects (Task 14 canonArgs reuse)", () => {
    const args1 = { path: "/tmp/x", nested: { z: 1, y: 2, a: { q: true, b: false } } };
    const args2 = { nested: { a: { b: false, q: true }, y: 2, z: 1 }, path: "/tmp/x" };
    expect(canonicalJson(args1)).toBe(canonicalJson(args2));
  });

  it("keeps array order (arrays are semantic)", () => {
    expect(canonicalJson({ x: [3, 1, 2] })).toBe('{"x":[3,1,2]}');
  });

  it("passes primitives through", () => {
    expect(canonicalJson("s")).toBe('"s"');
    expect(canonicalJson(7)).toBe("7");
    expect(canonicalJson(null)).toBe("null");
    expect(canonicalJson(true)).toBe("true");
  });
});

describe("canonicalToolJson", () => {
  it("is load-order independent (the byte-stability contract)", () => {
    expect(canonicalToolJson([tool("c"), tool("a"), tool("b")])).toBe(
      canonicalToolJson([tool("b"), tool("c"), tool("a")]),
    );
  });

  it("equals canonicalJson over the already-canonical roster", () => {
    const sorted = canonicalTools([tool("b"), tool("a")]);
    expect(canonicalToolJson(sorted)).toBe(canonicalJson(sorted));
  });
});

// ── markCacheBreakpoints ────────────────────────────────────────────────────

describe("markCacheBreakpoints", () => {
  it("MAX_CACHE_BREAKPOINTS is 4", () => {
    expect(MAX_CACHE_BREAKPOINTS).toBe(4);
  });

  it("marks final tool, final system block and the last two non-volatile messages (≤4)", () => {
    const messages = convo(6);
    const tools = canonicalTools([tool("b"), tool("a")]);
    const r = markCacheBreakpoints(SYSTEM, messages, tools);

    const total =
      countMarks(r.system) + countMarks(r.messages) + countMarks(r.tools);
    expect(total).toBeLessThanOrEqual(MAX_CACHE_BREAKPOINTS);
    expect(total).toBe(4);

    // final tool (last of the canonical roster)
    expect(r.tools).toHaveLength(2);
    expect(r.tools[r.tools.length - 1].cacheControl).toEqual({
      type: "ephemeral",
    });
    // final system block
    expect(r.system[r.system.length - 1].cacheControl).toEqual({
      type: "ephemeral",
    });
    // the LAST two non-volatile messages (tail is a tool-result row)
    const markedIdx = r.messages
      .map((m, i) => (m.cacheControl ? i : -1))
      .filter((i) => i >= 0);
    expect(markedIdx).toEqual([r.messages.length - 2, r.messages.length - 1]);
  });

  it("marks carry no ttl by default ({type:'ephemeral'} — 5m default)", () => {
    const r = markCacheBreakpoints(SYSTEM, convo(1), [tool("a")]);
    expect(JSON.stringify(r)).not.toContain('"ttl"');
  });

  it("never marks a volatile:true message (the volatile tail stays unmarked)", () => {
    const messages = [...convo(2), volatileMsg("GOAL: x\nTODO: y")];
    const r = markCacheBreakpoints(SYSTEM, messages, [tool("a")]);
    expect(r.messages[r.messages.length - 1].cacheControl).toBeUndefined();
    const marked = r.messages.filter((m) => m.cacheControl);
    expect(marked).toHaveLength(2);
    expect(marked.every((m) => !m.volatile)).toBe(true);
    // the boundary mark lands before the volatile row (Dart parity)
    const markedIdx = r.messages.map((m, i) => (m.cacheControl ? i : -1));
    expect(Math.max(...markedIdx)).toBeLessThan(messages.length - 1);
  });

  it("never marks a volatile system block; falls back to the last stable one", () => {
    const system: AgentMessage[] = [
      { role: "system", content: "STABLE" },
      { role: "system", content: "TODO NOW", volatile: true },
    ];
    const r = markCacheBreakpoints(system, [], [tool("a")]);
    expect(r.system[1].cacheControl).toBeUndefined();
    expect(r.system[0].cacheControl).toEqual({ type: "ephemeral" });
  });

  it("skips content-less messages when placing message marks", () => {
    const messages: AgentMessage[] = [
      { role: "user", content: "u0" },
      { role: "user", content: "   " },
      { role: "user", content: "u2" },
    ];
    const r = markCacheBreakpoints([], messages, []);
    expect(r.messages[1].cacheControl).toBeUndefined();
    expect(r.messages[2].cacheControl).toEqual({ type: "ephemeral" });
    expect(r.messages[0].cacheControl).toEqual({ type: "ephemeral" });
  });

  it("marking twice is a no-op (idempotent)", () => {
    const messages = [...convo(3), volatileMsg("clock 10:00")];
    const first = markCacheBreakpoints(SYSTEM, messages, [tool("b"), tool("a")]);
    const second = markCacheBreakpoints(first.system, first.messages, first.tools);
    expect(second).toEqual(first);
    expect(
      countMarks(second.system) + countMarks(second.messages) + countMarks(second.tools),
    ).toBe(
      countMarks(first.system) + countMarks(first.messages) + countMarks(first.tools),
    );
  });

  it("does not mutate its inputs", () => {
    const messages = convo(2);
    const tools = [tool("b"), tool("a")];
    markCacheBreakpoints(SYSTEM, messages, tools);
    expect(countMarks(SYSTEM)).toBe(0);
    expect(countMarks(messages)).toBe(0);
    expect(countMarks(tools)).toBe(0);
  });

  it("handles the empty edge: no tools, no system, no messages", () => {
    const r = markCacheBreakpoints([], [], []);
    expect(r.system).toEqual([]);
    expect(r.messages).toEqual([]);
    expect(r.tools).toEqual([]);
  });

  it("without tools the budget flows to nothing extra (still ≤ system + 2 messages)", () => {
    const r = markCacheBreakpoints(SYSTEM, convo(2), []);
    expect(countMarks(r.tools)).toBe(0);
    expect(
      countMarks(r.system) + countMarks(r.messages),
    ).toBe(3);
  });
});

// ── byte-stability pin (Review Focus #3, ported golden tests) ───────────────

describe("golden: prefix stability across turns", () => {
  const TOOLS = [tool("zeta"), tool("alpha"), tool("mid")];

  /** The Task-15 pipeline: canonicalTools first, then markCacheBreakpoints. */
  function pipeline(messages: AgentMessage[]) {
    const canonical = canonicalTools(TOOLS);
    return { ...markCacheBreakpoints(SYSTEM, messages, canonical), canonical };
  }

  it("turn N+1 request extends turn N byte-for-byte (marks stripped)", () => {
    const t1 = convo(3);
    const t2 = [...convo(3), { role: "tool", toolCallId: "c3", content: "result 3" }];
    const b1 = pipeline(t1);
    const b2 = pipeline(t2);

    // stable tool bytes across both builds
    expect(canonicalToolJson(b2.tools)).toBe(canonicalToolJson(b1.tools));
    // stable system block bytes across both builds
    expect(JSON.stringify(b2.system)).toBe(JSON.stringify(b1.system));
    // history prefix identical once marks are stripped
    const m1 = stripMarks(b1.messages);
    const m2 = stripMarks(b2.messages);
    expect(JSON.stringify(m2.slice(0, m1.length))).toBe(JSON.stringify(m1));
  });

  it("tool load order does not change the serialised prefix", () => {
    const a = markCacheBreakpoints(SYSTEM, convo(2), canonicalTools([tool("c"), tool("a"), tool("b")]));
    const b = markCacheBreakpoints(SYSTEM, convo(2), canonicalTools([tool("b"), tool("c"), tool("a")]));
    expect(canonicalToolJson(a.tools)).toBe(canonicalToolJson(b.tools));
    expect(JSON.stringify(a.system)).toBe(JSON.stringify(b.system));
  });

  it("per-turn volatile changes do not alter the cached prefix", () => {
    function prefix(volatileContent: string): string {
      const messages = [...convo(2), volatileMsg(volatileContent)];
      const r = markCacheBreakpoints(SYSTEM, messages, canonicalTools([tool("a")]));
      // prefix = everything before the volatile tail row, marks stripped
      return JSON.stringify(
        stripMarks([r.tools, r.messages.slice(0, r.messages.length - 1)]),
      );
    }
    expect(prefix("clock 10:00 todo A")).toBe(prefix("clock 10:05 todo B"));
  });
});
