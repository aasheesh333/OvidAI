import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/studio_remote_client.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_drafts.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_layout.dart';
import 'package:ovid_ai/ui/studio_screen.dart';

import 'support/studio_fake_gateway.dart';

/// Studio responsive layout, re-pointed at the P7 workspace API.
///
/// The breakpoint scheme is unchanged: below 600dp the tree is an overlay,
/// the editor keeps its
/// minimum width/height on every device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeStudioGateway fake;
  late StudioRemoteClient remote;


  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    StudioDraftStore.I.disableForTest();
    final app = AppState.createForTest();
    app.sessions.add(ChatSession(
      id: kFakeStudioSession,
      title: 'Studio',
      model: 'gpt-4o',
    ));
    app.activeSessionId = kFakeStudioSession;

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
    remote.clearAll();
    StudioDraftStore.I.disableForTest();
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
      MaterialApp(theme: Aether.theme(), home: StudioScreen(
          workspaceKey: kFakeStudioSession,
          agentEvents: Stream<CloudSessionEvent>.empty(),
        )),
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
    });

    testWidgets('the tree opens as an overlay and the scrim closes it',
        (tester) async {
      setSurface(tester, const Size(360, 640));
      await pumpStudio(tester);

      await tester.tap(find.byTooltip('Show files'));
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
      expect(find.byTooltip('Hide files'), findsOneWidget,
          reason: 'the tree toggle is always available');
    });
  });
}
