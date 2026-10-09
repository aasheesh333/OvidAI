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
      SharedPreferences.setMockInitialValues({
        'ovid_theme_mode': mode,
        'ovid_light_theme': mode != 'light',
      });
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
    for (final url in [
      'https://api.anthropic.com/v1',
      'https://proxy.test/anthropic.com/v1',
    ]) {
      final provider = ProviderConfig(
        name: 'Explicit',
        description: '',
        baseUrl: url,
        apiFormat: ApiFormat.openai,
      );
      expect(provider.effectiveApiFormat, ApiFormat.openai);
    }
  });

  test('legacy custom and seeded protocols survive load and save', () async {
    SharedPreferences.setMockInitialValues({
      'ovid_provider_configs_v1': jsonEncode([
        {'id': 'anthropic', 'baseUrl': 'https://proxy.test/v1'},
        {'id': 'openai', 'baseUrl': 'https://api.anthropic.com/v1'},
        for (final row in [
          {'id': 'custom-legacy', 'baseUrl': 'https://api.anthropic.com/v1'},
          {
            'id': 'custom-openai',
            'baseUrl': 'https://api.anthropic.com/v1',
            'apiFormat': 'openai',
          },
          {'id': 'custom-proxy', 'baseUrl': 'https://proxy.test/v1'},
          {
            'id': 'custom-native',
            'baseUrl': 'https://proxy.test/v1',
            'apiFormat': 'anthropic',
          },
        ])
          {...row, 'custom': true},
      ]),
    });
    var app = AppState.createForTest();
    await app.loadProviderState();
    final expected = {
      'anthropic': ApiFormat.anthropic,
      'openai': ApiFormat.anthropic,
      'custom-legacy': ApiFormat.anthropic,
      'custom-openai': ApiFormat.openai,
      'custom-proxy': ApiFormat.openai,
      'custom-native': ApiFormat.anthropic,
    };
    for (final entry in expected.entries) {
      expect(
        app.providerById(entry.key)!.effectiveApiFormat,
        entry.value,
        reason: entry.key,
      );
      expect(
        app.providerById(entry.key)!.toPersistedJson()['apiFormat'],
        entry.value.wire,
        reason: 'migration must persist for ${entry.key}',
      );
    }
    await app.persistProviderState();
    AppState.resetTestInstance();
    app = AppState.createForTest();
    await app.loadProviderState();
    for (final entry in expected.entries) {
      expect(app.providerById(entry.key)!.effectiveApiFormat, entry.value);
    }
  });

  test(
    'custom descriptions follow protocol changes and survive reload',
    () async {
      var app = AppState.createForTest();
      expect(
        await app.addCustomProvider(
          name: 'Native',
          baseUrl: 'https://api.anthropic.com/v1',
          apiFormat: ApiFormat.anthropic,
        ),
        isNull,
      );
      var provider = app.providerById('custom-native')!;
      expect(provider.description, contains('Anthropic'));
      expect(provider.description, isNot(contains('OpenAI')));
      await app.updateProviderApiFormat(provider, ApiFormat.openai);
      expect(provider.effectiveApiFormat, ApiFormat.openai);
      expect(provider.description, contains('OpenAI'));
      AppState.resetTestInstance();
      app = AppState.createForTest();
      await app.loadProviderState();
      provider = app.providerById('custom-native')!;
      expect(provider.effectiveApiFormat, ApiFormat.openai);
      expect(provider.description, contains('OpenAI'));
      await app.updateProviderDescription(provider, 'My own description');
      await app.updateProviderApiFormat(provider, ApiFormat.anthropic);
      expect(provider.description, 'My own description');
    },
  );
}
