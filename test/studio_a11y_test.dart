
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

/// Studio accessibility, re-pointed at the P7 workspace API.
///
/// The screen-level invariants survive the thin-client move: every interactive
/// control is at least 44dp and labelled, and the main regions are exposed to screen readers. The removed local-sync
/// progress live region (RepoCache) is not tested.
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

  /// Measures every element a finder resolves to.
  void expectTargets(
    WidgetTester tester,
    Finder finder,
    String what, {
    String Function(Element e)? describe,
  }) {
    final elements = finder.evaluate().toList();
    expect(elements, isNotEmpty, reason: '$what: nothing to measure');
    for (final e in elements) {
      final box = e.renderObject;
      expect(box, isA<RenderBox>(), reason: '$what has no render box');
      final size = (box! as RenderBox).size;
      final who = describe == null ? what : '$what ${describe(e)}';
      expect(size.width, greaterThanOrEqualTo(kStudioTapTarget),
          reason: '$who is ${size.width}px wide');
      expect(size.height, greaterThanOrEqualTo(kStudioTapTarget),
          reason: '$who is ${size.height}px tall');
    }
  }

  String buttonName(Element e) {
    final w = e.widget;
    if (w is StudioIconButton) return '"${w.tooltip}"';
    final tip = e.findAncestorWidgetOfExactType<Tooltip>();
    return tip == null ? '' : '"${tip.message}"';
  }

  group('44dp tap targets', () {
    testWidgets('every icon button on the screen clears 44dp', (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);
      expectTargets(tester, find.byType(StudioIconButton), 'icon button',
          describe: buttonName);
    });

    testWidgets('every icon button carries a label', (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);
      final buttons = tester
          .widgetList<StudioIconButton>(find.byType(StudioIconButton))
          .toList();
      expect(buttons, isNotEmpty);
      for (final b in buttons) {
        expect(b.tooltip.trim(), isNotEmpty,
            reason: 'an unlabelled icon button is invisible to TalkBack');
      }
    });

    testWidgets('editor tabs and their close buttons clear 44dp',
        (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);
      expectTargets(tester, find.byType(StudioTapTarget), 'tap target');
      expectTargets(
        tester,
        find.byTooltip('Close tab a.dart'),
        'tab close button',
      );
    });

    testWidgets('file-tree rows clear 44dp', (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);
      final row = find.text('README.md');
      expect(row, findsOneWidget);
      final box = tester.renderObject<RenderBox>(
        find.ancestor(of: row, matching: find.byType(StudioTapTarget)).first,
      );
      expect(box.size.height, greaterThanOrEqualTo(kStudioTapTarget),
          reason: 'tree rows measured ~25dp');
    });
  });
}
