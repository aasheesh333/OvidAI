import 'dart:async';

import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'transcript_actions.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// One typed block in an assistant message.
///
/// The transcript stores markdown, but the UI renders a small, explicit block
/// model instead of a full markdown engine. That keeps every kind of output
/// (code, diagrams, images, files and links) laid out predictably at 320 dp
/// and 200 % text, without a WebView or a browser engine.
sealed class V2MessageBlock {
  const V2MessageBlock();
}

final class V2HeadingBlock extends V2MessageBlock {
  const V2HeadingBlock({required this.level, required this.text});

  /// 1–3. Deeper markdown headings collapse into level 3.
  final int level;
  final String text;
}

final class V2ParagraphBlock extends V2MessageBlock {
  const V2ParagraphBlock({required this.text});

  final String text;
}

final class V2BulletItem {
  const V2BulletItem({required this.text, this.depth = 0});

  final String text;

  /// Nesting depth, clamped by the parser so a stray indent cannot push text
  /// off a narrow screen.
  final int depth;
}

final class V2BulletListBlock extends V2MessageBlock {
  const V2BulletListBlock({required this.items, this.ordered = false});

  final List<V2BulletItem> items;
  final bool ordered;
}

final class V2CodeBlock extends V2MessageBlock {
  const V2CodeBlock({required this.code, this.language});

  final String code;

  /// Lower-case fence info string, e.g. `dart`. Null for a plain fence.
  final String? language;
}

final class V2DiagramBlock extends V2MessageBlock {
  const V2DiagramBlock({required this.source});

  /// The original Mermaid source. It is never rendered as a live diagram.
  final String source;

  String get title => _diagramTitle(source);
}

final class V2ImageBlock extends V2MessageBlock {
  const V2ImageBlock({required this.alt, required this.url});

  final String alt;
  final String url;
}

final class V2FileBlock extends V2MessageBlock {
  const V2FileBlock({required this.fileName, required this.href});

  final String fileName;
  final String href;
}

final class V2DownloadLink {
  const V2DownloadLink({
    required this.label,
    required this.href,
    this.isDownload = false,
  });

  final String label;
  final String href;
  final bool isDownload;
}

final class V2DownloadLinksBlock extends V2MessageBlock {
  const V2DownloadLinksBlock({required this.links});

  final List<V2DownloadLink> links;
}

final class V2DividerBlock extends V2MessageBlock {
  const V2DividerBlock();
}

/// File extensions that become an artifact card rather than a plain link.
const Set<String> _artifactExtensions = {
  'apk',
  'csv',
  'dart',
  'doc',
  'docx',
  'gif',
  'gz',
  'htm',
  'html',
  'ipa',
  'jpeg',
  'jpg',
  'js',
  'json',
  'log',
  'md',
  'mp3',
  'mp4',
  'pdf',
  'png',
  'ppt',
  'pptx',
  'py',
  'sh',
  'sql',
  'svg',
  'tar',
  'ts',
  'tsx',
  'txt',
  'wav',
  'webp',
  'xls',
  'xlsx',
  'yaml',
  'yml',
  'zip',
};

final _inlinePattern = RegExp(
  r'\*\*([^*]+)\*\*|`([^`]+)`|\*([^*\n]+)\*|\[([^\]]+)\]\(([^)\s]+)\)',
);
final _fencePattern = RegExp(r'^(`{3,}|~{3,})(.*)$');
final _headingPattern = RegExp(r'^(#{1,6})\s+(.+)$');
final _bulletPattern = RegExp(r'^([ \t]*)([-*+•]|\d+[.)])[ \t]+(.+)$');
final _rulePattern = RegExp(r'^([-*_])\1{2,}$');
final _imagePattern = RegExp(
  r'^!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)$',
);
final _linkPattern = RegExp(
  r'^\[([^\]]+)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)$',
);
final _bareUrlPattern = RegExp(r'^<?(https?://[^\s<>]+)>?$');

/// Parses the small markdown subset used in assistant messages.
///
/// Supported blocks:
/// * ATX headings (`#`, `##`, `###`; deeper levels collapse to 3)
/// * bullet and ordered lists (two-space nesting)
/// * fenced code (```` ```lang ````), with `mermaid` becoming a diagram card
/// * standalone images (`![alt](url)`)
/// * standalone file links (`[report.pdf](url)`), rendered as artifact cards
/// * standalone links (and bare URLs), rendered as a download/link row
/// * rules (`---`, `***`, `___`)
///
/// Everything else is a paragraph. Inline bold, code and links are styled but
/// intentionally not tappable; only standalone links become actions.
List<V2MessageBlock> parseV2MessageBlocks(String markdown) {
  final lines = markdown
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final blocks = <V2MessageBlock>[];
  final paragraph = <String>[];

  void flushParagraph() {
    if (paragraph.isEmpty) return;
    final text = paragraph.join(' ').trim();
    paragraph.clear();
    if (text.isNotEmpty) blocks.add(V2ParagraphBlock(text: text));
  }

  var i = 0;
  while (i < lines.length) {
    final raw = lines[i];
    final line = raw.trim();

    if (line.isEmpty) {
      flushParagraph();
      i++;
      continue;
    }

    final fence = _fencePattern.firstMatch(raw.trimLeft());
    if (fence != null) {
      flushParagraph();
      final marker = fence.group(1)!;
      final fenceChar = marker[0];
      final fenceLength = marker.length;
      final info = fence.group(2)!.trim();
      final language = info.isEmpty
          ? null
          : info.split(RegExp(r'\s+')).first.toLowerCase();
      final codeLines = <String>[];
      var j = i + 1;
      while (j < lines.length &&
          !_isFenceClose(lines[j], fenceChar, fenceLength)) {
        codeLines.add(lines[j]);
        j++;
      }
      final code = codeLines.join('\n');
      if (language == 'mermaid') {
        blocks.add(V2DiagramBlock(source: code));
      } else {
        blocks.add(V2CodeBlock(code: code, language: language));
      }
      i = j < lines.length ? j + 1 : j;
      continue;
    }

    final heading = _headingPattern.firstMatch(line);
    if (heading != null) {
      flushParagraph();
      final text = heading
          .group(2)!
          .replaceFirst(RegExp(r'\s+#+\s*$'), '')
          .trim();
      if (text.isNotEmpty) {
        final level = heading.group(1)!.length;
        blocks.add(V2HeadingBlock(level: level > 3 ? 3 : level, text: text));
      }
      i++;
      continue;
    }

    final image = _imagePattern.firstMatch(line);
    if (image != null) {
      flushParagraph();
      blocks.add(
        V2ImageBlock(alt: image.group(1)!.trim(), url: image.group(2)!),
      );
      i++;
      continue;
    }

    if (_rulePattern.hasMatch(line)) {
      flushParagraph();
      blocks.add(const V2DividerBlock());
      i++;
      continue;
    }

    final bullet = _bulletPattern.firstMatch(raw);
    if (bullet != null) {
      flushParagraph();
      final marker = bullet.group(2)!;
      final ordered = RegExp(r'^\d').hasMatch(marker);
      final items = <V2BulletItem>[];
      var j = i;
      while (j < lines.length) {
        final next = _bulletPattern.firstMatch(lines[j]);
        if (next == null) break;
        final nextOrdered = RegExp(r'^\d').hasMatch(next.group(2)!);
        if (nextOrdered != ordered) break;
        final text = next.group(3)!.trim();
        if (text.isNotEmpty) {
          items.add(
            V2BulletItem(text: text, depth: _indentDepth(next.group(1)!)),
          );
        }
        j++;
      }
      if (items.isNotEmpty) {
        blocks.add(
          V2BulletListBlock(items: List.unmodifiable(items), ordered: ordered),
        );
      }
      i = j;
      continue;
    }

    final standalone = _standaloneLink(line);
    if (standalone != null) {
      flushParagraph();
      final entries = <_LinkEntry>[];
      var j = i;
      while (j < lines.length) {
        final next = _standaloneLink(lines[j].trim());
        if (next == null) break;
        entries.add(next);
        j++;
      }
      _emitLinkBlocks(entries, blocks);
      i = j;
      continue;
    }

    paragraph.add(line);
    i++;
  }
  flushParagraph();
  return List.unmodifiable(blocks);
}

/// Bounded memo for [parseV2MessageBlocks].
///
/// A transcript row rebuilds on scroll, theme change or when a sibling
/// streams. Re-parsing an unchanged message is pure waste, so the last few
/// hundred parses are kept. Streaming messages change their string every
/// token; the oldest entry is evicted so the cache stays bounded.
const int _parseCacheLimit = 128;
final Map<String, List<V2MessageBlock>> _parseCache =
    <String, List<V2MessageBlock>>{};

/// Test seam: counts cache misses, i.e. real parses. Null in production.
void Function(String markdown)? v2MessageParseObserver;

List<V2MessageBlock> parseV2MessageBlocksCached(String markdown) {
  final cached = _parseCache.remove(markdown);
  if (cached != null) {
    _parseCache[markdown] = cached; // Re-insert as most recently used.
    return cached;
  }
  v2MessageParseObserver?.call(markdown);
  final parsed = parseV2MessageBlocks(markdown);
  _parseCache[markdown] = parsed;
  if (_parseCache.length > _parseCacheLimit) {
    _parseCache.remove(_parseCache.keys.first);
  }
  return parsed;
}

String _diagramTitle(String source) {
  for (final raw in source.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('%%')) continue;
    final lower = line.toLowerCase();
    if (lower.startsWith('flowchart') || lower.startsWith('graph')) {
      return 'Flowchart';
    }
    if (lower.startsWith('sequencediagram')) return 'Sequence diagram';
    if (lower.startsWith('classdiagram')) return 'Class diagram';
    if (lower.startsWith('statediagram')) return 'State diagram';
    if (lower.startsWith('erdiagram')) return 'Entity relationship diagram';
    if (lower.startsWith('gantt')) return 'Gantt chart';
    if (lower.startsWith('pie')) return 'Pie chart';
    if (lower.startsWith('journey')) return 'User journey';
    break;
  }
  return 'Diagram';
}

bool _isFenceClose(String line, String char, int length) {
  final text = line.trim();
  if (text.length < length) return false;
  for (var i = 0; i < text.length; i++) {
    if (text[i] != char) return false;
  }
  return true;
}

int _indentDepth(String indent) {
  var width = 0;
  for (final unit in indent.runes) {
    width += unit == 0x09 ? 2 : 1;
  }
  return (width ~/ 2).clamp(0, 4).toInt();
}

final class _LinkEntry {
  const _LinkEntry(this.label, this.href);

  final String label;
  final String href;
}

_LinkEntry? _standaloneLink(String line) {
  final link = _linkPattern.firstMatch(line);
  if (link != null) return _LinkEntry(link.group(1)!.trim(), link.group(2)!);
  final bare = _bareUrlPattern.firstMatch(line);
  if (bare != null) return _LinkEntry(bare.group(1)!, bare.group(1)!);
  return null;
}

void _emitLinkBlocks(List<_LinkEntry> entries, List<V2MessageBlock> blocks) {
  final generic = <V2DownloadLink>[];

  void flushGeneric() {
    if (generic.isEmpty) return;
    blocks.add(V2DownloadLinksBlock(links: List.unmodifiable(generic)));
    generic.clear();
  }

  for (final entry in entries) {
    final file = _fileBlockFor(entry);
    if (file != null) {
      flushGeneric();
      blocks.add(file);
    } else {
      generic.add(
        V2DownloadLink(
          label: entry.label,
          href: entry.href,
          isDownload: _looksLikeDownload(entry.label),
        ),
      );
    }
  }
  flushGeneric();
}

V2FileBlock? _fileBlockFor(_LinkEntry entry) {
  final labelExt = _artifactExtension(entry.label);
  final hrefExt = _artifactExtension(entry.href);
  if (labelExt == null && hrefExt == null) return null;
  final fileName =
      _cleanFileName(entry.label) ??
      _fileNameFromHref(entry.href) ??
      entry.label;
  return V2FileBlock(fileName: fileName, href: entry.href);
}

String? _cleanFileName(String label) {
  var text = label.trim();
  text = text
      .replaceFirst(
        RegExp(r'^(download|get|open|save)\s+', caseSensitive: false),
        '',
      )
      .trim();
  if (text.isEmpty || _artifactExtension(text) == null) return null;
  final path = text.split('?').first.split('#').first;
  final name = path.split('/').last.trim();
  return name.isEmpty ? null : name;
}

String? _fileNameFromHref(String href) {
  final path = _pathOf(href);
  if (path.isEmpty) return null;
  final name = path.split('/').last.trim();
  if (name.isEmpty) return null;
  try {
    return Uri.decodeComponent(name);
  } on ArgumentError {
    return name;
  }
}

String _pathOf(String value) {
  final trimmed = value.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.hasScheme) return uri.path;
  return trimmed.split('?').first.split('#').first;
}

String? _artifactExtension(String value) {
  final path = _pathOf(value);
  final name = path.split('/').last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  final extension = name.substring(dot + 1).toLowerCase();
  return _artifactExtensions.contains(extension) ? extension : null;
}

bool _looksLikeDownload(String label) {
  final lower = label.trim().toLowerCase();
  return lower.startsWith('download') ||
      lower.startsWith('save') ||
      lower.startsWith('get file');
}

String _linkHost(String url) {
  final uri = Uri.tryParse(url);
  if (uri != null && uri.host.isNotEmpty) return uri.host;
  return url;
}

/// Renders a markdown message as lightweight chat blocks.
///
/// Images are cards, not network image views: a transcript never blocks on a
/// remote asset or a web view. File cards and link rows call back with the
/// href so the host can open or download it.
class V2MessageBlocks extends StatelessWidget {
  const V2MessageBlocks({
    super.key,
    required this.markdown,
    this.onCopyCode,
    this.onOpenLink,
    this.onDownload,
  });

  final String markdown;

  /// Overrides clipboard copy for code blocks (tests and hosts that record it).
  final ValueChanged<String>? onCopyCode;

  /// Open a page, image or non-download link.
  final ValueChanged<String>? onOpenLink;

  /// Download an artifact or a link whose label says "Download".
  final ValueChanged<String>? onDownload;

  @override
  Widget build(BuildContext context) {
    final blocks = parseV2MessageBlocksCached(markdown);
    if (blocks.isEmpty) return const SizedBox.shrink();
    // A host that does not inject a handler still gets a working control: the
    // defaults open the real URL and save a real file.
    void open(String href) {
      final handler = onOpenLink;
      if (handler != null) {
        handler(href);
      } else {
        unawaited(v2OpenTranscriptLink(context, href));
      }
    }

    void download(String href, {String? suggestedName}) {
      final handler = onDownload;
      if (handler != null) {
        handler(href);
      } else {
        unawaited(
          v2SaveTranscriptLink(context, href, suggestedName: suggestedName),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(height: OSpace.m),
          _buildBlock(context, blocks[i], open, download),
        ],
      ],
    );
  }

  Widget _buildBlock(
    BuildContext context,
    V2MessageBlock block,
    ValueChanged<String> open,
    void Function(String href, {String? suggestedName}) download,
  ) {
    final c = OColors.of(context);
    return switch (block) {
      V2HeadingBlock heading => _HeadingView(block: heading, onOpenLink: open),
      V2ParagraphBlock paragraph => _paragraph(context, paragraph.text, open),
      V2BulletListBlock list => _BulletListView(block: list, onOpenLink: open),
      V2CodeBlock code => _CodeBlockCard(block: code, onCopy: onCopyCode),
      V2DiagramBlock diagram => _DiagramCard(block: diagram),
      V2ImageBlock image => _ImageCard(
        block: image,
        onOpen: open,
        onDownload: (href) => download(href),
      ),
      V2FileBlock file => _FileCard(
        block: file,
        onOpen: open,
        onDownload: (href) => download(href, suggestedName: file.fileName),
      ),
      V2DownloadLinksBlock links => _DownloadLinksCard(
        block: links,
        onOpenLink: open,
        onDownload: (link) => download(
          link.href,
          suggestedName: link.isDownload ? link.label : null,
        ),
      ),
      V2DividerBlock _ => Divider(height: OSpace.l, color: c.hairline),
    };
  }

  Widget _paragraph(
    BuildContext context,
    String text,
    ValueChanged<String> onOpenLink,
  ) {
    final c = OColors.of(context);
    final style = OType.body.copyWith(color: c.text);
    return _InlineText(text: text, style: style, onOpenLink: onOpenLink);
  }
}

/// Paragraph, heading and bullet text with inline bold, code, italic and
/// links. Inline links are real controls: they call [onOpenLink] instead of
/// only looking tappable.
class _InlineText extends StatefulWidget {
  const _InlineText({
    required this.text,
    required this.style,
    required this.onOpenLink,
  });

  final String text;
  final TextStyle style;
  final ValueChanged<String> onOpenLink;

  @override
  State<_InlineText> createState() => _InlineTextState();
}

class _InlineTextState extends State<_InlineText> {
  final Map<String, TapGestureRecognizer> _recognizers =
      <String, TapGestureRecognizer>{};

  @override
  void dispose() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    super.dispose();
  }

  TapGestureRecognizer _recognizerFor(String href) {
    final existing = _recognizers[href];
    if (existing != null) {
      existing.onTap = () => widget.onOpenLink(href);
      return existing;
    }
    final created = TapGestureRecognizer()
      ..onTap = () => widget.onOpenLink(href);
    _recognizers[href] = created;
    return created;
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final style = widget.style;
    final spans = <InlineSpan>[];
    var index = 0;
    for (final match in _inlinePattern.allMatches(widget.text)) {
      if (match.start > index) {
        spans.add(TextSpan(text: widget.text.substring(index, match.start)));
      }
      if (match.group(1) != null) {
        spans.add(
          TextSpan(
            text: match.group(1),
            style: style.copyWith(fontWeight: FontWeight.w600),
          ),
        );
      } else if (match.group(2) != null) {
        spans.add(
          TextSpan(
            text: match.group(2),
            style: OType.mono.copyWith(
              color: c.accent,
              backgroundColor: c.codeBg,
            ),
          ),
        );
      } else if (match.group(3) != null) {
        spans.add(
          TextSpan(
            text: match.group(3),
            style: style.copyWith(fontStyle: FontStyle.italic),
          ),
        );
      } else {
        final href = match.group(5)!;
        spans.add(
          TextSpan(
            text: match.group(4),
            recognizer: _recognizerFor(href),
            style: style.copyWith(
              color: c.accent,
              decoration: TextDecoration.underline,
              decorationColor: c.accent,
            ),
          ),
        );
      }
      index = match.end;
    }
    if (index < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(index)));
    }
    return Text.rich(TextSpan(style: style, children: spans));
  }
}

class _HeadingView extends StatelessWidget {
  const _HeadingView({required this.block, required this.onOpenLink});

  final V2HeadingBlock block;
  final ValueChanged<String> onOpenLink;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final style = switch (block.level) {
      1 => OType.h2,
      2 => OType.h3,
      _ => OType.bodyStrong,
    }.copyWith(color: c.text);
    return Semantics(
      header: true,
      child: _InlineText(
        text: block.text,
        style: style,
        onOpenLink: onOpenLink,
      ),
    );
  }
}

class _BulletListView extends StatelessWidget {
  const _BulletListView({required this.block, required this.onOpenLink});

  final V2BulletListBlock block;
  final ValueChanged<String> onOpenLink;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final style = OType.body.copyWith(color: c.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < block.items.length; i++)
          Padding(
            padding: EdgeInsets.only(
              left: block.items[i].depth * OSpace.l,
              bottom: i == block.items.length - 1 ? 0 : OSpace.xs,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (block.ordered)
                  Text(
                    '${i + 1}.',
                    style: style.copyWith(
                      color: c.textMuted,
                      fontWeight: FontWeight.w500,
                    ),
                  )
                else
                  ExcludeSemantics(
                    child: Text('•', style: style.copyWith(color: c.textMuted)),
                  ),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: _InlineText(
                    text: block.items[i].text,
                    style: style,
                    onOpenLink: onOpenLink,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _CodeBlockCard extends StatefulWidget {
  const _CodeBlockCard({required this.block, this.onCopy});

  final V2CodeBlock block;
  final ValueChanged<String>? onCopy;

  @override
  State<_CodeBlockCard> createState() => _CodeBlockCardState();
}

class _CodeBlockCardState extends State<_CodeBlockCard> {
  Timer? _reset;
  bool _copied = false;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    try {
      if (widget.onCopy != null) {
        widget.onCopy!(widget.block.code);
      } else {
        await Clipboard.setData(ClipboardData(text: widget.block.code));
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Could not copy the code.')),
        );
      return;
    }
    if (!mounted) return;
    setState(() => _copied = true);
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Code copied',
        Directionality.of(context),
      ),
    );
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final language = widget.block.language;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.codeBg,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: c.surfaceAlt,
            padding: const EdgeInsets.only(left: OSpace.m),
            child: Row(
              children: [
                Icon(Icons.terminal_rounded, size: 16, color: c.accent),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: Text(
                    language == null ? 'Code' : language.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.overline.copyWith(color: c.textFaint),
                  ),
                ),
                OIconButton(
                  icon: _copied
                      ? Icons.check_rounded
                      : Icons.content_copy_rounded,
                  semanticLabel: _copied ? 'Code copied' : 'Copy code',
                  tooltip: _copied ? 'Copied' : 'Copy code',
                  size: 18,
                  onPressed: _copy,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.hairline),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(
              OSpace.m,
              OSpace.s,
              OSpace.m,
              OSpace.m,
            ),
            child: Text(
              widget.block.code,
              style: OType.mono.copyWith(color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiagramCard extends StatelessWidget {
  const _DiagramCard({required this.block});

  final V2DiagramBlock block;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      padding: const EdgeInsets.all(OSpace.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.account_tree_rounded, size: 18, color: c.accent),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  block.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          // The source is the honest representation of the diagram: no fake
          // preview, no "unavailable" copy.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(OSpace.m),
            decoration: BoxDecoration(
              color: c.codeBg,
              borderRadius: BorderRadius.circular(ORadius.m),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                block.source,
                style: OType.mono.copyWith(color: c.textMuted),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageCard extends StatelessWidget {
  const _ImageCard({
    required this.block,
    required this.onOpen,
    required this.onDownload,
  });

  final V2ImageBlock block;
  final ValueChanged<String> onOpen;
  final ValueChanged<String> onDownload;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final alt = block.alt.isEmpty ? 'Image' : block.alt;
    final url = block.url;
    // One row, like every other attachment. A fake 96 dp preview band added
    // height without adding information.
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      child: OPressable(
        onTap: () => onOpen(url),
        semanticLabel: 'Open image: $alt',
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            OSpace.m,
            OSpace.s,
            OSpace.xs,
            OSpace.s,
          ),
          child: Row(
            children: [
              Icon(Icons.image_rounded, size: 20, color: c.accent),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      alt,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: OType.bodySmStrong.copyWith(color: c.text),
                    ),
                    if (url.isNotEmpty) ...[
                      const SizedBox(height: OSpace.xxs),
                      Text(
                        _linkHost(url),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
              OIconButton(
                icon: Icons.download_rounded,
                semanticLabel: 'Download image',
                size: 20,
                onPressed: () => onDownload(url),
              ),
              Icon(Icons.chevron_right_rounded, size: 18, color: c.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileCard extends StatelessWidget {
  const _FileCard({
    required this.block,
    required this.onOpen,
    required this.onDownload,
  });

  final V2FileBlock block;
  final ValueChanged<String> onOpen;
  final ValueChanged<String> onDownload;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final extension =
        _artifactExtension(block.fileName) ?? _artifactExtension(block.href);
    final meta = extension == null
        ? 'Attachment'
        : '${extension.toUpperCase()} file';
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      child: OPressable(
        onTap: () => onOpen(block.href),
        semanticLabel: 'Open ${block.fileName}',
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            OSpace.m,
            OSpace.s,
            OSpace.xs,
            OSpace.s,
          ),
          child: Row(
            children: [
              Icon(_fileIcon(extension), size: 20, color: c.accent),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      block.fileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: OType.bodySmStrong.copyWith(color: c.text),
                    ),
                    const SizedBox(height: OSpace.xxs),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
              // The icon says "download"; the visible label would repeat it.
              OIconButton(
                icon: Icons.download_rounded,
                semanticLabel: 'Download ${block.fileName}',
                size: 20,
                onPressed: () => onDownload(block.href),
              ),
              Icon(Icons.chevron_right_rounded, size: 18, color: c.textFaint),
            ],
          ),
        ),
      ),
    );
  }

  IconData _fileIcon(String? extension) {
    return switch (extension) {
      'pdf' ||
      'doc' ||
      'docx' ||
      'txt' ||
      'md' ||
      'log' => Icons.description_rounded,
      'csv' || 'xls' || 'xlsx' => Icons.table_chart_rounded,
      'zip' || 'tar' || 'gz' => Icons.folder_zip_rounded,
      'png' ||
      'jpg' ||
      'jpeg' ||
      'gif' ||
      'webp' ||
      'svg' => Icons.image_rounded,
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
      'yml' => Icons.code_rounded,
      'mp3' || 'wav' => Icons.audiotrack_rounded,
      'mp4' => Icons.movie_rounded,
      'apk' || 'ipa' => Icons.android_rounded,
      _ => Icons.insert_drive_file_rounded,
    };
  }
}

class _DownloadLinksCard extends StatelessWidget {
  const _DownloadLinksCard({
    required this.block,
    required this.onOpenLink,
    required this.onDownload,
  });

  final V2DownloadLinksBlock block;
  final ValueChanged<String> onOpenLink;
  final ValueChanged<V2DownloadLink> onDownload;

  @override
  Widget build(BuildContext context) {
    if (block.links.isEmpty) return const SizedBox.shrink();
    final c = OColors.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        children: [
          for (var i = 0; i < block.links.length; i++) ...[
            if (i > 0) Divider(height: 1, color: c.hairline),
            _DownloadLinkRow(
              link: block.links[i],
              onOpenLink: onOpenLink,
              onDownload: onDownload,
            ),
          ],
        ],
      ),
    );
  }
}

class _DownloadLinkRow extends StatelessWidget {
  const _DownloadLinkRow({
    required this.link,
    required this.onOpenLink,
    required this.onDownload,
  });

  final V2DownloadLink link;
  final ValueChanged<String> onOpenLink;
  final ValueChanged<V2DownloadLink> onDownload;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final lower = link.label.trim().toLowerCase();
    final label = link.isDownload
        ? (lower.startsWith('download') ? link.label : 'Download ${link.label}')
        : (lower.startsWith('open') ? link.label : 'Open ${link.label}');
    final onTap = link.isDownload
        ? () => onDownload(link)
        : () => onOpenLink(link.href);
    return Semantics(
      label: label,
      button: true,
      enabled: true,
      excludeSemantics: true,
      child: OPressable(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: OSpace.touch),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: OSpace.m,
              vertical: OSpace.s,
            ),
            child: Row(
              children: [
                Icon(
                  link.isDownload
                      ? Icons.download_rounded
                      : Icons.open_in_new_rounded,
                  size: 20,
                  color: c.accent,
                ),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: Text(
                    link.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: OType.bodySm.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: OSpace.s),
                Icon(Icons.chevron_right_rounded, size: 18, color: c.textFaint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
