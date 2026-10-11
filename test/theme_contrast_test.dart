import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/theme.dart';

/// WCAG 2.x contrast ratio between two opaque colours.
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  for (final (name, c) in const [
    ('light', AetherColors.light),
    ('dark', AetherColors.dark),
  ]) {
    group('$name palette', () {
      final backgrounds = {
        'bg': c.bg,
        'surface': c.surface,
        'surfaceAlt': c.surfaceAlt,
      };

      // Body text: WCAG AA 1.4.3, 4.5:1.
      final textTokens = {
        'text': c.text,
        'textMuted': c.textMuted,
        'textFaint': c.textFaint,
        'accent': c.accent,
        'success': c.success,
        'warn': c.warn,
        'danger': c.danger,
      };
      for (final fg in textTokens.entries) {
        for (final bg in backgrounds.entries) {
          test('${fg.key} on ${bg.key} >= 4.5:1', () {
            expect(
              contrast(fg.value, bg.value),
              greaterThanOrEqualTo(4.5),
              reason: '${fg.key} ${fg.value} on ${bg.key} ${bg.value}',
            );
          });
        }
      }

      // Non-text UI boundaries and status marks: WCAG 1.4.11, 3:1 against
      // the surfaces they sit on.
      final nonText = {
        'inputBorder': c.inputBorder,
        'success': c.success,
        'warn': c.warn,
        'danger': c.danger,
      };
      for (final fg in nonText.entries) {
        for (final bg in {'bg': c.bg, 'surface': c.surface}.entries) {
          test('${fg.key} on ${bg.key} >= 3:1 (non-text)', () {
            expect(contrast(fg.value, bg.value), greaterThanOrEqualTo(3.0));
          });
        }
      }

      test('button label on accentFill >= 4.5:1', () {
        expect(contrast(c.onAccent, c.accentFill), greaterThanOrEqualTo(4.5));
      });

      test('text levels stay distinct', () {
        expect(
          contrast(c.text, c.bg),
          greaterThan(contrast(c.textMuted, c.bg)),
        );
        expect(
          contrast(c.textMuted, c.bg),
          greaterThan(contrast(c.textFaint, c.bg)),
        );
      });
    });
  }

  group('theme wiring', () {
    tearDown(() {
      Aether.dark = false;
      Aether.resetThemeCacheForTest();
    });

    test('static getters follow the palette for the current mode', () {
      Aether.dark = false;
      expect(Aether.textFaint, AetherColors.light.textFaint);
      expect(Aether.accent, AetherColors.light.accent);
      Aether.dark = true;
      expect(Aether.textFaint, AetherColors.dark.textFaint);
      expect(Aether.accent, AetherColors.dark.accent);
      // Legacy aliases are the same tokens.
      expect(Aether.successLight, Aether.success);
      expect(Aether.dangerC, Aether.danger);
    });

    test('light and dark themes carry their AetherColors extension', () {
      final light = Aether.themeFor(dark: false);
      final dark = Aether.themeFor(dark: true);
      expect(light.extension<AetherColors>(), AetherColors.light);
      expect(dark.extension<AetherColors>(), AetherColors.dark);
      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      // Field boundaries use the 3:1 input border, not the divider hairline.
      final enabled =
          light.inputDecorationTheme.enabledBorder! as OutlineInputBorder;
      expect(enabled.borderSide.color, AetherColors.light.inputBorder);
      // M3 primary is readable with its on-colour in both modes.
      for (final t in [light, dark]) {
        expect(
          contrast(t.colorScheme.primary, t.colorScheme.onPrimary),
          greaterThanOrEqualTo(4.5),
        );
      }
    });

    test('lerp interpolates every token', () {
      final mid = AetherColors.light.lerp(AetherColors.dark, 0.5);
      expect(
        mid.bg,
        Color.lerp(AetherColors.light.bg, AetherColors.dark.bg, .5),
      );
      expect(
        AetherColors.light.lerp(AetherColors.dark, 1).accent,
        AetherColors.dark.accent,
      );
    });
  });
}
