import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// RepoCache — clones the user's connected GitHub repo into app storage
/// (Git Trees API, recursive) so the agent can vibe-code the WHOLE project:
///
///   • listRepoTree()  → every file path (fast, 1 API call)
///   • readAll()       → load file contents into memory map
///   • write()         → local edit (pending commit)
///   • commitAll()     → push pending edits to GitHub via Contents API
///   • exportPreview() → copy web projects (html/css/js) for live preview
class RepoCache extends ChangeNotifier {
  RepoCache._();
  static final RepoCache I = RepoCache._();

  static const _api = 'https://api.github.com';
  static const _requestTimeout = Duration(seconds: 20);

  String? repoFull; // "owner/repo"
  String? _token; // from GitHubService after login
  String? defaultBranch;
  int _bindingGeneration = 0;

  /// path → content (working copy)
  final Map<String, String> files = {};
  final Set<String> _dirty = {}; // locally modified paths
  final List<String> treePaths = []; // all paths from git tree
  DateTime? lastSync;

  bool get isReady => repoFull != null && files.isNotEmpty;
  bool get hasPending => _dirty.isNotEmpty;
  int get dirtyCount => _dirty.length;

  @override
  void notifyListeners() => super.notifyListeners();

  // ── init ─────────────────────────────────────────────────────────────
  void bind(String full, String token, {String branch = 'main'}) {
    _bindingGeneration++;
    repoFull = full;
    _token = token;
    defaultBranch = branch;
  }

  /// Disconnect — clear everything so Studio shows the login state again.
  void unbind() {
    _bindingGeneration++;
    repoFull = null;
    _token = null;
    defaultBranch = null;
    files.clear();
    treePaths.clear();
    _dirty.clear();
    lastSync = null;
    notifyListeners();
  }

  // ── sync from GitHub ─────────────────────────────────────────────────
  /// Fetches the recursive git tree (single API call) then file contents.
  /// [maxFiles] keeps memory sane on huge repos.
  Future<void> sync({
    int maxFiles = 400,
    void Function(String line)? onLine,
    http.Client? client,
  }) async {
    final repo = repoFull;
    final token = _token;
    final branch = defaultBranch ?? 'main';
    final generation = _bindingGeneration;
    if (repo == null || token == null || token.isEmpty) {
      throw Exception('repo not bound');
    }

    final c = client ?? http.Client();
    try {
      onLine?.call('fetching tree of $repo …');
      final tree = await _getTree(repo, token, branch, c);
      // only text-ish files, skip vendor dirs
      const skip = <String>[
        'node_modules/',
        '.git/',
        'build/',
        '.dart_tool/',
        'dist/',
        'android/app/build/',
        'ios/Pods/',
        '.png',
        '.jpg',
        '.jpeg',
        '.gif',
        '.webp',
        '.ico',
        '.woff',
        '.woff2',
        '.ttf',
        '.zip',
        '.jar',
        '.so',
        '.apk',
        '.pdf',
        '.mp4',
        '.bin',
      ];
      final okPaths = tree
          .where((e) => e['type'] == 'blob')
          .map((e) => e['path'] as String)
          .where((p) => !skip.any((s) => p.contains(s)))
          .toList();

      final take = okPaths.length > maxFiles
          ? okPaths.sublist(0, maxFiles)
          : okPaths;
      final syncedFiles = <String, String>{};

      // fetch contents in small batches
      var done = 0;
      for (final p in take) {
        _ensureBinding(generation);
        final content = await _fetchRaw(repo, token, p, c);
        if (content != null) syncedFiles[p] = content;
        done++;
        if (done % 25 == 0) {
          onLine?.call('synced $done / ${take.length} files');
        }
      }
      _ensureBinding(generation);
      treePaths
        ..clear()
        ..addAll(take);
      files
        ..clear()
        ..addAll(syncedFiles);
      _dirty.clear();
      lastSync = DateTime.now();
      onLine?.call('repo synced ✓ ${files.length} files in memory');
      notifyListeners();
    } finally {
      if (client == null) c.close();
    }
  }

  void _ensureBinding(int generation) {
    if (generation != _bindingGeneration) {
      throw StateError('repository binding changed');
    }
  }

  Future<List<Map<String, dynamic>>> _getTree(
    String repo,
    String token,
    String branch,
    http.Client client,
  ) async {
    final res = await client
        .get(
          Uri.parse('$_api/repos/$repo/git/trees/$branch?recursive=1'),
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/vnd.github+json',
          },
        )
        .timeout(_requestTimeout);
    if (res.statusCode != 200) {
      throw Exception('tree fetch ${res.statusCode}');
    }
    final j = jsonDecode(res.body);
    return (j['tree'] as List).cast<Map<String, dynamic>>();
  }

  Future<String?> _fetchRaw(
    String repo,
    String token,
    String path,
    http.Client client,
  ) async {
    try {
      final res = await client
          .get(
            Uri.parse(
              '$_api/repos/$repo/contents/${Uri.encodeComponent(path)}',
            ),
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/vnd.github.raw',
            },
          )
          .timeout(_requestTimeout);
      if (res.statusCode != 200) return null;
      return utf8.decode(res.bodyBytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  // ── working copy ops (agent edits land here first) ───────────────────
  void write(String path, String content) {
    files[path] = content;
    _dirty.add(path);
    notifyListeners();
  }

  String? read(String path) => files[path];

  /// Public on-demand fetch for a path that exists in the repo tree but was
  /// never synced into memory (e.g. Studio file-tree tap). Returns the real
  /// file content and caches it, or null if unreachable.
  Future<String?> fetchFile(String path) async {
    if (repoFull == null) return files[path];
    try {
      final c = http.Client();
      try {
        final contents = await _fetchRaw(repoFull!, _token ?? '', path, c);
        return contents;
      } finally {
        c.close();
      }
    } catch (_) {
      return null;
    }
  }

  bool exists(String path) => files.containsKey(path);

  void create(String path, String content) {
    files[path] = content;
    _dirty.add(path);
    if (!treePaths.contains(path)) treePaths.add(path);
  }

  void remove(String path) {
    files.remove(path);
    _dirty.remove(path);
    treePaths.remove(path);
  }

  /// List files of a folder (children names) for the Studio tree UI.
  List<(String name, bool isDir)> listDir(String dir) {
    final prefix = dir.isEmpty ? '' : '$dir/';
    final seen = <String>{};
    final out = <(String, bool)>[];
    for (final p in treePaths) {
      if (!p.startsWith(prefix)) continue;
      final rest = p.substring(prefix.length);
      final seg = rest.split('/').first;
      if (seg.isEmpty || seen.contains(seg)) continue;
      seen.add(seg);
      out.add((seg, rest.contains('/')));
    }
    return out;
  }

  // ── commit pending ───────────────────────────────────────────────────
  Future<int> commitAll(String message, {http.Client? client}) async {
    final repo = repoFull;
    final token = _token;
    final generation = _bindingGeneration;
    if (repo == null || token == null || token.isEmpty) {
      throw StateError('repo not bound');
    }
    final pending = {
      for (final path in _dirty)
        if (files[path] case final String content) path: content,
    };
    final c = client ?? http.Client();
    try {
      var pushed = 0;
      for (final entry in pending.entries) {
        _ensureBinding(generation);
        final sha = await _shaOf(repo, token, entry.key, c);
        _ensureBinding(generation);
        final ok = await _putFile(
          repo,
          token,
          entry.key,
          entry.value,
          message,
          sha,
          c,
        );
        _ensureBinding(generation);
        if (ok) {
          if (files[entry.key] == entry.value) _dirty.remove(entry.key);
          pushed++;
        }
      }
      return pushed;
    } finally {
      if (client == null) c.close();
    }
  }

  Future<String?> _shaOf(
    String repo,
    String token,
    String path,
    http.Client client,
  ) async {
    try {
      final res = await client
          .get(
            Uri.parse(
              '$_api/repos/$repo/contents/${Uri.encodeComponent(path)}',
            ),
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/vnd.github+json',
            },
          )
          .timeout(_requestTimeout);
      if (res.statusCode == 200) {
        return (jsonDecode(res.body))['sha'] as String?;
      }
    } catch (_) {}
    return null;
  }

  Future<bool> _putFile(
    String repo,
    String token,
    String path,
    String content,
    String message,
    String? sha,
    http.Client client,
  ) async {
    final res = await client
        .put(
          Uri.parse('$_api/repos/$repo/contents/${Uri.encodeComponent(path)}'),
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/vnd.github+json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'message': message,
            'content': base64Encode(utf8.encode(content)),
            'sha': ?sha,
          }),
        )
        .timeout(_requestTimeout);
    return res.statusCode == 200 || res.statusCode == 201;
  }

  // ── live preview (vibe-coding) ───────────────────────────────────────
  /// Copies an index.html-based project to a preview dir for WebView.
  /// Rewrites relative refs (./style.css → style.css) so the preview works.
  Future<String?> exportPreview(String projectDir) async {
    final base = await getApplicationDocumentsDirectory();
    final prevDir = Directory('${base.path}/ovid/preview');
    if (prevDir.existsSync()) prevDir.deleteSync(recursive: true);
    prevDir.createSync(recursive: true);

    final idx = files['$projectDir/index.html'] ?? files['index.html'];
    if (idx == null) return null;

    for (final e in files.entries) {
      final name = e.key.split('/').last;
      final ext = name.contains('.') ? name.split('.').last : '';
      if (['html', 'css', 'js', 'svg', 'json'].contains(ext)) {
        File('${prevDir.path}/$name').writeAsStringSync(e.value);
      }
    }
    return '${prevDir.path}/index.html';
  }
}
