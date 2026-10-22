import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/diag.dart';
import '../core/notification_permission.dart';
import 'shell.dart' show TelemetryConsentPrompter;

/// SharedPreferences key: the first-run notification question was asked.
const kNotificationsPromptedPref = 'ovid_notifications_prompted';

/// The optional prompts of the first-run sequence, run ONE AT A TIME by
/// LoginGate after the welcome (EM-005, SH-031): notifications, then
/// telemetry consent, then (only with importable chats) the history import.
/// Static seams so widget tests can replace a step.
class FirstRunSteps {
  FirstRunSteps._();

  static Future<void> Function(BuildContext context) notifications =
      askNotificationsOnce;

  static Future<void> Function(BuildContext context) telemetry =
      _askTelemetry;

  @visibleForTesting
  static void reset() {
    notifications = askNotificationsOnce;
    telemetry = _askTelemetry;
  }

  static Future<void> _askTelemetry(BuildContext context) =>
      TelemetryConsentPrompter.firebase().askOnce(context);
}

/// Asks for POST_NOTIFICATIONS once, at a moment that explains why (EM-016:
/// targetSdk 36 never shows it otherwise, and Settings then reported
/// "blocked by Android"). Skipped when already granted, permanently denied,
/// or when the platform has no such permission. Settings keeps the toggle.
///
/// The runtime dialog only exists on API 33+. On 24–32 the permission is an
/// install-time switch, so "Turn on" opens the system notification settings
/// instead — `request()` there returns denied without showing anything.
Future<void> askNotificationsOnce(
  BuildContext context, {
  @visibleForTesting bool? isAndroid,
}) async {
  // POST_NOTIFICATIONS is an Android runtime permission; nothing to ask
  // elsewhere (host tests, desktop).
  if (!(isAndroid ?? (!kIsWeb && Platform.isAndroid))) return;
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(kNotificationsPromptedPref) == true) return;
  PermissionStatus status;
  try {
    status = await NotificationPermissionAccess.status();
  } catch (e) {
    // No platform implementation (tests, desktop): nothing to ask.
    Diag.swallow('first_run.notifications_status', e);
    return;
  }
  if (status.isGranted ||
      status.isPermanentlyDenied ||
      status.isRestricted ||
      status.isLimited) {
    await prefs.setBool(kNotificationsPromptedPref, true);
    return;
  }
  if (!context.mounted) return;
  await prefs.setBool(kNotificationsPromptedPref, true);
  if (!context.mounted) return;
  final allow = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (d) => AlertDialog(
      key: const ValueKey('first-run-notifications'),
      title: const Text(
        'Get notified when Ovid Si finishes',
        style: TextStyle(fontSize: 16),
      ),
      content: const Text(
        'Ovid Si works in the cloud, so long tasks keep running after you '
        'leave the app. Turn on notifications to hear when a run finishes '
        'or needs your approval. You can change this in Settings.',
        style: TextStyle(fontSize: 13, height: 1.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(d, true),
          child: const Text('Turn on'),
        ),
      ],
    ),
  );
  if (allow != true) return;
  // 0 means "the shell could not say" (host tests, older shell): assume the
  // prompt exists rather than sending a 33+ user to settings for nothing.
  final sdkInt = await NotificationPermission.androidSdkInt();
  final canPrompt = sdkInt == 0 || sdkInt >= 33;
  try {
    if (canPrompt) {
      await NotificationPermissionAccess.request();
    } else {
      await NotificationPermission.openSettings();
    }
  } catch (e) {
    Diag.swallow('first_run.notifications_request', e);
  }
}
