import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/commands.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

// Tool approval "Always allow for this command" (2026-09-13): in Studio
// (and everywhere the approval card appears for plain tools), the user gets
// Allow / Deny / Always. Always-allow is remembered per session; the next
// call of the same tool proceeds without prompting. Destructive commands,
// plugin installs, device permissions, questions and plan reviews never
// offer it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory ledgerDir;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ledgerDir = Directory.systemTemp.createTempSync('aaa-ledger-');
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
    AppState.resetTestInstance();
  });

  tearDown(() async {
    AgentService.setRunSessionForTest('');
    AppState.resetTestInstance();
  });

  Future<ChatSession> testSession(String id, {String mode = 'safe'}) async {
    final app = AppState.createForTest();
    await app.initialize();
    final s = ChatSession(id: id, title: 'S', model: 'm', mode: mode);
    app.sessions.insert(0, s);
    app.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
    addTearDown(() {
      AgentService.setRunSessionForTest('');
      app.activeSessionId = null;
      app.sessions.removeWhere((x) => x.id == s.id);
    });
    return s;
  }

  Future<ApprovalRequest?> waitForApproval() async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (AgentService.I.pendingApproval == null) {
      if (DateTime.now().isAfter(deadline)) return null;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return AgentService.I.pendingApproval;
  }

  test('tool approval offers Always; remembered tool skips prompts', () async {
    await testSession('aaa-1');
    final fut = AgentService.I.dispatchForTest('browser_open', {
      'url': 'https://example.com',
    });
    final req = await waitForApproval();
    expect(req, isNotNull, reason: 'browser_open must prompt in safe mode');
    expect(req!.allowAlways, isTrue);
    AgentService.I.approveAlways();
    final res = await fut.timeout(const Duration(seconds: 60));
    expect(res, isNot('DENIED by user'));

    // Second call of the same tool: no prompt, straight through.
    final fut2 = AgentService.I.dispatchForTest('browser_open', {
      'url': 'https://example.com',
    });
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(
      AgentService.I.pendingApproval,
      isNull,
      reason: 'remembered tool must not prompt again',
    );
    final res2 = await fut2.timeout(const Duration(seconds: 60));
    expect(res2, isNot('DENIED by user'));
  });

  test('destructive commands always prompt without an Always option',
      () async {
    // Auto mode, run_code (no sandbox-policy pre-check): a destructive
    // payload reaches the approval prompt instead of any hard gate.
    await testSession('aaa-2', mode: 'auto');
    final fut = AgentService.I.dispatchForTest('run_code', {
      'code': 'import os; os.system("rm -rf /")',
      'lang': 'python',
    });
    final req = await waitForApproval();
    expect(req, isNotNull);
    expect(
      req!.allowAlways,
      isFalse,
      reason: 'destructive prompts must not offer always-allow',
    );
    AgentService.I.approve(false);
    final res = await fut.timeout(const Duration(seconds: 60));
    expect(res, 'DENIED by user');
  });

  test('device permission prompt has no Always option', () async {
    await testSession('aaa-3');
    final fut = AgentService.I.dispatchForTest('request_permission', {
      'permission': 'camera',
      'reason': 'test',
    });
    final req = await waitForApproval();
    expect(req, isNotNull);
    expect(req!.allowAlways, isFalse);
    AgentService.I.approve(false);
    await fut.timeout(const Duration(seconds: 60));
  });
}
