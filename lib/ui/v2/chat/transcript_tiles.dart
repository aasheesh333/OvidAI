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
  if (progress != null) {
    return progress >= 1 ? V2ToolState.done : V2ToolState.running;
  }
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
/// handler is missing. Collapsed it is a single line with a chevron; the
/// chevron is the only affordance.
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
    final canToggle = onToggle != null && details.isNotEmpty;
    // A thinking row is a status line, not a card: no fill, no border.
    return Material(
      color: Colors.transparent,
      child: Semantics(
        button: canToggle,
        expanded: expanded,
        child: InkWell(
          onTap: canToggle ? onToggle : null,
          borderRadius: BorderRadius.circular(ORadius.s),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: OSpace.touch),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: OSpace.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.psychology_rounded, size: 18, color: c.accent),
                      const SizedBox(width: OSpace.s),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
                  if (expanded && details.isNotEmpty) ...[
                    const SizedBox(height: OSpace.s),
                    for (var i = 0; i < details.length; i++)
                      Padding(
                        padding: EdgeInsets.only(top: i == 0 ? 0 : OSpace.xs),
                        child: Text(
                          details[i],
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

/// A tool row with a real status glyph, an expandable detail area and a
/// progress bar that only exists while the tool is running. A finished tool
/// has no indeterminate animation left on screen. Collapsed it is one line;
/// the chevron is the only affordance.
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
    final canToggle = onToggle != null && details.isNotEmpty;
    final value = progress.clamp(0.0, 1.0).toDouble();

    return Material(
      color: c.surface,
      borderRadius: BorderRadius.circular(ORadius.l),
      child: Semantics(
        button: canToggle,
        expanded: expanded,
        child: InkWell(
          onTap: canToggle ? onToggle : null,
          borderRadius: BorderRadius.circular(ORadius.l),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: OSpace.m,
              vertical: OSpace.s,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(ORadius.l),
              border: Border.all(color: c.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 32),
                  child: Row(
                    children: [
                      // The state glyph replaces the tool-type icon: one icon
                      // carries the outcome, so the row stays one line.
                      _ToolStateGlyph(
                        state: state,
                        tone: tone,
                        label: label,
                        fallbackIcon: icon,
                      ),
                      const SizedBox(width: OSpace.s),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OType.bodySmStrong.copyWith(color: c.text),
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
                ),
                if (state == V2ToolState.running) ...[
                  const SizedBox(height: OSpace.s),
                  OProgressBar(value: value),
                ],
                if (expanded && details.isNotEmpty) ...[
                  const SizedBox(height: OSpace.s),
                  Divider(height: 1, color: c.hairline),
                  const SizedBox(height: OSpace.s),
                  // The glyph already carries the outcome; repeating it as
                  // "Status: Done" only adds a line.
                  for (var i = 0; i < details.length; i++)
                    Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 0 : OSpace.xs),
                      child: Text(
                        details[i],
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
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

/// Static terminal glyph. Running shows a dot (no endless spin); every other
/// state shows a fixed icon, so a finished row is visually still.
class _ToolStateGlyph extends StatelessWidget {
  const _ToolStateGlyph({
    required this.state,
    required this.tone,
    required this.label,
    required this.fallbackIcon,
  });

  final V2ToolState state;
  final Color tone;
  final String label;

  /// Shown when the host gave no recognisable state token.
  final IconData fallbackIcon;

  @override
  Widget build(BuildContext context) {
    if (state == V2ToolState.running) {
      return Semantics(
        label: label,
        child: SizedBox(
          width: 16,
          height: 16,
          child: Center(
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
            ),
          ),
        ),
      );
    }
    final icon = switch (state) {
      V2ToolState.done => Icons.check_rounded,
      V2ToolState.failed => Icons.close_rounded,
      V2ToolState.stopped => Icons.stop_rounded,
      _ => fallbackIcon,
    };
    return Semantics(
      label: label,
      child: SizedBox(
        width: 16,
        height: 16,
        child: Icon(icon, size: 16, color: tone),
      ),
    );
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

/// A generated file in the transcript. One row: file name, meta and a
/// download control. Tapping the row opens the artifact detail route; the
/// status pill only appears while the file is not ready.
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
      child: OPressable(
        onTap: onOpen,
        semanticLabel: 'Open $fileName',
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            OSpace.m,
            OSpace.s,
            OSpace.xs,
            OSpace.s,
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: c.accent),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      fileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: OType.bodySmStrong.copyWith(color: c.text),
                    ),
                    const SizedBox(height: OSpace.xxs),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: OType.caption.copyWith(color: c.textMuted),
                          ),
                        ),
                        // "Ready" is the default and repeats the row itself;
                        // only a state the user must act on gets a pill.
                        if (state != V2ArtifactState.ready) ...[
                          const SizedBox(width: OSpace.s),
                          Flexible(
                            child: OPill(
                              label: statusLabel,
                              tone: tone,
                              dot: true,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (onDownload != null)
                OIconButton(
                  icon: Icons.download_rounded,
                  semanticLabel: 'Download $fileName',
                  size: 20,
                  onPressed: onDownload,
                ),
              Icon(Icons.chevron_right_rounded, size: 18, color: c.textFaint),
            ],
          ),
        ),
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
          'png' ||
          'jpg' ||
          'jpeg' ||
          'gif' ||
          'webp' ||
          'svg' => V2ArtifactPreviewKind.image,
          'pdf' ||
          'doc' ||
          'docx' ||
          'txt' ||
          'md' => V2ArtifactPreviewKind.data,
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
