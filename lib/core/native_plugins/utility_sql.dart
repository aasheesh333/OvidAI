/// Lossless lexical tokens. Formatting never changes protected token contents
/// or inserts spaces inside operators, qualified names, or literal prefixes.
class UtilitySqlToken {
  const UtilitySqlToken(this.text, this.kind);
  final String text;
  final String kind;
  String get upper => text.toUpperCase();
}

List<UtilitySqlToken> lexUtilitySql(String sql) {
  if (sql.length > 262144) {
    throw const FormatException('SQL input limit exceeded: 262144 code units.');
  }
  final tokens = <UtilitySqlToken>[];
  var i = 0;
  var depth = 0;
  bool word(int c) =>
      c >= 65 && c <= 90 || c >= 97 && c <= 122 || c == 95 || c >= 128;
  bool digit(int c) => c >= 48 && c <= 57;
  while (i < sql.length) {
    final start = i;
    final c = sql[i];
    var kind = 'symbol';
    if (c.trim().isEmpty) {
      kind = 'space';
      while (i < sql.length && sql[i].trim().isEmpty) {
        i++;
      }
    } else if (sql.startsWith('--', i)) {
      kind = 'comment';
      i += 2;
      while (i < sql.length && sql[i] != '\n' && sql[i] != '\r') {
        i++;
      }
      if (i < sql.length && sql[i] == '\r') {
        i++;
      }
      if (i < sql.length && sql[i] == '\n') {
        i++;
      }
    } else if (sql.startsWith('/*', i)) {
      kind = 'comment';
      i += 2;
      var nesting = 1;
      while (i < sql.length && nesting > 0) {
        if (sql.startsWith('/*', i)) {
          nesting++;
          i += 2;
        } else if (sql.startsWith('*/', i)) {
          nesting--;
          i += 2;
        } else {
          i++;
        }
      }
      if (nesting != 0) {
        throw FormatException('Unclosed SQL comment at $start.');
      }
    } else if (c == "'" || c == '"' || c == '`' || c == '[') {
      kind = c == "'" ? 'string' : 'identifier';
      final close = c == '[' ? ']' : c;
      i++;
      var closed = false;
      while (i < sql.length) {
        if (sql[i] == close) {
          i++;
          if (i < sql.length && sql[i] == close) {
            i++;
            continue;
          }
          closed = true;
          break;
        }
        // Backslash escapes have dialect-dependent meaning: do not guess.
        if (sql[i] == r'\' && c == "'") {
          throw const FormatException(
            'Unsupported SQL backslash string escape; use doubled quotes.',
          );
        }
        i++;
      }
      if (!closed) {
        throw FormatException('Unbalanced SQL quote at $start.');
      }
    } else if (c == r'$') {
      final delimiter = RegExp(
        r'\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$',
      ).matchAsPrefix(sql, i)?.group(0);
      if (delimiter == null) {
        i++;
      } else {
        kind = 'dollar';
        final end = sql.indexOf(delimiter, i + delimiter.length);
        if (end == -1) {
          throw FormatException('Unclosed dollar quote at $start.');
        }
        i = end + delimiter.length;
      }
    } else if (word(sql.codeUnitAt(i))) {
      kind = 'word';
      i++;
      while (i < sql.length &&
          (word(sql.codeUnitAt(i)) ||
              digit(sql.codeUnitAt(i)) ||
              sql[i] == r'$')) {
        i++;
      }
    } else if (digit(sql.codeUnitAt(i))) {
      kind = 'number';
      i++;
      while (i < sql.length && digit(sql.codeUnitAt(i))) {
        i++;
      }
      if (i + 1 < sql.length && sql[i] == '.' && digit(sql.codeUnitAt(i + 1))) {
        i++;
        while (i < sql.length && digit(sql.codeUnitAt(i))) {
          i++;
        }
      }
    } else {
      i++;
      if (c == '(' && ++depth > 64) {
        throw const FormatException(
          'SQL parentheses depth limit exceeded: 64.',
        );
      }
      if (c == ')' && --depth < 0) {
        throw const FormatException('Unbalanced SQL parentheses.');
      }
      if (i < sql.length &&
          const {
            '<=',
            '>=',
            '<>',
            '!=',
            '||',
            '::',
            '->',
            '==',
            '<<',
            '>>',
          }.contains(sql.substring(start, i + 1))) {
        i++;
      }
    }
    tokens.add(UtilitySqlToken(sql.substring(start, i), kind));
  }
  if (depth != 0) {
    throw const FormatException('Unbalanced SQL parentheses.');
  }
  return tokens;
}

/// Deliberately small, completely consumed grammar, not a database validator.
/// SELECT [DISTINCT] (atom [AS identifier]) (, ...)* [FROM identifier]
/// [WHERE atom comparison atom ((AND|OR) atom comparison atom)*] [;]
/// atom: identifier[.identifier], decimal, standard string, NULL, TRUE, FALSE, *.
/// No implicit aliases, functions, joins, subqueries, DDL, or multiple statements.
class UtilitySelectParser {
  UtilitySelectParser(List<UtilitySqlToken> tokens, this.dialect)
    : tokens = tokens
          .where((t) => t.kind != 'space' && t.kind != 'comment')
          .toList();
  final List<UtilitySqlToken> tokens;
  final String dialect;
  var i = 0;
  static const reserved = {
    'SELECT',
    'DISTINCT',
    'FROM',
    'WHERE',
    'AND',
    'OR',
    'AS',
    'NULL',
    'TRUE',
    'FALSE',
    'JOIN',
    'ON',
    'ORDER',
    'GROUP',
    'LIMIT',
    'UNION',
    'INSERT',
    'UPDATE',
    'DELETE',
    'CREATE',
    'TABLE',
    'NOT',
    'IS',
    'IN',
    'BY',
  };
  bool take(String text) {
    if (i < tokens.length && tokens[i].upper == text) {
      i++;
      return true;
    }
    return false;
  }

  Never fail() => throw const FormatException(
    'Unsupported or invalid SQL: expected the documented SELECT subset.',
  );
  void identifier() {
    if (i >= tokens.length) {
      fail();
    }
    final t = tokens[i];
    if (t.text.startsWith('[') && t.text.contains(']]')) {
      fail(); // SQLite bracket identifiers do not support doubled ] escapes.
    }
    if (t.kind == 'word' && !reserved.contains(t.upper) ||
        t.kind == 'identifier' &&
            (t.text.startsWith('"') || dialect == 'sqlite')) {
      i++;
    } else {
      fail();
    }
  }

  void atom({bool star = false}) {
    if (i >= tokens.length) {
      fail();
    }
    if (star && take('*')) {
      return;
    }
    if (const {'number', 'string'}.contains(tokens[i].kind) ||
        const {'NULL', 'TRUE', 'FALSE'}.contains(tokens[i].upper)) {
      i++;
      return;
    }
    identifier();
    if (take('.')) {
      identifier();
    }
  }

  void comparison() {
    atom();
    if (i >= tokens.length ||
        !const {
          '=',
          '<',
          '>',
          '<=',
          '>=',
          '<>',
          '!=',
        }.contains(tokens[i++].text)) {
      fail();
    }
    atom();
  }

  void parse() {
    if (!take('SELECT')) {
      fail();
    }
    take('DISTINCT');
    do {
      final wildcard = i < tokens.length && tokens[i].text == '*';
      atom(star: true);
      if (take('AS')) {
        if (wildcard) fail();
        identifier();
      }
    } while (take(','));
    if (take('FROM')) {
      identifier();
    }
    if (take('WHERE')) {
      comparison();
      while (take('AND') || take('OR')) {
        comparison();
      }
    }
    take(';');
    if (i != tokens.length) {
      fail();
    }
  }
}
