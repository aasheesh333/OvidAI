import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    AppState.resetTestInstance();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(AppState.resetTestInstance);

  test('fresh state defaults to following the system', () {
    expect(AppState.createForTest().themeMode, 'system');
  });
  test('absent theme preference restores system mode', () async {
    final app = AppState.createForTest();
    await app.initializeForFirstFrame();
    expect(app.themeMode, 'system');
  });
  for (final mode in ['light', 'dark', 'system']) {
    test('saved $mode mode wins over a stale legacy theme flag', () async {
      SharedPreferences.setMockInitialValues({'ovid_theme_mode': mode, 'ovid_light_theme': mode != 'light'});
      final app = AppState.createForTest();
      await app.initializeForFirstFrame();
      expect(app.themeMode, mode);
      if (mode != 'system') expect(app.lightTheme, mode == 'light');
    });
  }
  for (final light in [true, false]) {
    test('legacy explicit light=$light preference is preserved', () async {
      SharedPreferences.setMockInitialValues({'ovid_light_theme': light});
      final app = AppState.createForTest();
      await app.initializeForFirstFrame();
      expect(app.themeMode, light ? 'light' : 'dark');
      expect(app.lightTheme, light);
    });
  }
  test('explicit OpenAI wins over Anthropic URL hints', () {
    for (final url in ['https://api.anthropic.com/v1', 'https://proxy.test/anthropic.com/v1']) {
      final provider = ProviderConfig(name: 'Explicit', description: '', baseUrl: url, apiFormat: ApiFormat.openai);
      expect(provider.effectiveApiFormat, ApiFormat.openai);
    }
  });

  test('retired provider keys are migration offers, never selectable model routes', () async {
    SharedPreferences.setMockInitialValues({
      'ovid_provider_configs_v1': jsonEncode([
        {'id': 'custom-native', 'name': 'My provider', 'baseUrl': 'https://proxy.test/v1', 'custom': true, 'apiFormat': 'anthropic'},
      ]),
    });
    FlutterSecureStorage.setMockInitialValues({'ovid_provider_key_custom-native': 'sk-old-secret'});
    final app = AppState.createForTest();
    await app.loadProviderState();
    await app.loadProviderCredentials();
    expect(app.providers.map((p) => p.id), [AppState.ovidCloudProviderId]);
    expect(app.legacyDeviceKeys.single.name, 'My provider');
    expect(app.legacyDeviceKeys.single.baseUrl, 'https://proxy.test/v1');
    expect(app.legacyDeviceKeys.single.apiKey, 'sk-old-secret');
  });

  test('cloud model cache saves do not erase pending device-key migration metadata', () async {
    SharedPreferences.setMockInitialValues({
      'ovid_provider_configs_v1': jsonEncode([
        {'id': 'custom-native', 'name': 'My provider', 'baseUrl': 'https://proxy.test/v1', 'custom': true, 'apiFormat': 'anthropic'},
      ]),
    });
    FlutterSecureStorage.setMockInitialValues({'ovid_provider_key_custom-native': 'sk-old-secret'});
    var app = AppState.createForTest();
    await app.loadProviderState();
    await app.persistProviderState();
    AppState.resetTestInstance();
    app = AppState.createForTest();
    await app.loadProviderState();
    await app.loadProviderCredentials();
    expect(app.legacyDeviceKeys.single.name, 'My provider');
    expect(app.legacyDeviceKeys.single.baseUrl, 'https://proxy.test/v1');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ovid_provider_configs_v1'), isNot(contains('sk-old-secret')));
  });
}
