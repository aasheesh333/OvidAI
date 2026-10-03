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
import 'diag.dart';

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
    } catch (e) { Diag.swallow('sandbox_pkg', e); }
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
        } catch (e) { Diag.swallow('sandbox_pkg', e); }
      }
    } catch (e) { Diag.swallow('sandbox_pkg', e); }
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
  armv7l|armv8l|armv7*) ARCH="arm" ;;
  arm64|aarch64) ARCH="aarch64" ;;
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
  # .gz first: the mirror serves Packages.gz (and plain) but not Packages.xz,
  # so probing .xz first printed a misleading "curl: (22) ... 404" on every
  # update. Expected probe failures are silenced; only the final plain fetch
  # surfaces an error.
  if curl -fsSL --retry 2 --connect-timeout 25 "$_url.gz" -o "$PKG_IDX/Packages.gz" 2>/dev/null; then
    gzip -dkf "$PKG_IDX/Packages.gz" || gunzip -kf "$PKG_IDX/Packages.gz" || return 1
  elif curl -fsSL --retry 2 --connect-timeout 25 "$_url.xz" -o "$PKG_IDX/Packages.xz" 2>/dev/null; then
    xz -dkf "$PKG_IDX/Packages.xz" || unxz -kf "$PKG_IDX/Packages.xz" || return 1
  else
    curl -fsSL --retry 2 --connect-timeout 25 "$_url" -o "$PKG_IDX/Packages" || return 1
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
    work="$PKG_IDX/archives"; targets=""; pending="$*"; visited=""
    for round in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
      [ -z "$pending" ] && break
      next=""
      for name in $pending; do
        case " $visited " in *" $name "*) continue;; esac
        fn="$(awk -v n="$name" '
          /^Package: /    { name=$2 }
          name==n && /^Filename: / { f=$2 }
          name==n && /^Depends: /  { d=$0 }
          name==n && /^$/          { if (f!="") { print f "\n" d; f=""; d="" } }
          END { if (name==n && f!="") print f "\n" d }
        ' "$PKG_IDX/Packages")"
        [ -z "$fn" ] && {
          echo "[ovid-pkg] not found: $name" >&2
          exit 1
        }
        path="$(printf '%s\n' "$fn" | head -1)"
        deps="$(printf '%s\n' "$fn" | sed -n 's/^Depends: //p')"
        out="$work/$(basename "$path")"
        curl -fsSL --retry 2 --connect-timeout 25 "$MIRROR/$path" -o "$out" \
          || { echo "[ovid-pkg] download failed: $name" >&2; exit 1; }
        targets="$targets $out"
        visited="$visited $name"
        # Resolve each comma-separated requirement independently. Keep all
        # alternatives after removing version constraints, then choose the
        # first package with an archive in this index. Never drop a requirement.
        for requirement in $(printf '%s\n' "$deps" | sed 's/([^)]*)//g; s/[[:space:]]//g' | tr ',' ' '); do
          chosen=""
          for d in $(printf '%s\n' "$requirement" | tr '|' ' '); do
            if awk -v n="$d" '
              /^Package: / { name=$2 }
              name==n && /^Filename: / && NF>1 { found=1 }
              END { exit !found }
            ' "$PKG_IDX/Packages"; then
              chosen="$d"
              break
            fi
          done
          [ -n "$chosen" ] || {
            echo "[ovid-pkg] required dependency not available for $name: $requirement" >&2
            exit 1
          }
          case " $visited $next " in *" $chosen "*) ;; *) next="$next $chosen";; esac
        done
      done
      # A package queued earlier in this round may have since been visited.
      # Filter again so back edges on round 16 do not look like unfinished work.
      pending=""
      for name in $next; do
        case " $visited " in *" $name "*) ;; *) pending="$pending $name";; esac
      done
    done
    [ -n "$pending" ] && {
      echo "[ovid-pkg] dependency traversal limit (16 rounds) exceeded; unresolved:$pending" >&2
      exit 1
    }
    if [ -z "$targets" ]; then
      echo "[ovid-pkg] nothing to install"
      exit 0
    fi
    echo "[ovid-pkg] installing$targets"
    # dpkg's compiled-in Termux prefix makes `dpkg -i` fail on-device
    # (Permission denied on the other app's admindir). `dpkg-deb -x`
    # extracts a .deb's data archive straight into $PREFIX with NO admindir
    # or status database, which works inside our own writable prefix. The
    # dependency closure was already resolved + downloaded above.
    _dlog="$PKG_IDX/extract.log"
    : > "$_dlog"
    for _deb in $targets; do
      if ! dpkg-deb -x "$_deb" "$PREFIX" >> "$_dlog" 2>&1; then
        tail -8 "$_dlog"
        echo "[ovid-pkg] extract failed: $(basename "$_deb")" >&2
        exit 1
      fi
    done
    tail -4 "$_dlog" 2>/dev/null
    echo "[ovid-pkg] extracted $(echo $targets | wc -w) package(s)"
    # Termux .deb payloads are rooted at /data/data/com.termux/files/usr, so
    # `dpkg-deb -x … $PREFIX` lands every file under
    # $PREFIX/data/data/com.termux/files/usr/… — off PATH, off the linker
    # search path, and invisible to every readiness probe that checks
    # `$PREFIX/bin/<tool>`. The install then "succeeded" while the binary did
    # not exist where anything looks for it: that is how proot (Flutter),
    # openjdk (Kotlin) and clang installs passed and still failed. Relocate
    # the payload into $PREFIX now, merging into directories that already
    # exist from the bootstrap.
    _tp="$PREFIX/data/data/com.termux/files/usr"
    if [ -d "$_tp" ]; then
      _moved=0
      _relocation_failed=0
      for _e in "$_tp"/*; do
        [ -e "$_e" ] || continue
        _b="$(basename "$_e")"
        if [ -d "$_e" ] && [ -d "$PREFIX/$_b" ]; then
          if cp -a "$_e/." "$PREFIX/$_b/" && rm -rf "$_e"; then
            _moved=$((_moved+1))
          else
            echo "[ovid-pkg] could not relocate $_b (copy or cleanup failed)" >&2
            _relocation_failed=1
          fi
        elif mv "$_e" "$PREFIX/$_b"; then
          _moved=$((_moved+1))
        elif cp -a "$_e" "$PREFIX/" && rm -rf "$_e"; then
          _moved=$((_moved+1))
        else
          echo "[ovid-pkg] could not relocate $_b (move, copy or cleanup failed)" >&2
          _relocation_failed=1
        fi
      done
      rmdir -p "$_tp" 2>/dev/null
      [ "$_moved" -gt 0 ] && echo "[ovid-pkg] relocated $_moved path(s) into \$PREFIX"
      [ "$_relocation_failed" -ne 0 ] && exit 1
    fi
    exit 0
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
