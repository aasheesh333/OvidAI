import { describe, expect, it } from "vitest";
import { sessionEvent, sessionEventSchema } from "./events.js";
import type { SessionEvent, SessionEventType } from "./events.js";

const valid: SessionEvent = {
  sessionId: "01990b7a-2f6c-7d1e-8a3b-4c5d6e7f8090",
  seq: "1760529600000-0",
  type: "message_delta",
  payload: { text: "hello" },
  ts: "2026-10-15T12:00:00.000Z",
};

// The single authoritative list (Task 3 additions at the end, same order as
// the union and the zod enum in events.ts). `satisfies` makes the compiler
// reject a list member missing from the SessionEventType union; the
// ExhaustiveAssignment below makes it reject a union member missing here.
const allEventTypes = [
  "run_started",
  "message_delta",
  "message_completed",
  "run_started_retry",
  "run_failed",
  "run_completed",
  "system_note",
  "tool_started",
  "tool_completed",
  "artifact_created",
  "workspace_hibernated",
  "workspace_hydrated",
] as const satisfies readonly SessionEventType[];

// Compile-time exhaustiveness: true is assignable only when every
// SessionEventType member appears in allEventTypes.
const exhaustive: SessionEventType extends (typeof allEventTypes)[number] ? true : never = true;
void exhaustive;

describe("sessionEvent", () => {
  it("round-trips a valid envelope", () => {
    expect(sessionEvent(valid)).toEqual(valid);
  });

  it("exposes the schema, which parses the same envelope", () => {
    expect(sessionEventSchema.parse(valid)).toEqual(valid);
  });

  it("rejects an unknown type", () => {
    expect(() => sessionEvent({ ...valid, type: "nope" })).toThrow();
  });

  it("rejects a missing seq", () => {
    const { seq: _seq, ...noSeq } = valid;
    expect(() => sessionEvent(noSeq)).toThrow();
  });

  it("rejects a non-object payload", () => {
    expect(() => sessionEvent({ ...valid, payload: "text" })).toThrow();
    expect(() => sessionEvent({ ...valid, payload: 42 })).toThrow();
    expect(() => sessionEvent({ ...valid, payload: null })).toThrow();
  });

  it("parses the workspace/artifact additions (Task 3)", () => {
    for (const type of ["artifact_created", "workspace_hibernated", "workspace_hydrated"] as const) {
      const event = { ...valid, type, payload: {} };
      expect(sessionEvent(event)).toEqual(event);
    }
  });

  it("still parses every pre-existing type (pin no regression)", () => {
    const oldTypes = allEventTypes.filter(
      (t) => t !== "artifact_created" && t !== "workspace_hibernated" && t !== "workspace_hydrated",
    );
    expect(oldTypes).toHaveLength(9);
    for (const type of oldTypes) {
      const event = { ...valid, type, payload: {} };
      expect(sessionEventSchema.parse(event)).toEqual(event);
    }
  });

  it("the enum array accepts every member of the compile-time list", () => {
    // Runtime mirror of the compile-time check above: the zod enum in
    // sessionEventSchema must accept exactly the allEventTypes membership
    // (unknown types are already rejected by the "unknown type" test above).
    for (const type of allEventTypes) {
      const event = { ...valid, type, payload: {} };
      expect(sessionEventSchema.parse(event)).toEqual(event);
    }
  });
});
