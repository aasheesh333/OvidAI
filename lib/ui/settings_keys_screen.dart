import 'package:flutter/material.dart';

import '../core/cloud/account_settings_client.dart';
import '../core/cloud/byok_client.dart';
import '../core/cloud/cloud_rest.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../l10n/l10n.dart';
import 'user_error.dart';
import 'widgets/aether_confirm.dart';
import 'widgets/aether_primitives.dart';

/// A model provider the add form knows: escrow provider id, display name,
/// official HTTPS API base URL and a sensible default model.
@immutable
class KeyProviderOption {
  const KeyProviderOption(this.id, this.name, this.endpoint, this.model);
  final String id;
  final String name;
  final String endpoint;
  final String model;

  bool get isOther => id == 'custom';
}

/// Providers offered in the add form (SE-017: a list, not free text). The
/// worker talks Anthropic's API for `anthropic` and OpenAI-compatible APIs
/// for everything else.
const keyProviderOptions = <KeyProviderOption>[
  KeyProviderOption('openai', 'OpenAI', 'https://api.openai.com/v1', 'gpt-4.1-mini'),
  KeyProviderOption('anthropic', 'Anthropic', 'https://api.anthropic.com/v1', 'claude-sonnet-4-5'),
  KeyProviderOption('openrouter', 'OpenRouter', 'https://openrouter.ai/api/v1', 'openai/gpt-4.1-mini'),
  KeyProviderOption('groq', 'Groq', 'https://api.groq.com/openai/v1', 'llama-3.3-70b-versatile'),
  KeyProviderOption('deepseek', 'DeepSeek', 'https://api.deepseek.com/v1', 'deepseek-chat'),
  KeyProviderOption('google', 'Google Gemini', 'https://generativelanguage.googleapis.com/v1beta/openai', 'gemini-2.5-flash'),
  KeyProviderOption('mistral', 'Mistral AI', 'https://api.mistral.ai/v1', 'mistral-large-latest'),
  KeyProviderOption('xai', 'xAI', 'https://api.x.ai/v1', 'grok-3-mini'),
  KeyProviderOption('together', 'Together AI', 'https://api.together.xyz/v1', ''),
  KeyProviderOption('fireworks', 'Fireworks AI', 'https://api.fireworks.ai/inference/v1', ''),
  KeyProviderOption('custom', '', '', ''),
];

KeyProviderOption? keyProviderFor(String providerId) {
  for (final o in keyProviderOptions) {
    if (o.id == providerId) return o;
  }
  return null;
}

/// Display name for an escrowed key's provider id.
String keyProviderName(String providerId) {
  final o = keyProviderFor(providerId);
  if (o != null && !o.isOther) return o.name;
  for (final e in AppState.legacyProviderCatalog.entries) {
    if (e.key == providerId) return e.value.$1;
  }
  return providerId;
}

/// Inline validation for the endpoint field (null = valid).
String? validateKeyEndpoint(AppLocalizations l, String raw) {
  final v = raw.trim();
  if (v.isEmpty) return l.keysEndpointRequired;
  final uri = Uri.tryParse(v);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    return l.keysEndpointHttps;
  }
  if (uri.userInfo.isNotEmpty || uri.hasFragment) return l.keysEndpointHttps;
  return null;
}

/// Human copy for a key API failure (SE-017: no server jargon).
String keyErrorMessage(AppLocalizations l, Object error) {
  if (error is CloudApiException) {
    switch (error.code) {
      case 'endpoint_rejected':
        return l.keysErrorEndpoint;
      case 'limit_reached':
        return l.keysErrorLimit;
      case 'unavailable':
        return l.keysErrorUnavailable;
    }
  }
  return friendlyError(error, l10n: l);
}

/// SE-004 / SE-017 — "Your API keys": the one key screen. Keys live in the
/// encrypted cloud key store (`/byok`); a key chosen for chats routes every
/// run to the user's own provider account (`PATCH /settings byokDefault`),
/// which is not metered on the Ovid allowance. Keys older builds saved on
/// this device (which never reached cloud runs) can be moved to the cloud
/// with consent, or deleted.
class KeysScreen extends StatefulWidget {
  const KeysScreen({super.key});

  @override
  State<KeysScreen> createState() => _KeysScreenState();
}

class _KeysScreenState extends State<KeysScreen> {
  List<ByokKeyDto> _keys = const [];
  AccountSettings _settings = AccountSettings.defaults;
  bool _loading = true;
  String? _error;

  /// Per-row action in flight: key id → 'test' | 'remove' | 'use'.
  final Map<String, String> _busy = {};

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
      final results = await Future.wait<Object>([
        ByokClient.I.list(),
        AccountSettingsClient.I.getSettings(),
      ]);
      if (!mounted) return;
      setState(() {
        _keys = results[0] as List<ByokKeyDto>;
        _settings = results[1] as AccountSettings;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = keyErrorMessage(context.l10n, e);
        _loading = false;
      });
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _add({LegacyDeviceKey? fromDevice}) async {
    final saved = await Navigator.of(context).push<ByokKeyDto>(
      MaterialPageRoute(builder: (_) => AddKeyScreen(fromDevice: fromDevice)),
    );
    if (saved == null || !mounted) return;
    if (fromDevice != null) {
      await AppState.I.forgetLegacyDeviceKey(fromDevice.providerId);
    }
    if (!mounted) return;
    _snack(context.l10n.keysSaved);
    await _load();
  }

  Future<void> _test(ByokKeyDto key) async {
    final l = context.l10n;
    setState(() => _busy[key.id] = 'test');
    try {
      final result = await ByokClient.I.test(key.id);
      if (!mounted) return;
      _snack(
        result.ok
            ? l.keysTestOk(keyProviderName(key.providerId))
            : l.keysTestFailed,
      );
      await _load();
    } catch (e) {
      if (mounted) _snack(keyErrorMessage(l, e));
    } finally {
      if (mounted) setState(() => _busy.remove(key.id));
    }
  }

  Future<void> _remove(ByokKeyDto key) async {
    final l = context.l10n;
    final inUse = _settings.byokDefault?.keyId == key.id;
    final ok = await showAetherConfirmDialog(
      context,
      title: l.keysRemoveTitle,
      message: inUse ? l.keysRemoveInUseBody : l.keysRemoveBody,
      confirmLabel: l.keysRemoveConfirm,
      cancelLabel: l.actionCancel,
    );
    if (!ok || !mounted) return;
    setState(() => _busy[key.id] = 'remove');
    try {
      await ByokClient.I.revoke(key.id);
      if (!mounted) return;
      _snack(l.keysRemoved);
      await _load();
    } catch (e) {
      if (mounted) _snack(keyErrorMessage(l, e));
    } finally {
      if (mounted) setState(() => _busy.remove(key.id));
    }
  }

  Future<void> _useForChats(ByokKeyDto key) async {
    final l = context.l10n;
    final current = _settings.byokDefault?.keyId == key.id
        ? _settings.byokDefault!.model
        : keyProviderFor(key.providerId)?.model ?? '';
    final model = await showDialog<String>(
      context: context,
      builder: (_) => _ModelDialog(
        providerName: keyProviderName(key.providerId),
        initial: current,
      ),
    );
    if (model == null || !mounted) return;
    setState(() => _busy[key.id] = 'use');
    try {
      final next = await AccountSettingsClient.I.setByokDefault(
        ByokDefault(keyId: key.id, model: model),
      );
      if (!mounted) return;
      setState(() => _settings = next);
      _snack(l.keysUsingNow(model));
    } catch (e) {
      if (mounted) _snack(keyErrorMessage(l, e));
    } finally {
      if (mounted) setState(() => _busy.remove(key.id));
    }
  }

  Future<void> _useOvid() async {
    final l = context.l10n;
    setState(() => _busy['default'] = 'use');
    try {
      final next = await AccountSettingsClient.I.setByokDefault(null);
      if (!mounted) return;
      setState(() => _settings = next);
      _snack(l.keysUsingOvid);
    } catch (e) {
      if (mounted) _snack(keyErrorMessage(l, e));
    } finally {
      if (mounted) setState(() => _busy.remove('default'));
    }
  }

  Future<void> _deleteDeviceKey(LegacyDeviceKey key) async {
    final l = context.l10n;
    final ok = await showAetherConfirmDialog(
      context,
      title: l.keysDeviceDeleteTitle,
      message: l.keysDeviceDeleteBody(key.name),
      confirmLabel: l.keysDeviceDeleteConfirm,
      cancelLabel: l.actionCancel,
    );
    if (!ok || !mounted) return;
    await AppState.I.forgetLegacyDeviceKey(key.providerId);
    if (mounted) _snack(l.keysDeviceDeleted);
  }

  String _statusLine(AppLocalizations l, ByokKeyDto key) {
    final at = key.lastTestAt;
    if (at == null) return l.keysNeverTested;
    final ago = _ago(l, DateTime.now().difference(at.toLocal()));
    return key.lastTestOk == true
        ? l.keysLastTestedOk(ago)
        : l.keysLastTestedFailed(ago);
  }

  static String _ago(AppLocalizations l, Duration d) {
    if (d.inMinutes < 1) return l.timeJustNow;
    if (d.inHours < 1) return l.timeMinutesAgo(d.inMinutes);
    if (d.inDays < 1) return l.timeHoursAgo(d.inHours);
    return l.timeDaysAgo(d.inDays);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final def = _settings.byokDefault;
    ByokKeyDto? defKey;
    for (final k in _keys) {
      if (k.id == def?.keyId) defKey = k;
    }
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(l.keysTitle),
      ),
      body: AnimatedBuilder(
        animation: AppState.I,
        builder: (context, _) {
          final deviceKeys = AppState.I.legacyDeviceKeys;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              Text(l.keysIntro, style: AetherType.bodyMuted),
              const SizedBox(height: 16),
              if (_error != null)
                AetherCard(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.keysLoadFailed, style: AetherType.title),
                      const SizedBox(height: 4),
                      Text(_error!, style: AetherType.bodyMuted),
                      const SizedBox(height: 8),
                      AetherSecondaryButton(
                        label: l.actionRetry,
                        onPressed: _load,
                      ),
                    ],
                  ),
                )
              else if (_loading && _keys.isEmpty)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  ),
                )
              else ...[
                AetherCard(
                  key: const ValueKey('keys-chats-route'),
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.keysChatsUseTitle, style: AetherType.title),
                      const SizedBox(height: 4),
                      Text(
                        def == null || defKey == null
                            ? l.keysChatsUseOvid
                            : l.keysChatsUseKey(
                                def.model,
                                keyProviderName(defKey.providerId),
                              ),
                        style: AetherType.bodyMuted,
                      ),
                      if (def != null) ...[
                        const SizedBox(height: 8),
                        AetherGhostButton(
                          label: l.keysUseOvidAction,
                          onPressed: _busy.containsKey('default')
                              ? null
                              : _useOvid,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (_keys.isEmpty)
                  AetherCard(
                    key: const ValueKey('byok-empty'),
                    padding: const EdgeInsets.all(18),
                    child: Text(l.keysEmpty, style: AetherType.bodyMuted),
                  )
                else
                  for (final key in _keys) ...[
                    _keyCard(l, key, inUse: key.id == def?.keyId),
                    const SizedBox(height: 10),
                  ],
                const SizedBox(height: 8),
                FilledButton.icon(
                  key: const ValueKey('keys-add'),
                  onPressed: () => _add(),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(l.keysAdd),
                ),
              ],
              if (deviceKeys.isNotEmpty) ...[
                const SizedBox(height: 28),
                Text(l.keysDeviceTitle, style: AetherType.title),
                const SizedBox(height: 4),
                Text(l.keysDeviceBody, style: AetherType.bodyMuted),
                const SizedBox(height: 10),
                for (final dk in deviceKeys) ...[
                  AetherCard(
                    key: ValueKey('device-key-${dk.providerId}'),
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(dk.name, style: AetherType.title),
                        const SizedBox(height: 2),
                        Text(
                          maskKey(dk.apiKey),
                          style: AetherType.bodyMuted,
                        ),
                        const SizedBox(height: 8),
                        OverflowBar(
                          spacing: 8,
                          overflowSpacing: 4,
                          children: [
                            AetherGhostButton(
                              label: l.keysDeviceMove,
                              icon: Icons.cloud_upload_outlined,
                              onPressed: () => _add(fromDevice: dk),
                            ),
                            AetherGhostButton(
                              label: l.keysDeviceDeleteConfirm,
                              icon: Icons.delete_outline,
                              onPressed: () => _deleteDeviceKey(dk),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _keyCard(AppLocalizations l, ByokKeyDto key, {required bool inUse}) {
    final busy = _busy[key.id];
    return AetherCard(
      key: ValueKey('byok-row-${key.id}'),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.vpn_key_outlined, size: 18, color: Aether.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  keyProviderName(key.providerId),
                  style: AetherType.title,
                ),
              ),
              if (inUse) AetherPill(label: l.keysInUse, color: Aether.success),
            ],
          ),
          const SizedBox(height: 6),
          if (key.label != null && key.label!.trim().isNotEmpty) ...[
            Text(key.label!, style: AetherType.body),
            const SizedBox(height: 2),
          ],
          Text(
            key.endpoint,
            style: AetherType.bodyMuted,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(_statusLine(l, key), style: AetherType.caption),
          const SizedBox(height: 8),
          OverflowBar(
            spacing: 8,
            overflowSpacing: 4,
            children: [
              AetherGhostButton(
                label: busy == 'test' ? l.keysTesting : l.keysTest,
                icon: Icons.bolt_outlined,
                onPressed: busy != null ? null : () => _test(key),
              ),
              AetherGhostButton(
                label: inUse ? l.keysChangeModel : l.keysUseForChats,
                icon: Icons.chat_bubble_outline,
                onPressed: busy != null ? null : () => _useForChats(key),
              ),
              AetherGhostButton(
                label: busy == 'remove' ? l.keysRemoving : l.keysRemove,
                icon: Icons.delete_outline,
                onPressed: busy != null ? null : () => _remove(key),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// `sk-…1234` — never the whole key on screen.
String maskKey(String key) {
  final k = key.trim();
  if (k.length <= 8) return '••••';
  return '${k.substring(0, 3)}••••${k.substring(k.length - 4)}';
}

class _ModelDialog extends StatefulWidget {
  const _ModelDialog({required this.providerName, required this.initial});
  final String providerName;
  final String initial;

  @override
  State<_ModelDialog> createState() => _ModelDialogState();
}

class _ModelDialogState extends State<_ModelDialog> {
  late final TextEditingController _model = TextEditingController(
    text: widget.initial,
  );
  String? _error;

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  void _save() {
    final v = _model.text.trim();
    if (v.isEmpty || v.length > 160) {
      setState(() => _error = context.l10n.keysModelRequired);
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AlertDialog(
      scrollable: true,
      title: Text(l.keysUseForChatsTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.keysUseForChatsBody(widget.providerName)),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('keys-model'),
            controller: _model,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: l.keysModelLabel,
              errorText: _error,
            ),
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(onPressed: _save, child: Text(l.keysUseForChats)),
      ],
    );
  }
}

/// Full-screen add-key form (SE-033: a dialog with four fields collapses on
/// small screens with the keyboard open). Pops the saved key on success.
class AddKeyScreen extends StatefulWidget {
  const AddKeyScreen({super.key, this.fromDevice});

  /// A retired device key being moved to the cloud (fields prefilled).
  final LegacyDeviceKey? fromDevice;

  @override
  State<AddKeyScreen> createState() => _AddKeyScreenState();
}

class _AddKeyScreenState extends State<AddKeyScreen> {
  final _form = GlobalKey<FormState>();
  late KeyProviderOption _provider;
  final _endpoint = TextEditingController();
  final _apiKey = TextEditingController();
  final _label = TextEditingController();
  final _customId = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final dk = widget.fromDevice;
    _provider = keyProviderOptions.first;
    if (dk != null) {
      _provider = _optionForDevice(dk);
      _endpoint.text = dk.baseUrl;
      _apiKey.text = dk.apiKey;
      _label.text = dk.name;
      if (_provider.isOther) _customId.text = dk.providerId;
    } else {
      _endpoint.text = _provider.endpoint;
    }
  }

  static KeyProviderOption _optionForDevice(LegacyDeviceKey dk) {
    final host = Uri.tryParse(dk.baseUrl)?.host ?? '';
    for (final o in keyProviderOptions) {
      if (o.isOther) continue;
      if (Uri.tryParse(o.endpoint)?.host == host) return o;
    }
    return keyProviderOptions.last;
  }

  @override
  void dispose() {
    _endpoint.dispose();
    _apiKey.dispose();
    _label.dispose();
    _customId.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final l = context.l10n;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final providerId = _provider.isOther
          ? (_customId.text.trim().isEmpty ? 'custom' : _customId.text.trim())
          : _provider.id;
      final saved = await ByokClient.I.upload(
        providerId: providerId,
        endpoint: _endpoint.text.trim(),
        apiKey: _apiKey.text.trim(),
        label: _label.text.trim().isEmpty ? null : _label.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) setState(() => _error = keyErrorMessage(l, e));
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
          widget.fromDevice == null ? l.keysAddTitle : l.keysDeviceMove,
        ),
      ),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              Text(
                widget.fromDevice == null
                    ? l.keysAddIntro
                    : l.keysDeviceMoveIntro,
                style: AetherType.bodyMuted,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<KeyProviderOption>(
                key: const ValueKey('byok-provider'),
                initialValue: _provider,
                isExpanded: true,
                decoration: InputDecoration(labelText: l.keysProviderLabel),
                items: [
                  for (final o in keyProviderOptions)
                    DropdownMenuItem(
                      value: o,
                      child: Text(o.isOther ? l.keysProviderOther : o.name),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (o) {
                        if (o == null) return;
                        setState(() {
                          _provider = o;
                          if (!o.isOther) _endpoint.text = o.endpoint;
                        });
                      },
              ),
              if (_provider.isOther) ...[
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('byok-provider-name'),
                  controller: _customId,
                  decoration: InputDecoration(
                    labelText: l.keysProviderNameLabel,
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? l.keysProviderNameRequired
                      : null,
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('byok-endpoint'),
                controller: _endpoint,
                keyboardType: TextInputType.url,
                autocorrect: false,
                readOnly: !_provider.isOther,
                decoration: InputDecoration(
                  labelText: l.keysEndpointLabel,
                  helperText: _provider.isOther ? l.keysEndpointHelper : null,
                ),
                validator: (v) => validateKeyEndpoint(l, v ?? ''),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('byok-api-key'),
                controller: _apiKey,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: l.keysApiKeyLabel,
                  helperText: l.keysApiKeyHelper,
                ),
                validator: (v) {
                  final k = (v ?? '').trim();
                  if (k.isEmpty) return l.keysApiKeyRequired;
                  if (RegExp(r'\s').hasMatch(k)) return l.keysApiKeyInvalid;
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('byok-label'),
                controller: _label,
                decoration: InputDecoration(labelText: l.keysNameLabel),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(color: Aether.dangerC, fontSize: 13),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                key: const ValueKey('byok-save'),
                onPressed: _saving ? null : _save,
                child: Text(_saving ? l.keysSaving : l.keysSave),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
