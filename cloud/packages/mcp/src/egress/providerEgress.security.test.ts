import { createServer, type Server } from "node:https";
import type { IncomingMessage, ServerResponse } from "node:http";
import { resolve4, resolve6 } from "node:dns/promises";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  createNodePinnedDispatcher,
  createProviderEgress,
  type EgressLimits,
  type EgressRequest,
  type PinnedDispatchResponse,
  type PinnedDispatcher,
  type PinnedDispatcherFactory,
  type PinnedDispatcherOptions,
  type ProviderEgress,
} from "./providerEgress.js";
import { createGuardedFetch, SsrfBlockedError } from "../ssrf.js";
import { followGuardedRedirects } from "../native/fetch.js";

vi.mock("node:dns/promises", () => ({ resolve4: vi.fn(), resolve6: vi.fn() }));

const PUBLIC = "93.184.216.34";
const SECRET = "redirect-secret-/+?";
const CERT = `-----BEGIN CERTIFICATE-----
MIIDPTCCAiWgAwIBAgIUbGtBeXoFz8OV08DCCHWlWCN3K5owDQYJKoZIhvcNAQEL
BQAwGDEWMBQGA1UEAwwNcHJvdmlkZXIudGVzdDAeFw0yNjEwMjQxMDM1MjBaFw0z
NjEwMjExMDM1MjBaMBgxFjAUBgNVBAMMDXByb3ZpZGVyLnRlc3QwggEiMA0GCSqG
SIb3DQEBAQUAA4IBDwAwggEKAoIBAQCU6ROAfv1Mu7d3sQpTNAPEy0PgGGhkfDQ/
m0Qgjb3XEKNRpMMVBFI2wwpbzwFZUxDzUba8/l4kHgY5uDZC1ogKF0+b4YhsXNTo
p4jmv96jJwbZlmQYCVmBkb5RccnZMVB526Ou3QbsqOYXkgoUwofYaFQy57Gyu53b
2xlqSGs26uI+0vSxAb8uoTkbFbptoJ1LJrQCj+YuDGBhsNFyQDVdtD0lurBVWa4z
htvgMvnybEvnOPycpNnZ5ljKU0Y/jPImRUwz52/hvbMNyurSFO7oszxktRZ6vTBy
1UR8LPi9+X3OBtmv4/oNGtbx9nOQrIxj4IE9KqgJ7vlIISJ/fk/VAgMBAAGjfzB9
MB0GA1UdDgQWBBT4oqOuoDEKt25SaCZ5+twbfXJjRjAfBgNVHSMEGDAWgBT4oqOu
oDEKt25SaCZ5+twbfXJjRjAPBgNVHRMBAf8EBTADAQH/MCoGA1UdEQQjMCGCDXBy
b3ZpZGVyLnRlc3SCCm90aGVyLnRlc3SHBH8AAAEwDQYJKoZIhvcNAQELBQADggEB
AHWPdQ4rn5flO3ic9l10FDhvMUUqs9bbUgKigu0ZDtG1A7t8xLz7oOTx+Foxes3C
UAVSg+XxtWSEN3TAip+arpn3eDj4kL/z72jr7AhtnFdfIH629ORCMhjzbf8kvOaG
hiV/LCFJ4E45mmr8TTbx0w0zgRvETQF0sPVQq2S+23wusXSK/nK3mUp89qtqRe9g
Py7ZLN2d5xRqmbgcFonDcKYVkasxj4qoteYf3H0bgvlzc18Et1nVTp1DYCxfj6eO
CbCZDiafdeUpSv5Zvpg42HI7IIdjvt5OoKnYIRct55RG/SLYgcBu7D24XwSuX6pT
Je7FW1EpGbX81125anwXhxg=
-----END CERTIFICATE-----`;
const KEY = `-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCU6ROAfv1Mu7d3
sQpTNAPEy0PgGGhkfDQ/m0Qgjb3XEKNRpMMVBFI2wwpbzwFZUxDzUba8/l4kHgY5
uDZC1ogKF0+b4YhsXNTop4jmv96jJwbZlmQYCVmBkb5RccnZMVB526Ou3QbsqOYX
kgoUwofYaFQy57Gyu53b2xlqSGs26uI+0vSxAb8uoTkbFbptoJ1LJrQCj+YuDGBh
sNFyQDVdtD0lurBVWa4zhtvgMvnybEvnOPycpNnZ5ljKU0Y/jPImRUwz52/hvbMN
yurSFO7oszxktRZ6vTBy1UR8LPi9+X3OBtmv4/oNGtbx9nOQrIxj4IE9KqgJ7vlI
ISJ/fk/VAgMBAAECggEAGcq1/0Vfi6Ue3bsbIfaqKXGYf83SdQcjSJoUxnuudDv0
Qb2jMXZ2Y/hLyMOVxPozfyV53InFVgWiR+iNc22zkeXgOsxpQ/WfRe3Qs0Dr57/o
epMHIrep2lybRYGLN9SIDxc5Jl4vpxmJAu+fUeGwxE2rucZyO5Yt/SjZodRJx7DL
HLNT8BaH63YsJosRpdT0odc0G/RNYh4OfA2AGbayknGCFhTvyvLsMsupR6zlrA78
0XWwqzhKkLRpaNHvuGqhbGAp15k4jRE2pw+k+QlHvJ+LibJQpWMV44X7Hg2HpCTn
1D7/WlUxUqF9c8eySoNTXtVsqtnsmpimBXQFvBgaSQKBgQDEFoL+RBIcLPzf/oG6
jQ83AF+MYopMUN3iaEWpKeqCZaWW5L76ban1W3V9IRldH9wumcFyzv0akUdZlbIo
AWzv9we61sFN6zBhggDVziv28E9RqLHv/EW2Ij+T/PNq7+rfGCIvx6w74D0X5rAQ
4kt7bee1XxN7nUk04zAW2mdCWQKBgQDCaHbrR+N2vGGEQWg80QhU2L0nYn05PUBX
FHQuOdlqqYb+tt11iACR2e/vJ4O281+UFSW28cHYayqg7jlDOJBEgvQnfZEeZh/9
bKM3s+S2GKr/wO0ruL41LtrJkazWnh1qQWP3FInGPeXKPyAoQQThKxZ7LfEG37dl
Hl4wqv8x3QKBgQCEMLzsVs1yqy1qf/PK5I9uP9UqGcAsBJQgrrTPfs92SrogCGNr
BgT+wEJrMaYcrn7L96F/GWVtxKS6Ev3AlH1xJDLU1TQJqFS8V1zixhPDbGu8nCIg
rAv+5gXAaVVcMRNAhM9/MHe/AcON2lm1eCj0s7nx/n9u5TDV85aWwXO9OQKBgBcO
xtP/EcZ6b2J9U3yrGj7d+gla0Bli32e0oFb/O39AHifFzpxrBg5GeAO4fxHK6dIp
c/Cv2druUv8FYjtL0SifE5A/f1/IoxCuuukXaBAE+vscicS+w6iRJxfzNDm8RSbe
HJookHK30rJbLFg55fdC4ga4GzdCf4D5yhghn+TtAoGAMe8b/Z9UOFgmwgSs2M2i
j12zaVrMSjwQ8XpMe+dnlhX+qnGUt2mNTiHZw4tHUeUm/8DSLHN+vLQ+IYaVIl96
X5zfAq99vBWY/bKRW/UvVj67w9D1FWmudjN7Xu2QI98D6ZrApsDTxowz1GKhyie9
IRTSUB3FPU0ntf+TfIjEkIw=
-----END PRIVATE KEY-----`;

const servers: Server[] = [];
const egresses: ProviderEgress[] = [];

function redactor() {
  const clean = (value: string, secrets: readonly string[] = []): string => {
    let output = value;
    for (const secret of [...secrets, ...secrets.map(encodeURIComponent)]) {
      if (secret !== "") output = output.split(secret).join("[REDACTED]");
    }
    return output;
  };
  return {
    text: clean,
    error: (error: unknown, secrets: readonly string[] = []) =>
      new Error(clean(error instanceof Error ? error.message : String(error), secrets)),
    json: <T,>(value: T, secrets: readonly string[] = []): T =>
      JSON.parse(clean(JSON.stringify(value), secrets)) as T,
  };
}

function limits(patch: Partial<EgressLimits> = {}): EgressLimits {
  return {
    connectMs: 100,
    headersMs: 100,
    idleMs: 100,
    totalMs: 1_000,
    maxRedirects: 2,
    headerBytes: 8_192,
    responseBytes: 1_024,
    decompressedBytes: 2_048,
    ...patch,
  };
}

function request(url: URL, patch: Partial<EgressRequest> = {}): EgressRequest {
  return {
    originKey: "provider",
    url,
    method: "GET",
    headers: {},
    redirect: "same_origin",
    limits: limits(),
    ...patch,
  };
}

function fakeDispatcher(response: () => Promise<PinnedDispatchResponse>): PinnedDispatcher {
  return { dispatch: response, close: vi.fn(async () => {}) };
}

async function startServer(
  handler: (req: IncomingMessage, res: ServerResponse) => void,
): Promise<URL> {
  const server = createServer({ key: KEY, cert: CERT }, handler);
  servers.push(server);
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const address = server.address();
  if (address === null || typeof address === "string") throw new Error("fixture address unavailable");
  return new URL(`https://127.0.0.1:${address.port}`);
}

function localEgress(origins: readonly URL[], production = false): {
  egress: ProviderEgress;
  dispatcherOptions: PinnedDispatcherOptions[];
} {
  const dispatcherOptions: PinnedDispatcherOptions[] = [];
  const egress = createProviderEgress({
    origins: { provider: origins },
    dispatcherFactory: (options) => {
      dispatcherOptions.push(options);
      return createNodePinnedDispatcher({ ...options, ca: CERT });
    },
    redactor: redactor(),
    production,
  });
  egresses.push(egress);
  return { egress, dispatcherOptions };
}

beforeEach(() => {
  vi.mocked(resolve4).mockReset();
  vi.mocked(resolve6).mockReset();
  vi.mocked(resolve4).mockResolvedValue([PUBLIC]);
  vi.mocked(resolve6).mockResolvedValue(["2606:4700::1111"]);
});

afterEach(async () => {
  await Promise.all(egresses.splice(0).map((egress) => egress.close()));
  await Promise.all(
    servers.splice(0).map(
      (server) =>
        new Promise<void>((resolve) => {
          server.closeAllConnections();
          server.close(() => resolve());
        }),
    ),
  );
});

describe("ProviderEgress DNS and TLS security", () => {
  it("rejects mixed answers, resolver failure/zero answers, and mapped loopback", async () => {
    const cases: Array<(host: string) => Promise<string[]>> = [
      async () => [PUBLIC, "10.0.0.2"],
      async () => [],
      async () => { throw new Error("DNS refused"); },
      async () => ["::ffff:127.0.0.1"],
      async () => ["127.0.0.1"],
      async () => ["not-an-address"],
    ];
    for (const resolver of cases) {
      const factory = vi.fn(() => fakeDispatcher(async () => { throw new Error("wire touched"); }));
      const egress = createProviderEgress({
        origins: { provider: [new URL("https://provider.test")] },
        resolver,
        dispatcherFactory: factory,
        redactor: redactor(),
        production: false,
      });
      egresses.push(egress);
      await expect(egress.request(request(new URL("https://provider.test")))).rejects.toThrow(
        SsrfBlockedError,
      );
      expect(factory).not.toHaveBeenCalled();
    }
  });

  it("default DNS requires successful A and AAAA lookups and a nonempty answer set", async () => {
    const wire = vi.fn(async () => new Response("ok"));
    const guarded = createGuardedFetch({ fetchImpl: wire });
    await guarded("https://provider.test/");
    expect(resolve4).toHaveBeenCalledWith("provider.test");
    expect(resolve6).toHaveBeenCalledWith("provider.test");
    expect(wire).toHaveBeenCalledTimes(1);

    vi.mocked(resolve6).mockRejectedValueOnce(new Error("AAAA failed"));
    await expect(guarded("https://provider.test/")).rejects.toThrow(SsrfBlockedError);
    vi.mocked(resolve4).mockResolvedValueOnce([]);
    vi.mocked(resolve6).mockResolvedValueOnce([]);
    await expect(guarded("https://provider.test/")).rejects.toThrow(SsrfBlockedError);
    expect(wire).toHaveBeenCalledTimes(1);
  });

  it("uses a per-socket checked lookup, verifies the literal remote, and does not weaken TLS", async () => {
    const base = await startServer((_req, res) => res.end("secure"));
    const { egress, dispatcherOptions } = localEgress([base]);
    const response = await egress.request(request(new URL(`${base}fixture`)));
    expect(response.remoteAddress).toBe("127.0.0.1");
    expect(await new Response(response.body).text()).toBe("secure");
    expect(dispatcherOptions).toHaveLength(1);
    expect(dispatcherOptions[0].addresses).toEqual(["127.0.0.1"]);
    expect(dispatcherOptions[0].servername).toBe("127.0.0.1");

    const untrusted = createProviderEgress({
      origins: { provider: [base] },
      redactor: redactor(),
      production: false,
    });
    egresses.push(untrusted);
    await expect(untrusted.request(request(new URL(`${base}fixture`)))).rejects.toThrow(
      /egress_transport_failed/,
    );
  });

  it("proves actual Node DNS-name lookup, SNI, and successful certificate hostname validation", async () => {
    const sni: Array<string | undefined> = [];
    const lookups: Array<{ hostname: string; all: boolean }> = [];
    let requests = 0;
    let receivedBody = "";
    const base = await startServer((req, res) => {
      requests++;
      req.setEncoding("utf8");
      req.on("data", (chunk: string) => { receivedBody += chunk; });
      req.on("end", () => res.end("dns-tls-ok"));
    });
    servers.at(-1)?.on("secureConnection", (socket) => sni.push(socket.servername || undefined));
    const dispatcher = createNodePinnedDispatcher({
      origin: new URL("https://provider.test"),
      addresses: ["127.0.0.1"],
      servername: "provider.test",
      lookup: (hostname, options, callback) => {
        lookups.push({ hostname, all: options.all === true });
        if (options.all) callback(null, [{ address: "127.0.0.1", family: 4 }]);
        else callback(null, "127.0.0.1", 4);
      },
      ca: CERT,
    });

    const response = await dispatcher.dispatch({
      url: new URL(`https://provider.test:${base.port}/dns-name`),
      method: "POST",
      headers: { "content-length": "4" },
      body: new TextEncoder().encode("ping"),
      signal: new AbortController().signal,
      connectMs: 100,
      headersMs: 100,
    });

    expect(response.status).toBe(200);
    expect(response.remoteAddress).toBe("127.0.0.1");
    expect(await new Response(response.body).text()).toBe("dns-tls-ok");
    expect(lookups.length).toBeGreaterThan(0);
    expect(lookups.every((entry) => entry.hostname === "provider.test")).toBe(true);
    expect(sni).toEqual(["provider.test"]);
    expect(requests).toBe(1);
    expect(receivedBody).toBe("ping");
    await dispatcher.close();
  });

  it("refuses a wrong-host certificate on the actual Node dispatcher before request bytes", async () => {
    let requests = 0;
    let bytes = 0;
    const base = await startServer((req, res) => {
      requests++;
      req.on("data", (chunk: Buffer) => { bytes += chunk.length; });
      req.on("end", () => res.end("wrong-host"));
    });
    const dispatcher = createNodePinnedDispatcher({
      origin: new URL("https://wrong.test"),
      addresses: ["127.0.0.1"],
      servername: "wrong.test",
      lookup: (_hostname, options, callback) => {
        if (options.all) callback(null, [{ address: "127.0.0.1", family: 4 }]);
        else callback(null, "127.0.0.1", 4);
      },
      ca: CERT,
    });

    const failure = await dispatcher.dispatch({
      url: new URL(`https://wrong.test:${base.port}/collect`),
      method: "POST",
      headers: { authorization: `Bearer ${SECRET}`, "content-length": String(SECRET.length) },
      body: new TextEncoder().encode(SECRET),
      signal: new AbortController().signal,
      connectMs: 100,
      headersMs: 100,
    }).catch((error: unknown) => error);

    expect(failure).toMatchObject({ code: "ERR_TLS_CERT_ALTNAME_INVALID" });
    expect(requests).toBe(0);
    expect(bytes).toBe(0);
    await dispatcher.close();
  });

  it("verifies the actual socket remote before sending headers or body", async () => {
    let requests = 0;
    let bytes = 0;
    const base = await startServer((req, res) => {
      requests++;
      req.on("data", (chunk: Buffer) => { bytes += chunk.length; });
      req.on("end", () => res.end("unchecked"));
    });
    const dispatcher = createNodePinnedDispatcher({
      origin: new URL("https://provider.test"),
      addresses: [PUBLIC],
      servername: "provider.test",
      // Deliberately violate the factory contract: the dispatcher must notice
      // that the resulting socket is not in the checked set before req.end().
      lookup: (_hostname, options, callback) => {
        if (options.all) callback(null, [{ address: "127.0.0.1", family: 4 }]);
        else callback(null, "127.0.0.1", 4);
      },
      ca: CERT,
    });
    await expect(
      dispatcher.dispatch({
        url: new URL(`https://provider.test:${base.port}/collect`),
        method: "POST",
        headers: { authorization: `Bearer ${SECRET}`, "content-length": String(SECRET.length) },
        body: new TextEncoder().encode(SECRET),
        signal: new AbortController().signal,
        connectMs: 100,
        headersMs: 100,
      }),
    ).rejects.toThrow(/remote_address/);
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(requests).toBe(0);
    expect(bytes).toBe(0);
    await dispatcher.close();
  });

  it("counts duplicate raw response headers toward the aggregate cap", async () => {
    const source = await startServer((_req, res) => {
      res.setHeader("x-a", Array(80).fill("aaaa"));
      res.end("ok");
    });
    const { egress } = localEgress([source]);

    await expect(
      egress.request(request(new URL(source), { limits: limits({ headerBytes: 600 }) })),
    ).rejects.toThrow(/header_bytes/);
  });

  it("allows literal loopback only outside production and never through a hostname answer", async () => {
    const base = await startServer((_req, res) => res.end("fixture"));
    const production = createProviderEgress({
      origins: { provider: [base] },
      redactor: redactor(),
      production: true,
    });
    egresses.push(production);
    await expect(production.request(request(new URL(base)))).rejects.toThrow(SsrfBlockedError);

    const { egress } = localEgress([base]);
    await expect(egress.request(request(new URL(base)))).resolves.toMatchObject({ status: 200 });
  });
});

describe("ProviderEgress redirect security", () => {
  it("denies privileged cross-origin 301/302/303/307/308 without replay", async () => {
    let targetRequests = 0;
    let targetBytes = 0;
    const target = await startServer((req, res) => {
      targetRequests++;
      req.on("data", (chunk: Buffer) => { targetBytes += chunk.length; });
      req.on("end", () => res.end("attacker"));
    });
    let status = 301;
    const source = await startServer((req, res) => {
      req.resume();
      req.on("end", () => {
        res.writeHead(status, { location: `${target}collect` });
        res.end();
      });
    });
    const { egress } = localEgress([source, target]);

    for (const redirectStatus of [301, 302, 303, 307, 308]) {
      status = redirectStatus;
      await expect(
        egress.request(
          request(new URL(`${source}start`), {
            method: "POST",
            headers: { authorization: `Bearer ${SECRET}` },
            body: new TextEncoder().encode(`payload=${SECRET}`),
            secretValues: [SECRET],
            privileged: true,
          }),
        ),
      ).rejects.toThrow(/cross_origin/);
    }
    expect(targetRequests).toBe(0);
    expect(targetBytes).toBe(0);
  });

  it("revalidates same-origin hops and denies downgrade", async () => {
    let targetRequests = 0;
    const target = await startServer((_req, res) => {
      targetRequests++;
      res.end("downgrade");
    });
    const methods: Array<string | undefined> = [];
    const bodies: string[] = [];
    const source = await startServer((req, res) => {
      let body = "";
      req.setEncoding("utf8");
      req.on("data", (chunk: string) => { body += chunk; });
      req.on("end", () => {
        methods.push(req.method);
        bodies.push(body);
        if (req.url === "/start") {
          res.writeHead(303, { location: "/final" });
          res.end();
        } else if (req.url === "/downgrade") {
          res.writeHead(302, { location: `${target.toString().replace("https:", "http:")}collect` });
          res.end();
        } else {
          res.end("landed");
        }
      });
    });
    const { egress, dispatcherOptions } = localEgress([source, target]);

    const response = await egress.request(
      request(new URL(`${source}start`), {
        method: "POST",
        headers: { authorization: `Bearer ${SECRET}` },
        body: new TextEncoder().encode(SECRET),
        secretValues: [SECRET],
        privileged: true,
      }),
    );
    expect(await new Response(response.body).text()).toBe("landed");
    expect(methods).toEqual(["POST", "GET"]);
    expect(bodies).toEqual([SECRET, ""]);
    expect(dispatcherOptions).toHaveLength(2);
    expect(dispatcherOptions.map((options) => options.addresses)).toEqual([
      ["127.0.0.1"],
      ["127.0.0.1"],
    ]);

    await expect(egress.request(request(new URL(`${source}downgrade`)))).rejects.toThrow(
      /downgrade/,
    );
    expect(targetRequests).toBe(0);
  });

  it("bounds same-origin chains and closes each redirect response", async () => {
    let requests = 0;
    const source = await startServer((_req, res) => {
      requests++;
      res.writeHead(302, { location: `/hop-${requests}` });
      res.end("redirect-body");
    });
    const { egress } = localEgress([source]);

    await expect(
      egress.request(request(new URL(`${source}start`), { limits: limits({ maxRedirects: 1 }) })),
    ).rejects.toThrow(/too_many_redirects/);
    expect(requests).toBe(2);
  });

  it("preserves S3 redirect denial without following or replaying a signed request", async () => {
    let targetRequests = 0;
    const target = await startServer((_req, res) => {
      targetRequests++;
      res.end("unexpected");
    });
    const source = await startServer((_req, res) => {
      res.writeHead(307, { location: `${target}signature-replay` });
      res.end();
    });
    const { egress } = localEgress([source, target]);

    const response = await egress.request(
      request(new URL(`${source}signed`), {
        method: "PUT",
        headers: { authorization: `AWS4-HMAC-SHA256 ${SECRET}` },
        body: new TextEncoder().encode(SECRET),
        secretValues: [SECRET],
        privileged: true,
        redirect: "deny",
      }),
    );
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(`${target}signature-replay`);
    expect(targetRequests).toBe(0);
    await response.body.cancel();
  });

  it("allows an explicitly unauthenticated public-fetch cross-origin redirect", async () => {
    const calls: string[] = [];
    const response = await followGuardedRedirects(
      async (url) => {
        calls.push(url);
        return calls.length === 1
          ? new Response(null, { status: 302, headers: { location: "https://public-target.test/final" } })
          : new Response("public");
      },
      "https://public-source.test/start",
      { headers: { "user-agent": "public-fetch" } },
      { privileged: false },
    );
    expect(await response.text()).toBe("public");
    expect(calls).toEqual([
      "https://public-source.test/start",
      "https://public-target.test/final",
    ]);
  });

  it("cancels every redirect response when the chain exceeds MAX_REDIRECTS", async () => {
    let calls = 0;
    let cancellations = 0;
    const pending = followGuardedRedirects(
      async () => {
        calls++;
        const body = new ReadableStream<Uint8Array>({
          cancel: () => { cancellations++; },
        });
        return new Response(body, {
          status: 302,
          headers: { location: `/hop-${calls}` },
        });
      },
      "https://public-source.test/start",
    );

    await expect(pending).rejects.toThrow(/too many redirects/);
    expect(calls).toBe(6);
    expect(cancellations).toBe(6);
  });

  it("cancels a redirect response whose Location is malformed", async () => {
    let calls = 0;
    let cancellations = 0;
    const body = new ReadableStream<Uint8Array>({
      cancel: () => { cancellations++; },
    });
    const pending = followGuardedRedirects(
      async () => {
        calls++;
        return new Response(body, {
          status: 302,
          headers: { location: "https://[" },
        });
      },
      "https://public-source.test/start",
    );

    await expect(pending).rejects.toThrow();
    expect(calls).toBe(1);
    expect(cancellations).toBe(1);
  });

  it("denies legacy credentialed and secret-body redirects instead of stripping and replaying", async () => {
    const cases: Array<{ url: string; init: RequestInit; privileged: boolean; location?: string }> = [
      {
        url: "https://source.test/start",
        init: { headers: { authorization: `Bearer ${SECRET}` } },
        privileged: false,
      },
      {
        url: "https://source.test/start",
        init: { method: "POST", body: `secret=${SECRET}` },
        privileged: false,
      },
      {
        url: "https://source.test/start",
        init: { headers: { "x-custom-credential": SECRET } },
        privileged: false,
      },
      {
        url: `https://source.test/start?secret=${encodeURIComponent(SECRET)}`,
        init: { headers: {} },
        privileged: false,
      },
      {
        url: "https://source.test/start",
        init: { headers: {} },
        privileged: true,
      },
      {
        url: "https://source.test/start",
        init: { headers: {} },
        privileged: false,
        location: `https://target.test/?secret=${encodeURIComponent(SECRET)}`,
      },
    ];
    for (const item of cases) {
      let calls = 0;
      const pending = followGuardedRedirects(
        async () => {
          calls++;
          return new Response(null, {
            status: 307,
            headers: { location: item.location ?? "https://target.test/" },
          });
        },
        item.url,
        item.init,
        { privileged: item.privileged, secretValues: [SECRET] },
      );
      await expect(pending).rejects.toThrow(/cross_origin/);
      expect(calls).toBe(1);
    }
  });

  const encodedUnicodeSecret = encodeURIComponent("space /本+?");
  const mixedEscapeSecret = encodedUnicodeSecret.replace(/%[0-9A-F]{2}/g, (escape, index: number) =>
    index % 2 === 0 ? escape.toLowerCase() : escape,
  );
  it.each([
    { kind: "lowercase percent escapes", value: encodedUnicodeSecret.toLowerCase() },
    { kind: "mixed-case percent escapes", value: mixedEscapeSecret },
    { kind: "plus-for-space form", value: encodedUnicodeSecret.replaceAll("%20", "+") },
    { kind: "plus and mixed-case escapes", value: mixedEscapeSecret.replaceAll("%20", "+") },
  ])("denies a declared secret with $kind in a cross-origin URL", async ({ value }) => {
    let calls = 0;
    const pending = followGuardedRedirects(
      async () => {
        calls++;
        return calls === 1
          ? new Response(null, { status: 307, headers: { location: "https://target.test/final" } })
          : new Response("secret replayed");
      },
      `https://source.test/start?secret=${value}`,
      {},
      { secretValues: ["space /本+?"] },
    );

    await expect(pending).rejects.toThrow(/cross_origin/);
    expect(calls).toBe(1);
  });
});

describe("ProviderEgress deadlines and cancellation", () => {
  it("times out a connection whose checked lookup never completes", async () => {
    const dispatcher = createNodePinnedDispatcher({
      origin: new URL("https://provider.test"),
      addresses: [PUBLIC],
      servername: "provider.test",
      lookup: () => {},
    });
    await expect(
      dispatcher.dispatch({
        url: new URL("https://provider.test/"),
        method: "GET",
        headers: {},
        signal: new AbortController().signal,
        connectMs: 20,
        headersMs: 500,
      }),
    ).rejects.toThrow(/connect_timeout/);
    await dispatcher.close();
  });

  it("enforces the headers deadline and aborts a pending request", async () => {
    const source = await startServer(() => {});
    const { egress } = localEgress([source]);
    await expect(
      egress.request(request(new URL(source), { limits: limits({ headersMs: 20, totalMs: 500 }) })),
    ).rejects.toThrow(/headers_timeout/);

    const controller = new AbortController();
    const pending = egress.request(
      request(new URL(source), {
        signal: controller.signal,
        limits: limits({ headersMs: 500, totalMs: 500 }),
      }),
    );
    controller.abort();
    await expect(pending).rejects.toThrow(/abort/i);
  });

  it("enforces idle and total deadlines on real HTTPS response streams", async () => {
    const source = await startServer((_req, res) => {
      res.writeHead(200, { "content-type": "application/octet-stream" });
      res.write("first");
    });
    for (const kind of ["idle", "total"] as const) {
      const { egress } = localEgress([source]);
      const response = await egress.request(
        request(new URL(source), {
          limits: limits({
            idleMs: kind === "idle" ? 30 : 500,
            totalMs: kind === "total" ? 50 : 500,
          }),
        }),
      );
      const reader = response.body.getReader();
      const first = await reader.read();
      expect(new TextDecoder().decode(first.value)).toBe("first");
      await expect(reader.read()).rejects.toThrow(kind === "idle" ? /idle_timeout/ : /total_timeout/);
    }
  });
});
