import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'image_studio.dart';
import 'state.dart';

/// Where a recovered (paid) image was kept.
class RecoveredImage {
  const RecoveredImage(this.file, {this.sessionId});
  final File file;

  /// Chat the image was attached to, when that chat still exists.
  final String? sessionId;
}

/// Keeps images recovered from Image receipts (F-206): writes the bytes to
/// app-private storage (so Save/Share work and nothing vanishes on back) and
/// attaches them to the originating chat as an image message, once.
class RecoveredImages {
  const RecoveredImages._();

  @visibleForTesting
  static Future<Directory> Function()? directoryForTest;

  static Future<Directory> _root() async =>
      await directoryForTest?.call() ??
      Directory(
        '${(await getApplicationSupportDirectory()).path}/recovered-images',
      );

  static Future<RecoveredImage> persist(
    ImageRequestRecord record,
    Uint8List bytes, {
    AppState? app,
  }) async {
    final state = app ?? AppState.I;
    final info = await ImageStudio.inspect(bytes);
    final extension = switch (info.mime) {
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      _ => 'png',
    };
    final root = await _root();
    await root.create(recursive: true);
    // Request IDs are validated [A-Za-z0-9_.:-]{8,128}: path-safe, and one
    // file per request so repeated recovery never duplicates.
    final file = File('${root.path}/${record.requestId}.$extension');
    await file.writeAsBytes(bytes, flush: true);
    final session = state.sessionById(record.sessionId);
    if (session == null) return RecoveredImage(file);
    if (!session.messages.any((m) => m.imagePath == file.path)) {
      session.messages.add(
        Message(
          role: 'assistant',
          kind: MsgKind.imageGen,
          content: 'Recovered image',
          imagePath: file.path,
        ),
      );
      state.refresh();
      await state.persistSessions();
    }
    return RecoveredImage(file, sessionId: session.id);
  }
}
