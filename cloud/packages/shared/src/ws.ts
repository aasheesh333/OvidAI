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
