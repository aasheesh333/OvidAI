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
import 'package:ovid_ai/ui/widgets/ovid_mark.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/Inter.ttf'))).load();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    AppState.I.sessions
      ..clear()
      ..addAll(
        List.generate(
          50,
          (i) => ChatSession(
            id: 'layout-$i',
            title: 'Session $i',
            model: 'model-$i',
          ),
        ),
      );
    AppState.I.activeSessionId = 'layout-0';
  });

  tearDown(() {
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  Future<void> pumpSidebar(
    WidgetTester tester, {
    required Size size,
    double scale = 1,
    bool drawer = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          drawer: drawer
              ? const Drawer(width: 288, child: SessionsSidebar())
              : null,
          body: drawer
              ? const SizedBox.expand()
              : const Row(children: [SessionsSidebar(isDrawer: false)]),
        ),
      ),
    );
    if (drawer) {
      tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    }
    await tester.pumpAndSettle();
  }

  final sessionScroll = find.descendant(
    of: find.byType(SessionsSidebar),
    matching: find.byWidgetPredicate(
      (w) =>
          w is Scrollable &&
          axisDirectionToAxis(w.axisDirection) == Axis.vertical,
    ),
  );

  for (final scenario in [
    (name: 'embedded', size: const Size(1000, 800), scale: 1.0, drawer: false),
    (
      name: 'narrow drawer',
      size: const Size(320, 640),
      scale: 1.0,
      drawer: true,
    ),
    (
      name: 'short drawer',
      size: const Size(320, 360),
      scale: 1.0,
      drawer: true,
    ),
    (name: 'large text', size: const Size(320, 800), scale: 2.0, drawer: true),
    (
      name: 'short with large text',
      size: const Size(320, 400),
      scale: 2.0,
      drawer: true,
    ),
    (
      name: 'very short with large text',
      size: const Size(320, 320),
      scale: 2.0,
      drawer: true,
    ),
    (
      name: 'constrained width with large text',
      size: const Size(240, 400),
      scale: 2.0,
      drawer: true,
    ),
  ]) {
    testWidgets('${scenario.name}: only sessions move when scrolling', (
      tester,
    ) async {
      await pumpSidebar(
        tester,
        size: scenario.size,
        scale: scenario.scale,
        drawer: scenario.drawer,
      );
      expect(tester.takeException(), isNull);
      expect(sessionScroll, findsOneWidget);

      final brand = find.byType(OvidMark);
      final search = find.byType(TextField);
      final settings = find.byIcon(Icons.settings_outlined);
      expect(
        settings.hitTestable(),
        findsOneWidget,
        reason: 'Footer must be reachable before scrolling through sessions',
      );
      final brandRect = tester.getRect(brand);
      final searchRect = tester.getRect(search);
      final settingsRect = tester.getRect(settings);
      expect(
        settings.hitTestable(),
        findsOneWidget,
        reason: 'Footer must be reachable before scrolling through sessions',
      );
      expect(search.hitTestable(), findsOneWidget);
      expect(find.text('New session').hitTestable(), findsOneWidget);
      final viewport = tester.getRect(sessionScroll);
      expect(viewport.height, greaterThanOrEqualTo(48));
      expect(find.text('Session 0').hitTestable(), findsOneWidget);
      final firstSessionTop = tester.getTopLeft(find.text('Session 0')).dy;

      await tester.drag(sessionScroll, Offset(0, -viewport.height * .8));
      await tester.pumpAndSettle();

      expect(
        tester.state<ScrollableState>(sessionScroll).position.pixels,
        greaterThan(0),
      );
      expect(tester.getRect(brand), brandRect);
      expect(tester.getRect(search), searchRect);
      expect(tester.getRect(settings), settingsRect);
      expect(settings.hitTestable(), findsOneWidget);
      if (find.text('Session 0').evaluate().isNotEmpty) {
        expect(
          tester.getTopLeft(find.text('Session 0')).dy,
          lessThan(firstSessionTop),
        );
      }
      expect(tester.takeException(), isNull);

      await tester.scrollUntilVisible(
        find.text('Session 49'),
        180,
        scrollable: sessionScroll,
      );
      await tester.pumpAndSettle();
      expect(find.text('Session 49').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Session 49'));
      await tester.pumpAndSettle();
      expect(AppState.I.activeSessionId, 'layout-49');
      if (scenario.drawer) {
        expect(
          tester.state<ScaffoldState>(find.byType(Scaffold)).isDrawerOpen,
          isFalse,
        );
      }
    });
  }

  testWidgets('filter and empty states keep the footer pinned', (tester) async {
    await pumpSidebar(tester, size: const Size(1000, 800));
    final settings = find.byIcon(Icons.settings_outlined);
    final footerRect = tester.getRect(settings);
    await tester.enterText(find.byType(TextField), 'model-49');
    await tester.pumpAndSettle();
    expect(find.text('Session 49').hitTestable(), findsOneWidget);
    expect(find.text('Session 0'), findsNothing);
    expect(tester.getRect(settings), footerRect);

    await tester.enterText(find.byType(TextField), 'no match');
    await tester.pumpAndSettle();
    expect(
      find.text('No sessions match "no match"').hitTestable(),
      findsOneWidget,
    );
    expect(tester.getRect(settings), footerRect);
    await tester.tap(find.byTooltip('Clear session search'));
    await tester.pumpAndSettle();
    expect(find.text('Session 0').hitTestable(), findsOneWidget);

    AppState.I.sessions.clear();
    await tester.enterText(find.byType(TextField), 'empty');
    await tester.pump();
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('No sessions yet').hitTestable(), findsOneWidget);
    expect(tester.getRect(settings), footerRect);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact footer keeps labelled actions and new session usable', (
    tester,
  ) async {
    await pumpSidebar(tester, size: const Size(320, 400), scale: 2);
    for (final label in ['Schedule', 'Trajectory — event ledger', 'Settings']) {
      expect(find.byTooltip(label).hitTestable(), findsOneWidget);
      final button = find.widgetWithIcon(IconButton, switch (label) {
        'Schedule' => Icons.schedule_outlined,
        'Settings' => Icons.settings_outlined,
        _ => Icons.timeline_outlined,
      });
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      expect(tester.widget<IconButton>(button).onPressed, isNotNull);
    }
    final count = AppState.I.sessions.length;
    await tester.tap(find.text('New session'));
    await tester.pumpAndSettle();
    expect(AppState.I.sessions.length, count + 1);
    expect(find.byType(SessionsSidebar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
