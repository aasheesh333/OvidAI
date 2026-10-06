import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/html_artifact.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/html_artifact_view.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// V2 polish coverage for [HtmlArtifactView]:
///  * ONE chrome — title, sandbox status caption, collapse, source/preview
///    toggle and expand live in a single header (the bordered pill is gone).
///  * The four non-running previews (failure, unsupported, paused,
///    fullscreen-relocated) share one designed empty-state recipe with a
///    single retry where recovery exists.
///  * The sandboxed AndroidView lifecycle (collapse/background/source/
///    fullscreen) is preserved.
///
/// Native views are stubbed through the platform-views channel; the test
/// platform defaults to Android so create/dispose stay observable. Pumps are
/// fixed-count and bounded — no runAsync, no real-time waits.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channels = <int, MethodChannel>{};
  final executing = <int>{};
  Map<String, Object>? startError;

  setUp(() {
    startError = null;
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
            return startError;
          }
          if (call.method == 'disposeDocument') executing.remove(id);
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

  HtmlArtifact artifact() => HtmlArtifact.create('owner', {
    'title': 'Demo artifact',
    'html': '<p>Hello marker</p>',
    'css': 'p { color: red; }',
    'javascript': 'void main() {}',
    'height': 320,
  });

  /// Three fixed pumps: mount/layout, platform-view creation callback, and
  /// the serialized startDocument acknowledgement.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
  }

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: HtmlArtifactView(artifact: artifact(), sessionId: 'owner'),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  /// The single chrome contract: caption + collapse + source + expand,
  /// each exactly once.
  void expectChrome() {
    expect(find.text('Demo artifact'), findsOneWidget);
    expect(find.text('OFFLINE SANDBOX'), findsOneWidget);
    expect(find.byTooltip('Collapse artifact'), findsOneWidget);
    expect(find.byTooltip('View source'), findsOneWidget);
    expect(find.byTooltip('Expand preview'), findsOneWidget);
  }

  /// The shared empty-state recipe: one circled 20px icon, one title, an
  /// optional caption, and at most one retry — never a native view.
  void expectPlaceholder(
    IconData icon,
    String title, {
    String? message,
    bool retry = false,
    bool skipOffstage = true,
  }) {
    expect(
      find.byWidgetPredicate(
        (w) => w is Icon && w.icon == icon && w.size == 20,
        skipOffstage: skipOffstage,
      ),
      findsOneWidget,
    );
    expect(find.text(title, skipOffstage: skipOffstage), findsOneWidget);
    if (message != null) {
      expect(find.text(message, skipOffstage: skipOffstage), findsOneWidget);
    }
    expect(
      find.widgetWithText(TextButton, 'Retry', skipOffstage: skipOffstage),
      retry ? findsOneWidget : findsNothing,
    );
  }

  testWidgets('chrome renders once: title, status caption, collapse, source '
      'and expand actions', (tester) async {
    await pumpHost(tester);

    expect(find.byType(AetherCard), findsOneWidget);
    expectChrome();
    // Two labeled ghost actions (source, expand); collapse is the icon
    // button in the same row.
    expect(find.byType(AetherGhostButton), findsNWidgets(2));

    // The bordered OFFLINE SANDBOX pill is gone: the marker survives only as
    // an Aether caption styled with the type scale, inside no pill.
    expect(
      find.ancestor(
        of: find.text('OFFLINE SANDBOX'),
        matching: find.byType(AetherPill),
      ),
      findsNothing,
    );
    final caption = tester.widget<Text>(find.text('OFFLINE SANDBOX'));
    expect(caption.style?.fontSize, AetherType.caption.fontSize);
    expect(caption.style?.color, AetherType.caption.color);

    // A running preview shows no placeholder.
    expect(find.byType(AndroidView), findsOneWidget);
    expect(executing, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapse destroys the running preview and reopen starts '
      'fresh', (tester) async {
    await pumpHost(tester);
    expect(find.byType(AndroidView), findsOneWidget);
    expect(executing, hasLength(1));

    await tester.tap(find.byTooltip('Collapse artifact'));
    await settle(tester);

    // Native execution is stopped, the preview is destroyed and the chrome
    // contracts to title + reopen.
    expect(executing, isEmpty);
    expect(find.byType(AndroidView), findsNothing);
    expect(find.byTooltip('View source'), findsNothing);
    expect(find.byTooltip('Expand preview'), findsNothing);
    expect(find.byTooltip('Open artifact'), findsOneWidget);
    expect(find.text('Demo artifact'), findsOneWidget);
    expect(find.text('OFFLINE SANDBOX'), findsOneWidget);

    await tester.tap(find.byTooltip('Open artifact'));
    await settle(tester);

    expect(find.byType(AndroidView), findsOneWidget);
    expect(executing, hasLength(1));
    expectChrome();
  });

  testWidgets('source toggle swaps the live preview for selectable source '
      'and back', (tester) async {
    await pumpHost(tester);
    expect(find.byType(AndroidView), findsOneWidget);

    await tester.tap(find.byTooltip('View source'));
    await settle(tester);

    expect(find.byType(AndroidView), findsNothing);
    expect(executing, isEmpty); // document destroyed, not merely hidden
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.textContaining('<p>Hello marker</p>'), findsOneWidget);
    expect(find.textContaining('p { color: red; }'), findsOneWidget);
    expect(find.textContaining('void main() {}'), findsOneWidget);
    expect(find.byTooltip('Show preview'), findsOneWidget);

    await tester.tap(find.byTooltip('Show preview'));
    await settle(tester);

    expect(find.byType(SelectableText), findsNothing);
    expect(find.byType(AndroidView), findsOneWidget);
    expect(executing, hasLength(1));
    expectChrome();
  });

  testWidgets('fullscreen opens as a route and exit restores the inline '
      'preview', (tester) async {
    await pumpHost(tester);

    await tester.tap(find.byTooltip('Expand preview'));
    await tester.pumpAndSettle();

    // Fullscreen host: same single chrome, flipped expand action.
    expect(find.byTooltip('Exit fullscreen'), findsOneWidget);
    expect(find.byTooltip('View source'), findsOneWidget);
    // The inline preview is replaced by the shared empty state while the
    // document runs in fullscreen.
    expectPlaceholder(
      Icons.fullscreen,
      'Preview open in fullscreen.',
      skipOffstage: false,
    );

    await tester.tap(find.byTooltip('Exit fullscreen'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Exit fullscreen'), findsNothing);
    expect(find.byType(AetherCard), findsOneWidget);
    expect(find.byType(AndroidView), findsOneWidget);
    expect(executing, hasLength(1));
    expectChrome();
    expect(tester.takeException(), isNull);
  });

  testWidgets('failure placeholder matches the shared design and offers one '
      'retry that recovers', (tester) async {
    await pumpHost(tester);
    final failedId = channels.keys.single;

    // A native load failure must surface the safe mapped message, never the
    // raw payload (which can embed user source).
    await messenger.handlePlatformMessage(
      'ovid/html-artifact/$failedId',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('loadError', {
          'code': 'main_frame_http',
          'status': 403,
          'message': 'data:text/html;base64,SECRET must never be displayed',
        }),
      ),
      (_) {},
    );
    await settle(tester);

    expectPlaceholder(
      Icons.error_outline,
      'Artifact preview could not be loaded.',
      retry: true,
    );
    expect(find.textContaining('SECRET'), findsNothing);
    expect(find.byType(AndroidView), findsNothing);
    expectChrome(); // chrome survives the failure

    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await settle(tester);

    expect(find.byType(AndroidView), findsOneWidget);
    expect(executing, hasLength(1));
    expect(channels.keys.last, isNot(failedId));
  });

  testWidgets('unsupported platform uses the shared empty state without a '
      'retry', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await pumpHost(tester);

    expectPlaceholder(
      Icons.phone_android_outlined,
      'Interactive preview requires Android.',
      message: 'Use View source to inspect this saved artifact.',
    );
    expect(channels, isEmpty); // no native view is ever created
    expectChrome();

    // Source remains reachable from the placeholder state.
    await tester.tap(find.byTooltip('View source'));
    await settle(tester);
    expect(find.textContaining('<p>Hello marker</p>'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('background stop uses the shared empty state and resume '
      'restarts the preview', (tester) async {
    await pumpHost(tester);
    expect(executing, hasLength(1));

    // Inactive keeps frames enabled (SchedulerBinding gates frames only on
    // hidden/paused/detached), so the stopped empty state actually paints:
    // execution halts and the shared placeholder replaces the preview.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await settle(tester);

    expect(executing, isEmpty);
    expectPlaceholder(Icons.pause_circle_outline, 'Preview paused.');
    expectChrome();

    // A hard pause additionally disables frames; execution stays stopped.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(executing, isEmpty);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);

    expect(find.byType(AndroidView), findsOneWidget);
    expect(executing, hasLength(1));
  });

  testWidgets('chrome, source and placeholders stay overflow-free at '
      '360x640 @2x and on a wide desktop viewport', (tester) async {
    const viewports = [
      (Size(720, 1280), 2.0), // 360x640 logical @2x
      (Size(1440, 900), 1.0), // wide
    ];
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final (size, dpr) in viewports) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = dpr;
      await pumpHost(tester);

      expectChrome();
      expect(tester.takeException(), isNull);

      // Source sheet fits the framed region.
      await tester.tap(find.byTooltip('View source'));
      await settle(tester);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Show preview'));
      await settle(tester);

      // Collapse contracts the chrome without overflow; reopen restores it.
      await tester.tap(find.byTooltip('Collapse artifact'));
      await settle(tester);
      expect(find.byTooltip('View source'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Open artifact'));
      await settle(tester);
      expect(find.byType(AndroidView), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
