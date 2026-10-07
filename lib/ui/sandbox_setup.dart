import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/state.dart';
import '../core/sandbox_service.dart';
import '../core/studio_setup_coordinator.dart';
import 'studio_screen.dart';
import 'shell.dart';
import 'widgets/aether_primitives.dart';

/// First open asks for install approval. Subsequent opens attach to any
/// active/unfinished job, even if the core has become available meanwhile.
void openStudio(BuildContext context) {
  final setup = StudioSetupCoordinator.I;
  if (setup.coreOnly && setup.status == StudioSetupStatus.ready) {
    setup.forgetCompleted();
  }
  if (setup.needsAttention || !AppState.I.studioFirstOpenDone) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SandboxSetupScreen(
          studioFirstOpen: !AppState.I.studioFirstOpenDone,
        ),
      ),
    );
    return;
  }
  SandboxService.I.checkExisting().then((installed) {
    AppState.I.sandboxInstalled = installed;
    if (!context.mounted) return;
    if (setup.needsAttention) {
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const SandboxSetupScreen()));
    } else if (installed) {
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const StudioScreen()));
    } else {
      setup.forgetCompleted();
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const SandboxSetupScreen()));
    }
  });
}

// ---------------------------------------------------------------------------
// Setup screen — REAL install only (no simulation, no fake progress).
// Every line shown is a real log line emitted by SandboxService.install;
// the progress bar tracks the real download/install phase progress.
//
// REDESIGN (wave 2 UI): the premium Aether primitives from
// `lib/ui/widgets/aether_primitives.dart` carry the layout — an
// AetherCard overall-progress header with a linear bar, one AetherCard per
// setup step (AetherStatusDot + step name + AetherGhostButton 'Repair') and
// AetherCard-framed approval/error/done panels. The install flow, kernel
// checks, approval/permission gates, gate-mode hand-off and every copy
// string are preserved verbatim (no new logic, no coordinator changes).
// ---------------------------------------------------------------------------

/// Per-step visual state derived from the coordinator's phase/status.
enum _StepState { done, active, failed, pending }

class SandboxSetupScreen extends StatefulWidget {
  /// Health-screen hard reset has already been approved: start a core-only
  /// job and hand off to chat. Studio setup always permits Back.
  final bool gateMode;

  /// First Studio setup asks approval for core + runtimes. Completion is
  /// recorded by the coordinator; opening Studio is an explicit action.
  final bool studioFirstOpen;
  const SandboxSetupScreen({
    super.key,
    this.gateMode = false,
    this.studioFirstOpen = false,
  });
  @override
  State<SandboxSetupScreen> createState() => _SandboxSetupScreenState();
}

class _SandboxSetupScreenState extends State<SandboxSetupScreen> {
  late final _setup = StudioSetupCoordinator.I;
  List<String> get _phaseNames => _setup.coreOnly
      ? const [
          'Checking device',
          'Locating bundled bootstrap',
          'Extracting sandbox payload',
          'Setting exec bits',
          'Linking tool aliases',
          'Configuring prefix',
          'Verifying native exec',
        ]
      : const [
          'Checking device',
          'Locating bundled bootstrap',
          'Extracting sandbox payload',
          'Setting exec bits',
          'Linking tool aliases',
          'Configuring prefix',
          'Verifying native exec',
          'Installing Node.js runtime',
          'Installing Python runtime',
        ];

  List<String> get _log => _setup.log;
  final _scroll = ScrollController();
  int get _phase => _setup.phase;
  double get _phaseProgress => _setup.phaseProgress;
  bool get _done => _setup.status == StudioSetupStatus.ready || _partial;
  bool get _verified => _setup.status == StudioSetupStatus.ready;
  bool get _partial => _setup.status == StudioSetupStatus.partial;
  String? get _error => _setup.error;
  bool get _unsupported => _setup.status == StudioSetupStatus.unsupported;
  // Guards the gate-mode hand-off: the auto-advance timer and the manual
  // "Start chatting" button must not push the shell twice.
  bool _navigated = false;
  Timer? _ticker;

  int get _elapsedSec => _setup.elapsed.inSeconds;

  @override
  void initState() {
    super.initState();
    _setup.addListener(_onChanged);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _setup.running) setState(() {});
    });
    if (widget.gateMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_runInstall());
      });
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _setup.removeListener(_onChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    final follow = !_scroll.hasClients || _scroll.position.extentAfter < 48;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && follow && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _runInstall() async {
    await _setup.start(coreOnly: widget.gateMode);
    if (!mounted || !widget.gateMode || !_verified) return;
    // Preserve the Health hard-reset handoff only while its route is current.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (!mounted || _navigated || ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _navigated = true;
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const OvidShell()),
      (_) => false,
    );
  }

  double get _overall {
    if (_verified) return 1;
    // Phases are equal-weighted — coarse but monotonic. Phase progress is
    // the real byte/tar count reported by the service. A partial result is
    // intentionally not presented as 100% complete: final verification did
    // not pass for every requested capability.
    return ((_phase + _phaseProgress) / _phaseNames.length).clamp(0.0, 1.0);
  }

  Color _lineColor(String l) {
    if (l.startsWith(r'$') || l.startsWith('#')) return Aether.accent;
    if (l.startsWith('⚠') || l.toLowerCase().contains('error')) {
      return Aether.danger;
    }
    if (l.endsWith('✓') || l.startsWith('✓')) return Aether.successLight;
    return Aether.textMuted;
  }

  String get _elapsedLabel {
    final s = _elapsedSec;
    if (s < 60) return '$s s';
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')} min';
  }

  /// Step cards reflect the coordinator's coarse phase pointer: completed
  /// phases, the phase the installer is currently inside (or the phase that
  /// was active when it failed), then everything still queued.
  _StepState _stepState(int index) {
    if (_verified) return _StepState.done;
    if (_error != null) {
      if (index < _phase) return _StepState.done;
      if (index == _phase) return _StepState.failed;
      return _StepState.pending;
    }
    if (index < _phase) return _StepState.done;
    if (index == _phase) return _StepState.active;
    return _StepState.pending;
  }

  String _stepStatusLabel(_StepState state) => switch (state) {
    _StepState.done => 'Verified',
    _StepState.active => 'In progress',
    _StepState.failed => 'Needs attention',
    _StepState.pending => 'Queued',
  };

  @override
  Widget build(BuildContext context) {
    final hideClose = widget.gateMode;
    return PopScope(
      canPop: !widget.gateMode,
      child: Scaffold(
        backgroundColor: Aether.bg,
        appBar: AppBar(
          leading: hideClose
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  tooltip: 'Back to chat',
                  onPressed: () => Navigator.pop(context),
                ),
          title: Tooltip(
            message: hideClose ? 'Setting up Ovid Si — one time' : 'Setting up sandbox',
            child: Text(
              hideClose ? 'Setting up Ovid Si — one time' : 'Setting up sandbox',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        body: SafeArea(
          child: _done
              ? _doneView()
              : _error != null
              ? _errorView()
              : _setup.status == StudioSetupStatus.idle
              ? _approvalView()
              : _progressView(),
        ),
      ),
    );
  }

  // ── Step cards ──────────────────────────────────────────────────────────

  /// One AetherCard per setup step: status dot + step name + a 'Repair'
  /// ghost action. Repair re-runs the preserved install flow
  /// (`StudioSetupCoordinator.start` re-checks the existing core, reinstalls
  /// only what's missing and re-verifies native execution) — it is the only
  /// remediation entry point the coordinator exposes, so it stays disabled
  /// while a job is running and becomes available on failure.
  Widget _stepCard(int index) {
    final state = _stepState(index);
    final statusLabel = _stepStatusLabel(state);
    final (color, pulsing) = switch (state) {
      _StepState.done => (Aether.success, false),
      _StepState.active => (Aether.accent, true),
      _StepState.failed => (Aether.danger, false),
      _StepState.pending => (Aether.textFaint, false),
    };
    return Semantics(
      container: true,
      liveRegion: state == _StepState.active || state == _StepState.failed,
      label: '${_phaseNames[index]}: $statusLabel',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: AetherCard(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(
            children: [
              AetherStatusDot(color: color, size: 10, pulsing: pulsing),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _phaseNames[index],
                      style: AetherType.title.copyWith(
                        color: state == _StepState.pending
                            ? Aether.textMuted
                            : null,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(statusLabel, style: AetherType.caption.copyWith(color: color)),
                  ],
                ),
              ),
              AetherGhostButton(
                label: 'Repair',
                onPressed: _setup.running
                    ? null
                    : () => unawaited(_runInstall()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _stepCards() => [
    for (var i = 0; i < _phaseNames.length; i++) _stepCard(i),
  ];

  // ── Views ───────────────────────────────────────────────────────────────

  Widget _approvalView() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: AetherCard(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.terminal, size: 44, color: Aether.accent),
                const SizedBox(height: 18),
                Text('Set up Studio', style: AetherType.h2),
                const SizedBox(height: 12),
                Text(
                  'Install the on-device sandbox and download Node.js, Python, and supporting tools. '
                  'This uses network data and device storage and may take several minutes. '
                  'Any existing sandbox core will be kept.',
                  textAlign: TextAlign.center,
                  style: AetherType.bodyMuted,
                ),
                const SizedBox(height: 10),
                Text(
                  'You can go Back and chat during setup. Reopen Studio to see progress. '
                  'Keep Ovid running; setup cannot continue if the app process is closed.',
                  textAlign: TextAlign.center,
                  style: AetherType.bodyMuted,
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  child: _SetupPrimaryButton(
                    label: 'Install sandbox',
                    icon: Icons.download,
                    onPressed: () => unawaited(_runInstall()),
                  ),
                ),
                const SizedBox(height: 4),
                AetherGhostButton(
                  label: 'Not now',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _progressView() {
    final idx = _phase.clamp(0, _phaseNames.length - 1);
    final verifying = _phaseNames[idx].startsWith('Verifying');
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AetherCard(
            padding: const EdgeInsets.all(16),
            title: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Aether.accent,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    verifying ? 'Verifying setup' : _phaseNames[idx],
                  ),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Step ${idx + 1} of ${_phaseNames.length} · ${verifying ? 'Verification' : 'Setup'}',
                  style: AetherType.caption,
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: _overall.clamp(0.01, 1.0),
                    minHeight: 6,
                    backgroundColor: Aether.surfaceAlt,
                    valueColor: const AlwaysStoppedAnimation(Aether.accent),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      '${(_overall * 100).toStringAsFixed(1)}% ${_verified ? 'verified' : 'verification'}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: Aether.accent,
                      ),
                    ),
                    const Spacer(),
                    Text(_elapsedLabel, style: AetherType.caption),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ..._stepCards(),
          const SizedBox(height: 4),
          SizedBox(height: 220, child: _terminal()),
          const SizedBox(height: 12),
          Text(
            widget.gateMode
                ? 'Installing the sandbox core. Runtime tools can be set up from Studio.'
                : 'Setup continues while you chat. Reopen Studio for progress. Keep Ovid running.',
            textAlign: TextAlign.center,
            style: AetherType.caption,
          ),
          if (!widget.gateMode)
            AetherGhostButton(
              label: 'Back to chat',
              onPressed: () => Navigator.pop(context),
            ),
        ],
      ),
    );
  }

  Widget _terminal() {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Aether.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Aether.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Aether.surfaceAlt,
              border: Border(bottom: BorderSide(color: Aether.hairline)),
            ),
            child: Row(
              children: [
                Icon(Icons.terminal, size: 13, color: Aether.textMuted),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'SANDBOX SETUP LOG — LIVE',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: Aether.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _log.isEmpty
                ? Center(
                    child: Text(
                      'Starting install…',
                      style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _log.length,
                    itemBuilder: (_, i) => Text(
                      _log[i],
                      style: TextStyle(
                        fontFamily: Aether.mono,
                        fontSize: 11,
                        height: 1.6,
                        color: _lineColor(_log[i]),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _errorView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AetherCard(
            padding: const EdgeInsets.all(16),
            title: Row(
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 20,
                  color: Aether.danger,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _unsupported
                        ? 'This device can\'t run the sandbox'
                        : 'Install interrupted',
                  ),
                ),
              ],
            ),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Aether.surfaceAlt,
                borderRadius: BorderRadius.circular(AetherRadius.rMd),
                border: Border.all(color: Aether.hairline),
              ),
              child: Text(
                _error!,
                style: TextStyle(
                  fontFamily: Aether.mono,
                  fontSize: 11.5,
                  height: 1.6,
                  color: Aether.textMuted,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          ..._stepCards(),
          if (_log.isNotEmpty) ...[
            const SizedBox(height: 4),
            SizedBox(height: 200, child: _terminal()),
          ],
          const SizedBox(height: 12),
          if (_unsupported) ...[
            // Chat, providers and the browser all work without the
            // sandbox — only the on-device terminal/Studio needs it.
            _SetupPrimaryButton(
              label: 'Continue to chat without sandbox',
              icon: Icons.chat_bubble_outline,
              onPressed: () async {
                await AppState.I.setSandboxSkipped(true);
                if (!mounted) return;
                if (widget.gateMode) {
                  // Same hand-off as a successful gate install.
                  Navigator.of(
                    context,
                    rootNavigator: true,
                  ).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const OvidShell()),
                    (_) => false,
                  );
                } else {
                  Navigator.pop(context);
                }
              },
            ),
            const SizedBox(height: 8),
            AetherGhostButton(
              label: 'Retry install anyway',
              onPressed: () => unawaited(_runInstall()),
            ),
          ] else ...[
            _SetupPrimaryButton(
              label: 'Retry install',
              icon: Icons.refresh,
              onPressed: () => unawaited(_runInstall()),
            ),
          ],
          if (!widget.gateMode) ...[
            const SizedBox(height: 4),
            AetherGhostButton(
              label: 'Close',
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ],
      ),
    );
  }

  Widget _doneView() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: AetherCard(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 450),
                  curve: Curves.elasticOut,
                  builder: (_, v, _) => Transform.scale(
                    scale: v,
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: Aether.successLight.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Aether.successLight.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Icon(
                        _partial
                            ? Icons.warning_amber_rounded
                            : Icons.check_rounded,
                        size: 38,
                        color: _partial ? Aether.accent : Aether.successLight,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  _partial ? 'Sandbox core ready' : 'Sandbox verified',
                  style: AetherType.h2,
                ),
                const SizedBox(height: 8),
                Text(
                  _partial
                      ? '${_error!} Runtime verification is incomplete.'
                      : _setup.coreOnly
                      ? 'Native sandbox core is ready. Set up runtime tools from Studio.'
                      : 'Native sandbox and Node.js, Python, Git and supporting runtime tools verified.',
                  textAlign: TextAlign.center,
                  style: AetherType.bodyMuted.copyWith(
                    fontSize: 12.5,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _partial
                      ? 'Core verified · runtime verification incomplete'
                      : 'Took $_elapsedLabel',
                  style: AetherType.caption,
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    _SetupBadge(
                      label: 'NATIVE BIONIC',
                      color: Aether.successLight,
                    ),
                    _SetupBadge(
                      label: _partial || _setup.coreOnly
                          ? 'RUNTIMES NOT VERIFIED'
                          : 'RUNTIMES VERIFIED',
                      color: Aether.textMuted,
                      filled: false,
                    ),
                    _SetupBadge(
                      label: 'NO ROOT',
                      color: Aether.textMuted,
                      filled: false,
                    ),
                  ],
                ),
                const SizedBox(height: 26),
                if (_partial) ...[
                  SizedBox(
                    width: double.infinity,
                    child: _SetupPrimaryButton(
                      label: 'Retry runtime setup',
                      icon: Icons.refresh,
                      onPressed: () => unawaited(_runInstall()),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                SizedBox(
                  width: double.infinity,
                  child: _SetupPrimaryButton(
                    label: widget.gateMode ? 'Start chatting' : 'Open Studio',
                    icon: Icons.code,
                    onPressed: () {
                      if (widget.gateMode) {
                        if (_navigated) return;
                        _navigated = true;
                        // Replace the whole nav stack with the chat shell.
                        Navigator.of(
                          context,
                          rootNavigator: true,
                        ).pushAndRemoveUntil(
                          MaterialPageRoute(builder: (_) => const OvidShell()),
                          (_) => false,
                        );
                      } else {
                        if (_navigated) return;
                        _navigated = true;
                        Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                            builder: (_) => const StudioScreen(),
                          ),
                        );
                      }
                    },
                  ),
                ),
                if (!widget.gateMode) ...[
                  const SizedBox(height: 4),
                  AetherGhostButton(
                    label: 'Back to chat',
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Setup actions can have multi-line labels at accessibility text sizes.
class _SetupPrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  const _SetupPrimaryButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.textScalerOf(context).scale(14) <= 18) {
      return AetherPrimaryButton(label: label, icon: icon, onPressed: onPressed);
    }
    return FilledButton.icon(
    onPressed: onPressed,
    icon: Icon(icon, size: 16),
    label: Text(label, textAlign: TextAlign.center),
    style: FilledButton.styleFrom(
      backgroundColor: Aether.accent,
      foregroundColor: Colors.white,
      minimumSize: const Size(0, 44),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AetherRadius.rMd),
      ),
    ),
    );
  }
}

class _SetupBadge extends StatelessWidget {
  final String label;
  final Color color;
  final bool filled;
  const _SetupBadge({required this.label, required this.color, this.filled = true});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final style = TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
        letterSpacing: .6, color: color);
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final fits = painter.width + 22 <= constraints.maxWidth;
      painter.dispose();
      if (fits) return AetherPill(label: label, color: color, filled: filled);
      return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: filled ? color.withValues(alpha: .14) : Colors.transparent,
      border: Border.all(color: color.withValues(alpha: .4)),
      borderRadius: BorderRadius.circular(AetherRadius.rPill),
    ),
    child: Text(label, textAlign: TextAlign.center,
      style: style),
    );
    });
  }
}
