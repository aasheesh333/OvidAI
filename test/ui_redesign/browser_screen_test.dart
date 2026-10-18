// P8 Task 16 — the rewritten cloud browser screen.
//
// The on-device WebView browser (and its suites) was deleted with the
// thin-client migration. This suite keeps the same path so the browser UI gate
// still has a home; it proves the NEW screen: the screencast canvas, the
// read-only address chrome, and the server-acked takeover affordance.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/cloud/browser_stream.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/browser_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

WsMultiplexer _ws() => WsMultiplexer(mintTicket: () async => 'ticket');

Map<String, dynamic> _state({bool takeover = false}) => <String, dynamic>{
      'sessionId': 's1',
      'live': true,
      'url': 'https://example.test/page',
      'title': 'Example page',
      'takeover': takeover,
      'screencast': true,
      'frameFormat': 'webp',
      'viewport': {'width': 1280, 'height': 800},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<Map<String, dynamic>> raw;
  late StreamController<Uint8List> binary;
  late BrowserStreamClient client;

  setUp(() {
    raw = StreamController<Map<String, dynamic>>.broadcast();
    binary = StreamController<Uint8List>.broadcast();
    client = BrowserStreamClient(
      ws: _ws(),
      rawFramesOverride: raw.stream,
      binaryFramesOverride: binary.stream,
      sendOverride: (_) async {},
    );
  });

  tearDown(() async {
    client.dispose();
    await raw.close();
    await binary.close();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
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
  }

  testWidgets('renders the cloud chrome, canvas and takeover affordance', (
    tester,
  ) async {
    await pumpScreen(tester);

    expect(find.byType(AetherGradientHeader), findsOneWidget);
    expect(find.byKey(const ValueKey('browser-tab-strip')), findsOneWidget);
    expect(find.byKey(const ValueKey('browser-url-field')), findsOneWidget);
    expect(find.byKey(const ValueKey('browser-canvas')), findsOneWidget);
    expect(find.byKey(const ValueKey('browser-takeover')), findsOneWidget);
    expect(find.text('Agent is driving — Take over'), findsOneWidget);
    expect(find.byKey(const ValueKey('browser-release')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('state updates the tab strip and address row', (tester) async {
    await pumpScreen(tester);
    raw.add(<String, dynamic>{
      'op': 'browser_state',
      'sessionId': 's1',
      'state': _state(),
    });
    await tester.pump();

    expect(find.text('Example page'), findsOneWidget);
    expect(find.text('example.test'), findsOneWidget);
    // The page title must never stand in for the address (spoof resistance).
    expect(find.text('Not secure'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a server takeover ack swaps the chip to Release control', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(find.byKey(const ValueKey('browser-takeover')));
    await tester.pump();

    // The request alone changes nothing: no optimistic flip.
    expect(find.byKey(const ValueKey('browser-takeover')), findsOneWidget);
    expect(find.byKey(const ValueKey('browser-release')), findsNothing);

    raw.add(<String, dynamic>{
      'op': 'browser_state',
      'sessionId': 's1',
      'state': _state(takeover: true),
    });
    await tester.pump();

    expect(find.byKey(const ValueKey('browser-release')), findsOneWidget);
    expect(find.text('You are controlling the browser'), findsOneWidget);
    expect(find.byKey(const ValueKey('browser-takeover')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
