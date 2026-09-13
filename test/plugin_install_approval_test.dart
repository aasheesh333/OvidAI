import 'dart:convert';
import 'dart:io';
import 'dart:ffi' as ffi;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/commands.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/plugin_runtime.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

// Agent-path plugin install approval (2026-09-13): when a runtime install
// fails for lack of a capability grant, the agent must surface an approval
// card to the user (Approve → persist grant → retry) instead of failing
// with "capability approval required before install" and no recourse.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory ledgerDir;
  late Directory staging;
  late Directory runtime;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ledgerDir = Directory.systemTemp.createTempSync('pia-ledger-');
    SessionLedger.rootOverrideForTest = ledgerDir;
    SessionSearch.dbPathOverrideForTest = '${ledgerDir.path}/search.db';
    CommandService.exportDirOverrideForTest = ledgerDir.path;
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux, () {
        try {
          return ffi.DynamicLibrary.open('libsqlite3.so.0');
        } catch (_) {
          return ffi.DynamicLibrary.open(
            '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
          );
        }
      });
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    staging = Directory.systemTemp.createTempSync('pia-staging-');
    runtime = Directory.systemTemp.createTempSync('pia-runtime-');
    PluginRuntimeManager.stagingRootOverrideForTest = staging;
    PluginRuntimeManager.runtimeRootOverrideForTest = runtime;
    PluginRuntimeManager.failRenameForTest = false;
    AppState.resetTestInstance();
  });

  tearDown(() async {
    AgentService.setRunSessionForTest('');
    PluginRuntimeManager.stagingRootOverrideForTest = null;
    PluginRuntimeManager.runtimeRootOverrideForTest = null;
    PluginRuntimeManager.failRenameForTest = false;
    for (final n in ['piaorg/approval-kit', 'piaorg/deny-kit']) {
      PluginContributionRegistry.I.unregisterPlugin(n);
    }
    try {
      staging.deleteSync(recursive: true);
    } catch (_) {}
    try {
      runtime.deleteSync(recursive: true);
    } catch (_) {}
    AppState.resetTestInstance();
  });

  Directory fixture(String name) {
    final dir = Directory.systemTemp.createTempSync('pia-plugin-src-');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    Directory('${dir.path}/.claude-plugin').createSync(recursive: true);
    File('${dir.path}/.claude-plugin/plugin.json').writeAsStringSync(
      jsonEncode({'name': name, 'author': 'piaorg', 'version': '1.0.0'}),
    );
    Directory('${dir.path}/commands').createSync(recursive: true);
    File('${dir.path}/commands/review.md').writeAsStringSync(
      '---\ndescription: PIA command\n---\nPIA BODY',
    );
    return dir;
  }

  Future<AppState> boot() async {
    final app = AppState.createForTest();
    await app.initialize();
    return app;
  }

  Future<ApprovalRequest?> waitForApproval() async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (AgentService.I.pendingApproval == null) {
      if (DateTime.now().isAfter(deadline)) return null;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return AgentService.I.pendingApproval;
  }

  test(
    'agent install without a grant surfaces an approval card, and approval installs',
    () async {
      final app = await boot();
      final src = fixture('Approval Kit');
      final row = PluginItem(
        name: 'PIA Approval Kit',
        author: 'piaorg',
        description: 'PIA fixture',
        version: '1.0.0',
        category: 'Tool',
      );
      app.plugins.add(row);
      final s = ChatSession(
        id: 'pia-s1',
        title: 'S1',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.insert(0, s);
      AgentService.setRunSessionForTest(s.id);

      final fut = AgentService.I.dispatchForTest('agent_install_plugin', {
        'plugin_name': 'PIA Approval Kit',
        'local_path': src.path,
      });
      final req = await waitForApproval();
      expect(
        req,
        isNotNull,
        reason:
            'agent must surface an approval card instead of failing with '
            '"capability approval required before install" and no recourse',
      );
      expect(req!.tool, 'agent_install_plugin');
      expect(req.summary.toLowerCase(), contains('approv'));
      // The card must name the requested capability so the user can judge.
      expect(req.detail.toLowerCase(), contains('workspace'));

      AgentService.I.approve(true);
      final res = await fut.timeout(const Duration(seconds: 90));
      expect(res, contains('installed'));
      expect(res, isNot(contains('failed')));
      expect(row.installed, isTrue);
      expect(row.runtimeId, 'piaorg/approval-kit');
    },
  );

  test('denying the approval card fails the install honestly', () async {
    final app = await boot();
    final src = fixture('Deny Kit');
    final row = PluginItem(
      name: 'PIA Deny Kit',
      author: 'piaorg',
      description: 'PIA fixture',
      version: '1.0.0',
      category: 'Tool',
    );
    app.plugins.add(row);
    final s = ChatSession(
      id: 'pia-s2',
      title: 'S2',
      model: 'm',
      mode: 'auto',
    );
    app.sessions.insert(0, s);
    AgentService.setRunSessionForTest(s.id);

    final fut = AgentService.I.dispatchForTest('agent_install_plugin', {
      'plugin_name': 'PIA Deny Kit',
      'local_path': src.path,
    });
    final req = await waitForApproval();
    expect(req, isNotNull);

    AgentService.I.approve(false);
    final res = await fut.timeout(const Duration(seconds: 90));
    expect(res.toLowerCase(), contains('declin'));
    expect(row.installed, isFalse);
  });
}
