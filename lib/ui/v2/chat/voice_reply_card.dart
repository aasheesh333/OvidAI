import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// One metric on a voice reply's visual card ("Steps", "6,420").
@immutable
class V2VoiceMetric {
  const V2VoiceMetric({required this.label, required this.value});

  final String label;
  final String value;
}

/// The durable, readable half of a voice-first answer.
///
/// The spoken note is best-effort (device TTS); this card is what the user can
/// still read, scan and act on when audio is unavailable or unwanted.
@immutable
class V2VoiceReplyData {
  const V2VoiceReplyData({
    required this.title,
    this.subtitle,
    this.metrics = const [],
    this.image,
    this.imageLabel,
    this.actionLabel,
    this.actionIcon = Icons.arrow_forward_rounded,
    this.transcript,
    this.duration = Duration.zero,
    this.position = Duration.zero,
    this.playing = false,
  });

  /// Headline of the visual summary ("Your portfolio is ready").
  final String title;

  /// One-line explanation under the headline.
  final String? subtitle;

  /// Zero to three short facts. More than three do not fit the card.
  final List<V2VoiceMetric> metrics;

  /// Optional preview image (a generated screenshot, chart or map).
  final ImageProvider? image;

  /// Accessible description for [image].
  final String? imageLabel;

  /// Label for the single next action, when there is one.
  final String? actionLabel;

  final IconData actionIcon;

  /// What Ovid said, verbatim. Shown only when the user asks for it.
  final String? transcript;

  /// Total length of the spoken reply.
  final Duration duration;

  /// How far playback has reached. Ignored when longer than [duration].
  final Duration position;

  /// Whether the note is playing right now.
  final bool playing;

  bool get hasTranscript => transcript != null && transcript!.trim().isNotEmpty;

  /// Playback progress in the range 0–1.
  double get progress {
    final total = duration.inMilliseconds;
    if (total <= 0) return 0;
    final at = position.inMilliseconds.clamp(0, total);
    return at / total;
  }
}

/// `m:ss`, or `h:mm:ss` once the note passes an hour.
String formatVoiceDuration(Duration value) {
  final totalSeconds = value.inSeconds < 0 ? 0 : value.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  final twoDigits = seconds.toString().padLeft(2, '0');
  if (minutes >= 60) {
    final hours = minutes ~/ 60;
    final rest = (minutes % 60).toString().padLeft(2, '0');
    return '$hours:$rest:$twoDigits';
  }
  return '$minutes:$twoDigits';
}

/// A voice note plus its visual summary card.
///
/// Everything is injected: the host owns playback and the transcript
/// expansion, so this widget never talks to audio APIs or app state.
class V2VoiceReplyCard extends StatelessWidget {
  const V2VoiceReplyCard({
    super.key,
    required this.data,
    this.transcriptExpanded = false,
    this.onPlay,
    this.onSeek,
    this.onOpenAction,
    this.onToggleTranscript,
  });

  final V2VoiceReplyData data;

  /// Whether the transcript is currently open.
  final bool transcriptExpanded;

  /// Play or pause the note.
  final VoidCallback? onPlay;

  /// Jump to a position chosen on the waveform.
  final ValueChanged<Duration>? onSeek;

  /// Run the card's single next action.
  final VoidCallback? onOpenAction;

  /// Show or hide the transcript. Receives the requested state.
  final ValueChanged<bool>? onToggleTranscript;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final total = data.duration;
    final position = data.position > total ? total : data.position;
    final seekable = onSeek != null && total > Duration.zero;
    // A transport row with no play handler and no audio is a dead control.
    final hasTransport = onPlay != null || total > Duration.zero;

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasTransport)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                OSpace.s,
                OSpace.s,
                OSpace.m,
                OSpace.s,
              ),
              child: Row(
                children: [
                  if (onPlay != null)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: c.accentSoft,
                        shape: BoxShape.circle,
                      ),
                      child: OIconButton(
                        icon: data.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        semanticLabel: data.playing
                            ? 'Pause voice reply'
                            : 'Play voice reply',
                        active: data.playing,
                        onPressed: onPlay,
                      ),
                    ),
                  if (onPlay != null) const SizedBox(width: OSpace.s),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _VoiceWaveform(
                          progress: data.progress,
                          duration: total,
                          enabled: seekable,
                          onSeek: onSeek,
                        ),
                        const SizedBox(height: OSpace.xs),
                        // The time is the only text under the waveform; the
                        // waveform itself already says this is audio.
                        Text(
                          '${formatVoiceDuration(position)} / '
                          '${formatVoiceDuration(total)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (hasTransport) Divider(height: 1, color: c.hairline),
          Padding(
            padding: const EdgeInsets.all(OSpace.l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            data.title,
                            style: OType.h3.copyWith(color: c.text),
                          ),
                          if (data.subtitle != null) ...[
                            const SizedBox(height: OSpace.xs),
                            Text(
                              data.subtitle!,
                              style: OType.bodySm.copyWith(color: c.textMuted),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (data.image != null) ...[
                      const SizedBox(width: OSpace.m),
                      _VoiceImage(
                        image: data.image!,
                        label: data.imageLabel ?? 'Reply image',
                      ),
                    ],
                  ],
                ),
                if (data.metrics.isNotEmpty) ...[
                  const SizedBox(height: OSpace.l),
                  _VoiceMetrics(metrics: data.metrics),
                ],
                if (data.actionLabel != null && onOpenAction != null) ...[
                  const SizedBox(height: OSpace.l),
                  OButton(
                    label: data.actionLabel!,
                    icon: data.actionIcon,
                    variant: OButtonVariant.secondary,
                    expand: true,
                    onPressed: onOpenAction,
                  ),
                ],
              ],
            ),
          ),
          if (data.hasTranscript) ...[
            if (onToggleTranscript != null) ...[
              Divider(height: 1, color: c.hairline),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: OSpace.s),
                child: OButton(
                  label: transcriptExpanded
                      ? 'Hide transcript'
                      : 'Show transcript',
                  icon: transcriptExpanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  variant: OButtonVariant.ghost,
                  expand: true,
                  onPressed: () => onToggleTranscript!(!transcriptExpanded),
                ),
              ),
            ] else if (transcriptExpanded)
              Divider(height: 1, color: c.hairline),
            if (transcriptExpanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  OSpace.l,
                  0,
                  OSpace.l,
                  OSpace.l,
                ),
                child: Container(
                  padding: const EdgeInsets.all(OSpace.m),
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(ORadius.m),
                  ),
                  child: Text(
                    data.transcript!,
                    style: OType.bodySm.copyWith(color: c.text),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// A deterministic bar waveform. Tapping or dragging seeks.
class _VoiceWaveform extends StatelessWidget {
  const _VoiceWaveform({
    required this.progress,
    required this.duration,
    required this.enabled,
    required this.onSeek,
  });

  final double progress;
  final Duration duration;
  final bool enabled;
  final ValueChanged<Duration>? onSeek;

  /// Hand-tuned heights so the waveform reads as speech, not random noise.
  static const _bars = <double>[
    0.32,
    0.52,
    0.42,
    0.72,
    0.55,
    0.88,
    0.62,
    0.38,
    0.68,
    0.94,
    0.70,
    0.46,
    0.60,
    0.82,
    0.52,
    0.34,
    0.58,
    0.78,
    0.66,
    0.44,
    0.86,
    0.58,
    0.40,
    0.70,
    0.50,
    0.30,
    0.62,
    0.48,
  ];

  static const double _height = 34;

  void _seekAt(double dx, double width) {
    if (!enabled || width <= 0 || onSeek == null) return;
    final fraction = (dx / width).clamp(0.0, 1.0);
    onSeek!(
      Duration(milliseconds: (duration.inMilliseconds * fraction).round()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final value =
        '${formatVoiceDuration(Duration(milliseconds: (duration.inMilliseconds * progress).round()))} of ${formatVoiceDuration(duration)}';
    return Semantics(
      label: enabled ? 'Seek voice reply' : 'Voice reply waveform',
      value: value,
      slider: enabled,
      enabled: enabled,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return GestureDetector(
            key: const ValueKey('voice-reply-waveform'),
            behavior: HitTestBehavior.opaque,
            onTapDown: enabled
                ? (details) => _seekAt(details.localPosition.dx, width)
                : null,
            onHorizontalDragUpdate: enabled
                ? (details) => _seekAt(details.localPosition.dx, width)
                : null,
            child: SizedBox(
              height: _height,
              child: Row(
                children: [
                  for (var i = 0; i < _bars.length; i++) ...[
                    if (i > 0) const SizedBox(width: OSpace.xxs),
                    Expanded(
                      child: Align(
                        alignment: Alignment.center,
                        child: Container(
                          width: double.infinity,
                          height: _height * _bars[i],
                          decoration: BoxDecoration(
                            color: (i + 0.5) / _bars.length <= progress
                                ? c.accentFill
                                : c.surfaceRaised,
                            borderRadius: BorderRadius.circular(ORadius.xs),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _VoiceImage extends StatelessWidget {
  const _VoiceImage({required this.image, required this.label});

  final ImageProvider image;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      image: true,
      label: label,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ORadius.m),
        child: Image(
          image: image,
          width: 72,
          height: 72,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => Container(
            width: 72,
            height: 72,
            color: c.surfaceAlt,
            alignment: Alignment.center,
            child: Icon(Icons.image_outlined, size: 24, color: c.textFaint),
          ),
        ),
      ),
    );
  }
}

class _VoiceMetrics extends StatelessWidget {
  const _VoiceMetrics({required this.metrics});

  final List<V2VoiceMetric> metrics;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    return LayoutBuilder(
      builder: (context, constraints) {
        // At 320 dp, or with large text, a row of three leaves each value
        // about 60 px. Stack instead of ellipsising every fact.
        if (metrics.length > 1 &&
            (constraints.maxWidth < 260 || textScale > 1.3)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < metrics.length; i++)
                Padding(
                  padding: EdgeInsets.only(
                    bottom: i == metrics.length - 1 ? 0 : OSpace.s,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        flex: 2,
                        child: Text(
                          metrics[i].label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ),
                      const SizedBox(width: OSpace.m),
                      Flexible(
                        flex: 3,
                        child: Text(
                          metrics[i].value,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                          style: OType.bodyStrong.copyWith(color: c.text),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < metrics.length; i++)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    right: i == metrics.length - 1 ? 0 : OSpace.m,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        metrics[i].value,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: OType.h3.copyWith(color: c.text),
                      ),
                      const SizedBox(height: OSpace.xxs),
                      Text(
                        metrics[i].label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
