import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

enum V2TakeControlStatus { ready, loading, ended, error }

/// State for the hand-over sheet. The server does not put a timer on human
/// control, so there is no countdown to show.
@immutable
class V2TakeControlData {
  const V2TakeControlData({
    this.status = V2TakeControlStatus.ready,
    this.errorMessage = 'Ovid could not pause the page. Try again.',
  });

  final V2TakeControlStatus status;
  final String errorMessage;
}

/// Bottom sheet that hands the live page to the person.
///
/// One title, one line, two buttons. What pauses and when Ovid resumes are
/// facts the person learns by using it, not paragraphs to read first.
class TakeControlSheet extends StatelessWidget {
  const TakeControlSheet({
    super.key,
    required this.data,
    this.onStart,
    this.onStayWatching,
    this.onRetry,
    this.scrim = true,
  });

  final V2TakeControlData data;
  final VoidCallback? onStart;
  final VoidCallback? onStayWatching;
  final VoidCallback? onRetry;
  final bool scrim;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.9;
    final panel = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 560, maxHeight: maxHeight),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(ORadius.xl),
          ),
          border: Border.all(color: c.hairline),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              OSpace.xl,
              OSpace.s,
              OSpace.xl,
              OSpace.l,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: c.hairlineStrong,
                    borderRadius: BorderRadius.circular(ORadius.xs),
                  ),
                ),
                const SizedBox(height: OSpace.l),
                Flexible(
                  child: _PanelBody(
                    data: data,
                    onStart: onStart,
                    onStayWatching: onStayWatching,
                    onRetry: onRetry,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final content = Align(
      alignment: Alignment.bottomCenter,
      child: OFadeSlide(offset: const Offset(0, 0.06), child: panel),
    );

    if (!scrim) return content;
    return Stack(
      children: [
        Positioned.fill(
          // The barrier is a shortcut for "Stay watching"; the visible button
          // carries the action and the label, so the barrier itself is kept
          // out of the semantics tree instead of being announced unlabelled.
          child: ExcludeSemantics(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onStayWatching,
              child: ColoredBox(color: c.scrim),
            ),
          ),
        ),
        content,
      ],
    );
  }
}

class _PanelBody extends StatelessWidget {
  const _PanelBody({
    required this.data,
    this.onStart,
    this.onStayWatching,
    this.onRetry,
  });

  final V2TakeControlData data;
  final VoidCallback? onStart;
  final VoidCallback? onStayWatching;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return switch (data.status) {
      V2TakeControlStatus.loading => const SizedBox(
        height: 160,
        child: OLoadingState(label: 'Pausing Ovid…'),
      ),
      V2TakeControlStatus.ended => _Message(
        title: 'Control ended',
        body: 'Ovid is watching this tab again.',
        action: onStayWatching == null
            ? null
            : OButton(
                label: 'Back to browser',
                expand: true,
                onPressed: onStayWatching,
              ),
      ),
      V2TakeControlStatus.error => _Message(
        title: 'Could not pause',
        body: data.errorMessage,
        action: onRetry == null
            ? null
            : OButton(label: 'Try again', expand: true, onPressed: onRetry),
      ),
      V2TakeControlStatus.ready => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            OSheetHeader(
              title: 'Take control',
              body: 'Tap, type and scroll. Ovid pauses until you hand back.',
              onClose: onStayWatching,
              padding: EdgeInsets.zero,
            ),
            const SizedBox(height: OSpace.l),
            if (onStart != null)
              OButton(
                label: 'Start controlling',
                expand: true,
                onPressed: onStart,
              ),
            if (onStart != null && onStayWatching != null)
              const SizedBox(height: OSpace.s),
            if (onStayWatching != null)
              OButton(
                label: 'Stay watching',
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: onStayWatching,
              ),
          ],
        ),
      ),
    };
  }
}

/// One title, one line, one action. Used by the non-ready states so they keep
/// the same shape as the sheet without adding more copy.
class _Message extends StatelessWidget {
  const _Message({required this.title, required this.body, this.action});

  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            container: true,
            header: true,
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: OType.h2.copyWith(color: c.text),
            ),
          ),
          const SizedBox(height: OSpace.s),
          Text(
            body,
            textAlign: TextAlign.center,
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
          if (action != null) ...[const SizedBox(height: OSpace.l), action!],
        ],
      ),
    );
  }
}
