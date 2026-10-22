import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

enum V2LegalPageStatus { loading, ready, empty, error }

/// One heading and its copy inside a legal document. Bullets are optional and
/// render under [body]; licences use them for package lists.
@immutable
class V2LegalSection {
  const V2LegalSection({
    required this.heading,
    this.body = '',
    this.bullets = const <String>[],
  });

  final String heading;
  final String body;
  final List<String> bullets;

  bool get hasBody => body.trim().isNotEmpty;
  bool get hasBullets => bullets.isNotEmpty;
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

/// A long-form legal document: title, last-updated date, sections and a back
/// affordance. [status] drives the loading, empty and error variants.
class LegalPage extends StatelessWidget {
  const LegalPage({super.key, required this.data});

  final V2LegalPageData data;

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: data.title,
      leading: OIconButton(
        icon: Icons.arrow_back_rounded,
        semanticLabel: 'Back',
        onPressed: data.onBack ?? () => Navigator.maybePop(context),
      ),
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (data.status == V2LegalPageStatus.loading) {
      return const OFadeSlide(child: OSkeletonList(rows: 5));
    }
    if (data.status == V2LegalPageStatus.error) {
      return OErrorState(
        title: 'Document unavailable',
        message: data.errorMessage,
        onRetry: data.onRetry,
      );
    }
    if (data.status == V2LegalPageStatus.empty || data.sections.isEmpty) {
      return _empty(context);
    }
    return _content(context);
  }

  Widget _content(BuildContext context) {
    final sections = data.sections;
    return ListView.builder(
      padding: const EdgeInsets.only(top: OSpace.xl, bottom: OSpace.xxl),
      itemCount: sections.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _header(context);
        return _section(context, sections[index - 1]);
      },
    );
  }

  /// The document title already lives in the header; the body carries only
  /// the date, the lead-in and the offline note.
  Widget _header(BuildContext context) {
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
          if (showOffline) _offlineNote(context),
        ],
      ),
    );
  }

  Widget _offlineNote(BuildContext context) {
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
          if (section.hasBody) ...[
            const SizedBox(height: OSpace.s),
            Text(section.body, style: OType.body.copyWith(color: c.textMuted)),
          ],
          if (section.hasBullets) ...[
            const SizedBox(height: OSpace.s),
            for (final bullet in section.bullets) _bullet(context, bullet),
          ],
        ],
      ),
    );
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
    final retry = data.onRetry;
    return OEmptyState(
      icon: Icons.article_outlined,
      title: 'Document unavailable',
      message: retry == null
          ? 'It may have been removed.'
          : 'Check your connection and try again.',
      action: OButton(
        label: retry == null ? 'Go back' : 'Try again',
        icon: retry == null ? Icons.arrow_back_rounded : Icons.refresh_rounded,
        onPressed: retry ?? data.onBack ?? () => Navigator.maybePop(context),
      ),
    );
  }
}
