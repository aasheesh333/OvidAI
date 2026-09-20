import 'dart:convert';
import 'dart:io';

import 'state.dart' show shellSplitArgs;

/// ── MCP config parsing (core) ───────────────────────────────────────────
/// Pure, dependency-free parsing of the MCP server config shapes Ovid
/// accepts. Extracted from the Plugins screen so `lib/core` code (the
/// plugin compatibility adapters) can reuse it without a core→ui import.
///
/// The UI keeps a thin delegate seam (`parseMcpConfigForTest`) over these
/// same functions, so behavior is shared rather than duplicated.

/// One MCP server entry parsed out of a config blob.
class ImportedMcp {
  final String name;
  final String command;
  final List<String> args;
  final Map<String, String> env;

  /// Non-null → this entry is a Streamable-HTTP (remote) server.
  final String? url;
  final Map<String, String> headers;

  /// Resolved transport ('stdio' | 'http' | 'sse').
  final String type;
  final String? cwd;
  final int? startupTimeoutS;

  /// Keys present in the source config that Ovid doesn't understand —
  /// surfaced to the user instead of silently dropped.
  final List<String> ignoredKeys;

  /// Non-secret values for unknown declaration fields. Secret-bearing
  /// env/header maps are deliberately not copied here.
  final Map<String, dynamic> ignoredFields;

  ImportedMcp({
    required this.name,
    required this.command,
    required this.args,
    this.env = const {},
    this.url,
    this.headers = const {},
    this.type = 'stdio',
    this.cwd,
    this.startupTimeoutS,
    this.ignoredKeys = const [],
    this.ignoredFields = const {},
  });
}

final _mcpVarPattern = RegExp(r'\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}');

/// Expand `${VAR}` / `${VAR:-default}` references in an MCP config value
/// against [env] (both [CC] `.mcp.json` and Codex `config.toml` rely on
/// this). A reference whose variable has a non-empty value is replaced by
/// that value; otherwise the `:-default` is used when present and
/// [allowDefault] is true. A reference with neither a value nor an allowed
/// default is left intact as the literal `${VAR}` so the credential gate can
/// still detect the required name.
String interpolateMcpValue(
  String value,
  Map<String, String> env, {
  bool allowDefault = true,
}) {
  if (!value.contains(r'${')) return value;
  return value.replaceAllMapped(_mcpVarPattern, (match) {
    final resolved = env[match.group(1)!];
    if (resolved != null && resolved.isNotEmpty) return resolved;
    if (allowDefault && match.group(2) != null) return match.group(3) ?? '';
    return match.group(0)!;
  });
}

/// Parse a pasted MCP config. Accepts the `mcpServers` map ([CC] /
/// claude_desktop / standard shape), a bare top-level JSON array, the
/// `mcp_servers`/`servers` aliases, and Codex's TOML `[mcp_servers.<name>]`
/// blocks (single or double quotes, multi-line `args`, `[.env]`/`[.headers]`
/// sub-tables, `cwd`/`type`).
///
/// [env] supplies `${VAR}` / `${VAR:-default}` values; it defaults to the
/// process environment.
List<ImportedMcp> parseMcpConfig(String raw, {Map<String, String>? env}) {
  final resolvedEnv = env ?? Platform.environment;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const [];
  if (trimmed.startsWith('{')) {
    return _parseMcpJson(trimmed, resolvedEnv);
  }
  if (trimmed.startsWith('[')) {
    // Ambiguous: a JSON array OR a TOML `[mcp_servers.foo]` block. A TOML
    // section never decodes as JSON, so try JSON first and fall back to
    // TOML when it doesn't parse.
    final asJson = _parseMcpJson(trimmed, resolvedEnv);
    if (asJson.isNotEmpty) return asJson;
  }
  return _parseMcpToml(trimmed, resolvedEnv);
}

List<ImportedMcp> _parseMcpJson(String raw, Map<String, String> env) {
  final out = <ImportedMcp>[];
  dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return out;
  }
  if (decoded is List) {
    for (final e in decoded) {
      if (e is Map) {
        final name = (e['name'] as String? ?? '').trim();
        if (name.isNotEmpty) {
          out.add(
            importedMcpFromJson(name, e.cast<String, dynamic>(), env: env),
          );
        }
      }
    }
    return out;
  }
  if (decoded is! Map) return out;
  final j = decoded.cast<String, dynamic>();
  final servers = j['mcpServers'] ?? j['mcp_servers'] ?? j['servers'];
  if (servers is Map) {
    for (final e in servers.entries) {
      final v = e.value;
      if (v is Map) {
        out.add(
          importedMcpFromJson(
            e.key.toString(),
            v.cast<String, dynamic>(),
            env: env,
          ),
        );
      }
    }
  } else if (servers is List) {
    for (final v in servers) {
      if (v is Map) {
        final name = (v['name'] as String? ?? '').trim();
        if (name.isNotEmpty) {
          out.add(
            importedMcpFromJson(name, v.cast<String, dynamic>(), env: env),
          );
        }
      }
    }
  }
  return out;
}

/// Keys we understand in a JSON MCP server entry — anything else is an
/// *ignored key* surfaced to the user rather than silently dropped.
const _knownMcpJsonKeys = {
  'name',
  'command',
  'cmd',
  'args',
  'env',
  'url',
  'headers',
  'cwd',
  'type',
  'transport',
  'description',
  'author',
  'category',
  'timeout',
  'startupTimeoutS',
  'startup_timeout_s',
};

/// Map one JSON server entry into an [ImportedMcp]. [env] supplies
/// `${VAR}` / `${VAR:-default}` values; it defaults to the process
/// environment.
ImportedMcp importedMcpFromJson(
  String name,
  Map<String, dynamic> v, {
  Map<String, String>? env,
}) {
  final resolvedEnv = env ?? Platform.environment;
  final rawUrl = (v['url'] as String?)?.trim();
  final url = rawUrl == null
      ? null
      : interpolateMcpValue(rawUrl, resolvedEnv);
  final explicitType = ((v['transport'] as String?) ?? (v['type'] as String?))
      ?.trim()
      .toLowerCase();
  final type = explicitType != null && explicitType.isNotEmpty
      ? explicitType
      : (url != null && url.isNotEmpty ? 'http' : 'stdio');
  final argsRaw = v['args'];
  final args = argsRaw is List
      ? argsRaw.whereType<String>().toList()
      : argsRaw is String
      ? shellSplitArgs(argsRaw)
      : <String>[];
  final rawCwd = (v['cwd'] as String?)?.trim();
  return ImportedMcp(
    name: name,
    // No silent default: a stdio entry without `command`/`cmd` keeps an
    // empty command so connect fails loudly naming the missing field
    // instead of spawning an unrelated binary.
    command:
        (v['command'] as String?) ?? (v['cmd'] as String?) ?? '',
    args: [for (final a in args) interpolateMcpValue(a, resolvedEnv)],
    env: mcpStringMap(v['env'], env: resolvedEnv),
    url: url != null && url.isNotEmpty ? url : null,
    headers: mcpStringMap(v['headers'], env: resolvedEnv),
    cwd: rawCwd == null ? null : interpolateMcpValue(rawCwd, resolvedEnv),
    type: type,
    startupTimeoutS:
        (v['timeout'] as num?)?.toInt() ??
        (v['startupTimeoutS'] as num?)?.toInt(),
    ignoredKeys: v.keys.where((k) => !_knownMcpJsonKeys.contains(k)).toList(),
    ignoredFields: {
      for (final e in v.entries)
        if (!_knownMcpJsonKeys.contains(e.key)) e.key: e.value,
    },
  );
}

Map<String, String> mcpStringMap(
  dynamic m, {
  Map<String, String> env = const {},
}) {
  if (m is! Map) return const {};
  return m.map(
    (k, v) => MapEntry(k.toString(), interpolateMcpValue(v.toString(), env)),
  );
}

/// Mutable accumulator for one TOML `[mcp_servers.<name>]` block.
/// `command` stays null until declared — a missing command must fail loudly
/// at connect time, never silently spawn a default binary.
class _TomlServerAgg {
  final String name;
  String? command;
  List<String> args = const [];
  String? url;
  String? cwd;
  String? type;
  int? timeout;
  final Map<String, String> env = {};
  final Map<String, String> headers = {};
  final List<String> ignoredKeys = [];
  final Map<String, dynamic> ignoredFields = {};
  _TomlServerAgg(this.name);
}

List<ImportedMcp> _parseMcpToml(String raw, Map<String, String> env) {
  final servers = <String, _TomlServerAgg>{};
  _TomlServerAgg serverFor(String name) =>
      servers.putIfAbsent(name, () => _TomlServerAgg(name));

  _TomlServerAgg? current;
  String? currentSub; // null | 'env' | 'headers'
  final lines = raw.split('\n');
  var i = 0;
  while (i < lines.length) {
    final line = lines[i].trim();
    if (line.isEmpty || line.startsWith('#')) {
      i++;
      continue;
    }
    final sec = _tomlSection(line);
    if (sec != null) {
      current = serverFor(sec.name);
      currentSub = sec.sub;
      i++;
      continue;
    }
    // A non-MCP TOML table (for example `[environment]`) ends the current
    // MCP server context; its keys must not become server unknown fields.
    if (line.startsWith('[') && line.endsWith(']')) {
      current = null;
      currentSub = null;
      i++;
      continue;
    }
    final eq = _indexOfAssignment(line);
    if (eq < 0) {
      i++;
      continue; // stray line (e.g. closing `]` of a multiline array)
    }
    final key = line.substring(0, eq).trim();
    final valueRaw = line.substring(eq + 1).trim();

    if (currentSub == 'env') {
      current?.env[unquoteToml(key)] = unquoteToml(valueRaw);
      i++;
      continue;
    }
    if (currentSub == 'headers') {
      current?.headers[key] = unquoteToml(valueRaw);
      i++;
      continue;
    }
    if (current == null) {
      i++;
      continue;
    }

    switch (key.toLowerCase()) {
      case 'command':
        current.command = unquoteToml(valueRaw);
        i++;
        break;
      case 'url':
        current.url = unquoteToml(valueRaw);
        i++;
        break;
      case 'cwd':
        current.cwd = unquoteToml(valueRaw);
        i++;
        break;
      case 'type':
      case 'transport':
        current.type = unquoteToml(valueRaw).toLowerCase();
        i++;
        break;
      case 'timeout':
      case 'startuptimeouts':
        current.timeout = int.tryParse(unquoteToml(valueRaw));
        i++;
        break;
      default:
        if (key.startsWith('env.')) {
          current.env[key.substring(4)] = unquoteToml(valueRaw);
          i++;
        } else if (key.toLowerCase().startsWith('headers.')) {
          current.headers[key.substring(8)] = unquoteToml(valueRaw);
          i++;
        } else if (key.toLowerCase() == 'args') {
          var buf = valueRaw;
          if (buf.contains('[') || buf.contains(']')) {
            var open = _countChar(buf, '[') - _countChar(buf, ']');
            while (open > 0 && i + 1 < lines.length) {
              i++;
              buf += ' ${lines[i].trim()}';
              open = _countChar(buf, '[') - _countChar(buf, ']');
            }
            current.args = _parseArgsArray(buf);
          } else {
            current.args = shellSplitArgs(unquoteToml(buf));
          }
          i++;
        } else {
          current.ignoredKeys.add(key);
          current.ignoredFields[key] = unquoteToml(valueRaw);
          i++;
        }
        break;
    }
  }

  return [for (final a in servers.values) _importedFromToml(a, env)];
}

ImportedMcp _importedFromToml(_TomlServerAgg a, Map<String, String> env) {
  final rawUrl = a.url;
  final url = rawUrl == null ? null : interpolateMcpValue(rawUrl, env);
  final resolvedType = a.type != null && a.type!.isNotEmpty
      ? a.type!
      : (url != null && url.isNotEmpty ? 'http' : 'stdio');
  return ImportedMcp(
    name: a.name,
    command: resolvedType == 'stdio' ? (a.command ?? '') : '',
    args: [for (final arg in a.args) interpolateMcpValue(arg, env)],
    env: {
      for (final e in a.env.entries)
        e.key: interpolateMcpValue(e.value, env),
    },
    url: url != null && url.isNotEmpty ? url : null,
    headers: {
      for (final e in a.headers.entries)
        e.key: interpolateMcpValue(e.value, env),
    },
    cwd: a.cwd == null ? null : interpolateMcpValue(a.cwd!, env),
    type: resolvedType,
    startupTimeoutS: a.timeout,
    ignoredKeys: a.ignoredKeys,
    ignoredFields: a.ignoredFields,
  );
}

/// Parse a TOML section header `[a.b.c]` into its name + optional sub-table
/// kind. Handles both the bare key (`[mcp_servers.foo]`) and the quoted-key
/// form (`["mcp_servers.foo.env"]`). Returns null for non-MCP sections.
({String name, String? sub})? _tomlSection(String t) {
  if (!t.startsWith('[') || !t.endsWith(']')) return null;
  var inner = t.substring(1, t.length - 1).trim();
  if (inner.length >= 2 && inner.startsWith('"') && inner.endsWith('"')) {
    inner = inner.substring(1, inner.length - 1);
  }
  final parts = inner.split('.');
  if (parts.length < 2) return null;
  final root = parts.first.toLowerCase();
  final isMcp =
      root == 'mcp_servers' || root == 'mcpservers' || root == 'servers';
  if (!isMcp) return null;
  final name = parts[1];
  final sub = parts.length >= 3
      ? parts.sublist(2).join('.').toLowerCase()
      : null;
  return (name: name, sub: sub);
}

int _indexOfAssignment(String s) {
  var inS = false, inD = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == "'" && !inD) {
      inS = !inS;
    } else if (c == '"' && !inS) {
      inD = !inD;
    } else if (c == '=' && !inS && !inD) {
      return i;
    }
  }
  return -1;
}

/// Strip surrounding TOML quotes from a scalar value.
String unquoteToml(String v) {
  var s = v.trim();
  if (s.length >= 2) {
    final f = s[0], l = s[s.length - 1];
    if ((f == '"' && l == '"') || (f == "'" && l == "'")) {
      s = s.substring(1, s.length - 1);
    } else if (f == '"' || f == "'") {
      s = s.substring(1);
    }
  }
  return s;
}

int _countChar(String s, String ch) => ch.allMatches(s).length;

List<String> _parseArgsArray(String s) {
  final start = s.indexOf('[');
  final end = s.lastIndexOf(']');
  if (start < 0) return shellSplitArgs(unquoteToml(s));
  final inner = s.substring(start + 1, end < 0 ? s.length : end);
  final out = <String>[];
  final re = RegExp("'([^']*)'|\"([^\"]*)\"");
  for (final m in re.allMatches(inner)) {
    out.add(m.group(1) ?? m.group(2) ?? '');
  }
  return out;
}
