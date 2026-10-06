import 'package:flutter/material.dart';

import '../core/health_service.dart';
import '../core/sandbox_service.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'sandbox_setup.dart';
import 'settings_action_widgets.dart';
import 'widgets/aether_primitives.dart';

/// Device health — a 0–100 capability score with a per-item breakdown of
/// exactly what's missing and why. Repair uses the signed runtime worker.
///
/// REDESIGN (wave 2 UI): the premium Aether primitives from
/// `lib/ui/widgets/aether_primitives.dart` carry the layout; runtime wiring
/// to [HealthService.I] and the hard-reset path to [SandboxService.I] is
/// preserved verbatim (no new logic, no owner contract changes).
class HealthScreen extends StatefulWidget {
  /// Optional service injection seam for widget tests. Production code
  /// defaults to the global [HealthService.I] singleton — the runtime
  /// probe wiring is unchanged.
  final HealthService? service;
  const HealthScreen({super.key, this.service});
  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> {
  late final HealthService _health = widget.service ?? HealthService.I;
  final List<String> _repairLog = [];
  bool _repairing = false;
  bool _resetting = false;
  String? _checkError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Guard against the post-frame callback firing after the widget has
      // been disposed (e.g. the gate immediately popped by a parent route).
      // HealthService is the source of truth and is safe to invoke, but we
      // skip to avoid racing a cancelled probe against a torn-down state.
      if (!mounted) return;
      _runChecks();
    });
  }

  Future<void> _runChecks() async {
    if (_repairing || _resetting || _health.repairing || _health.checking) return;
    setState(() => _checkError = null);
    try {
      await _health.runChecks();
    } catch (e) {
      if (mounted) setState(() => _checkError = 'Health checks failed: $e');
    }
  }

  @override
  void dispose() {
    if (_repairing && _health.repairing) _health.cancelRepair();
    super.dispose();
  }

  /// PR47/K6: hard reset — delete the whole sandbox prefix + reinstall from
  /// the bundled bootstrap in the SHELL (SandboxSetupScreen drives its own
  /// progress). Points the user at a healthy state even when self-heal
  /// saturates on older/corrupt installs.
  Future<void> _hardResetSandbox() async {
    if (_resetting || _repairing || _health.repairing || _health.checking) return;
    setState(() => _resetting = true);
    _repairLog.add('ovid: deleting sandbox prefix…');
    setState(() {});
    try {
      await SandboxService.I.uninstall();
      if (!mounted) return;
      _repairLog.add('ovid: deleted — reopening setup gate…');
      setState(() {});
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const SandboxSetupScreen(gateMode: true),
        ),
      );
      // Back from the gate — the sandbox should be installed again. Skip
      // re-probing if this screen has been disposed while the gate was up.
      if (!mounted) return;
      await _health.runChecks();
    } catch (e) {
      _repairLog.add('ovid: reset failed: $e');
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  Color _scoreColor(int s) => s >= 90
      ? Aether.successLight
      : s >= 70
      ? Aether.accent
      : s >= 45
      ? Aether.warnLight
      : Aether.dangerC;

  String _scoreLabel(int s) => s >= 90
      ? 'Most scored checks pass. Review each result below.'
      : s >= 70
      ? 'Some capabilities are unavailable.'
      : s >= 45
      ? 'Several capability checks need attention.'
      : 'Many capability checks are unavailable.';

  Future<void> _runRepair() async {
    if (_repairing || _resetting || _health.repairing || _health.checking) return;
    setState(() {
      _repairing = true;
      _repairLog.clear();
    });
    try {
      await _health.repair((l) {
        if (!mounted) return;
        setState(() {
          _repairLog.add(l);
          if (_repairLog.length > 100) _repairLog.removeAt(0);
        });
      });
    } catch (e) {
      if (mounted) {
        setState(() => _repairLog.add('repair failed: $e'));
      }
    } finally {
      if (mounted) {
        setState(() => _repairing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Device health'),
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([_health, AppState.I]),
        builder: (_, _) {
          final report = _health.lastReport;
          final checking = _health.checking;
          if (_checkError != null && report == null) {
            return ListView(padding: const EdgeInsets.all(24), children: [
              Text(_checkError!, style: AetherType.body),
              const SizedBox(height: 12),
              SettingsActionButton(label: 'Re-run checks', onPressed: _runChecks),
            ]);
          }
          if (report == null) {
            return const _ProbingState();
          }
          return _buildBody(context, report, checking);
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, HealthReport report, bool checking) {
    final score = report.score;
    final color = _scoreColor(score);
    final services = AppState.I.serviceStatus;
    final busy = _repairing || _resetting || _health.repairing || checking;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        if (checking) const LinearProgressIndicator(semanticsLabel: 'Checking device health'),
        if (_checkError != null) ...[
          Text(_checkError!, style: AetherType.body),
          const SizedBox(height: 12),
        ],
        // ── Overall summary ──
        _ScoreSummaryCard(
          score: score,
          color: color,
          label: _scoreLabel(score),
          totalChecks: report.checks.length,
          failedChecks: report.failed.length,
        ),

        // ── Runtime health (per-check breakdown) ──
        const SizedBox(height: 20),
        const AetherSectionTitle(
          eyebrow: 'Runtime health',
          subtitle: 'Version and configuration probes do not verify network access or every tool operation.',
        ),
        const SizedBox(height: 12),
        if (report.anyRepairable && _health.repairWorker != null) ...[
          _RepairBanner(
            color: color,
            repairing: _repairing || _health.repairing,
            onRepair: busy ? null : _runRepair,
          ),
          const SizedBox(height: 12),
        ],
        if (_health.repairing) ...[
          SettingsActionButton(
            label: _health.cancellationRequested ? 'Waiting for worker to stop…' : 'Cancel repair',
            onPressed: _health.cancellationRequested ? null : _health.cancelRepair,
          ),
          const SizedBox(height: 12),
        ],
        if (report.anyRepairable && _health.repairWorker == null)
          Text('Targeted repair unavailable: no runtime worker is connected.', style: AetherType.bodyMuted),
        for (final c in report.checks) ...[
          _HealthCheckCard(check: c),
          const SizedBox(height: 8),
        ],

        if (_repairLog.isNotEmpty) ...[
          const SizedBox(height: 4),
          _RepairLogCard(lines: _repairLog),
        ],

        // ── Services (MCP & plugins) ──
        if (services.isNotEmpty) ...[
          const SizedBox(height: 20),
          AetherSectionTitle(
            eyebrow: 'Services',
            subtitle:
                '${services.values.where((s) => s.health == ServiceHealth.working).length} of ${services.length} working',
          ),
          const SizedBox(height: 12),
          for (final entry in services.entries) ...[
            _ServiceCard(
              name: entry.key,
              status: entry.value,
              onRetry: busy ? null : _runChecks,
            ),
            const SizedBox(height: 8),
          ],
        ],

        // ── Danger / reset / re-run ──
        const SizedBox(height: 20),
        _DangerActionsCard(
          resetting: _resetting,
          onReset: busy ? null : _hardResetSandbox,
          onReRun: busy ? null : _runChecks,
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Internal premium building blocks
// ──────────────────────────────────────────────────────────────────────────

class _ProbingState extends StatelessWidget {
  const _ProbingState();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Aether.accent,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Probing device capabilities…',
              style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _ScoreSummaryCard extends StatelessWidget {
  final int score;
  final Color color;
  final String label;
  final int totalChecks;
  final int failedChecks;
  const _ScoreSummaryCard({
    required this.score,
    required this.color,
    required this.label,
    required this.totalChecks,
    required this.failedChecks,
  });

  @override
  Widget build(BuildContext context) {
    return AetherCard(
      title: const Text('Overall health'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 78 * (MediaQuery.textScalerOf(context).scale(24) / 24),
            height: 78 * (MediaQuery.textScalerOf(context).scale(24) / 24),
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: score / 100,
                    strokeWidth: 6,
                    strokeCap: StrokeCap.round,
                    backgroundColor: Aether.hairline,
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$score',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: color,
                        height: 1,
                      ),
                    ),
                    Text(
                      'of 100',
                      style: TextStyle(
                        fontSize: 9.5,
                        color: Aether.textFaint,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: AetherType.title,
                ),
                const SizedBox(height: 6),
                Text(
                  '$failedChecks of $totalChecks check(s) failing',
                  style: AetherType.caption,
                ),
              ],
          ),
        ],
      ),
    );
  }
}

class _RepairBanner extends StatelessWidget {
  final Color color;
  final bool repairing;
  final VoidCallback? onRepair;
  const _RepairBanner({
    required this.color,
    required this.repairing,
    required this.onRepair,
  });

  @override
  Widget build(BuildContext context) {
    return AetherCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(
            Icons.build_circle_outlined,
            size: 20,
            color: color,
          ),
          const SizedBox(height: 12),
          Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  repairing
                      ? 'Repair in progress'
                      : 'Repair available',
                  style: AetherType.title,
                ),
                const SizedBox(height: 2),
                Text(
                  repairing
                      ? 'Installing signed packages and re-running executable checks…'
                      : 'Repair failed, supported runtimes using signed packages.',
                  style: AetherType.caption,
                ),
              ],
          ),
          const SizedBox(height: 12),
          SettingsActionButton(
            label: repairing ? 'Repairing…' : 'Repair',
            icon: Icons.build_outlined,
            primary: true,
            onPressed: onRepair,
          ),
          if (repairing) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(semanticsLabel: 'Runtime repair in progress'),
          ],
        ],
      ),
    );
  }
}

class _RepairLogCard extends StatelessWidget {
  final List<String> lines;
  const _RepairLogCard({required this.lines});
  @override
  Widget build(BuildContext context) {
    return AetherCard(
      title: const Text('Repair log'),
      padding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 180),
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final l in lines.reversed.toList())
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  l,
                  style: TextStyle(
                    fontFamily: Aether.mono,
                    fontSize: 11,
                    height: 1.5,
                    color: Aether.textMuted,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HealthCheckCard extends StatelessWidget {
  final HealthCheck check;
  const _HealthCheckCard({required this.check});

  Color get _dotColor {
    if (check.ok) return Aether.success;
    switch (check.status) {
      case HealthStatus.denied:
      case HealthStatus.unsupported:
      case HealthStatus.failed:
        return Aether.danger;
      case HealthStatus.missing:
      case HealthStatus.missingConfiguration:
        return Aether.warn;
      case HealthStatus.available:
        return Aether.success;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AetherCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: AetherStatusDot(color: _dotColor, size: 10),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        check.name,
                        style: AetherType.title,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '+${check.points}',
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: Aether.mono,
                        color: check.ok
                            ? Aether.successLight
                            : Aether.textFaint,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  check.detail,
                  style: AetherType.caption.copyWith(
                    color: check.ok ? Aether.textFaint : Aether.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  final String name;
  final ServiceStatus status;
  final VoidCallback? onRetry;
  const _ServiceCard({
    required this.name,
    required this.status,
    required this.onRetry,
  });

  Color get _dotColor {
    switch (status.health) {
      case ServiceHealth.working:
        return Aether.success;
      case ServiceHealth.connecting:
        return Aether.warn;
      case ServiceHealth.failed:
        return Aether.danger;
    }
  }

  String get _lastCheckCaption {
    final detail = status.detail.trim();
    final t = status.updatedAt;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final time = 'last check $hh:$mm';
    if (detail.isEmpty) return time;
    return '$time · $detail';
  }

  @override
  Widget build(BuildContext context) {
    final connecting = status.health == ServiceHealth.connecting;
    return AetherCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: connecting
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Aether.accent,
                    ),
                  )
                : AetherStatusDot(
                    color: _dotColor,
                    size: 10,
                    // REDESIGN (wave 2 UI): pulsing on failed services kept
                    // the ticker alive forever and broke pumpAndSettle in the
                    // widget tests. The red tint + 'Retry' CTA now carry the
                    // "needs attention" affordance on their own.
                    pulsing: false,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name, style: AetherType.title),
                const SizedBox(height: 2),
                Text(
                  _lastCheckCaption,
                  style: AetherType.caption,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          AetherGhostButton(
            label: 'Retry',
            onPressed: connecting ? null : onRetry,
          ),
        ],
      ),
    );
  }
}

class _DangerActionsCard extends StatelessWidget {
  final bool resetting;
  final VoidCallback? onReset;
  final VoidCallback? onReRun;
  const _DangerActionsCard({
    required this.resetting,
    required this.onReset,
    required this.onReRun,
  });

  @override
  Widget build(BuildContext context) {
    // PR47/K6: Hard reset — a broken sandbox (bad clone, stuck stale state,
    // orphaned apt processes) wants a full wipe and re-extraction. Deleting
    // the whole prefix and re-running the setup gate is the only honest way
    // to prove the ground.
    return AetherCard(
      title: const Text('Diagnostics'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsActionButton(
            label: 'Re-run checks',
            icon: Icons.refresh,
            onPressed: onReRun,
          ),
          const SizedBox(height: 10),
          SettingsActionButton(
            label: resetting
                ? 'Resetting sandbox…'
                : 'Hard reset the sandbox',
            icon: Icons.delete_sweep_outlined,
            danger: true,
            onPressed: onReset,
          ),
        ],
      ),
    );
  }
}
