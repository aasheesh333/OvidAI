import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/studio_pty.dart';
import 'package:ovid_ai/core/cloud/studio_remote_client.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_drafts.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_layout.dart';
import 'package:ovid_ai/ui/studio_screen.dart';
import 'package:ovid_ai/ui/studio_terminal_tabs.dart';

import 'support/studio_fake_gateway.dart';

/// Studio responsive layout, re-pointed at the P7 workspace API.
///
/// The breakpoint scheme is unchanged: below 600dp the tree is an overlay,
/// the terminal collapses on short viewports, and the editor keeps its
/// minimum width/height on every device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeStudioGateway fake;
  late StudioRemoteClient remote;

  WsMultiplexer idleWs() => WsMultiplexer(
        mintTicket: () async => 'ticket',
        heartbeatInterval: const Duration(hours: 1),
        pongTimeout: const Duration(hours: 1),
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    StudioDraftStore.I.disableForTest();
    studioLoginPromptOverrideForTest = (_) {};
    studioPtyChannelFactoryOverrideForTest = (sessionId, tabId) =>
        CloudPtyChannel(
          sessionId: sessionId,
          tabId: tabId,
          ws: idleWs(),
          rawFramesOverride: const Stream<Map<String, dynamic>>.empty(),
          sendOverride: (_) async {},
        );
    final app = AppState.createForTest();
    app.sessions.add(ChatSession(
      id: kFakeStudioSession,
      title: 'Studio',
      model: 'gpt-4o',
    ));
    app.activeSessionId = kFakeStudioSession;
    await GitHubService.I.initialize();

    fake = FakeStudioGateway(
      files: {
        'lib/a.dart': 'void a() {}',
        'README.md': '# hi',
      },
      roots: [
        FakeNode.dir('lib', [FakeNode.file('lib/a.dart')]),
        FakeNode.file('README.md'),
      ],
    );
    remote = installFakeStudio(fake);
    await remote.openStudioFile(kFakeStudioSession, 'lib/a.dart');
  });

  tearDown(() async {
    studioLoginPromptOverrideForTest = null;
    studioPtyChannelFactoryOverrideForTest = null;
    remote.clearAll();
    StudioDraftStore.I.disableForTest();
    await GitHubService.I.signOut();
    AppState.resetTestInstance();
  });

  void setSurface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpStudio(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const StudioScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
  }

  Size sizeOf(WidgetTester tester, Key key) =>
      tester.getSize(find.byKey(key).first);

  group('phone portrait (360x640)', () {
    testWidgets('the tree is not docked and the editor gets the full width',
        (tester) async {
      setSurface(tester, const Size(360, 640));
      await pumpStudio(tester);

      expect(find.text('FILES'), findsNothing,
          reason: 'a docked tree left ~150dp of editor');
      expect(sizeOf(tester, studioEditorPaneKey).width, 360);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the editor keeps a usable height', (tester) async {
      setSurface(tester, const Size(360, 640));
      await pumpStudio(tester);

      final editor = sizeOf(tester, studioEditorPaneKey);
      expect(editor.height,
          greaterThanOrEqualTo(StudioMetrics.minEditorHeight));
      final terminal = sizeOf(tester, studioTerminalPaneKey);
      expect(terminal.height, lessThan(240),
          reason: 'the terminal was a fixed 240px on every device');
    });

    testWidgets('the tree opens as an overlay and the scrim closes it',
        (tester) async {
      setSurface(tester, const Size(360, 640));
      await pumpStudio(tester);

      await tester.tap(find.byTooltip('Toggle files'));
      await tester.pumpAndSettle();

      expect(find.text('FILES'), findsOneWidget);
      final tree = sizeOf(tester, studioTreePaneKey);
      expect(tree.width, lessThan(360),
          reason: 'the overlay must leave the editor visible behind it');
      expect(tree.width, greaterThanOrEqualTo(200));
      // The editor still owns the full width underneath.
      expect(sizeOf(tester, studioEditorPaneKey).width, 360);

      // Tap the scrim to the right of the panel (its centre is covered).
      final scrim = tester.getRect(find.byKey(studioTreeScrimKey));
      await tester.tapAt(Offset(scrim.right - 20, scrim.center.dy));
      await tester.pumpAndSettle();
      expect(find.text('FILES'), findsNothing);
    });

    testWidgets('nothing overflows on a 320dp-wide device', (tester) async {
      setSurface(tester, const Size(320, 480));
      await pumpStudio(tester);
      expect(tester.takeException(), isNull);
      expect(sizeOf(tester, studioEditorPaneKey).width, 320);
    });

    testWidgets('a 2x OS text scale still fits', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      setSurface(tester, const Size(360, 640));
      await pumpStudio(tester);

      expect(tester.takeException(), isNull,
          reason: 'fixed 40/38/30px bars clipped scaled text');
      expect(sizeOf(tester, studioEditorPaneKey).height,
          greaterThanOrEqualTo(StudioMetrics.minEditorHeight * 0.6));
    });
  });

  group('tablet / desktop (>=840)', () {
    testWidgets('the tree is docked by default and the editor keeps 320dp',
        (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);

      expect(find.text('FILES'), findsOneWidget);
      final tree = sizeOf(tester, studioTreePaneKey);
      expect(tree.width, greaterThanOrEqualTo(StudioMetrics.minTreeWidth));
      expect(sizeOf(tester, studioEditorPaneKey).width,
          greaterThanOrEqualTo(StudioMetrics.minEditorWidth));
      expect(find.byTooltip('Toggle files'), findsOneWidget,
          reason: 'the tree toggle is always available');
    });

    testWidgets('a user-collapsed terminal still fits at 2x text scale',
        (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);

      await tester.tap(find.byTooltip('Collapse terminal'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'the collapsed bar is 44dp * text scale, not a flat 44dp');
      expect(sizeOf(tester, studioTerminalPaneKey).height,
          greaterThanOrEqualTo(StudioMetrics.collapsedBarHeight * 2));
    });

    testWidgets('dragging the pane divider resizes the tree', (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);

      final before = sizeOf(tester, studioTreePaneKey).width;
      await tester.drag(
          find.byKey(studioTreeDividerKey), const Offset(-140, 0));
      await tester.pumpAndSettle();
      final after = sizeOf(tester, studioTreePaneKey).width;

      expect(after, lessThan(before));
      expect(sizeOf(tester, studioEditorPaneKey).width,
          greaterThanOrEqualTo(StudioMetrics.minEditorWidth));
    });

    testWidgets('a divider drag can never starve the editor', (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);

      await tester.drag(
          find.byKey(studioTreeDividerKey), const Offset(4000, 0));
      await tester.pumpAndSettle();

      expect(sizeOf(tester, studioTreePaneKey).width,
          lessThanOrEqualTo(1200 - StudioMetrics.minEditorWidth));
      expect(sizeOf(tester, studioEditorPaneKey).width,
          greaterThanOrEqualTo(StudioMetrics.minEditorWidth));
    });

    testWidgets('dragging the terminal header resizes the terminal',
        (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);

      final before = sizeOf(tester, studioTerminalPaneKey).height;
      final handle = tester.getTopLeft(find.byKey(studioTerminalHandleKey));
      await tester.dragFrom(
          handle + const Offset(20, 20), const Offset(0, -140));
      await tester.pumpAndSettle();

      expect(sizeOf(tester, studioTerminalPaneKey).height,
          greaterThan(before));
      expect(sizeOf(tester, studioEditorPaneKey).height,
          greaterThanOrEqualTo(StudioMetrics.minEditorHeight));
    });

    testWidgets('the terminal cannot be dragged over the editor minimum',
        (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);

      final handle = tester.getTopLeft(find.byKey(studioTerminalHandleKey));
      await tester.dragFrom(
          handle + const Offset(20, 20), const Offset(0, 4000));
      await tester.pumpAndSettle();

      expect(sizeOf(tester, studioEditorPaneKey).height,
          greaterThanOrEqualTo(StudioMetrics.minEditorHeight));
      expect(sizeOf(tester, studioTerminalPaneKey).height,
          lessThanOrEqualTo(StudioMetrics.maxTerminalHeight));
    });

    testWidgets('the terminal collapses and gives the room back',
        (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);

      final expanded = sizeOf(tester, studioTerminalPaneKey).height;

      await tester.tap(find.byTooltip('Collapse terminal'));
      await tester.pumpAndSettle();
      final collapsed = sizeOf(tester, studioTerminalPaneKey).height;
      expect(collapsed, StudioMetrics.collapsedBarHeight);
      expect(sizeOf(tester, studioEditorPaneKey).height,
          greaterThan(expanded - collapsed - 1));

      await tester.tap(find.byTooltip('Expand terminal'));
      await tester.pumpAndSettle();
      expect(sizeOf(tester, studioTerminalPaneKey).height, expanded);
    });
  });

  group('orientation', () {
    testWidgets('a landscape phone collapses the terminal, not the editor',
        (tester) async {
      setSurface(tester, const Size(640, 360));
      await pumpStudio(tester);

      expect(tester.takeException(), isNull);
      expect(sizeOf(tester, studioTerminalPaneKey).height,
          StudioMetrics.collapsedBarHeight,
          reason: 'the 240px terminal left ~0px of editor at 360dp tall');
      expect(sizeOf(tester, studioEditorPaneKey).height,
          greaterThanOrEqualTo(StudioMetrics.minEditorHeight * 0.9));
      expect(find.byTooltip('Expand terminal'), findsOneWidget);
    });

    testWidgets('the terminal can still be expanded by hand in landscape',
        (tester) async {
      setSurface(tester, const Size(640, 360));
      await pumpStudio(tester);
      expect(sizeOf(tester, studioTerminalPaneKey).height,
          StudioMetrics.collapsedBarHeight);

      await tester.tap(find.byTooltip('Expand terminal'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'an expanded terminal must not overflow its own chrome');
      final term = sizeOf(tester, studioTerminalPaneKey).height;
      expect(term, greaterThan(StudioMetrics.collapsedBarHeight));
      expect(sizeOf(tester, studioEditorPaneKey).height, greaterThan(0));

      await tester.tap(find.byTooltip('Collapse terminal'));
      await tester.pumpAndSettle();
      expect(sizeOf(tester, studioTerminalPaneKey).height,
          StudioMetrics.collapsedBarHeight);
    });

    testWidgets('rotating portrait → landscape → portrait stays usable',
        (tester) async {
      setSurface(tester, const Size(360, 640));
      await pumpStudio(tester);
      final portraitEditor = sizeOf(tester, studioEditorPaneKey);

      setSurface(tester, const Size(640, 360));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(sizeOf(tester, studioTerminalPaneKey).height,
          StudioMetrics.collapsedBarHeight);

      setSurface(tester, const Size(360, 640));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(sizeOf(tester, studioEditorPaneKey).width, portraitEditor.width);
      expect(sizeOf(tester, studioTerminalPaneKey).height,
          greaterThan(StudioMetrics.collapsedBarHeight),
          reason: 'rotating back must bring the terminal back');
    });

    testWidgets('rotating to tablet width docks the tree', (tester) async {
      setSurface(tester, const Size(360, 640));
      await pumpStudio(tester);
      expect(find.text('FILES'), findsNothing);

      setSurface(tester, const Size(1200, 900));
      await tester.pumpAndSettle();

      expect(find.text('FILES'), findsOneWidget);
      expect(sizeOf(tester, studioEditorPaneKey).width,
          greaterThanOrEqualTo(StudioMetrics.minEditorWidth));
      expect(tester.takeException(), isNull);
    });
  });
}
