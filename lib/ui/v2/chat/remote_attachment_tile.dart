import 'dart:async';
import 'dart:io' show HttpException;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../core/state.dart';
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

/// Loads image bytes without cookies, authorization, or an HTML renderer.
typedef RemoteImageLoader = Future<Uint8List> Function(String url);

const int _maxRemoteImageBytes = 8 * 1024 * 1024;
const int _maxImageDimension = 4096;
const int _maxImagePixels = 16 * 1024 * 1024;

Future<Uint8List> _loadRemoteImage(String url) =>
    loadBoundedRemoteImage(url, maxBytes: _maxRemoteImageBytes);

/// Streams an image with limits applied before a whole response can buffer.
/// No cookies or authorization are attached; the URL is the only capability.
Future<Uint8List> loadBoundedRemoteImage(
  String url, {
  http.Client? client,
  int maxBytes = _maxRemoteImageBytes,
}) async {
  if (maxBytes <= 0 || maxBytes > _maxRemoteImageBytes) {
    throw const FormatException('Invalid image byte limit');
  }
  final uri = Uri.tryParse(url.trim());
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty) {
    throw const FormatException('Unsupported image URL');
  }
  final owned = client == null;
  final httpClient = client ?? http.Client();
  try {
    final request = http.Request('GET', uri);
    final response = await httpClient
        .send(request)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Image returned ${response.statusCode}');
    }
    final type = response.headers['content-type']?.toLowerCase() ?? '';
    if (type.contains('svg') ||
        type.contains('text/html') ||
        type.contains('xml')) {
      throw const FormatException('Active image content');
    }
    final declared = response.contentLength;
    if (declared != null && declared > maxBytes) {
      throw const FormatException('Image is too large');
    }

    final iterator = StreamIterator<List<int>>(response.stream);
    final bytes = BytesBuilder(copy: false);
    var total = 0;
    try {
      while (await iterator.moveNext()) {
        final chunk = iterator.current;
        if (chunk.length > maxBytes - total) {
          throw const FormatException('Image is too large');
        }
        bytes.add(chunk);
        total += chunk.length;
      }
    } finally {
      await iterator.cancel();
    }
    return bytes.takeBytes();
  } finally {
    if (owned) httpClient.close();
  }
}

/// Reads intrinsic dimensions without accepting a full-resolution frame.
/// PNG, JPEG, GIF and WebP are supported; SVG/HTML/XML never enters decoding.
void _validateIntrinsicImageDimensions(Uint8List bytes) {
  final dimensions = _intrinsicImageDimensions(bytes);
  if (dimensions == null) {
    throw const FormatException('Unsupported or malformed image');
  }
  final (width, height) = dimensions;
  if (width <= 0 ||
      height <= 0 ||
      width > _maxImageDimension ||
      height > _maxImageDimension ||
      width * height > _maxImagePixels) {
    throw const FormatException('Image dimensions are too large');
  }
}

(int, int)? _intrinsicImageDimensions(Uint8List bytes) {
  if (bytes.length >= 24 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x0a &&
      bytes[6] == 0x1a &&
      bytes[7] == 0x0a &&
      bytes[12] == 0x49 &&
      bytes[13] == 0x48 &&
      bytes[14] == 0x44 &&
      bytes[15] == 0x52) {
    final data = ByteData.sublistView(bytes);
    return (data.getUint32(16), data.getUint32(20));
  }
  if (bytes.length >= 10 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38 &&
      (bytes[4] == 0x37 || bytes[4] == 0x39) &&
      bytes[5] == 0x61) {
    return (bytes[6] | (bytes[7] << 8), bytes[8] | (bytes[9] << 8));
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return _webpDimensions(bytes);
  }
  if (bytes.length >= 4 && bytes[0] == 0xff && bytes[1] == 0xd8) {
    return _jpegDimensions(bytes);
  }
  return null;
}

(int, int)? _jpegDimensions(Uint8List bytes) {
  const startOfFrame = <int>{
    0xc0,
    0xc1,
    0xc2,
    0xc3,
    0xc5,
    0xc6,
    0xc7,
    0xc9,
    0xca,
    0xcb,
    0xcd,
    0xce,
    0xcf,
  };
  var offset = 2;
  while (offset + 4 <= bytes.length) {
    if (bytes[offset] != 0xff) {
      offset++;
      continue;
    }
    while (offset < bytes.length && bytes[offset] == 0xff) {
      offset++;
    }
    if (offset >= bytes.length) break;
    final marker = bytes[offset++];
    if (marker == 0xd8 ||
        marker == 0xd9 ||
        marker == 0x01 ||
        (marker >= 0xd0 && marker <= 0xd7)) {
      continue;
    }
    if (offset + 2 > bytes.length) break;
    final length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) break;
    if (startOfFrame.contains(marker)) {
      if (length < 7) break;
      final height = (bytes[offset + 3] << 8) | bytes[offset + 4];
      final width = (bytes[offset + 5] << 8) | bytes[offset + 6];
      return (width, height);
    }
    offset += length;
  }
  return null;
}

(int, int)? _webpDimensions(Uint8List bytes) {
  if (bytes.length < 30) return null;
  final data = ByteData.sublistView(bytes);
  final riffBytes = data.getUint32(4, Endian.little) + 8;
  if (riffBytes > bytes.length) return null;
  final chunkBytes = data.getUint32(16, Endian.little);
  final chunkEnd = 20 + chunkBytes;
  if (chunkEnd > bytes.length || chunkEnd > riffBytes) return null;
  final format = String.fromCharCodes(bytes.sublist(12, 16));
  if (format == 'VP8X') {
    if (chunkBytes < 10) return null;
    // VP8X stores canvas-width-minus-one at 24..26 and height-minus-one
    // at 27..29, each as an unsigned little-endian 24-bit integer.
    final width = 1 + bytes[24] + (bytes[25] << 8) + (bytes[26] << 16);
    final height = 1 + bytes[27] + (bytes[28] << 8) + (bytes[29] << 16);
    return (width, height);
  }
  if (format == 'VP8 ' &&
      bytes.length >= 30 &&
      bytes[23] == 0x9d &&
      bytes[24] == 0x01 &&
      bytes[25] == 0x2a) {
    return (
      (bytes[26] | (bytes[27] << 8)) & 0x3fff,
      (bytes[28] | (bytes[29] << 8)) & 0x3fff,
    );
  }
  if (format == 'VP8L' && bytes.length >= 25 && bytes[20] == 0x2f) {
    final bits =
        bytes[21] | (bytes[22] << 8) | (bytes[23] << 16) | (bytes[24] << 24);
    return (1 + (bits & 0x3fff), 1 + ((bits >> 14) & 0x3fff));
  }
  return null;
}

/// A remote/generated image with real loading, error and decoded-pixel states.
/// SVG never reaches this widget: model SVG uses the static native sanitizer.
class RemoteTranscriptImage extends StatefulWidget {
  const RemoteTranscriptImage({
    super.key,
    required this.url,
    required this.alt,
    this.loader,
  });

  final String url;
  final String alt;
  final RemoteImageLoader? loader;

  @override
  State<RemoteTranscriptImage> createState() => _RemoteTranscriptImageState();
}

class _RemoteTranscriptImageState extends State<RemoteTranscriptImage> {
  late Future<Uint8List> _future;

  Future<Uint8List> _load() async {
    final bytes = await (widget.loader ?? _loadRemoteImage)(widget.url);
    _validateIntrinsicImageDimensions(bytes);
    return bytes;
  }

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(RemoteTranscriptImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.loader != widget.loader) {
      _future = _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _RemoteImageLoading();
        }
        final bytes = snapshot.data;
        if (snapshot.hasError || bytes == null) {
          return _RemoteImageError(alt: widget.alt);
        }
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: Image.memory(
            bytes,
            cacheWidth: _maxImageDimension,
            fit: BoxFit.contain,
            semanticLabel: widget.alt.isEmpty ? 'Image' : widget.alt,
            errorBuilder: (_, _, _) => _RemoteImageError(alt: widget.alt),
          ),
        );
      },
    );
  }
}

class _RemoteImageLoading extends StatelessWidget {
  const _RemoteImageLoading();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 96),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: OSpace.s),
        child: Center(
          child: Text(
            'Loading image…',
            style: OType.bodyMd.copyWith(color: c.textMuted),
          ),
        ),
      ),
    );
  }
}

class _RemoteImageError extends StatelessWidget {
  const _RemoteImageError({required this.alt});

  final String alt;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      label: alt.isEmpty ? 'Image unavailable' : '$alt unavailable',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 88),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: OSpace.m,
            vertical: OSpace.s,
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.broken_image_outlined, color: c.textMuted),
                const SizedBox(height: OSpace.xs),
                Text(
                  'Image unavailable',
                  textAlign: TextAlign.center,
                  style: OType.bodyMd.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum RemoteAttachmentState { loading, ready, error }

/// A transcript attachment's actual upload/availability state. Controls exist
/// only for a ready attachment with a real host handler.
class RemoteAttachmentTile extends StatelessWidget {
  const RemoteAttachmentTile({
    super.key,
    required this.attachment,
    required this.state,
    this.onOpen,
    this.onDownload,
  });

  final MessageAttachment attachment;
  final RemoteAttachmentState state;
  final VoidCallback? onOpen;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final ready = state == RemoteAttachmentState.ready;
    final subtitle = switch (state) {
      RemoteAttachmentState.loading => 'Uploading…',
      RemoteAttachmentState.error => 'Attachment unavailable',
      RemoteAttachmentState.ready => _sizeLabel(attachment.size),
    };
    return Semantics(
      container: true,
      explicitChildNodes: true,
      button: ready && onOpen != null,
      enabled: ready && onOpen != null,
      onTap: ready ? onOpen : null,
      label: ready && onOpen != null
          ? 'Open ${attachment.name}'
          : '${attachment.name}. $subtitle',
      child: Container(
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(ORadius.m),
          border: Border.all(color: c.hairline),
        ),
        child: OPressable(
          onTap: ready ? onOpen : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: OSpace.m,
              vertical: OSpace.s,
            ),
            child: Row(
              children: [
                Icon(
                  switch (state) {
                    RemoteAttachmentState.loading =>
                      Icons.cloud_upload_outlined,
                    RemoteAttachmentState.ready =>
                      Icons.insert_drive_file_outlined,
                    RemoteAttachmentState.error => Icons.error_outline_rounded,
                  },
                  size: 20,
                  color: state == RemoteAttachmentState.error
                      ? c.danger
                      : c.textMuted,
                ),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        attachment.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: OType.bodyMdStrong.copyWith(color: c.text),
                      ),
                      Text(
                        subtitle,
                        style: OType.caption.copyWith(
                          color: state == RemoteAttachmentState.error
                              ? c.danger
                              : c.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (ready && onDownload != null)
                  OIconButton(
                    icon: Icons.download_rounded,
                    semanticLabel: 'Download ${attachment.name}',
                    onPressed: onDownload,
                    size: 18,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _sizeLabel(int bytes) {
  if (bytes <= 0) return 'Size —';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
