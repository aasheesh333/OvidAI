import type { Redis } from "ioredis";
import {
  PTY_CTL_PATTERN,
  PTY_HEARTBEAT_MS,
  PTY_REGISTRY_TTL_MS,
  PTY_WIRE_MAX_BYTES,
  parsePtyCtlMsg,
  ptyOutChannel,
  ptyRegistryKey,
  type PtyCtlMsg,
  type PtyOutMsg,
  type PtyReplyMsg,
  type RingChunkWire,
} from "@ovid/shared";
import {
  RootfsUnavailable,
  SandboxAdmissionError,
  SandboxCapacityError,
  type PtySession,
  type RingChunk,
  type SandboxHandle,
  type SandboxManager,
} from "@ovid/sandbox";

/**
 * Worker-side terminal bridge (P2 Task 13): PSUBSCRIBEs `pty:ctl:*` on the
 * queue Redis and serves the gateway's pty requests against the
 * SandboxManager. `open` attaches the user's sandbox (admission/capacity
 * errors map to the pinned wire codes), creates a PTY session whose
 * onData/onExit handlers publish to `pty:out:{ptyId}`, registers the pty in
 * the `pty:reg:{ptyId}` HASH (TTL + heartbeat), then acks. `attach` replays
 * `ring.since(lastOffset)`.
 *
 * The bridge deliberately does NOT kill ptys on stop(): the worker's shutdown
 * order is stop-bridge → manager.close(), and the manager's env teardown
 * kills every live pty leaf (each onExit publishes `exit` + HDELs the
 * registry).
 */

export interface WorkerPtyDeps {
  sandbox: SandboxManager;
  redis: Redis;
}

interface LivePty {
  userId: string;
  sessionId: string;
  session: PtySession;
}

const CTL_PREFIX = "pty:ctl:";

/**
 * Splits a ring chunk into wire chunks of at most PTY_WIRE_MAX_BYTES decoded
 * bytes each (ring chunks can be up to 64 KiB; the wire cap is 16 KiB —
 * offsets stay contiguous, so the stream reassembles losslessly).
 */
function wireChunks(chunk: RingChunk): RingChunkWire[] {
  const buf = Buffer.from(chunk.data, "base64");
  if (buf.length === 0) return [{ offset: chunk.offset, data: "" }];
  const out: RingChunkWire[] = [];
  for (let pos = 0; pos < buf.length; pos += PTY_WIRE_MAX_BYTES) {
    out.push({
      offset: chunk.offset + pos,
      data: buf.subarray(pos, pos + PTY_WIRE_MAX_BYTES).toString("base64"),
    });
  }
  return out;
}

export function startWorkerPtyBridge(
  deps: WorkerPtyDeps,
  opts: { ttlMs?: number; heartbeatMs?: number } = {},
): Promise<() => Promise<void>> {
  const { sandbox, redis } = deps;
  const ttlMs = opts.ttlMs ?? PTY_REGISTRY_TTL_MS;
  const heartbeatMs = opts.heartbeatMs ?? PTY_HEARTBEAT_MS;

  /** ptyId → live session (the gateway's ptyId is the routing key; the
   * PtySession's own id is internal to the sandbox manager). */
  const live = new Map<string, LivePty>();

  const publishOut = (ptyId: string, m: PtyOutMsg): void => {
    void redis.publish(ptyOutChannel(ptyId), JSON.stringify(m)).catch(() => {});
  };

  const reply = async (replyChannel: string, m: PtyReplyMsg): Promise<void> => {
    await redis.publish(replyChannel, JSON.stringify(m)).catch(() => {});
  };

  async function openPty(msg: Extract<PtyCtlMsg, { type: "open" }>): Promise<void> {
    const { ptyId, replyChannel } = msg;
    const openedFailed = (
      code: "sandbox_busy" | "sandbox_unavailable" | "internal",
      err: unknown,
    ): Promise<void> =>
      reply(replyChannel, {
        type: "opened_failed",
        ptyId,
        code,
        message: err instanceof Error ? err.message : String(err),
      });

    let handle: SandboxHandle;
    try {
      handle = await sandbox.attach(msg.userId);
    } catch (err) {
      if (err instanceof SandboxAdmissionError) return openedFailed("sandbox_busy", err);
      if (err instanceof SandboxCapacityError || err instanceof RootfsUnavailable) {
        return openedFailed("sandbox_unavailable", err);
      }
      return openedFailed("internal", err);
    }

    let session: PtySession;
    try {
      session = await handle.createPty(
        { sessionId: msg.sessionId, cols: msg.cols, rows: msg.rows },
        {
          onData: (chunk) => {
            for (const wire of wireChunks(chunk)) {
              publishOut(ptyId, { type: "output", ptyId, offset: wire.offset, data: wire.data });
            }
          },
          onExit: (exitCode) => {
            live.delete(ptyId);
            publishOut(ptyId, { type: "exit", ptyId, exitCode });
            void redis.hdel(ptyRegistryKey(ptyId)).catch(() => {});
          },
        },
      );
    } catch (err) {
      return openedFailed("internal", err);
    }
    if (!session.alive) {
      // Exited between spawn and here — its onExit already ran (registry HDEL,
      // exit publish). Report the open as failed; nothing was registered.
      return openedFailed("internal", new Error("pty exited during open"));
    }

    live.set(ptyId, { userId: msg.userId, sessionId: msg.sessionId, session });
    await redis.hset(ptyRegistryKey(ptyId), {
      userId: msg.userId,
      sessionId: msg.sessionId,
      cols: String(msg.cols),
      rows: String(msg.rows),
      createdAt: new Date().toISOString(),
    });
    await redis.pexpire(ptyRegistryKey(ptyId), ttlMs);
    await reply(replyChannel, { type: "opened", ptyId, sessionId: msg.sessionId });
  }

  async function attachPty(msg: Extract<PtyCtlMsg, { type: "attach" }>): Promise<void> {
    const { ptyId, replyChannel } = msg;
    const lp = live.get(ptyId);
    const registryExists = (await redis.exists(ptyRegistryKey(ptyId))) === 1;
    if (lp === undefined || !registryExists) {
      // Registry TTL-lapsed OR the pty exited and HDEL'd itself.
      await reply(replyChannel, {
        type: "attach_failed",
        ptyId,
        code: "pty_gone",
        message: "terminal no longer exists",
      });
      return;
    }
    // Snapshot the ring; the gateway bridge dedupes live chunks against this
    // endOffset (Review Focus #3).
    const since = lp.session.ring.since(msg.lastOffset);
    const chunks = since.chunks.flatMap((c) => wireChunks(c));
    await reply(replyChannel, {
      type: "attach_reply",
      ptyId,
      truncated: since.truncated,
      chunks,
      endOffset: since.endOffset,
    });
  }

  function controlPty(
    msg:
      | Extract<PtyCtlMsg, { type: "input" }>
      | Extract<PtyCtlMsg, { type: "resize" }>
      | Extract<PtyCtlMsg, { type: "close" }>,
  ): void {
    const lp = live.get(msg.ptyId);
    if (lp === undefined) return; // raced an exit — there is nothing to deliver to
    switch (msg.type) {
      case "input":
        lp.session.write(Buffer.from(msg.data, "base64"));
        return;
      case "resize":
        lp.session.resize(msg.cols, msg.rows);
        return;
      case "close":
        void lp.session.kill().catch(() => {});
        return;
    }
  }

  // PSUBSCRIBE on a DEDICATED connection (pub/sub mode blocks regular
  // commands; registry writes and publishes go over the shared client).
  const sub = redis.duplicate();
  sub.on("error", () => {});
  sub.on("pmessage", (_pattern: string, channel: string, message: string) => {
    if (!channel.startsWith(CTL_PREFIX)) return;
    let msg: PtyCtlMsg;
    try {
      msg = parsePtyCtlMsg(JSON.parse(message));
    } catch {
      return; // garbage on the channel: skip, keep listening
    }
    void (async () => {
      try {
        if (msg.type === "open") await openPty(msg);
        else if (msg.type === "attach") await attachPty(msg);
        else controlPty(msg);
      } catch (err) {
        console.error(`[pty-bridge] ctl ${msg.type} failed for ${msg.ptyId}:`, err);
      }
    })();
  });

  // Heartbeat: re-arm every live registry TTL, well inside its window.
  const heartbeat = setInterval(() => {
    for (const ptyId of live.keys()) {
      void redis.pexpire(ptyRegistryKey(ptyId), ttlMs).catch(() => {});
    }
  }, heartbeatMs);
  heartbeat.unref?.();

  let stopped = false;
  const stop = async (): Promise<void> => {
    if (stopped) return;
    stopped = true;
    clearInterval(heartbeat);
    sub.removeAllListeners("pmessage");
    try {
      await sub.punsubscribe(PTY_CTL_PATTERN);
    } catch {
      // connection already gone — quit() below still cleans up
    }
    await sub.quit().catch(() => {});
    // Live ptys are NOT killed here (see the module comment).
  };

  return (async () => {
    await sub.psubscribe(PTY_CTL_PATTERN);
    return stop;
  })();
}
