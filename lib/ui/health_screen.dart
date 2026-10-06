import 'package:flutter/material.dart';

import '../core/health_service.dart';
import '../core/sandbox_service.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'sandbox_setup.dart';
import 'settings_action_widgets.dart';
import 'widgets/aether_primitives.dart';

/// Device health — the ONE health surface.
///
/// The two former health screens (`HealthScreen` and the settings-only
/// `SettingsHealthScreen`) are merged here:
///   * 0–100 capability score ring with a plain-language summary;
///   * per-runtime check breakdown;
///   * TARGETED repair — tick the failed, repairable runtimes and fix just
///     those via the signed, cancellable worker;
///   * MCP/plugin service status with per-service retry;
///   * the destructive sandbox hard reset tucked behind an Advanced
///     disclosure so it is never one accidental tap away.
///
/// All runtime wiring is preserved verbatim from both predecessors:
/// [HealthService.runChecks] on open, targeted [HealthService.repair] with
/// the dispose-time `cancelRepair` guard, and the PR47/K6 hard reset via
/// [SandboxService.I.uninstall] + the setup gate. `SettingsHealthScreen`
/// remains as a source-compatible alias in `settings_health_screen.dart`.
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
  final Set<String> _selected = {};
  bool _repairing = false;
  bool _resetting = false;
  String? _checkError;
  String? _result;

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

  bool get _busy =>
      _repairing || _resetting || _health.repairing || _health.checking;

  Future<void> _runChecks() async {
    if (_busy) return;
    setState(() {
      _checkError = null;
      _result = null;
    });
    try {
      final report = await _health.runChecks();
      if (mounted) {
        // Keep only the still-relevant selections: failed AND repairable.
        setState(() => _selected.retainAll(
          report.failed.where((c) => c.repairable).map((c) => c.id),
        ));
      }
    } catch (e) {
      if (mounted) setState(() => _checkError = 'Health checks failed: $e');
    }
  }

  @override
  void dispose() {
    if (_repairing && _health.repairing) _health.cancelRepair();
    super.dispose();
  }

  /// Targeted repair — fixes only the failed, repairable runtimes the user
  /// ticked, via the signed cancellable worker.
  Future<void> _runRepair() async {
    if (_busy || _selected.isEmpty) return;
    setState(() {
      _repairing = true;
      _result = null;
      _repairLog.clear();
    });
    try {
      await _health.repair((l) {
        if (!mounted) return;
        setState(() {
          _repairLog.add(l);
          if (_repairLog.length > 100) _repairLog.removeAt(0);
        });
      }, targets: Set.of(_selected));
      if (mounted) {
        setState(() {
          _result = 'Selected runtime checks now pass.';
          _selected.clear();
        });
      }
    } catch (e) {
      if (mounted) setState(() => _result = '$e');
    } finally {
      if (mounted) setState(() => _repairing = false);
    }
  }

  void _toggle(String id, bool value) {
    setState(() {
      if (value) {
        _selected.add(id);
      } else {
        _selected.remove(id);
      }
    });
  }

  /// PR47/K6: hard reset — delete the whole sandbox prefix + reinstall from
  /// the bundled bootstrap in the SHELL (SandboxSetupScreen drives its own
  /// progress). Points the user at a healthy state even when self-heal
  /// saturates on older/corrupt installs.
  Future<void> _hardResetSandbox() async {
    if (_busy) return;
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
    final busy = _busy;
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

        // ── Runtime health (per-check breakdown + targeted repair) ──
        const SizedBox(height: 20),
        const AetherSectionTitle(
          eyebrow: 'Runtime health',
          subtitle: 'Version and configuration probes do not verify network access or every tool operation.',
        ),
        const SizedBox(height: 12),
        if (_health.repairWorker == null)
          const _NoWorkerCard()
        else
          _RepairControls(
            busy: busy,
            repairing: _health.repairing,
            cancellationRequested: _health.cancellationRequested,
            canRepair: !checking && _selected.isNotEmpty,
            onRepair: _runRepair,
            onCancel: _health.cancelRepair,
          ),
        if (_result != null) ...[
          const SizedBox(height: 12),
          _ResultCard(message: _result!),
        ],
        const SizedBox(height: 12),
        for (final c in report.checks) ...[
          _HealthCheckCard(
            check: c,
            selectable: c.repairable && _health.repairWorker != null,
            selected: _selected.contains(c.id),
            onChanged: busy ? null : _toggle,
          ),
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

        // ── Re-run + destructive recovery (behind Advanced) ──
        const SizedBox(height: 12),
        SettingsActionButton(
          label: 'Re-run checks',
          icon: Icons.refresh,
          onPressed: busy ? null : _runChecks,
        ),
        const SizedBox(height: 20),
        _AdvancedCard(
          resetting: _resetting,
          onReset: busy ? null : _hardResetSandbox,
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

class _NoWorkerCard extends StatelessWidget {
  const _NoWorkerCard();
  @override
  Widget build(BuildContext context) {
    return AetherCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 20, color: Aether.textFaint),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Targeted repair unavailable in this build: no cancellable runtime worker is connected. Open Studio for installation options.',
              style: AetherType.bodyMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _RepairControls extends StatelessWidget {
  final bool busy;
  final bool repairing;
  final bool cancellationRequested;
  final bool canRepair;
  final VoidCallback onRepair;
  final VoidCallback onCancel;
  const _RepairControls({
    required this.busy,
    required this.repairing,
    required this.cancellationRequested,
    required this.canRepair,
    required this.onRepair,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return AetherCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  busy
                      ? 'Repair in progress'
                      : (canRepair
                          ? 'Ready to repair'
                          : 'Select runtimes to repair'),
                  style: AetherType.title,
                ),
                const SizedBox(height: 2),
                Text(
                  canRepair
                      ? 'Only failed, repairable runtimes can be selected.'
                      : 'Tick a failed runtime below to enable repair.',
                  style: AetherType.caption,
                ),
              ],
          ),
          const SizedBox(height: 12),
          if (repairing)
            SettingsActionButton(
              label: cancellationRequested
                  ? 'Waiting for worker to stop…'
                  : 'Cancel repair',
              onPressed: cancellationRequested ? null : onCancel,
            )
          else
            SettingsActionButton(
              label: 'Repair selected runtimes',
              icon: Icons.build_outlined,
              primary: true,
              onPressed: busy || !canRepair ? null : onRepair,
            ),
          // NOTE: no indeterminate progress bar here — a perpetual animation
          // would keep pumpAndSettle alive forever in the cancellation
          // flows; the cancel/waiting label already carries the busy state.
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final String message;
  const _ResultCard({required this.message});
  @override
  Widget build(BuildContext context) {
    return AetherCard(
      padding: const EdgeInsets.all(14),
      child: Semantics(
        liveRegion: true,
        child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: Aether.textFaint),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: AetherType.bodyMuted)),
        ],
        ),
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
  final bool selectable;
  final bool selected;
  final void Function(String id, bool value)? onChanged;
  const _HealthCheckCard({
    required this.check,
    required this.selectable,
    required this.selected,
    required this.onChanged,
  });

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
          if (selectable) ...[
            const SizedBox(width: 8),
            Semantics(
              label: 'Select ${check.name} for repair',
              child: Checkbox(
              value: selected,
              onChanged: onChanged == null
                  ? null
                  : (v) => onChanged!(check.id, v == true),
              ),
            ),
          ],
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

/// Advanced disclosure — the destructive sandbox recovery lives here so the
/// primary health surface stays calm. Expanded on demand only.
class _AdvancedCard extends StatelessWidget {
  final bool resetting;
  final VoidCallback? onReset;
  const _AdvancedCard({
    required this.resetting,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    // PR47/K6: Hard reset — a broken sandbox (bad clone, stuck stale state,
    // orphaned apt processes) wants a full wipe and re-extraction. Deleting
    // the whole prefix and re-running the setup gate is the only honest way
    // to prove the ground.
    return AetherCard(
      padding: EdgeInsets.zero,
      child: Theme(
        // ExpansionTile paints hairlines above/below when expanded; the card
        // border already carries the separation, so keep it calm.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          title: const Text(
            'Advanced',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            'Destructive recovery actions',
            style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Wipes the Linux sandbox and reinstalls it from the bundled '
                'bootstrap. Chats and settings are untouched.',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: Aether.textFaint,
                ),
              ),
            ),
            const SizedBox(height: 12),
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
      ),
    );
  }
}
