import 'package:flutter/material.dart';

import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/usage_history.dart';
import 'package:ovid_ai/core/cloud_usage_store.dart';
import 'package:ovid_ai/core/format.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/core/usage_today.dart';
import 'package:ovid_ai/ui/billing_screen.dart';
import 'package:ovid_ai/ui/cloud_usage_status.dart';
import 'package:ovid_ai/ui/image_receipt_panel.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// Usage — detailed and server-authoritative (SH-016, SE-020, owner ask).
///
/// Two server sources, both shared by every device on the account:
///  * `POST /usage` ([CloudUsageStore]): the plan, the allowance left, its
///    reset time, the current window's requests/tokens/images, and the same
///    per model, plus each model's remaining-message estimate.
///  * `GET /cloud/v1/usage/history` ([UsageHistoryStore]): the worker's
///    per-model-call token ledger — per day, per model, per chat and per run
///    over 7/30/90 days.
///
/// No money is ever shown for usage (owner rule). A run's cost is expressed
/// as an estimated share of the allowance ("≈ 2% of allowance"), from the
/// model prices the server already sends with `/usage`.
class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key, this.history});

  /// Test seam; production builds one over [CloudRestClient.I].
  final UsageHistoryStore? history;

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  late final CloudUsageStore _store;
  late final UsageHistoryStore _history;

  @override
  void initState() {
    super.initState();
    _store = CloudUsageStore.acquire(AppState.I);
    _history = widget.history ?? UsageHistoryStore();
    _history.refresh();
  }

  @override
  void dispose() {
    _store.release();
    if (widget.history == null) _history.dispose();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    _store.refresh();
    await _history.refresh();
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
          // Reads the stores inside a builder so its enabled state is live
          // (SH-016).
          AnimatedBuilder(
            animation: Listenable.merge([_store, _history]),
            builder: (_, _) => IconButton(
              tooltip: 'Refresh usage',
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: _store.loading || _history.loading
                  ? null
                  : _refreshAll,
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        child: AnimatedBuilder(
          animation: Listenable.merge([_store, _history]),
          builder: (context, _) {
            final usage = _store.usage;
            final today = UsageToday.resolve(usage, UsageToday.empty);
            return ListView(
              key: const ValueKey('usage-list'),
              physics: const AlwaysScrollableScrollPhysics(),
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
                      'Your allowance is unavailable right now. Pull down to '
                      'refresh.',
                      style: AetherType.bodyMuted,
                    ),
                  )
                else ...[
                  _PlanCard(usage: usage),
                  const SizedBox(height: 12),
                  _WindowCard(usage: usage, today: today),
                  if (usage.perModel.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _RemainingByModelCard(usage: usage),
                  ],
                ],
                const SizedBox(height: 20),
                _HistorySection(store: _history, usage: usage),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Allowance-share estimate (no money on screen)
// ---------------------------------------------------------------------------

/// Estimated share of the allowance [input]/[output] tokens of [model] used,
/// from the per-token prices `/usage` sends and the window budget. Null when
/// the model's price is unknown (e.g. Auto) or the budget is not reported.
double? allowanceShare(OvidUsage? usage, String model, int input, int output) {
  if (usage == null || usage.dailyBudgetUsd <= 0) return null;
  OvidModelUsage? priced;
  for (final m in usage.models) {
    if (m.model == model) {
      priced = m;
      break;
    }
  }
  final inCost = priced?.inputCostPerToken;
  final outCost = priced?.outputCostPerToken;
  if (inCost == null && outCost == null) return null;
  final cost = input * (inCost ?? 0) + output * (outCost ?? 0);
  if (cost <= 0) return null;
  return cost / usage.dailyBudgetUsd;
}

String formatAllowanceShare(double share) {
  final pct = share * 100;
  if (pct < 0.1) return '< 0.1% of allowance';
  if (pct < 10) return '≈ ${pct.toStringAsFixed(1)}% of allowance';
  return '≈ ${pct.round()}% of allowance';
}

String _modelName(OvidUsage? usage, String id) {
  for (final m in usage?.models ?? const <OvidModelUsage>[]) {
    if (m.model == id) return m.label;
  }
  return ovidModelLabel(id);
}

String _tok(int n) => formatCompactCount(n);

// ---------------------------------------------------------------------------
// Plan + current window
// ---------------------------------------------------------------------------

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.usage});

  final OvidUsage usage;

  @override
  Widget build(BuildContext context) {
    final remaining = usage.remainingFraction;
    final pct = remaining == null
        ? null
        : (remaining * 100).clamp(0, 100).toStringAsFixed(0);
    final resetsAt = usage.resetsAt;
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
                  '${usage.displayPlanName} plan',
                  style: AetherType.h2,
                ),
              ),
              AetherPill(
                // The plan's name and multiplier, not the raw tier (SH-006).
                label: ovidMultiplierLabel(usage.multiplier),
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
          if (resetsAt != null) ...[
            const SizedBox(height: 8),
            Text(
              formatResetLabel(resetsAt),
              key: const ValueKey('usage-reset'),
              style: AetherType.caption,
            ),
          ],
          if (usage.window != null) ...[
            const SizedBox(height: 2),
            Text(
              'One allowance for every model, renewed every ${usage.window}.',
              style: AetherType.caption,
            ),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('usage-change-plan'),
              icon: const Icon(Icons.workspace_premium_outlined, size: 18),
              label: const Text('Change plan'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const BillingScreen()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WindowCard extends StatelessWidget {
  const _WindowCard({required this.usage, required this.today});

  final OvidUsage usage;
  final UsageToday today;

  @override
  Widget build(BuildContext context) {
    final byModel = usage.today?.byModel ?? const {};
    final rows = byModel.entries.toList()
      ..sort(
        (a, b) => (b.value.inputTokens + b.value.outputTokens).compareTo(
          a.value.inputTokens + a.value.outputTokens,
        ),
      );
    return AetherCard(
      key: const ValueKey('usage-today-card'),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('This allowance window', style: AetherType.h2),
          const SizedBox(height: 10),
          Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              _stat('Requests', '${today.requests}'),
              _stat('Input tokens', _tok(today.inputTokens)),
              _stat('Output tokens', _tok(today.outputTokens)),
              _stat('Images', '${today.images}'),
            ],
          ),
          if (rows.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('By model', style: AetherType.label),
            const SizedBox(height: 6),
            for (final e in rows)
              _BreakdownRow(
                key: ValueKey('usage-window-model-${e.key}'),
                title: _modelName(usage, e.key),
                detail:
                    '${e.value.requests} requests · ${_tok(e.value.inputTokens)} in · '
                    '${_tok(e.value.outputTokens)} out'
                    '${e.value.images > 0 ? ' · ${e.value.images} images' : ''}',
                share: allowanceShare(
                  usage,
                  e.key,
                  e.value.inputTokens,
                  e.value.outputTokens,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _RemainingByModelCard extends StatelessWidget {
  const _RemainingByModelCard({required this.usage});
  final OvidUsage usage;

  @override
  Widget build(BuildContext context) {
    return AetherCard(
      key: const ValueKey('usage-remaining-card'),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('What is left, per model', style: AetherType.h2),
          const SizedBox(height: 4),
          Text(
            'Estimated from each model\'s price; pricier models use the '
            'allowance faster.',
            style: AetherType.caption,
          ),
          const SizedBox(height: 8),
          for (final m in usage.perModel)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(child: Text(m.label, style: AetherType.body)),
                  Text(
                    m.remaining == null
                        ? '—'
                        : '${m.estimate == 'conservative' ? '≥ ' : '≈ '}'
                              '${m.remaining} ${m.isImage ? 'images' : 'messages'}',
                    style: AetherType.label,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// History (per day / model / chat / run)
// ---------------------------------------------------------------------------

class _HistorySection extends StatelessWidget {
  const _HistorySection({required this.store, required this.usage});

  final UsageHistoryStore store;
  final OvidUsage? usage;

  @override
  Widget build(BuildContext context) {
    final history = store.history;
    final children = <Widget>[
      Row(
        children: [
          Expanded(
            child: AetherSectionTitle(
              eyebrow: 'History',
              subtitle: 'Agent runs across all your devices.',
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          for (final d in const [7, 30, 90])
            ChoiceChip(
              key: ValueKey('usage-range-$d'),
              label: Text('$d days'),
              selected: store.days == d,
              onSelected: (_) => store.setDays(d),
            ),
        ],
      ),
      const SizedBox(height: 12),
    ];
    if (store.unsupported) {
      children.add(
        AetherCard(
          key: const ValueKey('usage-history-unsupported'),
          padding: const EdgeInsets.all(16),
          child: Text(
            'Detailed history is not available on Ovid Cloud yet. Your '
            'allowance above is up to date.',
            style: AetherType.bodyMuted,
          ),
        ),
      );
    } else if (history == null && store.loading) {
      children.add(
        const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator(strokeWidth: 1.6)),
        ),
      );
    } else if (history == null) {
      children.add(
        AetherCard(
          key: const ValueKey('usage-history-error'),
          padding: const EdgeInsets.all(16),
          child: Text(
            store.error ?? 'Usage history is unavailable right now.',
            style: AetherType.bodyMuted,
          ),
        ),
      );
    } else {
      if (store.error != null) {
        children.add(Text(store.error!, style: AetherType.caption));
      }
      children.addAll([
        _TotalsCard(history: history, days: store.days),
        const SizedBox(height: 12),
        _DailyCard(history: history),
        if (history.models.isNotEmpty) ...[
          const SizedBox(height: 12),
          _GroupCard(
            key: const ValueKey('usage-history-models'),
            title: 'By model',
            rows: [
              for (final m in history.models)
                _BreakdownRow(
                  title: _modelName(usage, m.model),
                  detail:
                      '${m.counts.runs} runs · ${m.counts.modelCalls} calls · '
                      '${_tok(m.counts.inputTokens)} in · '
                      '${_tok(m.counts.outputTokens)} out',
                  share: allowanceShare(
                    usage,
                    m.model,
                    m.counts.inputTokens,
                    m.counts.outputTokens,
                  ),
                ),
            ],
          ),
        ],
        if (history.sessions.isNotEmpty) ...[
          const SizedBox(height: 12),
          _GroupCard(
            key: const ValueKey('usage-history-sessions'),
            title: 'By chat',
            rows: [
              for (final s in history.sessions)
                _BreakdownRow(
                  title: s.title?.trim().isNotEmpty == true
                      ? s.title!
                      : 'Deleted chat',
                  detail:
                      '${s.counts.runs} runs · ${_tok(s.counts.totalTokens)} tokens'
                      '${s.lastAt == null ? '' : ' · last ${formatLocalDateTime(s.lastAt!)}'}',
                  onTap: s.title == null
                      ? null
                      : () => _openChat(context, s.sessionId),
                ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        _RunsCard(store: store, usage: usage),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

void _openChat(BuildContext context, String serverId) {
  String id = serverId;
  try {
    id = CloudSessionStore.I.resolveLocalSessionId(serverId);
  } catch (_) {}
  if (AppState.I.sessionById(id) == null) return;
  AppState.I.selectSession(id);
  Navigator.of(context).popUntil((route) => route.isFirst);
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.history, required this.days});
  final UsageHistory history;
  final int days;

  @override
  Widget build(BuildContext context) {
    final t = history.totals;
    return AetherCard(
      key: const ValueKey('usage-history-totals'),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Last $days days', style: AetherType.h2),
          const SizedBox(height: 10),
          Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              _stat('Runs', '${t.runs}'),
              _stat('Model calls', '${t.modelCalls}'),
              _stat('Input tokens', _tok(t.inputTokens)),
              _stat('Output tokens', _tok(t.outputTokens)),
              if (t.cacheReadTokens > 0)
                _stat('Cached input', _tok(t.cacheReadTokens)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Tokens per day: one series, one hue, thin rounded bars on a shared
/// baseline with a 2px gap; each bar has a tooltip and the list below is the
/// table view (dataviz rules).
class _DailyCard extends StatelessWidget {
  const _DailyCard({required this.history});
  final UsageHistory history;

  @override
  Widget build(BuildContext context) {
    final days = history.days.reversed.toList(); // oldest → newest
    final max = days.fold<int>(
      0,
      (m, d) => d.counts.totalTokens > m ? d.counts.totalTokens : m,
    );
    final active = history.days.where((d) => d.counts.modelCalls > 0).toList();
    return AetherCard(
      key: const ValueKey('usage-history-daily'),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Tokens per day', style: AetherType.h2),
          const SizedBox(height: 12),
          if (max == 0)
            Text('No agent runs in this period.', style: AetherType.bodyMuted)
          else ...[
            SizedBox(
              height: 96,
              child: LayoutBuilder(
                builder: (context, c) {
                  final barW =
                      ((c.maxWidth - 2 * (days.length - 1)) / days.length)
                          .clamp(1.0, 18.0);
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < days.length; i++) ...[
                        if (i > 0) const SizedBox(width: 2),
                        Tooltip(
                          message:
                              '${_dayLabel(days[i])}: ${_tok(days[i].counts.totalTokens)} tokens, '
                              '${days[i].counts.runs} runs',
                          child: Container(
                            width: barW,
                            height: days[i].counts.totalTokens == 0
                                ? 1
                                : (96 * days[i].counts.totalTokens / max).clamp(
                                    3.0,
                                    96.0,
                                  ),
                            decoration: BoxDecoration(
                              color: days[i].counts.totalTokens == 0
                                  ? Aether.hairline
                                  : Aether.accent,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(4),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(_dayLabel(days.first), style: AetherType.caption),
                const Spacer(),
                Text(_dayLabel(days.last), style: AetherType.caption),
              ],
            ),
            const SizedBox(height: 12),
            for (final d in active.take(14))
              _BreakdownRow(
                title: _dayLabel(d),
                detail:
                    '${d.counts.runs} runs · ${_tok(d.counts.inputTokens)} in · '
                    '${_tok(d.counts.outputTokens)} out',
              ),
          ],
        ],
      ),
    );
  }

  static String _dayLabel(UsageDay d) {
    final day = d.day;
    return day == null ? d.date : formatLocalDay(day);
  }
}

class _RunsCard extends StatelessWidget {
  const _RunsCard({required this.store, required this.usage});
  final UsageHistoryStore store;
  final OvidUsage? usage;

  @override
  Widget build(BuildContext context) {
    final runs = store.history?.runs ?? const <UsageRunRow>[];
    return AetherCard(
      key: const ValueKey('usage-history-runs'),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Recent runs', style: AetherType.h2),
          const SizedBox(height: 8),
          if (runs.isEmpty)
            Text('No agent runs in this period.', style: AetherType.bodyMuted),
          for (final r in runs)
            _BreakdownRow(
              key: ValueKey('usage-run-${r.runId}'),
              title: r.sessionTitle?.trim().isNotEmpty == true
                  ? r.sessionTitle!
                  : 'Deleted chat',
              detail: [
                if (r.startedAt != null) formatLocalDateTime(r.startedAt!),
                if (r.models.isNotEmpty)
                  r.models.map((m) => _modelName(usage, m)).join(', '),
                '${_tok(r.counts.inputTokens)} in · ${_tok(r.counts.outputTokens)} out',
                if (r.counts.modelCalls > 1) '${r.counts.modelCalls} calls',
                if (r.startedAt != null && r.finishedAt != null)
                  formatCompactDuration(r.finishedAt!.difference(r.startedAt!)),
                if (r.status != null && r.status != 'completed') r.status!,
              ].join(' · '),
              share: r.models.length == 1
                  ? allowanceShare(
                      usage,
                      r.models.single,
                      r.counts.inputTokens,
                      r.counts.outputTokens,
                    )
                  : null,
              onTap: r.sessionTitle == null
                  ? null
                  : () => _openChat(context, r.sessionId),
            ),
          if (store.history?.nextBefore != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('usage-runs-more'),
                onPressed: store.loadingMore ? null : store.loadMoreRuns,
                child: Text(store.loadingMore ? 'Loading…' : 'Show older runs'),
              ),
            ),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({super.key, required this.title, required this.rows});
  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) => AetherCard(
    padding: const EdgeInsets.all(18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AetherType.h2),
        const SizedBox(height: 8),
        ...rows,
      ],
    ),
  );
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    super.key,
    required this.title,
    required this.detail,
    this.share,
    this.onTap,
  });

  final String title;
  final String detail;
  final double? share;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final body = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AetherType.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(detail, style: AetherType.caption),
              ],
            ),
          ),
          if (share != null) ...[
            const SizedBox(width: 8),
            Text(formatAllowanceShare(share!), style: AetherType.label),
          ],
          if (onTap != null)
            Icon(Icons.chevron_right, size: 18, color: Aether.textFaint),
        ],
      ),
    );
    return onTap == null
        ? MergeSemantics(child: body)
        : InkWell(onTap: onTap, child: body);
  }
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
