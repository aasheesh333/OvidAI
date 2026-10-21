import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import '../library/artifact_detail_page.dart';
import 'transcript_actions.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// The real state of a tool row, derived from the durable `toolState` the
/// agent stores (`running`, `ok`, `error`, `stopped`). Older prose statuses
/// fall back to the progress value.
enum V2ToolState { running, done, failed, stopped, unknown }

V2ToolState v2ToolStateOf(String status, {double? progress}) {
  switch (status.trim().toLowerCase()) {
    case 'running':
    case 'streaming':
    case 'in progress':
    case 'working':
      return V2ToolState.running;
    case 'ok':
    case 'done':
    case 'success':
    case 'complete':
    case 'completed':
    case 'ready':
      return V2ToolState.done;
    case 'error':
    case 'failed':
    case 'failure':
      return V2ToolState.failed;
    case 'stopped':
    case 'cancelled':
    case 'canceled':
      return V2ToolState.stopped;
    case 'unknown':
      return V2ToolState.unknown;
  }
  if (progress != null) return progress >= 1 ? V2ToolState.done : V2ToolState.running;
  return V2ToolState.running;
}

/// Human label for a state token, or the prose the agent already wrote.
String v2ToolStatusLabel(String status, V2ToolState state) {
  final text = status.trim();
  const tokens = {
    'running',
    'streaming',
    'in progress',
    'working',
    'ok',
    'done',
    'success',
    'complete',
    'completed',
    'ready',
    'error',
    'failed',
    'failure',
    'stopped',
    'cancelled',
    'canceled',
    'unknown',
  };
  if (text.isNotEmpty && !tokens.contains(text.toLowerCase())) return text;
  return switch (state) {
    V2ToolState.running => 'Running',
    V2ToolState.done => 'Done',
    V2ToolState.failed => 'Failed',
    V2ToolState.stopped => 'Stopped',
    V2ToolState.unknown => 'Unknown',
  };
}

Color _toolTone(OColors c, V2ToolState state) => switch (state) {
  V2ToolState.running => c.accent,
  V2ToolState.done => c.success,
  V2ToolState.failed => c.danger,
  V2ToolState.stopped => c.warn,
  V2ToolState.unknown => c.textMuted,
};

/// One collapsible "thinking" row. The host owns [expanded]; tapping the row
/// asks for the opposite state, so the row never looks interactive while the
/// handler is missing.
class V2ThinkingTile extends StatelessWidget {
  const V2ThinkingTile({
    super.key,
    required this.label,
    required this.details,
    required this.expanded,
    required this.onToggle,
  });

  final String label;
  final List<String> details;
  final bool expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final canToggle = onToggle != null;
    return Material(
      color: c.surfaceAlt,
      borderRadius: BorderRadius.circular(ORadius.m),
      child: Semantics(
        button: canToggle,
        expanded: expanded,
        child: InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(ORadius.m),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: OSpace.touch),
            child: Padding(
              padding: const EdgeInsets.all(OSpace.m),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.psychology_rounded,
                        size: 18,
                        color: c.accent,
                      ),
                      const SizedBox(width: OSpace.s),
                      Expanded(
                        child: Text(
                          label,
                          style: OType.caption.copyWith(
                            color: c.textMuted,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (canToggle)
                        AnimatedRotation(
                          turns: expanded ? 0.25 : 0,
                          duration: OMotion.fast,
                          child: Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: c.textFaint,
                          ),
                        ),
                    ],
                  ),
                  if (expanded) ...[
                    const SizedBox(height: OSpace.s),
                    if (details.isEmpty)
                      Text(
                        'No further detail was recorded for this step.',
                        style: OType.caption.copyWith(color: c.textMuted),
                      )
                    else
                      for (final detail in details)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            detail,
                            style: OType.caption.copyWith(color: c.textMuted),
                          ),
                        ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A tool row with a real status badge, an expandable detail area and a
/// progress bar that only exists while the tool is running. A finished tool
/// has no indeterminate animation left on screen.
class V2ToolTile extends StatelessWidget {
  const V2ToolTile({
    super.key,
    required this.title,
    required this.status,
    required this.progress,
    this.icon = Icons.language_rounded,
    this.details = const <String>[],
    this.expanded = false,
    this.onToggle,
  });

  final String title;
  final String status;
  final double progress;
  final IconData icon;
  final List<String> details;
  final bool expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final state = v2ToolStateOf(status, progress: progress);
    final tone = _toolTone(c, state);
    final label = v2ToolStatusLabel(status, state);
    final canToggle = onToggle != null;
    final value = progress.clamp(0.0, 1.0).toDouble();

    return Material(
      color: c.surface,
      borderRadius: BorderRadius.circular(ORadius.l),
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(ORadius.l),
        child: Container(
          padding: const EdgeInsets.all(OSpace.m),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(ORadius.l),
            border: Border.all(color: c.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: tone.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(ORadius.s),
                    ),
                    child: Icon(icon, size: 17, color: tone),
                  ),
                  const SizedBox(width: OSpace.s),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: OType.bodySm.copyWith(
                            color: c.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            _ToolStateGlyph(state: state, tone: tone),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                label,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: OType.caption.copyWith(color: tone),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (canToggle)
                    AnimatedRotation(
                      turns: expanded ? 0.25 : 0,
                      duration: OMotion.fast,
                      child: Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: c.textFaint,
                      ),
                    ),
                ],
              ),
              if (state == V2ToolState.running) ...[
                const SizedBox(height: OSpace.m),
                OProgressBar(value: value),
              ],
              if (expanded) ...[
                const SizedBox(height: OSpace.s),
                Divider(height: 1, color: c.hairline),
                const SizedBox(height: OSpace.s),
                Text(
                  'Status: $label',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
                if (details.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      state == V2ToolState.running
                          ? 'Ovid is still working on this step.'
                          : 'This step has no extra output.',
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  )
                else
                  for (final detail in details)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        detail,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Static terminal glyph. Running shows a dot (no endless spin); every other
/// state shows a fixed icon, so a finished row is visually still.
class _ToolStateGlyph extends StatelessWidget {
  const _ToolStateGlyph({required this.state, required this.tone});

  final V2ToolState state;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    if (state == V2ToolState.running) {
      return Semantics(
        label: 'Running',
        child: Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
        ),
      );
    }
    final icon = switch (state) {
      V2ToolState.done => Icons.check_rounded,
      V2ToolState.failed => Icons.close_rounded,
      V2ToolState.stopped => Icons.stop_rounded,
      _ => Icons.help_outline_rounded,
    };
    return Icon(icon, size: 13, color: tone);
  }
}

/// The real state of a generated artifact, derived from the stored label.
enum V2ArtifactState { ready, working, failed, unknown }

V2ArtifactState v2ArtifactStateOf(String statusLabel) {
  switch (statusLabel.trim().toLowerCase()) {
    case 'ready':
    case 'done':
    case 'complete':
    case 'completed':
    case 'generated':
    case 'available':
      return V2ArtifactState.ready;
    case 'generating':
    case 'running':
    case 'building':
    case 'uploading':
    case 'queued':
      return V2ArtifactState.working;
    case 'failed':
    case 'error':
    case 'expired':
    case 'stopped':
      return V2ArtifactState.failed;
  }
  return V2ArtifactState.unknown;
}

/// A generated file in the transcript. Tapping it opens the artifact detail
/// route; the status pill uses the state the data actually carries instead of
/// claiming success for every card.
class V2ArtifactTile extends StatelessWidget {
  const V2ArtifactTile({
    super.key,
    required this.fileName,
    required this.meta,
    required this.statusLabel,
    required this.previewLabel,
    required this.onOpen,
    this.onDownload,
    this.icon = Icons.code_rounded,
  });

  final String fileName;
  final String meta;
  final String statusLabel;
  final String previewLabel;
  final VoidCallback onOpen;
  final VoidCallback? onDownload;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final state = v2ArtifactStateOf(statusLabel);
    final tone = switch (state) {
      V2ArtifactState.ready => OPillTone.success,
      V2ArtifactState.working => OPillTone.accent,
      V2ArtifactState.failed => OPillTone.danger,
      V2ArtifactState.unknown => OPillTone.neutral,
    };
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
          OPressable(
            onTap: onOpen,
            semanticLabel: 'Open $fileName',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(OSpace.m),
                  color: c.surfaceAlt,
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: c.accentSoft,
                          borderRadius: BorderRadius.circular(ORadius.s),
                        ),
                        child: Icon(icon, size: 17, color: c.accent),
                      ),
                      const SizedBox(width: OSpace.s),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              fileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: OType.bodySm.copyWith(
                                color: c.text,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              meta,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: OType.caption.copyWith(color: c.textMuted),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: OSpace.s),
                      Flexible(
                        child: OPill(
                          label: statusLabel,
                          tone: tone,
                          dot: true,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  constraints: const BoxConstraints(minHeight: 148),
                  color: c.codeBg,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(
                    horizontal: OSpace.m,
                    vertical: OSpace.l,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 34, color: c.accent),
                      const SizedBox(height: OSpace.s),
                      Text(
                        previewLabel,
                        textAlign: TextAlign.center,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (onDownload != null)
            Padding(
              padding: const EdgeInsets.all(OSpace.m),
              child: Row(
                children: [
                  Expanded(
                    child: OButton(
                      label: 'Download',
                      icon: Icons.download_rounded,
                      onPressed: onDownload,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Opens the real artifact detail route with everything the transcript knows.
Future<void> openV2ArtifactDetail(
  BuildContext context, {
  required String fileName,
  required String meta,
  required String statusLabel,
  required String previewLabel,
  IconData icon = Icons.code_rounded,
}) {
  final extension = fileName.contains('.')
      ? fileName.split('.').last.toLowerCase()
      : '';
  final previewKind = icon == Icons.image_outlined
      ? V2ArtifactPreviewKind.image
      : switch (extension) {
          'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'svg' =>
            V2ArtifactPreviewKind.image,
          'pdf' || 'doc' || 'docx' || 'txt' || 'md' => V2ArtifactPreviewKind.data,
          'dart' ||
          'js' ||
          'ts' ||
          'tsx' ||
          'py' ||
          'sh' ||
          'sql' ||
          'html' ||
          'htm' ||
          'json' ||
          'yaml' ||
          'yml' => V2ArtifactPreviewKind.code,
          _ => V2ArtifactPreviewKind.document,
        };
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ArtifactDetailPage(
        data: V2ArtifactDetailData(
          name: fileName,
          typeLabel: extension.isEmpty ? 'Artifact' : extension.toUpperCase(),
          versionLabel: statusLabel,
          previewKind: previewKind,
          previewHeadline: previewLabel,
          details: <V2ArtifactDetailRow>[
            V2ArtifactDetailRow(label: 'Preview', value: previewLabel),
            V2ArtifactDetailRow(label: 'Details', value: meta),
          ],
        ),
      ),
    ),
  );
}

/// Saves [href] to a real file (or opens it in the browser on web). Exposed so
/// the live chat page can wire artifact downloads without a host callback.
void startV2ArtifactDownload(
  BuildContext context,
  String href, {
  String? suggestedName,
}) {
  unawaited(v2SaveTranscriptLink(context, href, suggestedName: suggestedName));
}
