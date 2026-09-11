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
