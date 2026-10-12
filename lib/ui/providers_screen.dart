import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/prompt_cache.dart';
import 'package:http/http.dart' as http;

import '../core/diag.dart';
import '../core/firebase_service.dart';
import '../core/model_limits.dart';
import '../core/ovid_cloud_service.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../l10n/l10n.dart';
import 'billing_screen.dart';
import 'user_error.dart';
import 'widgets/aether_primitives.dart';

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

/// Test seam: HTTP client for the live `/models` request. Lets tests exercise
/// response parsing and error copy without the network.
@visibleForTesting
http.Client? providerModelsHttpClientForTest;

/// Provider-specific copy for a non-200 `/models` response.
String providerFetchStatusMessage(AppLocalizations l, int status) =>
    switch (UserError.kindForStatus(status)) {
      UserErrorKind.unauthorized ||
      UserErrorKind.forbidden => l.providerFetchKeyRejected,
      UserErrorKind.notFound => l.providerFetchNoModelsEndpoint,
      UserErrorKind.rateLimited => l.providerFetchRateLimited,
      UserErrorKind.server => l.providerFetchServerError,
      UserErrorKind.timeout => l.providerFetchUnreachable,
      _ => l.providerFetchFailed,
    };

/// Provider-specific copy for a `/models` request that threw.
String providerFetchErrorMessage(AppLocalizations l, Object error) {
  if (error is FormatException &&
      error.message.contains('Invalid HTTP header field value')) {
    return l.providerFetchInvalidKey;
  }
  return switch (UserError.kindOf(error)) {
    UserErrorKind.offline ||
    UserErrorKind.timeout => l.providerFetchUnreachable,
    UserErrorKind.badResponse => l.providerFetchUnexpectedResponse,
    _ => friendlyError(error, l10n: l),
  };
}

enum _FetchState { idle, busy, success, error, empty }

/// Outcome of a `GET {baseUrl}/models` probe against a BYOK provider.
@visibleForTesting
class ProviderModelsProbe {
  /// Model ids returned (empty on failure or an empty listing).
  final List<String> ids;

  /// Human-readable failure, or null on HTTP 200.
  final String? error;

  /// The non-200 HTTP status, when that was the failure.
  final int? status;

  /// The exception behind the failure, when one was thrown. Lets the Fetch
  /// models UI map it to localized copy ([providerFetchErrorMessage]).
  final Object? cause;

  const ProviderModelsProbe.ok(this.ids)
    : error = null,
      status = null,
      cause = null;
  const ProviderModelsProbe.failed(this.error, {this.status, this.cause})
    : ids = const [];

  bool get ok => error == null;
}

/// Map a `/models` HTTP status to something the user can act on.
@visibleForTesting
String describeProviderProbeStatus(int status) {
  if (status == 401 || status == 403) {
    return 'Key rejected by the provider (HTTP $status). Check that you '
        'pasted the whole key and that it is still active.';
  }
  if (status == 404) {
    return 'No /models endpoint found (HTTP 404). Check the base URL in Edit.';
  }
  if (status == 429) {
    return 'The provider is rate limiting requests (HTTP 429). Try again '
        'in a minute.';
  }
  if (status >= 500) {
    return 'The provider had a server error (HTTP $status). Try again later.';
  }
  return 'The provider answered HTTP $status. Check the key and base URL.';
}

/// Lightweight `/models` probe shared by "Fetch models" and key verification.
/// Never throws; failures come back as [ProviderModelsProbe.failed].
@visibleForTesting
Future<ProviderModelsProbe> probeProviderModels(
  ProviderConfig provider, {
  http.Client? client,
}) async {
  final injected = client ?? providerModelsHttpClientForTest;
  final c = injected ?? http.Client();
  try {
    var url = provider.baseUrl.trim();
    if (!url.endsWith('/')) url += '/';
    final uri = Uri.tryParse('${url}models');
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      return const ProviderModelsProbe.failed(
        'The base URL is not a valid address. Fix it in Edit.',
      );
    }
    final cleanKey = provider.cleanApiKey;
    final isAnthropic = provider.effectiveApiFormat == ApiFormat.anthropic;
    final res = await c
        .get(
          uri,
          headers: {
            if (isAnthropic && cleanKey.isNotEmpty) 'x-api-key': cleanKey,
            if (isAnthropic) 'anthropic-version': '2023-06-01',
            if (!isAnthropic && cleanKey.isNotEmpty)
              'Authorization': 'Bearer $cleanKey',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      return ProviderModelsProbe.failed(
        describeProviderProbeStatus(res.statusCode),
        status: res.statusCode,
      );
    }
    final j = jsonDecode(res.body);
    final fetched = j is Map ? (j['data'] ?? j['models']) : j;
    if (fetched is! List) {
      // Neither {data|models: [...]} nor a bare array (Together AI style).
      throw const FormatException('models response has no list');
    }
    final ids = <String>[
      for (final m in fetched)
        (m is Map ? (m['id'] ?? m['name'] ?? '') : '$m').toString(),
    ].where((s) => s.isNotEmpty).toList();
    return ProviderModelsProbe.ok(ids);
  } on TimeoutException catch (e) {
    return ProviderModelsProbe.failed(
      'The provider did not answer within 15 seconds. Check your connection '
      'and the base URL.',
      cause: e,
    );
  } on FormatException catch (e) {
    if (e.message.contains('Invalid HTTP header field value')) {
      return ProviderModelsProbe.failed(
        'API key looks invalid (contains whitespace or extra text). '
        'Please re-enter your key.',
        cause: e,
      );
    }
    return ProviderModelsProbe.failed(
      'The provider returned a response that is not a model list. Check the '
      'base URL.',
      cause: e,
    );
  } catch (e) {
    final text = e.toString();
    if (e is http.ClientException ||
        text.contains('SocketException') ||
        text.contains('HandshakeException')) {
      return ProviderModelsProbe.failed(
        "Can't reach the provider. Check your connection and the base URL.",
        cause: e,
      );
    }
    // The raw error stays in [cause] (logged by callers), never in copy.
    return ProviderModelsProbe.failed(
      'Could not check the provider. Check the key and base URL.',
      cause: e,
    );
  } finally {
    if (injected == null) c.close();
  }
}

/// Premium Providers screen — managed Ovid Cloud + BYOK providers.
///
/// * Managed Ovid Cloud always surfaces at the top with a 'Manage plan' route
///   into [BillingScreen]. Its base URL and secret stay server-side.
/// * BYOK providers (built-in + user-added) render as [AetherCard] tiles.
///   Each tile exposes the four operations the user actually performs on a
///   provider: fetch models, set/clear the API key, edit (base URL / API
///   format / enable or disable models), and remove (for custom rows only).
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
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              const AetherSectionTitle(
                eyebrow: 'Ovid Cloud',
                subtitle:
                    'Managed by Ovid Si — one plan, every model. No key to copy.',
              ),
              const SizedBox(height: 12),
              if (ovidCloud != null) _OvidCloudTile(provider: ovidCloud),
              const SizedBox(height: 24),
              const AetherSectionTitle(
                eyebrow: 'Your providers',
                subtitle:
                    'Bring your own key. Keys are stored securely on this '
                    'device and sent to your provider to authenticate requests. '
                    'Free tiers still need their own key.',
              ),
              const SizedBox(height: 12),
              if (byok.isEmpty)
                AetherEmptyState(
                  icon: Icons.cloud_queue_outlined,
                  title: 'No providers yet',
                  message:
                      'Add an OpenAI-compatible endpoint — Together, Groq, '
                      'OpenRouter, or your own gateway — to use its models in '
                      'chat.',
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
          );
        },
      ),
    );
  }
}

/// One-line result of a successful Fetch models run.
@visibleForTesting
String fetchResultSummary({
  required int fetched,
  required int added,
  required int removed,
}) {
  final parts = <String>[
    '$fetched models fetched',
    if (added > 0) '$added new',
    if (removed > 0) '$removed no longer offered removed',
  ];
  return '${parts.join(' · ')} ✓';
}

/// Managed Ovid Cloud tile. Shows the live connection state (connecting,
/// failed with its reason, ready) with Retry / Refresh actions, plus the plan
/// tier and a 'Manage plan' route into [BillingScreen]. The base URL is
/// intentionally not shown — the gateway address is a server-side detail.
class _OvidCloudTile extends StatelessWidget {
  final ProviderConfig provider;
  const _OvidCloudTile({required this.provider});

  @override
  Widget build(BuildContext context) {
    final cloud = OvidCloudService.I;
    return AnimatedBuilder(
      animation: cloud,
      builder: (context, _) => _buildTile(context, cloud),
    );
  }

  Widget _buildTile(BuildContext context, OvidCloudService cloud) {
    final app = AppState.I;
    final tier = app.ovidCloudTier;
    final paid = app.ovidCloudIsPaid;
    final connection = cloud.connectionFor(app);
    final statusLabel = paid ? tier.toUpperCase() : 'FREE';
    final statusColor = paid ? Aether.accent : Aether.success;
    final modelCount = <String>{'auto', ...provider.models}.length;
    final l = context.l10n;
    final modelsLabel = l.cloudModelCount(modelCount);
    final String connectionLabel = switch (connection.status) {
      CloudConnectionStatus.idle =>
        provider.hasKey
            ? l.cloudStatusNotConnected
            : l.cloudStatusSignInToActivate,
      CloudConnectionStatus.connecting => l.cloudStatusConnecting,
      CloudConnectionStatus.loadingCatalog => l.cloudStatusLoadingCatalog,
      CloudConnectionStatus.ready => l.cloudStatusReady(modelsLabel),
      CloudConnectionStatus.failed =>
        (connection.error == null || connection.error!.trim().isEmpty)
            ? l.cloudStatusFailed
            : connection.error!,
    };
    final failed = connection.status == CloudConnectionStatus.failed;
    final ready = connection.status == CloudConnectionStatus.ready;
    return AetherCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _IconChip(label: 'OC', color: Aether.accent),
              const SizedBox(width: 12),
              Expanded(child: Text(provider.name, style: AetherType.title)),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AetherPill(label: statusLabel, color: statusColor),
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
            ],
          ),
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              connectionLabel,
              key: const ValueKey('ovid-cloud-connection-status'),
              style: failed
                  ? AetherType.caption.copyWith(color: Aether.dangerC)
                  : AetherType.caption,
            ),
          ),
          if (failed)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                l.cloudCatalogStale(modelsLabel),
                style: AetherType.caption,
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              if (ready)
                TextButton.icon(
                  key: const ValueKey('ovid-cloud-refresh-models'),
                  label: Text(l.cloudRefreshModels),
                  icon: const Icon(Icons.refresh, size: 16),
                  onPressed: () =>
                      unawaited(cloud.ensureConnected(app: app, force: true)),
                )
              else
                TextButton.icon(
                  key: const ValueKey('ovid-cloud-retry-connection'),
                  label: Text(
                    connection.loading
                        ? l.cloudConnectingButton
                        : l.cloudRetryConnection,
                  ),
                  icon: const Icon(Icons.refresh, size: 16),
                  onPressed: connection.loading
                      ? null
                      : () => unawaited(cloud.ensureConnected(app: app)),
                ),
              if (connection.mintStatus == MintStatus.sessionExpired)
                TextButton.icon(
                  key: const ValueKey('ovid-cloud-sign-out'),
                  label: Text(l.cloudSignOut),
                  icon: const Icon(Icons.logout, size: 16),
                  onPressed: () => unawaited(FirebaseService.I.signOut()),
                ),
              TextButton.icon(
                label: const Text('Manage plan'),
                icon: const Icon(Icons.open_in_new, size: 16),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const BillingScreen(),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// BYOK provider tile. Exposes provider actions and defers key
/// capture / base-URL editing / model management into bottom sheets so the
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
  bool _expanded = false;
  _FetchState _fetchState = _FetchState.idle;
  String? _fetchResult;

  Color get _statusColor {
    if (!provider.requiresApiKey) return Aether.success;
    if (provider.hasKey && provider.verifiedAt != null) {
      return Aether.success;
    }
    if (provider.hasKey) return Aether.accent;
    if (provider.isFree) return Aether.accent;
    return Aether.textFaint;
  }

  String get _statusLabel {
    if (!provider.requiresApiKey) return 'Connected · no key required';
    if (provider.hasKey && provider.verifiedAt != null) return 'Key verified';
    if (provider.hasKey) return 'Key saved · not verified';
    if (provider.isFree) return 'Free tier — key required';
    return 'Not connected · key required';
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
            child: Text('Delete', style: TextStyle(color: Aether.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final error =
        await (removeCustomProviderForTest?.call(provider.id) ??
            AppState.I.removeCustomProvider(provider.id));
    if (!context.mounted) return;
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _fetchModels(BuildContext context) async {
    if (_fetching) return;
    final l = context.l10n;
    setState(() {
      _fetching = true;
      _fetchState = _FetchState.busy;
      _fetchResult = 'Fetching models…';
    });
    try {
      final override = fetchProviderModelsForTest;
      if (override != null) {
        final err = await override(provider);
        if (!mounted) return;
        AppState.I.reconcileProviderModels(provider.id);
        if (err != null) {
          _fetchState = _FetchState.error;
          _fetchResult = err;
        } else if (provider.models.isEmpty) {
          _fetchState = _FetchState.empty;
          _fetchResult =
              'No models returned. You can add a model manually in Edit.';
        } else {
          _fetchState = _FetchState.success;
          _fetchResult = '${provider.models.length} models fetched ✓';
        }
        return;
      }
      final probe = await probeProviderModels(provider);
      if (!mounted) return;
      if (!probe.ok) {
        _fetchState = _FetchState.error;
        final status = probe.status;
        final cause = probe.cause;
        _fetchResult = status != null
            ? providerFetchStatusMessage(l, status)
            : cause != null
            ? providerFetchErrorMessage(l, cause)
            : probe.error;
      } else if (probe.ids.isEmpty) {
        _fetchState = _FetchState.empty;
        _fetchResult =
            'No models returned. Existing models were kept; you can add one manually in Edit.';
      } else {
        final before = provider.models.toSet();
        final removed = await AppState.I.replaceProviderModels(
          provider,
          probe.ids,
        );
        if (!mounted) return;
        final added = provider.models.where((m) => !before.contains(m)).length;
        _fetchState = _FetchState.success;
        _fetchResult = fetchResultSummary(
          fetched: probe.ids.length,
          added: added,
          removed: removed.length,
        );
      }
    } catch (e, st) {
      Diag.swallow('providers_screen.fetch_models', e, st);
      _fetchState = _FetchState.error;
      _fetchResult = providerFetchErrorMessage(l, e);
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final letter = provider.name.isEmpty
        ? '?'
        : provider.name.substring(0, 1).toUpperCase();
    return AetherCard(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  expanded: _expanded,
                  child: InkWell(
                    onTap: () => setState(() => _expanded = !_expanded),
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Row(
                        children: [
                          _IconChip(label: letter, color: Aether.textMuted),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(provider.name, style: AetherType.title),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 2,
                                  children: [
                                    Text(
                                      _statusLabel,
                                      style: AetherType.caption.copyWith(
                                        color: _statusColor,
                                      ),
                                    ),
                                    Text(
                                      '${provider.models.length} models',
                                      style: AetherType.caption,
                                    ),
                                    if (provider.isFree)
                                      Text(
                                        'FREE',
                                        style: AetherType.caption.copyWith(
                                          color: Aether.success,
                                        ),
                                      )
                                    else if (!provider.custom)
                                      Text(
                                        'BUILT-IN',
                                        style: AetherType.caption,
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            _expanded ? Icons.expand_less : Icons.expand_more,
                            color: Aether.textMuted,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
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
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
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
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
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
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _fetchState == _FetchState.busy
                          ? Icons.sync
                          : _fetchState == _FetchState.success
                          ? Icons.check_circle_outline
                          : _fetchState == _FetchState.empty
                          ? Icons.info_outline
                          : Icons.error_outline,
                      size: 17,
                      color: _fetchState == _FetchState.busy
                          ? Aether.accent
                          : _fetchState == _FetchState.success
                          ? Aether.success
                          : _fetchState == _FetchState.empty
                          ? Aether.textMuted
                          : Aether.danger,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(_fetchResult!, style: AetherType.bodyMuted),
                    ),
                  ],
                ),
              ),
            ),
          if (_expanded) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 6),
              child: _CachedProviderModels(provider: provider),
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
  String? _status;

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
      _status = null;
    });
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final provider = widget.provider;
    // Strip whitespace/control chars so pasted blobs never hit HTTP headers.
    final sanitized = _controller.text.replaceAll(
      RegExp(r'[\s\x00-\x1f\x7f]'),
      '',
    );
    final keyChanged = sanitized != provider.cleanApiKey;
    try {
      await AppState.I.updateProviderApiKey(provider, sanitized);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'The API key could not be stored securely.';
      });
      return;
    }
    if (keyChanged) provider.verifiedAt = null;
    if (sanitized.isEmpty) {
      if (!mounted) return;
      navigator.pop();
      return;
    }
    // Verify the key with a lightweight /models probe before closing so a
    // typo surfaces here, not as a failed chat turn later.
    if (!mounted) return;
    setState(() => _status = 'Checking key…');
    final probe = await probeProviderModels(provider);
    if (!mounted) return;
    if (!probe.ok) {
      setState(() {
        _saving = false;
        _status = null;
        _error = 'Key saved, but it could not be verified. ${probe.error}';
      });
      AppState.I.refresh();
      unawaited(AppState.I.persistProviderState());
      return;
    }
    if (probe.ids.isNotEmpty) {
      await AppState.I.replaceProviderModels(provider, probe.ids);
    }
    await AppState.I.markProviderVerified(provider);
    if (!mounted) return;
    final n = probe.ids.length;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          n > 0
              ? 'Key verified ✓ · $n ${n == 1 ? 'model' : 'models'}'
              : 'Key verified ✓',
        ),
      ),
    );
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
            child: Text('Clear', style: TextStyle(color: Aether.danger)),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: Text(
            _saving ? (_status != null ? 'Checking…' : 'Saving…') : 'Save',
          ),
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
          AetherField(
            label: 'API key',
            hint: 'sk-…',
            obscure: true,
            controller: _controller,
            autofocus: true,
          ),
          if (_status != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Row(
                children: [
                  const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_status!, style: AetherType.bodyMuted),
                  ),
                ],
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: AetherType.body.copyWith(color: Aether.danger),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Edit sheet — base URL, API format (OpenAI/Anthropic), model list. All
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
            child: Text('Add', style: TextStyle(color: Aether.accent)),
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
                    (value: ApiFormat.openai, label: 'OpenAI-compatible'),
                    (value: ApiFormat.anthropic, label: 'Anthropic'),
                  ])
                    ChoiceChip(
                      label: Text(option.label),
                      selected: provider.effectiveApiFormat == option.value,
                      materialTapTargetSize: MaterialTapTargetSize.padded,
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
              const SizedBox(height: 16),
              Text(context.l10n.promptCachingTitle, style: AetherType.label),
              const SizedBox(height: 2),
              Text(
                context.l10n.promptCacheProviderHelp,
                style: AetherType.caption,
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in PromptCacheOverride.values)
                    ChoiceChip(
                      label: Text(
                        option.name[0].toUpperCase() + option.name.substring(1),
                      ),
                      selected: provider.promptCache == option,
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      onSelected: (_) => AppState.I.updateProviderPromptCache(
                        provider,
                        option,
                      ),
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
                _CachedProviderModels(provider: provider, removable: true),
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

/// Cached models are built only as requested; expanding never fetches remotely.
class _CachedProviderModels extends StatefulWidget {
  const _CachedProviderModels({required this.provider, this.removable = false});

  final ProviderConfig provider;
  final bool removable;

  @override
  State<_CachedProviderModels> createState() => _CachedProviderModelsState();
}

class _CachedProviderModelsState extends State<_CachedProviderModels> {
  static const _pageSize = 10;
  int _visibleCount = _pageSize;

  @override
  Widget build(BuildContext context) {
    final models = widget.provider.models;
    if (models.isEmpty) {
      return Text(
        'No cached models yet — use Fetch models or add one in Edit.',
        style: AetherType.caption,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final model in models.take(_visibleCount))
              _ModelChip(
                provider: widget.provider,
                model: model,
                removable: widget.removable,
              ),
          ],
        ),
        if (models.length > _visibleCount)
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => setState(() => _visibleCount += _pageSize),
            child: const Text('More'),
          ),
      ],
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
                if (limits != null) Text(limits, style: AetherType.caption),
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
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _AddProviderSheet(),
  );
}

class _AddProviderSheet extends StatefulWidget {
  const _AddProviderSheet();

  @override
  State<_AddProviderSheet> createState() => _AddProviderSheetState();
}

class _AddProviderSheetState extends State<_AddProviderSheet> {
  final name = TextEditingController();
  final url = TextEditingController();
  final key = TextEditingController();
  var apiFormat = ApiFormat.openai;

  @override
  void dispose() {
    name.dispose();
    url.dispose();
    key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext sheetContext) {
    return Padding(
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
                apiFormat: apiFormat,
              );
              if (!sheetContext.mounted) return;
              if (error != null) {
                messenger.showSnackBar(SnackBar(content: Text(error)));
                return;
              }
              navigator.pop();
            },
            child: Text('Add', style: TextStyle(color: Aether.accent)),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Connect an OpenAI-compatible or Anthropic endpoint.',
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
            AetherField(
              label: 'API key (optional)',
              hint: 'sk-…',
              controller: key,
              obscure: true,
            ),
            const SizedBox(height: 16),
            Text('API format', style: AetherType.label),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in const [
                  (value: ApiFormat.openai, label: 'OpenAI-compatible'),
                  (value: ApiFormat.anthropic, label: 'Anthropic'),
                ])
                  ChoiceChip(
                    label: Text(option.label),
                    selected: apiFormat == option.value,
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    onSelected: (_) => setState(() => apiFormat = option.value),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
