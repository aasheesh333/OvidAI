import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/line_diff.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/ui/studio_screen.dart';

import 'repo_cache_approval_test.dart' show ApprovalGit;
import 'studio_commit_approval_test.dart' show revealInReview;

/// Reconstructs `after` by applying [hunks] to `before`.
String? _apply(String before, List<DiffHunk> hunks) {
  final a = before.endsWith('\n')
      ? before.substring(0, before.length - 1).split('\n')
      : before.split('\n');
  if (before.isEmpty) a.clear();
  final out = <String>[];
  var pos = 0;
  for (final h in hunks) {
    final start = h.oldCount == 0 ? h.oldStart : h.oldStart - 1;
    while (pos < start) {
      out.add(a[pos++]);
    }
    for (final l in h.lines) {
      switch (l.kind) {
        case ' ':
          if (a[pos] != l.text) return null;
          out.add(a[pos++]);
        case '-':
          if (a[pos] != l.text) return null;
          pos++;
        case '+':
          out.add(l.text);
      }
    }
  }
  while (pos < a.length) {
    out.add(a[pos++]);
  }
  return out.join('\n');
}

void main() {
  group('line diff (F-169)', () {
    test('one changed line in 100 lines is one hunk of <= 7 lines', () {
      final before = [for (var i = 0; i < 100; i++) 'line $i'].join('\n');
      final after = before.replaceFirst('line 50', 'line fifty');
      final hunks = unifiedHunks('$before\n', '$after\n');
      expect(hunks, hasLength(1));
      expect(hunks.single.lines.length, lessThanOrEqualTo(8));
      expect(
        hunks.single.lines.where((l) => l.kind != ' ').map((l) => l.kind),
        ['-', '+'],
      );
      expect(hunks.single.header, '@@ -48,7 +48,7 @@');
    });

    test('random edits always reconstruct the new text', () {
      final r = Random(7);
      for (var t = 0; t < 300; t++) {
        List<String> gen() => [
          for (var i = 0; i < r.nextInt(25); i++) 'l${r.nextInt(5)}',
        ];
        final a = gen().join('\n'), b = gen().join('\n');
        final got = _apply(
          a.isEmpty ? '' : '$a\n',
          unifiedHunks(a.isEmpty ? '' : '$a\n', b.isEmpty ? '' : '$b\n'),
        );
        expect(got, b, reason: 'a=$a b=$b');
      }
    });

    test('a missing trailing newline is explicit', () {
      final lines = renderHunks(unifiedHunks('x\n', 'x')).toList();
      expect(lines, contains(r'\ No newline at end of file'));
    });
  });

  group('commit review', () {
    final cache = RepoCache.I;
    late ApprovalGit git;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      cache.unbind();
      cache.bind('owner/repo', 'token', sessionId: 's1');
      git = ApprovalGit();
    });
    tearDown(() {
      cache.unbind();
      git.client.close();
    });

    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(home: StudioCommitDialog(client: git.client)),
      );
      await tester.pumpAndSettle();
    }

    test(
      'CommitApproval.diff for one changed line is one small hunk',
      () async {
        final original = [for (var i = 0; i < 100; i++) 'row $i'].join('\n');
        git.entries.add({
          'path': 'big.txt',
          'type': 'blob',
          'mode': '100644',
          'sha': 'big',
        });
        git.originals['big'] = '$original\n';
        cache.write(
          'big.txt',
          '${original.replaceFirst('row 7', 'row seven')}\n',
        );
        final approval = await cache.prepareCommit('m', client: git.client);
        final f = approval.fileDiffs.single;
        expect(f.lines.where((l) => l.startsWith('@@')), hasLength(1));
        // One hunk header + 3 context + -/+ + 3 context.
        expect(f.lines.length, lessThanOrEqualTo(9));
        expect(f.added, 1);
        expect(f.removed, 1);
        expect(
          identical(approval.fileDiffs, approval.fileDiffs),
          isTrue,
          reason: 'cached on the approval',
        );
      },
    );

    testWidgets('a large file is capped with "Show full diff"', (tester) async {
      cache.write(
        'lock.json',
        [for (var i = 0; i < 1000; i++) 'l$i'].join('\n'),
      );
      await open(tester);
      await tester.tap(find.text('Review changes'));
      await tester.pumpAndSettle();
      final more = find.textContaining('Show full diff');
      await revealInReview(tester, more, delta: 600);
      expect(more, findsOneWidget);
      tester
          .widget<TextButton>(
            find.ancestor(of: more, matching: find.byType(TextButton)),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      expect(find.textContaining('Show full diff'), findsNothing);
    });

    testWidgets('bytes changing after review shows mapped stale copy', (
      tester,
    ) async {
      cache.write('a.txt', 'approved');
      await open(tester);
      await tester.tap(find.text('Review changes'));
      await tester.pumpAndSettle();
      cache.write('a.txt', 'later');
      await tester.pumpAndSettle();
      expect(find.textContaining('changed after you reviewed'), findsOneWidget);
      expect(find.textContaining('Commit preview is stale'), findsNothing);
    });

    testWidgets('unknown outcome offers Check status with a copyable SHA', (
      tester,
    ) async {
      cache.write('a.txt', 'approved');
      git.intercept = (r) =>
          r.method == 'PATCH' ? throw Exception('lost') : null;
      await open(tester);
      await tester.tap(find.text('Review changes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approve and commit'));
      await tester.pumpAndSettle();
      final status = find.text('Check status');
      await revealInReview(tester, status);
      expect(status, findsOneWidget);
      expect(find.textContaining('Intended commit: intended'), findsOneWidget);
      expect(find.textContaining('commit outcome unknown'), findsNothing);
      await tester.tap(find.text('Details'));
      await tester.pump();
      expect(find.textContaining('commit outcome unknown'), findsOneWidget);
    });

    testWidgets('Review is disabled with an empty message', (tester) async {
      cache.write('a.txt', 'approved');
      await open(tester);
      await tester.enterText(find.byType(TextField), '  ');
      await tester.pump();
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Review changes'),
      );
      expect(button.onPressed, isNull);
    });
  });
}
