import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/cloud/cloud_rest.dart';
import '../core/cloud/cloud_session_store.dart';
import '../core/cloud/studio_files.dart';
import '../core/theme.dart';
import 'link_safety.dart';

/// Largest workspace image the chat will fetch and decode (SE-018).
const int kWorkspaceImageMaxBytes = 8 * 1024 * 1024;

const Set<String> _imageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp'};
const Set<String> _imageContentTypes = {
  'image/png',
  'image/jpeg',
  'image/jpg',
  'image/gif',
  'image/webp',
};

/// The bytes of one workspace file plus the content type the server declared.
class WorkspaceImageBytes {
  const WorkspaceImageBytes(this.bytes, {this.contentType});
  final Uint8List bytes;
  final String? contentType;
}

/// Fetches [path] (already normalised) from the workspace addressed through
/// [serverSessionId].
typedef WorkspaceImageLoader = Future<WorkspaceImageBytes> Function(
    String serverSessionId, String path);

/// Resolves the server session id the workspace route is addressed through
/// for the local chat [localSessionId] (null = the active chat). Null when
/// there is no server session yet.
typedef WorkspaceSessionResolver = Future<String?> Function(
    String? localSessionId);

/// Normalises a model-authored workspace-relative image path, or returns
/// null when it is unsafe: absolute, `~`, `..`, backslashes, a scheme or
/// drive letter, control characters, malformed percent-encoding, or not an
/// image extension (png/jpg/jpeg/gif/webp).
String? normalizeWorkspaceImagePath(String raw) {
  String p;
  try {
    p = Uri.decodeComponent(raw.trim());
  } catch (_) {
    return null;
  }
  if (p.isEmpty) return null;
  if (p.contains('\\') || p.contains(':')) return null;
  if (p.startsWith('/') || p.startsWith('~')) return null;
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(p)) return null;
  final segments = <String>[];
  for (final seg in p.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..' || seg.startsWith('~')) return null;
    segments.add(seg);
  }
  if (segments.isEmpty) return null;
  final leaf = segments.last;
  final dot = leaf.lastIndexOf('.');
  if (dot <= 0) return null;
  if (!_imageExtensions.contains(leaf.substring(dot + 1).toLowerCase())) {
    return null;
  }
  return segments.join('/');
}

bool _contentTypeAllowed(String? contentType) {
  final ct = contentType?.split(';').first.trim().toLowerCase() ?? '';
  if (ct.isEmpty || ct == 'application/octet-stream') return true;
  return _imageContentTypes.contains(ct);
}

/// Default resolver: the explicit chat's server id when known, otherwise the
/// Studio anchor (the active chat's server session, then the newest one —
/// the workspace is per user, so any of the user's sessions addresses it).
Future<String?> defaultWorkspaceSessionResolver(String? localSessionId) async {
  if (localSessionId != null) {
    final store = CloudSessionStore.I;
    await store.resolveServerSessionIdAsync(localSessionId);
    final id = store.knownServerIdFor(localSessionId);
    if (id != null) return id;
  }
  return StudioFilesClient(CloudRestClient.I).anchor();
}

/// Default loader: `GET /cloud/v1/sessions/:id/workspace/file?path=…`.
/// Inline base64 is decoded; a presigned `downloadUrl` (https only) is
/// streamed with a hard [kWorkspaceImageMaxBytes] cap.
Future<WorkspaceImageBytes> fetchWorkspaceImage(
  String serverSessionId,
  String path, {
  CloudRestClient? rest,
  http.Client? httpClient,
}) async {
  final json = await (rest ?? CloudRestClient.I).getJson(
    '/sessions/$serverSessionId/workspace/file',
    query: <String, String>{'path': path},
  );
  final contentType = json['contentType'] as String?;
  if (!_contentTypeAllowed(contentType)) {
    throw const FormatException('not an image');
  }
  final declared = (json['sizeBytes'] as num?)?.toInt();
  if (declared != null && declared > kWorkspaceImageMaxBytes) {
    throw const FormatException('image too large');
  }
  final downloadUrl = json['downloadUrl'];
  if (downloadUrl is String && downloadUrl.isNotEmpty) {
    final uri = Uri.parse(downloadUrl);
    if (uri.scheme != 'https') throw const FormatException('insecure url');
    final client = httpClient ?? http.Client();
    try {
      final response = await client
          .send(http.Request('GET', uri))
          .timeout(CloudRestClient.defaultTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const FormatException('download failed');
      }
      if ((response.contentLength ?? 0) > kWorkspaceImageMaxBytes) {
        throw const FormatException('image too large');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk
          in response.stream.timeout(CloudRestClient.defaultTimeout)) {
        builder.add(chunk);
        if (builder.length > kWorkspaceImageMaxBytes) {
          throw const FormatException('image too large');
        }
      }
      return WorkspaceImageBytes(builder.takeBytes(),
          contentType: contentType);
    } finally {
      if (httpClient == null) client.close();
    }
  }
  if (json['encoding'] != 'base64') {
    throw const FormatException('not binary content');
  }
  final raw = (json['content'] as String?) ?? '';
  if (raw.length ~/ 4 * 3 > kWorkspaceImageMaxBytes + 3) {
    throw const FormatException('image too large');
  }
  return WorkspaceImageBytes(base64Decode(raw), contentType: contentType);
}

/// Small in-memory LRU of decoded-ready bytes keyed by (server session, path)
/// so scrolling a long chat does not refetch. In-flight loads are shared.
class _WorkspaceImageCache {
  static const int maxEntries = 24;
  static const int maxTotalBytes = 48 * 1024 * 1024;

  final LinkedHashMap<String, Uint8List> _entries = LinkedHashMap();
  final Map<String, Future<Uint8List>> _inFlight = {};
  int _total = 0;

  Uint8List? get(String key) {
    final hit = _entries.remove(key);
    if (hit != null) _entries[key] = hit;
    return hit;
  }

  void put(String key, Uint8List bytes) {
    final old = _entries.remove(key);
    if (old != null) _total -= old.length;
    _entries[key] = bytes;
    _total += bytes.length;
    while (_entries.length > maxEntries ||
        (_total > maxTotalBytes && _entries.length > 1)) {
      final first = _entries.keys.first;
      _total -= _entries.remove(first)!.length;
    }
  }

  Future<Uint8List> load(String key, Future<Uint8List> Function() fetch) {
    final hit = get(key);
    if (hit != null) return Future.value(hit);
    return _inFlight[key] ??= () async {
      try {
        final bytes = await fetch();
        put(key, bytes);
        return bytes;
      } finally {
        _inFlight.remove(key);
      }
    }();
  }

  void clear() {
    _entries.clear();
    _inFlight.clear();
    _total = 0;
  }
}

/// An image inside the user's cloud workspace, referenced by a model answer
/// as `![](chart.png)`. Fetched through the authenticated workspace route
/// (first-party, so no tap-to-load), capped at [kWorkspaceImageMaxBytes] and
/// decoded with a `cacheWidth` cap. Failures show a calm note, never an
/// exception.
class WorkspaceImage extends StatefulWidget {
  const WorkspaceImage({
    super.key,
    required this.path,
    this.alt,
    this.sessionId,
    this.loader,
    this.resolver,
  });

  /// Workspace-relative path as written by the model (normalised here).
  final String path;
  final String? alt;

  /// Local chat id; null = the active chat.
  final String? sessionId;
  final WorkspaceImageLoader? loader;
  final WorkspaceSessionResolver? resolver;

  /// Test hooks used when a widget is built without explicit
  /// [loader]/[resolver] (e.g. through `safeMarkdownImage`).
  @visibleForTesting
  static WorkspaceImageLoader? debugLoaderOverride;
  @visibleForTesting
  static WorkspaceSessionResolver? debugResolverOverride;

  static final _WorkspaceImageCache _cache = _WorkspaceImageCache();

  /// (local chat, path) → the last resolved cache key, so a rebuilt widget
  /// (scrolled back into view) paints a cached image on its first frame.
  static final Map<String, String> _lastKey = {};

  @visibleForTesting
  static void debugClearCache() {
    _cache.clear();
    _lastKey.clear();
  }

  @override
  State<WorkspaceImage> createState() => _WorkspaceImageState();
}

class _WorkspaceImageState extends State<WorkspaceImage> {
  Future<Uint8List>? _future;
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(WorkspaceImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.sessionId != widget.sessionId) {
      _start();
    }
  }

  String get _widgetKey => '${widget.sessionId ?? ''}\u0000${widget.path}';

  void _start() {
    final known = WorkspaceImage._lastKey[_widgetKey];
    _bytes = known == null ? null : WorkspaceImage._cache.get(known);
    _future = _load();
  }

  Future<Uint8List> _load() async {
    final path = normalizeWorkspaceImagePath(widget.path);
    if (path == null) throw const FormatException('unsafe path');
    final resolver = widget.resolver ??
        WorkspaceImage.debugResolverOverride ??
        defaultWorkspaceSessionResolver;
    final loader = widget.loader ??
        WorkspaceImage.debugLoaderOverride ??
        fetchWorkspaceImage;
    final serverId = await resolver(widget.sessionId);
    if (serverId == null || serverId.isEmpty) {
      throw const FormatException('no workspace');
    }
    final key = '$serverId\u0000$path';
    if (WorkspaceImage._lastKey.length > 256) WorkspaceImage._lastKey.clear();
    WorkspaceImage._lastKey[_widgetKey] = key;
    return WorkspaceImage._cache.load(key, () async {
      final result = await loader(serverId, path);
      if (!_contentTypeAllowed(result.contentType)) {
        throw const FormatException('not an image');
      }
      if (result.bytes.isEmpty ||
          result.bytes.length > kWorkspaceImageMaxBytes) {
        throw const FormatException('bad size');
      }
      return result.bytes;
    });
  }

  Widget _failed() =>
      ImageNote(alt: widget.alt, note: 'Image could not be shown');

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      initialData: _bytes,
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes != null) {
          _bytes = bytes;
          return CappedImage(
            builder: (cacheWidth) => Image.memory(
              bytes,
              key: const ValueKey('workspace-image'),
              cacheWidth: cacheWidth,
              fit: BoxFit.contain,
              semanticLabel: widget.alt,
              errorBuilder: (_, _, _) => _failed(),
            ),
          );
        }
        if (snap.hasError) return _failed();
        return Container(
          key: const ValueKey('workspace-image-loading'),
          height: 48,
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Aether.textMuted,
            ),
          ),
        );
      },
    );
  }
}
