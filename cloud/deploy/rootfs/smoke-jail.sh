#!/usr/bin/env bash
# Smoke-tests an installed rootfs by running the pinned binaries inside a
# minimal bwrap jail — the same bind layout the sandbox launcher uses (root
# read-only at /, --proc/--dev, uid 0 in a user namespace, own PID ns).
# GATE: node/pnpm/uv versions must match versions.env, and the gcc PATH shim
# must refuse with the spec §7 copy and exit status 126.
#
# Usage: OVID_ROOTFS=/opt/ovid-rootfs/current bash smoke-jail.sh
set -euo pipefail

ROOTFS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$ROOTFS_DIR/versions.env"

ROOTFS="${OVID_ROOTFS:-/opt/ovid-rootfs/current}"

REFUSAL="Heavy native compilation (APK/Gradle/Kotlin builds) is disabled on live cloud workspaces. Use GitHub Actions CI or syntax/lint preview mode instead."

die() { echo "smoke-jail.sh: $*" >&2; exit 1; }

command -v bwrap >/dev/null 2>&1 || die "bwrap not found"
[ -d "$ROOTFS" ] || die "rootfs not found: $ROOTFS"

# PATH inside the jail: /usr/local/bin ahead of /usr/bin, so the shims win.
JAIL_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

jail() {
  bwrap \
    --ro-bind "$ROOTFS" / \
    --proc /proc \
    --dev /dev \
    --unshare-user --uid 0 --gid 0 \
    --unshare-pid --die-with-parent \
    -- env PATH="$JAIL_PATH" "$@"
}

# --- pinned toolchain: exact version gates -----------------------------------
NODE_OUT="$(jail node -e 'console.log(process.version)')"
[ "$NODE_OUT" = "$NODE_VERSION" ] || die "node: expected $NODE_VERSION, got '$NODE_OUT'"

PNPM_OUT="$(jail pnpm -v)"
[ "$PNPM_OUT" = "$PNPM_VERSION" ] || die "pnpm: expected $PNPM_VERSION, got '$PNPM_OUT'"

UV_OUT="$(jail uv -V)"
# `uv -V` prints the version plus a build-target suffix
# ("uv 0.13.1 (x86_64-unknown-linux-gnu)"), so compare the version TOKEN, not
# the whole line. Exactness is preserved: the first two fields must be
# exactly "uv <pinned version>".
UV_TOKEN="$(printf '%s\n' "$UV_OUT" | awk '{print $1" "$2}')"
[ "$UV_TOKEN" = "uv $UV_VERSION" ] || die "uv: expected uv $UV_VERSION, got '$UV_OUT'"

# --- present-but-unpinned tools: just prove they run -------------------------
PYTHON_OUT="$(jail python3 -V)"
[ -n "$PYTHON_OUT" ] || die "python3 -V produced no output"
GIT_OUT="$(jail git --version)"
[ -n "$GIT_OUT" ] || die "git --version produced no output"

# --- gcc shim: refusal copy + exit 126 ----------------------------------------
set +e
GCC_OUT="$(jail gcc)"
GCC_RC=$?
set -e
[ "$GCC_RC" -eq 126 ] || die "gcc shim: expected exit 126, got $GCC_RC"
[ "$GCC_OUT" = "$REFUSAL" ] || die "gcc shim: unexpected output '$GCC_OUT'"

echo "smoke-jail: OK ($ROOTFS — node $NODE_OUT, pnpm $PNPM_OUT, uv $UV_OUT, $PYTHON_OUT)"
