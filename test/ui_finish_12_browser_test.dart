import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
// Replace only the native boundary; toolbar callbacks and tab state stay real.
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/html_artifact.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/browser_screen.dart';
import 'package:ovid_ai/ui/html_artifact_view.dart';

const _capture = bool.fromEnvironment('UI_REVIEW_CAPTURE');
const _boundaryKey = Key('ui-finish-12-boundary');
const _sizes = [
  (name: 'small2x', size: Size(360, 640), scale: 2.0),
  (name: 'small', size: Size(320, 640), scale: 1.0),
  (name: 'desktop', size: Size(1024, 768), scale: 1.0),
];

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
  Future<void> goBack() async { events.add('back'); }
  @override
  Future<void> goForward() async { events.add('forward'); }
  @override
  Future<void> reload() async { events.add('reload'); }
  @override
  Future<void> loadFile(String absoluteFilePath) async {
    events.add('file:$absoluteFilePath');
  }
  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    events.add('url:${params.uri}');
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  required Size size,
  required double scale,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: Aether.theme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: RepaintBoundary(key: _boundaryKey, child: child),
    ),
    home: screen,
  ));
  await tester.pump();
}

Future<void> _routeFrames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _waitForFullscreenExit(WidgetTester tester) async {
  // Exit awaits native disposal and an end-of-frame before starting its
  // reverse transition. Wait for removal, including the final disposal frame.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (find.byTooltip('Exit fullscreen').evaluate().isEmpty) return;
  }
  expect(find.byTooltip('Exit fullscreen'), findsNothing);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late bool previousDark;
  setUp(() {
    previousDark = Aether.dark;
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    AppState.createForTest().seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I
      ..debugPauseScheduleTimerForTest(true)
      ..clearBrowserTabsForTest();
    browserWebViewBuilderForTest = (tab) => SizedBox.expand(
      key: ValueKey('stub-${tab.id}'),
      child: ColoredBox(
        color: Aether.surface,
        child: Center(child: Text('WebView stub', style: TextStyle(color: Aether.textMuted))),
      ),
    );
  });
  tearDown(() {
    Aether.dark = previousDark;
    browserWebViewBuilderForTest = null;
    AgentService.I
      ..clearBrowserTabsForTest()
      ..debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  for (final configuration in _sizes) {
    for (final dark in [true, false]) {
      testWidgets('browser ${configuration.name} dark=$dark: chrome fits and tabs select/close', (tester) async {
        Aether.dark = dark;
        final first = BrowserTab(url: 'https://example.test/first')..title = 'First research page';
        final second = BrowserTab(url: 'https://second.test/page')..title = 'Second research page';
        AgentService.I.browserTabs.addAll([first, second]);
        await _pump(tester, const BrowserScreen(), size: configuration.size, scale: configuration.scale);
        expect(tester.takeException(), isNull);
        final field = find.byType(TextField);
        // Navigation shares the title row, on its right, with full hit targets.
        final titleRect = tester.getRect(field);
        expect(titleRect.width, greaterThanOrEqualTo(160));
        for (final action in ['back', 'forward', 'reload']) {
          final rect = tester.getRect(find.byKey(ValueKey('browser-$action')));
          expect(rect.left, greaterThanOrEqualTo(titleRect.right));
          expect(rect.center.dy, closeTo(titleRect.center.dy, 1));
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(rect.height, greaterThanOrEqualTo(48));
        }
        for (final label in ['Open in browser', 'New tab', 'Reload']) {
          expect(find.byTooltip(label).hitTestable(), findsOneWidget);
        }
        final close = find.bySemanticsLabel('Close tab').first;
        expect(tester.getSize(close).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(close).width, greaterThanOrEqualTo(48));

        final secondLabel = find.text('Second research page');
        await tester.ensureVisible(secondLabel);
        await tester.tap(secondLabel);
        await tester.pump();
        expect(AgentService.I.activeTabIndex, 1);
        expect(tester.widget<TextField>(field).controller!.text, 'Second research page');
        await tester.tap(field);
        await tester.pump();
        expect(tester.widget<TextField>(field).controller!.text, 'https://second.test/page');
        expect(tester.getSize(field).width, greaterThanOrEqualTo(240));
        for (final action in ['back', 'forward', 'reload']) {
          expect(find.byKey(ValueKey('browser-$action')), findsNothing);
        }
        expect(find.byTooltip('Go').hitTestable(), findsOneWidget);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        expect(find.byKey(const ValueKey('browser-reload')), findsOneWidget);
        final secondClose = find.byKey(ValueKey('browser-close-${second.id}'));
        await tester.ensureVisible(secondClose);
        await tester.tap(secondClose);
        await tester.pump();
        expect(AgentService.I.browserTabs, [first]);
        expect(tester.widget<TextField>(field).controller!.text, 'First research page');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('artifact ${configuration.name} dark=$dark: source, expand, exit and collapse remain usable', (tester) async {
        Aether.dark = dark;
        final artifact = HtmlArtifact.create('owner', {
          'title': 'A saved interactive artifact with a descriptive title',
          'html': '<p>Saved source marker</p>',
          'css': 'p { color: red; }',
          'javascript': 'console.log("saved script");',
          'height': 320,
        });
        await _pump(tester, Scaffold(body: SingleChildScrollView(
          child: HtmlArtifactView(artifact: artifact, sessionId: 'owner'),
        )), size: configuration.size, scale: configuration.scale);
        expect(tester.takeException(), isNull);
        if (configuration.scale == 2) {
          expect(tester.getSize(find.byTooltip('View source')).height, greaterThan(44));
        }
        for (final label in ['OFFLINE SANDBOX', 'View source', 'Expand preview', artifact.title]) {
          expect(
            tester.renderObject<RenderParagraph>(find.text(label)).didExceedMaxLines,
            isFalse,
            reason: '$label must remain fully readable',
          );
        }
        await tester.ensureVisible(find.byTooltip('View source'));
        expect(find.byTooltip('View source').hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip('View source'));
        await tester.pump();
        expect(find.byType(SelectableText), findsNWidgets(3));
        expect(find.textContaining('<p>Saved source marker</p>'), findsOneWidget);
        expect(find.text('p { color: red; }'), findsOneWidget);
        expect(find.text('console.log("saved script");'), findsOneWidget);
        await tester.tap(find.byTooltip('Show preview'));
        await tester.pump();
        expect(find.byType(SelectableText), findsNothing);
        await tester.ensureVisible(find.byTooltip('Expand preview'));
        expect(find.byTooltip('Expand preview').hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip('Expand preview'));
        await _routeFrames(tester);
        expect(find.byTooltip('Exit fullscreen'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byTooltip('View source'));
        await tester.tap(find.byTooltip('View source'));
        await tester.pump();
        expect(find.textContaining('console.log("saved script");'), findsOneWidget);
        await tester.ensureVisible(find.byTooltip('Exit fullscreen'));
        expect(find.byTooltip('Exit fullscreen').hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip('Exit fullscreen'));
        await _waitForFullscreenExit(tester);
        expect(find.byTooltip('Exit fullscreen'), findsNothing);
        await tester.ensureVisible(find.byTooltip('Collapse artifact'));
        await tester.tap(find.byTooltip('Collapse artifact'));
        await tester.pump();
        expect(find.byTooltip('View source'), findsNothing);
        await tester.tap(find.byTooltip('Open artifact'));
        await tester.pump();
        expect(find.byTooltip('View source'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
    }
  }

  testWidgets('small2x held popup remains readable and dismissible', (tester) async {
    final tab = BrowserTab(url: 'https://example.test/')
      ..popupRequests.add('https://a-long-popup-host.example.test/offer');
    AgentService.I.browserTabs.add(tab);
    await _pump(tester, const BrowserScreen(), size: const Size(360, 640), scale: 2);
    expect(tester.takeException(), isNull);
    final label = find.text('Popup held: a-long-popup-host.example.test');
    final paragraph = tester.renderObject<RenderParagraph>(label);
    expect(paragraph.didExceedMaxLines, isFalse);
    await tester.tap(find.byKey(const ValueKey('popup-dismiss')));
    await tester.pump();
    expect(tab.popupRequests, isEmpty);
    expect(find.byKey(const ValueKey('popup-notice')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('toolbar retains history guards, local reload and search navigation', (tester) async {
    final native = _NavigationController();
    final tab = BrowserTab(url: 'https://example.test/')
      ..controller = WebViewController.fromPlatform(native)
      ..profileBound = true;
    AgentService.I.browserTabs.add(tab);
    await _pump(tester, const BrowserScreen(), size: const Size(360, 640), scale: 2);
    for (final action in ['back', 'forward', 'reload']) {
      await tester.tap(find.byKey(ValueKey('browser-$action')));
      await tester.pump();
    }
    expect(native.events, ['back', 'forward', 'reload']);
    native.historyAvailable = false;
    await tester.tap(find.byKey(const ValueKey('browser-back')));
    await tester.tap(find.byKey(const ValueKey('browser-forward')));
    await tester.pump();
    expect(native.events, ['back', 'forward', 'reload']);
    tab.localPreviewPath = '/fixture/index.html';
    await tester.tap(find.byKey(const ValueKey('browser-reload')));
    await tester.pump();
    expect(native.events.last, 'file:/fixture/index.html');
    await tester.enterText(find.byType(TextField), 'flutter layout');
    await tester.tap(find.byTooltip('Go'));
    await tester.pump();
    expect(native.events.last, 'url:https://www.google.com/search?q=flutter%20layout');
    expect(tab.localPreviewPath, isNull);
    expect(tab.url, 'https://www.google.com/search?q=flutter%20layout');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Enter navigation unfocuses the URL field and restores controls', (tester) async {
    final native = _NavigationController();
    final tab = BrowserTab(url: 'https://example.test/')
      ..controller = WebViewController.fromPlatform(native)
      ..profileBound = true;
    AgentService.I.browserTabs.add(tab);
    await _pump(tester, const BrowserScreen(), size: const Size(360, 640), scale: 2);

    final field = find.byType(TextField);
    await tester.tap(field);
    await tester.enterText(field, 'flutter layout');
    tester.widget<TextField>(field).onSubmitted!.call('flutter layout');
    await tester.pump();

    expect(native.events.last, 'url:https://www.google.com/search?q=flutter%20layout');
    expect(tab.url, 'https://www.google.com/search?q=flutter%20layout');
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
    expect(find.byTooltip('Go'), findsNothing);
    expect(find.byKey(const ValueKey('browser-reload')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('desktop tab keeps native geometry and exposes horizontal pan', (tester) async {
    final tab = BrowserTab(url: 'https://example.test/', desktopMode: true);
    AgentService.I.browserTabs.add(tab);
    await _pump(tester, const BrowserScreen(), size: const Size(360, 640), scale: 2);
    expect(tester.getSize(find.byKey(ValueKey('stub-${tab.id}'))), const Size(1280, 800));
    final bar = tester.widget<Scrollbar>(find.byType(Scrollbar));
    expect(bar.interactive, isTrue);
    expect(bar.controller!.position.maxScrollExtent, greaterThan(0));
    final horizontal = find.byWidgetPredicate((widget) =>
        widget is SingleChildScrollView && widget.scrollDirection == Axis.horizontal);
    await tester.drag(horizontal, const Offset(-1200, 0));
    await _routeFrames(tester);
    expect(bar.controller!.offset, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('popup Open uses the service new-tab path', (tester) async {
    final tab = BrowserTab(url: 'https://example.test/')
      ..popupRequests.add('https://popup.example.test/');
    AgentService.I.browserTabs.add(tab);
    await _pump(tester, const BrowserScreen(), size: const Size(360, 640), scale: 2);
    await tester.tap(find.byKey(const ValueKey('popup-open')));
    await tester.pump();
    expect(tab.popupRequests, isEmpty);
    expect(AgentService.I.browserTabs, hasLength(2));
    expect(AgentService.I.activeTabIndex, 1);
    expect(AgentService.I.browserTabs.last.url, 'https://popup.example.test/');
    expect(find.byKey(const ValueKey('popup-notice')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('capture actual browser chrome with stub WebView', (tester) async {
    Aether.dark = true;
    AgentService.I.browserTabs.addAll([
      BrowserTab(url: 'https://example.test/research')..title = 'Research notes',
      BrowserTab(url: 'https://docs.example.test/')..title = 'Documentation',
    ]);
    await _pump(tester, const BrowserScreen(), size: const Size(360, 640), scale: 2);
    await _routeFrames(tester);
    expect(tester.takeException(), isNull);
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_boundaryKey));
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/opencode/ui-finish-12.png').writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
    await tester.pumpWidget(const SizedBox());
  }, skip: !_capture);
}
