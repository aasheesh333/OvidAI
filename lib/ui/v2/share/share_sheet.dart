import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/collaboration/models.dart' show maxActiveMembers;
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'share_link_card.dart';

// TODO(l10n): extract this screen's English copy during the ARB pass.

/// Load state for a share sheet. The link itself is data, not a route.
///
/// [creating] and [revoking] are in-flight states owned by the host while its
/// real service call is pending. [revoked] is terminal until a new link is
/// created. The sheet also infers the short-lived in-flight states locally so
/// a synchronous host callback still gets immediate feedback.
enum V2ShareStatus { loading, ready, creating, revoking, revoked, error }

/// How a shared chat can be used by the people who open the link.
///
/// [collab] is a live room capped at [maxActiveMembers] people with a single
/// sender at a time, paid for by the creator. [readOnly] is a snapshot that
/// viewers can fork into their own account.
enum V2ShareMode { collab, readOnly }

/// Where a shared link can be sent from the share sheet.
///
/// The sheet no longer renders a target grid: the operating system's share
/// sheet owns that list. The enum stays so existing hosts keep compiling.
enum V2ShareTarget { whatsApp, gmail, slack, more }

/// Hard cap on people in a Collab room, including the creator.
const int v2ShareMemberLimit = maxActiveMembers;

/// Immutable share state for [ShareSheet].
@immutable
class V2ShareSheetData {
  const V2ShareSheetData({
    required this.link,
    required this.creatorName,
    this.mode = V2ShareMode.readOnly,
    this.memberCount = 1,
    this.capacity = v2ShareMemberLimit,
    this.creatorPaysStorage = true,
    this.viewerCanFork = false,
    this.canChangeMode = true,
    this.anyoneCanView = true,
    this.showName = true,
    this.active = true,
    this.copied = false,
    this.status = V2ShareStatus.ready,
    this.errorMessage = 'We could not load the share link.',
    this.revoked = false,
    this.collabAvailable = true,
    this.collabUnavailableReason,
    this.readOnlyAvailable = true,
    this.readOnlyUnavailableReason,
  }) : assert(capacity > 0, 'A shared room always has a capacity');

  /// The read-only link shown in the sheet, for example `ovidsi.com/c/79f9b4c0e`.
  final String link;

  /// The sharing mode currently selected.
  final V2ShareMode mode;

  /// People in the Collab room, including the creator.
  final int memberCount;

  /// Hard room cap. Defaults to [v2ShareMemberLimit].
  final int capacity;

  /// Whether the creator's plan and storage pay for the room.
  final bool creatorPaysStorage;

  /// True when the person reading this sheet is a viewer of a read-only link
  /// rather than its creator, so they can fork it into their own account.
  final bool viewerCanFork;

  /// False when the current person cannot switch the mode (for example a
  /// member who joined someone else's room).
  final bool canChangeMode;

  /// Whether anyone with the link can open it. Kept for hosts that still own
  /// the value; the sheet does not render a toggle for it.
  final bool anyoneCanView;

  /// Whether the creator's name is shown on the shared page.
  final bool showName;

  /// Whether the link is currently live.
  final bool active;

  /// Whether the link was just copied. The owner of the state flips this for
  /// the short confirmation on the copy control.
  final bool copied;

  /// Name shown in the "Show my name" subtitle. Injected: the sheet never
  /// invents a person.
  final String creatorName;

  final V2ShareStatus status;
  final String errorMessage;

  /// True when the creator has revoked the link. This is distinct from
  /// [active] being false: a chat that was never shared is not revoked.
  final bool revoked;

  /// Whether the service that creates Collab rooms is available. A mode that
  /// is not supported is rendered disabled with [collabUnavailableReason], so
  /// the sheet never silently hides half of the choice.
  final bool collabAvailable;
  final String? collabUnavailableReason;

  /// Whether the read-only share service is available.
  final bool readOnlyAvailable;
  final String? readOnlyUnavailableReason;

  bool get isCollab => mode == V2ShareMode.collab;

  /// True when the active link is live and non-empty.
  bool get shared => active && link.trim().isNotEmpty;

  /// True when the room has reached its member cap.
  bool get roomFull => capacity > 0 && memberCount >= capacity;

  /// Short label for the member count, for example `3 of 50 members`.
  String get memberLabel => '$memberCount of $capacity members';

  bool isModeAvailable(V2ShareMode value) => switch (value) {
    V2ShareMode.collab => collabAvailable,
    V2ShareMode.readOnly => readOnlyAvailable,
  };

  String? modeUnavailableReason(V2ShareMode value) => switch (value) {
    V2ShareMode.collab => collabUnavailableReason,
    V2ShareMode.readOnly => readOnlyUnavailableReason,
  };
}

/// Generic share sheet. The host injects the real service actions.
///
/// Minimal layout: a title row with close, two one-line mode cards, the link
/// row with copy, then the revoke action. Sharing to an app is the operating
/// system's job.
class ShareSheet extends StatefulWidget {
  const ShareSheet({
    super.key,
    required this.data,
    this.onCopyLink,
    this.onModeChanged,
    this.onFork,
    this.onToggleAnyoneCanView,
    this.onToggleShowName,
    this.onShareTarget,
    this.onStopSharing,
    this.onCreateLink,
    this.onCreateLinkForMode,
    this.onRetry,
    this.onClose,
    this.title = 'Share this chat',
    this.subtitle,
    this.forkNote,
  });

  final V2ShareSheetData data;
  final VoidCallback? onCopyLink;
  final ValueChanged<V2ShareMode>? onModeChanged;

  /// Called when a read-only viewer forks the chat into their own account.
  final VoidCallback? onFork;
  final ValueChanged<bool>? onToggleAnyoneCanView;
  final ValueChanged<bool>? onToggleShowName;
  final ValueChanged<V2ShareTarget>? onShareTarget;
  final VoidCallback? onStopSharing;

  /// Legacy create callback. The host reads the selected mode from [data].
  final VoidCallback? onCreateLink;

  /// Per-mode create callback. Prefer this over [onCreateLink] when binding a
  /// real service: the selected mode is passed explicitly, so Collab and
  /// Read only cannot be created by the same branch by accident.
  final ValueChanged<V2ShareMode>? onCreateLinkForMode;

  final VoidCallback? onRetry;
  final VoidCallback? onClose;

  final String title;

  /// Retained for hosts that used to pass a second header line. The minimal
  /// header is one line; the mode cards explain the two options instead.
  final String? subtitle;

  /// Retained for the chat variant. Forking is explained by the card's action,
  /// so the sheet does not render a paragraph.
  final String? forkNote;

  @override
  State<ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<ShareSheet> {
  static const Duration _createWatchdog = Duration(seconds: 25);
  static const Duration _revokeWatchdog = Duration(seconds: 20);
  static const Duration _copiedLinger = Duration(milliseconds: 1600);

  /// A host callback is synchronous. These flags bridge the gap until the
  /// host rebuilds with the real result, so the person sees the request is in
  /// flight instead of the Create button disappearing.
  bool _creating = false;
  bool _revoking = false;
  bool _revoked = false;
  bool _copied = false;
  String? _actionError;
  Timer? _createTimer;
  Timer? _revokeTimer;
  Timer? _copyTimer;

  V2ShareSheetData get _data => widget.data;

  bool get _canPickMode =>
      _data.canChangeMode &&
      !_data.viewerCanFork &&
      widget.onModeChanged != null;

  bool get _hasCreateAction =>
      widget.onCreateLink != null || widget.onCreateLinkForMode != null;

  V2ShareStatus get _status {
    if (_data.status != V2ShareStatus.ready) return _data.status;
    if (_actionError != null) return V2ShareStatus.error;
    if (_data.revoked || _revoked) return V2ShareStatus.revoked;
    if (_creating) return V2ShareStatus.creating;
    if (_revoking) return V2ShareStatus.revoking;
    return V2ShareStatus.ready;
  }

  String get _errorMessage => _actionError ?? _data.errorMessage;

  @override
  void didUpdateWidget(covariant ShareSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldShared =
        oldWidget.data.active && oldWidget.data.link.trim().isNotEmpty;
    final shared = _data.active && _data.link.trim().isNotEmpty;

    if (_data.mode != oldWidget.data.mode) {
      _clearTransient();
      _revoked = false;
      _copied = false;
    }
    if (_data.link != oldWidget.data.link) _copied = false;

    if (shared != oldShared) {
      _cancelActionTimers();
      _creating = false;
      _revoking = false;
      if (shared) {
        _revoked = false;
        _actionError = null;
      } else if (oldShared) {
        // A link that was live and is now gone was revoked by the host.
        _revoked = true;
      }
    }

    if (_data.status != oldWidget.data.status) {
      if (_data.status == V2ShareStatus.error ||
          _data.status == V2ShareStatus.loading) {
        _creating = false;
        _revoking = false;
        if (_data.status == V2ShareStatus.error) _actionError = null;
      }
      if (_data.status == V2ShareStatus.revoked) _revoked = true;
      if (_data.status == V2ShareStatus.ready && !shared) {
        _creating = false;
        _revoking = false;
      }
    }
  }

  @override
  void dispose() {
    _cancelActionTimers();
    _copyTimer?.cancel();
    super.dispose();
  }

  void _cancelActionTimers() {
    _createTimer?.cancel();
    _createTimer = null;
    _revokeTimer?.cancel();
    _revokeTimer = null;
  }

  void _clearTransient() {
    _cancelActionTimers();
    _creating = false;
    _revoking = false;
    _actionError = null;
  }

  void _startCreate() {
    if (_creating || _status == V2ShareStatus.creating) return;
    if (!_data.isModeAvailable(_data.mode) || !_hasCreateAction) return;
    setState(() {
      _creating = true;
      _revoked = false;
      _actionError = null;
    });
    _createTimer?.cancel();
    _createTimer = Timer(_createWatchdog, () {
      if (!mounted || !_creating) return;
      setState(() => _creating = false);
    });
    try {
      final forMode = widget.onCreateLinkForMode;
      if (forMode != null) {
        forMode(_data.mode);
      } else {
        widget.onCreateLink!();
      }
    } catch (error) {
      _createTimer?.cancel();
      _createTimer = null;
      if (!mounted) return;
      setState(() {
        _creating = false;
        _actionError = _messageOf(error);
      });
    }
  }

  void _startRevoke() {
    final revoke = widget.onStopSharing;
    if (revoke == null || _revoking) return;
    setState(() {
      _revoking = true;
      _actionError = null;
    });
    _revokeTimer?.cancel();
    _revokeTimer = Timer(_revokeWatchdog, () {
      if (!mounted || !_revoking) return;
      setState(() => _revoking = false);
    });
    try {
      revoke();
    } catch (error) {
      _revokeTimer?.cancel();
      _revokeTimer = null;
      if (!mounted) return;
      setState(() {
        _revoking = false;
        _actionError = _messageOf(error);
      });
    }
  }

  void _copy() {
    final copy = widget.onCopyLink;
    if (copy == null || !_data.shared) return;
    copy();
    if (!mounted) return;
    setState(() => _copied = true);
    _copyTimer?.cancel();
    _copyTimer = Timer(_copiedLinger, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _selectMode(V2ShareMode mode) {
    if (!_canPickMode || _status != V2ShareStatus.ready) return;
    if (mode == _data.mode || !_data.isModeAvailable(mode)) return;
    _clearTransient();
    setState(() {
      _revoked = false;
      _copied = false;
    });
    widget.onModeChanged!(mode);
  }

  void _retry() {
    if (_actionError != null) {
      setState(() => _actionError = null);
      _startCreate();
      return;
    }
    widget.onRetry?.call();
  }

  Future<void> _confirmRevoke() async {
    final revoke = widget.onStopSharing;
    if (revoke == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Revoke this link?'),
        content: const Text(
          'Anyone with the link loses access immediately. This cannot be '
          'undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: OColors.of(dialogContext).danger,
              foregroundColor: OColors.of(dialogContext).onAccent,
            ),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    _startRevoke();
  }

  String _messageOf(Object error) {
    final text = error.toString();
    return text.startsWith('Bad state: ')
        ? text.substring('Bad state: '.length)
        : text;
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            OSpace.l,
            OSpace.s,
            OSpace.l,
            OSpace.l,
          ),
          child: _body(context),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final status = _status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        if (status != V2ShareStatus.loading) ...[
          const SizedBox(height: OSpace.s),
          if (_canPickMode) _modeChooser() else _modeSummary(),
        ],
        const SizedBox(height: OSpace.l),
        switch (status) {
          V2ShareStatus.loading => const SizedBox(
            height: 320,
            child: OSkeletonList(rows: 4),
          ),
          V2ShareStatus.error => SizedBox(
            height: 320,
            child: OErrorState(message: _errorMessage, onRetry: _retry),
          ),
          V2ShareStatus.creating => _creatingCard(context),
          V2ShareStatus.revoking => _sharedBlock(context, revoking: true),
          V2ShareStatus.revoked => _revokedCard(context),
          V2ShareStatus.ready =>
            _data.shared ? _sharedBlock(context) : _notSharedCard(context),
        },
      ],
    );
  }

  /// One header row, shared with every other sheet: title on the left, close
  /// on the right. The scroll view already supplies the outer gutter, so the
  /// header only adds the gap under itself.
  Widget _header() {
    return OSheetHeader(
      title: widget.title,
      closeLabel: 'Close share sheet',
      onClose: widget.onClose,
      padding: const EdgeInsets.only(bottom: OSpace.s),
    );
  }

  Widget _modeChooser() {
    final status = _status;
    final locked =
        status == V2ShareStatus.creating || status == V2ShareStatus.revoking;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Sharing mode',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _modeCard(V2ShareMode.collab, locked: locked),
          const SizedBox(height: OSpace.s),
          _modeCard(V2ShareMode.readOnly, locked: locked),
        ],
      ),
    );
  }

  /// One line per mode. The selected card carries the check and the accent.
  Widget _modeCard(V2ShareMode mode, {required bool locked}) {
    final collab = mode == V2ShareMode.collab;
    final selected = _data.mode == mode;
    final available = _data.isModeAvailable(mode);
    final reason = _data.modeUnavailableReason(mode);
    final title = collab ? 'Collab' : 'Read only';
    final body = collab
        ? 'Max $v2ShareMemberLimit · one sender at a time · creator pays storage.'
        : 'Recipients fork into their own account.';
    final onTap = available && !locked ? () => _selectMode(mode) : null;
    return _ModeCard(
      title: title,
      body: body,
      note: available ? null : (reason ?? 'Unavailable in this build.'),
      icon: collab ? Icons.groups_rounded : Icons.visibility_rounded,
      selected: selected,
      enabled: available,
      onTap: onTap,
    );
  }

  /// A viewer cannot change the mode, so the same two facts are shown as one
  /// static summary instead of a control with no action behind it.
  Widget _modeSummary() {
    final collab = _data.isCollab;
    return _ModeSummary(
      title: collab ? 'Collab room' : 'Read only',
      body: collab
          ? 'Max $v2ShareMemberLimit · one sender at a time · creator pays storage.'
          : 'Recipients fork into their own account.',
      icon: collab ? Icons.groups_rounded : Icons.visibility_rounded,
    );
  }

  Widget _sharedBlock(BuildContext context, {bool revoking = false}) {
    final viewer = _data.viewerCanFork;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        V2ShareLinkCard(
          data: V2ShareLinkCardData(
            url: _data.link,
            mode: _data.mode,
            memberCount: _data.memberCount,
            capacity: _data.capacity,
            copied: _data.copied || _copied,
            viewer: viewer,
            revoked: _data.revoked,
            busy: revoking,
          ),
          onCopy: _data.link.trim().isEmpty ? null : _copy,
          onFork: widget.onFork,
        ),
        if (!viewer && (widget.onStopSharing != null || revoking)) ...[
          const SizedBox(height: OSpace.l),
          OButton(
            label: revoking ? 'Revoking' : 'Revoke link',
            icon: revoking ? null : Icons.link_off_rounded,
            variant: OButtonVariant.danger,
            loading: revoking,
            expand: true,
            onPressed: revoking ? null : () => unawaited(_confirmRevoke()),
          ),
        ],
      ],
    );
  }

  Widget _notSharedCard(BuildContext context) {
    final c = OColors.of(context);
    final available = _data.isModeAvailable(_data.mode);
    final reason =
        _data.modeUnavailableReason(_data.mode) ?? 'Unavailable in this build.';
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            container: true,
            header: true,
            child: Text(
              'Not shared yet',
              style: OType.h3.copyWith(color: c.text),
            ),
          ),
          const SizedBox(height: OSpace.s),
          Text(
            available ? 'Only people with the link can open it.' : reason,
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
          if (_hasCreateAction) ...[
            const SizedBox(height: OSpace.l),
            OButton(
              label: 'Create link',
              icon: Icons.link_rounded,
              expand: true,
              onPressed: available ? _startCreate : null,
            ),
          ] else ...[
            const SizedBox(height: OSpace.s),
            Text(
              'Sign in to create a link.',
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ],
        ],
      ),
    );
  }

  Widget _creatingCard(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Creating link', style: OType.h3.copyWith(color: c.text)),
          const SizedBox(height: OSpace.s),
          Text(
            'This only takes a moment.',
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: OSpace.l),
          // A progress row, not a button: nothing can be pressed while the
          // link is being created, so the card must not draw a control.
          Semantics(
            liveRegion: true,
            label: 'Creating link',
            child: ExcludeSemantics(
              child: SizedBox(
                height: OSpace.touch,
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: c.textMuted,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _revokedCard(BuildContext context) {
    final c = OColors.of(context);
    final available = _data.isModeAvailable(_data.mode);
    final reason =
        _data.modeUnavailableReason(_data.mode) ?? 'Unavailable in this build.';
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            container: true,
            header: true,
            child: Text(
              'Link revoked',
              style: OType.h3.copyWith(color: c.text),
            ),
          ),
          const SizedBox(height: OSpace.s),
          Text(
            available ? 'No one can open it now.' : reason,
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
          if (_hasCreateAction) ...[
            const SizedBox(height: OSpace.l),
            OButton(
              label: 'Create link',
              icon: Icons.link_rounded,
              expand: true,
              onPressed: available ? _startCreate : null,
            ),
          ],
        ],
      ),
    );
  }
}

/// Opens [ShareSheet] in the shared bottom-sheet container.
Future<void> showShareSheet(
  BuildContext context, {
  required V2ShareSheetData data,
  VoidCallback? onCopyLink,
  ValueChanged<V2ShareMode>? onModeChanged,
  VoidCallback? onFork,
  ValueChanged<bool>? onToggleAnyoneCanView,
  ValueChanged<bool>? onToggleShowName,
  ValueChanged<V2ShareTarget>? onShareTarget,
  VoidCallback? onStopSharing,
  VoidCallback? onCreateLink,
  ValueChanged<V2ShareMode>? onCreateLinkForMode,
  VoidCallback? onRetry,
}) {
  return showOSheet<void>(
    context,
    builder: (sheetContext) => ShareSheet(
      data: data,
      onCopyLink: onCopyLink,
      onModeChanged: onModeChanged,
      onFork: onFork,
      onToggleAnyoneCanView: onToggleAnyoneCanView,
      onToggleShowName: onToggleShowName,
      onShareTarget: onShareTarget,
      onStopSharing: onStopSharing,
      onCreateLink: onCreateLink,
      onCreateLinkForMode: onCreateLinkForMode,
      onRetry: onRetry,
      onClose: () => Navigator.maybePop(sheetContext),
    ),
  );
}

/// One selectable share mode. The whole card is the 48 dp target, reports a
/// radio group member with its checked state, and states the mode's cap and
/// who pays in its accessible label.
class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.title,
    required this.body,
    required this.icon,
    required this.selected,
    required this.enabled,
    this.note,
    this.onTap,
  });

  final String title;
  final String body;
  final String? note;
  final IconData icon;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final label = note == null ? '$title. $body' : '$title. $body $note';
    return Semantics(
      container: true,
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: enabled,
      label: label,
      onTap: enabled ? onTap : null,
      child: ExcludeSemantics(
        child: OPressable(
          onTap: enabled ? onTap : null,
          child: AnimatedContainer(
            duration: OMotion.fast,
            constraints: const BoxConstraints(minHeight: OSpace.touch),
            padding: const EdgeInsets.all(OSpace.m),
            decoration: BoxDecoration(
              color: !enabled
                  ? c.surfaceRaised
                  : selected
                  ? c.accentSoft
                  : c.surface,
              borderRadius: BorderRadius.circular(ORadius.m),
              border: Border.all(
                color: selected && enabled
                    ? c.accentFill.withValues(alpha: 0.5)
                    : c.hairline,
                width: selected && enabled ? 1.5 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: !enabled
                      ? c.textFaint
                      : selected
                      ? c.accent
                      : c.textMuted,
                ),
                const SizedBox(width: OSpace.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: OType.bodySm.copyWith(
                          color: enabled ? c.text : c.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: OSpace.xxs),
                      Text(
                        body,
                        style: OType.caption.copyWith(
                          color: enabled ? c.textMuted : c.textFaint,
                        ),
                      ),
                      if (note != null) ...[
                        const SizedBox(height: OSpace.xxs),
                        Text(
                          note!,
                          style: OType.caption.copyWith(color: c.danger),
                        ),
                      ],
                    ],
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: OSpace.s),
                  Icon(
                    Icons.check_rounded,
                    size: 20,
                    color: enabled ? c.accent : c.textFaint,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Static mode facts for a viewer, who cannot change the mode.
class _ModeSummary extends StatelessWidget {
  const _ModeSummary({
    required this.title,
    required this.body,
    required this.icon,
  });

  final String title;
  final String body;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: OSpace.touch),
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: c.textMuted),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: OType.bodySm.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: OSpace.xxs),
                Text(body, style: OType.caption.copyWith(color: c.textMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
