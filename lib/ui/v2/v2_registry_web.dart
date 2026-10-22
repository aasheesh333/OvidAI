import 'dart:math' as math;

import '../design/o_components.dart';
import '../design/o_screen.dart' show OBreakpoints;
import '../design/o_tokens.dart';
import 'app/app_lock_settings_page.dart';
import 'browser/browser_page.dart';
import 'browser/tab_strip.dart';
import 'browser/take_control_sheet.dart';
import 'browser/viewport.dart';
import 'chat/chat_page.dart';
import 'chat/composer_plus_sheet.dart';
import 'chat/live_chat_page.dart';
import 'chat/model_chip.dart';
import 'chat/model_chip_menu.dart';
import 'chat/chat_model_preview.dart';
import 'chat/model_picker_preview.dart';
import 'chat/permission_sheet.dart';
import 'chat/queue_dock.dart';
import 'collab/collab_live_page.dart';
import 'collab/collab_members_page.dart';
import 'collab/turn_banner.dart';
import 'connectors/add_connector_page.dart';
import 'connectors/connector_detail_page.dart';
import 'connectors/connector_permissions.dart';
import 'connectors/connectors_page.dart';
import 'library/artifact_detail_page.dart';
import 'library/artifact_filters.dart';
import 'library/artifact_preview.dart';
import 'library/artifacts_page.dart';
import 'onboarding/language_goal_page.dart';
import 'onboarding/onboarding_welcome.dart';
import 'onboarding/paywall_page.dart';
import 'onboarding/phone_auth_sheet.dart';
import 'onboarding/purchase_banner.dart';
import 'onboarding/sign_in_page.dart';
import 'onboarding/splash_page.dart';
import 'onboarding/step_progress.dart';
import 'runs/run_trajectory_page.dart';
import 'runs/subagent_page.dart';
import 'runs/subagent_summary.dart';
import 'runs/timeline.dart';
import 'schedules/cadence_picker.dart';
import 'schedules/run_timeline.dart';
import 'schedules/schedule_editor_page.dart';
import 'schedules/schedule_runs_page.dart';
import 'schedules/schedules_page.dart';
import 'settings/account_health_page.dart';
import 'settings/appearance_page.dart';
import 'settings/confirm_typed_sheet.dart';
import 'settings/credentials_page.dart';
import 'settings/data_control_page.dart';
import 'settings/export_picker_sheet.dart';
import 'settings/memory_page.dart';
import 'settings/plan_billing_page.dart';
import 'settings/plan_compare_table.dart';
import 'settings/settings_hub.dart';
import 'settings/settings_search.dart';
import 'settings/storage_breakdown.dart';
import 'settings/storage_page.dart';
import 'settings/usage_charts.dart';
import 'settings/usage_page.dart';
import 'settings_extra/about_page.dart';
import 'settings_extra/agent_presets_page.dart';
import 'settings_extra/memory_files_page.dart';
import 'settings_extra/notifications_page.dart';
import 'settings_extra/legal_page.dart';
import 'settings_extra/permissions_page.dart';
import 'settings_extra/response_wait_page.dart';
import 'settings_extra/shared_memory_page.dart';
import 'share/share_chat_sheet.dart';
import 'share/share_link_card.dart';
import 'share/share_sheet.dart';
import 'sidebar/project_detail_page.dart';
import 'sidebar/project_memory_editor.dart';
import 'sidebar/projects_page.dart';
import 'sidebar/session_actions_sheet.dart';
import 'sidebar/sidebar.dart';
import 'sidebar/sidebar_footer.dart';
import 'states/state_tiles.dart';
import 'states/system_states_page.dart';
import 'studio/branch_picker_sheet.dart';
import 'studio/changes_page.dart';
import 'studio/code_viewer.dart';
import 'studio/commit_sheet.dart';
import 'studio/file_tree.dart';
import 'studio/live_preview_page.dart';
import 'studio/repo_picker_page.dart';
import 'studio/studio_workspace_page.dart';
import 'v2_preview_data.dart';
import 'package:flutter/material.dart';

import 'v2_screen_entry.dart';

/// Page frame for a section component that normally sits inside a screen.
///
/// The gallery preview already supplies a Scaffold and a theme, but section
/// widgets (charts, timelines, filter bars) expect a scrolling body with the
/// screen's spacing, so give them one here.
Widget _componentPage(
  String title,
  String subtitle,
  Widget child, {
  EdgeInsetsGeometry padding = const EdgeInsets.all(OSpace.l),
}) {
  return OScaffold(
    appBar: OAppBar(title: title, subtitle: subtitle, showBack: false),
    body: SingleChildScrollView(padding: padding, child: child),
  );
}

/// Bottom-sheet frame for components that normally arrive through
/// `showOSheet`, so a reviewer can see the sheet at its real max height.
Widget _sheetPage(
  BuildContext context,
  String title,
  String subtitle,
  Widget child,
) {
  final c = OColors.of(context);
  final viewport = MediaQuery.sizeOf(context).height;
  final dialog = MediaQuery.sizeOf(context).width >= OBreakpoints.tablet;
  return OScaffold(
    appBar: OAppBar(title: title, subtitle: subtitle, showBack: false),
    body: ColoredBox(
      color: c.scrim.withValues(alpha: 0.16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // A real sheet is capped at ~90 % of the screen. On a phone the frame
          // keeps a 720 dp floor and lets the page scroll so a short browser
          // window cannot clip the sheet mid-list; a tablet gets a centred
          // dialog that fits the window instead.
          final sheetHeight = dialog
              ? math.min(720.0, constraints.maxHeight - 2 * OSpace.xl)
              : math.max(viewport * 0.92, 720.0);
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Align(
                alignment: dialog ? Alignment.center : Alignment.bottomCenter,
                child: Padding(
                  padding: dialog
                      ? const EdgeInsets.all(OSpace.xl)
                      : EdgeInsets.zero,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    // A bound is required: with loose constraints the sheet's
                    // scrollable body collapses to zero and the rows vanish.
                    child: SizedBox(
                      height: sheetHeight,
                      child: Material(
                        color: c.surface,
                        clipBehavior: Clip.antiAlias,
                        borderRadius: BorderRadius.circular(
                          dialog ? ORadius.xl : 0,
                        ),
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// Web-safe subset of the gallery.
///
/// A handful of screens import `core/state.dart`, which links sqlite3 (FFI) and
/// cannot compile for web. Every other screen is presentational and renders
/// here unchanged, so the browser preview still covers the real UI.
final List<V2ScreenEntry> v2ScreensWeb = <V2ScreenEntry>[
  V2ScreenEntry(
    id: 'splash',
    title: 'Splash',
    group: 'Identity',
    summary: 'Mark, wordmark and startup progress',
    builder: (_) => const SplashPage(
      data: V2SplashData(progress: 0.62, statusLabel: 'Loading your chats'),
    ),
  ),
  V2ScreenEntry(
    id: 'sign_in',
    title: 'Sign in',
    group: 'Identity',
    summary: 'Google and phone sign-in with inline errors',
    builder: (_) => const SignInPage(),
  ),
  V2ScreenEntry(
    id: 'welcome',
    title: 'Welcome',
    group: 'Identity',
    summary: 'First-run introduction with language choice',
    builder: (_) => const OnboardingWelcomePage(),
  ),
  V2ScreenEntry(
    id: 'language_goal',
    title: 'Language & goal',
    group: 'Identity',
    summary: 'Hindi, Hinglish, Punjabi, Tamil plus what to build first',
    builder: (_) => const LanguageGoalPage(),
  ),
  V2ScreenEntry(
    id: 'paywall',
    title: 'Paywall',
    group: 'Identity',
    summary: 'Free, Go, Plus and Pro with monthly/yearly and INR',
    builder: (_) => const PaywallPage(),
  ),
  V2ScreenEntry(
    id: 'phone_auth',
    title: 'Phone sign-in',
    group: 'Identity',
    summary: 'Country code, six-digit SMS code and resend timer',
    isSheet: true,
    builder: (context) => _sheetPage(
      context,
      'Phone sign-in',
      'Country code, six-digit SMS code and resend timer',
      V2PhoneAuthSheet(
        data: previewPhoneAuthData(),
        onCountryChanged: (_) {},
        onPhoneChanged: (_) {},
        onSendCode: (_) {},
        onCodeChanged: (_) {},
        onVerify: (_) {},
        onResend: () {},
        onChangeNumber: () {},
        onClose: () {},
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'chat',
    title: 'Chat (empty)',
    group: 'Chat',
    summary: 'Top bar, model chip, suggestions and composer',
    builder: (_) => const V2ChatPage(data: V2ChatPageData()),
  ),
  V2ScreenEntry(
    id: 'live_chat',
    title: 'Live chat',
    group: 'Chat',
    summary: 'Transcript, thinking, tools, artifacts and stop',
    builder: (_) => V2LiveChatPage(data: previewLiveChatData()),
  ),
  V2ScreenEntry(
    id: 'model_picker',
    title: 'Model picker (Free / Go)',
    group: 'Chat',
    summary: 'Auto only: manual models stay locked and inert',
    isSheet: true,
    builder: (_) => const V2ModelPickerPreview(manualModelsAllowed: false),
  ),
  V2ScreenEntry(
    id: 'model_picker_paid',
    title: 'Model picker (Plus / Pro)',
    group: 'Chat',
    summary: 'Auto plus every manual model, selection fires onSelect',
    isSheet: true,
    builder: (_) => const V2ModelPickerPreview(manualModelsAllowed: true),
  ),
  V2ScreenEntry(
    id: 'chat_auto_vs_manual',
    title: 'Chat: Auto vs manual',
    group: 'Chat',
    summary: 'Type and send: the reply names the model that answered',
    builder: (_) => const V2ChatModelPreview(),
  ),
  V2ScreenEntry(
    id: 'model_chip',
    title: 'Model chip menu',
    group: 'Chat',
    summary: 'Quick model switch from the top bar',
    isSheet: true,
    builder: (_) => V2ModelChipMenu(
      data: const V2ModelChipMenuData(lockedModels: []),
      onSelect: (_) {},
      onManageModels: () {},
      onComparePlans: () {},
    ),
  ),
  V2ScreenEntry(
    id: 'permission_sheet',
    title: 'Permission modes',
    group: 'Chat',
    summary: 'Read-only, General, Full Access and Studio',
    isSheet: true,
    builder: (context) => _sheetPage(
      context,
      'Permission modes',
      'Choose what Ovid may do in this chat',
      V2PermissionSheet(
        data: previewPermissionSheetData(),
        onSelect: (_) {},
        onClose: () {},
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'composer_plus',
    title: 'Composer plus menu',
    group: 'Chat',
    summary: 'Photo, camera, file, Studio folder and connectors',
    isSheet: true,
    builder: (context) => _sheetPage(
      context,
      'Composer plus menu',
      'Photo, camera, file, Studio folder and connectors',
      V2ComposerPlusSheet(
        data: previewComposerPlusData(),
        onPhoto: () {},
        onCamera: () {},
        onFile: () {},
        onStudioFolder: () {},
        onConnectors: () {},
        onOpenStudio: () {},
        onClose: () {},
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'system_states',
    title: 'System states',
    group: 'Chat',
    summary: 'Plan limit, offline, error and empty variants',
    builder: (_) => const V2SystemStatesPage(),
  ),
  V2ScreenEntry(
    id: 'sidebar',
    title: 'Sidebar',
    group: 'Navigation',
    summary: 'Profile, new session, pinned, projects and sessions',
    builder: (_) => const Sidebar(data: V2SidebarData(name: 'Ovid user')),
  ),
  V2ScreenEntry(
    id: 'projects',
    title: 'Projects',
    group: 'Navigation',
    summary: 'Shared projects, storage and member stacks',
    builder: (_) => ProjectsPage(
      data: previewProjectsData(),
      onProjectTap: (_) {},
      onProjectMemory: (_) {},
      onCreateProject: (_) {},
    ),
  ),
  V2ScreenEntry(
    id: 'project_detail',
    title: 'Project detail',
    group: 'Navigation',
    summary: 'Project chats, memory files and storage',
    builder: (_) => ProjectDetailPage(data: previewProjectDetailData()),
  ),
  V2ScreenEntry(
    id: 'project_memory_editor',
    title: 'Project memory editor',
    group: 'Navigation',
    summary: 'Name, Markdown body, size cap and delete',
    isSheet: true,
    builder: (context) => _sheetPage(
      context,
      'Project memory editor',
      'Name, Markdown body, size cap and delete',
      ProjectMemoryEditorSheet(
        data: previewProjectMemoryEditorData(),
        onSave: (_) {},
        onDelete: (_) {},
        onClose: () {},
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'session_actions',
    title: 'Chat actions',
    group: 'Navigation',
    summary: 'Pin, rename, move, share, duplicate, export and delete',
    isSheet: true,
    builder: (_) =>
        const SessionActionsSheet(data: V2SessionActionsData(title: 'Chat')),
  ),
  V2ScreenEntry(
    id: 'repo_picker',
    title: 'Studio repo picker',
    group: 'Work',
    summary: 'GitHub connection, repository and branch choice',
    builder: (_) => V2RepoPickerPage(data: previewRepoPickerData()),
  ),
  V2ScreenEntry(
    id: 'studio_workspace',
    title: 'Studio workspace',
    group: 'Work',
    summary: 'File tree, editor, sync and changes',
    builder: (_) => V2StudioWorkspacePage(
      data: V2StudioWorkspaceData(
        repoName: 'aarav/ovid-app',
        branch: 'feature/hero-revamp',
        filesChanged: 3,
        additions: 48,
        deletions: 10,
        syncCount: 2,
        openFileName: 'auth_service.dart',
        openFilePath: 'lib/core/auth_service.dart',
        fileTree: previewStudioFileNodes(),
        codeLines: previewStudioCodeLines(),
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'branch_picker',
    title: 'Branch picker',
    group: 'Work',
    summary: 'Switch branch or create one',
    isSheet: true,
    builder: (_) =>
        V2BranchPickerSheet(data: previewBranchPickerData(), showHandle: false),
  ),
  V2ScreenEntry(
    id: 'changes',
    title: 'Changes & diff',
    group: 'Work',
    summary: 'Changed files, diff hunks and commit dock',
    builder: (_) => V2ChangesPage(data: previewChangesData()),
  ),
  V2ScreenEntry(
    id: 'code_viewer',
    title: 'Code viewer',
    group: 'Work',
    summary: 'Read-only file and unified diff in the Studio viewer',
    builder: (_) => V2CodeViewerPage(data: previewCodeViewerData()),
  ),
  V2ScreenEntry(
    id: 'commit_sheet',
    title: 'Commit changes',
    group: 'Work',
    summary: 'Message, changed files, sync-first and protected branch',
    isSheet: true,
    builder: (context) => _sheetPage(
      context,
      'Commit changes',
      'Message, changed files, sync-first and protected branch',
      V2CommitSheet(
        data: previewCommitSheetData(),
        onCommit: (_) {},
        onSync: () {},
        onRetry: () {},
        onClose: () {},
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'live_preview',
    title: 'Live preview',
    group: 'Work',
    summary: 'Sandbox preview, expiry and share controls',
    builder: (_) => V2LivePreviewPage(
      data: previewLivePreviewData(),
      onShareLink: () {},
      onOpenInBrowser: () {},
      onStop: () {},
    ),
  ),
  V2ScreenEntry(
    id: 'browser',
    title: 'Browser',
    group: 'Work',
    summary: 'Agent-driven tab, live frames, take control',
    builder: (_) => BrowserPage(data: previewBrowserData()),
  ),
  V2ScreenEntry(
    id: 'take_control',
    title: 'Take control',
    group: 'Work',
    summary: 'Human control, 45 s countdown and keyboard/trackpad',
    isSheet: true,
    builder: (_) => const TakeControlSheet(data: V2TakeControlData()),
  ),
  V2ScreenEntry(
    id: 'connectors',
    title: 'Connectors',
    group: 'Connectors',
    summary: 'Installed apps, plugins and add-ons with categories',
    builder: (_) => const ConnectorsPage(data: V2ConnectorsData()),
  ),
  V2ScreenEntry(
    id: 'connector_detail',
    title: 'Connector detail',
    group: 'Connectors',
    summary: 'Permissions, tools, account and disconnect',
    builder: (_) => ConnectorDetailPage(data: previewConnectorDetailData()),
  ),
  V2ScreenEntry(
    id: 'connector_permissions',
    title: 'Connector permissions',
    group: 'Connectors',
    summary: 'Read, write and admin grants with the tools they unlock',
    builder: (_) =>
        ConnectorPermissionsPage(data: previewConnectorPermissionsData()),
  ),
  V2ScreenEntry(
    id: 'add_connector',
    title: 'Add connector',
    group: 'Connectors',
    summary: 'Searchable catalog, plan limit and safe install',
    builder: (_) => const AddConnectorPage(data: V2AddConnectorData()),
  ),
  V2ScreenEntry(
    id: 'artifacts',
    title: 'Artifacts',
    group: 'Library',
    summary: 'Lifetime library with search, filters and sizes',
    builder: (_) => const ArtifactsPage(data: V2ArtifactsData()),
  ),
  V2ScreenEntry(
    id: 'artifact_detail',
    title: 'Artifact detail',
    group: 'Library',
    summary: 'Preview, metadata, share, delete',
    builder: (_) => ArtifactDetailPage(data: previewArtifactDetailData()),
  ),
  V2ScreenEntry(
    id: 'schedules',
    title: 'Schedules',
    group: 'Schedules',
    summary: 'Scheduled prompts, cadence, runs and source chat',
    builder: (_) => SchedulesPage(data: previewSchedulesData()),
  ),
  V2ScreenEntry(
    id: 'schedule_editor',
    title: 'Schedule editor',
    group: 'Schedules',
    summary: 'Prompt, cadence, timezone and notifications',
    builder: (_) => const ScheduleEditorPage(data: V2ScheduleEditorData()),
  ),
  V2ScreenEntry(
    id: 'schedule_runs',
    title: 'Schedule runs',
    group: 'Schedules',
    summary: 'Run history, failures, retry and artifacts',
    builder: (_) => ScheduleRunsPage(data: previewScheduleRunsData()),
  ),
  V2ScreenEntry(
    id: 'share_chat',
    title: 'Share chat',
    group: 'Sharing',
    summary: 'Collab or read-only with a fork note',
    isSheet: true,
    builder: (_) => ShareChatSheet(data: previewShareChatData()),
  ),
  V2ScreenEntry(
    id: 'share_sheet',
    title: 'Share sheet',
    group: 'Sharing',
    summary: 'Read-only link, visibility and share targets',
    isSheet: true,
    builder: (_) => ShareSheet(data: previewShareSheetData()),
  ),
  V2ScreenEntry(
    id: 'collab_live',
    title: 'Collaboration live',
    group: 'Sharing',
    summary: 'Up to 50 members, one sender and a turn queue',
    builder: (_) => CollabLivePage(data: previewCollabLiveData()),
  ),
  V2ScreenEntry(
    id: 'collab_members',
    title: 'Collaboration members',
    group: 'Sharing',
    summary: 'Roles, capacity and creator-paid storage',
    builder: (_) => CollabMembersPage(data: previewCollabMembersData()),
  ),
  V2ScreenEntry(
    id: 'trajectory',
    title: 'Run trajectory',
    group: 'Runs',
    summary: 'Subagent launches, steps and token spend',
    builder: (_) => RunTrajectoryPage(data: previewRunTrajectoryData()),
  ),
  V2ScreenEntry(
    id: 'subagent',
    title: 'Subagent',
    group: 'Runs',
    summary: 'Progress, files, log and the 300-token summary',
    builder: (_) => SubagentPage(data: previewSubagentData()),
  ),
  V2ScreenEntry(
    id: 'settings',
    title: 'Settings hub',
    group: 'Settings',
    summary: 'Account, chat, models, data control and advanced',
    builder: (_) => SettingsHubPage(data: previewSettingsHubData()),
  ),
  V2ScreenEntry(
    id: 'settings_search',
    title: 'Settings search',
    group: 'Settings',
    summary: 'Search every settings section and row',
    builder: (_) => SettingsSearchPage(data: previewSettingsSearchData()),
  ),
  V2ScreenEntry(
    id: 'plan_billing',
    title: 'Plan & billing',
    group: 'Settings',
    summary: 'Free/Go/Plus/Pro limits, currency, history',
    builder: (_) => PlanBillingPage(data: previewPlanBillingData()),
  ),
  V2ScreenEntry(
    id: 'usage',
    title: 'Usage',
    group: 'Settings',
    summary: 'Daily and monthly allowance, models and storage',
    builder: (_) => UsagePage(data: previewUsageData()),
  ),
  V2ScreenEntry(
    id: 'memory',
    title: 'Memory',
    group: 'Settings',
    summary: 'Master switch, shared memory and scopes',
    builder: (_) => MemoryPage(data: previewMemoryData()),
  ),
  V2ScreenEntry(
    id: 'shared_memory',
    title: 'Shared memory',
    group: 'Settings',
    summary: 'What leaves this chat, who sees it and how to forget',
    builder: (_) => SharedMemoryPage(data: previewSharedMemoryData()),
  ),
  V2ScreenEntry(
    id: 'data_control',
    title: 'Data control',
    group: 'Settings',
    summary: 'Export, import, local data and danger zone',
    builder: (_) => DataControlPage(data: previewDataControlData()),
  ),
  V2ScreenEntry(
    id: 'export_picker',
    title: 'Export picker',
    group: 'Settings',
    summary: 'Pick chats, see sizes and stay under the archive limit',
    isSheet: true,
    builder: (context) => _sheetPage(
      context,
      'Export picker',
      'Pick chats, see sizes and stay under the archive limit',
      ExportPickerSheet(
        data: previewExportPickerData(),
        onToggleSession: (_, _) {},
        onSelectAll: (_) {},
        onExport: () {},
        onRetry: () {},
        onClose: () {},
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'confirm_typed',
    title: 'Confirm by typing',
    group: 'Settings',
    summary: 'Delete account with a typed email and a 24 h grace note',
    isSheet: true,
    builder: (context) => _sheetPage(
      context,
      'Confirm by typing',
      'Delete account with a typed email and a 24 h grace note',
      V2ConfirmTypedSheet(
        data: previewConfirmTypedData(),
        onConfirm: () {},
        onCancel: () {},
        onManageSubscription: () {},
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'storage',
    title: 'Storage',
    group: 'Settings',
    summary: 'Plan quota, breakdown and clean-up',
    builder: (_) => StoragePage(data: previewStorageData()),
  ),
  V2ScreenEntry(
    id: 'appearance',
    title: 'Personalization',
    group: 'Settings',
    summary: 'Theme, memory, reasoning and text size',
    builder: (_) => AppearancePage(data: previewAppearanceData()),
  ),
  V2ScreenEntry(
    id: 'app_lock',
    title: 'App lock',
    group: 'Settings',
    summary: 'PIN, change PIN and the lock-after idle choice',
    builder: (_) => const AppLockSettingsPage(),
  ),
  V2ScreenEntry(
    id: 'credentials',
    title: 'Credentials',
    group: 'Settings',
    summary: 'Sign-in providers, GitHub and browser logins',
    builder: (_) => CredentialsPage(data: previewCredentialsData()),
  ),
  V2ScreenEntry(
    id: 'account_health',
    title: 'Account health',
    group: 'Settings',
    summary: 'Plan, usage, storage and deletion state',
    builder: (_) => AccountHealthPage(data: previewAccountHealthPageData()),
  ),
  V2ScreenEntry(
    id: 'about',
    title: 'About',
    group: 'Settings',
    summary: 'Version and the three legal documents',
    builder: (_) => AboutPage(data: previewAboutData()),
  ),
  V2ScreenEntry(
    id: 'legal',
    title: 'Legal document',
    group: 'Settings',
    summary: 'Privacy policy, terms and licences with sections',
    builder: (_) => LegalPage(data: previewLegalData()),
  ),
  V2ScreenEntry(
    id: 'notifications',
    title: 'Notifications',
    group: 'Settings',
    summary: 'Master switch, channels, quiet hours and sound',
    builder: (_) => NotificationsPage(data: previewNotificationsData()),
  ),
  V2ScreenEntry(
    id: 'presets',
    title: 'Agent presets',
    group: 'Settings',
    summary: 'Standard, Minimal, Studio, Code, Plan and custom',
    builder: (_) => AgentPresetsPage(data: previewPresetsData()),
  ),
  V2ScreenEntry(
    id: 'response_wait',
    title: 'Response wait limit',
    group: 'Settings',
    summary: 'How long Ovid waits before asking',
    builder: (_) => ResponseWaitPage(data: previewResponseWaitData()),
  ),
  V2ScreenEntry(
    id: 'permissions',
    title: 'Permissions',
    group: 'Settings',
    summary: 'Microphone and notifications, with the OS state',
    builder: (_) => PermissionsPage(data: previewPermissionsData()),
  ),
  V2ScreenEntry(
    id: 'memory_files',
    title: 'Memory files',
    group: 'Settings',
    summary: 'Global, project and session files, editable',
    builder: (_) => MemoryFilesPage(data: previewMemoryFilesData()),
  ),

  // ── Component previews ──────────────────────────────────────────────────
  // Sections and sheets that normally live inside a screen. They are mounted
  // on the gallery's own frame so their content, not their empty state, is
  // what a reviewer sees.
  V2ScreenEntry(
    id: 'step_progress',
    title: 'Onboarding step progress',
    group: 'Identity',
    summary: 'STEP 2 OF 3 with one filled bar per step',
    builder: (_) => _componentPage(
      'Onboarding step progress',
      'Step indicator and trailing label',
      OCard(child: OnboardingStepProgress(data: previewOnboardingStepData())),
    ),
  ),
  V2ScreenEntry(
    id: 'purchase_banner',
    title: 'Purchase banner',
    group: 'Identity',
    summary: 'Test store, pending, failed and restored billing states',
    builder: (_) => _componentPage(
      'Purchase banner',
      'Failed purchase with retry and manage subscription',
      V2PurchaseBanner(
        data: previewPurchaseBannerData(),
        onRetry: () {},
        onManageSubscription: () {},
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'model_chip_component',
    title: 'Model chip',
    group: 'Chat',
    summary: 'Current model, Auto-only lock and subagent count',
    builder: (_) => _componentPage(
      'Model chip',
      'Compact model selector for the chat app bar',
      Wrap(
        spacing: OSpace.m,
        runSpacing: OSpace.m,
        children: <Widget>[
          V2ModelChip(label: 'Auto', onTap: () {}, subagentCount: 3),
          V2ModelChip(
            label: 'Ovid Pro 1.5',
            icon: Icons.bolt_rounded,
            onTap: () {},
          ),
          V2ModelChip(label: 'Auto', autoOnly: true, onTap: () {}),
          const V2ModelChip(label: 'Auto'),
        ],
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'queue_dock',
    title: 'Queue dock',
    group: 'Chat',
    summary: 'Messages waiting behind the active run with Send now',
    builder: (context) {
      final c = OColors.of(context);
      final messages = previewQueuedMessages();
      return OScaffold(
        appBar: const OAppBar(
          title: 'Queue dock',
          subtitle: 'Messages above the composer',
          showBack: false,
        ),
        body: Column(
          children: <Widget>[
            const Spacer(),
            V2QueueDock(
              count: messages.length,
              preview: messages.first,
              onSendNow: () {},
              onDismiss: () {},
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.l,
                vertical: OSpace.m,
              ),
              decoration: BoxDecoration(
                color: c.surface,
                border: Border(top: BorderSide(color: c.hairline)),
              ),
              child: Text(
                'Message Ovid…',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: c.textMuted),
              ),
            ),
          ],
        ),
      );
    },
  ),
  V2ScreenEntry(
    id: 'state_tiles',
    title: 'State tiles',
    group: 'Chat',
    summary: 'Offline, plan limit, storage, suspension, deletion and error',
    builder: (_) => _componentPage(
      'State tiles',
      'Recoverable states with a next action',
      Column(
        children: <Widget>[
          for (final kind in previewStateTileKinds()) ...<Widget>[
            V2StateTile(kind: kind, onAction: () {}),
            const SizedBox(height: OSpace.m),
          ],
        ],
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'sidebar_footer',
    title: 'Sidebar footer',
    group: 'Navigation',
    summary: 'Schedule next run, artifacts and settings destinations',
    builder: (_) => OScaffold(
      appBar: const OAppBar(
        title: 'Sidebar footer',
        subtitle: 'Destinations at the bottom',
        showBack: false,
      ),
      body: Column(
        children: <Widget>[
          const Spacer(),
          SidebarFooter(
            scheduleNextRun: 'Next run 9:00 AM',
            onSchedule: () {},
            onArtifacts: () {},
            onSettings: () {},
          ),
        ],
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'tab_strip',
    title: 'Browser tab strip',
    group: 'Work',
    summary: 'Agent-owned tabs, active tab, headless badge and no plus',
    builder: (_) => _componentPage(
      'Browser tab strip',
      'Ovid opens every tab',
      BrowserTabStrip(
        tabs: previewBrowserTabs(),
        activeTabId: 'github',
        onSelectTab: (_) {},
        onCloseTab: (_) {},
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'viewport',
    title: 'Browser viewport',
    group: 'Work',
    summary: 'Live frame, agent cursor, fps hint and take control',
    builder: (_) => _componentPage(
      'Browser viewport',
      'The page Ovid is driving',
      SizedBox(
        height: 420,
        child: BrowserViewport(
          status: V2ViewportStatus.live,
          cursor: previewViewportCursor(),
          onRetry: () {},
        ),
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'browser_chrome',
    title: 'Browser chrome',
    group: 'Work',
    summary: 'Tab strip, live viewport and the control bar together',
    builder: (_) => _componentPage(
      'Browser chrome',
      'Tabs, live picture and the take-control bar',
      Column(
        children: <Widget>[
          BrowserTabStrip(
            tabs: previewBrowserTabs(),
            activeTabId: 'docs',
            onSelectTab: (_) {},
            onCloseTab: (_) {},
          ),
          const SizedBox(height: OSpace.m),
          SizedBox(
            height: 360,
            child: BrowserViewport(
              status: V2ViewportStatus.live,
              cursor: previewViewportCursor(),
              onRetry: () {},
            ),
          ),
        ],
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'file_tree',
    title: 'File tree',
    group: 'Work',
    summary: 'Searchable workspace tree with change badges',
    builder: (_) => _componentPage(
      'File tree',
      'Folders, files and working-tree changes',
      V2FileTree(data: previewFileTreeData(), onSelectFile: (_) {}),
    ),
  ),
  V2ScreenEntry(
    id: 'artifact_filters',
    title: 'Artifact filters',
    group: 'Library',
    summary: 'Type, source, session, sort and size summary',
    builder: (_) => _componentPage(
      'Artifact filters',
      'Controlled filter bar for the artifact library',
      ArtifactFilterBar(
        filters: previewArtifactFilters(),
        summary: previewArtifactSizeSummary(),
        sessions: previewArtifactSessions(),
        onChanged: (_) {},
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'artifact_preview_code',
    title: 'Artifact preview · code',
    group: 'Library',
    summary: 'Capped code snippet with metadata and an external open',
    builder: (_) => _componentPage(
      'Artifact preview · code',
      'Code artifacts stay cheap and capped',
      V2ArtifactPreview(
        data: previewArtifactCodePreviewData(),
        onOpenExternally: () {},
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'artifact_preview_document',
    title: 'Artifact preview · document',
    group: 'Library',
    summary: 'Metadata-only document preview, never an embedded renderer',
    builder: (_) => _componentPage(
      'Artifact preview · document',
      'Documents show facts, not a live document',
      V2ArtifactPreview(
        data: previewArtifactDocumentPreviewData(),
        onOpenExternally: () {},
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'cadence_picker',
    title: 'Cadence picker',
    group: 'Schedules',
    summary: 'Daily, weekly or custom with weekday chips and next run',
    builder: (_) => _componentPage(
      'Cadence picker',
      'When a scheduled prompt runs',
      CadencePicker(
        draft: previewCadenceDraft(),
        now: DateTime(2026, 10, 21, 8, 30),
        onChanged: (_) {},
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'run_timeline',
    title: 'Run timeline',
    group: 'Schedules',
    summary: 'Day groups, outcomes, artifacts and retry on failure',
    builder: (_) => _componentPage(
      'Run timeline',
      'Run history for one schedule',
      RunTimeline(
        data: previewRunTimelineData(),
        onOpenArtifact: (_) {},
        onRetryRun: (_) {},
        onRetry: () {},
        onBackToSchedule: () {},
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'share_link_card',
    title: 'Share link card',
    group: 'Sharing',
    summary: 'URL, Collab capacity, dates, copy and revoke',
    builder: (_) => _componentPage(
      'Share link card',
      'A readable link with one copy target',
      V2ShareLinkCard(
        data: previewShareLinkCardData(),
        onCopy: () {},
        onRevoke: () {},
        now: DateTime(2026, 10, 21),
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'turn_banner',
    title: 'Collab turn banner',
    group: 'Sharing',
    summary: 'Whose turn, time left, the queue and request-turn',
    builder: (_) => _componentPage(
      'Collab turn banner',
      'One sender at a time',
      CollabTurnBanner(
        data: previewTurnBannerData(),
        onRequestTurn: () {},
        onViewQueue: () {},
        onRetry: () {},
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'trajectory_timeline',
    title: 'Trajectory timeline',
    group: 'Runs',
    summary: 'Plan, search, subagent, approval and test steps',
    builder: (_) => _componentPage(
      'Trajectory timeline',
      'Reusable vertical timeline for a run',
      V2Timeline(
        items: previewTrajectoryTimelineItems(),
        semanticLabel: 'Execution trajectory',
        onItemTap: (_) {},
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'subagent_summary',
    title: 'Subagent summary',
    group: 'Runs',
    summary: 'The strict five-key JSON, files, artifacts and findings',
    builder: (_) => _componentPage(
      'Subagent summary',
      'What the main agent receives from a subagent',
      SubagentSummaryCard(
        summary: previewSubagentSummaryData(),
        onFileTap: (_) {},
        onArtifactTap: (_) {},
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'storage_breakdown',
    title: 'Storage breakdown',
    group: 'Settings',
    summary: 'Donut, legend and the selected category share',
    builder: (_) => _componentPage(
      'Storage breakdown',
      'Where the account storage went',
      StorageBreakdown(data: previewStorageBreakdownData()),
    ),
  ),
  V2ScreenEntry(
    id: 'usage_charts',
    title: 'Usage charts',
    group: 'Settings',
    summary: 'Daily tokens, model share and image generations',
    builder: (_) => _componentPage(
      'Usage charts',
      'Three charts with 7/30 day range',
      Column(
        children: <Widget>[
          V2DailyTokensChart(
            points: previewTokenChartPoints(),
            onRangeChanged: (_) {},
          ),
          const SizedBox(height: OSpace.l),
          V2ModelShareChart(slices: previewModelShareSlices()),
          const SizedBox(height: OSpace.l),
          V2ImageUsageChart(points: previewImageUsagePoints()),
        ],
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'plan_compare',
    title: 'Plan comparison',
    group: 'Settings',
    summary: 'Pinned limits column with Free, Go, Plus and Pro',
    builder: (_) => _componentPage(
      'Plan comparison',
      'Every plan limit side by side',
      PlanCompareTable(data: previewPlanCompareData()),
    ),
  ),
];
