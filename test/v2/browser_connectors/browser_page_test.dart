import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/browser/browser_page.dart';
import 'package:ovid_ai/ui/v2/browser/control_bar.dart';
import 'package:ovid_ai/ui/v2/browser/tab_strip.dart';
import 'package:ovid_ai/ui/v2/browser/viewport.dart';

Widget _app(Widget child, {ThemeData? theme, double textScale = 1}) {
  return MaterialApp(
    theme: theme ?? OTheme.light(),
    builder: textScale == 1
        ? null
        : (context, content) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: content!,
          ),
    home: child,
  );
}

/// Sample session for the tests only. The screen itself ships empty defaults.
const _actions = <V2BrowserAction>[
  V2BrowserAction(
    id: 'open',
    label: 'Opened the page',
    detail: 'Docs home',
    timeLabel: '2m',
  ),
  V2BrowserAction(
    id: 'scroll',
    label: 'Scrolled to Service keys',
    detail: 'Found the section Ovid needed',
    timeLabel: '1m',
  ),
  V2BrowserAction(
    id: 'read',
    label: 'Reading the steps',
    detail: 'Ovid is taking notes for you',
    timeLabel: 'now',
    state: V2BrowserActionState.active,
  ),
];

V2BrowserData _data({
  V2BrowserStatus status = V2BrowserStatus.content,
  List<V2BrowserAction> actions = _actions,
}) {
  return V2BrowserData(
    tabs: const [
      V2BrowserTab(id: 'docs', title: 'Docs', host: 'ovidsi.com'),
      V2BrowserTab(id: 'github', title: 'GitHub', host: 'github.com'),
    ],
    activeTabId: 'docs',
    address: 'ovidsi.com/docs/quickstart',
    drivingDetail: 'Auto-reading docs',
    liveLabel: 'watching live · 4 fps',
    streamLabel: '720p stream',
    headlessLabel: 'Headless in 45 s',
    actions: actions,
    status: status,
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
  double textScale = 1,
}) async {
  await tester.pumpWidget(_app(child, theme: theme, textScale: textScale));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// Pumps the screen on a 320 × 640 phone at 200 % text.
Future<void> _pumpSmall(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
}) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await _pump(tester, child, theme: theme, textScale: 2);
}

void main() {
  testWidgets('browser renders tabs, address, live view and driving bar', (
    tester,
  ) async {
    await _pump(
      tester,
      BrowserPage(
        data: _data(),
        viewportChild: const Center(child: Text('Injected live page')),
      ),
    );

    expect(find.text('Browser'), findsOneWidget);
    expect(find.text('Docs'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('ovidsi.com/docs/quickstart'), findsOneWidget);
    expect(find.text('Read-only'), findsOneWidget);
    expect(find.text('watching live · 4 fps'), findsOneWidget);
    expect(find.text('Ovid is driving'), findsOneWidget);
    expect(find.text('Take control'), findsOneWidget);
    expect(find.text('Injected live page'), findsOneWidget);
  });

  testWidgets('browser renders in dark theme', (tester) async {
    await _pump(tester, BrowserPage(data: _data()), theme: OTheme.dark());

    expect(find.text('Browser'), findsOneWidget);
    expect(find.text('Ovid is driving'), findsOneWidget);
    expect(find.text('watching live · 4 fps'), findsOneWidget);
  });

  testWidgets('plus is disabled and explains that Ovid opens tabs', (
    tester,
  ) async {
    await _pump(tester, BrowserPage(data: _data()));

    expect(find.byTooltip('Ovid opens tabs'), findsOneWidget);
    final iconButton = tester.widget<IconButton>(
      find.descendant(
        of: find.byTooltip('Ovid opens tabs'),
        matching: find.byType(IconButton),
      ),
    );
    expect(iconButton.onPressed, isNull);
  });

  testWidgets('empty state explains the next step and fires its action', (
    tester,
  ) async {
    var opened = 0;
    await _pump(
      tester,
      BrowserPage(
        data: _data(status: V2BrowserStatus.empty),
        onOpenRequested: () => opened++,
      ),
    );

    expect(find.text('No page open'), findsOneWidget);
    expect(find.text('Ask Ovid to open a page'), findsOneWidget);

    await tester.tap(find.text('Ask Ovid to open a page'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(opened, 1);
  });

  testWidgets('take control is the primary callback', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      BrowserPage(data: _data(), onTakeControl: () => taps++),
    );

    await tester.tap(find.text('Take control'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(taps, 1);
  });

  testWidgets('tapping a tab switches the active tab', (tester) async {
    String? selected;
    await _pump(
      tester,
      BrowserPage(data: _data(), onSelectTab: (id) => selected = id),
    );

    await tester.tap(find.text('GitHub'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(selected, 'github');
  });

  testWidgets('closing a tab does not also select it', (tester) async {
    String? closed;
    String? selected;
    await _pump(
      tester,
      BrowserPage(
        data: _data(),
        onCloseTab: (id) => closed = id,
        onSelectTab: (id) => selected = id,
      ),
    );

    await tester.tap(find.byIcon(Icons.close_rounded).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(closed, 'docs');
    expect(selected, isNull);
  });

  testWidgets('action log lists steps and the headless timer', (tester) async {
    var opened = 0;
    await _pump(
      tester,
      BrowserPage(data: _data(), onShowActionLog: () => opened++),
    );

    expect(find.text('Action log'), findsOneWidget);
    expect(find.text('Opened the page'), findsOneWidget);
    expect(find.text('Headless in 45 s'), findsOneWidget);

    await tester.tap(find.text('Action log'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(opened, 1);
  });

  testWidgets('stop, download and upload callbacks are wired', (tester) async {
    var stops = 0;
    var downloads = 0;
    var uploads = 0;
    await _pump(
      tester,
      BrowserPage(
        data: _data(),
        onStop: () => stops++,
        onDownload: () => downloads++,
        onUpload: () => uploads++,
      ),
    );

    await tester.tap(find.text('Stop'));
    await tester.tap(find.byTooltip('Download file'));
    await tester.tap(find.byTooltip('Upload file'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(stops, 1);
    expect(downloads, 1);
    expect(uploads, 1);
  });

  testWidgets('an offline connection shows a reconnect path', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      BrowserPage(
        data: const V2BrowserData(
          tabs: [V2BrowserTab(id: 'docs', title: 'Docs', host: 'ovidsi.com')],
          activeTabId: 'docs',
          connection: V2BrowserConnection.offline,
        ),
        onRetry: () => retries++,
      ),
    );

    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);

    await tester.tap(find.text('Reconnect'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(retries, 1);
  });

  testWidgets('an empty action log still explains what happens next', (
    tester,
  ) async {
    await _pump(
      tester,
      BrowserPage(data: _data(actions: const <V2BrowserAction>[])),
    );

    expect(
      find.text('No steps yet. Ovid will list what it does here.'),
      findsOneWidget,
    );
  });

  testWidgets('error state offers a retry', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      BrowserPage(
        data: _data(status: V2BrowserStatus.error),
        onRetry: () => retries++,
      ),
    );

    expect(find.text('Live view paused'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(retries, 1);
  });

  testWidgets('loading state shows skeletons and keeps the tab strip', (
    tester,
  ) async {
    await _pump(
      tester,
      BrowserPage(data: _data(status: V2BrowserStatus.loading)),
    );

    expect(find.text('Docs'), findsOneWidget);
    expect(find.byType(ListView), findsWidgets);
    expect(find.text('Take control'), findsNothing);
  });

  testWidgets('no sample content ships in the default data', (tester) async {
    const data = V2BrowserData();
    expect(data.actions, isEmpty);
    expect(data.address, isEmpty);
    expect(data.headlessLabel, isEmpty);
    expect(data.streamLabel, isEmpty);
    expect(data.liveLabel, isEmpty);
    expect(data.drivingDetail, isEmpty);
    expect(data.tabs, isEmpty);
    expect(data.connectionLabel, 'Live');

    await _pump(tester, const BrowserPage(data: data));

    expect(
      find.text('No steps yet. Ovid will list what it does here.'),
      findsOneWidget,
    );
    expect(find.text('The live page shows here'), findsOneWidget);
    expect(find.textContaining('sk_live'), findsNothing);
  });

  testWidgets('320 dp at 200 % text lays out without overflow (light)', (
    tester,
  ) async {
    await _pumpSmall(tester, BrowserPage(data: _data()));

    expect(tester.takeException(), isNull);
    expect(find.text('Browser'), findsOneWidget);
    expect(find.text('Take control'), findsOneWidget);
    expect(find.text('Ovid is driving'), findsOneWidget);
    expect(find.text('Action log'), findsOneWidget);
    expect(find.text('Read-only'), findsOneWidget);
  });

  testWidgets('320 dp at 200 % text lays out without overflow (dark)', (
    tester,
  ) async {
    await _pumpSmall(tester, BrowserPage(data: _data()), theme: OTheme.dark());

    expect(tester.takeException(), isNull);
    expect(find.text('Ovid is driving'), findsOneWidget);
    expect(find.text('Take control'), findsOneWidget);
  });

  testWidgets('320 dp at 200 % text, offline, still lays out', (tester) async {
    await _pumpSmall(
      tester,
      BrowserPage(
        data: const V2BrowserData(
          tabs: [V2BrowserTab(id: 'docs', title: 'Docs', host: 'ovidsi.com')],
          activeTabId: 'docs',
          address: 'ovidsi.com/docs/quickstart',
          connection: V2BrowserConnection.offline,
          actions: _actions,
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Reconnect'), findsOneWidget);
  });

  testWidgets('a short landscape window scrolls instead of overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(tester, BrowserPage(data: _data()));

    expect(tester.takeException(), isNull);
    expect(find.text('Action log'), findsOneWidget);
  });

  testWidgets('mounts the shared tab strip and maps headless tabs', (
    tester,
  ) async {
    await _pump(
      tester,
      BrowserPage(
        data: const V2BrowserData(
          tabs: [
            V2BrowserTab(id: 'docs', title: 'Docs', host: 'ovidsi.com'),
            V2BrowserTab(
              id: 'github',
              title: 'GitHub',
              host: 'github.com',
              headless: true,
            ),
          ],
          activeTabId: 'docs',
          address: 'ovidsi.com/docs/quickstart',
        ),
      ),
    );

    expect(find.byType(BrowserTabStrip), findsOneWidget);
    expect(find.byKey(const ValueKey('v2-browser-tab-docs')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('v2-browser-tab-headless-github')),
      findsOneWidget,
    );
    expect(find.text('Headless'), findsOneWidget);
  });

  testWidgets('paints the injected frame in the shared viewport', (
    tester,
  ) async {
    final frame = MemoryImage(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0l'
        'EQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    await _pump(
      tester,
      BrowserPage(
        data: V2BrowserData(
          tabs: const [
            V2BrowserTab(id: 'docs', title: 'Docs', host: 'ovidsi.com'),
          ],
          activeTabId: 'docs',
          address: 'ovidsi.com/docs/quickstart',
          frame: frame,
          cursor: const V2ViewportCursor(x: 0.4, y: 0.6),
        ),
      ),
    );

    expect(find.byType(BrowserViewport), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image).first);
    expect(image.image, same(frame));
    expect(find.byKey(BrowserViewport.cursorKey), findsOneWidget);
    expect(find.text('Live · 3–5 fps'), findsOneWidget);
  });

  testWidgets('viewport status and retry flow through the page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var retries = 0;
    await _pump(
      tester,
      BrowserPage(
        data: const V2BrowserData(
          tabs: [V2BrowserTab(id: 'docs', title: 'Docs', host: 'ovidsi.com')],
          activeTabId: 'docs',
          address: 'ovidsi.com/docs/quickstart',
          viewportStatus: V2ViewportStatus.streamLost,
        ),
        onRetry: () => retries++,
      ),
    );

    expect(find.text('Stream lost'), findsWidgets);
    await tester.tap(find.byKey(BrowserViewport.retryKey));
    await tester.pump(const Duration(milliseconds: 300));
    expect(retries, 1);
  });

  testWidgets('control bar carries fps, countdown and input tools', (
    tester,
  ) async {
    var back = 0;
    var keyboard = 0;
    var trackpad = 0;
    var uploads = 0;
    var downloads = 0;
    var released = 0;
    await _pump(
      tester,
      BrowserPage(
        data: const V2BrowserData(
          tabs: [V2BrowserTab(id: 'docs', title: 'Docs', host: 'ovidsi.com')],
          activeTabId: 'docs',
          address: 'ovidsi.com/docs/quickstart',
          headlessLabel: 'Headless in 45 s',
          controlling: true,
          canGoBack: true,
        ),
        onBack: () => back++,
        onToggleKeyboard: () => keyboard++,
        onToggleTrackpad: () => trackpad++,
        onUpload: () => uploads++,
        onDownload: () => downloads++,
        onReleaseControl: () => released++,
      ),
    );

    expect(find.byType(BrowserControlBar), findsOneWidget);
    expect(find.text('3–5 fps'), findsOneWidget);
    expect(find.text('Headless in 45 s'), findsOneWidget);
    expect(find.byKey(BrowserControlBar.backKey), findsOneWidget);

    await tester.tap(find.byKey(BrowserControlBar.backKey));
    await tester.tap(find.byKey(BrowserControlBar.keyboardKey));
    await tester.tap(find.byKey(BrowserControlBar.trackpadKey));
    await tester.tap(find.byKey(BrowserControlBar.uploadKey));
    await tester.tap(find.byKey(BrowserControlBar.downloadKey));
    await tester.tap(find.byKey(BrowserControlBar.takeControlKey));
    await tester.pump(const Duration(milliseconds: 300));

    expect(back, 1);
    expect(keyboard, 1);
    expect(trackpad, 1);
    expect(uploads, 1);
    expect(downloads, 1);
    expect(released, 1);
  });

  testWidgets('control bar can hand the page over', (tester) async {
    var takes = 0;
    await _pump(
      tester,
      BrowserPage(data: _data(), onTakeControl: () => takes++),
    );

    await tester.tap(find.byKey(BrowserControlBar.takeControlKey));
    await tester.pump(const Duration(milliseconds: 300));
    expect(takes, 1);
  });

  testWidgets('controlling layout fits 320 dp at 200 % text', (tester) async {
    await _pumpSmall(
      tester,
      BrowserPage(
        data: const V2BrowserData(
          tabs: [V2BrowserTab(id: 'docs', title: 'Docs', host: 'ovidsi.com')],
          activeTabId: 'docs',
          address: 'ovidsi.com/docs/quickstart',
          headlessLabel: 'Headless in 45 s',
          controlling: true,
          keyboard: true,
          trackpad: true,
          canGoBack: true,
          canGoForward: true,
        ),
        onBack: () {},
        onForward: () {},
        onToggleKeyboard: () {},
        onToggleTrackpad: () {},
        onUpload: () {},
        onDownload: () {},
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(BrowserControlBar), findsOneWidget);
    expect(find.text('Headless in 45 s'), findsWidgets);
  });
}
