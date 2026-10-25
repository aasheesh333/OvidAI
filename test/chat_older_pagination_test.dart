import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/message_search.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/cloud/projects.dart';
import 'package:ovid_ai/core/cloud/static_rich_content.dart';
import 'package:ovid_ai/core/connection_service.dart';
import 'package:ovid_ai/core/session_history_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/v2_app_shell.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppState.resetTestInstance();
    AppState.createForTest();
  });

  tearDown(AppState.resetTestInstance);

  test(
    'older prepend preserves anchor, socket watermark, and live run',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final rest = _PagingRest();
      final ws = WsMultiplexer(
        mintTicket: () async => 'ticket',
        socketFactory: (_) async => _FakeSocket(),
        prefs: prefs,
        heartbeatInterval: const Duration(hours: 1),
        pongTimeout: const Duration(hours: 1),
        jitterMs: () => 0,
      );
      addTearDown(ws.dispose);
      await ws.connectIfNeeded();
      await pumpEventQueue();
      final store = CloudSessionStore(
        rest: rest,
        cache: SessionHistoryRepository.I,
        prefs: prefs,
        connection: ConnectionService.forTest(status: ConnectionStatus.online),
        ws: ws,
        autoRetry: false,
      );
      addTearDown(store.dispose);
      await store.ready;
      final sink = _LiveSink();
      store.transcriptSink = sink;

      await store.loadTranscript('srv-1');
      expect(rest.calls.single.before, isNull);
      expect(sink.liveRunId, 'run-live');
      expect(store.hasEarlierTranscript('srv-1'), isTrue);
      expect(sink.messages.map((message) => message.privateSyncId), <String>[
        'm2',
        'm3',
      ]);
      final historyAttachment =
          sink.messages.first.attachments.single as RichMessageAttachment;
      expect(historyAttachment.id, 'att-history');
      expect(
        historyAttachment.availability,
        MessageAttachmentAvailability.ready,
      );

      // Newer live state arrives after the REST snapshot. Older paging must not
      // move the socket backwards or replace/refold this active tail.
      ws.seedCursor('srv-1', '900');
      sink.messages.add(
        Message(
          privateSyncId: 'live-tail',
          role: 'assistant',
          kind: MsgKind.streaming,
          content: 'still running',
        ),
      );

      final receipt = await store.loadEarlierTranscript(
        'srv-1',
        anchorMessageId: 'm3',
      );

      expect(rest.calls.last.before, 'older-2');
      expect(receipt.previousOldestMessageId, 'm2');
      expect(receipt.anchorMessageId, 'm3');
      expect(receipt.insertedCount, 2);
      expect(receipt.nextCursor, isNull);
      expect(receipt.hasMore, isFalse);
      expect(receipt.socketWatermark, '900');
      expect(await ws.cursorFor('srv-1'), '900');
      expect(sink.liveRunId, 'run-live');
      expect(sink.richSeedCount, 1);
      expect(sink.prepends, 1);
      expect(sink.messages.map((message) => message.privateSyncId), <String>[
        'm0',
        'm1',
        'm2',
        'm3',
        'live-tail',
      ]);
      expect(store.cachedCursorFor('srv-1'), '10');

      final exhausted = await store.loadEarlierTranscript('srv-1');
      expect(exhausted.insertedCount, 0);
      expect(exhausted.previousOldestMessageId, 'm0');
      expect(exhausted.anchorMessageId, isNull);
      expect(rest.calls, hasLength(2));
      expect(store.hasEarlierTranscript('srv-1'), isFalse);
    },
  );

  testWidgets('prepending restores the first visible row at its exact offset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const _PagingHost()),
    );
    await tester.pump();

    final anchor = find.text('ANCHOR');
    expect(anchor, findsOneWidget);
    final before = tester.getTopLeft(anchor).dy;
    await tester.tap(find.text('Load earlier messages'));
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }

    expect(anchor, findsOneWidget);
    final after = tester.getTopLeft(anchor).dy;
    expect(after, moreOrLessEquals(before, epsilon: 1));
    expect(find.text('Load earlier messages'), findsNothing);
  });

  testWidgets('a message deep link scrolls the actual target into view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final items = <V2LiveChatItem>[
      for (var i = 0; i < 40; i++)
        V2LiveUserMessage(
          id: 'm$i',
          text: i == 39 ? 'TARGET MESSAGE' : 'row $i\n${'x' * 80}',
        ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: V2LiveChatPage(
          data: V2LiveChatData(items: items, targetMessageId: 'm39'),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }

    expect(find.text('TARGET MESSAGE'), findsOneWidget);
    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('v2-live-transcript')),
      matching: find.byType(Scrollable),
    );
    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      greaterThan(0),
    );
  });

  // UNEXECUTED additions under HEAVY-COMMANDS-PAUSED.md (2026-10-25):
  // final viewport stability and same-hit reactivation are new assertions.
  testWidgets(
    'search deep link pages to the exact message and fences foreign ids',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final prefs = await SharedPreferences.getInstance();
      final rest = _PagingRest();
      final ws = WsMultiplexer(
        mintTicket: () async => 'ticket',
        socketFactory: (_) async => _FakeSocket(),
        prefs: prefs,
        heartbeatInterval: const Duration(hours: 1),
        pongTimeout: const Duration(hours: 1),
        jitterMs: () => 0,
      );
      await ws.connectIfNeeded();
      final store = CloudSessionStore.forTest(
        idMap: const <String, String>{'local-search': 'srv-1'},
        rest: rest,
        cache: SessionHistoryRepository.I,
        connection: ConnectionService.forTest(status: ConnectionStatus.online),
        ws: ws,
      );
      final facade = CloudAgentFacade(rest: rest, ws: ws, store: store);
      CloudSessionStore.installForTest(store);
      CloudAgentFacade.installForTest(facade);
      ProjectsController.installForTest(_SilentProjects());
      addTearDown(() async {
        await ws.disconnect();
        ProjectsController.resetForTest();
        CloudAgentFacade.resetForTest();
        CloudSessionStore.resetForTest();
        store.dispose();
        ws.dispose();
      });

      AppState.I.sessions.add(
        ChatSession(
          id: 'local-search',
          title: 'Search target',
          model: 'auto',
          mode: 'auto',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
      );
      await tester.pump();
      final dynamic shell = tester.state<State<V2AppShell>>(
        find.byType(V2AppShell),
      );
      ws.seedCursor('srv-1', '900');

      await shell.openSearchHit(
        const MessageSearchHit(messageId: 'm1', sessionId: 'srv-1'),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }

      expect(AppState.I.activeSessionId, 'local-search');
      expect(rest.calls.map((call) => call.before), [null, 'older-2']);
      expect(await ws.cursorFor('srv-1'), '900');
      expect(facade.busyFor('local-search'), isTrue);
      // The tall paragraph contains more than the short ID text. Use the
      // stable row identity instead of an exact-text finder.
      final target = find.byKey(const V2LiveRowKey('live-item-m1'));
      expect(target, findsOneWidget);
      final scrollable = find.descendant(
        of: find.byKey(const ValueKey('v2-live-transcript')),
        matching: find.byType(Scrollable),
      );
      ScrollableState scrollState() =>
          tester.state<ScrollableState>(scrollable);

      // Finding 1: the exact target must survive every competing anchor retry,
      // not merely exist somewhere in the lazy list after search pagination.
      final targetTop = tester.getTopLeft(target).dy;
      expect(targetTop, greaterThanOrEqualTo(0));
      expect(targetTop, lessThan(200));
      final targetPixels = scrollState().position.pixels;
      expect(scrollState().position.maxScrollExtent, greaterThan(0));
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect(tester.getTopLeft(target).dy, moreOrLessEquals(targetTop, epsilon: 1));
      expect(scrollState().position.pixels, moreOrLessEquals(targetPixels, epsilon: 1));

      // Finding 4: scrolling away and tapping the SAME hit is a new request.
      scrollState().position.jumpTo(scrollState().position.maxScrollExtent);
      await tester.pump();
      await tester.pump();
      expect(
        scrollState().position.pixels,
        isNot(moreOrLessEquals(targetPixels, epsilon: 1)),
      );
      final targetRect = target.evaluate().isEmpty
          ? null
          : tester.getRect(target);
      expect(
        targetRect == null ||
            targetRect.bottom <= 0 ||
            targetRect.top >= tester.view.physicalSize.height,
        isTrue,
        reason: 'The same-hit reselect must begin with the target offscreen.',
      );
      await shell.openSearchHit(
        const MessageSearchHit(messageId: 'm1', sessionId: 'srv-1'),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect(tester.getTopLeft(target).dy, moreOrLessEquals(targetTop, epsilon: 1));
      expect(scrollState().position.pixels, moreOrLessEquals(targetPixels, epsilon: 1));

      // Different hits in the same session still own their own exact targets.
      await shell.openSearchHit(
        const MessageSearchHit(messageId: 'm0', sessionId: 'srv-1'),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      final firstTarget = find.byKey(const V2LiveRowKey('live-item-m0'));
      expect(firstTarget, findsOneWidget);
      expect(tester.getTopLeft(firstTarget).dy, greaterThanOrEqualTo(0));
      expect(tester.getTopLeft(firstTarget).dy, lessThan(200));

      await shell.openSearchHit(
        const MessageSearchHit(messageId: 'm0', sessionId: 'foreign-session'),
      );
      expect(AppState.I.activeSessionId, 'local-search');
      expect(rest.calls, hasLength(2));
      await ws.disconnect();
    },
  );
}

class _SilentProjects extends ProjectsController {
  @override
  Future<void> refresh() async {}
}

class _PagingHost extends StatefulWidget {
  const _PagingHost();

  @override
  State<_PagingHost> createState() => _PagingHostState();
}

class _PagingHostState extends State<_PagingHost> {
  List<V2LiveChatItem> _items = <V2LiveChatItem>[
    const V2LiveUserMessage(id: 'm0', text: 'ANCHOR'),
    for (var i = 1; i < 30; i++)
      V2LiveUserMessage(id: 'm$i', text: 'message $i'),
  ];
  bool _hasEarlier = true;

  Future<PrependReceipt> _loadEarlier(String? anchorMessageId) async {
    setState(() {
      _items = <V2LiveChatItem>[
        for (var i = 0; i < 5; i++)
          V2LiveUserMessage(id: 'older-$i', text: 'OLDER $i ${'y' * 240}'),
        ..._items,
      ];
      _hasEarlier = false;
    });
    return PrependReceipt(
      previousOldestMessageId: 'm0',
      anchorMessageId: anchorMessageId,
      insertedCount: 5,
      nextCursor: null,
      socketWatermark: 'test-watermark',
    );
  }

  @override
  Widget build(BuildContext context) {
    return V2LiveChatPage(
      data: V2LiveChatData(items: _items, hasEarlier: _hasEarlier),
      onLoadEarlier: _loadEarlier,
    );
  }
}

class _PagingRest extends CloudRestClient {
  _PagingRest() : super(restBase: 'https://example.test/cloud/v1');

  final List<({String? before, int limit, bool withEvents})> calls = [];

  @override
  Future<CloudPage<MessageDto>> pageMessages(
    String sessionId, {
    int limit = 50,
    String? before,
    bool withEvents = false,
  }) async {
    calls.add((before: before, limit: limit, withEvents: withEvents));
    final initial = before == null;
    return MessagePage(
      items: <MessageDto>[
        if (initial) ...[
          _message('m3', 3),
          _message('m2', 2),
        ] else ...[
          _message('m1', 1),
          _message('m0', 0),
        ],
      ],
      nextCursor: initial ? 'older-2' : null,
      hasWatermark: true,
      lastEventSeq: '10',
      activeRunId: 'run-live',
      rawEvents: const <Map<String, dynamic>>[],
    );
  }

  static MessageDto _message(String id, int minute) => MessageDto(
    id: id,
    sessionId: 'srv-1',
    role: 'assistant',
    // Tall rows guarantee a real scroll range; four one-line rows made the
    // same-hit reselection assertions vacuous on a 600 dp viewport.
    content: 'message $id\n${'history row $id ' * 80}',
    createdAt: DateTime.utc(2026, 10, 24, 12, minute),
    attachments: <MessageAttachmentDto>[
      if (id == 'm2')
        const MessageAttachmentDto(
          id: 'att-history',
          name: 'history.txt',
          sizeBytes: 12,
        ),
    ],
  );
}

class _LiveSink implements CloudTranscriptSink {
  final List<Message> messages = <Message>[];
  String? liveRunId;
  int richSeedCount = 0;
  int prepends = 0;

  @override
  void seedRichTranscript(
    String serverSessionId, {
    required List<Message> rows,
    required List<CloudSessionEvent> events,
    required String? watermark,
    required String? activeRunId,
  }) {
    richSeedCount++;
    messages
      ..clear()
      ..addAll(rows);
    liveRunId = activeRunId;
  }

  @override
  void prependTranscript(String serverSessionId, List<Message> older) {
    prepends++;
    messages.insertAll(0, older);
  }

  @override
  void seedTranscript(
    String serverSessionId,
    List<Message> rows,
    String? cursor,
  ) {
    messages
      ..clear()
      ..addAll(rows);
  }

  @override
  void outboxDelivered(
    String serverSessionId,
    OutboxEntry entry,
    SendMessageResponse response,
  ) {}

  @override
  void sessionMapped(String localSessionId, String serverSessionId) {}
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
