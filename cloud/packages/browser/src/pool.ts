/**
 * BrowserPool — one chromium process (research §5: shared caches make one
 * process + N contexts cheaper than N processes) behind two admission
 * classes:
 *
 *  - "live": per-session persistent contexts (screencast-driving sessions),
 *    capped by `cfg.maxLiveBrowsers`, evicted idle after `cfg.idleEvictMs`.
 *  - "tier1": short-lived fallback leases for one-shot navigations, capped by
 *    `cfg.tier1FallbackContexts`; `release()` closes the context.
 *
 * Both classes share a single FIFO waiter queue (per-class capacity, strict
 * enqueue order within a class) with a per-waiter `queueTimeoutMs`. The
 * browser launches lazily on the FIRST acquire; a process death ("disconnect")
 * rejects every waiter with `BrowserPoolBusyError` ("browser process died —
 * retry"), clears the maps, and the next acquire relaunches.
 *
 * Context creation pins the hygiene bundle from research §4.1:
 * `serviceWorkers: "block"` (SWs re-register on load; blocking keeps eviction
 * state clean) even for live contexts, `ignoreHTTPSErrors: false`, and the
 * configured screencast viewport so every page is cast-ready.
 */

import { existsSync } from "node:fs";
import { chromium, type Browser, type BrowserContext, type Page } from "playwright-core";

import type { BrowserEngineConfig } from "./config.js";
import type { StorageState } from "./storageState.js";
import { prepareBrowserUidDrop, type BrowserUidDrop } from "./uidDrop.js";

export type PoolClass = "live" | "tier1";

/** The options Playwright's chromium.launch accepts (1.64.1). */
export type ChromiumLaunchOptions = NonNullable<Parameters<typeof chromium.launch>[0]>;

export interface LiveContextHandle {
  sessionId: string;
  context: BrowserContext;
  page: Page;
  createdAt: number;
  /** Resets the idle-eviction clock for this handle. */
  touch(): void;
}

export interface Tier1Lease {
  context: BrowserContext;
  page: Page;
  /** Closes the context and frees the tier-1 slot (admits the next waiter). */
  release(): Promise<void>;
}

export class BrowserPoolBusyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BrowserPoolBusyError";
  }
}

export interface BrowserPoolOptions {
  /** Called BEFORE context.close on idle eviction — the engine flushes storageState here. */
  onIdleEvict?(sessionId: string, context: BrowserContext): Promise<void>;
  /** Per-waiter queue timeout, default 30_000. */
  queueTimeoutMs?: number;
  /**
   * Test seam; default `chromium.launch(options)`. The options include the
   * uid-drop shim (executablePath/env/downloadsPath) when a dedicated browser
   * uid is configured, so a seam can assert the wiring.
   */
  launch?(options?: ChromiumLaunchOptions): Promise<Browser>;
  /**
   * Prepared uid-drop runtime. `undefined` ⇒ prepare lazily when
   * `cfg.egressUid` is set (the engine prepares eagerly at boot and passes
   * the same object here); `null` ⇒ no drop.
   */
  uidDrop?: BrowserUidDrop | null;
  now?(): number;
  /** Background evictIdle interval, default 30_000 (unref'd); 0 disables. */
  sweepIntervalMs?: number;
}

export interface BrowserPool {
  /** Same sessionId ⇒ existing handle (touch); FIFO beyond cfg.maxLiveBrowsers. */
  acquireLive(sessionId: string, opts?: { storageState?: StorageState | null }): Promise<LiveContextHandle>;
  /** FIFO beyond cfg.tier1FallbackContexts; lease.release closes the context. */
  acquireTier1(): Promise<Tier1Lease>;
  peekLive(sessionId: string): LiveContextHandle | null;
  /** Closes + removes the context (caller flushes state BEFORE — onIdleEvict is NOT called). */
  releaseLive(sessionId: string): Promise<void>;
  /** Handles untouched > cfg.idleEvictMs: onIdleEvict → close; returns evicted sessionIds. */
  evictIdle(): Promise<string[]>;
  liveCount(): number;
  tier1Count(): number;
  queueDepth(): number;
  stats(): { browserAlive: boolean; live: number; tier1: number; queued: number };
  /** Reject waiters (BrowserPoolBusyError), onIdleEvict NOT called, close all contexts, browser.close(), stop sweep timer. */
  close(): Promise<void>;
}

/** The skipIf gate for every chromium test: registry executablePath + existsSync. */
export function chromiumExecutableExists(): boolean {
  try {
    return existsSync(chromium.executablePath());
  } catch {
    return false;
  }
}

interface LiveHandle extends LiveContextHandle {
  lastTouch: number;
}

interface Tier1Entry {
  context: BrowserContext;
  page: Page;
}

interface Waiter {
  kind: PoolClass;
  sessionId?: string;
  storageState: StorageState | null;
  resolve(value: LiveContextHandle | Tier1Lease): void;
  reject(err: Error): void;
  timer: ReturnType<typeof setTimeout>;
}

export function createBrowserPool(cfg: BrowserEngineConfig, opts: BrowserPoolOptions = {}): BrowserPool {
  const queueTimeoutMs = opts.queueTimeoutMs ?? 30_000;
  const sweepIntervalMs = opts.sweepIntervalMs ?? 30_000;
  const now = (): number => (opts.now ? opts.now() : Date.now());

  let browser: Browser | null = null;
  let browserAlive = false;
  let launching: Promise<Browser> | null = null;
  let closed = false;
  let closePromise: Promise<void> | null = null;
  let sweepTimer: ReturnType<typeof setInterval> | null = null;

  const live = new Map<string, LiveHandle>();
  const tier1 = new Set<Tier1Entry>();
  let waiters: Waiter[] = [];

  // In-flight admissions: createLiveHandle/createTier1Lease only land in the
  // map after awaits (newContext is round-trip slow), so capacity checks must
  // count them or pump() would admit two waiters into one freed slot.
  let pendingLive = 0;
  let pendingTier1 = 0;
  const liveHasCapacity = (): boolean => live.size + pendingLive < cfg.maxLiveBrowsers;
  const tier1HasCapacity = (): boolean => tier1.size + pendingTier1 < cfg.tier1FallbackContexts;

  // -------------------------------------------------------------------------
  // Browser lifecycle
  // -------------------------------------------------------------------------

  /**
   * Resolve the uid-drop runtime once. The engine prepares it eagerly (so a
   * misconfigured uid fails at boot); a direct pool user gets the same
   * fail-loud preparation on first launch. There is never a root fallback.
   */
  let uidDropResolved: BrowserUidDrop | null | undefined;
  let ownsUidDrop = false;
  async function resolveUidDrop(): Promise<BrowserUidDrop | null> {
    if (uidDropResolved !== undefined) return uidDropResolved;
    if (opts.uidDrop !== undefined) {
      uidDropResolved = opts.uidDrop;
      return uidDropResolved;
    }
    if ((cfg.egressUid ?? null) === null) {
      uidDropResolved = null;
      return null;
    }
    uidDropResolved = await prepareBrowserUidDrop(cfg);
    ownsUidDrop = true;
    return uidDropResolved;
  }

  function ensureBrowser(): Promise<Browser> {
    if (browserAlive && browser) return Promise.resolve(browser);
    if (launching) return launching;
    launching = (async () => {
      const uidDrop = await resolveUidDrop();
      const launchOptions: ChromiumLaunchOptions = {
        headless: true,
        args: cfg.chromiumArgs,
      };
      if (uidDrop !== null) {
        // Playwright has no uid/gid option — the generated setpriv shim is
        // the executablePath; env/downloadsPath point at uid-owned dirs.
        launchOptions.executablePath = uidDrop.wrapperPath;
        launchOptions.env = uidDrop.env;
        launchOptions.downloadsPath = uidDrop.downloadsDir;
      }
      const b = opts.launch
        ? await opts.launch(launchOptions)
        : await chromium.launch(launchOptions);
      // playwright's event is "disconnected" — fired both on external close()
      // and on crash/process death.
      b.on("disconnected", onDisconnect);
      browser = b;
      browserAlive = true;
      return b;
    })();
    const clear = () => {
      launching = null;
    };
    launching.then(clear, clear);
    return launching;
  }

  function onDisconnect(): void {
    // pool.close() itself lands here via browser.close() — the pool-level
    // flags are already set by then, and there is nothing left to clean.
    if (closed) return;
    browserAlive = false;
    browser = null;
    // Contexts are gone with the process — drop them without close().
    live.clear();
    tier1.clear();
    rejectAllWaiters(new BrowserPoolBusyError("The browser process died — retry."));
  }

  function rejectAllWaiters(err: Error): void {
    const pending = waiters;
    waiters = [];
    for (const w of pending) {
      clearTimeout(w.timer);
      w.reject(err);
    }
  }

  // -------------------------------------------------------------------------
  // Context creation — the pinned research §4.1 hygiene bundle
  // -------------------------------------------------------------------------

  function newPinnedContext(b: Browser, storageState: StorageState | null | undefined): Promise<BrowserContext> {
    return b.newContext({
      storageState: storageState ?? undefined,
      viewport: { width: cfg.screencast.width, height: cfg.screencast.height },
      ignoreHTTPSErrors: false,
      serviceWorkers: "block",
    });
  }

  async function createLiveHandle(sessionId: string, storageState: StorageState | null | undefined): Promise<LiveHandle> {
    pendingLive++;
    try {
      const b = await ensureBrowser();
      const context = await newPinnedContext(b, storageState);
      const page = await context.newPage();
      const handle: LiveHandle = {
        sessionId,
        context,
        page,
        createdAt: now(),
        lastTouch: now(),
        touch() {
          handle.lastTouch = now();
        },
      };
      live.set(sessionId, handle);
      return handle;
    } finally {
      pendingLive--;
    }
  }

  async function createTier1Lease(): Promise<Tier1Lease> {
    pendingTier1++;
    try {
      const b = await ensureBrowser();
      const context = await newPinnedContext(b, null);
      const page = await context.newPage();
      const entry: Tier1Entry = { context, page };
      tier1.add(entry);
      return {
        context,
        page,
        async release(): Promise<void> {
          if (!tier1.has(entry)) return; // already released / pool cleared it
          tier1.delete(entry);
          try {
            await context.close();
          } finally {
            pump();
          }
        },
      };
    } finally {
      pendingTier1--;
    }
  }

  // -------------------------------------------------------------------------
  // Admission + FIFO queue
  // -------------------------------------------------------------------------

  function enqueueWaiter(
    kind: PoolClass,
    sessionId: string | undefined,
    storageState: StorageState | null,
  ): Promise<LiveContextHandle | Tier1Lease> {
    return new Promise<LiveContextHandle | Tier1Lease>((resolve, reject) => {
      const waiter: Waiter = {
        kind,
        sessionId,
        storageState,
        resolve: resolve as Waiter["resolve"],
        reject,
        timer: setTimeout(() => {
          const i = waiters.indexOf(waiter);
          if (i !== -1) waiters.splice(i, 1);
          const slots = kind === "live" ? cfg.maxLiveBrowsers : cfg.tier1FallbackContexts;
          const what = kind === "live" ? "live browser slots busy" : "tier-1 fallback contexts busy";
          reject(new BrowserPoolBusyError(`The browser pool is full (${slots} ${what}). The request was queued and timed out — try again shortly.`));
        }, queueTimeoutMs),
      };
      waiters.push(waiter);
    });
  }

  /** Admit waiters front-to-back while their class has capacity (FIFO per class). */
  function pump(): void {
    let progressed = true;
    while (progressed) {
      progressed = false;
      for (let i = 0; i < waiters.length; i++) {
        const w = waiters[i];
        const hasCapacity = w.kind === "live" ? liveHasCapacity() : tier1HasCapacity();
        if (!hasCapacity) continue;
        waiters.splice(i, 1);
        void admit(w);
        progressed = true;
        break;
      }
    }
  }

  async function admit(w: Waiter): Promise<void> {
    clearTimeout(w.timer);
    try {
      if (w.kind === "live") {
        // The session may already have a live handle by admission time (a
        // duplicate waiter raced an existing acquire) — reuse it, no slot used.
        const existing = w.sessionId !== undefined ? live.get(w.sessionId) : undefined;
        if (existing) {
          existing.touch();
          w.resolve(existing);
          return;
        }
        w.resolve(await createLiveHandle(w.sessionId!, w.storageState));
      } else {
        w.resolve(await createTier1Lease());
      }
    } catch (err) {
      w.reject(err instanceof Error ? err : new Error(String(err)));
    }
  }

  async function acquireLive(
    sessionId: string,
    acquireOpts?: { storageState?: StorageState | null },
  ): Promise<LiveContextHandle> {
    if (closed) throw new BrowserPoolBusyError("The browser pool is closed.");
    const existing = live.get(sessionId);
    if (existing) {
      existing.touch();
      return existing;
    }
    if (liveHasCapacity()) {
      return createLiveHandle(sessionId, acquireOpts?.storageState ?? null);
    }
    return enqueueWaiter("live", sessionId, acquireOpts?.storageState ?? null) as Promise<LiveContextHandle>;
  }

  async function acquireTier1(): Promise<Tier1Lease> {
    if (closed) throw new BrowserPoolBusyError("The browser pool is closed.");
    if (tier1HasCapacity()) {
      return createTier1Lease();
    }
    return enqueueWaiter("tier1", undefined, null) as Promise<Tier1Lease>;
  }

  async function releaseLive(sessionId: string): Promise<void> {
    const handle = live.get(sessionId);
    if (!handle) return;
    live.delete(sessionId);
    try {
      await handle.context.close();
    } finally {
      pump();
    }
  }

  async function evictIdle(): Promise<string[]> {
    const t = now();
    const evicted: string[] = [];
    for (const [sessionId, handle] of [...live]) {
      if (t - handle.lastTouch <= cfg.idleEvictMs) continue;
      live.delete(sessionId);
      evicted.push(sessionId);
      if (opts.onIdleEvict) await opts.onIdleEvict(sessionId, handle.context);
      await handle.context.close();
    }
    pump();
    return evicted;
  }

  // -------------------------------------------------------------------------
  // Sweep, stats, close
  // -------------------------------------------------------------------------

  if (sweepIntervalMs > 0) {
    sweepTimer = setInterval(() => {
      void evictIdle().catch(() => {
        // onIdleEvict/context failures must never kill the sweep loop.
      });
    }, sweepIntervalMs);
    sweepTimer.unref?.();
  }

  function close(): Promise<void> {
    if (closePromise) return closePromise;
    closed = true;
    closePromise = (async () => {
      if (sweepTimer) {
        clearInterval(sweepTimer);
        sweepTimer = null;
      }
      rejectAllWaiters(new BrowserPoolBusyError("The browser pool is closed."));
      const handles = [...live.values()];
      live.clear();
      const entries = [...tier1];
      tier1.clear();
      await Promise.allSettled([
        ...handles.map((h) => h.context.close()),
        ...entries.map((e) => e.context.close()),
      ]);
      const b = browser;
      browser = null;
      browserAlive = false;
      if (b) {
        try {
          await b.close();
        } catch {
          // already dead — disconnect already cleared the pool state
        }
      }
      // Only a pool that prepared the runtime owns its cleanup; the engine
      // passes a prepared runtime and cleans it after every pool is closed.
      if (ownsUidDrop && uidDropResolved) await uidDropResolved.cleanup();
    })();
    return closePromise;
  }

  return {
    acquireLive,
    acquireTier1,
    peekLive: (sessionId: string) => live.get(sessionId) ?? null,
    releaseLive,
    evictIdle,
    liveCount: () => live.size,
    tier1Count: () => tier1.size,
    queueDepth: () => waiters.length,
    stats: () => ({ browserAlive, live: live.size, tier1: tier1.size, queued: waiters.length }),
    close,
  };
}
