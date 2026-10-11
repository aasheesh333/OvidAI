import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [url] outside the app. When no app can handle it (or the launch
/// throws), shows a SnackBar with the address and a "Copy link" action so the
/// user is never left with a silent failure.
///
/// Returns whether the launch succeeded.
Future<bool> openExternalLink(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final uri = Uri.tryParse(url);
  var opened = false;
  if (uri != null) {
    try {
      opened = await (externalLinkLauncherForTest ?? _launch)(uri);
    } catch (_) {
      opened = false;
    }
  }
  if (!opened && messenger != null && messenger.mounted) {
    final shown = uri != null && uri.scheme == 'mailto' ? uri.path : url;
    messenger
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Could not open $shown'),
          action: SnackBarAction(
            label: 'Copy link',
            onPressed: () => Clipboard.setData(ClipboardData(text: shown)),
          ),
        ),
      );
  }
  return opened;
}

Future<bool> _launch(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Test seam: replaces the platform launcher.
@visibleForTesting
Future<bool> Function(Uri uri)? externalLinkLauncherForTest;

/// An inline text link with a 48dp minimum touch target, exposed to
/// accessibility services as a link.
class ExternalLinkButton extends StatelessWidget {
  const ExternalLinkButton({
    super.key,
    required this.label,
    required this.url,
    this.style,
  });

  final String label;
  final String url;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      label: label,
      onTap: () => openExternalLink(context, url),
      excludeSemantics: true,
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
        onPressed: () => openExternalLink(context, url),
        child: Text(
          label,
          style: (style ?? const TextStyle()).copyWith(
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }
}
