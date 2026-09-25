import 'dart:convert';
import 'dart:io';

import 'mcp_config_parse.dart';
import 'plugin_manifest.dart';
import 'plugin_permissions.dart';
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

/// Legacy note (kept for API stability): SSE-only MCP definitions used to
/// be rejected with this message before the legacy SSE transport was
/// implemented in [McpService]. No longer emitted.
@Deprecated('SSE transport is now supported; this message is not emitted.')
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

String _basename(String path) {
  final p = path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  final i = p.lastIndexOf('/');
  return i >= 0 && i < p.length - 1 ? p.substring(i + 1) : p;
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

  /// Default-enable choice, derived during inspection (see [_finish]):
  /// true unless the source manifest explicitly opts out with
  /// `enabledByDefault: false`. An explicitly installed plugin is on by
  /// default — the flag only lets a manifest author ship "installed but
  /// off until the user enables it".
  bool enabledByDefault = true;

  /// Per-event hook ordinals — [PluginHook.ordinal] is the manifest-order
  /// index WITHIN its event, not a global counter across all events.
  final hookOrdinals = <String, int>{};

  _Build(this.pluginId, this.root);
}

/// Parse markdown contributions (commands/agents) from [dir].
Future<void> _addMarkdown(
  _Build b,
  Directory dir, {
  required bool asAgent,
}) async {
  for (final file in _filesUnder(dir, (f) => f.path.endsWith('.md'))) {
    final skill = await SkillService.I.parseContributionFile(file);
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
    final skill = await SkillService.I.parseContributionFile(file);
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

  void add({
    required String event,
    required String type,
    required String payload,
    String? matcher,
    int timeoutS = 0,
    Map<String, dynamic> unknownFields = const {},
    Map<String, dynamic> frontmatter = const {},
  }) {
    // Manifest-order index WITHIN the event (per the PluginHook.ordinal
    // contract), not a global counter across events.
    final ordinal = b.hookOrdinals[event] ?? 0;
    b.hookOrdinals[event] = ordinal + 1;
    // A `shell` naming an interpreter the sandbox doesn't guarantee
    // degrades to bash with a visible note (honored in HookService._exec).
    final shellDecl = unknownFields['shell'];
    if (shellDecl is String &&
        shellDecl.trim().isNotEmpty &&
        !kKnownHookShells.contains(shellDecl.trim())) {
      b.issues.add(
        CompatibilityIssue(
          severity: CompatibilitySeverity.optional,
          message:
              'Hook shell "${shellDecl.trim()}" is not supported by the '
              'sandbox; the hook runs under bash instead.',
          fields: ['hooks.$event'],
        ),
      );
    }
    b.hooks.add(
      PluginHook(
        pluginId: b.pluginId,
        event: event,
        ordinal: ordinal,
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
    // A single matcher-object (non-array) is wrapped rather than dropped.
    final List<dynamic> groups;
    if (value is Map) {
      groups = [value];
    } else if (value is! List) {
      b.issues.add(
        CompatibilityIssue(
          severity: CompatibilitySeverity.optional,
          message:
              'Hook event "$rawEvent" has an unsupported shape and was skipped.',
          fields: ['hooks.$rawEvent'],
        ),
      );
      continue;
    } else {
      groups = value;
    }
    for (final group in groups) {
      if (group is! Map) continue;
      final matcher = (group['matcher'] as String?)?.trim();
      final inner = group['hooks'];
      if (inner is! List) continue;
      for (final hook in inner) {
        if (hook is! Map) continue;
        final map = hook.cast<String, dynamic>();
        final explicitType = (map['type'] as String?)?.trim();
        final command = map['command'] as String?;
        final prompt = map['prompt'] as String?;
        final hasCommand = command != null && command.trim().isNotEmpty;
        final hasPrompt = prompt != null && prompt.trim().isNotEmpty;
        // An explicit `type` wins; otherwise a prompt payload must never be
        // coerced into a shell command, so `prompt` alone means prompt.
        final type = explicitType != null && explicitType.isNotEmpty
            ? explicitType
            : hasCommand
            ? 'command'
            : hasPrompt
            ? 'prompt'
            : 'command';
        final payload = command ?? prompt ?? '';
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

/// Parse Codex inline `[[hooks.<Event>]]` / `[[hooks.<Event>.hooks]]`
/// tables into the `{'hooks': {...}}` shape [CC] `hooks.json` uses, so
/// [_addHooks] normalizes both identically (Codex hooks guide).
/// The first non-empty capture group of [m]. The hook-event patterns offer
/// two alternatives (double-quoted or bare) so exactly one group is ever
/// populated.
String? _firstNamedGroup(RegExpMatch m) {
  for (var i = 1; i <= m.groupCount; i++) {
    final g = m.group(i);
    if (g != null && g.isNotEmpty) return g;
  }
  return null;
}

Map<String, dynamic> _parseCodexInlineHooks(String config) {
  // Quoted keys are legal TOML — `[[hooks."SessionStart"]]` — and Codex configs
  // do use them. The previous pattern accepted only bare identifiers, so every
  // quoted-event hook was silently skipped with at most an "optional issue".
  // Hyphens are allowed too (`session-start`).
  final handlerHeader = RegExp(
    r'^\[\[\s*hooks\s*\.\s*(?:"([^"]+)"|([A-Za-z0-9_-]+))'
    r'\s*\.\s*hooks\s*\]\]$',
  );
  final eventHeader = RegExp(
    r'^\[\[\s*hooks\s*\.\s*(?:"([^"]+)"|([A-Za-z0-9_-]+))\s*\]\]$',
  );
  final assignment = RegExp(r'^([A-Za-z0-9_]+)\s*=\s*(.+)$');
  final events = <String, List<Map<String, dynamic>>>{};
  Map<String, dynamic>? group;
  Map<String, dynamic>? handler;
  for (final rawLine in config.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (handlerHeader.hasMatch(line)) {
      if (group == null) continue;
      handler = <String, dynamic>{};
      (group['hooks'] as List).add(handler);
      continue;
    }
    final eventMatch = eventHeader.firstMatch(line);
    if (eventMatch != null) {
      final event = _firstNamedGroup(eventMatch);
      if (event == null) continue;
      group = <String, dynamic>{'hooks': <dynamic>[]};
      events.putIfAbsent(event, () => []).add(group);
      handler = null;
      continue;
    }
    if (line.startsWith('[')) {
      group = null;
      handler = null;
      continue;
    }
    final assignmentMatch = assignment.firstMatch(line);
    final target = handler ?? group;
    if (assignmentMatch == null || target == null) continue;
    target[assignmentMatch.group(1)!] = _tomlScalar(assignmentMatch.group(2)!);
  }
  if (events.isEmpty) return const {};
  return {
    'hooks': {
      for (final e in events.entries)
        e.key: [for (final g in e.value) Map<String, dynamic>.from(g)],
    },
  };
}

Object? _tomlScalar(String value) {
  final v = value.trim();
  if (v == 'true') return true;
  if (v == 'false') return false;
  return int.tryParse(v) ?? unquoteToml(v);
}

/// Map parsed MCP entries into scrubbed [PluginMcpServer] records. Legacy
/// SSE (`"type": "sse"`) is accepted — [McpService] speaks the legacy
/// GET /sse + POST /message protocol — though Streamable HTTP remains the
/// recommended transport for new servers.
void _addMcp(
  _Build b,
  List<ImportedMcp> parsed,
  String sourcePath, {
  Map<String, dynamic> rawByName = const {},
}) {
  for (final s in parsed) {
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
      message:
          'Invalid plugin identity: $idField declares no publisher, so '
          'the canonical id "publisher/name" has an empty publisher segment.',
      fields: [idField],
    ),
  );
}

/// Derive the minimum capability set from what the manifest actually
/// declares (spec §5.1) — never a blanket grant. Delegates to the single
/// public inference point so the adapters and the approval/runtime side
/// can never drift.
Set<PluginCapability> _inferCapabilities(_Build b) {
  return inferRequestedCapabilities(
    NormalizedPluginManifest(
      id: b.pluginId,
      name: '',
      version: '',
      format: PluginFormat.genericMcp,
      rootPath: b.root.path,
      commands: List.unmodifiable(b.commands),
      skills: List.unmodifiable(b.skills),
      agents: List.unmodifiable(b.agents),
      hooks: List.unmodifiable(b.hooks),
      mcpServers: List.unmodifiable(b.mcpServers),
      environmentReadNames: Set.unmodifiable(b.envNames),
    ),
  );
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
      // WS2 default-enable rule (documented on [_Build.enabledByDefault]):
      // manifest-declared opt-out only; every format without one stays
      // default-on. Round-tripped through JSON so the flag freezes with
      // the rest of the normalized model.
      enabledByDefault: b.enabledByDefault,
      requestedCapabilities: Set.unmodifiable(_inferCapabilities(b)),
      environmentReadNames: Set.unmodifiable(b.envNames),
      unknownFields: Map.unmodifiable(b.unknown),
      compatibility: List.unmodifiable(b.issues),
    ).toJson(),
  );
}

/// Fields `.claude-plugin/plugin.json` contributes to the normalized model —
/// everything else is preserved as `unknownFields`. The inline/component
/// keys (`hooks`, `mcpServers`, `commands`, `skills`, `agents`) are handled
/// by [_addClaudeInlineComponents], so they are "known" and never duplicated
/// into `unknownFields`.
const _knownClaudeManifestKeys = {
  'name',
  'version',
  'author',
  'description',
  'homepage',
  'license',
  'keywords',
  'enabledByDefault',
  'hooks',
  'mcpServers',
  'commands',
  'skills',
  'agents',
};

/// Reads a manifest-declared default-enable opt-out: only an explicit
/// boolean `false` flips the default; any other type (string, number,
/// …) is ignored so a malformed declaration can never silently disable
/// a plugin the user chose to install.
bool _readEnabledByDefault(Map<String, dynamic> manifestJson) {
  final v = manifestJson['enabledByDefault'];
  return v is bool ? v : true;
}

/// Adapts a [CC]-shaped plugin tree (spec §4.3).
class ClaudePluginAdapter {
  const ClaudePluginAdapter();

  Future<NormalizedPluginManifest> inspect(Directory root) async {
    final manifestFile = File('${root.path}/.claude-plugin/plugin.json');
    final j = _readJsonMap(manifestFile);
    final name = (j['name'] as String?)?.trim() ?? '';
    final author = j['author'];
    // Author may be a string or a {name, email, …} map; anything else
    // (list, number) yields an empty publisher instead of a cast throw.
    final publisher = author is Map
        ? ((author['name'] as String?) ?? '')
        : (author is String ? author : '');

    final b = _Build(
      NormalizedPluginManifest.canonicalId(publisher, name),
      root,
    );
    for (final e in j.entries) {
      if (!_knownClaudeManifestKeys.contains(e.key)) b.unknown[e.key] = e.value;
    }
    _requirePublisherIdentity(b, '.claude-plugin/plugin.json:author');
    // Manifest-declared default-enable opt-out (see [_readEnabledByDefault]).
    b.enabledByDefault = _readEnabledByDefault(j);

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
            e.value is Map
                ? e.value.cast<String, dynamic>()
                : <String, dynamic>{'value': e.value},
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

    // Inline manifest declarations (spec §4.3 parity): plugin.json may
    // declare hooks inline, bundle MCP servers, and point the component
    // directories at custom locations.
    await _addClaudeInlineComponents(b, j);

    _addDependencies(b);
    return _finish(
      b,
      name: name,
      version: (j['version'] as String?) ?? '',
      format: PluginFormat.claudeCode,
    );
  }
}

/// Inline `plugin.json` component declarations for the Claude adapter:
/// - `hooks`: an inline hooks event map (same shape as `hooks/hooks.json`),
///   or a string pointing at a directory containing `hooks.json`.
/// - `mcpServers`: an inline MCP server map, parsed exactly like
///   `.mcp.json` entries.
/// - `commands` / `skills` / `agents`: string pointers at custom component
///   directories, scanned ADDITIVELY alongside the default scans.
///
/// Directory pointers are sanitized: `..` segments (escaping the plugin
/// tree) and absolute paths are rejected; a missing directory is skipped
/// silently. A pointer that resolves to the already-scanned default
/// directory is not scanned twice.
Future<void> _addClaudeInlineComponents(
  _Build b,
  Map<String, dynamic> j,
) async {
  final root = b.root;

  Directory? safeComponentDir(String pointer, Directory defaultDir) {
    final cleaned = pointer
        .trim()
        .replaceAll(RegExp(r'^\.?/'), '')
        .replaceAll(RegExp(r'/+$'), '');
    if (cleaned.isEmpty) return null;
    final segments = cleaned.split('/');
    if (segments.contains('..')) return null;
    final dir = Directory('${root.path}/$cleaned');
    if (!dir.existsSync()) return null;
    // Don't scan the default directory twice.
    if (dir.absolute.path == defaultDir.absolute.path) return null;
    return dir;
  }

  // Inline hooks: {"hooks": {"PreToolUse": [...]}} — the same event-map
  // shape `_addHooks` expects from hooks.json. `_addHooks` preserves
  // hook-level unknown fields such as `"if"` predicates.
  final hooksDecl = j['hooks'];
  if (hooksDecl is Map) {
    _addHooks(
      b,
      {'hooks': hooksDecl},
      '.claude-plugin/plugin.json#hooks',
    );
  } else if (hooksDecl is String && hooksDecl.trim().isNotEmpty) {
    final dir = safeComponentDir(
      hooksDecl,
      Directory('${root.path}/hooks'),
    );
    final f = dir == null ? null : File('${dir.path}/hooks.json');
    if (f != null && f.existsSync()) {
      _addHooks(
        b,
        _readJsonMap(f),
        '.claude-plugin/plugin.json#hooks',
      );
    }
  }

  // Inline MCP servers: {"mcpServers": {"name": {...}}} — parsed exactly
  // like `.mcp.json` entries, including `oauth` and wrapperless shapes.
  final mcpDecl = j['mcpServers'];
  if (mcpDecl is Map && mcpDecl.isNotEmpty) {
    final parsed = <ImportedMcp>[];
    for (final e in mcpDecl.entries) {
      final v = e.value;
      if (v is! Map) continue;
      try {
        parsed.add(
          importedMcpFromJson(
            e.key.toString(),
            v.cast<String, dynamic>(),
          ),
        );
      } catch (_) {
        // A malformed inline entry must not fail the whole plugin —
        // `parseMcpConfig` already surfaced structured issues for
        // `.mcp.json`; here we simply skip.
      }
    }
    _addMcp(
      b,
      parsed,
      '.claude-plugin/plugin.json#mcpServers',
      rawByName: mcpDecl.cast<String, dynamic>(),
    );
  }

  // Custom component directories (additive with the default scans in
  // [ClaudePluginAdapter.inspect]).
  final commandsDecl = j['commands'];
  if (commandsDecl is String && commandsDecl.trim().isNotEmpty) {
    final dir = safeComponentDir(
      commandsDecl,
      Directory('${root.path}/commands'),
    );
    if (dir != null) await _addMarkdown(b, dir, asAgent: false);
  }
  final skillsDecl = j['skills'];
  if (skillsDecl is String && skillsDecl.trim().isNotEmpty) {
    final dir = safeComponentDir(
      skillsDecl,
      Directory('${root.path}/skills'),
    );
    if (dir != null) await _addSkills(b, dir);
  }
  final agentsDecl = j['agents'];
  if (agentsDecl is String && agentsDecl.trim().isNotEmpty) {
    final dir = safeComponentDir(
      agentsDecl,
      Directory('${root.path}/agents'),
    );
    if (dir != null) await _addMarkdown(b, dir, asAgent: true);
  }
}

/// Adapts a Codex-shaped plugin tree (spec §4.3).
class CodexPluginAdapter {
  const CodexPluginAdapter();

  Future<NormalizedPluginManifest> inspect(Directory root) async {
    final configFile = File('${root.path}/config.toml');
    final config = configFile.existsSync() ? configFile.readAsStringSync() : '';
    // Only the root TOML table may name the plugin: a `name`/`publisher`
    // nested inside an `[mcp_servers.*]` (or any other) table must not
    // spoof the manifest identity.
    final rootConfig = config.split(RegExp(r'^\[', multiLine: true)).first;
    String scalar(String key) {
      final m = RegExp(
        '^\\s*$key\\s*=\\s*(.+)\$',
        multiLine: true,
      ).firstMatch(rootConfig);
      return m == null ? '' : unquoteToml(m.group(1)!.trim());
    }

    // `.codex-plugin/plugin.json` (Codex plugin manifest, e.g.
    // obra/superpowers): declares name/version/author, a `skills`
    // directory pointer, and a `hooks` map. Read it BEFORE building the
    // identity so a manifest-declared name/publisher wins over the
    // config.toml fallback when config.toml names nothing.
    final codexManifestFile = File('${root.path}/.codex-plugin/plugin.json');
    final codexManifest = codexManifestFile.existsSync()
        ? _readJsonMap(codexManifestFile)
        : const <String, dynamic>{};
    final manifestName = (codexManifest['name'] as String?)?.trim() ?? '';
    final manifestAuthor = codexManifest['author'];
    // Author may be a string or a {name, email, …} map; anything else
    // (list, number) yields an empty publisher instead of a cast throw.
    final manifestPublisher = manifestAuthor is Map
        ? ((manifestAuthor['name'] as String?)?.trim() ?? '')
        : (manifestAuthor is String ? manifestAuthor.trim() : '');

    // Stock Codex configs declare no `name`/`publisher`; derive a stable,
    // slug-safe identity from the source id instead of failing.
    final sourceId = _slug(_basename(root.path));
    final fallbackName = sourceId.isEmpty ? 'plugin' : sourceId;
    final explicitName = scalar('name');
    final explicitPublisher = scalar('publisher');
    final name = explicitName.isNotEmpty
        ? explicitName
        : (manifestName.isNotEmpty ? manifestName : fallbackName);
    final publisher = explicitPublisher.isNotEmpty
        ? explicitPublisher
        : (manifestPublisher.isNotEmpty ? manifestPublisher : 'codex');
    final b = _Build(
      NormalizedPluginManifest.canonicalId(publisher, name),
      root,
    );
    // Preserve unrecognized manifest metadata (interface block, homepage,
    // keywords, …) verbatim so newer manifests never lose information.
    for (final e in codexManifest.entries) {
      if (const {
        'name',
        'version',
        'description',
        'author',
        'skills',
        'hooks',
      }.contains(e.key)) {
        continue;
      }
      b.unknown['manifest.${e.key}'] = e.value;
    }
    _requirePublisherIdentity(
      b,
      explicitPublisher.isNotEmpty
          ? 'config.toml:publisher'
          : (manifestPublisher.isNotEmpty
                ? '.codex-plugin/plugin.json:author'
                : 'config.toml:publisher'),
    );

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
    ).allMatches(rootConfig)) {
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
    // CODEX PARITY (2026-09-24): the Claude adapter also scans the plain
    // top-level `commands/`, `agents/` and `skills/` directories. A Codex tree
    // using that layout contributed NOTHING — no commands, no agents — while an
    // identical Claude tree worked, which is most of why "Codex plugins don't
    // work" was reported.
    await _addMarkdown(b, Directory('${root.path}/commands'), asAgent: false);
    await _addMarkdown(b, Directory('${root.path}/agents'), asAgent: true);
    await _addSkills(b, Directory('${root.path}/skills'));

    // The manifest's `skills` pointer (e.g. `"skills": "./skills/"`) —
    // honor it in addition to the legacy `.agents/skills` scan above.
    // `..` segments are rejected: a manifest must not point outside the
    // plugin tree.
    final skillsPointer = codexManifest['skills'];
    if (skillsPointer is String && skillsPointer.trim().isNotEmpty) {
      final cleaned = skillsPointer
          .trim()
          .replaceAll(RegExp(r'^\.?/'), '')
          .replaceAll(RegExp(r'/+$'), '');
      final segments = cleaned.split('/');
      if (!segments.contains('..') && cleaned.isNotEmpty) {
        final skillsDir = Directory('${root.path}/$cleaned');
        final legacyDir = Directory('${root.path}/.agents/skills');
        if (skillsDir.path != legacyDir.path) {
          await _addSkills(b, skillsDir);
        }
      }
    }

    // Codex lifecycle hooks: plugin-bundled `hooks/hooks.json` plus inline
    // `[[hooks.<Event>]]` tables, normalized through the shared [_addHooks].
    _addHooks(b, _parseCodexInlineHooks(config), 'config.toml');
    final codexHooksFile = File('${root.path}/hooks/hooks.json');
    if (codexHooksFile.existsSync()) {
      _addHooks(b, _readJsonMap(codexHooksFile), 'hooks/hooks.json');
    }
    // …plus the manifest-declared `hooks` map, when present.
    final manifestHooks = codexManifest['hooks'];
    if (manifestHooks is Map && manifestHooks.isNotEmpty) {
      _addHooks(b, {'hooks': manifestHooks}, '.codex-plugin/plugin.json');
    }

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

    // Default-enable: manifest-declared opt-out
    // (`enabledByDefault: false` in `.codex-plugin/plugin.json`) or the
    // root TOML table's `enabled_by_default = false` — an explicit false
    // in either wins; anything else keeps the default-on rule.
    final tomlEnabledDefault = scalar(
      'enabled_by_default',
    ).trim().toLowerCase();
    b.enabledByDefault =
        _readEnabledByDefault(codexManifest) && tomlEnabledDefault != 'false';

    _addDependencies(b);
    final version = scalar('version');
    final manifestVersion = codexManifest['version'];
    return _finish(
      b,
      name: name,
      version: version.isNotEmpty
          ? version
          : (manifestVersion is String
                ? manifestVersion
                : (manifestVersion is num ? '$manifestVersion' : '')),
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
        File('${root.path}/.codex-plugin/plugin.json').existsSync() ||
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
