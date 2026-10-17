/**
 * BrowserEngine — the composition facade (P6 Task 14). One object a worker
 * process constructs at boot and P3's loop drives per run:
 *
 *   openSession    = sessionOps.ensureSession + bridge.watch
 *   releaseSession = stop cast + sessionOps.releaseSession + bridge.unwatch
 *                    + a final {live:false} publish
 *   publishState   = registry + screencast status → BrowserStateDto → bridge
 *   close          = releaseSession(all live, flushing state) → bridge.close
 *                    → research.close → pool.close (idempotent)
 *
 * Pinned orderings:
 *  - Flush BEFORE close (Review Focus #2): every path that ends a live
 *    context (idle eviction, releaseSession, close) captures storageState and
 *    persists it BEFORE the context dies — the 3-minute hibernation mirror
 *    (research §5 knob 5).
 *  - The webp probe runs ONCE per engine lifetime, on the first screencast
 *    start, and its page navigation is undone afterwards (T6 carry:
 *    probeWebpSupport navigates the page — never leave the user on the probe
 *    fixture).
 *  - Viewer input is applied in redis arrival order (T7/T8 carry): one
 *    serial queue per session, never concurrent un-awaited dispatches.
 *  - The screencast follows the active tab: a 10 s unref'd monitor restarts
 *    the cast when `screencastPage !== activePage`, and steps down the
 *    quality ladder on viewer overflow or host load.
 */

import { mkdir } from "node:fs/promises";
import { loadavg } from "node:os";
import { join } from "node:path";

import type { Redis } from "ioredis";
import type { BrowserContext, Page } from "playwright-core";
import type { BrowserInputEvent, BrowserStateDto } from "@ovid/shared";

import { createRedisBrowserBridge } from "./bridge.js";
import type { BrowserEngineConfig } from "./config.js";
import { applyInputEvent } from "./input.js";
import { createLightpandaPool, lightpandaAvailable, type LightpandaPool } from "./lightpanda.js";
import { createBrowserPool, type BrowserPool } from "./pool.js";
import { createResearchBrowser, type ResearchBrowser } from "./researchBrowser.js";
import {
  SCREENCAST_LADDER,
  probeWebpSupport,
  startScreencast,
  type ScreencastHandle,
} from "./screencast.js";
import {
  ensureSession,
  releaseSession as releaseSessionOps,
  type SessionOps,
} from "./sessionOps.js";
import { createBrowserSessionRegistry, type BrowserSessionRegistry, type SessionBrowser } from "./sessions.js";
import type { StorageStatePersistence } from "./stateStore.js";
import type { StorageState } from "./storageState.js";
import { createBrowserTools } from "./tools/definitions.js";
import type { BrowserToolDef } from "./tools/types.js";
import { prepareBrowserUidDrop, type BrowserUidDrop } from "./uidDrop.js";
import { createSsrfGuardedFetch } from "./url.js";

export interface BrowserEngineDeps {
  cfg: BrowserEngineConfig;
  /** Must return a FRESH connection each call; the bridge quits them all on close. */
  redisFactory: () => Redis;
  /** null when cfg.stateDir is null or no master key — no login restore/flush. */
  persistence: StorageStatePersistence | null;
  /** Default createSsrfGuardedFetch(cfg). */
  fetchImpl?: typeof fetch;
  /**
   * Default: join(OVID_WORKSPACES_ROOT ?? "/workspaces/users", userId,
   * "sessions", sessionId) + mkdir -p. The worker passes P2's resolved root
   * explicitly so the engine and the SandboxManager agree on the layout.
   */
  workspaceDir?(userId: string, sessionId: string): Promise<string>;
  /**
   * Test seam: default prepareBrowserUidDrop(cfg). Runs at boot so a
   * configured browser uid that cannot be applied (non-root worker, missing
   * setpriv, unusable Chromium) fails loudly instead of falling back to root.
   */
  prepareUidDrop?(cfg: BrowserEngineConfig): Promise<BrowserUidDrop | null>;
  now?(): number;
  log?(msg: string, err?: unknown): void;
}

export interface BrowserEngine {
  pool: BrowserPool;
  registry: BrowserSessionRegistry;
  research: ResearchBrowser;
  tools: BrowserToolDef[];
  /** sessionOps.ensureSession + bridge.watch. */
  openSession(sessionId: string, userId: string): Promise<SessionBrowser>;
  /** sessionOps.releaseSession + bridge.unwatch + publishState {live:false} — P3 calls at run end. */
  releaseSession(sessionId: string): Promise<void>;
  /** Builds a BrowserStateDto from the registry + screencast status → bridge.publishState. */
  publishState(sessionId: string): void;
  screencastCount(): number;
  /** releaseSession(all live, flushing state) → bridge.close → research.close → pool.close; idempotent. */
  close(): Promise<void>;
}

/** The 10 s screencast-follow/load monitor cadence (unref'd — never holds the process open). */
const MONITOR_INTERVAL_MS = 10_000;

export async function createBrowserEngine(deps: BrowserEngineDeps): Promise<BrowserEngine> {
  const cfg = deps.cfg;
  const persistence = deps.persistence;
  const now = deps.now ?? Date.now;
  const log: (msg: string, err?: unknown) => void =
    deps.log ?? ((msg, err) => console.error(`[browser-engine] ${msg}`, err ?? ""));
  const fetchImpl = deps.fetchImpl ?? createSsrfGuardedFetch(cfg);
  const workspaceDir: (userId: string, sessionId: string) => Promise<string> =
    deps.workspaceDir ??
    (async (userId: string, sessionId: string) => {
      const root = process.env.OVID_WORKSPACES_ROOT ?? "/workspaces/users";
      const dir = join(root, userId, "sessions", sessionId);
      await mkdir(dir, { recursive: true });
      return dir;
    });

  // -------------------------------------------------------------------------
  // Dedicated browser uid — prepare BEFORE any process can be spawned. A
  // failure here rejects engine construction (worker boot), never a silent
  // root fallback.
  // -------------------------------------------------------------------------

  const uidDrop =
    deps.prepareUidDrop !== undefined
      ? await deps.prepareUidDrop(cfg)
      : await prepareBrowserUidDrop(cfg);

  // -------------------------------------------------------------------------
  // Core services (Tasks 4-13)
  // -------------------------------------------------------------------------

  const registry = createBrowserSessionRegistry({ now });

  // The pool's idle-eviction hook is the engine's flush-before-close path;
  // it only ever runs after construction, so it may reference the bridge and
  // the screencast bookkeeping declared below.
  const pool = createBrowserPool(cfg, {
    now,
    uidDrop,
    onIdleEvict: (sessionId: string, context: BrowserContext) => onPoolIdleEvict(sessionId, context),
  });

  const bridge = createRedisBrowserBridge({
    redisFactory: deps.redisFactory,
    now,
    log,
    handlers: {
      onViewersChange: (sessionId: string, viewers: number) => onViewersChange(sessionId, viewers),
      onInput: (sessionId: string, event: BrowserInputEvent) => onInput(sessionId, event),
      onTakeover: (sessionId: string, enabled: boolean) => onTakeover(sessionId, enabled),
    },
  });

  const lightpanda: LightpandaPool | null = lightpandaAvailable(cfg.lightpandaBin)
    ? createLightpandaPool(cfg.lightpandaBin as string, cfg, { uidDrop })
    : null;

  const research = createResearchBrowser({
    fetchImpl,
    lightpanda,
    cfg,
    chromiumRead: async (url: string, timeoutMs: number) => {
      const lease = await pool.acquireTier1();
      try {
        await lease.page.goto(url, { waitUntil: "domcontentloaded", timeout: timeoutMs });
        const html = await lease.page.content();
        const title = await lease.page.title();
        return { html, title, finalUrl: lease.page.url() };
      } finally {
        await lease.release();
      }
    },
  });

  const ops: SessionOps = {
    pool,
    registry,
    persistence,
    cfg,
    notifyState: (sessionId: string) => publishState(sessionId),
    log,
  };

  const tools = createBrowserTools({
    pool,
    registry,
    persistence,
    cfg,
    workspaceDir,
    notifyState: (sessionId: string) => publishState(sessionId),
    log,
    now,
  });

  // -------------------------------------------------------------------------
  // Screencast bookkeeping
  // -------------------------------------------------------------------------

  interface CastEntry {
    handle: ScreencastHandle;
    page: Page;
    stepIndex: number;
  }

  const casts = new Map<string, CastEntry>();
  /** In-flight starts/restarts — the dedup guard against double casts. */
  const starting = new Set<string>();
  /** Probed once per engine lifetime; null = not probed yet. Failure ⇒ jpeg forever. */
  let webpSupport: boolean | null = null;

  function currentFormat(): BrowserStateDto["frameFormat"] {
    return webpSupport === true ? "webp" : "jpeg";
  }

  async function startScreencastFor(sessionId: string): Promise<void> {
    if (casts.has(sessionId) || starting.has(sessionId)) return;
    if (casts.size + starting.size >= cfg.maxActiveScreencasts) return; // overflow: stay off
    const page = registry.activePage(sessionId);
    if (page === null) return; // no session yet — openSession re-triggers after ensure

    starting.add(sessionId);
    try {
      if (webpSupport === null) {
        // T6 carry: the probe NAVIGATES the page to its inline animated
        // fixture. Snapshot the URL, probe, then undo the navigation — only
        // ever the probe's own (tools refuse data: URLs, so a data: page here
        // IS the probe fixture; a concurrent tool navigation is not clobbered).
        const preProbeUrl = page.url();
        webpSupport = await probeWebpSupport(page, cfg.screencast);
        if (
          registry.activePage(sessionId) === page &&
          page.url().startsWith("data:") &&
          page.url() !== preProbeUrl
        ) {
          await page
            .goto(preProbeUrl, { waitUntil: "domcontentloaded", timeout: 30_000 })
            .catch((err: unknown) => log(`probe restore navigation failed for session ${sessionId}`, err));
        }
      }
      // Viewers may have left while the probe ran — never start an orphan cast.
      if (bridge.viewerCount(sessionId) === 0) return;
      const handle = await startScreencast(
        page,
        cfg.screencast,
        (frame) => bridge.publishFrame(sessionId, frame),
        { format: currentFormat() },
      );
      if (bridge.viewerCount(sessionId) === 0) {
        await handle.stop().catch(() => {});
        return;
      }
      casts.set(sessionId, { handle, page, stepIndex: 0 });
      publishState(sessionId);
    } finally {
      starting.delete(sessionId);
    }
  }

  async function stopScreencast(sessionId: string): Promise<void> {
    const entry = casts.get(sessionId);
    if (entry === undefined) return;
    casts.delete(sessionId);
    try {
      await entry.handle.stop();
    } catch (err) {
      log(`screencast stop failed for session ${sessionId}`, err);
    }
    publishState(sessionId);
  }

  async function stepDown(sessionId: string): Promise<void> {
    const entry = casts.get(sessionId);
    if (entry === undefined) return;
    entry.stepIndex = Math.min(entry.stepIndex + 1, SCREENCAST_LADDER.length - 1);
    try {
      await entry.handle.adjust(SCREENCAST_LADDER[entry.stepIndex]);
    } catch (err) {
      // A cast that cannot step down is a dead cast — drop it rather than
      // leave a live-flagged handle (adjust marks itself stopped when its
      // restart rejects; stop() is the documented cleanup).
      log(`screencast step-down failed for session ${sessionId} — stopping`, err);
      await stopScreencast(sessionId);
    }
  }

  /** The 10 s unref'd monitor: tab-follow restarts + load/overflow step-downs. */
  async function monitorPass(): Promise<void> {
    if (closePromise !== null) return; // a close() already ran — never restart a cast
    const load = loadavg()[0];
    for (const [sessionId, entry] of [...casts]) {
      try {
        const active = registry.activePage(sessionId);
        if (active === null || active !== entry.page || entry.page.isClosed()) {
          // The screencast follows the active tab: restart it on the new page.
          await stopScreencast(sessionId);
          if (closePromise === null && bridge.viewerCount(sessionId) > 0) {
            await startScreencastFor(sessionId);
          }
          continue;
        }
        if (load > cfg.screencastLoadMax || bridge.viewerCount(sessionId) > cfg.maxActiveScreencasts) {
          await stepDown(sessionId);
        }
      } catch (err) {
        log(`screencast monitor pass failed for session ${sessionId}`, err);
      }
    }
  }

  const monitorTimer = setInterval(() => {
    void monitorPass().catch((err: unknown) => log("screencast monitor pass crashed", err));
  }, MONITOR_INTERVAL_MS);
  monitorTimer.unref?.();

  // -------------------------------------------------------------------------
  // State publishing
  // -------------------------------------------------------------------------

  /** page.title() is async — the cache backs the sync publishState. */
  const titleCache = new Map<string, string>();

  function deadState(sessionId: string): BrowserStateDto {
    return {
      sessionId,
      live: false,
      url: null,
      title: null,
      takeover: false,
      screencast: false,
      frameFormat: currentFormat(),
      viewport: { width: cfg.screencast.width, height: cfg.screencast.height },
    };
  }

  async function refreshTitle(sessionId: string, page: Page): Promise<void> {
    try {
      const title = await page.title();
      if (registry.get(sessionId) === null) return;
      if (titleCache.get(sessionId) !== title) {
        titleCache.set(sessionId, title);
        publishState(sessionId); // terminates: the refreshed title no longer differs
      }
    } catch {
      // page/context gone — the next publish builds a dead state anyway
    }
  }

  function publishState(sessionId: string): void {
    const session = registry.get(sessionId);
    if (session === null) {
      titleCache.delete(sessionId);
      bridge.publishState(sessionId, deadState(sessionId));
      return;
    }
    const page = session.tabs[session.activeIndex] ?? session.handle.page;
    const viewport = page.viewportSize() ?? { width: cfg.screencast.width, height: cfg.screencast.height };
    bridge.publishState(sessionId, {
      sessionId,
      live: true,
      url: page.url(),
      title: titleCache.get(sessionId) ?? null,
      takeover: session.takeover,
      screencast: casts.has(sessionId),
      frameFormat: currentFormat(),
      viewport,
    });
    // The first publish after a navigation carries the previous title; the
    // refresh republishes with the fresh one. The gateway keeps the latest.
    void refreshTitle(sessionId, page);
  }

  // -------------------------------------------------------------------------
  // Bridge handlers
  // -------------------------------------------------------------------------

  function onViewersChange(sessionId: string, viewers: number): void {
    if (viewers === 0) {
      void stopScreencast(sessionId);
      return;
    }
    if (viewers > cfg.maxActiveScreencasts) {
      void stepDown(sessionId);
      return;
    }
    if (casts.has(sessionId) || starting.has(sessionId)) return;
    if (casts.size + starting.size >= cfg.maxActiveScreencasts) return;
    void startScreencastFor(sessionId).catch((err: unknown) =>
      log(`screencast start failed for session ${sessionId}`, err),
    );
  }

  /**
   * ONE serial queue per session: input must be applied in redis arrival
   * order (T7/T8 carry — concurrent un-awaited dispatches would interleave at
   * the Playwright channel). Errors are logged, never thrown into redis.
   * The queue entry is pruned when it drains, and on every session teardown —
   * a long-lived worker must not accumulate empty arrays per session id.
   */
  const inputQueues = new Map<string, BrowserInputEvent[]>();
  const inputPumping = new Set<string>();

  function pruneInputQueue(sessionId: string): void {
    const queue = inputQueues.get(sessionId);
    // A pumping loop re-creates nothing: it drains what exists and exits, so
    // deleting an EMPTY queue here is always safe; a non-empty one (events
    // raced the teardown) is left for its pump to drain against the dead
    // session and then pruned by the pump itself.
    if (queue !== undefined && queue.length === 0) inputQueues.delete(sessionId);
  }

  function onInput(sessionId: string, event: BrowserInputEvent): void {
    let queue = inputQueues.get(sessionId);
    if (queue === undefined) {
      queue = [];
      inputQueues.set(sessionId, queue);
    }
    queue.push(event);
    if (inputPumping.has(sessionId)) return;
    inputPumping.add(sessionId);
    void (async () => {
      try {
        for (;;) {
          const next = inputQueues.get(sessionId)?.shift();
          if (next === undefined) break;
          const page = registry.activePage(sessionId);
          if (page === null) continue; // session gone — drop the event
          try {
            // Viewer input is activity: reset the idle-eviction clock so an
            // interacting user never has the tab evicted mid-interaction.
            registry.touch(sessionId);
            await applyInputEvent(page, next);
          } catch (err) {
            log(`input event failed on session ${sessionId}`, err);
          }
        }
      } finally {
        inputPumping.delete(sessionId);
        pruneInputQueue(sessionId);
      }
    })();
  }

  function onTakeover(sessionId: string, enabled: boolean): void {
    registry.setTakeover(sessionId, enabled);
    publishState(sessionId);
  }

  // -------------------------------------------------------------------------
  // Session lifecycle
  // -------------------------------------------------------------------------

  async function openSession(sessionId: string, userId: string): Promise<SessionBrowser> {
    // Watch FIRST: a viewer joining while the context is being acquired must
    // not be missed — the join handler would find no session yet, and the
    // viewerCount re-check below starts the cast for exactly that race.
    await bridge.watch(sessionId);
    const session = await ensureSession(ops, { sessionId, userId });
    if (bridge.viewerCount(sessionId) > 0) {
      void startScreencastFor(sessionId).catch((err: unknown) =>
        log(`screencast start failed for session ${sessionId}`, err),
      );
    }
    return session;
  }

  async function releaseSession(sessionId: string): Promise<void> {
    await stopScreencast(sessionId);
    // capture → flush → registry.close → pool.releaseLive → notify {live:false}
    await releaseSessionOps(ops, sessionId);
    pruneInputQueue(sessionId);
    await bridge.unwatch(sessionId);
    publishState(sessionId); // the pinned post-unwatch {live:false} publish
  }

  /**
   * Pool idle eviction (the 3-min hibernation mirror, research §5 knob 5):
   * stop the cast, capture + flush the storageState BEFORE the context dies
   * (evictIdle closes it right after this hook), then registry/bridge
   * teardown, then the {live:false} publish — the exact pinned ordering.
   */
  async function onPoolIdleEvict(sessionId: string, context: BrowserContext): Promise<void> {
    await stopScreencast(sessionId);
    const session = registry.get(sessionId);
    if (session !== null) {
      try {
        const captured = (await context.storageState()) as StorageState;
        if (persistence !== null) await persistence.flush(session.userId, captured);
      } catch (err) {
        log(`failed to capture/flush browser state for evicted session ${sessionId}`, err);
      }
      registry.close(sessionId);
    }
    titleCache.delete(sessionId);
    pruneInputQueue(sessionId);
    await bridge.unwatch(sessionId);
    publishState(sessionId);
  }

  // -------------------------------------------------------------------------
  // close()
  // -------------------------------------------------------------------------

  let closePromise: Promise<void> | null = null;

  function close(): Promise<void> {
    if (closePromise !== null) return closePromise;
    closePromise = (async () => {
      clearInterval(monitorTimer);
      // Flush BEFORE any process dies (Review Focus #2): every live session
      // goes through the full capture→flush→close path first. The REGISTRY
      // is the enumeration source (the "context alive" set) — the engine's
      // published-live set is a subset, because browser_open suppresses the
      // creation notify and publishes only after a successful goto, so a
      // timed-out first navigation leaves an unpublished session whose
      // Set-Cookie state must still be flushed (review I1).
      for (const sessionId of registry.ids()) {
        try {
          await releaseSession(sessionId);
        } catch (err) {
          // Per-session isolation (review M3): one throwing context.close()
          // must never abort the loop — bridge/research/pool teardown below
          // has to run so the worker's shutdown() still exits 0.
          log(`releaseSession failed during close for session ${sessionId} — continuing`, err);
        }
      }
      // Safety net: casts without a registry entry (should not exist — every
      // teardown path stops them — but a leaked CDP session is exactly the
      // thing close() must never leave behind).
      for (const sessionId of [...casts.keys()]) await stopScreencast(sessionId);
      await bridge.close();
      await research.close();
      await pool.close();
      // Every browser process is gone now; remove the uid-drop runtime tree.
      await uidDrop?.cleanup();
    })();
    return closePromise;
  }

  return {
    pool,
    registry,
    research,
    tools,
    openSession,
    releaseSession,
    publishState,
    screencastCount: () => casts.size,
    close,
  };
}
