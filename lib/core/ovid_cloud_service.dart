import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'diag.dart';
import 'cloud_app_check.dart';
import 'firebase_service.dart';
import 'image_studio.dart';
import 'state.dart';

/// Result of a successful mint: the user's per-user virtual key, their plan
/// tier, and the gateway base URL the app should talk to.
class MintResult {
  const MintResult({
    required this.key,
    required this.tier,
    required this.baseUrl,
  });
  final String key;
  final String tier; // free | 3x | 7x | 15x
  final String baseUrl;
}

/// How a [bindOvidCloud] attempt ended — so the UI can tell "signed out" from
/// "free limit reached" from "network down" without parsing strings.
enum MintStatus {
  ok,
  notSignedIn,
  freeLimitReached, // HTTP 402
  rejected, // 401/403 — bad/again-needed token, banned
  unavailable, // network / 5xx / timeout
}

class MintOutcome {
  const MintOutcome(this.status, {this.result, this.message});
  final MintStatus status;
  final MintResult? result;
  final String? message;
  bool get ok => status == MintStatus.ok;
}

enum CloudConnectionStatus { idle, connecting, loadingCatalog, ready, failed }

/// Ephemeral, account/credential-scoped status; never persisted with a key.
class CloudConnectionState {
  const CloudConnectionState(this.status, {this.error, this.mintStatus});
  final CloudConnectionStatus status;
  final String? error;
  final MintStatus? mintStatus;
  bool get loading =>
      status == CloudConnectionStatus.connecting ||
      status == CloudConnectionStatus.loadingCatalog;
}

/// Talks to the Ovid Cloud mint endpoint and wires the returned per-user key
/// into the built-in "Ovid Cloud" provider.
///
/// The real provider base URLs / keys never reach the client — the mint
/// endpoint hands back only this user's quota-limited virtual key, which is
/// stored in secure storage (via [AppState.updateProviderApiKey]). A leaked
/// key can only use that user's own plan limit.
class OvidCloudService extends ChangeNotifier {
  OvidCloudService._() {
    _uid = _currentUid;
    FirebaseService.I.addListener(_authChanged);
  }
  static final OvidCloudService I = OvidCloudService._();

  String? _uid;
  int _accountGeneration = 0;
  int _mutationRevision = 0;
  Object? _mutationQueueOwner;
  Future<void> _mutationTail = Future<void>.value();
  int _allowanceRevision = 0;
  Object? _confirmedIdentity;
  String? _confirmedTier;
  Object? _keyIdentity;
  ProviderConfig? _keyProvider;
  String? _boundKey;
  String? _boundBaseUrl;
  _CloudRequestScope? _connectionScope;
  CloudConnectionState _connection = const CloudConnectionState(
    CloudConnectionStatus.idle,
  );
  _CloudRequestScope? _recoveryScope;
  Future<MintOutcome>? _recoveryFlight;

  CloudConnectionState connectionFor(AppState state) {
    final scope = _connectionScope;
    if (scope == null || !identical(scope.state, state) || !scope.isCurrent) {
      return const CloudConnectionState(CloudConnectionStatus.idle);
    }
    return _connection;
  }

  void _publishConnection(
    _CloudRequestScope scope,
    CloudConnectionState value,
  ) {
    if (!scope.isCurrent) return;
    // Publication is revision-fenced, but an accepted snapshot stays valid
    // across a later failed upgrade with the same account and credentials.
    _connectionScope = _CloudRequestScope(this, scope.state);
    _connection = value;
    notifyListeners();
  }

  /// Login, explicit Retry and resume share one flight for the current owner.
  /// A catalog failure keeps its bound key and retries only the catalog.
  Future<MintOutcome> ensureConnected({AppState? app, http.Client? client}) {
    final state = app ?? AppState.I;
    _authChanged();
    final pending = _recoveryScope;
    if (_recoveryFlight != null &&
        pending != null &&
        identical(pending.state, state) &&
        pending.isCurrent) {
      return _recoveryFlight!;
    }
    if (connectionFor(state).status == CloudConnectionStatus.ready) {
      return Future.value(const MintOutcome(MintStatus.ok));
    }
    final scope = _CloudRequestScope(this, state);
    _recoveryScope = scope;
    late final Future<MintOutcome> flight;
    flight =
        _serializeMutation(state, () async {
          if (!scope.isCurrent) {
            return const MintOutcome(
              MintStatus.rejected,
              message:
                  'Account or cloud provider changed. Retry for the current account.',
            );
          }
          if (_keyIdentity == scope.identity &&
              identical(_keyProvider, scope.provider) &&
              _boundKey == scope.key &&
              _boundBaseUrl == scope.baseUrl &&
              scope.key.isNotEmpty) {
            final c = client ?? _newClient();
            try {
              await _refreshModels(scope, c);
              scope.check();
              return const MintOutcome(MintStatus.ok);
            } on CloudUsageException catch (e) {
              return MintOutcome(MintStatus.rejected, message: e.message);
            } finally {
              if (client == null) c.close();
            }
          }
          return _mint(state, client);
        }, const MintOutcome(MintStatus.rejected)).whenComplete(() {
          if (identical(_recoveryFlight, flight)) {
            _recoveryFlight = null;
            _recoveryScope = null;
          }
        });
    _recoveryFlight = flight;
    _publishConnection(
      scope,
      const CloudConnectionState(CloudConnectionStatus.connecting),
    );
    return flight;
  }

  String? get confirmedTier =>
      _confirmedIdentity == accountIdentity ? _confirmedTier : null;

  void _confirmTier(String tier) {
    _confirmedIdentity = accountIdentity;
    _confirmedTier = tier;
  }

  String? get _currentUid => FirebaseService.I.uid;

  void _authChanged() {
    final uid = _currentUid;
    if (uid == _uid) return;
    _uid = uid;
    _accountGeneration++;
    notifyListeners();
  }

  /// Includes a session generation: A → signed out → A is a new owner.
  /// The legacy token seam also serves as an identity in SDK-free tests.
  Object get accountIdentity => (
    _currentUid,
    _accountGeneration,
    idTokenOverrideForTest,
    FirebaseService.I.isAvailable
        ? FirebaseAuth.instance.currentUser?.uid
        : null,
  );

  int get allowanceRevision => _allowanceRevision;

  void _allowanceChanged() {
    _allowanceRevision++;
    notifyListeners();
  }

  /// Keep login mint and plan changes in server/application order. A failed
  /// upgrade must not cancel a valid login key; a new account must not wait
  /// for the previous account's network or credential-storage work.
  Future<T> _serializeMutation<T>(
    AppState state,
    Future<T> Function() action,
    T staleResult,
  ) {
    _authChanged();
    final identity = accountIdentity;
    final provider = state.providerById(AppState.ovidCloudProviderId);
    final owner = (state, identity);
    if (_mutationQueueOwner != owner) {
      _mutationQueueOwner = owner;
      _mutationTail = Future<void>.value();
    }
    final result = _mutationTail.then<T>((_) {
      if (identity != accountIdentity ||
          !identical(
            provider,
            state.providerById(AppState.ovidCloudProviderId),
          )) {
        return staleResult;
      }
      // Capture the key/base URL in the operation after the preceding mint
      // has finished, while preserving the account/provider captured at entry.
      return action();
    });
    _mutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  final _appCheck = CloudAppCheck(
    initializeFirebase: () => FirebaseService.I.initialize(),
    activatedByFirebase: () => FirebaseService.I.accountService.enabled,
  );

  Future<String> _appCheckToken() async {
    try {
      final override = appCheckTokenProvider;
      // Preserve existing SDK-free ID-token tests. Production always uses
      // SDK attestation; an explicit App Check seam must still return a token.
      if (override == null && idTokenOverrideForTest != null) return '';
      final token = override != null
          ? await override()
          : await _appCheck.getToken();
      if (token == null || token.trim().isEmpty) {
        throw const CloudUsageException(
          'App Check could not verify this app. Restart the app and retry.',
        );
      }
      return token;
    } catch (_) {
      throw const CloudUsageException(
        'App Check could not verify this app. Restart the app and retry.',
      );
    }
  }

  Future<Map<String, String>> _headers(_CloudRequestScope scope) async {
    final token = idTokenOverrideForTest != null
        ? await idTokenOverrideForTest!()
        : await FirebaseService.I.getIdToken();
    scope.check();
    if (token == null || token.isEmpty) {
      throw const CloudUsageException('Sign in to view your cloud allowance.');
    }
    final appCheck = await _appCheckToken();
    scope.check();
    return {
      'Authorization': 'Bearer $token',
      if (appCheck.isNotEmpty) 'X-Firebase-AppCheck': appCheck,
    };
  }

  /// Default mint endpoint. Points at the same gateway host as the Ovid Cloud
  /// provider's base URL; `/mint` is served (behind Cloudflare) by the VPS
  /// verifier that checks the Firebase ID token + App Check token.
  static const String mintUrl = 'https://cloud.dhanuksoftwares.com/mint';

  /// Server-authoritative usage endpoint. Usage is read from the server (the
  /// source of truth), NOT computed on the device — so it is identical across
  /// a user's devices and a reverse engineer cannot fake or inflate it.
  static const String usageUrl = 'https://cloud.dhanuksoftwares.com/usage';

  /// TEST-only upgrade endpoint (the "Pay now" button). The server gates it
  /// behind ALLOW_TEST_UPGRADE; a real payment webhook replaces it later.
  static const String upgradeUrl = 'https://cloud.dhanuksoftwares.com/upgrade';

  /// Test seam: force a specific [CloudConnectionState] for [state] without
  /// going through the mint/retry round-trip. Lets widget tests exercise the
  /// `ready`/`failed`/`idle` branches of surfaces that read [connectionFor]
  /// (picker, provider cards, cloud banners).
  @visibleForTesting
  void setConnectionForTest(AppState state, CloudConnectionState value) {
    _connectionScope = _CloudRequestScope(this, state);
    _connection = value;
    notifyListeners();
  }

  /// Test seams.
  @visibleForTesting
  static Future<String?> Function()? get idTokenOverrideForTest =>
      _idTokenOverride;
  static Future<String?> Function()? _idTokenOverride;
  @visibleForTesting
  static set idTokenOverrideForTest(Future<String?> Function()? value) {
    if (identical(value, _idTokenOverride)) return;
    _idTokenOverride = value;
    I._accountGeneration++;
    I.notifyListeners();
  }

  @visibleForTesting
  static Future<String?> Function()? appCheckTokenProvider;

  /// Test seam: builds the HTTP client used when a caller passes none (lets
  /// widget tests drive the real /usage and test-mode /upgrade flows).
  @visibleForTesting
  static http.Client Function()? httpClientFactoryForTest;

  static http.Client _newClient() =>
      httpClientFactoryForTest?.call() ?? http.Client();

  /// Image routes verify Firebase/App Check AND the user's current scoped key.
  Future<Map<String, String>> imageHeaders() async {
    final scope = _CloudRequestScope(this, AppState.I);
    if (_keyIdentity != accountIdentity ||
        !identical(_keyProvider, scope.provider) ||
        _boundKey != scope.key) {
      ImageStudio.I.clearCapabilities();
      return {};
    }
    try {
      final headers = await _headers(scope);
      scope.check();
      if (scope.key.isEmpty) {
        ImageStudio.I.clearCapabilities();
        return {};
      }
      return {...headers, 'X-Ovid-Key': scope.key};
    } on CloudUsageException {
      ImageStudio.I.clearCapabilities();
      rethrow;
    }
  }

  /// Mint (or fetch) this signed-in user's key and bind it to the Ovid Cloud
  /// provider, then refresh the model list and default to Auto mode.
  Future<MintOutcome> bindOvidCloud({http.Client? client, AppState? app}) {
    final state = app ?? AppState.I;
    return _serializeMutation(
      state,
      () => _mint(state, client),
      const MintOutcome(
        MintStatus.rejected,
        message:
            'Account or cloud provider changed. Retry for the current account.',
      ),
    );
  }

  Future<MintOutcome> _mint(AppState state, http.Client? client) async {
    final revision = ++_mutationRevision;
    final scope = _CloudRequestScope(
      this,
      state,
      isLatest: () => revision == _mutationRevision,
    );
    _publishConnection(
      scope,
      const CloudConnectionState(CloudConnectionStatus.connecting),
    );
    final outcome = await _requestMint(state, client, scope);
    if (!outcome.ok) {
      _publishConnection(
        scope,
        CloudConnectionState(
          CloudConnectionStatus.failed,
          error: outcome.message,
          mintStatus: outcome.status,
        ),
      );
    }
    return outcome;
  }

  Future<MintOutcome> _requestMint(
    AppState state,
    http.Client? client,
    _CloudRequestScope scope,
  ) async {
    final c = client ?? _newClient();
    try {
      final headers = await _headers(scope);
      final res = await c
          .post(
            Uri.parse(mintUrl),
            headers: {...headers, 'Content-Type': 'application/json'},
          )
          .timeout(const Duration(seconds: 20));
      scope.check();

      if (res.statusCode == 402) {
        return const MintOutcome(
          MintStatus.freeLimitReached,
          message: 'Free plan limit reached. Upgrade for more usage.',
        );
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        return MintOutcome(
          MintStatus.rejected,
          message: 'Sign-in could not be verified (${res.statusCode}).',
        );
      }
      if (res.statusCode != 200) {
        return MintOutcome(
          MintStatus.unavailable,
          message: 'Ovid Cloud is unavailable (${res.statusCode}).',
        );
      }

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final key = (body['key'] as String?)?.trim() ?? '';
      final tier = (body['tier'] as String?)?.trim() ?? 'free';
      final baseUrl = (body['base_url'] as String?)?.trim() ?? '';
      if (key.isEmpty) {
        return const MintOutcome(
          MintStatus.unavailable,
          message: 'Ovid Cloud returned no key.',
        );
      }

      final result = MintResult(key: key, tier: tier, baseUrl: baseUrl);
      await _bind(state, result, scope, c);
      return MintOutcome(MintStatus.ok, result: result);
    } on CloudUsageException catch (e) {
      return MintOutcome(
        e.message.startsWith('Sign in')
            ? MintStatus.notSignedIn
            : MintStatus.rejected,
        message: e.message,
      );
    } on FormatException {
      return const MintOutcome(
        MintStatus.unavailable,
        message: 'Ovid Cloud returned an invalid connection response. Retry.',
      );
    } on TypeError {
      return const MintOutcome(
        MintStatus.unavailable,
        message: 'Ovid Cloud returned an invalid connection response. Retry.',
      );
    } catch (e) {
      Diag.swallow('ovid_cloud.bind', e);
      return const MintOutcome(
        MintStatus.unavailable,
        message: 'Could not reach Ovid Cloud. Check your connection.',
      );
    } finally {
      if (client == null) c.close();
    }
  }

  Future<void> _bind(
    AppState state,
    MintResult r,
    _CloudRequestScope scope,
    http.Client client,
  ) async {
    scope.check();
    final provider = state.providerById(AppState.ovidCloudProviderId);
    if (provider == null) {
      throw const CloudUsageException('Ovid Cloud provider is unavailable.');
    }
    final recovery = _recoveryScope;
    final ownsRecovery =
        recovery != null &&
        identical(recovery.state, state) &&
        recovery.isCurrent;
    if (r.baseUrl.isNotEmpty) provider.baseUrl = r.baseUrl;
    scope.baseUrl = provider.baseUrl;
    scope.key = r.key;
    if (ownsRecovery) {
      recovery.key = scope.key;
      recovery.baseUrl = scope.baseUrl;
    }
    final binding = state.updateProviderApiKey(provider, r.key);
    _publishConnection(
      scope,
      const CloudConnectionState(CloudConnectionStatus.connecting),
    );
    await binding;
    scope.check();
    _keyIdentity = accountIdentity;
    _keyProvider = provider;
    _boundKey = r.key;
    _boundBaseUrl = scope.baseUrl;
    _confirmTier(r.tier);
    state.setOvidCloudTier(r.tier);
    scope.check();
    _allowanceChanged();
    await _refreshModels(scope, client);
    scope.check();
    // Default the app to Auto mode on Ovid Cloud if nothing else is selected.
    if (state.lastSelectedModel.isEmpty ||
        state.lastSelectedProviderId == null) {
      final models = provider.models;
      final auto = models.contains('auto')
          ? 'auto'
          : (models.isNotEmpty ? models.first : 'auto');
      state.setModel(AppState.ovidCloudProviderId, auto);
    }
  }

  /// AppState's general model fetch has no ownership fence. Keep publication
  /// here bound to the exact account, provider object, key and base URL.
  Future<void> _refreshModels(
    _CloudRequestScope scope,
    http.Client client,
  ) async {
    scope.check();
    if (scope.provider == null || scope.baseUrl.isEmpty) {
      _publishConnection(
        scope,
        const CloudConnectionState(
          CloudConnectionStatus.failed,
          error: 'Ovid Cloud provider is unavailable. Retry.',
        ),
      );
      return;
    }
    // An upgrade may finish before this account's mint. Never refresh models
    // with a persisted key whose account ownership has not been confirmed.
    if (_keyIdentity != scope.identity ||
        !identical(_keyProvider, scope.provider) ||
        _boundKey != scope.key) {
      return;
    }
    _publishConnection(
      scope,
      const CloudConnectionState(CloudConnectionStatus.loadingCatalog),
    );
    void failed(String message) => _publishConnection(
      scope,
      CloudConnectionState(CloudConnectionStatus.failed, error: message),
    );
    try {
      final base = scope.baseUrl.endsWith('/')
          ? scope.baseUrl
          : '${scope.baseUrl}/';
      final res = await client
          .get(
            Uri.parse('${base}models'),
            headers: {
              if (scope.key.isNotEmpty) 'Authorization': 'Bearer ${scope.key}',
            },
          )
          .timeout(const Duration(seconds: 15));
      scope.check();
      if (res.statusCode != 200) {
        // An expired/revoked scoped key requires re-verification on Retry.
        if (res.statusCode == 401 || res.statusCode == 403) _keyIdentity = null;
        failed(
          'Ovid Cloud model catalog unavailable (${res.statusCode}). Retry.',
        );
        return;
      }
      final body = jsonDecode(res.body);
      final rows = body is Map ? body['data'] ?? body['models'] : null;
      if (rows is! List) throw const FormatException();
      final ids = <String>{};
      for (final row in rows) {
        if (row is Map &&
            (row['output_modality'] == 'image' ||
                row['id'] == ImageStudio.alias)) {
          continue;
        }
        final id = row is Map ? row['id'] ?? row['name'] : row;
        if (id is! String || id.trim().isEmpty) {
          throw const FormatException();
        }
        ids.add(id.trim());
      }
      if (ids.isEmpty) {
        failed(
          'Ovid Cloud returned no chat models. Retry to refresh the catalog.',
        );
        return;
      }
      scope.provider!.models
        ..clear()
        ..addAll({'auto', ...ids});
      scope.state.reconcileProviderModels(AppState.ovidCloudProviderId);
      _publishConnection(
        scope,
        const CloudConnectionState(CloudConnectionStatus.ready),
      );
    } on CloudUsageException {
      rethrow;
    } on FormatException {
      failed('Ovid Cloud returned an invalid model catalog. Retry.');
    } catch (e) {
      Diag.swallow('ovid_cloud.models', e);
      failed(
        'Could not load Ovid Cloud models. Check your connection and retry.',
      );
    }
  }

  /// Fetch server-authoritative usage for the signed-in user. Returns null
  /// when signed out or the server is unreachable (the UI then shows nothing
  /// rather than a wrong number). The UI renders only the remaining
  /// percentage — never the internal dollar fields.
  Future<OvidUsage?> fetchUsage({
    http.Client? client,
    bool throwOnError = false,
  }) async {
    final revision = _mutationRevision;
    final scope = _CloudRequestScope(
      this,
      AppState.I,
      isLatest: () => revision == _mutationRevision,
    );
    final c = client ?? _newClient();
    try {
      final headers = await _headers(scope);
      final res = await c
          .post(Uri.parse(usageUrl), headers: headers)
          .timeout(const Duration(seconds: 15));
      scope.check();
      if (res.statusCode != 200) {
        throw CloudUsageException(
          'Cloud allowance unavailable (${res.statusCode}). Retry to refresh.',
        );
      }
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      return OvidUsage.fromJson(j);
    } catch (e) {
      Diag.swallow('ovid_cloud.usage', e);
      if (throwOnError) {
        throw e is CloudUsageException
            ? e
            : const CloudUsageException(
                'Cloud allowance unavailable. Check your connection and retry.',
              );
      }
      return null;
    } finally {
      if (client == null) c.close();
    }
  }

  /// TEST "Pay now": upgrade the signed-in user's plan tier. Server-gated by
  /// ALLOW_TEST_UPGRADE. Returns the new tier on success, null on failure.
  Future<String?> upgrade(String tier, {http.Client? client}) {
    final state = AppState.I;
    return _serializeMutation<String?>(
      state,
      () => _upgrade(tier, state, client),
      null,
    );
  }

  Future<String?> _upgrade(
    String tier,
    AppState state,
    http.Client? client,
  ) async {
    final revision = ++_mutationRevision;
    final scope = _CloudRequestScope(
      this,
      state,
      isLatest: () => revision == _mutationRevision,
    );
    final c = client ?? _newClient();
    try {
      final headers = await _headers(scope);
      final res = await c
          .post(
            Uri.parse(upgradeUrl),
            headers: {...headers, 'Content-Type': 'application/json'},
            body: jsonEncode({'tier': tier}),
          )
          .timeout(const Duration(seconds: 20));
      scope.check();
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final newTier = j['tier'];
      if (j['ok'] != true ||
          newTier is! String ||
          newTier != tier ||
          !ovidPlanMultipliers.containsKey(newTier)) {
        return null;
      }
      _confirmTier(newTier);
      state.setOvidCloudTier(newTier);
      scope.check();
      _allowanceChanged();
      await _refreshModels(scope, c);
      scope.check();
      return newTier;
    } catch (e) {
      Diag.swallow('ovid_cloud.upgrade', e);
      return null;
    } finally {
      if (client == null) c.close();
    }
  }
}

class CloudUsageException implements Exception {
  const CloudUsageException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _CloudRequestScope {
  _CloudRequestScope(this.service, this.state, {this.isLatest})
    : provider = state.providerById(AppState.ovidCloudProviderId) {
    // LoginGate can start mint from an earlier Firebase listener in the same
    // notification. Observe the new UID before capturing its generation.
    service._authChanged();
    identity = service.accountIdentity;
    key = provider?.cleanApiKey ?? '';
    baseUrl = provider?.baseUrl ?? '';
  }
  final OvidCloudService service;
  final AppState state;
  late final Object identity;
  final ProviderConfig? provider;
  final bool Function()? isLatest;
  late String key;
  late String baseUrl;

  bool get isCurrent {
    try {
      check();
      return true;
    } on CloudUsageException {
      return false;
    }
  }

  void check() {
    if (identity != service.accountIdentity ||
        (isLatest != null && !isLatest!()) ||
        !identical(
          provider,
          state.providerById(AppState.ovidCloudProviderId),
        ) ||
        key != (provider?.cleanApiKey ?? '') ||
        baseUrl != (provider?.baseUrl ?? '')) {
      throw const CloudUsageException(
        'Account or cloud provider changed. Retry for the current account.',
      );
    }
  }
}

/// Plan multipliers over the Free base limit: paid limit = Free × multiplier.
///
/// The server applies this to its own (internal) base amount. The client only
/// ever shows the multiplier and a remaining fraction — never a dollar value.
const Map<String, int> ovidPlanMultipliers = {
  'free': 1,
  '3x': 3,
  '7x': 7,
  '15x': 15,
};

/// Multiplier for [tier] over the Free base limit (unknown tiers → 1).
int ovidPlanMultiplier(String tier) => ovidPlanMultipliers[tier] ?? 1;

/// Server-authoritative usage snapshot for the Ovid Cloud plan.
///
/// The `*Usd` fields mirror what the server sends and are kept for parsing
/// only — they are INTERNAL and must never be rendered. The UI shows only
/// [remainingFraction] (a percentage + progress bar), when supplied.
class OvidUsage {
  const OvidUsage({
    required this.tier,
    required this.isPaid,
    required this.dailySpentUsd,
    required this.dailyBudgetUsd,
    required this.dailyRemainingUsd,
    required this.monthFreeSpentUsd,
    required this.monthFreeCapUsd,
    required this.requestsToday,
    required this.budgetWindow,
    required this.remainingPct,
    required this.models,
    this.hasRemainingPct = true,
  });

  final String tier;
  final bool isPaid;

  /// Internal (server field `daily_spent_usd`) — never render.
  final double dailySpentUsd;

  /// Internal (server field `daily_budget_usd`) — never render.
  final double dailyBudgetUsd;

  /// Internal (server field `daily_remaining_usd`) — never render.
  final double dailyRemainingUsd;

  /// Internal (server field `month_free_spent_usd`) — never render.
  final double monthFreeSpentUsd;

  /// Internal (server field `month_free_cap_usd`) — never render.
  final double monthFreeCapUsd;

  /// Server field `requests_today` (parsed, not rendered).
  final int requestsToday;

  /// Raw server window string, parsed as-is. The client applies NO window
  /// logic of its own (no 24-hour cap anywhere client-side).
  final String budgetWindow;

  /// Shared remaining fraction (0..1) of the plan's usage across all models.
  final double remainingPct;

  /// Whether the server actually sent `remaining_pct`.
  final bool hasRemainingPct;

  /// Available models with their shared remaining fraction.
  final List<OvidModelUsage> models;

  /// Only a valid server fraction is displayable. Missing/invalid values are
  /// unknown, not zero, and are never reconstructed from internal budgets.
  double? get remainingFraction =>
      hasRemainingPct ? _validRemainingFraction(remainingPct) : null;

  /// This plan's multiplier over the Free base limit.
  int get multiplier => ovidPlanMultiplier(tier);

  factory OvidUsage.fromJson(Map<String, dynamic> j) => OvidUsage(
    tier: (j['tier'] as String?) ?? 'free',
    isPaid: (j['is_paid'] as bool?) ?? false,
    dailySpentUsd: (j['daily_spent_usd'] as num?)?.toDouble() ?? 0,
    dailyBudgetUsd: (j['daily_budget_usd'] as num?)?.toDouble() ?? 0,
    dailyRemainingUsd: (j['daily_remaining_usd'] as num?)?.toDouble() ?? 0,
    monthFreeSpentUsd: (j['month_free_spent_usd'] as num?)?.toDouble() ?? 0,
    monthFreeCapUsd: (j['month_free_cap_usd'] as num?)?.toDouble() ?? 0,
    requestsToday: (j['requests_today'] as num?)?.toInt() ?? 0,
    budgetWindow: (j['budget_window'] as String?) ?? '',
    remainingPct: (j['remaining_pct'] as num?)?.toDouble() ?? 0,
    hasRemainingPct: j['remaining_pct'] is num,
    models: [
      for (final m in (j['models'] as List? ?? const []))
        if (m is Map<String, dynamic>) OvidModelUsage.fromJson(m),
    ],
  );
}

/// One available model: its public name and the shared remaining fraction of
/// the user's plan usage. Per-token prices are parsed (internal) but never
/// rendered.
class OvidModelUsage {
  const OvidModelUsage({
    required this.model,
    required this.inputCostPerToken,
    required this.outputCostPerToken,
    required this.remainingPct,
    this.hasRemainingPct = true,
  });
  final String model;

  /// Internal — never render.
  final double? inputCostPerToken;

  /// Internal — never render.
  final double? outputCostPerToken;
  final double remainingPct;
  final bool hasRemainingPct;

  double? get remainingFraction =>
      hasRemainingPct ? _validRemainingFraction(remainingPct) : null;

  factory OvidModelUsage.fromJson(Map<String, dynamic> j) => OvidModelUsage(
    model: (j['model'] as String?) ?? '',
    inputCostPerToken: j['model'] == ImageStudio.alias
        ? null
        : (j['input_cost_per_token'] as num?)?.toDouble(),
    outputCostPerToken: j['model'] == ImageStudio.alias
        ? null
        : (j['output_cost_per_token'] as num?)?.toDouble(),
    remainingPct: (j['remaining_pct'] as num?)?.toDouble() ?? 0,
    hasRemainingPct: j['remaining_pct'] is num,
  );
}

double? _validRemainingFraction(double value) =>
    value.isFinite && value >= 0 && value <= 1 ? value : null;
