import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { isNonPublicAddress, parseAddressBytes } from "@ovid/shared";
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

// Hand-derived from isNonPublicAddress. Keep these literals independent of
// the exported defaults so deleting a default cannot delete its expectation.
const REQUIRED_BLOCKED_V4 = [
  "0.0.0.0/8",
  "10.0.0.0/8",
  "100.64.0.0/10",
  "127.0.0.0/8",
  "169.254.0.0/16",
  "172.16.0.0/12",
  "192.0.0.0/24",
  "192.168.0.0/16",
  "198.18.0.0/15",
  "224.0.0.0/4",
  "240.0.0.0/4",
] as const;

const REQUIRED_BLOCKED_V6 = [
  "::/128",
  "::1/128",
  // IPv4-compatible forms need the same precise embedded-v4 classification;
  // ::/104 is deliberately NOT the over-broad ::/96.
  "::/104",
  "::a00:0/104", // ::10.0.0.0/8 embedded
  "::6440:0/106", // ::100.64.0.0/10 embedded
  "::7f00:0/104", // ::127.0.0.0/8 embedded
  "::a9fe:0/112", // ::169.254.0.0/16 embedded
  "::ac10:0/108", // ::172.16.0.0/12 embedded
  "::c000:0/120", // ::192.0.0.0/24 embedded
  "::c0a8:0/112", // ::192.168.0.0/16 embedded
  "::c612:0/111", // ::198.18.0.0/15 embedded
  "::e000:0/100", // ::224.0.0.0/4 embedded
  "::f000:0/100", // ::240.0.0.0/4 embedded
  "::ffff:0:0/96",
  "fe80::/10",
  "fc00::/7",
  "fec0::/10",
  "ff00::/8",
  "2002::/16",
  "64:ff9b::/96",
] as const;

function cidrContains(address: string, cidr: string): boolean {
  const slash = cidr.lastIndexOf("/");
  const network = cidr.slice(0, slash);
  const prefix = Number(cidr.slice(slash + 1));
  const addressBytes = parseAddressBytes(address);
  const networkBytes = parseAddressBytes(network);
  if (addressBytes === null || networkBytes === null || addressBytes.length !== networkBytes.length) {
    throw new Error(`bad parity fixture: ${address} vs ${cidr}`);
  }
  for (let bit = 0; bit < prefix; bit++) {
    const mask = 1 << (7 - (bit % 8));
    const index = Math.floor(bit / 8);
    if ((addressBytes[index] & mask) !== (networkBytes[index] & mask)) return false;
  }
  return true;
}

function coveredByDefaults(address: string): boolean {
  const bytes = parseAddressBytes(address);
  if (bytes === null) throw new Error(`bad parity address: ${address}`);
  const ranges = bytes.length === 4 ? DEFAULT_BLOCKED_V4 : DEFAULT_BLOCKED_V6;
  return ranges.some((cidr) => cidrContains(address, cidr));
}

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
    // 3 network blocks + the catch-all deny that closes the outbound allow-list.
    expect(dropLines(rs).length).toBe(4);
  });

  it("sandbox outbound is allow-listed to 80/443/53 and denies everything else", () => {
    // Founder directive 2026-10-18: no SMTP, SSH, torrent, tunnel or mining
    // ports from a sandbox. The allow-list is explicit and the final rule
    // denies whatever it did not accept.
    const rs = renderNftRuleset(BASE);
    expect(rs).toContain("meta skuid 200000-209999 tcp dport { 53, 80, 443 } counter accept");
    expect(rs).toContain("meta skuid 200000-209999 udp dport { 53 } counter accept");
    expect(rs).toContain("meta skuid 200000-209999 counter drop");
    // The catch-all must come AFTER the accepts or it would shadow them.
    const lines = rs.split("\n");
    const firstAccept = lines.findIndex((l) => l.includes("tcp dport { 53, 80, 443 }"));
    const catchAll = lines.findIndex((l) =>
      l.trim() === "meta skuid 200000-209999 counter drop",
    );
    expect(firstAccept).toBeGreaterThan(-1);
    expect(catchAll).toBeGreaterThan(firstAccept);
  });

  it("rejects an out-of-range or empty port list (it is rendered into nft)", () => {
    expect(() => renderNftRuleset({ ...BASE, egressTcpPorts: [0] })).toThrow(/egressTcpPorts/);
    expect(() => renderNftRuleset({ ...BASE, egressTcpPorts: [70000] })).toThrow(/egressTcpPorts/);
    expect(() => renderNftRuleset({ ...BASE, egressTcpPorts: [] })).toThrow(/egressTcpPorts/);
    expect(() => renderNftRuleset({ ...BASE, egressUdpPorts: [1.5] })).toThrow(/egressUdpPorts/);
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

  it("renders the complete nonpublic backstop without ::/96", () => {
    expect(DEFAULT_BLOCKED_V4).toEqual(REQUIRED_BLOCKED_V4);
    expect(DEFAULT_BLOCKED_V6).toEqual(REQUIRED_BLOCKED_V6);
    expect(DEFAULT_BLOCKED_V6).not.toContain("::/96");
    const rs = renderNftRuleset(BASE);
    for (const cidr of [...REQUIRED_BLOCKED_V4, ...REQUIRED_BLOCKED_V6]) {
      expect(rs, `rendered ruleset missing ${cidr}`).toContain(cidr);
    }
  });

  it.each([
    "0.0.0.5",
    "10.0.0.1",
    "100.100.100.200",
    "127.0.0.1",
    "169.254.169.254",
    "172.31.255.255",
    "192.0.0.9",
    "192.168.1.1",
    "198.19.255.255",
    "224.0.0.1",
    "255.255.255.255",
    "::",
    "::1",
    "::0.0.0.2",
    "::ffff:127.0.0.1",
    "::ffff:10.0.0.1",
    "::127.0.0.1",
    "::10.0.0.1",
    "::100.100.100.200",
    "::169.254.169.254",
    "::172.16.0.1",
    "::192.0.0.9",
    "::192.168.1.1",
    "::198.18.0.1",
    "::224.0.0.1",
    "::255.255.255.255",
    "fc00::1",
    "fdff::1",
    "fe80::1",
    "fec0::1",
    "ff02::1",
    "64:ff9b::a00:1",
    "2002:7f00:1::1",
  ])("classifier/render parity covers nonpublic %s", (address) => {
    expect(isNonPublicAddress(address), `shared classifier fixture ${address}`).toBe(true);
    expect(coveredByDefaults(address), `nft defaults must cover ${address}`).toBe(true);
  });

  it.each([
    "8.8.8.8",
    "100.128.0.1",
    "192.0.1.1",
    "198.20.0.1",
    "223.255.255.255",
    "2606:4700::1111",
    "2001:4860:4860::8888",
    // Public IPv4-compatible addresses are the counterexamples that forbid
    // the broad ::/96 block. Mapped/6to4/NAT64 are intentional supersets.
    "::1.2.3.4",
    "::8.8.8.8",
    "::93.184.216.34",
  ])("classifier/render parity leaves public %s outside the default sets", (address) => {
    expect(isNonPublicAddress(address), `shared classifier fixture ${address}`).toBe(false);
    expect(coveredByDefaults(address), `nft defaults must not cover ${address}`).toBe(false);
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

  it("without a browser range the only accepts are the sandbox port allow-list", () => {
    const rs = renderNftRuleset(BASE);
    const accepts = (rs.match(/^.*accept$/gm) ?? []).map((l) => l.trim());
    // Two, both keyed to the sandbox uids: tcp 53/80/443 and udp 53.
    expect(accepts).toEqual([
      "meta skuid 200000-209999 tcp dport { 53, 80, 443 } counter accept",
      "meta skuid 200000-209999 udp dport { 53 } counter accept",
    ]);
    // No browser-uid accept leaked in.
    expect(rs).not.toContain("meta skuid 230000");
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
    expect(dropIdxs.length).toBe(4);
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
    // 3 network blocks + 2 port accepts + the catch-all deny.
    expect(without.length).toBe(6);
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

  it("refuses uids below 100000 (the system/user range) — including the worker uid 0", () => {
    for (const bad of ["0", "1", "99999", "99999-100000", "0-230000"]) {
      expect(() => parseBrowserEgressUid(bad), `input ${bad}`).toThrow(
        /OVID_BROWSER_EGRESS_UID/,
      );
    }
    // The floor itself is valid.
    expect(parseBrowserEgressUid("100000")).toEqual([100_000, 100_000]);
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

  it.each([
    { name: "production", base: undefined, key: "200000-209999" },
    { name: "staging", base: "220000", key: "220000-229999" },
  ])("renders the full nonpublic superset for $name UID $key", ({ base, key }) => {
    const rs = renderCli({
      OVID_PUBLIC_IP: "203.0.113.7",
      ...(base === undefined ? {} : { OVID_SANDBOX_UID_BASE: base }),
    });
    for (const cidr of [...REQUIRED_BLOCKED_V4, ...REQUIRED_BLOCKED_V6]) {
      expect(rs, `${key} rendered ruleset missing ${cidr}`).toContain(cidr);
    }
    for (const line of dropLines(rs)) expect(line).toContain(`skuid ${key}`);
    const accepts = (rs.match(/^.*accept$/gm) ?? []).map((line) => line.trim());
    expect(accepts, "the range update must not open new ports").toEqual([
      `meta skuid ${key} tcp dport { 53, 80, 443 } counter accept`,
      `meta skuid ${key} udp dport { 53 } counter accept`,
    ]);
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
    // OVID_BROWSER_EGRESS_ALLOW without a browser uid is inert: the only
    // accepts are the sandbox port allow-list, none of them browser-keyed.
    const inert = renderCli({
      OVID_PUBLIC_IP: "203.0.113.7",
      OVID_BROWSER_EGRESS_ALLOW: "10.1.2.3/32",
    });
    const inertAccepts = (inert.match(/^.*accept$/gm) ?? []).map((l) => l.trim());
    expect(inertAccepts).toHaveLength(2);
    expect(inertAccepts.every((l) => l.startsWith("meta skuid 200000-209999 "))).toBe(true);
    expect(inert).not.toContain("meta skuid 230000");
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

  it("staging sandbox block (220000-229999) also rejects overlap; 230000 stays distinct", () => {
    const staging = {
      OVID_PUBLIC_IP: "203.0.113.7",
      OVID_SANDBOX_UID_BASE: "220000",
      OVID_SANDBOX_UID_MAX: "229999",
    };
    expect(() =>
      renderCli({ ...staging, OVID_BROWSER_EGRESS_UID: "225000" }),
    ).toThrow(/overlaps the sandbox uidRange/);
    const rs = renderCli({ ...staging, OVID_BROWSER_EGRESS_UID: "230000" });
    expect(rs).toContain("meta skuid 230000-230000 ip daddr @blocked_v4 counter drop");
    expect(rs).not.toContain("skuid 225000");
  });
});
