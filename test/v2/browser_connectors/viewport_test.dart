import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/browser/viewport.dart';

/// A valid 2 × 2 opaque PNG. The tests only need a provider that paints; the
/// bytes are not a screenshot of any real page.
final Uint8List _frameBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGOoifn/'
  'H4QZYAwAYdILWapN/cEAAAAASUVORK5CYII=',
);

Widget _app(
  Widget child, {
  ThemeData? theme,
  double textScale = 1,
  Size size = const Size(360, 240),
}) {
  return MaterialApp(
    theme: theme ?? OTheme.light(),
    builder: (context, content) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: content!,
    ),
    home: Scaffold(
      body: Center(
        child: SizedBox.fromSize(size: size, child: child),
      ),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
  double textScale = 1,
  Size size = const Size(360, 240),
}) async {
  await tester.pumpWidget(
    _app(child, theme: theme, textScale: textScale, size: size),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Pumps the viewport on the smallest phone we support at 200 % text.
Future<void> _pumpSmall(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
}) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await _pump(
    tester,
    child,
    theme: theme,
    textScale: 2,
    size: const Size(320, 220),
  );
}

void main() {
  testWidgets('live view paints the frame and the agent cursor', (
    tester,
  ) async {
    final frame = MemoryImage(_frameBytes);
    await _pump(
      tester,
      BrowserViewport(
        frame: frame,
        cursor: const V2ViewportCursor(x: 0.4, y: 0.5),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, same(frame));
    expect(image.fit, BoxFit.contain);
    expect(find.byKey(BrowserViewport.cursorKey), findsOneWidget);

    // The picture is the status: no Live pill, no corner chrome at all.
    expect(find.text('Live'), findsNothing);

    // It is a frame painter, not a hidden embedded browser.
    expect(find.byType(AndroidView), findsNothing);
    expect(find.byType(PlatformViewLink), findsNothing);
  });

  testWidgets('the slow frame rate is not explained in words', (tester) async {
    await _pump(tester, BrowserViewport(frame: MemoryImage(_frameBytes)));

    expect(find.textContaining('fps'), findsNothing);
    expect(find.textContaining('times a second'), findsNothing);
  });

  testWidgets('live without a frame is an honest waiting state, not a page', (
    tester,
  ) async {
    await _pump(tester, const BrowserViewport());

    // It must not claim to be live while it has no picture: one centred line.
    expect(find.text('Live'), findsNothing);
    expect(find.text('Waiting for the page…'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    // Nothing is invented as a page either.
    expect(find.text('The live page shows here'), findsNothing);

    // Nothing that looks like a credential may ship in the empty state.
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '');
    expect(
      texts.where((text) => RegExp(r'sk_(live|test)_').hasMatch(text)),
      isEmpty,
    );
    expect(find.textContaining('Bearer'), findsNothing);
  });

  testWidgets('loading waits for the first frame', (tester) async {
    await _pump(
      tester,
      BrowserViewport(
        frame: MemoryImage(_frameBytes),
        status: V2ViewportStatus.loading,
      ),
    );

    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('stream lost keeps the last frame and offers a reconnect', (
    tester,
  ) async {
    var retries = 0;
    await _pump(
      tester,
      BrowserViewport(
        frame: MemoryImage(_frameBytes),
        status: V2ViewportStatus.streamLost,
        onRetry: () => retries++,
      ),
    );

    expect(find.text('Stream lost'), findsOneWidget);
    // No corner pill: the centred line is the whole notice.
    expect(find.text('Lost'), findsNothing);
    // The last frame stays behind the notice rather than going black.
    expect(find.byType(Image), findsOneWidget);

    await tester.tap(find.byKey(BrowserViewport.retryKey));
    await tester.pump(const Duration(milliseconds: 300));
    expect(retries, 1);
  });

  testWidgets('a retry with no callback is not rendered', (tester) async {
    await _pump(
      tester,
      const BrowserViewport(status: V2ViewportStatus.streamLost),
    );

    // No handler means no Reconnect button at all.
    expect(find.text('Reconnect'), findsNothing);
    expect(find.byKey(BrowserViewport.retryKey), findsNothing);
    expect(find.text('Stream lost'), findsOneWidget);
  });

  testWidgets('the waiting state offers a real retry and stops spinning', (
    tester,
  ) async {
    var retries = 0;
    await _pump(
      tester,
      BrowserViewport(
        status: V2ViewportStatus.waiting,
        onRetry: () => retries++,
      ),
    );

    expect(find.text('Waiting for the page…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    final retry = find.byKey(BrowserViewport.waitingRetryKey);
    await tester.ensureVisible(retry);
    await tester.pump();
    await tester.tap(retry);
    await tester.pump(const Duration(milliseconds: 300));
    expect(retries, 1);
  });

  testWidgets('a tap while controlling becomes a normalized page tap', (
    tester,
  ) async {
    final taps = <Offset>[];
    await _pump(
      tester,
      BrowserViewport(
        frame: MemoryImage(_frameBytes),
        controlling: true,
        frameAspectRatio: 2,
        onPageTap: (x, y) => taps.add(Offset(x, y)),
      ),
      size: const Size(400, 200),
    );

    final surface = find.byKey(BrowserViewport.pageTapKey);
    expect(surface, findsOneWidget);
    // The 2:1 frame fills a 400 × 200 box exactly; the centre is page centre.
    await tester.tapAt(tester.getCenter(surface));
    await tester.pump();
    expect(taps, hasLength(1));
    expect(taps.single.dx, closeTo(0.5, 0.01));
    expect(taps.single.dy, closeTo(0.5, 0.01));
  });

  testWidgets('a tap in the letterbox is ignored, not sent to the page', (
    tester,
  ) async {
    final taps = <Offset>[];
    await _pump(
      tester,
      BrowserViewport(
        frame: MemoryImage(_frameBytes),
        controlling: true,
        frameAspectRatio: 1,
        onPageTap: (x, y) => taps.add(Offset(x, y)),
      ),
      size: const Size(400, 200),
    );

    final surface = find.byKey(BrowserViewport.pageTapKey);
    // A 1:1 frame inside 400 × 200 is 200 wide and centred: x = 10 is bars.
    await tester.tapAt(tester.getTopLeft(surface) + const Offset(10, 100));
    await tester.pump();
    expect(taps, isEmpty);
  });

  testWidgets('taps do nothing while Ovid is driving', (tester) async {
    final taps = <Offset>[];
    await _pump(
      tester,
      BrowserViewport(
        frame: MemoryImage(_frameBytes),
        onPageTap: (x, y) => taps.add(Offset(x, y)),
      ),
    );

    expect(find.byKey(BrowserViewport.pageTapKey), findsNothing);
    await tester.tap(find.byType(BrowserViewport));
    await tester.pump();
    expect(taps, isEmpty);
  });

  testWidgets('controlling keeps the picture tappable without a second badge', (
    tester,
  ) async {
    await _pump(
      tester,
      BrowserViewport(
        frame: MemoryImage(_frameBytes),
        controlling: true,
        onPageTap: (_, _) {},
      ),
    );

    expect(find.byKey(BrowserViewport.pageTapKey), findsOneWidget);
    // The control dock already says who is in control; the picture stays
    // clean: no badge, no status pill.
    expect(find.text('You are controlling'), findsNothing);
    expect(find.text('Live'), findsNothing);
  });

  testWidgets('the agent cursor is announced and stays inside the frame', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      BrowserViewport(
        frame: MemoryImage(_frameBytes),
        cursor: const V2ViewportCursor(x: 2, y: -1, label: 'Reading'),
      ),
    );

    expect(find.bySemanticsLabel('Reading cursor'), findsOneWidget);
    final rect = tester.getRect(find.byKey(BrowserViewport.cursorKey));
    final viewport = tester.getRect(find.byType(BrowserViewport));
    // The marker is clamped, not painted off-screen when the server sends an
    // out-of-range coordinate.
    expect(rect.left, greaterThanOrEqualTo(viewport.left));
    expect(rect.top, greaterThanOrEqualTo(viewport.top));
    expect(rect.right, lessThanOrEqualTo(viewport.right));
    expect(rect.bottom, lessThanOrEqualTo(viewport.bottom));
    handle.dispose();
  });

  for (final dark in [false, true]) {
    final name = dark ? 'dark' : 'light';

    testWidgets('320 dp at 200 % text lays out every state ($name)', (
      tester,
    ) async {
      final theme = dark ? OTheme.dark() : OTheme.light();
      final frame = MemoryImage(_frameBytes);

      for (final status in V2ViewportStatus.values) {
        await _pumpSmall(
          tester,
          BrowserViewport(
            frame: frame,
            status: status,
            cursor: const V2ViewportCursor(x: 0.9, y: 0.8),
            onRetry: () {},
          ),
          theme: theme,
        );

        expect(
          tester.takeException(),
          isNull,
          reason: 'viewport overflowed in the $status state ($name)',
        );
      }
    });
  }

  testWidgets('an unbounded height falls back to a readable box', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const SingleChildScrollView(child: BrowserViewport())),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(BrowserViewport)).height,
      greaterThanOrEqualTo(200),
    );
  });
}
