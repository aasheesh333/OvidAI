import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/transcript_model.dart';

Message _msg(
  String content, {
  String role = 'user',
  MsgKind kind = MsgKind.text,
  bool thinking = false,
}) => Message(role: role, kind: kind, content: content, thinking: thinking);

Message _user(String content) => _msg(content);

Message _answer(String content) =>
    _msg(content, role: 'assistant', kind: MsgKind.text);

Message _tool(String content, {bool thinking = false}) =>
    _msg(content, role: 'assistant', kind: MsgKind.tool, thinking: thinking);

Message _reason(String content, {bool thinking = false}) =>
    _msg(content, role: 'assistant', kind: MsgKind.reasoning, thinking: thinking);

void main() {
  group('foldMessages', () {
    test('passes non-foldable messages through in order with indices', () {
      final messages = [_user('hi'), _answer('hello')];
      final items = foldMessages(messages, showReasoning: false);
      expect(items, hasLength(2));
      expect(items[0], isA<SingleItem>());
      expect((items[0] as SingleItem).m.content, 'hi');
      expect((items[0] as SingleItem).index, 0);
      expect(items[1], isA<SingleItem>());
      expect((items[1] as SingleItem).m.content, 'hello');
      expect((items[1] as SingleItem).index, 1);
    });

    test('folds a run of two tool calls followed by an answer', () {
      final messages = [_tool('a'), _tool('b'), _answer('done')];
      final items = foldMessages(messages, showReasoning: false);
      expect(items, hasLength(2));
      expect(items[0], isA<FoldedGroup>());
      final group = items[0] as FoldedGroup;
      expect(group.msgs.map((m) => m.content), ['a', 'b']);
      expect(group.indices, [0, 1]);
      expect(items[1], isA<SingleItem>());
      expect((items[1] as SingleItem).m.content, 'done');
    });

    test('does not fold a lone tool call', () {
      final messages = [_tool('a'), _answer('done')];
      final items = foldMessages(messages, showReasoning: false);
      expect(items, hasLength(2));
      expect(items[0], isA<SingleItem>());
      expect(items[1], isA<SingleItem>());
    });

    test('keeps a trailing run unfolded when no text follows', () {
      final messages = [_tool('a'), _tool('b')];
      final items = foldMessages(messages, showReasoning: false);
      expect(items, hasLength(2));
      expect(items.every((it) => it is SingleItem), isTrue);
    });

    test('folds a run followed by any text row', () {
      // The fold looks ahead for a text row; a user text row counts too.
      final messages = [_tool('a'), _tool('b'), _user('next')];
      final items = foldMessages(messages, showReasoning: false);
      expect(items, hasLength(2));
      expect(items[0], isA<FoldedGroup>());
      expect(items[1], isA<SingleItem>());
    });

    test('skips reasoning rows when showReasoning is false', () {
      final messages = [_user('q'), _reason('thinking'), _answer('a')];
      final items = foldMessages(messages, showReasoning: false);
      expect(items, hasLength(2));
      expect(items.map((it) => (it as SingleItem).m.content), ['q', 'a']);
    });

    test('keeps and folds reasoning rows when showReasoning is true', () {
      final messages = [_reason('r1'), _reason('r2'), _answer('a')];
      final items = foldMessages(messages, showReasoning: true);
      expect(items, hasLength(2));
      expect(items[0], isA<FoldedGroup>());
      expect((items[0] as FoldedGroup).msgs.map((m) => m.content), [
        'r1',
        'r2',
      ]);
    });

    test('thinking rows are never folded', () {
      final messages = [
        _tool('a', thinking: true),
        _tool('b', thinking: true),
        _answer('done'),
      ];
      final items = foldMessages(messages, showReasoning: false);
      expect(items, hasLength(3));
      expect(items.every((it) => it is SingleItem), isTrue);
    });

    test('is deterministic for the same input', () {
      final messages = [_tool('a'), _tool('b'), _answer('done')];
      final first = foldMessages(messages, showReasoning: false);
      final second = foldMessages(messages, showReasoning: false);
      expect(first.length, second.length);
      expect(first[0], isA<FoldedGroup>());
      expect(second[0], isA<FoldedGroup>());
      expect((first[0] as FoldedGroup).indices, (second[0] as FoldedGroup).indices);
    });
  });

  group('windowFor', () {
    test('returns only the requested tail and counts the hidden items', () {
      final messages = List.generate(5000, (i) => _msg('m$i'));
      final w = windowFor(
        messages,
        pageSize: 40,
        visibleCount: 40,
        showReasoning: false,
      );
      expect(w.visible.length, lessThanOrEqualTo(40));
      expect(w.visible.length, 40);
      expect(w.hiddenCount, 4960);
      expect(w.totalFolded, 5000);
      expect((w.visible.last as SingleItem).m.content, 'm4999');
    });

    test('returns everything when the window covers the history', () {
      final messages = List.generate(10, (i) => _msg('m$i'));
      final w = windowFor(
        messages,
        pageSize: 40,
        visibleCount: 40,
        showReasoning: false,
      );
      expect(w.visible.length, 10);
      expect(w.hiddenCount, 0);
      expect(w.totalFolded, 10);
    });

    test('defaults to pageSize when visibleCount is not positive', () {
      final messages = List.generate(100, (i) => _msg('m$i'));
      final w = windowFor(
        messages,
        pageSize: 40,
        visibleCount: 0,
        showReasoning: false,
      );
      expect(w.visible.length, 40);
      expect(w.hiddenCount, 60);
      expect(w.totalFolded, 100);
    });

    test('respects showReasoning when folding the window', () {
      final messages = [_user('q'), _reason('r'), _answer('a')];
      final hidden = windowFor(
        messages,
        pageSize: 40,
        visibleCount: 40,
        showReasoning: false,
      );
      final shown = windowFor(
        messages,
        pageSize: 40,
        visibleCount: 40,
        showReasoning: true,
      );
      expect(hidden.totalFolded, 2);
      expect(shown.totalFolded, 3);
    });

    test('visible is the tail slice of the full fold', () {
      final messages = List.generate(100, (i) => _msg('m$i'));
      final all = foldMessages(messages, showReasoning: false);
      final w = windowFor(
        messages,
        pageSize: 10,
        visibleCount: 10,
        showReasoning: false,
      );
      expect(w.visible.length, 10);
      expect(
        (w.visible.first as SingleItem).m.content,
        (all[all.length - 10] as SingleItem).m.content,
      );
    });
  });

  group('Show reasoning: off (F-128)', () {
    Iterable<Message> flatten(List<ChatItem> items) sync* {
      for (final item in items) {
        if (item is SingleItem) {
          yield item.m;
        } else {
          yield* (item as FoldedGroup).msgs;
        }
      }
    }

    test('hides reasoning rows that follow a tool row', () {
      final messages = [
        _user('u'),
        _tool('t1'),
        _reason('r1'),
        _tool('t2'),
        _answer('done'),
      ];
      final items = foldMessages(messages, showReasoning: false);
      expect(
        flatten(items).where((m) => m.kind == MsgKind.reasoning),
        isEmpty,
      );
      // The run still folds around the hidden row.
      expect(items[1], isA<FoldedGroup>());
      expect((items[1] as FoldedGroup).indices, [1, 3]);
    });

    test('hides a lone reasoning row after a single tool', () {
      final messages = [_tool('t1'), _reason('r1'), _answer('done')];
      final items = foldMessages(messages, showReasoning: false);
      expect(flatten(items).map((m) => m.content), ['t1', 'done']);
    });

    test('keeps reasoning when the setting is on', () {
      final messages = [_tool('t1'), _reason('r1'), _tool('t2'), _answer('x')];
      final items = foldMessages(messages, showReasoning: true);
      expect(
        flatten(items).where((m) => m.kind == MsgKind.reasoning),
        hasLength(1),
      );
    });

    test('bounded window equals the tail of windowFor', () {
      final messages = <Message>[];
      for (var n = 0; n < 40; n++) {
        messages
          ..add(_user('u$n'))
          ..add(_tool('a$n'))
          ..add(_reason('r$n'))
          ..add(_tool('b$n'))
          ..add(_reason('s$n'))
          ..add(_answer('done$n'));
      }
      for (final count in [1, 2, 3, 5, 9, 20, 77]) {
        final full = windowFor(
          messages,
          pageSize: count,
          visibleCount: count,
          showReasoning: false,
        );
        final bounded = windowForBounded(
          messages,
          pageSize: count,
          visibleCount: count,
          showReasoning: false,
        );
        String sig(ChatItem i) => i is SingleItem
            ? 's${i.index}'
            : 'g${(i as FoldedGroup).indices.join(',')}';
        expect(
          bounded.visible.map(sig).toList(),
          full.visible.map(sig).toList(),
          reason: 'count=$count',
        );
        expect(
          flatten(bounded.visible).where((m) => m.kind == MsgKind.reasoning),
          isEmpty,
        );
      }
    });
  });
}
