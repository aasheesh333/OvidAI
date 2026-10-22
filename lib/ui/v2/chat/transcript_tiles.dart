import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../core/artifact_kind.dart';
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import '../library/artifact_actions.dart';
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

/// One collapsible "thinking" line — "Thought for a moment" — that expands to
/// the details. The host owns [expanded]; tapping the line asks for the
/// opposite state, so it never looks interactive while the handler is missing.
/// There is no icon and no card: the muted line is the whole row, the chevron
/// the only affordance. While [running] the label carries a subtle shimmer;
/// a finished thought is still.
class V2ThinkingTile extends StatelessWidget {
  const V2ThinkingTile({
    super.key,
    required this.label,
    required this.details,
    required this.expanded,
    required this.onToggle,
    this.running = false,
  });

  final String label;
  final List<String> details;
  final bool expanded;
  final VoidCallback? onToggle;

  /// True while this thought is the live tail of an active run. Drives the
  /// shimmer; when the run ends the line is plain muted text again.
  final bool running;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final canToggle = onToggle != null && details.isNotEmpty;
    final labelStyle = OType.caption.copyWith(
      color: c.textMuted,
      fontWeight: FontWeight.w500,
    );
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
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: running
                            ? _ShimmerLine(text: label, style: labelStyle)
                            : Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: labelStyle,
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

/// A soft light sweep across a line of text while work is in flight. Honours
/// reduced motion (renders the plain line) and never runs after the caller
/// stops mounting it.
class _ShimmerLine extends StatefulWidget {
  const _ShimmerLine({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_ShimmerLine> createState() => _ShimmerLineState();
}

class _ShimmerLineState extends State<_ShimmerLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: OMotion.ambient,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (OMove.reduced(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Text(
      widget.text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: widget.style,
    );
    if (OMove.reduced(context)) return text;
    // Flat system: the thinking line breathes its opacity instead of sweeping
    // a gradient through the text.
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        final pulse = 0.6 + (t < 0.5 ? t : 1 - t) * 0.4;
        return Opacity(opacity: pulse, child: child);
      },
      child: text,
    );
  }
}

/// A tool is one quiet line: the state glyph, the title, and a chevron when
/// it can expand. No card, no border. The progress bar exists only while the
/// tool runs, so a finished row is visually still.
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
      color: Colors.transparent,
      child: Semantics(
        button: canToggle,
        expanded: expanded,
        child: InkWell(
          onTap: canToggle ? onToggle : null,
          borderRadius: BorderRadius.circular(ORadius.s),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: OSpace.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: OSpace.touch),
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
                          style: OType.bodySm.copyWith(color: c.text),
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
                if (state == V2ToolState.running)
                  Padding(
                    padding: const EdgeInsets.only(
                      left: OSpace.xl,
                      bottom: OSpace.s,
                    ),
                    child: OProgressBar(value: value),
                  ),
                if (expanded && details.isNotEmpty) ...[
                  const SizedBox(height: OSpace.xs),
                  // The glyph already carries the outcome; repeating it as
                  // "Status: Done" only adds a line.
                  for (var i = 0; i < details.length; i++)
                    Padding(
                      padding: EdgeInsets.only(
                        left: OSpace.xl,
                        bottom: OSpace.xs,
                        top: i == 0 ? 0 : OSpace.xxs,
                      ),
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

/// A generated file in the transcript. One row: a real thumbnail (or the type
/// glyph), the file name, one meta line and one menu. Tapping the row opens
/// the artifact detail route; the status pill only appears while the file is
/// not ready.
///
/// The menu holds only actions that can really run: Preview (the detail page's
/// preview), Copy (the file's text, or its link when only a link exists) and
/// Download (a real URL). A missing handler hides its row instead of leaving a
/// dead control.
class V2ArtifactTile extends StatelessWidget {
  const V2ArtifactTile({
    super.key,
    required this.fileName,
    required this.meta,
    required this.statusLabel,
    required this.previewLabel,
    required this.onOpen,
    this.onDownload,
    this.onCopy,
    this.copyText = true,
    this.icon = Icons.code_rounded,
    this.thumbnail,
  });

  final String fileName;
  final String meta;
  final String statusLabel;
  final String previewLabel;
  final VoidCallback onOpen;

  /// Saves the file from a URL the host really has. Null hides Download.
  final VoidCallback? onDownload;

  /// Puts the artifact's content (or its link) on the clipboard. Null hides
  /// Copy.
  final VoidCallback? onCopy;

  /// True when Copy puts the file's text on the clipboard, so the menu says
  /// "Copy"; false when only a link can be copied, so it says "Copy link".
  final bool copyText;

  final IconData icon;

  /// Real pixels for an image artifact. Null keeps the type glyph: the row
  /// never draws a fake preview.
  final ImageProvider? thumbnail;

  bool get _hasMenu => onCopy != null || onDownload != null;

  /// The Preview row already says "Preview"; repeating that as its subtitle
  /// adds a line without adding information.
  String get _previewSubtitle => previewLabel.trim();

  bool get _showPreviewSubtitle =>
      _previewSubtitle.isNotEmpty &&
      _previewSubtitle.toLowerCase() != 'preview';

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
              _leading(c),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // One line plus one meta line: the row never wraps into a
                    // paragraph, at 320 dp or 200 % text.
                    Text(
                      fileName,
                      maxLines: 1,
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
              if (_hasMenu)
                OIconButton(
                  icon: Icons.more_vert_rounded,
                  semanticLabel: 'Actions for $fileName',
                  size: 20,
                  onPressed: () => _openMenu(context),
                ),
              Icon(Icons.chevron_right_rounded, size: 18, color: c.textFaint),
            ],
          ),
        ),
      ),
    );
  }

  /// The image thumbnail when the host has real pixels, else the type glyph.
  Widget _leading(OColors c) {
    final image = thumbnail;
    if (image == null) {
      return Icon(icon, size: 20, color: c.accent);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(ORadius.s),
      child: Image(
        image: ResizeImage.resizeIfNeeded(80, null, image),
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        // A broken or expired image falls back to the glyph rather than
        // leaving an empty hole.
        errorBuilder: (_, _, _) => SizedBox(
          width: 40,
          height: 40,
          child: Center(child: Icon(icon, size: 20, color: c.accent)),
        ),
      ),
    );
  }

  Future<void> _openMenu(BuildContext context) async {
    final action = await showOSheet<String>(
      context,
      title: fileName,
      builder: (sheetContext) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: OSpace.l),
        children: [
          OListRow(
            title: 'Preview',
            // The host already knows what the preview shows; the menu row is
            // where that context belongs, so it is not dead data.
            subtitle: _showPreviewSubtitle ? _previewSubtitle : null,
            icon: Icons.visibility_outlined,
            showChevron: false,
            onTap: () => Navigator.of(sheetContext).pop('preview'),
          ),
          if (onCopy != null)
            OListRow(
              title: copyText ? 'Copy' : 'Copy link',
              icon: Icons.copy_rounded,
              showChevron: false,
              onTap: () => Navigator.of(sheetContext).pop('copy'),
            ),
          if (onDownload != null)
            OListRow(
              title: 'Download',
              icon: Icons.download_rounded,
              showChevron: false,
              onTap: () => Navigator.of(sheetContext).pop('download'),
            ),
        ],
      ),
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case 'preview':
        onOpen();
      case 'copy':
        onCopy?.call();
      case 'download':
        onDownload?.call();
    }
  }
}

/// The detail preview family the artifact model implies, when the host knows
/// the real kind. Falls back to the file name for older rows.
V2ArtifactPreviewKind v2ArtifactPreviewKindOf(
  String name, {
  ArtifactKind? kind,
}) => switch (kind) {
  ArtifactKind.image => V2ArtifactPreviewKind.image,
  ArtifactKind.html || ArtifactKind.code => V2ArtifactPreviewKind.code,
  ArtifactKind.document => V2ArtifactPreviewKind.document,
  ArtifactKind.other => V2ArtifactPreviewKind.data,
  null => v2ArtifactPreviewKindForName(name),
};

/// True for files whose text Copy can really read: code and pages always,
/// documents only when the extension is textual. Images and binaries are not.
bool v2ArtifactIsTextual(String name, {ArtifactKind? kind}) => switch (kind) {
  ArtifactKind.code || ArtifactKind.html => true,
  ArtifactKind.image => false,
  ArtifactKind.document || ArtifactKind.other => artifactIsText(name),
  null => artifactIsText(name),
};

/// `14.2 KB` for a real byte count; empty when the size is unknown.
String v2ArtifactSizeLabel(int? bytes) {
  final value = bytes ?? 0;
  if (value <= 0) return '';
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// What a Copy action really put on the clipboard.
enum V2ArtifactCopyResult { text, link, failed }

/// A bounded head of the file behind [url], or null when it cannot be read.
///
/// Same limits as the library's detail host: 1 MiB and 20 s. The cap keeps a
/// huge file from stalling the tap; the caller falls back to the link.
const int v2ArtifactCopyMaxBytes = 1024 * 1024;
const int v2ArtifactCopyMaxLines = 200;

Future<String?> _fetchArtifactText(String url, {http.Client? client}) async {
  final owned = client == null;
  final httpClient = client ?? http.Client();
  try {
    final response = await httpClient
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    if (response.bodyBytes.length > v2ArtifactCopyMaxBytes) return null;
    final decoded = utf8.decode(response.bodyBytes, allowMalformed: true);
    return decoded.split('\n').take(v2ArtifactCopyMaxLines).join('\n');
  } catch (_) {
    return null;
  } finally {
    if (owned) httpClient.close();
  }
}

/// Copies the artifact's real content: the text the host already has, else the
/// file's head fetched from [url], else the link itself.
///
/// The result says which of those really happened, so the caller never shows a
/// "Copied" confirmation for an empty clipboard.
Future<V2ArtifactCopyResult> v2CopyArtifactContent({
  required String fileName,
  String? content,
  String? url,
  ArtifactKind? kind,
  http.Client? client,
}) async {
  final inline = content?.trim() ?? '';
  if (inline.isNotEmpty) {
    return await v2CopyArtifactText(inline)
        ? V2ArtifactCopyResult.text
        : V2ArtifactCopyResult.failed;
  }
  final link = url?.trim() ?? '';
  if (link.isEmpty) return V2ArtifactCopyResult.failed;
  if (v2ArtifactIsTextual(fileName, kind: kind)) {
    final fetched = await _fetchArtifactText(link, client: client);
    if (fetched != null && fetched.trim().isNotEmpty) {
      return await v2CopyArtifactText(fetched)
          ? V2ArtifactCopyResult.text
          : V2ArtifactCopyResult.failed;
    }
  }
  return await v2CopyArtifactText(link)
      ? V2ArtifactCopyResult.link
      : V2ArtifactCopyResult.failed;
}

/// Opens the real artifact detail route with everything the transcript knows.
///
/// The preview, size and Download come from the artifact itself; when a field
/// is unknown the page shows less rather than inventing it.
Future<void> openV2ArtifactDetail(
  BuildContext context, {
  required String fileName,
  required String meta,
  required String statusLabel,
  required String previewLabel,
  IconData icon = Icons.code_rounded,
  ArtifactKind? kind,
  int? sizeBytes,
  String? downloadUrl,
  String? content,
  ImageProvider? thumbnail,
}) {
  final extension = fileName.contains('.')
      ? fileName.split('.').last.toLowerCase()
      : '';
  final previewKind = icon == Icons.image_outlined
      ? V2ArtifactPreviewKind.image
      : v2ArtifactPreviewKindOf(fileName, kind: kind);
  final text = content?.trim() ?? '';
  final code = previewKind == V2ArtifactPreviewKind.code;
  final document =
      previewKind == V2ArtifactPreviewKind.document ||
      previewKind == V2ArtifactPreviewKind.data;
  final sizeLabel = v2ArtifactSizeLabel(sizeBytes);
  final link = downloadUrl?.trim() ?? '';
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ArtifactDetailPage(
        data: V2ArtifactDetailData(
          name: fileName,
          typeLabel: extension.isEmpty ? 'Artifact' : extension.toUpperCase(),
          sizeLabel: sizeLabel,
          versionLabel: statusLabel,
          previewKind: previewKind,
          previewHeadline: previewLabel,
          previewCodeFile: fileName,
          previewCode: code ? text : '',
          documentText: document ? text : '',
          thumbnail: previewKind == V2ArtifactPreviewKind.image
              ? thumbnail
              : null,
          downloadUrl: link,
          shareUrl: link,
          openUrl: link,
          details: <V2ArtifactDetailRow>[
            V2ArtifactDetailRow(label: 'Preview', value: previewLabel),
            V2ArtifactDetailRow(label: 'Details', value: meta),
            if (sizeLabel.isNotEmpty)
              V2ArtifactDetailRow(label: 'Size', value: sizeLabel),
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
