import type { Redis } from "ioredis";
import { sessions, type Db } from "@ovid/db";
import type { EventLog } from "@ovid/events";
import { APPROVAL_RESPONSES_CHANNEL } from "@ovid/shared";
import type { ApprovalBridge, ApprovalDecision } from "@ovid/agent-core";

/**
 * Worker-side approval bridge (P3 Task 12): the ApprovalGate's transport.
 *
 * SUBSCRIBEs APPROVAL_RESPONSES_CHANNEL ONCE (on a dedicated duplicated
 * connection — pub/sub mode blocks regular commands, the Task 4
 * convention); the gateway publishes {approvalId, userId, decision} there
 * after its ownership check. ask() registers a pending deferred keyed by
 * approvalId and resolves on the matching message — but ONLY after its OWN
 * ownership re-check (sessions.get): a cross-user answer on the channel is
 * dropped, never resolved.
 *
 * First resolution wins: a user response landing after the timeout (or
 * after an abort) is a NO-OP (Review Focus #1 — the gateway acked the
 * publish, but the bridge had already settled; the gate therefore emits
 * exactly one approval_resolved and a late "always" writes no grant). The
 * ABORT signal resolves "deny" so a cancelled run never wedges on a card.
 *
 * deps.events is the worker composition's shared EventLog — the GATE owns
 * approval_requested/approval_resolved emission through its sinkFactory
 * (wired to the same log in Task 16), so the bridge itself never appends;
 * the dep is part of the pinned composition signature.
 */

const DECISIONS: ReadonlySet<string> = new Set(["allow", "deny", "always"]);

/** One pending ask: settle() is once-only (first resolution wins). */
interface PendingEntry {
  sessionId: string;
  userId: string;
  settle(decision: ApprovalDecision | "timeout"): void;
}

export interface RedisApprovalBridgeHandle extends ApprovalBridge {
  /** Resolves once the SUBSCRIBE of APPROVAL_RESPONSES_CHANNEL is acknowledged. */
  readonly ready: Promise<void>;
  /**
   * Quits the channel subscription and reaps every still-pending ask as
   * "deny" (fail-closed: a wait-forever question can never hang shutdown).
   */
  close(): Promise<void>;
}

export function createRedisApprovalBridge(deps: {
  redisQ: Redis;
  events: EventLog;
  db: Db;
}): RedisApprovalBridgeHandle {
  const { redisQ, db } = deps;

  const pending = new Map<string, PendingEntry>();

  // Dedicated connection for the subscription (Task 4 convention).
  const sub = redisQ.duplicate();
  sub.on("error", () => {}); // ioredis reconnects on its own; transient errors are contained

  sub.on("message", (_channel: string, message: string) => {
    let msg: { approvalId?: unknown; userId?: unknown; decision?: unknown };
    try {
      msg = JSON.parse(message) as typeof msg;
    } catch {
      return; // garbage on the channel: skip, keep listening
    }
    if (
      typeof msg.approvalId !== "string" ||
      typeof msg.userId !== "string" ||
      typeof msg.decision !== "string" ||
      !DECISIONS.has(msg.decision)
    ) {
      return; // malformed payload or decision: fail-closed drop
    }
    const approvalId = msg.approvalId;
    const userId = msg.userId;
    const decision = msg.decision as ApprovalDecision;
    void (async () => {
      try {
        const entry = pending.get(approvalId);
        if (entry === undefined) return; // late or unknown: no-op (Review Focus #1)
        // Ownership re-check: only the session's owner may answer. A
        // cross-user publish is dropped — the ask keeps waiting (its own
        // timeout or the correct owner's answer settles it).
        const owned = await sessions.get(db, entry.sessionId, userId);
        if (owned === null) return;
        entry.settle(decision);
      } catch (err) {
        console.error(`[approval-bridge] response dispatch failed for ${approvalId}:`, err);
      }
    })();
  });

  const ready: Promise<void> = sub
    .subscribe(APPROVAL_RESPONSES_CHANNEL)
    .then(() => undefined);

  let stopped = false;

  return {
    ready,
    ask(req, o) {
      return new Promise<ApprovalDecision | "timeout">((resolve) => {
        if (stopped) {
          resolve("deny"); // closed bridge: fail-closed, never a wedged ask
          return;
        }
        let settled = false;
        let timer: ReturnType<typeof setTimeout> | undefined;
        const onAbort = (): void => {
          settle("deny");
        };
        const settle = (decision: ApprovalDecision | "timeout"): void => {
          if (settled) return; // first resolution wins
          settled = true;
          if (timer !== undefined) clearTimeout(timer);
          o.signal.removeEventListener("abort", onAbort);
          pending.delete(req.approvalId);
          resolve(decision);
        };
        pending.set(req.approvalId, { sessionId: o.sessionId, userId: o.userId, settle });
        if (o.timeoutMs > 0) {
          timer = setTimeout(() => settle("timeout"), o.timeoutMs);
          timer.unref?.(); // never hold the process open by itself
        }
        if (o.signal.aborted) {
          settle("deny");
          return;
        }
        o.signal.addEventListener("abort", onAbort);
      });
    },
    async close() {
      if (stopped) return;
      stopped = true;
      sub.removeAllListeners("message");
      try {
        await sub.unsubscribe(APPROVAL_RESPONSES_CHANNEL);
      } catch {
        // connection already gone — quit() below still cleans up
      }
      await sub.quit().catch(() => {});
      for (const entry of [...pending.values()]) entry.settle("deny");
      pending.clear();
    },
  };
}
