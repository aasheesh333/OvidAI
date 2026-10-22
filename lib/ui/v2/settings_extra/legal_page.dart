import 'package:flutter/foundation.dart' show LicenseEntry, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

enum V2LegalPageStatus { loading, ready, empty, error }

/// One ordered block inside a legal section. The published documents mix
/// paragraphs, bullet lists and tables; keeping the order means the in-app
/// copy reads the same as the Markdown source.
@immutable
sealed class V2LegalBlock {
  const V2LegalBlock();
}

@immutable
class V2LegalParagraph extends V2LegalBlock {
  const V2LegalParagraph(this.text);

  final String text;
}

@immutable
class V2LegalBulletList extends V2LegalBlock {
  const V2LegalBulletList(this.items);

  final List<String> items;
}

/// One heading and its copy inside a legal document. Bullets are optional and
/// render under [body]; licences use them for package lists.
@immutable
class V2LegalSection {
  const V2LegalSection({
    required this.heading,
    this.body = '',
    this.bullets = const <String>[],
    this.blocks = const <V2LegalBlock>[],
  });

  final String heading;
  final String body;
  final List<String> bullets;

  /// Ordered content parsed from the source document. When empty, [body] and
  /// [bullets] are rendered instead (the shape callers and tests inject).
  final List<V2LegalBlock> blocks;

  bool get hasBody => body.trim().isNotEmpty;
  bool get hasBullets => bullets.isNotEmpty;
  bool get hasBlocks => blocks.isNotEmpty;
}

/// Injected state for a legal document. The same page renders the privacy
/// policy, the terms of service and the open-source licences; only the copy
/// and the icon change.
@immutable
class V2LegalPageData {
  const V2LegalPageData({
    required this.title,
    this.icon = Icons.description_outlined,
    this.updatedAt = '',
    this.summary = '',
    this.sections = const <V2LegalSection>[],
    this.status = V2LegalPageStatus.ready,
    this.offline = false,
    this.offlineNote =
        "You're offline. This is the saved copy of the document.",
    this.errorMessage = 'We could not load this document.',
    this.onBack,
    this.onRetry,
  });

  final String title;
  final IconData icon;

  /// Human-readable date, for example "12 March 2026". The screen does not
  /// format or localise it.
  final String updatedAt;

  /// Short lead-in shown before the first section.
  final String summary;
  final List<V2LegalSection> sections;
  final V2LegalPageStatus status;

  /// While offline the last downloaded copy stays readable.
  final bool offline;
  final String offlineNote;

  final String errorMessage;

  final VoidCallback? onBack;
  final VoidCallback? onRetry;

  String get updatedLabel =>
      updatedAt.trim().isEmpty ? '' : 'Last updated $updatedAt';

  bool get hasContent =>
      status == V2LegalPageStatus.ready && sections.isNotEmpty;
}

/// Why a real document could not be read. [message] is shown verbatim, so it
/// names the cause instead of a generic failure.
class V2LegalLoadException implements Exception {
  const V2LegalLoadException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum V2LegalDocumentKind { asset, network, custom }

/// A real legal document: a bundled Markdown asset, a fetched URL, or an
/// injected loader for tests and hosts.
///
/// The text is parsed from the source at open time, so the in-app reader never
/// carries a second hand-maintained copy of the policy.
@immutable
class V2LegalDocument {
  const V2LegalDocument({
    required this.title,
    required this.load,
    this.icon = Icons.description_outlined,
    this.kind = V2LegalDocumentKind.custom,
  });

  factory V2LegalDocument.asset({
    required String assetPath,
    required String title,
    IconData icon = Icons.description_outlined,
  }) {
    return V2LegalDocument(
      title: title,
      icon: icon,
      kind: V2LegalDocumentKind.asset,
      load: () => rootBundle.loadString(assetPath),
    );
  }

  factory V2LegalDocument.url({
    required Uri url,
    required String title,
    IconData icon = Icons.description_outlined,
    http.Client? client,
  }) {
    return V2LegalDocument(
      title: title,
      icon: icon,
      kind: V2LegalDocumentKind.network,
      load: () async {
        // A dead host must not leave the reader on a loading skeleton: the
        // ceiling turns it into the page's own "could not be downloaded" copy
        // with a retry.
        final response = await (client == null
                ? http.get(url)
                : client.get(url))
            .timeout(const Duration(seconds: 20));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw const V2LegalLoadException(
            'The document could not be downloaded. Try again.',
          );
        }
        return response.body;
      },
    );
  }

  final String title;
  final IconData icon;
  final V2LegalDocumentKind kind;
  final Future<String> Function() load;
}

/// A long-form legal document: title, last-updated date, sections and a back
/// affordance. [status] drives the loading, empty and error variants.
class LegalPage extends StatefulWidget {
  const LegalPage({super.key, required this.data, this.onBack})
    : document = null;

  /// Reads a real document (bundled asset or URL) and renders the parsed
  /// sections. Loading and failures have their own states.
  const LegalPage.document({
    super.key,
    required V2LegalDocument this.document,
    this.onBack,
  }) : data = null;

  final V2LegalPageData? data;
  final V2LegalDocument? document;

  /// Overrides the back action. Defaults to popping the route.
  final VoidCallback? onBack;

  @override
  State<LegalPage> createState() => _LegalPageState();
}

class _LegalPageState extends State<LegalPage> {
  late V2LegalPageStatus _status;
  V2LegalPageData? _data;
  String? _error;
  int _loadId = 0;

  @override
  void initState() {
    super.initState();
    final injected = widget.data;
    if (injected != null) {
      _data = injected;
      _status = injected.status;
    } else {
      _status = V2LegalPageStatus.loading;
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant LegalPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final injected = widget.data;
    if (injected != null) {
      _data = injected;
      _status = injected.status;
      _error = null;
      return;
    }
    if (widget.document != oldWidget.document) _load();
  }

  Future<void> _load() async {
    final document = widget.document;
    if (document == null) return;
    final id = ++_loadId;
    setState(() {
      _status = V2LegalPageStatus.loading;
      _error = null;
    });
    try {
      final source = await document.load();
      final parsed = parseLegalMarkdown(
        source,
        fallbackTitle: document.title,
        icon: document.icon,
      );
      if (parsed.sections.isEmpty) {
        throw const V2LegalLoadException('The document is empty.');
      }
      if (!mounted || id != _loadId) return;
      setState(() {
        _data = parsed;
        _status = V2LegalPageStatus.ready;
      });
    } on V2LegalLoadException catch (error) {
      _fail(id, error.message);
    } catch (_) {
      _fail(id, switch (document.kind) {
        V2LegalDocumentKind.asset => 'The document is missing from this build.',
        V2LegalDocumentKind.network => 'The document could not be downloaded.',
        V2LegalDocumentKind.custom => 'The document could not be loaded.',
      });
    }
  }

  void _fail(int id, String reason) {
    if (!mounted || id != _loadId) return;
    setState(() {
      _status = V2LegalPageStatus.error;
      _error = reason;
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final document = widget.document;
    return OScreen(
      title: data?.title ?? document?.title ?? 'Document',
      leading: OIconButton(
        icon: Icons.arrow_back_rounded,
        semanticLabel: 'Back',
        onPressed:
            widget.data?.onBack ??
            widget.onBack ??
            () => Navigator.maybePop(context),
      ),
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_status == V2LegalPageStatus.loading) {
      return const OFadeSlide(child: OSkeletonList(rows: 5));
    }
    if (_status == V2LegalPageStatus.error) {
      return OErrorState(
        title: 'Document unavailable',
        message:
            _error ??
            widget.data?.errorMessage ??
            'We could not load this document.',
        onRetry: _retry,
      );
    }
    final data = _data;
    if (_status == V2LegalPageStatus.empty ||
        data == null ||
        data.sections.isEmpty) {
      return _empty(context);
    }
    return _content(context, data);
  }

  VoidCallback? get _retry =>
      widget.data?.onRetry ?? (widget.document == null ? null : _load);

  Widget _content(BuildContext context, V2LegalPageData data) {
    final sections = data.sections;
    return ListView.builder(
      padding: const EdgeInsets.only(top: OSpace.xl, bottom: OSpace.xxl),
      itemCount: sections.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _header(context, data);
        return _section(context, sections[index - 1]);
      },
    );
  }

  /// The document title already lives in the header; the body carries only
  /// the date, the lead-in and the offline note.
  Widget _header(BuildContext context, V2LegalPageData data) {
    final c = OColors.of(context);
    final showOffline = data.offline && data.offlineNote.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (data.updatedLabel.isNotEmpty) ...[
            Text(
              data.updatedLabel,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: OSpace.m),
          ],
          if (data.summary.trim().isNotEmpty) ...[
            Text(
              data.summary,
              style: OType.bodySm.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: OSpace.l),
          ],
          if (showOffline) _offlineNote(context, data),
        ],
      ),
    );
  }

  Widget _offlineNote(BuildContext context, V2LegalPageData data) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      child: Container(
        padding: const EdgeInsets.all(OSpace.m),
        decoration: BoxDecoration(
          color: c.surfaceAlt,
          borderRadius: BorderRadius.circular(ORadius.m),
          border: Border.all(color: c.hairline),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.cloud_off_rounded, size: 18, color: c.textMuted),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Text(
                data.offlineNote,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, V2LegalSection section) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              section.heading,
              style: OType.h3.copyWith(color: c.text),
            ),
          ),
          if (section.hasBlocks)
            for (var index = 0; index < section.blocks.length; index++) ...[
              const SizedBox(height: OSpace.s),
              _block(context, section.blocks[index]),
            ]
          else ...[
            if (section.hasBody) ...[
              const SizedBox(height: OSpace.s),
              Text(
                section.body,
                style: OType.body.copyWith(color: c.textMuted),
              ),
            ],
            if (section.hasBullets) ...[
              const SizedBox(height: OSpace.s),
              for (final bullet in section.bullets) _bullet(context, bullet),
            ],
          ],
        ],
      ),
    );
  }

  Widget _block(BuildContext context, V2LegalBlock block) {
    final c = OColors.of(context);
    return switch (block) {
      V2LegalParagraph(:final text) => Text(
        text,
        style: OType.body.copyWith(color: c.textMuted),
      ),
      V2LegalBulletList(:final items) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final item in items) _bullet(context, item)],
      ),
    };
  }

  Widget _bullet(BuildContext context, String text) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('•', style: OType.body.copyWith(color: c.textFaint)),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(text, style: OType.body.copyWith(color: c.textMuted)),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final retry = _retry;
    return OEmptyState(
      icon: Icons.article_outlined,
      title: 'Document unavailable',
      message: retry == null
          ? 'It may have been removed.'
          : 'Check your connection and try again.',
      action: OButton(
        label: retry == null ? 'Go back' : 'Try again',
        icon: retry == null ? Icons.arrow_back_rounded : Icons.refresh_rounded,
        onPressed:
            retry ??
            widget.data?.onBack ??
            widget.onBack ??
            () => Navigator.maybePop(context),
      ),
    );
  }
}

/// The real Flutter licence registry, grouped by package. This is the same
/// registry the framework uses, so the list always matches the packages in
/// the build.
class LicencesPage extends StatefulWidget {
  const LicencesPage({super.key, this.onBack, this.loadLicences});

  final VoidCallback? onBack;

  /// Injectable registry stream for tests. Defaults to
  /// [LicenseRegistry.licenses].
  final Stream<LicenseEntry> Function()? loadLicences;

  @override
  State<LicencesPage> createState() => _LicencesPageState();
}

class _LicencesPageState extends State<LicencesPage> {
  V2LegalPageStatus _status = V2LegalPageStatus.loading;
  String? _error;
  List<_LicencePackage> _packages = const <_LicencePackage>[];
  int _loadId = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = ++_loadId;
    setState(() {
      _status = V2LegalPageStatus.loading;
      _error = null;
    });
    try {
      final grouped = <String, List<String>>{};
      final entries = widget.loadLicences?.call() ?? LicenseRegistry.licenses;
      await for (final entry in entries) {
        final text = entry.paragraphs
            .map((paragraph) => paragraph.text.trim())
            .where((paragraph) => paragraph.isNotEmpty)
            .join('\n\n');
        if (text.isEmpty) continue;
        for (final package in entry.packages) {
          final name = package.trim();
          if (name.isEmpty) continue;
          final texts = grouped.putIfAbsent(name, () => <String>[]);
          if (!texts.contains(text)) texts.add(text);
        }
      }
      if (!mounted || id != _loadId) return;
      if (grouped.isEmpty) {
        setState(() {
          _status = V2LegalPageStatus.error;
          _error = 'No licence notices were found in this build.';
        });
        return;
      }
      final packages = <_LicencePackage>[
        for (final entry in grouped.entries)
          _LicencePackage(entry.key, List<String>.unmodifiable(entry.value)),
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() {
        _packages = List<_LicencePackage>.unmodifiable(packages);
        _status = V2LegalPageStatus.ready;
      });
    } catch (_) {
      if (!mounted || id != _loadId) return;
      setState(() {
        _status = V2LegalPageStatus.error;
        _error = 'The licence registry could not be read.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: 'Open-source licences',
      leading: OIconButton(
        icon: Icons.arrow_back_rounded,
        semanticLabel: 'Back',
        onPressed: widget.onBack ?? () => Navigator.maybePop(context),
      ),
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    return switch (_status) {
      V2LegalPageStatus.loading => const OFadeSlide(
        child: OSkeletonList(rows: 6),
      ),
      V2LegalPageStatus.error => OErrorState(
        title: 'Licences unavailable',
        message: _error ?? 'The licence registry could not be read.',
        onRetry: _load,
      ),
      _ => _list(context),
    };
  }

  Widget _list(BuildContext context) {
    final packages = _packages;
    return ListView.builder(
      padding: const EdgeInsets.only(top: OSpace.xl, bottom: OSpace.xxl),
      itemCount: packages.length,
      itemBuilder: (context, index) => _package(context, packages[index]),
    );
  }

  Widget _package(BuildContext context, _LicencePackage package) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(package.name, style: OType.h3.copyWith(color: c.text)),
          ),
          for (final text in package.texts) ...[
            const SizedBox(height: OSpace.s),
            Text(text, style: OType.bodySm.copyWith(color: c.textMuted)),
          ],
        ],
      ),
    );
  }
}

@immutable
class _LicencePackage {
  const _LicencePackage(this.name, this.texts);

  final String name;
  final List<String> texts;
}

/// Parses the Markdown that ships in `docs/legal/` into the section model the
/// page renders.
///
/// The parser covers the constructs those documents use: `#`/`##`/`###`
/// headings, paragraphs, `-` and numbered lists, and pipe tables (rendered as
/// wrapping rows so a four-column table cannot overflow a 320 dp screen).
V2LegalPageData parseLegalMarkdown(
  String source, {
  required String fallbackTitle,
  IconData icon = Icons.description_outlined,
}) {
  final lines = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  String? title;
  var updatedAt = '';
  final summaryLines = <String>[];
  final builders = <_SectionBuilder>[];
  _SectionBuilder? current;
  var inSummary = true;

  for (var index = 0; index < lines.length; index++) {
    final raw = lines[index];
    final trimmed = raw.trim();

    if (trimmed.startsWith('# ')) {
      title ??= _inlineMarkdown(trimmed.substring(2));
      continue;
    }
    if (trimmed.startsWith('**Last updated:**')) {
      updatedAt = _inlineMarkdown(
        trimmed.substring('**Last updated:**'.length),
      );
      continue;
    }
    if (trimmed.startsWith('**Effective:**') ||
        trimmed.startsWith('**Applies to:**')) {
      continue;
    }
    if (trimmed.startsWith('### ')) {
      current = _SectionBuilder(_inlineMarkdown(trimmed.substring(4)));
      builders.add(current);
      inSummary = false;
      continue;
    }
    if (trimmed.startsWith('## ')) {
      current = _SectionBuilder(_inlineMarkdown(trimmed.substring(3)));
      builders.add(current);
      inSummary = false;
      continue;
    }
    if (trimmed.isEmpty) {
      if (!inSummary) {
        current!.flushParagraph();
        current.flushBullets();
      }
      continue;
    }
    if (inSummary) {
      summaryLines.add(_inlineMarkdown(trimmed));
      continue;
    }
    if (trimmed.startsWith('|')) {
      final table = <String>[];
      while (index < lines.length && lines[index].trim().startsWith('|')) {
        table.add(lines[index].trim());
        index++;
      }
      index--;
      current!.addTable(table);
      continue;
    }
    if (trimmed.startsWith('- ')) {
      current!.addBullet(_inlineMarkdown(trimmed.substring(2)));
      continue;
    }
    final numbered = RegExp(r'^\d+\.\s+(.*)$').firstMatch(trimmed);
    if (numbered != null) {
      current!.addBullet(_inlineMarkdown(numbered.group(1)!));
      continue;
    }
    if (raw.startsWith('  ') && current!.hasActiveBullet) {
      current.appendToBullet(_inlineMarkdown(trimmed));
      continue;
    }
    current!.addParagraphLine(_inlineMarkdown(trimmed));
  }

  final sections = <V2LegalSection>[
    for (final builder in builders) builder.build(),
  ];
  if (sections.isEmpty) {
    final body = summaryLines.where((line) => line.isNotEmpty).join(' ');
    if (body.isNotEmpty) {
      sections.add(V2LegalSection(heading: 'Details', body: body));
    }
  }
  final summary = summaryLines.where((line) => line.isNotEmpty).join(' ');
  final parsedTitle = title?.trim();
  final resolvedTitle = fallbackTitle.trim().isNotEmpty
      ? fallbackTitle.trim()
      : (parsedTitle?.isNotEmpty == true ? parsedTitle! : 'Document');

  return V2LegalPageData(
    title: resolvedTitle,
    icon: icon,
    updatedAt: updatedAt,
    summary: summary,
    sections: List<V2LegalSection>.unmodifiable(sections),
    status: sections.isEmpty
        ? V2LegalPageStatus.empty
        : V2LegalPageStatus.ready,
  );
}

class _SectionBuilder {
  _SectionBuilder(this.heading);

  final String heading;
  final List<V2LegalBlock> _blocks = <V2LegalBlock>[];
  final List<String> _paragraph = <String>[];
  final List<String> _bullets = <String>[];

  bool get hasActiveBullet => _bullets.isNotEmpty;

  void addParagraphLine(String line) {
    flushBullets();
    _paragraph.add(line);
  }

  void addBullet(String text) {
    flushParagraph();
    _bullets.add(text);
  }

  void appendToBullet(String text) {
    if (_bullets.isEmpty) {
      addParagraphLine(text);
      return;
    }
    _bullets[_bullets.length - 1] = '${_bullets.last} $text';
  }

  void addTable(List<String> rows) {
    flushParagraph();
    flushBullets();
    final items = <String>[];
    for (final row in rows) {
      final cells = row.split('|').map((cell) => cell.trim()).toList();
      if (cells.isNotEmpty && cells.first.isEmpty) cells.removeAt(0);
      if (cells.isNotEmpty && cells.last.isEmpty) cells.removeLast();
      if (cells.isEmpty) continue;
      final separator = cells.every(
        (cell) => RegExp(r'^:?-{2,}:?$').hasMatch(cell),
      );
      if (separator) continue;
      final text = cells
          .map(_inlineMarkdown)
          .where((cell) => cell.isNotEmpty)
          .join(' — ');
      if (text.isNotEmpty) items.add(text);
    }
    if (items.isNotEmpty) {
      _blocks.add(V2LegalBulletList(List<String>.unmodifiable(items)));
    }
  }

  void flushParagraph() {
    if (_paragraph.isEmpty) return;
    _blocks.add(V2LegalParagraph(_paragraph.join(' ')));
    _paragraph.clear();
  }

  void flushBullets() {
    if (_bullets.isEmpty) return;
    _blocks.add(V2LegalBulletList(List<String>.unmodifiable(_bullets)));
    _bullets.clear();
  }

  V2LegalSection build() {
    flushParagraph();
    flushBullets();
    return V2LegalSection(
      heading: heading,
      blocks: List<V2LegalBlock>.unmodifiable(_blocks),
    );
  }
}

String _inlineMarkdown(String text) {
  var value = text.trim();
  value = value.replaceAllMapped(RegExp(r'\[([^\]]+)\]\(([^)]+)\)'), (match) {
    final label = match.group(1)!.trim();
    final url = match.group(2)!.trim();
    return label == url ? label : '$label ($url)';
  });
  value = value.replaceAllMapped(
    RegExp(r'\*\*(.+?)\*\*'),
    (match) => match.group(1)!,
  );
  value = value.replaceAllMapped(
    RegExp(r'`([^`]+)`'),
    (match) => match.group(1)!,
  );
  value = value.replaceAllMapped(
    RegExp(r'\*([^*]+)\*'),
    (match) => match.group(1)!,
  );
  return value.trim();
}
