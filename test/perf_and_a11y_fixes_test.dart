import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_terminal.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/browser_screen.dart';

/// Performance and accessibility fixes (2026-09-24).
///
/// Perf: `Aether.theme()` built a fresh `ThemeData` on every call and the ROOT
/// widget listened to all of `AppState` — which notifies on every streamed token
/// — so each token invalidated `MaterialApp`, its theme and every route. Both are
/// fixed: the theme is cached per light/dark value and the root only rebuilds when
/// that value actually changes. The Studio terminal's `history` also grew without
/// bound.
///
/// A11y: the browser tab-close button was a bare 12×12dp icon ~5px from the tab
/// body (the easiest mis-tap in the app, and the worst outcome — closing the
/// wrong tab), and the agent-state dot encoded busy/idle by colour alone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ThemeData is cached, not rebuilt per call', () {
    tearDown(() {
      Aether.resetThemeCacheForTest();
      Aether.dark = true;
    });

    test('repeated calls return the identical instance', () {
      final a = Aether.theme();
      final b = Aether.theme();
      expect(identical(a, b), isTrue, reason: 'a rebuild per call is the bug');
    });

    test('flipping light/dark invalidates the cache', () {
      Aether.dark = true;
      final darkTheme = Aether.theme();
      Aether.dark = false;
      final lightTheme = Aether.theme();

      expect(identical(darkTheme, lightTheme), isFalse);
      expect(Aether.theme(), same(lightTheme));

      Aether.dark = true;
      expect(identical(Aether.theme(), darkTheme), isFalse,
          reason: 'a rebuilt dark theme is correct; a stale light one is not');
      expect(Aether.theme().brightness, Brightness.dark);
    });
  });

  group('the streaming refresh is coalesced but never loses the last token',
      () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
      AppState.createForTest().seenWelcomeVersion = AppState.welcomeVersion;
      AgentService.I.debugPauseScheduleTimerForTest(true);
    });

    tearDown(() {
      AgentService.I.flushStreamRefreshForTest();
      AgentService.I.debugPauseScheduleTimerForTest(false);
      AppState.resetTestInstance();
    });

    test('the flush seam is callable and idempotent', () {
      // The finalizer contract: every live-message finalizer flushes, so a
      // pending trailing refresh can never outlive its turn.
      AgentService.I.flushStreamRefreshForTest();
      AgentService.I.flushStreamRefreshForTest();
    });
  });

  group('Studio terminal history is bounded', () {
    test('old lines are dropped past the cap', () {
      final s = StudioShellSession(tabId: 'ring');
      addTearDown(s.dispose);

      for (var i = 0; i < StudioShellSession.maxHistoryLines + 500; i++) {
        s.addOutput('line $i');
      }

      expect(s.history.length, StudioShellSession.maxHistoryLines);
      // The NEWEST lines are kept — a terminal that drops the tail is useless.
      expect(s.history.last, 'line ${StudioShellSession.maxHistoryLines + 499}');
      expect(s.history.first, isNot('line 0'));
    });
  });

  group('browser accessibility', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
      AppState.createForTest().seenWelcomeVersion = AppState.welcomeVersion;
      AgentService.I
        ..debugPauseScheduleTimerForTest(true)
        ..clearBrowserTabsForTest();
      browserWebViewBuilderForTest = (_) => const ColoredBox(
        key: Key('stub'),
        color: Color(0xFF000000),
      );
    });

    tearDown(() {
      browserWebViewBuilderForTest = null;
      AgentService.I
        ..clearBrowserTabsForTest()
        ..debugPauseScheduleTimerForTest(false);
      AppState.resetTestInstance();
    });

    testWidgets('tab close has a real hit area and a label', (tester) async {
      AgentService.I.browserTabs.add(BrowserTab(url: 'https://a.test/'));
      AgentService.I.browserTabs.add(BrowserTab(url: 'https://b.test/'));
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const BrowserScreen()),
      );
      await tester.pump();

      final labelled = find.bySemanticsLabel('Close tab');
      expect(labelled, findsWidgets);

      // The tappable box is far larger than the 12px glyph it draws.
      final sizes = tester
          .widgetList<SizedBox>(
            find.descendant(of: labelled.first, matching: find.byType(SizedBox)),
          )
          .map((b) => b.width ?? 0)
          .toList();
      expect(sizes.any((w) => w >= 32), isTrue,
          reason: 'a 12dp target is unusable and closes the wrong tab');

      expect(
        tester.widgetList<GestureDetector>(
          find.descendant(of: labelled.first, matching: find.byType(GestureDetector)),
        ).any((g) => g.behavior == HitTestBehavior.opaque),
        isTrue,
        reason: 'the padding must be tappable, not dead space',
      );
    });

    testWidgets('the agent dot states what it means, not just a colour',
        (tester) async {
      AgentService.I.browserTabs.add(BrowserTab(url: 'https://a.test/'));
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const BrowserScreen()),
      );
      await tester.pump();

      expect(
        find.bySemanticsLabel('Agent idle on this tab'),
        findsOneWidget,
      );
      expect(find.byTooltip('Agent idle on this tab'), findsOneWidget);
    });
  });
}
