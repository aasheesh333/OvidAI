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
  String get errorQuotaExceeded =>
      'You\'ve reached your plan limit. It resets automatically.';

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

  @override
  String get receiptResultNotOnDeviceTitle => 'Image not saved on this device';

  @override
  String get receiptResultNotOnDeviceBody =>
      'Recover image downloads it again from this receipt. It never starts a new paid request.';

  @override
  String get receiptResultFailedTitle => 'No image: the request failed';

  @override
  String get receiptResultFailedBody =>
      'Nothing was produced for this request. The summary above shows whether it was charged.';

  @override
  String get receiptResultPendingTitle => 'Result not ready yet';

  @override
  String get receiptResultPendingBody =>
      'Check status to update this request. Do not submit a replacement.';

  @override
  String get receiptResultPreviewFailedTitle => 'Image preview failed';

  @override
  String get receiptOutcomeNotOnServer =>
      'Image no longer available from the server';

  @override
  String get usageTitle => 'Usage';

  @override
  String get usageMoreActions => 'More actions';

  @override
  String get usageImageReceipts => 'Image receipts';

  @override
  String get usageCloudName => 'Ovid Cloud';

  @override
  String usagePlanSemantics(String plan) {
    return 'Plan: $plan';
  }

  @override
  String get usagePlanSaved => 'Saved plan · awaiting server confirmation';

  @override
  String get usagePlanLastKnown => 'Last known plan and allowance';

  @override
  String get usagePlanConfirmed => 'Server-confirmed plan and allowance';

  @override
  String get usageServerAuthoritative => 'Server-authoritative';

  @override
  String usageRemainingPercent(int percent) {
    return '$percent% remaining';
  }

  @override
  String get usageRemainingUnknown => 'Usage unavailable';

  @override
  String get usageOverallBarLabel => 'Plan allowance remaining';

  @override
  String get usageResetsUnderMinute => 'Resets in under a minute';

  @override
  String usageResetsInMinutes(int minutes) {
    return 'Resets in ${minutes}m';
  }

  @override
  String usageResetsInHoursMinutes(int hours, int minutes) {
    return 'Resets in ${hours}h ${minutes}m';
  }

  @override
  String usageResetsInDays(int days) {
    return 'Resets in ${days}d';
  }

  @override
  String usageResetsInDaysHours(int days, int hours) {
    return 'Resets in ${days}d ${hours}h';
  }

  @override
  String get usageUpgradeUsedUp => 'Allowance used up · See plans';

  @override
  String get usageUpgradeLow => 'Running low · Upgrade';

  @override
  String get usageTodayTitle => 'Today';

  @override
  String get usageTodayRequests => 'Requests';

  @override
  String get usageTodayInput => 'Input tokens';

  @override
  String get usageTodayOutput => 'Output tokens';

  @override
  String get usageTodayImages => 'Images';

  @override
  String get usageTodayDeviceNote => 'Counted on this device';

  @override
  String get usageTodayEstimatedNote =>
      '≈ Includes estimates where the model sent no token counts';

  @override
  String usageTodayAutoNote(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Includes $count requests in Auto mode',
      one: 'Includes 1 request in Auto mode',
    );
    return '$_temp0';
  }

  @override
  String get usageModelsTitle => 'Remaining by model';

  @override
  String get usageModelsFootnote =>
      'Each model has its own remaining usage: larger models use more of your plan per message, so they show fewer messages left.';

  @override
  String usageModelMessagesLeft(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '≈ $count messages left',
      one: '≈ 1 message left',
      zero: 'No messages left',
    );
    return '$_temp0';
  }

  @override
  String usageModelImagesLeft(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '≈ $count images left',
      one: '≈ 1 image left',
      zero: 'No images left',
    );
    return '$_temp0';
  }

  @override
  String get usageModelRemainingUnknown => 'Remaining usage not known';

  @override
  String get usageModelAuto => 'Auto';

  @override
  String get usageModelEstimateNote =>
      'Estimate · Auto picks a model for each request';

  @override
  String usageProviderAutoRequests(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count requests in Auto mode',
      one: '1 request in Auto mode',
    );
    return '$_temp0';
  }

  @override
  String get notificationOpen => 'Open';

  @override
  String get bgCardTitle => 'Background reliability';

  @override
  String get bgCardReady =>
      'All set. Ovid can run schedules and agent tasks while it is closed.';

  @override
  String bgCardNeedsAttention(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count settings need attention',
      one: '1 setting needs attention',
    );
    return '$_temp0';
  }

  @override
  String get bgNotificationsTitle => 'Notifications';

  @override
  String get bgNotificationsOk =>
      'Allowed. You\'ll hear when a task finishes or needs you.';

  @override
  String get bgNotificationsNeeded =>
      'Blocked. Ovid can\'t tell you when work finishes or needs approval.';

  @override
  String get bgBatteryTitle => 'Battery optimization';

  @override
  String get bgBatteryOk =>
      'Unrestricted. Android won\'t pause Ovid in the background.';

  @override
  String get bgBatteryNeeded =>
      'Restricted. Android may pause Ovid and delay scheduled tasks.';

  @override
  String get bgExactTitle => 'Exact alarms';

  @override
  String get bgExactOk => 'Allowed. Scheduled tasks start on time.';

  @override
  String get bgExactNeeded =>
      'Not allowed. Scheduled tasks may start late because Android batches them.';

  @override
  String bgOemTitle(String maker) {
    return '$maker background settings';
  }

  @override
  String bgOemBody(String maker) {
    return '$maker phones can stop apps despite the settings above. Allow Ovid to autostart and run in the background.';
  }

  @override
  String get bgActionAllow => 'Allow';

  @override
  String get bgActionOpen => 'Open';

  @override
  String get bgActionGuide => 'Guide';

  @override
  String get bgStatusOk => 'Done';

  @override
  String get bgStatusNeeded => 'Needs attention';

  @override
  String get bgKeepActiveTitle => 'Keep Ovid active in background';

  @override
  String get bgKeepActiveOn =>
      'On. A quiet status notification keeps schedules and agent runs working when Ovid is closed, and after a restart.';

  @override
  String get bgKeepActiveOff =>
      'Off. Ovid only wakes for scheduled tasks and while a run is in progress.';

  @override
  String get bgChannelsTitle => 'Notification types';

  @override
  String get bgChannelAgent => 'Agent updates';

  @override
  String get bgChannelAgentHint =>
      'Finished, needs input or approval, long jobs done';

  @override
  String get bgChannelSchedule => 'Scheduled task results';

  @override
  String get bgChannelScheduleHint =>
      'Success or failure, with a short summary';

  @override
  String get bgChannelStatus => 'Background status';

  @override
  String get bgChannelStatusHint => 'Silent notification while Ovid is active';

  @override
  String get bgSoundChime => 'Ovid chime';

  @override
  String get bgSoundSystem => 'System default';

  @override
  String get bgSoundSilent => 'Silent';

  @override
  String get bgSoundLabel => 'Sound';

  @override
  String get bgChannelSystemSettings =>
      'Android settings for this notification type';

  @override
  String get actionCancel => 'Cancel';

  @override
  String get actionSave => 'Save';

  @override
  String get actionDelete => 'Delete';

  @override
  String get chatHeaderStudio => 'Studio — code & terminal';

  @override
  String get chatHeaderBrowser => 'Browser — agent & login';

  @override
  String get chatMenuMore => 'More options';

  @override
  String chatMenuMoreJobs(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count background jobs',
      one: '1 background job',
    );
    return 'More options, $_temp0';
  }

  @override
  String get chatMenuShare => 'Share chat';

  @override
  String get chatMenuNewChat => 'New chat';

  @override
  String chatMenuJobs(int count) {
    return 'Background jobs ($count)';
  }

  @override
  String get chatMenuRename => 'Rename chat';

  @override
  String get chatMenuTrajectory => 'Trajectory';

  @override
  String get chatMenuUsage => 'Usage & limits';

  @override
  String get chatMenuDelete => 'Delete chat';

  @override
  String get chatThinking => 'Thinking…';

  @override
  String chatThinkingFor(String duration) {
    return 'Thinking… $duration';
  }

  @override
  String get chatThoughts => 'Thoughts';

  @override
  String chatThoughtFor(String duration) {
    return 'Thought for $duration';
  }

  @override
  String get toolStatusRunning => 'Running';

  @override
  String get toolStatusDone => 'Done';

  @override
  String get toolStatusFailed => 'Failed';

  @override
  String get toolStatusStopped => 'Stopped';

  @override
  String get toolStatusUnknown => 'Status unknown';

  @override
  String get toolDetailInput => 'Input';

  @override
  String get toolDetailOutput => 'Output';

  @override
  String get toolDetailCopy => 'Copy output';

  @override
  String get subagentDefaultName => 'Subagent';

  @override
  String get subagentStatusRunning => 'Running';

  @override
  String get subagentStatusDone => 'Done';

  @override
  String get subagentStatusFailed => 'Failed';

  @override
  String get subagentStatusStopped => 'Stopped';

  @override
  String subagentToolUses(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tool uses',
      one: '1 tool use',
      zero: 'No tool uses',
    );
    return '$_temp0';
  }

  @override
  String subagentEarlierTools(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count earlier tool uses',
      one: '1 earlier tool use',
    );
    return '$_temp0';
  }

  @override
  String get subagentNoToolsYet => 'No tool calls yet';

  @override
  String get subagentOpenTranscript => 'Open transcript';

  @override
  String subagentCardSemantics(String name, String status) {
    return 'Subagent $name: $status';
  }

  @override
  String chatProducedFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Produced $count files',
      one: 'Produced 1 file',
    );
    return '$_temp0';
  }

  @override
  String chatProducedMore(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '+$count more files',
      one: '+1 more file',
    );
    return '$_temp0';
  }

  @override
  String get artifactsTitle => 'Artifacts';

  @override
  String get artifactsFilterAll => 'All';

  @override
  String get artifactsFilterUploaded => 'Uploaded';

  @override
  String get artifactsFilterGenerated => 'Generated';

  @override
  String get artifactsScopeAllChats => 'All chats';

  @override
  String get artifactsEmptyTitle => 'No artifacts yet';

  @override
  String get artifactsEmptyBody =>
      'Files you attach and files, images and pages Ovid creates will appear here.';

  @override
  String get artifactOriginUploaded => 'Uploaded by you';

  @override
  String get artifactOriginGenerated => 'Generated by Ovid';

  @override
  String get artifactActionsHint => 'Share or remove';

  @override
  String get artifactShare => 'Share';

  @override
  String get artifactRemoveFromList => 'Remove from list';

  @override
  String get artifactRemoved => 'Removed from Artifacts';

  @override
  String artifactOpenSemantics(String name) {
    return 'Open $name';
  }

  @override
  String get artifactKindImage => 'Image';

  @override
  String get artifactKindHtml => 'Web page';

  @override
  String get artifactKindCode => 'Code';

  @override
  String get artifactKindDocument => 'Document';

  @override
  String get artifactKindFile => 'File';

  @override
  String get artifactCopy => 'Copy';

  @override
  String get artifactCopied => 'Copied to clipboard';

  @override
  String get artifactOpenWith => 'Open with…';

  @override
  String get artifactOpenInStudio => 'Open in Studio';

  @override
  String get artifactNotOnDevice => 'This file isn\'t on this device anymore.';

  @override
  String get artifactMissingTitle => 'File not available';

  @override
  String get artifactTooLargeTitle => 'Too large to preview';

  @override
  String get artifactTooLargeBody => 'Open it in another app to read it.';

  @override
  String get artifactNoPreviewTitle => 'No preview available';

  @override
  String get artifactNoPreviewBody => 'Open it with another app or share it.';

  @override
  String get sessionRenameTitle => 'Rename session';

  @override
  String get sessionRenameEmpty => 'Session name cannot be empty';

  @override
  String sessionDeleteTitle(String title) {
    return 'Delete $title?';
  }

  @override
  String get sessionDeleteImpactUndo =>
      'You can undo for a few seconds; after that this chat cannot be recovered.';

  @override
  String sessionDeleteImpactDetails(String details) {
    return 'This will permanently delete $details. You can undo for a few seconds; after that this chat cannot be recovered.';
  }

  @override
  String sessionDeleteChildSessions(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count child sessions',
      one: '1 child session',
    );
    return '$_temp0';
  }

  @override
  String sessionDeleteSandboxes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count sandbox workspaces',
      one: '1 sandbox workspace',
    );
    return '$_temp0';
  }

  @override
  String get sessionDeleteStopsRunning => 'the running chat will be stopped';

  @override
  String sessionDeleteStopsDescendants(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count running descendants will be stopped',
      one: '1 running descendant will be stopped',
    );
    return '$_temp0';
  }

  @override
  String get sessionDeleted => 'Chat deleted';

  @override
  String get sessionDeleteFailed =>
      'The chat could not be deleted and has been restored. Try again.';

  @override
  String get scheduleCloudEmptyTitle => 'Schedules run in Ovid Cloud';

  @override
  String get scheduleCloudEmptyMessage =>
      'Sign in to Ovid Cloud to see and manage scheduled tasks. This build has no on-device scheduler.';

  @override
  String get scheduleLoadErrorTitle => 'Could not load schedules';

  @override
  String get scheduleCloudActive => 'Cloud scheduling active';

  @override
  String get scheduleCloudActiveMessage =>
      'Scheduled tasks run in Ovid Cloud, even when Ovid is closed. Results appear here and arrive as notifications.';

  @override
  String get scheduleRanLate => 'ran late';

  @override
  String get scheduleMissedRun => 'missed run';

  @override
  String get scheduleCron => 'Cron';

  @override
  String get scheduleCronLabel => 'Cron expression';

  @override
  String get scheduleCronHelper =>
      'Five fields (minute hour day month weekday).';
}
