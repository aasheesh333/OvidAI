// Wave 1a — the core chat send contract and data safety, end to end through
// the REAL store + facade pair (outbox, id mapping, projection) over fake
// REST / WS transports.
//
// Findings covered: CT-001 / CH-001 / CH-007 / CH-008 (per-turn settings on
// the wire), CH-009 (keep until delivered), CH-010 (one clientMsgId per user
// send), CH-011 (optimistic row first, in order), CH-012 (no unhandled
// failure on a new chat), CH-014 (unsubscribe on leave), CH-023 (composer
// queue survives process death), CH-033 (files staged in a brand-new chat),
// CH-044 (one cancel per Stop) and the plan_mode_changed fold.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/connection_service.dart';
import 'package:ovid_ai/core/session_history_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Rest extends CloudRestClient {
  _Rest() : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  final List<({String sessionId, String content, String? clientMsgId,
      List<String> attachmentIds, CloudTurnOptions turn})> sent = [];
  final List<({String sessionId, String name})> attachments = [];
  final List<String> cancelled = [];
  int creates = 0;

  /// Holds sendMessage answers until completed (the in-flight window).
  Completer<void>? sendGate;

  /// One-shot failures.
  Object? nextSendThrow;
  Object? nextCreateThrow;

  @override
  Future<SessionDto> createSession({String? title}) async {
    final thrown = nextCreateThrow;
    if (thrown != null) {
      nextCreateThrow = null;
      throw thrown;
    }
    creates++;
    return SessionDto(
      id: 'srv-new-$creates',
      title: title,
      mode: 'auto',
      createdAt: DateTime.utc(2026, 10, 19),
      updatedAt: DateTime.utc(2026, 10, 19),
    );
  }

  @override
  Future<SessionDto> patchSession(String id, {String? title, String? mode}) async =>
      SessionDto(
        id: id,
        title: title,
        mode: mode ?? 'auto',
        createdAt: DateTime.utc(2026, 10, 19),
        updatedAt: DateTime.utc(2026, 10, 19),
      );

  @override
  Future<AttachmentUpload> createAttachment(String sessionId,
      {required String name, required int size}) async {
    attachments.add((sessionId: sessionId, name: name));
    return AttachmentUpload(
      attachmentId: 'att-${attachments.length}',
      uploadUrl: 'https://upload.test/${attachments.length}',
      path: 'uploads/$name',
      expiresAt: DateTime.utc(2026, 10, 19, 1),
    );
  }

  @override
  Future<void> uploadAttachmentBytes(AttachmentUpload upload, List<int> bytes,
      {Duration? timeout}) async {}

  @override
  Future<SendMessageResponse> sendMessage(
    String sessionId,
    String content, {
    List<String> attachmentIds = const [],
    String? clientMsgId,
    int? maxOutputTokens,
    CloudTurnOptions turn = CloudTurnOptions.none,
  }) async {
    final thrown = nextSendThrow;
    if (thrown != null) {
      nextSendThrow = null;
      throw thrown;
    }
    sent.add((
      sessionId: sessionId,
      content: content,
      clientMsgId: clientMsgId,
      attachmentIds: attachmentIds,
      turn: turn,
    ));
    final gate = sendGate;
    if (gate != null) await gate.future;
    return SendMessageResponse(
      runId: 'run-${sent.length}',
      userMessageId: 'msg-${sent.length}',
      status: 'queued',
    );
  }

  @override
  Future<RunCancelResponse> cancelRun(String runId) async {
    cancelled.add(runId);
    return RunCancelResponse(runId: runId, status: 'cancelling');
  }
}

class _Socket implements CloudSocket {
  final StreamController<Object> _frames = StreamController<Object>.broadcast();
  final StreamController<void> _closed = StreamController<void>.broadcast();
  final List<String> sent = [];

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
    if (!_frames.isClosed) await _frames.close();
    if (!_closed.isClosed) await _closed.close();
  }

  void event(String sessionId, String seq, String type,
          Map<String, dynamic> payload) =>
      _frames.add(jsonEncode(<String, dynamic>{
        'op': 'event',
        'event': <String, dynamic>{
          'sessionId': sessionId,
          'seq': seq,
          'type': type,
          'payload': payload,
          'ts': '2026-10-19T10:00:00.000Z',
        },
      }));

  List<Map<String, dynamic>> framesWithOp(String op) => [
        for (final raw in sent)
          if ((jsonDecode(raw) as Map<String, dynamic>)['op'] == op)
            jsonDecode(raw) as Map<String, dynamic>,
      ];
}

class _H {
  _H(this.rest, this.ws, this.store, this.facade, this.sockets, this.prefs);
  final _Rest rest;
  final WsMultiplexer ws;
  final CloudSessionStore store;
  final CloudAgentFacade facade;
  final List<_Socket> sockets;
  final SharedPreferences prefs;
  _Socket get socket => sockets.last;

  Future<void> close() async {
    facade.dispose();
    store.dispose();
    await ws.disconnect();
  }
}

Future<_H> _build({
  List<String> knownServerIds = const ['srv-1', 'srv-2'],
  Map<String, String> idMap = const <String, String>{},
  bool persistQueue = false,
}) async {
  final prefs = await SharedPreferences.getInstance();
  if (idMap.isNotEmpty) {
    await prefs.setString(CloudSessionStore.idMapKey, jsonEncode(idMap));
  }
  await prefs.setString(
      CloudSessionStore.knownServerIdsKey, jsonEncode(knownServerIds));
  final sockets = <_Socket>[];
  final ws = WsMultiplexer(
    mintTicket: () async => 'ticket',
    socketFactory: (Uri url) async {
      final s = _Socket();
      sockets.add(s);
      return s;
    },
    prefs: prefs,
    heartbeatInterval: const Duration(hours: 1),
    pongTimeout: const Duration(hours: 1),
    jitterMs: () => 0,
  );
  await ws.connectIfNeeded();
  await pumpEventQueue();
  final rest = _Rest();
  final store = CloudSessionStore(
    rest: rest,
    cache: SessionHistoryRepository.I,
    prefs: prefs,
    connection: ConnectionService.forTest(),
    ws: ws,
    autoRetry: false,
  );
  await store.ready;
  final facade = CloudAgentFacade(
    rest: rest,
    ws: ws,
    store: store,
    persistQueue: persistQueue,
  );
  await pumpEventQueue();
  return _H(rest, ws, store, facade, sockets, prefs);
}

ChatSession _session(String id, {String model = 'auto', String title = 'Chat'}) {
  final s = ChatSession(id: id, title: title, model: model);
  AppState.I.sessions.add(s);
  AppState.I.activeSessionId = id;
  return s;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    AppState.resetTestInstance();
    AppState.createForTest();
  });

  group('CT-001 / CH-001 / CH-007 / CH-008 — per-turn settings', () {
    test('the header model, mode chip, Plan chip and preset ride the send',
        () async {
      final h = await _build();
      final s = _session('srv-1', model: 'glm-5.3 · high');
      s.mode = 'safe';
      s.planMode = true;
      s.presetId = 'code';

      await h.facade.runTask('do it', sessionId: 'srv-1');

      final turn = h.rest.sent.single.turn;
      expect(turn.model, 'glm-5.3 · high');
      expect(turn.mode, 'safe', reason: 'Read-Only maps to the server "safe"');
      expect(turn.planMode, isTrue);
      expect(turn.presetId, 'code');
      await h.close();
    });

    test('an empty pick or the legacy sentinel sends "auto" — what the header '
        'shows as Auto', () async {
      expect(CloudAgentFacade.cloudModelWireId(''), 'auto');
      expect(CloudAgentFacade.cloudModelWireId('Select a provider'), 'auto');
      expect(CloudAgentFacade.cloudModelWireId('minimax-m3'), 'minimax-m3');

      final h = await _build();
      _session('srv-1', model: 'Select a provider');
      await h.facade.runTask('hi', sessionId: 'srv-1');
      expect(h.rest.sent.single.turn.model, 'auto');
      await h.close();
    });

    test('each AgentMode chip maps to the same server mode name', () {
      expect(
        [for (final m in AgentMode.values) m.name],
        ['safe', 'auto', 'drive', 'studio'],
      );
      expect(AgentMode.safe.label, 'Read-Only');
      expect(AgentMode.auto.label, 'General');
      expect(AgentMode.drive.label, 'Full Access');
    });

    test('a queued row of a mapped chat drains with THAT chat\'s settings',
        () async {
      final h = await _build(idMap: const {'l1': 'srv-1'});
      final s = _session('l1', model: 'minimax-m3');
      s.mode = 'drive';
      await h.facade.runTask('first', sessionId: 'l1');
      await pumpEventQueue();
      h.socket.event('srv-1', '1-0', 'run_started', {'runId': 'run-1'});
      await pumpEventQueue();
      h.facade.enqueueMessage('second', sessionId: 'l1');
      h.socket.event('srv-1', '2-0', 'run_completed', {'runId': 'run-1'});
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await pumpEventQueue();
      expect([for (final c in h.rest.sent) c.content], ['first', 'second']);
      expect(h.rest.sent.last.turn.model, 'minimax-m3');
      expect(h.rest.sent.last.turn.mode, 'drive');
      await h.close();
    });

    test('@-tagged session ids ride the send (R1)', () async {
      final h = await _build();
      _session('srv-1');
      await h.facade.runTask('compare with @[Trip]',
          sessionId: 'srv-1', sessionRefs: const ['srv-2']);
      expect(h.rest.sent.single.turn.sessionRefs, ['srv-2']);
      await h.close();
    });

    test('plan_mode_changed from the server moves the Plan chip (the next '
        'send must not undo exit_plan_mode)', () async {
      final h = await _build();
      final s = _session('srv-1');
      s.planMode = true;
      await h.facade.runTask('plan it', sessionId: 'srv-1');
      await pumpEventQueue();
      h.socket.event('srv-1', '1-0', 'plan_mode_changed',
          {'runId': 'run-1', 'planMode': false});
      await pumpEventQueue();
      expect(s.planMode, isFalse);
      await h.facade.runTask('build it', sessionId: 'srv-1');
      expect(h.rest.sent.last.turn.planMode, isFalse);
      await h.close();
    });
  });

  group('CH-011 — the prompt shows at once, in order', () {
    test('a pending row appears before the POST lands and becomes the '
        'confirmed row in place', () async {
      final h = await _build();
      _session('srv-1');
      h.rest.sendGate = Completer<void>();
      final queued = Completer<void>();
      final send = h.facade.runTask('hello', sessionId: 'srv-1',
          onQueued: queued.complete);
      await queued.future;
      await pumpEventQueue();

      final rows = h.facade.transcriptFor('srv-1')!;
      expect(rows, hasLength(1));
      expect(CloudAgentFacade.pendingClientMsgIdOf(rows.single), isNotNull);
      expect(h.facade.pendingStateOf(rows.single), PendingSendState.sending);

      // A run_started racing the 202 lands AFTER the user row.
      h.socket.event('srv-1', '1-0', 'run_started', {'runId': 'run-1'});
      await pumpEventQueue();
      h.rest.sendGate!.complete();
      await send;

      final after = h.facade.transcriptFor('srv-1')!;
      expect(after.first.role, 'user');
      expect(after.first.privateSyncId, 'msg-1');
      expect(after.first.content, 'hello');
      expect(CloudAgentFacade.pendingClientMsgIdOf(after.first), isNull);
      await h.close();
    });
  });

  group('CH-033 / CH-012 — the first send of a brand-new chat', () {
    test('files staged before the server id exists ride the first send',
        () async {
      final h = await _build(knownServerIds: const []);
      _session('local-1', title: 'New chat');
      final dir = await Directory.systemTemp.createTemp('w1a-new-chat');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/photo.png')..writeAsBytesSync([7, 7, 7]);

      expect(await h.facade.attachFile(file.path, 'photo.png',
          sessionId: 'local-1'), isNull);
      await h.facade.runTask('describe this image', sessionId: 'local-1');

      expect(h.rest.creates, 1);
      expect(h.rest.attachments.single.sessionId, 'srv-new-1');
      expect(h.rest.sent.single.sessionId, 'srv-new-1');
      expect(h.rest.sent.single.attachmentIds, ['att-1']);
      expect(h.facade.pendingAttachmentsForTest('local-1'), isEmpty);
      // The local chat now renders the confirmed row under its server id.
      final rows = h.facade.transcriptFor('local-1')!;
      expect(rows.single.privateSyncId, 'msg-1');
      expect(rows.single.attachments.single.name, 'photo.png');
      await h.close();
    });

    test('a network failure while creating the chat never throws and never '
        'loses the prompt', () async {
      final h = await _build(knownServerIds: const []);
      _session('local-2', title: 'New chat');
      h.rest.nextCreateThrow = const SocketException('Failed host lookup');

      await h.facade.runTask('are you there?', sessionId: 'local-2');

      final kept = h.store.outboxFor('local-2');
      expect(kept.single.content, 'are you there?');
      expect(kept.single.failed, isFalse, reason: 'transient: retried later');
      final row = h.facade.transcriptFor('local-2')!.single;
      expect(h.facade.pendingStateOf(row), PendingSendState.retrying);

      await h.store.flushOutbox();
      expect(h.rest.sent.single.content, 'are you there?');
      expect(h.rest.sent.single.clientMsgId, kept.single.clientMsgId);
      await h.close();
    });
  });

  group('CH-009 / CH-010 — kept until delivered, one key per send', () {
    test('a timed-out send stays queued and its retry reuses the key',
        () async {
      final h = await _build();
      _session('srv-1');
      h.rest.nextSendThrow = CloudApiException(
          status: 0, code: 'timeout', message: 'no answer');

      await h.facade.runTask('slow network', sessionId: 'srv-1');
      final entry = h.store.outboxFor('srv-1').single;
      expect(h.rest.sent, isEmpty);

      await h.store.flushOutbox();
      expect(h.rest.sent.single.clientMsgId, entry.clientMsgId);
      expect(h.store.outboxFor('srv-1'), isEmpty);
      await h.close();
    });

    test('a refused send shows "Not sent"; Retry reuses the key; Discard '
        'drops it', () async {
      final h = await _build();
      _session('srv-1');
      h.rest.nextSendThrow = CloudApiException(
          status: 402, code: 'daily_limit_reached', message: 'limit');
      await h.facade.runTask('over the limit', sessionId: 'srv-1');
      final entry = h.store.outboxFor('srv-1').single;
      final row = h.facade.transcriptFor('srv-1')!.single;
      expect(h.facade.pendingStateOf(row), PendingSendState.failed);
      expect(h.facade.runStateFor('srv-1').lastErrorCode, 'daily_limit_reached');

      await h.facade.retryPendingSend(entry.clientMsgId);
      expect(h.rest.sent.single.clientMsgId, entry.clientMsgId);
      expect(h.facade.runStateFor('srv-1').lastErrorCode, isNull);

      h.rest.nextSendThrow = CloudApiException(
          status: 400, code: 'bad_request', message: 'no');
      await h.facade.runTask('second', sessionId: 'srv-1');
      final second = h.store.outboxFor('srv-1').single;
      await h.facade.discardPendingSend(second.clientMsgId);
      expect(h.store.outboxFor('srv-1'), isEmpty);
      expect(
        h.facade.transcriptFor('srv-1')!.where((m) => m.content == 'second'),
        isEmpty,
      );
      await h.close();
    });
  });

  group('CH-014 — subscriptions follow the screen', () {
    test('leaving an idle chat unsubscribes it; a chat with a live run stays '
        'subscribed until the run ends', () async {
      final h = await _build();
      _session('srv-1');
      await h.facade.runTask('first', sessionId: 'srv-1');
      await pumpEventQueue();
      h.socket.event('srv-1', '1-0', 'run_started', {'runId': 'run-1'});
      await pumpEventQueue();

      AppState.I.activeSessionId = 'srv-2';
      h.facade.releaseSession('srv-1');
      expect(h.facade.subscribedSessionsForTest, contains('srv-1'),
          reason: 'a live run keeps its stream');

      h.socket.event('srv-1', '2-0', 'run_completed', {'runId': 'run-1'});
      await pumpEventQueue();
      expect(h.facade.subscribedSessionsForTest, isNot(contains('srv-1')));
      expect(
        h.socket.framesWithOp('unsubscribe').map((f) => f['sessionId']),
        contains('srv-1'),
      );

      // Coming back re-subscribes.
      AppState.I.activeSessionId = 'srv-1';
      h.facade.activateSession('srv-1');
      await pumpEventQueue();
      expect(h.facade.subscribedSessionsForTest, contains('srv-1'));
      await h.close();
    });
  });

  group('CH-023 — the composer queue survives process death', () {
    test('rows queued behind a live run are restored by a new facade',
        () async {
      final h = await _build(persistQueue: true);
      _session('srv-1');
      h.facade.setActiveRunForTest('srv-1', 'busy');
      h.facade.enqueueMessage('queued one', sessionId: 'srv-1');
      h.facade.enqueueMessage('queued two', sessionId: 'srv-1');
      await pumpEventQueue();
      expect(h.facade.queuedMessagesFor('srv-1'), ['queued one', 'queued two']);

      // "Process death": a brand-new facade over the same prefs.
      final revived = CloudAgentFacade(
        rest: h.rest,
        ws: h.ws,
        store: null,
        persistQueue: true,
      );
      await pumpEventQueue();
      expect(revived.queuedMessagesFor('srv-1'), ['queued one', 'queued two']);
      revived.dispose();
      await h.close();
    });
  });

  group('CH-044 — Stop', () {
    test('a second Stop tap while stopping sends no second cancel', () async {
      final h = await _build();
      _session('srv-1');
      await h.facade.runTask('long task', sessionId: 'srv-1');
      await pumpEventQueue();
      h.socket.event('srv-1', '1-0', 'run_started', {'runId': 'run-1'});
      await pumpEventQueue();

      expect(h.facade.stopRequested(sessionId: 'srv-1'), isTrue);
      expect(h.facade.stoppingFor('srv-1'), isTrue);
      h.facade.stopRequested(sessionId: 'srv-1');
      await pumpEventQueue();
      expect(h.rest.cancelled, ['run-1']);
      await h.close();
    });
  });
}
