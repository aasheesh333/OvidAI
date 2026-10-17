#!/usr/bin/env node
/**
 * verify-r2.mjs — owner-run, least-privilege Cloudflare R2 smoke probe.
 *
 * P7 Task 14. Runs ONLY when the owner supplies the OVID_R2_* environment
 * (never in CI — there are no credentials there). It loads the SAME config
 * loader and adapter the gateway/worker boot through, so a green run proves
 * the deploy env, the endpoint, the token scope and the bucket agree.
 *
 * Checks, one `[ok]`/`[FAIL]` line each:
 *   1. config   — loadR2Config(process.env) (missing var → names it, exits 1)
 *   2. put      — 1 KiB probe at users/_probe/<uuidv7>.txt
 *   3. head     — byte count + caller metadata + sha256 round-trip
 *   4. get      — getBuffer byte-compare against the probe
 *   5. presign  — presignGet(60) → global fetch → 200 + identical bytes
 *   6. delete   — idempotent delete
 *   7. gone     — head() is null
 *
 * Least privilege: this exercises ONLY object put/get/head/presign/delete on
 * the bucket. No list, no account-admin, no CORS. The probe is deleted on
 * every path (best effort in `finally`); it is never left behind.
 *
 * Output masking: only the account id's first 8 characters and the bucket
 * name are ever printed. The access key, secret, presigned URL and object
 * bodies are never logged (SDK messages are scrubbed too).
 *
 * Usage (from the repo root — the directory containing `cloud/`):
 *   set -a; . /opt/ovid-cloud/.env; set +a   # or export the OVID_R2_* vars
 *   node cloud/scripts/verify-r2.mjs
 * Exit codes: 0 = every check green; 1 = any FAIL (or missing config).
 *
 * The import is a RELATIVE path to the built package so the probe works from
 * a bare deployed checkout (no pnpm workspace-root @ovid symlinks needed).
 * Build first if dist is absent: `pnpm --filter @ovid/storage build`.
 */

import { createHash, randomBytes } from "node:crypto";

import {
  createR2Storage,
  loadR2Config,
} from "../packages/storage/dist/index.js";

const PROBE_BYTES = 1024;
const PRESIGN_TTL_SECONDS = 60;

/** @type {{ accessKeyId?: string; secretAccessKey?: string } | null} */
let loadedConfig = null;
let failures = 0;

/** RFC 9562 UUIDv7 (48-bit ms timestamp + random) — no dependency needed. */
function uuidv7() {
  const bytes = randomBytes(16);
  let ts = BigInt(Date.now());
  for (let i = 5; i >= 0; i -= 1) {
    bytes[i] = Number(ts & 0xffn);
    ts >>= 8n;
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x70; // version 7
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** Never let an SDK error echo a credential. */
function scrub(text) {
  let out = String(text);
  for (const secret of [loadedConfig?.accessKeyId, loadedConfig?.secretAccessKey]) {
    if (typeof secret === "string" && secret !== "") {
      out = out.split(secret).join("[redacted]");
    }
  }
  return out;
}

function errorText(err) {
  return scrub(err instanceof Error ? err.message : err);
}

function ok(label, detail) {
  console.log(`[ok]   ${label}${detail ? ` — ${detail}` : ""}`);
}

function fail(label, err) {
  failures += 1;
  console.error(`[FAIL] ${label} — ${errorText(err)}`);
}

function maskAccount(accountId) {
  return `${accountId.slice(0, 8)}…`;
}

async function main() {
  let cfg;
  try {
    cfg = loadR2Config(process.env);
  } catch (err) {
    // Missing/incomplete config: names the variable, prints no values.
    fail("config", err);
    return;
  }
  loadedConfig = cfg;
  ok("config", `account ${maskAccount(cfg.accountId)} bucket ${cfg.bucket}`);

  // maxAttempts 2 keeps a misconfigured token from retrying for minutes.
  const adapter = createR2Storage(cfg, { maxAttempts: 2 });
  const key = `users/_probe/${uuidv7()}.txt`;

  // Deterministic 1 KiB body (bytes 0..250 repeating).
  const body = Buffer.alloc(PROBE_BYTES);
  for (let i = 0; i < PROBE_BYTES; i += 1) body[i] = i % 251;
  const sha256Hex = createHash("sha256").update(body).digest("hex");

  let putSucceeded = false;
  try {
    // ---- put -------------------------------------------------------------
    let put;
    try {
      put = await adapter.put(key, body, {
        contentType: "text/plain",
        sha256Hex,
        metadata: { probe: "verify-r2" },
      });
      putSucceeded = true;
    } catch (err) {
      fail("put", err);
      return; // nothing downstream can be meaningful
    }
    if (put.bytes !== PROBE_BYTES) {
      fail("put", `adapter reported ${put.bytes} bytes (expected ${PROBE_BYTES})`);
      return;
    }
    ok("put", `${put.bytes} bytes at ${key}`);

    // ---- head ------------------------------------------------------------
    const head = await adapter.head(key);
    if (head === null) {
      fail("head", "object missing immediately after put");
      return;
    }
    if (head.bytes !== PROBE_BYTES) {
      fail("head", `ContentLength ${head.bytes} (expected ${PROBE_BYTES})`);
    } else if (head.sha256Hex !== sha256Hex) {
      fail("head", "Metadata.sha256 does not match the probe digest");
    } else if (head.metadata?.probe !== "verify-r2") {
      fail("head", "caller metadata {probe: verify-r2} did not round-trip");
    } else {
      ok("head", `${head.bytes} bytes, sha256 + metadata verified`);
    }

    // ---- getBuffer -------------------------------------------------------
    const fetched = await adapter.getBuffer(key);
    if (fetched === null) {
      fail("get", "getBuffer returned null");
    } else if (!fetched.equals(body)) {
      fail("get", `byte mismatch (${fetched.length} bytes returned)`);
    } else {
      ok("get", `${fetched.length} bytes byte-identical`);
    }

    // ---- presignGet + fetch ---------------------------------------------
    // The URL embeds a signature: fetch it, never print it.
    const url = await adapter.presignGet(key, PRESIGN_TTL_SECONDS);
    const response = await fetch(url);
    const viaPresign = Buffer.from(await response.arrayBuffer());
    if (response.status !== 200) {
      fail("presign", `presigned GET returned HTTP ${response.status}`);
    } else if (!viaPresign.equals(body)) {
      fail("presign", `presigned GET bytes differ (${viaPresign.length} bytes)`);
    } else {
      ok("presign", `HTTP 200, ${viaPresign.length} bytes byte-identical (ttl ${PRESIGN_TTL_SECONDS}s)`);
    }

    // ---- delete ----------------------------------------------------------
    await adapter.delete(key);
    ok("delete", "probe object deleted");

    // ---- gone ------------------------------------------------------------
    const afterDelete = await adapter.head(key);
    if (afterDelete !== null) {
      fail("gone", "head() still returns the object after delete");
    } else {
      ok("gone", "head() returns null");
    }
  } catch (err) {
    fail("probe", err);
  } finally {
    // Best-effort cleanup for any early exit (delete is idempotent).
    if (putSucceeded) {
      try {
        await adapter.delete(key);
      } catch {
        // The explicit delete check above already reported the failure.
      }
    }
  }
}

await main();

console.log(
  "note: least privilege — this probe exercises object put/get/head/presign/delete " +
    "on the bucket only; no list or account-admin permission is required.",
);

process.exitCode = failures === 0 ? 0 : 1;
