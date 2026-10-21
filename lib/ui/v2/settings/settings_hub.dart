// TODO(l10n): move the English copy in this screen to the ARB files.
import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'settings_search.dart';

/// The four states every settings list can be in.
enum V2SettingsHubStatus { loading, ready, empty, error }

@immutable
class V2SettingsProfile {
  const V2SettingsProfile({
    required this.name,
    required this.email,
    this.planLabel = 'Free plan',
    this.initials,
    this.image,
  });

  final String name;
  final String email;
  final String planLabel;
  final String? initials;
  final ImageProvider? image;
}

@immutable
class V2SettingsItem {
  const V2SettingsItem({
    required this.id,
    required this.label,
    required this.icon,
    this.subtitle,
    this.onTap,
    this.danger = false,
    this.enabled = true,
  });

  final String id;
  final String label;
  final String? subtitle;
  final IconData icon;
  final VoidCallback? onTap;
  final bool danger;
  final bool enabled;
}

@immutable
class V2SettingsSection {
  const V2SettingsSection({required this.title, this.items = const []});

  final String title;
  final List<V2SettingsItem> items;
}

@immutable
class V2SettingsHubData {
  const V2SettingsHubData({
    this.status = V2SettingsHubStatus.ready,
    this.profile,
    this.account = const V2SettingsSection(title: 'Account'),
    this.chat = const V2SettingsSection(title: 'Chat'),
    this.models = const V2SettingsSection(title: 'Models'),
    this.dataControl = const V2SettingsSection(title: 'Data control'),
    this.advanced = const V2SettingsSection(title: 'Advanced'),
    this.showReasoning = true,
    this.onReasoningChanged,
    this.onAddConnector,
    this.onProfileTap,
    this.onSignOut,
    this.onRetry,
    this.errorMessage = 'We could not load your settings.',
  });

  final V2SettingsHubStatus status;
  final V2SettingsProfile? profile;
  final V2SettingsSection account;
  final V2SettingsSection chat;
  final V2SettingsSection models;
  final V2SettingsSection dataControl;
  final V2SettingsSection advanced;
  final bool showReasoning;
  final ValueChanged<bool>? onReasoningChanged;
  final VoidCallback? onAddConnector;
  final VoidCallback? onProfileTap;
  final VoidCallback? onSignOut;
  final VoidCallback? onRetry;
  final String errorMessage;
}

/// Settings home. Rows only call the callbacks carried by [data]; this screen
/// never pushes another page itself.
class SettingsHubPage extends StatelessWidget {
  const SettingsHubPage({super.key, required this.data});

  final V2SettingsHubData data;

  /// The one order every settings list uses. The Models card sits between Chat
  /// and Data control and always starts with Connectors.
  static const _canonicalOrder = <String, List<String>>{
    'account': ['account', 'plan_billing', 'usage', 'credentials'],
    'chat': [
      'appearance',
      'memory',
      'shared_memory',
      'memory_files',
      'show_reasoning',
    ],
    'models': ['connectors', 'agent_presets', 'response_wait_limit'],
    'data_control': [
      'export_import',
      'permissions',
      'crash_reports',
      'storage',
      'delete_data',
      'reset_memory',
    ],
    'advanced': ['notifications', 'app_lock', 'account_health', 'about'],
  };

  /// Older wiring layers use short row ids. They still land in the same slot
  /// instead of drifting to the end of their card.
  static const _rowAliases = <String, String>{
    'presets': 'agent_presets',
    'response_wait': 'response_wait_limit',
    'export': 'export_import',
    'crash': 'crash_reports',
    'delete': 'delete_data',
  };

  @override
  Widget build(BuildContext context) {
    final sections = <V2SettingsSection>[
      _ordered('account', data.account),
      _ordered('chat', data.chat),
      _ordered('models', data.models),
      _ordered('data_control', data.dataControl),
      _ordered('advanced', data.advanced),
    ];
    final hasContent =
        data.profile != null ||
        sections.any((section) => section.items.isNotEmpty);

    final Widget body;
    switch (data.status) {
      case V2SettingsHubStatus.loading:
        body = const OSkeletonList(rows: 8);
      case V2SettingsHubStatus.error:
        body = OErrorState(message: data.errorMessage, onRetry: data.onRetry);
      case V2SettingsHubStatus.empty:
        body = _emptyState();
      case V2SettingsHubStatus.ready:
        body = hasContent ? _content(sections) : _emptyState();
    }

    return OScaffold(
      appBar: OAppBar(
        title: 'Settings',
        actions: [
          OIconButton(
            key: const ValueKey('settings-search'),
            icon: Icons.search_rounded,
            semanticLabel: 'Search settings',
            tooltip: 'Search settings',
            onPressed: () => _openSearch(context, sections),
          ),
        ],
      ),
      body: OFadeSlide(child: body),
    );
  }

  /// Opens the shared settings search over this hub's own (already ordered)
  /// sections, so the index can never drift from the rows on screen.
  Future<void> _openSearch(
    BuildContext context,
    List<V2SettingsSection> sections,
  ) {
    final status = switch (data.status) {
      V2SettingsHubStatus.loading => V2SettingsSearchStatus.loading,
      V2SettingsHubStatus.error => V2SettingsSearchStatus.error,
      V2SettingsHubStatus.ready ||
      V2SettingsHubStatus.empty => V2SettingsSearchStatus.ready,
    };
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => SettingsSearchPage(
          data: V2SettingsSearchData(
            sections: sections,
            status: status,
            errorMessage: data.errorMessage,
          ),
          onResultTap: (result) {
            // Close search first, then activate the row exactly as the hub
            // would. The reasoning switch is owned by the hub, not the model,
            // so it is toggled through the same callback as the row.
            Navigator.of(routeContext).maybePop();
            if (!result.item.enabled) return;
            if (result.item.id == 'show_reasoning') {
              final changed = data.onReasoningChanged;
              if (changed != null) changed(!data.showReasoning);
              return;
            }
            result.item.onTap?.call();
          },
          onRetry: data.onRetry,
        ),
      ),
    );
  }

  V2SettingsSection _ordered(String key, V2SettingsSection section) {
    final order = _canonicalOrder[key] ?? const <String>[];
    int rank(String id) {
      final canonical = _rowAliases[id] ?? id;
      final index = order.indexOf(canonical);
      return index == -1 ? order.length : index;
    }

    // Stable sort: rows that are not in the canonical list keep their order.
    final positions = List<int>.generate(section.items.length, (i) => i);
    positions.sort((a, b) {
      final byRank = rank(section.items[a].id);
      final against = rank(section.items[b].id);
      if (byRank != against) return byRank.compareTo(against);
      return a.compareTo(b);
    });
    return V2SettingsSection(
      title: section.title,
      items: [for (final index in positions) section.items[index]],
    );
  }

  Widget _emptyState() {
    return OEmptyState(
      icon: Icons.tune_rounded,
      title: 'No settings yet',
      message: 'Your settings will appear here when your account is ready.',
      action: OButton(
        label: 'Refresh settings',
        icon: Icons.refresh_rounded,
        onPressed: data.onRetry,
      ),
    );
  }

  Widget _content(List<V2SettingsSection> sections) {
    final profile = data.profile;
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
          if (profile != null)
            OCard(
              onTap: data.onProfileTap,
              semanticLabel:
                  '${profile.name}, ${profile.email}, ${profile.planLabel}',
              padding: const EdgeInsets.all(OSpace.m),
              child: _ProfileHeader(
                profile: profile,
                showChevron: data.onProfileTap != null,
              ),
            ),
          for (final section in sections)
            if (section.items.isNotEmpty) ...[
              OSectionHeader(
                label: section.title,
                padding: const EdgeInsets.fromLTRB(
                  OSpace.xs,
                  OSpace.xl,
                  OSpace.xs,
                  OSpace.s,
                ),
              ),
              _SectionCard(
                section: section,
                showReasoning: data.showReasoning,
                onReasoningChanged: data.onReasoningChanged,
                onAddConnector: data.onAddConnector,
              ),
            ],
          if (data.onSignOut != null) ...[
            const SizedBox(height: OSpace.xl),
            OButton(
              label: profile == null ? 'Log out' : 'Log out of ${profile.name}',
              icon: Icons.logout_rounded,
              variant: OButtonVariant.secondary,
              expand: true,
              onPressed: data.onSignOut,
            ),
          ],
          const SizedBox(height: OSpace.s),
        ],
      ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.profile, required this.showChevron});

  final V2SettingsProfile profile;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Row(
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            OAvatar(
              initials: profile.initials ?? profile.name,
              image: profile.image,
              size: 56,
              semanticLabel: '${profile.name} profile photo',
            ),
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: c.success,
                  shape: BoxShape.circle,
                  border: Border.all(color: c.surface, width: 2),
                ),
                child: Icon(Icons.check_rounded, size: 11, color: c.onAccent),
              ),
            ),
          ],
        ),
        const SizedBox(width: OSpace.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: OSpace.s,
                runSpacing: OSpace.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    profile.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: OType.h3.copyWith(color: c.text),
                  ),
                  OPill(label: profile.planLabel, tone: OPillTone.accent),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                profile.email,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ),
        if (showChevron)
          Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.section,
    required this.showReasoning,
    required this.onReasoningChanged,
    required this.onAddConnector,
  });

  final V2SettingsSection section;
  final bool showReasoning;
  final ValueChanged<bool>? onReasoningChanged;
  final VoidCallback? onAddConnector;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final rows = <Widget>[];
    for (var index = 0; index < section.items.length; index++) {
      final item = section.items[index];
      rows.add(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            OListRow(
              title: item.label,
              subtitle: item.subtitle,
              icon: item.icon,
              danger: item.danger,
              enabled: item.enabled,
              showChevron: true,
              onTap: _rowTap(item),
              trailing: _trailing(context, item),
            ),
            if (index != section.items.length - 1)
              Divider(height: 1, thickness: 1, indent: 64, color: c.hairline),
          ],
        ),
      );
    }
    return OCard(
      padding: EdgeInsets.zero,
      child: OStagger(children: rows),
    );
  }

  VoidCallback? _rowTap(V2SettingsItem item) {
    if (!item.enabled) return null;
    if (item.id == 'show_reasoning') {
      if (onReasoningChanged == null) return null;
      return () => onReasoningChanged!(!showReasoning);
    }
    return item.onTap;
  }

  Widget? _trailing(BuildContext context, V2SettingsItem item) {
    if (item.id == 'show_reasoning') {
      return _ReasoningToggle(
        value: showReasoning,
        onChanged: item.enabled ? onReasoningChanged : null,
      );
    }
    if (item.id == 'connectors') {
      return OIconButton(
        icon: Icons.add_rounded,
        semanticLabel: 'Add connector',
        tooltip: 'Add connector',
        onPressed: item.enabled ? onAddConnector : null,
      );
    }
    return null;
  }
}

class _ReasoningToggle extends StatelessWidget {
  const _ReasoningToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      label: 'Show reasoning',
      toggled: value,
      child: SizedBox(
        width: 52,
        height: OSpace.touch,
        child: Center(
          child: Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: c.onAccent,
            activeTrackColor: c.accentFill,
            inactiveThumbColor: c.textMuted,
            inactiveTrackColor: c.surfaceRaised,
            materialTapTargetSize: MaterialTapTargetSize.padded,
          ),
        ),
      ),
    );
  }
}
