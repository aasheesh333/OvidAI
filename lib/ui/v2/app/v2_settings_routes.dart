import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/account_service.dart';
import '../../../core/app_info.dart';
import '../../../core/auth_identity.dart';
import '../../../core/auth_providers.dart';
import '../../../core/connection_service.dart';
import '../../../core/distribution.dart';
import '../../../core/background_notifications.dart';
import '../../../core/cloud/account_health.dart';
import '../../../core/cloud/account_settings_client.dart';
import '../../../core/cloud/artifact_vault.dart';
import '../../../core/cloud/cloud_rest.dart';
import '../../../core/cloud/cloud_session_store.dart';
import '../../../core/cloud/credentials.dart';
import '../../../core/cloud/plans_client.dart';
import '../../../core/cloud/projects.dart';
import '../../../core/cloud/usage_history.dart';
import '../../../core/commands.dart';
import '../../../core/firebase_service.dart';
import '../../../core/format.dart';
import '../../../core/github_service.dart';
import '../../../core/legal_links.dart';
import '../../../core/notification_permission.dart';
import '../../../core/ovid_cloud_service.dart';
import '../../../core/play_billing.dart';
import '../../../core/presets.dart';
import '../../../core/revenuecat_billing.dart';
import '../../../core/state.dart' hide ServiceStatus;
import '../../auth_methods.dart';
import '../../github_login_sheet.dart';
import '../settings/account_health_page.dart' as health;
import '../settings/account_page.dart';
import '../settings/appearance_page.dart';
import '../settings/credentials_page.dart';
import '../settings/data_control_page.dart';
import '../settings/memory_page.dart';
import '../settings/plan_billing_page.dart';
import '../settings/storage_page.dart';
import '../settings/usage_page.dart';
import '../settings_extra/about_page.dart';
import '../settings_extra/agent_presets_page.dart';
import '../settings_extra/memory_files_page.dart';
import '../settings_extra/notifications_page.dart';
import '../settings_extra/permissions_page.dart';
import '../settings_extra/response_wait_page.dart';
import '../settings_extra/shared_memory_page.dart';
import '../states/system_states_page.dart';
import 'app_lock_settings_page.dart';
import 'v2_settings_actions.dart';

/// Builds every settings destination from live app state.
///
/// Each page is still presentational; this file is the only place that reads
/// `AppState`, Firebase and the cloud services for settings. Rows that are not
/// backed by a real source yet render a disabled row, never demo data.
class V2SettingsRoutes {
  const V2SettingsRoutes._();

  static Future<void> open(
    BuildContext context,
    String id,
    V2SettingsActions actions,
  ) async {
    // Danger rows act immediately (with their own confirmation) instead of
    // opening a second screen.
    if (id == 'delete') {
      await actions.deleteAllData(context);
      return;
    }
    if (id == 'reset_memory') {
      await actions.resetMemory(context);
      return;
    }
    final page = _page(context, id, actions);
    if (page == null) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  static Widget? _page(
    BuildContext context,
    String id,
    V2SettingsActions actions,
  ) {
    switch (id) {
      case 'account':
        return AccountPage(data: _account(context, actions));
      case 'plan_billing':
        return _PlanLoader(actions: actions);
      case 'usage':
        return _UsageLoader(actions: actions);
      case 'memory':
        return _MemoryLoader(actions: actions);
      case 'shared_memory':
        return _SharedMemoryLoader(actions: actions);
      case 'memory_files':
        return const MemoryFilesPage.live();
      case 'appearance':
        return _AppearanceLoader(actions: actions);
      case 'data_control':
      case 'export':
      case 'crash':
        return _DataControlLoader(actions: actions);
      case 'storage':
        return _StorageLoader(actions: actions);
      case 'credentials':
        return _CredentialsLoader(actions: actions);
      case 'account_health':
        return _AccountHealthLoader(actions: actions);
      case 'notifications':
        return _NotificationsLoader(actions: actions);
      case 'presets':
        return _PresetLoader(actions: actions);
      case 'response_wait':
        return ResponseWaitPage(data: _responseWait(context, actions));
      case 'permissions':
        return _PermissionsLoader();
      case 'app_lock':
        return const AppLockSettingsPage();
      case 'about':
        return AboutPage(data: _about(context, actions));
      case 'system_states':
        return _systemStates(context, actions);
      default:
        return null;
    }
  }

  /// The live conditions this device can actually observe.
  ///
  /// Every flag is read from a real source. Blocked, rate-limited and
  /// update-required have no endpoint or version feed yet, so they stay false
  /// rather than being guessed — the page then says "All clear", which is the
  /// truth it can stand behind.
  static Widget _systemStates(BuildContext context, V2SettingsActions actions) {
    // The shell already holds the one live store; reading it through the
    // actions avoids a second `acquire` whose consumer count is never
    // released (which would keep the store, its AppState listener and its
    // lifecycle observer alive after the shell is gone).
    final usage = actions.usage.usage;
    final limited =
        usage != null && usage.hasRemainingPct && usage.remainingPct <= 0;
    return V2SystemStatesPage(
      data: V2SystemStatesData(
        offline: ConnectionService.I.offline,
        allowanceUsed: limited,
        allowanceResetsAt: usage?.resetsAt,
      ),
      onRetryConnection: () => ConnectionService.I.probe(),
      onSeePlans: () => V2SettingsRoutes.open(context, 'plan_billing', actions),
      onBackToChat: () => Navigator.of(context).maybePop(),
    );
  }

  static V2AccountData _account(
    BuildContext context,
    V2SettingsActions actions,
  ) {
    final firebase = FirebaseService.I;
    final app = AppState.I;
    final receipt = firebase.lastDeletionReceipt;
    // OVID_ACCOUNT_ENABLED off means the account service is not deployed: a
    // "Delete account" row could only ever fail. Render no row rather than a
    // control that cannot do what it says. `OVID_ACCOUNT_ENABLED=true` is a
    // release requirement (docs/play/RELEASE-CHECKLIST.md).
    final accountService = firebase.accountService.enabled;
    return V2AccountData(
      profile: V2AccountProfile(
        name: firebase.accountLabel,
        email: firebase.email ?? firebase.accountDetail,
        role: _planName(app.ovidCloudTier),
        initials: initialsFor(firebase.accountLabel),
        photoUrl: firebase.photoUrl,
      ),
      fields: [
        V2AccountField(
          id: 'display_name',
          label: 'Display name',
          value: firebase.displayName ?? firebase.accountLabel,
          editable: true,
        ),
        V2AccountField(
          id: 'email',
          label: 'Email',
          value: firebase.email ?? 'Not added',
          verified: firebase.emailVerified,
        ),
      ],
      connectedAccounts: [
        V2ConnectedAccount(
          id: 'google',
          name: 'Google',
          detail: firebase.email ?? 'Not connected',
          connected: firebase.email != null,
        ),
        V2ConnectedAccount(
          id: 'github',
          name: 'GitHub',
          detail: GitHubService.I.isLoggedIn
              ? (GitHubService.I.login == null
                    ? 'Connected'
                    : '@${GitHubService.I.login}')
              : 'Manage in Credentials',
          connected: GitHubService.I.isLoggedIn,
        ),
      ],
      onEditProfile: () => actions.renameAccount(context),
      // Phone-only accounts have no email to verify, so they get no control.
      onResendEmailVerification: (firebase.email ?? '').contains('@')
          ? () async {
              final error = await firebase.resendEmailVerification();
              if (error == 'too-many-requests') {
                return V2EmailVerificationResult.tooManyRequests;
              }
              if (error == 'network-request-failed') {
                return V2EmailVerificationResult.network;
              }
              if (error != null) return V2EmailVerificationResult.failed;
              // The service re-read the user; report what it actually says.
              return firebase.emailVerified
                  ? V2EmailVerificationResult.verified
                  : V2EmailVerificationResult.sent;
            }
          : null,
      onFieldTap: (field) {
        if (field.id == 'display_name') actions.renameAccount(context);
      },
      onSignOut: () => actions.signOut(context),
      onDeleteAccount: accountService
          ? () => actions.deleteAccount(context)
          : null,
      onLinkAccount: () => open(context, 'credentials', actions),
      onDataControl: () => unawaited(open(context, 'data_control', actions)),
      // The account service refuses a deletion without a fresh identity proof
      // (5 minutes, `AuthIdentity.deletionAuthorized`). The typed confirmation
      // alone is not proof of who is holding the phone, so verify with a
      // linked provider first and report a refusal instead of a silent no-op.
      requestDeletion: accountService
          ? (requestId) async {
              // A legacy password-only account has no linked provider to
              // verify, so the server's proof requirement can never be met.
              // Say what to do instead of failing on a check that cannot pass.
              if (firebase.reauthProviders.isEmpty) {
                throw const AccountException(legacyAuthMigrationHelp);
              }
              if (!await _verifyIdentityForDeletion(context, firebase)) {
                throw const AccountException(
                  'Deletion needs a fresh sign-in check. Verify this account '
                  'and try again.',
                );
              }
              return firebase.requestAccountDeletion(requestId);
            }
          : null,
      restoreDeletion: accountService ? actions.restoreAccount : null,
      deletionPending: receipt?.isPending == true,
      deletionDeadline: receipt?.deleteAfter,
      deviceEraseFailed: () => firebase.deletionDeviceEraseFailed,
    );
  }

  /// Same-account verification before a destructive account action.
  ///
  /// Mirrors the legacy Account screen's proof step: a linked provider is
  /// reauthenticated, which is what makes [FirebaseService
  /// .requestAccountDeletion] accept the request. False on cancel, on a
  /// changed account, or when the account has no linked provider to verify.
  static Future<bool> _verifyIdentityForDeletion(
    BuildContext context,
    FirebaseService fb,
  ) async {
    if (fb.reauthProviders.isEmpty) return false;
    final expectedUid = fb.uid;
    var busy = false;
    final verified = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, update) => PopScope(
          canPop: !busy,
          child: AlertDialog(
            title: const Text('Verify this account'),
            content: SingleChildScrollView(
              child: AuthMethods(
                providers: fb.authProviders,
                intent: AuthIntent.reauthenticate,
                linkedIds: fb.linkedProviderIds,
                phoneNumber: fb.phoneNumber,
                social: (id) =>
                    fb.authenticateSocial(id, AuthIntent.reauthenticate),
                phone: () => fb.createPhoneFlow(AuthIntent.reauthenticate),
                onBusyChanged: (value) => update(() => busy = value),
                onSuccess: () => Navigator.of(dialog).pop(true),
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(dialog).pop(false),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
    return verified == true && fb.uid == expectedUid;
  }

  /// Builds the plan screen from the gateway's plan table.
  ///
  /// `GET /cloud/v1/plans` is the only source of a plan's name, price and
  /// limits. Before this, the screen carried its own copy keyed by the old
  /// `3x` / `7x` / `15x` aliases with a Free default, so a paying Go, Plus or
  /// Pro account was shown "Free, $0, 3 GB". The server's answer also carries
  /// the authoritative limits: a `null` limit is unknown and renders `—`,
  /// never `0`.
  static V2PlanBillingData _plans(
    BuildContext context,
    V2SettingsActions actions, {
    List<CloudPlan>? serverPlans,
    bool plansLoading = false,
    String? plansError,
    VoidCallback? onReloadPlans,
    V2Currency currency = V2Currency.usd,
    V2BillingPeriod period = V2BillingPeriod.monthly,
    ValueChanged<V2Currency>? onCurrencyChanged,
    ValueChanged<V2BillingPeriod>? onPeriodChanged,
  }) {
    final usage = actions.usage.usage;
    final app = AppState.I;
    final play = PlayBillingService.I;
    // Play's catalogue only gates the CTA when Play is the attempted path. A
    // confirmed RevenueCat fallback (or Test Store) may sell products Play does
    // not list, so there the availability is unknown.
    final route = resolveBillingRoute(
      playLoaded: play.loaded,
      playAvailable: play.available,
      revenueCat: RevenueCatBilling.I,
    );
    final playCatalogue =
        route != BillingRoute.revenueCat && route != BillingRoute.demo;

    final plans = <V2Plan>[];
    if (serverPlans != null) {
      // The endpoint answered: its rows are the whole truth, including an
      // empty list (nothing is on sale).
      for (final plan in serverPlans) {
        plans.add(_cardFromServerPlan(plan, play, playCatalogue));
      }
    } else if (usage != null && usage.plans.isNotEmpty) {
      // The older `/usage.plans` shape, for a server that predates `/plans`.
      for (final plan in usage.plans) {
        plans.add(_cardFromUsagePlan(plan, play, playCatalogue));
      }
    } else if (!plansLoading && plansError == null) {
      // Offline seed, used only when no request has answered and none failed.
      for (final plan in OvidPlanCatalog.plans) {
        plans.add(_cardFromUsagePlan(plan, play, playCatalogue));
      }
    }

    // The server's answer is the only source that can confirm the plan
    // (state.dart restores a display-only cache); until it answers, fall back
    // to the cached tier for the badge only. Purchases re-check with
    // `isServerConfirmed` inside [V2SettingsActions.buyPlan].
    final currentTier = confirmedPlanTier ?? app.ovidCloudTier;
    final status = plans.isNotEmpty
        ? V2PlanBillingStatus.ready
        : plansLoading
        ? V2PlanBillingStatus.loading
        : plansError != null
        ? V2PlanBillingStatus.error
        : V2PlanBillingStatus.empty;
    return V2PlanBillingData(
      status: status,
      currency: currency,
      period: period,
      currentPlanId: currentTier,
      plans: plans,
      errorMessage:
          plansError ??
          'We could not load plans. Check your connection and try again.',
      // RevenueCat present but no server route can confirm its charge: every
      // paid card disables its CTA with this real reason. Only once Play has
      // answered, so a page opened during startup cannot stay disabled after
      // Play turns out to be available.
      checkoutBlockedReason:
          route == BillingRoute.none &&
              play.loaded &&
              RevenueCatBilling.I.available
          ? kRevenueCatUnconfirmedReason
          : null,
      demoNote: Distribution.billingDemo
          ? 'Demo: plans unlock without a charge.'
          : null,
      onCurrencyChanged: onCurrencyChanged,
      onPeriodChanged: onPeriodChanged,
      // Every card names its own plan; the old screen hard-coded Plus here,
      // so a Go user's "Upgrade" bought Plus. The period travels with the
      // request so the yearly toggle cannot silently buy the monthly product.
      onPurchase: (purchase) {
        if (purchase.planId == 'free') {
          // Downgrading or cancelling is a Play action, not a purchase.
          unawaited(
            actions.openUrl(context, playSubscriptionCenterUri().toString()),
          );
          return;
        }
        actions.buyPlan(
          context,
          purchase.tier,
          period: ovidPeriodFor(purchase.period),
        );
      },
      onRestorePurchases: () => actions.restorePurchases(context),
      onRetry: () {
        actions.refreshUsage();
        onReloadPlans?.call();
      },
    );
  }

  /// One card from a `GET /plans` row. Every number is the server's; a null
  /// limit stays null so the screen renders `—`.
  static V2Plan _cardFromServerPlan(
    CloudPlan plan,
    PlayBillingService play,
    bool playCatalogue,
  ) {
    final id = plan.canonicalId;
    final spec = _planSpec(id);
    final limits = V2PlanLimits(
      id: id,
      name: plan.name,
      storageGb: plan.storageGb,
      filesPerWindow: plan.uploads?.count,
      fileWindowLabel: _fileWindowLabel(
        plan.uploads?.windowHours ?? plan.windowHours,
      ),
      filesPerProject: plan.projectFiles,
      manualModels: plan.manualModels,
      autoMultiplier: plan.mult,
      customConnectors: plan.customConnectors,
      // The backend has no token counter: allowances are USD. An unreported
      // cap is unknown, not the retired "50M tokens a day" claim.
      dailyTokenCap: null,
      monthlyTokenCap: null,
    );
    return _planCard(
      id: id,
      name: plan.name.isEmpty ? spec.name : plan.name,
      tagline: spec.tagline,
      priceUsd: plan.priceUsd,
      priceInr: plan.priceInr,
      limits: limits,
      play: play,
      playCatalogue: playCatalogue,
    );
  }

  /// One card from the older `/usage.plans` shape. It carries a price but no
  /// limits, so the canonical table supplies those.
  static V2Plan _cardFromUsagePlan(
    OvidPlan plan,
    PlayBillingService play,
    bool playCatalogue,
  ) {
    final id =
        V2PlanLimits.forId(plan.tier)?.id ??
        V2PlanLimits.forId(plan.id)?.id ??
        plan.id;
    final spec = _planSpec(id);
    return _planCard(
      id: id,
      name: plan.name.isEmpty ? spec.name : plan.name,
      tagline: spec.tagline,
      priceUsd: plan.priceUsd,
      // `/usage.plans` has no rupee product price. Null is unknown; the card
      // shows `—` rather than a converted number.
      priceInr: null,
      limits: V2PlanLimits.forId(id),
      play: play,
      playCatalogue: playCatalogue,
    );
  }

  static V2Plan _planCard({
    required String id,
    required String name,
    required String tagline,
    required num? priceUsd,
    required num? priceInr,
    required V2PlanLimits? limits,
    required PlayBillingService play,
    required bool playCatalogue,
  }) {
    // Play and RevenueCat sell the legacy tier ids (`3x` / `7x` / `15x`).
    final storeTier = V2PlanProducts.tierForPlan(id);
    final monthlyProduct = play.productFor(storeTier);
    final yearlyProduct = play.productFor(
      storeTier,
      period: OvidBillingPeriod.yearly,
    );
    return V2Plan(
      id: id,
      name: name,
      tagline: tagline,
      priceUsd: priceUsd?.round() ?? 0,
      priceInr: priceInr?.round() ?? 0,
      // No server table carries a yearly price, so none is derived. Only the
      // store's own price can fill a yearly card.
      priceUsdYearly: 0,
      priceInrYearly: 0,
      // What Google Play actually charges, when the store has answered.
      storePriceMonthly: monthlyProduct?.price,
      storePriceYearly: yearlyProduct?.price,
      storeCurrency:
          monthlyProduct?.currencyCode ?? yearlyProduct?.currencyCode,
      storeMonthlyAvailable: playCatalogue && play.loaded
          ? monthlyProduct != null
          : null,
      storeYearlyAvailable: playCatalogue && play.loaded
          ? yearlyProduct != null
          : null,
      limits: limits,
      autoOnly: limits?.manualModels == false,
      // No feature copy is rendered on the card; the comparison table is the
      // one place limits are stated.
      features: const [],
      popular: id == 'plus',
    );
  }

  /// `24` → `day`, `3` → `3 h`; unknown stays empty.
  static String _fileWindowLabel(int? hours) {
    if (hours == null || hours <= 0) return '';
    return hours == 24 ? 'day' : '$hours h';
  }

  /// Builds the Usage screen from the two real sources:
  ///
  /// * `GET /usage` (`OvidUsage`): the live tier, the account-wide `today`
  ///   counters and the allowance reset instant;
  /// * `GET /usage/history` (`UsageHistoryStore`): the per-day ledger, the
  ///   30-day token total and the per-model split.
  ///
  /// Anything the server did not report is left empty so the page renders an
  /// honest `—`, never a zero that looks like real usage.
  static V2UsageData _usage(
    BuildContext context,
    V2SettingsActions actions,
    UsageHistoryStore history,
  ) {
    final store = actions.usage;
    final usage = store.usage;
    void upgrade() => unawaited(open(context, 'plan_billing', actions));
    if (usage == null) {
      final error = store.error;
      return V2UsageData(
        status: error == null ? V2UsageStatus.loading : V2UsageStatus.error,
        errorMessage: error ?? 'We could not load your usage.',
        onUpgrade: upgrade,
        onRetry: actions.refreshUsage,
      );
    }

    final tier = usage.tier.trim().isEmpty
        ? AppState.I.ovidCloudTier
        : usage.tier;
    final limits = V2PlanLimits.forIdOrFree(tier);
    final dailyCap = limits.dailyTokenCap ?? 0;
    final monthlyCap = limits.monthlyTokenCap ?? 0;
    final today = usage.today;
    final recorded = history.history;

    final bucket = _todayBucket(recorded);
    int? dailyTokens;
    if (today != null) {
      dailyTokens = today.inputTokens + today.outputTokens;
    } else {
      dailyTokens = bucket?.counts.totalTokens;
    }
    final monthlyTokens = recorded?.totals.totalTokens;
    // The counters are today's, like the hero number. `totals.runs` /
    // `totals.modelCalls` cover the whole 30 day window, so only today's
    // bucket may stand in for `/usage`'s `today` counters. `modelCalls` is the
    // ledger's equivalent of a request (one row per model call).
    final requests = today?.requests ?? bucket?.counts.modelCalls;
    final images = today?.images;

    // Both endpoints are still in flight and nothing real is known yet: show
    // the skeleton, not an empty state that claims there is no usage.
    final nothingYet =
        dailyTokens == null &&
        monthlyTokens == null &&
        requests == null &&
        images == null;
    if (history.loading && nothingYet) {
      return V2UsageData(
        status: V2UsageStatus.loading,
        planId: tier,
        onUpgrade: upgrade,
        onRetry: actions.refreshUsage,
      );
    }

    // The progress bar follows the server's real remaining fraction (the USD
    // allowance gate) when it sent one. The token fraction is only a Free-plan
    // fallback; paid plans have no token cap, so an unknown server fraction
    // stays 0 rather than inventing a cap.
    final remaining = usage.remainingFraction;
    final dailyFraction = remaining != null
        ? (1 - remaining).clamp(0.0, 1.0)
        : (dailyTokens == null || dailyCap <= 0
              ? 0.0
              : (dailyTokens / dailyCap).clamp(0.0, 1.0));

    return V2UsageData(
      status: V2UsageStatus.ready,
      planId: tier,
      dailyUsedLabel: dailyTokens == null ? '' : compactTokens(dailyTokens),
      dailyLimitLabel: dailyCap <= 0 ? '' : compactTokens(dailyCap),
      dailyFraction: dailyFraction,
      // The page derives a live countdown from this instant; no static string.
      resetsAt: usage.resetsAt,
      resetsAtLabel: usage.resetsAt == null
          ? ''
          : formatLocalDateTime(usage.resetsAt!),
      monthlyUsedLabel: monthlyTokens == null
          ? ''
          : compactTokens(monthlyTokens),
      monthlyLimitLabel: monthlyCap <= 0 ? '' : compactTokens(monthlyCap),
      days: _usageDays(recorded, history.days),
      range: history.days == 7
          ? V2UsageRange.sevenDays
          : V2UsageRange.thirtyDays,
      historyLoading: history.loading && recorded == null,
      models: _usageModels(usage, recorded),
      requestsLabel: requests == null ? '' : '$requests',
      imagesLabel: images == null ? '' : '$images',
      storageLimitLabel: limits.storageGb == null
          ? ''
          : '${limits.storageGb} GB',
      onRangeChanged: (range) =>
          unawaited(history.setDays(range == V2UsageRange.sevenDays ? 7 : 30)),
      onUpgrade: upgrade,
      onRetry: () {
        actions.refreshUsage();
        unawaited(history.refresh());
      },
    );
  }

  static UsageDay? _todayBucket(UsageHistory? history) {
    if (history == null) return null;
    final now = DateTime.now();
    final key =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    for (final day in history.days) {
      if (day.date == key) return day;
    }
    return null;
  }

  /// Oldest → newest window of real daily buckets, sized to the selected range.
  static List<V2UsageDay> _usageDays(UsageHistory? history, int window) {
    if (history == null || history.days.isEmpty) return const [];
    final sorted = [...history.days]..sort((a, b) => a.date.compareTo(b.date));
    final shown = sorted.length > window
        ? sorted.sublist(sorted.length - window)
        : sorted;
    var peak = 0;
    for (final day in shown) {
      if (day.counts.totalTokens > peak) peak = day.counts.totalTokens;
    }
    return [
      for (final day in shown)
        V2UsageDay(
          id: day.date,
          label: _dayLabel(day.date),
          fraction: peak == 0 ? 0 : day.counts.totalTokens / peak,
          valueLabel: '${compactTokens(day.counts.totalTokens)} tokens',
          tokens: day.counts.totalTokens,
        ),
    ];
  }

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  static String _dayLabel(String date) {
    final parsed = DateTime.tryParse(date);
    if (parsed == null) return date;
    return _weekdays[(parsed.weekday - 1).clamp(0, 6)];
  }

  /// Per-model split from the real counters: today's `by_model` when the
  /// server sends it, else the ledger's model rows.
  static List<V2UsageModel> _usageModels(
    OvidUsage usage,
    UsageHistory? history,
  ) {
    final known = {for (final model in usage.models) model.model: model};
    final byModel = usage.today?.byModel ?? const <String, OvidUsageToday>{};
    var total = 0;
    for (final counts in byModel.values) {
      total += counts.inputTokens + counts.outputTokens;
    }
    if (total > 0) {
      final rows =
          byModel.entries
              .map(
                (entry) => (
                  entry.key,
                  entry.value.inputTokens + entry.value.outputTokens,
                ),
              )
              .where((row) => row.$2 > 0)
              .toList()
            ..sort((a, b) => b.$2.compareTo(a.$2));
      return [
        for (final (id, tokens) in rows)
          V2UsageModel(
            id: id,
            name: known[id]?.label ?? ovidModelLabel(id),
            subtitle: known[id]?.isImage == true ? 'Images' : 'Chat',
            percent: (tokens / total * 100).round().clamp(0, 100),
            tokensLabel: '${compactTokens(tokens)} tokens',
          ),
      ];
    }
    if (history == null || history.models.isEmpty) return const [];
    var ledgerTotal = 0;
    for (final row in history.models) {
      ledgerTotal += row.counts.totalTokens;
    }
    if (ledgerTotal == 0) return const [];
    final rows = [...history.models.where((row) => row.counts.totalTokens > 0)]
      ..sort((a, b) => b.counts.totalTokens.compareTo(a.counts.totalTokens));
    return [
      for (final row in rows)
        V2UsageModel(
          id: row.model,
          name: known[row.model]?.label ?? ovidModelLabel(row.model),
          subtitle: known[row.model]?.isImage == true ? 'Images' : 'Chat',
          percent: (row.counts.totalTokens / ledgerTotal * 100).round().clamp(
            0,
            100,
          ),
          tokensLabel: '${compactTokens(row.counts.totalTokens)} tokens',
        ),
    ];
  }

  static V2MemoryPageData _memory(
    BuildContext context,
    V2SettingsActions actions, {
    List<V2MemoryEntry> globalEntries = const [],
    List<V2MemoryFile> files = const [],
    bool loading = false,
    String? errorMessage,
    V2MemoryForget? onForgetMemory,
    V2MemoryEdit? onEditMemory,
    V2MemoryAdd? onAddMemory,
    VoidCallback? onRetry,
  }) {
    final app = AppState.I;
    return V2MemoryPageData(
      memoryEnabled: app.memoryEnabled,
      shareSessionMemory: app.effectiveShareSessionMemory,
      globalEntries: globalEntries,
      globalVersionLabel: '',
      // Project memory files are the server's per-project count; the memory
      // page only lists projects that actually keep memory.
      projects: [
        for (final project in ProjectsController.I.projects)
          if (project.fileBreakdown.memory > 0)
            V2MemoryProject(
              id: project.id,
              name: project.name,
              detail: project.fileBreakdown.memory == 1
                  ? '1 file'
                  : '${project.fileBreakdown.memory} files',
            ),
      ],
      sessionFiles: files,
      loading: loading,
      errorMessage: errorMessage,
      onMemoryEnabledChanged: actions.setMemoryEnabled,
      onShareSessionMemoryChanged: actions.setShareSessionMemory,
      onEditGlobal: () => open(context, 'memory_files', actions),
      onProjectTap: (_) => open(context, 'memory_files', actions),
      // One Forget per row: the source deletes the fact line, the chat file or
      // the project's memory files for real.
      onForgetMemory: onForgetMemory,
      onEditMemory: onEditMemory,
      onAddMemory: onAddMemory,
      onResetAll: () => actions.resetMemory(context),
      onRetry: onRetry,
    );
  }

  static V2AppearancePageData _appearance(
    BuildContext context,
    V2SettingsActions actions,
  ) {
    final app = AppState.I;
    return V2AppearancePageData(
      themeMode: themeModeOf(app.themeMode),
      textScale: app.chatFontScale,
      voiceLanguageId: app.voiceLanguage,
      memoryEnabled: app.memoryEnabled,
      shareSessionMemory: app.effectiveShareSessionMemory,
      showReasoning: app.showReasoning,
      onThemeModeChanged: (mode) => actions.setThemeMode(mode),
      onTextScaleChanged: actions.setTextScale,
      onVoiceLanguageChanged: app.setVoiceLanguage,
      onMemoryEnabledChanged: actions.setMemoryEnabled,
      onShareSessionMemoryChanged: actions.setShareSessionMemory,
      onShowReasoningChanged: (value) =>
          unawaited(AppState.I.setShowReasoning(value)),
      onMemoryFilesTap: () => open(context, 'memory_files', actions),
    );
  }

  static V2DataControlPageData _dataControl(
    BuildContext context,
    V2SettingsActions actions, {
    int totalBytes = 0,
    List<V2ExportSession> exportSessions = const [],
    V2ExportSessionToggle? onExportSessionToggled,
  }) {
    final spec = _planSpec(AppState.I.ovidCloudTier);
    final storageGb = spec.storageGb;
    final quotaBytes = storageGb == null ? 0 : storageGb * 1024 * 1024 * 1024;
    final firebase = FirebaseService.I;
    // The gateway compares the typed value with the account's registered
    // EMAIL. It stores no phone, so a phone is never offered as a
    // confirmation target here.
    final contact = (firebase.email ?? '').trim();
    // A null id set means "every chat"; the picker's ticks narrow it. Only
    // filter when something was actually unticked, so an unsynced local id
    // can never silently drop the rest of the account's chats.
    void export() {
      final narrowed = exportSessions.any((session) => !session.selected);
      final selected = !narrowed
          ? null
          : {
              for (final session in exportSessions)
                if (session.selected) session.id,
            };
      actions.exportData(context, sessionIds: selected);
    }

    return V2DataControlPageData(
      totalDataSizeLabel: totalBytes > 0 ? _bytes(totalBytes) : '',
      exportSessions: exportSessions,
      crashReports: FirebaseService.I.consentGiven,
      hasData: AppState.I.sessions.isNotEmpty,
      accountContact: contact,
      storageUsedLabel: storageGb == null
          ? ''
          : '${_bytes(totalBytes)} of $storageGb GB',
      storageFraction: quotaBytes <= 0
          ? 0
          : (totalBytes / quotaBytes).clamp(0.0, 1.0),
      storageFreeLabel: quotaBytes <= 0
          ? ''
          : _bytes((quotaBytes - totalBytes).clamp(0, quotaBytes)),
      onExportImport: export,
      onExport: export,
      onExportSessionToggled: onExportSessionToggled,
      onChooseImport: () => actions.importData(context),
      onPermissions: () => open(context, 'permissions', actions),
      onCrashReportsChanged: (value) =>
          unawaited(actions.setCrashReports(value)),
      onStorage: () => open(context, 'storage', actions),
      // The destructive row calls the gateway directly; a refused or dropped
      // call is a typed failure the page renders as one sentence. The reset
      // row in the hub keeps its own action for the same route.
      onServerDeleteAll: actions.deleteAllCloudData,
      // The legacy hook is the DEVICE reset, not the cloud delete: a host
      // that renders this page without the server seam keeps the old,
      // honestly-labelled behaviour.
      onDeleteData: () => actions.deleteDeviceData(context),
      onResetMemory: () => actions.resetMemory(context),
    );
  }

  /// The export picker's rows, measured from this device's transcripts.
  ///
  /// Ids are the server session ids the archive will actually carry, so a tick
  /// survives the round trip to [V2SettingsActions.exportData].
  static List<V2ExportSession> exportSessionsFor(
    Iterable<ChatSession> sessions,
    Map<String, bool> selected,
  ) {
    final ordered = [...sessions]
      ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    return [
      for (final session in ordered)
        if (session.messages.isNotEmpty)
          V2ExportSession(
            id: CloudSessionStore.I.resolveServerSessionId(session.id),
            name: session.title,
            sizeBytes: _sessionBytes(session),
            sizeLabel: _bytes(_sessionBytes(session)),
            detail:
                '${session.messages.length} '
                '${session.messages.length == 1 ? 'message' : 'messages'}',
            selected:
                selected[CloudSessionStore.I.resolveServerSessionId(
                  session.id,
                )] ??
                true,
          ),
    ];
  }

  static V2StoragePageData _storage(
    BuildContext context,
    V2SettingsActions actions, {
    int artifactsBytes = 0,
    int sessionsBytes = 0,
    int cacheBytes = 0,
    bool loading = false,
    String? errorMessage,
    Future<int> Function()? onClearCacheAndReport,
    VoidCallback? onRetry,
  }) {
    final spec = _planSpec(AppState.I.ovidCloudTier);
    final storageGb = spec.storageGb;
    // Cache lives on the device, so it is shown but never counted against the
    // account's cloud quota.
    final used = artifactsBytes + sessionsBytes;
    double gb(int bytes) => bytes / (1024 * 1024 * 1024);
    return V2StoragePageData(
      usedGb: gb(used),
      totalGb: storageGb?.toDouble() ?? 0,
      planName: _planName(AppState.I.ovidCloudTier),
      quotaLabel: storageGb == null ? '' : '$storageGb GB included',
      slices: [
        if (artifactsBytes > 0)
          V2StorageSlice(
            label: 'Artifacts',
            valueGb: gb(artifactsBytes),
            sizeLabel: _bytes(artifactsBytes),
          ),
        if (sessionsBytes > 0)
          V2StorageSlice(
            label: 'Chats',
            valueGb: gb(sessionsBytes),
            sizeLabel: _bytes(sessionsBytes),
          ),
        if (cacheBytes > 0)
          V2StorageSlice(
            label: 'Cache',
            valueGb: gb(cacheBytes),
            sizeLabel: _bytes(cacheBytes),
          ),
      ],
      artifactsGb: gb(artifactsBytes),
      artifactsSizeLabel: _bytes(artifactsBytes),
      sessionsGb: gb(sessionsBytes),
      sessionsSizeLabel: _bytes(sessionsBytes),
      cacheGb: gb(cacheBytes),
      cacheSizeLabel: _bytes(cacheBytes),
      loading: loading,
      errorMessage: errorMessage,
      onClearCacheAndReport: onClearCacheAndReport,
      onDeleteOldChats: () => actions.deleteOldChats(context),
      onRetry: onRetry,
      onGoUpgrade: () => open(context, 'plan_billing', actions),
    );
  }

  /// UTF-8 size of the on-device transcript, including attachment metadata.
  static int _localTranscriptBytes() {
    var total = 0;
    for (final session in AppState.I.sessions) {
      total += _sessionBytes(session);
    }
    return total;
  }

  /// UTF-8 size of one chat's transcript, including attachment metadata.
  static int _sessionBytes(ChatSession session) {
    var total = 0;
    for (final message in session.messages) {
      total += utf8.encode(message.content).length;
      final detail = message.toolDetail;
      if (detail != null) total += utf8.encode(detail).length;
      for (final attachment in message.attachments) {
        total += attachment.size;
      }
    }
    return total;
  }

  static String _bytes(int value) {
    if (value <= 0) return '0 MB';
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    if (value < 1024 * 1024 * 1024) {
      return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static V2CredentialsPageData _credentials(
    BuildContext context,
    V2SettingsActions actions, {
    List<V2BrowserCredential> browserCredentials = const [],
    ValueChanged<V2BrowserCredential>? onAddBrowserCredential,
    ValueChanged<V2BrowserCredential>? onEditBrowserCredential,
    ValueChanged<V2BrowserCredential>? onDeleteBrowserCredential,
    VoidCallback? onRevokeAll,
  }) {
    final firebase = FirebaseService.I;
    final github = GitHubService.I;
    return V2CredentialsPageData(
      google: V2Credential(
        id: 'google',
        kind: V2CredentialKind.google,
        title: 'Google',
        subtitle: firebase.email ?? 'Not connected',
        connected: firebase.email != null,
      ),
      github: V2Credential(
        id: 'github',
        kind: V2CredentialKind.github,
        title: 'GitHub',
        subtitle: github.isLoggedIn
            ? (github.login == null ? 'Connected' : '@${github.login}')
            : 'Connect for Studio clone and push',
        connected: github.isLoggedIn,
      ),
      token: const V2Credential(
        id: 'token',
        kind: V2CredentialKind.token,
        title: 'Access token',
        subtitle: 'Token for custom providers',
        connected: false,
      ),
      browserCredentials: browserCredentials,
      githubOAuthConnected: github.isLoggedIn,
      cloudKeyStatusLabel: 'Managed by Ovid',
      cloudKeyStatusDetail:
          'Your cloud key stays on the server and is never shown on this device.',
      cloudKeyActive: true,
      // The page stores personal keys and GitHub PATs in the platform secure
      // store itself when no host saver is injected.
      onConnectGithubOAuth: () => showGithubLoginSheet(context),
      onDisconnectGithubOAuth: () => unawaited(github.signOut()),
      onAddBrowserCredential: onAddBrowserCredential,
      onEditBrowserCredential: onEditBrowserCredential,
      onDeleteBrowserCredential: onDeleteBrowserCredential,
      // Revoke removes the saved credentials; it must never sign the account
      // out. The page already removed its own secrets and browser logins.
      onRevokeAll: onRevokeAll,
    );
  }

  /// Maps the gateway's `/account/health` answer onto the screen's four
  /// facts. A null section (or a null field inside one) stays unknown and
  /// renders the page's dash; it is never coerced to zero. The status is
  /// passed separately so loading, empty and error do not need fake data.
  static health.V2AccountHealthPageData _health(
    BuildContext context,
    V2SettingsActions actions, {
    AccountHealth? accountHealth,
    health.V2AccountHealthStatus status = health.V2AccountHealthStatus.ready,
    String? errorMessage,
    VoidCallback? onCancelDeletion,
    VoidCallback? onRetry,
  }) {
    final plan = accountHealth?.plan;
    final storage = accountHealth?.storage;
    final usage = accountHealth?.usage;
    final standing = accountHealth?.standing;
    final deletion = standing?.deletion;

    final planId = plan?.id ?? plan?.tier;
    final limits = planId == null ? null : V2PlanLimits.forId(planId);
    // Only a plan the table knows gets a display name. An unknown tier must
    // not fall back to "Free" and claim a plan the server did not name.
    // `_planName` resolves canonical ids (`go` / `plus` / `pro`) as well as the
    // legacy aliases, so a paying account is not labelled Free.
    final planName = limits == null
        ? (plan?.name ?? '')
        : _barePlanName(planId!);

    final todayTokens = usage?.today?.usedTokens;
    // The gateway's own token arithmetic (it clamps the remainder at 0). An
    // older gateway sends none of these, so they stay null and the rows are
    // simply not drawn.
    final tokensUsed = usage?.today?.tokensUsed;
    final tokenCap = usage?.today?.tokenCap;
    final tokensRemaining = usage?.today?.tokensRemaining;
    final usedBytes = storage?.usedBytes;
    final quotaBytes = storage?.quotaBytes;

    final banned = standing?.banned;
    final pending = deletion?.pending;
    final health.V2AccountStatus? accountStatus;
    if (banned == true) {
      accountStatus = health.V2AccountStatus.banned;
    } else if (pending == true) {
      // A pending deletion is a fact even when the ban flag is unreadable;
      // surfacing it is more honest than a generic "Status unknown".
      accountStatus = health.V2AccountStatus.deletionPending;
    } else if (banned == null) {
      accountStatus = null;
    } else if (deletion == null) {
      accountStatus = health.V2AccountStatus.active;
    } else if (pending == null) {
      accountStatus = null;
    } else {
      accountStatus = health.V2AccountStatus.active;
    }

    final deadline = deletion?.deleteAfter;
    return health.V2AccountHealthPageData(
      status: status,
      planLabel: planName,
      accountStatus: accountStatus,
      todayUsageLabel: todayTokens == null
          ? ''
          : '${compactTokens(todayTokens)} tokens',
      todayUsageFraction:
          todayTokens == null ||
              limits == null ||
              (limits.dailyTokenCap ?? 0) <= 0
          ? null
          : (todayTokens / limits.dailyTokenCap!).clamp(0.0, 1.0).toDouble(),
      tokensUsedLabel: tokensUsed == null ? '' : compactTokens(tokensUsed),
      tokenCapLabel: tokenCap == null ? '' : compactTokens(tokenCap),
      tokensRemainingLabel: tokensRemaining == null
          ? ''
          : compactTokens(tokensRemaining),
      storageUsedLabel: usedBytes == null || quotaBytes == null
          ? ''
          : '${_bytes(usedBytes)} of ${_bytes(quotaBytes)}',
      storageFraction:
          usedBytes == null || quotaBytes == null || quotaBytes <= 0
          ? null
          : (usedBytes / quotaBytes).clamp(0.0, 1.0).toDouble(),
      deletionScheduledLabel: pending == true && deadline != null
          ? formatLocalDateTime(deadline)
          : '',
      deletionKnown: standing != null,
      errorMessage: errorMessage,
      onRetry: onRetry,
      // The plan list and the storage screen are real routes; each row opens
      // the screen that owns the number it shows.
      onOpenPlans: () => unawaited(open(context, 'plan_billing', actions)),
      onOpenStorage: () => unawaited(open(context, 'storage', actions)),
      onCancelDeletion: onCancelDeletion,
    );
  }

  static V2NotificationsPageData _notifications(
    BuildContext context,
    V2SettingsActions actions, {
    required bool notificationsBlocked,
    required VoidCallback onOpenSystem,
    V2NotificationsStatus status = V2NotificationsStatus.ready,
    bool serviceAvailable = true,
    bool saving = false,
    bool masterEnabled = false,
    ValueChanged<bool>? onMasterChanged,
    void Function(String id, bool value)? onToggle,
    VoidCallback? onRetry,
  }) {
    final settings = BackgroundNotifier.I.settings;
    final master = masterEnabled;
    final start = settings.quietHoursStartMinutes;
    final end = settings.quietHoursEndMinutes;
    String hhmm(int minutes) {
      final h = (minutes ~/ 60).toString().padLeft(2, '0');
      final m = (minutes % 60).toString().padLeft(2, '0');
      return '$h:$m';
    }

    return V2NotificationsPageData(
      status: status,
      serviceAvailable: serviceAvailable,
      saving: saving,
      notificationsBlocked: notificationsBlocked,
      masterEnabled: master,
      activity: [
        V2NotificationSetting(
          id: OvidChannel.agentUpdates.key,
          title: 'Run finished',
          description: 'When Ovid completes a task.',
          value: master && (settings.enabled[OvidChannel.agentUpdates] ?? true),
        ),
        V2NotificationSetting(
          id: OvidChannel.schedulerResults.key,
          title: 'Schedule results',
          description: 'When a scheduled run finishes.',
          value:
              master &&
              (settings.enabled[OvidChannel.schedulerResults] ?? true),
        ),
        const V2NotificationSetting(
          id: 'shares_invites',
          title: 'Shares and invites',
          description: 'When someone shares a chat or invites you.',
          value: false,
          available: false,
        ),
        const V2NotificationSetting(
          id: 'collaboration',
          title: 'Collaboration',
          description: 'New messages in shared chats.',
          value: false,
          available: false,
        ),
      ],
      security: const [
        V2NotificationSetting(
          id: 'new_signins',
          title: 'New sign-ins',
          description: 'When a new device signs in.',
          value: false,
          available: false,
        ),
        V2NotificationSetting(
          id: 'billing',
          title: 'Billing',
          description: 'Receipts and renewal reminders.',
          value: false,
          available: false,
        ),
      ],
      sound: settings.sounds.values.any(
        (sound) => sound != NotificationSound.silent,
      ),
      quietHoursEnabled: settings.quietHoursEnabled,
      quietHoursLabel: '${hhmm(start)}–${hhmm(end)}',
      quietHoursStart: TimeOfDay(hour: start ~/ 60, minute: start % 60),
      quietHoursEnd: TimeOfDay(hour: end ~/ 60, minute: end % 60),
      sounds: [
        for (final channel in OvidChannel.values)
          if (channel.soundConfigurable)
            V2ChannelSoundSetting(
              id: channel.key,
              title: channel == OvidChannel.agentUpdates
                  ? 'Agent updates'
                  : 'Scheduled results',
              description: channel == OvidChannel.agentUpdates
                  ? 'Runs that finish, need input or approval.'
                  : 'Scheduled runs that finish or fail.',
              value: switch (settings.sounds[channel]!) {
                NotificationSound.chime => V2NotificationSound.chime,
                NotificationSound.system => V2NotificationSound.system,
                NotificationSound.silent => V2NotificationSound.silent,
              },
            ),
      ],
      onToggle:
          onToggle ?? (id, value) => actions.setNotificationChannel(id, value),
      onMasterChanged:
          onMasterChanged ??
          (value) => unawaited(actions.setNotificationsMaster(context, value)),
      onQuietHours: () =>
          actions.setQuietHours(enabled: !settings.quietHoursEnabled),
      onQuietHoursEnabledChanged: (value) =>
          actions.setQuietHours(enabled: value),
      onQuietHoursStartChanged: (value) => actions.setQuietHours(
        enabled: settings.quietHoursEnabled,
        start: value,
      ),
      onQuietHoursEndChanged: (value) => actions.setQuietHours(
        enabled: settings.quietHoursEnabled,
        end: value,
      ),
      onSoundChanged: (id, value) => actions.setChannelSound(id, value),
      onOpenSystem: onOpenSystem,
      onRetry: onRetry,
    );
  }

  static V2AgentPresetsPageData _presets() {
    return V2AgentPresetsPageData(
      presets: [
        for (final preset in PresetRegistry.all)
          V2AgentPreset(
            id: preset.id,
            name: preset.label,
            description: preset.description,
            modelLabel: preset.model ?? 'Auto',
            modelId: preset.model,
            builtIn: PresetRegistry.isBuiltInId(preset.id),
            icon: PresetRegistry.isBuiltInId(preset.id)
                ? Icons.auto_awesome_rounded
                : Icons.tune_rounded,
            responseWaitSeconds: preset.responseWaitSeconds,
            permissionModeId: preset.permissionMode,
          ),
      ],
      selectedId: AppState.I.activeSession?.presetId,
      models: _presetModels(),
      defaultResponseWaitSeconds: AppState.I.responseTimeoutSec,
      onApply: (id) async {
        final result = await CommandService.I.execute('/preset $id');
        final feedback = result?.feedback ?? '';
        if (feedback.startsWith('Unknown preset') ||
            feedback.startsWith('No active session')) {
          throw StateError(feedback);
        }
      },
      onCreatePreset: (draft) async {
        final preset = AgentPreset(
          id: PresetRegistry.newCustomId(),
          label: draft.name.trim(),
          description: draft.description.trim(),
          model: draft.modelId.trim().isEmpty ? null : draft.modelId.trim(),
          responseWaitSeconds: draft.responseWaitSeconds,
          permissionMode: draft.permissionModeId,
        );
        await AppState.I.saveCustomPreset(preset);
      },
      onUpdatePreset: (id, draft) async {
        final existing = PresetRegistry.all
            .where((preset) => preset.id == id)
            .firstOrNull;
        if (existing == null) {
          throw StateError('That preset no longer exists.');
        }
        if (PresetRegistry.isBuiltInId(id)) {
          throw StateError('Built-in presets cannot be edited.');
        }
        await AppState.I.saveCustomPreset(
          existing.copyWith(
            label: draft.name.trim(),
            description: draft.description.trim(),
            model: draft.modelId.trim().isEmpty ? null : draft.modelId.trim(),
            responseWaitSeconds: draft.responseWaitSeconds,
            permissionMode: draft.permissionModeId,
          ),
        );
      },
      onDeletePreset: (id) => AppState.I.deleteCustomPreset(id),
    );
  }

  /// Test seam: the production wiring of the preset screen's hooks.
  @visibleForTesting
  static V2AgentPresetsPageData presetsPageForTest() => _presets();

  /// The models a preset can pin: Auto first, then every model a configured
  /// provider lists. The editor's picker is only as real as this list.
  static List<V2PresetModelOption> _presetModels() {
    final options = <String, V2PresetModelOption>{
      'auto': const V2PresetModelOption(id: 'auto', label: 'Auto'),
    };
    for (final provider in AppState.I.providers) {
      for (final model in provider.models) {
        final id = model.trim();
        if (id.isEmpty) continue;
        options.putIfAbsent(
          id,
          () => V2PresetModelOption(id: id, label: ovidModelLabel(id)),
        );
      }
    }
    return options.values.toList(growable: false);
  }

  static V2ResponseWaitPageData _responseWait(
    BuildContext context,
    V2SettingsActions actions,
  ) {
    // The persisted value the watchdog actually reads; AppState loads it from
    // prefs at boot, so this is never a synthetic default.
    final seconds = AppState.I.responseTimeoutSec;
    return V2ResponseWaitPageData(
      seconds: seconds,
      onChanged: actions.setResponseWait,
    );
  }

  /// Maps the OS answer onto the page's four-state model.
  static V2PermissionAccess _permissionAccess(PermissionStatus status) {
    if (status.isGranted || status.isLimited || status.isProvisional) {
      return V2PermissionAccess.granted;
    }
    if (status.isPermanentlyDenied || status.isRestricted) {
      return V2PermissionAccess.permanentlyDenied;
    }
    if (status.isDenied) return V2PermissionAccess.denied;
    return V2PermissionAccess.notAsked;
  }

  /// Test seam: the loader's own row list is what proves only the permissions
  /// this build's manifest declares are listed.
  @visibleForTesting
  static List<V2PermissionItem> permissionItemsForTest(
    Map<String, PermissionStatus> statuses,
  ) => _permissionItems(statuses);

  /// Test seam for the OS answer → four-state mapping.
  @visibleForTesting
  static V2PermissionAccess permissionAccessForTest(PermissionStatus status) =>
      _permissionAccess(status);

  /// The two permissions this build's manifest declares: microphone for voice
  /// input and notifications for run results. Camera, photos and storage are
  /// never requested, so listing them would send the user to an OS page with
  /// no entry for Ovid.
  static List<V2PermissionItem> _permissionItems(
    Map<String, PermissionStatus> statuses,
  ) {
    const ids = <String>['microphone', 'notifications'];
    const meta = <String, ({String name, String reason, IconData icon})>{
      'microphone': (
        name: 'Microphone',
        reason: 'Voice input in Hindi, Hinglish, Punjabi and Tamil.',
        icon: Icons.mic_none_rounded,
      ),
      'notifications': (
        name: 'Notifications',
        reason: 'Tell you when a long run finishes.',
        icon: Icons.notifications_outlined,
      ),
    };
    return [
      for (final id in ids)
        V2PermissionItem(
          id: id,
          name: meta[id]!.name,
          reason: meta[id]!.reason,
          status: _permissionAccess(statuses[id] ?? PermissionStatus.denied),
          icon: meta[id]!.icon,
        ),
    ];
  }

  static V2AboutPageData _about(
    BuildContext context,
    V2SettingsActions actions,
  ) {
    return V2AboutPageData(
      // The build's real version/build, never a demo string.
      version: kAppVersion,
      build: kAppBuildNumber,
      onCopyVersion: () => actions.copyVersion(context),
      onPrivacyPolicy: () => actions.openUrl(context, LegalLinks.privacyPolicy),
      onTerms: () => actions.openUrl(context, LegalLinks.terms),
      onContactSupport: () =>
          actions.openUrl(context, 'mailto:${LegalLinks.supportEmail}'),
      onDeleteAccount: () => actions.deleteAccount(context),
    );
  }

  /// The account's plan name for a settings row, resolved by canonical id.
  ///
  /// `ovidPlanName` cannot be used on its own: its offline table is keyed by
  /// the old aliases, so `ovidPlanName('go')` falls through to Free. Resolving
  /// the id first (and refusing to name an unknown plan Free) keeps a paying
  /// Go/Plus/Pro account from being labelled Free.
  static String _planName(String tier) =>
      canonicalPlanId(tier) == 'free' ? 'Free plan' : _barePlanName(tier);

  /// The bare plan name (`Free`, `Go`, `Plus`, `Pro`) for a tier.
  static String _barePlanName(String tier) {
    final canonical = canonicalPlanId(tier);
    final spec = _planSpec(canonical);
    if (spec.name == 'Unknown') return 'Unknown';
    final live =
        OvidPlanCatalog.plans
            .where((plan) => V2PlanLimits.forId(plan.tier)?.id == canonical)
            .firstOrNull ??
        OvidPlanCatalog.plans
            .where((plan) => V2PlanLimits.forId(plan.id)?.id == canonical)
            .firstOrNull;
    final name = live?.name ?? spec.name;
    return Distribution.billingDemo ? '$name (demo)' : name;
  }

  /// The display copy for a plan, resolved by canonical id.
  ///
  /// The server stores canonical ids (`go` / `plus` / `pro`), but existing
  /// `users.tier` rows still hold the aliases the mint wrote (`3x` / `7x` /
  /// `15x`) and older seeds (`starter` / `max`). Both spellings resolve here
  /// through the same mapping the server uses, so a stale stored tier still
  /// renders the right plan instead of falling into Free.
  ///
  /// Prices and limits are deliberately absent: they come from the server's
  /// plan table, never from a local copy.
  static V2PlanSpec _planSpec(String tier) {
    return switch (canonicalPlanId(tier)) {
      'free' => const V2PlanSpec(
        name: 'Free',
        tagline: 'Start building',
        storageGb: 3,
      ),
      'go' => const V2PlanSpec(
        name: 'Go',
        tagline: 'For everyday work',
        storageGb: 5,
      ),
      'plus' => const V2PlanSpec(
        name: 'Plus',
        tagline: 'For serious builders',
        storageGb: 15,
      ),
      'pro' => const V2PlanSpec(
        name: 'Pro',
        tagline: 'For teams and heavy use',
        storageGb: 75,
      ),
      // Unknown is its own answer. Calling it Free would describe a plan the
      // server never named.
      _ => const V2PlanSpec(name: 'Unknown', tagline: '', storageGb: null),
    };
  }

  /// Test seam: id resolution for the plan screen.
  @visibleForTesting
  static V2PlanSpec planSpecForTest(String tier) => _planSpec(tier);
}

/// One fact parsed out of a shared memory file.
///
/// Memory is stored as Markdown files (`MEMORY.md` plus notes), so a fact is a
/// non-empty line with its bullet/heading markers removed. The line index keeps
/// the id stable long enough to delete exactly that line.
@immutable
class V2MemoryFact {
  const V2MemoryFact({
    required this.id,
    required this.text,
    required this.fileName,
    required this.line,
  });

  final String id;
  final String text;
  final String fileName;
  final int line;
}

/// Parses the facts in one memory file. Headings and code fences are not facts.
List<V2MemoryFact> memoryFactsFrom(String fileName, String content) {
  final facts = <V2MemoryFact>[];
  final lines = content.split('\n');
  var inFence = false;
  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trim();
    if (trimmed.startsWith('```')) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('#')) continue;
    final text = trimmed
        .replaceFirst(RegExp(r'^(?:[-*+]|\d+[.)])\s+'), '')
        .trim();
    if (text.isEmpty) continue;
    facts.add(
      V2MemoryFact(id: '$fileName#$i', text: text, fileName: fileName, line: i),
    );
  }
  return facts;
}

/// Removes [fact]'s line from [content], or null when the file no longer holds
/// that exact fact (the caller then asks the person to refresh).
String? removeMemoryFact(String content, V2MemoryFact fact) {
  final lines = content.split('\n');
  if (fact.line < 0 || fact.line >= lines.length) return null;
  final current = memoryFactsFrom(
    fact.fileName,
    content,
  ).where((entry) => entry.line == fact.line).firstOrNull;
  if (current == null || current.text != fact.text) return null;
  lines.removeAt(fact.line);
  return lines.join('\n');
}

/// What the memory API returned for one chat.
@immutable
class V2MemorySnapshot {
  const V2MemorySnapshot({
    required this.shared,
    required this.files,
    this.facts = const [],
  });

  /// True when the account's "Share memory" preference opened the shared
  /// scope, so [facts] are the cross-chat facts.
  final bool shared;
  final List<MemoryFileSummary> files;
  final List<V2MemoryFact> facts;
}

/// The real memory source: `GET /memory`, `GET/PUT/DELETE /memory/:name` and
/// the project memory routes.
///
/// Memory is isolated per chat by default. With sharing on the server returns
/// the shared scope instead, and the facts inside those files are the global
/// ones the Memory screen lists.
class V2MemorySource {
  V2MemorySource({AccountSettingsClient? client})
    : _client = client ?? AccountSettingsClient.I;

  final AccountSettingsClient _client;

  Future<V2MemorySnapshot> load(String sessionId) async {
    final listing = await _client.memoryFiles(sessionId);
    if (!listing.shared) {
      return V2MemorySnapshot(shared: false, files: listing.files);
    }
    final facts = <V2MemoryFact>[];
    for (final file in listing.files) {
      final doc = await _client.readMemory(sessionId, file.name);
      facts.addAll(memoryFactsFrom(file.name, doc.content));
    }
    return V2MemorySnapshot(shared: true, files: listing.files, facts: facts);
  }

  /// Deletes one row for real. Global rows rewrite the fact out of its file,
  /// session rows delete the file and project rows empty that project's memory.
  Future<void> forget({
    required String sessionId,
    required V2MemoryScope scope,
    required String id,
    required V2MemorySnapshot snapshot,
  }) async {
    switch (scope) {
      case V2MemoryScope.global:
        final fact = snapshot.facts
            .where((entry) => entry.id == id)
            .firstOrNull;
        if (fact == null) {
          throw StateError('That memory is no longer in the list.');
        }
        final doc = await _client.readMemory(sessionId, fact.fileName);
        final next = removeMemoryFact(doc.content, fact);
        if (next == null) {
          throw StateError('That memory changed. Refresh and try again.');
        }
        if (next.trim().isEmpty) {
          await _client.deleteMemory(sessionId, fact.fileName);
        } else {
          await _client.writeMemory(
            sessionId,
            fact.fileName,
            next,
            ifRevision: doc.revision,
          );
        }
      case V2MemoryScope.session:
        await _client.deleteMemory(sessionId, id);
      case V2MemoryScope.project:
        await _forgetProject(id);
      case V2MemoryScope.all:
        break;
    }
  }

  /// Removes every file in the shared scope (the screen already confirmed).
  Future<void> forgetAllShared(String sessionId) async {
    final listing = await _client.memoryFiles(sessionId);
    for (final file in listing.files) {
      await _client.deleteMemory(sessionId, file.name);
    }
  }

  /// Rewrites one global fact in place, preserving its bullet/indent marker.
  ///
  /// Returns the text the service stored, or null when the file changed, the
  /// fact disappeared or the write failed; the screen then keeps the old text.
  Future<String?> editFact({
    required String sessionId,
    required V2MemoryScope scope,
    required String id,
    required String text,
  }) async {
    if (scope != V2MemoryScope.global) return null;
    final next = text.trim();
    if (next.isEmpty) return null;
    final split = id.lastIndexOf('#');
    if (split <= 0) return null;
    final fileName = id.substring(0, split);
    final line = int.tryParse(id.substring(split + 1));
    if (line == null || line < 0) return null;
    try {
      final doc = await _client.readMemory(sessionId, fileName);
      final lines = doc.content.split('\n');
      if (line >= lines.length) return null;
      final current = memoryFactsFrom(
        fileName,
        doc.content,
      ).where((fact) => fact.line == line).firstOrNull;
      if (current == null) return null;
      final prefix = RegExp(
        r'^(\s*(?:[-*+]|\d+[.)])\s+)?',
      ).firstMatch(lines[line])?.group(1);
      lines[line] = '${prefix ?? ''}$next';
      await _client.writeMemory(
        sessionId,
        fileName,
        lines.join('\n'),
        ifRevision: doc.revision,
      );
      return next;
    } catch (_) {
      return null;
    }
  }

  /// Appends one global fact to the shared `MEMORY.md`.
  ///
  /// Returns the stored entry (with its real line id), or null when the write
  /// failed. The screen never invents a row for an unconfirmed write.
  Future<V2MemoryEntry?> addFact({
    required String sessionId,
    required String text,
  }) async {
    final next = text.trim();
    if (next.isEmpty) return null;
    const fileName = 'MEMORY.md';
    try {
      final listing = await _client.memoryFiles(sessionId);
      final exists = listing.files.any((file) => file.name == fileName);
      final doc = exists
          ? await _client.readMemory(sessionId, fileName)
          : const MemoryFile(name: fileName, content: '', revision: '');
      final base = doc.content;
      final separator = base.isEmpty || base.endsWith('\n') ? '' : '\n';
      final content = '$base$separator- $next\n';
      final stored = await _client.writeMemory(
        sessionId,
        fileName,
        content,
        ifRevision: exists ? doc.revision : null,
      );
      // The server may normalise the body; locate the line it actually stored.
      final facts = memoryFactsFrom(fileName, stored.content);
      for (final fact in facts.reversed) {
        if (fact.text == next) {
          return V2MemoryEntry(id: fact.id, text: fact.text);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _forgetProject(String projectId) async {
    final rest = CloudRestClient.I;
    final project = Uri.encodeComponent(projectId);
    final json = await rest.getJson('/projects/$project/memory');
    final items = json['items'];
    if (items is! List) return;
    for (final item in items) {
      if (item is! Map || item['name'] is! String) continue;
      final name = Uri.encodeComponent(item['name'] as String);
      await rest.delete('/projects/$project/memory/$name');
    }
    // The sidebar's per-project memory count is server-derived; refresh it so
    // the row does not keep claiming files that are gone.
    await ProjectsController.I.refresh();
  }
}

class _PlanLoader extends StatefulWidget {
  const _PlanLoader({required this.actions});

  final V2SettingsActions actions;

  @override
  State<_PlanLoader> createState() => _PlanLoaderState();
}

class _PlanLoaderState extends State<_PlanLoader> {
  V2Currency _currency = V2Currency.usd;
  V2BillingPeriod _period = V2BillingPeriod.monthly;

  /// The gateway's plan table. Null until `GET /plans` answers; an empty list
  /// is a real answer ("nothing is on sale").
  List<CloudPlan>? _serverPlans;
  bool _plansLoading = true;
  String? _plansError;

  @override
  void initState() {
    super.initState();
    widget.actions.usage.addListener(_onChange);
    // The plan badge must reflect the server, not a stale cached tier.
    widget.actions.refreshUsage();
    unawaited(_loadPlans());
  }

  @override
  void dispose() {
    widget.actions.usage.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// Reads the one source of names, prices and limits.
  ///
  /// The screen used to carry its own plan copy; a failure here must not fall
  /// back to invented numbers, so an error is shown until a retry answers.
  Future<void> _loadPlans() async {
    if (mounted) {
      setState(() {
        _plansLoading = true;
        _plansError = null;
      });
    }
    try {
      final plans = await PlansClient().fetch();
      if (!mounted) return;
      setState(() {
        _serverPlans = plans;
        _plansLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _plansLoading = false;
        _plansError =
            'We could not load plans. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PlanBillingPage(
      data: V2SettingsRoutes._plans(
        context,
        widget.actions,
        serverPlans: _serverPlans,
        plansLoading: _plansLoading,
        plansError: _plansError,
        onReloadPlans: () => unawaited(_loadPlans()),
        currency: _currency,
        period: _period,
        onCurrencyChanged: (value) => setState(() => _currency = value),
        onPeriodChanged: (value) => setState(() => _period = value),
      ),
    );
  }
}

/// Keeps the Usage screen on live data: rebuilds when `/usage` or the daily
/// ledger changes, and forwards the 7/30-day switch to the real history query.
class _UsageLoader extends StatefulWidget {
  const _UsageLoader({required this.actions});

  final V2SettingsActions actions;

  @override
  State<_UsageLoader> createState() => _UsageLoaderState();
}

class _UsageLoaderState extends State<_UsageLoader> {
  final UsageHistoryStore _history = UsageHistoryStore();

  @override
  void initState() {
    super.initState();
    widget.actions.usage.addListener(_onChange);
    _history.addListener(_onChange);
    widget.actions.refreshUsage();
    _history.refresh();
  }

  @override
  void dispose() {
    widget.actions.usage.removeListener(_onChange);
    _history.removeListener(_onChange);
    _history.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return UsagePage(
      data: V2SettingsRoutes._usage(context, widget.actions, _history),
    );
  }
}

/// Loads the Android notification-permission state for the Notifications page
/// and refreshes it whenever the app returns to the foreground (for example
/// after the user grants the permission in system settings).
class _NotificationsLoader extends StatefulWidget {
  const _NotificationsLoader({required this.actions});

  final V2SettingsActions actions;

  @override
  State<_NotificationsLoader> createState() => _NotificationsLoaderState();
}

class _NotificationsLoaderState extends State<_NotificationsLoader>
    with WidgetsBindingObserver {
  bool _blocked = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  late bool _master = AppState.I.notificationsEnabled;

  /// The native notifier exists only on a phone. Web and desktop have no
  /// Android channel, so the page must say so instead of storing a preference
  /// that can never fire.
  static bool get _serviceAvailable =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  Future<void> _check() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final allowed = await NotificationPermission.isEnabled();
      if (!mounted) return;
      setState(() {
        _blocked = !allowed;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'We could not read the notification permission.';
      });
    }
  }

  Future<void> _openSystem() async {
    await NotificationPermission.openSettings();
    await _check();
  }

  /// Writes the account switch. The loader mirrors the optimistic value so the
  /// screen adopts it, then reads the persisted value back: a refused write
  /// leaves AppState unchanged and the switch rolls back.
  void _setMaster(bool value) {
    if (_saving) return;
    setState(() {
      _master = value;
      _saving = true;
    });
    unawaited(() async {
      try {
        await widget.actions.setNotificationsMaster(context, value);
      } finally {
        if (mounted) {
          setState(() {
            _master = AppState.I.notificationsEnabled;
            _saving = false;
          });
        }
      }
    }());
  }

  void _toggleChannel(String id, bool value) {
    if (_saving) return;
    setState(() => _saving = true);
    unawaited(() async {
      try {
        await widget.actions.setNotificationChannel(id, value);
      } finally {
        if (mounted) setState(() => _saving = false);
      }
    }());
  }

  @override
  Widget build(BuildContext context) {
    final status = _loading
        ? V2NotificationsStatus.loading
        : _error != null
        ? V2NotificationsStatus.error
        : V2NotificationsStatus.ready;
    return NotificationsPage(
      data: V2SettingsRoutes._notifications(
        context,
        widget.actions,
        notificationsBlocked: _blocked,
        onOpenSystem: _openSystem,
        status: status,
        serviceAvailable: _serviceAvailable,
        saving: _saving,
        masterEnabled: _master,
        onMasterChanged: _setMaster,
        onToggle: _toggleChannel,
        onRetry: _check,
      ),
    );
  }
}

/// Loads the one honest account-health aggregate from the gateway and keeps
/// the page on it. The four states are explicit: loading while the request is
/// in flight, empty when there is no signed-in account, error when the server
/// refuses or the answer is unreadable, content when it answers.
class _AccountHealthLoader extends StatefulWidget {
  const _AccountHealthLoader({required this.actions});

  final V2SettingsActions actions;

  @override
  State<_AccountHealthLoader> createState() => _AccountHealthLoaderState();
}

class _AccountHealthLoaderState extends State<_AccountHealthLoader> {
  AccountHealth? _health;
  health.V2AccountHealthStatus _status = health.V2AccountHealthStatus.loading;
  String? _error;
  bool? _signedIn;

  @override
  void initState() {
    super.initState();
    _signedIn = FirebaseService.I.isSignedIn;
    FirebaseService.I.addListener(_onChange);
    unawaited(_loadHealth());
  }

  @override
  void dispose() {
    FirebaseService.I.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    final signedIn = FirebaseService.I.isSignedIn;
    if (signedIn != _signedIn) {
      _signedIn = signedIn;
      unawaited(_loadHealth());
      return;
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadHealth() async {
    if (!FirebaseService.I.isSignedIn) {
      if (!mounted) return;
      setState(() {
        _health = null;
        _status = health.V2AccountHealthStatus.empty;
        _error = null;
      });
      return;
    }
    if (mounted) {
      setState(() {
        _status = health.V2AccountHealthStatus.loading;
        _error = null;
      });
    }
    try {
      final answer = await AccountHealthClient().fetch();
      if (!mounted) return;
      setState(() {
        _health = answer;
        // A 200 with no readable section is a contract failure, not an
        // account with zero of everything.
        _status = answer.isEmpty
            ? health.V2AccountHealthStatus.error
            : health.V2AccountHealthStatus.ready;
        _error = answer.isEmpty
            ? health.V2AccountHealthPageData.loadFailed
            : null;
      });
    } on CloudApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _health = null;
        _status = e.status == 401
            ? health.V2AccountHealthStatus.empty
            : health.V2AccountHealthStatus.error;
        _error = e.status == 401 ? null : e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _health = null;
        _status = health.V2AccountHealthStatus.error;
        _error = health.V2AccountHealthPageData.loadFailed;
      });
    }
  }

  Future<void> _cancelDeletion() async {
    try {
      await widget.actions.restoreAccount();
      // The deletion row is the server's; re-read it rather than assuming the
      // cancel changed this screen's copy.
      await _loadHealth();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not cancel deletion.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return health.AccountHealthPage(
      data: V2SettingsRoutes._health(
        context,
        widget.actions,
        accountHealth: _health,
        status: _status,
        errorMessage: _error,
        onCancelDeletion: _cancelDeletion,
        onRetry: () => unawaited(_loadHealth()),
      ),
    );
  }
}

/// Loads the signed-in chat's real memory files for the Memory screen.
class _MemoryLoader extends StatefulWidget {
  const _MemoryLoader({required this.actions});

  final V2SettingsActions actions;

  @override
  State<_MemoryLoader> createState() => _MemoryLoaderState();
}

class _MemoryLoaderState extends State<_MemoryLoader> {
  final V2MemorySource _source = V2MemorySource();
  V2MemorySnapshot? _snapshot;
  late V2MemoryPageData _data;

  @override
  void initState() {
    super.initState();
    _data = V2SettingsRoutes._memory(context, widget.actions, loading: true);
    unawaited(_load());
  }

  Future<void> _load() async {
    final sessionId = AppState.I.activeSessionId;
    if (sessionId == null) {
      if (!mounted) return;
      setState(() {
        _snapshot = null;
        _data = V2SettingsRoutes._memory(
          context,
          widget.actions,
          onRetry: _load,
        );
      });
      return;
    }
    try {
      final snapshot = await _source.load(sessionId);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _data = _pageFor(snapshot);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _data = V2SettingsRoutes._memory(
          context,
          widget.actions,
          errorMessage:
              'We could not load this chat’s memory files. Check your '
              'connection and try again.',
          onRetry: _load,
        );
      });
    }
  }

  /// Maps the real files and facts onto the screen. The shared scope holds
  /// cross-chat facts, so its files become [V2MemoryEntry] rows rather than
  /// per-chat file rows.
  V2MemoryPageData _pageFor(V2MemorySnapshot snapshot) {
    final sessionId = AppState.I.activeSessionId;
    // The global fact list only exists in the shared scope, so that is the one
    // scope with a real edit/add path. Chat-scope files stay read/forget only.
    final canWriteFacts = snapshot.shared && sessionId != null;
    return V2SettingsRoutes._memory(
      context,
      widget.actions,
      globalEntries: [
        for (final fact in snapshot.facts)
          V2MemoryEntry(id: fact.id, text: fact.text),
      ],
      files: snapshot.shared
          ? const []
          : [
              for (final file in snapshot.files)
                V2MemoryFile(
                  id: file.name,
                  name: file.name,
                  detail: V2SettingsRoutes._bytes(file.sizeBytes),
                ),
            ],
      onForgetMemory: _forget,
      onEditMemory: canWriteFacts
          ? (scope, id, text) => _source.editFact(
              sessionId: sessionId,
              scope: scope,
              id: id,
              text: text,
            )
          : null,
      onAddMemory: canWriteFacts
          ? (text) => _source.addFact(sessionId: sessionId, text: text)
          : null,
      onRetry: _load,
    );
  }

  /// Deletes one row through the real memory API, then reloads. The bool is
  /// the completion signal the screen needs: false keeps the row in place.
  Future<bool> _forget(V2MemoryScope scope, String id) async {
    final sessionId = AppState.I.activeSessionId;
    final snapshot = _snapshot;
    if (sessionId == null || snapshot == null) return false;
    try {
      await _source.forget(
        sessionId: sessionId,
        scope: scope,
        id: id,
        snapshot: snapshot,
      );
      await _load();
      return true;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text('Could not forget that memory. Try again.')),
          );
      }
      await _load();
      return false;
    }
  }

  @override
  Widget build(BuildContext context) => MemoryPage(data: _data);
}

/// Shared memory: the account's real sharing preference and the shared scope's
/// facts. The server has one shared namespace (not a switch per destination),
/// so the screen exposes that one real scope instead of inventing three.
class _SharedMemoryLoader extends StatefulWidget {
  const _SharedMemoryLoader({required this.actions});

  final V2SettingsActions actions;

  @override
  State<_SharedMemoryLoader> createState() => _SharedMemoryLoaderState();
}

class _SharedMemoryLoaderState extends State<_SharedMemoryLoader> {
  final V2MemorySource _source = V2MemorySource();
  bool _loading = true;
  String? _error;
  int _factCount = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final app = AppState.I;
    final sessionId = app.activeSessionId;
    if (!app.memoryEnabled ||
        !app.effectiveShareSessionMemory ||
        sessionId == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
        _factCount = 0;
      });
      return;
    }
    try {
      final snapshot = await _source.load(sessionId);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
        _factCount = snapshot.shared ? snapshot.facts.length : 0;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'We could not load shared memory.';
        _factCount = 0;
      });
    }
  }

  Future<void> _setShared(bool value) async {
    // Sharing needs memory: turning sharing on must turn memory on too,
    // otherwise the switch would flip back on the next rebuild.
    if (value && !AppState.I.memoryEnabled) {
      await widget.actions.setMemoryEnabled(true);
    }
    await widget.actions.setShareSessionMemory(value);
    await _load();
  }

  Future<void> _forget() async {
    final sessionId = AppState.I.activeSessionId;
    if (sessionId != null) {
      try {
        await _source.forgetAllShared(sessionId);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(content: Text('Could not forget shared facts.')),
            );
        }
      }
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = AppState.I.effectiveShareSessionMemory;
    final status = _loading
        ? V2SharedMemoryStatus.loading
        : _error != null
        ? V2SharedMemoryStatus.error
        : _factCount == 0
        ? V2SharedMemoryStatus.empty
        : V2SharedMemoryStatus.ready;
    return SharedMemoryPage(
      data: V2SharedMemoryPageData(
        status: status,
        enabled: enabled,
        scopes: [
          V2SharedMemoryScope(
            id: 'global',
            kind: V2SharedMemoryScopeKind.global,
            title: 'All chats',
            description: 'Facts reused in every chat you start.',
            audience: 'Only you, everywhere',
            shared: enabled,
          ),
        ],
        factCount: _factCount,
        onEnabledChanged: (value) => unawaited(_setShared(value)),
        onScopeChanged: (id, value) {
          if (id == 'global') unawaited(_setShared(value));
        },
        onForget: () => unawaited(_forget()),
        onRetry: _load,
        errorMessage: _error ?? 'We could not load shared memory.',
      ),
    );
  }
}

/// Personalization screen: rebuilds from live [AppState] and refreshes the
/// preview in place instead of pushing a second Appearance screen.
class _AppearanceLoader extends StatefulWidget {
  const _AppearanceLoader({required this.actions});

  final V2SettingsActions actions;

  @override
  State<_AppearanceLoader> createState() => _AppearanceLoaderState();
}

class _AppearanceLoaderState extends State<_AppearanceLoader> {
  @override
  void initState() {
    super.initState();
    AppState.I.addListener(_onChange);
  }

  @override
  void dispose() {
    AppState.I.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => AppearancePage(
    data: V2SettingsRoutes._appearance(context, widget.actions),
  );
}

/// Data control screen with real measured sizes, consent state, the account's
/// real contact and the export picker's per-chat selection.
class _DataControlLoader extends StatefulWidget {
  const _DataControlLoader({required this.actions});

  final V2SettingsActions actions;

  @override
  State<_DataControlLoader> createState() => _DataControlLoaderState();
}

class _DataControlLoaderState extends State<_DataControlLoader> {
  /// Export ids the person unticked. Absent means selected.
  final Map<String, bool> _selected = {};

  @override
  void initState() {
    super.initState();
    AppState.I.addListener(_onSessionsChanged);
  }

  @override
  void dispose() {
    AppState.I.removeListener(_onSessionsChanged);
    super.dispose();
  }

  void _onSessionsChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final sessions = V2SettingsRoutes.exportSessionsFor(
      AppState.I.sessions,
      _selected,
    );
    return DataControlPage(
      data: V2SettingsRoutes._dataControl(
        context,
        widget.actions,
        totalBytes: V2SettingsRoutes._localTranscriptBytes(),
        exportSessions: sessions,
        onExportSessionToggled: (id, selected) {
          setState(() => _selected[id] = selected);
        },
      ),
    );
  }
}

/// Storage screen measured from the account's artifact inventory, this
/// device's transcripts and the temporary cache.
class _StorageLoader extends StatefulWidget {
  const _StorageLoader({required this.actions});

  final V2SettingsActions actions;

  @override
  State<_StorageLoader> createState() => _StorageLoaderState();
}

class _StorageLoaderState extends State<_StorageLoader> {
  int _artifacts = 0;
  int _sessions = 0;
  int _cache = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final sessions = V2SettingsRoutes._localTranscriptBytes();
    final cache = await _cacheBytes();
    final artifacts = await _artifactBytes();
    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _cache = cache;
      _artifacts = artifacts;
      _loading = false;
    });
  }

  Future<int> _artifactBytes() async {
    final svc = FirebaseService.I;
    final uid = svc.uid;
    if (!svc.isSignedIn || uid == null) return 0;
    try {
      final page = await ArtifactVaultClient(
        accountId: () => 'firebase:$uid',
      ).list(limit: 100);
      var total = 0;
      for (final item in page.items) {
        total += item.sizeBytes;
      }
      return total;
    } catch (_) {
      // The inventory is account-scoped; an offline read leaves the row at 0
      // instead of inventing a number.
      return 0;
    }
  }

  Future<int> _cacheBytes() async {
    try {
      final dir = await getTemporaryDirectory();
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        try {
          total += await entity.length();
        } catch (_) {
          // A file removed mid-walk does not invalidate the measurement.
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Empties the temporary directory and returns the bytes actually freed, so
  /// the "Clear cache" row reports a measured number and the page reloads.
  Future<int> _clearCache() async {
    try {
      final dir = await getTemporaryDirectory();
      if (!await dir.exists()) return 0;
      final before = await _dirBytes(dir);
      await for (final entity in dir.list(followLinks: false)) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {
          // A file in use is skipped; the difference reports what went.
        }
      }
      final after = await _dirBytes(dir);
      if (mounted) await _load();
      return (before - after).clamp(0, before);
    } catch (_) {
      return 0;
    }
  }

  Future<int> _dirBytes(Directory dir) async {
    var bytes = 0;
    final stack = <Directory>[dir];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      try {
        await for (final entity in current.list(followLinks: false)) {
          if (entity is File) {
            try {
              bytes += await entity.length();
            } catch (_) {
              // Unreadable entries are not part of the report.
            }
          } else if (entity is Directory) {
            stack.add(entity);
          }
        }
      } catch (_) {
        // Unreadable directories are skipped.
      }
    }
    return bytes;
  }

  @override
  Widget build(BuildContext context) => StoragePage(
    data: V2SettingsRoutes._storage(
      context,
      widget.actions,
      artifactsBytes: _artifacts,
      sessionsBytes: _sessions,
      cacheBytes: _cache,
      loading: _loading,
      onClearCacheAndReport: _clearCache,
      onRetry: () {
        setState(() => _loading = true);
        unawaited(_load());
      },
    ),
  );
}

/// Permissions screen backed by the OS permission state.
class _PermissionsLoader extends StatefulWidget {
  const _PermissionsLoader();

  @override
  State<_PermissionsLoader> createState() => _PermissionsLoaderState();
}

class _PermissionsLoaderState extends State<_PermissionsLoader>
    with WidgetsBindingObserver {
  Map<String, PermissionStatus> _statuses = const {};
  bool _loading = true;
  String? _error;

  static const _permissions = <String, Permission>{
    'microphone': Permission.microphone,
    'notifications': Permission.notification,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }

  Future<void> _load() async {
    final next = <String, PermissionStatus>{};
    try {
      for (final entry in _permissions.entries) {
        next[entry.key] = await entry.value.status;
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            'Android did not report permission state. Open system settings '
            'to review them.';
      });
      return;
    }
    if (!mounted) return;
    // Android below API 33 has no notification prompt at all: a denied
    // notifications row can only be changed in system settings, so it must
    // offer "Open settings" instead of an "Ask" that can never show a dialog.
    final sdkInt = await NotificationPermission.androidSdkInt();
    if (sdkInt > 0 && sdkInt < 33) {
      final status = next['notifications'];
      if (status != null && !status.isGranted) {
        next['notifications'] = PermissionStatus.permanentlyDenied;
      }
    }
    if (!mounted) return;
    setState(() {
      _statuses = next;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _request(String id) async {
    final permission = _permissions[id];
    if (permission == null) return;
    try {
      await permission.request();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not ask Android for permission.'),
          ),
        );
      }
      return;
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const PermissionsPage(
        data: V2PermissionsPageData(status: V2PermissionsStatus.loading),
      );
    }
    final error = _error;
    if (error != null) {
      return PermissionsPage(
        data: V2PermissionsPageData(
          status: V2PermissionsStatus.error,
          errorMessage: error,
          onRetry: _load,
        ),
      );
    }
    return PermissionsPage(
      data: V2PermissionsPageData(
        permissions: V2SettingsRoutes._permissionItems(_statuses),
        onRequest: (id) => unawaited(_request(id)),
        onOpenSettings: () => unawaited(openAppSettings()),
        onOpenSettingsFor: (_) => unawaited(openAppSettings()),
        onRefresh: () => unawaited(_load()),
        onRetry: _load,
      ),
    );
  }
}

/// Agent presets: creates a real custom preset and rebuilds the list.
class _PresetLoader extends StatefulWidget {
  const _PresetLoader({required this.actions});

  final V2SettingsActions actions;

  @override
  State<_PresetLoader> createState() => _PresetLoaderState();
}

class _PresetLoaderState extends State<_PresetLoader> {
  @override
  void initState() {
    super.initState();
    AppState.I.addListener(_onChange);
  }

  @override
  void dispose() {
    AppState.I.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) =>
      AgentPresetsPage(data: V2SettingsRoutes._presets());
}

/// Credentials screen kept live across a GitHub device-flow sign-in.
class _CredentialsLoader extends StatefulWidget {
  const _CredentialsLoader({required this.actions});

  final V2SettingsActions actions;

  @override
  State<_CredentialsLoader> createState() => _CredentialsLoaderState();
}

class _CredentialsLoaderState extends State<_CredentialsLoader> {
  final CredentialsApi _vault = CloudCredentialsApi();
  List<V2BrowserCredential> _browser = const [];
  bool _browserLoaded = false;

  /// Placeholder shown for a vault secret. The server never returns the
  /// plaintext, so the row can only mask a fixed marker.
  static const _browserSecretMask = '••••••••';

  @override
  void initState() {
    super.initState();
    FirebaseService.I.addListener(_onChange);
    GitHubService.I.addListener(_onChange);
    unawaited(_loadBrowserCredentials());
  }

  @override
  void dispose() {
    FirebaseService.I.removeListener(_onChange);
    GitHubService.I.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _loadBrowserCredentials() async {
    try {
      final stored = await _vault.list();
      if (!mounted) return;
      setState(() {
        _browserLoaded = true;
        _browser = [
          for (final credential in stored)
            V2BrowserCredential(
              id: credential.id,
              site: credential.site,
              username: credential.username,
              password: _browserSecretMask,
            ),
        ];
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _browserLoaded = true);
    }
  }

  /// Creates a vault login for real. The page has already collected it.
  void _addBrowser(V2BrowserCredential credential) {
    unawaited(_saveBrowser(credential, create: true));
  }

  /// Updates a vault login. An unchanged secret arrives as the mask, so the
  /// write omits it and the stored plaintext stays on the server.
  void _editBrowser(V2BrowserCredential credential) {
    unawaited(_saveBrowser(credential, create: false));
  }

  Future<void> _saveBrowser(
    V2BrowserCredential credential, {
    required bool create,
  }) async {
    try {
      if (create) {
        await _vault.create(
          label: credential.site,
          site: credential.site,
          username: credential.username,
          secret: credential.password,
          secretKind: 'password',
        );
      } else {
        await _vault.update(
          credential.id,
          label: credential.site,
          site: credential.site,
          username: credential.username,
          secret: credential.password == _browserSecretMask
              ? null
              : credential.password,
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save the login.')),
        );
      }
    }
    await _loadBrowserCredentials();
  }

  /// Deletes one vault login for real. The page has already confirmed.
  void _deleteBrowser(V2BrowserCredential credential) {
    unawaited(() async {
      try {
        await _vault.remove(credential.id);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not delete the login.')),
          );
        }
      }
      await _loadBrowserCredentials();
    }());
  }

  /// Revokes every saved credential without ending the account session.
  ///
  /// The GitHub OAuth token is revoked and every stored provider key is
  /// cleared; the page has already removed its own secure-store secrets and
  /// the browser logins by the time this runs.
  Future<void> _revokeAll() async {
    try {
      for (final provider in [...AppState.I.providers]) {
        if (provider.apiKey.trim().isEmpty) continue;
        final error = await AppState.I.clearProviderApiKey(provider);
        if (error != null) throw StateError(error);
      }
      await GitHubService.I.signOut();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not revoke every credential.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => CredentialsPage(
    data: V2SettingsRoutes._credentials(
      context,
      widget.actions,
      browserCredentials: _browserLoaded ? _browser : const [],
      onAddBrowserCredential: _browserLoaded ? _addBrowser : null,
      onEditBrowserCredential: _browserLoaded ? _editBrowser : null,
      onDeleteBrowserCredential: _browserLoaded ? _deleteBrowser : null,
      onRevokeAll: () => unawaited(_revokeAll()),
    ),
  );
}

class V2PlanSpec {
  const V2PlanSpec({required this.name, required this.tagline, this.storageGb});

  final String name;
  final String tagline;

  /// The plan's R2 quota, or null when the tier is unknown. Prices are not
  /// here: they come from the server's plan table.
  final int? storageGb;
}
