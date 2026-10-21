import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart' hide ServiceStatus;

import '../../../core/app_info.dart';
import '../../../core/background_notifications.dart';
import '../../../core/cloud/account_settings_client.dart';
import '../../../core/cloud/artifact_vault.dart';
import '../../../core/cloud/projects.dart';
import '../../../core/cloud/usage_history.dart';
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
import '../../github_login_sheet.dart';
import '../settings/account_health_page.dart';
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
    final app = AppState.I;
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
        return SharedMemoryPage(
          data: V2SharedMemoryPageData(
            enabled: app.effectiveShareSessionMemory,
            onEnabledChanged: (value) =>
                unawaited(actions.setShareSessionMemory(value)),
            onForget: () => unawaited(actions.resetMemory(context)),
          ),
        );
      case 'memory_files':
        return _MemoryFilesLoader(actions: actions);
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
        return AccountHealthPage(data: _health(context, actions));
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
        return _AboutLoader(actions: actions);
      default:
        return null;
    }
  }

  static V2AccountData _account(
    BuildContext context,
    V2SettingsActions actions,
  ) {
    final firebase = FirebaseService.I;
    final app = AppState.I;
    final receipt = firebase.lastDeletionReceipt;
    return V2AccountData(
      profile: V2AccountProfile(
        name: firebase.accountLabel,
        email: firebase.email ?? firebase.accountDetail,
        role: _planName(app.ovidCloudTier),
        initials: initialsFor(firebase.accountLabel),
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
      onFieldTap: (field) {
        if (field.id == 'display_name') actions.renameAccount(context);
      },
      onSignOut: () => actions.signOut(context),
      onDeleteAccount: () => actions.deleteAccount(context),
      onLinkAccount: () => open(context, 'credentials', actions),
      requestDeletion: FirebaseService.I.requestAccountDeletion,
      restoreDeletion: actions.restoreAccount,
      deletionPending: receipt?.isPending == true,
      deletionDeadline: receipt?.deleteAfter,
    );
  }

  static V2PlanBillingData _plans(
    BuildContext context,
    V2SettingsActions actions, {
    V2Currency currency = V2Currency.usd,
    V2BillingPeriod period = V2BillingPeriod.monthly,
    ValueChanged<V2Currency>? onCurrencyChanged,
    ValueChanged<V2BillingPeriod>? onPeriodChanged,
  }) {
    final usage = actions.usage.usage;
    final app = AppState.I;
    final catalog = usage != null && usage.plans.isNotEmpty
        ? usage.plans
        : OvidPlanCatalog.plans;
    final plans = <V2Plan>[];
    for (final plan in catalog) {
      final tier = plan.tier;
      final spec = _planSpec(tier);
      final limits = V2PlanLimits.forIdOrFree(tier);
      plans.add(
        V2Plan(
          id: tier,
          name: spec.name,
          tagline: spec.tagline,
          priceUsd: spec.usd,
          priceInr: spec.inr,
          priceUsdYearly: spec.usd * 10,
          priceInrYearly: spec.inr * 10,
          storageGb: spec.storageGb,
          autoOnly: !limits.manualModels,
          features: spec.features,
          popular: tier == '7x',
        ),
      );
    }
    // The server's answer is the only source that can confirm the plan
    // (state.dart restores a display-only cache); until it answers, fall back
    // to the cached tier for the badge only. Purchases re-check with
    // `isServerConfirmed` inside [V2SettingsActions.buyPlan].
    final currentTier = confirmedPlanTier ?? app.ovidCloudTier;
    return V2PlanBillingData(
      status: plans.isEmpty
          ? V2PlanBillingStatus.empty
          : V2PlanBillingStatus.ready,
      currency: currency,
      period: period,
      currentPlanId: currentTier,
      plans: plans,
      onCurrencyChanged: onCurrencyChanged,
      onPeriodChanged: onPeriodChanged,
      legalNote: RevenueCatBilling.I.usingTestStore
          ? 'Test mode: RevenueCat Test Store simulates purchases. No card is '
                'charged and no real subscription is created.'
          : 'Subscriptions renew automatically each month until canceled. '
                'You can cancel anytime from Google Play Store subscriptions.',
      // Every card names its own plan; the old screen hard-coded Plus here,
      // so a Go user's "Upgrade" bought Plus. The period travels with the
      // request so the yearly toggle cannot silently buy the monthly product.
      onPurchase: (purchase) {
        if (purchase.planId == 'free') {
          // Downgrading or cancelling is a Play action, not a purchase.
          unawaited(
            actions.openUrl(
              context,
              playSubscriptionCenterUri().toString(),
            ),
          );
          return;
        }
        actions.buyPlan(context, purchase.tier);
      },
      onRestorePurchases: () => actions.restorePurchases(context),
      onRetry: actions.refreshUsage,
    );
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

    final tier = usage.tier.trim().isEmpty ? AppState.I.ovidCloudTier : usage.tier;
    final limits = V2PlanLimits.forIdOrFree(tier);
    final today = usage.today;
    final recorded = history.history;

    int? dailyTokens;
    if (today != null) {
      dailyTokens = today.inputTokens + today.outputTokens;
    } else {
      final bucket = _todayBucket(recorded);
      dailyTokens = bucket?.counts.totalTokens;
    }
    final monthlyTokens = recorded?.totals.totalTokens;
    final requests = today?.requests ?? recorded?.totals.runs;
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

    final dailyFraction = dailyTokens == null || limits.dailyTokenCap == 0
        ? 0.0
        : (dailyTokens / limits.dailyTokenCap).clamp(0.0, 1.0);
    final monthlyFraction =
        monthlyTokens == null || limits.monthlyTokenCap == 0
        ? 0.0
        : (monthlyTokens / limits.monthlyTokenCap).clamp(0.0, 1.0);

    return V2UsageData(
      status: V2UsageStatus.ready,
      planId: tier,
      dailyUsedLabel: dailyTokens == null ? '' : compactTokens(dailyTokens),
      dailyLimitLabel: compactTokens(limits.dailyTokenCap),
      dailyFraction: dailyFraction,
      // The page derives a live countdown from this instant; no static string.
      resetsAt: usage.resetsAt,
      resetsAtLabel: usage.resetsAt == null
          ? ''
          : formatLocalDateTime(usage.resetsAt!),
      monthlyUsedLabel: monthlyTokens == null
          ? ''
          : compactTokens(monthlyTokens),
      monthlyLimitLabel: compactTokens(limits.monthlyTokenCap),
      monthlyFraction: monthlyFraction,
      monthlyPercentLabel: monthlyTokens == null
          ? ''
          : '${(monthlyFraction * 100).round()}%',
      billingNote: usage.isPaid
          ? 'Billed through Google Play.'
          : 'Free plan · limits reset every 24 hours.',
      days: _usageDays(recorded, history.days),
      range: history.days == 7
          ? V2UsageRange.sevenDays
          : V2UsageRange.thirtyDays,
      historyLoading: history.loading && recorded == null,
      models: _usageModels(usage, recorded),
      requestsLabel: requests == null ? '' : '$requests',
      imagesLabel: images == null ? '' : '$images',
      storageLimitLabel: '${limits.storageGb} GB',
      showFreePlanNote: !limits.manualModels,
      onRangeChanged: (range) => unawaited(
        history.setDays(range == V2UsageRange.sevenDays ? 7 : 30),
      ),
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
    final sorted = [...history.days]
      ..sort((a, b) => a.date.compareTo(b.date));
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

  static const _weekdays = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

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
      final rows = byModel.entries
          .map((entry) => (entry.key, entry.value.inputTokens + entry.value.outputTokens))
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
          percent: (row.counts.totalTokens / ledgerTotal * 100)
              .round()
              .clamp(0, 100),
          tokensLabel: '${compactTokens(row.counts.totalTokens)} tokens',
        ),
    ];
  }

  static V2MemoryPageData _memory(
    BuildContext context,
    V2SettingsActions actions, {
    List<V2MemoryFile> files = const [],
    bool loading = false,
    String? errorMessage,
    VoidCallback? onRetry,
  }) {
    final app = AppState.I;
    return V2MemoryPageData(
      memoryEnabled: app.memoryEnabled,
      shareSessionMemory: app.effectiveShareSessionMemory,
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
      onFileDownload: (_) => actions.exportData(context),
      onExport: () => actions.exportData(context),
      onResetAll: () => actions.resetMemory(context),
      onRetry: onRetry,
    );
  }

  static V2AppearancePageData _appearance(
    BuildContext context,
    V2SettingsActions actions, {
    VoidCallback? onRefreshPreview,
  }) {
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
      // Re-reading AppState rebuilds the preview; it must not push a second
      // Appearance screen on top of this one.
      onRefreshPreview: onRefreshPreview,
    );
  }

  static V2DataControlPageData _dataControl(
    BuildContext context,
    V2SettingsActions actions, {
    int totalBytes = 0,
  }) {
    final spec = _planSpec(AppState.I.ovidCloudTier);
    final quotaBytes = spec.storageGb * 1024 * 1024 * 1024;
    return V2DataControlPageData(
      totalDataSizeLabel: totalBytes > 0 ? _bytes(totalBytes) : '',
      crashReports: FirebaseService.I.consentGiven,
      hasData: AppState.I.sessions.isNotEmpty,
      storageUsedLabel: '${_bytes(totalBytes)} of ${spec.storageGb} GB',
      storageFraction: quotaBytes <= 0
          ? 0
          : (totalBytes / quotaBytes).clamp(0.0, 1.0),
      storageFreeLabel: _bytes(
        (quotaBytes - totalBytes).clamp(0, quotaBytes),
      ),
      onExportImport: () => actions.exportData(context),
      onExport: () => actions.exportData(context),
      onChooseImport: () => actions.importData(context),
      onPermissions: () => open(context, 'permissions', actions),
      onCrashReportsChanged: (value) =>
          unawaited(actions.setCrashReports(value)),
      onStorage: () => open(context, 'storage', actions),
      onDeleteData: () => actions.deleteAllData(context),
      onResetMemory: () => actions.resetMemory(context),
    );
  }

  static V2StoragePageData _storage(
    BuildContext context,
    V2SettingsActions actions, {
    int artifactsBytes = 0,
    int sessionsBytes = 0,
    int cacheBytes = 0,
    bool loading = false,
    String? errorMessage,
    VoidCallback? onRetry,
  }) {
    final spec = _planSpec(AppState.I.ovidCloudTier);
    // Cache lives on the device, so it is shown but never counted against the
    // account's cloud quota.
    final used = artifactsBytes + sessionsBytes;
    double gb(int bytes) => bytes / (1024 * 1024 * 1024);
    return V2StoragePageData(
      usedGb: gb(used),
      totalGb: spec.storageGb.toDouble(),
      planName: _planName(AppState.I.ovidCloudTier),
      quotaLabel: '${spec.storageGb} GB included',
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
      onRetry: onRetry,
      onGoUpgrade: () => open(context, 'plan_billing', actions),
    );
  }

  /// UTF-8 size of the on-device transcript, including attachment metadata.
  static int _localTranscriptBytes() {
    var total = 0;
    for (final session in AppState.I.sessions) {
      for (final message in session.messages) {
        total += utf8.encode(message.content).length;
        final detail = message.toolDetail;
        if (detail != null) total += utf8.encode(detail).length;
        for (final attachment in message.attachments) {
          total += attachment.size;
        }
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
    V2SettingsActions actions,
  ) {
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
            : 'Connect to clone and push from Studio',
        connected: github.isLoggedIn,
      ),
      token: const V2Credential(
        id: 'token',
        kind: V2CredentialKind.token,
        title: 'Access token',
        subtitle: 'Personal token for custom providers',
        connected: false,
      ),
      githubOAuthConnected: github.isLoggedIn,
      cloudKeyStatusLabel: 'Managed by Ovid',
      cloudKeyStatusDetail:
          'Your cloud key stays on the server and is never shown on this device.',
      cloudKeyActive: true,
      // The page stores personal keys and GitHub PATs in the platform secure
      // store itself when no host saver is injected.
      onConnectGithubOAuth: () => showGithubLoginSheet(context),
      onDisconnectGithubOAuth: () => unawaited(github.signOut()),
      onRevokeAll: () => actions.signOut(context),
    );
  }

  static V2AccountHealthPageData _health(
    BuildContext context,
    V2SettingsActions actions,
  ) {
    final firebase = FirebaseService.I;
    return V2AccountHealthPageData(
      statusTitle: firebase.emailVerified
          ? 'Your account is protected'
          : 'Verify your email',
      statusMessage: firebase.emailVerified
          ? 'Email verified. Review devices if you see something unfamiliar.'
          : 'Verifying your email helps us recover your account.',
      healthy: firebase.emailVerified,
      emailVerified: firebase.emailVerified,
      emailLabel: firebase.email ?? 'No email',
      regionLabel: 'Asia Pacific',
      devices: [
        V2SignInDevice(
          id: 'current',
          name: 'This device',
          detail: 'Android · active now',
          current: true,
        ),
      ],
      // Two-step sign-in and device review have no service behind them yet;
      // the rows stay hidden rather than offering a dead action.
      onReviewDevices: null,
      onEnableTwoFactor: null,
    );
  }

  static V2NotificationsPageData _notifications(
    BuildContext context,
    V2SettingsActions actions, {
    required bool notificationsBlocked,
    required VoidCallback onOpenSystem,
  }) {
    final settings = BackgroundNotifier.I.settings;
    final master = AppState.I.notificationsEnabled;
    final start = settings.quietHoursStartMinutes;
    final end = settings.quietHoursEndMinutes;
    String hhmm(int minutes) {
      final h = (minutes ~/ 60).toString().padLeft(2, '0');
      final m = (minutes % 60).toString().padLeft(2, '0');
      return '$h:$m';
    }

    return V2NotificationsPageData(
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
      vibration: true,
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
      onToggle: (id, value) => actions.setNotificationChannel(id, value),
      onMasterChanged: (value) =>
          unawaited(actions.setNotificationsMaster(context, value)),
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
    );
  }

  static V2AgentPresetsPageData _presets(
    BuildContext context,
    V2SettingsActions actions, {
    VoidCallback? onCreate,
  }) {
    return V2AgentPresetsPageData(
      presets: [
        for (final preset in PresetRegistry.all)
          V2AgentPreset(
            id: preset.id,
            name: preset.label,
            description: preset.description,
            modelLabel: preset.model ?? 'Auto',
            builtIn: PresetRegistry.isBuiltInId(preset.id),
            icon: PresetRegistry.isBuiltInId(preset.id)
                ? Icons.auto_awesome_rounded
                : Icons.tune_rounded,
          ),
      ],
      selectedId: AppState.I.activeSession?.presetId,
      onCreate: onCreate,
      onSelect: actions.selectPreset,
      onDelete: (id) => actions.deletePreset(id),
    );
  }

  static V2ResponseWaitPageData _responseWait(
    BuildContext context,
    V2SettingsActions actions,
  ) {
    final seconds = AppState.I.responseTimeoutSec;
    return V2ResponseWaitPageData(
      seconds: seconds,
      onChanged: actions.setResponseWait,
      onPreset: actions.setResponseWait,
    );
  }

  /// Maps the OS answer onto the page's three-state model.
  static V2PermissionAccess _permissionAccess(PermissionStatus status) {
    if (status.isGranted || status.isLimited) return V2PermissionAccess.granted;
    if (status.isPermanentlyDenied || status.isRestricted) {
      return V2PermissionAccess.blocked;
    }
    return V2PermissionAccess.notAsked;
  }

  /// The five device permissions Ovid can ask for, with the real OS state.
  static List<V2PermissionItem> _permissionItems(
    Map<String, PermissionStatus> statuses,
  ) {
    const ids = <String>['camera', 'microphone', 'photos', 'notifications', 'files'];
    const meta = <String, ({String name, String reason, IconData icon})>{
      'camera': (
        name: 'Camera',
        reason: 'Scan documents and QR codes.',
        icon: Icons.photo_camera_outlined,
      ),
      'microphone': (
        name: 'Microphone',
        reason: 'Voice input in Hindi, Hinglish, Punjabi and Tamil.',
        icon: Icons.mic_none_rounded,
      ),
      'photos': (
        name: 'Photos',
        reason: 'Attach images to a chat.',
        icon: Icons.photo_library_outlined,
      ),
      'notifications': (
        name: 'Notifications',
        reason: 'Tell you when a long run finishes.',
        icon: Icons.notifications_outlined,
      ),
      'files': (
        name: 'Files',
        reason: 'Read and write files in your workspace.',
        icon: Icons.folder_outlined,
      ),
    };
    return [
      for (final id in ids)
        V2PermissionItem(
          id: id,
          name: meta[id]!.name,
          reason: meta[id]!.reason,
          status: _permissionAccess(
            statuses[id] ?? PermissionStatus.denied,
          ),
          icon: meta[id]!.icon,
        ),
    ];
  }

  static V2AboutPageData _about(
    BuildContext context,
    V2SettingsActions actions, {
    V2SystemStatus systemStatus = V2SystemStatus.unknown,
    VoidCallback? onSystemStatus,
    VoidCallback? onRetrySystemStatus,
  }) {
    return V2AboutPageData(
      // The build's real version/build, never a demo string.
      version: kAppVersion,
      build: kAppBuildNumber,
      systemStatus: systemStatus,
      onCopyVersion: () => actions.copyVersion(context),
      onPrivacyPolicy: () => actions.openUrl(context, LegalLinks.privacyPolicy),
      onTerms: () => actions.openUrl(context, LegalLinks.terms),
      onContactSupport: () =>
          actions.openUrl(context, 'mailto:${LegalLinks.supportEmail}'),
      onSystemStatus: onSystemStatus,
      onRetrySystemStatus: onRetrySystemStatus,
      onDeleteAccount: () => actions.deleteAccount(context),
    );
  }

  /// Maps the gateway's `/status` answer onto the About badge.
  static V2SystemStatus _systemStatusOf(ServiceStatus status) =>
      switch (status.overall) {
        ServiceCheck.ok => V2SystemStatus.operational,
        ServiceCheck.degraded => V2SystemStatus.degraded,
        ServiceCheck.down => V2SystemStatus.error,
        ServiceCheck.unknown => V2SystemStatus.unknown,
      };

  static String _planName(String tier) =>
      tier == 'free' ? 'Free plan' : ovidPlanName(tier);

  static V2PlanSpec _planSpec(String tier) {
    switch (tier) {
      case '3x':
        return const V2PlanSpec(
          name: 'Go',
          tagline: 'For everyday work',
          usd: 5,
          inr: 499,
          storageGb: 5,
          features: ['Auto models', '5 GB storage', 'Schedules'],
        );
      case '7x':
        return const V2PlanSpec(
          name: 'Plus',
          tagline: 'For serious builders',
          usd: 18,
          inr: 1799,
          storageGb: 15,
          features: ['All models', '15 GB storage', 'Collaboration'],
        );
      case '15x':
        return const V2PlanSpec(
          name: 'Pro',
          tagline: 'For teams and heavy use',
          usd: 99,
          inr: 9999,
          storageGb: 75,
          features: ['All models', '75 GB storage', 'Priority support'],
        );
      default:
        return const V2PlanSpec(
          name: 'Free',
          tagline: 'Start building',
          usd: 0,
          inr: 0,
          storageGb: 3,
          features: ['Auto model', '3 GB storage', '50M tokens a day'],
        );
    }
  }
}

/// Keeps the Plan & billing screen live: owns the currency/period choice (so
/// the toggles are real, not dead) and rebuilds when `/usage` changes the
/// confirmed plan after a purchase.
class _PlanLoader extends StatefulWidget {
  const _PlanLoader({required this.actions});

  final V2SettingsActions actions;

  @override
  State<_PlanLoader> createState() => _PlanLoaderState();
}

class _PlanLoaderState extends State<_PlanLoader> {
  V2Currency _currency = V2Currency.usd;
  V2BillingPeriod _period = V2BillingPeriod.monthly;

  @override
  void initState() {
    super.initState();
    widget.actions.usage.addListener(_onChange);
    // The plan badge must reflect the server, not a stale cached tier.
    widget.actions.refreshUsage();
  }

  @override
  void dispose() {
    widget.actions.usage.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return PlanBillingPage(
      data: V2SettingsRoutes._plans(
        context,
        widget.actions,
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
    final allowed = await NotificationPermission.isEnabled();
    if (!mounted) return;
    setState(() => _blocked = !allowed);
  }

  Future<void> _openSystem() async {
    await NotificationPermission.openSettings();
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationsPage(
      data: V2SettingsRoutes._notifications(
        context,
        widget.actions,
        notificationsBlocked: _blocked,
        onOpenSystem: _openSystem,
      ),
    );
  }
}

/// Loads the signed-in account's memory files for the active chat. The page
/// itself stays presentational; this wrapper owns the request and the
/// destructive actions.
class _MemoryFilesLoader extends StatefulWidget {
  const _MemoryFilesLoader({required this.actions});

  final V2SettingsActions actions;

  @override
  State<_MemoryFilesLoader> createState() => _MemoryFilesLoaderState();
}

class _MemoryFilesLoaderState extends State<_MemoryFilesLoader> {
  V2MemoryFilesPageData _data = const V2MemoryFilesPageData(
    status: V2MemoryFilesStatus.loading,
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sessionId = AppState.I.activeSessionId;
    if (sessionId == null) {
      if (!mounted) return;
      setState(() {
        _data = const V2MemoryFilesPageData(status: V2MemoryFilesStatus.empty);
      });
      return;
    }
    try {
      final listing = await AccountSettingsClient.I.memoryFiles(sessionId);
      if (!mounted) return;
      final total = listing.files.fold<int>(0, (sum, f) => sum + f.sizeBytes);
      setState(() {
        _data = V2MemoryFilesPageData(
          status: listing.files.isEmpty
              ? V2MemoryFilesStatus.empty
              : V2MemoryFilesStatus.ready,
          totalSizeLabel: _size(total),
          files: [
            for (final file in listing.files)
              V2MemoryFileEntry(
                id: file.name,
                name: file.name,
                group: listing.shared
                    ? V2MemoryFileGroup.global
                    : V2MemoryFileGroup.session,
                sizeLabel: _size(file.sizeBytes),
                updatedLabel: '',
                preview: '',
              ),
          ],
        );
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _data = const V2MemoryFilesPageData(status: V2MemoryFilesStatus.error);
      });
    }
  }

  Future<void> _open(V2MemoryFileEntry entry) async {
    final sessionId = AppState.I.activeSessionId;
    if (sessionId == null) return;
    try {
      final file = await AccountSettingsClient.I.readMemory(
        sessionId,
        entry.name,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(entry.name),
          content: SingleChildScrollView(child: Text(file.content)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open that file.')),
        );
      }
    }
  }

  Future<void> _delete(V2MemoryFileEntry entry) async {
    final sessionId = AppState.I.activeSessionId;
    if (sessionId == null) return;
    try {
      await AccountSettingsClient.I.deleteMemory(sessionId, entry.name);
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete that file.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MemoryFilesPage(
      data: V2MemoryFilesPageData(
        status: _data.status,
        files: _data.files,
        totalSizeLabel: _data.totalSizeLabel,
        onOpen: (id) {
          final entry = _data.files.where((f) => f.id == id).firstOrNull;
          if (entry != null) _open(entry);
        },
        onDelete: (id) {
          final entry = _data.files.where((f) => f.id == id).firstOrNull;
          if (entry != null) _delete(entry);
        },
        onExportAll: () => widget.actions.exportData(context),
        onRetry: _load,
      ),
    );
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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
  late V2MemoryPageData _data;

  @override
  void initState() {
    super.initState();
    _data = V2SettingsRoutes._memory(
      context,
      widget.actions,
      loading: true,
    );
    unawaited(_load());
  }

  Future<void> _load() async {
    final sessionId = AppState.I.activeSessionId;
    if (sessionId == null) {
      if (!mounted) return;
      setState(() {
        _data = V2SettingsRoutes._memory(
          context,
          widget.actions,
          onRetry: _load,
        );
      });
      return;
    }
    try {
      final listing = await AccountSettingsClient.I.memoryFiles(sessionId);
      if (!mounted) return;
      setState(() {
        _data = V2SettingsRoutes._memory(
          context,
          widget.actions,
          files: [
            for (final file in listing.files)
              V2MemoryFile(
                id: file.name,
                name: file.name,
                detail: V2SettingsRoutes._bytes(file.sizeBytes),
              ),
          ],
          onRetry: _load,
        );
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

  @override
  Widget build(BuildContext context) => MemoryPage(data: _data);
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
    data: V2SettingsRoutes._appearance(
      context,
      widget.actions,
      onRefreshPreview: () {
        if (mounted) setState(() {});
      },
    ),
  );
}

/// Data control screen with real measured sizes, consent state and content.
class _DataControlLoader extends StatelessWidget {
  const _DataControlLoader({required this.actions});

  final V2SettingsActions actions;

  @override
  Widget build(BuildContext context) => DataControlPage(
    data: V2SettingsRoutes._dataControl(
      context,
      actions,
      totalBytes: V2SettingsRoutes._localTranscriptBytes(),
    ),
  );
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
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
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

  @override
  Widget build(BuildContext context) => StoragePage(
    data: V2SettingsRoutes._storage(
      context,
      widget.actions,
      artifactsBytes: _artifacts,
      sessionsBytes: _sessions,
      cacheBytes: _cache,
      loading: _loading,
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
    'camera': Permission.camera,
    'microphone': Permission.microphone,
    'photos': Permission.photos,
    'notifications': Permission.notification,
    'files': Permission.storage,
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
          const SnackBar(content: Text('Could not ask Android for permission.')),
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

  Future<void> _create() async {
    final created = await widget.actions.createPreset(context);
    if (created != null && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => AgentPresetsPage(
    data: V2SettingsRoutes._presets(
      context,
      widget.actions,
      onCreate: () => unawaited(_create()),
    ),
  );
}

/// Credentials screen kept live across a GitHub device-flow sign-in.
class _CredentialsLoader extends StatefulWidget {
  const _CredentialsLoader({required this.actions});

  final V2SettingsActions actions;

  @override
  State<_CredentialsLoader> createState() => _CredentialsLoaderState();
}

class _CredentialsLoaderState extends State<_CredentialsLoader> {
  @override
  void initState() {
    super.initState();
    FirebaseService.I.addListener(_onChange);
    GitHubService.I.addListener(_onChange);
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

  @override
  Widget build(BuildContext context) => CredentialsPage(
    data: V2SettingsRoutes._credentials(context, widget.actions),
  );
}

/// About screen with the real build identity and the gateway's live status.
class _AboutLoader extends StatefulWidget {
  const _AboutLoader({required this.actions});

  final V2SettingsActions actions;

  @override
  State<_AboutLoader> createState() => _AboutLoaderState();
}

class _AboutLoaderState extends State<_AboutLoader> {
  V2SystemStatus _status = V2SystemStatus.checking;
  ServiceStatus? _service;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (mounted) setState(() => _status = V2SystemStatus.checking);
    try {
      final service = await AccountSettingsClient.I.serviceStatus();
      if (!mounted) return;
      setState(() {
        _service = service;
        _status = V2SettingsRoutes._systemStatusOf(service);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _service = null;
        _status = V2SystemStatus.error;
      });
    }
  }

  Future<void> _showStatus() async {
    final service = _service;
    if (service == null) {
      await _load();
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Service status'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StatusLine(label: 'Overall', check: service.overall),
            _StatusLine(label: 'Storage', check: service.storage),
            _StatusLine(label: 'Queue', check: service.queue),
            _StatusLine(label: 'Agents', check: service.agents),
            _StatusLine(label: 'Models', check: service.models),
            if (service.checkedAt != null) ...[
              const SizedBox(height: 8),
              Text(
                'Checked ${formatLocalDateTime(service.checkedAt!)}',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AboutPage(
    data: V2SettingsRoutes._about(
      context,
      widget.actions,
      systemStatus: _status,
      onSystemStatus: () => unawaited(_showStatus()),
      onRetrySystemStatus: () => unawaited(_load()),
    ),
  );
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.label, required this.check});

  final String label;
  final ServiceCheck check;

  @override
  Widget build(BuildContext context) {
    final text = switch (check) {
      ServiceCheck.ok => 'Operational',
      ServiceCheck.degraded => 'Some issues',
      ServiceCheck.down => 'Down',
      ServiceCheck.unknown => 'Not reported',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [Text(label), Text(text)],
      ),
    );
  }
}

class V2PlanSpec {
  const V2PlanSpec({
    required this.name,
    required this.tagline,
    required this.usd,
    required this.inr,
    required this.storageGb,
    required this.features,
  });

  final String name;
  final String tagline;
  final int usd;
  final int inr;
  final int storageGb;
  final List<String> features;
}
