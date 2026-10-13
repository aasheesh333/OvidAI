import 'dart:io';

import 'diag.dart';
import 'image_receipt_store.dart';
import 'recovered_images.dart';
import 'state.dart';

/// Finds the image a receipt produced, when it is still on this device.
///
/// The receipt journal deliberately stores no paths, so the result is looked
/// up where the app actually saved it:
///  1. the chat image row tagged with the request id (images generated since
///     this fix, and recovered images);
///  2. the receipts screen's own kept copy (`recovered-images/<id>.*`);
///  3. legacy chats: the generate/edit tool card whose result text names the
///     request (`Request \`id\`: … Image saved: \`path\``).
/// Only existing files are returned; a deleted file means "not on device".
class ImageResultLocator {
  const ImageResultLocator._();

  static Future<File?> find(ImageRequestRecord record, {AppState? app}) async {
    if (record.state == 'failed') return null;
    try {
      final state = app ?? AppState.I;
      final id = record.requestId;
      final preferred = state.sessionById(record.sessionId);
      final sessions = [
        ?preferred,
        for (final s in state.sessions)
          if (!identical(s, preferred)) s,
      ];
      for (final session in sessions) {
        for (final m in session.messages) {
          final path = m.imagePath;
          if (m.imageRequestId == id && path != null) {
            final file = File(path);
            if (await file.exists()) return file;
          }
        }
      }
      try {
        final kept = await RecoveredImages.existing(id);
        if (kept != null) return kept;
      } catch (e) {
        // No app-support directory (tests / unsupported platform).
        Diag.swallow('image_result.recovered', e);
      }
      final legacy = RegExp(
        'Request `${RegExp.escape(id)}`[\\s\\S]*?Image saved: `([^`]+)`',
      );
      for (final session in sessions) {
        for (final m in session.messages) {
          final detail = m.toolDetail;
          if (detail == null || !detail.contains(id)) continue;
          final path = legacy.firstMatch(detail)?.group(1);
          if (path == null) continue;
          final file = File(path);
          if (await file.exists()) return file;
        }
      }
    } catch (e) {
      Diag.swallow('image_result.locate', e);
    }
    return null;
  }
}
