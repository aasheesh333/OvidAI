import 'package:flutter/services.dart';

import 'state.dart';

/// Android owns file staging, MIME detection and temporary content URI grants.
class NativeShare {
  static const _channel = MethodChannel('ovid/native');

  static Future<void> _send(String method, Map<String, String> payload) async {
    if (await _channel.invokeMethod<bool>(method, payload) != true) {
      throw PlatformException(
        code: 'SHARE_FAILED',
        message: 'The share sheet could not be opened.',
      );
    }
  }

  static Future<void> app() => _send('shareText', {
    'text': 'Ovid — AI chat, agents & tools\nhttps://dhanuk.page.gd/ovid',
    'title': 'Share Ovid',
  });

  static Future<void> file(String path) =>
      _send('shareFile', {'filePath': path, 'title': 'Share file'});

  static Future<void> transcript(ChatSession session) =>
      _send('shareTranscript', {
        'text': transcriptText(session),
        'fileName': 'ovid-chat.txt',
        'title': 'Share chat transcript',
      });

  static String transcriptText(ChatSession session) {
    final out = StringBuffer(session.title);
    for (final m in session.messages) {
      final label = m.kind == MsgKind.tool
          ? 'Tool: ${m.toolTitle ?? m.toolName ?? 'tool'}'
          : m.role == 'user'
          ? 'You:'
          : 'Ovid:';
      out.write('\n\n$label\n');
      out.write(m.kind == MsgKind.tool ? m.toolDetail ?? m.content : m.content);
      for (final attachment in m.attachments) {
        out.write('\nAttachment: ${attachment.name}');
      }
      if (m.imagePath != null) {
        out.write('\nImage: ${m.imagePath!.split('/').last}');
      }
    }
    out.writeln();
    return out.toString();
  }
}
