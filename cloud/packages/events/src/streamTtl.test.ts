import { describe, expect, it } from "vitest";
import { DEFAULT_STREAM_TTL_SEC, streamTtlSecFromEnv } from "./eventLog.js";

describe("streamTtlSecFromEnv", () => {
  it("defaults to 48 h", () => {
    expect(DEFAULT_STREAM_TTL_SEC).toBe(172_800);
    expect(streamTtlSecFromEnv({})).toBe(172_800);
    expect(streamTtlSecFromEnv({ OVID_EVENT_STREAM_TTL_S: " " })).toBe(172_800);
  });

  it("accepts 0 (disabled) and 60..30 days", () => {
    expect(streamTtlSecFromEnv({ OVID_EVENT_STREAM_TTL_S: "0" })).toBe(0);
    expect(streamTtlSecFromEnv({ OVID_EVENT_STREAM_TTL_S: "86400" })).toBe(86_400);
  });

  it("rejects out-of-range or non-integer values", () => {
    for (const bad of ["59", "-1", "abc", "1.5", String(31 * 86_400)]) {
      expect(() => streamTtlSecFromEnv({ OVID_EVENT_STREAM_TTL_S: bad })).toThrow(
        /OVID_EVENT_STREAM_TTL_S/,
      );
    }
  });
});
