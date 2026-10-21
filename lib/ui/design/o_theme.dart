import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'o_motion.dart';
import 'o_tokens.dart';

/// The Ovid Si theme. Light is the fallback; the app follows the device by
/// default (`ThemeMode.system`) and the user may pin light or dark.
abstract final class OTheme {
  static const supportedModes = <String>{'system', 'light', 'dark'};

  /// Maps the persisted preference to a [ThemeMode]. Unknown values fall back
  /// to [ThemeMode.system] (and therefore to light when the platform has no
  /// preference).
  static ThemeMode modeFor(String value) => switch (value) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static String normalizeMode(String value) =>
      supportedModes.contains(value) ? value : 'system';

  static Brightness fallbackBrightness(BuildContext context) =>
      MediaQuery.maybeOf(context)?.platformBrightness ?? Brightness.light;

  static ThemeData light() => _build(OColors.light, Brightness.light);

  static ThemeData dark() => _build(OColors.dark, Brightness.dark);

  static ThemeData of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark() : light();

  static OColors colors(BuildContext context) => OColors.of(context);

  static ThemeData _build(OColors c, Brightness brightness) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: c.accentFill,
      onPrimary: c.onAccent,
      primaryContainer: c.accentSoft,
      onPrimaryContainer: c.accent,
      secondary: c.accent,
      onSecondary: c.onAccent,
      secondaryContainer: c.accentSoft,
      onSecondaryContainer: c.accent,
      tertiary: c.success,
      onTertiary: c.onAccent,
      error: c.danger,
      onError: c.onDanger,
      surface: c.surface,
      onSurface: c.text,
      surfaceContainerHighest: c.surfaceRaised,
      onSurfaceVariant: c.textMuted,
      outline: c.hairlineStrong,
      outlineVariant: c.hairline,
      shadow: const Color(0xFF000000),
      scrim: c.scrim,
      inverseSurface: c.text,
      onInverseSurface: c.bg,
      inversePrimary: c.accent,
    );

    final textTheme = TextTheme(
      displayLarge: OType.display,
      displayMedium: OType.h1,
      displaySmall: OType.h2,
      headlineLarge: OType.h1,
      headlineMedium: OType.h2,
      headlineSmall: OType.h3,
      titleLarge: OType.h3,
      titleMedium: OType.bodyStrong,
      titleSmall: OType.label,
      bodyLarge: OType.body,
      bodyMedium: OType.bodySm,
      bodySmall: OType.caption,
      labelLarge: OType.label,
      labelMedium: OType.caption,
      labelSmall: OType.overline,
    ).apply(bodyColor: c.text, displayColor: c.text);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: 'Inter',
      scaffoldBackgroundColor: c.bg,
      canvasColor: c.bg,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      extensions: <ThemeExtension<dynamic>>[c],
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: _OPageTransitionsBuilder(),
          TargetPlatform.iOS: _OPageTransitionsBuilder(),
          TargetPlatform.linux: _OPageTransitionsBuilder(),
          TargetPlatform.macOS: _OPageTransitionsBuilder(),
          TargetPlatform.windows: _OPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: c.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: OSpace.l,
        toolbarHeight: 56,
        systemOverlayStyle: brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        titleTextStyle: OType.h2.copyWith(color: c.text),
        iconTheme: IconThemeData(color: c.text, size: 22),
      ),
      iconTheme: IconThemeData(color: c.text, size: 22),
      dividerTheme: DividerThemeData(
        color: c.hairline,
        thickness: 1,
        space: 1,
      ),
      dividerColor: c.hairline,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surfaceAlt,
        isDense: false,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: OSpace.l,
          vertical: OSpace.controlPad,
        ),
        // Hints are 16 sp body copy, so they must clear the 4.5:1 body gate.
        // textFaint is the large-text/graphic token (3.73:1 on dark surface)
        // and is not allowed to carry body-size text.
        hintStyle: OType.body.copyWith(color: c.textMuted),
        labelStyle: OType.bodySm.copyWith(color: c.textMuted),
        helperStyle: OType.caption.copyWith(color: c.textFaint),
        errorStyle: OType.caption.copyWith(color: c.danger),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ORadius.m),
          borderSide: BorderSide(color: c.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ORadius.m),
          borderSide: BorderSide(color: c.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ORadius.m),
          borderSide: BorderSide(color: c.accentFill, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ORadius.m),
          borderSide: BorderSide(color: c.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ORadius.m),
          borderSide: BorderSide(color: c.danger, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.accentFill,
          foregroundColor: c.onAccent,
          disabledBackgroundColor: c.surfaceRaised,
          disabledForegroundColor: c.textFaint,
          minimumSize: const Size(OSpace.touch, OSpace.touch),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          textStyle: OType.label,
          shape: const StadiumBorder(),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.text,
          minimumSize: const Size(OSpace.touch, OSpace.touch),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          textStyle: OType.label,
          side: BorderSide(color: c.hairlineStrong),
          shape: const StadiumBorder(),
          elevation: 0,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.accent,
          minimumSize: const Size(OSpace.touch, OSpace.touch),
          textStyle: OType.label,
          shape: const StadiumBorder(),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: c.text,
          minimumSize: const Size(OSpace.touch, OSpace.touch),
          iconSize: 22,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        modalBackgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(ORadius.xl),
          ),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.surfaceRaised,
        contentTextStyle: OType.bodySm.copyWith(color: c.text),
        actionTextColor: c.accent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ORadius.m),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.accentFill,
        linearTrackColor: c.surfaceRaised,
        circularTrackColor: c.surfaceRaised,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: c.textMuted,
        textColor: c.text,
        contentPadding: const EdgeInsets.symmetric(horizontal: OSpace.l),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ORadius.m),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: c.surfaceRaised,
          borderRadius: BorderRadius.circular(ORadius.s),
          border: Border.all(color: c.hairline),
        ),
        textStyle: OType.caption.copyWith(color: c.text),
        waitDuration: const Duration(milliseconds: 500),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.surface,
        surfaceTintColor: Colors.transparent,
        // Flat system: menus separate from the page with a hairline and the
        // scrim, never with a drop shadow (the Stitch reference uses one).
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ORadius.m),
          side: BorderSide(color: c.hairline),
        ),
        textStyle: OType.bodySm.copyWith(color: c.text),
      ),
    );
  }
}

class _OPageTransitionsBuilder extends PageTransitionsBuilder {
  const _OPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (route.isFirst) return child;
    if (OMove.reduced(context)) return child;
    return OMove.pageTransition(animation, child);
  }
}
