/**
 * P10 Task 8 — pins Review Focus #4: the security corpus can never silently
 * never run.
 *
 * These assertions are deterministic and host-independent: capability probes
 * are injected, and stdout is captured. They pin:
 * - every missing capability is named in `capabilityGate().reasons`,
 * - a skipped group prints `SKIPPED: <reason>`, is accumulated in
 *   `SKIPPED_SECURITY`, and never executes its body,
 * - a capable group runs and is counted,
 * - the summary line is `security corpus: N ran, M SKIPPED: <reasons>`,
 * - a zero-case corpus is loudly reported instead of a green `0 SKIPPED`.
 */

import { afterEach, describe, expect, it, vi } from "vitest";

import {
  capabilityGate,
  formatSecuritySummary,
  printSecuritySummary,
  recordSecurityRun,
  recordSecuritySkip,
  resetSecurityReport,
  SECURITY_SUMMARY_PREFIX,
  securityCase,
  securityCorpusCounts,
  SKIPPED_SECURITY,
  STAGING_NFT_TABLE,
} from "./skipReport.js";

afterEach(() => {
  vi.restoreAllMocks();
  resetSecurityReport();
});

describe("security corpus skip reporting (Review Focus #4)", () => {
  it("capabilityGate names every missing capability in one reason list", () => {
    const gate = capabilityGate({
      platform: "darwin",
      isRoot: false,
      bwrapPath: "/nope/bwrap",
      cgroupRoot: "/nope/cgroup",
      nftTable: "staging_table",
      rootfsPath: "/nope/rootfs",
      probeBwrap: (p) => `bwrap missing at ${p}`,
      probeCgroup: (r) => `cgroup unusable at ${r}`,
      probeNft: (t) => `nft table ${t} missing`,
      probeRootfs: (p) => `rootfs missing at ${p}`,
    });
    expect(gate.ok).toBe(false);
    const joined = gate.reasons.join("\n");
    expect(joined).toContain("platform is darwin, not linux");
    expect(joined).toContain("not running as root");
    expect(joined).toContain("bwrap missing at /nope/bwrap");
    expect(joined).toContain("cgroup unusable at /nope/cgroup");
    expect(joined).toContain("nft table staging_table missing");
    expect(joined).toContain("rootfs missing at /nope/rootfs");
  });

  it("capabilityGate is ok when every probe passes; requireNft=false skips only the nft probe", () => {
    const all = capabilityGate({
      platform: "linux",
      isRoot: true,
      probeBwrap: () => null,
      probeCgroup: () => null,
      probeNft: () => null,
      probeRootfs: () => null,
    });
    expect(all).toEqual({ ok: true, reasons: [] });

    const noNft = capabilityGate({
      platform: "linux",
      isRoot: true,
      requireNft: false,
      probeBwrap: () => null,
      probeCgroup: () => null,
      probeNft: () => {
        throw new Error("the nft probe must not run when requireNft=false");
      },
      probeRootfs: () => null,
    });
    expect(noNft.ok).toBe(true);
  });

  it("a skipped group prints a loud SKIPPED line, is counted, and never runs its body", async () => {
    const log = vi.fn();
    let bodyRan = false;
    const gate = { ok: false, reasons: ["bwrap binary missing at /usr/bin/bwrap"] };
    await securityCase(
      "path confinement",
      gate,
      async () => {
        bodyRan = true;
      },
      log,
    )();

    expect(bodyRan).toBe(false);
    expect(log).toHaveBeenCalledWith(
      "SKIPPED: path confinement: bwrap binary missing at /usr/bin/bwrap",
    );
    expect(SKIPPED_SECURITY).toEqual([
      "path confinement: bwrap binary missing at /usr/bin/bwrap",
    ]);
    expect(securityCorpusCounts()).toEqual({
      ran: 0,
      skipped: 1,
      reasons: ["path confinement: bwrap binary missing at /usr/bin/bwrap"],
    });
  });

  it("a capable group runs and is counted", async () => {
    const log = vi.fn();
    let bodyRan = false;
    await securityCase(
      "uid map",
      { ok: true, reasons: [] },
      async () => {
        bodyRan = true;
      },
      log,
    )();

    expect(bodyRan).toBe(true);
    expect(log).not.toHaveBeenCalled();
    expect(securityCorpusCounts()).toEqual({ ran: 1, skipped: 0, reasons: [] });
  });

  it("the summary line is printed and counted — skips cannot hide", () => {
    recordSecurityRun();
    recordSecurityRun();
    recordSecuritySkip("path confinement", "bwrap missing");
    recordSecuritySkip("egress rules", "nft staging ruleset missing");

    const log = vi.fn();
    printSecuritySummary(log);
    const expected =
      `${SECURITY_SUMMARY_PREFIX} 2 ran, 2 SKIPPED: ` +
      "path confinement: bwrap missing; egress rules: nft staging ruleset missing";
    expect(log).toHaveBeenCalledWith(expected);
    expect(formatSecuritySummary()).toBe(expected);
  });

  it("a zero-case corpus is loudly reported, never a silent green", () => {
    resetSecurityReport();
    const line = formatSecuritySummary();
    expect(line).toContain(`${SECURITY_SUMMARY_PREFIX} 0 ran, 0 SKIPPED`);
    expect(line).toContain("corpus did not execute");
  });

  it("default SKIPPED lines go to stdout so CI logs always show them", () => {
    const spy = vi.spyOn(console, "log").mockImplementation(() => {});
    recordSecuritySkip("pids.max enforcement", "not running as root");
    expect(spy).toHaveBeenCalledWith("SKIPPED: pids.max enforcement: not running as root");
  });

  it("exports the plan's staging egress table name", () => {
    expect(STAGING_NFT_TABLE).toBe("sandbox_egress_staging");
  });
});
