/// Distribution channel gates.
///
/// A Google Play build is produced with `--dart-define=OVID_PLAY_BUILD=true`.
/// The same define drives the native side (android/app/build.gradle.kts reads
/// Flutter's forwarded dart-defines): targetSdk 36, no bundled Linux userland,
/// and the src/play manifest overlay without the AccessibilityService.
///
/// Every Play-policy feature cut is expressed here so it is reviewable in one
/// place (see docs/play/PLAY_COMPLIANCE_AUDIT.md):
///  * Control mode — Play prohibits using the Accessibility API to let an app
///    "autonomously initiate, plan, and execute actions" (answer/10964491).
///  * On-device sandbox — exec from app data is blocked at targetSdk >= 29
///    and downloading executables from outside Play violates Device and
///    Network Abuse (answer/9888379).
///  * Idle keep-alive — a foreground service with no user task is not an
///    approvable foreground-service use (answer/13392821).
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

class Distribution {
  const Distribution._();

  static const bool _playDefine = bool.fromEnvironment('OVID_PLAY_BUILD');

  /// Test seam: force the Play (true) or sideload (false) behaviour.
  static bool? playOverrideForTest;

  /// True for the Google Play artifact.
  static bool get play => playOverrideForTest ?? _playDefine;

  // -------------------------------------------------------------------------
  // Thin client (P8) — the cloud-execution migration gates.
  //
  // Every consumer keeps BOTH paths compiled (Global Constraints: dies in
  // pieces) and branches on these flags. `OVID_THIN_CLIENT=true` opts a
  // sideload build into the cloud client before Play becomes the default.
  // -------------------------------------------------------------------------

  static const bool _thinDefine = bool.fromEnvironment('OVID_THIN_CLIENT');

  /// Test seam: force thin-client mode on/off. Null falls through to the
  /// compile-time define and the Play channel.
  @visibleForTesting
  static bool? thinOverrideForTest;

  /// True when chat/runs execute in Ovid Cloud instead of on-device.
  static bool get thinClient => thinOverrideForTest ?? (_thinDefine || play);

  /// Chat + runs via cloud (Task 10 flips the consumers).
  static bool get cloudExecution => thinClient;

  /// Remote Studio is live only after Task 15.
  static bool get cloudStudio => thinClient;

  /// Cloud schedules are live only after Task 14.
  static bool get cloudSchedules => thinClient;

  /// Cloud browser is live only after Task 16.
  static bool get cloudBrowser => thinClient;

  /// MCP/plugin runtime is dark until P5.
  static bool get cloudPlugins => false;

  /// BYOK escrow is dark until the P9 escrow endpoints.
  static bool get cloudByok => false;

  /// Accessibility-driven Control mode. Removed entirely in P8 Task 13
  /// (spec D5): false for every channel, not just Play.
  static bool get controlModeAvailable => false;

  /// Termux-style on-device Linux sandbox. Removed entirely in P8 Task 13.
  static bool get onDeviceSandboxAvailable => false;

  /// Idle "Ready & Listening" foreground presence after a run ends.
  static bool get idleKeepAliveAvailable => !play;

  /// Device permissions the agent may ask for. Play builds only declare the
  /// ones a shipped feature uses (browser camera/mic/location, voice input,
  /// notifications); asking for an undeclared permission would just fail.
  static const List<String> allAgentPermissions = [
    'notifications',
    'camera',
    'microphone',
    'storage',
    'photos',
    'videos',
    'audio',
    'contacts',
    'calendar',
    'location',
    'phone',
    'sms',
    'bluetooth',
    'activity_recognition',
    'sensors',
  ];

  static const List<String> _playAgentPermissions = [
    'notifications',
    'camera',
    'microphone',
    'location',
  ];

  static List<String> get agentPermissions =>
      play ? _playAgentPermissions : allAgentPermissions;

  /// User-facing reason shown when a sideload-only capability is requested.
  static const String sandboxUnavailableMessage =
      'The on-device terminal is not part of the Google Play version of Ovid. '
      'Chat, providers, the browser and cloud features work normally; '
      'commands that need a local Linux shell are unavailable.';

  static const String controlUnavailableMessage =
      'Control mode is not available in the Google Play version of Ovid.';
}
