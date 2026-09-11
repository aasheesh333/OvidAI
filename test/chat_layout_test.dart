import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/chat_layout.dart';

void main() {
  group('ChatLayout', () {
    test('content width is centered and capped', () {
      expect(const ChatLayout(viewportWidth: 1400).contentWidth, 896); // 64%
      expect(const ChatLayout(viewportWidth: 2000).contentWidth, 920); // capped
      expect(const ChatLayout(viewportWidth: 400).contentWidth, 400); // pane-bound
    });

    test('composer is the column plus 32px, capped to the viewport', () {
      expect(const ChatLayout(viewportWidth: 1400).composerWidth, 928);
      // A narrow pane cannot grow a composer wider than the viewport.
      expect(const ChatLayout(viewportWidth: 400).composerWidth, 400);
    });

    test('user bubble is three quarters of the column', () {
      expect(const ChatLayout(viewportWidth: 1400).userBubbleMaxWidth, 672);
      expect(const ChatLayout(viewportWidth: 400).userBubbleMaxWidth, 300);
    });

    test('sidebar narrows the pane before the width clamps', () {
      final layout = const ChatLayout(viewportWidth: 1400, sidebarWidth: 300);
      expect(layout.contentWidth, (1100 * 0.64).clamp(680.0, 920.0));
    });

    test('zero and negative viewports collapse to zero', () {
      expect(const ChatLayout(viewportWidth: 0).contentWidth, 0);
      expect(const ChatLayout(viewportWidth: 0).composerWidth, 0);
      expect(const ChatLayout(viewportWidth: -10).contentWidth, 0);
      expect(const ChatLayout(viewportWidth: -10).userBubbleMaxWidth, 0);
    });
  });
}
