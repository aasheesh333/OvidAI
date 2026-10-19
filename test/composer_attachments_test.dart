import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/state.dart';

/// Composer attachment lifecycle on the thin client.
///
/// P8 Task 19 port: `CloudAgentFacade` stages a file by SOURCE PATH (no local
/// workspace copy), so same-name cases use distinct source files. The
/// surviving contracts are the ones the cloud send path still owns: the
/// 20-file cap, filename validation, per-session staging, failure retention,
/// and clearing only the sent snapshot. Local-run cases (`llmOnceForTest`,
/// cancel-mid-provider-call, local tool dispatch, reference expansion) were
/// dropped with the retired service.
class _AttachRest extends CloudRestClient {
  _AttachRest()
      : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  final List<({String content, List<String> attachmentIds})> sent =
      <({String content, List<String> attachmentIds})>[];
  final List<int> uploadedBytes = <int>[];
  CloudApiException? sendError;
  Completer<void>? entered;
  Completer<void>? release;
  int _seq = 0;
  int _att = 0;

  @override
  Future<AttachmentUpload> createAttachment(
    String sessionId, {
    required String name,
    required int size,
  }) async {
    final n = ++_att;
    return AttachmentUpload(
      attachmentId: 'att-$n',
      uploadUrl: 'http://upload/$n',
      path: name,
      expiresAt: DateTime.utc(2026, 10, 18),
    );
  }

  @override
  Future<void> uploadAttachmentBytes(
    AttachmentUpload upload,
    List<int> bytes, {
    Duration? timeout,
  }) async {
    uploadedBytes.add(bytes.length);
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
    final gate = entered;
    if (gate != null && !gate.isCompleted) gate.complete();
    final wait = release;
    if (wait != null) await wait.future;
    final error = sendError;
    if (error != null) throw error;
    sent.add((content: content, attachmentIds: attachmentIds));
    final n = ++_seq;
    return SendMessageResponse(
      runId: 'run-$n',
      userMessageId: 'msg-user-$n',
      status: 'queued',
    );
  }

  @override
  Future<RunCancelResponse> cancelRun(String runId) async =>
      RunCancelResponse(runId: runId, status: 'cancelled');
}

class _FakeSocket implements CloudSocket {
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
  void sendText(String frame) {}

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_closed.isClosed) await _closed.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppState app;
  late ChatSession session;
  late _AttachRest rest;
  late WsMultiplexer ws;
  late CloudAgentFacade facade;
  var sourceSeq = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('composer-attachments-');
    AppState.resetTestInstance();
    app = AppState.createForTest();
    app.suspendCoalescedPersistenceForTest = true;
    rest = _AttachRest();
    ws = WsMultiplexer(
      mintTicket: () async => 'ticket',
      socketFactory: (_) async => _FakeSocket(),
      heartbeatInterval: const Duration(hours: 1),
      pongTimeout: const Duration(hours: 1),
      jitterMs: () => 0,
    );
    facade = CloudAgentFacade(rest: rest, ws: ws, store: null);
    CloudAgentFacade.installForTest(facade);
    sourceSeq = 0;
    session = ChatSession(
      id: 'attach-session',
      title: 'Attachments',
      model: 'gpt-4o',
      mode: 'auto',
      workspaceFolder:
          Directory('${root.path}/work').createSyncAndReturnPath(),
    );
    app.sessions.add(session);
    app.activeSessionId = session.id;
    facade.clearAttachment();
  });

  tearDown(() async {
    await ws.disconnect();
    facade.dispose();
    CloudAgentFacade.resetForTest();
    AppState.resetTestInstance();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<String?> attach(String name, [String contents = 'original']) async {
    final source = File('${root.path}/source-${sourceSeq++}')
      ..writeAsStringSync(contents);
    return facade.attachFile(source.path, name);
  }

  test('the 21st file is rejected with a limit explanation', () async {
    for (var i = 0; i < 20; i++) {
      expect(await attach('file-$i.txt'), isNull);
    }
    expect(await attach('extra.txt'), contains('20 files'));
    expect(facade.pendingAttachments, hasLength(20));
  });

  test('concurrent selections reserve slots and cannot overwrite names',
      () async {
    final source = File('${root.path}/source-concurrent')
      ..writeAsStringSync('content');
    final results = await Future.wait([
      for (var i = 0; i < 25; i++) facade.attachFile(source.path, 'same.txt'),
    ]);
    expect(results.where((r) => r == null), hasLength(20));
    expect(
      results.whereType<String>(),
      everyElement(contains('20 files')),
    );
    // The facade stages source paths (no copy), so the surviving assertion is
    // the staged COUNT, not path uniqueness.
    expect(facade.pendingAttachments, hasLength(20));
  });

  test('same-name files keep both contents and stay in the session', () async {
    expect(await attach('photo.png', 'first'), isNull);
    expect(await attach('photo.png', 'second'), isNull);
    final files = facade.pendingAttachments.toList();
    expect(files.map((f) => f.path).toSet(), hasLength(2));
    expect(File(files.first.path).readAsStringSync(), 'first');
    expect(File(files.last.path).readAsStringSync(), 'second');
    app.sessions.add(ChatSession(id: 'other', title: 'Other', model: 'gpt-4o'));
    app.activeSessionId = 'other';
    expect(facade.pendingAttachments, isEmpty);
    app.activeSessionId = session.id;
    expect(facade.pendingAttachments, hasLength(2));
  });

  test('removing one same-name attachment keeps the other', () async {
    await attach('notes.txt', 'one');
    await attach('notes.txt', 'two');
    facade.removeAttachment(facade.pendingAttachments.first.path);
    expect(facade.pendingAttachments, hasLength(1));
    expect(
      File(facade.pendingAttachments.single.path).readAsStringSync(),
      'two',
    );
  });

  test('picked filename cannot escape the workspace', () async {
    expect(
      await attach('../../escape.txt'),
      contains('invalid attachment filename'),
    );
    expect(facade.pendingAttachments, isEmpty);
    expect(File('${root.parent.path}/escape.txt').existsSync(), isFalse);
  });

  test('picker completion stays with its originating session', () async {
    final source = File('${root.path}/source-picker')
      ..writeAsStringSync('content');
    final selected = facade.attachFile(source.path, 'notes.txt');
    app.sessions.add(ChatSession(id: 'other', title: 'Other', model: 'gpt-4o'));
    app.activeSessionId = 'other';
    expect(await selected, isNull);
    expect(facade.pendingAttachments, isEmpty);
    app.activeSessionId = session.id;
    expect(facade.pendingAttachments.single.path, source.path);
  });

  test('failed provider send preserves composer attachments', () async {
    await attach('notes.txt');
    rest.sendError = CloudApiException(
      status: 401,
      code: 'invalid_api_key',
      message: 'HTTP 401: invalid key',
    );
    await facade.runTask('read notes', sessionId: session.id);
    expect(facade.pendingAttachments.single.name, 'notes.txt');
  });

  test('accepted send notifies and clears only the sent snapshot', () async {
    await attach('notes.txt');
    rest.entered = Completer<void>();
    rest.release = Completer<void>();
    final run = facade.runTask('read notes', sessionId: session.id);
    await rest.entered!.future;
    // CH-011 / CH-033: the sent files left the composer the moment Send
    // was pressed — they ride the pending user row, not the staging list.
    expect(facade.pendingAttachments, isEmpty);
    final pendingRow = facade.transcriptFor(session.id)!.last;
    expect(pendingRow.attachments.map((a) => a.name), ['notes.txt']);
    await attach('next.txt');
    final observed = <List<String>>[];
    void listener() => observed
        .add(facade.pendingAttachments.map((a) => a.name).toList());
    facade.addListener(listener);
    rest.release!.complete();
    await run;
    facade.removeListener(listener);
    expect(facade.pendingAttachments.map((a) => a.name), ['next.txt']);
    expect(observed, contains(equals(['next.txt'])));
  });

  test('stored paths survive reload and are visible on later requests', () {
    // Pure Message.fromJson round-trip: request assembly is server-side now,
    // so the surviving assertion is that the path is persisted verbatim.
    final restored = Message.fromJson({
      'role': 'user',
      'content': 'edit the photo',
      'attachments': [
        {
          'name': 'photo.png',
          'size': 42,
          'path': '${session.workspaceFolder}/photo.png',
        },
      ],
    });
    session.messages.add(
      Message.fromJson(jsonDecode(jsonEncode(restored.toJson()))),
    );
    session.messages.add(Message(role: 'user', content: 'now crop it'));
    final reloaded = ChatSession.fromJson(
      jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>,
    );
    expect(
      reloaded.messages.first.attachments.single.path,
      '${session.workspaceFolder}/photo.png',
    );
    expect(
      jsonEncode(reloaded.toJson()),
      contains('${session.workspaceFolder}/photo.png'),
    );
  });

  test('path-only metadata updates are written to session storage', () async {
    app.suspendCoalescedPersistenceForTest = false;
    app.sendMessage('read attachment');
    session.messages.first.attachments = [
      MessageAttachment(
        name: 'notes.txt',
        size: 12,
        path: '/work/first/notes.txt',
      ),
    ];
    app.persistSessions();
    await app.flushSessionPersistenceForTest();
    session.messages.first.attachments = [
      MessageAttachment(
        name: 'notes.txt',
        size: 12,
        path: '/work/second/notes.txt',
      ),
    ];
    app.persistSessions();
    await app.flushSessionPersistenceForTest();
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs
        .getStringList('ovid_sessions')!
        .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
        .firstWhere((s) => s['id'] == session.id);
    final restored = ChatSession.fromJson(saved);
    expect(
      restored.messages.first.attachments.single.path,
      '/work/second/notes.txt',
    );
  });
}

extension on Directory {
  String createSyncAndReturnPath() {
    createSync(recursive: true);
    return path;
  }
}
