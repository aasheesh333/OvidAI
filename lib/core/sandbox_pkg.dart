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
    _writeText('$p/libexec/ovid-pkg-resolve.awk', _dependencyResolver);
    _writeText('$p/libexec/ovid-pkg-archive.awk', _archiveValidator);
    _writeText('$p/libexec/ovid-pkg-overlay.awk', _overlayValidator);
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
    } catch (e) {
      Diag.swallow('sandbox_pkg', e);
    }
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
        } catch (e) {
          Diag.swallow('sandbox_pkg', e);
        }
      }
    } catch (e) {
      Diag.swallow('sandbox_pkg', e);
    }
  }

  static String _pkgWrapper(String p, String tool) =>
      """#!$p/bin/sh
# Ovid-wrapped $tool — package ops always work even when apt can't reach
# a mirror (Transport HTTPS broken → see ovid-pkg).
exec "$p/bin/ovid-pkg" "\$@"
""";

  static String _npmCliWrapper(String p, String name) =>
      """#!$p/bin/sh
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
    # Resolve the entire closure before transport or extraction. An owned
    # temporary directory prevents archive-name collisions between versions.
    work="$(mktemp -d "$PKG_IDX/archives/install.XXXXXX")" || exit 1
    trap 'rm -rf "$work"' EXIT
    trap 'exit 1' HUP INT TERM
    [ "$(wc -c < "$PKG_IDX/Packages")" -le 33554432 ] || {
      echo '[ovid-pkg] dependency index size limit exceeded' >&2; exit 1;
    }
    OVID_REQUESTS="$*" OVID_ARCH="$ARCH" awk -f "$PREFIX/libexec/ovid-pkg-resolve.awk" \
      "$PKG_IDX/Packages" > "$work/plan" || exit 1
    targets=""
    while IFS='|' read -r id name version architecture path size hash; do
      out="$work/$id.deb"
      curl -fsSL --retry 2 --connect-timeout 25 --max-filesize "$size" "$MIRROR/$path" -o "$out"
      status=$?
      [ "$status" -eq 0 ] || { echo "[ovid-pkg] download failed: $name" >&2; exit "$status"; }
      [ "$(wc -c < "$out")" = "$size" ] || {
        echo "[ovid-pkg] archive size verification failed: $name" >&2; exit 1;
      }
      actual="$(sha256sum "$out")" || { echo "[ovid-pkg] SHA256 tool failed: $name" >&2; exit 1; }
      [ "${actual%% *}" = "$hash" ] || {
        echo "[ovid-pkg] SHA256 verification failed: $name" >&2; exit 1;
      }
      for field in Package Version Architecture; do
        actual="$(dpkg-deb -f "$out" "$field")" || {
          echo "[ovid-pkg] invalid archive control: $name" >&2; exit 1;
        }
        case "$field" in Package) expected="$name";; Version) expected="$version";; Architecture) expected="$architecture";; esac
        [ "$actual" = "$expected" ] || {
          echo "[ovid-pkg] archive identity mismatch: $name ($field)" >&2; exit 1;
        }
      done
      # Materialize then inspect: never hide dpkg-deb/tar status in a pipe.
      # Limit decompressed tar size (ulimit units vary by shell: <= 1 GiB).
      (ulimit -f 1048576 && dpkg-deb --fsys-tarfile "$out" > "$work/data.tar") || {
        echo "[ovid-pkg] invalid or oversized archive data: $name" >&2; exit 1;
      }
      LC_ALL=C tar -tvf "$work/data.tar" > "$work/$id.list" || {
        echo "[ovid-pkg] archive listing failed: $name" >&2; exit 1;
      }
      rm -f "$work/data.tar" || exit 1
      targets="$targets $out"
    done < "$work/plan"
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
    # Validate the union as well as each archive: another package must not
    # introduce a link parent or a link cycle across the selected closure.
    awk -f "$PREFIX/libexec/ovid-pkg-archive.awk" "$work/"*.list > "$work/paths" || exit 1
    _contained() {
      _resolved="$(realpath -m -- "$1")" || return 1
      case "$_resolved" in "$PREFIX"|"$PREFIX"/*) return 0;; esac
      echo "[ovid-pkg] destination symlink escapes prefix: $1" >&2
      return 1
    }
    # A safe leaf can be replaced without following it. Parent directory
    # aliases are retained, but their resolved destinations must be contained.
    while IFS='|' read -r kind entry target; do
        for relative in "$entry" "${entry#data/data/com.termux/files/usr/}"; do
          destination="$PREFIX/$relative"
          _contained "$destination" || exit 1
        done
        if [ -n "$target" ]; then
          _contained "$PREFIX/$target" || exit 1
          _contained "$PREFIX/${target#data/data/com.termux/files/usr/}" || exit 1
        fi
    done < "$work/paths"
    # Validate the effective link graph, not two independent approximations.
    # Incoming leaves override existing leaves; existing directory aliases
    # remain in effect. Check both publication and post-relocation layouts.
    for layout in original relocated; do
      OVID_LAYOUT="$layout" awk -f "$PREFIX/libexec/ovid-pkg-overlay.awk" "$work/paths" || exit 1
    done
    mkdir "$work/stage" || exit 1
    for _deb in $targets; do
      dpkg-deb -x "$_deb" "$work/stage" >> "$_dlog" 2>&1
      status=$?
      if [ "$status" -ne 0 ]; then
        tail -8 "$_dlog"
        echo "[ovid-pkg] extract failed: $(basename "$_deb")" >&2
        exit "$status"
      fi
    done
    # Only after every archive extracted successfully may repaired leaves be
    # unlinked. cp must never write through an existing file symlink.
    while IFS='|' read -r kind entry target; do
      [ "$kind" = d ] && continue
      for relative in "$entry" "${entry#data/data/com.termux/files/usr/}"; do
        destination="$PREFIX/$relative"
        _contained "$destination" || exit 1
        if [ -L "$destination" ]; then rm -- "$destination" || exit 1; fi
      done
    done < "$work/paths"
    # cp -a refuses a directory over an existing directory symlink. Merge
    # these already containment-checked aliases explicitly, deepest first,
    # and exclude their consumed stage trees from the ordinary bulk copy.
    awk -F '|' '$1=="d" { print $2 }' "$work/paths" | LC_ALL=C sort -r > "$work/directories"
    while IFS= read -r entry; do
      for relative in "$entry" "${entry#data/data/com.termux/files/usr/}"; do
        source="$work/stage/$entry"; destination="$PREFIX/$relative"
        if [ -d "$source" ] && [ -L "$destination" ]; then
          _contained "$destination" || exit 1
          mkdir -p -- "$_resolved" || exit 1
          cp -a "$source/." "$_resolved/" && rm -rf -- "$source" || {
            echo '[ovid-pkg] staged archive alias publication failed' >&2; exit 1;
          }
        fi
      done
    done < "$work/directories"
    cp -a "$work/stage/." "$PREFIX/" || {
      echo '[ovid-pkg] staged archive publication failed' >&2; exit 1;
    }
    tail -4 "$_dlog" 2>/dev/null
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
    echo "[ovid-pkg] extracted $(echo $targets | wc -w) package(s)"
    exit 0
    ;;
  upgrade|full-upgrade)
    echo "[ovid-pkg] upgrade is not supported by ovid-pkg; use 'ovid-pkg install <pkg>...' to (re)install packages" >&2
    exit 2
    ;;
  list-installed|list)
    dpkg --root="$PREFIX" --admindir="$PREFIX/var/lib/dpkg" -l
    exit $?
    ;;
  *)
    echo "usage: ovid-pkg {update|install|search|list-installed|upgrade}" >&2
    exit 2
    ;;
esac
''';

// Portable awk keeps resolution available before Node/Python are installed.
// dpkg is used only for Debian version comparison, never to install packages.
// Search is deliberately bounded and fail-closed; a limit is not a valid plan.
const _dependencyResolver = r'''
BEGIN { arch = ENVIRON["OVID_ARCH"] }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function fail(s) { print "[ovid-pkg] " s > "/dev/stderr"; fatal=1; exit 1 }
function version(s) { return s ~ /^[0-9][A-Za-z0-9.+:~_-]*$/ }
function compare(a, op, b, key, rc) {
  key=a SUBSEP op SUBSEP b
  if (!(key in comparisons)) {
    rc=system("dpkg --compare-versions \"" a "\" \"" op "\" \"" b "\"")
    if (rc != 0 && rc != 1) fail("dependency version comparator failed")
    comparisons[key]=(rc == 0)
  }
  return comparisons[key]
}
function term(s, base, v, n, parts) {
  pn=pq=po=pv=""; s=trim(s)
  if (s ~ /\(/) {
    base=s; sub(/\(.*/, "", base)
    v=substr(s, length(base)+1)
    if (v !~ /^\((<<|<=|=|>=|>>)[ \t]+[^() \t]+\)$/) return 0
    sub(/^\(/, "", v); sub(/\)$/, "", v)
    split(v, parts, /[ \t]+/); po=parts[1]; pv=parts[2]
    if (!version(pv)) return 0
    s=trim(base)
  }
  n=split(s, parts, ":")
  if (n>2 || parts[1] !~ /^[a-z0-9][a-z0-9+.-]*$/) return 0
  pn=parts[1]
  if (n==2) {
    pq=parts[2]
    if (pq !~ /^[a-z0-9][a-z0-9-]*$/) return 0
  }
  return 1
}
function finish( k, name, count, i, j, reqs, alts, p) {
  if (!field["Package"]) { for (k in field) delete field[k]; return }
  if (++total>50000) fail("dependency index record limit exceeded")
  name=field["Package"]
  if (name !~ /^[a-z0-9][a-z0-9+.-]*$/ || !version(field["Version"]) ||
      field["Architecture"] !~ /^[a-z0-9][a-z0-9-]*$/)
    fail("invalid dependency metadata: " name)
  for (k in field) data[total,k]=field[k]
  byName[name]=byName[name] " " total
  p=field["Pre-Depends"]
  if (field["Depends"]!="") p=p (p=="" ? "" : ",") field["Depends"]
  if (p!="") {
    count=split(p, reqs, ",")
    if (count>256) fail("dependency requirement limit exceeded: " name)
    for (i=1;i<=count;i++) {
      requirements[total,i]=trim(reqs[i])
      if (split(reqs[i], alts, "|")>64) fail("dependency alternative limit exceeded: " name)
      for (j in alts) if (!term(alts[j])) fail("invalid dependency for " name ": " reqs[i])
    }
    requirementCount[total]=count
  }
  if (field["Provides"]!="") {
    count=split(field["Provides"], reqs, ",")
    if (count>256) fail("dependency provider limit exceeded: " name)
    for (i=1;i<=count;i++) {
      if (!term(reqs[i]) || pq!="" || (po!="" && po!="="))
        fail("invalid dependency Provides: " name)
      providers[pn]=providers[pn] " " total
      provided[total,pn]=pv
    }
  }
  for (k in field) delete field[k]
}
function compatible(id, qualifier, a) {
  a=data[id,"Architecture"]
  if (a!=arch && a!="all") return 0
  if (qualifier=="any") return data[id,"Multi-Arch"]=="allowed"
  return qualifier=="" || qualifier=="native" || qualifier==arch
}
function accepts(id, name, qualifier, op, v, actual) {
  if (!compatible(id,qualifier)) return 0
  if (data[id,"Package"]==name) actual=data[id,"Version"]
  else {
    if (!((id SUBSEP name) in provided)) return 0
    actual=provided[id,name]
  }
  return op=="" || (actual!="" && compare(actual,op,v))
}
function visit(id, depth, j) {
  if (color[id]==1) { problem="dependency cycle at " data[id,"Package"]; return 0 }
  if (color[id]==2) return 1
  if (depth>64) { problem="dependency depth limit at " data[id,"Package"]; return 0 }
  color[id]=1
  for (j=1;j<=total;j++) if (edges[id,j] && !visit(j,depth+1)) return 0
  color[id]=2; order[++orderCount]=id
  return 1
}
function completed( k, i) {
  for (k in color) delete color[k]
  orderCount=0
  for (i=1;i<=rootCount;i++) if (!visit(rootIds[i],1)) return 0
  return 1
}
function solve(queue, selectedCount, depth, line, rest, sep, owner, req, n, a,
               alternatives, name, qualifier, op, v, pool, ids, seen, candidates,
               count, i, j, id, tmp, pkg, fresh, edgeKey, hadEdge, remaining, rootSlot) {
  if (++steps>8192 || depth>1024) fail("dependency search limit exceeded")
  if (queue=="") return completed()
  sep=index(queue,"\n"); line=substr(queue,1,sep-1); rest=substr(queue,sep+1)
  sep=index(line,"\t"); owner=substr(line,1,sep-1)+0; req=substr(line,sep+1)
  n=split(req,alternatives,"|")
  for (a=1;a<=n;a++) {
    if (!term(alternatives[a])) fail("invalid dependency: " req)
    name=pn; qualifier=pq; op=po; v=pv
    pool=byName[name] providers[name]; split(pool,ids," "); count=0
    for (i in seen) delete seen[i]
    for (i in ids) {
      id=ids[i]+0
      if (id && !seen[id]++ && accepts(id,name,qualifier,op,v)) {
        if (++count>64) fail("dependency candidate limit exceeded: " name)
        candidates[count]=id
      }
    }
    # Stable preference: real packages before providers, highest version first.
    for (i=1;i<=count;i++) for (j=i+1;j<=count;j++) {
      if ((data[candidates[j],"Package"]==name && data[candidates[i],"Package"]!=name) ||
          (data[candidates[j],"Package"]==data[candidates[i],"Package"] &&
           compare(data[candidates[j],"Version"],">>",data[candidates[i],"Version"])) ||
          (data[candidates[j],"Package"]!=name && data[candidates[i],"Package"]!=name && candidates[j]<candidates[i])) {
        tmp=candidates[i]; candidates[i]=candidates[j]; candidates[j]=tmp
      }
    }
    for (i=1;i<=count;i++) {
      id=candidates[i]; pkg=data[id,"Package"]
      if (selected[pkg] && selected[pkg]!=id) continue
      fresh=!selected[pkg]
      if (fresh && selectedCount>=256) fail("dependency package limit exceeded at " pkg)
      selected[pkg]=id
      edgeKey=owner SUBSEP id; hadEdge=edges[edgeKey]
      rootSlot=0
      if (owner) edges[edgeKey]=1
      else { rootSlot=++rootCount; rootIds[rootSlot]=id }
      remaining=rest
      if (fresh) for (j=requirementCount[id];j>=1;j--) remaining=id "\t" requirements[id,j] "\n" remaining
      if (solve(remaining,selectedCount+fresh,depth+1)) return 1
      if (rootSlot) { delete rootIds[rootSlot]; rootCount-- }
      if (!hadEdge) delete edges[edgeKey]
      if (fresh) delete selected[pkg]
    }
  }
  if (problem=="") problem="unresolved dependency for " (owner ? data[owner,"Package"] : "request") ": " req
  return 0
}
{
  sub(/\r$/, "")
  if (length($0)>65536) fail("dependency metadata line limit exceeded")
  if ($0=="") { finish(); key=""; next }
  if ($0 ~ /^[ \t]/) {
    if (key=="") fail("invalid dependency metadata continuation")
    field[key]=field[key] " " trim($0); next
  }
  colon=index($0,":")
  if (!colon) fail("invalid dependency metadata field")
  key=substr($0,1,colon-1)
  if (key in field) fail("duplicate dependency metadata field: " key)
  field[key]=trim(substr($0,colon+1))
}
END {
  if (fatal) exit 1
  finish()
  n=split(ENVIRON["OVID_REQUESTS"],roots," "); queue=""
  for (i=1;i<=n;i++) {
    if (!term(roots[i]) || po!="") fail("invalid dependency request: " roots[i])
    queue=queue "0\t" roots[i] "\n"
  }
  if (!solve(queue,0,0)) fail(problem)
  # Validate all selected metadata before emitting any transport plan.
  for (i=1;i<=orderCount;i++) {
    id=order[i]; path=data[id,"Filename"]; size=data[id,"Size"]; hash=data[id,"SHA256"]
    if (path !~ /^[A-Za-z0-9][A-Za-z0-9_+.~:\/-]*\.deb$/ || path ~ /(^|\/)\.\.?\// || path ~ /\/\// ||
        size !~ /^[1-9][0-9]*$/ || size+0>536870912 ||
        length(hash)!=64 || hash ~ /[^a-fA-F0-9]/)
      fail("invalid archive metadata: " data[id,"Package"])
    data[id,"SHA256"]=tolower(hash)
  }
  for (i=1;i<=orderCount;i++) {
    id=order[i]
    print id "|" data[id,"Package"] "|" data[id,"Version"] "|" data[id,"Architecture"] "|" data[id,"Filename"] "|" data[id,"Size"] "|" data[id,"SHA256"]
  }
}
''';

// Parse the fixed verbose-listing header, preserving printable member names.
// Ambiguous listing delimiters/escapes and special files still fail closed.
const _archiveValidator = r'''
function fail(s) { print "[ovid-pkg] unsafe archive: " s > "/dev/stderr"; bad=1; exit 1 }
function printable(s) {
  return s!="" && s !~ /[[:cntrl:]\\|]/ && s !~ / -> / && s !~ / link to /
}
function normalized(s, count, parts, i, depth, stack, result) {
  if (!printable(s) || s ~ /^\//) fail("invalid path or link target")
  count=split(s,parts,"/"); depth=0
  for (i=1;i<=count;i++) {
    if (parts[i]=="" || parts[i]==".") continue
    if (parts[i]=="..") {
      if (!depth) fail("link target escapes archive root")
      depth--
    } else stack[++depth]=parts[i]
  }
  result=""
  for (i=1;i<=depth;i++) result=result (i==1 ? "" : "/") stack[i]
  return result
}
function parent(s) { if (!sub(/\/[^\/]*$/, "", s)) return ""; return s }
function relocated(s) { sub(/^data\/data\/com.termux\/files\/usr\//,"",s); return s }
function resolve(s, moved, steps, count, parts, i, j, prefix, suffix, changed, key) {
  for (steps=0;steps<64;steps++) {
    count=split(s,parts,"/"); prefix=""; changed=0
    for (i=1;i<=count;i++) {
      if (parts[i]=="" || parts[i]==".") continue
      if (parts[i]=="..") {
        if (prefix=="") fail("link target escapes archive root")
        prefix=parent(prefix); continue
      }
      prefix=prefix (prefix=="" ? "" : "/") parts[i]
      key=(moved ? "m" : "o") SUBSEP prefix
      if (key in rawLinks) {
        suffix=""
        for (j=i+1;j<=count;j++) suffix=suffix "/" parts[j]
        s=rawLinks[key] suffix; changed=1; break
      }
    }
    if (!changed) return prefix
  }
  fail("link cycle or depth limit")
}
{
  if (++entries>100000) fail("member limit exceeded")
  type=substr($1,1,1); name=$0; target=""
  # mode owner/group size date time precede the complete (possibly spaced) name.
  for (i=1;i<=5;i++) if (!sub(/^[^ \t]+[ \t]+/,"",name)) fail("invalid listing header")
  if (type=="l" || type=="h") {
    delimiter=(type=="l" ? " -> " : " link to "); at=index(name,delimiter)
    if (!at) fail("missing link target")
    target=substr(name,at+length(delimiter)); name=substr(name,1,at-1)
    if (!printable(target) || target ~ /^\//) fail("invalid link target")
  } else if (type!="d" && type!="-") fail("unexpected member type")
  # Member paths themselves must never contain parent traversal, even when
  # lexical normalization would happen to keep them inside the root.
  if (name ~ /(^|\/)\.\.($|\/)/) fail("member path traversal")
  name=normalized(name)
  if (name=="" && type=="d") next
  if (name=="") fail("empty member path")
  if ($3 !~ /^[0-9]+$/) fail("invalid member size")
  bytes+=$3
  if (bytes>1073741824) fail("expanded size limit exceeded")
  if ((name in kinds) && (kinds[name]!=type || (type!="d" && type!="-"))) fail("conflicting archive member")
  kinds[name]=type
  if (type=="l") {
    base=parent(name)
    links[name]=1
    rawLinks["o",name]=(base=="" ? "" : base "/") target
    # Check containment again after the Termux prefix is relocated.
    base=parent(relocated(name))
    rawLinks["m",relocated(name)]=(base=="" ? "" : base "/") target
  }
  if (type=="h") hard[name]=normalized(target)
}
END {
  if (bad) exit 1
  if (!entries) fail("empty member listing")
  for (name in kinds) {
    ancestor=parent(name)
    while (ancestor!="") {
      if (ancestor in links) fail("symlink parent " ancestor)
      ancestor=parent(ancestor)
    }
    target=""
    if (name in links) {
      resolve(name,0)
      resolve(relocated(name),1)
      target=rawLinks["o",name]
    }
    if (name in hard) {
      target=hard[name]
      # Hard links name archive-root members, not symlink-relative paths.
      # Requiring an ordinary member prevents linking external or symlink data.
      if (kinds[target]!="-" || resolve(target,0)!=target) fail("invalid hard link target")
      if (relocated(name)!=name && relocated(target)==target) fail("hard link crosses relocated root")
    }
    print kinds[name] "|" name "|" target
  }
}
''';

// Resolve package and on-disk links as one overlay, without mutating PREFIX.
// Shell operands are quoted; neither index fields nor link text become code.
const _overlayValidator = r'''
function fail(s) { print "[ovid-pkg] unsafe combined symlink graph: " s > "/dev/stderr"; bad=1; exit 1 }
function quote(s) { gsub(/'/,"'\\''",s); return "'" s "'" }
function parent(s) { if (!sub(/\/[^\/]*$/, "", s)) return ""; return s }
function mapped(s) { if (ENVIRON["OVID_LAYOUT"]=="relocated") sub(/^data\/data\/com.termux\/files\/usr\//,"",s); return s }
function relative(s) {
  if (s==root) return ""
  if (index(s,root "/")!=1) fail("target escapes prefix: " s)
  return substr(s,length(root)+2)
}
function existing(s, cmd, line, rc, count, target, status, unsupported) {
  if (!(s in checked)) {
    cmd="if [ -L " quote(root "/" s) " ]; then readlink -- " quote(root "/" s) "; fi"
    # readlink adds exactly one record terminator. A second record (even
    # empty) belongs to the target itself, including a trailing newline.
    # Drain the stream before closing so no part of a target is ignored.
    count=0; unsupported=0
    while ((rc=(cmd | getline line))>0) {
      count++
      if (count>1 || line ~ /[[:cntrl:]]/) unsupported=1
      if (count==1) target=line
    }
    status=close(cmd)
    if (status!=0 || rc<0) fail("cannot inspect existing link: " s)
    if (unsupported) fail("unsupported existing link target")
    checked[s]=1
    if (count) diskLinks[s]=target
  }
  return s in diskLinks
}
function resolve(s, hops, n, parts, i, j, path, suffix, target, found) {
  for (hops=0;hops<64;hops++) {
    n=split(s,parts,"/"); path=""; found=0
    for (i=1;i<=n;i++) {
      if (parts[i]=="" || parts[i]==".") continue
      if (parts[i]=="..") {
        if (path=="") fail("parent traversal escapes prefix")
        path=parent(path); continue
      }
      path=path (path=="" ? "" : "/") parts[i]
      if ((path in kinds) && kinds[path]=="l") { target=links[path]; found=1 }
      else if (!(path in kinds) || kinds[path]=="d") {
        if (existing(path)) { target=diskLinks[path]; found=1 }
      }
      if (found) {
        suffix=""
        for (j=i+1;j<=n;j++) suffix=suffix "/" parts[j]
        if (target ~ /^\//) s=relative(target) suffix
        else s=(parent(path)=="" ? "" : parent(path) "/") target suffix
        break
      }
    }
    if (!found) return path
  }
  fail("link cycle or depth limit")
}
BEGIN { FS="|"; root=ENVIRON["PREFIX"] }
{
  name=mapped($2); target=$3
  # Map through existing parent aliases to the actual publication location.
  # realpath resolves only existing parents here, never the replaced leaf.
  cmd="realpath -m -- " quote(root "/" parent(name))
  if ((cmd | getline location)!=1) fail("cannot resolve publication parent")
  if (close(cmd)!=0) fail("cannot resolve publication parent")
  location=relative(location)
  leaf=name; sub(/^.*\//,"",leaf)
  key=location (location=="" ? "" : "/") leaf
  if ((key in kinds) && (kinds[key]!=$1 || ($1=="l" && links[key]!=target)))
    fail("conflicting publication paths: " name)
  kinds[key]=$1
  if ($1=="l") {
    # The archive validator emits the unnormalized parent + raw target.
    base=parent($2)
    if (base!="") target=substr(target,length(base)+2)
    links[key]=target
  }
  requests[name]=1
}
END {
  if (bad) exit 1
  for (name in requests) resolve(name)
  for (name in kinds) resolve(name)
}
''';
