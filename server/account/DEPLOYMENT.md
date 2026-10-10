# Configured backend composition — deployment commands, not activation evidence

Run commands from the reviewed repository root. All host values below must come
from the operator's actual inventory. Nothing in this repository discovers or
configures the external mint service, IAM, shared spend authority or proxy.

The concrete `server.sync.postgres.PostgresSyncRepository` is wired directly to
the account `PostgresStore` when private sync is configured. No external factory
is needed. Runtime/configuration tests establish code behavior; they do **not**
establish real activation, deployed credentials, gateway fences or public routing.
No production service is enabled by installing these artifacts.

## 1. Inventory and provision authoritative local stores

All image serving, share serving, deletion and retention processes must use the
**same physical local databases**, on a host/filesystem supporting SQLite locking.
Do not use per-container copies, network filesystems, temporary storage or a new
empty database in place of an existing authority. Store UUIDs detect accidental
misbinding; a copied/stale backup has the same UUID and still needs host controls.

Set `ACCOUNT_STORE_CONFIG` to a protected JSON file with precisely this shape,
replacing the descriptive placeholders with reviewed absolute paths and distinct
canonical UUIDs generated once (`python -c 'import uuid; print(uuid.uuid4())'`):

```json
{
  "version": 1,
  "images": {"path": "<absolute authoritative image SQLite file>", "store_id": "<stable UUID>"},
  "shares": {"path": "<absolute authoritative shares SQLite file>", "store_id": "<different stable UUID>"}
}
```

The parent directories must already exist and be service-owned. This config is
mandatory even while paid images remain inactive: existing content still needs
erasure. If an external store owns content instead, this local composition is
insufficient; implement/test its acknowledged idempotent adapter before activation.

Close admission and drain **all** older consumers before upgrading. Take consistent
DB/WAL backups under the actual retention policy. Explicitly bind reviewed existing
databases (or create reviewed new authorities on a first installation):

```sh
"$OVID_PYTHON" -m pip install -r server/account/requirements.txt
"$OVID_PYTHON" -m server.account.stores --provision
"$OVID_PYTHON" -m server.account.stores
```

`OVID_PYTHON` is the absolute executable in the actual deployment virtualenv.
Provisioning is repeatable and never replaces an identity. Normal startup refuses
missing files/identities and validates both stores before additive migrations.
Constructors add retention indexes without changing existing deadlines or charges.
The image legacy migration retains unknown reservations and discards undated old
replay content; see images/README.md. No destructive schema migration is introduced.

First install of the account database (PostgreSQL only):

```sh
psql "$ACCOUNT_DATABASE_URL" -v ON_ERROR_STOP=1 -f server/account/schema.sql
psql "$ACCOUNT_DATABASE_URL" -v ON_ERROR_STOP=1 -f server/account/schema_private_sync.sql
```

Existing account database (instead of the fresh-install files):

```sh
psql "$ACCOUNT_DATABASE_URL" -v ON_ERROR_STOP=1 -f server/account/migrations/002_retry_schedule.sql
psql "$ACCOUNT_DATABASE_URL" -v ON_ERROR_STOP=1 -f server/account/migrations/003_private_sync.sql
```

Legacy rows still `deleting` get the new image/share stages despite aggregate
`data`. Already `deleted` rows are not automatically re-enqueued: audit those
tombstones against both stores and run an operator-reviewed idempotent backfill
before signoff. Do not edit a completed row to resurrect Auth or permit admission.
Drain API/worker together: old binaries ignore required stages, identity bindings
and tombstones. Keep admission closed and roll forward if an upgrade fails.

## 2. Account/share application factory

### Configuration and shared authority identity

Start with `server/account/deploy/.env.example`, `examples/account-stores.json`
and `examples/account-cleanup-manifest.json`. The manifest's `REPLACE_*` tables
are placeholders, not claims about the deployed LiteLLM schema. Replace all
example UUIDs with distinct UUIDs generated **once per authority**, record them
in the inventory, and share them across API, deletion and retention processes.

`PRIVATE_SYNC_CONFIGURED=true` selects the concrete PostgreSQL implementation
using `ACCOUNT_DATABASE_URL` and its `public` schema. Apply the SQL above first.
Set `PRIVATE_SYNC_AUTHORITY_ID` to the stable inventory UUID. It is independent
of credentials/DSN spelling: credential rotation must not change cleanup identity.
Never reuse that UUID for another database or an independently restored copy.
The deployment identity is operator-bound, not discovered from a remote server;
the local configuration check does not prove database connectivity or binding.

`LIVE_COLLABORATION_CONFIGURED=true` requires an absolute
`LIVE_COLLABORATION_DATABASE_PATH` and `LIVE_COLLABORATION_AUTHORITY_ID`. Bind its
on-disk identity explicitly before startup, after reviewing any existing content:

```sh
"$OVID_PYTHON" -m server.account.runtime --provision-collaboration
"$OVID_PYTHON" -m server.account.runtime
```

Ordinary startup refuses missing/rebound collaboration databases. Its stored UUID
replaces path-based identity; moving the same authority preserves its identity.
Paths must be distinct from the image/share databases. The existing local store
identity mechanism checks the file's kind and UUID before constructing the repository.
All writers must use the same physical collaboration file and locking filesystem.

`PRIVATE_SYNC_ACTIVATED` and `LIVE_COLLABORATION_ACTIVATED` control **HTTP routes
only**. Keep `*_CONFIGURED`, IDs and paths in place when disabling routes. Even
with `*_CONFIGURED=false`, specifying an authority ID/path/factory retains cleanup;
route activation also implies configuration for older installations. Boolean values
must be exactly `true` or `false`. Removing all configuration is a decommissioning
operation requiring a data inventory, not a way to pause HTTP traffic.

The optional legacy `PRIVATE_SYNC_REPOSITORY_FACTORY=module:attribute` still receives
the same account authority. Its result must declare `durability='durable'`,
`authority='server'`, a nonempty stable `authority_identity`, and implement the
sync/deletion/`purge_expired(limit=...)` contracts. Arbitrary class/path identity
fallbacks are rejected. Factory code must itself avoid Firebase/mint dependencies
if used by retention. Existing in-progress cleanup records with older identities
fail closed on identity mismatch; reconcile their original authorities during a
drained upgrade rather than discarding saved checkpoints.

Supply the account README's real Postgres/SQL manifest/Firebase App Check/ADC,
LiteLLM/Redis environment plus `ACCOUNT_STORE_CONFIG` and `SHARE_BASE_URL` (actual
HTTPS origin and optional path prefix). Verify gateway fences and IAM in staging
before setting `ACCOUNT_ACTIVATED=true`.

```sh
"$OVID_PYTHON" -m uvicorn server.account.runtime:create_app --factory --host "$OVID_BIND_HOST" --port "$OVID_BIND_PORT" --no-access-log --no-proxy-headers
"$OVID_PYTHON" -m server.account.worker
```

The app factory mounts account routes, optional `/sync/v1` and `/chat` routes,
and shares/viewer under the path prefix in
`SHARE_BASE_URL`. It uses Firebase Admin revocation/App Check/disabled checks and
holds `Lifecycle.access` across each owner repository operation. Public viewer
reads remain anonymous and enforce revocation/expiry on each request. The proxy
must route these exact paths, bypass caches and honor no-store, and avoid logging
share tokens. Configure client flags only after actual public route acceptance.

## 3. Existing mint host: configured image router factory

Use the **actual mint module** in its host composition. This is a Python integration
API, not a guessed import name or a second key-minting service:

```python
from server.account.runtime import build
from server.images.runtime import mount_configured_images

lifecycle, admin = build()
service = mount_configured_images(
    mint, lifecycle, admin, lifecycle.data.stores, image_config_path,
    transport=verified_inferhub_transport,
    admission=shared_atomic_budget_admission,
    enforced_max_upstream_cost=enforced_route_ceiling,
)
```

`mint`, `image_config_path`, `verified_inferhub_transport`,
`shared_atomic_budget_admission` and `enforced_route_ceiling` are host-supplied
objects/configuration, not repository exports or fabricated authorities. Transport
is normally `server.images.inferhub.InferHub` with the actual protected key.
Its catalog verification contacts upstream **only on active factory construction**.
No such call was made for local verification. Mount exactly once per mint app,
before serving, with no duplicate pre-existing `/v1/models` or image routes.

Missing transport, shared admission, cost ceiling, or enabled mint App Check keeps
all image routes at 503 while installing private backend catalog masking. With all
present the factory also checks Firebase Admin identity and current scoped mint
key ownership. Its account lock encloses the shared budget context and the whole
image execution. Match that lock order in text/mint/webhook writers; never acquire
the shared quota lock and then the account lock in another writer.

`GET /v1/images/requests/{request_id}` reads the receipt;
`GET /v1/images/requests/{request_id}/result` reads the original output + receipt.
Both recheck identity/key/App Check/account fences, work at zero remaining quota,
send no-store, and never admit/resubmit/settle a paid job. Unknown work returns 409,
missing work 404, expired/deleted work 410. POST retains paid admission checks.
The client may persist/poll the original request ID and fetch the result without
creating a new billable request. Read expiry works before scheduled physical purge.

The shared bridge remains external: it must coordinate text/image spend, pending
reservations, exact settlements, resets and `/usage`. Local ledger confirmation is
not evidence of settlement in LiteLLM/Redis. Verify scoped mint keys, upstream cap,
proxy routing and controlled cheap paid generation/edit only after that bridge exists.

## 4. Bounded retention and restart scheduling

One sweep removes at most `batch-size * max-batches` eligible rows **per authority**,
using each repository's transactional `purge_expired(limit=...)`. Configured private
sync participates even with its HTTP routes disabled. Limits are 1–10,000 rows and 1–100 batches;
defaults are 500 and 4. Failures in one store do not starve the other; exit 1 and
the JSON `failed` names signal retry. It never drops billing/dedup tombstones or
pending/unknown reservations. It does not need Firebase credentials/activation.
Construction uses only configured stores and the account PostgreSQL authority,
without importing Firebase or gateway adapters. Collaboration is opened/identity
validated for consistent cleanup configuration, but no collaboration expiry sweep
is claimed: that repository currently exposes no `purge_expired` contract.

```sh
"$OVID_PYTHON" -m server.account.retention --batch-size 500 --max-batches 4
# Alternative sync-only invocation; normally the combined timer above suffices.
"$OVID_PYTHON" -m server.sync.maintenance --batch-size 500 --max-batches 4
```

Install the provided unit files only after preparing actual protected drop-ins:

```sh
sudo install -m 0644 server/account/deploy/ovid-account-worker.service /etc/systemd/system/
sudo install -m 0644 server/account/deploy/ovid-account-worker.timer /etc/systemd/system/
sudo install -m 0644 server/account/deploy/ovid-retention.service /etc/systemd/system/
sudo install -m 0644 server/account/deploy/ovid-retention.timer /etc/systemd/system/
sudo systemctl edit ovid-account-worker.service
sudo systemctl edit ovid-retention.service
```

Each drop-in must set the actual `User=`, `WorkingDirectory=`, `EnvironmentFile=`
and `ExecStart=`. For the worker ExecStart is the absolute Python executable
followed by `-m server.account.worker`; for retention it is followed by
`-m server.account.retention --batch-size 500 --max-batches 4`.
Set `ReadWritePaths=` to both database **parent directories** (SQLite journals/WAL
must be writable). The service account needs config read access. If storage/code
is under a protected home directory, choose an explicit reviewed systemd policy.
The unit templates deliberately have no executable/host defaults and cannot run
until configured. Retention uses `deploy/retention.env.example`: store configuration,
configured shared authority identities/paths, and the PostgreSQL DSN when sync is
configured. It needs no Firebase, Redis, LiteLLM or mint secrets. A missing purge
implementation or invalid result is a nonzero failure, never successful cleanup.

```sh
sudo systemd-analyze verify /etc/systemd/system/ovid-account-worker.service /etc/systemd/system/ovid-retention.service
sudo systemctl daemon-reload
sudo systemctl start ovid-retention.service
sudo systemctl start ovid-account-worker.service
sudo systemctl enable --now ovid-retention.timer ovid-account-worker.timer
sudo systemctl list-timers ovid-retention.timer ovid-account-worker.timer
sudo journalctl -u ovid-retention.service -u ovid-account-worker.service
```

Persistent timers catch up after reboot. Systemd serializes each oneshot locally;
overlapping hosts still serialize SQLite effects. Interrupted transactions roll
back; a later tick repeats safely. A sweep is row/count bounded, not a global
latency guarantee: SQLite lock waits and external worker calls have separate
timeouts, and systemd imposes the process deadline. Alert on nonzero exits,
overdue deletion and sustained expiry backlog. Verify backup/free-page/WAL/log
expiration and tombstone replay after restore separately from logical row cleanup.

## 5. API service, container and exact reverse-proxy routes

The new API unit uses the explicit layout `/opt/ovid-account` (reviewed source),
`/opt/ovid-account/venv`, `/etc/ovid-account` (protected configuration), and
`/var/lib/ovid-account` (service-owned persistent database directory). Create the
`ovid-account` user/group and directories before installation. Config/ADC files
must be service-readable, not public; use directory mode 0750 and file mode 0640.
`worker.conf.example` and `retention.conf.example` supply matching host drop-ins
for the existing oneshot units. Adjust all paths together for a different layout.

```sh
sudo install -m 0644 server/account/deploy/ovid-account-api.service /etc/systemd/system/
sudo systemd-analyze verify /etc/systemd/system/ovid-account-api.service
```

The unit binds only `127.0.0.1:8080` and disables Uvicorn access logging. Its
read-only filesystem policy allows writes only to the authoritative database
directory; SQLite WAL/journals must share that directory. Start/enable the API
only after staging acceptance and protected configuration are complete.

For containers, build from the repository root using the supplied Dockerfile and
its adjacent allowlist `Dockerfile.dockerignore`. Only runtime Python source and
dependency manifests enter the context; credentials, `.env`, local databases,
tests and unrelated workspace files are excluded. Pin the base image digest in
the reviewed release after validating the image in your registry.

```sh
docker build -f server/account/deploy/Dockerfile -t ovid-account:reviewed .
docker run --rm --read-only --cap-drop ALL --security-opt no-new-privileges \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --publish 127.0.0.1:8080:8080 \
  --env-file /etc/ovid-account/api.env \
  --mount type=bind,src=/etc/ovid-account,dst=/etc/ovid-account,readonly \
  --mount type=bind,src=/var/lib/ovid-account,dst=/var/lib/ovid-account \
  ovid-account:reviewed
```

Choose container or host service for the API port. The container runs as UID/GID
10001; align directory ownership with that identity. API and all workers must
mount the **same** files, not separately initialized volumes.

`deploy/Caddyfile` is a dedicated HTTPS origin using `OVID_ACCOUNT_HOST`, which
must match `SHARE_BASE_URL` with **no path prefix** for this template. It forwards:

- `/account/login`, `/account/deletion`, `/account/deletion/cancel`
- `/sync/v1/records`, `/sync/v1/changes`, `/sync/v1/state`, `/sync/v1/devices`,
  `/sync/v1/devices/{device_id}`
- `/chat`, `/chat/{session_token}`, and its `/members`, `/members/{participant_id}`,
  `/events`, `/close` routes (including `/members/me`)
- `/shares`, `/shares/{token}`, `/shares/{token}/fork`, `/s/{token}`,
  `/s/{token}.json`, `/.well-known/assetlinks.json`

All other paths return 404; HTTP methods/auth remain enforced by the API. The
template adds no-store/no-referrer, limits request bodies, and has **no access
logging**. Do not inherit host-wide access/debug logging or upstream URI/header
logging: chat/share path tokens and Firebase headers are credentials. Keep proxy
error diagnostics redacted as well. No `/mint`, `/v1/*`, wildcard `/account/*`,
or external gateway routing is installed by this template. A prefixed share
deployment must explicitly adjust its exact matchers before use.

```sh
caddy validate --config server/account/deploy/Caddyfile --adapter caddyfile
"$OVID_PYTHON" -m unittest tool.deployment_config_test
"$OVID_PYTHON" -m pytest -q server/account/tests server/sync/tests
```

These checks verify local code/configuration. PostgreSQL integration tests use an
explicit isolated test database or local test cluster and may skip when neither
is available. Real activation still requires deployed schema/permissions, gateway
fencing, Firebase/App Check checks, public TLS/routes, backup restore and retention
acceptance. Neither template existence nor a passing local test enables production.

### CI and local verification environments

```sh
# Android/tool job: server dependencies are not required for discovery.
python3 -m unittest discover -s tool -p '*_test.py'
# Server job: run the actual runtime CLI integration without dependency skips.
"$OVID_PYTHON" -m unittest -v tool.deployment_config_test
"$OVID_PYTHON" -m pytest -q server/account/tests
```

`tool/deployment_config_test.py` imports only the standard library. Its real
store-provisioning/runtime CLI check explicitly skips when `pydantic`, Pillow or
`psycopg` is absent; its sync-maintenance CLI check skips without `psycopg`.
Missing modules are reported as skips, never successful integration. The example
config parser also runs under `python -S` to prove it needs no site packages.
Installed-but-broken/incompatible dependencies still fail the integration tests.

The `server-tests` job in `.github/workflows/build.yml` installs server dependencies,
runs deployment CLI tests, and supplies `SYNC_TEST_DATABASE_URL` from a disposable
PostgreSQL 16 service to pytest. This exercises concrete runtime-composed sync
cleanup with HTTP disabled, PostgreSQL checkpoints before Auth deletion, replay
idempotency, and account fencing after restart in an isolated test schema. Local
equivalents must point `SYNC_TEST_DATABASE_URL` only at a disposable test database.
The tests apply existing schema artifacts inside test schemas; deployment DDL and
production activation remain explicit operator actions.

See the root README's **Verification** section for the exact bounded Flutter suite
runner and manual CI selector. The default tracked-file CI manifest and the
filesystem runner both cover newly added tests once those files are committed;
the filesystem runner additionally includes untracked local test files.
