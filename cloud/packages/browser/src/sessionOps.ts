/**
 * Session lifecycle (P6 Task 12) — the ONE open/close path shared by the
 * browser tools and the Task-14 engine. Keeping it here (rather than in the
 * engine) means every caller restores/flushes storageState in exactly one
 * order:
 *
 *   open:  persistence.restore → pool.acquireLive → registry.open → notify
 *   close: context.storageState → persistence.flush → registry.close →
 *          pool.releaseLive → notify
 *
 * Ownership: the POOL closes contexts; the registry only removes its entry
 * (Task 5's boundary pin).
 */

import type { Page } from "playwright-core";

import type { BrowserOperationCoordinator } from "./browserOperations.js";
import type { BrowserEngineConfig } from "./config.js";
import type { BrowserPool } from "./pool.js";
import type { BrowserSessionRegistry, SessionBrowser } from "./sessions.js";
import type { StorageStatePersistence } from "./stateStore.js";
import type { StorageState } from "./storageState.js";
import { SsrfError, assertPublicHost, navigableUrlReason } from "./url.js";
import {
  BrowserToolFailure,
  messageOf,
  type BrowserToolContext,
  type BrowserToolsDeps,
} from "./tools/types.js";

/** Structural subset of `BrowserToolsDeps` the engine also satisfies. */
export interface SessionOps {
  pool: BrowserPool;
  registry: BrowserSessionRegistry;
  persistence: StorageStatePersistence | null;
  cfg: BrowserEngineConfig;
  /** Structural additive seam; Task 10 uses the same coordinator for all entry points. */
  browserOperations?: Pick<BrowserOperationCoordinator, "isCredentialOperationActive">;
  notifyState?(sessionId: string): void;
  /**
   * Diagnostic sink for swallowed release-time capture/flush failures.
   * Defaults to `console.warn` (mirroring `stateStore.restore`'s log) so auth
   * persistence problems are never completely invisible.
   */
  log?(msg: string, err?: unknown): void;
}

function defaultLog(msg: string, err?: unknown): void {
  console.warn(`[sessionOps] ${msg}`, err ?? "");
}

/**
 * In-flight opens per sessionId. Two concurrent tool calls for a session that
 * does not exist yet must share ONE acquire/open: the pool would hand back the
 * same handle, but a second `registry.open` would re-instrument the page and
 * wipe the buffers.
 *
 * OWNERSHIP NOTE: the shared promise closes over the FIRST caller's `ops`
 * (including its `notifyState`), so a concurrent caller that suppressed its
 * own creation notification (state-mutating tools pass `notifyState:
 * undefined`) still observes the first caller's publish. That is intentional:
 * `bridge.publishState` is idempotent, and every publish is an accurate
 * snapshot at that moment; the mutation-owning tool publishes again after its
 * operation succeeds. Do not treat the creation notify as "belonging" to a
 * particular caller.
 */
const opening = new Map<string, Promise<SessionBrowser>>();

/**
 * Registry hit ⇒ touch + return. Otherwise restore the user's persisted login
 * state, acquire the pool's live context for this session, register it (which
 * instruments tab 0), and notify the bridge.
 */
/**
 * The last http(s) URL each session was on. The pool freezes a live context
 * after 15 s of inactivity (Muse ephemeral step leases), which closes the
 * page; storageState restores cookies/localStorage but NOT the current URL,
 * so without this the next step would open on about:blank and the agent would
 * have to navigate again. Re-navigating here keeps eviction transparent.
 * Entries are tiny (one string per session) and are overwritten on each step.
 */
const lastUrls = new Map<string, string>();

function credentialOperationActive(ops: SessionOps, sessionId: string): boolean {
  return ops.browserOperations?.isCredentialOperationActive(sessionId) === true;
}

/** Purge on credential entry/unwind so a sensitive URL can never be restored later. */
export function purgeSessionUrlMemory(sessionId: string): void {
  lastUrls.delete(sessionId);
}

function rememberUrl(ops: SessionOps, sessionId: string, url: string): void {
  if (credentialOperationActive(ops, sessionId)) {
    // Never persist OR retain an earlier URL across a credential operation.
    purgeSessionUrlMemory(sessionId);
    return;
  }
  if (url.startsWith("http://") || url.startsWith("https://")) {
    lastUrls.set(sessionId, url);
  }
}

export async function ensureSession(ops: SessionOps, ctx: BrowserToolContext): Promise<SessionBrowser> {
  const existing = ops.registry.get(ctx.sessionId);
  if (existing) {
    ops.registry.touch(ctx.sessionId);
    return existing;
  }

  const inFlight = opening.get(ctx.sessionId);
  if (inFlight) return inFlight;

  const promise = (async (): Promise<SessionBrowser> => {
    const storageState = ops.persistence ? await ops.persistence.restore(ctx.userId) : null;
    const handle = await ops.pool.acquireLive(ctx.sessionId, { storageState });

    // Another path may have registered the session while acquireLive was
    // awaiting; reuse that entry rather than re-opening over it.
    const raced = ops.registry.get(ctx.sessionId);
    if (raced) {
      ops.registry.touch(ctx.sessionId);
      return raced;
    }

    const session = ops.registry.open({
      sessionId: ctx.sessionId,
      userId: ctx.userId,
      handle,
    });
    ops.notifyState?.(ctx.sessionId);
    // Ephemeral-lease restore: a context that was frozen mid-session comes
    // back on the page it was showing. Best-effort — a dead URL must not turn
    // a tool call into an error, the caller's own navigation still applies.
    const credentialActive = credentialOperationActive(ops, ctx.sessionId);
    if (credentialActive) purgeSessionUrlMemory(ctx.sessionId);
    const previous = credentialActive ? undefined : lastUrls.get(ctx.sessionId);
    if (previous !== undefined) {
      try {
        await handle.page.goto(previous, { waitUntil: "domcontentloaded", timeout: 15_000 });
      } catch {
        // Unreachable now: the next explicit navigate replaces it.
      }
    }
    return session;
  })();

  opening.set(ctx.sessionId, promise);
  try {
    return await promise;
  } finally {
    opening.delete(ctx.sessionId);
  }
}

/**
 * Capture the session's storageState, flush it through persistence, then let
 * the pool close the context. Idempotent: an unknown session is a no-op.
 *
 * Capture/flush failures are swallowed (a crashed page must never keep a live
 * context or a pool slot alive) but logged: auth-persistence failures are
 * otherwise invisible.
 */
export async function releaseSession(ops: SessionOps, sessionId: string): Promise<void> {
  const session = ops.registry.get(sessionId);
  if (!session) return;

  try {
    const captured = (await session.handle.context.storageState()) as StorageState;
    if (ops.persistence) await ops.persistence.flush(session.userId, captured);
  } catch (err) {
    // Corrupt/dead context: fresh start next time, but still release below.
    (ops.log ?? defaultLog)(
      `failed to capture/flush browser state for session ${JSON.stringify(sessionId)} — releasing anyway`,
      err,
    );
  }

  ops.registry.close(sessionId);
  try {
    await ops.pool.releaseLive(sessionId);
  } finally {
    ops.notifyState?.(sessionId);
  }
}

/**
 * Ensure the session exists, reset its idle clock, and run `fn` with the
 * session and its active page. Takeover refuses with the exact copy before any
 * work (a tool body may call this directly in Task 13).
 */
export async function withSession<T>(
  deps: BrowserToolsDeps & Pick<SessionOps, "browserOperations">,
  ctx: BrowserToolContext,
  fn: (session: SessionBrowser, page: Page) => Promise<T>,
): Promise<T> {
  const refusal = deps.registry.refuseReasonIfTakeover(ctx.sessionId);
  if (refusal !== null) throw new BrowserToolFailure(refusal);

  const session = await ensureSession(deps, ctx);
  deps.registry.touch(ctx.sessionId);
  const page = session.tabs[session.activeIndex] ?? session.handle.page;
  try {
    return await fn(session, page);
  } finally {
    // Remember where the step left the tab so an idle freeze can restore it.
    rememberUrl(deps, ctx.sessionId, page.url());
  }
}

/**
 * Gate a URL before navigation:
 *   1. `navigableUrlReason` (http/https only, Dart refusal copy),
 *   2. `assertPublicHost` (SSRF: literal/resolved non-public addresses).
 * Returns a refusal copy, or null when the URL may be navigated.
 *
 * Relative URLs are allowed through: they have no host to resolve, and
 * Playwright rejects them at `goto` with a clear error.
 */
export async function guardUrl(
  url: string,
  toolName: string,
  cfg: BrowserEngineConfig,
): Promise<string | null> {
  const reason = navigableUrlReason(url, toolName);
  if (reason !== null) return reason;

  const colon = url.indexOf(":");
  const slash = url.indexOf("/");
  const relative = colon === -1 || (slash !== -1 && slash < colon);
  if (relative) return null;

  try {
    await assertPublicHost(url, cfg);
    return null;
  } catch (err) {
    if (err instanceof SsrfError) return `${toolName}: refused — ${err.message}`;
    return `${toolName}: refused — ${messageOf(err)}`;
  }
}
