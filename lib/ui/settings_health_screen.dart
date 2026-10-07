import 'package:flutter/material.dart';
import '../core/health_service.dart';
import '../core/theme.dart';
import 'settings_action_widgets.dart';
import 'widgets/aether_primitives.dart';

/// Settings-only health consumer. Uses the existing service's per-runtime
/// results without borrowing the global sandbox uninstall/install controls.
///
/// REDESIGN (wave 2 UI): premium Aether primitives from
/// `lib/ui/widgets/aether_primitives.dart` carry the layout. All runtime
/// wiring — [HealthService.runChecks], [HealthService.repair], the
/// per-check `repairable` targeting set, the cancellable repair worker,
/// and the dispose-time `cancelRepair` guard — is preserved verbatim.
class SettingsHealthScreen extends StatefulWidget {
  final HealthService? service;
  const SettingsHealthScreen({super.key, this.service});
  @override
  State<SettingsHealthScreen> createState() => _SettingsHealthScreenState();
}

class _SettingsHealthScreenState extends State<SettingsHealthScreen> {
  late final HealthService _health = widget.service ?? HealthService.I;
  final List<String> _log = [];
  final Set<String> _selected = {};
  bool _starting = false;
  String? _result;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (_starting || _health.repairing || _health.checking) return;
    setState(() {
      _result = null;
      _log.clear();
    });
    try {
      final report = await _health.runChecks();
      if (mounted) {
        setState(() => _selected.retainAll(
          report.failed.where((c) => c.repairable).map((c) => c.id),
        ));
      }
    } catch (_) {
      if (mounted) setState(() => _result = 'Health checks failed. Retry.');
    }
  }

  @override
  void dispose() {
    if (_starting && _health.repairing) _health.cancelRepair();
    super.dispose();
  }

  Future<void> _repair() async {
    if (_starting || _health.repairing || _health.checking || _selected.isEmpty) return;
    setState(() {
      _starting = true;
      _result = null;
      _log.clear();
    });
    try {
      await _health.repair((line) {
        if (mounted) {
          setState(() {
            _log.add(line);
            if (_log.length > 100) _log.removeAt(0);
          });
        }
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
      if (mounted) setState(() => _starting = false);
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

  Color _scoreColor(int s) => s >= 90
      ? Aether.successLight
      : s >= 70
      ? Aether.accent
      : s >= 45
      ? Aether.warnLight
      : Aether.dangerC;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(title: const Text('Device health')),
      body: AnimatedBuilder(
        animation: _health,
        builder: (_, _) {
          final report = _health.lastReport;
          final busy = _starting || _health.repairing;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
            children: [
              // ── Overall summary ──
              if (report != null)
                _ScoreSummaryCard(
                  score: report.score,
                  color: _scoreColor(report.score),
                  totalChecks: report.checks.length,
                  failedChecks: report.failed.length,
                ),
              if (_health.checking) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],

              // ── Runtime health ──
              const SizedBox(height: 20),
              const AetherSectionTitle(
                eyebrow: 'Runtime health',
                subtitle:
                    'A passing version probe is not proof of network access or every tool operation.',
              ),
              const SizedBox(height: 12),

              if (_health.repairWorker == null)
                _NoWorkerCard()
              else ...[
                _RepairControls(
                  busy: busy,
                  repairing: _health.repairing,
                  cancellationRequested: _health.cancellationRequested,
                   canRepair: !_health.checking && _selected.isNotEmpty,
                  onRepair: _repair,
                  onCancel: _health.cancelRepair,
                ),
                const SizedBox(height: 12),
              ],

              if (_result != null) ...[
                _ResultCard(message: _result!),
                const SizedBox(height: 12),
              ],

              for (final check in report?.checks ?? <HealthCheck>[]) ...[
                _HealthCheckCard(
                  check: check,
                  selectable:
                      check.repairable && _health.repairWorker != null,
                  selected: _selected.contains(check.id),
                   onChanged: busy || _health.checking ? null : _toggle,
                ),
                const SizedBox(height: 8),
              ],

              if (_log.isNotEmpty) ...[
                const SizedBox(height: 4),
                _RepairLogCard(lines: _log),
                const SizedBox(height: 12),
              ],

              const SizedBox(height: 8),
              SettingsActionButton(
                label: 'Re-run checks',
                icon: Icons.refresh,
                onPressed: busy || _health.checking ? null : _check,
              ),
            ],
          );
        },
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Internal premium building blocks
// ──────────────────────────────────────────────────────────────────────────

class _ScoreSummaryCard extends StatelessWidget {
  final int score;
  final Color color;
  final int totalChecks;
  final int failedChecks;
  const _ScoreSummaryCard({
    required this.score,
    required this.color,
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
            width: 64 * (MediaQuery.textScalerOf(context).scale(18) / 18),
            height: 64 * (MediaQuery.textScalerOf(context).scale(18) / 18),
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: score / 100,
                    strokeWidth: 5,
                    strokeCap: StrokeCap.round,
                    backgroundColor: Aether.hairline,
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
                Text(
                  '$score',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
              '$failedChecks of $totalChecks checks unavailable',
              style: AetherType.title,
          ),
        ],
      ),
    );
  }
}

class _NoWorkerCard extends StatelessWidget {
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
                      ? 'Only repairable, failed runtimes can be selected.'
                      : 'Tick a failed runtime below to enable Repair.',
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
                Text(check.name, style: AetherType.title),
                const SizedBox(height: 4),
                Text(check.detail, style: AetherType.caption),
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
