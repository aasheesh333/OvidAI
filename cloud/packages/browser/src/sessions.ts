/**
 * BrowserSessionRegistry — per-session bookkeeping on top of the pool's live
 * handles (Task 4). A `SessionBrowser` is the tabs + buffers + takeover flag
 * that every browser tool talks to:
 *
 *  - tabs: a session always keeps exactly one page (closeTab refuses the
 *    last one); `addTab` instruments and makes the new tab active.
 *  - buffers: console/network rings (capped, drop-oldest), held dialogs and
 *    recorded popups — per SESSION, shared across its tabs, matching Dart's
 *    per-tab-strip model.
 *  - dialogs are HELD (never auto-resolved on capture): the tool side picks
 *    accept/dismiss. A hold expires after DIALOG_HOLD_MS (unref'd timer) so
 *    a forgotten dialog can't block the page forever — the timeout
 *    auto-dismisses, drops the entry and reports via onDialogTimeout.
 *  - popups: recorded and immediately CLOSED — server-side popups never
 *    render; `browser_popups open` re-opens one as a real tab.
 *  - takeover: exactly one controller at a time; while flagged, every
 *    browser tool is paused with TAKEOVER_REFUSAL. The flag is void
 *    without a viewer — the engine releases it when the session's last
 *    viewer disconnects (leave or stale sweep), so tools never stay
 *    refused on an abandoned session.
 *
 * Ownership boundary (Review Focus): the POOL owns context closing —
 * `close()` removes the registry entry only; `closeTab` closes pages
 * (not the context).
 */

import type { Page } from "playwright-core";

import type { LiveContextHandle } from "./pool.js";
import { assertTabCreationAllowed, type TabActor } from "./tabPolicy.js";

export const TAKEOVER_REFUSAL =
  "The user is currently controlling the browser live (takeover). Browser tools are paused — wait for the user to release control, then retry.";
export const CONSOLE_BUFFER_CAP = 200;
export const NETWORK_BUFFER_CAP = 200;
export const DIALOG_HOLD_MS = 10_000;

export interface ConsoleEntry {
  ts: number;
  type: string;
  text: string;
  location: string | null;
}

export interface NetworkEntry {
  ts: number;
  url: string;
  method: string;
  status: number | null;
  failure: string | null;
}

export interface DialogEntry {
  id: string;
  type: "alert" | "confirm" | "prompt" | "beforeunload";
  message: string;
  defaultValue: string | null;
  resolve(action: "accept" | "dismiss", text?: string): void;
  heldAt: number;
}

export interface PopupEntry {
  url: string;
  openedAt: number;
}

export interface SessionBrowser {
  sessionId: string;
  userId: string;
  handle: LiveContextHandle;
  tabs: Page[];
  activeIndex: number;
  takeover: boolean;
  /** Wave 5 FE-026: the gateway viewer that holds takeover (null when none / unknown). */
  takeoverViewerId: string | null;
  lastActivityAt: number;
  console: ConsoleEntry[];
  network: NetworkEntry[];
  dialogs: DialogEntry[];
  popups: PopupEntry[];
}

export interface BrowserSessionRegistry {
  /**
   * Registers a live handle; instruments entry.handle.page as tab 0. The
   * first tab is AGENT-owned: a `"user"` actor is refused with the typed
   * error before any entry is created.
   */
  open(entry: { sessionId: string; userId: string; handle: LiveContextHandle }, actor?: TabActor): SessionBrowser;
  get(sessionId: string): SessionBrowser | null;
  /**
   * Owner-scoped lookup: the entry only when its userId matches `userId`.
   * Every tool-facing read of a caller-supplied browser key goes through this
   * (a shared key must never expose another account's session).
   */
  getOwned(sessionId: string, userId: string): SessionBrowser | null;
  /**
   * Every live session id — exactly the "context alive" set. The Task-14
   * engine's close() enumerates this (its own published-live set is a
   * subset: browser_open suppresses the creation notify and publishes only
   * after a successful goto, so a timed-out first navigation leaves a
   * registry session that was never published).
   */
  ids(): string[];
  /** Removes the entry only — the POOL owns context closing. */
  close(sessionId: string): SessionBrowser | null;
  activePage(sessionId: string): Page | null;
  /**
   * Instruments, appends, switches active; returns the new index (-1 when
   * unknown). AGENT ONLY: an explicit `"agent"` actor is required, so an
   * omitted actor (legacy call site) is refused with the typed
   * `BrowserTabCreationForbiddenError` before any page is touched.
   */
  addTab(sessionId: string, page: Page, actor?: TabActor): number;
  /** Convenience for the agent tool path — always allowed. */
  addTabForAgent(sessionId: string, page: Page): number;
  /** A user-initiated create: ALWAYS throws the typed refusal. */
  createTabAsUser(sessionId: string): never;
  /** Closes the page (not the context), fixes activeIndex; refuses the last tab. */
  closeTab(sessionId: string, index: number, actor?: TabActor): boolean;
  /** Users may switch between existing tabs (never create one). */
  switchTab(sessionId: string, index: number, actor?: TabActor): boolean;
  /** false when session unknown. `viewerId` records the controller (cleared on release). */
  setTakeover(sessionId: string, enabled: boolean, viewerId?: string | null): boolean;
  /** TAKEOVER_REFUSAL when flagged, else null (unknown session ⇒ null). */
  refuseReasonIfTakeover(sessionId: string): string | null;
  /** lastActivityAt + handle.touch() — resets the pool's idle-eviction clock. */
  touch(sessionId: string): void;
}

export interface SessionRegistryOptions {
  now?(): number;
  onDialogTimeout?(d: DialogEntry): void;
}

/**
 * Internal per-session state: the SessionBrowser surface plus the registry
 * seams instrumentPage needs (clock, timeout hook) and the live dialog-hold
 * timers, so `resolve` and `close` can clear them.
 */
interface SessionInternal extends SessionBrowser {
  now(): number;
  onDialogTimeout?(d: DialogEntry): void;
  dialogSeq: number;
  dialogTimers: Map<string, ReturnType<typeof setTimeout>>;
}

export function createBrowserSessionRegistry(opts: SessionRegistryOptions = {}): BrowserSessionRegistry {
  const now = opts.now ?? Date.now;
  const sessions = new Map<string, SessionInternal>();

  function clearDialogTimers(s: SessionInternal): void {
    for (const timer of s.dialogTimers.values()) clearTimeout(timer);
    s.dialogTimers.clear();
  }

  function open(
    entry: { sessionId: string; userId: string; handle: LiveContextHandle },
    actor: TabActor = "agent",
  ): SessionBrowser {
    // The first tab is agent-owned, exactly like every later one.
    assertTabCreationAllowed(actor, entry.sessionId);
    // Re-opening an existing session replaces the stale entry — its hold
    // timers must not fire into the new one.
    const stale = sessions.get(entry.sessionId);
    if (stale) clearDialogTimers(stale);

    const s: SessionInternal = {
      sessionId: entry.sessionId,
      userId: entry.userId,
      handle: entry.handle,
      tabs: [],
      activeIndex: 0,
      takeover: false,
      takeoverViewerId: null,
      lastActivityAt: now(),
      console: [],
      network: [],
      dialogs: [],
      popups: [],
      now,
      onDialogTimeout: opts.onDialogTimeout,
      dialogSeq: 0,
      dialogTimers: new Map(),
    };
    s.tabs.push(entry.handle.page);
    instrumentPage(s, entry.handle.page);
    sessions.set(entry.sessionId, s);
    return s;
  }

  function get(sessionId: string): SessionBrowser | null {
    return sessions.get(sessionId) ?? null;
  }

  function getOwned(sessionId: string, userId: string): SessionBrowser | null {
    const s = sessions.get(sessionId);
    return s !== undefined && s.userId === userId ? s : null;
  }

  function close(sessionId: string): SessionBrowser | null {
    const s = sessions.get(sessionId);
    if (!s) return null;
    sessions.delete(sessionId);
    // Entry removal ONLY — the pool owns context closing. Hold timers are
    // dropped with the entry so nothing fires late into onDialogTimeout.
    clearDialogTimers(s);
    return s;
  }

  function activePage(sessionId: string): Page | null {
    const s = sessions.get(sessionId);
    return s ? s.tabs[s.activeIndex] ?? null : null;
  }

  function addTab(sessionId: string, page: Page, actor?: TabActor): number {
    // Agent-owned tabs: refuse a user (or an actor-less legacy caller) BEFORE
    // looking at the session. Tab creation is allowed only with an EXPLICIT
    // "agent" actor — the policy is not opt-in at each call site.
    assertTabCreationAllowed(actor, sessionId);
    const s = sessions.get(sessionId);
    if (!s) return -1;
    s.tabs.push(page);
    s.activeIndex = s.tabs.length - 1;
    s.lastActivityAt = now();
    instrumentPage(s, page);
    return s.activeIndex;
  }

  function createTabAsUser(sessionId: string): never {
    assertTabCreationAllowed("user", sessionId);
    // Unreachable: assertTabCreationAllowed always throws for a user actor.
    throw new Error("unreachable: user tab creation was not refused");
  }

  function closeTab(sessionId: string, index: number, _actor: TabActor = "agent"): boolean {
    const s = sessions.get(sessionId);
    if (!s) return false;
    if (index < 0 || index >= s.tabs.length) return false;
    if (s.tabs.length <= 1) return false; // a session always keeps one page
    const [page] = s.tabs.splice(index, 1);
    void page.close().catch(() => {
      // already closed / browser gone — the tabs array no longer holds it
    });
    // The POOL owns the context; this closes the PAGE only.
    if (s.activeIndex > index) s.activeIndex -= 1;
    else s.activeIndex = Math.min(s.activeIndex, s.tabs.length - 1);
    return true;
  }

  function switchTab(sessionId: string, index: number, _actor: TabActor = "agent"): boolean {
    const s = sessions.get(sessionId);
    if (!s) return false;
    if (index < 0 || index >= s.tabs.length) return false;
    s.activeIndex = index;
    return true;
  }

  function setTakeover(sessionId: string, enabled: boolean, viewerId?: string | null): boolean {
    const s = sessions.get(sessionId);
    if (!s) return false;
    s.takeover = enabled;
    s.takeoverViewerId = enabled ? (viewerId ?? null) : null;
    return true;
  }

  function refuseReasonIfTakeover(sessionId: string): string | null {
    const s = sessions.get(sessionId);
    return s?.takeover ? TAKEOVER_REFUSAL : null;
  }

  function touch(sessionId: string): void {
    const s = sessions.get(sessionId);
    if (!s) return;
    s.lastActivityAt = now();
    s.handle.touch();
  }

  return {
    open,
    get,
    getOwned,
    ids: () => [...sessions.keys()],
    close,
    activePage,
    addTab,
    addTabForAgent: (sessionId: string, page: Page) => addTab(sessionId, page, "agent"),
    createTabAsUser,
    closeTab,
    switchTab,
    setTakeover,
    refuseReasonIfTakeover,
    touch,
  };
}

/**
 * Pins the session's event wiring onto a page: console/network rings, held
 * dialogs (auto-dismiss after DIALOG_HOLD_MS), popup recording. Buffers live
 * on the SESSION, so every instrumented tab of a session feeds the same rings.
 * Exported because `open`/`addTab` are not the only entry points — the
 * screencast path can instrument a page against an existing session directly.
 */
export function instrumentPage(session: SessionBrowser, page: Page): void {
  const s = session as SessionInternal;
  const now = (): number => (typeof s.now === "function" ? s.now() : Date.now());

  page.on("console", (msg) => {
    const loc = msg.location();
    s.console.push({
      ts: now(),
      type: msg.type(),
      text: msg.text(),
      location: loc?.url ? `${loc.url}:${loc.lineNumber ?? 0}` : null,
    });
    if (s.console.length > CONSOLE_BUFFER_CAP) s.console.splice(0, s.console.length - CONSOLE_BUFFER_CAP);
  });

  const pushNetwork = (entry: NetworkEntry): void => {
    s.network.push(entry);
    if (s.network.length > NETWORK_BUFFER_CAP) s.network.splice(0, s.network.length - NETWORK_BUFFER_CAP);
  };

  page.on("response", (res) => {
    pushNetwork({
      ts: now(),
      url: res.url(),
      method: res.request().method(),
      status: res.status(),
      failure: null,
    });
  });

  page.on("requestfailed", (req) => {
    pushNetwork({
      ts: now(),
      url: req.url(),
      method: req.method(),
      status: null,
      failure: req.failure()?.errorText ?? "failed",
    });
  });

  page.on("dialog", (dialog) => {
    const id = `d${++s.dialogSeq}`;
    const entry: DialogEntry = {
      id,
      type: dialog.type() as DialogEntry["type"],
      message: dialog.message(),
      defaultValue: dialog.defaultValue() || null,
      heldAt: now(),
      resolve(action, text) {
        const timer = s.dialogTimers.get(id);
        if (!timer) return; // already timed out (or resolved+removed)
        clearTimeout(timer);
        s.dialogTimers.delete(id);
        const i = s.dialogs.indexOf(entry);
        if (i !== -1) s.dialogs.splice(i, 1);
        if (action === "accept") void dialog.accept(text).catch(() => {});
        else void dialog.dismiss().catch(() => {});
      },
    };
    // Hold the dialog — NEVER auto-resolve on capture. The tool side (or the
    // user via the UI) decides; the page's JS stays blocked until then.
    const timer = setTimeout(() => {
      s.dialogTimers.delete(id);
      const i = s.dialogs.indexOf(entry);
      if (i !== -1) s.dialogs.splice(i, 1);
      void dialog.dismiss().catch(() => {});
      s.onDialogTimeout?.(entry);
    }, DIALOG_HOLD_MS);
    timer.unref?.();
    s.dialogTimers.set(id, timer);
    s.dialogs.push(entry);
  });

  page.on("popup", (popup) => {
    s.popups.push({ url: popup.url(), openedAt: now() });
    // Server-side popups never render — close the page; `browser_popups open`
    // re-opens the recorded URL as a real tab.
    void popup.close().catch(() => {});
  });
}
