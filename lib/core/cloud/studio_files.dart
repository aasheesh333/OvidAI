import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../state.dart';
import 'cloud_rest.dart';
import 'cloud_session_store.dart';
import '../studio_drafts.dart' show kStudioEditHardCap;

/// The Studio bucket key for the user's ONE cloud workspace.
///
/// The agent workspace is per USER (`{root}/{uid}/workspace`, shared by every
/// session — cloud/packages/storage/src/workspacePaths.ts), so Studio is not
/// bound to a chat: tabs, buffers and drafts live under this single key, and
/// switching chats never swaps the files under the editor (ST-016). Only the
/// REST path still needs a server session id, which [StudioFilesClient]
/// resolves per call (see [StudioFilesClient.anchor]).
const String kStudioWorkspaceKey = 'workspace';

/// The workspace bucket of one signed-in account. Drafts persist per bucket,
/// so scoping by account keeps one account's unsaved Studio edits from ever
/// appearing for another account on the same device.
String studioWorkspaceKeyFor(String account) => '$kStudioWorkspaceKey:$account';

/// True for [kStudioWorkspaceKey] and every [studioWorkspaceKeyFor] key.
bool isStudioWorkspaceKey(String key) =>
    key == kStudioWorkspaceKey || key.startsWith('$kStudioWorkspaceKey:');

/// P7 workspace file API — reconciled against the BUILT gateway routes
/// (`cloud/apps/gateway/src/routes/workspace.ts`) and the shared wire types
/// (`cloud/packages/shared/src/workspace.ts`), not the plan prose.
///
/// Endpoints (all under the CloudRestClient base, `/cloud/v1`):
///
///  - `GET  /sessions/:id/workspace/tree[?path=sub]`
///    → `{sessionId, state, generation, source, tree: UiManifest}`; `?path`
///      lists one folder of a warm workspace (409 `not_warm` when asleep)
///  - `GET  /sessions/:id/workspace/file?path=…`
///    → inline `{path,sizeBytes,contentType,encoding:'utf8'|'base64',content}`
///      OR redirect `{path,sizeBytes,contentType,downloadUrl,expiresAt}`
///  - `PUT  /sessions/:id/workspace/file`
///    body `{path, contentUtf8, ifMatchSha256? | ifNoneMatch?:'*'}` →
///    `{path,sizeBytes,sha256}`; 409 `baseline_mismatch` / `already_exists`
///    when the precondition fails (the server compares INSIDE its atomic
///    temp+rename write, so there is no client-side TOCTOU window — ST-007)
///  - `DELETE /sessions/:id/workspace/file?path=…[&recursive=true]`
///    → `{path, type}`; 409 `not_empty` for a folder without `recursive`
///  - `POST /sessions/:id/workspace/move {from,to}` → `{from,to}`; 409
///    `already_exists` (never clobbers)
///  - `POST /sessions/:id/workspace/mkdir {path}` → `{path, created}`
///  - `POST /sessions/:id/workspace/hydrate` → `{status:'warm'|'hydrating'}`
///
/// Every mutating route answers 202 `{status:'hydrating'}` while a cold
/// workspace warms ([StudioFileHydratingException]).

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

/// No server session exists yet to address the user's cloud workspace
/// (ST-002): the user has never sent a message, so the agent has never run
/// and the workspace has not been created. Thrown BEFORE any request — a
/// local chat id is never put on the wire.
class StudioNoWorkspaceException extends CloudApiException {
  StudioNoWorkspaceException()
      : super(
          status: 404,
          code: 'no_workspace',
          message: 'There is no cloud workspace yet.',
        );
}

/// Resolves the server session id the workspace REST calls are addressed
/// through, or null when there is none yet.
typedef StudioWorkspaceAnchor = Future<String?> Function();

class StudioFilesClient {
  StudioFilesClient(
    this.rest, {
    http.Client? httpClient,
    CloudSessionStore? sessions,
    StudioWorkspaceAnchor? anchor,
  })  : _http = httpClient ?? http.Client(),
        // ignore: prefer_initializing_formals
        _sessions = sessions,
        // ignore: prefer_initializing_formals
        _anchor = anchor;

  final CloudRestClient rest;
  final http.Client _http;

  /// The local→server id map. Null uses the process store lazily, so merely
  /// constructing a client in a test never touches SharedPreferences.
  final CloudSessionStore? _sessions;
  final StudioWorkspaceAnchor? _anchor;

  CloudSessionStore get _store => _sessions ?? CloudSessionStore.I;

  /// The server session every [kStudioWorkspaceKey] call is addressed through.
  ///
  /// The gateway's workspace routes are session-scoped (ownership is checked
  /// per session) but every session of a user resolves to the SAME per-user
  /// directory, so any live server session of the user works. Preference:
  /// the active chat's server session (the one the agent most likely just
  /// ran in), then the newest chat that has one. Null = no server session at
  /// all yet ([StudioNoWorkspaceException]).
  Future<String?> anchor() async {
    final custom = _anchor;
    if (custom != null) return custom();
    final store = _store;
    // Waits for the persisted id map only while it is still loading (an
    // already-complete `ready` future would hop zones in tests).
    await store.resolveServerSessionIdAsync(kStudioWorkspaceKey);
    final app = AppState.I;
    final active = app.activeSession?.id;
    if (active != null) {
      final id = store.knownServerIdFor(active);
      if (id != null) return id;
    }
    final byNewest = [...app.sessions]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final session in byNewest) {
      final id = store.knownServerIdFor(session.id);
      if (id != null) return id;
    }
    return null;
  }

  /// The server UUID for a Studio bucket key.
  ///
  /// [kStudioWorkspaceKey] resolves through [anchor]; any other key is a chat
  /// id that must be KNOWN to the server ([CloudSessionStore.knownServerIdFor])
  /// — an unsynced local id is refused here instead of producing a 404 for a
  /// non-UUID path (ST-002).
  Future<String> _serverSessionId(String key) async {
    final String? id;
    if (isStudioWorkspaceKey(key)) {
      id = await anchor();
    } else {
      final store = _store;
      await store.resolveServerSessionIdAsync(key);
      id = store.knownServerIdFor(key);
    }
    if (id == null) throw StudioNoWorkspaceException();
    return id;
  }

  /// GET /sessions/:id/workspace/tree — parsed into the synthetic root.
  Future<FileNode> tree(String sessionId) async =>
      (await treeSnapshot(sessionId)).root;

  /// [subPath] lists one folder of a warm workspace (ST-015); the returned
  /// root's children are that folder's entries (workspace-relative paths).
  Future<StudioTreeSnapshot> treeSnapshot(String sessionId,
      {String? subPath}) async {
    final serverId = await _serverSessionId(sessionId);
    final json = await rest.getJson(
      '/sessions/$serverId/workspace/tree',
      query: subPath == null ? null : <String, String>{'path': subPath},
    );
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
      sessionId: (json['sessionId'] as String?) ?? serverId,
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
    final serverId = await _serverSessionId(sessionId);
    return _readFile(serverId, path);
  }

  /// The resolved-id read. [serverId] is already a server UUID.
  Future<StudioFileRead> _readFile(String serverId, String path) async {
    final json = await rest.getJson(
      '/sessions/$serverId/workspace/file',
      query: <String, String>{'path': path},
    );
    final downloadUrl = json['downloadUrl'];
    final declaredSize = (json['sizeBytes'] as num?)?.toInt();
    if (downloadUrl is String && downloadUrl.isNotEmpty) {
      // A redirect response declares sizeBytes BEFORE the body is fetched.
      // Files above the edit hard cap only ever render the "too large"
      // placeholder, so do not pull megabytes (or 100 MB) off object storage
      // just to discard them.
      if (declaredSize != null && declaredSize > kStudioEditHardCap) {
        return StudioFileRead(
          path: (json['path'] as String?) ?? path,
          sizeBytes: declaredSize,
          contentType:
              (json['contentType'] as String?) ?? 'application/octet-stream',
          encoding: 'binary',
          content: '',
          sha256: '',
          redirectUrl: downloadUrl,
        );
      }
      // Presigned object-storage GET: same hung-socket risk as the gateway
      // calls, so it gets the same ceiling. The body is bounded by
      // kStudioEditHardCap (larger files never reach this branch), so the
      // default 30s is generous. A cut-off download surfaces as the client's
      // standard (0, 'timeout') shape.
      final http.Response response;
      try {
        response = await _http
            .get(Uri.parse(downloadUrl))
            .timeout(CloudRestClient.defaultTimeout);
      } on TimeoutException {
        throw CloudApiException(
          status: 0,
          code: 'timeout',
          message: 'The file download from object storage timed out.',
        );
      }
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
        sizeBytes: declaredSize ?? bytes.length,
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

  static final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

  /// PUT /sessions/:id/workspace/file.
  ///
  /// [baselineHash] is the sha256 captured when the buffer was opened (or the
  /// sha256 the previous successful PUT returned). It travels as the
  /// server-side `ifMatchSha256` precondition: the server compares it inside
  /// its atomic write and answers 409 `baseline_mismatch` (nothing written)
  /// when the file changed meanwhile — no client-side pre-read, no TOCTOU
  /// window (ST-007).
  ///
  /// [createOnly] (a brand-new file) sends `ifNoneMatch:'*'`: the server
  /// refuses with 409 `already_exists` instead of overwriting a file that
  /// exists on the server (ST-005).
  Future<StudioWriteResult> writeFile(
    String sessionId,
    String path,
    String content, {
    String? baselineHash,
    bool createOnly = false,
  }) async {
    final serverId = await _serverSessionId(sessionId);
    final baseline = baselineHash?.toLowerCase();
    final json = await rest.putJson(
      '/sessions/$serverId/workspace/file',
      body: <String, Object>{
        'path': path,
        'contentUtf8': content,
        if (baseline != null && _sha256Hex.hasMatch(baseline))
          'ifMatchSha256': baseline
        else if (createOnly)
          'ifNoneMatch': '*',
      },
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

  /// DELETE /sessions/:id/workspace/file — a file, or a folder with
  /// [recursive]. Returns the deleted node's kind (`file`/`dir`/`symlink`).
  Future<String> deletePath(String sessionId, String path,
      {bool recursive = false}) async {
    final serverId = await _serverSessionId(sessionId);
    final json = await rest.deleteJson(
      '/sessions/$serverId/workspace/file',
      query: <String, String>{
        'path': path,
        if (recursive) 'recursive': 'true',
      },
    );
    if (json['status'] == 'hydrating') throw StudioFileHydratingException();
    return (json['type'] as String?) ?? 'file';
  }

  /// POST /sessions/:id/workspace/move — never overwrites [to].
  Future<void> movePath(String sessionId, String from, String to) async {
    final serverId = await _serverSessionId(sessionId);
    final json = await rest.postJson(
      '/sessions/$serverId/workspace/move',
      body: <String, Object>{'from': from, 'to': to},
    );
    if (json['status'] == 'hydrating') throw StudioFileHydratingException();
  }

  /// POST /sessions/:id/workspace/mkdir — true when the folder was created
  /// (false: it already existed).
  Future<bool> makeDir(String sessionId, String path) async {
    final serverId = await _serverSessionId(sessionId);
    final json = await rest.postJson(
      '/sessions/$serverId/workspace/mkdir',
      body: <String, Object>{'path': path},
    );
    if (json['status'] == 'hydrating') throw StudioFileHydratingException();
    return json['created'] == true;
  }

  /// POST /sessions/:id/workspace/hydrate — wakes a cold workspace. Returns
  /// the server's status (`warm` or `hydrating`).
  Future<String> hydrate(String sessionId) async {
    final serverId = await _serverSessionId(sessionId);
    final json = await rest.postJson('/sessions/$serverId/workspace/hydrate');
    return (json['status'] as String?) ?? 'hydrating';
  }
}

/// Normalises a user-typed workspace path for Studio's create/rename dialogs:
/// trims, folds `\` to `/`, drops empty and `.` segments. Returns null for a
/// path the server would refuse (empty, absolute, `..`, control characters,
/// a trailing `/` on a file name) so the dialog can say so before any request.
String? normalizeStudioPath(String raw, {bool allowTrailingSlash = false}) {
  var text = raw.trim().replaceAll('\\', '/');
  if (text.isEmpty || text.startsWith('/')) return null;
  if (text.endsWith('/') && !allowTrailingSlash) return null;
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(text)) return null;
  final segments = <String>[];
  for (final seg in text.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') return null;
    segments.add(seg);
  }
  if (segments.isEmpty) return null;
  return segments.join('/');
}
