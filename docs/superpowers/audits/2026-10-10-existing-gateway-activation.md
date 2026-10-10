# Existing gateway activation inspection

Target selected by the user: existing gateway host, `/opt/ovid-gateway`.

## Repository work

The preceding app/private-sync implementation was committed and pushed as
`6eb7f06`. PostgreSQL collaboration now additionally provides native transactions,
multi-process capacity/sequence enforcement, persistent cursors and idempotency,
account cleanup, explicit schema migration 004, and atomic offline SQLite import.
Runtime selection supports `LIVE_COLLABORATION_BACKEND=postgres` without a SQLite
fallback. In-flight source-bound account cleanup prevents an unsafe import.

Final focused verification on disposable PostgreSQL 16:

- Entire collaboration suite after review fixes: 187 tests and 78 subtests passed.
- Runtime/PostgreSQL/migration/process verification: 101 tests passed.
- Tool discovery in the test virtualenv: 66 tests passed.
- Whitespace checks passed. Disposable database/container/volume removed.

## Read-only host observations

- Compose stack exists with mint, Caddy, LiteLLM, PostgreSQL and Redis.
- Caddy serves `api.ovidsi.com` and the legacy hostname, forwarding model/image,
  mint and usage routes. Account, private-sync and collaboration routes are absent.
- Running mint environment reports `APPCHECK_ENABLED=false`.
- Running mint has no `GOOGLE_APPLICATION_CREDENTIALS`, account App Check app-ID
  allowlist, account store config, cleanup manifest, or account database setting.
- The mint image has no `firebase_admin` package. It is the existing mint runtime,
  not the new account-service deployment image.

These observations do not establish whether credentials exist elsewhere on the
host. No secret values were printed or copied into this repository.

## Activation remains blocked

An authorized Firebase Admin credential/ADC identity and the approved Firebase
App Check app-ID configuration must be supplied to the new service. The existing
gateway's admission/cleanup authorities must be configured and verified, including
the deployed LiteLLM ownership manifest and authoritative image/share stores.
Valid signed-device ID-token/App-Check acceptance cannot be fabricated from public
Firebase project configuration.

No live schema migrations, account service start, public proxy changes, token
verification bypass, or worker activation was performed. Existing traffic remains
on the original deployment. Continue provisioning only after the missing identity
and authority configuration is available; use `server/account/DEPLOYMENT.md`.
