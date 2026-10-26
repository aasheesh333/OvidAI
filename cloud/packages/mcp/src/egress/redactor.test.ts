import { describe, expect, it } from "vitest";
import { createSecretRedactor } from "./redactor.js";

const CANARY = "sk-live/Canary +?=本";
const REDACTED = "[REDACTED]";

describe("createSecretRedactor", () => {
  it("redacts exact, URL-encoded, JSON-escaped, and base64 forms of secret values", () => {
    const redactor = createSecretRedactor();
    const encoded = encodeURIComponent(CANARY);
    const jsonEscaped = JSON.stringify(CANARY).slice(1, -1);
    const base64 = Buffer.from(CANARY).toString("base64");
    const input = `raw=${CANARY} encoded=${encoded} json="${jsonEscaped}" basic=${base64}`;
    const output = redactor.text(input, [CANARY]);
    expect(output).not.toContain(CANARY);
    expect(output).not.toContain(encoded);
    expect(output).not.toContain(jsonEscaped);
    expect(output).not.toContain(base64);
    expect(output).toContain(REDACTED);
  });

  it("redacts authorization, cookie, api-key, query, form, and signed-URL values even without a secret list", () => {
    const redactor = createSecretRedactor();
    const input = [
      "Authorization: Bearer auth-canary",
      "Cookie: session=cookie-canary",
      "x-api-key: header-canary",
      "https://api.example/items?api_key=query-canary&ok=1",
      "client_secret=form-canary&code_verifier=verifier-canary",
      "https://bucket.example/a?X-Amz-Credential=cred-canary&X-Amz-Signature=signed-canary",
    ].join("\n");
    const output = redactor.text(input);
    for (const canary of [
      "auth-canary",
      "cookie-canary",
      "header-canary",
      "query-canary",
      "form-canary",
      "verifier-canary",
      "cred-canary",
      "signed-canary",
    ]) {
      expect(output).not.toContain(canary);
    }
    expect(output).toContain("ok=1");
  });

  it("redacts secrets echoed in paths, base URLs, JSON text, and upstream errors", () => {
    const redactor = createSecretRedactor();
    const base = "https://tenant-secret.example/v1";
    const token = "path-secret-9";
    const upstream = `Error: GET ${base}/bot${token}/getMe failed with {"access_token":"${token}"}\n    at provider.js:9:1`;
    const output = redactor.text(upstream, [base, token]);
    expect(output).not.toContain(base);
    expect(output).not.toContain(token);
    expect(output).not.toContain("tenant-secret");
    const error = redactor.error(new Error(upstream), [base, token]);
    expect(error.message).not.toContain(base);
    expect(error.message).not.toContain(token);
    expect(error.stack).toBeUndefined();
    expect(error.cause).toBeUndefined();
  });

  it("projects nested JSON without retaining secret-bearing keys or values", () => {
    const redactor = createSecretRedactor();
    const projected = redactor.json(
      {
        ok: true,
        nested: {
          authorization: "Bearer nested-canary",
          cookie: "a=b",
          url: "https://x.example/?access_token=url-canary&safe=yes",
          echoed: "prefix exact-canary suffix",
        },
        list: [{ refresh_token: "refresh-canary" }, "exact-canary"],
      },
      ["exact-canary"],
    );
    const serialized = JSON.stringify(projected);
    for (const canary of ["nested-canary", "url-canary", "refresh-canary", "exact-canary", "a=b"]) {
      expect(serialized).not.toContain(canary);
    }
    expect(serialized).toContain("safe=yes");
    expect(projected.ok).toBe(true);
  });

  it("keeps JSON parseable when a credential value appears inside a key", () => {
    const redactor = createSecretRedactor();
    // A short token is the hostile case: substring replacement in a key would
    // produce `{"commen[REDACTED]s":[]}` and break every downstream parser.
    const projected = redactor.json({ comments: [], id: "1" }, ["t"]);
    const roundTripped = JSON.parse(JSON.stringify(projected)) as Record<string, unknown>;
    // The key containing the token is replaced whole, so the document stays
    // valid JSON instead of becoming `{"commen[REDACTED]s":[]}`.
    expect(roundTripped.id).toBe("1");
    expect(Object.keys(roundTripped)).toHaveLength(2);
    expect(Object.keys(roundTripped).join(" ")).not.toContain("commen");
  });

  it("replaces a whole key that does contain the credential", () => {
    const redactor = createSecretRedactor();
    const projected = redactor.json({ "prefix-tenant-secret-suffix": 1, safe: 2 }, ["tenant-secret"]);
    const keys = Object.keys(projected);
    expect(keys).toContain("safe");
    expect(keys.join(" ")).not.toContain("tenant-secret");
    expect(JSON.parse(JSON.stringify(projected))).toEqual(projected);
  });

  it("bounds hostile recursive input instead of recursing forever", () => {
    const redactor = createSecretRedactor();
    const cyclic: Record<string, unknown> = { password: "cycle-canary" };
    cyclic.self = cyclic;
    const projected = redactor.json(cyclic);
    expect(JSON.stringify(projected)).not.toContain("cycle-canary");
  });
});
