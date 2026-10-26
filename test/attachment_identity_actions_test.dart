import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/chat_pins.dart';
import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/cloud/projects.dart';
import 'package:ovid_ai/core/cloud/static_rich_content.dart';
import 'package:ovid_ai/core/connection_service.dart';
import 'package:ovid_ai/core/session_history_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/v2_app_shell.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/transcript_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppState.resetTestInstance();
    AppState.createForTest();
    ChatPinsStore.I.clearForTest();
    V2TranscriptIo.reset();
  });
  tearDown(() {
    V2TranscriptIo.reset();
    ChatPinsStore.I.clearForTest();
    AppState.resetTestInstance();
  });

  test('attachment identity and availability survive JSON round trips', () {
    final attachment = RichMessageAttachment(
      id: 'att-1',
      name: 'notes.txt',
      size: 12,
      path: '/tmp/notes.txt',
      availability: MessageAttachmentAvailability.pending,
    );
    final restored =
        richMessageFromJson(
              Message(
                role: 'user',
                content: 'attached',
                attachments: <MessageAttachment>[attachment],
              ).toJson(),
            ).attachments.single
            as RichMessageAttachment;
    expect(restored.id, 'att-1');
    expect(restored.path, '/tmp/notes.txt');
    expect(restored.availability, MessageAttachmentAvailability.pending);

    final ready = RichMessageAttachment.fromJson(<String, dynamic>{
      'id': 'att-ready',
      'name': 'ready.txt',
      'size': 2,
    });
    expect(ready.availability, MessageAttachmentAvailability.ready);
  });

  test('accepted outbox attachments retain real ids and ready state', () async {
    final ws = _socket();
    final store = CloudSessionStore.forTest(ws: ws);
    final facade = CloudAgentFacade(rest: _Rest(), ws: ws, store: store);
    addTearDown(() {
      facade.dispose();
      store.dispose();
      ws.dispose();
    });
    final entry = OutboxEntry(
      clientMsgId: 'client-1',
      sessionId: 'srv-1',
      content: 'attached',
      createdAt: DateTime.utc(2026, 10, 24),
      attachmentIds: const <String>['att-1'],
    );
    facade.outboxDelivered(
      'srv-1',
      entry,
      const SendMessageResponse(
        runId: 'run-1',
        userMessageId: 'message-1',
        status: 'queued',
      ),
    );

    final row = facade.transcriptFor('srv-1')!.single;
    final attachment = row.attachments.single as RichMessageAttachment;
    expect(attachment.id, 'att-1');
    expect(attachment.availability, MessageAttachmentAvailability.ready);
  });

  test(
    'restored pending attachments retain local path and pending state',
    () async {
      final ws = _socket();
      final store = CloudSessionStore.forTest(ws: ws);
      await store.enqueue(
        'srv-1',
        'pending',
        attachmentFiles: const <OutboxFile>[
          OutboxFile(name: 'local.txt', path: '/tmp/local.txt', size: 3),
        ],
      );
      final facade = CloudAgentFacade(rest: _Rest(), ws: ws, store: store);
      addTearDown(() {
        facade.dispose();
        store.dispose();
        ws.dispose();
      });
      facade.seedTranscript('srv-1', const <Message>[], null);

      final row = facade.transcriptFor('srv-1')!.single;
      final attachment = row.attachments.single as RichMessageAttachment;
      expect(attachment.path, '/tmp/local.txt');
      expect(attachment.id, isNull);
      expect(attachment.availability, MessageAttachmentAvailability.pending);
    },
  );

  // UNEXECUTED under HEAVY-COMMANDS-PAUSED.md (2026-10-25): authored to fail
  // while a refused outbox entry leaves every attachment pending forever.
  test('terminal upload refusal marks attachments unavailable and retry accepts them', () async {
    final ws = _socket();
    final prefs = await SharedPreferences.getInstance();
    final rest = _UploadRest();
    await prefs.setString(
      CloudSessionStore.knownServerIdsKey,
      jsonEncode(const <String>['srv-1']),
    );
    final store = CloudSessionStore(
      rest: rest,
      cache: SessionHistoryRepository.I,
      prefs: prefs,
      connection: ConnectionService.forTest(status: ConnectionStatus.online),
      ws: ws,
      autoRetry: false,
    );
    final facade = CloudAgentFacade(rest: rest, ws: ws, store: store);
    addTearDown(() {
      facade.dispose();
      store.dispose();
      ws.dispose();
    });
    await store.ready;
    final file = File('${Directory.systemTemp.path}/ovid-rich-upload-refused.txt');
    await file.writeAsString('no');
    addTearDown(() async {
      await file.delete().catchError((_) => file);
    });
    await store.enqueue(
      'srv-1',
      'refuse upload',
      clientMsgId: 'client-refused',
      attachmentFiles: <OutboxFile>[
        OutboxFile(name: 'refused.txt', path: file.path, size: 2),
      ],
    );
    facade.seedTranscript('srv-1', const <Message>[], null);
    await store.flushOutbox();

    RichMessageAttachment attachment() =>
        facade.transcriptFor('srv-1')!.single.attachments.single
            as RichMessageAttachment;
    expect(store.outboxEntry('client-refused')!.failed, isTrue);
    expect(attachment().availability, MessageAttachmentAvailability.unavailable);
    expect(attachment().name, 'refused.txt');

    rest.refuseUploads = false;
    await store.retryOutboxEntry('client-refused');
    expect(store.outboxEntry('client-refused'), isNull);
    final accepted = facade.transcriptFor('srv-1')!.single.attachments.single
        as RichMessageAttachment;
    expect(accepted.id, 'att-1');
    expect(accepted.availability, MessageAttachmentAvailability.ready);
  });

  // UNEXECUTED under HEAVY-COMMANDS-PAUSED.md (2026-10-25): covers both a
  // restored failed outbox row and its rendered error, not perpetual uploading.
  testWidgets('restored failed outbox renders attachment error instead of uploading', (
    tester,
  ) async {
    final ws = _socket();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      CloudSessionStore.outboxKey,
      jsonEncode(<Object>[
        OutboxEntry(
          clientMsgId: 'client-restart-failed',
          sessionId: 'srv-1',
          content: 'failed upload',
          createdAt: DateTime.utc(2026, 10, 24),
          attachmentIds: const <String>['att-checkpoint'],
          attachmentFiles: const <OutboxFile>[
            OutboxFile(name: 'later.txt', path: '/tmp/later.txt', size: 5),
          ],
          failedCode: 'attachment_missing',
          failedMessage: 'The attachment could not be uploaded.',
        ).toJson(),
      ]),
    );
    await prefs.setString(
      CloudSessionStore.attachmentMetadataKey,
      jsonEncode(<String, Object>{
        'account': 'guest',
        'sessions': <String, Object>{
          'srv-1': <String, Object>{
            'att-checkpoint': const OutboxFile(
              name: 'checkpoint.txt',
              path: '/tmp/checkpoint.txt',
              size: 10,
            ).toJson(),
          },
        },
      }),
    );
    final store = CloudSessionStore(
      rest: _Rest(),
      cache: SessionHistoryRepository.I,
      prefs: prefs,
      connection: ConnectionService.forTest(status: ConnectionStatus.online),
      ws: ws,
      autoRetry: false,
    );
    final facade = CloudAgentFacade(rest: _Rest(), ws: ws, store: store);
    // The widget-test binding checks for pending timers BEFORE addTearDown
    // callbacks run, and the facade's subscribe() opens the socket (and arms
    // its heartbeat). Tear the cloud objects down inside the body, keeping
    // the registered cleanup for failure paths.
    var tornDown = false;
    void tearDownCloud() {
      if (tornDown) return;
      tornDown = true;
      facade.dispose();
      store.dispose();
      ws.dispose();
    }
    addTearDown(tearDownCloud);
    await store.ready;
    facade.seedTranscript('srv-1', const <Message>[], null);
    final restored = facade.transcriptFor('srv-1')!.single.attachments;
    expect(restored.map((a) => a.name), ['checkpoint.txt', 'later.txt']);
    for (final attachment in restored.cast<RichMessageAttachment>()) {
      expect(attachment.availability, MessageAttachmentAvailability.unavailable);
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: V2LiveChatPage(
          data: V2LiveChatData(
            items: <V2LiveChatItem>[
              V2LiveUserMessage(
                id: 'message-failed',
                text: 'failed upload',
                attachments: restored,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Attachment unavailable'), findsNWidgets(2));
    expect(find.text('Uploading…'), findsNothing);
    expect(find.bySemanticsLabel('Open checkpoint.txt'), findsNothing);
    expect(find.bySemanticsLabel('Download later.txt'), findsNothing);
    tearDownCloud();
  });

  // UNEXECUTED under HEAVY-COMMANDS-PAUSED.md (2026-10-25): file 1 checkpoints
  // before file 2 fails; restart must retain metadata through cloud/history.
  test('partial upload checkpoint preserves metadata through acceptance and history restore', () async {
    final prefs = await SharedPreferences.getInstance();
    final ws = _socket();
    final rest = _UploadRest()
      ..refuseUploads = false
      ..interruptSecondUpload = true;
    final connection = ConnectionService.forTest(status: ConnectionStatus.online);
    await prefs.setString(
      CloudSessionStore.knownServerIdsKey,
      jsonEncode(const <String>['srv-1']),
    );
    final store = CloudSessionStore(
      rest: rest,
      cache: SessionHistoryRepository.I,
      prefs: prefs,
      connection: connection,
      ws: ws,
      autoRetry: false,
    );
    var oldStoreDisposed = false;
    addTearDown(() {
      if (!oldStoreDisposed) store.dispose();
      ws.dispose();
    });
    await store.ready;
    final first = File('${Directory.systemTemp.path}/ovid-rich-first.txt');
    final second = File('${Directory.systemTemp.path}/ovid-rich-second.txt');
    await first.writeAsString('first');
    await second.writeAsString('second');
    addTearDown(() async {
      await first.delete().catchError((_) => first);
      await second.delete().catchError((_) => second);
    });
    await store.enqueue(
      'srv-1',
      'partial checkpoint',
      clientMsgId: 'client-checkpoint',
      attachmentFiles: <OutboxFile>[
        OutboxFile(name: 'first.txt', path: first.path, size: 5),
        OutboxFile(name: 'second.txt', path: second.path, size: 6),
      ],
    );
    await store.flushOutbox();
    final checkpoint = store.outboxEntry('client-checkpoint')!;
    expect(checkpoint.attachmentIds, ['att-1']);
    expect(checkpoint.attachmentFiles.map((file) => file.name), ['second.txt']);
    expect(checkpoint.failed, isFalse);
    final rawMetadata = prefs.getString(CloudSessionStore.attachmentMetadataKey);
    expect(rawMetadata, isNotNull);
    final persistedMetadata =
        jsonDecode(rawMetadata!) as Map<String, dynamic>;
    expect(persistedMetadata['account'], 'guest');
    final sessionMetadata =
        (persistedMetadata['sessions'] as Map<String, dynamic>)['srv-1']
            as Map<String, dynamic>;
    expect(
      (sessionMetadata['att-1'] as Map<String, dynamic>)['path'],
      first.path,
    );
    // att-2 was returned for the interrupted create but never checkpointed;
    // the real retry create may return a fresh att-3.
    expect(sessionMetadata.containsKey('att-2'), isFalse);
    expect(sessionMetadata.containsKey('att-3'), isFalse);
    store.dispose();
    oldStoreDisposed = true;

    final restartedStore = CloudSessionStore(
      rest: rest,
      cache: SessionHistoryRepository.I,
      prefs: prefs,
      connection: connection,
      ws: ws,
      autoRetry: false,
    );
    final facade = CloudAgentFacade(rest: rest, ws: ws, store: restartedStore);
    addTearDown(() {
      facade.dispose();
      restartedStore.dispose();
    });
    await restartedStore.ready;
    facade.seedTranscript('srv-1', const <Message>[], null);
    final restored = facade.transcriptFor('srv-1')!.single.attachments
        .cast<RichMessageAttachment>();
    expect(restored, hasLength(2));
    expect(restored[0].id, 'att-1');
    expect(restored[0].name, 'first.txt');
    expect(restored[0].size, 5);
    expect(restored[0].path, first.path);
    expect(restored[0].availability, MessageAttachmentAvailability.pending);
    expect(restored[1].name, 'second.txt');
    expect(restored[1].path, second.path);
    expect(restored[1].availability, MessageAttachmentAvailability.pending);

    await restartedStore.flushOutbox();
    final accepted = facade.transcriptFor('srv-1')!.single.attachments
        .cast<RichMessageAttachment>();
    expect(rest.sent.single.attachmentIds, ['att-1', 'att-3']);
    expect(accepted.map((a) => a.id), ['att-1', 'att-3']);
    expect(accepted.map((a) => a.name), ['first.txt', 'second.txt']);
    expect(accepted.map((a) => a.path), [first.path, second.path]);
    expect(
      accepted.every((a) => a.availability == MessageAttachmentAvailability.ready),
      isTrue,
    );
    final acceptedMetadata =
        jsonDecode(prefs.getString(CloudSessionStore.attachmentMetadataKey)!)
            as Map<String, dynamic>;
    final acceptedSessionMetadata =
        (acceptedMetadata['sessions'] as Map<String, dynamic>)['srv-1']
            as Map<String, dynamic>;
    expect(
      (acceptedSessionMetadata['att-1'] as Map<String, dynamic>)['path'],
      first.path,
    );
    expect(
      (acceptedSessionMetadata['att-3'] as Map<String, dynamic>)['path'],
      second.path,
    );

    // A server DTO rebuild must restore the authorized local path by real
    // account+session+attachment ID, never by a URL or a generic attachment ID.
    rest.history = <MessageDto>[
      MessageDto(
        id: 'message-accepted',
        sessionId: 'srv-1',
        role: 'user',
        content: 'partial checkpoint',
        createdAt: DateTime.utc(2026, 10, 24),
        attachments: const <MessageAttachmentDto>[
          MessageAttachmentDto(id: 'att-1', name: 'first.txt', sizeBytes: 5),
          MessageAttachmentDto(id: 'att-3', name: 'second.txt', sizeBytes: 6),
        ],
      ),
    ];
    await restartedStore.loadTranscript('srv-1');
    final cloudRows = facade.transcriptFor('srv-1')!.single.attachments
        .cast<RichMessageAttachment>();
    expect(cloudRows.map((a) => a.name), ['first.txt', 'second.txt']);
    expect(cloudRows.map((a) => a.size), [5, 6]);
    expect(cloudRows.map((a) => a.path), [first.path, second.path]);

    // Replace the enriched row with a bare ID/name/size server row before the
    // replay. A no-op already-present branch must not be able to pass by
    // inheriting paths from the preceding DTO fixture.
    facade.seedTranscript(
      'srv-1',
      <Message>[
        Message(
          privateSyncId: 'message-accepted',
          role: 'user',
          content: 'partial checkpoint',
          attachments: <MessageAttachment>[
            RichMessageAttachment(id: 'att-1', name: 'first.txt', size: 5),
            RichMessageAttachment(id: 'att-3', name: 'second.txt', size: 6),
          ],
        ),
      ],
      '20',
    );
    final bareBeforeReplay = facade.transcriptFor('srv-1')!.single.attachments
        .cast<RichMessageAttachment>();
    expect(bareBeforeReplay.map((a) => a.id), ['att-1', 'att-3']);
    expect(bareBeforeReplay.map((a) => a.name), ['first.txt', 'second.txt']);
    expect(bareBeforeReplay.map((a) => a.size), [5, 6]);
    expect(bareBeforeReplay.map((a) => a.path), [null, null]);

    // The already-present server-row acceptance/replay branch must enrich,
    // not discard, that same metadata.
    facade.outboxDelivered(
      'srv-1',
      OutboxEntry(
        clientMsgId: 'client-checkpoint',
        sessionId: 'srv-1',
        content: 'partial checkpoint',
        createdAt: checkpoint.createdAt,
        attachmentIds: const <String>['att-1', 'att-3'],
      ),
      const SendMessageResponse(
        runId: 'run-accepted',
        userMessageId: 'message-accepted',
        status: 'queued',
      ),
    );
    final replayedRows = facade.transcriptFor('srv-1')!.single.attachments
        .cast<RichMessageAttachment>();
    expect(replayedRows.map((a) => a.path), [first.path, second.path]);

    // A real restart replaces the facade together with its socket
    // subscription. WsMultiplexer.subscribe() is single-listener per session,
    // so the old facade must be torn down before the restarted one listens.
    facade.dispose();

    // Seed a deliberately bare cache row: ID/name/size are present but local
    // paths are null, so offline restoration must consult the sidecar rather
    // than merely round-tripping an already-enriched DTO/cache attachment.
    final bareCacheMessage = Message(
      privateSyncId: 'message-accepted',
      role: 'user',
      content: 'partial checkpoint',
      attachments: <MessageAttachment>[
        RichMessageAttachment(id: 'att-1', name: 'first.txt', size: 5),
        RichMessageAttachment(id: 'att-3', name: 'second.txt', size: 6),
      ],
    );
    final bareCacheJson = bareCacheMessage.toJson();
    expect(
      (bareCacheJson['attachments'] as List<dynamic>)
          .map((a) => (a as Map<String, dynamic>)['path']),
      [null, null],
    );
    await SessionHistoryRepository.I.writeRows(
      prefs,
      CloudSessionStore.cacheNamespace,
      <String>[
        jsonEncode(<String, dynamic>{
          'id': 'srv-1',
          'cursor': '20',
          'messages': <Map<String, dynamic>>[bareCacheJson],
          'cachedAt': DateTime.utc(2026, 10, 24).toIso8601String(),
        }),
      ],
    );
    final historyStore = CloudSessionStore(
      rest: rest,
      cache: SessionHistoryRepository.I,
      prefs: prefs,
      connection: ConnectionService.forTest(status: ConnectionStatus.offline),
      ws: ws,
      autoRetry: false,
    );
    final historyFacade = CloudAgentFacade(rest: rest, ws: ws, store: historyStore);
    addTearDown(() {
      historyFacade.dispose();
      historyStore.dispose();
    });
    await historyStore.ready;
    await historyStore.loadTranscript('srv-1');
    final historyRows = historyFacade.transcriptFor('srv-1')!.single.attachments
        .cast<RichMessageAttachment>();
    expect(historyRows.map((a) => a.id), ['att-1', 'att-3']);
    expect(historyRows.map((a) => a.name), ['first.txt', 'second.txt']);
    expect(historyRows.map((a) => a.size), [5, 6]);
    expect(historyRows.map((a) => a.path), [first.path, second.path]);
  });

  // UNEXECUTED under HEAVY-COMMANDS-PAUSED.md (2026-10-25): owner+session
  // fencing must survive an in-process A → B → A transition with the same IDs.
  test('attachment metadata never crosses account or session boundaries', () async {
    AppState.resetTestInstance();
    AppState.createForTest(sessionAccountIdForTest: 'uid-a');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      CloudSessionStore.knownServerIdsKey,
      jsonEncode(const <String>['srv-1']),
    );
    final ws = _socket();
    final rest = _UploadRest()..refuseUploads = false;
    final store = CloudSessionStore(
      rest: rest,
      cache: SessionHistoryRepository.I,
      prefs: prefs,
      connection: ConnectionService.forTest(status: ConnectionStatus.online),
      ws: ws,
      autoRetry: false,
    );
    addTearDown(() {
      store.dispose();
      ws.dispose();
    });
    await store.ready;
    final file = File('${Directory.systemTemp.path}/ovid-rich-account-a.txt');
    await file.writeAsString('private-a');
    addTearDown(() async {
      await file.delete().catchError((_) => file);
    });
    await store.enqueue(
      'srv-1',
      'A attachment',
      clientMsgId: 'client-a',
      attachmentFiles: <OutboxFile>[
        OutboxFile(name: 'private-a.txt', path: file.path, size: 9),
      ],
    );
    await store.flushOutbox();
    final aKey = AppState.I.accountScopedPrefKey(
      CloudSessionStore.attachmentMetadataKey,
    );
    final aRaw = prefs.getString(aKey)!;
    expect(aRaw, contains('uid-a'));
    expect(aRaw, contains(file.path));
    expect(store.attachmentMetadataFor('srv-1', 'att-1')?.path, file.path);
    expect(store.attachmentMetadataFor('other-session', 'att-1'), isNull);

    // Production reset drops the RAM namespace before the account changes.
    store.resetSyncState();
    AppState.resetTestInstance();
    AppState.createForTest(sessionAccountIdForTest: 'uid-b');
    expect(store.attachmentMetadataFor('srv-1', 'att-1'), isNull);
    await store.enqueue(
      'srv-1',
      'B pending with a colliding attachment ID',
      clientMsgId: 'client-b',
      attachmentIds: const <String>['att-1'],
    );
    final bKey = AppState.I.accountScopedPrefKey(
      CloudSessionStore.attachmentMetadataKey,
    );
    final bRaw = prefs.getString(bKey);
    expect(bRaw == null || !bRaw.contains(file.path), isTrue);

    final facade = CloudAgentFacade(rest: rest, ws: ws, store: store);
    addTearDown(facade.dispose);
    facade.seedTranscript('srv-1', const <Message>[], null);
    final bAttachment = facade.transcriptFor('srv-1')!.single.attachments.single
        as RichMessageAttachment;
    expect(bAttachment.id, 'att-1');
    expect(bAttachment.name, isNot('private-a.txt'));
    expect(bAttachment.path, isNull);

    store.resetSyncState();
    AppState.resetTestInstance();
    AppState.createForTest(sessionAccountIdForTest: 'uid-a');
    expect(store.attachmentMetadataFor('srv-1', 'att-1')?.path, file.path);
    expect(store.attachmentMetadataFor('other-session', 'att-1'), isNull);
    final bRawAfterReturn = prefs.getString(bKey);
    expect(bRawAfterReturn == null || !bRawAfterReturn.contains(file.path), isTrue);

    // Even a correctly shaped but stale/wrong-owner payload under B's key is
    // not authorized to reconstruct a path for B's row.
    store.resetSyncState();
    AppState.resetTestInstance();
    AppState.createForTest(sessionAccountIdForTest: 'uid-b');
    await prefs.setString(
      bKey,
      jsonEncode(<String, Object>{
        'account': 'uid-a',
        'sessions': <String, Object>{
          'srv-1': <String, Object>{
            'att-1': OutboxFile(
              name: 'private-a.txt',
              path: file.path,
              size: 9,
            ).toJson(),
          },
        },
      }),
    );
    expect(store.attachmentMetadataFor('srv-1', 'att-1'), isNull);
  });

  // UNEXECUTED under HEAVY-COMMANDS-PAUSED.md (2026-10-25): a reset must not
  // replace an owner's existing sidecar with only the next upload's delta.
  test('sidecar overwrite after reset merges persisted owner namespace', () async {
    AppState.resetTestInstance();
    AppState.createForTest(sessionAccountIdForTest: 'uid-b');
    final prefs = await SharedPreferences.getInstance();
    final oldFile = const OutboxFile(
      name: 'old-b.txt',
      path: '/tmp/old-b.txt',
      size: 4,
    );
    await prefs.setString(
      CloudSessionStore.knownServerIdsKey,
      jsonEncode(const <String>['srv-1']),
    );
    await prefs.setString(
      AppState.I.accountScopedPrefKey(CloudSessionStore.attachmentMetadataKey),
      jsonEncode(<String, Object>{
        'account': 'uid-b',
        'sessions': <String, Object>{
          'srv-old': <String, Object>{'att-old': oldFile.toJson()},
        },
      }),
    );
    final ws = _socket();
    final rest = _UploadRest()..refuseUploads = false;
    final store = CloudSessionStore(
      rest: rest,
      cache: SessionHistoryRepository.I,
      prefs: prefs,
      connection: ConnectionService.forTest(status: ConnectionStatus.online),
      ws: ws,
      autoRetry: false,
    );
    addTearDown(() {
      store.dispose();
      ws.dispose();
    });
    await store.ready;
    // No metadata lookup is made before this upload: RAM is deliberately cold.
    store.resetSyncState();
    final newFile = File('${Directory.systemTemp.path}/ovid-rich-new-b.txt');
    await newFile.writeAsString('new-b');
    addTearDown(() async {
      await newFile.delete().catchError((_) => newFile);
    });
    await store.enqueue(
      'srv-1',
      'new B file after reset',
      clientMsgId: 'client-b-new',
      attachmentFiles: <OutboxFile>[
        OutboxFile(name: 'new-b.txt', path: newFile.path, size: 5),
      ],
    );
    await store.flushOutbox();

    final decoded = jsonDecode(
      prefs.getString(
        AppState.I.accountScopedPrefKey(CloudSessionStore.attachmentMetadataKey),
      )!,
    ) as Map<String, dynamic>;
    final sessions = decoded['sessions'] as Map<String, dynamic>;
    expect(
      ((sessions['srv-old'] as Map<String, dynamic>)['att-old']
          as Map<String, dynamic>)['path'],
      oldFile.path,
    );
    expect(
      ((sessions['srv-1'] as Map<String, dynamic>)['att-1']
          as Map<String, dynamic>)['path'],
      newFile.path,
    );
    expect(store.attachmentMetadataFor('srv-old', 'att-old')?.path, oldFile.path);
    expect(store.attachmentMetadataFor('srv-1', 'att-1')?.path, newFile.path);
  });

  // UNEXECUTED under HEAVY-COMMANDS-PAUSED.md (2026-10-25): an upload that
  // completes after a reset must merge its original owner's persisted bytes.
  test('in-flight upload completion after reset preserves prior owner metadata', () async {
    AppState.resetTestInstance();
    AppState.createForTest(sessionAccountIdForTest: 'uid-a');
    final prefs = await SharedPreferences.getInstance();
    const oldFile = OutboxFile(
      name: 'old-a.txt',
      path: '/tmp/old-a.txt',
      size: 4,
    );
    await prefs.setString(
      CloudSessionStore.knownServerIdsKey,
      jsonEncode(const <String>['srv-1']),
    );
    await prefs.setString(
      AppState.I.accountScopedPrefKey(CloudSessionStore.attachmentMetadataKey),
      jsonEncode(<String, Object>{
        'account': 'uid-a',
        'sessions': <String, Object>{
          'srv-old': <String, Object>{'att-old': oldFile.toJson()},
        },
      }),
    );
    final ws = _socket();
    final rest = _UploadRest()..refuseUploads = false;
    final store = CloudSessionStore(
      rest: rest,
      cache: SessionHistoryRepository.I,
      prefs: prefs,
      connection: ConnectionService.forTest(status: ConnectionStatus.online),
      ws: ws,
      autoRetry: false,
    );
    addTearDown(() {
      store.dispose();
      ws.dispose();
    });
    await store.ready;
    final file = File('${Directory.systemTemp.path}/ovid-rich-inflight-a.txt');
    await file.writeAsString('inflight-a');
    addTearDown(() async {
      await file.delete().catchError((_) => file);
    });
    final started = Completer<void>();
    final gate = Completer<void>();
    rest.nextUploadStarted = started;
    rest.nextUploadGate = gate;
    await store.enqueue(
      'srv-1',
      'A upload in flight',
      clientMsgId: 'client-a-inflight',
      attachmentFiles: <OutboxFile>[
        OutboxFile(name: 'inflight-a.txt', path: file.path, size: 10),
      ],
    );
    final flush = store.flushOutbox();
    await started.future;
    store.resetSyncState();
    gate.complete();
    await flush;

    final decoded = jsonDecode(
      prefs.getString(
        AppState.I.accountScopedPrefKey(CloudSessionStore.attachmentMetadataKey),
      )!,
    ) as Map<String, dynamic>;
    final sessions = decoded['sessions'] as Map<String, dynamic>;
    expect(
      ((sessions['srv-old'] as Map<String, dynamic>)['att-old']
          as Map<String, dynamic>)['path'],
      oldFile.path,
    );
    expect(
      ((sessions['srv-1'] as Map<String, dynamic>)['att-1']
          as Map<String, dynamic>)['path'],
      file.path,
    );
  });

  // UNEXECUTED under HEAVY-COMMANDS-PAUSED.md (2026-10-25): reset occurs
  // after upload completion and delta capture, before the serializer callback.
  test('reset after completion before serializer callback preserves immutable delta', () async {
    AppState.resetTestInstance();
    AppState.createForTest(sessionAccountIdForTest: 'uid-a');
    final prefs = await SharedPreferences.getInstance();
    const oldFile = OutboxFile(
      name: 'old-a.txt',
      path: '/tmp/old-a.txt',
      size: 4,
    );
    await prefs.setString(
      CloudSessionStore.knownServerIdsKey,
      jsonEncode(const <String>['srv-1']),
    );
    await prefs.setString(
      AppState.I.accountScopedPrefKey(CloudSessionStore.attachmentMetadataKey),
      jsonEncode(<String, Object>{
        'account': 'uid-a',
        'sessions': <String, Object>{
          'srv-old': <String, Object>{'att-old': oldFile.toJson()},
        },
      }),
    );
    final ws = _socket();
    final rest = _UploadRest()..refuseUploads = false;
    final serializerStarted = Completer<void>();
    final releaseSerializer = Completer<void>();
    var armed = false;
    final store = CloudSessionStore(
      rest: rest,
      cache: SessionHistoryRepository.I,
      prefs: prefs,
      connection: ConnectionService.forTest(status: ConnectionStatus.online),
      ws: ws,
      autoRetry: false,
      attachmentMetadataWriteBarrier: () async {
        if (!armed) return;
        if (!serializerStarted.isCompleted) serializerStarted.complete();
        await releaseSerializer.future;
      },
    );
    addTearDown(() {
      store.dispose();
      ws.dispose();
    });
    await store.ready;
    final file = File('${Directory.systemTemp.path}/ovid-rich-after-complete.txt');
    await file.writeAsString('complete');
    addTearDown(() async {
      await file.delete().catchError((_) => file);
    });
    await store.enqueue(
      'srv-1',
      'completed before reset',
      clientMsgId: 'client-after-complete',
      attachmentFiles: <OutboxFile>[
        OutboxFile(name: 'complete.txt', path: file.path, size: 8),
      ],
    );
    armed = true;
    final flush = store.flushOutbox();
    await serializerStarted.future;
    store.resetSyncState();
    releaseSerializer.complete();
    await flush;

    final decoded = jsonDecode(
      prefs.getString(
        AppState.I.accountScopedPrefKey(CloudSessionStore.attachmentMetadataKey),
      )!,
    ) as Map<String, dynamic>;
    final sessions = decoded['sessions'] as Map<String, dynamic>;
    expect(
      ((sessions['srv-old'] as Map<String, dynamic>)['att-old']
          as Map<String, dynamic>)['path'],
      oldFile.path,
    );
    expect(
      ((sessions['srv-1'] as Map<String, dynamic>)['att-1']
          as Map<String, dynamic>)['path'],
      file.path,
    );
    expect(store.attachmentMetadataFor('srv-1', 'att-1')?.path, file.path);
  });

  // UNEXECUTED under HEAVY-COMMANDS-PAUSED.md (2026-10-25): real A → B switch
  // while A's completed delta waits for serialization; B cannot inherit it.
  test('A to B in-flight completion persists only A owner metadata', () async {
    AppState.resetTestInstance();
    AppState.createForTest(sessionAccountIdForTest: 'uid-a');
    final prefs = await SharedPreferences.getInstance();
    const oldFile = OutboxFile(
      name: 'old-a.txt',
      path: '/tmp/old-a.txt',
      size: 4,
    );
    final aKey = AppState.I.accountScopedPrefKey(
      CloudSessionStore.attachmentMetadataKey,
    );
    await prefs.setString(
      CloudSessionStore.knownServerIdsKey,
      jsonEncode(const <String>['srv-1']),
    );
    await prefs.setString(
      aKey,
      jsonEncode(<String, Object>{
        'account': 'uid-a',
        'sessions': <String, Object>{
          'srv-old': <String, Object>{'att-old': oldFile.toJson()},
        },
      }),
    );
    final ws = _socket();
    final rest = _UploadRest()..refuseUploads = false;
    final serializerStarted = Completer<void>();
    final releaseSerializer = Completer<void>();
    var armed = false;
    final store = CloudSessionStore(
      rest: rest,
      cache: SessionHistoryRepository.I,
      prefs: prefs,
      connection: ConnectionService.forTest(status: ConnectionStatus.online),
      ws: ws,
      autoRetry: false,
      attachmentMetadataWriteBarrier: () async {
        if (!armed) return;
        if (!serializerStarted.isCompleted) serializerStarted.complete();
        await releaseSerializer.future;
      },
    );
    addTearDown(() {
      store.dispose();
      ws.dispose();
    });
    await store.ready;
    final file = File('${Directory.systemTemp.path}/ovid-rich-a-to-b.txt');
    await file.writeAsString('private-a');
    addTearDown(() async {
      await file.delete().catchError((_) => file);
    });
    await store.enqueue(
      'srv-1',
      'A completes after switch',
      clientMsgId: 'client-a-to-b',
      attachmentFiles: <OutboxFile>[
        OutboxFile(name: 'a-to-b.txt', path: file.path, size: 9),
      ],
    );
    armed = true;
    final flush = store.flushOutbox();
    await serializerStarted.future;
    store.resetSyncState();
    AppState.resetTestInstance();
    AppState.createForTest(sessionAccountIdForTest: 'uid-b');
    releaseSerializer.complete();
    await flush;

    final aDecoded = jsonDecode(prefs.getString(aKey)!)
        as Map<String, dynamic>;
    final aSessions = aDecoded['sessions'] as Map<String, dynamic>;
    expect(
      ((aSessions['srv-old'] as Map<String, dynamic>)['att-old']
          as Map<String, dynamic>)['path'],
      oldFile.path,
    );
    expect(
      ((aSessions['srv-1'] as Map<String, dynamic>)['att-1']
          as Map<String, dynamic>)['path'],
      file.path,
    );
    final bKey = AppState.I.accountScopedPrefKey(
      CloudSessionStore.attachmentMetadataKey,
    );
    final bRaw = prefs.getString(bKey);
    expect(bRaw == null || !bRaw.contains(file.path), isTrue);
    expect(store.attachmentMetadataFor('srv-1', 'att-1'), isNull);

    store.resetSyncState();
    AppState.resetTestInstance();
    AppState.createForTest(sessionAccountIdForTest: 'uid-a');
    expect(store.attachmentMetadataFor('srv-1', 'att-1')?.path, file.path);
  });

  // UNEXECUTED under HEAVY-COMMANDS-PAUSED.md (2026-10-25): malformed nested
  // records must not be silently omitted and replaced by a valid-looking map.
  test('malformed nested metadata is never overwritten by a later checkpoint', () async {
    AppState.resetTestInstance();
    AppState.createForTest(sessionAccountIdForTest: 'uid-b');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      CloudSessionStore.knownServerIdsKey,
      jsonEncode(const <String>['srv-1']),
    );
    final ws = _socket();
    final store = CloudSessionStore(
      rest: _UploadRest()..refuseUploads = false,
      cache: SessionHistoryRepository.I,
      prefs: prefs,
      connection: ConnectionService.forTest(status: ConnectionStatus.online),
      ws: ws,
      autoRetry: false,
    );
    addTearDown(() {
      store.dispose();
      ws.dispose();
    });
    await store.ready;
    final key = AppState.I.accountScopedPrefKey(
      CloudSessionStore.attachmentMetadataKey,
    );
    final malformedSessions = <Object>[
      'not-a-map',
      <String, Object>{'att-1': 'not-a-map'},
      <String, Object>{
        'att-1': <String, Object>{
          'name': 'future.txt',
          'path': '/tmp/future.txt',
          'size': 4,
          'forwardVersionField': true,
        },
      },
    ];
    for (final sessions in malformedSessions) {
      final raw = jsonEncode(<String, Object>{
        'account': 'uid-b',
        'sessions': sessions,
      });
      await prefs.setString(key, raw);
      await expectLater(
        store.enqueue(
          'srv-1',
          'must not overwrite malformed metadata',
          clientMsgId: 'client-malformed-$sessions',
        ),
        throwsStateError,
      );
      expect(prefs.getString(key), raw);
    }
  });

  test('attachment download action mints the canonical CDN URL', () async {
    final rest = _Rest();
    final minted = await rest.mintAttachmentCdnUrl(
      'srv-1',
      'att-1',
      download: true,
    );
    expect(minted.url, 'https://cdn.example/file');
    expect(rest.calls.single.path, '/sessions/srv-1/attachments/att-1/cdn-url');
    expect(rest.calls.single.query, <String, String>{'download': '1'});
  });

  testWidgets('only ready identified attachments expose working actions', (
    tester,
  ) async {
    var opens = 0;
    var downloads = 0;
    final ready = RichMessageAttachment(
      id: 'att-ready',
      name: 'ready.txt',
      size: 2,
      availability: MessageAttachmentAvailability.ready,
    );
    final pending = RichMessageAttachment(
      name: 'pending.txt',
      size: 2,
      path: '/tmp/pending.txt',
      availability: MessageAttachmentAvailability.pending,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: V2LiveChatPage(
          data: V2LiveChatData(
            items: <V2LiveChatItem>[
              V2LiveUserMessage(
                id: 'message-1',
                text: 'files',
                attachments: <MessageAttachment>[ready, pending],
                onOpenAttachment: (_) async => opens++,
                onDownloadAttachment: (_) async => downloads++,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.ensureVisible(find.text('ready.txt'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Open ready.txt'));
    await tester.tap(find.bySemanticsLabel('Download ready.txt'));
    expect(opens, 1);
    expect(downloads, 1);
    expect(find.text('Uploading…'), findsOneWidget);
    expect(find.bySemanticsLabel('Open pending.txt'), findsNothing);
    expect(find.bySemanticsLabel('Download pending.txt'), findsNothing);
  });

  testWidgets('shell opens and downloads a minted URL for a ready attachment', (
    tester,
  ) async {
    final rest = _Rest();
    final ws = _socket();
    final store = CloudSessionStore.forTest(
      idMap: const <String, String>{'local-files': 'srv-files'},
      rest: rest,
      ws: ws,
    );
    final facade = CloudAgentFacade(rest: rest, ws: ws, store: store);
    CloudRestClient.installForTest(rest);
    CloudSessionStore.installForTest(store);
    CloudAgentFacade.installForTest(facade);
    ProjectsController.installForTest(_SilentProjects());
    addTearDown(() async {
      ProjectsController.resetForTest();
      CloudAgentFacade.resetForTest();
      CloudSessionStore.resetForTest();
      store.dispose();
      facade.dispose();
      ws.dispose();
      await ws.disconnect();
    });
    final opened = <Uri>[];
    V2TranscriptIo.debugOpenOverride = (uri) async {
      opened.add(uri);
      return true;
    };
    AppState.I.sessions.add(
      ChatSession(
        id: 'local-files',
        title: 'Files',
        model: 'auto',
        messages: <Message>[
          Message(
            privateSyncId: 'message-files',
            role: 'user',
            content: 'attached',
            attachments: <MessageAttachment>[
              RichMessageAttachment(
                id: 'att-ready',
                name: 'ready.txt',
                size: 2,
                availability: MessageAttachmentAvailability.ready,
              ),
            ],
          ),
        ],
      ),
    );
    AppState.I.activeSessionId = 'local-files';

    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
    );
    await tester.pump();
    await tester.ensureVisible(find.bySemanticsLabel('Open ready.txt'));
    await tester.tap(find.bySemanticsLabel('Open ready.txt'));
    await tester.pump();
    expect(opened, <Uri>[Uri.parse('https://cdn.example/file')]);

    await tester.ensureVisible(find.bySemanticsLabel('Download ready.txt'));
    await tester.tap(find.bySemanticsLabel('Download ready.txt'));
    await tester.pump();
    expect(
      rest.calls.map((call) => call.path),
      contains('/sessions/srv-files/attachments/att-ready/cdn-url'),
    );
    expect(rest.calls.last.query, <String, String>{'download': '1'});
  });
}

class _SilentProjects extends ProjectsController {
  @override
  Future<void> refresh() async {}
}

WsMultiplexer _socket() => WsMultiplexer(
  mintTicket: () async => 'ticket',
  socketFactory: (_) async => _FakeSocket(),
  heartbeatInterval: const Duration(hours: 1),
  pongTimeout: const Duration(hours: 1),
  jitterMs: () => 0,
);

class _UploadRest extends CloudRestClient {
  _UploadRest() : super(restBase: 'https://example.test/cloud/v1');

  bool refuseUploads = true;
  bool interruptSecondUpload = false;
  int uploadCount = 0;
  Completer<void>? nextUploadStarted;
  Completer<void>? nextUploadGate;
  List<MessageDto> history = const <MessageDto>[];
  final List<({String sessionId, List<String> attachmentIds})> sent = [];

  @override
  Future<AttachmentUpload> createAttachment(
    String sessionId, {
    required String name,
    required int size,
  }) async {
    if (refuseUploads) {
      throw CloudApiException(
        status: 400,
        code: 'attachment_invalid',
        message: 'Attachment refused.',
      );
    }
    uploadCount++;
    // createAttachment has no client idempotency/file key: an interrupted
    // retry may return a fresh ID (att-3), and production must use that ID.
    final attachmentId = 'att-$uploadCount';
    return AttachmentUpload(
      attachmentId: attachmentId,
      uploadUrl: 'https://upload.example/$attachmentId',
      path: 'uploads/$attachmentId',
      expiresAt: DateTime.utc(2026, 10, 25),
    );
  }

  @override
  Future<void> uploadAttachmentBytes(
    AttachmentUpload upload,
    List<int> bytes, {
    Duration? timeout,
  }) async {
    if (interruptSecondUpload && uploadCount == 2) {
      interruptSecondUpload = false;
      throw CloudApiException(
        status: 503,
        code: 'unavailable',
        message: 'Temporary upload interruption.',
      );
    }
    final started = nextUploadStarted;
    if (started != null) {
      nextUploadStarted = null;
      started.complete();
    }
    final gate = nextUploadGate;
    if (gate != null) {
      nextUploadGate = null;
      await gate.future;
    }
  }

  @override
  Future<CloudPage<MessageDto>> pageMessages(
    String sessionId, {
    int limit = 50,
    String? before,
    bool withEvents = false,
  }) async {
    return MessagePage(
      items: history,
      nextCursor: null,
      hasWatermark: true,
      lastEventSeq: '20',
      activeRunId: null,
      rawEvents: const <Map<String, dynamic>>[],
    );
  }

  @override
  Future<SendMessageResponse> sendMessage(
    String sessionId,
    String content, {
    List<String> attachmentIds = const <String>[],
    String? clientMsgId,
    int? maxOutputTokens,
    CloudTurnOptions turn = CloudTurnOptions.none,
  }) async {
    sent.add((sessionId: sessionId, attachmentIds: attachmentIds));
    return const SendMessageResponse(
      runId: 'run-accepted',
      userMessageId: 'message-accepted',
      status: 'queued',
    );
  }
}

class _Rest extends CloudRestClient {
  _Rest() : super(restBase: 'https://example.test/cloud/v1');

  final List<({String path, Map<String, String>? query})> calls = [];

  @override
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    calls.add((path: path, query: query));
    return <String, dynamic>{
      'url': 'https://cdn.example/file',
      'expiresAt': '2026-10-24T18:00:00.000Z',
    };
  }
}

class _FakeSocket implements CloudSocket {
  final StreamController<Object> _frames = StreamController<Object>.broadcast();
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
    await _frames.close();
    await _closed.close();
  }
}
