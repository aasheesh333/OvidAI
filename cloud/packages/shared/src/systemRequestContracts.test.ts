import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const canonicalUrl = new URL(
  "../contracts/fixtures/system-requests-v1.json",
  import.meta.url,
);
const webMirrorUrl = new URL(
  "../../../../../OvidWeb/web/test/fixtures/system-requests-v1.json",
  import.meta.url,
);
const flutterMirrorUrl = new URL(
  "../../../../../OvidFlutter/test/fixtures/system-requests-v1.json",
  import.meta.url,
);

const requestKeys = [
  "requestId",
  "userId",
  "sessionId",
  "runId",
  "kind",
  "safePayload",
  "sensitive",
  "status",
  "expiresAt",
  "response",
  "version",
] as const;
const responseKeys = [
  "requestId",
  "userId",
  "version",
  "response",
  "clientResponseId",
  "createdAt",
] as const;
const attemptKeys = ["requestId", "version", "response", "clientResponseId"] as const;

function fixture(): any {
  return JSON.parse(readFileSync(canonicalUrl, "utf8"));
}

async function contracts() {
  return import("./systemRequestContracts.js");
}

describe("canonical system request/response fixture", () => {
  it("parses complete pending approval and sensitive elicitation DTOs", async () => {
    const { systemRequestDtoSchema, systemRequestsFixtureV1Schema } = await contracts();
    const value = fixture();
    expect(value.contractVersion).toBe(1);
    expect(systemRequestsFixtureV1Schema.parse(value)).toEqual(value);

    const approval = value.requests.pendingApproval;
    const sensitive = value.requests.sensitiveElicitation;
    for (const request of [approval, sensitive]) {
      expect(Object.keys(request)).toEqual(requestKeys);
      expect(systemRequestDtoSchema.parse(request)).toEqual(request);
      expect(request.userId).toBe("user-fixture-system-requests");
      expect(request.sessionId).toMatch(/^[0-9a-f-]{36}$/);
      expect(request.runId).toMatch(/^[0-9a-f-]{36}$/);
      expect(request.status).toBe("pending");
      expect(request.response).toBeNull();
      expect(Number.isInteger(request.version) && request.version > 0).toBe(true);
    }
    expect(approval).toMatchObject({
      requestId: "system-request-approval-v1",
      kind: "approval",
      sensitive: false,
      version: 3,
      safePayload: { tool: "bash", preview: "pwd" },
    });
    expect(sensitive).toMatchObject({
      requestId: "system-request-elicitation-v1",
      kind: "elicitation",
      sensitive: true,
      safePayload: {
        message: "Enter your password",
        fields: [{ name: "password", title: "Password", type: "string" }],
        required: ["password"],
      },
    });
  });

  it("pins the response receipt and structurally identical replay", async () => {
    const {
      systemResponseAttemptSchema,
      systemResponseDtoSchema,
      systemRequestsFixtureV1Schema,
    } = await contracts();
    const value = systemRequestsFixtureV1Schema.parse(fixture());
    const receipt = value.responseReceipt;
    const replay = value.identicalReplay;

    expect(Object.keys(receipt)).toEqual(responseKeys);
    expect(systemResponseDtoSchema.parse(receipt)).toEqual(receipt);
    expect(receipt).toMatchObject({
      requestId: value.requests.pendingApproval.requestId,
      userId: value.requests.pendingApproval.userId,
      version: value.requests.pendingApproval.version,
      response: { approve: true, allowDependencyScripts: false },
      clientResponseId: "client-response-approval-v1",
    });
    expect(replay.receipt).toEqual(receipt);
    expect(Object.keys(replay.attempt)).toEqual(attemptKeys);
    expect(systemResponseAttemptSchema.parse(replay.attempt)).toEqual(replay.attempt);
    expect(replay.attempt.requestId).toBe(receipt.requestId);
    expect(replay.attempt.version).toBe(receipt.version);
    expect(replay.attempt.clientResponseId).toBe(receipt.clientResponseId);
    expect(replay.attempt.response).toEqual(receipt.response);
    expect(JSON.stringify(replay.attempt.response)).not.toBe(JSON.stringify(receipt.response));
  });

  it("pins a stale-version conflict without forging a response receipt", async () => {
    const { systemResponseAttemptSchema } = await contracts();
    const value = fixture();
    const conflict = value.versionConflict;
    expect(Object.keys(conflict)).toEqual(["attempt", "currentVersion", "error"]);
    expect(systemResponseAttemptSchema.parse(conflict.attempt)).toEqual(conflict.attempt);
    expect(conflict).toEqual({
      attempt: {
        requestId: value.requests.pendingApproval.requestId,
        version: 2,
        response: { approve: false },
        clientResponseId: "client-response-stale-v1",
      },
      currentVersion: value.requests.pendingApproval.version,
      error: {
        code: "version_conflict",
        message: "The system request version is stale.",
      },
    });
    expect(conflict.attempt.version).toBeLessThan(conflict.currentVersion);
    expect(Object.hasOwn(conflict, "receipt")).toBe(false);
  });

  it("keeps sensitive plaintext and response-wait settings out of the request fixture", () => {
    const raw = readFileSync(canonicalUrl, "utf8");
    const value = fixture();
    expect(value.requests.sensitiveElicitation.response).toBeNull();
    expect(raw).not.toMatch(/"(?:plaintext|plaintextSecret|secretValue|accessToken|refreshToken|apiKey)"\s*:/i);
    expect(raw).not.toMatch(/never-persist|hostile-storage|online-only-secret|0033-secret-canary/);
    expect(raw).not.toMatch(/-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----/);
    expect(raw).not.toMatch(/"responseWaitSeconds"\s*:/);
  });

  it("has byte-identical canonical, Web, and Flutter copies", () => {
    const canonical = readFileSync(canonicalUrl);
    expect(readFileSync(webMirrorUrl)).toEqual(canonical);
    expect(readFileSync(flutterMirrorUrl)).toEqual(canonical);
  });
});

describe("strict system request schemas", () => {
  it("rejects missing, malformed, and additive DTO fields", async () => {
    const { systemRequestDtoSchema, systemResponseAttemptSchema, systemResponseDtoSchema } =
      await contracts();
    const value = fixture();
    const request = value.requests.pendingApproval;
    const receipt = value.responseReceipt;
    const attempt = value.identicalReplay.attempt;

    for (const key of requestKeys) {
      const incomplete = { ...request };
      delete incomplete[key];
      expect(() => systemRequestDtoSchema.parse(incomplete), `missing ${key}`).toThrow();
    }
    for (const [schema, valid] of [
      [systemRequestDtoSchema, request],
      [systemResponseDtoSchema, receipt],
      [systemResponseAttemptSchema, attempt],
    ] as const) {
      expect(() => schema.parse({ ...valid, additiveUnknownField: true })).toThrow();
    }
    expect(() => systemRequestDtoSchema.parse({ ...request, kind: "unknown" })).toThrow();
    expect(() => systemRequestDtoSchema.parse({ ...request, status: "queued" })).toThrow();
    expect(() => systemRequestDtoSchema.parse({ ...request, version: 0 })).toThrow();
    expect(() => systemRequestDtoSchema.parse({ ...request, version: 1.5 })).toThrow();
    expect(() => systemRequestDtoSchema.parse({ ...request, safePayload: [] })).toThrow();
    expect(() => systemRequestDtoSchema.parse({ ...request, expiresAt: "tomorrow" })).toThrow();
    expect(() => systemResponseDtoSchema.parse({ ...receipt, createdAt: "tomorrow" })).toThrow();
    expect(() => systemResponseAttemptSchema.parse({ ...attempt, userId: "client-forged" })).toThrow();
    expect(() => systemResponseAttemptSchema.parse({ ...attempt, status: "resolved" })).toThrow();
  });

  it("accepts every approved kind/status but never a sensitive or pending plaintext response", async () => {
    const { systemRequestDtoSchema } = await contracts();
    const request = fixture().requests.pendingApproval;
    for (const kind of ["approval", "sampling", "elicitation"]) {
      expect(systemRequestDtoSchema.parse({ ...request, kind }).kind).toBe(kind);
    }
    for (const status of ["pending", "resolved", "expired", "cancelled"]) {
      expect(systemRequestDtoSchema.parse({ ...request, status }).status).toBe(status);
    }
    expect(() =>
      systemRequestDtoSchema.parse({
        ...request,
        kind: "elicitation",
        sensitive: true,
        response: { content: { password: "must-not-be-accepted" } },
      }),
    ).toThrow();
    expect(() =>
      systemRequestDtoSchema.parse({ ...request, response: { approve: true } }),
    ).toThrow();
  });

  it("exports the schemas from the shared package barrel", async () => {
    const direct = await contracts();
    const barrel = await import("./index.js");
    expect(barrel.systemRequestDtoSchema).toBe(direct.systemRequestDtoSchema);
    expect(barrel.systemResponseDtoSchema).toBe(direct.systemResponseDtoSchema);
    expect(barrel.systemRequestsFixtureV1Schema).toBe(direct.systemRequestsFixtureV1Schema);
  });
});
