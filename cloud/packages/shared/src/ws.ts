import { z } from "zod";
import { sessionEventSchema, type SessionEvent } from "./events.js";

export type WsClientMsg =
  | { op: "subscribe"; sessionId: string; lastEventId?: string | null }
  | { op: "unsubscribe"; sessionId: string }
  | { op: "ping" };

export type WsServerMsg =
  | { op: "subscribed"; sessionId: string }
  | { op: "event"; event: SessionEvent }
  | { op: "pong" }
  | { op: "error"; code: string; message: string; sessionId?: string };

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
 */
export type WsErrorCode =
  | "bad_message"
  | "forbidden"
  | "internal"
  | "too_many_subscriptions"
  | "unauthenticated";

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
  }),
]);

export function wsClientMsg(input: unknown): WsClientMsg {
  return wsClientMsgSchema.parse(input);
}

export function wsServerMsg(input: unknown): WsServerMsg {
  return wsServerMsgSchema.parse(input);
}
