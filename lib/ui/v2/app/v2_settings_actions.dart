import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/account_service.dart';
import '../../../core/app_info.dart';
import '../../../core/background_notifications.dart';
import '../../../core/cloud/account_settings_client.dart';
import '../../../core/cloud/cloud_backup.dart';
import '../../../core/cloud/cloud_session_store.dart';
import '../../../core/cloud_usage_store.dart';
import '../../../core/commands.dart';
import '../../../core/firebase_service.dart';
import '../../../core/format.dart';
import '../../../core/native_share.dart';
import '../../../core/ovid_cloud_service.dart';
import '../../../core/play_billing.dart';
import '../../../core/presets.dart';
import '../../../core/revenuecat_billing.dart';
import '../../../core/settings_backup_service.dart';
import '../../../core/state.dart';
import '../chat/composer_voice.dart';
import '../settings_extra/notifications_page.dart';

/// Live actions used by the settings destinations. Kept out of the screens so
/// every page stays presentational and testable with injected data.
class V2SettingsActions {
  V2SettingsActions(this.usage) {
    // Launch hook: reconcile the cached plan with the store's entitlements
    // (refunds/cancellations) and mirror every server plan answer.
    usage.addListener(_onUsage);
    RevenueCatBilling.I.start();
  }

  final CloudUsageStore usage;

  /// Mirrors the server's plan answer into the local state.
  ///
  /// The tier restored from SharedPreferences (`state.dart:4789`
  /// `_loadOvidCloudTier`) is display-only: it survives a refund, a
  /// cancellation or an account switch. `/usage` is the source of truth, so
  /// its tier is recorded for [isServerConfirmed] and written to [AppState]
  /// (`setOvidCloudTier` is a no-op when it already matches).
  void _onUsage() {
    final tier = usage.usage?.tier;
    if (tier == null) return; // no server answer yet: keep the last one
    confirmPlanTier(tier);
    if (tier == 'free' || isKnownOvidTier(tier)) {
      AppState.I.setOvidCloudTier(tier);
    }
  }

  Future<void> signOut(BuildContext context) async {
    final ok = await _confirm(
      context,
      title: 'Sign out?',
      body: 'Your chats stay in your account and come back when you sign in.',
      confirm: 'Sign out',
    );
    if (!ok) return;
    await FirebaseService.I.signOut();
  }

  /// Requests account deletion from the account service.
  ///
  /// The server's receipt is the only success signal: the device is signed out
  /// only after a `pending` answer, and a refused or unconfigured service is
  /// reported verbatim instead of claiming the account was deleted.
  Future<void> deleteAccount(BuildContext context) async {
    final ok = await _confirm(
      context,
      title: 'Delete your account?',
      body:
          'This deletes your chats, files, memory and subscription data after '
          'a 24-hour grace period. It cannot be undone.',
      confirm: 'Delete account',
      danger: true,
    );
    if (!ok) return;
    try {
      final receipt = await FirebaseService.I.requestAccountDeletion(
        _newRequestId(),
      );
      if (!context.mounted) return;
      if (!receipt.isPending) {
        _snack(
          context,
          'The account service did not confirm the request. Nothing was '
          'deleted.',
        );
        return;
      }
      final deadline = receipt.deleteAfter;
      _snack(
        context,
        deadline == null
            ? 'Deletion scheduled. Sign in before the deadline to restore it.'
            : 'Deletion scheduled. Sign in before '
                  '${formatLocalDateTime(deadline)} to restore it.',
      );
    } on AccountException catch (e) {
      if (context.mounted) _snack(context, e.message);
    } catch (_) {
      if (context.mounted) {
        _snack(context, 'Could not request account deletion. Try again.');
      }
    }
  }

  /// Cancels a pending deletion on the server and returns the receipt so the
  /// account screen can show the restored state.
  Future<AccountDeletion?> restoreAccount() async {
    await FirebaseService.I.restoreAccount();
    return FirebaseService.I.lastDeletionReceipt;
  }

  static String _newRequestId() {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return 'v2-delete-$stamp';
  }

  Future<void> renameAccount(BuildContext context) async {
    final current = FirebaseService.I.displayName ?? '';
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Display name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Your name'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    final clean = name?.trim();
    if (clean == null || clean.isEmpty) return;
    final error = await FirebaseService.I.updateDisplayName(clean);
    if (error != null && context.mounted) _snack(context, error);
  }

  Future<void> buyPlan(BuildContext context, String tier) async {
    // Gate on the *server-confirmed* plan only: the tier restored from
    // SharedPreferences is display-only (state.dart:4789), so a stale cache
    // must not block a real purchase.
    if (isServerConfirmed(tier)) {
      _snack(context, 'You are already on this plan.');
      return;
    }
    if (tier == 'free') {
      _snack(context, 'Manage or cancel your plan in Google Play.');
      return;
    }
    // RevenueCat is the required purchase layer; the server-verified Play
    // flow remains the fallback for builds without a RevenueCat key.
    final rc = RevenueCatBilling.I;
    final viaRevenueCat = rc.available;
    final outcome = viaRevenueCat
        ? await rc.buy(tier)
        : await PlayBillingService.I.buy(tier);
    if (!context.mounted) return;
    if (!outcome.ok) {
      _snack(context, _billingMessage(outcome.result));
      return;
    }
    final unlocked = await _applyPurchase(outcome, viaRevenueCat: viaRevenueCat);
    if (!context.mounted) return;
    refreshUsage();
    _snack(
      context,
      unlocked
          ? 'Plan updated.'
          : 'Payment received. Your plan unlocks as soon as our server '
                'confirms it.',
    );
  }

  Future<void> restorePurchases(BuildContext context) async {
    final rc = RevenueCatBilling.I;
    final viaRevenueCat = rc.available;
    final outcome = viaRevenueCat
        ? await rc.restore()
        : await PlayBillingService.I.restore();
    if (!context.mounted) return;
    if (!outcome.ok) {
      _snack(context, _billingMessage(outcome.result));
      return;
    }
    final unlocked = await _applyPurchase(outcome, viaRevenueCat: viaRevenueCat);
    if (!context.mounted) return;
    refreshUsage();
    _snack(
      context,
      unlocked
          ? 'Purchases restored.'
          : 'Purchase found. Your plan unlocks as soon as our server confirms '
                'it.',
    );
  }

  /// Applies a successful purchase/restore to the local plan.
  ///
  /// A RevenueCat outcome is the store's word, not the server's: the tier is
  /// written only after `/usage` names the plan (`applyPurchasedPlan`). The
  /// Google Play outcome is already the `/billing/verify` verdict, so the
  /// server has confirmed it. Returns true when the plan is unlocked.
  Future<bool> _applyPurchase(
    UpgradeOutcome outcome, {
    required bool viaRevenueCat,
  }) async {
    final tier = outcome.tier;
    if (tier == null) return false;
    if (!viaRevenueCat) {
      AppState.I.setOvidCloudTier(tier);
      return true;
    }
    // The local demo path (debug/profile Test Store only) grants without a
    // server round trip; release builds cannot reach it.
    return applyPurchasedPlan(
      tier,
      demo: RevenueCatBilling.I.lastPurchaseWasDemo,
    );
  }

  Future<void> exportData(BuildContext context) async {
    _snack(context, 'Preparing your export…');
    try {
      final snapshot = await CloudBackup().fetchHistory();
      final plan = SettingsBackupService.planExport(snapshot.sessions);
      if (plan.included.isEmpty) {
        if (context.mounted) {
          _snack(context, plan.limitHit ?? 'There is nothing to export yet.');
        }
        return;
      }
      final bytes = await SettingsBackupService().export(plan.included);
      final temp = await getTemporaryDirectory();
      final dir = await temp.createTemp('ovid-backup-');
      final file = File('${dir.path}/ovid-transcripts-v1.zip');
      await file.writeAsBytes(bytes, flush: true);
      await NativeShare.file(file.path);
      if (context.mounted) {
        _snack(
          context,
          'Exported ${plan.included.length} '
          '${plan.included.length == 1 ? 'chat' : 'chats'}.',
        );
      }
    } on BackupLimitException catch (e) {
      if (context.mounted) _snack(context, e.message);
    } catch (_) {
      if (context.mounted) _snack(context, 'Export failed. Try again.');
    }
  }

  Future<void> importData(BuildContext context) async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        withData: false,
      );
      final path = picked?.files.singleOrNull?.path;
      if (path == null) return;
      final file = File(path);
      if (await file.length() > SettingsBackupService.maxArchiveBytes) {
        if (context.mounted) _snack(context, 'That file is larger than 64 MB.');
        return;
      }
      final temp = await getTemporaryDirectory();
      final staged = await SettingsBackupService().stage(
        await file.readAsBytes(),
        temp,
      );
      final List<Map<String, dynamic>> sessions;
      try {
        sessions = List.of(staged.sessions);
      } finally {
        await staged.dispose();
      }
      if (sessions.isEmpty) {
        if (context.mounted) _snack(context, 'That archive has no chats.');
        return;
      }
      if (!context.mounted) return;
      final ok = await _confirm(
        context,
        title: 'Import ${sessions.length} ${sessions.length == 1 ? 'chat' : 'chats'}?',
        body: 'They are added as new chats. Nothing existing is replaced.',
        confirm: 'Import',
      );
      if (!ok) return;
      final report = await CloudBackup().uploadArchiveSessions(sessions);
      try {
        await CloudSessionStore.I.refreshSessions();
      } catch (_) {
        // The chats are already on the server; the next refresh catches up.
      }
      if (context.mounted) {
        _snack(
          context,
          'Imported ${report.imported} of ${sessions.length} chats.',
        );
      }
    } on FormatException catch (e) {
      if (context.mounted) _snack(context, e.message);
    } catch (_) {
      if (context.mounted) _snack(context, 'Import failed. Try again.');
    }
  }

  Future<void> deleteAllData(BuildContext context) async {
    final ok = await _confirm(
      context,
      title: 'Delete all data?',
      body:
          'Chats, files, memory and drafts are removed from this device and '
          'the cloud. This cannot be undone.',
      confirm: 'Delete everything',
      danger: true,
    );
    if (!ok) return;
    await AppState.I.deleteAllData();
    if (context.mounted) _snack(context, 'All data deleted.');
  }

  Future<void> resetMemory(BuildContext context) async {
    final ok = await _confirm(
      context,
      title: 'Reset memory?',
      body: 'Ovid forgets global, project and session memory. Chats stay.',
      confirm: 'Reset memory',
      danger: true,
    );
    if (!ok) return;
    final sessionId = AppState.I.activeSessionId;
    if (sessionId == null) {
      if (context.mounted) _snack(context, 'Open a chat first.');
      return;
    }
    try {
      final client = AccountSettingsClient.I;
      final listing = await client.memoryFiles(sessionId);
      for (final file in listing.files) {
        await client.deleteMemory(sessionId, file.name);
      }
      if (context.mounted) _snack(context, 'Memory reset for this chat.');
    } catch (_) {
      if (context.mounted) _snack(context, 'Could not reset memory. Try again.');
    }
  }

  Future<void> setMemoryEnabled(bool value) =>
      AppState.I.setMemoryEnabled(value);

  Future<void> setShareSessionMemory(bool value) =>
      AppState.I.setShareSessionMemory(value);

  Future<void> setThemeMode(ThemeMode mode) {
    final value = switch (mode) {
      ThemeMode.system => 'system',
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
    };
    return AppState.I.setThemeMode(value);
  }

  Future<void> setTextScale(double value) =>
      AppState.I.setChatFontScale(value);

  /// Persists the dictation language and mirrors it into the composer.
  Future<void> setVoiceLanguage(String id) async {
    await AppState.I.setVoiceLanguage(id);
    v2SavedVoiceLanguage = AppState.I.voiceLanguage;
  }

  Future<void> setResponseWait(int seconds) =>
      AppState.I.setResponseTimeout(seconds);

  Future<void> setQuietHours({
    required bool enabled,
    TimeOfDay? start,
    TimeOfDay? end,
  }) => BackgroundNotifier.I.setQuietHours(
    enabled: enabled,
    startMinutes: start == null ? null : start.hour * 60 + start.minute,
    endMinutes: end == null ? null : end.hour * 60 + end.minute,
  );

  Future<void> setChannelSound(String channelId, V2NotificationSound sound) {
    for (final channel in OvidChannel.values) {
      if (channel.key != channelId) continue;
      return BackgroundNotifier.I.setChannelSound(
        channel,
        switch (sound) {
          V2NotificationSound.chime => NotificationSound.chime,
          V2NotificationSound.system => NotificationSound.system,
          V2NotificationSound.silent => NotificationSound.silent,
        },
      );
    }
    return Future<void>.value();
  }

  /// Per-channel switch. Channel keys are the only ids this handles; the
  /// account-wide switch has its own method so its branch can never be
  /// shadowed by a channel with the same key.
  Future<void> setNotificationChannel(String id, bool value) async {
    for (final channel in OvidChannel.values) {
      if (channel.key != id) continue;
      await BackgroundNotifier.I.setChannelEnabled(channel, value);
      return;
    }
  }

  /// The account-wide push switch. The server is the source of truth: the
  /// local preference is only written after `/settings` accepts the change,
  /// so a failed request cannot leave the UI claiming notifications are off.
  Future<void> setNotificationsMaster(BuildContext context, bool value) async {
    try {
      await AccountSettingsClient.I.setNotificationsEnabled(value);
    } catch (_) {
      if (context.mounted) {
        _snack(context, 'Could not update notifications. Check your connection.');
      }
      return;
    }
    await AppState.I.setNotificationsEnabled(value);
  }

  /// Opt in or out of anonymous crash reports and analytics.
  Future<void> setCrashReports(bool value) => FirebaseService.I.setConsent(value);

  void selectPreset(String id) {
    unawaited(CommandService.I.execute('/preset $id'));
  }

  /// Creates a custom preset and persists it through [AppState].
  ///
  /// The screen owns its own confirmation for deletion, so [deletePreset] does
  /// not ask again.
  Future<AgentPreset?> createPreset(BuildContext context) async {
    final controller = TextEditingController();
    final description = TextEditingController();
    final created = await showDialog<({String label, String description})>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New preset'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(hintText: 'Preset name'),
              onSubmitted: (value) => Navigator.pop(
                dialogContext,
                (label: value, description: description.text),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: description,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'What is this preset for? (optional)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(
              dialogContext,
              (label: controller.text, description: description.text),
            ),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    description.dispose();
    final label = created?.label.trim() ?? '';
    if (label.isEmpty) return null;
    final preset = AgentPreset(
      id: PresetRegistry.newCustomId(),
      label: label,
      description: created?.description.trim() ?? '',
    );
    await AppState.I.saveCustomPreset(preset);
    return preset;
  }

  Future<void> deletePreset(String id) async {
    await AppState.I.deleteCustomPreset(id);
  }

  Future<void> copyVersion(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: kAppVersionLabel));
    if (context.mounted) _snack(context, 'Version copied.');
  }

  Future<void> openUrl(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) _snack(context, 'Could not open the link.');
  }

  Future<void> openSystemSettings(BuildContext context) async {
    final uri = Uri.parse('app-settings:');
    try {
      await launchUrl(uri);
    } catch (_) {
      if (context.mounted) _snack(context, 'Open Android Settings manually.');
    }
  }

  void refreshUsage() => usage.refresh();

  void notReady(BuildContext context, String label) {
    _snack(context, '$label is not available yet.');
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String confirm,
    bool danger = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              confirm,
              style: danger ? const TextStyle(color: Colors.red) : null,
            ),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _snack(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _billingMessage(UpgradeResult result) => switch (result) {
    UpgradeResult.ok => 'Plan updated.',
    UpgradeResult.pending => 'Payment pending. Your plan activates once confirmed.',
    UpgradeResult.cancelled => 'Purchase cancelled.',
    UpgradeResult.notAvailable => 'Google Play billing is not available.',
    UpgradeResult.rejected => 'This purchase was not accepted.',
    UpgradeResult.nothingToRestore => 'No active subscription to restore.',
    UpgradeResult.confirming => 'Confirming your purchase…',
    UpgradeResult.otherAccount => 'This purchase belongs to another account.',
    UpgradeResult.offline => 'You appear to be offline. Try again.',
    UpgradeResult.unknown => 'The purchase did not complete. Try again.',
  };
}

ThemeMode themeModeOf(String value) => switch (value) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};

String? initialsFor(String name) {
  final words = name.trim().split(RegExp(r'\s+'));
  if (words.isEmpty || words.first.isEmpty) return null;
  if (words.length == 1) {
    return words.first.characters.take(1).toString().toUpperCase();
  }
  final first = words.first.characters.take(1).toString();
  final second = words[1].characters.take(1).toString();
  return '$first$second'.toUpperCase();
}

String compactTokens(int value) {
  if (value >= 1000000000) {
    return '${(value / 1000000000).toStringAsFixed(1)}B';
  }
  if (value >= 1000000) {
    final m = value / 1000000;
    return '${m.toStringAsFixed(m >= 10 ? 0 : 1)}M';
  }
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(0)}K';
  return '$value';
}
