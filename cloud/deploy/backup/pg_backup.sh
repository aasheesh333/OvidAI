#!/usr/bin/env bash
# Ovid Postgres backups — dumps EVERY non-template database on the live
# postgres container (works before AND after ovid_cloud exists; override with
# BACKUP_DBS), as `pg_dump | zstd -9` into:
#
#   ${BACKUP_DIR:-/opt/ovid-backups/pg}/YYYYMMDD-HHMMSS/<db>.dump.zst
#
# Guarantees: free-space guard (aborts under BACKUP_MIN_FREE_MB, default
# 2048MB — re-checked between dumps), flock overlap guard, 14-day local
# retention prune of timestamped run dirs, integrity check (zstd -t) per dump,
# optional Cloudflare R2 upload when the OVID_R2_*/AWS_* env is set (loud
# notice when not), NONZERO EXIT on any failure (systemd marks the run failed
# → visible in journalctl / systemctl status).
#
# pg_dump runs INSIDE the container (no host pg tooling needed); the host only
# needs docker + zstd (+ aws CLI for R2). Read-only w.r.t. the databases.
# Restore procedure: backup/README.md.
set -euo pipefail

PG_CONTAINER="${PG_CONTAINER:-ovid-gateway-postgres-1}"
BACKUP_ROOT="${BACKUP_DIR:-/opt/ovid-backups/pg}"
MIN_FREE_MB="${BACKUP_MIN_FREE_MB:-2048}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
LOCK_FILE="${BACKUP_LOCK_FILE:-/tmp/ovid-pg-backup.lock}"
DB_LIST="${BACKUP_DBS:-}"

log() { printf '[backup %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() {
  printf '[backup] FATAL: %s\n' "$*" >&2
  exit 1
}

command -v docker >/dev/null || die "docker not found on PATH"
command -v zstd >/dev/null || die "zstd not found on PATH (apt install zstd)"
docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER" ||
  die "postgres container '$PG_CONTAINER' is not running"

# ── Overlap guard: a slow run must never be joined by the next tick ────────
exec 9>"$LOCK_FILE"
flock -n 9 || die "another backup holds $LOCK_FILE — refusing to overlap"

# ── Destination + free-space guard ─────────────────────────────────────────
mkdir -p "$BACKUP_ROOT"
TS="$(date -u +%Y%m%d-%H%M%S)"
DEST="$BACKUP_ROOT/$TS"
free_mb() { df -Pm "$BACKUP_ROOT" | awk 'NR==2 {print $4}'; }
FREE_MB="$(free_mb)"
[ "$FREE_MB" -ge "$MIN_FREE_MB" ] ||
  die "only ${FREE_MB}MB free under $BACKUP_ROOT (< ${MIN_FREE_MB}MB required) — refusing to dump"
mkdir -p "$DEST"
log "free ${FREE_MB}MB (min ${MIN_FREE_MB}MB) → writing to $DEST"

# ── Database list: explicit BACKUP_DBS, else discover ──────────────────────
if [ -z "$DB_LIST" ]; then
  DB_LIST="$(
    docker exec "$PG_CONTAINER" sh -c \
      'psql -U "${POSTGRES_USER:-postgres}" -d postgres -Atqc "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY 1"'
  )"
  [ -n "$DB_LIST" ] || die "no databases discovered on $PG_CONTAINER"
fi
log "databases: $(echo $DB_LIST)"

# ── Dump (plain SQL | zstd -9; integrity-checked; fail-fast) ───────────────
for db in $DB_LIST; do
  out="$DEST/$db.dump.zst"
  log "dumping $db …"
  if ! docker exec "$PG_CONTAINER" sh -c 'pg_dump -U "${POSTGRES_USER:-postgres}" -d "$1"' _ "$db" |
    zstd -9 -q -o "$out"; then
    rm -f -- "$out"
    die "$db: pg_dump | zstd pipeline failed"
  fi
  zstd -t "$out" || die "$db: compressed dump FAILED integrity check ($out)"
  log "  → $out ($(du -h "$out" | cut -f1))"
  # Re-check between dumps: one huge database must not fill the disk.
  FREE_MB="$(free_mb)"
  [ "$FREE_MB" -ge "$MIN_FREE_MB" ] ||
    die "free space fell to ${FREE_MB}MB mid-run (< ${MIN_FREE_MB}MB) — aborting after $db"
done

# ── Retention: prune timestamped run dirs older than RETENTION_DAYS ────────
if [ "$RETENTION_DAYS" -gt 0 ]; then
  while IFS= read -r old; do
    [ -n "$old" ] || continue
    log "prune (older than ${RETENTION_DAYS}d): $old"
    rm -rf -- "$old"
  done < <(
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
      -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{6}' \
      -mtime +"$RETENTION_DAYS"
  )
fi

# ── Optional offsite: Cloudflare R2 via the S3 API ─────────────────────────
if [ -n "${OVID_R2_ACCOUNT_ID:-}" ] && [ -n "${OVID_R2_BUCKET:-}" ] &&
  [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  command -v aws >/dev/null ||
    die "OVID_R2_* is set but the aws CLI is missing — install it or unset the R2 vars"
  log "uploading to R2 s3://${OVID_R2_BUCKET}/pg/$TS/ …"
  aws s3 cp --recursive "$DEST" "s3://${OVID_R2_BUCKET}/pg/$TS/" \
    --endpoint-url "https://${OVID_R2_ACCOUNT_ID}.r2.cloudflarestorage.com" ||
    die "R2 upload FAILED — local copies kept at $DEST"
  log "R2 upload complete"
else
  log "NOTICE: OVID_R2_* not configured — backups are LOCAL ONLY ($BACKUP_ROOT)."
  log "NOTICE: losing this disk loses the backups; set OVID_R2_* for offsite copies."
fi

log "done: $(du -sh "$DEST" | cut -f1) in $DEST"
