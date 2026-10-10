# Sync and collaboration runtime verification

## Implemented

- Concrete PostgreSQL private-sync repository: account/device authorization,
  transactional record admission, digest-bound idempotency, per-record partial
  results, rate and byte/ingest quotas, bounded replay/bootstrap, cursor expiry,
  deletion barriers, and cursor-aware maintenance.
- Explicit runtime composition and stable cleanup authority binding. Disabling
  HTTP routes does not remove a configured authority's deletion obligations.
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

- All account, sync, collaboration, image and share suites: **611 passed,
  1,381 subtests passed, zero skipped** against disposable PostgreSQL 16.15.
- Includes real schema application, retention and runtime account cleanup tests.
- The single warning is an existing Starlette/AnyIO deprecation.
- Tool discovery: **66 passed** in the test virtualenv after installing its
  missing PyYAML dependency. The initial tool invocation failed to import two
  YAML-dependent modules; that environment issue was corrected, not suppressed.
- Dockerfile checks and Caddy configuration validation passed. Installed systemd
  execution still depends on the operator-provided virtualenv and host paths.

No production database, Firebase credentials, or live gateway configuration was
used for these checks. Disposable PostgreSQL resources were removed.

## Architectural decisions and deployment boundary

- Polling is the correctness transport. Optional SSE/WebSocket delivery is not
  implemented; the cost is polling latency rather than an instant push channel.
- Private sync uses PostgreSQL. Collaboration retains its hardened transactional
  SQLite authority and requires one authoritative local file; this does **not**
  implement the earlier plan's multi-host PostgreSQL collaboration authority.
  Deploying collaboration across hosts would require that migration first.
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
