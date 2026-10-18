#!/usr/bin/env bash
# P10 Task 14 — one-command acceptance + release evidence.
#
# Runs the ordered release gates against the isolated staging composition,
# writes cloud/apps/load/reports/RELEASE-EVIDENCE-<YYYYMMDD>.md, and exits
# nonzero if ANY gate fails. The evidence file is written even on failure.
#
#   bash cloud/scripts/acceptance.sh                 # full run (staging up)
#   bash cloud/scripts/acceptance.sh --quick         # unit+e2e+security only
#   bash cloud/scripts/acceptance.sh --dry-run       # print gates, run nothing
#   bash cloud/scripts/acceptance.sh --list          # alias for --dry-run
#
# Gate ordering is load-bearing: staging comes up (gate 3) BEFORE the full
# security suite (gate 4). The sandbox-isolation corpus needs the staging
# composition; running it first would report SKIPPED on every release box.
#
# Review Focus #4 is wired for real: gate 4 parses the machine-readable
# `security corpus: N ran, M SKIPPED: …` line emitted by
# apps/e2e/src/security/skipReport.ts. On a release-box run (the default,
# ACCEPTANCE_REQUIRE_FULL_SECURITY=1) a missing summary, ran==0, or any
# skipped group FAILS the gate. CI sets ACCEPTANCE_REQUIRE_FULL_SECURITY=0.
#
# Owner-gated gates (marked in the output and evidence):
#   - 8b watch --self-test     (needs ALERT_TELEGRAM_* or OVID_ALERT_WEBHOOK_URL)
#   - 8c verify-r2.mjs         (needs OVID_R2_* credentials)
# Set ACCEPTANCE_REQUIRE_OWNER_GATES=1 to make "not configured" a failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CLOUD_DIR/.." && pwd)"
STAGING="$CLOUD_DIR/scripts/staging.sh"
LOAD_DIR="$CLOUD_DIR/apps/load"
REPORTS_DIR="$LOAD_DIR/reports"
ENV_FILE="${STAGING_ENV_FILE:-$CLOUD_DIR/deploy/.env.staging}"
COMPOSE_FILE="$CLOUD_DIR/deploy/docker-compose.staging.yml"
DATE_UTC="$(date -u +%Y%m%d)"
EVIDENCE="$REPORTS_DIR/RELEASE-EVIDENCE-$DATE_UTC.md"

QUICK=0
DRY_RUN=0
REQUIRE_FULL_SECURITY="${ACCEPTANCE_REQUIRE_FULL_SECURITY:-1}"
REQUIRE_OWNER_GATES="${ACCEPTANCE_REQUIRE_OWNER_GATES:-0}"

# Work directory for per-gate logs (kept with ACCEPTANCE_KEEP_LOGS=1).
WORK_DIR="${ACCEPTANCE_WORK_DIR:-}"
if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ovid-acceptance.XXXXXX")"
fi
BASELINE="$WORK_DIR/live-baseline.txt"
LOAD_REPORT="$REPORTS_DIR/load-smoke10-$DATE_UTC.md"
LOAD_JSON="$REPORTS_DIR/load-smoke10-$DATE_UTC.json"
CANARY_LOAD_REPORT="$REPORTS_DIR/load-smoke10-canary-$DATE_UTC.md"
CANARY_LOAD_JSON="$REPORTS_DIR/load-smoke10-canary-$DATE_UTC.json"
CHAOS_REPORT="$REPORTS_DIR/chaos-$DATE_UTC.md"
CANARY_DIR="$WORK_DIR/canary"
GATEWAY_LOG="$WORK_DIR/gateway.log"
CANARY_WRAPPER="$WORK_DIR/canary-workload.sh"

START_EPOCH="$(date +%s)"

usage() {
  cat <<'EOF'
usage: acceptance.sh [--quick] [--dry-run|--list] [--help]

  (no flags)   full acceptance: build, typecheck, staging bring-up, full
               tests + security corpus, smoke10 load, worker-kill chaos,
               canary sweep, live-unaffected, owner-gated checks, teardown,
               release evidence
  --quick      skip the load/chaos/canary gates (gates 5-7); still runs
               build, typecheck, tests + security, owner-gated checks and
               evidence. When cloud/deploy/.env.staging exists, staging
               bring-up, live-unaffected and teardown also run (the sandbox
               corpus needs staging). When it does not exist, the CI path is
               used: staging gates are skipped and gate 4 runs against the
               caller's TEST_DATABASE_URL/TEST_REDIS_URL.
  --dry-run    print every gate, its exact command, quick-mode skips and
  --list       owner-gated markers; execute nothing and write no evidence
  --help       this text

Environment:
  ACCEPTANCE_REQUIRE_FULL_SECURITY=1|0  default 1. On a release box, gate 4
                                        fails if the sandbox security corpus
                                        reports SKIPPED (or did not run).
                                        CI sets 0.
  ACCEPTANCE_REQUIRE_OWNER_GATES=1|0    default 0. When 1, an unconfigured
                                        owner-gated gate (8b/8c) fails.
  ACCEPTANCE_WORK_DIR=<dir>             keep per-gate logs in <dir>.
  ACCEPTANCE_KEEP_LOGS=1                do not delete the work directory.
  STAGING_ENV_FILE=<path>               staging env file (default
                                        cloud/deploy/.env.staging).

Evidence: cloud/apps/load/reports/RELEASE-EVIDENCE-<YYYYMMDD>.md
EOF
}

die() {
  printf 'acceptance: ERROR: %s\n' "$*" >&2
  exit 2
}

for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --dry-run|--list) DRY_RUN=1 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument '$arg' (try --help)" ;;
  esac
done

case "$REQUIRE_FULL_SECURITY" in
  0|1) ;;
  *) die "ACCEPTANCE_REQUIRE_FULL_SECURITY must be 0 or 1 (got '$REQUIRE_FULL_SECURITY')" ;;
esac
case "$REQUIRE_OWNER_GATES" in
  0|1) ;;
  *) die "ACCEPTANCE_REQUIRE_OWNER_GATES must be 0 or 1 (got '$REQUIRE_OWNER_GATES')" ;;
esac

# ── dry-run / gate inventory ────────────────────────────────────────────────

preflight_line() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  %-46s present\n' "$label"
  else
    printf '  %-46s MISSING\n' "$label"
  fi
}

print_dry_run() {
  local mode="full"
  local gate5_tag="REQUIRED unless --quick"
  local gate6_tag="REQUIRED unless --quick"
  local gate7_tag="REQUIRED unless --quick"
  local gate3_tag="REQUIRED"
  local gate8_tag="REQUIRED"
  local gate9_tag="REQUIRED"
  local quick_staging_note=""
  if [[ "$QUICK" -eq 1 ]]; then
    mode="quick (gates 5-7 skipped)"
    gate5_tag="SKIPPED IN --quick"
    gate6_tag="SKIPPED IN --quick"
    gate7_tag="SKIPPED IN --quick"
    if [[ -f "$ENV_FILE" ]]; then
      quick_staging_note="staging env present -> gates 3/4/8/9 still run (security corpus needs staging)"
    else
      quick_staging_note="no staging env file -> CI path: gates 3/8/9 skipped, gate 4 uses existing TEST_DATABASE_URL/TEST_REDIS_URL"
      gate3_tag="SKIPPED IN --quick (no staging env)"
      gate8_tag="SKIPPED IN --quick (no staging env)"
      gate9_tag="SKIPPED IN --quick (no staging env)"
    fi
  fi
  cat <<EOF
Ovid Cloud acceptance — DRY RUN (${mode})
  repo:            $REPO_ROOT
  cloud dir:       $CLOUD_DIR
  staging script:  $STAGING
  evidence path:   $EVIDENCE
  work dir:        $WORK_DIR
  full security:   ACCEPTANCE_REQUIRE_FULL_SECURITY=${REQUIRE_FULL_SECURITY}
  owner gates:     ACCEPTANCE_REQUIRE_OWNER_GATES=${REQUIRE_OWNER_GATES}
  quick staging:   ${quick_staging_note:-n/a (full run)}

Preflight (informational only; the dry run executes nothing):
EOF
  preflight_line "pnpm" command -v pnpm
  preflight_line "node" command -v node
  preflight_line "docker" command -v docker
  preflight_line "cloud/scripts/staging.sh" test -f "$STAGING"
  preflight_line "cloud/deploy/.env.staging" test -f "$ENV_FILE"
  preflight_line "cloud/deploy/docker-compose.staging.yml" test -f "$COMPOSE_FILE"
  preflight_line "cloud/deploy/Dockerfile.mint (P9-T18)" test -f "$CLOUD_DIR/deploy/Dockerfile.mint"
  preflight_line "apps/load/dist/cli.js" test -f "$LOAD_DIR/dist/cli.js"
  preflight_line "apps/load/dist/chaosCli.js" test -f "$LOAD_DIR/dist/chaosCli.js"
  preflight_line "apps/load/dist/canaryCli.js" test -f "$LOAD_DIR/dist/canaryCli.js"
  preflight_line "apps/watch/dist/main.js" test -f "$CLOUD_DIR/apps/watch/dist/main.js"
  preflight_line "packages/account/tsconfig.check.json" test -f "$CLOUD_DIR/packages/account/tsconfig.check.json"
  preflight_line "cloud/deploy/ROLLOUT.md (Task 13)" test -f "$CLOUD_DIR/deploy/ROLLOUT.md"
  cat <<EOF

GATE 1 build [REQUIRED]
  cwd: $CLOUD_DIR
  command: pnpm install --frozen-lockfile && pnpm -r build

GATE 2 typecheck [REQUIRED]
  cwd: $CLOUD_DIR
  command: pnpm -r --parallel exec tsc -p tsconfig.check.json --noEmit

GATE 3 staging-isolation-and-bring-up [${gate3_tag}]
  commands (in order):
    $STAGING live-check --write-baseline <work>/live-baseline.txt
    $STAGING guard
    $STAGING up
    $STAGING mock-start
    $STAGING worker-start
  note: 'guard' explicitly re-proves that prod-valued env is refused;
        'up' also runs the guard internally. The live baseline is captured
        here so gate 8 spans gates 3-7.
  BLOCKER: none for the build itself — deploy/Dockerfile.mint, ROLLOUT.md
           and packages/account/tsconfig.check.json all now exist. See the
           known-blockers list at the end for what still gates the FULL run.

GATE 4 full-suite-and-security [REQUIRED]
  cwd: $CLOUD_DIR
  command: pnpm -r --workspace-concurrency=1 test   (serial: db suites DROP the schema)
  env: TEST_DATABASE_URL=<staging DATABASE_URL>
       TEST_REDIS_URL=<staging REDIS_Q_URL>
       OVID_ROOTFS=${OVID_ROOTFS:-/opt/ovid-rootfs/current}
       OVID_STAGING_NFT_TABLE=${OVID_STAGING_NFT_TABLE:-sandbox_egress_staging}
  fail condition (ACCEPTANCE_REQUIRE_FULL_SECURITY=1):
    - no 'security corpus: N ran, M SKIPPED' line  (corpus did not execute)
    - ran == 0
    - skipped > 0 (each reason printed in the gate log)
    - any '[security] ... SKIPPED' line from auth-surface/route-sweep/
      secrets-at-rest
  note: this gate MUST follow gate 3. The sandbox corpus requires staging up.

GATE 4b security-regressions [REQUIRED when the worker env is present]
  cwd: $CLOUD_DIR
  command: bash scripts/security-regressions.sh   (with /opt/ovid-cloud/worker.env)
  asserts: tunnels/proxies/scanners/miners and heavy toolchains are refused;
           outbound 22/25/7844/3333 dropped and 443 allowed; a package
           postinstall never executes; host /etc/shadow and other users'
           workspaces are unreadable; metadata + RFC1918 egress dropped.
           Needs root, bwrap, cgroups, the rootfs and the nft rules.

GATE 5 load-smoke10 [${gate5_tag}]
  cwd: $CLOUD_DIR
  command: node apps/load/dist/cli.js load --profile smoke10 --target staging
             --thresholds smoke --out $LOAD_REPORT --json $LOAD_JSON
  extra: positive-data check on the JSON (users=10, runsStarted>0,
         runsCompleted>0, eventDelivery.samples>0, integrity zeroes,
         harness.maxPendingFrames + latencyFloorP95Ms present, zero
         threshold failures) -> a missing measurement can never PASS.

GATE 6 chaos-worker-kill [${gate6_tag}]
  cwd: $CLOUD_DIR
  command: node apps/load/dist/chaosCli.js --scenario worker-kill
             --out $CHAOS_REPORT
  extra: report must show '## worker-kill — PASS' AND both the
         'precondition' and 'inject' assertion rows PASS (no vacuous green).

GATE 7 canary-sweep [${gate7_tag}]
  cwd: $CLOUD_DIR
  command: node apps/load/dist/canaryCli.js
             --captures-dir $CANARY_DIR
             --log $GATEWAY_LOG
             --log <staging worker log> --log <staging mock log>
             --database-url <staging DATABASE_URL>
             --redis-url <staging REDIS_Q_URL>
             -- <wrapper: smoke10 load, then docker compose logs gateway>
  extra: 'canary-sweep: PASS — zero leaks', workload exit=0, and the canary
         smoke10 JSON passes the same positive-data check.
  scope: canaries are injected into the WRAPPED WORKLOAD's environment. This
         proves the load client/staging logs do not leak them; it does NOT put
         canaries into the gateway/worker configuration (those use .env).

GATE 7b canary-stack [${gate7_tag}]
  cwd: $CLOUD_DIR
  command: node apps/load/dist/canaryCli.js --in-process-stack --strict
             --captures-dir $CANARY_DIR/stack
             --database-url <staging DATABASE_URL (ADMIN)>
             --redis-url <staging REDIS_Q_URL (ADMIN)>
             --stack-proof $CANARY_DIR/stack/proof.json
  extra: provisions a disposable DB role + Redis ACL user whose passwords ARE
         canaries, runs the SHIPPED gateway+worker with canaries as the real
         DATABASE_URL / REDIS_Q_URL / OVID_MASTER_KEY / mint / LiteLLM config,
         drives one authenticated run to a terminal event plus a BYOK upload,
         then scans. The proof file must show run_completed, a byok row, and
         mirror/event counts > 0 — an empty workload cannot pass.
  note: this is the only gate that proves the DB/Redis/BYOK paths do not leak.

GATE 8 live-unaffected [${gate8_tag}]
  command: $STAGING live-check --baseline <work>/live-baseline.txt
  asserts: https://api.ovidsi.com/healthz == 200, every ovid-gateway-*
           container Up, every StartedAt identical to gate 3's baseline.

GATE 8b watch-self-test [OWNER-GATED]
  cwd: $CLOUD_DIR
  command: pnpm --filter @ovid/watch self-test
  runs only when ALERT_TELEGRAM_BOT_TOKEN+ALERT_TELEGRAM_CHAT_ID or
  OVID_ALERT_WEBHOOK_URL is configured; otherwise recorded OWNER-GATED.

GATE 8c r2-verification [OWNER-GATED]
  command: node $CLOUD_DIR/scripts/verify-r2.mjs
  runs only when OVID_R2_ACCOUNT_ID, OVID_R2_ACCESS_KEY_ID,
  OVID_R2_SECRET_ACCESS_KEY and OVID_R2_BUCKET are all set; otherwise
  recorded OWNER-GATED.

GATE 9 teardown [${gate9_tag}]
  commands (each attempted):
    $STAGING worker-stop graceful
    $STAGING mock-stop
    $STAGING down

GATE 10 release-evidence [REQUIRED]
  writes: $EVIDENCE
  contains: box facts, git HEAD/branch/dirty count, per-gate PASS/FAIL,
            security corpus ran/skipped + reasons, load/chaos/canary report
            references, live-unaffected block, owner-gated statuses, raw
            per-gate output, total duration. Written on failure too.

Known blockers (reported, not worked around):
  - None left in the scripts. The former 'sandbox_egress_staging' blocker is
    CLEARED: staging.sh now installs that table in 'up' and removes it in
    'down' (install_staging_egress/remove_staging_egress, rendered by
    @ovid/sandbox's renderNftRuleset, a SEPARATE table from production's
    ovid_sandbox). What remains is the owner-gated run itself: it needs root
    for nft, a real bwrap/rootfs, and the staging stack.
  - Also CLEARED since this text was first written: Dockerfile.mint, ROLLOUT.md
    and packages/account/tsconfig.check.json now all exist. Do not defer the
    run for those.

Dry run complete: nothing was executed, staging was not touched, and no
evidence file was written.
EOF
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  print_dry_run
  # The dry run must not leave a temp dir behind. An explicitly supplied
  # ACCEPTANCE_WORK_DIR is never removed.
  if [[ -z "${ACCEPTANCE_WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
  exit 0
fi

mkdir -p "$WORK_DIR" "$REPORTS_DIR"

# ── gate runner / results ───────────────────────────────────────────────────

GATE_NUMBERS=()
GATE_NAMES=()
GATE_STATUSES=()
GATE_NOTES=()
GATE_LOGS=()
FAILED=0
LAST_GATE_RC=0

record_gate() {
  local num="$1" name="$2" status="$3" note="${4:-}"
  GATE_NUMBERS+=("$num")
  GATE_NAMES+=("$name")
  GATE_STATUSES+=("$status")
  GATE_NOTES+=("$note")
  GATE_LOGS+=("$WORK_DIR/gate-$num.log")
  printf 'GATE %s %s: %s%s\n' "$num" "$name" "$status" "${note:+ ($note)}"
  if [[ "$status" == "FAIL" ]]; then
    FAILED=1
  fi
}

record_skip() {
  record_gate "$1" "$2" "SKIPPED" "$3"
}

# Runs a gate function in a subshell with errexit, captures stdout+stderr to
# a per-gate log, prints it, applies an optional POST_CHECK, and records the
# result. Returns 0 always; inspect LAST_GATE_RC.
run_gate() {
  local num="$1" name="$2"
  shift 2
  local log="$WORK_DIR/gate-$num.log"
  local rc=0
  echo
  echo "──────── GATE $num $name ────────"
  set +e
  ( set -e; "$@" ) >"$log" 2>&1
  rc=$?
  if [[ $rc -eq 0 && -n "${POST_CHECK:-}" ]]; then
    "$POST_CHECK" "$log" >>"$log" 2>&1
    rc=$?
  fi
  set -e
  cat "$log"
  if [[ $rc -eq 0 ]]; then
    record_gate "$num" "$name" "PASS"
  else
    record_gate "$num" "$name" "FAIL" "exit $rc"
  fi
  LAST_GATE_RC=$rc
  return 0
}

run_owner_gate() {
  local num="$1" name="$2" configured="$3"
  shift 3
  local log="$WORK_DIR/gate-$num.log"
  echo
  echo "──────── GATE $num $name [OWNER-GATED] ────────"
  if ! "$configured" >/dev/null 2>&1; then
    echo "OWNER-GATED: $name not run — required credentials/sink are not configured."
    if [[ "$REQUIRE_OWNER_GATES" == "1" ]]; then
      record_gate "$num" "$name" "FAIL" "owner-gated but not configured"
      LAST_GATE_RC=1
    else
      record_gate "$num" "$name" "OWNER-GATED" "not configured"
      LAST_GATE_RC=0
    fi
    return 0
  fi
  set +e
  ( set -e; "$@" ) >"$log" 2>&1
  local rc=$?
  set -e
  cat "$log"
  if [[ $rc -eq 0 ]]; then
    record_gate "$num" "$name" "PASS" "owner-gated"
  else
    record_gate "$num" "$name" "FAIL" "owner-gated, exit $rc"
  fi
  LAST_GATE_RC=$rc
  return 0
}

# ── gate bodies ─────────────────────────────────────────────────────────────

gate1_build() {
  pnpm install --frozen-lockfile
  pnpm -r build
}

gate2_typecheck() {
  pnpm -r --parallel exec tsc -p tsconfig.check.json --noEmit
}

gate3_staging() {
  # Read-only baseline first: gate 8 compares against it, spanning 3-7.
  "$STAGING" live-check --write-baseline "$BASELINE"
  # Explicit Review Focus #1 gate: prod-valued env must be refused.
  "$STAGING" guard
  "$STAGING" up
  "$STAGING" mock-start
  "$STAGING" worker-start
}

load_staging_env() {
  local env_text key value
  env_text="$(bash "$STAGING" env)" || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      STAGING_DATABASE_URL|STAGING_REDIS_Q_URL|STAGING_GATEWAY_URL|STAGING_MOCK_LLM_URL|STAGING_WORKER_PIDFILE|STAGING_MOCK_PIDFILE|BULL_PREFIX)
        printf -v "$key" '%s' "$value"
        export "$key"
        ;;
    esac
  done <<< "$env_text"
  [[ -n "${STAGING_DATABASE_URL:-}" && -n "${STAGING_REDIS_Q_URL:-}" ]]
}

gate4_tests() {
  # Full runs resolved these from staging.sh env (gate 3). In --quick mode
  # without a staging env file, fall back to the caller's CI/dev service
  # URLs (the GitHub workflow exports them). Never overwrite a resolved
  # staging URL with an empty value.
  if [[ -n "${STAGING_DATABASE_URL:-}" ]]; then
    export TEST_DATABASE_URL="$STAGING_DATABASE_URL"
  fi

  # A DEDICATED database for the suite while the staging stack is live.
  # packages/db's suites DROP and re-create the whole schema, and gate 4 runs
  # while gate 3's gateway/worker/mint are attached to the STAGING database.
  # Sharing it left the live worker querying tables that had just been
  # replaced: gate 5 then accepted 60 runs and the worker started ZERO.
  # The schema is migrated here with the deploy path's own migrate().
  local accept_db="ovid_accept_$$"
  if [[ -n "${STAGING_DATABASE_URL:-}" ]] && command -v node >/dev/null 2>&1 \
     && [[ -f "$CLOUD_DIR/packages/db/dist/migrate-cli.js" ]]; then
    if node --input-type=module -e '
      import postgres from "postgres";
      const [url, name] = process.argv.slice(1);
      const admin = postgres(url, { max: 1, onnotice: () => {} });
      try { await admin.unsafe(`DROP DATABASE IF EXISTS "${name}" WITH (FORCE)`);
            await admin.unsafe(`CREATE DATABASE "${name}"`); }
      finally { await admin.end({ timeout: 5 }); }
    ' "$STAGING_DATABASE_URL" "$accept_db" >/dev/null 2>&1; then
      local accept_url="${STAGING_DATABASE_URL%/*}/$accept_db"
      if node "$CLOUD_DIR/packages/db/dist/migrate-cli.js" "$accept_url" >/dev/null 2>&1; then
        export TEST_DATABASE_URL="$accept_url"
        echo "gate 4: dedicated test database $accept_db (staging DB untouched)"
        cleanup_accept_db() {
          node --input-type=module -e '
            import postgres from "postgres";
            const [url, name] = process.argv.slice(1);
            const admin = postgres(url, { max: 1, onnotice: () => {} });
            try { await admin.unsafe(`DROP DATABASE IF EXISTS "${name}" WITH (FORCE)`); }
            finally { await admin.end({ timeout: 5 }); }
          ' "$STAGING_DATABASE_URL" "$accept_db" >/dev/null 2>&1 || true
        }
        ACCEPT_CLEANUPS+=(cleanup_accept_db)
      else
        echo "gate 4: WARN — could not migrate $accept_db; using $TEST_DATABASE_URL" >&2
      fi
    else
      echo "gate 4: WARN — could not create $accept_db; using $TEST_DATABASE_URL" >&2
    fi
  fi
  if [[ -n "${STAGING_REDIS_Q_URL:-}" ]]; then
    export TEST_REDIS_URL="$STAGING_REDIS_Q_URL"
  fi
  export OVID_TEST_QUEUE_PREFIX="${OVID_TEST_QUEUE_PREFIX:-ovid-accept-$DATE_UTC-$$}"
  export OVID_ROOTFS="${OVID_ROOTFS:-/opt/ovid-rootfs/current}"
  export OVID_STAGING_NFT_TABLE="${OVID_STAGING_NFT_TABLE:-sandbox_egress_staging}"

  # A DEDICATED Redis for the suite while the staging worker is live.
  # The worker's internal terminal machinery PSUBSCRIBEs `pty:ctl:*` on the
  # staging Redis and answers ANY ptyId (a random uuid is no protection), so
  # the gateway's pty-bridge tests receive foreign replies — "unexpected reply
  # for open", "terminal no longer exists". Pub/sub is NOT db-scoped, so only
  # a separate server isolates them. In CI (--quick, no staging worker) the
  # caller's TEST_REDIS_URL is used unchanged.
  # One EXIT trap for every resource this gate creates (bash keeps a single
  # EXIT trap per shell; a second `trap ... EXIT` would silently drop the
  # first). gate4_tests runs in run_gate's subshell, so this fires as the
  # gate finishes.
  ACCEPT_CLEANUPS=()
  cleanup_accept_resources() {
    local fn
    for fn in "${ACCEPT_CLEANUPS[@]}"; do "$fn"; done
  }
  trap cleanup_accept_resources EXIT

  local test_redis="" test_redis_port=""
  if [[ -n "${STAGING_WORKER_PIDFILE:-}" && -r "${STAGING_WORKER_PIDFILE:-/nonexistent}" ]] \
     && kill -0 "$(cat "$STAGING_WORKER_PIDFILE" 2>/dev/null || echo 0)" 2>/dev/null \
     && command -v docker >/dev/null 2>&1; then
    test_redis="ovid-accept-redis-$$"
    cleanup_test_redis() { docker rm -f "$test_redis" >/dev/null 2>&1 || true; }
    ACCEPT_CLEANUPS+=(cleanup_test_redis)
    if docker run -d --name "$test_redis" -p 127.0.0.1::6379 redis:7-alpine >/dev/null 2>&1; then
      for _ in $(seq 1 100); do
        if docker exec "$test_redis" redis-cli ping >/dev/null 2>&1; then break; fi
        sleep 0.1
      done
      test_redis_port="$(docker port "$test_redis" 6379/tcp | head -n 1 | sed 's/.*://')"
      if [[ -n "$test_redis_port" ]]; then
        export TEST_REDIS_URL="redis://127.0.0.1:$test_redis_port"
        echo "gate 4: dedicated test Redis on 127.0.0.1:$test_redis_port"
      fi
    else
      echo "gate 4: WARN — could not start the dedicated test Redis; using $TEST_REDIS_URL" >&2
      cleanup_test_redis
    fi
  fi

  # SERIAL on purpose: packages/db's suites DROP and re-migrate the shared
  # schema, so a parallel workspace run races packages/mcp and packages/storage
  # ("relation messages already exists" / "plugins does not exist"). The whole
  # suite is under a minute, so serial costs little and is deterministic.
  pnpm -r --workspace-concurrency=1 test
}

SECURITY_SUMMARY="<not run>"
SECURITY_RAN=""
SECURITY_SKIPPED=""

# Gate 4b — user-sandbox security regressions (founder directive 2026-10-18).
# Runs inside a REAL jail through the shipped SandboxManager: refused binaries,
# dropped outbound ports, blocked package scripts, cross-user/host file denial,
# metadata + RFC1918 egress. Needs the worker env (bwrap/cgroups/rootfs/nft).
gate4b_security() {
  ( set -a; source /opt/ovid-cloud/worker.env; set +a
    bash "$CLOUD_DIR/scripts/security-regressions.sh" )
}

gate4b_post_check() {
  local log="$1"
  local rc=0
  grep -qE '^security regressions: [0-9]+ passed, 0 failed' "$log" \
    || { echo "SECURITY REGRESSION GATE: FAIL — no all-pass summary line"; rc=1; }
  if grep -q '^\[FAIL\]' "$log"; then
    echo "SECURITY REGRESSION GATE: FAIL — one or more boundary checks failed"
    grep '^\[FAIL\]' "$log" || true
    rc=1
  fi
  [[ $rc -eq 0 ]] && echo "SECURITY REGRESSION GATE: PASS (sandbox boundary holds)"
  return $rc
}

gate4_post_check() {
  local log="$1"
  local summary ran skipped rc=0
  summary="$(grep -oE 'security corpus: [0-9]+ ran, .*' "$log" | tail -n 1 || true)"
  SECURITY_SUMMARY="${summary:-<missing>}"
  SECURITY_RAN=""
  SECURITY_SKIPPED=""
  if [[ -n "$summary" ]]; then
    SECURITY_RAN="$(sed -E 's/^security corpus: ([0-9]+) ran,.*/\1/' <<<"$summary")"
    SECURITY_SKIPPED="$(sed -E 's/^security corpus: [0-9]+ ran, ([0-9]+) SKIPPED.*/\1/' <<<"$summary")"
  fi

  echo "SECURITY CORPUS SUMMARY: ${summary:-<missing>}"
  echo "SECURITY CORPUS RAN: ${SECURITY_RAN:-<unknown>}"
  echo "SECURITY CORPUS SKIPPED: ${SECURITY_SKIPPED:-<unknown>}"

  if [[ "$REQUIRE_FULL_SECURITY" != "1" ]]; then
    echo "SECURITY GATE: ADVISORY (ACCEPTANCE_REQUIRE_FULL_SECURITY=0; skips do not fail)"
    if [[ -n "$summary" && "${SECURITY_SKIPPED:-0}" != "0" ]]; then
      echo "SECURITY GATE WARNING: corpus skipped on this box (CI mode)"
    fi
    return 0
  fi

  if [[ -z "$summary" ]]; then
    echo "SECURITY GATE: FAIL — no 'security corpus:' summary line; the corpus did not execute"
    rc=1
  else
    if [[ "${SECURITY_RAN:-0}" == "0" ]]; then
      echo "SECURITY GATE: FAIL — corpus ran 0 cases; it did not execute"
      rc=1
    fi
    if [[ "${SECURITY_SKIPPED:-1}" != "0" ]]; then
      echo "SECURITY GATE: FAIL — ${SECURITY_SKIPPED} group(s) SKIPPED on a release-box run"
      rc=1
    fi
  fi

  local skipped_lines
  skipped_lines="$(grep -E '\[security\] .*SKIPPED' "$log" || true)"
  if [[ -n "$skipped_lines" ]]; then
    echo "SECURITY GATE: FAIL — security suites reported SKIPPED lines:"
    printf '%s\n' "$skipped_lines"
    rc=1
  fi

  if [[ $rc -eq 0 ]]; then
    echo "SECURITY GATE: PASS (corpus ran ${SECURITY_RAN} case(s), 0 SKIPPED)"
  fi
  return $rc
}

# Shared positive-data gate for a load report JSON. Missing measurements fail.
POSITIVE_DATA_JS='
const fs = require("node:fs");
const file = process.argv[1];
let data;
try {
  data = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (err) {
  console.error("positive-data: cannot read report JSON: " + (err && err.message ? err.message : err));
  process.exit(1);
}
const report = data && data.report ? data.report : null;
const failures = data && Array.isArray(data.failures) ? data.failures : null;
const rows = [];
function check(name, ok, detail) { rows.push([name, Boolean(ok), detail]); }
const num = (value) => typeof value === "number" && Number.isFinite(value);
check("report present", report !== null, report ? "LoadReport object" : "missing report");
check("users=10", report && report.users === 10, report ? String(report.users) : "missing");
check("runsStarted>0", report && num(report.runsStarted) && report.runsStarted > 0, report ? String(report.runsStarted) : "missing");
check("runsCompleted>0", report && num(report.runsCompleted) && report.runsCompleted > 0, report ? String(report.runsCompleted) : "missing");
check("runsCompleted==runsStarted", report && report.runsCompleted === report.runsStarted, report ? String(report.runsCompleted) + "/" + String(report.runsStarted) : "missing");
check("eventDelivery.samples>0", report && report.eventDelivery && num(report.eventDelivery.samples) && report.eventDelivery.samples > 0, report && report.eventDelivery ? String(report.eventDelivery.samples) : "missing");
check("eventDelivery.p95Ms present", report && report.eventDelivery && num(report.eventDelivery.p95Ms), report && report.eventDelivery ? String(report.eventDelivery.p95Ms) : "missing");
check("integrity.lostEvents=0", report && report.integrity && report.integrity.lostEvents === 0, report && report.integrity ? String(report.integrity.lostEvents) : "missing");
check("integrity.duplicateEvents=0", report && report.integrity && report.integrity.duplicateEvents === 0, report && report.integrity ? String(report.integrity.duplicateEvents) : "missing");
check("integrity.gapsVsMirror=0", report && report.integrity && report.integrity.gapsVsMirror === 0, report && report.integrity ? String(report.integrity.gapsVsMirror) : "missing");
check("harness.maxPendingFrames present", report && report.harness && num(report.harness.maxPendingFrames), report && report.harness ? String(report.harness.maxPendingFrames) : "missing");
check("harness.latencyFloorP95Ms present", report && report.harness && num(report.harness.latencyFloorP95Ms), report && report.harness ? String(report.harness.latencyFloorP95Ms) : "missing");
check("threshold failures empty", failures !== null && failures.length === 0, failures === null ? "missing failures array" : JSON.stringify(failures));
for (const row of rows) console.log((row[1] ? "PASS" : "FAIL") + " " + row[0] + ": " + row[2]);
const bad = rows.filter((row) => !row[1]);
if (bad.length > 0) {
  console.error("positive-data: FAIL (" + bad.length + " missing/failed check(s)) — a missing measurement is not a pass");
  process.exit(1);
}
console.log("positive-data: PASS (all required measurements present)");
'

gate5_load() {
  rm -f "$LOAD_REPORT" "$LOAD_JSON"
  node apps/load/dist/cli.js load \
    --profile smoke10 \
    --target staging \
    --thresholds smoke \
    --out "$LOAD_REPORT" \
    --json "$LOAD_JSON"
  node -e "$POSITIVE_DATA_JS" "$LOAD_JSON"
}

gate5_post_check() {
  local log="$1"
  local rc=0
  [[ -s "$LOAD_REPORT" ]] || { echo "LOAD GATE: FAIL — markdown report missing ($LOAD_REPORT)"; rc=1; }
  [[ -s "$LOAD_JSON" ]] || { echo "LOAD GATE: FAIL — JSON report missing ($LOAD_JSON)"; rc=1; }
  if [[ $rc -eq 0 ]]; then
    node -e "$POSITIVE_DATA_JS" "$LOAD_JSON" >>"$log" 2>&1 || rc=1
  fi
  [[ $rc -eq 0 ]] && echo "LOAD GATE: PASS (thresholds + positive data)"
  return $rc
}

gate6_chaos() {
  rm -f "$CHAOS_REPORT"
  node apps/load/dist/chaosCli.js --scenario worker-kill --out "$CHAOS_REPORT"
}

gate6_post_check() {
  local log="$1"
  local rc=0
  if ! grep -qE '\[chaos\] worker-kill: PASS' "$log"; then
    echo "CHAOS GATE: FAIL — no '[chaos] worker-kill: PASS' line"
    rc=1
  fi
  if [[ ! -s "$CHAOS_REPORT" ]]; then
    echo "CHAOS GATE: FAIL — report missing ($CHAOS_REPORT)"
    return 1
  fi
  grep -qE '^## worker-kill .* PASS' "$CHAOS_REPORT" \
    || { echo "CHAOS GATE: FAIL — report header is not '## worker-kill — PASS'"; rc=1; }
  grep -qE '^\| `precondition` \| PASS \|' "$CHAOS_REPORT" \
    || { echo "CHAOS GATE: FAIL — precondition assertion did not PASS (vacuous-green guard)"; rc=1; }
  grep -qE '^\| `inject` \| PASS \|' "$CHAOS_REPORT" \
    || { echo "CHAOS GATE: FAIL — inject assertion did not PASS (failure was not injected)"; rc=1; }
  if grep -qE '^\| `[^`]+` \| FAIL \|' "$CHAOS_REPORT"; then
    echo "CHAOS GATE: FAIL — report contains FAIL assertion rows"
    grep -E '^\| `[^`]+` \| FAIL \|' "$CHAOS_REPORT" || true
    rc=1
  fi
  if ! grep -qE '^### Live stack \(before\)' "$CHAOS_REPORT" \
    || ! grep -qE '^### Live stack \(after\)' "$CHAOS_REPORT"; then
    echo "CHAOS GATE: FAIL — live before/after block missing from the report"
    rc=1
  fi
  [[ $rc -eq 0 ]] && echo "CHAOS GATE: PASS (precondition proven, failure injected, all assertions green)"
  return $rc
}

gate7_canary() {
  mkdir -p "$CANARY_DIR"
  cat > "$CANARY_WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
node "$LOAD_DIR/dist/cli.js" load \\
  --profile smoke10 \\
  --target staging \\
  --thresholds smoke \\
  --out "$CANARY_LOAD_REPORT" \\
  --json "$CANARY_LOAD_JSON"
# Capture the gateway log after the workload so the sweep can scan it.
docker compose --env-file "$ENV_FILE" -p ovid-cloud-staging \\
  -f "$COMPOSE_FILE" logs --no-color gateway > "$GATEWAY_LOG" 2>&1 || true
EOF
  chmod +x "$CANARY_WRAPPER"
  node apps/load/dist/canaryCli.js \
    --captures-dir "$CANARY_DIR" \
    --log "$GATEWAY_LOG" \
    --log "${STAGING_WORKER_LOG:-/tmp/opencode/ovid-staging-worker.log}" \
    --log "${STAGING_MOCK_LOG:-/tmp/opencode/ovid-staging-mock.log}" \
    --database-url "$STAGING_DATABASE_URL" \
    --redis-url "$STAGING_REDIS_Q_URL" \
    -- bash "$CANARY_WRAPPER"
}

gate7_post_check() {
  local log="$1"
  local rc=0
  grep -qE 'canary-sweep: PASS .* zero leaks' "$log" \
    || { echo "CANARY GATE: FAIL — no 'canary-sweep: PASS — zero leaks' line"; rc=1; }
  if grep -qE 'canary-sweep: LEAK ' "$log"; then
    echo "CANARY GATE: FAIL — canary leak(s) detected"
    grep -E 'canary-sweep: LEAK ' "$log" || true
    rc=1
  fi
  grep -qE 'canary-sweep: workload exit=0' "$log" \
    || { echo "CANARY GATE: FAIL — workload did not exit 0"; rc=1; }

  # A sweep that scanned nothing is not a pass. `runCanarySweep` silently skips
  # a --log path it cannot read, so a missing or empty gateway/worker/mock log
  # shrinks the corpus without failing anything — the sweep would then report
  # "PASS — zero leaks" having looked at almost nothing. Require every named
  # log to exist and be non-empty, and require the scanned count to cover all
  # three logs plus the two always-present corpora (db mirror + redis).
  local l
  for l in "$GATEWAY_LOG" "${STAGING_WORKER_LOG:-/tmp/opencode/ovid-staging-worker.log}" \
           "${STAGING_MOCK_LOG:-/tmp/opencode/ovid-staging-mock.log}"; do
    if [[ ! -s "$l" ]]; then
      echo "CANARY GATE: FAIL — sweep input is missing or empty: $l"
      echo "  (runCanarySweep skips unreadable --log paths silently, so this would be a blind spot)"
      rc=1
    fi
  done
  local scanned
  scanned="$(grep -oE 'canary-sweep: scanned [0-9]+ corpus location\(s\)' "$log" \
    | tail -1 | grep -oE '[0-9]+' || true)"
  if [[ -z "$scanned" ]]; then
    echo "CANARY GATE: FAIL — no 'scanned N corpus location(s)' line"
    rc=1
  elif (( scanned < 5 )); then
    echo "CANARY GATE: FAIL — scanned only $scanned corpus location(s); expected >= 5 (3 logs + db + redis)"
    rc=1
  fi

  if [[ ! -s "$CANARY_LOAD_JSON" ]]; then
    echo "CANARY GATE: FAIL — canary load JSON missing ($CANARY_LOAD_JSON)"
    rc=1
  else
    node -e "$POSITIVE_DATA_JS" "$CANARY_LOAD_JSON" >>"$log" 2>&1 || rc=1
  fi
  [[ $rc -eq 0 ]] && echo "CANARY GATE: PASS (zero leaks over $scanned corpus location(s); workload measured positively)"
  return $rc
}

# Gate 7b — the STRONG canary sweep.
#
# Gate 7 injects the canaries into the load client's environment and scans the
# staging logs/DB/Redis for them. That proves the wrapped process does not dump
# its own env; it does NOT put the canaries into the gateway/worker/BYOK/mint
# configuration, because those services run with the staging .env. Gate 7b runs
# the shipped gateway + worker composition with canaries as the REAL config
# values (DATABASE_URL / REDIS_Q_URL / OVID_MASTER_KEY / mint + LiteLLM keys),
# drives one authenticated run to a terminal event plus a BYOK upload, and only
# then scans. Without it, "PASS — zero leaks" understates what was proven.
gate7b_canary_stack() {
  mkdir -p "$CANARY_DIR/stack"
  node apps/load/dist/canaryCli.js \
    --in-process-stack \
    --strict \
    --captures-dir "$CANARY_DIR/stack" \
    --database-url "$STAGING_DATABASE_URL" \
    --redis-url "$STAGING_REDIS_Q_URL" \
    --stack-proof "$CANARY_DIR/stack/proof.json"
}

gate7b_post_check() {
  local log="$1"
  local rc=0
  grep -qE 'canary-sweep: PASS .* zero leaks' "$log" \
    || { echo "CANARY-STACK GATE: FAIL — no 'PASS — zero leaks' line"; rc=1; }
  if grep -qE 'canary-sweep: LEAK ' "$log"; then
    echo "CANARY-STACK GATE: FAIL — canary leak(s) from the shipped stack"
    grep -E 'canary-sweep: LEAK ' "$log" || true
    rc=1
  fi
  # An empty workload must not read as a pass: require proof that a real run
  # reached a terminal event and a BYOK row was escrowed.
  local proof="$CANARY_DIR/stack/proof.json"
  if [[ ! -s "$proof" ]]; then
    echo "CANARY-STACK GATE: FAIL — stack proof missing ($proof)"
    rc=1
  else
    node -e '
      const fs = require("fs");
      const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const fail = [];
      if (!p.runId) fail.push("no runId");
      if (p.terminalEvent !== "run_completed") fail.push(`terminalEvent=${p.terminalEvent}`);
      if (!p.byokId) fail.push("no byok row");
      if (!(p.mirrorRows > 0)) fail.push(`mirrorRows=${p.mirrorRows}`);
      if (!(p.eventCount > 0)) fail.push(`eventCount=${p.eventCount}`);
      if (fail.length) { console.error("proof: " + fail.join(", ")); process.exit(1); }
      console.log(`proof: run=${p.runId} terminal=${p.terminalEvent} byok=${p.byokId} mirror=${p.mirrorRows} events=${p.eventCount}`);
    ' "$proof" || rc=1
  fi
  [[ $rc -eq 0 ]] && echo "CANARY-STACK GATE: PASS (canaries were the shipped stack's real config; a real run and a BYOK upload executed)"
  return $rc
}

gate8_live() {
  "$STAGING" live-check --baseline "$BASELINE"
}

gate8_post_check() {
  local log="$1"
  local rc=0
  grep -qE 'live stack unchanged' "$log" \
    || { echo "LIVE GATE: FAIL — staging.sh did not report 'live stack unchanged'"; rc=1; }
  grep -qE 'healthz=200' "$log" \
    || { echo "LIVE GATE: FAIL — live healthz was not 200"; rc=1; }
  if grep -qE 'status=.*(Exited|Restarting|unhealthy|dead)' "$log"; then
    echo "LIVE GATE: FAIL — a live container is not Up"
    grep -E 'status=.*(Exited|Restarting|unhealthy|dead)' "$log" || true
    rc=1
  fi
  if ! grep -qE '^  container=.* status=Up ' "$log"; then
    echo "LIVE GATE: FAIL — no ovid-gateway-* container snapshot found"
    rc=1
  fi
  [[ $rc -eq 0 ]] && echo "LIVE GATE: PASS (healthz 200, all ovid-gateway-* Up, StartedAt identical)"
  return $rc
}

watch_configured() {
  { [[ -n "${ALERT_TELEGRAM_BOT_TOKEN:-}" && -n "${ALERT_TELEGRAM_CHAT_ID:-}" ]] \
    || [[ -n "${OVID_ALERT_WEBHOOK_URL:-}" ]]; }
}

gate8b_watch_selftest() {
  pnpm --filter @ovid/watch self-test
}

r2_configured() {
  [[ -n "${OVID_R2_ACCOUNT_ID:-}" \
    && -n "${OVID_R2_ACCESS_KEY_ID:-}" \
    && -n "${OVID_R2_SECRET_ACCESS_KEY:-}" \
    && -n "${OVID_R2_BUCKET:-}" ]]
}

gate8c_r2() {
  node "$CLOUD_DIR/scripts/verify-r2.mjs"
}

gate9_teardown() {
  local rc=0
  "$STAGING" worker-stop graceful || rc=1
  "$STAGING" mock-stop || rc=1
  "$STAGING" down || rc=1
  return $rc
}

# ── evidence writer ─────────────────────────────────────────────────────────

write_evidence() {
  local status="PASS"
  [[ "$FAILED" -ne 0 ]] && status="FAIL"
  local duration=$(( $(date +%s) - START_EPOCH ))
  local git_head git_branch git_dirty
  git_head="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  git_branch="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo unknown)"
  git_dirty="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ' || true)"
  [[ "$git_dirty" =~ ^[0-9]+$ ]] || git_dirty="unknown"

  mkdir -p "$REPORTS_DIR"
  {
    echo "# Ovid Cloud release evidence — ${DATE_UTC}"
    echo
    echo "- generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- mode: $([[ "$QUICK" -eq 1 ]] && echo quick || echo full)"
    echo "- result: **${status}**"
    echo "- duration: ${duration}s"
    echo "- git HEAD: ${git_head} (branch ${git_branch}, ${git_dirty} dirty path(s))"
    echo "- host: $(hostname 2>/dev/null || echo unknown)"
    echo "- kernel: $(uname -sr 2>/dev/null || echo unknown)"
    echo "- cpus: $(nproc 2>/dev/null || echo unknown)"
    echo "- memory: $(free -m 2>/dev/null | awk 'NR==2 {print $2 " MiB total, " $7 " MiB available"}' || echo unknown)"
    echo "- disk /: $(df -Pm / 2>/dev/null | awk 'NR==2 {print $4 " MiB free of " $2 " MiB"}' || echo unknown)"
    echo "- node: $(node --version 2>/dev/null || echo unknown)"
    echo "- pnpm: $(pnpm --version 2>/dev/null || echo unknown)"
    echo "- docker: $(docker --version 2>/dev/null || echo unknown)"
    echo "- staging script: ${STAGING}"
    echo "- acceptance script: ${SCRIPT_DIR}/acceptance.sh"
    echo "- ACCEPTANCE_REQUIRE_FULL_SECURITY: ${REQUIRE_FULL_SECURITY}"
    echo "- ACCEPTANCE_REQUIRE_OWNER_GATES: ${REQUIRE_OWNER_GATES}"
    echo
    echo "## Gate summary"
    echo
    echo "| Gate | Name | Result | Notes |"
    echo "|---|---|---|---|"
    local i
    for i in "${!GATE_NUMBERS[@]}"; do
      echo "| ${GATE_NUMBERS[$i]} | ${GATE_NAMES[$i]} | ${GATE_STATUSES[$i]} | ${GATE_NOTES[$i]:-} |"
    done
    echo "| 10 | release-evidence | $( [[ "$FAILED" -eq 0 ]] && echo PASS || echo FAIL ) | this file |"
    echo
    echo "## Security corpus (Review Focus #4)"
    echo
    echo "- summary: ${SECURITY_SUMMARY}"
    echo "- ran: ${SECURITY_RAN:-<unknown>}"
    echo "- skipped: ${SECURITY_SKIPPED:-<unknown>}"
    echo "- release-box requirement: $([[ "$REQUIRE_FULL_SECURITY" == "1" ]] && echo "skips fail the gate" || echo "advisory (CI mode)")"
    echo
    echo "## Load"
    echo
    echo "- report: ${LOAD_REPORT}"
    echo "- json: ${LOAD_JSON}"
    echo "- positive-data gates: see GATE 5 output (missing measurements fail)"
    echo "- canary workload report: ${CANARY_LOAD_REPORT}"
    echo "- canary workload json: ${CANARY_LOAD_JSON}"
    echo
    echo "## Chaos"
    echo
    echo "- scenario: worker-kill"
    echo "- report: ${CHAOS_REPORT}"
    echo "- required assertions: precondition PASS + inject PASS + zero FAIL rows"
    echo
    echo "## Canary"
    echo
    echo "- captures: ${CANARY_DIR}"
    echo "- gateway log: ${GATEWAY_LOG}"
    echo "- result: see GATE 7 output (zero leaks required)"
    echo
    echo "## Live-unaffected"
    echo
    echo "- baseline: ${BASELINE} (captured at the start of GATE 3)"
    echo "- assertion: https://api.ovidsi.com/healthz == 200, every ovid-gateway-* Up, StartedAt identical"
    echo "- result: see GATE 8 output"
    echo
    echo "## Owner-gated"
    echo
    echo "- GATE 8b watch --self-test: see gate summary (OWNER-GATED when no sink is configured)"
    echo "- GATE 8c R2 verification: see gate summary (OWNER-GATED when OVID_R2_* is absent)"
    echo
    echo "## Raw gate output"
    echo
    for i in "${!GATE_NUMBERS[@]}"; do
      echo "### GATE ${GATE_NUMBERS[$i]} ${GATE_NAMES[$i]} — ${GATE_STATUSES[$i]}"
      echo
      echo '~~~text'
      if [[ -f "${GATE_LOGS[$i]}" ]]; then
        cat "${GATE_LOGS[$i]}"
      else
        echo "(no output captured)"
      fi
      echo '~~~'
      echo
    done
  } > "$EVIDENCE"

  [[ -s "$EVIDENCE" ]]
}

cleanup() {
  if [[ "${ACCEPTANCE_KEEP_LOGS:-0}" != "1" && -n "${WORK_DIR:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

# ── main flow ───────────────────────────────────────────────────────────────

cd "$CLOUD_DIR"

GATE3_OK=0
GATE3_ATTEMPTED=0
POST_CHECK=""

# --quick with no staging env file is the CI path: gates 1, 2, 4 run against
# the caller's TEST_DATABASE_URL/TEST_REDIS_URL (the GitHub workflow's service
# containers); staging/load/chaos/canary/live/teardown are skipped. On a
# release box (staging env present), --quick still brings staging up because
# the security corpus needs it.
RUN_STAGING=1
if [[ "$QUICK" -eq 1 && ! -f "$ENV_FILE" ]]; then
  RUN_STAGING=0
fi

# GATE 1 — build. Everything else depends on the built workspace.
run_gate 1 "build" gate1_build
if [[ "$LAST_GATE_RC" -ne 0 ]]; then
  record_skip 2 "typecheck" "gate 1 (build) failed"
  record_skip 3 "staging-isolation-and-bring-up" "gate 1 (build) failed"
  record_skip 4 "full-suite-and-security" "gate 1 (build) failed"
  record_skip 5 "load-smoke10" "gate 1 (build) failed"
  record_skip 6 "chaos-worker-kill" "gate 1 (build) failed"
  record_skip 7 "canary-sweep" "gate 1 (build) failed"
  record_skip 8 "live-unaffected" "gate 1 (build) failed"
  record_skip 8b "watch-self-test" "gate 1 (build) failed"
  record_skip 8c "r2-verification" "gate 1 (build) failed"
  record_skip 9 "teardown" "nothing was started"
  FAILED=1
else
  # GATE 2 — typecheck (tests included).
  run_gate 2 "typecheck" gate2_typecheck

  # GATE 3 — staging isolation guard + bring-up. Must precede the security
  # suite: the sandbox corpus needs the staging composition running.
  if [[ "$RUN_STAGING" -eq 1 ]]; then
    GATE3_ATTEMPTED=1
    run_gate 3 "staging-isolation-and-bring-up" gate3_staging
    if [[ "$LAST_GATE_RC" -eq 0 ]]; then
      GATE3_OK=1
      if ! load_staging_env; then
        echo "acceptance: failed to resolve staging env from 'staging.sh env'" >&2
        GATE3_OK=0
        record_gate "3-env" "staging-env" "FAIL" "staging.sh env did not resolve"
      fi
    fi
  else
    record_skip 3 "staging-isolation-and-bring-up" \
      "--quick without cloud/deploy/.env.staging (CI path; TEST_* used for gate 4)"
  fi

  # GATE 4 — full suite, including the permanent security corpus.
  # In a full run it must follow a successful gate 3. In the --quick CI path
  # it runs against the caller's TEST_* service URLs.
  if [[ "$RUN_STAGING" -eq 1 && "$GATE3_OK" -ne 1 ]]; then
    record_skip 4 "full-suite-and-security" "gate 3 (staging bring-up) failed"
  else
    POST_CHECK=gate4_post_check
    run_gate 4 "full-suite-and-security" gate4_tests
    POST_CHECK=""

    POST_CHECK=gate4b_post_check
    run_gate 4b "security-regressions" gate4b_security
    POST_CHECK=""
  fi

  # GATE 5-7 — staging load, chaos, canary. --quick skips them.
  if [[ "$QUICK" -eq 1 ]]; then
    record_skip 5 "load-smoke10" "--quick"
    record_skip 6 "chaos-worker-kill" "--quick"
    record_skip 7 "canary-sweep" "--quick"
    record_skip 7b "canary-stack" "--quick"
  elif [[ "$GATE3_OK" -eq 1 ]]; then
    POST_CHECK=gate5_post_check
    run_gate 5 "load-smoke10" gate5_load
    POST_CHECK=""

    POST_CHECK=gate6_post_check
    run_gate 6 "chaos-worker-kill" gate6_chaos
    POST_CHECK=""

    POST_CHECK=gate7_post_check
    run_gate 7 "canary-sweep" gate7_canary
    POST_CHECK=""

    POST_CHECK=gate7b_post_check
    run_gate 7b "canary-stack" gate7b_canary_stack
    POST_CHECK=""
  else
    record_skip 5 "load-smoke10" "gate 3 (staging bring-up) failed"
    record_skip 6 "chaos-worker-kill" "gate 3 (staging bring-up) failed"
    record_skip 7 "canary-sweep" "gate 3 (staging bring-up) failed"
    record_skip 7b "canary-stack" "gate 3 (staging bring-up) failed"
  fi

  # GATE 8 — live stack unaffected across gates 3-7 (needs the baseline
  # captured at the start of gate 3).
  if [[ -f "$BASELINE" ]]; then
    POST_CHECK=gate8_post_check
    run_gate 8 "live-unaffected" gate8_live
    POST_CHECK=""
  elif [[ "${GATE3_OK:-0}" -eq 1 ]]; then
    # staging.sh writes the baseline on a successful gate 3, so this means the
    # file was lost or the write failed. Recording SKIPPED here would let a
    # full run exit 0 with live-unaffected never asserted — fail closed.
    record_gate 8 "live-unaffected" "FAIL" \
      "gate 3 succeeded but the live baseline ($BASELINE) is missing"
  else
    record_skip 8 "live-unaffected" "no live baseline was captured (staging not started)"
  fi

  # GATE 8b / 8c — owner-gated; independent of staging.
  run_owner_gate 8b "watch-self-test" watch_configured gate8b_watch_selftest
  run_owner_gate 8c "r2-verification" r2_configured gate8c_r2

  # GATE 9 — teardown. Attempt it whenever staging was touched at all.
  if [[ "$GATE3_ATTEMPTED" -eq 1 ]]; then
    run_gate 9 "teardown" gate9_teardown
  else
    record_skip 9 "teardown" "staging was never started"
  fi
fi

# GATE 10 — evidence (always written, even when a gate failed).
echo
echo "──────── GATE 10 release-evidence ────────"
if write_evidence; then
  record_gate 10 "release-evidence" "PASS" "written to $EVIDENCE"
  printf '\nGATE 10 release-evidence: PASS (%s)\n' "$EVIDENCE" >> "$EVIDENCE"
else
  record_gate 10 "release-evidence" "FAIL" "could not write $EVIDENCE"
fi

echo
echo "Acceptance result: $( [[ "$FAILED" -eq 0 ]] && echo PASS || echo FAIL )"
echo "Evidence: $EVIDENCE"
if [[ "${ACCEPTANCE_KEEP_LOGS:-0}" == "1" ]]; then
  echo "Logs kept in: $WORK_DIR"
fi

if [[ "$FAILED" -ne 0 ]]; then
  exit 1
fi
exit 0
