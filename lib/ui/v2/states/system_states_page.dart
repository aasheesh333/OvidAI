import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// Copy for the four calm system states. The caller can override any line.
@immutable
class V2SystemStatesData {
  const V2SystemStatesData({
    this.emptyTitle = 'Start with a hello',
    this.emptyMessage =
        'Ask a coding question, brainstorm ideas, or let Ovid browse the web for you.',
    this.emptyActionLabel = 'Try an example prompt',
    this.offlineTitle = 'You are offline',
    this.offlineMessage =
        'No internet connection detected. Your messages will send when you reconnect.',
    this.offlineActionLabel = 'Retry connection',
    this.errorTitle = 'Something went wrong',
    this.errorMessage =
        'Ovid could not finish this run because the service timed out. Your changes are safe.',
    this.errorActionLabel = 'Try again',
    this.errorDetailsLabel = 'View error details',
    this.limitTitle = 'Daily limit reached',
    this.limitMessage =
        "You have used all 50M of today's free tokens. Your balance resets at midnight UTC.",
    this.limitResetLabel = 'Resets soon',
    this.limitActionLabel = 'See plans',
    this.footerNote =
        'Your chats and files stay safe in every state. Nothing is lost.',
  });

  final String emptyTitle;
  final String emptyMessage;
  final String emptyActionLabel;
  final String offlineTitle;
  final String offlineMessage;
  final String offlineActionLabel;
  final String errorTitle;
  final String errorMessage;
  final String errorActionLabel;
  final String errorDetailsLabel;
  final String limitTitle;
  final String limitMessage;
  final String limitResetLabel;
  final String limitActionLabel;
  final String footerNote;
}

/// A calm showcase of the four system states used across chat.
class V2SystemStatesPage extends StatelessWidget {
  const V2SystemStatesPage({
    super.key,
    this.data = const V2SystemStatesData(),
    this.onTryExample,
    this.onRetryConnection,
    this.onTryAgain,
    this.onViewErrorDetails,
    this.onSeePlans,
  });

  final V2SystemStatesData data;
  final VoidCallback? onTryExample;
  final VoidCallback? onRetryConnection;
  final VoidCallback? onTryAgain;
  final VoidCallback? onViewErrorDetails;
  final VoidCallback? onSeePlans;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OScaffold(
      appBar: const OAppBar(
        title: 'System states',
        subtitle: 'Calm feedback when things change',
      ),
      body: OFadeSlide(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            OSpace.screen,
            OSpace.l,
            OSpace.screen,
            OSpace.xxl,
          ),
          children: [
            OStagger(
              children: [
                _StateCard(
                  icon: Icons.waving_hand_rounded,
                  tone: c.accent,
                  title: data.emptyTitle,
                  message: data.emptyMessage,
                  action: OButton(
                    label: data.emptyActionLabel,
                    icon: Icons.lightbulb_outline_rounded,
                    variant: OButtonVariant.secondary,
                    onPressed: onTryExample,
                  ),
                ),
                _StateCard(
                  icon: Icons.cloud_off_rounded,
                  tone: c.textMuted,
                  title: data.offlineTitle,
                  message: data.offlineMessage,
                  action: OButton(
                    label: data.offlineActionLabel,
                    icon: Icons.sync_rounded,
                    variant: OButtonVariant.secondary,
                    onPressed: onRetryConnection,
                  ),
                ),
                _StateCard(
                  icon: Icons.warning_amber_rounded,
                  tone: c.danger,
                  title: data.errorTitle,
                  message: data.errorMessage,
                  action: OButton(
                    label: data.errorActionLabel,
                    icon: Icons.refresh_rounded,
                    onPressed: onTryAgain,
                  ),
                  secondaryAction: OButton(
                    label: data.errorDetailsLabel,
                    variant: OButtonVariant.ghost,
                    onPressed: onViewErrorDetails,
                  ),
                ),
                _StateCard(
                  icon: Icons.hourglass_top_rounded,
                  tone: c.accent,
                  title: data.limitTitle,
                  message: data.limitMessage,
                  pill: data.limitResetLabel,
                  action: OButton(
                    label: data.limitActionLabel,
                    icon: Icons.bolt_rounded,
                    onPressed: onSeePlans,
                  ),
                ),
              ],
            ),
            const SizedBox(height: OSpace.xl),
            Container(
              padding: const EdgeInsets.all(OSpace.m),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(ORadius.m),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.check_circle_outline_rounded,
                    size: 20,
                    color: c.success,
                  ),
                  const SizedBox(width: OSpace.s),
                  Expanded(
                    child: Text(
                      data.footerNote,
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.icon,
    required this.tone,
    required this.title,
    required this.message,
    required this.action,
    this.secondaryAction,
    this.pill,
  });

  final IconData icon;
  final Color tone;
  final String title;
  final String message;
  final Widget action;
  final Widget? secondaryAction;
  final String? pill;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.m),
      child: OCard(
        padding: const EdgeInsets.all(OSpace.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: tone.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 27, color: tone),
            ),
            const SizedBox(height: OSpace.m),
            Text(
              title,
              textAlign: TextAlign.center,
              style: OType.h2.copyWith(color: c.text),
            ),
            const SizedBox(height: OSpace.xs),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            ),
            if (pill != null) ...[
              const SizedBox(height: OSpace.m),
              _StatePill(label: pill!),
            ],
            const SizedBox(height: OSpace.m),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: SizedBox(width: double.infinity, child: action),
            ),
            if (secondaryAction != null) ...[
              const SizedBox(height: OSpace.xs),
              secondaryAction!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Accent pill for the reset countdown.
///
/// Deliberately not [OPill]: that pill fixes its height and lets its label take
/// unbounded width, so at 200 % text the label spills outside the pill. This
/// one grows with the text and wraps inside the card.
class _StatePill extends StatelessWidget {
  const _StatePill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.xs,
      ),
      decoration: BoxDecoration(
        color: c.accentSoft,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: OType.caption.copyWith(
                color: c.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
