import WebSocket from "ws";
import {
  sessionDtoSchema,
  wsServerMsg,
  type SendMessageResponse,
  type SessionEvent,
  type WsClientMsg,
  type WsServerMsg,
} from "@ovid/shared";

/**
 * Load-generator client: REST for session/message creation, WS for the event
 * stream. EVERY server frame is parsed through the shared `wsServerMsg`
 * schema, so client drift from the gateway's wire contract is impossible —
 * an off-contract frame is recorded as an invalid frame, never silently
 * accepted (Review Focus #2 relies on this honesty).
 */

export interface CreateLoadClientOptions {
  baseUrl: string;
  wsBase: string;
  uid: string;
  /** Only the test verifier is supported by the harness. Default "test". */
  authMode?: "test";
}

export interface LoadClient {
  createSession(): Promise<string>;
  sendMessage(sessionId: string, content: string): Promise<SendMessageResponse>;
  /**
   * Fetch a fresh single-use ticket, open a socket, subscribe, and resolve on
   * the `subscribed` ack. Calling it again (after `terminate()`) resumes from
   * `lastEventId` — the replay leg of the reconnect contract.
   */
  subscribe(sessionId: string, lastEventId: string | null): Promise<void>;
  readonly received: Array<{ event: SessionEvent; receivedAtMs: number }>;
  lastEventId(): string | null;
  /**
   * App-level backlog: frames the socket delivered but the harness has not
   * finished parsing/recording. Always 0 in a synchronous consumer; the
   * scenario samples it to prove the generator is never the bottleneck.
   */
  pendingFrames(): number;
  /** Abrupt teardown — no close handshake (mid-run reconnect). */
  terminate(): void;
  close(): Promise<void>;
  // Additive (documented) surface used by the scenario layer.
  readonly errors: Array<{ code: string; message: string; sessionId?: string }>;
  /** Per-frame parse+dispatch cost in ms — the harness's own latency floor. */
  dispatchLatenciesMs(): number[];
  /** Send an arbitrary client op (browser_attach, ping, …). */
  sendOp(op: WsClientMsg): void;
  /** Off-contract frames seen (a non-zero value fails the harness). */
  invalidFrames(): number;
}

const ACK_TIMEOUT_MS = 10_000;
const CLOSE_TIMEOUT_MS = 2_000;

export async function createLoadClient(opts: CreateLoadClientOptions): Promise<LoadClient> {
  const authMode = opts.authMode ?? "test";
  if (authMode !== "test") {
    throw new Error(`createLoadClient: unsupported authMode ${String(authMode)}`);
  }
  const authorization = `Bearer test:${opts.uid}`;
  const baseUrl = opts.baseUrl.replace(/\/+$/, "");
  const wsBase = opts.wsBase.replace(/\/+$/, "");

  let socket: WebSocket | null = null;
  let socketClosed: Promise<void> = Promise.resolve();
  const received: Array<{ event: SessionEvent; receivedAtMs: number }> = [];
  const errors: Array<{ code: string; message: string; sessionId?: string }> = [];
  const dispatch: number[] = [];
  let rawFrames = 0;
  let processedFrames = 0;
  let invalid = 0;

  async function api(path: string, init: RequestInit): Promise<{ status: number; body: unknown }> {
    const response = await fetch(`${baseUrl}${path}`, {
      ...init,
      headers: {
        authorization,
        ...(init.body === undefined ? {} : { "content-type": "application/json" }),
        ...(init.headers ?? {}),
      },
    });
    const text = await response.text();
    let body: unknown = null;
    if (text !== "") {
      try {
        body = JSON.parse(text);
      } catch {
        body = text;
      }
    }
    return { status: response.status, body };
  }

  function closeCurrentSocket(): Promise<void> {
    const current = socket;
    socket = null;
    if (current === null) return Promise.resolve();
    if (current.readyState === WebSocket.CLOSED) return Promise.resolve();
    const closed = new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        current.terminate();
        resolve();
      }, CLOSE_TIMEOUT_MS);
      current.once("close", () => {
        clearTimeout(timer);
        resolve();
      });
      current.close();
    });
    return closed;
  }

  const client: LoadClient = {
    received,
    errors,

    async createSession() {
      const res = await api("/cloud/v1/sessions", {
        method: "POST",
        body: JSON.stringify({}),
      });
      if (res.status !== 201) {
        throw new Error(`createSession: HTTP ${res.status} ${JSON.stringify(res.body)}`);
      }
      return sessionDtoSchema.parse(res.body).id;
    },

    async sendMessage(sessionId, content) {
      const res = await api(
        `/cloud/v1/sessions/${encodeURIComponent(sessionId)}/messages`,
        { method: "POST", body: JSON.stringify({ content }) },
      );
      if (res.status !== 202) {
        throw new Error(`sendMessage: HTTP ${res.status} ${JSON.stringify(res.body)}`);
      }
      const body = res.body as Partial<SendMessageResponse> | null;
      if (
        body === null ||
        typeof body.runId !== "string" ||
        typeof body.userMessageId !== "string" ||
        body.status !== "queued"
      ) {
        throw new Error(`sendMessage: off-contract response ${JSON.stringify(res.body)}`);
      }
      return body as SendMessageResponse;
    },

    async subscribe(sessionId, lastEventId) {
      await closeCurrentSocket();

      const ticketRes = await api("/cloud/v1/auth/ticket", {
        method: "POST",
        body: JSON.stringify({}),
      });
      if (ticketRes.status !== 200) {
        throw new Error(`ticket: HTTP ${ticketRes.status} ${JSON.stringify(ticketRes.body)}`);
      }
      const ticket = (ticketRes.body as { ticket?: unknown } | null)?.ticket;
      if (typeof ticket !== "string" || ticket === "") {
        throw new Error("ticket: no ticket minted");
      }

      const ws = new WebSocket(`${wsBase}?ticket=${encodeURIComponent(ticket)}`);
      socket = ws;
      let ackSettled = false;
      let resolveAck!: () => void;
      let rejectAck!: (err: Error) => void;
      const acked = new Promise<void>((resolve, reject) => {
        resolveAck = resolve;
        rejectAck = reject;
      });
      const ackTimer = setTimeout(() => {
        ackSettled = true;
        rejectAck(new Error("subscribe: ack timeout"));
      }, ACK_TIMEOUT_MS);

      ws.on("message", (data) => {
        const rawAt = performance.now();
        rawFrames += 1;
        try {
          let parsedJson: unknown;
          try {
            parsedJson = JSON.parse(data.toString());
          } catch {
            throw new Error("unparseable JSON frame");
          }
          const msg: WsServerMsg = wsServerMsg(parsedJson);
          if (msg.op === "event") {
            received.push({ event: msg.event, receivedAtMs: Date.now() });
            dispatch.push(performance.now() - rawAt);
          } else if (msg.op === "error") {
            errors.push({ code: msg.code, message: msg.message, sessionId: msg.sessionId });
            if (!ackSettled) {
              // An error before `subscribed` is a failed subscription, not a
              // 10-second timeout: surface it immediately.
              ackSettled = true;
              clearTimeout(ackTimer);
              rejectAck(new Error(`subscribe: ${msg.code}: ${msg.message}`));
            }
          } else if (msg.op === "subscribed") {
            ackSettled = true;
            clearTimeout(ackTimer);
            resolveAck();
          }
        } catch (err) {
          invalid += 1;
          const message = err instanceof Error ? err.message : String(err);
          errors.push({ code: "invalid_frame", message });
          if (!ackSettled) {
            ackSettled = true;
            clearTimeout(ackTimer);
            rejectAck(new Error(`subscribe: invalid frame: ${message}`));
          }
        } finally {
          processedFrames += 1;
        }
      });

      ws.on("error", (err) => {
        clearTimeout(ackTimer);
        ackSettled = true;
        rejectAck(err instanceof Error ? err : new Error(String(err)));
      });

      socketClosed = new Promise<void>((resolve) => {
        ws.once("close", () => {
          clearTimeout(ackTimer);
          if (!ackSettled) {
            ackSettled = true;
            rejectAck(new Error("subscribe: socket closed before ack"));
          }
          resolve();
        });
      });

      await new Promise<void>((resolve, reject) => {
        ws.once("open", () => {
          const subscribeMsg: WsClientMsg = { op: "subscribe", sessionId, lastEventId };
          ws.send(JSON.stringify(subscribeMsg));
          resolve();
        });
        ws.once("error", (err) => {
          reject(err instanceof Error ? err : new Error(String(err)));
        });
      });

      try {
        await acked;
      } catch (err) {
        clearTimeout(ackTimer);
        ws.terminate();
        throw err;
      }
    },

    lastEventId() {
      return received.length === 0 ? null : received[received.length - 1]!.event.seq;
    },

    pendingFrames() {
      // App-level backlog (frames delivered but not yet parsed/recorded) plus
      // a one-frame estimate for bytes still sitting in the TCP read buffer.
      // Both are sampled by the scenario; zero means the consumer keeps up.
      const transport = (socket as unknown as { _socket?: { readableLength?: number } } | null)
        ?._socket;
      const bufferedBytes =
        transport !== undefined && typeof transport.readableLength === "number"
          ? transport.readableLength
          : 0;
      return Math.max(0, rawFrames - processedFrames) + (bufferedBytes > 0 ? 1 : 0);
    },

    terminate() {
      socket?.terminate();
      socket = null;
    },

    async close() {
      await closeCurrentSocket();
      await socketClosed.catch(() => {});
    },

    dispatchLatenciesMs() {
      return [...dispatch];
    },

    sendOp(op) {
      if (socket !== null && socket.readyState === WebSocket.OPEN) {
        socket.send(JSON.stringify(op));
      }
    },

    invalidFrames() {
      return invalid;
    },
  };

  return client;
}
