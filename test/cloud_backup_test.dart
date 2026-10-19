// SE-008 / SE-009: Export & import works from the user's Ovid Cloud history,
// not from whatever the device happened to cache, and restore uploads through
// POST /import/sessions instead of publishing local `restored-` rows.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_backup.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/settings_backup_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/user_error.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ImportCall {
  _ImportCall(this.sessionId, this.title, this.createdAt, this.messages);
  final String? sessionId;
  final String? title;
  final DateTime? createdAt;
  final List<ImportMessage> messages;
}

/// In-memory gateway: keyset pages exactly like the real routes (sessions
/// newest-first with an opaque cursor; messages newest-first, `before` = the
/// oldest id of the previous page) and an import route that dedupes on
/// (session, clientMsgId).
class _FakeRest extends CloudRestClient {
  _FakeRest() : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  final List<SessionDto> sessions = [];
  final Map<String, List<MessageDto>> messages = {};
  final List<String?> sessionCursors = [];
  final Map<String, List<String?>> messageCursors = {};
  final List<_ImportCall> imports = [];
  final Map<String, Set<String>> stored = {};
  CloudApiException? failWith;
  int _created = 0;

  @override
  Future<CloudPage<SessionDto>> listSessions({
    int limit = 50,
    String? cursor,
  }) async {
    if (failWith != null) throw failWith!;
    sessionCursors.add(cursor);
    final start = cursor == null ? 0 : int.parse(cursor);
    final end = (start + limit).clamp(0, sessions.length);
    return CloudPage(
      items: sessions.sublist(start, end),
      nextCursor: end < sessions.length ? '$end' : null,
    );
  }

  @override
  Future<CloudPage<MessageDto>> pageMessages(
    String sessionId, {
    int limit = 50,
    String? before,
  }) async {
    if (failWith != null) throw failWith!;
    messageCursors.putIfAbsent(sessionId, () => []).add(before);
    // Stored oldest-first; served newest-first.
    final all = (messages[sessionId] ?? const <MessageDto>[]).reversed.toList();
    var start = 0;
    if (before != null) {
      start = all.indexWhere((m) => m.id == before) + 1;
    }
    final end = (start + limit).clamp(0, all.length);
    final page = all.sublist(start, end);
    return CloudPage(
      items: page,
      nextCursor: end < all.length ? page.last.id : null,
    );
  }

  @override
  Future<ImportReport> importMessages({
    String? sessionId,
    String? title,
    DateTime? createdAt,
    required List<ImportMessage> messages,
  }) async {
    if (failWith != null) throw failWith!;
    imports.add(_ImportCall(sessionId, title, createdAt, messages));
    expect(messages, isNotEmpty);
    expect(messages.length, lessThanOrEqualTo(500));
    String id;
    if (sessionId != null) {
      if (!stored.containsKey(sessionId)) {
        throw CloudApiException(
          status: 404,
          code: 'not_found',
          message: 'Not found.',
        );
      }
      id = sessionId;
    } else {
      _created++;
      id = '00000000-0000-7000-8000-${_created.toString().padLeft(12, '0')}';
      stored[id] = <String>{};
    }
    var imported = 0;
    var skipped = 0;
    for (final m in messages) {
      if (stored[id]!.add(m.clientMsgId)) {
        imported++;
      } else {
        skipped++;
      }
    }
    return ImportReport(sessionId: id, imported: imported, skipped: skipped);
  }
}

SessionDto _session(int i) => SessionDto(
  id: 'aaaaaaaa-0000-7000-8000-${i.toString().padLeft(12, '0')}',
  title: 'Chat $i',
  mode: 'auto',
  createdAt: DateTime.utc(2026, 1, 1).add(Duration(days: i)),
  updatedAt: DateTime.utc(2026, 1, 1).add(Duration(days: i)),
);

List<MessageDto> _messages(String sessionId, int count, {int offset = 0}) => [
  for (var i = 0; i < count; i++)
    MessageDto(
      id: '$sessionId-m${(i + offset).toString().padLeft(5, '0')}',
      sessionId: sessionId,
      role: i.isEven ? 'user' : 'assistant',
      content: 'message $i',
      createdAt: DateTime.utc(2026, 2, 1).add(Duration(minutes: i)),
    ),
];

void main() {
  late _FakeRest rest;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    rest = _FakeRest();
  });

  group('export (SE-008)', () {
    test('pages ALL sessions and ALL message pages from the server', () async {
      for (var i = 0; i < 230; i++) {
        final s = _session(i);
        rest.sessions.add(s);
        rest.messages[s.id] = _messages(s.id, i == 0 ? 250 : 2);
      }
      // A tool row and a system row are not part of the transcript archive.
      rest.messages[rest.sessions[1].id]!.addAll([
        MessageDto(
          id: 'tool',
          sessionId: rest.sessions[1].id,
          role: 'tool',
          content: '{}',
          createdAt: DateTime.utc(2026, 3, 1),
        ),
        MessageDto(
          id: 'sys',
          sessionId: rest.sessions[1].id,
          role: 'system',
          content: 'context',
          createdAt: DateTime.utc(2026, 3, 1),
        ),
      ]);
      final progress = <CloudBackupProgress>[];

      final snapshot = await CloudBackup(
        rest: rest,
        prefs: prefs,
      ).fetchHistory(onProgress: progress.add);

      // Every session page was requested, following the cursor to the end.
      expect(rest.sessionCursors, [null, '100', '200']);
      expect(snapshot.sessions, hasLength(230));
      // The 250-message chat needed three message pages.
      final big = rest.sessions[0].id;
      expect(rest.messageCursors[big], hasLength(3));
      final bigChat = snapshot.sessions.firstWhere((s) => s.id == big);
      expect(bigChat.messages, hasLength(250));
      // Chronological order, oldest first.
      expect(bigChat.messages.first.content, 'message 0');
      expect(bigChat.messages.last.content, 'message 249');
      expect(snapshot.messageCount, 250 + 229 * 2);
      expect(snapshot.skippedMessages, 2);
      expect(progress, isNotEmpty);
      expect(progress.last.done, progress.last.total);

      // The server snapshot builds a valid v1 archive that restore can read.
      final bytes = await SettingsBackupService().export(snapshot.sessions);
      final staged = await SettingsBackupService().stage(
        bytes,
        Directory.systemTemp,
      );
      try {
        expect(staged.sessions, hasLength(230));
        final total = staged.sessions.fold<int>(
          0,
          (sum, s) => sum + (s['messages'] as List).length,
        );
        expect(total, snapshot.messageCount);
        expect(staged.attachments, isEmpty);
      } finally {
        await staged.dispose();
      }
    });

    test('cancel stops paging with CloudBackupCancelled', () async {
      for (var i = 0; i < 5; i++) {
        final s = _session(i);
        rest.sessions.add(s);
        rest.messages[s.id] = _messages(s.id, 3);
      }
      final cancel = CloudBackupCancelToken();
      await expectLater(
        CloudBackup(rest: rest, prefs: prefs).fetchHistory(
          cancel: cancel,
          onProgress: (p) {
            if (p.done >= 2) cancel.cancel();
          },
        ),
        throwsA(isA<CloudBackupCancelled>()),
      );
      expect(rest.messageCursors.length, lessThan(5));
    });

    test('signed out fails with a human, typed error', () async {
      rest.failWith = CloudApiException(
        status: 401,
        code: 'unauthenticated',
        message: 'Sign in to use Ovid Cloud.',
      );
      Object? caught;
      try {
        await CloudBackup(rest: rest, prefs: prefs).fetchHistory();
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<CloudApiException>());
      expect(UserError.from(caught!).kind, UserErrorKind.unauthorized);
    });
  });

  group('restore (SE-009)', () {
    Map<String, dynamic> archiveSession(
      String id,
      int count, {
      List<Map<String, dynamic>> extra = const [],
    }) => <String, dynamic>{
      'id': id,
      'title': 'Archived $id',
      'createdAt': DateTime.utc(2025, 5, 1).toIso8601String(),
      'messages': [
        for (var i = 0; i < count; i++)
          <String, dynamic>{
            'role': i.isEven ? 'user' : 'assistant',
            'kind': 'text',
            'content': 'archived $i',
            'time': DateTime.utc(
              2025,
              5,
              1,
              0,
              i % 60,
              i ~/ 60,
            ).toIso8601String(),
            'attachments': const <dynamic>[],
          },
        ...extra,
      ],
    };

    test('uploads through /import/sessions with deterministic clientMsgIds '
        'and a re-import never duplicates', () async {
      AppState.resetTestInstance();
      AppState.createForTest();
      addTearDown(AppState.resetTestInstance);
      final before = AppState.I.sessions.map((s) => s.id).toList();
      final archive = [
        archiveSession('1700000000000000', 620),
        archiveSession('local-b', 3),
      ];

      final first = await CloudBackup(
        rest: rest,
        prefs: prefs,
      ).uploadArchiveSessions(archive);

      // 620 messages → 500 + 120: two chunks into ONE server session.
      expect(rest.imports, hasLength(3));
      expect(rest.imports[0].sessionId, isNull);
      expect(rest.imports[0].title, 'Archived 1700000000000000');
      expect(rest.imports[0].createdAt, DateTime.utc(2025, 5, 1));
      expect(rest.imports[0].messages, hasLength(500));
      expect(rest.imports[1].sessionId, isNotNull);
      expect(rest.imports[1].messages, hasLength(120));
      final ids = [
        for (final call in rest.imports)
          for (final m in call.messages) m.clientMsgId,
      ];
      expect(ids.toSet(), hasLength(ids.length));
      for (final id in ids) {
        expect(id, matches(RegExp(r'^[0-9a-f]{64}$')));
      }
      expect(first.chats, 2);
      expect(first.imported, 623);
      expect(first.duplicates, 0);
      expect(rest.stored, hasLength(2));

      // No local `restored-` rows: AppState is untouched.
      expect(AppState.I.sessions.map((s) => s.id).toList(), before);
      expect(
        AppState.I.sessions.where((s) => s.id.startsWith('restored-')),
        isEmpty,
      );

      // Same backup again (fresh service, same prefs): continues into the
      // same server sessions with the same ids → every message skipped.
      final firstCalls = rest.imports.length;
      final second = await CloudBackup(
        rest: rest,
        prefs: prefs,
      ).uploadArchiveSessions(archive);
      final again = rest.imports.sublist(firstCalls);
      expect(again.every((c) => c.sessionId != null), isTrue);
      expect([
        for (final c in again)
          for (final m in c.messages) m.clientMsgId,
      ], ids);
      expect(second.imported, 0);
      expect(second.duplicates, 623);
      expect(rest.stored, hasLength(2));
    });

    test('a deleted continuation session is re-created, not lost', () async {
      final archive = [archiveSession('local-a', 4)];
      await CloudBackup(
        rest: rest,
        prefs: prefs,
      ).uploadArchiveSessions(archive);
      rest.stored.clear(); // the user deleted the restored chat
      final report = await CloudBackup(
        rest: rest,
        prefs: prefs,
      ).uploadArchiveSessions(archive);
      expect(report.imported, 4);
      expect(rest.stored, hasLength(1));
    });

    test('chats already in this account are not uploaded again', () async {
      final existing = _session(1);
      rest.sessions.add(existing);
      final report = await CloudBackup(rest: rest, prefs: prefs)
          .uploadArchiveSessions([
            archiveSession(existing.id, 4),
            archiveSession('local-x', 2),
          ]);
      expect(rest.imports, hasLength(1));
      expect(rest.imports.single.title, 'Archived local-x');
      expect(report.chats, 1);
      expect(report.alreadyInAccount, 1);
    });

    test('reasoning and compacted rows are not uploaded as replies', () async {
      final report = await CloudBackup(rest: rest, prefs: prefs)
          .uploadArchiveSessions([
            archiveSession(
              'local-r',
              2,
              extra: [
                <String, dynamic>{
                  'role': 'assistant',
                  'kind': 'reasoning',
                  'content': 'thinking',
                  'time': DateTime.utc(2025, 5, 2).toIso8601String(),
                  'attachments': const <dynamic>[],
                },
              ],
            ),
          ]);
      expect(rest.imports.single.messages, hasLength(2));
      expect(report.imported, 2);
      expect(report.leftOut, 1);
    });

    test('signed out fails before anything is uploaded', () async {
      rest.failWith = CloudApiException(
        status: 401,
        code: 'unauthenticated',
        message: 'Sign in to use Ovid Cloud.',
      );
      await expectLater(
        CloudBackup(
          rest: rest,
          prefs: prefs,
        ).uploadArchiveSessions([archiveSession('local-a', 2)]),
        throwsA(isA<CloudApiException>()),
      );
      expect(rest.imports, isEmpty);
    });
  });
}
