import 'package:flutter/material.dart';

/// Ovid Si design tokens.
///
/// Three colours, flat, no gradients and no glow: Paper `#F4F1EA`, Ink
/// `#1B1B1B`, Signal Red `#E5484D`, plus Stone `#8A867D` for secondary text.
/// Paper and Ink carry about 90 % of every surface; Signal Red is the agent's
/// own colour and appears nowhere else. The app follows the device theme and
/// falls back to Paper (light) when the platform reports nothing.
@immutable
class OColors extends ThemeExtension<OColors> {
  const OColors({
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.surfaceRaised,
    required this.hairline,
    required this.hairlineStrong,
    required this.inputBorder,
    required this.text,
    required this.textMuted,
    required this.textFaint,
    required this.codeBg,
    required this.accent,
    required this.accentFill,
    required this.onAccent,
    required this.accentSoft,
    required this.success,
    required this.warn,
    required this.danger,
    required this.onDanger,
    required this.scrim,
  });

  final Color bg;
  final Color surface;
  final Color surfaceAlt;
  final Color surfaceRaised;
  final Color hairline;
  final Color hairlineStrong;
  final Color inputBorder;
  final Color text;
  final Color textMuted;
  final Color textFaint;
  final Color codeBg;
  final Color accent;
  final Color accentFill;
  final Color onAccent;
  final Color accentSoft;
  final Color success;
  final Color warn;
  final Color danger;
  final Color onDanger;
  final Color scrim;

  /// Paper / Ink / Signal Red / Stone.
  ///
  /// Three colours, flat. Paper and Ink carry ~90 % of every surface; Signal
  /// Red is reserved for the agent itself (its avatar, its live state, its
  /// destructive confirmations) and never used as decoration. Stone is the
  /// only secondary-text colour.
  /// Paper / Ink / Signal Red / Stone.
  ///
  /// Three colours, flat. Paper and Ink carry ~90 % of every surface; Signal
  /// Red is the agent's own colour (its mark, its live state, its destructive
  /// confirmations) and never decoration. Stone is the only secondary text.
  static const light = OColors(
    bg: Color(0xFFF4F1EA), // Paper
    surface: Color(0xFFF8F6F0), // one step up from Paper
    surfaceAlt: Color(0xFFEDE9E0),
    surfaceRaised: Color(0xFFE6E1D6),
    hairline: Color(0xFFDDD8CC),
    hairlineStrong: Color(0xFFC8C2B4),
    inputBorder: Color(0xFF8A867D), // Stone
    text: Color(0xFF1B1B1B), // Ink
    textMuted: Color(0xFF605C55), // Stone, darkened for body-size text
    textFaint: Color(0xFF837F76), // Stone, for captions and icons
    codeBg: Color(0xFFEDE9E0),
    // Signal Red as text/icon. #E5484D is 3.47:1 on Paper — enough for an icon
    // or large text, not for a body-size link — so the text token is the same
    // hue darkened to 4.86:1. `accentFill` keeps the exact brand value.
    accent: Color(0xFFB32D34),
    accentFill: Color(0xFFE5484D), // Signal Red
    onAccent: Color(0xFF0F0F0F), // 4.83:1 on Signal Red
    accentSoft: Color(0x1AE5484D),
    // Status is carried by icon and wording, not by a fourth hue.
    success: Color(0xFF1B1B1B),
    warn: Color(0xFF605C55),
    danger: Color(0xFFC2333A),
    onDanger: Color(0xFFFFFFFF),
    scrim: Color(0x8A1B1B1B),
  );

  /// The same three colours inverted: Ink becomes the page, Paper the text.
  static const dark = OColors(
    bg: Color(0xFF141413),
    surface: Color(0xFF1B1B1A),
    surfaceAlt: Color(0xFF232322),
    surfaceRaised: Color(0xFF2C2C2A),
    hairline: Color(0xFF333331),
    hairlineStrong: Color(0xFF4A4A46),
    inputBorder: Color(0xFF8A867D),
    text: Color(0xFFF4F1EA), // Paper
    textMuted: Color(0xFFA8A399), // Stone, lifted for body-size text
    textFaint: Color(0xFF8A867D), // Stone
    codeBg: Color(0xFF0F0F0E),
    // Signal Red lifted for the Ink page: 6.66:1.
    accent: Color(0xFFFF6B6F),
    accentFill: Color(0xFFE5484D),
    onAccent: Color(0xFF0F0F0F),
    accentSoft: Color(0x24E5484D),
    success: Color(0xFFF4F1EA),
    warn: Color(0xFFA8A399),
    danger: Color(0xFFFF6B6F),
    onDanger: Color(0xFF0F0F0F),
    scrim: Color(0xB3000000),
  );

  static OColors of(BuildContext context) =>
      Theme.of(context).extension<OColors>() ?? light;

  static OColors resolve(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  @override
  OColors copyWith({
    Color? bg,
    Color? surface,
    Color? surfaceAlt,
    Color? surfaceRaised,
    Color? hairline,
    Color? hairlineStrong,
    Color? inputBorder,
    Color? text,
    Color? textMuted,
    Color? textFaint,
    Color? codeBg,
    Color? accent,
    Color? accentFill,
    Color? onAccent,
    Color? accentSoft,
    Color? success,
    Color? warn,
    Color? danger,
    Color? onDanger,
    Color? scrim,
  }) {
    return OColors(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surfaceAlt: surfaceAlt ?? this.surfaceAlt,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      hairline: hairline ?? this.hairline,
      hairlineStrong: hairlineStrong ?? this.hairlineStrong,
      inputBorder: inputBorder ?? this.inputBorder,
      text: text ?? this.text,
      textMuted: textMuted ?? this.textMuted,
      textFaint: textFaint ?? this.textFaint,
      codeBg: codeBg ?? this.codeBg,
      accent: accent ?? this.accent,
      accentFill: accentFill ?? this.accentFill,
      onAccent: onAccent ?? this.onAccent,
      accentSoft: accentSoft ?? this.accentSoft,
      success: success ?? this.success,
      warn: warn ?? this.warn,
      danger: danger ?? this.danger,
      onDanger: onDanger ?? this.onDanger,
      scrim: scrim ?? this.scrim,
    );
  }

  @override
  OColors lerp(ThemeExtension<OColors>? other, double t) {
    if (other is! OColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return OColors(
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      surfaceAlt: l(surfaceAlt, other.surfaceAlt),
      surfaceRaised: l(surfaceRaised, other.surfaceRaised),
      hairline: l(hairline, other.hairline),
      hairlineStrong: l(hairlineStrong, other.hairlineStrong),
      inputBorder: l(inputBorder, other.inputBorder),
      text: l(text, other.text),
      textMuted: l(textMuted, other.textMuted),
      textFaint: l(textFaint, other.textFaint),
      codeBg: l(codeBg, other.codeBg),
      accent: l(accent, other.accent),
      accentFill: l(accentFill, other.accentFill),
      onAccent: l(onAccent, other.onAccent),
      accentSoft: l(accentSoft, other.accentSoft),
      success: l(success, other.success),
      warn: l(warn, other.warn),
      danger: l(danger, other.danger),
      onDanger: l(onDanger, other.onDanger),
      scrim: l(scrim, other.scrim),
    );
  }
}

/// Four-point spacing scale. Every gap in the app comes from here.
///
/// The four-point values ([xs] and up) are layout gaps. The named component
/// metrics below them are the few sub-4 dp / odd values that are not gaps but
/// fixed optical measurements (a title/meta stack, an icon-to-label gap, the
/// padding inside a pill). They live here so no screen needs a bare literal.
abstract final class OSpace {
  /// 2 dp — the hairline stack between a title and its meta line, and between
  /// a label and its value. A leading nudge, not a gap.
  static const xxs = 2.0;
  static const xs = 4.0;
  /// 6 dp — icon-to-label gap inside pills, chips and inline metadata.
  static const iconGap = 6.0;
  static const s = 8.0;
  /// 10 dp — horizontal padding inside a pill.
  static const pillPad = 10.0;
  static const m = 12.0;
  /// 14 dp — padding inside a compact control: a chip's horizontal inset, a
  /// text field's vertical inset, a tag's horizontal inset.
  static const controlPad = 14.0;
  static const l = 16.0;
  /// 20 dp — horizontal padding inside a button.
  static const buttonPad = 20.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const huge = 48.0;
  static const screen = 24.0;
  static const listRow = 56.0;
  static const touch = 48.0;
  /// 36 dp — leading icon tile inside a list row.
  static const iconTile = 36.0;
}

abstract final class ORadius {
  /// 4 dp — 8 dp-tall bars, thumbnails and mini fills. A 4-6 dp bar that
  /// should read as a stadium uses [pill], never a bare `2`.
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 24.0;
  static const pill = 999.0;
}

/// Inter type scale from the approved design (1.4 line height).
abstract final class OType {
  static const _family = 'Inter';

  static const display = TextStyle(
    fontFamily: _family,
    fontSize: 34,
    height: 1.18,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.6,
  );
  static const h1 = TextStyle(
    fontFamily: _family,
    fontSize: 28,
    height: 1.29,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
  );
  static const h2 = TextStyle(
    fontFamily: _family,
    fontSize: 20,
    height: 1.4,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );
  static const h3 = TextStyle(
    fontFamily: _family,
    fontSize: 17,
    height: 1.4,
    fontWeight: FontWeight.w600,
  );
  static const body = TextStyle(
    fontFamily: _family,
    fontSize: 16,
    height: 1.45,
    fontWeight: FontWeight.w400,
  );
  static const bodyStrong = TextStyle(
    fontFamily: _family,
    fontSize: 16,
    height: 1.45,
    fontWeight: FontWeight.w600,
  );
  static const bodySm = TextStyle(
    fontFamily: _family,
    fontSize: 14,
    height: 1.45,
    fontWeight: FontWeight.w400,
  );

  /// The 14 sp semibold rung. Screens had been reaching for
  /// `bodySm.copyWith(fontWeight: FontWeight.w600)` in 140 places; the scale
  /// was missing this step, not the call sites.
  static const bodySmStrong = TextStyle(
    fontFamily: _family,
    fontSize: 14,
    height: 1.45,
    fontWeight: FontWeight.w600,
  );
  static const label = TextStyle(
    fontFamily: _family,
    fontSize: 14,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
  );
  static const caption = TextStyle(
    fontFamily: _family,
    fontSize: 12,
    height: 1.4,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.2,
  );
  static const overline = TextStyle(
    fontFamily: _family,
    fontSize: 11,
    height: 1.4,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.1,
  );
  static const mono = TextStyle(
    fontFamily: 'JetBrainsMono',
    fontSize: 13,
    height: 1.5,
    fontWeight: FontWeight.w400,
  );

  static const all = <TextStyle>[
    display,
    h1,
    h2,
    h3,
    body,
    bodyStrong,
    bodySm,
    bodySmStrong,
    label,
    caption,
    overline,
    mono,
  ];
}

/// Motion is part of the product, not decoration: short, spring-like, never
/// blocking input. Durations are deliberately short enough to feel instant.
abstract final class OMotion {
  static const instant = Duration(milliseconds: 90);
  static const fast = Duration(milliseconds: 140);
  static const base = Duration(milliseconds: 200);
  static const medium = Duration(milliseconds: 260);
  static const slow = Duration(milliseconds: 360);
  static const ambient = Duration(milliseconds: 1200);

  static const standard = Cubic(0.2, 0.8, 0.2, 1);
  static const emphasized = Cubic(0.05, 0.7, 0.1, 1);
  static const exit = Cubic(0.4, 0.0, 1.0, 1.0);
  static const spring = Cubic(0.34, 1.56, 0.64, 1.0);

  /// Stagger between list items. Capped by callers so long lists stay snappy.
  static const stagger = Duration(milliseconds: 32);
}

/// Elevation is reserved for surfaces that genuinely float over the page.
///
/// The system is flat: cards, rows and sheets use a hairline border and a
/// surface step, never a shadow. [floating] and [sheet] are for popovers,
/// menus and frames that overlap content. There is deliberately no decorative
/// glow: the contract bans it, and the browser viewport is flat.
abstract final class OShadow {
  static const floating = <BoxShadow>[
    BoxShadow(color: Color(0x73000000), blurRadius: 24, offset: Offset(0, 8)),
  ];
  static const sheet = <BoxShadow>[
    BoxShadow(color: Color(0x99000000), blurRadius: 32, offset: Offset(0, 16)),
  ];
}
