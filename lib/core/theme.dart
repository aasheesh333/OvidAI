import 'package:flutter/material.dart';

/// Ovid Si design system — flat Paper/Ink surfaces with a single Signal Red
/// accent that belongs to the agent. Calm, confident, "no colour noise".
/// Light/dark switchable: [Aether.dark] flips the whole palette; UI code
/// reads the same names either way (light/dark preference parity).
///
/// Brand (docs: Ovid Si brand guidelines v2): Paper #F4F1EA, Ink #1B1B1B,
/// Signal Red #E5484D, Stone #8A867D. Red appears in one place only — the
/// agent. Balance Paper/Ink 90%, Signal Red 10%. No gradients or glow.
class Aether {
  Aether._();

  /// Brand name and tagline (launcher, splash, about, share).
  static const brandName = 'Ovid Si';
  static const tagline = 'Chat. Code. Create.';

  /// The brand mark colours (independent of light/dark for the mark itself).
  static const paper = Color(0xFFF4F1EA);
  static const ink = Color(0xFF1B1B1B);
  static const signalRed = Color(0xFFE5484D);
  static const stone = Color(0xFF8A867D);

  /// true = dark (Ink), false = light (Paper). Paper is the default brand
  /// surface. Prefer `context.aether` in new code: it registers a dependency on
  /// the [Theme], so the widget repaints when the palette flips. The static
  /// getters below read this flag directly and only update on the next rebuild
  /// (the app root forces one for every element on a switch, see
  /// [rebuildAll]).
  static bool dark = false;

  /// The palette for the current [dark] value.
  static AetherColors get palette =>
      dark ? AetherColors.dark : AetherColors.light;

  static Color get bg => palette.bg;
  static Color get surface => palette.surface;
  static Color get surfaceAlt => palette.surfaceAlt;
  static Color get surfaceRaised => palette.surfaceRaised;

  /// Dividers and card edges only. Input boundaries use [inputBorder].
  static Color get hairline => palette.hairline;
  static Color get hairlineStrong => palette.hairlineStrong;

  /// Visible boundary of an empty text field (WCAG 1.4.11, >= 3:1).
  static Color get inputBorder => palette.inputBorder;

  static Color get text => palette.text;
  static Color get textMuted => palette.textMuted;
  static Color get textFaint => palette.textFaint;

  /// Fenced code-block background (distinct from the card surface).
  static Color get codeBg => palette.codeBg;

  /// Red for text, icons, links and focus rings. Theme-aware so it stays
  /// readable (>= 4.5:1) on every surface in both modes. The brand mark, the
  /// agent dot and similar decorative uses keep [signalRed].
  static Color get accent => palette.accent;

  /// Fill for solid red buttons. Pair with [onAccent] for the label.
  static Color get accentFill => palette.accentFill;
  static Color get onAccent => palette.onAccent;
  static Color get accentSoft => palette.accentSoft;

  /// Status colours, readable as text and >= 3:1 as non-text in both modes.
  static Color get success => palette.success;
  static Color get warn => palette.warn;
  static Color get danger => palette.danger;

  /// Fill for destructive solid buttons. Pair with [onAccent].
  static Color get dangerFill => palette.accentFill;

  // Legacy aliases. Every value now equals the theme-aware token, so they are
  // safe; remaining call sites (chat_screen.dart, edited on parallel branches)
  // migrate to the plain names in a follow-up and these are then deleted.
  static Color get accentC => accent;
  static Color get successC => success;
  static Color get dangerC => danger;
  static Color get successLight => success;
  static Color get warnLight => warn;

  /// Marks every element below [context] dirty so widgets that read the
  /// static palette (const subtrees, cached builder children, open dialogs
  /// and sheets) repaint after a light/dark switch. Call it from the app
  /// root right after flipping [dark].
  static void rebuildAll(BuildContext context) {
    void mark(Element element) {
      element.markNeedsBuild();
      element.visitChildren(mark);
    }

    (context as Element).visitChildren(mark);
  }

  /// Brand motion: UI feedback 200–300 ms, ambient 1–3 s.
  static const ease = Cubic(0.2, 0.8, 0.2, 1);
  static const motionFast = Duration(milliseconds: 220);
  static const motionBase = Duration(milliseconds: 280);
  static const motionSlow = Duration(milliseconds: 420);

  static const mono = 'JetBrainsMono';

  /// Decode width for an image that will be displayed at roughly [logicalWidth]
  /// logical pixels on this device.
  ///
  /// MEMORY (2026-09-24): `Image.file` / `Image.network` without `cacheWidth`
  /// decode at FULL resolution into the image cache. Generated images here reach
  /// 16 MB JPEGs, so a handful of them in one chat was enough to spike RAM and
  /// risk an OOM kill on a low-end device — with no visual difference, because
  /// the pixels beyond the display size are thrown away at paint time anyway.
  static int imageCacheWidth(BuildContext context, {double? logicalWidth}) {
    final mq = MediaQuery.of(context);
    final logical = (logicalWidth ?? mq.size.width).clamp(120.0, 1600.0);
    return (logical * mq.devicePixelRatio).round().clamp(240, 3200);
  }

  static ThemeData? _cachedLight;
  static ThemeData? _cachedDark;

  /// Drops the cached [ThemeData]s. Only tests need this; production builds
  /// each theme once.
  @visibleForTesting
  static void resetThemeCacheForTest() {
    _cachedLight = null;
    _cachedDark = null;
  }

  /// The app theme for the current [dark] value. Same as
  /// `themeFor(dark: dark)`.
  static ThemeData theme() => themeFor(dark: dark);

  /// The light or dark app theme, CACHED per brightness.
  ///
  /// PERF (2026-09-24): this built a fresh `ThemeData.dark()/light()` plus a
  /// full `copyWith` on EVERY call, and the root widget calls it on every
  /// rebuild — which, because the root also listened to all of `AppState`,
  /// meant once per streamed token. Returning the cached instance removes that
  /// allocation from the hot path entirely.
  static ThemeData themeFor({required bool dark}) => dark
      ? (_cachedDark ??= _buildTheme(AetherColors.dark, dark: true))
      : (_cachedLight ??= _buildTheme(AetherColors.light, dark: false));

  static ThemeData _buildTheme(AetherColors c, {required bool dark}) {
    final base = dark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);
    return base.copyWith(
      extensions: <ThemeExtension<dynamic>>[c],
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {TargetPlatform.android: _FadeSlideTransitionsBuilder()},
      ),
      scaffoldBackgroundColor: c.bg,
      dividerColor: c.hairline,
      colorScheme: (dark ? const ColorScheme.dark() : const ColorScheme.light())
          .copyWith(
            surface: c.surface,
            // Light: the red fill with a white label (5.84:1). Dark: the light
            // red text tone with an Ink label (5.65:1), so M3 widgets that
            // draw text or thin strokes in `primary` stay readable on Ink.
            primary: dark ? c.accent : c.accentFill,
            onPrimary: dark ? Aether.ink : c.onAccent,
            secondary: dark ? c.accent : c.accentFill,
            tertiary: dark ? c.accent : c.accentFill,
            onSurface: c.text,
            onSurfaceVariant: c.textMuted,
            outline: c.inputBorder,
            outlineVariant: c.hairline,
            error: c.danger,
          ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: c.text,
          letterSpacing: 0.1,
        ),
        iconTheme: IconThemeData(color: c.textMuted, size: 20),
      ),
      dividerTheme: DividerThemeData(color: c.hairline, thickness: 1, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surfaceAlt,
        hintStyle: TextStyle(color: c.textFaint, fontSize: 14),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.inputBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.accent, width: 1.2),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.inputBorder),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.surfaceRaised,
        contentTextStyle: TextStyle(color: c.text, fontSize: 13),
        actionTextColor: c.accent,
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: c.hairline),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      textTheme: base.textTheme.apply(
        fontFamily: 'Inter',
        bodyColor: c.text,
        displayColor: c.text,
      ),
    );
  }
}

/// The Aether palette as a [ThemeExtension], so widgets that read it through
/// `context.aether` rebuild (and animate) when the theme changes.
///
/// Contrast (WCAG 2.x, see test/theme_contrast_test.dart): every text token is
/// >= 4.5:1 on bg, surface and surfaceAlt; [inputBorder], [success], [warn]
/// and [danger] are >= 3:1 as non-text on bg and surface.
@immutable
class AetherColors extends ThemeExtension<AetherColors> {
  const AetherColors({
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

  /// Paper.
  static const light = AetherColors(
    bg: Color(0xFFF4F1EA),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFEDE9DF),
    surfaceRaised: Color(0xFFE4DFD3),
    hairline: Color(0xFFDCD7CB),
    hairlineStrong: Color(0xFFC4BEB0),
    inputBorder: Color(0xFF8F897C),
    text: Color(0xFF1B1B1B),
    textMuted: Color(0xFF57534B),
    textFaint: Color(0xFF6C685F),
    codeBg: Color(0xFFEDE9DF),
    accent: Color(0xFFC0292E),
    accentFill: Color(0xFFC0292E),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0x1FE5484D),
    success: Color(0xFF166534),
    warn: Color(0xFFA04606),
    danger: Color(0xFFC0292E),
  );

  /// Ink.
  static const dark = AetherColors(
    bg: Color(0xFF141414),
    surface: Color(0xFF1E1E1E),
    surfaceAlt: Color(0xFF262626),
    surfaceRaised: Color(0xFF303030),
    hairline: Color(0xFF333333),
    hairlineStrong: Color(0xFF454545),
    inputBorder: Color(0xFF7F7A6E),
    text: Color(0xFFF4F1EA),
    textMuted: Color(0xFFA8A49B),
    textFaint: Color(0xFF9A968D),
    codeBg: Color(0xFF1A1A1A),
    accent: Color(0xFFF2666A),
    accentFill: Color(0xFFC0292E),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0x1FE5484D),
    success: Color(0xFF22C55E),
    warn: Color(0xFFF59E0B),
    danger: Color(0xFFF2666A),
  );

  @override
  AetherColors copyWith({
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
  }) => AetherColors(
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
  );

  @override
  AetherColors lerp(covariant ThemeExtension<AetherColors>? other, double t) {
    if (other is! AetherColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AetherColors(
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
    );
  }
}

/// `context.aether.text` etc. Registers a [Theme] dependency, so the caller
/// rebuilds on a light/dark switch. Falls back to the static palette when the
/// ambient theme has no [AetherColors] (bare `MaterialApp()` in tests).
extension AetherThemeContext on BuildContext {
  AetherColors get aether =>
      Theme.of(this).extension<AetherColors>() ?? Aether.palette;
}

/// Small labeled tag (e.g. "FREE", "BYOK").
class Tag extends StatelessWidget {
  final String label;
  final Color? color;
  final bool filled;
  const Tag(
    this.label, {
    super.key,
    this.color,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? Aether.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: filled ? color.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: color,
        ),
      ),
    );
  }
}

/// Section header used across settings/plugins.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  const SectionHeader(this.title, {super.key, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
              color: Aether.textFaint,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// Soft fade + slight upward slide — premium page transitions.
class _FadeSlideTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeSlideTransitionsBuilder();
  @override
  Widget buildTransitions<T>(
    Route<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.025),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
