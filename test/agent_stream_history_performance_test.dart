import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

/// Counts real list traversal without relying on machine speed or timers.
class _CountedMessages extends ListBase<Message> {
  final List<Message> _items = [];
  int reads = 0;
  int containsCalls = 0;

  @override
  int get length => _items.length;

  @override
  set length(int value) => _items.length = value;

  @override
  Message operator [](int index) {
    reads++;
    return _items[index];
  }

  @override
  void operator []=(int index, Message value) => _items[index] = value;

  @override
  void add(Message value) => _items.add(value);

  @override
  bool contains(Object? element) {
    containsCalls++;
    return super.contains(element);
  }

  void resetCounts() {
    reads = 0;
    containsCalls = 0;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final agent = AgentService.I;
  late ChatSession session;
  late _CountedMessages messages;

  setUp(() {
    messages = _CountedMessages();
    session = ChatSession(
      id: 'stream-history-performance',
      title: 'Streaming regression',
      model: 'test',
      messages: messages,
    );
    final run = agent.runBucketForTest(session.id);
    agent.setRunCtxForTest(run, session, run.runEpoch);
  });

  tearDown(() {
    agent.flushStreamRefreshForTest();
    agent.clearRunCtxForTest();
    agent.dropSessionRun(session.id);
  });

  for (final historyLength in [0, 100, 10000]) {
    test('tail streaming has bounded reads with $historyLength old messages', () {
      for (var i = 0; i < historyLength; i++) {
        messages.add(Message(role: 'user', content: 'History $i'));
      }
      agent.streamToBubbleForTest(session, 'start:');
      final bubble = messages.last;
      messages.resetCounts();
      agent.resetStreamPublicationCountForTest();

      for (var i = 0; i < 200; i++) {
        agent.streamToBubbleForTest(session, 'x');
      }
      agent.flushStreamRefreshForTest();

      expect(messages.containsCalls, 0);
      expect(messages.reads, lessThanOrEqualTo(200));
      expect(agent.streamPublicationCountForTest, 1);
      expect(messages.length, historyLength + 1);
      expect(messages.last, same(bubble));
      expect(bubble.content, 'start:${List.filled(200, 'x').join()}');
      expect(bubble.kind, MsgKind.streaming);
      expect(bubble.thinking, isFalse);
    });
  }

  test('a live bubble behind another message is reused', () {
    agent.streamToBubbleForTest(session, 'Hello');
    final bubble = messages.last;
    final other = Message(role: 'user', content: 'interleaved');
    messages.add(other);
    messages.resetCounts();

    agent.streamToBubbleForTest(session, ' world');
    agent.flushStreamRefreshForTest();

    expect(messages.containsCalls, 1);
    expect(messages.length, 2);
    expect(messages.first, same(bubble));
    expect(messages.last, same(other));
    expect(bubble.content, 'Hello world');
    expect(other.content, 'interleaved');
  });

  test('reasoning after an answer does not republish the live bubble', () {
    agent.resetStreamPublicationCountForTest();
    agent.streamToBubbleForTest(session, 'answer');
    agent.flushStreamRefreshForTest();
    final publicationsAfterAnswer = agent.streamPublicationCountForTest;

    agent.streamReasoningForTest(session, 'late thought');

    expect(agent.streamPublicationCountForTest, publicationsAfterAnswer);
    expect(messages.last.content, 'answer');
  });

  test('hidden reasoning settles as transcript-only history', () {
    final previousShowReasoning = AppState.I.showReasoning;
    AppState.I.showReasoning = false;
    try {
      agent.streamReasoningForTest(session, 'private thought');
      agent.finalizeLiveForTest();

      expect(messages, hasLength(1));
      expect(messages.single.kind, MsgKind.reasoning);
      expect(messages.single.thinking, isFalse);
      expect(messages.single.content, 'private thought');

      final request = agent.buildRequestMessages(session, 'system');
      expect(
        request.where((m) => m['content'] == 'private thought'),
        isEmpty,
      );
    } finally {
      AppState.I.showReasoning = previousShowReasoning;
    }
  });

  for (final clearHistory in [false, true]) {
    test('removed bubble is recreated (empty history: $clearHistory)', () {
      messages.add(Message(role: 'user', content: 'history'));
      agent.streamToBubbleForTest(session, 'Hello');
      final removed = messages.removeLast();
      if (clearHistory) messages.clear();
      messages.resetCounts();

      agent.streamToBubbleForTest(session, ' again');
      agent.flushStreamRefreshForTest();

      expect(messages.containsCalls, 1);
      expect(messages.length, clearHistory ? 1 : 2);
      expect(messages.last, isNot(same(removed)));
      expect(messages.last.content, 'Hello again');
      expect(removed.content, 'Hello');
    });
  }
}
