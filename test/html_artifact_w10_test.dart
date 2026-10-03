import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/html_artifact.dart';
import 'package:ovid_ai/ui/html_artifact_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channels = <int, MethodChannel>{};
  final executing = <int>{};
  var peakExecuting = 0;
  Completer<void>? stopGate;
  Map<String, Object>? initialError;

  setUp(() {
    peakExecuting = 0;
    stopGate = null;
    initialError = null;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      final args = call.arguments as Map;
      final id = args['id'] as int;
      if (call.method == 'create') {
        final channel = MethodChannel('ovid/html-artifact/$id');
        channels[id] = channel;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'startDocument') {
            executing.add(id);
            if (executing.length > peakExecuting) {
              peakExecuting = executing.length;
            }
            return initialError;
          }
          if (call.method == 'disposeDocument') {
            await stopGate?.future;
            executing.remove(id);
          }
          return null;
        });
        return 1;
      }
      if (call.method == 'resize') {
        return {'width': args['width'], 'height': args['height']};
      }
      if (call.method == 'dispose') executing.remove(id);
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    for (final channel in channels.values) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    channels.clear();
    executing.clear();
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
  });

  final artifact = HtmlArtifact.create('owner', {
    'title': 'Counter',
    'html': '<button>0</button>',
  });
  Widget host({String session = 'owner', bool visible = true}) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: visible
            ? HtmlArtifactView(artifact: artifact, sessionId: session)
            : const Text('Chat'),
      ),
    ),
  );

  Future<void> error(int id) async {
    await messenger.handlePlatformMessage(
      channels[id]!.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('loadError', {
          'code': 'main_frame_http',
          'status': 403,
          'message': 'data:text/html;base64,SECRET must never be displayed',
        }),
      ),
      (_) {},
    );
  }

  testWidgets('main-frame error gives safe source and a fresh retry', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final failedId = channels.keys.single;
    await error(failedId);
    await tester.pumpAndSettle();
    expect(find.byType(AndroidView), findsNothing);
    expect(find.textContaining('SECRET'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
    await tester.tap(find.byTooltip('View source'));
    await tester.pumpAndSettle();
    expect(find.textContaining('<button>0</button>'), findsOneWidget);
    await tester.tap(find.byTooltip('Show preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(find.byType(AndroidView), findsOneWidget);
    expect(channels.keys.last, isNot(failedId));
    await error(failedId); // A disposed generation cannot poison its successor.
    await tester.pumpAndSettle();
    expect(find.byType(AndroidView), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'startup failure returned before event subscription has a retry',
    (tester) async {
      initialError = {'code': 'unsupported_renderer'};
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
      expect(find.byType(AndroidView), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'fullscreen is a route; stop acknowledgement precedes replacement and Back restores inline',
    (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      final inlineSize = tester.getSize(find.byType(AndroidView));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      stopGate = Completer<void>();
      await tester.tap(find.byTooltip('Expand preview'));
      await tester.pump();
      expect(channels, hasLength(1));
      stopGate!.complete();
      await tester.pumpAndSettle();
      expect(navigator.canPop(), isTrue);
      expect(find.byType(AndroidView, skipOffstage: false), findsOneWidget);
      expect(
        tester.getSize(find.byType(AndroidView)).height,
        greaterThan(inlineSize.height),
      );
      expect(peakExecuting, 1);
      expect(peakExecuting, greaterThan(0));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(navigator.canPop(), isFalse);
      expect(find.byType(AndroidView), findsOneWidget);
      expect(tester.getSize(find.byType(AndroidView)), inlineSize);
      expect(peakExecuting, 1);
      expect(channels, hasLength(3));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(executing, isEmpty);
    },
  );

  testWidgets(
    'fullscreen pauses in background and is removed on session replacement',
    (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Expand preview'));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(executing, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(executing, hasLength(1));
      await tester.pumpWidget(host(session: 'other'));
      await tester.pumpAndSettle();
      expect(find.byType(AndroidView, skipOffstage: false), findsNothing);
      expect(executing, isEmpty);
      expect(find.textContaining('unavailable'), findsOneWidget);
      expect(peakExecuting, 1);
    },
  );

  testWidgets('collapse cancels fullscreen while native stop is pending', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    stopGate = Completer<void>();
    await tester.tap(find.byTooltip('Expand preview'));
    await tester.pump();
    await tester.tap(find.byTooltip('Collapse artifact'));
    await tester.pump();
    stopGate!.complete();
    await tester.pumpAndSettle();
    expect(navigator.canPop(), isFalse);
    expect(find.byType(AndroidView), findsNothing);
    await tester.tap(find.byTooltip('Open artifact'));
    await tester.pumpAndSettle();
    expect(find.byType(AndroidView), findsOneWidget);
    await tester.tap(find.byTooltip('Expand preview'));
    await tester.pumpAndSettle();
    expect(navigator.canPop(), isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('navigation cancels fullscreen before native teardown completes', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    stopGate = Completer<void>();
    await tester.tap(find.byTooltip('Expand preview'));
    await tester.pump();
    // A transparent route keeps TickerMode enabled, so route identity matters.
    final other = PageRouteBuilder<void>(
      opaque: false,
      pageBuilder: (_, _, _) => const Scaffold(body: Text('Other screen')),
    );
    unawaited(navigator.push(other));
    await tester.pumpAndSettle();
    stopGate!.complete();
    await tester.pumpAndSettle();
    expect(other.isCurrent, isTrue);
    expect(find.byTooltip('Exit fullscreen'), findsNothing);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.byType(AndroidView), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('removing the owner closes fullscreen and stops execution', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Expand preview'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(visible: false));
    await tester.pumpAndSettle();
    expect(find.byType(AndroidView, skipOffstage: false), findsNothing);
    expect(find.text('Chat'), findsOneWidget);
    expect(executing, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'fullscreen error supports source and retry without inline execution',
    (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Expand preview'));
      await tester.pumpAndSettle();
      await error(channels.keys.last);
      await tester.pumpAndSettle();
      expect(find.byType(AndroidView, skipOffstage: false), findsNothing);
      await tester.tap(find.byTooltip('View source'));
      await tester.pumpAndSettle();
      expect(find.textContaining('<button>0</button>'), findsOneWidget);
      await tester.tap(find.byTooltip('Show preview'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pumpAndSettle();
      expect(find.byType(AndroidView, skipOffstage: false), findsOneWidget);
      expect(peakExecuting, 1);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
