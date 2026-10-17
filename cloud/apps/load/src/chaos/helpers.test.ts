import { describe, expect, it } from "vitest";
import type { SessionEvent } from "@ovid/shared";
import { runEventCounts } from "./helpers.js";

/**
 * M2: many worker failure paths emit `run_failed` WITHOUT `payload.runId`.
 * Dropping those made a failed run invisible to the terminal checks. These
 * tests pin the attribution rules.
 */

function event(
  type: string,
  payload: Record<string, unknown>,
  seq = "1-0",
): SessionEvent {
  return { sessionId: "s1", seq, type, payload } as unknown as SessionEvent;
}

describe("runEventCounts — unlabelled terminal events (M2)", () => {
  it("attributes a run_failed without runId to the single still-open run", () => {
    const counts = runEventCounts(
      [
        event("run_started", { runId: "run-1" }),
        event("run_failed", { code: "model_terminal" }),
      ],
      ["run-1"],
    );

    expect(counts.failed.has("run-1")).toBe(true);
    expect(counts.unattributedTerminal).toBe(0);
    expect(counts.terminalEvents).toBe(1);
  });

  it("attributes a run_completed without runId when exactly one run is open", () => {
    const counts = runEventCounts(
      [event("run_completed", {})],
      ["run-1", "run-2"],
    );

    // Both expected runs are open → ambiguous, so it is counted, not dropped.
    expect(counts.unattributedTerminal).toBe(1);
    expect(counts.completed.size).toBe(0);
  });

  it("does not attribute an unlabelled terminal when the open run is ambiguous", () => {
    const counts = runEventCounts(
      [
        event("run_started", { runId: "run-1" }),
        event("run_started", { runId: "run-2" }),
        event("run_failed", { code: "run_queue_wait_timeout" }),
      ],
      ["run-1", "run-2"],
    );

    expect(counts.failed.size).toBe(0);
    expect(counts.unattributedTerminal).toBe(1);
  });

  it("skips a terminal already attributed to a labelled run", () => {
    const counts = runEventCounts(
      [
        event("run_started", { runId: "run-1" }),
        event("run_completed", { runId: "run-1" }),
        event("run_failed", { code: "model_terminal" }),
      ],
      ["run-1", "run-2"],
    );

    // run-1 is closed, so the unlabelled failure belongs to run-2.
    expect(counts.completed.has("run-1")).toBe(true);
    expect(counts.failed.has("run-2")).toBe(true);
    expect(counts.unattributedTerminal).toBe(0);
  });

  it("counts duplicate terminal events so exactly-one can fail", () => {
    const counts = runEventCounts(
      [
        event("run_completed", { runId: "run-1" }),
        event("run_completed", { runId: "run-1" }),
      ],
      ["run-1"],
    );

    expect(counts.terminalEvents).toBe(2);
    expect(counts.completed.size).toBe(1);
  });

  it("ignores non-terminal and non-run events", () => {
    const counts = runEventCounts(
      [event("message_delta", { runId: "run-1" }), event("system_note", {})],
      ["run-1"],
    );

    expect(counts.terminalEvents).toBe(0);
    expect(counts.unattributedTerminal).toBe(0);
  });
});
