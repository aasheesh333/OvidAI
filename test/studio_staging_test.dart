import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/studio_screen.dart';
import 'repo_cache_approval_test.dart' show ApprovalGit;

void main() {
  final cache = RepoCache.I;
  late ApprovalGit git;
  late Directory workspace;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    workspace = Directory.systemTemp.createTempSync('ovid-studio-stage');
    cache.unbind();
    cache.bind('owner/repo', 'token', sessionId: 's1', workspaceFolder: workspace.path);
    File('${workspace.path}/a.sh').writeAsStringSync('same\n');
    cache.files['a.sh'] = 'same\n';
    cache.treePaths.add('a.sh');
    git = ApprovalGit();
    git.entries.add({'path': 'a.sh', 'type': 'blob', 'mode': '100644', 'sha': 'old'});
    git.originals['old'] = 'same\n';
  });
  tearDown(() {
    cache.unbind();
    git.client.close();
    workspace.deleteSync(recursive: true);
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });
  Future<void> open(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pumpAndSettle();
  }
  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.byTooltip('Stage a.sh'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    // Toasts are timed overlays; let success feedback close before reviewing.
    if (!label.contains('deletion') || !File('${workspace.path}/a.sh').existsSync()) {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('real file tree stages unchanged executable mode without disk mutation', (tester) async {
    final diskMode = File('${workspace.path}/a.sh').statSync().mode;
    await open(tester, const SizedBox(width: 320, height: 500, child: StudioFileTree()));
    await choose(tester, 'Stage executable (100755)');
    expect(cache.pendingPaths, ['a.sh']);
    expect(File('${workspace.path}/a.sh').statSync().mode, diskMode);
    await tester.pumpWidget(const SizedBox.shrink());
    await open(tester, StudioCommitDialog(client: git.client));
    await tester.tap(find.text('Review changes'));
    await tester.pumpAndSettle();
    expect(find.textContaining('old mode 100644\nnew mode 100755'), findsOneWidget);
    await tester.tap(find.text('Approve and commit'));
    await tester.pumpAndSettle();
    final tree = git.requests.singleWhere((r) => r.method == 'POST' && r.url.path.endsWith('/trees'));
    expect(jsonDecode(tree.body)['tree'][0]['mode'], '100755');
  });

  testWidgets('staging mode or deletion in review invalidates approval', (tester) async {
    cache.write('a.sh', 'same\n');
    cache.didSaveWorkspaceFile('a.sh', 'same\n');
    await open(tester, StudioCommitDialog(client: git.client));
    await tester.tap(find.text('Review changes'));
    await tester.pumpAndSettle();
    await choose(tester, 'Stage executable (100755)');
    expect(find.text('Approve and commit'), findsNothing);
    await tester.tap(find.text('Review changes'));
    await tester.pumpAndSettle();
    expect(find.text('Approve and commit'), findsOneWidget);
    await choose(tester, 'Stage regular (100644)');
    expect(find.text('Approve and commit'), findsNothing);
    await tester.tap(find.text('Review changes'));
    await tester.pumpAndSettle();
    expect(find.text('Approve and commit'), findsOneWidget);
    File('${workspace.path}/a.sh').deleteSync();
    await choose(tester, 'Stage deletion (already missing)');
    expect(find.text('Approve and commit'), findsNothing);
    expect(find.text('Staged deletion · disk unchanged'), findsOneWidget);
    expect(git.mutations, isEmpty);
    await tester.tap(find.text('Review changes'));
    await tester.pumpAndSettle();
    expect(find.textContaining('deleted file mode 100644'), findsOneWidget);
  });

  testWidgets('missing path absent from tree can be explicitly staged in commit dialog', (tester) async {
    File('${workspace.path}/a.sh').deleteSync();
    cache.files.clear();
    cache.treePaths.clear();
    await open(tester, StudioCommitDialog(client: git.client));
    await tester.tap(find.text('Stage missing file deletion'));
    await tester.pumpAndSettle();
    expect(find.textContaining('does not delete'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Repository-relative path'), 'a.sh');
    await tester.tap(find.text('Stage deletion'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(CheckboxListTile, 'a.sh'), findsOneWidget);
    await tester.tap(find.text('Review changes'));
    await tester.pumpAndSettle();
    expect(find.textContaining('-same\n'), findsOneWidget);
    await tester.tap(find.text('Approve and commit'));
    await tester.pumpAndSettle();
    expect(cache.hasPending, isFalse);
    expect(git.requests.where((r) => r.method == 'PATCH'), hasLength(1));
  });

  testWidgets('tree deletion refuses existing checkout file with visible error', (tester) async {
    await open(tester, const SizedBox(width: 320, height: 500, child: StudioFileTree()));
    await choose(tester, 'Stage deletion (already missing)');
    expect(find.textContaining('already-missing'), findsWidgets);
    expect(File('${workspace.path}/a.sh').readAsStringSync(), 'same\n');
    expect(cache.hasPending, isFalse);
    expect(git.requests, isEmpty);
  });

  testWidgets('new selected path invalidates displayed review', (tester) async {
    cache.write('a.sh', 'same\n');
    await open(tester, StudioCommitDialog(client: git.client));
    await tester.tap(find.text('Review changes'));
    await tester.pumpAndSettle();
    cache.write('b.txt', 'new selected path');
    await tester.pumpAndSettle();
    expect(find.text('Approve and commit'), findsNothing);
    expect(git.mutations, isEmpty);
  });

  testWidgets('file action opened before rebind cannot stage in new owner', (tester) async {
    await open(tester, const SizedBox(width: 320, height: 500, child: StudioFileTree()));
    await tester.tap(find.byTooltip('Stage a.sh'));
    await tester.pumpAndSettle();
    cache.bind('other/repo', 'token', sessionId: 's2');
    cache.files['a.sh'] = 'other owner';
    await tester.tap(find.text('Stage executable (100755)'));
    await tester.pumpAndSettle();
    expect(cache.hasPending, isFalse);
    expect(find.textContaining('binding changed'), findsWidgets);
  });

  testWidgets('missing deletion entry fits phone with keyboard and large text', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final keyboard = ValueNotifier<double>(0);
    addTearDown(keyboard.dispose);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => ValueListenableBuilder<double>(
        valueListenable: keyboard,
        builder: (context, inset, _) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2), viewInsets: EdgeInsets.only(bottom: inset)),
          child: child!,
        ),
      ),
      home: Scaffold(resizeToAvoidBottomInset: false, body: StudioCommitDialog(client: git.client)),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Stage missing file deletion'));
    await tester.tap(find.text('Stage missing file deletion'));
    await tester.pumpAndSettle();
    keyboard.value = 260;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.widgetWithText(TextField, 'Repository-relative path'));
    await tester.enterText(find.widgetWithText(TextField, 'Repository-relative path'), 'missing.txt');
    await tester.ensureVisible(find.text('Stage deletion'));
    await tester.tap(find.text('Stage deletion'));
    await tester.pumpAndSettle();
    expect(cache.pendingPaths, ['missing.txt']);
  });
}
