import 'dart:async';

import 'package:flutter/material.dart';
import '../core/agent_service.dart';
import '../core/health_service.dart';
import '../core/sandbox_service.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'providers_screen.dart';
import 'sandbox_setup.dart';
import 'settings_action_widgets.dart';
import 'widgets/aether_confirm.dart';
import 'widgets/aether_primitives.dart';

/// Settings-only health consumer. Uses the existing service's per-runtime
/// results without borrowing the global sandbox uninstall/install controls.
///
/// REDESIGN (wave 2 UI): premium Aether primitives from
/// `lib/ui/widgets/aether_primitives.dart` carry the layout. All runtime
/// wiring — [HealthService.runChecks], [HealthService.repair], the
/// per-check `repairable` targeting set and the cancellable repair worker —
/// is preserved. Leaving the screen no longer cancels a repair mid-install
/// (that could leave a dpkg lock or half-installed packages): a back press
/// asks, the repair keeps running in [HealthService], and reopening the
/// screen re-attaches its log (F-067).
///
/// This is the only Device health screen: the Services (MCP & plugins)
/// section and the sandbox Hard reset were ported here from the retired
/// legacy `HealthScreen`. Without a sandbox the per-runtime checks collapse
/// into one "Install sandbox" card instead of 16 identical failures.
class SettingsHealthScreen extends StatefulWidget {
  final HealthService? service;

  /// Overrides for the two CTAs (tests). Defaults open sandbox setup and the
  /// Providers screen respectively.
  final VoidCallback? onInstallSandbox;
  final VoidCallback? onOpenProviders;
  const SettingsHealthScreen({
    super.key,
    this.service,
    this.onInstallSandbox,
    this.onOpenProviders,
  });
  @override
  State<SettingsHealthScreen> createState() => _SettingsHealthScreenState();
}

class _SettingsHealthScreenState extends State<SettingsHealthScreen> {
  late final HealthService _health = widget.service ?? HealthService.I;
  final List<String> _log = [];
  final Set<String> _selected = {};
  bool _starting = false;
  bool _resetting = false;
  String? _result;

  /// Wall-clock start of the running repair, for the elapsed-time readout.
  DateTime? _repairStartedAt;
  Timer? _elapsedTicker;

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
        setState(
          () => _selected.retainAll(
            report.failed.where((c) => c.repairable).map((c) => c.id),
          ),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _result = 'Health checks failed. Retry.');
    }
  }

  @override
  void dispose() {
    // The repair itself keeps running in HealthService (F-067).
    _elapsedTicker?.cancel();
    super.dispose();
  }

  /// Back while a repair runs: keep it running (default), stop it, or stay.
  Future<void> _confirmLeave() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('Leave while repairing?'),
        content: const Text(
          'Packages are being installed. Leaving keeps the repair running in '
          'the background; reopen Device health to see its progress. '
          'Stopping mid-install can leave packages half-installed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'stop'),
            child: Text(
              'Stop repair and leave',
              style: TextStyle(color: Aether.danger),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'stay'),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'leave'),
            child: const Text('Keep running'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null || choice == 'stay') return;
    if (choice == 'stop' && _health.repairing) _health.cancelRepair();
    _leaving = true;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  bool _leaving = false;

  Future<void> _installSandbox() async {
    final override = widget.onInstallSandbox;
    if (override != null) return override();
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SandboxSetupScreen()));
    if (mounted) await _check();
  }

  void _openProviders() {
    final override = widget.onOpenProviders;
    if (override != null) return override();
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ProvidersScreen()));
  }

  /// PR47/K6: hard reset — delete the whole sandbox prefix + reinstall from
  /// the bundled bootstrap in the SHELL (SandboxSetupScreen drives its own
  /// progress). Points the user at a healthy state even when self-heal
  /// saturates on older/corrupt installs. Ported from the legacy screen.
  Future<void> _hardResetSandbox() async {
    if (_resetting || _starting || _health.repairing || _health.checking) {
      return;
    }
    setState(() {
      _resetting = true;
      _result = null;
      _log
        ..clear()
        ..add('ovid: deleting sandbox prefix…');
    });
    try {
      await SandboxService.I.uninstall();
      if (!mounted) return;
      setState(() => _log.add('ovid: deleted — reopening setup gate…'));
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
      if (mounted) setState(() => _log.add('ovid: reset failed: $e'));
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  /// Hard reset is guarded (F-068): running chats use the sandbox rootfs,
  /// and the confirmation spells out what is lost.
  Future<void> _confirmHardReset() async {
    // Running replies use the sandbox rootfs; deleting it under them breaks
    // them mid-flight. Block until they are stopped.
    final running = AppState.I.sessions
        .where((s) => AgentService.I.busyFor(s.id))
        .length;
    if (running > 0) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Stop running chats first'),
          content: Text(
            '$running chat${running == 1 ? ' is' : 's are'} still running and '
            'using the sandbox. Stop ${running == 1 ? 'it' : 'them'}, then '
            'reset the sandbox.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;
    final confirmed = await showAetherConfirmDialog(
      context,
      title: 'Reset the sandbox?',
      message:
          'This deletes the whole sandbox and opens setup again. Open '
          'terminals and local (stdio) MCP servers are stopped.',
      extra: Text(
        'You will lose: installed packages and runtimes, Python/Node modules '
        'and tool caches, and the sandbox home folder (shell history, config '
        'and anything saved outside chat workspaces). Chat workspace folders '
        'are kept.',
        style: AetherType.bodyMuted,
      ),
      confirmLabel: 'Reset sandbox',
    );
    if (confirmed && mounted) await _hardResetSandbox();
  }

  Future<void> _repair() async {
    if (_starting ||
        _health.repairing ||
        _health.checking ||
        _selected.isEmpty) {
      return;
    }
    setState(() {
      _starting = true;
      _result = null;
      _log.clear();
      _repairStartedAt = DateTime.now();
    });
    _elapsedTicker?.cancel();
    _elapsedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
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
          _result = 'Repair complete: selected runtime checks now pass.';
          _selected.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        final message = e is HealthRepairCancelled
            ? 'Repair cancelled: ${e.toString().replaceFirst('HealthRepairCancelled: ', '')}'
            : 'Repair failed: $e';
        setState(() => _result = message);
      }
    } finally {
      _elapsedTicker?.cancel();
      _elapsedTicker = null;
      if (mounted) {
        setState(() {
          _starting = false;
          _repairStartedAt = null;
        });
      }
    }
  }

  Duration? get _elapsed {
    final started = _repairStartedAt;
    return started == null ? null : DateTime.now().difference(started);
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
    return AnimatedBuilder(
      animation: _health,
      builder: (context, child) => PopScope(
        canPop: _leaving || !_health.repairing,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _confirmLeave();
        },
        child: child!,
      ),
      child: Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(title: const Text('Device health')),
      body: AnimatedBuilder(
        animation: Listenable.merge([_health, AppState.I]),
        builder: (_, _) {
          // Re-attach to a repair started before this screen was reopened.
          final log = _log.isEmpty && _health.repairing
              ? _health.repairLog
              : _log;
          final report = _health.lastReport;
          final busy = _starting || _resetting || _health.repairing;
          final checks = report?.checks ?? const <HealthCheck>[];
          final available = checks.where((check) => check.ok).length;
          final attention = checks
              .where(
                (check) =>
                    !check.ok &&
                    (check.status == HealthStatus.missing ||
                        check.status == HealthStatus.missingConfiguration),
              )
              .length;
          final unavailable = checks.length - available - attention;
          final repairable = checks.where((check) => check.repairable).length;
          // No sandbox: every runtime and storage check fails for the same
          // reason, so they collapse into one actionable card.
          final sandbox = checks.where((c) => c.id == 'sandbox').firstOrNull;
          final noSandbox = sandbox != null && !sandbox.ok;
          final dependent = noSandbox
              ? checks
                    .where((c) => c.id != 'sandbox' && c.id != 'provider')
                    .toList()
              : const <HealthCheck>[];
          final visibleChecks = noSandbox
              ? checks.where((c) => c.id == 'provider').toList()
              : checks;
          final services = AppState.I.serviceStatus;
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
                  availableChecks: available,
                  attentionChecks: attention,
                  unavailableChecks: unavailable,
                ),
              if (_health.checking) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(
                  semanticsLabel: 'Checking device health',
                ),
              ],

              // A failed check run has no report to show: put its outcome at
              // the top. Repair outcomes sit next to the repair controls.
              if (_result != null && report == null) ...[
                const SizedBox(height: 12),
                _ResultCard(message: _result!),
              ],

              // ── Runtime health ──
              const SizedBox(height: 20),
              const AetherSectionTitle(
                eyebrow: 'Runtime health',
                subtitle:
                    'A passing version probe is not proof of network access or every tool operation.',
              ),
              const SizedBox(height: 12),

              if (noSandbox) ...[
                _NoSandboxCard(
                  // "Missing" is what the card already says; any other failure
                  // (a probe error) is worth showing verbatim.
                  detail: sandbox.status == HealthStatus.missing
                      ? null
                      : sandbox.detail,
                  hiddenChecks: dependent.length,
                  onInstall: busy || _health.checking ? null : _installSandbox,
                ),
                const SizedBox(height: 12),
              ] else if (_health.repairWorker == null)
                _NoWorkerCard()
              else ...[
                _RepairControls(
                  busy: busy,
                  repairing: _health.repairing,
                  cancellationRequested: _health.cancellationRequested,
                  canRepair: !_health.checking && _selected.isNotEmpty,
                  selectedCount: _selected.length,
                  repairableCount: repairable,
                  elapsed: _elapsed,
                  onRepair: _repair,
                  onCancel: _health.cancelRepair,
                ),
                const SizedBox(height: 12),
              ],

              if (_result != null && report != null) ...[
                _ResultCard(message: _result!),
                const SizedBox(height: 12),
              ],

              for (final check in visibleChecks) ...[
                _HealthCheckCard(
                  check: check,
                  selectable: check.repairable && _health.repairWorker != null,
                  selected: _selected.contains(check.id),
                  onChanged: busy || _health.checking ? null : _toggle,
                  onOpenProviders: check.id == 'provider' && !check.ok
                      ? _openProviders
                      : null,
                ),
                const SizedBox(height: 8),
              ],

              if (log.isNotEmpty) ...[
                const SizedBox(height: 4),
                _RepairLogCard(lines: log),
                const SizedBox(height: 12),
              ],

              // ── Services (MCP & plugins) ──
              if (services.isNotEmpty) ...[
                const SizedBox(height: 12),
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
                    onRetry: busy || _health.checking ? null : _check,
                  ),
                  const SizedBox(height: 8),
                ],
              ],

              // ── Diagnostics: re-run + hard reset ──
              const SizedBox(height: 12),
              _DangerActionsCard(
                resetting: _resetting,
                onReset: busy || _health.checking ? null : _confirmHardReset,
                onReRun: busy || _health.checking ? null : _check,
              ),
            ],
          );
        },
      ),
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
  final int availableChecks;
  final int attentionChecks;
  final int unavailableChecks;
  const _ScoreSummaryCard({
    required this.score,
    required this.color,
    required this.totalChecks,
    required this.failedChecks,
    required this.availableChecks,
    required this.attentionChecks,
    required this.unavailableChecks,
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
            '$totalChecks of $totalChecks checks completed',
            style: AetherType.title,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              _SummaryCount(label: 'Available', count: availableChecks),
              _SummaryCount(label: 'Needs attention', count: attentionChecks),
              _SummaryCount(label: 'Unavailable', count: unavailableChecks),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '$failedChecks of $totalChecks checks need attention or recovery.',
            style: AetherType.caption,
          ),
        ],
      ),
    );
  }
}

class _SummaryCount extends StatelessWidget {
  final String label;
  final int count;
  const _SummaryCount({required this.label, required this.count});

  @override
  Widget build(BuildContext context) =>
      Text('$label: $count', style: AetherType.caption);
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
  final int selectedCount;
  final int repairableCount;

  /// Time since the running repair started (null when idle).
  final Duration? elapsed;
  final VoidCallback onRepair;
  final VoidCallback onCancel;
  const _RepairControls({
    required this.busy,
    required this.repairing,
    required this.cancellationRequested,
    required this.canRepair,
    required this.selectedCount,
    required this.repairableCount,
    this.elapsed,
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
          Text(
            '$selectedCount selected · $repairableCount repairable',
            style: AetherType.caption,
          ),
          if (repairing) ...[
            const SizedBox(height: 12),
            // A signed install can take minutes; an indeterminate bar and a
            // ticking clock show it is still working.
            const LinearProgressIndicator(
              semanticsLabel: 'Runtime repair in progress',
            ),
            const SizedBox(height: 6),
            Text(
              'Installing signed packages · elapsed ${_formatElapsed(elapsed ?? Duration.zero)}'
              ' · this can take several minutes',
              style: AetherType.caption,
            ),
          ],
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

String _formatElapsed(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Shown instead of every runtime/storage check when the sandbox is missing:
/// one reason, one action.
class _NoSandboxCard extends StatelessWidget {
  final String? detail;
  final int hiddenChecks;
  final VoidCallback? onInstall;
  const _NoSandboxCard({
    required this.detail,
    required this.hiddenChecks,
    required this.onInstall,
  });

  @override
  Widget build(BuildContext context) {
    return AetherCard(
      key: const ValueKey('health-no-sandbox'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: AetherStatusDot(color: Aether.warn, size: 10),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Sandbox not installed', style: AetherType.title),
                    const SizedBox(height: 4),
                    Text(
                      'Python, Node.js, git, shell tools and workspace '
                      'storage ($hiddenChecks checks) need the on-device '
                      'Linux sandbox.${detail == null ? '' : ' $detail'}',
                      style: AetherType.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SettingsActionButton(
            label: 'Install sandbox',
            icon: Icons.download_outlined,
            primary: true,
            onPressed: onInstall,
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

  /// Set for the provider check when it fails: an "Open Providers" button.
  final VoidCallback? onOpenProviders;
  const _HealthCheckCard({
    required this.check,
    required this.selectable,
    required this.selected,
    required this.onChanged,
    this.onOpenProviders,
  });

  String get _statusWord => switch (check.status) {
    HealthStatus.available => 'Available',
    HealthStatus.missingConfiguration => 'Missing configuration',
    HealthStatus.missing => 'Missing',
    HealthStatus.denied => 'Permission denied',
    HealthStatus.unsupported => 'Unsupported',
    HealthStatus.failed => 'Failed',
  };

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
                const SizedBox(height: 2),
                // The status word carries the meaning the dot colour alone
                // cannot (colour-blind users, screen readers).
                Text(
                  _statusWord,
                  style: AetherType.caption.copyWith(color: _dotColor),
                ),
                const SizedBox(height: 2),
                Text(check.detail, style: AetherType.caption),
                if (onOpenProviders != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: AetherGhostButton(
                      label: 'Open Providers',
                      onPressed: onOpenProviders,
                    ),
                  ),
                ],
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
                ? SizedBox(
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
                    // A pulsing dot keeps a ticker alive forever; the red
                    // tint + Retry carry the "needs attention" affordance.
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
                Text(switch (status.health) {
                  ServiceHealth.working => 'Working',
                  ServiceHealth.connecting => 'Connecting',
                  ServiceHealth.failed => 'Failed',
                }, style: AetherType.caption.copyWith(color: _dotColor)),
                const SizedBox(height: 2),
                Text(_lastCheckCaption, style: AetherType.caption),
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
            label: resetting ? 'Resetting sandbox…' : 'Hard reset the sandbox',
            icon: Icons.delete_sweep_outlined,
            danger: true,
            onPressed: onReset,
          ),
        ],
      ),
    );
  }
}
