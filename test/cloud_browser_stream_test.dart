// P8 Task 16 — P6 browser screencast channel.
//
// Wire contract is the BUILT server (cloud/packages/shared/src/browser.ts,
// cloud/apps/gateway/src/ws.ts):
//   client → `browser_attach{sessionId}`, `browser_detach{sessionId}`,
//            `browser_input{sessionId,input}`, `browser_takeover{sessionId,enabled}`
//   server → `browser_state{state}` JSON + raw BINARY image bytes.
//
// The binary fixture is a REAL 1×1 WebP (verified with `file`:
// "RIFF ... Web/P image, VP8 encoding, 1x1"), so the decode path is exercised
// end to end rather than against a hand-built stand-in.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/browser_stream.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/connection_service.dart';
import 'package:ovid_ai/core/session_history_store.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/browser_screen.dart';

const String _webp1x1Base64 =
    'UklGRiQAAABXRUJQVlA4IBgAAAAwAQCdASoBAAEAAwA0JaQAA3AA/vuUAAA=';

Uint8List _webp1x1() => base64Decode(_webp1x1Base64);

/// A multiplexer whose link state a test can flip (the real one derives it
/// from a socket).
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

Map<String, dynamic> _stateJson({
  String sessionId = 's1',
  bool takeover = false,
  bool live = true,
  String? url = 'https://example.test/',
  String? title = 'Example',
}) =>
    <String, dynamic>{
      'sessionId': sessionId,
      'live': live,
      'url': url,
      'title': title,
      'takeover': takeover,
      'screencast': true,
      'frameFormat': 'webp',
      'viewport': {'width': 1280, 'height': 800},
    };

WsMultiplexer _ws() => WsMultiplexer(mintTicket: () async => 'ticket');

void main() {
  group('BrowserStreamClient', () {
    late StreamController<Map<String, dynamic>> raw;
    late StreamController<Uint8List> binary;
    late List<Map<String, Object?>> sent;
    late BrowserStreamClient client;

    setUp(() {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      CloudSessionStore.resetForTest();
      raw = StreamController<Map<String, dynamic>>.broadcast();
      binary = StreamController<Uint8List>.broadcast();
      sent = <Map<String, Object?>>[];
      client = BrowserStreamClient(
        ws: _ws(),
        rawFramesOverride: raw.stream,
        binaryFramesOverride: binary.stream,
        sendOverride: (frame) async => sent.add(frame),
      );
    });

    tearDown(() async {
      client.dispose();
      CloudSessionStore.resetForTest();
      await raw.close();
      await binary.close();
    });

    List<Map<String, Object?>> inputOps() => sent
        .where((f) => f['op'] == 'browser_input')
        .map((f) => Map<String, Object?>.from(f))
        .toList();

    test('a binary 1×1 WebP frame decodes into a BrowserFrame', () async {
      await client.attach('s1');
      expect(sent.first, <String, Object?>{
        'op': 'browser_attach',
        'sessionId': 's1',
      });

      final next = client.frames.first;
      binary.add(_webp1x1());
      final frame = await next;

      expect(frame.width, 1);
      expect(frame.height, 1);
      expect(frame.webpBytes, _webp1x1());
    });

    test('a tap BEFORE the takeover ack writes nothing; after the ack it does',
        () async {
      await client.attach('s1');

      // The server's initial state: the agent is driving.
      raw.add(<String, dynamic>{
        'op': 'browser_state',
        'sessionId': 's1',
        'state': _stateJson(takeover: false),
      });
      await Future<void>.delayed(Duration.zero);
      expect(client.takeoverActive, isFalse);

      client.sendTap(10, 20);
      await Future<void>.delayed(Duration.zero);
      expect(inputOps(), isEmpty,
          reason: 'input must be ignored while the agent drives');

      // Asking is not owning: the flag flips only on the server's ack.
      await client.requestTakeover();
      expect(client.takeoverActive, isFalse);
      expect(
        sent.where((f) => f['op'] == 'browser_takeover').toList(),
        <Map<String, Object?>>[
          <String, Object?>{
            'op': 'browser_takeover',
            'sessionId': 's1',
            'enabled': true,
          },
        ],
      );

      client.sendTap(11, 22);
      await Future<void>.delayed(Duration.zero);
      expect(inputOps(), isEmpty,
          reason: 'the request was sent but not yet acknowledged');

      // Server ack: a browser_state carrying takeover=true.
      raw.add(<String, dynamic>{
        'op': 'browser_state',
        'sessionId': 's1',
        'state': _stateJson(takeover: true),
      });
      await Future<void>.delayed(Duration.zero);
      expect(client.takeoverActive, isTrue);

      client.sendTap(12, 34);
      await Future<void>.delayed(Duration.zero);
      expect(inputOps(), <Map<String, Object?>>[
        <String, Object?>{
          'op': 'browser_input',
          'sessionId': 's1',
          'input': <String, Object?>{'type': 'tap', 'x': 12.0, 'y': 34.0},
        },
      ]);
    });

    test('scroll and key use the built input-event union', () async {
      await client.attach('s1');
      raw.add(<String, dynamic>{
        'op': 'browser_state',
        'sessionId': 's1',
        'state': _stateJson(takeover: true),
      });
      await Future<void>.delayed(Duration.zero);

      client.sendScroll(0, 120);
      client.sendKey('Enter');
      await Future<void>.delayed(Duration.zero);

      expect(inputOps().map((f) => f['input']).toList(), <Object?>[
        <String, Object?>{'type': 'scroll', 'dx': 0.0, 'dy': 120.0},
        <String, Object?>{'type': 'key', 'key': 'Enter'},
      ]);
    });

    test('detach sends browser_detach and stops forwarding frames', () async {
      await client.attach('s1');
      client.detach();
      expect(sent.last, <String, Object?>{
        'op': 'browser_detach',
        'sessionId': 's1',
      });

      var emitted = 0;
      final sub = client.frames.listen((_) => emitted++);
      binary.add(_webp1x1());
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(emitted, 0);
    });

    test('browser_state updates url/title/viewport and ignores other sessions',
        () async {
      await client.attach('s1');
      raw.add(<String, dynamic>{
        'op': 'browser_state',
        'sessionId': 'other',
        'state': _stateJson(sessionId: 'other', url: 'https://wrong.test/'),
      });
      raw.add(<String, dynamic>{
        'op': 'browser_state',
        'sessionId': 's1',
        'state': _stateJson(),
      });
      await Future<void>.delayed(Duration.zero);

      expect(client.state?.url, 'https://example.test/');
      expect(client.state?.viewportWidth, 1280);
      expect(client.state?.viewportHeight, 800);
      expect(client.state?.frameFormat, 'webp');
    });

    test('a session-scoped error frame becomes a readable client error',
        () async {
      await client.attach('s1');
      raw.add(<String, dynamic>{
        'op': 'error',
        'code': 'forbidden',
        'message': 'Session not found.',
        'sessionId': 's1',
      });
      await Future<void>.delayed(Duration.zero);

      expect(client.error?.code, 'forbidden');
      expect(client.error?.message, 'Session not found.');

      // The next good state clears it.
      raw.add(<String, dynamic>{
        'op': 'browser_state',
        'sessionId': 's1',
        'state': _stateJson(),
      });
      await Future<void>.delayed(Duration.zero);
      expect(client.error, isNull);
      expect(client.state, isNotNull);
    });

    test('an error for another session is ignored', () async {
      await client.attach('s1');
      raw.add(<String, dynamic>{
        'op': 'error',
        'code': 'forbidden',
        'message': 'Session not found.',
        'sessionId': 'other',
      });
      await Future<void>.delayed(Duration.zero);
      expect(client.error, isNull);
    });

    test('a link reconnect re-sends browser_attach and clears stale state',
        () async {
      final ws = _FakeLinkWs();
      final sentOps = <Map<String, Object?>>[];
      final reconnecting = BrowserStreamClient(
        ws: ws,
        rawFramesOverride: raw.stream,
        binaryFramesOverride: binary.stream,
        sendOverride: (frame) async => sentOps.add(frame),
      );
      addTearDown(reconnecting.dispose);

      ws.setLink(WsLinkState.online);
      await reconnecting.attach('s1');
      raw.add(<String, dynamic>{
        'op': 'browser_state',
        'sessionId': 's1',
        'state': _stateJson(),
      });
      await Future<void>.delayed(Duration.zero);
      expect(reconnecting.state, isNotNull);

      // The gateway tore the attach down with the socket; coming back online
      // must attach again (raw ops are not replayed).
      ws.setLink(WsLinkState.disconnected);
      ws.setLink(WsLinkState.online);
      await Future<void>.delayed(Duration.zero);

      expect(
        sentOps.where((f) => f['op'] == 'browser_attach').toList(),
        <Map<String, Object?>>[
          <String, Object?>{'op': 'browser_attach', 'sessionId': 's1'},
          <String, Object?>{'op': 'browser_attach', 'sessionId': 's1'},
        ],
      );
      expect(reconnecting.state, isNull,
          reason: 'a pre-reconnect frame must not read as live');
    });

    test('a decode queued for session A never paints into session B',
        () async {
      final gate = Completer<void>();
      var decodes = 0;
      final switching = BrowserStreamClient(
        ws: _ws(),
        rawFramesOverride: raw.stream,
        binaryFramesOverride: binary.stream,
        sendOverride: (_) async {},
        decodeFrame: (bytes) async {
          decodes++;
          await gate.future;
          return BrowserFrame(webpBytes: bytes, width: 1, height: 1);
        },
      );
      addTearDown(switching.dispose);
      final painted = <BrowserFrame>[];
      final sub = switching.frames.listen(painted.add);

      await switching.attach('A');
      binary.add(_webp1x1());
      await Future<void>.delayed(Duration.zero);
      expect(decodes, 1, reason: 'A frame is decoding when B attaches');

      await switching.attach('B');
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(painted, isEmpty, reason: "A's in-flight frame leaked into B");

      // B's own frames still flow.
      binary.add(_webp1x1());
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(painted, hasLength(1));
      await sub.cancel();
    });

    // ---- Wave 5: per-user browser, per-viewer takeover, keyboard, scroll ----

    test('states match on the op-level echo id (the DTO carries the per-user key)',
        () async {
      await client.attach('s1');
      raw.add(<String, dynamic>{
        'op': 'browser_state',
        'sessionId': 'other',
        'state': _stateJson(sessionId: 'user-u1', url: 'https://wrong.test/'),
      });
      raw.add(<String, dynamic>{
        'op': 'browser_state',
        'sessionId': 's1',
        'viewerId': 'v1',
        'state': _stateJson(sessionId: 'user-u1'),
      });
      await Future<void>.delayed(Duration.zero);
      expect(client.state?.url, 'https://example.test/');
      expect(client.viewerId, 'v1');
    });

    test('takeover belongs to ONE viewer: another device holding it is read-only here',
        () async {
      await client.attach('s1');
      raw.add(<String, dynamic>{
        'op': 'browser_state',
        'sessionId': 's1',
        'viewerId': 'me',
        'state': _stateJson(takeover: true)..['takeoverViewerId'] = 'other-device',
      });
      await Future<void>.delayed(Duration.zero);
      expect(client.takeoverActive, isFalse);
      expect(client.controlledElsewhere, isTrue);
      client.sendTap(1, 2);
      await Future<void>.delayed(Duration.zero);
      expect(inputOps(), isEmpty);

      raw.add(<String, dynamic>{
        'op': 'browser_state',
        'sessionId': 's1',
        'viewerId': 'me',
        'state': _stateJson(takeover: true)..['takeoverViewerId'] = 'me',
      });
      await Future<void>.delayed(Duration.zero);
      expect(client.takeoverActive, isTrue);
      expect(client.controlledElsewhere, isFalse);
    });

    test('Take control is pending until the ack, and times out honestly',
        () async {
      final timed = BrowserStreamClient(
        ws: _ws(),
        rawFramesOverride: raw.stream,
        binaryFramesOverride: binary.stream,
        sendOverride: (frame) async => sent.add(frame),
        takeoverAckTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(timed.dispose);
      await timed.attach('s1');
      raw.add(<String, dynamic>{
        'op': 'browser_state',
        'sessionId': 's1',
        'state': _stateJson(),
      });
      await Future<void>.delayed(Duration.zero);

      await timed.requestTakeover();
      expect(timed.takeoverPending, isTrue);
      expect(timed.takeoverFailed, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(timed.takeoverPending, isFalse);
      expect(timed.takeoverFailed, isTrue);

      // A retry that IS acknowledged clears the failure.
      await timed.requestTakeover();
      expect(timed.takeoverFailed, isFalse);
      raw.add(<String, dynamic>{
        'op': 'browser_state',
        'sessionId': 's1',
        'state': _stateJson(takeover: true),
      });
      await Future<void>.delayed(Duration.zero);
      expect(timed.takeoverPending, isFalse);
      expect(timed.takeoverActive, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(timed.takeoverFailed, isFalse, reason: 'acked: the timer is void');
    });

    test('there is nothing to take over without a live page', () async {
      await client.attach('s1');
      raw.add(<String, dynamic>{
        'op': 'browser_state',
        'sessionId': 's1',
        'state': _stateJson(live: false, url: null, title: null),
      });
      await Future<void>.delayed(Duration.zero);
      expect(client.canTakeOver, isFalse);
      await client.requestTakeover();
      expect(sent.where((f) => f['op'] == 'browser_takeover'), isEmpty);
    });

    test('keyboard: text is inserted, special keys are pressed (FE-008)',
        () async {
      await client.attach('s1');
      raw.add(<String, dynamic>{
        'op': 'browser_state',
        'sessionId': 's1',
        'state': _stateJson(takeover: true),
      });
      await Future<void>.delayed(Duration.zero);

      client.sendText('héllo');
      client.sendKey('Backspace');
      client.sendKey('Tab');
      client.sendKey('Enter');
      client.sendText('');
      await Future<void>.delayed(Duration.zero);
      expect(inputOps().map((f) => f['input']).toList(), <Object?>[
        <String, Object?>{'type': 'key', 'key': 'Insert', 'text': 'héllo'},
        <String, Object?>{'type': 'key', 'key': 'Backspace'},
        <String, Object?>{'type': 'key', 'key': 'Tab'},
        <String, Object?>{'type': 'key', 'key': 'Enter'},
      ]);
    });

    test('scroll carries the finger position; double tap and long press map to the union',
        () async {
      await client.attach('s1');
      raw.add(<String, dynamic>{
        'op': 'browser_state',
        'sessionId': 's1',
        'state': _stateJson(takeover: true),
      });
      await Future<void>.delayed(Duration.zero);

      client.sendScroll(0, 40, x: 100, y: 200);
      client.sendDoubleTap(5, 6);
      client.sendLongPress(7, 8);
      await Future<void>.delayed(Duration.zero);
      expect(inputOps().map((f) => f['input']).toList(), <Object?>[
        <String, Object?>{'type': 'scroll', 'dx': 0.0, 'dy': 40.0, 'x': 100.0, 'y': 200.0},
        <String, Object?>{'type': 'double_tap', 'x': 5.0, 'y': 6.0},
        <String, Object?>{'type': 'long_press', 'x': 7.0, 'y': 8.0},
      ]);
    });

    test('input refusals are transient notices, never the screen-level error',
        () async {
      await client.attach('s1');
      raw.add(<String, dynamic>{
        'op': 'error',
        'code': 'not_controller',
        'message': 'The browser is being controlled on another device.',
        'sessionId': 's1',
      });
      await Future<void>.delayed(Duration.zero);
      expect(client.error, isNull);
      expect(client.notice?.code, 'not_controller');
    });

    test('the user alias attaches without a chat', () async {
      await client.attach(BrowserStreamClient.userAlias);
      expect(sent.single, <String, Object?>{
        'op': 'browser_attach',
        'sessionId': 'user',
      });
    });

    test('the production decoder returns the decoded image (no second decode)',
        () async {
      final frame = await decodeBrowserFrame(_webp1x1());
      expect(frame.image, isNotNull);
      expect(frame.image!.width, 1);
      expect(frame.image!.height, 1);
      frame.image!.dispose();
    });
  });

  group('BrowserScreen (cloud)', () {
    late StreamController<Map<String, dynamic>> raw;
    late StreamController<Uint8List> binary;
    late List<Map<String, Object?>> sent;
    late _FakeLinkWs ws;
    late BrowserStreamClient client;

    setUp(() {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      CloudSessionStore.resetForTest();
      raw = StreamController<Map<String, dynamic>>.broadcast();
      binary = StreamController<Uint8List>.broadcast();
      sent = <Map<String, Object?>>[];
      ws = _FakeLinkWs()..setLink(WsLinkState.online);
    });

    tearDown(() async {
      CloudSessionStore.resetForTest();
      await raw.close();
      await binary.close();
    });

    Future<void> pumpScreen(WidgetTester tester, {String? sessionId = 's1'}) async {
      // Built INSIDE the test's fake-async zone: the client's decode chain
      // must run on the zone the tester pumps.
      client = BrowserStreamClient(
        ws: ws,
        rawFramesOverride: raw.stream,
        binaryFramesOverride: binary.stream,
        sendOverride: (frame) async => sent.add(frame),
        // Dimensions without an engine image: the screen paints the bytes.
        decodeFrame: (bytes) async =>
            BrowserFrame(webpBytes: bytes, width: 1280, height: 800),
      );
      addTearDown(client.dispose);
      tester.view.physicalSize = const Size(480, 960);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: BrowserScreen(sessionId: sessionId, client: client),
        ),
      );
      // Let the async id resolver and attach() run.
      await tester.pump();
      await tester.pump();
    }

    String attachId() =>
        sent.lastWhere((f) => f['op'] == 'browser_attach')['sessionId']! as String;

    Future<void> pushState(
      WidgetTester tester,
      Map<String, dynamic> state, {
      String viewerId = 'me',
    }) async {
      raw.add(<String, dynamic>{
        'op': 'browser_state',
        'sessionId': attachId(),
        'viewerId': viewerId,
        'state': state,
      });
      await tester.pump();
    }

    Future<void> pushFrame(WidgetTester tester) async {
      binary.add(_webp1x1());
      await tester.pump();
      await tester.pump();
    }

    List<Map<String, Object?>> inputs() => sent
        .where((f) => f['op'] == 'browser_input')
        .map((f) => Map<String, Object?>.from(f['input']! as Map))
        .toList();

    testWidgets('loading state first, then the live page with Take control',
        (tester) async {
      await pumpScreen(tester);
      expect(find.byKey(const ValueKey('browser-canvas')), findsOneWidget);
      expect(find.byKey(const ValueKey('browser-loading')), findsOneWidget);
      expect(find.byKey(const ValueKey('browser-takeover')), findsNothing,
          reason: 'nothing to control before the server says a page is live');

      await pushState(tester, _stateJson(sessionId: 'user-u1'));
      await pushFrame(tester);
      expect(find.text('example.test'), findsOneWidget);
      expect(find.byKey(const ValueKey('browser-takeover')), findsOneWidget);
      expect(find.text('Take control'), findsOneWidget);
    });

    testWidgets('EM-019: no live browser ⇒ no "Agent is driving" chip, honest idle copy',
        (tester) async {
      await pumpScreen(tester);
      await pushState(
        tester,
        _stateJson(live: false, url: null, title: null),
      );
      expect(find.byKey(const ValueKey('browser-takeover')), findsNothing);
      expect(find.byKey(const ValueKey('browser-idle')), findsOneWidget);
      expect(find.text("The agent isn't using the browser right now"),
          findsOneWidget);
      expect(find.text('No page open'), findsOneWidget);
    });

    testWidgets('no state at all after the bounded wait ⇒ idle copy + Check again',
        (tester) async {
      await pumpScreen(tester);
      expect(find.byKey(const ValueKey('browser-loading')), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.byKey(const ValueKey('browser-idle')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('browser-retry')));
      await tester.pump();
      await tester.pump();
      expect(sent.where((f) => f['op'] == 'browser_attach'), hasLength(2));
    });

    testWidgets('an unsent chat (no server id) attaches to the user browser, never a local id',
        (tester) async {
      await pumpScreen(tester, sessionId: '1729000000000000');
      expect(attachId(), BrowserStreamClient.userAlias);
    });

    testWidgets('no chat at all (the /browser route) still attaches', (tester) async {
      await pumpScreen(tester, sessionId: null);
      expect(attachId(), BrowserStreamClient.userAlias);
    });

    testWidgets('attaches with the MAPPED server id when the chat has one',
        (tester) async {
      const localId = '1729000000000000';
      const serverId = '0199b4e2-7c3a-7d4b-8f1e-0a1b2c3d4e5f';
      SharedPreferences.setMockInitialValues(<String, Object>{
        CloudSessionStore.idMapKey: jsonEncode(<String, String>{
          localId: serverId,
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      final store = CloudSessionStore(
        rest: CloudRestClient(
          headers: CloudHeaders.forTest(),
          restBase: 'http://test',
        ),
        cache: SessionHistoryRepository.I,
        prefs: prefs,
        connection: ConnectionService.forTest(),
        ws: ws,
      );
      CloudSessionStore.installForTest(store);
      await store.ready;

      await pumpScreen(tester, sessionId: localId);
      expect(attachId(), serverId);
    });

    testWidgets('an attach error shows friendly copy (no raw code) and Retry re-attaches',
        (tester) async {
      await pumpScreen(tester);
      raw.add(<String, dynamic>{
        'op': 'error',
        'code': 'forbidden',
        'message': 'Session not found.',
        'sessionId': attachId(),
      });
      await tester.pump();

      expect(find.byKey(const ValueKey('browser-error')), findsOneWidget);
      expect(find.text('Browser unavailable'), findsOneWidget);
      expect(find.text('forbidden'), findsNothing);
      expect(find.text('Session not found.'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('browser-retry')));
      await tester.pump();
      await tester.pump();
      expect(sent.where((f) => f['op'] == 'browser_attach'), hasLength(2));
    });

    testWidgets('Take control: pending spinner, then a timeout says so and offers Try again',
        (tester) async {
      await pumpScreen(tester);
      await pushState(tester, _stateJson());
      await pushFrame(tester);

      await tester.tap(find.text('Take control'));
      await tester.pump();
      expect(find.byKey(const ValueKey('browser-takeover-pending')), findsOneWidget);
      expect(sent.where((f) => f['op'] == 'browser_takeover'), hasLength(1));

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.byKey(const ValueKey('browser-takeover-failed')), findsOneWidget);
      expect(find.text("Couldn't take control"), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pump();
      await pushState(tester, _stateJson(takeover: true)..['takeoverViewerId'] = 'me');
      expect(find.byKey(const ValueKey('browser-release')), findsOneWidget);
      expect(find.text('Resume agent'), findsOneWidget);
    });

    testWidgets('another device in control ⇒ read-only banner here (FE-026)',
        (tester) async {
      await pumpScreen(tester);
      await pushState(
        tester,
        _stateJson(takeover: true)..['takeoverViewerId'] = 'tablet',
      );
      await pushFrame(tester);
      expect(find.byKey(const ValueKey('browser-elsewhere')), findsOneWidget);
      expect(find.text('Controlled on another device'), findsOneWidget);
      expect(find.byKey(const ValueKey('browser-release')), findsNothing);
    });

    testWidgets('scroll follows the finger and streams DURING the drag (FE-009)',
        (tester) async {
      await pumpScreen(tester);
      await pushState(tester, _stateJson(takeover: true)..['takeoverViewerId'] = 'me');
      await pushFrame(tester);

      final canvas = find.byKey(const ValueKey('browser-canvas'));
      final gesture = await tester.startGesture(tester.getCenter(canvas));
      // Finger moves UP: the page must scroll DOWN (positive wheel dy).
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(0, -20));
        await tester.pump(const Duration(milliseconds: 30));
      }
      final midDrag = inputs().where((i) => i['type'] == 'scroll').toList();
      expect(midDrag, isNotEmpty, reason: 'scroll must not wait for finger-up');
      for (final s in midDrag) {
        expect(s['dy']! as double, greaterThan(0));
        expect(s.containsKey('x'), isTrue);
        expect(s.containsKey('y'), isTrue);
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('keyboard: typing inserts text, deleting sends Backspace, keys bar sends Tab/Enter (FE-008)',
        (tester) async {
      await pumpScreen(tester);
      await pushState(tester, _stateJson(takeover: true)..['takeoverViewerId'] = 'me');
      await pushFrame(tester);

      await tester.tap(find.byKey(const ValueKey('browser-keyboard')));
      await tester.pump();
      final field = find.byKey(const ValueKey('browser-keyboard-field'));
      await tester.enterText(field, '​​abc');
      await tester.pump();
      await tester.enterText(field, '​');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('browser-key-tab')));
      await tester.tap(find.byKey(const ValueKey('browser-key-enter')));
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();

      expect(inputs(), <Map<String, Object?>>[
        <String, Object?>{'type': 'key', 'key': 'Insert', 'text': 'abc'},
        <String, Object?>{'type': 'key', 'key': 'Backspace'},
        <String, Object?>{'type': 'key', 'key': 'Tab'},
        <String, Object?>{'type': 'key', 'key': 'Enter'},
        <String, Object?>{'type': 'key', 'key': 'Enter'},
      ]);
    });

    testWidgets('link drop ⇒ Reconnecting banner over the stale frame; no takeover offered (FE-020)',
        (tester) async {
      await pumpScreen(tester);
      await pushState(tester, _stateJson());
      await pushFrame(tester);
      expect(find.byKey(const ValueKey('browser-reconnecting')), findsNothing);

      ws.setLink(WsLinkState.disconnected);
      await tester.pump();
      // The reconnect path clears the stale state; with no frame left the
      // placeholder itself says so.
      expect(find.text('Reconnecting…'), findsWidgets);
      expect(find.byKey(const ValueKey('browser-takeover')), findsNothing);

      ws.setLink(WsLinkState.online);
      await tester.pump();
      expect(sent.where((f) => f['op'] == 'browser_attach'), hasLength(2),
          reason: 'coming back online re-attaches');
    });

    testWidgets('backgrounding the app detaches (screencast stops); resuming re-attaches (R3)',
        (tester) async {
      await pumpScreen(tester);
      await pushState(tester, _stateJson());
      await pushFrame(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(sent.where((f) => f['op'] == 'browser_detach'), hasLength(1));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(sent.where((f) => f['op'] == 'browser_attach'), hasLength(2));
    });

    testWidgets('closing the screen detaches (the browser stays headless server-side)',
        (tester) async {
      await pumpScreen(tester);
      await pushState(tester, _stateJson());
      await tester.tap(find.byKey(const ValueKey('browser-close')));
      await tester.pumpWidget(const SizedBox());
      expect(sent.last['op'], 'browser_detach');
    });
  });
}
