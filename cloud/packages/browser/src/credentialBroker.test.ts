import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { chromium, type Browser } from "playwright-core";

import { ensureSession } from "./sessionOps.js";
import {
  BrowserCredentialBroker,
  parseCredentialOrigin,
  type CredentialUseApprover,
} from "./credentialBroker.js";
import {
  CREDENTIAL_SENTINEL,
  createCredentialFixture,
  type CredentialFixture,
} from "./test/credentialFixture.js";
import { startCredentialHttpsFixture, type CredentialHttpsFixture } from "./test/httpsFixture.js";

function approver(fixture: CredentialFixture, decision: "allow" | "deny" = "allow"): CredentialUseApprover {
  return {
    async approve(input) {
      fixture.approvals.push(input as unknown as Record<string, unknown>);
      return decision;
    },
  };
}

function broker(fixture: CredentialFixture, submitTimeoutMs = 1_000): BrowserCredentialBroker {
  return new BrowserCredentialBroker({
    ...fixture.deps,
    credentials: fixture.credentials,
    operations: fixture.operations,
    submitTimeoutMs,
  });
}

function login(
  fixture: CredentialFixture,
  decision: "allow" | "deny" = "allow",
  submitTimeoutMs = 1_000,
) {
  return broker(fixture, submitTimeoutMs).login({
    ctx: fixture.ctx,
    credentialId: fixture.credential.id,
    approver: approver(fixture, decision),
    signal: fixture.controller.signal,
  });
}

function expectSecretHygiene(fixture: CredentialFixture, result: unknown): void {
  const encoded = encodeURIComponent(CREDENTIAL_SENTINEL);
  for (const value of [
    result,
    fixture.logs,
    fixture.session.console,
    fixture.session.network,
    fixture.session.dialogs,
    fixture.session.popups,
  ]) {
    const serialized = JSON.stringify(value);
    expect(serialized).not.toContain(CREDENTIAL_SENTINEL);
    expect(serialized).not.toContain(encoded);
  }
}

describe("parseCredentialOrigin", () => {
  it.each([
    ["https://example.com", "https://example.com"],
    ["https://example.com/", "https://example.com"],
    ["HTTPS://EXAMPLE.COM:443/", "https://example.com"],
    ["https://example.com:8443", "https://example.com:8443"],
    ["https://127.0.0.1:443/", "https://127.0.0.1"],
  ])("canonicalizes exact HTTPS origin %s", (input, expected) => {
    expect(parseCredentialOrigin(input)).toBe(expected);
  });

  it.each([
    "http://example.com",
    "example.com",
    "https://user@example.com",
    "https://user:pass@example.com",
    "https://@example.com",
    "https://example.com/login",
    "https://example.com/login/..",
    "https://example.com/.",
    "https://example.com/./",
    "https://example.com/%2e%2e",
    "https://example.com//",
    "https:example.com",
    "https://example.com/?next=/login",
    "https://example.com?",
    "https://example.com/#fragment",
    "https://example.com#",
    "https://example.com:0",
    "https://example.com:65536",
    "https://example.com:not-a-port",
    "https://",
    "",
  ])("rejects non-origin or ambiguous credential site %s", (input) => {
    expect(parseCredentialOrigin(input)).toBeNull();
  });
});

describe("BrowserCredentialBroker (real Chromium + HTTPS)", () => {
  let browser: Browser;
  let https: CredentialHttpsFixture;
  const fixtures: CredentialFixture[] = [];

  beforeAll(async () => {
    https = await startCredentialHttpsFixture();
    browser = await chromium.launch({
      headless: true,
      args: ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"],
    });
  }, 30_000);

  afterAll(async () => {
    await browser.close();
    await https.close();
  });

  afterEach(async () => {
    for (const fixture of fixtures.splice(0)) await fixture.close();
    https.posts.length = 0;
    https.otherPosts.length = 0;
  });

  async function fixture(path = "/login", site?: string): Promise<CredentialFixture> {
    const value = await createCredentialFixture({ browser, https, path, ...(site === undefined ? {} : { site }) });
    fixtures.push(value);
    return value;
  }

  it("fill → submit → clear performs one approved exact-origin POST and never claims verified login", async () => {
    const f = await fixture();
    const result = await login(f);

    expect(result).toEqual({
      status: "submitted",
      code: "submitted_unverified",
      message: "Credentials were submitted; login success was not verified.",
    });
    expect(f.resolutions).toEqual([{ userId: "u1", id: "cred-1" }]);
    expect(f.approvals).toHaveLength(1);
    expect(f.approvals[0]).toMatchObject({
      userId: "u1",
      sessionId: "chat-1",
      runId: "run-1",
      credentialId: "cred-1",
      origin: https.origin,
    });
    expect(https.posts).toHaveLength(1);
    const body = new URLSearchParams(https.posts[0]!.body);
    expect(body.get("username")).toBe("person@example.test");
    expect(body.get("password")).toBe(CREDENTIAL_SENTINEL);
    expect(https.otherPosts).toEqual([]);
    expect(await f.page.locator("#username").inputValue()).toBe("");
    expect(await f.page.locator("#password").inputValue()).toBe("");
    expect(f.page.isClosed()).toBe(false);
    expect(f.operations.isCredentialOperationActive("user-u1")).toBe(false);
    expectSecretHygiene(f, result);
  });

  it("removes broker markers so a second approved attempt succeeds on the unchanged page", async () => {
    const f = await fixture();
    const first = await login(f);
    const second = await login(f);

    expect(first.status).toBe("submitted");
    expect(second.status).toBe("submitted");
    expect(https.posts).toHaveLength(2);
    expect(f.resolutions).toHaveLength(2);
    expect(await f.page.locator("[data-ovid-credential-broker]").count()).toBe(0);
    expect(await f.page.locator("[data-ovid-credential-field]").count()).toBe(0);
    expectSecretHygiene(f, second);
  });

  it("removes broker markers after denial so a repeated denied attempt reaches approval again", async () => {
    const f = await fixture();
    const first = await login(f, "deny");
    const second = await login(f, "deny");

    expect(first).toMatchObject({ status: "refused", code: "credential_use_denied" });
    expect(second).toMatchObject({ status: "refused", code: "credential_use_denied" });
    expect(f.approvals).toHaveLength(2);
    expect(f.resolutions).toEqual([]);
    expect(await f.page.locator("[data-ovid-credential-broker]").count()).toBe(0);
    expect(await f.page.locator("[data-ovid-credential-field]").count()).toBe(0);
  });

  it("approval denial refuses before decryption or any page fill", async () => {
    const f = await fixture();
    const result = await login(f, "deny");
    expect(result).toMatchObject({ status: "refused", code: "credential_use_denied" });
    expect(f.resolutions).toEqual([]);
    expect(https.posts).toEqual([]);
    expect(await f.page.locator("#password").inputValue()).toBe("");
    expectSecretHygiene(f, result);
  });

  it("an always decision is not a per-use approval and is refused before decryption", async () => {
    const f = await fixture();
    const always: CredentialUseApprover = {
      async approve(input) {
        f.approvals.push(input as unknown as Record<string, unknown>);
        return "always" as "allow";
      },
    };
    const result = await broker(f).login({
      ctx: f.ctx,
      credentialId: "cred-1",
      approver: always,
      signal: f.controller.signal,
    });
    expect(result).toMatchObject({ status: "refused", code: "credential_use_denied" });
    expect(f.resolutions).toEqual([]);
    expectSecretHygiene(f, result);
  });

  it("rejects an invalid stored credential origin before approval or decryption", async () => {
    const f = await fixture("/login", "https://user:password@example.test/login?next=1");
    const result = await login(f);
    expect(result).toMatchObject({ status: "refused", code: "credential_origin_invalid" });
    expect(f.approvals).toEqual([]);
    expect(f.resolutions).toEqual([]);
    expectSecretHygiene(f, result);
  });

  it("rejects a different effective port before filling", async () => {
    const f = await fixture("/login", https.otherOrigin);
    const result = await login(f);
    expect(result).toMatchObject({ status: "refused", code: "credential_origin_mismatch" });
    expect(f.resolutions).toEqual([]);
    expect(https.posts).toEqual([]);
    expect(https.otherPosts).toEqual([]);
    expect(await f.page.locator("#password").inputValue()).toBe("");
    expectSecretHygiene(f, result);
  });

  it.each(["https://www.example.test", "https://alias.example.test"])(
    "does not treat %s as a www/subdomain alias for the live origin",
    async (site) => {
      const f = await fixture("/login", site);
      const result = await login(f);
      expect(result).toMatchObject({ status: "refused", code: "credential_origin_mismatch" });
      expect(f.resolutions).toEqual([]);
      expectSecretHygiene(f, result);
    },
  );

  it("rejects a cross-origin form action before filling", async () => {
    const f = await fixture(`/login?action=${encodeURIComponent(https.otherUrl("/steal"))}`);
    const result = await login(f);
    expect(result).toMatchObject({ status: "refused", code: "form_action_origin_mismatch" });
    expect(f.resolutions).toEqual([]);
    expect(https.otherPosts).toEqual([]);
    expect(await f.page.locator("#password").inputValue()).toBe("");
    expectSecretHygiene(f, result);
  });

  it("honors abort during asynchronous decryption before any fill or submission", async () => {
    const f = await fixture();
    await f.page.evaluate(() => {
      globalThis.document.querySelector("#username")?.addEventListener("input", () => {
        globalThis.document.body.dataset.usernameFilled = "true";
      });
    });
    const resolve = f.credentials.resolve.bind(f.credentials);
    f.credentials.resolve = async (userId, id) => {
      const credential = await resolve(userId, id);
      f.controller.abort();
      return credential;
    };
    const result = await login(f);

    expect(result).toMatchObject({ status: "refused", code: "credential_aborted" });
    expect(await f.page.locator("body").getAttribute("data-username-filled")).toBeNull();
    expect(https.posts).toEqual([]);
    expectSecretHygiene(f, result);
  });

  it("rechecks the live action after asynchronous decryption and before the first fill", async () => {
    const f = await fixture();
    await f.page.evaluate(() => {
      globalThis.document.querySelector("#username")?.addEventListener("input", () => {
        globalThis.document.body.dataset.usernameFilled = "true";
      });
    });
    const resolve = f.credentials.resolve.bind(f.credentials);
    f.credentials.resolve = async (userId, id) => {
      const credential = await resolve(userId, id);
      await f.page.evaluate((action) => {
        globalThis.document.querySelector("form")?.setAttribute("action", action);
      }, https.otherUrl("/steal"));
      return credential;
    };
    const result = await login(f);

    expect(result).toMatchObject({ status: "refused", code: "form_action_origin_mismatch" });
    expect(await f.page.locator("body").getAttribute("data-username-filled")).toBeNull();
    expect(https.posts).toEqual([]);
    expect(https.otherPosts).toEqual([]);
    expectSecretHygiene(f, result);
  });

  it("rechecks a form action changed by the password fill before submitting and clears both fields", async () => {
    const f = await fixture();
    await f.page.evaluate((action) => {
      const password = globalThis.document.querySelector("#password");
      password?.addEventListener("input", () => {
        globalThis.document.querySelector("form")?.setAttribute("action", action);
      });
    }, https.otherUrl("/steal"));
    const result = await login(f);

    expect(result).toMatchObject({ status: "refused", code: "form_action_origin_mismatch" });
    expect(https.posts).toEqual([]);
    expect(https.otherPosts).toEqual([]);
    expect(await f.page.locator("#username").inputValue()).toBe("");
    expect(await f.page.locator("#password").inputValue()).toBe("");
    expectSecretHygiene(f, result);
  });

  it("refuses an iframe context before approval or decryption", async () => {
    const f = await fixture("/login-iframe");
    const result = await login(f);
    expect(result).toMatchObject({ status: "refused", code: "unsupported_login_context" });
    expect(f.approvals).toEqual([]);
    expect(f.resolutions).toEqual([]);
    expectSecretHygiene(f, result);
  });

  it("refuses an existing second tab before approval or decryption", async () => {
    const f = await fixture();
    await f.context.newPage();
    const result = await login(f);
    expect(result).toMatchObject({ status: "refused", code: "unsupported_login_context" });
    expect(f.approvals).toEqual([]);
    expect(f.resolutions).toEqual([]);
    expectSecretHygiene(f, result);
  });

  it.each(["/login-mfa", "/login-captcha", "/login-sso", "/login-custom", "/login-get", "/login-target"])(
    "requires manual login for MFA/CAPTCHA/SSO/custom or unsafe form flow %s",
    async (path) => {
      const f = await fixture(path);
      const result = await login(f);
      expect(result.status).toBe(path === "/login-target" ? "refused" : "manual_login_required");
      expect(f.approvals).toEqual([]);
      expect(f.resolutions).toEqual([]);
      expect(https.posts).toEqual([]);
      expectSecretHygiene(f, result);
    },
  );

  it("refuses navigation caused by a fill, closes when field cleanup cannot be proven, and never submits", async () => {
    const f = await fixture();
    await f.page.evaluate(() => {
      globalThis.document.querySelector("#password")?.addEventListener("input", () => {
        globalThis.location.assign("/navigated");
      });
    });
    const result = await login(f);

    expect(result).toMatchObject({ status: "refused", code: "credential_navigation_refused" });
    expect(https.posts).toEqual([]);
    expect(f.page.isClosed()).toBe(true);
    expect(f.operations.isCredentialOperationActive("user-u1")).toBe(false);
    expectSecretHygiene(f, result);
  });

  it("never persists or replays a credential-bearing page URL through sessionOps lastUrls", async () => {
    const f = await fixture(`/login?credential=${encodeURIComponent(CREDENTIAL_SENTINEL)}`);
    f.ctx.sessionId = "user-credential-url-memory";
    f.session.sessionId = f.ctx.sessionId;
    const result = await login(f);
    expect(result.status).toBe("submitted");
    expect(f.page.url()).toContain(encodeURIComponent(CREDENTIAL_SENTINEL));

    const restoreRequests: string[] = [];
    const restoredHandle = {
      page: { goto: async (url: string) => restoreRequests.push(url) },
      context: {},
      touch() {},
    };
    const restoredSession = { sessionId: f.ctx.sessionId, userId: f.ctx.userId, handle: restoredHandle };
    f.deps.registry = {
      get: () => null,
      open: () => restoredSession,
      touch() {},
    } as never;
    f.deps.pool = { acquireLive: async () => restoredHandle } as never;
    await ensureSession(f.deps, f.ctx);

    expect(restoreRequests).toEqual([]);
    expect(JSON.stringify(restoreRequests)).not.toContain(CREDENTIAL_SENTINEL);
    expect(JSON.stringify(restoreRequests)).not.toContain(encodeURIComponent(CREDENTIAL_SENTINEL));
  });

  it("refuses a new tab caused by a fill, closes the popup, and verifies both main-frame fields clear", async () => {
    const f = await fixture();
    await f.page.evaluate(() => {
      globalThis.document.querySelector("#password")?.addEventListener("input", () => {
        globalThis.open("/after", "_blank");
      });
    });
    const result = await login(f);

    expect(result).toMatchObject({ status: "refused", code: "unsupported_login_context" });
    expect(https.posts).toEqual([]);
    expect(f.context.pages()).toEqual([f.page]);
    expect(await f.page.locator("#username").inputValue()).toBe("");
    expect(await f.page.locator("#password").inputValue()).toBe("");
    expectSecretHygiene(f, result);
  });

  it("returns submission_unknown for a redirect/fetch failure and still clears every field", async () => {
    const f = await fixture("/login?action=/redirect-session");
    const result = await login(f);
    expect(result).toMatchObject({ status: "submission_unknown", code: "submission_outcome_unknown" });
    expect(https.posts).toHaveLength(1);
    expect(await f.page.locator("#username").inputValue()).toBe("");
    expect(await f.page.locator("#password").inputValue()).toBe("");
    expectSecretHygiene(f, result);
  });

  it("aborts a timed-out broker-owned submission, reports uncertainty, and clears", async () => {
    const f = await fixture("/login?action=/slow-session");
    const result = await login(f, "allow", 30);
    expect(result).toMatchObject({ status: "submission_unknown", code: "submission_timeout" });
    expect(https.posts).toHaveLength(1);
    expect(await f.page.locator("#username").inputValue()).toBe("");
    expect(await f.page.locator("#password").inputValue()).toBe("");
    expect(f.operations.isCredentialOperationActive("user-u1")).toBe(false);
    expectSecretHygiene(f, result);
  });

  it("aborts an in-flight submission on the caller signal, reports uncertainty, and clears", async () => {
    const f = await fixture("/login?action=/slow-session");
    const pending = login(f);
    for (let i = 0; i < 100 && https.posts.length === 0; i += 1) {
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    expect(https.posts).toHaveLength(1);
    f.controller.abort();
    const result = await pending;
    expect(result).toMatchObject({ status: "submission_unknown", code: "submission_aborted" });
    expect(await f.page.locator("#username").inputValue()).toBe("");
    expect(await f.page.locator("#password").inputValue()).toBe("");
    expectSecretHygiene(f, result);
  });

  it("detects a connected clone replacing the original field during submission and closes with cleanup unproven", async () => {
    const f = await fixture("/login?action=/slow-session");
    await f.page.evaluate(() => {
      const password = globalThis.document.querySelector("#password") as HTMLInputElement;
      password.addEventListener("input", () => {
        globalThis.setTimeout(() => {
          const clone = password.cloneNode(true) as HTMLInputElement;
          clone.value = password.value;
          password.replaceWith(clone);
        }, 50);
      }, { once: true });
    });
    const result = await login(f);

    expect(https.posts).toHaveLength(1);
    expect(result).toMatchObject({ code: "credential_cleanup_unproven" });
    expect(f.page.isClosed()).toBe(true);
    expectSecretHygiene(f, result);
  });

  it("enumerates an unmarked live control containing the exact secret and closes instead of trusting original handles", async () => {
    const f = await fixture("/login?action=/slow-session");
    await f.page.evaluate(() => {
      const password = globalThis.document.querySelector("#password") as HTMLInputElement;
      password.addEventListener("input", () => {
        globalThis.setTimeout(() => {
          const clone = globalThis.document.createElement("input");
          clone.id = "late-secret-copy";
          clone.type = "text";
          clone.value = password.value;
          globalThis.document.body.append(clone);
        }, 50);
      }, { once: true });
    });
    const result = await login(f);

    expect(https.posts).toHaveLength(1);
    expect(result).toMatchObject({ code: "credential_cleanup_unproven" });
    expect(f.page.isClosed()).toBe(true);
    expectSecretHygiene(f, result);
  });

  it("refuses and closes when a nonthrowing cleanup setter synchronously appends an unmarked secret copy", async () => {
    const f = await fixture();
    await f.page.evaluate(() => {
      const password = globalThis.document.querySelector("#password") as HTMLInputElement;
      password.addEventListener("input", () => {
        let current = password.value;
        Object.defineProperty(password, "value", {
          configurable: true,
          get: () => current,
          set: (next: string) => {
            if (next !== "") {
              current = next;
              return;
            }
            const captured = current;
            const copy = globalThis.document.createElement("input");
            copy.id = "setter-secret-copy";
            copy.type = "text";
            copy.value = captured;
            // The new unmarked copy is absent from the cleanup snapshot, while
            // the original getter immediately reports an empty value.
            globalThis.document.body.append(copy);
            current = "";
            globalThis.console.log("setter-copy-created");
          },
        });
      }, { once: true });
    });
    const result = await login(f);

    expect(https.posts).toHaveLength(1);
    expect(result).toMatchObject({ code: "credential_cleanup_unproven" });
    expect(f.session.console.some((entry) => entry.text === "setter-copy-created")).toBe(true);
    expect(f.page.isClosed()).toBe(true);
    expectSecretHygiene(f, result);
  });

  it("refuses and closes when post-fill prototype tampering hides the retained native password", async () => {
    const f = await fixture();
    await f.page.evaluate(() => {
      const password = globalThis.document.querySelector("#password") as HTMLInputElement;
      password.addEventListener("input", () => {
        (globalThis as any).__capturedByPrototypeTamper = password.value;
        Object.defineProperty(globalThis.HTMLInputElement.prototype, "value", {
          configurable: true,
          get: () => "",
          set: () => {},
        });
        globalThis.console.log("prototype-value-tampered");
      }, { once: true });
    });
    const result = await login(f);

    expect(https.posts).toHaveLength(1);
    expect(f.session.console.some((entry) => entry.text === "prototype-value-tampered")).toBe(true);
    expect(result).toMatchObject({ code: "credential_cleanup_unproven" });
    expect(f.page.isClosed()).toBe(true);
    expectSecretHygiene(f, result);
  });

  it("requires a quiescent post-marker scan when MutationObserver appends a secret at the next microtask", async () => {
    const f = await fixture();
    await f.page.evaluate(() => {
      const password = globalThis.document.querySelector("#password") as HTMLInputElement;
      password.addEventListener("input", () => {
        const captured = password.value;
        const observer = new globalThis.MutationObserver((records) => {
          if (!records.some((record) => record.attributeName === "data-ovid-credential-field")) return;
          observer.disconnect();
          const copy = globalThis.document.createElement("input");
          copy.id = "observer-secret-copy";
          copy.type = "text";
          copy.value = captured;
          globalThis.document.body.append(copy);
          globalThis.console.log("observer-copy-created");
        });
        observer.observe(globalThis.document.documentElement, {
          attributes: true,
          attributeFilter: ["data-ovid-credential-field"],
          subtree: true,
        });
      }, { once: true });
    });
    const result = await login(f);

    expect(https.posts).toHaveLength(1);
    expect(f.session.console.some((entry) => entry.text === "observer-copy-created")).toBe(true);
    expect(result).toMatchObject({ code: "credential_cleanup_unproven" });
    expect(f.page.isClosed()).toBe(true);
    expectSecretHygiene(f, result);
  });

  it("repeats cleanup after a field clear error and closes the page when cleanup cannot be proven", async () => {
    const f = await fixture();
    await f.page.evaluate(() => {
      const password = globalThis.document.querySelector("#password") as HTMLInputElement;
      password.addEventListener("input", () => {
        const current = password.value;
        Object.defineProperty(password, "value", {
          configurable: true,
          get: () => current,
          set: () => {
            throw new Error(`fixture cleanup failure ${current}`);
          },
        });
      }, { once: true });
    });
    const result = await login(f);

    expect(result).toMatchObject({ status: "submitted", code: "submitted_unverified" });
    expect(https.posts).toHaveLength(1);
    expect(f.page.isClosed()).toBe(true);
    expect(f.logs.length).toBeGreaterThan(0);
    expectSecretHygiene(f, result);
  });

  it("keeps delayed records and Error message/stack redacted after the broker returns without retaining raw secret references", async () => {
    const f = await fixture();
    const encoded = encodeURIComponent(CREDENTIAL_SENTINEL);
    expect(encoded).not.toBe(CREDENTIAL_SENTINEL);
    const result = await login(f);
    expect(result.status).toBe("submitted");

    // These emissions happen after the old implementation restored array.push
    // and cleared its raw secret strings, reproducing the detached-emitter leak.
    await f.page.evaluate(async (value) => {
      globalThis.console.log(`delayed console ${value}`);
      await globalThis.fetch(`/after?delayed=${encodeURIComponent(value)}`);
      globalThis.open(`/after?popup=${encodeURIComponent(value)}`, "_blank");
    }, CREDENTIAL_SENTINEL);
    for (let i = 0; i < 100 && !f.session.network.some((entry) => entry.url.includes("delayed=")); i += 1) {
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    f.session.dialogs.push({
      id: "delayed-dialog",
      type: "alert",
      message: `dialog ${CREDENTIAL_SENTINEL}`,
      defaultValue: CREDENTIAL_SENTINEL,
      heldAt: Date.now(),
      resolve() {},
    });
    f.session.popups.push({ url: `https://fixture.invalid/${encoded}`, openedAt: Date.now() });
    const error = Object.assign(new Error(`message ${CREDENTIAL_SENTINEL}`), {
      stack: `Error: ${CREDENTIAL_SENTINEL}\n    at https://fixture.invalid/${encoded}`,
      detail: { requestBody: `password=${encoded}` },
    });
    f.session.console.push(error as never);

    expectSecretHygiene(f, result);
    const sanitizedError = f.session.console.at(-1) as unknown as Record<string, unknown>;
    expect(sanitizedError.message).toBe("message [credential-redacted]");
    expect(String(sanitizedError.stack)).toContain("[credential-redacted]");
    expect(JSON.stringify(sanitizedError)).toContain("requestBody");
    expect(JSON.stringify(sanitizedError)).toContain("[credential-redacted]");
    expect(JSON.stringify(f.session.network)).toContain("delayed=");
    expect(JSON.stringify(f.session.dialogs)).toContain("[credential-redacted]");
    expect(JSON.stringify(f.session.popups)).toContain("[credential-redacted]");
  });

  it("redacts exact and URL-encoded secrets from scoped outputs, errors, logs, URLs and event/network records", async () => {
    const f = await fixture();
    await f.page.evaluate(() => {
      globalThis.document.querySelector("#password")?.addEventListener("input", (event) => {
        const value = (event.currentTarget as HTMLInputElement).value;
        globalThis.console.log(`fixture credential ${value}`);
        void globalThis.fetch(`/after?credential=${encodeURIComponent(value)}`).catch(() => {});
      });
    });
    (f.session.network as unknown as Array<Record<string, unknown>>).push({
      url: `https://fixture.invalid/${CREDENTIAL_SENTINEL}`,
      postData: `password=${CREDENTIAL_SENTINEL}`,
    });
    const result = await login(f);

    expect(result.status).toBe("submitted");
    expectSecretHygiene(f, result);
    expect(JSON.stringify(f.session.network)).toContain("[credential-redacted]");
  });
});
