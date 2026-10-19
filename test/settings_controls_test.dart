// PR-6d settings: notification permission, memory sharing, response wait
// limit, context override clamping and custom preset ids.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/presets.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/settings_screen.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    app = AppState.createForTest();
    PresetRegistry.clearCustom();
  });

  tearDown(() {
    NotificationPermissionAccess.reset();
    PresetRegistry.clearCustom();
    AppState.resetTestInstance();
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(540, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const SettingsScreen()),
    );
    await tester.pump();
  }

  Future<void> open(WidgetTester tester, String title) async {
    await tester.scrollUntilVisible(
      find.text(title),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text(title));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Notifications ON while Android blocks them offers Open settings',
    (tester) async {
      var opened = 0;
      NotificationPermissionAccess.status = () async =>
          PermissionStatus.permanentlyDenied;
      NotificationPermissionAccess.openSettings = () async {
        opened++;
        return true;
      };
      await app.setNotificationsEnabled(true);
      await pumpSettings(tester);
      setCloudNotificationsForTest = (v) async {};
      addTearDown(() => setCloudNotificationsForTest = null);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('notifications-blocked')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('notifications-blocked')),
        findsOneWidget,
      );
      expect(find.text('Blocked by Android'), findsOneWidget);
      await tester.tap(find.text('Open settings'));
      await tester.pump();
      expect(opened, 1);
    },
  );

  testWidgets('turning Notifications on requests the permission', (
    tester,
  ) async {
    var requested = 0;
    NotificationPermissionAccess.status = () async => PermissionStatus.denied;
    NotificationPermissionAccess.request = () async {
      requested++;
      return PermissionStatus.granted;
    };
    setCloudNotificationsForTest = (v) async {};
    addTearDown(() => setCloudNotificationsForTest = null);
    await app.setNotificationsEnabled(false);
    await pumpSettings(tester);
    final row = find.ancestor(
      of: find.textContaining('Ovid Cloud sends no notifications'),
      matching: find.byType(ListTile),
    );
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(row);
    await tester.pump();
    await tester.pump();
    expect(requested, 1);
    expect(app.notificationsEnabled, isTrue);
    expect(find.byKey(const ValueKey('notifications-blocked')), findsNothing);
  });

  testWidgets('Share session memory is disabled while Memory is off', (
    tester,
  ) async {
    app.shareSessionMemory = true;
    await app.setMemoryEnabled(false);
    await pumpSettings(tester);
    expect(app.effectiveShareSessionMemory, isFalse);
    expect(find.textContaining('Turn on Memory'), findsOneWidget);
    final tile = find.ancestor(
      of: find.text('Share memory across chats'),
      matching: find.byType(ListTile),
    );
    final toggle = find.descendant(of: tile, matching: find.byType(Switch));
    expect(tester.widget<Switch>(toggle).onChanged, isNull);
    expect(tester.widget<Switch>(toggle).value, isFalse);

    await app.setMemoryEnabled(true);
    await tester.pump();
    expect(app.effectiveShareSessionMemory, isTrue);
    expect(find.textContaining('Turn on Memory'), findsNothing);
  });

  test('the "still working" hint is clamped to 30 s … 10 min', () async {
    await app.setResponseTimeout(5);
    expect(app.responseTimeoutSec, 30);
    await app.setResponseTimeout(3600);
    expect(app.responseTimeoutSec, 600);
    expect(AppState.timeoutPresets.last, 600);
  });

  test('answer length never exceeds the Ovid Cloud cap (8K)', () async {
    await app.setMaxOutputTokens(32768);
    expect(app.maxOutputTokens, 8192);
    await app.setMaxOutputTokens(0);
    expect(app.maxOutputTokens, 0);
    expect(AppState.outputTokenPresets.every((v) => v <= 8192), isTrue);
  });

  testWidgets('Responses screen: honest copy, no context override, no 16K/32K', (
    tester,
  ) async {
    await pumpSettings(tester);
    await open(tester, 'Responses');
    expect(find.text('Answer length'.toUpperCase()), findsOneWidget);
    expect(find.text('16K'), findsNothing);
    expect(find.text('32K'), findsNothing);
    expect(find.byKey(const ValueKey('context-info')), findsOneWidget);
    expect(find.textContaining('giving up'), findsNothing);
    expect(find.textContaining('never stops the run'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('output-4096')));
    await tester.pumpAndSettle();
    expect(app.maxOutputTokens, 4096);
    await tester.tap(find.byKey(const ValueKey('hint-60')));
    await tester.pumpAndSettle();
    expect(app.responseTimeoutSec, 60);
  });

  test('a persisted context override is ignored (cloud compacts itself)', () async {
    SharedPreferences.setMockInitialValues({'ovid_context_window_override': 32768});
    AppState.resetTestInstance();
    final fresh = AppState.createForTest();
    await fresh.reloadShellPreferencesForTest();
    expect(fresh.contextWindowOverride, 0);
  });

  testWidgets('no placeholder rows: Permissions and Providers are gone', (
    tester,
  ) async {
    await pumpSettings(tester);
    expect(find.text('Permissions'), findsNothing);
    expect(find.text('Providers'), findsNothing);
    expect(find.text('Response wait limit'), findsNothing);
    expect(find.text('Context & output'), findsNothing);
    expect(find.textContaining('P3'), findsNothing);
  });

  testWidgets('theme label says Auto is the default, not Dark', (tester) async {
    await app.setThemeMode('dark');
    await pumpSettings(tester);
    expect(find.text('Dark (default)'), findsNothing);
    expect(find.text('Dark'), findsWidgets);
  });

  testWidgets('an emulator never reports a clean integrity result', (
    tester,
  ) async {
    app.deviceSecurity = const {
      'isEmulator': true,
      'isRooted': false,
      'isHookingFrameworkPresent': false,
      'isDebuggerAttached': false,
    };
    app.securityChecked = true;
    await pumpSettings(tester);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('device-integrity')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('emulator'), findsOneWidget);
    expect(find.textContaining('OK'), findsNothing);
  });

  testWidgets('Notifications switch updates the cloud push preference', (
    tester,
  ) async {
    final sent = <bool>[];
    setCloudNotificationsForTest = (v) async => sent.add(v);
    addTearDown(() => setCloudNotificationsForTest = null);
    NotificationPermissionAccess.status = () async => PermissionStatus.granted;
    await app.setNotificationsEnabled(true);
    await pumpSettings(tester);
    final row = find.ancestor(
      of: find.textContaining('get notified'),
      matching: find.byType(ListTile),
    );
    await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
    await tester.pump();
    await tester.pump();
    expect(sent, [false]);
    expect(app.notificationsEnabled, isFalse);
  });

  testWidgets('a failed cloud push update leaves the switch unchanged', (
    tester,
  ) async {
    setCloudNotificationsForTest = (v) async => throw StateError('offline');
    addTearDown(() => setCloudNotificationsForTest = null);
    NotificationPermissionAccess.status = () async => PermissionStatus.granted;
    await app.setNotificationsEnabled(true);
    await pumpSettings(tester);
    final row = find.ancestor(
      of: find.textContaining('get notified'),
      matching: find.byType(ListTile),
    );
    await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
    await tester.pump();
    await tester.pump();
    expect(app.notificationsEnabled, isTrue);
  });
}
