# Configured backend composition — deployment commands, not activation evidence

Run commands from the reviewed repository root. All host values below must come
from the operator's actual inventory. Nothing in this repository discovers or
configures the external mint service, IAM, shared spend authority or proxy.

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

Supply the account README's real Postgres/SQL manifest/Firebase App Check/ADC,
LiteLLM/Redis environment plus `ACCOUNT_STORE_CONFIG` and `SHARE_BASE_URL` (actual
HTTPS origin and optional path prefix). Verify gateway fences and IAM in staging
before setting `ACCOUNT_ACTIVATED=true`.

```sh
"$OVID_PYTHON" -m uvicorn server.account.runtime:create_app --factory --host "$OVID_BIND_HOST" --port "$OVID_BIND_PORT"
"$OVID_PYTHON" -m server.account.worker
```

The app factory mounts `/account/*` and shares/viewer under the path prefix in
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

One sweep removes at most `batch-size * max-batches` eligible rows **per store**,
in short SQLite write transactions. Limits are 1–10,000 rows and 1–100 batches;
defaults are 500 and 4. Failures in one store do not starve the other; exit 1 and
the JSON `failed` names signal retry. It never drops billing/dedup tombstones or
pending/unknown reservations. It does not need Firebase credentials/activation.

```sh
"$OVID_PYTHON" -m server.account.retention --batch-size 500 --max-batches 4
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
until configured. Retention may use a separate env file containing only store config.

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
