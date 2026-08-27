import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../core/state.dart';
import '../core/sandbox_service.dart';
import 'studio_screen.dart';

/// Opens Studio — first-time users go through the sandbox install flow.
void openStudio(BuildContext context) {
  if (AppState.I.sandboxInstalled) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const StudioScreen()));
  } else {
    _showGate(context);
  }
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
                icon: const Icon(Icons.close,
                    size: 18, color: Aether.textFaint),
                onPressed: () => Navigator.pop(ctx),
              ),
            ]),
            const SizedBox(height: 12),
            const Text(
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
                    side: const BorderSide(color: Aether.hairlineStrong),
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
                style: const TextStyle(
                    fontSize: 11.5, color: Aether.textFaint)),
          ],
        ),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Setup screen — live simulated install log (proot-distro style).
// ---------------------------------------------------------------------------

class _Step {
  final String title;
  final double dur; // simulated seconds
  final List<(double, String)> events;
  const _Step(this.title, this.dur, this.events);
}

const _steps = [
  _Step('Checking device', 2.2, [
    (0.2, r'$ ovid sandbox --check'),
    (0.6, 'architecture ......... aarch64 ✓'),
    (1.0, 'android .............. 14 · API 34 ✓'),
    (1.4, 'storage .............. 38.2 GB free ✓'),
    (1.8, 'network .............. online ✓'),
  ]),
  _Step('Installing proot engine', 4.0, [
    (0.2, r'$ pkg install proot-distro'),
    (0.8, 'fetching proot 5.3.1 .................. 1.2 MB ✓'),
    (1.6, 'fetching proot-distro 3.12 ............ 18 KB ✓'),
    (2.4, 'unpacking packages ✓'),
    (3.2, 'proot engine ready ✓'),
  ]),
  _Step('Downloading Ubuntu 24.04 LTS', 9.0, [
    (0.2, r'$ proot-distro install ubuntu-24.04'),
    (8.5, 'rootfs downloaded ✓ 182.6 MB'),
  ]),
  _Step('Extracting rootfs', 5.5, [
    (0.2, 'extracting ubuntu-core-24.04-arm64.tar.xz'),
    (5.0, 'configuring base system ✓'),
  ]),
  _Step('First boot & user setup', 3.5, [
    (0.2, r'$ ovid sandbox --boot'),
    (0.8, 'creating user "ovid" ✓'),
    (1.6, 'locale en_US.UTF-8 ✓ · dns bridge ✓'),
    (2.6, 'ubuntu 24.04 LTS running ✓'),
  ]),
  _Step('Installing toolchain', 7.0, [
    (0.2, r'# apt update && apt install -y python3 nodejs git gcc make'),
    (2.0, 'setting up python3 3.12.3 ✓'),
    (3.0, 'setting up nodejs 20.14.0 ✓'),
    (4.0, 'setting up git 2.43.0 ✓'),
    (5.0, 'setting up gcc 13.2.0 ✓'),
    (6.0, 'setting up make 4.3 ✓'),
  ]),
  _Step('Verifying sandbox', 3.2, [
    (0.3, r'$ python3 --V   →  Python 3.12.3'),
    (1.0, r'$ node -v       →  v20.14.0'),
    (1.7, r'$ git --version →  git version 2.43.0'),
    (2.4, 'all checks passed ✓'),
  ]),
];

const _dlStepIndex = 2; // the big download step
const _dlTotalMb = 182.6;
const _totalDur = 34.4; // sum of step durations

class SandboxSetupScreen extends StatefulWidget {
  const SandboxSetupScreen({super.key});
  @override
  State<SandboxSetupScreen> createState() => _SandboxSetupScreenState();
}

class _SandboxSetupScreenState extends State<SandboxSetupScreen> {
  final _log = <String>[];
  final _scroll = ScrollController();
  Timer? _t;
  double _elapsed = 0;
  double _speed = 4.2;
  bool _done = false;
  final _rnd = Random();
  final List<int> _fired = List.filled(_steps.length, 0);
  bool _useSim = false; // true when real install can't run (e.g. desktop)

  int get _stepIdx {
    double t = 0;
    for (var i = 0; i < _steps.length; i++) {
      t += _steps[i].dur;
      if (_elapsed < t) return i;
    }
    return _steps.length - 1;
  }

  double get _stepT {
    double t = 0;
    for (var i = 0; i < _steps.length; i++) {
      if (_elapsed < t + _steps[i].dur) return _elapsed - t;
      t += _steps[i].dur;
    }
    return _steps.last.dur;
  }

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(milliseconds: 120), (_) => _tick());
    _runRealInstall();
  }

  Future<void> _runRealInstall() async {
    try {
      var lastPhase = -1;
      await SandboxService.I.install(onPhase: (phase, p, line) {
        if (!mounted || _done) return;
        if (phase != lastPhase) lastPhase = phase;
        setState(() {
          _elapsed = phase * (_totalDur / _steps.length) +
              p * (_totalDur / _steps.length);
          _log.add(line);
        });
      });
      if (!mounted) return;
      setState(() {
        _elapsed = _totalDur;
        _done = true;
        _t?.cancel();
        _log.add('sandbox ready ✓');
      });
      AppState.I.sandboxReady();
    } catch (e) {
      // Real install unavailable (dev machine / no proot exec) → simulate.
      debugPrint('real install failed: $e — falling back to simulation');
      if (!mounted) return;
      setState(() {
        _elapsed = 0;
        _log.clear();
        for (var i = 0; i < _fired.length; i++) {
          _fired[i] = 0;
        }
        _useSim = true;
      });
    }
  }

  @override
  void dispose() {
    _t?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _tick() {
    if (_done || !_useSim) return;
    setState(() {
      _elapsed = min(_elapsed + 0.12, _totalDur);
      // speed random-walk for the download ticker
      _speed = (_speed + (_rnd.nextDouble() - 0.5) * 0.5).clamp(1.8, 7.4);

      // fire log events for every step up to current
      double t = 0;
      for (var i = 0; i < _steps.length; i++) {
        final s = _steps[i];
        final stepElapsed = _elapsed - t;
        while (_fired[i] < s.events.length &&
            s.events[_fired[i]].$1 <= stepElapsed) {
          _log.add(s.events[_fired[i]].$2);
          _fired[i]++;
        }
        t += s.dur;
      }

      if (_elapsed >= _totalDur) {
        _done = true;
        _t?.cancel();
        _log.add('sandbox ready ✓');
        AppState.I.sandboxReady();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  String get _dlLine {
    final p = (_stepT / _steps[_dlStepIndex].dur).clamp(0.0, 1.0);
    final mb = _dlTotalMb * p;
    return 'downloading ubuntu-core ... '
        '${mb.toStringAsFixed(1)} / $_dlTotalMb MB '
        '(${_speed.toStringAsFixed(1)} MB/s)';
  }

  String get _eta {
    final remaining = (_totalDur - _elapsed) * 4.2; // feel like real minutes
    final s = remaining.round();
    return '~${(s ~/ 60)}:${(s % 60).toString().padLeft(2, '0')} left';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_done,
      child: Scaffold(
        backgroundColor: Aether.bg,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          title: const Text('Setting up sandbox'),
        ),
        body: SafeArea(child: _done ? _doneView() : _progressView()),
      ),
    );
  }

  Widget _progressView() {
    final step = _steps[_stepIdx];
    final overall = (_elapsed / _totalDur).clamp(0.0, 1.0);
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
              child: Text(step.title,
                  style: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w700)),
            ),
            Text('Step ${_stepIdx + 1} of ${_steps.length}',
                style: const TextStyle(
                    fontSize: 11, color: Aether.textFaint)),
          ]),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: overall, end: overall),
              duration: const Duration(milliseconds: 120),
              builder: (_, v, __) => LinearProgressIndicator(
                value: v,
                minHeight: 6,
                backgroundColor: Aether.surfaceAlt,
                valueColor: const AlwaysStoppedAnimation(Aether.accent),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Text('${(overall * 100).toStringAsFixed(0)}%',
                style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: Aether.accent)),
            const Spacer(),
            Text(_eta,
                style: const TextStyle(
                    fontSize: 11.5, color: Aether.textFaint)),
          ]),
          const SizedBox(height: 16),
          Expanded(child: _terminal()),
          const SizedBox(height: 12),
          const Text('Keep the app open — this happens only once.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: Aether.textFaint)),
        ],
      ),
    );
  }

  Widget _terminal() {
    final inDl = !_done && _stepIdx == _dlStepIndex && _stepT > 0.6;
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
            decoration: const BoxDecoration(
              color: Aether.surfaceAlt,
              border:
                  Border(bottom: BorderSide(color: Aether.hairline)),
            ),
            child: const Row(children: [
              Icon(Icons.terminal, size: 13, color: Aether.textMuted),
              SizedBox(width: 8),
              Text('SANDBOX SETUP LOG',
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: Aether.textMuted)),
              Spacer(),
              Icon(Icons.more_horiz, size: 14, color: Aether.textFaint),
            ]),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              itemCount: _log.length + (inDl ? 1 : 0),
              itemBuilder: (_, i) {
                if (inDl && i == _log.length) {
                  return Text(_dlLine,
                      style: const TextStyle(
                          fontFamily: Aether.mono,
                          fontSize: 11,
                          height: 1.6,
                          color: Aether.warn));
                }
                final l = _log[i];
                return Text(l,
                    style: TextStyle(
                        fontFamily: Aether.mono,
                        fontSize: 11,
                        height: 1.6,
                        color: _lineColor(l)));
              },
            ),
          ),
        ],
      ),
    );
  }

  Color _lineColor(String l) {
    if (l.startsWith(r'$') || l.startsWith('#')) return Aether.accent;
    if (l.endsWith('✓')) return Aether.success;
    if (l.contains('→')) return Aether.text;
    return Aether.textMuted;
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
              builder: (_, v, __) => Transform.scale(
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
            const Text(
              'Ubuntu 24.04 · python3 · node · git · gcc\nAll running privately on this device.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12.5, height: 1.6, color: Aether.textMuted),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: const [
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
              child: const Text('Back to chat',
                  style: TextStyle(fontSize: 12.5, color: Aether.textFaint)),
            ),
          ],
        ),
      ),
    );
  }
}
