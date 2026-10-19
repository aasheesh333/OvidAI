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
  String get chatHeaderStudio => 'Studio — your cloud files';

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
  String get vaultTabGenerated => 'Created by Ovid';

  @override
  String get vaultTabUploaded => 'Uploaded by User';

  @override
  String get vaultTypeAll => 'All types';

  @override
  String get vaultSearchHint => 'Search files';

  @override
  String get vaultLoadMore => 'Load more';

  @override
  String get vaultErrorTitle => 'Couldn\'t load your files';

  @override
  String get vaultPolicyNote =>
      'Files from every chat in your account. Links to open or share are temporary and expire about an hour after they are created.';

  @override
  String get vaultLocalScope =>
      'On this device — only files saved locally are listed. Sign in to see every file in your account.';

  @override
  String get artifactCloudMissingTitle => 'File not available';

  @override
  String get artifactCloudUnavailableBody =>
      'This file is no longer stored in Ovid Cloud.';

  @override
  String get artifactCloudIncompleteBody =>
      'This file did not finish uploading. Remove and re-attach it.';

  @override
  String get artifactCloudErrorBody =>
      'Ovid Cloud could not prepare this file. Check your connection and retry.';

  @override
  String get artifactCloudAccountTitle => 'Account changed';

  @override
  String get artifactCloudAccountBody =>
      'This file belongs to a different account. Sign back in to open it.';

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
      'This deletes the chat and its history on all your devices. Files in your Studio workspace are kept. You can undo for a few seconds.';

  @override
  String sessionDeleteImpactDetails(String details) {
    return 'This deletes the chat and its history on all your devices, and $details. Files in your Studio workspace are kept. You can undo for a few seconds.';
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

  @override
  String get schedulesTitle => 'Schedules';

  @override
  String get scheduleNew => 'New schedule';

  @override
  String get scheduleScopeAll => 'All chats';

  @override
  String scheduleUseDeviceZone(String zone) {
    return 'Use device zone ($zone)';
  }

  @override
  String get scheduleResultsGoTo => 'Results go to';

  @override
  String get scheduleTargetNewChat => 'A new chat';

  @override
  String get scheduleQuickStart => 'Quick start';

  @override
  String get scheduleRecoverEdit => 'Edit task';

  @override
  String get scheduleRecoverResume => 'Resume schedule';

  @override
  String get scheduleRecoverRunOnce => 'Run once now';

  @override
  String get scheduleRunNow => 'Run now';

  @override
  String get scheduleDuplicate => 'Duplicate';

  @override
  String get scheduleOpenChat => 'Open chat';

  @override
  String get scheduleRunHistory => 'Run history';

  @override
  String get scheduleNoRuns => 'No runs yet.';

  @override
  String get scheduleStripChecking => 'Checking cloud scheduling…';

  @override
  String get scheduleStripError => 'Couldn\'t reach cloud scheduling';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsAccount => 'Account';

  @override
  String get settingsYou => 'You';

  @override
  String get settingsSignInPrompt => 'Sign in to your account';

  @override
  String get settingsPlan => 'Plan & billing';

  @override
  String get settingsPlanSubtitle => 'Your Ovid Cloud plan and upgrades';

  @override
  String get settingsUsage => 'Usage';

  @override
  String get settingsUsageSubtitle => 'Today\'s allowance and recent spend';

  @override
  String get settingsChat => 'Chat';

  @override
  String get settingsShowReasoning => 'Show reasoning';

  @override
  String get settingsShowReasoningOn => 'On: reasoning shows before answers';

  @override
  String get settingsShowReasoningOff => 'Off: answers only';

  @override
  String get settingsMemory => 'Memory';

  @override
  String get settingsMemoryOn =>
      'On: Ovid can save and recall facts you ask it to remember';

  @override
  String get settingsMemoryOff => 'Off: Ovid does not save or read memories';

  @override
  String get settingsShareMemory => 'Share memory across chats';

  @override
  String get settingsShareMemoryOn =>
      'On: Ovid can search your other chats for context';

  @override
  String get settingsShareMemoryOff =>
      'Off: each chat only sees itself. Tag a chat with @ to include it.';

  @override
  String get settingsShareMemoryNeedsMemory => 'Turn on Memory to use this';

  @override
  String get settingsMemoryFiles => 'Memory files';

  @override
  String get settingsMemoryFilesSubtitle =>
      'See, edit or delete what Ovid remembers';

  @override
  String get settingsModels => 'Models & keys';

  @override
  String get settingsKeysSubtitle => 'Run chats on your own provider account';

  @override
  String get settingsPresetsSubtitle =>
      'Choose which tools and model the agent uses';

  @override
  String get settingsResponsesSubtitle =>
      'Answer length and the \"still working\" hint';

  @override
  String get settingsNotifications => 'Notifications';

  @override
  String get settingsData => 'Data & privacy';

  @override
  String get settingsExport => 'Export & import';

  @override
  String get settingsExportSubtitle =>
      'Download your cloud chats or upload an archive';

  @override
  String get settingsTelemetry => 'Crash reports & analytics';

  @override
  String get settingsTelemetryOn =>
      'On: share crash reports and anonymous usage to help fix bugs';

  @override
  String get settingsTelemetryOff => 'Off';

  @override
  String get settingsTelemetryUnavailable => 'Not available in this build';

  @override
  String get settingsStorage => 'Storage';

  @override
  String get settingsStorageSubtitle => 'Space Ovid uses on this phone';

  @override
  String get settingsClearDevice => 'Clear this device';

  @override
  String get settingsClearDeviceSubtitle =>
      'Signs out and removes local data. Your cloud chats are kept.';

  @override
  String get settingsUnavailable => 'Unavailable in this build';

  @override
  String get settingsDeleteAccount => 'Delete account';

  @override
  String get settingsDeleteAccountSubtitle =>
      'Permanently delete your account and cloud data';

  @override
  String get settingsHelp => 'Help & about';

  @override
  String get settingsStatusSubtitle =>
      'Check that Ovid Cloud and this device are working';

  @override
  String get settingsShare => 'Share Ovid';

  @override
  String get settingsPrivacy => 'Privacy policy';

  @override
  String get settingsAbout => 'About';

  @override
  String settingsAboutSubtitle(String version) {
    return 'Ovid Si $version';
  }

  @override
  String get settingsSaveFailed => 'Couldn\'t save that setting. Try again.';

  @override
  String get themeTitle => 'Theme';

  @override
  String get themeAutoLight => 'Auto (default): follows your phone, light now';

  @override
  String get themeAutoDark => 'Auto (default): follows your phone, dark now';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get themeOptionAuto => 'Auto';

  @override
  String get themeOptionLight => 'Light';

  @override
  String get themeOptionDark => 'Dark';

  @override
  String get notificationsOn =>
      'On: get notified when a cloud run finishes, fails or needs your approval';

  @override
  String get notificationsOnBlocked =>
      'On, but Android is blocking notifications for Ovid';

  @override
  String get notificationsOff =>
      'Off: Ovid Cloud sends no notifications to your devices';

  @override
  String get notificationsBlockedTitle => 'Blocked by Android';

  @override
  String get notificationsBlockedBody =>
      'Allow notifications for Ovid in system settings.';

  @override
  String get notificationsOpenSettings => 'Open settings';

  @override
  String get integrityTitle => 'Device integrity';

  @override
  String get integrityChecking => 'Checking…';

  @override
  String get integrityUnavailable =>
      'This device didn\'t return a complete result';

  @override
  String get integrityClean =>
      'No signs of root, hooking tools or a debugger (basic check)';

  @override
  String get integrityEmulator =>
      'This is an emulator, so its integrity can\'t be verified';

  @override
  String integrityAtRisk(String flags) {
    return 'At risk: $flags. Your sign-in could be read by other apps.';
  }

  @override
  String get integrityFlagRooted => 'rooted';

  @override
  String get integrityFlagHooking => 'hooking framework';

  @override
  String get integrityFlagDebugger => 'debugger attached';

  @override
  String get integrityRechecked => 'Checked again';

  @override
  String get storageOnDevice => 'On this device';

  @override
  String get storageIntro =>
      'Your chats live in Ovid Cloud. This is the space the app uses on this phone.';

  @override
  String get storageChats => 'Offline chat cache';

  @override
  String get storageChatsSubtitle => 'Recent chats kept for offline reading';

  @override
  String get storageCache => 'Temporary files';

  @override
  String get storageCacheSubtitle => 'Safe to clear';

  @override
  String get storageApp => 'App data';

  @override
  String get storageAppSubtitle =>
      'Needed to run Ovid. Removed by Clear this device.';

  @override
  String get storageTotal => 'Total';

  @override
  String get storageClearTitle => 'Clear temporary files?';

  @override
  String storageClearBody(String size) {
    return 'Frees $size. Chats and settings are not touched.';
  }

  @override
  String get storageClearConfirm => 'Clear temporary files';

  @override
  String storageCleared(String size) {
    return 'Cleared $size.';
  }

  @override
  String get storageClearIncomplete =>
      'Some files couldn\'t be cleared. Try again in a moment.';

  @override
  String aboutVersion(String version) {
    return 'Version $version';
  }

  @override
  String get aboutMaker => 'by Dhanuk Softwares';

  @override
  String get aboutTagline =>
      'Your AI agent in the cloud: chat, files, browsing and schedules.';

  @override
  String get aboutWebsite => 'Website';

  @override
  String get aboutTerms => 'Terms of Service';

  @override
  String get aboutLicenses => 'Open-source licenses';

  @override
  String get aboutLicensesSubtitle => 'Third-party software used by Ovid Si';

  @override
  String aboutCopyright(int year) {
    return '© $year Dhanuk Softwares';
  }

  @override
  String get timeJustNow => 'just now';

  @override
  String timeMinutesAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count min ago',
      one: '1 min ago',
    );
    return '$_temp0';
  }

  @override
  String timeHoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hours ago',
      one: '1 hour ago',
    );
    return '$_temp0';
  }

  @override
  String timeDaysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days ago',
      one: '1 day ago',
    );
    return '$_temp0';
  }

  @override
  String durationSeconds(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count seconds',
      one: '1 second',
    );
    return '$_temp0';
  }

  @override
  String durationMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutes',
      one: '1 minute',
    );
    return '$_temp0';
  }

  @override
  String get keysTitle => 'Your API keys';

  @override
  String get keysIntro =>
      'Add a key from a model provider to run your chats on your own account with that provider. Keys are encrypted on Ovid\'s servers and never shown again.';

  @override
  String get keysLoadFailed => 'Couldn\'t load your keys';

  @override
  String get keysChatsUseTitle => 'Your chats use';

  @override
  String get keysChatsUseOvid =>
      'Ovid models, counted against your Ovid allowance.';

  @override
  String keysChatsUseKey(String model, String provider) {
    return '$model with your $provider key. These runs bill your provider account, not your Ovid allowance.';
  }

  @override
  String get keysUseOvidAction => 'Use Ovid models instead';

  @override
  String get keysEmpty => 'No keys yet.';

  @override
  String get keysAdd => 'Add a key';

  @override
  String get keysInUse => 'Used for chats';

  @override
  String get keysNeverTested => 'Not tested yet';

  @override
  String keysLastTestedOk(String ago) {
    return 'Tested $ago: working';
  }

  @override
  String keysLastTestedFailed(String ago) {
    return 'Tested $ago: not working';
  }

  @override
  String get keysTest => 'Test';

  @override
  String get keysTesting => 'Testing…';

  @override
  String keysTestOk(String provider) {
    return '$provider accepted the key.';
  }

  @override
  String get keysTestFailed =>
      'The provider didn\'t accept the key. Check the key and try again.';

  @override
  String get keysUseForChats => 'Use for my chats';

  @override
  String get keysChangeModel => 'Change model';

  @override
  String get keysUseForChatsTitle => 'Use this key for your chats';

  @override
  String keysUseForChatsBody(String provider) {
    return 'Every chat and scheduled task will run on this $provider model. Enter the model id as your provider names it.';
  }

  @override
  String get keysModelLabel => 'Model';

  @override
  String get keysModelRequired => 'Enter a model id.';

  @override
  String keysUsingNow(String model) {
    return 'Your chats now use $model.';
  }

  @override
  String get keysUsingOvid => 'Your chats now use Ovid models.';

  @override
  String get keysRemove => 'Remove';

  @override
  String get keysRemoving => 'Removing…';

  @override
  String get keysRemoveTitle => 'Remove this key?';

  @override
  String get keysRemoveBody =>
      'The key is deleted from Ovid. You can add it again later.';

  @override
  String get keysRemoveInUseBody =>
      'Your chats use this key. After removing it they go back to Ovid models. You can add the key again later.';

  @override
  String get keysRemoveConfirm => 'Remove key';

  @override
  String get keysRemoved => 'Key removed.';

  @override
  String get keysSaved => 'Key saved.';

  @override
  String get keysDeviceTitle => 'Keys saved on this phone only';

  @override
  String get keysDeviceBody =>
      'Older versions kept these keys on this phone, and Ovid Cloud never used them. Move a key to your account to use it, or delete it.';

  @override
  String get keysDeviceMove => 'Move to my account';

  @override
  String get keysDeviceMoveIntro =>
      'This uploads the key to your Ovid account, encrypted. It is then removed from this phone.';

  @override
  String get keysDeviceDeleteTitle => 'Delete this key from this phone?';

  @override
  String keysDeviceDeleteBody(String provider) {
    return 'The $provider key is deleted from this phone. This can\'t be undone.';
  }

  @override
  String get keysDeviceDeleteConfirm => 'Delete';

  @override
  String get keysDeviceDeleted => 'Key deleted from this phone.';

  @override
  String get keysAddTitle => 'Add a key';

  @override
  String get keysAddIntro =>
      'Pick your provider and paste an API key from its dashboard.';

  @override
  String get keysProviderLabel => 'Provider';

  @override
  String get keysProviderOther => 'Other (OpenAI-compatible)';

  @override
  String get keysProviderNameLabel => 'Provider name';

  @override
  String get keysProviderNameRequired => 'Enter a name for this provider.';

  @override
  String get keysEndpointLabel => 'API address';

  @override
  String get keysEndpointHelper =>
      'The provider\'s official HTTPS API address, for example https://api.example.com/v1';

  @override
  String get keysEndpointRequired => 'Enter the API address.';

  @override
  String get keysEndpointHttps =>
      'Use the provider\'s official https:// API address.';

  @override
  String get keysApiKeyLabel => 'API key';

  @override
  String get keysApiKeyHelper => 'Sent once, encrypted, never shown again';

  @override
  String get keysApiKeyRequired => 'Paste your API key.';

  @override
  String get keysApiKeyInvalid =>
      'The key has spaces or line breaks. Paste just the key.';

  @override
  String get keysNameLabel => 'Name (optional)';

  @override
  String get keysSave => 'Save key';

  @override
  String get keysSaving => 'Saving…';

  @override
  String get keysErrorEndpoint =>
      'Use the provider\'s official HTTPS API address.';

  @override
  String get keysErrorLimit =>
      'You\'ve reached the limit of saved keys. Remove one first.';

  @override
  String get keysErrorUnavailable =>
      'Saving keys isn\'t available right now. Try again later.';

  @override
  String get presetsTitle => 'Agent presets';

  @override
  String get presetsIntro =>
      'A preset decides which tools the agent may use, and can pin a model and temperature. Ovid enforces it on every run in that chat.';

  @override
  String get presetsLoadFailed => 'Couldn\'t load presets';

  @override
  String get presetsBuiltIn => 'Built in';

  @override
  String get presetsCustom => 'Yours';

  @override
  String get presetsCustomEmpty => 'No custom presets yet.';

  @override
  String get presetsNew => 'New preset';

  @override
  String get presetsEdit => 'Edit';

  @override
  String get presetsEditTitle => 'Edit preset';

  @override
  String get presetsUseInChat => 'Use in this chat';

  @override
  String get presetsInThisChat => 'In this chat';

  @override
  String get presetsApplied =>
      'Preset applied. It takes effect from your next message.';

  @override
  String get presetsNeedChat =>
      'Open a chat and send a message first, then apply a preset.';

  @override
  String presetsSaved(String name) {
    return 'Saved $name.';
  }

  @override
  String get presetsDeleteTitle => 'Delete this preset?';

  @override
  String presetsDeleteBody(String name) {
    return '$name is deleted. Chats using it go back to Standard.';
  }

  @override
  String get presetsDeleteConfirm => 'Delete';

  @override
  String get presetsDeleted => 'Preset deleted.';

  @override
  String get presetsAllTools => 'All tools';

  @override
  String presetsToolsOff(String tools) {
    return 'Off: $tools';
  }

  @override
  String presetsModelPin(String model) {
    return 'Model: $model';
  }

  @override
  String presetsTemperatureValue(String value) {
    return 'Temperature $value';
  }

  @override
  String get presetsNameLabel => 'Name';

  @override
  String get presetsNameRequired => 'Give the preset a name.';

  @override
  String get presetsDescriptionLabel => 'Description (optional)';

  @override
  String get presetsToolsTitle => 'Tools';

  @override
  String get presetsToolsHelp =>
      'Switch off what this agent must not do. Switched-off tools are removed and refused.';

  @override
  String get presetsModelLabel => 'Model';

  @override
  String get presetsModelChat => 'The chat\'s model';

  @override
  String get presetsTemperatureLabel => 'Set temperature';

  @override
  String get presetsTemperatureDefault => 'Provider default';

  @override
  String get presetsSave => 'Save preset';

  @override
  String get responsesTitle => 'Responses';

  @override
  String get responsesLengthTitle => 'Answer length';

  @override
  String get responsesLengthHelp =>
      'The most an answer can use. Ovid Cloud allows up to 8K tokens.';

  @override
  String get responsesLengthAuto => 'Auto';

  @override
  String get responsesHintTitle => '\"Still working\" hint';

  @override
  String get responsesHintHelp =>
      'When to show \"Still working…\" if the agent is quiet. It never stops the run.';

  @override
  String get responsesHintDefault => 'Default';

  @override
  String get responsesContextTitle => 'Context window';

  @override
  String get responsesContextHelp =>
      'For information. Ovid Cloud summarizes long chats automatically.';

  @override
  String responsesContextInfo(String model, String window, String threshold) {
    return 'Model: $model\nContext window: $window tokens\nOvid summarizes older messages at about $threshold tokens.';
  }

  @override
  String get memoryTitle => 'Memory files';

  @override
  String get memoryIntro =>
      'Memory stays in the current chat unless you explicitly turn on sharing.';

  @override
  String get memoryScopeChat =>
      'Current chat only. Other chats cannot use these notes unless you explicitly tag this chat or turn on memory sharing.';

  @override
  String get memoryScopeShared =>
      'Shared memory is on. These notes can be used by your chats. Turn off sharing in Settings to return to chat-only notes.';

  @override
  String get memoryNeedChat =>
      'Open a cloud chat first to manage its memory. A chat that has not been sent yet has no saved memory.';

  @override
  String get memoryEmpty =>
      'Nothing saved yet. Ask Ovid to remember something in a chat.';

  @override
  String get memoryNew => 'New memory file';

  @override
  String memorySize(int bytes) {
    return '$bytes bytes';
  }

  @override
  String get memoryDeleteTitle => 'Delete this memory file?';

  @override
  String memoryDeleteBody(String name) {
    return 'Ovid forgets everything in $name. This can\'t be undone.';
  }

  @override
  String get memoryDeleteConfirm => 'Delete';

  @override
  String memoryDeleted(String name) {
    return 'Deleted $name.';
  }

  @override
  String get memorySave => 'Save';

  @override
  String get memorySaved => 'Memory saved.';

  @override
  String get memoryNameLabel => 'File name';

  @override
  String get memoryNameHelper => 'Letters, numbers, - or _, ending in .md';

  @override
  String get memoryNameInvalid =>
      'Use a short name like notes.md (letters, numbers, - or _).';

  @override
  String get memoryContentLabel => 'Notes (Markdown)';

  @override
  String get memoryTooLong => 'Memory files can be up to 32 KB.';

  @override
  String get memoryNoWorkspace =>
      'Start a chat first. Memory lives in your cloud workspace.';

  @override
  String get memoryConflict =>
      'This memory changed since you opened it. Go back and open it again.';

  @override
  String get statusTitle => 'Service status';

  @override
  String get statusChecking => 'Checking…';

  @override
  String get statusRecheck => 'Check again';

  @override
  String get statusAllGood => 'Everything is working';

  @override
  String get statusPartial =>
      'Mostly working. Some things may be slow or unavailable.';

  @override
  String get statusProblem =>
      'Something isn\'t working. Chats may fail until it\'s fixed.';

  @override
  String get statusUnreachable =>
      'Ovid couldn\'t reach Ovid Cloud. Check your connection.';

  @override
  String get statusCloudSection => 'Ovid Cloud';

  @override
  String get statusDeviceSection => 'This device';

  @override
  String get statusStorage => 'Chats and history';

  @override
  String get statusQueue => 'Run queue';

  @override
  String get statusAgents => 'Agents';

  @override
  String get statusModels => 'Models';

  @override
  String get statusAccount => 'Sign-in';

  @override
  String get statusSignedOut => 'You\'re signed out';

  @override
  String get statusLive => 'Live updates';

  @override
  String get statusPush => 'Notifications';

  @override
  String get statusPushOff => 'This device isn\'t registered for notifications';

  @override
  String get statusOk => 'Working';

  @override
  String get statusWarn => 'Limited';

  @override
  String get statusDown => 'Not working';

  @override
  String statusVersion(String version) {
    return 'App version $version';
  }

  @override
  String get statusCopyDiagnostics => 'Copy diagnostics';

  @override
  String get statusDiagnosticsCopied =>
      'Diagnostics copied. Paste them into your message to support.';
}
