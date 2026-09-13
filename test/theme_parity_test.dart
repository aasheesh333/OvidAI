import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/theme.dart';

/// P1 (2026-09-13): the dark palette is aligned to the captured reference
/// values in `docs/superpowers/reference/2026-09-13-dsh-web-visual-reference.md`.
void main() {
  group('Aether dark palette parity', () {
    setUp(() => Aether.dark = true);

    test('background and surfaces match the reference ramp', () {
      expect(Aether.bg.toARGB32(), 0xFF151517);
      expect(Aether.surface.toARGB32(), 0xFF232324);
      expect(Aether.surfaceAlt.toARGB32(), 0xFF2C2C2E);
      expect(Aether.surfaceRaised.toARGB32(), 0xFF353638);
    });

    test('label ramp matches', () {
      expect(Aether.text.toARGB32(), 0xFFF9FAFB);
      expect(Aether.textMuted.toARGB32(), 0xFFADB2B8);
      expect(Aether.textFaint.toARGB32(), 0xFF81858C);
    });

    test('accent and state colors match', () {
      expect(Aether.accent.toARGB32(), 0xFF679EFE);
      expect(Aether.success.toARGB32(), 0xFF22C55E);
      expect(Aether.warn.toARGB32(), 0xFFF59E0B);
      expect(Aether.danger.toARGB32(), 0xFFF25A5A);
    });
  });
}
