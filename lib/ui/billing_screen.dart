import 'package:flutter/material.dart';

import '../core/firebase_service.dart';
import '../core/ovid_cloud_service.dart';
import '../core/state.dart';
import '../core/theme.dart';

/// Billing / Plan screen — opencode/ChatGPT-style.
///
/// Shows the user's current Ovid Cloud plan, what each plan offers, and
/// (for paid plans) server-authoritative usage. Free tier is Zen: no numbers,
/// just the plan + an upgrade call-to-action. Payment is not wired yet — the
/// upgrade buttons explain pricing and that checkout is coming.
class BillingScreen extends StatefulWidget {
  const BillingScreen({super.key});

  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

class _PlanOption {
  const _PlanOption(
    this.tier,
    this.title,
    this.price,
    this.blurb,
    this.multiplier,
  );
  final String tier;
  final String title;
  final String price;
  final String blurb;
  final String multiplier;
}

const _plans = <_PlanOption>[
  _PlanOption(
    'free',
    'Free',
    '₹0',
    'Daily free limit. Just chat — no card needed.',
    '1x',
  ),
  _PlanOption(
    '5x',
    'Plus',
    '₹499',
    '5× the daily limit. Resets every 24 hours.',
    '5x',
  ),
  _PlanOption(
    '10x',
    'Pro',
    '₹899',
    '10× the daily limit. Resets every 24 hours.',
    '10x',
  ),
  _PlanOption(
    '20x',
    'Max',
    '₹1699',
    '20× the daily limit. Resets every 24 hours.',
    '20x',
  ),
];

class _BillingScreenState extends State<BillingScreen> {
  OvidUsage? _usage;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final u = await OvidCloudService.I.fetchUsage();
    if (!mounted) return;
    setState(() {
      _usage = u;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Plan & Billing'),
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([app, FirebaseService.I]),
        builder: (_, _) {
          final tier = _usage?.tier ?? app.ovidCloudTier;
          final isPaid = _usage?.isPaid ?? app.ovidCloudIsPaid;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
            children: [
              _currentPlanCard(tier, isPaid),
              const SizedBox(height: 20),
              Text(
                'PLANS',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                  color: Aether.textFaint,
                ),
              ),
              const SizedBox(height: 10),
              for (final p in _plans) _planTile(p, tier),
              const SizedBox(height: 16),
              Text(
                'Prices shown for reference. In-app checkout is coming soon — '
                'your plan and limits update automatically once you subscribe.',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: Aether.textFaint,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _currentPlanCard(String tier, bool isPaid) {
    final plan = _plans.firstWhere(
      (p) => p.tier == tier,
      orElse: () => _plans.first,
    );
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Aether.accent.withValues(alpha: 0.16), Aether.surface],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Aether.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Current plan',
                style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: isPaid ? Aether.accent : Aether.surfaceAlt,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  plan.title.toUpperCase(),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: isPaid ? Colors.white : Aether.textMuted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            plan.title,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Aether.text,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            plan.blurb,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: Aether.textMuted,
            ),
          ),
          if (_loading) ...[
            const SizedBox(height: 14),
            const SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ] else if (isPaid && _usage != null) ...[
            const SizedBox(height: 16),
            _usageBar(_usage!),
          ],
        ],
      ),
    );
  }

  Widget _usageBar(OvidUsage u) {
    final pct = u.dailyBudgetUsd <= 0
        ? 0.0
        : (u.dailySpentUsd / u.dailyBudgetUsd).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 8,
            backgroundColor: Aether.surfaceAlt,
            valueColor: AlwaysStoppedAnimation(
              pct > 0.9 ? Aether.danger : Aether.accent,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '\$${u.dailySpentUsd.toStringAsFixed(2)} used of '
          '\$${u.dailyBudgetUsd.toStringAsFixed(2)} today · '
          '${u.requestsToday} requests · resets every 24h',
          style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
        ),
      ],
    );
  }

  Widget _planTile(_PlanOption p, String currentTier) {
    final current = p.tier == currentTier;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Aether.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: current ? Aether.accent : Aether.hairline,
          width: current ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    p.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Aether.text,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Aether.surfaceAlt,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      p.multiplier,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: Aether.accent,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                p.blurb,
                style: TextStyle(fontSize: 11.5, color: Aether.textMuted),
              ),
            ],
          ),
          const Spacer(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                p.price,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Aether.text,
                ),
              ),
              if (p.tier != 'free')
                Text(
                  '/ 24h',
                  style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
                ),
              const SizedBox(height: 6),
              if (current)
                Text(
                  'Current',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Aether.accent,
                  ),
                )
              else if (p.tier != 'free')
                _UpgradeButton(plan: p),
            ],
          ),
        ],
      ),
    );
  }
}

class _UpgradeButton extends StatelessWidget {
  const _UpgradeButton({required this.plan});
  final _PlanOption plan;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: Aether.accent,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        minimumSize: const Size(0, 32),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onPressed: () {
        showModalBottomSheet<void>(
          context: context,
          backgroundColor: Aether.surface,
          builder: (_) => Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Upgrade to ${plan.title}',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: Aether.text,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${plan.price} / 24h · ${plan.blurb}',
                  style: TextStyle(fontSize: 13, color: Aether.textMuted),
                ),
                const SizedBox(height: 16),
                Text(
                  'In-app checkout is coming soon. Once you subscribe, your '
                  'plan and daily limit update automatically — no app update '
                  'needed.',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: Aether.textFaint,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Aether.accent,
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Got it'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
      child: const Text('Upgrade', style: TextStyle(fontSize: 12.5)),
    );
  }
}
