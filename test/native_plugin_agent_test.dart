import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeJsonCapability implements NativePluginCapability {
  String lastTool = '';
  Map<String, dynamic> lastArgs = {};

  @override
  String get pluginName => 'JSON Visualizer';

  @override
  List<NativePluginConfigField> get configFields => const [
        NativePluginConfigField(key: 'api_key', label: 'API Key', secret: true),
        NativePluginConfigField(key: 'base_url', label: 'Base URL'),
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
        NativePluginTool(
          name: 'minify',
          description: 'Minify JSON',
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
    lastTool = toolName;
    lastArgs = Map<String, dynamic>.from(args);
    return 'ok:$toolName:${args['json_string'] ?? ''}';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeJsonCapability capability;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NativePluginRegistry.I.clearForTest();
    capability = _FakeJsonCapability();
    NativePluginRegistry.I.register(capability);
  });

  tearDown(() {
    NativePluginRegistry.I.clearForTest();
    AgentService.setRunSessionForTest('');
    // Restore the seeded JSON Visualizer row to its catalog defaults.
    try {
      final row =
          AppState.I.plugins.firstWhere((p) => p.name == 'JSON Visualizer');
      row.installed = false;
      row.enabled = false;
    } catch (_) {}
  });

  PluginItem jsonRow() =>
      AppState.I.plugins.firstWhere((p) => p.name == 'JSON Visualizer');

  List<String> rosterNames() => AgentService.I.toolsForTest()
      .map((t) => ((t['function'] as Map)['name']).toString())
      .toList();

  test('installed+enabled native plugin tools appear in roster', () {
    final row = jsonRow();
    row.installed = true;
    row.enabled = true;

    final names = rosterNames();
    expect(names, contains('plugin__json_visualizer__format'));
    expect(names, contains('plugin__json_visualizer__minify'));
    expect(
      AgentService.I.pluginToolNames(row),
      containsAll([
        'plugin__json_visualizer__format',
        'plugin__json_visualizer__minify',
      ]),
    );
  });

  test('disabling the plugin removes its tools from roster', () {
    final row = jsonRow();
    row.installed = true;
    row.enabled = true;
    expect(rosterNames(), contains('plugin__json_visualizer__format'));

    row.enabled = false;
    expect(rosterNames(), isNot(contains('plugin__json_visualizer__format')));
    expect(rosterNames(), isNot(contains('plugin__json_visualizer__minify')));
    expect(AgentService.I.pluginToolNames(row), isEmpty);
  });

  test('plugin__ dispatch invokes capability.callTool', () async {
    final row = jsonRow();
    row.installed = true;
    row.enabled = true;

    final out = await AgentService.I.dispatchForTest(
      'plugin__json_visualizer__format',
      {'json_string': '{"a":1}'},
    );
    expect(capability.lastTool, 'format');
    expect(capability.lastArgs['json_string'], '{"a":1}');
    expect(out, contains('ok:format'));
  });

  test('catalog_configure_plugin updates capability configuration', () async {
    final row = jsonRow();
    row.installed = true;
    row.enabled = true;

    final out = await AgentService.I.dispatchForTest(
      'catalog_configure_plugin',
      {
        'plugin': 'JSON Visualizer',
        'settings': {'base_url': 'https://example.com'},
      },
    );
    expect(out, contains('configured'));
    final stored = await NativePluginConfigStore.I.read(
      pluginName: 'JSON Visualizer',
      key: 'base_url',
    );
    expect(stored, 'https://example.com');
  });
}
