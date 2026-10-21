import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/chat_pins.dart';
import '../../../core/cloud/cloud_agent_facade.dart';
import '../../../core/cloud/models.dart';
import '../../../core/cloud/projects.dart';
import '../../../core/cloud_usage_store.dart';
import '../../../core/composer_drafts.dart';
import '../../../core/conversation_share_service.dart';
import '../../../core/connection_service.dart';
import '../../../core/firebase_service.dart';
import '../../../core/format.dart';
import '../../../core/ovid_cloud_service.dart';
import '../../../core/state.dart';
import '../../design/o_tokens.dart';
import '../chat/chat_page.dart';
import '../chat/composer_attachments.dart';
import '../chat/live_chat_page.dart';
import '../chat/model_picker_sheet.dart';
import '../../design/o_components.dart';
import '../settings/settings_hub.dart';
import '../sidebar/projects_page.dart';
import '../sidebar/search_page.dart';
import '../share/share_sheet.dart';
import '../sidebar/session_actions_sheet.dart';
import '../sidebar/sidebar.dart';
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
  late final CloudUsageStore _usage;
  late final V2SettingsActions _settings;
  late final Listenable _listenable;
  final Map<String, ConversationShare> _activeShares = {};

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
    unawaited(ChatPinsStore.I.bindCurrentAccount());
    unawaited(ComposerDraftStore.I.load().then((_) {
      if (mounted) setState(() {});
    }));
    unawaited(ProjectsController.I.refresh());
  }

  @override
  void dispose() {
    _usage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _listenable,
      builder: (context, _) {
        final app = AppState.I;
        final session = app.activeSession;
        final hasMessages = session != null && session.messages.isNotEmpty;
        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: OColors.of(context).bg,
          drawer: Drawer(
            width: 340,
            backgroundColor: OColors.of(context).surface,
            child: Sidebar(
              data: _sidebarData(app),
              onProfile: () => _openSettings(context),
              onNewChat: () => _newChat(),
              onSearch: () => _openSearch(context),
              onNewProject: () => _openProjects(context),
              onProjectTap: (project) => _openProject(context, project),
              onSessionTap: (row) => _selectSession(row.id),
              onSessionActions: (row) => _showSessionActions(context, row.id),
              onSessionLongPress: (row) =>
                  _showSessionActions(context, row.id),
              onSchedule: () => V2WorkRoutes.openSchedules(context, _settings),
              onArtifacts: () => V2WorkRoutes.openArtifacts(context, _settings),
              onSettings: () => _openSettings(context),
              onRetry: () => setState(() {}),
            ),
          ),
          body: hasMessages
              ? V2LiveChatPage(
                  key: ValueKey('live-${session.id}'),
                  data: _liveData(app, session),
                  onMenu: _openDrawer,
                  onModelChipTap: () => _openModelPicker(context),
                  onStudio: () => V2WorkRoutes.openStudio(context, _settings),
                  onBrowser: () => V2WorkRoutes.openBrowser(context, _settings),
                  onMore: () => _chatMenu(context, session.id),
                  onSubmit: _submit,
                  onStop: _stop,
                  onDownload: (name) => _download(context, name),
                  onStartChat: _newChat,
                  onRetry: _retry,
                  onDraftChanged: (text) =>
                      ComposerDraftStore.I.put(session.id, text),
                )
              : V2ChatPage(
                  key: ValueKey('empty-${session?.id ?? 'new'}'),
                  data: _chatData(app),
                  onMenu: _openDrawer,
                  onModelChipTap: () => _openModelPicker(context),
                  onStudio: () => V2WorkRoutes.openStudio(context, _settings),
                  onBrowser: () => V2WorkRoutes.openBrowser(context, _settings),
                  onMore: session == null
                      ? null
                      : () => _chatMenu(context, session.id),
                  onSubmit: _submit,
                  onStop: _stop,
                  onPermissionTap: _cyclePermission,
                  onRetry: _retry,
                  onSeePlans: () =>
                      V2SettingsRoutes.open(context, 'plan_billing', _settings),
                  onDraftChanged: (text) {
                    final id = AppState.I.activeSessionId;
                    if (id != null) ComposerDraftStore.I.put(id, text);
                  },
                ),
        );
      },
    );
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
        pinned.add(V2SidebarSession(
          id: row.id,
          title: row.title,
          modelLabel: row.modelLabel,
          timeLabel: row.timeLabel,
          pinned: true,
        ));
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
        ),
    ];
  }

  V2SidebarSession _sidebarSession(ChatSession session) => V2SidebarSession(
    id: session.id,
    title: session.title,
    modelLabel: _modelLabel(session),
    timeLabel: _timeLabel(session.lastActivityAt),
  );

  V2ChatPageData _chatData(AppState app) {
    final limited = _planLimited;
    final state = ConnectionService.I.offline
        ? V2ChatState.offline
        : limited
        ? V2ChatState.planLimited
        : V2ChatState.empty;
    return V2ChatPageData(
      title: 'Ovid Si',
      modelLabel: _modelLabel(app.activeSession),
      tokensLabel: _tokensLabel(),
      fastAgentLabel: 'Fast agent',
      sessionId: app.activeSessionId,
      draft: _draftFor(app.activeSessionId),
      state: state,
      queuedCount: 0,
      limitResetLabel: _resetLabel(),
      permissionLabel: CloudAgentFacade.I.mode.label,
      composerHint: 'Ask Ovid to do anything...',
      offlineTitle: "You're offline",
      offlineMessage: 'Messages will send when you reconnect.',
    );
  }

  V2LiveChatData _liveData(AppState app, ChatSession session) {
    final agent = CloudAgentFacade.I;
    final running = agent.busyFor(session.id);
    return V2LiveChatData(
      title: 'Ovid Si',
      sessionTitle: session.title,
      modelLabel: _modelLabel(session),
      items: _items(session),
      running: running,
      loading: false,
      statusLabel:
          agent.activityFor(session.id) ??
          agent.statusFor(session.id) ??
          'Ovid is working...',
      draft: _draftFor(session.id),
      composerHint: 'Ask Ovid to do anything...',
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
              statusLabel: 'Ready',
              previewLabel: 'Tap to open',
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
            _openSettings(context);
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

  void _retry() {
    final id = AppState.I.activeSessionId;
    if (id == null) return;
    CloudAgentFacade.I.retryLastPrompt(id);
  }

  void _cyclePermission() {
    final current = CloudAgentFacade.I.mode;
    final next = AgentMode.values[(current.index + 1) % AgentMode.values.length];
    CloudAgentFacade.I.setMode(next);
  }

  Future<void> _chatMenu(BuildContext context, String id) async {
    final session = AppState.I.sessionById(id);
    if (session == null) return;
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
            if (session.repo != null && session.repo!.isNotEmpty)
              OListRow(
                title: 'Open Studio',
                subtitle: session.repo,
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
        await V2StudioRoutes.openWorkspace(
          context,
          session.repo!,
          session.branch ?? 'main',
          sessionId: id,
        );
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
      onTogglePin: (value) => unawaited(
        ChatPinsStore.I.setPinned(id, value),
      ),
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
      _notWired(context, 'Projects');
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
      _notWired(context, 'Sharing this chat');
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
          V2ShareTarget.gmail => 'mailto:?subject=${Uri.encodeComponent(session.title)}&body=$text',
          V2ShareTarget.slack => 'https://slack.com/openid/connect/authorize?$text',
          V2ShareTarget.more => null,
        };
        if (url == null) {
          unawaited(Clipboard.setData(ClipboardData(text: link)));
          _snack(context, 'Link copied.');
          return;
        }
        unawaited(launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication));
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
      buffer.writeln(
        message.role == 'user' ? '## You\n\n' : '## Ovid Si\n\n',
      );
      buffer.writeln('${message.content.trim()}\n');
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (context.mounted) _snack(context, 'Markdown copied.');
  }

  Future<void> _download(BuildContext context, String name) async {
    for (final message in AppState.I.activeSession?.messages ?? const []) {
      final url = message.imageUrl;
      if (url != null && url.isNotEmpty) {
        final ok = await launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        );
        if (ok) return;
      }
    }
    if (context.mounted) _snack(context, 'Nothing to download yet.');
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

  void _openSearch(BuildContext context) {
    _scaffoldKey.currentState?.closeDrawer();
    final sessions = AppState.I.rootSessionsByRecency;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SearchPage(
          data: V2SearchData(
            chats: [
              for (final session in sessions)
                V2SearchChat(
                  id: session.id,
                  title: session.title,
                  modelLabel: _modelLabel(session),
                  timeLabel: _timeLabel(session.lastActivityAt),
                  snippet: _snippet(session),
                ),
            ],
          ),
          onChatTap: (row) {
            Navigator.of(context).pop();
            _selectSession(row.id);
          },
          onCancel: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  void _openProjects(BuildContext context) {
    _scaffoldKey.currentState?.closeDrawer();
    final controller = ProjectsController.I;
    unawaited(controller.refresh());
    Navigator.of(context).push(
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
            final session = AppState.I.rootSessionsByRecency
                .where((s) => s.projectId == project.id)
                .firstOrNull;
            if (session == null) return;
            Navigator.of(context).pop();
            _selectSession(session.id);
          },
          onProjectActions: (project) => _projectActions(context, project),
        ),
      ),
    );
  }

  Future<void> _projectActions(
    BuildContext context,
    V2Project project,
  ) async {
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

  void _openProject(BuildContext context, V2SidebarProject project) {
    final session = AppState.I.rootSessionsByRecency
        .where((s) => s.projectId == project.id)
        .firstOrNull;
    if (session == null) {
      _openProjects(context);
      return;
    }
    _selectSession(session.id);
  }

  void _openSettings(BuildContext context) {
    _scaffoldKey.currentState?.closeDrawer();
    Navigator.of(context).push(
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
                  context,
                  'account',
                  'Account',
                  Icons.manage_accounts_rounded,
                  'Profile, email and region',
                ),
                _settingsRow(
                  context,
                  'plan_billing',
                  'Plan & billing',
                  Icons.credit_card_rounded,
                  '${_planLabel(AppState.I.ovidCloudTier)} · 3 GB storage',
                ),
                _settingsRow(
                  context,
                  'usage',
                  'Usage',
                  Icons.data_usage_rounded,
                  'Tokens, requests and storage',
                ),
                _settingsRow(
                  context,
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
                  context,
                  'appearance',
                  'Appearance',
                  Icons.palette_outlined,
                  'Theme, text size and motion',
                ),
                _settingsRow(
                  context,
                  'memory',
                  'Memory',
                  Icons.psychology_outlined,
                  'Global and project memory',
                ),
                _settingsRow(
                  context,
                  'shared_memory',
                  'Shared memory',
                  Icons.hub_outlined,
                  'Share memory with your project',
                ),
                _settingsRow(
                  context,
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
                  context,
                  'connectors',
                  'Connectors',
                  Icons.extension_rounded,
                  'Apps Ovid can use',
                ),
                _settingsRow(
                  context,
                  'presets',
                  'Agent presets',
                  Icons.tune_rounded,
                  'How Ovid approaches a task',
                ),
                _settingsRow(
                  context,
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
                  context,
                  'export',
                  'Export or import',
                  Icons.swap_vert_rounded,
                  'Move your data in or out',
                ),
                _settingsRow(
                  context,
                  'permissions',
                  'Permissions',
                  Icons.verified_user_outlined,
                  'Camera, microphone and files',
                ),
                _settingsRow(
                  context,
                  'crash',
                  'Crash reports',
                  Icons.bug_report_outlined,
                  'Anonymous and optional',
                ),
                _settingsRow(
                  context,
                  'storage',
                  'Storage',
                  Icons.storage_rounded,
                  'What is using your space',
                ),
                _settingsRow(
                  context,
                  'delete',
                  'Delete data',
                  Icons.delete_outline_rounded,
                  'Remove chats, files and memory',
                  danger: true,
                ),
                _settingsRow(
                  context,
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
                  context,
                  'notifications',
                  'Notifications',
                  Icons.notifications_outlined,
                  'Runs, schedules and security',
                ),
                _settingsRow(
                  context,
                  'app_lock',
                  'App lock',
                  Icons.lock_outline_rounded,
                  'Require a PIN when Ovid returns',
                ),
                _settingsRow(
                  context,
                  'account_health',
                  'Account health',
                  Icons.health_and_safety_outlined,
                  'Security and devices',
                ),
                _settingsRow(
                  context,
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
                V2WorkRoutes.openConnectors(context, _settings),
            onProfileTap: () =>
                V2SettingsRoutes.open(context, 'account', _settings),
            onSignOut: () => _settings.signOut(context),
            onRetry: () {},
          ),
        ),
      ),
    );
  }

  V2SettingsItem _settingsRow(
    BuildContext context,
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
      onTap: () => V2SettingsRoutes.open(context, id, _settings),
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

  String _snippet(ChatSession session) {
    for (final message in session.messages.reversed) {
      final text = message.content.trim();
      if (text.isNotEmpty) {
        return text.length <= 90 ? text : '${text.substring(0, 90)}…';
      }
    }
    return '';
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

  void _notWired(BuildContext context, String label) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('$label is coming in the wiring pass.')),
      );
  }
}
