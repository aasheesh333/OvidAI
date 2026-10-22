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

  /// HTTP 402 — the plan allowance is used up.
  ///
  /// In en, this message translates to:
  /// **'You\'ve reached your plan limit. It resets automatically.'**
  String get errorQuotaExceeded;

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
  /// **'For long 24/7 chats with pauses over 5 minutes. Cache writes cost 2x input instead of 1.25x; reads stay 0.1x. Claude only.'**
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

  /// Snackbar action: opens the chat or screen a background notification refers to.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get notificationOpen;

  /// Settings card heading: whether Ovid can keep working while closed.
  ///
  /// In en, this message translates to:
  /// **'Background reliability'**
  String get bgCardTitle;

  /// Card summary when every background permission is granted.
  ///
  /// In en, this message translates to:
  /// **'All set. Ovid can run schedules and agent tasks while it is closed.'**
  String get bgCardReady;

  /// Card summary: number of background permissions still missing.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 setting needs attention} other{{count} settings need attention}}'**
  String bgCardNeedsAttention(int count);

  /// Requirement row: Android notification permission.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get bgNotificationsTitle;

  /// Notification permission granted.
  ///
  /// In en, this message translates to:
  /// **'Allowed. You\'ll hear when a task finishes or needs you.'**
  String get bgNotificationsOk;

  /// Notification permission missing.
  ///
  /// In en, this message translates to:
  /// **'Blocked. Ovid can\'t tell you when work finishes or needs approval.'**
  String get bgNotificationsNeeded;

  /// Requirement row: exemption from Android battery optimization.
  ///
  /// In en, this message translates to:
  /// **'Battery optimization'**
  String get bgBatteryTitle;

  /// Battery optimization exemption granted.
  ///
  /// In en, this message translates to:
  /// **'Unrestricted. Android won\'t pause Ovid in the background.'**
  String get bgBatteryOk;

  /// Battery optimization still applies to Ovid.
  ///
  /// In en, this message translates to:
  /// **'Restricted. Android may pause Ovid and delay scheduled tasks.'**
  String get bgBatteryNeeded;

  /// Requirement row: Android 'Alarms & reminders' permission.
  ///
  /// In en, this message translates to:
  /// **'Exact alarms'**
  String get bgExactTitle;

  /// Exact alarm permission granted (or not needed).
  ///
  /// In en, this message translates to:
  /// **'Allowed. Scheduled tasks start on time.'**
  String get bgExactOk;

  /// Exact alarm permission missing.
  ///
  /// In en, this message translates to:
  /// **'Not allowed. Scheduled tasks may start late because Android batches them.'**
  String get bgExactNeeded;

  /// Requirement row for phone makers with aggressive battery managers.
  ///
  /// In en, this message translates to:
  /// **'{maker} background settings'**
  String bgOemTitle(String maker);

  /// Guidance for phone makers that kill background apps.
  ///
  /// In en, this message translates to:
  /// **'{maker} phones can stop apps despite the settings above. Allow Ovid to autostart and run in the background.'**
  String bgOemBody(String maker);

  /// Button that requests a missing background permission.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get bgActionAllow;

  /// Button that opens the phone maker's background/autostart settings.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get bgActionOpen;

  /// Button that opens a web guide for the phone maker's battery settings.
  ///
  /// In en, this message translates to:
  /// **'Guide'**
  String get bgActionGuide;

  /// Accessibility label for a granted requirement tick.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get bgStatusOk;

  /// Accessibility label for a missing requirement.
  ///
  /// In en, this message translates to:
  /// **'Needs attention'**
  String get bgStatusNeeded;

  /// Switch: keep the background service running.
  ///
  /// In en, this message translates to:
  /// **'Keep Ovid active in background'**
  String get bgKeepActiveTitle;

  /// Subtitle when keep-active is on.
  ///
  /// In en, this message translates to:
  /// **'On. A quiet status notification keeps schedules and agent runs working when Ovid is closed, and after a restart.'**
  String get bgKeepActiveOn;

  /// Subtitle when keep-active is off.
  ///
  /// In en, this message translates to:
  /// **'Off. Ovid only wakes for scheduled tasks and while a run is in progress.'**
  String get bgKeepActiveOff;

  /// Heading above per-type notification settings.
  ///
  /// In en, this message translates to:
  /// **'Notification types'**
  String get bgChannelsTitle;

  /// Notification type: agent run finished / needs input / long job done.
  ///
  /// In en, this message translates to:
  /// **'Agent updates'**
  String get bgChannelAgent;

  /// Explains the Agent updates notification type.
  ///
  /// In en, this message translates to:
  /// **'Finished, needs input or approval, long jobs done'**
  String get bgChannelAgentHint;

  /// Notification type: results of scheduled tasks.
  ///
  /// In en, this message translates to:
  /// **'Scheduled task results'**
  String get bgChannelSchedule;

  /// Explains the Scheduled task results notification type.
  ///
  /// In en, this message translates to:
  /// **'Success or failure, with a short summary'**
  String get bgChannelScheduleHint;

  /// Notification type: silent 'Ovid is active' service notification.
  ///
  /// In en, this message translates to:
  /// **'Background status'**
  String get bgChannelStatus;

  /// Explains the Background status notification type.
  ///
  /// In en, this message translates to:
  /// **'Silent notification while Ovid is active'**
  String get bgChannelStatusHint;

  /// Sound choice: Ovid's own notification sound.
  ///
  /// In en, this message translates to:
  /// **'Ovid chime'**
  String get bgSoundChime;

  /// Sound choice: the phone's default notification sound.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get bgSoundSystem;

  /// Sound choice: no sound.
  ///
  /// In en, this message translates to:
  /// **'Silent'**
  String get bgSoundSilent;

  /// Label of the notification sound picker.
  ///
  /// In en, this message translates to:
  /// **'Sound'**
  String get bgSoundLabel;

  /// Tooltip: opens Android's settings for one notification channel.
  ///
  /// In en, this message translates to:
  /// **'Android settings for this notification type'**
  String get bgChannelSystemSettings;

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

  /// Tooltip of the chat header button that opens Studio (the cloud workspace file editor).
  ///
  /// In en, this message translates to:
  /// **'Studio — your cloud files'**
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

  /// Artifact Vault tab: files Ovid produced across the account's chats.
  ///
  /// In en, this message translates to:
  /// **'Created by Ovid'**
  String get vaultTabGenerated;

  /// Artifact Vault tab: files the user attached across the account's chats.
  ///
  /// In en, this message translates to:
  /// **'Uploaded by User'**
  String get vaultTabUploaded;

  /// Artifact Vault type filter: no file-type restriction.
  ///
  /// In en, this message translates to:
  /// **'All types'**
  String get vaultTypeAll;

  /// Hint text of the Artifact Vault search field.
  ///
  /// In en, this message translates to:
  /// **'Search files'**
  String get vaultSearchHint;

  /// Button at the end of the Artifact Vault list: fetches the next page.
  ///
  /// In en, this message translates to:
  /// **'Load more'**
  String get vaultLoadMore;

  /// Artifact Vault error-state title when the inventory request failed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load your files'**
  String get vaultErrorTitle;

  /// Footnote in the Artifact Vault explaining account scope and link expiry.
  ///
  /// In en, this message translates to:
  /// **'Files from every chat in your account. Links to open or share are temporary and expire about an hour after they are created.'**
  String get vaultPolicyNote;

  /// Footnote in the guest-only local Artifacts view explaining its scope.
  ///
  /// In en, this message translates to:
  /// **'On this device — only files saved locally are listed. Sign in to see every file in your account.'**
  String get vaultLocalScope;

  /// Preview title when a cloud Vault file could not be fetched.
  ///
  /// In en, this message translates to:
  /// **'File not available'**
  String get artifactCloudMissingTitle;

  /// Preview message for the typed artifact_unavailable mint failure.
  ///
  /// In en, this message translates to:
  /// **'This file is no longer stored in Ovid Cloud.'**
  String get artifactCloudUnavailableBody;

  /// Preview message for the typed artifact_incomplete mint failure.
  ///
  /// In en, this message translates to:
  /// **'This file did not finish uploading. Remove and re-attach it.'**
  String get artifactCloudIncompleteBody;

  /// Preview message for any other typed cloud mint failure.
  ///
  /// In en, this message translates to:
  /// **'Ovid Cloud could not prepare this file. Check your connection and retry.'**
  String get artifactCloudErrorBody;

  /// Preview title when the file belongs to the previously signed-in account.
  ///
  /// In en, this message translates to:
  /// **'Account changed'**
  String get artifactCloudAccountTitle;

  /// Preview message when the previewing account no longer owns the file.
  ///
  /// In en, this message translates to:
  /// **'This file belongs to a different account. Sign back in to open it.'**
  String get artifactCloudAccountBody;

  /// Rename-chat dialog title.
  ///
  /// In en, this message translates to:
  /// **'Rename chat'**
  String get sessionRenameTitle;

  /// Rename-chat validation error.
  ///
  /// In en, this message translates to:
  /// **'Chat name cannot be empty'**
  String get sessionRenameEmpty;

  /// Delete-chat confirmation title.
  ///
  /// In en, this message translates to:
  /// **'Delete {title}?'**
  String sessionDeleteTitle(String title);

  /// Delete-chat confirmation body when nothing else is affected.
  ///
  /// In en, this message translates to:
  /// **'This deletes the chat and its history on all your devices. Files in your Studio workspace are kept. You can undo for a few seconds.'**
  String get sessionDeleteImpactUndo;

  /// Delete-chat confirmation body listing what else is deleted or stopped.
  ///
  /// In en, this message translates to:
  /// **'This deletes the chat and its history on all your devices, and {details}. Files in your Studio workspace are kept. You can undo for a few seconds.'**
  String sessionDeleteImpactDetails(String details);

  /// Delete-chat impact item.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 subagent chat} other{{count} subagent chats}}'**
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

  /// Schedule screen empty state when the cloud-schedule feature is unavailable in this build.
  ///
  /// In en, this message translates to:
  /// **'Schedules run in Ovid Cloud'**
  String get scheduleCloudEmptyTitle;

  /// Schedule screen empty state body when cloud schedules are unavailable.
  ///
  /// In en, this message translates to:
  /// **'Sign in to Ovid Cloud to see and manage scheduled tasks. This build has no on-device scheduler.'**
  String get scheduleCloudEmptyMessage;

  /// Schedule screen error card title when the server list request fails.
  ///
  /// In en, this message translates to:
  /// **'Could not load schedules'**
  String get scheduleLoadErrorTitle;

  /// Schedule screen status strip headline.
  ///
  /// In en, this message translates to:
  /// **'Cloud scheduling active'**
  String get scheduleCloudActive;

  /// Schedule screen status strip explanation of server-side scheduling.
  ///
  /// In en, this message translates to:
  /// **'Scheduled tasks run in Ovid Cloud, even when Ovid is closed. Results appear here and arrive as notifications.'**
  String get scheduleCloudActiveMessage;

  /// Badge on a schedule whose last run fired inside the missed-run grace window.
  ///
  /// In en, this message translates to:
  /// **'ran late'**
  String get scheduleRanLate;

  /// Badge on a schedule paused because an occurrence was missed beyond the grace window.
  ///
  /// In en, this message translates to:
  /// **'missed run'**
  String get scheduleMissedRun;

  /// Recurrence choice for a cron trigger.
  ///
  /// In en, this message translates to:
  /// **'Cron'**
  String get scheduleCron;

  /// Field label for a five-field cron expression.
  ///
  /// In en, this message translates to:
  /// **'Cron expression'**
  String get scheduleCronLabel;

  /// Helper text under the cron expression field.
  ///
  /// In en, this message translates to:
  /// **'Five fields (minute hour day month weekday).'**
  String get scheduleCronHelper;

  /// App bar title of the screen listing every scheduled task on the account.
  ///
  /// In en, this message translates to:
  /// **'Schedules'**
  String get schedulesTitle;

  /// Button / tooltip / sheet title to create a scheduled task without the agent.
  ///
  /// In en, this message translates to:
  /// **'New schedule'**
  String get scheduleNew;

  /// Filter chip: show the schedules of every chat.
  ///
  /// In en, this message translates to:
  /// **'All chats'**
  String get scheduleScopeAll;

  /// Button that switches a daily/cron schedule to the phone's current time zone.
  ///
  /// In en, this message translates to:
  /// **'Use device zone ({zone})'**
  String scheduleUseDeviceZone(String zone);

  /// Label above the choice of chat that receives a new schedule's results.
  ///
  /// In en, this message translates to:
  /// **'Results go to'**
  String get scheduleResultsGoTo;

  /// Choice: a new schedule runs in its own new chat.
  ///
  /// In en, this message translates to:
  /// **'A new chat'**
  String get scheduleTargetNewChat;

  /// Label above the preset chips (every hour, every day, custom) when creating a schedule.
  ///
  /// In en, this message translates to:
  /// **'Quick start'**
  String get scheduleQuickStart;

  /// Recovery button on a failed schedule: open the editor.
  ///
  /// In en, this message translates to:
  /// **'Edit task'**
  String get scheduleRecoverEdit;

  /// Recovery button on a failed schedule: make it active again after review.
  ///
  /// In en, this message translates to:
  /// **'Resume schedule'**
  String get scheduleRecoverResume;

  /// Recovery button on a failed schedule: run it a single time now.
  ///
  /// In en, this message translates to:
  /// **'Run once now'**
  String get scheduleRecoverRunOnce;

  /// Menu action: run a scheduled task immediately (its schedule is unchanged).
  ///
  /// In en, this message translates to:
  /// **'Run now'**
  String get scheduleRunNow;

  /// Menu action: create a new schedule pre-filled from this one.
  ///
  /// In en, this message translates to:
  /// **'Duplicate'**
  String get scheduleDuplicate;

  /// Opens the chat that receives a schedule's results.
  ///
  /// In en, this message translates to:
  /// **'Open chat'**
  String get scheduleOpenChat;

  /// Section title listing a schedule's past runs.
  ///
  /// In en, this message translates to:
  /// **'Run history'**
  String get scheduleRunHistory;

  /// Run history is empty.
  ///
  /// In en, this message translates to:
  /// **'No runs yet.'**
  String get scheduleNoRuns;

  /// Schedule status strip while the list is loading.
  ///
  /// In en, this message translates to:
  /// **'Checking cloud scheduling…'**
  String get scheduleStripChecking;

  /// Schedule status strip when the list could not be loaded (never shown as active).
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reach cloud scheduling'**
  String get scheduleStripError;

  /// Settings screen title.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// Settings section heading.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get settingsAccount;

  /// Account row title when signed out.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get settingsYou;

  /// Account row subtitle when signed out.
  ///
  /// In en, this message translates to:
  /// **'Sign in to your account'**
  String get settingsSignInPrompt;

  /// Settings row: plan and billing screen.
  ///
  /// In en, this message translates to:
  /// **'Plan & billing'**
  String get settingsPlan;

  /// Subtitle of the Plan & billing row.
  ///
  /// In en, this message translates to:
  /// **'Your Ovid Cloud plan and upgrades'**
  String get settingsPlanSubtitle;

  /// Settings row: usage screen.
  ///
  /// In en, this message translates to:
  /// **'Usage'**
  String get settingsUsage;

  /// Subtitle of the Usage row.
  ///
  /// In en, this message translates to:
  /// **'Today\'s allowance and recent spend'**
  String get settingsUsageSubtitle;

  /// Settings section heading for chat preferences.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get settingsChat;

  /// Toggle: show the model reasoning in chats.
  ///
  /// In en, this message translates to:
  /// **'Show reasoning'**
  String get settingsShowReasoning;

  /// Show reasoning toggle, on state.
  ///
  /// In en, this message translates to:
  /// **'On: reasoning shows before answers'**
  String get settingsShowReasoningOn;

  /// Show reasoning toggle, off state.
  ///
  /// In en, this message translates to:
  /// **'Off: answers only'**
  String get settingsShowReasoningOff;

  /// Toggle: let Ovid save and recall memories.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get settingsMemory;

  /// Memory toggle, on state.
  ///
  /// In en, this message translates to:
  /// **'On: Ovid can save and recall facts you ask it to remember'**
  String get settingsMemoryOn;

  /// Memory toggle, off state.
  ///
  /// In en, this message translates to:
  /// **'Off: Ovid does not save or read memories'**
  String get settingsMemoryOff;

  /// Toggle: let chats search each other for context.
  ///
  /// In en, this message translates to:
  /// **'Share memory across chats'**
  String get settingsShareMemory;

  /// Share memory toggle, on state.
  ///
  /// In en, this message translates to:
  /// **'On: Ovid can search your other chats for context'**
  String get settingsShareMemoryOn;

  /// Share memory toggle, off state.
  ///
  /// In en, this message translates to:
  /// **'Off: each chat only sees itself. Tag a chat with @ to include it.'**
  String get settingsShareMemoryOff;

  /// Share memory toggle while Memory is off.
  ///
  /// In en, this message translates to:
  /// **'Turn on Memory to use this'**
  String get settingsShareMemoryNeedsMemory;

  /// Settings row: view and edit what Ovid remembers.
  ///
  /// In en, this message translates to:
  /// **'Memory files'**
  String get settingsMemoryFiles;

  /// Subtitle of the Memory files row.
  ///
  /// In en, this message translates to:
  /// **'See, edit or delete what Ovid remembers'**
  String get settingsMemoryFilesSubtitle;

  /// Settings section heading for models, keys and presets.
  ///
  /// In en, this message translates to:
  /// **'Models & keys'**
  String get settingsModels;

  /// Subtitle of the Your API keys row.
  ///
  /// In en, this message translates to:
  /// **'Run chats on your own provider account'**
  String get settingsKeysSubtitle;

  /// Subtitle of the Agent presets row.
  ///
  /// In en, this message translates to:
  /// **'Choose which tools and model the agent uses'**
  String get settingsPresetsSubtitle;

  /// Subtitle of the Responses row.
  ///
  /// In en, this message translates to:
  /// **'Answer length and the \"still working\" hint'**
  String get settingsResponsesSubtitle;

  /// Settings section heading and notifications toggle title.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get settingsNotifications;

  /// Settings section heading.
  ///
  /// In en, this message translates to:
  /// **'Data & privacy'**
  String get settingsData;

  /// Settings row: export or import chat archives.
  ///
  /// In en, this message translates to:
  /// **'Export & import'**
  String get settingsExport;

  /// Subtitle of the Export & import row.
  ///
  /// In en, this message translates to:
  /// **'Download your cloud chats or upload an archive'**
  String get settingsExportSubtitle;

  /// Telemetry consent toggle title.
  ///
  /// In en, this message translates to:
  /// **'Crash reports & analytics'**
  String get settingsTelemetry;

  /// Telemetry toggle, on state.
  ///
  /// In en, this message translates to:
  /// **'On: share crash reports and anonymous usage to help fix bugs'**
  String get settingsTelemetryOn;

  /// Telemetry toggle, off state.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get settingsTelemetryOff;

  /// Telemetry toggle when Firebase is not configured.
  ///
  /// In en, this message translates to:
  /// **'Not available in this build'**
  String get settingsTelemetryUnavailable;

  /// Settings row and screen title: on-device storage.
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get settingsStorage;

  /// Subtitle of the Storage row.
  ///
  /// In en, this message translates to:
  /// **'Space Ovid uses on this phone'**
  String get settingsStorageSubtitle;

  /// Settings row: sign out and wipe local data.
  ///
  /// In en, this message translates to:
  /// **'Clear this device'**
  String get settingsClearDevice;

  /// Subtitle of the Clear this device row.
  ///
  /// In en, this message translates to:
  /// **'Signs out and removes local data. Your cloud chats are kept.'**
  String get settingsClearDeviceSubtitle;

  /// Subtitle for an action this build cannot run.
  ///
  /// In en, this message translates to:
  /// **'Unavailable in this build'**
  String get settingsUnavailable;

  /// Settings row: delete the account and cloud data.
  ///
  /// In en, this message translates to:
  /// **'Delete account'**
  String get settingsDeleteAccount;

  /// Subtitle of the Delete account row.
  ///
  /// In en, this message translates to:
  /// **'Delete your account after a 24-hour grace period'**
  String get settingsDeleteAccountSubtitle;

  /// Settings section heading.
  ///
  /// In en, this message translates to:
  /// **'Help & about'**
  String get settingsHelp;

  /// Subtitle of the Service status row.
  ///
  /// In en, this message translates to:
  /// **'Check that Ovid Cloud and this device are working'**
  String get settingsStatusSubtitle;

  /// Row that shares the Ovid website.
  ///
  /// In en, this message translates to:
  /// **'Share Ovid'**
  String get settingsShare;

  /// Row that opens the privacy policy.
  ///
  /// In en, this message translates to:
  /// **'Privacy policy'**
  String get settingsPrivacy;

  /// Settings row and screen title.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAbout;

  /// Subtitle of the About row.
  ///
  /// In en, this message translates to:
  /// **'Ovid Si {version}'**
  String settingsAboutSubtitle(String version);

  /// A preference failed to save.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save that setting. Try again.'**
  String get settingsSaveFailed;

  /// Theme selector title.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get themeTitle;

  /// Theme subtitle in auto mode while light.
  ///
  /// In en, this message translates to:
  /// **'Auto (default): follows your phone, light now'**
  String get themeAutoLight;

  /// Theme subtitle in auto mode while dark.
  ///
  /// In en, this message translates to:
  /// **'Auto (default): follows your phone, dark now'**
  String get themeAutoDark;

  /// Theme subtitle in light mode.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// Theme subtitle in dark mode.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// Theme option that follows the OS.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get themeOptionAuto;

  /// Theme option.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeOptionLight;

  /// Theme option.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeOptionDark;

  /// Notifications toggle, on state.
  ///
  /// In en, this message translates to:
  /// **'On: get notified when a cloud run finishes, fails or needs your approval'**
  String get notificationsOn;

  /// Notifications toggle on while the OS permission is denied.
  ///
  /// In en, this message translates to:
  /// **'On, but Android is blocking notifications for Ovid'**
  String get notificationsOnBlocked;

  /// Notifications toggle, off state.
  ///
  /// In en, this message translates to:
  /// **'Off: Ovid Cloud sends no notifications to your devices'**
  String get notificationsOff;

  /// Row shown when notifications are blocked by the OS.
  ///
  /// In en, this message translates to:
  /// **'Blocked by Android'**
  String get notificationsBlockedTitle;

  /// Explains how to unblock notifications.
  ///
  /// In en, this message translates to:
  /// **'Allow notifications for Ovid in system settings.'**
  String get notificationsBlockedBody;

  /// Button: opens Android notification settings.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get notificationsOpenSettings;

  /// Row title for the device integrity check.
  ///
  /// In en, this message translates to:
  /// **'Device integrity'**
  String get integrityTitle;

  /// Device integrity check in progress.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get integrityChecking;

  /// Device integrity probe incomplete.
  ///
  /// In en, this message translates to:
  /// **'This device didn\'t return a complete result'**
  String get integrityUnavailable;

  /// Device integrity: nothing suspicious found.
  ///
  /// In en, this message translates to:
  /// **'No signs of root, hooking tools or a debugger (basic check)'**
  String get integrityClean;

  /// Device integrity on a virtual device.
  ///
  /// In en, this message translates to:
  /// **'This is an emulator, so its integrity can\'t be verified'**
  String get integrityEmulator;

  /// Device integrity: problems found.
  ///
  /// In en, this message translates to:
  /// **'At risk: {flags}. Your sign-in could be read by other apps.'**
  String integrityAtRisk(String flags);

  /// Integrity flag: device is rooted.
  ///
  /// In en, this message translates to:
  /// **'rooted'**
  String get integrityFlagRooted;

  /// Integrity flag: a hooking framework is installed.
  ///
  /// In en, this message translates to:
  /// **'hooking framework'**
  String get integrityFlagHooking;

  /// Integrity flag: a debugger is attached.
  ///
  /// In en, this message translates to:
  /// **'debugger attached'**
  String get integrityFlagDebugger;

  /// Snackbar after re-running the integrity check.
  ///
  /// In en, this message translates to:
  /// **'Checked again'**
  String get integrityRechecked;

  /// Storage screen section heading.
  ///
  /// In en, this message translates to:
  /// **'On this device'**
  String get storageOnDevice;

  /// Storage screen intro.
  ///
  /// In en, this message translates to:
  /// **'Your chats live in Ovid Cloud. This is the space the app uses on this phone.'**
  String get storageIntro;

  /// Storage row: cached chats.
  ///
  /// In en, this message translates to:
  /// **'Offline chat cache'**
  String get storageChats;

  /// Storage row subtitle.
  ///
  /// In en, this message translates to:
  /// **'Recent chats kept for offline reading'**
  String get storageChatsSubtitle;

  /// Storage row: cache directory.
  ///
  /// In en, this message translates to:
  /// **'Temporary files'**
  String get storageCache;

  /// Storage row subtitle.
  ///
  /// In en, this message translates to:
  /// **'Safe to clear'**
  String get storageCacheSubtitle;

  /// Storage row: support files.
  ///
  /// In en, this message translates to:
  /// **'App data'**
  String get storageApp;

  /// Storage row subtitle.
  ///
  /// In en, this message translates to:
  /// **'Needed to run Ovid. Removed by Clear this device.'**
  String get storageAppSubtitle;

  /// Storage total row.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get storageTotal;

  /// Confirm dialog title.
  ///
  /// In en, this message translates to:
  /// **'Clear temporary files?'**
  String get storageClearTitle;

  /// Confirm dialog body.
  ///
  /// In en, this message translates to:
  /// **'Frees {size}. Chats and settings are not touched.'**
  String storageClearBody(String size);

  /// Button that clears the cache.
  ///
  /// In en, this message translates to:
  /// **'Clear temporary files'**
  String get storageClearConfirm;

  /// Snackbar after clearing the cache.
  ///
  /// In en, this message translates to:
  /// **'Cleared {size}.'**
  String storageCleared(String size);

  /// Cache clear partly failed.
  ///
  /// In en, this message translates to:
  /// **'Some files couldn\'t be cleared. Try again in a moment.'**
  String get storageClearIncomplete;

  /// About screen version line.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String aboutVersion(String version);

  /// About screen maker line. Company name, do not translate.
  ///
  /// In en, this message translates to:
  /// **'by Dhanuk Softwares'**
  String get aboutMaker;

  /// About screen tagline.
  ///
  /// In en, this message translates to:
  /// **'Your AI agent in the cloud: chat, files, browsing and schedules.'**
  String get aboutTagline;

  /// Link to the website.
  ///
  /// In en, this message translates to:
  /// **'Website'**
  String get aboutWebsite;

  /// Link to the terms.
  ///
  /// In en, this message translates to:
  /// **'Terms of Service'**
  String get aboutTerms;

  /// Row that opens the licenses page.
  ///
  /// In en, this message translates to:
  /// **'Open-source licenses'**
  String get aboutLicenses;

  /// Licenses row subtitle.
  ///
  /// In en, this message translates to:
  /// **'Third-party software used by Ovid Si'**
  String get aboutLicensesSubtitle;

  /// Copyright line.
  ///
  /// In en, this message translates to:
  /// **'© {year} Dhanuk Softwares'**
  String aboutCopyright(int year);

  /// Relative time under a minute.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get timeJustNow;

  /// Relative time in minutes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 min ago} other{{count} min ago}}'**
  String timeMinutesAgo(int count);

  /// Relative time in hours.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 hour ago} other{{count} hours ago}}'**
  String timeHoursAgo(int count);

  /// Relative time in days.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 day ago} other{{count} days ago}}'**
  String timeDaysAgo(int count);

  /// A duration in seconds.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 second} other{{count} seconds}}'**
  String durationSeconds(int count);

  /// A duration in minutes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 minute} other{{count} minutes}}'**
  String durationMinutes(int count);

  /// Screen title and settings row for the user's own provider keys.
  ///
  /// In en, this message translates to:
  /// **'Your API keys'**
  String get keysTitle;

  /// Intro text of the keys screen.
  ///
  /// In en, this message translates to:
  /// **'Add a key from a model provider to run your chats on your own account with that provider. Keys are encrypted on Ovid\'s servers and never shown again.'**
  String get keysIntro;

  /// Keys failed to load.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load your keys'**
  String get keysLoadFailed;

  /// Card title showing which models chats run on.
  ///
  /// In en, this message translates to:
  /// **'Your chats use'**
  String get keysChatsUseTitle;

  /// Chats run on Ovid models.
  ///
  /// In en, this message translates to:
  /// **'Ovid models, counted against your Ovid allowance.'**
  String get keysChatsUseOvid;

  /// Chats run on the user's own key.
  ///
  /// In en, this message translates to:
  /// **'{model} with your {provider} key. These runs bill your provider account, not your Ovid allowance.'**
  String keysChatsUseKey(String model, String provider);

  /// Button: stop using the user's key for chats.
  ///
  /// In en, this message translates to:
  /// **'Use Ovid models instead'**
  String get keysUseOvidAction;

  /// Empty state of the keys list.
  ///
  /// In en, this message translates to:
  /// **'No keys yet.'**
  String get keysEmpty;

  /// Button: add a provider key.
  ///
  /// In en, this message translates to:
  /// **'Add a key'**
  String get keysAdd;

  /// Pill on the key chats use.
  ///
  /// In en, this message translates to:
  /// **'Used for chats'**
  String get keysInUse;

  /// Key test status.
  ///
  /// In en, this message translates to:
  /// **'Not tested yet'**
  String get keysNeverTested;

  /// Key test status, success.
  ///
  /// In en, this message translates to:
  /// **'Tested {ago}: working'**
  String keysLastTestedOk(String ago);

  /// Key test status, failure.
  ///
  /// In en, this message translates to:
  /// **'Tested {ago}: not working'**
  String keysLastTestedFailed(String ago);

  /// Button: test a key.
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get keysTest;

  /// Key test in progress.
  ///
  /// In en, this message translates to:
  /// **'Testing…'**
  String get keysTesting;

  /// Key test succeeded.
  ///
  /// In en, this message translates to:
  /// **'{provider} accepted the key.'**
  String keysTestOk(String provider);

  /// Key test failed.
  ///
  /// In en, this message translates to:
  /// **'The provider didn\'t accept the key. Check the key and try again.'**
  String get keysTestFailed;

  /// Button: route chats through this key.
  ///
  /// In en, this message translates to:
  /// **'Use for my chats'**
  String get keysUseForChats;

  /// Button: change the model used with this key.
  ///
  /// In en, this message translates to:
  /// **'Change model'**
  String get keysChangeModel;

  /// Dialog title.
  ///
  /// In en, this message translates to:
  /// **'Use this key for your chats'**
  String get keysUseForChatsTitle;

  /// Dialog body.
  ///
  /// In en, this message translates to:
  /// **'Every chat and scheduled task will run on this {provider} model. Enter the model id as your provider names it.'**
  String keysUseForChatsBody(String provider);

  /// Field label: provider model id.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get keysModelLabel;

  /// Validation: model id missing.
  ///
  /// In en, this message translates to:
  /// **'Enter a model id.'**
  String get keysModelRequired;

  /// Snackbar after choosing a key for chats.
  ///
  /// In en, this message translates to:
  /// **'Your chats now use {model}.'**
  String keysUsingNow(String model);

  /// Snackbar after switching back to Ovid models.
  ///
  /// In en, this message translates to:
  /// **'Your chats now use Ovid models.'**
  String get keysUsingOvid;

  /// Button: remove a key.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get keysRemove;

  /// Key removal in progress.
  ///
  /// In en, this message translates to:
  /// **'Removing…'**
  String get keysRemoving;

  /// Confirm dialog title.
  ///
  /// In en, this message translates to:
  /// **'Remove this key?'**
  String get keysRemoveTitle;

  /// Confirm dialog body.
  ///
  /// In en, this message translates to:
  /// **'The key is deleted from Ovid. You can add it again later.'**
  String get keysRemoveBody;

  /// Confirm dialog body when the key is in use.
  ///
  /// In en, this message translates to:
  /// **'Your chats use this key. After removing it they go back to Ovid models. You can add the key again later.'**
  String get keysRemoveInUseBody;

  /// Confirm button.
  ///
  /// In en, this message translates to:
  /// **'Remove key'**
  String get keysRemoveConfirm;

  /// Snackbar after removing a key.
  ///
  /// In en, this message translates to:
  /// **'Key removed.'**
  String get keysRemoved;

  /// Snackbar after adding a key.
  ///
  /// In en, this message translates to:
  /// **'Key saved.'**
  String get keysSaved;

  /// Section title for keys older versions stored on the device.
  ///
  /// In en, this message translates to:
  /// **'Keys saved on this phone only'**
  String get keysDeviceTitle;

  /// Explains device-only keys.
  ///
  /// In en, this message translates to:
  /// **'Older versions kept these keys on this phone, and Ovid Cloud never used them. Move a key to your account to use it, or delete it.'**
  String get keysDeviceBody;

  /// Button and screen title: move a device key to the cloud.
  ///
  /// In en, this message translates to:
  /// **'Move to my account'**
  String get keysDeviceMove;

  /// Intro of the move-key screen.
  ///
  /// In en, this message translates to:
  /// **'This uploads the key to your Ovid account, encrypted. It is then removed from this phone.'**
  String get keysDeviceMoveIntro;

  /// Confirm dialog title.
  ///
  /// In en, this message translates to:
  /// **'Delete this key from this phone?'**
  String get keysDeviceDeleteTitle;

  /// Confirm dialog body.
  ///
  /// In en, this message translates to:
  /// **'The {provider} key is deleted from this phone. This can\'t be undone.'**
  String keysDeviceDeleteBody(String provider);

  /// Confirm button and action label.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get keysDeviceDeleteConfirm;

  /// Snackbar.
  ///
  /// In en, this message translates to:
  /// **'Key deleted from this phone.'**
  String get keysDeviceDeleted;

  /// Add-key screen title.
  ///
  /// In en, this message translates to:
  /// **'Add a key'**
  String get keysAddTitle;

  /// Add-key screen intro.
  ///
  /// In en, this message translates to:
  /// **'Pick your provider and paste an API key from its dashboard.'**
  String get keysAddIntro;

  /// Field label.
  ///
  /// In en, this message translates to:
  /// **'Provider'**
  String get keysProviderLabel;

  /// Provider option for any OpenAI-compatible API.
  ///
  /// In en, this message translates to:
  /// **'Other (OpenAI-compatible)'**
  String get keysProviderOther;

  /// Field label for a custom provider.
  ///
  /// In en, this message translates to:
  /// **'Provider name'**
  String get keysProviderNameLabel;

  /// Validation.
  ///
  /// In en, this message translates to:
  /// **'Enter a name for this provider.'**
  String get keysProviderNameRequired;

  /// Field label: provider API base URL.
  ///
  /// In en, this message translates to:
  /// **'API address'**
  String get keysEndpointLabel;

  /// Helper text.
  ///
  /// In en, this message translates to:
  /// **'The provider\'s official HTTPS API address, for example https://api.example.com/v1'**
  String get keysEndpointHelper;

  /// Validation.
  ///
  /// In en, this message translates to:
  /// **'Enter the API address.'**
  String get keysEndpointRequired;

  /// Validation: not an https URL.
  ///
  /// In en, this message translates to:
  /// **'Use the provider\'s official https:// API address.'**
  String get keysEndpointHttps;

  /// Field label.
  ///
  /// In en, this message translates to:
  /// **'API key'**
  String get keysApiKeyLabel;

  /// Helper text under the key field.
  ///
  /// In en, this message translates to:
  /// **'Sent once, encrypted, never shown again'**
  String get keysApiKeyHelper;

  /// Validation.
  ///
  /// In en, this message translates to:
  /// **'Paste your API key.'**
  String get keysApiKeyRequired;

  /// Validation.
  ///
  /// In en, this message translates to:
  /// **'The key has spaces or line breaks. Paste just the key.'**
  String get keysApiKeyInvalid;

  /// Field label for a key nickname.
  ///
  /// In en, this message translates to:
  /// **'Name (optional)'**
  String get keysNameLabel;

  /// Button.
  ///
  /// In en, this message translates to:
  /// **'Save key'**
  String get keysSave;

  /// Save in progress.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get keysSaving;

  /// Server rejected the endpoint.
  ///
  /// In en, this message translates to:
  /// **'Use the provider\'s official HTTPS API address.'**
  String get keysErrorEndpoint;

  /// Server key limit reached.
  ///
  /// In en, this message translates to:
  /// **'You\'ve reached the limit of saved keys. Remove one first.'**
  String get keysErrorLimit;

  /// Key store unavailable.
  ///
  /// In en, this message translates to:
  /// **'Saving keys isn\'t available right now. Try again later.'**
  String get keysErrorUnavailable;

  /// Screen title and settings row.
  ///
  /// In en, this message translates to:
  /// **'Agent presets'**
  String get presetsTitle;

  /// Presets screen intro.
  ///
  /// In en, this message translates to:
  /// **'A preset decides which tools the agent may use, and can pin a model and temperature. Ovid enforces it on every run in that chat.'**
  String get presetsIntro;

  /// Presets failed to load.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load presets'**
  String get presetsLoadFailed;

  /// Section heading for built-in presets.
  ///
  /// In en, this message translates to:
  /// **'Built in'**
  String get presetsBuiltIn;

  /// Section heading for custom presets.
  ///
  /// In en, this message translates to:
  /// **'Yours'**
  String get presetsCustom;

  /// Empty state.
  ///
  /// In en, this message translates to:
  /// **'No custom presets yet.'**
  String get presetsCustomEmpty;

  /// Button and screen title.
  ///
  /// In en, this message translates to:
  /// **'New preset'**
  String get presetsNew;

  /// Button.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get presetsEdit;

  /// Screen title.
  ///
  /// In en, this message translates to:
  /// **'Edit preset'**
  String get presetsEditTitle;

  /// Button: apply the preset to the open chat.
  ///
  /// In en, this message translates to:
  /// **'Use in this chat'**
  String get presetsUseInChat;

  /// Pill on the preset the open chat uses.
  ///
  /// In en, this message translates to:
  /// **'In this chat'**
  String get presetsInThisChat;

  /// Snackbar after applying a preset.
  ///
  /// In en, this message translates to:
  /// **'Preset applied. It takes effect from your next message.'**
  String get presetsApplied;

  /// Snackbar when there is no cloud chat to apply to.
  ///
  /// In en, this message translates to:
  /// **'Open a chat and send a message first, then apply a preset.'**
  String get presetsNeedChat;

  /// Snackbar after saving a preset.
  ///
  /// In en, this message translates to:
  /// **'Saved {name}.'**
  String presetsSaved(String name);

  /// Confirm title.
  ///
  /// In en, this message translates to:
  /// **'Delete this preset?'**
  String get presetsDeleteTitle;

  /// Confirm body.
  ///
  /// In en, this message translates to:
  /// **'{name} is deleted. Chats using it go back to Standard.'**
  String presetsDeleteBody(String name);

  /// Confirm button and action label.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get presetsDeleteConfirm;

  /// Snackbar.
  ///
  /// In en, this message translates to:
  /// **'Preset deleted.'**
  String get presetsDeleted;

  /// Preset summary: nothing switched off.
  ///
  /// In en, this message translates to:
  /// **'All tools'**
  String get presetsAllTools;

  /// Preset summary: switched-off tool families.
  ///
  /// In en, this message translates to:
  /// **'Off: {tools}'**
  String presetsToolsOff(String tools);

  /// Preset summary: pinned model.
  ///
  /// In en, this message translates to:
  /// **'Model: {model}'**
  String presetsModelPin(String model);

  /// Preset temperature.
  ///
  /// In en, this message translates to:
  /// **'Temperature {value}'**
  String presetsTemperatureValue(String value);

  /// Field label.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get presetsNameLabel;

  /// Validation.
  ///
  /// In en, this message translates to:
  /// **'Give the preset a name.'**
  String get presetsNameRequired;

  /// Field label.
  ///
  /// In en, this message translates to:
  /// **'Description (optional)'**
  String get presetsDescriptionLabel;

  /// Section heading.
  ///
  /// In en, this message translates to:
  /// **'Tools'**
  String get presetsToolsTitle;

  /// Help text.
  ///
  /// In en, this message translates to:
  /// **'Switch off what this agent must not do. Switched-off tools are removed and refused.'**
  String get presetsToolsHelp;

  /// Field label.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get presetsModelLabel;

  /// Model option: do not pin a model.
  ///
  /// In en, this message translates to:
  /// **'The chat\'s model'**
  String get presetsModelChat;

  /// Toggle label.
  ///
  /// In en, this message translates to:
  /// **'Set temperature'**
  String get presetsTemperatureLabel;

  /// Temperature not set.
  ///
  /// In en, this message translates to:
  /// **'Provider default'**
  String get presetsTemperatureDefault;

  /// Button.
  ///
  /// In en, this message translates to:
  /// **'Save preset'**
  String get presetsSave;

  /// Screen title and settings row.
  ///
  /// In en, this message translates to:
  /// **'Responses'**
  String get responsesTitle;

  /// Section heading.
  ///
  /// In en, this message translates to:
  /// **'Answer length'**
  String get responsesLengthTitle;

  /// Help text.
  ///
  /// In en, this message translates to:
  /// **'The most an answer can use. Ovid Cloud allows up to 8K tokens.'**
  String get responsesLengthHelp;

  /// Answer length option: provider default.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get responsesLengthAuto;

  /// Section heading.
  ///
  /// In en, this message translates to:
  /// **'\"Still working\" hint'**
  String get responsesHintTitle;

  /// Help text.
  ///
  /// In en, this message translates to:
  /// **'When to show \"Still working…\" if the agent is quiet. It never stops the run.'**
  String get responsesHintHelp;

  /// Marks the default option.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get responsesHintDefault;

  /// Section heading.
  ///
  /// In en, this message translates to:
  /// **'Context window'**
  String get responsesContextTitle;

  /// Help text.
  ///
  /// In en, this message translates to:
  /// **'For information. Ovid Cloud summarizes long chats automatically.'**
  String get responsesContextHelp;

  /// Context window details.
  ///
  /// In en, this message translates to:
  /// **'Model: {model}\nContext window: {window} tokens\nOvid summarizes older messages at about {threshold} tokens.'**
  String responsesContextInfo(String model, String window, String threshold);

  /// Screen title.
  ///
  /// In en, this message translates to:
  /// **'Memory files'**
  String get memoryTitle;

  /// Screen intro.
  ///
  /// In en, this message translates to:
  /// **'Memory stays in the current chat unless you explicitly turn on sharing.'**
  String get memoryIntro;

  /// Memory screen: per-chat scope explanation.
  ///
  /// In en, this message translates to:
  /// **'Current chat only. Other chats cannot use these notes unless you explicitly tag this chat or turn on memory sharing.'**
  String get memoryScopeChat;

  /// Memory screen: shared-scope explanation.
  ///
  /// In en, this message translates to:
  /// **'Shared memory is on. These notes can be used by your chats. Turn off sharing in Settings to return to chat-only notes.'**
  String get memoryScopeShared;

  /// Memory screen: no active chat guidance.
  ///
  /// In en, this message translates to:
  /// **'Open a cloud chat first to manage its memory. A chat that has not been sent yet has no saved memory.'**
  String get memoryNeedChat;

  /// Empty state.
  ///
  /// In en, this message translates to:
  /// **'Nothing saved yet. Ask Ovid to remember something in a chat.'**
  String get memoryEmpty;

  /// Button and screen title.
  ///
  /// In en, this message translates to:
  /// **'New memory file'**
  String get memoryNew;

  /// File size.
  ///
  /// In en, this message translates to:
  /// **'{bytes} bytes'**
  String memorySize(int bytes);

  /// Confirm title.
  ///
  /// In en, this message translates to:
  /// **'Delete this memory file?'**
  String get memoryDeleteTitle;

  /// Confirm body.
  ///
  /// In en, this message translates to:
  /// **'Ovid forgets everything in {name}. This can\'t be undone.'**
  String memoryDeleteBody(String name);

  /// Confirm button and tooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get memoryDeleteConfirm;

  /// Snackbar.
  ///
  /// In en, this message translates to:
  /// **'Deleted {name}.'**
  String memoryDeleted(String name);

  /// Button.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get memorySave;

  /// Snackbar.
  ///
  /// In en, this message translates to:
  /// **'Memory saved.'**
  String get memorySaved;

  /// Field label.
  ///
  /// In en, this message translates to:
  /// **'File name'**
  String get memoryNameLabel;

  /// Helper text.
  ///
  /// In en, this message translates to:
  /// **'Letters, numbers, - or _, ending in .md'**
  String get memoryNameHelper;

  /// Validation.
  ///
  /// In en, this message translates to:
  /// **'Use a short name like notes.md (letters, numbers, - or _).'**
  String get memoryNameInvalid;

  /// Field label.
  ///
  /// In en, this message translates to:
  /// **'Notes (Markdown)'**
  String get memoryContentLabel;

  /// Validation.
  ///
  /// In en, this message translates to:
  /// **'Memory files can be up to 32 KB.'**
  String get memoryTooLong;

  /// No workspace yet.
  ///
  /// In en, this message translates to:
  /// **'Start a chat first. Memory lives in your cloud workspace.'**
  String get memoryNoWorkspace;

  /// Edit conflict.
  ///
  /// In en, this message translates to:
  /// **'This memory changed since you opened it. Go back and open it again.'**
  String get memoryConflict;

  /// Screen title and settings row.
  ///
  /// In en, this message translates to:
  /// **'Service status'**
  String get statusTitle;

  /// Check in progress.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get statusChecking;

  /// Tooltip: re-run the checks.
  ///
  /// In en, this message translates to:
  /// **'Check again'**
  String get statusRecheck;

  /// Headline: all checks pass.
  ///
  /// In en, this message translates to:
  /// **'Everything is working'**
  String get statusAllGood;

  /// Headline: degraded.
  ///
  /// In en, this message translates to:
  /// **'Mostly working. Some things may be slow or unavailable.'**
  String get statusPartial;

  /// Headline: a check failed.
  ///
  /// In en, this message translates to:
  /// **'Something isn\'t working. Chats may fail until it\'s fixed.'**
  String get statusProblem;

  /// Headline: server unreachable.
  ///
  /// In en, this message translates to:
  /// **'Ovid couldn\'t reach Ovid Cloud. Check your connection.'**
  String get statusUnreachable;

  /// Section heading.
  ///
  /// In en, this message translates to:
  /// **'Ovid Cloud'**
  String get statusCloudSection;

  /// Section heading.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get statusDeviceSection;

  /// Check: database.
  ///
  /// In en, this message translates to:
  /// **'Chats and history'**
  String get statusStorage;

  /// Check: queue.
  ///
  /// In en, this message translates to:
  /// **'Run queue'**
  String get statusQueue;

  /// Check: workers consuming runs.
  ///
  /// In en, this message translates to:
  /// **'Agents'**
  String get statusAgents;

  /// Check: model catalog.
  ///
  /// In en, this message translates to:
  /// **'Models'**
  String get statusModels;

  /// Check: authenticated request.
  ///
  /// In en, this message translates to:
  /// **'Sign-in'**
  String get statusAccount;

  /// Detail when signed out.
  ///
  /// In en, this message translates to:
  /// **'You\'re signed out'**
  String get statusSignedOut;

  /// Check: realtime ticket.
  ///
  /// In en, this message translates to:
  /// **'Live updates'**
  String get statusLive;

  /// Check: push registration.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get statusPush;

  /// Detail when push is not registered.
  ///
  /// In en, this message translates to:
  /// **'This device isn\'t registered for notifications'**
  String get statusPushOff;

  /// Row state.
  ///
  /// In en, this message translates to:
  /// **'Working'**
  String get statusOk;

  /// Row state.
  ///
  /// In en, this message translates to:
  /// **'Limited'**
  String get statusWarn;

  /// Row state.
  ///
  /// In en, this message translates to:
  /// **'Not working'**
  String get statusDown;

  /// Version line.
  ///
  /// In en, this message translates to:
  /// **'App version {version}'**
  String statusVersion(String version);

  /// Button: copy a support report.
  ///
  /// In en, this message translates to:
  /// **'Copy diagnostics'**
  String get statusCopyDiagnostics;

  /// Snackbar.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics copied. Paste them into your message to support.'**
  String get statusDiagnosticsCopied;

  /// Snackbar after pinning a chat.
  ///
  /// In en, this message translates to:
  /// **'Chat pinned'**
  String get sessionPinned;

  /// Snackbar after unpinning a chat.
  ///
  /// In en, this message translates to:
  /// **'Chat unpinned'**
  String get sessionUnpinned;

  /// Snackbar when pinning a chat fails.
  ///
  /// In en, this message translates to:
  /// **'Could not update the pin. Please try again.'**
  String get pinUpdateFailed;

  /// Snackbar after moving a chat into a project.
  ///
  /// In en, this message translates to:
  /// **'Added to project'**
  String get addedToProject;

  /// Snackbar after removing a chat from its project.
  ///
  /// In en, this message translates to:
  /// **'Removed from project'**
  String get removedFromProject;

  /// Snackbar when moving a chat to a project fails.
  ///
  /// In en, this message translates to:
  /// **'Could not move the chat. Please try again.'**
  String get moveChatFailed;

  /// Settings row title for saved browser logins.
  ///
  /// In en, this message translates to:
  /// **'Credentials vault'**
  String get credentialsVault;

  /// Settings row subtitle for saved browser logins.
  ///
  /// In en, this message translates to:
  /// **'Saved logins for the cloud browser'**
  String get credentialsVaultSubtitle;
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
