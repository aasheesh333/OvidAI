import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/sidebar.dart';

/// v2 nav restructure (2026-10-06) — sidebar destination band + single
/// drawer wiring.
///
/// Covers:
///  1. The footer nav band renders the six destinations (Chat, Studio,
///     Activity, Library, Money, Plugins) plus Schedule and Settings in
///     one consistent ghost-row style, all enabled when a session is
///     active.
///  2. Session-gated rows (Activity, Schedule) never disable silently:
///     the chevron swaps to a visible "Needs a chat" marker and the row
///     tooltip explains why.
///  3. The narrow-screen Drawer is declared in exactly one place
///     (ChatScreen's Scaffold) — the shell's duplicate is gone.
///  4. "New session" creates exactly one session.
///  5. The session list renders seeded sessions.
///  6. Layout holds at 360×640 @2× (drawer mode) and wide (hover
///     highlight on the nav rows).
///
/// All pumps are bounded; no pumpAndSettle without a timeout, no
/// runAsync.
/// Destination label → the key stamped on its nav row's InkWell.
const _navKeys = <String, String>{
  'Chat': 'sidebar-nav-chat',
  'Studio': 'sidebar-nav-studio',
  'Activity': 'sidebar-nav-activity',
  'Library': 'sidebar-nav-library',
  'Money': 'sidebar-nav-money',
  'Plugins': 'sidebar-nav-plugins',
  'Schedule': 'sidebar-nav-schedule',
  'Settings': 'sidebar-nav-settings',
};

const _sixDestinations = <String>[
  'Chat',
  'Studio',
  'Activity',
  'Library',
  'Money',
  'Plugins',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The app theme uses the bundled Inter font; the test VM has no Inter
  // installed, so without this the fallback font's wider glyphs can
  // overflow tight rows (same guard as worker_d_sidebar_fixes_test).
  setUpAll(() async {
    final bytes = await File('assets/fonts/Inter.ttf').readAsBytes();
    await (FontLoader(
      'Inter',
    )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDownAll(() {
    AgentService.I.debugPauseScheduleTimerForTest(false);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    AppState.I.sessions.clear();
    AppState.I.activeSessionId = null;
  });

  tearDown(() {
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  ChatSession seedSession(String id, String title, {bool active = false}) {
    final s = ChatSession(id: id, title: title, model: 'test-model');
    AppState.I.sessions.add(s);
    if (active) AppState.I.activeSessionId = id;
    return s;
  }

  Future<void> pumpSidebar(
    WidgetTester tester, {
    bool isDrawer = false,
    Size physicalSize = const Size(360, 900),
    double dpr = 1.0,
  }) async {
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Scaffold(body: SessionsSidebar(isDrawer: isDrawer)),
      ),
    );
    await tester.pump();
  }

  InkWell navRow(WidgetTester tester, String label) =>
      tester.widget<InkWell>(find.byKey(ValueKey(_navKeys[label]!)));

  group('footer destination nav band', () {
    testWidgets(
      'six destinations render and every row is enabled with a session',
      (tester) async {
        seedSession('s1', 'Alpha work', active: true);
        await pumpSidebar(tester);

        // The six destinations, plus the pre-existing Schedule and
        // Settings rows, all render exactly once.
        for (final label in _navKeys.keys) {
          expect(
            find.text(label),
            findsOneWidget,
            reason: 'destination "$label" must render in the nav band',
          );
        }
        // Activity keeps the legacy ledger name as its caption.
        expect(find.text('Trajectory — event ledger'), findsOneWidget);

        // Enabled state: every row's InkWell has a live onTap.
        for (final label in _navKeys.keys) {
          expect(
            navRow(tester, label).onTap,
            isNotNull,
            reason: 'destination "$label" must be enabled with a session',
          );
        }
        // No disabled markers anywhere.
        expect(find.text('Needs a chat'), findsNothing);
      },
    );

    testWidgets('gated rows explain their disabled state, never silent', (
      tester,
    ) async {
      // No active session → Activity and Schedule are gated.
      await pumpSidebar(tester);

      for (final label in _sixDestinations) {
        expect(
          find.text(label),
          findsOneWidget,
          reason: 'destination "$label" still renders when gated',
        );
      }

      // The two gated rows are disabled…
      expect(navRow(tester, 'Activity').onTap, isNull);
      expect(navRow(tester, 'Schedule').onTap, isNull);
      // …but never silently: a visible marker replaces the chevron…
      expect(find.text('Needs a chat'), findsNWidgets(2));
      // …and each row's tooltip carries the explanation.
      final activityTip = tester.widget<Tooltip>(
        find.ancestor(
          of: find.byKey(const ValueKey('sidebar-nav-activity')),
          matching: find.byType(Tooltip),
        ),
      );
      expect(activityTip.message, 'Start a chat to view activity');
      final scheduleTip = tester.widget<Tooltip>(
        find.ancestor(
          of: find.byKey(const ValueKey('sidebar-nav-schedule')),
          matching: find.byType(Tooltip),
        ),
      );
      expect(scheduleTip.message, 'Start a chat to schedule runs');

      // Everything else stays enabled.
      for (final label in [
        'Chat',
        'Studio',
        'Library',
        'Money',
        'Plugins',
        'Settings',
      ]) {
        expect(
          navRow(tester, label).onTap,
          isNotNull,
          reason: '"$label" is not session-gated',
        );
      }
    });

    testWidgets(
      'decoupled destinations: no-op unregistered, fire when registered',
      (tester) async {
        SidebarNav.debugClear();
        addTearDown(SidebarNav.debugClear);
        await pumpSidebar(tester);

        // Unregistered (no shell in this harness): tap is a safe no-op.
        await tester.tap(find.byKey(const ValueKey('sidebar-nav-studio')));
        await tester.pump();
        expect(tester.takeException(), isNull);

        // Once the shell registers a pusher, the same row fires it.
        var studioPushes = 0;
        SidebarNav.register(SidebarNav.studio, (_) => studioPushes++);
        await tester.tap(find.byKey(const ValueKey('sidebar-nav-studio')));
        await tester.pump();
        expect(studioPushes, 1);

        var settingsPushes = 0;
        SidebarNav.register(SidebarNav.settings, (_) => settingsPushes++);
        await tester.tap(find.byKey(const ValueKey('sidebar-nav-settings')));
        await tester.pump();
        expect(settingsPushes, 1);
      },
    );
  });

  group('single drawer declaration path', () {
    test('shell declares no Drawer; exactly one Drawer( remains in lib/ui', () {
      final shellSrc = File('lib/ui/shell.dart').readAsStringSync();
      expect(
        shellSrc.contains('Drawer('),
        isFalse,
        reason:
            'the shell must not declare the narrow drawer — ChatScreen owns it',
      );

      final drawerSites = <String, int>{};
      for (final entity in Directory('lib/ui').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final count = 'Drawer('.allMatches(entity.readAsStringSync()).length;
        if (count > 0) drawerSites[entity.path] = count;
      }
      expect(
        drawerSites,
        hasLength(1),
        reason:
            'a second Drawer declaration means the duplicate wiring is back: '
            '$drawerSites',
      );
      expect(drawerSites.keys.single, endsWith('chat_screen.dart'));
      expect(drawerSites.values.single, 1);
    });
  });

  group('sessions', () {
    testWidgets('New session creates exactly one session', (tester) async {
      seedSession('s1', 'Alpha work', active: true);
      await pumpSidebar(tester);

      final before = AppState.I.sessions.length;
      await tester.tap(find.text('New session'));
      // Bounded pumps only — newSession() is synchronous.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        AppState.I.sessions.length,
        before + 1,
        reason: 'one tap on New session must create exactly one session',
      );
    });

    testWidgets('session list renders seeded sessions', (tester) async {
      seedSession('s1', 'Alpha work', active: true);
      seedSession('s2', 'Beta research');
      seedSession('s3', 'Gamma planning');
      await pumpSidebar(tester);

      expect(find.text('SESSIONS'), findsOneWidget);
      expect(find.text('Alpha work'), findsOneWidget);
      expect(find.text('Beta research'), findsOneWidget);
      expect(find.text('Gamma planning'), findsOneWidget);
    });
  });

  group('form factors', () {
    testWidgets('renders at 360×640 @2× (drawer mode) without overflow', (
      tester,
    ) async {
      seedSession('s1', 'Alpha work', active: true);
      // 360×640 logical @2× → 720×1280 physical.
      await pumpSidebar(
        tester,
        isDrawer: true,
        physicalSize: const Size(720, 1280),
        dpr: 2.0,
      );

      for (final label in _sixDestinations) {
        expect(find.text(label), findsOneWidget, reason: '$label @2×');
      }
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Trajectory — event ledger'), findsOneWidget);
      expect(find.text('New session'), findsOneWidget);
      expect(find.text('Alpha work'), findsOneWidget);
      // Drawer mode keeps the close affordance.
      expect(find.byTooltip('Close sidebar'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('wide: nav rows highlight on hover; Chat tap is a safe no-op', (
      tester,
    ) async {
      seedSession('s1', 'Alpha work', active: true);
      await pumpSidebar(
        tester,
        physicalSize: const Size(1200, 800),
      );

      // Wide mode embeds the sidebar — no drawer close button.
      expect(find.byTooltip('Close sidebar'), findsNothing);

      // Every nav row carries the Aether hover tint (the wide-pointer
      // hover highlight).
      for (final label in _navKeys.keys) {
        expect(
          navRow(tester, label).hoverColor,
          Aether.surfaceAlt,
          reason: '"$label" must hover-highlight on wide pointers',
        );
      }

      // Actually hover the Studio row with a mouse pointer.
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('sidebar-nav-studio'))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);

      // Chat in wide mode pops any pushed route back to the embedded
      // chat; with nothing pushed it is a safe no-op.
      await tester.tap(find.byKey(const ValueKey('sidebar-nav-chat')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(SessionsSidebar), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
