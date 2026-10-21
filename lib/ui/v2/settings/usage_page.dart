// TODO(l10n): move the English copy in this screen to the ARB files.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/format.dart';
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'plan_billing_page.dart';
import 'usage_charts.dart';

enum V2UsageStatus { loading, ready, empty, error }

enum V2UsageRange { today, sevenDays, thirtyDays }

enum V2UsageTone { accent, success, warn }

@immutable
class V2UsageDay {
  const V2UsageDay({
    required this.id,
    required this.label,
    required this.fraction,
    this.valueLabel = '',
    this.tokens = 0,
    this.imageCount = 0,
  });

  final String id;
  final String label;

  /// Share of the tallest bar in the chart, 0..1.
  final double fraction;
  final String valueLabel;

  /// Absolute token count for the day. When zero the count is parsed from
  /// [valueLabel] (for example `8.2M tokens`), so older callers keep working.
  final int tokens;

  /// Image generations for the day. Zero means no image activity.
  final int imageCount;
}

@immutable
class V2UsageModel {
  const V2UsageModel({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.percent,
    required this.tokensLabel,
    this.tone = V2UsageTone.accent,
    this.providerLabel,
    this.isCustomProvider = false,
  });

  final String id;
  final String name;
  final String subtitle;
  final int percent;
  final String tokensLabel;
  final V2UsageTone tone;

  /// Provider name for custom connectors (`Ollama`, `OpenRouter`, …).
  final String? providerLabel;

  /// True when this row came from a user-added provider, not Ovid Cloud.
  final bool isCustomProvider;
}

@immutable
class V2UsageData {
  const V2UsageData({
    this.status = V2UsageStatus.ready,
    this.planId,
    this.dailyUsedLabel = '',
    this.dailyLimitLabel = '',
    this.dailyFraction = 0,
    this.dailyCapLabel = '',
    this.resetLabel = '',
    this.resetsAt,
    this.resetsAtLabel = '',
    this.monthlyUsedLabel = '',
    this.monthlyLimitLabel = '',
    this.monthlyFraction = 0,
    this.monthlyPercentLabel = '',
    this.monthlyCapLabel = '',
    this.billingNote = '',
    this.days = const [],
    this.historyLoading = false,
    this.selectedDayId,
    this.selectedDayLabel = '',
    this.models = const [],
    this.range = V2UsageRange.today,
    this.showFreePlanNote = true,
    this.requestsLabel = '',
    this.imagesLabel = '',
    this.imagesDetail = 'image generations',
    this.storageUsedLabel = '',
    this.storageLimitLabel = '',
    this.storageFraction = 0,
    this.upgradeTitle = 'Need more room?',
    this.upgradeMessage = 'Upgrade for higher limits and faster models.',
    this.upgradeLabel = 'Upgrade plan',
    this.onRangeChanged,
    this.onDaySelected,
    this.onStartChat,
    this.onUpgrade,
    this.onRetry,
    this.errorMessage = 'We could not load your usage.',
  });

  final V2UsageStatus status;

  /// Current plan id (`free`, `go`, `plus`, `pro` or a server tier alias).
  /// Selects the exact token caps from the authoritative plan table. When
  /// omitted, the plan is inferred from [storageLimitLabel] (the route already
  /// derives that from the live tier).
  final String? planId;
  final String dailyUsedLabel;
  final String dailyLimitLabel;

  /// The marker for a value the server has not reported. It is deliberately
  /// not `0`: a zero looks like real usage and hides a failed load.
  static const unknownLabel = '—';

  /// True when at least one real number was supplied. The page shows its
  /// empty state instead of a screen full of zeros when this is false.
  bool get hasData =>
      dailyUsedLabel.trim().isNotEmpty ||
      monthlyUsedLabel.trim().isNotEmpty ||
      requestsLabel.trim().isNotEmpty ||
      imagesLabel.trim().isNotEmpty ||
      days.isNotEmpty ||
      models.isNotEmpty;

  /// Display fallbacks: an unwired screen must never render "of  tokens used",
  /// and it must never invent a `0` for a value it does not have.
  String get usedText =>
      dailyUsedLabel.trim().isEmpty ? unknownLabel : dailyUsedLabel;

  /// The exact 24 h cap from the authoritative plan table when the caller did
  /// not supply one.
  String get limitText =>
      dailyLimitLabel.trim().isEmpty ? planLimits.dailyCapLabel : dailyLimitLabel;

  String get monthlyUsedText =>
      monthlyUsedLabel.trim().isEmpty ? unknownLabel : monthlyUsedLabel;

  String get monthlyLimitText => monthlyLimitLabel.trim().isEmpty
      ? planLimits.monthlyCapLabel
      : monthlyLimitLabel;

  String get monthlyPercentText => monthlyPercentLabel.trim().isEmpty
      ? unknownLabel
      : monthlyPercentLabel;
  final double dailyFraction;

  /// Overrides for the exact 24 h cap; empty derives it from [planId].
  final String dailyCapLabel;

  /// Optional pre-formatted countdown. Live data should pass [resetsAt]
  /// instead, so the countdown keeps ticking instead of freezing at the value
  /// computed when the route was built.
  final String resetLabel;

  /// When the current allowance window really resets, straight from the
  /// server's `resets_at`. The page derives and refreshes the countdown from
  /// this instant.
  final DateTime? resetsAt;

  /// Absolute reset time, e.g. `Oct 22, 2026, 6:12 AM`.
  final String resetsAtLabel;
  final String monthlyUsedLabel;
  final String monthlyLimitLabel;
  final double monthlyFraction;
  final String monthlyPercentLabel;

  /// Overrides for the exact 30 day cap; empty derives it from [planId].
  final String monthlyCapLabel;
  final String billingNote;
  final List<V2UsageDay> days;

  /// True while the daily ledger (`/usage/history`) is still loading. The
  /// charts show a skeleton instead of "no activity" in that window.
  final bool historyLoading;
  final String? selectedDayId;
  final String selectedDayLabel;
  final List<V2UsageModel> models;
  final V2UsageRange range;
  final bool showFreePlanNote;
  final String requestsLabel;
  final String imagesLabel;
  final String imagesDetail;
  final String storageUsedLabel;
  final String storageLimitLabel;
  final double storageFraction;
  final String upgradeTitle;
  final String upgradeMessage;
  final String upgradeLabel;
  final ValueChanged<V2UsageRange>? onRangeChanged;
  final ValueChanged<V2UsageDay>? onDaySelected;
  final VoidCallback? onStartChat;
  final VoidCallback? onUpgrade;
  final VoidCallback? onRetry;
  final String errorMessage;

  V2PlanLimits get planLimits {
    final byId = planId == null ? null : V2PlanLimits.forId(planId!);
    if (byId != null) return byId;
    final gb = int.tryParse(storageLimitLabel.split(' ').first);
    return V2PlanLimits.forStorageGb(gb) ?? V2PlanLimits.free;
  }

  String get effectiveDailyCapLabel =>
      dailyCapLabel.isNotEmpty ? dailyCapLabel : planLimits.dailyCapLabel;

  String get effectiveMonthlyCapLabel =>
      monthlyCapLabel.isNotEmpty ? monthlyCapLabel : planLimits.monthlyCapLabel;

  int get customProviderCount =>
      models.where((model) => model.isCustomProvider).length;
}

class UsagePage extends StatelessWidget {
  const UsagePage({super.key, required this.data});

  final V2UsageData data;

  @override
  Widget build(BuildContext context) {
    final Widget body;
    switch (data.status) {
      case V2UsageStatus.loading:
        body = const OSkeletonList(rows: 6);
      case V2UsageStatus.error:
        body = OErrorState(message: data.errorMessage, onRetry: data.onRetry);
      case V2UsageStatus.empty:
        body = _emptyState(context);
      case V2UsageStatus.ready:
        // A ready page with no real numbers would render zeros that look like
        // usage. Show the honest empty state instead.
        body = data.hasData ? _content(context) : _emptyState(context);
    }

    return OScaffold(
      appBar: const OAppBar(title: 'Usage'),
      body: OFadeSlide(child: body),
    );
  }

  Widget _emptyState(BuildContext context) {
    // Only offer the action that is actually wired: a "Start a chat" button
    // that silently retries the fetch is a fake control.
    final Widget? action;
    if (data.onStartChat != null) {
      action = OButton(
        label: 'Start a chat',
        icon: Icons.chat_bubble_outline_rounded,
        onPressed: data.onStartChat,
      );
    } else if (data.onRetry != null) {
      action = OButton(
        label: 'Try again',
        icon: Icons.refresh_rounded,
        onPressed: data.onRetry,
      );
    } else {
      action = null;
    }
    return OEmptyState(
      icon: Icons.insights_rounded,
      title: 'No usage yet',
      message: 'Chat with Ovid to see your token use here.',
      action: action,
    );
  }

  Widget _content(BuildContext context) {
    final c = OColors.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DailyRingCard(data: data),
          const SizedBox(height: OSpace.m),
          _MonthlyCard(data: data),
          const SizedBox(height: OSpace.m),
          _GlanceCard(data: data),
          const SizedBox(height: OSpace.m),
          _DailyTokensSection(data: data),
          const SizedBox(height: OSpace.m),
          _ModelShareSection(data: data),
          const SizedBox(height: OSpace.m),
          _ImageUsageSection(data: data),
          if (data.showFreePlanNote) ...[
            const SizedBox(height: OSpace.m),
            OCard(
              padding: const EdgeInsets.all(OSpace.l),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: c.accentSoft,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: c.accent,
                    ),
                  ),
                  const SizedBox(width: OSpace.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Free and Go use Auto mode only.',
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Manual models unlock with Plus or Pro.',
                          style: OType.caption.copyWith(color: c.textFaint),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (data.onUpgrade != null) ...[
            const SizedBox(height: OSpace.m),
            _UpgradeCard(data: data),
          ],
        ],
      ),
    );
  }
}

class _DailyRingCard extends StatelessWidget {
  const _DailyRingCard({required this.data});

  final V2UsageData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final fraction = data.dailyFraction.clamp(0.0, 1.0).toDouble();
    return OCard(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.l,
        vertical: OSpace.xl,
      ),
      child: Column(
        children: [
          Semantics(
            label: data.dailyUsedLabel.trim().isEmpty
                ? 'Today\'s token usage is not available. '
                      'The limit is ${data.limitText} tokens.'
                : '${data.usedText} of ${data.limitText} tokens used today',
            child: ConstrainedBox(
              // The ring keeps its 208 dp look but grows with the text scale
              // instead of clipping the labels inside it.
              constraints: const BoxConstraints(minWidth: 208, minHeight: 208),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: fraction),
                      duration: OMove.duration(context, OMotion.slow),
                      curve: OMotion.emphasized,
                      builder: (context, value, _) => Center(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: CircularProgressIndicator(
                            value: value,
                            strokeWidth: 14,
                            strokeCap: StrokeCap.round,
                            backgroundColor: c.surfaceRaised,
                            color: c.accentFill,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(OSpace.xl),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'TOKENS TODAY',
                          textAlign: TextAlign.center,
                          style: OType.overline.copyWith(color: c.success),
                        ),
                        const SizedBox(height: OSpace.xs),
                        Text(
                          data.usedText,
                          textAlign: TextAlign.center,
                          style: OType.display.copyWith(
                            color: c.text,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: OSpace.xs),
                        Text(
                          'of ${data.limitText} tokens used',
                          textAlign: TextAlign.center,
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: OSpace.l),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${data.usedText} used',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
              const SizedBox(width: OSpace.s),
              Flexible(
                child: Text(
                  '${data.limitText} limit',
                  textAlign: TextAlign.right,
                  style: OType.caption.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          OProgressBar(value: fraction, height: 8),
          const SizedBox(height: OSpace.s),
          Text(
            'Daily cap ${data.effectiveDailyCapLabel} tokens / 24 h',
            textAlign: TextAlign.center,
            style: OType.caption.copyWith(color: c.textMuted),
          ),
          if (data.resetsAtLabel.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              'Resets at ${data.resetsAtLabel}',
              textAlign: TextAlign.center,
              style: OType.caption.copyWith(color: c.textFaint),
            ),
          ],
          if (data.resetsAt != null || data.resetLabel.isNotEmpty) ...[
            const SizedBox(height: OSpace.l),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.m,
                vertical: OSpace.s,
              ),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(ORadius.pill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.schedule_rounded, size: 16, color: c.accent),
                  const SizedBox(width: 6),
                  Flexible(
                    child: _ResetCountdown(
                      resetsAt: data.resetsAt,
                      fallback: data.resetLabel,
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Live countdown to the allowance reset.
///
/// The route passes the server's `resets_at` instant, so the label is derived
/// from the real window and keeps ticking. A pre-formatted [fallback] is only
/// used by previews/tests that have no clock source.
class _ResetCountdown extends StatefulWidget {
  const _ResetCountdown({
    required this.resetsAt,
    required this.fallback,
    required this.style,
  });

  final DateTime? resetsAt;
  final String fallback;
  final TextStyle style;

  @override
  State<_ResetCountdown> createState() => _ResetCountdownState();
}

class _ResetCountdownState extends State<_ResetCountdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(_ResetCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetsAt != widget.resetsAt) _syncTimer();
  }

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    if (widget.resetsAt == null) return;
    // Minute resolution is all the copy shows, so one tick a minute is enough
    // and keeps the page from waking the device every second.
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final resetsAt = widget.resetsAt;
    final label = resetsAt == null
        ? widget.fallback
        : 'Resets ${formatTimeUntil(resetsAt)}';
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: widget.style,
    );
  }
}

class _MonthlyCard extends StatelessWidget {
  const _MonthlyCard({required this.data});

  final V2UsageData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      padding: const EdgeInsets.all(OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Icon(
                  Icons.calendar_month_rounded,
                  size: 19,
                  color: c.accent,
                ),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Monthly quota',
                      style: OType.bodySm.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      data.billingNote,
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
              OPill(label: data.monthlyPercentText, tone: OPillTone.accent),
            ],
          ),
          const SizedBox(height: OSpace.m),
          OProgressBar(value: data.monthlyFraction, height: 8),
          const SizedBox(height: OSpace.s),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${data.monthlyUsedText} used',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
              const SizedBox(width: OSpace.s),
              Flexible(
                child: Text(
                  '${data.monthlyLimitText} limit',
                  textAlign: TextAlign.right,
                  style: OType.caption.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          Text(
            'Monthly cap ${data.effectiveMonthlyCapLabel} tokens / 30 days',
            style: OType.caption.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: 2),
          Text(
            '${data.planLimits.autoAllowanceLabel} · '
            '${data.planLimits.modelAccessLabel}',
            style: OType.caption.copyWith(color: c.textFaint),
          ),
        ],
      ),
    );
  }
}

class _GlanceCard extends StatelessWidget {
  const _GlanceCard({required this.data});

  final V2UsageData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      padding: const EdgeInsets.all(OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'This month at a glance',
            padding: EdgeInsets.zero,
          ),
          const SizedBox(height: OSpace.m),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _GlanceStat(
                  label: 'Requests',
                  value: data.requestsLabel.trim().isEmpty
                      ? V2UsageData.unknownLabel
                      : data.requestsLabel,
                ),
              ),
              Container(
                width: 1,
                height: 40,
                margin: const EdgeInsets.symmetric(horizontal: OSpace.m),
                color: c.hairline,
              ),
              Expanded(
                child: _GlanceStat(
                  label: 'Images',
                  value: data.imagesLabel.trim().isEmpty
                      ? V2UsageData.unknownLabel
                      : data.imagesLabel,
                  detail: data.imagesDetail,
                ),
              ),
              Container(
                width: 1,
                height: 40,
                margin: const EdgeInsets.symmetric(horizontal: OSpace.m),
                color: c.hairline,
              ),
              Expanded(
                child: _GlanceStat(
                  label: 'Storage',
                  value: data.storageUsedLabel.trim().isEmpty
                      ? V2UsageData.unknownLabel
                      : data.storageUsedLabel,
                  detail: data.storageUsedLabel.trim().isEmpty
                      ? 'Not tracked yet'
                      : 'of ${data.storageLimitLabel}',
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          OProgressBar(value: data.storageFraction, height: 6),
        ],
      ),
    );
  }
}

class _GlanceStat extends StatelessWidget {
  const _GlanceStat({required this.label, required this.value, this.detail});

  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: OType.caption.copyWith(color: c.textMuted)),
        const SizedBox(height: OSpace.xs),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: OType.h3.copyWith(color: c.text),
        ),
        if (detail != null) ...[
          const SizedBox(height: 2),
          Text(detail!, style: OType.caption.copyWith(color: c.textFaint)),
        ],
      ],
    );
  }
}

class _UpgradeCard extends StatelessWidget {
  const _UpgradeCard({required this.data});

  final V2UsageData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      accent: true,
      padding: const EdgeInsets.all(OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.arrow_upward_rounded,
                  size: 19,
                  color: c.accent,
                ),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.upgradeTitle,
                      style: OType.h3.copyWith(color: c.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      data.upgradeMessage,
                      style: OType.bodySm.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          OButton(
            label: data.upgradeLabel,
            icon: Icons.workspace_premium_outlined,
            expand: true,
            onPressed: data.onUpgrade,
          ),
        ],
      ),
    );
  }
}

/// Daily token bars. The page's [V2UsageDay] list is the single source of
/// truth; the chart only renders it and reports a range change.
class _DailyTokensSection extends StatelessWidget {
  const _DailyTokensSection({required this.data});

  final V2UsageData data;

  @override
  Widget build(BuildContext context) {
    final range = data.range == V2UsageRange.thirtyDays
        ? V2UsageChartRange.thirtyDays
        : V2UsageChartRange.sevenDays;
    final onRangeChanged = data.onRangeChanged;
    return V2DailyTokensChart(
      key: const ValueKey('usage-daily-tokens-chart'),
      title: 'Activity',
      points: [for (final day in data.days) _tokenPoint(day)],
      range: range,
      status: data.historyLoading
          ? V2UsageChartStatus.loading
          : V2UsageChartStatus.ready,
      onRangeChanged: onRangeChanged == null
          ? null
          : (value) => onRangeChanged(
              value == V2UsageChartRange.thirtyDays
                  ? V2UsageRange.thirtyDays
                  : V2UsageRange.sevenDays,
            ),
      onStartChat: data.onStartChat,
      onRetry: data.onRetry,
    );
  }
}

/// Model share. Custom-provider models keep their explanatory line above the
/// chart, while the chart owns the split bar and the legend.
class _ModelShareSection extends StatelessWidget {
  const _ModelShareSection({required this.data});

  final V2UsageData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (data.customProviderCount > 0) ...[
          Text(
            data.customProviderCount == 1
                ? 'Includes 1 custom provider model.'
                : 'Includes ${data.customProviderCount} custom provider models.',
            style: OType.caption.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: OSpace.s),
        ],
        V2ModelShareChart(
          key: const ValueKey('usage-model-share-chart'),
          title: 'Usage by model',
          status: data.historyLoading
              ? V2UsageChartStatus.loading
              : V2UsageChartStatus.ready,
          slices: [
            for (final model in data.models)
              V2ModelShareSlice(
                id: model.id,
                label: model.name,
                percent: model.percent.toDouble(),
                valueLabel: model.tokensLabel.isNotEmpty
                    ? model.tokensLabel
                    : model.subtitle,
              ),
          ],
          onStartChat: data.onStartChat,
          onRetry: data.onRetry,
        ),
      ],
    );
  }
}

/// Daily image generations, mapped from the same day list.
class _ImageUsageSection extends StatelessWidget {
  const _ImageUsageSection({required this.data});

  final V2UsageData data;

  @override
  Widget build(BuildContext context) {
    // `/usage/history` has no per-day image counts. When today's counter is
    // known but the series is not, say so instead of claiming "No images yet".
    final hasDailySeries = data.days.any((day) => day.imageCount > 0);
    final imagesToday = int.tryParse(data.imagesLabel.trim()) ?? 0;
    final missingSeries = imagesToday > 0 && !hasDailySeries;
    return V2ImageUsageChart(
      key: const ValueKey('usage-image-chart'),
      title: 'Images generated',
      status: data.historyLoading
          ? V2UsageChartStatus.loading
          : V2UsageChartStatus.ready,
      emptyTitle: missingSeries
          ? 'Daily image history is not available'
          : 'No images yet',
      emptyMessage: missingSeries
          ? 'Today\'s image count is shown above; the per-day series is not '
                'reported yet.'
          : 'Images you generate will show up here.',
      points: [
        for (final day in data.days)
          V2ImageUsagePoint(
            id: day.id,
            label: day.label,
            count: day.imageCount,
            valueLabel:
                '${day.imageCount} '
                '${day.imageCount == 1 ? 'image' : 'images'}',
          ),
      ],
      onStartChat: data.onStartChat,
      onRetry: data.onRetry,
    );
  }
}

V2TokenChartPoint _tokenPoint(V2UsageDay day) {
  final parsed = day.tokens > 0
      ? day.tokens.toDouble()
      : _tokensFromLabel(day.valueLabel);
  return V2TokenChartPoint(
    id: day.id,
    label: day.label,
    // A day without an absolute count still keeps its relative height.
    value: parsed > 0 ? parsed : day.fraction * 1000000,
    valueLabel: day.valueLabel,
  );
}

/// Reads `8.2M tokens`, `950K` or `12,400` into an absolute token count.
double _tokensFromLabel(String label) {
  final match = RegExp(
    r'([0-9]+(?:\.[0-9]+)?)\s*([KMB])?',
    caseSensitive: false,
  ).firstMatch(label.replaceAll(',', ''));
  if (match == null) return 0;
  final number = double.tryParse(match.group(1) ?? '') ?? 0;
  return switch ((match.group(2) ?? '').toUpperCase()) {
    'K' => number * 1000,
    'M' => number * 1000000,
    'B' => number * 1000000000,
    _ => number,
  };
}
