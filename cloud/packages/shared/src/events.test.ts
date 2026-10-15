import { describe, expect, it } from "vitest";
import { sessionEvent, sessionEventSchema } from "./events.js";
import type { SessionEvent } from "./events.js";

const valid: SessionEvent = {
  sessionId: "01990b7a-2f6c-7d1e-8a3b-4c5d6e7f8090",
  seq: "1760529600000-0",
  type: "message_delta",
  payload: { text: "hello" },
  ts: "2026-10-15T12:00:00.000Z",
};

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
});
