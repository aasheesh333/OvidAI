import { describe, expect, it } from "vitest";
import {
  createSuspensionMailer,
  createSuspensionMailerFromEnv,
} from "./suspensionMailer.js";

const INPUT = {
  uid: "uid-suspension",
  blockId: "anomaly:uid-suspension:123:network_fanout",
  registeredEmail: "registered@example.test",
} as const;

function response(status: number, body = "{}"): Response {
  return new Response(body, {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("SuspensionMailer", () => {
  it("is honestly not_configured without provider configuration and performs no fetch", async () => {
    let calls = 0;
    const mailer = createSuspensionMailer({
      fetchImpl: async () => {
        calls += 1;
        return response(200);
      },
    });

    await expect(mailer.send(INPUT)).resolves.toBe("not_configured");
    expect(calls).toBe(0);
  });

  it("sends a plain suspension notice only to the registered account email", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const mailer = createSuspensionMailer({
      apiKey: "test-provider-secret",
      from: "Ovid Si <security@ovid.example>",
      fetchImpl: async (url, init) => {
        calls.push({ url: String(url), init: init! });
        return response(200, JSON.stringify({ id: "provider-id-must-not-escape" }));
      },
    });

    await expect(mailer.send(INPUT)).resolves.toBe("sent");
    expect(calls).toHaveLength(1);
    const call = calls[0]!;
    expect(call.url).toBe("https://api.resend.com/emails");
    expect(call.init.method).toBe("POST");
    const headers = new Headers(call.init.headers);
    expect(headers.get("authorization")).toBe("Bearer test-provider-secret");
    expect(headers.get("idempotency-key")).toBe(INPUT.blockId);
    const body = JSON.parse(String(call.init.body)) as Record<string, unknown>;
    expect(body).toMatchObject({
      from: "Ovid Si <security@ovid.example>",
      to: [INPUT.registeredEmail],
      subject: expect.stringContaining("suspended"),
    });
    expect(body.text).toEqual(expect.stringContaining("unusual network activity"));
    expect(body.html).toBeUndefined();
    expect(JSON.stringify(body)).not.toContain("other@example.test");
  });

  it("uses the same stable provider idempotency key on a replay", async () => {
    const idempotencyKeys: Array<string | null> = [];
    const mailer = createSuspensionMailer({
      apiKey: "test-provider-secret",
      from: "security@ovid.example",
      fetchImpl: async (_url, init) => {
        idempotencyKeys.push(new Headers(init?.headers).get("idempotency-key"));
        return response(200);
      },
    });

    await expect(mailer.send(INPUT)).resolves.toBe("sent");
    await expect(mailer.send(INPUT)).resolves.toBe("sent");
    expect(idempotencyKeys).toEqual([INPUT.blockId, INPUT.blockId]);
  });

  it("sanitizes a provider rejection and never returns its raw payload", async () => {
    const secret = "sk_live_provider_canary_9f3e";
    const mailer = createSuspensionMailer({
      apiKey: "test-provider-secret",
      from: "security@ovid.example",
      fetchImpl: async () => response(403, JSON.stringify({ error: secret })),
    });

    const outcome = await mailer.send(INPUT);
    expect(outcome).toBe("failed");
    expect(JSON.stringify({ outcome })).not.toContain(secret);
  });

  it("sanitizes a transport failure", async () => {
    const secret = "raw socket payload with provider secret";
    const mailer = createSuspensionMailer({
      apiKey: "test-provider-secret",
      from: "security@ovid.example",
      fetchImpl: async () => {
        throw new Error(secret);
      },
    });

    const outcome = await mailer.send(INPUT);
    expect(outcome).toBe("failed");
    expect(JSON.stringify({ outcome })).not.toContain(secret);
  });

  it.each([null, "", "not-an-email", "two@example.test other@example.test"])(
    "never guesses a destination for invalid registered email %s",
    async (registeredEmail) => {
      let calls = 0;
      const mailer = createSuspensionMailer({
        apiKey: "test-provider-secret",
        from: "security@ovid.example",
        fetchImpl: async () => {
          calls += 1;
          return response(200);
        },
      });

      await expect(mailer.send({ ...INPUT, registeredEmail })).resolves.toBe(
        "not_configured",
      );
      expect(calls).toBe(0);
    },
  );

  it("loads provider configuration from the environment without sending at construction", () => {
    let calls = 0;
    const mailer = createSuspensionMailerFromEnv(
      {
        OVID_RESEND_API_KEY: "configured-secret",
        OVID_SUSPENSION_FROM_EMAIL: "security@ovid.example",
      },
      async () => {
        calls += 1;
        return response(200);
      },
    );
    expect(calls).toBe(0);
    expect(mailer).toBeDefined();
  });
});
