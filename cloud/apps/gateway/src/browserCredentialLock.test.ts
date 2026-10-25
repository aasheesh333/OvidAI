import { EventEmitter } from "node:events";

import { describe, expect, it } from "vitest";
import type { Redis } from "ioredis";
import type { WebSocket } from "ws";
import {
  browserCtlChannel,
  browserFramesChannel,
  browserInputChannel,
  browserStateChannel,
  userBrowserKey,
  type BrowserStateDto,
} from "@ovid/shared";

import { handleWsConnection, type WsDeps } from "./ws.js";

class FakeRedis extends EventEmitter {
  readonly published: Array<{ channel: string; payload: Buffer | string }> = [];
  quitCalled = false;

  async subscribe(): Promise<number> {
    return 1;
  }

  async unsubscribe(): Promise<number> {
    return 1;
  }

  async quit(): Promise<string> {
    this.quitCalled = true;
    return "OK";
  }

  async publish(channel: string, payload: Buffer | string): Promise<number> {
    this.published.push({ channel, payload });
    return 1;
  }
}

class FakeSocket extends EventEmitter {
  readonly OPEN = 1;
  readonly CLOSED = 3;
  readyState = this.OPEN;
  bufferedAmount = 0;
  readonly sent: Array<string | Buffer> = [];

  send(data: string | Buffer): void {
    this.sent.push(data);
  }

  ping(): void {}

  close(): void {
    if (this.readyState === this.CLOSED) return;
    this.readyState = this.CLOSED;
    this.emit("close");
  }

  terminate(): void {
    this.close();
  }
}

async function waitFor(predicate: () => boolean, timeoutMs = 2_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (predicate()) return;
    if (Date.now() >= deadline) throw new Error("gateway credential-lock wait timed out");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

function state(key: string, credentialLock: boolean): BrowserStateDto & { credentialLock: boolean } {
  return {
    sessionId: key,
    live: true,
    url: null,
    title: null,
    takeover: false,
    screencast: !credentialLock,
    frameFormat: "jpeg",
    viewport: { width: 1280, height: 800 },
    tabs: [],
    activeTabIndex: 0,
    credentialLock,
  };
}

describe("gateway browser credential lock", () => {
  it("drops stale frames/input/takeover/tab switches until unlock, then accepts only fresh work", async () => {
    const socket = new FakeSocket();
    const connections: FakeRedis[] = [];
    const key = userBrowserKey("u1");
    const deps: WsDeps = {
      tickets: { verify: async () => ({ uid: "u1" }) } as never,
      events: {} as never,
      db: {} as never,
      pty: {} as never,
      browser: {
        redisFactory: () => {
          const connection = new FakeRedis();
          connections.push(connection);
          return connection as unknown as Redis;
        },
      },
    };
    try {
      await handleWsConnection(
        socket as unknown as WebSocket,
        new URL("http://gateway.invalid/cloud/ws?ticket=test"),
        deps,
        { pingIntervalMs: 60_000 },
      );
      socket.emit("message", Buffer.from(JSON.stringify({ op: "browser_attach", sessionId: "user" })));
      await waitFor(() => connections.length === 2 && connections[0]!.published.length === 1);
      const subscriber = connections[1]!;
      const publisher = connections[0]!;
      expect(publisher.published[0]!.channel).toBe(browserCtlChannel(key));

      subscriber.emit(
        "messageBuffer",
        Buffer.from(browserStateChannel(key)),
        Buffer.from(JSON.stringify(state(key, true))),
      );
      await waitFor(() => socket.sent.some((entry) => typeof entry === "string" && entry.includes("browser_state")));
      const lockedState = socket.sent
        .filter((entry): entry is string => typeof entry === "string")
        .map((entry) => JSON.parse(entry) as { op?: string; state?: { credentialLock?: boolean } })
        .find((entry) => entry.op === "browser_state");

      subscriber.emit("messageBuffer", Buffer.from(browserFramesChannel(key)), Buffer.from([1, 0xff, 0xd8, 1]));
      const ctlBefore = publisher.published.length;
      socket.emit("message", Buffer.from(JSON.stringify({
        op: "browser_input",
        sessionId: "user",
        input: { type: "tap", x: 10, y: 10 },
      })));
      socket.emit("message", Buffer.from(JSON.stringify({ op: "browser_takeover", sessionId: "user", enabled: true })));
      socket.emit("message", Buffer.from(JSON.stringify({ op: "browser_switch_tab", sessionId: "user", index: 0 })));
      await new Promise((resolve) => setTimeout(resolve, 50));
      const binaryDuringLock = socket.sent.filter((entry) => Buffer.isBuffer(entry)).length;
      const controlDuringLock = publisher.published.slice(ctlBefore);

      subscriber.emit(
        "messageBuffer",
        Buffer.from(browserStateChannel(key)),
        Buffer.from(JSON.stringify(state(key, false))),
      );
      subscriber.emit("messageBuffer", Buffer.from(browserFramesChannel(key)), Buffer.from([1, 0xff, 0xd8, 2]));
      socket.emit("message", Buffer.from(JSON.stringify({
        op: "browser_input",
        sessionId: "user",
        input: { type: "tap", x: 20, y: 20 },
      })));
      await waitFor(() => publisher.published.some((entry) => entry.channel === browserInputChannel(key)));
      const freshBytes = socket.sent.filter((entry): entry is Buffer => Buffer.isBuffer(entry));

      expect({
        advertisedLock: lockedState?.state?.credentialLock,
        binaryDuringLock,
        controlDuringLock: controlDuringLock.map((entry) => entry.channel),
        freshFrameBytes: freshBytes.map((entry) => [...entry]),
        inputResumed: publisher.published.some((entry) => entry.channel === browserInputChannel(key)),
      }).toEqual({
        advertisedLock: true,
        binaryDuringLock: 0,
        controlDuringLock: [],
        freshFrameBytes: [[0xff, 0xd8, 2]],
        inputResumed: true,
      });
    } finally {
      socket.close();
      await waitFor(() => connections.every((connection) => connection.quitCalled));
    }
  });
});
