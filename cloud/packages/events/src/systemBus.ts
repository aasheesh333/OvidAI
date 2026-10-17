import type { Redis } from "ioredis";
import { systemEventSchema, type SystemEvent } from "@ovid/shared";

/**
 * P4 Task 6 — the per-user system event bus (scheduler notifications).
 *
 * The scheduler (worker side) PUBLISHes SystemEvents on `user:{uid}:system`;
 * the gateway subscribes one dedicated connection per uid and fans events out
 * to that user's sockets as the WS `system` op (the schedule SystemEvent of
 * @ovid/shared's schedules.ts — NOT the P5 SystemEventEnvelope, which rides
 * the separate sys:{uid}:out channel).
 *
 * Connection/teardown discipline is copied from eventLog.subscribe (Task 4):
 * pub/sub mode blocks regular commands, so every subscriber gets a dedicated
 * duplicate() connection; ioredis keeps reconnecting on its own, so listener
 * connection errors are swallowed; unsubscribe detaches first and quits.
 */
export interface SystemBus {
  /** PUBLISH the event as JSON on the user's system channel. */
  publish(uid: string, event: SystemEvent): Promise<void>;

  /**
   * SUBSCRIBE the user's channel on a dedicated duplicate() connection;
   * resolves once redis acknowledges. Returns the unsubscribe function.
   */
  subscribe(
    uid: string,
    onEvent: (e: SystemEvent) => void,
  ): Promise<() => Promise<void>>;
}

const systemChannel = (uid: string): string => `user:${uid}:system`;

export function createRedisSystemBus(redis: Redis): SystemBus {
  return {
    async publish(uid, event) {
      await redis.publish(systemChannel(uid), JSON.stringify(event));
    },

    async subscribe(uid, onEvent) {
      // Dedicated connection: ioredis pub/sub mode blocks regular commands,
      // so the shared client cannot be used here (eventLog convention).
      const sub = redis.duplicate();
      // An unhandled "error" event would crash the process; ioredis keeps
      // reconnecting on its own, so transient errors are swallowed here.
      sub.on("error", () => {});
      const channel = systemChannel(uid);
      const listener = (_ch: string, message: string): void => {
        // Hardening (same ruling as eventLog.subscribe): this runs inside an
        // EventEmitter listener — an exception thrown here escapes as an
        // uncaughtException and kills the host process (gateway/worker).
        // Garbage on the channel is skipped (JSON gate + schema gate); a
        // throwing consumer loses that one event but the listener survives
        // for the next.
        let raw: unknown;
        try {
          raw = JSON.parse(message);
        } catch {
          return; // not even JSON: skip, keep listening
        }
        // Valid JSON that is not a SystemEvent is skipped too — the wire
        // contract is systemEventSchema, not "whatever parses as JSON".
        const parsed = systemEventSchema.safeParse(raw);
        if (!parsed.success) {
          return; // off-contract payload: skip, keep listening
        }
        try {
          onEvent(parsed.data);
        } catch {
          // consumer bug: contained — never fatal to the pub/sub connection
        }
      };
      sub.on("message", listener);
      try {
        await sub.subscribe(channel); // resolves once redis acknowledges
      } catch (err) {
        await sub.quit().catch(() => {}); // don't leak the connection on failure
        throw err;
      }

      let closed = false;
      return async () => {
        if (closed) return;
        closed = true;
        // Detach first so no message can be delivered mid-teardown.
        sub.off("message", listener);
        await sub.quit().catch(() => {});
      };
    },
  };
}
