import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

// Mobile and desktop: downloads are written to a real `Ovid` folder inside the
// platform downloads directory (or app documents when downloads is absent).

String? _overrideDirectory;

/// Test seam. Point downloads at a temporary directory so a widget test can
/// assert the file really exists.
void setDownloadDirectoryOverride(String? path) => _overrideDirectory = path;

Future<String?> saveDownloadedBytes(Uint8List bytes, String fileName) async {
  try {
    final Directory base;
    if (_overrideDirectory != null) {
      base = Directory(_overrideDirectory!);
    } else if (Platform.isAndroid || Platform.isIOS) {
      // Mobile has no shared Downloads folder we may write to without the
      // storage permission; the app documents folder is a real, durable file.
      base = await getApplicationDocumentsDirectory();
    } else {
      base =
          await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
    }
    final folder = Directory('${base.path}${Platform.pathSeparator}Ovid');
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    final file = await _uniqueFile(folder, fileName);
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> readLocalBytes(Uri uri) async {
  try {
    final file = uri.scheme == 'file' ? File.fromUri(uri) : File(uri.toFilePath());
    if (!await file.exists()) return null;
    return await file.readAsBytes();
  } catch (_) {
    return null;
  }
}

Future<File> _uniqueFile(Directory folder, String name) async {
  final separator = Platform.pathSeparator;
  var candidate = File('${folder.path}$separator$name');
  if (!await candidate.exists()) return candidate;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final extension = dot > 0 ? name.substring(dot) : '';
  for (var i = 2; i < 1000; i++) {
    candidate = File('${folder.path}$separator$stem-$i$extension');
    if (!await candidate.exists()) return candidate;
  }
  return candidate;
}
