import { describe, expect, it } from "vitest";
import { wsClientMsg, wsServerMsg } from "./ws.js";
import type { WsClientMsg, WsServerMsg } from "./ws.js";
import type { SessionEvent } from "./events.js";

const event: SessionEvent = {
  sessionId: "s1",
  seq: "1760529600000-0",
  type: "run_started",
  payload: {},
  ts: "2026-10-15T12:00:00.000Z",
};

describe("wsClientMsg", () => {
  it("parses subscribe with lastEventId", () => {
    const input = { op: "subscribe", sessionId: "s1", lastEventId: "1760529600000-0" };
    expect(wsClientMsg(input)).toEqual(input);
  });

  it("parses subscribe with null lastEventId", () => {
    const input = { op: "subscribe", sessionId: "s1", lastEventId: null };
    expect(wsClientMsg(input)).toEqual(input);
  });

  it("parses subscribe without lastEventId, leaving the field undefined", () => {
    const parsed = wsClientMsg({ op: "subscribe", sessionId: "s1" });
    expect(parsed).toEqual({ op: "subscribe", sessionId: "s1" });
    const sub = parsed as Extract<WsClientMsg, { op: "subscribe" }>;
    expect(sub.lastEventId).toBeUndefined();
  });

  it("parses unsubscribe", () => {
    expect(wsClientMsg({ op: "unsubscribe", sessionId: "s1" })).toEqual({
      op: "unsubscribe",
      sessionId: "s1",
    });
  });

  it("parses ping", () => {
    expect(wsClientMsg({ op: "ping" })).toEqual({ op: "ping" });
  });

  it("rejects an unknown op", () => {
    expect(() => wsClientMsg({ op: "nope" })).toThrow();
  });
});

describe("wsServerMsg", () => {
  it("parses subscribed", () => {
    expect(wsServerMsg({ op: "subscribed", sessionId: "s1" })).toEqual({
      op: "subscribed",
      sessionId: "s1",
    });
  });

  it("parses event", () => {
    expect(wsServerMsg({ op: "event", event })).toEqual({ op: "event", event });
  });

  it("parses pong", () => {
    expect(wsServerMsg({ op: "pong" })).toEqual({ op: "pong" });
  });

  it("parses error with and without sessionId", () => {
    const withSession = { op: "error", code: "not_found", message: "gone", sessionId: "s1" };
    expect(wsServerMsg(withSession)).toEqual(withSession);
    const parsed = wsServerMsg({ op: "error", code: "not_found", message: "gone" });
    expect(parsed).toEqual({ op: "error", code: "not_found", message: "gone" });
    const err = parsed as Extract<WsServerMsg, { op: "error" }>;
    expect(err.sessionId).toBeUndefined();
  });

  it("rejects an unknown op", () => {
    expect(() => wsServerMsg({ op: "nope" })).toThrow();
  });
});

// P6 Task 2 — browser channel ops (additive discriminants; all NEW cases).
describe("wsClientMsg browser ops (P6)", () => {
  it("parses browser_attach", () => {
    expect(wsClientMsg({ op: "browser_attach", sessionId: "s1" })).toEqual({
      op: "browser_attach",
      sessionId: "s1",
    });
  });

  it("parses browser_detach", () => {
    expect(wsClientMsg({ op: "browser_detach", sessionId: "s1" })).toEqual({
      op: "browser_detach",
      sessionId: "s1",
    });
  });

  it("parses browser_input with a full tap event", () => {
    const input = { op: "browser_input", sessionId: "s1", input: { type: "tap", x: 10, y: 20 } };
    expect(wsClientMsg(input)).toEqual(input);
  });

  it("rejects browser_input with a malformed input event", () => {
    expect(() =>
      wsClientMsg({ op: "browser_input", sessionId: "s1", input: { type: "tap", x: "a", y: 20 } }),
    ).toThrow();
  });

  it("parses browser_takeover", () => {
    const input = { op: "browser_takeover", sessionId: "s1", enabled: true };
    expect(wsClientMsg(input)).toEqual(input);
  });
});

describe("wsServerMsg browser ops (P6)", () => {
  const browserState = {
    sessionId: "s1",
    live: true,
    url: "https://example.com",
    title: "Example",
    takeover: false,
    screencast: true,
    frameFormat: "jpeg" as const,
    viewport: { width: 1280, height: 720 },
  };

  it("parses browser_state", () => {
    const input = { op: "browser_state", sessionId: "s1", state: browserState };
    expect(wsServerMsg(input)).toEqual(input);
  });

  it("rejects browser_state with a malformed state", () => {
    expect(() =>
      wsServerMsg({
        op: "browser_state",
        sessionId: "s1",
        state: { ...browserState, frameFormat: "png" },
      }),
    ).toThrow();
  });
});

// Regression pin: pre-existing ops unchanged after the P6 additions.
describe("ws ops regression pin (P6)", () => {
  it("still parses subscribe, ping; still rejects unknown ops", () => {
    const sub = { op: "subscribe", sessionId: "s" };
    expect(wsClientMsg(sub)).toEqual(sub);
    expect(wsClientMsg({ op: "ping" })).toEqual({ op: "ping" });
    expect(() => wsClientMsg({ op: "nope" })).toThrow();
    expect(() => wsServerMsg({ op: "nope" })).toThrow();
  });
});
