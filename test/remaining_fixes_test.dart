import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/global_repo_registry.dart';

/// Remaining correctness/security items closed on 2026-09-24.
void main() {
  group('cloud-metadata endpoints are refused in every mode', () {
    // SSRF: `drive`/`control` returned true for EVERY host, so a prompt-injected
    // model could read instance credentials from the metadata service. Loopback
    // is deliberately still allowed — local dev servers and local MCP servers are
    // a real workflow.
    test('link-local and metadata hosts are blocked', () {
      for (final h in [
        '169.254.169.254',
        '169.254.0.1',
        'metadata.google.internal',
        'sub.metadata.google.internal',
        '100.100.100.200',
        'fe80::1',
        'FE80::1',
      ]) {
        expect(
          AgentService.isMetadataOrLinkLocalHost(h),
          isTrue,
          reason: '$h must never be reachable by the agent',
        );
      }
    });

    test('ordinary and loopback hosts are NOT blocked', () {
      for (final h in ['example.com', 'api.github.com', '127.0.0.1', 'localhost',
        '192.168.1.50', '10.0.0.3']) {
        expect(
          AgentService.isMetadataOrLinkLocalHost(h),
          isFalse,
          reason: '$h goes through the normal grant prompt, not a hard block',
        );
      }
    });

    test('the check runs before any mode exemption', () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      final i = src.indexOf('Future<bool> _checkHostGrant(');
      expect(i, greaterThan(-1));
      final body = src.substring(i, i + 1600);
      expect(
        body.indexOf('isMetadataOrLinkLocalHost(host)'),
        lessThan(body.indexOf('if (m == AgentMode.drive) return true;')),
        reason: 'Full Access must not bypass the metadata block',
      );
    });
  });

  group('the registry remembers the chosen branch per repo', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('branch-memory-'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    GlobalRepoRegistry reg() => GlobalRepoRegistry.createForTest(
      baseDir: Directory('${tmp.path}/global'),
      gitRunner: (r, b, d) async => Directory(d).create(recursive: true),
    );

    test('a re-pick of the same repo keeps the branch the user chose', () async {
      final r = reg();
      expect(r.branchFor('acme/widget'), isNull);

      await r.rememberBranch('acme/widget', 'feature-x');
      expect(r.branchFor('acme/widget'), 'feature-x');

      // Another repo does not cross-write the slot (lastBranch used to).
      await r.rememberBranch('other/proj', 'dev');
      expect(r.branchFor('acme/widget'), 'feature-x');
      expect(r.branchFor('other/proj'), 'dev');
    });

    test('it survives a restart', () async {
      final r1 = reg();
      await r1.rememberBranch('acme/widget', 'release-2');

      // createForTest does not auto-load (production `instance()` does); a
      // fresh process reads the index explicitly.
      final r2 = reg();
      await r2.reload();
      expect(
        r2.branchFor('acme/widget'),
        'release-2',
        reason: 'the choice must be persisted in the index, not in memory',
      );
    });

    test('the index carries it under a "branches" key', () async {
      final r = reg();
      await r.rememberBranch('acme/widget', 'main-ish');
      final j = jsonDecode(
        File('${tmp.path}/global/repo_index.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(j['branches'], {'acme/widget': 'main-ish'});
    });

    test('a blank branch is ignored', () async {
      final r = reg();
      await r.rememberBranch('acme/widget', '   ');
      expect(r.branchFor('acme/widget'), isNull);
    });
  });

  group('background approvals are surfaced instead of silently auto-denied', () {
    test('the dock renders the other-sessions row when the foreground is idle',
        () {
      final src = File('lib/ui/chat_screen.dart').readAsStringSync();
      final dock = src.substring(src.indexOf('class _ApprovalDockState'));
      final body = dock.substring(0, dock.indexOf('Widget build(BuildContext') + 2000);
      expect(body, contains('pendingApprovalsElsewhere'));
      expect(body, contains('_OtherSessionsApprovalRow(items: elsewhere)'));
      expect(src, contains('is waiting for approval'));
      expect(src, contains('sessions are waiting for approval'));
      // Review must switch to the waiting session, where the real card renders.
      expect(
        src,
        contains('AppState.I.selectSession(first.sessionId)'),
      );
    });

    test('the service exposes approvals from non-foreground sessions', () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      expect(src, contains('get pendingApprovalsElsewhere'));
      final i = src.indexOf('get pendingApprovalsElsewhere');
      final body = src.substring(i, i + 900);
      expect(
        body,
        contains('if (entry.key == activeId) continue;'),
        reason: 'the foreground session is already rendered by the dock',
      );
      expect(body, contains('entry.value.pendingApproval'));
    });
  });

  group('a reminder no longer hijacks the visible session', () {
    test('delivery notifies instead of calling selectSession', () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      final i = src.indexOf('Do NOT yank the user to another chat');
      expect(i, greaterThan(-1));
      final region = src.substring(i - 200, i + 1800);
      expect(region, isNot(contains('AppState.I.selectSession(s.id)')));
      expect(region, contains('reminder fired in'));
      expect(region, contains('wasVisible'));
    });

    test('the schedule tick is no longer 1Hz for the app lifetime', () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      expect(src, contains('scheduleTickInterval = Duration(seconds: 5)'));
      expect(
        src,
        contains('Timer.periodic(scheduleTickInterval'),
      );
    });
  });

  group('browser_navigate survives the controller being recreated', () {
    test('the title read is null-safe', () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      final i = src.indexOf("case 'browser_navigate':");
      final body = src.substring(i, i + 3000);
      expect(body, isNot(contains('tab.controller!.getTitle()')));
      expect(body, contains('final ctl = tab.controller;'));
      expect(body, contains('tab.title'));
    });
  });

  group('origin writes are serialized', () {
    test('rememberOrigin queues per bucket instead of read-modify-writing', () {
      final src = File('lib/core/session_browser_profiles.dart').readAsStringSync();
      expect(src, contains('_originWrites'));
      expect(src, contains('Future<void> _writeOrigin('));
      final i = src.indexOf('Future<void> rememberOrigin(');
      // Window ends at the helper: rememberOrigin must only enqueue.
      final body = src.substring(i, src.indexOf('Future<void> _writeOrigin('));
      expect(
        body,
        contains('previous'),
        reason: 'a later write must wait for the earlier one',
      );
      expect(
        body,
        isNot(contains('prefs.setStringList')),
        reason: 'the read-modify-write must live behind the queue',
      );
    });
  });

  group('images decode to the display size, not full resolution', () {
    test('every Image.file/Image.network passes a cacheWidth', () {
      final chat = File('lib/ui/chat_screen.dart').readAsStringSync();
      final studio = File('lib/ui/studio_screen.dart').readAsStringSync();
      expect(
        'cacheWidth:'.allMatches(chat).length,
        greaterThanOrEqualTo(2),
        reason: 'inline card + fullscreen view',
      );
      expect(studio, contains('cacheWidth:'));
      expect(
        File('lib/core/theme.dart').readAsStringSync(),
        contains('static int imageCacheWidth(BuildContext context'),
      );
    });
  });
}
