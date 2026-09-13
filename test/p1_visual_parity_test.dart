import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// P1 (2026-09-13): visual-parity pins for the home/chat surface. These are
/// source pins (the repo's existing pattern for UI-shape invariants) so a
/// regression that reintroduces the removed pill or drops the faint hint
/// fails loudly.
void main() {
  late String chat;

  setUpAll(() {
    chat = File('lib/ui/chat_screen.dart').readAsStringSync();
  });

  test('the home hero no longer renders the "preview" pill', () {
    expect(chat.contains("'preview'"), isFalse);
  });

  test('the composer hint is explicitly faint', () {
    // The hint style block must set a faint color.
    final idx = chat.indexOf('hintStyle: TextStyle(');
    expect(idx, greaterThan(0));
    final block = chat.substring(idx, idx + 320);
    expect(block.contains('Aether.textFaint'), isTrue);
  });

  test('the AI question card is bounded and scrollable', () {
    expect(chat.contains('SingleChildScrollView'), isTrue);
    // The questions card wraps its list in a max-height scroll view.
    final q = chat.indexOf('class _QuestionsCard');
    expect(q, greaterThan(0));
    final body = chat.substring(q);
    expect(body.contains('ConstrainedBox'), isTrue);
    expect(body.contains('maxHeight'), isTrue);
  });

  test('the model picker surfaces a Recent section', () {
    expect(chat.contains("'Recent'"), isTrue);
  });
}
