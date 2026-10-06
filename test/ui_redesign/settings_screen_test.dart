// Smoke tests for the Wave 2 Aether reskin of SettingsScreen.
//
// Verifies that the premium reskin:
//   * renders the Account / Appearance / Models / Autonomy / Studio section
//     titles (built from AetherSectionTitle, uppercased by the primitive);
//   * flips Aether.dark when the theme segmented control is driven;
//   * navigates to SettingsBackupScreen when the backup row's "Backup"
//     action is tapped;
//   * navigates to SettingsHealthScreen when the health row's "Health"
//     action is tapped.
//
// Behavior parity (persisted preferences, action widgets, provider config
// entry, autonomy / Studio / Image bindings) is already covered by the
// per-feature suites and must remain untouched here.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/settings_backup_screen.dart';
import 'package:ovid_ai/ui/settings_health_screen.dart';
import 'package:ovid_ai/ui/settings_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    // Keep the schedule timer paused — matches the convention used by the
    // other ui_redesign suites so the test tree disposes cleanly.
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDown(() {
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  Widget host() => MaterialApp(
    theme: Aether.theme(),
    home: const SettingsScreen(),
  );

  testWidgets(
    'renders Account / Appearance / Models / Autonomy / Studio sections',
    (tester) async {
      // Give the screen a tall viewport so every section is laid out and
      // reachable via a single scroll pass.
      tester.view.physicalSize = const Size(540, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(host());
      await tester.pump();

      // AetherSectionTitle is used for every section header. Each title is
      // uppercased by the primitive, so the raw eyebrow text appears as
      // 'ACCOUNT', 'APPEARANCE', etc.
      expect(find.text('ACCOUNT'), findsOneWidget);
      expect(find.text('APPEARANCE'), findsOneWidget);
      expect(find.text('MODELS'), findsOneWidget);
      expect(find.text('AUTONOMY'), findsOneWidget);
      expect(find.text('STUDIO'), findsOneWidget);

      // Multiple AetherCard surfaces are composed into the list — one per
      // section bucket at minimum.
      expect(find.byType(AetherCard), findsWidgets);

      // The theme segmented control is built from the AetherSegmentedControl
      // primitive instead of the raw Material SegmentedButton.
      expect(find.byType(AetherSegmentedControl<String>), findsOneWidget);
    },
  );

  testWidgets('toggling the dark theme segment flips Aether.dark', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(540, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Start from the known default — dark palette is the production default.
    Aether.dark = true;
    AppState.I.lightTheme = false;

    await tester.pumpWidget(host());
    await tester.pump();

    // Tapping the "Light" pill drives AppState.setThemeMode('light'),
    // which flips Aether.dark to false.
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(Aether.dark, isFalse);
    expect(AppState.I.lightTheme, isTrue);

    // And back the other way via the "Dark" pill.
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(Aether.dark, isTrue);
    expect(AppState.I.lightTheme, isFalse);
  });

  testWidgets('tapping Backup pushes SettingsBackupScreen', (tester) async {
    tester.view.physicalSize = const Size(540, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host());
    await tester.pump();

    // Backup row carries an AetherGhostButton labelled 'Backup' — tapping
    // it pushes the SettingsBackupScreen without changing the legacy
    // row-level tap behavior.
    await tester.ensureVisible(find.widgetWithText(AetherGhostButton, 'Backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AetherGhostButton, 'Backup'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(SettingsBackupScreen), findsOneWidget);
  });

  testWidgets('tapping Health pushes SettingsHealthScreen', (tester) async {
    tester.view.physicalSize = const Size(540, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host());
    await tester.pump();

    await tester.ensureVisible(find.widgetWithText(AetherGhostButton, 'Health'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AetherGhostButton, 'Health'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(SettingsHealthScreen), findsOneWidget);
    // SettingsHealthScreen kicks real HealthService probes on init; let them
    // finish (with timers) before popping, so the test does not trip the
    // pending-Timer invariant on dispose.
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 4)));
    final ctx = tester.element(find.byType(SettingsHealthScreen));
    Navigator.of(ctx).pop();
    await tester.pump();
  });
}
