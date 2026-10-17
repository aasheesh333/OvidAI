// Approval gate (P3 Task 12) — grants + bridge + session events, the port
// of agent_service.dart's _maybeApprove/_askUser approval core.
//
// approve(ctx, req) flow:
//  1. consult the session's grants for pathTargets/hostTargets — a matching
//     allow/always grant answers "allow" with NO prompt, a matching deny
//     answers "deny" with NO prompt (silently: grant hits raise no events,
//     matching Dart);
//  2. a remembered denial of an identical targetless request auto-denies
//     without prompting (Dart _deniedApprovals parity — denialKey is the
//     tool+summary hash) until forgetDenial(sessionId, key);
//  3. otherwise emit approval_requested, ask the bridge, and on settle emit
//     approval_resolved. The BRIDGE guarantees first-resolution-wins: a late
//     user answer after a timeout is a no-op there, so exactly one
//     approval_resolved is ever emitted and a late "always" writes nothing;
//  4. decision "always" + targets persists one grant row per target kind
//     (grantsRepo.add — only "always" persists; plain "allow" and denials
//     with targets are not written, per the P3 brief);
//  5. a denied TARGETLESS request is remembered per session.
//
// Timeout seam (spec §6.2/§8): the default is 120 s, attended AND
// unattended. kind "question"/"plan" while ATTENDED gets NO timeout (a
// question card IS the interaction — timeoutMs 0 means wait); unattended
// keeps the timeout for ALL kinds. deps.timeoutMs OVERRIDES the 120 s
// default (Task 16 wires OVID_APPROVAL_TIMEOUT_MS here — the documented
// seam the unattended-timeout tests inject short timeouts through).
// deps.timeoutPolicy, when provided, computes the per-request timeout for
// everything outside the attended question/plan exception — the exported
// decision point P4's UnattendedApprovalHook extends at its own seam.
//
// The ABORT signal resolves "deny" inside the bridge (worker
// approvalBridge.ts) — the gate only passes ctx.signal through.

import { createHash } from "node:crypto";

import { grantsRepo, type Db } from "@ovid/db";

import { findApplicableGrant, normalizeGrantHost, normalizeGrantPath, type GrantLike } from "./grants.js";
import type {
  ApprovalBridge,
  ApprovalDecision,
  ApprovalGate,
  ApprovalRequest,
  EventSink,
} from "./ports.js";
import type { ToolContext } from "./types.js";

/** Spec §6.2/§8 — the 120 s attended AND unattended default. */
export const APPROVAL_TIMEOUT_MS = 120_000;

/**
 * Per-request timeout decision point. P4's UnattendedApprovalHook extends
 * this seam: it receives the request and the unattended flag and returns
 * the timeout (the fixed default / the env override applies when unset).
 */
export type ApprovalTimeoutPolicy = (
  req: ApprovalRequest,
  ctx: { unattended: boolean },
) => number;

/** The gate's deps: grants + bridge + the session event sink factory. */
export interface ApprovalGateDeps {
  db: Db;
  bridge: ApprovalBridge;
  sinkFactory(sessionId: string): EventSink;
  /** Overrides the 120 s default (Task 16 wires OVID_APPROVAL_TIMEOUT_MS). */
  timeoutMs?: number;
  /** Computes the per-request timeout when provided (P4 seam). */
  timeoutPolicy?: ApprovalTimeoutPolicy;
}

/**
 * The gate plus the denial-memory handle: forgetDenial clears one remembered
 * denial so the next identical targetless request prompts again (Dart's
 * revokeRememberedDenial parity).
 */
export interface ApprovalGateHandle extends ApprovalGate {
  forgetDenial(sessionId: string, denialKey: string): boolean;
}

/** denialKey = hash of tool+summary (the brief's tool+summary hash). */
export function approvalDenialKey(tool: string, summary: string): string {
  return createHash("sha256").update(`${tool}\u0000${summary}`).digest("hex");
}

export function createApprovalGate(deps: ApprovalGateDeps): ApprovalGateHandle {
  /** sessionId → remembered denial keys (Dart _deniedApprovals parity). */
  const denials = new Map<string, Set<string>>();

  const baseTimeout = deps.timeoutMs ?? APPROVAL_TIMEOUT_MS;

  function effectiveTimeoutMs(req: ApprovalRequest, unattended: boolean): number {
    // Structural rule first: an attended question/plan card waits — the
    // interaction itself is the point, and a policy/override must not be
    // able to time it out. Everything else: policy, else the default.
    if ((req.kind === "question" || req.kind === "plan") && !unattended) return 0;
    if (deps.timeoutPolicy !== undefined) {
      return deps.timeoutPolicy(req, { unattended });
    }
    return baseTimeout;
  }

  function rememberDenial(sessionId: string, key: string): void {
    const set = denials.get(sessionId);
    if (set === undefined) denials.set(sessionId, new Set([key]));
    else set.add(key);
  }

  return {
    async approve(ctx, req) {
      // ---- 1. grant consultation (silent: no prompt, no events) ----
      const targets: Array<{ kind: "path" | "host"; value: string }> = [
        ...req.pathTargets.map((value) => ({ kind: "path" as const, value })),
        ...req.hostTargets.map((value) => ({ kind: "host" as const, value })),
      ];
      if (targets.length > 0) {
        const rows = await grantsRepo.listForSession(deps.db, ctx.userId, ctx.sessionId);
        const grants: GrantLike[] = rows.map((r) => ({
          kind: r.kind === "path" ? "path" : "host",
          pattern: r.pattern,
          decision: r.decision === "deny" ? "deny" : r.decision === "allow" ? "allow" : "always",
        }));
        // Combined-card semantics: any target with an applicable deny refuses
        // without asking; EVERY target covered by an allow/always grant skips
        // the card; anything partially covered still prompts.
        let anyDenied = false;
        let allCovered = true;
        for (const t of targets) {
          const applicable = findApplicableGrant(grants, t.kind, t.value);
          if (applicable === null) {
            allCovered = false;
          } else if (applicable.decision === "deny") {
            anyDenied = true;
          }
        }
        if (anyDenied) return "deny";
        if (allCovered) return "allow";
      }

      // ---- 2. remembered denial of an identical targetless request ----
      const denialKey = approvalDenialKey(req.tool, req.summary);
      if (targets.length === 0 && (denials.get(ctx.sessionId)?.has(denialKey) ?? false)) {
        return "deny"; // auto-deny WITHOUT prompting (Dart parity: silent)
      }

      // ---- 3. prompt: request event → bridge → resolved event ----
      const sink: EventSink = deps.sinkFactory(ctx.sessionId);
      const timeoutMs = effectiveTimeoutMs(req, ctx.unattended);
      const expiresAt =
        timeoutMs > 0 ? new Date(Date.now() + timeoutMs).toISOString() : null;
      await sink.emit("approval_requested", {
        approvalId: req.approvalId,
        tool: req.tool,
        kind: req.kind,
        summary: req.summary,
        detail: req.detail,
        allowAlways: req.allowAlways,
        expiresAt,
      });

      const settled = await deps.bridge.ask(req, {
        sessionId: ctx.sessionId,
        userId: ctx.userId,
        timeoutMs,
        signal: ctx.signal,
      });
      const timedOut = settled === "timeout";
      const decision: ApprovalDecision = timedOut ? "deny" : settled;
      const reason =
        timedOut === true ? (ctx.unattended ? "unattended_timeout" : "timeout") : undefined;

      // ---- 4. "always" + targets → one grant row per target ----
      if (decision === "always" && targets.length > 0) {
        // Dart _contains parity WITHIN one request: two spellings of the
        // same target ("/ws/a" and "/ws/a/") normalize to one pattern and
        // must not stack duplicate rows.
        const written = new Set<string>();
        for (const t of targets) {
          // Blank targets never persist (blank-path parity: a near-blank
          // value would normalize into the ROOT grant "/"). An explicit "/"
          // target is a legitimate root grant and persists.
          if (t.value.trim() === "") continue;
          const pattern =
            t.kind === "path" ? normalizeGrantPath(t.value) : normalizeGrantHost(t.value);
          if (pattern === "") continue;
          const dedupeKey = `${t.kind}\u0000${pattern}`;
          if (written.has(dedupeKey)) continue;
          written.add(dedupeKey);
          await grantsRepo.add(deps.db, {
            userId: ctx.userId,
            sessionId: ctx.sessionId,
            kind: t.kind,
            pattern,
            decision: "always",
            mode: ctx.mode,
          });
        }
      }

      // ---- 5. resolved event (exactly one — the bridge settles once) ----
      await sink.emit("approval_resolved", {
        approvalId: req.approvalId,
        decision,
        ...(reason !== undefined ? { reason } : {}),
      });

      // ---- 6. denied targetless requests are remembered per session ----
      if (decision === "deny" && targets.length === 0) {
        rememberDenial(ctx.sessionId, denialKey);
      }
      return decision;
    },

    forgetDenial(sessionId: string, denialKey: string): boolean {
      const set = denials.get(sessionId);
      const removed = set?.delete(denialKey) ?? false;
      if (set !== undefined && set.size === 0) denials.delete(sessionId);
      return removed;
    },
  };
}
