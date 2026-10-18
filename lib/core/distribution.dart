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

  /// Cloud browser screencast (P8 Task 16) — the only browser surface now
  /// that the on-device WebView browser is removed.
  static bool get cloudBrowser => thinClient;

  /// MCP/plugin runtime is dark until P5.
  static bool get cloudPlugins => false;

  /// BYOK escrow is live with the P9 escrow endpoints.
  ///
  /// Test seam: force it on/off without a build define.
  @visibleForTesting
  static bool? byokOverrideForTest;

  static bool get cloudByok => byokOverrideForTest ?? true;

  /// Accessibility-driven Control mode. Removed entirely in P8 Task 13
  /// (spec D5): false for every channel, not just Play.
  static bool get controlModeAvailable => false;

  /// Termux-style on-device Linux sandbox. Removed entirely in P8 Task 13.
  static bool get onDeviceSandboxAvailable => false;

  /// Device permissions the app actually declares, for the UI that explains
  /// why a request can fail. This used to be a 15-entry list mirroring the
  /// on-device agent's capability roster; every capability that needed the
  /// broad entries (sandbox T13, device control T13, background agent T12,
  /// on-device browser T16) is gone, so the manifest now declares exactly
  /// these three and the list mirrors it. `test/play_distribution_test.dart`
  /// parses the manifest and fails if the two drift.
  static const List<String> declaredPermissions = [
    'internet',
    'notifications',
    'microphone',
  ];

  /// User-facing reason shown when a sideload-only capability is requested.
  static const String sandboxUnavailableMessage =
      'The on-device terminal is not part of the Google Play version of Ovid. '
      'Chat, providers, the browser and cloud features work normally; '
      'commands that need a local Linux shell are unavailable.';

  static const String controlUnavailableMessage =
      'Control mode is not available in the Google Play version of Ovid.';
}
