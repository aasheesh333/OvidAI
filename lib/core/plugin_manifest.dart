/// Normalized plugin manifest models (Production Plugin & MCP Compatibility,
/// design spec §4.3/§4.4, §5.1, §7).
///
/// Every supported source format (Claude Code plugin, Codex plugin, generic
/// MCP config) is adapted into ONE normalized manifest: immutable,
/// JSON round-trippable, with a stable canonical `publisher/name` identity
/// and explicit capability requests. Unrecognized source fields are preserved
/// verbatim in `unknownFields` maps so newer plugin manifests never lose
/// information when read by this Ovid version.
///
/// Secrets never live here (spec §5.1): contribution records carry only the
/// NAMES of required environment variables / HTTP headers — values stay in
/// secure storage, keyed to the owning plugin. [scrubMcpSecrets] is the one
/// authoritative path enforcing this when raw declaration blocks are
/// normalized.
library;

/// The source format a manifest was adapted from (spec §4.3).
enum PluginFormat { claudeCode, codex, genericMcp }

/// Fixed capability vocabulary (spec §5.1). The spec's
/// `environment.read:<name>` form is represented by
/// [PluginCapability.environmentRead]; the specific variable names travel
/// separately (e.g. `NormalizedPluginManifest.environmentReadNames`,
/// `PluginMcpServer.envNames`) — never encoded into the enum.
enum PluginCapability {
  workspaceRead,
  workspaceWrite,
  shellExecute,
  networkConnect,
  processSpawn,
  environmentRead,
  mcpRegister,
  hooksObserve,
  hooksBlock,
  sessionRead,
  sessionWrite,
  deviceControl,
}

/// Activation states of an installed plugin (spec §4.1/§7).
enum PluginActivation {
  sessionActive,
  pendingGlobal,
  globalActive,
  degraded,
  failed,
  disabled,
}

/// Where an install came from (spec §7): agent installs activate for the
/// installing session only and promote on next boot; Plugins-screen installs
/// stay pending-global until restart.
enum PluginInstallOrigin { agent, pluginsScreen }

/// Severity of a [CompatibilityIssue] (spec §4.3/§13): required unsupported
/// behavior fails inspection/install before activation; optional unsupported
/// behavior degrades with a visible warning.
enum CompatibilitySeverity { optional, required }

/// Dependency runtime kind (spec §6).
enum PluginDependencyKind { npm, python, native }

/// Canonical runtime identities have exactly two normalized path segments.
/// Keeping this check shared prevents malformed IDs reaching persistence,
/// filesystem paths, or the contribution registry through different seams.
bool isCanonicalPluginId(String value) {
  final parts = value.split('/');
  if (parts.length != 2) return false;
  return parts.every(
    (part) =>
        part.isNotEmpty &&
        part ==
            part
                .toLowerCase()
                .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
                .replaceAll(RegExp(r'^-+|-+$'), ''),
  );
}

/// One compatibility finding against a normalized manifest (spec §4.3):
/// unsupported proprietary host APIs and unrunnable contributions are
/// reported with their EXACT offending manifest fields (spec §13); optional
/// findings degrade, required findings fail.
class CompatibilityIssue {
  final CompatibilitySeverity severity;
  final String message;

  /// Offending manifest fields, e.g. `['mcpServers[0].command']`.
  final List<String> fields;

  const CompatibilityIssue({
    required this.severity,
    required this.message,
    this.fields = const [],
  });

  Map<String, dynamic> toJson() => {
    'severity': severity.name,
    'message': message,
    'fields': fields,
  };

  factory CompatibilityIssue.fromJson(Map<String, dynamic> j) =>
      CompatibilityIssue(
        // Unknown severity falls back to `required` — a finding we cannot
        // classify must fail loudly, never silently degrade.
        severity:
            compatibilitySeverityFromName(j['severity']) ??
            CompatibilitySeverity.required,
        message: j['message'] as String? ?? '',
        fields: _asStringList(j['fields']),
      );
}

/// A slash command contributed by a plugin (`commands/**/*.md`).
class PluginCommand {
  /// Owning plugin's canonical id (`publisher/name`).
  final String pluginId;

  /// Command name without the leading `/`.
  final String name;

  /// Source-relative path, e.g. `commands/review.md`.
  final String path;

  /// Parsed markdown frontmatter.
  final Map<String, dynamic> frontmatter;

  /// Unrecognized source fields, preserved verbatim.
  final Map<String, dynamic> unknownFields;

  const PluginCommand({
    required this.pluginId,
    required this.name,
    required this.path,
    this.frontmatter = const {},
    this.unknownFields = const {},
  });

  /// Registry id (spec §4.4): `plugin:<plugin-id>/command:<name>`.
  String get canonicalId => 'plugin:$pluginId/command:$name';

  Map<String, dynamic> toJson() => {
    'pluginId': pluginId,
    'name': name,
    'path': path,
    'frontmatter': frontmatter,
    'unknownFields': unknownFields,
  };

  factory PluginCommand.fromJson(Map<String, dynamic> j) => PluginCommand(
    pluginId: j['pluginId'] as String? ?? '',
    name: j['name'] as String? ?? '',
    path: j['path'] as String? ?? '',
    frontmatter: _asMap(j['frontmatter']),
    unknownFields: _asMap(j['unknownFields']),
  );
}

/// A skill contributed by a plugin (`skills/**/SKILL.md` plus every
/// supporting file under the skill directory — spec §4.3).
class PluginSkill {
  final String pluginId;
  final String name;

  /// Source-relative path of the `SKILL.md`.
  final String path;

  /// Source-relative paths of supporting files inside the skill directory.
  final List<String> supportingFiles;

  /// Parsed `SKILL.md` YAML frontmatter.
  final Map<String, dynamic> frontmatter;

  final Map<String, dynamic> unknownFields;

  const PluginSkill({
    required this.pluginId,
    required this.name,
    required this.path,
    this.supportingFiles = const [],
    this.frontmatter = const {},
    this.unknownFields = const {},
  });

  /// Registry id (spec §4.4): `plugin:<plugin-id>/skill:<name>`.
  String get canonicalId => 'plugin:$pluginId/skill:$name';

  Map<String, dynamic> toJson() => {
    'pluginId': pluginId,
    'name': name,
    'path': path,
    'supportingFiles': supportingFiles,
    'frontmatter': frontmatter,
    'unknownFields': unknownFields,
  };

  factory PluginSkill.fromJson(Map<String, dynamic> j) => PluginSkill(
    pluginId: j['pluginId'] as String? ?? '',
    name: j['name'] as String? ?? '',
    path: j['path'] as String? ?? '',
    supportingFiles: _asStringList(j['supportingFiles']),
    frontmatter: _asMap(j['frontmatter']),
    unknownFields: _asMap(j['unknownFields']),
  );
}

/// An agent/persona contributed by a plugin (`agents/**/*.md`, or
/// Codex-compatible persona markdown).
class PluginAgent {
  final String pluginId;
  final String name;

  /// Source-relative path of the agent markdown.
  final String path;

  /// Parsed markdown frontmatter (description, model, tools, …).
  final Map<String, dynamic> frontmatter;

  final Map<String, dynamic> unknownFields;

  const PluginAgent({
    required this.pluginId,
    required this.name,
    required this.path,
    this.frontmatter = const {},
    this.unknownFields = const {},
  });

  /// Registry id (spec §4.4): `plugin:<plugin-id>/agent:<name>`.
  String get canonicalId => 'plugin:$pluginId/agent:$name';

  Map<String, dynamic> toJson() => {
    'pluginId': pluginId,
    'name': name,
    'path': path,
    'frontmatter': frontmatter,
    'unknownFields': unknownFields,
  };

  factory PluginAgent.fromJson(Map<String, dynamic> j) => PluginAgent(
    pluginId: j['pluginId'] as String? ?? '',
    name: j['name'] as String? ?? '',
    path: j['path'] as String? ?? '',
    frontmatter: _asMap(j['frontmatter']),
    unknownFields: _asMap(j['unknownFields']),
  );
}

/// One ordered hook entry (spec §4.3/§8). The old one-command-per-event
/// reduction is gone: every event supports multiple ordered hooks, matcher
/// groups, command or prompt types, and per-hook timeouts.
class PluginHook {
  /// Canonical event names (spec §8.1). Existing Ovid `on_*` aliases remain
  /// accepted by adapters and map into this set.
  static const canonicalEvents = [
    'session_start',
    'session_end',
    'user_prompt_submit',
    'pre_request',
    'post_request',
    'pre_tool',
    'post_tool',
    'permission_request',
    'notification',
    'pre_compact',
    'post_compact',
    'stop',
    'subagent_start',
    'subagent_end',
  ];

  /// Events that MAY block (exit code 2 / JSON decision — spec §8.2).
  /// Everything else is fire-and-observe.
  static const blockingEvents = ['pre_tool', 'permission_request'];

  final String pluginId;

  /// Canonical event name from [canonicalEvents] (aliases pre-mapped).
  final String event;

  /// Manifest-order index within the event — deterministic ordering
  /// (spec §8.2) and part of the canonical id.
  final int ordinal;

  /// `'command'` (shell) or `'prompt'` (model prompt, where implementable).
  final String type;

  /// Shell command — or prompt text when [type] is `'prompt'`.
  final String payload;

  /// Optional tool-name matcher regex (matcher groups — spec §8.1);
  /// null means the hook fires for every tool.
  final String? matcher;

  /// Declared per-hook timeout in seconds; 0 = runtime default. The runtime
  /// clamps to the 120 s cap (spec §8.1).
  final int timeoutS;

  /// Source-relative path of the declaring file, e.g. `hooks/hooks.json`.
  final String path;

  /// Raw surrounding declaration config (e.g. the matcher-group object from
  /// `hooks.json`); markdown-declared hooks carry parsed frontmatter.
  final Map<String, dynamic> frontmatter;

  final Map<String, dynamic> unknownFields;

  const PluginHook({
    required this.pluginId,
    required this.event,
    required this.payload,
    this.ordinal = 0,
    this.type = 'command',
    this.matcher,
    this.timeoutS = 0,
    this.path = '',
    this.frontmatter = const {},
    this.unknownFields = const {},
  });

  /// Registry id (spec §4.4): `plugin:<plugin-id>/hook:<event>:<ordinal>`.
  String get canonicalId => 'plugin:$pluginId/hook:$event:$ordinal';

  /// Whether this hook may deny an action (spec §8.2). Observe hooks can
  /// never block the main run.
  bool get canBlock => blockingEvents.contains(event);

  Map<String, dynamic> toJson() => {
    'pluginId': pluginId,
    'event': event,
    'ordinal': ordinal,
    'type': type,
    'payload': payload,
    'matcher': matcher,
    'timeoutS': timeoutS,
    'path': path,
    'frontmatter': frontmatter,
    'unknownFields': unknownFields,
  };

  factory PluginHook.fromJson(Map<String, dynamic> j) => PluginHook(
    pluginId: j['pluginId'] as String? ?? '',
    event: j['event'] as String? ?? '',
    ordinal: (j['ordinal'] as num?)?.toInt() ?? 0,
    type: j['type'] as String? ?? 'command',
    payload: j['payload'] as String? ?? '',
    matcher: j['matcher'] as String?,
    timeoutS: (j['timeoutS'] as num?)?.toInt() ?? 0,
    path: j['path'] as String? ?? '',
    frontmatter: _asMap(j['frontmatter']),
    unknownFields: _asMap(j['unknownFields']),
  );
}

/// An MCP server contributed by a plugin (`.mcp.json`, `config.toml`, or a
/// pasted/direct generic MCP definition — spec §4.2/§9). Secret VALUES never
/// appear here; only the names the runtime must source from secure storage.
class PluginMcpServer {
  final String pluginId;

  /// Source-local server name. Ownership uses `<plugin-id>/<name>` (spec §9),
  /// so bare names never deduplicate globally.
  final String name;

  /// `'stdio'` or `'http'` (Streamable HTTP). SSE-only definitions are
  /// rejected by the adapter with the actionable migration message.
  final String transport;

  /// Executable for `'stdio'` transport ('' for http).
  final String command;
  final List<String> args;

  /// Streamable-HTTP endpoint (required for `'http'`, unused for stdio).
  final String? url;

  /// Source-relative working directory for the spawned process, if declared.
  final String? cwd;

  /// Environment variable NAMES the server needs (values stay in secure
  /// storage; a missing name yields `degraded: needs configuration`).
  final List<String> envNames;

  /// HTTP header NAMES carrying authorization (values stay in secure
  /// storage — spec §5.1).
  final List<String> headerNames;

  /// Source-relative path of the declaring file, e.g. `.mcp.json`.
  final String path;

  /// Raw server declaration block from the source config, scrubbed of
  /// secret VALUES (spec §5.1): `env`/`headers` objects never survive
  /// here — only their names, moved into [envNames]/[headerNames].
  final Map<String, dynamic> frontmatter;

  final Map<String, dynamic> unknownFields;

  const PluginMcpServer({
    required this.pluginId,
    required this.name,
    this.transport = 'stdio',
    this.command = '',
    this.args = const [],
    this.url,
    this.cwd,
    this.envNames = const [],
    this.headerNames = const [],
    this.path = '',
    this.frontmatter = const {},
    this.unknownFields = const {},
  });

  /// Authoritative adapter path (spec §5.1): builds a server record from
  /// the RAW declaration block (`.mcp.json` entry, `config.toml` table,
  /// pasted generic definition). [scrubMcpSecrets] moves env/header NAMES
  /// into [envNames]/[headerNames] and strips their secret VALUES from the
  /// stored frontmatter/unknownFields, so a secret can never round-trip
  /// through [toJson] into persisted plugin metadata. Explicitly resolved
  /// [envNames]/[headerNames] merge with the names found in
  /// [rawDeclaration] (exact-deduplicated, source order).
  factory PluginMcpServer.scrubbedRaw({
    required String pluginId,
    required String name,
    required Map<String, dynamic> rawDeclaration,
    String transport = 'stdio',
    String command = '',
    List<String> args = const [],
    String? url,
    String? cwd,
    List<String> envNames = const [],
    List<String> headerNames = const [],
    String path = '',
    Map<String, dynamic> unknownFields = const {},
  }) {
    final decl = scrubMcpSecrets(rawDeclaration);
    final unknown = scrubMcpSecrets(unknownFields);
    return PluginMcpServer(
      pluginId: pluginId,
      name: name,
      transport: transport,
      command: command,
      args: List<String>.unmodifiable(args),
      url: url,
      cwd: cwd,
      envNames: _mergedNames([envNames, decl.envNames, unknown.envNames]),
      headerNames: _mergedNames([
        headerNames,
        decl.headerNames,
        unknown.headerNames,
      ]),
      path: path,
      frontmatter: decl.scrubbed,
      unknownFields: unknown.scrubbed,
    );
  }

  /// Registry id (spec §4.4): `plugin:<plugin-id>/mcp:<server-name>`.
  String get canonicalId => 'plugin:$pluginId/mcp:$name';

  /// Canonical id of one discovered tool (spec §4.4):
  /// `mcp:<plugin-id>/<server-name>/<tool-name>`.
  String canonicalToolId(String toolName) => 'mcp:$pluginId/$name/$toolName';

  Map<String, dynamic> toJson() => {
    'pluginId': pluginId,
    'name': name,
    'transport': transport,
    'command': command,
    'args': args,
    'url': url,
    'cwd': cwd,
    'envNames': envNames,
    'headerNames': headerNames,
    'path': path,
    'frontmatter': frontmatter,
    'unknownFields': unknownFields,
  };

  factory PluginMcpServer.fromJson(Map<String, dynamic> j) {
    // Round-trip safety: even a persisted/hand-edited JSON must never
    // reintroduce secret VALUES. Re-scrub the raw blocks so envNames /
    // headerNames absorb any smuggled env/header values on read.
    final decl = scrubMcpSecrets(_asMap(j['frontmatter']));
    final unknown = scrubMcpSecrets(_asMap(j['unknownFields']));
    return PluginMcpServer(
      pluginId: j['pluginId'] as String? ?? '',
      name: j['name'] as String? ?? '',
      transport: j['transport'] as String? ?? 'stdio',
      command: j['command'] as String? ?? '',
      args: _asStringList(j['args']),
      url: j['url'] as String?,
      cwd: j['cwd'] as String?,
      envNames: _mergedNames([
        _asStringList(j['envNames']),
        decl.envNames,
        unknown.envNames,
      ]),
      headerNames: _mergedNames([
        _asStringList(j['headerNames']),
        decl.headerNames,
        unknown.headerNames,
      ]),
      path: j['path'] as String? ?? '',
      frontmatter: decl.scrubbed,
      unknownFields: unknown.scrubbed,
    );
  }
}

/// One declared dependency (spec §6). A failed REQUIRED dependency means
/// `failed` (no partial activation); a failed optional dependency means
/// `degraded` with only the affected contribution disabled.
class PluginDependency {
  final String name;

  /// Version specifier; '' = unpinned/any.
  final String versionSpec;

  final PluginDependencyKind kind;

  final bool required;

  const PluginDependency({
    required this.name,
    this.versionSpec = '',
    this.kind = PluginDependencyKind.npm,
    this.required = true,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'versionSpec': versionSpec,
    'kind': kind.name,
    'required': required,
  };

  factory PluginDependency.fromJson(Map<String, dynamic> j) => PluginDependency(
    name: j['name'] as String? ?? '',
    versionSpec: j['versionSpec'] as String? ?? '',
    kind:
        _enumByName(PluginDependencyKind.values, j['kind']) ??
        PluginDependencyKind.npm,
    // Unknown requirement semantics fall back to required — under-promising
    // activation is the honest default.
    required: j['required'] as bool? ?? true,
  );
}

/// The dependency graph of one plugin (spec §6): npm packages into a local
/// prefix, Python packages into a per-plugin venv, native packages only when
/// the sandbox package manager + device ABI support them.
class PluginDependencies {
  final List<PluginDependency> packages;

  const PluginDependencies({this.packages = const []});

  bool get isEmpty => packages.isEmpty;

  Iterable<PluginDependency> get npm =>
      packages.where((p) => p.kind == PluginDependencyKind.npm);

  Iterable<PluginDependency> get python =>
      packages.where((p) => p.kind == PluginDependencyKind.python);

  Iterable<PluginDependency> get native =>
      packages.where((p) => p.kind == PluginDependencyKind.native);

  Map<String, dynamic> toJson() => {
    'packages': packages.map((p) => p.toJson()).toList(),
  };

  factory PluginDependencies.fromJson(Map<String, dynamic> j) =>
      PluginDependencies(
        packages: List<PluginDependency>.unmodifiable(
          _asMapList(j['packages']).map(PluginDependency.fromJson),
        ),
      );
}

/// The single normalized artifact every compatibility adapter emits
/// (spec §4.3). Immutable; unknown source fields are preserved in
/// [unknownFields] and unsupported behavior is reported in [compatibility].
class NormalizedPluginManifest {
  /// Stable publisher/name identity — built with [canonicalId].
  final String id;

  /// Display name.
  final String name;

  final String version;
  final PluginFormat format;

  /// Root directory of the plugin content (staging or installed location).
  final String rootPath;

  final List<PluginCommand> commands;
  final List<PluginSkill> skills;
  final List<PluginAgent> agents;
  final List<PluginHook> hooks;
  final List<PluginMcpServer> mcpServers;
  final PluginDependencies dependencies;

  /// Minimum requested capability set derived by inspection (spec §5.1).
  final Set<PluginCapability> requestedCapabilities;

  /// Specific environment variable names behind
  /// [PluginCapability.environmentRead] (`environment.read:<name>` detail —
  /// kept out of the fixed enum).
  final Set<String> environmentReadNames;

  /// Unrecognized top-level source fields, preserved verbatim.
  final Map<String, dynamic> unknownFields;

  /// Required findings fail inspection/install; optional findings degrade
  /// with a visible warning (spec §4.3/§13).
  final List<CompatibilityIssue> compatibility;

  const NormalizedPluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.format,
    required this.rootPath,
    this.commands = const [],
    this.skills = const [],
    this.agents = const [],
    this.hooks = const [],
    this.mcpServers = const [],
    this.dependencies = const PluginDependencies(),
    this.requestedCapabilities = const {},
    this.environmentReadNames = const {},
    this.unknownFields = const {},
    this.compatibility = const [],
  });

  /// True when any compatibility finding is REQUIRED-unsupported — the
  /// manifest must fail inspection/install before activation (spec §4.3).
  bool get hasRequiredIssues =>
      compatibility.any((c) => c.severity == CompatibilitySeverity.required);

  /// Stable canonical identity: lowercase `publisher/name`, each part with
  /// non-alphanumerics collapsed to single `-` and edge `-` stripped.
  /// `'Acme Inc'` + `'Reviewer Pro'` → `'acme-inc/reviewer-pro'`.
  static String canonicalId(String publisher, String name) =>
      '${_canonicalPart(publisher)}/${_canonicalPart(name)}';

  static String _canonicalPart(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'format': format.name,
    'rootPath': rootPath,
    'commands': commands.map((c) => c.toJson()).toList(),
    'skills': skills.map((s) => s.toJson()).toList(),
    'agents': agents.map((a) => a.toJson()).toList(),
    'hooks': hooks.map((h) => h.toJson()).toList(),
    'mcpServers': mcpServers.map((s) => s.toJson()).toList(),
    'dependencies': dependencies.toJson(),
    'requestedCapabilities': requestedCapabilities.map((c) => c.name).toList(),
    'environmentReadNames': environmentReadNames.toList(),
    'unknownFields': unknownFields,
    'compatibility': compatibility.map((c) => c.toJson()).toList(),
  };

  factory NormalizedPluginManifest.fromJson(Map<String, dynamic> j) =>
      NormalizedPluginManifest(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        version: j['version'] as String? ?? '',
        // Unknown format falls back to genericMcp — the least-assuming
        // adapter surface (MCP contributions only).
        format:
            _enumByName(PluginFormat.values, j['format']) ??
            PluginFormat.genericMcp,
        rootPath: j['rootPath'] as String? ?? '',
        commands: List<PluginCommand>.unmodifiable(
          _asMapList(j['commands']).map(PluginCommand.fromJson),
        ),
        skills: List<PluginSkill>.unmodifiable(
          _asMapList(j['skills']).map(PluginSkill.fromJson),
        ),
        agents: List<PluginAgent>.unmodifiable(
          _asMapList(j['agents']).map(PluginAgent.fromJson),
        ),
        hooks: List<PluginHook>.unmodifiable(
          _asMapList(j['hooks']).map(PluginHook.fromJson),
        ),
        mcpServers: List<PluginMcpServer>.unmodifiable(
          _asMapList(j['mcpServers']).map(PluginMcpServer.fromJson),
        ),
        dependencies: PluginDependencies.fromJson(_asMap(j['dependencies'])),
        requestedCapabilities: pluginCapabilitiesFromNames(
          j['requestedCapabilities'],
        ),
        environmentReadNames: Set<String>.unmodifiable(
          _asStringList(j['environmentReadNames']),
        ),
        unknownFields: _asMap(j['unknownFields']),
        compatibility: List<CompatibilityIssue>.unmodifiable(
          _asMapList(j['compatibility']).map(CompatibilityIssue.fromJson),
        ),
      );
}

/// One consolidated user approval (spec §5.1). Grants persist by plugin id +
/// manifest digest: a later update whose digest differs and requests new
/// capabilities pauses activation until the delta is approved. Removing a
/// grant immediately disables affected contributions.
class PluginPermissionGrant {
  final String pluginId;

  /// Digest of the approved [NormalizedPluginManifest].
  final String manifestDigest;

  final Set<PluginCapability> capabilities;

  /// Approved `environment.read:<name>` details — the specific variable
  /// names the plugin may receive (values still only flow from secure
  /// storage).
  final Set<String> environmentReadNames;

  final DateTime approvedAt;

  const PluginPermissionGrant({
    required this.pluginId,
    required this.manifestDigest,
    required this.capabilities,
    this.environmentReadNames = const {},
    required this.approvedAt,
  });

  Map<String, dynamic> toJson() => {
    'pluginId': pluginId,
    'manifestDigest': manifestDigest,
    'capabilities': capabilities.map((c) => c.name).toList(),
    'environmentReadNames': environmentReadNames.toList(),
    'approvedAt': approvedAt.toIso8601String(),
  };

  factory PluginPermissionGrant.fromJson(Map<String, dynamic> j) =>
      PluginPermissionGrant(
        pluginId: j['pluginId'] as String? ?? '',
        manifestDigest: j['manifestDigest'] as String? ?? '',
        capabilities: pluginCapabilitiesFromNames(j['capabilities']),
        environmentReadNames: Set<String>.unmodifiable(
          _asStringList(j['environmentReadNames']),
        ),
        // Fail CLOSED: a corrupt/missing timestamp yields a Visibly-Stale
        // epoch-0 UTC sentinel, never DateTime.now() (which would make a
        // damaged grant look freshly approved — spec §5.1).
        approvedAt:
            DateTime.tryParse(j['approvedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
}

/// Persisted activation/restart state per plugin (spec §7). `bootEpoch`
/// increments exactly once during app initialization; `activateForBoot()`
/// promotes valid pending records to globalActive exactly one restart after
/// install and clears [promoteOnNextBoot].
class PluginActivationRecord {
  final String pluginId;

  /// Lifecycle state — one of [PluginActivation].
  final PluginActivation state;

  /// For [PluginActivation.sessionActive]: the ONLY session that sees the
  /// plugin before promotion (agent installs — spec §7).
  final String? immediateSessionId;

  final int installedBootEpoch;

  final bool promoteOnNextBoot;

  const PluginActivationRecord({
    required this.pluginId,
    required this.state,
    this.immediateSessionId,
    this.installedBootEpoch = 0,
    this.promoteOnNextBoot = false,
  });

  Map<String, dynamic> toJson() => {
    'pluginId': pluginId,
    'state': state.name,
    'immediateSessionId': immediateSessionId,
    'installedBootEpoch': installedBootEpoch,
    'promoteOnNextBoot': promoteOnNextBoot,
  };

  factory PluginActivationRecord.fromJson(Map<String, dynamic> j) =>
      PluginActivationRecord(
        pluginId: j['pluginId'] as String? ?? '',
        state:
            pluginActivationFromName(j['state']) ?? PluginActivation.disabled,
        immediateSessionId: j['immediateSessionId'] as String?,
        installedBootEpoch: (j['installedBootEpoch'] as num?)?.toInt() ?? 0,
        promoteOnNextBoot: j['promoteOnNextBoot'] as bool? ?? false,
      );
}

/// ---------- enum + JSON wire helpers ----------

T? _enumByName<T extends Enum>(List<T> values, Object? raw) {
  if (raw is! String) return null;
  for (final v in values) {
    if (v.name == raw) return v;
  }
  return null;
}

/// Parses a persisted activation state. Unknown/missing names yield null so
/// callers pick their honest default (legacy `PluginItem` rows default to
/// [PluginActivation.disabled] — never an auto-promoted globalActive).
PluginActivation? pluginActivationFromName(Object? raw) =>
    _enumByName(PluginActivation.values, raw);

PluginFormat? pluginFormatFromName(Object? raw) =>
    _enumByName(PluginFormat.values, raw);

PluginInstallOrigin? pluginInstallOriginFromName(Object? raw) =>
    _enumByName(PluginInstallOrigin.values, raw);

CompatibilitySeverity? compatibilitySeverityFromName(Object? raw) =>
    _enumByName(CompatibilitySeverity.values, raw);

/// Capability sets round-trip as lists of enum string names. Names this Ovid
/// version does not know are dropped — adapters preserve unrecognized source
/// capability strings in `unknownFields` instead, so a newer manifest can
/// never inflate an approval.
Set<PluginCapability> pluginCapabilitiesFromNames(Object? raw) {
  final out = <PluginCapability>{};
  if (raw is! Iterable) return Set<PluginCapability>.unmodifiable(out);
  for (final e in raw) {
    final cap = _enumByName(PluginCapability.values, e);
    if (cap != null) out.add(cap);
  }
  return Set<PluginCapability>.unmodifiable(out);
}

/// Frozen wire helpers (immutability contract): every collection these
/// return is a fresh copy AND unmodifiable, so no adapter can later mutate a
/// published manifest's contents through a stored reference. The const
/// constructors keep accepting caller collections as-is — adapters that need
/// the frozen guarantee round-trip through `fromJson` or use [scrubMcpSecrets]
/// / `PluginMcpServer.scrubbedRaw`, which freeze their results too.
Map<String, dynamic> _asMap(Object? raw) => raw is Map
    ? Map<String, dynamic>.unmodifiable(Map<String, dynamic>.from(raw))
    : const <String, dynamic>{};

List<Map<String, dynamic>> _asMapList(Object? raw) => raw is List
    ? List<Map<String, dynamic>>.unmodifiable([
        for (final e in raw)
          if (e is Map) _asMap(e),
      ])
    : const <Map<String, dynamic>>[];

List<String> _asStringList(Object? raw) => raw is List
    ? List<String>.unmodifiable([for (final e in raw) e.toString()])
    : const <String>[];

/// One authoritative secret scrubber (spec §5.1: secrets are NEVER copied
/// into plugin metadata or ordinary preferences). Given a raw MCP server
/// declaration block (`.mcp.json` entry, `config.toml` table, or pasted
/// generic definition) — or any unknown-fields block — it:
///
/// * collects the NAMES of every `env` / `environment` / `headers` object it
///   finds, at ANY depth (env keys into `envNames`, header keys into
///   `headerNames`),
/// * DROPS those objects — with their secret values — from the returned
///   `scrubbed` map, so a value like `sk-…` or `Bearer …` can never
///   round-trip through `toJson()` into persisted metadata,
/// * preserves everything else verbatim, so unknown fields never lose
///   information.
///
/// The result is deeply frozen: nested maps and lists are unmodifiable as
/// they are rebuilt. Adapters (Task 2) build [PluginMcpServer] records via
/// [PluginMcpServer.scrubbedRaw], which applies this scrubber.
({
  Map<String, dynamic> scrubbed,
  List<String> envNames,
  List<String> headerNames,
})
scrubMcpSecrets(Map<String, dynamic> raw) {
  final envNames = <String>[];
  final headerNames = <String>[];
  return (
    scrubbed: Map<String, dynamic>.unmodifiable(
      _scrubNode(raw, envNames, headerNames) as Map<String, dynamic>,
    ),
    envNames: List<String>.unmodifiable(envNames),
    headerNames: List<String>.unmodifiable(headerNames),
  );
}

/// Recursively scrubs one map/list node; harvested names land in [envNames]
/// / [headerNames] (exact-deduplicated, source order).
Object? _scrubNode(
  Object? node,
  List<String> envNames,
  List<String> headerNames,
) {
  if (node is Map) {
    final out = <String, dynamic>{};
    node.forEach((key, value) {
      final name = key.toString();
      final lower = name.toLowerCase();
      final isEnvBlock = lower == 'env' || lower == 'environment';
      if (value is Map && (isEnvBlock || lower == 'headers')) {
        // Secret-bearing object: keep the NAMES, drop the VALUES.
        final names = isEnvBlock ? envNames : headerNames;
        for (final k in value.keys) {
          final secretName = k.toString();
          if (!names.contains(secretName)) names.add(secretName);
        }
        return;
      }
      out[name] = _scrubNode(value, envNames, headerNames);
    });
    return Map<String, dynamic>.unmodifiable(out);
  }
  if (node is List) {
    return List<Object?>.unmodifiable([
      for (final e in node) _scrubNode(e, envNames, headerNames),
    ]);
  }
  return node;
}

/// Merges name groups in source order, exact-deduplicated, frozen.
List<String> _mergedNames(Iterable<Iterable<String>> groups) {
  final out = <String>[];
  for (final group in groups) {
    for (final name in group) {
      if (!out.contains(name)) out.add(name);
    }
  }
  return List<String>.unmodifiable(out);
}
