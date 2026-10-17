import { describe, expect, it } from "vitest";
import {
  PTY_CTL_PATTERN,
  PTY_HEARTBEAT_MS,
  PTY_REGISTRY_TTL_MS,
  parsePtyCtlMsg,
  parsePtyOutMsg,
  parsePtyReplyMsg,
  ptyCtlChannel,
  ptyOutChannel,
  ptyRegistryKey,
} from "./pty.js";
import { wsClientMsg, wsServerMsg } from "./ws.js";

/**
 * Terminal-over-WS wire protocol (Task 13): every message variant parses, the
 * pinned validation rules reject, and the ws union additions round-trip. The
 * P1 ws union coverage (ws.test.ts) stays green UNMODIFIED — these are purely
 * additive discriminants.
 */

/** Valid base64 chars only, decoding to just under/over the 16 KiB wire cap. */
const B64_JUST_UNDER = "A".repeat(21_844); // 21844/4·3 = 16383 bytes
const B64_OVER = "A".repeat(21_848); // 21848/4·3 = 16386 bytes > 16384

describe("pty channel/key helpers", () => {
  it("channels, registry key and the PSUBSCRIBE pattern are exactly as pinned", () => {
    expect(ptyCtlChannel("abc123")).toBe("pty:ctl:abc123");
    expect(ptyOutChannel("abc123")).toBe("pty:out:abc123");
    expect(ptyRegistryKey("abc123")).toBe("pty:reg:abc123");
    expect(PTY_CTL_PATTERN).toBe("pty:ctl:*");
    expect(PTY_REGISTRY_TTL_MS).toBe(90_000);
    expect(PTY_HEARTBEAT_MS).toBe(30_000);
  });
});

describe("ptyCtlMsg", () => {
  it("parses every variant", () => {
    expect(
      parsePtyCtlMsg({
        type: "open",
        ptyId: "p1",
        userId: "u1",
        sessionId: "s1",
        cols: 80,
        rows: 24,
        replyChannel: "pty:reply:r1",
      }),
    ).toEqual({
      type: "open",
      ptyId: "p1",
      userId: "u1",
      sessionId: "s1",
      cols: 80,
      rows: 24,
      replyChannel: "pty:reply:r1",
    });

    expect(
      parsePtyCtlMsg({ type: "attach", ptyId: "p1", lastOffset: null, replyChannel: "pty:reply:r1" }),
    ).toEqual({ type: "attach", ptyId: "p1", lastOffset: null, replyChannel: "pty:reply:r1" });
    expect(
      parsePtyCtlMsg({ type: "attach", ptyId: "p1", lastOffset: 12, replyChannel: "pty:reply:r1" }),
    ).toEqual({ type: "attach", ptyId: "p1", lastOffset: 12, replyChannel: "pty:reply:r1" });

    expect(parsePtyCtlMsg({ type: "input", ptyId: "p1", data: "aGk=" })).toEqual({
      type: "input",
      ptyId: "p1",
      data: "aGk=",
    });
    expect(parsePtyCtlMsg({ type: "resize", ptyId: "p1", cols: 120, rows: 40 })).toEqual({
      type: "resize",
      ptyId: "p1",
      cols: 120,
      rows: 40,
    });
    expect(parsePtyCtlMsg({ type: "close", ptyId: "p1" })).toEqual({ type: "close", ptyId: "p1" });
  });

  it("rejects an unknown type", () => {
    expect(() => parsePtyCtlMsg({ type: "nope", ptyId: "p1" })).toThrow();
  });

  it("rejects cols/rows out of the 1..500 int range", () => {
    const open = { type: "open", ptyId: "p1", userId: "u1", sessionId: "s1", replyChannel: "r" };
    expect(() => parsePtyCtlMsg({ ...open, cols: 0, rows: 24 })).toThrow();
    expect(() => parsePtyCtlMsg({ ...open, cols: 80, rows: 0 })).toThrow();
    expect(() => parsePtyCtlMsg({ ...open, cols: 501, rows: 24 })).toThrow();
    expect(() => parsePtyCtlMsg({ ...open, cols: 80.5, rows: 24 })).toThrow();
    expect(() => parsePtyCtlMsg({ type: "resize", ptyId: "p1", cols: 501, rows: 24 })).toThrow();
  });

  it("rejects non-base64 data and data decoding over 16 KiB", () => {
    expect(() => parsePtyCtlMsg({ type: "input", ptyId: "p1", data: "not base64!" })).toThrow();
    expect(() => parsePtyCtlMsg({ type: "input", ptyId: "p1", data: "aGk " })).toThrow();
    expect(() => parsePtyCtlMsg({ type: "input", ptyId: "p1", data: B64_JUST_UNDER })).not.toThrow();
    expect(() => parsePtyCtlMsg({ type: "input", ptyId: "p1", data: B64_OVER })).toThrow();
  });

  it("rejects a negative or fractional lastOffset", () => {
    const attach = { type: "attach", ptyId: "p1", replyChannel: "r" };
    expect(() => parsePtyCtlMsg({ ...attach, lastOffset: -1 })).toThrow();
    expect(() => parsePtyCtlMsg({ ...attach, lastOffset: 1.5 })).toThrow();
  });
});

describe("ptyReplyMsg", () => {
  it("parses every variant", () => {
    expect(parsePtyReplyMsg({ type: "opened", ptyId: "p1", sessionId: "s1" })).toEqual({
      type: "opened",
      ptyId: "p1",
      sessionId: "s1",
    });
    for (const code of ["sandbox_busy", "sandbox_unavailable", "internal"] as const) {
      expect(
        parsePtyReplyMsg({ type: "opened_failed", ptyId: "p1", code, message: "boom" }),
      ).toEqual({ type: "opened_failed", ptyId: "p1", code, message: "boom" });
    }
    expect(
      parsePtyReplyMsg({
        type: "attach_reply",
        ptyId: "p1",
        truncated: true,
        chunks: [{ offset: 5, data: "aGk=" }],
        endOffset: 7,
      }),
    ).toEqual({
      type: "attach_reply",
      ptyId: "p1",
      truncated: true,
      chunks: [{ offset: 5, data: "aGk=" }],
      endOffset: 7,
    });
    for (const code of ["pty_gone", "internal"] as const) {
      expect(
        parsePtyReplyMsg({ type: "attach_failed", ptyId: "p1", code, message: "gone" }),
      ).toEqual({ type: "attach_failed", ptyId: "p1", code, message: "gone" });
    }
  });

  it("rejects an unknown code, bad chunk offsets/data and a bad endOffset", () => {
    expect(() =>
      parsePtyReplyMsg({ type: "opened_failed", ptyId: "p1", code: "nope", message: "x" }),
    ).toThrow();
    expect(() =>
      parsePtyReplyMsg({
        type: "attach_reply",
        ptyId: "p1",
        truncated: false,
        chunks: [{ offset: -1, data: "aGk=" }],
        endOffset: 0,
      }),
    ).toThrow();
    expect(() =>
      parsePtyReplyMsg({
        type: "attach_reply",
        ptyId: "p1",
        truncated: false,
        chunks: [{ offset: 0, data: "!!" }],
        endOffset: 0,
      }),
    ).toThrow();
    expect(() =>
      parsePtyReplyMsg({
        type: "attach_reply",
        ptyId: "p1",
        truncated: false,
        chunks: [{ offset: 0, data: B64_OVER }],
        endOffset: 0,
      }),
    ).toThrow();
    expect(() =>
      parsePtyReplyMsg({ type: "attach_reply", ptyId: "p1", truncated: false, chunks: [], endOffset: -3 }),
    ).toThrow();
  });
});

describe("ptyOutMsg", () => {
  it("parses output and exit (exitCode number and null)", () => {
    expect(parsePtyOutMsg({ type: "output", ptyId: "p1", offset: 0, data: "aGk=" })).toEqual({
      type: "output",
      ptyId: "p1",
      offset: 0,
      data: "aGk=",
    });
    expect(parsePtyOutMsg({ type: "exit", ptyId: "p1", exitCode: 0 })).toEqual({
      type: "exit",
      ptyId: "p1",
      exitCode: 0,
    });
    expect(parsePtyOutMsg({ type: "exit", ptyId: "p1", exitCode: null })).toEqual({
      type: "exit",
      ptyId: "p1",
      exitCode: null,
    });
  });

  it("rejects a negative offset and bad data", () => {
    expect(() => parsePtyOutMsg({ type: "output", ptyId: "p1", offset: -1, data: "aGk=" })).toThrow();
    expect(() => parsePtyOutMsg({ type: "output", ptyId: "p1", offset: 0, data: "xx yy" })).toThrow();
    expect(() => parsePtyOutMsg({ type: "output", ptyId: "p1", offset: 0, data: B64_OVER })).toThrow();
  });
});

describe("ws pty ops (union additions)", () => {
  it("parses every client pty op", () => {
    expect(wsClientMsg({ op: "pty_open", sessionId: "s1", cols: 80, rows: 24 })).toEqual({
      op: "pty_open",
      sessionId: "s1",
      cols: 80,
      rows: 24,
    });
    expect(wsClientMsg({ op: "pty_attach", ptyId: "p1" })).toEqual({ op: "pty_attach", ptyId: "p1" });
    expect(wsClientMsg({ op: "pty_attach", ptyId: "p1", lastOffset: null })).toEqual({
      op: "pty_attach",
      ptyId: "p1",
      lastOffset: null,
    });
    expect(wsClientMsg({ op: "pty_attach", ptyId: "p1", lastOffset: 12 })).toEqual({
      op: "pty_attach",
      ptyId: "p1",
      lastOffset: 12,
    });
    expect(wsClientMsg({ op: "pty_input", ptyId: "p1", data: "aGk=" })).toEqual({
      op: "pty_input",
      ptyId: "p1",
      data: "aGk=",
    });
    expect(wsClientMsg({ op: "pty_resize", ptyId: "p1", cols: 100, rows: 50 })).toEqual({
      op: "pty_resize",
      ptyId: "p1",
      cols: 100,
      rows: 50,
    });
    expect(wsClientMsg({ op: "pty_close", ptyId: "p1" })).toEqual({ op: "pty_close", ptyId: "p1" });
  });

  it("rejects bad client pty frames", () => {
    expect(() => wsClientMsg({ op: "pty_open", sessionId: "s1", cols: 0, rows: 24 })).toThrow();
    expect(() => wsClientMsg({ op: "pty_open", sessionId: "s1", cols: 501, rows: 24 })).toThrow();
    expect(() => wsClientMsg({ op: "pty_resize", ptyId: "p1", cols: "x", rows: 24 })).toThrow();
    expect(() => wsClientMsg({ op: "pty_input", ptyId: "p1", data: "not base64!" })).toThrow();
    expect(() => wsClientMsg({ op: "pty_input", ptyId: "p1", data: B64_OVER })).toThrow();
    expect(() => wsClientMsg({ op: "pty_attach", ptyId: "p1", lastOffset: -1 })).toThrow();
    expect(() => wsClientMsg({ op: "pty_attach", ptyId: "p1", lastOffset: 1.5 })).toThrow();
  });

  it("parses every server pty frame, and error gains an optional ptyId", () => {
    expect(wsServerMsg({ op: "pty_opened", ptyId: "p1", sessionId: "s1" })).toEqual({
      op: "pty_opened",
      ptyId: "p1",
      sessionId: "s1",
    });
    expect(wsServerMsg({ op: "pty_attached", ptyId: "p1", truncated: false })).toEqual({
      op: "pty_attached",
      ptyId: "p1",
      truncated: false,
    });
    expect(wsServerMsg({ op: "pty_output", ptyId: "p1", data: "aGk=", offset: 3 })).toEqual({
      op: "pty_output",
      ptyId: "p1",
      data: "aGk=",
      offset: 3,
    });
    expect(wsServerMsg({ op: "pty_exit", ptyId: "p1", exitCode: null })).toEqual({
      op: "pty_exit",
      ptyId: "p1",
      exitCode: null,
    });
    expect(wsServerMsg({ op: "pty_exit", ptyId: "p1", exitCode: 127 })).toEqual({
      op: "pty_exit",
      ptyId: "p1",
      exitCode: 127,
    });

    const withPty = { op: "error", code: "sandbox_busy", message: "full", ptyId: "p1" };
    expect(wsServerMsg(withPty)).toEqual(withPty);
    // still fine WITHOUT ptyId (additive, P1 shape unchanged)
    expect(wsServerMsg({ op: "error", code: "bad_message", message: "x" })).toEqual({
      op: "error",
      code: "bad_message",
      message: "x",
    });
  });

  it("rejects a bad server pty frame", () => {
    expect(() => wsServerMsg({ op: "pty_output", ptyId: "p1", data: "aGk=", offset: -1 })).toThrow();
    expect(() => wsServerMsg({ op: "pty_output", ptyId: "p1", data: "??", offset: 0 })).toThrow();
    expect(() => wsServerMsg({ op: "pty_attached", ptyId: "p1" })).toThrow();
  });
});
