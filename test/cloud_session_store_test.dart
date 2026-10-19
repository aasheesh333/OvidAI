// P8 Task 9 — CloudSessionStore (reconciliation, offline cache, prompt outbox).
//
// Contract anchors:
//   - POST /sessions                 → SessionDto (create-on-first-send)
//   - GET  /sessions?limit&cursor    → keyset page of SessionDto
//   - DELETE /sessions/:id           → 204 (soft delete; a tombstone hides
//     the row locally until the server confirms it is gone)
//   - GET  /sessions/:id/messages    → NEWEST-FIRST page of MessageDto
//   - POST /sessions/:id/messages    → 202 {runId,userMessageId,status}
//     (clientMsgId is the Task 4 idempotency key: a replay returns the
//      ORIGINAL runId/userMessageId and never creates a second run)
//   - ConnectionService.status / WsMultiplexer.linkState → offline
//   - SharedPreferences `ovid_cloud_session_ids` (local→server map) and
//     `ovid_cloud_outbox` (FIFO JSON list) survive process death. The outbox
//     key is ACCOUNT-SCOPED (P0 privacy): each account owns its queue; the
//     plain key is the guest queue and the legacy pre-scoping form.
//   - SessionHistoryRepository is the offline READ CACHE (spec §12).
//
// Review Focus #3 (plan): an offline prompt composed before process death
// MUST still be in the outbox when a NEW store instance is built over the
// same prefs.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/event_projection.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/connection_service.dart';
import 'package:ovid_ai/core/session_history_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Fake REST — records the wire, returns contract-shaped answers, and models
// Task 4's clientMsgId replay semantics.
// ---------------------------------------------------------------------------

class FakeStoreRest extends CloudRestClient {
  FakeStoreRest()
      : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  int createCalls = 0;
  final List<
      ({
        String sessionId,
        String content,
        List<String> attachmentIds,
        String? clientMsgId,
        int? maxOutputTokens,
      })> sent = [];
  final Map<String, SendMessageResponse> responsesByClientMsgId =
      <String, SendMessageResponse>{};
  final Map<String, CloudApiException> sendErrors =
      <String, CloudApiException>{};

  final List<({String sessionId, String? before, int limit})> pageCalls =
      <({String sessionId, String? before, int limit})>[];
  final List<String> sessionCursors = <String>[];
  List<CloudPage<SessionDto>> sessionPages = const [];
  Map<String, List<MessageDto>> messagesBySession =
      const <String, List<MessageDto>>{};

  /// DELETE /sessions/:id wire log.
  final List<String> deleteCalls = <String>[];

  /// id → error thrown on the NEXT deleteSession. Cleared when thrown, so a
  /// retry succeeds — unless [stickyDeleteErrors] (a persistently failing
  /// delete). Models a transient 5xx / offline failure.
  final Map<String, CloudApiException> deleteErrors =
      <String, CloudApiException>{};
  bool stickyDeleteErrors = false;

  @override
  Future<void> deleteSession(String id) async {
    deleteCalls.add(id);
    final error = deleteErrors[id];
    if (error != null) {
      if (!stickyDeleteErrors) deleteErrors.remove(id);
      throw error;
    }
    // Server realism: a deleted session disappears from later list pages.
    sessionPages = <CloudPage<SessionDto>>[
      for (final page in sessionPages)
        CloudPage<SessionDto>(
          items: <SessionDto>[
            for (final dto in page.items)
              if (dto.id != id) dto,
          ],
          nextCursor: page.nextCursor,
        ),
    ];
  }

  /// Titles every createSession carried (CH-013).
  final List<String?> createdTitles = <String?>[];

  /// Title PATCHes (the CH-013 heal), in order.
  final List<({String id, String? title})> titlePatches =
      <({String id, String? title})>[];

  @override
  Future<SessionDto> patchSession(String id, {String? title, String? mode}) async {
    titlePatches.add((id: id, title: title));
    return _dtoFor(id, title);
  }

  static SessionDto _dtoFor(String id, String? title) => SessionDto(
        id: id,
        title: title,
        mode: 'auto',
        createdAt: DateTime.utc(2026, 10, 17),
        updatedAt: DateTime.utc(2026, 10, 17),
      );

  /// Attachment wire log: (session, name) per create, bytes per upload.
  final List<({String sessionId, String name})> attachmentCreates =
      <({String sessionId, String name})>[];
  final List<List<int>> uploads = <List<int>>[];

  @override
  Future<AttachmentUpload> createAttachment(String sessionId,
      {required String name, required int size}) async {
    attachmentCreates.add((sessionId: sessionId, name: name));
    return AttachmentUpload(
      attachmentId: '00000000-0000-4000-8000-00000000000${attachmentCreates.length}',
      uploadUrl: 'https://upload.test/${attachmentCreates.length}',
      path: 'uploads/$name',
      expiresAt: DateTime.utc(2026, 10, 17, 1),
    );
  }

  @override
  Future<void> uploadAttachmentBytes(AttachmentUpload upload, List<int> bytes,
      {Duration? timeout}) async {
    uploads.add(bytes);
  }

  /// One-shot non-HTTP failure for the NEXT send (a DNS failure, a socket
  /// reset — CH-012).
  Object? nextSendThrow;

  /// Every turn-options payload that reached the wire, in order.
  final List<CloudTurnOptions> turns = <CloudTurnOptions>[];

  @override
  Future<SessionDto> createSession({String? title}) async {
    createdTitles.add(title);
    createCalls++;
    final id = 'srv-created-$createCalls';
    return SessionDto(
      id: id,
      title: title,
      mode: 'auto',
      createdAt: DateTime.utc(2026, 10, 17),
      updatedAt: DateTime.utc(2026, 10, 17),
    );
  }

  @override
  Future<CloudPage<SessionDto>> listSessions(
      {int limit = 50, String? cursor}) async {
    sessionCursors.add(cursor ?? '');
    if (sessionPages.isEmpty) {
      return const CloudPage<SessionDto>(items: [], nextCursor: null);
    }
    final index = cursor == null ? 0 : int.parse(cursor);
    return sessionPages[index];
  }

  @override
  Future<CloudPage<MessageDto>> pageMessages(
    String sessionId, {
    int limit = 50,
    String? before,
  }) async {
    pageCalls.add((sessionId: sessionId, before: before, limit: limit));
    return CloudPage<MessageDto>(
      items: messagesBySession[sessionId] ?? const <MessageDto>[],
      nextCursor: null,
    );
  }

  CloudTurnOptions lastTurn = CloudTurnOptions.none;

  @override
  Future<SendMessageResponse> sendMessage(
    String sessionId,
    String content, {
    List<String> attachmentIds = const [],
    String? clientMsgId,
    int? maxOutputTokens,
    CloudTurnOptions turn = CloudTurnOptions.none,
  }) async {
    lastTurn = turn;
    final thrown = nextSendThrow;
    if (thrown != null) {
      nextSendThrow = null;
      throw thrown;
    }
    final error = sendErrors[content];
    if (error != null) throw error;
    turns.add(turn);
    final key = clientMsgId ?? '';
    final prior = responsesByClientMsgId[key];
    if (prior != null) {
      // Task 4 replay: the original run/user message, no second run row.
      return prior;
    }
    final n = responsesByClientMsgId.length + 1;
    final response = SendMessageResponse(
      runId: 'run-$n',
      userMessageId: 'msg-$n',
      status: 'queued',
    );
    responsesByClientMsgId[key] = response;
    sent.add((
      sessionId: sessionId,
      content: content,
      attachmentIds: attachmentIds,
      clientMsgId: clientMsgId,
      maxOutputTokens: maxOutputTokens,
    ));
    return response;
  }
}

// ---------------------------------------------------------------------------
// Fake socket / sink / harness
// ---------------------------------------------------------------------------

class _FakeSocket implements CloudSocket {
  final List<String> sent = <String>[];
  final StreamController<Object> _frames =
      StreamController<Object>.broadcast();
  final StreamController<void> _closed = StreamController<void>.broadcast();

  @override
  Stream<Object> get frames => _frames.stream;

  @override
  Stream<void> get closed => _closed.stream;

  @override
  int? get closeCode => null;

  @override
  void sendText(String frame) => sent.add(frame);

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_closed.isClosed) await _closed.close();
  }
}

class _RecordingSink implements CloudTranscriptSink {
  List<Message>? seeded;
  String? seededCursor;
  final List<List<Message>> prepended = <List<Message>>[];
  final List<({String sessionId, String userMessageId, String content})>
      sentUser = <({String sessionId, String userMessageId, String content})>[];

  @override
  void seedTranscript(
      String serverSessionId, List<Message> messages, String? cursor) {
    seeded = messages;
    seededCursor = cursor;
  }

  @override
  void prependTranscript(String serverSessionId, List<Message> messages) {
    prepended.add(messages);
  }

  final List<({String local, String server})> mapped =
      <({String local, String server})>[];

  @override
  void outboxDelivered(String serverSessionId, OutboxEntry entry,
      SendMessageResponse response) {
    sentUser.add((
      sessionId: serverSessionId,
      userMessageId: response.userMessageId,
      content: entry.content,
    ));
  }

  @override
  void sessionMapped(String localSessionId, String serverSessionId) {
    mapped.add((local: localSessionId, server: serverSessionId));
  }
}

class _Harness {
  _Harness(
    this.rest,
    this.prefs,
    this.connection,
    this.ws,
    this.store,
    this.sockets,
  );

  final FakeStoreRest rest;
  final SharedPreferences prefs;
  final ConnectionService connection;
  final WsMultiplexer ws;
  final CloudSessionStore store;
  final List<_FakeSocket> sockets;

  _FakeSocket get socket => sockets.last;
}

Future<_Harness> _buildStore({
  bool online = true,
  FakeStoreRest? rest,
  Map<String, String> idMap = const <String, String>{},
  List<String> knownServerIds = const <String>[],
  List<OutboxEntry> outbox = const <OutboxEntry>[],
}) async {
  final prefs = await SharedPreferences.getInstance();
  if (idMap.isNotEmpty) {
    await prefs.setString(CloudSessionStore.idMapKey, jsonEncode(idMap));
  }
  if (knownServerIds.isNotEmpty) {
    await prefs.setString(
        CloudSessionStore.knownServerIdsKey, jsonEncode(knownServerIds));
  }
  if (outbox.isNotEmpty) {
    await prefs.setString(CloudSessionStore.outboxKey,
        jsonEncode([for (final entry in outbox) entry.toJson()]));
  }

  final connection = ConnectionService.forTest(
    status: online ? ConnectionStatus.online : ConnectionStatus.offline,
  );
  final sockets = <_FakeSocket>[];
  final ws = WsMultiplexer(
    mintTicket: () async => 'ticket',
    socketFactory: (Uri url) async {
      final socket = _FakeSocket();
      sockets.add(socket);
      return socket;
    },
    prefs: prefs,
    heartbeatInterval: const Duration(hours: 1),
    pongTimeout: const Duration(hours: 1),
    jitterMs: () => 0,
  );
  if (online) {
    await ws.connectIfNeeded();
    await pumpEventQueue();
  }

  final fakeRest = rest ?? FakeStoreRest();
  final store = CloudSessionStore(
    rest: fakeRest,
    cache: SessionHistoryRepository.I,
    prefs: prefs,
    connection: connection,
    ws: ws,
    // Tests drive the flush by hand; no real backoff timers.
    autoRetry: false,
  );
  await store.ready;
  return _Harness(fakeRest, prefs, connection, ws, store, sockets);
}

SessionDto _dto(String id, String? title) => SessionDto(
      id: id,
      title: title,
      mode: 'auto',
      createdAt: DateTime.utc(2026, 10, 1),
      updatedAt: DateTime.utc(2026, 10, 17),
    );

MessageDto _msg(String id, String role, String content, {int minute = 0}) =>
    MessageDto(
      id: id,
      sessionId: 'srv-1',
      role: role,
      content: content,
      createdAt: DateTime.utc(2026, 10, 17, 12, minute),
    );

CloudSessionEvent _event(String type, Map<String, dynamic> payload,
        {required String seq}) =>
    CloudSessionEvent.fromJson(<String, dynamic>{
      'sessionId': 'srv-1',
      'seq': seq,
      'type': type,
      'payload': payload,
      'ts': '2026-10-17T12:00:00.000Z',
    });

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    AppState.resetTestInstance();
    AppState.createForTest();
  });

  tearDown(() async {
    AppState.resetTestInstance();
  });

  group('ensureServerSession', () {
    test('creates once; the second call returns the mapped id without a POST',
        () async {
      final h = await _buildStore();
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      final first = await h.store.ensureServerSession('local-1', title: 'Hi');
      final second = await h.store.ensureServerSession('local-1');

      expect(first, 'srv-created-1');
      expect(second, first);
      expect(h.rest.createCalls, 1,
          reason: 'create-on-first-send must be idempotent');
      expect(h.store.serverIdFor('local-1'), first);

      // A new process over the same prefs sees the persisted map.
      final reloaded = CloudSessionStore(
        rest: h.rest,
        cache: SessionHistoryRepository.I,
        prefs: h.prefs,
        connection: h.connection,
        ws: h.ws,
      );
      await reloaded.ready;
      expect(reloaded.serverIdFor('local-1'), first);
      reloaded.dispose();
    });
  });

  group('refreshSessions', () {
    test('pages the server list, creates ChatSessions, and preserves the '
        'local→server map', () async {
      final h = await _buildStore(
        idMap: <String, String>{'local-1': 'srv-2'},
      );
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      AppState.I.sessions.add(
        ChatSession(id: 'local-1', title: 'Local', model: 'm'),
      );
      h.rest.sessionPages = <CloudPage<SessionDto>>[
        CloudPage<SessionDto>(
          items: <SessionDto>[_dto('srv-1', 'One'), _dto('srv-2', 'Server Two')],
          nextCursor: '1',
        ),
        CloudPage<SessionDto>(
          items: <SessionDto>[_dto('srv-3', 'Three')],
          nextCursor: null,
        ),
      ];

      await h.store.refreshSessions();

      expect(h.rest.sessionCursors, <String>['', '1'],
          reason: 'both keyset pages must be walked');
      expect(AppState.I.sessionById('srv-1')?.title, 'One');
      expect(AppState.I.sessionById('srv-3')?.title, 'Three');
      // The mapped server session is the LOCAL row, never a duplicate.
      expect(AppState.I.sessionById('srv-2'), isNull);
      expect(AppState.I.sessionById('local-1')?.title, 'Server Two');
      expect(h.store.serverIdFor('local-1'), 'srv-2');
    });
  });

  group('deleteServerSession (tombstones)', () {
    test('a mapped chat: DELETEs the server id, clears the map, no tombstone',
        () async {
      final h = await _buildStore(
        idMap: <String, String>{'local-1': 'srv-9'},
        knownServerIds: const <String>['srv-native'],
      );
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      await h.store.deleteServerSession('local-1');
      // A server-native row (ChatSession.id IS the server id) resolves
      // through the known-server set the same way.
      await h.store.deleteServerSession('srv-native');

      expect(h.rest.deleteCalls, <String>['srv-9', 'srv-native']);
      expect(h.store.serverIdFor('local-1'), isNull,
          reason: 'the id map entry must not outlive the chat');
      expect(h.store.isTombstoned('srv-9'), isFalse,
          reason: 'a confirmed delete clears the tombstone');
      expect(h.store.isTombstoned('srv-native'), isFalse);
    });

    test('a never-synced local chat: no DELETE, nothing tombstoned',
        () async {
      final h = await _buildStore();
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      await h.store.deleteServerSession('local-only');

      expect(h.rest.deleteCalls, isEmpty,
          reason: 'a chat that never sent has no server copy');
      expect(h.store.isTombstoned('local-only'), isFalse);
    });

    test('an offline delete keeps the tombstone; refreshSessions hides the '
        'row and retries the DELETE', () async {
      final h = await _buildStore(
        idMap: <String, String>{'local-1': 'srv-9'},
      );
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      // The DELETE never reaches the server (transient 5xx).
      h.rest.deleteErrors['srv-9'] = CloudApiException(
        status: 503,
        code: 'unavailable',
        message: 'Cloud is briefly unavailable.',
      );
      await h.store.deleteServerSession('local-1');
      expect(h.rest.deleteCalls, <String>['srv-9']);
      expect(h.store.isTombstoned('srv-9'), isTrue);
      expect(h.store.serverIdFor('local-1'), isNull);

      // The server still lists the row — the refresh must hide it (the
      // offline-delete contract) and re-fire the DELETE, which now lands.
      h.rest.sessionPages = <CloudPage<SessionDto>>[
        CloudPage<SessionDto>(
          items: <SessionDto>[_dto('srv-9', 'Back'), _dto('srv-8', 'Alive')],
          nextCursor: null,
        ),
      ];
      await h.store.refreshSessions();

      expect(AppState.I.sessionById('srv-9'), isNull,
          reason: 'a tombstoned row must not resurrect locally');
      expect(AppState.I.sessionById('srv-8')?.title, 'Alive');
      expect(h.rest.deleteCalls, <String>['srv-9', 'srv-9'],
          reason: 'the refresh retries the pending delete');
      expect(h.store.isTombstoned('srv-9'), isFalse,
          reason: 'the confirmed delete clears the tombstone');
    });

    test('a retry that fails again keeps the tombstone and keeps hiding the row',
        () async {
      final h = await _buildStore(
        idMap: <String, String>{'local-1': 'srv-9'},
      );
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      h.rest.stickyDeleteErrors = true;
      h.rest.deleteErrors['srv-9'] = CloudApiException(
        status: 503,
        code: 'unavailable',
        message: 'Cloud is briefly unavailable.',
      );
      await h.store.deleteServerSession('local-1');

      h.rest.sessionPages = <CloudPage<SessionDto>>[
        CloudPage<SessionDto>(
          items: <SessionDto>[_dto('srv-9', 'Still there')],
          nextCursor: null,
        ),
      ];
      await h.store.refreshSessions();

      expect(AppState.I.sessionById('srv-9'), isNull);
      expect(h.rest.deleteCalls, <String>['srv-9', 'srv-9']);
      expect(h.store.isTombstoned('srv-9'), isTrue,
          reason: 'an unconfirmed delete keeps the tombstone for the next '
              'refresh');

      // Tombstones persist across process death: a NEW store over the same
      // prefs keeps hiding the row.
      final reloaded = CloudSessionStore(
        rest: h.rest,
        cache: SessionHistoryRepository.I,
        prefs: h.prefs,
        connection: h.connection,
        ws: h.ws,
      );
      await reloaded.ready;
      expect(reloaded.isTombstoned('srv-9'), isTrue);
      reloaded.dispose();
    });

    test('a 404 answers the tombstone (already gone server-side)', () async {
      final h = await _buildStore(
        idMap: <String, String>{'local-1': 'srv-9'},
      );
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      h.rest.stickyDeleteErrors = true;
      h.rest.deleteErrors['srv-9'] = CloudApiException(
        status: 404,
        code: 'not_found',
        message: 'Session not found.',
      );
      await h.store.deleteServerSession('local-1');

      expect(h.store.isTombstoned('srv-9'), isFalse,
          reason: 'the server confirmed the row is gone — no more hiding');
    });

    test('AppState.deleteSession fires the server DELETE for a mapped chat',
        () async {
      final rest = FakeStoreRest();
      final store = CloudSessionStore.forTest(
        idMap: <String, String>{'local-1': 'srv-9'},
        rest: rest,
      );
      CloudSessionStore.installForTest(store);
      addTearDown(CloudSessionStore.resetForTest);
      addTearDown(store.dispose);

      AppState.I.sessions.add(
        ChatSession(id: 'local-1', title: 'Doomed', model: 'm'),
      );
      AppState.I.activeSessionId = 'local-1';

      await AppState.I.deleteSession('local-1');
      await pumpEventQueue();

      expect(AppState.I.sessionById('local-1'), isNull,
          reason: 'the local delete is unconditional');
      expect(rest.deleteCalls, <String>['srv-9'],
          reason: 'the server copy is deleted through the store');
      expect(store.serverIdFor('local-1'), isNull,
          reason: 'the id map entry dies with the chat');
    });
  });

  group('loadTranscript', () {
    test('reverses the newest-first page and writes the offline cache',
        () async {
      final h = await _buildStore();
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      // The multiplexer's persisted high-water mark (last accepted seq).
      h.ws.seedCursor('srv-1', '500-0');
      h.rest.messagesBySession = <String, List<MessageDto>>{
        'srv-1': <MessageDto>[
          _msg('m3', 'assistant', 'three', minute: 3),
          _msg('m2', 'assistant', 'two', minute: 2),
          _msg('m1', 'user', 'one', minute: 1),
        ],
      };
      final sink = _RecordingSink();
      h.store.transcriptSink = sink;

      await h.store.loadTranscript('srv-1');

      expect(h.rest.pageCalls.single.before, isNull);
      expect(
        [for (final m in h.store.cachedTranscriptFor('srv-1')!) m.content],
        <String>['one', 'two', 'three'],
        reason: 'the wire is newest-first; the transcript is oldest-first',
      );
      expect(h.store.cachedCursorFor('srv-1'), '500-0');
      expect(sink.seededCursor, '500-0');
      expect([for (final m in sink.seeded!) m.content],
          <String>['one', 'two', 'three']);

      // Durable: the SessionHistoryRepository namespace holds the row.
      final rows = await SessionHistoryRepository.I.readRows(
          h.prefs, CloudSessionStore.cacheNamespace);
      expect(rows, isNotNull);
      final row = (jsonDecode(rows!.single) as Map<String, dynamic>);
      expect(row['id'], 'srv-1');
      expect(row['cursor'], '500-0');
      expect(
        [
          for (final m in (row['messages'] as List))
            (m as Map<String, dynamic>)['content']
        ],
        <String>['one', 'two', 'three'],
      );
    });
  });

  group('offline outbox', () {
    test('enqueue persists across a new store instance (Review Focus #3)',
        () async {
      final h = await _buildStore(online: false);
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      expect(h.store.offline, isTrue);
      await h.store.enqueue('srv-1', 'composed offline');

      final reloaded = CloudSessionStore(
        rest: h.rest,
        cache: SessionHistoryRepository.I,
        prefs: h.prefs,
        connection: h.connection,
        ws: h.ws,
      );
      await reloaded.ready;
      final entries = reloaded.outboxFor('srv-1');
      expect(entries, hasLength(1));
      expect(entries.single.content, 'composed offline');
      expect(entries.single.clientMsgId, matches(RegExp(r'^[0-9a-f]{32}$')));
      reloaded.dispose();
    });

    test('flushOutbox sends FIFO with the stored clientMsgIds and removes '
        'each success', () async {
      final h = await _buildStore();
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      await h.store.enqueue('srv-1', 'first');
      await h.store.enqueue('srv-1', 'second');
      final stored = [
        for (final entry in h.store.outboxFor('srv-1')) entry.clientMsgId
      ];

      await h.store.flushOutbox();

      expect([for (final call in h.rest.sent) call.content],
          <String>['first', 'second']);
      expect([for (final call in h.rest.sent) call.clientMsgId], stored);
      expect(h.store.outboxFor('srv-1'), isEmpty);
    });

    test('enqueue carries maxOutputTokens through the flush (and survives a '
        'reload — offline sends honor the Settings cap)', () async {
      final h = await _buildStore();
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      await h.store.enqueue('srv-1', 'capped', maxOutputTokens: 4096);
      await h.store.enqueue('srv-1', 'auto');

      // Reload the queue from prefs: the cap is durable state, not a
      // call-site memory.
      final reloaded = CloudSessionStore(
        rest: h.rest,
        cache: SessionHistoryRepository.I,
        prefs: h.prefs,
        connection: h.connection,
        ws: h.ws,
      );
      await reloaded.ready;
      reloaded.dispose();

      await h.store.flushOutbox();

      expect([for (final call in h.rest.sent) call.content],
          <String>['capped', 'auto']);
      expect(h.rest.sent.first.maxOutputTokens, 4096);
      expect(h.rest.sent.last.maxOutputTokens, isNull);
    });

    test('a 503 stops the flush and keeps the remainder', () async {
      final h = await _buildStore();
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      await h.store.enqueue('srv-1', 'ok');
      await h.store.enqueue('srv-1', 'down');
      h.rest.sendErrors['down'] = CloudApiException(
        status: 503,
        code: 'unavailable',
        message: 'Cloud is briefly unavailable.',
      );

      await h.store.flushOutbox();

      expect([for (final call in h.rest.sent) call.content], <String>['ok']);
      final remaining = h.store.outboxFor('srv-1');
      expect(remaining, hasLength(1));
      expect(remaining.single.content, 'down');
      expect(h.store.outboxError?.code, 'unavailable');
    });

    test('402 keeps the prompt (retryable)', () async {
      final h = await _buildStore();
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      await h.store.enqueue('srv-1', 'limited');
      h.rest.sendErrors['limited'] = CloudApiException(
        status: 402,
        code: 'daily_limit_reached',
        message: 'Daily limit reached.',
      );
      await h.store.flushOutbox();
      expect(h.store.outboxFor('srv-1'), hasLength(1));
      expect(h.store.outboxError?.code, 'daily_limit_reached');
    });

    test('409 run_conflict removes the already-sent entry', () async {
      final h = await _buildStore();
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      await h.store.enqueue('srv-1', 'already sent');
      h.rest.sendErrors['already sent'] = CloudApiException(
        status: 409,
        code: 'run_conflict',
        message: 'Already accepted.',
      );
      await h.store.flushOutbox();
      expect(h.store.outboxFor('srv-1'), isEmpty);
    });
  });

  group('account-scoped outbox (P0 privacy)', () {
    // The store stamps and filters by `AppState.I.sessionAccountId`, so a
    // mid-test account switch is just a fresh AppState test instance.
    void signInAs(String account) {
      AppState.resetTestInstance();
      AppState.createForTest(sessionAccountIdForTest: account);
    }

    test("A's queued prompt is never delivered to B and B never sees it",
        () async {
      signInAs('a');
      final h = await _buildStore(knownServerIds: const <String>['srv-1']);
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      await h.store.enqueue('srv-1', 'a-secret');
      final aKey = AppState.I.accountScopedPrefKey(
        CloudSessionStore.outboxKey,
        'a',
      );

      // Sign out / in as B on the same device, same process.
      signInAs('b');

      await h.store.flushOutbox();
      expect(h.rest.sent, isEmpty,
          reason: "B's flush must not deliver A's prompt");
      expect(h.store.outboxFor('srv-1'), isEmpty,
          reason: "B's queue chip must not surface A's prompt text");
      expect(h.store.outboxEntries, isEmpty,
          reason: 'the reconnect upload path must skip foreign entries');

      // Skip-and-RETAIN, never drop: the entry is still on disk under A's
      // key, and B's key never carried it.
      expect(h.prefs.getString(aKey), isNotNull);
      expect(
        h.prefs.getString(
          AppState.I.accountScopedPrefKey(CloudSessionStore.outboxKey, 'b'),
        ),
        isNull,
      );

      // Sign back in as A: the retained entry finally flushes.
      signInAs('a');
      await h.store.flushOutbox();
      expect(
        [for (final call in h.rest.sent) call.content],
        <String>['a-secret'],
      );
      expect(h.store.outboxFor('srv-1'), isEmpty);
    });

    test("a restarted process as B loads none of A's queue; as A it flushes",
        () async {
      signInAs('a');
      final h = await _buildStore(knownServerIds: const <String>['srv-1']);
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      await h.store.enqueue('srv-1', 'a-secret');

      // Process death, restart while B is signed in.
      signInAs('b');
      final asB = CloudSessionStore(
        rest: h.rest,
        cache: SessionHistoryRepository.I,
        prefs: h.prefs,
        connection: h.connection,
        ws: h.ws,
      );
      await asB.ready;
      addTearDown(asB.dispose);
      expect(asB.outboxFor('srv-1'), isEmpty,
          reason: "A's scoped key must not even load for B");
      await asB.flushOutbox();
      expect(h.rest.sent, isEmpty);

      // Restart again as A: the scoped key still holds the prompt.
      signInAs('a');
      final asA = CloudSessionStore(
        rest: h.rest,
        cache: SessionHistoryRepository.I,
        prefs: h.prefs,
        connection: h.connection,
        ws: h.ws,
      );
      await asA.ready;
      addTearDown(asA.dispose);
      expect(asA.outboxFor('srv-1'), hasLength(1));
      await asA.flushOutbox();
      expect(
        [for (final call in h.rest.sent) call.content],
        <String>['a-secret'],
      );
    });

    test('legacy unstamped rows are adopted by the current account and the '
        'plain key is retired', () async {
      signInAs('a');
      // A pre-scoping build wrote this row under the plain key with no
      // account stamp.
      final h = await _buildStore(
        knownServerIds: const <String>['srv-1'],
        outbox: <OutboxEntry>[
          OutboxEntry(
            clientMsgId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            sessionId: 'srv-1',
            content: 'legacy queued prompt',
            createdAt: DateTime.utc(2026, 10, 17),
          ),
        ],
      );
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      // The migration adopted the row for A: visible to A, stamped under
      // A's scoped key, plain key gone.
      expect(h.store.outboxFor('srv-1'), hasLength(1));
      expect(h.prefs.getString(CloudSessionStore.outboxKey), isNull);
      final scoped = h.prefs.getString(
        AppState.I.accountScopedPrefKey(CloudSessionStore.outboxKey),
      );
      expect(scoped, isNotNull);
      expect(
        (jsonDecode(scoped!) as List).single['account'],
        'a',
        reason: 'the adopted row must carry the owning account stamp',
      );

      // A later process as B still cannot see or deliver it.
      signInAs('b');
      final asB = CloudSessionStore(
        rest: h.rest,
        cache: SessionHistoryRepository.I,
        prefs: h.prefs,
        connection: h.connection,
        ws: h.ws,
      );
      await asB.ready;
      addTearDown(asB.dispose);
      expect(asB.outboxFor('srv-1'), isEmpty);
      await asB.flushOutbox();
      expect(h.rest.sent, isEmpty);

      // Back as A it flushes (the stamp, not the loader, owns the row).
      signInAs('a');
      await h.store.flushOutbox();
      expect(
        [for (final call in h.rest.sent) call.content],
        <String>['legacy queued prompt'],
      );
    });

    test('guest keeps the plain key; a drained queue removes its key',
        () async {
      final h = await _buildStore(
        knownServerIds: const <String>['srv-1'],
        outbox: <OutboxEntry>[
          OutboxEntry(
            clientMsgId: 'cccccccccccccccccccccccccccccccc',
            sessionId: 'srv-1',
            content: 'guest prompt',
            createdAt: DateTime.utc(2026, 10, 17),
          ),
        ],
      );
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      // Guest's scoped key IS the plain key — the row stays put, stamped.
      expect(h.store.outboxFor('srv-1'), hasLength(1));
      final raw = h.prefs.getString(CloudSessionStore.outboxKey);
      expect(raw, isNotNull);
      expect((jsonDecode(raw!) as List).single['account'], 'guest');

      await h.store.flushOutbox();
      expect(
        [for (final call in h.rest.sent) call.content],
        <String>['guest prompt'],
      );
      // A drained owner's key is removed, not left to resurrect stale rows.
      expect(h.prefs.getString(CloudSessionStore.outboxKey), isNull);
    });
  });

  group('replayed flush (Task 4 idempotency)', () {
    test('a duplicate clientMsgId removes the entry without a second '
        'optimistic message', () async {
      const clientMsgId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final entry = OutboxEntry(
        clientMsgId: clientMsgId,
        sessionId: 'srv-1',
        content: 'hello',
        createdAt: DateTime.utc(2026, 10, 17),
      );
      // The server already accepted this prompt in a previous process: the
      // replay returns the ORIGINAL runId/userMessageId.
      final rest = FakeStoreRest()
        ..responsesByClientMsgId[clientMsgId] = const SendMessageResponse(
          runId: 'run-original',
          userMessageId: 'msg-original',
          status: 'queued',
        );
      final h = await _buildStore(
        rest: rest,
        knownServerIds: const <String>['srv-1'],
        // Two copies of the SAME entry: the first flush sent it but the
        // process died before the removal persisted.
        outbox: <OutboxEntry>[entry, entry],
      );
      addTearDown(h.ws.dispose);

      final facade = CloudAgentFacade(
        rest: h.rest,
        ws: h.ws,
        store: h.store,
      );
      addTearDown(facade.dispose);

      await h.store.flushOutbox();
      await pumpEventQueue();

      expect(h.rest.sent, isEmpty,
          reason: 'both sends are clientMsgId replays');
      expect(h.store.outboxFor('srv-1'), isEmpty);
      final projection = facade.projectionForTest('srv-1');
      expect(projection, isNotNull);
      final userRows =
          projection!.messages.where((m) => m.role == 'user').toList();
      expect(userRows, hasLength(1),
          reason: 'the replay must not append a second optimistic row');
      expect(userRows.single.privateSyncId, 'msg-original');
    });
  });

  group('cursor reconciliation (T7 carry)', () {
    test('seedCursor makes the projector ignore events at/below the cache '
        'high-water mark', () {
      final projection = TranscriptProjection();
      final projector = EventTranscriptProjector(projection);
      projector.seedCursor('500-0');

      projector.apply(
          _event('system_note', <String, dynamic>{'message': 'old'}, seq: '400-0'));
      expect(projection.messages, isEmpty,
          reason: 'an event already covered by the cache must not re-fold');

      projector.apply(
          _event('system_note', <String, dynamic>{'message': 'new'}, seq: '600-0'));
      expect(projection.messages.single.content, 'new');
    });

    test('the facade seeds the WS subscription cursor from the cache before '
        'subscribing', () async {
      final h = await _buildStore();
      addTearDown(h.ws.dispose);

      h.ws.seedCursor('srv-1', '500-0');
      h.rest.messagesBySession = <String, List<MessageDto>>{
        'srv-1': <MessageDto>[_msg('m1', 'user', 'cached', minute: 1)],
      };
      await h.store.loadTranscript('srv-1');
      expect(h.store.cachedCursorFor('srv-1'), '500-0');

      final facade =
          CloudAgentFacade(rest: h.rest, ws: h.ws, store: h.store);
      addTearDown(facade.dispose);

      // Triggers _stateFor → seed the projection + WS cursor → subscribe.
      facade.subscribeForTest('srv-1');
      await pumpEventQueue();

      final frames = <Map<String, dynamic>>[
        for (final raw in h.socket.sent)
          if (jsonDecode(raw) is Map<String, dynamic>)
            jsonDecode(raw) as Map<String, dynamic>
      ];
      final subscribe = frames.lastWhere(
        (frame) => frame['op'] == 'subscribe' && frame['sessionId'] == 'srv-1',
      );
      expect(subscribe['lastEventId'], '500-0',
          reason: 'replay must start at the cache high-water mark');
      expect(facade.projectionForTest('srv-1')!.messages.single.content,
          'cached');
    });
  });

  group('facade wiring', () {
    test('flushes the outbox on the offline→online flip', () async {
      final h = await _buildStore(online: false);
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      // A mapped server session keeps the entry flushable without a create.
      await h.store.ensureServerSession('local-1');
      await h.store.enqueue('local-1', 'queued offline');
      expect(h.store.offline, isTrue);

      final facade =
          CloudAgentFacade(rest: h.rest, ws: h.ws, store: h.store);
      addTearDown(facade.dispose);

      // Bring the WS up first (still offline: ConnectionService says so).
      await h.ws.connectIfNeeded();
      await pumpEventQueue();
      expect(h.store.offline, isTrue);

      // The connectivity flip is the flush trigger.
      await h.connection.probe();
      await pumpEventQueue();

      expect([for (final call in h.rest.sent) call.content],
          <String>['queued offline']);
      expect(h.store.outboxFor('local-1'), isEmpty);
    });

    test('runTask enqueues (and does not POST) while offline', () async {
      final h = await _buildStore(online: false);
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);

      final facade =
          CloudAgentFacade(rest: h.rest, ws: h.ws, store: h.store);
      addTearDown(facade.dispose);

      await facade.runTask('offline prompt', sessionId: 'srv-1');

      expect(h.rest.sent, isEmpty);
      expect(h.store.outboxFor('srv-1'), hasLength(1));
      expect(h.store.outboxFor('srv-1').single.content, 'offline prompt');
    });
  });

  // -------------------------------------------------------------------------
  // Wave 1a — send contract and data safety
  // -------------------------------------------------------------------------
  group('Wave 1a outbox data safety (CH-009 / CH-010 / CH-012)', () {
    for (final failure in <(String, Object)>[
      (
        'a 30 s timeout (status 0)',
        CloudApiException(status: 0, code: 'timeout', message: 'slow'),
      ),
      (
        'a 429',
        CloudApiException(status: 429, code: 'rate_limited', message: 'busy'),
      ),
      (
        'a 503',
        CloudApiException(status: 503, code: 'unavailable', message: 'down'),
      ),
      ('a socket failure', const SocketException('Failed host lookup')),
    ]) {
      test('${failure.$1} keeps the prompt for an automatic retry', () async {
        final h = await _buildStore(knownServerIds: const ['srv-1']);
        addTearDown(h.ws.dispose);
        addTearDown(h.store.dispose);
        h.rest.nextSendThrow = failure.$2;

        await h.store.enqueue('srv-1', 'keep me');
        await h.store.flushOutbox();

        final kept = h.store.outboxFor('srv-1');
        expect(kept, hasLength(1), reason: 'a transient failure never drops');
        expect(kept.single.failed, isFalse, reason: 'it retries by itself');
        expect(kept.single.attempts, 1);

        // The retry re-sends with the SAME idempotency key (CH-010).
        final key = kept.single.clientMsgId;
        await h.store.flushOutbox();
        expect(h.rest.sent.single.clientMsgId, key);
        expect(h.store.outboxFor('srv-1'), isEmpty);
      });
    }

    test('a 401 is KEPT as "Not sent" (never dropped) until retried', () async {
      final h = await _buildStore(knownServerIds: const ['srv-1']);
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);
      h.rest.sendErrors['who am i'] = CloudApiException(
          status: 401, code: 'unauthenticated', message: 'expired');

      await h.store.enqueue('srv-1', 'who am i');
      await h.store.flushOutbox();
      final entry = h.store.outboxFor('srv-1').single;
      expect(entry.failed, isTrue);
      expect(entry.failedCode, 'unauthenticated');

      // Survives process death.
      final reloaded = CloudSessionStore(
        rest: h.rest,
        cache: SessionHistoryRepository.I,
        prefs: h.prefs,
        connection: h.connection,
        ws: h.ws,
        autoRetry: false,
      );
      await reloaded.ready;
      expect(reloaded.outboxFor('srv-1').single.failedCode, 'unauthenticated');
      reloaded.dispose();

      // A plain flush does not resend a refused prompt; Retry does, with the
      // same key.
      h.rest.sendErrors.remove('who am i');
      await h.store.flushOutbox();
      expect(h.rest.sent, isEmpty);
      await h.store.retryOutboxEntry(entry.clientMsgId);
      expect(h.rest.sent.single.clientMsgId, entry.clientMsgId);
      expect(h.store.outboxFor('srv-1'), isEmpty);
    });

    test('a refused prompt holds the later prompts of ITS chat (order) but '
        'not other chats; Discard is the only drop', () async {
      final h = await _buildStore(knownServerIds: const ['srv-1', 'srv-2']);
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);
      h.rest.sendErrors['bad'] = CloudApiException(
          status: 400, code: 'bad_request', message: 'nope');

      await h.store.enqueue('srv-1', 'bad');
      await h.store.enqueue('srv-1', 'after bad');
      await h.store.enqueue('srv-2', 'other chat');
      await h.store.flushOutbox();

      expect([for (final c in h.rest.sent) c.content], ['other chat']);
      expect([for (final e in h.store.outboxFor('srv-1')) e.content],
          ['bad', 'after bad']);

      final bad = h.store.outboxFor('srv-1').first;
      await h.store.discardOutboxEntry(bad.clientMsgId);
      await h.store.flushOutbox();
      expect([for (final c in h.rest.sent) c.content],
          ['other chat', 'after bad']);
      expect(h.store.outboxFor('srv-1'), isEmpty);
    });

    test('retry backoff grows 2 s → 60 s and honours a 429 reset instant', () {
      expect(CloudSessionStore.retryDelay(1), const Duration(seconds: 2));
      expect(CloudSessionStore.retryDelay(2), const Duration(seconds: 4));
      expect(CloudSessionStore.retryDelay(3), const Duration(seconds: 8));
      expect(CloudSessionStore.retryDelay(9), const Duration(seconds: 60));
      final now = DateTime.utc(2026, 10, 19, 12);
      expect(
        CloudSessionStore.retryDelay(1,
            resetsAt: now.add(const Duration(seconds: 90)), now: now),
        const Duration(seconds: 90),
      );
    });

    test('the per-turn settings ride the flush and survive a reload '
        '(CT-001)', () async {
      final h = await _buildStore(knownServerIds: const ['srv-1']);
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);
      await h.store.enqueue(
        'srv-1',
        'plan it',
        turn: const CloudTurnOptions(
          model: 'glm-5.3 · high',
          mode: 'safe',
          planMode: true,
          presetId: 'code',
          sessionRefs: ['srv-9'],
        ),
      );
      final reloaded = CloudSessionStore(
        rest: h.rest,
        cache: SessionHistoryRepository.I,
        prefs: h.prefs,
        connection: h.connection,
        ws: h.ws,
        autoRetry: false,
      );
      await reloaded.ready;
      await reloaded.flushOutbox();
      final turn = h.rest.turns.single;
      expect(turn.model, 'glm-5.3 · high');
      expect(turn.mode, 'safe');
      expect(turn.planMode, isTrue);
      expect(turn.presetId, 'code');
      expect(turn.sessionRefs, ['srv-9']);
      reloaded.dispose();
    });
  });

  group('Wave 1a brand-new chat (CH-033 / CH-013)', () {
    test('a file staged in an unmapped chat uploads to the NEW server id and '
        'rides the first send', () async {
      final h = await _buildStore();
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);
      final sink = _RecordingSink();
      h.store.transcriptSink = sink;
      final dir = await Directory.systemTemp.createTemp('outbox-file');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/photo.png')..writeAsBytesSync([1, 2, 3]);

      await h.store.enqueue('local-new', 'describe this image',
          attachmentFiles: [
            OutboxFile(name: 'photo.png', path: file.path, size: 3),
          ]);
      await h.store.flushOutbox();

      expect(h.rest.createCalls, 1);
      expect(sink.mapped.single.local, 'local-new');
      expect(sink.mapped.single.server, 'srv-created-1');
      expect(h.rest.attachmentCreates.single.sessionId, 'srv-created-1');
      expect(h.rest.uploads.single, [1, 2, 3]);
      expect(h.rest.sent.single.sessionId, 'srv-created-1');
      expect(h.rest.sent.single.attachmentIds, hasLength(1));
      expect(sink.sentUser.single.content, 'describe this image');
    });

    test('a missing staged file is refused and kept, not silently sent '
        'without it', () async {
      final h = await _buildStore(knownServerIds: const ['srv-1']);
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);
      await h.store.enqueue('srv-1', 'needs the file', attachmentFiles: const [
        OutboxFile(name: 'gone.txt', path: '/nonexistent/gone.txt', size: 4),
      ]);
      await h.store.flushOutbox();
      expect(h.rest.sent, isEmpty);
      expect(h.store.outboxFor('srv-1').single.failedCode, 'attachment_missing');
    });

    test('the "New chat" placeholder is never sent as a title', () async {
      final h = await _buildStore();
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);
      AppState.I.sessions.add(ChatSession(id: 'l1', title: 'New chat', model: 'm'));
      AppState.I.sessions.add(ChatSession(id: 'l2', title: 'Trip plan', model: 'm'));
      await h.store.ensureServerSession('l1');
      await h.store.ensureServerSession('l2');
      expect(h.rest.createdTitles, [null, 'Trip plan']);
    });

    test("the server's placeholder title never overwrites a real local "
        'title; the server copy is healed', () async {
      final h = await _buildStore(idMap: const {'l1': 'srv-1'});
      addTearDown(h.ws.dispose);
      addTearDown(h.store.dispose);
      AppState.I.sessions
          .add(ChatSession(id: 'l1', title: 'Budget review', model: 'm'));
      h.rest.sessionPages = [
        CloudPage<SessionDto>(items: [_dto('srv-1', 'New chat')], nextCursor: null),
      ];
      await h.store.refreshSessions();
      await pumpEventQueue();
      expect(AppState.I.sessionById('l1')!.title, 'Budget review');
      expect(h.rest.titlePatches.single, (id: 'srv-1', title: 'Budget review'));
    });
  });
}
