import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/commands.dart';
import 'package:ovid_ai/core/compaction/compaction_checkpoint.dart';
import 'package:ovid_ai/core/compaction/compaction_ledger.dart';
import 'package:ovid_ai/core/compaction/compaction_policy.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

/// Lossless compaction: "Compaction must not forget the session's context —
/// what the user gave and what the agent did."
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState app;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('lossless-compaction-');
    SessionLedger.rootOverrideForTest = tmp;
    SessionSearch.dbPathOverrideForTest = '${tmp.path}/search.db';
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux, () {
        try {
          return ffi.DynamicLibrary.open('libsqlite3.so.0');
        } catch (_) {
          return ffi.DynamicLibrary.open(
            '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
          );
        }
      });
    }
    app = AppState.I;
    await app.initialize();
  });

  tearDownAll(() {
    SessionLedger.rootOverrideForTest = null;
    SessionSearch.dbPathOverrideForTest = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    app.sessions.clear();
    app.activeSessionId = null;
    app.contextWindowOverride = 0;
    AgentService.I.compactionSummarizerForTest = null;
  });

  tearDown(() {
    app.contextWindowOverride = 0;
    AgentService.I.compactionSummarizerForTest = null;
  });

  ProviderConfig provider() => ProviderConfig(
    id: 'prov-lossless',
    name: 'Test',
    description: '',
    baseUrl: 'https://x.test',
    models: const ['m'],
    requiresApiKey: false,
  );

  const goal =
      'Build a CSV export feature for the invoices module in lib/invoices/.';
  // Constraints and corrections stated EARLY (turn index → text).
  const constraints = <int, String>{
    3: 'Constraint: never use the http package; use dio instead.',
    10: 'Always write tests under test/invoices/ and run them after edits.',
    25: 'Actually, the delimiter must be a semicolon, not a comma.',
    120: 'Prefer snake_case for every new file name.',
  };
  const pastedConstraint =
      'Do not modify lib/legacy/billing.dart under any circumstances.';

  final touched = <String>{};

  /// One synthetic turn: user message → fs_edit → run_shell → reply.
  void addTurn(ChatSession s, int i) {
    String user;
    if (i == 0) {
      user = goal;
    } else if (constraints.containsKey(i)) {
      user = constraints[i]!;
    } else if (i == 60) {
      // A long paste with an instruction buried inside.
      user =
          'Here is the failing log, please look.\n```\n${'ERROR row parse failed at column 7\n' * 60}```\n'
          'The parser chokes on quoted fields. $pastedConstraint '
          'Thanks for checking this carefully, it matters for the release.';
    } else {
      user = 'Step $i: continue with the next part of the export.';
    }
    s.messages.add(
      Message(
        role: 'user',
        content: user,
        attachments: i == 5
            ? [
                MessageAttachment(
                  name: 'spec.pdf',
                  size: 1024,
                  path: '/ws/uploads/spec.pdf',
                ),
              ]
            : const [],
      ),
    );
    final path = 'lib/invoices/csv_part_$i.dart';
    touched.add(path);
    s.messages.add(
      Message(
        role: 'assistant',
        kind: MsgKind.tool,
        toolName: 'fs_edit',
        toolInput: CompactionLedger.toolInputRecord('fs_edit', {
          'command': i.isEven ? 'create' : 'str_replace',
          'path': path,
          'new_str': 'x' * 300,
        }),
        toolDetail: 'diff $path\n+${'line\n+' * 40}',
        toolState: 'ok',
      ),
    );
    final failing = i == 30;
    s.messages.add(
      Message(
        role: 'assistant',
        kind: MsgKind.tool,
        toolName: 'run_shell',
        toolInput: CompactionLedger.toolInputRecord('run_shell', {
          'command': 'flutter test test/invoices/csv_${i}_test.dart',
        }),
        toolDetail: failing
            ? 'Error: Expected ";" but found ","\n(exit code 1)'
            : '${'ok test passed\n' * 20}(exit code 0)',
        toolState: failing ? 'error' : 'ok',
      ),
    );
    if (i % 40 == 7) {
      final scratch = 'lib/tmp/scratch_$i.dart';
      touched.add(scratch);
      s.messages.add(
        Message(
          role: 'assistant',
          kind: MsgKind.tool,
          toolName: 'run_shell',
          toolInput: CompactionLedger.toolInputRecord('run_shell', {
            'command': 'rm -f $scratch',
          }),
          toolDetail: '(exit code 0)',
          toolState: 'ok',
        ),
      );
    }
    if (i == 50) {
      s.messages.add(
        Message(
          role: 'assistant',
          kind: MsgKind.tool,
          toolName: 'dispatch_agent',
          toolInput: CompactionLedger.toolInputRecord('dispatch_agent', {
            'prompt': 'audit the CSV escaping rules',
          }),
          toolDetail: 'Subagent report: RFC 4180 quoting required',
          toolState: 'ok',
        ),
      );
    }
    s.messages.add(
      Message(role: 'assistant', content: 'Done step $i. ${'detail ' * 30}'),
    );
  }

  ChatSession session(String id, int turns) {
    touched.clear();
    final s = ChatSession(id: id, title: id, model: 'm', mode: 'auto');
    for (var i = 0; i < turns; i++) {
      addTurn(s, i);
    }
    s.todos.addAll([
      {'content': 'Write the CSV encoder', 'status': 'completed'},
      {'content': 'Handle quoted fields', 'status': 'in_progress'},
      {'content': 'Wire the export button', 'status': 'pending'},
    ]);
    app.sessions.insert(0, s);
    return s;
  }

  String modelContext(ChatSession s) => AgentService.I
      .buildRequestMessages(s, 'SYS')
      .map((m) => '${m['content']}')
      .join('\n');

  List<String> visible(ChatSession s) => [
    for (final m in s.messages)
      if (m.kind != MsgKind.compact)
        '${m.role}|${m.kind.name}|${m.content}|${m.toolDetail}',
  ];

  void expectLossless(ChatSession s, {required int lastTurn}) {
    final ctx = modelContext(s);
    expect(ctx, contains(goal), reason: 'original goal kept verbatim');
    for (final c in constraints.entries.where((e) => e.key <= lastTurn)) {
      expect(ctx, contains(c.value), reason: 'constraint #${c.key} verbatim');
    }
    if (lastTurn >= 60) {
      expect(ctx, contains(pastedConstraint), reason: 'buried constraint');
    }
    for (final p in touched) {
      expect(ctx, contains(p), reason: 'touched path $p kept');
    }
    expect(ctx, contains('spec.pdf (/ws/uploads/spec.pdf)'));
    expect(ctx, contains('[~] Handle quoted fields'));
    expect(ctx, contains('[ ] Wire the export button'));
    expect(ctx, contains('Subagent report: RFC 4180 quoting required'));
    expect(ctx, contains('Expected ";" but found ","'));
    // The last K turns replay verbatim after the checkpoint.
    for (var i = lastTurn - 1; i <= lastTurn; i++) {
      expect(ctx, contains('Step $i: continue with the next part'));
    }
    // Tool pairs: the retained tail never starts inside a tool run and
    // the replay never carries orphaned tool-role rows.
    final cut = s.compactedAtCount;
    expect(s.messages[cut].kind, MsgKind.compact);
    expect(CompactionPolicy.splitsToolRun(s.messages, cut + 1), isFalse);
    expect(s.messages[cut + 1].role, 'user', reason: 'cut at a turn start');
    expect(
      AgentService.I
          .buildRequestMessages(s, 'SYS')
          .where((m) => m['role'] == 'tool'),
      isEmpty,
    );
  }

  test('200-turn session: one and three compactions keep every user '
      'instruction, the goal, every path, todos and the last turns', () async {
    final p = provider();
    final s = session('lossless-200', 200);
    app.contextWindowOverride = 32000;
    var calls = 0;
    AgentService.I.compactionSummarizerForTest = (sess, a, b) async {
      calls++;
      return '## Decisions\n- dio over http (user constraint)\n'
          '## Next Steps\n- finish quoted-field handling (round $calls)';
    };
    final before = visible(s);

    final r1 = await AgentService.I.compactNow(s, p);
    expect(r1, contains('Session compacted'));
    expectLossless(s, lastTurn: 199);
    expect(visible(s), before, reason: 'visible transcript unchanged');

    // Two more rounds of work + compaction.
    var turn = 200;
    for (var round = 0; round < 2; round++) {
      for (var k = 0; k < 40; k++) {
        addTurn(s, turn++);
      }
      final r = await AgentService.I.compactNow(s, p);
      expect(r, contains('Session compacted'));
    }
    expectLossless(s, lastTurn: turn - 1);
    final ledger = CompactionLedger.of(s)!;
    expect(ledger.compactions, 3);
    expect(ledger.goal, goal);
    // Cumulative: every folded user message is in the ledger, in order.
    final foldedUsers = s.messages
        .take(s.compactedAtCount)
        .where((m) => m.role == 'user')
        .length;
    expect(ledger.userMessages.length, foldedUsers);
    expect(ledger.userMessages.map((u) => u.seq).toList(), [
      for (var i = 1; i <= foldedUsers; i++) i,
    ]);
    // The narrative is the latest merge, not a summary of a summary.
    expect(s.compactedSummary, contains('round 3'));
    expect(s.compactedSummary, contains('dio over http'));
    // Errors are paired with the fix that resolved them.
    expect(s.compactedSummary, contains('fixed by'));
    // Deleted files are recorded as deleted.
    expect(s.compactedSummary, contains('deleted: lib/tmp/scratch_7.dart'));
    // The row tells the user what was kept.
    final rows = s.messages.where((m) => m.kind == MsgKind.compact).toList();
    expect(rows, hasLength(3));
    expect(rows.last.content, contains('user messages'));
    expect(rows.last.toolDetail, contains('## User instructions'));
  });

  test('the checkpoint uses the structured template', () async {
    final s = session('lossless-template', 30);
    app.contextWindowOverride = 16000;
    AgentService.I.compactionSummarizerForTest = (sess, a, b) async =>
        '## Decisions\n- d\n## Current Work\n- c\n## Next Steps\n- n';
    await AgentService.I.compactNow(s, provider());
    final text = s.compactedSummary!;
    var at = -1;
    for (final h in [
      '## Goal',
      '## User instructions & constraints',
      '## Facts & data the user provided',
      '## Files & artifacts',
      '## Actions taken',
      '## Decisions',
      '## Errors & fixes',
      '## Current state / todos',
      '## Next steps',
    ]) {
      final i = text.indexOf(h);
      expect(i, greaterThan(at), reason: '$h in order');
      at = i;
    }
    expect(text, contains('run_shell: flutter test test/invoices/csv_'));
    expect(text, contains('exit 0'));
  });

  test(
    '/compact <focus> text reaches the summariser and the checkpoint',
    () async {
      final p = provider();
      app.providers.add(p);
      addTearDown(() => app.providers.removeWhere((x) => x.id == p.id));
      final s = session('lossless-focus', 40);
      s.providerId = p.id;
      app.activeSessionId = s.id;
      app.contextWindowOverride = 16000;
      String? seen;
      AgentService.I.compactionSummarizerForTest = (sess, a, b) async {
        seen = 'called';
        return '## Decisions\n- x';
      };
      final res = await CommandService.I.execute(
        '/compact focus on the semicolon delimiter bug',
      );
      expect(res!.feedback, contains('Session compacted'));
      expect(seen, 'called');
      expect(
        s.compactedSummary,
        contains('focus on the semicolon delimiter bug'),
      );
      expect(s.compactedSummary, contains('## Compaction focus'));
      // The real summariser prompt carries the focus too.
      final prompt = CompactionEngine.summarizerUserPrompt(
        replay: '',
        priorNarrative: '',
        ledger: CompactionLedger(),
        focus: 'semicolon',
      );
      expect(prompt, contains('FOCUS (from the user): semicolon'));
    },
  );

  test(
    'summariser failure falls back to the deterministic checkpoint',
    () async {
      for (final mode in ['null', 'throw']) {
        final s = session('lossless-fail-$mode', 60);
        app.contextWindowOverride = 16000;
        AgentService.I.compactionSummarizerForTest = (sess, a, b) async {
          if (mode == 'throw') throw StateError('provider down');
          return null;
        };
        final before = visible(s);
        final status = await AgentService.I.compactNow(s, provider());
        expect(status, contains('transcript only'), reason: mode);
        expect(s.compactedAtCount, greaterThan(0), reason: mode);
        expectLossless(s, lastTurn: 59);
        expect(s.compactedSummary, contains('model summary unavailable'));
        expect(visible(s), before, reason: 'visible transcript unchanged');
      }
    },
  );

  test('a failed summary carries the previous narrative forward', () async {
    final s = session('lossless-carry', 60);
    app.contextWindowOverride = 16000;
    AgentService.I.compactionSummarizerForTest = (sess, a, b) async =>
        '## Decisions\n- chose RFC 4180 quoting because of the subagent audit';
    await AgentService.I.compactNow(s, provider());
    for (var i = 60; i < 100; i++) {
      addTurn(s, i);
    }
    AgentService.I.compactionSummarizerForTest = (sess, a, b) async => null;
    await AgentService.I.compactNow(s, provider());
    expect(s.compactedSummary, contains('chose RFC 4180 quoting'));
    expect(CompactionLedger.of(s)!.compactions, 2);
  });

  test('auto-compaction snaps to a turn boundary and stays lossless', () async {
    final s = session('lossless-auto', 200);
    app.contextWindowOverride = 32000;
    AgentService.I.compactionSummarizerForTest = (sess, a, b) async =>
        '## Decisions\n- auto';
    await AgentService.I.maybeCompactForTest(s, provider());
    expect(s.compactedAtCount, greaterThan(0));
    expectLossless(s, lastTurn: 199);
  });

  test(
    'legacy sessions (LLM-only summary) adopt the ledger losslessly',
    () async {
      final s = session('lossless-legacy', 80);
      // Simulate an old compaction: summary text, no ledger, 40 rows folded.
      s.compactedSummary = '## Primary Request and Intent\n- legacy narrative';
      s.compactedAtCount = 40;
      app.contextWindowOverride = 16000;
      AgentService.I.compactionSummarizerForTest = (sess, a, b) async => null;
      await AgentService.I.compactNow(s, provider());
      final text = s.compactedSummary!;
      expect(text, contains(goal), reason: 'pre-legacy rows re-absorbed');
      expect(text, contains(constraints[3]!));
      expect(text, contains('legacy narrative'), reason: 'old summary carried');
    },
  );

  group('pure units', () {
    test('snapCutoff never lands on a tool card or after a running tool', () {
      final msgs = <Message>[
        Message(role: 'user', content: 'u0'),
        Message(role: 'assistant', kind: MsgKind.tool, toolState: 'ok'),
        Message(role: 'assistant', kind: MsgKind.tool, toolState: 'ok'),
        Message(role: 'assistant', content: 'a'),
        Message(role: 'user', content: 'u1'),
        Message(role: 'assistant', kind: MsgKind.tool, toolState: 'ok'),
        Message(role: 'assistant', kind: MsgKind.tool, toolState: 'running'),
        Message(role: 'assistant', content: 'b'),
      ];
      for (var c = 1; c < msgs.length; c++) {
        final snapped = CompactionPolicy.snapCutoff(msgs, 0, c);
        expect(
          CompactionPolicy.splitsToolRun(msgs, snapped),
          isFalse,
          reason: 'cutoff $c → $snapped',
        );
      }
      // Prefers the user-turn start.
      expect(CompactionPolicy.snapCutoff(msgs, 0, 5), 4);
    });

    test('ledger JSON round-trips and shell ops are parsed', () {
      final l = CompactionLedger()
        ..absorb([
          Message(role: 'user', content: 'goal here'),
          Message(
            role: 'assistant',
            kind: MsgKind.tool,
            toolName: 'run_shell',
            toolInput: CompactionLedger.toolInputRecord('run_shell', {
              'command': 'mv a.txt b.txt && rm -rf build/ && echo hi > out.log',
            }),
            toolDetail: '(exit code 0)',
            toolState: 'ok',
          ),
          Message(
            role: 'assistant',
            kind: MsgKind.tool,
            toolName: 'mcp__github__create_issue',
            toolInput: CompactionLedger.toolInputRecord(
              'mcp__github__create_issue',
              {'repo': 'o/r'},
            ),
            toolDetail: 'created issue #42',
            toolState: 'ok',
          ),
        ]);
      final r = CompactionLedger.fromJson(l.toJson());
      expect(r.goal, 'goal here');
      expect(r.files['a.txt'], contains('deleted'));
      expect(r.files['b.txt'], contains('created'));
      expect(r.files['build/'], contains('deleted'));
      expect(r.files['out.log'], contains('edited'));
      expect(r.actions.last.kind, ActionKind.mcp);
      expect(r.actions.last.note, 'created issue #42');
    });

    test('digest keeps directive sentences verbatim', () {
      final long =
          'Intro sentence about the project. ${'Filler words here. ' * 30}'
          'You must never call the payments API from tests. '
          'See docs/payments/README.md for details.';
      final d = CompactionEngine.digest(long);
      expect(d, contains('Intro sentence about the project.'));
      expect(d, contains('You must never call the payments API from tests.'));
      expect(d, contains('docs/payments/README.md'));
      expect(d.length, lessThan(long.length));
    });

    test('toolInputRecord stores sizes, never file bodies', () {
      final rec = CompactionLedger.toolInputRecord('file_write', {
        'path': 'a.dart',
        'content': 'SECRET BODY' * 100,
      });
      expect(rec, contains('a.dart'));
      expect(rec, contains('content_chars'));
      expect(rec, isNot(contains('SECRET BODY')));
    });
  });
}
