import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// P1 (2026-09-13): visual-parity pins for the home/chat surface. These are
/// source pins (the repo's existing pattern for UI-shape invariants) so a
/// regression that reintroduces the removed pill or drops the faint hint
/// fails loudly.
///
/// v2-03 (chat split): the monolithic chat_screen.dart was split into
/// lib/ui/chat/{transcript,composer,docks,sheets}.dart, so each pin below
/// reads the file where the behavior now lives (chat_screen.dart remains
/// the screen shell and is still covered by the removed-pill guard).
void main() {
  late String chatScreen;
  late String transcript;
  late String composer;
  late String docks;
  late String sheets;

  setUpAll(() {
    chatScreen = File('lib/ui/chat_screen.dart').readAsStringSync();
    transcript = File('lib/ui/chat/transcript.dart').readAsStringSync();
    composer = File('lib/ui/chat/composer.dart').readAsStringSync();
    docks = File('lib/ui/chat/docks.dart').readAsStringSync();
    sheets = File('lib/ui/chat/sheets.dart').readAsStringSync();
  });

  test('the home hero no longer renders the "preview" pill', () {
    // The hero greeting moved to transcript.dart in the v2-03 split; the
    // pill must stay gone from the whole home/chat surface.
    for (final src in [chatScreen, transcript, composer, docks, sheets]) {
      expect(src.contains("'preview'"), isFalse);
    }
  });

  test('the composer hint is explicitly faint', () {
    // The composer field is an AetherField (composer.dart); the faint hint
    // style block lives on that shared primitive now — it must set a faint
    // color.
    expect(composer.contains('AetherField('), isTrue);
    final aether =
        File('lib/ui/widgets/aether_primitives.dart').readAsStringSync();
    final field = aether.indexOf('class AetherField');
    expect(field, greaterThan(0));
    final idx = aether.indexOf('hintStyle: TextStyle(', field);
    expect(idx, greaterThan(field));
    final block = aether.substring(idx, idx + 320);
    expect(block.contains('Aether.textFaint'), isTrue);
  });

  test('the AI question card is bounded and scrollable', () {
    expect(docks.contains('SingleChildScrollView'), isTrue);
    // The questions card wraps its list in a max-height scroll view.
    final q = docks.indexOf('class _QuestionsCard');
    expect(q, greaterThan(0));
    final body = docks.substring(q);
    expect(body.contains('ConstrainedBox'), isTrue);
    expect(body.contains('maxHeight'), isTrue);
  });

  test('the model picker surfaces a Recent section', () {
    expect(sheets.contains("'Recent'"), isTrue);
  });

  test('reasoning disclosure matches the reference geometry', () {
    // 33px collapsed trigger with a .5px bottom hairline.
    expect(transcript.contains('height: 33'), isTrue);
    expect(transcript.contains('width: 0.5'), isTrue);
    // Chevron rotates over 100ms (reference .1s).
    expect(transcript.contains('Duration(milliseconds: 100)'), isTrue);
  });

  test('live status shimmer uses the reference blue gradient', () {
    // base #4176e6 with a #d3e2ff highlight sweeping across.
    expect(transcript.contains('0xFF4176E6'), isTrue);
    expect(transcript.contains('0xFFD3E2FF'), isTrue);
    expect(transcript.contains('milliseconds: 1800'), isTrue);
  });

  test('state dot chase is a three-dot 1s ladder', () {
    expect(transcript.contains('milliseconds: 1000'), isTrue);
    expect(transcript.contains('_levels'), isTrue);
  });
}
