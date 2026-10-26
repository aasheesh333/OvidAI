import { describe, expect, it } from "vitest";
import type { Db } from "@ovid/db";
import type { QueueServices } from "@ovid/queue";
import type { FastifyRequest } from "fastify";
import { buildGateway, sanitizeRequestLogUrl } from "./app.js";
import {
  createGatewayObservabilityComposition,
} from "./observabilityComposition.js";
import {
  redactSensitiveText,
  safeLogRecord,
} from "../../../packages/shared/src/observability.js";
import { noopEvents, stubKeys, stubMint, stubSystemBus, stubTickets, stubVerifier } from "./test/stubs.js";

/**
 * Hostile-input redaction matrix.
 *
 * Each canary is a real credential SHAPE, not a random string: a bearer token,
 * an R2 presigned URL, a GitHub PAT, and a JWT. Every sink the backend owns is
 * checked — the composed metric sample, the composed log record, the shared
 * last-resort text redactor, and the HTTP access log the gateway actually
 * writes (pino via buildGateway({ logger })).
 */

const BEARER = "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyLTEifQ.sig";
const R2_SIGNED =
  "https://ovid-prod.r2.cloudflarestorage.com/users/u1/file.pdf?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20261026%2Fauto%2Fs3%2Faws4_request&X-Amz-Signature=deadbeefcafebabe";
const GITHUB_PAT = "ghp_AbCdEf0123456789AbCdEf0123456789AbCd";
const JWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1MSJ9.c2lnbmF0dXJl";
const PROMPT = "system: you are Ovid. user: my private medical history";

const HOSTILE: ReadonlyArray<{ label: string; value: string }> = [
  { label: "bearer token", value: BEARER },
  { label: "R2 presigned URL", value: R2_SIGNED },
  { label: "GitHub PAT", value: GITHUB_PAT },
  { label: "JWT", value: JWT },
  { label: "prompt body", value: PROMPT },
];

function harness() {
  const metrics: unknown[] = [];
  const logs: unknown[] = [];
  const gateway = createGatewayObservabilityComposition({
    exporter: {
      metric(sample) {
        metrics.push(sample);
      },
      log(record) {
        logs.push(record);
      },
    },
  });
  return { gateway, metrics, logs };
}

function assertAbsent(sink: unknown, canaries: readonly { label: string; value: string }[]): void {
  const text = JSON.stringify(sink) ?? "";
  for (const { label, value } of canaries) {
    // The raw value, and the distinguishing substring of it, must both be gone.
    expect(text, `${label} reached the sink`).not.toContain(value);
  }
}

describe("observability redaction matrix — composed sinks", () => {
  it("never forwards a hostile value attached to an unknown field of a metric or log", () => {
    const { gateway, metrics, logs } = harness();

    for (const { value } of HOSTILE) {
      gateway.metric("connectors.health", 1, "gauge", {
        requestId: "request-1",
        // Unknown fields are dropped by the shared correlation allowlist.
        prompt: value,
        token: value,
        signedUrl: value,
        providerPayload: { raw: value },
      } as never);
      gateway.log({
        event: "provider.operation_completed",
        correlation: { requestId: "request-1" },
        outcome: "failed",
        reason: "upstream_unavailable",
        prompt: value,
        providerPayload: { raw: value },
        responseBody: value,
      });
    }

    assertAbsent(metrics, HOSTILE);
    assertAbsent(logs, HOSTILE);
    // The operational facts still made it through.
    expect(logs).toHaveLength(HOSTILE.length);
    expect((logs[0] as Record<string, unknown>).event).toBe("provider.operation_completed");
  });

  it("refuses a hostile value used AS a correlation id or a log code, and exports nothing", () => {
    const { gateway, metrics, logs } = harness();

    for (const { value } of HOSTILE) {
      expect(() => gateway.metric("admission.accepted", 1, "count", { runId: value })).toThrow();
      expect(() => gateway.log({ event: "admission.accepted", correlation: { runId: value } })).toThrow();
      expect(() => gateway.log({ event: value })).toThrow();
      expect(() => gateway.log({ event: "admission.accepted", reason: value })).toThrow();
      expect(() => gateway.log({ event: "admission.accepted", outcome: value })).toThrow();
    }

    expect(metrics).toEqual([]);
    expect(logs).toEqual([]);
  });

  it("keeps a metric label closed: an unregistered name cannot be minted to carry a secret", () => {
    const { gateway, metrics } = harness();
    for (const { value } of HOSTILE) {
      expect(() => gateway.metric(`prompt.${value}`, 1, "count")).toThrow("unknown metric");
    }
    expect(metrics).toEqual([]);
  });
});

describe("observability redaction matrix — shared text redactor", () => {
  it("removes every hostile shape from unavoidable legacy text", () => {
    const text = [
      `authorization: ${BEARER}`,
      `object: ${R2_SIGNED}`,
      `token ${GITHUB_PAT}`,
      `jwt=${JWT}`,
      `body: ${PROMPT}`,
    ].join("\n");
    const redacted = redactSensitiveText(text);

    expect(redacted).not.toContain("eyJhbGciOiJIUzI1NiJ9");
    expect(redacted).not.toContain("X-Amz-Signature");
    expect(redacted).not.toContain("deadbeefcafebabe");
    expect(redacted).not.toContain(GITHUB_PAT);
    expect(redacted).not.toContain(JWT);
    expect(redacted).toContain("[redacted]");
  });

  it("rejects rather than redacts when a secret is smuggled into a structured code", () => {
    for (const value of [BEARER, GITHUB_PAT, JWT, R2_SIGNED]) {
      expect(() => safeLogRecord({ event: value })).toThrow();
      expect(() => safeLogRecord({ event: "e", outcome: value })).toThrow();
      expect(() => safeLogRecord({ event: "e", reason: value })).toThrow();
    }
  });
});

describe("observability redaction matrix — HTTP access log", () => {
  const okDb = { $client: { unsafe: async () => [{ ok: 1 }] } } as unknown as Db;
  const queues = {
    agentRuns: {
      client: Promise.resolve({ ping: async () => "PONG" }),
      getWorkersCount: async () => 1,
    },
  } as unknown as QueueServices;

  function loggedLines(): { lines: string[]; app: ReturnType<typeof buildGateway> } {
    const lines: string[] = [];
    const app = buildGateway(
      {
        system: stubSystemBus(),
        db: okDb,
        queues,
        verifier: stubVerifier(),
        tickets: stubTickets(),
        keys: stubKeys(),
        mint: stubMint(),
        events: noopEvents,
      },
      {
        logger: {
          level: "info",
          stream: { write: (line: string) => lines.push(line) },
          serializers: {
            // A caller-supplied serializer must not become a bypass: the
            // gateway merges its own `req` over this one.
            req: (request: FastifyRequest) => ({
              method: request.method,
              url: request.url,
              headers: request.headers,
            }),
          },
        },
      },
    );
    return { lines, app };
  }

  it("strips the OAuth code/state and never writes request headers", async () => {
    const { lines, app } = loggedLines();
    try {
      await app.inject({
        method: "GET",
        url: `/cloud/v1/mcp/oauth/callback?state=${encodeURIComponent(JWT)}&code=${encodeURIComponent(GITHUB_PAT)}`,
        headers: { authorization: BEARER, cookie: `session=${JWT}` },
      });
    } finally {
      await app.close();
    }

    const output = lines.join("\n");
    expect(output.length).toBeGreaterThan(0);
    expect(output).not.toContain(JWT);
    expect(output).not.toContain(GITHUB_PAT);
    expect(output).not.toContain("eyJhbGciOiJIUzI1NiJ9");
    expect(output).toContain("state=[redacted]");
    expect(output).toContain("code=[redacted]");
    // Path telemetry survives so the log is still useful.
    expect(output).toContain("/cloud/v1/mcp/oauth/callback");
  });

  it("redacts a share receipt token in the path and a signed URL in a query", () => {
    const share = sanitizeRequestLogUrl(`/s/${GITHUB_PAT}`);
    expect(share).toBe("/s/[redacted]");
    expect(share).not.toContain(GITHUB_PAT);

    const invite = sanitizeRequestLogUrl(`/s/${GITHUB_PAT}/invite-1`);
    expect(invite).toBe("/s/[redacted]/invite-1");

    const signed = sanitizeRequestLogUrl(
      `/cloud/v1/attachments/x?url=${encodeURIComponent(R2_SIGNED)}&token=${JWT}&limit=20`,
    );
    expect(signed).not.toContain("X-Amz-Signature");
    expect(signed).not.toContain(JWT);
    expect(signed).toContain("token=[redacted]");
    // Non-secret pagination telemetry is preserved.
    expect(signed).toContain("limit=20");
  });
});
