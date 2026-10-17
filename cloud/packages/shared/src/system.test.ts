import { describe, expect, it } from "vitest";
import {
  systemEventEnvelope,
  sysInChannel,
  sysOutChannel,
  type SystemEventEnvelope,
  type SystemEventKind,
} from "./system.js";
import { wsClientMsg, wsServerMsg } from "./ws.js";
import type { SessionEvent } from "./events.js";

/**
 * System event envelope (P5 Task 10) — the wire shape carried by the WS
 * `system_event` op (server → client) and the `sys:{uid}:out` /
 * `sys:{uid}:in` redis channels (worker ↔ gateway). Everything here is
 * ADDITIVE: the regression pins at the bottom prove the union members that
 * existed before this task still parse unchanged.
 */

const KINDS: SystemEventKind[] = [
  "mcp_sampling_approval",
  "mcp_elicitation",
  "plugin_grant_approval",
  "plugin_install_progress",
  "mcp_oauth_completed",
  "mcp_oauth_failed",
];

const envelope: SystemEventEnvelope = {
  id: "018f1e2a-7b1c-7abc-8def-0123456789ab",
  kind: "mcp_oauth_completed",
  requiresResponse: false,
  payload: { serverId: "srv-1", ok: true },
  ts: "2026-10-17T00:00:00.000Z",
};

describe("systemEventEnvelope", () => {
  it("round-trips a valid envelope", () => {
    expect(systemEventEnvelope({ ...envelope })).toEqual(envelope);
  });

  it("round-trips every documented kind", () => {
    for (const kind of KINDS) {
      expect(systemEventEnvelope({ ...envelope, kind })).toEqual({ ...envelope, kind });
    }
  });

  it("rejects an unknown kind", () => {
    expect(() => systemEventEnvelope({ ...envelope, kind: "mcp_nope" })).toThrow();
  });

  it("rejects an empty id, missing requiresResponse, non-record payload, empty ts", () => {
    expect(() => systemEventEnvelope({ ...envelope, id: "" })).toThrow();
    expect(() =>
      systemEventEnvelope({
        id: envelope.id,
        kind: envelope.kind,
        payload: envelope.payload,
        ts: envelope.ts,
      }),
    ).toThrow(); // requiresResponse missing
    expect(() => systemEventEnvelope({ ...envelope, payload: "nope" })).toThrow();
    expect(() => systemEventEnvelope({ ...envelope, payload: null })).toThrow();
    expect(() => systemEventEnvelope({ ...envelope, ts: "" })).toThrow();
  });
});

describe("ws union additions (P5 Task 10)", () => {
  it("wsServerMsg parses system_event with a valid envelope", () => {
    const input = { op: "system_event", event: envelope };
    expect(wsServerMsg(input)).toEqual(input);
  });

  it("wsServerMsg rejects system_event with an unknown kind or a missing event", () => {
    expect(() => wsServerMsg({ op: "system_event", event: { ...envelope, kind: "nope" } })).toThrow();
    expect(() => wsServerMsg({ op: "system_event" })).toThrow();
  });

  it("wsClientMsg parses system_response", () => {
    const input = { op: "system_response", id: "evt-1", payload: { decision: "allow" } };
    expect(wsClientMsg(input)).toEqual(input);
  });

  it("wsClientMsg rejects system_response with an empty id, a missing id, or a non-record payload", () => {
    expect(() => wsClientMsg({ op: "system_response", id: "", payload: {} })).toThrow();
    expect(() => wsClientMsg({ op: "system_response", payload: {} })).toThrow();
    expect(() => wsClientMsg({ op: "system_response", id: "evt-1", payload: "nope" })).toThrow();
    expect(() => wsClientMsg({ op: "system_response", id: "evt-1" })).toThrow();
  });

  it("still rejects cross-direction and unknown ops after the additions", () => {
    expect(() => wsClientMsg({ op: "system_event" })).toThrow(); // server-only op from a client
    expect(() => wsServerMsg({ op: "system_response", id: "x", payload: {} })).toThrow(); // client-only op from a server
    expect(() => wsClientMsg({ op: "system_response2" })).toThrow();
    expect(() => wsServerMsg({ op: "system_event2" })).toThrow();
  });
});

describe("system channel naming", () => {
  it("pins the cross-process redis channel format (worker ↔ gateway contract)", () => {
    expect(sysOutChannel("u-1")).toBe("sys:u-1:out");
    expect(sysInChannel("u-1")).toBe("sys:u-1:in");
  });
});

// Regression pin: the P1 shapes, copied verbatim — every union member that
// existed BEFORE this task still parses unchanged (additive-only proof).
describe("P1 regression pin (unchanged before Task 10)", () => {
  const event: SessionEvent = {
    sessionId: "s1",
    seq: "1760529600000-0",
    type: "run_started",
    payload: {},
    ts: "2026-10-15T12:00:00.000Z",
  };

  it("client: subscribe (with/without/null lastEventId), unsubscribe, ping", () => {
    const sub = { op: "subscribe", sessionId: "s1", lastEventId: "1760529600000-0" };
    expect(wsClientMsg(sub)).toEqual(sub);
    expect(wsClientMsg({ op: "subscribe", sessionId: "s1", lastEventId: null })).toEqual({
      op: "subscribe",
      sessionId: "s1",
      lastEventId: null,
    });
    expect(wsClientMsg({ op: "subscribe", sessionId: "s1" })).toEqual({ op: "subscribe", sessionId: "s1" });
    expect(wsClientMsg({ op: "unsubscribe", sessionId: "s1" })).toEqual({
      op: "unsubscribe",
      sessionId: "s1",
    });
    expect(wsClientMsg({ op: "ping" })).toEqual({ op: "ping" });
  });

  it("server: subscribed, event, pong, error (with/without sessionId)", () => {
    expect(wsServerMsg({ op: "subscribed", sessionId: "s1" })).toEqual({
      op: "subscribed",
      sessionId: "s1",
    });
    expect(wsServerMsg({ op: "event", event })).toEqual({ op: "event", event });
    expect(wsServerMsg({ op: "pong" })).toEqual({ op: "pong" });
    const withSession = { op: "error", code: "forbidden", message: "gone", sessionId: "s1" };
    expect(wsServerMsg(withSession)).toEqual(withSession);
    expect(wsServerMsg({ op: "error", code: "forbidden", message: "gone" })).toEqual({
      op: "error",
      code: "forbidden",
      message: "gone",
    });
  });
});
