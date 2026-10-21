import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

enum V2AgentPresetsStatus { loading, ready, empty, error }

/// One agent preset. Built-in presets ship with Ovid; custom presets belong to
/// the user and can be edited or deleted.
@immutable
class V2AgentPreset {
  const V2AgentPreset({
    required this.id,
    required this.name,
    required this.description,
    required this.modelLabel,
    this.builtIn = false,
    this.icon = Icons.auto_awesome_rounded,
  });

  final String id;
  final String name;
  final String description;
  final String modelLabel;
  final bool builtIn;
  final IconData icon;
}

/// Injected state for the Agent presets screen.
@immutable
class V2AgentPresetsPageData {
  const V2AgentPresetsPageData({
    this.status = V2AgentPresetsStatus.ready,
    this.presets = const <V2AgentPreset>[],
    this.selectedId,
    this.onSelect,
    this.onCreate,
    this.onEdit,
    this.onDelete,
    this.onRetry,
    this.errorMessage = 'We could not load your presets.',
  });

  final V2AgentPresetsStatus status;
  final List<V2AgentPreset> presets;
  final String? selectedId;

  final ValueChanged<String>? onSelect;
  final VoidCallback? onCreate;
  final ValueChanged<String>? onEdit;
  final ValueChanged<String>? onDelete;
  final VoidCallback? onRetry;
  final String errorMessage;
}

/// Agent presets: built-in approaches plus the user's own presets.
class AgentPresetsPage extends StatelessWidget {
  const AgentPresetsPage({super.key, required this.data});

  final V2AgentPresetsPageData data;

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Agent presets'),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (data.status == V2AgentPresetsStatus.loading) {
      return const OFadeSlide(child: OSkeletonList(rows: 6));
    }
    if (data.status == V2AgentPresetsStatus.error) {
      return OErrorState(message: data.errorMessage, onRetry: data.onRetry);
    }
    if (data.status == V2AgentPresetsStatus.empty || data.presets.isEmpty) {
      return OEmptyState(
        icon: Icons.auto_awesome_outlined,
        title: 'No presets yet',
        message: 'Make a preset to change how Ovid works on your tasks.',
        action: OButton(
          label: 'New preset',
          icon: Icons.add_rounded,
          onPressed: data.onCreate,
        ),
      );
    }

    final builtIn = data.presets.where((preset) => preset.builtIn).toList();
    final custom = data.presets.where((preset) => !preset.builtIn).toList();

    return OFadeSlide(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          OSpace.screen,
          OSpace.l,
          OSpace.screen,
          OSpace.xxl,
        ),
        child: OStagger(
          children: [
            _explainer(context),
            if (builtIn.isNotEmpty)
              _presetSection(context, title: 'Built-in', presets: builtIn),
            if (custom.isNotEmpty)
              _presetSection(context, title: 'Your presets', presets: custom),
            Padding(
              padding: const EdgeInsets.only(top: OSpace.s),
              child: OButton(
                label: 'New preset',
                icon: Icons.add_rounded,
                expand: true,
                onPressed: data.onCreate,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _explainer(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      child: OCard(
        accent: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.auto_awesome_rounded, size: 20, color: c.accent),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Text(
                'Presets change how Ovid approaches a task.',
                style: OType.body.copyWith(color: c.text),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _presetSection(
    BuildContext context, {
    required String title,
    required List<V2AgentPreset> presets,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: title,
            padding: const EdgeInsets.only(bottom: OSpace.s),
          ),
          OStagger(
            children: [
              for (final preset in presets)
                Padding(
                  padding: const EdgeInsets.only(bottom: OSpace.m),
                  child: _presetCard(context, preset),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _presetCard(BuildContext context, V2AgentPreset preset) {
    final c = OColors.of(context);
    final selected = data.selectedId == preset.id;
    return OCard(
      accent: selected,
      padding: EdgeInsets.zero,
      onTap: data.onSelect == null ? null : () => data.onSelect!(preset.id),
      semanticLabel:
          '${preset.name} preset${selected ? ', selected' : ''}. '
          '${preset.description}',
      child: Padding(
        padding: const EdgeInsets.all(OSpace.l),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c.accentSoft,
                borderRadius: BorderRadius.circular(ORadius.m),
              ),
              child: Icon(preset.icon, size: 21, color: c.accent),
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: OSpace.s,
                          runSpacing: OSpace.xs,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              preset.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: OType.h3.copyWith(color: c.text),
                            ),
                            if (preset.builtIn)
                              _pill(
                                context,
                                label: 'Built-in',
                                foreground: c.textMuted,
                                background: c.surfaceAlt,
                              ),
                          ],
                        ),
                      ),
                      if (selected) ...[
                        const SizedBox(width: OSpace.s),
                        Icon(
                          Icons.check_circle_rounded,
                          size: 18,
                          color: c.accentFill,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: OSpace.xs),
                  Text(
                    preset.description,
                    style: OType.bodySm.copyWith(color: c.textMuted),
                  ),
                  const SizedBox(height: OSpace.s),
                  Row(
                    children: [
                      Icon(Icons.memory_rounded, size: 14, color: c.textFaint),
                      const SizedBox(width: OSpace.xs),
                      Flexible(
                        child: Text(
                          preset.modelLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OType.caption.copyWith(color: c.textFaint),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (!preset.builtIn) _presetMenu(context, preset),
          ],
        ),
      ),
    );
  }

  Widget _pill(
    BuildContext context, {
    required String label,
    required Color foreground,
    required Color background,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: OSpace.xs,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: OType.caption.copyWith(
          color: foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _presetMenu(BuildContext context, V2AgentPreset preset) {
    final c = OColors.of(context);
    final items = <PopupMenuEntry<String>>[
      if (data.onEdit != null)
        PopupMenuItem<String>(
          value: 'edit',
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 18, color: c.textMuted),
              const SizedBox(width: OSpace.m),
              Text('Edit', style: OType.bodySm.copyWith(color: c.text)),
            ],
          ),
        ),
      if (data.onDelete != null)
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded, size: 18, color: c.danger),
              const SizedBox(width: OSpace.m),
              Text('Delete', style: OType.bodySm.copyWith(color: c.danger)),
            ],
          ),
        ),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      width: OSpace.touch,
      height: OSpace.touch,
      child: PopupMenuButton<String>(
        tooltip: 'Preset options',
        icon: Icon(Icons.more_vert_rounded, color: c.textMuted),
        onSelected: (value) {
          if (value == 'edit') {
            data.onEdit?.call(preset.id);
          } else if (value == 'delete') {
            _confirmDelete(context, preset);
          }
        },
        itemBuilder: (context) => items,
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    V2AgentPreset preset,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final dialogColors = OColors.of(context);
        return AlertDialog(
          backgroundColor: dialogColors.surface,
          title: Text(
            'Delete ${preset.name}?',
            style: OType.h2.copyWith(color: dialogColors.text),
          ),
          content: Text(
            'This preset will be removed from your list. Chats that used it '
            'keep their history.',
            style: OType.bodySm.copyWith(color: dialogColors.textMuted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: dialogColors.danger),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      data.onDelete?.call(preset.id);
    }
  }
}
