import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import '../settings/settings_rows.dart';

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

/// Agent presets: one list. Tap a row to apply it; the row menu edits or
/// deletes a custom preset; the header action creates one.
///
/// The screen keeps a working copy of the list so a selection or a deletion
/// is visible at once. The caller still persists it; a page pushed once from
/// Settings has no listener on `AppState`.
class AgentPresetsPage extends StatefulWidget {
  const AgentPresetsPage({super.key, required this.data});

  final V2AgentPresetsPageData data;

  @override
  State<AgentPresetsPage> createState() => _AgentPresetsPageState();
}

class _AgentPresetsPageState extends State<AgentPresetsPage> {
  late List<V2AgentPreset> _presets;
  String? _selectedId;

  V2AgentPresetsPageData get data => widget.data;

  @override
  void initState() {
    super.initState();
    _adopt(data, null);
  }

  @override
  void didUpdateWidget(covariant AgentPresetsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.data, widget.data)) {
      _adopt(widget.data, oldWidget.data);
    }
  }

  /// Adopts only what the caller changed, so an unchanged rebuild cannot
  /// undo an optimistic selection or deletion.
  void _adopt(V2AgentPresetsPageData next, V2AgentPresetsPageData? prev) {
    if (prev == null || !identical(next.presets, prev.presets)) {
      _presets = List<V2AgentPreset>.of(next.presets);
    }
    if (prev == null || next.selectedId != prev.selectedId) {
      _selectedId = next.selectedId;
    }
  }

  void _select(V2AgentPreset preset) {
    final handler = data.onSelect;
    if (handler == null) return;
    setState(() => _selectedId = preset.id);
    handler(preset.id);
  }

  void _delete(V2AgentPreset preset) {
    setState(() {
      _presets = [
        for (final item in _presets)
          if (item.id != preset.id) item,
      ];
      if (_selectedId == preset.id) _selectedId = null;
    });
    data.onDelete?.call(preset.id);
  }

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: 'Agent presets',
      actions: [
        if (data.onCreate != null)
          OIconButton(
            key: const ValueKey<String>('presets-new'),
            icon: Icons.add_rounded,
            semanticLabel: 'New preset',
            onPressed: data.onCreate,
          ),
      ],
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final status = switch (data.status) {
      V2AgentPresetsStatus.loading => OStatus.loading,
      V2AgentPresetsStatus.error => OStatus.error,
      V2AgentPresetsStatus.empty => OStatus.empty,
      V2AgentPresetsStatus.ready => _presets.isEmpty
          ? OStatus.empty
          : OStatus.content,
    };
    return OStateView(
      status: status,
      errorMessage: data.errorMessage,
      onRetry: data.onRetry,
      emptyTitle: 'No presets yet',
      emptyBody: 'Make a preset to change how Ovid works.',
      emptyActionLabel: 'New preset',
      onEmptyAction: data.onCreate,
      skeletonRows: 6,
      child: _list(context),
    );
  }

  Widget _list(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xxl),
      children: [V2SettingsRowList(rows: [for (final p in _presets) _presetRow(context, p)])],
    );
  }

  /// One preset, one row: tile, name, the model it runs on, and the selected
  /// check. Custom presets carry the row menu (edit / delete).
  Widget _presetRow(BuildContext context, V2AgentPreset preset) {
    final c = OColors.of(context);
    final selected = _selectedId == preset.id;
    return V2SettingsRow(
      key: ValueKey<String>('preset-${preset.id}'),
      icon: preset.icon,
      title: preset.name,
      showChevron: false,
      stacksTrailing: true,
      onTap: data.onSelect == null ? null : () => _select(preset),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              preset.modelLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
          if (selected) ...[
            const SizedBox(width: OSpace.s),
            Icon(Icons.check_circle_rounded, size: 20, color: c.accentFill),
          ],
          if (!preset.builtIn) _presetMenu(context, preset),
        ],
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
            'Chats that used it keep their history.',
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
    if (confirmed == true) _delete(preset);
  }
}
