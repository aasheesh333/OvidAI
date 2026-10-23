/// Distribution channel gates.
///
/// A Google Play build is produced with `--dart-define=OVID_PLAY_BUILD=true`.
/// The same define drives the native side (android/app/build.gradle.kts reads
/// Flutter's forwarded dart-defines): the src/play manifest overlay without
/// the AccessibilityService. Every build (Play or sideload) targets SDK 36 and
/// bundles no Linux userland.
///
/// P8 Task 20 collapsed the thin-client migration scaffolding: the app has no
/// local execution path any more (spec NG3), so the cloud surfaces are plain
/// `true` constants rather than channel/define gates. What remains here is
/// channel packaging (`play`) and the still-dark P5 plugin runtime.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

class Distribution {
  const Distribution._();

  static const bool _playDefine = bool.fromEnvironment('OVID_PLAY_BUILD');

  /// Billing demo: `--dart-define=OVID_BILLING_DEMO=true`.
  ///
  /// Play monetization is not approved yet, so an internal test build has no
  /// working store. This flag lets plan selection work locally — no charge, no
  /// store call — so the paywall and every paid surface can be exercised.
  ///
  /// It is deliberately **refused in a Play artifact**: a build that can be
  /// uploaded to the store must never grant a plan for free. The combination
  /// is the guard, not the flag alone.
  static const bool _billingDemoDefine = bool.fromEnvironment(
    'OVID_BILLING_DEMO',
  );

  /// Test seam: force the demo on/off without a build define.
  static bool? billingDemoOverrideForTest;

  /// True when this build may grant a plan without a purchase.
  static bool get billingDemo =>
      billingDemoOverrideForTest ?? (_billingDemoDefine && !play);

  /// Test seam: force the Play (true) or sideload (false) behaviour.
  static bool? playOverrideForTest;

  /// True for the Google Play artifact.
  static bool get play => playOverrideForTest ?? _playDefine;

  // -------------------------------------------------------------------------
  // Thin client (P8) — the only implementation since Task 19.
  //
  // There is no `OVID_THIN_CLIENT` opt-in and no on-device fallback: chat and
  // runs execute on Ovid Cloud, Studio is remote, schedules are server rows
  // and the browser is the cloud screencast. Consumers render the cloud arm
  // directly; these constants exist so the surface stays greppable while the
  // last references are removed.
  // -------------------------------------------------------------------------

  /// Chat + runs via cloud.
  static const bool cloudExecution = true;

  /// Remote Studio.
  static const bool cloudStudio = true;

  /// Cloud schedules.
  static const bool cloudSchedules = true;

  /// Cloud browser screencast (P8 Task 16) — the only browser surface now
  /// that the on-device WebView browser is removed.
  static const bool cloudBrowser = true;

  /// MCP/plugin runtime is dark until P5.
  static const bool cloudPlugins = false;

  /// BYOK escrow is live with the P9 escrow endpoints.
  ///
  /// Test seam: force it on/off without a build define.
  @visibleForTesting
  static bool? byokOverrideForTest;

  static bool get cloudByok => byokOverrideForTest ?? true;

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
}
