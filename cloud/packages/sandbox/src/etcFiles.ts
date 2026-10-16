import { chmod, chown, mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

/**
 * The five files of the per-sandbox private /etc. `writeEnvFiles` puts them
 * in the jail's etcDir; `buildBwrapArgs` binds them over /etc (Task 5).
 */
export interface EtcBundle {
  passwd: string;
  group: string;
  hosts: string;
  resolvConf: string;
  nsswitch: string;
}

// systemd-resolved's stub listener. Loopback inside the jail has nothing
// listening on it, so a jail pointed here gets no DNS at all — refuse at
// render time rather than shipping a silently broken resolver.
const STUB_RESOLVER = "127.0.0.53";

/**
 * Renders the private /etc bundle. passwd/group carry root + nobody ONLY —
 * the host's user list must not leak into the jail. resolvConf carries one
 * `nameserver` line per configured resolver (never the systemd-resolved
 * stub, which is rejected outright). hosts pins localhost on both stacks.
 */
export function renderEtcBundle(opts: { dns: string[] }): EtcBundle {
  if (opts.dns.includes(STUB_RESOLVER)) {
    throw new Error(
      `sandbox dns must not include the systemd-resolved stub ${STUB_RESOLVER} — ` +
        `it is unreachable inside the jail (set OVID_SANDBOX_DNS to real resolvers)`,
    );
  }
  return {
    passwd:
      "root:x:0:0:root:/root:/bin/bash\n" +
      "nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n",
    group: "root:x:0:\nnogroup:x:65534:\n",
    hosts: "127.0.0.1 localhost\n::1 localhost\n",
    resolvConf: opts.dns.map((d) => `nameserver ${d}\n`).join(""),
    nsswitch: "passwd: files\ngroup: files\nhosts: files dns\n",
  };
}

/**
 * Dotfiles seeded into every per-sandbox home. pnpm's store dir matches
 * NPM_CONFIG_STORE_DIR from BASE_JAIL_ENV (invocation.ts); fund/audit noise
 * is off so package installs stay quiet.
 */
export function renderHomeDotfiles(): { npmrc: string } {
  return {
    npmrc: "store-dir=/root/.cache/pnpm-store\nfund=false\naudit=false\n",
  };
}

/**
 * Writes the bundle's five /etc files plus the home `.npmrc`. Creates both
 * directories (mkdir -p), normalizes every file to 0644 and chowns it to
 * `ownerUid` (the sandbox uid the manager allocated for this sandbox).
 */
export async function writeEnvFiles(opts: {
  etcDir: string;
  homeDir: string;
  bundle: EtcBundle;
  dotfiles: { npmrc: string };
  ownerUid: number;
}): Promise<void> {
  const writes: Array<[string, string]> = [
    [join(opts.etcDir, "passwd"), opts.bundle.passwd],
    [join(opts.etcDir, "group"), opts.bundle.group],
    [join(opts.etcDir, "hosts"), opts.bundle.hosts],
    [join(opts.etcDir, "resolv.conf"), opts.bundle.resolvConf],
    [join(opts.etcDir, "nsswitch.conf"), opts.bundle.nsswitch],
    [join(opts.homeDir, ".npmrc"), opts.dotfiles.npmrc],
  ];

  await mkdir(opts.etcDir, { recursive: true });
  await mkdir(opts.homeDir, { recursive: true });
  for (const [path, content] of writes) {
    await writeFile(path, content, { mode: 0o644 });
    // writeFile's mode only applies at creation — re-assert for pre-existing
    // files so a stale 0600 can never reach the jail.
    await chmod(path, 0o644);
    await chown(path, opts.ownerUid, opts.ownerUid);
  }
}
