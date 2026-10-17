#!/usr/bin/env node
import { isIP } from "node:net";
import { pathToFileURL } from "node:url";
import {
  DEFAULT_BLOCKED_V4,
  DEFAULT_BLOCKED_V6,
  isValidV4Cidr,
  isValidV6Cidr,
  parseBrowserEgressUid,
  renderNftRuleset,
} from "./net.js";

export const RENDER_NFT_USAGE = [
  "usage: OVID_PUBLIC_IP=<ipv4> [options] render-nft > ovid-sandbox.nft",
  "",
  "  OVID_PUBLIC_IP              required — this host's public IPv4",
  "  OVID_SANDBOX_UID_BASE       default 200000 (staging/P10 renders 220000-229999)",
  "  OVID_SANDBOX_UID_MAX        default <base>+9999",
  "  OVID_SANDBOX_EXTRA_BLOCKED  csv of extra blocked cidrs (v4 or v6)",
  "  OVID_BROWSER_EGRESS_UID     browser uid or uid-uid range (set at P6 activation)",
  "  OVID_BROWSER_EGRESS_ALLOW   csv of internal-endpoint IPv4 cidrs the browser uid may reach",
].join("\n");

// Mirror config.ts's parseUidRange rules so the CLI and SandboxConfig can
// never disagree about the block (gap G4: the rules key on the CONFIGURED
// range — prod 200000-209999 and P10 staging 220000-229999 both render).
const UID_BASE_FLOOR = 100_000;
const UID_RANGE_WIDTH = 9_999;

function parseUidRange(env: NodeJS.ProcessEnv): [number, number] {
  const baseRaw = env.OVID_SANDBOX_UID_BASE;
  let uidBase = 200_000;
  if (baseRaw !== undefined && baseRaw !== "") {
    const n = Number(baseRaw);
    if (!Number.isInteger(n) || n < UID_BASE_FLOOR) {
      throw new Error(
        `OVID config: OVID_SANDBOX_UID_BASE must be an integer >= ${UID_BASE_FLOOR}, got ${JSON.stringify(baseRaw)}`,
      );
    }
    uidBase = n;
  }
  const maxRaw = env.OVID_SANDBOX_UID_MAX;
  let uidMax = uidBase + UID_RANGE_WIDTH;
  if (maxRaw !== undefined && maxRaw !== "") {
    const n = Number(maxRaw);
    if (!Number.isInteger(n)) {
      throw new Error(
        `OVID config: OVID_SANDBOX_UID_MAX must be an integer, got ${JSON.stringify(maxRaw)}`,
      );
    }
    uidMax = n;
  }
  if (uidMax <= uidBase || uidMax > uidBase + UID_RANGE_WIDTH) {
    throw new Error(
      `OVID config: OVID_SANDBOX_UID_MAX must satisfy uidBase < OVID_SANDBOX_UID_MAX <= uidBase + ${UID_RANGE_WIDTH} (uidBase=${uidBase}), got ${uidMax}`,
    );
  }
  return [uidBase, uidMax];
}

function requiredPublicIp(env: NodeJS.ProcessEnv): string {
  const v = env.OVID_PUBLIC_IP;
  if (v === undefined || v === "" || isIP(v) !== 4) {
    throw new Error(
      "OVID_PUBLIC_IP is required and must be an IPv4 address (this host's public " +
        `IP — sandbox uids must not reach it); got ${JSON.stringify(v === undefined ? "" : v)}`,
    );
  }
  return v;
}

function csvEnv(env: NodeJS.ProcessEnv, name: string): string[] {
  const v = env[name];
  if (v === undefined || v === "") return [];
  const parts = v.split(",").map((s) => s.trim());
  // Strict like config.parseDns: an empty entry is a typo, not a silent skip.
  if (parts.some((s) => s.length === 0)) {
    throw new Error(
      `OVID config: ${name} must be a comma list with no empty entries, got ${JSON.stringify(v)}`,
    );
  }
  return parts;
}

/**
 * Pure CLI core: environment → ruleset text. Throws (naming the offending
 * variable) on any config error; the bin wrapper turns that into usage on
 * stderr + exit 1. Pinned by net.test.ts; reused by the Task 15 golden
 * drift check.
 */
export function renderCli(env: NodeJS.ProcessEnv): string {
  const ownPublicIp = requiredPublicIp(env);
  const uidRange = parseUidRange(env);

  const extra = csvEnv(env, "OVID_SANDBOX_EXTRA_BLOCKED");
  const extraV4 = extra.filter((e) => !e.includes(":"));
  const extraV6 = extra.filter((e) => e.includes(":"));
  for (const e of extraV4) {
    if (!isValidV4Cidr(e)) {
      throw new Error(
        `OVID config: OVID_SANDBOX_EXTRA_BLOCKED entry ${JSON.stringify(e)} is not a valid IPv4 cidr`,
      );
    }
  }
  for (const e of extraV6) {
    if (!isValidV6Cidr(e)) {
      throw new Error(
        `OVID config: OVID_SANDBOX_EXTRA_BLOCKED entry ${JSON.stringify(e)} is not a valid IPv6 cidr`,
      );
    }
  }

  const browserUidRange = parseBrowserEgressUid(env.OVID_BROWSER_EGRESS_UID);
  const browserAllowedV4 = csvEnv(env, "OVID_BROWSER_EGRESS_ALLOW");
  for (const c of browserAllowedV4) {
    if (!isValidV4Cidr(c)) {
      throw new Error(
        `OVID config: OVID_BROWSER_EGRESS_ALLOW entry ${JSON.stringify(c)} is not a valid IPv4 cidr`,
      );
    }
  }

  // Overlap validation (and everything else structural) happens in
  // renderNftRuleset — it throws naming both ranges.
  return renderNftRuleset({
    uidRange,
    blockedV4: [...DEFAULT_BLOCKED_V4, ...extraV4],
    blockedV6: [...DEFAULT_BLOCKED_V6, ...extraV6],
    ownPublicIp,
    browserUidRange,
    browserAllowedV4: browserAllowedV4.length > 0 ? browserAllowedV4 : undefined,
  });
}

function main(): void {
  if (process.argv[2] === "-h" || process.argv[2] === "--help") {
    process.stdout.write(`${RENDER_NFT_USAGE}\n`);
    return;
  }
  try {
    process.stdout.write(renderCli(process.env));
  } catch (e) {
    process.stderr.write(
      `render-nft: ${e instanceof Error ? e.message : String(e)}\n\n${RENDER_NFT_USAGE}\n`,
    );
    process.exit(1);
  }
}

// Run only when executed as the bin (`node dist/renderNftCli.js` / the
// `render-nft` symlink) — importing this module for renderCli must be inert.
const invoked =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;
if (invoked) main();
