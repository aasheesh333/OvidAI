import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:ovid_ai/core/native_plugin.dart';

/// Part B (NP2) pure-Dart utility capabilities: File Converter,
/// Markdown Editor, Password Vault, Env Manager, and Log Analyzer.
///
/// Uses existing dependencies only (`package:markdown` for HTML rendering,
/// `flutter_secure_storage` for the vault). Each [callTool] returns either
/// the raw textual result (render_html, generate, get, set, merge,
/// json_to_csv) or a JSON-encoded result object (csv_to_json, extract_toc,
/// stats, list, parse, filter). User-input errors surface as
/// [FormatException]; unknown tools or missing arguments surface as
/// [ArgumentError].
void registerDevUtilities() {
  NativePluginRegistry.I.register(FileConverterCapability());
  NativePluginRegistry.I.register(MarkdownEditorCapability());
  NativePluginRegistry.I.register(PasswordVaultCapability());
  NativePluginRegistry.I.register(EnvManagerCapability());
  NativePluginRegistry.I.register(LogAnalyzerCapability());
}

String _requireString(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) {
    throw ArgumentError('Missing required argument: $key');
  }
  return value.toString();
}

bool _optionalBool(Map<String, dynamic> args, String key, bool fallback) {
  final value = args[key];
  if (value == null) return fallback;
  if (value is bool) return value;
  return value.toString().toLowerCase() == 'true';
}

// ---------------------------------------------------------------------------
// File Converter
// ---------------------------------------------------------------------------

class FileConverterCapability implements NativePluginCapability {
  @override
  String get pluginName => 'File Converter';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'csv_to_json',
          description: 'Convert CSV data with headers to a JSON array.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'csv_text': {'type': 'string'},
            },
            'required': ['csv_text'],
          },
        ),
        NativePluginTool(
          name: 'json_to_csv',
          description: 'Flatten a JSON array of objects into CSV rows.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'json_text': {'type': 'string'},
            },
            'required': ['json_text'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {
    if (values.isNotEmpty) {
      throw ArgumentError(
        'Plugin "$pluginName" has no configurable settings.',
      );
    }
  }

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'csv_to_json':
        return _csvToJson(_requireString(args, 'csv_text'));
      case 'json_to_csv':
        return _jsonToCsv(_requireString(args, 'json_text'));
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  List<String> _parseCsvLine(String line) {
    final fields = <String>[];
    final current = StringBuffer();
    var inQuotes = false;
    var i = 0;
    while (i < line.length) {
      final c = line[i];
      if (inQuotes) {
        if (c == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            current.write('"');
            i += 2;
          } else {
            inQuotes = false;
            i++;
          }
        } else {
          current.write(c);
          i++;
        }
      } else {
        if (c == '"') {
          inQuotes = true;
          i++;
        } else if (c == ',') {
          fields.add(current.toString());
          current.clear();
          i++;
        } else {
          current.write(c);
          i++;
        }
      }
    }
    fields.add(current.toString());
    if (inQuotes) {
      throw FormatException('Unterminated quoted field in CSV: $line');
    }
    return fields;
  }

  String _csvToJson(String csvText) {
    final lines = csvText
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      throw FormatException(
        'Empty CSV input: expected a header row followed by data rows.',
      );
    }
    final headers =
        _parseCsvLine(lines.first).map((h) => h.trim()).toList();
    if (headers.isEmpty || headers.every((h) => h.isEmpty)) {
      throw FormatException('Empty CSV input: header row has no columns.');
    }
    final rows = <Map<String, String>>[];
    for (final line in lines.skip(1)) {
      final fields = _parseCsvLine(line);
      final row = <String, String>{};
      for (var i = 0; i < headers.length; i++) {
        row[headers[i]] = i < fields.length ? fields[i] : '';
      }
      rows.add(row);
    }
    return jsonEncode(rows);
  }

  String _csvCell(String value) {
    if (value.contains(RegExp(r'[",\n\r]'))) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  String _jsonValueToCell(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is num || value is bool) return value.toString();
    return jsonEncode(value);
  }

  String _jsonToCsv(String jsonText) {
    dynamic decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException catch (e) {
      throw FormatException('Invalid JSON: ${e.message}');
    }
    if (decoded is! List) {
      throw FormatException(
        'Expected a JSON array of objects for CSV conversion.',
      );
    }
    if (decoded.isEmpty) return '';
    final keys = <String>[];
    for (final item in decoded) {
      if (item is! Map) {
        throw FormatException(
          'Expected a JSON array of objects for CSV conversion.',
        );
      }
      for (final key in item.keys) {
        final name = key.toString();
        if (!keys.contains(name)) keys.add(name);
      }
    }
    final rows = <String>[_csvRow(keys)];
    for (final item in decoded) {
      final map = item as Map;
      rows.add(_csvRow(
        [for (final key in keys) _jsonValueToCell(map[key])],
      ));
    }
    return rows.join('\n');
  }

  String _csvRow(List<String> cells) =>
      cells.map(_csvCell).join(',');
}

// ---------------------------------------------------------------------------
// Markdown Editor
// ---------------------------------------------------------------------------

class MarkdownEditorCapability implements NativePluginCapability {
  @override
  String get pluginName => 'Markdown Editor';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'render_html',
          description: 'Render markdown to HTML.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'markdown': {'type': 'string'},
            },
            'required': ['markdown'],
          },
        ),
        NativePluginTool(
          name: 'extract_toc',
          description:
              'Extract headers (H1-H6) with levels and slug anchors.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'markdown': {'type': 'string'},
            },
            'required': ['markdown'],
          },
        ),
        NativePluginTool(
          name: 'stats',
          description:
              'Report word count, character count, and reading time.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'markdown': {'type': 'string'},
            },
            'required': ['markdown'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {
    if (values.isNotEmpty) {
      throw ArgumentError(
        'Plugin "$pluginName" has no configurable settings.',
      );
    }
  }

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'render_html':
        return md.markdownToHtml(_requireString(args, 'markdown'));
      case 'extract_toc':
        return _extractToc(_requireString(args, 'markdown'));
      case 'stats':
        return _stats(_requireString(args, 'markdown'));
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  String _slugify(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  String _extractToc(String markdown) {
    final entries = <Map<String, dynamic>>[];
    for (final line in markdown.split('\n')) {
      final match = RegExp(r'^(#{1,6})\s+(.+)$').firstMatch(line.trimRight());
      if (match == null) continue;
      final text = match
          .group(2)!
          .trim()
          .replaceAll(RegExp(r'\s+#+$'), '')
          .trim();
      if (text.isEmpty) continue;
      entries.add({
        'level': match.group(1)!.length,
        'text': text,
        'anchor': _slugify(text),
      });
    }
    return jsonEncode(entries);
  }

  String _stats(String markdown) {
    final trimmed = markdown.trim();
    final words = trimmed.isEmpty ? 0 : trimmed.split(RegExp(r'\s+')).length;
    return jsonEncode({
      'words': words,
      'characters': markdown.length,
      'reading_time_minutes': (words / 200).ceil(),
    });
  }
}

// ---------------------------------------------------------------------------
// Password Vault
// ---------------------------------------------------------------------------

class PasswordVaultCapability implements NativePluginCapability {
  PasswordVaultCapability({FlutterSecureStorage? secureStorage})
      : _secure = secureStorage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _secure;

  static const _prefix = 'password_vault__';

  @override
  String get pluginName => 'Password Vault';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'generate',
          description: 'Generate a cryptographically secure password.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'length': {'type': 'integer'},
              'uppercase': {'type': 'boolean'},
              'lowercase': {'type': 'boolean'},
              'numbers': {'type': 'boolean'},
              'symbols': {'type': 'boolean'},
            },
          },
        ),
        NativePluginTool(
          name: 'store',
          description: 'Securely store a secret under a key.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'key': {'type': 'string'},
              'secret': {'type': 'string'},
            },
            'required': ['key', 'secret'],
          },
        ),
        NativePluginTool(
          name: 'get',
          description: 'Retrieve a stored secret by key.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'key': {'type': 'string'},
            },
            'required': ['key'],
          },
        ),
        NativePluginTool(
          name: 'list',
          description: 'List stored secret keys (without values).',
          inputSchema: {
            'type': 'object',
            'properties': {},
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {
    if (values.isNotEmpty) {
      throw ArgumentError(
        'Plugin "$pluginName" has no configurable settings.',
      );
    }
  }

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'generate':
        return _generate(
          _parseLength(args['length']),
          _optionalBool(args, 'uppercase', true),
          _optionalBool(args, 'lowercase', true),
          _optionalBool(args, 'numbers', true),
          _optionalBool(args, 'symbols', true),
        );
      case 'store':
        return _store(
          _requireString(args, 'key'),
          _requireString(args, 'secret'),
        );
      case 'get':
        return _get(_requireString(args, 'key'));
      case 'list':
        return _list();
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  int _parseLength(dynamic raw) {
    if (raw == null) return 16;
    final parsed =
        raw is num ? raw.toInt() : int.tryParse(raw.toString().trim());
    if (parsed == null) {
      throw FormatException('Invalid length "$raw": expected an integer.');
    }
    return parsed;
  }

  String _generate(
    int length,
    bool uppercase,
    bool lowercase,
    bool numbers,
    bool symbols,
  ) {
    if (length <= 0 || length > 1024) {
      throw ArgumentError(
        'Invalid length $length: expected 1-1024 characters.',
      );
    }
    const upperSet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    const lowerSet = 'abcdefghijklmnopqrstuvwxyz';
    const numberSet = '0123456789';
    const symbolSet = '!@#\$%^&*()-_=+[]{};:,.<>?';
    final sets = <String>[
      if (uppercase) upperSet,
      if (lowercase) lowerSet,
      if (numbers) numberSet,
      if (symbols) symbolSet,
    ];
    if (sets.isEmpty) {
      throw ArgumentError(
        'At least one character set must be enabled.',
      );
    }
    final random = math.Random.secure();
    final alphabet = sets.join();
    final chars = <String>[];
    // Guarantee one character from each selected set when length allows.
    if (length >= sets.length) {
      for (final set in sets) {
        chars.add(set[random.nextInt(set.length)]);
      }
    }
    while (chars.length < length) {
      chars.add(alphabet[random.nextInt(alphabet.length)]);
    }
    chars.shuffle(random);
    return chars.join();
  }

  String _storageKey(String key) {
    if (key.trim().isEmpty) {
      throw ArgumentError('Missing required argument: key');
    }
    return '$_prefix$key';
  }

  Future<String> _store(String key, String secret) async {
    await _secure.write(key: _storageKey(key), value: secret);
    return 'Stored secret for key "$key".';
  }

  Future<String> _get(String key) async {
    final value = await _secure.read(key: _storageKey(key));
    if (value == null) {
      throw ArgumentError('Secret not found for key "$key".');
    }
    return value;
  }

  Future<String> _list() async {
    final all = await _secure.readAll();
    final keys = all.keys
        .where((k) => k.startsWith(_prefix))
        .map((k) => k.substring(_prefix.length))
        .toList()
      ..sort();
    return jsonEncode({'keys': keys});
  }
}

// ---------------------------------------------------------------------------
// Env Manager
// ---------------------------------------------------------------------------

final _envKeyPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

class EnvManagerCapability implements NativePluginCapability {
  @override
  String get pluginName => 'Env Manager';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'parse',
          description: 'Parse .env content into key-value pairs.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'env_content': {'type': 'string'},
            },
            'required': ['env_content'],
          },
        ),
        NativePluginTool(
          name: 'set',
          description:
              'Update or add a variable while preserving other lines.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'env_content': {'type': 'string'},
              'key': {'type': 'string'},
              'value': {'type': 'string'},
            },
            'required': ['env_content', 'key', 'value'],
          },
        ),
        NativePluginTool(
          name: 'merge',
          description:
              'Merge two .env files; override values win on collision.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'base_env': {'type': 'string'},
              'override_env': {'type': 'string'},
            },
            'required': ['base_env', 'override_env'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {
    if (values.isNotEmpty) {
      throw ArgumentError(
        'Plugin "$pluginName" has no configurable settings.',
      );
    }
  }

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'parse':
        return jsonEncode(_parseEnvMap(_requireString(args, 'env_content')));
      case 'set':
        return _setEnv(
          _requireString(args, 'env_content'),
          _requireString(args, 'key'),
          _requireString(args, 'value'),
        );
      case 'merge':
        return _mergeEnv(
          _requireString(args, 'base_env'),
          _requireString(args, 'override_env'),
        );
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  String _unescapeDoubleQuoted(String value) {
    final out = StringBuffer();
    var i = 0;
    while (i < value.length) {
      final c = value[i];
      if (c == r'\' && i + 1 < value.length) {
        final next = value[i + 1];
        switch (next) {
          case 'n':
            out.write('\n');
          case 'r':
            out.write('\r');
          case 't':
            out.write('\t');
          case '"':
            out.write('"');
          case "'":
            out.write("'");
          case r'\':
            out.write(r'\');
          default:
            out.write('\\');
            out.write(next);
        }
        i += 2;
      } else {
        out.write(c);
        i++;
      }
    }
    return out.toString();
  }

  Map<String, String> _parseEnvMap(String content) {
    final entries = <String, String>{};
    for (final rawLine in content.split('\n')) {
      final line = rawLine.endsWith('\r')
          ? rawLine.substring(0, rawLine.length - 1)
          : rawLine;
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      var rest = trimmed;
      final exportMatch =
          RegExp(r'^export\s+').firstMatch(rest);
      if (exportMatch != null) {
        rest = rest.substring(exportMatch.end).trimLeft();
      }
      final separator = rest.indexOf('=');
      if (separator <= 0) continue;
      final key = rest.substring(0, separator).trim();
      if (!_envKeyPattern.hasMatch(key)) continue;
      var value = rest.substring(separator + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        final quote = value[0];
        value = value.substring(1, value.length - 1);
        value = quote == '"'
            ? _unescapeDoubleQuoted(value)
            : value.replaceAll("\\'", "'").replaceAll('\\\\', r'\');
      } else {
        final commentStart = value.indexOf(' #');
        if (commentStart != -1) {
          value = value.substring(0, commentStart).trimRight();
        }
      }
      entries[key] = value;
    }
    return entries;
  }

  String _quoteValueIfNeeded(String value) {
    if (value.isEmpty) return value;
    if (value.trim() != value ||
        RegExp(r'''[\s#"'`$\\]''').hasMatch(value)) {
      final escaped = value
          .replaceAll(r'\', r'\\')
          .replaceAll('"', r'\"')
          .replaceAll('\n', r'\n')
          .replaceAll('\r', r'\r')
          .replaceAll('\t', r'\t');
      return '"$escaped"';
    }
    return value;
  }

  String _setEnv(String content, String key, String value) {
    if (!_envKeyPattern.hasMatch(key.trim())) {
      throw ArgumentError(
        'Invalid env key "$key": expected [A-Za-z_][A-Za-z0-9_]*.',
      );
    }
    final name = key.trim();
    final emitted = _quoteValueIfNeeded(value);
    final pattern = RegExp(
      r'^(\s*(?:export\s+)?)' + RegExp.escape(name) + r'\s*=',
    );
    final lines = content.split('\n');
    var found = false;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final stripped =
          line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
      final suffix = line.endsWith('\r') ? '\r' : '';
      final match = pattern.firstMatch(stripped);
      if (match != null) {
        lines[i] = '${match.group(1)}$name=$emitted$suffix';
        found = true;
      }
    }
    if (!found) {
      final prefix =
          content.isNotEmpty && !content.endsWith('\n') ? '\n' : '';
      return '$content$prefix$name=$emitted\n';
    }
    return lines.join('\n');
  }

  String _mergeEnv(String base, String overrideEnv) {
    final overrides = _parseEnvMap(overrideEnv);
    var result = base;
    for (final entry in overrides.entries) {
      result = _setEnv(result, entry.key, entry.value);
    }
    return result;
  }
}

// ---------------------------------------------------------------------------
// Log Analyzer
// ---------------------------------------------------------------------------

final _logLevelPattern =
    RegExp(r'\b(FATAL|ERROR|WARN(?:ING)?|INFO|DEBUG)\b', caseSensitive: false);

const _logLevels = {'FATAL', 'ERROR', 'WARN', 'INFO', 'DEBUG', 'UNKNOWN'};

class LogAnalyzerCapability implements NativePluginCapability {
  @override
  String get pluginName => 'Log Analyzer';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'parse',
          description:
              'Categorize log entries by severity; find error clusters.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'log_text': {'type': 'string'},
            },
            'required': ['log_text'],
          },
        ),
        NativePluginTool(
          name: 'filter',
          description:
              'Filter log lines by severity level and search text.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'log_text': {'type': 'string'},
              'level': {'type': 'string'},
              'query': {'type': 'string'},
            },
            'required': ['log_text'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {
    if (values.isNotEmpty) {
      throw ArgumentError(
        'Plugin "$pluginName" has no configurable settings.',
      );
    }
  }

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'parse':
        return _parse(_requireString(args, 'log_text'));
      case 'filter':
        return _filter(
          _requireString(args, 'log_text'),
          args['level']?.toString(),
          args['query']?.toString(),
        );
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  String _normalizeLevel(String level) {
    final upper = level.trim().toUpperCase();
    return upper == 'WARNING' ? 'WARN' : upper;
  }

  String _detectLevel(String line) {
    final match = _logLevelPattern.firstMatch(line);
    if (match == null) return 'UNKNOWN';
    return _normalizeLevel(match.group(1)!);
  }

  List<String> _splitLines(String logText) {
    if (logText.trim().isEmpty) return const [];
    return logText.split('\n');
  }

  String _parse(String logText) {
    final lines = _splitLines(logText);
    final counts = {for (final level in _logLevels) level: 0};
    final errorLines = <int>[];
    for (var i = 0; i < lines.length; i++) {
      final level = _detectLevel(lines[i]);
      counts[level] = counts[level]! + 1;
      if (level == 'ERROR' || level == 'FATAL') errorLines.add(i + 1);
    }
    final clusters = <List<int>>[];
    var current = <int>[];
    for (final lineNumber in errorLines) {
      if (current.isNotEmpty && lineNumber != current.last + 1) {
        if (current.length >= 2) clusters.add(List.of(current));
        current = <int>[];
      }
      current.add(lineNumber);
    }
    if (current.length >= 2) clusters.add(List.of(current));
    return jsonEncode({
      'total': lines.length,
      'counts': counts,
      'error_line_numbers': errorLines,
      'error_clusters': clusters,
    });
  }

  String _filter(String logText, String? level, String? query) {
    final rawLevel = (level ?? '').trim();
    final wantLevel = rawLevel.isEmpty || rawLevel.toUpperCase() == 'ALL'
        ? null
        : _normalizeLevel(rawLevel);
    if (wantLevel != null && !_logLevels.contains(wantLevel)) {
      throw ArgumentError(
        'Unknown log level "$level": '
        'expected one of ALL, FATAL, ERROR, WARN, INFO, DEBUG, UNKNOWN.',
      );
    }
    final needle = (query ?? '').toLowerCase();
    final matches = <String>[];
    for (final line in _splitLines(logText)) {
      if (wantLevel != null && _detectLevel(line) != wantLevel) continue;
      if (needle.isNotEmpty && !line.toLowerCase().contains(needle)) continue;
      matches.add(line);
    }
    return jsonEncode({'matches': matches, 'count': matches.length});
  }
}
