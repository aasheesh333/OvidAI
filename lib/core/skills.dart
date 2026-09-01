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

  const Skill({
    required this.name,
    required this.description,
    required this.whenToUse,
    required this.content,
    required this.path,
    required this.modelInvocable,
    required this.userInvocable,
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

  final List<Skill> _skills = [];
  final Set<String> _roots = {};

  List<Skill> get skills => List.unmodifiable(_skills);

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

  Future<void> _scanDir(Directory dir) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is Directory) {
          // Bundle: <name>/SKILL.md
          final skillMd = File('${entity.path}/SKILL.md');
          if (skillMd.existsSync()) {
            final s = await _parse(skillMd, entity.path);
            if (s != null) _skills.add(s);
            continue;
          }
          // Nested directories with **/SKILL.md are excluded (spec parity).
        } else if (entity is File && entity.path.endsWith('.md')) {
          final s = await _parse(entity, entity.path);
          if (s != null) _skills.add(s);
        }
      }
    } catch (_) {}
  }

  Future<Skill?> _parse(File file, String path) async {
    try {
      final raw = await file.readAsString();
      final name = _basename(path);
      var description = '';
      var whenToUse = '';
      var modelInvocable = true;
      var userInvocable = true;
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
            }
            switch (key) {
              case 'name':
                description = value; // placeholder if no name field; overridden below
              case 'description':
                description = value;
              case 'whenToUse':
                whenToUse = value;
              case 'disable-model-invocation':
                modelInvocable = value.toLowerCase() != 'true';
              case 'user-invocable':
                userInvocable = value.toLowerCase() == 'true';
            }
          }
        }
      }

      if (content.trim().isEmpty) return null;
      return Skill(
        name: name,
        description: description,
        whenToUse: whenToUse,
        content: content,
        path: path,
        modelInvocable: modelInvocable,
        userInvocable: userInvocable,
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
