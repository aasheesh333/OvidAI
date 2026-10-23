// TODO(l10n): move the English copy in this screen to the ARB files.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/format.dart';
import '../../design/o_components.dart';
import '../../design/o_screen.dart';
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
  });

  final String id;
  final String label;

  /// Share of the tallest bar in the chart, 0..1.
  final double fraction;
  final String valueLabel;

  /// Absolute token count for the day. When zero the count is parsed from
  /// [valueLabel] (for example `8.2M tokens`), so older callers keep working.
  final int tokens;
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
  });

  final String id;
  final String name;
  final String subtitle;
  final int percent;
  final String tokensLabel;
  final V2UsageTone tone;
}

@immutable
class V2UsageData {
  const V2UsageData({
    this.status = V2UsageStatus.ready,
    this.planId,
    this.dailyUsedLabel = '',
    this.dailyLimitLabel = '',
    this.dailyFraction = 0,
    this.resetLabel = '',
    this.resetsAt,
    this.resetsAtLabel = '',
    this.monthlyUsedLabel = '',
    this.monthlyLimitLabel = '',
    this.days = const [],
    this.historyLoading = false,
    this.models = const [],
    this.range = V2UsageRange.today,
    this.requestsLabel = '',
    this.imagesLabel = '',
    this.storageLimitLabel = '',
    this.onRangeChanged,
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
  /// not supply one. Empty when the plan has no token cap (paid plans are not
  /// token-capped), so the page never paints a cap that is not enforced.
  String get limitText {
    final supplied = dailyLimitLabel.trim();
    if (supplied.isNotEmpty) return supplied;
    final cap = planLimits.dailyTokenCap;
    return cap == null || cap <= 0 ? '' : _compactCap(cap);
  }

  String get monthlyUsedText =>
      monthlyUsedLabel.trim().isEmpty ? unknownLabel : monthlyUsedLabel;

  /// The exact 30 day cap, compact. A caller-supplied label wins; otherwise the
  /// plan table is the only source of truth. Empty for a plan with no cap.
  String get monthlyLimitText {
    final supplied = monthlyLimitLabel.trim();
    if (supplied.isNotEmpty) return supplied;
    final cap = planLimits.monthlyTokenCap;
    return cap == null || cap <= 0 ? '' : _compactCap(cap);
  }

  /// The account's request and image counters for today, straight from
  /// `/usage`'s `today` object (`requests`, `images`). Empty when the server
  /// reported neither, so the line is omitted rather than showing a zero that
  /// looks like real usage.
  String get countersText {
    final parts = <String>[
      if (requestsLabel.trim().isNotEmpty) '${requestsLabel.trim()} requests',
      if (imagesLabel.trim().isNotEmpty) '${imagesLabel.trim()} images',
    ];
    return parts.isEmpty ? '' : '${parts.join(' · ')} today';
  }

  final double dailyFraction;

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
  final List<V2UsageDay> days;

  /// True while the daily ledger (`/usage/history`) is still loading. The
  /// charts show a skeleton instead of "no activity" in that window.
  final bool historyLoading;
  final List<V2UsageModel> models;
  final V2UsageRange range;
  final String requestsLabel;
  final String imagesLabel;
  final String storageLimitLabel;
  final ValueChanged<V2UsageRange>? onRangeChanged;
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
}

class UsagePage extends StatelessWidget {
  const UsagePage({super.key, required this.data, this.clock});

  final V2UsageData data;

  /// Clock source for the reset countdown. Defaults to [DateTime.now]; tests
  /// inject one so a tick can be proven without waiting a real minute.
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    final Widget body;
    switch (data.status) {
      case V2UsageStatus.loading:
        body = const OSkeletonList(rows: 6);
      case V2UsageStatus.error:
        body = OErrorState(message: data.errorMessage, onRetry: data.onRetry);
      case V2UsageStatus.empty:
        body = _emptyState();
      case V2UsageStatus.ready:
        // A ready page with no real numbers would render zeros that look like
        // usage. Show the honest empty state instead.
        body = data.hasData ? _content(context) : _emptyState();
    }

    return OScreen(
      title: 'Usage',
      actions: [
        if (data.onUpgrade != null)
          OIconButton(
            key: const ValueKey<String>('usage-upgrade'),
            icon: Icons.workspace_premium_outlined,
            semanticLabel: 'Upgrade plan',
            tooltip: 'Upgrade plan',
            onPressed: data.onUpgrade,
          ),
      ],
      child: body,
    );
  }

  Widget _emptyState() {
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
      message: 'Chat to see token use.',
      action: action,
    );
  }

  Widget _content(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _UsageHero(data: data, clock: clock),
          const SizedBox(height: OSpace.l),
          _DailyTokensSection(data: data),
        ],
      ),
    );
  }
}

/// One hero number: today's tokens, the cap and the live reset, with the
/// 30 day allowance and today's request/image counters as captions underneath.
/// Everything else on the screen is the single activity chart.
class _UsageHero extends StatelessWidget {
  const _UsageHero({required this.data, this.clock});

  final V2UsageData data;
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final fraction = data.dailyFraction.clamp(0.0, 1.0).toDouble();
    final limit = data.limitText;
    // A missing count is `—`, and an unknown count must not paint an empty
    // progress track: a 0-width bar reads as "no usage" when the truth is
    // "not loaded".
    final hasDaily = data.dailyUsedLabel.trim().isNotEmpty;
    final fallback = data.resetLabel.isNotEmpty
        ? data.resetLabel
        : (data.resetsAtLabel.isEmpty ? '' : 'Resets at ${data.resetsAtLabel}');
    final monthlyUsed = data.monthlyUsedText;
    final monthlyLimit = data.monthlyLimitText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Tokens today', style: OType.caption.copyWith(color: c.textMuted)),
        const SizedBox(height: OSpace.xs),
        Semantics(
          label: hasDaily
              ? (limit.isEmpty
                    ? '${data.usedText} tokens used today'
                    : '${data.usedText} of $limit tokens used today')
              : (limit.isEmpty
                    ? 'Today\'s token usage is not available.'
                    : 'Today\'s token usage is not available. '
                          'The limit is $limit tokens.'),
          child: ExcludeSemantics(
            child: Text(
              data.usedText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.h1.copyWith(color: c.text),
            ),
          ),
        ),
        Text(
          limit.isEmpty ? 'tokens used today' : 'of $limit tokens',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: OType.bodySm.copyWith(color: c.textMuted),
        ),
        if (hasDaily) ...[
          const SizedBox(height: OSpace.m),
          OProgressBar(value: fraction, height: 8),
        ],
        if (fallback.isNotEmpty || data.resetsAt != null) ...[
          const SizedBox(height: OSpace.s),
          _ResetCountdown(
            resetsAt: data.resetsAt,
            fallback: fallback,
            clock: clock,
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ],
        const SizedBox(height: OSpace.m),
        // The second real number: the 30 day allowance from `/usage/history`.
        // It stays a caption under the one hero instead of a second card.
        Semantics(
          label: data.monthlyUsedLabel.trim().isEmpty
              ? (monthlyLimit.isEmpty
                    ? 'This month\'s token usage is not available.'
                    : 'This month\'s token usage is not available. '
                          'The limit is $monthlyLimit tokens.')
              : (monthlyLimit.isEmpty
                    ? '$monthlyUsed tokens used this month'
                    : '$monthlyUsed of $monthlyLimit tokens used this month'),
          child: ExcludeSemantics(
            child: Text(
              monthlyLimit.isEmpty
                  ? 'This month: $monthlyUsed'
                  : 'This month: $monthlyUsed of $monthlyLimit',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
        ),
        // The request/image counters from `/usage`'s `today` object. One line,
        // never a card; omitted when the server reported neither.
        if (data.countersText.isNotEmpty) ...[
          const SizedBox(height: OSpace.xs),
          Text(
            data.countersText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ],
      ],
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
    this.clock,
  });

  final DateTime? resetsAt;
  final String fallback;
  final TextStyle style;
  final DateTime Function()? clock;

  @override
  State<_ResetCountdown> createState() => _ResetCountdownState();
}

class _ResetCountdownState extends State<_ResetCountdown> {
  Timer? _timer;

  DateTime get _now => widget.clock?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(_ResetCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetsAt != widget.resetsAt ||
        oldWidget.clock != widget.clock) {
      _syncTimer();
    }
  }

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    final at = widget.resetsAt;
    // A window that has already reset has nothing left to tick. Keeping the
    // periodic timer alive would wake the device once a minute forever.
    if (at == null || !at.isAfter(_now)) return;
    // Minute resolution is all the copy shows, so one tick a minute is enough
    // and keeps the page from waking the device every second.
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      if (!at.isAfter(_now)) {
        _timer?.cancel();
        _timer = null;
      }
      setState(() {});
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
        : 'Resets ${formatTimeUntil(resetsAt, now: _now)}';
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: widget.style,
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

/// `50000000` → `50M`, `1000000000` → `1B`.
String _compactCap(int value) {
  if (value >= 1000000000) {
    final billions = value / 1000000000;
    return billions == billions.roundToDouble()
        ? '${billions.round()}B'
        : '${billions.toStringAsFixed(1)}B';
  }
  if (value >= 1000000) {
    final millions = value / 1000000;
    return millions == millions.roundToDouble()
        ? '${millions.round()}M'
        : '${millions.toStringAsFixed(1)}M';
  }
  return '$value';
}

V2TokenChartPoint _tokenPoint(V2UsageDay day) {
  // Only a real count may reach the chart. Falling back to the bar fraction
  // would invent a token total in the screen-reader summary.
  final parsed = day.tokens > 0
      ? day.tokens.toDouble()
      : _tokensFromLabel(day.valueLabel);
  return V2TokenChartPoint(
    id: day.id,
    label: day.label,
    value: parsed,
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
