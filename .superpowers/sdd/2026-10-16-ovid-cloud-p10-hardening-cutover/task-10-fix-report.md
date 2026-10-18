# Task 10 fix report — Security suite III review findings

**Branch:** `feat/ovid-cloud`
**Reviewed task:** `.superpowers/sdd/2026-10-16-ovid-cloud-p10-hardening-cutover/task-10-review.md`
**Original report:** `task-10-report.md`
**Scope:** the two HIGHs and two MEDIUMs the review left unfixed. The LOWs
(wrong-key route-composition gap, rotation lost-update window, drill-report
location, unpinned `pip-audit`) are unchanged and still open.

## Verdict

All four requested findings are fixed and pinned by tests. The canary sweep now
runs the shipped gateway/worker composition with canaries in its real
configuration, asserts the workload actually executed, and scans the DB/Redis
rows it produced. The at-rest pin enumerates the live schema instead of a
hard-coded column list. The rotation CLI reports a MIXED table after a partial
write. A requested-but-missing corpus is now a strict-mode failure.

## Findings

| # | Severity | State |
| --- | --- | --- |
| HIGH 1 | Canary sweep never injected canaries into the processes handling secrets | **Fixed** — `--in-process-stack` mode + dedicated e2e stack test |
| HIGH 2 | At-rest pin hard-coded 12 of 13 `byok_keys` columns | **Fixed** — `information_schema` enumeration + dynamic projection |
| MEDIUM | Rotation CLI says "table unchanged" after a partial failure | **Fixed** — mixed-state report + mid-run failure test |
| MEDIUM | Missing corpora silently skipped | **Fixed** — `missing` tracking, `--strict`, in-process mode always strict |

---

## HIGH 1 — canaries now reach the shipped code

### What was open

`runCanarySweep` injected `OVID_CANARY_BYOK_KEY`, `OVID_CANARY_MINT_KEY`,
`REDIS_PASSWORD`, and `OVID_CANARY_DB_PASSWORD` — variables no shipped code
read. The wrapped workload was the e2e test process or the load client, whose
gateways used hard-coded keys, so "PASS — zero leaks" only proved that the
wrapped process did not dump its own environment.

### Fix

`cloud/apps/load/src/canaryCli.ts` gained `--in-process-stack` (requires
`--database-url` and `--redis-url` as ADMIN URLs for disposable services). It:

1. **Provisions isolated services whose credentials ARE the canaries.**
   - Creates a dedicated Postgres role + database:
     `CREATE ROLE "ovid_canary_<id>" LOGIN PASSWORD '<canary db password>'`,
     then `CREATE DATABASE "ovid_canary_<id>" OWNER …`.
   - Creates a dedicated Redis ACL user:
     `ACL SETUSER ovid_canary_<id> reset on ><canary redis password> ~* &* +@all`,
     and selects a per-run DB index (1–15).
   - Builds `DATABASE_URL` and `REDIS_Q_URL` with those canary passwords.
2. **Sets the canaries under the REAL config names** in the child's
   `process.env`:
   - `OVID_MASTER_KEY` — a 64-hex canary (`c0de` + 60 hex), because the shipped
     validator requires exactly 32 bytes;
   - `OVID_INTERNAL_API_SECRET` — the mint HMAC secret;
   - `LITELLM_MASTER_KEY` and `OVID_LITELLM_MASTER_KEY` — the model key;
   - `DATABASE_URL` / `REDIS_Q_URL` — canary passwords;
   - `OVID_CANARY_BYOK_KEY` — the plaintext uploaded through `POST /byok`
     (a test input, not a service config name; the service reads it from the
     request body).
   `CANARY_ENV` (`canarySweep.ts`) now maps each role to the real variable
   names; roles with no standalone variable (`byokKey`, `redisPassword`,
   `dbPassword`) map to an empty list instead of inventing a name. The old
   `OVID_CANARY_BYOK_KEY` / `OVID_CANARY_MINT_KEY` / `REDIS_PASSWORD` /
   `OVID_CANARY_DB_PASSWORD` injection is gone from the generic sweep.
3. **Runs a dedicated e2e stack test** (`cloud/apps/e2e/src/security/canary-stack.test.ts`,
   enabled only by `OVID_CANARY_STACK=1`) that builds the shipped composition:
   - `buildGateway(...)` with real Postgres, real Redis event log / system bus /
     ticket store / queues, `createTestVerifier()`, and
     `createEnvelopeCrypto(OVID_MASTER_KEY)`;
   - `createAgentRunProcessor(...)` + `createAgentRunsWorker(...)` with the
     shipped `createServerKeyResolver(...)`, `createByokKeyProvider(...)`, and
     `createOpenAiTransport()`;
   - `createInternalMintProvisioner(..., OVID_INTERNAL_API_SECRET)` against a
     local mint mock that **verifies the HMAC** with the same canary secret;
   - a local SSE mock for the model boundary.
4. **Drives real traffic:** `POST /cloud/v1/sessions` → `POST /auth/ticket` →
   WS subscribe → `POST /sessions/:id/messages` → consume the stream to
   `run_completed`; then `POST /cloud/v1/byok` with the canary plaintext and a
   real provider decrypt round-trip.
5. **Proves the workload was not empty.** The test writes a proof JSON
   (`sessionId`, `uid`, `runId`, `byokId`, `terminalEvent`, counts). The CLI
   independently queries the isolated DB and Redis:
   - `runs.id = proof.runId` exists with `status = 'completed'`;
   - `byok_keys.id = proof.byokId` exists;
   - `session_event_mirror` has rows for the session;
   - `sess:<sessionId>:events` exists.
   A missing proof or any failed check exits non-zero; a skipped test cannot
   produce a green sweep.
6. **Scans** stdout/stderr captures, `session_event_mirror`, `byok_keys`
   (`SELECT *`), raw `sess:*:events` XRANGE payloads, and any `--log` files.
7. **Cleans up** with key-scoped deletes (`sess:<id>:*`, `user:<uid>:key`, the
   unique queue prefix), `ACL DELUSER`, and `DROP DATABASE … WITH (FORCE)` /
   `DROP ROLE`. It never runs `FLUSHDB` and never touches the live
   `ovid-gateway-*` containers.

### Test that pins it

- `cloud/apps/load/src/canarySweep.test.ts` →
  `in-process stack mode drives the shipped gateway/worker with canary config`
  (gated on `TEST_DATABASE_URL` + `TEST_REDIS_URL`) calls `runCanaryCli` with
  `--in-process-stack`, asserts exit 0, the child stack test ran, and the proof
  records a completed run, a BYOK id, and mirror rows.
- `cloud/apps/e2e/src/security/canary-stack.test.ts` asserts the terminal
  event, completed run row, BYOK row, provider decrypt, mirror rows, and that
  the mint mock received at least one HMAC-verified request.
- `canarySweep.test.ts` also asserts the real env mapping:
  `OVID_MASTER_KEY`/`OVID_INTERNAL_API_SECRET`/`LITELLM_MASTER_KEY`/
  `OVID_LITELLM_MASTER_KEY` are set to the canaries, the master key is 64 hex,
  and no invented `OVID_CANARY_*`/`REDIS_PASSWORD` variables are injected.

### Actual sweep output (in-process stack, real isolated services)

```
$ node apps/load/dist/canaryCli.js --in-process-stack \
    --captures-dir /tmp/ovid-canary-fix \
    --database-url postgres://postgres:ovid@127.0.0.1:5433/postgres \
    --redis-url redis://127.0.0.1:6390
canary-sweep: in-process stack: database=ovid_canary_215fca8501 redis-db=9
canary-sweep: injecting 6 canaries (masterKey, byokKey, mintKey, redisPassword, dbPassword, litellmKey)
canary-sweep: DATABASE_URL/REDIS_Q_URL carry canary passwords; OVID_MASTER_KEY/OVID_INTERNAL_API_SECRET/LITELLM_MASTER_KEY are canaries
canary-sweep: workload: shipped gateway + worker stack (e2e canary-stack test)

 RUN  v2.1.9 /root/OvidAI/cloud/apps/e2e

 ✓ src/security/canary-stack.test.ts (1 test) 570ms

 Test Files  1 passed (1)
      Tests  1 passed (1)

canary-sweep: proof: run=01a14d45-a89c-7a1e-9101-0679b83ad963 terminal=run_completed byok=01a14d45-a8d6-7ed2-afab-803002256a70 mirror=6 streams=1
canary-sweep: scanned 5 corpus location(s)
canary-sweep: workload exit=0
canary-sweep: PASS — zero leaks
exit=0
```

Post-run verification: `pg_database`/`pg_roles` have no `ovid_canary_%` rows,
`ACL USERS` is back to `default`, and no `sess:<id>:*` or `*ovid-canary-*` keys
remain in the selected Redis DB.

---

## HIGH 2 — at-rest pin enumerates the live schema

### What was open

`secrets-at-rest.test.ts` selected 12 hard-coded columns; `byok_keys` has 13
(`user_id` was omitted). A future column would silently escape the pin.

### Fix

`cloud/apps/e2e/src/security/secrets-at-rest.test.ts` now:

- reads `column_name, data_type` from `information_schema.columns` for
  `byok_keys` (schema `current_schema()`, ordered by `ordinal_position`);
- builds the projection dynamically, quoting each identifier:
  - `bytea`: `coalesce(encode("col", 'escape'), '')`
  - everything else: `coalesce(encode(convert_to("col"::text, 'UTF8'), 'escape'), '')`
- executes it with `db.$client.unsafe(sql, [id])`.

A column added later is included automatically; nothing is hand-maintained.

### Test that pins it

- New test `enumerates every byok_keys column from information_schema (user_id included)`:
  asserts `user_id` is present, no duplicate names, and the enumerated count
  equals the `information_schema` count.
- `escrowed key is ciphertext at the byte level` now asserts
  `Object.keys(row)` equals the enumerated schema columns, so a column that
  escaped the projection fails the test.

### Gate output

```
$ TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres \
    pnpm --filter @ovid/e2e exec vitest run src/security/secrets-at-rest.test.ts

 RUN  v2.1.9 /root/OvidAI/cloud/apps/e2e

 ✓ src/security/secrets-at-rest.test.ts (4 tests) 207ms

 Test Files  1 passed (1)
      Tests  4 passed (4)
exit=0
```

---

## MEDIUM — rotation CLI reports the real state after a partial failure

### What was open

`runRotateMasterKeyCli` printed `"FAIL — N row(s) not rotated; table
unchanged"` even when `rotated > 0`, contradicting `KEY-ROTATION.md`.

### Fix

`cloud/packages/escrow/src/rotateMasterKey.ts` adds
`rotationFailureState(result)`, used by the CLI:

- `rotated === 0`:
  `FAIL — 0/N row(s) rotated; table unchanged (no row was written)` plus
  guidance to fix the reported row(s) and re-run.
- `rotated > 0`:
  `FAIL — rotated X/N row(s); R row(s) still under the old key; table is MIXED`
  plus: `Old-key rows are still readable with the OLD key; rotated rows only
  with the NEW key. Resume the rotation with the same old/new keys or roll
  back.`

`runRotateMasterKeyCli` also accepts an injected rotation function (default:
the real one) so the CLI output path is directly testable.

### Tests that pin it

`cloud/packages/escrow/src/rotateMasterKey.test.ts`:

- `reports a MIXED table after a mid-run write failure (never 'unchanged')` —
  seeds 3 rows and injects a failure on the second per-row transaction. Asserts
  `total=3`, `rotated=1`, one failure, exactly one row decrypts with the new
  key and two with the old key, and `rotationFailureState` reports
  `mixed=true`, `remaining=2`, `"table is MIXED"`, `"1/3"`.
- `CLI prints the mixed state and counts after a partial failure` — injects a
  partial result and asserts the CLI exits 1, prints the failed row, `1/3`,
  `table is MIXED`, and does **not** print `table unchanged`.

### Gate output

```
$ TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres \
    pnpm --filter @ovid/escrow test

 ✓ src/envelope.test.ts (10 tests)
 ✓ src/endpoints.test.ts (21 tests)
 ✓ src/address.test.ts (31 tests)
 ✓ src/provider.test.ts (5 tests)
 ✓ src/rotateMasterKey.test.ts (6 tests)

 Test Files  5 passed (5)
      Tests  73 passed (73)
exit=0
```

The LOW lost-update window (no `WHERE wrapped_dek = <validated>` guard) is
unchanged; it is out of this fix's scope.

---

## MEDIUM — missing corpora are a strict-mode failure

### What was open

A requested `--log` that did not exist (or an unreadable DB/Redis corpus) was
silently dropped; the sweep still printed `PASS — zero leaks` after scanning
only the captures.

### Fix

`cloud/apps/load/src/canarySweep.ts`:

- `CanarySweepResult.missing` lists every requested location that could not be
  read (`capture:…`, `log:…`, or a corpus `where`).
- `CanarySweepOptions.strict` throws `CanaryCorpusMissingError` after the scan
  when anything is missing.
- `runCanaryCli` gained `--strict`. Non-strict prints `MISSING …` plus a
  `WARN`; strict exits 1. Strict also fails when `scanned === 0`.
- The in-process stack mode always fails on a missing corpus and requires the
  DB/Redis/byok corpora (so a PASS cannot describe a scan that never looked at
  them).

### Tests that pin it

- `strict mode fails when a requested log corpus is missing` — non-strict
  returns `missing: ["log:…"]`; strict rejects with
  `CanaryCorpusMissingError`.
- The in-process integration test asserts `scanned = 5` (2 captures +
  `session_event_mirror` + `byok_keys` + raw Redis streams).

### Actual strict-mode output

```
$ node apps/load/dist/canaryCli.js --captures-dir /tmp/ovid-canary-strict \
    --strict --log /tmp/ovid-canary-strict/DOES-NOT-EXIST.log \
    -- node -e "process.stdout.write('workload ok\n')"
canary-sweep: injecting 6 canaries (masterKey, byokKey, mintKey, redisPassword, dbPassword, litellmKey)
canary-sweep: workload: node -e process.stdout.write('workload ok\n')
workload ok
canary-sweep: scanned 2 corpus location(s)
canary-sweep: workload exit=0
canary-sweep: MISSING log:/tmp/ovid-canary-strict/DOES-NOT-EXIST.log
canary-sweep: FAIL — 1 requested corpus location(s) missing
exit=1
```

---

## Gates (exact)

```
### pnpm --filter @ovid/load build
$ tsc -p tsconfig.json
exit=0

### pnpm exec tsc -p tsconfig.check.json --noEmit (apps/load)
exit=0
```

```
### TEST_DATABASE_URL=… pnpm --filter @ovid/escrow test
✓ src/envelope.test.ts (10 tests)
✓ src/endpoints.test.ts (21 tests)
✓ src/address.test.ts (31 tests)
✓ src/provider.test.ts (5 tests)
✓ src/rotateMasterKey.test.ts (6 tests)
Test Files  5 passed (5)
     Tests  73 passed (73)
exit=0

### pnpm exec tsc -p tsconfig.check.json --noEmit (packages/escrow)
exit=0
```

```
### TEST_DATABASE_URL=… pnpm --filter @ovid/e2e exec vitest run src/security/secrets-at-rest.test.ts
✓ src/security/secrets-at-rest.test.ts (4 tests)
Test Files  1 passed (1)
     Tests  4 passed (4)
exit=0

### pnpm exec tsc -p tsconfig.check.json --noEmit (apps/e2e)
exit=0
```

```
### TEST_DATABASE_URL=… TEST_REDIS_URL=… pnpm --filter @ovid/load exec vitest run src/canarySweep.test.ts
✓ src/canarySweep.test.ts (6 tests)
   ✓ in-process stack mode drives the shipped gateway/worker with canary config
Test Files  1 passed (1)
     Tests  6 passed (6)
exit=0
```

The in-process test output includes:

```
canary-sweep: proof: run=… terminal=run_completed byok=… mirror=6 streams=1
canary-sweep: scanned 5 corpus location(s)
canary-sweep: workload exit=0
canary-sweep: PASS — zero leaks
```

---

## Coverage — what the sweep now does and does not reach

**Reached by `--in-process-stack`:**

- The **gateway**: real `buildGateway` composition, authenticated REST
  (`POST /cloud/v1/sessions`, `POST /auth/ticket`, `POST /sessions/:id/messages`,
  `POST /cloud/v1/byok`), and the WebSocket stream through `run_completed`.
- The **worker**: real `createAgentRunProcessor` + `createAgentRunsWorker` +
  BullMQ queue; real `session_event_mirror` writes and raw
  `sess:*:events` XRANGE.
- **BYOK escrow**: encryption through the real route under
  `OVID_MASTER_KEY`, and decryption through the real
  `createByokKeyProvider`.
- **Mint boundary**: real `createInternalMintProvisioner` signs with
  `OVID_INTERNAL_API_SECRET`; the local mock verifies the HMAC.
- **DB/Redis credentials**: the Postgres role and Redis ACL user authenticate
  only with the canary passwords, so the canaries are genuinely in the
  connection configuration.
- **Model key**: `LITELLM_MASTER_KEY` is the key the shipped resolver returns
  to the real transport (the local SSE mock ignores its value).
- **Corpora**: stdout/stderr captures, `session_event_mirror`, `byok_keys`
  (`SELECT *`), raw Redis streams, and requested `--log` files.

**NOT reached (honest limits):**

- **Sandboxed tool execution** — this host has no bwrap/rootfs, so the stack
  test uses the documented tool-less v0 processor shape (the same shape
  `spine.test.ts` uses). The sandboxed-tool path is **not** covered by this
  sweep.
- **Real mint service / real LiteLLM** — both boundaries are local mocks. The
  mint mock does verify the real HMAC; the LiteLLM mock speaks the real SSE
  dialect but does not validate the key.
- **MCP/plugin sealed columns and worker browser-state files** — same
  `OVID_MASTER_KEY`, but not exercised here (rotation scope remains
  `byok_keys`).
- **Staging / live containers** — no staging run is claimed. The in-process
  mode must be pointed at disposable admin URLs; it creates and drops its own
  database and ACL user.
- **Generic (non-stack) mode** — it still injects the real standalone config
  names for the master/mint/LiteLLM roles, but it cannot inject the DB/Redis
  password or BYOK roles into an arbitrary workload. A generic PASS must not
  be read as coverage of the DB/Redis/BYOK paths; only `--in-process-stack`
  does that.
- **The rotation CLI** is not part of the sweep; it has its own real-Postgres
  tests.

---

## CI coverage check

`.github/workflows/cloud.yml` **does not invoke the canary sweep**. A
repo-wide search finds `canary` only in `cloud/deploy/RUNBOOKS.md` (a
description of the gates) and `cloud/deploy/KEY-ROTATION.md` (drill rows). The
sweep remains a manual/operator CLI (and Task 14's staging step); CI does not
run it. This report does not claim CI coverage.

---

## Files changed

- `cloud/apps/load/src/canarySweep.ts` — real-name mapping, 64-hex master-key
  canary, `litellmKey` role, `missing`/strict, `byokKeysCorpus`.
- `cloud/apps/load/src/canaryCli.ts` — `--in-process-stack`, `--strict`,
  isolated Postgres role/DB + Redis ACL provisioning, proof verification,
  key-scoped cleanup, byok corpus.
- `cloud/apps/load/src/canarySweep.test.ts` — env-mapping, strict-missing, and
  in-process integration tests.
- `cloud/apps/e2e/src/security/secrets-at-rest.test.ts` — dynamic schema
  enumeration and projection.
- `cloud/apps/e2e/src/security/canary-stack.test.ts` (new) — the shipped
  gateway/worker composition under canary config.
- `cloud/packages/escrow/src/rotateMasterKey.ts` — `rotationFailureState` and
  mixed-state CLI output.
- `cloud/packages/escrow/src/rotateMasterKey.test.ts` — mid-run failure and
  CLI-output tests.
