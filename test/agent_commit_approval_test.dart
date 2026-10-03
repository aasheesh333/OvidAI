import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/state.dart';
import 'repo_cache_approval_test.dart' show ApprovalGit;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ApprovalGit git;
  late ChatSession session;
  final agent = AgentService.I;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    agent.debugPauseScheduleTimerForTest(true);
    session =
        ChatSession(
            id: 'approval-agent',
            title: 'Commit',
            model: 'm',
            mode: 'auto',
          )
          ..repo = 'owner/repo'
          ..branch = 'main';
    app.sessions.insert(0, session);
    app.activeSessionId = session.id;
    AgentService.setRunSessionForTest(session.id);
    RepoCache.I.unbind();
    RepoCache.I.bind('owner/repo', 'token', sessionId: session.id);
    RepoCache.I.write('a.txt', 'approved');
    git = ApprovalGit();
  });
  tearDown(() {
    agent.approve(false);
    AgentService.setRunSessionForTest('');
    agent.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    RepoCache.I.unbind();
    AppState.resetTestInstance();
    git.client.close();
  });

  for (final action in ['approve', 'edit', 'deny']) {
    test(
      'agent $action uses the snapshot shown by existing approval policy',
      () async {
        final prompted = Completer<void>();
        void listener() {
          if (agent.pendingApproval != null && !prompted.isCompleted) {
            prompted.complete();
          }
        }

        agent.addListener(listener);
        addTearDown(() => agent.removeListener(listener));
        final result = http.runWithClient(
          () => agent.dispatchForTest('commit', {
            'message': 'exact agent message',
          }),
          () => git.client,
        );
        await prompted.future.timeout(const Duration(seconds: 3));
        expect(agent.pendingApproval!.detail, contains('Base: base'));
        expect(agent.pendingApproval!.detail, contains('+approved'));
        expect(git.mutations, isEmpty);
        if (action == 'edit') RepoCache.I.write('a.txt', 'later');
        agent.approve(action != 'deny');
        final output = await result;
        if (action == 'approve') {
          expect(output, contains('single atomic commit'));
          final commit = git.requests.singleWhere(
            (r) => r.method == 'POST' && r.url.path.endsWith('/commits'),
          );
          expect(jsonDecode(commit.body)['message'], 'exact agent message');
        } else {
          expect(git.mutations, isEmpty);
          expect(RepoCache.I.hasPending, isTrue);
          expect(output, contains(action == 'deny' ? 'DENIED' : 'stale'));
        }
      },
    );
  }

  test(
    'Control publishes through frozen contract without an extra prompt',
    () async {
      session.mode = 'control';
      final output = await http.runWithClient(
        () => agent.dispatchForTest('commit', {'message': 'control message'}),
        () => git.client,
      );
      expect(output, contains('single atomic commit'));
      expect(agent.pendingApproval, isNull);
      expect(git.requests.where((r) => r.method == 'PATCH').length, 1);
    },
  );
}
