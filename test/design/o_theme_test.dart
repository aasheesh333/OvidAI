import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';

double _contrast(Color a, Color b) {
  final l1 = a.computeLuminance();
  final l2 = b.computeLuminance();
  final hi = l1 > l2 ? l1 : l2;
  final lo = l1 > l2 ? l2 : l1;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('OColors', () {
    test('light palette is Paper, Ink, Signal Red and Stone', () {
      // The three-colour system, pinned so a theme edit cannot drift it.
      expect(OColors.light.bg.toARGB32(), 0xFFF4F1EA); // Paper
      expect(OColors.light.text.toARGB32(), 0xFF1B1B1B); // Ink
      expect(OColors.light.agent.toARGB32(), 0xFFE5484D); // Signal Red
      // Ordinary actions are Ink on Paper, not Signal Red: the system spends
      // its one strong colour on the agent.
      expect(OColors.light.accentFill.toARGB32(), 0xFF1B1B1B);
      expect(OColors.light.inputBorder.toARGB32(), 0xFF8A867D); // Stone
    });

    test('dark palette inverts Ink and Paper, keeps Signal Red', () {
      expect(OColors.dark.text.toARGB32(), 0xFFF4F1EA); // Paper on Ink
      expect(OColors.dark.agent.toARGB32(), 0xFFFF6B6F); // Signal Red
      expect(OColors.dark.accentFill.toARGB32(), 0xFFF4F1EA); // Paper
      // The page is a near-black Ink, not pure black: pure black loses the
      // paper-like softness the light theme is built on.
      expect(OColors.dark.bg.computeLuminance(), lessThan(0.02));
      expect(OColors.dark.bg.toARGB32(), isNot(0xFF000000));
    });

    test('dark danger is its own warm hue, never Signal Red', () {
      // Signal Red belongs to the agent alone. Dark danger is a desaturated
      // red-orange (#E8835C), pinned so it cannot drift back onto the agent.
      expect(OColors.dark.danger.toARGB32(), 0xFFE8835C);
      expect(
        OColors.dark.danger.toARGB32(),
        isNot(OColors.dark.agent.toARGB32()),
      );
      // Error text still clears AA body on the dark page, and the label on
      // the destructive fill clears it too.
      expect(
        _contrast(OColors.dark.danger, OColors.dark.bg),
        closeTo(6.88, 0.01),
      );
      expect(
        _contrast(OColors.dark.onDanger, OColors.dark.danger),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('light palette is a real counterpart, not an inversion', () {
      expect(OColors.light.bg.computeLuminance(), greaterThan(0.8));
      expect(OColors.light.text.computeLuminance(), lessThan(0.1));
      expect(
        OColors.light.bg.toARGB32(),
        isNot(OColors.dark.bg.toARGB32()),
      );
    });

    test('body and muted text meet AA on their own background', () {
      for (final c in [OColors.light, OColors.dark]) {
        expect(_contrast(c.text, c.bg), greaterThanOrEqualTo(4.5));
        expect(_contrast(c.textMuted, c.bg), greaterThanOrEqualTo(4.5));
        expect(_contrast(c.text, c.surface), greaterThanOrEqualTo(4.5));
        expect(_contrast(c.textMuted, c.surface), greaterThanOrEqualTo(4.5));
      }
    });

    test('primary button label stays readable on the accent fill', () {
      for (final c in [OColors.light, OColors.dark]) {
        expect(_contrast(c.onAccent, c.accentFill), greaterThanOrEqualTo(4.5));
      }
    });

    test('every token is present in both palettes', () {
      for (final c in [OColors.light, OColors.dark]) {
        expect(c.bg, isNot(c.surface));
        expect(c.hairline, isNot(c.bg));
        expect(c.accentSoft.a, greaterThan(0));
      }
    });
  });

  group('OTheme', () {
    test('unknown persisted values fall back to system', () {
      expect(OTheme.modeFor('system'), ThemeMode.system);
      expect(OTheme.modeFor('light'), ThemeMode.light);
      expect(OTheme.modeFor('dark'), ThemeMode.dark);
      expect(OTheme.modeFor('sepia'), ThemeMode.system);
      expect(OTheme.modeFor(''), ThemeMode.system);
    });

    test('normalizeMode keeps only supported values', () {
      expect(OTheme.normalizeMode('dark'), 'dark');
      expect(OTheme.normalizeMode('nope'), 'system');
    });

    test('light and dark themes carry the palette extension', () {
      final light = OTheme.light();
      final dark = OTheme.dark();
      expect(light.extension<OColors>(), OColors.light);
      expect(dark.extension<OColors>(), OColors.dark);
      expect(light.scaffoldBackgroundColor, OColors.light.bg);
      expect(dark.scaffoldBackgroundColor, OColors.dark.bg);
      expect(light.textTheme.bodyLarge?.height, greaterThanOrEqualTo(1.35));
    });

    test('typography never drops below 11sp and keeps a readable rhythm', () {
      for (final style in OType.all) {
        expect(style.fontSize, greaterThanOrEqualTo(11));
        // Display type is allowed to be tighter; body copy is not.
        expect(style.height, greaterThanOrEqualTo(1.15));
      }
      expect(OType.body.height, greaterThanOrEqualTo(1.4));
      expect(OType.bodySm.height, greaterThanOrEqualTo(1.4));
      expect(OType.caption.height, greaterThanOrEqualTo(1.35));
    });
  });

  group('spacing', () {
    test('scale is four-point and monotonic', () {
      const scale = [
        OSpace.xs,
        OSpace.s,
        OSpace.m,
        OSpace.l,
        OSpace.xl,
        OSpace.xxl,
      ];
      expect(scale, [4.0, 8.0, 12.0, 16.0, 24.0, 32.0]);
      for (var i = 1; i < scale.length; i++) {
        expect(scale[i], greaterThan(scale[i - 1]));
      }
    });

    test('touch target is at least 48dp', () {
      expect(OSpace.touch, greaterThanOrEqualTo(48));
      expect(OSpace.listRow, greaterThanOrEqualTo(48));
    });

    test('component metrics that screens used to hard-code are tokens', () {
      // The literal each one replaced, so a regression is obvious.
      expect(OSpace.xxs, 2); // title -> subtitle stack (was `2`, 107 uses)
      expect(OSpace.iconGap, 6); // icon -> label (was `6`, 27 uses)
      expect(OSpace.pillPad, 10); // pill inset (was `10`, 20 uses)
      expect(OSpace.controlPad, 14); // chip/field inset (was `14`)
      expect(OSpace.buttonPad, 20); // button inset (was `20`)
      expect(OSpace.iconTile, 36); // list-row icon tile (was `36`)
      expect(ORadius.xs, 4); // mini bars and thumbnails (was `2`/`3`)
    });

    test('the type scale has a semibold 14 sp rung', () {
      expect(OType.bodySmStrong.fontSize, OType.bodySm.fontSize);
      expect(OType.bodySmStrong.fontWeight, FontWeight.w600);
      expect(OType.all, contains(OType.bodySmStrong));
    });
  });
}
