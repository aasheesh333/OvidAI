/// PR47: sandbox package-manager bootstrap content.
///
/// `ovid-pkg` — curl+dpkg installer (no apt https transport; that method
/// is broken on some devices with a permanently fake "no Release file"
/// error on every mirror).
///
/// `npm`/`npx` wrappers — direct `node` exec with an absolute sandbox
/// prefix. Bypasses every Termux-path shebang issue ("Permission denied"
/// when the interpreter path resolves into the Termux app prefix, or
/// "No such file or directory" when it points at our nonexistent usr/bin).
library;

import 'dart:io';

/// Write `$PREFIX/bin/ovid-pkg`, `$PREFIX/bin/apt`, `bin/apt-get`,
/// `bin/pkg`, plus `$PREFIX/bin/npm` and `$PREFIX/bin/npx`. All shell
/// scripts hardcode the sandbox prefix (via a #! shebang on the sandbox
/// bash/sh binary) so they work without LD_PRELOAD/glibc tricks.
class OvidPkgInstaller {
  /// [arch] is the apt repo arch from the Dart ABI map
  /// (`aptArchFor`); when null the script falls back to `uname -m` and
  /// maps armv7l/armv8l → arm. [mirrors] is the app's ordered mirror
  /// pool, written to `$PREFIX/etc/apt/ovid-mirrors` so the script reads
  /// the same list the app uses instead of only sources.list.
  static void writeAll(
    Directory prefix, {
    String? arch,
    List<String>? mirrors,
  }) {
    final p = prefix.path;
    _write('$p/bin/ovid-pkg', _ovidPkgFor(p, arch));
    if (mirrors != null && mirrors.isNotEmpty) {
      _writeText('$p/etc/apt/ovid-mirrors', '${mirrors.join('\n')}\n');
    }
    for (final b in ['apt', 'apt-get', 'pkg']) {
      _write('$p/bin/$b', _pkgWrapper(p, b));
    }
    _write('$p/bin/npm', _npmCliWrapper(p, 'npm'));
    _write('$p/bin/npx', _npmCliWrapper(p, 'npx'));
  }

  static void _writeText(String path, String content) {
    try {
      final f = File(path);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content, flush: true);
    } catch (_) {}
  }

  static void _write(String path, String content) {
    try {
      final f = File(path);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content, flush: true);
      try {
        Process.runSync('chmod', ['0755', path]);
      } catch (_) {
        try {
          Process.runSync('/system/bin/chmod', ['0755', path]);
        } catch (_) {}
      }
    } catch (_) {}
  }

  static String _pkgWrapper(String p, String tool) => """#!$p/bin/sh
# Ovid-wrapped $tool — package ops always work even when apt can't reach
# a mirror (Transport HTTPS broken → see ovid-pkg).
exec "$p/bin/ovid-pkg" "\$@"
""";

  static String _npmCliWrapper(String p, String name) => """#!$p/bin/sh
# Ovid runtime wrapper for $name — bypasses the Termux-env shebang.
exec "$p/bin/node" "$p/lib/node_modules/npm/bin/$name-cli.js" "\$@"
""";

  /// Real script with the sandbox prefix baked into the shebang and,
  /// when known, the payload's apt arch baked in place of the `uname`
  /// probe. The raw constant starts with a newline (raw-string
  /// convention), so we lstrip it — a script must begin with exactly
  /// `#!` at byte 0.
  static String _ovidPkgFor(String p, String? arch) {
    var s = _ovidPkg.lstripNewline.replaceFirst('#!/bin/sh', '#!$p/bin/sh');
    if (arch != null && arch.isNotEmpty) {
      s = s.replaceFirst(
        r'ARCH="$(uname -m 2>/dev/null || echo aarch64)"',
        'ARCH="$arch"',
      );
    }
    return s;
  }
}

extension on String {
  String get lstripNewline => startsWith('\n') ? substring(1) : this;
}

const _ovidPkg = r'''
#!/bin/sh
# ovid-pkg − curl+dpkg installer; apt's https method is broken on this device.
set -u
if [ -z "${PREFIX:-}" ]; then echo "missing PREFIX env" >&2; exit 1; fi
PKG_IDX="$PREFIX/var/cache/ovid-pkg"
mkdir -p "$PKG_IDX/archives"
ARCH="$(uname -m 2>/dev/null || echo aarch64)"
case "$ARCH" in
  armv7l|armv8l|armv7*) ARCH=arm ;;
  arm64|aarch64) ARCH=aarch64 ;;
esac

# Mirror order: the app-written list first, then the generated
# sources.list, then the public default. Keeps the script aligned with
# the mirror pool the app actually uses.
MIRROR=""
if [ -r "$PREFIX/etc/apt/ovid-mirrors" ]; then
  MIRROR="$(awk 'NF { print; exit }' "$PREFIX/etc/apt/ovid-mirrors")"
fi
if [ -z "$MIRROR" ] && [ -r "$PREFIX/etc/apt/sources.list" ]; then
  MIRROR="$(awk '/^deb /{print $2; exit}' "$PREFIX/etc/apt/sources.list")"
fi
[ -z "$MIRROR" ] && MIRROR=https://packages.termux.dev/apt/termux-main

# Fetch + decompress the binary index for $ARCH. Returns non-zero when
# every transport fails or decompression yields nothing — never leaves a
# stale index behind a success exit.
_fetch_index() {
  _url="$1"
  if curl -fsSL --retry 2 --connect-timeout 25 "$_url.xz" -o "$PKG_IDX/Packages.xz"; then
    xz -dkf "$PKG_IDX/Packages.xz" || unxz -kf "$PKG_IDX/Packages.xz" || return 1
  elif curl -fsSL --retry 2 "$_url.gz" -o "$PKG_IDX/Packages.gz"; then
    gzip -dkf "$PKG_IDX/Packages.gz" || gunzip -kf "$PKG_IDX/Packages.gz" || return 1
  else
    curl -fsSL --retry 2 "$_url" -o "$PKG_IDX/Packages" || return 1
  fi
  return 0
}

# A usable index exists on disk and actually carries package records.
_index_ok() {
  [ -f "$PKG_IDX/Packages" ] && grep -q '^Package: ' "$PKG_IDX/Packages"
}

cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
  update)
    url="$MIRROR/dists/stable/main/binary-$ARCH/Packages"
    echo "[ovid-pkg] fetch index → $url (curl — apt https is unreliable)"
    _fetch_index "$url" || { echo "[ovid-pkg] index fetch failed" >&2; exit 1; }
    [ ! -f "$PKG_IDX/Packages" ] && { echo "[ovid-pkg] no index on disk" >&2; exit 1; }
    _index_ok || { echo "[ovid-pkg] index empty or stale" >&2; exit 1; }
    echo "[ovid-pkg] index ready ($(wc -l < "$PKG_IDX/Packages") lines)"
    ;;
  search)
    pat="${1:-}"; [ -z "$pat" ] && { echo "usage: ovid-pkg search '<text>'" >&2; exit 1; }
    if ! _index_ok; then ovid-pkg update || exit 1; fi
    _index_ok || { echo "[ovid-pkg] index empty or stale" >&2; exit 1; }
    grep -B8 -- "$pat" "$PKG_IDX/Packages" | grep '^Package: ' | sort -u | head -40
    ;;
  install)
    # Strip apt flags before any package is resolved, so
    # `apt install -y pkg` never tries to install a package named "-y".
    _names=""
    for _a in "$@"; do
      case "$_a" in
        -y|--yes|-q|--quiet) ;;
        *) _names="$_names $_a" ;;
      esac
    done
    # shellcheck disable=SC2086
    set -- $_names
    [ "$#" -lt 1 ] && { echo "usage: ovid-pkg install <pkg>..." >&2; exit 1; }
    if ! _index_ok; then ovid-pkg update || exit 1; fi
    _index_ok || { echo "[ovid-pkg] index empty or stale" >&2; exit 1; }
    work="$PKG_IDX/archives"; targets=""; pending="$*"; missing=""
    for round in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
      [ -z "$pending" ] && break
      next=""
      for name in $pending; do
        case " $targets " in *" $name "*) continue;; esac
        fn="$(awk -v n="$name" '
          /^Package: /    { name=$2 }
          name==n && /^Filename: / { f=$2 }
          name==n && /^Depends: /  { d=$0 }
          name==n && /^$/          { if (f!="") { print f "\n" d; f=""; d="" } }
          END { if (name==n && f!="") print f "\n" d }
        ' "$PKG_IDX/Packages")"
        [ -z "$fn" ] && {
          echo "[ovid-pkg] not found: $name" >&2
          missing="$missing $name"
          continue
        }
        path="$(printf '%s\n' "$fn" | head -1)"
        deps="$(printf '%s\n' "$fn" | tail -1 | sed 's/^Depends: //')"
        out="$work/$(basename "$path")"
        curl -fsSL --retry 2 --connect-timeout 25 "$MIRROR/$path" -o "$out" \
          || { echo "[ovid-pkg] download failed: $name" >&2; exit 1; }
        targets="$targets $out"
        for d in $(printf '%s\n' "$deps" | tr ',' '\n' | sed 's/(.*//; s/|.*//; s/ //g'); do
          [ -n "$d" ] && grep -q "^Package: $d$" "$PKG_IDX/Packages" && next="$next $d"
        done
      done
      pending="$next"
    done
    if [ -z "$targets" ]; then
      [ -n "$missing" ] && { echo "[ovid-pkg] not available:$missing" >&2; exit 1; }
      echo "[ovid-pkg] nothing to install"
      exit 0
    fi
    echo "[ovid-pkg] installing$targets"
    # Run dpkg into a log and tail it afterwards: piping into tail made
    # every failure look like exit 0 and hid broken installs.
    _dlog="$PKG_IDX/dpkg.log"
    dpkg --root="$PREFIX" --admindir="$PREFIX/var/lib/dpkg" \
      --log="$PREFIX/var/log/dpkg.log" -i $targets > "$_dlog" 2>&1
    rc=$?
    tail -8 "$_dlog"
    [ "$rc" -ne 0 ] && { echo "[ovid-pkg] dpkg failed (exit $rc)" >&2; exit "$rc"; }
    [ -n "$missing" ] && { echo "[ovid-pkg] not available:$missing" >&2; exit 1; }
    ;;
  upgrade|full-upgrade)
    echo "[ovid-pkg] upgrade is not supported by ovid-pkg; use 'ovid-pkg install <pkg>...' to (re)install packages" >&2
    exit 2
    ;;
  list-installed|list)
    dpkg --root="$PREFIX" --admindir="$PREFIX/var/lib/dpkg" -l 2>/dev/null | head -80
    ;;
  *)
    echo "usage: ovid-pkg {update|install|search|list-installed|upgrade}" >&2
    exit 2
    ;;
esac
''';

// End of file.