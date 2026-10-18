import { isIP } from "node:net";

/**
 * Egress filter configuration (Task 11, research §2.4 mechanism): the nftables
 * table rendered here is the ONLY thing standing between a sandboxed uid and
 * the host's internal network (Review Focus #5) — every deny rule is keyed on
 * a uid range so non-sandbox traffic is untouched.
 */
export interface EgressConfig {
  /** Sandbox uid block [first, last] — from SandboxConfig (Task 2). */
  uidRange: [number, number];
  /** Blocked IPv4 cidrs (interval set). */
  blockedV4: string[];
  /** Blocked IPv6 cidrs (interval set). */
  blockedV6: string[];
  /** This host's public IPv4 — sandbox uids must not reach it. */
  ownPublicIp: string;
  /** nft table name; default "ovid_sandbox". */
  table?: string;
  /**
   * The P6 worker/browser-engine uid block (gap G2). Unset → no browser
   * section. MUST NOT overlap uidRange — distinct keyspaces: the browser
   * engine never shares a sandbox uid.
   */
  browserUidRange?: [number, number];
  /**
   * Outbound TCP ports a sandbox/browser uid may reach. Everything else is
   * dropped (founder directive 2026-10-18: a compromised or prompt-injected
   * agent must not be able to send mail, brute-force SSH, mine, or dial a
   * tunnel endpoint). Default [80, 443, 53].
   */
  egressTcpPorts?: number[];
  /**
   * Outbound UDP ports a sandbox/browser uid may reach. Default [53] (DNS).
   */
  egressUdpPorts?: number[];
  /**
   * Internal-endpoint IPv4 cidrs the browser uid must still reach. Loopback
   * 127.0.0.0/8 is ALWAYS allowed for the browser range (LiteLLM :4000 and
   * the pg/mint proxies live there) and is not configurable here — entries
   * inside 127/8 are rejected instead of double-rendered.
   */
  browserAllowedV4?: string[];
}

// Keep these defaults in sync with the browser app guard
// (cloud/packages/browser/src/url.ts `isNonPublicAddress`): the nftables
// backstop must never be NARROWER than the app-level check it backs up, or a
// rebound/resolved address slips past the TOCTOU-prone guard. CGNAT and the
// v6 special-purpose ranges were added for P6 final-review parity (Finding 2).
export const DEFAULT_BLOCKED_V4: readonly string[] = [
  "10.0.0.0/8",
  "100.64.0.0/10", // CGNAT (app guard: 100.64/10)
  "127.0.0.0/8",
  "169.254.0.0/16",
  "172.16.0.0/12",
  "192.168.0.0/16",
];

// v6 parity with url.ts: loopback, link-local, ULA, site-local, multicast,
// 6to4, and NAT64.
export const DEFAULT_BLOCKED_V6: readonly string[] = [
  "::1/128",
  "fe80::/10",
  "fc00::/7",
  "fec0::/10",
  "ff00::/8",
  "2002::/16",
  "64:ff9b::/96",
];

export const DEFAULT_EGRESS_TABLE = "ovid_sandbox";

// Sandbox/browser uids live in the ≥ 100000 block (config.ts UID_BASE_FLOOR):
// below that is the system/user range, and a filter keyed there would apply to
// host users — refuse to render such a ruleset.
const UID_FLOOR = 100_000;

const V4_CIDR =
  /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}(\/([0-9]|[12]\d|3[0-2]))?$/;

/** Valid IPv4 address or cidr (a bare address is a /32). */
export function isValidV4Cidr(v: string): boolean {
  return V4_CIDR.test(v);
}

/**
 * Valid IPv6 address or cidr. Strict (M1): the address half is checked with
 * isIP (so garbage like ":::" fails) and an optional numeric prefix must be
 * 0-128 — a renderer-level reject beats rendering a ruleset that only fails
 * at `nft -f` load time.
 */
export function isValidV6Cidr(v: string): boolean {
  const slash = v.lastIndexOf("/");
  if (slash === -1) return isIP(v) === 6;
  const prefix = v.slice(slash + 1);
  if (!/^\d+$/.test(prefix)) return false;
  const n = Number(prefix);
  return n <= 128 && isIP(v.slice(0, slash)) === 6;
}

function validateUidRange(label: string, range: [number, number]): void {
  const [a, b] = range;
  if (
    !Number.isInteger(a) ||
    !Number.isInteger(b) ||
    a < UID_FLOOR ||
    b < UID_FLOOR ||
    a > b
  ) {
    throw new Error(
      `OVID egress: ${label} must be two integers ${UID_FLOOR} <= first <= last, got [${a}, ${b}]`,
    );
  }
}

function validateEntries(
  label: string,
  entries: readonly string[],
  ok: (v: string) => boolean,
): void {
  for (const e of entries) {
    if (!ok(e)) {
      throw new Error(`OVID egress: ${label} entry ${JSON.stringify(e)} is not a valid cidr`);
    }
  }
}

function validateTable(name: string): void {
  if (!/^[A-Za-z_][A-Za-z0-9_]{0,28}$/.test(name)) {
    throw new Error(
      `OVID egress: table must be a plain nft identifier, got ${JSON.stringify(name)}`,
    );
  }
}

/**
 * Render the complete `nft -f` ruleset. Structure:
 *
 *   - flush-on-reload safe: `table inet <t>` + `delete table inet <t>` guard
 *     removes any previously loaded version, so every load starts clean;
 *   - interval sets blocked_v4 / blocked_v6;
 *   - chain output (filter, priority 0, policy accept) where EVERY deny rule
 *     is keyed `meta skuid <a>-<b>` — the uid key is the whole enforcement
 *     mechanism, so a ruleset line ending in `drop` without it is a bug;
 *   - optional browser section (allow-internal-then-drop, gap G2): loopback
 *     and browserAllowedV4 accepts BEFORE the same blocks keyed on the
 *     browser range. The sandbox section is byte-identical whether or not a
 *     browser section is present.
 */
/**
 * Port lists are rendered into an nft set literal, so anything that is not a
 * plain port number could inject rule text. Bounded to 1..65535, sorted and
 * de-duplicated for a deterministic ruleset.
 */
function normalizePorts(name: string, ports: number[]): number[] {
  const out = new Set<number>();
  for (const port of ports) {
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      throw new Error(`OVID egress: ${name} must contain port numbers 1-65535, got ${JSON.stringify(port)}`);
    }
    out.add(port);
  }
  if (out.size === 0) throw new Error(`OVID egress: ${name} must not be empty`);
  return [...out].sort((a, b) => a - b);
}

export function renderNftRuleset(cfg: EgressConfig): string {
  const table = cfg.table ?? DEFAULT_EGRESS_TABLE;
  validateTable(table);
  validateUidRange("uidRange", cfg.uidRange);
  validateEntries("blockedV4", cfg.blockedV4, isValidV4Cidr);
  validateEntries("blockedV6", cfg.blockedV6, isValidV6Cidr);
  if (isIP(cfg.ownPublicIp) !== 4) {
    throw new Error(
      `OVID egress: ownPublicIp must be an IPv4 address (the deny rule keys on "ip daddr"), got ${JSON.stringify(cfg.ownPublicIp)}`,
    );
  }

  const [uidA, uidB] = cfg.uidRange;
  const sk = `${uidA}-${uidB}`;

  const tcpPorts = normalizePorts("egressTcpPorts", cfg.egressTcpPorts ?? [80, 443, 53]);
  const udpPorts = normalizePorts("egressUdpPorts", cfg.egressUdpPorts ?? [53]);
  const tcpSet = `{ ${tcpPorts.join(", ")} }`;
  const udpSet = `{ ${udpPorts.join(", ")} }`;

  const chain: string[] = [
    "",
    `\t\t# sandbox uids ${sk} — internal nets and this host's public IP are blocked`,
    `\t\tmeta skuid ${sk} ip daddr @blocked_v4 counter drop`,
    `\t\tmeta skuid ${sk} ip6 daddr @blocked_v6 counter drop`,
    `\t\tmeta skuid ${sk} ip daddr ${cfg.ownPublicIp} counter drop`,
    "",
    `\t\t# sandbox uids ${sk} — outbound allow-list, then deny the remainder`,
    `\t\tmeta skuid ${sk} tcp dport ${tcpSet} counter accept`,
    `\t\tmeta skuid ${sk} udp dport ${udpSet} counter accept`,
    `\t\tmeta skuid ${sk} counter drop`,
  ];

  if (cfg.browserUidRange !== undefined) {
    validateUidRange("browserUidRange", cfg.browserUidRange);
    const [bA, bB] = cfg.browserUidRange;
    // Distinct keyspaces (gap G2): overlap would let browser rules shadow (or
    // be shadowed by) sandbox rules for the shared uids.
    if (bA <= uidB && uidA <= bB) {
      throw new Error(
        `OVID egress: browserUidRange [${bA}, ${bB}] overlaps the sandbox uidRange [${uidA}, ${uidB}] — the browser engine must use a distinct uid keyspace (P6 Task 16d)`,
      );
    }
    const bk = `${bA}-${bB}`;
    const allowed = cfg.browserAllowedV4 ?? [];
    validateEntries("browserAllowedV4", allowed, isValidV4Cidr);
    for (const cidr of allowed) {
      if (cidr.startsWith("127.")) {
        throw new Error(
          `OVID egress: browserAllowedV4 must not contain loopback (${cidr}) — 127.0.0.0/8 is always allowed for the browser range and never configurable`,
        );
      }
    }
    chain.push(
      "",
      `\t\t# browser uids ${bk} — worker-internal endpoints first, then the same blocks`,
      `\t\tmeta skuid ${bk} ip daddr 127.0.0.0/8 accept`,
      `\t\tmeta skuid ${bk} ip6 daddr ::1/128 accept`,
      ...allowed.map((cidr) => `\t\tmeta skuid ${bk} ip daddr ${cidr} accept`),
      `\t\tmeta skuid ${bk} ip daddr @blocked_v4 counter drop`,
      `\t\tmeta skuid ${bk} ip6 daddr @blocked_v6 counter drop`,
      `\t\tmeta skuid ${bk} ip daddr ${cfg.ownPublicIp} counter drop`,
      "",
      `\t\t# browser uids ${bk} — outbound allow-list, then deny the remainder`,
      `\t\tmeta skuid ${bk} tcp dport ${tcpSet} counter accept`,
      `\t\tmeta skuid ${bk} udp dport ${udpSet} counter accept`,
      `\t\tmeta skuid ${bk} counter drop`,
    );
  }

  return [
    "#!/usr/sbin/nft -f",
    "# ovid-sandbox egress filter — generated by render-nft; do not hand-edit.",
    "# Reload-safe: the declare-then-delete guard below removes any previous",
    "# version of the table, so every load starts from a clean state.",
    `table inet ${table}`,
    `delete table inet ${table}`,
    "",
    `table inet ${table} {`,
    "\tset blocked_v4 {",
    "\t\ttype ipv4_addr",
    "\t\tflags interval",
    `\t\telements = { ${cfg.blockedV4.join(", ")} }`,
    "\t}",
    "",
    "\tset blocked_v6 {",
    "\t\ttype ipv6_addr",
    "\t\tflags interval",
    `\t\telements = { ${cfg.blockedV6.join(", ")} }`,
    "\t}",
    "",
    "\tchain output {",
    "\t\ttype filter hook output priority 0; policy accept;",
    ...chain,
    "\t}",
    "}",
    "",
  ].join("\n");
}

/**
 * Parse OVID_BROWSER_EGRESS_UID: "230000" (single uid → [u, u]) or
 * "230000-230099". undefined/empty → undefined. Anything else throws, naming
 * the variable.
 */
export function parseBrowserEgressUid(v: string | undefined): [number, number] | undefined {
  if (v === undefined || v === "") return undefined;
  const m = /^(\d+)(?:-(\d+))?$/.exec(v);
  const bad = (): Error =>
    new Error(
      `OVID config: OVID_BROWSER_EGRESS_UID must be a single uid ("230000") or a range ("230000-230099") of integers >= ${UID_FLOOR}, got ${JSON.stringify(v)}`,
    );
  if (m === null) throw bad();
  const a = Number(m[1]);
  const b = m[2] === undefined ? a : Number(m[2]);
  if (a < UID_FLOOR || b < UID_FLOOR || b < a) throw bad();
  return [a, b];
}
