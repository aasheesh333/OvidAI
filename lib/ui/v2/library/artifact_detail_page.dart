import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

enum V2ArtifactDetailStatus { loading, content, error, missing }

enum V2ArtifactDetailTab { preview, details }

enum V2ArtifactDetailTone { neutral, success }

@immutable
class V2ArtifactDetailRow {
  const V2ArtifactDetailRow({
    required this.label,
    required this.value,
    this.tone = V2ArtifactDetailTone.neutral,
  });

  final String label;
  final String value;
  final V2ArtifactDetailTone tone;
}

@immutable
class V2ArtifactDetailData {
  const V2ArtifactDetailData({
    this.status = V2ArtifactDetailStatus.content,
    this.name = '',
    this.typeLabel = '',
    this.sizeLabel = '',
    this.createdLabel = '',
    this.versionLabel = 'Ready',
    this.sourceChatTitle = '',
    this.sourcePrompt = '',
    this.previewHeadline = '',
    this.previewSubtitle = '',
    this.previewTag = '',
    this.previewCodeFile = '',
    this.previewCode = '',
    this.previewNote =
        'This preview is read-only. Download the file or open it in Studio to make changes.',
    this.details = const <V2ArtifactDetailRow>[],
    this.thumbnail,
    this.errorMessage = 'We could not open this artifact. Check your connection and try again.',
  });

  final V2ArtifactDetailStatus status;
  final String name;
  final String typeLabel;
  final String sizeLabel;
  final String createdLabel;
  final String versionLabel;
  final String sourceChatTitle;
  final String sourcePrompt;
  final String previewHeadline;
  final String previewSubtitle;
  final String previewTag;
  final String previewCodeFile;
  final String previewCode;
  final String previewNote;
  final List<V2ArtifactDetailRow> details;
  final ImageProvider? thumbnail;
  final String errorMessage;
}

/// Language badge for the preview snippet, taken from the file extension so a
/// `.ts` artifact is never labelled `HTML`. Null when there is no extension.
String? _codeLanguage(String file) {
  final dot = file.lastIndexOf('.');
  if (dot < 0 || dot == file.length - 1) return null;
  return switch (file.substring(dot + 1).toLowerCase()) {
    'html' || 'htm' => 'HTML',
    'ts' || 'tsx' => 'TS',
    'js' || 'jsx' => 'JS',
    'css' => 'CSS',
    'json' => 'JSON',
    'md' => 'MD',
    'py' => 'Python',
    final other => other.toUpperCase(),
  };
}

/// A single artifact with its preview, origin chat and technical details.
class ArtifactDetailPage extends StatefulWidget {
  const ArtifactDetailPage({
    super.key,
    required this.data,
    this.onDownload,
    this.onShareLink,
    this.onOpenInStudio,
    this.onOpenChat,
    this.onMore,
    this.onRetry,
    this.onBackToArtifacts,
  });

  final V2ArtifactDetailData data;
  final VoidCallback? onDownload;
  final VoidCallback? onShareLink;
  final VoidCallback? onOpenInStudio;
  final VoidCallback? onOpenChat;
  final VoidCallback? onMore;
  final VoidCallback? onRetry;
  final VoidCallback? onBackToArtifacts;

  @override
  State<ArtifactDetailPage> createState() => _ArtifactDetailPageState();
}

class _ArtifactDetailPageState extends State<ArtifactDetailPage> {
  V2ArtifactDetailTab _tab = V2ArtifactDetailTab.preview;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OScaffold(
      appBar: OAppBar(
        title: 'Artifact detail',
        actions: [
          OIconButton(
            icon: Icons.more_vert_rounded,
            semanticLabel: 'More options',
            onPressed: widget.onMore,
          ),
        ],
      ),
      body: OFadeSlide(
        child: OAnimatedSwap(
          child: switch (widget.data.status) {
            V2ArtifactDetailStatus.loading => const OSkeletonList(rows: 5),
            V2ArtifactDetailStatus.error => OErrorState(
              message: widget.data.errorMessage,
              onRetry: widget.onRetry,
            ),
            V2ArtifactDetailStatus.missing => OEmptyState(
              icon: Icons.broken_image_outlined,
              title: 'This artifact is gone',
              message:
                  'It may have been deleted or moved. Your other artifacts are safe.',
              action: OButton(
                label: 'Back to artifacts',
                icon: Icons.arrow_back_rounded,
                onPressed: widget.onBackToArtifacts,
              ),
            ),
            V2ArtifactDetailStatus.content => _content(c),
          },
        ),
      ),
    );
  }

  Widget _content(OColors c) {
    final data = widget.data;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xxl,
      ),
      children: [
        _stage(c),
        const SizedBox(height: OSpace.l),
        _summary(c),
        const SizedBox(height: OSpace.m),
        _sourceChat(c),
        const SizedBox(height: OSpace.m),
        _tabs(c),
        const SizedBox(height: OSpace.m),
        _actions(),
        const SizedBox(height: OSpace.m),
        OAnimatedSwap(
          child: _tab == V2ArtifactDetailTab.preview
              ? _previewTab(c, data)
              : _detailsTab(c, data),
        ),
      ],
    );
  }

  Widget _stage(OColors c) {
    final data = widget.data;
    final thumbnail = data.thumbnail;
    return AspectRatio(
      aspectRatio: 1.15,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ORadius.l),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              decoration: BoxDecoration(
                color: c.codeBg,
                border: Border.all(color: c.hairline),
                borderRadius: BorderRadius.circular(ORadius.l),
              ),
              child: thumbnail != null
                  ? Image(
                      image: thumbnail,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _mockPage(c),
                    )
                  : _mockPage(c),
            ),
            Positioned(
              top: OSpace.s,
              left: OSpace.s,
              right: OSpace.s,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: OSpace.s,
                runSpacing: OSpace.xs,
                children: [
                  _stagePill(
                    c,
                    icon: Icons.devices_rounded,
                    label: 'Responsive view',
                  ),
                  _stagePill(c, dot: c.success, label: 'Live preview'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mockPage(OColors c) {
    final data = widget.data;
    final codeLines = data.previewCode.isEmpty
        ? const <String>[]
        : data.previewCode.split('\n');
    return Column(
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: 30),
          padding: const EdgeInsets.symmetric(
            horizontal: OSpace.m,
            vertical: 6,
          ),
          color: c.surface,
          child: Row(
            children: [
              for (var i = 0; i < 3; i++) ...[
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: c.hairlineStrong,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: OSpace.xs),
              ],
              Expanded(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: OSpace.m,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: c.codeBg,
                      borderRadius: BorderRadius.circular(ORadius.s),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 11,
                          color: c.success,
                        ),
                        const SizedBox(width: OSpace.xs),
                        Flexible(
                          child: Text(
                            'ovid.site',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: OType.caption.copyWith(color: c.textMuted),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 28),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(OSpace.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      constraints: const BoxConstraints(
                        minWidth: 22,
                        minHeight: 22,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: c.accentFill,
                        borderRadius: BorderRadius.circular(ORadius.s),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'AC',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.overline.copyWith(color: c.onAccent),
                      ),
                    ),
                    const SizedBox(width: OSpace.s),
                    Expanded(
                      child: Text(
                        'Alex Chen',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.caption.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: OSpace.s),
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: 'Work',
                              style: OType.caption.copyWith(color: c.textMuted),
                            ),
                            TextSpan(
                              text: ' · Contact',
                              style: OType.caption.copyWith(color: c.accent),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: OSpace.s),
                if (data.previewTag.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: OSpace.s,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: c.accentSoft,
                      borderRadius: BorderRadius.circular(ORadius.pill),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.code_rounded, size: 11, color: c.accent),
                        const SizedBox(width: OSpace.xs),
                        Flexible(
                          child: Text(
                            data.previewTag,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: OType.overline.copyWith(color: c.accent),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: OSpace.s),
                Text(
                  data.previewHeadline,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: OType.h3.copyWith(color: c.text),
                ),
                const SizedBox(height: OSpace.xs),
                Text(
                  data.previewSubtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: OSpace.s),
                if (codeLines.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(OSpace.s),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(ORadius.s),
                      border: Border.all(color: c.hairline),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                data.previewCodeFile,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: OType.mono.copyWith(color: c.accent),
                              ),
                            ),
                            if (_codeLanguage(data.previewCodeFile)
                                case final language?)
                              Text(
                                language,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: OType.overline.copyWith(
                                  color: c.textFaint,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: OSpace.xs),
                        for (final line in codeLines.take(3))
                          Text(
                            line,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: OType.mono.copyWith(color: c.textMuted),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _stagePill(
    OColors c, {
    IconData? icon,
    Color? dot,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.s,
        vertical: OSpace.xs,
      ),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(ORadius.pill),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null)
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            )
          else if (icon != null)
            Icon(icon, size: 12, color: c.accent),
          const SizedBox(width: OSpace.xs),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.overline.copyWith(color: c.text),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summary(OColors c) {
    final data = widget.data;
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: OSpace.s,
            runSpacing: OSpace.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                data.name,
                style: OType.h2.copyWith(color: c.text),
              ),
              _versionBadge(c),
            ],
          ),
          const SizedBox(height: OSpace.s),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: OSpace.s,
            runSpacing: OSpace.xs,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: c.success,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: OSpace.xs),
                  Flexible(
                    child: Text(
                      data.typeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.bodySm.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              Text('•', style: OType.caption.copyWith(color: c.textFaint)),
              Text(
                data.sizeLabel,
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
              Text('•', style: OType.caption.copyWith(color: c.textFaint)),
              Text(
                data.createdLabel,
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _versionBadge(OColors c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: c.accentSoft,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Text(
        widget.data.versionLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: OType.caption.copyWith(
          color: c.accent,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _sourceChat(OColors c) {
    return OCard(
      padding: const EdgeInsets.all(OSpace.m),
      onTap: widget.onOpenChat,
      semanticLabel:
          'Made in chat, ${widget.data.sourceChatTitle}. Open the source chat.',
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(ORadius.m),
            ),
            child: Icon(Icons.auto_awesome_rounded, size: 20, color: c.accent),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Made in chat',
                  style: OType.bodySm.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Prompted in "${widget.data.sourcePrompt}"',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint),
        ],
      ),
    );
  }

  Widget _tabs(OColors c) {
    return Container(
      padding: const EdgeInsets.all(OSpace.xs),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        children: [
          Expanded(
            child: _tabButton(
              c,
              tab: V2ArtifactDetailTab.preview,
              label: 'Preview',
              icon: Icons.visibility_outlined,
            ),
          ),
          const SizedBox(width: OSpace.xs),
          Expanded(
            child: _tabButton(
              c,
              tab: V2ArtifactDetailTab.details,
              label: 'Details',
              icon: Icons.info_outline_rounded,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabButton(
    OColors c, {
    required V2ArtifactDetailTab tab,
    required String label,
    required IconData icon,
  }) {
    final selected = _tab == tab;
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      child: OPressable(
        onTap: () => setState(() => _tab = tab),
        child: AnimatedContainer(
          duration: OMotion.fast,
          curve: OMotion.standard,
          height: OSpace.touch,
          decoration: BoxDecoration(
            color: selected ? c.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(ORadius.s),
            border: Border.all(
              color: selected ? c.hairline : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 17,
                color: selected ? c.accent : c.textMuted,
              ),
              const SizedBox(width: OSpace.s),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.label.copyWith(
                    color: selected ? c.text : c.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actions() {
    return Column(
      children: [
        OButton(
          label: 'Download',
          icon: Icons.download_rounded,
          expand: true,
          onPressed: widget.onDownload,
        ),
        const SizedBox(height: OSpace.s),
        Row(
          children: [
            Expanded(
              child: OButton(
                label: 'Share link',
                icon: Icons.link_rounded,
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: widget.onShareLink,
              ),
            ),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: OButton(
                label: 'Open in Studio',
                icon: Icons.terminal_rounded,
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: widget.onOpenInStudio,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _previewTab(OColors c, V2ArtifactDetailData data) {
    return OCard(
      accent: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: c.accentSoft,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.auto_awesome_rounded, size: 17, color: c.accent),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ready to view',
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
                const SizedBox(height: OSpace.xs),
                Text(
                  data.previewNote,
                  style: OType.bodySm.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailsTab(OColors c, V2ArtifactDetailData data) {
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        children: [
          for (var i = 0; i < data.details.length; i++) ...[
            if (i > 0) Divider(height: 1, color: c.hairline),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.l,
                vertical: OSpace.m,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      data.details[i].label,
                      style: OType.bodySm.copyWith(color: c.textMuted),
                    ),
                  ),
                  const SizedBox(width: OSpace.m),
                  Flexible(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (data.details[i].tone ==
                            V2ArtifactDetailTone.success) ...[
                          Icon(
                            Icons.check_circle_rounded,
                            size: 16,
                            color: c.success,
                          ),
                          const SizedBox(width: OSpace.xs),
                        ],
                        Flexible(
                          child: Text(
                            data.details[i].value,
                            textAlign: TextAlign.end,
                            style: OType.bodySm.copyWith(
                              color: data.details[i].tone ==
                                      V2ArtifactDetailTone.success
                                  ? c.success
                                  : c.text,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
