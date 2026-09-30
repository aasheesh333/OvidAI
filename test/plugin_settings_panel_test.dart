import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/plugin_settings_panel.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';

/// Schema-driven plugin settings form (audit 2026-09-25): a plugin ships
/// DATA (key, label, secret, hint), the host renders it — no WebView, no JS,
/// no plugin-supplied code ever executes. Values read/write through the
/// EXISTING [NativePluginConfigStore], so `secret: true` fields land in
/// FlutterSecureStorage and never in SharedPreferences (or logs).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // NativePluginConfigStore namespaces keys by slugified plugin name:
  // 'acme/settings-kit' → 'acme_settings_kit'.
  const pluginName = 'acme/settings-kit';
  const endpointPrefsKey = 'native_plugin_acme_settings_kit__endpoint';
  const tokenSecureKey = 'native_plugin_acme_settings_kit__api_token';

  const fields = [
    NativePluginConfigField(
      key: 'endpoint',
      label: 'Endpoint',
      hint: 'Base URL of the API',
    ),
    NativePluginConfigField(
      key: 'api_token',
      label: 'API Token',
      secret: true,
      hint: 'From the dashboard',
    ),
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.createForTest();
  });

  tearDown(() {
    AppState.resetTestInstance();
  });

  Future<void> pumpPanel(
    WidgetTester tester, {
    List<NativePluginConfigField> fields = fields,
    String pluginName = pluginName,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: PluginSettingsPanel(
              pluginName: pluginName,
              fields: fields,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('PluginSettingsPanel renders the declared schema', () {
    testWidgets('one labeled input per field with helper text from hint', (
      tester,
    ) async {
      await pumpPanel(tester);

      expect(
        find.byKey(const ValueKey('plugin-settings-field-endpoint')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('plugin-settings-field-api_token')),
        findsOneWidget,
      );
      // Accessible labels + helper text render.
      expect(find.text('Endpoint'), findsOneWidget);
      expect(find.text('API Token'), findsOneWidget);
      expect(find.text('Base URL of the API'), findsOneWidget);
      expect(find.text('From the dashboard'), findsOneWidget);
    });

    testWidgets('secret fields are masked; plain fields are not', (
      tester,
    ) async {
      await pumpPanel(tester);

      final secret = tester.widget<TextField>(
        find.byKey(const ValueKey('plugin-settings-field-api_token')),
      );
      final plain = tester.widget<TextField>(
        find.byKey(const ValueKey('plugin-settings-field-endpoint')),
      );
      expect(secret.obscureText, isTrue);
      expect(secret.enableSuggestions, isFalse);
      expect(secret.autocorrect, isFalse);
      expect(plain.obscureText, isFalse);
    });

    testWidgets('every input carries a non-empty accessible label', (
      tester,
    ) async {
      await pumpPanel(
        tester,
        fields: const [
          NativePluginConfigField(key: 'raw_key', label: ''),
          NativePluginConfigField(key: 'named', label: 'Named field'),
        ],
      );

      final raw = tester.widget<TextField>(
        find.byKey(const ValueKey('plugin-settings-field-raw_key')),
      );
      final named = tester.widget<TextField>(
        find.byKey(const ValueKey('plugin-settings-field-named')),
      );
      // An empty declared label falls back to the key — never unlabeled.
      expect(raw.decoration!.labelText, isNotEmpty);
      expect(raw.decoration!.labelText, 'raw_key');
      expect(named.decoration!.labelText, 'Named field');
    });

    testWidgets('the save action meets the 44dp tap-target invariant', (
      tester,
    ) async {
      await pumpPanel(tester);

      final size = tester.getSize(
        find.byKey(const ValueKey('plugin-settings-save')),
      );
      expect(size.height, greaterThanOrEqualTo(44));
    });
  });

  group('PluginSettingsPanel reads/writes through NativePluginConfigStore', () {
    testWidgets('loads stored values (secret from secure storage)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        endpointPrefsKey: 'https://stored.example.com',
      });
      FlutterSecureStorage.setMockInitialValues({
        tokenSecureKey: 'stored-secret',
      });

      await pumpPanel(tester);

      expect(find.text('https://stored.example.com'), findsOneWidget);
      final secret = tester.widget<TextField>(
        find.byKey(const ValueKey('plugin-settings-field-api_token')),
      );
      expect(secret.controller!.text, 'stored-secret');
    });

    testWidgets('save routes non-secret to prefs, secret to secure storage', (
      tester,
    ) async {
      await pumpPanel(tester);

      await tester.enterText(
        find.byKey(const ValueKey('plugin-settings-field-endpoint')),
        'https://api.example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('plugin-settings-field-api_token')),
        'sk-secret-77',
      );
      await tester.tap(find.byKey(const ValueKey('plugin-settings-save')));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(endpointPrefsKey),
        'https://api.example.com',
      );
      // The secret is ONLY in secure storage — never in prefs.
      expect(prefs.getString(tokenSecureKey), isNull);
      for (final key in prefs.getKeys()) {
        expect(
          prefs.get(key)?.toString() ?? '',
          isNot(contains('sk-secret-77')),
          reason: 'no prefs entry may hold the secret value',
        );
      }
      const secure = FlutterSecureStorage();
      expect(await secure.read(key: tokenSecureKey), 'sk-secret-77');
      // Honest save feedback.
      expect(find.byKey(const ValueKey('plugin-settings-saved')), findsOneWidget);
    });
  });

  group('configFieldsForSettings shares one model for both plugin kinds', () {
    test('manifest fields mirror into the native config-field shape', () {
      final converted = configFieldsForSettings(const [
        PluginSettingsField(
          pluginId: 'acme/settings-kit',
          key: 'api_token',
          label: 'API Token',
          secret: true,
          hint: 'From the dashboard',
        ),
        PluginSettingsField(
          pluginId: 'acme/settings-kit',
          key: 'raw_key',
          label: '',
        ),
      ]);

      expect(converted.length, 2);
      expect(converted[0].key, 'api_token');
      expect(converted[0].label, 'API Token');
      expect(converted[0].secret, isTrue);
      expect(converted[0].hint, 'From the dashboard');
      // Empty labels fall back to the key — every rendered field is labeled.
      expect(converted[1].label, 'raw_key');
    });
  });

  group('PluginDetailScreen mount', () {
    const manifestId = 'acme/settings-kit';

    NormalizedPluginManifest manifest({
      List<PluginSettingsField> fields = const [
        PluginSettingsField(
          pluginId: manifestId,
          key: 'api_token',
          label: 'API Token',
          secret: true,
          hint: 'From the dashboard',
        ),
      ],
    }) => NormalizedPluginManifest(
      id: manifestId,
      name: 'Settings Kit',
      version: '1.0.0',
      format: PluginFormat.claudeCode,
      rootPath: '/tmp/settings-kit',
      settingsFields: fields,
    );

    PluginItem row() => PluginItem(
      name: 'Settings Kit',
      author: 'acme',
      description: 'declares settings fields',
      version: '1.0.0',
      category: 'Tool',
      installed: true,
      enabled: true,
      runtimeId: manifestId,
      activation: PluginActivation.globalActive,
    );

    Future<void> pumpDetail(WidgetTester tester, PluginItem plugin) async {
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: PluginDetailScreen(plugin: plugin)),
      );
      await tester.pump();
    }

    testWidgets('an installed plugin with declared fields shows a real form', (
      tester,
    ) async {
      PluginContributionRegistry.I.register(
        manifest(),
        activation: PluginActivation.globalActive,
      );
      addTearDown(
        () => PluginContributionRegistry.I.unregisterPlugin(manifestId),
      );
      final plugin = row();
      AppState.I.plugins.add(plugin);

      await pumpDetail(tester, plugin);
      await tester.pumpAndSettle();

      final field = find.byKey(
        const ValueKey('plugin-settings-field-api_token'),
      );
      expect(find.text('SETTINGS'), findsOneWidget);
      expect(field, findsOneWidget);
      expect(tester.widget<TextField>(field).obscureText, isTrue);

      // End-to-end through the detail screen into secure storage.
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, 'sk-mount-1');
      final save = find.byKey(const ValueKey('plugin-settings-save'));
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();

      const secure = FlutterSecureStorage();
      expect(await secure.read(key: tokenSecureKey), 'sk-mount-1');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(tokenSecureKey), isNull);
    });

    testWidgets('no settings section when the plugin declares no fields', (
      tester,
    ) async {
      PluginContributionRegistry.I.register(
        manifest(fields: const []),
        activation: PluginActivation.globalActive,
      );
      addTearDown(
        () => PluginContributionRegistry.I.unregisterPlugin(manifestId),
      );
      final plugin = row();
      AppState.I.plugins.add(plugin);

      await pumpDetail(tester, plugin);
      await tester.pumpAndSettle();

      expect(find.text('SETTINGS'), findsNothing);
      expect(find.byType(PluginSettingsPanel), findsNothing);
    });
  });
}
