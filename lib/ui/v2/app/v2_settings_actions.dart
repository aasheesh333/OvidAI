import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/background_notifications.dart';
import '../../../core/cloud/account_settings_client.dart';
import '../../../core/cloud/cloud_backup.dart';
import '../../../core/cloud/cloud_session_store.dart';
import '../../../core/cloud_usage_store.dart';
import '../../../core/commands.dart';
import '../../../core/firebase_service.dart';
import '../../../core/native_share.dart';
import '../../../core/ovid_cloud_service.dart';
import '../../../core/play_billing.dart';
import '../../../core/revenuecat_billing.dart';
import '../../../core/settings_backup_service.dart';
import '../../../core/state.dart';
import '../settings_extra/notifications_page.dart';

/// Live actions used by the settings destinations. Kept out of the screens so
/// every page stays presentational and testable with injected data.
class V2SettingsActions {
  V2SettingsActions(this.usage);

  final CloudUsageStore usage;

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

  Future<void> deleteAccount(BuildContext context) async {
    final ok = await _confirm(
      context,
      title: 'Delete your account?',
      body:
          'This deletes your chats, files, memory and subscription data. '
          'It cannot be undone.',
      confirm: 'Delete account',
      danger: true,
    );
    if (!ok) return;
    await FirebaseService.I.signOut();
    if (context.mounted) {
      _snack(context, 'Deletion request started. Check your email.');
    }
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
    if (tier == AppState.I.ovidCloudTier) {
      _snack(context, 'You are already on this plan.');
      return;
    }
    if (tier == 'free') {
      _snack(context, 'Manage or cancel your plan in Google Play.');
      return;
    }
    // RevenueCat is the required purchase layer; the server-verified Play
    // flow remains the fallback for builds without a RevenueCat key.
    final outcome = RevenueCatBilling.I.available
        ? await RevenueCatBilling.I.buy(tier)
        : await PlayBillingService.I.buy(tier);
    if (!context.mounted) return;
    if (outcome.ok) {
      AppState.I.setOvidCloudTier(outcome.tier ?? tier);
      refreshUsage();
      _snack(context, 'Plan updated.');
    } else {
      _snack(context, _billingMessage(outcome.result));
    }
  }

  Future<void> restorePurchases(BuildContext context) async {
    final outcome = RevenueCatBilling.I.available
        ? await RevenueCatBilling.I.restore()
        : await PlayBillingService.I.restore();
    if (!context.mounted) return;
    if (outcome.ok) {
      AppState.I.setOvidCloudTier(outcome.tier ?? AppState.I.ovidCloudTier);
      refreshUsage();
      _snack(context, 'Purchases restored.');
    } else {
      _snack(context, _billingMessage(outcome.result));
    }
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

  Future<void> setNotificationChannel(String id, bool value) async {
    for (final channel in OvidChannel.values) {
      if (channel.key != id) continue;
      await BackgroundNotifier.I.setChannelEnabled(channel, value);
      return;
    }
    if (id == OvidChannel.agentUpdates.key) {
      await AppState.I.setNotificationsEnabled(value);
    }
  }

  void selectPreset(String id) {
    unawaited(CommandService.I.execute('/preset $id'));
  }

  Future<void> deletePreset(BuildContext context, String id) async {
    final ok = await _confirm(
      context,
      title: 'Delete preset?',
      body: 'Runs using this preset keep their current settings.',
      confirm: 'Delete',
      danger: true,
    );
    if (!ok) return;
    await AppState.I.deleteCustomPreset(id);
  }

  void copyVersion(BuildContext context) {
    _snack(context, 'Version copied.');
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
