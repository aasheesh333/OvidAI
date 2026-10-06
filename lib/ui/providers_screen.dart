import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/model_limits.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'money_screen.dart';
import 'widgets/aether_primitives.dart';
import 'widgets/aether_v2.dart';

/// Test seam: when non-null, overrides [ProviderConfig] delete routing used by
/// the overflow Remove action. Tests inject this to assert that the UI calls
/// the right AppState mutation and to avoid secure-storage I/O in widget
/// tests. Production flows pass through [AppState.removeCustomProvider].
@visibleForTesting
Future<String?> Function(String providerId)? removeCustomProviderForTest;

/// Test seam for the `Fetch models` tile action. When non-null the UI calls
/// this instead of running the live HTTP request against the provider's
/// `/models` endpoint. Returning a non-null string surfaces as inline feedback.
@visibleForTesting
Future<String?> Function(ProviderConfig provider)? fetchProviderModelsForTest;

/// Premium Providers screen — managed Ovid Cloud + BYOK providers.
///
/// This is a visual-only redesign over an unchanged state contract:
///
/// * Managed Ovid Cloud always surfaces at the top as a calm tile: plan pill,
///   sign-in caption, and a 'Manage plan' route into [MoneyScreen]. Its
///   base URL and secret stay server-side.
/// * BYOK providers (built-in + user-added) render as [AetherCard] tiles with
///   exactly one status pill (connected / key required / not connected), the
///   model count, and the actions the user actually performs on a provider:
///   fetch models, set/clear the API key via the unified [AetherSecretField],
///   and an overflow menu for edit (base URL / API format / models) and
///   remove (custom rows only).
/// * Every mutation routes through [AppState] — [addCustomProvider],
///   [updateProviderApiKey], [updateProviderBaseUrlChecked],
///   [updateProviderApiFormat], [addProviderModel], [removeProviderModel],
///   [removeCustomProvider], [reconcileProviderModels] — so the Agent's
///   catalog view and the chat picker see identical results.
/// * API keys are written through [AppState.updateProviderApiKey] (secure
///   storage). This screen never persists keys directly.
class ProvidersScreen extends StatelessWidget {
  const ProvidersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Providers'),
      ),
      body: AnimatedBuilder(
        animation: app,
        builder: (_, _) {
          final ovidCloud = app.providerById(AppState.ovidCloudProviderId);
          final byok = app.providers
              .where((p) => p.id != AppState.ovidCloudProviderId)
              .toList();
          // Cap the reading width on tablets/desktop so tiles stay calm.
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  const AetherSectionTitle(
                    eyebrow: 'Ovid Cloud',
                    subtitle: 'Managed by Ovid — one plan, every model.',
                  ),
                  const SizedBox(height: 12),
                  if (ovidCloud != null) _OvidCloudTile(provider: ovidCloud),
                  const SizedBox(height: 24),
                  const AetherSectionTitle(
                    eyebrow: 'Your providers',
                    subtitle:
                        'Bring your own key. Keys stay on this device, in '
                        'secure storage.',
                  ),
                  const SizedBox(height: 12),
                  if (byok.isEmpty)
                    AetherEmptyState(
                      icon: Icons.key_outlined,
                      title: 'No providers yet',
                      message:
                          'Add an [OI]-compatible endpoint to use its models '
                          'in chat.',
                      action: FilledButton.icon(
                        label: const Text('Add provider'),
                        icon: const Icon(Icons.add),
                        onPressed: () => addProviderSheet(context),
                      ),
                    )
                  else ...[
                    for (final p in byok) ...[
                      _ProviderTile(key: ValueKey(p.id), provider: p),
                      const SizedBox(height: 10),
                    ],
                    const SizedBox(height: 4),
                    OutlinedButton.icon(
                      label: const Text('Add custom provider'),
                      icon: const Icon(Icons.add),
                      onPressed: () => addProviderSheet(context),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Managed Ovid Cloud tile. The plan pill reflects the current tier; the
/// trailing 'Manage plan' button opens [MoneyScreen] where the user can
/// review allowance and change plan. The base URL is intentionally not
/// shown — the gateway address is a server-side detail.
class _OvidCloudTile extends StatelessWidget {
  final ProviderConfig provider;
  const _OvidCloudTile({required this.provider});

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final paid = app.ovidCloudIsPaid;
    final signedIn = provider.hasKey;
    return AetherCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _IconChip(label: 'OC', color: Aether.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(provider.name, style: AetherType.title),
                    const SizedBox(height: 4),
                    Text(
                      signedIn
                          ? 'Signed in · ${provider.models.length} models'
                          : 'Sign in to activate',
                      style: AetherType.caption,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              AetherPill(
                label: paid ? app.ovidCloudTier.toUpperCase() : 'FREE',
                color: paid ? Aether.accent : Aether.successLight,
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              label: const Text('Manage plan'),
              icon: const Icon(Icons.open_in_new, size: 16),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const MoneyScreen()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// BYOK provider tile: one status pill + model count + actions. Key capture,
/// base-URL editing, and model management defer into bottom sheets so the
/// tile stays compact in the list.
class _ProviderTile extends StatefulWidget {
  final ProviderConfig provider;
  const _ProviderTile({super.key, required this.provider});

  @override
  State<_ProviderTile> createState() => _ProviderTileState();
}

class _ProviderTileState extends State<_ProviderTile> {
  ProviderConfig get provider => widget.provider;
  bool _fetching = false;
  String? _fetchResult;

  /// The single status pill: a saved key means connected; a free tier still
  /// needs its own key; anything else has no key on file. Labels stay short
  /// on purpose — at 2× text scale a pill has ~290px before it overflows.
  (String, Color) get _status {
    if (provider.hasKey) return ('CONNECTED', Aether.successLight);
    if (provider.isFree) return ('NEEDS KEY', Aether.accent);
    return ('NO KEY', Aether.textFaint);
  }

  Future<void> _confirmRemove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text('Remove ${provider.name}?'),
        content: const Text(
          'This provider and its saved key will be removed from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete', style: TextStyle(color: Aether.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final error = await (removeCustomProviderForTest?.call(provider.id) ??
        AppState.I.removeCustomProvider(provider.id));
    if (!context.mounted) return;
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _fetchModels(BuildContext context) async {
    if (_fetching) return;
    setState(() {
      _fetching = true;
      _fetchResult = null;
    });
    try {
      final override = fetchProviderModelsForTest;
      if (override != null) {
        final err = await override(provider);
        if (!mounted) return;
        AppState.I.reconcileProviderModels(provider.id);
        _fetchResult = err ?? (provider.models.isEmpty
            ? 'No models returned. You can add a model manually in Edit.'
            : '${provider.models.length} models fetched ✓');
        return;
      }
      var url = provider.baseUrl;
      if (!url.endsWith('/')) url += '/';
      final uri = Uri.parse('${url}models');
      final cleanKey = provider.cleanApiKey;
      final res = await http
          .get(
            uri,
            headers: {
              if (cleanKey.isNotEmpty) 'Authorization': 'Bearer $cleanKey',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body);
        final List fetched = j['data'] ?? j['models'] ?? [];
        final ids = [
          for (final m in fetched)
            (m is Map ? (m['id'] ?? m['name'] ?? '') : '$m').toString(),
        ].where((s) => s.isNotEmpty).toList();
        if (ids.isNotEmpty) {
          final existing = provider.models.toSet();
          for (final id in ids) {
            if (!existing.contains(id)) {
              provider.models.add(id);
              existing.add(id);
            }
          }
        }
        AppState.I.reconcileProviderModels(provider.id);
        _fetchResult = ids.isEmpty
            ? 'No models returned. You can add a model manually in Edit.'
            : '${ids.length} models fetched ✓';
      } else {
        _fetchResult = 'Failed: HTTP ${res.statusCode} — check key/URL';
      }
    } catch (e) {
      String msg;
      if (e is FormatException &&
          e.message.contains('Invalid HTTP header field value')) {
        msg =
            'API key looks invalid (contains whitespace or extra text). '
            'Please re-enter your key.';
      } else {
        msg = 'Fetch failed: $e';
      }
      _fetchResult = msg;
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final letter = provider.name.isEmpty
        ? '?'
        : provider.name.substring(0, 1).toUpperCase();
    final (statusLabel, statusColor) = _status;
    return AetherCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _IconChip(label: letter, color: Aether.textMuted),
              const SizedBox(width: 12),
              Expanded(
                child: Text(provider.name, style: AetherType.title),
              ),
              PopupMenuButton<String>(
                tooltip: 'More actions',
                icon: Icon(Icons.more_horiz, color: Aether.textMuted),
                itemBuilder: (_) => [
                  PopupMenuItem<String>(
                    value: 'edit',
                    child: Text('Edit', style: AetherType.body),
                  ),
                  if (provider.custom)
                    PopupMenuItem<String>(
                      value: 'remove',
                      child: Text(
                        'Remove',
                        style: AetherType.body.copyWith(color: Aether.danger),
                      ),
                    ),
                ],
                onSelected: (choice) {
                  switch (choice) {
                    case 'edit':
                      _showEditSheet(context);
                    case 'remove':
                      unawaited(_confirmRemove(context));
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Status + count get the full card width; the header slot beside
          // the overflow menu is too narrow for a pill at 2× text scale.
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                AetherPill(label: statusLabel, color: statusColor),
                Text(
                  '${provider.models.length} models',
                  style: AetherType.caption,
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  label: Text(_fetching ? 'Fetching models…' : 'Fetch models'),
                  icon: _fetching
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync, size: 16),
                  onPressed: _fetching ? null : () => _fetchModels(context),
                ),
                TextButton.icon(
                  label: const Text('API key'),
                  icon: Icon(
                    provider.hasKey ? Icons.key : Icons.key_outlined,
                    size: 16,
                  ),
                  onPressed: () => _showApiKeySheet(context),
                ),
              ],
            ),
          ),
          if (_fetchResult != null)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: Text(_fetchResult!, style: AetherType.bodyMuted),
              ),
            ),
          if (provider.models.isNotEmpty) ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final m in provider.models.take(6))
                    _ModelChip(provider: provider, model: m),
                  if (provider.models.length > 6)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Aether.surfaceAlt,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: Aether.hairline),
                      ),
                      child: Text(
                        '+${provider.models.length - 6} more',
                        style: AetherType.caption,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showApiKeySheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: _ApiKeySheet(provider: provider),
      ),
    );
  }

  void _showEditSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: _EditProviderSheet(provider: provider),
      ),
    );
  }
}

/// API-key capture sheet. Pastes/sanitises/stores the key via
/// [AppState.updateProviderApiKey]. The 'Clear' action deletes the stored
/// value from secure storage via [AppState.clearProviderApiKey].
class _ApiKeySheet extends StatefulWidget {
  final ProviderConfig provider;
  const _ApiKeySheet({required this.provider});

  @override
  State<_ApiKeySheet> createState() => _ApiKeySheetState();
}

class _ApiKeySheetState extends State<_ApiKeySheet> {
  late final TextEditingController _controller;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.provider.apiKey);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    // Strip whitespace/control chars so pasted blobs never hit HTTP headers.
    final sanitized =
        _controller.text.replaceAll(RegExp(r'[\s\x00-\x1f\x7f]'), '');
    try {
      await AppState.I.updateProviderApiKey(widget.provider, sanitized);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'The API key could not be stored securely.';
      });
      return;
    }
    if (!mounted) return;
    navigator.pop();
  }

  Future<void> _clear() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    final err = await AppState.I.clearProviderApiKey(widget.provider);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _saving = false;
        _error = err;
      });
      return;
    }
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return _ProviderSheet(
      title: '${widget.provider.name} API key',
      actions: [
        if (widget.provider.hasKey)
          TextButton(
            onPressed: _saving ? null : _clear,
            child: const Text(
              'Clear',
              style: TextStyle(color: Aether.danger),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.provider.isFree
                ? 'Free tier keys are rate-limited by the upstream provider. '
                      'Stored only on this device.'
                : 'Stored only on this device, in secure storage.',
            style: AetherType.bodyMuted,
          ),
          const SizedBox(height: 16),
          AetherSecretField(
            label: 'API key',
            hint: 'sk-…',
            controller: _controller,
            saved: widget.provider.hasKey,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(_error!, style: AetherType.body.copyWith(color: Aether.dangerC)),
            ),
          ],
        ],
      ),
    );
  }
}

/// Edit sheet — base URL, API format ([OI]/Anthropic), model list. All
/// mutations route through [AppState] so the agent catalog is in sync.
class _EditProviderSheet extends StatefulWidget {
  final ProviderConfig provider;
  const _EditProviderSheet({required this.provider});

  @override
  State<_EditProviderSheet> createState() => _EditProviderSheetState();
}

class _EditProviderSheetState extends State<_EditProviderSheet> {
  late final TextEditingController _urlController;
  String? _urlResult;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.provider.baseUrl);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _saveUrl() async {
    final err = await AppState.I.updateProviderBaseUrlChecked(
      widget.provider,
      _urlController.text,
    );
    if (!mounted) return;
    setState(() => _urlResult = err ?? 'Base URL saved.');
  }

  Future<void> _addModel() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('Add model id'),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontFamily: Aether.mono, fontSize: 13.5),
          decoration: const InputDecoration(hintText: 'e.g. gpt-5.2-codex'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Add', style: TextStyle(color: Aether.accent)),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.trim().isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final err = await AppState.I.addProviderModel(widget.provider, value);
    if (!mounted) return;
    if (err != null) messenger.showSnackBar(SnackBar(content: Text(err)));
  }

  @override
  Widget build(BuildContext context) {
    final provider = widget.provider;
    return AnimatedBuilder(
      animation: AppState.I,
      builder: (_, _) {
        return _ProviderSheet(
          title: 'Edit ${provider.name}',
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ],
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AetherField(
                  label: 'Base URL',
                  hint: 'https://…/v1',
                  controller: _urlController,
                  onSubmitted: (_) => _saveUrl(),
                  suffix: IconButton(
                    tooltip: 'Save base URL',
                    icon: const Icon(Icons.save_outlined, size: 18),
                    color: Aether.textMuted,
                    onPressed: _saveUrl,
                  ),
                ),
                if (_urlResult != null) ...[
                  const SizedBox(height: 8),
                  Semantics(
                    liveRegion: true,
                    child: Text(_urlResult!, style: AetherType.bodyMuted),
                  ),
                ],
                const SizedBox(height: 16),
                Text('API format', style: AetherType.label),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final option in const [
                      (value: ApiFormat.openai, label: '[OI]-compatible'),
                      (value: ApiFormat.anthropic, label: 'Anthropic'),
                    ])
                      ChoiceChip(
                        label: Text(option.label),
                        selected: provider.effectiveApiFormat == option.value,
                        onSelected: (_) async {
                          final messenger = ScaffoldMessenger.of(context);
                          final err = await AppState.I.updateProviderApiFormat(
                            provider,
                            option.value,
                          );
                          if (!mounted) return;
                          if (err != null) {
                            messenger.showSnackBar(SnackBar(content: Text(err)));
                          }
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('Models', style: AetherType.label),
                    TextButton.icon(
                      label: const Text('Add model'),
                      icon: const Icon(Icons.add, size: 16),
                      onPressed: _addModel,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (provider.models.isEmpty)
                  Text(
                    'No models yet — fetch from the provider or add one '
                    'manually.',
                    style: AetherType.caption,
                  )
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final m in provider.models)
                        _ModelChip(
                          provider: provider,
                          model: m,
                          removable: true,
                        ),
                    ],
                  ),
              ],
          ),
        );
      },
    );
  }
}

/// Square tinted monogram used as the tile leading glyph. Keeps the layout
/// honest when a provider has no logo asset to draw.
class _IconChip extends StatelessWidget {
  final String label;
  final Color color;
  const _IconChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      padding: const EdgeInsets.all(8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// The entire sheet scrolls, including long provider names and its actions.
/// A keyboard can leave too little height for a fixed title/action frame.
class _ProviderSheet extends StatelessWidget {
  const _ProviderSheet({
    required this.title,
    required this.child,
    required this.actions,
  });

  final String title;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Aether.surface,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(AetherRadius.rXl),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: AetherType.h2),
              const SizedBox(height: 16),
              child,
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: actions,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact monospace model badge. Shows the provider-published context
/// window label if known and (when [removable]) a tap-to-remove `×`.
class _ModelChip extends StatelessWidget {
  final ProviderConfig provider;
  final String model;
  final bool removable;
  const _ModelChip({
    required this.provider,
    required this.model,
    this.removable = false,
  });

  @override
  Widget build(BuildContext context) {
    final limits = ModelLimits.compactLabel(model, provider.id);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
      decoration: BoxDecoration(
        color: Aether.surfaceAlt,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Aether.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  model,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: Aether.mono,
                    color: Aether.textMuted,
                  ),
                ),
                if (limits != null)
                  Text(limits, style: AetherType.caption),
              ],
            ),
          ),
          if (removable) ...[
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Remove model $model',
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final error = await AppState.I.removeProviderModel(
                  provider,
                  model,
                );
                if (!context.mounted || error == null) return;
                messenger.showSnackBar(SnackBar(content: Text(error)));
              },
              icon: Icon(Icons.close, size: 18, color: Aether.textMuted),
            ),
          ] else
            const SizedBox(width: 4),
        ],
      ),
    );
  }
}

/// Add-provider bottom sheet. Routes through [AppState.addCustomProvider]
/// which validates the URL, dedupes by slug, and persists the key through
/// secure storage before the row surfaces in the list.
void addProviderSheet(BuildContext context) {
  final name = TextEditingController();
  final url = TextEditingController();
  final key = TextEditingController();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: _ProviderSheet(
        title: 'Add custom provider',
        actions: [
          TextButton(
            onPressed: () => Navigator.of(sheetContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(sheetContext);
              final navigator = Navigator.of(sheetContext);
              final error = await AppState.I.addCustomProvider(
                name: name.text,
                baseUrl: url.text,
                apiKey: key.text,
              );
              if (!sheetContext.mounted) return;
              if (error != null) {
                messenger.showSnackBar(SnackBar(content: Text(error)));
                return;
              }
              navigator.pop();
            },
            child: const Text('Add', style: TextStyle(color: Aether.accent)),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Any [OI]-compatible endpoint works.',
              style: AetherType.bodyMuted,
            ),
            const SizedBox(height: 16),
            AetherField(
              label: 'Name',
              hint: 'e.g. Together AI',
              controller: name,
            ),
            const SizedBox(height: 12),
            AetherField(
              label: 'Base URL',
              hint: 'https://…/v1',
              controller: url,
            ),
            const SizedBox(height: 12),
            AetherSecretField(
              label: 'API key (optional)',
              hint: 'sk-…',
              controller: key,
            ),
          ],
        ),
      ),
    ),
  ).whenComplete(() {
    name.dispose();
    url.dispose();
    key.dispose();
  });
}
