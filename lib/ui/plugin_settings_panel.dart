import 'package:flutter/material.dart';

import '../core/native_plugin.dart';
import '../core/plugin_manifest.dart';
import '../core/theme.dart';

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
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              key: ValueKey('plugin-settings-field-${field.key}'),
              controller: _controllers[field.key],
              enabled: !_loading && !_saving,
              obscureText: field.secret,
              enableSuggestions: !field.secret,
              autocorrect: !field.secret,
              keyboardType: field.secret
                  ? TextInputType.visiblePassword
                  : null,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                labelText: _labelFor(field),
                helperText: field.hint?.isNotEmpty == true
                    ? field.hint
                    : (field.secret
                          ? 'Stored in secure storage on this device.'
                          : null),
                helperMaxLines: 3,
                prefixIcon: field.secret
                    ? Icon(
                        Icons.lock_outline,
                        size: 16,
                        color: Aether.textFaint,
                      )
                    : null,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _error!,
              key: const ValueKey('plugin-settings-error'),
              style: TextStyle(fontSize: 12, color: Aether.danger),
            ),
          ),
        if (_saved && !_saving)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              key: const ValueKey('plugin-settings-saved'),
              children: [
                Icon(
                  Icons.check_circle_outline,
                  size: 14,
                  color: Aether.successLight,
                ),
                const SizedBox(width: 8),
                Text(
                  'Settings saved',
                  style: TextStyle(fontSize: 12, color: Aether.textMuted),
                ),
              ],
            ),
          ),
        FilledButton.icon(
          key: const ValueKey('plugin-settings-save'),
          style: FilledButton.styleFrom(
            backgroundColor: Aether.accent,
            // 44dp tap-target invariant.
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: _loading || _saving ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                )
              : const Icon(Icons.save_outlined, size: 16),
          label: Text(
            _saving ? 'Saving…' : 'Save settings',
            style: const TextStyle(fontSize: 13.5),
          ),
        ),
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
