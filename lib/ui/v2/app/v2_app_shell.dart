import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/chat_integration_ports.dart';
import '../../../core/chat_pins.dart';
import '../../../core/collaboration/models.dart';
import '../../../core/collaboration/production.dart';
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
import '../../../core/session_artifacts.dart';
import '../../../core/state.dart';
import '../../../core/voice_reply_service.dart';
import '../../design/o_screen.dart';
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
import '../share/share_chat_sheet.dart';
import '../share/share_sheet.dart';
import '../sidebar/session_actions_sheet.dart';
import '../sidebar/sidebar.dart';
import 'bottom_nav.dart';
import 'mention_source_live.dart';
import 'v2_collab_routes.dart';
import 'v2_settings_actions.dart';
import 'v2_work_routes.dart';
import 'v2_run_routes.dart';
import 'v2_settings_routes.dart';
import 'v2_studio_routes.dart';

/// Width of the fixed navigation column on the tablet band (600–899 dp).
///
/// Aliased to the sidebar's own rail width so the column and the widget it
/// holds can never disagree by a pixel.
const double v2TabletNavWidth = Sidebar.railWidthTablet;

/// Width of the fixed navigation column on the wide band (900 dp+).
const double v2WideNavWidth = Sidebar.railWidthWide;

/// The widest the phone drawer is allowed to get. On a 320 dp screen the drawer
/// still has to leave a strip of the page visible and must never exceed the
/// window, so the host scales it down to 86 % of the available width.
const double _drawerMaxWidth = 340;

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
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            // < 600 dp: drawer + bottom bar. 600–899 dp: fixed 280 dp column,
            // no bottom bar. 900 dp+: fixed 300 dp column, no bottom bar.
            final isTablet = OBreakpoints.isTablet(width);
            final isWide = OBreakpoints.isWide(width);
            return Scaffold(
              key: _scaffoldKey,
              backgroundColor: OColors.of(context).bg,
              // The fixed column already holds the sidebar on tablets, so the
              // drawer is removed there: one navigation, never two.
              drawer: isTablet
                  ? null
                  : Drawer(
                      width: math.min(_drawerMaxWidth, width * 0.86),
                      backgroundColor: OColors.of(context).surface,
                      child: _sidebar(app, SidebarLayout.drawer),
                    ),
              body: Row(
                children: [
                  // The empty first slot keeps the Navigator's position stable
                  // when a rotation crosses the tablet breakpoint, so the open
                  // route survives the layout change.
                  if (isTablet)
                    _NavColumn(
                      key: const ValueKey<String>('v2-shell-sidebar'),
                      width: isWide ? v2WideNavWidth : v2TabletNavWidth,
                      child: _sidebar(app, SidebarLayout.rail),
                    )
                  else
                    const SizedBox.shrink(),
                  // The tabs push onto this nested navigator so the bar stays
                  // mounted; the handler gives the system back gesture to the
                  // nested stack first, and only exits the app from the home
                  // route.
                  Expanded(
                    child: NavigatorPopHandler(
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
                  ),
                ],
              ),
              // Navigation lives in exactly one place per band: the bottom bar
              // below 600 dp, the fixed column above it.
              bottomNavigationBar: isTablet
                  ? null
                  : ValueListenableBuilder<V2NavTab>(
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
      },
    );
  }

  /// One sidebar per band: the drawer form below 600 dp, the fixed rail form
  /// above it. They share every callback and the same data, so the two
  /// navigation shapes never drift.
  Widget _sidebar(AppState app, SidebarLayout layout) {
    return Sidebar(
      data: _sidebarData(app),
      layout: layout,
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
        // The cloud fold writes into the facade's projection, never into
        // ChatSession.messages (the same resolution the share sheet uses).
        // Reading the session row here would pin a cloud chat on the empty
        // page forever: the prompt and the answer would never paint.
        final messages = session == null
            ? const <Message>[]
            : CloudAgentFacade.I.transcriptFor(session.id) ??
                  session.messages;
        final hasMessages = messages.isNotEmpty;
        final sessionId = session?.id;
        if (!hasMessages) {
          return V2ChatPage(
            key: ValueKey('empty-${session?.id ?? 'new'}'),
            data: _chatData(app),
            onMenu: _usesDrawer(routeContext) ? _openDrawer : null,
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
          key: ValueKey('live-${sessionId ?? 'new'}'),
          data: _liveData(app, session!),
          onMenu: _usesDrawer(routeContext) ? _openDrawer : null,
          onModelChipTap: () => _openModelPicker(routeContext),
          onStudio: () => V2WorkRoutes.openStudio(_navContext, _settings),
          onBrowser: () => V2WorkRoutes.openBrowser(_navContext, _settings),
          onMore: () => _chatMenu(routeContext, sessionId!),
          onSubmit: _submit,
          onStop: _stop,
          onSendQueuedNow: _sendQueuedNow,
          onDismissQueued: () => _dismissQueued(sessionId!),
          onDownload: (id) => _download(routeContext, id),
          onArtifactTap: (id) => _openArtifact(routeContext, id),
          onOpenLink: (url) =>
              unawaited(v2OpenTranscriptLink(routeContext, url)),
          onDownloadLink: (url) =>
              unawaited(v2SaveTranscriptLink(routeContext, url)),
          onStartChat: _newChat,
          onRetry: _retry,
          onPermissionTap: () => unawaited(_openPermissionSheet(routeContext)),
          permissionLabel: CloudAgentFacade.I.mode.label,
          voiceService: const V2PlatformVoiceService(),
          voiceLanguage: app.voiceLanguage,
          onVoicePlay: _playVoiceReply,
          onDraftChanged: (text) => ComposerDraftStore.I.put(sessionId!, text),
        );
      },
    );
  }

  BuildContext get _navContext => _routeContext ?? context;

  /// True below 600 dp, where the drawer is the only navigation beside the
  /// bottom bar. Above it the fixed column is always visible, so the header
  /// menu would open a second copy of the same list.
  bool _usesDrawer(BuildContext context) =>
      MediaQuery.sizeOf(context).width < OBreakpoints.tablet;

  /// The one place every tab goes. Chat is the home route; the other four open
  /// their real destination on the shell's navigator so the bar stays mounted
  /// and the selected tab follows the route.
  ///
  /// Re-tapping the active tab pops back to that tab's root instead of pushing
  /// a second copy of it.
  void _selectTab(V2NavTab tab) {
    if (!mounted) return;
    final nav = _navKey.currentState;
    if (nav == null) return;
    if (tab == _tabObserver.current.value) {
      _tabObserver.popToTabRoot(nav);
      return;
    }
    // A different tab starts from the home route, so tab destinations never
    // stack on top of one another.
    nav.popUntil((route) => route.isFirst);
    switch (tab) {
      case V2NavTab.chat:
        // The home route is the chat transcript; popping above was enough.
        return;
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
    final token = _tabObserver.expect(tab);
    try {
      await open();
    } finally {
      // Only clear the expectation this call created: a route that was popped
      // by a newer tab switch must not erase the newer tab's expectation.
      _tabObserver.clearExpectation(token);
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
    final messages =
        CloudAgentFacade.I.transcriptFor(session.id) ?? session.messages;
    for (final message in messages) {
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
          // The same artifact row the library derives, so the transcript's tap
          // opens the library's real detail route with the real file.
          final artifact = _artifactFor(session, message);
          final link = _artifactLinkOf(artifact) ?? _artifactHref(message);
          items.add(
            V2LiveArtifact(
              id: message.privateSyncId,
              fileName: artifact?.name ?? _artifactName(message),
              meta: _artifactMeta(artifact, message),
              statusLabel: _artifactStatus(message),
              previewLabel: 'Open',
              href: link,
              kind: artifact?.kind,
              sizeBytes: artifact?.size,
              downloadUrl: link,
              thumbnail: _artifactThumbnail(artifact),
              content: _artifactContent(artifact, message),
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
    // A live room is keyed by the collaboration session id, and only the chat
    // that started it (or the room's own id) can open it from this menu.
    final collaboration = AppState.I.collaboration;
    final collabState = collaboration?.state;
    final collabSessionId = collabState?.session.sessionId;
    final collabHere =
        collabSessionId != null &&
        (collaboration?.sourceSessionId == id || collabSessionId == id);
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
            if (collabHere)
              OListRow(
                title: 'Live chat',
                subtitle: 'Open the live room',
                icon: Icons.forum_outlined,
                showChevron: false,
                onTap: () => Navigator.pop(sheetContext, 'live'),
              ),
            if (collabHere)
              OListRow(
                title: 'Members',
                subtitle: 'People in this room',
                icon: Icons.group_outlined,
                showChevron: false,
                onTap: () => Navigator.pop(sheetContext, 'members'),
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
      case 'live':
        if (collabSessionId != null) {
          await V2CollabRoutes.openLive(context, collabSessionId);
        }
      case 'members':
        if (collabSessionId != null) {
          await V2CollabRoutes.openMembers(context, collabSessionId);
        }
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
      _snack(context, 'Create a project, then move this chat.');
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
    await showOSheet<void>(
      context,
      builder: (sheetContext) => _ChatShareHost(
        session: session,
        onClose: () => Navigator.maybePop(sheetContext),
      ),
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
  ///
  /// The transcript's artifact is the same row the library derives, so the tap
  /// pushes the library's detail host (mint, preview fetch, Download, Copy
  /// link). Only an artifact with no id falls back to launching its URL, and
  /// only one with neither falls back to the transcript's local detail.
  Future<void> _openArtifact(BuildContext context, String id) async {
    final message = _messageById(id);
    if (message == null) return;
    final session = AppState.I.activeSession;
    final artifact = session == null ? null : _artifactFor(session, message);
    if (artifact != null) {
      await V2WorkRoutes.openArtifactDetail(context, artifact);
      return;
    }
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
      previewLabel: 'Open',
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
    final session = AppState.I.activeSession;
    if (session == null) return null;
    // The same transcript the live page renders (facade projection first).
    final messages =
        CloudAgentFacade.I.transcriptFor(session.id) ?? session.messages;
    for (final message in messages) {
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
              subtitle: 'Chats stay; grouping is removed',
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
                  'Sign-in and deletion',
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

  /// The artifact row a message projects onto, built the way the library
  /// derives its list (`collectSessionArtifacts`), so the transcript and the
  /// library open the same file with the same identity.
  SessionArtifact? _artifactFor(ChatSession session, Message message) {
    switch (message.kind) {
      case MsgKind.imageGen:
        final url = message.imageUrl?.trim() ?? '';
        final path = message.imagePath?.trim() ?? '';
        if (url.isEmpty && path.isEmpty) return null;
        final cloudId = cloudArtifactIdOf(url);
        return SessionArtifact(
          id: '${session.id}:img:${message.privateSyncId}',
          name: _artifactName(message),
          path: path.isEmpty ? null : path,
          url: url.isEmpty ? null : url,
          sessionId: session.id,
          sessionTitle: session.title,
          time: message.time,
          origin: ArtifactOrigin.generated,
          kind: ArtifactKind.image,
          // Only a row with a cloud identity can be re-minted; a local file
          // keeps its own path and the detail says so.
          cloudArtifactId: cloudId,
          cloudAccountId: cloudId == null
              ? null
              : V2WorkRoutes.artifactAccountId,
        );
      case MsgKind.htmlArtifact:
        final html = message.htmlArtifact;
        if (html == null) return null;
        return SessionArtifact(
          id: '${session.id}:html:${html.id}',
          name: html.title,
          sessionId: session.id,
          sessionTitle: session.title,
          time: message.time,
          origin: ArtifactOrigin.generated,
          kind: ArtifactKind.html,
          size: html.payloadBytes,
          html: html,
        );
      default:
        return null;
    }
  }

  /// The artifact's real download URL, or null when it has none.
  String? _artifactLinkOf(SessionArtifact? artifact) {
    final url = artifact?.url?.trim();
    return url == null || url.isEmpty ? null : url;
  }

  /// One meta line: the artifact's type, plus its real size when known.
  String _artifactMeta(SessionArtifact? artifact, Message message) {
    final type = message.kind == MsgKind.imageGen ? 'Image' : 'Web page';
    final size = v2ArtifactSizeLabel(artifact?.size);
    return size.isEmpty ? type : '$type · $size';
  }

  /// Real pixels for an image artifact that has a URL. A local path or a page
  /// has no thumbnail here, so the row keeps its type glyph.
  ImageProvider? _artifactThumbnail(SessionArtifact? artifact) {
    if (artifact == null || artifact.kind != ArtifactKind.image) return null;
    final url = _artifactLinkOf(artifact);
    return url == null ? null : NetworkImage(url);
  }

  /// The inline page's source, so the detail preview and Copy have real text
  /// without a fetch. URL-backed files are fetched on demand instead.
  String? _artifactContent(SessionArtifact? artifact, Message message) {
    final html = artifact?.html ?? message.htmlArtifact;
    if (html == null) return null;
    final buffer = StringBuffer(html.html);
    if (html.css.trim().isNotEmpty) {
      buffer.write('\n<style>\n${html.css}\n</style>');
    }
    if (html.javascript.trim().isNotEmpty) {
      buffer.write('\n<script>\n${html.javascript}\n</script>');
    }
    return buffer.toString();
  }
}

/// Owns the share sheet's real state.
///
/// Read-only links come from [ConversationShareService] (create, list, revoke).
/// Collab links come from the live collaboration session started for this
/// chat, so switching the mode really changes what the link does.
class _ChatShareHost extends StatefulWidget {
  const _ChatShareHost({required this.session, required this.onClose});

  final ChatSession session;
  final VoidCallback onClose;

  @override
  State<_ChatShareHost> createState() => _ChatShareHostState();
}

class _ChatShareHostState extends State<_ChatShareHost> {
  static const String _createError =
      'We could not create a share link. Try again.';

  final ConversationShareService _service =
      ConversationShareService.production();

  V2ShareMode _mode = V2ShareMode.readOnly;
  V2ShareStatus _status = V2ShareStatus.loading;
  String _link = '';
  String _error = _createError;
  bool _busy = false;
  ConversationShare? _readShare;
  int _members = 1;

  ChatSession get _session => widget.session;

  /// The facade's live projection for a cloud chat; the local rows otherwise.
  List<Message> get _messages =>
      CloudAgentFacade.I.transcriptFor(_session.id) ?? _session.messages;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() =>
      _mode == V2ShareMode.collab ? _loadCollab() : _loadReadOnly();

  Future<void> _loadReadOnly() async {
    if (!mounted) return;
    setState(() {
      _status = V2ShareStatus.loading;
      _busy = false;
    });
    if (!_service.available || !FirebaseService.I.isSignedIn) {
      setState(() {
        _status = V2ShareStatus.ready;
        _link = '';
        _readShare = null;
      });
      return;
    }
    try {
      final shares = await _service.list(_session.id);
      if (!mounted) return;
      final share = shares.isEmpty ? null : shares.first;
      setState(() {
        _readShare = share;
        _link = share?.url.toString() ?? '';
        _status = V2ShareStatus.ready;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = V2ShareStatus.error;
        _error = error is ConversationShareException
            ? error.message
            : _createError;
      });
    }
  }

  Future<void> _loadCollab() async {
    if (!mounted) return;
    setState(() {
      _status = V2ShareStatus.loading;
      _busy = false;
    });
    final collab = AppState.I.collaboration;
    if (collab == null || !collab.configured) {
      if (!mounted) return;
      setState(() {
        _status = V2ShareStatus.error;
        _error = 'Live chats are unavailable in this build.';
      });
      return;
    }
    final state = collab.state;
    final mine =
        state != null &&
        collab.isOwner &&
        collab.sourceSessionId == _session.id;
    if (!mounted) return;
    setState(() {
      _status = V2ShareStatus.ready;
      _link = mine ? (collab.shareLink ?? '') : '';
      _members = state?.activeMembers.length ?? 1;
      _error = _createError;
    });
  }

  void _setMode(V2ShareMode mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _status = V2ShareStatus.loading;
      _link = '';
      _error = _createError;
    });
    unawaited(_load());
  }

  Future<void> _create() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = _createError;
    });
    try {
      if (_mode == V2ShareMode.collab) {
        await _createCollab();
      } else {
        await _createReadOnly();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = V2ShareStatus.error;
        if (error is ConversationShareException) {
          _error = error.message;
        } else if (_mode == V2ShareMode.collab) {
          _error = collaborationErrorMessage(error);
        } else {
          _error = _createError;
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createReadOnly() async {
    final snapshot = ConversationSnapshot.fromSession(
      _session,
      messages: _messages,
    );
    if (!snapshot.withinLimits) {
      throw const ConversationShareException(
        'This chat has no shareable text yet.',
      );
    }
    final share = await _service.create(
      snapshot,
      requestId: ConversationShareService.newRequestId(),
    );
    if (!mounted) return;
    setState(() {
      _readShare = share;
      _link = share.url.toString();
      _status = V2ShareStatus.ready;
    });
  }

  Future<void> _createCollab() async {
    if (!FirebaseService.I.isSignedIn) {
      throw const ConversationShareException(
        'Sign in to start a live chat.',
      );
    }
    final collab = AppState.I.collaboration;
    if (collab == null) {
      throw StateError('Live chats are unavailable in this build.');
    }
    final snapshot = ConversationSnapshot.fromSession(
      _session,
      messages: _messages,
    );
    await collab.startFromConversation(
      sourceSessionId: _session.id,
      seed: [
        for (final message in snapshot.messages)
          CollaborationSeedMessage(
            message.role == 'user' ? MessageRole.user : MessageRole.assistant,
            message.content,
          ),
      ],
    );
    final link = collab.shareLink;
    if (link == null) {
      throw StateError('We could not create an invite link.');
    }
    if (!mounted) return;
    setState(() {
      _link = link;
      _members = collab.state?.activeMembers.length ?? 1;
      _status = V2ShareStatus.ready;
    });
  }

  Future<void> _revoke() async {
    try {
      if (_mode == V2ShareMode.collab) {
        await AppState.I.collaboration?.revokeLink();
      } else {
        final share = _readShare;
        if (share == null) return;
        await _service.revoke(share.id);
        _readShare = null;
      }
      if (!mounted) return;
      setState(() {
        _link = '';
        _status = V2ShareStatus.ready;
      });
      _snack('Link revoked.');
    } catch (error) {
      _snack(
        _mode == V2ShareMode.collab
            ? collaborationErrorMessage(error)
            : 'Could not revoke the link.',
      );
    }
  }

  void _copy() {
    if (_link.isEmpty) return;
    unawaited(Clipboard.setData(ClipboardData(text: _link)));
    _snack('Link copied.');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final ready = _status == V2ShareStatus.ready;
    return ShareChatSheet(
      data: V2ShareChatSheetData(
        link: _link,
        mode: _mode,
        memberCount: _members,
        creatorName: FirebaseService.I.accountLabel,
        active: _link.isNotEmpty,
        status: _status,
        errorMessage: _error,
      ),
      onCopyLink: _link.isEmpty ? null : _copy,
      // The mode cards are only offered when this callback is wired.
      onModeChanged: _setMode,
      onCreateLink: ready && _link.isEmpty && !_busy
          ? () => unawaited(_create())
          : null,
      onStopSharing: _link.isEmpty ? null : () => unawaited(_revoke()),
      onRetry: () => unawaited(_load()),
      onClose: widget.onClose,
    );
  }
}

/// The fixed navigation column used from 600 dp up.
///
/// It holds the sidebar in [SidebarLayout.rail] form: 280 dp at 600 dp, 300 dp
/// at 900 dp. The column is the only navigation in this band — the drawer and
/// the bottom bar are both gone. The rail paints its own right hairline, so the
/// host adds no second border (two would read as a 2 px seam).
class _NavColumn extends StatelessWidget {
  const _NavColumn({super.key, required this.width, required this.child});

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(width: width, child: child);
  }
}

/// Tracks which bottom tab owns the current route.
///
/// The shell registers the tab it is about to open with [expect]; [didPush]
/// consumes that expectation, records the tab and marks the route as that
/// tab's root. [didPop]/[didRemove] restore the tab of the route underneath.
/// Routes pushed from inside a tab (for example artifact detail) inherit the
/// tab they were opened from, so [popToTabRoot] can walk back to the one route
/// the bottom bar actually opened.
class _V2TabObserver extends NavigatorObserver {
  final ValueNotifier<V2NavTab> current = ValueNotifier<V2NavTab>(
    V2NavTab.chat,
  );

  /// One entry per live route, bottom first.
  final List<({V2NavTab tab, bool root})> _stack =
      <({V2NavTab tab, bool root})>[];
  V2NavTab? _next;

  /// Bumped on every [expect] so a late `finally` from an older tab switch
  /// cannot clear the expectation a newer one just installed.
  int _generation = 0;

  int expect(V2NavTab tab) {
    _next = tab;
    return ++_generation;
  }

  void clearExpectation(int token) {
    if (token == _generation) _next = null;
  }

  /// Pops everything above [current]'s tab root. Already at the root means
  /// nothing moves, so re-tapping a tab never reloads or stacks a duplicate.
  void popToTabRoot(NavigatorState nav) {
    final tab = current.value;
    var keep = 1;
    for (var i = 0; i < _stack.length; i++) {
      final entry = _stack[i];
      if (entry.tab == tab && entry.root) keep = i + 1;
    }
    var pops = _stack.length - keep;
    while (pops > 0 && nav.canPop()) {
      nav.pop();
      pops--;
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final expected = _next;
    final tab = expected ?? (route.isFirst ? V2NavTab.chat : current.value);
    final root = expected != null || route.isFirst;
    _next = null;
    _stack.add((tab: tab, root: root));
    current.value = tab;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_stack.isNotEmpty) _stack.removeLast();
    current.value = _stack.isEmpty ? V2NavTab.chat : _stack.last.tab;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_stack.isNotEmpty) _stack.removeLast();
    current.value = _stack.isEmpty ? V2NavTab.chat : _stack.last.tab;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute == null) return;
    final expected = _next;
    final tab = expected ?? current.value;
    _next = null;
    if (_stack.isNotEmpty) {
      _stack[_stack.length - 1] = (
        tab: tab,
        root: expected != null || _stack.last.root,
      );
    } else {
      _stack.add((tab: tab, root: expected != null));
    }
    current.value = tab;
  }
}
