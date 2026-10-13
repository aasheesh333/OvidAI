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

  /// Section title for the prompt caching settings and the per-provider caching option.
  ///
  /// In en, this message translates to:
  /// **'Prompt caching'**
  String get promptCachingTitle;

  /// Switch title: reuse the system prompt, tools and history between turns.
  ///
  /// In en, this message translates to:
  /// **'Cache the prompt prefix'**
  String get promptCachePrefixTitle;

  /// Explains what prompt prefix caching does and its cost effect.
  ///
  /// In en, this message translates to:
  /// **'Reuses system prompt, tools and history between turns on providers that support it (Claude, and automatic caches). Cache reads cost about 0.1x input.'**
  String get promptCachePrefixSubtitle;

  /// Switch title: keep the prompt cache for one hour instead of five minutes.
  ///
  /// In en, this message translates to:
  /// **'Extended 1-hour cache'**
  String get promptCacheExtendedTitle;

  /// Explains the one-hour cache trade-off.
  ///
  /// In en, this message translates to:
  /// **'For long 24/7 sessions with pauses over 5 minutes. Cache writes cost 2x input instead of 1.25x; reads stay 0.1x. Claude only.'**
  String get promptCacheExtendedSubtitle;

  /// Help text under the per-provider prompt caching choice (Auto / On / Off).
  ///
  /// In en, this message translates to:
  /// **'Auto sends cache markers only where the endpoint is known to accept them. On forces markers for Anthropic-compatible proxies; Off never sends them.'**
  String get promptCacheProviderHelp;

  /// Tooltip and screen-reader label of the small x button that removes a staged attachment from the composer.
  ///
  /// In en, this message translates to:
  /// **'Remove attachment {name}'**
  String attachmentRemove(String name);

  /// Hint above the composer attachment row when the per-message attachment limit is near.
  ///
  /// In en, this message translates to:
  /// **'{count}/{max} files'**
  String attachmentCount(int count, int max);

  /// Screen-reader label of an attachment tile: full file name, file type and file size.
  ///
  /// In en, this message translates to:
  /// **'{name}, {type}, {size}'**
  String attachmentSemantics(String name, String type, String size);

  /// Screen-reader hint: tapping an attachment tile opens its preview.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get attachmentPreviewHint;

  /// Label of the placeholder tile shown while a picked file is being copied into the chat.
  ///
  /// In en, this message translates to:
  /// **'Adding file…'**
  String get attachmentStaging;

  /// Shown on an image attachment tile whose thumbnail could not be loaded.
  ///
  /// In en, this message translates to:
  /// **'Preview unavailable'**
  String get attachmentPreviewError;

  /// Button in the attachment info sheet: open the file in another app.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get attachmentOpen;

  /// Button in the attachment info sheet: share the file through the system share sheet.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get attachmentShare;

  /// Snackbar when no installed app can open an attachment.
  ///
  /// In en, this message translates to:
  /// **'No app can open {name}'**
  String attachmentNoApp(String name);

  /// Shown in the attachment info sheet when the file path of an older message is unknown.
  ///
  /// In en, this message translates to:
  /// **'This file is no longer available on this device.'**
  String get attachmentMissing;

  /// Attachment type name for screen readers: an image file.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get attachmentTypeImage;

  /// Attachment type name for screen readers: a PDF file.
  ///
  /// In en, this message translates to:
  /// **'PDF document'**
  String get attachmentTypePdf;

  /// Attachment type name for screen readers: a word-processor or rich-text document.
  ///
  /// In en, this message translates to:
  /// **'Document'**
  String get attachmentTypeDoc;

  /// Attachment type name for screen readers: a spreadsheet such as XLS or XLSX.
  ///
  /// In en, this message translates to:
  /// **'Spreadsheet'**
  String get attachmentTypeSheet;

  /// Attachment type name for screen readers: a comma-separated values file.
  ///
  /// In en, this message translates to:
  /// **'CSV table'**
  String get attachmentTypeCsv;

  /// Attachment type name for screen readers: a ZIP or other compressed archive.
  ///
  /// In en, this message translates to:
  /// **'Archive'**
  String get attachmentTypeArchive;

  /// Attachment type name for screen readers: source code or plain text.
  ///
  /// In en, this message translates to:
  /// **'Code or text file'**
  String get attachmentTypeCode;

  /// Attachment type name for screen readers: an audio recording or music file.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get attachmentTypeAudio;

  /// Attachment type name for screen readers: a video file.
  ///
  /// In en, this message translates to:
  /// **'Video'**
  String get attachmentTypeVideo;

  /// Attachment type name for screen readers: any other kind of file.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get attachmentTypeOther;

  /// Image receipts: heading when a completed image request has no saved copy on this device.
  ///
  /// In en, this message translates to:
  /// **'Image not saved on this device'**
  String get receiptResultNotOnDeviceTitle;

  /// Image receipts: explains the Recover image button for a completed request with no local copy.
  ///
  /// In en, this message translates to:
  /// **'Recover image downloads it again from this receipt. It never starts a new paid request.'**
  String get receiptResultNotOnDeviceBody;

  /// Image receipts: heading for a failed image request, which produced no image.
  ///
  /// In en, this message translates to:
  /// **'No image: the request failed'**
  String get receiptResultFailedTitle;

  /// Image receipts: body text for a failed image request.
  ///
  /// In en, this message translates to:
  /// **'Nothing was produced for this request. The summary above shows whether it was charged.'**
  String get receiptResultFailedBody;

  /// Image receipts: heading while an image request is pending or its outcome is unknown.
  ///
  /// In en, this message translates to:
  /// **'Result not ready yet'**
  String get receiptResultPendingTitle;

  /// Image receipts: body text while an image request is pending or unknown.
  ///
  /// In en, this message translates to:
  /// **'Check status to update this request. Do not submit a replacement.'**
  String get receiptResultPendingBody;

  /// Image receipts: heading when a saved or recovered image could not be decoded for preview.
  ///
  /// In en, this message translates to:
  /// **'Image preview failed'**
  String get receiptResultPreviewFailedTitle;

  /// Image receipts: result line after Recover image when the server no longer keeps the image bytes.
  ///
  /// In en, this message translates to:
  /// **'Image no longer available from the server'**
  String get receiptOutcomeNotOnServer;

  /// Usage screen app bar title.
  ///
  /// In en, this message translates to:
  /// **'Usage'**
  String get usageTitle;

  /// Tooltip for the Usage screen overflow menu.
  ///
  /// In en, this message translates to:
  /// **'More actions'**
  String get usageMoreActions;

  /// Usage screen menu item that opens the image receipts screen.
  ///
  /// In en, this message translates to:
  /// **'Image receipts'**
  String get usageImageReceipts;

  /// Product name shown in the Usage header. Usually not translated.
  ///
  /// In en, this message translates to:
  /// **'Ovid Cloud'**
  String get usageCloudName;

  /// Screen reader label for the plan pill in the Usage header.
  ///
  /// In en, this message translates to:
  /// **'Plan: {plan}'**
  String usagePlanSemantics(String plan);

  /// Usage header freshness line before the server has answered.
  ///
  /// In en, this message translates to:
  /// **'Saved plan · awaiting server confirmation'**
  String get usagePlanSaved;

  /// Usage header freshness line when the latest refresh failed and older data is shown.
  ///
  /// In en, this message translates to:
  /// **'Last known plan and allowance'**
  String get usagePlanLastKnown;

  /// Usage header freshness line when the server answered.
  ///
  /// In en, this message translates to:
  /// **'Server-confirmed plan and allowance'**
  String get usagePlanConfirmed;

  /// Caption noting the allowance comes from the server, not the device.
  ///
  /// In en, this message translates to:
  /// **'Server-authoritative'**
  String get usageServerAuthoritative;

  /// Overall plan allowance left, as a percentage. Never a price.
  ///
  /// In en, this message translates to:
  /// **'{percent}% remaining'**
  String usageRemainingPercent(int percent);

  /// Shown instead of the overall allowance bar when the server has not reported it.
  ///
  /// In en, this message translates to:
  /// **'Usage unavailable'**
  String get usageRemainingUnknown;

  /// Screen reader label for the overall allowance progress bar.
  ///
  /// In en, this message translates to:
  /// **'Plan allowance remaining'**
  String get usageOverallBarLabel;

  /// Allowance reset countdown, less than one minute left.
  ///
  /// In en, this message translates to:
  /// **'Resets in under a minute'**
  String get usageResetsUnderMinute;

  /// Allowance reset countdown in minutes (m = minutes).
  ///
  /// In en, this message translates to:
  /// **'Resets in {minutes}m'**
  String usageResetsInMinutes(int minutes);

  /// Allowance reset countdown in hours and minutes (h = hours, m = minutes).
  ///
  /// In en, this message translates to:
  /// **'Resets in {hours}h {minutes}m'**
  String usageResetsInHoursMinutes(int hours, int minutes);

  /// Allowance reset countdown in whole days (d = days).
  ///
  /// In en, this message translates to:
  /// **'Resets in {days}d'**
  String usageResetsInDays(int days);

  /// Allowance reset countdown in days and hours (d = days, h = hours).
  ///
  /// In en, this message translates to:
  /// **'Resets in {days}d {hours}h'**
  String usageResetsInDaysHours(int days, int hours);

  /// Usage header button when the allowance is exhausted.
  ///
  /// In en, this message translates to:
  /// **'Allowance used up · See plans'**
  String get usageUpgradeUsedUp;

  /// Usage header button when less than 10% of the allowance is left.
  ///
  /// In en, this message translates to:
  /// **'Running low · Upgrade'**
  String get usageUpgradeLow;

  /// Section heading for today's usage counters in the Usage header.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get usageTodayTitle;

  /// Label under today's request count.
  ///
  /// In en, this message translates to:
  /// **'Requests'**
  String get usageTodayRequests;

  /// Label under today's input (prompt) token count.
  ///
  /// In en, this message translates to:
  /// **'Input tokens'**
  String get usageTodayInput;

  /// Label under today's output (reply) token count.
  ///
  /// In en, this message translates to:
  /// **'Output tokens'**
  String get usageTodayOutput;

  /// Label under today's generated image count.
  ///
  /// In en, this message translates to:
  /// **'Images'**
  String get usageTodayImages;

  /// Note under today's counters when they come from this device instead of the server.
  ///
  /// In en, this message translates to:
  /// **'Counted on this device'**
  String get usageTodayDeviceNote;

  /// Note when some of today's token counts are local estimates.
  ///
  /// In en, this message translates to:
  /// **'≈ Includes estimates where the model sent no token counts'**
  String get usageTodayEstimatedNote;

  /// Note that Auto-mode requests are included in today's request count.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Includes 1 request in Auto mode} other{Includes {count} requests in Auto mode}}'**
  String usageTodayAutoNote(int count);

  /// Section heading for the per-model remaining usage list.
  ///
  /// In en, this message translates to:
  /// **'Remaining by model'**
  String get usageModelsTitle;

  /// Explains why models show different remaining counts. Must not mention prices or currency.
  ///
  /// In en, this message translates to:
  /// **'Each model has its own remaining usage: larger models use more of your plan per message, so they show fewer messages left.'**
  String get usageModelsFootnote;

  /// Approximate chat messages left for one model in the current window.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No messages left} =1{≈ 1 message left} other{≈ {count} messages left}}'**
  String usageModelMessagesLeft(int count);

  /// Approximate images left for one image model in the current window.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No images left} =1{≈ 1 image left} other{≈ {count} images left}}'**
  String usageModelImagesLeft(int count);

  /// Screen reader label for a model whose remaining usage is unknown (shown as a dash).
  ///
  /// In en, this message translates to:
  /// **'Remaining usage not known'**
  String get usageModelRemainingUnknown;

  /// Pill on the Auto model row: Auto picks a model for each request.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get usageModelAuto;

  /// Note under the Auto row explaining its remaining count is a conservative estimate.
  ///
  /// In en, this message translates to:
  /// **'Estimate · Auto picks a model for each request'**
  String get usageModelEstimateNote;

  /// Provider card line: requests sent in Auto mode, also counted under their served model.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 request in Auto mode} other{{count} requests in Auto mode}}'**
  String usageProviderAutoRequests(int count);

  /// Generic button that dismisses a dialog without changes.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// Generic button that saves the dialog's changes.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get actionSave;

  /// Generic destructive confirm button.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get actionDelete;

  /// Tooltip of the chat header button that opens Studio (editor + terminal).
  ///
  /// In en, this message translates to:
  /// **'Studio — code & terminal'**
  String get chatHeaderStudio;

  /// Tooltip of the chat header button that opens the in-app browser.
  ///
  /// In en, this message translates to:
  /// **'Browser — agent & login'**
  String get chatHeaderBrowser;

  /// Tooltip of the three-dot overflow menu button.
  ///
  /// In en, this message translates to:
  /// **'More options'**
  String get chatMenuMore;

  /// Accessibility label of the overflow menu button while background jobs exist.
  ///
  /// In en, this message translates to:
  /// **'More options, {count, plural, =1{1 background job} other{{count} background jobs}}'**
  String chatMenuMoreJobs(int count);

  /// Overflow menu item: share the current conversation.
  ///
  /// In en, this message translates to:
  /// **'Share chat'**
  String get chatMenuShare;

  /// Overflow menu item: start a new, empty chat.
  ///
  /// In en, this message translates to:
  /// **'New chat'**
  String get chatMenuNewChat;

  /// Overflow menu item that lists this chat's background jobs.
  ///
  /// In en, this message translates to:
  /// **'Background jobs ({count})'**
  String chatMenuJobs(int count);

  /// Overflow menu item: rename the current chat.
  ///
  /// In en, this message translates to:
  /// **'Rename chat'**
  String get chatMenuRename;

  /// Overflow menu item: open the chat's event ledger (trajectory).
  ///
  /// In en, this message translates to:
  /// **'Trajectory'**
  String get chatMenuTrajectory;

  /// Overflow menu item: open usage statistics and plan limits.
  ///
  /// In en, this message translates to:
  /// **'Usage & limits'**
  String get chatMenuUsage;

  /// Overflow menu item: delete the current chat (asks for confirmation).
  ///
  /// In en, this message translates to:
  /// **'Delete chat'**
  String get chatMenuDelete;

  /// Live label of the reasoning block while the model is thinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking…'**
  String get chatThinking;

  /// Live label of the reasoning block with the elapsed thinking time.
  ///
  /// In en, this message translates to:
  /// **'Thinking… {duration}'**
  String chatThinkingFor(String duration);

  /// Title of a finished reasoning block when its duration is unknown.
  ///
  /// In en, this message translates to:
  /// **'Thoughts'**
  String get chatThoughts;

  /// Title of a finished reasoning block with how long the model thought.
  ///
  /// In en, this message translates to:
  /// **'Thought for {duration}'**
  String chatThoughtFor(String duration);

  /// Accessibility label of a tool call that is still running.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get toolStatusRunning;

  /// Accessibility label of a tool call that finished successfully.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get toolStatusDone;

  /// Accessibility label of a tool call that failed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get toolStatusFailed;

  /// Accessibility label of a tool call that was stopped.
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get toolStatusStopped;

  /// Accessibility label of a tool call whose outcome is unknown (interrupted).
  ///
  /// In en, this message translates to:
  /// **'Status unknown'**
  String get toolStatusUnknown;

  /// Section label above a tool call's arguments in its expanded details.
  ///
  /// In en, this message translates to:
  /// **'Input'**
  String get toolDetailInput;

  /// Section label above a tool call's result in its expanded details.
  ///
  /// In en, this message translates to:
  /// **'Output'**
  String get toolDetailOutput;

  /// Tooltip: copies a tool call's output.
  ///
  /// In en, this message translates to:
  /// **'Copy output'**
  String get toolDetailCopy;

  /// Name shown on a subagent card when the agent type is unknown.
  ///
  /// In en, this message translates to:
  /// **'Subagent'**
  String get subagentDefaultName;

  /// Subagent card status while the subagent works.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get subagentStatusRunning;

  /// Subagent card status after the subagent finished.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get subagentStatusDone;

  /// Subagent card status after the subagent failed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get subagentStatusFailed;

  /// Subagent card status after the subagent was stopped.
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get subagentStatusStopped;

  /// Subagent card: how many tools the subagent called.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No tool uses} =1{1 tool use} other{{count} tool uses}}'**
  String subagentToolUses(int count);

  /// Subagent card: older tool rows hidden above the latest ones.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 earlier tool use} other{{count} earlier tool uses}}'**
  String subagentEarlierTools(int count);

  /// Subagent card body before the subagent called any tool.
  ///
  /// In en, this message translates to:
  /// **'No tool calls yet'**
  String get subagentNoToolsYet;

  /// Subagent card button that opens the subagent's full transcript.
  ///
  /// In en, this message translates to:
  /// **'Open transcript'**
  String get subagentOpenTranscript;

  /// Accessibility label of a subagent card header.
  ///
  /// In en, this message translates to:
  /// **'Subagent {name}: {status}'**
  String subagentCardSemantics(String name, String status);

  /// Header of the card listing files the agent produced this run.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Produced 1 file} other{Produced {count} files}}'**
  String chatProducedFiles(int count);

  /// Button that shows the remaining produced files.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{+1 more file} other{+{count} more files}}'**
  String chatProducedMore(int count);

  /// Title of the Artifacts screen and its sidebar / menu entry (uploaded and generated files).
  ///
  /// In en, this message translates to:
  /// **'Artifacts'**
  String get artifactsTitle;

  /// Artifacts filter tab: every item.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get artifactsFilterAll;

  /// Artifacts filter tab: files the user attached.
  ///
  /// In en, this message translates to:
  /// **'Uploaded'**
  String get artifactsFilterUploaded;

  /// Artifacts filter tab: files Ovid produced.
  ///
  /// In en, this message translates to:
  /// **'Generated'**
  String get artifactsFilterGenerated;

  /// Artifacts toggle: show items from every chat instead of only the current one.
  ///
  /// In en, this message translates to:
  /// **'All chats'**
  String get artifactsScopeAllChats;

  /// Artifacts empty-state title.
  ///
  /// In en, this message translates to:
  /// **'No artifacts yet'**
  String get artifactsEmptyTitle;

  /// Artifacts empty-state explanation.
  ///
  /// In en, this message translates to:
  /// **'Files you attach and files, images and pages Ovid creates will appear here.'**
  String get artifactsEmptyBody;

  /// Badge tooltip: the user attached this file.
  ///
  /// In en, this message translates to:
  /// **'Uploaded by you'**
  String get artifactOriginUploaded;

  /// Badge tooltip: Ovid produced this file.
  ///
  /// In en, this message translates to:
  /// **'Generated by Ovid'**
  String get artifactOriginGenerated;

  /// Accessibility hint for the long-press action on an artifact row.
  ///
  /// In en, this message translates to:
  /// **'Share or remove'**
  String get artifactActionsHint;

  /// Shares an artifact file.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get artifactShare;

  /// Hides an artifact from the Artifacts list; the file and chat stay.
  ///
  /// In en, this message translates to:
  /// **'Remove from list'**
  String get artifactRemoveFromList;

  /// Snackbar after hiding an artifact (with Undo).
  ///
  /// In en, this message translates to:
  /// **'Removed from Artifacts'**
  String get artifactRemoved;

  /// Accessibility label of an artifact card.
  ///
  /// In en, this message translates to:
  /// **'Open {name}'**
  String artifactOpenSemantics(String name);

  /// Artifact type label.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get artifactKindImage;

  /// Artifact type label for HTML artifacts.
  ///
  /// In en, this message translates to:
  /// **'Web page'**
  String get artifactKindHtml;

  /// Artifact type label.
  ///
  /// In en, this message translates to:
  /// **'Code'**
  String get artifactKindCode;

  /// Artifact type label.
  ///
  /// In en, this message translates to:
  /// **'Document'**
  String get artifactKindDocument;

  /// Artifact type label for other files.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get artifactKindFile;

  /// Tooltip: copies the previewed text/code.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get artifactCopy;

  /// Snackbar after copying an artifact's text.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get artifactCopied;

  /// Opens the artifact in another installed app.
  ///
  /// In en, this message translates to:
  /// **'Open with…'**
  String get artifactOpenWith;

  /// Opens a generated workspace file in Studio's editor.
  ///
  /// In en, this message translates to:
  /// **'Open in Studio'**
  String get artifactOpenInStudio;

  /// The artifact's file was moved, deleted, or lives only in a remote repo.
  ///
  /// In en, this message translates to:
  /// **'This file isn\'t on this device anymore.'**
  String get artifactNotOnDevice;

  /// Preview title when the artifact file is missing.
  ///
  /// In en, this message translates to:
  /// **'File not available'**
  String get artifactMissingTitle;

  /// Preview title for a text file above the preview size limit.
  ///
  /// In en, this message translates to:
  /// **'Too large to preview'**
  String get artifactTooLargeTitle;

  /// Preview hint for a file too large to show inline.
  ///
  /// In en, this message translates to:
  /// **'Open it in another app to read it.'**
  String get artifactTooLargeBody;

  /// Preview title for a binary file type Ovid cannot render.
  ///
  /// In en, this message translates to:
  /// **'No preview available'**
  String get artifactNoPreviewTitle;

  /// Preview hint for a binary file type.
  ///
  /// In en, this message translates to:
  /// **'Open it with another app or share it.'**
  String get artifactNoPreviewBody;

  /// Rename-chat dialog title.
  ///
  /// In en, this message translates to:
  /// **'Rename session'**
  String get sessionRenameTitle;

  /// Rename-chat validation error.
  ///
  /// In en, this message translates to:
  /// **'Session name cannot be empty'**
  String get sessionRenameEmpty;

  /// Delete-chat confirmation title.
  ///
  /// In en, this message translates to:
  /// **'Delete {title}?'**
  String sessionDeleteTitle(String title);

  /// Delete-chat confirmation body when nothing else is affected.
  ///
  /// In en, this message translates to:
  /// **'You can undo for a few seconds; after that this chat cannot be recovered.'**
  String get sessionDeleteImpactUndo;

  /// Delete-chat confirmation body listing what else is deleted or stopped.
  ///
  /// In en, this message translates to:
  /// **'This will permanently delete {details}. You can undo for a few seconds; after that this chat cannot be recovered.'**
  String sessionDeleteImpactDetails(String details);

  /// Delete-chat impact item.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 child session} other{{count} child sessions}}'**
  String sessionDeleteChildSessions(int count);

  /// Delete-chat impact item.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 sandbox workspace} other{{count} sandbox workspaces}}'**
  String sessionDeleteSandboxes(int count);

  /// Delete-chat impact item when the chat is mid-reply.
  ///
  /// In en, this message translates to:
  /// **'the running chat will be stopped'**
  String get sessionDeleteStopsRunning;

  /// Delete-chat impact item for running subagents.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 running descendant will be stopped} other{{count} running descendants will be stopped}}'**
  String sessionDeleteStopsDescendants(int count);

  /// Snackbar after deleting a chat (with Undo).
  ///
  /// In en, this message translates to:
  /// **'Chat deleted'**
  String get sessionDeleted;

  /// Snackbar when the durable delete failed and the chat was restored.
  ///
  /// In en, this message translates to:
  /// **'The chat could not be deleted and has been restored. Try again.'**
  String get sessionDeleteFailed;
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
