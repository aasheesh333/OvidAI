// P8 Task 20 — HistoryImportService contract tests.
//
// CloudRestClient is NOT final, so the narrow seam is a subclass that overrides
// `importMessages` (the same pattern test/cloud_session_store_test.dart uses).
// No `ImportTransport` interface is needed; the production service still takes
// the real `CloudRestClient` pinned by the plan.
//
// Fixtures mirror the durable stores:
//   * SessionHistoryRepository legacy mode → prefs StringList rows
//   * SessionHistoryRepository SQLite mode → history_rows authority
//   * <docs>/session-ledgers/*.jsonl (the retired ledger's directory)
//   * a per-account memory root injected through the service's test seam

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/history_import.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/session_history_store.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

/// Minimal path_provider override: the service resolves the retired ledger
/// directory under the documents root (`<docs>/session-ledgers`).
class _Paths extends PathProviderPlatform {
  _Paths(this.directory);
  final Directory directory;

  @override
  Future<String> getApplicationDocumentsPath() async => directory.path;
}

// ---------------------------------------------------------------------------
// Fake REST
// ---------------------------------------------------------------------------

class _Call {
  _Call(this.sessionId, this.title, this.createdAt, this.messages);

  final String? sessionId;
  final String? title;
  final DateTime? createdAt;
  final List<ImportMessage> messages;
}

class _FakeRest extends CloudRestClient {
  _FakeRest() : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  final List<_Call> calls = <_Call>[];

  /// Return true to make the matching call fail like a dropped network.
  bool Function(_Call call)? failWhen;

  /// Return the server-deduped count for the matching call.
  int Function(_Call call)? skippedWhen;

  int _sessionsCreated = 0;

  @override
  Future<ImportReport> importMessages({
    String? sessionId,
    String? title,
    DateTime? createdAt,
    required List<ImportMessage> messages,
  }) async {
    final call = _Call(sessionId, title, createdAt, List<ImportMessage>.of(messages));
    calls.add(call);
    if (failWhen?.call(call) ?? false) {
      throw CloudApiException(
        status: 503,
        code: 'unavailable',
        message: 'network unavailable',
      );
    }
    final target = sessionId ?? 'server-session-${++_sessionsCreated}';
    final skipped = skippedWhen?.call(call) ?? 0;
    return ImportReport(
      sessionId: target,
      imported: messages.length - skipped,
      skipped: skipped,
    );
  }
}

// ---------------------------------------------------------------------------
// Store fixtures
// ---------------------------------------------------------------------------

Map<String, dynamic> _message(String role, String content, int index) =>
    <String, dynamic>{
      'role': role,
      'kind': 'text',
      'content': content,
      'time': DateTime.utc(2026, 1, 1, 0, 0, index).toIso8601String(),
    };

String _sessionJson(
  String id,
  List<Map<String, dynamic>> messages, {
  String? title,
}) =>
    jsonEncode(<String, dynamic>{
      'id': id,
      'title': title ?? 'Chat $id',
      'model': 'm',
      'sandboxId': id,
      'mode': 'auto',
      'messages': messages,
      'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
    });

String _sessionWithCount(String id, int count) => _sessionJson(id, <Map<String, dynamic>>[
      for (var i = 0; i < count; i++)
        _message(i.isEven ? 'user' : 'assistant', 'm$i', i),
    ]);

void main() {
  if (Platform.isLinux) {
    open.overrideFor(
      OperatingSystem.linux,
      () => ffi.DynamicLibrary.open('libsqlite3.so.0'),
    );
  }

  late Directory root;
  late Directory dbDir;
  late Directory ledgerDir;
  late Directory memoryDir;
  late List<SessionHistoryRepository> opened;
  late PathProviderPlatform originalPaths;

  setUp(() {
    root = Directory.systemTemp.createTempSync('history-import-');
    dbDir = Directory('${root.path}/db')..createSync();
    ledgerDir = Directory('${root.path}/session-ledgers')..createSync();
    memoryDir = Directory('${root.path}/memory')..createSync();
    opened = <SessionHistoryRepository>[];
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root);
  });

  tearDown(() async {
    for (final repo in opened) {
      await repo.close();
    }
    PathProviderPlatform.instance = originalPaths;
    root.deleteSync(recursive: true);
  });

  SessionHistoryRepository legacyRepo() {
    final repo = SessionHistoryRepository.forTest();
    opened.add(repo);
    return repo;
  }

  SessionHistoryRepository sqliteRepo() {
    final repo = SessionHistoryRepository.forTest()
      ..enableSqlite(
        path: '${dbDir.path}/history.db',
        backgroundSearch: false,
      );
    opened.add(repo);
    return repo;
  }

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  HistoryImportService service({
    required CloudRestClient rest,
    required SessionHistoryRepository history,
    required SharedPreferences prefs,
    String account = 'guest',
  }) =>
      HistoryImportService(
        rest: rest,
        history: history,
        prefs: prefs,
        account: account,
        memoryRoot: memoryDir,
      );

  // ── plan ─────────────────────────────────────────────────────────────────

  test('plan counts sessions and messages from the SQLite authority', () async {
    final prefs = await prefsWith(const <String, Object>{});
    final repo = sqliteRepo();
    await repo.writeRows(prefs, 'ovid_sessions', <String>[
      _sessionJson('s1', <Map<String, dynamic>>[
        _message('user', 'a', 0),
        _message('assistant', 'b', 1),
        _message('user', 'c', 2),
      ]),
      _sessionJson('s2', <Map<String, dynamic>>[
        _message('user', 'd', 0),
        _message('assistant', 'e', 1),
      ]),
    ]);

    final fake = _FakeRest();
    final plan = await service(rest: fake, history: repo, prefs: prefs).plan();

    expect(plan.sessions, 2);
    expect(plan.messages, 5);
    expect(plan.alreadyImported, isFalse);
    expect(fake.calls, isEmpty, reason: 'plan is read-only');
  });

  test('plan falls back to legacy prefs rows, including the bare-uid namespace',
      () async {
    final prefs = await prefsWith(<String, Object>{
      'ovid_sessions_owner_u1': <String>[
        _sessionJson('s1', <Map<String, dynamic>>[
          _message('user', 'a', 0),
          _message('assistant', 'b', 1),
        ]),
        _sessionJson('s2', <Map<String, dynamic>>[
          _message('user', 'c', 0),
          _message('assistant', 'd', 1),
          _message('user', 'e', 2),
          _message('assistant', 'f', 3),
        ]),
      ],
    });
    final repo = legacyRepo();
    final fake = _FakeRest();

    final bare = await service(
      rest: fake,
      history: repo,
      prefs: prefs,
      account: 'u1',
    ).plan();
    expect(bare.sessions, 2);
    expect(bare.messages, 6);

    // AppState's production account string is `firebase:<uid>`. Its encoded
    // namespace is absent here, so the bare-uid fallback must be found.
    final firebase = await service(
      rest: fake,
      history: repo,
      prefs: prefs,
      account: 'firebase:u1',
    ).plan();
    expect(firebase.sessions, 2);
    expect(firebase.messages, 6);
  });

  test('plan is read-only: no network calls and no preference writes', () async {
    final prefs = await prefsWith(<String, Object>{
      'ovid_sessions': <String>[
        _sessionJson('s1', <Map<String, dynamic>>[_message('user', 'a', 0)]),
      ],
      'unrelated': 'keep',
    });
    final beforeKeys = prefs.getKeys().toSet();
    final repo = legacyRepo();
    final fake = _FakeRest();

    await service(rest: fake, history: repo, prefs: prefs).plan();

    expect(fake.calls, isEmpty);
    expect(prefs.getKeys().toSet(), beforeKeys);
    expect(prefs.getString('unrelated'), 'keep');
    expect(prefs.getString('ovid_cloud_import_progress_guest'), isNull);
    expect(prefs.get('ovid_cloud_import_done_guest'), isNull);
  });

  // ── consent / short-circuit ──────────────────────────────────────────────

  test('run without consent performs zero network calls and reports the skip',
      () async {
    final prefs = await prefsWith(<String, Object>{
      'ovid_sessions': <String>[
        _sessionJson('s1', <Map<String, dynamic>>[_message('user', 'a', 0)]),
      ],
    });
    final repo = legacyRepo();
    final fake = _FakeRest();
    final stages = <String>[];

    final result = await service(rest: fake, history: repo, prefs: prefs).run(
      (stage, progress) => stages.add(stage),
      consent: false,
    );

    expect(fake.calls, isEmpty);
    expect(result.imported, 0);
    expect(result.skipped, 0);
    expect(result.failedSessionKeys, isEmpty);
    expect(stages, contains(HistoryImportService.stageNoConsent));
    expect(prefs.getString('ovid_cloud_import_progress_guest'), isNull);
    expect(prefs.get('ovid_cloud_import_done_guest'), isNull);
  });

  test('alreadyImported short-circuits run with no network', () async {
    final prefs = await prefsWith(<String, Object>{
      'ovid_sessions': <String>[
        _sessionJson('s1', <Map<String, dynamic>>[_message('user', 'a', 0)]),
      ],
      'ovid_cloud_import_done_u1': true,
    });
    final repo = legacyRepo();
    final fake = _FakeRest();
    final svc = service(
      rest: fake,
      history: repo,
      prefs: prefs,
      account: 'firebase:u1',
    );

    expect((await svc.plan()).alreadyImported, isTrue);

    final stages = <String>[];
    final result = await svc.run(
      (stage, progress) => stages.add(stage),
      consent: true,
    );
    expect(fake.calls, isEmpty);
    expect(result.imported, 0);
    expect(result.skipped, 0);
    expect(result.failedSessionKeys, isEmpty);
    expect(stages, contains(HistoryImportService.stageAlreadyImported));
  });

  // ── chunking / resume / idempotency ──────────────────────────────────────

  test('chunks 1,201 messages into 500/500/201 in one server session', () async {
    final prefs = await prefsWith(<String, Object>{
      'ovid_sessions': <String>[_sessionWithCount('s1', 1201)],
    });
    final repo = legacyRepo();
    final fake = _FakeRest();

    final result = await service(rest: fake, history: repo, prefs: prefs)
        .run((stage, progress) {}, consent: true);

    expect(fake.calls.map((c) => c.messages.length), <int>[500, 500, 201]);
    expect(fake.calls[0].sessionId, isNull);
    expect(fake.calls[0].title, 'Chat s1');
    expect(fake.calls[0].createdAt, DateTime.utc(2026, 1, 1));
    expect(fake.calls[1].sessionId, 'server-session-1');
    expect(fake.calls[2].sessionId, 'server-session-1');
    expect(fake.calls[1].title, isNull);
    expect(fake.calls[1].createdAt, isNull);
    expect(result.imported, 1201);
    expect(result.skipped, 0);
    expect(result.failedSessionKeys, isEmpty);
  });

  test('failure at chunk 3 persists progress; a fresh service resumes at chunk 4',
      () async {
    final prefs = await prefsWith(<String, Object>{
      'ovid_sessions': <String>[_sessionWithCount('s1', 5000)],
    });
    final repo = legacyRepo();
    final fake = _FakeRest()..failWhen = (call) => call.messages.first.content == 'm1000';

    final firstResult =
        await service(rest: fake, history: repo, prefs: prefs).run(
      (stage, progress) {},
      consent: true,
    );

    expect(firstResult.failedSessionKeys, <String>['s1']);
    expect(firstResult.imported, 1000, reason: 'chunks 1-2 landed');
    expect(fake.calls.map((c) => c.messages.length), <int>[500, 500, 500]);
    expect(fake.calls.last.messages.first.content, 'm1000');

    final marker = jsonDecode(
      prefs.getString('ovid_cloud_import_progress_guest')!,
    ) as Map<String, dynamic>;
    final entry = marker['s1'] as Map<String, dynamic>;
    expect(entry['completed'], 2);
    expect(entry['nextChunk'], 3);
    expect(entry['sessionId'], 'server-session-1');
    expect(prefs.get('ovid_cloud_import_done_guest'), isNull,
        reason: 'a partial run must not set the one-time marker');

    // A NEW service instance models the next process start. The network is
    // back; the same durable prefs must resume at chunk 4 (m1500).
    fake.failWhen = null;
    final before = fake.calls.length;
    final resumedResult =
        await service(rest: fake, history: repo, prefs: prefs).run(
      (stage, progress) {},
      consent: true,
    );
    final resumedCalls = fake.calls.sublist(before);

    expect(resumedCalls, hasLength(7), reason: 'chunks 4-10');
    expect(resumedCalls.first.messages.first.content, 'm1500');
    expect(resumedCalls.every((c) => c.sessionId == 'server-session-1'), isTrue);
    expect(resumedResult.failedSessionKeys, isEmpty);
    expect(resumedResult.imported, 3500);
    expect(prefs.get('ovid_cloud_import_done_guest'), isTrue);
  });

  test('clientMsgIds are deterministic across runs', () async {
    final prefs = await prefsWith(<String, Object>{
      'ovid_sessions': <String>[
        _sessionJson('s1', <Map<String, dynamic>>[
          _message('user', 'hello', 0),
          _message('assistant', 'hi', 1),
          _message('user', 'again', 2),
        ]),
      ],
    });
    final repo = legacyRepo();
    final fake = _FakeRest();

    await service(rest: fake, history: repo, prefs: prefs)
        .run((stage, progress) {}, consent: true);
    final firstIds = <String>[
      for (final call in fake.calls)
        for (final message in call.messages) message.clientMsgId,
    ];

    // Simulate a lost marker (reinstall / cleared prefs): the same local
    // messages must produce the same ids so the server dedupes them.
    await prefs.remove('ovid_cloud_import_progress_guest');
    await prefs.remove('ovid_cloud_import_done_guest');
    fake.calls.clear();

    await service(rest: fake, history: repo, prefs: prefs)
        .run((stage, progress) {}, consent: true);
    final secondIds = <String>[
      for (final call in fake.calls)
        for (final message in call.messages) message.clientMsgId,
    ];

    expect(firstIds, hasLength(3));
    expect(secondIds, firstIds);
    expect(firstIds.toSet(), hasLength(3));
    expect(
      firstIds.every((id) => RegExp(r'^[0-9a-f]{64}$').hasMatch(id)),
      isTrue,
      reason: 'sha256 hex is exactly the server 64-char limit',
    );
  });

  // ── ledger / memory / roles / failures ───────────────────────────────────

  test('ledger and memory stages report the missing endpoint and are counted',
      () async {
    File('${ledgerDir.path}/s1.jsonl').writeAsStringSync(
      '{"seq":1,"kind":"turn_start"}\n{"seq":2,"kind":"turn_end"}\n',
    );
    File('${memoryDir.path}/MEMORY.md').writeAsStringSync('remember');
    File('${memoryDir.path}/notes.md').writeAsStringSync('note');
    File('${memoryDir.path}/ignored.txt').writeAsStringSync('not markdown');

    final prefs = await prefsWith(<String, Object>{
      'ovid_sessions': <String>[
        _sessionJson('s1', <Map<String, dynamic>>[_message('user', 'a', 0)]),
      ],
    });
    final repo = legacyRepo();
    final fake = _FakeRest();
    final stages = <String>[];

    final result = await service(rest: fake, history: repo, prefs: prefs)
        .run((stage, progress) => stages.add(stage), consent: true);

    expect(fake.calls, hasLength(1), reason: 'transcripts only');
    expect(stages, contains(HistoryImportService.stageLedger));
    expect(stages, contains(HistoryImportService.stageMemory));
    expect(
      stages.where((s) => s == HistoryImportService.skippedEndpointNotLive),
      hasLength(2),
      reason: 'one explicit skip for the ledger and one for memory',
    );
    expect(result.imported, 1);
    expect(result.skipped, 4, reason: '2 ledger events + 2 Markdown files');
  });

  test('roles map to the server enum; unknown roles are skipped and counted',
      () async {
    final prefs = await prefsWith(<String, Object>{
      'ovid_sessions': <String>[
        _sessionJson('s1', <Map<String, dynamic>>[
          _message('user', 'u', 0),
          _message('assistant', 'a', 1),
          _message('system', 's', 2),
          _message('tool', 't', 3),
          _message('developer', 'd', 4),
          _message('function', 'f', 5),
        ]),
      ],
    });
    final repo = legacyRepo();
    final fake = _FakeRest();
    final svc = service(rest: fake, history: repo, prefs: prefs);

    // The plan previews every stored message; run reports the two it cannot
    // represent as skipped.
    expect((await svc.plan()).messages, 6);

    final result = await svc.run((stage, progress) {}, consent: true);
    final sent = <ImportMessage>[
      for (final call in fake.calls) ...call.messages,
    ];
    expect(sent.map((m) => m.role), <String>['user', 'assistant', 'system', 'tool']);
    expect(result.imported, 4);
    expect(result.skipped, 2);
    expect(result.failedSessionKeys, isEmpty);
  });

  test('a mid-way failure lists only that session and retries its last chunk',
      () async {
    final prefs = await prefsWith(<String, Object>{
      'ovid_sessions': <String>[
        _sessionJson('ok', <Map<String, dynamic>>[
          _message('user', 'ok-0', 0),
          _message('assistant', 'ok-1', 1),
        ]),
        _sessionJson('bad', <Map<String, dynamic>>[
          _message('user', 'bad-0', 0),
          _message('assistant', 'bad-1', 1),
        ]),
      ],
    });
    final repo = legacyRepo();
    final fake = _FakeRest()..failWhen = (call) => call.messages.first.content == 'bad-0';
    final svc = service(rest: fake, history: repo, prefs: prefs);

    final first = await svc.run((stage, progress) {}, consent: true);
    expect(first.failedSessionKeys, <String>['bad']);
    expect(first.imported, 2, reason: 'the healthy session still imported');
    expect(prefs.get('ovid_cloud_import_done_guest'), isNull);

    final marker = jsonDecode(
      prefs.getString('ovid_cloud_import_progress_guest')!,
    ) as Map<String, dynamic>;
    final bad = marker['bad'] as Map<String, dynamic>;
    expect(bad['completed'], 0);
    expect(bad['nextChunk'], 0, reason: 'a last-chunk failure is retried');

    // The completed session is not sent again; only the failed one retries.
    fake.failWhen = null;
    final before = fake.calls.length;
    final second = await svc.run((stage, progress) {}, consent: true);
    final retried = fake.calls.sublist(before);
    expect(retried, hasLength(1));
    expect(retried.single.messages.first.content, 'bad-0');
    expect(second.imported, 2);
    expect(second.failedSessionKeys, isEmpty);
    expect(prefs.get('ovid_cloud_import_done_guest'), isTrue);
  });

  test('server-side skipped counts are surfaced, not treated as errors',
      () async {
    final prefs = await prefsWith(<String, Object>{
      'ovid_sessions': <String>[
        _sessionJson('s1', <Map<String, dynamic>>[
          _message('user', 'a', 0),
          _message('assistant', 'b', 1),
        ]),
      ],
    });
    final repo = legacyRepo();
    final fake = _FakeRest()
      ..skippedWhen = (call) => call.messages.length;

    final result = await service(rest: fake, history: repo, prefs: prefs)
        .run((stage, progress) {}, consent: true);

    expect(result.imported, 0);
    expect(result.skipped, 2);
    expect(result.failedSessionKeys, isEmpty);
    expect(prefs.get('ovid_cloud_import_done_guest'), isTrue);
  });
}
