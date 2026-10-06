import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/state.dart';
import '../core/router.dart';
import '../core/sandbox_service.dart';
import '../core/studio_setup_coordinator.dart';
import 'studio_screen.dart';
import 'shell.dart';
import 'widgets/aether_primitives.dart';

/// First open asks for install approval. Subsequent opens attach to any
/// active/unfinished job, even if the core has become available meanwhile.
///
/// DETERMINISTIC (v2-13): the whole decision runs through ONE resolver —
/// [resolveStudioDestination] — which lands in exactly ONE place per state
/// (install/attention/first-open → [SandboxSetupScreen]; ready →
/// [StudioScreen]). There is no split sync/async decision tree and no
/// 3-outcome completion callback: inputs are gathered once, the pure gate
/// ([determineStudioRoute]) decides, and the single resulting route is
/// PUSHED — the stack is never wiped here; replacing or clearing routes
/// stays behind explicit user actions inside the screens.
void openStudio(BuildContext context) {
  // Collapse double taps during the disk probe: one resolution, one push.
  if (_studioOpening) return;
  _studioOpening = true;
  unawaited(() async {
    try {
      final destination = await resolveStudioDestination();
      if (!context.mounted) return;
      unawaited(
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => destination)),
      );
    } finally {
      _studioOpening = false;
    }
  }());
}

bool _studioOpening = false;

/// The ONE Studio destination for the current state, computed in a single
/// pass. A completed core-only job (Health hard reset) is forgotten first —
/// it is not proof the full Studio toolchain exists. First-open and
/// needs-attention states short-circuit before the disk probe (approval
/// comes before any install decision); otherwise the probe decides between
/// Studio and the install flow, and the job state is re-read after the
/// probe because a banner retry may have started while it ran.
Future<Widget> resolveStudioDestination() async {
  final setup = StudioSetupCoordinator.I;
  if (setup.coreOnly && setup.status == StudioSetupStatus.ready) {
    setup.forgetCompleted();
  }
  final firstOpenDone = AppState.I.studioFirstOpenDone;
  if (!firstOpenDone || setup.needsAttention) {
    return studioScreenFor(
      determineStudioRoute(
        firstOpenDone: firstOpenDone,
        needsAttention: setup.needsAttention,
        sandboxInstalled: AppState.I.sandboxInstalled,
      ),
    );
  }
  final installed = await SandboxService.I.checkExisting();
  AppState.I.sandboxInstalled = installed;
  final attention = setup.needsAttention;
  // A completed job is not proof that a wiped core still exists — but a
  // retained failure/partial state is never forgotten here.
  if (!installed && !attention) setup.forgetCompleted();
  return studioScreenFor(
    determineStudioRoute(
      firstOpenDone: true,
      needsAttention: attention,
      sandboxInstalled: installed,
    ),
  );
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
//
// ONBOARDING (v2-13): first-open completion consolidates into one guided
// "Connect repo" step — Session clone preselected (the sensible default),
// Local folder clone under a collapsed Advanced options section, and one
// clear action (Open Studio) that hands off to Studio with the one-time
// post-install GitHub prompt. Repair/partial/gate completions keep the
// classic done panel. Approval copy is a single calm paragraph; every state
// (empty/progress/error) keeps exactly one primary action.
// ---------------------------------------------------------------------------

/// Per-step visual state derived from the coordinator's phase/status.
enum _StepState { done, active, failed, pending }

/// Where a connected repo's working copy lives. Session clone is the
/// preselected sensible default on the Connect repo step; Local folder
/// clone sits under the collapsed Advanced options.
enum _CloneTarget { session, local }

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
  bool get _partial => _setup.status == StudioSetupStatus.partial;
  String? get _error => _setup.error;
  bool get _unsupported => _setup.status == StudioSetupStatus.unsupported;
  // Guards the gate-mode hand-off: the auto-advance timer and the manual
  // "Start chatting" button must not push the shell twice.
  bool _navigated = false;
  Timer? _ticker;

  /// Connect repo step: Session clone is preselected; Advanced options
  /// (Local folder clone) start collapsed.
  _CloneTarget _connectTarget = _CloneTarget.session;
  bool _connectAdvancedOpen = false;

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
    if (!mounted || !widget.gateMode || !_done) return;
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
    if (_done) return 1;
    // 7 phases of equal weight — coarse but monotonic. Phase progress is
    // the real byte/tar count reported by the service.
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
    if (_done) return _StepState.done;
    if (_error != null) {
      if (index < _phase) return _StepState.done;
      if (index == _phase) return _StepState.failed;
      return _StepState.pending;
    }
    if (index < _phase) return _StepState.done;
    if (index == _phase) return _StepState.active;
    return _StepState.pending;
  }

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
            message: hideClose ? 'Setting up Ovid — one time' : 'Setting up sandbox',
            child: Text(
              hideClose ? 'Setting up Ovid — one time' : 'Setting up sandbox',
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
    final (color, pulsing) = switch (state) {
      _StepState.done => (Aether.success, false),
      _StepState.active => (Aether.accent, true),
      _StepState.failed => (Aether.danger, false),
      _StepState.pending => (Aether.textFaint, false),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AetherCard(
        padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
        child: Row(
          children: [
            AetherStatusDot(color: color, size: 10, pulsing: pulsing),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _phaseNames[index],
                style: AetherType.title.copyWith(
                  color: state == _StepState.pending ? Aether.textMuted : null,
                ),
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
                  'Install the on-device sandbox with Node.js, Python and tools. '
                  'One time, a few minutes — you can keep chatting while it runs.',
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
                Expanded(child: Text(_phaseNames[idx])),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Step ${idx + 1} of ${_phaseNames.length}', style: AetherType.caption),
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
                      '${(_overall * 100).toStringAsFixed(1)}%',
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
              label: 'Continue without sandbox',
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
    // First-open completion consolidates onboarding into the guided Connect
    // repo step. Partial toolchains and gate-mode completions keep the
    // classic done panel (its runtime retry / Start chatting contracts).
    if (widget.studioFirstOpen && !widget.gateMode && !_partial) {
      return _connectRepoView();
    }
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
                _successIcon(),
                const SizedBox(height: 20),
                Text(
                  _partial ? 'Sandbox core ready' : 'Sandbox ready',
                  style: AetherType.h2,
                ),
                const SizedBox(height: 8),
                Text(
                  _partial
                      ? _error!
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
                Text('Took $_elapsedLabel', style: AetherType.caption),
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
                          ? 'RUNTIMES INCOMPLETE'
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

  /// Calm success marker shared by the done panel and the Connect repo step.
  Widget _successIcon() {
    return TweenAnimationBuilder<double>(
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
            Icons.check_rounded,
            size: 38,
            color: Aether.successLight,
          ),
        ),
      ),
    );
  }

  // ── First-open onboarding: one guided Connect repo step ─────────────────
  //
  // Session clone is preselected (the sensible default — clone once into
  // Ovid storage, reused by future sessions); Local folder clone sits under
  // the collapsed Advanced options. The single action opens Studio, which
  // owns the actual sign-in/repo-pick/clone flow, with the one-time
  // post-install GitHub prompt wired.

  Widget _connectRepoView() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: _successIcon()),
              const SizedBox(height: 20),
              Text(
                'Sandbox ready',
                style: AetherType.h2,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Connect a repo to start building.',
                textAlign: TextAlign.center,
                style: AetherType.bodyMuted,
              ),
              const SizedBox(height: 24),
              Text('Connect repo', style: AetherType.title),
              const SizedBox(height: 10),
              _connectOption(
                key: const ValueKey('connectRepo.sessionClone'),
                title: 'Session clone',
                subtitle: 'Clone once into Ovid storage — '
                    'reused by future sessions.',
                badge: 'Default',
                selected: _connectTarget == _CloneTarget.session,
                onTap: () =>
                    setState(() => _connectTarget = _CloneTarget.session),
              ),
              Semantics(
                container: true,
                button: true,
                expanded: _connectAdvancedOpen,
                child: InkWell(
                  borderRadius: BorderRadius.circular(AetherRadius.rMd),
                  onTap: () => setState(
                    () => _connectAdvancedOpen = !_connectAdvancedOpen,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _connectAdvancedOpen
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 18,
                          color: Aether.textMuted,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Advanced options',
                            style: AetherType.label,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_connectAdvancedOpen)
                _connectOption(
                  key: const ValueKey('connectRepo.localClone'),
                  title: 'Local folder clone',
                  subtitle: 'Pick a device folder; the repo is cloned '
                      'into a subfolder.',
                  selected: _connectTarget == _CloneTarget.local,
                  onTap: () =>
                      setState(() => _connectTarget = _CloneTarget.local),
                ),
              const SizedBox(height: 22),
              _SetupPrimaryButton(
                label: 'Open Studio',
                icon: Icons.code,
                onPressed: _openStudioAfterSetup,
              ),
              const SizedBox(height: 4),
              AetherGhostButton(
                label: 'Back to chat',
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One selectable clone-target card: a radio-style check conveys the
  /// selection (Session clone is preselected), an optional pill marks the
  /// recommended default.
  Widget _connectOption({
    required Key key,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
    String? badge,
  }) {
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      child: AetherCard(
        key: key,
        padding: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(AetherRadius.rLg),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    size: 20,
                    color: selected ? Aether.accent : Aether.textFaint,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(title, style: AetherType.title),
                          if (badge != null)
                            AetherPill(label: badge, color: Aether.accent),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: AetherType.bodyMuted.copyWith(
                          fontSize: 12.5,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The Connect repo step's one action: replace this route with Studio
  /// (user-confirmed — never a stack wipe) and fire the one-time
  /// post-install GitHub login prompt from Studio's side.
  void _openStudioAfterSetup() {
    if (_navigated) return;
    _navigated = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => const StudioScreen(postInstallGithubPrompt: true),
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
