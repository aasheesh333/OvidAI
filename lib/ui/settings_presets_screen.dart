import 'package:flutter/material.dart';

import '../core/cloud/account_settings_client.dart';
import '../core/cloud/cloud_session_store.dart';
import '../core/presets.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../l10n/l10n.dart';
import 'user_error.dart';
import 'widgets/aether_confirm.dart';
import 'widgets/aether_primitives.dart';

/// Test seam: resolves the server session id for the active chat.
@visibleForTesting
String? Function(String localId)? serverSessionIdForTest;

String? _serverIdFor(String localId) {
  final seam = serverSessionIdForTest;
  if (seam != null) return seam(localId);
  try {
    return CloudSessionStore.I.serverIdFor(localId) ??
        (RegExp(r'^[0-9a-f-]{36}$').hasMatch(localId) ? localId : null);
  } catch (_) {
    return null;
  }
}

/// SE-007 — Agent presets, backed by the server. Built-in presets come with
/// Ovid; custom presets (tool families switched off, an Ovid model pin, a
/// temperature) are stored on the user's account and enforced by the agent:
/// a switched-off tool is removed from the agent's tools and refused if
/// called anyway.
class PresetsScreen extends StatefulWidget {
  const PresetsScreen({super.key});

  @override
  State<PresetsScreen> createState() => _PresetsScreenState();
}

class _PresetsScreenState extends State<PresetsScreen> {
  CloudPresetCatalog? _catalog;
  bool _loading = true;
  String? _error;
  String? _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final c = await AccountSettingsClient.I.presets();
      if (!mounted) return;
      setState(() {
        _catalog = c;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e, l10n: context.l10n);
        _loading = false;
      });
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _edit([CloudCustomPreset? preset]) async {
    final catalog = _catalog;
    if (catalog == null) return;
    final saved = await Navigator.of(context).push<CloudCustomPreset>(
      MaterialPageRoute(
        builder: (_) => PresetEditorScreen(
          initial: preset,
          toolGroups: catalog.toolGroups,
          takenIds: catalog.custom.map((p) => p.id).toList(),
        ),
      ),
    );
    if (saved == null || !mounted) return;
    _snack(context.l10n.presetsSaved(saved.label));
    await _load();
  }

  Future<void> _delete(CloudCustomPreset preset) async {
    final l = context.l10n;
    final ok = await showAetherConfirmDialog(
      context,
      title: l.presetsDeleteTitle,
      message: l.presetsDeleteBody(preset.label),
      confirmLabel: l.presetsDeleteConfirm,
      cancelLabel: l.actionCancel,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = preset.id);
    try {
      await AccountSettingsClient.I.deletePreset(preset.id);
      for (final s in AppState.I.sessions) {
        if (s.customPresetId == preset.id) {
          s.customPresetId = null;
          s.presetId = 'standard';
        }
      }
      await AppState.I.persistSessions();
      if (!mounted) return;
      _snack(l.presetsDeleted);
      await _load();
    } catch (e) {
      if (mounted) _snack(friendlyError(e, l10n: l));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// Applies [presetId] to the active chat on the server and mirrors it
  /// locally (a built-in rides every message; a custom one is kept by the
  /// server and the local built-in id is cleared so it is not overwritten).
  Future<void> _useInChat(String presetId, {required bool custom}) async {
    final l = context.l10n;
    final app = AppState.I;
    final session = app.activeSession;
    final serverId = session == null ? null : _serverIdFor(session.id);
    if (session == null || serverId == null) {
      _snack(l.presetsNeedChat);
      return;
    }
    setState(() => _busy = presetId);
    try {
      await AccountSettingsClient.I.applyPreset(serverId, presetId);
      session.customPresetId = custom ? presetId : null;
      session.presetId = custom ? '' : presetId;
      await app.persistSessions();
      app.refresh();
      if (mounted) _snack(l.presetsApplied);
    } catch (e) {
      if (mounted) _snack(friendlyError(e, l10n: l));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final catalog = _catalog;
    final active = AppState.I.activeSession;
    // A built-in picked later in the chat rides the next message and
    // replaces the custom preset server-side, so it wins here too.
    final activeId = (active?.presetId.isNotEmpty ?? false)
        ? active!.presetId
        : (active?.customPresetId ?? 'standard');
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(leading: const BackButton(), title: Text(l.presetsTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(l.presetsIntro, style: AetherType.bodyMuted),
          const SizedBox(height: 16),
          if (_error != null)
            AetherCard(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.presetsLoadFailed, style: AetherType.title),
                  const SizedBox(height: 4),
                  Text(_error!, style: AetherType.bodyMuted),
                  const SizedBox(height: 8),
                  AetherSecondaryButton(label: l.actionRetry, onPressed: _load),
                ],
              ),
            )
          else if (_loading && catalog == null)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(strokeWidth: 1.6),
              ),
            )
          else if (catalog != null) ...[
            Text(l.presetsBuiltIn, style: AetherType.title),
            const SizedBox(height: 8),
            for (final p in PresetRegistry.all.where(
              (p) => catalog.builtIn.contains(p.id),
            )) ...[
              _tile(
                key: ValueKey('preset-${p.id}'),
                title: p.label,
                subtitle: p.description,
                active: activeId == p.id,
                busy: _busy == p.id,
                onUse: () => _useInChat(p.id, custom: false),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 16),
            Text(l.presetsCustom, style: AetherType.title),
            const SizedBox(height: 8),
            if (catalog.custom.isEmpty)
              Text(l.presetsCustomEmpty, style: AetherType.bodyMuted),
            for (final p in catalog.custom) ...[
              _tile(
                key: ValueKey('preset-${p.id}'),
                title: p.label,
                subtitle: _summary(l, p, catalog.toolGroups),
                active: activeId == p.id,
                busy: _busy == p.id,
                onUse: () => _useInChat(p.id, custom: true),
                onEdit: () => _edit(p),
                onDelete: () => _delete(p),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 8),
            if (catalog.custom.length < catalog.maxCustom)
              FilledButton.icon(
                key: const ValueKey('presets-new'),
                onPressed: () => _edit(),
                icon: const Icon(Icons.add, size: 18),
                label: Text(l.presetsNew),
              ),
          ],
        ],
      ),
    );
  }

  String _summary(
    AppLocalizations l,
    CloudCustomPreset p,
    List<PresetToolGroup> groups,
  ) {
    final off = [
      for (final g in groups)
        if (p.deniedGroups(groups).contains(g.id)) g.label,
    ];
    final parts = <String>[
      if (p.description.isNotEmpty) p.description,
      off.isEmpty ? l.presetsAllTools : l.presetsToolsOff(off.join(', ')),
      if (p.model != null) l.presetsModelPin(p.model!),
      if (p.temperature != null)
        l.presetsTemperatureValue(p.temperature!.toStringAsFixed(1)),
    ];
    return parts.join(' · ');
  }

  Widget _tile({
    required Key key,
    required String title,
    required String subtitle,
    required bool active,
    required bool busy,
    required VoidCallback onUse,
    VoidCallback? onEdit,
    VoidCallback? onDelete,
  }) {
    final l = context.l10n;
    return AetherCard(
      key: key,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: AetherType.title)),
              if (active)
                AetherPill(label: l.presetsInThisChat, color: Aether.success),
            ],
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: AetherType.bodyMuted),
          const SizedBox(height: 8),
          OverflowBar(
            spacing: 8,
            overflowSpacing: 4,
            children: [
              if (!active)
                AetherGhostButton(
                  label: l.presetsUseInChat,
                  icon: Icons.check,
                  onPressed: busy ? null : onUse,
                ),
              if (onEdit != null)
                AetherGhostButton(
                  label: l.presetsEdit,
                  icon: Icons.edit_outlined,
                  onPressed: busy ? null : onEdit,
                ),
              if (onDelete != null)
                AetherGhostButton(
                  label: l.presetsDeleteConfirm,
                  icon: Icons.delete_outline,
                  onPressed: busy ? null : onDelete,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Create or edit a custom preset. Pops the saved preset.
class PresetEditorScreen extends StatefulWidget {
  const PresetEditorScreen({
    super.key,
    this.initial,
    required this.toolGroups,
    required this.takenIds,
  });

  final CloudCustomPreset? initial;
  final List<PresetToolGroup> toolGroups;
  final List<String> takenIds;

  @override
  State<PresetEditorScreen> createState() => _PresetEditorScreenState();
}

class _PresetEditorScreenState extends State<PresetEditorScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name = TextEditingController(
    text: widget.initial?.label ?? '',
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.initial?.description ?? '',
  );
  late Set<String> _off;
  String? _model;
  double? _temperature;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _off = widget.initial?.deniedGroups(widget.toolGroups) ?? <String>{};
    _model = widget.initial?.model;
    _temperature = widget.initial?.temperature;
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  List<String> get _models {
    final managed = AppState.I.providerById(AppState.ovidCloudProviderId);
    final list = <String>{
      ...?managed?.models.where((m) => m != 'auto'),
      ?_model,
    }.toList()..sort();
    return list;
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final l = context.l10n;
    setState(() {
      _saving = true;
      _error = null;
    });
    final denied = <String>{
      for (final g in widget.toolGroups)
        if (_off.contains(g.id)) ...g.tools,
    }.toList();
    final preset = CloudCustomPreset(
      id:
          widget.initial?.id ??
          CloudCustomPreset.idFor(_name.text.trim(), widget.takenIds),
      label: _name.text.trim(),
      description: _description.text.trim(),
      deniedTools: denied,
      model: _model,
      temperature: _temperature,
    );
    try {
      final saved = await AccountSettingsClient.I.savePreset(preset);
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e, l10n: l));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const CloseButton(),
        title: Text(
          widget.initial == null ? l.presetsNew : l.presetsEditTitle,
        ),
      ),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              TextFormField(
                key: const ValueKey('preset-name'),
                controller: _name,
                maxLength: 60,
                decoration: InputDecoration(labelText: l.presetsNameLabel),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? l.presetsNameRequired : null,
              ),
              TextFormField(
                key: const ValueKey('preset-description'),
                controller: _description,
                maxLength: 200,
                decoration: InputDecoration(
                  labelText: l.presetsDescriptionLabel,
                ),
              ),
              const SizedBox(height: 8),
              Text(l.presetsToolsTitle, style: AetherType.title),
              const SizedBox(height: 4),
              Text(l.presetsToolsHelp, style: AetherType.bodyMuted),
              for (final g in widget.toolGroups)
                SwitchListTile(
                  key: ValueKey('preset-tool-${g.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(g.label),
                  value: !_off.contains(g.id),
                  onChanged: _saving
                      ? null
                      : (on) => setState(() {
                          if (on) {
                            _off.remove(g.id);
                          } else {
                            _off.add(g.id);
                          }
                        }),
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                key: const ValueKey('preset-model'),
                initialValue: _model,
                isExpanded: true,
                decoration: InputDecoration(labelText: l.presetsModelLabel),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(l.presetsModelChat),
                  ),
                  for (final m in _models)
                    DropdownMenuItem<String?>(value: m, child: Text(m)),
                ],
                onChanged: _saving ? null : (v) => setState(() => _model = v),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                key: const ValueKey('preset-temperature-toggle'),
                contentPadding: EdgeInsets.zero,
                title: Text(l.presetsTemperatureLabel),
                subtitle: Text(
                  _temperature == null
                      ? l.presetsTemperatureDefault
                      : l.presetsTemperatureValue(
                          _temperature!.toStringAsFixed(1),
                        ),
                ),
                value: _temperature != null,
                onChanged: _saving
                    ? null
                    : (on) => setState(() => _temperature = on ? 0.7 : null),
              ),
              if (_temperature != null)
                Slider(
                  value: _temperature!,
                  min: 0,
                  max: 2,
                  divisions: 20,
                  label: _temperature!.toStringAsFixed(1),
                  onChanged: _saving
                      ? null
                      : (v) => setState(() => _temperature = v),
                ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(color: Aether.dangerC, fontSize: 13),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('preset-save'),
                onPressed: _saving ? null : _save,
                child: Text(_saving ? l.keysSaving : l.presetsSave),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
