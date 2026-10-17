/**
 * Dedicated browser uid drop — unit + host-gated pins.
 *
 * The non-root cases pin the validation and the generated shim text. The
 * root-gated cases actually spawn through the shim and prove the child runs
 * as the configured uid (the whole point of the nftables browser rule).
 */

import { spawn } from "node:child_process";
import { mkdir, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { loadBrowserEngineConfig } from "./config.js";
import {
  BrowserUidDropError,
  prepareBrowserUidDrop,
  renderUidWrapperScript,
} from "./uidDrop.js";

const IS_ROOT = process.getuid?.() === 0;

const UID_CFG = loadBrowserEngineConfig({ OVID_BROWSER_EGRESS_UID: "230000" });

/** Run a command and capture stdout/stderr/exit. */
function run(
  command: string,
  args: string[],
  env: NodeJS.ProcessEnv = process.env,
): Promise<{ code: number | null; stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (c: Buffer) => {
      stdout += c.toString("utf8");
    });
    child.stderr?.on("data", (c: Buffer) => {
      stderr += c.toString("utf8");
    });
    child.once("error", reject);
    child.once("exit", (code) => resolve({ code, stdout, stderr }));
  });
}

describe("prepareBrowserUidDrop validation", () => {
  it("returns null when no uid is configured", async () => {
    const cfg = loadBrowserEngineConfig({});
    await expect(prepareBrowserUidDrop(cfg, { getuid: () => 0 })).resolves.toBeNull();
  });

  it("fails loudly when a uid is configured but the worker is not root", async () => {
    let err: unknown;
    try {
      await prepareBrowserUidDrop(UID_CFG, { getuid: () => 1_000, preflight: false });
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(BrowserUidDropError);
    const msg = (err as Error).message;
    expect(msg).toContain("OVID_BROWSER_EGRESS_UID=230000");
    expect(msg).toContain("requires root");
    expect(msg).toContain("OVID_BROWSER_UID_DROP=disabled");
  });

  it("rejects a uid below the floor even when constructed by hand", async () => {
    await expect(
      prepareBrowserUidDrop({ ...UID_CFG, egressUid: 999 }, { getuid: () => 0, preflight: false }),
    ).rejects.toThrow(/integer >= 100000/);
  });

  it("rejects a uid inside the sandbox block even when constructed by hand", async () => {
    await expect(
      prepareBrowserUidDrop(
        { ...UID_CFG, egressUid: 205_000, sandboxUidRange: [200_000, 209_999] },
        { getuid: () => 0, preflight: false },
      ),
    ).rejects.toThrow(/inside the sandbox uid block/);
  });
});

describe("renderUidWrapperScript", () => {
  it("bakes the uid/gid, chowns the Playwright profile dir, and execs setpriv", () => {
    const script = renderUidWrapperScript(
      230_000,
      230_000,
      "/usr/bin/setpriv",
      "/opt/ovid-browsers/ms-playwright/chromium/chrome",
    );
    expect(script.startsWith("#!/bin/sh")).toBe(true);
    expect(script).toContain("uid='230000'");
    expect(script).toContain("gid='230000'");
    expect(script).toContain("real='/opt/ovid-browsers/ms-playwright/chromium/chrome'");
    expect(script).toContain('--user-data-dir=*) data_dir="${arg#--user-data-dir=}"');
    expect(script).toContain('chown -R "$uid:$gid" "$data_dir"');
    expect(script).toContain(
      `exec '/usr/bin/setpriv' --reuid="$uid" --regid="$gid" --clear-groups "$real" "$@"`,
    );
  });

  it("single-quote-escapes paths with spaces and quotes", () => {
    const script = renderUidWrapperScript(230_000, 230_000, "/usr/bin/setpriv", "/opt/a b/it's");
    expect(script).toContain(`real='/opt/a b/it'\\''s'`);
  });
});

describe.skipIf(!IS_ROOT)("prepareBrowserUidDrop (root, host-gated)", () => {
  const roots: string[] = [];

  afterEach(async () => {
    for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true });
  });

  async function runtimeRoot(): Promise<string> {
    const root = await mkdtemp(join(tmpdir(), "ovid-uid-drop-test-"));
    roots.push(root);
    return root;
  }

  it("spawns a child that really runs as the configured uid AND chowns the profile dir", async () => {
    const root = await runtimeRoot();
    // A stand-in for the real Chromium that reports its own uid and ignores
    // the Playwright arguments (including --user-data-dir=...).
    const fakeChromium = join(root, "fake-chromium.sh");
    await writeFile(fakeChromium, "#!/bin/sh\nid -u\n", { mode: 0o755 });

    const runtime = await prepareBrowserUidDrop(UID_CFG, {
      getuid: () => 0,
      preflight: false,
      chromiumPath: fakeChromium,
      runtimeRoot: root,
    });
    expect(runtime).not.toBeNull();
    expect(runtime!.uid).toBe(230_000);
    expect(runtime!.gid).toBe(230_000);

    // Playwright creates this dir root-owned 0700 before spawning the shim.
    const profile = join(root, "playwright-profile");
    await mkdir(profile, { mode: 0o700 });
    expect((await stat(profile)).uid).toBe(0);

    const result = await run(runtime!.wrapperPath, [`--user-data-dir=${profile}`], runtime!.env);
    expect(result.code).toBe(0);
    expect(result.stdout.trim()).toBe("230000");
    // The shim chowned the profile before exec — Chromium can write it.
    expect((await stat(profile)).uid).toBe(230_000);
  });

  it("fails the boot probe when the shim cannot exec the browser as the uid", async () => {
    const root = await runtimeRoot();
    const runtime = await prepareBrowserUidDrop(UID_CFG, {
      getuid: () => 0,
      preflight: false,
      chromiumPath: "/bin/false", // execs fine but --version exits non-zero
      runtimeRoot: root,
    });
    await expect(
      prepareBrowserUidDrop(UID_CFG, {
        getuid: () => 0,
        chromiumPath: "/bin/false",
        runtimeRoot: root,
      }),
    ).rejects.toThrow(/Chromium uid shim probe .* exited with code 1/);
    expect(runtime).not.toBeNull();
  });

  it("preflight passes with an executable that exits 0", async () => {
    const root = await runtimeRoot();
    await expect(
      prepareBrowserUidDrop(UID_CFG, {
        getuid: () => 0,
        chromiumPath: "/bin/true",
        runtimeRoot: root,
      }),
    ).resolves.not.toBeNull();
  });

  it("cleanup removes an owned runtime tree and is idempotent", async () => {
    const runtime = await prepareBrowserUidDrop(UID_CFG, {
      getuid: () => 0,
      preflight: false,
      chromiumPath: "/bin/true",
    });
    expect(runtime).not.toBeNull();
    const root = runtime!.wrapperPath.slice(0, runtime!.wrapperPath.lastIndexOf("/"));
    await expect(stat(root)).resolves.toBeTruthy();
    await runtime!.cleanup();
    await expect(stat(root)).rejects.toThrow();
    await expect(runtime!.cleanup()).resolves.toBeUndefined();
  });
});
