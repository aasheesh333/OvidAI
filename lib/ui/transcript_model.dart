import '../core/state.dart';

/// One row of the folded transcript: either a single message or a collapsed
/// run of consecutive assistant tool/reasoning messages.
sealed class ChatItem {
  const ChatItem();
}

class SingleItem extends ChatItem {
  final Message m;
  final int index;

  const SingleItem(this.m, this.index);
}

class FoldedGroup extends ChatItem {
  final List<Message> msgs;
  final List<int> indices;

  const FoldedGroup(this.msgs, this.indices);
}

/// Folds consecutive assistant tool/reasoning messages into a single
/// expandable strip when the run is complete (followed by an assistant text
/// answer). The last, still-in-progress run stays unfolded.
///
/// Pure: callers pass [showReasoning]; this never reads global state.
List<ChatItem> foldMessages(
  List<Message> messages, {
  required bool showReasoning,
}) {
  final out = <ChatItem>[];
  var i = 0;
  while (i < messages.length) {
    final m = messages[i];
    // Reasoning display toggle (Settings): OFF → skip thinking chips.
    // Data stays in the session; only display is suppressed.
    if (m.kind == MsgKind.reasoning && !showReasoning) {
      i++;
      continue;
    }
    final foldable =
        m.role == 'assistant' &&
        (m.kind == MsgKind.tool || m.kind == MsgKind.reasoning) &&
        !m.thinking;
    if (!foldable) {
      out.add(SingleItem(m, i));
      i++;
      continue;
    }
    // Collect the foldable run.
    final group = <Message>[];
    final idx = <int>[];
    while (i < messages.length &&
        messages[i].role == 'assistant' &&
        (messages[i].kind == MsgKind.tool ||
            messages[i].kind == MsgKind.reasoning) &&
        !messages[i].thinking) {
      group.add(messages[i]);
      idx.add(i);
      i++;
    }
    // Look ahead: if the NEXT message is a text answer, this group is
    // complete → fold it. If the group runs to the end, keep it unfolded
    // (still in progress / latest).
    final nextIsAnswer =
        i < messages.length && messages[i].kind == MsgKind.text;
    if (group.length >= 2 && nextIsAnswer) {
      out.add(FoldedGroup(group, idx));
    } else {
      for (var j = 0; j < group.length; j++) {
        out.add(SingleItem(group[j], idx[j]));
      }
    }
  }
  return out;
}

/// The bounded tail of a folded transcript.
class TranscriptWindow {
  /// At most the requested number of newest folded items.
  final List<ChatItem> visible;

  /// How many folded items sit above [visible].
  final int hiddenCount;

  /// The total number of folded items in the full history.
  final int totalFolded;

  const TranscriptWindow({
    required this.visible,
    required this.hiddenCount,
    required this.totalFolded,
  });
}

/// Folds [messages] once and returns the newest [visibleCount] items plus the
/// count hidden above them. [pageSize] is the default window when
/// [visibleCount] is not positive.
TranscriptWindow windowFor(
  List<Message> messages, {
  required int pageSize,
  required int visibleCount,
  required bool showReasoning,
}) {
  final all = foldMessages(messages, showReasoning: showReasoning);
  final total = all.length;
  final requested = visibleCount > 0 ? visibleCount : pageSize;
  final take = requested < 0
      ? 0
      : (requested > total ? total : requested);
  final hidden = total - take;
  final visible = hidden > 0 ? all.sublist(total - take) : all;
  return TranscriptWindow(
    visible: visible,
    hiddenCount: hidden,
    totalFolded: total,
  );
}
