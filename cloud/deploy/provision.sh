#!/usr/bin/env bash
# Ovid Cloud provisioning — idempotent, safe to re-run at any time.
#
#   ./provision.sh --dry-run   # validate everything, mutate NOTHING
#   ./provision.sh             # create role/DB if missing → migrate → validate
#
# Runs on the VPS host. Requires:
#   • docker, with the live ovid-gateway stack running (postgres container up);
#   • the cloud/ monorepo BUILT (corepack enable && pnpm install
#     --frozen-lockfile && pnpm -r build) — migrations run from
#     packages/db/dist/migrate-cli.js;
#   • a filled .env next to this script (copy .env.example; DEPLOY.md §2).
#
# What it mutates (real run ONLY, all guarded by existence checks):
#   • Postgres role `ovid_cloud` (LOGIN + password from OVID_CLOUD_DB_PASSWORD)
#   • Postgres database `ovid_cloud` (owner ovid_cloud)
#   • the ovid_cloud schema (drizzle migrations, idempotent journal)
# It NEVER touches other databases/roles, never restarts live containers, and
# never edits anything under /opt/ovid-gateway.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
PG_CONTAINER="${PG_CONTAINER:-ovid-gateway-postgres-1}"
PG_NETWORK="${PG_NETWORK:-ovid-gateway_internal}"
MIGRATE_IMAGE="${MIGRATE_IMAGE:-node:22-alpine}"
DB_NAME="${OVID_CLOUD_DB_NAME:-ovid_cloud}"
DB_ROLE="${OVID_CLOUD_DB_ROLE:-ovid_cloud}"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      echo "usage: provision.sh [--dry-run]"
      exit 0
      ;;
    *)
      echo "provision.sh: unknown argument '$arg' (usage: provision.sh [--dry-run])" >&2
      exit 2
      ;;
  esac
done

log() { printf '[provision] %s\n' "$*"; }
die() {
  printf '[provision] ERROR: %s\n' "$*" >&2
  exit 1
}
dry() { [ "$DRY_RUN" = 1 ] && printf '[provision] DRY-RUN: %s\n' "$*"; return 0; }

[ "$DB_NAME" ] && [[ "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]] ||
  die "DB name '$DB_NAME' is not a safe postgres identifier"
[ "$DB_ROLE" ] && [[ "$DB_ROLE" =~ ^[a-z_][a-z0-9_]*$ ]] ||
  die "role name '$DB_ROLE' is not a safe postgres identifier"

# ── 1. Env file: present, complete, no placeholders ────────────────────────
[ -f "$ENV_FILE" ] ||
  die "no env file at $ENV_FILE — copy .env.example to .env, fill it, chmod 600 (DEPLOY.md §2)"
log "using env file: $ENV_FILE"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
for var in DATABASE_URL OVID_CLOUD_DB_PASSWORD REDIS_Q_PASSWORD OVID_DEFAULT_MODEL; do
  [ -n "${!var:-}" ] || die "$var missing/empty in $ENV_FILE"
  case "${!var}" in
  *CHANGE_ME*) die "$var still contains the CHANGE_ME placeholder in $ENV_FILE" ;;
  esac
done
# The password is interpolated into a single-quoted SQL literal below; keep the
# alphabet safe (openssl rand -hex 24 satisfies this).
[[ "$OVID_CLOUD_DB_PASSWORD" =~ ^[A-Za-z0-9_-]+$ ]] ||
  die "OVID_CLOUD_DB_PASSWORD must be alphanumeric/-/_ only (generate: openssl rand -hex 24)"
[[ "$DATABASE_URL" == *"@${PG_CONTAINER}:5432/${DB_NAME}"* ]] ||
  log "WARNING: DATABASE_URL does not point at ${PG_CONTAINER}:5432/${DB_NAME} — migrations will follow DATABASE_URL"

# ── 2. Host + live infra reachable (read-only checks) ──────────────────────
command -v docker >/dev/null || die "docker not found on PATH"
docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER" ||
  die "postgres container '$PG_CONTAINER' is not running"
docker network inspect "$PG_NETWORK" >/dev/null 2>&1 ||
  die "docker network '$PG_NETWORK' missing — is the live ovid-gateway stack up?"
[ -f "$CLOUD_DIR/packages/db/dist/migrate-cli.js" ] ||
  die "packages/db/dist/migrate-cli.js missing — build first: cd $CLOUD_DIR && pnpm install --frozen-lockfile && pnpm -r build"
[ -f "$CLOUD_DIR/pnpm-lock.yaml" ] || die "$CLOUD_DIR does not look like the cloud/ monorepo root"
FB_PATH="${FIREBASE_CREDENTIALS_HOST_PATH:-/opt/ovid-gateway/firebase-admin.json}"
if [ ! -f "$FB_PATH" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    log "WARNING: firebase credentials file not found at $FB_PATH (gateway would fail to bind-mount it)"
  else
    die "firebase credentials file not found at $FB_PATH (compose bind-mounts it into the gateway)"
  fi
fi

# Read-only queries run INSIDE the live postgres container as its superuser
# ($POSTGRES_USER is resolved there — this script never handles it; the
# :-postgres fallback covers images started without POSTGRES_USER set).
psql_live() {
  docker exec "$PG_CONTAINER" sh -c \
    'psql -U "${POSTGRES_USER:-postgres}" -d postgres -Atqc "$1"' _ "$1"
}

ROLE_EXISTS="$(psql_live "SELECT 1 FROM pg_roles WHERE rolname='$DB_ROLE'")"
DB_EXISTS="$(psql_live "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")"
log "role '$DB_ROLE' exists: $([ -n "$ROLE_EXISTS" ] && echo yes || echo no)"
log "database '$DB_NAME' exists: $([ -n "$DB_EXISTS" ] && echo yes || echo no)"

# ── 3. Role + database (idempotent; dry-run reports only) ──────────────────
if [ -z "$ROLE_EXISTS" ]; then
  dry "would CREATE ROLE $DB_ROLE (LOGIN, password from OVID_CLOUD_DB_PASSWORD)"
  if [ "$DRY_RUN" = 0 ]; then
    log "creating role $DB_ROLE …"
    docker exec -e NEW_ROLE="$DB_ROLE" -e NEW_PASS="$OVID_CLOUD_DB_PASSWORD" \
      "$PG_CONTAINER" sh -c \
      'psql -U "${POSTGRES_USER:-postgres}" -d postgres -v ON_ERROR_STOP=1 -qc "CREATE ROLE $NEW_ROLE LOGIN PASSWORD '"'"'$NEW_PASS'"'"'"' ||
      die "CREATE ROLE failed"
  fi
else
  dry "role exists — leaving it untouched (password rotation is a manual ALTER ROLE)"
fi

if [ -z "$DB_EXISTS" ]; then
  dry "would CREATE DATABASE $DB_NAME OWNER $DB_ROLE"
  if [ "$DRY_RUN" = 0 ]; then
    log "creating database $DB_NAME …"
    docker exec "$PG_CONTAINER" sh -c \
      "psql -U \"\${POSTGRES_USER:-postgres}\" -d postgres -v ON_ERROR_STOP=1 -qc 'CREATE DATABASE $DB_NAME OWNER $DB_ROLE'" ||
      die "CREATE DATABASE failed"
  fi
else
  dry "database exists — leaving it untouched"
fi

# ── 4. Migrations ──────────────────────────────────────────────────────────
# DATABASE_URL's hostname ($PG_CONTAINER) only resolves on the docker network,
# so the CLI runs in an ephemeral node container attached to it — the repo is
# mounted READ-ONLY, the container is --rm, and nothing live is modified.
if [ "$DRY_RUN" = 1 ]; then
  dry "would run: docker run --rm --network $PG_NETWORK -v $CLOUD_DIR:$CLOUD_DIR:ro -w $CLOUD_DIR/packages/db $MIGRATE_IMAGE node dist/migrate-cli.js \"\$DATABASE_URL\""
  if docker image inspect "$MIGRATE_IMAGE" >/dev/null 2>&1; then
    log "migrate image $MIGRATE_IMAGE present locally"
  else
    log "NOTE: migrate image $MIGRATE_IMAGE not local — real run would pull it"
  fi
else
  log "applying migrations (ephemeral $MIGRATE_IMAGE container on $PG_NETWORK) …"
  docker run --rm --network "$PG_NETWORK" \
    -v "$CLOUD_DIR:$CLOUD_DIR:ro" -w "$CLOUD_DIR/packages/db" \
    "$MIGRATE_IMAGE" node dist/migrate-cli.js "$DATABASE_URL" ||
    die "migrations failed"
fi

# ── 5. Compose validation (read-only in both modes) ────────────────────────
log "validating compose config …"
# The compose services declare `env_file: .env` NEXT TO the compose file —
# compose requires that file for config/up even when --env-file points
# elsewhere (--env-file only feeds ${…} interpolation).
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  if [ "$ENV_FILE" != "$SCRIPT_DIR/.env" ]; then
    die "compose needs the deploy env at $SCRIPT_DIR/.env (service-level env_file) — copy or symlink $ENV_FILE there"
  fi
  die "compose needs the deploy env at $SCRIPT_DIR/.env (service-level env_file)"
fi
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config -q ||
  die "docker compose config rejected $COMPOSE_FILE (with $ENV_FILE)"
log "compose config OK"

# ── 6. Next steps ──────────────────────────────────────────────────────────
if [ "$DRY_RUN" = 1 ]; then
  log "DRY-RUN OK — nothing was mutated."
else
  cat <<EOF
[provision] done. Next steps (DEPLOY.md):
  1. Start the stack:      cd $SCRIPT_DIR && docker compose up -d --build
  2. Watch health:         docker compose ps   (gateway → healthy)
  3. Route traffic:        insert caddy-snippet.conf into the live Caddyfile
                           (§6: backup → insert → caddy validate → reload)
  4. Verify:               curl -sf https://api.ovidsi.com/cloud/v1/health
  5. Backups:              install ovid-cloud-backup.{service,timer} (§8)
EOF
fi
