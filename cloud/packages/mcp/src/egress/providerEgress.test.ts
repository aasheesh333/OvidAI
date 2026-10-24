import { describe, expect, it, vi } from "vitest";
import {
  createProviderEgress,
  type EgressLimits,
  type EgressRequest,
  type PinnedDispatchResponse,
  type PinnedDispatcher,
  type PinnedDispatcherFactory,
  type ProviderEgress,
} from "./providerEgress.js";
import { SsrfBlockedError } from "../ssrf.js";

const PUBLIC_V4 = "93.184.216.34";
const PUBLIC_V6 = "2606:4700::1111";
const SECRET = "egress-canary-/+?";

function testRedactor() {
  const clean = (value: string, secrets: readonly string[] = []): string => {
    let output = value;
    for (const secret of [...secrets, ...secrets.map(encodeURIComponent)]) {
      if (secret !== "") output = output.split(secret).join("[REDACTED]");
    }
    return output;
  };
  return {
    text: clean,
    error(error: unknown, secrets: readonly string[] = []): Error {
      return new Error(clean(error instanceof Error ? error.message : String(error), secrets));
    },
    json<T>(value: T, secrets: readonly string[] = []): T {
      return JSON.parse(clean(JSON.stringify(value), secrets)) as T;
    },
  };
}

function limits(patch: Partial<EgressLimits> = {}): EgressLimits {
  return {
    connectMs: 100,
    headersMs: 100,
    idleMs: 100,
    totalMs: 1_000,
    maxRedirects: 2,
    headerBytes: 1_024,
    responseBytes: 1_024,
    decompressedBytes: 2_048,
    ...patch,
  };
}

function request(patch: Partial<EgressRequest> = {}): EgressRequest {
  return {
    originKey: "provider",
    url: new URL("https://provider.test/v1/items"),
    method: "GET",
    headers: {},
    redirect: "same_origin",
    limits: limits(),
    ...patch,
  };
}

function dispatchResponse(patch: Partial<PinnedDispatchResponse> = {}): PinnedDispatchResponse {
  return {
    status: 200,
    headers: new Headers(),
    body: new Response("ok").body!,
    remoteAddress: PUBLIC_V4,
    ...patch,
  };
}

function fakeDispatcher(
  dispatch: PinnedDispatcher["dispatch"] = async () => dispatchResponse(),
): PinnedDispatcher {
  return { dispatch, close: vi.fn(async () => {}) };
}

function providerHarness(
  factory: PinnedDispatcherFactory,
  resolver: (host: string) => Promise<string[]> = async () => [PUBLIC_V4],
) {
  const egress = createProviderEgress({
    origins: { provider: [new URL("https://provider.test")] },
    resolver,
    dispatcherFactory: factory,
    redactor: testRedactor(),
    production: false,
  });
  return egress;
}

describe("ProviderEgress pinned transport", () => {
  it("pins DNS and TLS hostname without a second lookup", async () => {
    const resolver = vi.fn(async (_host: string) => [PUBLIC_V4, PUBLIC_V6]);
    const lookups: string[][] = [];
    const servernames: string[] = [];
    const factory: PinnedDispatcherFactory = (options) => {
      servernames.push(options.servername);
      return fakeDispatcher(async () => {
        const addresses = await new Promise<string[]>((resolve, reject) => {
          options.lookup(options.origin.hostname, { all: true }, (error, value) => {
            if (error) reject(error);
            else resolve((value as Array<{ address: string }>).map((entry) => entry.address));
          });
        });
        lookups.push(addresses);
        return dispatchResponse({ remoteAddress: PUBLIC_V6 });
      });
    };
    const egress = providerHarness(factory, resolver);

    const response = await egress.request(request());

    expect(response.status).toBe(200);
    expect(response.remoteAddress).toBe(PUBLIC_V6);
    expect(response.origin.origin).toBe("https://provider.test");
    expect(resolver).toHaveBeenCalledTimes(1);
    expect(resolver).toHaveBeenCalledWith("provider.test");
    expect(lookups).toEqual([[PUBLIC_V4, PUBLIC_V6]]);
    expect(servernames).toEqual(["provider.test"]);
    await egress.close();
  });

  it("re-resolves and rejects a rebound private answer on a same-origin redirect", async () => {
    let resolutions = 0;
    const resolver = vi.fn(async (_host: string) => {
      resolutions++;
      return resolutions === 1 ? [PUBLIC_V4] : [PUBLIC_V4, "127.0.0.1"];
    });
    const factory = vi.fn(() =>
      fakeDispatcher(async () =>
        dispatchResponse({
          status: 302,
          headers: new Headers({ location: "/next" }),
          body: new Response("redirect").body!,
        }),
      ),
    );
    const egress = providerHarness(factory, resolver);

    await expect(egress.request(request())).rejects.toThrow(SsrfBlockedError);
    expect(resolver).toHaveBeenCalledTimes(2);
    expect(factory).toHaveBeenCalledTimes(1);
    await egress.close();
  });

  it("refuses a dispatcher whose connected remote is outside the checked set", async () => {
    let cancelled = 0;
    const body = new ReadableStream<Uint8Array>({ cancel: () => { cancelled++; } });
    const factory: PinnedDispatcherFactory = () =>
      fakeDispatcher(async () => dispatchResponse({ body, remoteAddress: "10.0.0.8" }));
    const egress = providerHarness(factory);

    await expect(egress.request(request())).rejects.toThrow(/remote_address/);
    expect(cancelled).toBe(1);
    await egress.close();
  });

  it("enforces aggregate headers and declared length before returning a body", async () => {
    for (const headers of [
      new Headers({ "x-large": "x".repeat(100) }),
      new Headers({ "content-length": "101" }),
    ]) {
      let cancelled = 0;
      const body = new ReadableStream<Uint8Array>({ cancel: () => { cancelled++; } });
      const egress = providerHarness(() =>
        fakeDispatcher(async () => dispatchResponse({ headers, body })),
      );
      await expect(
        egress.request(request({ limits: limits({ headerBytes: 32, responseBytes: 100 }) })),
      ).rejects.toThrow(/header_bytes|response_bytes/);
      expect(cancelled).toBe(1);
      await egress.close();
    }
  });

  it("cancels an actual streaming overflow even without a declared length", async () => {
    let cancelled = 0;
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array(9));
      },
      cancel: () => { cancelled++; },
    });
    const egress = providerHarness(() => fakeDispatcher(async () => dispatchResponse({ body })));

    const response = await egress.request(request({ limits: limits({ responseBytes: 8 }) }));
    await expect(response.body.getReader().read()).rejects.toThrow(/response_bytes/);
    expect(cancelled).toBe(1);
    await egress.close();
  });

  it("applies the headers deadline even when a dispatcher never answers", async () => {
    const egress = providerHarness(
      () => fakeDispatcher(() => new Promise<PinnedDispatchResponse>(() => {})),
    );

    await expect(
      egress.request(request({ limits: limits({ headersMs: 20, totalMs: 500 }) })),
    ).rejects.toThrow(/headers_timeout/);
    await egress.close();
  });

  it("bounds unresolved DNS by the total deadline and external cancellation", async () => {
    for (const kind of ["total", "abort"] as const) {
      const controller = new AbortController();
      const factory = vi.fn(() => fakeDispatcher());
      const egress = providerHarness(factory, () => new Promise<string[]>(() => {}));
      const pending = egress.request(
        request({
          signal: kind === "abort" ? controller.signal : undefined,
          limits: limits({ totalMs: kind === "total" ? 20 : 500 }),
        }),
      );
      const guarded = Promise.race([
        pending,
        new Promise<never>((_resolve, reject) => {
          setTimeout(() => reject(new Error("deadline was not enforced")), 100);
        }),
      ]);
      if (kind === "abort") controller.abort();
      await expect(guarded).rejects.toThrow(kind === "total" ? /total_timeout/ : /abort/i);
      expect(factory).not.toHaveBeenCalled();
      await egress.close();
    }
  });

  it("keeps the total deadline and external cancellation active while awaiting headers", async () => {
    for (const kind of ["total", "abort"] as const) {
      const controller = new AbortController();
      const egress = providerHarness(
        () =>
          fakeDispatcher(
            (input) =>
              new Promise<PinnedDispatchResponse>((_resolve, reject) => {
                input.signal.addEventListener("abort", () => reject(input.signal.reason), { once: true });
              }),
          ),
      );
      const pending = egress.request(
        request({
          signal: kind === "abort" ? controller.signal : undefined,
          limits: limits({ headersMs: 500, totalMs: kind === "total" ? 20 : 500 }),
        }),
      );
      if (kind === "abort") controller.abort();
      await expect(pending).rejects.toThrow(kind === "total" ? /total_timeout/ : /abort/i);
      await egress.close();
    }
  });

  it("enforces idle and total deadlines between body chunks", async () => {
    for (const kind of ["idle", "total"] as const) {
      const body = new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(new Uint8Array([1]));
        },
      });
      const egress = providerHarness(() => fakeDispatcher(async () => dispatchResponse({ body })));
      const response = await egress.request(
        request({
          limits: limits({
            idleMs: kind === "idle" ? 20 : 500,
            totalMs: kind === "total" ? 40 : 500,
          }),
        }),
      );
      const reader = response.body.getReader();
      expect(await reader.read()).toEqual({ done: false, value: new Uint8Array([1]) });
      await expect(reader.read()).rejects.toThrow(kind === "idle" ? /idle_timeout/ : /total_timeout/);
      await egress.close();
    }
  });

  it("redacts transport failures and their encoded secret forms", async () => {
    const egress = providerHarness(
      () =>
        fakeDispatcher(async () => {
          throw new Error(`provider failed ${SECRET} ${encodeURIComponent(SECRET)}`);
        }),
    );

    const failure = await egress.request(request({ secretValues: [SECRET] })).catch((error: unknown) => error);
    expect(failure).toBeInstanceOf(Error);
    expect((failure as Error).message).not.toContain(SECRET);
    expect((failure as Error).message).not.toContain(encodeURIComponent(SECRET));
    expect((failure as Error).message).toContain("egress_transport_failed");
    await egress.close();
  });

  it("locks origin keys, URL authority, methods, ports, and production transport seams", async () => {
    const resolver = vi.fn(async () => [PUBLIC_V4]);
    const factory = vi.fn(() => fakeDispatcher());
    const egress = providerHarness(factory, resolver);
    const hostile = [
      request({ originKey: "missing" }),
      request({ url: new URL("https://attacker.test/") }),
      request({ url: new URL("http://provider.test/") }),
      request({ url: new URL("https://user:pass@provider.test/") }),
      request({ method: "OPTIONS" as EgressRequest["method"] }),
      request({ headers: { host: "attacker.test" } }),
    ];
    for (const input of hostile) await expect(egress.request(input)).rejects.toThrow(/egress_/);
    expect(resolver).not.toHaveBeenCalled();
    expect(factory).not.toHaveBeenCalled();
    await egress.close();

    expect(() =>
      createProviderEgress({
        origins: { provider: [new URL("https://provider.test:8443")] },
        redactor: testRedactor(),
        production: true,
      }),
    ).toThrow(/port/);
    expect(() =>
      createProviderEgress({
        origins: { provider: [new URL("https://provider.test")] },
        resolver,
        redactor: testRedactor(),
        production: true,
      }),
    ).toThrow(/test-only/);
  });
});
