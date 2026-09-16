import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ovid_ai/core/native_plugin.dart';

/// Part C (NP2) pure-Dart utility capabilities: API Tester, Web Scraper Pro,
/// Prompt Library, DB Designer, and Web Clipper.
///
/// Uses existing dependencies only (`package:http` for network tools).
/// HTTP-dependent capabilities accept an injectable [http.Client] so tests
/// can supply a mock client and never touch the real network. Each
/// [callTool] returns either the raw textual result (prompt get, DDL,
/// clipped markdown) or a JSON-encoded result object (API responses,
/// scraper matches, prompt lists, schema validation). User-input errors
/// surface as [FormatException]; unknown tools or missing arguments surface
/// as [ArgumentError].
void registerWebAndDbUtilities() {
  NativePluginRegistry.I.register(ApiTesterCapability());
  NativePluginRegistry.I.register(WebScraperProCapability());
  NativePluginRegistry.I.register(PromptLibraryCapability());
  NativePluginRegistry.I.register(DbDesignerCapability());
  NativePluginRegistry.I.register(WebClipperCapability());
}

String _requireString(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) {
    throw ArgumentError('Missing required argument: $key');
  }
  return value.toString();
}

// ---------------------------------------------------------------------------
// API Tester
// ---------------------------------------------------------------------------

const _httpMethods = {
  'GET',
  'POST',
  'PUT',
  'PATCH',
  'DELETE',
  'HEAD',
  'OPTIONS',
};

class ApiTesterCapability implements NativePluginCapability {
  ApiTesterCapability({http.Client? client}) : _clientOverride = client;

  final http.Client? _clientOverride;
  http.Client? _lazyClient;

  /// Lazily created so capability *registration* (which happens at app
  /// boot, and in tests outside a test zone) never touches the HTTP
  /// stack — the client is only built on first actual tool use.
  http.Client get _client => _clientOverride ?? (_lazyClient ??= http.Client());

  @override
  String get pluginName => 'API Tester';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'request',
          description:
              'Dispatch an HTTP request; return status, headers, and body.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'url': {'type': 'string'},
              'method': {'type': 'string'},
              'headers': {'type': 'object'},
              'body': {'type': 'string'},
              'timeout_seconds': {'type': 'number'},
            },
            'required': ['url'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'request':
        return _request(args);
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  Future<String> _request(Map<String, dynamic> args) async {
    final rawUrl = _requireString(args, 'url');
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null ||
        !uri.hasScheme ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      throw FormatException('Invalid URL "$rawUrl": expected absolute http(s) URL.');
    }
    final method = (args['method']?.toString() ?? 'GET').trim().toUpperCase();
    if (!_httpMethods.contains(method)) {
      throw ArgumentError(
        'Unknown HTTP method "$method": expected one of ${_httpMethods.join(', ')}.',
      );
    }
    final headers = <String, String>{};
    final rawHeaders = args['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers[entry.key.toString()] = entry.value.toString();
      }
    } else if (rawHeaders is String && rawHeaders.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawHeaders);
        if (decoded is! Map) {
          throw FormatException(
            'Invalid headers: expected a JSON object of string values.',
          );
        }
        for (final entry in decoded.entries) {
          headers[entry.key.toString()] = entry.value.toString();
        }
      } on FormatException catch (e) {
        throw FormatException('Invalid headers JSON: ${e.message}');
      }
    }
    final body = args['body']?.toString();
    final timeoutSeconds =
        (args['timeout_seconds'] as num?)?.toDouble() ?? 10.0;
    if (timeoutSeconds <= 0) {
      throw ArgumentError(
        'Invalid timeout_seconds $timeoutSeconds: must be positive.',
      );
    }
    final stopwatch = Stopwatch()..start();
    http.Response response;
    try {
      final request = http.Request(method, uri);
      request.headers.addAll(headers);
      if (body != null && body.isNotEmpty) {
        request.body = body;
      }
      final streamed = await _client
          .send(request)
          .timeout(Duration(milliseconds: (timeoutSeconds * 1000).round()));
      response = await http.Response.fromStream(streamed);
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('HTTP request failed: $e');
    } finally {
      stopwatch.stop();
    }
    return jsonEncode({
      'url': uri.toString(),
      'method': method,
      'status': response.statusCode,
      'headers': response.headers,
      'body': response.body,
      'elapsed_ms': stopwatch.elapsedMilliseconds,
    });
  }
}

// ---------------------------------------------------------------------------
// Web Scraper Pro
// ---------------------------------------------------------------------------

final _pairedTagPattern = RegExp(
  r'<([A-Za-z][A-Za-z0-9]*)\b([^<>]*)>([^<>]*?)</\1\s*>',
  caseSensitive: false,
);

final _voidTagPattern = RegExp(
  r'<(area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr)\b([^<>]*?)/?>',
  caseSensitive: false,
);

final _attrPattern = RegExp(
  r'''([\w:-]+)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))''',
);

String _stripTags(String html) {
  var text = html.replaceAll(RegExp(r'<[^>]*>'), '');
  return _decodeEntities(text);
}

String _decodeEntities(String text) {
  return text
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ');
}

Map<String, String> _parseAttributes(String raw) {
  final attrs = <String, String>{};
  for (final match in _attrPattern.allMatches(raw)) {
    final name = match.group(1)!.toLowerCase();
    final value = match.group(3) ?? match.group(4) ?? match.group(5) ?? '';
    attrs[name] = _decodeEntities(value);
  }
  return attrs;
}

class WebScraperProCapability implements NativePluginCapability {
  @override
  String get pluginName => 'Web Scraper Pro';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'extract',
          description:
              'Extract elements, links, images, or text blocks from HTML.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'html': {'type': 'string'},
              'tag': {'type': 'string'},
              'attribute': {'type': 'string'},
              'contains_text': {'type': 'string'},
            },
            'required': ['html'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'extract':
        return _extract(
          _requireString(args, 'html'),
          args['tag']?.toString(),
          args['attribute']?.toString(),
          args['contains_text']?.toString(),
        );
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  String _extract(
    String html,
    String? tag,
    String? attribute,
    String? containsText,
  ) {
    final wantTag = (tag ?? '').trim().toLowerCase();
    final wantAttr = (attribute ?? '').trim().toLowerCase();
    final needle = (containsText ?? '').toLowerCase();
    final results = <Map<String, dynamic>>[];

    void consider(String tagName, String rawAttrs, String innerHtml) {
      tagName = tagName.toLowerCase();
      if (tagName == 'script' || tagName == 'style') return;
      if (wantTag.isNotEmpty && tagName != wantTag) return;
      final attrs = _parseAttributes(rawAttrs);
      final text = _stripTags(innerHtml).trim().replaceAll(
            RegExp(r'\s+'),
            ' ',
          );
      final searchable = text.isNotEmpty
          ? text
          : attrs.values.join(' ');
      if (needle.isNotEmpty &&
          !searchable.toLowerCase().contains(needle) &&
          !innerHtml.toLowerCase().contains(needle)) {
        return;
      }
      if (wantAttr.isNotEmpty) {
        if (!attrs.containsKey(wantAttr)) return;
        results.add({
          'tag': tagName,
          'attribute': wantAttr,
          'value': attrs[wantAttr],
          'text': text,
        });
      } else {
        results.add({
          'tag': tagName,
          'text': text,
          'attributes': attrs,
        });
      }
    }

    // Leaf paired elements (inner content holds no nested tags, so outer
    // wrappers never swallow inner matches).
    for (final match in _pairedTagPattern.allMatches(html)) {
      consider(match.group(1)!, match.group(2)!, match.group(3)!);
    }
    // Void elements such as <img> have no closing tag.
    for (final match in _voidTagPattern.allMatches(html)) {
      consider(match.group(1)!, match.group(2)!, '');
    }
    return jsonEncode({'results': results, 'count': results.length});
  }
}

// ---------------------------------------------------------------------------
// Prompt Library
// ---------------------------------------------------------------------------

class _SavedPrompt {
  _SavedPrompt(this.prompt, this.tags);
  String prompt;
  List<String> tags;
}

List<String> _parseTags(dynamic raw) {
  if (raw == null) return const [];
  if (raw is List) {
    return [
      for (final item in raw)
        item.toString().trim(),
    ].where((t) => t.isNotEmpty).toList();
  }
  return raw
      .toString()
      .split(',')
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();
}

class PromptLibraryCapability implements NativePluginCapability {
  final Map<String, _SavedPrompt> _prompts = {};

  @override
  String get pluginName => 'Prompt Library';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'save',
          description: 'Save a reusable prompt template.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'title': {'type': 'string'},
              'prompt': {'type': 'string'},
              'tags': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
            'required': ['title', 'prompt'],
          },
        ),
        NativePluginTool(
          name: 'get',
          description: 'Retrieve a saved prompt by title.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'title': {'type': 'string'},
            },
            'required': ['title'],
          },
        ),
        NativePluginTool(
          name: 'list',
          description: 'List saved prompts, optionally filtered by tag.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'tag': {'type': 'string'},
            },
          },
        ),
        NativePluginTool(
          name: 'delete',
          description: 'Delete a saved prompt by title.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'title': {'type': 'string'},
            },
            'required': ['title'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'save':
        return _save(
          _requireString(args, 'title'),
          _requireString(args, 'prompt'),
          _parseTags(args['tags']),
        );
      case 'get':
        return _get(_requireString(args, 'title'));
      case 'list':
        return _list(args['tag']?.toString());
      case 'delete':
        return _delete(_requireString(args, 'title'));
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  String _normalizeTitle(String title) {
    final normalized = title.trim();
    if (normalized.isEmpty) {
      throw ArgumentError('Missing required argument: title');
    }
    return normalized;
  }

  String _save(String title, String prompt, List<String> tags) {
    final name = _normalizeTitle(title);
    if (prompt.trim().isEmpty) {
      throw ArgumentError('Missing required argument: prompt');
    }
    _prompts[name] = _SavedPrompt(prompt, tags);
    return 'Saved prompt "$name".';
  }

  String _get(String title) {
    final name = _normalizeTitle(title);
    final saved = _prompts[name];
    if (saved == null) {
      throw ArgumentError('Prompt not found: "$name".');
    }
    return saved.prompt;
  }

  String _list(String? tag) {
    final needle = (tag ?? '').trim().toLowerCase();
    final entries = <Map<String, dynamic>>[];
    final titles = _prompts.keys.toList()..sort();
    for (final title in titles) {
      final saved = _prompts[title]!;
      if (needle.isNotEmpty &&
          !saved.tags.any((t) => t.toLowerCase() == needle)) {
        continue;
      }
      entries.add({
        'title': title,
        'prompt': saved.prompt,
        'tags': saved.tags,
      });
    }
    return jsonEncode(entries);
  }

  String _delete(String title) {
    final name = _normalizeTitle(title);
    if (!_prompts.containsKey(name)) {
      throw ArgumentError('Prompt not found: "$name".');
    }
    _prompts.remove(name);
    return 'Deleted prompt "$name".';
  }
}

// ---------------------------------------------------------------------------
// DB Designer
// ---------------------------------------------------------------------------

final _identifierPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

const _knownColumnTypes = {
  'INTEGER', 'INT', 'BIGINT', 'SMALLINT', 'SERIAL', 'BIGSERIAL',
  'TEXT', 'VARCHAR', 'CHAR', 'CHARACTER', 'CLOB',
  'BOOLEAN', 'BOOL',
  'REAL', 'FLOAT', 'DOUBLE', 'NUMERIC', 'DECIMAL',
  'TIMESTAMP', 'DATETIME', 'DATE', 'TIME',
  'BLOB', 'BYTEA', 'UUID', 'JSON', 'JSONB',
};

String _normalizeColumnType(String raw) {
  var type = raw.trim().toUpperCase();
  final paren = type.indexOf('(');
  final base = (paren == -1 ? type : type.substring(0, paren)).trim();
  final suffix = paren == -1 ? '' : type.substring(paren);
  const aliases = {
    'INT': 'INTEGER',
    'BOOL': 'BOOLEAN',
    'DATETIME': 'TIMESTAMP',
    'CHARACTER': 'VARCHAR',
  };
  return '${aliases[base] ?? base}$suffix';
}

String _baseTypeOf(String normalized) {
  final paren = normalized.indexOf('(');
  return paren == -1 ? normalized : normalized.substring(0, paren);
}

class _DbColumn {
  const _DbColumn({
    required this.name,
    required this.type,
    required this.primaryKey,
    required this.nullable,
    required this.unique,
    required this.defaultValue,
    required this.references,
  });
  final String name;
  final String type;
  final bool primaryKey;
  final bool nullable;
  final bool unique;
  final String? defaultValue;
  final String? references;
}

class _DbTable {
  const _DbTable(this.name, this.columns);
  final String name;
  final List<_DbColumn> columns;
}

class _ParsedSchema {
  const _ParsedSchema(this.tables);
  final List<_DbTable> tables;
}

bool _isTruthy(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  return value.toString().toLowerCase() == 'true';
}

_ParsedSchema _parseSchema(dynamic decoded) {
  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } on FormatException catch (e) {
      throw FormatException('Invalid schema JSON: ${e.message}');
    }
  }
  if (decoded is! Map) {
    throw FormatException(
      'Invalid schema: expected a JSON object with a "tables" array.',
    );
  }
  final tablesRaw = decoded['tables'];
  if (tablesRaw is! List || tablesRaw.isEmpty) {
    throw FormatException(
      'Invalid schema: expected a non-empty "tables" array.',
    );
  }
  final tables = <_DbTable>[];
  for (final tableRaw in tablesRaw) {
    if (tableRaw is! Map) {
      throw FormatException('Invalid schema: each table must be an object.');
    }
    final name = tableRaw['name']?.toString() ?? '';
    if (!_identifierPattern.hasMatch(name)) {
      throw FormatException(
        'Invalid table name "$name": expected [A-Za-z_][A-Za-z0-9_]*.',
      );
    }
    final columnsRaw = tableRaw['columns'];
    if (columnsRaw is! List || columnsRaw.isEmpty) {
      throw FormatException(
        'Invalid table "$name": expected a non-empty "columns" array.',
      );
    }
    final columns = <_DbColumn>[];
    for (final columnRaw in columnsRaw) {
      if (columnRaw is! Map) {
        throw FormatException(
          'Invalid column in table "$name": each column must be an object.',
        );
      }
      final columnName = columnRaw['name']?.toString() ?? '';
      if (!_identifierPattern.hasMatch(columnName)) {
        throw FormatException(
          'Invalid column name "$columnName" in table "$name".',
        );
      }
      final type = _normalizeColumnType(
        columnRaw['type']?.toString() ?? '',
      );
      columns.add(_DbColumn(
        name: columnName,
        type: type,
        primaryKey: _isTruthy(columnRaw['primary_key'] ?? false),
        nullable: columnRaw.containsKey('nullable')
            ? _isTruthy(columnRaw['nullable'])
            : true,
        unique: _isTruthy(columnRaw['unique'] ?? false),
        defaultValue: columnRaw['default']?.toString(),
        references: (columnRaw['references'] as dynamic)?.toString(),
      ));
    }
    tables.add(_DbTable(name, columns));
  }
  return _ParsedSchema(tables);
}

List<String> _validateParsed(_ParsedSchema schema) {
  final errors = <String>[];
  final tableNames = <String>{};
  for (final table in schema.tables) {
    if (!tableNames.add(table.name)) {
      errors.add('Duplicate table name "${table.name}".');
    }
  }
  final byTable = {for (final t in schema.tables) t.name: t};
  for (final table in schema.tables) {
    final columnNames = <String>{};
    for (final column in table.columns) {
      if (!columnNames.add(column.name)) {
        errors.add(
          'Duplicate column "${column.name}" in table "${table.name}".',
        );
      }
      if (!_knownColumnTypes.contains(_baseTypeOf(column.type))) {
        errors.add(
          'Unknown type "${column.type}" for column '
          '"${table.name}.${column.name}".',
        );
      }
    }
    if (!table.columns.any((c) => c.primaryKey)) {
      errors.add(
        'Table "${table.name}" has no primary key: '
        'mark at least one column with primary_key=true.',
      );
    }
    for (final column in table.columns) {
      final ref = column.references;
      if (ref == null || ref.trim().isEmpty) continue;
      final match =
          RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)\(([^)]+)\)$')
              .firstMatch(ref.trim());
      if (match == null) {
        errors.add(
          'Invalid reference "${column.references}" on '
          '"${table.name}.${column.name}": expected table(column).',
        );
        continue;
      }
      final targetTable = match.group(1)!;
      final targetColumn = match.group(2)!.trim();
      final target = byTable[targetTable];
      if (target == null) {
        errors.add(
          'Dangling foreign key on "${table.name}.${column.name}": '
          'table "$targetTable" does not exist.',
        );
      } else if (!target.columns.any((c) => c.name == targetColumn)) {
        errors.add(
          'Dangling foreign key on "${table.name}.${column.name}": '
          'column "$targetColumn" does not exist in table "$targetTable".',
        );
      }
    }
  }
  return errors;
}

String _mapTypeForDialect(String normalized, String dialect) {
  if (dialect == 'sqlite') {
    const mapping = {
      'SERIAL': 'INTEGER',
      'BIGSERIAL': 'INTEGER',
      'UUID': 'TEXT',
      'JSONB': 'TEXT',
      'JSON': 'TEXT',
      'BYTEA': 'BLOB',
      'TIMESTAMP': 'TEXT',
      'DATETIME': 'TEXT',
    };
    final base = _baseTypeOf(normalized);
    final suffix = normalized.substring(base.length);
    return '${mapping[base] ?? base}$suffix';
  }
  return normalized;
}

class DbDesignerCapability implements NativePluginCapability {
  @override
  String get pluginName => 'DB Designer';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'generate_ddl',
          description:
              'Convert a JSON table definition to PostgreSQL/SQLite DDL.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'schema': {'type': 'string'},
              'dialect': {'type': 'string'},
            },
            'required': ['schema'],
          },
        ),
        NativePluginTool(
          name: 'validate_schema',
          description:
              'Validate table dependencies, primary keys, and field types.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'schema': {'type': 'string'},
            },
            'required': ['schema'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'generate_ddl':
        return _generateDdl(
          _requireSchema(args),
          _requireDialect(args['dialect']?.toString() ?? 'postgres'),
        );
      case 'validate_schema':
        return _validateSchema(_requireSchema(args));
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  dynamic _requireSchema(Map<String, dynamic> args) {
    final value = args['schema'];
    if (value == null) {
      throw ArgumentError('Missing required argument: schema');
    }
    return value;
  }

  String _requireDialect(String raw) {
    final dialect = raw.trim().toLowerCase();
    if (dialect == 'postgres' || dialect == 'postgresql') return 'postgres';
    if (dialect == 'sqlite') return 'sqlite';
    throw ArgumentError(
      'Unknown dialect "$raw": expected postgres or sqlite.',
    );
  }

  String _generateDdl(dynamic schemaRaw, String dialect) {
    final schema = _parseSchema(schemaRaw);
    final errors = _validateParsed(schema);
    if (errors.isNotEmpty) {
      throw FormatException(
        'Invalid schema:\n${errors.join('\n')}',
      );
    }
    final statements = <String>[];
    for (final table in schema.tables) {
      final lines = <String>[];
      for (final column in table.columns) {
        final parts = <String>[
          '"${column.name}"',
          _mapTypeForDialect(column.type, dialect),
        ];
        if (column.primaryKey) parts.add('PRIMARY KEY');
        if (!column.nullable && !column.primaryKey) {
          parts.add('NOT NULL');
        }
        if (column.unique && !column.primaryKey) parts.add('UNIQUE');
        if (column.defaultValue != null &&
            column.defaultValue!.trim().isNotEmpty) {
          parts.add('DEFAULT ${column.defaultValue}');
        }
        if (column.references != null &&
            column.references!.trim().isNotEmpty) {
          parts.add('REFERENCES ${column.references!.trim()}');
        }
        lines.add('  ${parts.join(' ')}');
      }
      statements.add(
        'CREATE TABLE "${table.name}" (\n${lines.join(',\n')}\n);',
      );
    }
    return statements.join('\n\n');
  }

  String _validateSchema(dynamic schemaRaw) {
    _ParsedSchema schema;
    try {
      schema = _parseSchema(schemaRaw);
    } on FormatException catch (e) {
      return jsonEncode({
        'valid': false,
        'errors': [e.message],
      });
    }
    final errors = _validateParsed(schema);
    return jsonEncode({'valid': errors.isEmpty, 'errors': errors});
  }
}

// ---------------------------------------------------------------------------
// Web Clipper
// ---------------------------------------------------------------------------

String _clipText(String html) => _decodeEntities(
      html.replaceAll(RegExp(r'\s+'), ' ').trim(),
    );

String _htmlToMarkdown(String html, String url) {
  final titleMatch = RegExp(
    r'<title[^>]*>(.*?)</title\s*>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(html);
  final title = titleMatch == null
      ? url
      : _clipText(_stripTags(titleMatch.group(1)!));
  var body = html;
  final bodyMatch = RegExp(
    r'<body[^>]*>(.*?)</body\s*>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(html);
  if (bodyMatch != null) body = bodyMatch.group(1)!;
  body = body.replaceAll(
    RegExp(r'<(script|style|nav|footer)[^>]*>.*?</\1\s*>',
        caseSensitive: false, dotAll: true),
    ' ',
  );
  body = body.replaceAllMapped(
    RegExp(
      r'''<a\b[^>]*href\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a\s*>''',
      caseSensitive: false,
      dotAll: true,
    ),
    (m) {
      final href = m.group(2) ?? m.group(3) ?? m.group(4) ?? '';
      final text = _clipText(_stripTags(m.group(5)!));
      if (text.isEmpty) return href.isEmpty ? '' : ' $href ';
      if (href.isEmpty) return ' $text ';
      return ' [$text]($href) ';
    },
  );
  for (var level = 6; level >= 1; level--) {
    body = body.replaceAllMapped(
      RegExp('<h$level\\b[^>]*>(.*?)</h$level\\s*>',
          caseSensitive: false, dotAll: true),
      (m) => '\n${'#' * level} ${_clipText(_stripTags(m.group(1)!))}\n',
    );
  }
  body = body.replaceAllMapped(
    RegExp(r'<(p|div|section|article|br|li|tr)\b[^>]*>',
        caseSensitive: false),
    (_) => '\n',
  );
  final text = _clipText(_stripTags(body));
  final lines = <String>[];
  for (final rawLine in text.split('\n')) {
    final line = rawLine.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
    if (line.isEmpty) {
      if (lines.isNotEmpty && lines.last.isNotEmpty) lines.add('');
      continue;
    }
    lines.add(line);
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return '# $title\n\nSource: $url\n\n${lines.join('\n')}';
}

class WebClipperCapability implements NativePluginCapability {
  WebClipperCapability({http.Client? client}) : _clientOverride = client;

  final http.Client? _clientOverride;
  http.Client? _lazyClient;

  /// Lazily created so capability *registration* (which happens at app
  /// boot, and in tests outside a test zone) never touches the HTTP
  /// stack — the client is only built on first actual tool use.
  http.Client get _client => _clientOverride ?? (_lazyClient ??= http.Client());

  @override
  String get pluginName => 'Web Clipper';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'clip',
          description:
              'Fetch a webpage and return its readable content as markdown.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'url': {'type': 'string'},
              'timeout_seconds': {'type': 'number'},
            },
            'required': ['url'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'clip':
        return _clip(
          _requireString(args, 'url'),
          (args['timeout_seconds'] as num?)?.toDouble() ?? 10.0,
        );
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  Future<String> _clip(String rawUrl, double timeoutSeconds) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null ||
        !uri.hasScheme ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      throw FormatException('Invalid URL "$rawUrl": expected absolute http(s) URL.');
    }
    if (timeoutSeconds <= 0) {
      throw ArgumentError(
        'Invalid timeout_seconds $timeoutSeconds: must be positive.',
      );
    }
    http.Response response;
    try {
      response = await _client
          .get(uri)
          .timeout(Duration(milliseconds: (timeoutSeconds * 1000).round()));
    } catch (e) {
      throw FormatException('Failed to fetch "$rawUrl": $e');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(
        'Failed to fetch "$rawUrl": HTTP ${response.statusCode}.',
      );
    }
    if (response.body.trim().isEmpty) {
      throw FormatException('Empty response body for "$rawUrl".');
    }
    return _htmlToMarkdown(response.body, uri.toString());
  }
}
