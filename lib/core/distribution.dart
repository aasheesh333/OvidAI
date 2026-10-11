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
class Distribution {
  const Distribution._();

  static const bool _playDefine = bool.fromEnvironment('OVID_PLAY_BUILD');

  /// Test seam: force the Play (true) or sideload (false) behaviour.
  static bool? playOverrideForTest;

  /// True for the Google Play artifact.
  static bool get play => playOverrideForTest ?? _playDefine;

  /// Accessibility-driven Control mode (sideload builds only).
  static bool get controlModeAvailable => !play;

  /// Termux-style on-device Linux sandbox (sideload builds only).
  static bool get onDeviceSandboxAvailable => !play;

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
