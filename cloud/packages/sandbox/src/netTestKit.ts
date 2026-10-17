import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
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
   * (metadata path). Extension over the brief's five fields so the caller can
   * assert it directly; the counter-increment side of that proof is enforced
   * in-kit (runEgressNetnsProof throws when the metadata curl does not move
   * the blocked_v4 counter).
   */
  metadataBlockedRc: number;
}

const LISTENER_PORT = 8999;
const METADATA_URL = "http://169.254.169.254/";
const CURL_TIMEOUT_S = 2;

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

interface RunOut {
  status: number | null;
  stdout: string;
  stderr: string;
}

function run(file: string, args: string[], timeoutMs = 10_000): RunOut {
  const r = spawnSync(file, args, { timeout: timeoutMs, encoding: "utf8" });
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

/** curl inside the netns, optionally as a uid (setpriv), returning its exit code. */
function curlAs(ns: string, uid: number | "root", url: string): number {
  const args = ["netns", "exec", ns];
  if (uid !== "root") {
    args.push("setpriv", `--reuid=${uid}`, `--regid=${uid}`, "--clear-groups");
  }
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

function listTable(ns: string): string {
  return runChecked("ip", ["netns", "exec", ns, "nft", "list", "table", "inet", "ovid_sandbox"], "nft list table").stdout;
}

/** Packets counted by the sandbox-uid blocked_v4 rule (0 when nothing matched). */
function v4Counter(ns: string, uid: number): number {
  const out = listTable(ns);
  const m = new RegExp(`meta skuid ${uid}-${uid} ip daddr @blocked_v4 counter packets (\\d+)`).exec(
    out,
  );
  if (m === null) {
    throw new Error(
      `netns proof: sandbox v4 deny rule for skuid ${uid}-${uid} not found in nft list output:\n${out}`,
    );
  }
  return Number(m[1]);
}

/**
 * Run the egress proof in a disposable netns. Requires root plus nft, ip,
 * curl, python3 and setpriv (the host suite gates on these). The ruleset is
 * rendered for exactly [uid, uid] (and [browserUid, browserUid] when given) so
 * the counter can be attributed unambiguously.
 */
export async function runEgressNetnsProof(opts: {
  ownPublicIp: string;
  uid: number;
  browserUid?: number;
}): Promise<NetnsProof> {
  const ns = `ovid-spike-egress-${process.pid}-${randomBytes(4).toString("hex")}`;
  const ruleset = renderNftRuleset({
    uidRange: [opts.uid, opts.uid],
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
  };

  try {
    runChecked("ip", ["netns", "add", ns], "ip netns add");
    runChecked("ip", ["netns", "exec", ns, "ip", "link", "set", "lo", "up"], "lo up");
    // A fresh netns has only lo + the local routing table, so 169.254.0.0/16
    // has NO route and a metadata curl would fail with ENETUNREACH before
    // ever reaching the output chain. Routing it via lo forces locally
    // generated packets through the filter, where the counter can see them.
    runChecked(
      "ip",
      ["netns", "exec", ns, "ip", "route", "add", "169.254.0.0/16", "dev", "lo"],
      "metadata route",
    );
    runChecked("ip", ["netns", "exec", ns, "nft", "-f", rulesetPath], "nft -f ruleset");

    // Listener as root INSIDE the netns; detached so the whole process group
    // can be signalled at teardown (`ip netns exec` forks a child that must
    // not outlive the kill).
    listener = spawn(
      "ip",
      ["netns", "exec", ns, "python3", "-m", "http.server", String(LISTENER_PORT), "--bind", "127.0.0.1"],
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
    const counterAfterLoopback = v4Counter(ns, opts.uid);
    proof.metadataBlockedRc = curlAs(ns, opts.uid, METADATA_URL);
    proof.counterPackets = v4Counter(ns, opts.uid);
    if (proof.counterPackets <= counterAfterLoopback) {
      throw new Error(
        `netns proof: the 169.254.169.254 curl did not increment the blocked_v4 counter ` +
          `(${counterAfterLoopback} → ${proof.counterPackets}) — metadata egress is not being filtered`,
      );
    }

    // Browser uid (when configured): allow-internal-then-drop — loopback
    // exempt, metadata blocked. 210050-style uids are outside the sandbox
    // range by the overlap rule, so these hit only the browser rules.
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
