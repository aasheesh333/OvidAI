import 'dart:io';

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

class Skill {
  final String name;
  final String description;
  final String whenToUse;
  final String content;
  final String path;
  final bool modelInvocable;
  final bool userInvocable;
  final List<String> allowedTools;
  final String? argumentHint;
  final String? model;
  final Map<String, String> frontmatter;
  final bool isAgent;

  /// Bundle-relative paths of every non-SKILL.md file that ships beside a
  /// bundled skill (templates, references, scripts). Empty for flat skills.
  /// Collected by a symlink-refusing, depth-limited, containment-checked
  /// walk so a bundle can never pull in a file outside its own directory.
  final List<String> supportingFiles;

  const Skill({
    required this.name,
    required this.description,
    required this.whenToUse,
    required this.content,
    required this.path,
    required this.modelInvocable,
    required this.userInvocable,
    this.allowedTools = const [],
    this.argumentHint,
    this.model,
    this.frontmatter = const {},
    this.isAgent = false,
    this.supportingFiles = const [],
  });

  /// Compact catalog line injected into the agent system context.
  String get catalogLine =>
      '- `$name`: ${description.isEmpty ? '(no description)' : description}'
      '${whenToUse.isEmpty ? '' : ' — use when: $whenToUse'}';
}

/// Loads skills from the filesystem with optional hot reload.
class SkillService {
  SkillService._();
  static final SkillService I = SkillService._();

  /// Test seam: a fresh isolated instance (private ctor is shared with I).
  SkillService.forTest() : this._();

  final List<Skill> _skills = [];
  final Set<String> _roots = {};

  List<Skill> get skills => List.unmodifiable(_skills);

  /// Skills the user can invoke from the composer with `/name` or the
  /// slash suggestion menu.
  List<Skill> get userSkills =>
      List.unmodifiable(_skills.where((s) => s.userInvocable));

  /// Discovered agent persona definitions.
  List<Skill> get agents =>
      List.unmodifiable(_skills.where((s) => s.isAgent));

  /// Register a search root (workspace, custom dirs, etc).
  void addRoot(String path) {
    if (path.trim().isEmpty) return;
    _roots.add(path);
  }

  void clearRoots() {
    _roots.clear();
    _skills.clear();
  }

  Future<void> reload() async {
    _skills.clear();
    for (final root in _roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      await _scanDir(dir);
    }
    _skills.sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> _scanDir(Directory dir, {int depth = 0}) async {
    if (depth > kBundleScanMaxDepth) return;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is Directory) {
          if (depth + 1 > kBundleScanMaxDepth) continue;
          // Bundle: <name>/SKILL.md
          final skillMd = File('${entity.path}/SKILL.md');
          if (skillMd.existsSync()) {
            final s = await _parse(skillMd, entity.path);
            if (s != null) _skills.add(s);
            continue;
          }
          final agentMd = File('${entity.path}/AGENT.md');
          if (agentMd.existsSync()) {
            final s = await _parse(agentMd, entity.path, isAgent: true);
            if (s != null) _skills.add(s);
            continue;
          }
          if (_basename(entity.path) == 'agents') {
            await _scanDir(entity, depth: depth + 1);
            continue;
          }
          // Plugin bundles may nest below the conventional top-level
          // directory. Recurse safely; a directory containing SKILL.md was
          // already consumed as one bundle above.
          await _scanDir(entity, depth: depth + 1);
        } else if (entity is File && entity.path.endsWith('.md')) {
          final isAgent = entity.path.contains('/agents/') ||
              entity.path.contains('\\agents\\') ||
              _basename(dir.path) == 'agents';
          final s = await _parse(entity, entity.path, isAgent: isAgent);
          if (s != null) _skills.add(s);
        }
      }
    } catch (_) {}
  }

  Future<Skill?> _parse(File file, String path, {bool isAgent = false}) async {
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
      var content = raw;

      // Minimal YAML frontmatter: between leading --- fences.
      if (raw.startsWith('---')) {
        final end = raw.indexOf('\n---', 3);
        if (end > 0) {
          final fm = raw.substring(3, end);
          content = raw.substring(end + 4).trim();
          for (final line in fm.split('\n')) {
            final idx = line.indexOf(':');
            if (idx < 0) continue;
            final key = line.substring(0, idx).trim();
            var value = line.substring(idx + 1).trim();
            if (value.startsWith('"') && value.endsWith('"')) {
              value = value.substring(1, value.length - 1);
            } else if (value.startsWith("'") && value.endsWith("'")) {
              value = value.substring(1, value.length - 1);
            }
            frontmatter[key] = value;
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
                var s = value;
                if (s.startsWith('[') && s.endsWith(']')) {
                  s = s.substring(1, s.length - 1);
                }
                allowedTools = s
                    .split(',')
                    .map((e) => e.trim().replaceAll('"', '').replaceAll("'", ""))
                    .where((e) => e.isNotEmpty)
                    .toList();
              case 'argument-hint' || 'argument_hint':
                argumentHint = value;
              case 'model':
                model = value;
            }
          }
        }
      }

      if (content.trim().isEmpty) return null;
      final resolvedIsAgent = isAgent ||
          path.contains('/agents/') ||
          path.contains('\\agents\\') ||
          _basename(file.parent.path) == 'agents';
      // A bundle (<dir>/SKILL.md) also ships supporting files; a flat
      // `<name>.md` skill has none.
      final bundleDir = _basename(file.path) == 'SKILL'
          ? file.parent
          : null;
      return Skill(
        name: name,
        description: description,
        whenToUse: whenToUse,
        content: content,
        path: path,
        modelInvocable: modelInvocable,
        userInvocable: userInvocable,
        allowedTools: allowedTools,
        argumentHint: argumentHint,
        model: model,
        frontmatter: frontmatter,
        isAgent: resolvedIsAgent,
        supportingFiles:
            bundleDir == null ? const [] : scanBundleFiles(bundleDir),
      );
    } catch (_) {
      return null;
    }
  }

  String _basename(String path) {
    final noExt = path.endsWith('.md') ? path.substring(0, path.length - 3) : path;
    final idx = noExt.lastIndexOf('/');
    return idx < 0 ? noExt : noExt.substring(idx + 1);
  }


  Skill? find(String name) {
    for (final s in _skills) {
      if (s.name.toLowerCase() == name.toLowerCase()) return s;
    }
    return null;
  }

  /// Test seam: parse a single SKILL.md file through the real frontmatter
  /// parser without registering a root.
  Future<Skill?> parseForTest(File file, String path) => _parse(file, path);

  /// Catalog block injected into the system prompt.
  String catalogBlock({int maxDescChars = 500}) {
    if (_skills.isEmpty) return '';
    final buf = StringBuffer()
      ..writeln('AVAILABLE SKILLS (call the `skill` tool with a name to load full instructions):');
    for (final s in _skills.where((s) => s.modelInvocable)) {
      final desc = s.description.length > maxDescChars
          ? '${s.description.substring(0, maxDescChars)}…'
          : s.description;
      buf.writeln('- `${s.name}`: $desc'
          '${s.whenToUse.isEmpty ? '' : ' — ${s.whenToUse}'}');
    }
    return buf.toString();
  }
}

/// Maximum directory depth a bundle walk will descend.
const int kBundleScanMaxDepth = 12;

/// Every non-`SKILL.md` file shipped inside a bundle directory, as sorted
/// `[dir]`-relative paths.
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
