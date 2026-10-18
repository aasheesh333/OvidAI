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
    testWidgets('renders the screencast canvas and the takeover button',
        (tester) async {
      final raw = StreamController<Map<String, dynamic>>.broadcast();
      final binary = StreamController<Uint8List>.broadcast();
      final sent = <Map<String, Object?>>[];
      final client = BrowserStreamClient(
        ws: _ws(),
        rawFramesOverride: raw.stream,
        binaryFramesOverride: binary.stream,
        sendOverride: (frame) async => sent.add(frame),
      );
      addTearDown(() async {
        client.dispose();
        await raw.close();
        await binary.close();
      });

      tester.view.physicalSize = const Size(480, 960);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: BrowserScreen(sessionId: 's1', client: client),
        ),
      );
      // Let the async local→server resolver and attach() run.
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('browser-canvas')), findsOneWidget);
      expect(find.text('Agent is driving — Take over'), findsOneWidget);

      raw.add(<String, dynamic>{
        'op': 'browser_state',
        'sessionId': 's1',
        'state': _stateJson(),
      });
      await tester.pump();

      expect(find.text('example.test'), findsOneWidget);
      expect(find.text('Agent is driving — Take over'), findsOneWidget);
    });

    testWidgets('attaches with the MAPPED server id, not the local chat id',
        (tester) async {
      const localId = '1729000000000000';
      const serverId = '0199b4e2-7c3a-7d4b-8f1e-0a1b2c3d4e5f';
      SharedPreferences.setMockInitialValues(<String, Object>{
        CloudSessionStore.idMapKey: jsonEncode(<String, String>{
          localId: serverId,
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      final ws = _ws();
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
      addTearDown(CloudSessionStore.resetForTest);
      await store.ready;

      final raw = StreamController<Map<String, dynamic>>.broadcast();
      final binary = StreamController<Uint8List>.broadcast();
      final sent = <Map<String, Object?>>[];
      final client = BrowserStreamClient(
        ws: ws,
        rawFramesOverride: raw.stream,
        binaryFramesOverride: binary.stream,
        sendOverride: (frame) async => sent.add(frame),
      );
      addTearDown(() async {
        client.dispose();
        await raw.close();
        await binary.close();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: BrowserScreen(sessionId: localId, client: client),
        ),
      );
      await tester.pump();
      await tester.pump();

      final attach = sent.singleWhere((f) => f['op'] == 'browser_attach');
      expect(attach['sessionId'], serverId,
          reason: 'the gateway rejects a local timestamp id with forbidden');
    });

    testWidgets('an attach error is shown and Retry re-attaches',
        (tester) async {
      final raw = StreamController<Map<String, dynamic>>.broadcast();
      final binary = StreamController<Uint8List>.broadcast();
      final sent = <Map<String, Object?>>[];
      final client = BrowserStreamClient(
        ws: _ws(),
        rawFramesOverride: raw.stream,
        binaryFramesOverride: binary.stream,
        sendOverride: (frame) async => sent.add(frame),
      );
      addTearDown(() async {
        client.dispose();
        await raw.close();
        await binary.close();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: BrowserScreen(sessionId: 's1', client: client),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(sent.where((f) => f['op'] == 'browser_attach'), hasLength(1));

      raw.add(<String, dynamic>{
        'op': 'error',
        'code': 'forbidden',
        'message': 'Session not found.',
        'sessionId': 's1',
      });
      await tester.pump();

      expect(find.byKey(const ValueKey('browser-error')), findsOneWidget);
      expect(find.text('Browser unavailable'), findsOneWidget);
      expect(find.text('Session not found.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('browser-retry')));
      await tester.pump();
      await tester.pump();
      expect(sent.where((f) => f['op'] == 'browser_attach'), hasLength(2),
          reason: 'Retry must re-send browser_attach');
    });

    testWidgets('an attached session with no frame says so after a bounded wait',
        (tester) async {
      final raw = StreamController<Map<String, dynamic>>.broadcast();
      final binary = StreamController<Uint8List>.broadcast();
      final client = BrowserStreamClient(
        ws: _ws(),
        rawFramesOverride: raw.stream,
        binaryFramesOverride: binary.stream,
        sendOverride: (_) async {},
      );
      addTearDown(() async {
        client.dispose();
        await raw.close();
        await binary.close();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: BrowserScreen(sessionId: 's1', client: client),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('The cloud browser is starting…'), findsOneWidget);

      // The worker sends nothing for a chat whose agent never browsed.
      await tester.pump(const Duration(seconds: 8));
      await tester.pump();
      expect(
        find.text("The agent hasn't opened a page in this chat yet."),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('browser-retry')), findsOneWidget);
    });

  });
}
