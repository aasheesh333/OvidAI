import { describe, expect, it } from "vitest";

import { cookieDomainMatchesOrigin, formatCookieForModel } from "./cookiePolicy.js";

describe("browser cookie policy", () => {
  it("redacts the cookie value from model-facing output", () => {
    const out = formatCookieForModel("login_tok", "supersecret-session-token");
    expect(out).toBe("login_tok=<redacted> (25 chars)");
    expect(out).not.toContain("supersecret");
  });

  it("binds a domain= write to the exact active origin (no cookie tossing)", () => {
    expect(cookieDomainMatchesOrigin("https://app.bank.test", "app.bank.test")).toBe(true);
    expect(cookieDomainMatchesOrigin("https://app.bank.test", ".app.bank.test")).toBe(true);
    expect(cookieDomainMatchesOrigin("https://app.bank.test", "bank.test")).toBe(false);
    expect(cookieDomainMatchesOrigin("https://app.bank.test", "evil.test")).toBe(false);
    expect(cookieDomainMatchesOrigin("https://app.bank.test", ".other.test")).toBe(false);
  });

  it("rejects a non-http origin", () => {
    expect(cookieDomainMatchesOrigin("about:blank", "app.bank.test")).toBe(false);
  });
});
