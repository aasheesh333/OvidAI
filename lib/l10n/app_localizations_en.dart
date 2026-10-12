// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get actionRetry => 'Retry';

  @override
  String get errorDetailsShow => 'Details';

  @override
  String get errorDetailsHide => 'Hide details';

  @override
  String get errorDetailsCopy => 'Copy details';

  @override
  String get errorDetailsCopied => 'Details copied';

  @override
  String get errorGeneric => 'Something went wrong. Please try again.';

  @override
  String get errorOffline =>
      'Ovid couldn\'t connect. Check your internet connection and try again.';

  @override
  String get errorTimeout => 'That took too long to respond. Please try again.';

  @override
  String get errorUnauthorized =>
      'Your sign-in or key was rejected. Check it and try again.';

  @override
  String get errorForbidden => 'You don\'t have permission to do that.';

  @override
  String get errorNotFound => 'Ovid couldn\'t find what it was looking for.';

  @override
  String get errorRateLimited =>
      'Too many requests right now. Wait a moment and try again.';

  @override
  String get errorServer =>
      'The service is having trouble right now. Please try again later.';

  @override
  String get errorBadResponse =>
      'Ovid received an unexpected response. Please try again.';

  @override
  String get errorDevice => 'Your device couldn\'t complete that action.';

  @override
  String get errorFile => 'Ovid couldn\'t read or write the file.';

  @override
  String get errorNotNow => 'That can\'t be done right now.';

  @override
  String get errorWidgetFallback =>
      'Something went wrong showing this part of the screen.';

  @override
  String get scheduleErrorResumeBackgroundFirst =>
      'Background execution is paused. Resume it to run this task.';

  @override
  String get scheduleActionResumeBackground => 'Resume background';

  @override
  String get scheduleErrorPreviousRunStopping =>
      'The previous run is still stopping. Try again in a moment.';

  @override
  String get scheduleErrorPauseBeforeEdit =>
      'Pause this task before editing it.';

  @override
  String get scheduleErrorInvalid =>
      'That schedule isn\'t valid. Check the time, interval and retries.';

  @override
  String get scheduleUpdated => 'Schedule updated.';

  @override
  String scheduleUpdateFailed(String reason) {
    return 'Couldn\'t update the schedule. $reason';
  }

  @override
  String get providerFetchKeyRejected =>
      'Key rejected by provider. Check the API key and try again.';

  @override
  String get providerFetchNoModelsEndpoint =>
      'No /models endpoint at this URL. Check the base URL.';

  @override
  String get providerFetchUnreachable =>
      'Couldn\'t reach provider. Check the URL and your connection.';

  @override
  String get providerFetchUnexpectedResponse =>
      'Unexpected response from provider. Check the base URL.';

  @override
  String get providerFetchRateLimited =>
      'Provider is limiting requests. Try again shortly.';

  @override
  String get providerFetchServerError =>
      'Provider is having trouble right now. Try again later.';

  @override
  String get providerFetchFailed =>
      'Provider refused the request. Check the key and URL.';

  @override
  String get providerFetchInvalidKey =>
      'API key looks invalid (contains whitespace or extra text). Please re-enter your key.';

  @override
  String get skillsLoadFailed => 'Couldn\'t load your skills.';

  @override
  String skillsUploadFailed(String reason) {
    return 'Couldn\'t upload skills. $reason';
  }

  @override
  String skillsUploadFileFailed(String name, String reason) {
    return '$name — $reason';
  }

  @override
  String get storageMeasureFailed => 'Couldn\'t measure storage.';

  @override
  String get storageSizeUnknown => '—';

  @override
  String get storageCookiesCleared =>
      'Signed out of websites in the in-app browser.';

  @override
  String storageCookiesPartial(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count chat browser profiles',
      one: '1 chat browser profile',
    );
    return 'Signed out of websites, but $_temp0 couldn\'t be cleared. Try again.';
  }

  @override
  String get storageCookiesFailed => 'Couldn\'t clear cookies on this device.';

  @override
  String settingsExportFailed(String reason) {
    return 'Couldn\'t export chats. $reason';
  }

  @override
  String get backupInvalidArchive =>
      'This file isn\'t a valid Ovid transcript archive.';

  @override
  String backupFailedUnchanged(String operation, String reason) {
    return '$operation failed. $reason No data was changed.';
  }

  @override
  String backupRestoreRolledBack(String reason) {
    return 'Restore failed. $reason Any partial changes were undone.';
  }

  @override
  String get backupRestoreRollbackUnverified =>
      'Restore failed, and Ovid couldn\'t confirm the partial restore was undone. Some restored chats or settings may remain. Check your chat list before trying again.';

  @override
  String cloudModelCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count models',
      one: '1 model',
    );
    return '$_temp0';
  }

  @override
  String get cloudStatusNotConnected => 'Not connected';

  @override
  String get cloudStatusSignInToActivate => 'Sign in to activate';

  @override
  String get cloudStatusConnecting => 'Connecting your account…';

  @override
  String get cloudStatusLoadingCatalog => 'Loading models…';

  @override
  String cloudStatusReady(String models) {
    return 'Signed in · $models';
  }

  @override
  String get cloudStatusFailed => 'Ovid Cloud connection failed.';

  @override
  String cloudCatalogStale(String models) {
    return '$models available · catalog may be out of date';
  }

  @override
  String get cloudRefreshModels => 'Refresh models';

  @override
  String get cloudConnectingButton => 'Connecting…';

  @override
  String get cloudRetryConnection => 'Retry connection';

  @override
  String get cloudSignOut => 'Sign out';

  @override
  String get scheduleStopBackgroundTitle => 'Pause background execution?';

  @override
  String scheduleStopBackgroundMessage(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count scheduled tasks',
      one: '1 scheduled task',
    );
    return 'This pauses $_temp0 across all chats, and any scheduled run in progress is stopped. Replies you started yourself keep running. Resume brings the paused tasks back.';
  }

  @override
  String get scheduleStopBackgroundConfirm => 'Pause schedules';

  @override
  String get scheduleCancelTask => 'Cancel task';

  @override
  String get scheduleCancelTaskTitle => 'Cancel this task?';

  @override
  String get scheduleCancelTaskRunningMessage =>
      'The task is running now and will be stopped. A cancelled task never runs again; this cannot be undone.';

  @override
  String get scheduleCancelTaskMessage =>
      'A cancelled task never runs again; this cannot be undone. Use Pause to stop it temporarily.';

  @override
  String get scheduleKeepTask => 'Keep task';

  @override
  String get scheduleMinimumInterval => 'Minimum 5 minutes.';

  @override
  String get scheduleRecurrence => 'Recurrence';

  @override
  String get scheduleAdvanced => 'Advanced';

  @override
  String get schedulePreview => 'Preview';

  @override
  String get scheduleDescription => 'Description';

  @override
  String get scheduleRawSpec => 'Raw spec';

  @override
  String get backupLimitReachedTitle => 'Backup limit reached';

  @override
  String get backupExportRecent => 'Export recent chats';

  @override
  String get backupRestoreTitle => 'Restore backup?';

  @override
  String get backupRestoreConfirm => 'Restore';

  @override
  String get backupCancel => 'Cancel';

  @override
  String get backupJsonExport => 'JSON (for other tools)';

  @override
  String get backupExportReadyTitle => 'Export-ready archive';

  @override
  String get promptCachingTitle => 'Prompt caching';

  @override
  String get promptCachePrefixTitle => 'Cache the prompt prefix';

  @override
  String get promptCachePrefixSubtitle =>
      'Reuses system prompt, tools and history between turns on providers that support it (Claude, and automatic caches). Cache reads cost about 0.1x input.';

  @override
  String get promptCacheExtendedTitle => 'Extended 1-hour cache';

  @override
  String get promptCacheExtendedSubtitle =>
      'For long 24/7 sessions with pauses over 5 minutes. Cache writes cost 2x input instead of 1.25x; reads stay 0.1x. Claude only.';

  @override
  String get promptCacheProviderHelp =>
      'Auto sends cache markers only where the endpoint is known to accept them. On forces markers for Anthropic-compatible proxies; Off never sends them.';

  @override
  String attachmentRemove(String name) {
    return 'Remove attachment $name';
  }

  @override
  String attachmentCount(int count, int max) {
    return '$count/$max files';
  }

  @override
  String attachmentSemantics(String name, String type, String size) {
    return '$name, $type, $size';
  }

  @override
  String get attachmentPreviewHint => 'Preview';

  @override
  String get attachmentStaging => 'Adding file…';

  @override
  String get attachmentPreviewError => 'Preview unavailable';

  @override
  String get attachmentOpen => 'Open';

  @override
  String get attachmentShare => 'Share';

  @override
  String attachmentNoApp(String name) {
    return 'No app can open $name';
  }

  @override
  String get attachmentMissing =>
      'This file is no longer available on this device.';

  @override
  String get attachmentTypeImage => 'Image';

  @override
  String get attachmentTypePdf => 'PDF document';

  @override
  String get attachmentTypeDoc => 'Document';

  @override
  String get attachmentTypeSheet => 'Spreadsheet';

  @override
  String get attachmentTypeCsv => 'CSV table';

  @override
  String get attachmentTypeArchive => 'Archive';

  @override
  String get attachmentTypeCode => 'Code or text file';

  @override
  String get attachmentTypeAudio => 'Audio';

  @override
  String get attachmentTypeVideo => 'Video';

  @override
  String get attachmentTypeOther => 'File';
}
