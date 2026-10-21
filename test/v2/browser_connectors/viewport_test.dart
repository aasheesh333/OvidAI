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
  testWidgets('live view paints the injected frame and the 3–5 fps hint', (
    tester,
  ) async {
    final frame = MemoryImage(_frameBytes);
    await _pump(
      tester,
      BrowserViewport(
        frame: frame,
        cursor: const V2ViewportCursor(x: 0.4, y: 0.5),
        onTakeControl: () {},
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, same(frame));
    expect(image.fit, BoxFit.contain);
    expect(find.text('Live · 3–5 fps'), findsOneWidget);
    expect(find.byKey(BrowserViewport.cursorKey), findsOneWidget);
    expect(find.text('Ovid'), findsOneWidget);
    expect(find.byKey(BrowserViewport.takeControlKey), findsOneWidget);

    // It is a frame painter, not a hidden embedded browser.
    expect(find.byType(AndroidView), findsNothing);
    expect(find.byType(PlatformViewLink), findsNothing);
  });

  testWidgets('a missing frame shows the neutral placeholder, not a page', (
    tester,
  ) async {
    await _pump(tester, const BrowserViewport());

    expect(find.text('The live page shows here'), findsOneWidget);
    expect(
      find.text('Ovid draws the page it is reading in this space.'),
      findsOneWidget,
    );
    expect(find.byType(Image), findsNothing);
    expect(find.byKey(BrowserViewport.takeControlKey), findsNothing);

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

  testWidgets('loading waits for the first frame and cannot be controlled', (
    tester,
  ) async {
    await _pump(
      tester,
      BrowserViewport(
        frame: MemoryImage(_frameBytes),
        status: V2ViewportStatus.loading,
        onTakeControl: () {},
      ),
    );

    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.text('Waiting for the first frame…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byKey(BrowserViewport.takeControlKey), findsNothing);
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
        onTakeControl: () {},
      ),
    );

    expect(find.text('Stream lost'), findsNWidgets(2));
    expect(
      find.text(
        'Ovid keeps working. The picture returns on its own, '
        'or reconnect now.',
      ),
      findsOneWidget,
    );
    // The last frame stays behind the notice rather than going black.
    expect(find.byType(Image), findsOneWidget);
    expect(find.byKey(BrowserViewport.takeControlKey), findsNothing);

    await tester.tap(find.byKey(BrowserViewport.retryKey));
    await tester.pump(const Duration(milliseconds: 300));
    expect(retries, 1);
  });

  testWidgets('a retry with no callback is announced as disabled', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      const BrowserViewport(status: V2ViewportStatus.streamLost),
    );

    expect(
      tester.getSemantics(find.text('Reconnect')),
      isSemantics(isButton: true, isEnabled: false),
    );
    handle.dispose();
  });

  testWidgets('tap-to-control is a labelled 48 dp target and fires once', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var takes = 0;
    await _pump(
      tester,
      BrowserViewport(
        frame: MemoryImage(_frameBytes),
        onTakeControl: () => takes++,
      ),
    );

    final finder = find.byKey(BrowserViewport.takeControlKey);
    expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
    expect(
      tester.getSemantics(find.text('Take control')),
      isSemantics(
        label: 'Take control',
        isButton: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );

    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 300));
    expect(takes, 1);
    handle.dispose();
  });

  testWidgets('the controlling state replaces the takeover overlay', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      BrowserViewport(
        frame: MemoryImage(_frameBytes),
        controlling: true,
        onTakeControl: () {},
      ),
    );

    expect(find.byKey(BrowserViewport.takeControlKey), findsNothing);
    expect(find.text('You are controlling'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('You are controlling')),
      isSemantics(label: 'You are controlling'),
    );
    handle.dispose();
  });

  testWidgets('the agent cursor is announced and stays inside the frame', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      const BrowserViewport(
        cursor: V2ViewportCursor(x: 2, y: -1, label: 'Reading'),
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

  testWidgets('the fps hint can be omitted without dropping the live state', (
    tester,
  ) async {
    await _pump(tester, const BrowserViewport(showFpsHint: false));

    expect(find.text('Live'), findsOneWidget);
    expect(find.textContaining('3–5 fps'), findsNothing);
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
            onTakeControl: () {},
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

      await _pumpSmall(
        tester,
        BrowserViewport(
          frame: frame,
          cursor: const V2ViewportCursor(x: 0.2, y: 0.2),
          onTakeControl: () {},
        ),
        theme: theme,
      );
      expect(tester.takeException(), isNull);
      final hint = find.text('Live · 3–5 fps');
      expect(hint, findsOneWidget);
      // A 12 pt caption at 200 % needs ~33.6 dp of line box; less means the
      // hint was squeezed instead of scaled.
      expect(tester.getSize(hint).height, greaterThanOrEqualTo(32));
      expect(find.text('Take control'), findsOneWidget);
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
