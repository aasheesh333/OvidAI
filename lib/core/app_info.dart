/// Single source of truth for the user-facing app version.
///
/// Keep in sync with `version:` in pubspec.yaml (no package_info_plus
/// dependency, so this constant is the canonical string the UI shows).
/// Format: the human-readable part before `+` in the pubspec version.
const kAppVersion = '1.0.0';
