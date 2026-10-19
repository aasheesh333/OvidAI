import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/cloud/cloud_rest.dart';
import '../core/diag.dart';
import '../core/native_share.dart';
import '../core/session_artifacts.dart';
import '../core/theme.dart';
import '../l10n/l10n.dart';
import 'html_artifact_view.dart';
import 'share_actions.dart';
import 'widgets/aether_primitives.dart';
import 'widgets/code_highlight.dart';

/// Largest text file the preview reads inline. Bigger files offer
/// "Open with" instead of loading megabytes into a Text widget.
const int artifactPreviewMaxBytes = 512 * 1024;

/// Host path of [a] on this device, or null when it is not on local disk.
///
/// Uploaded files and generated images carry absolute paths. Tool-written
/// files carry the workspace-relative path the agent used; they resolve
/// against that session's workspace root.
String? resolveArtifactHostPath(SessionArtifact a) {
  final path = a.path;
  if (path == null || path.isEmpty) return null;
  // Cloud artifacts are R2 URLs (see [SessionArtifact.url]); only an
  // absolute local path (legacy upload) is readable from disk.
  return path.startsWith('/') ? path : null;
}

IconData artifactIcon(ArtifactKind kind) => switch (kind) {
  ArtifactKind.image => Icons.image_outlined,
  ArtifactKind.html => Icons.web_asset_rounded,
  ArtifactKind.code => Icons.data_object_rounded,
  ArtifactKind.document => Icons.article_outlined,
  ArtifactKind.other => Icons.insert_drive_file_outlined,
};

String artifactKindLabel(BuildContext context, ArtifactKind kind) {
  final l10n = context.l10n;
  return switch (kind) {
    ArtifactKind.image => l10n.artifactKindImage,
    ArtifactKind.html => l10n.artifactKindHtml,
    ArtifactKind.code => l10n.artifactKindCode,
    ArtifactKind.document => l10n.artifactKindDocument,
    ArtifactKind.other => l10n.artifactKindFile,
  };
}

String formatArtifactSize(int bytes) => bytes >= 1048576
    ? '${(bytes / 1048576).toStringAsFixed(1)} MB'
    : bytes >= 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '$bytes B';

String? _mimeFor(String name) => switch (artifactExtension(name)) {
  'png' => 'image/png',
  'jpg' || 'jpeg' => 'image/jpeg',
  'gif' => 'image/gif',
  'webp' => 'image/webp',
  'pdf' => 'application/pdf',
  'html' || 'htm' => 'text/html',
  'md' || 'markdown' || 'txt' || 'log' => 'text/plain',
  'csv' => 'text/csv',
  'json' => 'application/json',
  _ => null,
};

/// Opens the preview for [artifact]: an image viewer, a highlighted
/// text/code viewer, the live HTML artifact, or an "open with" fallback.
Future<void> openArtifactPreview(
  BuildContext context,
  SessionArtifact artifact,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ArtifactPreviewScreen(artifact: artifact),
  ),
);

/// A URL [a] can actually be loaded from: a freshly minted presign when the
/// persisted one can be re-minted, else the persisted one as-is.
///
/// Presigned artifact URLs expire (~1h TTL) and transcripts persist them
/// verbatim, so a stale `a.url` is the rule, not the exception, once the
/// message is older than the TTL. Minting needs the gateway workspace-object
/// id, which [cloudArtifactIdOf] recovers from the URL itself; URLs without
/// that layout (local/legacy) are returned untouched. On mint failure the
/// stale URL wins — a maybe-working old URL beats nothing.
Future<String?> freshArtifactUrl(SessionArtifact a) async {
  final stale = a.url;
  if (stale == null || stale.isEmpty) return stale;
  final artifactId = cloudArtifactIdOf(stale);
  if (artifactId == null) return stale;
  try {
    final minted = await CloudRestClient.I.mintArtifactUrl(
      a.sessionId,
      artifactId,
    );
    return minted.url;
  } catch (e) {
    Diag.swallow('artifact.mintUrl', e);
    return stale;
  }
}

/// Shares the artifact file through the system sheet (FileProvider), or
/// explains why it cannot.
Future<void> shareArtifact(BuildContext context, SessionArtifact a) async {
  final url = a.url;
  if (url != null && url.isNotEmpty) {
    // Mint-if-needed: the recipient gets file access for the URL's remaining
    // TTL either way, so hand them a fresh capability rather than a presign
    // that is likely already dead.
    // TODO(l10n): note the link's ~1h TTL in the share text once the sheet
    // copy is localized (NativeShare.link only carries the raw URL today).
    final fresh = await freshArtifactUrl(a);
    if (!context.mounted) return;
    await showNativeShare(context, () => NativeShare.link(fresh ?? url));
    return;
  }
  final host = resolveArtifactHostPath(a);
  if (host == null || !File(host).existsSync()) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.artifactNotOnDevice)));
    return;
  }
  await showNativeShare(context, () => NativeShare.file(host));
}

Future<void> _openWith(BuildContext context, SessionArtifact a) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  final url = a.url;
  if (url != null && url.isNotEmpty) {
    final fresh = await freshArtifactUrl(a);
    final opened = await launchUrl(
      Uri.parse(fresh ?? url),
      mode: LaunchMode.externalApplication,
    );
    if (!opened) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.artifactNotOnDevice)),
      );
    }
    return;
  }
  final host = resolveArtifactHostPath(a);
  if (host == null || !File(host).existsSync()) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.artifactNotOnDevice)));
    return;
  }
  try {
    await NativeShare.open(host, mime: _mimeFor(a.name));
  } catch (e) {
    Diag.swallow('artifact.openWith', e);
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.attachmentNoApp(a.name))),
    );
  }
}

/// Square thumbnail: the image itself for local images, else a tinted
/// type glyph.
///
/// Stateful for the cloud case: a persisted presigned URL is rendered
/// immediately (Flutter's image cache may still honor it) while a fresh one
/// is minted in the background; the swap repaints when it lands.
class ArtifactThumb extends StatefulWidget {
  const ArtifactThumb({super.key, required this.artifact, this.size = 40});

  final SessionArtifact artifact;
  final double size;

  @override
  State<ArtifactThumb> createState() => _ArtifactThumbState();
}

class _ArtifactThumbState extends State<ArtifactThumb> {
  String? _freshUrl;

  @override
  void initState() {
    super.initState();
    if ((widget.artifact.url ?? '').isNotEmpty) {
      unawaited(_mint());
    }
  }

  @override
  void didUpdateWidget(ArtifactThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artifact.url != widget.artifact.url) {
      _freshUrl = null;
      if ((widget.artifact.url ?? '').isNotEmpty) unawaited(_mint());
    }
  }

  Future<void> _mint() async {
    final fresh = await freshArtifactUrl(widget.artifact);
    if (!mounted || fresh == null || fresh == widget.artifact.url) return;
    setState(() => _freshUrl = fresh);
  }

  @override
  Widget build(BuildContext context) {
    final artifact = widget.artifact;
    final size = widget.size;
    final radius = BorderRadius.circular(AetherRadius.rSm);
    final glyph = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: Aether.accentSoft, borderRadius: radius),
      child: Icon(
        artifactIcon(artifact.kind),
        size: size * 0.48,
        color: Aether.accent,
      ),
    );
    if (artifact.kind != ArtifactKind.image) return glyph;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final url = _freshUrl ?? artifact.url;
    if (url != null && url.isNotEmpty) {
      return ClipRRect(
        borderRadius: radius,
        child: Image.network(
          url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: (size * dpr).round(),
          errorBuilder: (_, _, _) => glyph,
        ),
      );
    }
    final host = resolveArtifactHostPath(artifact);
    if (host == null) return glyph;
    return ClipRRect(
      borderRadius: radius,
      child: Image.file(
        File(host),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * dpr).round(),
        errorBuilder: (_, _, _) => glyph,
      ),
    );
  }
}

/// In-chat artifact card (Claude-style): thumbnail/type glyph, name, type ·
/// size, and an open affordance. Tapping opens [openArtifactPreview].
class ArtifactCard extends StatelessWidget {
  const ArtifactCard({super.key, required this.artifact, this.subtitle});

  final SessionArtifact artifact;

  /// Overrides the default "Type · size" line.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final kind = artifactKindLabel(context, artifact.kind);
    final line =
        subtitle ??
        [
          kind,
          if (artifact.size != null && artifact.size! > 0)
            formatArtifactSize(artifact.size!),
        ].join(' · ');
    return Semantics(
      button: true,
      label: l10n.artifactOpenSemantics(artifact.name),
      excludeSemantics: true,
      child: Material(
        color: Aether.surface,
        borderRadius: BorderRadius.circular(AetherRadius.rMd),
        child: InkWell(
          key: ValueKey('chat-artifact-card-${artifact.id}'),
          borderRadius: BorderRadius.circular(AetherRadius.rMd),
          onTap: () => openArtifactPreview(context, artifact),
          child: Container(
            constraints: const BoxConstraints(minHeight: 56, maxWidth: 420),
            padding: const EdgeInsets.fromLTRB(8, 8, 10, 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AetherRadius.rMd),
              border: Border.all(color: Aether.hairline),
            ),
            child: Row(
              children: [
                ArtifactThumb(artifact: artifact),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        artifact.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Aether.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Aether.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.open_in_full_rounded,
                  size: 15,
                  color: Aether.textFaint,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen artifact preview.
class ArtifactPreviewScreen extends StatefulWidget {
  const ArtifactPreviewScreen({super.key, required this.artifact});

  final SessionArtifact artifact;

  @override
  State<ArtifactPreviewScreen> createState() => _ArtifactPreviewScreenState();
}

enum _PreviewState { image, text, html, tooLarge, missing, binary, remote }

class _ArtifactPreviewScreenState extends State<ArtifactPreviewScreen> {
  late final String? _host = resolveArtifactHostPath(widget.artifact);
  late _PreviewState _state;
  String _text = '';
  int? _size;

  /// Freshly minted replacement for [SessionArtifact.url] (remote artifacts
  /// only): the persisted presign is likely past its ~1h TTL by the time the
  /// preview opens.
  String? _freshUrl;

  @override
  void initState() {
    super.initState();
    _state = _classify();
    if (_state == _PreviewState.remote &&
        widget.artifact.kind == ArtifactKind.image) {
      unawaited(_mintRemoteUrl());
    }
  }

  Future<void> _mintRemoteUrl() async {
    final fresh = await freshArtifactUrl(widget.artifact);
    if (!mounted || fresh == null || fresh == widget.artifact.url) return;
    setState(() => _freshUrl = fresh);
  }

  _PreviewState _classify() {
    final a = widget.artifact;
    if (a.html != null) return _PreviewState.html;
    final host = _host;
    if (host == null) {
      return (a.url ?? '').isEmpty
          ? _PreviewState.missing
          : _PreviewState.remote;
    }
    final f = File(host);
    try {
      if (!f.existsSync()) return _PreviewState.missing;
      _size = f.lengthSync();
      if (a.kind == ArtifactKind.image && artifactExtension(a.name) != 'svg') {
        return _PreviewState.image;
      }
      if (!artifactIsText(a.name)) return _PreviewState.binary;
      if (_size! > artifactPreviewMaxBytes) return _PreviewState.tooLarge;
      // A bounded synchronous read (≤512 KB) keeps the first frame complete.
      _text = f.readAsStringSync();
      return _PreviewState.text;
    } catch (e) {
      Diag.swallow('artifact.preview.read', e);
      return _PreviewState.binary;
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.l10n.artifactCopied),
        duration: const Duration(milliseconds: 900),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final a = widget.artifact;
    final canShare = a.html == null && _state != _PreviewState.missing;
    final meta = [
      artifactKindLabel(context, a.kind),
      if ((_size ?? a.size ?? 0) > 0) formatArtifactSize(_size ?? a.size!),
      a.sessionTitle,
    ].join(' · ');
    return Scaffold(
      backgroundColor: _state == _PreviewState.image ? Colors.black : Aether.bg,
      appBar: AppBar(
        backgroundColor: _state == _PreviewState.image ? Colors.black : null,
        foregroundColor: _state == _PreviewState.image ? Colors.white : null,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              a.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: _state == _PreviewState.image
                    ? Colors.white70
                    : Aether.textMuted,
              ),
            ),
          ],
        ),
        actions: [
          if (_state == _PreviewState.text)
            IconButton(
              tooltip: l10n.artifactCopy,
              icon: const Icon(Icons.copy_rounded, size: 19),
              onPressed: _copy,
            ),
          if (canShare)
            IconButton(
              tooltip: l10n.artifactShare,
              icon: const Icon(Icons.ios_share_rounded, size: 19),
              onPressed: () => shareArtifact(context, a),
            ),
          if (canShare)
            PopupMenuButton<String>(
              tooltip: l10n.chatMenuMore,
              icon: const Icon(Icons.more_vert_rounded, size: 20),
              onSelected: (v) {
                if (v == 'open') _openWith(context, a);
              },
              itemBuilder: (_) => [
                if (canShare)
                  PopupMenuItem(
                    value: 'open',
                    child: Text(l10n.artifactOpenWith),
                  ),
              ],
            ),
        ],
      ),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final l10n = context.l10n;
    final a = widget.artifact;
    switch (_state) {
      case _PreviewState.html:
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: HtmlArtifactView(artifact: a.html, sessionId: a.sessionId),
        );
      case _PreviewState.image:
        return Center(
          key: const ValueKey('artifact-preview-image'),
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 5,
            child: Image.file(
              File(_host!),
              cacheWidth: Aether.imageCacheWidth(context),
              errorBuilder: (_, _, _) => Icon(
                Icons.broken_image_outlined,
                size: 48,
                color: Aether.textFaint,
              ),
            ),
          ),
        );
      case _PreviewState.text:
        return _TextPreview(text: _text, name: a.name);
      case _PreviewState.tooLarge:
        return AetherEmptyState(
          icon: artifactIcon(a.kind),
          title: l10n.artifactTooLargeTitle,
          message: l10n.artifactTooLargeBody,
          action: AetherSecondaryButton(
            label: l10n.artifactOpenWith,
            onPressed: () => _openWith(context, a),
          ),
        );
      case _PreviewState.binary:
        return AetherEmptyState(
          icon: artifactIcon(a.kind),
          title: l10n.artifactNoPreviewTitle,
          message: l10n.artifactNoPreviewBody,
          action: AetherSecondaryButton(
            label: l10n.artifactOpenWith,
            onPressed: () => _openWith(context, a),
          ),
        );
      case _PreviewState.remote:
        if (a.kind == ArtifactKind.image) {
          return Center(
            key: const ValueKey('artifact-preview-image'),
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 5,
              child: Image.network(
                _freshUrl ?? a.url!,
                cacheWidth: Aether.imageCacheWidth(context),
                errorBuilder: (_, _, _) => Icon(
                  Icons.broken_image_outlined,
                  size: 48,
                  color: Aether.textFaint,
                ),
              ),
            ),
          );
        }
        return AetherEmptyState(
          icon: artifactIcon(a.kind),
          title: l10n.artifactNoPreviewTitle,
          message: l10n.artifactNoPreviewBody,
          action: AetherSecondaryButton(
            label: l10n.artifactOpenWith,
            onPressed: () => _openWith(context, a),
          ),
        );
      case _PreviewState.missing:
        return AetherEmptyState(
          icon: Icons.cloud_off_outlined,
          title: l10n.artifactMissingTitle,
          message: l10n.artifactNotOnDevice,
        );
    }
  }
}

class _TextPreview extends StatelessWidget {
  const _TextPreview({required this.text, required this.name});

  final String text;
  final String name;

  @override
  Widget build(BuildContext context) {
    final lines = '\n'.allMatches(text).length + 1;
    final gutter = '$lines'.length * 8.0 + 12;
    final style = TextStyle(
      fontFamily: Aether.mono,
      fontSize: 12,
      height: 1.55,
      color: Aether.text,
    );
    return Container(
      key: const ValueKey('artifact-preview-text'),
      color: Aether.codeBg,
      child: Scrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(0, 12, 16, 24),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Line-number gutter (excluded from selection/copy).
                ExcludeSemantics(
                  child: SizedBox(
                    width: gutter,
                    child: Text(
                      List.generate(lines, (i) => '${i + 1}').join('\n'),
                      textAlign: TextAlign.right,
                      style: style.copyWith(color: Aether.textFaint),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SelectableText.rich(
                  highlightCode(
                    text,
                    lang: artifactExtension(name),
                    style: style,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Name · Session · 14:02" style subtitle for list rows.
String artifactListSubtitle(BuildContext context, SessionArtifact a) {
  final loc = MaterialLocalizations.of(context);
  final now = DateTime.now();
  final sameDay =
      now.year == a.time.year &&
      now.month == a.time.month &&
      now.day == a.time.day;
  final when = sameDay
      ? loc.formatTimeOfDay(TimeOfDay.fromDateTime(a.time))
      : loc.formatShortDate(a.time);
  return [
    a.sessionTitle,
    when,
    if (a.size != null && a.size! > 0) formatArtifactSize(a.size!),
  ].join(' · ');
}
