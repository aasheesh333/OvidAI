// Settings v2 — calm, premium, progressive-disclosure IA.
//
// Pins the restructured contract:
//   * the eight root sections render (Account / Appearance / Models /
//     Privacy & autonomy / Data & backup / Studio / Health & repair / About);
//   * nav rows push the correct sub-pages, and sub-page rows push the
//     correct target screens;
//   * the theme segmented control still flips Aether.dark (persistence path
//     untouched);
//   * the merged Health screen shows the score ring + targeted repair;
//   * no overflow at 360x640 with 2x text in light and dark.
//
// All pumps are bounded (explicit pump durations / runAsync drains); the
// only unbounded settles run against fully-fake services that complete.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/health_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/health_screen.dart';
import 'package:ovid_ai/ui/providers_screen.dart';
import 'package:ovid_ai/ui/settings_backup_screen.dart';
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
    // other UI suites so the test tree disposes cleanly.
    AgentService.I.debugPauseScheduleTimerForTest(true);
    Aether.dark = true;
  });

  tearDown(() {
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
    Aether.dark = true;
  });

  Widget host(Widget child, {double textScale = 1}) => MaterialApp(
    theme: Aether.theme(),
    builder: textScale == 1
        ? null
        : (context, c) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: c!,
          ),
    home: child,
  );

  void setView(WidgetTester tester, Size logical) {
    tester.view.physicalSize = logical;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Bounded settle — only ever driven against fully-fake services and
  /// mocked stores, so it completes in milliseconds (default timeout caps
  /// the worst case). Real-service probes use bounded runAsync drains.
  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle();

  /// Push animation window — bounded, mirrors the legacy ui_redesign suites.
  Future<void> transition(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> pop(WidgetTester tester, Finder screen) async {
    final ctx = tester.element(screen);
    Navigator.of(ctx).pop();
    await transition(tester);
  }

  testWidgets('root renders the eight calm sections', (tester) async {
    setView(tester, const Size(540, 2400));
    await tester.pumpWidget(host(const SettingsScreen()));
    await tester.pump();

    expect(find.text('ACCOUNT'), findsOneWidget);
    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(find.text('MODELS'), findsOneWidget);
    expect(find.text('PRIVACY & AUTONOMY'), findsOneWidget);
    expect(find.text('DATA & BACKUP'), findsOneWidget);
    expect(find.text('STUDIO'), findsOneWidget);
    expect(find.text('HEALTH & REPAIR'), findsOneWidget);
    expect(find.text('ABOUT'), findsOneWidget);

    // Premium composition primitives are in use.
    expect(find.byType(AetherCard), findsWidgets);
    expect(find.byType(AetherSegmentedControl<String>), findsOneWidget);

    // The privacy policy appears exactly once on the root.
    expect(find.text('Privacy policy'), findsOneWidget);
  });

  testWidgets('nav rows push the correct sub-pages and targets', (
    tester,
  ) async {
    setView(tester, const Size(540, 2400));
    await tester.pumpWidget(host(const SettingsScreen()));
    await tester.pump();

    // ── Models sub-page ──
    await tester.tap(find.text('Models'));
    await transition(tester);
    expect(find.text('Providers'), findsOneWidget);
    expect(find.text('Context & output'), findsOneWidget);
    expect(find.text('AI response timeout'), findsOneWidget);
    expect(find.text('Agent presets'), findsOneWidget);

    await tester.tap(find.text('Providers'));
    await transition(tester);
    expect(find.byType(ProvidersScreen), findsOneWidget);
    await pop(tester, find.byType(ProvidersScreen));
    await pop(tester, find.text('Agent presets')); // back off Models sub-page

    // ── Privacy & autonomy sub-page ──
    await tester.tap(find.text('Privacy & autonomy'));
    await transition(tester);
    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('Memory'), findsWidgets);
    expect(find.text('Reasoning mode'), findsOneWidget);
    expect(find.text('Device integrity'), findsOneWidget);
    await pop(tester, find.text('Device integrity'));

    // ── Data & backup sub-page ──
    await tester.tap(find.text('Data & backup'));
    await transition(tester);
    expect(find.text('Backup & export'), findsOneWidget);
    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('Delete all data'), findsOneWidget);

    await tester.tap(find.text('Backup & export'));
    await transition(tester);
    expect(find.byType(SettingsBackupScreen), findsOneWidget);
    await pop(tester, find.byType(SettingsBackupScreen));
    await pop(tester, find.text('Delete all data')); // back off Data & backup

    // ── Health & repair pushes the merged Health screen ──
    await tester.tap(find.text('Health & repair'));
    await transition(tester);
    expect(find.byType(HealthScreen), findsOneWidget);
    // The merged screen kicks real HealthService probes on open; drain them
    // (bounded) before popping so no Timer outlives the test.
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 4)));
    final ctx = tester.element(find.byType(HealthScreen));
    Navigator.of(ctx).pop();
    await tester.pump();
  });

  testWidgets('memory switch keeps its persisted binding on the sub-page', (
    tester,
  ) async {
    setView(tester, const Size(540, 2400));
    await tester.pumpWidget(host(const SettingsScreen()));
    await tester.pump();

    await tester.tap(find.text('Privacy & autonomy'));
    await transition(tester);

    final before = AppState.I.memoryEnabled;
    final switchTile = find.descendant(
      of: find.widgetWithText(ListTile, 'Memory'),
      matching: find.byType(Switch),
    );
    expect(switchTile, findsOneWidget);
    await tester.tap(switchTile);
    await settle(tester);
    expect(
      (await SharedPreferences.getInstance()).getBool('ovid_memory_enabled'),
      !before,
    );
  });

  testWidgets('theme control flips Aether.dark', (tester) async {
    setView(tester, const Size(540, 2400));
    Aether.dark = true;
    AppState.I.lightTheme = false;

    await tester.pumpWidget(host(const SettingsScreen()));
    await tester.pump();

    await tester.tap(find.text('Light'));
    await settle(tester);
    expect(Aether.dark, isFalse);
    expect(AppState.I.lightTheme, isTrue);

    await tester.tap(find.text('Dark'));
    await settle(tester);
    expect(Aether.dark, isTrue);
    expect(AppState.I.lightTheme, isFalse);
  });

  testWidgets('health screen shows the score ring and targeted repair', (
    tester,
  ) async {
    setView(tester, const Size(900, 3200));
    var pythonFixed = false;
    Set<String>? seenTargets;
    final health = HealthService(
      installed: () async => true,
      exec: (args) async {
        // Only the `python --version` probe fails (pip shares the same
        // executable name, so match the full argument list).
        if (!pythonFixed &&
            args.length == 2 &&
            args.first == 'python' &&
            args[1] == '--version') {
          return (127, 'missing');
        }
        return (0, 'version');
      },
      workspace: () async {},
      providerConfigured: () => true,
      repairWorker: (targets, cancellation, onLine) async {
        seenTargets = targets;
        onLine('installing…');
        pythonFixed = true;
      },
    );

    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: HealthScreen(service: health)),
    );
    await settle(tester);

    // Score ring + summary.
    expect(find.text('Overall health'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('of 100'), findsOneWidget);
    expect(find.textContaining('check(s) failing'), findsOneWidget);
    expect(find.text('RUNTIME HEALTH'), findsOneWidget);

    // Targeted repair: select the failed runtime, repair just it.
    expect(find.byType(Checkbox), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await settle(tester);
    await tester.tap(find.text('Repair selected runtimes'));
    await settle(tester);

    expect(seenTargets, {'python'});
    expect(find.text('Selected runtime checks now pass.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    health.dispose();
  });

  testWidgets('health screen keeps hard reset behind Advanced disclosure', (
    tester,
  ) async {
    setView(tester, const Size(900, 3200));
    final health = HealthService(
      installed: () async => true,
      exec: (_) async => (0, 'version'),
      workspace: () async {},
      providerConfigured: () => true,
    );
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: HealthScreen(service: health)),
    );
    await settle(tester);

    // Collapsed: the destructive action is not on stage.
    expect(find.text('Advanced'), findsOneWidget);
    expect(find.text('Hard reset the sandbox'), findsNothing);

    await tester.tap(find.text('Advanced'));
    await settle(tester);
    expect(find.text('Hard reset the sandbox'), findsOneWidget);
    expect(find.text('Re-run checks'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    health.dispose();
  });

  for (final dark in [true, false]) {
    testWidgets('no overflow at 360x640 @2x (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      setView(tester, const Size(360, 640));
      Aether.dark = dark;
      AppState.I.lightTheme = !dark;

      await tester.pumpWidget(host(const SettingsScreen(), textScale: 2));
      await transition(tester);
      expect(tester.takeException(), isNull);

      // Each sub-page must also stay overflow-free at 2x text. The root is
      // a LAZY ListView, so off-screen rows are not built yet — reveal them
      // with scrollUntilVisible rather than ensureVisible.
      for (final entry in const {
        'Models': 'Agent presets',
        'Privacy & autonomy': 'Device integrity',
        'Data & backup': 'Delete all data',
      }.entries) {
        await tester.scrollUntilVisible(
          find.text(entry.key),
          250,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 100,
        );
        await transition(tester);
        await tester.tap(find.text(entry.key));
        await transition(tester);
        expect(find.text(entry.value), findsWidgets);
        expect(tester.takeException(), isNull);
        await pop(tester, find.text(entry.value).first);
      }

      // Merged health screen at the same size, with a fast fake service.
      await tester.scrollUntilVisible(
        find.text('Health & repair'),
        250,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 100,
      );
      await transition(tester);
      await tester.tap(find.text('Health & repair'));
      await transition(tester);
      expect(find.byType(HealthScreen), findsOneWidget);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 4)),
      );
      expect(tester.takeException(), isNull);
      final ctx = tester.element(find.byType(HealthScreen));
      Navigator.of(ctx).pop();
      await tester.pump();
    });
  }
}
