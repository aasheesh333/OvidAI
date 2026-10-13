import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Lightweight, dependency-free syntax highlighting for chat code blocks,
/// tool output and the artifact code viewer.
///
/// It is a single-pass regex tokenizer (comments, strings, numbers, keywords,
/// types, annotations), not a parser: good enough to make code scannable the
/// way the Claude app does, cheap enough to run inside a chat row. Inputs
/// longer than [maxHighlightChars] render as plain text so a huge paste never
/// stalls a frame.
const int maxHighlightChars = 16000;

const _keywords = {
  // C-family / JS / TS / Dart / Java / Kotlin / Swift / Go / Rust
  'abstract', 'as', 'async', 'await', 'break', 'case', 'catch', 'class',
  'const', 'continue', 'default', 'defer', 'do', 'else', 'enum', 'export',
  'extends', 'extension', 'false', 'final', 'finally', 'fn', 'for', 'fun',
  'func', 'function', 'go', 'if', 'impl', 'implements', 'import', 'in',
  'interface', 'is', 'late', 'let', 'match', 'mixin', 'mod', 'mut', 'new',
  'null', 'nil', 'none', 'override', 'package', 'private', 'protected',
  'pub', 'public', 'required', 'return', 'sealed', 'static', 'struct',
  'super', 'switch', 'this', 'throw', 'throws', 'trait', 'true', 'try',
  'type', 'typeof', 'use', 'val', 'var', 'void', 'when', 'where', 'while',
  'with', 'yield',
  // Python / Ruby / shell
  'and', 'def', 'del', 'elif', 'end', 'except', 'from', 'global', 'lambda',
  'not', 'or', 'pass', 'raise', 'self', 'None', 'True', 'False', 'then',
  'fi', 'done', 'esac', 'echo', 'local', 'unless', 'until', 'module',
  'require', 'begin', 'rescue', 'ensure',
  // SQL (upper-case forms are matched case-insensitively below)
  'select', 'insert', 'update', 'delete', 'into', 'values', 'join', 'left',
  'right', 'inner', 'outer', 'on', 'group', 'order', 'by', 'limit', 'create',
  'table', 'drop', 'alter', 'primary', 'key', 'references', 'distinct',
  'having', 'union', 'set',
};

const _hashCommentLangs = {
  'py',
  'python',
  'sh',
  'bash',
  'zsh',
  'shell',
  'console',
  'rb',
  'ruby',
  'yaml',
  'yml',
  'toml',
  'r',
  'perl',
  'pl',
  'dockerfile',
  'makefile',
  'ini',
  'conf',
  'env',
  'gitignore',
};

const _sqlLangs = {'sql', 'mysql', 'postgres', 'postgresql', 'sqlite'};

final _tokenizer = RegExp(
  r'(?<block>/\*[\s\S]*?\*/|<!--[\s\S]*?-->)'
  r'|(?<line>//[^\n]*|#[^\n]*|--[^\n]*)'
  r'|(?<str>"""[\s\S]*?"""'
  "|'''[\\s\\S]*?'''"
  r'|"(?:\\.|[^"\\\n])*"'
  r"|'(?:\\.|[^'\\\n])*'"
  r'|`(?:\\.|[^`\\])*`)'
  r'|(?<num>\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b)'
  r'|(?<ann>@[A-Za-z_]\w*)'
  r'|(?<word>[A-Za-z_]\w*)',
);

/// Palette for highlighted spans, derived from the active Aether palette so
/// light and dark themes both stay readable.
@immutable
class CodePalette {
  const CodePalette({
    required this.keyword,
    required this.string,
    required this.comment,
    required this.number,
    required this.type,
    required this.annotation,
  });

  factory CodePalette.of() => CodePalette(
    keyword: Aether.accent,
    string: Aether.success,
    comment: Aether.textFaint,
    number: Aether.warn,
    type: Aether.accent.withValues(alpha: 0.80),
    annotation: Aether.warn,
  );

  final Color keyword;
  final Color string;
  final Color comment;
  final Color number;
  final Color type;
  final Color annotation;
}

/// Normalises a fence label / file extension (`Python`, `.py`, `tsx`).
String normalizeCodeLang(String lang) {
  var l = lang.trim().toLowerCase();
  if (l.startsWith('.')) l = l.substring(1);
  return l;
}

/// Highlighted spans for [code]. Falls back to a single plain span for
/// unknown/plain languages and for oversized input.
TextSpan highlightCode(
  String code, {
  required String lang,
  required TextStyle style,
  CodePalette? palette,
}) {
  final l = normalizeCodeLang(lang);
  if (code.length > maxHighlightChars ||
      const {
        '',
        'text',
        'txt',
        'plain',
        'plaintext',
        'output',
        'log',
      }.contains(l)) {
    return TextSpan(text: code, style: style);
  }
  final p = palette ?? CodePalette.of();
  final hashComments = _hashCommentLangs.contains(l);
  final sql = _sqlLangs.contains(l);
  final spans = <InlineSpan>[];
  var last = 0;
  for (final match in _tokenizer.allMatches(code)) {
    final text = match.group(0)!;
    TextStyle? tokenStyle;
    if (match.namedGroup('block') != null) {
      tokenStyle = TextStyle(color: p.comment, fontStyle: FontStyle.italic);
    } else if (match.namedGroup('line') != null) {
      final isHash = text.startsWith('#');
      final isDash = text.startsWith('--');
      // `#` is a comment only in hash-comment languages (it is a CSS id /
      // C preprocessor elsewhere); `--` only in SQL / Lua.
      if ((isHash && !hashComments) ||
          (text.startsWith('//') && hashComments) ||
          (isDash && !(sql || l == 'lua' || l == 'hs'))) {
        // Not a comment in this language: leave the run plain.
        continue;
      }
      tokenStyle = TextStyle(color: p.comment, fontStyle: FontStyle.italic);
    } else if (match.namedGroup('str') != null) {
      tokenStyle = TextStyle(color: p.string);
    } else if (match.namedGroup('num') != null) {
      tokenStyle = TextStyle(color: p.number);
    } else if (match.namedGroup('ann') != null) {
      tokenStyle = TextStyle(color: p.annotation);
    } else if (match.namedGroup('word') != null) {
      final isKeyword =
          _keywords.contains(text) ||
          (sql && _keywords.contains(text.toLowerCase()));
      if (isKeyword) {
        tokenStyle = TextStyle(color: p.keyword, fontWeight: FontWeight.w600);
      } else if (text.length > 1 &&
          text.codeUnitAt(0) >= 0x41 &&
          text.codeUnitAt(0) <= 0x5A &&
          text.contains(RegExp('[a-z]'))) {
        tokenStyle = TextStyle(color: p.type);
      } else {
        continue;
      }
    }
    if (match.start > last) {
      spans.add(TextSpan(text: code.substring(last, match.start)));
    }
    spans.add(TextSpan(text: text, style: tokenStyle));
    last = match.end;
  }
  if (last < code.length) spans.add(TextSpan(text: code.substring(last)));
  return TextSpan(style: style, children: spans);
}
