#!/usr/bin/env bash
# Ovid Cloud P10 — isolated staging composition control.
#
# This script is the ONLY supported entry point for the staging stack used by
# P10 Tasks 4–7, 9, 10 and 14. It refuses to operate on any production-valued
# environment (`guard`), keeps every published port loopback-only, and prints
# a read-only live-stack check before and after every mutating command.
#
# It deliberately does NOT touch /opt, the live `ovid-gateway` compose
# project, the live Caddyfile, the production worker, or the prod uid range.
#
# Usage: cloud/scripts/staging.sh <command> [options]   (see `help`)
# Safe dry validation: `bash -n cloud/scripts/staging.sh`.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd -- "$CLOUD_DIR/.." && pwd)"
DEPLOY_DIR="$CLOUD_DIR/deploy"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose.staging.yml"
PROJECT="ovid-cloud-staging"
DEFAULT_ENV_FILE="$DEPLOY_DIR/.env.staging"
DEFAULT_MINT_ENV_FILE="$DEPLOY_DIR/.env.staging.mint"

ENV_FILE="${STAGING_ENV_FILE:-$DEFAULT_ENV_FILE}"
MINT_ENV_FILE="${STAGING_MINT_ENV_FILE:-$DEFAULT_MINT_ENV_FILE}"

# F1: logs go to STDERR so machine-readable stdout stays parseable. In
# particular `pressure-mount` prints ONLY the mount path on stdout (the
# @ovid/load chaos harness parses it), and `env` prints only KEY=VALUE lines.
log() { printf '[staging] %s\n' "$*" >&2; }

die() {
  printf '[staging] ERROR: %s\n' "$*" >&2
  exit 2
}

guard_fail() {
  local var="$1"
  shift
  printf '[staging] GUARD FAIL: %s: %s\n' "$var" "$*" >&2
  exit 2
}

usage() {
  cat <<'EOF'
usage: staging.sh <command> [options]

  guard [--env-file <path>]        validate staging isolation (read-only;
                                   exits 2 and names the variable on any
                                   production-valued or non-loopback value)
  env                              print the resolved staging env as
                                   KEY=VALUE (consumed by @ovid/load)
  up [--auth test|firebase]        guard -> compose up -> migrate -> wait for
                                   the mint boot re-sync and gateway health
  down [-v]                        stop the staging compose project (named
                                   volumes are kept unless -v)
  mock-start | mock-stop           start/stop the Task-4 mock LiteLLM on
                                   0.0.0.0:14000 (one of two host
                                   non-loopback listeners; the other is the
                                   worker file service on 0.0.0.0:18093)
  worker-start [--env K=V ...]     start the host staging worker (root is
                                   required for bwrap/cgroups)
  worker-stop [graceful|kill]      stop the host staging worker
  pressure-mount [MB] | pressure-unmount
                                   P10 Task 7: mount/remove a loopback ext4
                                   fixture at /mnt/ovid-pressure (default
                                   256MB; never fills the host disk)
  live-check [--baseline <file> | --write-baseline <file>]
                                   read-only live-stack health/StartedAt
                                   snapshot or unchanged assertion
  help                             this text

Env overrides: STAGING_ENV_FILE / STAGING_MINT_ENV_FILE are accepted ONLY at
their default paths (cloud/deploy/.env.staging[.mint]); any other value is
rejected because compose hardcodes those `env_file:` paths.
EOF
}

# ── env loading / URL parsing ───────────────────────────────────────────────

load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || die "env file not found: $file (copy cloud/deploy/.env.staging.example)"
  # Plain KEY=VALUE shell syntax by contract. `set -a` exports every value so
  # the backgrounded worker/mock inherit the staging env without re-parsing.
  set -a
  # shellcheck disable=SC1090
  . "$file"
  set +a
}

# L2: stop paths must honour a custom pidfile from the env file, but must
# still work when the file is already gone. Source it when present, else fall
# back to the built-in default.
load_env_if_present() {
  if [[ -f "$ENV_FILE" ]]; then
    load_env_file "$ENV_FILE"
    return 0
  fi
  log "env file $ENV_FILE missing — using default pidfiles"
  return 1
}

# L2: never signal a reused/unrelated PID. Prove the live process is the one
# this script started (cmdline +, for the worker, its cwd) before killing it.
verify_pid_identity() {
  local pid="$1" kind="$2" cmdline cwd
  [[ "$pid" =~ ^[0-9]+$ ]] \
    || guard_fail "$kind-stop" "pidfile contains a non-numeric pid ('$pid')"
  cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  case "$kind" in
    worker)
      [[ "$cmdline" == *"dist/main.js"* ]] \
        || guard_fail "worker-stop" "pid $pid is not the staging worker (cmdline: '${cmdline:-<unreadable>}') — refusing to signal"
      cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
      [[ "$cwd" == "$CLOUD_DIR/apps/worker" ]] \
        || guard_fail "worker-stop" "pid $pid cwd '$cwd' is not $CLOUD_DIR/apps/worker — refusing to signal"
      ;;
    mock)
      [[ "$cmdline" == *"mockServer.js"* && "$cmdline" == *"--port 14000"* ]] \
        || guard_fail "mock-stop" "pid $pid is not the staging mock LiteLLM (cmdline: '${cmdline:-<unreadable>}') — refusing to signal"
      ;;
    *)
      guard_fail "$kind-stop" "unknown process kind"
      ;;
  esac
}

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || guard_fail "$name" "is required"
}

# Lexically normalize a path-like value without touching the filesystem:
# collapse duplicate slashes and drop "." segments. ".." is rejected by
# require_exact_path BEFORE this runs, so traversal can never survive it.
normalize_path() {
  local value="$1" out="" segment absolute=0
  local -a parts=()
  [[ "$value" == /* ]] && absolute=1
  local IFS=/
  read -r -a parts <<< "$value"
  for segment in "${parts[@]}"; do
    [[ -z "$segment" || "$segment" == "." ]] && continue
    out="${out:+$out/}$segment"
  done
  if (( absolute )); then
    printf '/%s' "$out"
  else
    printf '%s' "$out"
  fi
}

# Require VAR to be present and, after lexical normalization, EXACTLY the
# expected staging literal. Two independent gates:
#   1. ".." anywhere is rejected outright (H2 — no normalization may climb
#      from a staging prefix into a live path);
#   2. the normalized value must equal the expected literal (H1 — omission
#      or a sibling path cannot fall back to a live default/prefix).
# One helper for every path-like variable, so a future variable cannot
# reintroduce the prefix-matching bug.
require_exact_path() {
  local name="$1" expected="$2" value normalized expected_norm
  require_var "$name"
  value="${!name}"
  [[ "$value" != *".."* ]] \
    || guard_fail "$name" "must not contain '..' path traversal (got '$value')"
  normalized="$(normalize_path "$value")"
  expected_norm="$(normalize_path "$expected")"
  [[ "$normalized" == "$expected_norm" ]] \
    || guard_fail "$name" "must be exactly '$expected' after path normalization (got '$value' -> '$normalized')"
}

# postgres://user:pass@host:port/db -> DB_USER / DB_HOST / DB_PORT / DB_NAME
db_url_parts() {
  local url="$1" rest authority hostport userinfo
  rest="${url#*://}"
  authority="${rest%%/*}"
  DB_NAME="${rest#*/}"
  DB_NAME="${DB_NAME%%\?*}"
  if [[ "$authority" == *"@"* ]]; then
    userinfo="${authority%@*}"
    hostport="${authority##*@}"
    DB_USER="${userinfo%%:*}"
  else
    DB_USER=""
    hostport="$authority"
  fi
  DB_HOST="${hostport%%:*}"
  if [[ "$hostport" == *:* ]]; then DB_PORT="${hostport##*:}"; else DB_PORT=""; fi
}

# redis://[:pass@]host:port[/db] -> R_HOST / R_PORT / R_DB
redis_url_parts() {
  local url="$1" rest authority hostport
  rest="${url#*://}"
  authority="${rest%%/*}"
  R_DB=""
  if [[ "$rest" == */* ]]; then
    R_DB="${rest#*/}"
    R_DB="${R_DB%%\?*}"
  fi
  hostport="${authority##*@}"
  R_HOST="${hostport%%:*}"
  if [[ "$hostport" == *:* ]]; then R_PORT="${hostport##*:}"; else R_PORT="6379"; fi
}

# http(s)://host:port/path -> host:port
http_hostport() {
  local url="$1" rest
  rest="${url#*://}"
  printf '%s' "${rest%%/*}"
}

# ── guard: refuse any production-valued staging env ────────────────────────

guard_env_file() {
  local file="$1"

  # M3: the compose services hardcode `env_file: [.env.staging]` /
  # `[.env.staging.mint]`; `--env-file` only affects interpolation. A
  # validated STAGING_ENV_FILE override therefore would NOT be the file the
  # containers load. Rejecting the override (instead of interpolating it)
  # keeps one source of truth: the validated file is always the loaded file.
  if [[ -n "${STAGING_ENV_FILE:-}" && "$STAGING_ENV_FILE" != "$DEFAULT_ENV_FILE" ]]; then
    guard_fail "STAGING_ENV_FILE" "must be the default $DEFAULT_ENV_FILE (compose hardcodes env_file: .env.staging); got '$STAGING_ENV_FILE'"
  fi
  if [[ -n "${STAGING_MINT_ENV_FILE:-}" && "$STAGING_MINT_ENV_FILE" != "$DEFAULT_MINT_ENV_FILE" ]]; then
    guard_fail "STAGING_MINT_ENV_FILE" "must be the default $DEFAULT_MINT_ENV_FILE (compose hardcodes env_file: .env.staging.mint); got '$STAGING_MINT_ENV_FILE'"
  fi

  load_env_file "$file"

  require_var NODE_ENV
  [[ "$NODE_ENV" != "production" ]] || guard_fail "NODE_ENV" "must not be production (staging only)"

  # The live compose project is `ovid-gateway`; staging is always
  # `ovid-cloud-staging` (`-p` in `compose()` wins, but an env-file override
  # would be a production smell worth refusing loudly).
  if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
    [[ "$COMPOSE_PROJECT_NAME" == "$PROJECT" ]] \
      || guard_fail "COMPOSE_PROJECT_NAME" "must be $PROJECT (got '$COMPOSE_PROJECT_NAME'); the live project is ovid-gateway"
  fi

  require_var OVID_AUTH_MODE
  [[ "$OVID_AUTH_MODE" == "test" || "$OVID_AUTH_MODE" == "firebase" ]] \
    || guard_fail "OVID_AUTH_MODE" "must be test or firebase (got '$OVID_AUTH_MODE')"

  # ── Postgres: dedicated staging container/database only ──
  require_var DATABASE_URL
  db_url_parts "$DATABASE_URL"
  [[ "$DB_NAME" == "ovid_cloud_staging" ]] \
    || guard_fail "DATABASE_URL" "database must be ovid_cloud_staging (got '$DB_NAME'); prod is ovid_cloud"
  if [[ "$DB_HOST" == "127.0.0.1" || "$DB_HOST" == "localhost" ]]; then
    [[ "$DB_PORT" == "15432" ]] \
      || guard_fail "DATABASE_URL" "loopback staging Postgres must be 127.0.0.1:15432 (got $DB_HOST:$DB_PORT)"
  elif [[ "$DB_HOST" == "postgres" ]]; then
    [[ "$DB_PORT" == "5432" || -z "$DB_PORT" ]] \
      || guard_fail "DATABASE_URL" "compose service Postgres must be postgres:5432"
  else
    guard_fail "DATABASE_URL" "host must be 127.0.0.1:15432 or the compose service 'postgres' (got '$DB_HOST')"
  fi
  [[ "$DB_USER" != "ovid_cloud" ]] \
    || guard_fail "DATABASE_URL" "prod user 'ovid_cloud' is forbidden"
  [[ "$DATABASE_URL" != *"CHANGE_ME"* ]] \
    || guard_fail "DATABASE_URL" "placeholder value (CHANGE_ME)"

  # ── redis-q: dedicated staging instance only ──
  require_var REDIS_Q_URL
  redis_url_parts "$REDIS_Q_URL"
  if [[ "$R_HOST" == "127.0.0.1" || "$R_HOST" == "localhost" ]]; then
    [[ "$R_PORT" == "16379" ]] \
      || guard_fail "REDIS_Q_URL" "loopback staging redis-q must be 127.0.0.1:16379 (got $R_HOST:$R_PORT)"
  elif [[ "$R_HOST" == "redis-q" ]]; then
    [[ "$R_PORT" == "6379" ]] \
      || guard_fail "REDIS_Q_URL" "compose service redis-q must be redis-q:6379"
  else
    guard_fail "REDIS_Q_URL" "host must be 127.0.0.1:16379 or redis-q:6379 (got '$R_HOST:$R_PORT')"
  fi
  [[ -z "$R_DB" || "$R_DB" == "0" ]] \
    || guard_fail "REDIS_Q_URL" "must not select a non-zero db (got '$R_DB')"
  require_var REDIS_Q_PASSWORD
  [[ "$REDIS_Q_PASSWORD" != "CHANGE_ME" ]] \
    || guard_fail "REDIS_Q_PASSWORD" "placeholder value (CHANGE_ME)"

  # ── staging mint db2 projection ──
  require_var REDIS_MINT_URL
  redis_url_parts "$REDIS_MINT_URL"
  if [[ "$R_HOST" == "127.0.0.1" || "$R_HOST" == "localhost" ]]; then
    [[ "$R_PORT" == "16380" ]] \
      || guard_fail "REDIS_MINT_URL" "loopback staging redis-mint must be 127.0.0.1:16380 (got $R_HOST:$R_PORT)"
  elif [[ "$R_HOST" == "redis-mint" ]]; then
    [[ "$R_PORT" == "6379" ]] \
      || guard_fail "REDIS_MINT_URL" "compose service redis-mint must be redis-mint:6379"
  else
    guard_fail "REDIS_MINT_URL" "host must be 127.0.0.1:16380 or redis-mint:6379 (got '$R_HOST:$R_PORT'); prod uses 6392/ovid-gateway-redis-1"
  fi
  [[ "$R_DB" == "2" ]] \
    || guard_fail "REDIS_MINT_URL" "must select db 2 (staging mint projection; got '${R_DB:-<none>}')"

  # ── internal mint surface (P9 Task 9) ──
  require_var OVID_INTERNAL_MINT_URL
  local internal_hp
  internal_hp="$(http_hostport "$OVID_INTERNAL_MINT_URL")"
  [[ "$internal_hp" == "127.0.0.1:18092" || "$internal_hp" == "mint:8092" ]] \
    || guard_fail "OVID_INTERNAL_MINT_URL" "must be http://127.0.0.1:18092 (host) or http://mint:8092 (container); got '$internal_hp'"
  if [[ -v MINT_BASE_URL ]]; then
    guard_fail "MINT_BASE_URL" "must not be present (the pre-P9 HTTP-mint surface was deleted by P9 Task 9; its presence is a prod/leftover smell)"
  fi

  # ── sandbox identity: distinct root + uid block + cgroup branch ──
  # H1: OVID_CGROUP_BASE is REQUIRED and exact. Omission would fall back to
  # config.ts's LIVE default (`ovid-sandboxes.slice/ovid-worker.service`);
  # a prefix check would also admit traversal (H2). One literal only.
  require_exact_path OVID_WORKSPACES_ROOT "/workspaces-staging"
  require_var OVID_SANDBOX_UID_BASE
  [[ "$OVID_SANDBOX_UID_BASE" == "220000" ]] \
    || guard_fail "OVID_SANDBOX_UID_BASE" "must be 220000 (staging range 220000-229999; got '$OVID_SANDBOX_UID_BASE'); prod is 200000"
  if [[ -n "${OVID_SANDBOX_UID_MAX:-}" ]]; then
    [[ "$OVID_SANDBOX_UID_MAX" == "229999" ]] \
      || guard_fail "OVID_SANDBOX_UID_MAX" "must be 229999 (got '$OVID_SANDBOX_UID_MAX')"
  fi
  require_exact_path OVID_CGROUP_BASE "ovid-sandboxes-staging.slice/ovid-staging-worker.service"

  # ── storage: staging-local fs only; never the prod R2 bucket ──
  if [[ -n "${OVID_STORAGE_BACKEND:-}" ]]; then
    [[ "$OVID_STORAGE_BACKEND" == "fs" ]] \
      || guard_fail "OVID_STORAGE_BACKEND" "staging must use the fs backend (got '$OVID_STORAGE_BACKEND'); never the live R2 bucket"
  fi
  # H2/H3: exact literals, normalized, with ".." rejected. The fs root must
  # match the compose gateway's writable bind mount (docker-compose.staging.yml).
  require_exact_path OVID_FS_STORAGE_ROOT "/workspaces-staging/storage"
  require_exact_path OVID_BROWSER_STATE_DIR "/workspaces-staging/browser-states"
  local r2var
  for r2var in OVID_R2_ACCOUNT_ID OVID_R2_ACCESS_KEY_ID OVID_R2_SECRET_ACCESS_KEY OVID_R2_BUCKET; do
    if [[ -n "${!r2var:-}" ]]; then
      guard_fail "$r2var" "R2 credentials are production storage — forbidden in staging"
    fi
  done

  # ── published addresses: loopback-only (mock bind is 0.0.0.0 by design,
  #    but it is never a *published* staging port; it is a host listener) ──
  require_var STAGING_BIND_ADDRESS
  [[ "$STAGING_BIND_ADDRESS" == "127.0.0.1" ]] \
    || guard_fail "STAGING_BIND_ADDRESS" "every staging publish address must be 127.0.0.1 (got '$STAGING_BIND_ADDRESS')"
  local urlvar url_hp
  for urlvar in STAGING_GATEWAY_URL STAGING_MOCK_LLM_URL; do
    if [[ -n "${!urlvar:-}" ]]; then
      url_hp="$(http_hostport "${!urlvar}")"
      [[ "$url_hp" == 127.0.0.1:* ]] \
        || guard_fail "$urlvar" "must be loopback (127.0.0.1); got '$url_hp'"
    fi
  done

  # ── worker file service: own port (the live worker owns 8091) ──
  require_var OVID_WORKER_FILE_PORT
  [[ "$OVID_WORKER_FILE_PORT" == "18093" ]] \
    || guard_fail "OVID_WORKER_FILE_PORT" "must be 18093 (the live worker owns 8091; got '$OVID_WORKER_FILE_PORT')"

  # ── model routing: the host-bound mock only ──
  require_var OVID_LITELLM_BASE
  local llm_hp
  llm_hp="$(http_hostport "$OVID_LITELLM_BASE")"
  [[ "$llm_hp" == "172.17.0.1:14000" || "$llm_hp" == "host.docker.internal:14000" ]] \
    || guard_fail "OVID_LITELLM_BASE" "must point at the staging mock (172.17.0.1:14000 or host.docker.internal:14000); got '$llm_hp' (live LiteLLM :4000 is forbidden)"
  require_var OVID_DEFAULT_MODEL

  # ── queue prefix / worker knobs ──
  require_var BULL_PREFIX
  [[ "$BULL_PREFIX" == "bull:staging" ]] \
    || guard_fail "BULL_PREFIX" "must be bull:staging (got '$BULL_PREFIX')"
  require_var OVID_RUN_STALE_MS
  [[ "$OVID_RUN_STALE_MS" == "15000" ]] \
    || guard_fail "OVID_RUN_STALE_MS" "must be 15000 (got '$OVID_RUN_STALE_MS')"
  require_var OVID_MAX_ACTIVE_SANDBOXES
  [[ "$OVID_MAX_ACTIVE_SANDBOXES" == "24" ]] \
    || guard_fail "OVID_MAX_ACTIVE_SANDBOXES" "must be 24 (got '$OVID_MAX_ACTIVE_SANDBOXES')"
  require_var MAX_LIVE_BROWSERS
  [[ "$MAX_LIVE_BROWSERS" == "4" ]] \
    || guard_fail "MAX_LIVE_BROWSERS" "must be 4 (got '$MAX_LIVE_BROWSERS')"
  require_var OVID_MAX_WARM_GB
  [[ "$OVID_MAX_WARM_GB" == "8" ]] \
    || guard_fail "OVID_MAX_WARM_GB" "must be 8 (got '$OVID_MAX_WARM_GB')"

  # ── shared secrets ──
  require_var OVID_INTERNAL_API_SECRET
  [[ ${#OVID_INTERNAL_API_SECRET} -ge 32 ]] \
    || guard_fail "OVID_INTERNAL_API_SECRET" "must be at least 32 bytes (got ${#OVID_INTERNAL_API_SECRET})"
  [[ "$OVID_INTERNAL_API_SECRET" != *"CHANGE_ME"* ]] \
    || guard_fail "OVID_INTERNAL_API_SECRET" "placeholder value (CHANGE_ME)"
  if [[ -n "${OVID_INTERNAL_TOKEN:-}" ]]; then
    [[ ${#OVID_INTERNAL_TOKEN} -ge 32 ]] \
      || guard_fail "OVID_INTERNAL_TOKEN" "must be at least 32 bytes (got ${#OVID_INTERNAL_TOKEN})"
  fi
  if [[ -n "${OVID_MASTER_KEY:-}" ]]; then
    [[ "$OVID_MASTER_KEY" =~ ^[0-9a-fA-F]{64}$ ]] \
      || guard_fail "OVID_MASTER_KEY" "must be exactly 64 hex characters"
  fi
}

# Validate `.env.staging.mint` in a subshell so its DATABASE_URL/REDIS_DB2_URL
# do not overwrite the host-side view used by `up`/`worker-start`.
guard_mint_env_file() {
  local file="$1" expected_secret="$2"
  [[ -f "$file" ]] || die "mint env file not found: $file (copy cloud/deploy/.env.staging.mint.example)"
  (
    set -a
    # shellcheck disable=SC1090
    . "$file"
    set +a

    require_var DATABASE_URL
    db_url_parts "$DATABASE_URL"
    [[ "$DB_NAME" == "ovid_cloud_staging" ]] \
      || guard_fail "DATABASE_URL" "mint must use the staging database (got '$DB_NAME')"
    [[ "$DB_HOST" == "postgres" || "$DB_HOST" == "127.0.0.1" || "$DB_HOST" == "localhost" ]] \
      || guard_fail "DATABASE_URL" "mint host must be the staging service 'postgres' or loopback"
    [[ "$DB_PORT" == "5432" || "$DB_PORT" == "15432" || -z "$DB_PORT" ]] \
      || guard_fail "DATABASE_URL" "mint Postgres port must be 5432 (container) or 15432 (host)"

    require_var REDIS_DB2_URL
    redis_url_parts "$REDIS_DB2_URL"
    if [[ "$R_HOST" == "127.0.0.1" || "$R_HOST" == "localhost" ]]; then
      [[ "$R_PORT" == "16380" ]] \
        || guard_fail "REDIS_DB2_URL" "loopback staging redis-mint must be 127.0.0.1:16380"
    elif [[ "$R_HOST" == "redis-mint" ]]; then
      [[ "$R_PORT" == "6379" ]] \
        || guard_fail "REDIS_DB2_URL" "compose service redis-mint must be redis-mint:6379"
    else
      guard_fail "REDIS_DB2_URL" "host must be 127.0.0.1:16380 or redis-mint:6379 (got '$R_HOST:$R_PORT')"
    fi
    [[ "$R_DB" == "2" ]] || guard_fail "REDIS_DB2_URL" "must select db 2"

    require_var LITELLM_BASE
    local hp
    hp="$(http_hostport "$LITELLM_BASE")"
    [[ "$hp" == "172.17.0.1:14000" || "$hp" == "host.docker.internal:14000" ]] \
      || guard_fail "LITELLM_BASE" "mint must use the mock LiteLLM admin stub (got '$hp'; live :4000 forbidden)"
    [[ "$LITELLM_BASE" != *"ovid-gateway-litellm-1"* ]] \
      || guard_fail "LITELLM_BASE" "live LiteLLM container name is forbidden"

    require_var OVID_INTERNAL_API_SECRET
    [[ "$OVID_INTERNAL_API_SECRET" == "$expected_secret" ]] \
      || guard_fail "OVID_INTERNAL_API_SECRET" "must match cloud/deploy/.env.staging"
    [[ "$OVID_INTERNAL_API_SECRET" != *"CHANGE_ME"* ]] \
      || guard_fail "OVID_INTERNAL_API_SECRET" "placeholder value (CHANGE_ME)"

    if [[ -v MINT_BASE_URL ]]; then
      guard_fail "MINT_BASE_URL" "must not be present (deleted by P9 Task 9)"
    fi
    if [[ -n "${MINT_PROJECTION_MODE:-}" ]]; then
      [[ "$MINT_PROJECTION_MODE" == "authoritative" ]] \
        || guard_fail "MINT_PROJECTION_MODE" "staging must be authoritative (got '$MINT_PROJECTION_MODE')"
    fi
    if [[ "${NODE_ENV:-}" == "production" ]]; then
      guard_fail "NODE_ENV" "staging mint must not run with NODE_ENV=production"
    fi
  )
}

# ── live-stack checks (read-only) ──────────────────────────────────────────

live_snapshot() {
  local out="$1" code body
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://api.ovidsi.com/healthz || true)"
  [[ -n "$code" ]] || code="000"
  body="$(mktemp)"
  local rows line name rest started
  rows="$(docker ps --filter 'name=ovid-gateway-' --format '{{.Names}} {{.Status}}' 2>/dev/null || true)"
  if [[ -z "$rows" ]]; then
    printf 'container_none=1\n' >> "$body"
  else
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      name="${line%% *}"
      rest="${line#* }"
      started="$(docker inspect "$name" --format '{{.State.StartedAt}}' 2>/dev/null || true)"
      printf 'container=%s status=%s started_at=%s\n' "$name" "$rest" "$started" >> "$body"
    done <<< "$rows"
  fi
  { printf 'healthz=%s\n' "$code"; sort "$body"; } > "$out"
  rm -f "$body"
  cat "$out"
}

live_check() {
  local label="$1" tmp code total up bad=0
  tmp="$(mktemp)"
  live_snapshot "$tmp" >/dev/null
  printf 'LIVE CHECK (%s):\n' "$label"
  sed 's/^/  /' "$tmp"
  code="$(sed -n 's/^healthz=//p' "$tmp")"
  total="$(grep -c '^container=' "$tmp" || true)"
  up="$(grep -c '^container=.* status=Up' "$tmp" || true)"
  rm -f "$tmp"
  [[ "$code" == "200" ]] || bad=1
  [[ "$total" -gt 0 && "$total" == "$up" ]] || bad=1
  if [[ "$bad" -ne 0 ]]; then
    printf '[staging] LIVE CHECK FAILED (%s): healthz=%s, containers Up=%s/%s — every ovid-gateway-* container must be Up\n' \
      "$label" "$code" "$up" "$total" >&2
    return 1
  fi
}

live_assert_unchanged() {
  local baseline="$1" current
  current="$(mktemp)"
  live_snapshot "$current" >/dev/null
  if ! diff -u "$baseline" "$current" >/dev/null; then
    printf '[staging] LIVE STACK CHANGED during the operation:\n' >&2
    diff -u "$baseline" "$current" >&2 || true
    rm -f "$current"
    return 1
  fi
  rm -f "$current"
  printf '[staging] live stack unchanged (healthz=200, every ovid-gateway-* Up, StartedAt identical)\n'
}

# ── compose / wait helpers ─────────────────────────────────────────────────

compose() {
  # L1: teardown must work when the env file is missing. `--env-file` only
  # controls interpolation and Docker fails before doing anything if the path
  # does not exist, so omit it when absent. (Service `env_file:` entries are
  # `required: false` in the compose file for the same reason; `up` still
  # validates the file first via guard_env_file.)
  local args=(compose)
  if [[ -f "$ENV_FILE" ]]; then
    args+=(--env-file "$ENV_FILE")
  fi
  args+=(-p "$PROJECT" -f "$COMPOSE_FILE")
  docker "${args[@]}" "$@"
}

wait_for_mint_projection() {
  local deadline=$((SECONDS + 60)) value
  log "waiting for the staging mint boot re-sync (redis-mint db2 config:limits)"
  while :; do
    value="$(compose exec -T redis-mint redis-cli --no-auth-warning \
      -a "${REDIS_MINT_PASSWORD:-staging}" -n 2 EXISTS config:limits 2>/dev/null | tr -d '\r' || true)"
    if [[ "$value" == "1" ]]; then
      log "mint projection ready (config:limits present on redis-mint db2)"
      return 0
    fi
    if (( SECONDS >= deadline )); then
      die "mint boot re-sync did not publish config:limits within 60s (last: '${value:-<no response>}')"
    fi
    sleep 1
  done
}

wait_for_gateway_health() {
  local deadline=$((SECONDS + 60)) body
  log "polling http://127.0.0.1:18082/cloud/v1/health"
  while :; do
    body="$(curl -sf --max-time 5 http://127.0.0.1:18082/cloud/v1/health || true)"
    if [[ "$body" == *'"status":"ok"'* ]]; then
      log "gateway healthy: $body"
      return 0
    fi
    if (( SECONDS >= deadline )); then
      die "staging gateway did not report status=ok within 60s (last: ${body:-<no response>})"
    fi
    sleep 1
  done
}

# ── subcommands ────────────────────────────────────────────────────────────

cmd_guard() {
  local file="$ENV_FILE"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file)
        [[ $# -ge 2 ]] || die "--env-file needs a path"
        file="$2"
        shift 2
        ;;
      *) die "guard: unknown argument '$1'" ;;
    esac
  done
  guard_env_file "$file"
  printf '[staging] guard OK: %s\n' "$file"
}

cmd_env() {
  [[ $# -eq 0 ]] || die "env takes no arguments"
  guard_env_file "$ENV_FILE"
  printf 'STAGING_DATABASE_URL=%s\n' "$DATABASE_URL"
  printf 'STAGING_REDIS_Q_URL=%s\n' "$REDIS_Q_URL"
  printf 'STAGING_REDIS_MINT_URL=%s\n' "$REDIS_MINT_URL"
  printf 'STAGING_INTERNAL_MINT_URL=%s\n' "$OVID_INTERNAL_MINT_URL"
  printf 'STAGING_GATEWAY_URL=%s\n' "${STAGING_GATEWAY_URL:-http://127.0.0.1:18082}"
  printf 'STAGING_MOCK_LLM_URL=%s\n' "${STAGING_MOCK_LLM_URL:-http://127.0.0.1:14000}"
  printf 'STAGING_WORKER_PIDFILE=%s\n' "${STAGING_WORKER_PIDFILE:-/tmp/opencode/ovid-staging-worker.pid}"
  printf 'STAGING_MOCK_PIDFILE=%s\n' "${STAGING_MOCK_PIDFILE:-/tmp/opencode/ovid-staging-mock.pid}"
  printf 'BULL_PREFIX=%s\n' "${BULL_PREFIX:-bull:staging}"
}

cmd_up() {
  local auth="test"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auth)
        [[ $# -ge 2 ]] || die "--auth needs test|firebase"
        auth="$2"
        shift 2
        ;;
      *) die "up: unknown argument '$1'" ;;
    esac
  done
  case "$auth" in test|firebase) ;; *) die "--auth must be test or firebase (got '$auth')" ;; esac

  guard_env_file "$ENV_FILE"
  guard_mint_env_file "$MINT_ENV_FILE" "$OVID_INTERNAL_API_SECRET"
  [[ -f "$COMPOSE_FILE" ]] || die "compose file not found: $COMPOSE_FILE"

  live_check before || die "live stack pre-check failed — refusing to start the staging composition"
  local baseline
  baseline="$(mktemp)"
  live_snapshot "$baseline" >/dev/null

  export STAGING_AUTH_MODE="$auth"
  log "starting staging compose project '$PROJECT' (auth=$auth)"
  compose up -d --build

  log "running migrations against $DATABASE_URL"
  ( cd "$CLOUD_DIR" && node packages/db/dist/migrate-cli.js "$DATABASE_URL" )

  wait_for_mint_projection
  wait_for_gateway_health

  live_assert_unchanged "$baseline"
  rm -f "$baseline"
  log "staging up: gateway http://127.0.0.1:18082 (mock 14000, mint 18091/18092)"
}

cmd_down() {
  local volumes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--volumes) volumes=1; shift ;;
      *) die "down: unknown argument '$1'" ;;
    esac
  done
  if [[ -f "$ENV_FILE" ]]; then
    guard_env_file "$ENV_FILE"
  else
    log "env file $ENV_FILE missing — teardown will use compose defaults"
  fi
  live_check before || log "WARNING: live stack pre-check failed; continuing teardown"
  if [[ -f "$COMPOSE_FILE" ]]; then
    if [[ "$volumes" -eq 1 ]]; then
      log "stopping staging compose project and REMOVING named volumes"
      compose down -v
    else
      log "stopping staging compose project (volumes kept)"
      compose down
    fi
  else
    log "compose file missing — nothing to stop"
  fi
  live_check after || log "WARNING: live stack post-check failed"
}

cmd_worker_start() {
  local overrides=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)
        [[ $# -ge 2 ]] || die "--env needs K=V"
        overrides+=("$2")
        shift 2
        ;;
      *) die "worker-start: unknown argument '$1'" ;;
    esac
  done

  guard_env_file "$ENV_FILE"
  live_check before || die "live stack pre-check failed — refusing to start the staging worker"

  local pidfile="${STAGING_WORKER_PIDFILE:-/tmp/opencode/ovid-staging-worker.pid}"
  local logfile="${STAGING_WORKER_LOG:-/tmp/opencode/ovid-staging-worker.log}"
  mkdir -p "$(dirname "$pidfile")" "$(dirname "$logfile")" \
    "$OVID_WORKSPACES_ROOT" "$OVID_FS_STORAGE_ROOT" "$OVID_BROWSER_STATE_DIR"
  # M4: the staging gateway bind-mounts $OVID_FS_STORAGE_ROOT writable but
  # runs as `USER node` (uid 1000). A bind source created by Docker is
  # root-owned, so hand the shared directory to uid/gid 1000 when we are root.
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    chown 1000:1000 "$OVID_FS_STORAGE_ROOT" 2>/dev/null || true
    chmod 0775 "$OVID_FS_STORAGE_ROOT" 2>/dev/null || true
  fi

  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    die "staging worker already running (pid $(cat "$pidfile"))"
  fi
  [[ -f "$CLOUD_DIR/apps/worker/dist/main.js" ]] \
    || die "apps/worker/dist/main.js missing — run 'cd cloud && pnpm -r build' first"
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log "WARNING: not running as root — bwrap/cgroup sandboxing will fail unless the launcher is setuid"
  fi

  log "starting staging worker (workspaces $OVID_WORKSPACES_ROOT, uid base $OVID_SANDBOX_UID_BASE)"
  (
    cd "$CLOUD_DIR/apps/worker"
    exec env "${overrides[@]}" node dist/main.js
  ) >>"$logfile" 2>&1 &
  local pid=$!
  echo "$pid" > "$pidfile"
  sleep 1
  kill -0 "$pid" 2>/dev/null \
    || die "staging worker exited immediately — see $logfile"
  log "staging worker pid $pid (pidfile $pidfile, log $logfile)"
  live_check after || log "WARNING: live stack post-check failed"
}

cmd_worker_stop() {
  local mode="graceful"
  if [[ $# -gt 0 ]]; then mode="$1"; fi
  case "$mode" in graceful|kill) ;; *) die "worker-stop mode must be graceful or kill (got '$mode')" ;; esac

  # L2: source the env file so a custom STAGING_WORKER_PIDFILE is honoured
  # (start and stop must agree); missing file is tolerated.
  load_env_if_present || true
  local pidfile="${STAGING_WORKER_PIDFILE:-/tmp/opencode/ovid-staging-worker.pid}"
  live_check before || log "WARNING: live stack pre-check failed; continuing worker stop"
  if [[ ! -f "$pidfile" ]]; then
    log "no worker pidfile at $pidfile — nothing to stop"
    return 0
  fi
  local pid
  pid="$(cat "$pidfile")"
  if ! kill -0 "$pid" 2>/dev/null; then
    log "worker pid $pid is not running; removing stale pidfile"
    rm -f "$pidfile"
    return 0
  fi

  # L2: verify identity before signalling (stale/reused PID protection).
  verify_pid_identity "$pid" worker

  if [[ "$mode" == "kill" ]]; then
    kill -9 "$pid" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
    local deadline=$((SECONDS + 15))
    while kill -0 "$pid" 2>/dev/null; do
      if (( SECONDS >= deadline )); then
        log "graceful stop timed out after 15s — sending SIGKILL"
        kill -9 "$pid" 2>/dev/null || true
        break
      fi
      sleep 0.5
    done
  fi
  rm -f "$pidfile"
  log "staging worker stopped ($mode)"
  live_check after || log "WARNING: live stack post-check failed"
}

cmd_mock_start() {
  guard_env_file "$ENV_FILE"
  live_check before || die "live stack pre-check failed — refusing to start the mock"

  local mock="$CLOUD_DIR/apps/load/dist/mockServer.js"
  [[ -f "$mock" ]] \
    || die "apps/load/dist/mockServer.js missing — run Task 4 first ('pnpm --filter @ovid/load build')"
  local pidfile="${STAGING_MOCK_PIDFILE:-/tmp/opencode/ovid-staging-mock.pid}"
  local logfile="${STAGING_MOCK_LOG:-/tmp/opencode/ovid-staging-mock.log}"
  mkdir -p "$(dirname "$pidfile")" "$(dirname "$logfile")"
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    die "mock LiteLLM already running (pid $(cat "$pidfile"))"
  fi

  log "starting mock LiteLLM on 0.0.0.0:14000 (gateway reaches it at 172.17.0.1:14000)"
  (
    cd "$CLOUD_DIR"
    exec node apps/load/dist/mockServer.js --port 14000 --bind 0.0.0.0
  ) >>"$logfile" 2>&1 &
  local pid=$!
  echo "$pid" > "$pidfile"

  local deadline=$((SECONDS + 10))
  until curl -s -o /dev/null --max-time 1 http://127.0.0.1:14000/ 2>/dev/null; do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$pidfile"
      die "mock LiteLLM exited immediately — see $logfile"
    fi
    if (( SECONDS >= deadline )); then
      die "mock LiteLLM did not listen on 127.0.0.1:14000 within 10s — see $logfile"
    fi
    sleep 0.2
  done
  log "mock LiteLLM pid $pid (pidfile $pidfile, log $logfile)"
  live_check after || log "WARNING: live stack post-check failed"
}

cmd_mock_stop() {
  # L2: honour a custom STAGING_MOCK_PIDFILE from the env file, and verify
  # the PID is the staging mock before signalling.
  load_env_if_present || true
  local pidfile="${STAGING_MOCK_PIDFILE:-/tmp/opencode/ovid-staging-mock.pid}"
  if [[ ! -f "$pidfile" ]]; then
    log "no mock pidfile at $pidfile — nothing to stop"
    return 0
  fi
  local pid
  pid="$(cat "$pidfile")"
  if kill -0 "$pid" 2>/dev/null; then
    verify_pid_identity "$pid" mock
    kill -TERM "$pid" 2>/dev/null || true
    local deadline=$((SECONDS + 10))
    while kill -0 "$pid" 2>/dev/null; do
      if (( SECONDS >= deadline )); then
        kill -9 "$pid" 2>/dev/null || true
        break
      fi
      sleep 0.2
    done
  fi
  rm -f "$pidfile"
  log "mock LiteLLM stopped"
}

cmd_pressure_mount() {
  # P10 Task 7: a 256 MB loopback ext4 fixture. It is the ONLY disk this
  # script may fill; the host root, /opt, /workspaces* and every prod path are
  # untouched. Fixed paths are deliberate: pressure-unmount never removes an
  # arbitrary directory.
  local mb="${1:-256}"
  local mount_dir="/mnt/ovid-pressure"
  local image="/var/tmp/ovid-pressure.img"

  [[ "${EUID:-$(id -u)}" -eq 0 ]] \
    || die "pressure-mount requires root (loop mount)"
  [[ "$mb" =~ ^[0-9]+$ ]] || die "pressure-mount: size must be integer MB (got '$mb')"
  (( mb >= 64 && mb <= 1024 )) \
    || die "pressure-mount: size must be between 64 and 1024 MB (got ${mb})"
  command -v mkfs.ext4 >/dev/null \
    || die "pressure-mount: mkfs.ext4 not found (apt install e2fsprogs)"
  command -v mount >/dev/null || die "pressure-mount: mount not found"
  command -v mountpoint >/dev/null || die "pressure-mount: mountpoint not found (util-linux)"
  command -v losetup >/dev/null || die "pressure-mount: losetup not found (util-linux)"

  if mountpoint -q "$mount_dir"; then
    # F5: an existing mount is only acceptable when it is OUR loopback image.
    # The size gate alone would let a foreign 256 MB filesystem through (and
    # pressure-unmount would then correctly refuse it, stranding both).
    local source_dev backing=""
    source_dev="$(findmnt -n -o SOURCE --target "$mount_dir" 2>/dev/null || true)"
    if [[ -z "$source_dev" ]]; then
      source_dev="$(awk -v m="$mount_dir" '$2 == m {print $1}' /proc/mounts)"
    fi
    if [[ "$source_dev" == /dev/loop* ]]; then
      backing="$(losetup -n -O BACK-FILE "$source_dev" 2>/dev/null || true)"
    fi
    [[ "$backing" == "$image" ]] \
      || die "pressure-mount: $mount_dir (source ${source_dev:-unknown}, backing ${backing:-unknown}) is not our $image — refusing to reuse a foreign mount"
    log "pressure fixture already mounted at $mount_dir"
    printf '%s\n' "$mount_dir"
    return 0
  fi

  # Never overwrite an existing non-empty directory with a mount.
  if [[ -d "$mount_dir" ]] && [[ -n "$(ls -A "$mount_dir" 2>/dev/null)" ]]; then
    die "pressure-mount: $mount_dir is non-empty and not a mount — refusing to shadow it"
  fi

  mkdir -p "$mount_dir"
  # F11: refuse to create the image unless the HOST has room for it. The
  # post-prepare gate's 1 GB floor is too late — dd would already have run.
  local host_free_mb
  host_free_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
  [[ "$host_free_mb" =~ ^[0-9]+$ ]] \
    || die "pressure-mount: could not read host free space"
  (( host_free_mb >= 1024 )) \
    || die "pressure-mount: host has only ${host_free_mb}MB free (< 1024MB floor) — refusing to create a ${mb}MB image"
  rm -f -- "$image"
  log "creating ${mb}MB loopback ext4 at $image (host root untouched beyond this file)"
  dd if=/dev/zero of="$image" bs=1M count="$mb" status=none \
    || die "pressure-mount: dd failed"
  mkfs.ext4 -q -F "$image" || {
    rm -f -- "$image"
    die "pressure-mount: mkfs.ext4 failed"
  }

  if ! mount -o loop,rw,nodev,nosuid,noexec "$image" "$mount_dir"; then
    rm -f -- "$image"
    die "pressure-mount: mount failed (loop devices may be unavailable in this container)"
  fi

  # Prove it is a separate filesystem before anything writes into it.
  local mount_dev root_dev
  mount_dev="$(stat -c %d "$mount_dir")"
  root_dev="$(stat -c %d /)"
  if [[ "$mount_dev" == "$root_dev" ]]; then
    umount "$mount_dir" 2>/dev/null || true
    rm -f -- "$image"
    die "pressure-mount: $mount_dir is not a separate filesystem — refusing to fill the host"
  fi

  log "pressure fixture mounted at $mount_dir ($(df -Pm "$mount_dir" | awk 'NR==2 {print $4}')MB free)"
  printf '%s\n' "$mount_dir"
}

cmd_pressure_unmount() {
  local mount_dir="/mnt/ovid-pressure"
  local image="/var/tmp/ovid-pressure.img"

  [[ "${EUID:-$(id -u)}" -eq 0 ]] \
    || die "pressure-unmount requires root"
  command -v mountpoint >/dev/null \
    || die "pressure-unmount: mountpoint not found (util-linux)"

  if mountpoint -q "$mount_dir"; then
    # Only unmount OUR fixture: the loop device's backing file must be the
    # fixed image (findmnt/losetup, with a /proc/mounts fallback for SOURCE).
    local source_dev backing=""
    source_dev="$(findmnt -n -o SOURCE --target "$mount_dir" 2>/dev/null || true)"
    if [[ -z "$source_dev" ]]; then
      source_dev="$(awk -v m="$mount_dir" '$2 == m {print $1}' /proc/mounts)"
    fi
    if [[ "$source_dev" == /dev/loop* ]]; then
      backing="$(losetup -n -O BACK-FILE "$source_dev" 2>/dev/null || true)"
    fi
    [[ "$backing" == "$image" ]] \
      || die "pressure-unmount: $mount_dir (source ${source_dev:-unknown}, backing ${backing:-unknown}) is not our $image — refusing to unmount a foreign mount"
    log "unmounting $mount_dir"
    umount "$mount_dir" || die "pressure-unmount: umount failed"
  fi

  rm -f -- "$image"
  rmdir "$mount_dir" 2>/dev/null || true
  log "pressure fixture removed ($image, $mount_dir)"
}

cmd_live_check() {
  local baseline="" write=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --baseline)
        [[ $# -ge 2 ]] || die "--baseline needs a path"
        baseline="$2"
        shift 2
        ;;
      --write-baseline)
        [[ $# -ge 2 ]] || die "--write-baseline needs a path"
        write="$2"
        shift 2
        ;;
      *) die "live-check: unknown argument '$1'" ;;
    esac
  done
  if [[ -n "$write" ]]; then
    live_snapshot "$write" >/dev/null
    log "wrote live baseline to $write"
  fi
  if [[ -n "$baseline" ]]; then
    live_check before
    live_assert_unchanged "$baseline"
  else
    live_check check
  fi
}

# ── dispatch ───────────────────────────────────────────────────────────────

command="${1:-}"
if [[ $# -gt 0 ]]; then shift; fi
case "$command" in
  guard) cmd_guard "$@" ;;
  env) cmd_env "$@" ;;
  up) cmd_up "$@" ;;
  down) cmd_down "$@" ;;
  worker-start) cmd_worker_start "$@" ;;
  worker-stop) cmd_worker_stop "$@" ;;
  mock-start) cmd_mock_start "$@" ;;
  mock-stop) cmd_mock_stop "$@" ;;
  pressure-mount) cmd_pressure_mount "$@" ;;
  pressure-unmount) cmd_pressure_unmount "$@" ;;
  live-check) cmd_live_check "$@" ;;
  ""|help|-h|--help) usage ;;
  *) die "unknown command '$command' (run 'staging.sh help')" ;;
esac
