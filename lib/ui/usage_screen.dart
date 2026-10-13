import 'package:flutter/material.dart';

import 'package:ovid_ai/core/cloud_usage_store.dart';
import 'package:ovid_ai/core/format.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/core/usage_attempt.dart';
import 'package:ovid_ai/core/usage_attempt_store.dart';
import 'package:ovid_ai/core/usage_today.dart';
import 'package:ovid_ai/l10n/l10n.dart';
import 'package:ovid_ai/ui/billing_screen.dart';
import 'package:ovid_ai/ui/cloud_usage_status.dart';
import 'package:ovid_ai/ui/image_receipt_panel.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:ovid_ai/ui/widgets/memo_listenable_builder.dart';

/// ═══════════════════════════════════════════════════════════════════
/// PROVIDER-WISE usage tracking — "kisne kitna khaya" view.
/// ───────────────────────────────────────────────────────────────────
/// Aggregated from [AppState.usageAttempts] — observed per-attempt history.
/// web-IDE StatsLine + TurnUsage pattern,
/// with server-authoritative remaining usage for Ovid Cloud.
/// ═══════════════════════════════════════════════════════════════════

class ProviderUsage {
  final String providerId;
  final String providerName;
  final String tier; // 'FREE' | 'BYOK'
  final IconData icon;
  final Color color;
  int requests;
  int tokensIn;
  int tokensOut;
  bool inputKnown;
  bool outputKnown;
  bool inputMeasuredKnown;
  bool outputMeasuredKnown;
  bool inputHasUnknown;
  bool outputHasUnknown;
  int measuredTotalTokens;
  bool measuredTotalKnown;
  bool hasMeasuredTotalUnknown;
  final Map<UsageProvenance, int> alternateTotals;
  final Set<UsageProvenance> provenances;
  int unknownTokenFields;

  /// Locally estimated input/output (provider sent no usage block).
  int estimatedIn;
  int estimatedOut;

  /// Requests sent in Auto mode (also counted under their served model).
  int autoRequests;
  List<UsageModelUsage> models;
  ProviderUsage({
    required this.providerId,
    required this.providerName,
    required this.tier,
    required this.icon,
    required this.color,
    required this.requests,
    required this.tokensIn,
    required this.tokensOut,
    required this.models,
    this.inputKnown = true,
    this.outputKnown = true,
    this.inputMeasuredKnown = false,
    this.outputMeasuredKnown = false,
    this.inputHasUnknown = false,
    this.outputHasUnknown = false,
    this.measuredTotalTokens = 0,
    this.measuredTotalKnown = false,
    this.hasMeasuredTotalUnknown = false,
    Map<UsageProvenance, int>? alternateTotals,
    Set<UsageProvenance>? provenances,
    this.unknownTokenFields = 0,
    this.estimatedIn = 0,
    this.estimatedOut = 0,
    this.autoRequests = 0,
  }) : alternateTotals = alternateTotals ?? <UsageProvenance, int>{},
       provenances = provenances ?? <UsageProvenance>{};
}

class UsageModelUsage {
  UsageModelUsage(this.model);
  final String model;
  int requests = 0;

  /// Of [requests], how many were routed here by Auto mode.
  int autoRequests = 0;
  int measuredTotal = 0;
  bool measuredTotalKnown = false;
  bool hasUnknownTotal = false;
  final Map<UsageProvenance, int> alternateTotals = {};
  final Set<UsageProvenance> provenances = {};
}

/// Everything the Usage screens derive from the attempt journal, computed in
/// one pass and memoised by [UsageSnapshot.keyFor] so streamed tokens and
/// unrelated [AppState] notifications never re-aggregate the journal.
@visibleForTesting
class UsageSnapshot {
  UsageSnapshot._({
    required this.providers,
    required this.todayTokens,
    required this.todayHasUnknown,
    required this.todayAlternate,
    required this.daily,
    required this.deviceToday,
  });

  /// Today's Ovid Cloud activity counted on this device (header fallback
  /// when the server sends no `today`).
  final UsageToday deviceToday;

  /// Per-provider aggregate, most-requested first.
  final List<ProviderUsage> providers;
  final int todayTokens;
  final bool todayHasUnknown;
  final Map<UsageProvenance, int> todayAlternate;

  /// Provider id → 14 calendar-day buckets of provider-reported totals,
  /// oldest first (index 13 is today).
  final Map<String, List<int>> daily;

  int get tokensIn => providers.fold<int>(0, (s, p) => s + p.tokensIn);
  int get tokensOut => providers.fold<int>(0, (s, p) => s + p.tokensOut);

  static Object? _key;
  static UsageSnapshot? _cached;

  /// Number of full journal aggregations performed (test hook).
  @visibleForTesting
  static int debugAggregations = 0;

  @visibleForTesting
  static void debugReset() {
    _key = null;
    _cached = null;
    debugAggregations = 0;
  }

  /// Memo key: journal identity + revision, provider display config and the
  /// local calendar day (the "today" figures roll over at midnight). Cheap to
  /// compute — no journal copy.
  static Object keyFor(AppState app) {
    final now = DateTime.now();
    return (
      app.usageMemoKey,
      Object.hashAll([
        for (final p in app.providers) Object.hash(p.id, p.name, p.isFree),
      ]),
      DateTime(now.year, now.month, now.day),
      // Image receipts feed today's image count.
      ImageStudio.I.receipts,
    );
  }

  static UsageSnapshot of(AppState app) {
    final key = keyFor(app);
    final cached = _cached;
    if (cached != null && _key == key) return cached;
    final next = const UsageScreen()._aggregate(app);
    _key = key;
    _cached = next;
    return next;
  }
}

class UsageScreen extends StatelessWidget {
  const UsageScreen({super.key});

  /// Aggregate the retained attempt journal into observed per-provider history.
  /// The Ovid Cloud card is deliberately separate from the server allowance:
  /// this is what the device observed, not a billing projection.
  UsageSnapshot _aggregate(AppState app) {
    UsageSnapshot.debugAggregations++;
    final byId = <String, ProviderUsage>{};
    // Per-provider model index: O(1) lookup instead of a linear scan of
    // `p.models` per journal record.
    final modelsByProvider = <String, Map<String, UsageModelUsage>>{};
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var todayTokens = 0;
    var todayHasUnknown = false;
    final todayAlternate = <UsageProvenance, int>{};
    final daily = <String, List<int>>{};
    for (final e in app.usageAttempts) {
      final local = e.startedAt.toLocal();
      final date = DateTime(local.year, local.month, local.day);
      final dayTotal = _totalOf(e);
      if (date == today) {
        if (dayTotal == null || dayTotal.value == null) {
          // In-flight, failed and cancelled attempts were not served; only a
          // served request without counts makes today's total incomplete.
          if (e.outcome == UsageOutcome.succeeded) todayHasUnknown = true;
        } else if (dayTotal.provenance == UsageProvenance.providerReported) {
          todayTokens += dayTotal.value!;
        } else {
          todayAlternate.update(
            dayTotal.provenance,
            (value) => value + dayTotal.value!,
            ifAbsent: () => dayTotal.value!,
          );
        }
      }
      if (!e.startedAt.isAfter(now)) {
        final age = today.difference(date).inDays;
        if (age >= 0 &&
            age < 14 &&
            dayTotal?.provenance == UsageProvenance.providerReported &&
            dayTotal?.value != null &&
            dayTotal!.value! > 0) {
          daily.putIfAbsent(
            e.provider,
            () => List<int>.filled(14, 0),
          )[13 - age] += dayTotal.value!;
        }
      }
      final config = app.providerById(e.provider);
      final providerName = e.provider == AppState.ovidCloudProviderId
          ? 'Ovid Cloud'
          : (config?.name ?? e.provider);
      final p = byId.putIfAbsent(
        e.provider,
        () => ProviderUsage(
          providerId: e.provider,
          providerName: providerName,
          tier: e.provider == AppState.ovidCloudProviderId
              ? 'CLOUD'
              : (config?.isFree ?? false)
              ? 'FREE'
              : 'BYOK',
          icon: _iconFor(providerName),
          color: _colorFor(providerName),
          requests: 0,
          tokensIn: 0,
          tokensOut: 0,
          models: [],
        ),
      );
      p.requests++;
      final viaAuto = e.requestedModel.trim().toLowerCase() == 'auto';
      if (viaAuto) p.autoRequests++;
      final model = e.reportedModel == null
          ? 'Requested: ${e.requestedModel} · reported model unavailable'
          : e.reportedModel!;
      final modelIndex = modelsByProvider.putIfAbsent(
        e.provider,
        () => <String, UsageModelUsage>{},
      );
      final m = modelIndex[model];
      final modelUsage = m ?? UsageModelUsage(model);
      if (m == null) {
        modelIndex[model] = modelUsage;
        p.models.add(modelUsage);
      }
      modelUsage.requests++;
      // Auto routes to the same manual models: the request counts under the
      // served model and is also tallied as an Auto request.
      if (viaAuto) modelUsage.autoRequests++;
      // An attempt that was never served (failed, cancelled, in flight) with
      // no counts is not "unknown usage": it counts as a request only.
      if (e.outcome != UsageOutcome.succeeded &&
          e.inputTokens?.value == null &&
          e.outputTokens?.value == null &&
          e.totalTokens?.value == null) {
        continue;
      }
      final tokens = [e.inputTokens, e.outputTokens, _totalOf(e)];
      for (final token in tokens) {
        if (token == null || token.value == null) {
          p.unknownTokenFields++;
          p.provenances.add(UsageProvenance.unknown);
        } else {
          p.provenances.add(token.provenance);
        }
      }
      final input = e.inputTokens;
      final output = e.outputTokens;
      if (input?.provenance == UsageProvenance.providerReported &&
          input?.value != null) {
        p.inputKnown = true;
        p.inputMeasuredKnown = true;
        p.tokensIn += input!.value!;
      } else if (input == null || input.value == null) {
        p.inputHasUnknown = true;
        p.inputKnown = p.inputMeasuredKnown;
      } else {
        p.inputKnown = p.inputMeasuredKnown;
        if (input.provenance == UsageProvenance.locallyEstimated) {
          p.estimatedIn += input.value!;
        }
      }
      if (output?.provenance == UsageProvenance.providerReported &&
          output?.value != null) {
        p.outputKnown = true;
        p.outputMeasuredKnown = true;
        p.tokensOut += output!.value!;
      } else if (output == null || output.value == null) {
        p.outputHasUnknown = true;
        p.outputKnown = p.outputMeasuredKnown;
      } else {
        p.outputKnown = p.outputMeasuredKnown;
        if (output.provenance == UsageProvenance.locallyEstimated) {
          p.estimatedOut += output.value!;
        }
      }
      final total = _totalOf(e);
      if (total?.provenance == UsageProvenance.providerReported &&
          total?.value != null) {
        p.measuredTotalKnown = true;
        p.measuredTotalTokens += total!.value!;
      } else if (total == null || total.value == null) {
        p.hasMeasuredTotalUnknown = true;
      } else {
        p.alternateTotals.update(
          total.provenance,
          (value) => value + total.value!,
          ifAbsent: () => total.value!,
        );
      }
      if (total?.provenance == UsageProvenance.providerReported &&
          total?.value != null) {
        modelUsage.measuredTotalKnown = true;
        modelUsage.measuredTotal += total!.value!;
      } else if (total != null && total.value != null) {
        modelUsage.alternateTotals.update(
          total.provenance,
          (value) => value + total.value!,
          ifAbsent: () => total.value!,
        );
      }
      if (total == null || total.value == null) {
        modelUsage.hasUnknownTotal = true;
        modelUsage.provenances.add(UsageProvenance.unknown);
      } else {
        modelUsage.provenances.add(total.provenance);
      }
    }
    return UsageSnapshot._(
      providers: byId.values.toList()
        ..sort((a, b) => b.requests.compareTo(a.requests)),
      todayTokens: todayTokens,
      todayHasUnknown: todayHasUnknown,
      todayAlternate: todayAlternate,
      daily: daily,
      deviceToday: UsageToday.fromDevice(
        attempts: app.usageAttempts,
        receipts: ImageStudio.I.receipts,
        provider: AppState.ovidCloudProviderId,
        now: now,
      ),
    );
  }

  /// The attempt's total; when the provider sent input and output but no
  /// total, their sum — labelled derived (or estimated), never "reported".
  static UsageTokenCount? _totalOf(UsageAttempt e) {
    final total = e.totalTokens;
    if (total?.value != null) return total;
    final i = e.inputTokens, o = e.outputTokens;
    if (i?.value == null || o?.value == null) return total;
    final sum = i!.value! + o!.value!;
    return i.provenance == UsageProvenance.locallyEstimated ||
            o.provenance == UsageProvenance.locallyEstimated
        ? UsageTokenCount.estimated(sum)
        : UsageTokenCount.derived(sum);
  }

  IconData _iconFor(String name) {
    final n = name.toLowerCase();
    if (n.contains('openai')) return Icons.diamond_outlined;
    if (n.contains('anthropic')) return Icons.memory_outlined;
    if (n.contains('gemini') || n.contains('google')) {
      return Icons.auto_awesome;
    }
    if (n.contains('deepseek')) return Icons.psychology_outlined;
    return Icons.cloud_outlined;
  }

  Color _colorFor(String name) {
    final n = name.toLowerCase();
    if (n.contains('openai')) return const Color(0xFF4CC9E8);
    if (n.contains('anthropic')) return Aether.warn;
    if (n.contains('gemini') || n.contains('google')) return Aether.accent;
    if (n.contains('deepseek')) return const Color(0xFF9B7BFF);
    return Aether.textMuted;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;

    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(context.l10n.usageTitle),
        actions: [
          PopupMenuButton<String>(
            tooltip: context.l10n.usageMoreActions,
            icon: Icon(Icons.more_vert, color: Aether.textMuted),
            onSelected: (value) {
              if (value == 'image-receipts') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ImageReceiptsScreen(),
                  ),
                );
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'image-receipts',
                child: Text(context.l10n.usageImageReceipts),
              ),
            ],
          ),
        ],
      ),
      body: MemoListenableBuilder(
        listenable: Listenable.merge([app, ImageStudio.I]),
        memoKey: () => UsageSnapshot.keyFor(app),
        builder: (_) {
          // Aggregate INSIDE the builder (memoised by journal revision): the
          // outer build runs once, so capturing here would freeze stats.
          final usage = UsageSnapshot.of(app);
          final providers = usage.providers;
          final tokensIn = usage.tokensIn;
          final tokensOut = usage.tokensOut;
          final todayTokens = usage.todayTokens;
          final todayHasUnknown = usage.todayHasUnknown;
          final todayAlternate = usage.todayAlternate;
          return ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              // ---- Hero: Ovid Cloud plan, today and per-model remaining ----
              _PlanHeroHeader(deviceToday: usage.deviceToday),

              // ---- Local token banner (unchanged copy for parity) ----
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: _LocalTotalsStrip(
                  todayTokens: todayTokens,
                  tokensIn: tokensIn,
                  tokensOut: tokensOut,
                  estimatedIn: providers.fold(0, (s, p) => s + p.estimatedIn),
                  estimatedOut: providers.fold(0, (s, p) => s + p.estimatedOut),
                  inputKnown: providers.any((p) => p.inputKnown),
                  outputKnown: providers.any((p) => p.outputKnown),
                  inputHasUnknown: providers.any((p) => p.inputHasUnknown),
                  outputHasUnknown: providers.any((p) => p.outputHasUnknown),
                  hasUnknown: providers.any((p) => p.unknownTokenFields > 0),
                  todayHasUnknown: todayHasUnknown,
                  todayAlternate: todayAlternate,
                ),
              ),

              // ---- Retention / storage notices (F-203) ----
              if (app.usageStorageError != null)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: _UsageHistoryNotice(
                    key: ValueKey('usage-storage-error'),
                    icon: Icons.error_outline,
                    danger: true,
                    message:
                        'Usage history on this device could not be read or '
                        'saved, so these totals may be incomplete. Your '
                        'Ovid Cloud allowance above is not affected.',
                  ),
                )
              else if (app.usageHistoryTruncated)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: _UsageHistoryNotice(
                    key: ValueKey('usage-history-truncated'),
                    icon: Icons.history_toggle_off,
                    message: usageHistoryLimitNotice,
                  ),
                ),

              // ---- 'By provider' section ----
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 22, 18, 10),
                child: const AetherSectionTitle(
                  eyebrow: 'By provider',
                  subtitle: 'Observed attempts · retained device history.',
                ),
              ),

              if (providers.isEmpty && app.usageStorageError != null)
                const AetherEmptyState(
                  icon: Icons.error_outline,
                  title: 'Usage history unavailable',
                  message:
                      'This device could not read its usage history. New '
                      'requests are still counted by Ovid Cloud.',
                )
              else if (providers.isEmpty)
                const AetherEmptyState(
                  icon: Icons.query_stats,
                  title: 'No usage yet',
                  message: 'Start a chat to see per-provider usage here.',
                )
              else
                for (final p in providers)
                  Padding(
                    key: ValueKey(p.providerId),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: _ProviderCard(provider: p),
                  ),

              if (providers.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 6, 18, 0),
                  child: Text(
                    'Observed attempts are separate from the server allowance.',
                    style: AetherType.caption,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
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

/// Shown when the device journal dropped older attempts (F-203).
const usageHistoryLimitNotice =
    'History limited to the last '
    '${UsageAttemptStore.defaultTerminalHistoryLimit} requests on this device. '
    'Older activity is not included in "Today" or the 14-day chart.';

class _UsageHistoryNotice extends StatelessWidget {
  const _UsageHistoryNotice({
    super.key,
    required this.icon,
    required this.message,
    this.danger = false,
  });
  final IconData icon;
  final String message;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? Aether.dangerC : Aether.textMuted;
    return Semantics(
      liveRegion: danger,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Aether.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: danger ? color : Aether.hairline),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text(message, style: AetherType.body)),
          ],
        ),
      ),
    );
  }
}

/// "Resets in 4h 12m" for a server reset time (F-204). Null when unknown.
String? formatResetCountdown(
  DateTime? resetsAt, {
  DateTime? now,
  AppLocalizations? l10n,
}) {
  if (resetsAt == null) return null;
  final t = l10n ?? appLocalizationsFallback;
  final left = resetsAt.difference((now ?? DateTime.now()).toUtc());
  if (left.inMinutes < 1) return t.usageResetsUnderMinute;
  if (left.inDays >= 1) {
    final hours = left.inHours % 24;
    return hours > 0
        ? t.usageResetsInDaysHours(left.inDays, hours)
        : t.usageResetsInDays(left.inDays);
  }
  if (left.inHours >= 1) {
    return t.usageResetsInHoursMinutes(left.inHours, left.inMinutes % 60);
  }
  return t.usageResetsInMinutes(left.inMinutes);
}

/// A single compact stat column used by the local totals strip.
Widget _stat(String label, String value, {bool big = false}) {
  return Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 10.5, color: Aether.textFaint)),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: big ? 22 : 16,
            fontWeight: FontWeight.w700,
            fontFamily: Aether.mono,
            color: big ? Aether.accent : Aether.text,
          ),
        ),
      ],
    ),
  );
}

String _fmtTok(int n) => formatCompactCount(n);

String _displayTokenValue(
  int value,
  bool known,
  bool hasUnknown, {
  int estimated = 0,
}) {
  if (estimated > 0) {
    // Reported plus locally estimated counts: approximate, never "unknown".
    final approx = '≈ ${_fmtTok(value + estimated)}';
    return hasUnknown ? '$approx · some unavailable' : approx;
  }
  if (!known) return 'Unavailable';
  return hasUnknown ? '${_fmtTok(value)} · some unavailable' : _fmtTok(value);
}

String _formatProvenanceTotals(Map<UsageProvenance, int> totals) {
  final entries = totals.entries.toList()
    ..sort(
      (a, b) => _provenanceLabel(a.key).compareTo(_provenanceLabel(b.key)),
    );
  return entries
      .map((entry) => '${_provenanceLabel(entry.key)} ${_fmtTok(entry.value)}')
      .join(' · ');
}

String _provenanceLabel(UsageProvenance provenance) {
  switch (provenance) {
    case UsageProvenance.providerReported:
      return 'Reported';
    case UsageProvenance.locallyEstimated:
      return 'Estimated';
    case UsageProvenance.derived:
      return 'Derived';
    case UsageProvenance.legacyUnspecified:
      return 'Legacy';
    case UsageProvenance.unknown:
      return 'Unknown';
  }
}

String _provenanceSummary(ProviderUsage provider) {
  final labels = provider.provenances.map(_provenanceLabel).toSet().toList()
    ..sort();
  if (provider.unknownTokenFields > 0 && !labels.contains('Unknown')) {
    labels.add('Unknown');
  }
  return labels.join(' · ');
}

/// Today's token snapshot + "in · out" micro-banner, kept behaviourally
/// identical to the previous layout so downstream tests that assert these
/// exact text strings (`'30'`, `'20 in · 10 out'`) still pass under the
/// redesign.
class _LocalTotalsStrip extends StatelessWidget {
  const _LocalTotalsStrip({
    required this.todayTokens,
    required this.tokensIn,
    required this.tokensOut,
    this.estimatedIn = 0,
    this.estimatedOut = 0,
    required this.inputKnown,
    required this.outputKnown,
    required this.inputHasUnknown,
    required this.outputHasUnknown,
    required this.hasUnknown,
    required this.todayHasUnknown,
    required this.todayAlternate,
  });

  final int todayTokens;
  final int tokensIn;
  final int tokensOut;
  final int estimatedIn;
  final int estimatedOut;
  final bool inputKnown;
  final bool outputKnown;
  final bool inputHasUnknown;
  final bool outputHasUnknown;
  final bool hasUnknown;
  final bool todayHasUnknown;
  final Map<UsageProvenance, int> todayAlternate;

  /// Reported tokens today; local estimates make it approximate ("≈"),
  /// never "Unavailable" when any count exists.
  String _todayValue() {
    final estimated =
        (todayAlternate[UsageProvenance.locallyEstimated] ?? 0) +
        (todayAlternate[UsageProvenance.derived] ?? 0);
    final base = estimated > 0
        ? '≈ ${_fmtTok(todayTokens + estimated)}'
        : _fmtTok(todayTokens);
    if (!todayHasUnknown) return base;
    return todayTokens == 0 && estimated == 0
        ? 'Unavailable'
        : '$base · some unavailable';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Retained observed history', style: AetherType.caption),
        const SizedBox(height: 8),
        AetherCard(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              _stat('Today · provider-reported tokens', _todayValue()),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Aether.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Aether.hairline),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(
                Icons.data_usage_outlined,
                size: 15,
                color: Aether.textFaint,
              ),
              const SizedBox(width: 8),
              Text(
                hasUnknown
                    ? 'Input · output · some values unavailable'
                    : estimatedIn + estimatedOut > 0
                    ? 'Input · output · includes estimates (≈)'
                    : 'Input · output · provider-reported usage',
                style: TextStyle(fontSize: 11, color: Aether.textFaint),
              ),
              if (hasUnknown)
                Text(
                  'Unavailable',
                  style: TextStyle(fontSize: 11, color: Aether.textFaint),
                ),
              Text(
                '${_displayTokenValue(tokensIn, inputKnown, inputHasUnknown, estimated: estimatedIn)} in · '
                '${_displayTokenValue(tokensOut, outputKnown, outputHasUnknown, estimated: estimatedOut)} out',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  fontFamily: Aether.mono,
                  color: Aether.text,
                ),
              ),
            ],
          ),
        ),
        if (todayAlternate.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            'Estimated/legacy totals · ${_formatProvenanceTotals(todayAlternate)}',
            style: AetherType.caption,
          ),
        ],
      ],
    );
  }
}

/// Hero plan header rendered on an [AetherGradientHeader] wash.
///
/// Server-authoritative data from [CloudUsageStore] / [OvidCloudService] drives
/// the plan pill (FREE/PLUS/PRO/MAX), the overall remaining bar, the reset
/// countdown and the per-model remaining list. Today's counters come from the
/// server's `today` object, or this device's journal on older servers and
/// offline. No price or currency is ever rendered.
class _PlanHeroHeader extends StatefulWidget {
  const _PlanHeroHeader({required this.deviceToday});

  final UsageToday deviceToday;

  @override
  State<_PlanHeroHeader> createState() => _PlanHeroHeaderState();
}

class _PlanHeroHeaderState extends State<_PlanHeroHeader>
    with AutomaticKeepAliveClientMixin {
  late final CloudUsageStore _store;

  /// Stay mounted while scrolled away: the store subscription (and its fetch)
  /// is not torn down and re-run as the user scrolls, and the list keeps a
  /// stable scroll extent.
  @override
  bool get wantKeepAlive => true;
  OvidUsage? get _usage => _store.usage;
  bool get _loading => _store.loading && _usage == null;

  @override
  void initState() {
    super.initState();
    _store = CloudUsageStore.acquire(AppState.I);
    _store.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    _store.release();
    super.dispose();
  }

  /// Human-readable plan name for the pill.
  ///
  /// Honours both the server's `is_paid` and [AppState.ovidCloudIsPaid] — the
  /// FREE/PLUS/PRO/MAX pill is purely a visual summary of the already-decided
  /// plan state; neither the tier nor the paid flag is invented here.
  String _pillLabel(String tier, bool isPaid) {
    if (!isPaid || tier == 'free' || tier.isEmpty) return 'FREE';
    switch (tier) {
      case '3x':
        return 'PLUS';
      case '7x':
        return 'PRO';
      case '15x':
        return 'MAX';
      default:
        return tier.toUpperCase();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = context.l10n;
    final app = AppState.I;
    final usage = _usage;
    final tier = usage?.tier ?? app.ovidCloudTier;
    final isPaid = usage?.isPaid ?? app.ovidCloudIsPaid;
    final label = _pillLabel(tier, isPaid);
    final pillColor = isPaid ? Aether.accent : Aether.textMuted;
    final pct = usage?.remainingFraction;
    final today = UsageToday.resolve(usage, widget.deviceToday);
    final models = usage?.perModel ?? const <OvidModelUsage>[];
    final reset = formatResetCountdown(usage?.resetsAt, l10n: l10n);

    final card = AetherCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(Icons.auto_awesome, size: 18, color: Aether.accent),
              Text(l10n.usageCloudName, style: AetherType.title),
              Semantics(
                label: l10n.usagePlanSemantics(label),
                excludeSemantics: true,
                child: AetherPill(label: label, color: pillColor),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            usage == null
                ? l10n.usagePlanSaved
                : _store.stale || _store.error != null
                ? l10n.usagePlanLastKnown
                : l10n.usagePlanConfirmed,
            style: AetherType.caption,
          ),
          const SizedBox(height: 14),
          if (_loading)
            const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            _RemainingHero(pct: pct),
          // Only the server's own reset time is shown; the client never
          // interprets the window itself.
          if (reset != null) ...[
            const SizedBox(height: 10),
            _HeroFact(
              key: const ValueKey('usage-reset'),
              icon: Icons.schedule,
              label: reset,
            ),
          ],
          const SizedBox(height: 16),
          _TodayStats(today: today),
          if (pct != null && pct < 0.1 && tier != '15x') ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const ValueKey('usage-upgrade'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const BillingScreen()),
                ),
                icon: const Icon(Icons.arrow_upward, size: 18),
                label: Text(
                  pct <= 0 ? l10n.usageUpgradeUsedUp : l10n.usageUpgradeLow,
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text(l10n.usageServerAuthoritative, style: AetherType.caption),
          CloudUsageStatus(store: _store),
          if (models.isNotEmpty) ...[
            const SizedBox(height: 18),
            Semantics(
              header: true,
              child: Text(
                l10n.usageModelsTitle.toUpperCase(),
                style: AetherType.caption.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.9,
                ),
              ),
            ),
            const SizedBox(height: 8),
            for (final m in models)
              _ModelRow(key: ValueKey('usage-model-${m.model}'), model: m),
            const SizedBox(height: 4),
            Text(l10n.usageModelsFootnote, style: AetherType.caption),
          ],
        ],
      ),
    );

    return Stack(
      children: [
        const AetherGradientHeader(height: 110, child: SizedBox.expand()),
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: card),
      ],
    );
  }
}

class _HeroFact extends StatelessWidget {
  const _HeroFact({super.key, required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 15, color: Aether.textMuted),
      const SizedBox(width: 6),
      Flexible(child: Text(label, style: AetherType.body)),
    ],
  );
}

/// Today's requests / input tokens / output tokens / images. Four columns
/// when there is room, two otherwise (320dp, large text).
class _TodayStats extends StatelessWidget {
  const _TodayStats({required this.today});
  final UsageToday today;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final approx = today.tokensEstimated ? '≈ ' : '';
    final cells = <(Key?, String, String)>[
      (
        const ValueKey('usage-requests-today'),
        l10n.usageTodayRequests,
        formatCompactCount(today.requests),
      ),
      (
        const ValueKey('usage-input-today'),
        l10n.usageTodayInput,
        '$approx${formatCompactCount(today.inputTokens)}',
      ),
      (
        const ValueKey('usage-output-today'),
        l10n.usageTodayOutput,
        '$approx${formatCompactCount(today.outputTokens)}',
      ),
      (
        const ValueKey('usage-images-today'),
        l10n.usageTodayImages,
        formatCompactCount(today.images),
      ),
    ];
    final notes = [
      if (today.source == UsageTodaySource.device) l10n.usageTodayDeviceNote,
      // Auto is tallied from this device's journal, so only claim it when
      // the counters themselves are device-local.
      if (today.source == UsageTodaySource.device && today.autoRequests > 0)
        l10n.usageTodayAutoNote(today.autoRequests),
      if (today.tokensEstimated) l10n.usageTodayEstimatedNote,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            l10n.usageTodayTitle.toUpperCase(),
            style: AetherType.caption.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.9,
            ),
          ),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context).scale(1);
            final columns = constraints.maxWidth / scale >= 300 ? 4 : 2;
            const gap = 10.0;
            final width =
                (constraints.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final (key, label, value) in cells)
                  SizedBox(
                    key: key,
                    width: width,
                    child: MergeSemantics(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Aether.surfaceAlt,
                          borderRadius: BorderRadius.circular(AetherRadius.rMd),
                          border: Border.all(color: Aether.hairline),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              value,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                fontFamily: Aether.mono,
                                color: Aether.text,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(label, style: AetherType.caption),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        for (final note in notes) ...[
          const SizedBox(height: 6),
          Text(note, style: AetherType.caption),
        ],
      ],
    );
  }
}

class _RemainingHero extends StatelessWidget {
  const _RemainingHero({required this.pct});
  final double? pct;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (pct == null) {
      return Text(l10n.usageRemainingUnknown, style: AetherType.bodyMuted);
    }
    final percentText = l10n.usageRemainingPercent((pct! * 100).round());
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(percentText, style: AetherType.display),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 8,
              semanticsLabel: l10n.usageOverallBarLabel,
              backgroundColor: Aether.surfaceAlt,
              valueColor: AlwaysStoppedAnimation(
                pct! < 0.1 ? Aether.danger : Aether.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One model's own remaining usage: "≈ 120 messages left" / "≈ 8 images
/// left", "—" when the model is unpriced or the count is unknown.
class _ModelRow extends StatelessWidget {
  const _ModelRow({super.key, required this.model});
  final OvidModelUsage model;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final remaining = model.remaining;
    final value = remaining == null
        ? '—'
        : model.isImage
        ? l10n.usageModelImagesLeft(remaining)
        : l10n.usageModelMessagesLeft(remaining);
    final low = remaining != null && remaining < (model.isImage ? 2 : 10);
    final name = Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Icon(
          model.isImage ? Icons.image_outlined : Icons.chat_bubble_outline,
          size: 15,
          color: Aether.textMuted,
        ),
        Text(model.label, style: AetherType.body.copyWith(color: Aether.text)),
        // The Auto row is usually named "Auto" already; only tag renamed ones.
        if (model.auto && model.label.trim().toLowerCase() != 'auto')
          AetherPill(label: l10n.usageModelAuto, color: Aether.accent),
      ],
    );
    final count = Semantics(
      label: remaining == null ? l10n.usageModelRemainingUnknown : null,
      excludeSemantics: remaining == null,
      child: Text(
        value,
        textAlign: TextAlign.end,
        style: AetherType.body.copyWith(
          fontWeight: FontWeight.w700,
          fontFamily: Aether.mono,
          color: remaining == null
              ? Aether.textMuted
              : low
              ? Aether.danger
              : Aether.text,
        ),
      ),
    );
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final scale = MediaQuery.textScalerOf(context).scale(1);
                // Side by side when there is room; stacked at 320dp / 2.0x.
                if (constraints.maxWidth / scale < 240) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [name, const SizedBox(height: 2), count],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: name),
                    const SizedBox(width: 12),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * 0.62,
                      ),
                      child: count,
                    ),
                  ],
                );
              },
            ),
            if (model.estimate != null) ...[
              const SizedBox(height: 2),
              Text(l10n.usageModelEstimateNote, style: AetherType.caption),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProviderCard extends StatefulWidget {
  const _ProviderCard({required this.provider});
  final ProviderUsage provider;

  @override
  State<_ProviderCard> createState() => _ProviderCardState();
}

class _ProviderCardState extends State<_ProviderCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    final countsLine =
        '${p.requests} requests · '
        '${_displayTokenValue(p.tokensIn, p.inputKnown, p.inputHasUnknown, estimated: p.estimatedIn)} in · '
        '${_displayTokenValue(p.tokensOut, p.outputKnown, p.outputHasUnknown, estimated: p.estimatedOut)} out';
    return InkWell(
      borderRadius: BorderRadius.circular(AetherRadius.rLg),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ProviderUsageScreen(provider: p)),
      ),
      child: Stack(
        children: [
          AetherCard(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: p.color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(AetherRadius.rMd),
                        border: Border.all(
                          color: p.color.withValues(alpha: 0.25),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Icon(p.icon, size: 18, color: p.color),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.providerName, style: AetherType.title),
                          const SizedBox(height: 4),
                          AetherPill(
                            label: p.tier,
                            color: p.tier == 'FREE'
                                ? Aether.success
                                : Aether.textMuted,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  countsLine,
                  style: AetherType.bodyMuted.copyWith(
                    fontFamily: Aether.mono,
                    fontSize: 12,
                  ),
                ),
                if (p.autoRequests > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    context.l10n.usageProviderAutoRequests(p.autoRequests),
                    style: AetherType.caption,
                  ),
                ],
                if (_provenanceSummary(p).isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Token provenance · ${_provenanceSummary(p)}',
                    style: AetherType.caption,
                  ),
                ],
                if (p.measuredTotalKnown || p.hasMeasuredTotalUnknown) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Measured · ${p.hasMeasuredTotalUnknown ? 'Unavailable' : _fmtTok(p.measuredTotalTokens)}',
                    style: AetherType.caption,
                  ),
                ],
                if (p.alternateTotals.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Estimated/legacy · ${_formatProvenanceTotals(p.alternateTotals)}',
                    style: AetherType.caption,
                  ),
                ],
                if (p.models.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      label: Text(
                        _expanded
                            ? 'Hide models'
                            : 'Show ${p.models.length} model${p.models.length == 1 ? '' : 's'}',
                      ),
                      icon: Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                      ),
                      onPressed: () => setState(() => _expanded = !_expanded),
                    ),
                  ),
                  if (_expanded) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Aether.surfaceAlt,
                        borderRadius: BorderRadius.circular(AetherRadius.rMd),
                        border: Border.all(color: Aether.hairline),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final m in p.models)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: _ModelCounts(model: m),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: Tooltip(
              message: 'View provider details',
              child: Semantics(
                button: true,
                label: 'View provider details',
                child: InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ProviderUsageScreen(provider: p),
                    ),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.open_in_new, size: 18),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Keep the complete model identifier readable even at large text sizes.
class _ModelCounts extends StatelessWidget {
  const _ModelCounts({required this.model});
  final UsageModelUsage model;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(model.model, style: AetherType.mono.copyWith(color: Aether.text)),
      const SizedBox(height: 4),
      Text(
        '${model.requests} req${model.autoRequests > 0 ? ' (${model.autoRequests} via Auto)' : ''} · ${model.measuredTotalKnown && !model.hasUnknownTotal ? '${_fmtTok(model.measuredTotal)} provider-reported tok' : 'Unavailable total'}',
        style: AetherType.caption,
      ),
      if (model.alternateTotals.isNotEmpty)
        Text(
          'Estimated/legacy · ${_formatProvenanceTotals(model.alternateTotals)}',
          style: AetherType.caption,
        ),
      if (model.provenances.isNotEmpty)
        Text(
          'Provenance · ${model.provenances.map(_provenanceLabel).join(' · ')}',
          style: AetherType.caption,
        ),
    ],
  );
}

/// Detailed per-provider usage screen.
class ProviderUsageScreen extends StatefulWidget {
  final ProviderUsage provider;
  const ProviderUsageScreen({super.key, required this.provider});

  @override
  State<ProviderUsageScreen> createState() => _ProviderUsageScreenState();
}

class _ProviderUsageScreenState extends State<ProviderUsageScreen> {
  ProviderUsage get provider => widget.provider;
  late final Object _initialRevision;
  late final Object _initialIdentity;

  @override
  void initState() {
    super.initState();
    // A caller-supplied snapshot remains a valid initial seed, but can never
    // resurrect counts after the live log has changed or been cleared.
    _initialRevision = (
      AppState.I.usageRevision,
      AppState.I.usageAttempts.lastOrNull,
    );
    _initialIdentity = OvidCloudService.I.accountIdentity;
  }

  @override
  Widget build(BuildContext context) {
    return MemoListenableBuilder(
      listenable: Listenable.merge([AppState.I, OvidCloudService.I]),
      memoKey: () => (
        UsageSnapshot.keyFor(AppState.I),
        OvidCloudService.I.accountIdentity,
      ),
      builder: _buildDetail,
    );
  }

  Widget _buildDetail(BuildContext context) {
    final usage = UsageSnapshot.of(AppState.I);
    final p =
        usage.providers
            .where((p) => p.providerId == provider.providerId)
            .firstOrNull ??
        ((_initialRevision ==
                    (
                      AppState.I.usageRevision,
                      AppState.I.usageAttempts.lastOrNull,
                    ) &&
                _initialIdentity == OvidCloudService.I.accountIdentity)
            ? provider
            : ProviderUsage(
                providerId: provider.providerId,
                providerName: provider.providerName,
                tier: provider.tier,
                icon: provider.icon,
                color: provider.color,
                requests: 0,
                tokensIn: 0,
                tokensOut: 0,
                models: [],
              ));
    // Calendar-day buckets come from the attempt journal only (memoised in
    // [UsageSnapshot]). Legacy rows are already migrated into that journal, so
    // reading usageLog here would count them a second time.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final daily = usage.daily[p.providerId] ?? List<int>.filled(14, 0);
    final hasTrend = daily.where((tokens) => tokens > 0).length >= 2;
    final maxTokens = daily.reduce((a, b) => a > b ? a : b);
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(leading: const BackButton(), title: Text(p.providerName)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          // header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: p.color.withValues(alpha: 0.12),
                  child: Icon(p.icon, size: 22, color: p.color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.providerName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        p.tier,
                        style: TextStyle(fontSize: 12, color: Aether.textFaint),
                      ),
                      Text(
                        '${p.requests} requests',
                        style: TextStyle(fontSize: 11, color: Aether.textFaint),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // quick stats
          Container(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Aether.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Aether.hairline),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final stacked =
                    constraints.maxWidth /
                        MediaQuery.textScalerOf(context).scale(1) <
                    280;
                final cells = [
                  _cell('Requests', '${p.requests}'),
                  _cell(
                    'Tokens in',
                    _displayTokenValue(
                      p.tokensIn,
                      p.inputKnown,
                      p.inputHasUnknown,
                      estimated: p.estimatedIn,
                    ),
                  ),
                  _cell(
                    'Tokens out',
                    _displayTokenValue(
                      p.tokensOut,
                      p.outputKnown,
                      p.outputHasUnknown,
                      estimated: p.estimatedOut,
                    ),
                  ),
                  _cell(
                    'Measured total',
                    p.measuredTotalKnown && !p.hasMeasuredTotalUnknown
                        ? _fmtTok(p.measuredTotalTokens)
                        : 'Unavailable',
                  ),
                ];
                return stacked
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final cell in cells)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: cell,
                            ),
                        ],
                      )
                    : Row(
                        children: [
                          for (final cell in cells) Expanded(child: cell),
                        ],
                      );
              },
            ),
          ),

          const _SectionLabel('LAST 14 DAYS · ACTIVITY SCOPE'),
          if (AppState.I.usageHistoryTruncated)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: _UsageHistoryNotice(
                icon: Icons.history_toggle_off,
                message: usageHistoryLimitNotice,
              ),
            ),
          if (!hasTrend)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Text(
                p.hasMeasuredTotalUnknown
                    ? 'Provider-reported totals unavailable for some attempts; not enough measured activity for a trend.'
                    : 'Provider-reported totals unavailable or not enough recent activity for a trend.',
                style: AetherType.caption,
              ),
            )
          else
            Container(
              key: const ValueKey('usage-activity-chart'),
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
              decoration: BoxDecoration(
                color: Aether.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Aether.hairline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Last 14 days · Provider-reported measured tokens · relative to busiest day',
                    style: AetherType.caption,
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 72,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (var i = 0; i < daily.length; i++)
                          Expanded(
                            child: _ChartPoint(
                              date: today.subtract(Duration(days: 13 - i)),
                              tokens: daily[i],
                              maxTokens: maxTokens,
                              color: p.color,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 16,
                    runSpacing: 4,
                    children: [
                      Text(
                        '13 days ago',
                        style: TextStyle(
                          fontSize: 9.5,
                          color: Aether.textFaint,
                        ),
                      ),
                      Text(
                        'Today',
                        style: TextStyle(
                          fontSize: 9.5,
                          color: Aether.textFaint,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Legacy totals excluded from measured chart.',
                    style: AetherType.caption,
                  ),
                ],
              ),
            ),

          const _SectionLabel('PER MODEL'),
          if (p.models.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: Text(
                  'No per-model breakdown yet.',
                  style: TextStyle(fontSize: 12, color: Aether.textMuted),
                ),
              ),
            )
          else
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
              decoration: BoxDecoration(
                color: Aether.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Aether.hairline),
              ),
              child: Column(
                children: [
                  for (final m in p.models)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: _ModelCounts(model: m),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _cell(String label, String value) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            fontFamily: Aether.mono,
          ),
        ),
        const SizedBox(height: 3),
        Text(label, style: TextStyle(fontSize: 10.5, color: Aether.textFaint)),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        color: Aether.textFaint,
      ),
    ),
  );
}

class _ChartPoint extends StatelessWidget {
  const _ChartPoint({
    required this.date,
    required this.tokens,
    required this.maxTokens,
    required this.color,
  });

  final DateTime date;
  final int tokens;
  final int maxTokens;
  final Color color;

  String get _dateLabel => date.toIso8601String().split('T').first;

  @override
  Widget build(BuildContext context) {
    final label = '$_dateLabel: $tokens tokens';
    return Semantics(
      button: true,
      label: label,
      hint: 'Double tap to hear this day’s measured token value',
      onTap: () => ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(label))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2.5),
        child: FractionallySizedBox(
          heightFactor: tokens / maxTokens,
          alignment: Alignment.bottomCenter,
          child: Container(
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.35 + tokens / maxTokens * 0.5),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ),
    );
  }
}
