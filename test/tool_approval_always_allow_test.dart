import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/commands.dart';
import 'package:ovid_ai/core/grant_store.dart';
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
    // Strict permission model: the off-allowlist host raises its own grant
    // card (still offering Always Allow — session or all-sessions scope).
    final hostReq = await waitForApproval();
    expect(hostReq, isNotNull, reason: 'off-allowlist host must prompt');
    expect(hostReq!.tool, 'grant:host:example.com');
    expect(hostReq.allowAlways, isTrue);
    AgentService.I.approveAlways();
    final res = await fut.timeout(const Duration(seconds: 60));
    expect(res, isNot('DENIED by user'));
    expect(res, isNot(startsWith('ACCESS_DENIED')));

    // Second call of the same tool: tool remembered AND host granted — no
    // prompt, straight through.
    final fut2 = AgentService.I.dispatchForTest('browser_open', {
      'url': 'https://example.com',
    });
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(
      AgentService.I.pendingApproval,
      isNull,
      reason: 'remembered tool + granted host must not prompt again',
    );
    final res2 = await fut2.timeout(const Duration(seconds: 60));
    expect(res2, isNot('DENIED by user'));
    expect(res2, isNot(startsWith('ACCESS_DENIED')));
  });

  test('destructive commands always prompt without an Always option', () async {
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

  test(
    'absolute path outside workspace prompts instead of bypassing',
    () async {
      // Regression: absolute host paths in agent file tools route through
      // the grant system — no silent bypass, no hard refusal.
      await testSession('aaa-grant-path');
      final outside = File('${ledgerDir.path}/outside-secret.txt')
        ..writeAsStringSync('top-secret-content');
      final fut = AgentService.I.dispatchForTest('file_read', {
        'path': outside.path,
      });
      final req = await waitForApproval();
      expect(req, isNotNull, reason: 'outside absolute path must prompt');
      expect(req!.tool, 'grant:path:${outside.path}');
      expect(req.allowAlways, isTrue);
      AgentService.I.approve(true);
      final res = await fut.timeout(const Duration(seconds: 60));
      expect(res, contains('top-secret-content'));
      expect(res, isNot(startsWith('ACCESS_DENIED')));

      // Denying the same path surfaces the structured denial, not
      // "file not found".
      final fut2 = AgentService.I.dispatchForTest('file_read', {
        'path': outside.path,
      });
      // The earlier Allow was one-shot (not always) — prompts again.
      final req2 = await waitForApproval();
      expect(req2, isNotNull);
      AgentService.I.approve(false);
      final res2 = await fut2.timeout(const Duration(seconds: 60));
      expect(res2, startsWith('ACCESS_DENIED: ${outside.path}.'));
      expect(res2, contains('ask the user what to do next'));
    },
  );

  test('run_shell outside paths raise ONE combined approval card', () async {
    // Auto mode: the tool itself needs no approval, so the only prompt is
    // the combined path-grant card covering every outside path. The test
    // verifies the grant model (prompt shape + recorded grants), not shell
    // execution itself (no phone shell in the test env).
    final s = await testSession('aaa-shell-paths', mode: 'auto');
    final a = File('${ledgerDir.path}/shell-a.txt')..writeAsStringSync('alpha');
    final b = File('${ledgerDir.path}/shell-b.txt')..writeAsStringSync('beta');
    final fut = AgentService.I.dispatchForTest('run_shell', {
      'command': 'cat ${a.path} ${b.path}',
    });
    final req = await waitForApproval();
    expect(req, isNotNull, reason: 'outside paths in shell must prompt');
    expect(
      req!.tool.startsWith('grant:paths:'),
      isTrue,
      reason: 'one combined card, not one per path (got: ${req.tool})',
    );
    expect(req.tool, contains(a.path));
    expect(req.tool, contains(b.path));
    expect(req.allowAlways, isTrue);
    // Always-allow on the combined card grants BOTH paths at once.
    AgentService.I.approveAlways();
    await fut.timeout(const Duration(seconds: 60));
    final granted = s.grants.map((g) => g.value).toSet();
    expect(granted, contains(a.path));
    expect(granted, contains(b.path));

    // Second run over the same paths: grants cover, no prompt.
    final fut2 = AgentService.I.dispatchForTest('run_shell', {
      'command': 'cat ${a.path} ${b.path}',
    });
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(
      AgentService.I.pendingApproval,
      isNull,
      reason: 'granted paths must not prompt again',
    );
    await fut2.timeout(const Duration(seconds: 60));
  });

  test(
    'fs_glob outside base prompts; deny returns structured denial',
    () async {
      await testSession('aaa-glob-deny');
      final fut = AgentService.I.dispatchForTest('fs_glob', {
        'pattern': '*.txt',
        'path': ledgerDir.path,
      });
      final req = await waitForApproval();
      expect(req, isNotNull, reason: 'outside glob base must prompt');
      expect(req!.tool, 'grant:path:${ledgerDir.path}');
      AgentService.I.approve(false, note: 'no peeking at my temp files');
      final res = await fut.timeout(const Duration(seconds: 60));
      expect(
        res,
        startsWith('ACCESS_DENIED: ${ledgerDir.path}.'),
        reason: 'denial must use the structured shape',
      );
      expect(res, contains('ask the user what to do next'));
      expect(res, contains('no peeking at my temp files'));
    },
  );

  test('deny with a note: note rides back in the denial message', () async {
    // Auto mode: browser_download is a write, so safe (read-only) mode
    // blocks it before the path gate; auto lets the grant card appear.
    await testSession('aaa-deny-note', mode: 'auto');
    final dest = '${ledgerDir.path}/nope.bin';
    final fut = AgentService.I.dispatchForTest('browser_download', {
      'url': 'https://example.com/f.bin',
      'filename': dest,
    });
    final req = await waitForApproval();
    expect(req, isNotNull);
    expect(req!.tool, 'grant:path:$dest');
    AgentService.I.approve(false, note: 'downloads go to the workspace');
    final res = await fut.timeout(const Duration(seconds: 60));
    expect(res, startsWith('ACCESS_DENIED: $dest.'));
    expect(res, contains('Explain briefly why you needed this path'));
    expect(res, contains('downloads go to the workspace'));
  });

  test('revoking a grant makes the next access prompt again', () async {
    final s = await testSession('aaa-revoke');
    final outside = File('${ledgerDir.path}/revoke-me.txt')
      ..writeAsStringSync('x');

    // Always-allow (session scope) on the grant card.
    var fut = AgentService.I.dispatchForTest('file_read', {
      'path': outside.path,
    });
    var req = await waitForApproval();
    expect(req, isNotNull);
    AgentService.I.approveAlways();
    await fut.timeout(const Duration(seconds: 60));

    // Granted: no prompt.
    fut = AgentService.I.dispatchForTest('file_read', {'path': outside.path});
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(
      AgentService.I.pendingApproval,
      isNull,
      reason: 'granted path must not prompt',
    );
    await fut.timeout(const Duration(seconds: 60));

    // Revoke via the Permissions-screen path; the next access prompts.
    final grant = s.grants.firstWhere(
      (g) => g.value == outside.path,
      orElse: () => throw StateError('session grant missing'),
    );
    await AgentService.I.revokeSessionPermissionGrant(grant);
    fut = AgentService.I.dispatchForTest('file_read', {'path': outside.path});
    req = await waitForApproval();
    expect(req, isNotNull, reason: 'revoked path must prompt again');
    expect(req!.tool, 'grant:path:${outside.path}');
    AgentService.I.approve(false);
    await fut.timeout(const Duration(seconds: 60));
  });

  test('global grant revoke removes cross-session access', () async {
    await testSession('aaa-global-revoke');
    final outside = File('${ledgerDir.path}/global-me.txt')
      ..writeAsStringSync('g');

    // Always-allow with the "all sessions" scope → global grant.
    var fut = AgentService.I.dispatchForTest('file_read', {
      'path': outside.path,
    });
    var req = await waitForApproval();
    expect(req, isNotNull);
    AgentService.I.approveAlways(global: true);
    await fut.timeout(const Duration(seconds: 60));
    // Flush the unawaited global-grant persistence.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      AppState.I.globalPermissionGrants.any((g) => g.value == outside.path),
      isTrue,
      reason: 'global grant must be recorded',
    );

    // Another session sees no prompt while the grant lives.
    await testSession('aaa-global-revoke-2');
    fut = AgentService.I.dispatchForTest('file_read', {'path': outside.path});
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(
      AgentService.I.pendingApproval,
      isNull,
      reason: 'global grant covers other sessions',
    );
    final resOther = await fut.timeout(const Duration(seconds: 60));
    expect(resOther, contains('g'));

    // Revoke globally; the other session now prompts.
    final removed = await AppState.I.revokeGlobalPermissionGrant(
      PermissionGrant.kindPath,
      outside.path,
    );
    expect(removed, isTrue);
    fut = AgentService.I.dispatchForTest('file_read', {'path': outside.path});
    req = await waitForApproval();
    expect(req, isNotNull, reason: 'revoked global grant must prompt again');
    AgentService.I.approve(false);
    await fut.timeout(const Duration(seconds: 60));
  });

  test('browser_popups open passes the host-grant gate', () async {
    // Bug-hunt regression: popup 'open' used to call newBrowserTab(url)
    // directly, letting a popup URL bypass the host-grant check.
    await testSession('aaa-popups', mode: 'auto');
    final fut = AgentService.I.dispatchForTest('browser_popups', {
      'action': 'open',
      'url': 'https://popup-ungranted.example/open-me',
    });
    final req = await waitForApproval();
    expect(req, isNotNull, reason: 'ungranted popup host must prompt');
    expect(req!.tool, 'grant:host:popup-ungranted.example');
    AgentService.I.approve(false);
    final res = await fut.timeout(const Duration(seconds: 60));
    expect(res, startsWith('ACCESS_DENIED'));
  });
}
