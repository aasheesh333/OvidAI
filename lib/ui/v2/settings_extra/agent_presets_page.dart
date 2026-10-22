import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import '../settings/settings_rows.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

enum V2AgentPresetsStatus { loading, ready, empty, error }

/// One model a preset can pin. A preset with no pin follows the chat's model;
/// the picker always offers that default first.
@immutable
class V2PresetModelOption {
  const V2PresetModelOption({required this.id, required this.label});

  final String id;
  final String label;
}

/// One agent access mode a preset can remember. The ids mirror the server's
/// `AgentMode` names (`safe`, `auto`, `drive`, `studio`).
@immutable
class V2PresetPermissionMode {
  const V2PresetPermissionMode({required this.id, required this.label});

  final String id;
  final String label;
}

/// The four modes the product offers, in escalation order.
const List<V2PresetPermissionMode> v2PresetPermissionModes =
    <V2PresetPermissionMode>[
      V2PresetPermissionMode(id: 'safe', label: 'Read-Only'),
      V2PresetPermissionMode(id: 'auto', label: 'General'),
      V2PresetPermissionMode(id: 'drive', label: 'Full Access'),
      V2PresetPermissionMode(id: 'studio', label: 'Studio'),
    ];

/// The waits the editor offers, matching Settings → Response wait.
const List<int> v2PresetWaitOptions = <int>[30, 60, 120, 300, 600];

/// "30 s", "1 min", "5 min", "1 min 30 s".
String v2PresetWaitLabel(int seconds) {
  if (seconds < 60) return '$seconds s';
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  return rest == 0 ? '$minutes min' : '$minutes min $rest s';
}

String _permissionLabel(String id) {
  for (final mode in v2PresetPermissionModes) {
    if (mode.id == id) return mode.label;
  }
  // An id this build does not know is still the truth; never relabel it as a
  // default mode the preset did not choose.
  return id;
}

/// One agent preset. Built-in presets ship with Ovid and can only be
/// duplicated; custom presets belong to the user and can be edited or deleted.
@immutable
class V2AgentPreset {
  const V2AgentPreset({
    required this.id,
    required this.name,
    required this.description,
    required this.modelLabel,
    this.modelId,
    this.builtIn = false,
    this.icon = Icons.auto_awesome_rounded,
    this.responseWaitSeconds,
    this.permissionModeId,
  });

  final String id;
  final String name;
  final String description;
  final String modelLabel;

  /// The model pin. Null means "follow the chat's model"; [modelLabel] is the
  /// display value either way.
  final String? modelId;
  final bool builtIn;
  final IconData icon;

  /// The wait this preset records, in seconds. Null when the caller has no
  /// stored value; the row then says nothing rather than inventing a default.
  final int? responseWaitSeconds;

  /// The access mode this preset records. Null when not stored.
  final String? permissionModeId;

  String? get waitLabel => responseWaitSeconds == null
      ? null
      : v2PresetWaitLabel(responseWaitSeconds!);
  String? get permissionLabel =>
      (permissionModeId == null || permissionModeId!.isEmpty)
      ? null
      : _permissionLabel(permissionModeId!);

  /// What this preset changes, one line: the model, the wait, the access mode
  /// and, for a built-in, that it cannot be edited or deleted.
  String get settingsLabel {
    final parts = <String>[
      if (builtIn) 'Built-in',
      modelLabel,
      ?waitLabel,
      ?permissionLabel,
    ];
    return parts.join(' · ');
  }

  /// The row's spoken and visible subtitle, including the active state.
  String rowLabel({required bool active}) =>
      active ? '$settingsLabel · Active' : settingsLabel;
}

/// The editable half of a preset: everything the editor can change.
@immutable
class V2AgentPresetDraft {
  const V2AgentPresetDraft({
    required this.name,
    this.description = '',
    required this.modelId,
    required this.modelLabel,
    this.responseWaitSeconds = 300,
    this.permissionModeId = 'auto',
  });

  factory V2AgentPresetDraft.fromPreset(V2AgentPreset preset) {
    return V2AgentPresetDraft(
      name: preset.name,
      description: preset.description,
      modelId: preset.modelId ?? '',
      modelLabel: preset.modelLabel,
      responseWaitSeconds: preset.responseWaitSeconds ?? 300,
      permissionModeId: preset.permissionModeId ?? 'auto',
    );
  }

  final String name;
  final String description;
  final String modelId;
  final String modelLabel;
  final int responseWaitSeconds;
  final String permissionModeId;

  V2AgentPresetDraft copyWith({
    String? name,
    String? description,
    String? modelId,
    String? modelLabel,
    int? responseWaitSeconds,
    String? permissionModeId,
  }) {
    return V2AgentPresetDraft(
      name: name ?? this.name,
      description: description ?? this.description,
      modelId: modelId ?? this.modelId,
      modelLabel: modelLabel ?? this.modelLabel,
      responseWaitSeconds: responseWaitSeconds ?? this.responseWaitSeconds,
      permissionModeId: permissionModeId ?? this.permissionModeId,
    );
  }
}

/// Persists the active preset. Throws when the write fails.
typedef V2PresetApply = Future<void> Function(String id);

/// Creates a preset from a validated draft. Throws when the write fails.
typedef V2PresetCreate = Future<void> Function(V2AgentPresetDraft draft);

/// Saves an edited preset. Throws when the write fails.
typedef V2PresetUpdate =
    Future<void> Function(String id, V2AgentPresetDraft draft);

/// Deletes a custom preset. Throws when the write fails.
typedef V2PresetDelete = Future<void> Function(String id);

/// Injected state for the Agent presets screen.
@immutable
class V2AgentPresetsPageData {
  const V2AgentPresetsPageData({
    this.status = V2AgentPresetsStatus.ready,
    this.presets = const <V2AgentPreset>[],
    this.selectedId,
    this.models = const <V2PresetModelOption>[
      V2PresetModelOption(id: 'auto', label: 'Auto'),
    ],
    this.defaultResponseWaitSeconds = 300,
    this.onSelect,
    this.onCreate,
    this.onEdit,
    this.onDelete,
    this.onRetry,
    this.onApply,
    this.onCreatePreset,
    this.onUpdatePreset,
    this.onDeletePreset,
    this.errorMessage = 'We could not load your presets.',
  });

  final V2AgentPresetsStatus status;
  final List<V2AgentPreset> presets;
  final String? selectedId;

  /// The models the editor offers. Auto is the first row and the default.
  final List<V2PresetModelOption> models;

  /// The wait a new preset starts with, in seconds.
  final int defaultResponseWaitSeconds;

  // Legacy synchronous hooks. They keep the existing Settings route working;
  // the async hooks below report failure and carry the full draft.

  /// Applies a preset. Kept as the fallback for [onApply].
  final ValueChanged<String>? onSelect;

  /// Asks the caller to open its own create flow. Used only when
  /// [onCreatePreset] is missing.
  final VoidCallback? onCreate;

  /// Opens the caller's own edit flow. Used only when [onUpdatePreset] is
  /// missing.
  final ValueChanged<String>? onEdit;

  /// Deletes a preset. Kept as the fallback for [onDeletePreset].
  final ValueChanged<String>? onDelete;

  final VoidCallback? onRetry;

  /// The real persistence hooks. Each returns only after the write lands, so
  /// the screen can show a saving state and roll back on failure.
  final V2PresetApply? onApply;
  final V2PresetCreate? onCreatePreset;
  final V2PresetUpdate? onUpdatePreset;
  final V2PresetDelete? onDeletePreset;

  final String errorMessage;
}

/// Agent presets: one list. Tap a row to apply it; the row menu edits,
/// duplicates or deletes; the header action creates one.
///
/// The screen keeps a working copy of the list so a selection, a deletion or a
/// duplicate is visible at once. The caller persists it through the async
/// hooks; a write that throws is reported and the row is restored.
class AgentPresetsPage extends StatefulWidget {
  const AgentPresetsPage({super.key, required this.data});

  final V2AgentPresetsPageData data;

  @override
  State<AgentPresetsPage> createState() => _AgentPresetsPageState();
}

class _AgentPresetsPageState extends State<AgentPresetsPage> {
  late List<V2AgentPreset> _presets;
  String? _selectedId;
  String? _applyingId;
  String? _deletingId;
  bool _saving = false;
  int _localSeq = 0;

  V2AgentPresetsPageData get data => widget.data;

  bool get _busy => _saving || _deletingId != null;

  bool get _canCreate => data.onCreatePreset != null || data.onCreate != null;

  List<V2PresetModelOption> get _models {
    if (data.models.isNotEmpty) return data.models;
    return const <V2PresetModelOption>[
      V2PresetModelOption(id: 'auto', label: 'Auto'),
    ];
  }

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
  /// undo an optimistic selection, deletion or duplicate.
  void _adopt(V2AgentPresetsPageData next, V2AgentPresetsPageData? prev) {
    if (prev == null || !identical(next.presets, prev.presets)) {
      _presets = List<V2AgentPreset>.of(next.presets);
    }
    if (prev == null || next.selectedId != prev.selectedId) {
      _selectedId = next.selectedId;
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Writes the active preset, then moves the marker. A failed write puts the
  /// marker back where it was instead of leaving a lie on screen.
  Future<void> _apply(V2AgentPreset preset) async {
    if (_busy || _applyingId != null || _selectedId == preset.id) return;
    final apply = data.onApply;
    final select = data.onSelect;
    if (apply == null && select == null) return;

    final previous = _selectedId;
    setState(() {
      _selectedId = preset.id;
      _applyingId = preset.id;
    });
    try {
      if (apply != null) {
        await apply(preset.id);
      } else {
        await Future<void>.sync(() => select!(preset.id));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _selectedId = previous);
      _snack('Could not apply preset.');
    } finally {
      if (mounted) setState(() => _applyingId = null);
    }
  }

  Future<void> _create() async {
    if (_busy) return;
    final save = data.onCreatePreset;
    if (save == null) {
      // The caller owns its create flow; it rebuilds this screen when done.
      data.onCreate?.call();
      return;
    }
    final draft = await showOSheet<V2AgentPresetDraft>(
      context,
      builder: (_) => _PresetEditorSheet(
        title: 'New preset',
        initial: V2AgentPresetDraft(
          name: '',
          modelId: _models.first.id,
          modelLabel: _models.first.label,
          responseWaitSeconds: data.defaultResponseWaitSeconds
              .clamp(30, 600)
              .toInt(),
        ),
        models: _models,
        takenNames: _takenNames(),
        onSave: save,
      ),
    );
    if (draft == null || !mounted) return;
    // The caller may already have rebuilt the list from the persisted write;
    // only add the row when it is not there yet.
    if (_hasName(draft.name)) return;
    setState(() {
      _presets = [
        ..._presets,
        _presetFromDraft(draft, id: _localId(), icon: Icons.tune_rounded),
      ];
    });
  }

  Future<void> _edit(V2AgentPreset preset) async {
    if (preset.builtIn || _busy) return;
    final update = data.onUpdatePreset;
    if (update == null) {
      data.onEdit?.call(preset.id);
      return;
    }
    final draft = await showOSheet<V2AgentPresetDraft>(
      context,
      builder: (_) => _PresetEditorSheet(
        title: 'Edit preset',
        initial: _draftFor(preset),
        models: _models,
        takenNames: _takenNames(excludeId: preset.id),
        onSave: (draft) => update(preset.id, draft),
      ),
    );
    if (draft == null || !mounted) return;
    setState(() {
      _presets = [
        for (final item in _presets)
          if (item.id == preset.id) _mergeDraft(item, draft) else item,
      ];
    });
  }

  /// Copies a preset under a free name. Built-ins can be duplicated but never
  /// edited or deleted, so this is their only row action.
  Future<void> _duplicate(V2AgentPreset preset) async {
    final save = data.onCreatePreset;
    if (save == null || _busy) return;
    final draft = _draftFor(preset).copyWith(name: _copyName(preset.name));
    setState(() => _saving = true);
    try {
      await save(draft);
      if (!mounted) return;
      if (_hasName(draft.name)) return;
      setState(() {
        _presets = [
          ..._presets,
          _presetFromDraft(draft, id: _localId(), icon: Icons.tune_rounded),
        ];
      });
    } catch (_) {
      if (mounted) _snack('Could not save preset.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(V2AgentPreset preset) async {
    if (_busy) return;
    // Built-ins ship with Ovid and are never removable. The guard is also a
    // last line of defence for a product that must keep one built-in preset.
    if (preset.builtIn || _wouldRemoveLastBuiltIn(preset)) return;
    final remove = data.onDeletePreset;
    final legacy = data.onDelete;
    if (remove == null && legacy == null) return;

    final confirmed = await _confirmDelete(preset);
    if (!confirmed || !mounted) return;

    setState(() => _deletingId = preset.id);
    try {
      if (remove != null) {
        await remove(preset.id);
      } else {
        await Future<void>.sync(() => legacy!(preset.id));
      }
      if (!mounted) return;
      setState(() {
        _presets = [
          for (final item in _presets)
            if (item.id != preset.id) item,
        ];
        if (_selectedId == preset.id) _selectedId = null;
      });
    } catch (_) {
      if (mounted) _snack('Could not delete preset.');
    } finally {
      if (mounted) setState(() => _deletingId = null);
    }
  }

  bool _wouldRemoveLastBuiltIn(V2AgentPreset preset) {
    if (!preset.builtIn) return false;
    return _presets.where((item) => item.builtIn).length <= 1;
  }

  bool _canDelete(V2AgentPreset preset) {
    if (preset.builtIn || _wouldRemoveLastBuiltIn(preset)) return false;
    return data.onDeletePreset != null || data.onDelete != null;
  }

  bool _canEdit(V2AgentPreset preset) {
    if (preset.builtIn) return false;
    return data.onUpdatePreset != null || data.onEdit != null;
  }

  bool _canDuplicate() => data.onCreatePreset != null;

  String _localId() => 'local-${_localSeq++}';

  bool _hasName(String name) {
    final needle = name.trim().toLowerCase();
    return _presets.any((preset) => preset.name.trim().toLowerCase() == needle);
  }

  Set<String> _takenNames({String? excludeId}) {
    return <String>{
      for (final preset in _presets)
        if (preset.id != excludeId) preset.name.trim().toLowerCase(),
    };
  }

  V2AgentPresetDraft _draftFor(V2AgentPreset preset) {
    final base = V2AgentPresetDraft.fromPreset(preset);
    if (base.modelId.isNotEmpty) return base;
    for (final model in _models) {
      if (model.label == preset.modelLabel) {
        return base.copyWith(modelId: model.id, modelLabel: model.label);
      }
    }
    return base.copyWith(
      modelId: _models.first.id,
      modelLabel: _models.first.label,
    );
  }

  V2AgentPreset _presetFromDraft(
    V2AgentPresetDraft draft, {
    required String id,
    required IconData icon,
  }) {
    return V2AgentPreset(
      id: id,
      name: draft.name,
      description: draft.description,
      modelLabel: draft.modelLabel,
      modelId: draft.modelId,
      icon: icon,
      responseWaitSeconds: draft.responseWaitSeconds,
      permissionModeId: draft.permissionModeId,
    );
  }

  V2AgentPreset _mergeDraft(V2AgentPreset base, V2AgentPresetDraft draft) {
    return V2AgentPreset(
      id: base.id,
      name: draft.name,
      description: base.description,
      modelLabel: draft.modelLabel,
      modelId: draft.modelId,
      builtIn: base.builtIn,
      icon: base.icon,
      responseWaitSeconds: draft.responseWaitSeconds,
      permissionModeId: draft.permissionModeId,
    );
  }

  String _copyName(String name) {
    final base = name.trim();
    final taken = _takenNames();
    String candidate(String suffix) {
      final room = 40 - suffix.length;
      final stem = base.length > room
          ? base.substring(0, room).trimRight()
          : base;
      return '$stem$suffix';
    }

    final first = candidate(' copy');
    if (!taken.contains(first.toLowerCase())) return first;
    for (var index = 2; index < 100; index++) {
      final next = candidate(' copy $index');
      if (!taken.contains(next.toLowerCase())) return next;
    }
    return first;
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OScreen(
      title: 'Agent presets',
      headerBottom: _busy
          ? PreferredSize(
              preferredSize: const Size.fromHeight(OSpace.xxs),
              child: LinearProgressIndicator(
                key: const ValueKey<String>('presets-busy'),
                minHeight: OSpace.xxs,
                backgroundColor: Colors.transparent,
                color: c.accentFill,
              ),
            )
          : null,
      actions: [
        if (_canCreate)
          OIconButton(
            key: const ValueKey<String>('presets-new'),
            icon: Icons.add_rounded,
            semanticLabel: 'New preset',
            onPressed: _busy ? null : () => unawaited(_create()),
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
      V2AgentPresetsStatus.ready =>
        _presets.isEmpty ? OStatus.empty : OStatus.content,
    };
    return OStateView(
      status: status,
      errorMessage: data.errorMessage,
      onRetry: data.onRetry,
      emptyTitle: 'No presets yet',
      emptyBody: 'Make a preset to change how Ovid works.',
      emptyActionLabel: _canCreate ? 'New preset' : null,
      onEmptyAction: _canCreate ? () => unawaited(_create()) : null,
      skeletonRows: 6,
      child: _list(context),
    );
  }

  Widget _list(BuildContext context) {
    final c = OColors.of(context);
    return ListView.separated(
      padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xxl),
      itemCount: _presets.length,
      separatorBuilder: (_, _) => Divider(
        height: 1,
        thickness: 1,
        indent: v2SettingsRowDividerIndent,
        color: c.hairline,
      ),
      itemBuilder: (context, index) => _presetRow(context, _presets[index]),
    );
  }

  /// One preset, one row: tile, name, what it changes, the active check and
  /// the row menu. The subtitle is the spoken label, so a screen reader hears
  /// the name, the settings and whether the preset is active.
  Widget _presetRow(BuildContext context, V2AgentPreset preset) {
    final c = OColors.of(context);
    final selected = _selectedId == preset.id;
    final applying = _applyingId == preset.id;
    final deleting = _deletingId == preset.id;
    final menu = _presetMenu(context, preset);

    return V2SettingsRow(
      key: ValueKey<String>('preset-${preset.id}'),
      icon: preset.icon,
      title: preset.name,
      subtitle: preset.rowLabel(active: selected),
      showChevron: false,
      stacksTrailing: true,
      enabled: !deleting,
      onTap: (data.onApply == null && data.onSelect == null) || deleting
          ? null
          : () => unawaited(_apply(preset)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (applying)
            SizedBox(
              key: ValueKey<String>('preset-applying-${preset.id}'),
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: c.accentFill,
              ),
            )
          else if (selected)
            Icon(Icons.check_circle_rounded, size: 20, color: c.accentFill),
          if (deleting) ...[
            const SizedBox(width: OSpace.s),
            SizedBox(
              key: ValueKey<String>('preset-deleting-${preset.id}'),
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: c.textMuted,
              ),
            ),
          ] else if (menu != null) ...[
            const SizedBox(width: OSpace.s),
            menu,
          ],
        ],
      ),
    );
  }

  Widget? _presetMenu(BuildContext context, V2AgentPreset preset) {
    final c = OColors.of(context);
    final canEdit = _canEdit(preset);
    final canDuplicate = _canDuplicate();
    final canDelete = _canDelete(preset);
    if (!canEdit && !canDuplicate && !canDelete) return null;

    final items = <PopupMenuEntry<String>>[
      if (canEdit)
        PopupMenuItem<String>(
          value: 'edit',
          child: _menuRow(
            icon: Icons.edit_outlined,
            label: 'Edit',
            spoken: 'Edit ${preset.name}',
            color: c.textMuted,
          ),
        ),
      if (canDuplicate)
        PopupMenuItem<String>(
          value: 'duplicate',
          child: _menuRow(
            icon: Icons.copy_rounded,
            label: 'Duplicate',
            spoken: 'Duplicate ${preset.name}',
            color: c.textMuted,
          ),
        ),
      if (canDelete)
        PopupMenuItem<String>(
          value: 'delete',
          child: _menuRow(
            icon: Icons.delete_outline_rounded,
            label: 'Delete',
            spoken: 'Delete ${preset.name}, cannot be undone',
            color: c.danger,
          ),
        ),
    ];

    return SizedBox(
      width: OSpace.touch,
      height: OSpace.touch,
      child: PopupMenuButton<String>(
        key: ValueKey<String>('preset-menu-${preset.id}'),
        tooltip: 'Options for ${preset.name}',
        icon: Icon(Icons.more_vert_rounded, color: c.textMuted),
        onSelected: (value) {
          switch (value) {
            case 'edit':
              unawaited(_edit(preset));
            case 'duplicate':
              unawaited(_duplicate(preset));
            case 'delete':
              unawaited(_delete(preset));
          }
        },
        itemBuilder: (context) => items,
      ),
    );
  }

  Widget _menuRow({
    required IconData icon,
    required String label,
    required String spoken,
    required Color color,
  }) {
    return Semantics(
      label: spoken,
      button: true,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: OSpace.m),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.bodySm.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDelete(V2AgentPreset preset) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final dialogColors = OColors.of(context);
        return AlertDialog(
          scrollable: true,
          backgroundColor: dialogColors.surface,
          title: Text(
            'Delete ${preset.name}?',
            style: OType.h2.copyWith(color: dialogColors.text),
          ),
          content: Text(
            'This cannot be undone.',
            style: OType.bodySm.copyWith(color: dialogColors.textMuted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            Semantics(
              hint: 'Cannot be undone',
              child: TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(
                  foregroundColor: dialogColors.danger,
                ),
                child: const Text('Delete'),
              ),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }
}

/// The create / edit sheet. It validates locally, then waits for the caller's
/// write; a failed write keeps the sheet open with an inline error.
class _PresetEditorSheet extends StatefulWidget {
  const _PresetEditorSheet({
    required this.title,
    required this.initial,
    required this.models,
    required this.takenNames,
    required this.onSave,
  });

  final String title;
  final V2AgentPresetDraft initial;
  final List<V2PresetModelOption> models;

  /// Lowercased, trimmed names that cannot be reused.
  final Set<String> takenNames;
  final V2PresetCreate onSave;

  @override
  State<_PresetEditorSheet> createState() => _PresetEditorSheetState();
}

class _PresetEditorSheetState extends State<_PresetEditorSheet> {
  late final TextEditingController _name;
  late final List<V2PresetModelOption> _models;
  late final List<int> _waits;
  late final List<V2PresetPermissionMode> _permissions;
  late String _modelId;
  late int _wait;
  late String _permission;
  String? _nameError;
  String? _saveError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial.name);
    _models = List<V2PresetModelOption>.of(widget.models);
    if (_models.isEmpty) {
      _models.add(
        V2PresetModelOption(
          id: widget.initial.modelId,
          label: widget.initial.modelLabel,
        ),
      );
    }
    if (widget.initial.modelId.isNotEmpty &&
        !_models.any((model) => model.id == widget.initial.modelId)) {
      _models.add(
        V2PresetModelOption(
          id: widget.initial.modelId,
          label: widget.initial.modelLabel,
        ),
      );
    }
    _modelId = widget.initial.modelId.isEmpty
        ? _models.first.id
        : widget.initial.modelId;
    // Keep a stored wait or mode the options list does not know about, so an
    // edit never silently rewrites it to a default.
    _waits = List<int>.of(v2PresetWaitOptions);
    if (!_waits.contains(widget.initial.responseWaitSeconds)) {
      _waits.add(widget.initial.responseWaitSeconds);
      _waits.sort();
    }
    _wait = widget.initial.responseWaitSeconds.clamp(30, 600).toInt();
    _permissions = List<V2PresetPermissionMode>.of(v2PresetPermissionModes);
    if (!_permissions.any(
      (mode) => mode.id == widget.initial.permissionModeId,
    )) {
      _permissions.add(
        V2PresetPermissionMode(
          id: widget.initial.permissionModeId,
          label: _permissionLabel(widget.initial.permissionModeId),
        ),
      );
    }
    _permission = widget.initial.permissionModeId;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  V2PresetModelOption get _model {
    for (final model in _models) {
      if (model.id == _modelId) return model;
    }
    return _models.first;
  }

  String? _validateName(String raw) {
    final name = raw.trim();
    if (name.isEmpty) return 'Enter a name.';
    if (name.length > 40) return 'Use 40 characters or fewer.';
    if (widget.takenNames.contains(name.toLowerCase())) {
      return 'That name is taken.';
    }
    return null;
  }

  Future<void> _save() async {
    if (_saving) return;
    final error = _validateName(_name.text);
    if (error != null) {
      setState(() => _nameError = error);
      return;
    }
    final draft = V2AgentPresetDraft(
      name: _name.text.trim(),
      description: widget.initial.description,
      modelId: _model.id,
      modelLabel: _model.label,
      responseWaitSeconds: _wait,
      permissionModeId: _permission,
    );
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await widget.onSave(draft);
      if (mounted) Navigator.pop(context, draft);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = 'Could not save preset.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final viewInsets = MediaQuery.viewInsetsOf(context).bottom;
    return PopScope(
      canPop: !_saving,
      child: Padding(
        padding: EdgeInsets.only(bottom: viewInsets),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OSheetHeader(
                title: widget.title,
                onClose: _saving ? null : () => Navigator.pop(context),
              ),
              const SizedBox(height: OSpace.s),
              TextField(
                key: const ValueKey<String>('preset-name'),
                controller: _name,
                autofocus: true,
                enabled: !_saving,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                style: OType.body.copyWith(color: c.text),
                decoration: InputDecoration(
                  labelText: 'Name',
                  hintText: 'Preset name',
                  helperText: '40 characters max',
                  errorText: _nameError,
                ),
                onChanged: (_) {
                  if (_nameError != null) setState(() => _nameError = null);
                },
                onSubmitted: (_) => unawaited(_save()),
              ),
              const SizedBox(height: OSpace.l),
              _fieldLabel(context, 'Model'),
              Wrap(
                spacing: OSpace.s,
                runSpacing: OSpace.s,
                children: [
                  for (final model in _models)
                    OChip(
                      key: ValueKey<String>('preset-model-${model.id}'),
                      label: model.label,
                      selected: model.id == _modelId,
                      onTap: _saving
                          ? null
                          : () => setState(() => _modelId = model.id),
                    ),
                ],
              ),
              const SizedBox(height: OSpace.l),
              _fieldLabel(context, 'Response wait'),
              Wrap(
                spacing: OSpace.s,
                runSpacing: OSpace.s,
                children: [
                  for (final seconds in _waits)
                    OChip(
                      key: ValueKey<String>('preset-wait-$seconds'),
                      label: v2PresetWaitLabel(seconds),
                      selected: seconds == _wait,
                      onTap: _saving
                          ? null
                          : () => setState(() => _wait = seconds),
                    ),
                ],
              ),
              const SizedBox(height: OSpace.l),
              _fieldLabel(context, 'Permission'),
              Wrap(
                spacing: OSpace.s,
                runSpacing: OSpace.s,
                children: [
                  for (final mode in _permissions)
                    OChip(
                      key: ValueKey<String>('preset-permission-${mode.id}'),
                      label: mode.label,
                      selected: mode.id == _permission,
                      onTap: _saving
                          ? null
                          : () => setState(() => _permission = mode.id),
                    ),
                ],
              ),
              if (_saveError != null) ...[
                const SizedBox(height: OSpace.l),
                Text(
                  _saveError!,
                  key: const ValueKey<String>('preset-save-error'),
                  style: OType.caption.copyWith(color: c.danger),
                ),
              ],
              const SizedBox(height: OSpace.xl),
              Row(
                children: [
                  Expanded(
                    child: OButton(
                      key: const ValueKey<String>('preset-cancel'),
                      label: 'Cancel',
                      variant: OButtonVariant.secondary,
                      onPressed: _saving ? null : () => Navigator.pop(context),
                    ),
                  ),
                  const SizedBox(width: OSpace.m),
                  Expanded(
                    child: OButton(
                      key: const ValueKey<String>('preset-save'),
                      label: 'Save',
                      loading: _saving,
                      onPressed: _saving ? null : () => unawaited(_save()),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fieldLabel(BuildContext context, String label) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.s),
      child: Text(label, style: OType.caption.copyWith(color: c.textMuted)),
    );
  }
}
