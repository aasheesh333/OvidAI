import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/native_share.dart';
import '../core/state.dart';

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
class ChatShareButton extends StatelessWidget {
  const ChatShareButton({super.key, required this.session});
  final ChatSession? session;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Share',
    icon: const Icon(Icons.share_outlined, size: 19),
    onSelected: (value) => showNativeShare(context, () async {
      if (value == 'chat') {
        final current = session;
        if (current != null) await NativeShare.transcript(current);
      } else {
        final picked = await FilePicker.platform.pickFiles();
        if (picked == null) return;
        final path = picked.files.single.path;
        if (path == null) throw StateError('No local file available');
        await NativeShare.file(path);
      }
    }),
    itemBuilder: (_) => [
      PopupMenuItem(
        value: 'chat',
        enabled: session?.messages.isNotEmpty == true,
        child: const Text('Share chat transcript'),
      ),
      const PopupMenuItem(value: 'file', child: Text('Share local file…')),
    ],
  );
}
