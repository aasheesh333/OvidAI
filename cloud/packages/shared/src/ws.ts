import { z } from "zod";
import { sessionEventSchema, type SessionEvent } from "./events.js";
import { ptyBase64Data } from "./pty.js";
import { browserInputEventSchema, type BrowserInputEvent, browserStateDtoSchema, type BrowserStateDto } from "./browser.js";
import { systemEventEnvelopeSchema, type SystemEventEnvelope } from "./system.js";
import { systemEventSchema, type SystemEvent } from "./schedules.js";

export type WsClientMsg =
  | { op: "subscribe"; sessionId: string; lastEventId?: string | null }
  | { op: "unsubscribe"; sessionId: string }
  | { op: "ping" }
  // Task 13 (terminal over WS) — additive discriminants only.
  | { op: "pty_open"; sessionId: string; cols: number; rows: number }
  | { op: "pty_attach"; ptyId: string; lastOffset?: number | null }
  | { op: "pty_input"; ptyId: string; data: string }
  | { op: "pty_resize"; ptyId: string; cols: number; rows: number }
  | { op: "pty_close"; ptyId: string }
  // P6 Task 2 (browser channel) — additive discriminants only.
  | { op: "browser_attach"; sessionId: string }
  | { op: "browser_detach"; sessionId: string }
  | { op: "browser_input"; sessionId: string; input: BrowserInputEvent }
  | { op: "browser_takeover"; sessionId: string; enabled: boolean }
  /** Wave 6 W4: select an existing agent-opened tab (never creates one). */
  | { op: "browser_switch_tab"; sessionId: string; index: number }
  // P3 Task 12 (approvals over WS) — additive discriminants only. The
  // client answers an approval_requested session event with this op; the
  // gateway validates session ownership, publishes to the approval
  // responses channel, and acks.
  | {
      op: "approval_response";
      sessionId: string;
      approvalId: string;
      decision: "allow" | "deny" | "always";
    }
  // P5 Task 10 (system channel) — additive discriminant only. The client
  // answers a requiresResponse system_event envelope by its `id`; the
  // gateway forwards the payload to sys:{uid}:in for the worker's pending
  // request. There is deliberately no ack frame — the request itself
  // resolving IS the confirmation (a late answer is a no-op on the worker).
  | { op: "system_response"; id: string; payload: Record<string, unknown> }
  // P4 Task 2 (scheduler system channel) — additive discriminants only. The
  // client asks the gateway to relay this uid's scheduler events; the
  // gateway answers with `system_subscribed` and then `system` frames.
  | { op: "subscribe_system" }
  | { op: "unsubscribe_system" };

export type WsServerMsg =
  // Replay-truncation signal (ADDITIVE optional field — older clients that
  // don't know it ignore it): `trimmed: true` on a `subscribed` ack means
  // the replay hit the gateway's REPLAY_LIMIT cap, so there MAY be more
  // backlog the client did not receive; absent means the whole backlog was
  // delivered. The Dart client consumes it at `case 'subscribed'`
  // (cloud_ws.dart) to heal instead of silently rendering a truncated
  // history.
  | { op: "subscribed"; sessionId: string; trimmed?: boolean }
  | { op: "event"; event: SessionEvent }
  | { op: "pong" }
  | { op: "error"; code: string; message: string; sessionId?: string; ptyId?: string }
  // Task 13 (terminal over WS) — additive discriminants only.
  | { op: "pty_opened"; ptyId: string; sessionId: string }
  | { op: "pty_attached"; ptyId: string; truncated: boolean }
  | { op: "pty_output"; ptyId: string; data: string; offset: number }
  | { op: "pty_exit"; ptyId: string; exitCode: number | null }
  // P6 Task 2 (browser channel) — additive discriminants only.
  // `viewerId` (Wave 5 FE-026): THIS socket's viewer id, so the client can
  // compare it with `state.takeoverViewerId`.
  | { op: "browser_state"; sessionId: string; state: BrowserStateDto; viewerId?: string }
  // P3 Task 12 (approvals over WS) — additive discriminants only. Ack for a
  // published approval_response: the gateway echoes the approvalId and the
  // decision it forwarded to the worker bridge.
  | { op: "approval_ack"; approvalId: string; decision: string }
  // P5 Task 10 (system channel) — additive discriminant only. A system event
  // pushed to this uid's sockets via the gateway's system hub (worker bus or
  // gateway-originated, e.g. the MCP OAuth callback).
  | { op: "system_event"; event: SystemEventEnvelope }
  // P4 Task 2 (scheduler system channel) — additive discriminants only. Ack
  // for `subscribe_system`, then one `system` frame per scheduler event of
  // the ticket's uid until `unsubscribe_system` or close.
  | { op: "system_subscribed" }
  | { op: "system"; event: SystemEvent };

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
 * - unavailable          — the composition wired no handler for the op
 *                          (approval_response without a publisher; browser_*)
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
  | "timeout"
  // P3 Task 12: approval_response on a composition with no approval
  // publisher wired (also sent by the browser channel's own fallback).
  | "unavailable"
  // browser_input/takeover without an attach for that id.
  | "not_attached"
  // Wave 5 FE-026: browser_input while ANOTHER viewer holds takeover.
  | "not_controller";

/**
 * Redis pub/sub channel carrying approval responses from the gateway to the
 * worker's approval bridge (P3 Task 12). Lives on the QUEUE redis instance
 * (noeviction) — messages are transient fire-and-forget payloads
 * {approvalId, userId, decision}; a lost message degrades to the bridge's
 * own timeout-deny, never to a stuck run.
 */
export const APPROVAL_RESPONSES_CHANNEL = "ovid:approval-responses";

/** Terminal dimension bounds shared by pty_open/pty_resize (ints 1..500). */
const dim = z
  .number()
  .int()
  .min(1)
  .max(500);

/** Byte offsets: non-negative integers. */
const offset = z.number().int().nonnegative();

const ptyIdField = z.string().min(1);

// The annotation is a CAST, not a plain type: the approval_response entry
// keeps `decision` an open string on the wire while WsClientMsg documents
// the enum — parse() therefore returns a wider shape than the declared
// union and the gateway enforces the three values (bad_request). This is
// the same documentation-vs-enforcement split as WsErrorCode above.
const wsClientMsgSchema = z.discriminatedUnion("op", [
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
  z.object({
    op: z.literal("browser_attach"),
    sessionId: z.string().min(1),
  }),
  z.object({
    op: z.literal("browser_detach"),
    sessionId: z.string().min(1),
  }),
  z.object({
    op: z.literal("browser_input"),
    sessionId: z.string().min(1),
    input: browserInputEventSchema,
  }),
  z.object({
    op: z.literal("browser_takeover"),
    sessionId: z.string().min(1),
    enabled: z.boolean(),
  }),
  z.object({
    op: z.literal("browser_switch_tab"),
    sessionId: z.string().min(1),
    index: z.number().int().nonnegative(),
  }),
  z.object({
    op: z.literal("approval_response"),
    sessionId: z.string().min(1),
    approvalId: z.string().min(1),
    // Open string ON PURPOSE (WsErrorCode discipline): the union in the type
    // above is the documented contract, but a malformed decision must reach
    // the GATEWAY so it can answer the specific `bad_request` refusal —
    // z.enum here would collapse that into a generic bad_message. The
    // gateway (and, defensively, the worker bridge) enforce the three
    // values at the edge.
    decision: z.string().min(1),
  }),
  z.object({
    op: z.literal("system_response"),
    id: z.string().min(1),
    payload: z.record(z.string(), z.unknown()),
  }),
  z.object({
    op: z.literal("subscribe_system"),
  }),
  z.object({
    op: z.literal("unsubscribe_system"),
  }),
]) as unknown as z.ZodType<WsClientMsg>;

const wsServerMsgSchema: z.ZodType<WsServerMsg> = z.discriminatedUnion("op", [
  z.object({
    op: z.literal("subscribed"),
    sessionId: z.string().min(1),
    // Optional on the wire (additive): the gateway sets it only when the
    // replay was capped, so a deep-equal check against an uncapped ack
    // still matches frames from older servers.
    trimmed: z.boolean().optional(),
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
  z.object({
    op: z.literal("browser_state"),
    sessionId: z.string().min(1),
    state: browserStateDtoSchema,
    viewerId: z.string().min(1).optional(),
  }),
  z.object({
    op: z.literal("approval_ack"),
    approvalId: z.string().min(1),
    decision: z.string().min(1),
  }),
  z.object({
    op: z.literal("system_event"),
    event: systemEventEnvelopeSchema,
  }),
  z.object({
    op: z.literal("system_subscribed"),
  }),
  z.object({
    op: z.literal("system"),
    event: systemEventSchema,
  }),
]);

export function wsClientMsg(input: unknown): WsClientMsg {
  return wsClientMsgSchema.parse(input);
}

export function wsServerMsg(input: unknown): WsServerMsg {
  return wsServerMsgSchema.parse(input);
}
