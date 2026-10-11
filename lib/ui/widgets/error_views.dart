import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/diag.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import 'aether_primitives.dart';

/// Collapsed "Details" disclosure for the technical side of an error, with a
/// copy button for support. Keeps raw text out of headlines: the friendly
/// message stays primary and this line only appears on request.
class ErrorDetails extends StatefulWidget {
  const ErrorDetails({super.key, required this.detail});

  final String detail;

  @override
  State<ErrorDetails> createState() => _ErrorDetailsState();
}

class _ErrorDetailsState extends State<ErrorDetails> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    if (widget.detail.isEmpty) return const SizedBox.shrink();
    final l = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          style: TextButton.styleFrom(minimumSize: const Size(48, 40)),
          icon: Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18),
          label: Text(_open ? l.errorDetailsHide : l.errorDetailsShow),
          onPressed: () => setState(() => _open = !_open),
        ),
        if (_open)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(widget.detail, style: AetherType.caption),
              ),
              IconButton(
                tooltip: l.errorDetailsCopy,
                icon: const Icon(Icons.copy_outlined, size: 18),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.maybeOf(context);
                  await Clipboard.setData(ClipboardData(text: widget.detail));
                  messenger?.showSnackBar(
                    SnackBar(content: Text(l.errorDetailsCopied)),
                  );
                },
              ),
            ],
          ),
      ],
    );
  }
}

/// Full-area error state: friendly message, optional details, Retry.
class ErrorRetryView extends StatelessWidget {
  const ErrorRetryView({
    super.key,
    required this.message,
    required this.onRetry,
    this.detail = '',
    this.icon = Icons.error_outline,
  });

  final String message;
  final String detail;
  final VoidCallback onRetry;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 32, color: Aether.dangerC),
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: AetherType.body,
                ),
              ),
              if (detail.isNotEmpty) ErrorDetails(detail: detail),
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(context.l10n.actionRetry),
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Replacement for Flutter's grey/red error box in release builds: a quiet
/// sentence instead of an empty hole or framework text. The real error is
/// recorded in [Diag] (Crashlytics already receives it via FlutterError).
class ReleaseErrorWidget extends StatelessWidget {
  const ReleaseErrorWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Text(
            context.l10n.errorWidgetFallback,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Aether.textMuted,
              fontSize: 13,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}

/// Installs [ReleaseErrorWidget] as [ErrorWidget.builder] outside debug and
/// profile builds, where Flutter's default is an unexplained grey box. Debug
/// keeps the red diagnostic screen.
void installReleaseErrorWidget({bool force = false}) {
  if (!kReleaseMode && !force) return;
  ErrorWidget.builder = (details) {
    Diag.swallow('flutter.error_widget', details.exception, details.stack);
    return const ReleaseErrorWidget();
  };
}
