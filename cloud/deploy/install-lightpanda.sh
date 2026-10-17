#!/usr/bin/env bash
# install-lightpanda.sh — provision the PINNED Lightpanda binary for the P6
# browser engine (plan: 2026-10-16-ovid-cloud-p6-browser-engine, Task 16).
#
# OWNER-GATED ACTIVATION ARTIFACT (same gate style as P1 Task 11 step 6):
# never run by a task agent, CI, or any automated deploy step. The owner runs
# it by hand on the production host (see cloud/deploy/BROWSERS.md §(b)).
#
# What it does: downloads the pinned release asset to a temp path, verifies
# sha256 + size, installs it 0755 under /opt/ovid-browsers/, and smokes
# `lightpanda version`. Idempotent — re-running with the correct binary in
# place is a no-op (exit 0), so it is safe to put in a host-bootstrap
# runbook. AGPL-3.0: the binary runs as an UNMODIFIED subprocess only —
# never fork, re-link, or vendor its source (research §1.3 / BROWSERS.md §(a)).

set -euo pipefail

VERSION=1.0.1
URL=https://github.com/lightpanda-io/browser/releases/download/1.0.1/lightpanda-x86_64-linux
SHA256=551747e35c51ba107b5d5277eca4b48e077b2a3b40f09a047bf6670448bc35fd
SIZE=75670856
DEST=/opt/ovid-browsers/lightpanda-1.0.1

fail() {
  echo "install-lightpanda: ERROR: $*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || [ -w /opt/ovid-browsers 2>/dev/null ] ||
  fail "refusing to run as a non-root user without write access to /opt/ovid-browsers — run as root (or arrange write access first)."

command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 ||
  fail "need curl or wget to download the pinned asset."

# ---------------------------------------------------------------------------
# Idempotence: correct binary already in place -> exit 0 without touching
# the network. A PRESENT-but-wrong binary falls through to a fresh download
# and is replaced (the sha check below still gates the new copy).
# ---------------------------------------------------------------------------
if [ -x "$DEST/lightpanda" ]; then
  if printf '%s  %s\n' "$SHA256" "$DEST/lightpanda" | sha256sum -c - >/dev/null 2>&1; then
    echo "install-lightpanda: $DEST/lightpanda already matches the pinned sha256 — nothing to do."
    exit 0
  fi
  echo "install-lightpanda: WARNING: $DEST/lightpanda exists but its sha256 does NOT match the pin — replacing it." >&2
fi

mkdir -p "$DEST"
TMP="$DEST.tmp"

echo "install-lightpanda: downloading $URL"
rm -f "$TMP"
if command -v curl >/dev/null 2>&1; then
  curl --fail --location --silent --show-error --output "$TMP" "$URL" ||
    { rm -f "$TMP"; fail "download failed ($URL) — deleted $TMP; not installing anything."; }
else
  wget --quiet --output-document="$TMP" "$URL" ||
    { rm -f "$TMP"; fail "download failed ($URL) — deleted $TMP; not installing anything."; }
fi

# ---------------------------------------------------------------------------
# Checksum + size gate: abort AND delete on any mismatch — a corrupt or
# substituted binary must never reach $DEST.
# ---------------------------------------------------------------------------
if ! printf '%s  %s\n' "$SHA256" "$TMP" | sha256sum -c - >/dev/null 2>&1; then
  rm -f "$TMP"
  fail "sha256 mismatch on the downloaded asset — deleted $TMP. Expected $SHA256. NOT installed."
fi
actual_size=$(stat -c %s "$TMP")
if [ "$actual_size" -ne "$SIZE" ]; then
  rm -f "$TMP"
  fail "size mismatch: downloaded $actual_size bytes, pinned size is $SIZE — deleted $TMP. NOT installed (sha256 passed; treat as a pin drift and re-verify the release by hand)."
fi

install -m 0755 "$TMP" "$DEST/lightpanda"
rm -f "$TMP"

# ---------------------------------------------------------------------------
# Smoke: must exit 0 AND print a version string naming the pinned version.
# ---------------------------------------------------------------------------
smoke="$(mktemp)"
if ! "$DEST/lightpanda" version >"$smoke" 2>&1; then
  echo "install-lightpanda: smoke output was: $(cat "$smoke")" >&2
  rm -f "$smoke"
  fail "smoke test failed: '$DEST/lightpanda version' exited non-zero — the binary is unusable on this host. Left it in place for inspection; remove or re-provision before activation."
fi
out="$(cat "$smoke")"
rm -f "$smoke"
[ -n "$out" ] || fail "smoke test failed: '$DEST/lightpanda version' printed nothing. Left the binary in place for inspection."
if ! printf '%s' "$out" | grep -q "$VERSION"; then
  fail "smoke test failed: version output does not mention the pinned $VERSION (got: $out). Left the binary in place for inspection — do NOT activate."
fi

echo "install-lightpanda: installed $DEST/lightpanda (version: $out)"
echo "install-lightpanda: set OVID_LIGHTPANDA_BIN=$DEST/lightpanda in the worker env (see BROWSERS.md §(b)) — absent/empty, tier-1 silently skips Lightpanda."
