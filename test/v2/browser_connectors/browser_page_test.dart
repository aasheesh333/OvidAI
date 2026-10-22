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

V2BrowserData _data({V2BrowserStatus status = V2BrowserStatus.content}) {
  return V2BrowserData(
    tabs: const [
      V2BrowserTab(id: 'docs', title: 'Docs', host: 'ovidsi.com'),
      V2BrowserTab(id: 'github', title: 'GitHub', host: 'github.com'),
    ],
    activeTabId: 'docs',
    address: 'ovidsi.com/docs/quickstart',
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

Future<void> _pumpSize(
  WidgetTester tester,
  Widget child,
  Size size, {
  ThemeData? theme,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await _pump(tester, child, theme: theme);
}

void main() {
  testWidgets('browser is one window: address, tabs, picture and one pill', (
    tester,
  ) async {
    await _pump(
      tester,
      BrowserPage(data: _data(), onTakeControl: () {}, onMenu: () {}),
    );

    // The header is the address, not a repeated screen title.
    expect(find.text('Browser'), findsNothing);
    expect(find.text('ovidsi.com/docs/quickstart'), findsOneWidget);
    expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);

    // The icon-only tab strip is present because there are two tabs.
    expect(find.byType(BrowserTabStrip), findsOneWidget);
    expect(find.byKey(const ValueKey('v2-browser-tab-docs')), findsOneWidget);
    expect(find.byKey(const ValueKey('v2-browser-tab-github')), findsOneWidget);
    expect(find.text('Docs'), findsNothing);

    // No status pill, no frame-rate explainer, no read-only badge: the
    // waiting surface is one centred line.
    expect(find.text('Waiting for the page…'), findsOneWidget);
    expect(find.text('Waiting'), findsNothing);
    expect(find.textContaining('fps'), findsNothing);
    expect(find.text('Read-only'), findsNothing);
    expect(find.text('Ovid is driving'), findsNothing);

    // One pill over the picture is the way in.
    expect(find.byKey(BrowserControlBar.takeControlKey), findsOneWidget);
    expect(find.text('Take control'), findsOneWidget);
  });

  testWidgets('browser renders in dark theme', (tester) async {
    await _pump(tester, BrowserPage(data: _data()), theme: OTheme.dark());

    expect(find.text('ovidsi.com/docs/quickstart'), findsOneWidget);
    expect(find.text('Waiting for the page…'), findsOneWidget);
  });

  testWidgets('the copy-address button is not in the header', (tester) async {
    await _pump(tester, BrowserPage(data: _data(), onMenu: () {}));

    expect(find.byIcon(Icons.content_copy_rounded), findsNothing);
    expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);
  });

  testWidgets('the header has a back arrow only when it can pop', (
    tester,
  ) async {
    await _pump(tester, BrowserPage(data: _data()));
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => BrowserPage(data: _data()),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('a single tab is the page: no tab strip', (tester) async {
    await _pump(
      tester,
      const BrowserPage(
        data: V2BrowserData(
          tabs: [V2BrowserTab(id: 'docs', title: 'Docs', host: 'ovidsi.com')],
          activeTabId: 'docs',
          address: 'ovidsi.com/docs/quickstart',
        ),
      ),
    );

    expect(find.byType(BrowserTabStrip), findsNothing);
    expect(find.byKey(const ValueKey('v2-browser-tab-docs')), findsNothing);
  });

  testWidgets('the tab strip appears with more than one tab', (tester) async {
    await _pump(tester, BrowserPage(data: _data()));
    expect(find.byType(BrowserTabStrip), findsOneWidget);
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
    expect(find.text('Open a page'), findsOneWidget);

    await tester.tap(find.text('Open a page'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(opened, 1);
  });

  testWidgets('an empty screen with only a retry shows one action', (
    tester,
  ) async {
    var retries = 0;
    await _pump(
      tester,
      BrowserPage(
        data: _data(status: V2BrowserStatus.empty),
        onRetry: () => retries++,
      ),
    );

    expect(find.text('Open a page'), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(retries, 1);
  });

  testWidgets('the pill over the picture takes control', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      BrowserPage(data: _data(), onTakeControl: () => taps++),
    );

    await tester.tap(find.byKey(BrowserControlBar.takeControlKey));
    await tester.pump(const Duration(milliseconds: 300));
    expect(taps, 1);
  });

  testWidgets('tapping a tab switches the active tab', (tester) async {
    String? selected;
    await _pump(
      tester,
      BrowserPage(data: _data(), onSelectTab: (id) => selected = id),
    );

    await tester.tap(find.byKey(const ValueKey('v2-browser-tab-github')));
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

  testWidgets('the removed log and transfer tools stay gone', (tester) async {
    await _pump(tester, BrowserPage(data: _data()));

    expect(find.text('Action log'), findsNothing);
    expect(find.text('Stop'), findsNothing);
    expect(find.byTooltip('Download file'), findsNothing);
    expect(find.byTooltip('Upload file'), findsNothing);
    expect(find.byIcon(Icons.download_rounded), findsNothing);
    expect(find.byIcon(Icons.upload_rounded), findsNothing);
  });

  testWidgets('a lost picture is one line with a retry', (tester) async {
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

    expect(find.text('Stream lost'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.text('Lost'), findsNothing);

    await tester.tap(find.text('Reconnect'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(retries, 1);
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

    expect(find.byKey(const ValueKey('v2-browser-tab-docs')), findsOneWidget);
    expect(find.byType(ListView), findsWidgets);
    expect(find.byKey(BrowserControlBar.takeControlKey), findsNothing);
  });

  testWidgets('no sample content ships in the default data', (tester) async {
    const data = V2BrowserData();
    expect(data.address, isEmpty);
    expect(data.tabs, isEmpty);
    expect(data.emptyTitle, 'No page open');
    expect(data.controlling, isFalse);

    await _pump(tester, const BrowserPage(data: data));

    // No picture means an honest waiting state, not a blank surface that
    // looks loaded.
    expect(find.text('Waiting for the page…'), findsOneWidget);
    expect(find.text('The live page shows here'), findsNothing);
    expect(find.textContaining('sk_live'), findsNothing);
  });

  testWidgets('320 dp at 200 % text lays out without overflow (light)', (
    tester,
  ) async {
    await _pumpSmall(tester, BrowserPage(data: _data(), onTakeControl: () {}));

    expect(tester.takeException(), isNull);
    expect(find.text('ovidsi.com/docs/quickstart'), findsOneWidget);
    expect(find.byKey(BrowserControlBar.takeControlKey), findsOneWidget);
    expect(find.text('Waiting for the page…'), findsOneWidget);
    expect(find.byKey(const ValueKey('v2-browser-tab-docs')), findsOneWidget);
  });

  testWidgets('320 dp at 200 % text lays out without overflow (dark)', (
    tester,
  ) async {
    await _pumpSmall(
      tester,
      BrowserPage(data: _data(), onTakeControl: () {}),
      theme: OTheme.dark(),
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(BrowserControlBar.takeControlKey), findsOneWidget);
  });

  testWidgets('320 dp at 200 % text, lost, still lays out', (tester) async {
    await _pumpSmall(
      tester,
      BrowserPage(
        data: const V2BrowserData(
          tabs: [V2BrowserTab(id: 'docs', title: 'Docs', host: 'ovidsi.com')],
          activeTabId: 'docs',
          address: 'ovidsi.com/docs/quickstart',
          viewportStatus: V2ViewportStatus.streamLost,
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Stream lost'), findsOneWidget);
  });

  testWidgets('a short landscape window scrolls nothing over', (tester) async {
    await _pumpSize(
      tester,
      BrowserPage(data: _data(), onTakeControl: () {}),
      const Size(640, 360),
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('v2-browser-tab-docs')), findsOneWidget);
    expect(find.byKey(BrowserControlBar.takeControlKey), findsOneWidget);
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
    // The picture is the status: no Live pill over it.
    expect(find.text('Live'), findsNothing);
  });

  testWidgets('viewport status and retry flow through the page', (
    tester,
  ) async {
    await _pumpSize(
      tester,
      BrowserPage(
        data: const V2BrowserData(
          tabs: [V2BrowserTab(id: 'docs', title: 'Docs', host: 'ovidsi.com')],
          activeTabId: 'docs',
          address: 'ovidsi.com/docs/quickstart',
          viewportStatus: V2ViewportStatus.streamLost,
        ),
        onRetry: () {},
      ),
      const Size(800, 900),
    );

    expect(find.text('Stream lost'), findsOneWidget);
    expect(find.byKey(BrowserViewport.retryKey), findsOneWidget);
  });

  testWidgets('the dock carries only the wired controls', (tester) async {
    var back = 0;
    var keyboard = 0;
    var released = 0;
    await _pump(
      tester,
      BrowserPage(
        data: const V2BrowserData(
          tabs: [V2BrowserTab(id: 'docs', title: 'Docs', host: 'ovidsi.com')],
          activeTabId: 'docs',
          address: 'ovidsi.com/docs/quickstart',
          controlling: true,
          canGoBack: true,
        ),
        onBack: () => back++,
        onToggleKeyboard: () => keyboard++,
        onReleaseControl: () => released++,
      ),
    );

    expect(find.byType(BrowserControlBar), findsOneWidget);
    expect(find.byKey(BrowserControlBar.backKey), findsOneWidget);
    expect(find.byKey(BrowserControlBar.forwardKey), findsNothing);
    expect(find.byKey(BrowserControlBar.keyboardKey), findsOneWidget);
    expect(find.byKey(BrowserControlBar.takeControlKey), findsOneWidget);

    await tester.tap(find.byKey(BrowserControlBar.backKey));
    await tester.tap(find.byKey(BrowserControlBar.keyboardKey));
    await tester.tap(find.byKey(BrowserControlBar.takeControlKey));
    await tester.pump(const Duration(milliseconds: 300));

    expect(back, 1);
    expect(keyboard, 1);
    expect(released, 1);
  });

  testWidgets('watching shows one pill and no dock', (tester) async {
    await _pump(
      tester,
      BrowserPage(data: _data(), onTakeControl: () {}),
    );

    expect(find.byKey(BrowserControlBar.takeControlKey), findsOneWidget);
    expect(find.byType(BrowserControlBar), findsNothing);
    expect(find.byKey(BrowserControlBar.keyboardKey), findsNothing);
  });

  testWidgets('no handler means no pill and no dock at all', (tester) async {
    await _pump(
      tester,
      BrowserPage(
        data: const V2BrowserData(
          tabs: [V2BrowserTab(id: 'docs', title: 'Docs', host: 'ovidsi.com')],
          activeTabId: 'docs',
          address: 'ovidsi.com/docs/quickstart',
        ),
      ),
    );

    expect(find.byKey(BrowserControlBar.takeControlKey), findsNothing);
    expect(find.byKey(BrowserControlBar.backKey), findsNothing);
    expect(find.byKey(BrowserControlBar.forwardKey), findsNothing);
    expect(find.byKey(BrowserControlBar.keyboardKey), findsNothing);
    expect(find.byType(BrowserControlBar), findsNothing);
  });

  testWidgets('the dock floats over the bottom of the frame', (tester) async {
    await _pump(
      tester,
      BrowserPage(
        data: const V2BrowserData(
          tabs: [V2BrowserTab(id: 'docs', title: 'Docs', host: 'ovidsi.com')],
          activeTabId: 'docs',
          address: 'ovidsi.com/docs/quickstart',
          controlling: true,
        ),
        onReleaseControl: () {},
      ),
    );

    final viewport = tester.getRect(find.byType(BrowserViewport));
    final bar = tester.getRect(find.byType(BrowserControlBar));
    // Over the picture, near its bottom edge, horizontally centred.
    expect(bar.bottom, lessThanOrEqualTo(viewport.bottom));
    expect(bar.bottom, greaterThan(viewport.bottom - 80));
    expect(bar.center.dx, closeTo(viewport.center.dx, 1));
  });

  testWidgets('the dock can hand the page back', (tester) async {
    var released = 0;
    await _pump(
      tester,
      BrowserPage(
        data: const V2BrowserData(
          tabs: [V2BrowserTab(id: 'docs', title: 'Docs', host: 'ovidsi.com')],
          activeTabId: 'docs',
          address: 'ovidsi.com/docs/quickstart',
          controlling: true,
        ),
        onReleaseControl: () => released++,
      ),
    );

    await tester.tap(find.byKey(BrowserControlBar.takeControlKey));
    await tester.pump(const Duration(milliseconds: 300));
    expect(released, 1);
  });

  testWidgets('controlling layout fits 320 dp at 200 % text', (tester) async {
    await _pumpSmall(
      tester,
      BrowserPage(
        data: const V2BrowserData(
          tabs: [V2BrowserTab(id: 'docs', title: 'Docs', host: 'ovidsi.com')],
          activeTabId: 'docs',
          address: 'ovidsi.com/docs/quickstart',
          controlling: true,
          keyboard: true,
          canGoBack: true,
          canGoForward: true,
        ),
        onBack: () {},
        onForward: () {},
        onToggleKeyboard: () {},
        onReleaseControl: () {},
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(BrowserControlBar), findsOneWidget);
    expect(find.byKey(BrowserControlBar.forwardKey), findsOneWidget);
  });

  testWidgets('600 dp fills the picture area without stretching it', (
    tester,
  ) async {
    await _pumpSize(
      tester,
      BrowserPage(data: _data(), onTakeControl: () {}),
      const Size(600, 900),
    );

    expect(tester.takeException(), isNull);
    // The tab strip uses the whole width; the picture fills it side to side.
    expect(tester.getSize(find.byType(BrowserTabStrip)).width, 600);
    final viewport = find.byType(BrowserViewport);
    final size = tester.getSize(viewport);
    expect(size.width, 600 - 2 * 24);
    expect(size.height, greaterThan(size.width / (16 / 10)));
    expect(tester.getCenter(viewport).dx, closeTo(300, 0.5));
  });

  testWidgets('900 dp caps the page at 1100 and fills the rest', (
    tester,
  ) async {
    await _pumpSize(
      tester,
      BrowserPage(data: _data(), onTakeControl: () {}),
      const Size(1400, 900),
    );

    expect(tester.takeException(), isNull);
    // One centred surface: the tab strip spans the 1100 dp container.
    expect(tester.getSize(find.byType(BrowserTabStrip)).width, 1100);
    expect(
      tester.getCenter(find.byType(BrowserTabStrip)).dx,
      closeTo(700, 0.5),
    );

    // The frame fills the capped page edge to edge; the picture letterboxes
    // inside it instead of the window letterboxing the frame.
    final viewport = find.byType(BrowserViewport);
    expect(tester.getCenter(viewport).dx, closeTo(700, 0.5));
    expect(tester.getSize(viewport).width, 1100 - 2 * 24);
  });

  testWidgets('a wide, short window still fills the picture area', (
    tester,
  ) async {
    await _pumpSize(
      tester,
      BrowserPage(data: _data(), onTakeControl: () {}),
      const Size(1200, 600),
    );

    expect(tester.takeException(), isNull);
    final viewport = find.byType(BrowserViewport);
    final size = tester.getSize(viewport);
    // No 16:10 cap on the frame itself: it takes the whole remaining area.
    expect(size.width, 1100 - 2 * 24);
    expect(
      tester.getCenter(viewport).dx,
      closeTo(600, 0.5),
    );
  });
}
