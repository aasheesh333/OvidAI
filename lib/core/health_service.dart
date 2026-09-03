import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'state.dart';
import 'sandbox_service.dart';

/// ═══════════════════════════════════════════════════════════════════
/// DEVICE / SANDBOX HEALTH (Settings → Device health)
/// ═══════════════════════════════════════════════════════════════════
/// Real capability checks, weighted to a 0–100 score.  Every check lists
/// WHY it failed and WHAT it breaks, so the user (and the agent) can see
/// exactly which packages are missing.  Repair = re-run the apt runtime
/// installer (self-heals CA/TLS).
/// ═══════════════════════════════════════════════════════════════════

class HealthCheck {
  final String name;
  final int points;
  final bool ok;

  /// User-facing detail — for failures, the exact reason + impact.
  final String detail;

  /// Can the Repair button fix this (i.e. it's a sandbox/apt item)?
  final bool repairable;
  const HealthCheck({
    required this.name,
    required this.points,
    required this.ok,
    required this.detail,
    this.repairable = false,
  });
}

class HealthReport {
  final List<HealthCheck> checks;
  const HealthReport(this.checks);
  int get score => checks.fold<int>(0, (a, c) => a + (c.ok ? c.points : 0));
  List<HealthCheck> get failed => checks.where((c) => !c.ok).toList();
  bool get anyRepairable => failed.any((c) => c.repairable);
}

class HealthService extends ChangeNotifier {
  static final HealthService I = HealthService._();
  HealthService._();

  HealthReport? lastReport;
  bool checking = false;

  /// Run all checks and return the report.  Probes are real (sandbox
  /// exec, file writes) but fast — everything has a hard timeout.
  Future<HealthReport> runChecks() async {
    checking = true;
    notifyListeners();
    final out = <HealthCheck>[];
    final sandbox = SandboxService.I;
    final isInstalled = await sandbox.checkExisting();

    out.add(
      HealthCheck(
        name: 'Native Linux sandbox installed',
        points: 20,
        ok: isInstalled,
        detail: isInstalled
            ? 'Sandbox prefix is on-device.'
            : 'Missing — install from the Studio screen (one-time, ~320 MB). '
                  'Without it there are no bash/python/node/git tools.',
        repairable: true,
      ),
    );

    if (!isInstalled) {
      out.addAll([
        const HealthCheck(
          name: 'Native exec (bash)',
          points: 15,
          ok: false,
          detail: 'bash cannot run without the sandbox.',
          repairable: true,
        ),
        const HealthCheck(
          name: 'apt package manager',
          points: 10,
          ok: false,
          detail: 'apt unavailable without the sandbox.',
          repairable: true,
        ),
        for (final b in ['Python', 'Node.js / npm', 'git', 'curl'])
          HealthCheck(
            name: b,
            points: 10,
            ok: false,
            detail: '$b is missing — the sandbox is not installed.',
            repairable: true,
          ),
        const HealthCheck(
          name: 'Workspace storage',
          points: 10,
          ok: false,
          detail: 'Session workspace needs the sandbox app files dir.',
          repairable: true,
        ),
      ]);
    } else {
      // bash native exec
      var bashOk = false;
      var bashDetail = 'Native bionic exec works.';
      try {
        final (code, o) = await sandbox
            .execChecked(['bash', '--version'])
            .timeout(const Duration(seconds: 10));
        bashOk = code == 0;
        if (!bashOk) {
          bashDetail =
              'bash exited $code: ${o.trim().split('\n').firstOrNull ?? 'no output'}';
        }
      } catch (e) {
        bashDetail = 'bash --version failed: $e';
      }
      out.add(
        HealthCheck(
          name: 'Native exec (bash)',
          points: 15,
          ok: bashOk,
          detail: bashDetail,
          repairable: true,
        ),
      );
      // Probe the toolchain in ONE bash call.
      final probe = await sandbox.probeRuntimes();
      String miss(String b) => (probe[b] ?? false)
          ? 'Available ($b).'
          : '$b not found — apt runtime packages were never installed '
                '(likely the earlier apt certificate issue). Tap Repair.';
      out.add(
        HealthCheck(
          name: 'apt package manager',
          points: 10,
          ok: probe['bash'] == true && bashOk,
          detail: bashOk
              ? 'apt works in the sandbox (HTTPS self-heals on cert errors).'
              : 'apt needs a working bash first.',
          repairable: true,
        ),
      );
      out.add(
        HealthCheck(
          name: 'Python (+pip)',
          points: 10,
          ok: probe['python'] == true,
          detail: miss('python'),
          repairable: true,
        ),
      );
      out.add(
        HealthCheck(
          name: 'Node.js / npm (+npx)',
          points: 10,
          ok: probe['node'] == true && probe['npm'] == true,
          detail: miss('node'),
          repairable: true,
        ),
      );
      out.add(
        HealthCheck(
          name: 'git',
          points: 10,
          ok: probe['git'] == true,
          detail: miss('git'),
          repairable: true,
        ),
      );
      out.add(
        HealthCheck(
          name: 'curl / HTTPS tooling',
          points: 10,
          ok: probe['curl'] == true,
          detail: miss('curl'),
          repairable: true,
        ),
      );
      // PR38: native-Linux-parity CLI tools — same eager-install set as
      // node/python/git/curl, so a miss means the same "runtime packages
      // were never installed" story and the same Repair button fixes it.
      out.add(
        HealthCheck(
          name: 'ripgrep (rg)',
          points: 5,
          ok: probe['rg'] == true,
          detail: miss('rg'),
          repairable: true,
        ),
      );
      out.add(
        HealthCheck(
          name: 'openssh (ssh/scp/sftp)',
          points: 5,
          ok: probe['ssh'] == true,
          detail: miss('ssh'),
          repairable: true,
        ),
      );
      out.add(
        HealthCheck(
          name: 'rsync',
          points: 0,
          ok: probe['rsync'] == true,
          detail: miss('rsync'),
          repairable: true,
        ),
      );
      out.add(
        HealthCheck(
          name: 'jq',
          points: 0,
          ok: probe['jq'] == true,
          detail: miss('jq'),
          repairable: true,
        ),
      );
      out.add(
        HealthCheck(
          name: 'unzip',
          points: 0,
          ok: probe['unzip'] == true,
          detail: miss('unzip'),
          repairable: true,
        ),
      );
      out.add(
        HealthCheck(
          name: 'tmux',
          points: 0,
          ok: probe['tmux'] == true,
          detail: miss('tmux'),
          repairable: true,
        ),
      );
      // Workspace writable.
      var wsOk = false;
      var wsDetail = 'Session workspace is readable and writable.';
      try {
        final work = await sandbox.workDirFor('health-probe');
        work.createSync(recursive: true);
        final probe = File('${work.path}/write-test');
        await probe.writeAsString('ok');
        await probe.delete();
        wsOk = true;
      } catch (e) {
        wsDetail = 'Workspace dir is not writable: $e';
      }
      out.add(
        HealthCheck(
          name: 'Workspace storage',
          points: 10,
          ok: wsOk,
          detail: wsDetail,
          repairable: true,
        ),
      );

      // ── PR22: DSH-workload probes (the exact on-device failure class) ──
      // npx smoke: exercises the env shebang chain end-to-end (usr/bin/env
      // compat symlink + patched shebangs). If this passes, every npm/npx
      // shebang tool works.
      if (probe['node'] == true) {
        var npxOk = false;
        var npxDetail = 'npx shebang chain resolves (usr compat ✓).';
        try {
          final (code, o) = await sandbox
              .execChecked(['npx', '--version'])
              .timeout(const Duration(seconds: 20));
          npxOk = code == 0;
          if (!npxOk) {
            final tail = o.trim().split('\n');
            npxDetail = 'npx --version exited $code — '
                '${tail.isEmpty ? "no output" : tail.last}';
          }
        } catch (e) {
          npxDetail = 'npx failed: $e';
        }
        out.add(
          HealthCheck(
            name: 'npx / shebang chain',
            points: 0,
            ok: npxOk,
            detail: npxDetail,
            repairable: true,
          ),
        );
        // node smoke: links libz + friends at exec time — catches the
        // "library libz.so.1 not found" class without running a build.
        var nodeOk = false;
        var nodeDetail = 'node links native libs (zlib ✓).';
        try {
          final (code, o) = await sandbox
              .execChecked(['node', '-e', 'console.log(1+1)'])
              .timeout(const Duration(seconds: 20));
          nodeOk = code == 0 && o.contains('2');
          if (!nodeOk) {
            nodeDetail =
                'node smoke failed ($code) — likely a missing lib symlink '
                '(libz.so.1). Tap Repair.';
          }
        } catch (e) {
          nodeDetail = 'node failed: $e';
        }
        out.add(
          HealthCheck(
            name: 'Node native link (libz)',
            points: 0,
            ok: nodeOk,
            detail: nodeDetail,
            repairable: true,
          ),
        );
        // mkdtemp in OUR tmp: the spill/npm-cache failure class — node's
        // mkdtemp falls back to the compiled-in Termux TMPDIR without
        // the env override.
        var tmpOk = false;
        var tmpDetail = 'mkdtemp uses the sandbox TMPDIR ✓.';
        try {
          final (code, o) = await sandbox.execChecked([
            'node',
            '-e',
            "const fs=require('fs'),os=require('os');"
                "const d=fs.mkdtempSync(require('path').join(os.tmpdir(),"
                "'ovid-'));console.log(d)",
          ]).timeout(const Duration(seconds: 20));
          tmpOk = code == 0 && o.contains('/sandbox');
          if (!tmpOk) {
            tmpDetail =
                'node tmpdir points outside the sandbox (EACCES class). '
                'Tap Repair.';
          }
        } catch (e) {
          tmpDetail = 'mkdtemp probe failed: $e';
        }
        out.add(
          HealthCheck(
            name: 'TMPDIR / mkdtemp',
            points: 0,
            ok: tmpOk,
            detail: tmpDetail,
            repairable: true,
          ),
        );
      }
    }

    // Provider configured — not repairable from Health (needs the user's key).
    final hasProvider = AppState.I.providers.any(
      (p) => p.isConfigured && p.models.isNotEmpty,
    );
    out.add(
      HealthCheck(
        name: 'AI provider configured',
        points: 10,
        ok: hasProvider,
        detail: hasProvider
            ? 'At least one provider has a key + model.'
            : 'Add an API key in Settings → Providers so the agent can run.',
      ),
    );

    final report = HealthReport(out);
    lastReport = report;
    checking = false;
    notifyListeners();
    return report;
  }

  /// Run the sandbox runtime repair (apt install of node/python/git/curl)
  /// with verbose lines surfaced to the UI.  Re-runs the checks after.
  Future<HealthReport> repair(void Function(String line) onLine) async {
    final sandbox = SandboxService.I;
    // PR22: self-heal first (usr symlink, lib links, shebangs, exec bits)
    // — cheap + fixes the bad-interpreter/libz/EACCES class without a
    // full runtime reinstall.
    await sandbox.selfHealNow(onLine: onLine);
    await sandbox.installCoreRuntimes((phase, progress, line) => onLine(line));
    return runChecks();
  }
}
