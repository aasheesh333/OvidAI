import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_editor.dart';
import 'package:ovid_ai/ui/studio_layout.dart';
import 'package:ovid_ai/ui/studio_screen.dart';

const _captureKey = Key('studio-review-capture');
const _source = 'void main() {\n  print("Studio review");\n}\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'ovid_github_token': 'tok'});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    RepoCache.I.unbind();
    studioLoginPromptOverrideForTest = (_) {};
    studioRepoSyncOverrideForTest = () async {};
    final app = AppState.createForTest();
    app.sandboxInstalled = true;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    await GitHubService.I.initialize(client: MockClient((request) async =>
        request.url.path == '/user'
            ? http.Response(jsonEncode({'login': 'octocat'}), 200)
            : http.Response('{}', 404)));
    app.activeSession!.repo = 'owner/studio-workspace';
    AgentService.I.repoFull = 'owner/studio-workspace';
    RepoCache.I.bind('owner/studio-workspace', 'tok',
        branch: 'main', sessionId: app.activeSession!.id);
    RepoCache.I.treePaths.addAll(['lib/main.dart', 'README.md']);
    RepoCache.I.files.addAll({
      'lib/main.dart': _source,
      'README.md': '# Studio workspace\nReview the source and terminal tabs.\n',
    });
    AgentService.I.openStudioFile('README.md', RepoCache.I.files['README.md']!);
    AgentService.I.openStudioFile('lib/main.dart', _source);
    RepoCache.I.notifyListeners();
  });

  tearDown(() async {
    Aether.dark = true;
    AgentService.I.pendingApproval = null;
    studioLoginPromptOverrideForTest = null;
    studioRepoSyncOverrideForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    RepoCache.I.unbind();
    await GitHubService.I.signOut();
    AppState.resetTestInstance();
  });

  Future<void> pumpStudio(WidgetTester tester, Size size, double scale,
      {bool light = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    Aether.dark = !light;
    await tester.pumpWidget(MaterialApp(
      theme: Aether.theme(),
      home: const RepaintBoundary(key: _captureKey, child: StudioScreen()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    // Autofocus can schedule its own caret-reveal animation after the first
    // frame. Finish that before issuing a competing ensureVisible scroll.
    await tester.pumpAndSettle(const Duration(milliseconds: 50),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle(const Duration(milliseconds: 50),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(finder.hitTestable(), findsOneWidget);
  }

  for (final fixture in [
    (name: 'phone large text', size: const Size(360, 640), scale: 2.0),
    (name: 'small phone', size: const Size(320, 640), scale: 1.0),
    (name: 'desktop', size: const Size(1024, 768), scale: 1.0),
  ]) {
    for (final light in [false, true]) {
      testWidgets('${fixture.name}, light=$light: editor and terminal controls remain usable',
          (tester) async {
        await pumpStudio(tester, fixture.size, fixture.scale, light: light);
        expect(tester.takeException(), isNull);
        final editor = tester.widget<TextField>(find.byKey(studioEditorFieldKey));
        expect(editor.controller!.text, _source);
        await reveal(tester, find.byTooltip('Find in file'));
        await tester.tap(find.byTooltip('Find in file'));
        await tester.pump();
        await reveal(tester, find.byKey(studioFindFieldKey));
        await tester.enterText(find.byKey(studioFindFieldKey), 'Studio');
        await tester.pump();
        expect(editor.controller!.selection.textInside(_source), 'Studio');
        await reveal(tester, find.byTooltip('Close find'));
        await tester.tap(find.byTooltip('Close find'));
        await tester.pump();
        await reveal(tester, find.byTooltip('New terminal'));
        await tester.tap(find.byTooltip('New terminal'));
        await tester.pump();
        expect(find.byTooltip('Close terminal 2'), findsOneWidget);
        await tester.tap(find.byTooltip('Close terminal 2'));
        await tester.pump();
        expect(find.byTooltip('Close terminal 1'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('large-text phone overflow menu and file overlay remain reachable',
      (tester) async {
    await pumpStudio(tester, const Size(360, 640), 2);
    await tester.tap(find.byTooltip('More Studio actions'));
    await tester.pumpAndSettle(const Duration(milliseconds: 50),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(find.text('Working folder').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Working folder'));
    await tester.pumpAndSettle(const Duration(milliseconds: 50),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(find.text('Change folder').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await reveal(tester, find.text('Use session sandbox'));
    // Dismiss the real working-folder sheet without selecting a new binding.
    await tester.tapAt(const Offset(12, 100));
    await tester.pumpAndSettle(const Duration(milliseconds: 50),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    await tester.tap(find.byTooltip('Toggle files'));
    await tester.pump();
    await tester.tap(find.text('lib'));
    await tester.pump();
    final file = find.descendant(
        of: find.byType(StudioFileTree), matching: find.text('main.dart'));
    await reveal(tester, file);
    await tester.tap(file);
    await tester.pump();
    expect(AgentService.I.activeFilePath, 'lib/main.dart');
    final scrim = tester.getRect(find.byKey(studioTreeScrimKey));
    await tester.tapAt(Offset(scrim.right - 10, scrim.center.dy));
    await tester.pump();
    expect(find.byKey(studioTreePaneKey), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('short landscape expanded terminal keeps its command field reachable',
      (tester) async {
    await pumpStudio(tester, const Size(640, 360), 1);
    await tester.tap(find.byTooltip('Expand terminal'));
    await tester.pump();
    final command = find.descendant(
        of: find.byType(StudioTerminalTabs), matching: find.byType(TextField));
    await reveal(tester, command);
    expect(tester.getSize(command).height, greaterThanOrEqualTo(44));
    expect(tester.getSize(find.byKey(studioEditorPaneKey)).height,
        greaterThanOrEqualTo(120));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final approved in [false, true]) {
    testWidgets('long phone approval is fully readable and resolves $approved',
        (tester) async {
      await pumpStudio(tester, const Size(360, 640), 2);
      final request = ApprovalRequest(
        tool: 'shell_exec_with_workspace_permissions',
        summary: 'Review this workspace command before allowing the agent to continue.',
        detail: List.generate(14, (i) => 'Line $i: inspect workspace files').join('\n'),
      );
      AgentService.I.pendingApproval = request;
      AgentService.I.notifyListeners();
      await tester.pump();
      expect(tester.takeException(), isNull);
      final detail = find.text(request.detail);
      expect(tester.widget<Text>(detail).maxLines, isNull,
          reason: 'The full command must be available for an informed decision.');
      final action = find.text(approved ? 'Approve' : 'Decline');
      await reveal(tester, action);
      expect(request.completer.isCompleted, isFalse);
      await tester.tap(action);
      await tester.pump();
      expect(await request.completer.future, approved);
      expect(AgentService.I.pendingApproval, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('populated Studio visual review capture', (tester) async {
    await pumpStudio(tester, const Size(1024, 768), 1);
    await tester.tap(find.text('lib'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byKey(studioTreePaneKey), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(studioEditorFieldKey))
        .controller!.text, _source);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('UI_REVIEW_CAPTURE')) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/opencode/ui-finish-06.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
