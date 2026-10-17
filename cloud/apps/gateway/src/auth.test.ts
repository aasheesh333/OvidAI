import { describe, expect, it } from "vitest";
import Fastify, { type FastifyBaseLogger, type FastifyInstance } from "fastify";
import type { App } from "firebase-admin/app";
import {
  authHook,
  createFirebaseVerifier,
  createTestVerifier,
  type AuthPrincipal,
  type Verifier,
} from "./auth.js";
import { loadGatewayEnv } from "./env.js";

const PRINCIPAL: AuthPrincipal = {
  uid: "u1",
  email: "u1@example.com",
  authTime: 1_700_000_000,
};

// Sensitive detail that must never surface in a 401 response body.
const LEAKY_MESSAGE = "signature-mismatch:alg=none kid=s3cr3t-jwk";

interface VerifierCalls {
  idTokens: string[];
  appCheckTokens: (string | null)[];
}

function resolvingVerifier(calls: VerifierCalls): Verifier {
  return async (idToken, appCheckToken) => {
    calls.idTokens.push(idToken);
    calls.appCheckTokens.push(appCheckToken);
    return PRINCIPAL;
  };
}

function throwingVerifier(): Verifier {
  return async () => {
    throw new Error(LEAKY_MESSAGE);
  };
}

// Real Fastify instance + inject so the hook is exercised exactly the way
// Task 7's routes will exercise it (no hand-rolled request/reply mocks).
async function withProtectedRoute(
  verifier: Verifier,
  run: (app: FastifyInstance) => Promise<void>,
): Promise<void> {
  const app = Fastify();
  try {
    app.addHook("preHandler", authHook(verifier));
    // Reads request.principal — compiles only via the module augmentation.
    app.get("/probe", async (request) => ({
      uid: request.principal.uid,
      email: request.principal.email,
      authTime: request.principal.authTime,
    }));
    await run(app);
  } finally {
    await app.close();
  }
}

const AUTH_HEADERS = {
  authorization: "Bearer id-token-1",
  "x-firebase-appcheck": "app-check-token-1",
};

describe("authHook", () => {
  it("rejects a request with no Authorization header with the 401 envelope", async () => {
    const calls: VerifierCalls = { idTokens: [], appCheckTokens: [] };
    await withProtectedRoute(resolvingVerifier(calls), async (app) => {
      const res = await app.inject({ method: "GET", url: "/probe" });
      expect(res.statusCode).toBe(401);
      expect(res.json()).toMatchObject({
        error: { code: "unauthenticated" },
      });
    });
    // Never even asked the verifier.
    expect(calls.idTokens).toEqual([]);
  });

  it("rejects a non-Bearer Authorization scheme", async () => {
    const calls: VerifierCalls = { idTokens: [], appCheckTokens: [] };
    await withProtectedRoute(resolvingVerifier(calls), async (app) => {
      const res = await app.inject({
        method: "GET",
        url: "/probe",
        headers: { authorization: "Basic dXNlcjpwYXNz" },
      });
      expect(res.statusCode).toBe(401);
      expect(res.json().error.code).toBe("unauthenticated");
    });
    expect(calls.idTokens).toEqual([]);
  });

  it("rejects an empty Bearer token", async () => {
    const calls: VerifierCalls = { idTokens: [], appCheckTokens: [] };
    await withProtectedRoute(resolvingVerifier(calls), async (app) => {
      const res = await app.inject({
        method: "GET",
        url: "/probe",
        headers: { authorization: "Bearer " },
      });
      expect(res.statusCode).toBe(401);
      expect(res.json().error.code).toBe("unauthenticated");
    });
    expect(calls.idTokens).toEqual([]);
  });

  it("maps a verifier rejection to 401 without leaking verification details", async () => {
    await withProtectedRoute(throwingVerifier(), async (app) => {
      const res = await app.inject({
        method: "GET",
        url: "/probe",
        headers: AUTH_HEADERS,
      });
      expect(res.statusCode).toBe(401);
      const body = res.json();
      expect(body.error.code).toBe("unauthenticated");
      expect(typeof body.error.message).toBe("string");
      expect(body.error.message).not.toContain("s3cr3t-jwk");
      expect(res.body).not.toContain(LEAKY_MESSAGE);
    });
  });

  it("decorates request.principal on success and forwards both tokens", async () => {
    const calls: VerifierCalls = { idTokens: [], appCheckTokens: [] };
    await withProtectedRoute(resolvingVerifier(calls), async (app) => {
      const res = await app.inject({
        method: "GET",
        url: "/probe",
        headers: AUTH_HEADERS,
      });
      expect(res.statusCode).toBe(200);
      expect(res.json()).toEqual({
        uid: "u1",
        email: "u1@example.com",
        authTime: 1_700_000_000,
      });
    });
    expect(calls.idTokens).toEqual(["id-token-1"]);
    expect(calls.appCheckTokens).toEqual(["app-check-token-1"]);
  });

  it("passes appCheckToken null when the App Check header is absent (verifier decides)", async () => {
    const calls: VerifierCalls = { idTokens: [], appCheckTokens: [] };
    await withProtectedRoute(resolvingVerifier(calls), async (app) => {
      const res = await app.inject({
        method: "GET",
        url: "/probe",
        headers: { authorization: "Bearer id-token-1" },
      });
      expect(res.statusCode).toBe(200);
    });
    expect(calls.appCheckTokens).toEqual([null]);
  });
});

// Task 6 review carry-over (binding on Task 7): the swallowed verification
// error must be diagnosable server-side — logged via request.log.warn WITH the
// underlying error — while the client-facing 401 envelope stays generic.
describe("authHook observability", () => {
  interface CapturingLogger {
    logger: FastifyBaseLogger;
    warns: unknown[][];
  }

  function capturingLogger(): CapturingLogger {
    const warns: unknown[][] = [];
    const noop = (): void => {};
    const logger = {
      level: "warn",
      fatal: noop,
      error: noop,
      warn: (...args: unknown[]) => {
        warns.push(args);
      },
      info: noop,
      debug: noop,
      trace: noop,
      silent: noop,
      child: () => logger,
    } as unknown as FastifyBaseLogger;
    return { logger, warns };
  }

  async function withLoggedApp(
    verifier: Verifier,
    run: (app: FastifyInstance, warns: unknown[][]) => Promise<void>,
  ): Promise<void> {
    const { logger, warns } = capturingLogger();
    const app = Fastify({ loggerInstance: logger });
    try {
      app.addHook("preHandler", authHook(verifier));
      app.get("/probe", async () => ({ ok: true }));
      await run(app, warns);
    } finally {
      await app.close();
    }
  }

  it("logs the swallowed verifier error server-side; client envelope unchanged", async () => {
    await withLoggedApp(throwingVerifier(), async (app) => {
      const res = await app.inject({ method: "GET", url: "/probe", headers: AUTH_HEADERS });
      expect(res.statusCode).toBe(401);
      expect(res.json().error.code).toBe("unauthenticated");
      expect(res.body).not.toContain("s3cr3t-jwk"); // still no detail leak
    });
  });

  it("the warn log carries the underlying verification error", async () => {
    await withLoggedApp(throwingVerifier(), async (app, warns) => {
      await app.inject({ method: "GET", url: "/probe", headers: AUTH_HEADERS });
      const logged = warns
        .map((args) => args[0])
        .filter(
          (a): a is { err: unknown } =>
            typeof a === "object" && a !== null && "err" in (a as object),
        )
        .map((a) => a.err);
      expect(
        logged.some((e) => e instanceof Error && e.message.includes("s3cr3t-jwk")),
      ).toBe(true);
    });
  });

  it("logs header-rejection 401s too (every hook 401 is diagnosable)", async () => {
    await withLoggedApp(resolvingVerifier({ idTokens: [], appCheckTokens: [] }), async (app, warns) => {
      const res = await app.inject({ method: "GET", url: "/probe" });
      expect(res.statusCode).toBe(401);
      expect(warns.length).toBeGreaterThan(0);
    });
  });
});

describe("createTestVerifier", () => {
  it("accepts tokens of the exact form test:<uid>", async () => {
    const verifier = createTestVerifier();
    await expect(verifier("test:abc123", null)).resolves.toEqual({
      uid: "abc123",
      email: null,
      authTime: 0,
    });
    // App Check token is irrelevant in test mode.
    await expect(verifier("test:u2", "whatever")).resolves.toMatchObject({
      uid: "u2",
    });
  });

  it("rejects anything that is not exactly test:<uid>", async () => {
    const verifier = createTestVerifier();
    for (const bad of [
      "",
      "abc123",
      "test:",
      "Test:abc",
      "TEST:abc",
      "testx:abc",
      "x-test-uid",
      "test",
      "test: ",
      "bearer test:abc",
    ]) {
      await expect(verifier(bad, null)).rejects.toThrow();
    }
  });
});

describe("createFirebaseVerifier", () => {
  it("rejects a missing App Check token before any firebase-admin call (no credentials needed)", async () => {
    // Lazy service construction is what makes this assertable without ADC:
    // the missing-header rejection must fire before getAuth/getAppCheck run.
    const verifier = createFirebaseVerifier({} as unknown as App);
    await expect(verifier("some-id-token", null)).rejects.toThrow();
  });
});

describe("loadGatewayEnv", () => {
  const fullRaw = {
    NODE_ENV: "production",
    PORT: "9001",
    HOST: "0.0.0.0",
    OVID_AUTH_MODE: "firebase",
    DATABASE_URL: "postgres://db:5432/ovid",
    REDIS_Q_URL: "redis://q:6379",
    REDIS_MINT_URL: "redis://mint:6379",
    MINT_BASE_URL: "http://mint:8000",
    // P7 Task 12 additions (required in firebase mode).
    OVID_WORKER_INTERNAL_URL: "http://worker:8091",
    OVID_INTERNAL_TOKEN: "internal-token",
  };

  it("throws when NODE_ENV=production and OVID_AUTH_MODE=test", () => {
    expect(() =>
      loadGatewayEnv({ NODE_ENV: "production", OVID_AUTH_MODE: "test" }),
    ).toThrow(/production/);
  });

  it("applies defaults (nodeEnv development, port 8081, host 127.0.0.1, authMode firebase)", () => {
    const env = loadGatewayEnv({
      OVID_AUTH_MODE: "test",
      DATABASE_URL: "postgres://x",
      REDIS_Q_URL: "redis://x",
      REDIS_MINT_URL: "redis://x",
      MINT_BASE_URL: "http://x",
    });
    expect(env.nodeEnv).toBe("development");
    expect(env.port).toBe(8081);
    expect(env.host).toBe("127.0.0.1");
    expect(env.authMode).toBe("test");
  });

  it("defaults authMode to firebase and requires every URL in firebase mode", () => {
    expect(() => loadGatewayEnv({})).toThrow(/DATABASE_URL/);
    for (const missing of [
      "DATABASE_URL",
      "REDIS_Q_URL",
      "REDIS_MINT_URL",
      "MINT_BASE_URL",
      "OVID_WORKER_INTERNAL_URL",
    ] as const) {
      const raw = { ...fullRaw, NODE_ENV: "development" };
      delete raw[missing];
      expect(() => loadGatewayEnv(raw)).toThrow(new RegExp(missing));
    }
    const noToken = { ...fullRaw, NODE_ENV: "development" };
    delete noToken.OVID_INTERNAL_TOKEN;
    expect(() => loadGatewayEnv(noToken)).toThrow(/OVID_INTERNAL_TOKEN/);
  });

  it("respects explicit values", () => {
    const env = loadGatewayEnv(fullRaw);
    expect(env).toEqual({
      nodeEnv: "production",
      port: 9001,
      host: "0.0.0.0",
      authMode: "firebase",
      databaseUrl: "postgres://db:5432/ovid",
      redisQUrl: "redis://q:6379",
      redisMintUrl: "redis://mint:6379",
      mintBaseUrl: "http://mint:8000",
      workerInternalUrl: "http://worker:8091",
      internalToken: "internal-token",
      fileInlineMaxBytes: 1_048_576,
      putMaxBytes: 8_388_608,
      presignTtlSeconds: 3600,
      hydrateWaitMs: 20_000,
      redisCUrl: "redis://q:6379",
    });
  });

  it("allows empty URLs in test mode", () => {
    const env = loadGatewayEnv({ OVID_AUTH_MODE: "test" });
    expect(env.databaseUrl).toBe("");
    expect(env.redisQUrl).toBe("");
    expect(env.redisMintUrl).toBe("");
    expect(env.mintBaseUrl).toBe("");
  });

  it("throws on an invalid PORT", () => {
    for (const bad of ["abc", "0", "-1", "65536", "80.5", ""]) {
      expect(() =>
        loadGatewayEnv({ OVID_AUTH_MODE: "test", PORT: bad }),
      ).toThrow(/PORT/);
    }
  });

  // HOST exists for the container deploy: docker-proxy forwards a published
  // port to the container's BRIDGE IP, so a gateway bound to loopback inside
  // the container is unreachable from the host's Caddy. Compose sets
  // HOST=0.0.0.0; the loopback default keeps bare-metal/dev runs closed.
  it("throws on an empty HOST when set", () => {
    for (const bad of ["", "   "]) {
      expect(() => loadGatewayEnv({ OVID_AUTH_MODE: "test", HOST: bad })).toThrow(
        /HOST/,
      );
    }
  });

  it("throws on an unknown OVID_AUTH_MODE", () => {
    expect(() => loadGatewayEnv({ OVID_AUTH_MODE: "magic" })).toThrow(
      /OVID_AUTH_MODE/,
    );
  });
});
