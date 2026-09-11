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

/// Test instrumentation seam: the number of messages passed through
/// [foldMessages] and the number of invocations since the last
/// [resetTranscriptFoldStats]. Purely diagnostic — production logic never
/// reads these.
int transcriptFoldedMessages = 0;
int transcriptFoldInvocations = 0;

/// Resets the [foldMessages] instrumentation counters.
void resetTranscriptFoldStats() {
  transcriptFoldedMessages = 0;
  transcriptFoldInvocations = 0;
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
  transcriptFoldInvocations++;
  transcriptFoldedMessages += messages.length;
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

  /// How many folded items sit above [visible] *inside the folded region*.
  /// For [windowFor] this is exact; for [windowForBounded] it counts only
  /// the items in the tail region that was folded — use [hasEarlier] /
  /// [hiddenMessages] to decide whether older history exists.
  final int hiddenCount;

  /// The number of folded items in the folded region (the full history for
  /// [windowFor], the bounded tail for [windowForBounded]).
  final int totalFolded;

  /// True when messages older than [visible] exist. The authoritative
  /// "load earlier" signal for the pager.
  final bool hasEarlier;

  /// How many raw messages sit above the first visible item. Drives the
  /// "N earlier messages" affordance.
  final int hiddenMessages;

  const TranscriptWindow({
    required this.visible,
    required this.hiddenCount,
    required this.totalFolded,
    this.hasEarlier = false,
    this.hiddenMessages = 0,
  });
}

int _itemStartIndex(ChatItem item) {
  if (item is SingleItem) return item.index;
  final indices = (item as FoldedGroup).indices;
  return indices.isEmpty ? 0 : indices.first;
}

/// Rebases folded items' indices onto the full [messages] list so callers
/// (delete/edit/isLast) can treat them as absolute positions.
List<ChatItem> _rebase(List<ChatItem> items, int offset) {
  if (offset == 0) return items;
  final out = <ChatItem>[];
  for (final item in items) {
    if (item is SingleItem) {
      out.add(SingleItem(item.m, item.index + offset));
    } else {
      final group = item as FoldedGroup;
      out.add(
        FoldedGroup(group.msgs, [for (final i in group.indices) i + offset]),
      );
    }
  }
  return out;
}

bool _isFoldable(Message m) =>
    m.role == 'assistant' &&
    (m.kind == MsgKind.tool || m.kind == MsgKind.reasoning) &&
    !m.thinking;

/// Folds the entire [messages] list once and returns the newest
/// [visibleCount] items plus the count hidden above them.
///
/// Semantics (Task 1 review M2): [pageSize] is the default window when
/// [visibleCount] is not positive; [visibleCount] is the pager's *cumulative*
/// request and MAY exceed [pageSize] — the newest `min(visibleCount, total)`
/// items are returned. This is the unbounded reference implementation; the
/// chat surface uses [windowForBounded] so a large history is not folded.
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
  final hiddenMessages = visible.isEmpty ? 0 : _itemStartIndex(visible.first);
  return TranscriptWindow(
    visible: visible,
    hiddenCount: hidden,
    totalFolded: total,
    hasEarlier: hidden > 0,
    hiddenMessages: hiddenMessages,
  );
}

/// Bounded variant of [windowFor]: folds only the tail of [messages] needed
/// to fill the newest [visibleCount] folded items (or [pageSize] when
/// [visibleCount] is not positive), never the whole history for a small
/// window.
///
/// Semantics (Task 1 review M2): [pageSize] is the initial window;
/// [visibleCount] is the pager's cumulative request and MAY exceed
/// [pageSize]. The result is identical to the tail of a full [windowFor]
/// fold — the tail start is snapped to a foldable-run boundary so a run is
/// never split — but [hiddenCount]/[totalFolded] describe only the folded
/// tail. Use [TranscriptWindow.hasEarlier] to page and
/// [TranscriptWindow.hiddenMessages] for the "earlier messages" label.
TranscriptWindow windowForBounded(
  List<Message> messages, {
  required int pageSize,
  required int visibleCount,
  required bool showReasoning,
}) {
  final requested = visibleCount > 0 ? visibleCount : pageSize;
  if (messages.isEmpty || requested <= 0) {
    return TranscriptWindow(
      visible: const [],
      hiddenCount: 0,
      totalFolded: 0,
      hasEarlier: messages.isNotEmpty,
      hiddenMessages: messages.length,
    );
  }
  final total = messages.length;
  var span = requested;
  var folded = const <ChatItem>[];
  while (true) {
    var candidate = total - span;
    if (candidate < 0) candidate = 0;
    // Snap back to a foldable-run boundary: folding the suffix then matches
    // the corresponding suffix of a full-history fold (no run is split).
    while (candidate > 0 && _isFoldable(messages[candidate - 1])) {
      candidate--;
    }
    folded = _rebase(
      foldMessages(
        candidate == 0 ? messages : messages.sublist(candidate),
        showReasoning: showReasoning,
      ),
      candidate,
    );
    if (folded.length >= requested || candidate == 0) {
      break;
    }
    span *= 2;
  }
  final take = requested < folded.length ? requested : folded.length;
  final hiddenItems = folded.length - take;
  final visible = hiddenItems > 0 ? folded.sublist(hiddenItems) : folded;
  final hiddenMessages = visible.isEmpty
      ? total
      : _itemStartIndex(visible.first);
  return TranscriptWindow(
    visible: visible,
    hiddenCount: hiddenItems,
    totalFolded: folded.length,
    hasEarlier: hiddenMessages > 0,
    hiddenMessages: hiddenMessages,
  );
}
