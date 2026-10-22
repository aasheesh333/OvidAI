import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// The recoverable states that can interrupt chat or a list.
///
/// Every state owns its icon, calm copy and one exit:
///
/// | State | Meaning | Action |
/// |---|---|---|
/// | [offline] | No connection; messages wait. | Retry |
/// | [planLimited] | The plan's allowance is spent. | See plans |
/// | [storageFull] | The account cannot accept new files. | Manage storage |
/// | [abuseBlocked] | The account is suspended pending review. | Contact support |
/// | [deletionPending] | An account deletion is scheduled. | Restore |
/// | [serverError] | A request failed on the service side. | Try again |
/// | [rateLimited] | Too many requests in a short window. | Try again after countdown |
/// | [updateRequired] | This build is too old to chat. | Open store |
enum V2StateTileKind {
  offline,
  planLimited,
  storageFull,
  abuseBlocked,
  deletionPending,
  serverError,
  rateLimited,
  updateRequired,
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
    message: 'Queued messages send when you reconnect.',
    actionLabel: 'Retry',
    actionVariant: OButtonVariant.secondary,
  );

  static const planLimited = V2StateTileCopy(
    icon: Icons.hourglass_top_rounded,
    title: 'Allowance used',
    message: "Your plan's allowance is spent.",
    actionLabel: 'See plans',
    tone: V2StateTileTone.warn,
  );

  static const storageFull = V2StateTileCopy(
    icon: Icons.storage_rounded,
    title: 'Storage full',
    message: 'New files cannot be saved.',
    actionLabel: 'Manage storage',
    tone: V2StateTileTone.warn,
  );

  static const abuseBlocked = V2StateTileCopy(
    icon: Icons.gpp_bad_rounded,
    title: 'Account blocked',
    message: 'Your account is suspended. Files are kept during review.',
    actionLabel: 'Contact support',
    actionVariant: OButtonVariant.secondary,
    tone: V2StateTileTone.danger,
  );

  static const deletionPending = V2StateTileCopy(
    icon: Icons.delete_sweep_rounded,
    title: 'Deletion pending',
    message: 'Restore before the deadline or your data is deleted.',
    actionLabel: 'Restore',
    tone: V2StateTileTone.warn,
  );

  static const serverError = V2StateTileCopy(
    icon: Icons.error_outline_rounded,
    title: 'Request failed',
    message: 'Your chats and changes are safe.',
    actionLabel: 'Try again',
    tone: V2StateTileTone.danger,
  );

  static const rateLimited = V2StateTileCopy(
    icon: Icons.speed_rounded,
    title: 'Rate limited',
    message: 'Too many requests. Wait for the countdown.',
    actionLabel: 'Try again',
    tone: V2StateTileTone.warn,
  );

  static const updateRequired = V2StateTileCopy(
    icon: Icons.system_update_alt_rounded,
    title: 'Update required',
    message: 'Install the latest version to keep chatting.',
    actionLabel: 'Open store',
    tone: V2StateTileTone.warn,
  );

  /// Defaults for [kind]. Stable enough for callers to [copyWith] one line.
  static V2StateTileCopy of(V2StateTileKind kind) => switch (kind) {
    V2StateTileKind.offline => offline,
    V2StateTileKind.planLimited => planLimited,
    V2StateTileKind.storageFull => storageFull,
    V2StateTileKind.abuseBlocked => abuseBlocked,
    V2StateTileKind.deletionPending => deletionPending,
    V2StateTileKind.serverError => serverError,
    V2StateTileKind.rateLimited => rateLimited,
    V2StateTileKind.updateRequired => updateRequired,
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
/// The tile is presentational except for one clock-driven detail: pass
/// [deadline] (a real instant, not a pre-formatted string) and the tile derives
/// a live countdown from it. The timer wakes at the coarsest interval the label
/// can show, and stops permanently once the deadline passes. A rate-limited
/// tile keeps its action disabled until that moment, so the person waits with
/// visible progress instead of retrying into the same wall.
///
/// Pass [onAction] (and [onSecondaryAction]) from the wiring layer. A null
/// callback renders its button disabled and announces that disabled state to
/// accessibility, so a preview never pretends a next step is available while a
/// production host always supplies the real route.
///
/// ```dart
/// V2StateTile.rateLimited(
///   deadline: blockedUntil,
///   onAction: () => retry(context),
/// )
/// ```
///
/// Use [V2StateTile.kind] when the state is chosen at runtime, and the named
/// constructors when the state is known at the call site.
class V2StateTile extends StatefulWidget {
  const V2StateTile({
    super.key,
    required this.kind,
    this.copy,
    this.deadline,
    this.clock,
    this.onAction,
    this.onSecondaryAction,
  });

  const V2StateTile.offline({
    super.key,
    this.copy,
    this.deadline,
    this.clock,
    this.onAction,
    this.onSecondaryAction,
  }) : kind = V2StateTileKind.offline;

  const V2StateTile.planLimited({
    super.key,
    this.copy,
    this.deadline,
    this.clock,
    this.onAction,
    this.onSecondaryAction,
  }) : kind = V2StateTileKind.planLimited;

  const V2StateTile.storageFull({
    super.key,
    this.copy,
    this.deadline,
    this.clock,
    this.onAction,
    this.onSecondaryAction,
  }) : kind = V2StateTileKind.storageFull;

  const V2StateTile.abuseBlocked({
    super.key,
    this.copy,
    this.deadline,
    this.clock,
    this.onAction,
    this.onSecondaryAction,
  }) : kind = V2StateTileKind.abuseBlocked;

  const V2StateTile.deletionPending({
    super.key,
    this.copy,
    this.deadline,
    this.clock,
    this.onAction,
    this.onSecondaryAction,
  }) : kind = V2StateTileKind.deletionPending;

  const V2StateTile.serverError({
    super.key,
    this.copy,
    this.deadline,
    this.clock,
    this.onAction,
    this.onSecondaryAction,
  }) : kind = V2StateTileKind.serverError;

  const V2StateTile.rateLimited({
    super.key,
    this.copy,
    this.deadline,
    this.clock,
    this.onAction,
    this.onSecondaryAction,
  }) : kind = V2StateTileKind.rateLimited;

  const V2StateTile.updateRequired({
    super.key,
    this.copy,
    this.deadline,
    this.clock,
    this.onAction,
    this.onSecondaryAction,
  }) : kind = V2StateTileKind.updateRequired;

  final V2StateTileKind kind;

  /// Replaces the default icon, copy and tone for [kind].
  final V2StateTileCopy? copy;

  /// The instant this state clears. The tile derives its countdown from this
  /// real timestamp; a past instant reads as "now" and never starts a timer.
  final DateTime? deadline;

  /// Clock source for the countdown. Defaults to [DateTime.now]; tests inject
  /// one so a tick can be proven without waiting a real second.
  final DateTime Function()? clock;

  final VoidCallback? onAction;
  final VoidCallback? onSecondaryAction;

  @override
  State<V2StateTile> createState() => _V2StateTileState();
}

class _V2StateTileState extends State<V2StateTile> {
  Timer? _timer;
  late DateTime _now;

  DateTime get _readClock => widget.clock?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _now = _readClock;
    _scheduleNextTick();
  }

  @override
  void didUpdateWidget(V2StateTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deadline != widget.deadline ||
        oldWidget.clock != widget.clock) {
      _now = _readClock;
      _scheduleNextTick();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// One-shot timer, re-armed after each tick. Far-out deadlines wake once an
  /// hour/minute because the label only shows those units; the last hour ticks
  /// every second. At the deadline no timer is armed, so the countdown stops.
  void _scheduleNextTick() {
    _timer?.cancel();
    _timer = null;
    final deadline = widget.deadline;
    if (deadline == null) return;
    final left = deadline.difference(_now);
    if (left <= Duration.zero) return;
    final interval = left > const Duration(days: 1)
        ? const Duration(hours: 1)
        : left > const Duration(hours: 1)
        ? const Duration(minutes: 1)
        : const Duration(seconds: 1);
    _timer = Timer(interval, _tick);
  }

  void _tick() {
    if (!mounted) return;
    setState(() => _now = _readClock);
    _scheduleNextTick();
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final resolved = widget.copy ?? V2StateTileCopy.of(widget.kind);
    final tone = _tone(c, resolved.tone);
    final secondary = resolved.secondaryActionLabel?.trim() ?? '';
    final actionLabel = resolved.actionLabel.trim();
    final deadline = widget.deadline;
    final remaining = deadline?.difference(_now);
    final countdown = remaining == null
        ? ''
        : _deadlineLabel(widget.kind, remaining);
    final ready = remaining == null || remaining <= Duration.zero;
    // The rate-limited exit is real only after the window closes. Every other
    // state's action works while its countdown is still running.
    final actionEnabled = widget.kind != V2StateTileKind.rateLimited || ready;

    return Semantics(
      container: true,
      explicitChildNodes: true,
      // A state tile replaces another state in place; announce the change
      // instead of waiting for the user to explore the screen again. The
      // countdown is excluded so TalkBack does not speak every second.
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
                // A bare tone icon, not a tinted medallion: the card is
                // already the surface.
                Padding(
                  padding: const EdgeInsets.only(top: OSpace.xxs),
                  child: ExcludeSemantics(
                    child: Icon(resolved.icon, size: 22, color: tone),
                  ),
                ),
                const SizedBox(width: OSpace.m),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title and body are one spoken unit: they describe a
                      // single condition, and splitting them makes TalkBack
                      // stop twice before the action.
                      Semantics(
                        container: true,
                        label: '${resolved.title}. ${resolved.message}',
                        excludeSemantics: true,
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
                          ],
                        ),
                      ),
                      if (countdown.isNotEmpty) ...[
                        const SizedBox(height: OSpace.s),
                        Semantics(
                          container: true,
                          label: countdown,
                          excludeSemantics: true,
                          child: Text(
                            countdown,
                            style: OType.caption.copyWith(
                              color: tone,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (actionLabel.isNotEmpty) ...[
              const SizedBox(height: OSpace.m),
              OButton(
                label: resolved.actionLabel,
                variant: resolved.actionVariant,
                onPressed: actionEnabled ? widget.onAction : null,
                expand: true,
              ),
            ],
            if (secondary.isNotEmpty) ...[
              const SizedBox(height: OSpace.xs),
              OButton(
                label: secondary,
                variant: resolved.secondaryActionVariant,
                onPressed: widget.onSecondaryAction,
                expand: true,
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _deadlineLabel(V2StateTileKind kind, Duration remaining) {
    final prefix = switch (kind) {
      V2StateTileKind.planLimited => 'Resets',
      V2StateTileKind.rateLimited => 'Ready',
      V2StateTileKind.deletionPending => 'Restore',
      _ => 'Ends',
    };
    return remaining <= Duration.zero
        ? '$prefix now'
        : '$prefix in ${_formatRemaining(remaining)}';
  }

  static String _formatRemaining(Duration remaining) {
    final seconds = remaining.inSeconds;
    if (seconds <= 0) return '0s';
    final days = seconds ~/ Duration.secondsPerDay;
    final hours = (seconds % Duration.secondsPerDay) ~/ Duration.secondsPerHour;
    final minutes =
        (seconds % Duration.secondsPerHour) ~/ Duration.secondsPerMinute;
    final secs = seconds % Duration.secondsPerMinute;
    if (days > 0) return '${days}d ${hours}h';
    if (hours > 0) return '${hours}h ${minutes}m';
    if (minutes > 0) return '${minutes}m ${secs}s';
    return '${secs}s';
  }

  static Color _tone(OColors c, V2StateTileTone tone) => switch (tone) {
    V2StateTileTone.neutral => c.textMuted,
    V2StateTileTone.warn => c.warn,
    V2StateTileTone.danger => c.danger,
  };
}
