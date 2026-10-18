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

import 'package:ovid_ai/core/cloud/browser_stream.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/browser_screen.dart';

const String _webp1x1Base64 =
    'UklGRiQAAABXRUJQVlA4IBgAAAAwAQCdASoBAAEAAwA0JaQAA3AA/vuUAAA=';

Uint8List _webp1x1() => base64Decode(_webp1x1Base64);

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
  });
}
