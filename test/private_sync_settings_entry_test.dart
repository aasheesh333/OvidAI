import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class _FakePrivateSyncSettingsController
    implements PrivateSyncSettingsController {
  int enrollCalls = 0;

  @override
  Future<void> enroll() async {
    enrollCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDown(() {
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  testWidgets('Private sync entry opens settings without auto-enrolling', (
    tester,
  ) async {
    final controller = _FakePrivateSyncSettingsController();
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: SettingsScreen(privateSyncController: controller),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Private sync'));
    await tester.pumpAndSettle();

    expect(find.byType(PrivateSyncSettingsScreen), findsOneWidget);
    expect(controller.enrollCalls, 0);
  });

  testWidgets('Private sync screen enrolls only after explicit action', (
    tester,
  ) async {
    final controller = _FakePrivateSyncSettingsController();
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: PrivateSyncSettingsScreen(controller: controller),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Enable private sync'));
    await tester.pump();

    expect(controller.enrollCalls, 1);
  });
}
