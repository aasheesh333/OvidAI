import 'dart:io';
import 'dart:math' show min;

import 'package:flutter_test/flutter_test.dart';

/// Text-budget ratchet for the rebuilt UI (docs/design/MINIMAL_UI_CONTRACT.md §3).
///
/// The audit reads the source of `lib/ui/v2/**` instead of pumping screens,
/// because the budget is about the *role* of a string (header title, row
/// subtitle, button label), and a widget tree does not carry that role.
///
/// Two passes cover the roles:
///  * a **specific** pass keyed by the shared primitive that owns the role
///    (`OScreen.title`, `OListRow.subtitle`, `OEmptyState.message`, …);
///  * a **generic** pass keyed by argument name (`emptyTitle`, `emptyBody`,
///    `emptyMessage`, `title`, `subtitle`, …). This is what catches the data
///    classes (`V2BrowserData`, `V2ChatSuggestion`, `V2TimelineItem`) and any
///    new constructor that reuses a role-bearing argument name.
///
/// Where both passes see an argument, the stricter budget wins.
///
/// Gates:
///  * a count ratchet: no over-budget role literal may exist ([_maxViolations]
///    is 0; every entry the test prints is a regression, not debt);
///  * a word ratchet: the total number of words in role-bearing literals may
///    not grow past [_maxRoleWords], so adding short-but-redundant copy still
///    fails even when each individual string fits its budget;
///  * a coverage floor: the scan must keep finding at least [_minChecked]
///    literals and every component in [_budgets] must still be present, so a
///    rename cannot silently disable a role;
///  * a hard ban on the phrases the contract deletes on sight (§3, §6),
///    checked on merged adjacent literals so `'Tap ' 'to open'` cannot dodge it.
///
/// Audit baseline (2026-10-22): widening the scan from the primitives to every
/// call exposed 8 over-budget literals (sheet header, browser empty state,
/// chat suggestions, one timeline row). All 8 were rewritten, which is why the
/// ceilings below are the post-fix numbers. Only ever lower them.
void main() {
  test('v2 copy stays inside the text budget', () {
    final audit = _auditV2();
    if (audit.report.isNotEmpty) {
      // ignore: avoid_print
      print(audit.report);
    }

    expect(
      audit.missing,
      isEmpty,
      reason: 'The budget scanner no longer finds these primitives: '
          '${audit.missing.join(', ')}. Their call shape changed; update '
          '_budgets so the role stays covered.',
    );

    expect(
      audit.checked,
      greaterThanOrEqualTo(_minChecked),
      reason: 'The budget scanner found only ${audit.checked} role-bearing '
          'strings (floor $_minChecked). A primitive or an argument name '
          'changed; update _budgets or _argBudgets.',
    );

    expect(
      audit.violations.length,
      lessThanOrEqualTo(_maxViolations),
      reason: 'New copy exceeded the §3 text budget. Shorten the listed '
          'strings. The ceiling is 0: there is no accepted debt.',
    );

    expect(
      audit.roleWords,
      lessThanOrEqualTo(_maxRoleWords),
      reason: 'Role-bearing copy grew to ${audit.roleWords} words (ceiling '
          '$_maxRoleWords). Every added word is a cost even when the string '
          'fits its per-element budget. Delete a word or lower the ceiling.',
    );
  });

  test('v2 copy never uses a banned phrase', () {
    final hits = <_Violation>[];
    for (final file in _v2Files()) {
      final source = file.readAsStringSync();
      final relative = file.path.replaceAll(r'\', '/');
      // Merge adjacent literals so a phrase split across concatenation still
      // matches; comments are skipped by the scanner.
      for (final literal in _literalsIn(source, 0, source.length)) {
        for (final phrase in _bannedPhrases) {
          if (!_hitsBan(literal.text, phrase)) continue;
          hits.add(
            _Violation(
              file: relative,
              line: _lineOf(source, literal.start),
              role: 'ban',
              words: _wordCount(literal.text),
              max: 0,
              text: literal.text,
            ),
          );
        }
      }
    }

    hits.sort((a, b) => a.file == b.file
        ? a.line.compareTo(b.line)
        : a.file.compareTo(b.file));
    if (hits.isNotEmpty) {
      final report = StringBuffer('Banned phrases (${hits.length}):\n');
      for (final hit in hits) {
        report.writeln('  $hit');
      }
      // ignore: avoid_print
      print(report);
    }

    expect(
      hits,
      isEmpty,
      reason: 'The contract deletes these phrases on sight. Rewrite the copy.',
    );
  });
}

/// Over-budget role-bearing literals. Zero: the ceiling is the floor.
const int _maxViolations = 0;

/// Total words across every role-bearing literal, post-audit.
///
/// Ratchet: only ever lower this. It stops short strings from accumulating
/// until the screen says the same thing five times.
/// Raised twice, both times for copy that fixed a defect rather than
/// decorated a screen:
///
///  2609 -> 2675  every empty state gained the sentence that tells a person
///                what to do next, and error copy stopped leaking raw
///                exception text. A blank body and "SocketException: ..." on
///                screen were both bugs.
///  2675 -> 2688  the billing gate, the report action and the export scope
///                each gained the sentence that makes their limit honest.
///
/// From here the rule is absolute: new copy replaces copy, it does not add to
/// it. Raise this only for a change that removes a false claim.
const int _maxRoleWords = 2688;

/// Lower bound on the number of literals the scan must see. Guards against a
/// refactor that quietly narrows the audit.
const int _minChecked = 1000;

/// Positional arguments are recorded under this name so the snackbar and
/// button passes can pick the copy argument without a second parser.
const String _positional = 'data';

/// Local helpers that show a transient message. Their second argument is the
/// copy the person reads, so it obeys the toast budget (§3: 8 words).
const List<String> _snackCalls = <String>['_snack', '_showSnack', '_toast'];

/// Framework buttons whose visible label is the first `Text` child.
const List<String> _buttonCalls = <String>[
  'TextButton',
  'FilledButton',
  'OutlinedButton',
  'ElevatedButton',
];

/// Phrases the contract deletes on sight (§3 and §6).
const List<String> _bannedPhrases = <String>[
  'not available yet',
  'coming soon',
  'tap to',
  'simply',
  'just',
  'please',
  'in order to',
  'nothing here yet',
];

/// Whole-word match for single words ("adjust" must not trip "just").
bool _hitsBan(String text, String phrase) {
  final lower = text.toLowerCase();
  if (phrase.contains(' ')) return lower.contains(phrase);
  return RegExp('\\b${RegExp.escape(phrase)}\\b').hasMatch(lower);
}

/// Role budgets from §3: component argument -> max words.
const Map<String, Map<String, int>> _budgets = <String, Map<String, int>>{
  'OAppBar': <String, int>{'title': 3, 'subtitle': 6},
  'OScreen': <String, int>{'title': 3, 'subtitle': 6},
  'OSheetHeader': <String, int>{'title': 3, 'subtitle': 6, 'closeLabel': 3},
  'OnboardingStepScaffold': <String, int>{
    'title': 3,
    'subtitle': 6,
    'primaryLabel': 3,
    'skipLabel': 3,
    'loadingLabel': 3,
  },
  'OListRow': <String, int>{'title': 4, 'subtitle': 10},
  'OSectionHeader': <String, int>{'label': 3},
  'OSectionTitle': <String, int>{'title': 3, 'actionLabel': 3},
  'OButton': <String, int>{'label': 3},
  'OTextAction': <String, int>{'label': 3},
  'OEmptyState': <String, int>{'title': 4, 'message': 18},
  'OErrorState': <String, int>{
    'title': 4,
    'message': 18,
    'retryLabel': 3,
  },
  'OStateView': <String, int>{
    'emptyTitle': 4,
    'emptyBody': 18,
    'emptyActionLabel': 3,
  },
  'OSearchField': <String, int>{'hint': 6},
  'OChip': <String, int>{'label': 3},
  'OPill': <String, int>{'label': 3},
  'showOSheet': <String, int>{'title': 3},
  'OLoadingState': <String, int>{'label': 3},
};

/// Argument-name safety net applied to every call, so a role cannot escape the
/// audit just because it lives on a data class instead of a shared primitive.
/// Header/sheet/row titles are at most four words generically; the specific
/// pass above tightens headers to three. Subtitles are ten generically, while
/// headers tighten them to six.
const Map<String, int> _argBudgets = <String, int>{
  'title': 4,
  'subtitle': 10,
  'emptyTitle': 4,
  'emptyBody': 18,
  'emptyMessage': 18,
  'emptyDescription': 18,
  'emptyActionLabel': 3,
  'retryLabel': 3,
  'closeLabel': 3,
};

List<File> _v2Files() {
  final root = Directory('lib/ui/v2');
  if (!root.existsSync()) {
    fail('Run this test from the package root: ${root.path} is missing.');
  }
  return root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

int _lineOf(String source, int offset) {
  var line = 1;
  for (var i = 0; i < offset && i < source.length; i++) {
    if (source.codeUnitAt(i) == 10) line++;
  }
  return line;
}

final RegExp _word = RegExp(r"[A-Za-z][A-Za-z'’\-]*");

int _wordCount(String text) {
  final plain = text
      .replaceAll(RegExp(r'\$\{[^}]*\}'), 'X')
      .replaceAll(RegExp(r'\$[A-Za-z_][A-Za-z0-9_]*'), 'X');
  return _word.allMatches(plain).length;
}

_Audit _auditV2() {
  final violations = <_Violation>[];
  final seen = <String>{};
  var checked = 0;
  var roleWords = 0;

  for (final file in _v2Files()) {
    final source = file.readAsStringSync();
    final relative = file.path.replaceAll(r'\', '/');
    final calls = _allCalls(source);

    // Specific role budgets, keyed by the call's opening paren so the generic
    // pass can apply the stricter of the two without parsing the file twice.
    final specific = <String, int>{};
    for (final component in _budgets.entries) {
      for (final call in _calls(source, component.key)) {
        seen.add(component.key);
        for (final arg in _topLevelArgs(source, call.open, call.close)) {
          final max = component.value[arg.name];
          if (max != null) specific['${call.open}:${arg.name}'] = max;
        }
      }
    }

    for (final call in calls) {
      for (final arg in _topLevelArgs(source, call.open, call.close)) {
        final specificMax = specific['${call.open}:${arg.name}'];
        final genericMax = _argBudgets[arg.name];
        final limits = <int>[?specificMax, ?genericMax];
        if (limits.isEmpty) continue;
        final max = limits.reduce(min);
        for (final literal in _literalsIn(
          source,
          arg.valueStart,
          arg.valueEnd,
        )) {
          checked++;
          final words = _wordCount(literal.text);
          roleWords += words;
          if (words > max) {
            violations.add(
              _Violation(
                file: relative,
                line: _lineOf(source, literal.start),
                role: '${call.name}.${arg.name}',
                words: words,
                max: max,
                text: literal.text,
              ),
            );
          }
        }
      }
    }

    for (final name in _snackCalls) {
      for (final call in _calls(source, name)) {
        final positional = _topLevelArgs(source, call.open, call.close)
            .where((arg) => arg.name == _positional)
            .toList();
        if (positional.length < 2) continue;
        for (final literal in _literalsIn(
          source,
          positional[1].valueStart,
          positional[1].valueEnd,
        )) {
          checked++;
          final words = _wordCount(literal.text);
          roleWords += words;
          if (words > 8) {
            violations.add(
              _Violation(
                file: relative,
                line: _lineOf(source, literal.start),
                role: 'toast',
                words: words,
                max: 8,
                text: literal.text,
              ),
            );
          }
        }
      }
    }

    for (final call in calls) {
      if (call.name == 'SnackBar') {
        _checkTextChild(
          source: source,
          calls: calls,
          call: call,
          argument: 'content',
          max: 8,
          role: 'snackbar',
          file: relative,
          violations: violations,
          onLiteral: (words) {
            checked++;
            roleWords += words;
          },
        );
      } else if (_buttonCalls.contains(call.name)) {
        _checkTextChild(
          source: source,
          calls: calls,
          call: call,
          argument: 'child',
          max: 3,
          role: 'button',
          file: relative,
          violations: violations,
          onLiteral: (words) {
            checked++;
            roleWords += words;
          },
        );
      }
    }
  }

  violations.sort((a, b) => a.file == b.file
      ? a.line.compareTo(b.line)
      : a.file.compareTo(b.file));

  final missing = _budgets.keys.where((key) => !seen.contains(key)).toList();

  final report = StringBuffer();
  if (violations.isNotEmpty) {
    report.writeln('Over budget (${violations.length}):');
    for (final v in violations) {
      report.writeln('  $v');
    }
  }
  if (missing.isNotEmpty) {
    report.writeln('Primitives no longer found (${missing.length}):');
    for (final name in missing) {
      report.writeln('  $name');
    }
  }

  return _Audit(
    violations: violations,
    checked: checked,
    roleWords: roleWords,
    missing: missing,
    report: report.toString(),
  );
}

/// Check a literal `Text` passed as [argument] of [call] against [max].
void _checkTextChild({
  required String source,
  required List<_NamedCall> calls,
  required _NamedCall call,
  required String argument,
  required int max,
  required String role,
  required String file,
  required List<_Violation> violations,
  required void Function(int words) onLiteral,
}) {
  for (final arg in _topLevelArgs(source, call.open, call.close)) {
    if (arg.name != argument) continue;
    for (final textCall in calls) {
      if (textCall.name != 'Text') continue;
      if (textCall.open < arg.valueStart || textCall.close > arg.valueEnd) {
        continue;
      }
      for (final textArg in _topLevelArgs(
        source,
        textCall.open,
        textCall.close,
      )) {
        if (textArg.name != _positional) continue;
        for (final literal in _literalsIn(
          source,
          textArg.valueStart,
          textArg.valueEnd,
        )) {
          final words = _wordCount(literal.text);
          onLiteral(words);
          if (words > max) {
            violations.add(
              _Violation(
                file: file,
                line: _lineOf(source, literal.start),
                role: role,
                words: words,
                max: max,
                text: literal.text,
              ),
            );
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// A deliberately small Dart string scanner. It understands comments, single,
// double and triple quoted strings, raw strings and `${...}` interpolation, so
// a quote inside an interpolation does not desynchronise the scan.
// ---------------------------------------------------------------------------

class _Literal {
  const _Literal(this.start, this.text);

  final int start;
  final String text;
}

class _Call {
  const _Call(this.open, this.close);

  final int open;
  final int close;
}

class _NamedCall {
  const _NamedCall(this.name, this.open, this.close);

  final String name;
  final int open;
  final int close;
}

class _Arg {
  const _Arg(this.name, this.valueStart, this.valueEnd);

  final String name;
  final int valueStart;
  final int valueEnd;
}

class _Audit {
  const _Audit({
    required this.violations,
    required this.checked,
    required this.roleWords,
    required this.missing,
    required this.report,
  });

  final List<_Violation> violations;
  final int checked;
  final int roleWords;
  final List<String> missing;
  final String report;
}

bool _isIdent(int c) =>
    (c >= 65 && c <= 90) ||
    (c >= 97 && c <= 122) ||
    (c >= 48 && c <= 57) ||
    c == 95 ||
    c == 36;

bool _isSpace(int c) => c == 32 || c == 9 || c == 10 || c == 13;

int _skipString(String s, int i) {
  final quote = s[i];
  final triple = s.startsWith(quote * 3, i);
  final raw = i > 0 &&
      s[i - 1] == 'r' &&
      (i < 2 || !_isIdent(s.codeUnitAt(i - 2)));
  var j = i + (triple ? 3 : 1);
  while (j < s.length) {
    if (!raw && s.codeUnitAt(j) == 92) {
      j += 2;
      continue;
    }
    if (triple) {
      if (s.startsWith(quote * 3, j)) return j + 3;
    } else if (s[j] == quote) {
      return j + 1;
    }
    if (s.codeUnitAt(j) == 36 && j + 1 < s.length && s[j + 1] == '{') {
      j = _skipInterpolation(s, j + 2);
      continue;
    }
    j++;
  }
  return s.length;
}

int _skipInterpolation(String s, int i) {
  var depth = 1;
  while (i < s.length) {
    final c = s[i];
    if (c == "'" || c == '"') {
      i = _skipString(s, i);
      continue;
    }
    if (c == '/' && i + 1 < s.length && s[i + 1] == '/') {
      final next = s.indexOf('\n', i);
      if (next < 0) return s.length;
      i = next;
      continue;
    }
    if (c == '/' && i + 1 < s.length && s[i + 1] == '*') {
      final next = s.indexOf('*/', i + 2);
      if (next < 0) return s.length;
      i = next + 2;
      continue;
    }
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return i + 1;
    }
    i++;
  }
  return s.length;
}

/// Index of the `)` matching the `(` at [open], or -1.
int _matchParen(String source, int open) {
  var depth = 0;
  var i = open;
  while (i < source.length) {
    final c = source[i];
    if (c == "'" || c == '"') {
      i = _skipString(source, i);
      continue;
    }
    if (c == '/' && i + 1 < source.length && source[i + 1] == '/') {
      final next = source.indexOf('\n', i);
      if (next < 0) break;
      i = next;
      continue;
    }
    if (c == '/' && i + 1 < source.length && source[i + 1] == '*') {
      final next = source.indexOf('*/', i + 2);
      if (next < 0) break;
      i = next + 2;
      continue;
    }
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return -1;
}

List<_Call> _calls(String source, String name) {
  final out = <_Call>[];
  final pattern = RegExp(
    '(?<![A-Za-z0-9_.])${RegExp.escape(name)}' r'\s*\(',
  );
  for (final match in pattern.allMatches(source)) {
    final open = match.end - 1;
    final close = _matchParen(source, open);
    if (close > open) out.add(_Call(open, close));
  }
  return out;
}

/// Every call in [source], including method calls and nested calls. Comments
/// and string contents are skipped, so `'foo('` is not a call.
List<_NamedCall> _allCalls(String source) {
  final out = <_NamedCall>[];
  var i = 0;
  while (i < source.length) {
    final c = source[i];
    if (c == "'" || c == '"') {
      i = _skipString(source, i);
      continue;
    }
    if (c == '/' && i + 1 < source.length && source[i + 1] == '/') {
      final next = source.indexOf('\n', i);
      if (next < 0) break;
      i = next;
      continue;
    }
    if (c == '/' && i + 1 < source.length && source[i + 1] == '*') {
      final next = source.indexOf('*/', i + 2);
      if (next < 0) break;
      i = next + 2;
      continue;
    }
    if (!_isIdent(source.codeUnitAt(i)) ||
        (i > 0 && _isIdent(source.codeUnitAt(i - 1)))) {
      i++;
      continue;
    }
    var end = i;
    while (end < source.length && _isIdent(source.codeUnitAt(end))) {
      end++;
    }
    final name = source.substring(i, end);
    var next = end;
    while (next < source.length && _isSpace(source.codeUnitAt(next))) {
      next++;
    }
    if (next < source.length && source[next] == '(') {
      final close = _matchParen(source, next);
      if (close > next) out.add(_NamedCall(name, next, close));
    }
    i = end;
  }
  return out;
}

List<_Arg> _topLevelArgs(String source, int open, int close) {
  final args = <_Arg>[];
  var depth = 0;
  var start = open + 1;
  var i = start;
  final named = RegExp(r'^\s*(\w+)\s*:');
  void flush(int end) {
    final segment = source.substring(start, end);
    final match = named.firstMatch(segment);
    if (match != null) {
      args.add(
        _Arg(
          match.group(1)!,
          start + match.end,
          end,
        ),
      );
    } else if (segment.trim().isNotEmpty) {
      args.add(_Arg(_positional, start, end));
    }
    start = end + 1;
  }

  while (i < close) {
    final c = source[i];
    if (c == "'" || c == '"') {
      i = _skipString(source, i);
      continue;
    }
    if (c == '/' && i + 1 < close && source[i + 1] == '/') {
      final next = source.indexOf('\n', i);
      if (next < 0 || next > close) break;
      i = next;
      continue;
    }
    if (c == '/' && i + 1 < close && source[i + 1] == '*') {
      final next = source.indexOf('*/', i + 2);
      if (next < 0 || next > close) break;
      i = next + 2;
      continue;
    }
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') depth--;
    if (c == ',' && depth == 0) {
      flush(i);
    }
    i++;
  }
  if (start < close && source.substring(start, close).trim().isNotEmpty) {
    flush(close);
  }
  return args;
}

/// Every literal in a role-bearing expression, with adjacent string
/// concatenation merged. Conditional labels (`cond ? 'A' : 'B'`) yield both
/// branches, so a hidden branch cannot dodge the budget.
List<_Literal> _literalsIn(String source, int start, int end) {
  final out = <_Literal>[];
  var i = start;
  int? previousEnd;
  while (i < end) {
    if (source.startsWith('//', i)) {
      final next = source.indexOf('\n', i);
      if (next < 0 || next > end) break;
      i = next;
      continue;
    }
    if (source.startsWith('/*', i)) {
      final next = source.indexOf('*/', i + 2);
      if (next < 0 || next > end) break;
      i = next + 2;
      continue;
    }
    final c = source[i];
    if (c != "'" && c != '"') {
      i++;
      continue;
    }
    final stop = _skipString(source, i);
    final triple = source.startsWith(c * 3, i);
    final open = i + (triple ? 3 : 1);
    final close = stop - (triple ? 3 : 1);
    final text = close > open ? source.substring(open, close) : '';
    if (previousEnd != null &&
        out.isNotEmpty &&
        source.substring(previousEnd, i).trim().isEmpty) {
      final previous = out.removeLast();
      out.add(_Literal(previous.start, previous.text + text));
    } else {
      out.add(_Literal(i, text));
    }
    previousEnd = stop;
    i = stop;
  }
  return out;
}

class _Violation {
  const _Violation({
    required this.file,
    required this.line,
    required this.role,
    required this.words,
    required this.max,
    required this.text,
  });

  final String file;
  final int line;
  final String role;
  final int words;
  final int max;
  final String text;

  @override
  String toString() => '$file:$line $role $words/$max :: "$text"';
}
