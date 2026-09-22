import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/transcript_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stop/output/result rendering (worker WS3):
/// 1. stopRequested interrupts the whole run tree (children + grandchildren).
/// 2. Events/tokens from a stale run epoch are dropped — nothing renders
///    after Stop.
/// 3. The live bubble is born as MsgKind.streaming (never reasoning) and
///    finalizes as text; reasoning-only turns settle (no stuck shimmer).
/// 4. foldMessages never folds the final answer into the collapsed strip.
/// 5. Settlement notices: parent stopped -> no-op; parent idle -> passive
///    row, never a new runTask.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final agent = AgentService.I;
  final app = AppState.I;

  ChatSession session(String id) =>
      ChatSession(id: id, title: 'T', model: 'm', mode: 'auto');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    app.sessions.clear();
    app.activeSessionId = null;
  });

  tearDown(() async {
    agent.clearRunCtxForTest();
    agent.clearSubagentsForTest();
    for (final id in [
      'stop-p',
      'stop-c',
      'stop-g',
      'ep-s',
      'bub-s',
      'bub-r',
      'settle-p',
      'settle-c',
    ]) {
      agent.dropSessionRun(id);
    }
    app.sessions.clear();
    app.activeSessionId = null;
  });

  group('stopRequested interrupts the run tree', () {
    test('child and grandchild subagents are interrupted, no output after',
        () async {
      final parent = session('stop-p');
      final child = session('stop-c');
      app.sessions.addAll([parent, child]);
      app.activeSessionId = parent.id;

      final parentBucket = agent.runBucketForTest(parent.id)
        ..activeRunId = 'run-p';
      final childBucket = agent.runBucketForTest(child.id)
        ..activeRunId = 'run-c';

      final sub1 = SubagentInfo(
        id: 'sub-1',
        label: 'child',
        sessionId: child.id,
        parentSessionId: parent.id,
        parentMode: AgentMode.auto,
        prompt: 'x',
        background: true,
      );
      final sub2 = SubagentInfo(
        id: 'sub-2',
        label: 'grandchild',
        sessionId: 'stop-g',
        parentSessionId: child.id,
        parentMode: AgentMode.auto,
        prompt: 'y',
        background: true,
      );
      agent.registerSubagentForTest(sub1);
      agent.registerSubagentForTest(sub2);

      // Pin a stale chain: epoch 0, then Stop bumps the bucket to 1.
      agent.setRunCtxForTest(parentBucket, parent, 0);

      agent.stopRequested(sessionId: parent.id);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // The whole tree is interrupted…
      expect(sub1.interrupted, isTrue);
      expect(sub2.interrupted, isTrue);
      // …and the child's own run bucket is cancelled promptly.
      expect(childBucket.cancelRequested, isTrue);
      expect(childBucket.activeRunId, isNull);
      // The parent run is cancelled too.
      expect(parentBucket.cancelRequested, isTrue);

      // Nothing renders after Stop: a stale chain's event is dropped.
      final before = parentBucket.runEvents.length;
      agent.emitToRunForTest(parentBucket, 'think', 'late event');
      expect(parentBucket.runEvents.length, before);
      expect(
        parentBucket.runEvents.map((e) => e.text),
        isNot(contains('late event')),
      );
      // …and stale streaming tokens never spawn a bubble.
      final msgCount = parent.messages.length;
      agent.streamToBubbleForTest(parent, 'late token');
      expect(parent.messages.length, msgCount);

      // Zone-less emits (the stop path's own ack) still pass through.
      agent.clearRunCtxForTest();
      agent.emitToRunForTest(parentBucket, 'think', 'ui-thread event');
      expect(
        parentBucket.runEvents.map((e) => e.text),
        contains('ui-thread event'),
      );
    });

    test('stale epoch from a superseded run is dropped', () {
      final s = session('ep-s');
      app.sessions.add(s);
      final bucket = agent.runBucketForTest(s.id);

      // Live generation: epoch 7 == bucket epoch 7 → renders.
      bucket.runEpoch = 7;
      agent.setRunCtxForTest(bucket, s, 7);
      agent.emitToRunForTest(bucket, 'think', 'fresh');
      expect(bucket.runEvents.map((e) => e.text), contains('fresh'));

      // A newer generation took over (epoch 8): the old chain is stale.
      bucket.runEpoch = 8;
      agent.emitToRunForTest(bucket, 'think', 'stale');
      expect(bucket.runEvents.map((e) => e.text), isNot(contains('stale')));

      // The new generation's own chain still renders.
      agent.setRunCtxForTest(bucket, s, 8);
      agent.emitToRunForTest(bucket, 'think', 'new-gen');
      expect(bucket.runEvents.map((e) => e.text), contains('new-gen'));
    });
  });

  group('live bubble kind and finalization', () {
    test('bubble is born streaming, finalizes as text', () {
      final s = session('bub-s');
      app.sessions.add(s);
      final bucket = agent.runBucketForTest(s.id);
      agent.setRunCtxForTest(bucket, s, bucket.runEpoch);

      agent.ensureLiveMsgForTest(s);
      final bubble = s.messages.last;
      expect(bubble.kind, MsgKind.streaming,
          reason: 'never born as reasoning');
      expect(bubble.thinking, isTrue);

      agent.streamToBubbleForTest(s, 'Hello ');
      agent.streamToBubbleForTest(s, 'world');
      expect(s.messages.last.content, 'Hello world');
      expect(s.messages.last.thinking, isFalse);

      agent.finalizeLiveForTest();
      final done = s.messages.last;
      expect(done.kind, MsgKind.text);
      expect(done.thinking, isFalse);
      expect(done.content, 'Hello world');
    });

    test('reasoning-only turn settles as reasoning without stuck shimmer',
        () {
      final s = session('bub-r');
      app.sessions.add(s);
      final bucket = agent.runBucketForTest(s.id);
      agent.setRunCtxForTest(bucket, s, bucket.runEpoch);

      agent.ensureLiveMsgForTest(s);
      agent.streamReasoningForTest(s, 'hmm, thinking…');
      agent.finalizeLiveForTest();

      final done = s.messages.last;
      expect(done.kind, MsgKind.reasoning);
      expect(done.thinking, isFalse,
          reason: 'never left reasoning+thinking=true hiding content');
      expect(done.content, contains('hmm'));
    });

    test('stopped bubble never leaves thinking=true', () {
      final s = session('bub-s');
      app.sessions.add(s);
      final bucket = agent.runBucketForTest(s.id);
      agent.setRunCtxForTest(bucket, s, bucket.runEpoch);

      agent.ensureLiveMsgForTest(s);
      agent.streamReasoningForTest(s, 'partial thought');
      agent.finalizeLiveStoppedForTest();

      final done = s.messages.last;
      expect(done.thinking, isFalse);
      expect(done.content, contains('stopped by user'));
    });
  });

  group('foldMessages keeps the final answer unfolded', () {
    Message tool(String c) => Message(
          role: 'assistant',
          kind: MsgKind.tool,
          content: c,
        );
    Message answer(String c) => Message(
          role: 'assistant',
          kind: MsgKind.text,
          content: c,
        );

    test('trailing text answer is excluded from the folded strip', () {
      final items = foldMessages(
        [tool('a'), tool('b'), answer('done')],
        showReasoning: true,
      );
      expect(items, hasLength(2));
      expect(items[0], isA<FoldedGroup>());
      expect((items[0] as FoldedGroup).msgs.map((m) => m.content),
          ['a', 'b']);
      expect(items[1], isA<SingleItem>());
      expect((items[1] as SingleItem).m.content, 'done');
    });

    test('a live streaming message is never folded', () {
      final live = Message(
        role: 'assistant',
        kind: MsgKind.streaming,
        thinking: true,
        content: 'partial',
      );
      final items = foldMessages(
        [tool('a'), tool('b'), live],
        showReasoning: true,
      );
      expect(items.every((i) => i is SingleItem), isTrue);
      expect(items, hasLength(3));
    });

    test('final reasoning-only row stays unfolded at the end', () {
      final items = foldMessages(
        [
          tool('a'),
          tool('b'),
          Message(
            role: 'assistant',
            kind: MsgKind.reasoning,
            thinking: false,
            content: 'thoughts',
          ),
        ],
        showReasoning: true,
      );
      expect(items.every((i) => i is SingleItem), isTrue);
    });
  });

  group('settlement notices', () {
    SubagentInfo bgSub(String parentId) => SubagentInfo(
          id: 'bg-1',
          label: 'Researcher',
          sessionId: 'settle-c',
          parentSessionId: parentId,
          parentMode: AgentMode.auto,
          prompt: 'x',
          background: true,
        )
          ..finished = true
          ..result = 'found it';

    test('idle parent gets a passive row, never a new run', () {
      final parent = session('settle-p');
      parent.messages.add(Message(role: 'user', content: 'hi'));
      app.sessions.add(parent);
      app.activeSessionId = parent.id;
      agent.runBucketForTest(parent.id); // idle bucket

      agent.deliverSettlementNoticeForTest(bgSub(parent.id));

      final last = parent.messages.last;
      expect(last.kind, MsgKind.turnTail,
          reason: 'passive notice row, not a user row');
      expect(last.content, contains('finished'));
      // The old behavior (user-role notice + runTask) is gone: no user
      // row was appended and no provider-setup error from a stray run.
      expect(
        parent.messages
            .where(
                (m) => m.role == 'user' && m.content.contains('Background')),
        isEmpty,
      );
      expect(
        parent.messages
            .where((m) => m.content.contains('Provider setup required')),
        isEmpty,
      );
    });

    test('stopped parent gets no notice at all', () {
      final parent = session('settle-p');
      parent.messages.add(Message(role: 'user', content: 'hi'));
      app.sessions.add(parent);
      final bucket = agent.runBucketForTest(parent.id)
        ..stoppedByUser = true;

      final before = parent.messages.length;
      agent.deliverSettlementNoticeForTest(bgSub(parent.id));

      expect(parent.messages.length, before);
      expect(bucket.stoppedByUser, isTrue);
    });
  });
}
