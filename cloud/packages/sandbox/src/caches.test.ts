import { describe, expect, it } from "vitest";
import { BASE_JAIL_ENV } from "./invocation.js";
import { cachePruneArgv, installEnv, ovidInstallArgv, STORE_PATHS } from "./caches.js";

// Task 10 portable contract: the per-user store surface is exactly these four
// exports, and every value must stay in lockstep with BASE_JAIL_ENV (Task 5)
// and the /usr/local/bin/ovid shim baked into the rootfs (Task 3).

describe("STORE_PATHS", () => {
  it("pins the exact jail paths for both per-user package stores", () => {
    expect(STORE_PATHS.pnpmStore).toBe("/root/.cache/pnpm-store");
    expect(STORE_PATHS.uvCache).toBe("/root/.cache/uv");
  });

  it("matches the BASE_JAIL_ENV store variables exactly (no env-wiring drift)", () => {
    expect(BASE_JAIL_ENV.NPM_CONFIG_STORE_DIR).toBe(STORE_PATHS.pnpmStore);
    expect(BASE_JAIL_ENV.UV_CACHE_DIR).toBe(STORE_PATHS.uvCache);
  });

  it("is frozen — callers cannot mutate the shared constant", () => {
    expect(Object.isFrozen(STORE_PATHS)).toBe(true);
  });
});

describe("ovidInstallArgv", () => {
  it("builds the ovid dispatcher argv for one package", () => {
    expect(ovidInstallArgv(["is-number"])).toEqual([
      "/usr/local/bin/ovid",
      "install",
      "is-number",
    ]);
  });

  it("keeps package order and passes several packages through", () => {
    expect(ovidInstallArgv(["is-number", "left-pad", "ms"])).toEqual([
      "/usr/local/bin/ovid",
      "install",
      "is-number",
      "left-pad",
      "ms",
    ]);
  });

  it("with no packages still requests an install (manifest-declared deps)", () => {
    expect(ovidInstallArgv([])).toEqual(["/usr/local/bin/ovid", "install"]);
  });
});

describe("cachePruneArgv", () => {
  it("builds the ovid cache-prune argv consumed by the P7 hibernate path", () => {
    expect(cachePruneArgv()).toEqual(["/usr/local/bin/ovid", "cache-prune"]);
  });

  it("returns a fresh array each call (no shared mutable argv)", () => {
    expect(cachePruneArgv()).not.toBe(cachePruneArgv());
  });
});

describe("installEnv", () => {
  it("carries the exact store env subset installs run with", () => {
    expect(installEnv()).toMatchObject({
      NPM_CONFIG_STORE_DIR: "/root/.cache/pnpm-store",
      UV_CACHE_DIR: "/root/.cache/uv",
      UV_LINK_MODE: "hardlink",
    });
  });

  it("contains ONLY the store subset — nothing else leaks in", () => {
    expect(Object.keys(installEnv()).sort()).toEqual([
      "NPM_CONFIG_STORE_DIR",
      "UV_CACHE_DIR",
      "UV_LINK_MODE",
    ]);
  });

  it("is re-exported from BASE_JAIL_ENV — every value identical, no drift", () => {
    const env = installEnv();
    for (const key of Object.keys(env) as (keyof typeof env)[]) {
      expect(env[key]).toBe(BASE_JAIL_ENV[key]);
    }
  });

  it("returns a frozen object per call", () => {
    expect(Object.isFrozen(installEnv())).toBe(true);
  });
});
