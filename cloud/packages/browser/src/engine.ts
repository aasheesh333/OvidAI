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
 *  - Viewer input is gated on takeover SERVER-side: without the flag the
 *    agent owns the page and events are dropped (the client's own gate is
 *    a nicety, not the boundary). The flag is likewise void without a
 *    viewer — the last leave, or the bridge's stale-viewer sweep, releases
 *    it; the pool's idle eviction destroys the whole entry instead.
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
import { BrowserOperationCoordinator, BrowserOperationRefusal } from "./browserOperations.js";
import type { BrowserEngineConfig } from "./config.js";
import { BrowserCredentialBroker, type CredentialUseApprover } from "./credentialBroker.js";

// index.ts is outside Task 9's scope; engine.ts is already a public barrel.
export { BrowserCredentialBroker, parseCredentialOrigin } from "./credentialBroker.js";
export { BrowserOperationCoordinator } from "./browserOperations.js";
export type {
  BrokerToolContext,
  BrowserCredentialBrokerDeps,
  BrowserCredentialLoginInput,
  BrowserCredentialLoginResult,
  CredentialLoginStatus,
  CredentialUseApproval,
  CredentialUseApprover,
} from "./credentialBroker.js";
export { BrowserOperationRefusal } from "./browserOperations.js";
export type { BrowserOperationKind, BrowserOperationOptions } from "./browserOperations.js";
import { createDetachGrace } from "./detachGrace.js";
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
import type {
  BrowserArtifactVaultPort,
  BrowserCredentialsPort,
  BrowserToolDef,
} from "./tools/types.js";
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
  /** Wave 6 W4: the owner-scoped credentials vault (agent list/use only). */
  credentials?: BrowserCredentialsPort;
  /** Task 9: no broker roster entry unless the flag and every dependency are present. */
  credentialApprover?: CredentialUseApprover;
  browserOperations?: BrowserOperationCoordinator;
  /** Test/composition seam; production normally constructs the broker from credentials. */
  credentialBroker?: BrowserCredentialBroker;
  /** Wave 6 W4: workspace ↔ Artifact Vault bridge for browser uploads/downloads. */
  artifactVault?: BrowserArtifactVaultPort;
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
  /** Attached viewers of a browser key (gateway viewer_join minus leaves/sweeps). */
  viewerCount(sessionId: string): number;
  /** Wave 6 W4: true while the detach grace window is holding the cast open. */
  detachGracePending(sessionId: string): boolean;
  /** True while the engine listens on the key's ctl/input channels. */
  isWatching(sessionId: string): boolean;
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

  const browserOperations = deps.browserOperations ?? new BrowserOperationCoordinator();
  const registry = createBrowserSessionRegistry({ now, browserOperations });

  // Wave 6 W4: after the last viewer leaves, keep rendering for the
  // configured window before converting to headless. While pending, the
  // browser is pinned exactly like a watched one — the pool's idle lease must
  // not close the context before the window elapses.
  const detachGrace = createDetachGrace({ graceMs: cfg.screencastDetachGraceMs });

  // The pool's idle-eviction hook is the engine's flush-before-close path;
  // it only ever runs after construction, so it may reference the bridge and
  // the screencast bookkeeping declared below.
  const pool = createBrowserPool(cfg, {
    now,
    uidDrop,
    browserOperations,
    onIdleEvict: (sessionId: string, context: BrowserContext) => onPoolIdleEvict(sessionId, context),
    // Wave 5 R3: a browser someone is watching is never idle-evicted; once
    // the last viewer leaves it idles headless until the normal lease ends.
    // Wave 6 W4: the detach grace window pins it too.
    isPinned: (sessionId: string) =>
      browserOperations.isCredentialOperationActive(sessionId) ||
      bridge.viewerCount(sessionId) > 0 ||
      detachGrace.pending(sessionId),
    isCredentialOperationActive: (sessionId: string) =>
      browserOperations.isCredentialOperationActive(sessionId),
  });

  const bridge = createRedisBrowserBridge({
    redisFactory: deps.redisFactory,
    now,
    log,
    handlers: {
      onViewersChange: (sessionId: string, viewers: number) => onViewersChange(sessionId, viewers),
      onInput: (sessionId: string, event: BrowserInputEvent) => onInput(sessionId, event),
      onTakeover: (sessionId: string, enabled: boolean, viewerId?: string) =>
        onTakeover(sessionId, enabled, viewerId),
      onSwitchTab: (sessionId: string, index: number, viewerId?: string) =>
        onSwitchTab(sessionId, index, viewerId),
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
    browserOperations,
    notifyState: (sessionId: string) => publishState(sessionId),
    log,
  };

  const credentialBroker =
    cfg.credentialBrokerEnabled && deps.credentials !== undefined && deps.credentialApprover !== undefined
      ? deps.credentialBroker ??
        new BrowserCredentialBroker({
          pool,
          registry,
          persistence,
          cfg,
          workspaceDir,
          notifyState: (sessionId: string) => publishState(sessionId),
          log,
          now,
          credentials: deps.credentials,
          operations: browserOperations,
        })
      : undefined;

  const tools = createBrowserTools({
    pool,
    registry,
    persistence,
    cfg,
    workspaceDir,
    notifyState: (sessionId: string) => publishState(sessionId),
    log,
    now,
    browserOperations,
    ...(deps.credentials !== undefined ? { credentials: deps.credentials } : {}),
    ...(credentialBroker !== undefined && deps.credentialApprover !== undefined
      ? { credentialBroker, credentialApprover: deps.credentialApprover }
      : {}),
    ...(deps.artifactVault !== undefined ? { artifactVault: deps.artifactVault } : {}),
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
  let screencastOperationSequence = 0;
  /** Probed once per engine lifetime; null = not probed yet. Failure ⇒ jpeg forever. */
  let webpSupport: boolean | null = null;

  function currentFormat(): BrowserStateDto["frameFormat"] {
    return webpSupport === true ? "webp" : "jpeg";
  }

  /** Wave 6 W4: keep casting for viewers OR a pending detach grace window. */
  function shouldCast(sessionId: string): boolean {
    return (
      !browserOperations.isCredentialOperationActive(sessionId) &&
      (bridge.viewerCount(sessionId) > 0 || detachGrace.pending(sessionId))
    );
  }

  async function startScreencastFor(sessionId: string): Promise<void> {
    screencastOperationSequence += 1;
    try {
      await browserOperations.withOperation(
        sessionId,
        { kind: "shared", operationId: `screencast-start:${screencastOperationSequence}` },
        async () => await startScreencastForShared(sessionId),
      );
    } catch (error) {
      if (error instanceof BrowserOperationRefusal) return;
      throw error;
    }
  }

  async function startScreencastForShared(sessionId: string): Promise<void> {
    const startEpoch = browserOperations.credentialEpoch(sessionId);
    if (browserOperations.isCredentialOperationActive(sessionId)) return;
    if (casts.has(sessionId) || starting.has(sessionId)) return;
    if (casts.size + starting.size >= cfg.maxActiveScreencasts) return; // overflow: stay off
    const page = registry.activePage(sessionId);
    if (page === null) return; // no session yet — openSession re-triggers after ensure
    if (!shouldCast(sessionId)) return;

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
      if (!shouldCast(sessionId)) return;
      const handle = await startScreencast(
        page,
        cfg.screencast,
        (frame) => {
          if (
            !browserOperations.isCredentialOperationActive(sessionId) &&
            browserOperations.credentialEpoch(sessionId) === startEpoch
          ) {
            bridge.publishFrame(sessionId, frame);
          }
        },
        {
          format: currentFormat(),
          isCredentialOperationActive: () => browserOperations.isCredentialOperationActive(sessionId),
          credentialEpoch: () => browserOperations.credentialEpoch(sessionId),
        },
      );
      if (
        browserOperations.isCredentialOperationActive(sessionId) ||
        browserOperations.credentialEpoch(sessionId) !== startEpoch
      ) {
        await handle.stop().catch(() => {});
        return;
      }
      if (!shouldCast(sessionId)) {
        await handle.stop().catch(() => {});
        return;
      }
      casts.set(sessionId, { handle, page, stepIndex: 0 });
      publishState(sessionId);
      // Wave 5: a static page emits no damage frame after start — capture one
      // so the viewer leaves its loading state at once.
      void refreshScreencast(sessionId, handle).catch((err: unknown) =>
        log(`initial frame failed for session ${sessionId}`, err),
      );
    } finally {
      starting.delete(sessionId);
    }
  }

  async function refreshScreencast(sessionId: string, handle: ScreencastHandle): Promise<void> {
    screencastOperationSequence += 1;
    await browserOperations.withOperation(
      sessionId,
      { kind: "shared", operationId: `screencast-refresh:${screencastOperationSequence}` },
      async () => await handle.refresh(),
    );
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
    if (browserOperations.isCredentialOperationActive(sessionId)) return;
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
        if (browserOperations.isCredentialOperationActive(sessionId)) {
          await stopScreencast(sessionId);
          continue;
        }
        const active = registry.activePage(sessionId);
        if (active === null || active !== entry.page || entry.page.isClosed()) {
          // The screencast follows the active tab: restart it on the new page.
          await stopScreencast(sessionId);
          if (closePromise === null && shouldCast(sessionId)) {
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
  const titleCacheEpoch = new Map<string, number>();
  /** Per-page tab titles (Wave 6 W4); pruned whenever a session publishes. */
  const tabTitleCache = new Map<Page, string>();
  const tabTitleCacheEpoch = new WeakMap<Page, number>();
  const refreshingTabTitles = new Set<string>();
  let stateOperationSequence = 0;

  function deadState(sessionId: string): BrowserStateDto & { credentialLock: boolean } {
    return {
      sessionId,
      live: false,
      credentialLock: false,
      url: null,
      title: null,
      takeover: false,
      takeoverViewerId: null,
      screencast: false,
      frameFormat: currentFormat(),
      viewport: { width: cfg.screencast.width, height: cfg.screencast.height },
      tabs: [],
      activeTabIndex: 0,
    };
  }

  function lockedState(sessionId: string): BrowserStateDto & { credentialLock: boolean } {
    return {
      ...deadState(sessionId),
      live: true,
      credentialLock: true,
    };
  }

  async function refreshTitle(sessionId: string, page: Page): Promise<void> {
    stateOperationSequence += 1;
    try {
      await browserOperations.withOperation(
        sessionId,
        { kind: "shared", operationId: `active-title:${stateOperationSequence}` },
        async () => {
          const readEpoch = browserOperations.credentialEpoch(sessionId);
          if (browserOperations.isCredentialOperationActive(sessionId)) return;
          const title = await page.title();
          if (
            browserOperations.isCredentialOperationActive(sessionId) ||
            browserOperations.credentialEpoch(sessionId) !== readEpoch
          ) {
            return;
          }
          if (registry.get(sessionId) === null) return;
          if (titleCache.get(sessionId) !== title || titleCacheEpoch.get(sessionId) !== readEpoch) {
            titleCache.set(sessionId, title);
            titleCacheEpoch.set(sessionId, readEpoch);
            publishState(sessionId); // terminates: the refreshed title no longer differs
          }
        },
      );
    } catch {
      // Page/context gone or credential admission refused: no stale publish.
    }
  }

  /**
   * Wave 5: the worker drives the engine through TOOLS only (never
   * openSession), so the first publish of a live session is where the engine
   * starts listening for viewers. Without this a viewer's viewer_join was
   * never seen on the production path and no frame was ever cast. After the
   * subscribe lands the state is republished: an attached gateway re-sends
   * its join on a live, non-casting state (browserChannel.ts), which starts
   * the cast for a viewer who opened the Browser screen BEFORE the agent
   * opened its first page.
   */
  const watchStarting = new Set<string>();
  function ensureWatched(sessionId: string): void {
    if (closePromise !== null || bridge.isWatching(sessionId) || watchStarting.has(sessionId)) return;
    watchStarting.add(sessionId);
    void bridge
      .watch(sessionId)
      .then(
        () => {
          if (registry.get(sessionId) !== null) publishState(sessionId);
          // Released/evicted while subscribing: never leave a watch behind.
          else return bridge.unwatch(sessionId);
          return undefined;
        },
        (err: unknown) => log(`browser watch failed for ${sessionId}`, err),
      )
      .finally(() => watchStarting.delete(sessionId));
  }

  function publishState(sessionId: string): void {
    if (browserOperations.isCredentialOperationActive(sessionId)) {
      bridge.publishState(sessionId, lockedState(sessionId));
      return;
    }
    const session = registry.get(sessionId);
    if (session === null) {
      titleCache.delete(sessionId);
      titleCacheEpoch.delete(sessionId);
      bridge.publishState(sessionId, deadState(sessionId));
      return;
    }
    ensureWatched(sessionId);
    const page = session.tabs[session.activeIndex] ?? session.handle.page;
    const viewport = page.viewportSize() ?? { width: cfg.screencast.width, height: cfg.screencast.height };
    const stateEpoch = browserOperations.credentialEpoch(sessionId);
    const currentTitle =
      titleCacheEpoch.get(sessionId) === stateEpoch ? (titleCache.get(sessionId) ?? null) : null;
    // Wave 6 W4: the tab strip is agent-owned. The list only ever contains
    // pages the agent opened; a viewer has no "new tab" path.
    const activeIndex = session.tabs.indexOf(page) === -1 ? session.activeIndex : session.tabs.indexOf(page);
    const tabs = session.tabs.map((tab, index) => ({
      index,
      url: tab.url() || null,
      title:
        tabTitleCacheEpoch.get(tab) === stateEpoch
          ? (tabTitleCache.get(tab) ?? null)
          : index === activeIndex
            ? currentTitle
            : null,
      active: index === activeIndex,
    }));
    bridge.publishState(sessionId, {
      sessionId,
      live: true,
      credentialLock: false,
      url: page.url(),
      title: currentTitle,
      takeover: session.takeover,
      takeoverViewerId: session.takeover ? session.takeoverViewerId : null,
      screencast: casts.has(sessionId),
      frameFormat: currentFormat(),
      viewport,
      tabs,
      activeTabIndex: activeIndex,
    } as BrowserStateDto & { credentialLock: boolean });
    // The first publish after a navigation carries the previous title; the
    // refresh republishes with the fresh one. The gateway keeps the latest.
    void refreshTitle(sessionId, page);
    void refreshTabTitles(sessionId);
  }

  /**
   * Tab titles are only known asynchronously. Refresh them after a publish
   * and republish once when anything changed — guarded per session so the
   * republish cannot recurse.
   */
  async function refreshTabTitles(sessionId: string): Promise<void> {
    if (browserOperations.isCredentialOperationActive(sessionId)) return;
    if (refreshingTabTitles.has(sessionId)) return;
    refreshingTabTitles.add(sessionId);
    stateOperationSequence += 1;
    try {
      await browserOperations.withOperation(
        sessionId,
        { kind: "shared", operationId: `tab-titles:${stateOperationSequence}` },
        async () => {
          const readEpoch = browserOperations.credentialEpoch(sessionId);
          const session = registry.get(sessionId);
          if (session === null || browserOperations.isCredentialOperationActive(sessionId)) return;
          let changed = false;
          const live = new Set(session.tabs);
          for (const tab of session.tabs) {
            try {
              const title = await tab.title();
              if (
                browserOperations.isCredentialOperationActive(sessionId) ||
                browserOperations.credentialEpoch(sessionId) !== readEpoch
              ) {
                return;
              }
              if (tabTitleCache.get(tab) !== title || tabTitleCacheEpoch.get(tab) !== readEpoch) {
                tabTitleCache.set(tab, title);
                tabTitleCacheEpoch.set(tab, readEpoch);
                changed = true;
              }
            } catch {
              // Page/context gone — the next publish drops it from `tabs`.
            }
          }
          if (
            browserOperations.isCredentialOperationActive(sessionId) ||
            browserOperations.credentialEpoch(sessionId) !== readEpoch
          ) {
            return;
          }
          // Drop cache entries for pages no longer in this session's strip.
          for (const cached of [...tabTitleCache.keys()]) {
            if (!live.has(cached)) tabTitleCache.delete(cached);
          }
          if (changed && registry.get(sessionId) !== null) publishState(sessionId);
        },
      );
    } catch {
      // Page/context gone or credential admission refused: no stale publish.
    } finally {
      refreshingTabTitles.delete(sessionId);
    }
  }

  // -------------------------------------------------------------------------
  // Bridge handlers
  // -------------------------------------------------------------------------

  /** Last seen viewer count per key — tells a join (increase) from a leave. */
  const viewerCounts = new Map<string, number>();

  function onViewersChange(sessionId: string, viewers: number): void {
    const previous = viewerCounts.get(sessionId) ?? 0;
    if (viewers === 0) viewerCounts.delete(sessionId);
    else viewerCounts.set(sessionId, viewers);
    if (browserOperations.isCredentialOperationActive(sessionId)) {
      publishState(sessionId);
      return;
    }
    if (viewers === 0) {
      // Takeover is void without a viewer: its owner is gone, and a flag
      // left set would brick every browser_* tool until idle eviction
      // destroys the session. Both disconnect paths funnel through here —
      // the explicit viewer_leave AND the bridge's stale-viewer sweep — so
      // one reset covers them (idle eviction needs none: registry.close
      // drops the whole entry). Mirrors onTakeover's set + publish.
      registry.setTakeover(sessionId, false);
      publishState(sessionId);
      // Wave 6 W4: keep the visual renderer alive for the grace window, then
      // convert to headless. With grace 0 this is the pre-W4 immediate stop.
      if (casts.has(sessionId) || starting.has(sessionId)) {
        detachGrace.schedule(sessionId, () => {
          void stopScreencast(sessionId).catch((err: unknown) =>
            log(`screencast stop after detach grace failed for session ${sessionId}`, err),
          );
        });
      }
      return;
    }
    // A viewer is back (or another one is): the grace conversion is moot.
    detachGrace.cancel(sessionId);
    // FE-026: takeover belongs to ONE viewer. When that viewer is gone
    // (leave or stale sweep) while others still watch, release it — the
    // remaining viewers must not inherit someone else's control.
    const session = registry.get(sessionId);
    if (
      session !== null &&
      session.takeover &&
      session.takeoverViewerId !== null &&
      !bridge.hasViewer(sessionId, session.takeoverViewerId)
    ) {
      registry.setTakeover(sessionId, false);
      publishState(sessionId);
    }
    if (viewers > cfg.maxActiveScreencasts) {
      void stepDown(sessionId);
      return;
    }
    const cast = casts.get(sessionId);
    if (cast !== undefined && viewers > previous) {
      // A viewer joined an already-running cast: it has seen neither the
      // state nor a frame yet. Republish the state and restart the cast so
      // chromium emits a fresh frame even on a static page.
      publishState(sessionId);
      void refreshScreencast(sessionId, cast.handle).catch(async (err: unknown) => {
        log(`screencast refresh failed for session ${sessionId} — stopping`, err);
        await stopScreencast(sessionId);
      });
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
  let inputOperationSequence = 0;

  const removeCredentialListener = browserOperations.addCredentialOperationListener((sessionId, active) => {
    if (active) {
      inputQueues.delete(sessionId);
      publishState(sessionId);
      void stopScreencast(sessionId).catch((err: unknown) =>
        log(`screencast stop at credential lock failed for session ${sessionId}`, err),
      );
      return;
    }
    publishState(sessionId);
    if (closePromise === null && shouldCast(sessionId)) {
      void startScreencastFor(sessionId).catch((err: unknown) =>
        log(`screencast restart after credential lock failed for session ${sessionId}`, err),
      );
    }
  });

  function pruneInputQueue(sessionId: string): void {
    const queue = inputQueues.get(sessionId);
    // A pumping loop re-creates nothing: it drains what exists and exits, so
    // deleting an EMPTY queue here is always safe; a non-empty one (events
    // raced the teardown) is left for its pump to drain against the dead
    // session and then pruned by the pump itself.
    if (queue !== undefined && queue.length === 0) inputQueues.delete(sessionId);
  }

  function onInput(sessionId: string, event: BrowserInputEvent): void {
    if (browserOperations.isCredentialOperationActive(sessionId)) return;
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
          if (browserOperations.isCredentialOperationActive(sessionId)) {
            inputQueues.delete(sessionId);
            break;
          }
          const next = inputQueues.get(sessionId)?.shift();
          if (next === undefined) break;
          if (browserOperations.isCredentialOperationActive(sessionId)) continue;
          const page = registry.activePage(sessionId);
          if (page === null) continue; // session gone — drop the event
          if (registry.get(sessionId)?.takeover !== true) {
            // Input exclusivity enforced SERVER-side: without the takeover
            // flag the agent owns the page, and a buggy or older client's
            // event must never reach the Playwright channel. Dropped with a
            // log only — the tool side's TAKEOVER_REFUSAL is the mirror for
            // the tool half, but a client that should not be sending has no
            // state change to signal. Checked at dispatch time, so a flag
            // released mid-queue also guards the tail.
            log(`dropping input event on session ${sessionId} — takeover is off`);
            continue;
          }
          try {
            inputOperationSequence += 1;
            await browserOperations.withOperation(
              sessionId,
              { kind: "shared", operationId: `viewer-input:${inputOperationSequence}` },
              async () => {
                if (registry.get(sessionId)?.takeover !== true) return;
                // Viewer input is activity: reset the idle-eviction clock so an
                // interacting user never has the tab evicted mid-interaction.
                registry.touch(sessionId);
                // The COMPLETE dispatch (including long-press sleeps and every
                // swipe move/up) is shared work, so exclusive entry drains it.
                await applyInputEvent(page, next);
              },
            );
          } catch (err) {
            if (err instanceof BrowserOperationRefusal) continue;
            log(`input event failed on session ${sessionId}`, err);
          }
        }
      } finally {
        inputPumping.delete(sessionId);
        pruneInputQueue(sessionId);
      }
    })();
  }

  function onTakeover(sessionId: string, enabled: boolean, viewerId?: string): void {
    if (browserOperations.isCredentialOperationActive(sessionId)) return;
    registry.setTakeover(sessionId, enabled, viewerId ?? null);
    publishState(sessionId);
  }

  /**
   * Wave 6 W4: a viewer selected an existing tab. Switching is view-only —
   * there is no path here that creates a page. The screencast follows the
   * active tab immediately rather than waiting for the 10 s monitor.
   */
  function onSwitchTab(sessionId: string, index: number, _viewerId?: string): void {
    if (browserOperations.isCredentialOperationActive(sessionId)) return;
    const session = registry.get(sessionId);
    if (session === null) return;
    const previous = session.tabs[session.activeIndex] ?? null;
    if (!registry.switchTab(sessionId, index)) return;
    const next = registry.activePage(sessionId);
    publishState(sessionId);
    if (next === null || next === previous) return;
    const cast = casts.get(sessionId);
    if (cast === undefined || cast.page === next) return;
    void (async () => {
      await stopScreencast(sessionId);
      if (bridge.viewerCount(sessionId) > 0 || detachGrace.pending(sessionId)) {
        await startScreencastFor(sessionId);
      }
    })().catch((err: unknown) => log(`tab-switch screencast restart failed for session ${sessionId}`, err));
  }

  // -------------------------------------------------------------------------
  // Session lifecycle
  // -------------------------------------------------------------------------

  async function openSession(sessionId: string, userId: string): Promise<SessionBrowser> {
    if (browserOperations.isCredentialOperationActive(sessionId)) {
      throw new BrowserOperationRefusal("credential_operation_in_progress");
    }
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
    if (browserOperations.isCredentialOperationActive(sessionId)) {
      publishState(sessionId);
      throw new BrowserOperationRefusal("credential_operation_in_progress");
    }
    detachGrace.cancel(sessionId);
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
    if (browserOperations.isCredentialOperationActive(sessionId)) return;
    detachGrace.cancel(sessionId);
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
    titleCacheEpoch.delete(sessionId);
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
      detachGrace.clear();
      inputQueues.clear();
      // Abort brokers first and await their fenced field cleanup BEFORE any
      // registry/pool persistence or context close can observe the page.
      await browserOperations.close();
      removeCredentialListener();
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
    viewerCount: (sessionId: string) => bridge.viewerCount(sessionId),
    detachGracePending: (sessionId: string) => detachGrace.pending(sessionId),
    isWatching: (sessionId: string) => bridge.isWatching(sessionId),
    close,
  };
}
