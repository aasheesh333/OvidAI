import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

/// A custom/agent-authored plugin with no mounted skill files used to answer
/// EVERY action name with "executed successfully" — including actions that do
/// not exist — and returned no content. That is the worst failure mode: a
/// stub that reports success regardless of input, so the model (and the user)
/// believe work happened when nothing did.
///
/// The generic plugin tool must never synthesise success.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final agent = AgentService.I;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    final a = AppState.createForTest();
    a.plugins.clear();
    a.sessions.clear();
    a.activeSessionId = null;
    AgentService.setRunSessionForTest('');
    // The legacy plugin dispatcher is gated on the safety reconciliation
    // having run; force it so the test exercises the real dispatch path.
    a.markPluginSafetyReconciledForTest();
  });

  tearDown(() {
    AgentService.setRunSessionForTest('');
    AppState.resetTestInstance();
  });

  PluginItem customPlugin() => PluginItem(
    name: 'Widgets',
    author: 'you',
    description: 'Test plugin',
    version: '1.0',
    category: 'Tool',
    installed: true,
    enabled: true,
  );

  test('an unknown action never reports success', () async {
    AppState.I.plugins.add(customPlugin());
    final res = await agent.dispatchForTest('plugin_widgets', {
      'action': 'this-action-does-not-exist-xyz',
    });
    expect(res.toLowerCase(), isNot(contains('executed successfully')));
    expect(res, contains('this-action-does-not-exist-xyz'));
  });

  test('a bare custom action is honest about not being executable', () async {
    AppState.I.plugins.add(customPlugin());
    final res = await agent.dispatchForTest('plugin_widgets', {
      'action': 'build',
      'input': 'hello',
    });
    expect(res.toLowerCase(), isNot(contains('executed successfully')));
    expect(res, contains('hello'));
  });

  test('no action specified says so honestly', () async {
    AppState.I.plugins.add(customPlugin());
    final res = await agent.dispatchForTest('plugin_widgets', {});
    expect(res.toLowerCase(), isNot(contains('executed successfully')));
  });
}
