import 'package:flutter/material.dart';

import 'package:ovid_ai/core/cloud_usage_store.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/core/usage_today.dart';
import 'package:ovid_ai/ui/cloud_usage_status.dart';
import 'package:ovid_ai/ui/image_receipt_panel.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// Usage — the server-authoritative Ovid Cloud allowance.
///
/// Device-local accounting died with the agent-core satellite strip (P8
/// Task 18). This screen reads ONLY `GET /usage` (through [CloudUsageStore]);
/// `usage_today.dart` resolves the server's `today` counters. There is no
/// per-provider local journal left to render.
class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key});

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  late final CloudUsageStore _store;

  @override
  void initState() {
    super.initState();
    _store = CloudUsageStore.acquire(AppState.I);
  }

  @override
  void dispose() {
    _store.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Usage'),
        actions: [
          IconButton(
            tooltip: 'Image receipts',
            icon: const Icon(Icons.receipt_long_outlined, size: 20),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ImageReceiptsScreen(),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Refresh usage',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _store.loading ? null : _store.refresh,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _store,
        builder: (context, _) {
          final usage = _store.usage;
          final today = UsageToday.resolve(usage, UsageToday.empty);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
            children: [
              CloudUsageStatus(store: _store),
              const SizedBox(height: 10),
              if (usage == null && _store.loading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  ),
                )
              else if (usage == null)
                AetherCard(
                  padding: const EdgeInsets.all(18),
                  child: Text(
                    'Usage is unavailable right now. Pull to refresh or try '
                    'again shortly.',
                    style: AetherType.bodyMuted,
                  ),
                )
              else ...[
                _PlanCard(usage: usage),
                const SizedBox(height: 12),
                _TodayCard(today: today),
                const SizedBox(height: 12),
                AetherCard(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Server-authoritative', style: AetherType.title),
                      const SizedBox(height: 6),
                      Text(
                        'Allowance and today\'s counters come from Ovid Cloud '
                        'and include every device on your account. This build '
                        'keeps no on-device usage journal.',
                        style: AetherType.bodyMuted.copyWith(height: 1.5),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.usage});

  final OvidUsage usage;

  @override
  Widget build(BuildContext context) {
    final remaining = usage.remainingFraction;
    final pct = remaining == null
        ? null
        : (remaining * 100).clamp(0, 100).toStringAsFixed(0);
    return AetherCard(
      key: const ValueKey('usage-plan-card'),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  usage.isPaid ? 'Ovid Cloud plan' : 'Ovid Cloud free',
                  style: AetherType.h2,
                ),
              ),
              AetherPill(
                label: usage.tier.toUpperCase(),
                color: usage.isPaid ? Aether.accent : Aether.textMuted,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            pct == null ? 'Allowance shared across models' : '$pct% remaining',
            style: AetherType.title,
          ),
          if (remaining != null) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: remaining.clamp(0, 1),
              minHeight: 6,
              backgroundColor: Aether.surfaceAlt,
              valueColor: AlwaysStoppedAnimation<Color>(Aether.accent),
            ),
          ),
          ],
          if (usage.resetsAt != null) ...[
            const SizedBox(height: 8),
            Text(
              'Resets ${usage.resetsAt!.toLocal()}',
              style: AetherType.caption,
            ),
          ],
        ],
      ),
    );
  }
}

class _TodayCard extends StatelessWidget {
  const _TodayCard({required this.today});

  final UsageToday today;

  @override
  Widget build(BuildContext context) {
    return AetherCard(
      key: const ValueKey('usage-today-card'),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Today', style: AetherType.h2),
          const SizedBox(height: 10),
          Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              _stat('Requests', '${today.requests}'),
              _stat('Input tokens', _fmtTok(today.inputTokens)),
              _stat('Output tokens', _fmtTok(today.outputTokens)),
              _stat('Images', '${today.images}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => SizedBox(
        width: 110,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: AetherType.caption),
            const SizedBox(height: 2),
            Text(value, style: AetherType.title),
          ],
        ),
      );
}

String _fmtTok(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

/// Route hosting the account-scoped [ImageReceiptPanel], reachable from the
/// Usage app bar menu. The panel is read-only: status checks are GET
/// recoveries against the saved request identity and never submit new paid
/// image work. Bound to the singleton studio and the current cloud key.
class ImageReceiptsScreen extends StatelessWidget {
  const ImageReceiptsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Image receipts'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
        children: [
          ImageReceiptPanel(
            studio: ImageStudio.I,
            headers: OvidCloudService.I.imageHeaders,
            sessionTitle: (id) => AppState.I.sessionById(id)?.title,
            onOpenSession: (id) {
              if (AppState.I.sessionById(id) == null) return;
              AppState.I.selectSession(id);
              Navigator.of(context).popUntil((route) => route.isFirst);
            },
          ),
        ],
      ),
    );
  }
}
