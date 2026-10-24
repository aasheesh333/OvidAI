/**
 * Exact-origin, per-use credential login. This is deliberately a narrow broker:
 * one strict main-frame POST form, one approved credential, one broker-owned
 * submission, and verified field cleanup. Task 10 wraps every observation path.
 */

import { createHash, randomUUID } from "node:crypto";

import type { CDPSession, ElementHandle, Page } from "playwright-core";

import { BrowserOperationRefusal, type BrowserOperationCoordinator } from "./browserOperations.js";
import { purgeSessionUrlMemory, withSession } from "./sessionOps.js";
import type { SessionBrowser } from "./sessions.js";
import type {
  BrowserCredentialSecret,
  BrowserCredentialsPort,
  BrowserToolContext,
  BrowserToolsDeps,
} from "./tools/types.js";

const FORM_ATTRIBUTE = "data-ovid-credential-broker";
const FIELD_ATTRIBUTE = "data-ovid-credential-field";
const REDACTED = "[credential-redacted]";

function windowGuardKey(token: string): string {
  return `__ovid_credential_window_${token.replaceAll("-", "_")}`;
}

async function installWindowOpenGuard(page: Page, token: string): Promise<void> {
  await page.evaluate(
    ({ key, marker, formAttribute, fieldAttribute }) => {
      const g = globalThis as any;
      const form = g.document.querySelector(`form[${formAttribute}="${marker}"]`);
      const state = {
        original: g.open,
        attempted: false,
        form,
        username: form?.querySelector(`[${fieldAttribute}="username"]`) ?? null,
        password: form?.querySelector(`[${fieldAttribute}="password"]`) ?? null,
      };
      g[key] = state;
      g.open = () => {
        state.attempted = true;
        return null;
      };
    },
    {
      key: windowGuardKey(token),
      marker: token,
      formAttribute: FORM_ATTRIBUTE,
      fieldAttribute: FIELD_ATTRIBUTE,
    },
  );
}

export type CredentialLoginStatus = "submitted" | "manual_login_required" | "refused" | "submission_unknown";

export interface BrowserCredentialLoginResult {
  status: CredentialLoginStatus;
  code: string;
  message: string;
}

export interface BrokerToolContext extends BrowserToolContext {
  /** Canonical run id, supplied by the worker adapter for per-use approval. */
  runId?: string;
  /** The adapter forwards the run signal; direct callers may pass it separately. */
  signal?: AbortSignal;
}

export interface CredentialUseApproval {
  userId: string;
  /** The originating chat session, not the per-user browser key. */
  sessionId: string;
  runId: string;
  credentialId: string;
  origin: string;
  signal: AbortSignal;
}

export interface CredentialUseApprover {
  /** There is no persistent/always grant. Only the exact string "allow" authorizes one use. */
  approve(input: CredentialUseApproval): Promise<"allow" | "deny">;
}

export interface BrowserCredentialBrokerDeps extends BrowserToolsDeps {
  credentials: BrowserCredentialsPort;
  operations: BrowserOperationCoordinator;
  submitTimeoutMs?: number;
}

export interface BrowserCredentialLoginInput {
  ctx: BrokerToolContext;
  credentialId: string;
  approver: CredentialUseApprover;
  signal: AbortSignal;
}

function hasAuthorityUserinfo(value: string): boolean {
  const schemeEnd = value.indexOf("://");
  if (schemeEnd < 0) return false;
  const start = schemeEnd + 3;
  const suffix = value.slice(start);
  const end = suffix.search(/[\\/?#]/);
  return (end < 0 ? suffix : suffix.slice(0, end)).includes("@");
}

/**
 * Parse a stored credential site as an ORIGIN, not a login URL. Paths are not
 * accepted: callers must not silently turn a path-bearing site into broader
 * origin approval. Live page/action URLs use the separate origin extractor.
 */
export function parseCredentialOrigin(value: string): string | null {
  if (
    value.length === 0 ||
    value.trim() !== value ||
    value.includes("?") ||
    value.includes("#") ||
    hasAuthorityUserinfo(value)
  ) {
    return null;
  }
  const schemeEnd = value.indexOf("://");
  if (schemeEnd <= 0 || value.slice(0, schemeEnd).toLowerCase() !== "https") return null;
  const authorityAndPath = value.slice(schemeEnd + 3);
  const rawPathStart = authorityAndPath.search(/[\\/]/);
  // Check RAW input before URL normalization: /login/.., /./ and encoded dot
  // segments must not disappear into an apparently safe root pathname.
  if (rawPathStart >= 0 && authorityAndPath.slice(rawPathStart) !== "/") return null;
  try {
    const url = new URL(value);
    if (
      url.protocol !== "https:" ||
      url.hostname === "" ||
      url.username !== "" ||
      url.password !== "" ||
      url.search !== "" ||
      url.hash !== "" ||
      (url.pathname !== "" && url.pathname !== "/") ||
      url.port === "0"
    ) {
      return null;
    }
    return url.origin;
  } catch {
    return null;
  }
}

/** Live page and action URLs may carry paths/query; their effective origin is still exact. */
function liveHttpsOrigin(value: string): string | null {
  try {
    const url = new URL(value);
    if (
      url.protocol !== "https:" ||
      url.hostname === "" ||
      url.username !== "" ||
      url.password !== "" ||
      hasAuthorityUserinfo(value)
    ) {
      return null;
    }
    return url.origin;
  } catch {
    return null;
  }
}

function pageUrlOrNull(page: Page | null): string | null {
  return page?.url() ?? null;
}

function pageIsClosed(page: Page | null): boolean {
  return page === null || page.isClosed();
}

function result(status: CredentialLoginStatus, code: string, message: string): BrowserCredentialLoginResult {
  return { status, code, message };
}

function submitted(): BrowserCredentialLoginResult {
  return result(
    "submitted",
    "submitted_unverified",
    "Credentials were submitted; login success was not verified.",
  );
}

function refused(code: string, message: string): BrowserCredentialLoginResult {
  return result("refused", code, message);
}

function unknown(code: string, message: string): BrowserCredentialLoginResult {
  return result("submission_unknown", code, message);
}

class BrokerControl extends Error {
  readonly outcome: BrowserCredentialLoginResult;

  constructor(outcome: BrowserCredentialLoginResult) {
    super(outcome.code);
    this.name = "BrokerControl";
    this.outcome = outcome;
  }
}

function control(outcome: BrowserCredentialLoginResult): never {
  throw new BrokerControl(outcome);
}

function manualLogin(): never {
  control(
    result(
      "manual_login_required",
      "manual_login_required",
      "This site requires manual login or uses an unsupported authentication flow.",
    ),
  );
}

interface DomProof {
  ok: true;
  action: string;
}

interface DomRefusal {
  ok: false;
  code: "manual_login_required" | "unsupported_login_context" | "credential_form_changed";
}

interface LiveProof {
  action: string;
  initialUrl: string;
}

async function inspectDom(page: Page, token: string, initial: boolean): Promise<DomProof | DomRefusal> {
  return await page.evaluate(
    ({ formAttribute, fieldAttribute, marker, first }) => {
      const g = globalThis as any;
      const doc = g.document;
      const guardKey = `__ovid_credential_window_${marker.replaceAll("-", "_")}`;
      if (g[guardKey]?.attempted === true) return { ok: false, code: "unsupported_login_context" };
      if (doc === undefined || doc.forms.length !== 1) return { ok: false, code: "manual_login_required" };
      if (doc.scripts.length > 0) return { ok: false, code: "manual_login_required" };
      if (doc.querySelector("iframe,frame,object,embed") !== null) {
        return { ok: false, code: "unsupported_login_context" };
      }
      if (
        doc.querySelector(
          "[data-sitekey],[class*='captcha' i],[id*='captcha' i],[name*='otp' i],[name*='mfa' i]",
        ) !== null
      ) {
        return { ok: false, code: "manual_login_required" };
      }
      const form = doc.forms[0];
      const existingMarker = form.getAttribute(formAttribute);
      if (!first && existingMarker !== marker) return { ok: false, code: "credential_form_changed" };
      if (first && existingMarker !== null) return { ok: false, code: "credential_form_changed" };
      if (String(form.method).toLowerCase() !== "post") return { ok: false, code: "manual_login_required" };
      if (form.target !== "") return { ok: false, code: "unsupported_login_context" };
      if (
        form.enctype !== "" &&
        String(form.enctype).toLowerCase() !== "application/x-www-form-urlencoded"
      ) {
        return { ok: false, code: "manual_login_required" };
      }
      if (form.querySelector("[formaction]") !== null) return { ok: false, code: "manual_login_required" };
      if (form.querySelector("[formtarget]") !== null) {
        return { ok: false, code: "unsupported_login_context" };
      }
      if (doc.querySelector("a[href]") !== null) return { ok: false, code: "manual_login_required" };
      const allControls = Array.from(doc.querySelectorAll("button,input,textarea,select"));
      if (allControls.some((element: any) => !form.contains(element))) {
        return { ok: false, code: "manual_login_required" };
      }
      const withAttributes = [form, ...Array.from(form.querySelectorAll("*"))];
      for (const element of withAttributes) {
        for (const attribute of Array.from(element.attributes ?? [])) {
          if (String((attribute as any).name).toLowerCase().startsWith("on")) {
            return { ok: false, code: "manual_login_required" };
          }
        }
      }
      const inputs = Array.from(form.querySelectorAll("input"));
      const passwords = inputs.filter((input: any) => input.type === "password");
      const usernames = inputs.filter((input: any) => input.type === "text" || input.type === "email");
      const submitters = Array.from(form.querySelectorAll("button[type='submit'],input[type='submit']"));
      if (passwords.length !== 1 || usernames.length !== 1 || submitters.length !== 1) {
        return { ok: false, code: "manual_login_required" };
      }
      const allowed = new Set([passwords[0], usernames[0], ...submitters]);
      for (const control of Array.from(form.querySelectorAll("input,textarea,select,button"))) {
        const element = control as any;
        if (allowed.has(element)) continue;
        if (element.tagName === "INPUT" && element.type === "hidden" && element.name !== "") continue;
        return { ok: false, code: "manual_login_required" };
      }
      const username = usernames[0] as any;
      const password = passwords[0] as any;
      if (
        username.name === "" ||
        password.name === "" ||
        username.disabled ||
        password.disabled ||
        username.readOnly ||
        password.readOnly
      ) {
        return { ok: false, code: "manual_login_required" };
      }
      if (first) {
        form.setAttribute(formAttribute, marker);
        username.setAttribute(fieldAttribute, "username");
        password.setAttribute(fieldAttribute, "password");
      } else if (
        username.getAttribute(fieldAttribute) !== "username" ||
        password.getAttribute(fieldAttribute) !== "password"
      ) {
        return { ok: false, code: "credential_form_changed" };
      }
      const owner = g[guardKey];
      if (
        !first &&
        owner !== undefined &&
        (form !== owner.form || username !== owner.username || password !== owner.password)
      ) {
        return { ok: false, code: "credential_form_changed" };
      }
      return { ok: true, action: String(form.action) };
    },
    { formAttribute: FORM_ATTRIBUTE, fieldAttribute: FIELD_ATTRIBUTE, marker: token, first: initial },
  );
}

async function proveLiveForm(
  page: Page,
  session: SessionBrowser,
  origin: string,
  token: string,
  previous: LiveProof | null,
): Promise<LiveProof> {
  if (page.isClosed()) control(refused("unsupported_login_context", "The credential login page is not available."));
  const currentUrl = page.url();
  if (previous !== null && currentUrl !== previous.initialUrl) {
    control(
      refused(
        "credential_navigation_refused",
        "The page navigated during the credential operation; submission was refused.",
      ),
    );
  }
  if (
    session.tabs.length !== 1 ||
    session.tabs[0] !== page ||
    page.context().pages().length !== 1 ||
    page.frames().length !== 1 ||
    page.mainFrame().url() !== currentUrl
  ) {
    control(
      refused(
        "unsupported_login_context",
        "Credential login requires one main-frame page with no iframes or additional tabs.",
      ),
    );
  }
  if (liveHttpsOrigin(currentUrl) !== origin) {
    control(
      refused(
        "credential_origin_mismatch",
        "The live page origin does not exactly match the approved credential origin.",
      ),
    );
  }
  const inspected = await inspectDom(page, token, previous === null);
  // Navigation can commit while the DOM inspection protocol call is in flight.
  // Recheck before classifying a missing form as manual-only, so the security
  // refusal is not replaced by a less specific authentication-flow result.
  if (previous !== null && page.url() !== previous.initialUrl) {
    control(
      refused(
        "credential_navigation_refused",
        "The page navigated during the credential operation; submission was refused.",
      ),
    );
  }
  if (!inspected.ok) {
    if (inspected.code === "manual_login_required") manualLogin();
    control(
      refused(
        inspected.code,
        inspected.code === "credential_form_changed"
          ? "The login form changed during the credential operation."
          : "Credential login requires one main-frame page with no iframes or additional tabs.",
      ),
    );
  }
  let action: URL;
  try {
    action = new URL(inspected.action);
  } catch {
    control(refused("form_action_origin_mismatch", "The login form action is not a valid HTTPS URL."));
  }
  if (
    liveHttpsOrigin(action.toString()) !== origin ||
    action.username !== "" ||
    action.password !== "" ||
    action.hash !== ""
  ) {
    control(
      refused(
        "form_action_origin_mismatch",
        "The login form action does not match the approved credential origin.",
      ),
    );
  }
  if (previous !== null && action.toString() !== previous.action) {
    control(refused("form_action_changed", "The login form action changed before submission."));
  }
  return { action: action.toString(), initialUrl: currentUrl };
}

interface SecretFingerprint {
  length: number;
  digest: string;
}

class ScopedSecretRedactor {
  private static readonly instances = new WeakMap<SessionBrowser, ScopedSecretRedactor>();

  static forSession(session: SessionBrowser): ScopedSecretRedactor {
    const existing = ScopedSecretRedactor.instances.get(session);
    if (existing !== undefined) return existing;
    const created = new ScopedSecretRedactor();
    ScopedSecretRedactor.instances.set(session, created);
    return created;
  }

  private secrets = new Set<string>();
  private fingerprints = new Map<string, SecretFingerprint>();
  private attachments: Array<{ array: any[]; original: (... items: any[]) => number; wrapped: (... items: any[]) => number }> = [];

  addSecrets(secrets: readonly string[]): void {
    for (const secret of secrets) if (secret !== "") this.secrets.add(secret);
  }

  private variants(): Set<string> {
    const variants = new Set<string>();
    for (const secret of this.secrets) {
      variants.add(secret);
      try {
        variants.add(encodeURIComponent(secret));
        variants.add(encodeURI(secret));
        variants.add(new URLSearchParams({ value: secret }).get("value") ?? secret);
      } catch {
        // The exact raw secret still has a fingerprint if encoding is impossible.
      }
    }
    return variants;
  }

  private sealRawSecrets(): void {
    for (const variant of this.variants()) {
      const digest = createHash("sha256").update(variant, "utf8").digest("hex");
      this.fingerprints.set(`${variant.length}:${digest}`, { length: variant.length, digest });
    }
    // Only one-way length/digest fingerprints remain for delayed emitters. The
    // raw credential strings are released; no memory-zeroization is claimed.
    this.secrets.clear();
  }

  private fingerprintText(value: string): string {
    if (this.fingerprints.size === 0 || value === "") return value;
    const patterns = [...this.fingerprints.values()].sort((a, b) => b.length - a.length);
    let output = "";
    let index = 0;
    while (index < value.length) {
      let matched = false;
      for (const pattern of patterns) {
        const end = index + pattern.length;
        if (end > value.length) continue;
        const candidate = value.slice(index, end);
        const digest = createHash("sha256").update(candidate, "utf8").digest("hex");
        if (digest === pattern.digest) {
          output += REDACTED;
          index = end;
          matched = true;
          break;
        }
      }
      if (!matched) {
        output += value[index];
        index += 1;
      }
    }
    return output;
  }

  text(value: string): string {
    let redacted = value;
    for (const variant of [...this.variants()].sort((a, b) => b.length - a.length)) {
      if (variant !== "") redacted = redacted.split(variant).join(REDACTED);
    }
    return this.fingerprintText(redacted);
  }

  value(input: unknown, seen = new WeakSet<object>()): unknown {
    if (typeof input === "string") return this.text(input);
    if (typeof input === "function") return "[credential-function]";
    if (input === null || typeof input !== "object") return input;
    if (seen.has(input)) return "[credential-redacted-cycle]";
    seen.add(input);
    if (input instanceof Error) {
      // Make name/message/stack enumerable and preserve enumerable details,
      // without retaining an original toJSON closure that could emit secrets.
      const safe: Record<string, unknown> = {};
      const keys = new Set([...Reflect.ownKeys(input), "name", "message", "stack"]);
      for (const key of keys) {
        if (typeof key !== "string") continue;
        const value = (input as unknown as Record<string, unknown>)[key];
        if (typeof value !== "function") safe[key] = this.value(value, seen);
      }
      return safe;
    }
    if (input instanceof URL) return this.text(input.toString());
    if (Buffer.isBuffer(input)) return Buffer.from(this.text(input.toString("utf8")), "utf8");
    if (Array.isArray(input)) return input.map((entry) => this.value(entry, seen));
    const prototype = Object.getPrototypeOf(input);
    if (prototype === Object.prototype || prototype === null) {
      return Object.fromEntries(
        Object.entries(input).map(([key, entry]) => [this.text(key), this.value(entry, seen)]),
      );
    }
    return this.text(String(input));
  }

  attach(session: SessionBrowser): void {
    if (this.attachments.length === 0) {
      for (const array of [session.console, session.network, session.dialogs, session.popups] as any[][]) {
        const original = array.push;
        const redactor = this;
        const wrapped = function (...items: any[]): number {
          return original.apply(array, items.map((item) => redactor.value(item)));
        };
        array.push = wrapped;
        this.attachments.push({ array, original, wrapped });
      }
    }
    this.scrub(session);
  }

  scrub(session: SessionBrowser): void {
    for (const array of [session.console, session.network, session.dialogs, session.popups] as any[][]) {
      const safe = this.value(array) as any[];
      array.splice(0, array.length, ...safe);
    }
  }

  seal(session: SessionBrowser): void {
    // Keep the scoped push wrappers installed for late instrumentation events;
    // WeakMap ownership avoids a detached global emitter/session reference.
    this.sealRawSecrets();
    this.scrub(session);
  }

  clearTemporary(): void {
    this.secrets.clear();
  }
}

async function fieldHandle(
  page: Page,
  token: string,
  field: "username" | "password",
): Promise<ElementHandle<HTMLInputElement>> {
  const handle = await page
    .locator(`form[${FORM_ATTRIBUTE}="${token}"] input[${FIELD_ATTRIBUTE}="${field}"]`)
    .elementHandle();
  if (handle === null) manualLogin();
  return handle as ElementHandle<HTMLInputElement>;
}

async function submitFromBroker(
  page: Page,
  token: string,
  action: string,
  signal: AbortSignal,
  timeoutMs: number,
): Promise<BrowserCredentialLoginResult> {
  const abortKey = `__ovid_credential_abort_${token.replaceAll("-", "_")}`;
  let abortReason: "timeout" | "caller" | null = null;
  let abortWork: Promise<void> = Promise.resolve();
  const abortInPage = (reason: "timeout" | "caller"): void => {
    if (abortReason !== null) return;
    abortReason = reason;
    abortWork = abortWork.then(async () => {
      await page
        .evaluate((key) => {
          const g = globalThis as any;
          g[key]?.abort();
        }, abortKey)
        .catch(() => {});
    });
  };
  const onAbort = (): void => abortInPage("caller");
  signal.addEventListener("abort", onAbort, { once: true });
  const timer = setTimeout(() => abortInPage("timeout"), timeoutMs);
  try {
    const outcome = await page.evaluate(
      async ({ formAttribute, marker, destination, controllerKey, windowKey }) => {
        const g = globalThis as any;
        const form = g.document.querySelector(`form[${formAttribute}="${marker}"]`);
        if (form === null) return { ok: false, refused: false };
        if (g[windowKey]?.attempted === true) return { ok: false, refused: true };
        const controller = new g.AbortController();
        g[controllerKey] = controller;
        try {
          const body = new g.URLSearchParams();
          for (const [key, value] of new g.FormData(form).entries()) {
            if (typeof value === "string") body.append(key, value);
          }
          if (g[windowKey]?.attempted === true) return { ok: false, refused: true };
          const response = await g.fetch(destination, {
            method: "POST",
            credentials: "include",
            redirect: "error",
            cache: "no-store",
            headers: { "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8" },
            body: body.toString(),
            signal: controller.signal,
          });
          await response.arrayBuffer();
          return { ok: true, refused: false };
        } catch {
          return { ok: false, refused: false };
        } finally {
          delete g[controllerKey];
        }
      },
      {
        formAttribute: FORM_ATTRIBUTE,
        marker: token,
        destination: action,
        controllerKey: abortKey,
        windowKey: windowGuardKey(token),
      },
    );
    await abortWork;
    if (abortReason === "timeout") {
      return unknown("submission_timeout", "The credential submission timed out; its outcome is unknown.");
    }
    if (abortReason === "caller" || signal.aborted) {
      return unknown("submission_aborted", "The credential submission was aborted; its outcome is unknown.");
    }
    if (outcome.refused) {
      return refused(
        "unsupported_login_context",
        "Credential login requires one main-frame page with no iframes or additional tabs.",
      );
    }
    return outcome.ok
      ? submitted()
      : unknown("submission_outcome_unknown", "The browser could not confirm whether the credential submission completed.");
  } catch {
    await abortWork;
    if (abortReason === "timeout") {
      return unknown("submission_timeout", "The credential submission timed out; its outcome is unknown.");
    }
    if (abortReason === "caller" || signal.aborted) {
      return unknown("submission_aborted", "The credential submission was aborted; its outcome is unknown.");
    }
    return unknown("submission_outcome_unknown", "The browser could not confirm whether the credential submission completed.");
  } finally {
    clearTimeout(timer);
    signal.removeEventListener("abort", onAbort);
    await abortWork;
  }
}

async function removeBrokerMarkers(page: Page, token: string, secret: string | null): Promise<boolean> {
  if (page.isClosed()) return true;
  try {
    return await page.evaluate(
      ({ formAttribute, fieldAttribute, marker, windowKey, exactSecret }) => {
        const g = globalThis as any;
        const doc = g.document;
        const owner = g[windowKey];
        if (doc === undefined) return false;
        if (owner === undefined) {
          // Validation can refuse before the field-owner guard exists. No fill
          // happened, so only provisional marker removal is required here.
          for (const element of Array.from(doc.querySelectorAll(`[${formAttribute}]`))) {
            if ((element as any).getAttribute(formAttribute) === marker) {
              (element as any).removeAttribute(formAttribute);
            }
          }
          for (const element of Array.from(doc.querySelectorAll(`[${fieldAttribute}]`))) {
            (element as any).removeAttribute(fieldAttribute);
          }
          return (
            doc.querySelector(`[${formAttribute}="${marker}"]`) === null &&
            doc.querySelector(`[${fieldAttribute}]`) === null
          );
        }
        const originals = [owner.username, owner.password].filter((node) => node != null);
        const originalSet = new Set(originals);
        const sameControls = (left: any[], right: any[]): boolean =>
          left.length === right.length && left.every((element, index) => element === right[index]);
        const beforeControls = Array.from(doc.querySelectorAll("input,textarea,select,button"));
        if (
          Array.isArray(owner.cleanupControls) &&
          !sameControls(owner.cleanupControls, beforeControls)
        ) {
          return false;
        }

        for (const element of Array.from(doc.querySelectorAll(`[${formAttribute}]`))) {
          if ((element as any).getAttribute(formAttribute) === marker) {
            (element as any).removeAttribute(formAttribute);
          }
        }
        for (const element of Array.from(doc.querySelectorAll(`[${fieldAttribute}]`))) {
          (element as any).removeAttribute(fieldAttribute);
        }

        // Marker mutations can also run page-defined callbacks. Verify a fresh
        // live document AFTER those mutations, using native value accessors.
        const afterControls = Array.from(doc.querySelectorAll("input,textarea,select,button"));
        if (!sameControls(beforeControls, afterControls)) return false;
        for (const control of afterControls) {
          const element = control as any;
          const prototype =
            element.tagName === "INPUT"
              ? g.HTMLInputElement?.prototype
              : element.tagName === "TEXTAREA"
                ? g.HTMLTextAreaElement?.prototype
                : element.tagName === "SELECT"
                  ? g.HTMLSelectElement?.prototype
                  : g.HTMLButtonElement?.prototype;
          let value: string;
          try {
            const descriptor = Object.getOwnPropertyDescriptor(prototype, "value");
            value =
              descriptor?.get !== undefined
                ? String(descriptor.get.call(element) ?? "")
                : String(element.value ?? "");
          } catch {
            return false;
          }
          if (exactSecret !== "" && value.includes(exactSecret)) return false;
          const password = element.tagName === "INPUT" && element.type === "password";
          if ((password || originalSet.has(element)) && value !== "") return false;
          if (password && !originalSet.has(element)) return false;
        }
        return (
          doc.querySelector(`[${formAttribute}="${marker}"]`) === null &&
          doc.querySelector(`[${fieldAttribute}]`) === null
        );
      },
      {
        formAttribute: FORM_ATTRIBUTE,
        fieldAttribute: FIELD_ATTRIBUTE,
        marker: token,
        windowKey: windowGuardKey(token),
        exactSecret: secret ?? "",
      },
    );
  } catch {
    return false;
  }
}

async function closeUnprovenPages(page: Page | null): Promise<boolean> {
  if (page === null) return true;
  try {
    const pages = [...page.context().pages()];
    await Promise.all(pages.map(async (candidate) => await candidate.close().catch(() => {})));
    return page.context().pages().length === 0;
  } catch {
    return page.isClosed();
  }
}

interface NativeCleanupChannel {
  cdp: CDPSession;
  executionContextId: number;
}

/**
 * Executes in a CDP isolated world, never the page's main realm. The isolated
 * intrinsic prototypes/descriptors and MutationObserver are independent of
 * page-side prototype/descriptor replacement. Only serializable proof crosses
 * back to Node; DOM/secret references stay inside the short-lived world.
 */
function nativeCleanupWorld(input: {
  action: "init" | "begin" | "checkpoint" | "finish" | "dispose";
  globalKey: string;
  token?: string;
  formAttribute?: string;
  fieldAttribute?: string;
  exactSecret?: string;
}): { ok: boolean } {
  const g = globalThis as any;
  const exactSecret = input.exactSecret ?? "";
  const stateKey = input.globalKey;
  if (input.action === "init") {
    const form = g.document?.querySelector(`form[${input.formAttribute}="${input.token}"]`);
    const username = form?.querySelector(`[${input.fieldAttribute}="username"]`);
    const password = form?.querySelector(`[${input.fieldAttribute}="password"]`);
    if (form == null || username == null || password == null) return { ok: false };
    const ids = new WeakMap<object, number>();
    let nextId = 0;
    const idFor = (node: object): number => {
      let id = ids.get(node);
      if (id === undefined) {
        id = ++nextId;
        ids.set(node, id);
      }
      return id;
    };
    const controls = Array.from(g.document.querySelectorAll("input,textarea,select,button"));
    g[stateKey] = {
      form,
      username,
      password,
      idFor,
      initialControlIds: controls.map((control) => idFor(control as object)),
      observer: null,
      baseline: null,
      changed: false,
    };
    return { ok: true };
  }
  const state = g[stateKey];
  if (state === undefined) return { ok: false };
  if (input.action === "dispose") {
    state.observer?.disconnect();
    state.form = null;
    state.username = null;
    state.password = null;
    state.initialControlIds = [];
    state.baseline = null;
    delete g[stateKey];
    return { ok: true };
  }

  const snapshot = (): { valid: boolean; signature: string } => {
    const doc = g.document;
    if (
      doc === undefined ||
      state.form == null ||
      state.username == null ||
      state.password == null ||
      !state.form.isConnected ||
      !state.username.isConnected ||
      !state.password.isConnected ||
      doc.forms.length !== 1 ||
      doc.forms[0] !== state.form
    ) {
      return { valid: false, signature: "invalid" };
    }
    const controls = Array.from(doc.querySelectorAll("input,textarea,select,button"));
    const ids = controls.map((control) => state.idFor(control));
    let valid =
      ids.length === state.initialControlIds.length &&
      ids.every((id, index) => id === state.initialControlIds[index]);
    const signature: Array<{ id: number; tag: string; type: string; value: string }> = [];
    for (let index = 0; index < controls.length; index += 1) {
      const element = controls[index] as any;
      const prototype =
        element.tagName === "INPUT"
          ? g.HTMLInputElement?.prototype
          : element.tagName === "TEXTAREA"
            ? g.HTMLTextAreaElement?.prototype
            : element.tagName === "SELECT"
              ? g.HTMLSelectElement?.prototype
              : g.HTMLButtonElement?.prototype;
      const descriptor = Object.getOwnPropertyDescriptor(prototype, "value");
      if (descriptor?.get === undefined) return { valid: false, signature: "invalid" };
      let value: string;
      try {
        // Isolated intrinsic getter bypasses BOTH main-realm prototype changes
        // and own getters/setters installed by the page on the DOM node.
        value = String(descriptor.get.call(element) ?? "");
      } catch {
        return { valid: false, signature: "invalid" };
      }
      const password = element.tagName === "INPUT" && element.type === "password";
      const original = element === state.username || element === state.password;
      if ((original || password) && value !== "") valid = false;
      if (exactSecret !== "" && value.includes(exactSecret)) valid = false;
      signature.push({ id: ids[index], tag: String(element.tagName), type: String(element.type ?? ""), value });
    }
    return { valid, signature: JSON.stringify(signature) };
  };

  if (input.action === "begin") {
    const baseline = snapshot();
    if (!baseline.valid || typeof g.MutationObserver !== "function") return { ok: false };
    state.baseline = baseline.signature;
    state.changed = false;
    state.observer = new g.MutationObserver(() => {
      state.changed = true;
    });
    state.observer.observe(g.document.documentElement, {
      attributes: true,
      childList: true,
      characterData: true,
      subtree: true,
    });
    return { ok: true };
  }

  if (input.action === "checkpoint" || input.action === "finish") {
    if (state.observer === null || state.baseline === null) return { ok: false };
    if (state.observer.takeRecords().length > 0) state.changed = true;
    const current = snapshot();
    const ok = !state.changed && current.valid && current.signature === state.baseline;
    if (input.action === "finish") {
      state.observer.disconnect();
      state.observer = null;
    }
    return { ok };
  }
  return { ok: false };
}

async function evaluateNativeCleanup(
  channel: NativeCleanupChannel,
  input: Omit<Parameters<typeof nativeCleanupWorld>[0], "globalKey">,
): Promise<boolean> {
  const expression = `(${nativeCleanupWorld.toString()})(${JSON.stringify({ ...input, globalKey: "__ovidNativeCleanup" })})`;
  const response = await channel.cdp.send("Runtime.evaluate", {
    contextId: channel.executionContextId,
    expression,
    returnByValue: true,
    awaitPromise: true,
  });
  if (response.exceptionDetails !== undefined) return false;
  return (response.result as { value?: { ok?: boolean } }).value?.ok === true;
}

async function createNativeCleanupChannel(
  page: Page,
  token: string,
): Promise<NativeCleanupChannel | null> {
  let cdp: CDPSession | null = null;
  try {
    cdp = await page.context().newCDPSession(page);
    const tree = await cdp.send("Page.getFrameTree");
    const world = await cdp.send("Page.createIsolatedWorld", {
      frameId: tree.frameTree.frame.id,
      worldName: `ovid-credential-cleanup-${token}`,
    });
    const channel = { cdp, executionContextId: world.executionContextId };
    if (
      !(await evaluateNativeCleanup(channel, {
        action: "init",
        token,
        formAttribute: FORM_ATTRIBUTE,
        fieldAttribute: FIELD_ATTRIBUTE,
        exactSecret: "",
      }))
    ) {
      await cdp.detach().catch(() => {});
      return null;
    }
    return channel;
  } catch {
    await cdp?.detach().catch(() => {});
    return null;
  }
}

function nextBrowserTask(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

async function proveNativeCleanupQuiescent(
  channel: NativeCleanupChannel,
  secret: string | null,
): Promise<boolean> {
  try {
    const exactSecret = secret ?? "";
    if (!(await evaluateNativeCleanup(channel, { action: "begin", exactSecret }))) return false;
    // MutationObserver callbacks run after the current JS stack. Separate CDP
    // tasks plus two checkpoints prove the post-marker DOM stayed quiescent.
    await nextBrowserTask();
    if (!(await evaluateNativeCleanup(channel, { action: "checkpoint", exactSecret }))) return false;
    await nextBrowserTask();
    return await evaluateNativeCleanup(channel, { action: "finish", exactSecret });
  } catch {
    return false;
  }
}

async function disposeNativeCleanupChannel(channel: NativeCleanupChannel | null): Promise<void> {
  if (channel === null) return;
  await evaluateNativeCleanup(channel, { action: "dispose", exactSecret: "" }).catch(() => {});
  await channel.cdp.detach().catch(() => {});
}

interface CleanupProof {
  /** Ordinary cleanup either succeeded or the compromised context was closed. */
  proven: boolean;
  /** A replacement/clone/unknown live secret requires an explicit unproven result. */
  compromised: boolean;
}

async function cleanupFields(
  page: Page,
  handles: readonly ElementHandle<HTMLInputElement>[],
  initialUrl: string | null,
  token: string,
  secret: string | null,
  log: (message: string, error?: unknown) => void,
): Promise<CleanupProof> {
  if (handles.length === 0) return { proven: true, compromised: false };
  let fieldsClear = false;
  let compromised = false;
  for (let attempt = 0; attempt < 3 && !fieldsClear; attempt += 1) {
    try {
      const report = await page.evaluate(
        ({ windowKey, fieldAttribute, exactSecret }) => {
          const g = globalThis as any;
          const doc = g.document;
          const owner = g[windowKey];
          if (owner === undefined || doc === undefined) {
            return { clear: false, compromised: false };
          }
          const originals = [owner.username, owner.password].filter((node) => node != null);
          const originalSet = new Set(originals);
          let changed = false;
          if (
            !owner.form?.isConnected ||
            doc.forms.length !== 1 ||
            doc.forms[0] !== owner.form ||
            originals.length !== 2
          ) {
            changed = true;
          }
          for (const original of originals) {
            if (!original.isConnected || !doc.documentElement.contains(original)) changed = true;
          }
          for (const marked of Array.from(doc.querySelectorAll(`[${fieldAttribute}]`))) {
            if (!originalSet.has(marked)) changed = true;
          }

          const readLiveValue = (element: any): { value: string; failed: boolean } => {
            const prototype =
              element.tagName === "INPUT"
                ? g.HTMLInputElement?.prototype
                : element.tagName === "TEXTAREA"
                  ? g.HTMLTextAreaElement?.prototype
                  : element.tagName === "SELECT"
                    ? g.HTMLSelectElement?.prototype
                    : g.HTMLButtonElement?.prototype;
            // Read the native value for verification; never trust an original
            // getter that an overridden setter may have made report empty.
            try {
              const descriptor = Object.getOwnPropertyDescriptor(prototype, "value");
              return {
                value:
                  descriptor?.get !== undefined
                    ? String(descriptor.get.call(element) ?? "")
                    : String(element.value ?? ""),
                failed: false,
              };
            } catch {
              return { value: "", failed: true };
            }
          };
          const sameControls = (left: any[], right: any[]): boolean =>
            left.length === right.length && left.every((element, index) => element === right[index]);

          // Clear the current document, then RE-ENUMERATE after every setter.
          // A synchronous setter can append a copy that was absent above.
          let clear = true;
          const controls = Array.from(doc.querySelectorAll("input,textarea,select,button"));
          for (const control of controls) {
            const element = control as any;
            const sample = readLiveValue(element);
            if (sample.failed) clear = false;
            const marked = element.hasAttribute(fieldAttribute);
            const password = element.tagName === "INPUT" && element.type === "password";
            const exactLiveSecret = exactSecret !== "" && sample.value.includes(exactSecret);
            const sensitive = marked || password || exactLiveSecret;
            if (sensitive && !originalSet.has(element)) changed = true;
            if (!sensitive && !originalSet.has(element)) continue;
            try {
              element.value = "";
              if (readLiveValue(element).value !== "") clear = false;
            } catch {
              clear = false;
            }
          }

          // Do not trust either the initial snapshot or a cleared original
          // getter. The live control set and native values must now be stable,
          // secret-free, and limited to the original marked/password fields.
          const afterControls = Array.from(doc.querySelectorAll("input,textarea,select,button"));
          if (!sameControls(controls, afterControls)) {
            changed = true;
            clear = false;
          }
          for (const control of afterControls) {
            const element = control as any;
            const sample = readLiveValue(element);
            if (sample.failed) clear = false;
            const marked = element.hasAttribute(fieldAttribute);
            const password = element.tagName === "INPUT" && element.type === "password";
            if (exactSecret !== "" && sample.value.includes(exactSecret)) {
              if (!originalSet.has(element)) changed = true;
              clear = false;
            }
            if ((marked || password || originalSet.has(element)) && sample.value !== "") clear = false;
            if ((marked || password) && !originalSet.has(element)) changed = true;
          }
          owner.cleanupControls = afterControls;
          return { clear, compromised: changed };
        },
        {
          windowKey: windowGuardKey(token),
          fieldAttribute: FIELD_ATTRIBUTE,
          exactSecret: secret ?? "",
        },
      );
      compromised ||= report.compromised;
      fieldsClear = report.clear;
    } catch (error) {
      fieldsClear = false;
      log("credential field cleanup attempt failed", error);
    }
  }
  let contextSafe = false;
  try {
    contextSafe =
      !page.isClosed() &&
      initialUrl !== null &&
      page.url() === initialUrl &&
      page.context().pages().length === 1 &&
      page.frames().length === 1;
  } catch {
    contextSafe = false;
  }
  if (fieldsClear && contextSafe && !compromised) return { proven: true, compromised: false };
  log("credential field cleanup could not be proven; closing the credential page");
  return { proven: await closeUnprovenPages(page), compromised };
}

export class BrowserCredentialBroker {
  private readonly deps: BrowserCredentialBrokerDeps;
  private readonly submitTimeoutMs: number;

  constructor(deps: BrowserCredentialBrokerDeps) {
    this.deps = deps;
    this.submitTimeoutMs = deps.submitTimeoutMs ?? 10_000;
  }

  async login(input: BrowserCredentialLoginInput): Promise<BrowserCredentialLoginResult> {
    const { ctx, credentialId, approver, signal } = input;
    purgeSessionUrlMemory(ctx.sessionId);
    const operationId = `credential:${ctx.runId ?? "unscoped"}:${randomUUID()}`;
    const token = randomUUID();
    const handles: ElementHandle<HTMLInputElement>[] = [];
    let credential: BrowserCredentialSecret | null = null;
    let secret: string | null = null;
    let redactor = new ScopedSecretRedactor();
    let session: SessionBrowser | null = null;
    let page: Page | null = null;
    let initialUrl: string | null = null;
    let submissionStarted = false;
    let redactionAttached = false;
    let operationViolation: "unsupported_login_context" | "credential_navigation_refused" | null = null;
    let stopMonitoring: (() => Promise<void>) | null = null;
    let nativeChannel: NativeCleanupChannel | null = null;
    let nativeChannelRequired = false;
    let outcome: BrowserCredentialLoginResult = refused("credential_operation_failed", "Credential login was refused.");
    const log = (message: string, error?: unknown): void => {
      this.deps.log?.(redactor.text(message), redactor.value(error));
    };

    try {
      if (typeof ctx.runId !== "string" || ctx.runId === "") {
        control(refused("credential_context_required", "Credential approval requires a run and chat session context."));
      }
      const entries = await this.deps.credentials.list(ctx.userId);
      const metadata = entries.find((entry) => entry.id === credentialId);
      if (metadata === undefined) {
        control(refused("credential_not_found", "The saved credential is not available to this user."));
      }
      const origin = parseCredentialOrigin(metadata.site);
      if (origin === null) {
        control(refused("credential_origin_invalid", "The saved credential is not bound to a valid exact HTTPS origin."));
      }
      const options = { kind: "credential" as const, operationId, signal };
      outcome = await this.deps.operations.withOperation(ctx.sessionId, options, async () =>
        // Reentrant by design: Task 10's withSession wrapper uses this same fence.
        await this.deps.operations.withOperation(ctx.sessionId, options, async () =>
          await withSession({ ...this.deps, browserOperations: this.deps.operations }, ctx, async (liveSession, livePage) => {
            session = liveSession;
            page = livePage;
            let proof = await proveLiveForm(livePage, liveSession, origin, token, null);
            initialUrl = proof.initialUrl;
            await installWindowOpenGuard(livePage, token);
            const assertNoViolation = (): void => {
              if (signal.aborted) {
                control(
                  submissionStarted
                    ? unknown("submission_aborted", "The credential submission was aborted; its outcome is unknown.")
                    : refused("credential_aborted", "Credential login was aborted before submission."),
                );
              }
              if (operationViolation === null) return;
              if (submissionStarted) {
                control(unknown("submission_outcome_unknown", "A browser navigation or tab changed the unknown submission outcome."));
              }
              control(
                refused(
                  operationViolation,
                  operationViolation === "credential_navigation_refused"
                    ? "The page navigated during the credential operation; submission was refused."
                    : "Credential login requires one main-frame page with no iframes or additional tabs.",
                ),
              );
            };
            const prove = async (previous: LiveProof): Promise<LiveProof> => {
              assertNoViolation();
              const next = await proveLiveForm(livePage, liveSession, origin, token, previous);
              assertNoViolation();
              return next;
            };
            const context = livePage.context();
            const onContextPage = (candidate: Page): void => {
              if (candidate === livePage) return;
              operationViolation = "unsupported_login_context";
              void candidate.close().catch(() => {});
            };
            const onPopup = (): void => {
              operationViolation = "unsupported_login_context";
            };
            const onFrameNavigated = (frame: import("playwright-core").Frame): void => {
              if (frame === livePage.mainFrame() && initialUrl !== null && frame.url() !== initialUrl) {
                operationViolation = "credential_navigation_refused";
              }
            };
            context.on("page", onContextPage);
            livePage.on("popup", onPopup);
            livePage.on("framenavigated", onFrameNavigated);
            stopMonitoring = async () => {
              context.off("page", onContextPage);
              livePage.off("popup", onPopup);
              livePage.off("framenavigated", onFrameNavigated);
              await livePage
                .evaluate((key) => {
                  const g = globalThis as any;
                  const state = g[key];
                  if (state !== undefined) {
                    g.open = state.original;
                    delete g[key];
                  }
                }, windowGuardKey(token))
                .catch(() => {});
            };
            assertNoViolation();
            if (signal.aborted) {
              control(refused("credential_aborted", "Credential login was aborted before submission."));
            }
            const decision = await approver.approve({
              userId: ctx.userId,
              sessionId: ctx.workspaceSessionId ?? ctx.sessionId,
              runId: ctx.runId as string,
              credentialId,
              origin,
              signal,
            });
            if (decision !== "allow") {
              control(refused("credential_use_denied", "Credential use was not approved for this login attempt."));
            }
            proof = await prove(proof);
            if (signal.aborted) {
              control(refused("credential_aborted", "Credential login was aborted before submission."));
            }
            nativeChannelRequired = true;
            nativeChannel = await createNativeCleanupChannel(livePage, token);
            if (nativeChannel === null) {
              control(
                refused(
                  "credential_cleanup_unproven",
                  "An independent native cleanup proof channel could not be established.",
                ),
              );
            }

            // Exactly one lazy resolution, after BOTH exclusive acquisition and
            // per-use approval. No notes are used by the broker.
            credential = await this.deps.credentials.resolve(ctx.userId, credentialId);
            if (credential === null || credential.id !== credentialId || credential.secret === "") {
              control(refused("credential_unavailable", "The approved credential could not be resolved."));
            }
            secret = credential.secret;
            redactor = ScopedSecretRedactor.forSession(liveSession);
            redactor.addSecrets(
              [credential.secret, credential.notes].filter((value): value is string => typeof value === "string" && value !== ""),
            );
            redactor.attach(liveSession);
            redactionAttached = true;
            if (parseCredentialOrigin(credential.site) !== origin) {
              control(refused("credential_origin_mismatch", "The resolved credential origin changed after approval."));
            }

            proof = await prove(proof);
            const username = await fieldHandle(livePage, token, "username");
            handles.push(username); // Track BEFORE fill: a partial fill still needs cleanup.
            proof = await prove(proof);
            await username.fill(credential.username);
            proof = await prove(proof);
            const password = await fieldHandle(livePage, token, "password");
            handles.push(password);
            proof = await prove(proof);
            await password.fill(secret);
            proof = await prove(proof);
            if (signal.aborted) {
              control(refused("credential_aborted", "Credential login was aborted before submission."));
            }
            assertNoViolation();
            submissionStarted = true;
            return await submitFromBroker(livePage, token, proof.action, signal, this.submitTimeoutMs);
          }),
        ),
      );
    } catch (error) {
      if (error instanceof BrokerControl) {
        outcome = error.outcome;
      } else if (operationViolation !== null) {
        outcome = submissionStarted
          ? unknown("submission_outcome_unknown", "A browser navigation or tab changed the unknown submission outcome.")
          : refused(
              operationViolation,
              operationViolation === "credential_navigation_refused"
                ? "The page navigated during the credential operation; submission was refused."
                : "Credential login requires one main-frame page with no iframes or additional tabs.",
            );
      } else if (error instanceof BrowserOperationRefusal || signal.aborted) {
        outcome = submissionStarted
          ? unknown("submission_aborted", "The credential submission was aborted; its outcome is unknown.")
          : refused("credential_aborted", "Credential login was aborted before submission.");
      } else if (
        !submissionStarted &&
        ((initialUrl !== null && pageUrlOrNull(page) !== initialUrl) ||
          (error instanceof Error &&
            error.message.includes("Execution context was destroyed, most likely because of a navigation")))
      ) {
        outcome = refused(
          "credential_navigation_refused",
          "The page navigated during the credential operation; submission was refused.",
        );
      } else {
        log("credential broker operation failed", error);
        outcome = submissionStarted
          ? unknown("submission_outcome_unknown", "The browser could not confirm whether the credential submission completed.")
          : refused("credential_operation_failed", "Credential login was refused without a verified submission.");
      }
    } finally {
      // withSession is fenced while active; this second purge covers every
      // unwind, including navigation/close races after its finally callback.
      purgeSessionUrlMemory(ctx.sessionId);
      let cleanupProven = true;
      let nativeCandidate = false;
      if (page !== null) {
        const cleanup = await cleanupFields(page, handles, initialUrl, token, secret, log);
        cleanupProven = cleanup.proven && !cleanup.compromised;
        if (!(await removeBrokerMarkers(page, token, secret))) {
          cleanupProven = false;
          await closeUnprovenPages(page);
        }
        nativeCandidate =
          handles.length > 0 && cleanup.proven && !cleanup.compromised && cleanupProven && !pageIsClosed(page);
      }
      const stop = stopMonitoring as unknown as (() => Promise<void>) | null;
      if (stop !== null) await stop();
      stopMonitoring = null;
      if (nativeChannelRequired && nativeChannel === null) {
        cleanupProven = false;
        if (!pageIsClosed(page)) await closeUnprovenPages(page);
      } else if (nativeCandidate) {
        const channel = nativeChannel as NativeCleanupChannel | null;
        const quiescent =
          channel !== null && (await proveNativeCleanupQuiescent(channel, secret));
        if (!quiescent) {
          cleanupProven = false;
          if (!pageIsClosed(page)) await closeUnprovenPages(page);
        }
      }
      if (!cleanupProven) {
        outcome = submissionStarted
          ? result(
              outcome.status === "submitted" ? "submitted" : "submission_unknown",
              "credential_cleanup_unproven",
              "Login success was not verified and credential field cleanup could not be proven.",
            )
          : refused("credential_cleanup_unproven", "Credential field cleanup could not be proven.");
      }
      await disposeNativeCleanupChannel(nativeChannel);
      nativeChannel = null;
      if (session !== null && redactionAttached) redactor.seal(session);
      for (const handle of handles.splice(0)) await handle.dispose().catch(() => {});
      // Drop local references only. JavaScript provides no honest guarantee of
      // memory zeroization for immutable strings or browser/protocol copies.
      secret = null;
      credential = null;
      if (!redactionAttached) redactor.clearTemporary();
      void secret;
      void credential;
    }
    return outcome;
  }
}
