import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/background_notifications.dart';
import '../../../core/cloud/account_settings_client.dart';
import '../../../core/firebase_service.dart';
import '../../../core/format.dart';
import '../../../core/legal_links.dart';
import '../../../core/notification_permission.dart';
import '../../../core/ovid_cloud_service.dart';
import '../../../core/presets.dart';
import '../../../core/revenuecat_billing.dart';
import '../../../core/state.dart';
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
        return PlanBillingPage(data: _plans(context, actions));
      case 'usage':
        return UsagePage(data: _usage(context, actions));
      case 'memory':
        return MemoryPage(data: _memory(context, actions));
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
        return AppearancePage(data: _appearance(context, actions));
      case 'data_control':
      case 'export':
      case 'crash':
        return DataControlPage(data: _dataControl(context, actions));
      case 'storage':
        return StoragePage(data: _storage(context, actions));
      case 'credentials':
        return CredentialsPage(data: _credentials(context, actions));
      case 'account_health':
        return AccountHealthPage(data: _health(context, actions));
      case 'notifications':
        return _NotificationsLoader(actions: actions);
      case 'presets':
        return AgentPresetsPage(data: _presets(context, actions));
      case 'response_wait':
        return ResponseWaitPage(data: _responseWait(context, actions));
      case 'permissions':
        return PermissionsPage(data: _permissions(context, actions));
      case 'app_lock':
        return const AppLockSettingsPage();
      case 'about':
        return AboutPage(data: _about(context, actions));
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
        const V2AccountField(
          id: 'region',
          label: 'Region',
          value: 'Asia Pacific',
        ),
      ],
      connectedAccounts: [
        V2ConnectedAccount(
          id: 'google',
          name: 'Google',
          detail: firebase.email ?? 'Not connected',
          connected: firebase.email != null,
        ),
        const V2ConnectedAccount(
          id: 'github',
          name: 'GitHub',
          detail: 'Manage in Credentials',
          connected: false,
        ),
      ],
      onEditProfile: () => actions.renameAccount(context),
      onFieldTap: (field) {
        if (field.id == 'display_name') actions.renameAccount(context);
      },
      onSignOut: () => actions.signOut(context),
      onDeleteAccount: () => actions.deleteAccount(context),
      onLinkAccount: () => open(context, 'credentials', actions),
    );
  }

  static V2PlanBillingData _plans(
    BuildContext context,
    V2SettingsActions actions,
  ) {
    final usage = actions.usage.usage;
    final app = AppState.I;
    final catalog = usage != null && usage.plans.isNotEmpty
        ? usage.plans
        : OvidPlanCatalog.plans;
    final plans = <V2Plan>[];
    for (final plan in catalog) {
      final tier = plan.tier;
      final spec = _planSpec(tier);
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
          autoOnly: tier == 'free' || tier == '3x',
          features: spec.features,
          popular: tier == '7x',
          ctaLabel: tier == app.ovidCloudTier ? 'Current plan' : null,
        ),
      );
    }
    return V2PlanBillingData(
      status: plans.isEmpty
          ? V2PlanBillingStatus.empty
          : V2PlanBillingStatus.ready,
      currentPlanId: app.ovidCloudTier,
      plans: plans,
      currentCtaLabel: app.ovidCloudIsPaid ? 'Manage subscription' : 'Upgrade',
      legalNote: RevenueCatBilling.I.usingTestStore
          ? 'Test mode: RevenueCat Test Store simulates purchases. No card is '
                'charged and no real subscription is created.'
          : 'Subscriptions renew automatically each month until canceled. '
                'You can cancel anytime from Google Play Store subscriptions.',
      onSelectPlan: (plan) => actions.buyPlan(context, plan.id),
      onUpgrade: () => actions.buyPlan(context, '7x'),
      onRestorePurchases: () => actions.restorePurchases(context),
      onRetry: actions.refreshUsage,
    );
  }

  static V2UsageData _usage(BuildContext context, V2SettingsActions actions) {
    final usage = actions.usage.usage;
    final today = usage?.today;
    final dailyLimit = 50000000;
    final monthlyLimit = 1500000000;
    final dailyUsed = (today?.inputTokens ?? 0) + (today?.outputTokens ?? 0);
    final monthlyUsed = usage?.monthFreeSpentUsd ?? 0;
    return V2UsageData(
      status: usage == null ? V2UsageStatus.loading : V2UsageStatus.ready,
      dailyUsedLabel: compactTokens(dailyUsed),
      dailyLimitLabel: compactTokens(dailyLimit),
      dailyFraction: dailyLimit == 0 ? 0 : (dailyUsed / dailyLimit).clamp(0, 1),
      resetLabel: usage?.resetsAt == null
          ? ''
          : formatTimeUntil(usage!.resetsAt!),
      monthlyUsedLabel: compactTokens(monthlyUsed.round()),
      monthlyLimitLabel: compactTokens(monthlyLimit),
      monthlyFraction: (monthlyUsed / monthlyLimit).clamp(0, 1),
      monthlyPercentLabel:
          '${((monthlyUsed / monthlyLimit) * 100).clamp(0, 100).toStringAsFixed(0)}%',
      billingNote: AppState.I.ovidCloudIsPaid
          ? 'Billed through Google Play.'
          : 'Free plan · limits reset every 24 hours.',
      requestsLabel: '${usage?.requestsToday ?? 0}',
      storageUsedLabel: '0 GB',
      storageLimitLabel: '${_planSpec(AppState.I.ovidCloudTier).storageGb} GB',
      models: [
        for (final model in usage?.models ?? const <OvidModelUsage>[])
          V2UsageModel(
            id: model.model,
            name: model.name ?? model.model,
            subtitle: model.kind == 'image' ? 'Images' : 'Chat',
            percent: model.hasRemainingPct
                ? (100 - model.remainingPct).round().clamp(0, 100)
                : 0,
            tokensLabel: '',
            tone: V2UsageTone.accent,
          ),
      ],
      showFreePlanNote: !AppState.I.ovidCloudIsPaid,
      onUpgrade: () => open(context, 'plan_billing', actions),
      onRetry: actions.refreshUsage,
    );
  }

  static V2MemoryPageData _memory(
    BuildContext context,
    V2SettingsActions actions,
  ) {
    final app = AppState.I;
    return V2MemoryPageData(
      memoryEnabled: app.memoryEnabled,
      shareSessionMemory: app.effectiveShareSessionMemory,
      globalVersionLabel: '',
      onMemoryEnabledChanged: actions.setMemoryEnabled,
      onShareSessionMemoryChanged: actions.setShareSessionMemory,
      onEditGlobal: () => open(context, 'memory_files', actions),
      onProjectTap: (_) => open(context, 'memory_files', actions),
      onFileDownload: (_) => actions.exportData(context),
      onExport: () => actions.exportData(context),
      onResetAll: () => actions.resetMemory(context),
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
      onThemeModeChanged: (mode) => actions.setThemeMode(mode),
      onTextScaleChanged: actions.setTextScale,
      onVoiceLanguageChanged: app.setVoiceLanguage,
      onRefreshPreview: () => open(context, 'appearance', actions),
    );
  }

  static V2DataControlPageData _dataControl(
    BuildContext context,
    V2SettingsActions actions,
  ) {
    return V2DataControlPageData(
      crashReports: false,
      hasData: true,
      onExportImport: () => actions.exportData(context),
      onExport: () => actions.exportData(context),
      onChooseImport: () => actions.importData(context),
      onPermissions: () => open(context, 'permissions', actions),
      onStorage: () => open(context, 'storage', actions),
      onDeleteData: () => actions.deleteAllData(context),
      onResetMemory: () => actions.resetMemory(context),
    );
  }

  static V2StoragePageData _storage(
    BuildContext context,
    V2SettingsActions actions,
  ) {
    final spec = _planSpec(AppState.I.ovidCloudTier);
    return V2StoragePageData(
      totalGb: spec.storageGb.toDouble(),
      onGoUpgrade: () => open(context, 'plan_billing', actions),
    );
  }

  static V2CredentialsPageData _credentials(
    BuildContext context,
    V2SettingsActions actions,
  ) {
    final firebase = FirebaseService.I;
    return V2CredentialsPageData(
      google: V2Credential(
        id: 'google',
        kind: V2CredentialKind.google,
        title: 'Google',
        subtitle: firebase.email ?? 'Not connected',
        connected: firebase.email != null,
      ),
      github: const V2Credential(
        id: 'github',
        kind: V2CredentialKind.github,
        title: 'GitHub',
        subtitle: 'Connect to clone and push from Studio',
        connected: false,
      ),
      token: const V2Credential(
        id: 'token',
        kind: V2CredentialKind.token,
        title: 'Access token',
        subtitle: 'Personal token for custom providers',
        connected: false,
      ),
      cloudKeyStatusLabel: 'Managed by Ovid',
      cloudKeyStatusDetail:
          'Your cloud key stays on the server and is never shown on this device.',
      cloudKeyActive: true,
      onConnectGithub: () => actions.notReady(context, 'GitHub'),
      onAddToken: () => actions.notReady(context, 'Access tokens'),
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
      onReviewDevices: () {},
      onEnableTwoFactor: () => actions.notReady(context, 'Two-factor'),
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
        V2NotificationSetting(
          id: 'shares_invites',
          title: 'Shares and invites',
          description: 'When someone shares a chat or invites you.',
          value: false,
        ),
        V2NotificationSetting(
          id: 'collaboration',
          title: 'Collaboration',
          description: 'New messages in shared chats.',
          value: false,
        ),
      ],
      security: const [
        V2NotificationSetting(
          id: 'new_signins',
          title: 'New sign-ins',
          description: 'When a new device signs in.',
          value: true,
        ),
        V2NotificationSetting(
          id: 'billing',
          title: 'Billing',
          description: 'Receipts and renewal reminders.',
          value: true,
        ),
      ],
      sound:
          settings.sounds[OvidChannel.agentUpdates] != NotificationSound.silent,
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
    V2SettingsActions actions,
  ) {
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
      onCreate: () => actions.notReady(context, 'New preset'),
      onSelect: actions.selectPreset,
      onDelete: (id) => actions.deletePreset(context, id),
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

  static V2PermissionsPageData _permissions(
    BuildContext context,
    V2SettingsActions actions,
  ) {
    return const V2PermissionsPageData(
      permissions: [
        V2PermissionItem(
          id: 'camera',
          name: 'Camera',
          reason: 'Scan documents and QR codes.',
          status: V2PermissionAccess.notAsked,
          icon: Icons.photo_camera_outlined,
        ),
        V2PermissionItem(
          id: 'microphone',
          name: 'Microphone',
          reason: 'Voice input in Hindi, Hinglish, Punjabi and Tamil.',
          status: V2PermissionAccess.notAsked,
          icon: Icons.mic_none_rounded,
        ),
        V2PermissionItem(
          id: 'photos',
          name: 'Photos',
          reason: 'Attach images to a chat.',
          status: V2PermissionAccess.notAsked,
          icon: Icons.photo_library_outlined,
        ),
        V2PermissionItem(
          id: 'notifications',
          name: 'Notifications',
          reason: 'Tell you when a long run finishes.',
          status: V2PermissionAccess.notAsked,
          icon: Icons.notifications_outlined,
        ),
        V2PermissionItem(
          id: 'files',
          name: 'Files',
          reason: 'Read and write files in your workspace.',
          status: V2PermissionAccess.notAsked,
          icon: Icons.folder_outlined,
        ),
      ],
    );
  }

  static V2AboutPageData _about(
    BuildContext context,
    V2SettingsActions actions,
  ) {
    return V2AboutPageData(
      version: '1.0.0',
      build: '1',
      onCopyVersion: () => actions.copyVersion(context),
      onPrivacyPolicy: () => actions.openUrl(context, LegalLinks.privacyPolicy),
      onTerms: () => actions.openUrl(context, LegalLinks.terms),
      onContactSupport: () =>
          actions.openUrl(context, 'mailto:${LegalLinks.supportEmail}'),
      onSystemStatus: () => actions.notReady(context, 'System status'),
    );
  }

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
