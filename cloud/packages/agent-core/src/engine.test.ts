// Agent engine (P3 Task 15) — TDD step 1.
//
// The engine wraps the turn loop with the per-session event sink (Redis
// append + Postgres mirror — P1 emit parity), the per-session run token
// (cancel + generation), and the never-throw contract. Ported legs:
// test/hard_stop_test.dart (:106 idle cancel is a no-op), test/
// session_stop_isolation_test.dart (:55/:181 targeted stop), test/
// agent_stop_fix_test.dart (:227 old run does not steal the successor's
// bucket — the generation guard).

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createDb,
  eventMirror,
  messages,
  migrate,
  runs,
  sessions,
  users,
  type Db,
} from "@ovid/db";
import type { EventLog } from "@ovid/events";
import type { SessionEvent, SessionEventType } from "@ovid/shared";

import { createAgentEngine, type AgentEngineDeps } from "./engine.js";
import type { HookEngine, HookStopResult, SessionStateStore, SkillCatalog } from "./ports.js";
import { createMemoryStateStore } from "./ports.js";
import { createToolRegistry, type AgentTransport, type AgentResponse } from "./types.js";
import { TransientModelError } from "./transport/errors.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

function fakeEvents(): EventLog & { events: SessionEvent[] } {
  const events: SessionEvent[] = [];
  let seq = 0;
  return {
    events,
    async append(sessionId, type: SessionEventType, payload) {
      seq += 1;
      const event: SessionEvent = {
        sessionId,
        seq: `${Date.now()}-${seq}`,
        type,
        payload,
        ts: new Date().toISOString(),
      };
      events.push(event);
      return event;
    },
    async readSince() {
      return [];
    },
    async subscribe() {
      return async () => {};
    },
  };
}

/** A transport whose first response waits until aborted (cancel legs). */
function abortableTransport(): {
  transport: AgentTransport;
  started: Promise<void>;
  sawAbort: () => boolean;
} {
  let startedResolve!: () => void;
  const started = new Promise<void>((r) => {
    startedResolve = r;
  });
  let aborted = false;
  const transport: AgentTransport = {
    apiFormat: "openai",
    async stream(_req, _h, signal): Promise<AgentResponse> {
      startedResolve();
      await new Promise<void>((_resolve, reject) => {
        if (signal.aborted) {
          aborted = true;
          reject(new Error("aborted"));
          return;
        }
        signal.addEventListener(
          "abort",
          () => {
            aborted = true;
            reject(new Error("aborted"));
          },
          { once: true },
        );
      });
      throw new Error("unreachable");
    },
  };
  return { transport, started, sawAbort: () => aborted };
}

function textTransport(text: string, delayMs = 0): AgentTransport {
  return {
    apiFormat: "openai",
    async stream(_req, h): Promise<AgentResponse> {
      if (delayMs > 0) await new Promise((r) => setTimeout(r, delayMs));
      h.onTextDelta(text);
      return {
        content: text,
        thinking: "",
        toolCalls: [],
        finishReason: "stop",
        usage: null,
      };
    },
  };
}

function hooksWithStop(stop: HookStopResult): HookEngine {
  return {
    async hasListeners() {
      return false;
    },
    async fire() {},
    async fireDetailed() {
      return { output: "", systemMessages: [], promptBlockReason: null };
    },
    async fireGate() {
      return { decision: "allow", reason: null, bypassPermission: false, decidedByPlugin: null, deniedByPlugin: null };
    },
    async fireStop() {
      return stop;
    },
    sessionContextFor() {
      return "";
    },
    promptContextFor() {
      return null;
    },
  };
}

const skills: SkillCatalog = {
  async list() {
    return [];
  },
  async load() {
    return null;
  },
};

describe.skipIf(!TEST_DATABASE_URL)("createAgentEngine (real postgres)", () => {
  let db: Db;

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  async function seed(): Promise<{ userId: string; sessionId: string; runId: string }> {
    const uid = `en-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
    await users.ensure(db, uid, null);
    const session = await sessions.create(db, uid, null);
    const prompt = await messages.append(db, {
      sessionId: session.id,
      role: "user",
      content: "hello",
    });
    const run = await runs.create(db, { sessionId: session.id, promptMessageId: prompt.id });
    await runs.claimNext(db, run.id);
    return { userId: uid, sessionId: session.id, runId: run.id };
  }

  function makeDeps(o: {
    transport: AgentTransport;
    hooks?: HookEngine;
    nullKey?: boolean;
    state?: SessionStateStore;
  }): AgentEngineDeps & { events: EventLog & { events: SessionEvent[] } } {
    const events = fakeEvents();
    return {
      db,
      events,
      sink: { async emit() {} },
      state: o.state ?? createMemoryStateStore(),
      keys: {
        async resolve() {
          return o.nullKey === true
            ? null
            : { kind: "litellm" as const, apiKey: "sk-test", baseUrl: "https://litellm.test", model: "m" };
        },
      },
      transports: { openai: o.transport, anthropic: o.transport },
      litellmBaseUrl: "https://litellm.test",
      defaultModel: "m",
      registry: createToolRegistry([]),
      approvals: { async approve() { return "allow"; } },
      hooks: o.hooks ?? hooksWithStop({ veto: false }),
      compactor: {
        async maybeCompact(i) {
          return { compacted: false, messages: i.messages };
        },
        async pruneOversizedToolResults(i) {
          return { pruned: 0, messages: i.messages };
        },
      },
      skills,
      sandbox: null,
      windowTokens: 128_000,
      sleep: async () => {},
    };
  }

  async function status(runId: string, userId: string): Promise<string> {
    return (await runs.get(db, runId, userId))!.status;
  }

  it("emits the P1 sequence through the shared sink and mirrors every event to Postgres", async () => {
    const { userId, sessionId, runId } = await seed();
    const deps = makeDeps({ transport: textTransport("hi") });
    const engine = createAgentEngine(deps);

    await engine.run({ runId, sessionId, userId, prompt: "hello" });

    expect(deps.events.events.map((e) => e.type)).toEqual([
      "run_started",
      "message_delta",
      "message_completed",
      "run_completed",
    ]);
    expect(await status(runId, userId)).toBe("completed");
    const mirrored = await eventMirror.readSince(db, sessionId, null, 100);
    expect(mirrored.map((e) => e.type)).toEqual([
      "run_started",
      "message_delta",
      "message_completed",
      "run_completed",
    ]);
    expect(engine.activeRun(sessionId)).toBeNull();
  });

  it("cancel aborts the in-flight transport, emits run_cancelled, and flips the run row", async () => {
    const { userId, sessionId, runId } = await seed();
    const abortable = abortableTransport();
    const engine = createAgentEngine(makeDeps({ transport: abortable.transport }));

    const running = engine.run({ runId, sessionId, userId, prompt: "hello" });
    await abortable.started;
    expect(engine.activeRun(sessionId)).toEqual({ runId });
    expect(await engine.cancel(sessionId)).toBe(true);
    await running;

    expect(abortable.sawAbort()).toBe(true);
    expect(await status(runId, userId)).toBe("cancelled");
    const types = (await eventMirror.readSince(db, sessionId, null, 100)).map((e) => e.type);
    expect(types).toContain("run_cancelled");
    expect(engine.activeRun(sessionId)).toBeNull();
  });

  it("cancel with no active run is a false no-op (hard_stop_test.dart :106)", async () => {
    const { sessionId } = await seed();
    const engine = createAgentEngine(makeDeps({ transport: textTransport("hi") }));
    expect(await engine.cancel(sessionId)).toBe(false);
    expect(engine.activeRun(sessionId)).toBeNull();
  });

  it("cancel targets its session only (session_stop_isolation_test.dart :55/:181)", async () => {
    const a = await seed();
    const b = await seed();
    const abortable = abortableTransport();
    const engine = createAgentEngine(makeDeps({ transport: abortable.transport }));

    const running = engine.run({ runId: a.runId, sessionId: a.sessionId, userId: a.userId, prompt: "a" });
    await abortable.started;
    // Session B is idle: cancelling it touches nothing.
    expect(await engine.cancel(b.sessionId)).toBe(false);
    expect(engine.activeRun(a.sessionId)).toEqual({ runId: a.runId });
    await engine.cancel(a.sessionId);
    await running;
  });

  it("user cancel beats a Stop veto", async () => {
    const { userId, sessionId, runId } = await seed();
    const abortable = abortableTransport();
    const engine = createAgentEngine(
      makeDeps({
        transport: abortable.transport,
        hooks: hooksWithStop({ veto: true, reason: "no", vetoedByPlugin: "p1" }),
      }),
    );
    const running = engine.run({ runId, sessionId, userId, prompt: "hello" });
    await abortable.started;
    await engine.cancel(sessionId);
    await running;
    expect(await status(runId, userId)).toBe("cancelled");
  });

  it("a stale run unwinding does not clear the successor's active run", async () => {
    // One session, two runs: A is cancelled, B is promoted on the same
    // session (the Dart ghost/duplicate-response fix).
    const { userId, sessionId } = await seed();
    const prompt = await messages.append(db, { sessionId, role: "user", content: "b" });
    const runB = await runs.create(db, { sessionId, promptMessageId: prompt.id });
    await runs.claimNext(db, runB.id);
    const runA = await runs.create(db, { sessionId, promptMessageId: (await messages.append(db, { sessionId, role: "user", content: "a" })).id });
    await runs.claimNext(db, runA.id);

    const abortable = abortableTransport();
    let calls = 0;
    const transport: AgentTransport = {
      apiFormat: "openai",
      stream(req, h, signal) {
        calls += 1;
        if (calls === 1) return abortable.transport.stream(req, h, signal);
        h.onTextDelta("second");
        return Promise.resolve({
          content: "second",
          thinking: "",
          toolCalls: [],
          finishReason: "stop",
          usage: null,
        });
      },
    };
    const engine = createAgentEngine(makeDeps({ transport }));

    const first = engine.run({ runId: runA.id, sessionId, userId, prompt: "a" });
    await abortable.started;
    await engine.cancel(sessionId);

    const second = engine.run({ runId: runB.id, sessionId, userId, prompt: "b" });
    // While B runs, A's unwind must not have nulled the bucket.
    expect(engine.activeRun(sessionId)).toEqual({ runId: runB.id });
    await Promise.all([first, second]);
    expect(engine.activeRun(sessionId)).toBeNull();
    expect(await status(runA.id, userId)).toBe("cancelled");
    expect(await status(runB.id, userId)).toBe("completed");
  });

  it("never throws for a run-level failure (null key → key_not_minted)", async () => {
    const { userId, sessionId, runId } = await seed();
    const deps = makeDeps({ transport: textTransport("never"), nullKey: true });
    const engine = createAgentEngine(deps);

    await expect(
      engine.run({ runId, sessionId, userId, prompt: "hello" }),
    ).resolves.toBeUndefined();
    expect(await status(runId, userId)).toBe("failed");
    expect(deps.events.events.map((e) => e.type)).toEqual(["run_failed"]);
    expect(deps.events.events[0]!.payload).toMatchObject({ code: "key_not_minted" });
  });

  it("propagates infrastructure errors (P1: only run-level failures are terminal)", async () => {
    const { userId, sessionId, runId } = await seed();
    const transport: AgentTransport = {
      apiFormat: "openai",
      async stream() {
        throw new Error("database is on fire");
      },
    };
    const engine = createAgentEngine(makeDeps({ transport }));
    await expect(
      engine.run({ runId, sessionId, userId, prompt: "hello" }),
    ).rejects.toThrow("database is on fire");
    expect(engine.activeRun(sessionId)).toBeNull();
  });

  it("resolves the mode from state for unattended runs too (ruling R4)", async () => {
    const { userId, sessionId, runId } = await seed();
    const state = createMemoryStateStore();
    await state.patch(sessionId, { mode: "drive" });
    const engine = createAgentEngine(makeDeps({ transport: textTransport("hi"), state }));
    // Smoke: the run completes and the job's mode flows through untouched.
    await engine.run({ runId, sessionId, userId, prompt: "hello", unattended: true });
    expect(await status(runId, userId)).toBe("completed");
  });

  it("transient failures still terminalize through the engine (model_transient_exhausted)", async () => {
    const { userId, sessionId, runId } = await seed();
    const transport: AgentTransport = {
      apiFormat: "openai",
      async stream() {
        throw new TransientModelError("503");
      },
    };
    const deps = makeDeps({ transport });
    const engine = createAgentEngine(deps);
    await engine.run({ runId, sessionId, userId, prompt: "hello" });
    expect(await status(runId, userId)).toBe("failed");
    expect(deps.events.events.at(-1)!.payload).toMatchObject({ code: "model_transient_exhausted" });
  });

  it("a ROOT run hands its final answer to the crash-safe delivery port", async () => {
    const { userId, sessionId, runId } = await seed();
    const calls: Array<{ runId: string; sessionId: string; content: string; payload: Record<string, unknown> }> = [];
    const deps = makeDeps({ transport: textTransport("delivered answer") });
    const engine = createAgentEngine({
      ...deps,
      finalDelivery: {
        async deliver(input) {
          calls.push(input);
        },
      },
    });

    await engine.run({ runId, sessionId, userId, prompt: "hello" });

    expect(calls).toEqual([
      {
        runId,
        sessionId,
        content: "delivered answer",
        completionPayload: expect.objectContaining({ runId }),
      },
    ]);
    // The port owns the message row and the terminal events: the loop must not
    // append a second answer or emit its own completion pair.
    expect(await messages.page(db, sessionId, { limit: 50 })).toMatchObject({
      rows: expect.not.arrayContaining([
        expect.objectContaining({ role: "assistant" }),
      ]),
    });
    expect(deps.events.events.map((event) => event.type)).not.toContain("run_completed");
  });

  it("a SUBAGENT child run never touches the root delivery port (inline finalize)", async () => {
    const { userId, sessionId, runId } = await seed();
    let calls = 0;
    const deps = makeDeps({ transport: textTransport("child answer") });
    const engine = createAgentEngine({
      ...deps,
      finalDelivery: {
        async deliver() {
          calls += 1;
        },
      },
    });

    // The supervisor's child loop: same engine, `isSubagent: true`.
    await engine.run({ runId, sessionId, userId, prompt: "hello", isSubagent: true });

    expect(calls).toBe(0);
    // The child's answer still lands in its own session's transcript.
    const { rows } = await messages.page(db, sessionId, { limit: 50 });
    expect(rows.some((row) => row.role === "assistant" && row.content === "child answer")).toBe(true);
    expect(await status(runId, userId)).toBe("completed");
  });
});
