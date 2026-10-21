import { describe, expect, it, vi, type Mock } from "vitest";
import type { Page } from "playwright-core";

import {
  TAB_CREATION_FORBIDDEN_CODE,
  TAB_CREATION_FORBIDDEN_COPY,
  BrowserTabCreationForbiddenError,
  TabCreationForbiddenError,
  UserTabCreationForbiddenError,
  isTabCreationForbiddenError,
  isUserTabCreateCtl,
} from "./tabPolicy.js";
import { createBrowserSessionRegistry } from "./sessions.js";
import type { LiveContextHandle } from "./pool.js";

interface StubPage {
  on: Mock<(ev: string, cb: (arg: never) => void) => void>;
  close: Mock<() => Promise<void>>;
}

function stubPage(): StubPage {
  return {
    on: vi.fn(),
    close: vi.fn(async () => {}),
  };
}

function stubHandle(page: StubPage): LiveContextHandle {
  return {
    sessionId: "u1",
    context: { close: vi.fn(async () => {}) } as unknown as LiveContextHandle["context"],
    page: page as unknown as Page,
    createdAt: 0,
    touch: vi.fn(),
  };
}

function registryWithSession(): ReturnType<typeof createBrowserSessionRegistry> {
  const registry = createBrowserSessionRegistry();
  registry.open({ sessionId: "s1", userId: "u1", handle: stubHandle(stubPage()) });
  return registry;
}

describe("agent-owned tabs (spec §8)", () => {
  it("the first tab is created by the agent's session open", () => {
    const registry = registryWithSession();
    const session = registry.get("s1")!;
    expect(session.tabs).toHaveLength(1);
    expect(session.activeIndex).toBe(0);
  });

  it("a user cannot create the FIRST tab either", () => {
    const registry = createBrowserSessionRegistry();
    expect(() =>
      registry.open({ sessionId: "s1", userId: "u1", handle: stubHandle(stubPage()) }, "user"),
    ).toThrow(BrowserTabCreationForbiddenError);
    expect(registry.get("s1")).toBeNull();
  });

  it("a user-initiated tab create is refused with the typed error and adds nothing", () => {
    const registry = registryWithSession();
    const before = registry.get("s1")!.tabs.length;
    const page = stubPage();

    let thrown: unknown;
    try {
      registry.addTab("s1", page as unknown as Page, "user");
    } catch (err) {
      thrown = err;
    }

    expect(thrown).toBeInstanceOf(BrowserTabCreationForbiddenError);
    expect(thrown).toBeInstanceOf(TabCreationForbiddenError);
    expect(thrown).toBeInstanceOf(UserTabCreationForbiddenError);
    expect(isTabCreationForbiddenError(thrown)).toBe(true);
    const typed = thrown as BrowserTabCreationForbiddenError;
    expect(typed.code).toBe(TAB_CREATION_FORBIDDEN_CODE);
    expect(typed.actor).toBe("user");
    expect(typed.sessionId).toBe("s1");
    expect(typed.message).toContain(TAB_CREATION_FORBIDDEN_COPY);

    expect(registry.get("s1")!.tabs).toHaveLength(before);
    expect(page.on).not.toHaveBeenCalled(); // never instrumented
  });

  it("an actor-less addTab is refused (tab creation is never opt-in by default)", () => {
    const registry = registryWithSession();
    const before = registry.get("s1")!.tabs.length;
    const page = stubPage();

    expect(() => registry.addTab("s1", page as unknown as Page)).toThrow(
      BrowserTabCreationForbiddenError,
    );
    expect(registry.get("s1")!.tabs).toHaveLength(before);
    expect(page.on).not.toHaveBeenCalled();
  });

  it("createTabAsUser always throws, even for an unknown session", () => {
    const registry = registryWithSession();
    expect(() => registry.createTabAsUser("s1")).toThrow(BrowserTabCreationForbiddenError);
    expect(() => registry.createTabAsUser("does-not-exist")).toThrow(BrowserTabCreationForbiddenError);
  });

  it("the agent may add tabs; a user may switch and close them but never add", () => {
    const registry = registryWithSession();
    const p1 = stubPage();
    const index = registry.addTabForAgent("s1", p1 as unknown as Page);
    expect(index).toBe(1);

    // User SELECT is allowed.
    expect(registry.switchTab("s1", 0, "user")).toBe(true);
    expect(registry.activePage("s1")).toBe(registry.get("s1")!.tabs[0]);

    // User CLOSE is allowed (two tabs remain one).
    expect(registry.closeTab("s1", 1, "user")).toBe(true);
    expect(registry.get("s1")!.tabs).toHaveLength(1);

    // User ADD is still refused.
    expect(() => registry.addTab("s1", stubPage() as unknown as Page, "user")).toThrow(
      BrowserTabCreationForbiddenError,
    );
  });

  it("the bridge recognises create-shaped ctl payloads from a client", () => {
    expect(isUserTabCreateCtl({ type: "new_tab", url: "https://x.test/" })).toBe(true);
    expect(isUserTabCreateCtl({ type: "create_tab" })).toBe(true);
    expect(isUserTabCreateCtl({ type: "switch_tab", index: 0 })).toBe(false);
    expect(isUserTabCreateCtl({ type: "viewer_join", viewerId: "v1" })).toBe(false);
    expect(isUserTabCreateCtl(null)).toBe(false);
    expect(isUserTabCreateCtl("new_tab")).toBe(false);
  });
});
