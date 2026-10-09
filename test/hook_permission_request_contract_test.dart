import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  const id = 'contract/permission';

  void register({String event = 'permission_request'}) {
    PluginContributionRegistry.I.register(
      NormalizedPluginManifest(
        id: id,
        name: 'permission',
        version: '1',
        format: PluginFormat.claudeCode,
        rootPath: root.path,
        hooks: [PluginHook(
          pluginId: id,
          event: event,
          ordinal: 0,
          type: 'command',
          payload: 'decide',
        )],
      ),
      activation: PluginActivation.sessionActive,
      immediateSessionId: 'a',
    );
  }

  String output(String behavior, {bool rewrite = false}) => jsonEncode({
    'hookSpecificOutput': {
      'hookEventName': 'PermissionRequest',
      'decision': {
        'behavior': behavior,
        if (behavior == 'deny') 'message': 'Policy refused this request',
        if (rewrite) 'updatedInput': {'command': 'npm run lint'},
      },
    },
  });

  Future<HookGateResult> fire([String sid = 'a', String event = 'permission_request']) =>
      HookService.I.fireGate(event, sid, payload: {
        'tool': 'run_shell',
        'args': {'command': 'npm test'},
      });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest(pluginBootActivator: (_, _) async {});
    root = Directory.systemTemp.createTempSync('hook-permission-');
    app.sessions.add(ChatSession(id: 'a', title: 'A', model: 'test', workspaceFolder: root.path));
    SessionLedger.rootOverrideForTest = Directory('${root.path}/ledger');
    HookService.I.resetForTest();
    HookService.I.enabled = true;
    register();
  });
  tearDown(() async {
    PluginContributionRegistry.I.unregisterPlugin(id);
    HookService.I.resetForTest();
    SessionLedger.rootOverrideForTest = null;
    AppState.resetTestInstance();
    await root.delete(recursive: true);
  });

  test('documented deny blocks and returns its message without rewrite', () async {
    HookService.I.executorForTest = (_, _) async => output('deny', rewrite: true);
    final result = await fire();
    expect(result.decision, HookDecision.deny);
    expect(result.reason, 'Policy refused this request');
    expect(result.updatedInput, isNull);
    expect(result.bypassPermission, isFalse);
  });

  test('documented allow returns replacement input and one-call approval', () async {
    HookService.I.executorForTest = (_, _) async => output('allow', rewrite: true);
    final result = await fire();
    expect(result.bypassPermission, isTrue);
    expect(result.updatedInput, {'command': 'npm run lint'});
    expect((await fire('b')).bypassPermission, isFalse);
  });

  test('PermissionRequest envelope cannot approve a PreToolUse gate', () async {
    register(event: 'pre_tool');
    HookService.I.executorForTest = (_, _) async => output('allow', rewrite: true);
    final result = await fire('a', 'pre_tool');
    expect(result.bypassPermission, isFalse);
    expect(result.updatedInput, isNull);
  });

  test('unregistered hook cannot publish a late permission decision', () async {
    final entered = Completer<void>();
    final response = Completer<String>();
    HookService.I.executorForTest = (_, _) {
      entered.complete();
      return response.future;
    };
    final pending = fire();
    await entered.future;
    PluginContributionRegistry.I.unregisterPlugin(id);
    response.complete(output('allow', rewrite: true));
    final result = await pending;
    expect(result.bypassPermission, isFalse);
    expect(result.updatedInput, isNull);
  });
}
