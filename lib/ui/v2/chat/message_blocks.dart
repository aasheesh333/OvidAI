import 'dart:async';

import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:markdown/markdown.dart' as md;

import '../../../core/cloud/static_rich_content.dart';
import '../../../core/state.dart';
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'remote_attachment_tile.dart';
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
  const V2BulletItem({required this.text, this.depth = 0, this.checked});

  final String text;

  /// Nesting depth, clamped by the parser so a stray indent cannot push text
  /// off a narrow screen.
  final int depth;

  /// Null for an ordinary bullet; true/false for a settled GFM task item.
  /// Tasks are read-only transcript content, never a second completion engine.
  final bool? checked;
}

final class V2BulletListBlock extends V2MessageBlock {
  const V2BulletListBlock({required this.items, this.ordered = false});

  final List<V2BulletItem> items;
  final bool ordered;
}

/// Column alignment from the markdown separator row (`:---`, `:---:`, `---:`).
enum V2TableAlign { start, center, end }

/// A pipe table (`| a | b |` + a `|---|---|` separator). The header row is
/// always drawn; rows keep the header's column count so a short or overlong
/// row cannot shift cells under the wrong heading.
final class V2TableBlock extends V2MessageBlock {
  const V2TableBlock({
    required this.headers,
    required this.rows,
    this.align = const <V2TableAlign>[],
  });

  final List<String> headers;
  final List<List<String>> rows;

  /// Per-column alignment. Shorter than [headers] means the rest start-align.
  final List<V2TableAlign> align;
}

final class V2CodeBlock extends V2MessageBlock {
  const V2CodeBlock({required this.code, this.language});

  final String code;

  /// Lower-case fence info string, e.g. `dart`. Null for a plain fence.
  final String? language;
}

final class V2DiagramBlock extends V2MessageBlock {
  const V2DiagramBlock({required this.source});

  /// Original Mermaid source, sent only to the offline strict pixel renderer.
  final String source;

  String get title => _diagramTitle(source);
}

final class V2SvgBlock extends V2MessageBlock {
  const V2SvgBlock({required this.source});

  /// XML source, sanitized before it can reach the native pixel renderer.
  final String source;
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
  r'\*\*([^*]+)\*\*|`([^`]+)`|\*([^*\n]+)\*|\[([^\]]+)\]\(([^)\s]+)\)|~~([^~\n]+)~~',
);

/// Parses settled assistant markdown through the existing GFM AST.
///
/// Tables, task lists, strikethrough, headings, lists, fences, images, files
/// and links become explicit Flutter blocks. Raw HTML stays plain md.Text;
/// this renderer never creates a raw-HTML/platform node. Mermaid and SVG
/// fences become static pixel-render requests, not interactive documents.
List<V2MessageBlock> parseV2MessageBlocks(String markdown) {
  // A fresh document per message prevents link/footnote references from one
  // transcript row leaking into another. Raw HTML remains md.Text; no HTML
  // element is ever constructed for it by this renderer.
  final document = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  );
  return List<V2MessageBlock>.unmodifiable(
    _blocksFromNodes(document.parse(markdown)),
  );
}

List<V2MessageBlock> _blocksFromNodes(List<md.Node> nodes) {
  final blocks = <V2MessageBlock>[];
  for (final node in nodes) {
    if (node is md.Text) {
      final text = node.text.trim();
      if (text.isNotEmpty) blocks.add(V2ParagraphBlock(text: text));
      continue;
    }
    if (node is! md.Element) continue;
    switch (node.tag) {
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final text = _inlineSource(node.children).trim();
        if (text.isNotEmpty) {
          final level = int.parse(node.tag.substring(1));
          blocks.add(V2HeadingBlock(level: level > 3 ? 3 : level, text: text));
        }
      case 'p':
        blocks.addAll(_paragraphBlocks(node));
      case 'pre':
        final code = node.children?.whereType<md.Element>().firstWhere(
          (element) => element.tag == 'code',
          orElse: () => md.Element.text('code', ''),
        );
        final languageClass = code?.attributes['class'] ?? '';
        final match = RegExp(
          r'(?:^|\s)language-([^\s]+)',
        ).firstMatch(languageClass);
        final language = match?.group(1)?.toLowerCase();
        final source = (code?.textContent ?? node.textContent).replaceFirst(
          RegExp(r'\n$'),
          '',
        );
        if (language == 'mermaid') {
          blocks.add(V2DiagramBlock(source: source));
        } else if (language == 'svg') {
          blocks.add(V2SvgBlock(source: source));
        } else {
          blocks.add(V2CodeBlock(code: source, language: language));
        }
      case 'ul' || 'ol':
        blocks.add(_listBlock(node));
      case 'table':
        final table = _tableBlock(node);
        if (table != null) blocks.add(table);
      case 'hr':
        blocks.add(const V2DividerBlock());
      case 'blockquote' || 'section':
        blocks.addAll(_blocksFromNodes(node.children ?? const <md.Node>[]));
      default:
        final text = _inlineSource(node.children).trim();
        if (text.isNotEmpty) blocks.add(V2ParagraphBlock(text: text));
    }
  }
  return blocks;
}

List<V2MessageBlock> _paragraphBlocks(md.Element paragraph) {
  final blocks = <V2MessageBlock>[];
  final pending = <md.Node>[];

  void flush() {
    final text = _inlineSource(
      pending,
    ).replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
    pending.clear();
    if (text.isNotEmpty) blocks.add(V2ParagraphBlock(text: text));
  }

  final segments = <List<md.Node>>[<md.Node>[]];
  for (final child in paragraph.children ?? const <md.Node>[]) {
    if (child is md.Text && child.text.contains('\n')) {
      final parts = child.text.split('\n');
      for (var i = 0; i < parts.length; i++) {
        if (parts[i].isNotEmpty) segments.last.add(md.Text(parts[i]));
        if (i < parts.length - 1) segments.add(<md.Node>[]);
      }
    } else {
      segments.last.add(child);
    }
  }

  for (final segment in segments) {
    final meaningful = segment
        .where((node) => node is! md.Text || node.text.trim().isNotEmpty)
        .toList();
    if (meaningful.isEmpty) continue;
    if (meaningful.length == 1 && meaningful.single is md.Element) {
      final only = meaningful.single as md.Element;
      if (only.tag == 'img') {
        flush();
        _appendImage(only, blocks);
        continue;
      }
      if (only.tag == 'a') {
        flush();
        _emitLinkBlocks(<_LinkEntry>[_linkEntry(only)], blocks);
        continue;
      }
    }
    for (final child in meaningful) {
      if (child is md.Element && child.tag == 'img') {
        flush();
        _appendImage(child, blocks);
      } else {
        pending.add(child);
      }
    }
    // Preserve CommonMark's soft line break inside one paragraph.
    pending.add(md.Text('\n'));
  }
  flush();
  final merged = <V2MessageBlock>[];
  for (final block in blocks) {
    if (block is V2DownloadLinksBlock &&
        merged.isNotEmpty &&
        merged.last is V2DownloadLinksBlock) {
      final previous = merged.removeLast() as V2DownloadLinksBlock;
      merged.add(
        V2DownloadLinksBlock(
          links: List<V2DownloadLink>.unmodifiable(<V2DownloadLink>[
            ...previous.links,
            ...block.links,
          ]),
        ),
      );
    } else {
      merged.add(block);
    }
  }
  return merged;
}

void _appendImage(md.Element image, List<V2MessageBlock> blocks) {
  final url = image.attributes['src']?.trim() ?? '';
  if (url.isEmpty) return;
  blocks.add(
    V2ImageBlock(alt: image.attributes['alt']?.trim() ?? '', url: url),
  );
}

V2BulletListBlock _listBlock(md.Element list) {
  final items = <V2BulletItem>[];

  void walk(md.Element current, int depth) {
    for (final item
        in current.children?.whereType<md.Element>() ?? const <md.Element>[]) {
      if (item.tag != 'li') continue;
      var hasCheckbox = false;
      var checked = false;

      void findCheckbox(List<md.Node> nodes) {
        for (final node in nodes) {
          if (node is! md.Element) continue;
          if (node.tag == 'input' && node.attributes['type'] == 'checkbox') {
            hasCheckbox = true;
            checked = node.attributes.containsKey('checked');
          } else if (node.tag != 'ul' && node.tag != 'ol') {
            findCheckbox(node.children ?? const <md.Node>[]);
          }
        }
      }

      findCheckbox(item.children ?? const <md.Node>[]);
      final nested = <md.Element>[];
      final content = <md.Node>[];
      for (final child in item.children ?? const <md.Node>[]) {
        if (child is md.Element && (child.tag == 'ul' || child.tag == 'ol')) {
          nested.add(child);
        } else {
          content.add(child);
        }
      }
      final text = _inlineSource(content).trim();
      if (text.isNotEmpty) {
        items.add(
          V2BulletItem(
            text: text,
            depth: depth > 4 ? 4 : depth,
            checked: hasCheckbox ? checked : null,
          ),
        );
      }
      for (final child in nested) {
        walk(child, depth + 1);
      }
    }
  }

  walk(list, 0);
  return V2BulletListBlock(
    items: List<V2BulletItem>.unmodifiable(items),
    ordered: list.tag == 'ol',
  );
}

V2TableBlock? _tableBlock(md.Element table) {
  md.Element? section(String name) {
    for (final child
        in table.children?.whereType<md.Element>() ?? const <md.Element>[]) {
      if (child.tag == name) return child;
    }
    return null;
  }

  List<md.Element> rows(md.Element? parent) => <md.Element>[
    for (final child
        in parent?.children?.whereType<md.Element>() ?? const <md.Element>[])
      if (child.tag == 'tr') child,
  ];

  List<md.Element> cells(md.Element row, String tag) => <md.Element>[
    for (final child
        in row.children?.whereType<md.Element>() ?? const <md.Element>[])
      if (child.tag == tag) child,
  ];

  final head = rows(section('thead'));
  if (head.isEmpty) return null;
  final headerCells = cells(head.single, 'th');
  if (headerCells.isEmpty) return null;
  final bodyRows = rows(section('tbody'));
  return V2TableBlock(
    headers: List<String>.unmodifiable(
      headerCells.map((cell) => _inlineSource(cell.children).trim()),
    ),
    rows: List<List<String>>.unmodifiable(
      bodyRows.map(
        (row) => List<String>.unmodifiable(
          cells(row, 'td').map((cell) => _inlineSource(cell.children).trim()),
        ),
      ),
    ),
    align: List<V2TableAlign>.unmodifiable(
      headerCells.map((cell) {
        return switch (cell.attributes['align']) {
          'right' => V2TableAlign.end,
          'center' => V2TableAlign.center,
          _ => V2TableAlign.start,
        };
      }),
    ),
  );
}

String _inlineSource(List<md.Node>? nodes) {
  final out = StringBuffer();
  for (final node in nodes ?? const <md.Node>[]) {
    if (node is md.Text) {
      out.write(node.text);
      continue;
    }
    if (node is! md.Element) continue;
    final content = _inlineSource(node.children);
    switch (node.tag) {
      case 'strong':
        out.write('**$content**');
      case 'em':
        out.write('*$content*');
      case 'del':
        out.write('~~$content~~');
      case 'code':
        out.write('`$content`');
      case 'a':
        out.write('[$content](${node.attributes['href'] ?? ''})');
      case 'img':
        out.write(
          '![${node.attributes['alt'] ?? ''}](${node.attributes['src'] ?? ''})',
        );
      case 'br':
        out.write('\n');
      case 'input':
        break;
      default:
        out.write(content);
    }
  }
  return out.toString();
}

_LinkEntry _linkEntry(md.Element link) => _LinkEntry(
  _inlineSource(link.children).trim(),
  link.attributes['href']?.trim() ?? '',
);

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

final class _LinkEntry {
  const _LinkEntry(this.label, this.href);

  final String label;
  final String href;
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

final SettledContentCache<V2MessageBlock> _settledContentCache =
    SettledContentCache<V2MessageBlock>(
      parser: (message) => parseV2MessageBlocksCached(message.content),
      limit: _parseCacheLimit,
    );

typedef V2StaticDiagramRenderer = Future<Uint8List> Function(String source);

/// Renders a settled markdown message as lightweight chat blocks.
///
/// Streaming text has a deliberately plain path: no incomplete GFM parse,
/// syntax highlighting, remote image, or diagram renderer runs per delta.
class V2MessageBlocks extends StatelessWidget {
  const V2MessageBlocks({
    super.key,
    required this.markdown,
    this.message,
    this.settled = true,
    this.onCopyCode,
    this.onOpenLink,
    this.onDownload,
    this.imageLoader,
    this.mermaidRenderer,
    this.svgRenderer,
  });

  final String markdown;
  final Message? message;
  final bool settled;

  /// Overrides clipboard copy for code blocks (tests and hosts that record it).
  final ValueChanged<String>? onCopyCode;

  /// Open a page, image or non-download link.
  final ValueChanged<String>? onOpenLink;

  /// Download an artifact or a link whose label says "Download".
  final ValueChanged<String>? onDownload;
  final RemoteImageLoader? imageLoader;
  final V2StaticDiagramRenderer? mermaidRenderer;
  final V2StaticDiagramRenderer? svgRenderer;

  @override
  Widget build(BuildContext context) {
    final isSettled = settled && message?.kind != MsgKind.streaming;
    if (!isSettled) {
      return Text(
        markdown,
        style: OType.body.copyWith(color: OColors.of(context).text),
      );
    }
    final sourceMessage = message;
    final blocks = sourceMessage == null
        ? parseV2MessageBlocksCached(markdown)
        : _settledContentCache.blocksFor(sourceMessage);
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
      V2TableBlock table => _TableView(block: table, onOpenLink: open),
      V2CodeBlock code => _CodeBlockCard(block: code, onCopy: onCopyCode),
      V2DiagramBlock diagram => _DiagramCard(
        block: diagram,
        renderer: mermaidRenderer,
      ),
      V2SvgBlock svg => _SvgCard(block: svg, renderer: svgRenderer),
      V2ImageBlock image => _ImageCard(
        block: image,
        loader: imageLoader,
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
    this.textAlign = TextAlign.start,
  });

  final String text;
  final TextStyle style;
  final ValueChanged<String> onOpenLink;
  final TextAlign textAlign;

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
      } else if (match.group(6) != null) {
        spans.add(
          TextSpan(
            text: match.group(6),
            style: style.copyWith(decoration: TextDecoration.lineThrough),
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
    return Text.rich(
      TextSpan(style: style, children: spans),
      textAlign: widget.textAlign,
    );
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
                if (block.items[i].checked != null)
                  Semantics(
                    label:
                        '${block.items[i].checked! ? 'Completed' : 'Incomplete'} task: ${block.items[i].text}',
                    child: Icon(
                      block.items[i].checked!
                          ? Icons.check_box_rounded
                          : Icons.check_box_outline_blank_rounded,
                      size: 18,
                      color: c.textMuted,
                    ),
                  )
                else if (block.ordered)
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

/// A markdown table: header row, one hairline between rows, and real cell
/// text (inline bold/code/links still work). A wide table scrolls sideways
/// inside its card instead of clipping or shrinking the text, which is the
/// only way columns stay readable at 320 dp / 200 %.
class _TableView extends StatelessWidget {
  const _TableView({required this.block, required this.onOpenLink});

  final V2TableBlock block;
  final ValueChanged<String> onOpenLink;

  TextAlign _alignFor(int column) => switch (column < block.align.length
      ? block.align[column]
      : V2TableAlign.start) {
    V2TableAlign.start => TextAlign.start,
    V2TableAlign.center => TextAlign.center,
    V2TableAlign.end => TextAlign.end,
  };

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    if (block.headers.isEmpty) return const SizedBox.shrink();

    TableRow row(List<String> cells, {required bool header}) {
      return TableRow(
        decoration: header ? BoxDecoration(color: c.surfaceAlt) : null,
        children: [
          for (var i = 0; i < block.headers.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.m,
                vertical: OSpace.s,
              ),
              child: _InlineText(
                text: i < cells.length ? cells[i] : '',
                style: (header ? OType.bodyMdStrong : OType.bodyMd).copyWith(
                  color: c.text,
                ),
                onOpenLink: onOpenLink,
                textAlign: _alignFor(i),
              ),
            ),
        ],
      );
    }

    return Semantics(
      container: true,
      label: 'Table',
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(ORadius.m),
          border: Border.all(color: c.hairline),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder(
              horizontalInside: BorderSide(color: c.hairline),
            ),
            children: [
              row(block.headers, header: true),
              for (final cells in block.rows) row(cells, header: false),
            ],
          ),
        ),
      ),
    );
  }
}

final RegExp _codeTokenPattern = RegExp(
  r'"(?:\\.|[^"\\])*"|//[^\n]*|\b(?:abstract|as|async|await|bool|break|case|catch|class|const|continue|def|do|double|else|enum|export|extends|final|finally|for|function|if|import|int|is|late|let|new|null|return|sealed|static|String|super|switch|this|throw|true|false|try|var|void|while|with|yield)\b|\b\d+(?:\.\d+)?\b',
);

TextSpan _highlightedCodeSpan(String code, OColors c) {
  final base = OType.mono.copyWith(color: c.textMuted);
  final spans = <TextSpan>[];
  var offset = 0;
  for (final match in _codeTokenPattern.allMatches(code)) {
    if (match.start > offset) {
      spans.add(TextSpan(text: code.substring(offset, match.start)));
    }
    final token = match.group(0)!;
    final style = token.startsWith('//')
        ? base.copyWith(color: c.textFaint, fontStyle: FontStyle.italic)
        : token.startsWith('"')
        ? base.copyWith(color: c.accent)
        : RegExp(r'^\d').hasMatch(token)
        ? base.copyWith(color: c.accent)
        : base.copyWith(color: c.text, fontWeight: FontWeight.w600);
    spans.add(TextSpan(text: token, style: style));
    offset = match.end;
  }
  if (offset < code.length) spans.add(TextSpan(text: code.substring(offset)));
  return TextSpan(style: base, children: spans);
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
            child: Text.rich(_highlightedCodeSpan(widget.block.code, c)),
          ),
        ],
      ),
    );
  }
}

class _DiagramCard extends StatelessWidget {
  const _DiagramCard({required this.block, this.renderer});

  final V2DiagramBlock block;
  final V2StaticDiagramRenderer? renderer;

  @override
  Widget build(BuildContext context) {
    return _StaticDiagramCard(
      title: block.title,
      source: block.source,
      renderer: renderer ?? StaticRichContentRenderer.renderMermaidPng,
      showSource: true,
    );
  }
}

class _SvgCard extends StatelessWidget {
  const _SvgCard({required this.block, this.renderer});

  final V2SvgBlock block;
  final V2StaticDiagramRenderer? renderer;

  @override
  Widget build(BuildContext context) {
    return _StaticDiagramCard(
      title: 'SVG diagram',
      source: block.source,
      renderer: renderer ?? StaticRichContentRenderer.renderSvgPng,
      showSource: false,
    );
  }
}

class _StaticDiagramCard extends StatefulWidget {
  const _StaticDiagramCard({
    required this.title,
    required this.source,
    required this.renderer,
    required this.showSource,
  });

  final String title;
  final String source;
  final V2StaticDiagramRenderer renderer;
  final bool showSource;

  @override
  State<_StaticDiagramCard> createState() => _StaticDiagramCardState();
}

class _StaticDiagramCardState extends State<_StaticDiagramCard> {
  late Future<Uint8List> _pixels;
  late String _requestId;
  var _generation = 0;
  var _nativeRender = false;

  void _beginRender() {
    _requestId = 'diagram-${identityHashCode(this)}-$_generation';
    if (widget.renderer == StaticRichContentRenderer.renderMermaidPng) {
      _nativeRender = true;
      _pixels = StaticRichContentRenderer.renderMermaidPng(
        widget.source,
        requestId: _requestId,
      );
    } else if (widget.renderer == StaticRichContentRenderer.renderSvgPng) {
      _nativeRender = true;
      _pixels = StaticRichContentRenderer.renderSvgPng(
        widget.source,
        requestId: _requestId,
      );
    } else {
      _nativeRender = false;
      _pixels = widget.renderer(widget.source);
    }
  }

  void _cancelRender() {
    if (_nativeRender) unawaited(_cancelRenderSafely());
  }

  Future<void> _cancelRenderSafely() async {
    try {
      await StaticRichContentRenderer.cancelRender(_requestId);
    } on MissingPluginException {
      // Disposal is also valid before native registration completes.
    } on StateError {
      // A malformed outcome is not allowed as an outcome, but disposal must
      // still finish without an unhandled asynchronous error.
    }
  }

  @override
  void initState() {
    super.initState();
    _beginRender();
  }

  @override
  void didUpdateWidget(_StaticDiagramCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.renderer != widget.renderer) {
      _cancelRender();
      _generation++;
      _beginRender();
    }
  }

  @override
  void dispose() {
    _cancelRender();
    super.dispose();
  }

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
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          FutureBuilder<Uint8List>(
            future: _pixels,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return Text(
                  'Rendering diagram…',
                  style: OType.bodyMd.copyWith(color: c.textMuted),
                );
              }
              final bytes = snapshot.data;
              if (snapshot.hasError || bytes == null) {
                return Text(
                  'Diagram unavailable',
                  style: OType.bodyMd.copyWith(color: c.textMuted),
                );
              }
              return ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 480),
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  semanticLabel: widget.title,
                  errorBuilder: (_, _, _) => Text(
                    'Diagram unavailable',
                    style: OType.bodyMd.copyWith(color: c.textMuted),
                  ),
                ),
              );
            },
          ),
          if (widget.showSource) ...[
            const SizedBox(height: OSpace.m),
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
                  widget.source,
                  style: OType.mono.copyWith(color: c.textMuted),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ImageCard extends StatelessWidget {
  const _ImageCard({
    required this.block,
    required this.loader,
    required this.onOpen,
    required this.onDownload,
  });

  final V2ImageBlock block;
  final RemoteImageLoader? loader;
  final ValueChanged<String> onOpen;
  final ValueChanged<String> onDownload;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final alt = block.alt.isEmpty ? 'Image' : block.alt;
    final url = block.url;
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
          RemoteTranscriptImage(url: url, alt: alt, loader: loader),
          OPressable(
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
                          style: OType.bodyMdStrong.copyWith(color: c.text),
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
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: c.textFaint,
                  ),
                ],
              ),
            ),
          ),
        ],
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
                      style: OType.bodyMdStrong.copyWith(color: c.text),
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
                    style: OType.bodyMd.copyWith(
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
