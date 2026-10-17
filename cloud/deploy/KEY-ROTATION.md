# Ovid Cloud — escrow master-key rotation

`OVID_MASTER_KEY` (64 hex chars = 32 bytes) is the KEK for every `byok_keys`
envelope (`cloud/packages/escrow`). Each row carries a per-record DEK wrapped
under the master key; the row id (`byok_keys:{id}`) is the GCM AAD on both
layers. Rotating the master key therefore means: **unwrap every row with the
old key, re-wrap with the new key, keep the row id (and therefore the AAD)
unchanged**.

The CLI lives in the escrow package so `pnpm -r build` compiles it:

```sh
cloud/packages/escrow/dist/rotateMasterKey.js   # bin: rotate-master-key
```

It reads both keys from **named environment variables** (never argv — process
lists are world-readable) and never prints key material or plaintext.

## Scope (v1) — read this before rotating production

The CLI rotates **`byok_keys` only** — the P9 BYOK escrow surface.

The same `OVID_MASTER_KEY` is also used by:

| Surface | Storage | Rotation support |
| --- | --- | --- |
| BYOK provider keys | `byok_keys.{wrapped_dek,iv,ciphertext,tag}` | **this CLI** |
| MCP servers / OAuth tokens / plugins | `mcp_servers`, `mcp_oauth_tokens`, `mcp_oauth_flows`, `plugins` sealed columns | **none yet** |
| Worker browser login state | files under `OVID_BROWSER_STATE_DIR` | **none yet** |

Consequence: a production rotation invalidates those rows/files (they will
fail closed on decrypt — never leak, but the affected user must re-add the MCP
server/plugin or log in again). **Before the first production rotation either
(a) extend this CLI to the sealed-column tables and the browser-state files,
or (b) accept and announce the re-enrolment requirement.** The owner decision
is tracked with spec R4 below.

## Preconditions

- Maintenance window (gateway + worker restart).
- A verified Postgres backup of the `byok_keys` table (see
  `cloud/deploy/backup/README.md`).
- The **old** key is the value currently deployed; the **new** key is
  `openssl rand -hex 32` (exactly 64 hex chars).
- `DATABASE_URL` for the target environment (staging: `:15432`, prod:
  loopback `:5433`). Keep the URL out of shell history where possible
  (`read -rs`).

```sh
export OVID_MASTER_KEY_OLD='<current 64-hex value>'
export OVID_MASTER_KEY_NEW="$(openssl rand -hex 32)"
```

## Procedure

### 1. Dry run (validates, writes nothing)

```sh
node cloud/packages/escrow/dist/rotateMasterKey.js \
  --database-url "$DATABASE_URL" \
  --old-key-env OVID_MASTER_KEY_OLD \
  --new-key-env OVID_MASTER_KEY_NEW \
  --dry-run
```

Expected:

```text
rotate-master-key: rows=3 mode=dry-run
rotate-master-key: row <id>: old key ok
...
rotate-master-key: OK — validated 3 row(s) with the old key; no writes (--dry-run)
```

Exit code 0 and **`rows=N` equal to the table count**. Exit 1 means at least
one row did not authenticate with the old key; the table is untouched. Do not
continue — investigate the row ids reported (a row sealed under a different
key indicates a prior partial deployment).

### 2. Rotate

```sh
node cloud/packages/escrow/dist/rotateMasterKey.js \
  --database-url "$DATABASE_URL" \
  --old-key-env OVID_MASTER_KEY_OLD \
  --new-key-env OVID_MASTER_KEY_NEW
```

Expected: `rotated N/N row(s)` and exit 0. Validation runs over every row
before the first write; each row is then updated in its own transaction. A
write failure stops the run and names the row — the remaining rows still carry
the old envelope, so the table is mixed until the run is resumed or rolled
back.

### 3. Point the services at the new key

Update `OVID_MASTER_KEY` in the deployment `.env` (staging:
`cloud/deploy/.env.staging`; production: `/opt/ovid-gateway/.env`), then
restart **gateway and worker together**:

```sh
# staging
cloud/scripts/staging.sh down && cloud/scripts/staging.sh up
cloud/scripts/staging.sh worker-start

# production (owner-present)
docker compose -f /opt/ovid-gateway/docker-compose.yml up -d gateway worker
```

Never leave one process on the old key while another holds the new one: reads
fail closed, but runs/requests will fail until both agree.

### 4. Verify the decrypt round-trip

Probe one BYOK key through the gateway (decrypts under the new key):

```sh
curl -fsS -X POST "$GATEWAY/cloud/v1/byok/<id>/test" \
  -H "Authorization: Bearer <id-token>" \
  -H "X-Firebase-AppCheck: <app-check-token>"
```

A `200` with `lastTestOk`-style success (or a provider-side probe result)
proves the envelope opened. A `500 BYOK key could not be decrypted` means the
process is still on the old key or step 2 did not cover the row.

### 5. Remove the old key

Once step 4 passes, delete `OVID_MASTER_KEY_OLD` from the environment and
unset the shell variables. The old key no longer opens any row.

## Rollback

The rotation is reversible because the CLI is symmetric. **Before reverting
`.env`**, re-run the CLI with the key roles swapped:

```sh
export OVID_MASTER_KEY_OLD="$(cat <<'EOF'
<the NEW key value>
EOF
)"
export OVID_MASTER_KEY_NEW='<the previous key value>'

node cloud/packages/escrow/dist/rotateMasterKey.js \
  --database-url "$DATABASE_URL" \
  --old-key-env OVID_MASTER_KEY_OLD \
  --new-key-env OVID_MASTER_KEY_NEW
```

Then restore the previous `OVID_MASTER_KEY` in `.env` and restart gateway +
worker. Re-run step 4. If a write failure left the table mixed, run the
rollback for the already-rotated rows and the forward command for the rest
(the CLI reports per-row status in both directions).

## Drill evidence (local, disposable Postgres)

Run 2026-10-17 against `ovid_rotate_drill` on the dev Postgres (`:5433`),
3 seeded canary rows:

```text
rotate-master-key: rows=3 mode=dry-run
rotate-master-key: row 0459ea8e-…: old key ok
rotate-master-key: row 0af559b4-…: old key ok
rotate-master-key: row cd02f8d8-…: old key ok
rotate-master-key: OK — validated 3 row(s) with the old key; no writes (--dry-run)

rotate-master-key: rows=3 mode=rotate
rotate-master-key: row 0459ea8e-…: rotated
rotate-master-key: row 0af559b4-…: rotated
rotate-master-key: row cd02f8d8-…: rotated
rotate-master-key: OK — rotated 3/3 row(s)

verify: 3 row(s) round-trip under the new key; 3 row(s) rejected under the old key
```

The staging run is deferred to Task 14 acceptance (the staging mint image
`cloud/deploy/Dockerfile.mint` is owned by P9-T18 and does not exist yet).

## Spec R4 — accepted v1 risk

> R4. Escrow master key co-located with data — accepted v1 risk; documented
> for future KMS.

The KEK lives in the same `.env` / host as the ciphertext and the database.
This rotation procedure limits the blast radius of a leaked key (rotate
without re-entering provider secrets) but does **not** protect against a host
compromise. Moving the KEK to a KMS (envelope encryption with a KMS-held root
key) remains the follow-up; this CLI's interface (old key in, new key out)
maps directly onto a KMS `ReEncrypt` call when that work lands.
