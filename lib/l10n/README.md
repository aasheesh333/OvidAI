# Localization status and the language pickers

## What ships today

The app UI is **English only**.

- `lib/l10n/app_en.arb` is the template and the only ARB file.
- `AppLocalizations.supportedLocales` is `[Locale('en')]`, so
  `MaterialApp` always resolves to English.
- Adding a UI locale is a real translation project: add `app_<code>.arb` with
  every key from the template, regenerate the `app_localizations*.dart`
  files, and add the locale to `supportedLocales`. Do not add a locale to
  `supportedLocales` before its ARB file exists.

## What the Hindi / Punjabi / Tamil / Hinglish pickers mean

They are **voice and assistant language** preferences, not app-UI languages:

- Onboarding: the step is titled **Voice & goal** and the choice group is
  **Voice language**. The choice is persisted under
  `ovid_onboarding_language` and is applied to
  `AppState.voiceLanguage` (dictation and spoken replies).
- Settings → Appearance: the row is **Voice language**, backed by
  `AppState.voiceLanguage`.
- The composer's dictation locale comes from the same id
  (`V2VoiceLocales` / `VoiceReplyService`).

The ids `hi`, `hinglish`, `pa`, `ta` are therefore *not* values for
`MaterialApp.locale`, and they are deliberately not written to `ovid_locale`
(see `lib/ui/v2/onboarding/onboarding_prefs.dart`).

The UI stays English while the person dictates or receives replies in one of
these languages. If the UI is ever translated, revisit this file and the
picker labels together.

## Formatting

Dates and times in `lib/core/format.dart` use `intl`'s `DateFormat` with an
optional `locale` argument (default: `Intl.getCurrentLocale()`). Relative-time
words (`now`, `in under a minute`, unit suffixes) live in `FormatStrings`, so a
future translation pass can supply a translated instance instead of editing
call sites. Non-English locales also need
`initializeDateFormatting(<locale>)` before the first format call.
