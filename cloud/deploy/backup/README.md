# Ovid Postgres backups — restorable, verified, off-site ready

`pg_backup.sh` dumps **every non-template database** on the live Postgres
instance as plain-SQL `pg_dump | zstd -9` into timestamped run directories:

```
${BACKUP_DIR:-/opt/ovid-backups/pg}/
└── 20261026-033012/
    ├── litellm.dump.zst
    ├── ovid_account_dev.dump.zst
    ├── ovid_cloud.dump.zst
    └── postgres.dump.zst
```

The run is **read-only** with respect to the live databases; it never writes
or restarts any live service.

## Safety features

- **Free-space guard** — aborts before dumping when the backup filesystem has
  less than `BACKUP_MIN_FREE_MB` (default 2048) free, and re-checks between dumps.
- **Overlap guard** — `flock -n` on `BACKUP_LOCK_FILE`; concurrent runs exit
  nonzero instead of doubling I/O.
- **Integrity** — every compressed dump passes `zstd -t` before the run continues.
- **Proven restorable** — set `BACKUP_VERIFY=1` and every dump is restored to a
  scratch database and compared row-for-row (row count + per-table MD5 checksum).
- **Retention** — configurable daily (`BACKUP_DAILY_RETENTION_DAYS`, default 14)
  and weekly (`BACKUP_WEEKLY_RETENTION_WEEKS`, default 4) pruning; older backups
  are removed, with one snapshot kept per week.
- **Offsite (optional)** — when `OVID_R2_ACCOUNT_ID`, `OVID_R2_BUCKET`,
  `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are set, the run directory is
  uploaded to R2. When unset a loud LOCAL-ONLY notice is emitted.
- **Any failure → nonzero exit**, so the systemd unit lands in `failed`.

## Configuration

For the systemd timer, put overrides in `/opt/ovid-cloud/backup.env`
(`chmod 600`).

| Var                       | Default                    | Meaning                                   |
| ------------------------- | -------------------------- | ----------------------------------------- |
| `PG_CONTAINER`            | `ovid-gateway-postgres-1`  | docker container (when `PG_HOST` empty)   |
| `PG_HOST`                 | _(empty)_                  | set to use host psql instead of docker    |
| `PG_PORT`                 | `5432`                     |                                           |
| `PG_USER`                 | `postgres`                 |                                           |
| `PGPASSWORD`              | _(unset)_                  | password for `PG_USER`                    |
| `BACKUP_DIR`              | `/opt/ovid-backups/pg`     | destination root                          |
| `BACKUP_MIN_FREE_MB`      | `2048`                     | free-space guard threshold                |
| `BACKUP_DAILY_RETENTION_DAYS`  | `14`                  | keep all runs within N days               |
| `BACKUP_WEEKLY_RETENTION_WEEKS`| `4`                   | keep one run per week beyond daily        |
| `BACKUP_VERIFY`           | `0`                        | set `1` to prove every dump restorable    |
| `BACKUP_LOCK_FILE`        | `/tmp/ovid-pg-backup.lock` | flock path                                |
| `BACKUP_DBS`              | _(all non-template)_       | explicit space-separated DB list          |
| `OVID_R2_*`, `AWS_*`      | _(unset)_                  | R2 offsite upload                         |

## Schedule

`ovid-cloud-backup.timer` fires nightly at **03:30 UTC** with `Persistent=true`
(missed runs fire on next boot) and `RandomizedDelaySec=15m`.

Install:

```bash
sudo cp /opt/ovid-cloud/repo/cloud/deploy/backup/ovid-cloud-backup.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ovid-cloud-backup.timer
systemctl list-timers ovid-cloud-backup.timer
journalctl -u ovid-cloud-backup.service --since -7d
```

Manual run:

```bash
sudo systemctl start ovid-cloud-backup.service
# or directly:
sudo BACKUP_DIR=/tmp/ovid-backup-manual /opt/ovid-cloud/repo/cloud/deploy/backup/pg_backup.sh
```

## Restore

Dumps are plain SQL (`OWNER TO` statements included), so the owning roles must
exist on the target instance. The `pg_restore.sh` helper is the exact inverse of
the backup script.

### `pg_restore.sh` options

```text
--dump PATH          .dump.zst file
--target-db NAME     database to restore into
--create             create the database if it does not exist
--drop               DROP the database before restore
--force              with --drop, use WITH (FORCE)
--container NAME     docker container [ovid-gateway-postgres-1]
--host HOST          use host psql instead of docker
--port PORT
--user USER
--password PASSWORD
--admin-db NAME      database for CREATE/DROP [postgres]
```

## Runbook

### (a) Take a verified backup now

Risk: low. Read-only against live DB; writes a compressed dump locally.
Blast radius: backup disk consumption.

```bash
sudo systemctl start ovid-cloud-backup.service
# Verify:
journalctl -u ovid-cloud-backup.service --since -1h
ls -l /opt/ovid-backups/pg/$(ls -t /opt/ovid-backups/pg | head -n1)
```

### (b) Verify a backup without restoring over live

Risk: very low. Restores only to a scratch database.
Blast radius: temporary disk and CPU on the backup host.

```bash
/opt/ovid-cloud/repo/cloud/deploy/backup/pg_verify_restore.sh \
  --dump /opt/ovid-backups/pg/<TS>/ovid_cloud.dump.zst \
  --source-db ovid_cloud \
  --target-db ovid_cloud_verify_$(date +%s) \
  --host 127.0.0.1 --port 5432 --user postgres --password "$PGPASSWORD"
```

### (c) Restore to a new database

Risk: low. The live database is untouched; restore goes to a new DB.
Blast radius: disk and name collision if the target exists.

```bash
/opt/ovid-cloud/repo/cloud/deploy/backup/pg_restore.sh \
  --dump /opt/ovid-backups/pg/<TS>/ovid_cloud.dump.zst \
  --target-db ovid_cloud_restored --create
```

### (d) Restore over live

Risk: **high**. Destroys the live database and replaces it with the backup.
Blast radius: data loss for anything written after the backup; downstream
services must be stopped first.

```bash
# 1. Stop writers for the database.
cd /opt/ovid-cloud/repo/cloud/deploy && docker compose stop gateway worker

# 2. Restore over the live database.
/opt/ovid-cloud/repo/cloud/deploy/backup/pg_restore.sh \
  --dump /opt/ovid-backups/pg/<TS>/ovid_cloud.dump.zst \
  --target-db ovid_cloud --drop --force

# 3. Verify and restart.
docker exec ovid-gateway-postgres-1 psql -U postgres -d ovid_cloud -Atc "SELECT count(*) FROM pg_tables WHERE schemaname='public'"
cd /opt/ovid-cloud/repo/cloud/deploy && docker compose start gateway worker
curl -sf http://127.0.0.1:8082/cloud/v1/health
```

### (e) Roll back a migration using the backup

Risk: **high**. Same as (d); the backup predates the migration.
Blast radius: all writes since the backup are lost.

1. Stop gateway and worker.
2. Restore the pre-migration backup over `ovid_cloud` as in (d).
3. Ensure migration tooling is aligned with the restored schema version
   (e.g. `drizzle-kit` baseline or skip the already-applied migrations).
4. Restart gateway and worker.

## Restore from R2

```bash
mkdir -p /tmp/restore-<TS>
aws s3 cp --recursive "s3://$OVID_R2_BUCKET/pg/<TS>/" /tmp/restore-<TS>/ \
  --endpoint-url "https://$OVID_R2_ACCOUNT_ID.r2.cloudflarestorage.com"
# Then follow (c) or (d) using /tmp/restore-<TS>/ovid_cloud.dump.zst
```

## Verification log

Record each restore drill here. A drill is a successful run of
`pg_verify_restore.sh` (or an equivalent manual dump → drop → restore → checksum
proof). Re-run after the first timer-produced backup, then quarterly.

- **Next drill:** ___________
