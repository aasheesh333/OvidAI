# Sync and collaboration runtime verification

## Implemented

- Concrete PostgreSQL private-sync repository: account/device authorization,
  transactional record admission, digest-bound idempotency, per-record partial
  results, rate and byte/ingest quotas, bounded replay/bootstrap, cursor expiry,
  deletion barriers, and cursor-aware maintenance.
- Explicit runtime composition and stable cleanup authority binding. Disabling
  HTTP routes does not remove a configured authority's deletion obligations.
- Explicit `LIVE_COLLABORATION_BACKEND=postgres|sqlite` selection (default SQLite).
  PostgreSQL collaboration uses the account DSN and resolves the lifecycle table's
  schema before construction. The operator's canonical UUID is mapped to the full
  persisted `collaboration:postgres:<uuid>` identity and checked by the repository.
  A PostgreSQL configuration rejects a nonempty SQLite path; startup never deploys
  PostgreSQL schema/secrets or falls back to SQLite.
- Account build and retention construct the configured PostgreSQL authority even
  with sync/HTTP disabled. Retention purges bounded expired rate-admission rows.
  Cleanup contexts retain backend-specific authority identity and reject migration
  mismatch or an unbound legacy context before further data/Auth deletion effects.
- Flutter production registration, authenticated transports with App Check,
  durable account-scoped enrollment/outbox/projections, foreground delivery,
  retry/quarantine handling, re-enrollment and all-account reset/readback.
- Explicit private-sync consent, settings, restored activity/conversation views,
  allowlisted provider metadata export and genuine local deletion tombstones.
- Collaboration create/join/invite/member management, bounded transport,
  durable request idempotency and quotas, membership-bound cursors, coherent
  historical replay, local messaging, terminal disconnection and recovery.
- Deployment Docker/systemd/Caddy artifacts and configuration examples;
  bounded full-inventory Flutter runner and PostgreSQL CI service.

## Verification evidence

### Full Flutter inventory

`/tmp/opencode/final-full-suite/summary.json` records one complete run of the
frozen working tree, including untracked tests:

- 467 files attempted; zero unverified files and zero timed-out batches.
- First pass: 5,639 passed, one failed, seven skipped.
- The failed accounting test passed its individual nine-test diagnostic retry.
- Diagnostic retries deliberately do not turn the runner's nonzero status into
  success. This run must not be represented as a clean first-pass success.

The remaining failure used a two-second wall-clock poll for asynchronous durable
usage publication. The test now waits for the actual AppState publication event,
retaining all two-attempt/retry/token assertions and the normal test timeout.
The affected 20-file batch subsequently passed all 119 tests at concurrency two.
Only this test synchronization changed after the full inventory run; the entire
inventory was not repeated after that change.

Earlier failures found in the first inventory sweep were repaired: the complete
core regression file passes 568 tests without hanging, and sidebar/chat/usage
regressions pass their focused responsive suites.

### Server and deployment tooling

- Latest account, sync, collaboration, image and share suites: **686 passed,
  1,381 subtests passed, zero skipped** against disposable PostgreSQL 16.15
  at `127.0.0.1:55446`, using `/tmp/opencode/testvenv/bin/python`.
- Both `COLLAB_TEST_POSTGRES_DSN` and `SYNC_TEST_DATABASE_URL` were set to the same
  test-only DSN. The command was `python -m pytest -q server/account/tests server/sync
  server/collaboration server/images server/shares`; completed in 343.27 seconds.
  An earlier invocation hit the tool's 120-second deadline; the complete rerun used
  a 600-second deadline and exited zero.
- Includes real schema application, multi-process collaboration contracts and
  offline migration tests, runtime build/mount/lifecycle admission, disabled-route
  cleanup, lost-ack restart before Auth deletion, account fences, schema/secret
  absence, authority mismatch, backend migration rejection, and retention CLI.
  Runtime tests use unique disposable schemas, including a schema dependency patch
  before constructor reads, rather than mutating the repository schema afterward.
  Firebase and gateway boundaries are controlled doubles; PostgreSQL is real.
- Deployment/runtime CLI and workflow checks: **16 passed**, using
  `python -m unittest -v tool.deployment_config_test tool.release_workflow_test`.
  CI now supplies `COLLAB_TEST_POSTGRES_DSN` alongside the sync DSN from its same
  isolated PostgreSQL service, so PostgreSQL collaboration cases run rather than skip.
- The single warning is an existing Starlette/AnyIO deprecation.
- Tool discovery: **66 passed** in the test virtualenv after installing its
  missing PyYAML dependency. The initial tool invocation failed to import two
  YAML-dependent modules; that environment issue was corrected, not suppressed.
- Dockerfile checks and Caddy configuration validation passed. Installed systemd
  execution still depends on the operator-provided virtualenv and host paths.

No production database, Firebase credentials, or live gateway configuration was
used for these checks. Runtime fixtures drop their own schemas; the pre-existing
disposable PostgreSQL container was retained for the ongoing backend work.

## Architectural decisions and deployment boundary

- Polling is the correctness transport. Optional SSE/WebSocket delivery is not
  implemented; the cost is polling latency rather than an instant push channel.
- Private sync uses PostgreSQL. Collaboration now supports the native PostgreSQL
  authority and retains SQLite as the default until deliberate offline migration.
  SQLite still requires one authoritative local file. API, deletion and retention
  must share the selected backend/identity; image/share local storage constraints
  continue to apply independently.
- `server/account/DEPLOYMENT.md` documents the exact schema/identity/import CLI,
  UUID suffix mapping, offline drain and consistent backup, empty-destination
  requirement, cleanup checkpoint reconciliation, and full-process restart after
  importing the cached cursor secret. Before destination writes, a stopped fleet
  can return to the untouched source; after destination writes, reverting to stale
  SQLite requires explicit reconciliation or roll-forward. Runtime does not migrate
  lifecycle cleanup checkpoints and supplies no automatic reverse import.
- The earlier audit claims that PostgreSQL lacked `sha256(bytea)` and that the
  deleted-account trigger permitted deletion were disproved using PostgreSQL.
  Correct SQL was retained and the erroneous extension requirement was removed
  from tests.
- Private data is transmitted over HTTPS and stored by the service. No
  end-to-end-encryption claim is made. Provider credentials and execution state
  are not synchronized; private transcript text is preserved as disclosed.

Actual activation remains operator work: provision the reviewed authorities,
apply migrations, configure endpoint URLs, Firebase/App Check, proxy and worker
environment, and perform signed-device/staging acceptance. No live deployment,
real two-device Firebase acceptance, or production activation is claimed here.
