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
