// V2 UI — slim browser chrome tests.
//
// The browser's six stacked bands are consolidated into a premium slim
// chrome: ONE omnibar (back/forward/reload + URL + go, with desktop-view /
// open-external / new-tab inline on wide and overflowing to the omnibar's
// second line on narrow), ONE status caption (leave affordance + agent/ready
// dot + host), the hairline progress bar, and the tab strip only when more
// than one tab is open. These tests pin that contract:
//   * the omnibar renders and its nav controls drive the tab controller,
//   * the status caption shows the agent dot + ready host,
//   * the tab strip appears with >1 tabs and closes tabs,
//   * the desktop toggle switches the tab between phone and 1280×800,
//   * narrow widths move the secondary actions into the omnibar overflow
//     line (still mounted, still hittable — a popup menu would hide them
//     from tooltips finders the older suites rely on),
//   * 360×640 @2× and a wide 1024×768 layout.
//
// Same seams as the ui_redesign suites (AppState.createForTest,
// AgentService.debugPauseScheduleTimerForTest / clearBrowserTabsForTest,
// browserWebViewBuilderForTest). Pumps are bounded — the pulsing status dot
// rules out pumpAndSettle.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
// Replace only the native boundary; toolbar callbacks and tab state stay real.
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/browser_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

class _NavigationController extends PlatformWebViewController {
  _NavigationController()
    : super.implementation(const PlatformWebViewControllerCreationParams());

  final events = <String>[];
  bool historyAvailable = true;

  @override
  Future<bool> canGoBack() async => historyAvailable;
  @override
  Future<bool> canGoForward() async => historyAvailable;
  @override
  Future<void> goBack() async {
    events.add('back');
  }

  @override
  Future<void> goForward() async {
    events.add('forward');
  }

  @override
  Future<void> reload() async {
    events.add('reload');
  }

  @override
  Future<void> loadFile(String absoluteFilePath) async {
    events.add('file:$absoluteFilePath');
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    events.add('url:${params.uri}');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const stubKey = Key('v2-browser-stub');

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

  Future<void> pumpBrowser(
    WidgetTester tester, {
    Size size = const Size(360, 640),
    double scale = 2.0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
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
        home: const BrowserScreen(),
      ),
    );
    await tester.pump();
  }

  testWidgets('omnibar renders and nav controls drive the tab controller', (
    tester,
  ) async {
    final native = _NavigationController();
    final tab = BrowserTab(url: 'https://example.test/')
      ..controller = WebViewController.fromPlatform(native)
      ..profileBound = true;
    AgentService.I.browserTabs.add(tab);
    await pumpBrowser(tester);

    // ONE omnibar: one gradient header band holding the only address field,
    // the inline nav actions (back/forward/reload inside the field), and Go.
    final header = find.byType(AetherGradientHeader);
    expect(header, findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(
      find.byKey(const ValueKey('browser-url-field')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: header, matching: find.byType(AetherGhostButton)),
      findsOneWidget, // only Go; nav icons are compact inline actions
    );
    expect(find.byKey(const ValueKey('browser-back')), findsOneWidget);
    expect(find.byKey(const ValueKey('browser-forward')), findsOneWidget);
    expect(find.byKey(const ValueKey('browser-reload')), findsOneWidget);
    expect(find.byTooltip('Go'), findsOneWidget);

    // Nav works: history guards pass through to the tab's controller.
    for (final action in ['back', 'forward', 'reload']) {
      await tester.tap(find.byKey(ValueKey('browser-$action')));
      await tester.pump();
    }
    expect(native.events, ['back', 'forward', 'reload']);

    // Go navigates: free text becomes a search URL on the same tab.
    await tester.enterText(find.byType(TextField), 'flutter layout');
    await tester.tap(find.byTooltip('Go'));
    await tester.pump();
    expect(
      native.events.last,
      'url:https://www.google.com/search?q=flutter%20layout',
    );
    expect(
      tab.url,
      'https://www.google.com/search?q=flutter%20layout',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('status caption shows the agent dot and the ready host', (
    tester,
  ) async {
    AgentService.I.browserTabs.add(
      BrowserTab(url: 'https://example.test/page')..title = 'Some page',
    );
    await pumpBrowser(tester);

    expect(
      find.byKey(const ValueKey('browser-status-dot')),
      findsOneWidget,
    );
    expect(find.byType(AetherStatusDot), findsOneWidget);
    expect(find.textContaining('Ready · example.test'), findsOneWidget);
    // The state travels with the dot as a label, not colour alone.
    expect(
      find.bySemanticsLabel('Agent idle on this tab'),
      findsOneWidget,
    );
    expect(find.byTooltip('Agent idle on this tab'), findsOneWidget);
    // A way out of the browser rides in the same caption row.
    expect(find.byTooltip('Close browser'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tab strip appears with more than one tab and closes tabs', (
    tester,
  ) async {
    final first = BrowserTab(url: 'https://a.test/')..title = 'First page';
    final second = BrowserTab(url: 'https://b.test/')..title = 'Second page';
    AgentService.I.browserTabs.addAll([first, second]);
    await pumpBrowser(tester);

    expect(find.bySemanticsLabel('Close tab'), findsNWidgets(2));
    // Selecting the second tab syncs the omnibar.
    await tester.tap(find.text('Second page'));
    await tester.pump();
    expect(AgentService.I.activeTabIndex, 1);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Second page',
    );
    // Closing it drops back to one tab and the strip hides.
    await tester.tap(find.byKey(ValueKey('browser-close-${second.id}')));
    await tester.pump();
    expect(AgentService.I.browserTabs, [first]);
    expect(find.bySemanticsLabel('Close tab'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'First page',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tab strip stays hidden with a single tab', (tester) async {
    AgentService.I.browserTabs.add(BrowserTab(url: 'https://solo.test/'));
    await pumpBrowser(tester);
    expect(find.bySemanticsLabel('Close tab'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('desktop toggle switches the tab between phone and 1280x800', (
    tester,
  ) async {
    // An empty-url tab never constructs a real WebViewController on toggle,
    // so the whole desktop path runs against the stubbed view.
    final tab = BrowserTab(url: '');
    AgentService.I.browserTabs.add(tab);
    await pumpBrowser(tester);

    expect(tab.desktopMode, isFalse);
    expect(
      tester.getSize(find.byKey(stubKey)),
      isNot(browserDesktopLogicalSize),
    );

    await tester.tap(find.byTooltip('Switch to desktop view'));
    await tester.pump();
    await tester.pump();
    expect(tab.desktopMode, isTrue);
    expect(
      tester.getSize(find.byKey(stubKey)),
      browserDesktopLogicalSize,
    );

    await tester.tap(find.byTooltip('Switch to mobile view'));
    await tester.pump();
    await tester.pump();
    expect(tab.desktopMode, isFalse);
    expect(
      tester.getSize(find.byKey(stubKey)),
      isNot(browserDesktopLogicalSize),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'narrow widths move secondary actions into the omnibar overflow line',
    (tester) async {
      AgentService.I.browserTabs.add(BrowserTab(url: 'https://example.test/'));
      await pumpBrowser(tester); // 360×640 @2× — narrow

      final field = find.byType(TextField);
      final fieldBottom = tester.getBottomLeft(field).dy;
      // Desktop / open-external / new-tab sit on the omnibar's second line,
      // below the address row — and stay mounted and hittable.
      for (final label in [
        'Switch to desktop view',
        'Open in browser',
        'New tab',
      ]) {
        final action = find.byTooltip(label);
        expect(action.hitTestable(), findsOneWidget, reason: label);
        expect(
          tester.getTopLeft(action).dy,
          greaterThanOrEqualTo(fieldBottom),
          reason: '$label must overflow below the address row on narrow',
        );
      }
      // The overflow actions still work from the second line.
      await tester.tap(find.byTooltip('New tab'));
      await tester.pump();
      expect(AgentService.I.browserTabs, hasLength(2));
      expect(find.bySemanticsLabel('Close tab'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('wide widths keep one omnibar row with actions inline', (
    tester,
  ) async {
    AgentService.I.browserTabs.add(BrowserTab(url: 'https://example.test/'));
    await pumpBrowser(tester, size: const Size(1024, 768), scale: 1.0);

    final field = find.byType(TextField);
    expect(tester.getSize(field).width, greaterThanOrEqualTo(240));
    final fieldTop = tester.getTopLeft(field).dy;
    // Nav, go and the secondary actions all share the address row's line.
    for (final finder in [
      find.byKey(const ValueKey('browser-back')),
      find.byKey(const ValueKey('browser-forward')),
      find.byKey(const ValueKey('browser-reload')),
      find.byTooltip('Go'),
      find.byTooltip('Switch to desktop view'),
      find.byTooltip('Open in browser'),
      find.byTooltip('New tab'),
    ]) {
      expect(finder.hitTestable(), findsOneWidget);
      expect(
        (tester.getTopLeft(finder).dy - fieldTop).abs(),
        lessThan(12),
        reason: 'wide layout keeps every omnibar control on one row',
      );
    }
    // The status caption sits directly under the single omnibar band.
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('browser-status-dot'))).dy,
      greaterThan(tester.getBottomLeft(field).dy),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
