#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# Ovid native-sandbox packaging — downloads the official Termux
# bootstrap zips, strips them to the agent-essential payload, and
# repacks per-ABI as libovid-bootstrap.so under jniLibs/<abi>/.
#
# Why lib*.so? Android's PackageManager extracts only jniLibs to the
# app's nativeLibraryDir WITH exec permission (W^X-safe on Android
# 6→15+). Termux does the same (libtermux-bootstrap.so). At first run
# the app reads this zip and installs the sandbox prefix.
#
# Usage: tool/prepare_bootstrap.sh [abi ...]   (default: all 3)
# Requires: curl, unzip, zip, file
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

TAG="bootstrap-2026.08.23-r1%2Bapt.android-7"
BASE="https://github.com/termux/termux-packages/releases/download/${TAG}"
OUT_ROOT="$(pwd)/android/app/src/main/jniLibs"
WORK="/tmp/opencode/bootstrap-work"

# ── Agent-essential payload ─────────────────────────────────────────
# Keep list: everything the agent needs for shell + apt + archives.
# (python/node/git install via `apt` afterwards — same as Termux.)
BINS=(
  bash dash coreutils
  apt apt-get apt-cache apt-mark apt-config apt-key
  dpkg dpkg-deb dpkg-query dpkg-trigger dpkg-divert dpkg-split dpkg-realpath
  tar gzip gunzip zcat bzip2 bunzip2 xz unxz zstd unzstd
  curl wget
  gpgv
  grep sed awk find xargs which
  less head tail cat ls cp mv rm mkdir rmdir touch chmod chown ln
  uname whoami id env printenv
  ps top kill pkill
  date sleep true false test
  sha256sum md5sum base64
  cut sort uniq wc tr tee
  termux-exec-ld-preload-lib termux-exec-system-linker-exec
)
LIBS_GLOBS=(
  # keep every lib the kept binaries + apt methods depend on
  "lib/lib*.so*"
)
APT_METHODS=(copy gpgv http https file store rsh cdrom)
ASSETS_DIRS=(etc share/terminfo)

mkdir -p "$WORK"
declare -A ABI_MAP=(
  [aarch64]=arm64-v8a
  [arm]=armeabi-v7a
  [x86_64]=x86_64
)

abis=("${@:-aarch64 arm x86_64}")
if [ $# -gt 0 ]; then abis=("$@"); else abis=(aarch64 arm x86_64); fi

for termux_abi in "${abis[@]}"; do
  jni="${ABI_MAP[$termux_abi]}"
  [ -n "$jni" ] || { echo "unknown ABI: $termux_abi"; exit 1; }
  echo "══ $termux_abi → $jni ══"
  z="$WORK/bootstrap-$termux_abi.zip"
  [ -f "$z" ] || curl -fSL --retry 3 -o "$z" "$BASE/bootstrap-$termux_abi.zip"

  d="$WORK/x-$termux_abi"
  rm -rf "$d" && mkdir -p "$d"

  # Full extract (zip is ~32MB, extraction is fast; we repack a subset).
  (cd "$d" && unzip -q -o "$z")

  out="$WORK/out-$termux_abi"
  rm -rf "$out" && mkdir -p "$out"
  cp "$d/SYMLINKS.txt" "$out/"

  # Bins
  mkdir -p "$out/bin"
  for b in "${BINS[@]}"; do
    [ -f "$d/bin/$b" ] && cp "$d/bin/$b" "$out/bin/$b" || true
  done
  # Libs (full set — binaries' DT_NEEDED closure is safest kept whole)
  mkdir -p "$out/lib"
  (cd "$d" && find lib -maxdepth 1 -name '*.so*' -exec cp {} "$out/lib/" \;)
  # apt methods (live under lib/apt/methods, must stay executable)
  mkdir -p "$out/lib/apt/methods"
  for m in "${APT_METHODS[@]}"; do
    [ -f "$d/lib/apt/methods/$m" ] && cp "$d/lib/apt/methods/$m" "$out/lib/apt/methods/$m" || true
  done
  # Assets: etc (apt config) + terminfo (TERM=xterm)
  for ad in "${ASSETS_DIRS[@]}"; do
    [ -d "$d/$ad" ] && (cd "$d" && cp -r "$ad" "$out/") || true
  done

  # Repack as the jniLibs payload zip.  The .so extension is ONLY a
  # container trick — the file is a zip; Android never parses it.
  dest="$OUT_ROOT/$jni"
  mkdir -p "$dest"
  (cd "$out" && zip -q -r -X "$dest/libovid_bootstrap.so" .)
  size=$(du -m "$dest/libovid_bootstrap.so" | cut -f1)
  echo "  → $dest/libovid_bootstrap.so  (${size} MB)"
done

echo "DONE — jniLibs payloads ready."
