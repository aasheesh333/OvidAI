#!/usr/bin/env bash
# sandbox-probe.sh — Ovid Cloud P2 Task 1: host sandbox-mechanism probe.
#
# PURPOSE
#   Verifies, on this host, which bwrap launch mechanism works for the Ovid
#   sandbox (research p2-bubblewrap-feasibility.md §8.2, decision matrix):
#     branch a: unprivileged bwrap as uid 200000 (kernel AppArmor userns
#               restriction either off or permissive for connected /proc paths)
#     branch b: same, after loading the ovid-sandbox AppArmor profile
#               (cloud/deploy/sandbox/ovid-sandbox.apparmor — grants bwrap
#               userns_create, flatpak/podman precedent)
#     branch c: "rootmap" — worker stays root, pre-unshares a userns with an
#               explicit `0 200000 1` map, bwrap joins it via --userns FD
#               (exec bwrap WITHOUT --unshare-user) so jail-inner uid 0 maps
#               to host uid 200000
#   Also measures: S5 ctty sanity through bwrap --new-session on a pty (the
#   node-pty question; Task 9 lands the runtime confirmation), and S6 cpu.max
#   throttling (research open item: expect ~50% of an uncapped 2s busy loop).
#
# USAGE (owner-gated — Steps 3-4 of the plan; this file is dry-validated only):
#   sudo bash cloud/deploy/sandbox/sandbox-probe.sh 2>&1 | \
#     tee /tmp/ovid-probe-$(date -u +%Y%m%dT%H%M%S).log
#
# SIDE EFFECTS (stop-condition, per plan Task 1 Step 3):
#   - installs bubblewrap via apt if /usr/bin/bwrap is absent (kept installed;
#     production prerequisite)
#   - on branch b only: copies ovid-sandbox.apparmor to /etc/apparmor.d and
#     loads it with apparmor_parser -r (kept; production prerequisite)
#   - everything else is scratch state removed on exit (S7 cleanup)
#
# EXIT CODE
#   0  — exactly one branch (a/b/c) succeeded and S5+S6 passed; the DECISION
#        line for cloud/deploy/sandbox/MECHANISM.md is printed in the summary.
#   1  — no branch succeeded (STOP: escalate to owner per Step 4), or a hard
#        section (S0/S1/S5/S6) failed. Evidence is always printed before exit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly SANDBOX_UID=200000
readonly BWRAP=/usr/bin/bwrap
readonly PROFILE_SRC="${SCRIPT_DIR}/ovid-sandbox.apparmor"
readonly PROFILE_DST=/etc/apparmor.d/ovid-sandbox
readonly CGROOT=/sys/fs/cgroup

SCRATCH=""            # S2 scratch dir (removed in cleanup)
CG_PROBE=""           # S6 scratch cgroup (removed in cleanup)
PROFILE_INSTALLED=0   # 1 if S3 installed+loaded the AppArmor profile
BWRAP_INSTALLED=0     # 1 if S1 apt-installed bubblewrap
BRANCH=""             # "a" | "b" | "c" | "" (none worked)
S5_RESULT="SKIPPED"
S6_RESULT="SKIPPED"
HARD_FAILURE=0

log()      { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
section()  { printf '\n========== %s ==========\n' "$*"; }
# Every host mutation is preceded by a MUTATION: log line (plan requirement).
mut()      { printf 'MUTATION: %s\n' "$*"; }
apparmor_evidence() { dmesg 2>/dev/null | grep -i apparmor | tail -20 || true; }

cleanup() {
  section "S7 cleanup"
  if [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ]; then
    mut "rm -rf ${SCRATCH} (probe scratch dir)"
    rm -rf "$SCRATCH" || log "WARN: could not remove scratch ${SCRATCH}"
  fi
  if [ -n "$CG_PROBE" ] && [ -d "$CG_PROBE" ]; then
    mut "rmdir ${CG_PROBE} (probe cgroup)"
    rmdir "$CG_PROBE" 2>/dev/null || log "WARN: could not remove ${CG_PROBE}"
  fi
  log "Left in place (production prerequisites):"
  if [ "$BWRAP_INSTALLED" -eq 1 ]; then
    log "  bubblewrap installed by S1: $(dpkg-query -W -f '${Version}' bubblewrap 2>/dev/null || echo unknown)"
  else
    log "  bubblewrap was already present (not installed by this probe)"
  fi
  if [ "$PROFILE_INSTALLED" -eq 1 ]; then
    log "  AppArmor profile ${PROFILE_DST} (loaded; branch b prerequisite)"
  else
    log "  no AppArmor profile installed (branch b not taken)"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# S0 — environment capture (read-only)
# ---------------------------------------------------------------------------
s0_capture() {
  section "S0 environment capture"
  log "kernel: $(uname -r)"
  local s v
  for s in kernel.unprivileged_userns_clone user.max_user_namespaces \
           kernel.apparmor_restrict_unprivileged_userns; do
    v="$(sysctl -n "$s" 2>/dev/null || echo '<absent>')"
    log "sysctl ${s} = ${v}"
  done
  log "aa-status (head -5):"
  aa-status 2>/dev/null | head -5 || log "aa-status unavailable"
  log "cgroup fs type: $(stat -fc %T "$CGROOT" 2>/dev/null || echo unknown)"
  log "cgroup root subtree_control: $(cat "$CGROOT/cgroup.subtree_control" 2>/dev/null || echo '<absent>')"
}

# ---------------------------------------------------------------------------
# S1 — ensure bwrap (mutating, gated on absence)
# ---------------------------------------------------------------------------
s1_bwrap() {
  section "S1 bwrap presence"
  if [ -x "$BWRAP" ]; then
    log "bwrap already present: $BWRAP ($(dpkg-query -W -f '${Version}' bubblewrap 2>/dev/null || echo unknown))"
    return 0
  fi
  mut "apt-get install -y bubblewrap (candidate on this box: 0.9.0-1ubuntu0.3)"
  apt-get install -y bubblewrap
  BWRAP_INSTALLED=1
  log "bwrap installed: $(dpkg-query -W -f '${Version}' bubblewrap 2>/dev/null || echo unknown)"
  if [ ! -x "$BWRAP" ]; then
    log "FAIL: ${BWRAP} still not executable after install"
    HARD_FAILURE=1
    return 1
  fi
}

# ---------------------------------------------------------------------------
# S2 — spec-shaped jail run (as root, and as uid 200000 via setpriv).
#   jail-arg shape (plan Task 1 Step 1, verbatim) plus the scratch dir
#   RW-bound at its own path, so the inherited cwd and $PWD resolve inside
#   the jail and the payload's `touch $PWD/probe` lands in the scratch dir.
# ---------------------------------------------------------------------------
JAIL_OUT=""
JAIL_RC=0

run_jail() {
  # $1 = dir (RW-bound, cwd inside), $2 = "root" | "uid200000"
  local dir="$1" who="$2"
  local -a runner=() argv=()
  if [ "$who" = "uid200000" ]; then
    runner=(setpriv --reuid="$SANDBOX_UID" --regid="$SANDBOX_UID" --clear-groups)
  fi
  argv=(
    "$BWRAP"
    --ro-bind /usr /usr
    --ro-bind /bin /bin
    --ro-bind /lib /lib
    --dir /etc
    --proc /proc
    --dev /dev
    --unshare-user --uid 0 --gid 0
    --unshare-pid --unshare-uts --unshare-ipc
    --die-with-parent --new-session
    --bind "$dir" "$dir"
    -- /bin/sh -c 'id; cat /proc/self/uid_map; touch $PWD/probe'
  )
  JAIL_RC=0
  JAIL_OUT="$(
    cd "$dir" || exit 90
    "${runner[@]}" "${argv[@]}" 2>&1
  )" || JAIL_RC=$?
}

print_jail_result() {
  # $1 = dir, $2 = label
  printf -- '--- %s run: rc=%d, stdout/stderr ---\n%s\n--- end ---\n' \
    "$2" "$JAIL_RC" "$JAIL_OUT"
  if [ "$JAIL_RC" -ne 0 ]; then
    log "apparmor dmesg evidence after ${2} failure:"
    apparmor_evidence
  fi
  log "host owner of ${1}/probe: $(stat -c %u "${1}/probe" 2>/dev/null || echo absent)"
}

s2_run() {
  section "S2 spec-shaped jail"
  mut "mktemp -d /tmp/ovid-probe.XXXX (probe scratch)"
  SCRATCH="$(mktemp -d /tmp/ovid-probe.XXXX)"
  mut "chmod 0777 ${SCRATCH} (uid ${SANDBOX_UID} must traverse/write)"
  chmod 0777 "$SCRATCH"

  # Root run (expected to succeed per research config b; evidence either way)
  mut "run spec-shaped jail as root (payload touches ${SCRATCH}/probe)"
  run_jail "$SCRATCH" root
  print_jail_result "$SCRATCH" "root"
  log "S2 root: rc=${JAIL_RC}, owner=$(stat -c %u "$SCRATCH/probe" 2>/dev/null || echo absent) (expected: rc=0, owner=0)"

  # uid 200000 run via setpriv (branch a candidate)
  mut "rm -f ${SCRATCH}/probe (reset between runs)"
  rm -f "$SCRATCH/probe"
  mut "run spec-shaped jail as uid ${SANDBOX_UID} via setpriv (payload touches ${SCRATCH}/probe)"
  run_jail "$SCRATCH" uid200000
  print_jail_result "$SCRATCH" "uid200000"
  local uid_owner
  uid_owner="$(stat -c %u "$SCRATCH/probe" 2>/dev/null || echo absent)"
  log "S2 uid${SANDBOX_UID}: rc=${JAIL_RC}, owner=${uid_owner} (expected: rc=0, owner=${SANDBOX_UID})"

  if [ "$JAIL_RC" -eq 0 ] && [ "$uid_owner" = "$SANDBOX_UID" ]; then
    log "S2 uid${SANDBOX_UID} PASS -> branch a"
    BRANCH="a"
    return 0
  fi
  log "S2 uid${SANDBOX_UID} FAILED (rc=${JAIL_RC}, owner=${uid_owner}) -> continue to S3"
  return 1
}

# ---------------------------------------------------------------------------
# S3 — branch b: install + load the ovid-sandbox AppArmor profile, retry S2
# ---------------------------------------------------------------------------
s3_apparmor_retry() {
  section "S3 branch b — ovid-sandbox AppArmor profile + retry"
  if [ ! -f "$PROFILE_SRC" ]; then
    log "FAIL: ${PROFILE_SRC} missing"
    return 1
  fi
  mut "cp ${PROFILE_SRC} -> ${PROFILE_DST}"
  if ! cp "$PROFILE_SRC" "$PROFILE_DST"; then
    log "FAIL: could not copy ${PROFILE_SRC} to ${PROFILE_DST}"
    return 1
  fi
  mut "apparmor_parser -r ${PROFILE_DST} (loads profile on the live host)"
  if ! apparmor_parser -r "$PROFILE_DST"; then
    log "FAIL: apparmor_parser -r failed (profile not loaded)"
    return 1
  fi
  PROFILE_INSTALLED=1
  log "loaded profiles matching ovid-sandbox:"
  aa-status 2>/dev/null | grep -i ovid-sandbox || log "(aa-status shows no ovid-sandbox line)"

  mut "rm -f ${SCRATCH}/probe (reset for branch b retry)"
  rm -f "$SCRATCH/probe"
  mut "re-run spec-shaped jail as uid ${SANDBOX_UID} (branch b retry)"
  run_jail "$SCRATCH" uid200000
  print_jail_result "$SCRATCH" "uid200000-b"
  local uid_owner
  uid_owner="$(stat -c %u "$SCRATCH/probe" 2>/dev/null || echo absent)"
  log "S3 retry: rc=${JAIL_RC}, owner=${uid_owner} (expected: rc=0, owner=${SANDBOX_UID})"

  if [ "$JAIL_RC" -eq 0 ] && [ "$uid_owner" = "$SANDBOX_UID" ]; then
    log "S3 retry PASS -> branch b"
    BRANCH="b"
    return 0
  fi
  log "S3 retry FAILED (rc=${JAIL_RC}, owner=${uid_owner}) -> continue to S4"
  return 1
}

# ---------------------------------------------------------------------------
# S4 — branch c smoke: rootmap. Root-run `unshare --user` PoC in which the
#   parent writes `0 200000 1` to the child's uid_map (and gid_map), then the
#   child execs bwrap WITHOUT --unshare-user, joining the pre-made userns via
#   --userns FD (bwrap's --uid requires --unshare-user OR --userns).
#   Ownership proof: the jail's `touch` must land as host uid 200000.
# ---------------------------------------------------------------------------
s4_rootmap() {
  section "S4 branch c smoke — rootmap (pre-made userns, 0->200000 map)"
  local dir="$SCRATCH/branchc" out_file="$SCRATCH/branchc.out"
  mut "mkdir -p ${dir} + chmod 0777 (branch c workspace)"
  mkdir -p "$dir"
  chmod 0777 "$dir"

  # Launch the unshare child directly (no subshell wrapper: $! must be the pid
  # that unshared the userns, so the parent can write its uid_map/gid_map).
  # Child script ($1 = workspace dir): wait for the parent to write our maps,
  # then exec bwrap joining the pre-made userns via --userns FD.
  local prev_pwd="$PWD" cpid rc=0 out=""
  cd "$dir" || return 1
  mut "run branch-c jail (child of pre-made userns; payload touches ${dir}/probe)"
  unshare --user bash -c '
    for ((i = 0; i < 200; i++)); do
      if [ -s /proc/self/uid_map ] && [ -s /proc/self/gid_map ]; then
        break
      fi
      sleep 0.05
    done
    if [ ! -s /proc/self/uid_map ]; then
      echo "child: uid_map never written by parent" >&2
      exit 99
    fi
    exec 3< /proc/self/ns/user
    exec /usr/bin/bwrap --userns 3 --uid 0 --gid 0 \
      --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib \
      --dir /etc --proc /proc --dev /dev \
      --unshare-pid --unshare-uts --unshare-ipc \
      --die-with-parent --new-session \
      --bind "$1" "$1" \
      -- /bin/sh -c "id; cat /proc/self/uid_map; touch \$PWD/probe"
  ' probe "$dir" >"$out_file" 2>&1 &
  cpid=$!
  cd "$prev_pwd"

  # Parent (root) writes the child's maps: nsuid 0 -> host uid/gid 200000.
  # Ephemeral: the maps vanish when the child exits.
  mut "write '0 ${SANDBOX_UID} 1' to /proc/${cpid}/uid_map (probe child, ephemeral)"
  local i wrote=0
  for ((i = 0; i < 100; i++)); do
    if printf '%s\n' "0 ${SANDBOX_UID} 1" > "/proc/${cpid}/uid_map" 2>/dev/null; then
      wrote=1
      break
    fi
    sleep 0.05
  done
  if [ "$wrote" -ne 1 ]; then
    log "FAIL: could not write child uid_map"
    apparmor_evidence
    wait "$cpid" 2>/dev/null || true
    return 1
  fi
  mut "write setgroups deny + '0 ${SANDBOX_UID} 1' gid_map to /proc/${cpid} (ephemeral)"
  printf 'deny\n' > "/proc/${cpid}/setgroups" 2>/dev/null || true
  printf '%s\n' "0 ${SANDBOX_UID} 1" > "/proc/${cpid}/gid_map" 2>/dev/null \
    || log "WARN: gid_map write failed (non-fatal for the uid proof)"

  wait "$cpid" || rc=$?
  out="$(cat "$out_file")"
  printf -- '--- branch c run: rc=%d, stdout/stderr ---\n%s\n--- end ---\n' "$rc" "$out"
  if [ "$rc" -ne 0 ]; then
    apparmor_evidence
  fi
  local owner
  owner="$(stat -c %u "$dir/probe" 2>/dev/null || echo absent)"
  log "host owner of ${dir}/probe: ${owner} (expected ${SANDBOX_UID})"
  if [ "$rc" -eq 0 ] && [ "$owner" = "$SANDBOX_UID" ]; then
    log "S4 PASS -> branch c"
    BRANCH="c"
    return 0
  fi
  log "S4 FAILED (rc=${rc}, owner=${owner})"
  return 1
}

# ---------------------------------------------------------------------------
# S5 — ctty sanity: bwrap --new-session on a probe-owned pty; expect a
#   /dev/pts/N line and 24x80 output. The python below is pty.spawn's exact
#   mechanism (openpty, fork, setsid, TIOCSCTTY, dup2) plus an explicit
#   TIOCSWINSZ 24x80: pty.spawn leaves the winsize at 0x0, while node-pty —
#   the production consumer — always sets a winsize; this probes the shape
#   the worker will actually see. The node-pty-specific confirmation lands
#   in Task 9.
# ---------------------------------------------------------------------------
s5_ctty() {
  section "S5 ctty sanity (bwrap --new-session on a pty)"
  mut "spawn bwrap --new-session jail on a probe-owned pty (ephemeral)"
  local rc=0 out=""
  out="$(python3 - <<'PYEOF' 2>&1
import fcntl
import os
import pty
import struct
import sys
import termios

argv = [
    "/usr/bin/bwrap",
    "--ro-bind", "/usr", "/usr",
    "--ro-bind", "/bin", "/bin",
    "--ro-bind", "/lib", "/lib",
    "--dir", "/etc",
    "--proc", "/proc",
    "--dev", "/dev",
    "--unshare-user", "--uid", "0", "--gid", "0",
    "--unshare-pid", "--unshare-uts", "--unshare-ipc",
    "--die-with-parent", "--new-session",
    "--", "/bin/sh", "-c", "tty; stty size",
]

master, slave = os.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
pid = os.fork()
if pid == 0:  # child: mirrors pty.spawn (setsid + controlling tty + stdio)
    os.close(master)
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    os.dup2(slave, 0)
    os.dup2(slave, 1)
    os.dup2(slave, 2)
    if slave > 2:
        os.close(slave)
    os.execv(argv[0], argv)
os.close(slave)
while True:
    try:
        data = os.read(master, 4096)
    except OSError:
        break
    if not data:
        break
    sys.stdout.buffer.write(data)
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
PYEOF
)" || rc=$?
  printf -- '--- S5 pty output (rc=%d) ---\n%s\n--- end ---\n' "$rc" "$out"
  if [ "$rc" -eq 0 ] \
     && printf '%s\n' "$out" | grep -Eq '/dev/pts/[0-9]+' \
     && printf '%s\n' "$out" | grep -q '24 80'; then
    log "S5 PASS (ctty present in jail, stty size 24 80)"
    S5_RESULT="PASS"
  else
    log "S5 FAIL (rc=${rc}; expected /dev/pts/N + '24 80' in output)"
    S5_RESULT="FAIL"
    HARD_FAILURE=1
  fi
}

# ---------------------------------------------------------------------------
# S6 — cpu.max throttling measurement (research open item). Scratch cgroup at
#   the cgroup root (root mkdir at cgroup root is permitted; controllers
#   already enabled in root subtree_control — verified on this box). Quota
#   "50000 100000" = 50% of one CPU; compare a ~2s busy-loop iteration count
#   inside vs outside the cgroup (expect ~50%).
# ---------------------------------------------------------------------------
measure_loop() {
  # $1 = cgroup.procs path to migrate into ("" = uncapped)
  bash -c '
    if [ -n "$1" ]; then
      echo "$BASHPID" > "$1" || exit 9
    fi
    i=0
    end=$(( $(date +%s%N) + 2000000000 ))
    while [ "$(date +%s%N)" -lt "$end" ]; do
      i=$((i + 1))
    done
    echo "$i"
  ' probe "$1"
}

s6_throttle() {
  section "S6 cpu.max throttling measurement"
  CG_PROBE="${CGROOT}/ovid-probe-cpu.$$"
  mut "mkdir ${CG_PROBE} (probe scratch cgroup at cgroup root)"
  if ! mkdir "$CG_PROBE" 2>/dev/null; then
    log "FAIL: cannot create ${CG_PROBE}"
    S6_RESULT="FAIL"
    HARD_FAILURE=1
    return 1
  fi
  if [ ! -f "$CG_PROBE/cpu.max" ]; then
    log "FAIL: ${CG_PROBE}/cpu.max missing (cpu controller not enabled in root subtree_control?)"
    log "cgroup.controllers: $(cat "${CGROOT}/cgroup.controllers" 2>/dev/null || echo absent)"
    log "cgroup.subtree_control: $(cat "${CGROOT}/cgroup.subtree_control" 2>/dev/null || echo absent)"
    S6_RESULT="FAIL"
    HARD_FAILURE=1
    return 1
  fi
  mut "write '50000 100000' to ${CG_PROBE}/cpu.max (probe cgroup)"
  if ! printf '%s\n' "50000 100000" > "$CG_PROBE/cpu.max"; then
    log "FAIL: cannot write ${CG_PROBE}/cpu.max"
    S6_RESULT="FAIL"
    HARD_FAILURE=1
    return 1
  fi

  local capped="" uncapped="" ratio="" verdict=""
  mut "migrate busy-loop process into ${CG_PROBE} (cgroup.procs write, ephemeral)"
  capped="$(measure_loop "$CG_PROBE/cgroup.procs")" \
    || { log "FAIL: capped busy loop rc=$?"; S6_RESULT="FAIL"; HARD_FAILURE=1; return 1; }
  uncapped="$(measure_loop "")" \
    || { log "FAIL: uncapped busy loop rc=$?"; S6_RESULT="FAIL"; HARD_FAILURE=1; return 1; }
  ratio="$(awk -v c="$capped" -v u="$uncapped" \
    'BEGIN { if (u > 0) printf "%.2f", c / u; else print "n/a" }')"
  verdict="$(awk -v c="$capped" -v u="$uncapped" \
    'BEGIN { if (u > 0 && c > 0) { r = c / u; if (r > 0.25 && r < 0.75) { print "PASS"; exit } } print "FAIL" }')"
  log "cpu.max throttling: capped iterations=${capped}, uncapped=${uncapped}, ratio=${ratio} (expect ~0.50)"
  log "cpu.max after run: $(cat "$CG_PROBE/cpu.max")"
  log "S6 ${verdict}"
  S6_RESULT="${verdict}"
  [ "$verdict" = PASS ] || HARD_FAILURE=1
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  if [ "$(id -u)" -ne 0 ]; then
    log "FAIL: this probe must run as root (sudo bash $0)"
    exit 1
  fi

  s0_capture
  s1_bwrap
  if [ "$HARD_FAILURE" -ne 0 ]; then
    log "ABORT: bwrap unavailable; no mechanism can be probed"
    exit 1
  fi

  if ! s2_run; then
    if ! s3_apparmor_retry; then
      s4_rootmap || true
    fi
  fi

  s5_ctty
  s6_throttle

  section "SUMMARY"
  case "$BRANCH" in
    a) log "branch a: unprivileged bwrap as uid ${SANDBOX_UID} works (no profile needed)" ;;
    b) log "branch b: unprivileged bwrap as uid ${SANDBOX_UID} works with ${PROFILE_DST} loaded" ;;
    c) log "branch c: rootmap smoke passed (pre-made userns 0->${SANDBOX_UID}, bwrap --userns)" ;;
    *) log "NO BRANCH PASSED — all of a/b/c failed. STOP: escalate to owner (plan Step 4)." ;;
  esac
  log "S5 ctty sanity: ${S5_RESULT}"
  log "S6 cpu.max throttle: ${S6_RESULT}"
  log "decision for MECHANISM.md (fill in Step 4, owner):"
  case "$BRANCH" in
    a|b) log "  DECISION: setuid" ;;
    c)   log "  DECISION: rootmap" ;;
    *)   log "  DECISION: <none — all branches failed>" ;;
  esac
  if [ -z "$BRANCH" ] || [ "$HARD_FAILURE" -ne 0 ]; then
    exit 1
  fi
  exit 0
}

main "$@"
