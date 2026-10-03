import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'diag.dart';
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

/// Talks to the Ovid Cloud mint endpoint and wires the returned per-user key
/// into the built-in "Ovid Cloud" provider.
///
/// The real provider base URLs / keys never reach the client — the mint
/// endpoint hands back only this user's quota-limited virtual key, which is
/// stored in secure storage (via [AppState.updateProviderApiKey]). A leaked
/// key can only use that user's own plan limit.
class OvidCloudService {
  OvidCloudService._();
  static final OvidCloudService I = OvidCloudService._();

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

  /// Test seams.
  @visibleForTesting
  static Future<String?> Function()? idTokenOverrideForTest;
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
    final key = AppState.I.providerById(AppState.ovidCloudProviderId)?.cleanApiKey;
    final token = idTokenOverrideForTest != null
        ? await idTokenOverrideForTest!()
        : await FirebaseService.I.getIdToken();
    if (key == null || key.isEmpty || token == null || token.isEmpty) {
      ImageStudio.I.clearCapabilities();
      return {};
    }
    final appCheck = await appCheckTokenProvider?.call();
    return {
      'Authorization': 'Bearer $token',
      'X-Ovid-Key': key,
      if (appCheck != null && appCheck.isNotEmpty) 'X-Firebase-AppCheck': appCheck,
    };
  }

  /// Mint (or fetch) this signed-in user's key and bind it to the Ovid Cloud
  /// provider, then refresh the model list and default to Auto mode.
  Future<MintOutcome> bindOvidCloud({
    http.Client? client,
    AppState? app,
  }) async {
    final state = app ?? AppState.I;
    final idToken = idTokenOverrideForTest != null
        ? await idTokenOverrideForTest!()
        : await FirebaseService.I.getIdToken();
    if (idToken == null || idToken.isEmpty) {
      return const MintOutcome(MintStatus.notSignedIn);
    }
    final appCheck = appCheckTokenProvider == null
        ? null
        : await appCheckTokenProvider!();

    final c = client ?? _newClient();
    try {
      final res = await c
          .post(
            Uri.parse(mintUrl),
            headers: {
              'Authorization': 'Bearer $idToken',
              'Content-Type': 'application/json',
              if (appCheck != null && appCheck.isNotEmpty)
                'X-Firebase-AppCheck': appCheck,
            },
          )
          .timeout(const Duration(seconds: 20));

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
      await _bind(state, result);
      return MintOutcome(MintStatus.ok, result: result);
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

  Future<void> _bind(AppState state, MintResult r) async {
    final provider = state.providerById(AppState.ovidCloudProviderId);
    if (provider == null) return;
    if (r.baseUrl.isNotEmpty) provider.baseUrl = r.baseUrl;
    await state.updateProviderApiKey(provider, r.key);
    state.setOvidCloudTier(r.tier);
    await state.refreshOvidCloudModels();
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

  /// Fetch server-authoritative usage for the signed-in user. Returns null
  /// when signed out or the server is unreachable (the UI then shows nothing
  /// rather than a wrong number). The UI renders only the remaining
  /// percentage — never the internal dollar fields.
  Future<OvidUsage?> fetchUsage({http.Client? client}) async {
    final idToken = idTokenOverrideForTest != null
        ? await idTokenOverrideForTest!()
        : await FirebaseService.I.getIdToken();
    if (idToken == null || idToken.isEmpty) return null;
    final appCheck = appCheckTokenProvider == null
        ? null
        : await appCheckTokenProvider!();
    final c = client ?? _newClient();
    try {
      final res = await c
          .post(
            Uri.parse(usageUrl),
            headers: {
              'Authorization': 'Bearer $idToken',
              if (appCheck != null && appCheck.isNotEmpty)
                'X-Firebase-AppCheck': appCheck,
            },
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      return OvidUsage.fromJson(j);
    } catch (e) {
      Diag.swallow('ovid_cloud.usage', e);
      return null;
    } finally {
      if (client == null) c.close();
    }
  }

  /// TEST "Pay now": upgrade the signed-in user's plan tier. Server-gated by
  /// ALLOW_TEST_UPGRADE. Returns the new tier on success, null on failure.
  Future<String?> upgrade(String tier, {http.Client? client}) async {
    final idToken = idTokenOverrideForTest != null
        ? await idTokenOverrideForTest!()
        : await FirebaseService.I.getIdToken();
    if (idToken == null || idToken.isEmpty) return null;
    final appCheck = appCheckTokenProvider == null
        ? null
        : await appCheckTokenProvider!();
    final c = client ?? _newClient();
    try {
      final res = await c
          .post(
            Uri.parse(upgradeUrl),
            headers: {
              'Authorization': 'Bearer $idToken',
              'Content-Type': 'application/json',
              if (appCheck != null && appCheck.isNotEmpty)
                'X-Firebase-AppCheck': appCheck,
            },
            body: jsonEncode({'tier': tier}),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final newTier = j['tier'];
      if (j['ok'] != true ||
          newTier is! String ||
          newTier != tier ||
          !ovidPlanMultipliers.containsKey(newTier)) {
        return null;
      }
      AppState.I.setOvidCloudTier(newTier);
      await AppState.I.refreshOvidCloudModels();
      return newTier;
    } catch (e) {
      Diag.swallow('ovid_cloud.upgrade', e);
      return null;
    } finally {
      if (client == null) c.close();
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
        ? null : (j['input_cost_per_token'] as num?)?.toDouble(),
    outputCostPerToken: j['model'] == ImageStudio.alias
        ? null : (j['output_cost_per_token'] as num?)?.toDouble(),
    remainingPct: (j['remaining_pct'] as num?)?.toDouble() ?? 0,
    hasRemainingPct: j['remaining_pct'] is num,
  );
}

double? _validRemainingFraction(double value) =>
    value.isFinite && value >= 0 && value <= 1 ? value : null;
