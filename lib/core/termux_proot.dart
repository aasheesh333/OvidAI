/// Runs the Termux userland under `proot`, with the app-private sandbox
/// prefix bound at the path every Termux package was compiled for.
///
/// Why: every Termux binary, script, config and maintainer script has
/// `/data/data/com.termux/files/usr` compiled in (ELF RUNPATH, shebangs,
/// dpkg CONFIGDIR/ADMINDIR, apt's Dir defaults, python's prefix, git's
/// exec-path, openssl's config dir, …). Termux documents that a different
/// package name needs every package rebuilt for the new prefix. Ovid's
/// prefix lives at `/data/user/0/com.dhanuk.ovidai/files/sandbox` (longer, so
/// binaries cannot be patched in place) and on a device where the Termux app
/// is installed the compiled-in path belongs to ANOTHER app (EACCES); without
/// Termux it simply does not exist (ENOENT). Rewriting paths one package at a
/// time (the previous design: dpkg `--root`, binary patches, shebang sed,
/// APT_CONFIG overrides, custom installers) cannot cover hundreds of packages.
///
/// proot (ptrace path translation, the mechanism behind `termux-chroot`,
/// proot-distro, UserLAnd and AnLinux) makes the compiled-in paths resolve to
/// the app's own directories for EVERY process in the tree, so stock apt,
/// dpkg and packages run unmodified:
///
///     <files>/sandbox/.termux-root  →  /data/data/com.termux
///     <files>/sandbox               →  /data/data/com.termux/files/usr
///     <files>/sandbox/home          →  /data/data/com.termux/files/home
///
/// The first binding is a private "glue" directory: the real
/// `/data/data/com.termux` (when Termux is installed) is never touched, and
/// apt's `Dir::Cache` (`/data/data/com.termux/cache`) lands inside the
/// sandbox. Host paths (workspaces, credential files) stay valid inside
/// proot, because proot only translates the bound guest paths.
///
/// proot itself, libtalloc and libandroid-shmem come from the signed Termux
/// repository debs vendored into the bootstrap payload (tool/bootstrap_supply.py)
/// and registered with dpkg, so apt upgrades them like any other package.
library;

import 'dart:io';

/// Paths and process wiring for one sandbox prefix.
class TermuxProot {
  TermuxProot(this.prefix);

  /// Host path of the sandbox prefix (`<files>/sandbox`).
  final String prefix;

  static const termuxRoot = '/data/data/com.termux';
  static const guestFiles = '$termuxRoot/files';

  /// The prefix every Termux package was compiled for.
  static const guestPrefix = '$guestFiles/usr';
  static const guestHome = '$guestFiles/home';

  /// Layout marker inside the prefix. A prefix without it was produced by
  /// the old native (path-rewriting) design and is replaced on the next
  /// setup, keeping `home/` (see [SandboxService] install).
  static const layoutMarker = '.ovid-layout';
  static const layoutVersion = 'proot-v1';

  /// Private directory bound at [termuxRoot] (relative to the prefix).
  static const glueDir = '.termux-root';

  static const prootRel = 'bin/proot';
  static const loaderRel = 'libexec/proot/loader';
  static const preloadRel = 'lib/libtermux-exec-ld-preload.so';

  String get glue => '$prefix/$glueDir';
  String get home => '$prefix/home';
  String get proot => '$prefix/$prootRel';
  String get loader => '$prefix/$loaderRel';

  /// True when [prefix] was built for this design.
  static bool isProotLayout(String prefix) {
    try {
      final marker = File('$prefix/$layoutMarker');
      return marker.existsSync() &&
          marker.readAsStringSync().trim() == layoutVersion &&
          File('$prefix/$prootRel').existsSync() &&
          File('$prefix/$loaderRel').existsSync();
    } catch (_) {
      return false;
    }
  }

  /// A prefix left by the native path-rewriting design (any build before
  /// proot-v1): no layout marker, and the artifacts that design wrote on
  /// every install AND every boot (`etc/apt/ovid-apt.conf`, the
  /// `data/data/com.termux/files/usr` alias symlink).
  static bool isLegacyLayout(String prefix) {
    if (!File('$prefix/bin/bash').existsSync() ||
        File('$prefix/$layoutMarker').existsSync()) {
      return false;
    }
    return File('$prefix/etc/apt/ovid-apt.conf').existsSync() ||
        FileSystemEntity.typeSync('$prefix/data/data/com.termux/files/usr',
                followLinks: false) ==
            FileSystemEntityType.link;
  }

  /// Directories that must exist before proot/apt run. Termux apt keeps its
  /// archive cache OUTSIDE usr (`/data/data/com.termux/cache/apt`), and the
  /// trimmed bootstrap ships no empty dirs.
  List<String> get requiredDirectories => [
        '$glue/files/usr', // mount points for the nested bindings
        '$glue/files/home',
        '$glue/cache/apt/archives/partial',
        '$prefix/home',
        '$prefix/tmp',
        '$prefix/etc/apt/apt.conf.d',
        '$prefix/etc/apt/preferences.d',
        '$prefix/etc/apt/sources.list.d',
        '$prefix/etc/apt/trusted.gpg.d',
        '$prefix/var/lib/apt/lists/partial',
        '$prefix/var/cache/apt/archives/partial',
        '$prefix/var/log/apt',
        '$prefix/var/lib/dpkg/info',
        '$prefix/var/lib/dpkg/updates',
        '$prefix/var/lib/dpkg/triggers',
      ];

  /// Create [requiredDirectories] and the layout marker. Idempotent.
  void ensureLayout() {
    for (final d in requiredDirectories) {
      Directory(d).createSync(recursive: true);
    }
    final conf = File('$prefix/etc/apt/apt.conf.d/99ovid');
    if (!conf.existsSync() || conf.readAsStringSync() != aptConf) {
      conf.writeAsStringSync(aptConf);
    }
    File('$prefix/$layoutMarker').writeAsStringSync('$layoutVersion\n');
  }

  /// The only apt configuration Ovid adds: non-interactive conffile handling
  /// (setup has no tty to answer dpkg's prompt) and bounded network retries.
  /// Everything else is stock Termux.
  static const aptConf = '''
// Ovid sandbox (written by the app). Stock Termux apt otherwise.
Dpkg::Options { "--force-confdef"; "--force-confold"; };
Dpkg::Use-Pty "0";
APT::Get::Assume-Yes "true";
Acquire::Retries "2";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
''';

  /// Rewrite an absolute Termux symlink target from SYMLINKS.txt into a
  /// target relative to the link, so it resolves both inside proot and for
  /// the app's own (host-side) file checks. Relative targets are returned
  /// unchanged.
  static String relativeLinkTarget(String target, String linkPath) {
    const usr = '$guestPrefix/';
    if (!target.startsWith(usr)) return target;
    final to = target.substring(usr.length).split('/');
    final from = linkPath.replaceFirst(RegExp(r'^\./'), '').split('/')..removeLast();
    var common = 0;
    while (common < from.length && common < to.length - 1 && from[common] == to[common]) {
      common++;
    }
    final ups = List.filled(from.length - common, '..');
    final rel = [...ups, ...to.skip(common)].join('/');
    return rel.isEmpty ? '.' : rel;
  }

  /// Map a host path inside the prefix to its guest path (other paths are
  /// returned unchanged — they are valid inside proot as they are).
  String toGuest(String hostPath) {
    if (hostPath == prefix) return guestPrefix;
    if (hostPath.startsWith('$prefix/home/') || hostPath == home) {
      return guestHome + hostPath.substring(home.length);
    }
    if (hostPath.startsWith('$prefix/')) {
      return guestPrefix + hostPath.substring(prefix.length);
    }
    return hostPath;
  }

  /// Environment of the HOST proot process (it is a Termux binary itself:
  /// libtalloc via LD_LIBRARY_PATH, loader + temp dir via PROOT_*). No
  /// LD_PRELOAD here — termux-exec must not hook proot's own execve.
  Map<String, String> hostEnv() => {
        'LD_LIBRARY_PATH': '$prefix/lib',
        'PROOT_LOADER': loader,
        'PROOT_TMP_DIR': '$prefix/tmp',
        // Android kills ptrace-heavy trees less eagerly without the
        // seccomp filter on some kernels; proot falls back automatically.
      };

  /// Guest-side environment for a Termux login-like process.
  static Map<String, String> guestEnv() => const {
        'PREFIX': guestPrefix,
        'TERMUX__PREFIX': guestPrefix,
        'TERMUX__ROOTFS': guestFiles,
        'TERMUX_APP__PACKAGE_NAME': 'com.termux',
        'HOME': guestHome,
        'TMPDIR': '$guestPrefix/tmp',
        'PATH': '$guestPrefix/bin:/system/bin:/system/xbin',
        'SHELL': '$guestPrefix/bin/bash',
        'LANG': 'en_US.UTF-8',
        'TERM': 'xterm-256color',
        'ANDROID_DATA': '/data',
        'ANDROID_ROOT': '/system',
      };

  /// Wrap [executable] [args] so it runs inside proot. [executable] is a
  /// bare command name (resolved in `$PREFIX/bin`) or an absolute path.
  /// [cwd] is a host path (valid inside proot unchanged).
  ({String executable, List<String> arguments}) wrap(
    String executable,
    List<String> args, {
    required String cwd,
  }) {
    final exe = executable.startsWith('/') ? toGuest(executable) : '$guestPrefix/bin/$executable';
    return (
      executable: proot,
      arguments: [
        '--kill-on-exit',
        '-b', '$glue:$termuxRoot',
        '-b', '$prefix:$guestPrefix',
        '-b', '$home:$guestHome',
        '-w', cwd,
        // termux-exec maps `#!/bin/bash`, `#!/usr/bin/env node` … onto the
        // prefix, exactly as in the Termux app. Injected inside the guest
        // (via env) so it never hooks the host proot process.
        '$guestPrefix/bin/env',
        'LD_PRELOAD=$guestPrefix/$preloadRel',
        exe,
        ...args,
      ],
    );
  }

  /// `bin/ovid-shell`: a /system/bin/sh launcher that enters the same proot
  /// environment the app uses. For `adb shell run-as <app>` debugging and the
  /// emulator e2e harness (scripts/studio_e2e.sh). Not used by the app.
  String launcherScript() {
    final env = guestEnv().entries.map((e) => "${e.key}='${e.value}'").join(' ');
    return '''#!/system/bin/sh
# Ovid sandbox launcher (generated). Usage: ovid-shell [-c CMD | ARGS...]
P='$prefix'
export LD_LIBRARY_PATH="\$P/lib" PROOT_LOADER="\$P/$loaderRel" PROOT_TMP_DIR="\$P/tmp"
cd "\$P/home" 2>/dev/null || cd "\$P"
exec "\$P/$prootRel" --kill-on-exit -b "\$P/$glueDir:$termuxRoot" -b "\$P:$guestPrefix" -b "\$P/home:$guestHome" -w "\$PWD" \\
  $guestPrefix/bin/env -i $env LD_PRELOAD=$guestPrefix/$preloadRel \\
  $guestPrefix/bin/bash "\$@"
''';
  }
}
