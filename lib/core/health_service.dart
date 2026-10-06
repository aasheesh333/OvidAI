import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'state.dart';
import 'sandbox_service.dart';

enum HealthStatus {
  available,
  missingConfiguration,
  missing,
  denied,
  unsupported,
  failed,
}

class HealthCheck {
  final String id;
  final String name;
  final int points;
  final bool ok;
  final String detail;
  final bool repairable;
  final HealthStatus? _status;
  HealthStatus get status =>
      _status ?? (ok ? HealthStatus.available : HealthStatus.failed);
  const HealthCheck({
    this.id = '',
    required this.name,
    required this.points,
    required this.ok,
    required this.detail,
    this.repairable = false,
    HealthStatus? status,
    // Keep the public named parameter while retaining the legacy bool API.
    // ignore: prefer_initializing_formals
  }) : _status = status;
}

class HealthReport {
  final List<HealthCheck> checks;
  const HealthReport(this.checks);
  int get score =>
      checks.fold<int>(0, (a, c) => a + (c.ok ? c.points : 0)).clamp(0, 100);
  List<HealthCheck> get failed => checks.where((c) => !c.ok).toList();
  bool get anyRepairable => failed.any((c) => c.repairable);
}

class HealthRepairCancelled implements Exception {
  @override
  String toString() =>
      'Repair cancelled; completed package changes may remain. Re-run checks.';
}

/// The runtime owner must observe [whenCancelled], stop only its own work, and
/// settle the worker future AFTER that work stops. A UI timeout is not a stop.
class HealthRepairCancellation {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw HealthRepairCancelled();
  }
}

typedef HealthRepairWorker =
    Future<void> Function(
      Set<String> targets,
      HealthRepairCancellation cancellation,
      void Function(String) onLine,
    );

/// Real per-command probes. Configuration is explicitly separate from runtime
/// availability. No network inference is made from a binary's version output.
class HealthService extends ChangeNotifier {
  static final HealthService I = HealthService();
  final Future<bool> Function() _installed;
  final Future<(int, String)> Function(List<String>) _exec;
  final Future<void> Function() _workspace;
  final bool Function() _providerConfigured;
  final Duration probeTimeout;

  /// Injectable worker. Production construction binds the signed, target-scoped
  /// command below; probe-only injected services never acquire a live installer.
  HealthRepairWorker? repairWorker;
  factory HealthService({
    Future<bool> Function()? installed,
    Future<(int, String)> Function(List<String>)? exec,
    Future<void> Function()? workspace,
    bool Function()? providerConfigured,
    HealthRepairWorker? repairWorker,
    Duration probeTimeout = const Duration(seconds: 10),
  }) => HealthService._(
    installed: installed,
    exec: exec,
    workspace: workspace,
    providerConfigured: providerConfigured,
    repairWorker:
        repairWorker ??
        (installed == null && exec == null && workspace == null
            ? _repairPackages
            : null),
    probeTimeout: probeTimeout,
  );

  HealthService._({
    Future<bool> Function()? installed,
    Future<(int, String)> Function(List<String>)? exec,
    Future<void> Function()? workspace,
    bool Function()? providerConfigured,
    this.repairWorker,
    required this.probeTimeout,
  }) : _installed = installed ?? SandboxService.I.checkExisting,
       _exec = exec ?? _sandboxExec,
       _workspace = workspace ?? _probeWorkspace,
       _providerConfigured =
           providerConfigured ??
           (() => AppState.I.providers.any(
             (p) => p.isConfigured && p.models.isNotEmpty,
           ));

  // Only package-backed checks supported by the signed installer. Base sandbox
  // recovery (bash/apt), storage and provider configuration have other owners.
  static const _repairPackagesByTarget = {
    'python': 'python',
    'pip': 'python-pip',
    'node': 'nodejs',
    'npm': 'npm',
    'npx': 'npm',
    'git': 'git',
    'curl': 'curl',
    'rg': 'ripgrep',
    'ssh': 'openssh',
    'rsync': 'rsync',
    'jq': 'jq',
    'unzip': 'unzip',
    'tmux': 'tmux',
  };
  static int _repairSequence = 0;

  static Future<void> _repairPackages(
    Set<String> targets,
    HealthRepairCancellation cancellation,
    void Function(String) onLine,
  ) async {
    cancellation.throwIfCancelled();
    if (targets.isEmpty ||
        targets.any((id) => !_repairPackagesByTarget.containsKey(id))) {
      throw UnsupportedError('No targeted package repair for this selection.');
    }
    final packages =
        targets.map((id) => _repairPackagesByTarget[id]!).toSet().toList()
          ..sort();
    final sandbox = SandboxService.I;
    final key = 'health-repair-${++_repairSequence}';
    final settled = Completer<void>();
    var timedOut = false;
    Timer? deadline;
    // Detach this callback on completion, so a later cancellation never kills
    // another operation. Never cancelInstall/killAllProcesses: those are shared.
    unawaited(
      Future.any([cancellation.whenCancelled, settled.future]).then((_) {
        if (!settled.isCompleted && cancellation.isCancelled) {
          sandbox.killCallProcesses(key);
        }
      }),
    );
    try {
      await runZoned(
        () => sandbox.withProcessScope(
          () async {
            onLine('Repairing signed packages: ${packages.join(', ')}');
            cancellation.throwIfCancelled();
            deadline = Timer(const Duration(minutes: 12), () {
              timedOut = true;
              sandbox.killCallProcesses(key);
            });
            // install verifies/fetches its signed index and resolves dependencies.
            // One command retains the installer's own lock for the whole operation.
            // Await the producer even after cancellation/timeout; no abandoned work
            // may race a retry. execChecked settles after exit and stream draining.
            final (code, _) = await sandbox.execChecked([
              'ovid-pkg',
              'install',
              ...packages,
            ]);
            cancellation.throwIfCancelled();
            if (timedOut) {
              throw TimeoutException('Signed package repair timed out.');
            }
            if (code != 0) {
              throw StateError('Signed package repair failed (exit $code).');
            }
            onLine('Package command completed; verifying executable checks.');
          },
          runKey: key,
          callKey: key,
        ),
        zoneValues: {SandboxService.callZoneKey: key},
      );
    } on SandboxCancelledException {
      if (timedOut && !cancellation.isCancelled) {
        throw TimeoutException('Signed package repair timed out.');
      }
      throw HealthRepairCancelled();
    } catch (_) {
      cancellation.throwIfCancelled();
      if (timedOut) throw TimeoutException('Signed package repair timed out.');
      rethrow;
    } finally {
      deadline?.cancel();
      settled.complete();
    }
  }

  static Future<(int, String)> _sandboxExec(List<String> args) async {
    final key = 'health-${DateTime.now().microsecondsSinceEpoch}-${args.first}';
    try {
      return await runZoned(
        () => SandboxService.I.execChecked(args),
        zoneValues: {SandboxService.callZoneKey: key},
      ).timeout(const Duration(seconds: 10));
    } finally {
      SandboxService.I.killCallProcesses(key);
    }
  }

  static Future<void> _probeWorkspace() async {
    final work = await SandboxService.I.workDirFor('health-probe');
    await work.create(recursive: true);
    final temp = await work.createTemp('probe-');
    try {
      await File('${temp.path}/write-test').writeAsString('ok', flush: true);
    } finally {
      await temp.delete(recursive: true);
    }
  }

  HealthReport? lastReport;
  bool checking = false;
  bool repairing = false;
  Future<HealthReport>? _checks;
  HealthRepairCancellation? _repairCancellation;
  bool get cancellationRequested => _repairCancellation?.isCancelled ?? false;

  Future<HealthReport> runChecks() =>
      _checks ??= _runChecks().whenComplete(() => _checks = null);

  static HealthStatus _failure(String detail, [int? code]) {
    final text = detail.toLowerCase();
    if (text.contains('permission denied') ||
        text.contains('operation not permitted')) {
      return HealthStatus.denied;
    }
    if (text.contains('exec format') ||
        text.contains('unsupported abi') ||
        text.contains('wrong elf')) {
      return HealthStatus.unsupported;
    }
    if (code == 127 ||
        text.contains('no such file') ||
        text.contains('not found')) {
      return HealthStatus.missing;
    }
    return HealthStatus.failed;
  }

  Future<HealthReport> _runChecks() async {
    checking = true;
    notifyListeners();
    final out = <HealthCheck>[];
    try {
      var installed = false;
      var installDetail = 'Missing — open Studio to install the sandbox.';
      var installStatus = HealthStatus.missing;
      try {
        installed = await _installed().timeout(probeTimeout);
        if (installed) {
          installDetail =
              'Sandbox prefix exists; runtime commands checked separately.';
        }
      } catch (e) {
        installDetail = 'Sandbox check failed: $e';
        installStatus = _failure('$e');
      }
      out.add(
        HealthCheck(
          id: 'sandbox',
          name: 'Native Linux sandbox installed',
          points: 20,
          ok: installed,
          detail: installDetail,
          status: installed ? HealthStatus.available : installStatus,
        ),
      );
      const commands = <(String, String, int, List<String>)>[
        ('bash', 'Native exec (bash)', 15, ['bash', '--version']),
        ('apt', 'apt package manager', 10, ['apt', '--version']),
        ('python', 'Python', 10, ['python', '--version']),
        ('pip', 'Python pip', 0, ['python', '-m', 'pip', '--version']),
        ('node', 'Node.js', 5, ['node', '--version']),
        ('npm', 'npm', 5, ['npm', '--version']),
        ('npx', 'npx / shebang chain', 0, ['npx', '--version']),
        ('git', 'git', 5, ['git', '--version']),
        ('curl', 'curl / HTTPS tooling', 5, ['curl', '--version']),
        ('rg', 'ripgrep (rg)', 0, ['rg', '--version']),
        ('ssh', 'OpenSSH', 0, ['ssh', '-V']),
        ('rsync', 'rsync', 0, ['rsync', '--version']),
        ('jq', 'jq', 0, ['jq', '--version']),
        ('unzip', 'unzip', 0, ['unzip', '-v']),
        ('tmux', 'tmux', 0, ['tmux', '-V']),
      ];
      for (final (id, name, points, args) in commands) {
        var ok = false;
        var status = HealthStatus.missing;
        var detail = 'Unavailable without the sandbox. Open Studio to install.';
        if (installed) {
          try {
            final (code, output) = await _exec(args).timeout(probeTimeout);
            ok = code == 0;
            status = ok ? HealthStatus.available : _failure(output, code);
            detail = ok
                ? '${args.join(' ')} succeeded. Network access is not tested.'
                : '${status.name}: ${args.join(' ')} exited $code. ${output.trim()}';
          } catch (e) {
            status = _failure('$e');
            detail = '${status.name}: $e';
          }
        }
        if (detail.length > 600) detail = '${detail.substring(0, 600)}…';
        out.add(
          HealthCheck(
            id: id,
            name: name,
            points: points,
            ok: ok,
            detail: detail,
            status: status,
            repairable:
                installed &&
                _repairPackagesByTarget.containsKey(id) &&
                !ok &&
                status != HealthStatus.denied &&
                status != HealthStatus.unsupported,
          ),
        );
      }
      var writable = false;
      var storageDetail = 'Unavailable without the sandbox.';
      var storageStatus = HealthStatus.missing;
      if (installed) {
        try {
          await _workspace().timeout(probeTimeout);
          writable = true;
          storageStatus = HealthStatus.available;
          storageDetail = 'Temporary workspace file written and removed.';
        } catch (e) {
          storageStatus = _failure('$e');
          storageDetail = 'Workspace probe failed: $e';
        }
      }
      out.add(
        HealthCheck(
          id: 'workspace',
          name: 'Workspace storage',
          points: 10,
          ok: writable,
          detail: storageDetail,
          status: storageStatus,
        ),
      );
      final configured = _providerConfigured();
      out.add(
        HealthCheck(
          id: 'provider',
          name: 'AI provider configuration',
          points: 15,
          ok: configured,
          status: configured
              ? HealthStatus.available
              : HealthStatus.missingConfiguration,
          detail: configured
              ? 'A provider and model are configured; credentials and reachability are not tested.'
              : 'Missing configuration — choose a provider and model in Settings → Providers.',
        ),
      );
      return lastReport = HealthReport(List.unmodifiable(out));
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  void cancelRepair() {
    _repairCancellation?.cancel();
    notifyListeners();
  }

  Future<HealthReport> repair(
    void Function(String) onLine, {
    Set<String>? targets,
  }) async {
    if (repairing) throw StateError('A repair is already running.');
    final worker = repairWorker;
    if (worker == null) {
      throw UnsupportedError(
        'Targeted repair worker unavailable in this build. No repair was started.',
      );
    }
    final cancellation = HealthRepairCancellation();
    _repairCancellation = cancellation;
    repairing = true;
    notifyListeners();
    try {
      final report = await runChecks();
      cancellation.throwIfCancelled();
      final allowed = report.failed
          .where((c) => c.repairable)
          .map((c) => c.id)
          .toSet();
      final selected = Set<String>.of(targets ?? allowed);
      if (selected.isEmpty || !allowed.containsAll(selected)) {
        throw StateError('Select a failed, repairable runtime.');
      }
      await worker(Set.unmodifiable(selected), cancellation, (line) {
        if (!cancellation.isCancelled) onLine(line);
      });
      cancellation.throwIfCancelled();
      // A UI refresh begun during installation can still contain pre-install
      // results. Let that producer settle before starting verification anew.
      final inFlightChecks = _checks;
      if (inFlightChecks != null) await inFlightChecks;
      cancellation.throwIfCancelled();
      final after = await runChecks();
      cancellation.throwIfCancelled();
      if (after.failed.any((c) => selected.contains(c.id))) {
        throw StateError(
          'Repair incomplete; selected runtime checks still fail.',
        );
      }
      return after;
    } finally {
      repairing = false;
      _repairCancellation = null;
      notifyListeners();
    }
  }
}
