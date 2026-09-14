import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/transcript_model.dart';

/// Optional DSH features (2026-09-13): branch-into-conversation,
/// send-while-busy selector, conversation-display (compact/full).
void main() {
  final app = AppState.I;

  group('branch into a new conversation', () {
    test('copies messages up to the branch point and becomes active', () {
      final src = ChatSession(
        id: 'branch-src',
        title: 'Source',
        model: 'm',
        providerId: 'p1',
        mode: 'studio',
        messages: [
          Message(role: 'user', content: 'one'),
          Message(role: 'assistant', content: 'two'),
          Message(role: 'user', content: 'three'),
        ],
      );
      app.sessions.insert(0, src);
      app.activeSessionId = src.id;
      addTearDown(() {
        app.sessions.removeWhere(
          (x) => x.id == src.id || x.title == 'Source (branch)',
        );
        app.activeSessionId = null;
      });

      final branch = app.branchSessionFrom(src.id, 1);
      expect(branch, isNotNull);
      expect(branch!.messages.length, 2);
      expect(branch.messages.map((m) => m.content), ['one', 'two']);
      expect(branch.title, 'Source (branch)');
      expect(branch.providerId, 'p1');
      expect(branch.mode, 'studio');
      expect(app.activeSessionId, branch.id);
      // The branch is a deep copy: mutating it must not touch the source.
      branch.messages[0].content = 'changed';
      expect(src.messages[0].content, 'one');
    });

    test('returns null for an unknown session or empty range', () {
      expect(app.branchSessionFrom('nope', 0), isNull);
    });
  });

  group('send-while-busy + conversation display prefs', () {
    test('default to queue + compact', () {
      expect(app.sendWhileBusy, 'queue');
      expect(app.sendWhileBusyInterrupt, isFalse);
      expect(app.conversationDisplay, 'compact');
      expect(app.conversationFull, isFalse);
    });

    test('setters accept valid values and reject junk', () async {
      await app.setSendWhileBusy('interrupt');
      expect(app.sendWhileBusyInterrupt, isTrue);
      await app.setSendWhileBusy('bogus');
      expect(app.sendWhileBusy, 'interrupt');

      await app.setConversationDisplay('full');
      expect(app.conversationFull, isTrue);
      await app.setConversationDisplay('bogus');
      expect(app.conversationDisplay, 'full');
      // reset
      await app.setSendWhileBusy('queue');
      await app.setConversationDisplay('compact');
    });
  });

  group('conversation display: compact vs full', () {    List<Message> run() => [
      Message(role: 'assistant', kind: MsgKind.tool, toolName: 'run_shell'),
      Message(
        role: 'assistant',
        kind: MsgKind.reasoning,
        content: 'thinking',
      ),
      Message(role: 'assistant', content: 'answer'),
    ];

    test('compact folds a completed process run', () {
      final items = foldMessages(run(), showReasoning: true);
      expect(items.whereType<FoldedGroup>(), hasLength(1));
    });

    test('full never folds — every row stays visible', () {
      final items = foldMessages(
        run(),
        showReasoning: true,
        compact: false,
      );
      expect(items.whereType<FoldedGroup>(), isEmpty);
      expect(items.whereType<SingleItem>().length, 3);
    });
  });

  group('system prompt disclosure', () {
    test('snapshot round-trips through session JSON', () {
      final s = ChatSession(
        id: 'sys-src',
        title: 'S',
        model: 'm',
        systemPromptSnapshot: 'You are Ovid.\nAccess mode: AUTO',
      );
      final restored = ChatSession.fromJson(s.toJson());
      expect(restored.systemPromptSnapshot, contains('Access mode: AUTO'));
    });

    test('the transcript renders a System prompt disclosure', () {
      final src = File('lib/ui/chat_screen.dart').readAsStringSync();
      expect(src.contains('_SystemPromptRow'), isTrue);
      expect(src.contains("'System prompt'"), isTrue);
      expect(src.contains('chat-system-prompt-row'), isTrue);
      // Captured in the run body (system prompt plus the trailing
      // volatile block, so the snapshot still shows the model's complete
      // instruction set).
      final agent = File('lib/core/agent_service.dart').readAsStringSync();
      expect(agent.contains('systemPromptSnapshot'), isTrue);
      expect(agent.contains('volatileCtx'), isTrue);
    });
  });
}
