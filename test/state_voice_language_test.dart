import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/v2/chat/composer_voice.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppState.resetTestInstance();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(AppState.resetTestInstance);

  test('voice language is unset until the user picks one', () {
    final app = AppState.createForTest();
    expect(app.voiceLanguage, isEmpty);
  });

  test('setter persists the id under ovid_voice_language', () async {
    final app = AppState.createForTest();
    await app.setVoiceLanguage('ta');

    expect(app.voiceLanguage, 'ta');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ovid_voice_language'), 'ta');
  });

  test('a saved language is read back after a restart', () async {
    SharedPreferences.setMockInitialValues({'ovid_voice_language': 'hinglish'});
    final app = AppState.createForTest();
    await app.initializeForFirstFrame();

    expect(app.voiceLanguage, 'hinglish');
  });

  test('an unsupported or corrupt preference falls back to unset', () async {
    SharedPreferences.setMockInitialValues({'ovid_voice_language': 'klingon'});
    final app = AppState.createForTest();
    await app.initializeForFirstFrame();

    expect(app.voiceLanguage, isEmpty);
  });

  test('unknown ids are ignored and never persisted', () async {
    final app = AppState.createForTest();
    await app.setVoiceLanguage('klingon');

    expect(app.voiceLanguage, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ovid_voice_language'), isNull);
  });

  test(
    'the composer uses the saved language over the device language',
    () async {
      final app = AppState.createForTest();
      await app.setVoiceLanguage('pa');

      expect(V2VoiceLocales.deviceLanguage(), 'pa');
      expect(
        V2VoiceLocales.localeFor(V2VoiceLocales.deviceLanguage()),
        'pa-IN',
      );
    },
  );

  test('with no saved language the composer still follows the device', () {
    AppState.createForTest();
    final id = V2VoiceLocales.deviceLanguage();

    expect(AppState.voiceLanguageIds, contains(id));
  });
}
