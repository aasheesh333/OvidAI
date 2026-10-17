import { describe, expect, it } from "vitest";
import {
  deviceRegisterRequestSchema,
  scheduleCreateRequestSchema,
  scheduleDtoSchema,
  schedulePrompt,
  scheduleRunDtoSchema,
  scheduleUpdateRequestSchema,
  systemEvent,
  systemEventSchema,
  type ScheduleDto,
  type ScheduleRunDto,
  type SystemEvent,
} from "./schedules.js";
import { wsClientMsg, wsServerMsg } from "./ws.js";
import type { SessionEvent } from "./events.js";
import type { SystemEventEnvelope } from "./system.js";

const every300 = { kind: "every" as const, seconds: 300 };

const event: SessionEvent = {
  sessionId: "s1",
  seq: "1760529600000-0",
  type: "run_started",
  payload: {},
  ts: "2026-10-15T12:00:00.000Z",
};

const scheduleEvent: SystemEvent = {
  type: "schedule_created",
  scheduleId: "sch-1",
  ts: "2026-10-17T00:00:00.000Z",
  payload: { schedule: { id: "sch-1" } },
};

const systemEnvelope: SystemEventEnvelope = {
  id: "018f1e2a-7b1c-7abc-8def-0123456789ab",
  kind: "mcp_oauth_completed",
  requiresResponse: false,
  payload: { serverId: "srv-1", ok: true },
  ts: "2026-10-17T00:00:00.000Z",
};

describe("schedulePrompt", () => {
  it("pins the Dart prompt template", () => {
    expect(schedulePrompt("Morning", "check inbox")).toBe("[schedule: Morning] check inbox");
  });
});

describe("scheduleCreateRequestSchema", () => {
  it("accepts the minimal body with optional fields absent", () => {
    const input = { title: "Morning", description: "check inbox", trigger: every300 };
    expect(scheduleCreateRequestSchema.parse(input)).toEqual(input);
  });

  it("accepts autonomy, maxRetries and sessionId", () => {
    const input = {
      title: "Morning",
      description: "check inbox",
      trigger: every300,
      autonomy: "auto" as const,
      maxRetries: 3,
      sessionId: "s1",
    };
    expect(scheduleCreateRequestSchema.parse(input)).toEqual(input);
  });

  it("rejects an empty title, maxRetries 4, and unknown keys", () => {
    expect(() =>
      scheduleCreateRequestSchema.parse({ title: "", description: "d", trigger: every300 }),
    ).toThrow();
    expect(() =>
      scheduleCreateRequestSchema.parse({
        title: "t",
        description: "d",
        trigger: every300,
        maxRetries: 4,
      }),
    ).toThrow();
    expect(() =>
      scheduleCreateRequestSchema.parse({
        title: "t",
        description: "d",
        trigger: every300,
        extra: true,
      }),
    ).toThrow();
  });

  it("rejects an invalid trigger", () => {
    expect(() =>
      scheduleCreateRequestSchema.parse({ title: "t", description: "d", trigger: { kind: "every", seconds: 1 } }),
    ).toThrow();
  });
});

describe("scheduleUpdateRequestSchema", () => {
  it("rejects an empty update", () => {
    expect(() => scheduleUpdateRequestSchema.parse({})).toThrow();
  });

  it("rejects status cancelled (only pending | paused are updatable)", () => {
    expect(() => scheduleUpdateRequestSchema.parse({ status: "cancelled" })).toThrow();
  });

  it("accepts one or more known fields and rejects unknown keys", () => {
    expect(scheduleUpdateRequestSchema.parse({ title: "New" })).toEqual({ title: "New" });
    expect(scheduleUpdateRequestSchema.parse({ status: "paused" })).toEqual({ status: "paused" });
    expect(scheduleUpdateRequestSchema.parse({ trigger: every300, maxRetries: 0 })).toEqual({
      trigger: every300,
      maxRetries: 0,
    });
    expect(() => scheduleUpdateRequestSchema.parse({ nope: 1 })).toThrow();
  });
});

describe("schedule DTO schemas", () => {
  const dto: ScheduleDto = {
    id: "sch-1",
    sessionId: "s1",
    title: "Morning",
    description: "check inbox",
    trigger: every300,
    autonomy: "safe",
    status: "pending",
    pausedReason: null,
    maxRetries: 2,
    nextRunAt: "2026-10-18T07:00:00.000Z",
    lastResult: null,
    createdAt: "2026-10-17T00:00:00.000Z",
    updatedAt: "2026-10-17T00:00:00.000Z",
  };

  it("round-trips a ScheduleDto", () => {
    expect(scheduleDtoSchema.parse(dto)).toEqual(dto);
  });

  it("round-trips a ScheduleRunDto", () => {
    const run: ScheduleRunDto = {
      id: "run-row-1",
      scheduleId: "sch-1",
      scheduledFor: "2026-10-18T07:00:00.000Z",
      runId: null,
      status: "running",
      attempt: 1,
      ranLate: false,
      error: null,
      startedAt: "2026-10-18T07:00:01.000Z",
      finishedAt: null,
    };
    expect(scheduleRunDtoSchema.parse(run)).toEqual(run);
  });

  it("rejects an unknown status", () => {
    expect(() => scheduleDtoSchema.parse({ ...dto, status: "nope" })).toThrow();
  });
});

describe("systemEvent", () => {
  it("round-trips a valid event", () => {
    expect(systemEvent(scheduleEvent)).toEqual(scheduleEvent);
    expect(systemEventSchema.parse(scheduleEvent)).toEqual(scheduleEvent);
  });

  it("accepts every schedule event type", () => {
    for (const type of [
      "schedule_created",
      "schedule_updated",
      "schedule_deleted",
      "schedule_run_started",
      "schedule_run_succeeded",
      "schedule_run_failed",
      "schedule_run_paused",
    ] as const) {
      expect(systemEvent({ ...scheduleEvent, type })).toEqual({ ...scheduleEvent, type });
    }
  });

  it("rejects an unknown type and a missing ts", () => {
    expect(() => systemEvent({ ...scheduleEvent, type: "schedule_nope" })).toThrow();
    const { ts: _ts, ...withoutTs } = scheduleEvent;
    expect(() => systemEvent(withoutTs)).toThrow();
  });
});

describe("deviceRegisterRequestSchema", () => {
  it("accepts an android token and rejects other platforms/unknown keys", () => {
    expect(deviceRegisterRequestSchema.parse({ token: "fcm-token", platform: "android" })).toEqual({
      token: "fcm-token",
      platform: "android",
    });
    expect(() => deviceRegisterRequestSchema.parse({ token: "t", platform: "ios" })).toThrow();
    expect(() =>
      deviceRegisterRequestSchema.parse({ token: "t", platform: "android", extra: 1 }),
    ).toThrow();
    expect(() => deviceRegisterRequestSchema.parse({ token: "", platform: "android" })).toThrow();
  });
});

describe("ws union additions (P4 Task 2)", () => {
  it("parses subscribe_system and unsubscribe_system", () => {
    expect(wsClientMsg({ op: "subscribe_system" })).toEqual({ op: "subscribe_system" });
    expect(wsClientMsg({ op: "unsubscribe_system" })).toEqual({ op: "unsubscribe_system" });
  });

  it("parses system_subscribed", () => {
    expect(wsServerMsg({ op: "system_subscribed" })).toEqual({ op: "system_subscribed" });
  });

  it("parses a system frame with a valid SystemEvent", () => {
    const input = { op: "system", event: scheduleEvent };
    expect(wsServerMsg(input)).toEqual(input);
  });

  it("rejects a system frame with an off-contract event", () => {
    expect(() => wsServerMsg({ op: "system", event: { ...scheduleEvent, type: "nope" } })).toThrow();
    expect(() => wsServerMsg({ op: "system" })).toThrow();
  });

  it("does not cross directions", () => {
    expect(() => wsClientMsg({ op: "system", event: scheduleEvent })).toThrow();
    expect(() => wsServerMsg({ op: "subscribe_system" })).toThrow();
  });
});

// Regression pin: every message shape that was valid BEFORE this task still
// parses unchanged (additive-only proof for the shared ws contract).
describe("ws regression pin (all pre-P4 messages unchanged)", () => {
  it("client: session ops", () => {
    for (const input of [
      { op: "subscribe", sessionId: "s1", lastEventId: "1760529600000-0" },
      { op: "subscribe", sessionId: "s1", lastEventId: null },
      { op: "subscribe", sessionId: "s1" },
      { op: "unsubscribe", sessionId: "s1" },
      { op: "ping" },
    ]) {
      expect(wsClientMsg(input)).toEqual(input);
    }
  });

  it("client: pty ops", () => {
    for (const input of [
      { op: "pty_open", sessionId: "s1", cols: 80, rows: 24 },
      { op: "pty_attach", ptyId: "p1", lastOffset: 0 },
      { op: "pty_attach", ptyId: "p1" },
      { op: "pty_input", ptyId: "p1", data: "aGVsbG8=" },
      { op: "pty_resize", ptyId: "p1", cols: 120, rows: 40 },
      { op: "pty_close", ptyId: "p1" },
    ]) {
      expect(wsClientMsg(input)).toEqual(input);
    }
  });

  it("client: browser, approval and system ops", () => {
    for (const input of [
      { op: "browser_attach", sessionId: "s1" },
      { op: "browser_detach", sessionId: "s1" },
      { op: "browser_input", sessionId: "s1", input: { type: "tap", x: 10, y: 20 } },
      { op: "browser_takeover", sessionId: "s1", enabled: true },
      { op: "approval_response", sessionId: "s1", approvalId: "ap-1", decision: "allow" },
      { op: "system_response", id: "evt-1", payload: { decision: "allow" } },
    ]) {
      expect(wsClientMsg(input)).toEqual(input);
    }
  });

  it("server: session, pty, browser, approval and system ops", () => {
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
    for (const input of [
      { op: "subscribed", sessionId: "s1" },
      { op: "event", event },
      { op: "pong" },
      { op: "error", code: "forbidden", message: "gone", sessionId: "s1" },
      { op: "error", code: "forbidden", message: "gone" },
      { op: "pty_opened", ptyId: "p1", sessionId: "s1" },
      { op: "pty_attached", ptyId: "p1", truncated: false },
      { op: "pty_output", ptyId: "p1", data: "aGVsbG8=", offset: 0 },
      { op: "pty_exit", ptyId: "p1", exitCode: 0 },
      { op: "pty_exit", ptyId: "p1", exitCode: null },
      { op: "browser_state", sessionId: "s1", state: browserState },
      { op: "approval_ack", approvalId: "ap-1", decision: "always" },
      { op: "system_event", event: systemEnvelope },
    ]) {
      expect(wsServerMsg(input)).toEqual(input);
    }
  });

  it("still rejects unknown ops in both directions", () => {
    expect(() => wsClientMsg({ op: "nope" })).toThrow();
    expect(() => wsServerMsg({ op: "nope" })).toThrow();
  });
});
