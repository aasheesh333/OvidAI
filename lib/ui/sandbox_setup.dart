import 'dart:async';
import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../core/state.dart';
import '../core/sandbox_service.dart';
import 'studio_screen.dart';

/// Opens Studio — first-time users go through the sandbox install flow.
void openStudio(BuildContext context) {
  // The gate is decided by a REAL disk check, not a stale in-memory flag.
  SandboxService.I.checkExisting().then((installed) {
    AppState.I.sandboxInstalled = installed;
    if (!context.mounted) return;
    if (installed) {
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const StudioScreen()));
    } else {
      _showGate(context);
    }
  });
}

/// "Code on your phone?" — one-time install permission sheet.
void _showGate(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Aether.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: Aether.accentSoft,
                  borderRadius: BorderRadius.circular(14),
                  border:
                      Border.all(color: Aether.accent.withValues(alpha: .35)),
                ),
                child: const Icon(Icons.terminal,
                    size: 22, color: Aether.accent),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Text('Code on your phone?',
                    style:
                        TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.close,
                    size: 18, color: Aether.textFaint),
                onPressed: () => Navigator.pop(ctx),
              ),
            ]),
            const SizedBox(height: 12),
            Text(
              'Ovid Studio needs a one-time sandbox — a real Ubuntu install that '
              'runs fully on this device. After this, the AI can edit files, run '
              'code and push commits straight from chat.',
              style: TextStyle(
                  fontSize: 13, height: 1.55, color: Aether.textMuted),
            ),
            const SizedBox(height: 16),
            const _SpecRow(Icons.dns_outlined, 'Ubuntu 24.04 LTS',
                'Full Linux userland — no root access needed'),
            const SizedBox(height: 10),
            const _SpecRow(Icons.construction_outlined, 'Toolchain',
                'python3 · node · gcc · git · make · curl'),
            const SizedBox(height: 10),
            const _SpecRow(Icons.download_outlined, 'One-time download',
                '≈ 320 MB · 2–4 min on 4G · 1.1 GB installed'),
            const SizedBox(height: 10),
            const _SpecRow(Icons.lock_outline, 'Private',
                'Everything runs and stays on this device'),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    side: BorderSide(color: Aether.hairlineStrong),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child:
                      const Text('Not now', style: TextStyle(fontSize: 13.5)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Aether.accent,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  icon:
                      const Icon(Icons.download_outlined, size: 17),
                  label: const Text('Install sandbox',
                      style: TextStyle(fontSize: 13.5)),
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const SandboxSetupScreen()));
                  },
                ),
              ),
            ]),
          ],
        ),
      ),
    ),
  );
}

class _SpecRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  const _SpecRow(this.icon, this.title, this.sub);

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, size: 16, color: Aether.textMuted),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 1),
            Text(sub,
                style: TextStyle(
                    fontSize: 11.5, color: Aether.textFaint)),
          ],
        ),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Setup screen — REAL install only (no simulation, no fake progress).
// Every line shown is a real log line emitted by SandboxService.install;
// the progress bar tracks the real download/install phase progress.
// ---------------------------------------------------------------------------

class SandboxSetupScreen extends StatefulWidget {
  const SandboxSetupScreen({super.key});
  @override
  State<SandboxSetupScreen> createState() => _SandboxSetupScreenState();
}

class _SandboxSetupScreenState extends State<SandboxSetupScreen> {
  static const _phaseNames = [
    'Checking device',
    'Downloading proot engine',
    'Downloading Ubuntu rootfs',
    'Extracting rootfs',
    'First boot & user setup',
    'Installing toolchain',
    'Verifying sandbox',
  ];

  final _log = <String>[];
  final _scroll = ScrollController();
  int _phase = 0;
  double _phaseProgress = 0;
  bool _done = false;
  String? _error;
  DateTime? _start;
  Timer? _ticker;

  int get _elapsedSec =>
      _start == null ? 0 : DateTime.now().difference(_start!).inSeconds;

  @override
  void initState() {
    super.initState();
    _start = DateTime.now();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_done) setState(() {}); // ticks the ETA/elapsed label
    });
    _runInstall();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _append(String line) {
    _log.add(line);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _runInstall() async {
    try {
      await SandboxService.I.install(onPhase: (phase, p, line) {
        if (!mounted || _done) return;
        _phase = phase;
        _phaseProgress = p;
        _append(line);
      });
      if (!mounted) return;
      setState(() {
        _done = true;
      });
      AppState.I.sandboxReady();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
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
    if (l.endsWith('✓') || l.startsWith('✓')) return Aether.success;
    return Aether.textMuted;
  }

  String get _elapsedLabel {
    final s = _elapsedSec;
    if (s < 60) return '$s s';
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')} min';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _done || _error != null,
      child: Scaffold(
        backgroundColor: Aether.bg,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: () {
              if (_done || _error == null) Navigator.pop(context);
            },
          ),
          title: const Text('Setting up sandbox'),
        ),
        body: SafeArea(
          child: _error != null
              ? _errorView()
              : _done
                  ? _doneView()
                  : _progressView(),
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
          Row(children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Aether.accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(_phaseNames[idx],
                  style: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w700)),
            ),
            Text('Step ${idx + 1} of ${_phaseNames.length}',
                style: TextStyle(
                    fontSize: 11, color: Aether.textFaint)),
          ]),
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
          Row(children: [
            Text('${(_overall * 100).toStringAsFixed(1)}%',
                style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: Aether.accent)),
            const Spacer(),
            Text(_elapsedLabel,
                style: TextStyle(
                    fontSize: 11.5, color: Aether.textFaint)),
          ]),
          const SizedBox(height: 16),
          Expanded(child: _terminal()),
          const SizedBox(height: 12),
          Text('Keep the app open — this happens only once.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: Aether.textFaint)),
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
              border:
                  Border(bottom: BorderSide(color: Aether.hairline)),
            ),
            child: Row(children: [
              Icon(Icons.terminal, size: 13, color: Aether.textMuted),
              SizedBox(width: 8),
              Text('SANDBOX SETUP LOG — LIVE',
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: Aether.textMuted)),
            ]),
          ),
          Expanded(
            child: _log.isEmpty
                ? Center(
                    child: Text('Starting install…',
                        style: TextStyle(
                            fontSize: 11.5, color: Aether.textFaint)),
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
                          color: _lineColor(_log[i])),
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
          const Text('Install interrupted',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
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
                  color: Aether.textMuted),
            ),
          ),
          const Spacer(),
          if (_log.isNotEmpty)
            Expanded(child: _terminal()),
          const SizedBox(height: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Aether.accent,
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            icon: const Icon(Icons.refresh, size: 17),
            label: const Text('Retry install'),
            onPressed: () {
              setState(() {
                _log.clear();
                _error = null;
                _phase = 0;
                _phaseProgress = 0;
                _done = false;
                _start = DateTime.now();
              });
              _runInstall();
            },
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close',
                style: TextStyle(fontSize: 12.5, color: Aether.textFaint)),
          ),
        ],
      ),
    );
  }

  Widget _doneView() {
    return Center(
      child: Padding(
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
                    color: Aether.success.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: Aether.success.withValues(alpha: 0.5)),
                  ),
                  child: const Icon(Icons.check_rounded,
                      size: 38, color: Aether.success),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text('Sandbox ready',
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(
              'Ubuntu 24.04 · python3 · node · git · gcc\nAll running privately on this device.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12.5, height: 1.6, color: Aether.textMuted),
            ),
            const SizedBox(height: 8),
            Text('Took $_elapsedLabel',
                style: TextStyle(
                    fontSize: 11.5, color: Aether.textFaint)),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                Tag('UBUNTU 24.04', color: Aether.success, filled: true),
                Tag('1.1 GB', color: Aether.textMuted),
                Tag('NO ROOT', color: Aether.textMuted),
              ],
            ),
            const SizedBox(height: 26),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Aether.accent,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13)),
                ),
                icon: const Icon(Icons.code, size: 18),
                label: const Text('Open Studio',
                    style: TextStyle(fontSize: 14)),
                onPressed: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                        builder: (_) => const StudioScreen())),
              ),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Back to chat',
                  style: TextStyle(fontSize: 12.5, color: Aether.textFaint)),
            ),
          ],
        ),
      ),
    );
  }
}
