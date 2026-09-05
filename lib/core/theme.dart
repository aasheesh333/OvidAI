import 'package:flutter/material.dart';

/// OvidAI design system — restrained monochrome theme with a single
/// muted indigo accent. Professional, calm, "no color noise".
/// Light/dark switchable: [Aether.dark] flips the whole palette; UI code
/// reads the same names either way (the reference light/dark preference parity).
class Aether {
  Aether._();

  /// true = dark (default), false = light.  Set before runApp and on
  /// toggle; call sites pick up the new palette on next rebuild.
  static bool dark = true;

  // ── Dark palette ──
  static const _bgD = Color(0xFF0A0A0C);
  static const _surfaceD = Color(0xFF111114);
  static const _surfaceAltD = Color(0xFF17171B);
  static const _surfaceRaisedD = Color(0xFF1D1D23);
  static const _hairlineD = Color(0xFF26262C);
  static const _hairlineStrongD = Color(0xFF33333B);
  static const _textD = Color(0xFFEDEDF0);
  static const _textMutedD = Color(0xFF9B9BA4);
  static const _textFaintD = Color(0xFF63636C);

  // ── Light palette ──
  static const _bgL = Color(0xFFFAFAFC);
  static const _surfaceL = Color(0xFFFFFFFF);
  static const _surfaceAltL = Color(0xFFF2F2F5);
  static const _surfaceRaisedL = Color(0xFFE9E9EE);
  static const _hairlineL = Color(0xFFE2E2E8);
  static const _hairlineStrongL = Color(0xFFCFCFD8);
  static const _textL = Color(0xFF1A1A20);
  static const _textMutedL = Color(0xFF5C5C66);
  static const _textFaintL = Color(0xFF9494A0);

  static Color get bg => dark ? _bgD : _bgL;
  static Color get surface => dark ? _surfaceD : _surfaceL;
  static Color get surfaceAlt => dark ? _surfaceAltD : _surfaceAltL;
  static Color get surfaceRaised => dark ? _surfaceRaisedD : _surfaceRaisedL;
  static Color get hairline => dark ? _hairlineD : _hairlineL;
  static Color get hairlineStrong => dark ? _hairlineStrongD : _hairlineStrongL;

  static Color get text => dark ? _textD : _textL;
  static Color get textMuted => dark ? _textMutedD : _textMutedL;
  static Color get textFaint => dark ? _textFaintD : _textFaintL;

  static const accent = Color(0xFF4D6BFE); // DeepSeek-ish muted blue
  static const accentSoft = Color(0x1A4D6BFE);
  static const success = Color(0xFF3ECF8E);
  static const warn = Color(0xFFE8B44C);
  static const danger = Color(0xFFE5534B);

  // Light-mode readable variants for success/danger on white surfaces.
  static Color get successC => dark ? success : const Color(0xFF1FA05F);
  static Color get dangerC => dark ? danger : const Color(0xFFD23B33);

  static const mono = 'JetBrainsMono';

  static ThemeData theme() {
    final base = dark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);
    return base.copyWith(
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {TargetPlatform.android: _FadeSlideTransitionsBuilder()},
      ),
      scaffoldBackgroundColor: bg,
      dividerColor: hairline,
      colorScheme: (dark ? const ColorScheme.dark() : const ColorScheme.light())
          .copyWith(
            surface: surface,
            primary: accent,
            secondary: accent,
            onSurface: text,
            error: dangerC,
          ),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: text,
          letterSpacing: 0.1,
        ),
        iconTheme: IconThemeData(color: textMuted, size: 20),
      ),
      dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceAlt,
        hintStyle: TextStyle(color: textFaint, fontSize: 14),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: accent, width: 1.2),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: hairline),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceRaised,
        contentTextStyle: TextStyle(color: text, fontSize: 13),
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: hairline),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      textTheme: base.textTheme.apply(
        fontFamily: 'Inter',
        bodyColor: text,
        displayColor: text,
      ),
    );
  }
}

/// Small labeled tag (e.g. "FREE", "BYOK").
class Tag extends StatelessWidget {
  final String label;
  final Color color;
  final bool filled;
  const Tag(
    this.label, {
    super.key,
    this.color = const Color(0xFF9B9BA4),
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
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
