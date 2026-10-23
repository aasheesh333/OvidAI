import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'diag.dart';
import 'distribution.dart';
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
  rejected, // account/provider changed or the account is not allowed
  sessionExpired, // /mint 401 even after a force-refreshed ID token
  deviceUnverified, // /mint 403 or App Check missing/invalid
  repairing, // /mint handed back the key the catalog just rejected
  unavailable, // network / 5xx / timeout
}

class MintOutcome {
  const MintOutcome(this.status, {this.result, this.message});
  final MintStatus status;
  final MintResult? result;
  final String? message;
  bool get ok => status == MintStatus.ok;
}

/// How a plan change ended (test `/upgrade` or a Google Play purchase), so the
/// UI can show specific copy instead of one generic failure (F-202).
enum UpgradeResult {
  /// The server confirmed the new tier.
  ok,

  /// Google Play reports a deferred/pending payment; nothing is active yet.
  pending,

  /// The user closed the Google Play purchase sheet.
  cancelled,

  /// No connection / timeout. Retrying makes sense.
  offline,

  /// Paid plans are not on sale (server disabled the path, no Play Billing).
  /// Never suggest retrying.
  notAvailable,

  /// The server refused (auth, account mismatch, invalid purchase, 402…).
  rejected,

  /// Restore found no active subscription for this Google account.
  nothingToRestore,

  /// Google Play took the payment but Ovid could not confirm it yet (verify
  /// unreachable / 404 / 5xx). The purchase stays unacknowledged, Play
  /// re-delivers it and it is re-verified on the next launch/resume (SH-002).
  /// Never "Nothing was charged".
  confirming,

  /// The Play purchase belongs to a different Ovid account (409 /
  /// account_mismatch): sign in with that account to use it.
  otherAccount,

  /// Anything else.
  unknown,
}

class UpgradeOutcome {
  const UpgradeOutcome(
    this.result, {
    this.tier,
    this.expiresAt,
    this.autoRenewing,
  });
  final UpgradeResult result;

  /// The server-confirmed tier when [result] is [UpgradeResult.ok].
  final String? tier;

  /// Subscription period end reported by `/billing/verify`, when known.
  final DateTime? expiresAt;
  final bool? autoRenewing;
  bool get ok => result == UpgradeResult.ok;
}

/// Server verdict for one Google Play purchase token (`/billing/verify`).
class PlayVerifyOutcome {
  const PlayVerifyOutcome(
    this.result, {
    this.tier,
    this.acknowledge = false,
    this.expiresAt,
    this.autoRenewing,
  });
  final UpgradeResult result;
  final String? tier;

  /// The client may acknowledge (complete) the purchase ONLY when true: the
  /// server verified the token with Google and set the tier.
  final bool acknowledge;
  final DateTime? expiresAt;
  final bool? autoRenewing;
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

  /// The scoped key the catalog last rejected (401/key_invalid, or a legacy
  /// gateway's 503 catalog_unavailable), with its owner. The next mint asks
  /// the server to rotate it; getting it back means the gateway is repairing.
  String? _rejectedKey;
  Object? _rejectedKeyIdentity;

  /// Resume-triggered recovery backoff (30 s doubling to 10 min, jittered).
  /// Reset by a ready connection or an explicit Retry.
  int _recoveryFailures = 0;
  DateTime? _resumeNotBefore;
  Object? _backoffIdentity;

  static const Duration _backoffBase = Duration(seconds: 30);
  static const Duration _backoffCap = Duration(minutes: 10);
  static final math.Random _random = math.Random();

  /// Test seam: the clock used for resume backoff.
  @visibleForTesting
  static DateTime Function() clockForTest = DateTime.now;

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

  /// True only when the provider's current key was minted for (and bound
  /// to) the signed-in account in this process. Chat requests must not send
  /// an Ovid Cloud key that belongs to a previous account.
  bool get keyOwnedByCurrentAccount {
    final provider = AppState.I.providerById(AppState.ovidCloudProviderId);
    final key = provider?.cleanApiKey ?? '';
    return provider != null &&
        key.isNotEmpty &&
        _keyIdentity == accountIdentity &&
        identical(_keyProvider, provider) &&
        _boundKey == key;
  }

  /// Whether [key] is the managed key bound to the signed-in account.
  bool ownsKey(String key) =>
      key.isNotEmpty && keyOwnedByCurrentAccount && key == _boundKey;

  /// App resume: like [ensureConnected], but failed recovery is retried with
  /// exponential backoff so a gateway outage is not hit by every resume of
  /// every client.
  Future<MintOutcome> ensureConnectedOnResume({
    AppState? app,
    http.Client? client,
  }) {
    final state = app ?? AppState.I;
    _authChanged();
    final notBefore = _resumeNotBefore;
    if (notBefore != null &&
        _backoffIdentity == accountIdentity &&
        clockForTest().isBefore(notBefore) &&
        connectionFor(state).status != CloudConnectionStatus.ready) {
      final current = connectionFor(state);
      return Future.value(
        MintOutcome(
          current.mintStatus ?? MintStatus.unavailable,
          message: current.error,
        ),
      );
    }
    return ensureConnected(app: state, client: client, userInitiated: false);
  }

  void _recordRecovery(AppState state, Object identity) {
    if (identity != accountIdentity) return;
    if (connectionFor(state).status == CloudConnectionStatus.ready) {
      _recoveryFailures = 0;
      _resumeNotBefore = null;
      _backoffIdentity = null;
      return;
    }
    _recoveryFailures++;
    final exponent = math.min(_recoveryFailures - 1, 10);
    var delay = _backoffBase * (1 << exponent);
    if (delay > _backoffCap) delay = _backoffCap;
    // Up to +20% jitter spreads a fleet of clients across the window.
    delay += delay * (_random.nextDouble() * 0.2);
    _backoffIdentity = identity;
    _resumeNotBefore = clockForTest().add(delay);
  }

  /// Login, explicit Retry and resume share one flight for the current owner.
  /// A catalog failure keeps its bound key and retries only the catalog.
  /// [force] re-fetches the catalog even when the connection is ready.
  Future<MintOutcome> ensureConnected({
    AppState? app,
    http.Client? client,
    bool force = false,
    bool userInitiated = true,
  }) {
    final state = app ?? AppState.I;
    _authChanged();
    final pending = _recoveryScope;
    if (_recoveryFlight != null &&
        pending != null &&
        identical(pending.state, state) &&
        pending.isCurrent) {
      return _recoveryFlight!;
    }
    if (!force && connectionFor(state).status == CloudConnectionStatus.ready) {
      return Future.value(const MintOutcome(MintStatus.ok));
    }
    if (userInitiated) {
      _recoveryFailures = 0;
      _resumeNotBefore = null;
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
              // The catalog rejected the bound key (revoked, expired or
              // deleted upstream). Re-mint once instead of retrying a dead key.
              if (_keyIdentity == null) return await _mint(state, client);
              return const MintOutcome(MintStatus.ok);
            } on CloudUsageException catch (e) {
              return MintOutcome(MintStatus.rejected, message: e.message);
            } finally {
              if (client == null) c.close();
            }
          }
          final outcome = await _mint(state, client);
          // The catalog rejected the key that was just minted (a stale cached
          // key server-side). Ask once for a rotation within the same flight.
          if (outcome.ok &&
              _keyIdentity == null &&
              _rejectedKey != null &&
              _rejectedKeyIdentity == scope.identity) {
            return await _mint(state, client);
          }
          return outcome;
        }, const MintOutcome(MintStatus.rejected)).whenComplete(() {
          if (identical(_recoveryFlight, flight)) {
            _recoveryFlight = null;
            _recoveryScope = null;
          }
          _recordRecovery(state, scope.identity);
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
    final previous = _uid;
    _uid = uid;
    _accountGeneration++;
    // A → signed out or A → B: the previous account's key must not stay on
    // the provider, or B's chats would be billed to A.
    if (previous != null) clearAccountKey();
    notifyListeners();
  }

  /// Forget the managed key, its ownership and the plan tier. Called on
  /// sign-out and account switch.
  void clearAccountKey({AppState? app}) {
    _keyIdentity = null;
    _keyProvider = null;
    _boundKey = null;
    _boundBaseUrl = null;
    _rejectedKey = null;
    _rejectedKeyIdentity = null;
    _confirmedIdentity = null;
    _confirmedTier = null;
    _recoveryFailures = 0;
    _resumeNotBefore = null;
    _backoffIdentity = null;
    final AppState state;
    try {
      state = app ?? AppState.I;
    } catch (_) {
      return;
    }
    state.setOvidCloudTier('free');
    final provider = state.providerById(AppState.ovidCloudProviderId);
    if (provider != null && provider.apiKey.isNotEmpty) {
      unawaited(
        state.updateProviderApiKey(provider, '').catchError((Object e) {
          Diag.swallow('ovid_cloud.clear_key', e);
        }),
      );
    }
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

  /// The shared instance: returns null (no header) unless OVID_APPCHECK=true.
  CloudAppCheck get _appCheck => CloudAppCheck.shared;

  Future<String> _appCheckToken({bool forceRefresh = false}) async {
    try {
      final override = appCheckTokenProvider;
      // Preserve existing SDK-free ID-token tests. Production always uses
      // SDK attestation; an explicit App Check seam must still return a token.
      if (override == null && idTokenOverrideForTest != null) return '';
      final token = override != null
          ? await override()
          : await _appCheck.getToken(forceRefresh: forceRefresh);
      // App Check is enforced by the gateway when enabled. Keep client-side
      // attestation best-effort so sideloaded/dev builds can still reach a
      // gateway configured with APPCHECK_ENABLED=false; the server remains
      // authoritative if attestation is required.
      return token?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<Map<String, String>> _headers(
    _CloudRequestScope scope, {
    bool forceRefresh = false,
  }) async {
    final token = forceRefresh && forceRefreshIdTokenOverrideForTest != null
        ? await forceRefreshIdTokenOverrideForTest!()
        : idTokenOverrideForTest != null
        ? await idTokenOverrideForTest!()
        : await FirebaseService.I.getIdToken(forceRefresh: forceRefresh);
    scope.check();
    if (token == null || token.isEmpty) {
      throw const CloudUsageException('Sign in to view your cloud allowance.');
    }
    final appCheck = await _appCheckToken(forceRefresh: forceRefresh);
    scope.check();
    return {
      'Authorization': 'Bearer $token',
      if (appCheck.isNotEmpty) 'X-Firebase-AppCheck': appCheck,
    };
  }

  /// Default mint endpoint. Points at the same gateway host as the Ovid Cloud
  /// provider's base URL; `/mint` is served (behind Cloudflare) by the VPS
  /// verifier that checks the Firebase ID token + App Check token.
  static const String mintUrl = 'https://api.ovidsi.com/mint';

  /// Server-authoritative usage endpoint. Usage is read from the server (the
  /// source of truth), NOT computed on the device — so it is identical across
  /// a user's devices and a reverse engineer cannot fake or inflate it.
  static const String usageUrl = 'https://api.ovidsi.com/usage';

  /// TEST-only upgrade endpoint (the "Pay now" button). The server gates it
  /// behind ALLOW_TEST_UPGRADE; a real payment webhook replaces it later.
  static const String upgradeUrl = 'https://api.ovidsi.com/upgrade';

  /// Google Play purchase-token verification (server/billing). The server
  /// checks the token with the Play Developer API and sets the tier; only
  /// then does the app acknowledge the purchase.
  static const String billingVerifyUrl =
      'https://api.ovidsi.com/billing/verify';

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

  /// Test seam: the ID token returned when /mint asks for a force refresh
  /// (falls back to [idTokenOverrideForTest] when unset).
  @visibleForTesting
  static Future<String?> Function()? forceRefreshIdTokenOverrideForTest;

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
      final rejectedKey = _rejectedKeyIdentity == scope.identity
          ? _rejectedKey
          : null;
      // Tell the gateway which key the catalog just rejected so it rotates
      // it instead of handing back its cached copy. Only a hash is sent.
      final mintBody = rejectedKey == null
          ? null
          : jsonEncode({
              'reason': 'key_rejected',
              'key_id': sha256.convert(utf8.encode(rejectedKey)).toString(),
            });
      Future<http.Response> post({bool forceRefresh = false}) async {
        final headers = await _headers(scope, forceRefresh: forceRefresh);
        final res = await c
            .post(
              Uri.parse(mintUrl),
              headers: {...headers, 'Content-Type': 'application/json'},
              body: mintBody,
            )
            .timeout(const Duration(seconds: 20));
        scope.check();
        return res;
      }

      var res = await post();
      // A stale/revoked ID token or a transient App Check failure: retry
      // once with freshly minted tokens before asking the user to act.
      if (res.statusCode == 401 || res.statusCode == 403) {
        res = await post(forceRefresh: true);
      }

      if (res.statusCode == 402) {
        return const MintOutcome(
          MintStatus.freeLimitReached,
          message: 'Free plan limit reached. Upgrade for more usage.',
        );
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        // The gateway may reject an account whose deletion was requested on
        // another device; re-read the account state (throttled).
        unawaited(FirebaseService.I.recheckAccountState(force: true));
        final detail = res.body.toLowerCase();
        final appCheck = RegExp(r'app[ _-]?check').hasMatch(detail);
        Diag.swallow(
          'ovid_cloud.mint_rejected',
          'HTTP ${res.statusCode}${appCheck ? ' (app check)' : ''}',
        );
        if (res.statusCode == 403 || appCheck) {
          return const MintOutcome(
            MintStatus.deviceUnverified,
            message:
                'This device could not be verified. Update Ovid from '
                'Google Play, then retry.',
          );
        }
        return const MintOutcome(
          MintStatus.sessionExpired,
          message: 'Your session expired. Sign in again to use Ovid Cloud.',
        );
      }
      if (res.statusCode == 429) {
        return const MintOutcome(
          MintStatus.unavailable,
          message: 'Ovid Cloud is busy. Retry in a moment.',
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

      if (rejectedKey != null && key == rejectedKey) {
        // The gateway has not rotated the dead key yet. Binding it again
        // would only loop Retry → rejected → Retry.
        return const MintOutcome(
          MintStatus.repairing,
          message: 'Ovid Cloud is being repaired. Try again in a few minutes.',
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
    if (r.baseUrl.isNotEmpty) {
      provider.baseUrl = ProviderConfig.normalizeOvidCloudBaseUrl(r.baseUrl);
    }
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
    _rejectedKey = null;
    _rejectedKeyIdentity = null;
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

  /// Gateways from `X-Ovid-Gateway: 2` on report a rejected key as 401
  /// `key_invalid`; their 503 is a genuine upstream outage.
  static bool _modernGateway(http.Response res) {
    for (final entry in res.headers.entries) {
      if (entry.key.toLowerCase() == 'x-ovid-gateway') {
        return (int.tryParse(entry.value.trim()) ?? 0) >= 2;
      }
    }
    return false;
  }

  static String? _errorCode(String body) {
    try {
      final decoded = jsonDecode(body);
      final error = decoded is Map ? decoded['error'] : null;
      final code = error is Map ? error['code'] : null;
      return code is String ? code : null;
    } catch (_) {
      return null;
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
        final code = _errorCode(res.body);
        // An expired/revoked scoped key requires a fresh mint. Gateways that
        // predate key_invalid report a rejected key as catalog_unavailable.
        if (res.statusCode == 401 ||
            res.statusCode == 403 ||
            (res.statusCode == 503 &&
                code == 'catalog_unavailable' &&
                !_modernGateway(res))) {
          _keyIdentity = null;
          _rejectedKey = scope.key;
          _rejectedKeyIdentity = scope.identity;
        }
        failed(switch (res.statusCode) {
          401 || 403 =>
            'Your Ovid Cloud session expired (${res.statusCode}). Retry to reconnect.',
          402 =>
            'Ovid Cloud usage limit reached (402). Upgrade or wait for reset.',
          429 => 'Ovid Cloud is busy (429). Retry in a moment.',
          _ =>
            'Ovid Cloud model catalog unavailable (${res.statusCode}). Retry.',
        });
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
        // No raw status codes on screen (EM-015). 401/403 here is the server
        // refusing this build or session, not a typo the user can fix.
        throw CloudUsageException(switch (res.statusCode) {
          401 || 403 =>
            "Ovid couldn't load your plan for this session. Retry, or sign "
                'out and back in.',
          429 => 'Too many requests. Wait a moment, then retry.',
          _ => 'Your plan and usage are unavailable right now. Retry in a '
              'moment.',
        });
      }
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final usage = OvidUsage.fromJson(j);
      OvidPlanCatalog.update(usage.plans);
      return usage;
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

  bool _upgradeDisabledByServer = false;

  /// True once `/upgrade` answered 403 "disabled": the server has no purchase
  /// path, so plan CTAs are hidden for the rest of the process.
  bool get upgradeDisabledByServer => _upgradeDisabledByServer;

  @visibleForTesting
  void resetUpgradeAvailabilityForTest() => _upgradeDisabledByServer = false;

  /// TEST "Pay now": upgrade the signed-in user's plan tier. Server-gated by
  /// ALLOW_TEST_UPGRADE. Returns the new tier on success, null on failure.
  Future<String?> upgrade(String tier, {http.Client? client}) async =>
      (await upgradeResult(tier, client: client)).tier;

  /// [upgrade] with the failure reason (offline / disabled / rejected …).
  Future<UpgradeOutcome> upgradeResult(String tier, {http.Client? client}) {
    final state = AppState.I;
    return _serializeMutation<UpgradeOutcome>(
      state,
      () => _upgrade(tier, state, client),
      const UpgradeOutcome(UpgradeResult.rejected),
    );
  }

  Future<UpgradeOutcome> _upgrade(
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
      if (res.statusCode == 403 &&
          res.body.toLowerCase().contains('disabled')) {
        // The server turned the test purchase path off ("test upgrade is
        // disabled"). Hide purchase CTAs instead of offering a dead button.
        _upgradeDisabledByServer = true;
        notifyListeners();
        return const UpgradeOutcome(UpgradeResult.notAvailable);
      }
      if (res.statusCode == 404 || res.statusCode == 501) {
        return const UpgradeOutcome(UpgradeResult.notAvailable);
      }
      if (res.statusCode >= 500) {
        return const UpgradeOutcome(UpgradeResult.unknown);
      }
      if (res.statusCode != 200) {
        return const UpgradeOutcome(UpgradeResult.rejected);
      }
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final newTier = j['tier'];
      if (j['ok'] != true ||
          newTier is! String ||
          newTier != tier ||
          !isKnownOvidTier(newTier)) {
        return const UpgradeOutcome(UpgradeResult.rejected);
      }
      await _applyConfirmedTier(newTier, scope, c);
      return UpgradeOutcome(UpgradeResult.ok, tier: newTier);
    } catch (e) {
      Diag.swallow('ovid_cloud.upgrade', e);
      return UpgradeOutcome(_failureResult(e));
    } finally {
      if (client == null) c.close();
    }
  }

  /// Ask the server to verify a Google Play purchase token and set the tier.
  /// Never acknowledges anything itself; see [PlayVerifyOutcome.acknowledge].
  Future<PlayVerifyOutcome> verifyPlayPurchase({
    required String productId,
    required String purchaseToken,
    required String packageName,
    http.Client? client,
  }) {
    final state = AppState.I;
    return _serializeMutation<PlayVerifyOutcome>(
      state,
      () => _verifyPlayPurchase(
        productId,
        purchaseToken,
        packageName,
        state,
        client,
      ),
      const PlayVerifyOutcome(UpgradeResult.rejected),
    );
  }

  Future<PlayVerifyOutcome> _verifyPlayPurchase(
    String productId,
    String purchaseToken,
    String packageName,
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
      Future<http.Response> send({bool forceRefresh = false}) async {
        final headers = await _headers(scope, forceRefresh: forceRefresh);
        return c
            .post(
              Uri.parse(billingVerifyUrl),
              headers: {...headers, 'Content-Type': 'application/json'},
              body: jsonEncode({
                'product_id': productId,
                'purchase_token': purchaseToken,
                'package_name': packageName,
              }),
            )
            .timeout(const Duration(seconds: 30));
      }

      var res = await send();
      scope.check();
      // A stale cached ID token must not turn a paid purchase into
      // "rejected": retry once with a fresh one.
      if (res.statusCode == 401) {
        res = await send(forceRefresh: true);
        scope.check();
      }
      Map<String, dynamic> body;
      try {
        body = jsonDecode(res.body) as Map<String, dynamic>;
      } catch (_) {
        body = const {};
      }
      if (res.statusCode == 202 || body['status'] == 'pending') {
        return const PlayVerifyOutcome(UpgradeResult.pending);
      }
      if (res.statusCode == 404 ||
          (res.statusCode == 503 &&
              (body['error'] is Map) &&
              (body['error'] as Map)['code'] == 'billing_unavailable')) {
        return const PlayVerifyOutcome(UpgradeResult.notAvailable);
      }
      if (res.statusCode >= 500) {
        return const PlayVerifyOutcome(UpgradeResult.unknown);
      }
      final errorCode = body['error'] is Map
          ? (body['error'] as Map)['code']
          : null;
      if (res.statusCode == 409 ||
          errorCode == 'account_mismatch' ||
          errorCode == 'purchase_owned_by_another_account') {
        return const PlayVerifyOutcome(UpgradeResult.otherAccount);
      }
      if (res.statusCode != 200) {
        return const PlayVerifyOutcome(UpgradeResult.rejected);
      }
      final tier = body['tier'];
      final expires = DateTime.tryParse('${body['expires_at'] ?? ''}');
      final autoRenewing = body['auto_renewing'] is bool
          ? body['auto_renewing'] as bool
          : null;
      if (tier is String && isKnownOvidTier(tier)) {
        // Active or not, the server's tier is authoritative for this account.
        await _applyConfirmedTier(tier, scope, c);
      }
      if (body['ok'] != true || tier is! String) {
        return PlayVerifyOutcome(
          UpgradeResult.rejected,
          tier: tier is String ? tier : null,
        );
      }
      return PlayVerifyOutcome(
        UpgradeResult.ok,
        tier: tier,
        acknowledge: body['acknowledge'] == true,
        expiresAt: expires,
        autoRenewing: autoRenewing,
      );
    } catch (e) {
      Diag.swallow('ovid_cloud.billing_verify', e);
      return PlayVerifyOutcome(_failureResult(e));
    } finally {
      if (client == null) c.close();
    }
  }

  Future<void> _applyConfirmedTier(
    String tier,
    _CloudRequestScope scope,
    http.Client c,
  ) async {
    _confirmTier(tier);
    scope.state.setOvidCloudTier(tier);
    scope.check();
    _allowanceChanged();
    await _refreshModels(scope, c);
    scope.check();
  }

  static UpgradeResult _failureResult(Object e) =>
      e is TimeoutException || e is http.ClientException || e is SocketException
      ? UpgradeResult.offline
      : e is CloudUsageException
      ? UpgradeResult.rejected
      : UpgradeResult.unknown;
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
/// OFFLINE FALLBACK ONLY, keyed by the stored tier the server reports in
/// `/usage.tier` (the plan's first alias). It mirrors the server's seed plan
/// table (cloud/apps/mint/src/planMath.ts `seedPlans`: Go ×1.5, Plus ×5,
/// Pro ×20); the live table — owner-editable in /admin — always wins via
/// [OvidPlanCatalog] (SH-006). The client never shows a dollar value of
/// usage, only plan prices (subscription metadata) and remaining fractions.
const Map<String, num> ovidPlanMultipliers = {
  'free': 1,
  '3x': 1.5,
  '7x': 5,
  '15x': 20,
};

/// Multiplier for [tier] over the Free base limit: the live server table
/// first, then the fallback (unknown tiers → 1).
num ovidPlanMultiplier(String tier) =>
    OvidPlanCatalog.byTier(tier)?.mult ?? ovidPlanMultipliers[tier] ?? 1;

/// A tier the server table (or the fallback) knows.
bool isKnownOvidTier(String tier) =>
    OvidPlanCatalog.byTier(tier) != null ||
    ovidPlanMultipliers.containsKey(tier);

/// Display name for [tier]: the live server table first, then the fallback.
/// The plan's display name, with a demo marker when this build grants plans
/// locally instead of selling them.
///
/// The marker lives here rather than on each screen: a demo build must not be
/// able to show "Ovid Plus" on one surface and "Ovid Plus (demo)" on another,
/// because the first reads as a real subscription.
String ovidPlanName(String tier) {
  final name =
      OvidPlanCatalog.byTier(tier)?.name ??
      OvidPlanCatalog.fallback
          .where((p) => p.tier == tier || p.id == tier)
          .firstOrNull
          ?.name ??
      'Free';
  return Distribution.billingDemo ? '$name (demo)' : name;
}

/// `×5` — whole multipliers bare, fractional ones with their decimal.
String ovidMultiplierLabel(num mult) =>
    '×${mult == mult.roundToDouble() ? mult.toInt() : mult}';

/// One sellable plan as the server describes it (`/usage.plans[]`, built
/// from the live plan table by the mint's planCards.ts).
class OvidPlan {
  const OvidPlan({
    required this.tier,
    required this.id,
    required this.name,
    required this.priceUsd,
    required this.mult,
    this.window,
    this.features = const [],
    this.productId,
  });

  /// The stored tier `/usage.tier` reports for this plan (first alias or id).
  final String tier;
  final String id;
  final String name;

  /// Subscription price in USD (plan metadata, shown as an indicative price
  /// until Google Play's localised price is loaded).
  final num priceUsd;

  /// Allowance multiplier over Free.
  final num mult;
  final String? window;
  final List<String> features;

  /// The Google Play subscription product mapped to this plan.
  final String? productId;

  bool get isFree => id == 'free' || priceUsd == 0;

  /// `$5 / month` style indicative price; null for Free.
  String? get indicativePrice {
    if (isFree) return null;
    final p = priceUsd == priceUsd.roundToDouble()
        ? priceUsd.toInt().toString()
        : priceUsd.toStringAsFixed(2);
    return 'US\$$p / month';
  }

  static OvidPlan? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final tier = raw['tier'];
    if (tier is! String || tier.isEmpty) return null;
    // Older servers send only {tier, features, product_id}: fill the rest
    // from the seed table, never "free" by accident.
    final seed = OvidPlanCatalog.fallback
        .where((p) => p.tier == tier)
        .firstOrNull;
    final id = raw['id'] is String ? raw['id'] as String : (seed?.id ?? tier);
    final name = raw['name'] is String && (raw['name'] as String).isNotEmpty
        ? raw['name'] as String
        : (seed?.name ?? ovidPlanName(tier));
    num number(String key, num fallback) {
      final v = raw[key];
      if (v is num && v.isFinite && v >= 0) return v;
      if (v is String) return num.tryParse(v) ?? fallback;
      return fallback;
    }

    return OvidPlan(
      tier: tier,
      id: id,
      name: name,
      priceUsd: number('price_usd', seed?.priceUsd ?? 0),
      mult: number('mult', seed?.mult ?? ovidPlanMultipliers[tier] ?? 1),
      window: raw['window'] is String ? raw['window'] as String : null,
      features: [
        for (final f in (raw['features'] is List ? raw['features'] as List : const []))
          if (f is String && f.trim().isNotEmpty && f.length <= 120) f,
      ].take(6).toList(),
      productId: raw['product_id'] is String ? raw['product_id'] as String : null,
    );
  }
}

/// The plan table last reported by the server, shared by Billing, Usage,
/// the sidebar and Account so they all say the same names and multipliers
/// (SH-006). Until the server answers, [fallback] mirrors the seed table.
class OvidPlanCatalog {
  OvidPlanCatalog._();

  static const fallback = <OvidPlan>[
    OvidPlan(tier: 'free', id: 'free', name: 'Free', priceUsd: 0, mult: 1),
    OvidPlan(tier: '3x', id: 'starter', name: 'Go', priceUsd: 5, mult: 1.5),
    OvidPlan(tier: '7x', id: 'pro', name: 'Plus', priceUsd: 18, mult: 5),
    OvidPlan(tier: '15x', id: 'max', name: 'Pro', priceUsd: 99, mult: 20),
  ];

  static List<OvidPlan>? _server;

  /// True once a server table has been seen in this process.
  static bool get fromServer => _server != null;

  /// The live table, else the fallback.
  static List<OvidPlan> get plans => _server ?? fallback;

  static void update(List<OvidPlan> plans) {
    if (plans.isNotEmpty) _server = List.unmodifiable(plans);
  }

  static OvidPlan? byTier(String tier) {
    for (final p in plans) {
      if (p.tier == tier || p.id == tier) return p;
    }
    return null;
  }

  @visibleForTesting
  static void resetForTest() => _server = null;
}

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
    this.billingEnabled = false,
    this.planExpiresAt,
    this.planAutoRenews,
    this.resetsAt,
    this.planFeatures = const {},
    this.window,
    this.today,
    this.hasRemainingFraction = false,
    this.plans = const [],
    this.planId,
    this.planName,
  });

  final String tier;

  /// Server field `plans`: the live plan table (names, prices, multipliers,
  /// features, Play products). Empty on servers that predate it.
  final List<OvidPlan> plans;

  /// Server field `plan`: the plan id (`starter`, `pro`, …).
  final String? planId;

  /// Server field `plan_name`: the display name of the current plan.
  final String? planName;

  /// The current plan from the server table (falls back to the catalog).
  OvidPlan? get currentPlan {
    for (final p in plans.isNotEmpty ? plans : OvidPlanCatalog.plans) {
      if (p.tier == tier || (planId != null && p.id == planId)) return p;
    }
    return null;
  }

  /// The name to show for the current plan: `plan_name`, else the table's.
  String get displayPlanName {
    final n = planName?.trim();
    if (n != null && n.isNotEmpty) return n;
    return currentPlan?.name ?? ovidPlanName(tier);
  }

  /// Server field `window` (`24h` | `30d`): the allowance window. Parsed only;
  /// the client never derives a reset time from it ([resetsAt] is shown).
  final String? window;

  /// Server field `today`: authoritative counters for the current day, across
  /// every device. Null on servers that predate it — the UI then falls back to
  /// this device's own journal instead of the always-zero `requests_today`.
  final OvidUsageToday? today;

  /// Whether the server sent the newer `remaining_fraction` field (it wins
  /// over the legacy `remaining_pct`).
  final bool hasRemainingFraction;

  /// Server field `plan_expires_at`: end of the current paid period (Play
  /// subscription), for "Renews on / Ends on". Null when free or unknown.
  final DateTime? planExpiresAt;

  /// Server field `plan_auto_renews`: false after the user cancelled in Play.
  final bool? planAutoRenews;

  /// Server field `resets_at`: when the current allowance window resets.
  final DateTime? resetsAt;

  /// Server field `plans`: per-tier feature lines (F-200). Empty when absent;
  /// the UI then falls back to built-in copy.
  final Map<String, List<String>> planFeatures;
  final bool isPaid;

  /// Server flag `billing_enabled`: a real purchase path exists. Absent or
  /// false means paid plans are not for sale yet.
  final bool billingEnabled;

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

  /// Server field `requests_today`.
  final int requestsToday;

  /// Raw server window string, parsed as-is. The client applies NO window
  /// logic of its own (no 24-hour cap anywhere client-side).
  final String budgetWindow;

  /// Shared remaining fraction (0..1) of the plan's usage across all models.
  final double remainingPct;

  /// Whether the server actually sent `remaining_pct`.
  final bool hasRemainingPct;

  /// Available models. On current servers each carries its own remaining
  /// usage ([OvidModelUsage.hasPerModelRemaining]); older servers send only a
  /// shared fraction, which the UI does not render per model.
  final List<OvidModelUsage> models;

  /// Models with per-model remaining usage, ordered for display: chat models
  /// before image models, then most remaining first; unpriced/unknown last.
  List<OvidModelUsage> get perModel {
    final rows = models.where((m) => m.hasPerModelRemaining).toList();
    int rank(OvidModelUsage m) => m.kind == 'image' ? 1 : 0;
    rows.sort((a, b) {
      final kind = rank(a).compareTo(rank(b));
      if (kind != 0) return kind;
      final ar = a.remaining, br = b.remaining;
      if (ar == null && br == null) return a.label.compareTo(b.label);
      if (ar == null) return 1;
      if (br == null) return -1;
      final byRemaining = br.compareTo(ar);
      return byRemaining != 0 ? byRemaining : a.label.compareTo(b.label);
    });
    return rows;
  }

  /// Only a valid server fraction is displayable. Missing/invalid values are
  /// unknown, not zero, and are never reconstructed from internal budgets.
  double? get remainingFraction =>
      hasRemainingPct ? _validRemainingFraction(remainingPct) : null;

  /// This plan's multiplier over the Free base limit.
  num get multiplier => currentPlan?.mult ?? ovidPlanMultiplier(tier);

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
    remainingPct:
        (j['remaining_fraction'] is num
                ? j['remaining_fraction'] as num
                : j['remaining_pct'] as num?)
            ?.toDouble() ??
        0,
    hasRemainingPct:
        j['remaining_fraction'] is num || j['remaining_pct'] is num,
    hasRemainingFraction: j['remaining_fraction'] is num,
    window: j['window'] is String ? j['window'] as String : null,
    today: OvidUsageToday.tryParse(j['today']),
    billingEnabled: j['billing_enabled'] == true,
    planExpiresAt: _parseServerTime(j['plan_expires_at']),
    planAutoRenews: j['plan_auto_renews'] is bool
        ? j['plan_auto_renews'] as bool
        : null,
    resetsAt: _parseServerTime(j['resets_at']),
    planFeatures: {
      for (final p in (j['plans'] is List ? j['plans'] as List : const []))
        if (p is Map &&
            p['tier'] is String &&
            (p['tier'] as String).isNotEmpty &&
            p['features'] is List)
          p['tier'] as String: [
            for (final f in p['features'] as List)
              if (f is String && f.trim().isNotEmpty && f.length <= 120) f,
          ].take(6).toList(),
    },
    plans: [
      for (final p in (j['plans'] is List ? j['plans'] as List : const []))
        ?OvidPlan.tryParse(p),
    ],
    planId: j['plan'] is String ? j['plan'] as String : null,
    planName: j['plan_name'] is String ? j['plan_name'] as String : null,
    models: [
      for (final m in (j['models'] as List? ?? const []))
        if (m is Map<String, dynamic>) OvidModelUsage.fromJson(m),
    ],
  );
}

/// Server-authoritative counters for the current day (`today`).
class OvidUsageToday {
  const OvidUsageToday({
    required this.requests,
    required this.inputTokens,
    required this.outputTokens,
    required this.images,
    this.byModel = const {},
  });

  final int requests;
  final int inputTokens;
  final int outputTokens;
  final int images;

  /// Server field `today.by_model`: the same counters per public model id
  /// for the current allowance window (every device on the account).
  final Map<String, OvidUsageToday> byModel;

  /// Null unless [value] is an object; missing/invalid counters read as 0.
  static OvidUsageToday? tryParse(Object? value) {
    if (value is! Map) return null;
    int count(String key) {
      final v = value[key];
      return v is num && v.isFinite && v >= 0 ? v.toInt() : 0;
    }

    final raw = value['by_model'];
    return OvidUsageToday(
      requests: count('requests'),
      inputTokens: count('input_tokens'),
      outputTokens: count('output_tokens'),
      images: count('images'),
      byModel: {
        if (raw is Map)
          for (final e in raw.entries)
            if (e.key is String && e.value is Map)
              e.key as String: OvidUsageToday.tryParse(e.value)!,
      },
    );
  }
}

/// One available model.
///
/// Current servers send `id`, `name`, `kind`, `priced` and the model's OWN
/// remaining usage as a count (`remaining_messages` for chat models,
/// `remaining_images` for image models), derived server-side from that
/// model's price: expensive models show fewer, cheap ones more. Older servers
/// send `model` plus a shared `remaining_pct`; per-token prices are parsed
/// (internal) but never rendered.
class OvidModelUsage {
  const OvidModelUsage({
    required this.model,
    required this.inputCostPerToken,
    required this.outputCostPerToken,
    required this.remainingPct,
    this.hasRemainingPct = true,
    this.name,
    this.kind = 'chat',
    this.priced = false,
    this.remainingMessages,
    this.remainingImages,
    this.auto = false,
    this.estimate,
    this.hasPerModelRemaining = false,
  });

  /// Public model id (`id`, or legacy `model`).
  final String model;

  /// Display name from the server, when sent.
  final String? name;

  /// `chat` | `image`.
  final String kind;

  /// Whether the server knows this model's price. Unpriced → remaining "—".
  final bool priced;
  final int? remainingMessages;
  final int? remainingImages;

  /// The Auto route (picks among the manual models per request).
  final bool auto;

  /// `conservative` when [remaining] is an estimate (Auto), else null.
  final String? estimate;

  /// True when the payload is the per-model contract (not the legacy shared
  /// fraction).
  final bool hasPerModelRemaining;

  /// Internal — never render.
  final double? inputCostPerToken;

  /// Internal — never render.
  final double? outputCostPerToken;
  final double remainingPct;
  final bool hasRemainingPct;

  bool get isImage => kind == 'image';

  /// Remaining count in this model's own unit; null when unknown/unpriced.
  int? get remaining {
    if (!priced) return null;
    return isImage ? remainingImages : remainingMessages;
  }

  /// Name to show: server `name`, else the public id label.
  String get label {
    final n = name?.trim();
    return n != null && n.isNotEmpty ? n : ovidModelLabel(model);
  }

  double? get remainingFraction =>
      hasRemainingPct ? _validRemainingFraction(remainingPct) : null;

  factory OvidModelUsage.fromJson(Map<String, dynamic> j) {
    final id = j['id'] is String ? j['id'] as String : null;
    final legacyModel = (j['model'] as String?) ?? '';
    final model = id ?? legacyModel;
    int? count(String key) {
      final v = j[key];
      return v is num && v.isFinite && v >= 0 ? v.toInt() : null;
    }

    final perModel =
        id != null ||
        j.containsKey('remaining_messages') ||
        j.containsKey('remaining_images');
    final kind = j['kind'] == 'image' || model == ImageStudio.alias
        ? 'image'
        : 'chat';
    return OvidModelUsage(
      model: model,
      name: j['name'] is String ? j['name'] as String : null,
      kind: kind,
      priced: j['priced'] is bool
          ? j['priced'] as bool
          : (count('remaining_messages') ?? count('remaining_images')) != null,
      remainingMessages: count('remaining_messages'),
      remainingImages: count('remaining_images'),
      auto: j['auto'] == true || model == 'auto',
      estimate: j['estimate'] is String ? j['estimate'] as String : null,
      hasPerModelRemaining: perModel,
      inputCostPerToken: legacyModel == ImageStudio.alias
          ? null
          : (j['input_cost_per_token'] as num?)?.toDouble(),
      outputCostPerToken: legacyModel == ImageStudio.alias
          ? null
          : (j['output_cost_per_token'] as num?)?.toDouble(),
      remainingPct: (j['remaining_pct'] as num?)?.toDouble() ?? 0,
      hasRemainingPct: j['remaining_pct'] is num,
    );
  }
}

DateTime? _parseServerTime(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

double? _validRemainingFraction(double value) =>
    value.isFinite && value >= 0 && value <= 1 ? value : null;
