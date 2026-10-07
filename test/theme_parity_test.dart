import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/theme.dart';

/// Ovid Si brand parity — the palette is the brand guidelines v2 spec:
/// Paper #F4F1EA, Ink #1B1B1B, Signal Red #E5484D, Stone #8A867D.
/// Red appears in one place only (the accent / agent). Both surfaces are
/// first-class: Paper (light, default) and Ink (dark).
void main() {
  group('Ovid Si brand constants', () {
    test('brand name, tagline and mark colours', () {
      expect(Aether.brandName, 'Ovid Si');
      expect(Aether.tagline, 'Chat. Code. Create.');
      expect(Aether.paper.toARGB32(), 0xFFF4F1EA);
      expect(Aether.ink.toARGB32(), 0xFF1B1B1B);
      expect(Aether.signalRed.toARGB32(), 0xFFE5484D);
      expect(Aether.stone.toARGB32(), 0xFF8A867D);
    });

    test('Signal Red is the single accent in both modes', () {
      for (final isDark in [true, false]) {
        Aether.dark = isDark;
        expect(Aether.accent.toARGB32(), 0xFFE5484D);
      }
    });
  });

  group('Paper (light) palette — the default brand surface', () {
    setUp(() => Aether.dark = false);

    test('background and surfaces are the paper ramp', () {
      expect(Aether.bg.toARGB32(), 0xFFF4F1EA);
      expect(Aether.surface.toARGB32(), 0xFFFFFFFF);
      expect(Aether.surfaceAlt.toARGB32(), 0xFFEDE9DF);
      expect(Aether.surfaceRaised.toARGB32(), 0xFFE4DFD3);
      expect(Aether.hairline.toARGB32(), 0xFFDCD7CB);
    });

    test('label ramp is Ink / muted / Stone', () {
      expect(Aether.text.toARGB32(), 0xFF1B1B1B);
      expect(Aether.textMuted.toARGB32(), 0xFF6B675E);
      expect(Aether.textFaint.toARGB32(), 0xFF8A867D);
    });
  });

  group('Ink (dark) palette', () {
    setUp(() => Aether.dark = true);

    test('background and surfaces are the ink ramp', () {
      expect(Aether.bg.toARGB32(), 0xFF141414);
      expect(Aether.surface.toARGB32(), 0xFF1E1E1E);
      expect(Aether.surfaceAlt.toARGB32(), 0xFF262626);
      expect(Aether.surfaceRaised.toARGB32(), 0xFF303030);
    });

    test('label ramp is Paper / muted / Stone', () {
      expect(Aether.text.toARGB32(), 0xFFF4F1EA);
      expect(Aether.textMuted.toARGB32(), 0xFFA8A49B);
      expect(Aether.textFaint.toARGB32(), 0xFF8A867D);
    });
  });

  group('state colours', () {
    test('success / warn keep their semantic hue', () {
      expect(Aether.success.toARGB32(), 0xFF22C55E);
      expect(Aether.warn.toARGB32(), 0xFFF59E0B);
    });
  });
}
