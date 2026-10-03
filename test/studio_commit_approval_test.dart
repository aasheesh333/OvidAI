import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/ui/studio_screen.dart';
import 'repo_cache_approval_test.dart' show ApprovalGit;

void main() {
  final cache = RepoCache.I;
  late ApprovalGit git;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cache.unbind();
    cache.bind('owner/repo', 'token', sessionId: 's1');
    cache.write('a.txt', 'approved');
    cache.write('b.txt', 'unselected');
    git = ApprovalGit();
  });
  tearDown(() {
    cache.unbind();
    git.client.close();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: StudioCommitDialog(client: git.client)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'review shows exact binding base bytes selection and message before send',
    (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), 'chosen message');
      await tester.tap(find.widgetWithText(CheckboxListTile, 'b.txt'));
      await tester.tap(find.text('Review changes'));
      await tester.pumpAndSettle();
      expect(find.textContaining('owner/repo'), findsWidgets);
      expect(find.textContaining('Base: base'), findsOneWidget);
      expect(find.textContaining('+approved'), findsOneWidget);
      expect(find.textContaining('+unselected'), findsNothing);
      expect(find.textContaining('Message: chosen message'), findsOneWidget);
      expect(git.mutations, isEmpty);
      await tester.tap(find.text('Approve and commit'));
      await tester.pumpAndSettle();
      final commit = git.requests.singleWhere(
        (r) => r.method == 'POST' && r.url.path.endsWith('/commits'),
      );
      expect(jsonDecode(commit.body)['message'], 'chosen message');
      expect(cache.pendingPaths, ['b.txt']);
    },
  );

  for (final action in ['cancel', 'message', 'selection', 'bytes', 'rebind']) {
    testWidgets('$action invalidates approval without remote mutation', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text('Review changes'));
      await tester.pumpAndSettle();
      expect(find.text('Approve and commit'), findsOneWidget);
      switch (action) {
        case 'cancel':
          await tester.tap(find.text('Cancel'));
        case 'message':
          await tester.enterText(find.byType(TextField), 'changed message');
        case 'selection':
          await tester.tap(find.widgetWithText(CheckboxListTile, 'b.txt'));
        case 'bytes':
          cache.write('a.txt', 'later bytes');
        case 'rebind':
          cache.bind('other/repo', 'token', sessionId: 's2');
      }
      await tester.pumpAndSettle();
      expect(find.text('Approve and commit'), findsNothing);
      expect(git.mutations, isEmpty);
    });
  }

  testWidgets('recovery action works with no local drafts after restart', (
    tester,
  ) async {
    git.intercept = (r) => r.method == 'PATCH' ? throw Exception('lost') : null;
    await tester.runAsync(() async {
      await expectLater(
        cache.commitAll('first', client: git.client),
        throwsA(anything),
      );
    });
    cache.unbind();
    cache.bind('owner/repo', 'token', sessionId: 's1');
    git.tip = 'intended';
    git.intercept = null;
    final mutations = git.mutations.length;
    await open(tester);
    expect(find.text('Reconcile pending commit'), findsOneWidget);
    await tester.tap(find.text('Reconcile pending commit'));
    await tester.pumpAndSettle();
    expect(cache.lastCommit?.commitSha, 'intended');
    expect(git.mutations.length, mutations);
  });
}
