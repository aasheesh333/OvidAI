import { z } from "zod";
import { sessionEventSchema, type SessionEvent } from "./events.js";
import { ptyBase64Data } from "./pty.js";

export type WsClientMsg =
  | { op: "subscribe"; sessionId: string; lastEventId?: string | null }
  | { op: "unsubscribe"; sessionId: string }
  | { op: "ping" }
  // Task 13 (terminal over WS) — additive discriminants only.
  | { op: "pty_open"; sessionId: string; cols: number; rows: number }
  | { op: "pty_attach"; ptyId: string; lastOffset?: number | null }
  | { op: "pty_input"; ptyId: string; data: string }
  | { op: "pty_resize"; ptyId: string; cols: number; rows: number }
  | { op: "pty_close"; ptyId: string };

export type WsServerMsg =
  | { op: "subscribed"; sessionId: string }
  | { op: "event"; event: SessionEvent }
  | { op: "pong" }
  | { op: "error"; code: string; message: string; sessionId?: string; ptyId?: string }
  // Task 13 (terminal over WS) — additive discriminants only.
  | { op: "pty_opened"; ptyId: string; sessionId: string }
  | { op: "pty_attached"; ptyId: string; truncated: boolean }
  | { op: "pty_output"; ptyId: string; data: string; offset: number }
  | { op: "pty_exit"; ptyId: string; exitCode: number | null };

/**
 * The error codes the WS server currently sends in `error` frames. The wire
 * schema keeps `code` an open string (forward-compatible), so this union is
 * documentation, not enforcement — extend it ADDITIVELY when a new refusal
 * reason appears; existing codes never change meaning:
 * - bad_message          — unparseable JSON or off-contract client frame
 * - forbidden            — session unknown or not owned by this principal
 * - internal             — server-side failure during a frame (db/redis)
 * - too_many_subscriptions — per-connection subscription cap (64) exceeded
 * - unauthenticated      — missing/invalid/reused ticket
 * - sandbox_busy         — pty_open: the sandbox admission gate timed out
 * - sandbox_unavailable  — pty_open: capacity/disk/rootfs unavailable
 * - pty_gone             — pty_attach: the terminal exited (or never existed)
 * - timeout              — the worker never answered a pty request in time
 */
export type WsErrorCode =
  | "bad_message"
  | "forbidden"
  | "internal"
  | "too_many_subscriptions"
  | "unauthenticated"
  | "sandbox_busy"
  | "sandbox_unavailable"
  | "pty_gone"
  | "timeout";

/** Terminal dimension bounds shared by pty_open/pty_resize (ints 1..500). */
const dim = z
  .number()
  .int()
  .min(1)
  .max(500);

/** Byte offsets: non-negative integers. */
const offset = z.number().int().nonnegative();

const ptyIdField = z.string().min(1);

const wsClientMsgSchema: z.ZodType<WsClientMsg> = z.discriminatedUnion("op", [
  z.object({
    op: z.literal("subscribe"),
    sessionId: z.string().min(1),
    lastEventId: z.string().min(1).nullish(),
  }),
  z.object({
    op: z.literal("unsubscribe"),
    sessionId: z.string().min(1),
  }),
  z.object({
    op: z.literal("ping"),
  }),
  z.object({
    op: z.literal("pty_open"),
    sessionId: z.string().min(1),
    cols: dim,
    rows: dim,
  }),
  z.object({
    op: z.literal("pty_attach"),
    ptyId: ptyIdField,
    lastOffset: offset.nullish(),
  }),
  z.object({
    op: z.literal("pty_input"),
    ptyId: ptyIdField,
    data: ptyBase64Data,
  }),
  z.object({
    op: z.literal("pty_resize"),
    ptyId: ptyIdField,
    cols: dim,
    rows: dim,
  }),
  z.object({
    op: z.literal("pty_close"),
    ptyId: ptyIdField,
  }),
]);

const wsServerMsgSchema: z.ZodType<WsServerMsg> = z.discriminatedUnion("op", [
  z.object({
    op: z.literal("subscribed"),
    sessionId: z.string().min(1),
  }),
  z.object({
    op: z.literal("event"),
    event: sessionEventSchema,
  }),
  z.object({
    op: z.literal("pong"),
  }),
  z.object({
    op: z.literal("error"),
    code: z.string().min(1),
    message: z.string(),
    sessionId: z.string().min(1).optional(),
    ptyId: z.string().min(1).optional(),
  }),
  z.object({
    op: z.literal("pty_opened"),
    ptyId: ptyIdField,
    sessionId: z.string().min(1),
  }),
  z.object({
    op: z.literal("pty_attached"),
    ptyId: ptyIdField,
    truncated: z.boolean(),
  }),
  z.object({
    op: z.literal("pty_output"),
    ptyId: ptyIdField,
    data: ptyBase64Data,
    offset,
  }),
  z.object({
    op: z.literal("pty_exit"),
    ptyId: ptyIdField,
    exitCode: z.number().nullable(),
  }),
]);

export function wsClientMsg(input: unknown): WsClientMsg {
  return wsClientMsgSchema.parse(input);
}

export function wsServerMsg(input: unknown): WsServerMsg {
  return wsServerMsgSchema.parse(input);
}
