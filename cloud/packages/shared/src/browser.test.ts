import { describe, expect, it } from "vitest";
import {
  BROWSER_FRAME_FORMAT,
  browserCtlChannel,
  browserCtlMsgSchema,
  browserFramesChannel,
  browserInputChannel,
  browserInputEventSchema,
  browserStateChannel,
  browserStateDtoSchema,
} from "./browser.js";

const validState = {
  sessionId: "s1",
  live: true,
  url: "https://example.com/page",
  title: "Example",
  takeover: false,
  screencast: true,
  frameFormat: "jpeg" as const,
  viewport: { width: 1280, height: 720 },
};

describe("browserInputEventSchema", () => {
  it("round-trips a tap", () => {
    const input = { type: "tap", x: 10, y: 20 };
    expect(browserInputEventSchema.parse(input)).toEqual(input);
  });

  it("round-trips a double_tap", () => {
    const input = { type: "double_tap", x: 10, y: 20 };
    expect(browserInputEventSchema.parse(input)).toEqual(input);
  });

  it("round-trips a long_press with and without durationMs", () => {
    const withDur = { type: "long_press", x: 10, y: 20, durationMs: 500 };
    expect(browserInputEventSchema.parse(withDur)).toEqual(withDur);
    const withoutDur = { type: "long_press", x: 10, y: 20 };
    expect(browserInputEventSchema.parse(withoutDur)).toEqual(withoutDur);
  });

  it("round-trips a scroll with and without x/y", () => {
    const withPos = { type: "scroll", dx: 0, dy: -120, x: 100, y: 200 };
    expect(browserInputEventSchema.parse(withPos)).toEqual(withPos);
    const withoutPos = { type: "scroll", dx: 0, dy: -120 };
    expect(browserInputEventSchema.parse(withoutPos)).toEqual(withoutPos);
  });

  it("round-trips a swipe with and without steps", () => {
    const withSteps = { type: "swipe", fromX: 10, fromY: 400, toX: 10, toY: 100, steps: 8 };
    expect(browserInputEventSchema.parse(withSteps)).toEqual(withSteps);
    const withoutSteps = { type: "swipe", fromX: 10, fromY: 400, toX: 10, toY: 100 };
    expect(browserInputEventSchema.parse(withoutSteps)).toEqual(withoutSteps);
  });

  it("round-trips a key with and without text", () => {
    const withText = { type: "key", key: "a", text: "a" };
    expect(browserInputEventSchema.parse(withText)).toEqual(withText);
    const withoutText = { type: "key", key: "Enter" };
    expect(browserInputEventSchema.parse(withoutText)).toEqual(withoutText);
  });

  it("rejects a tap with a non-numeric coordinate", () => {
    expect(() => browserInputEventSchema.parse({ type: "tap", x: "a", y: 20 })).toThrow();
  });

  it("rejects an unknown type", () => {
    expect(() => browserInputEventSchema.parse({ type: "pinch", scale: 2 })).toThrow();
  });
});

describe("browserStateDtoSchema", () => {
  it("round-trips a valid state", () => {
    expect(browserStateDtoSchema.parse(validState)).toEqual(validState);
  });

  it("round-trips a state with null url/title and webp frames", () => {
    const input = { ...validState, url: null, title: null, frameFormat: "webp" as const };
    expect(browserStateDtoSchema.parse(input)).toEqual(input);
  });

  it("rejects a state missing frameFormat", () => {
    const { frameFormat: _omit, ...missing } = validState;
    expect(() => browserStateDtoSchema.parse(missing)).toThrow();
  });

  it("rejects frameFormat png", () => {
    expect(() => browserStateDtoSchema.parse({ ...validState, frameFormat: "png" })).toThrow();
  });
});

describe("browserCtlMsgSchema", () => {
  it("round-trips viewer_join, viewer_leave and takeover", () => {
    const join = { type: "viewer_join", viewerId: "v1" };
    expect(browserCtlMsgSchema.parse(join)).toEqual(join);
    const leave = { type: "viewer_leave", viewerId: "v1" };
    expect(browserCtlMsgSchema.parse(leave)).toEqual(leave);
    const takeover = { type: "takeover", enabled: true };
    expect(browserCtlMsgSchema.parse(takeover)).toEqual(takeover);
  });

  it("rejects viewer_join without a viewerId", () => {
    expect(() => browserCtlMsgSchema.parse({ type: "viewer_join" })).toThrow();
  });
});

describe("browser channel helpers", () => {
  it("returns the exact redis channel names", () => {
    expect(browserFramesChannel("s1")).toBe("browser:s1:frames");
    expect(browserStateChannel("s1")).toBe("browser:s1:state");
    expect(browserCtlChannel("s1")).toBe("browser:s1:ctl");
    expect(browserInputChannel("s1")).toBe("browser:s1:input");
  });
});

describe("BROWSER_FRAME_FORMAT", () => {
  it("pins the redis 1-byte format prefix values", () => {
    expect(BROWSER_FRAME_FORMAT.jpeg).toBe(1);
    expect(BROWSER_FRAME_FORMAT.webp).toBe(2);
  });
});
