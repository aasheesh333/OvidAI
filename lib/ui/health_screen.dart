import 'package:flutter/material.dart';
import '../core/health_service.dart';
import '../core/theme.dart';

/// Device health — a 0–100 capability score with a per-item breakdown of
/// exactly what's missing and why. Repair re-runs the sandbox runtime
/// installer (with apt TLS self-heal). Mirrors the DSH "diagnostics" view.
class HealthScreen extends StatefulWidget {
  const HealthScreen({super.key});
  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> {
  final List<String> _repairLog = [];
  bool _repairing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      HealthService.I.runChecks();
    });
  }

  Color _scoreColor(int s) => s >= 90
      ? Aether.success
      : s >= 70
      ? Aether.accent
      : s >= 45
      ? Aether.warn
      : Aether.dangerC;

  String _scoreLabel(int s) => s >= 90
      ? 'Everything works — full agent capabilities.'
      : s >= 70
      ? 'Mostly working — a few tools are unavailable.'
      : s >= 45
      ? 'Degraded — many agent tools will fail.'
      : 'Critical — the agent can barely run tools here.';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Device health'),
      ),
      body: AnimatedBuilder(
        animation: HealthService.I,
        builder: (_, _) {
          final report = HealthService.I.lastReport;
          final checking = HealthService.I.checking;
          if (report == null || checking) {
            return Center(
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
            );
          }
          final score = report.score;
          final color = _scoreColor(score);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
            children: [
              // ── Score header ──
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Aether.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Aether.hairline),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 74,
                      height: 74,
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
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _scoreLabel(score),
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              height: 1.35,
                              color: Aether.text,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${report.failed.length} of ${report.checks.length} check(s) failing',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: Aether.textFaint,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // ── Repair CTA (when a sandbox item fails) ──
              if (report.anyRepairable) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: color,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _repairing
                      ? null
                      : () async {
                          setState(() {
                            _repairing = true;
                            _repairLog.clear();
                          });
                          await HealthService.I.repair(
                            (l) => setState(() => _repairLog.add(l)),
                          );
                          if (mounted) setState(() => _repairing = false);
                        },
                  icon: Icon(
                    _repairing
                        ? Icons.hourglass_top_outlined
                        : Icons.build_circle_outlined,
                    size: 17,
                  ),
                  label: Text(
                    _repairing
                        ? 'Repairing… do not close'
                        : 'Repair — install missing packages (apt)',
                    style: const TextStyle(fontSize: 13.5),
                  ),
                ),
                if (_repairLog.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Aether.surfaceAlt,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Aether.hairline),
                    ),
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final l in _repairLog.reversed.toList())
                          Text(
                            l,
                            style: TextStyle(
                              fontFamily: Aether.mono,
                              fontSize: 11,
                              height: 1.5,
                              color: Aether.textMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],

              // ── Per-check list (every failure names its reason) ──
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
                child: Text(
                  'BREAKDOWN — why this score',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: Aether.textFaint,
                  ),
                ),
              ),
              for (final c in report.checks)
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Aether.surface,
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(color: Aether.hairline),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        c.ok ? Icons.check_circle_outline : Icons.error_outline,
                        size: 17,
                        color: c.ok ? Aether.success : Aether.dangerC,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              c.name,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Aether.text,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              c.detail,
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.4,
                                color: c.ok
                                    ? Aether.textFaint
                                    : Aether.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '+${c.points}',
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: Aether.mono,
                          color: c.ok ? Aether.success : Aether.textFaint,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              Center(
                child: TextButton.icon(
                  onPressed: HealthService.I.runChecks,
                  icon: Icon(Icons.refresh, size: 15, color: Aether.accent),
                  label: Text(
                    'Re-run checks',
                    style: TextStyle(fontSize: 12.5, color: Aether.accent),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
