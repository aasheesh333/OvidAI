// PR-6d settings: notification permission, memory sharing, response wait
// limit, context override clamping and custom preset ids.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
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
    AgentService.I.debugPauseScheduleTimerForTest(true);
    PresetRegistry.clearCustom();
  });

  tearDown(() {
    NotificationPermissionAccess.reset();
    PresetRegistry.clearCustom();
    AgentService.I.debugPauseScheduleTimerForTest(false);
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
      await tester.scrollUntilVisible(
        find.text('Notifications'),
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
    await app.setNotificationsEnabled(false);
    await pumpSettings(tester);
    await tester.scrollUntilVisible(
      find.text('Notifications'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Notifications'));
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
    expect(find.textContaining('Requires Memory'), findsOneWidget);
    final tile = find.ancestor(
      of: find.text('Share session memory'),
      matching: find.byType(ListTile),
    );
    final toggle = find.descendant(of: tile, matching: find.byType(Switch));
    expect(tester.widget<Switch>(toggle).onChanged, isNull);
    expect(tester.widget<Switch>(toggle).value, isFalse);

    await app.setMemoryEnabled(true);
    await tester.pump();
    expect(app.effectiveShareSessionMemory, isTrue);
    expect(find.textContaining('Requires Memory'), findsNothing);
  });

  test('response wait limit is clamped to at least 30 s', () async {
    await app.setResponseTimeout(5);
    expect(app.responseTimeoutSec, AppState.minResponseTimeoutSec);
    expect(AppState.minResponseTimeoutSec, greaterThanOrEqualTo(30));
    await app.setResponseTimeout(99999);
    expect(app.responseTimeoutSec, AppState.maxResponseTimeoutSec);
  });

  testWidgets('wait limit slider starts at the minimum and warns below 60 s', (
    tester,
  ) async {
    await app.setResponseTimeout(30);
    await pumpSettings(tester);
    await open(tester, 'Response wait limit');
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.min, greaterThanOrEqualTo(30));
    expect(find.byKey(const ValueKey('timeout-low-warning')), findsOneWidget);
    expect(find.textContaining('not a cap on the'), findsOneWidget);
  });

  group('context window override', () {
    ChatSession session(String model) {
      final s = ChatSession(id: 'ctx', title: 'ctx', model: model);
      app.sessions.add(s);
      app.activeSessionId = s.id;
      return s;
    }

    test('never exceeds the model window', () async {
      final s = session('gpt-4o');
      await app.setContextWindowOverride(1000000);
      expect(AgentService.contextWindowForSession(s), 128000);
      expect(AgentService.contextOverrideAppliesTo(s), isFalse);
      await app.setContextWindowOverride(32768);
      expect(AgentService.contextWindowForSession(s), 32768);
      expect(AgentService.contextOverrideAppliesTo(s), isTrue);
      expect(AgentService.effectiveContextWindow(0, 128000), 128000);
    });

    testWidgets('a 32K override shows "(override)"', (tester) async {
      session('gpt-4o');
      await app.setContextWindowOverride(32768);
      await pumpSettings(tester);
      await open(tester, 'Context & output');
      expect(find.textContaining('32K tokens (override)'), findsOneWidget);
      expect(find.textContaining('Model window: 128K'), findsOneWidget);
      // 1M is larger than gpt-4o's window: not offered.
      final oneM = find.ancestor(
        of: find.text('1M'),
        matching: find.byType(RadioListTile<int>),
      );
      expect(tester.widget<RadioListTile<int>>(oneM).enabled, isFalse);
    });
  });

  group('custom preset ids', () {
    test('a built-in id is rejected and never shadows the built-in', () {
      final before = PresetRegistry.all.length;
      expect(PresetRegistry.validateNewCustomId('standard'), isNotNull);
      expect(PresetRegistry.validateNewCustomId('Bad Id!'), isNotNull);
      expect(
        () => PresetRegistry.saveCustom(
          const AgentPreset(id: 'standard', label: 'Shadow', description: ''),
        ),
        throwsArgumentError,
      );
      expect(PresetRegistry.all.length, before);
      expect(PresetRegistry.byId('standard').label, 'Standard');
    });

    test('generated ids are valid and unique', () {
      final ids = {for (var i = 0; i < 50; i++) PresetRegistry.newCustomId()};
      expect(ids.length, 50);
      for (final id in ids) {
        expect(PresetRegistry.customIdPattern.hasMatch(id), isTrue);
        expect(id, startsWith('custom_'));
      }
    });

    testWidgets('duplicating Standard creates a custom preset and reveals it', (
      tester,
    ) async {
      await pumpSettings(tester);
      await open(tester, 'Agent presets');
      final before = PresetRegistry.all.length;
      await tester.tap(find.byTooltip('Duplicate as custom').first);
      await tester.pumpAndSettle();
      expect(find.text('Preset ID'), findsNothing);
      await tester.enterText(find.byType(TextField), 'My standard');
      await tester.tap(find.text('Duplicate'));
      await tester.pumpAndSettle();

      expect(PresetRegistry.all.length, before + 1);
      final created = PresetRegistry.customPresets.single;
      expect(created.id, startsWith('custom_'));
      expect(PresetRegistry.byId('standard').label, 'Standard');
      expect(find.text("Created 'My standard'"), findsOneWidget);
      // Scrolled to and expanded: its configuration is visible.
      expect(find.text('My standard'), findsOneWidget);
      expect(find.byKey(const ValueKey('preset-model-pick')), findsOneWidget);
    });

    testWidgets('model pin picker searches and stores provider + model', (
      tester,
    ) async {
      app.providers.add(
        ProviderConfig(
          id: 'gw-a',
          name: 'Gateway A',
          description: '',
          baseUrl: 'https://a.test/v1',
          models: ['shared-model', 'alpha-only'],
        ),
      );
      await app.saveCustomPreset(
        const AgentPreset(id: 'custom_pin', label: 'Pin me', description: ''),
      );
      await pumpSettings(tester);
      await open(tester, 'Agent presets');
      await tester.scrollUntilVisible(
        find.text('Pin me'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byTooltip('Configure denied tools').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('preset-model-pick')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('preset-model-pick')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('preset-model-pick')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('preset-model-search')),
        'alpha',
      );
      await tester.pump();
      expect(find.text('shared-model'), findsNothing);
      await tester.tap(find.text('alpha-only'));
      await tester.pumpAndSettle();
      final pinned = PresetRegistry.byId('custom_pin');
      expect(pinned.model, 'alpha-only');
      expect(pinned.modelProviderId, 'gw-a');
      expect(AgentPreset.fromJson(pinned.toJson()).modelProviderId, 'gw-a');
    });
  });
}
