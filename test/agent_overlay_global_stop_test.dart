import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final agent = AgentService.I;
  final nativeCalls = <String>[];
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.createForTest();
    AgentNotificationService.I.resetForTest();
    agent.debugPauseScheduleTimerForTest(true);
    nativeCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ovid/native'), (call) async {
      nativeCalls.add(call.method);
      return null;
    });
  });
  tearDown(() {
    agent.dropSessionRun('overlay-a');
    agent.dropSessionRun('overlay-b');
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ovid/native'), null);
  });

  for (final hasSession in [true, false]) {
    test('overlay Stop persists global stop ${hasSession ? 'with queued runs' : 'while idle'}', () async {
      if (hasSession) {
        for (final id in ['overlay-a', 'overlay-b']) {
          AppState.I.sessions.add(ChatSession(id: id, title: id, model: 'm', mode: 'auto'));
          agent.runBucketForTest(id)..activeRunId = id..queue.add('must not resume');
        }
        AppState.I.activeSessionId = 'overlay-a';
      }
      final started = <String>[];
      agent.queuedRunStarterForTest = (id, text) async { started.add(text); };
      addTearDown(() => agent.queuedRunStarterForTest = null);
      expect(await agent.handleDeviceOverlayMethodCall(
          const MethodCall(AgentService.deviceOverlayStopMethod)), isTrue);
      expect(AgentNotificationService.I.backgroundStopped, isTrue);
      expect((await SharedPreferences.getInstance()).getBool('ovid_background_stopped'), isTrue);
      expect(agent.schedules.stopped, isTrue);
      expect(agent.anyRunActive, isFalse);
      expect(started, isEmpty);
      expect(agent.queuedMessagesFor('overlay-a'), isEmpty);
      expect(agent.queuedMessagesFor('overlay-b'), isEmpty);
      expect(nativeCalls.where((m) => m == 'backgroundStop'), hasLength(1));
    });
  }
}
