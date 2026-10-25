import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/collaboration/models.dart';
import '../core/collaboration/production.dart';
import '../core/collaboration/reducer.dart';
import '../core/firebase_service.dart';
import '../core/native_share.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'auth_screen.dart';
import 'share_actions.dart';
import 'widgets/aether_primitives.dart';
import 'widgets/read_only_markdown.dart';
import 'collab_attachment_picker.dart';
import 'collab_report_sheet.dart';

/// A model choice from the sender's server-populated Ovid Cloud catalog.
class CollabModelChoice {
  const CollabModelChoice(this.providerId, this.model, this.providerName);
  final String providerId;
  final String model;
  final String providerName;

  String get label => model;

  @override
  bool operator ==(Object other) =>
      other is CollabModelChoice &&
      other.providerId == providerId &&
      other.model == model;

  @override
  int get hashCode => Object.hash(providerId, model);
}

/// Models advertised by the sender's Ovid Cloud catalog. Local provider keys
/// and host credentials are never consulted for collaboration.
List<CollabModelChoice> collabModelChoices(AppState app) => [
  for (final p in app.providers)
    if (p.id == AppState.ovidCloudProviderId)
      for (final model in p.models)
        if (model.trim().isNotEmpty) CollabModelChoice(p.id, model, p.name),
];

CollabModelChoice? defaultCollabModel(AppState app) {
  final choices = collabModelChoices(app);
  if (choices.isEmpty) return null;
  for (final choice in choices) {
    if (choice.providerId == app.lastSelectedProviderId &&
        choice.model == app.lastSelectedModel) {
      return choice;
    }
  }
  return choices.first;
}

/// Live multi-user chat for one Collab session.
class CollabSessionScreen extends StatefulWidget {
  const CollabSessionScreen({super.key, this.controller, this.models});

  final CollaborationProduction? controller;

  /// Test seam for the model list; production reads [AppState].
  final List<CollabModelChoice>? models;

  @override
  State<CollabSessionScreen> createState() => _CollabSessionScreenState();
}

class _CollabSessionScreenState extends State<CollabSessionScreen> {
  final _composer = TextEditingController();
  CollabModelChoice? _model;
  List<CollaborationAttachmentInput> _attachments = const [];

  CollaborationProduction? get _controller =>
      widget.controller ?? AppState.I.collaboration;

  List<CollabModelChoice> get _models =>
      widget.models ?? collabModelChoices(AppState.I);

  @override
  void initState() {
    super.initState();
    _model = widget.models != null
        ? (widget.models!.isEmpty ? null : widget.models!.first)
        : defaultCollabModel(AppState.I);
    final controller = _controller;
    if (controller != null) {
      controller.live = true;
      controller.refresh();
    }
  }

  @override
  void dispose() {
    _controller?.live = false;
    _composer.dispose();
    super.dispose();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _pickAttachments() async {
    try {
      final picked = await pickCollaborationAttachments();
      if (picked == null || !mounted) return;
      setState(() => _attachments = [..._attachments, ...picked]);
    } catch (error) {
      _snack(error is StateError ? error.message : 'Could not read that file.');
    }
  }

  void _removeAttachment(int index) {
    setState(() => _attachments = [
      for (var i = 0; i < _attachments.length; i++)
        if (i != index) _attachments[i],
    ]);
  }

  Future<void> _send() async {
    final controller = _controller;
    final model = _model;
    final text = _composer.text.trim();
    if (controller == null || text.isEmpty) return;
    final state = controller.state;
    final holder = state?.session.turn?.holderParticipantId;
    if (holder != null) {
      _snack(holder == state!.localParticipantId
          ? 'Your reply is still running. Send when it finishes.'
          : 'Wait for ${state.nameOf(holder)} to finish the turn.');
      return;
    }
    if (model == null) {
      _snack('No chat model is available for this account.');
      return;
    }
    _composer.clear();
    try {
      await controller.sendTurn(
        text,
        model: model.model,
        attachments: _attachments,
      );
      if (mounted) setState(() => _attachments = const []);
    } catch (error) {
      if (_composer.text.isEmpty) _composer.text = text;
      _snack(collaborationErrorMessage(error));
    }
  }

  Future<void> _pickModel() async {
    final models = _models;
    final picked = await showModalBottomSheet<CollabModelChoice>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => AetherSheet(
        title: 'Your model for this session',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'The server runs your messages with this model on your account. Other members use their own accounts.',
              style: AetherType.bodyMuted,
            ),
            const SizedBox(height: 8),
            if (models.isEmpty)
              Text(
                'No chat models are available for this account.',
                style: AetherType.body,
              ),
            for (final choice in models)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(choice.model),
                subtitle: Text(choice.providerName),
                trailing: choice == _model ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, choice),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _model = picked);
  }

  Future<void> _removeMessage(
    CollaborationProduction controller,
    String messageId,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove this message from the room?'),
        content: const Text('The server keeps canonical history for moderation.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await controller.removeMessage(messageId);
      _snack('Message removed from the room.');
    } catch (error) {
      _snack(collaborationErrorMessage(error));
    }
  }

  Future<void> _openArtifact(
    CollaborationProduction controller,
    String artifactId,
  ) async {
    try {
      final minted = await controller.objectUrl(artifactId: artifactId);
      final opened = await launchUrl(
        minted.url,
        mode: LaunchMode.externalApplication,
      );
      if (!opened) _snack('Could not open the artifact.');
    } catch (error) {
      _snack(collaborationErrorMessage(error));
    }
  }

  Future<void> _openMembers() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => CollabMembersSheet(controller: _controller!),
  );

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const _Unavailable();
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _body(context, controller),
    );
  }

  Widget _body(BuildContext context, CollaborationProduction controller) {
    final state = controller.state;
    final active = state?.activeMembers.length ?? 0;
    final responding = controller.respondingParticipants.toList();
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Live session'),
            if (state != null)
              Text('$active/$maxActiveMembers members', style: AetherType.caption),
          ],
        ),
        actions: [
          if (state != null)
            IconButton(
              tooltip: 'Members and link',
              icon: const Icon(Icons.group_outlined),
              onPressed: _openMembers,
            ),
        ],
      ),
      body: Column(
        children: [
          if (state == null)
            Expanded(
              child: AetherEmptyState(
                icon: Icons.groups_outlined,
                title: controller.sessionToken == null
                    ? 'Not in a live session'
                    : 'Connecting…',
                message: controller.sessionToken == null
                    ? 'Open a Collab link, or share a chat and choose Collab.'
                    : null,
              ),
            )
          else ...[
            if (state.status == CollaborationStatus.closed)
              _Banner(
                text: state.closeReason == CloseReason.localRemoved
                    ? 'You are no longer a member of this session.'
                    : 'The owner ended this live session.',
              )
            else if (state.session.turn != null)
              _Banner(
                text: state.session.turn!.holderParticipantId == state.localParticipantId
                    ? 'Your reply is still running.'
                    : "${state.nameOf(state.session.turn!.holderParticipantId)}'s reply is still running.",
              )
            else if (controller.stale)
              const _Banner(text: 'Reconnecting… messages may be delayed.'),
            Expanded(
              child: state.messages.isEmpty && state.artifacts.isEmpty
                  ? const AetherEmptyState(
                      icon: Icons.forum_outlined,
                      title: 'No messages yet',
                      message: 'Say hello. Everyone in the session sees every message and AI reply.',
                    )
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                      itemCount: state.messages.length + state.artifacts.length,
                      itemBuilder: (context, index) {
                        if (index >= state.messages.length) {
                          final artifact = state.artifacts.values.elementAt(
                            index - state.messages.length,
                          );
                          return CollabArtifactTile(
                            artifact: artifact,
                            onOpen: artifact.artifactId == null
                                ? null
                                : () => _openArtifact(controller, artifact.artifactId!),
                          );
                        }
                        final message = state.messages[state.messages.length - 1 - index];
                        final mine = message.author == state.localParticipantId;
                        return CollabMessageBubble(
                          message: message,
                          authorName: state.nameOf(message.author),
                          mine: mine,
                          // Play UGC policy: other people's messages and
                          // their AI replies can be reported (audit §6).
                          onReport: mine ||
                                  !collaborationIsCanonicalMessageSource(
                                    message.clientEventId,
                                  )
                              ? null
                              : () => showCollaborationReportSheet(
                                  context,
                                  controller,
                                  kind: 'collab_message',
                                  targetId: collaborationCanonicalMessageId(
                                    message.clientEventId,
                                  ),
                                ),
                          onRemove: !controller.isOwner ||
                                  !collaborationIsCanonicalMessageSource(
                                    message.clientEventId,
                                  )
                              ? null
                              : () => _removeMessage(
                                  controller,
                                  collaborationCanonicalMessageId(
                                    message.clientEventId,
                                  ),
                                ),
                        );
                      },
                    ),
            ),
            for (final participant in responding)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        participant == state.localParticipantId
                            ? 'Your model is replying…'
                            : "${state.nameOf(participant)}'s model is replying…",
                        style: AetherType.caption,
                      ),
                    ),
                  ],
                ),
              ),
            if (state.status == CollaborationStatus.live)
              _Composer(
                controller: _composer,
                model: _model,
                busy: controller.turnRunning || state.session.turn != null,
                attachments: _attachments,
                onAttach: _pickAttachments,
                onRemoveAttachment: _removeAttachment,
                onPickModel: _pickModel,
                onSend: _send,
              ),
          ],
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: Aether.warnLight.withValues(alpha: 0.12),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Text(text, style: AetherType.caption),
  );
}

class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Live session')),
    body: const AetherEmptyState(
      icon: Icons.cloud_off_outlined,
      title: 'Live sessions are unavailable',
      message: 'Sign in and try again.',
    ),
  );
}

/// Pinned composer with the sender's OWN model selection.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.model,
    required this.busy,
    required this.attachments,
    required this.onAttach,
    required this.onRemoveAttachment,
    required this.onPickModel,
    required this.onSend,
  });

  final TextEditingController controller;
  final CollabModelChoice? model;
  final bool busy;
  final List<CollaborationAttachmentInput> attachments;
  final VoidCallback onAttach;
  final ValueChanged<int> onRemoveAttachment;
  final VoidCallback onPickModel;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      decoration: BoxDecoration(
        color: Aether.surface,
        border: Border(top: BorderSide(color: Aether.hairline)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ActionChip(
            avatar: const Icon(Icons.auto_awesome_outlined, size: 16),
            label: Text(
              model == null ? 'Choose your model' : 'Your model: ${model!.label}',
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: onPickModel,
          ),
          if (attachments.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var index = 0; index < attachments.length; index++)
                  InputChip(
                    label: Text(attachments[index].name),
                    onDeleted: busy ? null : () => onRemoveAttachment(index),
                  ),
              ],
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Attach files',
                onPressed: busy ? null : onAttach,
                icon: const Icon(Icons.attach_file),
              ),
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    hintText: 'Message everyone…',
                    border: InputBorder.none,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Send',
                onPressed: busy ? null : onSend,
                icon: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// One live message: author name, AI replies labelled with whose model.
class CollabMessageBubble extends StatelessWidget {
  const CollabMessageBubble({
    super.key,
    required this.message,
    required this.authorName,
    required this.mine,
    this.onReport,
    this.onRemove,
  });

  final CollaborationMessage message;
  final String authorName;
  final bool mine;

  /// Opens the content report sheet; null for the user's own messages.
  final VoidCallback? onReport;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final canonicalSource = collaborationIsCanonicalMessageSource(
      message.clientEventId,
    );
    final assistant = message.isAssistant;
    final who = mine ? 'You' : authorName;
    final header = assistant
        ? "$who's AI${message.model == null ? '' : ' · ${message.model}'}"
        : who;
    final alignRight = mine && !assistant;
    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: alignRight
                ? Aether.accent.withValues(alpha: 0.10)
                : assistant
                ? Aether.surfaceAlt
                : Aether.surface,
            borderRadius: BorderRadius.circular(AetherRadius.rMd),
            border: Border.all(color: Aether.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    assistant ? Icons.auto_awesome_outlined : Icons.person_outline,
                    size: 14,
                    color: Aether.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      header,
                      style: AetherType.label,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (canonicalSource && onReport != null)
                    IconButton(
                      tooltip: 'Report message',
                      icon: Icon(
                        Icons.flag_outlined,
                        size: 16,
                        color: Aether.textMuted,
                      ),
                      onPressed: onReport,
                    ),
                  if (canonicalSource && onRemove != null)
                    IconButton(
                      tooltip: 'Remove message',
                      icon: Icon(
                        Icons.delete_outline,
                        size: 16,
                        color: Aether.textMuted,
                      ),
                      onPressed: onRemove,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              ReadOnlyMarkdown(message.text),
            ],
          ),
        ),
      ),
    );
  }
}

class CollabArtifactTile extends StatelessWidget {
  const CollabArtifactTile({
    super.key,
    required this.artifact,
    this.onOpen,
  });

  final CollaborationArtifact artifact;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.data_object_outlined),
        title: Text(artifact.name ?? 'Artifact'),
        subtitle: Text(artifact.sizeBytes == null
            ? 'Size unavailable'
            : '${artifact.sizeBytes} bytes'),
        trailing: onOpen == null ? null : const Icon(Icons.open_in_new),
        onTap: onOpen,
      ),
    );
  }
}

/// Members (names, owner can remove), the share link and leave/end.
class CollabMembersSheet extends StatefulWidget {
  const CollabMembersSheet({super.key, required this.controller});
  final CollaborationProduction controller;

  @override
  State<CollabMembersSheet> createState() => _CollabMembersSheetState();
}

class _CollabMembersSheetState extends State<CollabMembersSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = collaborationErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final state = controller.state;
      final link = controller.shareLink;
      final owner = controller.isOwner;
      final members = state?.activeMembers ?? const <Member>[];
      return FractionallySizedBox(
        heightFactor: .85,
        child: AetherSheet(
          title: 'Members · ${members.length}/$maxActiveMembers',
          actions: [
            AetherGhostButton(label: 'Close', onPressed: () => Navigator.pop(context)),
          ],
          child: ListView(
            shrinkWrap: true,
            children: [
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_error!, style: TextStyle(color: Aether.dangerC)),
                ),
              for (final member in members)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.person_outline),
                  title: Text(
                    member.participantId == state!.localParticipantId
                        ? '${state.nameOf(member.participantId)} (you)'
                        : state.nameOf(member.participantId),
                  ),
                  subtitle: Text(member.role == MemberRole.owner ? 'Owner' : 'Member'),
                  trailing: member.participantId != state.localParticipantId
                      ? Wrap(
                          children: [
                            TextButton(
                              onPressed: () => showCollaborationReportSheet(
                                context,
                                controller,
                                kind: 'collab_participant',
                                targetId: member.participantId,
                              ),
                              child: const Text('Report'),
                            ),
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _run(() => controller.block(member.participantId)),
                              child: const Text('Block'),
                            ),
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _run(() => controller.unblock(member.participantId)),
                              child: const Text('Unblock'),
                            ),
                            if (owner && member.role != MemberRole.owner)
                              TextButton(
                          onPressed: _busy
                              ? null
                              : () async {
                                  final name = state.nameOf(member.participantId);
                                  if (!await _confirm(
                                    'Remove $name?',
                                    '$name leaves the session and cannot rejoin with this link.',
                                    'Remove',
                                  )) {
                                    return;
                                  }
                                  await _run(
                                    () => controller.revokeMember(member.participantId),
                                  );
                                },
                          child: const Text('Remove'),
                        ),
                          ],
                        )
                      : null,
                ),
              if (owner) ...[
                const Divider(height: 24),
                Text('Invite link', style: AetherType.label),
                const SizedBox(height: 6),
                if (link == null)
                  Text(
                    'No active link. Create one to invite people.',
                    style: AetherType.bodyMuted,
                  )
                else
                  SelectableText(link, style: AetherType.mono),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (link != null) ...[
                      AetherGhostButton(
                        label: 'Copy',
                        icon: Icons.copy,
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: link));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Link copied')),
                            );
                          }
                        },
                      ),
                      AetherGhostButton(
                        label: 'Share',
                        icon: Icons.share_outlined,
                        onPressed: () => showNativeShare(
                          context,
                          () => NativeShare.link(link, title: 'Join my live Ovid session'),
                        ),
                      ),
                      AetherDangerButton(
                        label: 'Revoke link',
                        icon: Icons.link_off,
                        onPressed: _busy ? null : () => _run(controller.revokeLink),
                      ),
                    ] else
                      AetherGhostButton(
                        label: 'Create new link',
                        icon: Icons.link,
                        onPressed: _busy ? null : () => _run(controller.newLink),
                      ),
                  ],
                ),
              ],
              const Divider(height: 24),
              AetherDangerButton(
                label: owner ? 'End session for everyone' : 'Leave session',
                icon: owner ? Icons.stop_circle_outlined : Icons.logout,
                onPressed: _busy
                    ? null
                    : () async {
                        if (!await _confirm(
                          owner ? 'End this live session?' : 'Leave this live session?',
                          owner
                              ? 'Everyone is disconnected and the link stops working.'
                              : 'You can rejoin later with a valid link.',
                          owner ? 'End session' : 'Leave',
                        )) {
                          return;
                        }
                        await _run(controller.leaveOrClose);
                        if (mounted && controller.sessionToken == null) {
                          Navigator.of(this.context)
                            ..pop()
                            ..maybePop();
                        }
                      },
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Landing screen for a Collab link: sign in, then join (10-member cap is
/// enforced by the server; the 11th joiner sees "This session is full").
class CollabJoinScreen extends StatefulWidget {
  const CollabJoinScreen({
    super.key,
    required this.token,
    required this.invite,
    this.controller,
  });

  final String token;
  final String invite;
  final CollaborationProduction? controller;

  @override
  State<CollabJoinScreen> createState() => _CollabJoinScreenState();
}

class _CollabJoinScreenState extends State<CollabJoinScreen> {
  bool _busy = false;
  String? _error;

  CollaborationProduction? get _controller =>
      widget.controller ?? AppState.I.collaboration;

  void _openSession() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CollabSessionScreen(controller: widget.controller),
      ),
    );
  }

  Future<void> _join({bool leaveCurrent = false}) async {
    final controller = _controller;
    if (controller == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (leaveCurrent && controller.sessionToken != null) {
        await controller.disconnect();
      }
      await controller.joinLink(widget.token, widget.invite);
      if (mounted) _openSession();
    } catch (error) {
      if (mounted) setState(() => _error = collaborationErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const _Unavailable();
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final current = controller.sessionToken;
        final alreadyHere = current == widget.token;
        final elsewhere = current != null && !alreadyHere;
        final signedIn = widget.controller != null || FirebaseService.I.isSignedIn;
        return Scaffold(
          appBar: AppBar(title: const Text('Join live session')),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Icon(Icons.groups_outlined, size: 48, color: Aether.accent),
              const SizedBox(height: 12),
              Text('You were invited to a live session', style: AetherType.h2),
              const SizedBox(height: 8),
              Text(
                'Up to $maxActiveMembers people chat together. Everyone sees every message and AI reply, labelled with the author\'s name.',
                style: AetherType.body,
              ),
              const SizedBox(height: 8),
              Text(
                'The server runs your messages with the model you choose on your account. Your name from your Ovid account is shown to other members.',
                style: AetherType.bodyMuted,
              ),
              const SizedBox(height: 20),
              if (_error != null)
                AetherCard(
                  color: Aether.danger.withValues(alpha: 0.06),
                  child: Text(_error!, style: TextStyle(color: Aether.dangerC)),
                ),
              if (elsewhere)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'You are in another live session. Joining this one disconnects that session on this device.',
                    style: AetherType.caption.copyWith(color: Aether.warnLight),
                  ),
                ),
              const SizedBox(height: 16),
              if (!signedIn)
                AetherPrimaryButton(
                  label: 'Sign in to join',
                  icon: Icons.login,
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AuthScreen()),
                    );
                    if (mounted) setState(() {});
                  },
                )
              else if (alreadyHere)
                AetherPrimaryButton(
                  label: 'Open live session',
                  icon: Icons.forum_outlined,
                  onPressed: _openSession,
                )
              else if (!controller.available)
                Column(
                  children: [
                    const LinearProgressIndicator(minHeight: 2),
                    const SizedBox(height: 8),
                    Text('Getting your account ready…', style: AetherType.caption),
                  ],
                )
              else
                AetherPrimaryButton(
                  label: _busy
                      ? 'Joining…'
                      : elsewhere
                      ? 'Leave other session and join'
                      : 'Join live session',
                  icon: Icons.group_add_outlined,
                  loading: _busy,
                  onPressed: _busy ? null : () => _join(leaveCurrent: elsewhere),
                ),
            ],
          ),
        );
      },
    );
  }
}
