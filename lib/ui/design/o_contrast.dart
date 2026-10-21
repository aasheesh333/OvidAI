import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import 'o_tokens.dart';

/// WCAG 2.2 contrast maths for the Ovid Si palette.
///
/// Every pairing the UI actually paints is declared in [audit] so a palette
/// change can be checked in one place. The thresholds are the WCAG 2.2 AA
/// ones:
///
/// * body text: **4.5:1**
/// * large text (>= 18 pt / 14 pt bold) and caption-sized labels: **3:1**
/// * non-text UI (status dots, icons that carry meaning): **3:1**
///
/// The brief treats the 11-12 sp caption style as "large" for the purpose of
/// this gate; [OContrastCheck.passesStrictBody] still exposes the stricter
/// 4.5:1 answer so the gap is visible rather than hidden.
///
/// Colours may be translucent (for example [OColors.accentSoft]); the
/// foreground is composited over the background before measuring, which is
/// what the eye actually sees.
abstract final class OContrast {
  /// WCAG AA minimum for body text.
  static const double bodyMinimum = 4.5;

  /// WCAG AA minimum for large text, captions and meaningful UI.
  static const double largeMinimum = 3.0;

  /// WCAG AAA minimum for body text.
  static const double bodyEnhancedMinimum = 7.0;

  /// WCAG AAA minimum for large text.
  static const double largeEnhancedMinimum = 4.5;

  /// Alpha component as a 0..1 double (kept explicit so call sites do not
  /// depend on a specific Flutter channel API).
  static double opacity(Color color) => color.a;

  /// Composites [foreground] over [background], honouring the foreground
  /// alpha. The result is always opaque.
  static Color compositeOver(Color foreground, Color background) {
    final fgAlpha = foreground.a;
    final base = background.a >= 1.0
        ? background
        : compositeOver(background, const Color(0xFFFFFFFF));
    if (fgAlpha >= 1.0) return foreground;
    if (fgAlpha <= 0.0) return base;
    double mix(double fg, double bg) => fg * fgAlpha + bg * (1 - fgAlpha);
    return Color.from(
      alpha: 1.0,
      red: mix(foreground.r, base.r),
      green: mix(foreground.g, base.g),
      blue: mix(foreground.b, base.b),
    );
  }

  /// Relative luminance per WCAG 2.2, matching `Color.computeLuminance()`.
  static double relativeLuminance(Color color) {
    final opaque = color.a >= 1.0
        ? color
        : compositeOver(color, const Color(0xFFFFFFFF));
    double linear(double channel) => channel <= 0.03928
        ? channel / 12.92
        : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * linear(opaque.r) +
        0.7152 * linear(opaque.g) +
        0.0722 * linear(opaque.b);
  }

  /// Contrast ratio between [foreground] and [background], from 1.0 to 21.0.
  ///
  /// A translucent [foreground] is composited over [background] first. A
  /// translucent [background] is itself composited over white.
  static double ratio(Color foreground, Color background) {
    final base = background.a >= 1.0
        ? background
        : compositeOver(background, const Color(0xFFFFFFFF));
    final fg = compositeOver(foreground, base);
    final l1 = relativeLuminance(fg);
    final l2 = relativeLuminance(base);
    final hi = math.max(l1, l2);
    final lo = math.min(l1, l2);
    return (hi + 0.05) / (lo + 0.05);
  }

  /// Whether [foreground] on [background] clears [tier].
  static bool meets(
    Color foreground,
    Color background, {
    OContrastTier tier = OContrastTier.body,
  }) => ratio(foreground, background) + _epsilon >= tier.minimum;

  /// Human readable WCAG grade for a measured [value].
  static String grade(double value) {
    if (value + _epsilon >= bodyEnhancedMinimum) return 'AAA';
    if (value + _epsilon >= bodyMinimum) return 'AA';
    if (value + _epsilon >= largeMinimum) return 'AA large';
    return 'Fail';
  }

  /// Every foreground/background pairing the app paints, for [colors].
  ///
  /// The four pairings called out by the design brief are
  /// `text/bg`, `textMuted/bg`, `accentFill/onAccent` and `danger/onDanger`.
  /// The other entries cover the surfaces those colours are actually drawn on
  /// (cards, sheets, code blocks) and the secondary roles of the accent,
  /// danger, success and warning tokens.
  static List<OContrastCheck> audit(OColors colors) {
    OContrastCheck body(String name, Color fg, Color bg) =>
        OContrastCheck(name, fg, bg, tier: OContrastTier.body);
    OContrastCheck caption(String name, Color fg, Color bg) =>
        OContrastCheck(name, fg, bg, tier: OContrastTier.caption);
    OContrastCheck graphic(String name, Color fg, Color bg) =>
        OContrastCheck(name, fg, bg, tier: OContrastTier.graphic);

    return <OContrastCheck>[
      // Primary copy on every surface.
      body('text/bg', colors.text, colors.bg),
      body('text/surface', colors.text, colors.surface),
      body('text/surfaceAlt', colors.text, colors.surfaceAlt),
      body('text/surfaceRaised', colors.text, colors.surfaceRaised),
      body('text/codeBg', colors.text, colors.codeBg),
      // Accent roles: text buttons / links, and the filled primary button.
      body('accent/bg', colors.accent, colors.bg),
      body('accent/surface', colors.accent, colors.surface),
      body('accentFill/onAccent', colors.onAccent, colors.accentFill),
      // Danger roles: inline errors and the destructive button.
      body('danger/bg', colors.danger, colors.bg),
      body('danger/surface', colors.danger, colors.surface),
      body('danger/onDanger', colors.onDanger, colors.danger),
      // Secondary copy.
      caption('textMuted/bg', colors.textMuted, colors.bg),
      caption('textMuted/surface', colors.textMuted, colors.surface),
      caption('textMuted/surfaceAlt', colors.textMuted, colors.surfaceAlt),
      caption(
        'textMuted/surfaceRaised',
        colors.textMuted,
        colors.surfaceRaised,
      ),
      caption('textFaint/bg', colors.textFaint, colors.bg),
      caption('textFaint/surface', colors.textFaint, colors.surface),
      caption('textFaint/surfaceAlt', colors.textFaint, colors.surfaceAlt),
      caption(
        'textFaint/surfaceRaised',
        colors.textFaint,
        colors.surfaceRaised,
      ),
      // Status colours are used for dots, rings and short status labels.
      graphic('success/bg', colors.success, colors.bg),
      graphic('warn/bg', colors.warn, colors.bg),
    ];
  }

  /// One human readable block covering [colors].
  static String report(OColors colors, {String label = 'palette'}) {
    final checks = audit(colors);
    final failing = checks.where((check) => !check.passes).length;
    final buffer = StringBuffer('Ovid Si contrast - $label\n');
    for (final check in checks) {
      buffer
        ..write(check.passes ? 'PASS' : 'FAIL')
        ..write('  ')
        ..write(check.ratio.toStringAsFixed(2).padLeft(5))
        ..write(':1  ')
        ..write(check.name.padRight(26))
        ..write('  ${check.tier.label}')
        ..writeln();
    }
    buffer.writeln(
      failing == 0
          ? 'All ${checks.length} pairs meet their WCAG AA tier.'
          : '$failing of ${checks.length} pairs fail their WCAG AA tier.',
    );
    return buffer.toString();
  }

  /// Convenience report for both first-class themes.
  static String reportAll() =>
      '${report(OColors.light, label: 'light')}\n'
      '${report(OColors.dark, label: 'dark')}';

  static const double _epsilon = 1e-9;
}

/// The contrast gate a pairing is expected to clear.
enum OContrastTier {
  /// Body copy at 16 sp and up (WCAG AA: 4.5:1).
  body(OContrast.bodyMinimum, 'AA body >= 4.5:1'),

  /// Caption/label copy and large text (WCAG AA large: 3:1).
  caption(OContrast.largeMinimum, 'AA large >= 3:1'),

  /// Meaningful non-text UI: status dots, icons, focus rings (3:1).
  graphic(OContrast.largeMinimum, 'AA non-text >= 3:1');

  const OContrastTier(this.minimum, this.label);

  /// Minimum allowed ratio.
  final double minimum;

  /// Short description used in reports and test failure messages.
  final String label;
}

/// A single foreground/background pairing and its measured contrast.
@immutable
class OContrastCheck {
  const OContrastCheck(
    this.name,
    this.foreground,
    this.background, {
    this.tier = OContrastTier.body,
  });

  /// Stable identifier such as `textMuted/bg`.
  final String name;

  /// Painted text (or icon) colour. May be translucent.
  final Color foreground;

  /// Surface the foreground is painted on. May be translucent.
  final Color background;

  /// Gate this pairing must clear.
  final OContrastTier tier;

  /// Measured ratio, 1.0 to 21.0.
  double get ratio => OContrast.ratio(foreground, background);

  /// Minimum ratio required by [tier].
  double get required => tier.minimum;

  /// Whether the pairing clears its declared [tier].
  bool get passes => ratio + 1e-9 >= tier.minimum;

  /// Whether the pairing would also clear the stricter 4.5:1 body gate.
  ///
  /// Captions are only gated at 3:1, so this is diagnostic: a `false` here
  /// is not a failure for [OContrastTier.caption], but it is a sign the
  /// caption may feel light at small sizes.
  bool get passesStrictBody => ratio + 1e-9 >= OContrast.bodyMinimum;

  /// WCAG grade for the measured ratio (`AAA`, `AA`, `AA large`, `Fail`).
  String get grade => OContrast.grade(ratio);

  /// Short line used in test messages and [OContrast.report].
  String get summary =>
      '${passes ? 'PASS' : 'FAIL'} $name ${ratio.toStringAsFixed(2)}:1 '
      '(${tier.label})';

  @override
  String toString() => 'OContrastCheck($summary)';
}
