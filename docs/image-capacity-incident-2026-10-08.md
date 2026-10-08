# Image admission incident — 2026-10-08

## Cause and scope

Request `wp_8k_cosmic_20261008` reached the image gateway. At
07:31:35 UTC, LiteLLM call `6669af13-7a6a-4235-b4b7-b450f3a2b43b`
returned HTTP 503 with the upstream's explicit `no_capacity` error: no provider
available, offers exhausted or in cooldown. No model fallback was attempted.
The gateway classified it as an uncertain result and saved `unknown`; the
client's durable admission journal then blocked new identities.

## Changes

- Gateway recognizes explicit HTTP 503 `no_capacity` and its exact model-bound
  LiteLLM message wrapper. It tries the next dashboard-configured image model
  under the same admission. Exhausted explicit rejections produce a terminal
  failed receipt with zero charge.
- Timeouts, generic 5xx, malformed failures and model-mismatched messages stay
  uncertain. Existing idempotency and reservation rules remain enforced.
- Flutter admission failures distinguish storage, availability, account,
  conflicting identity and unresolved receipt conditions. Pending errors name
  the saved request to check. Resolved failures explain that a new job is allowed.

## Verification and deployment

- Server image suite: 55 tests and 44 subtests passed.
- Flutter image suites: 80 tests passed; an additional direct POST-503/receipt
  regression was added and the six-test admission suite then passed.
- Targeted Flutter analysis and `git diff --check` passed.
- Independent review found no new critical financial/idempotency issue and
  highlighted the separate historical-receipt reconciliation requirement.
- Six gateway tests also ran inside the built image, with networking disabled
  and a temporary ledger, before deployment.
- Live gateway code SHA-256:
  `f35063940e2abf8aa4758039752155d41d84f4997f40d515c672b61dbb4e00f5`.
- Mint was recreated with a 180-second graceful shutdown allowance; startup
  mounted all three configured image models. Public `/healthz` returned 200.
- Previous image retained as `ovid-gateway-mint:pre-image-capacity-20261008`.
  Roll back by tagging it as `ovid-gateway-mint:latest` and recreating only mint
  with `docker compose up -d --no-deps --no-build --timeout 180 mint`.

## Historical receipt recovery

An incident-specific transaction checked the account hash, request fingerprint,
unknown state, absence of actual charge/output, and account-deletion state. It
changed exactly one row to `failed`, zero reserved/actual/charged, retaining its
identity and a 90-day receipt. Evidence was the explicit pre-dispatch rejection;
empty LiteLLM spend/error tables were **not** used as evidence of nonbilling.

SQLite online backup retained in the mint data volume:
`/data/ovid-images.sqlite.pre-capacity-reconcile-20261008-1791447762711611836`.
The guarded one-incident script is `/tmp/opencode/reconcile-image-20261008.py`.
Do not restore the entire backup over later paid work; any rollback of accounting
must be reviewed and scoped to the incident row.

Existing installations can synchronize the terminal receipt through:
**Usage → ⋮ → Image receipts → Check status**, then submit a new image job.
The more precise Flutter messages require a subsequent application build/release.

## Limits of verification

The deployment and receipt recovery do not establish that an upstream currently
has capacity. No new paid production image was submitted during these checks.
The tests validate the incident fix, not a ten-million-user load/capacity claim.
