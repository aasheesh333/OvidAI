import 'dart:convert';
import 'dart:io';

import 'mcp_config_parse.dart';
import 'plugin_manifest.dart';
import 'skills.dart';
import 'state.dart' show shellSplitArgs;

/// ── Plugin compatibility adapters ───────────────────────────────────────
/// Adapt a [CC] plugin tree, a Codex plugin tree, or a bare MCP config
/// into the one [NormalizedPluginManifest] the rest of Ovid runs on
/// (design spec §4.2-§4.3).
///
/// Adapters are read-only: source files are parsed, never rewritten.
/// Unrecognized fields are preserved in `unknownFields` so a newer plugin
/// manifest never loses information, and unsupported behavior is reported
/// as a [CompatibilityIssue] — optional findings degrade, required ones
/// fail the install before activation.
///
/// Secret hygiene (spec §5.1): MCP records are built ONLY through
/// [PluginMcpServer.scrubbedRaw], so env/header VALUES are stripped and
/// only their NAMES survive into persisted metadata.

/// Actionable message for SSE-only MCP definitions (spec §4.3). SSE is not
/// a supported transport; Streamable HTTP replaces it.
const String kSseUnsupportedMessage =
    'SSE transport is not supported. Use Streamable HTTP instead: replace '
    '"type": "sse" with "type": "http" and point "url" at the server\'s '
    'Streamable HTTP endpoint.';

/// Canonical hook event for a [CC]/Codex/legacy-Ovid event name, or null
/// when the name maps to nothing this runtime can fire (spec §8.1).
String? canonicalHookEvent(String raw) {
  final key = raw.trim();
  if (key.isEmpty) return null;
  if (PluginHook.canonicalEvents.contains(key)) return key;
  const map = <String, String>{
    // Legacy Ovid aliases.
    'on_session_start': 'session_start',
    'on_pre_request': 'pre_request',
    'on_pre_tool': 'pre_tool',
    'on_post_tool': 'post_tool',
    // `on_turn_*` have no literal §8.1 name; these are their turn-lifecycle
    // equivalents.
    'on_turn_start': 'user_prompt_submit',
    'on_turn_end': 'stop',
    // [CC] native event names.
    'PreToolUse': 'pre_tool',
    'PostToolUse': 'post_tool',
    'PostToolUseFailure': 'post_tool',
    'UserPromptSubmit': 'user_prompt_submit',
    'Notification': 'notification',
    'Stop': 'stop',
    'SubagentStart': 'subagent_start',
    'SubagentStop': 'subagent_end',
    'SessionStart': 'session_start',
    'SessionEnd': 'session_end',
    'PreCompact': 'pre_compact',
    'PostCompact': 'post_compact',
    'PermissionRequest': 'permission_request',
  };
  return map[key];
}

/// Slug used for a contribution name: lowercase, non-alphanumerics collapsed
/// to `-`. Keeps canonical IDs stable and shell-safe (spec §4.4).
String _slug(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

/// Frontmatter keys the normalized contribution models already carry — the
/// rest are preserved verbatim as `unknownFields`.
const _knownFrontmatterKeys = {
  'name',
  'description',
  'whenToUse',
  'disable-model-invocation',
  'user-invocable',
  'allowed-tools',
  'allowed_tools',
  'tools',
  'argument-hint',
  'argument_hint',
  'model',
};

Map<String, dynamic> _unknownFrontmatter(Map<String, String> frontmatter) => {
  for (final e in frontmatter.entries)
    if (!_knownFrontmatterKeys.contains(e.key)) e.key: e.value,
};

/// Recursively collect files matching [test] under [dir], depth-bounded and
/// refusing symlinks so an untrusted tree cannot escape itself.
List<File> _filesUnder(Directory dir, bool Function(File) test) {
  if (!dir.existsSync()) return const [];
  final root = dir.resolveSymbolicLinksSync();
  final out = <File>[];
  void walk(Directory current, int depth) {
    if (depth > kBundleScanMaxDepth) return;
    final List<FileSystemEntity> entries;
    try {
      entries = current.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final e in entries) {
      if (e is Link) continue;
      if (e is Directory) {
        walk(e, depth + 1);
      } else if (e is File && test(e)) {
        try {
          final real = e.resolveSymbolicLinksSync();
          if (real.startsWith('$root/')) out.add(e);
        } catch (_) {}
      }
    }
  }

  walk(dir, 0);
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

String _relative(Directory root, String path) {
  final base = root.path.endsWith('/') ? root.path : '${root.path}/';
  return path.startsWith(base) ? path.substring(base.length) : path;
}

Map<String, dynamic> _readJsonMap(File file) {
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    return decoded is Map ? decoded.cast<String, dynamic>() : const {};
  } catch (_) {
    return const {};
  }
}

/// Accumulates contributions while adapting one source tree.
class _Build {
  final String pluginId;
  final Directory root;
  final commands = <PluginCommand>[];
  final skills = <PluginSkill>[];
  final agents = <PluginAgent>[];
  final hooks = <PluginHook>[];
  final mcpServers = <PluginMcpServer>[];
  final dependencies = <PluginDependency>[];
  final issues = <CompatibilityIssue>[];
  final unknown = <String, dynamic>{};
  final envNames = <String>{};

  _Build(this.pluginId, this.root);
}

/// Parse markdown contributions (commands/agents) from [dir].
Future<void> _addMarkdown(
  _Build b,
  Directory dir, {
  required bool asAgent,
}) async {
  for (final file in _filesUnder(dir, (f) => f.path.endsWith('.md'))) {
    final skill = await SkillService.forTest().parseForTest(file, file.path);
    if (skill == null) continue;
    final rel = _relative(b.root, file.path);
    final name = _slug(skill.name);
    if (name.isEmpty) continue;
    final frontmatter = <String, dynamic>{...skill.frontmatter};
    final unknownFields = _unknownFrontmatter(skill.frontmatter);
    if (asAgent) {
      b.agents.add(
        PluginAgent(
          pluginId: b.pluginId,
          name: name,
          path: rel,
          frontmatter: Map.unmodifiable(frontmatter),
          unknownFields: Map.unmodifiable(unknownFields),
        ),
      );
    } else {
      b.commands.add(
        PluginCommand(
          pluginId: b.pluginId,
          name: name,
          path: rel,
          frontmatter: Map.unmodifiable(frontmatter),
          unknownFields: Map.unmodifiable(unknownFields),
        ),
      );
    }
  }
}

/// Parse `<dir>/**/SKILL.md` bundles plus their supporting files.
Future<void> _addSkills(_Build b, Directory dir) async {
  for (final file in _filesUnder(dir, (f) => f.path.endsWith('/SKILL.md'))) {
    final skill = await SkillService.forTest().parseForTest(file, file.path);
    if (skill == null) continue;
    final name = _slug(skill.name);
    if (name.isEmpty) continue;
    b.skills.add(
      PluginSkill(
        pluginId: b.pluginId,
        name: name,
        path: _relative(b.root, file.path),
        supportingFiles: List.unmodifiable([
          for (final rel in scanBundleFiles(file.parent))
            _relative(b.root, '${file.parent.path}/$rel'),
        ]),
        frontmatter: Map.unmodifiable({...skill.frontmatter}),
        unknownFields: Map.unmodifiable(_unknownFrontmatter(skill.frontmatter)),
      ),
    );
  }
}

/// Normalize one `hooks.json`-style event map into ordered [PluginHook]s.
void _addHooks(_Build b, Map<String, dynamic> hooksJson, String sourcePath) {
  final events = hooksJson['hooks'];
  for (final e in hooksJson.entries) {
    if (e.key == 'hooks') continue;
    b.unknown['hooks.${e.key}'] = e.value;
  }
  if (events is! Map) return;
  var ordinal = 0;

  void add({
    required String event,
    required String type,
    required String payload,
    String? matcher,
    int timeoutS = 0,
    Map<String, dynamic> unknownFields = const {},
    Map<String, dynamic> frontmatter = const {},
  }) {
    b.hooks.add(
      PluginHook(
        pluginId: b.pluginId,
        event: event,
        ordinal: ordinal++,
        type: type,
        payload: payload,
        matcher: matcher,
        timeoutS: timeoutS,
        path: sourcePath,
        frontmatter: Map.unmodifiable(frontmatter),
        unknownFields: Map.unmodifiable(unknownFields),
      ),
    );
  }

  for (final entry in events.entries) {
    final rawEvent = entry.key.toString();
    final event = canonicalHookEvent(rawEvent);
    if (event == null) {
      b.issues.add(
        CompatibilityIssue(
          severity: CompatibilitySeverity.optional,
          message:
              'Hook event "$rawEvent" is not supported by Ovid and was skipped.',
          fields: ['hooks.$rawEvent'],
        ),
      );
      continue;
    }
    final value = entry.value;
    // Shorthand: "event": "command string".
    if (value is String) {
      add(event: event, type: 'command', payload: value);
      continue;
    }
    if (value is! List) continue;
    for (final group in value) {
      if (group is! Map) continue;
      final matcher = (group['matcher'] as String?)?.trim();
      final inner = group['hooks'];
      if (inner is! List) continue;
      for (final hook in inner) {
        if (hook is! Map) continue;
        final map = hook.cast<String, dynamic>();
        final type = (map['type'] as String?)?.trim().isNotEmpty == true
            ? (map['type'] as String).trim()
            : 'command';
        final payload =
            (map['command'] as String?) ?? (map['prompt'] as String?) ?? '';
        add(
          event: event,
          type: type,
          payload: payload,
          matcher: matcher != null && matcher.isNotEmpty ? matcher : null,
          timeoutS: (map['timeout'] as num?)?.toInt() ?? 0,
          frontmatter: {...group.cast<String, dynamic>()}..remove('hooks'),
          unknownFields: {
            for (final e in map.entries)
              if (!const {
                'type',
                'command',
                'prompt',
                'timeout',
              }.contains(e.key))
                e.key: e.value,
          },
        );
      }
    }
  }
}

/// Map parsed MCP entries into scrubbed [PluginMcpServer] records, adding a
/// required-severity issue for unsupported SSE definitions.
void _addMcp(
  _Build b,
  List<ImportedMcp> parsed,
  String sourcePath, {
  Map<String, dynamic> rawByName = const {},
}) {
  for (final s in parsed) {
    if (s.type == 'sse') {
      b.issues.add(
        CompatibilityIssue(
          severity: CompatibilitySeverity.required,
          message: kSseUnsupportedMessage,
          fields: ['$sourcePath:${s.name}'],
        ),
      );
      continue;
    }
    final raw = rawByName[s.name] ?? s.ignoredFields;
    b.mcpServers.add(
      PluginMcpServer.scrubbedRaw(
        pluginId: b.pluginId,
        name: s.name,
        rawDeclaration: raw is Map ? raw.cast<String, dynamic>() : const {},
        transport: s.type,
        command: s.command,
        args: s.args,
        url: s.url,
        cwd: s.cwd,
        envNames: s.env.keys.toList(),
        headerNames: s.headers.keys.toList(),
        path: sourcePath,
      ),
    );
    b.envNames.addAll(s.env.keys);
  }
}

/// npm + Python dependency manifests (spec §6).
void _addDependencies(_Build b) {
  final pkg = File('${b.root.path}/package.json');
  if (pkg.existsSync()) {
    final j = _readJsonMap(pkg);
    void addAll(String key, bool required) {
      final m = j[key];
      if (m is! Map) return;
      for (final e in m.entries) {
        b.dependencies.add(
          PluginDependency(
            name: e.key.toString(),
            versionSpec: e.value.toString(),
            kind: PluginDependencyKind.npm,
            required: required,
          ),
        );
      }
    }

    addAll('dependencies', true);
    addAll('optionalDependencies', false);
  }

  final reqs = File('${b.root.path}/requirements.txt');
  if (reqs.existsSync()) {
    for (var line in reqs.readAsLinesSync()) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final m = RegExp(r'^([A-Za-z0-9._-]+)\s*(.*)$').firstMatch(line);
      if (m == null) continue;
      b.dependencies.add(
        PluginDependency(
          name: m.group(1)!,
          versionSpec: m.group(2)!.trim(),
          kind: PluginDependencyKind.python,
        ),
      );
    }
  }

  final pyproject = File('${b.root.path}/pyproject.toml');
  if (pyproject.existsSync()) {
    final text = pyproject.readAsStringSync();
    final block = RegExp(
      r'dependencies\s*=\s*\[(.*?)\]',
      dotAll: true,
    ).firstMatch(text);
    if (block != null) {
      for (final m in RegExp(
        '''['"]([^'"]+)['"]''',
      ).allMatches(block.group(1)!)) {
        final spec = m.group(1)!.trim();
        final name = RegExp(r'^([A-Za-z0-9._-]+)').firstMatch(spec)?.group(1);
        if (name == null) continue;
        b.dependencies.add(
          PluginDependency(
            name: name,
            versionSpec: spec.substring(name.length).trim(),
            kind: PluginDependencyKind.python,
          ),
        );
      }
    }
  }
}

/// Spec §4.3/§4.4: the manifest `id` is the stable `publisher/name`
/// identity every contribution's canonical registry key is built on — an
/// EMPTY publisher segment makes that identity invalid. Empty-publisher
/// validation is pinned by the adapters as a REQUIRED finding, so
/// inspection/install fails before activation.
void _requirePublisherIdentity(_Build b, String idField) {
  if (!b.pluginId.startsWith('/')) return;
  b.issues.add(
    CompatibilityIssue(
      severity: CompatibilitySeverity.required,
      message: 'Invalid plugin identity: $idField declares no publisher, so '
          'the canonical id "publisher/name" has an empty publisher segment.',
      fields: [idField],
    ),
  );
}

/// Derive the minimum capability set from what the manifest actually
/// declares (spec §5.1) — never a blanket grant.
Set<PluginCapability> _inferCapabilities(_Build b) {
  final caps = <PluginCapability>{};
  if (b.commands.isNotEmpty || b.skills.isNotEmpty || b.agents.isNotEmpty) {
    caps.add(PluginCapability.workspaceRead);
  }
  for (final h in b.hooks) {
    caps.add(PluginCapability.hooksObserve);
    if (h.type == 'command') caps.add(PluginCapability.shellExecute);
    if (h.canBlock) caps.add(PluginCapability.hooksBlock);
  }
  for (final s in b.mcpServers) {
    caps.add(PluginCapability.mcpRegister);
    if (s.transport == 'stdio') caps.add(PluginCapability.processSpawn);
    if (s.transport == 'http') caps.add(PluginCapability.networkConnect);
  }
  if (b.envNames.isNotEmpty) caps.add(PluginCapability.environmentRead);
  return caps;
}

NormalizedPluginManifest _finish(
  _Build b, {
  required String name,
  required String version,
  required PluginFormat format,
}) {
  // Round-tripping through the model's defensive decoder freezes all nested
  // maps/lists as well as the top-level collections before publication.
  return NormalizedPluginManifest.fromJson(
    NormalizedPluginManifest(
      id: b.pluginId,
      name: name,
      version: version,
      format: format,
      rootPath: b.root.path,
      commands: List.unmodifiable(b.commands),
      skills: List.unmodifiable(b.skills),
      agents: List.unmodifiable(b.agents),
      hooks: List.unmodifiable(b.hooks),
      mcpServers: List.unmodifiable(b.mcpServers),
      dependencies: PluginDependencies(
        packages: List.unmodifiable(b.dependencies),
      ),
      requestedCapabilities: Set.unmodifiable(_inferCapabilities(b)),
      environmentReadNames: Set.unmodifiable(b.envNames),
      unknownFields: Map.unmodifiable(b.unknown),
      compatibility: List.unmodifiable(b.issues),
    ).toJson(),
  );
}

/// Fields `.claude-plugin/plugin.json` contributes to the normalized model —
/// everything else is preserved as `unknownFields`.
const _knownClaudeManifestKeys = {
  'name',
  'version',
  'author',
  'description',
  'homepage',
  'license',
  'keywords',
};

/// Adapts a [CC]-shaped plugin tree (spec §4.3).
class ClaudePluginAdapter {
  const ClaudePluginAdapter();

  Future<NormalizedPluginManifest> inspect(Directory root) async {
    final manifestFile = File('${root.path}/.claude-plugin/plugin.json');
    final j = _readJsonMap(manifestFile);
    final name = (j['name'] as String?)?.trim() ?? '';
    final author = j['author'];
    final publisher = author is Map
        ? (author['name'] as String?) ?? ''
        : (author as String?) ?? '';

    final b = _Build(
      NormalizedPluginManifest.canonicalId(publisher, name),
      root,
    );
    for (final e in j.entries) {
      if (!_knownClaudeManifestKeys.contains(e.key)) b.unknown[e.key] = e.value;
    }
    _requirePublisherIdentity(b, '.claude-plugin/plugin.json:author');

    await _addMarkdown(b, Directory('${root.path}/commands'), asAgent: false);
    await _addSkills(b, Directory('${root.path}/skills'));
    await _addMarkdown(b, Directory('${root.path}/agents'), asAgent: true);

    final hooksFile = File('${root.path}/hooks/hooks.json');
    if (hooksFile.existsSync()) {
      _addHooks(b, _readJsonMap(hooksFile), 'hooks/hooks.json');
    }

    final mcpFile = File('${root.path}/.mcp.json');
    if (mcpFile.existsSync()) {
      final raw = _readJsonMap(mcpFile);
      final servers = raw['mcpServers'] ?? raw['mcp_servers'] ?? raw['servers'];
      for (final e in raw.entries) {
        if (!const {'mcpServers', 'mcp_servers', 'servers'}.contains(e.key)) {
          b.unknown['mcp.${e.key}'] = scrubMcpSecrets(
            e.value is Map ? e.value.cast<String, dynamic>() : <String, dynamic>{'value': e.value},
          ).scrubbed;
        }
      }
      _addMcp(
        b,
        parseMcpConfig(mcpFile.readAsStringSync()),
        '.mcp.json',
        rawByName: servers is Map ? servers.cast<String, dynamic>() : const {},
      );
    }

    _addDependencies(b);
    return _finish(
      b,
      name: name,
      version: (j['version'] as String?) ?? '',
      format: PluginFormat.claudeCode,
    );
  }
}

/// Adapts a Codex-shaped plugin tree (spec §4.3).
class CodexPluginAdapter {
  const CodexPluginAdapter();

  Future<NormalizedPluginManifest> inspect(Directory root) async {
    final configFile = File('${root.path}/config.toml');
    final config = configFile.existsSync()
        ? configFile.readAsStringSync()
        : '';
    String scalar(String key) {
      final m = RegExp(
        '^\\s*$key\\s*=\\s*(.+)\$',
        multiLine: true,
      ).firstMatch(config);
      return m == null ? '' : unquoteToml(m.group(1)!.trim());
    }

    final name = scalar('name');
    final b = _Build(
      NormalizedPluginManifest.canonicalId(scalar('publisher'), name),
      root,
    );
    _requirePublisherIdentity(b, 'config.toml:publisher');

    // Root + nested AGENTS.md instruction files.
    final instructions = [
      for (final f in _filesUnder(root, (f) => f.path.endsWith('/AGENTS.md')))
        _relative(root, f.path),
    ]..sort((a, b) => a.split('/').length.compareTo(b.split('/').length));
    if (instructions.isNotEmpty) b.unknown['instructionPaths'] = instructions;

    // Unrecognized top-level config scalars are preserved.
    for (final m in RegExp(
      r'^\s*([A-Za-z0-9_]+)\s*=\s*(.+)$',
      multiLine: true,
    ).allMatches(config.split(RegExp(r'^\[', multiLine: true)).first)) {
      final key = m.group(1)!;
      if (const {'name', 'version', 'publisher'}.contains(key)) continue;
      b.unknown['config.$key'] = unquoteToml(m.group(2)!.trim());
    }

    await _addSkills(b, Directory('${root.path}/.agents/skills'));
    await _addMarkdown(
      b,
      Directory('${root.path}/.agents/personas'),
      asAgent: true,
    );

    if (config.isNotEmpty) {
      _addMcp(b, parseMcpConfig(config), 'config.toml');
      // `[environment]` names are read by the plugin at runtime; values are
      // secrets and are never captured.
      var inEnvironment = false;
      for (final line in config.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.startsWith('[')) {
          inEnvironment = trimmed == '[environment]';
          continue;
        }
        if (inEnvironment) {
          final match = RegExp(r'^([A-Za-z0-9_]+)\s*=').firstMatch(trimmed);
          if (match != null) b.envNames.add(match.group(1)!);
        }
      }
    }

    _addDependencies(b);
    return _finish(
      b,
      name: name,
      version: scalar('version'),
      format: PluginFormat.codex,
    );
  }
}

/// Adapts a bare MCP config blob (pasted JSON/TOML, a direct command, or a
/// Streamable HTTP URL) into an MCP-only manifest (spec §4.2).
class GenericMcpAdapter {
  const GenericMcpAdapter();

  NormalizedPluginManifest inspectConfig(
    String raw, {
    required String sourceId,
  }) {
    final b = _Build(
      NormalizedPluginManifest.canonicalId('mcp', sourceId),
      Directory('.'),
    );

    var parsed = parseMcpConfig(raw);
    var rawByName = <String, dynamic>{};
    Map<String, dynamic> decoded = const {};
    try {
      final d = jsonDecode(raw);
      if (d is Map) decoded = d.cast<String, dynamic>();
    } catch (_) {}
    final servers =
        decoded['mcpServers'] ?? decoded['mcp_servers'] ?? decoded['servers'];
    if (servers is Map) rawByName = servers.cast<String, dynamic>();
    for (final e in decoded.entries) {
      if (!const {'mcpServers', 'mcp_servers', 'servers'}.contains(e.key)) {
        final value = e.value;
        b.unknown['mcp.${e.key}'] = value is Map
            ? scrubMcpSecrets(value.cast<String, dynamic>()).scrubbed
            : value;
      }
    }

    // A direct `{"command": ...}` / `{"url": ...}` definition names itself
    // after the source.
    if (parsed.isEmpty &&
        (decoded.containsKey('command') || decoded.containsKey('url'))) {
      parsed = [importedMcpFromJson(_slug(sourceId), decoded)];
    }
    if (parsed.isEmpty) {
      final trimmed = raw.trim();
      if (RegExp(r'^https?://').hasMatch(trimmed)) {
        parsed = [
          ImportedMcp(
            name: _slug(sourceId),
            command: '',
            args: const [],
            url: trimmed,
            type: 'http',
          ),
        ];
      } else if (trimmed.isNotEmpty && !trimmed.startsWith('[')) {
        final args = shellSplitArgs(trimmed);
        if (args.isNotEmpty) {
          parsed = [
            ImportedMcp(
              name: _slug(sourceId),
              command: args.first,
              args: args.skip(1).toList(),
            ),
          ];
        }
      }
    }

    _addMcp(b, parsed, sourceId, rawByName: rawByName);
    return _finish(
      b,
      name: sourceId,
      version: '',
      format: PluginFormat.genericMcp,
    );
  }
}

/// Picks the adapter matching a source tree's markers (spec §4.3).
class PluginAdapterRegistry {
  const PluginAdapterRegistry();

  Future<NormalizedPluginManifest> inspect(Directory root) async {
    if (File('${root.path}/.claude-plugin/plugin.json').existsSync() ||
        File('${root.path}/.claude-plugin/marketplace.json').existsSync()) {
      return const ClaudePluginAdapter().inspect(root);
    }
    if (File('${root.path}/AGENTS.md').existsSync() ||
        File('${root.path}/config.toml').existsSync() ||
        Directory('${root.path}/.agents').existsSync()) {
      return const CodexPluginAdapter().inspect(root);
    }
    final mcp = File('${root.path}/.mcp.json');
    if (mcp.existsSync()) {
      return const GenericMcpAdapter().inspectConfig(
        mcp.readAsStringSync(),
        sourceId: _relative(root.parent, root.path),
      );
    }
    return const ClaudePluginAdapter().inspect(root);
  }
}
