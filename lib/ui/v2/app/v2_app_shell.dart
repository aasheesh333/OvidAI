import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/chat_integration_ports.dart';
import '../../../core/chat_pins.dart';
import '../../../core/cloud/cloud_agent_facade.dart';
import '../../../core/cloud/cloud_session_store.dart';
import '../../../core/cloud/models.dart';
import '../../../core/cloud/projects.dart';
import '../../../core/cloud_usage_store.dart';
import '../../../core/composer_drafts.dart';
import '../../../core/conversation_share_service.dart';
import '../../../core/connection_service.dart';
import '../../../core/diag.dart';
import '../../../core/firebase_service.dart';
import '../../../core/format.dart';
import '../../../core/native_share.dart';
import '../../../core/ovid_cloud_service.dart';
import '../../../core/state.dart';
import '../../../core/voice_reply_service.dart';
import '../../design/o_tokens.dart';
import '../chat/composer_mentions.dart';
import '../chat/composer_voice.dart';
import '../chat/chat_page.dart';
import '../chat/composer_attachments.dart';
import '../chat/live_chat_page.dart';
import '../chat/model_picker_sheet.dart';
import '../chat/permission_sheet.dart';
import '../chat/transcript_actions.dart';
import '../chat/transcript_tiles.dart';
import '../../design/o_components.dart';
import '../settings/settings_hub.dart';
import '../sidebar/project_detail_page.dart';
import '../sidebar/projects_page.dart';
import '../share/share_sheet.dart';
import '../sidebar/session_actions_sheet.dart';
import '../sidebar/sidebar.dart';
import 'bottom_nav.dart';
import 'mention_source_live.dart';
import 'v2_settings_actions.dart';
import 'v2_work_routes.dart';
import 'v2_run_routes.dart';
import 'v2_settings_routes.dart';
import 'v2_studio_routes.dart';

/// Production host for the rebuilt UI. It owns the live session, the drawer,
/// and the chat transcript; every child screen stays presentational.
///
/// This shell is mounted only when `OVID_UI_V2=true` until the parity gate
/// passes. The legacy `OvidShell` remains the default.
class V2AppShell extends StatefulWidget {
  const V2AppShell({super.key});

  @override
  State<V2AppShell> createState() => _V2AppShellState();
}

class _V2AppShellState extends State<V2AppShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _navKey = GlobalKey<NavigatorState>();
  final _tabObserver = _V2TabObserver();
  late final CloudUsageStore _usage;
  late final V2SettingsActions _settings;
  late final Listenable _listenable;
  final Map<String, ConversationShare> _activeShares = {};

  /// The build context of the home route inside [_navKey]. Route pushes go
  /// through this context so the bottom bar stays mounted above every
  /// destination.
  BuildContext? _routeContext;

  @override
  void initState() {
    super.initState();
    _usage = CloudUsageStore.acquire(AppState.I);
    _settings = V2SettingsActions(_usage);
    _listenable = Listenable.merge([
      AppState.I,
      CloudAgentFacade.I,
      ChatPinsStore.I,
      ProjectsController.I,
      ConnectionService.I,
      _usage,
    ]);
    v2DefaultMentionSource = const V2AppMentionSource();
    // `@` refs travel to the gateway as server session ids; local ids are not
    // valid there.
    v2SessionRefResolver = (localId) =>
        CloudSessionStore.I.knownServerIdFor(localId) ?? localId;
    v2SavedVoiceLanguage = AppState.I.voiceLanguage;
    unawaited(ChatPinsStore.I.bindCurrentAccount());
    unawaited(
      ComposerDraftStore.I.load().then((_) {
        if (mounted) setState(() {});
      }),
    );
    unawaited(ProjectsController.I.refresh());
  }

  @override
  void dispose() {
    _tabObserver.current.dispose();
    _usage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _listenable,
      builder: (context, _) {
        final app = AppState.I;
        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: OColors.of(context).bg,
          drawer: Drawer(
            width: 340,
            backgroundColor: OColors.of(context).surface,
            child: Sidebar(
              data: _sidebarData(app),
              onProfile: _openSettings,
              onNewChat: () => _newChat(),
              onNewProject: () => _openProjects(context),
              onProjectTap: _openProject,
              onProjectMemory: _openProject,
              onSessionTap: (row) => _selectSession(row.id),
              onSessionActions: (row) => _showSessionActions(context, row.id),
              onSessionLongPress: (row) => _showSessionActions(context, row.id),
              onSchedule: () => _withTab(
                V2NavTab.chat,
                () => V2WorkRoutes.openSchedules(context, _settings),
              ),
              onArtifacts: () => _withTab(
                V2NavTab.library,
                () => V2WorkRoutes.openArtifacts(context, _settings),
              ),
              onSettings: _openSettings,
              onRetry: _reloadSidebar,
            ),
          ),
          // The tabs push onto this nested navigator so the bar stays
          // mounted; the handler gives the system back gesture to the nested
          // stack first, and only exits the app from the home route.
          body: NavigatorPopHandler(
            onPopWithResult: (_) => _navKey.currentState?.maybePop(),
            child: Navigator(
              key: _navKey,
              observers: [_tabObserver],
              onGenerateRoute: (settings) => MaterialPageRoute<void>(
                settings: settings,
                builder: (routeContext) {
                  _routeContext = routeContext;
                  return _homeBody(routeContext);
                },
              ),
            ),
          ),
          bottomNavigationBar: ValueListenableBuilder<V2NavTab>(
            valueListenable: _tabObserver.current,
            builder: (context, tab, _) => V2BottomNav(
              current: tab,
              items: v2WorkNavItems,
              onSelect: _selectTab,
            ),
          ),
        );
      },
    );
  }

  // ── Navigation ──────────────────────────────────────────────────────────

  /// The chat surface, rebuilt on its own so a route created before the first
  /// message still switches to the live transcript once a run starts.
  Widget _homeBody(BuildContext routeContext) {
    return ListenableBuilder(
      listenable: _listenable,
      builder: (context, _) {
        final app = AppState.I;
        final session = app.activeSession;
        final hasMessages = session != null && session.messages.isNotEmpty;
        if (!hasMessages) {
          return V2ChatPage(
            key: ValueKey('empty-${session?.id ?? 'new'}'),
            data: _chatData(app),
            onMenu: _openDrawer,
            onModelChipTap: () => _openModelPicker(routeContext),
            onStudio: () => V2WorkRoutes.openStudio(_navContext, _settings),
            onBrowser: () => V2WorkRoutes.openBrowser(_navContext, _settings),
            onMore: session == null
                ? null
                : () => _chatMenu(routeContext, session.id),
            onSubmit: _submit,
            onStop: _stop,
            onSendQueuedNow: _sendQueuedNow,
            onDismissQueued: () => _dismissQueued(app.activeSessionId),
            onPermissionTap: () =>
                unawaited(_openPermissionSheet(routeContext)),
            onRetry: _retry,
            onSeePlans: () =>
                V2SettingsRoutes.open(_navContext, 'plan_billing', _settings),
            onDraftChanged: (text) {
              final id = AppState.I.activeSessionId;
              if (id != null) ComposerDraftStore.I.put(id, text);
            },
          );
        }
        return V2LiveChatPage(
          key: ValueKey('live-${session.id}'),
          data: _liveData(app, session),
          onMenu: _openDrawer,
          onModelChipTap: () => _openModelPicker(routeContext),
          onStudio: () => V2WorkRoutes.openStudio(_navContext, _settings),
          onBrowser: () => V2WorkRoutes.openBrowser(_navContext, _settings),
          onMore: () => _chatMenu(routeContext, session.id),
          onSubmit: _submit,
          onStop: _stop,
          onSendQueuedNow: _sendQueuedNow,
          onDismissQueued: () => _dismissQueued(session.id),
          onDownload: (id) => _download(routeContext, id),
          onArtifactTap: (id) => _openArtifact(routeContext, id),
          onOpenLink: (url) =>
              unawaited(v2OpenTranscriptLink(routeContext, url)),
          onDownloadLink: (url) =>
              unawaited(v2SaveTranscriptLink(routeContext, url)),
          onStartChat: _newChat,
          onRetry: _retry,
          onPermissionTap: () =>
              unawaited(_openPermissionSheet(routeContext)),
          permissionLabel: CloudAgentFacade.I.mode.label,
          voiceService: const V2PlatformVoiceService(),
          voiceLanguage: app.voiceLanguage,
          onVoicePlay: _playVoiceReply,
          onDraftChanged: (text) =>
              ComposerDraftStore.I.put(session.id, text),
        );
      },
    );
  }

  BuildContext get _navContext => _routeContext ?? context;

  /// The one place every tab goes. Chat returns to the transcript; the other
  /// four open their real destination on the shell's navigator so the bar
  /// stays mounted and the selected tab follows the route.
  void _selectTab(V2NavTab tab) {
    if (!mounted) return;
    if (tab != V2NavTab.chat) {
      // Re-tapping a tab replaces its destination instead of stacking a second
      // copy of it.
      _navKey.currentState?.popUntil((route) => route.isFirst);
    }
    switch (tab) {
      case V2NavTab.chat:
        _navKey.currentState?.popUntil((route) => route.isFirst);
      case V2NavTab.studio:
        unawaited(
          _withTab(
            V2NavTab.studio,
            () => V2WorkRoutes.openStudio(_navContext, _settings),
          ),
        );
      case V2NavTab.browser:
        unawaited(
          _withTab(
            V2NavTab.browser,
            () => V2WorkRoutes.openBrowser(_navContext, _settings),
          ),
        );
      case V2NavTab.library:
        unawaited(
          _withTab(
            V2NavTab.library,
            () => V2WorkRoutes.openArtifacts(_navContext, _settings),
          ),
        );
      case V2NavTab.settings:
        unawaited(_withTab(V2NavTab.settings, _openSettings));
    }
  }

  Future<void> _withTab(V2NavTab tab, Future<void> Function() open) async {
    _tabObserver.expect(tab);
    try {
      await open();
    } finally {
      _tabObserver.clearExpectation();
    }
  }

  Future<void> _reloadSidebar() async {
    try {
      await ProjectsController.I.refresh();
    } catch (e) {
      // The sidebar shows its own error state; a retry never throws.
      Diag.swallow('v2.sidebar.projects', e);
    }
    try {
      await ChatPinsStore.I.bindCurrentAccount();
    } catch (e) {
      Diag.swallow('v2.sidebar.pins', e);
    }
    try {
      await CloudSessionStore.I.refreshSessions();
    } catch (e) {
      Diag.swallow('v2.sidebar.sessions', e);
    }
    if (mounted) setState(() {});
  }

  // ── Data mapping ────────────────────────────────────────────────────────

  V2SidebarData _sidebarData(AppState app) {
    final now = DateTime.now();
    final startToday = DateTime(now.year, now.month, now.day);
    final startYesterday = startToday.subtract(const Duration(days: 1));
    final pinned = <V2SidebarSession>[];
    final today = <V2SidebarSession>[];
    final yesterday = <V2SidebarSession>[];
    final earlier = <V2SidebarSession>[];

    for (final session in app.rootSessionsByRecency) {
      final row = _sidebarSession(session);
      if (ChatPinsStore.I.isPinned(session.id)) {
        pinned.add(
          V2SidebarSession(
            id: row.id,
            title: row.title,
            modelLabel: row.modelLabel,
            timeLabel: row.timeLabel,
            pinned: true,
            projectName: row.projectName,
          ),
        );
        continue;
      }
      final at = session.lastActivityAt.toLocal();
      if (!at.isBefore(startToday)) {
        today.add(row);
      } else if (!at.isBefore(startYesterday)) {
        yesterday.add(row);
      } else {
        earlier.add(row);
      }
    }

    return V2SidebarData(
      name: FirebaseService.I.accountLabel,
      initials: _initials(FirebaseService.I.accountLabel),
      planLabel: _planLabel(app.ovidCloudTier),
      pinned: pinned,
      projects: _projects(),
      today: today,
      yesterday: yesterday,
      earlier: earlier,
      status: app.sessions.isEmpty && ProjectsController.I.error != null
          ? V2SidebarStatus.error
          : V2SidebarStatus.content,
      errorMessage: ProjectsController.I.error,
    );
  }

  List<V2SidebarProject> _projects() {
    final controller = ProjectsController.I;
    return [
      for (final project in controller.projects)
        V2SidebarProject(
          id: project.id,
          name: project.name,
          chatCount: project.sessionCount,
          memoryFileCount: project.fileBreakdown.memory,
        ),
    ];
  }

  V2SidebarSession _sidebarSession(ChatSession session) => V2SidebarSession(
    id: session.id,
    title: session.title,
    modelLabel: _modelLabel(session),
    timeLabel: _timeLabel(session.lastActivityAt),
    projectName: session.projectId == null
        ? null
        : ProjectsController.I.byId(session.projectId!)?.name,
  );

  V2ChatPageData _chatData(AppState app) {
    final limited = _planLimited;
    final state = ConnectionService.I.offline
        ? V2ChatState.offline
        : limited
        ? V2ChatState.planLimited
        : V2ChatState.empty;
    final agent = CloudAgentFacade.I;
    final sessionId = app.activeSessionId;
    final queued = sessionId == null
        ? const <String>[]
        : agent.queuedMessagesFor(sessionId);
    return V2ChatPageData(
      title: 'Ovid Si',
      modelLabel: _modelLabel(app.activeSession),
      tokensLabel: _tokensLabel(),
      fastAgentLabel: 'Fast agent',
      sessionId: app.activeSessionId,
      draft: _draftFor(app.activeSessionId),
      state: state,
      queuedCount: sessionId == null ? 0 : agent.queuedCountFor(sessionId),
      queuedPreview: queued.firstOrNull,
      limitResetLabel: _resetLabel(),
      permissionLabel: agent.mode.label,
      composerHint: 'Ask Ovid to do anything...',
      offlineTitle: "You're offline",
      offlineMessage: 'Messages will send when you reconnect.',
    );
  }

  V2LiveChatData _liveData(AppState app, ChatSession session) {
    final agent = CloudAgentFacade.I;
    final running = agent.busyFor(session.id);
    final queued = agent.queuedMessagesFor(session.id);
    // Response-wait watchdog: the same source the legacy transcript reads, so
    // the Settings limit has a visible effect here too.
    final stalled = agent.stalledFor(session.id);
    final status = agent.statusFor(session.id);
    final activity = agent.activityFor(session.id);
    return V2LiveChatData(
      title: 'Ovid Si',
      sessionTitle: session.title,
      modelLabel: _modelLabel(session),
      items: _items(session),
      running: running,
      loading: false,
      statusLabel: stalled
          ? 'Still working…'
          : status != null && status.trim().isNotEmpty
          ? status.trim()
          : activity != null
          ? '$activity…'
          : 'Ovid is working...',
      draft: _draftFor(session.id),
      composerHint: 'Ask Ovid to do anything...',
      queuedCount: agent.queuedCountFor(session.id),
      queuedPreview: queued.firstOrNull,
    );
  }

  List<V2LiveChatItem> _items(ChatSession session) {
    final items = <V2LiveChatItem>[];
    for (final message in session.messages) {
      switch (message.kind) {
        case MsgKind.tool:
          items.add(
            V2LiveTool(
              id: message.privateSyncId,
              title: message.toolTitle ?? message.toolName ?? 'Working',
              status: message.toolState,
              progress: message.toolState == 'running' ? 0.55 : 1,
              icon: _toolIcon(message.toolName),
            ),
          );
        case MsgKind.reasoning:
          items.add(
            V2LiveThinking(
              id: message.privateSyncId,
              label: message.thinking ? 'Thinking' : 'Thought for a moment',
              details: [
                if (message.content.trim().isNotEmpty)
                  message.content.trim()
                else
                  'Working through the request.',
              ],
            ),
          );
        case MsgKind.imageGen:
        case MsgKind.htmlArtifact:
          items.add(
            V2LiveArtifact(
              id: message.privateSyncId,
              fileName: _artifactName(message),
              meta: message.kind == MsgKind.imageGen ? 'Image' : 'Web page',
              statusLabel: _artifactStatus(message),
              previewLabel: 'Tap to open',
              href: _artifactHref(message),
              icon: message.kind == MsgKind.imageGen
                  ? Icons.image_outlined
                  : Icons.code_rounded,
            ),
          );
        case MsgKind.turnTail:
        case MsgKind.compact:
          if (message.content.trim().isNotEmpty) {
            items.add(
              V2LiveAssistantMessage(
                id: message.privateSyncId,
                markdown: message.content,
              ),
            );
          }
        case MsgKind.text:
        case MsgKind.streaming:
          if (message.role == 'user') {
            items.add(
              V2LiveUserMessage(
                id: message.privateSyncId,
                text: message.content,
                timeLabel: _timeLabel(message.time),
              ),
            );
          } else if (message.content.trim().isNotEmpty) {
            items.add(
              V2LiveAssistantMessage(
                id: message.privateSyncId,
                markdown: message.content,
              ),
            );
          }
      }
    }
    return items;
  }

  // ── Actions ─────────────────────────────────────────────────────────────

  void _openDrawer() => _scaffoldKey.currentState?.openDrawer();

  void _openModelPicker(BuildContext context) {
    final app = AppState.I;
    final tier = app.ovidCloudTier;
    final autoOnly = tier == 'free' || tier == '3x';
    final options = <V2ModelOption>[];
    final lookup = <String, ({String providerId, String modelId})>{
      'auto': (providerId: AppState.ovidCloudProviderId, modelId: 'auto'),
    };
    for (final provider in app.providers) {
      if (!provider.connected) continue;
      for (final model in provider.models) {
        if (model == 'auto') continue;
        final id = '${provider.id}::$model';
        lookup[id] = (providerId: provider.id, modelId: model);
        options.add(
          V2ModelOption(
            id: id,
            name: ovidModelLabel(model),
            subtitle: provider.name,
            speed: 'Standard',
            costHint: 'Included',
            locked: autoOnly,
            tag: autoOnly ? 'Paid plans' : null,
          ),
        );
      }
    }
    final current = app.activeSession?.model ?? 'auto';
    var selectedId = 'auto';
    if (current != 'auto') {
      selectedId =
          '${app.activeSession?.providerId ?? AppState.ovidCloudProviderId}::$current';
      if (!lookup.containsKey(selectedId)) selectedId = 'auto';
    }
    unawaited(
      showOSheet<void>(
        context,
        builder: (_) => V2ModelPickerSheet(
          data: V2ModelPickerData(
            models: options,
            selectedId: selectedId,
            planLabel: _planLabel(tier),
            manualModelsAllowed: !autoOnly,
            // TODO(l10n): move the plan gate copy to ARB keys.
            upgradeHint: autoOnly
                ? 'Manual models need Plus or Pro. ${_planLabel(tier)} '
                      'includes Auto and every subagent.'
                : 'Every model is included on your plan.',
            freePlanNote: autoOnly
                ? '${_planLabel(tier)} uses Auto only.'
                : 'All models are available on your plan.',
          ),
          onSelect: (id) {
            final target = lookup[id];
            if (target == null) return;
            if (autoOnly && target.modelId != 'auto') return;
            app.setModel(target.providerId, target.modelId);
            Navigator.of(context).pop();
          },
          onManageModels: () {
            Navigator.of(context).pop();
            _openSettings();
          },
        ),
      ),
    );
  }

  void _newChat() {
    _scaffoldKey.currentState?.closeDrawer();
    AppState.I.newSession();
  }

  void _selectSession(String id) {
    AppState.I.selectSession(id);
    CloudAgentFacade.I.activateSession(id);
    _scaffoldKey.currentState?.closeDrawer();
  }

  Future<void> _submit(V2ComposerSubmission submission) async {
    final text = submission.text.trim();
    if (submission.isEmpty) return;
    final app = AppState.I;
    if (app.activeSessionId == null) app.newSession();
    final id = app.activeSessionId;
    if (id == null) return;
    ComposerDraftStore.I.remove(id);
    final attachments = <({String name, String path, int size})>[
      for (final file in submission.attachments)
        if (file.isReadable)
          (name: file.name, path: file.path, size: file.size),
    ];
    await CloudAgentFacade.I.runTask(
      text,
      sessionId: id,
      attachments: attachments.isEmpty ? null : attachments,
      sessionRefs: submission.sessionRefs,
      projectRefs: submission.projectRefs,
    );
  }

  void _stop() {
    final id = AppState.I.activeSessionId;
    if (id == null) return;
    CloudAgentFacade.I.stopRequested(sessionId: id, dispatchQueued: true);
  }

  /// "Send now" on the queue dock: cancel the active turn and dispatch the
  /// queued head immediately. Dispatched subagents keep running.
  void _sendQueuedNow() {
    final id = AppState.I.activeSessionId;
    if (id == null) return;
    CloudAgentFacade.I.stopRequested(sessionId: id, dispatchQueued: true);
  }

  /// Dismiss removes only the first queued row, by its stable id.
  void _dismissQueued(String? sessionId) {
    if (sessionId == null) return;
    final ids = CloudAgentFacade.I.queuedMessageIdsFor(sessionId);
    if (ids.isEmpty) return;
    CloudAgentFacade.I.removeQueuedMessageById(ids.first);
  }

  void _retry() {
    final id = AppState.I.activeSessionId;
    if (id == null) return;
    CloudAgentFacade.I.retryLastPrompt(id);
  }

  Future<void> _openPermissionSheet(BuildContext context) {
    final agent = CloudAgentFacade.I;
    return showV2PermissionSheet(
      context,
      data: V2PermissionSheetData(selectedId: agent.mode.name),
      onSelect: (id) {
        for (final mode in AgentMode.values) {
          if (mode.name == id) {
            agent.setMode(mode);
            return;
          }
        }
      },
    );
  }

  Future<void> _chatMenu(BuildContext context, String id) async {
    final navContext = _navContext;
    final session = AppState.I.sessionById(id);
    if (session == null) return;
    final bound = StudioBindingPort.instance?.bindingFor(id);
    final studioRepo = (session.repo?.trim().isNotEmpty ?? false)
        ? session.repo!
        : (bound?.ready == true ? bound!.repo : null);
    final action = await showOSheet<String>(
      context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            OListRow(
              title: 'Chat actions',
              subtitle: 'Pin, rename, move, export or delete',
              icon: Icons.tune_rounded,
              showChevron: false,
              onTap: () => Navigator.pop(sheetContext, 'actions'),
            ),
            OListRow(
              title: 'Run details',
              subtitle: 'Steps, tools and token usage',
              icon: Icons.route_outlined,
              showChevron: false,
              onTap: () => Navigator.pop(sheetContext, 'run'),
            ),
            if (studioRepo != null)
              OListRow(
                title: 'Open Studio',
                subtitle: studioRepo,
                icon: Icons.code_rounded,
                showChevron: false,
                onTap: () => Navigator.pop(sheetContext, 'studio'),
              ),
            OListRow(
              title: 'Share chat',
              icon: Icons.share_outlined,
              showChevron: false,
              onTap: () => Navigator.pop(sheetContext, 'share'),
            ),
            const SizedBox(height: OSpace.s),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'actions':
        await _showSessionActions(context, id);
      case 'run':
        await V2RunRoutes.openTrajectory(context, id);
      case 'studio':
        // The port owns the real repo/branch binding; without one there is no
        // workspace to open, so the picker is the honest destination.
        final binding = StudioBindingPort.instance?.bindingFor(id);
        if (binding == null || !binding.ready) {
          await V2WorkRoutes.openStudio(navContext, _settings);
        } else {
          await V2StudioRoutes.openWorkspace(
            navContext,
            binding.repo,
            binding.branch,
            sessionId: id,
          );
        }
      case 'share':
        await _shareChat(context, id);
    }
  }

  Future<void> _showSessionActions(BuildContext context, String id) async {
    final session = AppState.I.sessionById(id);
    if (session == null) return;
    await showSessionActionsSheet(
      context,
      data: V2SessionActionsData(
        title: session.title,
        modelLabel: _modelLabel(session),
        timeLabel: _timeLabel(session.lastActivityAt),
        messageCount: session.messages.length,
        projectName: session.projectId == null
            ? null
            : ProjectsController.I.byId(session.projectId!)?.name,
        pinned: ChatPinsStore.I.isPinned(id),
      ),
      onTogglePin: (value) => unawaited(ChatPinsStore.I.setPinned(id, value)),
      onRename: () => _rename(id),
      onMoveToProject: () => _moveToProject(context, id),
      onShare: () => _shareChat(context, id),
      onDuplicate: () => _duplicateChat(context, id),
      onExportMarkdown: () => _copyMarkdown(context, id),
      onDelete: () => _delete(id),
    );
  }

  Future<void> _moveToProject(BuildContext context, String id) async {
    final projects = ProjectsController.I.projects;
    if (projects.isEmpty) {
      _snack(context, 'Create a project first, then move this chat into it.');
      return;
    }
    final session = AppState.I.sessionById(id);
    final chosen = await showOSheet<String?>(
      context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(OSpace.l),
              child: Text('Move to project'),
            ),
            OListRow(
              title: 'No project',
              subtitle: 'Keep this chat on its own',
              icon: Icons.folder_off_outlined,
              trailing: session?.projectId == null
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () => Navigator.pop(sheetContext, ''),
            ),
            for (final project in projects)
              OListRow(
                title: project.name,
                subtitle:
                    '${project.sessionCount} ${project.sessionCount == 1 ? 'chat' : 'chats'}',
                icon: Icons.folder_outlined,
                trailing: session?.projectId == project.id
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(sheetContext, project.id),
              ),
            const SizedBox(height: OSpace.s),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    await ProjectsController.I.moveSession(id, chosen.isEmpty ? null : chosen);
  }

  Future<void> _shareChat(BuildContext context, String id) async {
    final session = AppState.I.sessionById(id);
    if (session == null) return;
    final snapshot = ConversationSnapshot.fromSession(session);
    if (!snapshot.withinLimits) {
      _snack(
        context,
        'This chat is too large to share. Share a shorter conversation.',
      );
      return;
    }
    String? link;
    try {
      final share = await ConversationShareService.production().create(
        snapshot,
        requestId: 'v2-${DateTime.now().microsecondsSinceEpoch}',
      );
      _activeShares[id] = share;
      link = share.url.toString();
    } catch (_) {
      link = null;
    }
    if (!context.mounted) return;
    await showShareSheet(
      context,
      data: V2ShareSheetData(
        link: link ?? '',
        creatorName: FirebaseService.I.accountLabel,
        status: link == null ? V2ShareStatus.error : V2ShareStatus.ready,
        errorMessage: 'We could not create a share link. Try again.',
      ),
      onCopyLink: () {
        if (link == null) return;
        unawaited(Clipboard.setData(ClipboardData(text: link)));
        _snack(context, 'Link copied.');
      },
      onShareTarget: (target) {
        if (link == null) return;
        final text = Uri.encodeComponent('${session.title}\n$link');
        final url = switch (target) {
          V2ShareTarget.whatsApp => 'https://wa.me/?text=$text',
          V2ShareTarget.gmail =>
            'mailto:?subject=${Uri.encodeComponent(session.title)}&body=$text',
          V2ShareTarget.slack =>
            'https://slack.com/openid/connect/authorize?$text',
          V2ShareTarget.more => null,
        };
        if (url == null) {
          unawaited(Clipboard.setData(ClipboardData(text: link)));
          _snack(context, 'Link copied.');
          return;
        }
        unawaited(
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        );
      },
      onStopSharing: () async {
        final share = _activeShares.remove(id);
        if (share == null) return;
        try {
          await ConversationShareService.production().revoke(share.id);
          if (context.mounted) _snack(context, 'Link revoked.');
        } catch (_) {
          if (context.mounted) _snack(context, 'Could not revoke the link.');
        }
      },
      onRetry: () => _shareChat(context, id),
    );
  }

  void _duplicateChat(BuildContext context, String id) {
    final copy = AppState.I.duplicateSession(id);
    if (copy == null) return;
    _snack(context, 'Branched into “${copy.title}”.');
  }

  Future<void> _copyMarkdown(BuildContext context, String id) async {
    final session = AppState.I.sessionById(id);
    if (session == null) return;
    final buffer = StringBuffer('# ${session.title}\n\n');
    for (final message in session.messages) {
      if (message.kind != MsgKind.text && message.kind != MsgKind.streaming) {
        continue;
      }
      if (message.content.trim().isEmpty) continue;
      buffer.writeln(message.role == 'user' ? '## You\n\n' : '## Ovid Si\n\n');
      buffer.writeln('${message.content.trim()}\n');
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (context.mounted) _snack(context, 'Markdown copied.');
  }

  /// Opens an artifact from the transcript by its message id.
  Future<void> _openArtifact(BuildContext context, String id) async {
    final message = _messageById(id);
    if (message == null) return;
    final url = _artifactHref(message);
    if (url != null) {
      await v2OpenTranscriptLink(context, url);
      return;
    }
    if (!context.mounted) return;
    await openV2ArtifactDetail(
      context,
      fileName: _artifactName(message),
      meta: message.kind == MsgKind.imageGen ? 'Image' : 'Web page',
      statusLabel: _artifactStatus(message),
      previewLabel: 'Tap to open',
      icon: message.kind == MsgKind.imageGen
          ? Icons.image_outlined
          : Icons.code_rounded,
    );
  }

  /// Downloads the artifact whose message id was tapped.
  Future<void> _download(BuildContext context, String id) async {
    final message = _messageById(id);
    if (message == null) {
      if (context.mounted) _snack(context, 'Nothing to download yet.');
      return;
    }
    final url = message.imageUrl;
    if (url != null && url.isNotEmpty) {
      startV2ArtifactDownload(
        context,
        url,
        suggestedName: _artifactName(message),
      );
      return;
    }
    final path = message.imagePath;
    if (path != null && path.isNotEmpty) {
      try {
        await NativeShare.file(path);
        return;
      } catch (_) {
        // Fall through to the honest empty result below.
      }
    }
    if (context.mounted) _snack(context, 'Nothing to download yet.');
  }

  Message? _messageById(String id) {
    for (final message in AppState.I.activeSession?.messages ?? const []) {
      if (message.privateSyncId == id) return message;
    }
    return null;
  }

  /// The artifact's real location, or null when it has no downloadable URL.
  String? _artifactHref(Message message) {
    final url = message.imageUrl;
    if (url != null && url.trim().isNotEmpty) return url.trim();
    return null;
  }

  /// The state the artifact actually carries, never an assumed success.
  String _artifactStatus(Message message) {
    final hasContent =
        (message.imageUrl?.isNotEmpty ?? false) ||
        (message.imagePath?.isNotEmpty ?? false) ||
        message.htmlArtifact != null;
    return switch (message.toolState) {
      'error' => 'Failed',
      'stopped' => 'Stopped',
      'running' => hasContent ? 'Ready' : 'Generating',
      _ => hasContent ? 'Ready' : 'Unavailable',
    };
  }

  /// Speaks a voice reply with the on-device TTS engine.
  void _playVoiceReply(String id) {
    final session = AppState.I.activeSession;
    if (session == null) return;
    for (final item in _items(session)) {
      if (item is! V2LiveVoiceReply || item.id != id) continue;
      final transcript = item.reply.transcript;
      if (transcript == null || transcript.trim().isEmpty) return;
      unawaited(
        VoiceReplyService.I.speak(
          transcript,
          localeId: VoiceReplyService.localeFor(AppState.I.voiceLanguage),
        ),
      );
      return;
    }
  }

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _rename(String id) async {
    final session = AppState.I.sessionById(id);
    if (session == null) return;
    final controller = TextEditingController(text: session.title);
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename chat'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Chat name'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    final clean = title?.trim();
    if (clean == null || clean.isEmpty) return;
    AppState.I.renameSession(id, clean);
  }

  Future<void> _delete(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this chat?'),
        content: const Text(
          'Deleting removes this chat’s files and memory from the cloud. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await AppState.I.deleteSession(id);
  }

  void _openProjects(BuildContext context) {
    _scaffoldKey.currentState?.closeDrawer();
    final controller = ProjectsController.I;
    unawaited(controller.refresh());
    Navigator.of(_navContext).push(
      MaterialPageRoute<void>(
        builder: (_) => ProjectsPage(
          data: V2ProjectsData(
            projects: [
              for (final project in controller.projects)
                V2Project(
                  id: project.id,
                  name: project.name,
                  chatCount: project.sessionCount,
                  storageLabel: _bytes(project.fileBytes),
                  updatedLabel: _timeLabel(project.updatedAt),
                ),
            ],
          ),
          onCreateProject: (draft) async {
            await controller.create(draft.name);
            await controller.refresh();
          },
          onProjectTap: (project) {
            // The project row opens its detail sheet, not an arbitrary chat.
            Navigator.of(_navContext).pop();
            unawaited(
              _openProject(
                V2SidebarProject(
                  id: project.id,
                  name: project.name,
                  chatCount: project.chatCount,
                  memoryFileCount:
                      controller.byId(project.id)?.fileBreakdown.memory ?? 0,
                ),
              ),
            );
          },
          onProjectActions: (project) => _projectActions(context, project),
        ),
      ),
    );
  }

  Future<void> _projectActions(BuildContext context, V2Project project) async {
    final action = await showOSheet<String>(
      context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            OListRow(
              title: 'Rename project',
              icon: Icons.edit_outlined,
              showChevron: false,
              onTap: () => Navigator.pop(sheetContext, 'rename'),
            ),
            OListRow(
              title: 'Delete project',
              subtitle: 'Chats stay; only the grouping is removed',
              icon: Icons.delete_outline_rounded,
              danger: true,
              showChevron: false,
              onTap: () => Navigator.pop(sheetContext, 'delete'),
            ),
            const SizedBox(height: OSpace.s),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    final controller = ProjectsController.I;
    if (action == 'rename') {
      final input = TextEditingController(text: project.name);
      final name = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Rename project'),
          content: TextField(
            controller: input,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            onSubmitted: (value) => Navigator.pop(dialogContext, value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, input.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      input.dispose();
      final clean = name?.trim();
      if (clean == null || clean.isEmpty) return;
      await controller.rename(project.id, clean);
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Delete ${project.name}?'),
          content: const Text('The chats inside stay in your sidebar.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Keep'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      await controller.delete(project.id);
    }
    await controller.refresh();
  }

  Future<void> _openProject(V2SidebarProject project) async {
    _scaffoldKey.currentState?.closeDrawer();
    final controller = ProjectsController.I;
    final dto = controller.byId(project.id);
    final sessions = AppState.I.rootSessionsByRecency
        .where((session) => session.projectId == project.id)
        .toList();
    final quotaGb = _storageGb(AppState.I.ovidCloudTier);
    final quotaBytes = quotaGb * 1024 * 1024 * 1024;
    final usedBytes = dto?.fileBytes ?? 0;
    await showProjectDetailSheet(
      _navContext,
      data: V2ProjectDetailData(
        projectName: project.name,
        chatCount: sessions.length,
        chats: [
          for (final session in sessions)
            V2ProjectChat(
              id: session.id,
              title: session.title,
              modelLabel: _modelLabel(session),
              timeLabel: _timeLabel(session.lastActivityAt),
            ),
        ],
        // No project-memory read endpoint exists; the sheet says so by
        // showing its empty section instead of inventing files.
        memoryFiles: const [],
        storageLabel: usedBytes <= 0
            ? ''
            : '${_bytes(usedBytes)} of $quotaGb GB',
        storageFraction: quotaBytes <= 0
            ? 0
            : (usedBytes / quotaBytes).clamp(0.0, 1.0),
        status: sessions.isEmpty && usedBytes <= 0
            ? V2ProjectDetailStatus.empty
            : V2ProjectDetailStatus.content,
      ),
      onChatTap: (chat) {
        Navigator.of(_navContext).pop();
        _selectSession(chat.id);
      },
      onRetry: () async {
        Navigator.of(_navContext).pop();
        await controller.refresh();
        if (mounted) {
          await _openProject(
            V2SidebarProject(
              id: project.id,
              name: project.name,
              chatCount: project.chatCount,
              memoryFileCount: project.memoryFileCount,
            ),
          );
        }
      },
    );
  }

  int _storageGb(String tier) => switch (tier) {
    '3x' => 5,
    '7x' => 15,
    '15x' => 75,
    _ => 3,
  };

  Future<void> _openSettings() async {
    _scaffoldKey.currentState?.closeDrawer();
    await Navigator.of(_navContext).push(
      MaterialPageRoute<void>(
        builder: (pageContext) => SettingsHubPage(
          data: V2SettingsHubData(
            profile: V2SettingsProfile(
              name: FirebaseService.I.accountLabel,
              email: FirebaseService.I.accountDetail,
              planLabel: _planLabel(AppState.I.ovidCloudTier),
              initials: _initials(FirebaseService.I.accountLabel),
            ),
            account: V2SettingsSection(
              title: 'Account',
              items: [
                _settingsRow(
                  'account',
                  'Account',
                  Icons.manage_accounts_rounded,
                  'Profile, email and region',
                ),
                _settingsRow(
                  'plan_billing',
                  'Plan & billing',
                  Icons.credit_card_rounded,
                  '${_planLabel(AppState.I.ovidCloudTier)} · '
                      '${_storageGb(AppState.I.ovidCloudTier)} GB storage',
                ),
                _settingsRow(
                  'usage',
                  'Usage',
                  Icons.data_usage_rounded,
                  'Tokens, requests and storage',
                ),
                _settingsRow(
                  'credentials',
                  'Credentials',
                  Icons.key_rounded,
                  'Sign-in methods and tokens',
                ),
              ],
            ),
            chat: V2SettingsSection(
              title: 'Chat',
              items: [
                _settingsRow(
                  'appearance',
                  'Appearance',
                  Icons.palette_outlined,
                  'Theme, text size and motion',
                ),
                _settingsRow(
                  'memory',
                  'Memory',
                  Icons.psychology_outlined,
                  'Global and project memory',
                ),
                _settingsRow(
                  'shared_memory',
                  'Shared memory',
                  Icons.hub_outlined,
                  'Share memory with your project',
                ),
                _settingsRow(
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
                _settingsRow(
                  'connectors',
                  'Connectors',
                  Icons.extension_rounded,
                  'Apps Ovid can use',
                ),
                _settingsRow(
                  'presets',
                  'Agent presets',
                  Icons.tune_rounded,
                  'How Ovid approaches a task',
                ),
                _settingsRow(
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
                _settingsRow(
                  'export',
                  'Export or import',
                  Icons.swap_vert_rounded,
                  'Move your data in or out',
                ),
                _settingsRow(
                  'permissions',
                  'Permissions',
                  Icons.verified_user_outlined,
                  'Camera, microphone and files',
                ),
                _settingsRow(
                  'crash',
                  'Crash reports',
                  Icons.bug_report_outlined,
                  'Anonymous and optional',
                ),
                _settingsRow(
                  'storage',
                  'Storage',
                  Icons.storage_rounded,
                  'What is using your space',
                ),
                _settingsRow(
                  'delete',
                  'Delete data',
                  Icons.delete_outline_rounded,
                  'Remove chats, files and memory',
                  danger: true,
                ),
                _settingsRow(
                  'reset_memory',
                  'Reset memory',
                  Icons.restart_alt_rounded,
                  'Forget everything Ovid learned',
                  danger: true,
                ),
              ],
            ),
            advanced: V2SettingsSection(
              title: 'Advanced',
              items: [
                _settingsRow(
                  'notifications',
                  'Notifications',
                  Icons.notifications_outlined,
                  'Runs, schedules and security',
                ),
                _settingsRow(
                  'app_lock',
                  'App lock',
                  Icons.lock_outline_rounded,
                  'Require a PIN when Ovid returns',
                ),
                _settingsRow(
                  'account_health',
                  'Account health',
                  Icons.health_and_safety_outlined,
                  'Security and devices',
                ),
                _settingsRow(
                  'about',
                  'About',
                  Icons.info_outline_rounded,
                  'Version, legal and support',
                ),
              ],
            ),
            showReasoning: AppState.I.showReasoning,
            onReasoningChanged: (value) =>
                unawaited(AppState.I.setShowReasoning(value)),
            onAddConnector: () =>
                V2WorkRoutes.openConnectors(_navContext, _settings),
            onProfileTap: () =>
                V2SettingsRoutes.open(_navContext, 'account', _settings),
            onSignOut: () => _settings.signOut(pageContext),
            onRetry: _settings.refreshUsage,
          ),
        ),
      ),
    );
  }

  V2SettingsItem _settingsRow(
    String id,
    String label,
    IconData icon,
    String subtitle, {
    bool danger = false,
  }) {
    return V2SettingsItem(
      id: id,
      label: label,
      icon: icon,
      subtitle: subtitle,
      danger: danger,
      onTap: () => V2SettingsRoutes.open(_navContext, id, _settings),
    );
  }

  // ── Small formatters ────────────────────────────────────────────────────

  String _modelLabel(ChatSession? session) {
    final raw = session?.model;
    if (raw == null || raw.isEmpty || raw == 'Select a provider') {
      return 'Auto';
    }
    return raw;
  }

  String _planLabel(String tier) {
    if (tier == 'free') return 'Free plan';
    return ovidPlanName(tier);
  }

  String _timeLabel(DateTime at) {
    final local = at.toLocal();
    final now = DateTime.now();
    final startToday = DateTime(now.year, now.month, now.day);
    final startYesterday = startToday.subtract(const Duration(days: 1));
    if (!local.isBefore(startToday)) {
      final h = local.hour.toString().padLeft(2, '0');
      final m = local.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }
    if (!local.isBefore(startYesterday)) return 'Yesterday';
    return formatLocalDay(local);
  }

  String? _initials(String name) {
    final words = name.trim().split(RegExp(r'\s+'));
    if (words.isEmpty || words.first.isEmpty) return null;
    if (words.length == 1) {
      return words.first.characters.take(1).toString().toUpperCase();
    }
    final first = words.first.characters.take(1).toString();
    final second = words[1].characters.take(1).toString();
    return '$first$second'.toUpperCase();
  }

  String _tokensLabel() {
    final usage = _usage.usage;
    if (usage == null || usage.today == null) {
      return 'Auto · Checking allowance…';
    }
    if (AppState.I.ovidCloudTier != 'free') return 'Auto · Paid plan';
    final today = usage.today!;
    final used = today.inputTokens + today.outputTokens;
    final left = (50000000 - used).clamp(0, 50000000);
    return 'Auto · ${_compact(left)} tokens left today';
  }

  bool get _planLimited {
    final usage = _usage.usage;
    return usage != null && usage.hasRemainingPct && usage.remainingPct <= 0;
  }

  String _resetLabel() {
    final resetsAt = _usage.usage?.resetsAt;
    if (resetsAt == null) return 'Resets soon';
    final until = formatTimeUntil(resetsAt);
    return until == 'now' ? 'Resetting now' : 'Resets $until';
  }

  String _draftFor(String? id) {
    if (id == null) return '';
    return ComposerDraftStore.I.draftFor(id) ?? '';
  }

  String _bytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    if (value < 1024 * 1024 * 1024) {
      return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _compact(int value) {
    if (value >= 1000000) {
      final m = value / 1000000;
      return '${m.toStringAsFixed(m >= 10 ? 0 : 1)}M';
    }
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(0)}K';
    return '$value';
  }

  IconData _toolIcon(String? name) {
    final tool = name ?? '';
    if (tool.contains('browser') || tool.contains('web')) {
      return Icons.language_rounded;
    }
    if (tool.contains('shell') || tool.contains('bash')) {
      return Icons.terminal_rounded;
    }
    if (tool.contains('edit') || tool.contains('write')) {
      return Icons.edit_document;
    }
    if (tool.contains('agent')) return Icons.hub_rounded;
    return Icons.build_rounded;
  }

  String _artifactName(Message message) {
    final url = message.imageUrl;
    if (url != null && url.isNotEmpty) {
      final name = url.split('/').last.split('?').first;
      if (name.isNotEmpty) return name;
    }
    final path = message.imagePath;
    if (path != null && path.isNotEmpty) return path.split('/').last;
    return message.htmlArtifact != null ? 'preview.html' : 'Artifact';
  }
}

/// Tracks which bottom tab owns the current route.
///
/// The shell registers the tab it is about to open with [expect]; [didPush]
/// consumes that expectation and records the tab, and [didPop]/[didRemove]
/// restore the tab of the route underneath. Routes pushed from inside a tab
/// (for example artifact detail) inherit the tab they were opened from.
class _V2TabObserver extends NavigatorObserver {
  final ValueNotifier<V2NavTab> current = ValueNotifier<V2NavTab>(
    V2NavTab.chat,
  );
  final List<V2NavTab> _stack = <V2NavTab>[];
  V2NavTab? _next;

  void expect(V2NavTab tab) => _next = tab;
  void clearExpectation() => _next = null;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final tab = _next ?? (route.isFirst ? V2NavTab.chat : current.value);
    _next = null;
    _stack.add(tab);
    current.value = tab;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_stack.isNotEmpty) _stack.removeLast();
    current.value = _stack.isEmpty ? V2NavTab.chat : _stack.last;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_stack.isNotEmpty) _stack.removeLast();
    current.value = _stack.isEmpty ? V2NavTab.chat : _stack.last;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute == null) return;
    final tab = _next ?? current.value;
    _next = null;
    if (_stack.isNotEmpty) {
      _stack[_stack.length - 1] = tab;
    } else {
      _stack.add(tab);
    }
    current.value = tab;
  }
}
