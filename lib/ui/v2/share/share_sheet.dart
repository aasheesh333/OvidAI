import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): extract this screen's English copy during the ARB pass.

/// Load state for a share sheet. The link itself is data, not a route.
enum V2ShareStatus { loading, ready, error }

/// Where a shared link can be sent from the share sheet.
enum V2ShareTarget { whatsApp, gmail, slack, more }

/// Immutable share state for [ShareSheet].
@immutable
class V2ShareSheetData {
  const V2ShareSheetData({
    required this.link,
    required this.creatorName,
    this.anyoneCanView = true,
    this.showName = true,
    this.active = true,
    this.copied = false,
    this.status = V2ShareStatus.ready,
    this.errorMessage = 'We could not load the share link.',
  });

  /// The read-only link shown in the sheet, for example `ovidsi.com/c/79f9b4c0e`.
  final String link;

  /// Whether anyone with the link can open it.
  final bool anyoneCanView;

  /// Whether the creator's name is shown on the shared page.
  final bool showName;

  /// Whether the link is currently live.
  final bool active;

  /// Whether the link was just copied. The owner of the state flips this for
  /// the short "Copied" confirmation.
  final bool copied;

  /// Name shown in the "Show my name" subtitle. Injected: the sheet never
  /// invents a person.
  final String creatorName;

  final V2ShareStatus status;
  final String errorMessage;
}

/// Generic share sheet. Presentational: all state and actions are injected.
class ShareSheet extends StatelessWidget {
  const ShareSheet({
    super.key,
    required this.data,
    this.onCopyLink,
    this.onToggleAnyoneCanView,
    this.onToggleShowName,
    this.onShareTarget,
    this.onStopSharing,
    this.onCreateLink,
    this.onRetry,
    this.onClose,
    this.title = 'Share this chat',
    this.subtitle,
    this.forkNote,
  });

  final V2ShareSheetData data;
  final VoidCallback? onCopyLink;
  final ValueChanged<bool>? onToggleAnyoneCanView;
  final ValueChanged<bool>? onToggleShowName;
  final ValueChanged<V2ShareTarget>? onShareTarget;
  final VoidCallback? onStopSharing;
  final VoidCallback? onCreateLink;
  final VoidCallback? onRetry;
  final VoidCallback? onClose;

  final String title;
  final String? subtitle;

  /// Extra explanation shown above the share targets. The chat variant uses
  /// this for the fork-into-your-own-account note.
  final String? forkNote;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: switch (data.status) {
          V2ShareStatus.loading => const SizedBox(
            height: 420,
            child: OSkeletonList(rows: 4),
          ),
          V2ShareStatus.error => SizedBox(
            height: 380,
            child: OErrorState(message: data.errorMessage, onRetry: onRetry),
          ),
          V2ShareStatus.ready =>
            data.active ? _content(context) : _empty(context),
        },
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return OEmptyState(
      icon: Icons.link_off_rounded,
      title: 'This chat is not shared yet',
      message:
          'Create a link anyone can view. Your files and connectors stay private.',
      action: OButton(
        label: 'Create link',
        icon: Icons.link_rounded,
        onPressed: onCreateLink,
      ),
    );
  }

  Widget _content(BuildContext context) {
    final c = OColors.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.s,
        OSpace.l,
        OSpace.l,
      ),
      child: OFadeSlide(
        child: OStagger(
          children: [
            _header(context, c),
            const SizedBox(height: OSpace.l),
            _linkCard(context, c),
            const SizedBox(height: OSpace.m),
            _permissions(context, c),
            if (forkNote != null) ...[
              const SizedBox(height: OSpace.m),
              _forkNoteCard(c),
            ],
            const SizedBox(height: OSpace.l),
            OSectionHeader(
              label: 'Share directly',
              padding: const EdgeInsets.only(bottom: OSpace.s),
            ),
            _targets(context, c),
            const SizedBox(height: OSpace.l),
            OButton(
              label: 'Stop sharing',
              icon: Icons.link_off_rounded,
              variant: OButtonVariant.danger,
              expand: true,
              onPressed: onStopSharing,
            ),
            const SizedBox(height: OSpace.l),
            _privacyNote(c),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, OColors c) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: OType.h2.copyWith(color: c.text)),
              if (subtitle != null) ...[
                const SizedBox(height: OSpace.xs),
                Text(
                  subtitle!,
                  style: OType.bodySm.copyWith(color: c.textMuted),
                ),
              ],
            ],
          ),
        ),
        if (onClose != null)
          OIconButton(
            icon: Icons.close_rounded,
            semanticLabel: 'Close share sheet',
            onPressed: onClose,
          ),
      ],
    );
  }

  Widget _linkCard(BuildContext context, OColors c) {
    final label = data.copied ? 'Copied' : 'Copy link';
    final icon = data.copied ? Icons.check_rounded : Icons.copy_rounded;
    return LayoutBuilder(
      builder: (context, constraints) {
        // The copy button is sized by its label. When it no longer leaves a
        // readable link beside it, the card stacks instead of overflowing.
        final inline = constraints.maxWidth >= _inlineLinkWidth(context, label);
        final link = Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c.accentSoft,
                borderRadius: BorderRadius.circular(ORadius.s),
              ),
              child: Icon(Icons.link_rounded, size: 20, color: c.accent),
            ),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Text(
                data.link,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.mono.copyWith(color: c.textMuted),
              ),
            ),
          ],
        );
        final button = OButton(
          label: label,
          icon: icon,
          onPressed: onCopyLink,
          expand: !inline,
        );
        return Container(
          padding: const EdgeInsets.all(OSpace.s),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(ORadius.m),
            border: Border.all(color: c.hairline),
          ),
          child: inline
              ? Row(
                  children: [
                    Expanded(child: link),
                    const SizedBox(width: OSpace.s),
                    button,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    link,
                    const SizedBox(height: OSpace.s),
                    button,
                  ],
                ),
        );
      },
    );
  }

  /// Width the inline link row needs before the copy button can sit beside it
  /// without squeezing the link or clipping the button label.
  double _inlineLinkWidth(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: OType.label),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final buttonWidth = painter.width + 19 + OSpace.s + 40;
    painter.dispose();
    // 40 icon + gap + a readable minimum for the link + gap + button.
    return 40 + OSpace.s + 96 + OSpace.s + buttonWidth;
  }

  Widget _permissions(BuildContext context, OColors c) {
    return OCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          _ToggleRow(
            title: 'Anyone with the link can view',
            subtitle: 'Read-only. They can fork it into their own account.',
            value: data.anyoneCanView,
            onChanged: onToggleAnyoneCanView,
          ),
          Divider(
            height: 1,
            color: c.hairline,
            indent: OSpace.l,
            endIndent: OSpace.l,
          ),
          _ToggleRow(
            title: 'Show my name',
            subtitle: 'Displays ${data.creatorName} as creator',
            value: data.showName,
            onChanged: onToggleShowName,
          ),
        ],
      ),
    );
  }

  Widget _forkNoteCard(OColors c) {
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.accentSoft,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.account_tree_rounded, size: 20, color: c.accent),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              forkNote!,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _targets(BuildContext context, OColors c) {
    return LayoutBuilder(
      builder: (context, constraints) => Wrap(
        alignment: WrapAlignment.spaceEvenly,
        spacing: OSpace.s,
        runSpacing: OSpace.m,
        children: [
          for (final target in V2ShareTarget.values)
            ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: 72,
                maxWidth: constraints.maxWidth,
              ),
              child: _ShareTargetButton(
                target: target,
                onTap: onShareTarget == null
                    ? null
                    : () => onShareTarget!(target),
              ),
            ),
        ],
      ),
    );
  }

  Widget _privacyNote(OColors c) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: OSpace.xs),
          child: Icon(Icons.lock_outline_rounded, size: 14, color: c.textFaint),
        ),
        const SizedBox(width: OSpace.xs),
        Flexible(
          child: Text(
            'Shared chats never include your files or connectors.',
            textAlign: TextAlign.center,
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ),
      ],
    );
  }
}

/// Opens [ShareSheet] in the shared bottom-sheet container.
Future<void> showShareSheet(
  BuildContext context, {
  required V2ShareSheetData data,
  VoidCallback? onCopyLink,
  ValueChanged<bool>? onToggleAnyoneCanView,
  ValueChanged<bool>? onToggleShowName,
  ValueChanged<V2ShareTarget>? onShareTarget,
  VoidCallback? onStopSharing,
  VoidCallback? onCreateLink,
  VoidCallback? onRetry,
}) {
  return showOSheet<void>(
    context,
    builder: (sheetContext) => ShareSheet(
      data: data,
      onCopyLink: onCopyLink,
      onToggleAnyoneCanView: onToggleAnyoneCanView,
      onToggleShowName: onToggleShowName,
      onShareTarget: onShareTarget,
      onStopSharing: onStopSharing,
      onCreateLink: onCreateLink,
      onRetry: onRetry,
      onClose: () => Navigator.maybePop(sheetContext),
    ),
  );
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.title,
    required this.subtitle,
    required this.value,
    this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.l,
          vertical: OSpace.m,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: OType.bodySm.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: OSpace.xs),
                  Text(
                    subtitle,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: OSpace.m),
            Switch(
              value: value,
              onChanged: onChanged,
              activeTrackColor: c.accentFill,
              activeThumbColor: c.onAccent,
              inactiveTrackColor: c.surfaceRaised,
              inactiveThumbColor: c.textFaint,
            ),
          ],
        ),
      ),
    );
  }
}

class _ShareTargetButton extends StatelessWidget {
  const _ShareTargetButton({required this.target, this.onTap});

  final V2ShareTarget target;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final (label, icon, tint) = switch (target) {
      V2ShareTarget.whatsApp => ('WhatsApp', Icons.chat_rounded, c.success),
      V2ShareTarget.gmail => ('Gmail', Icons.mail_rounded, c.danger),
      V2ShareTarget.slack => ('Slack', Icons.forum_rounded, c.accent),
      V2ShareTarget.more => ('More', Icons.more_horiz_rounded, c.textMuted),
    };
    return Semantics(
      label: 'Share on $label',
      button: true,
      enabled: onTap != null,
      onTap: onTap,
      excludeSemantics: true,
      child: OPressable(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: OSpace.xs,
            vertical: OSpace.s,
          ),
          child: Column(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(ORadius.l),
                ),
                child: Icon(icon, size: 26, color: tint),
              ),
              const SizedBox(height: OSpace.s),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
