#!/usr/bin/env bash
# Builds the pinned ubuntu-noble-min rootfs tarball (docker-export) for Ovid
# cloud sandboxes. Toolchain pins come from versions.env; the Dockerfile
# verifies node/uv checksums inline, so any upstream mismatch fails here.
#
# Usage:   REVISION=1 bash cloud/deploy/rootfs/build.sh
# Output:  dist/ubuntu-noble-min-YYYYMMDD-rN.tar.zst
#          dist/ubuntu-noble-min-YYYYMMDD-rN.manifest.json
#          dist/ubuntu-noble-min-YYYYMMDD-rN.SHA256SUMS
# Scope:   docker-only and autonomous — the build container is named
#          ovid-rootfs-build-$NAME (trap-cleaned) and the build tag is
#          removed at the end. Nothing outside cloud/deploy/rootfs/dist is
#          touched. install.sh (owner-gated, Task 16) activates the result.
set -euo pipefail

ROOTFS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$ROOTFS_DIR/versions.env"

REVISION="${REVISION:-1}"
NAME="ubuntu-noble-min-$(date -u +%Y%m%d)-r${REVISION}"
DIST_DIR="$ROOTFS_DIR/dist"
BUILD_TAG="ovid-rootfs-build:$NAME"
CTR="ovid-rootfs-build-$NAME"

die() { echo "build.sh: $*" >&2; exit 1; }

for cmd in docker zstd sha256sum sed awk git; do
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done

mkdir -p "$DIST_DIR"

# --- 1. Base image: pull and resolve the repo digest -----------------------
echo "==> pulling $UBUNTU_IMAGE"
docker pull "$UBUNTU_IMAGE" >/dev/null
BASE_DIGEST="$(
  docker image inspect "$UBUNTU_IMAGE" --format '{{join .RepoDigests "\n"}}' \
    | head -n1 | sed 's/^[^@]*@//'
)"
case "$BASE_DIGEST" in
  sha256:[0-9a-f]*) ;;
  *) die "could not resolve repo digest for $UBUNTU_IMAGE (got: '$BASE_DIGEST')" ;;
esac

BUILDER_COMMIT="$(git -C "$ROOTFS_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- 2. Build the image (checksums verified inside the Dockerfile) ---------
echo "==> docker build $BUILD_TAG"
docker build \
  -f "$ROOTFS_DIR/Dockerfile.noble" \
  -t "$BUILD_TAG" \
  --build-arg UBUNTU_IMAGE="$UBUNTU_IMAGE" \
  --build-arg NODE_VERSION="$NODE_VERSION" \
  --build-arg PNPM_VERSION="$PNPM_VERSION" \
  --build-arg UV_VERSION="$UV_VERSION" \
  --build-arg APT_PACKAGES="$APT_PACKAGES" \
  "$ROOTFS_DIR"

# --- 3. dpkg -l snapshot from the built image -------------------------------
DPKG_OUTPUT="$(docker run --rm "$BUILD_TAG" dpkg -l)"

# --- 4. Manifest, baked INTO the tarball ------------------------------------
# JSON-escape the dpkg snapshot (backslashes and quotes; newlines become \n).
DPKG_ESCAPED="$(
  printf '%s' "$DPKG_OUTPUT" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | awk '{ printf "%s\\n", $0 }'
)"
APT_JSON="$(
  printf '%s' "$APT_PACKAGES" \
    | awk 'BEGIN { sep = "" } { for (i = 1; i <= NF; i++) { printf "%s\"%s\"", sep, $i; sep = ", " } }'
)"

MANIFEST_TMP="$(mktemp /tmp/ovid-rootfs-manifest.XXXXXX)"
docker create --name "$CTR" "$BUILD_TAG" >/dev/null
trap 'docker rm -f "$CTR" >/dev/null 2>&1 || true; rm -f "$MANIFEST_TMP"' EXIT

{
  printf '{\n'
  printf '  "name": "%s",\n' "$NAME"
  printf '  "baseImage": "%s",\n' "$UBUNTU_IMAGE"
  printf '  "baseImageDigest": "%s",\n' "$BASE_DIGEST"
  printf '  "nodeVersion": "%s",\n' "$NODE_VERSION"
  printf '  "pnpmVersion": "%s",\n' "$PNPM_VERSION"
  printf '  "uvVersion": "%s",\n' "$UV_VERSION"
  printf '  "aptPackages": [%s],\n' "$APT_JSON"
  printf '  "buildDate": "%s",\n' "$BUILD_DATE"
  printf '  "builderCommit": "%s",\n' "$BUILDER_COMMIT"
  printf '  "dpkgSnapshot": "%s"\n' "$DPKG_ESCAPED"
  printf '}\n'
} > "$MANIFEST_TMP"

# Sanity: the manifest must be valid JSON (checked with the image's own node,
# so build.sh needs no host-side node).
docker run --rm -i "$BUILD_TAG" node -e \
  'JSON.parse(require("fs").readFileSync(0, "utf8"))' < "$MANIFEST_TMP" >/dev/null

docker cp "$MANIFEST_TMP" "$CTR:/manifest.json"

# --- 5. Export the filesystem and compress ----------------------------------
TARBALL="$DIST_DIR/$NAME.tar.zst"
echo "==> docker export | zstd -19 -> $TARBALL"
docker export "$CTR" | zstd -19 -T0 -f -o "$TARBALL"
zstd -t "$TARBALL"

# --- 6. dist records --------------------------------------------------------
cp "$MANIFEST_TMP" "$DIST_DIR/$NAME.manifest.json"
(
  cd "$DIST_DIR"
  sha256sum "$NAME.tar.zst" "$NAME.manifest.json" > "$NAME.SHA256SUMS"
)

# --- 7. Cleanup --------------------------------------------------------------
docker rm -f "$CTR" >/dev/null
docker rmi "$BUILD_TAG" >/dev/null
trap - EXIT
rm -f "$MANIFEST_TMP"

echo "==> done"
echo "    tarball   : $TARBALL"
echo "    manifest  : $DIST_DIR/$NAME.manifest.json"
echo "    checksums : $DIST_DIR/$NAME.SHA256SUMS"
echo "    base digest: $BASE_DIGEST (builder commit $BUILDER_COMMIT)"
