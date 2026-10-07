import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppState app;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    app = AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    app.sessions.add(ChatSession(
      id: 'polish',
      title: 'Polish',
      model: 'test-model',
      mode: 'auto',
    ));
    app.activeSessionId = 'polish';
  });
  tearDown(() {
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(839, 900);
    tester.view.padding = const FakeViewPadding(top: 32, left: 24, right: 24);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);
    await tester.pumpWidget(MaterialApp(theme: Aether.theme(), home: const OvidShell()));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('draft, selection and focus survive both breakpoint directions and warning changes', (tester) async {
    await mount(tester);
    final composer = find.byKey(const ValueKey('chat-composer'));
    await tester.enterText(composer, 'Keep this unsent draft');
    final field = tester.widget<TextField>(composer);
    field.controller!.selection = const TextSelection(baseOffset: 2, extentOffset: 9);
    final chatState = tester.state(find.byType(ChatScreen));
    for (final width in [840.0, 839.0, 1024.0, 500.0]) {
      tester.view.physicalSize = Size(width, 900);
      app.lastSessionPersistFailed = !app.lastSessionPersistFailed;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      final current = tester.widget<TextField>(composer);
      expect(tester.state(find.byType(ChatScreen)), same(chatState));
      expect(current.controller!.text, 'Keep this unsent draft');
      expect(current.controller!.selection, const TextSelection(baseOffset: 2, extentOffset: 9));
      expect(current.focusNode!.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('persistence warning respects display cutouts and announces recovery state changes', (tester) async {
    final semantics = tester.ensureSemantics();
    await mount(tester);
    final warning = find.textContaining("Chat history isn't being saved");
    expect(warning, findsNothing);
    app.lastSessionPersistFailed = true;
    await tester.pump(const Duration(seconds: 3));
    final rect = tester.getRect(warning);
    expect(rect.top, greaterThanOrEqualTo(32));
    expect(rect.left, greaterThanOrEqualTo(24));
    expect(rect.right, lessThanOrEqualTo(839 - 24));
    expect(tester.getSemantics(warning).flagsCollection.isLiveRegion, isTrue);
    app.lastSessionPersistFailed = false;
    await tester.pump(const Duration(seconds: 3));
    expect(warning, findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });
}
