import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_editor.dart';
import 'package:ovid_ai/ui/studio_file_tree.dart';

/// F-036: agent notifications that do not touch Studio state no longer
/// re-run the editor's line/column scan or the file tree build.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    RepoCache.I.unbind();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    for (final p in AgentService.I.studioOpenFiles.toList()) {
      AgentService.I.closeStudioFile(p);
    }
    AgentService.I.fileBuffer.clear();
    AgentService.I.activeFilePath = null;
  });

  tearDown(() {
    AgentService.I.debugPauseScheduleTimerForTest(false);
    RepoCache.I.unbind();
    AppState.resetTestInstance();
  });

  void seedRepo(int files) {
    RepoCache.I.bind('owner/repo', 'tok', branch: 'main', sessionId: 's1');
    RepoCache.I.treePaths
      ..clear()
      ..addAll([for (var i = 0; i < files; i++) 'lib/dir${i % 40}/f$i.dart']);
    RepoCache.I.files.clear();
    RepoCache.I.notifyListeners();
  }

  Future<void> pumpStudio(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(
          body: Row(
            children: [
              SizedBox(width: 260, height: 600, child: StudioFileTree()),
              Expanded(
                child: Column(
                  children: [
                    StudioEditorTabs(),
                    Expanded(child: StudioEditor()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('100 agent notifies: tree and line index built at most once', (
    tester,
  ) async {
    seedRepo(2000);
    AgentService.I.openStudioFile(
      'lib/dir0/f0.dart',
      List.generate(3000, (i) => 'line $i').join('\n'),
    );
    StudioEditorDebug.lineIndexBuilds = 0;
    debugStudioTreeBuilds = 0;
    await pumpStudio(tester);
    expect(StudioEditorDebug.lineIndexBuilds, greaterThan(0));
    expect(debugStudioTreeBuilds, greaterThan(0));

    debugStudioTreeBuilds = 0;
    StudioEditorDebug.lineIndexBuilds = 0;
    for (var i = 0; i < 100; i++) {
      AgentService.I.refreshNow();
      await tester.pump();
    }
    expect(debugStudioTreeBuilds, lessThanOrEqualTo(1));
    expect(StudioEditorDebug.lineIndexBuilds, lessThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an agent rewrite of the open file still reaches the editor', (
    tester,
  ) async {
    AgentService.I.openStudioFile('a.txt', 'before');
    await pumpStudio(tester);
    AgentService.I.fileBuffer['a.txt'] = 'after';
    AgentService.I.refreshNow();
    await tester.pump();
    final field = tester.widget<TextField>(find.byKey(studioEditorFieldKey));
    expect(field.controller!.text, 'after');
  });
}
