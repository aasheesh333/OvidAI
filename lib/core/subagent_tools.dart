import 'dart:async';

import 'claude_code_tools.dart';

/// Claude Code subagent tool scoping (sub-agents docs, "Tool and MCP
/// inheritance"), owner-tightened: a subagent can NEVER spawn a subagent.
///
/// A subagent definition carries an optional `tools` allowlist and an
/// optional `disallowedTools` denylist. Ovid persists both in the child
/// session's `agentAllowedTools` list — denylist entries are prefixed with
/// `!` — so cold-resumed children keep the same scope without a schema change.
///
/// Entries may be:
///  * a native Ovid tool name (`fs_edit`, `plugin__x__y`),
///  * a Claude Code tool name (`Read`, `Edit`, `Bash`, `Agent`/`Task`, ...),
///    expanded through [ClaudeCodeTools.nativeToolsFor],
///  * an MCP tool `mcp__<server>__<tool>`, a server pattern `mcp__<server>`
///    or `mcp__<server>__*`, or `mcp__*` (every MCP tool),
///  * any name with a trailing `*` (prefix match),
///  * a permission-rule specifier such as `Bash(git push *)`, which scopes
///    the WHOLE tool (Claude Code: a specifier still grants/removes the tool).
///
/// Omitted / empty `tools` = inherit every tool the parent has. Filter 1 of
/// the docs ([alwaysDenied]) always applies, even when listed in `tools`.
class SubagentToolPolicy {
  SubagentToolPolicy._(this.allow, this.deny);

  /// Parse the persisted `agentAllowedTools` list.
  factory SubagentToolPolicy.fromStored(Iterable<String> stored) {
    final allow = <String>[];
    final deny = <String>[];
    for (final raw in stored) {
      final entry = raw.trim();
      if (entry.isEmpty) continue;
      if (entry.startsWith('!')) {
        final d = entry.substring(1).trim();
        if (d.isNotEmpty) deny.add(d);
      } else {
        allow.add(entry);
      }
    }
    return SubagentToolPolicy._(
      List.unmodifiable(allow),
      List.unmodifiable(deny),
    );
  }

  /// Encode a definition's `tools` / `disallowedTools` for persistence.
  static List<String> encode({
    Iterable<String> tools = const [],
    Iterable<String> disallowed = const [],
  }) => [
    for (final t in tools)
      if (t.trim().isNotEmpty) t.trim(),
    for (final d in disallowed)
      if (d.trim().isNotEmpty) '!${d.trim()}',
  ];

  /// Allowlist entries (empty = inherit all).
  final List<String> allow;

  /// Denylist entries.
  final List<String> deny;

  /// Spawn tools: removed from EVERY subagent regardless of its `tools`
  /// field (owner rule: a subagent cannot trigger another subagent). Plugin
  /// agent contributions are covered separately by [isSpawnTool].
  static const spawnTools = {'dispatch_agent', 'workflow', 'ralph'};

  /// Docs filter 1 (user-facing / main-thread-only tools) plus [spawnTools].
  static const alwaysDenied = {
    ...spawnTools,
    'ask_user_question',
    'exit_plan_mode',
    'request_permission',
    'request_working_folder',
  };

  /// True when [native] would start another agent: the core spawners, or a
  /// plugin `agents/*.md` contribution tool (which dispatches a subagent).
  static bool isSpawnTool(String native, {bool isAgentContribution = false}) =>
      spawnTools.contains(native) || isAgentContribution;

  bool get inheritsAll => allow.isEmpty || allow.contains('*');

  /// Whether a subagent bound by this policy may see / call [native].
  bool allows(String native, {bool isAgentContribution = false}) {
    if (alwaysDenied.contains(native)) return false;
    if (isSpawnTool(native, isAgentContribution: isAgentContribution)) {
      return false;
    }
    if (deny.any((d) => entryMatches(d, native, denyList: true))) return false;
    if (inheritsAll) return true;
    return allow.any((a) => entryMatches(a, native));
  }

  /// Display form of the allowlist for prompts and the subagent screen.
  String describe() {
    final parts = <String>[
      if (inheritsAll) 'all parent tools' else allow.join(', '),
      if (deny.isNotEmpty) 'except ${deny.join(', ')}',
    ];
    return parts.join(' ');
  }

  /// Does one `tools` / `disallowedTools` [entry] cover native tool [native]?
  static bool entryMatches(
    String entry,
    String native, {
    bool denyList = false,
  }) {
    var base = entry.trim();
    final paren = base.indexOf('(');
    if (paren > 0 && base.endsWith(')')) base = base.substring(0, paren).trim();
    if (base.isEmpty) return false;
    if (base == '*') return true;
    if (base == native) return true;
    if (base.startsWith('mcp__')) {
      if (!native.startsWith('mcp__')) return false;
      if (base == 'mcp__*' || base == 'mcp__') return true;
      if (base.endsWith('*')) {
        return native.startsWith(base.substring(0, base.length - 1));
      }
      // `mcp__<server>` (no tool segment) grants the whole server.
      if (!base.substring(5).contains('__')) {
        return native.startsWith('${base}__');
      }
      return false;
    }
    if (ClaudeCodeTools.nativeToolsFor(base).contains(native)) return true;
    if (base.endsWith('*') && base.length > 1) {
      return native.startsWith(base.substring(0, base.length - 1));
    }
    return false;
  }
}

/// Identity of the subagent a piece of work runs inside, carried as a Zone
/// value so services below the agent loop (MCP client, usage store, hooks)
/// can attribute their work without importing the agent service.
class SubagentScope {
  const SubagentScope({
    required this.agentId,
    required this.agentType,
    required this.sessionId,
    required this.rootSessionId,
  });

  /// Durable handle id (`sub-N`) — Claude Code's `agent_id`.
  final String agentId;

  /// Definition name (`general-purpose`, `my-plugin:reviewer`) — Claude
  /// Code's `agent_type`.
  final String agentType;

  /// The child session id.
  final String sessionId;

  /// The root (main conversation) session id.
  final String rootSessionId;

  static final Object _key = Object();

  /// The subagent the current zone runs inside, if any.
  static SubagentScope? get current {
    final v = Zone.current[_key];
    return v is SubagentScope ? v : null;
  }

  /// Run [body] attributed to this subagent.
  R run<R>(R Function() body) => runZoned(body, zoneValues: {_key: this});
}

/// Claude Code `model:` resolution for a subagent definition.
///
/// `inherit`, blank or absent → the parent's model. A full model id is used
/// as-is. A Claude alias (`sonnet`, `opus`, `haiku`, `fable`) resolves to the
/// first model of the parent's provider whose id contains the alias; when the
/// provider offers none the parent's model is inherited (an alias must never
/// become a literal model id the provider rejects).
String? resolveSubagentModel(
  String? declared, {
  required String parentModel,
  Iterable<String> providerModels = const [],
}) {
  final d = declared?.trim() ?? '';
  if (d.isEmpty || d.toLowerCase() == 'inherit') return null;
  const aliases = {'sonnet', 'opus', 'haiku', 'fable'};
  if (aliases.contains(d.toLowerCase())) {
    final alias = d.toLowerCase();
    if (parentModel.toLowerCase().contains(alias)) return null;
    for (final m in providerModels) {
      if (m.toLowerCase().contains(alias)) return m;
    }
    return null;
  }
  return d;
}

/// Parse a frontmatter list value (`a, b`, `[a, b]` or a YAML block list
/// joined with newlines). Unlike the skill parser it keeps permission-rule
/// specifiers with spaces (`Bash(git push *)`) intact.
List<String> parseFrontmatterList(String? value) {
  if (value == null) return const [];
  var body = value.trim();
  if (body.startsWith('[') && body.endsWith(']')) {
    body = body.substring(1, body.length - 1);
  }
  final out = <String>[];
  final buf = StringBuffer();
  var depth = 0;
  void flush() {
    final t = buf.toString().trim().replaceAll('"', '').replaceAll("'", '');
    if (t.isNotEmpty) out.add(t);
    buf.clear();
  }

  for (final ch in body.split('')) {
    if (ch == '(') depth++;
    if (ch == ')' && depth > 0) depth--;
    if (depth == 0 && (ch == ',' || ch == '\n')) {
      flush();
      continue;
    }
    buf.write(ch);
  }
  flush();
  // A bare space-separated list (`tools: Read Grep Glob`) without commas.
  if (out.length == 1 && !out.first.contains('(') && out.first.contains(' ')) {
    return out.first.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  }
  return out;
}
