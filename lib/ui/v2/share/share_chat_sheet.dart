import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import '../chat/message_blocks.dart';
import 'share_sheet.dart';

// TODO(l10n): extract this screen's English copy during the ARB pass.

/// How a shared chat link can no longer be used.
enum V2SharedChatAvailability { live, expired, revoked }

/// What a transcript row is.
///
/// [thinking] and [tool] rows are progress, not answers: the viewer renders
/// them as one quiet line and never expands them. A shared snapshot is
/// read-only, so no row exposes a composer, send, edit or delete control.
enum V2SharedChatRole { user, assistant, thinking, tool }

/// One immutable row in a shared, read-only transcript.
@immutable
class V2SharedChatMessage {
  const V2SharedChatMessage({
    required this.id,
    required this.role,
    required this.text,
  });

  /// Stable identity, used as the list key so a rebuild reuses the row.
  final String id;

  final V2SharedChatRole role;

  /// Plain text for [V2SharedChatRole.user], markdown for
  /// [V2SharedChatRole.assistant], and the already-collapsed label for
  /// [V2SharedChatRole.thinking] / [V2SharedChatRole.tool].
  final String text;
}

/// The fork operation a shared chat host can really perform.
///
/// It receives the server-side share id and returns the id of the new session
/// created in the recipient's account.
typedef V2ShareChatForkHandler = Future<String> Function(String shareId);

/// Immutable state for [ShareChatSheet].
///
/// The sheet has two roles. A creator gets the link-management surface
/// ([viewerCanFork] false); a recipient gets the read-only transcript and one
/// Fork action ([viewerCanFork] true).
@immutable
class V2ShareChatSheetData {
  const V2ShareChatSheetData({
    required this.link,
    this.shareId = '',
    this.mode = V2ShareMode.readOnly,
    this.memberCount = 1,
    this.viewerCanFork = false,
    this.canChangeMode = true,
    this.active = true,
    this.copied = false,
    this.creatorName = '',
    this.status = V2ShareStatus.ready,
    this.errorMessage = 'We could not load the share link.',
    this.revoked = false,
    this.collabAvailable = true,
    this.collabUnavailableReason,
    this.readOnlyAvailable = true,
    this.readOnlyUnavailableReason,
    this.transcript = const <V2SharedChatMessage>[],
    this.availability = V2SharedChatAvailability.live,
  }) : assert(memberCount >= 1, 'A shared room always has at least one member');

  /// The read-only link shown to its creator, for example
  /// `ovidsi.com/c/79f9b4c0e`. Recipients fork by [shareId], not by URL.
  final String link;

  /// The server-side share id handed to [V2ShareChatForkHandler]. Empty falls
  /// back to [link], which keeps older hosts that stored the id there working.
  final String shareId;

  /// Collab (live, capped, one sender) or Read only (forkable snapshot).
  final V2ShareMode mode;

  /// People in the Collab room, including the creator.
  final int memberCount;

  /// True when the person reading this sheet opened someone else's read-only
  /// link rather than sharing their own chat.
  final bool viewerCanFork;

  /// False when the current person cannot switch the mode (for example a
  /// member who joined someone else's room).
  final bool canChangeMode;

  /// Whether the creator's link is currently live.
  final bool active;

  /// Whether the link was just copied, for the short confirmation.
  final bool copied;

  /// Name shown on a shared page. Empty keeps the header to one line.
  final String creatorName;

  /// Load state for the link and its transcript.
  final V2ShareStatus status;

  final String errorMessage;

  /// True when the creator revoked the link. Forwarded to the owner sheet so
  /// it does not have to infer a revocation from the link disappearing.
  final bool revoked;

  /// Whether the service that creates Collab rooms is available. An
  /// unavailable mode is disabled with [collabUnavailableReason] instead of
  /// failing after the person selects it.
  final bool collabAvailable;
  final String? collabUnavailableReason;

  /// Whether the read-only share service is available.
  final bool readOnlyAvailable;
  final String? readOnlyUnavailableReason;

  /// Recipient-only transcript. The owner share surface ignores it.
  final List<V2SharedChatMessage> transcript;

  /// Recipient-only link state. Expired and revoked links never render an
  /// empty transcript in place of the honest reason.
  final V2SharedChatAvailability availability;
}

/// The read-only shared chat view, or the creator's share sheet.
///
/// A recipient sees one header, one read-only banner and one Fork action. The
/// transcript is lazy, has no composer or mutation controls, and collapses tool
/// and thinking rows to a single line. The creator path keeps the existing
/// link-management sheet, so the app shell needs no special case.
class ShareChatSheet extends StatefulWidget {
  const ShareChatSheet({
    super.key,
    required this.data,
    this.onCopyLink,
    this.onModeChanged,
    this.onFork,
    this.onForked,
    this.onStopSharing,
    this.onCreateLink,
    this.onCreateLinkForMode,
    this.onRetry,
    this.onClose,
  });

  final V2ShareChatSheetData data;

  /// Creator-only: copy the link.
  final VoidCallback? onCopyLink;

  /// Creator-only: switch between Collab and Read only.
  final ValueChanged<V2ShareMode>? onModeChanged;

  /// Recipient-only: fork by share id and return the new session id.
  final V2ShareChatForkHandler? onFork;

  /// Called once with the new session id after a successful fork. Hosts that
  /// navigate to the copy use this; [onFork]'s return value is the same id.
  final ValueChanged<String>? onForked;

  /// Creator-only: revoke the link.
  final VoidCallback? onStopSharing;

  /// Creator-only: create a link for a chat that is not shared yet.
  final VoidCallback? onCreateLink;

  /// Creator-only: create a link for an explicit mode. Preferred over
  /// [onCreateLink] because Collab and Read only must not share a branch.
  final ValueChanged<V2ShareMode>? onCreateLinkForMode;

  /// Reload the link or transcript after a failure.
  final VoidCallback? onRetry;

  final VoidCallback? onClose;

  @override
  State<ShareChatSheet> createState() => _ShareChatSheetState();
}

class _ShareChatSheetState extends State<ShareChatSheet> {
  bool _forking = false;
  String? _forkError;
  String? _forkedSessionId;

  /// Bumped whenever the underlying share changes or the widget is disposed,
  /// so a completed fork never lands on a different link.
  int _forkGeneration = 0;

  String get _shareId {
    final id = widget.data.shareId.trim();
    return id.isEmpty ? widget.data.link.trim() : id;
  }

  bool get _viewer => widget.data.viewerCanFork;

  bool get _linkIsLive =>
      widget.data.status == V2ShareStatus.ready &&
      widget.data.availability == V2SharedChatAvailability.live;

  bool get _canFork =>
      _viewer &&
      _linkIsLive &&
      widget.data.mode == V2ShareMode.readOnly &&
      widget.onFork != null &&
      _shareId.isNotEmpty &&
      widget.data.transcript.isNotEmpty;

  @override
  void didUpdateWidget(covariant ShareChatSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed =
        oldWidget.data.shareId != widget.data.shareId ||
        oldWidget.data.link != widget.data.link ||
        oldWidget.data.mode != widget.data.mode ||
        oldWidget.data.viewerCanFork != widget.data.viewerCanFork ||
        oldWidget.data.status != widget.data.status ||
        oldWidget.data.availability != widget.data.availability;
    if (!changed) return;
    _forkGeneration++;
    _forking = false;
    _forkError = null;
    _forkedSessionId = null;
  }

  @override
  void dispose() {
    _forkGeneration++;
    super.dispose();
  }

  Future<void> _fork() async {
    final handler = widget.onFork;
    final shareId = _shareId;
    if (_forking || handler == null || shareId.isEmpty) return;
    final generation = ++_forkGeneration;
    setState(() {
      _forking = true;
      _forkError = null;
      _forkedSessionId = null;
    });
    try {
      final sessionId = (await handler(shareId)).trim();
      if (sessionId.isEmpty) {
        throw const FormatException('The fork returned no session id.');
      }
      if (!mounted || generation != _forkGeneration || shareId != _shareId) {
        return;
      }
      setState(() {
        _forking = false;
        _forkedSessionId = sessionId;
      });
      widget.onForked?.call(sessionId);
    } catch (error) {
      if (!mounted || generation != _forkGeneration || shareId != _shareId) {
        return;
      }
      setState(() {
        _forking = false;
        _forkError = _reason(error);
      });
    }
  }

  /// The server exception already carries a person-readable reason. Other
  /// errors keep theirs after stripping the class prefix, with an honest
  /// fallback for an empty message.
  static String _reason(Object error) {
    final text = error.toString().trim().replaceFirst(
      RegExp(r'^(?:Exception|Error):\s*'),
      '',
    );
    return text.isEmpty ? 'Could not fork this chat. Try again.' : text;
  }

  @override
  Widget build(BuildContext context) {
    if (!_viewer) return _buildOwner();
    return _buildViewer(context);
  }

  /// The creator keeps the existing minimal link sheet. All state and actions
  /// remain injected; this screen adds no second copy of the share surface.
  Widget _buildOwner() {
    return ShareSheet(
      // A mode change is a different sheet, not a revocation: remounting
      // prevents the sheet's local "link went away" inference from painting a
      // revoked card while the host loads the newly selected mode.
      key: ValueKey<V2ShareMode>(widget.data.mode),
      data: V2ShareSheetData(
        link: widget.data.link,
        mode: widget.data.mode,
        memberCount: widget.data.memberCount,
        creatorName: widget.data.creatorName.isEmpty
            ? 'you'
            : widget.data.creatorName,
        canChangeMode: widget.data.canChangeMode,
        active: widget.data.active,
        copied: widget.data.copied,
        status: widget.data.status,
        errorMessage: widget.data.errorMessage,
        revoked: widget.data.revoked,
        collabAvailable: widget.data.collabAvailable,
        collabUnavailableReason: widget.data.collabUnavailableReason,
        readOnlyAvailable: widget.data.readOnlyAvailable,
        readOnlyUnavailableReason: widget.data.readOnlyUnavailableReason,
      ),
      onCopyLink: widget.onCopyLink,
      onModeChanged: widget.onModeChanged,
      onStopSharing: widget.onStopSharing,
      onCreateLink: widget.onCreateLink,
      onCreateLinkForMode: widget.onCreateLinkForMode,
      onRetry: widget.onRetry,
      onClose: widget.onClose,
      title: 'Share this chat',
    );
  }

  Widget _buildViewer(BuildContext context) {
    final name = widget.data.creatorName.trim();
    return OContent(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSheetHeader(
            title: 'Shared chat',
            subtitle: name.isEmpty ? null : 'Shared by $name',
            closeLabel: 'Close shared chat',
            onClose: widget.onClose,
            padding: const EdgeInsets.only(bottom: OSpace.s),
          ),
          if (_linkIsLive) ...[
            const _ReadOnlyBanner(),
            const SizedBox(height: OSpace.s),
          ],
          Expanded(child: _body(context)),
          if (_forkError != null)
            _ForkErrorBar(
              reason: _forkError!,
              onRetry: _canFork ? () => unawaited(_fork()) : null,
            ),
          ?_footer(context),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (widget.data.status == V2ShareStatus.loading) {
      return const OSkeletonList(rows: 5);
    }
    if (widget.data.status == V2ShareStatus.error) {
      return OErrorState(
        message: widget.data.errorMessage,
        onRetry: widget.onRetry,
      );
    }
    switch (widget.data.availability) {
      case V2SharedChatAvailability.expired:
        return const _UnavailableLine(
          icon: Icons.schedule_rounded,
          label: 'Link expired',
        );
      case V2SharedChatAvailability.revoked:
        return const _UnavailableLine(
          icon: Icons.link_off_rounded,
          label: 'Link revoked',
        );
      case V2SharedChatAvailability.live:
        break;
    }
    if (widget.data.transcript.isEmpty) {
      return const OEmptyState(
        icon: Icons.forum_outlined,
        title: 'No messages',
        message: 'This chat has no messages.',
        compact: true,
      );
    }
    return _Transcript(rows: widget.data.transcript);
  }

  /// Exactly one primary action: Fork while the link is live, a quiet
  /// confirmation after a successful fork, and nothing while a failure bar is
  /// offering Retry. A null handler removes the control instead of disabling a
  /// feature that does not exist.
  Widget? _footer(BuildContext context) {
    if (!_linkIsLive) return null;
    if (_forkedSessionId != null) {
      return const Padding(
        padding: EdgeInsets.only(top: OSpace.s, bottom: OSpace.m),
        child: _ForkedLine(),
      );
    }
    if (_forkError != null || !_canFork) return null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.m),
        child: OButton(
          label: 'Fork',
          icon: Icons.account_tree_rounded,
          expand: true,
          loading: _forking,
          onPressed: () => unawaited(_fork()),
        ),
      ),
    );
  }
}

/// One quiet, announced line that says the transcript may be read but never
/// changed. It is not interactive, so it carries no enabled state.
class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      label: 'Read only',
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minHeight: OSpace.touch),
          padding: const EdgeInsets.symmetric(horizontal: OSpace.m),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(ORadius.m),
            border: Border.all(color: c.hairline),
          ),
          child: Row(
            children: [
              Icon(Icons.lock_outline_rounded, size: 18, color: c.textMuted),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  'Read only',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.label.copyWith(color: c.text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The lazy transcript. A five-thousand-message share builds only the rows in
/// and around the viewport.
class _Transcript extends StatelessWidget {
  const _Transcript({required this.rows});

  final List<V2SharedChatMessage> rows;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      key: const ValueKey<String>('shared-chat-transcript'),
      padding: const EdgeInsets.only(top: OSpace.xs, bottom: OSpace.l),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        return Padding(
          key: ValueKey<String>('shared-row-${row.id}'),
          padding: const EdgeInsets.only(bottom: OSpace.l),
          child: _TranscriptRow(row: row, index: index),
        );
      },
    );
  }
}

class _TranscriptRow extends StatelessWidget {
  const _TranscriptRow({required this.row, required this.index});

  final V2SharedChatMessage row;
  final int index;

  @override
  Widget build(BuildContext context) {
    final sortKey = OrdinalSortKey(index.toDouble());
    return switch (row.role) {
      V2SharedChatRole.user => _UserRow(row: row, sortKey: sortKey),
      V2SharedChatRole.assistant => Semantics(
        container: true,
        explicitChildNodes: true,
        sortKey: sortKey,
        label: 'Assistant',
        child: V2MessageBlocks(markdown: row.text),
      ),
      V2SharedChatRole.thinking => _MetaRow(
        label: 'Thinking',
        text: row.text,
        icon: Icons.psychology_alt_outlined,
        sortKey: sortKey,
      ),
      V2SharedChatRole.tool => _MetaRow(
        label: 'Tool',
        text: row.text,
        icon: Icons.build_rounded,
        sortKey: sortKey,
      ),
    };
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({required this.row, required this.sortKey});

  final V2SharedChatMessage row;
  final OrdinalSortKey sortKey;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      container: true,
      sortKey: sortKey,
      label: 'You. ${row.text}',
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cap = constraints.maxWidth * 0.78;
          return Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: cap > 560 ? 560 : cap),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: OSpace.l,
                  vertical: OSpace.m,
                ),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.l),
                ),
                child: Text(
                  row.text,
                  style: OType.body.copyWith(color: c.text),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A tool or thinking row is progress, not content: one line, ellipsized,
/// with no chevron and no expansion target.
class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.label,
    required this.text,
    required this.icon,
    required this.sortKey,
  });

  final String label;
  final String text;
  final IconData icon;
  final OrdinalSortKey sortKey;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      container: true,
      sortKey: sortKey,
      label: '$label. $text',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: OSpace.xs),
        child: Row(
          children: [
            Icon(icon, size: 16, color: c.textFaint),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// An expired or revoked link is a fact, not an empty chat. One line, no
/// transcript and no Fork action.
class _UnavailableLine extends StatelessWidget {
  const _UnavailableLine({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Center(
      child: Semantics(
        container: true,
        label: label,
        child: ExcludeSemantics(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: c.textMuted),
              const SizedBox(width: OSpace.s),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.bodySm.copyWith(color: c.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ForkErrorBar extends StatelessWidget {
  const _ForkErrorBar({required this.reason, required this.onRetry});

  final String reason;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      margin: const EdgeInsets.only(top: OSpace.s),
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 20, color: c.danger),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Semantics(
              container: true,
              liveRegion: true,
              label: 'Fork failed. $reason',
              child: ExcludeSemantics(
                child: Text(
                  reason,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(color: c.text),
                ),
              ),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: OSpace.s),
            OButton(
              label: 'Retry',
              variant: OButtonVariant.ghost,
              size: OButtonSize.compact,
              onPressed: onRetry,
            ),
          ],
        ],
      ),
    );
  }
}

class _ForkedLine extends StatelessWidget {
  const _ForkedLine();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      label: 'Forked',
      child: ExcludeSemantics(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_outline_rounded, size: 20, color: c.text),
            const SizedBox(width: OSpace.s),
            Text(
              'Forked',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.label.copyWith(color: c.text),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens [ShareChatSheet] in the shared bottom-sheet container.
///
/// The returned future completes with the new session id when the recipient
/// forks the chat, or null when the sheet is dismissed without forking.
Future<String?> showShareChatSheet(
  BuildContext context, {
  required V2ShareChatSheetData data,
  VoidCallback? onCopyLink,
  ValueChanged<V2ShareMode>? onModeChanged,
  V2ShareChatForkHandler? onFork,
  VoidCallback? onStopSharing,
  VoidCallback? onCreateLink,
  ValueChanged<V2ShareMode>? onCreateLinkForMode,
  VoidCallback? onRetry,
}) {
  return showOSheet<String>(
    context,
    builder: (sheetContext) => ShareChatSheet(
      data: data,
      onCopyLink: onCopyLink,
      onModeChanged: onModeChanged,
      onFork: onFork,
      onForked: (sessionId) => Navigator.maybePop(sheetContext, sessionId),
      onStopSharing: onStopSharing,
      onCreateLink: onCreateLink,
      onCreateLinkForMode: onCreateLinkForMode,
      onRetry: onRetry,
      onClose: () => Navigator.maybePop(sheetContext),
    ),
  );
}
