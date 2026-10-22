// Wiring tests for the v2 Browser screen.
//
// These run the real BrowserStreamClient over fake streams, so they prove the
// page is wired to the browser channel — not just that the widgets render.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/cloud/browser_stream.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/browser/browser_live_page.dart';
import 'package:ovid_ai/ui/v2/browser/control_bar.dart';
import 'package:ovid_ai/ui/v2/browser/viewport.dart';

/// A real 2 × 2 PNG. The frame path only needs a decodable provider.
final Uint8List _frameBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGOoifn/'
  'H4QZYAwAYdILWapN/cEAAAAASUVORK5CYII=',
);

WsMultiplexer _ws() => WsMultiplexer(mintTicket: () async => 'ticket');

/// A multiplexer whose link state a test can flip, so the page can be driven
/// through a dropped socket without opening one.
class _FakeLinkWs extends WsMultiplexer {
  _FakeLinkWs() : super(mintTicket: () async => 'ticket');

  WsLinkState _link = WsLinkState.disconnected;

  @override
  WsLinkState get linkState => _link;

  void setLink(WsLinkState value) {
    if (_link == value) return;
    _link = value;
    notifyListeners();
  }
}

Map<String, dynamic> _state({
  bool takeover = false,
  bool live = true,
  bool screencast = true,
  String url = 'https://example.test/page',
  String title = 'Example page',
}) {
  return <String, dynamic>{
    'sessionId': 's1',
    'live': live,
    'url': url,
    'title': title,
    'takeover': takeover,
    'screencast': screencast,
    'frameFormat': 'webp',
    'viewport': {'width': 1280, 'height': 800},
    'tabs': [
      {'index': 0, 'url': url, 'title': title, 'active': true},
      {
        'index': 1,
        'url': 'https://docs.test/start',
        'title': 'Docs',
        'active': false,
      },
    ],
    'activeTabIndex': 0,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<Map<String, dynamic>> raw;
  late StreamController<Uint8List> binary;
  late List<Map<String, Object?>> sent;
  late BrowserStreamClient client;

  setUp(() {
    raw = StreamController<Map<String, dynamic>>.broadcast();
    binary = StreamController<Uint8List>.broadcast();
    sent = <Map<String, Object?>>[];
  });

  tearDown(() async {
    client.dispose();
    await raw.close();
    await binary.close();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(420, 900),
    double textScale = 1,
    ThemeData? theme,
    WsMultiplexer? ws,
    bool failTakeover = false,
  }) async {
    // Built inside the test body on purpose: the client chains frame decodes
    // on a future created in its constructor zone, and a client built in
    // setUp would schedule them outside the widget tester's fake clock.
    client = BrowserStreamClient(
      ws: ws ?? _ws(),
      rawFramesOverride: raw.stream,
      binaryFramesOverride: binary.stream,
      sendOverride: (frame) async {
        sent.add(frame);
        if (failTakeover && frame['op'] == 'browser_takeover') {
          throw StateError('link is down');
        }
      },
      decodeFrame: (bytes) async =>
          BrowserFrame(webpBytes: bytes, width: 2, height: 2),
    );
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? OTheme.light(),
        builder: textScale == 1
            ? null
            : (context, content) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(textScale)),
                child: content!,
              ),
        home: BrowserLivePage(client: client, attachId: 's1'),
      ),
    );
    // Let attach() run before the test emits a state.
    await tester.pump();
    await tester.pump();
  }

  Future<void> emitState(
    WidgetTester tester, [
    Map<String, dynamic>? state,
  ]) async {
    raw.add(<String, dynamic>{
      'op': 'browser_state',
      'sessionId': 's1',
      'state': state ?? _state(),
    });
    await tester.pump();
    await tester.pump();
  }

  Future<void> emitFrame(WidgetTester tester) async {
    binary.add(_frameBytes);
    // Decode runs through the client's arrival-ordered chain, so it takes an
    // extra pump before the frame reaches the page.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  List<Map<String, Object?>> opsOf(String op) => sent
      .where((frame) => frame['op'] == op)
      .map((frame) => Map<String, Object?>.from(frame))
      .toList();

  testWidgets('renders the agent tabs, address and a real frame provider', (
    tester,
  ) async {
    await pumpPage(tester);
    await emitState(tester);
    await emitFrame(tester);

    // Tabs come from browser_state: two agent tabs, icon-only.
    expect(find.byKey(const ValueKey('v2-browser-tab-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('v2-browser-tab-1')), findsOneWidget);
    expect(find.text('https://example.test/page'), findsOneWidget);

    // The viewport paints the decoded frame through an ImageProvider.
    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images, isNotEmpty);
    expect(images.first.image, isA<MemoryImage>());
    // The picture is the status: no Live pill, no stream size, no fps note.
    expect(find.text('Live'), findsNothing);
    expect(find.text('1280×800'), findsNothing);
    expect(find.textContaining('fps'), findsNothing);
  });

  testWidgets('the agent owns tabs: there is no way to add one', (
    tester,
  ) async {
    await pumpPage(tester);
    await emitState(tester);
    await emitFrame(tester);

    expect(find.byKey(const ValueKey('v2-browser-tab-add')), findsNothing);
    expect(find.byIcon(Icons.add_rounded), findsNothing);
    expect(find.byKey(const ValueKey('v2-browser-tab-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('v2-browser-tab-1')), findsOneWidget);
    expect(find.text('New tab'), findsNothing);
    expect(opsOf('browser_switch_tab'), isEmpty);
    expect(opsOf('browser_new_tab'), isEmpty);
  });

  testWidgets('selecting an agent tab asks the server to switch', (
    tester,
  ) async {
    await pumpPage(tester);
    await emitState(tester);

    await tester.tap(find.byKey(const ValueKey('v2-browser-tab-1')));
    await tester.pump();

    final switches = opsOf('browser_switch_tab');
    expect(switches, hasLength(1));
    expect(switches.single['index'], 1);
  });

  testWidgets('take control is server-acknowledged and really controls', (
    tester,
  ) async {
    await pumpPage(tester);
    await emitState(tester);
    await emitFrame(tester);

    await tester.tap(find.byKey(BrowserControlBar.takeControlKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The sheet is the real hand-over: nothing has been sent yet.
    expect(find.text('Start controlling'), findsOneWidget);
    expect(opsOf('browser_takeover'), isEmpty);

    await tester.tap(find.text('Start controlling'));
    await tester.pump();

    final requests = opsOf('browser_takeover');
    expect(requests, hasLength(1));
    expect(requests.single['enabled'], isTrue);
    // No optimistic flip: the sheet waits for the server.
    expect(find.text('Pausing Ovid…'), findsOneWidget);

    await emitState(tester, _state(takeover: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Controlled state: the dock offers the way back over the picture.
    expect(find.byType(BrowserControlBar), findsOneWidget);
    expect(find.byTooltip('Return control'), findsOneWidget);

    // A tap on the picture reaches the page in CSS pixels.
    await tester.tapAt(
      tester.getCenter(find.byKey(BrowserViewport.pageTapKey)),
    );
    await tester.pump();
    final inputs = opsOf('browser_input');
    expect(inputs, hasLength(1));
    final input = Map<String, Object?>.from(inputs.single['input']! as Map);
    expect(input['type'], 'tap');
    expect(input['x'], closeTo(640, 1));
    expect(input['y'], closeTo(400, 1));

    // Handing back is a real request too.
    await tester.tap(find.byKey(BrowserControlBar.takeControlKey));
    await tester.pump();
    final releases = opsOf('browser_takeover').last;
    expect(releases['enabled'], isFalse);

    await emitState(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byTooltip('Take control'), findsOneWidget);
  });

  testWidgets('the keyboard tool sends real page input', (tester) async {
    await pumpPage(tester);
    await emitState(tester, _state(takeover: true));
    await emitFrame(tester);

    // Closed until the person asks for it.
    expect(
      find.byKey(const ValueKey('v2-browser-keyboard-bridge')),
      findsNothing,
    );

    await tester.tap(find.byKey(BrowserControlBar.keyboardKey));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('v2-browser-keyboard-bridge')),
      findsOneWidget,
    );

    Map<String, Object?> lastInput() =>
        Map<String, Object?>.from(opsOf('browser_input').last['input']! as Map);

    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    expect(lastInput(), <String, Object?>{
      'type': 'key',
      'key': 'Insert',
      'text': 'hi',
    });

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(lastInput(), <String, Object?>{'type': 'key', 'key': 'Enter'});

    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(lastInput(), <String, Object?>{'type': 'key', 'key': 'Backspace'});

    await tester.tap(find.byKey(BrowserControlBar.keyboardKey));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('v2-browser-keyboard-bridge')),
      findsNothing,
    );
  });

  testWidgets('upload and download are absent, not dead', (tester) async {
    await pumpPage(tester);
    await emitState(tester);
    await emitFrame(tester);

    expect(find.byTooltip('Upload file'), findsNothing);
    expect(find.byTooltip('Download file'), findsNothing);
    expect(find.byIcon(Icons.upload_rounded), findsNothing);
    expect(find.byIcon(Icons.download_rounded), findsNothing);
  });

  testWidgets('no state after the window is an honest empty screen', (
    tester,
  ) async {
    await pumpPage(tester);

    // Still connecting: a skeleton is allowed here, but not forever.
    expect(find.byType(OSkeletonList), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));

    expect(find.text('Browser not open'), findsOneWidget);
    expect(find.byType(OSkeletonList), findsNothing);

    final attachesBefore = opsOf('browser_attach').length;
    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump();
    expect(opsOf('browser_attach').length, greaterThan(attachesBefore));
  });

  testWidgets('a state without a frame waits honestly, then retries', (
    tester,
  ) async {
    await pumpPage(tester);
    await emitState(tester);

    // Attached, no picture: loading first…
    expect(find.text('Connecting…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));

    // …then one centred line and a real retry, not a spinner forever.
    expect(find.text('Waiting for the page…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Live'), findsNothing);

    final attachesBefore = opsOf('browser_attach').length;
    await tester.tap(find.byKey(BrowserViewport.waitingRetryKey));
    await tester.pump();
    await tester.pump();
    expect(opsOf('browser_attach').length, greaterThan(attachesBefore));
  });

  testWidgets('a browser-channel error is a real error state with a retry', (
    tester,
  ) async {
    await pumpPage(tester);
    await emitState(tester);

    raw.add(<String, dynamic>{
      'op': 'error',
      'sessionId': 's1',
      'code': 'unavailable',
      'message': 'worker down',
    });
    await tester.pump();
    await tester.pump();

    expect(find.text('Live view paused'), findsOneWidget);
    expect(
      find.text('The cloud browser is not available right now.'),
      findsOneWidget,
    );

    final attachesBefore = opsOf('browser_attach').length;
    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump();
    expect(opsOf('browser_attach').length, greaterThan(attachesBefore));
  });

  testWidgets('a picture that stops arriving says the stream is lost', (
    tester,
  ) async {
    await pumpPage(tester);
    await emitState(tester);
    await emitFrame(tester);
    expect(find.byType(Image), findsWidgets);

    await tester.pump(const Duration(seconds: 8));

    expect(find.text('Stream lost'), findsOneWidget);
    expect(find.byKey(BrowserViewport.retryKey), findsOneWidget);
  });

  testWidgets('the menu copies the real address', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await pumpPage(tester);
    await emitState(tester);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Copy address'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final copy = calls.where((call) => call.method == 'Clipboard.setData');
    expect(copy, isNotEmpty);
    expect((copy.first.arguments as Map)['text'], 'https://example.test/page');
    expect(find.text('Address copied'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    final name = dark ? 'dark' : 'light';

    testWidgets('320 dp at 200 % text, controlled, lays out ($name)', (
      tester,
    ) async {
      await pumpPage(
        tester,
        size: const Size(320, 640),
        textScale: 2,
        theme: dark ? OTheme.dark() : OTheme.light(),
      );
      await emitState(tester, _state(takeover: true));
      await emitFrame(tester);

      expect(tester.takeException(), isNull);
      expect(find.byType(Image), findsWidgets);
      expect(find.byTooltip('Return control'), findsOneWidget);
    });
  }

  testWidgets('control is not offered while the picture is still waiting', (
    tester,
  ) async {
    await pumpPage(tester);
    await emitState(tester);

    // Attached, no picture: there is nothing to aim at yet.
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.byKey(BrowserControlBar.takeControlKey), findsNothing);

    await tester.pump(const Duration(seconds: 6));
    expect(find.text('Waiting for the page…'), findsOneWidget);
    expect(find.byKey(BrowserControlBar.takeControlKey), findsNothing);

    // The first frame is what unlocks control.
    await emitFrame(tester);
    expect(find.byKey(BrowserControlBar.takeControlKey), findsOneWidget);
  });

  testWidgets('switching tabs drops the old picture instead of mislabelling it', (
    tester,
  ) async {
    await pumpPage(tester);
    await emitState(tester);
    await emitFrame(tester);
    expect(find.byType(Image), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('v2-browser-tab-1')));
    await tester.pump();

    // The old tab's last frame must not sit under the new tab's address.
    expect(find.byType(Image), findsNothing);
    expect(find.text('Connecting…'), findsOneWidget);

    // The new tab's first frame brings the picture back.
    await emitState(tester, _state(title: 'Docs'));
    await emitFrame(tester);
    expect(find.byType(Image), findsWidgets);
  });

  testWidgets('a dropped socket stops painting the last frame as live', (
    tester,
  ) async {
    final ws = _FakeLinkWs()..setLink(WsLinkState.online);
    await pumpPage(tester, ws: ws);
    await emitState(tester);
    await emitFrame(tester);
    expect(find.text('Stream lost'), findsNothing);

    ws.setLink(WsLinkState.disconnected);
    await tester.pump();
    await tester.pump();

    // The frame is still there (a stale still is better than black), but it
    // is no longer presented as a live stream, and reconnect is offered.
    expect(find.text('Stream lost'), findsOneWidget);
    expect(find.byKey(BrowserViewport.retryKey), findsOneWidget);
  });

  testWidgets('a hand-back the server ignores keeps control and says so', (
    tester,
  ) async {
    await pumpPage(tester);
    await emitState(tester, _state(takeover: true));
    await emitFrame(tester);

    await tester.tap(find.byKey(BrowserControlBar.takeControlKey));
    await tester.pump();
    expect(opsOf('browser_takeover').last['enabled'], isFalse);

    // Never optimistic: the dock stays until the server confirms.
    expect(find.byTooltip('Return control'), findsOneWidget);

    // No acknowledgement arrives; the person is told and can try again.
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('Still controlling. Try again.'), findsOneWidget);
    expect(find.byTooltip('Return control'), findsOneWidget);
  });

  testWidgets('a takeover request that cannot be sent says so', (tester) async {
    await pumpPage(tester, failTakeover: true);
    await emitState(tester);
    await emitFrame(tester);

    await tester.tap(find.byKey(BrowserControlBar.takeControlKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Start controlling'));
    await tester.pump();
    await tester.pump();

    // The request never left; the person is told and the sheet keeps its
    // retry instead of pretending control changed hands.
    expect(find.text('Could not pause the page. Try again.'), findsOneWidget);
    expect(find.byTooltip('Return control'), findsNothing);

    await tester.pump(const Duration(seconds: 6));
    expect(find.text('Could not pause'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('the page never offers download or upload', (tester) async {
    await pumpPage(tester);
    await emitState(tester, _state(takeover: true));
    await emitFrame(tester);

    expect(find.byIcon(Icons.download_rounded), findsNothing);
    expect(find.byIcon(Icons.upload_rounded), findsNothing);
    expect(find.byTooltip('Download'), findsNothing);
    expect(find.byTooltip('Upload'), findsNothing);
    expect(find.text('Download'), findsNothing);
    expect(find.text('Upload'), findsNothing);
  });
}
