import { gzipSync } from "node:zlib";
import { describe, expect, it } from "vitest";
import {
  readBoundedBody,
  readBoundedSse,
  type EgressLimits,
  type EgressResponse,
  type StreamLimits,
} from "./responseLimits.js";

function limits(patch: Partial<StreamLimits> = {}): StreamLimits {
  return {
    connectMs: 100,
    headersMs: 100,
    idleMs: 100,
    totalMs: 1_000,
    maxRedirects: 0,
    headerBytes: 1_024,
    responseBytes: 1_024,
    decompressedBytes: 2_048,
    sseEventBytes: 1_024,
    sseEventCount: 8,
    jsonRpcFrameBytes: 1_024,
    aggregateStreamBytes: 4_096,
    toolResultBytes: 1_024,
    ...patch,
  };
}

function response(
  chunks: readonly Uint8Array[],
  options: {
    headers?: Record<string, string>;
    onCancel?: () => void;
    holdOpen?: boolean;
  } = {},
): EgressResponse {
  let index = 0;
  const body = new ReadableStream<Uint8Array>({
    async pull(controller) {
      if (index < chunks.length) {
        controller.enqueue(chunks[index++]);
        return;
      }
      if (options.holdOpen) return;
      controller.close();
    },
    cancel() {
      options.onCancel?.();
    },
  });
  return {
    status: 200,
    headers: new Headers(options.headers),
    body,
    origin: new URL("https://provider.example"),
    remoteAddress: "192.0.2.1",
  };
}

const bytes = (value: string): Uint8Array => new TextEncoder().encode(value);

async function expectLimit(promise: Promise<unknown>, code: RegExp): Promise<void> {
  await expect(promise).rejects.toThrow(code);
}

describe("readBoundedBody", () => {
  it("returns bytes only after declared and actual caps hold", async () => {
    const result = await readBoundedBody(
      response([bytes("hel"), bytes("lo")], { headers: { "content-length": "5" } }),
      limits(),
    );
    expect(new TextDecoder().decode(result)).toBe("hello");
  });

  it("rejects an oversized declared length and cancels before reading", async () => {
    let cancelled = 0;
    const res = response([bytes("too much")], {
      headers: { "content-length": "100" },
      onCancel: () => cancelled++,
    });
    await expectLimit(readBoundedBody(res, limits({ responseBytes: 8 })), /response_bytes/);
    expect(cancelled).toBe(1);
  });

  it("rejects actual overflow despite a small or absent declared length and cancels", async () => {
    for (const declared of [undefined, "1"]) {
      let cancelled = 0;
      const res = response([bytes("1234"), bytes("5678")], {
        headers: declared === undefined ? {} : { "content-length": declared },
        holdOpen: true,
        onCancel: () => cancelled++,
      });
      await expectLimit(readBoundedBody(res, limits({ responseBytes: 6 })), /response_bytes/);
      expect(cancelled).toBe(1);
    }
  });

  it("enforces the aggregate header cap and cancels the body", async () => {
    let cancelled = 0;
    const res = response([bytes("ok")], {
      headers: { "x-provider-payload": "s".repeat(200) },
      onCancel: () => cancelled++,
    });
    await expectLimit(readBoundedBody(res, limits({ headerBytes: 32 })), /header_bytes/);
    expect(cancelled).toBe(1);
  });

  it("times out an idle chunk and cancels its reader", async () => {
    let cancelled = 0;
    const res = response([bytes("first")], {
      holdOpen: true,
      onCancel: () => cancelled++,
    });
    await expectLimit(
      readBoundedBody(res, limits({ idleMs: 20, totalMs: 500 })),
      /idle_timeout/,
    );
    expect(cancelled).toBe(1);
  });

  it("enforces the total deadline across otherwise active chunks", async () => {
    let cancelled = 0;
    const res = response(
      Array.from({ length: 100 }, () => bytes("x")),
      { holdOpen: true, onCancel: () => cancelled++ },
    );
    // Each pull yields immediately; a non-yielding final read exceeds totalMs.
    const originalPull = res.body.getReader;
    void originalPull;
    await expectLimit(
      readBoundedBody(res, limits({ idleMs: 500, totalMs: 20 })),
      /total_timeout/,
    );
    expect(cancelled).toBe(1);
  });

  it("caps compressed bytes independently of decompressed bytes", async () => {
    const compressed = gzipSync(bytes("a".repeat(1_000)));
    let cancelled = 0;
    const res = response([compressed], {
      headers: { "content-encoding": "gzip" },
      holdOpen: true,
      onCancel: () => cancelled++,
    });
    await expectLimit(
      readBoundedBody(res, limits({ responseBytes: 8, decompressedBytes: 2_000 })),
      /response_bytes/,
    );
    expect(cancelled).toBe(1);
  });

  it("caps decompressed output and cancels on a compression bomb", async () => {
    const compressed = gzipSync(bytes("a".repeat(10_000)));
    let cancelled = 0;
    const res = response([compressed], {
      headers: { "content-encoding": "gzip" },
      holdOpen: true,
      onCancel: () => cancelled++,
    });
    await expectLimit(
      readBoundedBody(res, limits({ responseBytes: 1_024, decompressedBytes: 64 })),
      /decompressed_bytes/,
    );
    expect(cancelled).toBe(1);
  });

  it("applies the decompressed cap before zlib can queue a large bomb", async () => {
    const compressed = gzipSync(bytes("a".repeat(16 * 1024 * 1024)));
    let cancelled = 0;
    const res = response([compressed], {
      headers: { "content-encoding": "gzip" },
      holdOpen: true,
      onCancel: () => cancelled++,
    });
    const before = process.memoryUsage().arrayBuffers;
    await expectLimit(
      readBoundedBody(
        res,
        limits({ responseBytes: 1_000_000, decompressedBytes: 32_768, idleMs: 1_000, totalMs: 5_000 }),
      ),
      /decompressed_bytes/,
    );
    const retainedOutput = process.memoryUsage().arrayBuffers - before;
    // The old data-listener queued the entire 16 MiB expansion before the
    // consumer saw its first chunk. A bounded streaming decoder stays below
    // 512 KiB even before GC has a chance to run.
    expect(retainedOutput).toBeLessThan(512 * 1024);
    expect(cancelled).toBe(1);
  });

  it("decompresses within both caps before returning bytes", async () => {
    const result = await readBoundedBody(
      response([gzipSync(bytes('{"ok":true}'))], { headers: { "content-encoding": "gzip" } }),
      limits(),
    );
    expect(new TextDecoder().decode(result)).toBe('{"ok":true}');
  });
});

describe("readBoundedSse", () => {
  it("parses split SSE frames only within event, frame, count, and aggregate caps", async () => {
    const events: string[] = [];
    await readBoundedSse(
      response([bytes("data: {\"jsonrpc\":"), bytes('"2.0"}\n\ndata: second\n\n')]),
      limits(),
      (data) => events.push(data),
    );
    expect(events).toEqual(['{"jsonrpc":"2.0"}', "second"]);
  });

  it("rejects and cancels an unterminated oversized event", async () => {
    let cancelled = 0;
    const res = response([bytes("data: " + "x".repeat(100))], {
      holdOpen: true,
      onCancel: () => cancelled++,
    });
    await expectLimit(
      readBoundedSse(res, limits({ sseEventBytes: 16 }), () => {}),
      /sse_event_bytes/,
    );
    expect(cancelled).toBe(1);
  });

  it("rejects and cancels when the SSE event count overflows", async () => {
    let cancelled = 0;
    const res = response([bytes("data: one\n\ndata: two\n\n")], {
      holdOpen: true,
      onCancel: () => cancelled++,
    });
    await expectLimit(
      readBoundedSse(res, limits({ sseEventCount: 1 }), () => {}),
      /sse_event_count/,
    );
    expect(cancelled).toBe(1);
  });

  it("enforces the JSON-RPC frame cap before dispatch", async () => {
    const events: string[] = [];
    let cancelled = 0;
    const res = response([bytes('data: {"jsonrpc":"2.0","result":"secret"}\n\n')], {
      holdOpen: true,
      onCancel: () => cancelled++,
    });
    await expectLimit(
      readBoundedSse(res, limits({ jsonRpcFrameBytes: 16 }), (data) => events.push(data)),
      /jsonrpc_frame_bytes/,
    );
    expect(events).toEqual([]);
    expect(cancelled).toBe(1);
  });

  it("enforces aggregate stream bytes across small events", async () => {
    let cancelled = 0;
    const res = response([bytes("data: one\n\ndata: two\n\n")], {
      holdOpen: true,
      onCancel: () => cancelled++,
    });
    await expectLimit(
      readBoundedSse(res, limits({ aggregateStreamBytes: 12 }), () => {}),
      /aggregate_stream_bytes/,
    );
    expect(cancelled).toBe(1);
  });

  it("enforces decompressed aggregate bytes across compressed SSE events", async () => {
    let cancelled = 0;
    const compressed = gzipSync(bytes("data: one\n\ndata: two\n\n"));
    const res = response([compressed], {
      headers: { "content-encoding": "gzip" },
      holdOpen: true,
      onCancel: () => cancelled++,
    });
    await expectLimit(
      readBoundedSse(
        res,
        limits({ responseBytes: 1_024, decompressedBytes: 8, aggregateStreamBytes: 1_024 }),
        () => {},
      ),
      /aggregate_stream_bytes|decompressed_bytes/,
    );
    expect(cancelled).toBe(1);
  });

  it("cancels the reader when event processing fails", async () => {
    let cancelled = 0;
    const res = response([bytes("data: one\n\n")], { holdOpen: true, onCancel: () => cancelled++ });
    await expect(
      readBoundedSse(res, limits(), () => {
        throw new Error("consumer failed");
      }),
    ).rejects.toThrow("consumer failed");
    expect(cancelled).toBe(1);
  });
});

// Compile-time consumer contract: Task 2 will supply this narrow interface;
// these tests deliberately do not claim that DNS pinning exists yet.
const _egressLimitConsumer: EgressLimits = limits();
void _egressLimitConsumer;
