import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// TODO(l10n): the keys and the supported id set are not copy, but the labels
// that go with them live in the ARB files.

/// SharedPreferences key for the v2 onboarding welcome marker. It is separate
/// from `AppState`'s in-app welcome notice (`ovid_welcome`) so finishing the
/// onboarding tour never suppresses that unrelated notice, and vice versa.
const String kV2WelcomeSeenPref = 'ovid_welcome_version_v2';

/// Default onboarding welcome version. Bump to show the tour again.
const String kV2OnboardingWelcomeVersion = '1';

/// Durable key for the language picked during onboarding.
///
/// It is deliberately **not** `ovid_locale`: `AppState` owns that key for the
/// reply-language preference and only accepts `system`/`en`/`zh`. Writing
/// `hi`/`pa`/`ta` there used to poison `AppState.localePref` with values it
/// can never produce itself.
const String kV2OnboardingLanguagePref = 'ovid_onboarding_language';

/// Durable key for the first goal(s) picked during onboarding.
const String kV2FirstGoalPref = 'ovid_first_goal';

/// The legacy key the gate wrote the onboarding language to before
/// [kV2OnboardingLanguagePref] existed. Read once for migration only.
const String kV2LegacyLocalePref = 'ovid_locale';

/// Language ids the onboarding grid can offer.
const Set<String> kV2OnboardingLanguageIds = {'en', 'hi', 'pa', 'ta'};

/// Everything the gate needs from disk to decide where onboarding starts.
@immutable
class V2OnboardingSnapshot {
  const V2OnboardingSnapshot({
    required this.welcomeSeen,
    this.languageId,
    this.goalIds = const <String>{},
  });

  /// The stored welcome marker matched the current version.
  final bool welcomeSeen;

  /// The language picked in a previous run, or null when the person has not
  /// reached the language step yet.
  final String? languageId;

  /// The goal ids picked in a previous run (empty when none were saved).
  final Set<String> goalIds;

  /// A returning user who already picked a language skips the language step.
  bool get hasChoices => languageId != null;
}

/// Durable store for the first-run choices.
///
/// This is the state seam for onboarding: the gate never keeps a choice only
/// in a widget field, and a restart re-reads exactly what was written. It is a
/// class (rather than a set of top-level functions) so tests can inject a fake
/// that blocks or fails, and so the gate can report a real save failure.
class V2OnboardingStore {
  const V2OnboardingStore();

  /// Reads the welcome marker, language and goals.
  ///
  /// Throws when SharedPreferences itself is unavailable, so the gate can
  /// surface a real error instead of silently starting over.
  Future<V2OnboardingSnapshot> load({required String welcomeVersion}) async {
    final prefs = await SharedPreferences.getInstance();
    final welcomeSeen =
        prefs.getString(kV2WelcomeSeenPref) == welcomeVersion;

    final saved = _cleanLanguage(prefs.getString(kV2OnboardingLanguagePref));
    // Migrate the old, colliding key only for people who finished the old
    // tour. A fresh install with `ovid_locale` from Settings must not look
    // like an onboarding choice.
    final legacy = welcomeSeen
        ? _cleanLanguage(prefs.getString(kV2LegacyLocalePref))
        : null;

    final goals = (prefs.getString(kV2FirstGoalPref) ?? '')
        .split(',')
        .where((id) => id.isNotEmpty)
        .toSet();

    return V2OnboardingSnapshot(
      welcomeSeen: welcomeSeen,
      languageId: saved ?? legacy,
      goalIds: goals,
    );
  }

  /// Persists the welcome marker. Throws on failure so the gate can retry.
  Future<void> markWelcomeSeen(String version) async {
    final prefs = await SharedPreferences.getInstance();
    final ok = await prefs.setString(kV2WelcomeSeenPref, version);
    if (!ok) throw StateError('could not persist the welcome marker');
  }

  /// Persists both first-run choices together. Throws on failure.
  Future<void> saveChoices({
    required String languageId,
    required Set<String> goalIds,
  }) async {
    if (!kV2OnboardingLanguageIds.contains(languageId)) {
      throw ArgumentError.value(languageId, 'languageId', 'unsupported');
    }
    final prefs = await SharedPreferences.getInstance();
    final sorted = goalIds.toList()..sort();
    final languageOk = await prefs.setString(
      kV2OnboardingLanguagePref,
      languageId,
    );
    final goalsOk = await prefs.setString(
      kV2FirstGoalPref,
      sorted.join(','),
    );
    if (!languageOk || !goalsOk) {
      throw StateError('could not persist the onboarding choices');
    }
  }

  static String? _cleanLanguage(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return null;
    return kV2OnboardingLanguageIds.contains(value) ? value : null;
  }
}
