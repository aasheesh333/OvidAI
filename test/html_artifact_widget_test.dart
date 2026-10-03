import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/html_artifact.dart';
import 'package:ovid_ai/ui/html_artifact_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  final nativeChannels = <MethodChannel>[];
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
          calls.add(call);
          if (call.method == 'create') {
            final channel = MethodChannel(
              'ovid/html-artifact/${(call.arguments as Map)['id']}',
            );
            nativeChannels.add(channel);
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, (call) async {
                  calls.add(call);
                  return null;
                });
            return 1;
          }
          if (call.method == 'resize') {
            final args = call.arguments as Map;
            return {'width': args['width'], 'height': args['height']};
          }
          return null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    calls.clear();
    for (final channel in nativeChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
    nativeChannels.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
  });

  Widget host(HtmlArtifact? artifact, {String session = 'owner'}) =>
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HtmlArtifactView(artifact: artifact, sessionId: session),
          ),
        ),
      );

  testWidgets(
    'narrow preview mounts sandboxed document and source disposes it',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final artifact = HtmlArtifact.create('owner', {
        'title': 'Counter',
        'html': '<button>0</button>',
        'javascript': 'document.querySelector("button").onclick=()=>{}',
      });
      await tester.pumpWidget(host(artifact));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final create =
          calls.firstWhere((c) => c.method == 'create').arguments as Map;
      expect(create['viewType'], 'ovid/html-artifact');
      final params =
          const StandardMessageCodec().decodeMessage(
                ByteData.sublistView(create['params'] as Uint8List),
              )
              as Map;
      expect(params['document'], artifact.sandboxDocument);
      await tester.tap(find.byTooltip('View source'));
      await tester.pumpAndSettle();
      expect(find.textContaining('<button>0</button>'), findsOneWidget);
      expect(calls.where((c) => c.method == 'dispose'), hasLength(1));
      await tester.tap(find.byTooltip('Show preview'));
      await tester.pump();
      await tester.tap(find.byTooltip('Expand preview'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Collapse artifact'));
      await tester.pumpAndSettle();
      expect(find.byType(AndroidView), findsNothing);
      expect(calls.where((c) => c.method == 'dispose'), hasLength(2));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'cross-session and invalid artifacts never create a native view',
    (tester) async {
      final artifact = HtmlArtifact.create('owner', {'html': '<p>private</p>'});
      await tester.pumpWidget(host(artifact, session: 'other'));
      expect(find.textContaining('unavailable'), findsOneWidget);
      expect(calls, isEmpty);
      expect(find.textContaining('private'), findsNothing);
      await tester.pumpWidget(host(null));
      expect(calls, isEmpty);
    },
  );

  testWidgets('unsupported platform has usable source fallback', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(
      host(HtmlArtifact.create('owner', {'html': '<b>hello</b>'})),
    );
    expect(find.textContaining('Android'), findsOneWidget);
    await tester.tap(find.byTooltip('View source'));
    await tester.pumpAndSettle();
    expect(find.textContaining('<b>hello</b>'), findsOneWidget);
    expect(calls, isEmpty);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('background and session switch dispose the executing document', (
    tester,
  ) async {
    final artifact = HtmlArtifact.create('owner', {'html': '<p>private</p>'});
    await tester.pumpWidget(host(artifact));
    await tester.pump();
    expect(calls.where((c) => c.method == 'create'), hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'disposeDocument'), hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(calls.where((c) => c.method == 'create'), hasLength(2));
    await tester.pumpWidget(host(artifact, session: 'other'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'dispose'), hasLength(2));
    expect(find.byType(AndroidView), findsNothing);
  });
}
