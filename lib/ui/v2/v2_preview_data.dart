import 'package:flutter/material.dart';

import 'browser/tab_strip.dart';
import 'browser/viewport.dart';
import 'chat/composer_plus_sheet.dart';
import 'chat/permission_sheet.dart';
import 'collab/collab_members_page.dart';
import 'collab/turn_banner.dart';
import 'connectors/connector_permissions.dart';
import 'library/artifact_filters.dart';
import 'library/artifact_preview.dart';
import 'onboarding/phone_auth_sheet.dart';
import 'onboarding/purchase_banner.dart';
import 'onboarding/step_progress.dart';
import 'runs/subagent_summary.dart';
import 'runs/timeline.dart';
import 'schedules/cadence_picker.dart';
import 'schedules/run_timeline.dart';
import 'settings/confirm_typed_sheet.dart';
import 'settings/export_picker_sheet.dart';
import 'settings/plan_compare_table.dart';
import 'chat/model_picker_sheet.dart';
import 'settings/settings_hub.dart';
import 'settings/settings_search.dart';
import 'settings/storage_breakdown.dart';
import 'settings/usage_charts.dart';
import 'settings_extra/shared_memory_page.dart';
import 'settings_extra/legal_page.dart';
import 'share/share_link_card.dart';
import 'share/share_sheet.dart';
import 'sidebar/project_detail_page.dart';
import 'sidebar/project_memory_editor.dart';
import 'states/state_tiles.dart';
import 'studio/code_viewer.dart';
import 'studio/commit_sheet.dart';
import 'studio/file_tree.dart';

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
          'Profile, email and region',
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
          '49 apps · 60 plugins and MCP',
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
          'Camera, microphone and files',
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
          'Security and devices',
        ),
        row(
          'about',
          'About',
          Icons.info_outline_rounded,
          'Version, legal and support',
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
      title: 'Read the brief and plan the change',
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
