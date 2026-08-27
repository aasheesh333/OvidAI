import 'dart:convert';
import 'dart:io';
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
class RepoCache {
  RepoCache._();
  static final RepoCache I = RepoCache._();

  static const _api = 'https://api.github.com';

  String? repoFull;          // "owner/repo"
  String? _token;            // from GitHubService after login
  String? defaultBranch;

  /// path → content (working copy)
  final Map<String, String> files = {};
  final Set<String> _dirty = {};      // locally modified paths
  final List<String> treePaths = [];  // all paths from git tree
  DateTime? lastSync;

  bool get isReady => repoFull != null && files.isNotEmpty;
  bool get hasPending => _dirty.isNotEmpty;
  int get dirtyCount => _dirty.length;

  // ── init ─────────────────────────────────────────────────────────────
  void bind(String full, String token, {String branch = 'main'}) {
    repoFull = full;
    _token = token;
    defaultBranch = branch;
  }

  // ── sync from GitHub ─────────────────────────────────────────────────
  /// Fetches the recursive git tree (single API call) then file contents.
  /// [maxFiles] keeps memory sane on huge repos.
  Future<void> sync({
    int maxFiles = 400,
    void Function(String line)? onLine,
  }) async {
    if (repoFull == null || _token == null) {
      throw Exception('repo not bound');
    }
    treePaths.clear();
    files.clear();
    _dirty.clear();

    onLine?.call('fetching tree of $repoFull …');
    final tree = await _getTree();
    // only text-ish files, skip vendor dirs
    const skip = <String>[
      'node_modules/', '.git/', 'build/', '.dart_tool/', 'dist/',
      'android/app/build/', 'ios/Pods/', '.png', '.jpg', '.jpeg', '.gif',
      '.webp', '.ico', '.woff', '.woff2', '.ttf', '.zip', '.jar', '.so',
      '.apk', '.pdf', '.mp4', '.bin',
    ];
    final okPaths = tree
        .where((e) => e['type'] == 'blob')
        .map((e) => e['path'] as String)
        .where((p) => !skip.any((s) => p.contains(s)))
        .toList();

    final take = okPaths.length > maxFiles ? okPaths.sublist(0, maxFiles) : okPaths;
    treePaths.addAll(take);

    // fetch contents in small batches
    var done = 0;
    for (final p in take) {
      final c = await _fetchRaw(p);
      if (c != null) files[p] = c;
      done++;
      if (done % 25 == 0) {
        onLine?.call('synced $done / ${take.length} files');
      }
    }
    lastSync = DateTime.now();
    onLine?.call('repo synced ✓ ${files.length} files in memory');
  }

  Future<List<Map<String, dynamic>>> _getTree() async {
    final res = await http.get(
      Uri.parse('$_api/repos/$repoFull/git/trees/${defaultBranch ?? 'main'}?recursive=1'),
      headers: {
        'Authorization': 'Bearer $_token',
        'Accept': 'application/vnd.github+json',
      },
    );
    if (res.statusCode != 200) {
      throw Exception('tree fetch ${res.statusCode}');
    }
    final j = jsonDecode(res.body);
    return (j['tree'] as List).cast<Map<String, dynamic>>();
  }

  Future<String?> _fetchRaw(String path) async {
    try {
      final res = await http.get(
        Uri.parse(
            '$_api/repos/$repoFull/contents/${Uri.encodeComponent(path)}'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Accept': 'application/vnd.github.raw',
        },
      );
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
  }

  String? read(String path) => files[path];

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
  Future<int> commitAll(String message) async {
    if (repoFull == null || _token == null) return 0;
    var pushed = 0;
    for (final path in _dirty.toList()) {
      final content = files[path];
      if (content == null) continue;
      final sha = await _shaOf(path);
      final ok = await _putFile(path, content, message, sha);
      if (ok) {
        _dirty.remove(path);
        pushed++;
      }
    }
    return pushed;
  }

  Future<String?> _shaOf(String path) async {
    try {
      final res = await http.get(
        Uri.parse('$_api/repos/$repoFull/contents/${Uri.encodeComponent(path)}'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Accept': 'application/vnd.github+json',
        },
      );
      if (res.statusCode == 200) {
        return (jsonDecode(res.body))['sha'] as String?;
      }
    } catch (_) {}
    return null;
  }

  Future<bool> _putFile(String path, String content, String message,
      String? sha) async {
    final res = await http.put(
      Uri.parse('$_api/repos/$repoFull/contents/${Uri.encodeComponent(path)}'),
      headers: {
        'Authorization': 'Bearer $_token',
        'Accept': 'application/vnd.github+json',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'message': message,
        'content': base64Encode(utf8.encode(content)),
        if (sha != null) 'sha': sha,
      }),
    );
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
