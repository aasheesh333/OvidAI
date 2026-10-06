import 'dart:convert';

import 'mcp_service.dart';
import 'plugin_registry.dart';
import 'state.dart';

/// Thin, typed exposure of the MCP **prompts/resources** catalogs as
/// agent-callable tools.
///
/// [McpService] already owns the protocol-level, capability-gated catalogs
/// (`listPrompts`, `listResources`, `listResourceTemplates`, `getPrompt`,
/// `readResource`). Those methods return raw, frozen protocol maps and throw
/// protocol/transport errors directly. This layer does NOT re-implement or
/// extend them — it only:
///
///   • maps each raw catalog item into a typed, agent-shaped [McpCatalogEntry]
///     (identity, title/description, prompt arguments, mime type);
///   • attaches the owning server's **per-owner visibility note** so the model
///     knows when a plugin-scoped server is out of session scope;
///   • bounds both the entry count and the rendered character count so a
///     chatty server cannot flood the context;
///   • refuses **native** transport with [UnsupportedError] rather than
///     pretending catalog methods work there.
///
/// The agent loop owns tool advertisement and dispatch. The exact two-line
/// integration is documented in the accompanying report; this file stays
/// controller-agnostic and depends only on [McpCatalogBackend], so a test can
/// drive it with a fake.
enum McpCatalogKind {
  prompts('prompts', 'prompt'),
  resources('resources', 'resource'),
  resourceTemplates('resourceTemplates', 'resource template');

  const McpCatalogKind(this.wireField, this.label);

  /// The JSON field name the service uses for this catalog (`prompts`,
  /// `resources`, `resourceTemplates`).
  final String wireField;

  /// Singular human label used in rendered results.
  final String label;
}

/// Resolved metadata for one MCP server, enough to build visibility notes and
/// reject unsupported transports without touching the transport itself.
class McpCatalogServer {
  const McpCatalogServer({
    required this.name,
    required this.transport,
    this.ownerPluginId,
    this.ownerVisible = true,
  });

  /// Canonical id used for service calls (owner-qualified when plugin-owned).
  final String name;
  final String transport;
  final String? ownerPluginId;

  /// Whether the owner plugin is active for the current session. Always true
  /// for user-owned (ownerless) servers.
  final bool ownerVisible;

  bool get isNative => transport == 'native';

  /// The per-owner visibility note surfaced to the model.
  String get visibilityNote {
    final owner = ownerPluginId;
    if (owner == null || owner.isEmpty) {
      return 'user-owned server — visible in every session';
    }
    return ownerVisible
        ? 'owned by plugin "$owner" — visible in this session'
        : 'owned by plugin "$owner" — NOT visible in this session; '
              'calls are refused until the plugin is active here';
  }

  Map<String, dynamic> toJson() => {
    'server': name,
    'transport': transport,
    'owner_plugin': ownerPluginId,
    'owner_visible': ownerVisible,
    'visibility_note': visibilityNote,
  };
}

/// One prompt argument, normalized from the raw `arguments` array.
class McpCatalogArgument {
  const McpCatalogArgument({
    required this.name,
    this.description,
    this.required = false,
  });

  final String name;
  final String? description;
  final bool required;

  Map<String, dynamic> toJson() => {
    'name': name,
    if (description != null) 'description': description,
    'required': required,
  };
}

/// One catalog item (prompt / resource / resource template) in agent shape.
class McpCatalogEntry {
  const McpCatalogEntry({
    required this.kind,
    required this.server,
    required this.identity,
    this.name,
    this.title,
    this.description,
    this.mimeType,
    this.arguments = const [],
  });

  final McpCatalogKind kind;
  final McpCatalogServer server;

  /// Stable identity: prompt `name`, resource `uri`, template `uriTemplate`.
  final String identity;
  final String? name;
  final String? title;
  final String? description;
  final String? mimeType;
  final List<McpCatalogArgument> arguments;

  Map<String, dynamic> toJson() => {
    'kind': kind.label,
    'identity': identity,
    if (name != null) 'name': name,
    if (title != null) 'title': title,
    if (description != null) 'description': description,
    if (mimeType != null) 'mime_type': mimeType,
    if (arguments.isNotEmpty)
      'arguments': [for (final a in arguments) a.toJson()],
    'owner_plugin': server.ownerPluginId,
    'owner_visible': server.ownerVisible,
    'visibility_note': server.visibilityNote,
  };

  /// One bounded, human-readable line for the rendered tool result.
  String renderLine() {
    final buffer = StringBuffer('- $identity');
    final desc = description;
    if (desc != null && desc.isNotEmpty) buffer.write(' — $desc');
    if (mimeType != null) buffer.write(' [$mimeType]');
    if (arguments.isNotEmpty) {
      final args = [
        for (final a in arguments) a.required ? '${a.name}*' : a.name,
      ];
      buffer.write(' (args: ${args.join(', ')})');
    }
    return buffer.toString();
  }
}

/// Result of a `catalog_mcp_list_*` call: typed entries + count + bounds.
class McpCatalogListResult {
  const McpCatalogListResult({
    required this.tool,
    required this.kind,
    required this.server,
    required this.entries,
    required this.total,
    this.truncated = false,
    this.notice,
  });

  final String tool;
  final McpCatalogKind kind;
  final McpCatalogServer server;
  final List<McpCatalogEntry> entries;

  /// Total entries the server returned before the entry cap was applied.
  final int total;
  final bool truncated;
  final String? notice;

  Map<String, dynamic> toJson() => {
    'tool': tool,
    ...server.toJson(),
    'kind': kind.label,
    'count': entries.length,
    'total': total,
    'truncated': truncated,
    if (notice != null) 'notice': notice,
    'entries': [for (final e in entries) e.toJson()],
  };

  String render({int maxChars = McpCatalogTools.defaultMaxChars}) {
    final buffer = StringBuffer()
      ..writeln('$tool · server "${server.name}" (${server.transport})')
      ..writeln(server.visibilityNote)
      ..writeln(
        '${kind.label}: showing ${entries.length} of $total'
        '${truncated ? ' (bounded)' : ''}',
      );
    if (notice != null) buffer.writeln(notice);
    for (final entry in entries) {
      buffer.writeln(entry.renderLine());
    }
    return boundMcpCatalogText(buffer.toString(), maxChars);
  }
}

/// Result of a `catalog_mcp_get_prompt` / `catalog_mcp_read_resource` call.
///
/// The payload is the service's validated map, passed through unchanged;
/// [render] bounds the JSON handed to the model.
class McpCatalogPayloadResult {
  const McpCatalogPayloadResult({
    required this.tool,
    required this.server,
    required this.payload,
  });

  final String tool;
  final McpCatalogServer server;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => {
    'tool': tool,
    ...server.toJson(),
    'payload': payload,
  };

  String render({int maxChars = McpCatalogTools.defaultMaxChars}) {
    final body = const JsonEncoder.withIndent('  ').convert(payload);
    final header =
        '$tool · server "${server.name}" (${server.transport})\n'
        '${server.visibilityNote}\n';
    return boundMcpCatalogText('$header$body', maxChars);
  }
}

/// Head+tail trim with an exact omission notice, mirroring the tool-result
/// spill behavior. Guarantees the returned string is at most [maxChars].
String boundMcpCatalogText(String text, int maxChars) {
  if (maxChars <= 0) return '';
  if (text.length <= maxChars) return text;
  final omitted = text.length - maxChars;
  final marker =
      '\n\n[…$omitted characters omitted — ask for a narrower catalog '
      'or query…]\n\n';
  final available = maxChars - marker.length;
  if (available <= 0) return text.substring(0, maxChars);
  final head = available ~/ 2;
  final tail = available - head;
  return '${text.substring(0, head)}$marker'
      '${text.substring(text.length - tail)}';
}

/// The service surface this layer needs. Implemented in production by
/// [McpServiceCatalogBackend]; a test supplies a fake.
abstract class McpCatalogBackend {
  Future<McpCatalogServer?> serverInfo(String serverName);

  Future<List<Map<String, dynamic>>> listPrompts(
    String serverName, {
    Duration? timeout,
    bool refresh = false,
  });

  Future<List<Map<String, dynamic>>> listResources(
    String serverName, {
    Duration? timeout,
    bool refresh = false,
  });

  Future<List<Map<String, dynamic>>> listResourceTemplates(
    String serverName, {
    Duration? timeout,
    bool refresh = false,
  });

  Future<Map<String, dynamic>> getPrompt(
    String serverName,
    String name, {
    Map<String, String> arguments = const {},
    Duration? timeout,
  });

  Future<Map<String, dynamic>> readResource(
    String serverName,
    String uri, {
    Duration? timeout,
  });
}

/// Production backend: resolves server metadata from [AppState] (transport,
/// owner, session visibility) and forwards catalog calls straight to
/// [McpService]. No catalog logic is duplicated here.
class McpServiceCatalogBackend implements McpCatalogBackend {
  const McpServiceCatalogBackend({this.sessionId});

  /// Session used for owner visibility. Defaults to the active session.
  final String? sessionId;

  @override
  Future<McpCatalogServer?> serverInfo(String serverName) async {
    final app = AppState.I;
    final match = app.mcpServers
        .where((s) => s.name == serverName || s.canonicalId == serverName)
        .firstOrNull;
    if (match == null) return null;
    final owner = match.ownerPluginId;
    final visible =
        owner == null ||
        PluginContributionRegistry.I.isPluginActiveForSession(
          owner,
          sessionId ?? app.activeSession?.id ?? '',
        );
    return McpCatalogServer(
      name: match.canonicalId,
      transport: match.transport,
      ownerPluginId: owner,
      ownerVisible: visible,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> listPrompts(
    String serverName, {
    Duration? timeout,
    bool refresh = false,
  }) => McpService.I.listPrompts(serverName, timeout: timeout, refresh: refresh);

  @override
  Future<List<Map<String, dynamic>>> listResources(
    String serverName, {
    Duration? timeout,
    bool refresh = false,
  }) => McpService.I.listResources(
    serverName,
    timeout: timeout,
    refresh: refresh,
  );

  @override
  Future<List<Map<String, dynamic>>> listResourceTemplates(
    String serverName, {
    Duration? timeout,
    bool refresh = false,
  }) => McpService.I.listResourceTemplates(
    serverName,
    timeout: timeout,
    refresh: refresh,
  );

  @override
  Future<Map<String, dynamic>> getPrompt(
    String serverName,
    String name, {
    Map<String, String> arguments = const {},
    Duration? timeout,
  }) => McpService.I.getPrompt(
    serverName,
    name,
    arguments: arguments,
    timeout: timeout,
  );

  @override
  Future<Map<String, dynamic>> readResource(
    String serverName,
    String uri, {
    Duration? timeout,
  }) => McpService.I.readResource(serverName, uri, timeout: timeout);
}

/// Agent-tool exposure of the MCP prompt/resource catalogs.
///
/// Construct with a [McpCatalogBackend] (production uses [McpCatalogTools.I]);
/// a test injects a fake. All methods return typed results whose [render] is
/// a bounded, agent-shaped string.
class McpCatalogTools {
  McpCatalogTools({
    McpCatalogBackend? backend,
    this.maxEntries = 200,
    this.maxChars = defaultMaxChars,
  }) : backend = backend ?? const McpServiceCatalogBackend();

  /// Shared production instance.
  static final McpCatalogTools I = McpCatalogTools();

  final McpCatalogBackend backend;

  /// Entry cap applied per catalog before rendering.
  final int maxEntries;

  /// Character cap applied to every rendered result.
  final int maxChars;

  static const int defaultMaxChars = 6000;

  static const String listPromptsTool = 'catalog_mcp_list_prompts';
  static const String listResourcesTool = 'catalog_mcp_list_resources';
  static const String listResourceTemplatesTool =
      'catalog_mcp_list_resource_templates';
  static const String getPromptTool = 'catalog_mcp_get_prompt';
  static const String readResourceTool = 'catalog_mcp_read_resource';

  static const Set<String> toolNames = {
    listPromptsTool,
    listResourcesTool,
    listResourceTemplatesTool,
    getPromptTool,
    readResourceTool,
  };

  /// Whether [name] is one of this layer's tools.
  bool handles(String name) => toolNames.contains(name);

  /// OpenAI/agent-shaped function specs for every tool this layer exposes.
  List<Map<String, dynamic>> get toolSpecs => _toolSpecs;

  static const List<Map<String, dynamic>> _toolSpecs = [
    {
      'type': 'function',
      'function': {
        'name': listPromptsTool,
        'description':
            'List the prompts a connected MCP server advertises '
            '(prompts/list). Read-only and bounded. Plugin-owned servers are '
            'only callable while their plugin is active in this session.',
        'parameters': {
          'type': 'object',
          'properties': {
            'server': {
              'type': 'string',
              'description': 'MCP server name or canonical id.',
            },
            'refresh': {
              'type': 'boolean',
              'description':
                  'Bypass the cached catalog and re-fetch from the server.',
            },
          },
          'required': ['server'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': listResourcesTool,
        'description':
            'List the concrete resources a connected MCP server advertises '
            '(resources/list). Read-only and bounded.',
        'parameters': {
          'type': 'object',
          'properties': {
            'server': {
              'type': 'string',
              'description': 'MCP server name or canonical id.',
            },
            'refresh': {
              'type': 'boolean',
              'description':
                  'Bypass the cached catalog and re-fetch from the server.',
            },
          },
          'required': ['server'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': listResourceTemplatesTool,
        'description':
            'List the parameterized resource templates a connected MCP '
            'server advertises (resources/templates/list). Read-only and '
            'bounded.',
        'parameters': {
          'type': 'object',
          'properties': {
            'server': {
              'type': 'string',
              'description': 'MCP server name or canonical id.',
            },
            'refresh': {
              'type': 'boolean',
              'description':
                  'Bypass the cached catalog and re-fetch from the server.',
            },
          },
          'required': ['server'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': getPromptTool,
        'description':
            'Fetch a prompt and its rendered messages from a connected MCP '
            'server (prompts/get). Output is bounded.',
        'parameters': {
          'type': 'object',
          'properties': {
            'server': {
              'type': 'string',
              'description': 'MCP server name or canonical id.',
            },
            'name': {
              'type': 'string',
              'description': 'Prompt name from catalog_mcp_list_prompts.',
            },
            'arguments': {
              'type': 'object',
              'description': 'Prompt arguments as string values.',
              'additionalProperties': {'type': 'string'},
            },
          },
          'required': ['server', 'name'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': readResourceTool,
        'description':
            'Read a resource by URI from a connected MCP server '
            '(resources/read). Output is bounded.',
        'parameters': {
          'type': 'object',
          'properties': {
            'server': {
              'type': 'string',
              'description': 'MCP server name or canonical id.',
            },
            'uri': {
              'type': 'string',
              'description': 'Resource URI from catalog_mcp_list_resources.',
            },
          },
          'required': ['server', 'uri'],
        },
      },
    },
  ];

  Future<McpCatalogListResult> listPrompts(
    String serverName, {
    bool refresh = false,
    Duration? timeout,
  }) => _list(
    McpCatalogKind.prompts,
    listPromptsTool,
    serverName,
    refresh: refresh,
    timeout: timeout,
  );

  Future<McpCatalogListResult> listResources(
    String serverName, {
    bool refresh = false,
    Duration? timeout,
  }) => _list(
    McpCatalogKind.resources,
    listResourcesTool,
    serverName,
    refresh: refresh,
    timeout: timeout,
  );

  Future<McpCatalogListResult> listResourceTemplates(
    String serverName, {
    bool refresh = false,
    Duration? timeout,
  }) => _list(
    McpCatalogKind.resourceTemplates,
    listResourceTemplatesTool,
    serverName,
    refresh: refresh,
    timeout: timeout,
  );

  Future<McpCatalogPayloadResult> getPrompt(
    String serverName,
    String name, {
    Map<String, String> arguments = const {},
    Duration? timeout,
  }) async {
    if (name.isEmpty) throw ArgumentError('Prompt name is empty');
    final server = await _requireServer(serverName);
    final payload = await backend.getPrompt(
      server.name,
      name,
      arguments: arguments,
      timeout: timeout,
    );
    return McpCatalogPayloadResult(
      tool: getPromptTool,
      server: server,
      payload: payload,
    );
  }

  Future<McpCatalogPayloadResult> readResource(
    String serverName,
    String uri, {
    Duration? timeout,
  }) async {
    if (uri.isEmpty) throw ArgumentError('Resource URI is empty');
    final server = await _requireServer(serverName);
    final payload = await backend.readResource(
      server.name,
      uri,
      timeout: timeout,
    );
    return McpCatalogPayloadResult(
      tool: readResourceTool,
      server: server,
      payload: payload,
    );
  }

  /// Dispatch one tool call to a bounded, agent-shaped string result.
  ///
  /// Throws [UnsupportedError] when [toolName] is unknown, matching the
  /// fail-closed behavior for unsupported transports.
  Future<String> dispatch(String toolName, Map<String, dynamic> args) async {
    final server = _stringArg(args, 'server');
    switch (toolName) {
      case listPromptsTool:
        final result = await listPrompts(server, refresh: args['refresh'] == true);
        return result.render(maxChars: maxChars);
      case listResourcesTool:
        final result = await listResources(server, refresh: args['refresh'] == true);
        return result.render(maxChars: maxChars);
      case listResourceTemplatesTool:
        final result = await listResourceTemplates(
          server,
          refresh: args['refresh'] == true,
        );
        return result.render(maxChars: maxChars);
      case getPromptTool:
        final name = _stringArg(args, 'name');
        final result = await getPrompt(
          server,
          name,
          arguments: _stringMap(args['arguments']),
        );
        return result.render(maxChars: maxChars);
      case readResourceTool:
        final uri = _stringArg(args, 'uri');
        final result = await readResource(server, uri);
        return result.render(maxChars: maxChars);
      default:
        throw UnsupportedError('Unknown MCP catalog tool "$toolName"');
    }
  }

  Future<McpCatalogListResult> _list(
    McpCatalogKind kind,
    String tool,
    String serverName, {
    required bool refresh,
    Duration? timeout,
  }) async {
    final server = await _requireServer(serverName);
    final raw = switch (kind) {
      McpCatalogKind.prompts => await backend.listPrompts(
        server.name,
        refresh: refresh,
        timeout: timeout,
      ),
      McpCatalogKind.resources => await backend.listResources(
        server.name,
        refresh: refresh,
        timeout: timeout,
      ),
      McpCatalogKind.resourceTemplates => await backend.listResourceTemplates(
        server.name,
        refresh: refresh,
        timeout: timeout,
      ),
    };
    final total = raw.length;
    final truncated = total > maxEntries;
    final kept = truncated ? raw.take(maxEntries) : raw;
    return McpCatalogListResult(
      tool: tool,
      kind: kind,
      server: server,
      entries: [for (final item in kept) _mapEntry(kind, server, item)],
      total: total,
      truncated: truncated,
      notice: truncated
          ? '${total - maxEntries} more ${kind.label} entries omitted '
                '(cap $maxEntries)'
          : null,
    );
  }

  Future<McpCatalogServer> _requireServer(String serverName) async {
    if (serverName.isEmpty) throw ArgumentError('Server name is empty');
    final info = await backend.serverInfo(serverName);
    if (info == null) {
      throw StateError('MCP server "$serverName" is not configured');
    }
    if (info.isNative) {
      throw UnsupportedError(
        'MCP catalog methods are not implemented for native transport '
        '(server "${info.name}")',
      );
    }
    return info;
  }

  static McpCatalogEntry _mapEntry(
    McpCatalogKind kind,
    McpCatalogServer server,
    Map<String, dynamic> raw,
  ) {
    final identity = switch (kind) {
      McpCatalogKind.prompts => _str(raw['name']),
      McpCatalogKind.resources => _str(raw['uri']),
      McpCatalogKind.resourceTemplates => _str(raw['uriTemplate']),
    };
    final arguments = <McpCatalogArgument>[];
    if (kind == McpCatalogKind.prompts && raw['arguments'] is List) {
      for (final arg in raw['arguments'] as List) {
        if (arg is! Map) continue;
        final name = _str(arg['name']);
        if (name.isEmpty) continue;
        arguments.add(
          McpCatalogArgument(
            name: name,
            description: _strOrNull(arg['description']),
            required: arg['required'] == true,
          ),
        );
      }
    }
    return McpCatalogEntry(
      kind: kind,
      server: server,
      identity: identity,
      name: _strOrNull(raw['name']),
      title: _strOrNull(raw['title']),
      description: _strOrNull(raw['description']),
      mimeType: _strOrNull(raw['mimeType']),
      arguments: arguments,
    );
  }

  static String _stringArg(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is! String || value.trim().isEmpty) {
      throw ArgumentError('Missing required "$key" argument');
    }
    return value.trim();
  }

  static Map<String, String> _stringMap(dynamic value) {
    if (value is! Map) return const {};
    final out = <String, String>{};
    for (final entry in value.entries) {
      final v = entry.value;
      if (v != null) out[entry.key.toString()] = v.toString();
    }
    return out;
  }

  static String _str(dynamic value) => value?.toString() ?? '';

  static String? _strOrNull(dynamic value) {
    if (value is! String || value.isEmpty) return null;
    return value;
  }
}
