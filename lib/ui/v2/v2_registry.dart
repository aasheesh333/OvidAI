import 'package:flutter/material.dart';

import 'browser/browser_page.dart';
import 'browser/take_control_sheet.dart';
import 'chat/chat_page.dart';
import 'chat/live_chat_page.dart';
import 'chat/model_chip_menu.dart';
import 'chat/model_picker_sheet.dart';
import 'collab/collab_live_page.dart';
import 'collab/collab_members_page.dart';
import 'connectors/add_connector_page.dart';
import 'connectors/connector_detail_page.dart';
import 'connectors/connectors_page.dart';
import 'library/artifact_detail_page.dart';
import 'library/artifacts_page.dart';
import 'onboarding/language_goal_page.dart';
import 'onboarding/onboarding_welcome.dart';
import 'onboarding/paywall_page.dart';
import 'onboarding/sign_in_page.dart';
import 'onboarding/splash_page.dart';
import 'runs/run_trajectory_page.dart';
import 'runs/subagent_page.dart';
import 'schedules/schedule_editor_page.dart';
import 'schedules/schedule_runs_page.dart';
import 'schedules/schedules_page.dart';
import 'settings/account_health_page.dart';
import 'settings/account_page.dart';
import 'settings/appearance_page.dart';
import 'settings/credentials_page.dart';
import 'settings/data_control_page.dart';
import 'settings/memory_page.dart';
import 'settings/plan_billing_page.dart';
import 'settings/settings_hub.dart';
import 'settings/storage_page.dart';
import 'settings/usage_page.dart';
import 'settings_extra/about_page.dart';
import 'settings_extra/agent_presets_page.dart';
import 'settings_extra/memory_files_page.dart';
import 'settings_extra/notifications_page.dart';
import 'settings_extra/permissions_page.dart';
import 'settings_extra/response_wait_page.dart';
import 'share/share_chat_sheet.dart';
import 'share/share_sheet.dart';
import 'sidebar/projects_page.dart';
import 'sidebar/search_page.dart';
import 'sidebar/session_actions_sheet.dart';
import 'sidebar/sidebar.dart';
import 'states/system_states_page.dart';
import 'studio/branch_picker_sheet.dart';
import 'studio/changes_page.dart';
import 'studio/live_preview_page.dart';
import 'studio/repo_picker_page.dart';
import 'studio/studio_workspace_page.dart';
/// One entry in the UI v2 gallery. The builder returns a complete screen
/// (including its own `OScaffold`); the gallery only supplies the frame.
class V2ScreenEntry {
  const V2ScreenEntry({
    required this.id,
    required this.title,
    required this.group,
    required this.summary,
    required this.builder,
    this.isSheet = false,
  });

  final String id;
  final String title;
  final String group;
  final String summary;
  final WidgetBuilder builder;

  /// Sheet bodies need a Material host when shown outside `showOSheet`.
  final bool isSheet;
}

/// Every UI v2 screen, in the order a reviewer should walk them. The builders
/// use neutral/default data: screens show their real empty or disabled state,
/// never sample content. Production never imports this file.
List<V2ScreenEntry> v2Screens = <V2ScreenEntry>[
  // ── Identity ────────────────────────────────────────────────────────────
  V2ScreenEntry(
    id: 'splash',
    title: 'Splash',
    group: 'Identity',
    summary: 'Mark, tagline, startup progress and a retry path',
    builder: (_) => const SplashPage(),
  ),
  V2ScreenEntry(
    id: 'sign_in',
    title: 'Sign in',
    group: 'Identity',
    summary: 'Email, password, Google, Apple and inline errors',
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

  // ── Chat ────────────────────────────────────────────────────────────────
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
    builder: (_) => const V2LiveChatPage(data: V2LiveChatData()),
  ),
  V2ScreenEntry(
    id: 'model_picker',
    isSheet: true,
    title: 'Model picker',
    group: 'Chat',
    summary: 'Auto recommendation, search and locked paid models',
    builder: (_) => V2ModelPickerSheet(
      data: const V2ModelPickerData(models: []),
      onSelect: (_) {},
      onManageModels: () {},
    ),
  ),
  V2ScreenEntry(
    id: 'model_chip',
    isSheet: true,
    title: 'Model chip menu',
    group: 'Chat',
    summary: 'Quick model switch from the top bar',
    builder: (_) => V2ModelChipMenu(
      data: const V2ModelChipMenuData(lockedModels: []),
      onSelect: (_) {},
      onManageModels: () {},
      onComparePlans: () {},
    ),
  ),
  V2ScreenEntry(
    id: 'system_states',
    title: 'System states',
    group: 'Chat',
    summary: 'Plan limit, offline, error and empty variants',
    builder: (_) => const V2SystemStatesPage(),
  ),

  // ── Navigation ──────────────────────────────────────────────────────────
  V2ScreenEntry(
    id: 'sidebar',
    title: 'Sidebar',
    group: 'Navigation',
    summary: 'Profile, new chat, pinned, projects and sessions',
    builder: (_) => const Sidebar(data: V2SidebarData(name: 'Ovid user')),
  ),
  V2ScreenEntry(
    id: 'projects',
    title: 'Projects',
    group: 'Navigation',
    summary: 'Shared projects, storage and member stacks',
    builder: (_) => const ProjectsPage(data: V2ProjectsData()),
  ),
  V2ScreenEntry(
    id: 'search',
    title: 'Search',
    group: 'Navigation',
    summary: 'Chats, projects and artifacts with recent searches',
    builder: (_) => const SearchPage(data: V2SearchData()),
  ),
  V2ScreenEntry(
    id: 'session_actions',
    isSheet: true,
    title: 'Chat actions',
    group: 'Navigation',
    summary: 'Pin, rename, move, share, duplicate, export and delete',
    builder: (_) => const SessionActionsSheet(
      data: V2SessionActionsData(title: 'Chat'),
    ),
  ),

  // ── Work surfaces ───────────────────────────────────────────────────────
  V2ScreenEntry(
    id: 'repo_picker',
    title: 'Studio repo picker',
    group: 'Work',
    summary: 'GitHub connection and repository choice',
    builder: (_) => const V2RepoPickerPage(data: V2RepoPickerData()),
  ),
  V2ScreenEntry(
    id: 'studio_workspace',
    title: 'Studio workspace',
    group: 'Work',
    summary: 'File tree, editor, sync and changes',
    builder: (_) => const V2StudioWorkspacePage(
      data: V2StudioWorkspaceData(repoName: 'owner/repo', branch: 'main'),
    ),
  ),
  V2ScreenEntry(
    id: 'branch_picker',
    isSheet: true,
    title: 'Branch picker',
    group: 'Work',
    summary: 'Switch or create a branch with a stash note',
    builder: (_) => const V2BranchPickerSheet(
      data: V2BranchPickerData(),
      showHandle: false,
    ),
  ),
  V2ScreenEntry(
    id: 'changes',
    title: 'Changes & diff',
    group: 'Work',
    summary: 'Changed files, diff hunks and commit dock',
    builder: (_) => const V2ChangesPage(data: V2ChangesData()),
  ),
  V2ScreenEntry(
    id: 'live_preview',
    title: 'Live preview',
    group: 'Work',
    summary: 'Sandbox preview, expiry and share controls',
    builder: (_) => const V2LivePreviewPage(data: V2LivePreviewData()),
  ),
  V2ScreenEntry(
    id: 'browser',
    title: 'Browser',
    group: 'Work',
    summary: 'Agent-driven tab, live frames, take control',
    builder: (_) => const BrowserPage(data: V2BrowserData()),
  ),
  V2ScreenEntry(
    id: 'take_control',
    isSheet: true,
    title: 'Take control',
    group: 'Work',
    summary: 'Human control, 45 s countdown and keyboard/trackpad',
    builder: (_) => const TakeControlSheet(data: V2TakeControlData()),
  ),

  // ── Connectors ──────────────────────────────────────────────────────────
  V2ScreenEntry(
    id: 'connectors',
    title: 'Connectors',
    group: 'Connectors',
    summary: 'Installed and available apps with categories',
    builder: (_) => const ConnectorsPage(data: V2ConnectorsData()),
  ),
  V2ScreenEntry(
    id: 'connector_detail',
    title: 'Connector detail',
    group: 'Connectors',
    summary: 'Permissions, account, usage and disconnect',
    builder: (_) => const ConnectorDetailPage(
      data: V2ConnectorDetailData(
        id: 'github',
        name: 'GitHub',
        description: 'Repositories, issues and pull requests.',
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'add_connector',
    title: 'Add connector',
    group: 'Connectors',
    summary: 'Searchable catalog, plan limit and auth',
    builder: (_) => const AddConnectorPage(data: V2AddConnectorData()),
  ),

  // ── Library ─────────────────────────────────────────────────────────────
  V2ScreenEntry(
    id: 'artifacts',
    title: 'Artifacts',
    group: 'Library',
    summary: 'Images, pages, files and code with filters',
    builder: (_) => const ArtifactsPage(data: V2ArtifactsData()),
  ),
  V2ScreenEntry(
    id: 'artifact_detail',
    title: 'Artifact detail',
    group: 'Library',
    summary: 'Preview, metadata, versions and actions',
    builder: (_) => const ArtifactDetailPage(data: V2ArtifactDetailData()),
  ),

  // ── Schedules ───────────────────────────────────────────────────────────
  V2ScreenEntry(
    id: 'schedules',
    title: 'Schedules',
    group: 'Schedules',
    summary: 'Scheduled prompts, cadence and next run',
    builder: (_) => const SchedulesPage(data: V2SchedulesData()),
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
    builder: (_) => const ScheduleRunsPage(data: V2ScheduleRunsData()),
  ),

  // ── Sharing ─────────────────────────────────────────────────────────────
  V2ScreenEntry(
    id: 'share_sheet',
    isSheet: true,
    title: 'Share sheet',
    group: 'Sharing',
    summary: 'Read-only link, visibility and share targets',
    builder: (_) => const ShareSheet(
      data: V2ShareSheetData(link: '', creatorName: ''),
    ),
  ),
  V2ScreenEntry(
    id: 'share_chat',
    isSheet: true,
    title: 'Share chat',
    group: 'Sharing',
    summary: 'Chat-specific share with fork note',
    builder: (_) => const ShareChatSheet(
      data: V2ShareChatSheetData(link: ''),
    ),
  ),
  V2ScreenEntry(
    id: 'collab_live',
    title: 'Collaboration live',
    group: 'Sharing',
    summary: 'Up to 50 members, one sender and a turn queue',
    builder: (_) => const CollabLivePage(
      data: V2CollabLivePageData(
        totalMembers: 1,
        turnHolderName: '',
        turnTimeLeftLabel: '',
        creatorPaysStorage: true,
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'collab_members',
    title: 'Collaboration members',
    group: 'Sharing',
    summary: 'Roles, capacity and creator-paid storage',
    builder: (_) => const CollabMembersPage(
      data: V2CollabMembersPageData(memberCount: 1, capacity: 50),
    ),
  ),

  // ── Runs ────────────────────────────────────────────────────────────────
  V2ScreenEntry(
    id: 'trajectory',
    title: 'Run trajectory',
    group: 'Runs',
    summary: 'Steps, tools, sources and token usage',
    builder: (_) => const RunTrajectoryPage(
      data: V2RunTrajectoryPageData(
        title: 'Run',
        runLabel: '',
        prompt: '',
        model: 'Auto',
        tokensLabel: '',
        durationLabel: '',
      ),
    ),
  ),
  V2ScreenEntry(
    id: 'subagent',
    title: 'Subagent',
    group: 'Runs',
    summary: 'Progress, files and the full log',
    builder: (_) => const SubagentPage(
      data: V2SubagentPageData(
        name: 'Subagent',
        instanceLabel: '',
        stepLabel: '',
        paceLabel: '',
        goal: '',
        startedLabel: '',
        elapsedLabel: '',
        timeLimitLabel: '8 h',
        remainingLabel: '',
        totalLogLines: 0,
      ),
    ),
  ),

  // ── Settings ────────────────────────────────────────────────────────────
  V2ScreenEntry(
    id: 'settings',
    title: 'Settings hub',
    group: 'Settings',
    summary: 'Account, chat, models, data control and advanced',
    builder: (_) => const SettingsHubPage(data: V2SettingsHubData()),
  ),
  V2ScreenEntry(
    id: 'account',
    title: 'Account',
    group: 'Settings',
    summary: 'Profile, email, sign-in methods and deletion',
    builder: (_) => const AccountPage(data: V2AccountData()),
  ),
  V2ScreenEntry(
    id: 'plan_billing',
    title: 'Plan & billing',
    group: 'Settings',
    summary: 'Free/Go/Plus/Pro, currency, history and restore',
    builder: (_) => const PlanBillingPage(data: V2PlanBillingData()),
  ),
  V2ScreenEntry(
    id: 'usage',
    title: 'Usage',
    group: 'Settings',
    summary: 'Daily and monthly allowance, models and storage',
    builder: (_) => const UsagePage(data: V2UsageData()),
  ),
  V2ScreenEntry(
    id: 'memory',
    title: 'Memory',
    group: 'Settings',
    summary: 'Master switch, shared memory and scopes',
    builder: (_) => const MemoryPage(data: V2MemoryPageData()),
  ),
  V2ScreenEntry(
    id: 'data_control',
    title: 'Data control',
    group: 'Settings',
    summary: 'Export, import, permissions and danger zone',
    builder: (_) => const DataControlPage(data: V2DataControlPageData()),
  ),
  V2ScreenEntry(
    id: 'storage',
    title: 'Storage',
    group: 'Settings',
    summary: 'Plan quota, breakdown and clean-up',
    builder: (_) => const StoragePage(data: V2StoragePageData()),
  ),
  V2ScreenEntry(
    id: 'appearance',
    title: 'Appearance',
    group: 'Settings',
    summary: 'System/Light/Dark, text size and motion',
    builder: (_) => const AppearancePage(data: V2AppearancePageData()),
  ),
  V2ScreenEntry(
    id: 'credentials',
    title: 'Credentials',
    group: 'Settings',
    summary: 'Sign-in providers, GitHub and the cloud key',
    builder: (_) => const CredentialsPage(data: V2CredentialsPageData()),
  ),
  V2ScreenEntry(
    id: 'account_health',
    title: 'Account health',
    group: 'Settings',
    summary: 'Security score, devices, sign-ins and services',
    builder: (_) => const AccountHealthPage(data: V2AccountHealthPageData()),
  ),

  // ── Settings extras ─────────────────────────────────────────────────────
  V2ScreenEntry(
    id: 'about',
    title: 'About',
    group: 'Settings',
    summary: 'Version, legal, support and system status',
    builder: (_) => const AboutPage(data: V2AboutPageData()),
  ),
  V2ScreenEntry(
    id: 'notifications',
    title: 'Notifications',
    group: 'Settings',
    summary: 'Runs, schedules, security and delivery',
    builder: (_) => const NotificationsPage(data: V2NotificationsPageData()),
  ),
  V2ScreenEntry(
    id: 'presets',
    title: 'Agent presets',
    group: 'Settings',
    summary: 'General, Coder, Researcher, Writer and custom',
    builder: (_) => const AgentPresetsPage(data: V2AgentPresetsPageData()),
  ),
  V2ScreenEntry(
    id: 'response_wait',
    title: 'Response wait limit',
    group: 'Settings',
    summary: 'How long Ovid waits before asking',
    builder: (_) => const ResponseWaitPage(data: V2ResponseWaitPageData()),
  ),
  V2ScreenEntry(
    id: 'permissions',
    title: 'Permissions',
    group: 'Settings',
    summary: 'Camera, microphone, photos, notifications, files',
    builder: (_) => const PermissionsPage(data: V2PermissionsPageData()),
  ),
  V2ScreenEntry(
    id: 'memory_files',
    title: 'Memory files',
    group: 'Settings',
    summary: 'Global, project and session files',
    builder: (_) => const MemoryFilesPage(data: V2MemoryFilesPageData()),
  ),
];
