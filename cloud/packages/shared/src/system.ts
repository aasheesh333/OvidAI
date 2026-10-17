import { z } from "zod";

/**
 * System channel (P5 Task 10) — the event shapes that ride the WS
 * `system_event` op and the `sys:{uid}:out` / `sys:{uid}:in` redis channels:
 * MCP sampling approvals, elicitation prompts, plugin grant approvals,
 * plugin install progress, and MCP OAuth completion notices. One envelope
 * shape carries all of them; `requiresResponse` distinguishes fire-and-
 * forget notices (progress, oauth completed/failed) from requests the client
 * is expected to answer on `sys:{uid}:in` (sampling approval, elicitation,
 * plugin grant approval — unanswered ones default-deny on the worker after
 * 120 s, spec §6.2).
 *
 * This module is ADDITIVE to the P1 ws contract: ws.ts gains exactly two
 * union variants (`system_event` server → client, `system_response` client
 * → server) and touches nothing else. The channel-name helpers live here
 * (not in the gateway) because BOTH sides of the protocol — the gateway hub
 * and @ovid/mcp's worker-side system bus — must agree on them; the same
 * discipline as APPROVAL_RESPONSES_CHANNEL in ws.ts.
 */

/**
 * The documented event kinds. Kinds are additive over time (each new
 * consumer appends); an envelope with an unknown kind is REJECTED at the
 * schema boundary (the producer is off-contract, not merely newer).
 */
export type SystemEventKind =
  | "mcp_sampling_approval"
  | "mcp_elicitation"
  | "plugin_grant_approval"
  | "plugin_install_progress"
  | "mcp_oauth_completed"
  | "mcp_oauth_failed";

/** The wire envelope for one system event. */
export interface SystemEventEnvelope {
  /** Correlation id: requests are answered by this id (system_response). */
  id: string;
  kind: SystemEventKind;
  /** True when the client is expected to respond (approval/elicitation). */
  requiresResponse: boolean;
  payload: Record<string, unknown>;
  /** ISO timestamp — the publisher fills it when absent. */
  ts: string;
}

const systemEventKindSchema = z.enum([
  "mcp_sampling_approval",
  "mcp_elicitation",
  "plugin_grant_approval",
  "plugin_install_progress",
  "mcp_oauth_completed",
  "mcp_oauth_failed",
]);

export const systemEventEnvelopeSchema: z.ZodType<SystemEventEnvelope> = z.object({
  id: z.string().min(1),
  kind: systemEventKindSchema,
  requiresResponse: z.boolean(),
  payload: z.record(z.string(), z.unknown()),
  ts: z.string().min(1),
});

/** Parses and validates one envelope; THROWS on an off-contract shape. */
export function systemEventEnvelope(input: unknown): SystemEventEnvelope {
  return systemEventEnvelopeSchema.parse(input);
}

/** Worker/gateway → that uid's sockets (the hub subscribes this per uid). */
export function sysOutChannel(uid: string): string {
  return `sys:${uid}:out`;
}

/** That uid's sockets → the worker's pending request (the bus listens). */
export function sysInChannel(uid: string): string {
  return `sys:${uid}:in`;
}
