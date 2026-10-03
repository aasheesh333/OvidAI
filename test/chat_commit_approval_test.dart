import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'repo_cache_approval_test.dart' show ApprovalGit;

void main() {
  testWidgets('real chat approval can scroll to final diff bytes before allowing', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    final session = ChatSession(id: 'commit-dock', title: 'Review', model: 'm');
    app.sessions
      ..clear()
      ..add(session);
    app.activeSessionId = session.id;
    RepoCache.I.unbind();
    RepoCache.I.bind('owner/repo', 'token', sessionId: session.id);
    RepoCache.I.write(
      'a.txt',
      '${List.generate(50, (i) => 'line $i').join('\n')}\nFINAL_APPROVED_BYTES',
    );
    final git = ApprovalGit();
    late CommitApproval artifact;
    await tester.runAsync(() async {
      artifact = await RepoCache.I.prepareCommit(
        'review me',
        client: git.client,
      );
    });
    final req = ApprovalRequest(
      tool: 'commit',
      summary: artifact.message,
      detail:
          'Repository: ${artifact.repo}\nBranch: ${artifact.branch}\nBase: ${artifact.baseCommit}\nMessage: ${artifact.message}\nSelected paths: ${artifact.paths.join(', ')}\n${artifact.diff}',
    );
    AgentService.I.pendingApproval = req;
    tester.view.physicalSize = const Size(700, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      AgentService.I.pendingApproval = null;
      AgentService.I.debugPauseScheduleTimerForTest(false);
      AgentNotificationService.I.resetForTest();
      RepoCache.I.unbind();
      AppState.resetTestInstance();
      git.client.close();
    });
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final detail = find.byKey(const ValueKey('commit-approval-detail'));
    expect(detail, findsOneWidget);
    expect(find.text('Base: base').hitTestable(), findsOneWidget);
    expect(find.text('+FINAL_APPROVED_BYTES').hitTestable(), findsNothing);
    final scrollable = find.descendant(
      of: detail,
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('+FINAL_APPROVED_BYTES'),
      150,
      scrollable: scrollable,
    );
    expect(find.text('+FINAL_APPROVED_BYTES').hitTestable(), findsOneWidget);
    expect(req.completer.isCompleted, isFalse);
    expect(git.mutations, isEmpty);
    await tester.tap(find.text('Allow'));
    expect(await req.completer.future, isTrue);
    expect(tester.takeException(), isNull);
  });
}
