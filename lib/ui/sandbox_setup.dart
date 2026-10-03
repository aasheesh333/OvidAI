import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/state.dart';
import '../core/sandbox_service.dart';
import '../core/studio_setup_coordinator.dart';
import 'studio_screen.dart';
import 'shell.dart';

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
// ---------------------------------------------------------------------------

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
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
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
          title: Text(
            hideClose ? 'Setting up Ovid — one time' : 'Setting up sandbox',
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

  Widget _approvalView() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.terminal, size: 48, color: Aether.accent),
            const SizedBox(height: 20),
            const Text(
              'Set up Studio',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            const Text(
              'Install the on-device sandbox and download Node.js, Python, and supporting tools. '
              'This uses network data and device storage and may take several minutes. '
              'Any existing sandbox core will be kept.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'You can go Back and chat during setup. Reopen Studio to see progress. '
              'Keep Ovid running; setup cannot continue if the app process is closed.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => unawaited(_runInstall()),
              icon: const Icon(Icons.download),
              label: const Text('Install sandbox'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _progressView() {
    final idx = _phase.clamp(0, _phaseNames.length - 1);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Aether.accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _phaseNames[idx],
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                'Step ${idx + 1} of ${_phaseNames.length}',
                style: TextStyle(fontSize: 11, color: Aether.textFaint),
              ),
            ],
          ),
          const SizedBox(height: 14),
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
              Text(
                _elapsedLabel,
                style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(child: _terminal()),
          const SizedBox(height: 12),
          Text(
            widget.gateMode
                ? 'Installing the sandbox core. Runtime tools can be set up from Studio.'
                : 'Setup continues while you chat. Reopen Studio for progress. Keep Ovid running.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
          ),
          if (!widget.gateMode)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Back to chat'),
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
                Text(
                  'SANDBOX SETUP LOG — LIVE',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: Aether.textMuted,
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
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          const Icon(Icons.error_outline, size: 40, color: Aether.danger),
          const SizedBox(height: 12),
          Text(
            _unsupported
                ? 'This device can\'t run the sandbox'
                : 'Install interrupted',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Aether.surface,
              borderRadius: BorderRadius.circular(10),
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
          const Spacer(),
          if (_log.isNotEmpty) Expanded(child: _terminal()),
          const SizedBox(height: 12),
          if (_unsupported) ...[
            // Chat, providers and the browser all work without the
            // sandbox — only the on-device terminal/Studio needs it.
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Aether.accent,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.chat_bubble_outline, size: 17),
                label: const Text(
                  'Continue without sandbox',
                  style: TextStyle(fontSize: 14),
                ),
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
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => unawaited(_runInstall()),
              child: Text(
                'Retry install anyway',
                style: TextStyle(fontSize: 12.5, color: Aether.textFaint),
              ),
            ),
          ] else ...[
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Aether.accent,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.refresh, size: 17),
              label: const Text('Retry install'),
              onPressed: () => unawaited(_runInstall()),
            ),
          ],
          const SizedBox(height: 8),
          if (!widget.gateMode)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'Close',
                style: TextStyle(fontSize: 12.5, color: Aether.textFaint),
              ),
            ),
        ],
      ),
    );
  }

  Widget _doneView() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
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
                    Icons.check_rounded,
                    size: 38,
                    color: Aether.successLight,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _partial ? 'Sandbox core ready' : 'Sandbox ready',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              _partial
                  ? _error!
                  : _setup.coreOnly
                  ? 'Native sandbox core is ready. Set up runtime tools from Studio.'
                  : 'Native sandbox and Node.js, Python, Git and supporting runtime tools verified.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: Aether.textMuted,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Took $_elapsedLabel',
              style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                Tag('NATIVE BIONIC', color: Aether.successLight, filled: true),
                Tag(
                  _partial || _setup.coreOnly
                      ? 'RUNTIMES INCOMPLETE'
                      : 'RUNTIMES VERIFIED',
                  color: Aether.textMuted,
                ),
                Tag('NO ROOT', color: Aether.textMuted),
              ],
            ),
            const SizedBox(height: 26),
            if (_partial) ...[
              FilledButton.icon(
                onPressed: () => unawaited(_runInstall()),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry runtime setup'),
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Aether.accent,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
                icon: const Icon(Icons.code, size: 18),
                label: Text(
                  widget.gateMode ? 'Start chatting' : 'Open Studio',
                  style: const TextStyle(fontSize: 14),
                ),
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
                      MaterialPageRoute(builder: (_) => const StudioScreen()),
                    );
                  }
                },
              ),
            ),
            if (!widget.gateMode) ...[
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'Back to chat',
                  style: TextStyle(fontSize: 12.5, color: Aether.textFaint),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
