import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppState app;
  const sid = 'chat-premium-regression';
  final composer = find.byKey(const ValueKey('chat-composer'));

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    app = AppState.createForTest();
    app.sessions
      ..clear()
      ..add(ChatSession(id: sid, title: 'Chat regression', model: 'm'));
    app.activeSessionId = sid;
    app.sendWhileBusy = 'queue';
    AgentService.I.debugPauseScheduleTimerForTest(true);
    AgentService.I.clearQueueForTest();
    AgentService.I.clearAttachment();
    AgentService.I.runBucketForTest(sid).activeRunId = null;
    AgentService.I.pendingApproval = null;
  });

  tearDown(() {
    AgentService.I.runBucketForTest(sid).activeRunId = null;
    AgentService.I.pendingApproval = null;
    AgentService.I.clearQueueForTest();
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  AetherPrimaryButton primary(WidgetTester tester) =>
      tester.widget<AetherPrimaryButton>(find.descendant(
        of: find.byKey(const ValueKey('chat-composer-card')),
        matching: find.byType(AetherPrimaryButton),
      ));

  testWidgets('empty and whitespace drafts cannot submit', (tester) async {
    await mount(tester);
    expect(primary(tester).onPressed, isNull);
    await tester.enterText(composer, '   \n  ');
    await tester.pump();
    expect(primary(tester).onPressed, isNull);
    await tester.enterText(composer, 'A real draft');
    await tester.pump();
    expect(primary(tester).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a draft without an active session cannot submit', (tester) async {
    app.activeSessionId = null;
    await mount(tester);
    await tester.enterText(composer, 'Select a session first');
    await tester.pump();
    expect(primary(tester).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Stop stays reachable with a draft and busy action follows setting', (
    tester,
  ) async {
    AgentService.I.runBucketForTest(sid).activeRunId = 'fixture-run';
    final semantics = tester.ensureSemantics();
    await mount(tester);
    await tester.enterText(composer, 'Keep my draft');
    await tester.pump();
    expect(find.byTooltip('Stop session').hitTestable(), findsOneWidget);
    expect(find.bySemanticsLabel('Add to queue'), findsOneWidget);
    app.sendWhileBusy = 'interrupt';
    app.refresh();
    await tester.pump();
    expect(find.bySemanticsLabel('Interrupt and send'), findsOneWidget);
    expect(find.byTooltip('Stop session').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('Stop session'));
    await tester.pump();
    expect(AgentService.I.busyFor(sid), isFalse);
    expect(tester.widget<TextField>(composer).controller!.text, 'Keep my draft');
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('approval is visible ahead of queued work and disables submission', (
    tester,
  ) async {
    await mount(tester);
    await tester.enterText(composer, 'Keep until approved');
    for (var i = 0; i < 6; i++) {
      AgentService.I.enqueueMessage('Queued $i', sessionId: sid);
    }
    AgentService.I.pendingApproval = ApprovalRequest(
      tool: 'shell',
      summary: 'Approval needed',
      detail: 'Review this command',
    );
    app.refresh();
    await tester.pump();
    expect(find.text('Deny').hitTestable(), findsOneWidget);
    expect(find.text('Allow').hitTestable(), findsOneWidget);
    expect(primary(tester).onPressed, isNull);
    expect(tester.widget<TextField>(composer).enabled, isFalse);
    expect(tester.widget<TextField>(composer).controller!.text, 'Keep until approved');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
