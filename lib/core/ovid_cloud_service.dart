import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'diag.dart';
import 'firebase_service.dart';
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
  final String tier; // free | 5x | 10x | 20x
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
/// key can only spend that user's own budget.
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

  /// Test seams.
  @visibleForTesting
  static Future<String?> Function()? idTokenOverrideForTest;
  @visibleForTesting
  static Future<String?> Function()? appCheckTokenProvider;

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

    final c = client ?? http.Client();
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
          message: 'Monthly free limit reached. Upgrade or wait for reset.',
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
  /// rather than a wrong number). Free-tier callers get `isPaid=false` and
  /// should hide the figures (Zen-style) regardless.
  Future<OvidUsage?> fetchUsage({http.Client? client}) async {
    final idToken = idTokenOverrideForTest != null
        ? await idTokenOverrideForTest!()
        : await FirebaseService.I.getIdToken();
    if (idToken == null || idToken.isEmpty) return null;
    final appCheck = appCheckTokenProvider == null
        ? null
        : await appCheckTokenProvider!();
    final c = client ?? http.Client();
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
}

/// Server-authoritative usage snapshot for the Ovid Cloud plan.
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
  });

  final String tier;
  final bool isPaid;
  final double dailySpentUsd;
  final double dailyBudgetUsd;
  final double dailyRemainingUsd;
  final double monthFreeSpentUsd;
  final double monthFreeCapUsd;
  final int requestsToday;

  /// '24h' for free (daily reset), '30d' for paid (monthly pool, no daily cap).
  final String budgetWindow;

  /// Shared remaining fraction (0..1) of the budget pool across all models.
  final double remainingPct;

  /// Available models with per-token pricing + their shared remaining-%.
  final List<OvidModelUsage> models;

  bool get isMonthly => budgetWindow == '30d';

  factory OvidUsage.fromJson(Map<String, dynamic> j) => OvidUsage(
    tier: (j['tier'] as String?) ?? 'free',
    isPaid: (j['is_paid'] as bool?) ?? false,
    dailySpentUsd: (j['daily_spent_usd'] as num?)?.toDouble() ?? 0,
    dailyBudgetUsd: (j['daily_budget_usd'] as num?)?.toDouble() ?? 0,
    dailyRemainingUsd: (j['daily_remaining_usd'] as num?)?.toDouble() ?? 0,
    monthFreeSpentUsd: (j['month_free_spent_usd'] as num?)?.toDouble() ?? 0,
    monthFreeCapUsd: (j['month_free_cap_usd'] as num?)?.toDouble() ?? 0,
    requestsToday: (j['requests_today'] as num?)?.toInt() ?? 0,
    budgetWindow: (j['budget_window'] as String?) ?? '24h',
    remainingPct: (j['remaining_pct'] as num?)?.toDouble() ?? 0,
    models: [
      for (final m in (j['models'] as List? ?? const []))
        if (m is Map<String, dynamic>) OvidModelUsage.fromJson(m),
    ],
  );
}

/// One available model: its public name, per-token price, and the shared
/// remaining-% of the user's budget pool.
class OvidModelUsage {
  const OvidModelUsage({
    required this.model,
    required this.inputCostPerToken,
    required this.outputCostPerToken,
    required this.remainingPct,
  });
  final String model;
  final double? inputCostPerToken;
  final double? outputCostPerToken;
  final double remainingPct;

  /// Approx USD per 1M output tokens, for a human price hint. Null if unknown.
  double? get per1mOutput =>
      outputCostPerToken == null ? null : outputCostPerToken! * 1000000;

  factory OvidModelUsage.fromJson(Map<String, dynamic> j) => OvidModelUsage(
    model: (j['model'] as String?) ?? '',
    inputCostPerToken: (j['input_cost_per_token'] as num?)?.toDouble(),
    outputCostPerToken: (j['output_cost_per_token'] as num?)?.toDouble(),
    remainingPct: (j['remaining_pct'] as num?)?.toDouble() ?? 0,
  );
}
