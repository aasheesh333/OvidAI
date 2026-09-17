import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDown(() {
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  test('custom user/agent-created plugins can be created, advertised as tools, executed, and survive reload', () async {
    final app = AppState.createForTest();
    
    // 1. Agent creates custom plugin via catalog_add_plugin
    final createRes = await AgentService.I.dispatchForTest('catalog_add_plugin', {
      'name': 'My Super Custom Helper',
      'description': 'Handles specialized custom workflows',
      'category': 'Custom',
    });
    expect(createRes, contains('created and enabled'));

    // Check that it's added to app state
    final customPlugin = app.plugins.firstWhere((p) => p.name == 'My Super Custom Helper');
    expect(customPlugin.installed, isTrue);
    expect(customPlugin.enabled, isTrue);
    expect(customPlugin.author, 'you');

    // 2. Verified advertised in toolsForTest
    final tools = AgentService.I.toolsForTest();
    final customToolName = 'plugin_my_super_custom_helper';
    expect(
      tools.any((t) => (t['function'] as Map)['name'] == customToolName),
      isTrue,
      reason: 'Custom plugin tool must be in agent roster',
    );

    // 3. Executed via agent tool dispatch
    final execRes = await AgentService.I.dispatchForTest(customToolName, {
      'action': 'doSpecialThing',
      'input': 'my custom input payload',
    });
    expect(execRes, contains('Custom plugin "My Super Custom Helper"'));
    expect(execRes, contains('doSpecialThing'));
    expect(execRes, contains('my custom input payload'));

    // 4. Test rehydration / restart survival
    // Calling internal _loadPluginState to ensure fake-state healing does not remove custom plugin
    await app.initialize();
    final reloadedPlugin = app.plugins.firstWhere((p) => p.name == 'My Super Custom Helper');
    expect(reloadedPlugin.installed, isTrue);
    expect(reloadedPlugin.enabled, isTrue);
  });
}
