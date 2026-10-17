import { spawnSync } from "node:child_process";
import { afterAll, describe, expect, it } from "vitest";
import { hostTestsAvailable } from "./hostGate.js";
import { runEgressNetnsProof } from "./netTestKit.js";

/**
 * HOST-GATED nftables egress proofs (Task 11 Step 4). Runs only when
 * OVID_SANDBOX_HOST_TESTS=1 and root, and needs nft/ip/curl/python3/setpriv
 * on PATH. Everything runs inside disposable `ovid-spike-egress-*` netns —
 * the host's own table (if any) is never touched, and the kit tears each
 * netns down in a finally. No bwrap/jail mechanism is involved.
 */

function netnsToolsAvailable(): boolean {
  for (const tool of ["nft", "ip", "curl", "python3", "setpriv"]) {
    if (spawnSync("sh", ["-c", `command -v ${tool}`]).status !== 0) return false;
  }
  return true;
}

describe.skipIf(!hostTestsAvailable() || !netnsToolsAvailable())(
  "nftables egress proof (host-gated, disposable netns)",
  () => {
    it("sandbox uid is blocked (rc 28, counter > 0) while root is not (rc 0) — uid-keying, Review Focus #5", async () => {
      const proof = await runEgressNetnsProof({ ownPublicIp: "203.0.113.7", uid: 200050 });
      // 127.0.0.1:8999 is inside the blocked 127.0.0.0/8 → curl as the uid times out.
      expect(proof.blockedRc).toBe(28);
      // The deny rule fired at the output hook — the block is the filter's doing.
      expect(proof.counterPackets).toBeGreaterThan(0);
      // Root reaches the SAME listener — the drop is keyed on the uid, not the address.
      expect(proof.rootRc).toBe(0);
      // The metadata path (169.254.169.254) also lands on the blocked_v4 rule:
      // rc 28, and the kit enforces the counter strictly increased for it.
      expect(proof.metadataBlockedRc).toBe(28);
    });

    it("browser range (gap G2): loopback allowed (rc 0) AND metadata blocked (rc 28) — allow-internal-then-drop", async () => {
      // 210050 is outside the sandbox range by the overlap rule, so these
      // curls hit only the browser section.
      const proof = await runEgressNetnsProof({
        ownPublicIp: "203.0.113.7",
        uid: 200050,
        browserUid: 210050,
      });
      expect(proof.browserLoopbackRc).toBe(0);
      expect(proof.browserBlockedRc).toBe(28);
      // Sandbox-side guarantees still hold in the same ruleset.
      expect(proof.blockedRc).toBe(28);
      expect(proof.counterPackets).toBeGreaterThan(0);
      expect(proof.rootRc).toBe(0);
      expect(proof.metadataBlockedRc).toBe(28);
    });

    afterAll(() => {
      // Netns cleanliness: nothing probe-scoped may outlive the suite.
      const list = spawnSync("ip", ["netns", "list"], { encoding: "utf8" });
      expect(list.status).toBe(0);
      expect(list.stdout, `leftover netns: ${list.stdout}`).not.toContain("ovid-spike-egress-");
    });
  },
);
