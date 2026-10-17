import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { beforeAll, afterAll, describe, expect, it } from "vitest";
import {
  DEFAULT_BLOCKED_V4,
  DEFAULT_BLOCKED_V6,
  isValidV6Cidr,
  parseBrowserEgressUid,
  renderNftRuleset,
  type EgressConfig,
} from "./net.js";
import { renderCli } from "./renderNftCli.js";

// Task 11 brief: the rendered ruleset is the security contract (Review Focus
// #5 — sandbox egress to internal/metadata endpoints). These portable tests
// pin its structure; the host-gated netns proof (net.host.test.ts) pins its
// BEHAVIOUR on a real kernel.

const BASE: EgressConfig = {
  uidRange: [200_000, 209_999],
  blockedV4: [...DEFAULT_BLOCKED_V4],
  blockedV6: [...DEFAULT_BLOCKED_V6],
  ownPublicIp: "203.0.113.7",
};

const BROWSER: EgressConfig = {
  ...BASE,
  browserUidRange: [230_000, 230_099],
  browserAllowedV4: ["10.1.2.3/32", "172.20.0.0/16"],
};

/** Every line of the ruleset that ends a rule with `drop` must be uid-keyed. */
function dropLines(ruleset: string): string[] {
  return ruleset
    .split("\n")
    .filter((l) => /\bdrop\b/.test(l));
}

/** All rules mentioning a given skuid key (`meta skuid a-b …`). */
function skuidLines(ruleset: string, key: string): string[] {
  return ruleset
    .split("\n")
    .filter((l) => l.includes(`skuid ${key} `) || l.trimEnd().endsWith(`skuid ${key}`));
}

describe("renderNftRuleset — sandbox range", () => {
  it("every deny rule is keyed on the configured uid range (meta skuid 200000-209999)", () => {
    const rs = renderNftRuleset(BASE);
    expect(rs).toContain("meta skuid 200000-209999 ip daddr @blocked_v4 counter drop");
    expect(rs).toContain("meta skuid 200000-209999 ip6 daddr @blocked_v6 counter drop");
    expect(rs).toContain("meta skuid 200000-209999 ip daddr 203.0.113.7 counter drop");
    expect(dropLines(rs).length).toBe(3);
  });

  it("regex sweep: NO line containing `drop` lacks the skuid key", () => {
    const rs = renderNftRuleset(BASE);
    for (const line of dropLines(rs)) {
      expect(line, `unkeyed deny rule: ${line}`).toContain("skuid");
    }
  });

  it("blocked sets: every default element present, both sets flags interval", () => {
    const rs = renderNftRuleset(BASE);
    for (const cidr of DEFAULT_BLOCKED_V4) expect(rs).toContain(cidr);
    for (const cidr of DEFAULT_BLOCKED_V6) expect(rs).toContain(cidr);
    expect(rs.match(/flags interval/g)?.length).toBe(2);
    expect(rs).toContain("set blocked_v4");
    expect(rs).toContain("set blocked_v6");
  });

  it("defaults carry CGNAT and the FULL app-guard v6 set (P6 Finding 2 parity)", () => {
    // Literal pins, not a loop over the exported arrays: dropping a range
    // from DEFAULT_BLOCKED_* must fail here (the parametric test above would
    // still pass). The list must never be narrower than the browser app
    // guard in cloud/packages/browser/src/url.ts `isNonPublicAddress`.
    const rs = renderNftRuleset(BASE);
    expect(DEFAULT_BLOCKED_V4).toContain("100.64.0.0/10");
    expect(rs).toContain("100.64.0.0/10");
    const v6 = [
      "::1/128",
      "fe80::/10",
      "fc00::/7",
      "fec0::/10",
      "ff00::/8",
      "2002::/16",
      "64:ff9b::/96",
    ];
    for (const cidr of v6) {
      expect(DEFAULT_BLOCKED_V6, `DEFAULT_BLOCKED_V6 missing ${cidr}`).toContain(cidr);
      expect(rs, `rendered ruleset missing ${cidr}`).toContain(cidr);
    }
  });

  it("output chain: filter hook, priority 0, policy accept", () => {
    expect(renderNftRuleset(BASE)).toContain(
      "type filter hook output priority 0; policy accept;",
    );
  });

  it("flush-on-reload safe: declare-then-delete guard precedes the full table", () => {
    const rs = renderNftRuleset(BASE);
    const lines = rs.split("\n");
    const declare = lines.findIndex((l) => l === "table inet ovid_sandbox");
    const del = lines.findIndex((l) => l === "delete table inet ovid_sandbox");
    const full = lines.findIndex((l) => l === "table inet ovid_sandbox {");
    expect(declare).toBeGreaterThanOrEqual(0);
    expect(del).toBeGreaterThan(declare);
    expect(full).toBeGreaterThan(del);
  });

  it("default table name is ovid_sandbox; custom table renders", () => {
    expect(renderNftRuleset(BASE)).toContain("table inet ovid_sandbox");
    const custom = renderNftRuleset({ ...BASE, table: "ovid_test_t" });
    expect(custom).toContain("table inet ovid_test_t");
    expect(custom).toContain("delete table inet ovid_test_t");
  });

  it("without a browser range there are NO accept rules at all", () => {
    const rs = renderNftRuleset(BASE);
    // `policy accept;` ends with ';'; only browser-section rules end in `accept`.
    expect(rs.match(/accept$/gm)).toBeNull();
  });

  it("rejects a non-IPv4 own public IP (the rule keys on `ip daddr`)", () => {
    expect(() => renderNftRuleset({ ...BASE, ownPublicIp: "not-an-ip" })).toThrow(
      /ownPublicIp/,
    );
    expect(() => renderNftRuleset({ ...BASE, ownPublicIp: "2001:db8::1" })).toThrow(
      /ownPublicIp/,
    );
  });

  it("rejects malformed blocked-set entries and uid ranges", () => {
    expect(() =>
      renderNftRuleset({ ...BASE, blockedV4: [...DEFAULT_BLOCKED_V4, "999.1.2.3"] }),
    ).toThrow(/blockedV4/);
    expect(() =>
      renderNftRuleset({ ...BASE, blockedV6: [...DEFAULT_BLOCKED_V6, "nope"] }),
    ).toThrow(/blockedV6/);
    expect(() => renderNftRuleset({ ...BASE, uidRange: [210_000, 200_000] })).toThrow(
      /uidRange/,
    );
  });
});

describe("renderNftRuleset — browser range (gap G2, allow-internal-then-drop)", () => {
  it("browser drops cover the SAME blocked sets + own public IP, keyed on the browser range", () => {
    const rs = renderNftRuleset(BROWSER);
    expect(rs).toContain("meta skuid 230000-230099 ip daddr @blocked_v4 counter drop");
    expect(rs).toContain("meta skuid 230000-230099 ip6 daddr @blocked_v6 counter drop");
    expect(rs).toContain("meta skuid 230000-230099 ip daddr 203.0.113.7 counter drop");
  });

  it("loopback accepts come BEFORE every browser drop rule (index order)", () => {
    const rs = renderNftRuleset(BROWSER);
    const lines = rs.split("\n");
    const v4Loopback = lines.findIndex((l) =>
      l.trim() === "meta skuid 230000-230099 ip daddr 127.0.0.0/8 accept",
    );
    const v6Loopback = lines.findIndex((l) =>
      l.trim() === "meta skuid 230000-230099 ip6 daddr ::1/128 accept",
    );
    expect(v4Loopback).toBeGreaterThanOrEqual(0);
    expect(v6Loopback).toBeGreaterThanOrEqual(0);
    const dropIdxs = lines
      .map((l, i) => (/\bskuid 230000-230099\b/.test(l) && /\bdrop\b/.test(l) ? i : -1))
      .filter((i) => i >= 0);
    expect(dropIdxs.length).toBe(3);
    for (const d of dropIdxs) {
      expect(v4Loopback, "127/8 accept must precede every browser deny rule").toBeLessThan(d);
      expect(v6Loopback, "::1 accept must precede every browser deny rule").toBeLessThan(d);
    }
  });

  it("each browserAllowedV4 entry renders an accept rule before the drops", () => {
    const rs = renderNftRuleset(BROWSER);
    const lines = rs.split("\n");
    const firstDrop = lines.findIndex(
      (l) => /\bskuid 230000-230099\b/.test(l) && /\bdrop\b/.test(l),
    );
    expect(rs).toContain("meta skuid 230000-230099 ip daddr 10.1.2.3/32 accept");
    expect(rs).toContain("meta skuid 230000-230099 ip daddr 172.20.0.0/16 accept");
    for (const l of lines) {
      if (/skuid 230000-230099 ip daddr (10\.1\.2\.3|172\.20\.0\.0)/.test(l)) {
        expect(lines.indexOf(l)).toBeLessThan(firstDrop);
      }
    }
  });

  it("loopback is ALWAYS allowed for the browser range — never configurable", () => {
    // 127.0.0.0/8 is hardcoded in the browser section (LiteLLM :4000 and the
    // pg/mint proxies live there) and entries inside 127/8 are REJECTED
    // rather than double-rendered or silently honored.
    const rs = renderNftRuleset({ ...BROWSER, browserAllowedV4: [] });
    expect(rs).toContain("meta skuid 230000-230099 ip daddr 127.0.0.0/8 accept");
    expect(rs).toContain("meta skuid 230000-230099 ip6 daddr ::1/128 accept");
    expect(() => renderNftRuleset({ ...BROWSER, browserAllowedV4: ["127.0.0.0/8"] })).toThrow(
      /browserAllowedV4/,
    );
    expect(() => renderNftRuleset({ ...BROWSER, browserAllowedV4: ["127.0.0.1/32"] })).toThrow(
      /browserAllowedV4/,
    );
  });

  it("sandbox rules are byte-identical with and without the browser section", () => {
    const without = skuidLines(renderNftRuleset(BASE), "200000-209999");
    const withBrowser = skuidLines(renderNftRuleset(BROWSER), "200000-209999");
    expect(withBrowser).toEqual(without);
    expect(without.length).toBe(3);
  });

  it("an overlapping browser range throws, naming BOTH ranges", () => {
    let err: unknown;
    try {
      renderNftRuleset({ ...BASE, browserUidRange: [205_000, 205_999] });
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(Error);
    const msg = (err as Error).message;
    expect(msg).toContain("205000");
    expect(msg).toContain("205999");
    expect(msg).toContain("200000");
    expect(msg).toContain("209999");
  });
});

describe("parseBrowserEgressUid", () => {
  it("single uid → [u, u]; range → the pair", () => {
    expect(parseBrowserEgressUid("230000")).toEqual([230_000, 230_000]);
    expect(parseBrowserEgressUid("230000-230099")).toEqual([230_000, 230_099]);
  });

  it("undefined/empty → undefined", () => {
    expect(parseBrowserEgressUid(undefined)).toBeUndefined();
    expect(parseBrowserEgressUid("")).toBeUndefined();
  });

  it("malformed → throws naming OVID_BROWSER_EGRESS_UID", () => {
    for (const bad of ["abc", "230000-", "-230099", "230099-230000", "23a000", "1.5"]) {
      expect(() => parseBrowserEgressUid(bad), `input ${bad}`).toThrow(
        /OVID_BROWSER_EGRESS_UID/,
      );
    }
  });
});

describe("isValidV6Cidr (M1: strict — loose input must fail at render time, not load time)", () => {
  it("accepts real v6 addresses and cidrs", () => {
    for (const good of ["::1", "::1/128", "fe80::", "fe80::/10", "fc00::/7", "::ffff:1.2.3.4"]) {
      expect(isValidV6Cidr(good), good).toBe(true);
    }
  });

  it("rejects ':::', malformed/garbage, and bad prefixes", () => {
    for (const bad of [
      ":::",
      ":/:",
      "nope",
      "fe80::/", // empty prefix
      "fe80::/129",
      "fe80::/ten",
      "1.2.3.4/24", // v4 is not a v6 cidr
    ]) {
      expect(isValidV6Cidr(bad), bad).toBe(false);
    }
  });
});

describe("render-nft bin — invoked through a SYMLINK (pnpm node_modules/.bin layout, I1)", () => {
  // The bin-level tests execute dist/renderNftCli.js, so build the package
  // first — always, not only when dist is missing: a stale dist would let a
  // regression hide behind old output.
  const PKG_ROOT = fileURLToPath(new URL("..", import.meta.url));
  const CLI_DIST = join(PKG_ROOT, "dist", "renderNftCli.js");
  const tmp = mkdtempSync(join(tmpdir(), "ovid-nft-bin-"));
  // pnpm installs package bins as symlinks into node_modules/.bin — this
  // layout is exactly what the guard must survive (I1).
  const link = join(tmp, "render-nft");

  beforeAll(() => {
    const build = spawnSync(join(PKG_ROOT, "node_modules", ".bin", "tsc"), ["-p", "tsconfig.json"], {
      cwd: PKG_ROOT,
      encoding: "utf8",
      timeout: 60_000,
    });
    if (build.status !== 0) {
      throw new Error(`bin tests need a fresh build, tsc failed:\n${build.stderr}`);
    }
    symlinkSync(CLI_DIST, link);
  }, 60_000);

  afterAll(() => rmSync(tmp, { recursive: true, force: true }));

  it("missing OVID_PUBLIC_IP through a symlink → exit 1 + usage on stderr, NOT silent success", () => {
    const r = spawnSync(process.execPath, [link], { encoding: "utf8", env: {} });
    // Regression (I1): the old import.meta.url === pathToFileURL(argv[1])
    // guard mismatched on symlinks → exit 0 with ZERO output — a silent
    // empty "ruleset" from a security-adjacent tool.
    expect(r.status).toBe(1);
    expect(r.stdout).toBe("");
    expect(r.stderr).toContain("OVID_PUBLIC_IP");
    expect(r.stderr).toContain("usage:");
  });

  it("with OVID_PUBLIC_IP through a symlink → exit 0 + the real ruleset on stdout", () => {
    const r = spawnSync(process.execPath, [link], {
      encoding: "utf8",
      env: { OVID_PUBLIC_IP: "203.0.113.7" },
    });
    expect(r.status).toBe(0);
    expect(r.stderr).toBe("");
    expect(r.stdout).toContain("meta skuid 200000-209999 ip daddr @blocked_v4 counter drop");
    expect(r.stdout).toContain("meta skuid 200000-209999 ip daddr 203.0.113.7 counter drop");
  });

  it("direct (non-symlink) invocation still behaves identically", () => {
    const r = spawnSync(process.execPath, [CLI_DIST], { encoding: "utf8", env: {} });
    expect(r.status).toBe(1);
    expect(r.stderr).toContain("usage:");
    expect(
      spawnSync(process.execPath, [CLI_DIST], {
        encoding: "utf8",
        env: { OVID_PUBLIC_IP: "198.51.100.9" },
      }).stdout,
    ).toContain("meta skuid 200000-209999 ip daddr 198.51.100.9 counter drop");
  });
});

describe("renderCli — env contract (gap G4: rules key on the CONFIGURED range)", () => {
  it("missing OVID_PUBLIC_IP → throws naming it", () => {
    expect(() => renderCli({})).toThrow(/OVID_PUBLIC_IP/);
    expect(() => renderCli({ OVID_SANDBOX_UID_BASE: "200000" })).toThrow(/OVID_PUBLIC_IP/);
  });

  it("non-IPv4 OVID_PUBLIC_IP → throws naming it", () => {
    expect(() => renderCli({ OVID_PUBLIC_IP: "not-an-ip" })).toThrow(/OVID_PUBLIC_IP/);
  });

  it("defaults: base 200000, uidMax base+9999 — every deny rule keyed 200000-209999", () => {
    const rs = renderCli({ OVID_PUBLIC_IP: "203.0.113.7" });
    for (const line of dropLines(rs)) {
      expect(line).toContain("skuid 200000-209999");
    }
    expect(rs).toContain("meta skuid 200000-209999 ip daddr 203.0.113.7 counter drop");
  });

  it("staging base 220000 → keyed 220000-229999, NO literal 200000 anywhere", () => {
    const rs = renderCli({ OVID_SANDBOX_UID_BASE: "220000", OVID_PUBLIC_IP: "203.0.113.7" });
    for (const line of dropLines(rs)) {
      expect(line).toContain("skuid 220000-229999");
    }
    expect(rs).not.toContain("200000");
    expect(rs).not.toContain("209999");
  });

  it("explicit OVID_SANDBOX_UID_MAX narrows the key; out-of-width values throw", () => {
    const rs = renderCli({
      OVID_SANDBOX_UID_BASE: "220000",
      OVID_SANDBOX_UID_MAX: "220500",
      OVID_PUBLIC_IP: "203.0.113.7",
    });
    for (const line of dropLines(rs)) {
      expect(line).toContain("skuid 220000-220500");
    }
    expect(() =>
      renderCli({
        OVID_SANDBOX_UID_BASE: "220000",
        OVID_SANDBOX_UID_MAX: "231000",
        OVID_PUBLIC_IP: "203.0.113.7",
      }),
    ).toThrow(/OVID_SANDBOX_UID_MAX/);
  });

  it("OVID_SANDBOX_EXTRA_BLOCKED csv lands in the blocked sets (v4 and v6)", () => {
    const rs = renderCli({
      OVID_PUBLIC_IP: "203.0.113.7",
      OVID_SANDBOX_EXTRA_BLOCKED: "100.64.0.0/10,fd00::/8",
    });
    expect(rs).toContain("100.64.0.0/10");
    expect(rs).toContain("fd00::/8");
    expect(() =>
      renderCli({
        OVID_PUBLIC_IP: "203.0.113.7",
        OVID_SANDBOX_EXTRA_BLOCKED: "100.64.0.0/10,,fd00::/8",
      }),
    ).toThrow(/OVID_SANDBOX_EXTRA_BLOCKED/);
  });

  it("browser env: OVID_BROWSER_EGRESS_UID single or range + allow csv", () => {
    const single = renderCli({
      OVID_PUBLIC_IP: "203.0.113.7",
      OVID_BROWSER_EGRESS_UID: "230000",
    });
    expect(single).toContain("meta skuid 230000-230000 ip daddr 127.0.0.0/8 accept");
    expect(single).toContain("meta skuid 230000-230000 ip daddr @blocked_v4 counter drop");

    const ranged = renderCli({
      OVID_PUBLIC_IP: "203.0.113.7",
      OVID_BROWSER_EGRESS_UID: "230000-230099",
      OVID_BROWSER_EGRESS_ALLOW: "10.1.2.3/32,172.20.0.0/16",
    });
    expect(ranged).toContain("meta skuid 230000-230099 ip daddr 10.1.2.3/32 accept");
    expect(ranged).toContain("meta skuid 230000-230099 ip daddr 172.20.0.0/16 accept");
    // OVID_BROWSER_EGRESS_ALLOW without a browser uid is inert: no accept rules
    expect(
      renderCli({ OVID_PUBLIC_IP: "203.0.113.7", OVID_BROWSER_EGRESS_ALLOW: "10.1.2.3/32" }).match(
        /accept$/gm,
      ),
    ).toBeNull();
  });

  it("browser env overlapping the configured sandbox range → throws naming both ranges", () => {
    let err: unknown;
    try {
      renderCli({
        OVID_PUBLIC_IP: "203.0.113.7",
        OVID_BROWSER_EGRESS_UID: "205000-205999",
      });
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(Error);
    const msg = (err as Error).message;
    expect(msg).toContain("205000");
    expect(msg).toContain("200000");
  });
});
