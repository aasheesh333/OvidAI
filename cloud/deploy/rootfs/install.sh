#!/usr/bin/env bash
# OWNER-GATED (Task 16 activation): installs a built rootfs tarball under
# /opt/ovid-rootfs, atomically repoints the `current` symlink, prunes to two
# revisions and runs smoke-jail.sh against the freshly activated tree.
# Never run this from a task agent — it mutates the host.
#
# Usage: sudo bash cloud/deploy/rootfs/install.sh [dist/<name>.tar.zst]
#        (no argument: the newest tarball in dist/)
set -euo pipefail

ROOTFS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$ROOTFS_DIR/versions.env"

OPT_ROOT="${OVID_ROOTFS_ROOT:-/opt/ovid-rootfs}"
KEEP_REVISIONS=2

die() { echo "install.sh: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (owner-gated)"
for cmd in zstd tar sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done

ARTIFACT="${1:-}"
if [ -z "$ARTIFACT" ]; then
  ARTIFACT="$(ls -1t "$ROOTFS_DIR"/dist/ubuntu-noble-min-*.tar.zst 2>/dev/null | head -n1 || true)"
fi
[ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ] || die "tarball not found: ${ARTIFACT:-<none>}"
case "$ARTIFACT" in
  "$ROOTFS_DIR"/dist/ubuntu-noble-min-*.tar.zst) ;;
  *) die "refusing to install from outside dist/: $ARTIFACT" ;;
esac

NAME="$(basename "$ARTIFACT" .tar.zst)"
SUMS_FILE="${ARTIFACT%.tar.zst}.SHA256SUMS"
[ -f "$SUMS_FILE" ] || die "checksums not found: $SUMS_FILE"

# --- verify the tarball against its SHA256SUMS ------------------------------
echo "==> verifying checksums for $(basename "$ARTIFACT")"
(
  cd "$(dirname "$ARTIFACT")"
  grep "$(basename "$ARTIFACT")\$" "$(basename "$SUMS_FILE")" | sha256sum -c -
)

# --- extract to a tmp dir, then mv into place (same fs => atomic) -----------
mkdir -p "$OPT_ROOT"
TARGET="$OPT_ROOT/$NAME"
TMP="$OPT_ROOT/$NAME.tmp"
rm -rf "$TMP"
mkdir "$TMP"
echo "==> extracting to $TMP"
zstd -dc "$ARTIFACT" | tar -x -C "$TMP"
[ -f "$TMP/manifest.json" ] || die "tarball has no /manifest.json"
mv "$TMP" "$TARGET"

# --- atomically flip the `current` symlink ----------------------------------
echo "==> activating $NAME as $OPT_ROOT/current"
ln -sfn "$NAME" "$OPT_ROOT/current.tmp"
mv -T "$OPT_ROOT/current.tmp" "$OPT_ROOT/current"

# --- prune to KEEP_REVISIONS (names sort newest-last: date + rN) ------------
mapfile -t revisions < <(ls -1d "$OPT_ROOT"/ubuntu-noble-min-* 2>/dev/null | sort -r || true)
if [ "${#revisions[@]}" -gt "$KEEP_REVISIONS" ]; then
  for old in "${revisions[@]:$KEEP_REVISIONS}"; do
    case "$old" in
      "$TARGET"|"$(readlink -f "$OPT_ROOT/current")") continue ;;
    esac
    echo "==> pruning old revision: $old"
    rm -rf "$old"
  done
fi

# --- smoke-test the activated tree in a bwrap jail ---------------------------
echo "==> running smoke-jail.sh"
OVID_ROOTFS="$OPT_ROOT/current" bash "$ROOTFS_DIR/smoke-jail.sh"

echo "==> installed: $OPT_ROOT/current -> $NAME"
