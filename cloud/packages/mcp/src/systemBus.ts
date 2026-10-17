import { randomBytes } from "node:crypto";
import { z } from "zod";

/**
 * Worker-side system bus (P5 Task 10) — the producer half of the system
 * channel the gateway's SystemHub consumes:
 *
 *   publish()/request() → sys:{uid}:out → the gateway hub fans the envelope
 *   out to that uid's sockets as `system_event` ws frames. request() then
 *   waits for the client's answer on sys:{uid}:in (matched by envelope id);
 *   a timeout resolves null and the CALLER treats null as DENY (spec §6.2,
 *   120 s default — matching the unattended-run auto-deny).
 *
 * Channel names, envelope kinds and the envelope shape are @ovid/shared's
 * system.ts contract. The workspace dependencies @ovid/mcp → @ovid/shared
 * and → ioredis cannot be DECLARED in this wave (the lockfile is frozen for
 * parallel lanes), so — exactly like oauth/flow.ts's @ovid/db loader — the
 * shared types are mirrored as local structural declarations
 * (member-for-member the shared schema; the test file pins them against the
 * real module) and the redis client is typed against the structural subset
 * below. The wave merger converts both to real imports when the deps are
 * declared.
 */

// ---------------------------------------------------------------------------
// @ovid/shared system.ts mirrors (wave-merger carry: convert to
// `import type { SystemEventKind, SystemEventEnvelope } from "@ovid/shared"`)
// ---------------------------------------------------------------------------

/** Mirrors @ovid/shared's SystemEventKind (member-for-member). */
export type SystemEventKind =
  | "mcp_sampling_approval"
  | "mcp_elicitation"
  | "plugin_grant_approval"
  | "plugin_install_progress"
  | "mcp_oauth_completed"
  | "mcp_oauth_failed";

/** Mirrors @ovid/shared's SystemEventEnvelope (member-for-member). */
interface SystemEventEnvelope {
  id: string;
  kind: SystemEventKind;
  requiresResponse: boolean;
  payload: Record<string, unknown>;
  ts: string;
}

// ---------------------------------------------------------------------------
// ioredis structural subset (wave-merger carry: convert to
// `import type { Redis } from "ioredis"` — a real client satisfies this).
// ---------------------------------------------------------------------------

/**
 * The redis surface the bus uses: publishing on the shared connection and
 * per-request DEDICATED subscribers (ioredis pub/sub mode blocks regular
 * commands, so the shared client cannot subscribe — Task 4 convention).
 */
interface SystemRedis {
  publish(channel: string, message: string): Promise<number>;
  duplicate(): SystemRedis;
  on(event: string, listener: (...args: never[]) => void): unknown;
  off(event: string, listener: (...args: never[]) => void): unknown;
  subscribe(channel: string): Promise<number>;
  quit(): Promise<unknown>;
  disconnect(): void;
}

// ---------------------------------------------------------------------------
// UUIDv7 (dependency-free): 48-bit unix_ts_ms + ver 7 + rand_a + var 10 +
// rand_b — time-ordered, lexicographically sortable like the DB ids.
// ---------------------------------------------------------------------------

function uuidv7(): string {
  const buf = Buffer.alloc(16);
  buf.writeUIntBE(Date.now(), 0, 6);
  const rnd = randomBytes(10); // 74 random bits used
  buf[6] = 0x70 | (rnd[0]! & 0x0f); // version 7 + rand_a high nibble
  buf[7] = rnd[1]!; // rand_a low byte
  buf[8] = 0x80 | (rnd[2]! & 0x3f); // variant 10 + rand_b top 6 bits
  rnd.copy(buf, 9, 3, 10); // rand_b remaining 56 bits
  const hex = buf.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

// Channel naming — the gateway hub's sysOutChannel/sysInChannel contract.
function sysOutChannel(uid: string): string {
  return `sys:${uid}:out`;
}
function sysInChannel(uid: string): string {
  return `sys:${uid}:in`;
}

// The worker-bound response on sys:{uid}:in (brief Produces: exported —
// request()'s callers type their result with it).
export interface SystemResponse {
  id: string;
  payload: Record<string, unknown>;
}

const systemResponseSchema = z.object({
  id: z.string().min(1),
  payload: z.record(z.string(), z.unknown()),
});

/** One in-flight request(): its settle + its dedicated sys:{uid}:in subscriber. */
interface PendingRequest {
  id: string;
  settle(response: SystemResponse | null): void;
  stop(): Promise<void>;
}

export interface UserSystemBus {
  /**
   * Fire-and-forget event. Fills `ts`, defaults `requiresResponse` false and
   * generates the `id` when absent — the runtime is deliberately forgiving
   * so the T9 OAuth flow's narrow structural SystemEventPublisher callers
   * ({kind, payload} only) keep working (F9 ruling: that publisher is a
   * structural subset of THIS interface, declared once here).
   */
  publish(uid: string, event: Omit<SystemEventEnvelope, "ts"> & { ts?: string }): Promise<void>;
  /**
   * Publishes {id, kind, requiresResponse: true, payload} on sys:{uid}:out
   * and resolves with the matching {id, payload} from sys:{uid}:in; a
   * timeout resolves null and the CALLER treats null as deny (§6.2).
   * ids are UUIDv7 (injectable for tests).
   */
  request(
    uid: string,
    kind: SystemEventKind,
    payload: Record<string, unknown>,
    opts?: { timeoutMs?: number },
  ): Promise<SystemResponse | null>;
  /**
   * Quits every pending request's subscriber and resolves them all as null
   * (pending approvals DENY on shutdown). Idempotent; later ops reject.
   */
  close(): Promise<void>;
}

/** Spec §6.2: unanswered approvals default-deny after 120 s. */
export const APPROVAL_TIMEOUT_MS = 120_000;

export function createRedisSystemBus(
  redis: SystemRedis,
  opts: { idGen?: () => string } = {},
): UserSystemBus {
  const idGen = opts.idGen ?? uuidv7;
  const pending = new Set<PendingRequest>();
  let closed = false;

  function assertOpen(): void {
    if (closed) throw new Error("system bus is closed");
  }

  return {
    async publish(uid, event) {
      assertOpen();
      const envelope = {
        // `??` looks dead to the declared types on purpose: the T9 callers
        // pass neither id nor requiresResponse (see the interface doc).
        id: event.id ?? idGen(),
        kind: event.kind,
        requiresResponse: event.requiresResponse ?? false,
        payload: event.payload,
        ts: event.ts ?? new Date().toISOString(),
      };
      await redis.publish(sysOutChannel(uid), JSON.stringify(envelope));
    },

    request(uid, kind, payload, reqOpts) {
      assertOpen();
      const timeoutMs = reqOpts?.timeoutMs ?? APPROVAL_TIMEOUT_MS;
      const id = idGen();
      const channel = sysInChannel(uid);

      return new Promise<SystemResponse | null>((resolve, reject) => {
        // One DEDICATED subscriber per pending request (builder's choice per
        // the brief; each subscribe owns its connection — P1 convention).
        // The listener is attached and the SUBSCRIBE acked BEFORE the
        // request is published, so a reply racing the subscribe can never
        // be missed (wsPty rule). Mismatched ids on the shared channel are
        // ignored — other pending requests own those ids.
        const sub = redis.duplicate();
        sub.on("error", () => {}); // ioredis reconnects on its own
        let settled = false;
        const listener = (ch: string, message: string): void => {
          if (ch !== channel) return;
          let parsed: { id: string; payload: Record<string, unknown> };
          try {
            parsed = systemResponseSchema.parse(JSON.parse(message));
          } catch {
            return; // garbage or off-contract on the channel: skip
          }
          if (parsed.id !== id) return; // another request's reply
          settle({ id, payload: parsed.payload });
        };

        // Detach first so no message can be delivered mid-teardown.
        const cleanup = (): void => {
          clearTimeout(timer);
          pending.delete(entry);
          sub.off("message", listener);
          void sub.quit().catch(() => {
            sub.disconnect();
          });
        };

        /** Response, timeout (→ null, the caller treats it as deny), or close. */
        const settle = (result: SystemResponse | null): void => {
          if (settled) return;
          settled = true;
          cleanup();
          resolve(result);
        };
        /** Infra failure BEFORE the request is published (loud, not deny). */
        const fail = (err: unknown): void => {
          if (settled) return;
          settled = true;
          cleanup();
          reject(err instanceof Error ? err : new Error(String(err)));
        };

        const timer = setTimeout(() => settle(null), timeoutMs);
        timer.unref?.(); // never hold the process (or a test runner) open

        const entry: PendingRequest = {
          id,
          settle,
          stop: async () => {
            settle(null); // close(): pending requests DENY on shutdown
          },
        };
        pending.add(entry);

        sub.on("message", listener);
        void sub
          .subscribe(channel) // resolves once redis acknowledges
          .then(() =>
            // Only NOW publish the request itself: the reply channel is
            // live, so the answer can never land before we listen.
            redis.publish(
              sysOutChannel(uid),
              JSON.stringify({
                id,
                kind,
                requiresResponse: true,
                payload,
                ts: new Date().toISOString(),
              }),
            ),
          )
          .catch(fail);
      });
    },

    async close() {
      if (closed) return;
      closed = true;
      const all = [...pending];
      pending.clear();
      await Promise.all(all.map((p) => p.stop()));
    },
  };
}
