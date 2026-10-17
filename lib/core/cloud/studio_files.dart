import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'cloud_rest.dart';

/// P7 workspace file API — reconciled against the BUILT gateway routes
/// (`cloud/apps/gateway/src/routes/workspace.ts`) and the shared wire types
/// (`cloud/packages/shared/src/workspace.ts`), not the plan prose.
///
/// Endpoints (all under the CloudRestClient base, `/cloud/v1`):
///
///  - `GET  /sessions/:id/workspace/tree`
///    → `{sessionId, state, generation, source, tree: UiManifest}`
///  - `GET  /sessions/:id/workspace/file?path=…`
///    → inline `{path,sizeBytes,contentType,encoding:'utf8'|'base64',content}`
///      OR redirect `{path,sizeBytes,contentType,downloadUrl,expiresAt}`
///  - `PUT  /sessions/:id/workspace/file`
///    body `{path, contentUtf8}` → `{path,sizeBytes,sha256}` (202
///    `{status:'hydrating'}` while a cold workspace warms).
///
/// The server has NO If-Match/baseline field (the PUT body schema is strict),
/// so the baseline contract is enforced client-side: [writeFile] re-reads the
/// file and compares its sha256 with the caller's baseline before the PUT.
/// A mismatch — or a genuine server 409 — surfaces as a
/// [CloudApiException] with `code == 'baseline_mismatch'`, which the Studio
/// client routes into the editor's conflict-resolution path.

/// One node of the server's manifest tree.
///
/// `kind` mirrors the built wire enum (`dir` | `file` | `symlink`). The brief
/// said `'file'|'dir'`; the server also emits `symlink`, and following the
/// built code wins (documented in the task report).
class FileNode {
  const FileNode({
    required this.name,
    required this.path,
    required this.kind,
    this.size,
    this.mtime,
    this.children = const <FileNode>[],
    this.omitted = 0,
    this.files,
    this.bytes,
    this.dirs,
  });

  final String name;
  final String path;
  final String kind;
  final int? size;
  final DateTime? mtime;
  final List<FileNode> children;

  /// Siblings dropped from [children] to stay inside the <5 KB manifest.
  final int omitted;

  /// Directory rollups present on pruned dirs.
  final int? files;
  final int? bytes;
  final int? dirs;

  bool get isDir => kind == 'dir';
  bool get isSymlink => kind == 'symlink';

  factory FileNode.fromJson(Map<String, dynamic> json) {
    final rawChildren = json['children'];
    return FileNode(
      name: (json['name'] as String?) ?? _leafOf(json['path'] as String? ?? ''),
      path: (json['path'] as String?) ?? '',
      kind: (json['type'] as String?) ?? 'file',
      size: (json['sizeBytes'] as num?)?.toInt(),
      mtime: _parseMtime(json['mtime']),
      omitted: (json['omitted'] as num?)?.toInt() ?? 0,
      files: (json['files'] as num?)?.toInt(),
      bytes: (json['bytes'] as num?)?.toInt(),
      dirs: (json['dirs'] as num?)?.toInt(),
      children: rawChildren is List
          ? [
              for (final child in rawChildren)
                if (child is Map)
                  FileNode.fromJson(Map<String, dynamic>.from(child)),
            ]
          : const <FileNode>[],
    );
  }

  static DateTime? _parseMtime(Object? raw) =>
      raw is String && raw.isNotEmpty ? DateTime.tryParse(raw) : null;

  static String _leafOf(String path) =>
      path.isEmpty ? path : path.substring(path.lastIndexOf('/') + 1);
}

/// One tree response: the synthetic root plus the workspace state the server
/// reported (`warm`/`hydrating`/`cold`/`hibernating`).
class StudioTreeSnapshot {
  const StudioTreeSnapshot({
    required this.sessionId,
    required this.state,
    required this.generation,
    required this.source,
    required this.truncated,
    required this.root,
    required this.fileCount,
    required this.dirCount,
    required this.totalBytes,
  });

  final String sessionId;
  final String state;
  final int generation;
  final String source;
  final bool truncated;
  final FileNode root;
  final int fileCount;
  final int dirCount;
  final int totalBytes;

  bool get hydrating => state == 'hydrating';
}

/// One decoded file read.
class StudioFileRead {
  const StudioFileRead({
    required this.path,
    required this.sizeBytes,
    required this.contentType,
    required this.encoding,
    required this.content,
    required this.sha256,
    this.redirectUrl,
  });

  final String path;
  final int sizeBytes;
  final String contentType;

  /// `utf8`, `base64` or `binary` (a presigned redirect fetched directly).
  final String encoding;
  final String content;

  /// sha256 of the DECODED bytes — the baseline token this client hands back
  /// to [StudioFilesClient.writeFile].
  final String sha256;

  final String? redirectUrl;
}

/// The PUT answer (`{path,sizeBytes,sha256}`).
class StudioWriteResult {
  const StudioWriteResult({
    required this.path,
    required this.sizeBytes,
    required this.sha256,
  });

  final String path;
  final int sizeBytes;
  final String sha256;
}

/// A cold workspace is still hydrating; the PUT was accepted (202) but no
/// bytes landed yet. Callers should retry after the `workspace_hydrated`
/// event (or a short backoff).
class StudioFileHydratingException extends CloudApiException {
  StudioFileHydratingException()
      : super(
          status: 202,
          code: 'hydrating',
          message: 'The workspace is hydrating; retry when it is warm.',
        );
}

class StudioFilesClient {
  StudioFilesClient(this.rest, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final CloudRestClient rest;
  final http.Client _http;

  /// GET /sessions/:id/workspace/tree — parsed into the synthetic root.
  Future<FileNode> tree(String sessionId) async =>
      (await treeSnapshot(sessionId)).root;

  Future<StudioTreeSnapshot> treeSnapshot(String sessionId) async {
    final json = await rest.getJson('/sessions/$sessionId/workspace/tree');
    final tree = json['tree'];
    if (tree is! Map) {
      throw CloudApiException(
        status: 500,
        code: 'internal',
        message: 'The workspace tree response was malformed.',
      );
    }
    final manifest = Map<String, dynamic>.from(tree);
    final roots = manifest['roots'];
    final nodes = <FileNode>[
      if (roots is List)
        for (final raw in roots)
          if (raw is Map) FileNode.fromJson(Map<String, dynamic>.from(raw)),
    ];
    final totals = manifest['totals'];
    return StudioTreeSnapshot(
      sessionId: (json['sessionId'] as String?) ?? sessionId,
      state: (json['state'] as String?) ?? 'warm',
      generation: (json['generation'] as num?)?.toInt() ?? 0,
      source: (json['source'] as String?) ?? 'live',
      truncated: manifest['truncated'] == true,
      root: FileNode(
        name: '',
        path: '',
        kind: 'dir',
        children: nodes,
        files: totals is Map ? (totals['files'] as num?)?.toInt() : null,
        dirs: totals is Map ? (totals['dirs'] as num?)?.toInt() : null,
        bytes: totals is Map ? (totals['bytes'] as num?)?.toInt() : null,
      ),
      fileCount: totals is Map ? (totals['files'] as num?)?.toInt() ?? 0 : 0,
      dirCount: totals is Map ? (totals['dirs'] as num?)?.toInt() ?? 0 : 0,
      totalBytes:
          totals is Map ? (totals['bytes'] as num?)?.toInt() ?? 0 : 0,
    );
  }

  /// GET /sessions/:id/workspace/file?path=… — inline or presigned redirect.
  Future<String> readFile(String sessionId, String path) async =>
      (await readFileDetailed(sessionId, path)).content;

  Future<StudioFileRead> readFileDetailed(
      String sessionId, String path) async {
    final json = await rest.getJson(
      '/sessions/$sessionId/workspace/file',
      query: <String, String>{'path': path},
    );
    final downloadUrl = json['downloadUrl'];
    if (downloadUrl is String && downloadUrl.isNotEmpty) {
      final response = await _http.get(Uri.parse(downloadUrl));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CloudApiException(
          status: response.statusCode,
          code: 'internal',
          message: 'The file download from object storage failed.',
        );
      }
      final bytes = response.bodyBytes;
      return StudioFileRead(
        path: (json['path'] as String?) ?? path,
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? bytes.length,
        contentType: (json['contentType'] as String?) ?? 'application/octet-stream',
        encoding: 'binary',
        content: utf8.decode(bytes, allowMalformed: true),
        sha256: sha256.convert(bytes).toString(),
        redirectUrl: downloadUrl,
      );
    }

    final encoding = (json['encoding'] as String?) ?? 'utf8';
    final raw = (json['content'] as String?) ?? '';
    final List<int> bytes;
    if (encoding == 'base64') {
      bytes = base64Decode(raw);
    } else {
      bytes = utf8.encode(raw);
    }
    return StudioFileRead(
      path: (json['path'] as String?) ?? path,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? bytes.length,
      contentType: (json['contentType'] as String?) ?? 'text/plain',
      encoding: encoding,
      content: encoding == 'base64'
          ? utf8.decode(bytes, allowMalformed: true)
          : raw,
      sha256: sha256.convert(bytes).toString(),
    );
  }

  /// PUT /sessions/:id/workspace/file.
  ///
  /// [baselineHash] is the sha256 captured when the buffer was opened (or the
  /// sha256 the previous successful PUT returned). When supplied, the current
  /// remote bytes are re-read and compared first; a mismatch throws a 409
  /// `baseline_mismatch` WITHOUT writing. A genuine server 409 is mapped the
  /// same way.
  Future<StudioWriteResult> writeFile(
    String sessionId,
    String path,
    String content, {
    String? baselineHash,
  }) async {
    if (baselineHash != null) {
      StudioFileRead? current;
      try {
        current = await readFileDetailed(sessionId, path);
      } on CloudApiException catch (error) {
        // A file that does not exist yet has no baseline to conflict with.
        if (error.status != 404) rethrow;
      }
      if (current != null && current.sha256 != baselineHash) {
        throw CloudApiException(
          status: 409,
          code: 'baseline_mismatch',
          message: 'The file changed on the server since it was opened.',
        );
      }
    }

    final json = await rest.putJson(
      '/sessions/$sessionId/workspace/file',
      body: <String, Object>{'path': path, 'contentUtf8': content},
    );
    if (json['status'] == 'hydrating') {
      throw StudioFileHydratingException();
    }
    final sha = json['sha256'];
    if (sha is! String || sha.isEmpty) {
      throw CloudApiException(
        status: 500,
        code: 'internal',
        message: 'The workspace write response was malformed.',
      );
    }
    return StudioWriteResult(
      path: (json['path'] as String?) ?? path,
      sizeBytes:
          (json['sizeBytes'] as num?)?.toInt() ?? utf8.encode(content).length,
      sha256: sha,
    );
  }
}
