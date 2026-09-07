import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// ── Secure plugin source resolver (spec §4.2) ─────────────────────────
///
/// Normalizes every supported plugin source — marketplace entry, GitHub
/// repo, local folder, ZIP, npm package, pasted MCP config, direct
/// stdio/HTTP MCP definition — into a staging directory under the
/// app-private `plugin-staging/<transaction-id>` root (spec §5.2 step 1).
///
/// Resolution never modifies source content: local trees and archives are
/// copied/extracted byte-for-byte, network payloads stream to disk, and
/// ephemeral pasted/direct configs are stored verbatim as an MCP-only
/// `.mcp.json` the adapter registry recognizes.
///
/// Security invariants:
/// - Archive entries with absolute paths, `..` traversal, or symlinks that
///   escape the staging root reject the whole source; every entry is
///   validated BEFORE anything is written (two-pass extraction). Only
///   regular files and directories are ever created — never symlinks or
///   device nodes.
/// - Local folder copies enforce lexical and symlink containment: only
///   entries whose realpath stays inside the source root are copied.
/// - Remote tree metadata is untrusted: entry paths are lexically checked
///   before they touch a filesystem path.
/// - npm tarballs verify `dist.integrity` (SRI, strongest supported
///   algorithm) when supplied and fail on mismatch.
/// - Staging is deleted on every error path.
/// - Manifest/metadata text parsing is bounded (GitHub tree and npm
///   registry documents have byte caps; pasted configs too). Bulk plugin
///   payloads stream to disk and are limited by storage, not an arbitrary
///   transfer cap.
///
/// Network access reuses the existing plugin-fetch shape (unauthenticated
/// `HttpClient`, 15s connection/request timeouts, `ovid-ai` user agent)
/// so mirrors and proxies that already work keep working.

/// Failure while resolving a plugin source. Staging has already been
/// deleted when this reaches the caller.
class PluginSourceException implements Exception {
  PluginSourceException(this.message);

  final String message;

  @override
  String toString() => 'PluginSourceException: $message';
}

/// Download/copy progress: cumulative bytes received across the whole
/// resolution, plus the size of the current payload when it is known
/// (from `content-length` or the local source file).
typedef PluginSourceProgress = void Function(int received, int? total);

/// One installable plugin origin (spec §4.2 source table).
sealed class PluginSource {
  const PluginSource();

  /// Stable, filesystem-safe identity of this source (used for the
  /// resolved staging root and downstream canonical plugin IDs).
  String get sourceId;
}

/// A marketplace catalog entry: resolve the entry's DECLARED source
/// (GitHub `owner/repo`, optionally `owner/repo/raw/<branch>/<subpath>`,
/// or an existing local folder) and fetch that.
class MarketplacePluginSource extends PluginSource {
  const MarketplacePluginSource({
    required this.catalogName,
    required this.declaredSource,
  });

  /// Human-readable catalog name (for error messages only).
  final String catalogName;

  /// The `source` string from the catalog entry, already normalized by
  /// the marketplace layer.
  final String declaredSource;

  @override
  String get sourceId => declaredSource.trim();
}

/// A GitHub repository (optionally pinned to a branch/ref and re-rooted
/// at a subpath). Fetches the recursive tree and streams every matching
/// blob into staging.
class GithubPluginSource extends PluginSource {
  const GithubPluginSource({
    required this.owner,
    required this.repo,
    this.ref,
    this.subPath,
    this.include,
  });

  final String owner;
  final String repo;

  /// Pinned branch/ref. `main`/`master` are always tried as fallbacks.
  final String? ref;

  /// Repo-relative subdirectory to re-root the source at.
  final String? subPath;

  /// Optional selective filter on re-rooted relative paths (legacy
  /// plugin-content cache compatibility). Null = fetch the full tree.
  final bool Function(String relPath)? include;

  @override
  String get sourceId => '$owner/$repo';
}

/// A local folder, copied into staging with lexical and symlink
/// containment.
class LocalFolderPluginSource extends PluginSource {
  const LocalFolderPluginSource(this.path);

  final String path;

  @override
  String get sourceId => _basename(path);
}

/// A local ZIP archive, extracted into staging with hostile-entry
/// rejection (absolute paths, `..` traversal, symlink escapes).
class ZipPluginSource extends PluginSource {
  const ZipPluginSource(this.path);

  final String path;

  @override
  String get sourceId {
    final base = _basename(path);
    return base.endsWith('.zip') ? base.substring(0, base.length - 4) : base;
  }
}

/// An npm package, resolved through registry metadata and downloaded as
/// a tarball with optional `dist.integrity` verification.
class NpmPluginSource extends PluginSource {
  const NpmPluginSource({required this.package, this.version});

  final String package;
  final String? version;

  @override
  String get sourceId => package;
}

/// Pasted MCP config text (JSON or TOML), stored verbatim as an
/// ephemeral MCP-only source.
class PastedConfigPluginSource extends PluginSource {
  const PastedConfigPluginSource({
    required this.label,
    required this.rawConfig,
  });

  final String label;
  final String rawConfig;

  @override
  String get sourceId => label.trim();
}

/// A direct MCP server definition (stdio command or Streamable HTTP
/// URL), staged as a synthesized MCP-only config.
class DirectMcpPluginSource extends PluginSource {
  const DirectMcpPluginSource.stdio({
    required this.name,
    required this.command,
    this.args = const [],
    this.cwd,
  }) : url = null,
       headers = const {};

  const DirectMcpPluginSource.http({
    required this.name,
    required this.url,
    this.headers = const {},
    this.cwd,
  }) : command = null,
       args = const [];

  final String name;
  final String? command;
  final List<String> args;
  final String? url;

  /// Header names AND values as the user typed them — this is source
  /// content (kept verbatim in the staged config), not plugin metadata.
  /// Adapters scrub values when building [NormalizedPluginManifest]
  /// records, keeping only names.
  final Map<String, String> headers;

  final String? cwd;

  @override
  String get sourceId => name.trim();
}

/// The staging result of one [PluginSourceResolver.resolve] call.
class ResolvedPluginSource {
  ResolvedPluginSource._({
    required this.source,
    required this.sourceId,
    required this.transactionId,
    required this.stagingDir,
    required this.fileCount,
  });

  final PluginSource source;
  final String sourceId;
  final String transactionId;

  /// App-private `<root>/plugin-staging/<transaction-id>` holding the
  /// resolved, unmodified source content.
  final Directory stagingDir;

  /// Regular files staged.
  final int fileCount;

  bool _discarded = false;
  bool get isDiscarded => _discarded;

  /// Delete the staging directory (install transaction failure, or after
  /// the content has been moved/copied elsewhere). Idempotent.
  void discard() {
    if (_discarded) return;
    _discarded = true;
    try {
      if (stagingDir.existsSync()) stagingDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Resolves [PluginSource]s into read-only staging directories
/// (spec §4.2). Construct with test seams; production callers use the
/// defaults (app documents root, real GitHub/npm endpoints).
class PluginSourceResolver {
  const PluginSourceResolver({
    this.stagingRootOverride,
    this.githubBaseOverride,
    this.npmRegistryBaseOverride,
  });

  /// Base directory that will contain `plugin-staging/`. Defaults to the
  /// app documents directory (system temp when unavailable, e.g. unit
  /// tests without the path_provider channel).
  final Directory? stagingRootOverride;

  /// Single-origin GitHub mock base (`http://host:port`) serving
  /// `/tree/<branch>` and `/raw/<repo-path>` — parity with the existing
  /// `AppState.pluginContentBaseOverrideForTest` seam.
  final String? githubBaseOverride;

  /// npm registry base override (e.g. a local mock registry).
  final String? npmRegistryBaseOverride;

  static const String _userAgent = 'ovid-ai';
  static const Duration _timeout = Duration(seconds: 15);

  /// Bounded metadata parsing (memory-abuse guard); bulk payloads stream
  /// to disk instead.
  static const int _kMaxTreeBytes = 4 * 1024 * 1024;
  static const int _kMaxRegistryBytes = 4 * 1024 * 1024;
  static const int _kMaxPastedBytes = 1024 * 1024;

  /// Same walk-depth cap the compatibility adapters use for bundle
  /// scans (`kBundleScanMaxDepth`).
  static const int _kMaxLocalDepth = 12;

  static final RegExp _npmNamePattern = RegExp(
    r'^(@[A-Za-z0-9._~-]+/)?[A-Za-z0-9._~-]+$',
  );

  static int _txCounter = 0;

  /// Resolve [source] into fresh app-private staging. Throws
  /// [PluginSourceException] (or the underlying IO error) on failure —
  /// staging is always deleted before the error reaches the caller.
  Future<ResolvedPluginSource> resolve(
    PluginSource source, {
    PluginSourceProgress? onProgress,
  }) async {
    final base = await _stagingRoot();
    final transactionId = _newTransactionId();
    final staging =
        Directory('${base.path}/plugin-staging/$transactionId')
          ..createSync(recursive: true);
    final progress = _Progress(onProgress);
    try {
      final count = await switch (source) {
        MarketplacePluginSource s => _resolveMarketplace(s, staging, progress),
        GithubPluginSource s => _resolveGithub(s, staging, progress),
        LocalFolderPluginSource s => _resolveLocalFolder(s, staging, progress),
        ZipPluginSource s => _resolveZip(s, staging),
        NpmPluginSource s => _resolveNpm(s, staging, progress),
        PastedConfigPluginSource s => _resolvePasted(s, staging, progress),
        DirectMcpPluginSource s => _resolveDirectMcp(s, staging, progress),
      };
      return ResolvedPluginSource._(
        source: source,
        sourceId: source.sourceId,
        transactionId: transactionId,
        stagingDir: staging,
        fileCount: count,
      );
    } catch (_) {
      try {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
      } catch (_) {}
      rethrow;
    }
  }

  Future<Directory> _stagingRoot() async {
    if (stagingRootOverride != null) return stagingRootOverride!;
    try {
      return await getApplicationDocumentsDirectory();
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  String _newTransactionId() {
    final micros = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rand = Random().nextInt(0xFFFFFF).toRadixString(36).padLeft(5, '0');
    return '$micros-$rand-${_txCounter++}';
  }

  // ── Marketplace ────────────────────────────────────────────────────────

  Future<int> _resolveMarketplace(
    MarketplacePluginSource s,
    Directory staging,
    _Progress p,
  ) async {
    final declared = s.declaredSource.trim();
    if (declared.isEmpty) {
      throw PluginSourceException(
        'marketplace entry "${s.catalogName}" declares an empty source',
      );
    }
    if (Directory(declared).existsSync()) {
      return _resolveLocalFolder(LocalFolderPluginSource(declared), staging, p);
    }
    final parts = declared.split('/');
    if (parts.length < 2 || parts[0].isEmpty || parts[1].isEmpty) {
      throw PluginSourceException(
        'marketplace entry "${s.catalogName}" declares an unusable source: '
        '${s.declaredSource}',
      );
    }
    String? ref;
    String? subPath;
    if (parts.length >= 4 && parts[2] == 'raw') {
      if (parts[3] != 'branch' && parts[3].isNotEmpty) ref = parts[3];
      if (parts.length > 4) {
        final sp = parts.sublist(4).join('/');
        if (sp.isNotEmpty) subPath = sp;
      }
    }
    return _resolveGithub(
      GithubPluginSource(
        owner: parts[0],
        repo: parts[1],
        ref: ref,
        subPath: subPath,
      ),
      staging,
      p,
    );
  }

  // ── GitHub ─────────────────────────────────────────────────────────────

  Future<int> _resolveGithub(
    GithubPluginSource s,
    Directory staging,
    _Progress p,
  ) async {
    final subPrefix =
        s.subPath == null || s.subPath!.isEmpty ? '' : '${s.subPath}/';
    final branches =
        s.ref != null && s.ref!.isNotEmpty
            ? [s.ref!, 'main', 'master']
            : const ['main', 'master'];

    var treeReached = false;
    for (final branch in branches) {
      final treeUrl =
          githubBaseOverride != null
              ? '$githubBaseOverride/tree/$branch'
              : 'https://api.github.com/repos/${s.owner}/${s.repo}/git/'
                    'trees/$branch?recursive=1';
      List<Map<String, String>> entries;
      try {
        entries = await _githubTreeEntries(s, treeUrl, branch, subPrefix);
        treeReached = true;
      } catch (_) {
        continue; // unreachable/malformed branch — try the next candidate
      }
      if (entries.isEmpty) continue;

      // First branch with matching content wins (matches the legacy
      // selective fetch); individual blob failures skip that file.
      var staged = 0;
      for (final e in entries) {
        final rel = e['rel']!;
        final repoPath = e['repoPath']!;
        final urls =
            githubBaseOverride != null
                ? [
                  '$githubBaseOverride/raw/$repoPath',
                  if (rel != repoPath) '$githubBaseOverride/raw/$rel',
                ]
                : [
                  'https://raw.githubusercontent.com/${s.owner}/${s.repo}/'
                      '$branch/$repoPath',
                ];
        final target = File('${staging.path}/$rel');
        for (final u in urls) {
          try {
            await _downloadToFile(Uri.parse(u), target, p);
            staged++;
            break;
          } catch (_) {
            continue;
          }
        }
      }
      return staged;
    }
    if (!treeReached) {
      throw PluginSourceException(
        'GitHub tree unreachable for ${s.owner}/${s.repo} '
        '(tried ${branches.join(', ')})',
      );
    }
    return 0; // tree exists but nothing matched — empty staging is success
  }

  Future<List<Map<String, String>>> _githubTreeEntries(
    GithubPluginSource s,
    String treeUrl,
    String branch,
    String subPrefix,
  ) async {
    final j = await _getJson(
      Uri.parse(treeUrl),
      _kMaxTreeBytes,
      accept: 'application/vnd.github+json',
    );
    final tree = (j['tree'] as List?)?.cast<Map<String, dynamic>>();
    if (tree == null) {
      throw PluginSourceException(
        'GitHub tree response for ${s.owner}/${s.repo} is malformed',
      );
    }
    final out = <Map<String, String>>[];
    for (final entry in tree) {
      if (entry['type'] != 'blob') continue;
      final fullPath = entry['path'] as String? ?? '';
      // Remote tree metadata is untrusted input: check it lexically
      // BEFORE it becomes a filesystem path.
      if (fullPath.isEmpty || !_isLexicallySafe(fullPath)) continue;
      String rel = fullPath;
      if (subPrefix.isNotEmpty) {
        if (!fullPath.startsWith(subPrefix)) continue;
        rel = fullPath.substring(subPrefix.length);
      }
      if (rel.isEmpty || !_isLexicallySafe(rel)) continue;
      final include = s.include;
      if (include != null && !include(rel)) continue;
      out.add({'rel': rel, 'repoPath': fullPath, 'branch': branch});
    }
    return out;
  }

  // ── Local folder ───────────────────────────────────────────────────────

  Future<int> _resolveLocalFolder(
    LocalFolderPluginSource s,
    Directory staging,
    _Progress p,
  ) async {
    final src = Directory(s.path);
    if (!src.existsSync()) {
      throw PluginSourceException('local plugin folder not found: ${s.path}');
    }
    final root = src.resolveSymbolicLinksSync();
    final stagingRoot = staging.resolveSymbolicLinksSync();
    if (root == stagingRoot ||
        root.startsWith('$stagingRoot/') ||
        stagingRoot.startsWith('$root/')) {
      throw PluginSourceException(
        'local plugin folder overlaps the plugin staging root',
      );
    }
    var count = 0;

    void walk(Directory dir, int depth) {
      if (depth > _kMaxLocalDepth) return;
      final List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } catch (_) {
        return;
      }
      for (final e in entries) {
        final rel = e.path.substring(root.length + 1);
        if (rel.isEmpty || !_isLexicallySafe(rel)) continue;
        if (e is Directory) {
          walk(e, depth + 1);
          continue;
        }
        if (e is Link) {
          // Copy links that resolve INSIDE the source root as the regular
          // file content they point at; never follow directory links
          // (cycle risk) and never copy escaping links.
          try {
            final real = e.resolveSymbolicLinksSync();
            if (!real.startsWith('$root/')) continue;
            if (FileSystemEntity.typeSync(e.path, followLinks: true) !=
                FileSystemEntityType.file) {
              continue;
            }
            if (_copyIntoStaging(File(e.path), '${staging.path}/$rel', p)) {
              count++;
            }
          } catch (_) {
            continue;
          }
          continue;
        }
        if (e is File) {
          String real;
          try {
            real = e.resolveSymbolicLinksSync();
          } catch (_) {
            continue;
          }
          if (!real.startsWith('$root/')) continue;
          if (_copyIntoStaging(e, '${staging.path}/$rel', p)) count++;
        }
      }
    }

    walk(Directory(root), 0);
    return count;
  }

  bool _copyIntoStaging(File from, String toPath, _Progress p) {
    try {
      final bytes = from.readAsBytesSync();
      // Byte-identical copy — resolution never modifies source content.
      File(toPath)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      p.add(bytes.length, null);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── ZIP ────────────────────────────────────────────────────────────────

  Future<int> _resolveZip(ZipPluginSource s, Directory staging) async {
    final f = File(s.path);
    if (!f.existsSync()) {
      throw PluginSourceException('zip plugin archive not found: ${s.path}');
    }
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(f.readAsBytesSync());
    } catch (_) {
      throw PluginSourceException('unreadable zip archive: ${s.path}');
    }
    return _extractArchiveEntries(archive, staging);
  }

  // ── npm ────────────────────────────────────────────────────────────────

  Future<int> _resolveNpm(
    NpmPluginSource s,
    Directory staging,
    _Progress p,
  ) async {
    if (!_npmNamePattern.hasMatch(s.package)) {
      throw PluginSourceException('invalid npm package name: ${s.package}');
    }
    final base = (npmRegistryBaseOverride ?? 'https://registry.npmjs.org')
        .replaceAll(RegExp(r'/+$'), '');
    final metaUrl =
        s.version == null ? '$base/${s.package}' : '$base/${s.package}/${s.version}';
    final meta = await _getJson(
      Uri.parse(metaUrl),
      _kMaxRegistryBytes,
      accept: 'application/json',
    );

    Map<String, dynamic> versionDoc;
    if (s.version != null) {
      versionDoc = meta;
    } else {
      final latest =
          ((meta['dist-tags'] as Map?)?.cast<String, dynamic>())?['latest']
              as String?;
      final versions = (meta['versions'] as Map?)?.cast<String, dynamic>();
      final doc =
          latest == null ? null : (versions?[latest] as Map?)?.cast<String, dynamic>();
      if (doc == null) {
        throw PluginSourceException(
          'npm package ${s.package} has no resolvable latest version',
        );
      }
      versionDoc = doc;
    }

    final dist = (versionDoc['dist'] as Map?)?.cast<String, dynamic>();
    final tarball = (dist?['tarball'] as String?)?.trim() ?? '';
    if (tarball.isEmpty) {
      throw PluginSourceException(
        'npm package ${s.package} has no dist.tarball',
      );
    }
    final integrity = (dist?['integrity'] as String?)?.trim();
    final tarballUri = Uri.parse(tarball);
    final absolute =
        tarballUri.isAbsolute
            ? tarballUri
            : Uri.parse('$base/${tarball.replaceFirst(RegExp(r'^/+'), '')}');

    // Stream the tarball to disk (payloads to disk; storage is the only
    // size bound), then verify before anything is extracted.
    final tgz = File('${staging.path}/.npm-tarball.tgz');
    await _downloadToFile(absolute, tgz, p);
    final List<int> bytes;
    try {
      bytes = tgz.readAsBytesSync();
    } finally {
      _deleteQuietly(tgz);
    }
    if (integrity != null && integrity.isNotEmpty && !_verifySri(bytes, integrity)) {
      throw PluginSourceException(
        'npm integrity check failed for ${s.package} '
        '(expected $integrity)',
      );
    }

    List<int> tarBytes;
    try {
      tarBytes = GZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw PluginSourceException(
        'npm tarball for ${s.package} is not valid gzip',
      );
    }
    Archive tar;
    try {
      tar = TarDecoder().decodeBytes(tarBytes);
    } catch (_) {
      throw PluginSourceException(
        'npm tarball for ${s.package} is not a valid tar',
      );
    }
    // npm tarballs nest everything under `package/` — re-root staging.
    return _extractArchiveEntries(tar, staging, stripPrefix: 'package');
  }

  /// Verify an SRI integrity metadata string. Checks the strongest
  /// supported algorithm present (sha512 > sha256 > sha1); unsupported
  /// algorithms are treated as nothing to verify.
  bool _verifySri(List<int> bytes, String integrity) {
    final candidates =
        integrity.split(RegExp(r'\s+')).where((c) => c.contains('-')).toList();
    for (final alg in const ['sha512', 'sha256', 'sha1']) {
      final forAlg =
          candidates
              .where((c) => c.substring(0, c.indexOf('-')) == alg)
              .toList();
      if (forAlg.isEmpty) continue;
      final actual = switch (alg) {
        'sha512' => base64.encode(sha512.convert(bytes).bytes),
        'sha256' => base64.encode(sha256.convert(bytes).bytes),
        _ => base64.encode(sha1.convert(bytes).bytes),
      };
      return forAlg.any((c) => c.substring(c.indexOf('-') + 1) == actual);
    }
    return true;
  }

  // ── Pasted config / direct MCP ─────────────────────────────────────────

  Future<int> _resolvePasted(
    PastedConfigPluginSource s,
    Directory staging,
    _Progress p,
  ) async {
    if (s.label.trim().isEmpty) {
      throw PluginSourceException('pasted MCP config needs a label');
    }
    final raw = s.rawConfig;
    if (raw.trim().isEmpty) {
      throw PluginSourceException('pasted MCP config is empty');
    }
    final bytes = utf8.encode(raw);
    if (bytes.length > _kMaxPastedBytes) {
      throw PluginSourceException(
        'pasted MCP config exceeds the ${_kMaxPastedBytes ~/ 1024} KiB bound',
      );
    }
    // Stored verbatim under the registry-recognized MCP-only marker.
    // `parseMcpConfig` sniffs JSON vs TOML from the content, so both
    // paste shapes adapt through the generic MCP adapter (spec §4.2).
    File('${staging.path}/.mcp.json').writeAsBytesSync(bytes);
    p.add(bytes.length, bytes.length);
    return 1;
  }

  Future<int> _resolveDirectMcp(
    DirectMcpPluginSource s,
    Directory staging,
    _Progress p,
  ) async {
    final name = s.name.trim();
    if (name.isEmpty) {
      throw PluginSourceException('direct MCP server needs a name');
    }
    final hasCommand = s.command != null && s.command!.trim().isNotEmpty;
    final hasUrl = s.url != null && s.url!.trim().isNotEmpty;
    if (!hasCommand && !hasUrl) {
      throw PluginSourceException(
        'direct MCP source "$name" needs a stdio command or an HTTP url',
      );
    }
    final def = <String, dynamic>{
      if (hasCommand) 'command': s.command!.trim(),
      if (s.args.isNotEmpty) 'args': s.args,
      if (hasUrl) 'url': s.url!.trim(),
      if (s.headers.isNotEmpty) 'headers': s.headers,
      if (s.cwd != null && s.cwd!.trim().isNotEmpty) 'cwd': s.cwd!.trim(),
    };
    final text = jsonEncode({
      'mcpServers': {name: def},
    });
    final bytes = utf8.encode(text);
    File('${staging.path}/.mcp.json').writeAsBytesSync(bytes);
    p.add(bytes.length, bytes.length);
    return 1;
  }

  // ── Safe archive extraction (ZIP + npm tarballs share these guards) ───

  /// Two-pass extraction: validate EVERY entry first (a single hostile
  /// entry rejects the whole archive before any write), then write only
  /// regular files and directories.
  int _extractArchiveEntries(
    Archive archive,
    Directory staging, {
    String stripPrefix = '',
  }) {
    final planned = <ArchiveFile, String>{};
    for (final e in archive.files) {
      final name = _archiveEntryPath(e, stripPrefix);
      if (name == null) continue;
      planned[e] = name;
    }
    var count = 0;
    for (final entry in planned.entries) {
      final e = entry.key;
      final target = '${staging.path}/${entry.value}';
      if (_archiveLinkTarget(e) != null) {
        // Contained symlinks are skipped (escaping ones already threw in
        // pass 1); staging never contains links, and device nodes are
        // never created — only regular files and directories.
        continue;
      }
      if (e.isFile) {
        File(target)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(e.readBytes() ?? const []);
        count++;
      } else {
        Directory(target).createSync(recursive: true);
      }
    }
    return count;
  }

  /// Validate and normalize one archive entry path, or null when the
  /// entry is not part of the staged tree (outside [stripPrefix]).
  /// Throws [PluginSourceException] on absolute paths, `..` escapes, and
  /// symlink entries whose target leaves the staging root.
  String? _archiveEntryPath(ArchiveFile e, String stripPrefix) {
    final raw = e.name.replaceAll('\\', '/');
    if (raw.isEmpty) return null;
    if (raw.startsWith('/') || (raw.length > 1 && raw[1] == ':')) {
      throw PluginSourceException(
        'archive entry has an absolute path: ${e.name}',
      );
    }
    var name = raw;
    if (stripPrefix.isNotEmpty) {
      if (name == stripPrefix || name == '$stripPrefix/') return null;
      if (!name.startsWith('$stripPrefix/')) return null;
      name = name.substring(stripPrefix.length + 1);
    }

    var depth = 0;
    for (final seg in name.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        depth--;
        if (depth < 0) {
          throw PluginSourceException(
            'archive entry escapes the staging root: ${e.name}',
          );
        }
        continue;
      }
      depth++;
    }

    final link = _archiveLinkTarget(e);
    if (link != null) {
      final t = link.replaceAll('\\', '/');
      if (t.startsWith('/') || (t.length > 1 && t[1] == ':')) {
        throw PluginSourceException(
          'archive symlink target is absolute: ${e.name} -> $link',
        );
      }
      final linkDir =
          name.contains('/')
              ? name.substring(0, name.lastIndexOf('/')).split('/')
              : const <String>[];
      var d = 0;
      for (final seg in [...linkDir, ...t.split('/')]) {
        if (seg.isEmpty || seg == '.') continue;
        if (seg == '..') {
          d--;
          if (d < 0) {
            throw PluginSourceException(
              'archive symlink escapes the staging root: ${e.name} -> $link',
            );
          }
          continue;
        }
        d++;
      }
    }

    name = name.replaceAll(RegExp(r'/+'), '/');
    while (name.endsWith('/')) {
      name = name.substring(0, name.length - 1);
    }
    return name.isEmpty ? null : name;
  }

  /// Symlink target of an archive entry, or null for regular entries.
  /// Zips encoded without the unix `versionMadeBy` flag keep the symlink
  /// type only in the mode nibble (0xa000) with the target as content.
  String? _archiveLinkTarget(ArchiveFile e) {
    final sym = e.symbolicLink;
    if (sym != null && sym.isNotEmpty) return sym;
    if ((e.mode & 0xf000) == 0xa000) {
      final bytes = e.readBytes();
      return bytes == null ? '' : utf8.decode(bytes, allowMalformed: true);
    }
    return null;
  }

  // ── HTTP + shared helpers ──────────────────────────────────────────────

  /// Stream [uri] into [target] (payloads to disk), reporting progress.
  /// Throws [PluginSourceException] on non-200; partial files are removed.
  Future<void> _downloadToFile(Uri uri, File target, _Progress p) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client.getUrl(uri).timeout(_timeout);
      req.headers.set('User-Agent', _userAgent);
      final res = await req.close().timeout(_timeout);
      if (res.statusCode != 200) {
        throw PluginSourceException('HTTP ${res.statusCode} downloading $uri');
      }
      final total = res.contentLength > 0 ? res.contentLength : null;
      target.parent.createSync(recursive: true);
      var ok = false;
      final sink = target.openWrite();
      try {
        await for (final chunk in res.timeout(_timeout)) {
          sink.add(chunk);
          p.add(chunk.length, total);
        }
        await sink.flush();
        ok = true;
      } finally {
        try {
          await sink.close();
        } catch (_) {}
        if (!ok) _deleteQuietly(target);
      }
    } finally {
      client.close(force: true);
    }
  }

  /// Fetch a small JSON object with a bounded in-memory read (metadata
  /// documents only — never bulk payloads).
  Future<Map<String, dynamic>> _getJson(
    Uri uri,
    int maxBytes, {
    String? accept,
  }) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client.getUrl(uri).timeout(_timeout);
      req.headers.set('User-Agent', _userAgent);
      if (accept != null) req.headers.set('Accept', accept);
      final res = await req.close().timeout(_timeout);
      if (res.statusCode != 200) {
        throw PluginSourceException('HTTP ${res.statusCode} fetching $uri');
      }
      final builder = BytesBuilder();
      await for (final chunk in res.timeout(_timeout)) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          throw PluginSourceException(
            'response from $uri exceeds the '
            '${maxBytes ~/ (1024 * 1024)} MiB metadata bound',
          );
        }
      }
      final decoded = jsonDecode(utf8.decode(builder.takeBytes()));
      if (decoded is! Map) {
        throw PluginSourceException('expected a JSON object from $uri');
      }
      return decoded.cast<String, dynamic>();
    } finally {
      client.close(force: true);
    }
  }

  /// True when [rel] is a relative path with no `..` escape, no leading
  /// separator, and no drive letter.
  static bool _isLexicallySafe(String rel) {
    if (rel.isEmpty || rel.startsWith('/') || rel.startsWith('\\')) {
      return false;
    }
    if (rel.length > 1 && rel[1] == ':') return false; // windows drive
    var depth = 0;
    for (final seg in rel.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        depth--;
        if (depth < 0) return false;
        continue;
      }
      depth++;
    }
    return true;
  }

  static void _deleteQuietly(FileSystemEntity e) {
    try {
      if (e.existsSync()) e.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Cumulative progress accumulator shared by one [PluginSourceResolver.resolve].
class _Progress {
  _Progress(this.on);

  final PluginSourceProgress? on;
  int received = 0;

  void add(int bytes, int? total) {
    received += bytes;
    on?.call(received, total);
  }
}

String _basename(String path) {
  final p = path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  final i = p.lastIndexOf('/');
  return i >= 0 && i < p.length - 1 ? p.substring(i + 1) : p;
}
