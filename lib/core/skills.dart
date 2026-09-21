import 'dart:convert';
import 'dart:io';

import 'plugin_manifest.dart';
import 'plugin_registry.dart';

/// ── Skills system ────────────────────────────────────────────────────────
/// A skill is a markdown instruction bundle the agent can load on demand.
/// Layout:
///   `<workspace>/.dsh/skills/<name>/SKILL.md`   (bundle)
///   `<workspace>/.dsh/skills/<name>.md`         (flat)
/// Frontmatter supports:
///   name, description, whenToUse, metadata,
///   disable-model-invocation, user-invocable
///
/// The agent sees a compact catalog in its system context and can call the
/// `skill` tool to load the full content when a task needs it. Users can
/// also invoke a skill directly from the composer with `/skill-name`.

enum SkillContributionKind { command, skill, agent }

class Skill {
  final String name;
  final String description;
  final String whenToUse;
  final String content;
  final String path;

  /// Directory that [supportingFiles] and [SkillService.readSupportingFile]
  /// resolve against. Null for in-memory declarations with no file location.
  final String? dirPath;

  /// Absolute path of the source markdown file (`SKILL.md`/`AGENT.md`/flat
  /// `.md`). Null for in-memory declarations. Used for hot-reload change
  /// detection, since [path] may be a bundle DIRECTORY.
  final String? sourcePath;

  final bool modelInvocable;
  final bool userInvocable;
  final List<String> allowedTools;
  final String? argumentHint;
  final String? model;
  final Map<String, String> frontmatter;
  final bool isAgent;
  final SkillContributionKind kind;

  /// Bundle-relative paths of every non-SKILL.md file that ships beside a
  /// bundled skill (templates, references, scripts). Empty for flat skills.
  /// Collected by a symlink-refusing, depth-limited, containment-checked
  /// walk so a bundle can never pull in a file outside its own directory.
  final List<String> supportingFiles;

  /// Canonical plugin id (`publisher/name`) of the plugin that contributed
  /// this skill; null for workspace/user skills. Set by
  /// [SkillService.addPluginRoot] when the owning root is scanned.
  final String? pluginId;

  Skill({
    required this.name,
    required this.description,
    required this.whenToUse,
    required this.content,
    required this.path,
    this.dirPath,
    this.sourcePath,
    required this.modelInvocable,
    required this.userInvocable,
    List<String> allowedTools = const [],
    this.argumentHint,
    this.model,
    Map<String, String> frontmatter = const {},
    this.isAgent = false,
    this.kind = SkillContributionKind.skill,
    List<String> supportingFiles = const [],
    this.pluginId,
  }) : allowedTools = List.unmodifiable(allowedTools),
       frontmatter = Map.unmodifiable(frontmatter),
       supportingFiles = List.unmodifiable(supportingFiles);

  /// Canonical contribution id (spec §4.4) for plugin content.
  String? get canonicalId =>
      pluginId == null ? null : 'plugin:$pluginId/${kind.name}:$name';

  /// The exact id an ambiguous-alias chooser lists: the canonical §4.4 id
  /// for plugin skills, the declaring path otherwise.
  String get providerId => canonicalId ?? path;

  /// Compact catalog line injected into the agent system context.
  String get catalogLine =>
      '- `$name`: ${description.isEmpty ? '(no description)' : description}'
      '${whenToUse.isEmpty ? '' : ' — use when: $whenToUse'}';
}

class PluginCatalogMount {
  final String contentDir;
  final NormalizedPluginManifest manifest;

  const PluginCatalogMount(this.contentDir, this.manifest);
}

class SkillCatalogInputs {
  final List<String> roots;
  final List<PluginCatalogMount> mounts;

  SkillCatalogInputs({
    Iterable<String> roots = const [],
    Iterable<PluginCatalogMount> mounts = const [],
  }) : roots = List.unmodifiable(roots),
       mounts = List.unmodifiable(mounts);
}

class SkillCatalogReservation {
  final String sessionId;
  final int generation;

  const SkillCatalogReservation(this.sessionId, this.generation);
}

class SkillCatalogSnapshot {
  final String sessionId;
  final int generation;
  final List<Skill> skills;

  /// The scanned roots this snapshot was built from (workspace skill dirs).
  /// Kept so a later call can cheaply detect that a `SKILL.md` was edited and
  /// re-scan instead of serving a stale catalog.
  final List<String> roots;

  /// Fingerprint of the root dirs + parsed skill files at publish time.
  final String fingerprint;

  /// Non-fatal findings raised while building this snapshot (for example a
  /// plugin declaring the same canonical contribution id twice). Publishing
  /// never throws for these; the caller surfaces them as a compatibility
  /// warning instead.
  final List<String> compatibilityNotes;

  SkillCatalogSnapshot({
    required this.sessionId,
    required this.generation,
    required List<Skill> skills,
    List<String> roots = const [],
    this.fingerprint = '',
    List<String> compatibilityNotes = const [],
  }) : skills = List.unmodifiable(skills),
       roots = List.unmodifiable(roots),
       compatibilityNotes = List.unmodifiable(compatibilityNotes);

  List<Skill> get userSkills =>
      List.unmodifiable(skills.where((skill) => skill.userInvocable));

  List<Skill> get agents => List.unmodifiable(
    skills.where((skill) => skill.kind == SkillContributionKind.agent),
  );

  SkillAliasResolution resolveAlias(String alias) =>
      _resolveSkillAlias(skills, alias);

  String catalogBlock({int maxDescChars = 500}) =>
      _catalogBlock(skills, maxDescChars: maxDescChars);
}

/// Loads skills from the filesystem with optional hot reload.
class SkillService {
  SkillService._();
  static final SkillService I = SkillService._();

  /// Test seam: a fresh isolated instance (private ctor is shared with I).
  SkillService.forTest() : this._();

  final List<Skill> _skills = [];
  final Set<String> _roots = {};

  /// Root path → owning plugin canonical id ([addPluginRoot]).
  final Map<String, String> _pluginRoots = {};
  final Map<String, SkillCatalogSnapshot> _sessionSnapshots = {};
  final Map<String, int> _sessionGenerations = {};

  List<Skill> get skills => List.unmodifiable(_skills);

  /// Skills the user can invoke from the composer with `/name` or the
  /// slash suggestion menu.
  List<Skill> get userSkills =>
      List.unmodifiable(_skills.where((s) => s.userInvocable));

  /// Discovered agent persona definitions.
  List<Skill> get agents => List.unmodifiable(_skills.where((s) => s.isAgent));

  bool hasSnapshotForSession(String sessionId) =>
      _sessionSnapshots.containsKey(sessionId);

  SkillCatalogSnapshot snapshotForSession(String sessionId) =>
      _sessionSnapshots[sessionId] ??
      SkillCatalogSnapshot(
        sessionId: sessionId,
        generation: 0,
        skills: const [],
      );

  List<Skill> skillsForSession(String sessionId) =>
      snapshotForSession(sessionId).skills;

  List<Skill> userSkillsForSession(String sessionId) =>
      snapshotForSession(sessionId).userSkills;

  List<Skill> agentsForSession(String sessionId) =>
      snapshotForSession(sessionId).agents;

  SkillAliasResolution resolveForSession(String sessionId, String alias) =>
      snapshotForSession(sessionId).resolveAlias(alias);

  String catalogBlockForSession(String sessionId, {int maxDescChars = 500}) =>
      snapshotForSession(sessionId).catalogBlock(maxDescChars: maxDescChars);

  SkillCatalogReservation reserveSessionCatalog(String sessionId) {
    final generation = (_sessionGenerations[sessionId] ?? 0) + 1;
    _sessionGenerations[sessionId] = generation;
    return SkillCatalogReservation(sessionId, generation);
  }

  Future<void> publishSessionCatalog(
    String sessionId, {
    SkillCatalogReservation? reservation,
    Iterable<String> roots = const [],
    Iterable<PluginCatalogMount> mounts = const [],
    Future<void> Function()? beforeScan,
  }) async {
    final reserved = reservation ?? reserveSessionCatalog(sessionId);
    if (reserved.sessionId != sessionId) {
      throw ArgumentError.value(
        reserved.sessionId,
        'reservation',
        'Reservation belongs to another session',
      );
    }
    final generation = reserved.generation;
    await beforeScan?.call();

    final rootList = roots.toList();
    final candidate = <Skill>[];
    for (final root in rootList) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      await _scanDir(dir, output: candidate);
    }
    for (final mount in mounts) {
      await _scanPluginMount(mount, candidate);
    }
    if (_sessionGenerations[sessionId] != generation) return;
    // Dedupe BEFORE sorting: canonical ids are install-order first-wins, and
    // Dart's sort is not stable, so a post-sort dedupe would be arbitrary.
    final notes = <String>[];
    final keptByCanonical = <String, Skill>{};
    final deduped = <Skill>[];
    for (final skill in candidate) {
      final id = skill.canonicalId;
      if (id == null) {
        deduped.add(skill);
        continue;
      }
      final kept = keptByCanonical[id];
      if (kept != null) {
        notes.add(
          'Duplicate plugin contribution id $id at ${skill.path}; '
          'keeping ${kept.path}',
        );
        continue;
      }
      keptByCanonical[id] = skill;
      deduped.add(skill);
    }
    deduped.sort((a, b) => a.providerId.compareTo(b.providerId));
    _sessionSnapshots[sessionId] = SkillCatalogSnapshot(
      sessionId: sessionId,
      generation: generation,
      skills: deduped,
      roots: rootList,
      fingerprint: computeCatalogFingerprint(rootList, deduped),
      compatibilityNotes: notes,
    );
  }

  /// Cheap change-detection fingerprint: the mtime of every scanned root plus
  /// every parsed skill file. A `SKILL.md` edit or a new/removed bundle
  /// changes it, so a stale snapshot can be re-scanned on demand.
  static String computeCatalogFingerprint(
    List<String> roots,
    List<Skill> skills,
  ) {
    final sb = StringBuffer();
    int mtime(String path, {required bool dir}) {
      try {
        final t = dir ? Directory(path) : File(path);
        if (!t.existsSync()) return -1;
        return t.statSync().modified.millisecondsSinceEpoch;
      } catch (_) {
        return -1;
      }
    }

    for (final r in roots) {
      sb
        ..write(r)
        ..write(':')
        ..write(mtime(r, dir: true))
        ..write(';');
    }
    for (final s in skills) {
      final file = s.sourcePath ?? s.path;
      sb
        ..write(file)
        ..write(':')
        ..write(mtime(file, dir: false))
        ..write(';');
    }
    return sb.toString();
  }

  /// True when [sessionId]'s published catalog no longer matches the files on
  /// disk (a workspace skill was edited/added/removed). Callers re-scan.
  bool isSessionCatalogStale(String sessionId) {
    final snapshot = _sessionSnapshots[sessionId];
    if (snapshot == null) return true;
    if (snapshot.roots.isEmpty) return false;
    return computeCatalogFingerprint(snapshot.roots, snapshot.skills) !=
        snapshot.fingerprint;
  }

  void invalidateSession(String sessionId) {
    _sessionGenerations[sessionId] = (_sessionGenerations[sessionId] ?? 0) + 1;
    _sessionSnapshots.remove(sessionId);
  }

  void invalidateAllSessions() {
    for (final sessionId in {
      ..._sessionGenerations.keys,
      ..._sessionSnapshots.keys,
    }) {
      _sessionGenerations[sessionId] =
          (_sessionGenerations[sessionId] ?? 0) + 1;
    }
    _sessionSnapshots.clear();
  }

  void invalidatePlugin(String pluginId) {
    for (final sessionId in {
      ..._sessionGenerations.keys,
      ..._sessionSnapshots.keys,
    }) {
      final generation = (_sessionGenerations[sessionId] ?? 0) + 1;
      _sessionGenerations[sessionId] = generation;
      final snapshot = _sessionSnapshots[sessionId];
      if (snapshot == null) continue;
      _sessionSnapshots[sessionId] = SkillCatalogSnapshot(
        sessionId: sessionId,
        generation: generation,
        skills: snapshot.skills
            .where((skill) => skill.pluginId != pluginId)
            .toList(),
        roots: snapshot.roots,
        compatibilityNotes: snapshot.compatibilityNotes,
      );
    }
  }

  void dropSession(String sessionId) => invalidateSession(sessionId);

  /// Register a search root (workspace, custom dirs, etc).
  void addRoot(String path) {
    if (path.trim().isEmpty) return;
    _roots.add(path);
  }

  /// Register a search root owned by ONE plugin (canonical `publisher/name`
  /// id). Skills scanned from it carry [Skill.pluginId], so they gain a
  /// canonical §4.4 id (`plugin:<plugin-id>/skill:<name>`) and take part in
  /// session-scoped unique-alias resolution ([resolveAlias]).
  void addPluginRoot(String path, String pluginId) {
    if (path.trim().isEmpty || pluginId.trim().isEmpty) return;
    _roots.add(path);
    _pluginRoots[path] = pluginId;
  }

  void clearRoots() {
    _roots.clear();
    _pluginRoots.clear();
    _skills.clear();
  }

  Future<void> reload() async {
    _skills.clear();
    for (final root in _roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      await _scanDir(dir, pluginId: _pluginRoots[root]);
    }
    _skills.sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> _scanDir(
    Directory dir, {
    int depth = 0,
    String? pluginId,
    List<Skill>? output,
  }) async {
    final target = output ?? _skills;
    if (depth > kBundleScanMaxDepth) return;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is Directory) {
          if (depth + 1 > kBundleScanMaxDepth) continue;
          // Bundle: <name>/SKILL.md
          final skillMd = File('${entity.path}/SKILL.md');
          if (skillMd.existsSync()) {
            final s = await _parse(skillMd, entity.path, pluginId: pluginId);
            if (s != null) target.add(s);
            continue;
          }
          final agentMd = File('${entity.path}/AGENT.md');
          if (agentMd.existsSync()) {
            final s = await _parse(
              agentMd,
              entity.path,
              isAgent: true,
              pluginId: pluginId,
            );
            if (s != null) target.add(s);
            continue;
          }
          if (_basename(entity.path) == 'agents') {
            await _scanDir(
              entity,
              depth: depth + 1,
              pluginId: pluginId,
              output: target,
            );
            continue;
          }
          // Plugin bundles may nest below the conventional top-level
          // directory. Recurse safely; a directory containing SKILL.md was
          // already consumed as one bundle above.
          await _scanDir(
            entity,
            depth: depth + 1,
            pluginId: pluginId,
            output: target,
          );
        } else if (entity is File && entity.path.endsWith('.md')) {
          if (depth == 0 &&
              kNonSkillRootDocs.contains(_fileName(entity.path))) {
            continue;
          }
          final isAgent =
              entity.path.contains('/agents/') ||
              entity.path.contains('\\agents\\') ||
              _basename(dir.path) == 'agents';
          final s = await _parse(
            entity,
            entity.path,
            isAgent: isAgent,
            pluginId: pluginId,
          );
          if (s != null) target.add(s);
        }
      }
    } catch (_) {}
  }

  Future<Skill?> _parse(
    File file,
    String path, {
    bool isAgent = false,
    String? pluginId,
    String? declaredName,
    SkillContributionKind? kind,
    List<String>? declaredSupportingFiles,
  }) async {
    try {
      final raw = await file.readAsString();
      var name = _basename(path);
      var description = '';
      var whenToUse = '';
      var modelInvocable = true;
      var userInvocable = true;
      var allowedTools = <String>[];
      String? argumentHint;
      String? model;
      final frontmatter = <String, String>{};
      final content = stripMarkdownFrontmatter(raw);

      // Minimal YAML frontmatter: between leading --- fences.
      if (raw.startsWith('---')) {
        final end = raw.indexOf('\n---', 3);
        if (end > 0) {
          frontmatter.addAll(_parseFrontmatter(raw.substring(3, end)));
          for (final entry in frontmatter.entries) {
            final key = entry.key;
            final value = entry.value;
            switch (key) {
              case 'name':
                if (value.isNotEmpty) name = value;
              case 'description':
                description = value;
              case 'whenToUse':
                whenToUse = value;
              case 'disable-model-invocation':
                modelInvocable = value.toLowerCase() != 'true';
              case 'user-invocable':
                userInvocable = value.toLowerCase() == 'true';
              case 'allowed-tools' || 'allowed_tools' || 'tools':
                allowedTools = _parseToolList(value);
              case 'argument-hint' || 'argument_hint':
                argumentHint = value;
              case 'model':
                model = value;
            }
          }
        }
      }

      if (content.trim().isEmpty) return null;
      final resolvedIsAgent =
          isAgent ||
          path.contains('/agents/') ||
          path.contains('\\agents\\') ||
          _basename(file.parent.path) == 'agents';
      // A bundle (<dir>/SKILL.md) also ships supporting files; a flat
      // `<name>.md` skill has none.
      final bundleDir = _basename(file.path) == 'SKILL' ? file.parent : null;
      final resolvedKind =
          kind ??
          (resolvedIsAgent
              ? SkillContributionKind.agent
              : SkillContributionKind.skill);
      return Skill(
        name: declaredName ?? name,
        description: description,
        whenToUse: whenToUse,
        content: content,
        path: path,
        dirPath: file.parent.path,
        sourcePath: file.path,
        modelInvocable: modelInvocable,
        userInvocable: userInvocable,
        allowedTools: allowedTools,
        argumentHint: argumentHint,
        model: model,
        frontmatter: Map.unmodifiable(frontmatter),
        isAgent: resolvedKind == SkillContributionKind.agent,
        kind: resolvedKind,
        supportingFiles:
            declaredSupportingFiles ??
            (bundleDir == null ? const [] : scanBundleFiles(bundleDir)),
        pluginId: pluginId,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _scanPluginMount(
    PluginCatalogMount mount,
    List<Skill> output,
  ) async {
    final manifest = mount.manifest;
    if (!isCanonicalPluginId(manifest.id)) return;
    final root = Directory(mount.contentDir);
    final manifestRoot = Directory(manifest.rootPath);
    final String rootReal;
    final String manifestReal;
    try {
      if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return;
      }
      rootReal = root.resolveSymbolicLinksSync();
      manifestReal = manifestRoot.resolveSymbolicLinksSync();
    } catch (_) {
      return;
    }
    if (rootReal != manifestReal) return;

    Future<void> add(
      String owner,
      String name,
      String path,
      SkillContributionKind kind, {
      List<String> supportingFiles = const [],
    }) async {
      if (owner != manifest.id ||
          name.isEmpty ||
          !_pathMatchesKind(path, kind)) {
        return;
      }
      final file = _containedRegularFile(rootReal, path);
      if (file == null) return;
      final declaredSupporting = <String>[];
      if (kind == SkillContributionKind.skill) {
        final bundle = path.substring(0, path.lastIndexOf('/'));
        for (final supporting in supportingFiles) {
          if (supporting == path ||
              !supporting.startsWith('$bundle/') ||
              _containedRegularFile(rootReal, supporting) == null) {
            return;
          }
          declaredSupporting.add(supporting.substring(bundle.length + 1));
        }
      } else if (supportingFiles.isNotEmpty) {
        return;
      }
      final parsed = await _parse(
        file,
        file.path,
        isAgent: kind == SkillContributionKind.agent,
        pluginId: manifest.id,
        declaredName: name,
        kind: kind,
        declaredSupportingFiles: List.unmodifiable(declaredSupporting),
      );
      if (parsed != null) output.add(parsed);
    }

    for (final command in manifest.commands) {
      await add(
        command.pluginId,
        command.name,
        command.path,
        SkillContributionKind.command,
      );
    }
    for (final skill in manifest.skills) {
      await add(
        skill.pluginId,
        skill.name,
        skill.path,
        SkillContributionKind.skill,
        supportingFiles: skill.supportingFiles,
      );
    }
    for (final agent in manifest.agents) {
      await add(
        agent.pluginId,
        agent.name,
        agent.path,
        SkillContributionKind.agent,
      );
    }
  }

  bool _pathMatchesKind(String path, SkillContributionKind kind) {
    if (!_strictRelativePath(path)) return false;
    return switch (kind) {
      SkillContributionKind.command =>
        (path.startsWith('commands/') ||
                path.startsWith('.claude/commands/')) &&
            path.endsWith('.md') &&
            !path.endsWith('/SKILL.md') &&
            !path.endsWith('/AGENT.md'),
      SkillContributionKind.skill =>
        (path.startsWith('skills/') ||
                path.startsWith('.agents/skills/') ||
                path.startsWith('.claude/skills/') ||
                path.startsWith('.codex/skills/')) &&
            path.endsWith('/SKILL.md'),
      SkillContributionKind.agent =>
        (path.startsWith('agents/') ||
                path.startsWith('.agents/personas/') ||
                path.startsWith('.claude/agents/')) &&
            path.endsWith('.md'),
    };
  }

  File? _containedRegularFile(String rootReal, String relative) {
    if (!_strictRelativePath(relative)) return null;
    var current = rootReal;
    final parts = relative.split('/').where((part) => part.isNotEmpty);
    for (final part in parts) {
      current = '$current/$part';
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.link ||
          type == FileSystemEntityType.notFound) {
        return null;
      }
    }
    if (FileSystemEntity.typeSync(current, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    try {
      final real = File(current).resolveSymbolicLinksSync();
      if (!real.startsWith('$rootReal/')) return null;
      return File(real);
    } catch (_) {
      return null;
    }
  }

  bool _strictRelativePath(String path) =>
      isLexicallySafeRelPath(path) && !path.split('/').contains('..');

  String _basename(String path) {
    final noExt = path.endsWith('.md')
        ? path.substring(0, path.length - 3)
        : path;
    final idx = noExt.lastIndexOf('/');
    return idx < 0 ? noExt : noExt.substring(idx + 1);
  }

  String _fileName(String path) {
    final slash = path.lastIndexOf('/');
    final backslash = path.lastIndexOf('\\');
    final cut = slash > backslash ? slash : backslash;
    return cut < 0 ? path : path.substring(cut + 1);
  }

  Skill? find(String name) {
    for (final s in _skills) {
      if (s.name.toLowerCase() == name.toLowerCase()) return s;
    }
    return null;
  }

  /// Canonical §4.4 lookup: resolves `plugin:<plugin-id>/skill:<name>`
  /// (exact, case-sensitive — canonical ids are exact) to the loaded skill
  /// contributed by that plugin. Visibility/session enforcement belongs to
  /// the caller (the agent dispatch consults the contribution registry).
  Skill? findCanonical(String canonicalId) {
    for (final s in _skills) {
      if (s.canonicalId == canonicalId) return s;
    }
    return null;
  }

  /// Unique-alias resolution (spec §4.4): a bare alias resolves ONLY when
  /// exactly one loaded skill carries it. With several providers the
  /// result is ambiguous — [SkillAliasResolution.options] lists the exact
  /// provider ids and the caller must NOT execute/load any of them.
  ///
  /// An exact [Skill.providerId] (canonical §4.4 id or declaring path)
  /// always resolves uniquely to that one skill. [hiddenPluginIds] drops
  /// skills of plugins that are not visible to the querying session, so
  /// session-scoping can turn a globally-ambiguous alias unique.
  SkillAliasResolution resolveAlias(
    String alias, {
    Set<String> hiddenPluginIds = const {},
  }) {
    final visible = [
      for (final s in _skills)
        if (s.pluginId == null || !hiddenPluginIds.contains(s.pluginId)) s,
    ];
    return _resolveSkillAlias(visible, alias);
  }

  /// Parse a single SKILL.md file through the real frontmatter parser
  /// without registering a root. Production API used by the plugin
  /// adapters during inspection.
  Future<Skill?> parseContributionFile(File file) => _parse(file, file.path);

  /// Test seam: parse a single SKILL.md file through the real frontmatter
  /// parser without registering a root.
  Future<Skill?> parseForTest(File file, String path) =>
      parseContributionFile(file);

  /// Resolves [relativePath] against [skill]'s own directory and returns the
  /// file's UTF-8 content, or null when the path is unsafe (traversal,
  /// absolute, drive letter, symlink escape), missing, or unreadable.
  /// Content over [kSupportingFileMaxBytes] is truncated and followed by a
  /// note stating the original byte count.
  Future<String?> readSupportingFile(Skill skill, String relativePath) async {
    final base = skill.dirPath;
    if (base == null || base.isEmpty) return null;
    final String rootReal;
    try {
      rootReal = Directory(base).resolveSymbolicLinksSync();
    } catch (_) {
      return null;
    }
    final file = _containedRegularFile(rootReal, relativePath);
    if (file == null) return null;
    try {
      final bytes = await file.readAsBytes();
      if (bytes.length <= kSupportingFileMaxBytes) {
        return utf8.decode(bytes, allowMalformed: true);
      }
      final head = utf8.decode(
        bytes.sublist(0, kSupportingFileMaxBytes),
        allowMalformed: true,
      );
      return '$head\n\n[truncated: showing first $kSupportingFileMaxBytes '
          'of ${bytes.length} bytes]';
    } catch (_) {
      return null;
    }
  }

  /// Bundle-relative supporting files discovered for [skill]. Empty for flat
  /// skills and in-memory declarations.
  List<String> supportingFilesFor(Skill skill) =>
      List.unmodifiable(skill.supportingFiles);

  /// Catalog block injected into the system prompt.
  String catalogBlock({int maxDescChars = 500}) {
    return _catalogBlock(_skills, maxDescChars: maxDescChars);
  }
}

SkillAliasResolution _resolveSkillAlias(List<Skill> skills, String alias) {
  final query = alias.trim();
  if (query.isEmpty) return const SkillAliasResolution([]);
  for (final skill in skills) {
    if (skill.providerId == query) return SkillAliasResolution([skill]);
  }
  var bare = query;
  if (bare.startsWith('/')) bare = bare.substring(1);
  if (bare.isEmpty) return const SkillAliasResolution([]);
  final lower = bare.toLowerCase();
  final matches = [
    for (final skill in skills)
      if (skill.name.toLowerCase() == lower) skill,
  ]..sort((a, b) => a.providerId.compareTo(b.providerId));
  return SkillAliasResolution(matches);
}

String _catalogBlock(List<Skill> skills, {required int maxDescChars}) {
  final modelSkills = skills.where((skill) => skill.modelInvocable).toList();
  if (modelSkills.isEmpty) return '';
  final buf = StringBuffer()
    ..writeln(
      'AVAILABLE SKILLS (call the `skill` tool with a name to load full instructions):',
    );
  for (final skill in modelSkills) {
    final desc = skill.description.length > maxDescChars
        ? '${skill.description.substring(0, maxDescChars)}…'
        : skill.description;
    buf.writeln(
      '- `${skill.canonicalId ?? skill.name}`: $desc'
      '${skill.whenToUse.isEmpty ? '' : ' — ${skill.whenToUse}'}',
    );
  }
  return buf.toString();
}

({String token, String args})? parseSkillInvocation(String line) {
  if (!line.startsWith('/')) return null;
  final body = line.substring(1);
  final boundary = body.indexOf(RegExp(r'\s'));
  final token = (boundary < 0 ? body : body.substring(0, boundary)).trim();
  if (token.isEmpty) return null;
  final args = boundary < 0 ? '' : body.substring(boundary).trim();
  return (token: token, args: args);
}

/// Result of a bare-skill-alias resolution (spec §4.4: an alias exists only
/// when unique; an ambiguous alias yields the exact provider options and
/// executes nothing).
class SkillAliasResolution {
  /// Matching skills sorted by [Skill.providerId] (deterministic options).
  final List<Skill> matches;

  const SkillAliasResolution(this.matches);

  bool get isAbsent => matches.isEmpty;
  bool get isUnique => matches.length == 1;
  bool get isAmbiguous => matches.length > 1;
  Skill? get unique => isUnique ? matches.first : null;

  /// The exact provider ids an ambiguous-alias chooser must list:
  /// canonical §4.4 ids for plugin skills, declaring paths otherwise.
  List<String> get options =>
      List.unmodifiable(matches.map((m) => m.providerId));
}

/// Parses the body of a `---`-fenced frontmatter block into top-level
/// `key: value` pairs. Supports quoted and bare scalars (values may contain
/// colons), folded (`>`) and literal (`|`) block scalars, and a bare
/// `key:` followed by an indented `- item` block list (items are joined with
/// newlines so list consumers can split on whitespace).
Map<String, String> _parseFrontmatter(String block) {
  final result = <String, String>{};
  final lines = block.split('\n');
  var index = 0;
  while (index < lines.length) {
    final line = lines[index];
    index++;
    if (line.trim().isEmpty) continue;
    final match = RegExp(r'^([^:\s][^:]*):(.*)$').firstMatch(line);
    if (match == null) continue;
    final key = match.group(1)!.trim();
    final rest = match.group(2)!.trim();
    final folded = rest == '>' || rest == '>-' || rest == '>+';
    final literal = rest == '|' || rest == '|-' || rest == '|+';
    if (folded || literal) {
      final collected = <String>[];
      while (index < lines.length) {
        final next = lines[index];
        if (next.trim().isEmpty) {
          collected.add('');
          index++;
          continue;
        }
        if (!next.startsWith(' ') && !next.startsWith('\t')) break;
        collected.add(next.replaceFirst(RegExp(r'^[ \t]+'), ''));
        index++;
      }
      while (collected.isNotEmpty && collected.last.isEmpty) {
        collected.removeLast();
      }
      result[key] = literal
          ? collected.join('\n')
          : collected.where((entry) => entry.isNotEmpty).join(' ');
      continue;
    }
    if (rest.isEmpty) {
      final items = <String>[];
      final resume = index;
      while (index < lines.length) {
        final item = RegExp(r'^\s+-\s+(.*)$').firstMatch(lines[index]);
        if (item == null) break;
        items.add(_unquote(item.group(1)!.trim()));
        index++;
      }
      if (items.isNotEmpty) {
        result[key] = items.join('\n');
        continue;
      }
      index = resume;
    }
    result[key] = _unquote(rest);
  }
  return result;
}

String _unquote(String value) {
  if (value.length >= 2) {
    if (value.startsWith('"') && value.endsWith('"')) {
      return value.substring(1, value.length - 1);
    }
    if (value.startsWith("'") && value.endsWith("'")) {
      return value.substring(1, value.length - 1);
    }
  }
  return value;
}

List<String> _parseToolList(String value) {
  var body = value.trim();
  if (body.startsWith('[') && body.endsWith(']')) {
    body = body.substring(1, body.length - 1);
  }
  return body
      .split(RegExp(r'[,\s]+'))
      .map((entry) => entry.trim().replaceAll('"', '').replaceAll("'", ""))
      .where((entry) => entry.isNotEmpty)
      .toList();
}

/// Strips a leading `---`-fenced YAML frontmatter block and returns the
/// trimmed body; returns [raw] unchanged when there is no fenced block.
/// One shared rule for the skills scanner and the agent's canonical
/// plugin-contribution loader, so both return the same body.
String stripMarkdownFrontmatter(String raw) {
  if (!raw.startsWith('---')) return raw;
  final end = raw.indexOf('\n---', 3);
  if (end <= 0) return raw;
  return raw.substring(end + 4).trim();
}

/// Maximum directory depth a bundle walk will descend.
const int kBundleScanMaxDepth = 12;

/// Hard cap on bytes returned by [SkillService.readSupportingFile]; longer
/// content is truncated with an honest byte-count note.
const int kSupportingFileMaxBytes = 64 * 1024;

/// Documentation files that live directly in a scanned root and must never
/// be ingested as flat skills. Bundle files (`<dir>/SKILL.md`,
/// `<dir>/AGENT.md`) are unaffected — this only gates depth-0 `.md` files.
const Set<String> kNonSkillRootDocs = {
  'AGENTS.md',
  'README.md',
  'CHANGELOG.md',
  'CONTRIBUTING.md',
  'CODE_OF_CONDUCT.md',
  'LICENSE.md',
  'SECURITY.md',
};

/// Every non-`SKILL.md` file shipped inside a bundle directory, as sorted
/// `[dir]`-relative paths. A subdirectory containing its own `SKILL.md` is a
/// SEPARATE bundle (discovered independently by the root skills scan), so
/// its contents are never supporting material for this one and the whole
/// subtree is skipped.
///
/// Hardened for untrusted plugin payloads: symlinks are never followed
/// (`followLinks: false`) and any entry whose real path escapes [dir] is
/// dropped, so a crafted bundle cannot harvest files outside itself. The
/// walk stops at [kBundleScanMaxDepth] to bound pathological trees.
List<String> scanBundleFiles(Directory dir) {
  final String rootReal;
  try {
    rootReal = dir.resolveSymbolicLinksSync();
  } catch (_) {
    return const [];
  }
  final out = <String>[];

  void walk(Directory current, int depth) {
    if (depth > kBundleScanMaxDepth) return;
    final List<FileSystemEntity> entries;
    try {
      entries = current.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final entity in entries) {
      // With followLinks:false a symlink surfaces as a Link — never
      // traverse or record it, whatever it points at.
      if (entity is Link) continue;
      if (entity is Directory) {
        // Nested bundle: it ships its own SKILL.md, so everything under it
        // belongs to that bundle, not this one.
        if (File('${entity.path}/SKILL.md').existsSync()) continue;
        walk(entity, depth + 1);
        continue;
      }
      if (entity is! File) continue;
      final String real;
      try {
        real = entity.resolveSymbolicLinksSync();
      } catch (_) {
        continue;
      }
      // Containment: the real file must live under the real bundle root.
      if (!real.startsWith('$rootReal/')) continue;
      final rel = real.substring(rootReal.length + 1);
      if (rel == 'SKILL.md') continue;
      out.add(rel);
    }
  }

  walk(dir, 0);
  out.sort();
  return List.unmodifiable(out);
}
