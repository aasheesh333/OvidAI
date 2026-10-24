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
  for (const tool of ["nft", "ip", "curl", "python3", "setpriv", "npm"]) {
    if (spawnSync("sh", ["-c", `command -v ${tool}`]).status !== 0) return false;
  }
  return true;
}

describe.skipIf(!hostTestsAvailable() || !netnsToolsAvailable())(
  "nftables egress proof (host-gated, disposable netns)",
  () => {
    it.each([
      { name: "production", range: "200000-209999", uidRange: [200_000, 209_999] as [number, number], uid: 200_050 },
      { name: "staging", range: "220000-229999", uidRange: [220_000, 229_999] as [number, number], uid: 220_050 },
    ])("$name $range raw-socket/postinstall denial (rc 28 + counters), root controls rc 0", async ({ uidRange, uid }) => {
      const proof = await runEgressNetnsProof({
        ownPublicIp: "203.0.113.7",
        uid,
        uidRange,
        runRawSocketPostinstallProof: true,
      });
      // 127.0.0.1:8999 is inside the blocked 127.0.0.0/8 → curl as the uid times out.
      expect(proof.blockedRc).toBe(28);
      expect(proof.counterPackets).toBeGreaterThan(0);
      expect(proof.rootRc).toBe(0);
      expect(proof.metadataBlockedRc).toBe(28);

      const raw = proof.rawSocketPostinstall;
      expect(raw).not.toBeNull();
      expect(raw?.mappedLoopbackRc).toBe(28);
      expect(raw?.mappedLoopbackRootRc).toBe(0);
      expect(raw?.mappedLoopbackCounterDelta).toBeGreaterThan(0);
      expect(raw?.hostRc).toBe(28);
      expect(raw?.hostRootRc).toBe(0);
      expect(raw?.hostCounterDelta).toBeGreaterThan(0);
      expect(raw?.metadataRc).toBe(28);
      expect(raw?.metadataRootRc).toBe(0);
      expect(raw?.metadataCounterDelta).toBeGreaterThan(0);
      // Lifecycle scripts are forcibly enabled in this disposable proof. A
      // missing marker is a failed proof, never a secure-looking skip.
      expect(raw?.postinstallRan).toBe(true);
      expect(raw?.postinstallHostRc).toBe(28);
      expect(raw?.postinstallMetadataRc).toBe(28);
      expect(raw?.postinstallHostCounterDelta).toBeGreaterThan(0);
      expect(raw?.postinstallMetadataCounterDelta).toBeGreaterThan(0);
    }, 120_000);

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
