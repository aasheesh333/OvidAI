import 'dart:convert';
import 'dart:math' as math;

import 'package:ovid_ai/core/native_plugin.dart';

/// Part A (NP2) pure-Dart utility capabilities: JSON Visualizer,
/// Regex Builder, SQL Formatter, Cron Designer, and Color Palette Gen.
///
/// Zero-dependency implementations. Each [callTool] returns either the
/// raw textual result (format/minify/replace/explain/build) or a
/// JSON-encoded result object (query/stats/test/validate/next_runs/
/// from_hex/contrast). User-input errors surface as [FormatException];
/// unknown tools or missing arguments surface as [ArgumentError].
void registerDataUtilities() {
  NativePluginRegistry.I.register(JsonVisualizerCapability());
  NativePluginRegistry.I.register(RegexBuilderCapability());
  NativePluginRegistry.I.register(SqlFormatterCapability());
  NativePluginRegistry.I.register(CronDesignerCapability());
  NativePluginRegistry.I.register(ColorPaletteGenCapability());
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
// JSON Visualizer
// ---------------------------------------------------------------------------

class JsonVisualizerCapability implements NativePluginCapability {
  @override
  String get pluginName => 'JSON Visualizer';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'format',
          description: 'Validate and pretty-print a JSON string.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'json_string': {'type': 'string'},
              'indent': {'type': 'integer'},
            },
            'required': ['json_string'],
          },
        ),
        NativePluginTool(
          name: 'minify',
          description: 'Strip whitespace from a JSON string.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'json_string': {'type': 'string'},
            },
            'required': ['json_string'],
          },
        ),
        NativePluginTool(
          name: 'query',
          description:
              'Navigate JSON with a dot-notated path (e.g. a.b.0.c).',
          inputSchema: {
            'type': 'object',
            'properties': {
              'json_string': {'type': 'string'},
              'path': {'type': 'string'},
            },
            'required': ['json_string', 'path'],
          },
        ),
        NativePluginTool(
          name: 'stats',
          description:
              'Report key count, max depth, data types, and size of JSON.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'json_string': {'type': 'string'},
            },
            'required': ['json_string'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'format':
        return _format(
          _requireString(args, 'json_string'),
          (args['indent'] as num?)?.toInt() ?? 2,
        );
      case 'minify':
        return _minify(_requireString(args, 'json_string'));
      case 'query':
        return _query(
          _requireString(args, 'json_string'),
          _requireString(args, 'path'),
        );
      case 'stats':
        return _stats(_requireString(args, 'json_string'));
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  dynamic _decode(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException catch (e) {
      throw FormatException('Invalid JSON: ${e.message}');
    }
  }

  String _format(String raw, int indent) {
    final value = _decode(raw);
    return JsonEncoder.withIndent(' ' * indent).convert(value);
  }

  String _minify(String raw) => jsonEncode(_decode(raw));

  String _query(String raw, String path) {
    dynamic current = _decode(raw);
    final segments =
        path.split('.').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) throw ArgumentError('Missing required argument: path');
    for (final segment in segments) {
      if (current is Map) {
        if (!current.containsKey(segment)) {
          throw ArgumentError('Path not found: $path');
        }
        current = current[segment];
      } else if (current is List) {
        final index = int.tryParse(segment);
        if (index == null || index < 0 || index >= current.length) {
          throw ArgumentError('Path not found: $path');
        }
        current = current[index];
      } else {
        throw ArgumentError('Path not found: $path');
      }
    }
    return jsonEncode(current);
  }

  String _stats(String raw) {
    final value = _decode(raw);
    var keys = 0;
    final types = <String, int>{};
    int walk(dynamic node) {
      if (node is Map) {
        keys += node.length;
        types['object'] = (types['object'] ?? 0) + 1;
        var childDepth = 0;
        for (final v in node.values) {
          final d = walk(v);
          if (d > childDepth) childDepth = d;
        }
        return 1 + childDepth;
      }
      if (node is List) {
        types['array'] = (types['array'] ?? 0) + 1;
        var childDepth = 0;
        for (final v in node) {
          final d = walk(v);
          if (d > childDepth) childDepth = d;
        }
        return 1 + childDepth;
      }
      final type = node == null
          ? 'null'
          : node is String
              ? 'string'
              : node is bool
                  ? 'boolean'
                  : node is num
                      ? 'number'
                      : 'unknown';
      types[type] = (types[type] ?? 0) + 1;
      return 0;
    }

    final maxDepth = walk(value);
    return jsonEncode({
      'keys': keys,
      'max_depth': maxDepth,
      'types': types,
      'size': utf8.encode(raw).length,
    });
  }
}

// ---------------------------------------------------------------------------
// Regex Builder
// ---------------------------------------------------------------------------

class RegexBuilderCapability implements NativePluginCapability {
  @override
  String get pluginName => 'Regex Builder';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'test',
          description: 'Test a regex against text; return matches + indices.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'pattern': {'type': 'string'},
              'text': {'type': 'string'},
              'multiline': {'type': 'boolean'},
              'case_sensitive': {'type': 'boolean'},
            },
            'required': ['pattern', 'text'],
          },
        ),
        NativePluginTool(
          name: 'replace',
          description: 'Regex search and replace over text.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'pattern': {'type': 'string'},
              'replacement': {'type': 'string'},
              'text': {'type': 'string'},
              'multiline': {'type': 'boolean'},
              'case_sensitive': {'type': 'boolean'},
            },
            'required': ['pattern', 'replacement', 'text'],
          },
        ),
        NativePluginTool(
          name: 'explain',
          description: 'Explain regex tokens in plain English.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'pattern': {'type': 'string'},
            },
            'required': ['pattern'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'test':
        return _test(
          _requireString(args, 'pattern'),
          _requireString(args, 'text'),
          _optionalBool(args, 'multiline', false),
          _optionalBool(args, 'case_sensitive', true),
        );
      case 'replace':
        return _replace(
          _requireString(args, 'pattern'),
          _requireString(args, 'replacement'),
          _requireString(args, 'text'),
          _optionalBool(args, 'multiline', false),
          _optionalBool(args, 'case_sensitive', true),
        );
      case 'explain':
        return _explain(_requireString(args, 'pattern'));
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  RegExp _compile(String pattern, bool multiLine, bool caseSensitive) {
    try {
      return RegExp(
        pattern,
        multiLine: multiLine,
        caseSensitive: caseSensitive,
      );
    } on FormatException catch (e) {
      throw FormatException('Invalid regex pattern: ${e.message}');
    }
  }

  String _test(
    String pattern,
    String text,
    bool multiLine,
    bool caseSensitive,
  ) {
    final regExp = _compile(pattern, multiLine, caseSensitive);
    final matches = <Map<String, dynamic>>[];
    for (final m in regExp.allMatches(text)) {
      matches.add({
        'match': m.group(0),
        'start': m.start,
        'end': m.end,
        'groups': [
          for (var i = 1; i <= m.groupCount; i++) m.group(i),
        ],
      });
    }
    return jsonEncode({'matches': matches, 'count': matches.length});
  }

  String _replace(
    String pattern,
    String replacement,
    String text,
    bool multiLine,
    bool caseSensitive,
  ) {
    final regExp = _compile(pattern, multiLine, caseSensitive);
    return text.replaceAll(regExp, replacement);
  }

  String _explain(String pattern) {
    // Validate first so invalid patterns surface as FormatException.
    _compile(pattern, false, true);
    final lines = <String>['Pattern: $pattern'];
    var i = 0;
    while (i < pattern.length) {
      final c = pattern[i];
      if (c == r'\') {
        final next = i + 1 < pattern.length ? pattern[i + 1] : '';
        const escapes = {
          'd': 'any digit (0-9)',
          'D': 'any non-digit',
          'w': 'any word character (letters, digits, _)',
          'W': 'any non-word character',
          's': 'any whitespace',
          'S': 'any non-whitespace',
          'b': 'a word boundary',
          'n': 'a newline',
          't': 'a tab',
        };
        lines.add(
          "'\\$next': escape matching ${escapes[next] ?? 'a literal "$next"'}",
        );
        i += 2;
        continue;
      }
      if (c == '[') {
        final close = pattern.indexOf(']', i + 1);
        final cls = close == -1 ? pattern.substring(i) : pattern.substring(i, close + 1);
        lines.add("'$cls': character class matching one of the enclosed characters");
        i = close == -1 ? pattern.length : close + 1;
        continue;
      }
      if (c == '(') {
        if (pattern.startsWith('(?<', i)) {
          final end = pattern.indexOf('>', i + 3);
          final name = end == -1 ? '' : pattern.substring(i + 3, end);
          lines.add(
            "'(?<$name>...)': named capturing group called \"$name\"",
          );
        } else if (pattern.startsWith('(?:', i)) {
          lines.add("'(?:...)': non-capturing group (groups without capturing)");
        } else if (pattern.startsWith('(?=', i) || pattern.startsWith('(?!', i)) {
          lines.add("'$c?...': lookahead group (zero-width assertion)");
        } else {
          lines.add("'(...)': capturing group (captures its match as group N)");
        }
        i++;
        continue;
      }
      if (c == ')' || c == ']') {
        i++;
        continue;
      }
      if (c == '^' || c == r'$') {
        lines.add(
          "'$c': anchor matching the ${c == '^' ? 'start' : 'end'} of the input",
        );
        i++;
        continue;
      }
      if (c == '*' || c == '+' || c == '?') {
        const meaning = {
          '*': 'zero or more times',
          '+': 'one or more times',
          '?': 'zero or one time (optional)',
        };
        if (c == '?' && i > 0 && '{}*+?'.contains(pattern[i - 1])) {
          lines.add("'$c' (after a quantifier): lazy quantifier modifier (match as few as possible)");
        } else {
          lines.add("'$c': quantifier repeating the previous token ${meaning[c]}");
        }
        i++;
        continue;
      }
      if (c == '{') {
        final close = pattern.indexOf('}', i + 1);
        if (close != -1) {
          lines.add(
            "'${pattern.substring(i, close + 1)}': quantifier repeating the previous token ${pattern.substring(i + 1, close)} times",
          );
          i = close + 1;
          continue;
        }
        i++;
        continue;
      }
      if (c == '|') {
        lines.add("'$c': alternation (match the left side or the right side)");
        i++;
        continue;
      }
      if (c == '.') {
        lines.add("'$c': wildcard matching any character except a newline");
        i++;
        continue;
      }
      i++;
    }
    lines.add(
      'Summary: the pattern is applied left to right; '
      'quantifiers repeat the token before them and anchors restrict position.',
    );
    return lines.join('\n');
  }
}

// ---------------------------------------------------------------------------
// SQL Formatter
// ---------------------------------------------------------------------------

class SqlFormatterCapability implements NativePluginCapability {
  static const _keywords = {
    'SELECT', 'FROM', 'WHERE', 'HAVING', 'LIMIT', 'OFFSET', 'UNION',
    'VALUES', 'SET', 'INSERT', 'INTO', 'UPDATE', 'DELETE', 'CREATE',
    'TABLE', 'ALTER', 'DROP', 'ON', 'AND', 'OR', 'AS', 'ASC', 'DESC',
    'DISTINCT', 'NOT', 'NULL', 'IN', 'IS', 'LIKE', 'BETWEEN', 'EXISTS',
    'CASE', 'WHEN', 'THEN', 'ELSE', 'END', 'WITH', 'BY', 'GROUP',
    'ORDER', 'JOIN', 'LEFT', 'RIGHT', 'INNER', 'OUTER', 'FULL', 'CROSS',
  };

  @override
  String get pluginName => 'SQL Formatter';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'format',
          description: 'Pretty-print SQL with indented clauses.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'sql': {'type': 'string'},
            },
            'required': ['sql'],
          },
        ),
        NativePluginTool(
          name: 'validate',
          description: 'Check SQL for balanced quotes/parens and structure.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'sql': {'type': 'string'},
            },
            'required': ['sql'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'format':
        return _format(_requireString(args, 'sql'));
      case 'validate':
        return _validate(_requireString(args, 'sql'));
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  String _display(String token) {
    final upper = token.toUpperCase();
    if (upper == 'GROUP BY' || upper == 'ORDER BY') return upper;
    if (upper.endsWith(' JOIN')) return upper;
    if (_keywords.contains(upper)) return upper;
    return token;
  }

  bool _isJoinToken(String token) {
    const parts = {
      'JOIN', 'LEFT', 'RIGHT', 'INNER', 'OUTER', 'FULL', 'CROSS',
    };
    if (!token.contains(' ')) return parts.contains(token.toUpperCase());
    return token.toUpperCase().split(' ').every(parts.contains);
  }

  bool _isLineStarter(String token) {
    final upper = token.toUpperCase();
    if (_isJoinToken(token)) return true;
    return {
      'SELECT', 'FROM', 'WHERE', 'GROUP BY', 'ORDER BY', 'HAVING',
      'LIMIT', 'OFFSET', 'UNION', 'VALUES', 'SET', 'INSERT', 'UPDATE',
      'DELETE', 'CREATE',
    }.contains(upper);
  }

  String _format(String sql) {
    final raw = sql
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (raw.isEmpty) throw ArgumentError('Missing required argument: sql');
    // Combine multi-word keywords: ORDER/GROUP BY and JOIN phrases.
    final tokens = <String>[];
    var i = 0;
    while (i < raw.length) {
      final upper = raw[i].toUpperCase();
      if ((upper == 'ORDER' || upper == 'GROUP') &&
          i + 1 < raw.length &&
          raw[i + 1].toUpperCase() == 'BY') {
        tokens.add('$upper BY');
        i += 2;
        continue;
      }
      if ({
        'JOIN', 'LEFT', 'RIGHT', 'INNER', 'FULL', 'CROSS', 'OUTER',
      }.contains(upper)) {
        final parts = <String>[];
        while (i < raw.length &&
            {
              'JOIN', 'LEFT', 'RIGHT', 'INNER', 'FULL', 'CROSS', 'OUTER',
            }.contains(raw[i].toUpperCase())) {
          parts.add(raw[i].toUpperCase());
          i++;
        }
        tokens.add(parts.join(' '));
        continue;
      }
      tokens.add(raw[i]);
      i++;
    }

    final lines = <String>[];
    final current = StringBuffer();
    void flush() {
      if (current.isNotEmpty) {
        lines.add(current.toString());
        current.clear();
      }
    }

    for (final token in tokens) {
      final upper = token.toUpperCase();
      final display = _display(token);
      if (_isLineStarter(token)) {
        flush();
        current.write(display);
      } else if (upper == 'ON' || upper == 'AND' || upper == 'OR') {
        flush();
        current.write('  $display');
      } else {
        if (current.isEmpty) {
          current.write(display);
        } else {
          current.write(' $display');
        }
      }
    }
    flush();
    return lines.join('\n');
  }

  String _validate(String sql) {
    final errors = <String>[];
    final trimmed = sql.trim();
    if (trimmed.isEmpty) {
      return jsonEncode({
        'valid': false,
        'errors': ['Empty SQL statement.'],
      });
    }
    var parenDepth = 0;
    String? quote;
    var quoteStart = -1;
    var idx = 0;
    while (idx < trimmed.length) {
      final c = trimmed[idx];
      if (quote != null) {
        if (c == quote) {
          // SQL escapes a quote by doubling it ('').
          if (idx + 1 < trimmed.length && trimmed[idx + 1] == quote) {
            idx += 2;
            continue;
          }
          quote = null;
        }
        idx++;
        continue;
      }
      if (c == "'" || c == '"') {
        quote = c;
        quoteStart = idx;
      } else if (c == '(') {
        parenDepth++;
      } else if (c == ')') {
        parenDepth--;
        if (parenDepth < 0) {
          errors.add('Unbalanced parentheses: closing ")" without an opener.');
          parenDepth = 0;
        }
      }
      idx++;
    }
    if (quote != null) {
      errors.add(
        'Unbalanced quote: ${quote == "'" ? 'single' : 'double'} quote '
        'opened at position $quoteStart is never closed.',
      );
    }
    if (parenDepth > 0) {
      errors.add('Unbalanced parentheses: $parenDepth unclosed "(".');
    }
    final firstWord = RegExp(r'[A-Za-z]+').firstMatch(trimmed)?.group(0)?.toUpperCase();
    const statementKeywords = {
      'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'WITH', 'CREATE',
      'DROP', 'ALTER', 'TRUNCATE', 'EXPLAIN',
    };
    if (firstWord == null || !statementKeywords.contains(firstWord)) {
      errors.add(
        'Unrecognized SQL statement: expected a leading keyword such as '
        'SELECT, INSERT, UPDATE, or DELETE.',
      );
    }
    return jsonEncode({'valid': errors.isEmpty, 'errors': errors});
  }
}

// ---------------------------------------------------------------------------
// Cron Designer
// ---------------------------------------------------------------------------

const _dowNames = [
  'Sunday', 'Monday', 'Tuesday', 'Wednesday',
  'Thursday', 'Friday', 'Saturday',
];

const _monthNames = [
  '', 'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

class _CronFields {
  const _CronFields(this.minute, this.hour, this.dom, this.month, this.dow);
  final String minute;
  final String hour;
  final String dom;
  final String month;
  final String dow;
}

class CronDesignerCapability implements NativePluginCapability {
  @override
  String get pluginName => 'Cron Designer';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'explain',
          description: 'Explain a 5-part cron expression in plain English.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'expression': {'type': 'string'},
            },
            'required': ['expression'],
          },
        ),
        NativePluginTool(
          name: 'build',
          description: 'Generate a cron expression from structured parameters.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'frequency': {'type': 'string'},
              'time': {'type': 'string'},
              'days': {
                'type': 'array',
                'items': {'type': 'integer'},
              },
            },
            'required': ['frequency'],
          },
        ),
        NativePluginTool(
          name: 'next_runs',
          description: 'Calculate upcoming run timestamps for an expression.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'expression': {'type': 'string'},
              'count': {'type': 'integer'},
            },
            'required': ['expression'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'explain':
        return _explain(_requireString(args, 'expression'));
      case 'build':
        return _build(
          _requireString(args, 'frequency'),
          args['time']?.toString(),
          (args['days'] as List?)?.toList() ?? const [],
        );
      case 'next_runs':
        return _nextRuns(
          _requireString(args, 'expression'),
          (args['count'] as num?)?.toInt() ?? 5,
        );
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  _CronFields _parse(String expression) {
    final parts = expression
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.length != 5) {
      throw FormatException(
        'Invalid cron expression "$expression": expected 5 fields '
        '(minute hour day-of-month month day-of-week).',
      );
    }
    const bounds = [
      (0, 59), // minute
      (0, 23), // hour
      (1, 31), // day of month
      (1, 12), // month
      (0, 7), // day of week (0 and 7 are Sunday)
    ];
    for (var f = 0; f < 5; f++) {
      _validateField(parts[f], bounds[f].$1, bounds[f].$2);
    }
    return _CronFields(parts[0], parts[1], parts[2], parts[3], parts[4]);
  }

  void _validateField(String field, int min, int max) {
    if (field.isEmpty) {
      throw FormatException('Invalid cron field "": empty value.');
    }
    for (final item in field.split(',')) {
      final stepSplit = item.split('/');
      if (stepSplit.length > 2) {
        throw FormatException('Invalid cron field "$field".');
      }
      if (stepSplit.length == 2) {
        final step = int.tryParse(stepSplit[1]);
        if (step == null || step <= 0) {
          throw FormatException(
            'Invalid cron step in "$field": must be a positive integer.',
          );
        }
      }
      final range = stepSplit[0];
      if (range == '*') continue;
      if (range.contains('-')) {
        final ends = range.split('-');
        if (ends.length != 2) {
          throw FormatException('Invalid cron range in "$field".');
        }
        final lo = int.tryParse(ends[0]);
        final hi = int.tryParse(ends[1]);
        if (lo == null ||
            hi == null ||
            lo < min ||
            hi > max ||
            lo > hi) {
          throw FormatException(
            'Invalid cron range "${ends[0]}-${ends[1]}": '
            'expected values between $min and $max.',
          );
        }
        continue;
      }
      final value = int.tryParse(range);
      if (value == null || value < min || value > max) {
        throw FormatException(
          'Invalid cron value "$range": expected * or a number '
          'between $min and $max.',
        );
      }
    }
  }

  bool _fieldMatches(String field, int value, int min) {
    for (final item in field.split(',')) {
      final stepSplit = item.split('/');
      final range = stepSplit[0];
      final step =
          stepSplit.length == 2 ? int.parse(stepSplit[1]) : 1;
      var lo = min;
      var hi = value;
      var wholeRange = false;
      if (range == '*') {
        wholeRange = true;
      } else if (range.contains('-')) {
        final ends = range.split('-');
        lo = int.parse(ends[0]);
        hi = int.parse(ends[1]);
      } else {
        lo = int.parse(range);
        hi = int.parse(range);
      }
      if (wholeRange) {
        if ((value - min) % step == 0) return true;
      } else if (value >= lo &&
          value <= hi &&
          (value - lo) % step == 0) {
        return true;
      }
    }
    return false;
  }

  bool _matches(_CronFields fields, DateTime candidate) {
    if (!_fieldMatches(fields.minute, candidate.minute, 0)) return false;
    if (!_fieldMatches(fields.hour, candidate.hour, 0)) return false;
    if (!_fieldMatches(fields.month, candidate.month, 1)) return false;
    final domMatch = _fieldMatches(fields.dom, candidate.day, 1);
    final dowMatch =
        _fieldMatches(fields.dow, candidate.weekday % 7, 0) ||
            (fields.dow != '*' && _dowValueMatchesSunday7(fields, candidate));
    if (fields.dom == '*' && fields.dow == '*') return true;
    if (fields.dom == '*') return dowMatch;
    if (fields.dow == '*') return domMatch;
    return domMatch || dowMatch;
  }

  bool _dowValueMatchesSunday7(_CronFields fields, DateTime candidate) {
    // Accept 7 as Sunday in addition to 0.
    if (candidate.weekday % 7 != 0) return false;
    for (final item in fields.dow.split(',')) {
      final range = item.split('/')[0];
      if (range == '7') return true;
      if (range.contains('-')) {
        final ends = range.split('-');
        if (int.parse(ends[0]) <= 7 && int.parse(ends[1]) >= 7) {
          return true;
        }
      }
    }
    return false;
  }

  String _describeDow(String field) {
    if (field == '*') return 'every day of the week';
    final parts = <String>[];
    for (final item in field.split(',')) {
      final range = item.split('/')[0];
      if (range == '*') {
        parts.add('every day');
        continue;
      }
      if (range.contains('-')) {
        final ends = range.split('-');
        parts.add(
          '${_dowNames[int.parse(ends[0]) % 7]} through '
          '${_dowNames[int.parse(ends[1]) % 7]}',
        );
      } else {
        parts.add(_dowNames[int.parse(range) % 7]);
      }
    }
    return parts.join(', ');
  }

  String _describeDom(String field) {
    if (field == '*') return '';
    return 'on day-of-month ${field.replaceAll(',', ', ')}';
  }

  String _describeMonth(String field) {
    if (field == '*') return '';
    final parts = field.split(',').map((item) {
      final range = item.split('/')[0];
      if (range.contains('-')) {
        final ends = range.split('-');
        return '${_monthNames[int.parse(ends[0])]} through '
            '${_monthNames[int.parse(ends[1])]}';
      }
      return _monthNames[int.parse(range)];
    }).toList();
    return 'in ${parts.join(', ')}';
  }

  String _describeTime(String minute, String hour) {
    final minuteIsEvery = minute == '*';
    final hourIsEvery = hour == '*';
    if (minuteIsEvery && hourIsEvery) return 'every minute';
    if (minute.startsWith('*/')) {
      final step = minute.substring(2);
      if (hourIsEvery) return 'every $step minutes';
      return 'every $step minutes during hour $hour';
    }
    if (minuteIsEvery) {
      return 'every minute during hour $hour:00';
    }
    final m = minute.padLeft(2, '0');
    if (hourIsEvery) return 'at minute $m past every hour';
    return 'at ${hour.padLeft(2, '0')}:$m';
  }

  String _explain(String expression) {
    final fields = _parse(expression);
    final time = _describeTime(fields.minute, fields.hour);
    final month = _describeMonth(fields.month);
    String day;
    if (fields.dom == '*' && fields.dow == '*') {
      day = 'every day';
    } else if (fields.dom == '*') {
      day = 'on ${_describeDow(fields.dow)}';
    } else if (fields.dow == '*') {
      day = _describeDom(fields.dom);
    } else {
      day = '${_describeDom(fields.dom)} and on ${_describeDow(fields.dow)}';
    }
    final monthSuffix = month.isEmpty ? '' : ' $month';
    return 'Runs $time $day$monthSuffix '
        '(cron "$expression": minute ${fields.minute}, hour ${fields.hour}, '
        'day-of-month ${fields.dom}, month ${fields.month}, '
        'day-of-week ${fields.dow}).';
  }

  List<int> _parseTime(String? time) {
    final raw = (time ?? '09:00').trim();
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(raw);
    if (match == null) {
      throw FormatException(
        'Invalid time "$raw": expected 24-hour HH:MM.',
      );
    }
    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      throw FormatException(
        'Invalid time "$raw": hour must be 0-23 and minute 0-59.',
      );
    }
    return [minute, hour];
  }

  static const _dayNameToNumber = {
    'sun': 0, 'sunday': 0,
    'mon': 1, 'monday': 1,
    'tue': 2, 'tues': 2, 'tuesday': 2,
    'wed': 3, 'wednesday': 3,
    'thu': 4, 'thur': 4, 'thurs': 4, 'thursday': 4,
    'fri': 5, 'friday': 5,
    'sat': 6, 'saturday': 6,
  };

  String _build(String frequency, String? time, List<dynamic> days) {
    final t = _parseTime(time);
    final minute = t[0];
    final hour = t[1];
    List<String> dayNumbers() {
      return days.map((d) {
        if (d is num) {
          final n = d.toInt();
          if (n < 0 || n > 7) {
            throw FormatException(
              'Invalid day "$d": expected 0-7 (0 and 7 are Sunday).',
            );
          }
          return '$n';
        }
        final key = d.toString().trim().toLowerCase();
        final asInt = int.tryParse(key);
        if (asInt != null) {
          if (asInt < 0 || asInt > 7) {
            throw FormatException(
              'Invalid day "$d": expected 0-7 (0 and 7 are Sunday).',
            );
          }
          return '$asInt';
        }
        final named = _dayNameToNumber[key];
        if (named == null) {
          throw FormatException(
            'Invalid day "$d": expected 0-7 or a weekday name.',
          );
        }
        return '$named';
      }).toList();
    }

    switch (frequency.trim().toLowerCase()) {
      case 'every_minute':
      case 'minutely':
        return '* * * * *';
      case 'hourly':
        return '$minute * * * *';
      case 'daily':
        return '$minute $hour * * *';
      case 'weekly':
        final dows = days.isEmpty ? ['1'] : dayNumbers();
        return '$minute $hour * * ${dows.join(',')}';
      case 'monthly':
        final doms = days.isEmpty ? ['1'] : dayNumbers().map((d) {
          final n = int.parse(d);
          if (n < 1 || n > 31) {
            throw FormatException(
              'Invalid month day "$d": expected 1-31.',
            );
          }
          return d;
        }).toList();
        return '$minute $hour ${doms.join(',')} * *';
      default:
        throw ArgumentError(
          'Unknown frequency "$frequency": expected one of '
          'every_minute, hourly, daily, weekly, monthly.',
        );
    }
  }

  String _nextRuns(String expression, int count) {
    final fields = _parse(expression);
    final wanted = count.clamp(1, 100);
    var cursor = DateTime.now()
        .toUtc()
        .add(const Duration(minutes: 1))
        .copyWith(second: 0, millisecond: 0, microsecond: 0);
    final runs = <String>[];
    // One leap-year of minute iterations is a safe upper bound: any valid
    // expression with a yearly occurrence matches within 366 days.
    const limit = 366 * 24 * 60;
    for (var i = 0; i < limit && runs.length < wanted; i++) {
      if (_matches(fields, cursor)) runs.add(cursor.toIso8601String());
      cursor = cursor.add(const Duration(minutes: 1));
    }
    return jsonEncode({'runs': runs});
  }
}

// ---------------------------------------------------------------------------
// Color Palette Gen
// ---------------------------------------------------------------------------

class _Rgb {
  const _Rgb(this.r, this.g, this.b);
  final int r;
  final int g;
  final int b;
}

class _Hsl {
  const _Hsl(this.h, this.s, this.l);
  final double h; // 0-360
  final double s; // 0-1
  final double l; // 0-1
}

class ColorPaletteGenCapability implements NativePluginCapability {
  @override
  String get pluginName => 'Color Palette Gen';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'from_hex',
          description: 'Generate complementary/analogous/triadic swatches.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'hex': {'type': 'string'},
            },
            'required': ['hex'],
          },
        ),
        NativePluginTool(
          name: 'contrast',
          description: 'WCAG 2.1 contrast ratio between two hex colors.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'hex1': {'type': 'string'},
              'hex2': {'type': 'string'},
            },
            'required': ['hex1', 'hex2'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'from_hex':
        return _fromHex(_requireString(args, 'hex'));
      case 'contrast':
        return _contrast(
          _requireString(args, 'hex1'),
          _requireString(args, 'hex2'),
        );
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  _Rgb _parseHex(String raw) {
    var hex = raw.trim().toLowerCase();
    if (hex.startsWith('#')) hex = hex.substring(1);
    if (hex.length == 3) {
      hex = hex.split('').map((c) => '$c$c').join();
    }
    if (!RegExp(r'^[0-9a-f]{6}$').hasMatch(hex)) {
      throw FormatException(
        'Invalid hex color "$raw": expected #rrggbb or #rgb.',
      );
    }
    return _Rgb(
      int.parse(hex.substring(0, 2), radix: 16),
      int.parse(hex.substring(2, 4), radix: 16),
      int.parse(hex.substring(4, 6), radix: 16),
    );
  }

  String _toHex(_Rgb rgb) {
    String two(int v) =>
        v.clamp(0, 255).toRadixString(16).padLeft(2, '0');
    return '#${two(rgb.r)}${two(rgb.g)}${two(rgb.b)}';
  }

  _Hsl _toHsl(_Rgb rgb) {
    final r = rgb.r / 255.0;
    final g = rgb.g / 255.0;
    final b = rgb.b / 255.0;
    final maxC = [r, g, b].reduce((a, v) => a > v ? a : v);
    final minC = [r, g, b].reduce((a, v) => a < v ? a : v);
    final l = (maxC + minC) / 2.0;
    if (maxC == minC) return _Hsl(0, 0, l);
    final d = maxC - minC;
    final s = l > 0.5 ? d / (2.0 - maxC - minC) : d / (maxC + minC);
    double h;
    if (maxC == r) {
      h = ((g - b) / d + (g < b ? 6 : 0)) * 60.0;
    } else if (maxC == g) {
      h = ((b - r) / d + 2) * 60.0;
    } else {
      h = ((r - g) / d + 4) * 60.0;
    }
    return _Hsl(h, s, l);
  }

  _Rgb _fromHsl(_Hsl hsl) {
    final h = ((hsl.h % 360) + 360) % 360 / 360.0;
    final s = hsl.s.clamp(0.0, 1.0);
    final l = hsl.l.clamp(0.0, 1.0);
    if (s == 0) {
      final v = (l * 255).round();
      return _Rgb(v, v, v);
    }
    double hueToRgb(double p, double q, double t) {
      var tt = t;
      if (tt < 0) tt += 1;
      if (tt > 1) tt -= 1;
      if (tt < 1 / 6) return p + (q - p) * 6 * tt;
      if (tt < 1 / 2) return q;
      if (tt < 2 / 3) return p + (q - p) * (2 / 3 - tt) * 6;
      return p;
    }

    final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    final p = 2 * l - q;
    return _Rgb(
      (hueToRgb(p, q, h + 1 / 3) * 255).round(),
      (hueToRgb(p, q, h) * 255).round(),
      (hueToRgb(p, q, h - 1 / 3) * 255).round(),
    );
  }

  String _shiftHue(_Hsl base, double degrees) =>
      _toHex(_fromHsl(_Hsl(base.h + degrees, base.s, base.l)));

  String _fromHex(String raw) {
    final rgb = _parseHex(raw);
    final hsl = _toHsl(rgb);
    return jsonEncode({
      'base': _toHex(rgb),
      'complementary': _shiftHue(hsl, 180),
      'analogous': [_shiftHue(hsl, -30), _shiftHue(hsl, 30)],
      'triadic': [_shiftHue(hsl, 120), _shiftHue(hsl, 240)],
      'monochromatic': [
        _toHex(_fromHsl(_Hsl(hsl.h, hsl.s, hsl.l - 0.2))),
        _toHex(rgb),
        _toHex(_fromHsl(_Hsl(hsl.h, hsl.s, hsl.l + 0.2))),
      ],
    });
  }

  double _luminance(_Rgb rgb) {
    double linearize(int channel) {
      final c = channel / 255.0;
      return c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * linearize(rgb.r) +
        0.7152 * linearize(rgb.g) +
        0.0722 * linearize(rgb.b);
  }

  String _contrast(String raw1, String raw2) {
    final l1 = _luminance(_parseHex(raw1));
    final l2 = _luminance(_parseHex(raw2));
    final lighter = l1 > l2 ? l1 : l2;
    final darker = l1 > l2 ? l2 : l1;
    final ratio = (lighter + 0.05) / (darker + 0.05);
    final rounded = double.parse(ratio.toStringAsFixed(2));
    return jsonEncode({
      'ratio': rounded,
      'aa_normal': rounded >= 4.5,
      'aa_large': rounded >= 3.0,
      'aaa_normal': rounded >= 7.0,
      'aaa_large': rounded >= 4.5,
    });
  }
}
