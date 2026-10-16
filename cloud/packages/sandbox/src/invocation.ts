import type { SandboxConfig } from "./config.js";

/** Jail-side mount point every workspace is bound at. */
export const JAIL_WORKSPACE = "/workspace";

/** Jail-side mount point every per-sandbox home is bound at. */
const JAIL_HOME = "/root";

/**
 * A jail whose execution the invocation builder turns into a bwrap argv.
 * Consumed by the manager (Task 8) and executors (Tasks 7/9).
 */
export interface JailSpec {
  /** Host path of the validated rootfs revision (Task 4 `resolveRootfs`). */
  rootfs: string;
  /** Host path of the workspace directory, bound at /workspace. */
  workspaceDir: string;
  /** Host path of the per-sandbox home, bound at /root. */
  homeDir: string;
  /** Host path of the per-sandbox private /etc stub directory. */
  etcDir: string;
  /** Jail path to start in; default "/workspace". */
  cwd?: string;
  /** Merged over {@link BASE_JAIL_ENV}; keys sorted for golden determinism. */
  env?: Record<string, string>;
  /** Payload, e.g. ["/bin/bash","-c","echo hi"]. */
  argv: string[];
}

/**
 * The complete environment every jail starts with. `--clearenv` wipes the
 * launcher's environment, so nothing reaches the payload unless it is listed
 * here or in `JailSpec.env` — an explicit allowlist, not a passthrough.
 */
export const BASE_JAIL_ENV: Readonly<Record<string, string>> = Object.freeze({
  PATH: "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
  HOME: "/root",
  LANG: "C.UTF-8",
  TERM: "xterm-256color",
  NPM_CONFIG_STORE_DIR: "/root/.cache/pnpm-store",
  UV_CACHE_DIR: "/root/.cache/uv",
  UV_LINK_MODE: "hardlink",
});

// The five files of the per-sandbox private /etc (Task 5), in the order the
// golden argv binds them.
const ETC_FILE_BINDS = ["passwd", "group", "hosts", "resolv.conf", "nsswitch.conf"] as const;

/**
 * Builds the full bwrap argv (including `bwrapPath` at [0]) for a jail spec.
 *
 * Flag order is golden-pinned: ro-bind root, /dev, /proc, /tmp, private /etc
 * (three rootfs ro-binds + five per-sandbox file binds), workspace and home
 * binds, launch-strategy user-ns flags, pid/ipc/uts unshares,
 * --die-with-parent --new-session, --clearenv + sorted --setenv pairs, --chdir,
 * then the payload argv.
 *
 * There is deliberately NO `--unshare-net` (spec §8.5): the jail shares the
 * host netns and the per-sandbox nft filter (Task 11) is the egress boundary.
 * Under `launch:"setuid"` the jail gets its own userns (`--unshare-user --uid 0
 * --gid 0`); under `launch:"rootmap"` the launcher has already created the
 * userns (Task 1 MECHANISM.md), so those three flags are absent.
 */
export function buildBwrapArgs(
  spec: JailSpec,
  cfg: Pick<SandboxConfig, "launch" | "bwrapPath">,
): string[] {
  const args: string[] = [cfg.bwrapPath];

  // Filesystem: rootfs read-only, then the private /etc.
  args.push("--ro-bind", spec.rootfs, "/");
  args.push("--dev", "/dev");
  args.push("--proc", "/proc");
  args.push("--tmpfs", "/tmp");
  args.push("--dir", "/etc");
  args.push("--ro-bind", `${spec.rootfs}/etc/ld.so.cache`, "/etc/ld.so.cache");
  args.push("--ro-bind", `${spec.rootfs}/etc/ssl`, "/etc/ssl");
  args.push("--ro-bind", `${spec.rootfs}/etc/ca-certificates`, "/etc/ca-certificates");
  for (const name of ETC_FILE_BINDS) {
    args.push("--ro-bind", `${spec.etcDir}/${name}`, `/etc/${name}`);
  }

  // Writable surfaces: the workspace and the per-sandbox home.
  args.push("--bind", spec.workspaceDir, JAIL_WORKSPACE);
  args.push("--bind", spec.homeDir, JAIL_HOME);

  // Namespaces. setuid needs bwrap to create the userns itself; rootmap joins
  // one the launcher already made.
  if (cfg.launch === "setuid") {
    args.push("--unshare-user", "--uid", "0", "--gid", "0");
  }
  args.push("--unshare-pid", "--unshare-ipc", "--unshare-uts");

  // Lifecycle: no orphaned sandboxes, no controlling tty takeover.
  args.push("--die-with-parent");
  args.push("--new-session");

  // Environment: wipe, then set exactly the merged allowlist in sorted key
  // order so the argv is deterministic (golden tests pin it).
  args.push("--clearenv");
  const env = { ...BASE_JAIL_ENV, ...spec.env };
  for (const key of Object.keys(env).sort()) {
    args.push("--setenv", key, env[key]);
  }

  // Payload.
  args.push("--chdir", spec.cwd ?? JAIL_WORKSPACE);
  args.push(...spec.argv);

  return args;
}
