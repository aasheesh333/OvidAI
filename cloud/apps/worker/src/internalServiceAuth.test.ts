import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import type { FastifyReply, FastifyRequest } from "fastify";
import { describe, expect, it } from "vitest";
import { createInternalServiceAuth } from "./internalServiceAuth.js";

const INTERNAL_TOKEN = "worker-internal-token-for-tests";
const INVALID_TOKEN_RESPONSE = {
  error: { code: "unauthenticated", message: "Missing or invalid internal token." },
};
const MISSING_USER_ID_RESPONSE = {
  error: { code: "unauthenticated", message: "Missing x-ovid-user-id." },
};

interface TestReply {
  statusCode: number;
  payload: unknown;
  code(statusCode: number): TestReply;
  send(payload: unknown): TestReply;
}

function makeReply(): TestReply {
  const reply: TestReply = {
    statusCode: 200,
    payload: undefined,
    code(statusCode) {
      reply.statusCode = statusCode;
      return reply;
    },
    send(payload) {
      reply.payload = payload;
      return reply;
    },
  };
  return reply;
}

function run(headers: Record<string, string | undefined>) {
  const reply = makeReply();
  const handler = createInternalServiceAuth(INTERNAL_TOKEN);
  return handler(
    { headers } as unknown as FastifyRequest,
    reply as unknown as FastifyReply,
  ).then((result) => ({ result, reply }));
}

describe("createInternalServiceAuth", () => {
  it("accepts the correct token and a non-empty user id", async () => {
    const { result, reply } = await run({
      "x-ovid-internal-token": INTERNAL_TOKEN,
      "x-ovid-user-id": "user-123",
    });

    expect(result).toBeUndefined();
    expect(reply.statusCode).toBe(200);
    expect(reply.payload).toBeUndefined();
  });

  it.each([
    ["a missing token", { "x-ovid-user-id": "user-123" }],
    [
      "a wrong token of the same length",
      {
        "x-ovid-internal-token": `x${INTERNAL_TOKEN.slice(1)}`,
        "x-ovid-user-id": "user-123",
      },
    ],
    [
      "a wrong token of a different length",
      {
        "x-ovid-internal-token": "wrong",
        "x-ovid-user-id": "user-123",
      },
    ],
    [
      "the raw SHA-256 digest of the correct token",
      {
        "x-ovid-internal-token": createHash("sha256").update(INTERNAL_TOKEN).digest("hex"),
        "x-ovid-user-id": "user-123",
      },
    ],
  ])("rejects %s with the exact 401 envelope", async (_name, headers) => {
    const { result, reply } = await run(headers);

    expect(result).toBe(reply);
    expect(reply.statusCode).toBe(401);
    expect(reply.payload).toEqual(INVALID_TOKEN_RESPONSE);
  });

  it("rejects a valid token without a user id using the exact 401 envelope", async () => {
    const { result, reply } = await run({
      "x-ovid-internal-token": INTERNAL_TOKEN,
    });

    expect(result).toBe(reply);
    expect(reply.statusCode).toBe(401);
    expect(reply.payload).toEqual(MISSING_USER_ID_RESPONSE);
  });

  it("uses timingSafeEqual on hashes and never compares the raw token", () => {
    const source = readFileSync(new URL("./internalServiceAuth.ts", import.meta.url), "utf8");

    expect(source).toContain("timingSafeEqual");
    expect(source).toMatch(/createHash\(["']sha256["']\)/);
    expect(source).not.toMatch(/token\s*!==\s*internalToken/);
  });
});
