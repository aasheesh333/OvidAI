import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'download_file_saver_stub.dart'
    if (dart.library.io) 'download_file_saver_io.dart' as saver;

/// Real link handling for transcript blocks.
///
/// The chat renderers stay presentational: a host may inject its own
/// [V2MessageBlocks.onOpenLink] / [V2MessageBlocks.onDownload]. When it does
/// not, these defaults do the real work (open in the browser, fetch and save a
/// file) instead of leaving a visible control dead.
class V2TranscriptIo {
  const V2TranscriptIo._();

  /// Test seam for [v2OpenTranscriptLink]. Returns whether a handler opened it.
  @visibleForTesting
  static Future<bool> Function(Uri uri)? debugOpenOverride;

  @visibleForTesting
  static void reset() {
    debugOpenOverride = null;
    saver.setDownloadDirectoryOverride(null);
  }

  @visibleForTesting
  static void setDownloadDirectoryOverride(String? path) =>
      saver.setDownloadDirectoryOverride(path);
}

/// Only these schemes are ever opened or saved. Anything else (for example
/// `javascript:`) is rejected before it reaches the platform.
Uri? v2TranscriptLinkUri(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final uri = Uri.tryParse(text);
  if (uri == null || uri.scheme.isEmpty) return null;
  return switch (uri.scheme.toLowerCase()) {
    'http' || 'https' || 'file' => uri,
    _ => null,
  };
}

/// File name used for a download, in priority order: an explicit name with an
/// extension, the last path segment of the URL, then the label, then
/// `download`.
String v2DownloadFileName(String href, {String? suggestedName}) {
  final suggested = _cleanFileName(suggestedName);
  if (suggested != null && suggested.contains('.')) return suggested;

  final uri = Uri.tryParse(href.trim());
  String? fromUrl;
  if (uri != null && uri.pathSegments.isNotEmpty) {
    try {
      fromUrl = Uri.decodeComponent(uri.pathSegments.last);
    } on ArgumentError {
      fromUrl = uri.pathSegments.last;
    }
  }
  final cleanedUrl = _cleanFileName(fromUrl);
  if (cleanedUrl != null && cleanedUrl.contains('.')) return cleanedUrl;
  if (suggested != null) return suggested;
  if (cleanedUrl != null) return cleanedUrl;
  return 'download';
}

String? _cleanFileName(String? raw) {
  if (raw == null) return null;
  var name = raw.trim().replaceAll(
    RegExp(r'[\u0000-\u001f<>:"/\\|?*]'),
    '_',
  );
  name = name.replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
  if (name.isEmpty) return null;
  if (name.length > 120) name = name.substring(0, 120);
  return name;
}

/// Writes [bytes] to the platform downloads folder. Null when the platform has
/// no writable folder (web) or the write failed.
@visibleForTesting
Future<String?> v2SaveTranscriptBytes(Uint8List bytes, String fileName) =>
    saver.saveDownloadedBytes(bytes, fileName);

Future<bool> _launch(Uri uri) async {
  final override = V2TranscriptIo.debugOpenOverride;
  if (override != null) return override(uri);
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

void _notify(BuildContext context, String message) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Open a transcript link in the platform browser (or the host override).
Future<bool> v2OpenTranscriptLink(BuildContext context, String href) async {
  final uri = v2TranscriptLinkUri(href);
  if (uri == null) {
    _notify(context, 'This link cannot be opened.');
    return false;
  }
  final opened = await _launch(uri);
  if (!context.mounted) return opened;
  if (!opened) _notify(context, 'Could not open this link. Try again.');
  return opened;
}

/// Fetch [href] and write it to a real file, then confirm with the saved name.
///
/// Web has no writable downloads folder, so the browser downloads the URL
/// instead and the confirmation says so.
Future<bool> v2SaveTranscriptLink(
  BuildContext context,
  String href, {
  String? suggestedName,
}) async {
  final uri = v2TranscriptLinkUri(href);
  final name = v2DownloadFileName(href, suggestedName: suggestedName);
  if (uri == null) {
    _notify(context, 'This file cannot be downloaded.');
    return false;
  }

  if (kIsWeb) {
    final started = await _launch(uri);
    if (!context.mounted) return started;
    _notify(
      context,
      started
          ? 'Download started in your browser.'
          : 'Could not download $name. Try again.',
    );
    return started;
  }

  Uint8List? bytes;
  if (uri.scheme == 'file') {
    bytes = await saver.readLocalBytes(uri);
  } else {
    try {
      final response = await http
          .get(uri)
          .timeout(const Duration(seconds: 45));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        bytes = response.bodyBytes;
      }
    } catch (_) {
      bytes = null;
    }
  }

  if (bytes == null) {
    if (!context.mounted) return false;
    _notify(context, 'Could not download $name. Try again.');
    return false;
  }

  final path = await saver.saveDownloadedBytes(bytes, name);
  if (!context.mounted) return path != null;
  if (path == null) {
    _notify(context, 'Could not save $name. Check your storage space.');
    return false;
  }
  _notify(context, 'Saved $name');
  return true;
}
