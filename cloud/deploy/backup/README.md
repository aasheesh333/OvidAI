# Ovid Postgres backups

`pg_backup.sh` dumps **every non-template database** on the live
`ovid-gateway-postgres-1` container (currently `litellm`, `ovid_account_dev`,
`postgres` — and `ovid_cloud` automatically once provision.sh creates it) as
plain-SQL `pg_dump | zstd -9` into timestamped run directories:

```
${BACKUP_DIR:-/opt/ovid-backups/pg}/
└── 20261016-033012/
    ├── litellm.dump.zst
    ├── ovid_account_dev.dump.zst
    ├── ovid_cloud.dump.zst        # once provisioned
    └── postgres.dump.zst
```

It is **read-only** with respect to the databases (only `pg_dump`/`psql -c
SELECT` run inside the live container) and never restarts or modifies any
live service.

## Safety behaviour

- **Free-space guard** — aborts loudly before dumping when the filesystem
  under `BACKUP_DIR` has less than `BACKUP_MIN_FREE_MB` (default 2048) free,
  and re-checks between dumps so one huge DB cannot fill the disk.
- **Overlap guard** — `flock -n` on `BACKUP_LOCK_FILE`; a second concurrent
  run exits nonzero instead of doubling I/O.
- **Integrity** — every dump is verified with `zstd -t` immediately after
  writing; a corrupt/partial file fails the run (and is deleted).
- **Retention** — run directories matching `YYYYMMDD-HHMMSS` older than
  `BACKUP_RETENTION_DAYS` (default 14) are pruned. Nothing else under
  `BACKUP_DIR` is ever deleted.
- **Offsite (optional)** — when `OVID_R2_ACCOUNT_ID`, `OVID_R2_BUCKET`,
  `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are all set, the run
  directory is uploaded with `aws s3 cp --recursive … --endpoint-url
  https://<account>.r2.cloudflarestorage.com`. When unset the script prints a
  loud LOCAL-ONLY notice. Upload failure = nonzero exit (local copies kept).
- **Any failure → nonzero exit**, so the systemd unit lands in `failed`
  (visible in `systemctl status` / `journalctl -u ovid-cloud-backup.service`).

## Configuration (env vars, all optional)

| Var                   | Default                     | Meaning                                  |
| --------------------- | --------------------------- | ---------------------------------------- |
| `PG_CONTAINER`        | `ovid-gateway-postgres-1`   | container running pg_dump/psql           |
| `BACKUP_DIR`          | `/opt/ovid-backups/pg`      | destination root                         |
| `BACKUP_MIN_FREE_MB`  | `2048`                      | free-space guard threshold               |
| `BACKUP_RETENTION_DAYS` | `14`                      | local prune age (`0` disables pruning)   |
| `BACKUP_LOCK_FILE`    | `/tmp/ovid-pg-backup.lock`  | flock path                               |
| `BACKUP_DBS`          | _(all non-template DBs)_    | explicit space-separated DB list         |
| `OVID_R2_*`, `AWS_*`  | _(unset)_                   | R2 offsite upload (see above)            |

For the systemd timer, put overrides in `/opt/ovid-cloud/backup.env`
(`chmod 600`; `EnvironmentFile=-` in the unit). A commented template lives in
`cloud/deploy/.env.example` under "Backups".

## Schedule

`ovid-cloud-backup.timer` fires nightly at **03:30 UTC** with
`Persistent=true` (missed runs fire on next boot) and `RandomizedDelaySec=15m`.
Install procedure: `cloud/deploy/DEPLOY.md` §8. Check with:

```bash
systemctl list-timers ovid-cloud-backup.timer
journalctl -u ovid-cloud-backup.service --since -7d
```

Manual run (same env as the timer):

```bash
sudo systemctl start ovid-cloud-backup.service     # or directly:
sudo BACKUP_DIR=/tmp/ovid-backup-manual ./pg_backup.sh
```

## Restore

Dumps are **plain SQL** (schema + data, `OWNER TO` statements included), so
restoring requires the owning roles to exist. On this box they do
(`ovid_cloud` is recreated by `provision.sh` if ever dropped).

### Restore one database on this host (real restore — owner only)

1. **Stop the writers** for that DB, e.g. for `ovid_cloud`:
   `cd /opt/ovid-cloud/repo/cloud/deploy && docker compose stop gateway worker`
2. **Pick a run**: `ls /opt/ovid-backups/pg/`
3. **Recreate the target database** (drops the current one!):
   ```bash
   docker exec -i ovid-gateway-postgres-1 sh -c \
     'psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -c \
      "DROP DATABASE IF EXISTS ovid_cloud WITH (FORCE); CREATE DATABASE ovid_cloud OWNER ovid_cloud;"'
   ```
4. **Stream the dump in** (no intermediate disk copy needed):
   ```bash
   zstd -dc /opt/ovid-backups/pg/<TS>/ovid_cloud.dump.zst | \
     docker exec -i ovid-gateway-postgres-1 sh -c \
     'psql -U "$POSTGRES_USER" -d ovid_cloud -v ON_ERROR_STOP=1 -q'
   ```
   (For `litellm`/`ovid_account_dev`, additionally stop their containers
   first and substitute the DB/owner names; both roles exist on this box.)
5. **Verify**: `\dt` count > 0, spot-check row counts, then
   `docker compose start gateway worker` and
   `curl -sf http://127.0.0.1:8082/cloud/v1/health`.

### Restore from R2

```bash
aws s3 cp --recursive "s3://$OVID_R2_BUCKET/pg/<TS>/" /tmp/restore-<TS>/ \
  --endpoint-url "https://$OVID_R2_ACCOUNT_ID.r2.cloudflarestorage.com"
```

then follow the same steps against `/tmp/restore-<TS>/<db>.dump.zst`.

### Restore to a FOREIGN postgres (drill / disaster recovery)

`OWNER TO` lines fail when the roles don't exist. Either create them first
(`CREATE ROLE ovid_cloud LOGIN; CREATE ROLE litellm LOGIN; …`), or restore
ignoring ownership errors (tables end up owned by the restoring superuser):

```bash
docker run -d --name ovid-restore-drill -e POSTGRES_PASSWORD=drill \
  -p 127.0.0.1:5434:5432 postgres:16-alpine
zstd -dc /opt/ovid-backups/pg/<TS>/litellm.dump.zst | \
  docker exec -i ovid-restore-drill psql -U postgres -d postgres -q 2>restore.log
docker exec ovid-restore-drill psql -U postgres -Atc \
  "SELECT count(*) FROM pg_tables WHERE schemaname='public'"   # expect > 0
docker rm -f ovid-restore-drill
```

Run this drill after the first real backup, then quarterly — a backup that
has never been restored is a hope, not a plan.

## Verification log

Proven restores are recorded here, newest first. A drill = the FOREIGN-postgres
procedure above, run end-to-end on a scratch container, with cleanup verified.

- **2026-10-16 — Task-11 scratch restore drill: PASS.** One live `pg_backup.sh`
  run (read-only against the databases; dumps written to /tmp): discovered
  `litellm`, `ovid_account_dev`, `postgres`; free-space gate OK (45057 MB ≥
  2048); `zstd -t` → "3 files decompressed : 11388460 bytes total". Restore:
  scratch `postgres:16-alpine` container on `127.0.0.1:5434`,
  `CREATE ROLE litellm LOGIN`, then
  `zstd -dc litellm.dump.zst | psql -U postgres -v ON_ERROR_STOP=1 -q` →
  **exit 0**; `SELECT count(*) FROM pg_tables WHERE schemaname='public'` →
  **88** (87 `LiteLLM_*`, incl. `LiteLLM_SpendLogs`, `LiteLLM_VerificationToken`).
  Cleanup verified: scratch container removed, /tmp dumps deleted. Full detail:
  `.superpowers/sdd/2026-10-15-ovid-cloud-p0-p1-spine/task-11-report.md` §7–8.
- **Next:** re-run the drill after the first timer-produced backup
  (install per `DEPLOY.md` §8), then quarterly. Record results here.
