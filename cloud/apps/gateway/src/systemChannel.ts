import type { Redis } from "ioredis";
import { systemEventEnvelope, sysInChannel, sysOutChannel, type SystemEventEnvelope } from "@ovid/shared";

/**
 * Gateway system hub (P5 Task 10) — the ws dispatch's only view of the
 * system channel. The two redis channels (same QUEUE instance, transient
 * fire-and-forget payloads like the approval-responses channel):
 *
 *   sys:{uid}:out  — worker bus / gateway-originated (OAuth callback) →
 *                    this hub's per-uid subscription → that uid's sockets
 *                    as `system_event` ws frames.
 *   sys:{uid}:in   — sockets' `system_response` frames → the worker bus's
 *                    pending request (matched by envelope id).
 *
 * ONE shared subscription per uid across that uid's sockets: the first
 * attach opens a dedicated subscriber (ioredis pub/sub mode blocks regular
 * commands, so the shared client cannot be used — Task 4 convention), later
 * attaches reuse it, and the last detach tears it down. `attach` is
 * synchronous and returns the detach handle immediately; the SUBSCRIBE ack
 * lands asynchronously, and a detach racing it still quits the connection
 * (the settle is awaited inside, never left dangling).
 *
 * Listener discipline (P1): a malformed payload is skipped and a throwing
 * consumer loses only that one fan-out — never the subscription.
 */

/** One uid's fan-out group: every attached socket + the shared subscriber. */
interface HubEntry {
  sockets: Set<(e: SystemEventEnvelope) => void>;
  sub: Redis;
  listener: (channel: string, message: string) => void;
  /** Settles (always resolves) once the SUBSCRIBE is acked — or failed. */
  subscribed: Promise<void>;
}

export interface SystemHub {
  /**
   * Registers `send` as one of this uid's socket callbacks; the returned
   * detach removes it — the last detach releases the shared subscription.
   * Called right after the ticket verify, before any frame can arrive.
   */
  attach(uid: string, send: (e: SystemEventEnvelope) => void): () => void;
  /** Publishes a gateway-originated event (e.g. the OAuth callback) on sys:{uid}:out. */
  publishOut(uid: string, event: SystemEventEnvelope): Promise<void>;
  /** Forwards a client's system_response to the worker on sys:{uid}:in. */
  respond(uid: string, id: string, payload: Record<string, unknown>): Promise<void>;
  /** Tears down every per-uid subscription (app shutdown). Idempotent. */
  close(): Promise<void>;
}

export function createSystemHub(redis: Redis): SystemHub {
  const entries = new Map<string, HubEntry>();
  let closed = false;

  function assertOpen(): void {
    if (closed) throw new Error("system hub is closed");
  }

  function fanout(uid: string, event: SystemEventEnvelope): void {
    const entry = entries.get(uid);
    if (entry === undefined) return; // released between publish and delivery
    for (const send of entry.sockets) {
      try {
        send(event);
      } catch {
        // one consumer bug must not kill the fan-out for the other sockets
      }
    }
  }

  /** Opens (or joins) the uid's shared subscription; returns the detach. */
  function attach(uid: string, send: (e: SystemEventEnvelope) => void): () => void {
    assertOpen();
    let entry = entries.get(uid);
    if (entry === undefined) {
      // FIRST socket for this uid: open the shared subscription. The
      // listener is attached before the SUBSCRIBE is issued, so a message
      // arriving in the same tick as the ack is never missed (wsPty rule).
      const sub = redis.duplicate();
      sub.on("error", () => {}); // ioredis reconnects on its own
      const listener = (ch: string, message: string): void => {
        if (ch !== sysOutChannel(uid)) return;
        let event: SystemEventEnvelope;
        try {
          event = systemEventEnvelope(JSON.parse(message));
        } catch {
          return; // garbage on the channel: skip, keep listening
        }
        fanout(uid, event);
      };
      sub.on("message", listener);
      entry = {
        sockets: new Set(),
        sub,
        listener,
        // The promise NEVER rejects outward: a failed subscribe self-cleans
        // the entry (so a later attach retries) instead of surfacing as an
        // unhandled rejection inside a listener context.
        subscribed: sub.subscribe(sysOutChannel(uid)).then(
          () => {},
          (err: unknown) => {
            const current = entries.get(uid);
            if (current !== undefined && current === entry) {
              entries.delete(uid);
              current.sub.off("message", current.listener);
            }
            void sub.quit().catch(() => {});
            console.warn(
              `[systemHub] sys channel subscribe failed for uid ${uid}: ` +
                (err instanceof Error ? err.message : String(err)),
            );
          },
        ),
      };
      entries.set(uid, entry);
    }
    entry.sockets.add(send);

    let detached = false;
    return () => {
      if (detached) return;
      detached = true;
      const current = entries.get(uid);
      if (current === undefined) return; // already released (subscribe failed / closed)
      current.sockets.delete(send);
      if (current.sockets.size === 0) {
        // Last socket gone: release the shared subscription.
        entries.delete(uid);
        current.sub.off("message", current.listener);
        // Await the SUBSCRIBE settle so quit() is never issued while the
        // command is still in flight; a failed settle already quit the conn.
        void current.subscribed.then(
          () => subQuit(current),
          () => subQuit(current),
        );
      }
    };
  }

  async function subQuit(entry: HubEntry): Promise<void> {
    await entry.sub.quit().catch(() => {
      entry.sub.disconnect();
    });
  }

  return {
    attach,
    async publishOut(uid, event) {
      assertOpen();
      await redis.publish(sysOutChannel(uid), JSON.stringify(event));
    },
    async respond(uid, id, payload) {
      assertOpen();
      await redis.publish(sysInChannel(uid), JSON.stringify({ id, payload }));
    },
    async close() {
      if (closed) return;
      closed = true;
      const all = [...entries.values()];
      entries.clear();
      await Promise.all(
        all.map((entry) => {
          entry.sub.off("message", entry.listener);
          return entry.subscribed.then(
            () => subQuit(entry),
            () => subQuit(entry),
          );
        }),
      );
    },
  };
}
