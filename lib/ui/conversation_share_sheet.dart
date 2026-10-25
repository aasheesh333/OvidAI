import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart' as qr;

import '../core/collaboration/models.dart' show maxActiveMembers;
import '../core/collaboration/production.dart';
import '../core/conversation_share_service.dart';
import '../core/firebase_service.dart';
import '../core/native_share.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'auth_screen.dart';
import 'collab_session_screen.dart';
import 'share_actions.dart';
import 'widgets/aether_confirm.dart';
import 'widgets/aether_primitives.dart';

/// The two ways to share a chat session.
enum ShareMode { readOnly, collab }

Future<void> showConversationShareSheet(
  BuildContext context,
  ChatSession session, {
  ShareMode? initialMode,
  List<Message>? messages,
}) {
  return showAetherSheet<void>(
    context: context,
    builder: (_) => FractionallySizedBox(
      heightFactor: .92,
      child: ConversationShareSheet(
        session: session,
        service: ConversationShareService.production(),
        serviceFactory: ConversationShareService.production,
        initialMode: initialMode,
        messages: messages,
      ),
    ),
  );
}

/// Share sheet: first choose Read only or Collab, then manage that link.
class ConversationShareSheet extends StatefulWidget {
  const ConversationShareSheet({
    super.key,
    required this.session,
    required this.service,
    this.serviceFactory,
    this.collaboration,
    this.initialMode,
    this.messages,
  });
  final ChatSession session;
  final ConversationShareService service;

  /// Rebuilds the account-bound service after an in-sheet sign in (F-186).
  final ConversationShareService Function()? serviceFactory;

  /// Live-session owner; production uses [AppState.collaboration].
  final CollaborationProduction? collaboration;
  final ShareMode? initialMode;

  /// The transcript to snapshot — the facade's live projection for a cloud
  /// session (its `ChatSession.messages` stays empty). Null keeps the
  /// session's own rows.
  final List<Message>? messages;

  @override
  State<ConversationShareSheet> createState() => _ConversationShareSheetState();
}

class _ConversationShareSheetState extends State<ConversationShareSheet> {
  late ShareMode? _mode = widget.initialMode;
  late ConversationShareService _service = widget.service;
  int _serviceGeneration = 0;

  CollaborationProduction? get _collaboration =>
      widget.collaboration ?? AppState.I.collaboration;

  Future<void> _signIn() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AuthScreen()),
    );
    if (!mounted) return;
    final factory = widget.serviceFactory;
    setState(() {
      if (factory != null) _service = factory();
      _serviceGeneration++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final mode = _mode;
    return AetherSheet(
      title: switch (mode) {
        null => 'Share this chat',
        ShareMode.readOnly => 'Read-only link',
        ShareMode.collab => 'Collab link',
      },
      actions: [
        if (mode != null && widget.initialMode == null)
          AetherGhostButton(
            label: 'Back',
            icon: Icons.arrow_back,
            onPressed: () => setState(() => _mode = null),
          ),
        AetherGhostButton(
          label: 'Close',
          onPressed: () => Navigator.pop(context),
        ),
      ],
      child: switch (mode) {
        null => _ModeChooser(onPick: (value) => setState(() => _mode = value)),
        ShareMode.readOnly => _ReadOnlyPanel(
          key: ValueKey(_serviceGeneration),
          session: widget.session,
          service: _service,
          messages: widget.messages,
          onSignIn: _signIn,
        ),
        ShareMode.collab => _CollabPanel(
          session: widget.session,
          controller: _collaboration,
          messages: widget.messages,
          onSignIn: _signIn,
        ),
      },
    );
  }
}

class _ModeChooser extends StatelessWidget {
  const _ModeChooser({required this.onPick});
  final ValueChanged<ShareMode> onPick;

  // Scrolls: AetherSheet clamps its body (PR-6b), and the two mode cards
  // overflow a 360x640 phone at large text otherwise.
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        'Pick how people can use the link.',
        style: AetherType.bodyMuted,
      ),
      const SizedBox(height: 12),
      _ModeCard(
        icon: Icons.visibility_outlined,
        title: 'Read only',
        body:
            'Anyone with the link can read this chat. Update the link to share newer messages.',
        onTap: () => onPick(ShareMode.readOnly),
      ),
      const SizedBox(height: 10),
      _ModeCard(
        icon: Icons.groups_outlined,
        title: 'Collab',
        body:
            'Up to $maxActiveMembers people (you included) chat live in this session. Messages show each author\'s name, and every person\'s turns use their own model and account.',
        onTap: () => onPick(ShareMode.collab),
      ),
    ],
    ),
  );
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: title,
    child: InkWell(
      borderRadius: BorderRadius.circular(AetherRadius.rMd),
      onTap: onTap,
      child: AetherCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Aether.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AetherType.title),
                  const SizedBox(height: 4),
                  Text(body, style: AetherType.bodyMuted),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: Aether.textMuted),
          ],
        ),
      ),
    ),
  );
}

/// Collab: start a live session from this chat, then manage its link.
class _CollabPanel extends StatefulWidget {
  const _CollabPanel({
    required this.session,
    required this.controller,
    required this.onSignIn,
    this.messages,
  });
  final ChatSession session;
  final CollaborationProduction? controller;
  final VoidCallback onSignIn;

  /// The facade's live projection for a cloud session (null = own rows).
  final List<Message>? messages;

  @override
  State<_CollabPanel> createState() => _CollabPanelState();
}

class _CollabPanelState extends State<_CollabPanel> {
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

  Future<void> _start(CollaborationProduction controller) => _run(() async {
    await controller.startFromConversation(
      sourceSessionId: widget.session.id,
    );
  });

  void _open(CollaborationProduction controller) {
    final navigator = Navigator.of(context, rootNavigator: true);
    Navigator.pop(context);
    navigator.push(
      MaterialPageRoute(
        builder: (_) => CollabSessionScreen(controller: widget.controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller == null || !controller.configured) {
      return Text(
        'Live sessions are unavailable in this build.',
        style: AetherType.body.copyWith(color: Aether.warn),
      );
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _body(context, controller),
    );
  }

  Widget _body(BuildContext context, CollaborationProduction controller) {
    final children = <Widget>[];
    if (_busy) {
      children.add(const LinearProgressIndicator(minHeight: 2));
    }
    if (_error != null) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(_error!, style: TextStyle(color: Aether.danger)),
        ),
      );
    }
    final current = controller.sessionToken;
    final mine = current != null &&
        controller.isOwner &&
        controller.sourceSessionId == widget.session.id;
    if (!FirebaseService.I.isSignedIn && widget.controller == null) {
      children.add(_SignInCard(onSignIn: widget.onSignIn, what: 'start a live session'));
    } else if (!controller.available) {
      children.add(Text('Getting your account ready…', style: AetherType.bodyMuted));
    } else if (mine) {
      final link = controller.shareLink;
      final members = controller.state?.activeMembers.length ?? 1;
      children.addAll([
        if (link != null)
          _LinkCard(
            url: link,
            label: 'Collab link',
            pill: '$members/$maxActiveMembers',
            busy: _busy,
            onRevoke: () => _run(controller.revokeLink),
            shareTitle: 'Join my live Ovid session',
          )
        else
          AetherCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('The link was revoked. Members who joined stay in the session.',
                    style: AetherType.bodyMuted),
                const SizedBox(height: 8),
                AetherGhostButton(
                  label: 'Create new link',
                  icon: Icons.link,
                  onPressed: _busy ? null : () => _run(controller.newLink),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        AetherPrimaryButton(
          label: 'Open live session',
          icon: Icons.forum_outlined,
          onPressed: () => _open(controller),
        ),
      ]);
    } else if (current != null) {
      children.addAll([
        Text(
          'You are already in a live session. Leave it before starting a new one.',
          style: AetherType.body,
        ),
        const SizedBox(height: 12),
        AetherPrimaryButton(
          label: 'Open current live session',
          icon: Icons.forum_outlined,
          onPressed: () => _open(controller),
        ),
      ]);
    } else {
      children.addAll([
        AetherCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Chat live together', style: AetherType.title),
              const SizedBox(height: 6),
              Text(
                'Up to $maxActiveMembers people, you included, can join with the link. Everyone sees every message and AI reply, each labelled with the author\'s name.',
                style: AetherType.bodyMuted,
              ),
              const SizedBox(height: 8),
              Text(
                'Collab uses this chat\'s existing server history; no local history is uploaded.',
                style: AetherType.caption.copyWith(height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        AetherPrimaryButton(
          label: 'Start Collab and create link',
          icon: Icons.group_add_outlined,
          loading: _busy,
          onPressed: _busy ? null : () => _start(controller),
        ),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

class _SignInCard extends StatelessWidget {
  const _SignInCard({required this.onSignIn, required this.what});
  final VoidCallback onSignIn;
  final String what;

  @override
  Widget build(BuildContext context) => AetherCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Sign in to $what', style: AetherType.title),
        const SizedBox(height: 6),
        Text(
          'Links belong to your Ovid account so you can revoke them later.',
          style: AetherType.bodyMuted,
        ),
        const SizedBox(height: 10),
        AetherPrimaryButton(label: 'Sign in', icon: Icons.login, onPressed: onSignIn),
      ],
    ),
  );
}

/// QR + URL + Copy / Share / Revoke for a link.
class _LinkCard extends StatelessWidget {
  const _LinkCard({
    required this.url,
    required this.label,
    required this.pill,
    required this.busy,
    required this.onRevoke,
    required this.shareTitle,
  });
  final String url;
  final String label;
  final String pill;
  final bool busy;
  final VoidCallback onRevoke;
  final String shareTitle;

  @override
  Widget build(BuildContext context) => AetherCard(
    title: Text(label, style: AetherType.title),
    trailing: AetherPill(label: pill, color: Aether.success, icon: Icons.group_outlined),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(AetherRadius.rMd),
              border: Border.all(color: Aether.hairline),
            ),
            child: Semantics(
              image: true,
              label: 'QR code for $label',
              child: _QrCode(data: url, size: 180),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SelectableText(url, style: AetherType.mono.copyWith(color: Aether.text)),
        const SizedBox(height: 12),
        _ShareActions(
          busy: busy,
          onCopy: () async {
            await Clipboard.setData(ClipboardData(text: url));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Link copied')),
              );
            }
          },
          onShare: () => showNativeShare(
            context,
            () => NativeShare.link(url, title: shareTitle),
          ),
          onRevoke: onRevoke,
          revokeLabel: 'Revoke link',
        ),
      ],
    ),
  );
}

class _ReadOnlyPanel extends StatefulWidget {
  const _ReadOnlyPanel({
    super.key,
    required this.session,
    required this.service,
    required this.onSignIn,
    this.messages,
  });
  final ChatSession session;
  final ConversationShareService service;
  final VoidCallback onSignIn;

  /// The facade's live projection for a cloud session (null = own rows).
  final List<Message>? messages;

  @override
  State<_ReadOnlyPanel> createState() => _ReadOnlyPanelState();
}

class _ReadOnlyPanelState extends State<_ReadOnlyPanel> {
  // The identity binding and frozen preview share the same lifetime.
  late final _service = widget.service;
  late final _snapshot = ConversationSnapshot.fromSession(
    widget.session,
    messages: widget.messages,
  );
  String _requestId = ConversationShareService.newRequestId();
  List<ConversationShare> _shares = [];
  bool _busy = false;
  bool _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Freeze the exact preview before any asynchronous server work.
    _snapshot;
    if (_service.available && _service.signedIn) _refresh();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is ConversationShareException
              ? error.message
              : 'Could not complete sharing. Please retry.';
          if (!_service.ownerIsCurrent) _shares = [];
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() => _run(() async {
    final shares = await _service.list(_snapshot.sessionId);
    if (mounted) {
      setState(() {
        _shares = shares;
        // A matching owner-only receipt conclusively resolves a lost response.
        if (shares.any((share) => share.requestId == _requestId)) {
          _requestId = ConversationShareService.newRequestId();
        }
        _loaded = true;
      });
    }
  });

  Future<void> _create() => _run(() async {
    final share = await _service.create(_snapshot, requestId: _requestId);
    if (mounted) {
      setState(() {
        _shares = [share, ..._shares.where((s) => s.id != share.id)];
        // Only advance the request ID after confirmed success.
        _requestId = ConversationShareService.newRequestId();
      });
    }
  });

  /// Republish the current chat to the same link (F-183), confirmed first.
  Future<void> _update(ConversationShare share) async {
    final ok = await showAetherSheet<bool>(
      context: context,
      builder: (context) => AetherSheet(
        title: 'Update link?',
        actions: [
          AetherGhostButton(
            label: 'Cancel',
            onPressed: () => Navigator.pop(context, false),
          ),
          AetherPrimaryButton(
            label: 'Update',
            icon: Icons.sync,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
        child: Text(
          'People with this link will see the chat as it is now. The link itself does not change.',
          style: AetherType.body,
        ),
      ),
    );
    if (ok != true) return;
    await _run(() async {
      final updated = await _service.update(
        share.id,
        _snapshot,
        requestId: ConversationShareService.newRequestId(),
      );
      if (!mounted) return;
      setState(() {
        _shares = [updated, ..._shares.where((s) => s.id != updated.id)];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link updated')),
      );
    });
  }

  Future<void> _share(ConversationShare share) => showNativeShare(
    context,
    () => NativeShare.link(share.url.toString(), title: 'Share chat link'),
  );

  /// Revoking deletes the public link for everyone, so it confirms first
  /// (F-069).
  Future<void> _revoke(ConversationShare share) async {
    final ok = await showAetherConfirmDialog(
      context,
      title: 'Revoke this link?',
      message:
          'People with this link will no longer be able to open it. You can '
          'create a new link later, but it will have a different address.',
      confirmLabel: 'Revoke link',
    );
    if (!ok || !mounted) return;
    await _revokeNow(share);
  }

  Future<void> _revokeNow(ConversationShare share) => _run(() async {
    await _service.revoke(share.id);
    if (mounted) setState(() => _shares.removeWhere((s) => s.id == share.id));
  });

  Future<void> _copy(ConversationShare share) => _run(() async {
    // Revalidate ownership and revocation before copying a displayed receipt.
    final current = await _service.list(_snapshot.sessionId);
    if (!mounted) return;
    setState(() => _shares = current);
    if (!current.any((s) => s.id == share.id)) {
      throw const ConversationShareException(
        'This link is no longer available.',
      );
    }
    await Clipboard.setData(ClipboardData(text: share.url.toString()));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Link copied')));
    }
  });

  @override
  Widget build(BuildContext context) {
    final available = _service.available;
    final activeShare = _shares.isEmpty ? null : _shares.first;
    if (available && !_service.signedIn) {
      return _SignInCard(onSignIn: widget.onSignIn, what: 'create links');
    }

    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                if (activeShare != null)
                  _ActiveShareCard(
                    share: activeShare,
                    busy: _busy,
                    onCopy: () => _copy(activeShare),
                    onShare: () => _share(activeShare),
                    onUpdate: _snapshot.withinLimits
                        ? () => _update(activeShare)
                        : null,
                    onRevoke: () => _revoke(activeShare),
                  )
                else
                  AetherCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Create a read-only link',
                          style: AetherType.title,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Anyone with the link can read this chat as it is now. Use Update link later to share newer messages.',
                          style: AetherType.bodyMuted,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Only the messages below are shared. Thinking, tools, internal context, detected credentials, attachments and session metadata are excluded. Review the text for personal information.',
                          style: AetherType.caption.copyWith(height: 1.5),
                        ),
                        if (!available) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Sharing is unavailable: deployment is not configured.',
                            style: AetherType.body.copyWith(
                              color: Aether.warn,
                            ),
                          ),
                        ],
                        if (_loaded && _shares.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              'No active links for this session.',
                              style: AetherType.bodyMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  AetherCard(
                    color: Aether.danger.withValues(alpha: 0.06),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.error_outline,
                              size: 16,
                              color: Aether.danger,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _error!,
                                style: AetherType.body.copyWith(
                                  color: Aether.danger,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (!_loaded)
                          AetherGhostButton(
                            label: 'Retry',
                            icon: Icons.refresh,
                            onPressed: available && !_busy ? _refresh : null,
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                AetherCard(
                  title: Text(
                    activeShare == null
                        ? 'Preview · ${_snapshot.messages.length} messages'
                        : 'Current chat (not yet shared) · ${_snapshot.messages.length} messages',
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final message in _snapshot.messages)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                message.role == 'user' ? 'You' : 'Assistant',
                                style: AetherType.label,
                              ),
                              const SizedBox(height: 4),
                              Text(message.content, style: AetherType.body),
                            ],
                          ),
                        ),
                      if (!_snapshot.withinLimits)
                        Text(
                          'No shareable text, or snapshot exceeds the 500-message / 200 KB / 20,000-character-per-message limit.',
                          style: AetherType.caption.copyWith(
                            color: Aether.warn,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Existing links', style: AetherType.label),
                    AetherGhostButton(
                      label: 'Refresh',
                      icon: Icons.refresh,
                      onPressed: available && !_busy ? _refresh : null,
                    ),
                  ],
                ),
                if (_loaded && _shares.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'No active links for this session.',
                      style: AetherType.bodyMuted,
                    ),
                  ),
                for (final share in _shares.skip(activeShare == null ? 0 : 1))
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _ShareLinkRow(
                      share: share,
                      busy: _busy,
                      onCopy: () => _copy(share),
                      onRevoke: () => _revoke(share),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          AetherPrimaryButton(
            label: 'Create link',
            icon: Icons.link,
            onPressed:
                available &&
                    _loaded &&
                    !_busy &&
                    _snapshot.withinLimits &&
                    _shares.isEmpty
                ? _create
                : null,
          ),
        ],
    );
  }
}

class _ActiveShareCard extends StatelessWidget {
  const _ActiveShareCard({
    required this.share,
    required this.busy,
    required this.onCopy,
    required this.onRevoke,
    this.onShare,
    this.onUpdate,
  });
  final ConversationShare share;
  final bool busy;
  final VoidCallback onCopy;
  final VoidCallback onRevoke;
  final VoidCallback? onShare;
  final VoidCallback? onUpdate;

  @override
  Widget build(BuildContext context) {
    final url = share.url.toString();
    final expires = share.expiresAt.toLocal().toString().split('.').first;
    return AetherCard(
      title: Text('Shareable link', style: AetherType.title),
      trailing: AetherPill(
        label: 'LIVE',
        color: Aether.success,
        icon: Icons.check_circle_outline,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AetherRadius.rMd),
                border: Border.all(color: Aether.hairline),
              ),
              child: Semantics(
                image: true,
                label: 'QR code for shared conversation',
                child: _QrCode(data: url, size: 180),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Aether.surfaceAlt,
              borderRadius: BorderRadius.circular(AetherRadius.rMd),
              border: Border.all(color: Aether.hairline),
            ),
            child: SelectableText(
              url,
              style: AetherType.mono.copyWith(color: Aether.text),
            ),
          ),
          const SizedBox(height: 8),
          Text('Expires $expires', style: AetherType.caption),
          const SizedBox(height: 14),
          _ShareActions(
            busy: busy,
            onCopy: onCopy,
            onShare: onShare,
            onRevoke: onRevoke,
          ),
          if (onUpdate != null) ...[
            const SizedBox(height: 8),
            AetherGhostButton(
              label: 'Update link',
              icon: Icons.sync,
              onPressed: busy ? null : onUpdate,
            ),
          ],
        ],
      ),
    );
  }
}

class _ShareLinkRow extends StatelessWidget {
  const _ShareLinkRow({
    required this.share,
    required this.busy,
    required this.onCopy,
    required this.onRevoke,
  });
  final ConversationShare share;
  final bool busy;
  final VoidCallback onCopy;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final expires = share.expiresAt.toLocal().toString().split('.').first;
    return AetherCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            share.url.toString(),
            style: AetherType.body,
          ),
          const SizedBox(height: 6),
          Text('Expires $expires', style: AetherType.caption),
          const SizedBox(height: 10),
          _ShareActions(
            busy: busy,
            onCopy: onCopy,
            onRevoke: onRevoke,
          ),
        ],
      ),
    );
  }
}

class _ShareActions extends StatelessWidget {
  const _ShareActions({
    required this.busy,
    required this.onCopy,
    required this.onRevoke,
    this.onShare,
    this.revokeLabel = 'Revoke',
  });
  final bool busy;
  final VoidCallback onCopy;
  final VoidCallback onRevoke;
  final VoidCallback? onShare;
  final String revokeLabel;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final buttons = <Widget>[
        AetherGhostButton(
          label: 'Copy link',
          icon: Icons.copy,
          onPressed: busy ? null : onCopy,
        ),
        if (onShare != null)
          AetherGhostButton(
            label: 'Share',
            icon: Icons.share_outlined,
            onPressed: busy ? null : onShare,
          ),
        AetherDangerButton(
          label: revokeLabel,
          icon: Icons.link_off,
          onPressed: busy ? null : onRevoke,
        ),
      ];
      // Each label needs its scaled text, icon, gap and button padding.
      final actionWidth =
          180 * buttons.length * MediaQuery.textScalerOf(context).scale(14) / 14;
      if (constraints.maxWidth < actionWidth) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < buttons.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              buttons[i],
            ],
          ],
        );
      }
      return Row(
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(child: buttons[i]),
          ],
        ],
      );
    },
  );
}

/// Pure-Dart QR renderer. Encodes [data] into a QrCode and paints it to a
/// crisp monochrome bitmap-style grid. Uses the already-vendored `qr`
/// package so no new dependency is introduced.
class _QrCode extends StatelessWidget {
  const _QrCode({required this.data, this.size = 160});
  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final qr.QrImage image;
    try {
      final code = qr.QrCode(
        payload: qr.QrPayload.fromString(data),
        errorCorrectLevel: qr.QrErrorCorrectLevel.medium,
      );
      image = qr.QrImage(code);
    } catch (_) {
      // An icon alone could be mistaken for a usable QR code.
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Text(
            'QR unavailable. Use Copy link.',
            textAlign: TextAlign.center,
            style: AetherType.body.copyWith(color: Colors.black),
          ),
        ),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _QrPainter(image)),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);
  final qr.QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    // QR requires a four-module quiet zone even for low-version short URLs.
    final cellSize = size.shortestSide / (image.moduleCount + 8);
    final paint = Paint()..color = const Color(0xFF0F1115);
    for (var x = 0; x < image.moduleCount; x++) {
      for (var y = 0; y < image.moduleCount; y++) {
        if (image.isDark(y, x)) {
          canvas.drawRect(
            Rect.fromLTWH(
              (x + 4) * cellSize,
              (y + 4) * cellSize,
              cellSize,
              cellSize,
            ),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter old) => old.image != image;
}
