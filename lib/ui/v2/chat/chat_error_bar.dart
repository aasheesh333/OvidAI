import 'package:flutter/material.dart';

import '../../../core/cloud/cloud_errors.dart';
import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';

/// The inline error a chat shows when a send or a run fails.
///
/// It sits directly above the composer and keeps the transcript intact: a
/// failed send must never look like an empty chat, which is exactly what a
/// silently dropped message used to do.
@immutable
class V2ChatError {
  const V2ChatError({
    required this.text,
    required this.action,
    this.detail,
    this.resetsAt,
  });

  /// One or two plain sentences.
  final String text;

  /// What the primary button does.
  final CloudErrorAction action;

  /// The server's own text, shown only inside the details expander.
  final String? detail;

  /// The allowance reset instant for a 402.
  final DateTime? resetsAt;

  /// Builds the surface from a facade error code. Returns null when there is
  /// nothing to show.
  static V2ChatError? fromCode(
    String? code, {
    String? message,
    DateTime? resetsAt,
    DateTime? now,
  }) {
    if (code == null || code.isEmpty) return null;
    // These two are not failures the user must act on: a stop is expected, and
    // a conflict means the server already accepted the prompt.
    if (code == 'cancelled' || code == 'run_conflict') return null;
    final copy = cloudErrorCopy(
      code,
      message: message,
      resetsAt: resetsAt,
      now: now,
    );
    return V2ChatError(
      text: copy.text,
      action: copy.action,
      detail: copy.detail,
      resetsAt: resetsAt,
    );
  }

  /// The button label for [action], or null when there is no action.
  String? get actionLabel => switch (action) {
    CloudErrorAction.retry => 'Retry',
    CloudErrorAction.signIn => 'Sign in',
    CloudErrorAction.openPlans => 'See plans',
    CloudErrorAction.pickModel => 'Pick model',
    CloudErrorAction.wait => null,
    CloudErrorAction.none => null,
  };
}

/// One compact error row: tone icon, the message, an optional action, and a
/// details expander for the raw server text.
///
/// Deliberately not a full-screen state: the transcript stays visible so the
/// user keeps their place and can retry in context.
class V2ChatErrorBar extends StatefulWidget {
  const V2ChatErrorBar({
    super.key,
    required this.error,
    this.onAction,
    this.onDismiss,
  });

  final V2ChatError error;

  /// Runs the action named by [V2ChatError.actionLabel].
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;

  @override
  State<V2ChatErrorBar> createState() => _V2ChatErrorBarState();
}

class _V2ChatErrorBarState extends State<V2ChatErrorBar> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final label = widget.error.actionLabel;
    final detail = widget.error.detail;
    return Container(
      key: const Key('v2-chat-error'),
      margin: const EdgeInsets.only(bottom: OSpace.s),
      padding: const EdgeInsets.fromLTRB(OSpace.m, OSpace.s, OSpace.xs, OSpace.s),
      decoration: BoxDecoration(
        color: c.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.danger.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // The message owns the full width: an action beside it would
          // squeeze the text to a sliver at 200 % text.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.error_outline_rounded,
                  size: 18,
                  color: c.danger,
                ),
              ),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  widget.error.text,
                  style: OType.bodySm.copyWith(color: c.text),
                ),
              ),
            ],
          ),
          if ((label != null && widget.onAction != null) ||
              widget.onDismiss != null) ...[
            const SizedBox(height: OSpace.xxs),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (detail != null && detail.trim().isNotEmpty)
                  OTextAction(
                    label: _open ? 'Hide details' : 'Details',
                    onPressed: () => setState(() => _open = !_open),
                  ),
                if (label != null && widget.onAction != null)
                  OTextAction(label: label, onPressed: widget.onAction),
                if (widget.onDismiss != null)
                  OIconButton(
                    icon: Icons.close_rounded,
                    size: 18,
                    semanticLabel: 'Dismiss error',
                    onPressed: widget.onDismiss,
                  ),
              ],
            ),
          ] else if (detail != null && detail.trim().isNotEmpty)
            OTextAction(
              label: _open ? 'Hide details' : 'Details',
              onPressed: () => setState(() => _open = !_open),
            ),
          if (_open && detail != null && detail.trim().isNotEmpty) ...[
            const SizedBox(height: OSpace.xxs),
            Text(detail, style: OType.caption.copyWith(color: c.textMuted)),
          ],
        ],
      ),
    );
  }
}
