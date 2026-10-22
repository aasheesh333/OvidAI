import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/v2/onboarding/onboarding_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('V2OnboardingStore choices', () {
    test('writes both choices and reads them back on the next launch', () async {
      final store = V2OnboardingStore();
      await store.saveChoices(
        languageId: 'hi',
        goalIds: {'write', 'research'},
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kV2OnboardingLanguagePref), 'hi');
      // Sorted so the same choice always produces the same stored value.
      expect(prefs.getString(kV2FirstGoalPref), 'research,write');

      final snapshot = await store.load(
        welcomeVersion: kV2OnboardingWelcomeVersion,
      );
      expect(snapshot.languageId, 'hi');
      expect(snapshot.goalIds, {'research', 'write'});
    });

    test('rejects an unsupported language before touching either key', () async {
      final store = V2OnboardingStore();
      await expectLater(
        store.saveChoices(languageId: 'fr', goalIds: {'build'}),
        throwsArgumentError,
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kV2OnboardingLanguagePref), isNull);
      expect(prefs.getString(kV2FirstGoalPref), isNull);
    });

    test('persists an empty goal set without inventing a goal', () async {
      final store = V2OnboardingStore();
      await store.saveChoices(languageId: 'en', goalIds: const <String>{});

      final snapshot = await store.load(
        welcomeVersion: kV2OnboardingWelcomeVersion,
      );
      expect(snapshot.languageId, 'en');
      expect(snapshot.goalIds, isEmpty);
    });

    test('ignores ids this build cannot show and trims stored goals', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kV2WelcomeSeenPref: kV2OnboardingWelcomeVersion,
        kV2OnboardingLanguagePref: 'fr',
        kV2FirstGoalPref: ' build, research, , ',
        kV2OnboardingCurrencyPref: 'eur',
      });
      final store = V2OnboardingStore();

      final snapshot = await store.load(
        welcomeVersion: kV2OnboardingWelcomeVersion,
      );

      expect(snapshot.languageId, isNull);
      expect(snapshot.goalIds, {'build', 'research'});
      expect(snapshot.currencyId, isNull);
    });
  });

  group('V2OnboardingStore migration', () {
    test('reads the legacy locale only after the welcome marker', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kV2LegacyLocalePref: 'ta',
      });
      final store = V2OnboardingStore();

      final fresh = await store.load(
        welcomeVersion: kV2OnboardingWelcomeVersion,
      );
      expect(fresh.welcomeSeen, isFalse);
      expect(
        fresh.languageId,
        isNull,
        reason: 'a Settings locale must not look like an onboarding choice',
      );
    });

    test('migrates the legacy locale for a finished tour', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kV2WelcomeSeenPref: kV2OnboardingWelcomeVersion,
        kV2LegacyLocalePref: 'ta',
      });
      final store = V2OnboardingStore();

      final snapshot = await store.load(
        welcomeVersion: kV2OnboardingWelcomeVersion,
      );
      expect(snapshot.welcomeSeen, isTrue);
      expect(snapshot.languageId, 'ta');
    });

    test('the current language key wins over the legacy key', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kV2WelcomeSeenPref: kV2OnboardingWelcomeVersion,
        kV2LegacyLocalePref: 'en',
        kV2OnboardingLanguagePref: 'pa',
      });
      final store = V2OnboardingStore();

      final snapshot = await store.load(
        welcomeVersion: kV2OnboardingWelcomeVersion,
      );
      expect(snapshot.languageId, 'pa');
    });
  });
}
