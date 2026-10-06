import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/agent_service.dart';
import '../../core/format.dart';
import '../../core/ovid_cloud_service.dart';
import '../../core/state.dart';
import '../../core/theme.dart';
import '../settings_screen.dart';
import '../widgets/aether_primitives.dart';

/// Chat bottom sheets — model picker, agent access mode, and session
/// metrics. Relocated from `chat_screen.dart` and unified:
///
/// * [showModelPickerSheet] is the premium-polish model picker (the
///   draggable catalogue sheet).
/// * [showAgentModeSheet] is the ONE agent access mode sheet — the
///   composer mode chip and the `/permission` command used to build two
///   near-identical sheets; both now open this one.
/// * [showSessionMetricsSheet] is the ONE metrics surface — the former
///   "Session analytics" and "Context" sheets consolidated into a single
///   sheet (context breakdown on top, turn analytics below).

/// Opens the model picker as a draggable sheet.
void showModelPickerSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: DraggableScrollableSheet(
        initialChildSize:
            MediaQuery.viewInsetsOf(sheetContext).bottom > 0 ||
                MediaQuery.textScalerOf(sheetContext).scale(14) > 20
            ? 0.92
            : 0.5,
        minChildSize:
            MediaQuery.viewInsetsOf(sheetContext).bottom > 0 ||
                MediaQuery.textScalerOf(sheetContext).scale(14) > 20
            ? 0.6
            : 0.32,
        maxChildSize: 0.92,
        snap: true,
        snapSizes:
            MediaQuery.viewInsetsOf(sheetContext).bottom > 0 ||
                MediaQuery.textScalerOf(sheetContext).scale(14) > 20
            ? const [0.6, 0.92]
            : const [0.5, 0.92],
        builder: (ctx, scrollController) =>
            _ModelPickerSheet(scrollController: scrollController),
      ),
    ),
  );
}

/// Agent access mode sheet — one row per [modeOptionsForPicker] entry with
/// the current mode checked. Picking Control runs [onEnableControl] (the
/// disclosure/battery/accessibility enable flow owned by the chat screen);
/// anything else applies immediately.
void showAgentModeSheet(
  BuildContext context, {
  required Future<void> Function(BuildContext) onEnableControl,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Aether.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            const Text(
              'Agent access mode',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            for (final m in modeOptionsForPicker())
              ListTile(
                dense: true,
                leading: Icon(m.icon, size: 18, color: m.color),
                title: Text(m.label, style: const TextStyle(fontSize: 13.5)),
                subtitle: Text(
                  m.hint,
                  style: TextStyle(
                    fontSize: 11,
                    color: Aether.textFaint,
                    height: 1.4,
                  ),
                ),
                trailing: AgentService.I.mode == m
                    ? const Icon(Icons.check, size: 18, color: Aether.accent)
                    : null,
                onTap: () async {
                  Navigator.pop(context);
                  if (m == AgentMode.control) {
                    await onEnableControl(context);
                  } else {
                    AgentService.I.setMode(m);
                  }
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

String _fmtTok(int t) => formatCompactCount(t);
String _fmtCost(double usd) => usd >= 1
    ? '\$${usd.toStringAsFixed(2)}'
    : '\$${usd.toStringAsFixed(usd >= 0.01 ? 3 : 4)}';

/// Session metrics sheet — the consolidated usage surface: context-window
/// breakdown (the former context meter) on top, turn analytics (the former
/// session analytics sheet) below. Both stats-line taps land here.
void showSessionMetricsSheet(BuildContext context, ChatSession session) {
  final a = session.analytics;
  final agent = AgentService.I;
  final window = AgentService.contextWindowForSession(session);
  final used = a.contextTokens > 0
      ? a.contextTokens
      : agent.measuredContextTokens(session);
  final frac = (used / window).clamp(0.0, 1.0);
  final sys = a.contextSystemTokens;
  final tool = a.contextToolTokens;
  final msgs = a.contextMessageTokens;
  final cache = a.cacheReadTokens;
  final usageColor = frac >= 0.8
      ? Aether.dangerC
      : frac >= 0.55
      ? Aether.warnLight
      : Aether.successLight;
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Aether.bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Session metrics',
              style: TextStyle(
                color: Aether.text,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${session.title} · ${ovidModelLabel(session.model)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Aether.textMuted, fontSize: 11),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  'Context',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Aether.text,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_fmtTok(used)} / ${_fmtTok(window)} · '
                  '${(frac * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: Aether.mono,
                    color: usageColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _MeterBreakdownBar(
              label: 'System',
              value: sys,
              total: window,
              color: Aether.accent,
            ),
            const SizedBox(height: 10),
            _MeterBreakdownBar(
              label: 'Tools',
              value: tool,
              total: window,
              color: Aether.warnLight,
            ),
            const SizedBox(height: 10),
            _MeterBreakdownBar(
              label: 'Messages',
              value: msgs,
              total: window,
              color: Aether.successLight,
            ),
            const SizedBox(height: 14),
            Text(
              [
                if (cache > 0)
                  'Cache-read: ${_fmtTok(cache)} tok (billed cheaper)',
                'Compaction triggers automatically near the window limit.',
              ].join('\n'),
              style: TextStyle(fontSize: 11, color: Aether.textFaint),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _metricsValue('Input', '${_fmtTok(a.inputTokens)} tok'),
                _metricsValue('Output', '${_fmtTok(a.outputTokens)} tok'),
                _metricsValue(
                  'Context',
                  '${_fmtTok(a.contextTokens)} / ${_fmtTok(a.contextLimit)}',
                ),
                _metricsValue('Turns', '${a.turns}'),
                _metricsValue(
                  'Tools',
                  '${a.toolCalls} · ${formatCompactDuration(Duration(milliseconds: a.toolMs))}',
                ),
                _metricsValue(
                  'TTFT',
                  a.averageTtftMs == 0 ? '—' : '${a.averageTtftMs} ms',
                ),
                _metricsValue(
                  'Decode',
                  a.decodeTokensPerSecond == 0
                      ? '—'
                      : '${a.decodeTokensPerSecond.toStringAsFixed(1)} tok/s',
                ),
                _metricsValue(
                  'Est. cost',
                  a.estimatedCostUsd == 0 ? '—' : _fmtCost(a.estimatedCostUsd),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Cost is an approximate public list-price estimate. Custom or unknown models show no invented price.',
              style: TextStyle(color: Aether.textFaint, fontSize: 10.5),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _metricsValue(String label, String value) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
  decoration: BoxDecoration(
    color: Aether.surfaceAlt,
    borderRadius: BorderRadius.circular(9),
    border: Border.all(color: Aether.hairline),
  ),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: TextStyle(color: Aether.textFaint, fontSize: 10)),
      const SizedBox(height: 2),
      Text(
        value,
        style: TextStyle(
          color: Aether.text,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  ),
);

/// One segmented row of the context meter: label + value + a bar showing
/// this bucket's share of the window.
class _MeterBreakdownBar extends StatelessWidget {
  final String label;
  final int value;
  final int total;
  final Color color;
  const _MeterBreakdownBar({
    required this.label,
    required this.value,
    required this.total,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final frac = total <= 0 ? 0.0 : (value / total).clamp(0.0, 1.0);
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(fontSize: 11, color: Aether.textFaint),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 8,
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 8,
                backgroundColor: Aether.hairline,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          formatCompactCount(value),
          style: TextStyle(
            fontSize: 10.5,
            fontFamily: Aether.mono,
            color: Aether.textFaint,
          ),
        ),
      ],
    );
  }
}

/// Premium-polish model picker.
///
/// Visual language: an [AetherSheet] with a search [AetherField], one
/// [AetherCard] per provider (header = [AetherType.label] eyebrow), each row
/// an [_ModelTile] showing the model name, a `Manual`/`Auto` [AetherPill],
/// and a check when selected. Empty catalogues get an [AetherEmptyState] with
/// a Settings CTA; empty searches get a distinct message. Unconfigured
/// providers surface in a bottom [AetherCard] notice. Ovid Cloud exposes a
/// retry [AetherGhostButton] that calls [OvidCloudService.ensureConnected]
/// with a sanitized status subtitle.
///
/// All selection behaviour (provider seed, model id, effort variant, recents,
/// Studio/Agent integration) remains intact — the sheet still drives
/// [AppState.setModel] via [_ModelTile].
class _ModelPickerSheet extends StatefulWidget {
  final ScrollController scrollController;
  const _ModelPickerSheet({required this.scrollController});

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Connection errors are already sanitized by OvidCloudService. Preserve
  /// the full actionable message, including retry instructions.
  String _cloudStatus(CloudConnectionState state) => switch (state.status) {
    CloudConnectionStatus.idle =>
      'Built-in account connection. Retry to connect — no API key needed.',
    CloudConnectionStatus.connecting => 'Connecting your account…',
    CloudConnectionStatus.loadingCatalog => 'Connected. Loading model catalog…',
    CloudConnectionStatus.ready => 'Built-in · Connected',
    CloudConnectionStatus.failed =>
      (state.error == null || state.error!.trim().isEmpty)
          ? 'Ovid Cloud connection failed. Tap Retry.'
           : state.error!,
  };

  bool _matchesQuery(String q, String haystack) =>
      q.isEmpty || haystack.toLowerCase().contains(q);

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return AnimatedBuilder(
      animation: Listenable.merge([app, OvidCloudService.I]),
      builder: (_, _) {
        final q = _query.toLowerCase();
        final cloud = OvidCloudService.I;
        final connection = cloud.connectionFor(app);
        final managed = app.providerById(AppState.ovidCloudProviderId);
        final showCloud =
            managed != null &&
            (q.isEmpty ||
                _matchesQuery(q, managed.name) ||
                (connection.status == CloudConnectionStatus.ready &&
                    managed.models.any((m) => _matchesQuery(q, m))));
        final configured = app.providers
            .where((p) => p.id != AppState.ovidCloudProviderId)
            .where((p) => p.hasKey && p.models.isNotEmpty)
            .where(
              (p) =>
                  _matchesQuery(q, p.name) ||
                  p.models.any((m) => _matchesQuery(q, m)),
            )
            .toList();
        final unconfigured = app.providers
            .where((p) => p.id != AppState.ovidCloudProviderId)
            .where((p) => !p.hasKey && p.models.isNotEmpty)
            .toList();
        final unconfiguredMatchesSearch = unconfigured.any(
          (p) =>
              _matchesQuery(q, p.name) ||
              p.models.any((m) => _matchesQuery(q, m)),
        );

        // Recents (current selection + prior selections), filtered by query &
        // Ovid Cloud readiness.
        final allRecents = <({String providerId, String model})>[];
        final session = app.activeSession;
        if (session != null &&
            session.model.isNotEmpty &&
            session.model != 'Select a provider') {
          final pId = session.providerId;
          if (pId != null && pId.isNotEmpty) {
            allRecents.add((providerId: pId, model: session.model));
          }
        }
        for (final r in app.recentModels) {
          if (!allRecents.any(
            (item) => item.providerId == r.providerId && item.model == r.model,
          )) {
            allRecents.add(r);
          }
        }
        final recents = allRecents.where((r) {
          final p = app.providerById(r.providerId);
          if (p == null) return false;
          if (p.id == AppState.ovidCloudProviderId &&
              (connection.status != CloudConnectionStatus.ready ||
                  !p.models.contains(r.model.split('·').first.trim()))) {
            return false;
          }
          if (q.isEmpty) return true;
          final baseModel = r.model.split('·').first.trim();
          return _matchesQuery(q, baseModel) ||
              _matchesQuery(q, r.model) ||
              _matchesQuery(q, p.name);
        }).toList();

        final noConfiguredAtAll =
            managed == null &&
            app.providers
                .where((p) => p.id != AppState.ovidCloudProviderId)
                .where((p) => p.hasKey && p.models.isNotEmpty)
                .isEmpty;
        final searchMissed =
            q.isNotEmpty &&
            !showCloud &&
            configured.isEmpty &&
            recents.isEmpty &&
            !unconfiguredMatchesSearch;

        // The draggable controller must own the only vertical viewport. A
        // generic sheet's outer scroller can otherwise obscure the last rows
        // of this bounded catalogue behind its header and keyboard inset.
        return Material(
          color: Aether.surface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AetherRadius.rXl),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
          child: CustomScrollView(
            key: const ValueKey('model-picker-list'),
            controller: widget.scrollController,
            // Search, notices and provider cards share the sheet's real scroll
            // controller, including empty results. Keep normal lazy caching;
            // search filters the catalogue data before rows are built.
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Aether.hairlineStrong,
                        borderRadius: BorderRadius.circular(AetherRadius.rPill),
                      ),
                    )),
                    const SizedBox(height: 14),
                    Text('Select model', style: AetherType.h2),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
              SliverToBoxAdapter(child:
              AetherField(
                key: const ValueKey('model-picker-search'),
                label: 'Search',
                showLabel: false,
                hint: 'Search models or providers',
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v.trim()),
                prefixIcon: Icon(
                  Icons.search,
                  size: 18,
                  color: Aether.textFaint,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 12,
                ),
              ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              Builder(
                  builder: (_) {
                    // Branch 1: catalogue is empty and no search entered.
                    if (noConfiguredAtAll && !showCloud && q.isEmpty) {
                      return SliverToBoxAdapter(child: AetherEmptyState(
                        icon: Icons.hub_outlined,
                        title: 'No models configured',
                        message:
                            'Add a provider API key in Settings → Providers '
                            'and tap Fetch models, or connect Ovid Cloud for a '
                            'managed catalogue.',
                        action: AetherPrimaryButton(
                          label: 'Open Settings',
                          icon: Icons.settings_outlined,
                          onPressed: () {
                            Navigator.pop(context);
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const SettingsScreen(),
                              ),
                            );
                          },
                        ),
                      ));
                    }
                    // Branch 2: query matched absolutely nothing.
                    if (searchMissed) {
                      return SliverToBoxAdapter(child: AetherEmptyState(
                        icon: Icons.search_off_outlined,
                        title: 'No matches',
                        message:
                            'Nothing matches "$_query" in your configured '
                            'providers or models. Try a different search.',
                      ));
                    }
                    return SliverList.list(
                      children: [
                        if (showCloud)
                          _buildOvidCloudCard(
                            context,
                            app: app,
                            cloud: cloud,
                            connection: connection,
                            managed: managed,
                            q: q,
                          ),
                        if (recents.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _buildRecentsCard(context, app: app, recents: recents),
                        ],
                        for (final p in configured) ...[
                          const SizedBox(height: 12),
                          _buildProviderCard(context, p: p, q: q),
                        ],
                        if (unconfiguredMatchesSearch) ...[
                          const SizedBox(height: 12),
                          _buildUnconfiguredNotice(context, unconfigured.where(
                            (p) => _matchesQuery(q, p.name) ||
                                p.models.any((m) => _matchesQuery(q, m)),
                          ).toList()),
                        ],
                      ],
                    );
                  },
              ),
            ],
          ),
          ),
        );
      },
    );
  }

  Widget _buildOvidCloudCard(
    BuildContext context, {
    required AppState app,
    required OvidCloudService cloud,
    required CloudConnectionState connection,
    required ProviderConfig managed,
    required String q,
  }) {
    final ready = connection.status == CloudConnectionStatus.ready;
    final filtered = managed.models
        .where(
          (m) => _matchesQuery(q, m) || _matchesQuery(q, managed.name),
        )
        .toList();
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            AetherStatusDot(
              color: switch (connection.status) {
                CloudConnectionStatus.ready => Aether.successLight,
                CloudConnectionStatus.failed => Aether.dangerC,
                CloudConnectionStatus.connecting ||
                CloudConnectionStatus.loadingCatalog => Aether.accent,
                CloudConnectionStatus.idle => Aether.textFaint,
              },
              pulsing: connection.loading,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _cloudStatus(connection),
                style: AetherType.bodyMuted,
              ),
            ),
          ],
        ),
             if (!ready)
               Align(
                 alignment: Alignment.centerLeft,
                 child:
               AetherGhostButton(
                 key: const ValueKey('cloud-connection-retry'),
                label: connection.loading ? 'Retrying…' : 'Retry',
                icon: Icons.refresh,
                loading: connection.loading,
                onPressed: connection.loading
                    ? null
                    : () => unawaited(cloud.ensureConnected(app: app)),
               ),
               ),
        if (ready && filtered.isNotEmpty) ...[
          const SizedBox(height: 12),
          Divider(height: 1, thickness: 1, color: Aether.hairline),
          const SizedBox(height: 4),
          for (final model in filtered)
            _ModelTile(providerId: managed.id, model: model),
        ],
      ],
    );
    return AetherCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
      title: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(managed.name, style: AetherType.title),
          const AetherPill(label: 'MANAGED', color: Aether.accent),
        ],
      ),
      child: body,
    );
  }

  Widget _buildRecentsCard(
    BuildContext context, {
    required AppState app,
    required List<({String providerId, String model})> recents,
  }) {
    return AetherCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
      title: Row(
        children: [
          Text('Recent', style: AetherType.label),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final r in recents)
            _ModelTile(
              providerId: r.providerId,
              model: r.model,
              isRecent: true,
            ),
        ],
      ),
    );
  }

  Widget _buildProviderCard(
    BuildContext context, {
    required ProviderConfig p,
    required String q,
  }) {
    final models = p.models
        .where((m) => _matchesQuery(q, m) || _matchesQuery(q, p.name))
        .toList();
    if (models.isEmpty) return const SizedBox.shrink();
    return AetherCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
      title: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(p.name, style: AetherType.title),
          if (p.isFree) ...[
            AetherPill(
              label: 'FREE',
              color: Aether.successLight,
            ),
          ],
          const AetherPill(label: 'KEY', color: Aether.accent),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in models) _ModelTile(providerId: p.id, model: m),
        ],
      ),
    );
  }

  Widget _buildUnconfiguredNotice(
    BuildContext context,
    List<ProviderConfig> unconfigured,
  ) {
    return AetherCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      color: Aether.surfaceAlt,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.key_off, size: 18, color: Aether.textFaint),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Providers awaiting a key', style: AetherType.label),
                const SizedBox(height: 4),
                Text(
                  '${unconfigured.map((p) => p.name).join(', ')} — add API '
                  'keys in Settings → Providers to use these models.',
                  style: AetherType.caption,
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: AetherGhostButton(
                    label: 'Open Settings',
                    icon: Icons.settings_outlined,
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SettingsScreen(),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  final String providerId;
  final String model;
  final bool isRecent;
  const _ModelTile({
    required this.providerId,
    required this.model,
    this.isRecent = false,
  });

  static const _effortModels = [
    'deepseek',
    'gpt',
    'kimi',
    'glm',
    'opus',
    'sonnet',
    'gemini-2.5',
    'qwen3',
    'o4',
    'grok',
    'r1',
  ];
  static const variants = ['Low', 'Medium', 'High'];

  bool get supportsEffort =>
      _effortModels.any((e) => model.toLowerCase().contains(e));

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final session = app.activeSession;
    final current = session?.model ?? '';
    final baseModel = model.split('·').first.trim();
    final currentBase = current.split('·').first.trim();
    final isExactMatch = current == model;
    final selected =
        session?.providerId == providerId &&
        (isExactMatch || currentBase == baseModel);

    final provider = app.providerById(providerId);
    final providerName = provider?.name ?? providerId;

    // Managed Ovid Cloud `auto` rows show an `Auto` pill — every other row
    // (own-key provider or specific cloud model) is manual selection.
    final isAutoRow =
        providerId == AppState.ovidCloudProviderId &&
        baseModel.toLowerCase() == 'auto';
    final AetherPill modePill = isAutoRow
        ? const AetherPill(label: 'Auto', color: Aether.accent)
        : AetherPill(label: 'Manual', color: Aether.textMuted);

    Widget buildCurrentBadge() {
      return Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Aether.accentSoft,
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text(
          'CURRENT',
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            color: Aether.accent,
          ),
        ),
      );
    }

    Widget modelTitle() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(ovidModelLabel(baseModel), style: const TextStyle(fontSize: 13.5)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [modePill, if (selected && isRecent) buildCurrentBadge()],
          ),
        ],
      );
    }

    if (!supportsEffort) {
      // Wrap in a transparent Material so splash/hover paints without the
      // DecoratedBox of the enclosing AetherCard hiding it.
      return Material(
        color: Colors.transparent,
        child: ListTile(
          dense: true,
          leading: Icon(
            Icons.smart_toy_outlined,
            size: 18,
            color: selected ? Aether.accent : Aether.textMuted,
          ),
          title: modelTitle(),
          subtitle: isRecent
              ? Text(
                  providerName,
                  style: TextStyle(
                    fontSize: 11,
                    color: selected ? Aether.accent : Aether.textFaint,
                  ),
                )
              : null,
          trailing: selected
              ? const Icon(Icons.check, size: 18, color: Aether.accent)
              : null,
          onTap: () {
            app.setModel(providerId, model);
            Navigator.pop(context);
          },
        ),
      );
    }

    final effortVariant = selected && current.contains('·')
        ? current.split('·').last.trim()
        : (model.contains('·') ? model.split('·').last.trim() : null);

    return Material(
      color: Colors.transparent,
      child: Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        leading: Icon(
          Icons.psychology_outlined,
          size: 18,
          color: selected ? Aether.accent : Aether.textMuted,
        ),
        title: modelTitle(),
        subtitle: isRecent
            ? Text(
                effortVariant != null
                    ? '$providerName · $effortVariant'
                    : providerName,
                style: TextStyle(
                  fontSize: 11,
                  color: selected ? Aether.accent : Aether.textFaint,
                ),
              )
            : (effortVariant != null
                  ? Text(
                      effortVariant,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Aether.accent,
                      ),
                    )
                  : null),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final v in variants)
                ChoiceChip(
                  label: Text(v, style: const TextStyle(fontSize: 12)),
                  selected:
                      current ==
                      (v == 'Medium'
                          ? '$baseModel · Medium'
                          : '$baseModel · $v'),
                  onSelected: (_) {
                    app.setModel(
                      providerId,
                      v == 'Medium' ? '$baseModel · Medium' : '$baseModel · $v',
                    );
                    Navigator.pop(context);
                  },
                  showCheckmark: false,
                  selectedColor: Aether.accentSoft,
                  backgroundColor: Aether.surfaceAlt,
                  side: BorderSide(
                    color:
                        current ==
                            (v == 'Medium'
                                ? '$baseModel · Medium'
                                : '$baseModel · $v')
                        ? Aether.accent
                        : Aether.hairline,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
            ],
          ),
        ],
      ),
      ),
    );
  }
}
