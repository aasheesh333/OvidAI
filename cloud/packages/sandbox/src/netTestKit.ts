import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import {
  chmodSync,
  chownSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DEFAULT_BLOCKED_V4, DEFAULT_BLOCKED_V6, renderNftRuleset } from "./net.js";

/**
 * Netns egress proof kit (Task 11, Step 4; exported for Task 15 reuse).
 *
 * Proves the rendered nftables ruleset BEHAVES on a real kernel, inside a
 * disposable network namespace `ovid-spike-egress-<pid>-<rand>` — never the
 * host's own table. Everything is torn down in `finally` and the kit asserts
 * its own namespace is gone before returning/throwing.
 *
 * The proof (Review Focus #5): a curl running as a sandbox uid cannot reach
 * a blocked listener (rc 28) while the same curl as root can (rc 0) — the
 * uid key is the enforcement — and the 169.254.169.254 metadata path
 * increments the blocked-set counter. With a browser uid set, the
 * allow-internal-then-drop ordering (gap G2) is proven: loopback rc 0,
 * metadata rc 28.
 */

export interface RawSocketPostinstallProof {
  /** Direct AF_INET6 socket to ::ffff:127.0.0.1 as the sandbox uid/root. */
  mappedLoopbackRc: number;
  mappedLoopbackRootRc: number;
  /** Combined blocked_v4 + blocked_v6 increment for the mapped probe. */
  mappedLoopbackCounterDelta: number;
  /** Direct socket to the configured host public IP as the sandbox uid/root. */
  hostRc: number;
  hostRootRc: number;
  hostCounterDelta: number;
  /** Direct socket to 169.254.169.254 as the sandbox uid/root. */
  metadataRc: number;
  metadataRootRc: number;
  metadataCounterDelta: number;
  /** A forced-on local npm postinstall made the same two raw connections. */
  postinstallRan: boolean;
  postinstallHostRc: number;
  postinstallMetadataRc: number;
  postinstallHostCounterDelta: number;
  postinstallMetadataCounterDelta: number;
}

export interface NetnsProof {
  /** Curl-to-127.0.0.1:8999 exit code as the sandbox uid — expect 28 (timeout). */
  blockedRc: number;
  /** blocked_v4 rule counter (packets) as the sandbox uid, after all uid curls. */
  counterPackets: number;
  /** Curl-to-127.0.0.1:8999 exit code as root — expect 0 (uid-keying proof). */
  rootRc: number;
  /** Browser-uid curl to 127.0.0.1:8999 — expect 0 (loopback exemption). Null when browserUid unset. */
  browserLoopbackRc: number | null;
  /** Browser-uid curl to 169.254.169.254 — expect 28. Null when browserUid unset. */
  browserBlockedRc: number | null;
  /**
   * Curl-to-169.254.169.254 exit code as the sandbox uid — expect 28
   * (metadata path). The counter-increment side of that proof is enforced
   * in-kit (runEgressNetnsProof throws when the metadata curl does not move
   * the blocked_v4 counter).
   */
  metadataBlockedRc: number;
  /** Additional opt-in proof; null for the original lightweight callers. */
  rawSocketPostinstall: RawSocketPostinstallProof | null;
}

const LISTENER_PORT = 8999;
const METADATA_IP = "169.254.169.254";
const MAPPED_LOOPBACK_IP = "::ffff:127.0.0.1";
const METADATA_URL = `http://${METADATA_IP}/`;
const CURL_TIMEOUT_S = 2;

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

interface RunOut {
  status: number | null;
  stdout: string;
  stderr: string;
}

function run(
  file: string,
  args: string[],
  timeoutMs = 10_000,
  env: NodeJS.ProcessEnv = process.env,
): RunOut {
  const r = spawnSync(file, args, { timeout: timeoutMs, encoding: "utf8", env });
  if (r.error) {
    throw new Error(`netns proof: cannot run ${file} ${args.join(" ")}: ${r.error.message}`);
  }
  return { status: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

function runChecked(file: string, args: string[], what: string, timeoutMs = 10_000): RunOut {
  const r = run(file, args, timeoutMs);
  if (r.status !== 0) {
    throw new Error(
      `netns proof: ${what} failed (rc=${r.status}): ${r.stderr.trim() || r.stdout.trim()}`,
    );
  }
  return r;
}

function netnsAs(ns: string, uid: number | "root"): string[] {
  const args = ["netns", "exec", ns];
  if (uid !== "root") {
    args.push("setpriv", `--reuid=${uid}`, `--regid=${uid}`, "--clear-groups");
  }
  return args;
}

/** curl inside the netns, optionally as a uid (setpriv), returning its exit code. */
function curlAs(ns: string, uid: number | "root", url: string): number {
  const args = netnsAs(ns, uid);
  args.push(
    "curl",
    "--noproxy",
    "*",
    "-s",
    "-o",
    "/dev/null",
    "--max-time",
    String(CURL_TIMEOUT_S),
    url,
  );
  const r = run("ip", args, (CURL_TIMEOUT_S + 8) * 1000);
  if (r.status === null) {
    throw new Error(`netns proof: curl as ${String(uid)} to ${url} did not exit: ${r.stderr}`);
  }
  return r.status;
}

const RAW_SOCKET_PY = [
  "import socket, sys",
  "try:",
  "    s = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=2)",
  "    s.close()",
  "except socket.timeout:",
  "    sys.exit(28)",
  "except OSError as e:",
  "    print(f'{type(e).__name__}: {e}', file=sys.stderr)",
  "    sys.exit(1)",
].join("\n");

/** Direct Python socket, bypassing curl's protocol/address handling. */
function rawSocketAs(ns: string, uid: number | "root", address: string): number {
  const r = run("ip", [
    ...netnsAs(ns, uid),
    "python3",
    "-c",
    RAW_SOCKET_PY,
    address,
    String(LISTENER_PORT),
  ]);
  if (r.status === null) {
    throw new Error(`netns proof: raw socket as ${String(uid)} to ${address} did not exit`);
  }
  if (r.status !== 0 && r.status !== 28) {
    throw new Error(
      `netns proof: raw socket as ${String(uid)} to ${address} rc=${r.status}: ${r.stderr.trim()}`,
    );
  }
  return r.status;
}

function listTable(ns: string): string {
  return runChecked("ip", ["netns", "exec", ns, "nft", "list", "table", "inet", "ovid_sandbox"], "nft list table").stdout;
}

interface RuleCounters {
  v4: number;
  v6: number;
  own: number;
}

/** One atomic table listing, so before/after deltas cannot mix counter snapshots. */
function ruleCounters(ns: string, uidKey: string, ownPublicIp: string): RuleCounters {
  const out = listTable(ns);
  const read = (rule: string): number => {
    const prefix = `meta skuid ${uidKey} ${rule}`;
    const line = out.split("\n").find((candidate) => candidate.includes(prefix));
    const match = line === undefined ? null : /counter packets (\d+)/.exec(line);
    if (match === null) {
      throw new Error(`netns proof: counter rule ${prefix} not found in nft list output:\n${out}`);
    }
    return Number(match[1]);
  };
  return {
    v4: read("ip daddr @blocked_v4"),
    v6: read("ip6 daddr @blocked_v6"),
    own: read(`ip daddr ${ownPublicIp}`),
  };
}

function assertIncrement(label: string, before: number, after: number): void {
  if (after <= before) {
    throw new Error(
      `netns proof: ${label} did not increment its deny counter (${before} → ${after})`,
    );
  }
}

interface PostinstallOutcome {
  rc: number;
  error: string;
}

interface PostinstallResult {
  ran: true;
  host: PostinstallOutcome;
  metadata: PostinstallOutcome;
}

const POSTINSTALL_JS = String.raw`
const fs = require("node:fs");
const net = require("node:net");
const [host, metadata, rawPort] = process.argv.slice(2);
const port = Number(rawPort);
function probe(address) {
  return new Promise((resolve) => {
    const socket = new net.Socket();
    let settled = false;
    const done = (rc, error) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve({ rc, error });
    };
    socket.setTimeout(2000);
    socket.once("connect", () => done(0, "connected"));
    socket.once("timeout", () => done(28, "ETIMEDOUT"));
    socket.once("error", (error) => done(1, String(error.code ?? error.message)));
    socket.connect(port, address);
  });
}
(async () => {
  const hostResult = await probe(host);
  const metadataResult = await probe(metadata);
  fs.writeFileSync("raw-result.json", JSON.stringify({
    ran: true,
    host: hostResult,
    metadata: metadataResult,
  }));
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
`;

function parsePostinstallOutcome(value: unknown, label: string): PostinstallOutcome {
  if (typeof value !== "object" || value === null) {
    throw new Error(`netns proof: postinstall ${label} outcome is not an object`);
  }
  const outcome = value as Partial<PostinstallOutcome>;
  if (!Number.isInteger(outcome.rc) || typeof outcome.error !== "string") {
    throw new Error(`netns proof: postinstall ${label} outcome is malformed`);
  }
  return { rc: outcome.rc as number, error: outcome.error };
}

/**
 * Run a dependency-free local install with lifecycle scripts forcibly enabled.
 * The marker is mandatory: `ignore-scripts` or an unavailable npm is NOT a
 * passing postinstall network-denial proof.
 */
function runPostinstallProof(
  ns: string,
  uid: number,
  ownPublicIp: string,
  tmp: string,
): PostinstallResult {
  chmodSync(tmp, 0o755);
  const packageDir = join(tmp, `postinstall-${uid}`);
  const home = join(tmp, `home-${uid}`);
  const cache = join(tmp, `npm-cache-${uid}`);
  for (const dir of [packageDir, home, cache]) {
    mkdirSync(dir, { recursive: true });
    chownSync(dir, uid, uid);
  }
  writeFileSync(join(packageDir, "postinstall.cjs"), POSTINSTALL_JS, { mode: 0o644 });
  writeFileSync(
    join(packageDir, "package.json"),
    JSON.stringify({
      name: "ovid-netns-postinstall-proof",
      version: "1.0.0",
      private: true,
      scripts: {
        postinstall: `node postinstall.cjs ${ownPublicIp} ${METADATA_IP} ${LISTENER_PORT}`,
      },
    }),
    { mode: 0o644 },
  );
  const install = run(
    "ip",
    [
      ...netnsAs(ns, uid),
      "npm",
      "--prefix",
      packageDir,
      "install",
      "--ignore-scripts=false",
      "--no-audit",
      "--no-fund",
      "--package-lock=false",
      "--offline",
    ],
    30_000,
    {
      ...process.env,
      HOME: home,
      NPM_CONFIG_CACHE: cache,
      NPM_CONFIG_UPDATE_NOTIFIER: "false",
    },
  );
  if (install.status !== 0) {
    throw new Error(
      `netns proof: forced-on postinstall npm install failed (rc=${install.status}): ` +
        `${install.stderr.trim() || install.stdout.trim()}`,
    );
  }
  const parsed = JSON.parse(readFileSync(join(packageDir, "raw-result.json"), "utf8")) as {
    ran?: unknown;
    host?: unknown;
    metadata?: unknown;
  };
  if (parsed.ran !== true) throw new Error("netns proof: postinstall marker did not run");
  return {
    ran: true,
    host: parsePostinstallOutcome(parsed.host, "host"),
    metadata: parsePostinstallOutcome(parsed.metadata, "metadata"),
  };
}

/**
 * Run the egress proof in a disposable netns. Requires root plus nft, ip,
 * curl, python3 and setpriv (the host suite gates on these); the expanded
 * raw-socket/postinstall proof also needs npm. The ruleset defaults to exactly
 * [uid, uid], or uses uidRange when a production/staging block is under test.
 */
export async function runEgressNetnsProof(opts: {
  ownPublicIp: string;
  uid: number;
  uidRange?: [number, number];
  browserUid?: number;
  runRawSocketPostinstallProof?: boolean;
}): Promise<NetnsProof> {
  const uidRange = opts.uidRange ?? [opts.uid, opts.uid];
  if (opts.uid < uidRange[0] || opts.uid > uidRange[1]) {
    throw new Error(`netns proof: probe uid ${opts.uid} is outside ${uidRange[0]}-${uidRange[1]}`);
  }
  const uidKey = `${uidRange[0]}-${uidRange[1]}`;
  const ns = `ovid-spike-egress-${process.pid}-${randomBytes(4).toString("hex")}`;
  const ruleset = renderNftRuleset({
    uidRange,
    blockedV4: [...DEFAULT_BLOCKED_V4],
    blockedV6: [...DEFAULT_BLOCKED_V6],
    ownPublicIp: opts.ownPublicIp,
    browserUidRange:
      opts.browserUid !== undefined ? [opts.browserUid, opts.browserUid] : undefined,
  });
  const tmp = mkdtempSync(join(tmpdir(), "ovid-egress-proof-"));
  const rulesetPath = join(tmp, "ovid-sandbox.nft");
  writeFileSync(rulesetPath, ruleset);
  let listener: ReturnType<typeof spawn> | null = null;

  const proof: NetnsProof = {
    blockedRc: -1,
    counterPackets: -1,
    rootRc: -1,
    browserLoopbackRc: null,
    browserBlockedRc: null,
    metadataBlockedRc: -1,
    rawSocketPostinstall: null,
  };

  try {
    runChecked("ip", ["netns", "add", ns], "ip netns add");
    runChecked("ip", ["netns", "exec", ns, "ip", "link", "set", "lo", "up"], "lo up");
    // A fresh netns has only lo + the local routing table, so nonlocal test
    // addresses need routes through lo to reach the output chain and listener.
    runChecked(
      "ip",
      ["netns", "exec", ns, "ip", "route", "add", "169.254.0.0/16", "dev", "lo"],
      "metadata route",
    );
    if (opts.runRawSocketPostinstallProof === true) {
      // Root controls need a LOCAL listener destination. A route via lo alone
      // still traverses output but never delivers to the local HTTP server.
      for (const [address, label] of [
        [opts.ownPublicIp, "own-public-IP"],
        [METADATA_IP, "metadata"],
      ] as const) {
        runChecked(
          "ip",
          ["netns", "exec", ns, "ip", "addr", "add", `${address}/32`, "dev", "lo"],
          `${label} local address`,
        );
      }
    }
    runChecked("ip", ["netns", "exec", ns, "nft", "-f", rulesetPath], "nft -f ruleset");

    // Listener as root INSIDE the netns; detached so the whole process group
    // can be signalled at teardown. It uses the same port for every proof;
    // the expanded proof binds all netns-local addresses for host-IP controls.
    listener = spawn(
      "ip",
      [
        "netns",
        "exec",
        ns,
        "python3",
        "-m",
        "http.server",
        String(LISTENER_PORT),
        "--bind",
        opts.runRawSocketPostinstallProof === true ? "0.0.0.0" : "127.0.0.1",
      ],
      { stdio: "ignore", detached: true },
    );

    // Readiness via root curls; once up, that same probe result is the
    // uid-keying proof (root sails through the filter).
    const readyDeadline = Date.now() + 10_000;
    for (;;) {
      proof.rootRc = curlAs(ns, "root", `http://127.0.0.1:${LISTENER_PORT}/`);
      if (proof.rootRc === 0) break;
      if (Date.now() > readyDeadline) {
        throw new Error(
          `netns proof: 127.0.0.1:${LISTENER_PORT} listener never answered as root (last rc=${proof.rootRc})`,
        );
      }
      await sleep(200);
    }

    // Sandbox uid: loopback is inside blocked 127.0.0.0/8 → timeout, and the
    // metadata path must land on the SAME rule (counter strictly increases).
    proof.blockedRc = curlAs(ns, opts.uid, `http://127.0.0.1:${LISTENER_PORT}/`);
    const counterAfterLoopback = ruleCounters(ns, uidKey, opts.ownPublicIp).v4;
    proof.metadataBlockedRc = curlAs(ns, opts.uid, METADATA_URL);
    proof.counterPackets = ruleCounters(ns, uidKey, opts.ownPublicIp).v4;
    assertIncrement("169.254.169.254 curl", counterAfterLoopback, proof.counterPackets);

    if (opts.runRawSocketPostinstallProof === true) {
      const raw: RawSocketPostinstallProof = {
        mappedLoopbackRc: -1,
        mappedLoopbackRootRc: -1,
        mappedLoopbackCounterDelta: -1,
        hostRc: -1,
        hostRootRc: -1,
        hostCounterDelta: -1,
        metadataRc: -1,
        metadataRootRc: -1,
        metadataCounterDelta: -1,
        postinstallRan: false,
        postinstallHostRc: -1,
        postinstallMetadataRc: -1,
        postinstallHostCounterDelta: -1,
        postinstallMetadataCounterDelta: -1,
      };
      proof.rawSocketPostinstall = raw;

      raw.mappedLoopbackRootRc = rawSocketAs(ns, "root", MAPPED_LOOPBACK_IP);
      let before = ruleCounters(ns, uidKey, opts.ownPublicIp);
      raw.mappedLoopbackRc = rawSocketAs(ns, opts.uid, MAPPED_LOOPBACK_IP);
      let after = ruleCounters(ns, uidKey, opts.ownPublicIp);
      raw.mappedLoopbackCounterDelta =
        after.v4 - before.v4 + after.v6 - before.v6;
      assertIncrement(
        "mapped-loopback raw socket",
        before.v4 + before.v6,
        after.v4 + after.v6,
      );

      raw.hostRootRc = rawSocketAs(ns, "root", opts.ownPublicIp);
      before = ruleCounters(ns, uidKey, opts.ownPublicIp);
      raw.hostRc = rawSocketAs(ns, opts.uid, opts.ownPublicIp);
      after = ruleCounters(ns, uidKey, opts.ownPublicIp);
      raw.hostCounterDelta = after.own - before.own;
      assertIncrement("own-host raw socket", before.own, after.own);

      raw.metadataRootRc = rawSocketAs(ns, "root", METADATA_IP);
      before = ruleCounters(ns, uidKey, opts.ownPublicIp);
      raw.metadataRc = rawSocketAs(ns, opts.uid, METADATA_IP);
      after = ruleCounters(ns, uidKey, opts.ownPublicIp);
      raw.metadataCounterDelta = after.v4 - before.v4;
      assertIncrement("metadata raw socket", before.v4, after.v4);

      before = ruleCounters(ns, uidKey, opts.ownPublicIp);
      const postinstall = runPostinstallProof(ns, opts.uid, opts.ownPublicIp, tmp);
      after = ruleCounters(ns, uidKey, opts.ownPublicIp);
      raw.postinstallRan = postinstall.ran;
      raw.postinstallHostRc = postinstall.host.rc;
      raw.postinstallMetadataRc = postinstall.metadata.rc;
      raw.postinstallHostCounterDelta = after.own - before.own;
      raw.postinstallMetadataCounterDelta = after.v4 - before.v4;
      assertIncrement("postinstall own-host raw socket", before.own, after.own);
      assertIncrement("postinstall metadata raw socket", before.v4, after.v4);
    }

    // Browser uid (when configured): allow-internal-then-drop — loopback
    // exempt, metadata blocked. The sandbox block above is unchanged.
    if (opts.browserUid !== undefined) {
      proof.browserLoopbackRc = curlAs(ns, opts.browserUid, `http://127.0.0.1:${LISTENER_PORT}/`);
      proof.browserBlockedRc = curlAs(ns, opts.browserUid, METADATA_URL);
    }

    return proof;
  } finally {
    // Teardown is unconditional: kill the listener group, drop the netns,
    // remove the scratch dir, and REFUSE to leave the netns behind.
    if (listener?.pid !== undefined) {
      try {
        process.kill(-listener.pid, "SIGKILL"); // negative pid = the detached group
      } catch {
        try {
          listener.kill("SIGKILL");
        } catch {
          /* already gone */
        }
      }
    }
    try {
      run("ip", ["netns", "del", ns]);
    } catch {
      /* already gone — the presence check below is the gate */
    }
    rmSync(tmp, { recursive: true, force: true });
    const remaining = run("ip", ["netns", "list"]).stdout;
    if (remaining.includes(ns)) {
      throw new Error(`netns proof: teardown failed — ${ns} still present in ip netns list`);
    }
  }
}
