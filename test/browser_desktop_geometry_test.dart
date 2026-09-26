import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/browser_screen.dart';

/// Desktop mode must give the WebView REAL desktop geometry (2026-09-24).
///
/// Before this, the WebView sat in a bare `Expanded` and was hard-constrained to
/// the phone screen; "desktop mode" only spoofed the UA, faked `innerWidth` in
/// JS, and injected a `<meta viewport width=1280>` that the page's own
/// `width=device-width` always won (Chromium: last meta wins). CSS media
/// queries, `vw`/`vh` and `visualViewport` read the REAL layout viewport, which
/// JS cannot fake — so sites kept their mobile layout and the owner's complaint
/// ("many websites require desktop size") was never addressed.
///
/// These assert the *layout*, which is the part that actually decides how a page
/// renders. On-device confirmation still needs the clientWidth probe (see the
/// design doc): a widget test proves the Flutter geometry, not what Chromium
/// does with it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const stubKey = Key('stub-webview');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    AppState.createForTest().seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I
      ..debugPauseScheduleTimerForTest(true)
      ..clearBrowserTabsForTest();
    browserWebViewBuilderForTest = (_) =>
        const ColoredBox(key: stubKey, color: Color(0xFF123456));
  });

  tearDown(() {
    browserWebViewBuilderForTest = null;
    AgentService.I
      ..clearBrowserTabsForTest()
      ..debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  Future<void> pumpWithTab(WidgetTester tester, BrowserTab tab) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    AgentService.I.browserTabs.add(tab);
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const BrowserScreen()),
    );
    await tester.pump();
  }

  test('the desktop geometry matches what the native side advertises', () {
    // If these diverge, the page's own layout logic contradicts the metrics it
    // reads back from window.innerWidth.
    expect(browserDesktopLogicalSize.width, BrowserTab.desktopLogicalWidth);
    expect(browserDesktopLogicalSize.height, BrowserTab.desktopLogicalHeight);
  });

  testWidgets('a desktop tab is laid out at 1280x800, not the phone size',
      (tester) async {
    await pumpWithTab(
      tester,
      BrowserTab(url: 'https://example.test/', desktopMode: true),
    );

    // The view really is desktop-sized at layout time.
    expect(tester.getSize(find.byKey(stubKey)), browserDesktopLogicalSize);

    // ...and it is scaled rather than overflowing the screen.
    expect(tester.takeException(), isNull);
    final fitted = find.byType(FittedBox);
    expect(fitted, findsWidgets);
    expect(
      tester.widgetList<FittedBox>(fitted).any((f) => f.fit == BoxFit.contain),
      isTrue,
      reason: 'the desktop view must be scaled to fit, not clipped',
    );

    // FILLS THE HEIGHT (2026-09-25). `BoxFit.contain` scaled to the WIDTH, so on
    // this 400x900 test device the page came out 400/1280*800 = 250dp tall
    // inside a much taller frame — a desktop page as a postage stamp with dead
    // space below it. It must now occupy the whole available height, with the
    // leftover width reachable by scrolling sideways.
    final scroller = find.byType(SingleChildScrollView);
    expect(
      scroller,
      findsWidgets,
      reason: 'the overflow width must be scrollable, not clipped away',
    );
    final viewportH = tester.getSize(scroller.first).height;
    expect(
      viewportH,
      greaterThan(250),
      reason: 'a width-driven contain fit left the page ~250dp tall',
    );
    final paintedW = browserDesktopLogicalSize.width *
        viewportH /
        browserDesktopLogicalSize.height;
    expect(
      tester.widgetList<SizedBox>(find.byType(SizedBox)).any(
            (b) =>
                b.height == viewportH &&
                b.width != null &&
                (b.width! - paintedW).abs() < 0.5,
          ),
      isTrue,
      reason: 'the painted frame must span the full height at desktop aspect',
    );
    // The WebView itself is still laid out at REAL 1280x800 — only the paint is
    // scaled. If the layout size followed the screen, `width=device-width` would
    // resolve to the phone width and the page would go mobile again.
    expect(desktopFrameCount(tester), 1);
  });

  testWidgets('a mobile tab still fills the screen unchanged', (tester) async {
    await pumpWithTab(
      tester,
      BrowserTab(url: 'https://example.test/', desktopMode: false),
    );

    // No desktop framing at all. (The stub is a childless ColoredBox, which
    // collapses under IndexedStack's loose constraints, so its own size is not
    // a meaningful assertion — the absence of the 1280x800 frame is.)
    expect(tester.getSize(find.byKey(stubKey)), isNot(browserDesktopLogicalSize));
    expect(desktopFrameCount(tester), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('toggling desktop mode changes the laid-out size',
      (tester) async {
    final tab = BrowserTab(url: 'https://example.test/', desktopMode: false);
    await pumpWithTab(tester, tab);
    expect(desktopFrameCount(tester), 0, reason: 'mobile: no desktop frame');

    tab.desktopMode = true;
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const BrowserScreen()),
    );
    await tester.pump();
    expect(tester.getSize(find.byKey(stubKey)), browserDesktopLogicalSize);
    expect(desktopFrameCount(tester), 1, reason: 'desktop: one 1280x800 frame');
  });
}

/// How many 1280x800 frames the screen currently lays out. Zero for a mobile
/// tab, exactly one for a desktop tab.
int desktopFrameCount(WidgetTester tester) => tester
    .widgetList<SizedBox>(find.byType(SizedBox))
    .where((b) =>
        b.width == browserDesktopLogicalSize.width &&
        b.height == browserDesktopLogicalSize.height)
    .length;
