import 'package:flutter/material.dart';

/// OvidAI design system — restrained monochrome dark theme with a single
/// muted indigo accent. Professional, calm, "no color noise".
class Aether {
  Aether._();

  static const bg = Color(0xFF0A0A0C);
  static const surface = Color(0xFF111114);
  static const surfaceAlt = Color(0xFF17171B);
  static const surfaceRaised = Color(0xFF1D1D23);
  static const hairline = Color(0xFF26262C);
  static const hairlineStrong = Color(0xFF33333B);

  static const text = Color(0xFFEDEDF0);
  static const textMuted = Color(0xFF9B9BA4);
  static const textFaint = Color(0xFF63636C);

  static const accent = Color(0xFF4D6BFE); // DeepSeek-ish muted blue
  static const accentSoft = Color(0x1A4D6BFE);
  static const success = Color(0xFF3ECF8E);
  static const warn = Color(0xFFE8B44C);
  static const danger = Color(0xFFE5534B);

  static const mono = 'monospace';

  static ThemeData theme() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      dividerColor: hairline,
      colorScheme: const ColorScheme.dark(
        surface: surface,
        primary: accent,
        secondary: accent,
        onSurface: text,
        error: danger,
      ),
      appBarTheme: const AppBarTheme(
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
      dividerTheme: const DividerThemeData(
        color: hairline,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceAlt,
        hintStyle: const TextStyle(color: textFaint, fontSize: 14),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: accent, width: 1.2),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: hairline),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: surfaceRaised,
        contentTextStyle: TextStyle(color: text, fontSize: 13),
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: hairline),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
    );
  }
}

/// Small labeled tag (e.g. "FREE", "BYOK").
class Tag extends StatelessWidget {
  final String label;
  final Color color;
  final bool filled;
  const Tag(this.label,
      {super.key, this.color = Aether.textMuted, this.filled = false});

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
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
              color: Aether.textFaint,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!,
                style:
                    const TextStyle(fontSize: 12.5, color: Aether.textMuted)),
          ],
        ],
      ),
    );
  }
}
