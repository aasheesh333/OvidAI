import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// The recoverable states that can interrupt chat or a list.
///
/// Every state owns its icon, calm copy and next action:
///
/// | State | Meaning | Action |
/// |---|---|---|
/// | [offline] | No connection; messages wait in the queue. | Retry |
/// | [planLimited] | The plan's allowance is spent. | See plans |
/// | [storageFull] | The account cannot accept new files. | Manage storage |
/// | [abuseBlocked] | The account is suspended pending review. | Get help |
/// | [deletionPending] | A 24-hour account deletion is scheduled. | Restore |
/// | [serverError] | A request failed on the service side. | Try again |
enum V2StateTileKind {
  offline,
  planLimited,
  storageFull,
  abuseBlocked,
  deletionPending,
  serverError,
}

/// Visual weight of a state. `neutral` is calm, `warn` asks for a decision and
/// `danger` means the account or request is blocked.
enum V2StateTileTone { neutral, warn, danger }

/// Icon, copy and action for one [V2StateTileKind].
///
/// The defaults live here so every screen tells the same story. Callers may
/// override any line with [copyWith], or build a completely custom tile by
/// passing their own copy to [V2StateTile.copy].
@immutable
class V2StateTileCopy {
  const V2StateTileCopy({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    this.secondaryActionLabel,
    this.tone = V2StateTileTone.neutral,
    this.actionVariant = OButtonVariant.primary,
    this.secondaryActionVariant = OButtonVariant.ghost,
  });

  /// Decorative icon. The title and message carry the meaning for screen
  /// readers, so the icon is excluded from semantics.
  final IconData icon;

  final String title;
  final String message;

  /// Label for the next step. An empty label hides the action.
  final String actionLabel;

  /// Optional second step, such as "View details" after a server error.
  final String? secondaryActionLabel;

  final V2StateTileTone tone;
  final OButtonVariant actionVariant;
  final OButtonVariant secondaryActionVariant;

  static const offline = V2StateTileCopy(
    icon: Icons.cloud_off_rounded,
    title: "You're offline",
    message: 'No internet connection. Messages will send when you reconnect.',
    actionLabel: 'Retry',
    actionVariant: OButtonVariant.secondary,
  );

  static const planLimited = V2StateTileCopy(
    icon: Icons.hourglass_top_rounded,
    title: 'Plan limit reached',
    message:
        'You have reached the limit for your plan. Upgrade to keep going now, '
        'or wait for your allowance to reset.',
    actionLabel: 'See plans',
    tone: V2StateTileTone.warn,
  );

  static const storageFull = V2StateTileCopy(
    icon: Icons.storage_rounded,
    title: 'Storage full',
    message:
        'Your storage is full, so new files cannot be saved. Delete old chats '
        'or clear previews to free space, or upgrade for more storage.',
    actionLabel: 'Manage storage',
    tone: V2StateTileTone.warn,
  );

  static const abuseBlocked = V2StateTileCopy(
    icon: Icons.gpp_bad_rounded,
    title: 'Account suspended',
    message:
        'This account is suspended for abuse. Contact support to appeal. '
        'Your files are kept while support reviews your account.',
    actionLabel: 'Get help',
    actionVariant: OButtonVariant.secondary,
    tone: V2StateTileTone.danger,
  );

  static const deletionPending = V2StateTileCopy(
    icon: Icons.delete_sweep_rounded,
    title: 'Account deletion pending',
    message:
        'Your account is kept for a 24-hour grace period. Sign in again and '
        'choose Restore to cancel the deletion; after that, your chats, files '
        'and memory are deleted.',
    actionLabel: 'Restore',
    tone: V2StateTileTone.warn,
  );

  static const serverError = V2StateTileCopy(
    icon: Icons.error_outline_rounded,
    title: 'Something went wrong',
    message:
        'Ovid could not finish that request. Your chats and changes are safe.',
    actionLabel: 'Try again',
    tone: V2StateTileTone.danger,
  );

  /// Defaults for [kind]. Stable enough for callers to [copyWith] one line.
  static V2StateTileCopy of(V2StateTileKind kind) => switch (kind) {
    V2StateTileKind.offline => offline,
    V2StateTileKind.planLimited => planLimited,
    V2StateTileKind.storageFull => storageFull,
    V2StateTileKind.abuseBlocked => abuseBlocked,
    V2StateTileKind.deletionPending => deletionPending,
    V2StateTileKind.serverError => serverError,
  };

  V2StateTileCopy copyWith({
    IconData? icon,
    String? title,
    String? message,
    String? actionLabel,
    String? secondaryActionLabel,
    V2StateTileTone? tone,
    OButtonVariant? actionVariant,
    OButtonVariant? secondaryActionVariant,
  }) {
    return V2StateTileCopy(
      icon: icon ?? this.icon,
      title: title ?? this.title,
      message: message ?? this.message,
      actionLabel: actionLabel ?? this.actionLabel,
      secondaryActionLabel: secondaryActionLabel ?? this.secondaryActionLabel,
      tone: tone ?? this.tone,
      actionVariant: actionVariant ?? this.actionVariant,
      secondaryActionVariant:
          secondaryActionVariant ?? this.secondaryActionVariant,
    );
  }
}

/// A calm, reusable card for a state that interrupts chat or a list.
///
/// The tile is presentational: pass [onAction] (and [onSecondaryAction]) from
/// the wiring layer. A null callback renders its button disabled and announces
/// that disabled state to accessibility, so callers never need to hide the
/// next step while it is unavailable.
///
/// ```dart
/// V2StateTile.planLimited(
///   detail: 'Resets in 6h 12m',
///   onAction: () => openPlans(context),
/// )
/// ```
///
/// Use [V2StateTile.kind] when the state is chosen at runtime, and the named
/// constructors when the state is known at the call site.
class V2StateTile extends StatelessWidget {
  const V2StateTile({
    super.key,
    required this.kind,
    this.copy,
    this.detail,
    this.onAction,
    this.onSecondaryAction,
  });

  const V2StateTile.offline({
    super.key,
    this.copy,
    this.detail,
    this.onAction,
    this.onSecondaryAction,
  }) : kind = V2StateTileKind.offline;

  const V2StateTile.planLimited({
    super.key,
    this.copy,
    this.detail,
    this.onAction,
    this.onSecondaryAction,
  }) : kind = V2StateTileKind.planLimited;

  const V2StateTile.storageFull({
    super.key,
    this.copy,
    this.detail,
    this.onAction,
    this.onSecondaryAction,
  }) : kind = V2StateTileKind.storageFull;

  const V2StateTile.abuseBlocked({
    super.key,
    this.copy,
    this.detail,
    this.onAction,
    this.onSecondaryAction,
  }) : kind = V2StateTileKind.abuseBlocked;

  const V2StateTile.deletionPending({
    super.key,
    this.copy,
    this.detail,
    this.onAction,
    this.onSecondaryAction,
  }) : kind = V2StateTileKind.deletionPending;

  const V2StateTile.serverError({
    super.key,
    this.copy,
    this.detail,
    this.onAction,
    this.onSecondaryAction,
  }) : kind = V2StateTileKind.serverError;

  final V2StateTileKind kind;

  /// Replaces the default icon, copy and tone for [kind].
  final V2StateTileCopy? copy;

  /// Optional supporting fact, such as `Resets in 6h 12m` or
  /// `2.9 GB of 3 GB used`. Kept separate from [copy] because it is measured
  /// data, not fixed copy.
  final String? detail;

  final VoidCallback? onAction;
  final VoidCallback? onSecondaryAction;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final resolved = copy ?? V2StateTileCopy.of(kind);
    final tone = _tone(c, resolved.tone);
    final detailText = detail?.trim() ?? '';
    final secondary = resolved.secondaryActionLabel?.trim() ?? '';

    return Semantics(
      container: true,
      explicitChildNodes: true,
      // A state tile replaces another state in place; announce the change
      // instead of waiting for the user to explore the screen again.
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(OSpace.l),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(ORadius.l),
          border: Border.all(color: c.hairline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: tone.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(ORadius.m),
                    ),
                    child: Icon(resolved.icon, size: 22, color: tone),
                  ),
                ),
                const SizedBox(width: OSpace.m),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        resolved.title,
                        style: OType.h3.copyWith(color: c.text),
                      ),
                      const SizedBox(height: OSpace.xs),
                      Text(
                        resolved.message,
                        style: OType.bodySm.copyWith(color: c.textMuted),
                      ),
                      if (detailText.isNotEmpty) ...[
                        const SizedBox(height: OSpace.s),
                        _StateDetail(label: detailText, tone: tone),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (resolved.actionLabel.trim().isNotEmpty) ...[
              const SizedBox(height: OSpace.m),
              OButton(
                label: resolved.actionLabel,
                variant: resolved.actionVariant,
                onPressed: onAction,
                expand: true,
              ),
            ],
            if (secondary.isNotEmpty) ...[
              const SizedBox(height: OSpace.xs),
              OButton(
                label: secondary,
                variant: resolved.secondaryActionVariant,
                onPressed: onSecondaryAction,
                expand: true,
              ),
            ],
          ],
        ),
      ),
    );
  }

  static Color _tone(OColors c, V2StateTileTone tone) => switch (tone) {
    V2StateTileTone.neutral => c.textMuted,
    V2StateTileTone.warn => c.warn,
    V2StateTileTone.danger => c.danger,
  };
}

/// Tone-tinted supporting line. Grows with the text instead of fixing its
/// height, so a detail such as `Resets in 6h 12m` can wrap at 200 % text.
class _StateDetail extends StatelessWidget {
  const _StateDetail({required this.label, required this.tone});

  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.xs,
      ),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: OType.caption.copyWith(
                color: tone,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
