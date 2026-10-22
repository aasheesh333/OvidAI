import 'package:flutter/material.dart';

import 'browser/browser_page.dart';
import 'browser/tab_strip.dart';
import 'browser/viewport.dart';
import 'chat/composer_plus_sheet.dart';
import 'chat/live_chat_page.dart';
import 'chat/permission_sheet.dart';
import 'collab/collab_live_page.dart';
import 'collab/collab_members_page.dart';
import 'collab/turn_banner.dart';
// Prefixed: the detail page declares its own permission enums, and importing
// them unqualified would collide with connector_permissions.dart below.
import 'connectors/connector_detail_page.dart' as connector_detail;
import 'connectors/connector_permissions.dart';
import 'library/artifact_detail_page.dart';
import 'library/artifact_filters.dart';
import 'library/artifact_preview.dart';
import 'onboarding/phone_auth_sheet.dart';
import 'onboarding/purchase_banner.dart';
import 'onboarding/step_progress.dart';
import 'runs/run_trajectory_page.dart';
import 'runs/subagent_page.dart';
import 'runs/subagent_summary.dart';
import 'runs/timeline.dart';
import 'schedules/cadence_picker.dart';
import 'schedules/run_timeline.dart';
import 'schedules/schedules_page.dart';
import 'schedules/schedule_runs_page.dart';
import 'settings/account_health_page.dart';
import 'settings/account_page.dart' hide V2AccountStatus;
import 'settings/appearance_page.dart';
import 'settings/confirm_typed_sheet.dart';
import 'settings/credentials_page.dart';
import 'settings/data_control_page.dart';
import 'settings/export_picker_sheet.dart';
import 'settings/memory_page.dart';
import 'settings/plan_billing_page.dart';
import 'settings/plan_compare_table.dart';
import 'chat/model_picker_sheet.dart';
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
import 'settings_extra/permissions_page.dart';
import 'settings_extra/response_wait_page.dart';
import 'settings_extra/shared_memory_page.dart';
import 'settings_extra/legal_page.dart';
import 'share/share_chat_sheet.dart';
import 'share/share_link_card.dart';
import 'share/share_sheet.dart';
import 'sidebar/project_detail_page.dart';
import 'sidebar/project_memory_editor.dart';
import 'sidebar/projects_page.dart';
import 'states/state_tiles.dart';
import 'studio/branch_picker_sheet.dart';
import 'studio/changes_page.dart';
import 'studio/code_viewer.dart';
import 'studio/commit_sheet.dart';
import 'studio/file_tree.dart';
import 'studio/live_preview_page.dart';
import 'studio/repo_picker_page.dart';
import 'studio/studio_workspace_page.dart';

/// Sample data for the design gallery only.
///
/// Production adapters in `lib/ui/v2/app/` build every screen from live state;
/// this file is imported exclusively by the web/gallery preview so a reviewer
/// sees real-looking content instead of empty states.
V2SettingsHubData previewSettingsHubData() {
  V2SettingsItem row(String id, String label, IconData icon, String subtitle) =>
      V2SettingsItem(
        id: id,
        label: label,
        icon: icon,
        subtitle: subtitle,
        onTap: () {},
      );

  return V2SettingsHubData(
    profile: const V2SettingsProfile(
      name: 'Aarav Sharma',
      email: 'aarav@gmail.com',
      initials: 'AS',
      planLabel: 'Ovid Plus',
    ),
    account: V2SettingsSection(
      title: 'Account',
      items: [
        row(
          'account',
          'Account',
          Icons.manage_accounts_rounded,
          'Profile, sign-in methods and data control',
        ),
        row(
          'plan_billing',
          'Plan & billing',
          Icons.credit_card_rounded,
          'Ovid Plus · 15 GB storage',
        ),
        row(
          'usage',
          'Usage',
          Icons.data_usage_rounded,
          'Tokens, requests and storage',
        ),
        row(
          'credentials',
          'Credentials',
          Icons.key_rounded,
          'Sign-in methods and browser logins',
        ),
      ],
    ),
    chat: V2SettingsSection(
      title: 'Chat',
      items: [
        row(
          'appearance',
          'Personalization',
          Icons.palette_outlined,
          'Theme, memory, reasoning and text size',
        ),
        row(
          'memory',
          'Memory',
          Icons.psychology_outlined,
          'Global and project memory',
        ),
        row(
          'shared_memory',
          'Shared memory',
          Icons.hub_outlined,
          'Let project members reuse facts',
        ),
        row(
          'memory_files',
          'Memory files',
          Icons.folder_outlined,
          'What Ovid remembers',
        ),
      ],
    ),
    models: V2SettingsSection(
      title: 'Models',
      items: [
        row(
          'connectors',
          'Connectors',
          Icons.extension_rounded,
          '49 apps · 60 plugins and add-ons',
        ),
        row(
          'presets',
          'Agent presets',
          Icons.tune_rounded,
          'How Ovid approaches a task',
        ),
        row(
          'response_wait',
          'Response wait limit',
          Icons.timer_outlined,
          'How long Ovid waits for a reply',
        ),
      ],
    ),
    dataControl: V2SettingsSection(
      title: 'Data control',
      items: [
        row(
          'export',
          'Export or import',
          Icons.swap_vert_rounded,
          'Up to 64 MB · 1,000 chats',
        ),
        row(
          'permissions',
          'Permissions',
          Icons.verified_user_outlined,
          'Microphone and notifications',
        ),
        row(
          'crash',
          'Crash reports',
          Icons.bug_report_outlined,
          'Anonymous and optional',
        ),
        row(
          'storage',
          'Storage',
          Icons.storage_rounded,
          '6.2 GB of 15 GB used',
        ),
        row(
          'delete',
          'Delete data',
          Icons.delete_outline_rounded,
          'Remove chats, files and memory',
        ),
        row(
          'reset_memory',
          'Reset memory',
          Icons.restart_alt_rounded,
          'Forget everything Ovid learned',
        ),
      ],
    ),
    advanced: V2SettingsSection(
      title: 'Advanced',
      items: [
        row(
          'notifications',
          'Notifications',
          Icons.notifications_outlined,
          'Runs, schedules and security',
        ),
        row(
          'app_lock',
          'App lock',
          Icons.lock_outline_rounded,
          'Require a PIN when Ovid returns',
        ),
        row(
          'account_health',
          'Account health',
          Icons.health_and_safety_outlined,
          'Plan, usage and deletion',
        ),
        row(
          'about',
          'About',
          Icons.info_outline_rounded,
          'Version and legal documents',
        ),
      ],
    ),
    showReasoning: true,
    onReasoningChanged: (_) {},
    onAddConnector: () {},
    onProfileTap: () {},
  );
}

/// Project detail with chats, memory files and storage in use.
V2ProjectDetailData previewProjectDetailData() {
  return const V2ProjectDetailData(
    projectName: 'Mobile App Redesign',
    shared: true,
    chatCount: 3,
    chats: <V2ProjectChat>[
      V2ProjectChat(
        id: 'brand',
        title: 'Brand palette chat',
        modelLabel: 'Auto',
        timeLabel: '2h ago',
      ),
      V2ProjectChat(
        id: 'onboarding',
        title: 'Onboarding copy pass',
        modelLabel: 'Claude Sonnet',
        timeLabel: 'Yesterday',
      ),
    ],
    memoryFiles: <V2ProjectMemoryFile>[
      V2ProjectMemoryFile(
        id: 'brand-md',
        name: 'brand.md',
        sizeLabel: '12 KB',
        updatedLabel: 'Updated 2h ago',
        preview: 'Primary colour is violet. Headings use Inter.',
      ),
      V2ProjectMemoryFile(
        id: 'decisions-md',
        name: 'decisions.md',
        sizeLabel: '4 KB',
        updatedLabel: 'Updated yesterday',
        preview: 'Use the Go plan for the first team rollout.',
      ),
    ],
    storageLabel: '340 MB of 3 GB',
    storageFraction: 0.11,
  );
}

/// Shared-memory screen with one scope shared into the project.
V2SharedMemoryPageData previewSharedMemoryData() {
  return const V2SharedMemoryPageData(
    enabled: true,
    factCount: 6,
    scopes: <V2SharedMemoryScope>[
      V2SharedMemoryScope(
        id: 'chat',
        kind: V2SharedMemoryScopeKind.chat,
        title: 'This chat',
        description: 'Facts learned in this conversation.',
        audience: 'Only you',
        shared: true,
      ),
      V2SharedMemoryScope(
        id: 'project',
        kind: V2SharedMemoryScopeKind.project,
        title: 'Project',
        description: 'Facts this project can reuse.',
        audience: 'Project members',
        shared: true,
      ),
      V2SharedMemoryScope(
        id: 'global',
        kind: V2SharedMemoryScopeKind.global,
        title: 'Global',
        description: 'Facts reused in every chat you start.',
        audience: 'Only you, everywhere',
      ),
    ],
    onEnabledChanged: _noopBool,
    onScopeChanged: _noopScope,
  );
}

/// Share sheet mid-flight as a Collab room that viewers can also fork.
V2ShareSheetData previewShareSheetData() {
  return const V2ShareSheetData(
    link: 'ovidsi.com/c/79f9b4c0e',
    creatorName: 'Aarav Sharma',
    mode: V2ShareMode.collab,
    memberCount: 4,
    viewerCanFork: true,
  );
}

/// A Collab room with an owner, two senders and one read-only viewer.
V2CollabMembersPageData previewCollabMembersData() {
  return const V2CollabMembersPageData(
    chatName: 'Auth refactor',
    memberCount: 4,
    creatorName: 'Aarav Sharma',
    members: <V2CollabMember>[
      V2CollabMember(
        id: 'you',
        name: 'You',
        subtitle: 'Owner',
        role: V2CollabRole.owner,
        isYou: true,
        isCreator: true,
        online: true,
        initials: 'AS',
      ),
      V2CollabMember(
        id: 'priya',
        name: 'Priya Nair',
        subtitle: 'Can send messages',
        role: V2CollabRole.canChat,
        online: true,
        initials: 'PN',
      ),
      V2CollabMember(
        id: 'rohan',
        name: 'Rohan Mehta',
        subtitle: 'View only',
        role: V2CollabRole.viewOnly,
        initials: 'RM',
      ),
      V2CollabMember(
        id: 'meera',
        name: 'Meera Iyer',
        subtitle: 'Can send messages',
        role: V2CollabRole.canChat,
        initials: 'MI',
      ),
    ],
    storageUsedLabel: '1.2 GB',
    storageTotalLabel: '15 GB',
    storageFreeLabel: '13.8 GB free',
    storagePercent: 0.08,
  );
}

void _noopBool(bool _) {}
void _noopScope(String _, bool _) {}

/// The settings index driven by the same sample sections the hub renders.
V2SettingsSearchData previewSettingsSearchData() =>
    V2SettingsSearchData.fromHub(previewSettingsHubData());

/// A short privacy policy so the legal layout has real structure.
V2LegalPageData previewLegalData() {
  return const V2LegalPageData(
    title: 'Privacy policy',
    icon: Icons.privacy_tip_outlined,
    updatedAt: '12 March 2026',
    summary:
        'This is the short version. Ovid keeps your chats in your account, '
        'never sells them, and only shares what you explicitly share.',
    sections: <V2LegalSection>[
      V2LegalSection(
        heading: 'What we store',
        body:
            'Your chats, files, memory notes and the workspace files you '
            'connect. Storage counts against your plan.',
      ),
      V2LegalSection(
        heading: 'What we never do',
        bullets: <String>[
          'Sell your data or your prompts.',
          'Train models on your private chats.',
          'Keep a Studio token in .git/config.',
        ],
      ),
      V2LegalSection(
        heading: 'Deleting your account',
        body:
            'Deletion starts a 24-hour grace period. Sign in again before '
            'it ends to restore the account.',
      ),
    ],
  );
}

/// A unified diff in the Studio code viewer.
V2CodeViewerData previewCodeViewerData() {
  return const V2CodeViewerData(
    fileName: 'auth_service.dart',
    filePath: 'lib/core/auth_service.dart',
    diff: true,
    lines: <V2CodeViewerLine>[
      V2CodeViewerLine(
        text: 'class AuthService {',
        oldNumber: 12,
        newNumber: 12,
      ),
      V2CodeViewerLine(
        text: '  Future<void> signIn(String email) async {',
        oldNumber: 13,
        newNumber: 13,
      ),
      V2CodeViewerLine(
        text: '    await _guard.requireBiometrics();',
        kind: V2CodeViewerLineKind.removed,
        oldNumber: 14,
      ),
      V2CodeViewerLine(
        text: '    await _guard.requireRecentAuth();',
        kind: V2CodeViewerLineKind.added,
        newNumber: 14,
      ),
      V2CodeViewerLine(
        text: '    return _session.open(email);',
        oldNumber: 15,
        newNumber: 15,
      ),
      V2CodeViewerLine(text: '  }', oldNumber: 16, newNumber: 16),
      V2CodeViewerLine(text: '}', oldNumber: 17, newNumber: 17),
    ],
  );
}

/// GitHub's read/write/admin permissions with the tools they unlock.
V2ConnectorPermissionsData previewConnectorPermissionsData() {
  return const V2ConnectorPermissionsData(
    connectorId: 'github',
    connectorName: 'GitHub',
    connectorDescription: 'Repositories, issues and pull requests.',
    accountLabel: 'aarav@gmail.com',
    permissions: <V2ConnectorPermissionItem>[
      V2ConnectorPermissionItem(
        id: 'repo-read',
        name: 'Read repositories',
        scope: V2ConnectorPermissionScope.read,
        description: 'Clone a repo and read its files and branches.',
        toolIds: <String>['repo_clone', 'repo_files', 'repo_branches'],
      ),
      V2ConnectorPermissionItem(
        id: 'pr-write',
        name: 'Write pull requests',
        scope: V2ConnectorPermissionScope.write,
        description: 'Open, comment on and merge pull requests.',
        risk: V2ConnectorPermissionRisk.medium,
        toolIds: <String>['pr_open', 'pr_comment'],
      ),
      V2ConnectorPermissionItem(
        id: 'admin',
        name: 'Manage the organisation',
        scope: V2ConnectorPermissionScope.admin,
        description: 'Change repository settings, secrets and access.',
        risk: V2ConnectorPermissionRisk.high,
        granted: false,
        toolIds: <String>['repo_settings'],
      ),
    ],
    tools: <V2ConnectorPermissionTool>[
      V2ConnectorPermissionTool(
        id: 'repo_clone',
        name: 'Clone repository',
        scope: V2ConnectorPermissionScope.read,
        permissionId: 'repo-read',
      ),
      V2ConnectorPermissionTool(
        id: 'pr_open',
        name: 'Open pull request',
        scope: V2ConnectorPermissionScope.write,
        permissionId: 'pr-write',
      ),
      V2ConnectorPermissionTool(
        id: 'repo_settings',
        name: 'Update repository settings',
        scope: V2ConnectorPermissionScope.admin,
        permissionId: 'admin',
      ),
    ],
    canDo: <String>[
      'Read the branches you pick for Studio.',
      'Open a pull request with the changes it made.',
    ],
    cannotDo: <String>[
      'Push to a branch you did not pick.',
      'Read a private repo you did not connect.',
    ],
    revokeNote:
        'Revoking a permission stops the tools beside it immediately. Files '
        'already cloned stay in your workspace.',
  );
}

/// The phone step of sign-in, mid-entry.
V2PhoneAuthData previewPhoneAuthData() {
  return const V2PhoneAuthData(phone: '98765 43210');
}

/// Editing an existing project memory file.
V2ProjectMemoryEditorData previewProjectMemoryEditorData() {
  return const V2ProjectMemoryEditorData(
    fileId: 'brand-md',
    name: 'brand.md',
    content: 'Primary colour is violet.\nHeadings use Inter.',
    projectName: 'Mobile App Redesign',
    takenNames: <String>['decisions.md'],
  );
}

/// The export picker with three chats, one of them heavy.
V2ExportPickerSheetData previewExportPickerData() {
  return const V2ExportPickerSheetData(
    sessions: <V2ExportPickerSession>[
      V2ExportPickerSession(
        id: 'c1',
        name: 'Brand palette chat',
        sizeBytes: 4200000,
        messageCount: 42,
        detail: '42 messages · updated 2h ago',
      ),
      V2ExportPickerSession(
        id: 'c2',
        name: 'Auth refactor',
        sizeBytes: 12800000,
        messageCount: 180,
        detail: '180 messages · updated yesterday',
        heavyArtifacts: true,
      ),
      V2ExportPickerSession(
        id: 'c3',
        name: 'Launch checklist',
        sizeBytes: 980000,
        messageCount: 12,
        detail: '12 messages · updated last week',
        selected: false,
      ),
    ],
  );
}

/// The delete-account confirmation, locked until the email is typed.
V2ConfirmTypedSheetData previewConfirmTypedData() {
  return const V2ConfirmTypedSheetData(contact: 'aarav@gmail.com');
}

/// The permission picker with General in force.
V2PermissionSheetData previewPermissionSheetData() {
  return const V2PermissionSheetData(selectedId: 'auto');
}

/// The composer "+" menu on the Plus plan without a Studio folder yet.
V2ComposerPlusData previewComposerPlusData() {
  return const V2ComposerPlusData(
    plan: V2ComposerPlusPlan.plus,
    customConnectorsUsed: 3,
  );
}

/// A commit sheet with staged changes on a protected branch.
V2CommitSheetData previewCommitSheetData() {
  return const V2CommitSheetData(
    branchLabel: 'feature/hero-revamp',
    initialMessage: 'Refresh the hero and tighten spacing',
    behindCount: 2,
    protectedBranch: true,
    files: <V2CommitFile>[
      V2CommitFile(path: 'lib/ui/home.dart', additions: 42, deletions: 8),
      V2CommitFile(path: 'lib/ui/theme.dart', additions: 6, deletions: 2),
    ],
  );
}

// ── Component previews ──────────────────────────────────────────────────────
// The widgets below are sections rather than pages, so the gallery mounts each
// one with sample state that shows its content state, not the empty state.

/// Five-way storage split at 6.2 GB of 15 GB.
V2StorageBreakdownData previewStorageBreakdownData() {
  return V2StorageBreakdownData(
    usedBytes: 6657199308,
    totalBytes: 16106127360,
    amountLabel: '6.2 GB',
    totalLabel: '15 GB',
    entries: const <V2StorageCategoryBytes>[
      V2StorageCategoryBytes(
        category: V2StorageCategory.chats,
        bytes: 2469606195,
        sizeLabel: '2.3 GB',
      ),
      V2StorageCategoryBytes(
        category: V2StorageCategory.artifacts,
        bytes: 1932735283,
        sizeLabel: '1.8 GB',
      ),
      V2StorageCategoryBytes(
        category: V2StorageCategory.uploads,
        bytes: 1181116006,
        sizeLabel: '1.1 GB',
      ),
      V2StorageCategoryBytes(
        category: V2StorageCategory.memory,
        bytes: 644245094,
        sizeLabel: '600 MB',
      ),
      V2StorageCategoryBytes(
        category: V2StorageCategory.cache,
        bytes: 429496730,
        sizeLabel: '400 MB',
      ),
    ],
    selectedCategory: V2StorageCategory.artifacts,
    onCategoryTap: _noopCategory,
    onEmptyAction: _noop,
    onRetry: _noop,
  );
}

/// Seven days of token use for [V2DailyTokensChart].
List<V2TokenChartPoint> previewTokenChartPoints() {
  return const <V2TokenChartPoint>[
    V2TokenChartPoint(
      id: 'mon',
      label: 'Mon',
      value: 4200000,
      valueLabel: '4.2M',
    ),
    V2TokenChartPoint(
      id: 'tue',
      label: 'Tue',
      value: 6800000,
      valueLabel: '6.8M',
    ),
    V2TokenChartPoint(
      id: 'wed',
      label: 'Wed',
      value: 2100000,
      valueLabel: '2.1M',
    ),
    V2TokenChartPoint(
      id: 'thu',
      label: 'Thu',
      value: 9400000,
      valueLabel: '9.4M',
    ),
    V2TokenChartPoint(
      id: 'fri',
      label: 'Fri',
      value: 7700000,
      valueLabel: '7.7M',
    ),
    V2TokenChartPoint(
      id: 'sat',
      label: 'Sat',
      value: 5200000,
      valueLabel: '5.2M',
    ),
    V2TokenChartPoint(
      id: 'sun',
      label: 'Sun',
      value: 8900000,
      valueLabel: '8.9M',
    ),
  ];
}

/// A realistic model split for [V2ModelShareChart].
List<V2ModelShareSlice> previewModelShareSlices() {
  return const <V2ModelShareSlice>[
    V2ModelShareSlice(
      id: 'auto',
      label: 'Auto',
      percent: 52,
      valueLabel: '22.8M tokens',
    ),
    V2ModelShareSlice(
      id: 'pro',
      label: 'Ovid Pro 1.5',
      percent: 28,
      valueLabel: '12.3M tokens',
    ),
    V2ModelShareSlice(
      id: 'flash',
      label: 'Ovid Flash',
      percent: 20,
      valueLabel: '8.8M tokens',
    ),
  ];
}

/// A week of image generations for [V2ImageUsageChart].
List<V2ImageUsagePoint> previewImageUsagePoints() {
  return const <V2ImageUsagePoint>[
    V2ImageUsagePoint(
      id: 'mon',
      label: 'Mon',
      count: 4,
      valueLabel: '4 images',
    ),
    V2ImageUsagePoint(
      id: 'tue',
      label: 'Tue',
      count: 7,
      valueLabel: '7 images',
    ),
    V2ImageUsagePoint(
      id: 'wed',
      label: 'Wed',
      count: 2,
      valueLabel: '2 images',
    ),
    V2ImageUsagePoint(
      id: 'thu',
      label: 'Thu',
      count: 9,
      valueLabel: '9 images',
    ),
    V2ImageUsagePoint(
      id: 'fri',
      label: 'Fri',
      count: 6,
      valueLabel: '6 images',
    ),
    V2ImageUsagePoint(
      id: 'sat',
      label: 'Sat',
      count: 3,
      valueLabel: '3 images',
    ),
    V2ImageUsagePoint(
      id: 'sun',
      label: 'Sun',
      count: 5,
      valueLabel: '5 images',
    ),
  ];
}

/// The full plan table with Ovid Plus marked current.
V2PlanCompareData previewPlanCompareData() {
  return V2PlanCompareData(
    plans: V2PlanComparePlan.canonical,
    currentPlanId: 'plus',
    onRetry: _noop,
  );
}

/// Filters narrowed to generated images from one chat.
V2ArtifactFilters previewArtifactFilters() {
  return const V2ArtifactFilters(
    type: V2ArtifactTypeFilter.image,
    source: V2ArtifactSourceFilter.generated,
    sessionId: 'brand',
    sort: V2ArtifactSort.newest,
  );
}

/// Sessions offered by the artifact session filter.
List<V2ArtifactSession> previewArtifactSessions() {
  return const <V2ArtifactSession>[
    V2ArtifactSession(id: 'brand', title: 'Brand palette chat', count: 6),
    V2ArtifactSession(id: 'auth', title: 'Auth refactor', count: 4),
    V2ArtifactSession(id: 'upload', title: 'Uploads', count: 2),
  ];
}

/// Twelve artifacts in the library, four matching the active filters.
V2ArtifactSizeSummary previewArtifactSizeSummary() {
  return const V2ArtifactSizeSummary(
    totalBytes: 2588672,
    totalCount: 12,
    visibleCount: 4,
    storageLimitLabel: '3 GB',
  );
}

/// A Dart artifact with the first lines of code.
V2ArtifactPreviewData previewArtifactCodePreviewData() {
  return const V2ArtifactPreviewData(
    name: 'auth_service.dart',
    type: V2ArtifactPreviewType.code,
    typeLabel: 'Dart',
    sizeLabel: '6 KB',
    codeFile: 'lib/core/auth_service.dart',
    codeTotalLines: 184,
    code:
        'class AuthService {\n'
        '  Future<void> signIn(String email) async {\n'
        '    await _guard.requireRecentAuth();\n'
        '    return _session.open(email);\n'
        '  }\n'
        '}',
    metadata: <V2ArtifactPreviewMeta>[
      V2ArtifactPreviewMeta(label: 'Language', value: 'Dart'),
      V2ArtifactPreviewMeta(label: 'Lines', value: '184'),
    ],
    note: 'Showing the first lines. Open externally for the full file.',
  );
}

/// A PDF artifact that shows metadata instead of a live document.
V2ArtifactPreviewData previewArtifactDocumentPreviewData() {
  return const V2ArtifactPreviewData(
    name: 'Q3-launch-brief.pdf',
    type: V2ArtifactPreviewType.document,
    typeLabel: 'PDF',
    sizeLabel: '1.2 MB',
    metadata: <V2ArtifactPreviewMeta>[
      V2ArtifactPreviewMeta(label: 'Pages', value: '12'),
      V2ArtifactPreviewMeta(label: 'Words', value: '3,400'),
      V2ArtifactPreviewMeta(label: 'Created', value: '12 Oct 2026'),
    ],
    note: 'Documents are not rendered in the app. Open externally to read it.',
  );
}

/// Weekday mornings at 9:00 in IST.
V2CadenceDraft previewCadenceDraft() {
  return const V2CadenceDraft(
    frequency: V2CadenceFrequency.weekly,
    hour: 9,
    minute: 0,
    days: <int>{1, 2, 3, 4, 5},
    timezoneLabel: 'Asia/Kolkata (GMT +5:30)',
    timezoneShort: 'IST',
  );
}

/// Two days of scheduled runs, including one failure to retry.
V2RunTimelineData previewRunTimelineData() {
  return const V2RunTimelineData(
    runs: <V2TimelineRun>[
      V2TimelineRun(
        id: 'run-1',
        dayLabel: 'Today · 21 Oct',
        timeLabel: '9:00 AM',
        durationLabel: '1m 12s',
        outcome: V2RunOutcome.succeeded,
        summary: 'Saved 12 items to daily.md',
        artifactName: 'daily.md',
      ),
      V2TimelineRun(
        id: 'run-2',
        dayLabel: 'Today · 21 Oct',
        timeLabel: '8:00 AM',
        durationLabel: '48s',
        outcome: V2RunOutcome.failed,
        summary: 'The source page timed out before it could be read.',
        failureDetail: 'news.example.com did not respond within 30 seconds.',
      ),
      V2TimelineRun(
        id: 'run-3',
        dayLabel: 'Yesterday · 20 Oct',
        timeLabel: '9:00 AM',
        durationLabel: '2m 04s',
        outcome: V2RunOutcome.succeeded,
        summary: 'Summarised 8 new pull requests',
        artifactName: 'pr-digest.md',
      ),
    ],
  );
}

/// A Collab link with four of fifty members.
V2ShareLinkCardData previewShareLinkCardData() {
  return V2ShareLinkCardData(
    url: 'ovidsi.com/c/79f9b4c0e',
    mode: V2ShareMode.collab,
    createdAt: DateTime(2026, 10, 12),
    memberCount: 4,
    capacity: 50,
    copied: true,
  );
}

/// A turn in progress with four people waiting.
V2CollabTurnBannerData previewTurnBannerData() {
  return const V2CollabTurnBannerData(
    holderName: 'Priya Nair',
    timeLeftLabel: '24s left in turn',
    timeLeftFraction: 0.6,
    queue: <V2CollabTurnWaiter>[
      V2CollabTurnWaiter(
        name: 'You',
        initials: 'AS',
        isYou: true,
        waitLabel: 'about 24s',
      ),
      V2CollabTurnWaiter(
        name: 'Rohan Mehta',
        initials: 'RM',
        waitLabel: 'about 1m',
      ),
      V2CollabTurnWaiter(
        name: 'Meera Iyer',
        initials: 'MI',
        waitLabel: 'about 2m',
      ),
      V2CollabTurnWaiter(
        name: 'Dev Patel',
        initials: 'DP',
        waitLabel: 'about 3m',
      ),
      V2CollabTurnWaiter(
        name: 'Sana Khan',
        initials: 'SK',
        waitLabel: 'about 4m',
      ),
    ],
  );
}

/// A finished run's steps, with one step still waiting for approval.
List<V2TimelineItem> previewTrajectoryTimelineItems() {
  return const <V2TimelineItem>[
    V2TimelineItem(
      id: 'plan',
      title: 'Plan the change',
      description:
          'Identified the auth refresh path and the two failing tests.',
      timeLabel: '10:41',
      durationLabel: '12s',
      status: V2TimelineStatus.success,
      initiallyExpanded: true,
      expandedDetail:
          'Plan: replace the old guard, keep the retry, then update the two '
          'widgets that depend on the session.',
    ),
    V2TimelineItem(
      id: 'search',
      title: 'Searched the workspace',
      description: 'Found the session guard in lib/core/auth_guard.dart.',
      timeLabel: '10:42',
      durationLabel: '4s',
      status: V2TimelineStatus.success,
    ),
    V2TimelineItem(
      id: 'subagent',
      title: 'Dispatched explorer subagent',
      description: 'Tracing every caller of AuthService.signIn.',
      timeLabel: '10:43',
      durationLabel: '2m 10s',
      status: V2TimelineStatus.running,
    ),
    V2TimelineItem(
      id: 'edit',
      title: 'Edit auth_service.dart',
      description: 'Waiting for approval before changing the session call.',
      timeLabel: '10:45',
      status: V2TimelineStatus.warning,
      statusLabel: 'Waiting for approval',
    ),
    V2TimelineItem(
      id: 'tests',
      title: 'Run the auth tests',
      description: 'Not started yet.',
      timeLabel: '10:45',
      status: V2TimelineStatus.neutral,
      statusLabel: 'Queued',
    ),
  ];
}

/// A completed subagent with the strict five-key summary.
V2SubagentSummaryData previewSubagentSummaryData() {
  return const V2SubagentSummaryData(
    status: 'completed',
    filesModified: <String>[
      'lib/core/auth_service.dart',
      'lib/ui/v2/chat/chat_page.dart',
    ],
    artifactsCreated: <String>['auth-diff.patch'],
    keyFindings: <String>[
      'Refreshed tokens now retry once before failing.',
      'Two widgets shared a duplicate key on the chat surface.',
    ],
  );
}

/// Step two of a three-step onboarding flow.
V2OnboardingStepData previewOnboardingStepData() {
  return const V2OnboardingStepData(
    step: 2,
    totalSteps: 3,
    trailingLabel: 'Your goal',
  );
}

/// A failed purchase with a retry and a manage-subscription action.
V2PurchaseBannerData previewPurchaseBannerData() {
  return const V2PurchaseBannerData(
    status: V2PurchaseBannerStatus.failed,
    planName: 'Ovid Plus',
    detail: 'The store did not confirm the purchase. Nothing was charged.',
  );
}

/// Every recoverable state tile the product can show.
List<V2StateTileKind> previewStateTileKinds() {
  return const <V2StateTileKind>[
    V2StateTileKind.offline,
    V2StateTileKind.planLimited,
    V2StateTileKind.storageFull,
    V2StateTileKind.abuseBlocked,
    V2StateTileKind.deletionPending,
    V2StateTileKind.serverError,
  ];
}

/// A workspace tree with three changed files and folders expanded.
V2FileTreeData previewFileTreeData() {
  return const V2FileTreeData(
    selectedPath: 'lib/core/auth_service.dart',
    expandedPaths: <String>{'lib', 'lib/core', 'lib/ui'},
    nodes: <V2FileTreeEntry>[
      V2FileTreeEntry(
        name: 'lib',
        path: 'lib',
        isFolder: true,
        children: <V2FileTreeEntry>[
          V2FileTreeEntry(
            name: 'core',
            path: 'lib/core',
            isFolder: true,
            children: <V2FileTreeEntry>[
              V2FileTreeEntry(
                name: 'auth_service.dart',
                path: 'lib/core/auth_service.dart',
                change: V2FileChange.modified,
              ),
              V2FileTreeEntry(
                name: 'auth_guard.dart',
                path: 'lib/core/auth_guard.dart',
              ),
            ],
          ),
          V2FileTreeEntry(
            name: 'ui',
            path: 'lib/ui',
            isFolder: true,
            children: <V2FileTreeEntry>[
              V2FileTreeEntry(
                name: 'chat_page.dart',
                path: 'lib/ui/chat_page.dart',
                change: V2FileChange.added,
              ),
              V2FileTreeEntry(
                name: 'theme.dart',
                path: 'lib/ui/theme.dart',
                change: V2FileChange.removed,
              ),
            ],
          ),
        ],
      ),
      V2FileTreeEntry(name: 'pubspec.yaml', path: 'pubspec.yaml'),
      V2FileTreeEntry(name: 'README.md', path: 'README.md'),
    ],
  );
}

/// The three tabs Ovid opened, one of them headless.
List<V2BrowserTabItem> previewBrowserTabs() {
  return const <V2BrowserTabItem>[
    V2BrowserTabItem(id: 'docs', title: 'Ovid docs', host: 'docs.ovidsi.com'),
    V2BrowserTabItem(
      id: 'github',
      title: 'PR #214 · GitHub',
      host: 'github.com',
    ),
    V2BrowserTabItem(
      id: 'news',
      title: 'Hacker News',
      host: 'news.ycombinator.com',
      headless: true,
    ),
  ];
}

/// Ovid's pointer just above the fold of the live page.
V2ViewportCursor previewViewportCursor() {
  return const V2ViewportCursor(x: 0.58, y: 0.42);
}

/// Two messages waiting behind the active run.
List<String> previewQueuedMessages() {
  return const <String>[
    'Also add a retry to the token refresh.',
    'Then update the changelog before you finish.',
  ];
}

void _noop() {}
void _noopCategory(V2StorageCategory _) {}

/// Models shown in the gallery so the picker can be exercised end to end.
List<V2ModelOption> previewModelOptions({required bool locked}) =>
    <V2ModelOption>[
      V2ModelOption(
        id: 'ovid-2-flash',
        name: 'Ovid 2 Flash',
        subtitle: 'Fast answers and small edits',
        speed: 'Fast',
        costHint: '1 credit',
        locked: locked,
        tag: locked ? 'Go and up' : null,
        icon: Icons.bolt_rounded,
      ),
      V2ModelOption(
        id: 'ovid-2-pro',
        name: 'Ovid 2 Pro',
        subtitle: 'Hard reasoning and long code',
        speed: 'Slower',
        costHint: '4 credits',
        locked: locked,
        tag: locked ? 'Plus and up' : 'Best for code',
        icon: Icons.psychology_rounded,
      ),
      V2ModelOption(
        id: 'custom-anthropic',
        name: 'Claude (your key)',
        subtitle: 'Connected provider',
        speed: 'Standard',
        costHint: 'Your key',
        locked: locked,
        tag: locked ? 'Paid plan' : null,
        icon: Icons.key_rounded,
      ),
    ];

// ── Minimised screens ───────────────────────────────────────────────────────
// After the minimal-UI pass these screens render an empty state unless the
// gallery supplies real content. Each builder below mirrors what production
// adapters in `lib/ui/v2/app/` hand the screen, so a reviewer sees the layout
// at its real density instead of a placeholder.

/// An active run with a transcript, a tool, an artifact and a queued message.
V2LiveChatData previewLiveChatData() {
  return const V2LiveChatData(
    sessionTitle: 'Auth refresh',
    modelLabel: 'Ovid 2 Pro',
    running: true,
    statusLabel: 'Ovid is editing auth_service.dart',
    queuedCount: 1,
    queuedPreview: 'Then update the changelog.',
    items: <V2LiveChatItem>[
      V2LiveUserMessage(
        id: 'u1',
        text: 'Refresh the auth token before the session opens.',
        timeLabel: '10:41',
      ),
      V2LiveThinking(
        id: 't1',
        label: 'Reading the auth guard',
        details: <String>[
          'Opened lib/core/auth_guard.dart',
          'Found the refresh path used by sign-in',
        ],
      ),
      V2LiveTool(
        id: 'tool1',
        title: 'Search the workspace',
        status: 'Found 4 callers',
        progress: 1,
        details: <String>[
          'lib/core/auth_service.dart',
          'lib/ui/v2/chat/chat_page.dart',
        ],
      ),
      V2LiveAssistantMessage(
        id: 'a1',
        markdown:
            'I will refresh the token once and retry before failing, so a '
            'cold start no longer signs you out.',
      ),
      V2LiveArtifact(
        id: 'art1',
        fileName: 'auth_service.dart',
        meta: 'lib/core · +14 −6',
        statusLabel: 'Updated',
        previewLabel: 'Show diff',
      ),
      V2LiveTool(
        id: 'tool2',
        title: 'Run the auth tests',
        status: 'Running',
        progress: 0.4,
        icon: Icons.play_arrow_rounded,
      ),
    ],
  );
}

/// A finished run with five steps and one subagent.
V2RunTrajectoryPageData previewRunTrajectoryData() {
  return const V2RunTrajectoryPageData(
    title: 'Auth refresh',
    runLabel: 'Run 4 of 7',
    steps: <V2RunStep>[
      V2RunStep(
        id: 's1',
        title: 'Plan the change',
        detail: 'Two failing tests pointed at the refresh path.',
        durationLabel: '12s',
        kind: V2RunStepKind.plan,
      ),
      V2RunStep(
        id: 's2',
        title: 'Search the workspace',
        detail: 'Found the guard in lib/core/auth_guard.dart.',
        durationLabel: '4s',
        kind: V2RunStepKind.search,
        sources: <V2RunSource>[V2RunSource(label: 'lib/core/auth_guard.dart')],
      ),
      V2RunStep(
        id: 's3',
        title: 'Edit auth_service.dart',
        detail: 'Refreshed the token once before retrying.',
        durationLabel: '48s',
        kind: V2RunStepKind.write,
        fileName: 'auth_service.dart',
        fileMeta: '+14 −6',
      ),
      V2RunStep(
        id: 's4',
        title: 'Run the auth tests',
        detail: 'Both tests now pass.',
        durationLabel: '1m 20s',
        kind: V2RunStepKind.finish,
      ),
    ],
    subagents: <V2SubagentLaunch>[
      V2SubagentLaunch(
        id: 'sub1',
        agentName: 'Explorer',
        taskSummary: 'Found every AuthService.signIn caller.',
        timeLabel: '10:43',
        durationLabel: '2m 10s',
      ),
    ],
  );
}

/// A subagent mid-run with a log and a finished summary.
V2SubagentPageData previewSubagentData() {
  return V2SubagentPageData(
    name: 'Explorer',
    instanceLabel: 'Instance 2 of 3',
    stepLabel: 'Reading chat_page.dart',
    paceLabel: 'On pace',
    goal: 'Find every caller of AuthService.signIn.',
    startedLabel: 'Started 10:43',
    elapsedLabel: '2m 10s elapsed',
    timeLimitLabel: '8 h',
    remainingLabel: '7h 57m left',
    totalLogLines: 4,
    progress: 0.62,
    files: const <String>[
      'lib/core/auth_service.dart',
      'lib/ui/v2/chat/chat_page.dart',
    ],
    logLines: const <V2SubagentLogLine>[
      V2SubagentLogLine(time: '10:43', text: 'Opened the workspace tree.'),
      V2SubagentLogLine(time: '10:44', text: 'Searching for signIn callers.'),
      V2SubagentLogLine(time: '10:45', text: 'Found 4 call sites.'),
      V2SubagentLogLine(
        time: '10:45',
        text: 'Two widgets share a duplicate key.',
        tone: V2SubagentLogTone.accent,
      ),
    ],
    logPath: '~/.ovid/runs/explorer.log',
    summary: previewSubagentSummaryData(),
  );
}

/// Three schedules: two healthy, one that failed its last run.
V2SchedulesData previewSchedulesData() {
  return V2SchedulesData(
    now: DateTime(2026, 10, 21, 8, 30),
    schedules: <V2ScheduleItem>[
      V2ScheduleItem(
        id: 's-daily',
        title: 'Daily brief',
        description: 'Summarise overnight messages and pull requests.',
        rule: 'Every day at 9:00 AM',
        cadence: const V2CadenceDraft(frequency: V2CadenceFrequency.daily),
      ),
      V2ScheduleItem(
        id: 's-weekly',
        title: 'Weekly changelog',
        description: 'Draft the changelog from merged pull requests.',
        rule: 'Mondays at 6:00 PM',
        cadence: const V2CadenceDraft(hour: 18, days: <int>{1}),
        enabled: false,
      ),
      V2ScheduleItem(
        id: 's-pr',
        title: 'PR digest',
        description: 'List new pull requests that need review.',
        rule: 'Weekdays at 8:00 AM',
        cadence: const V2CadenceDraft(hour: 8),
        lastRunFailed: true,
      ),
    ],
  );
}

/// Three runs for one schedule, one of them failed.
V2ScheduleRunsData previewScheduleRunsData() {
  return V2ScheduleRunsData(
    scheduleTitle: 'Daily brief',
    total: 3,
    succeeded: 2,
    failed: 1,
    avgRuntimeLabel: '1m 21s',
    now: DateTime(2026, 10, 21, 12, 0),
    groups: <V2RunGroup>[
      V2RunGroup(
        label: 'Today · 21 Oct',
        runs: <V2ScheduleRun>[
          V2ScheduleRun(
            id: 'r1',
            timeLabel: '9:00 AM',
            durationLabel: '1m 12s',
            status: V2RunStatus.succeeded,
            summary: 'Saved 12 items to daily.md',
            startedAt: DateTime(2026, 10, 21, 9, 0),
            finishedAt: DateTime(2026, 10, 21, 9, 1, 12),
            artifactName: 'daily.md',
          ),
          V2ScheduleRun(
            id: 'r2',
            timeLabel: '8:00 AM',
            durationLabel: '48s',
            status: V2RunStatus.failed,
            summary: 'The source page timed out before it could be read.',
            startedAt: DateTime(2026, 10, 21, 8, 0),
            finishedAt: DateTime(2026, 10, 21, 8, 0, 48),
            error: 'news.example.com did not respond within 30 seconds.',
            failureTitle: 'Run failed · timed out',
            failureDetail: 'news.example.com did not respond in 30 seconds.',
          ),
        ],
      ),
      V2RunGroup(
        label: 'Yesterday · 20 Oct',
        runs: <V2ScheduleRun>[
          V2ScheduleRun(
            id: 'r3',
            timeLabel: '9:00 AM',
            durationLabel: '2m 04s',
            status: V2RunStatus.succeeded,
            summary: 'Summarised 8 new pull requests',
            startedAt: DateTime(2026, 10, 20, 9, 0),
            finishedAt: DateTime(2026, 10, 20, 9, 2, 4),
            artifactName: 'pr-digest.md',
          ),
        ],
      ),
    ],
  );
}

/// A working tree with three changed files.
V2ChangesData previewChangesData() {
  return const V2ChangesData(
    branchLabel: 'feature/hero-revamp',
    behindCount: 2,
    commitMessage: 'Refresh the hero and tighten spacing',
    files: <V2ChangedFile>[
      V2ChangedFile(
        path: 'lib/ui/home.dart',
        directory: 'lib/ui',
        additions: 42,
        deletions: 8,
        initiallyExpanded: true,
      ),
      V2ChangedFile(
        path: 'lib/ui/theme.dart',
        directory: 'lib/ui',
        additions: 6,
        deletions: 2,
      ),
      V2ChangedFile(path: 'pubspec.yaml', additions: 2, deletions: 1),
    ],
  );
}

/// Two GitHub repositories, the first with branches ready to pick.
V2RepoPickerData previewRepoPickerData() {
  return const V2RepoPickerData(
    accountLabel: 'aarav',
    repos: <V2Repo>[
      V2Repo(
        id: 'ovid-app',
        name: 'ovid-app',
        owner: 'aarav',
        description: 'The Ovid Si client.',
        language: 'Dart',
        updatedLabel: 'Updated 2h ago',
        isPrivate: true,
        branches: <V2RepoBranch>[
          V2RepoBranch(
            name: 'main',
            lastCommitLabel: 'Refresh the hero',
            isDefault: true,
          ),
          V2RepoBranch(
            name: 'feature/hero-revamp',
            lastCommitLabel: 'Tighten spacing',
          ),
        ],
      ),
      V2Repo(
        id: 'landing',
        name: 'landing',
        owner: 'aarav',
        description: 'Marketing site.',
        language: 'TypeScript',
        updatedLabel: 'Updated yesterday',
        branches: <V2RepoBranch>[V2RepoBranch(name: 'main', isDefault: true)],
      ),
    ],
  );
}

/// A branch switch with the current branch and two alternatives.
V2BranchPickerData previewBranchPickerData() {
  return const V2BranchPickerData(
    current: V2Branch(
      name: 'feature/hero-revamp',
      lastCommitLabel: 'Tighten spacing · 2h ago',
      isCurrent: true,
    ),
    branches: <V2Branch>[
      V2Branch(
        name: 'main',
        lastCommitLabel: 'Refresh the hero · yesterday',
        isDefault: true,
      ),
      V2Branch(
        name: 'feature/hero-revamp',
        lastCommitLabel: 'Tighten spacing · 2h ago',
        isCurrent: true,
      ),
      V2Branch(
        name: 'fix/auth-refresh',
        lastCommitLabel: 'Retry once · 3 days ago',
      ),
    ],
  );
}

/// A live Collab link with four of fifty seats used.
V2ShareChatSheetData previewShareChatData() {
  return const V2ShareChatSheetData(
    link: 'ovidsi.com/c/79f9b4c0e',
    mode: V2ShareMode.collab,
    memberCount: 4,
    creatorName: 'Aarav Sharma',
    viewerCanFork: true,
  );
}

/// A live Collab chat with a turn in progress and four messages.
V2CollabLivePageData previewCollabLiveData() {
  return const V2CollabLivePageData(
    title: 'Auth refactor',
    subtitle: '4 members · one sender at a time',
    selfName: 'Aarav Sharma',
    totalMembers: 4,
    turnHolderName: 'Priya Nair',
    turnTimeLeftLabel: '24s left',
    queueLabel: '4 waiting',
    creatorPaysStorage: true,
    participants: <V2CollabParticipant>[
      V2CollabParticipant(id: 'priya', name: 'Priya Nair', initials: 'PN'),
      V2CollabParticipant(id: 'rohan', name: 'Rohan Mehta', initials: 'RM'),
      V2CollabParticipant(id: 'meera', name: 'Meera Iyer', initials: 'MI'),
    ],
    messages: <V2CollabMessage>[
      V2CollabMessage(
        id: 'm1',
        speakerName: 'Priya Nair',
        timeLabel: '10:41',
        text: 'Starting on the token refresh. Tell me if the retry is wrong.',
        initials: 'PN',
        isTurnHolder: true,
      ),
      V2CollabMessage(
        id: 'm2',
        speakerName: 'Rohan Mehta',
        timeLabel: '10:42',
        text: 'One retry is enough. Do not loop.',
        initials: 'RM',
      ),
      V2CollabMessage(
        id: 'm3',
        speakerName: 'Ovid',
        timeLabel: '10:43',
        text: 'Refreshed the token once and re-ran the auth tests.',
        kind: V2CollabMessageKind.agent,
        agentStatus: 'Tests passed',
        toolName: 'run_tests',
        toolResult: '2 passed, 0 failed',
      ),
      V2CollabMessage(
        id: 'm4',
        speakerName: 'Meera Iyer',
        timeLabel: '10:44',
        text: 'Ship it.',
        initials: 'MI',
      ),
    ],
  );
}

/// A code artifact with its metadata and a download link.
V2ArtifactDetailData previewArtifactDetailData() {
  return const V2ArtifactDetailData(
    name: 'auth_service.dart',
    typeLabel: 'Dart',
    sizeLabel: '6 KB',
    createdLabel: 'Created 21 Oct, 10:44',
    versionLabel: 'Version 3',
    sourceChatTitle: 'Auth refresh',
    previewHeadline: 'Auth token refresh',
    previewCodeFile: 'lib/core/auth_service.dart',
    previewCode:
        'class AuthService {\n'
        '  Future<void> signIn(String email) async {\n'
        '    await _guard.requireRecentAuth();\n'
        '    return _session.open(email);\n'
        '  }\n'
        '}',
    previewTotalLines: 184,
    downloadUrl: 'https://ovidsi.com/a/79f9b4c0e',
    shareUrl: 'https://ovidsi.com/a/79f9b4c0e',
    openUrl: 'https://ovidsi.com/a/79f9b4c0e',
    details: <V2ArtifactDetailRow>[
      V2ArtifactDetailRow(label: 'Type', value: 'Dart source'),
      V2ArtifactDetailRow(label: 'Lines', value: '184'),
      V2ArtifactDetailRow(label: 'Model', value: 'Ovid 2 Pro'),
      V2ArtifactDetailRow(label: 'Chat', value: 'Auth refresh'),
      V2ArtifactDetailRow(
        label: 'Status',
        value: 'Ready',
        tone: V2ArtifactDetailTone.success,
      ),
    ],
  );
}

/// Three projects, one shared with the team.
V2ProjectsData previewProjectsData() {
  return const V2ProjectsData(
    projects: <V2Project>[
      V2Project(
        id: 'redesign',
        name: 'Mobile App Redesign',
        chatCount: 12,
        storageLabel: '340 MB',
        shared: true,
        memberInitials: <String>['PN', 'RM', 'MI'],
        updatedLabel: 'Updated 2h ago',
      ),
      V2Project(
        id: 'auth',
        name: 'Auth refactor',
        chatCount: 5,
        storageLabel: '48 MB',
        updatedLabel: 'Updated yesterday',
      ),
      V2Project(
        id: 'launch',
        name: 'Launch checklist',
        chatCount: 3,
        storageLabel: '12 MB',
        updatedLabel: 'Updated last week',
        colorKey: 'teal',
      ),
    ],
  );
}

/// Free, Go, Plus and Pro with one past purchase.
V2PlanBillingData previewPlanBillingData() {
  return V2PlanBillingData(
    currentPlanId: 'plus',
    plans: const <V2Plan>[
      V2Plan(
        id: 'free',
        name: 'Free',
        tagline: 'Try Ovid',
        priceUsd: 0,
        priceInr: 0,
        autoOnly: true,
        features: <String>['Auto model only', '2 GB storage'],
      ),
      V2Plan(
        id: 'go',
        name: 'Go',
        tagline: 'Everyday chats',
        priceUsd: 5,
        priceInr: 399,
        priceUsdYearly: 48,
        priceInrYearly: 3999,
        features: <String>['All models', '15 GB storage'],
      ),
      V2Plan(
        id: 'plus',
        name: 'Plus',
        tagline: 'Longer runs',
        priceUsd: 18,
        priceInr: 1499,
        priceUsdYearly: 180,
        priceInrYearly: 14999,
        features: <String>['More Studio time', '50 GB storage'],
        popular: true,
      ),
      V2Plan(
        id: 'pro',
        name: 'Pro',
        tagline: 'Heavy builds',
        priceUsd: 99,
        priceInr: 8299,
        priceUsdYearly: 990,
        priceInrYearly: 82999,
        features: <String>['Priority runs', '200 GB storage'],
      ),
    ],
    history: const <V2BillingHistoryEntry>[
      V2BillingHistoryEntry(
        id: 'h1',
        title: 'Ovid Plus · monthly',
        dateLabel: '12 Oct 2026',
        amountLabel: '₹1,499',
      ),
      V2BillingHistoryEntry(
        id: 'h2',
        title: 'Ovid Go · monthly',
        dateLabel: '12 Sep 2026',
        amountLabel: '₹399',
      ),
    ],
  );
}

/// Seven days of use on the Plus plan.
V2UsageData previewUsageData() {
  return V2UsageData(
    planId: 'plus',
    dailyUsedLabel: '8.2M',
    dailyLimitLabel: '20M',
    dailyFraction: 0.41,
    dailyCapLabel: '20M tokens a day',
    resetLabel: 'Resets in 6h',
    monthlyUsedLabel: '44M',
    monthlyLimitLabel: '200M',
    monthlyFraction: 0.22,
    monthlyPercentLabel: '22% of the month',
    monthlyCapLabel: '200M tokens a month',
    billingNote: 'Renews on 12 Nov',
    requestsLabel: '128',
    imagesLabel: '36',
    storageUsedLabel: '6.2 GB',
    storageLimitLabel: '15 GB',
    storageFraction: 0.41,
    showFreePlanNote: false,
    days: const <V2UsageDay>[
      V2UsageDay(id: 'mon', label: 'Mon', fraction: 0.42, valueLabel: '4.2M'),
      V2UsageDay(id: 'tue', label: 'Tue', fraction: 0.68, valueLabel: '6.8M'),
      V2UsageDay(id: 'wed', label: 'Wed', fraction: 0.21, valueLabel: '2.1M'),
      V2UsageDay(id: 'thu', label: 'Thu', fraction: 0.94, valueLabel: '9.4M'),
      V2UsageDay(id: 'fri', label: 'Fri', fraction: 0.77, valueLabel: '7.7M'),
      V2UsageDay(id: 'sat', label: 'Sat', fraction: 0.52, valueLabel: '5.2M'),
      V2UsageDay(id: 'sun', label: 'Sun', fraction: 0.89, valueLabel: '8.9M'),
    ],
    models: const <V2UsageModel>[
      V2UsageModel(
        id: 'auto',
        name: 'Auto',
        subtitle: 'Smart routing',
        percent: 52,
        tokensLabel: '22.8M tokens',
      ),
      V2UsageModel(
        id: 'pro',
        name: 'Ovid 2 Pro',
        subtitle: 'Hard reasoning',
        percent: 28,
        tokensLabel: '12.3M tokens',
        tone: V2UsageTone.success,
      ),
      V2UsageModel(
        id: 'flash',
        name: 'Ovid 2 Flash',
        subtitle: 'Fast answers',
        percent: 20,
        tokensLabel: '8.8M tokens',
        tone: V2UsageTone.warn,
      ),
    ],
  );
}

/// A signed-in account with two linked providers and a data-control route.
V2AccountData previewAccountData() {
  return V2AccountData(
    profile: const V2AccountProfile(
      name: 'Aarav Sharma',
      email: 'aarav@gmail.com',
      role: 'Plus',
      initials: 'AS',
    ),
    fields: const <V2AccountField>[
      V2AccountField(
        id: 'display_name',
        label: 'Display name',
        value: 'Aarav Sharma',
        editable: true,
      ),
      V2AccountField(
        id: 'email',
        label: 'Email',
        value: 'aarav@gmail.com',
        verified: true,
      ),
    ],
    connectedAccounts: const <V2ConnectedAccount>[
      V2ConnectedAccount(
        id: 'google',
        name: 'Google',
        detail: 'aarav@gmail.com',
      ),
      V2ConnectedAccount(id: 'github', name: 'GitHub', detail: '@aarav'),
    ],
    onEditProfile: () {},
    onDataControl: () {},
    onLinkAccount: () {},
    onSignOut: () {},
    onDeleteAccount: () {},
  );
}

/// The hub's data-control destination: measured total, real chat rows and the
/// account contact the delete confirmation names.
V2DataControlPageData previewDataControlData() {
  return V2DataControlPageData(
    totalDataSizeLabel: '1.2 GB across 42 chats',
    exportSessions: const <V2ExportSession>[
      V2ExportSession(
        id: 'auth-refresh',
        name: 'Auth refresh',
        sizeBytes: 3_100_000,
        sizeLabel: '3.1 MB',
        detail: '180 messages',
      ),
      V2ExportSession(
        id: 'design-review',
        name: 'Design review',
        sizeBytes: 1_800_000,
        sizeLabel: '1.8 MB',
        detail: '64 messages',
        selected: false,
      ),
    ],
    hasData: true,
    accountContact: 'aarav@gmail.com',
    onExport: () {},
    onChooseImport: () {},
    onDeleteData: () {},
    onExportSessionToggled: (_, _) {},
    onRetry: () {},
  );
}

/// Personalization with a real theme, text size and voice choice.
V2AppearancePageData previewAppearanceData() {
  return V2AppearancePageData(
    themeMode: ThemeMode.dark,
    textScale: 1.1,
    voiceLanguageId: 'hinglish',
    memoryEnabled: true,
    shareSessionMemory: false,
    showReasoning: true,
    onThemeModeChanged: (_) {},
    onTextScaleChanged: (_) {},
    onVoiceLanguageChanged: (_) {},
    onMemoryEnabledChanged: (_) {},
    onShareSessionMemoryChanged: (_) {},
    onShowReasoningChanged: (_) {},
    onMemoryFilesTap: () {},
  );
}

/// The shipped build plus the three legal documents.
V2AboutPageData previewAboutData() {
  return V2AboutPageData(
    onCopyVersion: () {},
    onPrivacyPolicy: () {},
    onTerms: () {},
    onContactSupport: () {},
    onDeleteAccount: () {},
  );
}

/// Notification channels the product can actually honour: the two run
/// channels are live; shares, collaboration, sign-ins and billing are marked
/// unavailable because no backend channel exists for them.
V2NotificationsPageData previewNotificationsData() {
  return V2NotificationsPageData(
    masterEnabled: true,
    activity: const <V2NotificationSetting>[
      V2NotificationSetting(
        id: 'agent_updates',
        title: 'Run finished',
        description: 'When Ovid completes a task.',
      ),
      V2NotificationSetting(
        id: 'scheduler_results',
        title: 'Schedule results',
        description: 'When a scheduled run finishes.',
      ),
      V2NotificationSetting(
        id: 'shares_invites',
        title: 'Shares and invites',
        description: 'When someone shares a chat or invites you.',
        available: false,
      ),
      V2NotificationSetting(
        id: 'collaboration',
        title: 'Collaboration',
        description: 'New messages in shared chats.',
        available: false,
      ),
    ],
    security: const <V2NotificationSetting>[
      V2NotificationSetting(
        id: 'new_signins',
        title: 'New sign-ins',
        description: 'When a new device signs in.',
        available: false,
      ),
      V2NotificationSetting(
        id: 'billing',
        title: 'Billing',
        description: 'Receipts, plan changes and payment issues.',
        available: false,
      ),
    ],
    sound: true,
    quietHoursEnabled: true,
    quietHoursStart: const TimeOfDay(hour: 22, minute: 0),
    quietHoursEnd: const TimeOfDay(hour: 8, minute: 0),
    sounds: const <V2ChannelSoundSetting>[
      V2ChannelSoundSetting(
        id: 'agent_updates',
        title: 'Agent updates',
        description: 'Runs that finish, need input or approval.',
        value: V2NotificationSound.chime,
      ),
      V2ChannelSoundSetting(
        id: 'scheduler_results',
        title: 'Scheduled results',
        description: 'Scheduled runs that finish or fail.',
        value: V2NotificationSound.chime,
      ),
    ],
    onToggle: (_, _) {},
    onMasterChanged: (_) {},
    onQuietHours: () {},
    onQuietHoursEnabledChanged: (_) {},
    onQuietHoursStartChanged: (_) {},
    onQuietHoursEndChanged: (_) {},
    onSoundChanged: (_, _) {},
    onOpenSystem: () {},
    onRetry: () {},
  );
}

/// The persisted five-minute wait, so the gallery shows the slider instead of
/// its loading skeleton.
V2ResponseWaitPageData previewResponseWaitData() {
  return V2ResponseWaitPageData(seconds: 300, onChanged: (_) async {});
}

/// Memory switched on, with global facts, two projects and a session file.
V2MemoryPageData previewMemoryData() {
  return const V2MemoryPageData(
    memoryEnabled: true,
    globalVersionLabel: 'Version 12 · updated 2h ago',
    globalMemory: <String>[
      'Prefers Dart and Flutter for app work.',
      'Ships on Android first, then web.',
      'Wants short commit messages.',
    ],
    projects: <V2MemoryProject>[
      V2MemoryProject(
        id: 'redesign',
        name: 'Mobile App Redesign',
        detail: '2 files · 14 facts',
      ),
      V2MemoryProject(
        id: 'auth',
        name: 'Auth refactor',
        detail: '1 file · 6 facts',
      ),
    ],
    sessionFiles: <V2MemoryFile>[
      V2MemoryFile(
        id: 'session',
        name: 'This chat',
        detail: '3 facts · saved 10:44',
      ),
    ],
  );
}

/// 6.2 GB of 15 GB with the largest items listed.
V2StoragePageData previewStorageData() {
  return const V2StoragePageData(
    usedGb: 6.2,
    totalGb: 15,
    planName: 'Plus',
    quotaLabel: '6.2 GB of 15 GB',
    artifactsGb: 1.8,
    artifactsSizeLabel: '1.8 GB',
    sessionsGb: 2.3,
    sessionsSizeLabel: '2.3 GB',
    cacheGb: 0.2,
    cacheSizeLabel: '200 MB',
    previewSizeLabel: '220 MB',
    trashItems: 3,
    trashSizeLabel: '48 MB',
    slices: <V2StorageSlice>[
      V2StorageSlice(label: 'Chats', sizeLabel: '2.3 GB', valueGb: 2.3),
      V2StorageSlice(label: 'Artifacts', sizeLabel: '1.8 GB', valueGb: 1.8),
      V2StorageSlice(label: 'Uploads', sizeLabel: '1.1 GB', valueGb: 1.1),
      V2StorageSlice(label: 'Memory', sizeLabel: '600 MB', valueGb: 0.6),
      V2StorageSlice(label: 'Cache', sizeLabel: '200 MB', valueGb: 0.2),
    ],
    largestItems: <V2StorageItem>[
      V2StorageItem(
        id: 'video',
        name: 'demo-recording.mp4',
        detail: 'Uploaded 12 Oct',
        sizeLabel: '820 MB',
        icon: Icons.videocam_outlined,
      ),
      V2StorageItem(
        id: 'archive',
        name: 'design-archive.zip',
        detail: 'Artifact · 8 Oct',
        sizeLabel: '540 MB',
        icon: Icons.folder_zip_outlined,
      ),
      V2StorageItem(
        id: 'chat',
        name: 'Auth refactor',
        detail: '180 messages',
        sizeLabel: '310 MB',
        icon: Icons.chat_bubble_outline_rounded,
      ),
    ],
  );
}

/// Google connected, GitHub connected, one browser login saved.
V2CredentialsPageData previewCredentialsData() {
  return V2CredentialsPageData(
    google: V2Credential(
      id: 'google',
      kind: V2CredentialKind.google,
      title: 'Google',
      subtitle: 'aarav@gmail.com',
    ),
    github: V2Credential(
      id: 'github',
      kind: V2CredentialKind.github,
      title: 'GitHub',
      subtitle: 'aarav · 2 repositories',
    ),
    token: V2Credential(
      id: 'token',
      kind: V2CredentialKind.token,
      title: 'Provider key',
      subtitle: 'Anthropic · added 2 Oct',
    ),
    githubOAuthConnected: true,
    browserCredentials: <V2BrowserCredential>[
      V2BrowserCredential(
        id: 'github-web',
        site: 'github.com',
        username: 'aarav',
        password: '••••••••',
      ),
    ],
    onDeleteBrowserCredential: (_) {},
    onRevokeAll: () {},
  );
}

/// A healthy account with one day of real-looking usage.
V2AccountHealthPageData previewAccountHealthPageData() {
  return V2AccountHealthPageData(
    planLabel: 'Plus',
    accountStatus: V2AccountStatus.active,
    todayUsageLabel: '8.2K tokens',
    todayUsageFraction: 0.16,
    storageUsedLabel: '1.2 GB of 15 GB',
    storageFraction: 0.08,
    onOpenPlans: () {},
    onOpenStorage: () {},
  );
}

/// The five built-in presets plus one custom, with the wait and access mode
/// the editor records.
V2AgentPresetsPageData previewPresetsData() {
  return V2AgentPresetsPageData(
    selectedId: 'code',
    models: <V2PresetModelOption>[
      V2PresetModelOption(id: 'auto', label: 'Auto'),
      V2PresetModelOption(id: 'ovid-2-pro', label: 'Ovid 2 Pro'),
      V2PresetModelOption(id: 'ovid-2-flash', label: 'Ovid 2 Flash'),
    ],
    presets: <V2AgentPreset>[
      V2AgentPreset(
        id: 'standard',
        name: 'Standard',
        description: 'Full tool roster — the default Ovid agent.',
        modelLabel: 'Auto',
        builtIn: true,
        responseWaitSeconds: 300,
        permissionModeId: 'auto',
      ),
      V2AgentPreset(
        id: 'minimal',
        name: 'Minimal',
        description: 'Chat + files + search + memory — no browser or images.',
        modelLabel: 'Auto',
        builtIn: true,
        responseWaitSeconds: 120,
        permissionModeId: 'safe',
      ),
      V2AgentPreset(
        id: 'studio',
        name: 'Studio',
        description: 'Authoring preset — images, web research and files.',
        modelLabel: 'Ovid 2 Pro',
        builtIn: true,
        icon: Icons.palette_outlined,
        responseWaitSeconds: 600,
        permissionModeId: 'studio',
      ),
      V2AgentPreset(
        id: 'code',
        name: 'Code',
        description: 'Repo work — shell, file edits and git.',
        modelLabel: 'Ovid 2 Pro',
        builtIn: true,
        icon: Icons.code_rounded,
        responseWaitSeconds: 300,
        permissionModeId: 'drive',
      ),
      V2AgentPreset(
        id: 'plan',
        name: 'Plan',
        description: 'Read-only planning — research, then propose.',
        modelLabel: 'Auto',
        builtIn: true,
        icon: Icons.alt_route_rounded,
        responseWaitSeconds: 300,
        permissionModeId: 'safe',
      ),
      V2AgentPreset(
        id: 'custom-release',
        name: 'Release notes',
        description: 'Turns merged pull requests into a changelog.',
        modelLabel: 'Ovid 2 Pro',
        modelId: 'ovid-2-pro',
        responseWaitSeconds: 300,
        permissionModeId: 'auto',
      ),
    ],
    onApply: (_) async {},
    onCreatePreset: (_) async {},
    onUpdatePreset: (_, _) async {},
    onDeletePreset: (_) async {},
  );
}

/// The two permissions the manifest declares, with honest OS states.
V2PermissionsPageData previewPermissionsData() {
  return const V2PermissionsPageData(
    permissions: <V2PermissionItem>[
      V2PermissionItem(
        id: 'microphone',
        name: 'Microphone',
        reason: 'Voice input in Hindi, Hinglish, Punjabi and Tamil.',
        status: V2PermissionAccess.granted,
        icon: Icons.mic_none_rounded,
      ),
      V2PermissionItem(
        id: 'notifications',
        name: 'Notifications',
        reason: 'Tell you when a long run finishes.',
        status: V2PermissionAccess.denied,
        icon: Icons.notifications_outlined,
      ),
    ],
  );
}

/// Four memory files across the three scopes.
V2MemoryFilesPageData previewMemoryFilesData() {
  return const V2MemoryFilesPageData(
    totalSizeLabel: '18 KB',
    files: <V2MemoryFileEntry>[
      V2MemoryFileEntry(
        id: 'global',
        name: 'global.md',
        group: V2MemoryFileGroup.global,
        sizeLabel: '6 KB',
        updatedLabel: 'Updated 2h ago',
        preview: 'Prefers Dart and Flutter. Ships Android first.',
        content: 'Prefers Dart and Flutter. Ships Android first.',
      ),
      V2MemoryFileEntry(
        id: 'brand',
        name: 'brand.md',
        group: V2MemoryFileGroup.project,
        sizeLabel: '12 KB',
        updatedLabel: 'Updated 2h ago',
        preview: 'Primary colour is violet. Headings use Inter.',
        content: 'Primary colour is violet. Headings use Inter.',
      ),
      V2MemoryFileEntry(
        id: 'decisions',
        name: 'decisions.md',
        group: V2MemoryFileGroup.project,
        sizeLabel: '4 KB',
        updatedLabel: 'Updated yesterday',
        preview: 'Use the Go plan for the first team rollout.',
        content: 'Use the Go plan for the first team rollout.',
      ),
      V2MemoryFileEntry(
        id: 'session',
        name: 'auth-refresh.md',
        group: V2MemoryFileGroup.session,
        sizeLabel: '2 KB',
        updatedLabel: 'Saved 10:44',
        preview: 'Retry the token refresh once before failing.',
        content: 'Retry the token refresh once before failing.',
      ),
    ],
  );
}

/// A live sandbox preview in its honest "nothing to show yet" state.
///
/// The preview screen never paints a fake page: the demo frame carries a real
/// URL and deadline, and the frame itself is supplied by the sandbox at
/// runtime. A gallery preview therefore shows the connecting state, which is
/// exactly what a user sees for the first second of a real preview.
V2LivePreviewData previewLivePreviewData() {
  return V2LivePreviewData(
    status: V2PreviewStatus.connecting,
    siteName: 'Ovid Studio',
    url: 'https://preview.ovidsi.com/79f9b4c0e',
    expiresAt: DateTime(2026, 10, 28),
    unavailableReason:
        'The sandbox has not sent a frame yet. It usually appears in a second.',
  );
}

/// Three agent-owned tabs with a live address.
V2BrowserData previewBrowserData() {
  return V2BrowserData(
    tabs: const <V2BrowserTab>[
      V2BrowserTab(id: 'docs', title: 'Ovid docs', host: 'docs.ovidsi.com'),
      V2BrowserTab(id: 'github', title: 'PR #214 · GitHub', host: 'github.com'),
      V2BrowserTab(
        id: 'news',
        title: 'Hacker News',
        host: 'news.ycombinator.com',
        headless: true,
      ),
    ],
    activeTabId: 'github',
    address: 'github.com/aarav/ovid-app/pull/214',
    cursor: previewViewportCursor(),
    canGoBack: true,
  );
}

/// A connected GitHub connector with permissions, tools and activity.
connector_detail.V2ConnectorDetailData previewConnectorDetailData() {
  return const connector_detail.V2ConnectorDetailData(
    id: 'github',
    name: 'GitHub',
    description: 'Repositories, issues and pull requests.',
    icon: Icons.hub_outlined,
    connected: true,
    endpoint: 'https://api.github.com',
    accountLabel: 'aarav@gmail.com',
    syncedLabel: 'Synced 2m ago',
    accessLabel: '2 of 3 permissions granted',
    authLabel: 'OAuth',
    permissions: <connector_detail.V2ConnectorPermission>[
      connector_detail.V2ConnectorPermission(
        id: 'repo-read',
        name: 'Read repositories',
        description: 'Clone a repo and read its files and branches.',
      ),
      connector_detail.V2ConnectorPermission(
        id: 'pr-write',
        name: 'Write pull requests',
        description: 'Open, comment on and merge pull requests.',
        scope: connector_detail.V2ConnectorPermissionScope.write,
        risk: connector_detail.V2ConnectorPermissionRisk.medium,
      ),
      connector_detail.V2ConnectorPermission(
        id: 'admin',
        name: 'Manage the organisation',
        description: 'Change repository settings, secrets and access.',
        granted: false,
        scope: connector_detail.V2ConnectorPermissionScope.admin,
        risk: connector_detail.V2ConnectorPermissionRisk.high,
      ),
    ],
    tools: <connector_detail.V2ConnectorTool>[
      connector_detail.V2ConnectorTool(
        id: 'repo_clone',
        name: 'Clone repository',
      ),
      connector_detail.V2ConnectorTool(
        id: 'pr_open',
        name: 'Open pull request',
        description: 'Create a pull request with the agent changes.',
        write: true,
      ),
    ],
    agents: <connector_detail.V2ConnectorAgent>[
      connector_detail.V2ConnectorAgent(
        id: 'coder',
        name: 'Coder',
        description: 'Uses GitHub to read the repo it edits.',
        accessLabel: 'Read only',
      ),
    ],
    activity: <connector_detail.V2ConnectorActivity>[
      connector_detail.V2ConnectorActivity(
        id: 'a1',
        title: 'Opened PR #214',
        detail: 'Refresh the hero and tighten spacing',
        timeLabel: '2h ago',
      ),
      connector_detail.V2ConnectorActivity(
        id: 'a2',
        title: 'Cloned ovid-app',
        timeLabel: 'Yesterday',
      ),
      connector_detail.V2ConnectorActivity(
        id: 'a3',
        title: 'Token refresh failed',
        detail: 'Retried automatically and succeeded.',
        timeLabel: '2 days ago',
        ok: false,
      ),
    ],
    safetyNote: 'Revoking a permission stops its tools immediately.',
    disconnectNote: 'Disconnecting removes the token from this device.',
  );
}

/// The workspace tree for the Studio preview.
List<V2FileNode> previewStudioFileNodes() {
  return const <V2FileNode>[
    V2FileNode(
      name: 'lib',
      children: <V2FileNode>[
        V2FileNode(
          name: 'core',
          children: <V2FileNode>[
            V2FileNode(
              name: 'auth_service.dart',
              path: 'lib/core/auth_service.dart',
              changed: true,
            ),
            V2FileNode(
              name: 'auth_guard.dart',
              path: 'lib/core/auth_guard.dart',
            ),
          ],
        ),
        V2FileNode(
          name: 'ui',
          children: <V2FileNode>[
            V2FileNode(
              name: 'theme.dart',
              path: 'lib/ui/theme.dart',
              changed: true,
            ),
          ],
        ),
      ],
    ),
    V2FileNode(name: 'pubspec.yaml', path: 'pubspec.yaml', changed: true),
  ];
}

/// The open file in the Studio preview.
List<V2CodeLine> previewStudioCodeLines() {
  return const <V2CodeLine>[
    V2CodeLine(number: 12, text: 'class AuthService {'),
    V2CodeLine(number: 13, text: '  Future<void> signIn(String email) async {'),
    V2CodeLine(number: 14, text: '    await _guard.requireRecentAuth();'),
    V2CodeLine(number: 15, text: '    return _session.open(email);'),
    V2CodeLine(number: 16, text: '  }'),
    V2CodeLine(number: 17, text: '}'),
  ];
}
