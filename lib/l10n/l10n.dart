import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

// The UI ships English only (`supportedLocales == [en]`). Hindi, Hinglish,
// Punjabi and Tamil are voice/assistant languages, not app-UI locales; see
// `lib/l10n/README.md` and the "Voice language" pickers.

/// English strings used when no [AppLocalizations] is in scope: widget tests
/// that pump a bare `MaterialApp`, and code that runs before the first frame.
final AppLocalizations appLocalizationsFallback = lookupAppLocalizations(
  const Locale('en'),
);

extension AppLocalizationsContext on BuildContext {
  /// Localized strings for this context, falling back to English.
  ///
  /// New user-facing copy belongs in `lib/l10n/app_en.arb`; read it through
  /// `context.l10n.someKey` instead of a string literal.
  AppLocalizations get l10n =>
      AppLocalizations.of(this) ?? appLocalizationsFallback;
}
