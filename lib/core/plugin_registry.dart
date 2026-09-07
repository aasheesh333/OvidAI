/// Namespaced plugin contribution registry (Production Plugin & MCP
/// Compatibility, design spec §4.4 + §7).
///
/// The in-memory ledger of every contribution of every REGISTERED
/// normalized plugin manifest. Each contribution carries its canonical
/// §4.4 id:
///
/// ```text
/// plugin:<plugin-id>/command:<name>
/// plugin:<plugin-id>/skill:<name>
/// plugin:<plugin-id>/agent:<name>
/// plugin:<plugin-id>/hook:<event>:<ordinal>
/// plugin:<plugin-id>/mcp:<server-name>
/// ```
///
/// Rules this ledger enforces:
///
/// * A collision NEVER overwrites an earlier contribution: two plugins
///   both contributing `review` coexist as two canonical tools, and the
///   bare alias `review` becomes ambiguous — [resolveAlias] then returns
///   the exact list of canonical options and the caller must not execute.
/// * Bare aliases exist only when unique (§4.4).
/// * Session scoping (§7): a `sessionActive` plugin is visible ONLY in
///   its `immediateSessionId`; `globalActive`/`degraded` are visible in
///   every session; `pendingGlobal`/`failed`/`disabled` are visible in
///   none. Callers resolve by the RUNNING session id — never the
///   foreground session.
///
/// Scope of this leaf: registry state + resolution logic ONLY. Install
/// transactions and activation persistence are Task 7 (`plugin_runtime`);
/// hook consumption is Task 8; plugin-owned MCP servers/tools extend this
/// registry in Task 9. Content execution lives in the caller (the agent
/// dispatch) — the registry never touches the filesystem or the UI.
library;

import 'plugin_manifest.dart';

/// The contribution kind — the segment after `plugin:<plugin-id>/` in a
/// canonical §4.4 id.
enum PluginContributionKind { command, skill, agent, hook, mcpServer }

/// One registered contribution of one plugin (spec §4.4). Metadata only:
/// the declaring file's CONTENT is read by the executing caller under its
/// own gates.
class PluginContribution {
  final PluginContributionKind kind;

  /// Canonical id, taken verbatim from the source record's `canonicalId`.
  final String canonicalId;

  /// Owning plugin's canonical id (`publisher/name`).
  final String pluginId;

  /// Bare contribution name (command/skill/agent name, hook event, MCP
  /// server name).
  final String name;

  /// Root directory of the plugin content (from the manifest).
  final String rootPath;

  /// Source-relative path of the declaring file (`''` for hook/MCP
  /// records whose payload is not a single readable instruction file).
  final String path;

  /// Frontmatter `description` when the contribution declares one.
  final String description;

  /// Model-visible tool name: the canonical id sanitized to the
  /// provider-safe function-name alphabet (`[A-Za-z0-9_-]`).
  final String toolName;

  PluginContribution({
    required this.kind,
    required this.canonicalId,
    required this.pluginId,
    required this.name,
    this.rootPath = '',
    this.path = '',
    this.description = '',
  }) : toolName = canonicalId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  factory PluginContribution.fromCommand(
    PluginCommand c,
    String rootPath,
  ) => PluginContribution(
    kind: PluginContributionKind.command,
    canonicalId: c.canonicalId,
    pluginId: c.pluginId,
    name: c.name,
    rootPath: rootPath,
    path: c.path,
    description: _descriptionOf(c.frontmatter),
  );

  factory PluginContribution.fromSkill(PluginSkill s, String rootPath) =>
      PluginContribution(
        kind: PluginContributionKind.skill,
        canonicalId: s.canonicalId,
        pluginId: s.pluginId,
        name: s.name,
        rootPath: rootPath,
        path: s.path,
        description: _descriptionOf(s.frontmatter),
      );

  factory PluginContribution.fromAgent(PluginAgent a, String rootPath) =>
      PluginContribution(
        kind: PluginContributionKind.agent,
        canonicalId: a.canonicalId,
        pluginId: a.pluginId,
        name: a.name,
        rootPath: rootPath,
        path: a.path,
        description: _descriptionOf(a.frontmatter),
      );

  factory PluginContribution.fromHook(PluginHook h, String rootPath) =>
      PluginContribution(
        kind: PluginContributionKind.hook,
        canonicalId: h.canonicalId,
        pluginId: h.pluginId,
        name: h.event,
        rootPath: rootPath,
        path: h.path,
      );

  factory PluginContribution.fromMcpServer(
    PluginMcpServer s,
    String rootPath,
  ) => PluginContribution(
    kind: PluginContributionKind.mcpServer,
    canonicalId: s.canonicalId,
    pluginId: s.pluginId,
    name: s.name,
    rootPath: rootPath,
    path: s.path,
  );

  static String _descriptionOf(Map<String, dynamic> frontmatter) =>
      frontmatter['description']?.toString() ?? '';

  /// Human-readable kind for agent/UI messages.
  String get kindLabel => switch (kind) {
    PluginContributionKind.command => 'command',
    PluginContributionKind.skill => 'skill',
    PluginContributionKind.agent => 'agent',
    PluginContributionKind.hook => 'hook',
    PluginContributionKind.mcpServer => 'mcp server',
  };

  /// True when the declaring [path] is a relative path with no `..`
  /// escape — the ONLY paths an executor may read. Malformed/hostile
  /// manifest paths (absolute, drive-lettered, escaping) stay in the
  /// ledger but can never be executed.
  bool get pathContained =>
      path.isNotEmpty && isLexicallySafeRelPath(path);

  /// Command/skill/agent contributions are the roster tools; hook and MCP
  /// wiring is consumed by Task 8/9 respectively.
  bool get isRosterTool =>
      kind == PluginContributionKind.command ||
      kind == PluginContributionKind.skill ||
      kind == PluginContributionKind.agent;
}

/// Result of a bare-alias resolution (spec §4.4): unique → one
/// contribution; ambiguous → the exact canonical option list and NO
/// execution; absent → no registered contribution carries this alias.
class AliasResolution {
  /// Matching command/skill/agent contributions, sorted by canonical id
  /// (deterministic across calls).
  final List<PluginContribution> matches;

  const AliasResolution(this.matches);

  bool get isAbsent => matches.isEmpty;
  bool get isUnique => matches.length == 1;
  bool get isAmbiguous => matches.length > 1;

  /// The single match when [isUnique], else null.
  PluginContribution? get unique => isUnique ? matches.first : null;

  /// The exact canonical ids an ambiguous-alias chooser must list.
  List<String> get options =>
      List.unmodifiable(matches.map((m) => m.canonicalId));
}

class _Registration {
  _Registration(
    this.manifest,
    this.activation,
    this.immediateSessionId,
    this.contributions,
  );

  final NormalizedPluginManifest manifest;
  final PluginActivation activation;
  final String? immediateSessionId;

  /// Every contribution of the manifest (all five kinds), manifest order.
  final List<PluginContribution> contributions;
}

/// The namespaced contribution ledger (spec §4.4) with §7 session
/// scoping. One process-wide instance ([I]) serves the agent roster and
/// dispatch; tests may build isolated instances.
class PluginContributionRegistry {
  PluginContributionRegistry();

  static final PluginContributionRegistry I = PluginContributionRegistry();

  /// Insertion-ordered by plugin id (Dart maps keep first-insert order,
  /// so a re-register preserves a plugin's roster position).
  final Map<String, _Registration> _registrations = {};

  /// Registers (or re-registers, for upgrades/activation changes) every
  /// contribution of [manifest] under its canonical ids. Re-registering
  /// the SAME plugin id replaces that plugin's entries in place — the
  /// install transaction (Task 7) uses this for promotion. Contributions
  /// of DIFFERENT plugins never collide: canonical ids are namespaced by
  /// plugin id, and a shared bare name becomes an ambiguous alias instead
  /// of an overwrite.
  ///
  /// A manifest without a canonical identity registers nothing —
  /// adapters/inspection report that as a required issue (Task 2/5).
  void register(
    NormalizedPluginManifest manifest, {
    required PluginActivation activation,
    String? immediateSessionId,
  }) {
    if (manifest.id.isEmpty) return;
    final contributions = <PluginContribution>[
      ...manifest.commands.map(
        (c) => PluginContribution.fromCommand(c, manifest.rootPath),
      ),
      ...manifest.skills.map(
        (s) => PluginContribution.fromSkill(s, manifest.rootPath),
      ),
      ...manifest.agents.map(
        (a) => PluginContribution.fromAgent(a, manifest.rootPath),
      ),
      ...manifest.hooks.map(
        (h) => PluginContribution.fromHook(h, manifest.rootPath),
      ),
      ...manifest.mcpServers.map(
        (s) => PluginContribution.fromMcpServer(s, manifest.rootPath),
      ),
    ];
    _registrations[manifest.id] = _Registration(
      manifest,
      activation,
      immediateSessionId,
      contributions,
    );
  }

  /// Removes every contribution of [pluginId] (disable/uninstall/rollback
  /// — spec §9). True when a registration was removed.
  bool unregisterPlugin(String pluginId) =>
      _registrations.remove(pluginId) != null;

  /// §7 visibility: `globalActive`/`degraded` are visible in every
  /// session; `sessionActive` ONLY in its `immediateSessionId` (an empty
  /// or missing session id never matches — fail-closed);
  /// `pendingGlobal`/`failed`/`disabled`/unregistered are visible in none.
  bool isPluginActiveForSession(String pluginId, String sessionId) {
    final reg = _registrations[pluginId];
    if (reg == null) return false;
    return _visible(reg, sessionId);
  }

  static bool _visible(_Registration reg, String sessionId) {
    switch (reg.activation) {
      // Degraded stays mounted (optional findings only — spec §4.3);
      // honesty about the degradation is the reporter's job, not a
      // silent unmount.
      case PluginActivation.globalActive:
      case PluginActivation.degraded:
        return true;
      case PluginActivation.sessionActive:
        final sid = reg.immediateSessionId;
        return sid != null && sid.isNotEmpty && sid == sessionId;
      case PluginActivation.pendingGlobal:
      case PluginActivation.failed:
      case PluginActivation.disabled:
        return false;
    }
  }

  /// The canonical command/skill/agent contributions visible to
  /// [sessionId], in registration order then manifest order — the
  /// session-scoped tool roster source (spec §7: scoping is enforced at
  /// tool-roster resolution, never only in UI state).
  List<PluginContribution> toolsForSession(String sessionId) {
    final out = <PluginContribution>[];
    for (final reg in _registrations.values) {
      if (!_visible(reg, sessionId)) continue;
      out.addAll(reg.contributions.where((c) => c.isRosterTool));
    }
    return List.unmodifiable(out);
  }

  /// Resolves a bare alias (spec §4.4: `/review`, `skill`, …). Leading
  /// `/` is stripped; matching is case-insensitive against
  /// command/skill/agent names (bare hook/MCP alias semantics belong to
  /// Task 8/9). When [sessionId] is supplied only contributions visible
  /// to that session count — a session-scoped plugin from ANOTHER session
  /// can neither be called nor make an alias ambiguous here. Without a
  /// session id every registered contribution counts (gates/UI listing).
  AliasResolution resolveAlias(String alias, {String? sessionId}) {
    var bare = alias.trim();
    if (bare.startsWith('/')) bare = bare.substring(1);
    if (bare.isEmpty) return const AliasResolution([]);
    final lower = bare.toLowerCase();
    final matches = <PluginContribution>[];
    for (final reg in _registrations.values) {
      if (sessionId != null && !_visible(reg, sessionId)) continue;
      for (final c in reg.contributions) {
        if (!c.isRosterTool) continue;
        if (c.name.toLowerCase() == lower) matches.add(c);
      }
    }
    matches.sort((a, b) => a.canonicalId.compareTo(b.canonicalId));
    return AliasResolution(List.unmodifiable(matches));
  }

  /// The contribution a model-visible tool name addresses, regardless of
  /// session visibility — the CALLER enforces
  /// [isPluginActiveForSession] and must refuse out-of-scope calls
  /// instead of executing (spec §7). First registration wins a tool name
  /// in the pathological case two canonical ids sanitize identically;
  /// the shadowed contribution stays addressable by canonical id.
  PluginContribution? contributionByToolName(String toolName) {
    for (final reg in _registrations.values) {
      for (final c in reg.contributions) {
        if (c.toolName == toolName) return c;
      }
    }
    return null;
  }

  /// Exact canonical §4.4 id lookup, regardless of session visibility —
  /// the caller enforces scoping.
  PluginContribution? contributionByCanonicalId(String canonicalId) {
    for (final reg in _registrations.values) {
      for (final c in reg.contributions) {
        if (c.canonicalId == canonicalId) return c;
      }
    }
    return null;
  }

  /// Every roster-tool contribution of [pluginId] whatever its activation
  /// — honest install reporting ("what does this plugin contribute?").
  List<PluginContribution> toolContributionsForPlugin(String pluginId) {
    final reg = _registrations[pluginId];
    if (reg == null) return const [];
    return List.unmodifiable(
      reg.contributions.where((c) => c.isRosterTool),
    );
  }

  /// The registered activation state, or null when unregistered.
  PluginActivation? activationFor(String pluginId) =>
      _registrations[pluginId]?.activation;

  /// The registered manifest of [pluginId], or null when unregistered.
  /// Lets permission/revocation surfaces (spec §5.1) reach the exact
  /// normalized manifest a plugin runs under without re-inspecting disk.
  NormalizedPluginManifest? manifestFor(String pluginId) =>
      _registrations[pluginId]?.manifest;

  bool isRegistered(String pluginId) => _registrations.containsKey(pluginId);

  /// Plugin ids with registered contributions, in registration order.
  Iterable<String> get registeredPluginIds => _registrations.keys;
}

/// True when [rel] is a relative path with no `..` escape, no leading
/// separator, and no drive letter — the containment rule every
/// contribution `path` must pass before an executor may read it. Mirrors
/// the source resolver's lexical validation (spec §4.2).
bool isLexicallySafeRelPath(String rel) {
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
