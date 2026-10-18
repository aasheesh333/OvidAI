#!/usr/bin/env bash
# Studio sandbox setup end-to-end harness (Android emulator).
#
# Boots (or reuses) a headless KVM emulator, installs a DEBUG build made with
# --dart-define=OVID_E2E_SKIP_LOGIN=true, drives the real UI with adb
# (Chat -> Studio -> "Install sandbox"), waits for the persisted setup log
# (files/studio-setup.log) to report a result, collects evidence and asserts
# the runtimes work through the app's own sandbox shell.
#
# Usage:
#   scripts/studio_e2e.sh [--build] [--apk PATH] [--keep-data] [--no-wait]
#                         [--out DIR] [--avd NAME] [--assert]
#   --build      derive the payload and build the debug APK first (x86_64,
#                e2e login bypass)
#   --keep-data  do not `pm clear` (resume / upgrade / idempotency runs)
#   --no-wait    trigger setup and return (force-stop tests)
#   --rerun      keep data and clear the "Studio setup done" flag so the
#                real setup runs again over the existing sandbox (idempotency)
#   --assert     after success, run node/npm/python/pip/git + npm/pip installs
#                through the sandbox launcher and fail on any error
# Env: ANDROID_HOME (default /opt/android-sdk), FLUTTER (default flutter).
set -euo pipefail

APP=com.dhanuk.ovidai
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
AVD=ovid34
APK="$ROOT/build/app/outputs/flutter-apk/app-debug.apk"
OUT="$ROOT/build/studio-e2e/$(date +%Y%m%d-%H%M%S)"
BUILD=0 KEEP=0 WAIT=1 ASSERT=0 RERUN=0 TIMEOUT=${STUDIO_E2E_TIMEOUT:-2400}
while [ $# -gt 0 ]; do
  case "$1" in
    --build) BUILD=1 ;;
    --apk) APK="$2"; shift ;;
    --keep-data) KEEP=1 ;;
    --rerun) KEEP=1; RERUN=1 ;;
    --no-wait) WAIT=0 ;;
    --assert) ASSERT=1 ;;
    --out) OUT="$2"; shift ;;
    --avd) AVD="$2"; shift ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
  shift
done
mkdir -p "$OUT"
log() { echo "[e2e $(date +%H:%M:%S)] $*" | tee -a "$OUT/harness.log"; }
runas() { adb exec-out run-as "$APP" "$@"; }

# ── 1. emulator ────────────────────────────────────────────────────────
if ! adb get-state >/dev/null 2>&1; then
  if ! avdmanager list avd 2>/dev/null | grep -q "Name: $AVD" &&
     [ ! -d "$HOME/.android/avd/$AVD.avd" ]; then
    yes | sdkmanager --sdk_root="$ANDROID_HOME" emulator \
      "system-images;android-34;google_apis;x86_64" >/dev/null
    echo no | avdmanager create avd -n "$AVD" \
      -k "system-images;android-34;google_apis;x86_64" -d pixel_6 --force
    printf 'hw.ramSize=4096\ndisk.dataPartition.size=8G\nhw.cpu.ncore=4\n' \
      >> "$HOME/.android/avd/$AVD.avd/config.ini"
  fi
  log "booting $AVD"
  nohup emulator -avd "$AVD" -no-window -no-audio -no-boot-anim \
    -gpu swiftshader_indirect -no-snapshot -accel on >"$OUT/emulator.log" 2>&1 &
  adb wait-for-device
fi
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 3; done
log "device: $(adb shell getprop ro.product.model | tr -d '\r') API $(adb shell getprop ro.build.version.sdk | tr -d '\r') abis=$(adb shell getprop ro.product.cpu.abilist | tr -d '\r')"

# ── 2. build + install ─────────────────────────────────────────────────
if [ "$BUILD" = 1 ]; then
  # No sandbox bootstrap payload: execution is server-side since the cloud
  # migration, and the release inventory gate rejects one if present.
  log "building debug APK"
  (cd "$ROOT" && ${FLUTTER:-flutter} build apk --debug --target-platform android-x64 \
     --dart-define=OVID_BUILD="e2e-$(git rev-parse --short HEAD)" \
     --dart-define=OVID_E2E_SKIP_LOGIN=true) >"$OUT/build.log" 2>&1
fi
log "installing $APK"
adb install -r "$APK" >/dev/null
adb shell am force-stop "$APP"
if [ "$KEEP" = 0 ]; then adb shell pm clear "$APP" >/dev/null; fi
if [ "$RERUN" = 1 ]; then
  runas sed -i 's#name="flutter.studio_first_open_done" value="true"#name="flutter.studio_first_open_done" value="false"#' \
    shared_prefs/FlutterSharedPreferences.xml
fi
adb shell pm grant "$APP" android.permission.POST_NOTIFICATIONS 2>/dev/null || true
adb shell pm list packages | grep -q com.termux && log "Termux app is installed" || log "Termux app is NOT installed"

# ── 3. drive the UI ────────────────────────────────────────────────────
# Prints "x y" of the first node whose text/content-desc matches $1 (regex).
find_node() {
  adb shell rm -f /sdcard/ui.xml >/dev/null 2>&1
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 || return 1
  adb exec-out cat /sdcard/ui.xml | python3 -I -c '
import re, sys
pat = re.compile(sys.argv[1])
for n in re.findall(r"<node [^>]*>", sys.stdin.read()):
    t = re.search(r" text=\"([^\"]*)\"", n).group(1)
    d = re.search(r"content-desc=\"([^\"]*)\"", n).group(1)
    if pat.search(t) or pat.search(d):
        x1, y1, x2, y2 = map(int, re.findall(r"\d+", re.search(r"bounds=\"([^\"]*)\"", n).group(1)))
        print((x1 + x2) // 2, (y1 + y2) // 2); break
' "$1"
}
tap_text() {  # tap_text REGEX [tries]
  local tries=${2:-20} xy
  for _ in $(seq "$tries"); do
    xy=$(find_node "$1" || true)
    if [ -n "$xy" ]; then adb shell input tap $xy; log "tapped '$1' at $xy"; return 0; fi
    sleep 2
  done
  log "UI element '$1' not found"; adb exec-out screencap -p >"$OUT/ui-missing.png"; return 1
}
adb logcat -c
runas rm -f files/studio-setup.log 2>/dev/null || true
START=$(date +%s)
adb shell monkey -p "$APP" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
# Wait for the chat shell (the composer) before looking for the Studio icon.
for _ in $(seq 30); do find_node '^(Attach|Send)$' | grep -q . && break; sleep 2; done
tap_text '^Studio' 30
sleep 3
# First open shows the approval card; an interrupted/resumed setup may show
# progress (or Retry) instead.
BUTTONS='^(Install sandbox|Retry install|Retry install anyway|Retry runtime setup)$'
tap_text "$BUTTONS" 10 || log "no install button (setup already running?)"
if [ -n "${E2E_SCREENSHOT_AFTER_TAP:-}" ]; then sleep 5; adb exec-out screencap -p >"$OUT/after-tap.png"; fi
[ "$WAIT" = 1 ] || { log "--no-wait: setup triggered"; exit 0; }

# ── 4. wait for the persisted result line ──────────────────────────────
while :; do
  if runas cat files/studio-setup.log 2>/dev/null | grep -q '^# result:'; then break; fi
  if [ $(( $(date +%s) - START )) -gt "$TIMEOUT" ]; then log "TIMEOUT after ${TIMEOUT}s"; break; fi
  sleep 10
done
ELAPSED=$(( $(date +%s) - START ))
runas cat files/studio-setup.log >"$OUT/studio-setup.log" 2>&1 || true
adb logcat -d >"$OUT/logcat.txt" || true
runas sh -c 'cd files && ls -la && ls -la sandbox sandbox/bin | head -400' >"$OUT/tree.txt" 2>&1 || true
adb exec-out screencap -p >"$OUT/final.png" || true
RESULT=$(grep '^# result:' "$OUT/studio-setup.log" | tail -1 || true)
log "setup finished in ${ELAPSED}s: ${RESULT:-<no result>}"
grep -E 'E: |error|Error|FAILED|⚠|denied|not found' "$OUT/studio-setup.log" | sed -E 's/^[0-9:.]+ //; s/generation\.[A-Za-z0-9]+/generation.X/g' | sort | uniq -c | sort -rn | head -40 >"$OUT/error-classes.txt" || true
log "distinct error lines: $(wc -l <"$OUT/error-classes.txt")"

case "$RESULT" in
  *'result: ready'*) ;;
  *) log "FAIL: setup did not reach ready"; exit 1 ;;
esac

# ── 5. assert the runtimes through the app's sandbox launcher ──────────
# files/sandbox/bin/ovid-shell is the same launcher the app uses for every
# sandbox process (agent shell, terminal, MCP); run-as gives the app's uid.
if [ "$ASSERT" = 1 ]; then
  SH='files/sandbox/bin/ovid-shell'
  run() {
    log "\$ $1"
    local t0=$(date +%s%N)
    runas "$SH" -c "export NO_COLOR=1 FORCE_COLOR=0 npm_config_color=false npm_config_progress=false; $1" 2>&1 \
      | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | tee -a "$OUT/assert.log"
    local rc=${PIPESTATUS[0]}
    echo "  (exit $rc, $(( ($(date +%s%N) - t0) / 1000000 )) ms)" >>"$OUT/assert.log"
    return "$rc"
  }
  fail=0
  for c in 'node -v' 'npm -v' 'npx -v' 'python -V' 'pip -V' 'git --version' 'curl --version | head -1' 'uv --version'; do
    out=$(run "$c") || fail=1
    echo "$out" | grep -qiE 'not found|error|denied' && fail=1
  done
  run 'rm -rf "$HOME/e2e-npm" && mkdir -p "$HOME/e2e-npm" && cd "$HOME/e2e-npm" && npm init -y >/dev/null && npm install --no-audit --no-fund is-number@7 && node -e "console.log(require(\"is-number\")(5))"' | tail -3 | grep -q 'true$' || fail=1
  run 'pip install --disable-pip-version-check six==1.16.0 && python -c "import six; print(six.__version__)"' | tail -1 | grep -q '^1.16.0$' || fail=1
  run 'cd "$HOME" && rm -rf e2e-git && git init -q e2e-git && cd e2e-git && git -c user.email=e@x -c user.name=e commit -q --allow-empty -m init && git log --oneline | wc -l' | tail -1 | grep -q '^1$' || fail=1
  [ "$fail" = 0 ] && log "ASSERT: all runtime checks passed" || { log "ASSERT: FAILED (see $OUT/assert.log)"; exit 1; }
fi
log "evidence in $OUT"
