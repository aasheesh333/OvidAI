import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_editor.dart';
import 'package:ovid_ai/ui/studio_layout.dart';

void main() {
  final agent = AgentService.I;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    RepoCache.I.unbind();
    AppState.createForTest();
    agent.debugPauseScheduleTimerForTest(true);
    for (final path in agent.studioOpenFiles.toList()) {
      agent.closeStudioFile(path);
    }
    agent.fileBuffer.clear();
    agent.activeFilePath = null;
  });
  tearDown(() {
    agent.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    RepoCache.I.unbind();
    AppState.resetTestInstance();
  });
  Future<void> pumpEditor(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(theme: Aether.theme(), home: const Scaffold(
      body: Column(children: [StudioEditorTabs(), Expanded(child: StudioEditor())]),
    )));
    await tester.pumpAndSettle();
  }
  TextEditingController controller(WidgetTester tester) =>
      tester.widget<TextField>(find.byKey(studioEditorFieldKey)).controller!;
  bool saveEnabled(WidgetTester tester) => tester.widget<StudioIconButton>(
      find.ancestor(of: find.byTooltip('Save changes'), matching: find.byType(StudioIconButton)))
      .onPressed != null;

  for (final resolution in ['unresolved', 'Keep draft', 'Use external']) {
    testWidgets('paused root save is invalidated by external conflict: $resolution', (tester) async {
      final root = Directory.systemTemp.createTempSync('parallel-studio-paused-root-');
      addTearDown(() => root.deleteSync(recursive: true));
      final gate = Completer<String>();
      var rootRequests = 0;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) {
        rootRequests++;
        return gate.future;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      final session = AppState.I.activeSession!;
      final file = File('${root.path}/workspaces/ws_${session.sandboxId ?? session.id}/a.txt');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('base');
      agent.openStudioFile('a.txt', 'base');
      await pumpEditor(tester);
      await tester.enterText(find.byKey(studioEditorFieldKey), 'admitted draft');
      await tester.pump();
      await tester.tap(find.byTooltip('Save changes'));
      await tester.pump();
      expect(rootRequests, greaterThan(0));
      file.writeAsStringSync('external accepted');
      agent.openStudioFile('a.txt', 'external accepted');
      await tester.pumpAndSettle();
      if (resolution != 'unresolved') {
        await tester.tap(find.text(resolution));
        await tester.pumpAndSettle();
      }
      gate.complete(root.path);
      await tester.pumpAndSettle();
      expect(file.readAsStringSync(), 'external accepted');
      expect(controller(tester).text, resolution == 'Use external' ? 'external accepted' : 'admitted draft');
      expect(find.textContaining('Saved a.txt'), findsNothing);
    });
  }

  testWidgets('two dirty tabs retain independent save state and caret after close/reopen', (tester) async {
    agent.openStudioFile('a.txt', 'a original');
    await pumpEditor(tester);
    await tester.enterText(find.byKey(studioEditorFieldKey), 'a draft');
    controller(tester).selection = const TextSelection.collapsed(offset: 2);
    agent.openStudioFile('b.txt', 'b original');
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(studioEditorFieldKey), 'b draft');
    agent.selectStudioFile('a.txt');
    await tester.pumpAndSettle();
    expect(controller(tester).text, 'a draft');
    expect(controller(tester).selection.baseOffset, 2);
    expect(saveEnabled(tester), isTrue);
    agent.closeStudioFile('a.txt');
    await tester.pumpAndSettle();
    expect(controller(tester).text, 'b draft');
    expect(saveEnabled(tester), isTrue);
    agent.openStudioFile('a.txt', 'a original');
    await tester.pumpAndSettle();
    expect(controller(tester).text, 'a draft');
    expect(controller(tester).selection.baseOffset, 2);
  });

  testWidgets('external rewrite surfaces conflict and preserves typed bytes', (tester) async {
    agent.openStudioFile('a.txt', 'base');
    await pumpEditor(tester);
    await tester.enterText(find.byKey(studioEditorFieldKey), 'my draft');
    controller(tester).selection = const TextSelection.collapsed(offset: 3);
    agent.openStudioFile('a.txt', 'external version');
    await tester.pumpAndSettle();
    expect(controller(tester).text, 'my draft');
    expect(controller(tester).selection.baseOffset, 3);
    expect(find.textContaining('changed externally'), findsOneWidget);
    expect(saveEnabled(tester), isFalse);
    await tester.tap(find.text('Keep draft'));
    await tester.pumpAndSettle();
    expect(controller(tester).text, 'my draft');
    expect(saveEnabled(tester), isTrue);
    expect(find.textContaining('changed externally'), findsNothing);
  });

  testWidgets('undo after switching tabs changes only that files draft', (tester) async {
    agent.openStudioFile('a.txt', 'a original');
    await pumpEditor(tester);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(find.byKey(studioEditorFieldKey), 'a draft');
    await tester.pump(const Duration(milliseconds: 600));
    agent.openStudioFile('b.txt', 'b original');
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(find.byKey(studioEditorFieldKey), 'b draft');
    await tester.pump(const Duration(milliseconds: 600));
    agent.selectStudioFile('a.txt');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Undo'));
    await tester.pumpAndSettle();
    expect(controller(tester).text, 'a original');
    expect(agent.fileBuffer['b.txt'], 'b draft');
    await tester.tap(find.byTooltip('Redo'));
    await tester.pumpAndSettle();
    expect(controller(tester).text, 'a draft');
  });

  testWidgets('save completion cannot publish old bytes over a newer edit', (tester) async {
    final root = Directory.systemTemp.createTempSync('parallel-studio-save-');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/a.txt').writeAsStringSync('base');
    AppState.I.setSessionWorkspaceFolder(root.path);
    RepoCache.I.bind('owner/repo', '', sessionId: AppState.I.activeSession!.id,
        workspaceFolder: root.path);
    agent.openStudioFile('a.txt', 'base');
    await pumpEditor(tester);
    await tester.enterText(find.byKey(studioEditorFieldKey), 'save snapshot');
    await tester.pump();
    final save = tester.widget<StudioIconButton>(find.ancestor(
        of: find.byTooltip('Save changes'), matching: find.byType(StudioIconButton)));
    save.onPressed!();
    controller(tester).text = 'newer typing';
    await tester.pumpAndSettle();
    expect(controller(tester).text, 'newer typing');
    expect(saveEnabled(tester), isTrue);
    expect(find.textContaining('changed externally'), findsNothing);
    expect(agent.fileBuffer['a.txt'], 'newer typing');
  });

  testWidgets('workspace sync exposes disk conflict without replacing the draft', (tester) async {
    final root = Directory.systemTemp.createTempSync('parallel-studio-conflict-');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File('${root.path}/a.txt')..writeAsStringSync('base');
    AppState.I.setSessionWorkspaceFolder(root.path);
    RepoCache.I.bind('owner/repo', '', sessionId: AppState.I.activeSession!.id,
        workspaceFolder: root.path);
    await tester.runAsync(() => RepoCache.I.sync());
    agent.openStudioFile('a.txt', 'base');
    await pumpEditor(tester);
    await tester.enterText(find.byKey(studioEditorFieldKey), 'draft');
    file.writeAsStringSync('external');
    await tester.runAsync(() => RepoCache.I.sync());
    await tester.pumpAndSettle();
    expect(controller(tester).text, 'draft');
    expect(find.textContaining('changed externally'), findsOneWidget);
    await tester.tap(find.text('Use external'));
    await tester.pumpAndSettle();
    expect(controller(tester).text, 'external');
    expect(saveEnabled(tester), isFalse);
    expect(file.readAsStringSync(), 'external');
  });

  testWidgets('save in flight cannot publish into a replacement repository', (tester) async {
    final root = Directory.systemTemp.createTempSync('parallel-studio-save-owner-');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/a.txt').writeAsStringSync('base');
    final app = AppState.I;
    app.setSessionWorkspaceFolder(root.path);
    app.setRepoForSession(app.activeSession!.id, 'owner/one');
    RepoCache.I.bind('owner/one', '', sessionId: app.activeSession!.id,
        workspaceFolder: root.path);
    agent.openStudioFile('a.txt', 'base');
    await pumpEditor(tester);
    await tester.enterText(find.byKey(studioEditorFieldKey), 'one saved');
    await tester.pump();
    tester.widget<StudioIconButton>(find.ancestor(of: find.byTooltip('Save changes'),
        matching: find.byType(StudioIconButton))).onPressed!();
    app.setRepoForSession(app.activeSession!.id, 'owner/two');
    RepoCache.I.bind('owner/two', '', sessionId: app.activeSession!.id);
    agent.openStudioFile('a.txt', 'two base');
    await tester.pumpAndSettle();
    expect(agent.fileBuffer['a.txt'], 'two base');
    expect(controller(tester).text, 'two base');
    expect(RepoCache.I.hasPending, isFalse);
  });

  testWidgets('same relative path in another binding cannot adopt the previous draft', (tester) async {
    final app = AppState.I;
    app.setRepoForSession(app.activeSession!.id, 'owner/one');
    agent.openStudioFile('a.txt', 'one');
    await pumpEditor(tester);
    await tester.enterText(find.byKey(studioEditorFieldKey), 'one draft');
    app.setRepoForSession(app.activeSession!.id, 'owner/two');
    agent.openStudioFile('a.txt', 'two');
    await tester.pumpAndSettle();
    expect(controller(tester).text, 'two');
    expect(saveEnabled(tester), isFalse);
    await tester.enterText(find.byKey(studioEditorFieldKey), 'two draft');
    app.setRepoForSession(app.activeSession!.id, 'owner/one');
    agent.selectStudioFile('a.txt');
    await tester.pumpAndSettle();
    expect(controller(tester).text, 'one draft');
    expect(saveEnabled(tester), isTrue);
  });
}
