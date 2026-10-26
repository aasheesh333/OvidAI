#!/usr/bin/env bash
# Verify that a pg_backup.sh dump is restorable by restoring it to a scratch
# database and comparing row count + per-table checksums.
#
# Usage:
#   pg_verify_restore.sh --dump PATH --source-db SRC --target-db TGT [conn opts]
#
# Connection (host mode is default):
#   --host HOST          [127.0.0.1]
#   --port PORT          [5432]
#   --user USER          [postgres]
#   --password PASSWORD
#   --container NAME     if given, restore inside this docker container
#
# Non-zero exit on mismatch or restore failure.
set -euo pipefail

DUMP=""
SOURCE_DB=""
TARGET_DB=""
HOST="127.0.0.1"
PORT="5432"
USER="postgres"
PASSWORD="${PGPASSWORD:-}"
CONTAINER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dump) DUMP="$2"; shift 2 ;;
    --source-db) SOURCE_DB="$2"; shift 2 ;;
    --target-db) TARGET_DB="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -n "$DUMP" ] || { echo "--dump required" >&2; exit 2; }
[ -n "$SOURCE_DB" ] || { echo "--source-db required" >&2; exit 2; }
[ -n "$TARGET_DB" ] || { echo "--target-db required" >&2; exit 2; }
[ -f "$DUMP" ] || { echo "dump file not found: $DUMP" >&2; exit 2; }
[ "$SOURCE_DB" != "$TARGET_DB" ] || { echo "source and target must differ" >&2; exit 2; }

log() { printf '[verify %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '[verify] FATAL: %s\n' "$*" >&2; exit 1; }

needs_docker() { [ -n "$CONTAINER" ]; }

psql_host() {
  local db="$1"; shift
  PGPASSWORD="$PASSWORD" psql -h "$HOST" -p "$PORT" -U "$USER" -d "$db" -v ON_ERROR_STOP=1 -tA "$@"
}

psql_docker() {
  local db="$1"; shift
  docker exec -i "$CONTAINER" \
    -e PGPASSWORD="$PASSWORD" \
    -e PGUSER="$USER" \
    -e PGDATABASE="$db" \
    psql -v ON_ERROR_STOP=1 -tA "$@"
}

psql_cmd() { needs_docker && psql_docker "$@" || psql_host "$@"; }

# ── Collect metrics for a database ─────────────────────────────────────────
metrics_file() {
  local db="$1" file="$2"
  local tables tab checksum rows
  tables="$(psql_cmd "$db" -c "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY table_name")"
  : > "$file"
  for tab in $tables; do
    rows="$(psql_cmd "$db" -c "SELECT count(*)::text FROM \"$tab\"")"
    if [ "$rows" = "0" ]; then
      checksum="empty"
    else
      checksum="$(psql_cmd "$db" -c "SELECT COALESCE(md5(string_agg(hash, ',' ORDER BY hash)), 'empty') FROM (SELECT md5(row_to_json(t.*)::text) AS hash FROM \"$tab\" t) q")"
    fi
    printf '%s\t%s\t%s\n' "$tab" "$rows" "$checksum" >> "$file"
  done
}

# ── Source metrics ─────────────────────────────────────────────────────────
SOURCE_METRICS="$(mktemp)"
trap 'rm -f "$SOURCE_METRICS"' EXIT
log "collecting source metrics from $SOURCE_DB"
metrics_file "$SOURCE_DB" "$SOURCE_METRICS"
log "source metrics:"
while IFS=$'\t' read -r tab rows checksum; do
  log "  $tab rows=$rows checksum=$checksum"
done < "$SOURCE_METRICS"

# ── Prepare target ─────────────────────────────────────────────────────────
log "preparing target database $TARGET_DB"
psql_cmd postgres -qc "DROP DATABASE IF EXISTS \"$TARGET_DB\" WITH (FORCE)" 2>/dev/null || true
psql_cmd postgres -qc "CREATE DATABASE \"$TARGET_DB\""

# ── Restore ──────────────────────────────────────────────────────────────────
log "restoring $DUMP → $TARGET_DB"
START_RESTORE=$(date +%s%3N)
zstd -dc "$DUMP" | psql_cmd "$TARGET_DB" -q -f -
END_RESTORE=$(date +%s%3N)
RESTORE_MS=$((END_RESTORE - START_RESTORE))
log "restore completed in ${RESTORE_MS}ms"

# ── Target metrics ─────────────────────────────────────────────────────────
TARGET_METRICS="$(mktemp)"
trap 'rm -f "$SOURCE_METRICS" "$TARGET_METRICS"' EXIT
log "collecting target metrics from $TARGET_DB"
metrics_file "$TARGET_DB" "$TARGET_METRICS"
log "target metrics:"
while IFS=$'\t' read -r tab rows checksum; do
  log "  $tab rows=$rows checksum=$checksum"
done < "$TARGET_METRICS"

# ── Compare ──────────────────────────────────────────────────────────────────
log "comparing source vs target metrics"
if ! diff -u "$SOURCE_METRICS" "$TARGET_METRICS" > /tmp/verify-diff.txt; then
  cat /tmp/verify-diff.txt >&2
  die "source/target mismatch detected"
fi
log "verification OK: $SOURCE_DB -> $TARGET_DB"
