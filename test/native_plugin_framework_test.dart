import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeCapability implements NativePluginCapability {
  @override
  String get pluginName => 'JSON Visualizer';

  @override
  List<NativePluginConfigField> get configFields => const [
        NativePluginConfigField(
          key: 'api_key',
          label: 'API Key',
          secret: true,
        ),
        NativePluginConfigField(
          key: 'base_url',
          label: 'Base URL',
        ),
      ];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'format',
          description: 'Format JSON',
          inputSchema: {
            'type': 'object',
            'properties': {
              'json_string': {'type': 'string'},
            },
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) {
    return NativePluginConfigStore.I.save(
      pluginName: pluginName,
      fields: configFields,
      values: values,
    );
  }

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    return 'ok:$toolName';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NativePluginRegistry.I.clearForTest();
  });

  test('registration and lookup by name (case-insensitive) and slug', () {
    final capability = FakeCapability();
    NativePluginRegistry.I.register(capability);

    expect(NativePluginRegistry.I.has('JSON Visualizer'), isTrue);
    expect(NativePluginRegistry.I.has('json visualizer'), isTrue);
    expect(NativePluginRegistry.I.has('JSON VISUALIZER'), isTrue);
    expect(NativePluginRegistry.I.has('Unknown Plugin'), isFalse);

    expect(
      NativePluginRegistry.I.capabilityFor('json VISUALIZER')?.pluginName,
      'JSON Visualizer',
    );
    expect(
      NativePluginRegistry.I.capabilityForSlug('json_visualizer')?.pluginName,
      'JSON Visualizer',
    );
    expect(NativePluginRegistry.I.all.length, 1);
  });

  test('secret vs non-secret configuration storage and isolation',
      () async {
    final capability = FakeCapability();
    NativePluginRegistry.I.register(capability);

    await capability.configure({
      'api_key': 'super-secret-value',
      'base_url': 'https://example.com',
    });

    final secret = await NativePluginConfigStore.I.read(
      pluginName: capability.pluginName,
      key: 'api_key',
      secret: true,
    );
    final nonSecret = await NativePluginConfigStore.I.read(
      pluginName: capability.pluginName,
      key: 'base_url',
    );
    expect(secret, 'super-secret-value');
    expect(nonSecret, 'https://example.com');

    // Isolation: secret must live in secure storage, never in prefs;
    // non-secret must live in prefs, never in secure storage.
    final prefs = await SharedPreferences.getInstance();
    const secure = FlutterSecureStorage();
    final slug = NativePluginRegistry.I.slugFor(capability.pluginName);
    expect(prefs.getString('native_plugin_${slug}__api_key'), isNull);
    expect(
      await secure.read(key: 'native_plugin_${slug}__api_key'),
      'super-secret-value',
    );
    expect(
      prefs.getString('native_plugin_${slug}__base_url'),
      'https://example.com',
    );
    expect(
      await secure.read(key: 'native_plugin_${slug}__base_url'),
      isNull,
    );
  });

  test('save rejects unknown configuration keys', () async {
    final capability = FakeCapability();
    NativePluginRegistry.I.register(capability);

    await expectLater(
      capability.configure({'bogus_key': 'x'}),
      throwsA(isA<ArgumentError>()),
    );

    // Nothing from the rejected batch may persist anywhere.
    final prefs = await SharedPreferences.getInstance();
    const secure = FlutterSecureStorage();
    final slug = NativePluginRegistry.I.slugFor(capability.pluginName);
    expect(prefs.getString('native_plugin_${slug}__bogus_key'), isNull);
    expect(
      await secure.read(key: 'native_plugin_${slug}__bogus_key'),
      isNull,
    );
  });

  test('slug normalization', () {
    expect(
      NativePluginRegistry.I.slugFor('JSON Visualizer'),
      'json_visualizer',
    );
    expect(
      NativePluginRegistry.I.slugFor('  Color Palette Gen  '),
      'color_palette_gen',
    );
    expect(
      NativePluginRegistry.I.slugFor('Web Scraper Pro'),
      'web_scraper_pro',
    );
  });
}
