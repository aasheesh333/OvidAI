#!/usr/bin/env bash
# Ovid Postgres backups — production-ready backup with provable restore.
#
# Dumps every non-template database on the target Postgres instance as
# plain SQL (pg_dump | zstd -9) into a timestamped run directory:
#
#   ${BACKUP_DIR:-/opt/ovid-backups/pg}/YYYYMMDD-HHMMSS/<db>.dump.zst
#
# Features:
#   - free-space guard (aborts under BACKUP_MIN_FREE_MB, default 2048MB)
#   - flock overlap guard
#   - daily + weekly retention prune
#   - integrity verification: each dump is PROVED restorable to a scratch DB
#   - optional Cloudflare R2 off-site copy when OVID_R2_* + AWS_* are set
#   - NONZERO exit on any failure (systemd marks the run failed)
#
# The script runs pg_dump inside the target container (or uses the supplied
# host/port/credentials). The host needs docker + zstd (+ aws CLI for R2).
# Restore procedure: see README.md and pg_restore.sh.
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
PG_CONTAINER="${PG_CONTAINER:-ovid-gateway-postgres-1}"
PG_HOST="${PG_HOST:-}"          # if empty, use docker exec against PG_CONTAINER
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-postgres}"
PGPASSWORD="${PGPASSWORD:-${POSTGRES_PASSWORD:-}}"
export PGPASSWORD PG_USER

BACKUP_ROOT="${BACKUP_DIR:-/opt/ovid-backups/pg}"
MIN_FREE_MB="${BACKUP_MIN_FREE_MB:-2048}"
DAILY_RETENTION_DAYS="${BACKUP_DAILY_RETENTION_DAYS:-14}"
WEEKLY_RETENTION_WEEKS="${BACKUP_WEEKLY_RETENTION_WEEKS:-4}"
LOCK_FILE="${BACKUP_LOCK_FILE:-/tmp/ovid-pg-backup.lock}"
DB_LIST="${BACKUP_DBS:-}"
VERIFY_MODE="${BACKUP_VERIFY:-0}"        # set 1 to prove every dump restorable

R2_ACCOUNT="${OVID_R2_ACCOUNT_ID:-}"
R2_BUCKET="${OVID_R2_BUCKET:-}"
R2_KEY="${AWS_ACCESS_KEY_ID:-${OVID_R2_ACCESS_KEY_ID:-}}}"
R2_SECRET="${AWS_SECRET_ACCESS_KEY:-${OVID_R2_SECRET_ACCESS_KEY:-}}}"

# ── Helpers ───────────────────────────────────────────────────────────────
log() { printf '[backup %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() {
  printf '[backup] FATAL: %s\n' "$*" >&2
  exit 1
}

needs_docker() { [ -z "$PG_HOST" ]; }

psql_cmd() {
  # usage: psql_cmd <database> <extra psql args>
  local db="$1"; shift
  if needs_docker; then
    docker exec -i "$PG_CONTAINER" \
      -e PGPASSWORD="$PGPASSWORD" \
      -e PGUSER="$PG_USER" \
      -e PGDATABASE="$db" \
      psql -v ON_ERROR_STOP=1 "$@"
  else
    PGPASSWORD="$PGPASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$db" -v ON_ERROR_STOP=1 "$@"
  fi
}

pg_dump_cmd() {
  local db="$1"
  if needs_docker; then
    docker exec -i "$PG_CONTAINER" \
      -e PGPASSWORD="$PGPASSWORD" \
      -e PGUSER="$PG_USER" \
      -e PGDATABASE="$db" \
      pg_dump
  else
    PGPASSWORD="$PGPASSWORD" pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$db"
  fi
}

# ── Preconditions ──────────────────────────────────────────────────────────
command -v docker >/dev/null || die "docker not found on PATH"
command -v zstd >/dev/null || die "zstd not found on PATH (apt install zstd)"
if ! needs_docker; then
  command -v psql >/dev/null || die "host psql not found on PATH"
  command -v pg_dump >/dev/null || die "host pg_dump not found on PATH"
fi

# ── Overlap guard ──────────────────────────────────────────────────────────
exec 9>"$LOCK_FILE"
flock -n 9 || die "another backup holds $LOCK_FILE — refusing to overlap"

# ── Destination + free-space guard ─────────────────────────────────────────
mkdir -p "$BACKUP_ROOT"
TS="$(date -u +%Y%m%d-%H%M%S)"
DEST="$BACKUP_ROOT/$TS"
free_mb() { df -Pm "$BACKUP_ROOT" | awk 'NR==2 {print $4}'; }
FREE_MB="$(free_mb)"
[ "$FREE_MB" -ge "$MIN_FREE_MB" ] ||
  die "only ${FREE_MB}MB free under $BACKUP_ROOT (< ${MIN_FREE_MB}MB required)"
mkdir -p "$DEST"
log "free ${FREE_MB}MB (min ${MIN_FREE_MB}MB) → writing to $DEST"

# ── Database list ──────────────────────────────────────────────────────────
if [ -z "$DB_LIST" ]; then
  DB_LIST="$(psql_cmd postgres -At -c 'SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY 1')"
  [ -n "$DB_LIST" ] || die "no databases discovered"
fi
log "databases: $(echo $DB_LIST)"

# ── Dump (plain SQL | zstd -9; integrity-checked; fail-fast) ───────────────
for db in $DB_LIST; do
  out="$DEST/$db.dump.zst"
  log "dumping $db …"
  if ! pg_dump_cmd "$db" | zstd -9 -q -o "$out"; then
    rm -f -- "$out"
    die "$db: pg_dump | zstd pipeline failed"
  fi
  zstd -t "$out" || die "$db: compressed dump FAILED zstd integrity check ($out)"
  log "  → $out ($(du -h "$out" | cut -f1))"

  FREE_MB="$(free_mb)"
  [ "$FREE_MB" -ge "$MIN_FREE_MB" ] ||
    die "free space fell to ${FREE_MB}MB mid-run (< ${MIN_FREE_MB}MB) — aborting after $db"
done

# ── Prove restorable (optional but recommended) ────────────────────────────
if [ "$VERIFY_MODE" = "1" ]; then
  log "VERIFY_MODE=1 — every dump will be restored to a scratch DB and compared"
  for db in $DB_LIST; do
    dump="$DEST/$db.dump.zst"
    log "verifying $db …"
    "$(dirname "$0")/pg_verify_restore.sh" \
      --dump "$dump" \
      --source-db "$db" \
      --target-db "verify_${db}_${TS}" \
      --host "${PG_HOST:-127.0.0.1}" --port "${PG_PORT}" --user "${PG_USER}" ||
      die "$db: restore verification FAILED"
    log "  → $db verified restorable"
  done
fi

# ── Retention: daily + weekly pruning ──────────────────────────────────────
prune() {
  local now_epoch week_ago day_ago marker_dir
  now_epoch="$(date -u +%s)"
  week_ago="$(( now_epoch - WEEKLY_RETENTION_WEEKS * 7 * 86400 ))"
  day_ago="$(( now_epoch - DAILY_RETENTION_DAYS * 86400 ))"
  marker_dir="$BACKUP_ROOT/.retention-markers"
  mkdir -p "$marker_dir"

  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{6}' | while IFS= read -r d; do
    [ -n "$d" ] || continue
    base="$(basename "$d")"
    d_epoch="$(date -u -d "${base:0:8} ${base:9:2}:${base:11:2}:${base:13:2}" +%s 2>/dev/null || echo 0)"
    [ "$d_epoch" -gt 0 ] || continue

    # Keep everything within daily retention.
    [ "$d_epoch" -ge "$day_ago" ] && continue

    # Keep one weekly snapshot per week (oldest run of the week).
    week_start="$(( (d_epoch / 86400 / 7) * 7 * 86400 ))"
    marker="$marker_dir/.weekly-kept.$week_start"
    if [ "$d_epoch" -ge "$week_ago" ] && [ ! -e "$marker" ]; then
      touch "$marker"
      continue
    fi

    log "prune: $d"
    rm -rf -- "$d"
  done
}
prune

# ── Off-site: Cloudflare R2 via the S3 API ─────────────────────────────────
if [ -n "$R2_ACCOUNT" ] && [ -n "$R2_BUCKET" ] && [ -n "$R2_KEY" ] && [ -n "$R2_SECRET" ]; then
  command -v aws >/dev/null ||
    die "R2 configured but the aws CLI is missing — install it or unset the R2 vars"
  export AWS_ACCESS_KEY_ID="$R2_KEY"
  export AWS_SECRET_ACCESS_KEY="$R2_SECRET"
  log "uploading to R2 s3://${R2_BUCKET}/pg/$TS/ …"
  aws s3 cp --recursive "$DEST" "s3://${R2_BUCKET}/pg/$TS/" \
    --endpoint-url "https://${R2_ACCOUNT}.r2.cloudflarestorage.com" ||
    die "R2 upload FAILED — local copies kept at $DEST"
  log "R2 upload complete"
else
  log "NOTICE: R2 not configured — backups are LOCAL ONLY ($BACKUP_ROOT)."
fi

log "done: $(du -sh "$DEST" | cut -f1) in $DEST"
