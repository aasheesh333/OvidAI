import 'dart:typed_data';

// Web / unsupported platforms: there is no writable downloads directory, so
// the caller falls back to letting the browser download the URL.

void setDownloadDirectoryOverride(String? path) {}

Future<String?> saveDownloadedBytes(Uint8List bytes, String fileName) async =>
    null;

Future<Uint8List?> readLocalBytes(Uri uri) async => null;
