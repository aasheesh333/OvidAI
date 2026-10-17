import { z } from "zod";

/**
 * Terminal-over-WS wire protocol (P2 Task 13): the Redis channel/key names,
 * the ctl/reply/out pub-sub message unions, and their zod schemas.
 *
 * Topology: the gateway owns one `ptyId` per terminal (a fresh uuid per
 * pty_open). Control frames (open/attach/input/resize/close) are published to
 * `pty:ctl:{ptyId}`; the worker PSUBSCRIBEs `pty:ctl:*`. Output (ring chunks +
 * exit) is published to `pty:out:{ptyId}`; the gateway SUBSCRIBEs that
 * channel BEFORE publishing an attach request (the ordering rule — the
 * gateway bridge's offset dedupe then makes snapshot+live exactly-once).
 * Replies (opened/attach_reply/…) go to the per-request `replyChannel` the
 * gateway generated and subscribed first. The registry `pty:reg:{ptyId}`
 * (HASH: userId, sessionId, cols, rows, createdAt, refreshed with PEXPIRE by a
 * heartbeat) is the ownership source for pty_attach and for control ops from
 * connections that did not open the pty.
 *
 * Pure data + zod only (no node APIs): the P3 thin client imports this file
 * in the browser.
 */

export function ptyCtlChannel(ptyId: string): string {
  return `pty:ctl:${ptyId}`;
}

export function ptyOutChannel(ptyId: string): string {
  return `pty:out:${ptyId}`;
}

export function ptyRegistryKey(ptyId: string): string {
  return `pty:reg:${ptyId}`;
}

/** The worker's PSUBSCRIBE pattern for every control channel. */
export const PTY_CTL_PATTERN = "pty:ctl:*";

/** Registry TTL; the worker's heartbeat re-arms it well inside this window. */
export const PTY_REGISTRY_TTL_MS = 90_000;
/** Registry heartbeat cadence (PEXPIRE refresh per live pty). */
export const PTY_HEARTBEAT_MS = 30_000;

/**
 * Max DECODED bytes of any base64 `data` field on the wire — both directions
 * (client key input and server ring-chunk output). Ring chunks can be up to
 * 64 KiB, so the worker bridge splits every chunk it publishes/snapshots
 * into pieces at most this big; nothing downstream ever exceeds the cap.
 */
export const PTY_WIRE_MAX_BYTES = 16_384;

/** One retained slice of a pty's output stream, as it appears on the wire. */
export interface RingChunkWire {
  /** Byte position of this chunk's first byte in the pty's lifetime stream. */
  offset: number;
  /** The chunk's bytes, base64-encoded. */
  data: string;
}

export type PtyCtlMsg =
  | {
      type: "open";
      ptyId: string;
      userId: string;
      sessionId: string;
      cols: number;
      rows: number;
      replyChannel: string;
    }
  | { type: "attach"; ptyId: string; lastOffset: number | null; replyChannel: string }
  | { type: "input"; ptyId: string; data: string /* base64 */ }
  | { type: "resize"; ptyId: string; cols: number; rows: number }
  | { type: "close"; ptyId: string };

export type PtyReplyMsg =
  | { type: "opened"; ptyId: string; sessionId: string }
  | {
      type: "opened_failed";
      ptyId: string;
      code: "sandbox_busy" | "sandbox_unavailable" | "internal";
      message: string;
    }
  | {
      type: "attach_reply";
      ptyId: string;
      truncated: boolean;
      chunks: RingChunkWire[];
      endOffset: number;
    }
  | { type: "attach_failed"; ptyId: string; code: "pty_gone" | "internal"; message: string };

export type PtyOutMsg =
  | { type: "output"; ptyId: string; offset: number; data: string /* base64 */ }
  | { type: "exit"; ptyId: string; exitCode: number | null };

// -- validation building blocks ---------------------------------------------

const BASE64_RE = /^[A-Za-z0-9+/=]*$/;

/**
 * Upper bound of a base64 string's decoded size, browser-safe (no Buffer).
 * Slightly over-estimates non-canonical padding, which is the safe direction
 * for a cap check: it never lets an oversized payload through.
 */
function base64DecodedBytes(s: string): number {
  const unpadded = s.replace(/=/g, "");
  return Math.floor((unpadded.length * 3) / 4);
}

/** Shared `data` field: base64 charset AND ≤ PTY_WIRE_MAX_BYTES decoded. */
export const ptyBase64Data = z
  .string()
  .regex(BASE64_RE, "data must be base64")
  .refine((s) => base64DecodedBytes(s) <= PTY_WIRE_MAX_BYTES, {
    message: `data decodes to more than ${PTY_WIRE_MAX_BYTES} bytes`,
  });

/** Terminal dimensions: integers 1..500. */
const dim = z
  .number()
  .int()
  .min(1)
  .max(500);

/** Byte offsets: non-negative integers. */
const offset = z.number().int().nonnegative();

const id = z.string().min(1);

// -- schemas ----------------------------------------------------------------

export const ptyCtlMsg: z.ZodType<PtyCtlMsg> = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("open"),
    ptyId: id,
    userId: id,
    sessionId: id,
    cols: dim,
    rows: dim,
    replyChannel: id,
  }),
  z.object({
    type: z.literal("attach"),
    ptyId: id,
    lastOffset: offset.nullable(),
    replyChannel: id,
  }),
  z.object({
    type: z.literal("input"),
    ptyId: id,
    data: ptyBase64Data,
  }),
  z.object({
    type: z.literal("resize"),
    ptyId: id,
    cols: dim,
    rows: dim,
  }),
  z.object({
    type: z.literal("close"),
    ptyId: id,
  }),
]);

export const ptyReplyMsg: z.ZodType<PtyReplyMsg> = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("opened"),
    ptyId: id,
    sessionId: id,
  }),
  z.object({
    type: z.literal("opened_failed"),
    ptyId: id,
    code: z.enum(["sandbox_busy", "sandbox_unavailable", "internal"]),
    message: z.string(),
  }),
  z.object({
    type: z.literal("attach_reply"),
    ptyId: id,
    truncated: z.boolean(),
    chunks: z.array(z.object({ offset, data: ptyBase64Data })),
    endOffset: offset,
  }),
  z.object({
    type: z.literal("attach_failed"),
    ptyId: id,
    code: z.enum(["pty_gone", "internal"]),
    message: z.string(),
  }),
]);

export const ptyOutMsg: z.ZodType<PtyOutMsg> = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("output"),
    ptyId: id,
    offset,
    data: ptyBase64Data,
  }),
  z.object({
    type: z.literal("exit"),
    ptyId: id,
    exitCode: z.number().nullable(),
  }),
]);

export function parsePtyCtlMsg(input: unknown): PtyCtlMsg {
  return ptyCtlMsg.parse(input);
}

export function parsePtyReplyMsg(input: unknown): PtyReplyMsg {
  return ptyReplyMsg.parse(input);
}

export function parsePtyOutMsg(input: unknown): PtyOutMsg {
  return ptyOutMsg.parse(input);
}
