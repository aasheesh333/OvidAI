/// Single source of truth for the user-facing app version (SE-026).
///
/// The release workflow passes `--dart-define=OVID_BUILD=<git sha>` (and may
/// pass `OVID_VERSION` / `OVID_BUILD_NUMBER`); local builds fall back to the
/// pubspec version. Support can tell builds apart from [kAppVersionLabel].
const kAppVersion = String.fromEnvironment(
  'OVID_VERSION',
  defaultValue: '1.0.0',
);

/// The pubspec build number (`+N`), overridable per build.
const kAppBuildNumber = String.fromEnvironment(
  'OVID_BUILD_NUMBER',
  defaultValue: '1',
);

/// The commit the build came from (CI passes the full sha), or empty.
const kAppBuildSha = String.fromEnvironment('OVID_BUILD');

/// `1.0.0 (build 1, abc1234)` — shown in About and Service status.
String get kAppVersionLabel {
  final sha = kAppBuildSha.length > 7
      ? kAppBuildSha.substring(0, 7)
      : kAppBuildSha;
  return sha.isEmpty
      ? '$kAppVersion (build $kAppBuildNumber)'
      : '$kAppVersion (build $kAppBuildNumber, $sha)';
}
