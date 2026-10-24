import { describe, expect, it, vi } from "vitest";
import type { EventLog } from "@ovid/events";
import { withRunCompletionNotification } from "./runCompletionNotifications.js";

function eventLog(): EventLog & { appended: string[] } {
  const appended: string[] = [];
  return {
    appended,
    append: async (_sessionId, type, payload) => {
      appended.push(type);
      return { sessionId: "s1", seq: "1", type, payload, ts: new Date().toISOString() };
    },
    readSince: async () => [],
    subscribe: async () => async () => {},
  };
}

const run = { runId: "r1", sessionId: "s1", userId: "u1", scheduled: false };

describe("run completion notifications", () => {
  it("notifies after the terminal event, never before it", async () => {
    const events = eventLog();
    const notifyAgentFinished = vi.fn(async () => {});
    const wrapped = withRunCompletionNotification(events, { notifyAgentFinished }, run);

    await wrapped.append("s1", "message_completed", { content: "done" });
    expect(notifyAgentFinished).not.toHaveBeenCalled();
    await wrapped.append("s1", "run_completed", { runId: "r1" });

    expect(events.appended).toEqual(["message_completed", "run_completed"]);
    expect(notifyAgentFinished).toHaveBeenCalledOnce();
    expect(notifyAgentFinished).toHaveBeenCalledWith({
      userId: "u1",
      runId: "r1",
      sessionId: "s1",
    });
  });

  it("ignores a child's run_completed and does not await fan-out in append", async () => {
    const events = eventLog();
    let release!: () => void;
    const blocked = new Promise<void>((resolve) => {
      release = resolve;
    });
    const notifyAgentFinished = vi.fn(() => blocked);
    const wrapped = withRunCompletionNotification(events, { notifyAgentFinished }, run);

    await wrapped.append("s1", "run_completed", { runId: "child-run" });
    expect(notifyAgentFinished).not.toHaveBeenCalled();

    await wrapped.append("s1", "run_completed", { runId: "r1" });
    expect(notifyAgentFinished).toHaveBeenCalledOnce();
    release();
    await Promise.resolve();
  });

  it("does not duplicate scheduled success or turn a push failure into a run failure", async () => {
    const scheduled = withRunCompletionNotification(eventLog(), {
      notifyAgentFinished: vi.fn(async () => {
        throw new Error("push offline");
      }),
    }, { ...run, scheduled: true });
    await scheduled.append("s1", "run_completed", { runId: "r1" });

    const notifyAgentFinished = vi.fn(async () => {
      throw new Error("push offline");
    });
    const wrapped = withRunCompletionNotification(eventLog(), { notifyAgentFinished }, run);
    await expect(wrapped.append("s1", "run_completed", { runId: "r1" })).resolves.toMatchObject({
      type: "run_completed",
    });
    expect(notifyAgentFinished).toHaveBeenCalledOnce();
  });
});
