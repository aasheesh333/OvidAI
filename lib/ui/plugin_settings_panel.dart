import 'package:flutter/material.dart';

import '../core/native_plugin.dart';
import '../core/plugin_manifest.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Schema-driven plugin settings form (audit 2026-09-25).
///
/// Plugins contribute DATA — declarative `{key, label, secret, hint}`
/// fields on the normalized manifest ([PluginSettingsField]) or a native
/// capability's `configFields` — and the host renders them here as plain
/// text inputs (masked for `secret: true`) with helper text from `hint`.
/// There is deliberately NO WebView, NO JS and NO arbitrary code execution:
/// a plugin can never ship its own renderer, so a hostile manifest cannot
/// turn the settings surface into an execution surface.
///
/// Values read and write through the EXISTING [NativePluginConfigStore], so
/// one storage path serves native and installed plugins: secret values go
/// to FlutterSecureStorage and never into SharedPreferences, logs, or the
/// manifest metadata (spec §5.1 — declarations carry names/labels only).
class PluginSettingsPanel extends StatefulWidget {
  const PluginSettingsPanel({
    super.key,
    required this.pluginName,
    required this.fields,
    this.store,
    this.onSaved,
  });

  /// Config-storage namespace — the canonical `publisher/name` id for an
  /// installed plugin, the display name for a native capability.
  /// [NativePluginConfigStore] slugifies it into its storage keys.
  final String pluginName;

  /// The declarative fields to render (shared model — see
  /// [configFieldsForSettings] for the manifest-side conversion).
  final List<NativePluginConfigField> fields;

  /// Injectable store; defaults to the process-wide
  /// [NativePluginConfigStore.I].
  final NativePluginConfigStore? store;

  /// Called after a successful save.
  final VoidCallback? onSaved;

  @override
  State<PluginSettingsPanel> createState() => _PluginSettingsPanelState();
}

class _PluginSettingsPanelState extends State<PluginSettingsPanel> {
  late final NativePluginConfigStore _store;
  late final Map<String, TextEditingController> _controllers;
  bool _loading = true;
  bool _saving = false;
  bool _saved = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? NativePluginConfigStore.I;
    _controllers = {
      for (final f in widget.fields) f.key: TextEditingController(),
    };
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final values = await _store.readAll(
        pluginName: widget.pluginName,
        fields: widget.fields,
      );
      if (!mounted) return;
      setState(() {
        for (final e in values.entries) {
          _controllers[e.key]?.text = e.value;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not read saved settings: $e';
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _saved = false;
      _error = null;
    });
    final values = <String, String>{
      for (final e in _controllers.entries) e.key: e.value.text.trim(),
    };
    try {
      // The store validates keys against the declared fields and routes
      // each value: `secret: true` → secure storage, everything else →
      // prefs. Secret values never touch ordinary preferences.
      await _store.save(
        pluginName: widget.pluginName,
        fields: widget.fields,
        values: values,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save settings: $e';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _saved = true;
    });
    widget.onSaved?.call();
  }

  /// Accessible label with a key fallback — a rendered field is never
  /// unlabeled.
  static String _labelFor(NativePluginConfigField f) =>
      f.label.trim().isEmpty ? f.key : f.label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final field in widget.fields)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: _SettingsField(
              fieldKey: field.key,
              label: _labelFor(field),
              secret: field.secret,
              hint: field.hint,
              controller: _controllers[field.key]!,
              enabled: !_loading && !_saving,
              onChanged: (_) {
                if (_saved) setState(() => _saved = false);
              },
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: AetherCard(
              key: const ValueKey('plugin-settings-error'),
              color: Aether.danger.withValues(alpha: 0.06),
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, size: 16, color: Aether.dangerC),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _error!,
                      style: AetherType.body.copyWith(color: Aether.dangerC),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_saved && !_saving)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              key: const ValueKey('plugin-settings-saved'),
              children: [
                Icon(
                  Icons.check_circle_outline,
                  size: 16,
                  color: Aether.successLight,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text('Settings saved', style: AetherType.bodyMuted)),
              ],
            ),
          ),
        AetherPrimaryButton(
          key: const ValueKey('plugin-settings-save'),
          label: _saving ? 'Saving…' : 'Save settings',
          icon: _saving ? null : Icons.save_outlined,
          loading: _saving,
          onPressed: _loading || _saving ? null : _save,
        ),
      ],
    );
  }
}

class _SettingsField extends StatelessWidget {
  const _SettingsField({
    required this.fieldKey,
    required this.label,
    required this.secret,
    required this.hint,
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });
  final String fieldKey;
  final String label;
  final bool secret;
  final String? hint;
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final helper = hint?.isNotEmpty == true
        ? hint
        : (secret ? 'Stored in secure storage on this device.' : null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: [
            if (secret) ...[
              Icon(Icons.lock_outline, size: 14, color: Aether.textFaint),
            ],
            Text(label, style: AetherType.label),
            if (secret) ...[
              AetherPill(
                label: 'SECRET',
                color: Aether.textMuted,
                filled: false,
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          key: ValueKey('plugin-settings-field-$fieldKey'),
          controller: controller,
          onChanged: onChanged,
          enabled: enabled,
          obscureText: secret,
          enableSuggestions: !secret,
          autocorrect: !secret,
          keyboardType: secret ? TextInputType.visiblePassword : null,
          style: AetherType.body,
          decoration: InputDecoration(
            filled: true,
            fillColor: Aether.surfaceAlt,
            hintText: label,
            hintStyle: TextStyle(color: Aether.textFaint, fontSize: 14),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AetherRadius.rMd),
              borderSide: BorderSide(color: Aether.hairline),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AetherRadius.rMd),
              borderSide: BorderSide(color: Aether.accent, width: 1.2),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AetherRadius.rMd),
              borderSide: BorderSide(color: Aether.hairline),
            ),
          ),
        ),
        if (helper != null) ...[
          const SizedBox(height: 6),
          Text(helper, style: AetherType.caption),
        ],
      ],
    );
  }
}

/// One shared declarative model for both plugin kinds (audit 2026-09-25):
/// manifest-declared [PluginSettingsField]s mirror into the same
/// [NativePluginConfigField] shape native capabilities declare, so
/// [PluginSettingsPanel] and [NativePluginConfigStore] serve installed and
/// native plugins through one form/storage path. Empty labels fall back to
/// the key — every rendered field keeps an accessible label.
List<NativePluginConfigField> configFieldsForSettings(
  List<PluginSettingsField> fields,
) => [
  for (final f in fields)
    NativePluginConfigField(
      key: f.key,
      label: f.label.trim().isEmpty ? f.key : f.label,
      secret: f.secret,
      hint: f.hint,
    ),
];
