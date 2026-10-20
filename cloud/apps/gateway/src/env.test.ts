import { describe, expect, it } from "vitest";

import { loadGatewayEnv } from "./env.js";

const SECRET = "w12-env-signing-secret-at-least-32-bytes!!";

describe("gateway env — W12 CDN knobs", () => {
  it("is disabled when OVID_CDN_BASE_URL is unset (no boot failure)", () => {
    const env = loadGatewayEnv({ OVID_AUTH_MODE: "test" });
    expect(env.cdn).toBeUndefined();
  });

  it("loads the CDN config when the base URL and secret are set", () => {
    const env = loadGatewayEnv({
      OVID_AUTH_MODE: "test",
      OVID_CDN_BASE_URL: "https://cdn.ovidsi.com/",
      OVID_CDN_SIGNING_SECRET: SECRET,
      OVID_CDN_TTL_SECONDS: "120",
    });
    expect(env.cdn).toEqual({
      baseUrl: "https://cdn.ovidsi.com",
      secret: SECRET,
      ttlSeconds: 120,
    });
  });

  it("fails loudly on a partial/malformed CDN config", () => {
    expect(() =>
      loadGatewayEnv({
        OVID_AUTH_MODE: "test",
        OVID_CDN_BASE_URL: "https://cdn.ovidsi.com",
      }),
    ).toThrow(/OVID_CDN_SIGNING_SECRET/);
    expect(() =>
      loadGatewayEnv({
        OVID_AUTH_MODE: "test",
        OVID_CDN_BASE_URL: "not-a-url",
        OVID_CDN_SIGNING_SECRET: SECRET,
      }),
    ).toThrow(/OVID_CDN_BASE_URL/);
  });
});
