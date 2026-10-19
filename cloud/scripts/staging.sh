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

# NEW-6: a value with an embedded newline would be validated only up to the
# first line by line-oriented consumers. Every value gets this check.
validate_no_newline() {
  local name="$1" value="$2"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] \
    || guard_fail "$name" "must not contain a newline (got '$value')"
}

# NEW-1: the ONE value rule shared by the env-file guard and the
# `worker-start --env` override path. An empty value is rejected because
# downstream `strEnv` treats "" as unset and falls back to LIVE defaults; ".."
# is rejected before any lexical normalization. Path-like callers use this;
# URL/credential callers use validate_no_newline (a password may contain "..").
validate_env_value() {
  local name="$1" value="$2"
  [[ -n "$value" ]] \
    || guard_fail "$name" "must not be empty (an empty value falls back to a live default downstream)"
  validate_no_newline "$name" "$value"
  [[ "$value" != *".."* ]] \
    || guard_fail "$name" "must not contain '..' path traversal (got '$value')"
}

# Resolve symlinks in every existing path component; missing leaf components
# are kept (`realpath -m`). The guard must never follow a staging path into a
# live namespace, so an unavailable resolver is fail-closed.
canonical_path() {
  local path="$1"
  command -v realpath >/dev/null 2>&1 || return 1
  realpath -m -- "$path"
}

usage() {
  cat <<'EOF'
usage: staging.sh <command> [options]

  guard [--env-file <path>]        validate staging isolation (read-only;
                                   exits 2 and names the variable on any
                                   production-valued or non-loopback value)
  env                              print the resolved staging env as
                                   KEY=VALUE (consumed by @ovid/load)
  up [--auth test|firebase]        guard -> compose up -> install the staging
                                   egress nft table -> migrate -> wait for
                                   the mint boot re-sync and gateway health
  down [-v]                        remove the staging egress nft table, then
                                   stop the staging compose project (named
                                   volumes are kept unless -v)
  mock-start | mock-stop           start/stop the Task-4 mock LiteLLM on
                                   0.0.0.0:14000 (one of two host
                                   non-loopback listeners; the other is the
                                   worker file service on 0.0.0.0:18093)
  worker-start [--env-file <path>] [--env K=V ...]
                                   start the host staging worker (root is
                                   required for bwrap/cgroups); --env is
                                   limited to operational knobs (the chaos
                                   harness uses OVID_RUN_STALE_MS)
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

# NEW-4: the env file is DATA, never code. Parsing (not sourcing) means
# `$(...)`, `exit 0`, function definitions and shell metacharacters cannot
# execute or change the guard. The accepted grammar is deliberately small:
# blank lines, `#` comments, optional `export `, and `KEY=VALUE` with an
# optionally single- or double-quoted value.
#
# Values are exported into the current shell so the backgrounded worker/mock
# inherit the validated staging env without re-reading the file.
ENV_FILE_UNSAFE_NAMES=(
  PATH IFS BASH_ENV ENV SHELLOPTS BASHOPTS CDPATH GLOBIGNORE
  LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT NODE_OPTIONS NODE_PATH
  PROMPT_COMMAND PS4 BASH_XTRACEFD SHELL
)

env_name_is_unsafe() {
  local name="$1" unsafe
  for unsafe in "${ENV_FILE_UNSAFE_NAMES[@]}"; do
    [[ "$name" == "$unsafe" ]] && return 0
  done
  [[ "$name" == BASH_FUNC_* ]] && return 0
  return 1
}

# Unquote one RHS. Never expands anything. Returns 1 on malformed/unsupported
# syntax so the caller can fail closed with the line number.
parse_env_value() {
  local value="$1"
  if [[ "$value" == \'* ]]; then
    [[ "$value" == *\' && ${#value} -ge 2 ]] || return 1
    value="${value#\'}"
    value="${value%\'}"
    [[ "$value" != *"'"* ]] || return 1
  elif [[ "$value" == \"* ]]; then
    [[ "$value" == *\" && ${#value} -ge 2 ]] || return 1
    value="${value#\"}"
    value="${value%\"}"
    [[ "$value" != *'"'* ]] || return 1
    # Never executed, but refuse shell-expansion syntax so a value cannot be
    # mistaken for code by a future consumer.
    [[ "$value" != *'$('* && "$value" != *'`'* ]] || return 1
    value="${value//\\\"/\"}"
    value="${value//\\\\/\\}"
  else
    [[ "$value" != *'$('* && "$value" != *'`'* ]] || return 1
    # No inline comments by contract; a '#' in a value is literal.
  fi
  printf '%s' "$value"
}

parse_env_file() {
  local file="$1" raw line name value lineno=0 parsed
  [[ -f "$file" ]] || die "env file not found: $file (copy cloud/deploy/.env.staging.example)"
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    lineno=$((lineno + 1))
    raw="${raw%$'\r'}"
    [[ "$raw" =~ ^[[:space:]]*$ ]] && continue
    [[ "$raw" =~ ^[[:space:]]*# ]] && continue
    line="${raw#"${raw%%[![:space:]]*}"}"
    if [[ "$line" =~ ^export[[:space:]]+ ]]; then
      line="${line#*export}"
      line="${line#"${line%%[![:space:]]*}"}"
    fi
    if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      die "env file $file:$lineno is not a KEY=VALUE assignment: '$raw' (the guard parses the file; it never sources it)"
    fi
    name="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if env_name_is_unsafe "$name"; then
      die "env file $file:$lineno sets forbidden shell/loader variable '$name'"
    fi
    parsed="$(parse_env_value "$value")" \
      || die "env file $file:$lineno has unsupported value syntax for '$name' (quotes must be balanced; no \$(...) or backticks)"
    printf -v "$name" '%s' "$parsed"
    export "$name"
  done < "$file"
}

# Kept as the one loading entry point used by the stop paths.
load_env_file() {
  parse_env_file "$1"
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
  validate_no_newline "$name" "${!name}"
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
# expected staging literal. Three independent gates:
#   1. the shared value rule rejects empty values, newlines and ".." (H2 —
#      no normalization may climb from a staging prefix into a live path);
#   2. the normalized value must equal the expected literal (H1 — omission
#      or a sibling path cannot fall back to a live default/prefix);
#   3. NEW-5: the resolved path (realpath -m, i.e. the nearest existing
#      ancestor's symlinks followed) must equal the literal expected path.
#      A symlinked /workspaces-staging therefore cannot redirect staging
#      writes into /workspaces or /opt.
# One helper for every path-like variable, so a future variable cannot
# reintroduce the prefix-matching bug.
require_exact_path() {
  local name="$1" expected="$2" value normalized expected_norm
  local actual_abs expected_abs resolved
  require_var "$name"
  value="${!name}"
  validate_env_value "$name" "$value"
  normalized="$(normalize_path "$value")"
  expected_norm="$(normalize_path "$expected")"
  [[ "$normalized" == "$expected_norm" ]] \
    || guard_fail "$name" "must be exactly '$expected' after path normalization (got '$value' -> '$normalized')"

  if [[ "$expected" == /* ]]; then
    actual_abs="$value"
    expected_abs="$expected"
  else
    # Relative cgroup paths live under OVID_CGROUP_ROOT.
    actual_abs="${OVID_CGROUP_ROOT:-/sys/fs/cgroup}/$value"
    expected_abs="${OVID_CGROUP_ROOT:-/sys/fs/cgroup}/$expected"
  fi
  resolved="$(canonical_path "$actual_abs")" \
    || guard_fail "$name" "cannot resolve '$actual_abs' (realpath unavailable or failed)"
  [[ "$resolved" == "$(normalize_path "$expected_abs")" ]] \
    || guard_fail "$name" "resolves to '$resolved' through a symlinked parent; must be exactly '$expected'"
}

# NEW-7: log/pidfile paths are written by root. Pin them under a private
# directory and prove the resolved path does not escape through a symlink.
validate_tmp_file_path() {
  local name="$1" dir="$2" value resolved
  [[ -n "${!name:-}" ]] || return 0
  value="${!name}"
  validate_env_value "$name" "$value"
  [[ "$value" == "$dir"/* ]] \
    || guard_fail "$name" "must be under $dir (got '$value'; /opt, /workspaces* and /var/lib are forbidden)"
  resolved="$(canonical_path "$value")" \
    || guard_fail "$name" "cannot resolve '$value'"
  [[ "$resolved" == "$(normalize_path "$dir")"/* ]] \
    || guard_fail "$name" "resolves to '$resolved' outside $dir (symlinked parent)"
}

# Host paths that are intentionally shared with the live stack (read-only
# rootfs, bwrap binary) are allowed, but must stay absolute and outside the
# live writable namespaces.
validate_shared_host_path() {
  local name="$1" value
  [[ -n "${!name:-}" ]] || return 0
  value="${!name}"
  validate_env_value "$name" "$value"
  [[ "$value" == /* ]] \
    || guard_fail "$name" "must be an absolute host path (got '$value')"
  [[ "$value" != /workspaces* ]] \
    || guard_fail "$name" "must not point into the live workspaces (got '$value')"
  [[ "$value" != /var/lib/* ]] \
    || guard_fail "$name" "must not point into live state (/var/lib) (got '$value')"
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

# NEW-2: parse http(s) URLs by authority instead of globbing the raw string.
# A naive `127.0.0.1:*` match accepts `http://127.0.0.1:8080@api.ovidsi.com`
# because the userinfo is not a host. This returns the authority only after
# rejecting userinfo, queries and fragments. Callers compare the exact
# host:port; the path (if any) is ignored.
http_authority() {
  local name="$1" url="$2" rest authority
  validate_no_newline "$name" "$url"
  [[ "$url" == http://* || "$url" == https://* ]] \
    || guard_fail "$name" "must be an http(s) URL (got '$url')"
  [[ "$url" != *"?"* && "$url" != *"#"* ]] \
    || guard_fail "$name" "must not contain a query or fragment (got '$url')"
  rest="${url#*://}"
  authority="${rest%%/*}"
  [[ -n "$authority" ]] \
    || guard_fail "$name" "has no host (got '$url')"
  [[ "$authority" != *"@"* ]] \
    || guard_fail "$name" "must not contain URL userinfo (got '$url')"
  printf '%s' "$authority"
}

validate_redis_url() {
  local name="$1" url="$2"
  validate_no_newline "$name" "$url"
  [[ "$url" == redis://* || "$url" == rediss://* ]] \
    || guard_fail "$name" "must be a redis:// URL (got '$url')"
  [[ "$url" != *"?"* && "$url" != *"#"* ]] \
    || guard_fail "$name" "must not contain a query or fragment (got '$url')"
}

# Pin an exact loopback staging listener: host must be 127.0.0.1 (no
# localhost alias, no userinfo) and the port must be the staging port.
validate_loopback_url() {
  local name="$1" url="$2" port="$3" authority
  validate_env_value "$name" "$url"
  authority="$(http_authority "$name" "$url")"
  [[ "$authority" == "127.0.0.1:$port" ]] \
    || guard_fail "$name" "must be exactly http://127.0.0.1:$port (got '$url'; host must be 127.0.0.1 and the port must be $port)"
}

# ── staging egress filter (P10 Task 8) ─────────────────────────────────────
#
# `up` loads and `down` removes table inet sandbox_egress_staging, keyed on
# the staging uid block. The ruleset is rendered by @ovid/sandbox's
# `renderNftRuleset` with the SAME DEFAULT_BLOCKED_V4/V6 as the production
# renderer — a hand-written second list would drift. This is a SEPARATE table
# from the production `ovid_sandbox`; nothing here may flush or modify that
# table.
STAGING_EGRESS_TABLE="sandbox_egress_staging"
STAGING_EGRESS_UID_BASE=220000
STAGING_EGRESS_UID_MAX=229999
DEFAULT_PUBLIC_IP="148.113.44.36"

render_staging_egress_ruleset() {
  local public_ip="${OVID_PUBLIC_IP:-$DEFAULT_PUBLIC_IP}"
  if [[ ! "$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    log "WARNING: OVID_PUBLIC_IP='$public_ip' is not an IPv4 address — using $DEFAULT_PUBLIC_IP for the staging egress table" >&2
    public_ip="$DEFAULT_PUBLIC_IP"
  fi
  (
    cd "$CLOUD_DIR"
    OVID_SANDBOX_UID_BASE="$STAGING_EGRESS_UID_BASE" \
    OVID_SANDBOX_UID_MAX="$STAGING_EGRESS_UID_MAX" \
    OVID_PUBLIC_IP="$public_ip" \
    OVID_STAGING_EGRESS_TABLE="$STAGING_EGRESS_TABLE" \
      node --input-type=module -e '
        import {
          renderNftRuleset,
          DEFAULT_BLOCKED_V4,
          DEFAULT_BLOCKED_V6,
        } from "./packages/sandbox/dist/index.js";
        process.stdout.write(
          renderNftRuleset({
            uidRange: [
              Number(process.env.OVID_SANDBOX_UID_BASE),
              Number(process.env.OVID_SANDBOX_UID_MAX),
            ],
            blockedV4: [...DEFAULT_BLOCKED_V4],
            blockedV6: [...DEFAULT_BLOCKED_V6],
            ownPublicIp: process.env.OVID_PUBLIC_IP,
            table: process.env.OVID_STAGING_EGRESS_TABLE,
          }),
        );
      '
  )
}

# Loads the staging table. No-op (loudly) when the box cannot own nftables.
install_staging_egress() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log "WARNING: not running as root — skipping the staging egress nft table ($STAGING_EGRESS_TABLE); the egress corpus will SKIP"
    return 0
  fi
  if ! command -v nft >/dev/null 2>&1; then
    log "WARNING: nft not found — skipping the staging egress nft table ($STAGING_EGRESS_TABLE); the egress corpus will SKIP"
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    die "node not found — cannot render the staging egress ruleset (run 'cd cloud && pnpm -r build')"
  fi
  [[ -f "$CLOUD_DIR/packages/sandbox/dist/index.js" ]] \
    || die "packages/sandbox/dist/index.js missing — run 'cd cloud && pnpm -r build' before staging.sh up"

  local rules
  rules="$(render_staging_egress_ruleset)" \
    || die "failed to render the staging egress ruleset"
  # Hard safety: this must be a SEPARATE table. Never touch prod's ovid_sandbox.
  if grep -q 'table inet ovid_sandbox' <<<"$rules"; then
    die "refusing to load: the renderer produced the PRODUCTION table (ovid_sandbox); staging must use $STAGING_EGRESS_TABLE"
  fi
  grep -q "table inet $STAGING_EGRESS_TABLE" <<<"$rules" \
    || die "renderer did not produce table inet $STAGING_EGRESS_TABLE"

  printf '%s\n' "$rules" | nft -f - \
    || die "failed to load table inet $STAGING_EGRESS_TABLE (production ovid_sandbox untouched)"
  log "loaded staging egress table inet $STAGING_EGRESS_TABLE (uids $STAGING_EGRESS_UID_BASE-$STAGING_EGRESS_UID_MAX)"
}

# Removes the staging table; idempotent (`nft delete` fails if absent).
remove_staging_egress() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log "WARNING: not running as root — cannot remove the staging egress nft table ($STAGING_EGRESS_TABLE)"
    return 0
  fi
  if ! command -v nft >/dev/null 2>&1; then
    log "WARNING: nft not found — cannot remove the staging egress nft table ($STAGING_EGRESS_TABLE)"
    return 0
  fi
  if nft list table inet "$STAGING_EGRESS_TABLE" >/dev/null 2>&1; then
    nft delete table inet "$STAGING_EGRESS_TABLE" \
      || log "WARNING: failed to delete table inet $STAGING_EGRESS_TABLE"
    log "removed staging egress table inet $STAGING_EGRESS_TABLE"
  else
    log "staging egress table inet $STAGING_EGRESS_TABLE not loaded — nothing to remove"
  fi
  return 0
}

# ── guard: refuse any production-valued staging env ────────────────────────

# NEW-4: variables the guard owns are cleared before the file is parsed, so an
# ambient shell value cannot silently satisfy a missing file entry. The file
# is the one source of truth for the host-side staging environment.
GUARDED_ENV_NAMES=(
  NODE_ENV COMPOSE_PROJECT_NAME OVID_AUTH_MODE DATABASE_URL
  REDIS_Q_URL REDIS_Q_PASSWORD REDIS_MINT_URL REDIS_MINT_PASSWORD
  OVID_INTERNAL_MINT_URL OVID_WORKSPACES_ROOT OVID_SANDBOX_UID_BASE
  OVID_SANDBOX_UID_MAX OVID_CGROUP_BASE OVID_CGROUP_ROOT
  OVID_STORAGE_BACKEND OVID_FS_STORAGE_ROOT OVID_BROWSER_STATE_DIR
  OVID_R2_ACCOUNT_ID OVID_R2_ACCESS_KEY_ID OVID_R2_SECRET_ACCESS_KEY
  OVID_R2_BUCKET STAGING_BIND_ADDRESS STAGING_GATEWAY_URL
  STAGING_MOCK_LLM_URL STAGING_WORKER_PIDFILE STAGING_WORKER_LOG
  STAGING_MOCK_PIDFILE STAGING_MOCK_LOG OVID_WORKER_FILE_PORT
  OVID_LITELLM_BASE OVID_DEFAULT_MODEL BULL_PREFIX OVID_RUN_STALE_MS
  OVID_MAX_ACTIVE_SANDBOXES MAX_LIVE_BROWSERS OVID_MAX_WARM_GB
  OVID_INTERNAL_API_SECRET OVID_INTERNAL_TOKEN OVID_MASTER_KEY
  REDIS_C_URL OVID_ANTHROPIC_BASE OVID_BROWSER_EGRESS_UID
  OVID_PUBLIC_IP MINT_BASE_URL OVID_ROOTFS OVID_BWRAP_PATH
  OVID_SANDBOX_LAUNCHER OVID_LIGHTPANDA_BIN OVID_DISK_ALERT_PCT
  REDIS_DB2_URL LITELLM_BASE MINT_PROJECTION_MODE PUBLIC_BASE_URL
  PUBLIC_PORT ADMIN_PORT
)
unset_guarded_env() {
  local name
  for name in "${GUARDED_ENV_NAMES[@]}"; do
    unset "$name" 2>/dev/null || true
  done
}

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

  unset_guarded_env
  parse_env_file "$file"
  validate_env
}

# Every rule for the resolved environment. Called once after parsing the file
# and again after `worker-start --env` overrides are applied, so the effective
# worker environment is validated with exactly the same rules.
validate_env() {
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
  validate_redis_url REDIS_Q_URL "$REDIS_Q_URL"
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
  validate_redis_url REDIS_MINT_URL "$REDIS_MINT_URL"
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

  # NEW-3: REDIS_C_URL is optional (the worker shares redis-q when unset), but
  # when set it must be the staging instance. Live host ports 6390/6391/6393
  # (ovid-dev-redis / redis-q / redis-c) are forbidden.
  if [[ -n "${REDIS_C_URL:-}" ]]; then
    validate_redis_url REDIS_C_URL "$REDIS_C_URL"
    redis_url_parts "$REDIS_C_URL"
    if [[ "$R_HOST" == "127.0.0.1" || "$R_HOST" == "localhost" ]]; then
      [[ "$R_PORT" == "16379" ]] \
        || guard_fail "REDIS_C_URL" "loopback staging redis-c must use the staging redis-q at 127.0.0.1:16379 (got $R_HOST:$R_PORT; live 6390/6391/6393 are forbidden)"
    elif [[ "$R_HOST" == "redis-q" ]]; then
      [[ "$R_PORT" == "6379" ]] \
        || guard_fail "REDIS_C_URL" "compose service redis-c must be redis-q:6379"
    else
      guard_fail "REDIS_C_URL" "host must be 127.0.0.1:16379 or redis-q:6379 (got '$R_HOST:$R_PORT')"
    fi
    [[ -z "$R_DB" || "$R_DB" == "0" ]] \
      || guard_fail "REDIS_C_URL" "must not select a non-zero db (got '$R_DB')"
  fi

  # ── internal mint surface (P9 Task 9) ──
  require_var OVID_INTERNAL_MINT_URL
  local internal_hp
  internal_hp="$(http_authority OVID_INTERNAL_MINT_URL "$OVID_INTERNAL_MINT_URL")"
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
  if [[ -n "${OVID_CGROUP_ROOT:-}" ]]; then
    require_exact_path OVID_CGROUP_ROOT "/sys/fs/cgroup"
  fi

  # NEW-3: browser processes must use a uid keyspace distinct from BOTH the
  # staging sandbox block (220000-229999) and the live one (200000-200099).
  # Overlapping either one makes ownership/nftables collide.
  if [[ -n "${OVID_BROWSER_EGRESS_UID:-}" ]]; then
    local egress_value="${OVID_BROWSER_EGRESS_UID}" egress_a egress_b
    validate_env_value OVID_BROWSER_EGRESS_UID "$egress_value"
    [[ "$egress_value" =~ ^([0-9]+)(-([0-9]+))?$ ]] \
      || guard_fail "OVID_BROWSER_EGRESS_UID" "must be a uid or uid range like 230000 or 230000-230099 (got '$egress_value')"
    egress_a="${BASH_REMATCH[1]}"
    egress_b="${BASH_REMATCH[3]:-$egress_a}"
    (( egress_b >= egress_a )) \
      || guard_fail "OVID_BROWSER_EGRESS_UID" "range end is before its start (got '$egress_value')"
    if (( egress_a <= 200099 && 200000 <= egress_b )); then
      guard_fail "OVID_BROWSER_EGRESS_UID" "must be outside the live sandbox uid block 200000-200099 (got '$egress_value')"
    fi
    if (( egress_a <= 229999 && 220000 <= egress_b )); then
      guard_fail "OVID_BROWSER_EGRESS_UID" "must be outside the staging sandbox uid block 220000-229999 (got '$egress_value')"
    fi
  fi

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

  # NEW-3/NEW-7: shared host binaries/rootfs are allowed (they are read-only
  # inputs, not staging-owned state), but never under the live writable
  # namespaces. Log/pid files are written as root, so they are pinned to the
  # private /tmp/opencode directory.
  local shared_path_var
  for shared_path_var in OVID_ROOTFS OVID_BWRAP_PATH OVID_SANDBOX_LAUNCHER OVID_LIGHTPANDA_BIN; do
    validate_shared_host_path "$shared_path_var"
  done
  validate_tmp_file_path STAGING_WORKER_PIDFILE "/tmp/opencode"
  validate_tmp_file_path STAGING_WORKER_LOG "/tmp/opencode"
  validate_tmp_file_path STAGING_MOCK_PIDFILE "/tmp/opencode"
  validate_tmp_file_path STAGING_MOCK_LOG "/tmp/opencode"

  # ── published addresses: loopback-only (mock bind is 0.0.0.0 by design,
  #    but it is never a *published* staging port; it is a host listener) ──
  require_var STAGING_BIND_ADDRESS
  [[ "$STAGING_BIND_ADDRESS" == "127.0.0.1" ]] \
    || guard_fail "STAGING_BIND_ADDRESS" "every staging publish address must be 127.0.0.1 (got '$STAGING_BIND_ADDRESS')"
  # NEW-2: parse the URL and pin host AND port. The old `127.0.0.1:*` glob
  # accepted `http://127.0.0.1:8080@api.ovidsi.com` (userinfo, real host
  # api.ovidsi.com) and unpinned live ports (8080 account-dev, 4000 LiteLLM).
  if [[ -n "${STAGING_GATEWAY_URL:-}" ]]; then
    validate_loopback_url STAGING_GATEWAY_URL "$STAGING_GATEWAY_URL" 18082
  fi
  if [[ -n "${STAGING_MOCK_LLM_URL:-}" ]]; then
    validate_loopback_url STAGING_MOCK_LLM_URL "$STAGING_MOCK_LLM_URL" 14000
  fi

  # ── worker file service: own port (the live worker owns 8091) ──
  require_var OVID_WORKER_FILE_PORT
  [[ "$OVID_WORKER_FILE_PORT" == "18093" ]] \
    || guard_fail "OVID_WORKER_FILE_PORT" "must be 18093 (the live worker owns 8091; got '$OVID_WORKER_FILE_PORT')"

  # ── model routing: the host-bound mock only ──
  require_var OVID_LITELLM_BASE
  local llm_hp
  llm_hp="$(http_authority OVID_LITELLM_BASE "$OVID_LITELLM_BASE")"
  # The staging worker runs on the HOST, where the mock is published on
  # 127.0.0.1:14000; the containers reach it as mock-llm:14000 (compose
  # overrides their env). All three spellings name the same mock — never the
  # live LiteLLM on :4000.
  [[ "$llm_hp" == "127.0.0.1:14000" || "$llm_hp" == "172.17.0.1:14000" || "$llm_hp" == "host.docker.internal:14000" || "$llm_hp" == "mock-llm:14000" ]] \
    || guard_fail "OVID_LITELLM_BASE" "must point at the staging mock (127.0.0.1:14000 for the host worker, mock-llm:14000 inside compose); got '$llm_hp' (live LiteLLM :4000 is forbidden)"
  # NEW-3: OVID_ANTHROPIC_BASE is added to the trusted provider-egress
  # origins. It must be the staging mock; the live LiteLLM (:4000) would
  # bypass the SSRF guard and receive staging Anthropic traffic.
  if [[ -n "${OVID_ANTHROPIC_BASE:-}" ]]; then
    local anthropic_hp
    anthropic_hp="$(http_authority OVID_ANTHROPIC_BASE "$OVID_ANTHROPIC_BASE")"
    [[ "$anthropic_hp" == "172.17.0.1:14000" || "$anthropic_hp" == "host.docker.internal:14000" ]] \
      || guard_fail "OVID_ANTHROPIC_BASE" "must point at the staging mock (172.17.0.1:14000 or host.docker.internal:14000); got '$anthropic_hp' (live LiteLLM :4000 is forbidden)"
  fi
  require_var OVID_DEFAULT_MODEL

  # ── queue prefix / worker knobs ──
  # BULL_PREFIX must equal what the staging gateway/worker ACTUALLY use. Their
  # mains pass no `prefix` option, so BullMQ's default "bull" applies. This
  # guard previously REQUIRED "bull:staging", which enforced a value nothing
  # reads and sent two chaos scenarios to inspect empty queues. Isolation from
  # prod comes from the separate redis-q instance, not from the prefix.
  require_var BULL_PREFIX
  [[ "$BULL_PREFIX" == "bull" ]] \
    || guard_fail "BULL_PREFIX" "must be 'bull' — the value the staging gateway/worker mains actually use (no prefix option => BullMQ default); got '$BULL_PREFIX'"
  require_var OVID_RUN_STALE_MS
  # The FILE must carry a production-like stale threshold. A 15 s value (the
  # original staging default) swept every run that legitimately took longer
  # than 15 s as `run_lost` — the first full100 run failed 63 of its 85
  # started runs that way, which reads as a product failure and is not one.
  # The chaos workerKill scenario still lowers it through the allowlisted
  # --env override (it needs a fast stranded-run observation); an override
  # deliberately skips this floor, which is why it is checked here and not
  # inside the shared value validator.
  if ! override_names_include OVID_RUN_STALE_MS; then
    [[ "$OVID_RUN_STALE_MS" =~ ^[0-9]+$ ]] \
      || guard_fail "OVID_RUN_STALE_MS" "must be an integer number of milliseconds (got '$OVID_RUN_STALE_MS')"
    (( OVID_RUN_STALE_MS >= 60000 )) \
      || guard_fail "OVID_RUN_STALE_MS" "must be >= 60000 ms in the env file — anything shorter sweeps healthy long runs as run_lost (got '$OVID_RUN_STALE_MS'); the chaos harness may lower it per-run via --env"
  fi
  require_var OVID_MAX_ACTIVE_SANDBOXES
  # Raised to 1500 (founder directive 2026-10-18): an idle jail costs ~1.7 MB
  # of slice memory, so 1500 live envs fit the 10G slice; the per-jail
  # memory.max (512 MB) is a ceiling, not a reservation. The REAL bound on
  # local work is OVID_MAX_CONCURRENT_TOOL_STEPS (200), applied around shell
  # and file steps only — never during LLM streaming.
  [[ "$OVID_MAX_ACTIVE_SANDBOXES" == "1500" ]] \
    || guard_fail "OVID_MAX_ACTIVE_SANDBOXES" "must be 1500 (got '$OVID_MAX_ACTIVE_SANDBOXES')"
  require_var MAX_LIVE_BROWSERS
  # Live-context cap 48 with the ephemeral-lease model (15 s freeze +
  # resource diet). 48 x ~240 MB ≈ 11.5 GB is above the 6-8 GB browser budget
  # on a quiet box, so the lease — not this number — is what keeps the
  # steady-state count low.
  [[ "$MAX_LIVE_BROWSERS" == "48" ]] \
    || guard_fail "MAX_LIVE_BROWSERS" "must be 48 (got '$MAX_LIVE_BROWSERS')"
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

# ── worker-start --env overrides (NEW-1) ───────────────────────────────────
#
# `worker-start --env K=V` is applied to the worker process AFTER the file
# guard. It therefore used to re-open every H1/H2/H3 bypass. Only a fixed set
# of non-path, non-credential operational knobs may be overridden; every
# value still passes `validate_env_value` and the full `validate_env` runs on
# the effective environment before exec. The chaos harness passes only
# OVID_RUN_STALE_MS (workerKill.ts), so that is the anchor of the list.
OVERRIDE_ALLOWLIST=(
  OVID_RUN_STALE_MS
  OVID_MAX_ACTIVE_SANDBOXES
  MAX_LIVE_BROWSERS
  OVID_MAX_WARM_GB
  OVID_DISK_ALERT_PCT
  OVID_SANDBOX_CPU_MAX
  OVID_SANDBOX_MEMORY_MAX_MB
  OVID_SANDBOX_SWAP_MAX_MB
  OVID_SANDBOX_PIDS_MAX
  OVID_APPROVAL_TIMEOUT_MS
  OVID_WINDOW_TOKENS
)

override_allowed() {
  local name="$1" allowed
  for allowed in "${OVERRIDE_ALLOWLIST[@]}"; do
    [[ "$name" == "$allowed" ]] && return 0
  done
  return 1
}

# Validate override syntax, the allowlist and the shared value rule. Runs
# BEFORE the env file is read so a rejected override fails closed even when
# the default env file is absent.
# Override names seen on this invocation (validate_env exempts the rules that
# a deliberate per-run override is allowed to change).
OVERRIDE_NAMES=()

override_names_include() {
  local wanted="$1" name
  for name in "${OVERRIDE_NAMES[@]:-}"; do
    [[ "$name" == "$wanted" ]] && return 0
  done
  return 1
}

check_overrides() {
  local spec name value
  OVERRIDE_NAMES=()
  for spec in "$@"; do
    [[ "$spec" == *=* ]] \
      || guard_fail "--env" "override must be K=V (got '$spec')"
    name="${spec%%=*}"
    value="${spec#*=}"
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
      || guard_fail "--env" "invalid override name '$name'"
    override_allowed "$name" \
      || guard_fail "$name" "may not be overridden via --env (allowed: ${OVERRIDE_ALLOWLIST[*]}); path, URL, credential and identity variables are file-only"
    OVERRIDE_NAMES+=("$name")
    validate_env_value "$name" "$value"
    # Knobs the worker parses as numbers must be numbers HERE, not at boot:
    # a bad value would crash-loop the worker after the launcher reported
    # success.
    case "$name" in
      OVID_RUN_STALE_MS|OVID_MAX_ACTIVE_SANDBOXES|MAX_LIVE_BROWSERS|OVID_MAX_WARM_GB|OVID_DISK_ALERT_PCT)
        [[ "$value" =~ ^[0-9]+$ ]] \
          || guard_fail "$name" "override must be a non-negative integer (got '$value')"
        ;;
    esac
  done
}

# Apply already-checked overrides, then re-run EVERY file rule so the
# effective (file + overrides) environment is what the guard approved.
apply_overrides() {
  local spec name value
  for spec in "$@"; do
    name="${spec%%=*}"
    value="${spec#*=}"
    printf -v "$name" '%s' "$value"
    export "$name"
  done
  [[ $# -eq 0 ]] || validate_env
}

# Validate `.env.staging.mint` in a subshell so its DATABASE_URL/REDIS_DB2_URL
# do not overwrite the host-side view used by `up`/`worker-start`.
guard_mint_env_file() {
  local file="$1" expected_secret="$2"
  [[ -f "$file" ]] || die "mint env file not found: $file (copy cloud/deploy/.env.staging.mint.example)"
  (
    # NEW-4: parse, never source. The subshell keeps the mint values from
    # overwriting the host-side view.
    unset_guarded_env
    parse_env_file "$file"

    require_var DATABASE_URL
    db_url_parts "$DATABASE_URL"
    [[ "$DB_NAME" == "ovid_cloud_staging" ]] \
      || guard_fail "DATABASE_URL" "mint must use the staging database (got '$DB_NAME')"
    [[ "$DB_HOST" == "postgres" || "$DB_HOST" == "127.0.0.1" || "$DB_HOST" == "localhost" ]] \
      || guard_fail "DATABASE_URL" "mint host must be the staging service 'postgres' or loopback"
    [[ "$DB_PORT" == "5432" || "$DB_PORT" == "15432" || -z "$DB_PORT" ]] \
      || guard_fail "DATABASE_URL" "mint Postgres port must be 5432 (container) or 15432 (host)"

    require_var REDIS_DB2_URL
    validate_redis_url REDIS_DB2_URL "$REDIS_DB2_URL"
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
    hp="$(http_authority LITELLM_BASE "$LITELLM_BASE")"
    [[ "$hp" == "172.17.0.1:14000" || "$hp" == "host.docker.internal:14000" || "$hp" == "mock-llm:14000" ]] \
      || guard_fail "LITELLM_BASE" "mint must use the mock LiteLLM admin stub (got '$hp'; live :4000 forbidden)"
    [[ "$LITELLM_BASE" != *"ovid-gateway-litellm-1"* ]] \
      || guard_fail "LITELLM_BASE" "live LiteLLM container name is forbidden"

    # NEW-2: pin the host-published mint listeners too. PUBLIC_BASE_URL is
    # handed to clients; the public listener is 127.0.0.1:18091 and the
    # admin/internal listener is 127.0.0.1:18092.
    if [[ -n "${PUBLIC_BASE_URL:-}" ]]; then
      validate_loopback_url PUBLIC_BASE_URL "$PUBLIC_BASE_URL" 18091
    fi
    if [[ -n "${PUBLIC_PORT:-}" ]]; then
      [[ "$PUBLIC_PORT" == "8091" ]] \
        || guard_fail "PUBLIC_PORT" "mint public container port must be 8091 (got '$PUBLIC_PORT')"
    fi
    if [[ -n "${ADMIN_PORT:-}" ]]; then
      [[ "$ADMIN_PORT" == "8092" ]] \
        || guard_fail "ADMIN_PORT" "mint admin container port must be 8092 (got '$ADMIN_PORT')"
    fi

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
  # NEW-8: `up` already validates the mint file; the standalone `guard` gate
  # must too. It is optional here only because a host-side-only guard may run
  # before the mint file is created; `up` still requires it.
  if [[ -f "$MINT_ENV_FILE" ]]; then
    guard_mint_env_file "$MINT_ENV_FILE" "$OVID_INTERNAL_API_SECRET"
  fi
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
  # The BullMQ prefix the staging gateway/worker ACTUALLY use. Their mains pass
  # no `prefix` option, so BullMQ's default "bull" applies — a value of
  # "bull:staging" here once sent two chaos scenarios to inspect queues nobody
  # writes to. Do not change this without threading the same prefix into the
  # gateway and worker queue construction.
  printf 'BULL_PREFIX=%s\n' "${BULL_PREFIX:-bull}"
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

  # ORDERING: the mint applies its boot re-sync immediately and queries money
  # tables (image_cards, …). On a fresh staging database those do not exist
  # until the migrations run, and the mint then exits with
  # `relation "image_cards" does not exist` — taking the gateway's
  # `depends_on: mint healthy` down with it. So: bring up the DATA services
  # first, migrate, and only then start gateway + mint. (Found on the first
  # real staging bring-up, 2026-10-18; production is unaffected because
  # provision.sh migrates before any compose up.)
  compose up -d --build postgres redis-q redis-mint
  log "running migrations against $DATABASE_URL"
  ( cd "$CLOUD_DIR" && node packages/db/dist/migrate-cli.js "$DATABASE_URL" )
  compose up -d --build

  # P10 Task 8: the permanent egress corpus requires this table. Loading it
  # after the compose bring-up keeps a failed `up` from leaving a host-level
  # filter behind; `down` removes it. Separate table from prod `ovid_sandbox`.
  install_staging_egress

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
  # P10 Task 8: remove the staging egress table (idempotent; prod untouched).
  remove_staging_egress
  live_check after || log "WARNING: live stack post-check failed"
}

cmd_worker_start() {
  local overrides=() env_file="$ENV_FILE"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)
        [[ $# -ge 2 ]] || die "--env needs K=V"
        overrides+=("$2")
        shift 2
        ;;
      --env-file)
        [[ $# -ge 2 ]] || die "--env-file needs a path"
        env_file="$2"
        shift 2
        ;;
      *) die "worker-start: unknown argument '$1'" ;;
    esac
  done

  # NEW-1: check the overrides BEFORE reading the file, then load/validate the
  # file, then apply the overrides and re-run every rule. The value that
  # reaches `exec env ... node` is therefore the value `validate_env` approved.
  check_overrides "${overrides[@]}"
  guard_env_file "$env_file"
  apply_overrides "${overrides[@]}"
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
  # Deploy-audit #1, staging twin of the worker unit's ExecStartPre nft check:
  # refuse to start the staging worker while the staging egress table is not
  # loaded — its sandbox uids would run with unfiltered egress. Enforced only
  # where the table could have been loaded (root + nft present); otherwise
  # install_staging_egress already SKIPped loudly, so this warns the same way.
  if [[ "${EUID:-$(id -u)}" -eq 0 ]] && command -v nft >/dev/null 2>&1; then
    nft list table inet "$STAGING_EGRESS_TABLE" >/dev/null 2>&1 \
      || die "staging egress table inet $STAGING_EGRESS_TABLE not loaded — run '$0 up' first (refusing to start the staging worker with unfiltered sandbox egress)"
  else
    log "WARNING: cannot verify the staging egress table ($STAGING_EGRESS_TABLE) — not root or nft missing; the staging worker starts WITHOUT an egress filter"
  fi

  log "starting staging worker (workspaces $OVID_WORKSPACES_ROOT, uid base $OVID_SANDBOX_UID_BASE)"
  # The worker's SandboxManager enables +cpu +memory +pids on ITS cgroup. A
  # controller can only be enabled where the parent already exposes it, and a
  # slice created outside systemd has an empty subtree_control — the worker
  # then dies at init with ENOENT (cgroup v2 reports an unavailable controller
  # that way). Production's systemd unit does this in ExecStartPre; the
  # staging worker is a plain background process, so do it here.
  local staging_slice="/sys/fs/cgroup/${OVID_CGROUP_BASE%%/*}"
  if [[ -d /sys/fs/cgroup && "$staging_slice" == /sys/fs/cgroup/* ]]; then
    mkdir -p "$staging_slice" 2>/dev/null || true
    printf '+cpu +memory +pids' > "$staging_slice/cgroup.subtree_control" 2>/dev/null \
      || log "WARNING: could not enable controllers on $staging_slice (sandbox init may fail)"
  fi
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
  # NEW-7: the pidfile is removed below; never accept one outside the private
  # directory (a parsed file must not be able to target /opt or /var/lib).
  validate_tmp_file_path STAGING_WORKER_PIDFILE "/tmp/opencode"
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
  # The staging composition now runs the mock as a service on the staging
  # bridge (a host-bound mock is unreachable from the containers — the host
  # firewall drops container→host traffic). When that service holds the port,
  # starting a second host-side mock would fail to bind, so treat an already
  # listening control endpoint as success.
  if curl -s -o /dev/null --max-time 1 http://127.0.0.1:14000/_control/status 2>/dev/null; then
    log "mock LiteLLM already listening on 127.0.0.1:14000 (staging compose service) — nothing to do"
    return 0
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
  # NEW-7: same pidfile rule as the worker stop path.
  validate_tmp_file_path STAGING_MOCK_PIDFILE "/tmp/opencode"
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
