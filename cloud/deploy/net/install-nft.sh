#!/usr/bin/env bash
# Ovid sandbox egress filter — render, validate, install, gate (Task 11).
#
# OWNER-RUN at P6/P10 activation (DEPLOY.md §11 step 4). Idempotent: safe to
# re-run after editing the env (a re-render restarts the unit, which deletes
# and reloads the table thanks to the ruleset's flush-on-reload guard).
#
# Environment:
#   OVID_PUBLIC_IP              REQUIRED — this host's public IPv4
#   OVID_SANDBOX_UID_BASE       optional — production default 200000;
#                                staging (P10) sets 220000 → rules keyed
#                                220000-229999 from this same script
#   OVID_SANDBOX_UID_MAX        optional — default <base>+9999
#   OVID_SANDBOX_EXTRA_BLOCKED  optional — csv of extra blocked cidrs
#   OVID_BROWSER_EGRESS_UID     optional (P6) — browser uid or uid-uid range
#   OVID_BROWSER_EGRESS_ALLOW   optional (P6) — csv of internal-endpoint v4
#                                cidrs the browser uid may still reach
#
# What it mutates: /opt/ovid-cloud/nft/ovid-sandbox.nft (rendered, validated
# with `nft -c` BEFORE install) and the ovid-sandbox-nft systemd unit. It
# never touches other nftables tables.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$CLOUD_DIR/packages/sandbox/dist/renderNftCli.js"
UNIT_SRC="$SCRIPT_DIR/ovid-sandbox-nft.service"
UNIT_DST="/etc/systemd/system/ovid-sandbox-nft.service"
NFT_DIR="/opt/ovid-cloud/nft"
RULESET="$NFT_DIR/ovid-sandbox.nft"
TABLE="ovid_sandbox"

log() { printf '[install-nft] %s\n' "$*"; }
die() { printf '[install-nft] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (the filter is a host-wide nftables table)"
[ -n "${OVID_PUBLIC_IP:-}" ] ||
  die "OVID_PUBLIC_IP is required (this host's public IPv4 — sandbox uids must not reach it)"
[ -f "$CLI" ] ||
  die "renderer missing at $CLI — build first: cd $CLOUD_DIR && pnpm install --frozen-lockfile && pnpm -r build"
[ -f "$UNIT_SRC" ] || die "unit template missing at $UNIT_SRC"
command -v nft >/dev/null || die "nft not found on PATH (apt-get install -y nftables)"

# Pass through the optional knobs so the renderer sees exactly what the
# operator set (unset vars stay unset — the renderer's defaults apply).
export OVID_PUBLIC_IP
for var in OVID_SANDBOX_UID_BASE OVID_SANDBOX_UID_MAX \
           OVID_SANDBOX_EXTRA_BLOCKED OVID_BROWSER_EGRESS_UID OVID_BROWSER_EGRESS_ALLOW; do
  if [ -n "${!var:-}" ]; then export "$var"; fi
done

# ── 1. Render + validate ───────────────────────────────────────────────────
install -d -m 0755 "$NFT_DIR"
TMP_RULESET="$(mktemp "$NFT_DIR/.ovid-sandbox.nft.XXXXXX")"
trap 'rm -f "$TMP_RULESET"' EXIT

if ! node "$CLI" > "$TMP_RULESET"; then
  die "render failed — see usage above (OVID_PUBLIC_IP is required)"
fi
chmod 0644 "$TMP_RULESET"

# nft -c parses and evaluates without applying; the declare-then-delete guard
# is check-friendly (proven on a table-less netns during Task 11).
if ! nft -c -f "$TMP_RULESET"; then
  die "nft -c rejected the rendered ruleset — refusing to install"
fi
log "ruleset rendered and validated for uid range ${OVID_SANDBOX_UID_BASE:-200000}-…"

# ── 2. Install ruleset + unit ───────────────────────────────────────────────
install -m 0644 "$TMP_RULESET" "$RULESET"
install -m 0644 "$UNIT_SRC" "$UNIT_DST"
systemctl daemon-reload
# enable starts the unit on boot; restart loads the freshly rendered ruleset
# now (ExecStop deletes the old table, ExecStart loads the new one — this is
# what makes re-runs after an env edit safe).
systemctl enable ovid-sandbox-nft.service
systemctl restart ovid-sandbox-nft.service

# ── 3. Gate ────────────────────────────────────────────────────────────────
nft list table inet "$TABLE" >/dev/null ||
  die "gate failed: nft list table inet $TABLE — the filter is NOT loaded"
log "table inet $TABLE loaded:"
nft list table inet "$TABLE"
log "done. Next: DEPLOY.md §11 step 5 (worker units), then step 7"
log "(systemctl enable --now ovid-worker ovid-sandbox-nft)."
