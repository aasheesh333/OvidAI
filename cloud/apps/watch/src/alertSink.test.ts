import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { describe, expect, it } from "vitest";
import { runSelfTest, sendAlert, type AlertSink } from "./alertSink.js";

/**
 * Review Focus #5 — the delivery path must be provable without sending a real
 * alert. Every case injects a fake fetch; the final pair uses a loopback HTTP
 * server so the proof covers the actual request/response cycle.
 */

function sink(overrides: Partial<AlertSink> = {}): AlertSink {
  return { log: () => {}, ...overrides };
}

function fakeFetch(
  calls: Array<{ url: string; init: RequestInit }>,
  status = 200,
): typeof fetch {
  return (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    return new Response(status === 200 ? '{"ok":true}' : "nope", { status });
  }) as typeof fetch;
}

describe("sendAlert", () => {
  it("POSTs mint's exact Telegram shape (bot URL, chat_id, text)", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    await sendAlert(
      sink({ telegram: { botToken: "123:abc", chatId: "42" } }),
      "hello",
      { fetchImpl: fakeFetch(calls) },
    );

    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe("https://api.telegram.org/bot123:abc/sendMessage");
    expect(calls[0].init.method).toBe("POST");
    expect(JSON.parse(String(calls[0].init.body))).toEqual({
      chat_id: "42",
      text: "hello",
    });
    expect(calls[0].init.signal).toBeInstanceOf(AbortSignal);
  });

  it("POSTs the optional webhook as {text}", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    await sendAlert(sink({ webhookUrl: "http://127.0.0.1:1/hook" }), "hello", {
      fetchImpl: fakeFetch(calls),
    });

    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe("http://127.0.0.1:1/hook");
    expect(JSON.parse(String(calls[0].init.body))).toEqual({ text: "hello" });
  });

  it("delivery failure throws (never swallowed) and is logged", async () => {
    const logs: string[] = [];
    await expect(
      sendAlert(
        sink({ webhookUrl: "http://127.0.0.1:1/hook", log: (l) => logs.push(l) }),
        "hello",
        { fetchImpl: fakeFetch([], 500) },
      ),
    ).rejects.toThrow(/HTTP 500/);
    expect(logs.some((l) => /failed/i.test(l))).toBe(true);
  });

  it("a network error throws and is logged", async () => {
    const logs: string[] = [];
    await expect(
      sendAlert(
        sink({
          webhookUrl: "http://127.0.0.1:1/hook",
          log: (l) => logs.push(l),
        }),
        "hello",
        {
          fetchImpl: (async () => {
            throw new Error("ECONNREFUSED");
          }) as typeof fetch,
        },
      ),
    ).rejects.toThrow(/ECONNREFUSED/);
    expect(logs.some((l) => /failed/i.test(l))).toBe(true);
  });

  it("throws when no sink is configured (a blind monitor is a failure)", async () => {
    await expect(sendAlert(sink(), "hello")).rejects.toThrow(/no alert sink/i);
  });

  it("delivers over a real loopback HTTP server (end-to-end request/response)", async () => {
    const received: string[] = [];
    const server = createServer((req: IncomingMessage, res: ServerResponse) => {
      let body = "";
      req.on("data", (chunk: Buffer) => {
        body += chunk.toString("utf8");
      });
      req.on("end", () => {
        received.push(body);
        res.writeHead(200, { "content-type": "application/json" });
        res.end("{}");
      });
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const port = (server.address() as AddressInfo).port;

    try {
      await sendAlert(sink({ webhookUrl: `http://127.0.0.1:${port}/hook` }), "delivered");
      expect(received).toHaveLength(1);
      expect(JSON.parse(received[0])).toEqual({ text: "delivered" });
    } finally {
      await new Promise<void>((resolve, reject) =>
        server.close((err) => (err ? reject(err) : resolve())),
      );
    }
  });
});

describe("runSelfTest (--self-test)", () => {
  it("sends the pinned TEST line and requires HTTP 200", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const text = await runSelfTest(
      sink({ webhookUrl: "http://127.0.0.1:1/hook" }),
      {
        fetchImpl: fakeFetch(calls),
        host: "box-1",
        now: new Date("2026-10-17T12:34:56.000Z"),
      },
    );

    expect(text).toBe(
      "TEST alert from ovid-cloud-watch on box-1 at 2026-10-17T12:34:56.000Z",
    );
    expect(JSON.parse(String(calls[0].init.body))).toEqual({ text });
  });

  it("throws (so the process exits nonzero) when delivery is not 200", async () => {
    await expect(
      runSelfTest(sink({ webhookUrl: "http://127.0.0.1:1/hook" }), {
        fetchImpl: fakeFetch([], 500),
      }),
    ).rejects.toThrow(/HTTP 500/);
  });
});
