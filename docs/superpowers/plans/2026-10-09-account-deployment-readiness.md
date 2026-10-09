# Account Deployment Readiness — 2026-10-09

**Scope:** Deployment-readiness summary for the account service and its image,
share, cleanup, and worker integrations. This is a documentation-only audit
record. It does not authorize deployment, migration execution, credential
provisioning, or production activation.

## Readiness conclusion

The account implementation and deployment artifacts are present in the
repository, but the service is **not production-ready**. Verification remains
staging-only. There is no evidence of a live production `/account` route, no
production activation, and no production deployment was performed as part of
this audit.

## Exact blockers

The following blockers must be closed by the release owner/operator before
production activation:

1. **Live `/account` route/proxy**
   - Mount the account application and route the exact `/account/*` paths
     through the production proxy.
   - Verify the actual HTTPS origin, path prefix, cache bypass,
     `Cache-Control: no-store`, rate limiting, and redacted logging.
   - The live route/proxy has not been deployed or acceptance-tested.

2. **Account service image/dependencies**
   - Install the pinned account-service dependencies from
     `server/account/requirements.txt` in the dedicated runtime.
   - Supply the actual runtime executable, service user, working directory,
     environment file, and host drop-ins.
   - Confirm the account service and worker run the reviewed image/code and
     dependency set together; no production service image activation has been
     verified.

3. **Firebase Admin/App Check**
   - Supply Firebase Admin application-default credentials with the required
     Auth permissions.
   - Register Play Integrity App Check for the signed Android build and record
     its Firebase app ID in `ACCOUNT_FIREBASE_APP_IDS`.
   - Set the external mint integration's `APPCHECK_ENABLED=true` and provide
     the shared admission bridge.
   - Verify real signed-build login, reauthentication, App Check attestation,
     revocation, and disabled-account behavior in staging. App-side wiring is
     covered by tests, but production Firebase/App Check evidence is absent.

4. **Postgres/migrations**
   - Provision durable PostgreSQL storage and backups.
   - Apply `schema.sql` for a fresh database, or explicitly apply the reviewed
     migration for an existing database; migrations have not been run against
     a production database.
   - Verify the account, LiteLLM, and quota authorities, schema readiness,
     backup/restore behavior, and the required gateway/write fences.

5. **Shared image/share stores**
   - Configure the authoritative image and share SQLite stores through
     `ACCOUNT_STORE_CONFIG`, with stable distinct store IDs and service-owned
     parent directories.
   - Confirm image serving, share serving, account deletion, and retention use
     the same physical authorities rather than per-container copies,
     temporary storage, or stale databases.
   - Provide the actual `SHARE_BASE_URL`, verify the image transport, shared
     atomic budget admission, route ceiling, and external provider/object-store
     retention behavior.

6. **Worker timers**
   - Install and configure the account-worker and retention systemd services
     and timers with reviewed `User=`, `WorkingDirectory=`,
     `EnvironmentFile=`, `ExecStart=`, and `ReadWritePaths=` values.
   - Verify timer persistence/catch-up after restart, serialized execution,
     failure alerts, overdue deletion alerts, and the shared account database
     and image/share authorities.
   - The repository unit templates are not deployment evidence; production
     worker timers have not been enabled or verified.

7. **Cleanup manifest**
   - Complete and review `ACCOUNT_CLEANUP_MANIFEST` against the deployed
     schema, including every UID-bearing table, Redis prefix, model cache,
     request log, and object bucket.
   - Validate key blocking/deletion, cache eviction, missing-key retry
     semantics, foreign-key ordering, backup expiration, and telemetry/proxy
     retention.
   - Confirm cleanup checkpoints for the account database, image store, share
     store, LiteLLM/quota integration, and external authorities before Auth
     deletion. A configured manifest and staging evidence are required;
     production cleanup sign-off is not present.

## Verification boundary

Repository tests and local artifacts establish implementation-level behavior
only. The remaining verification must run against staging Firebase, PostgreSQL,
the configured image/share authorities, the external mint/gateway, and the
actual proxy. Staging verification must cover route acceptance, authentication
and App Check, account lifecycle races, migration/restore behavior, cleanup
ordering, worker restart/catch-up, shared spend admission, and no-store/error
logging behavior.

## Activation decision

**Status: blocked.** Do not set `ACCOUNT_ACTIVATED=true`, do not build with
`OVID_ACCOUNT_ENABLED=true` for production, and do not expose the live account
route until every blocker above has staging evidence and release-owner
sign-off. No production activation was performed for this audit.

## Source audit references

- `server/account/README.md` — activation requirements, cleanup manifest, and
  runtime configuration.
- `server/account/DEPLOYMENT.md` — route/proxy, store, image integration,
  migration, and worker/timer runbook.
- `docs/superpowers/audits/2026-10-06-firebase-appcheck-gates.md` — Firebase
  Admin, App Check, signing, and external mint gates.
- `docs/superpowers/audits/2026-10-06-production-signing-runbook.md` — signed
  production-build prerequisites.
