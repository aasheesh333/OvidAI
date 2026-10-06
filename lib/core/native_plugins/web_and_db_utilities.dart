import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'utility_limits.dart';

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

/// Tolerant double parsing for LLM-supplied numeric args: accepts [num]
/// directly or a numeric [String] (e.g. `"10"`); anything else is a
/// user-input error ([FormatException]).
double _parseDoubleArg(dynamic raw, String key, double fallback) {
  if (raw == null) return fallback;
  if (raw is num) return raw.toDouble();
  final parsed = double.tryParse(raw.toString().trim());
  if (parsed == null) {
    throw FormatException('Invalid $key "$raw": expected a number.');
  }
  return parsed;
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
  Future<void> configure(Map<String, String> values) async {
    if (values.isNotEmpty) {
      throw ArgumentError('Plugin "$pluginName" has no configurable settings.');
    }
  }

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
    checkUtilityInput(args);
    final rawUrl = _requireString(args, 'url');
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null ||
        !uri.hasScheme ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      throw FormatException(
        'Invalid URL "$rawUrl": expected absolute http(s) URL.',
      );
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
    final timeoutSeconds = _parseDoubleArg(
      args['timeout_seconds'],
      'timeout_seconds',
      10.0,
    );
    if (timeoutSeconds <= 0) {
      throw ArgumentError(
        'Invalid timeout_seconds $timeoutSeconds: must be positive.',
      );
    }
    final stopwatch = Stopwatch()..start();
    http.Response response;
    try {
      response = await boundedUtilityRequest(
        _client,
        method,
        uri,
        headers: headers,
        body: body,
        timeoutSeconds: timeoutSeconds,
      );
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('HTTP request failed: $e');
    } finally {
      stopwatch.stop();
    }
    return checkUtilityOutput(
      jsonEncode({
        'url': uri.toString(),
        'method': method,
        'status': response.statusCode,
        'headers': response.headers,
        'body': response.body,
        'elapsed_ms': stopwatch.elapsedMilliseconds,
      }),
    );
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
      description: 'Extract elements, links, images, or text blocks from HTML.',
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
  Future<void> configure(Map<String, String> values) async {
    if (values.isNotEmpty) {
      throw ArgumentError('Plugin "$pluginName" has no configurable settings.');
    }
  }

  @override
  Future<String> callTool(
    String toolName,
    Map<String, dynamic> args, {
    UtilityCancellation? cancellation,
  }) async {
    checkUtilityInput(args);
    return runBoundedUtility(
      () => WebScraperProCapability()._execute(toolName, args),
      cancellation: cancellation,
    );
  }

  String _execute(String toolName, Map<String, dynamic> args) {
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
      if (results.length >= 1000) {
        throw const FormatException('Scraper match limit exceeded: 1000.');
      }
      tagName = tagName.toLowerCase();
      if (tagName == 'script' || tagName == 'style') return;
      if (wantTag.isNotEmpty && tagName != wantTag) return;
      final attrs = _parseAttributes(rawAttrs);
      final text = _stripTags(innerHtml).trim().replaceAll(RegExp(r'\s+'), ' ');
      final searchable = text.isNotEmpty ? text : attrs.values.join(' ');
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
        results.add({'tag': tagName, 'text': text, 'attributes': attrs});
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
      for (final item in raw) item.toString().trim(),
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
  bool _loaded = false;

  /// Non-secret prefs key backing the prompt cache (prompts are reusable
  /// templates, never secrets — secure storage must NOT be used here).
  static const _prefsKey = 'native_plugin_prompt_library__prompts';

  /// Loads persisted prompts once (lazily on first use, since construction
  /// cannot be async); the in-memory map stays as a cache afterwards.
  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final prompt = value['prompt']?.toString() ?? '';
        if (prompt.isEmpty) continue;
        final tags = [
          for (final t in (value['tags'] as List? ?? const [])) t.toString(),
        ].where((t) => t.isNotEmpty).toList();
        _prompts[entry.key.toString()] = _SavedPrompt(prompt, tags);
      }
    } catch (_) {
      // Corrupt or unavailable cache: start empty rather than crash.
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode({
        for (final entry in _prompts.entries)
          entry.key: {'prompt': entry.value.prompt, 'tags': entry.value.tags},
      }),
    );
  }

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
  Future<void> configure(Map<String, String> values) async {
    if (values.isNotEmpty) {
      throw ArgumentError('Plugin "$pluginName" has no configurable settings.');
    }
  }

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'save':
        await _ensureLoaded();
        final saved = _save(
          _requireString(args, 'title'),
          _requireString(args, 'prompt'),
          _parseTags(args['tags']),
        );
        await _persist();
        return saved;
      case 'get':
        await _ensureLoaded();
        return _get(_requireString(args, 'title'));
      case 'list':
        await _ensureLoaded();
        return _list(args['tag']?.toString());
      case 'delete':
        await _ensureLoaded();
        final deleted = _delete(_requireString(args, 'title'));
        await _persist();
        return deleted;
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
      entries.add({'title': title, 'prompt': saved.prompt, 'tags': saved.tags});
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
  'INTEGER',
  'INT',
  'BIGINT',
  'SMALLINT',
  'SERIAL',
  'BIGSERIAL',
  'TEXT',
  'VARCHAR',
  'CHAR',
  'CHARACTER',
  'CLOB',
  'BOOLEAN',
  'BOOL',
  'REAL',
  'FLOAT',
  'DOUBLE',
  'NUMERIC',
  'DECIMAL',
  'TIMESTAMP',
  'DATETIME',
  'DATE',
  'TIME',
  'BLOB',
  'BYTEA',
  'UUID',
  'JSON',
  'JSONB',
};

String _normalizeColumnType(String raw) {
  var type = raw.trim().toUpperCase();
  if (!RegExp(r'^[A-Z]+(?:\(\d+(?:\s*,\s*\d+)?\))?$').hasMatch(type)) {
    throw const FormatException('Unsupported column type grammar.');
  }
  final paren = type.indexOf('(');
  final base = (paren == -1 ? type : type.substring(0, paren)).trim();
  final suffix = paren == -1 ? '' : type.substring(paren);
  const aliases = {
    'INT': 'INTEGER',
    'BOOL': 'BOOLEAN',
    'DATETIME': 'TIMESTAMP',
    'CHARACTER': 'CHAR',
  };
  final normalizedBase = aliases[base] ?? base;
  if (suffix.isNotEmpty) {
    final values = suffix
        .substring(1, suffix.length - 1)
        .split(',')
        .map((v) => int.tryParse(v.trim()))
        .toList();
    final precision = values.first;
    if (precision == null ||
        precision < 1 ||
        precision > 1000 ||
        !const {
          'VARCHAR',
          'CHAR',
          'NUMERIC',
          'DECIMAL',
        }.contains(normalizedBase) ||
        values.length > 1 &&
            (!const {'NUMERIC', 'DECIMAL'}.contains(normalizedBase) ||
                values[1] == null ||
                values[1]! > precision)) {
      throw const FormatException(
        'Unsupported type parameters: length/precision 1..1000; scale 0..precision.',
      );
    }
  }
  return '$normalizedBase$suffix';
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

bool _schemaBool(Map raw, String key, {bool fallback = false}) {
  final value = raw[key];
  if (value == null && !raw.containsKey(key)) return fallback;
  if (value is bool) return value;
  throw FormatException('Invalid $key: expected a boolean.');
}

_ParsedSchema _parseSchema(dynamic decoded) {
  checkUtilityInput(decoded);
  if (decoded is String) {
    checkUtilityJson(decoded);
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
  if (decoded.keys.any((key) => key != 'tables')) {
    throw const FormatException(
      'Unsupported schema property: only tables is supported.',
    );
  }
  final tablesRaw = decoded['tables'];
  if (tablesRaw is! List || tablesRaw.isEmpty) {
    throw FormatException(
      'Invalid schema: expected a non-empty "tables" array.',
    );
  }
  if (tablesRaw.length > 64) {
    throw const FormatException('Schema table limit exceeded: 64.');
  }
  final tables = <_DbTable>[];
  for (final tableRaw in tablesRaw) {
    if (tableRaw is! Map) {
      throw FormatException('Invalid schema: each table must be an object.');
    }
    if (tableRaw.keys.any((key) => !const {'name', 'columns'}.contains(key))) {
      throw const FormatException('Unsupported table property.');
    }
    final name = tableRaw['name']?.toString() ?? '';
    if (name.length > 63 || !_identifierPattern.hasMatch(name)) {
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
    if (columnsRaw.length > 128) {
      throw const FormatException(
        'Schema columns per table limit exceeded: 128.',
      );
    }
    for (final columnRaw in columnsRaw) {
      if (columnRaw is! Map) {
        throw FormatException(
          'Invalid column in table "$name": each column must be an object.',
        );
      }
      if (columnRaw.keys.any(
        (key) => !const {
          'name',
          'type',
          'primary_key',
          'nullable',
          'unique',
          'default',
          'references',
        }.contains(key),
      )) {
        throw const FormatException(
          'Unsupported column property or constraint.',
        );
      }
      final columnName = columnRaw['name']?.toString() ?? '';
      if (columnName.length > 63 || !_identifierPattern.hasMatch(columnName)) {
        throw FormatException(
          'Invalid column name "$columnName" in table "$name".',
        );
      }
      final type = _normalizeColumnType(columnRaw['type']?.toString() ?? '');
      columns.add(
        _DbColumn(
          name: columnName,
          type: type,
          primaryKey: _schemaBool(columnRaw, 'primary_key'),
          nullable: _schemaBool(columnRaw, 'nullable', fallback: true),
          unique: _schemaBool(columnRaw, 'unique'),
          defaultValue: columnRaw['default']?.toString(),
          references: columnRaw['references']?.toString(),
        ),
      );
    }
    tables.add(_DbTable(name, columns));
  }
  return _ParsedSchema(tables);
}

List<String> _validateParsed(_ParsedSchema schema) {
  final errors = <String>[];
  final tableNames = <String>{};
  for (final table in schema.tables) {
    if (!tableNames.add(table.name.toLowerCase())) {
      errors.add('Duplicate table name "${table.name}".');
    }
  }
  final byTable = {for (final t in schema.tables) t.name: t};
  for (final table in schema.tables) {
    final columnNames = <String>{};
    for (final column in table.columns) {
      if (!columnNames.add(column.name.toLowerCase())) {
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
      final value = column.defaultValue;
      if (value != null && !_supportedDefault(value, column)) {
        errors.add(
          'Unsupported or incompatible default on "${table.name}.${column.name}". '
          'Use a typed literal, NULL, or CURRENT_DATE/TIME/TIMESTAMP.',
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
      final match = RegExp(
        r'^([A-Za-z_][A-Za-z0-9_]*)\(([^)]+)\)$',
      ).firstMatch(ref.trim());
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
      } else {
        final referenced = target.columns.firstWhere(
          (c) => c.name == targetColumn,
          // Unreachable: the any() guard above proves the column exists.
          orElse: () => throw FormatException(
            'Foreign key target column "$targetColumn" missing from '
            'table "$targetTable".',
          ),
        );
        if (!referenced.unique &&
            !(referenced.primaryKey &&
                target.columns.where((c) => c.primaryKey).length == 1)) {
          errors.add(
            'Foreign key target must be a single-column primary key or UNIQUE column.',
          );
        }
        if (referenced.type != column.type) {
          errors.add('Foreign key types must match exactly.');
        }
      }
    }
  }
  return errors;
}

bool _supportedDefault(String value, _DbColumn column) {
  if (value.length > 4096) return false;
  final raw = value.trim();
  final upper = raw.toUpperCase();
  final base = _baseTypeOf(column.type);
  if (upper == 'NULL') return column.nullable && !column.primaryKey;
  if (upper == 'CURRENT_DATE') return base == 'DATE';
  if (upper == 'CURRENT_TIME') return base == 'TIME';
  if (upper == 'CURRENT_TIMESTAMP') return base == 'TIMESTAMP';
  if (base == 'BOOLEAN') return upper == 'TRUE' || upper == 'FALSE';
  if (const {
    'INTEGER',
    'BIGINT',
    'SMALLINT',
    'SERIAL',
    'BIGSERIAL',
  }.contains(base)) {
    final integer = int.tryParse(raw);
    if (integer == null || !RegExp(r'^[+-]?\d{1,18}$').hasMatch(raw)) {
      return false;
    }
    if (base == 'SMALLINT') return integer >= -32768 && integer <= 32767;
    if (base == 'INTEGER' || base == 'SERIAL') {
      return integer >= -2147483648 && integer <= 2147483647;
    }
    return true;
  }
  if (const {'REAL', 'FLOAT', 'DOUBLE', 'NUMERIC', 'DECIMAL'}.contains(base)) {
    return RegExp(r'^[+-]?\d{1,18}(?:\.\d{1,18})?$').hasMatch(raw);
  }
  if (!const {
        'TEXT',
        'VARCHAR',
        'CHAR',
        'CLOB',
        'DATE',
        'TIME',
        'TIMESTAMP',
      }.contains(base) ||
      !RegExp(r"^'(?:[^'\\]|'')*'$").hasMatch(raw)) {
    return false;
  }
  final literal = raw.substring(1, raw.length - 1).replaceAll("''", "'");
  if (base == 'VARCHAR' || base == 'CHAR') {
    final opening = column.type.indexOf('(');
    if (opening != -1 &&
        literal.runes.length >
            int.parse(
              column.type.substring(opening + 1, column.type.length - 1),
            )) {
      return false;
    }
  }
  if (base == 'DATE') {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(literal);
    if (match == null) return false;
    final parsed = DateTime.tryParse(literal);
    return parsed != null &&
        parsed.year == int.parse(match[1]!) &&
        parsed.month == int.parse(match[2]!) &&
        parsed.day == int.parse(match[3]!);
  }
  if (base == 'TIME') {
    return RegExp(
      r'^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$',
    ).hasMatch(literal);
  }
  if (base == 'TIMESTAMP') {
    if (!RegExp(
      r'^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\dZ$',
    ).hasMatch(literal)) {
      return false;
    }
    try {
      parseUtilityInstant(literal);
      return true;
    } on FormatException {
      return false;
    }
  }
  return true;
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
  const mapping = {
    'BLOB': 'BYTEA',
    'CLOB': 'TEXT',
    'DOUBLE': 'DOUBLE PRECISION',
  };
  return mapping[normalized] ?? normalized;
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
          'Generate SQLite/PostgreSQL CREATE TABLE subset. ASCII names '
          '1..63 chars, <=64 tables, <=128 columns/table. Quoted names; '
          'composite PK, nullable, unique, single-column references. '
          'Types: integer/serial, text/varchar/char, bool, real/float/double, '
          'numeric/decimal, date/time/timestamp, blob/bytea, uuid/json/jsonb. '
          'Length/precision 1..1000, scale 0..precision. Defaults: typed '
          'literals, NULL, CURRENT_DATE/TIME/TIMESTAMP only; no expressions. '
          'Postgres dependency cycles unsupported. Validation is schema '
          'subset checking, not live database validation.',
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
  Future<void> configure(Map<String, String> values) async {
    if (values.isNotEmpty) {
      throw ArgumentError('Plugin "$pluginName" has no configurable settings.');
    }
  }

  @override
  Future<String> callTool(
    String toolName,
    Map<String, dynamic> args, {
    UtilityCancellation? cancellation,
  }) async {
    checkUtilityInput(args);
    return runBoundedUtility(
      () => DbDesignerCapability()._execute(toolName, args),
      cancellation: cancellation,
    );
  }

  String _execute(String toolName, Map<String, dynamic> args) {
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
    throw ArgumentError('Unknown dialect "$raw": expected postgres or sqlite.');
  }

  String _generateDdl(dynamic schemaRaw, String dialect) {
    final schema = _parseSchema(schemaRaw);
    final errors = _validateParsed(schema);
    if (errors.isNotEmpty) {
      throw FormatException('Invalid schema:\n${errors.join('\n')}');
    }
    final statements = <String>[];
    final ordered = <_DbTable>[];
    final visiting = <String>{};
    final visited = <String>{};
    void visit(_DbTable table) {
      if (visited.contains(table.name)) return;
      if (!visiting.add(table.name)) {
        throw const FormatException(
          'Unsupported PostgreSQL cyclic foreign keys.',
        );
      }
      if (dialect == 'postgres') {
        for (final column in table.columns) {
          final ref = column.references;
          if (ref == null || ref.trim().isEmpty) continue;
          final name = ref.trim().split('(').first;
          if (name != table.name) {
            visit(
              schema.tables.firstWhere(
                (t) => t.name == name,
                // Unreachable: _validateParsed rejected dangling foreign
                // keys before generation began.
                orElse: () => throw FormatException(
                  'Foreign key references unknown table "$name".',
                ),
              ),
            );
          }
        }
      }
      visiting.remove(table.name);
      visited.add(table.name);
      ordered.add(table);
    }

    for (final table in schema.tables) {
      visit(table);
    }
    for (final table in ordered) {
      final lines = <String>[];
      final keys = table.columns.where((c) => c.primaryKey).toList();
      for (final column in table.columns) {
        final parts = <String>[
          '"${column.name}"',
          _mapTypeForDialect(column.type, dialect),
        ];
        if (column.primaryKey && keys.length == 1) parts.add('PRIMARY KEY');
        if (!column.nullable || column.primaryKey) {
          parts.add('NOT NULL');
        }
        if (column.unique && (!column.primaryKey || keys.length > 1)) {
          parts.add('UNIQUE');
        }
        if (column.defaultValue != null &&
            column.defaultValue!.trim().isNotEmpty) {
          parts.add('DEFAULT ${column.defaultValue}');
        }
        if (column.references != null && column.references!.trim().isNotEmpty) {
          final ref = column.references!.trim();
          final opening = ref.indexOf('(');
          parts.add(
            'REFERENCES "${ref.substring(0, opening)}"'
            '("${ref.substring(opening + 1, ref.length - 1).trim()}")',
          );
        }
        lines.add('  ${parts.join(' ')}');
      }
      if (keys.length > 1) {
        lines.add(
          '  PRIMARY KEY (${keys.map((c) => '"${c.name}"').join(', ')})',
        );
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

String _clipText(String html) =>
    _decodeEntities(html.replaceAll(RegExp(r'\s+'), ' ').trim());

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
    RegExp(
      r'<(script|style|nav|footer)[^>]*>.*?</\1\s*>',
      caseSensitive: false,
      dotAll: true,
    ),
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
      RegExp(
        '<h$level\\b[^>]*>(.*?)</h$level\\s*>',
        caseSensitive: false,
        dotAll: true,
      ),
      (m) => '\n${'#' * level} ${_clipText(_stripTags(m.group(1)!))}\n',
    );
  }
  body = body.replaceAllMapped(
    RegExp(r'<(p|div|section|article|br|li|tr)\b[^>]*>', caseSensitive: false),
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
  Future<void> configure(Map<String, String> values) async {
    if (values.isNotEmpty) {
      throw ArgumentError('Plugin "$pluginName" has no configurable settings.');
    }
  }

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'clip':
        return _clip(
          _requireString(args, 'url'),
          _parseDoubleArg(args['timeout_seconds'], 'timeout_seconds', 10.0),
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
      throw FormatException(
        'Invalid URL "$rawUrl": expected absolute http(s) URL.',
      );
    }
    if (timeoutSeconds <= 0) {
      throw ArgumentError(
        'Invalid timeout_seconds $timeoutSeconds: must be positive.',
      );
    }
    http.Response response;
    try {
      response = await boundedUtilityRequest(
        _client,
        'GET',
        uri,
        timeoutSeconds: timeoutSeconds,
        maxBytes: 262144,
      );
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
    final html = response.body;
    final url = uri.toString();
    return runBoundedUtility(() => _htmlToMarkdown(html, url));
  }
}
