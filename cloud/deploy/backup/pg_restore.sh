#!/usr/bin/env bash
# Restore a pg_backup.sh-produced .dump.zst into a Postgres database.
#
# Usage:
#   pg_restore.sh --dump <path> --target-db <name> [options]
#
# Required:
#   --dump PATH          compressed dump file to restore
#   --target-db NAME     database to restore into (must exist or --create)
#
# Connection (choose container mode or host mode; container mode is default):
#   --container NAME     docker container name [ovid-gateway-postgres-1]
#   --host HOST          Postgres host (enables host mode)
#   --port PORT          [5432]
#   --user USER          [postgres]
#   --password PASSWORD
#   --admin-db NAME      database used for CREATE/DROP [postgres]
#
# Behaviour:
#   --create             create the target database if it does not exist
#   --drop               DROP the target database before restore (DANGER)
#   --force              with --drop, use WITH (FORCE)
#   --verbose            show psql output instead of -q
#
# Non-zero exit on any failure.
set -euo pipefail

DUMP=""
TARGET_DB=""
CONTAINER="ovid-gateway-postgres-1"
HOST=""
PORT="5432"
USER="postgres"
PASSWORD="${PGPASSWORD:-}"
ADMIN_DB="postgres"
CREATE=0
DROP=0
FORCE=0
VERBOSE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dump) DUMP="$2"; shift 2 ;;
    --target-db) TARGET_DB="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --admin-db) ADMIN_DB="$2"; shift 2 ;;
    --create) CREATE=1; shift ;;
    --drop) DROP=1; shift ;;
    --force) FORCE=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -n "$DUMP" ] || { echo "--dump required" >&2; exit 2; }
[ -n "$TARGET_DB" ] || { echo "--target-db required" >&2; exit 2; }
[ -f "$DUMP" ] || { echo "dump file not found: $DUMP" >&2; exit 2; }

log() { printf '[restore %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '[restore] FATAL: %s\n' "$*" >&2; exit 1; }

needs_docker() { [ -z "$HOST" ]; }

psql_admin() {
  if needs_docker; then
    docker exec -i "$CONTAINER" \
      -e PGPASSWORD="$PASSWORD" \
      -e PGUSER="$USER" \
      -e PGDATABASE="$ADMIN_DB" \
      psql -v ON_ERROR_STOP=1 "$@"
  else
    PGPASSWORD="$PASSWORD" psql -h "$HOST" -p "$PORT" -U "$USER" -d "$ADMIN_DB" -v ON_ERROR_STOP=1 "$@"
  fi
}

psql_restore() {
  if needs_docker; then
    docker exec -i "$CONTAINER" \
      -e PGPASSWORD="$PASSWORD" \
      -e PGUSER="$USER" \
      -e PGDATABASE="$TARGET_DB" \
      psql -v ON_ERROR_STOP=1 "$@"
  else
    PGPASSWORD="$PASSWORD" psql -h "$HOST" -p "$PORT" -U "$USER" -d "$TARGET_DB" -v ON_ERROR_STOP=1 "$@"
  fi
}

# ── Drop target if requested ───────────────────────────────────────────────
if [ "$DROP" = "1" ]; then
  force_clause=""
  [ "$FORCE" = "1" ] && force_clause=" WITH (FORCE)"
  log "DROPPING database $TARGET_DB$force_clause"
  psql_admin -qc "DROP DATABASE IF EXISTS \"$TARGET_DB\"$force_clause" || die "drop failed"
  CREATE=1
fi

# ── Create target if requested ───────────────────────────────────────────────
if [ "$CREATE" = "1" ]; then
  log "creating database $TARGET_DB"
  psql_admin -qc "CREATE DATABASE \"$TARGET_DB\"" || die "create failed"
fi

# ── Restore ──────────────────────────────────────────────────────────────────
log "restoring $DUMP → $TARGET_DB"
if [ "$VERBOSE" = "1" ]; then
  zstd -dc "$DUMP" | psql_restore -f -
else
  zstd -dc "$DUMP" | psql_restore -q -f -
fi
log "restore complete: $TARGET_DB"
