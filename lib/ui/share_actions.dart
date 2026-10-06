import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/native_share.dart';
import '../core/state.dart';
import '../core/theme.dart';

Future<void> showNativeShare(
  BuildContext context,
  Future<void> Function() share,
) async {
  try {
    await share();
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Could not open sharing. Please retry.',
        ),
      ),
    );
  }
}

/// One compact action exposes the current transcript and arbitrary local files.
///
/// Rendered as the Aether share pill in app bars: a soft hairline-outlined
/// icon button that opens a native-feeling popup menu with the two actions.
///
/// The widget is stateful so the transcript entry can live-track whether a
/// shareable session exists even while the popup overlay is already open:
/// when the parent swaps the [session] (e.g. navigating between chats), the
/// menu item flips between enabled and disabled without needing to be closed
/// and reopened.
class ChatShareButton extends StatefulWidget {
  const ChatShareButton({super.key, required this.session});
  final ChatSession? session;

  @override
  State<ChatShareButton> createState() => _ChatShareButtonState();
}

class _ChatShareButtonState extends State<ChatShareButton> {
  late final ValueNotifier<bool> _transcriptEnabled = ValueNotifier<bool>(
    _hasTranscript(widget.session),
  );

  static bool _hasTranscript(ChatSession? session) =>
      session != null && session.messages.isNotEmpty;

  @override
  void didUpdateWidget(ChatShareButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The popup belongs to a separate overlay route, so notifying it while
    // this parent is building would mark a non-descendant dirty during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _transcriptEnabled.value = _hasTranscript(widget.session);
    });
  }

  @override
  void dispose() {
    _transcriptEnabled.dispose();
    super.dispose();
  }

  Future<void> _handleSelection(BuildContext context, String value) =>
      showNativeShare(context, () async {
        if (value == 'chat') {
          final current = widget.session;
          if (current != null) await NativeShare.transcript(current);
        } else {
          final picked = await FilePicker.platform.pickFiles();
          if (picked == null) return;
          final path = picked.files.single.path;
          if (path == null) throw StateError('No local file available');
          await NativeShare.file(path);
        }
      });

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Share',
    icon: Icon(Icons.share_outlined, size: 19, color: Aether.textMuted),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: Aether.hairline),
    ),
    color: Aether.surface,
    position: PopupMenuPosition.under,
    onSelected: (value) => _handleSelection(context, value),
    itemBuilder: (_) => [
      _LivePopupMenuItem<String>(
        value: 'chat',
        enabledListenable: _transcriptEnabled,
        child: const _ShareMenuRow(
          icon: Icons.forum_outlined,
          label: 'Share chat transcript',
        ),
      ),
      const PopupMenuItem<String>(
        value: 'file',
        child: _ShareMenuRow(
          icon: Icons.attach_file_outlined,
          label: 'Share local file…',
        ),
      ),
    ],
  );
}

class _ShareMenuRow extends StatelessWidget {
  const _ShareMenuRow({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16, color: Aether.textMuted),
      const SizedBox(width: 10),
      Flexible(
        child: Text(
          label,
          softWrap: true,
        ),
      ),
    ],
  );
}

/// A [PopupMenuItem] whose [enabled] flag mirrors a [ValueListenable] so the
/// item can be toggled while the overlay route is still mounted.
///
/// `PopupMenuItem.enabled` is a final field captured when the route is first
/// built, so a plain rebuild of the parent widget cannot flip the entry's
/// enabled state after the menu has opened. Overriding [enabled] with a getter
/// backed by a listenable—and rebuilding the state when the listenable
/// changes—lets the entry react immediately to session updates.
class _LivePopupMenuItem<T> extends PopupMenuItem<T> {
  const _LivePopupMenuItem({
    super.key,
    super.value,
    required this.enabledListenable,
    required Widget super.child,
  }) : super(enabled: true);

  final ValueListenable<bool> enabledListenable;

  @override
  bool get enabled => enabledListenable.value;

  @override
  PopupMenuItemState<T, _LivePopupMenuItem<T>> createState() =>
      _LivePopupMenuItemState<T>();
}

class _LivePopupMenuItemState<T>
    extends PopupMenuItemState<T, _LivePopupMenuItem<T>> {
  @override
  void initState() {
    super.initState();
    widget.enabledListenable.addListener(_handleEnabledChanged);
  }

  @override
  void didUpdateWidget(_LivePopupMenuItem<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabledListenable != widget.enabledListenable) {
      oldWidget.enabledListenable.removeListener(_handleEnabledChanged);
      widget.enabledListenable.addListener(_handleEnabledChanged);
    }
  }

  @override
  void dispose() {
    widget.enabledListenable.removeListener(_handleEnabledChanged);
    super.dispose();
  }

  void _handleEnabledChanged() {
    if (!mounted) return;
    setState(() {});
  }
}
