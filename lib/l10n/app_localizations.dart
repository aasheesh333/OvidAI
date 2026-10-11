import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// Button that repeats a failed action.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get actionRetry;

  /// Expands technical details under an error message.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get errorDetailsShow;

  /// Collapses technical details under an error message.
  ///
  /// In en, this message translates to:
  /// **'Hide details'**
  String get errorDetailsHide;

  /// Tooltip: copies the technical error details for support.
  ///
  /// In en, this message translates to:
  /// **'Copy details'**
  String get errorDetailsCopy;

  /// Confirmation after error details were copied to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Details copied'**
  String get errorDetailsCopied;

  /// Fallback for an error Ovid cannot classify.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Please try again.'**
  String get errorGeneric;

  /// Network unreachable, DNS failure, connection refused.
  ///
  /// In en, this message translates to:
  /// **'Ovid couldn\'t connect. Check your internet connection and try again.'**
  String get errorOffline;

  /// A request or operation timed out.
  ///
  /// In en, this message translates to:
  /// **'That took too long to respond. Please try again.'**
  String get errorTimeout;

  /// HTTP 401 or a rejected credential.
  ///
  /// In en, this message translates to:
  /// **'Your sign-in or key was rejected. Check it and try again.'**
  String get errorUnauthorized;

  /// HTTP 403.
  ///
  /// In en, this message translates to:
  /// **'You don\'t have permission to do that.'**
  String get errorForbidden;

  /// HTTP 404 or a missing resource.
  ///
  /// In en, this message translates to:
  /// **'Ovid couldn\'t find what it was looking for.'**
  String get errorNotFound;

  /// HTTP 429.
  ///
  /// In en, this message translates to:
  /// **'Too many requests right now. Wait a moment and try again.'**
  String get errorRateLimited;

  /// HTTP 5xx.
  ///
  /// In en, this message translates to:
  /// **'The service is having trouble right now. Please try again later.'**
  String get errorServer;

  /// Malformed or unexpected data (parse/type errors).
  ///
  /// In en, this message translates to:
  /// **'Ovid received an unexpected response. Please try again.'**
  String get errorBadResponse;

  /// A platform/plugin call failed (file picker, storage, etc.).
  ///
  /// In en, this message translates to:
  /// **'Your device couldn\'t complete that action.'**
  String get errorDevice;

  /// A file-system operation failed.
  ///
  /// In en, this message translates to:
  /// **'Ovid couldn\'t read or write the file.'**
  String get errorFile;

  /// An action was refused because of the app's current state.
  ///
  /// In en, this message translates to:
  /// **'That can\'t be done right now.'**
  String get errorNotNow;

  /// Shown in place of a widget that failed to build in release builds.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong showing this part of the screen.'**
  String get errorWidgetFallback;

  /// Resuming a scheduled task while background execution is stopped.
  ///
  /// In en, this message translates to:
  /// **'Background execution is paused. Resume it to run this task.'**
  String get scheduleErrorResumeBackgroundFirst;

  /// Inline action that resumes background execution.
  ///
  /// In en, this message translates to:
  /// **'Resume background'**
  String get scheduleActionResumeBackground;

  /// Resuming a task whose previous run has not finished stopping.
  ///
  /// In en, this message translates to:
  /// **'The previous run is still stopping. Try again in a moment.'**
  String get scheduleErrorPreviousRunStopping;

  /// Editing a task that is currently running.
  ///
  /// In en, this message translates to:
  /// **'Pause this task before editing it.'**
  String get scheduleErrorPauseBeforeEdit;

  /// The schedule specification was rejected.
  ///
  /// In en, this message translates to:
  /// **'That schedule isn\'t valid. Check the time, interval and retries.'**
  String get scheduleErrorInvalid;

  /// A schedule action succeeded.
  ///
  /// In en, this message translates to:
  /// **'Schedule updated.'**
  String get scheduleUpdated;

  /// A schedule action failed; reason is a full friendly sentence.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t update the schedule. {reason}'**
  String scheduleUpdateFailed(String reason);

  /// Fetching models returned HTTP 401/403.
  ///
  /// In en, this message translates to:
  /// **'Key rejected by provider. Check the API key and try again.'**
  String get providerFetchKeyRejected;

  /// Fetching models returned HTTP 404. Do not translate /models.
  ///
  /// In en, this message translates to:
  /// **'No /models endpoint at this URL. Check the base URL.'**
  String get providerFetchNoModelsEndpoint;

  /// Fetching models failed with a timeout or network error.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reach provider. Check the URL and your connection.'**
  String get providerFetchUnreachable;

  /// The /models response could not be parsed.
  ///
  /// In en, this message translates to:
  /// **'Unexpected response from provider. Check the base URL.'**
  String get providerFetchUnexpectedResponse;

  /// Fetching models returned HTTP 429.
  ///
  /// In en, this message translates to:
  /// **'Provider is limiting requests. Try again shortly.'**
  String get providerFetchRateLimited;

  /// Fetching models returned HTTP 5xx.
  ///
  /// In en, this message translates to:
  /// **'Provider is having trouble right now. Try again later.'**
  String get providerFetchServerError;

  /// Fetching models returned another non-200 status.
  ///
  /// In en, this message translates to:
  /// **'Provider refused the request. Check the key and URL.'**
  String get providerFetchFailed;

  /// The saved key cannot be sent as an HTTP header.
  ///
  /// In en, this message translates to:
  /// **'API key looks invalid (contains whitespace or extra text). Please re-enter your key.'**
  String get providerFetchInvalidKey;

  /// Skills screen failed to list uploaded skills.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load your skills.'**
  String get skillsLoadFailed;

  /// Picking or saving skill files failed; reason is a full friendly sentence.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t upload skills. {reason}'**
  String skillsUploadFailed(String reason);

  /// One skill file could not be copied.
  ///
  /// In en, this message translates to:
  /// **'{name} — {reason}'**
  String skillsUploadFileFailed(String name, String reason);

  /// Storage screen could not compute folder sizes.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t measure storage.'**
  String get storageMeasureFailed;

  /// Placeholder for a size that could not be measured.
  ///
  /// In en, this message translates to:
  /// **'—'**
  String get storageSizeUnknown;

  /// All in-app browser cookies were cleared.
  ///
  /// In en, this message translates to:
  /// **'Signed out of websites in the in-app browser.'**
  String get storageCookiesCleared;

  /// Some per-chat browser cookie jars could not be cleared.
  ///
  /// In en, this message translates to:
  /// **'Signed out of websites, but {count, plural, =1{1 chat browser profile} other{{count} chat browser profiles}} couldn\'t be cleared. Try again.'**
  String storageCookiesPartial(int count);

  /// Clearing cookies failed entirely.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t clear cookies on this device.'**
  String get storageCookiesFailed;

  /// Exporting chats to a JSON file failed; reason is a full friendly sentence.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t export chats. {reason}'**
  String settingsExportFailed(String reason);

  /// The selected backup file failed validation.
  ///
  /// In en, this message translates to:
  /// **'This file isn\'t a valid Ovid transcript archive.'**
  String get backupInvalidArchive;

  /// A backup step failed before anything was written.
  ///
  /// In en, this message translates to:
  /// **'{operation} failed. {reason} No data was changed.'**
  String backupFailedUnchanged(String operation, String reason);

  /// Restore failed while saving and the partial write was rolled back.
  ///
  /// In en, this message translates to:
  /// **'Restore failed. {reason} Any partial changes were undone.'**
  String backupRestoreRolledBack(String reason);

  /// Restore failed and its rollback could not be verified.
  ///
  /// In en, this message translates to:
  /// **'Restore failed, and Ovid couldn\'t confirm the partial restore was undone. Some restored chats or settings may remain. Check your chat list before trying again.'**
  String get backupRestoreRollbackUnverified;

  /// Number of Ovid Cloud models available.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 model} other{{count} models}}'**
  String cloudModelCount(int count);

  /// Ovid Cloud tile: idle with a stored key.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get cloudStatusNotConnected;

  /// Ovid Cloud tile: idle without an account.
  ///
  /// In en, this message translates to:
  /// **'Sign in to activate'**
  String get cloudStatusSignInToActivate;

  /// Ovid Cloud tile: minting the gateway key.
  ///
  /// In en, this message translates to:
  /// **'Connecting your account…'**
  String get cloudStatusConnecting;

  /// Ovid Cloud tile: fetching the model catalog.
  ///
  /// In en, this message translates to:
  /// **'Loading models…'**
  String get cloudStatusLoadingCatalog;

  /// Ovid Cloud tile: connected.
  ///
  /// In en, this message translates to:
  /// **'Signed in · {models}'**
  String cloudStatusReady(String models);

  /// Ovid Cloud tile: failed with no specific reason.
  ///
  /// In en, this message translates to:
  /// **'Ovid Cloud connection failed.'**
  String get cloudStatusFailed;

  /// Ovid Cloud tile: shown under a failure, with the last known model count.
  ///
  /// In en, this message translates to:
  /// **'{models} available · catalog may be out of date'**
  String cloudCatalogStale(String models);

  /// Button: re-fetch the Ovid Cloud model catalog.
  ///
  /// In en, this message translates to:
  /// **'Refresh models'**
  String get cloudRefreshModels;

  /// Disabled retry button while connecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get cloudConnectingButton;

  /// Button: retry the Ovid Cloud connection.
  ///
  /// In en, this message translates to:
  /// **'Retry connection'**
  String get cloudRetryConnection;

  /// Button: sign out after the Ovid Cloud session expired.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get cloudSignOut;

  /// Confirm dialog title for pausing all schedules.
  ///
  /// In en, this message translates to:
  /// **'Pause background execution?'**
  String get scheduleStopBackgroundTitle;

  /// Confirm dialog body for pausing all schedules.
  ///
  /// In en, this message translates to:
  /// **'This pauses {count, plural, =1{1 scheduled task} other{{count} scheduled tasks}} across all chats, and any scheduled run in progress is stopped. Replies you started yourself keep running. Resume brings the paused tasks back.'**
  String scheduleStopBackgroundMessage(int count);

  /// Confirm button for pausing all schedules.
  ///
  /// In en, this message translates to:
  /// **'Pause schedules'**
  String get scheduleStopBackgroundConfirm;

  /// Menu item and confirm button that permanently cancels a scheduled task.
  ///
  /// In en, this message translates to:
  /// **'Cancel task'**
  String get scheduleCancelTask;

  /// Confirm dialog title for cancelling a scheduled task.
  ///
  /// In en, this message translates to:
  /// **'Cancel this task?'**
  String get scheduleCancelTaskTitle;

  /// Cancel-task confirmation when the task is running.
  ///
  /// In en, this message translates to:
  /// **'The task is running now and will be stopped. A cancelled task never runs again; this cannot be undone.'**
  String get scheduleCancelTaskRunningMessage;

  /// Cancel-task confirmation when the task is idle.
  ///
  /// In en, this message translates to:
  /// **'A cancelled task never runs again; this cannot be undone. Use Pause to stop it temporarily.'**
  String get scheduleCancelTaskMessage;

  /// Dismiss button of the cancel-task confirmation.
  ///
  /// In en, this message translates to:
  /// **'Keep task'**
  String get scheduleKeepTask;

  /// Schedule editor: smallest allowed interval.
  ///
  /// In en, this message translates to:
  /// **'Minimum 5 minutes.'**
  String get scheduleMinimumInterval;

  /// Schedule editor: label above One-off / Daily / Interval.
  ///
  /// In en, this message translates to:
  /// **'Recurrence'**
  String get scheduleRecurrence;

  /// Schedule editor: expands the raw spec field.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get scheduleAdvanced;

  /// Schedule editor: label above the next-run preview.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get schedulePreview;

  /// Schedule details: label above the task prompt.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get scheduleDescription;

  /// Schedule details: label above the raw schedule spec.
  ///
  /// In en, this message translates to:
  /// **'Raw spec'**
  String get scheduleRawSpec;

  /// Dialog title when chats exceed a backup limit.
  ///
  /// In en, this message translates to:
  /// **'Backup limit reached'**
  String get backupLimitReachedTitle;

  /// Button: export only the chats that fit the backup limits.
  ///
  /// In en, this message translates to:
  /// **'Export recent chats'**
  String get backupExportRecent;

  /// Confirm dialog title before restoring a backup.
  ///
  /// In en, this message translates to:
  /// **'Restore backup?'**
  String get backupRestoreTitle;

  /// Confirm button: restore the validated backup.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get backupRestoreConfirm;

  /// Dismiss button in backup dialogs.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get backupCancel;

  /// Button: export chats as JSON for other tools (not restorable).
  ///
  /// In en, this message translates to:
  /// **'JSON (for other tools)'**
  String get backupJsonExport;

  /// Card title for the portable backup archive format.
  ///
  /// In en, this message translates to:
  /// **'Export-ready archive'**
  String get backupExportReadyTitle;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
