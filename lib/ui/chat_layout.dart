import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Pure width axis shared by the transcript, docks, and composer.
///
/// Mirrors the DeepSeek web clamp semantics without importing any of its
/// tokens: one readable column (680–920px, 64% of the chat pane), a composer
/// card 32px wider than that column, and a compact user bubble at 75% of it.
class ChatLayout {
  final double viewportWidth;
  final double sidebarWidth;

  const ChatLayout({required this.viewportWidth, this.sidebarWidth = 0});

  /// The single readable column width for transcript rows, docks, and the
  /// composer card.
  double get contentWidth {
    final pane = (viewportWidth - sidebarWidth).clamp(0.0, double.infinity);
    return (pane * 0.64).clamp(680.0, 920.0).clamp(0.0, pane);
  }

  /// Composer card is slightly wider than the transcript column.
  double get composerWidth => (contentWidth + 32).clamp(0.0, viewportWidth);

  /// User bubble is a compact fraction of the column.
  double get userBubbleMaxWidth =>
      (contentWidth * 0.75).clamp(0.0, contentWidth);
}

// ═══════════════════════════════════════════════════════════════════════
// Wave-2 UI redesign — Aether transcript primitives.
//
// [ChatLayout] above stays the pure width axis (behavior pinned by
// test/chat_layout_test.dart). The widgets below are the Aether rendering
// of the three transcript row kinds: message rows sit on [AetherSurface],
// tool-call bubbles are [AetherCard]s, and live/final state is an
// [AetherPill]. They are additive — `chat_screen.dart` keeps its own rows —
// so no layout, scroll, or streaming behavior changes.
// ═══════════════════════════════════════════════════════════════════════

/// Low-level Aether surface: rounded corner, hairline border, soft shadow.
///
/// Base container for transcript message rows. [AetherCard] is deliberately
/// NOT used for plain messages — rows need a bare padded surface, not
/// header/footer section chrome. The construction mirrors [AetherCard]'s
/// surface treatment so rows and cards read as one material.
class AetherSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final double radius;

  const AetherSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    this.color,
    this.radius = AetherRadius.rLg,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Aether.hairline),
        boxShadow: AetherShadows.shadowS,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: color ?? Aether.surface,
        borderRadius: BorderRadius.circular(radius),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// One transcript message row on the shared [ChatLayout] width axis.
///
/// User rows align right and cap at [ChatLayout.userBubbleMaxWidth] on an
/// accent-tinted [AetherSurface]; assistant rows align left and cap at
/// [ChatLayout.contentWidth] on the plain surface. An optional [statusLabel]
/// renders as an [AetherPill] above the bubble (streaming/thinking state);
/// [footer] is the per-message action-row slot underneath.
class ChatMessageRow extends StatelessWidget {
  final ChatLayout layout;
  final bool isUser;
  final Widget child;

  /// Key applied to the bubble surface so callers/tests can pin geometry
  /// (e.g. `ValueKey('chat-user-bubble-$msgIndex')`).
  final Key? bubbleKey;
  final String? statusLabel;
  final Color? statusColor;
  final Widget? footer;

  const ChatMessageRow({
    super.key,
    required this.layout,
    required this.isUser,
    required this.child,
    this.bubbleKey,
    this.statusLabel,
    this.statusColor,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (statusLabel != null) ...[
            AetherPill(
              label: statusLabel!,
              color: statusColor ?? Aether.accent,
            ),
            const SizedBox(height: 6),
          ],
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: isUser
                  ? layout.userBubbleMaxWidth
                  : layout.contentWidth,
            ),
            child: AetherSurface(
              key: bubbleKey,
              color: isUser ? Aether.accentSoft : Aether.surface,
              child: DefaultTextStyle.merge(
                style: AetherType.body,
                child: child,
              ),
            ),
          ),
          ?footer,
        ],
      ),
    );
  }
}

/// Live/final state of a tool-call bubble, mirrored from the transcript's
/// `toolState` strings ('running'/'error'/'stopped'/'unknown', else done).
enum ChatToolState { running, done, error, stopped, unknown }

/// Tool-call bubble: an [AetherCard] whose header carries the tool icon,
/// title, and one-line summary, with the [state] shown as a trailing
/// [AetherPill]. When [detail] is present the card body discloses the full
/// detail in a mono code block on tap.
class ChatToolCallCard extends StatefulWidget {
  final ChatToolState state;
  final IconData icon;
  final String title;
  final String? summary;
  final String? detail;

  const ChatToolCallCard({
    super.key,
    required this.state,
    required this.title,
    this.icon = Icons.bolt_outlined,
    this.summary,
    this.detail,
  });

  /// Human label for [state] shown in the trailing [AetherPill].
  static String stateLabel(ChatToolState state) => switch (state) {
    ChatToolState.running => 'Running',
    ChatToolState.done => 'Done',
    ChatToolState.error => 'Error',
    ChatToolState.stopped => 'Stopped',
    ChatToolState.unknown => 'Unknown',
  };

  /// Pill color for [state]; matches the transcript's state-dot palette.
  static Color stateColor(ChatToolState state) => switch (state) {
    ChatToolState.running => Aether.accent,
    ChatToolState.done => Aether.successC,
    ChatToolState.error => Aether.dangerC,
    ChatToolState.stopped => Aether.warnLight,
    ChatToolState.unknown => Aether.textFaint,
  };

  @override
  State<ChatToolCallCard> createState() => _ChatToolCallCardState();
}

class _ChatToolCallCardState extends State<ChatToolCallCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final hasDetail = (widget.detail ?? '').trim().isNotEmpty;
    return AetherCard(
      padding: const EdgeInsets.all(12),
      title: Row(
        children: [
          Icon(widget.icon, size: 14, color: Aether.textMuted),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AetherType.title.copyWith(fontSize: 12),
            ),
          ),
          if ((widget.summary ?? '').isNotEmpty) ...[
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                widget.summary!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: Aether.textMuted,
                  fontFamily: Aether.mono,
                ),
              ),
            ),
          ],
        ],
      ),
      trailing: AetherPill(
        label: ChatToolCallCard.stateLabel(widget.state),
        color: ChatToolCallCard.stateColor(widget.state),
      ),
      child: hasDetail
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  key: const ValueKey('chat-tool-card-toggle'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => setState(() => _open = !_open),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Details', style: AetherType.label),
                        const SizedBox(width: 4),
                        AnimatedRotation(
                          turns: _open ? 0.5 : 0.0,
                          duration: const Duration(milliseconds: 150),
                          child: Icon(
                            Icons.expand_more,
                            size: 16,
                            color: Aether.textFaint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_open)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Aether.codeBg,
                      borderRadius: BorderRadius.circular(AetherRadius.rSm),
                    ),
                    child: Text(
                      widget.detail!,
                      style: AetherType.mono.copyWith(color: Aether.textMuted),
                    ),
                  ),
              ],
            )
          : const SizedBox.shrink(),
    );
  }
}
