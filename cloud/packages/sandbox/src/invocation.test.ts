import { describe, expect, it } from "vitest";
import type { SandboxConfig } from "./config.js";
import { BASE_JAIL_ENV, buildBwrapArgs, JAIL_WORKSPACE, type JailSpec } from "./invocation.js";

const ROOTFS = "/opt/ovid-rootfs/rev-20261016-r1";
const ETC_DIR = "/var/ovid/sandboxes/sbx-abc123/etc";
const HOME_DIR = "/var/ovid/sandboxes/sbx-abc123/home";
const WORKSPACE_DIR = "/workspaces/users/u_abc/ws-1";
const BWRAP = "/usr/bin/bwrap";

const SPEC: JailSpec = {
  rootfs: ROOTFS,
  workspaceDir: WORKSPACE_DIR,
  homeDir: HOME_DIR,
  etcDir: ETC_DIR,
  argv: ["/bin/bash", "-c", "echo hi"],
};

function cfg(
  launch: "setuid" | "rootmap",
  bwrapPath: string = BWRAP,
): Pick<SandboxConfig, "launch" | "bwrapPath"> {
  return { launch, bwrapPath };
}

// The golden argv — Task 5 pins the flag order verbatim. Task 7 (exec) spawns
// this exact vector and the Task 11 nft egress rule assumes the shared netns
// (no --unshare-net), so any reorder here is a contract break, not a refactor.
const GOLDEN_SETUID = [
  BWRAP,
  "--ro-bind", ROOTFS, "/",
  "--dev", "/dev",
  "--proc", "/proc",
  "--tmpfs", "/tmp",
  "--dir", "/etc",
  "--ro-bind", `${ROOTFS}/etc/ld.so.cache`, "/etc/ld.so.cache",
  "--ro-bind", `${ROOTFS}/etc/ssl`, "/etc/ssl",
  "--ro-bind", `${ROOTFS}/etc/ca-certificates`, "/etc/ca-certificates",
  "--ro-bind", `${ETC_DIR}/passwd`, "/etc/passwd",
  "--ro-bind", `${ETC_DIR}/group`, "/etc/group",
  "--ro-bind", `${ETC_DIR}/hosts`, "/etc/hosts",
  "--ro-bind", `${ETC_DIR}/resolv.conf`, "/etc/resolv.conf",
  "--ro-bind", `${ETC_DIR}/nsswitch.conf`, "/etc/nsswitch.conf",
  "--bind", WORKSPACE_DIR, "/workspace",
  "--bind", HOME_DIR, "/root",
  "--unshare-user", "--uid", "0", "--gid", "0",
  "--unshare-pid", "--unshare-ipc", "--unshare-uts",
  "--die-with-parent",
  "--new-session",
  "--clearenv",
  "--setenv", "HOME", "/root",
  "--setenv", "LANG", "C.UTF-8",
  "--setenv", "NPM_CONFIG_STORE_DIR", "/root/.cache/pnpm-store",
  "--setenv", "PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
  "--setenv", "TERM", "xterm-256color",
  "--setenv", "UV_CACHE_DIR", "/root/.cache/uv",
  "--setenv", "UV_LINK_MODE", "hardlink",
  "--chdir", "/workspace",
  "/bin/bash", "-c", "echo hi",
];

// rootmap: identical EXCEPT the three user-ns flags are absent — the launcher
// pre-creates the userns (Task 1 MECHANISM.md), so bwrap joins it implicitly.
const GOLDEN_ROOTMAP = [
  BWRAP,
  "--ro-bind", ROOTFS, "/",
  "--dev", "/dev",
  "--proc", "/proc",
  "--tmpfs", "/tmp",
  "--dir", "/etc",
  "--ro-bind", `${ROOTFS}/etc/ld.so.cache`, "/etc/ld.so.cache",
  "--ro-bind", `${ROOTFS}/etc/ssl`, "/etc/ssl",
  "--ro-bind", `${ROOTFS}/etc/ca-certificates`, "/etc/ca-certificates",
  "--ro-bind", `${ETC_DIR}/passwd`, "/etc/passwd",
  "--ro-bind", `${ETC_DIR}/group`, "/etc/group",
  "--ro-bind", `${ETC_DIR}/hosts`, "/etc/hosts",
  "--ro-bind", `${ETC_DIR}/resolv.conf`, "/etc/resolv.conf",
  "--ro-bind", `${ETC_DIR}/nsswitch.conf`, "/etc/nsswitch.conf",
  "--bind", WORKSPACE_DIR, "/workspace",
  "--bind", HOME_DIR, "/root",
  "--unshare-pid", "--unshare-ipc", "--unshare-uts",
  "--die-with-parent",
  "--new-session",
  "--clearenv",
  "--setenv", "HOME", "/root",
  "--setenv", "LANG", "C.UTF-8",
  "--setenv", "NPM_CONFIG_STORE_DIR", "/root/.cache/pnpm-store",
  "--setenv", "PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
  "--setenv", "TERM", "xterm-256color",
  "--setenv", "UV_CACHE_DIR", "/root/.cache/uv",
  "--setenv", "UV_LINK_MODE", "hardlink",
  "--chdir", "/workspace",
  "/bin/bash", "-c", "echo hi",
];

// The --setenv slice of an argv (between --clearenv and --chdir).
function setenvSection(argv: string[]): string[] {
  return argv.slice(argv.indexOf("--clearenv") + 1, argv.indexOf("--chdir"));
}

describe("BASE_JAIL_ENV / JAIL_WORKSPACE", () => {
  it("is exactly the seven jail variables from the Task 5 brief", () => {
    expect({ ...BASE_JAIL_ENV }).toEqual({
      PATH: "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      HOME: "/root",
      LANG: "C.UTF-8",
      TERM: "xterm-256color",
      NPM_CONFIG_STORE_DIR: "/root/.cache/pnpm-store",
      UV_CACHE_DIR: "/root/.cache/uv",
      UV_LINK_MODE: "hardlink",
    });
  });

  it("pins the workspace mount point", () => {
    expect(JAIL_WORKSPACE).toBe("/workspace");
  });
});

describe("buildBwrapArgs (setuid)", () => {
  it("golden: exact full argv including bwrapPath at [0]", () => {
    expect(buildBwrapArgs(SPEC, cfg("setuid"))).toEqual(GOLDEN_SETUID);
  });

  it("uses the configured bwrapPath at [0]", () => {
    expect(buildBwrapArgs(SPEC, cfg("setuid", "/opt/bwrap-1.12/bin/bwrap"))[0]).toBe(
      "/opt/bwrap-1.12/bin/bwrap",
    );
  });
});

describe("buildBwrapArgs (rootmap)", () => {
  it("golden: differs from setuid only by the user-ns flags", () => {
    expect(buildBwrapArgs(SPEC, cfg("rootmap"))).toEqual(GOLDEN_ROOTMAP);
  });

  it("omits --unshare-user/--uid/--gid entirely", () => {
    const argv = buildBwrapArgs(SPEC, cfg("rootmap"));
    expect(argv).not.toContain("--unshare-user");
    expect(argv).not.toContain("--uid");
    expect(argv).not.toContain("--gid");
  });
});

describe("buildBwrapArgs (both strategies)", () => {
  it("never includes --unshare-net (Task 11 nft is the egress boundary)", () => {
    expect(buildBwrapArgs(SPEC, cfg("setuid"))).not.toContain("--unshare-net");
    expect(buildBwrapArgs(SPEC, cfg("rootmap"))).not.toContain("--unshare-net");
  });

  it("includes --die-with-parent and --new-session", () => {
    for (const launch of ["setuid", "rootmap"] as const) {
      const argv = buildBwrapArgs(SPEC, cfg(launch));
      expect(argv).toContain("--die-with-parent");
      expect(argv).toContain("--new-session");
    }
  });

  it("binds the spec's host workspace and home dirs at /workspace and /root", () => {
    const argv = buildBwrapArgs(SPEC, cfg("setuid"));
    expect(argv).toContain("--bind");
    const i = argv.indexOf("--bind");
    expect(argv.slice(i, i + 3)).toEqual(["--bind", WORKSPACE_DIR, "/workspace"]);
    expect(argv.slice(i + 3, i + 6)).toEqual(["--bind", HOME_DIR, "/root"]);
  });
});

describe("buildBwrapArgs env merge", () => {
  it("caller env overrides BASE, extra keys merged, keys sorted", () => {
    const argv = buildBwrapArgs(
      { ...SPEC, env: { PATH: "/custom/bin", FOO: "bar" } },
      cfg("setuid"),
    );
    expect(setenvSection(argv)).toEqual([
      "--setenv", "FOO", "bar",
      "--setenv", "HOME", "/root",
      "--setenv", "LANG", "C.UTF-8",
      "--setenv", "NPM_CONFIG_STORE_DIR", "/root/.cache/pnpm-store",
      "--setenv", "PATH", "/custom/bin",
      "--setenv", "TERM", "xterm-256color",
      "--setenv", "UV_CACHE_DIR", "/root/.cache/uv",
      "--setenv", "UV_LINK_MODE", "hardlink",
    ]);
  });

  it("always carries the pnpm/uv cache variables", () => {
    const section = setenvSection(buildBwrapArgs({ ...SPEC, env: {} }, cfg("rootmap")));
    expect(section).toContain("NPM_CONFIG_STORE_DIR");
    expect(section).toContain("/root/.cache/pnpm-store");
    expect(section).toContain("UV_CACHE_DIR");
    expect(section).toContain("/root/.cache/uv");
    expect(section).toContain("UV_LINK_MODE");
    expect(section).toContain("hardlink");
  });
});

describe("buildBwrapArgs cwd", () => {
  it("defaults --chdir to /workspace", () => {
    const argv = buildBwrapArgs(SPEC, cfg("setuid"));
    expect(argv.slice(argv.indexOf("--chdir"), argv.indexOf("--chdir") + 2)).toEqual([
      "--chdir",
      "/workspace",
    ]);
  });

  it("honours a jail-path cwd override", () => {
    const argv = buildBwrapArgs({ ...SPEC, cwd: "/workspace/pkg" }, cfg("setuid"));
    expect(argv.slice(argv.indexOf("--chdir"), argv.indexOf("--chdir") + 2)).toEqual([
      "--chdir",
      "/workspace/pkg",
    ]);
  });
});

describe("buildBwrapArgs payload", () => {
  it("appends the argv verbatim at the end", () => {
    const argv = buildBwrapArgs(
      { ...SPEC, argv: ["/usr/local/bin/ovid", "run", "a b"] },
      cfg("setuid"),
    );
    expect(argv.slice(-3)).toEqual(["/usr/local/bin/ovid", "run", "a b"]);
  });
});
