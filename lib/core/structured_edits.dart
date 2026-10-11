/// Pure, I/O-free cores of the Claude Code `MultiEdit` and `NotebookEdit`
/// tools. The agent service handles paths, permissions, approval, diff cards,
/// the repo cache and Studio. These functions only turn old content into new
/// content, or throw a [StructuredEditException] and change nothing (atomic).
library;

import 'dart:convert';

/// An edit that cannot be applied. Nothing was written.
class StructuredEditException implements Exception {
  const StructuredEditException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One `MultiEdit` operation.
class TextEdit {
  const TextEdit({
    required this.oldString,
    required this.newString,
    this.replaceAll = false,
  });

  final String oldString;
  final String newString;
  final bool replaceAll;

  /// Parse the `edits` array of a MultiEdit call. Accepts the Claude Code
  /// keys (`old_string`/`new_string`/`replace_all`) and Ovid's fs_edit
  /// spellings (`old_str`/`new_str`).
  static List<TextEdit> parseList(Object? raw) {
    if (raw is! List || raw.isEmpty) {
      throw const StructuredEditException(
        'edits must be a non-empty array of {old_string, new_string}',
      );
    }
    return [
      for (final (i, e) in raw.indexed)
        if (e is Map)
          TextEdit(
            oldString: '${e['old_string'] ?? e['old_str'] ?? ''}',
            newString: '${e['new_string'] ?? e['new_str'] ?? ''}',
            replaceAll: e['replace_all'] == true,
          )
        else
          throw StructuredEditException('edit ${i + 1} is not an object'),
    ];
  }
}

int _count(String haystack, String needle) {
  if (needle.isEmpty) return 0;
  var n = 0;
  var i = haystack.indexOf(needle);
  while (i >= 0) {
    n++;
    i = haystack.indexOf(needle, i + needle.length);
  }
  return n;
}

/// Apply [edits] in order, each to the result of the previous one. All or
/// nothing: the first failing edit throws and [content] is never partly
/// edited. When [content] is null (the file does not exist), the first edit
/// must have an empty `old_string`; it creates the file with its
/// `new_string` (Claude Code's create-via-MultiEdit rule).
String applyMultiEdit(String? content, List<TextEdit> edits) {
  var text = content;
  for (final (i, e) in edits.indexed) {
    final n = i + 1;
    if (text == null) {
      if (i == 0 && e.oldString.isEmpty) {
        text = e.newString;
        continue;
      }
      throw const StructuredEditException(
        'file does not exist — to create it, make the first edit\'s '
        'old_string empty',
      );
    }
    if (e.oldString.isEmpty) {
      throw StructuredEditException(
        'edit $n: old_string must not be empty for an existing file',
      );
    }
    if (e.oldString == e.newString) {
      throw StructuredEditException(
        'edit $n: old_string and new_string are identical',
      );
    }
    final count = _count(text, e.oldString);
    if (count == 0) {
      throw StructuredEditException(
        'edit $n: old_string not found (after applying edits 1..${n - 1})',
      );
    }
    if (count > 1 && !e.replaceAll) {
      throw StructuredEditException(
        'edit $n: old_string matches $count times — add surrounding context '
        'to make it unique, or set replace_all: true',
      );
    }
    text = e.replaceAll
        ? text.replaceAll(e.oldString, e.newString)
        : text.replaceFirst(e.oldString, e.newString);
  }
  return text ?? '';
}

/// NotebookEdit `edit_mode`.
enum NotebookEditMode { replace, insert, delete }

NotebookEditMode parseNotebookEditMode(Object? raw) => switch (raw) {
  null || '' || 'replace' => NotebookEditMode.replace,
  'insert' => NotebookEditMode.insert,
  'delete' => NotebookEditMode.delete,
  _ => throw StructuredEditException(
    'edit_mode must be replace, insert or delete (got "$raw")',
  ),
};

/// Apply one Claude Code NotebookEdit to the `.ipynb` JSON [source].
///
/// * `replace` (default): overwrite the target cell's source. The cell's
///   metadata, id and outputs are preserved. Changing `cell_type` drops
///   outputs and `execution_count` when the cell becomes markdown, and adds
///   empty ones when it becomes code.
/// * `insert`: add a new cell AFTER the target. With no `cell_id` the cell
///   goes at the start. `cell_type` (`code` | `markdown`) is required.
/// * `delete`: remove the target cell.
///
/// [cellId] matches a cell's `id`. It may also be a 0-based index or
/// `cell-N`. Notebook metadata, nbformat and every other cell are kept
/// byte-for-byte in value. Returns the new JSON (1-space indent, the
/// nbformat convention) with a trailing newline.
String applyNotebookEdit(
  String source, {
  String? cellId,
  required String newSource,
  String? cellType,
  NotebookEditMode mode = NotebookEditMode.replace,
}) {
  Object? decoded;
  try {
    decoded = jsonDecode(source);
  } catch (_) {
    throw const StructuredEditException('not a valid .ipynb (invalid JSON)');
  }
  if (decoded is! Map || decoded['cells'] is! List) {
    throw const StructuredEditException('not a valid .ipynb (no cells array)');
  }
  final nb = Map<String, dynamic>.from(decoded);
  final cells = List<dynamic>.from(nb['cells'] as List);
  if (cellType != null && cellType != 'code' && cellType != 'markdown') {
    throw StructuredEditException(
      'cell_type must be code or markdown (got "$cellType")',
    );
  }

  int? indexOf(String? id) {
    if (id == null || id.isEmpty) return null;
    for (var i = 0; i < cells.length; i++) {
      final c = cells[i];
      if (c is Map && c['id'] == id) return i;
    }
    final m = RegExp(r'^(?:cell-)?(\d+)$').firstMatch(id);
    if (m != null) {
      final i = int.parse(m.group(1)!);
      if (i >= 0 && i < cells.length) return i;
    }
    throw StructuredEditException('cell_id "$id" not found in the notebook');
  }

  final target = indexOf(cellId);
  // nbformat stores source as a list of lines (each keeping its "\n").
  List<String> lines(String s) {
    if (s.isEmpty) return const [];
    final parts = s.split('\n');
    return [
      for (var i = 0; i < parts.length; i++)
        if (i < parts.length - 1)
          '${parts[i]}\n'
        else if (parts[i].isNotEmpty)
          parts[i],
    ];
  }

  final minor = (nb['nbformat_minor'] as num?)?.toInt() ?? 0;
  final major = (nb['nbformat'] as num?)?.toInt() ?? 4;
  final wantsIds = major > 4 || (major == 4 && minor >= 5);

  switch (mode) {
    case NotebookEditMode.delete:
      if (target == null) {
        throw const StructuredEditException('delete needs a cell_id');
      }
      cells.removeAt(target);
    case NotebookEditMode.insert:
      if (cellType == null) {
        throw const StructuredEditException(
          'insert needs cell_type (code or markdown)',
        );
      }
      final cell = <String, dynamic>{
        'cell_type': cellType,
        if (wantsIds) 'id': _newCellId(cells),
        'metadata': <String, dynamic>{},
        'source': lines(newSource),
        if (cellType == 'code') 'execution_count': null,
        if (cellType == 'code') 'outputs': <dynamic>[],
      };
      cells.insert(target == null ? 0 : target + 1, cell);
    case NotebookEditMode.replace:
      if (target == null) {
        throw const StructuredEditException('replace needs a cell_id');
      }
      final cell = Map<String, dynamic>.from(cells[target] as Map);
      cell['source'] = lines(newSource);
      if (cellType != null && cellType != cell['cell_type']) {
        cell['cell_type'] = cellType;
        if (cellType == 'markdown') {
          cell.remove('outputs');
          cell.remove('execution_count');
        } else {
          cell['outputs'] = <dynamic>[];
          cell['execution_count'] = null;
        }
      }
      cells[target] = cell;
  }
  nb['cells'] = cells;
  return '${const JsonEncoder.withIndent(' ').convert(nb)}\n';
}

String _newCellId(List<dynamic> cells) {
  final used = {
    for (final c in cells)
      if (c is Map && c['id'] is String) c['id'] as String,
  };
  var n = DateTime.now().microsecondsSinceEpoch;
  while (true) {
    final id = n.toRadixString(16).padLeft(8, '0');
    final short = id.substring(id.length - 8);
    if (!used.contains(short)) return short;
    n++;
  }
}
