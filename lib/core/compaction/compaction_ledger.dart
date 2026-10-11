import 'dart:collection';
import 'dart:convert';

import '../state.dart';

/// Lossless compaction: the DETERMINISTIC half of a checkpoint.
///
/// The ledger is built straight from the transcript (user messages and tool
/// cards), never from a model summary, so nothing in it can be hallucinated
/// away. It is CUMULATIVE: each compaction absorbs only the newly folded span
/// into the ledger carried forward from the previous compaction
/// (`ChatSession.compactionState`). Repeated compactions therefore never
/// summarise a summary. User instructions and the work log only grow.
///
/// See docs/compaction/LOSSLESS_COMPACTION.md.

/// One user message, stored verbatim (very large pastes keep head + tail
/// and a reference to the visible transcript, which always holds the
/// original).
class LedgerUserMessage {
  final int seq;
  final String text;
  final int fullLength;
  final List<String> attachments;

  const LedgerUserMessage({
    required this.seq,
    required this.text,
    required this.fullLength,
    this.attachments = const [],
  });

  bool get truncated => fullLength > text.length;

  Map<String, dynamic> toJson() => {
    's': seq,
    't': text,
    if (fullLength != text.length) 'n': fullLength,
    if (attachments.isNotEmpty) 'a': attachments,
  };

  factory LedgerUserMessage.fromJson(Map<String, dynamic> j) {
    final text = j['t'] as String? ?? '';
    return LedgerUserMessage(
      seq: (j['s'] as num?)?.toInt() ?? 0,
      text: text,
      fullLength: (j['n'] as num?)?.toInt() ?? text.length,
      attachments: [for (final a in (j['a'] as List? ?? const [])) '$a'],
    );
  }
}

/// Action categories. They decide what collapses first under a budget.
abstract final class ActionKind {
  static const write = 'write';
  static const delete = 'delete';
  static const shell = 'shell';
  static const read = 'read';
  static const subagent = 'subagent';
  static const mcp = 'mcp';
  static const vcs = 'vcs';
  static const reply = 'reply';
  static const other = 'other';
}

/// One thing the agent did, derived from a tool card (or a turn-ending reply).
class LedgerAction {
  final int seq;
  final String tool;
  final String kind;
  final String input;

  /// `ok` | `error` | `stopped` | `exit N`.
  final String outcome;
  final String? note;

  const LedgerAction({
    required this.seq,
    required this.tool,
    required this.kind,
    required this.input,
    required this.outcome,
    this.note,
  });

  bool get failed =>
      outcome == 'error' ||
      (outcome.startsWith('exit ') && outcome != 'exit 0');

  Map<String, dynamic> toJson() => {
    's': seq,
    'tool': tool,
    'k': kind,
    'in': input,
    'o': outcome,
    if (note != null) 'note': note,
  };

  factory LedgerAction.fromJson(Map<String, dynamic> j) => LedgerAction(
    seq: (j['s'] as num?)?.toInt() ?? 0,
    tool: j['tool'] as String? ?? 'tool',
    kind: j['k'] as String? ?? ActionKind.other,
    input: j['in'] as String? ?? '',
    outcome: j['o'] as String? ?? 'ok',
    note: j['note'] as String?,
  );
}

/// An error the agent hit and, once seen, the action that resolved it.
class LedgerError {
  final int actionSeq;
  final String tool;
  final String input;
  final String error;
  String? fix;

  LedgerError({
    required this.actionSeq,
    required this.tool,
    required this.input,
    required this.error,
    this.fix,
  });

  Map<String, dynamic> toJson() => {
    's': actionSeq,
    'tool': tool,
    'in': input,
    'e': error,
    if (fix != null) 'fix': fix,
  };

  factory LedgerError.fromJson(Map<String, dynamic> j) => LedgerError(
    actionSeq: (j['s'] as num?)?.toInt() ?? 0,
    tool: j['tool'] as String? ?? 'tool',
    input: j['in'] as String? ?? '',
    error: j['e'] as String? ?? '',
    fix: j['fix'] as String?,
  );
}

class CompactionLedger {
  /// Stored cap for one user message. Beyond it, head and tail are kept and
  /// the middle becomes an explicit reference to the visible transcript.
  static const storedUserChars = 16000;

  /// Stored cap for the action list. Beyond it, the oldest read-only and
  /// reply entries become per-tool counts.
  static const storedActions = 3000;

  int compactions = 0;
  int foldedMessages = 0;
  int userCount = 0;
  int actionCount = 0;
  String? goal;
  final List<LedgerUserMessage> userMessages = [];
  final List<LedgerAction> actions = [];

  /// path → operations (created / edited / deleted / read), first-touch order.
  final LinkedHashMap<String, LinkedHashSet<String>> files = LinkedHashMap();
  final List<LedgerError> errors = [];

  /// Actions folded out of [actions] under the storage cap: tool → count.
  final Map<String, int> collapsed = {};

  /// Every `/compact <focus>` text, in order.
  final List<String> focus = [];

  /// The latest model-written narrative (decisions / current work / next
  /// steps / key context). This is the ONLY model-authored part.
  String narrative = '';

  CompactionLedger();

  // ── absorb ────────────────────────────────────────────────────────────

  /// Fold [span] (the newly compacted messages, in order) into the ledger.
  void absorb(List<Message> span) {
    for (var i = 0; i < span.length; i++) {
      final m = span[i];
      if (m.kind == MsgKind.compact) continue;
      if (m.kind == MsgKind.tool) {
        _absorbTool(m);
        continue;
      }
      if (m.role == 'user') {
        _absorbUser(m);
        continue;
      }
      // A turn-ending assistant reply: its first line is a deterministic
      // anchor for "what the agent told the user".
      if (m.role == 'assistant' && m.kind == MsgKind.text) {
        final next = i + 1 < span.length ? span[i + 1] : null;
        final endsTurn = next == null || next.role == 'user';
        final text = m.content.trim();
        if (endsTurn && text.isNotEmpty) {
          _addAction(
            tool: 'reply',
            kind: ActionKind.reply,
            input: _firstLine(text, 200),
            outcome: 'ok',
          );
        }
      }
    }
    _enforceActionCap();
  }

  void _absorbUser(Message m) {
    final raw = m.content.trim();
    final atts = [
      for (final a in m.attachments)
        a.path == null || a.path!.isEmpty ? a.name : '${a.name} (${a.path})',
    ];
    if (raw.isEmpty && atts.isEmpty) return;
    userCount++;
    final stored = raw.length <= storedUserChars
        ? raw
        : '${raw.substring(0, storedUserChars - 1200)}\n'
              '…[${raw.length - storedUserChars + 200} more chars of pasted '
              'content omitted here; the full original is user message '
              '#$userCount in the visible transcript]…\n'
              '${raw.substring(raw.length - 1000)}';
    userMessages.add(
      LedgerUserMessage(
        seq: userCount,
        text: stored,
        fullLength: raw.length,
        attachments: atts,
      ),
    );
    if (goal == null && raw.isNotEmpty) goal = stored;
  }

  void _absorbTool(Message m) {
    final tool = m.toolName ?? 'tool';
    final args = _decodeInput(m.toolInput);
    final detail = (m.toolDetail ?? '').trim();
    final input = _displayInput(tool, args, m);
    final exit = _exitCode(detail);
    final outcome = exit != null
        ? 'exit $exit'
        : (m.toolState == 'running' ? 'ok' : m.toolState);
    final kind = _kindFor(tool);
    String? note;
    final failed = outcome == 'error' || (exit != null && exit != 0);
    if (failed) {
      note = _errorLine(detail);
    } else if (kind == ActionKind.subagent || kind == ActionKind.mcp) {
      final head = _firstLine(detail, 200);
      if (head.isNotEmpty) note = head;
    }
    final action = _addAction(
      tool: tool,
      kind: kind,
      input: input,
      outcome: outcome,
      note: note,
    );
    if (action.failed) {
      errors.add(
        LedgerError(
          actionSeq: action.seq,
          tool: tool,
          input: input,
          error: note ?? '(failed)',
        ),
      );
    } else if (outcome == 'ok' || outcome == 'exit 0') {
      // The first later success of the same tool closes its open errors.
      for (final e in errors) {
        if (e.fix == null && e.tool == tool) {
          e.fix = '#${action.seq} $tool ${_clip(input, 160)} → $outcome';
        }
      }
    }
    _recordFiles(tool, args, input, detail, failed: action.failed);
  }

  LedgerAction _addAction({
    required String tool,
    required String kind,
    required String input,
    required String outcome,
    String? note,
  }) {
    actionCount++;
    final a = LedgerAction(
      seq: actionCount,
      tool: tool,
      kind: kind,
      input: input,
      outcome: outcome,
      note: note,
    );
    actions.add(a);
    return a;
  }

  void _touch(String path, String op) {
    final p = path.trim();
    if (p.isEmpty || p == '/dev/null' || p.startsWith('&')) return;
    final ops = files.putIfAbsent(p, LinkedHashSet<String>.new);
    ops.add(op);
  }

  void _recordFiles(
    String tool,
    Map<String, dynamic> args,
    String input,
    String detail, {
    required bool failed,
  }) {
    final path = (args['path'] ?? args['file'])?.toString() ?? '';
    switch (tool) {
      case 'file_write':
        if (failed) return;
        final p = path.isNotEmpty ? path : _diffPath(detail) ?? input;
        _touch(p, _diffIsCreate(detail) ? 'created' : 'edited');
      case 'fs_edit':
        if (failed) return;
        final p = path.isNotEmpty ? path : _diffPath(detail) ?? '';
        final cmd = args['command']?.toString() ?? '';
        if (cmd == 'view') {
          _touch(p, 'read');
        } else if (cmd == 'create' || (cmd.isEmpty && _diffIsCreate(detail))) {
          _touch(p, 'created');
        } else {
          _touch(p, 'edited');
        }
      case 'file_read' || 'read_image':
        _touch(path.isNotEmpty ? path : input, 'read');
      case 'run_shell' || 'job_start':
        if (failed) return;
        final cmd = args['command']?.toString() ?? input;
        for (final op in shellFileOps(cmd)) {
          _touch(op.$1, op.$2);
        }
      default:
        if (tool.startsWith('fs_') && path.isNotEmpty) _touch(path, 'read');
    }
  }

  void _enforceActionCap() {
    if (actions.length <= storedActions) return;
    // Collapse the oldest low-value entries first, then anything that is
    // not an error, a write, or a delete.
    bool lowValue(LedgerAction a) =>
        a.kind == ActionKind.read || a.kind == ActionKind.reply;
    bool keep(LedgerAction a) =>
        a.failed ||
        a.kind == ActionKind.write ||
        a.kind == ActionKind.delete ||
        a.kind == ActionKind.subagent ||
        a.kind == ActionKind.mcp ||
        a.kind == ActionKind.vcs;
    for (final pass in [lowValue, (LedgerAction a) => !keep(a)]) {
      var i = 0;
      while (actions.length > storedActions && i < actions.length) {
        if (pass(actions[i])) {
          final a = actions.removeAt(i);
          collapsed[a.tool] = (collapsed[a.tool] ?? 0) + 1;
        } else {
          i++;
        }
      }
    }
  }

  // ── helpers (pure) ────────────────────────────────────────────────────

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max - 1)}…';

  static String _firstLine(String s, int max) {
    final line = s
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    return _clip(line, max);
  }

  static Map<String, dynamic> _decodeInput(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final d = jsonDecode(raw);
      if (d is Map) return d.cast<String, dynamic>();
    } on FormatException {
      // Tool input that is not JSON carries no structured fields.
    }
    return const {};
  }

  static String _displayInput(
    String tool,
    Map<String, dynamic> args,
    Message m,
  ) {
    if (args.isNotEmpty) {
      final parts = <String>[];
      for (final e in args.entries) {
        final v = e.value is List ? (e.value as List).join(' | ') : e.value;
        parts.add(
          args.length == 1 && (e.key == 'command' || e.key == 'path')
              ? '$v'
              : '${e.key}=$v',
        );
      }
      return _clip(parts.join(' · '), 400);
    }
    // Legacy card without recorded input: the diff header or the summary.
    final fromDiff = _diffPath(m.toolDetail ?? '');
    if (fromDiff != null) return fromDiff;
    return _clip((m.toolSummary ?? m.content).trim(), 400);
  }

  static int? _exitCode(String detail) {
    final ms = RegExp(r'exit(?:ed with)? code (-?\d+)').allMatches(detail);
    if (ms.isEmpty) return null;
    return int.tryParse(ms.last.group(1)!);
  }

  static String _errorLine(String detail) {
    final lines = detail
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return '(failed)';
    final hit = lines.firstWhere(
      (l) => RegExp(
        r'error|exception|failed|denied|not found|cannot|no such|traceback',
        caseSensitive: false,
      ).hasMatch(l),
      orElse: () => lines.last,
    );
    return _clip(hit, 240);
  }

  static String? _diffPath(String detail) {
    final first = detail.split('\n').first.trim();
    if (first.startsWith('diff ') && first.length > 5) {
      return first.substring(5).trim();
    }
    return null;
  }

  /// `buildEditDiff` renders a whole-file create as only `+` lines.
  static bool _diffIsCreate(String detail) {
    final lines = detail.split('\n');
    if (lines.length < 2 || !lines.first.startsWith('diff ')) return false;
    final body = lines.skip(1).where((l) => l.isNotEmpty);
    return body.isNotEmpty &&
        body.every((l) => l.startsWith('+') || l.startsWith('…'));
  }

  static String _kindFor(String tool) {
    if (tool.startsWith('mcp_')) return ActionKind.mcp;
    return switch (tool) {
      'file_write' || 'fs_edit' => ActionKind.write,
      'run_shell' || 'job_start' || 'run_code' => ActionKind.shell,
      'file_read' ||
      'fs_glob' ||
      'fs_grep' ||
      'read_image' ||
      'git_status' ||
      'git_diff' ||
      'git_log' ||
      'web_search' ||
      'fetch_url' ||
      'memory_search' ||
      'session_search' ||
      'session_read' ||
      'job_output' ||
      'job_list' => ActionKind.read,
      'dispatch_agent' || 'workflow' || 'ralph' => ActionKind.subagent,
      'commit' || 'git_push' || 'git_pull' || 'git_clone' => ActionKind.vcs,
      _ when tool.startsWith('browser_') => ActionKind.read,
      _ => ActionKind.other,
    };
  }

  /// File operations implied by a shell command (best effort): `rm` deletes,
  /// `mv a b` deletes a and creates b, `cp`/`touch`/`mkdir` create, and
  /// `> file` writes.
  static List<(String, String)> shellFileOps(String cmd) {
    final out = <(String, String)>[];
    for (final seg in cmd.split(RegExp(r'&&|\|\||;|\n'))) {
      final words = seg
          .trim()
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .toList();
      if (words.isEmpty) continue;
      final verb = words.first;
      final operands = words
          .skip(1)
          .where((w) => !w.startsWith('-') && !w.contains('>'))
          .map((w) => w.replaceAll(RegExp(r'''^['"]|['"]$'''), ''))
          .toList();
      switch (verb) {
        case 'rm' || 'rmdir' || 'unlink':
          for (final p in operands) {
            out.add((p, 'deleted'));
          }
        case 'mv' when operands.length >= 2:
          for (final p in operands.take(operands.length - 1)) {
            out.add((p, 'deleted'));
          }
          out.add((operands.last, 'created'));
        case 'cp' when operands.length >= 2:
          out.add((operands.last, 'created'));
        case 'touch' || 'mkdir':
          for (final p in operands) {
            out.add((p, 'created'));
          }
      }
      for (final r in RegExp(
        r'(?<![0-9&])>>?\s*([^\s;&|<>]+)',
      ).allMatches(seg)) {
        final p = r.group(1)!;
        if (p != '/dev/null' && !p.startsWith('&')) out.add((p, 'edited'));
      }
    }
    return out;
  }

  /// The tool-input record stored on a tool card at dispatch
  /// (`Message.toolInput`): a JSON object of the SMALL identifying args only
  /// (paths, commands, URLs, queries, prompts), each clipped. File bodies are
  /// recorded as sizes, never as content.
  static String toolInputRecord(String tool, Map<String, dynamic> args) {
    const keys = [
      'path',
      'file',
      'command',
      'cmd',
      'url',
      'query',
      'queries',
      'pattern',
      'prompt',
      'message',
      'selector',
      'old_path',
      'new_path',
      'from',
      'to',
      'server',
      'agent',
      'subagent_type',
      'objective',
      'mode',
      'cwd',
      'repo',
      'branch',
      'name',
    ];
    final out = <String, dynamic>{};
    for (final k in keys) {
      final v = args[k];
      if (v == null) continue;
      if (v is List) {
        out[k] = [for (final x in v.take(8)) _clip('$x', 200)];
      } else if (v is String || v is num || v is bool) {
        out[k] = v is String ? _clip(v, 300) : v;
      }
    }
    for (final k in const ['content', 'file_text', 'new_str', 'code']) {
      final v = args[k];
      if (v is String) out['${k}_chars'] = v.length;
    }
    return jsonEncode(out);
  }

  // ── persistence ───────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
    'v': 1,
    'compactions': compactions,
    'folded': foldedMessages,
    'userCount': userCount,
    'actionCount': actionCount,
    if (goal != null) 'goal': goal,
    'users': [for (final u in userMessages) u.toJson()],
    'actions': [for (final a in actions) a.toJson()],
    'files': {for (final e in files.entries) e.key: e.value.toList()},
    'errors': [for (final e in errors) e.toJson()],
    if (collapsed.isNotEmpty) 'collapsed': collapsed,
    if (focus.isNotEmpty) 'focus': focus,
    if (narrative.isNotEmpty) 'narrative': narrative,
  };

  factory CompactionLedger.fromJson(Map<String, dynamic> j) {
    final l = CompactionLedger()
      ..compactions = (j['compactions'] as num?)?.toInt() ?? 0
      ..foldedMessages = (j['folded'] as num?)?.toInt() ?? 0
      ..userCount = (j['userCount'] as num?)?.toInt() ?? 0
      ..actionCount = (j['actionCount'] as num?)?.toInt() ?? 0
      ..goal = j['goal'] as String?
      ..narrative = j['narrative'] as String? ?? '';
    for (final u in (j['users'] as List? ?? const [])) {
      if (u is Map) l.userMessages.add(LedgerUserMessage.fromJson(u.cast()));
    }
    for (final a in (j['actions'] as List? ?? const [])) {
      if (a is Map) l.actions.add(LedgerAction.fromJson(a.cast()));
    }
    final files = j['files'];
    if (files is Map) {
      for (final e in files.entries) {
        l.files['${e.key}'] = LinkedHashSet.of([
          for (final op in (e.value as List? ?? const [])) '$op',
        ]);
      }
    }
    for (final e in (j['errors'] as List? ?? const [])) {
      if (e is Map) l.errors.add(LedgerError.fromJson(e.cast()));
    }
    final collapsed = j['collapsed'];
    if (collapsed is Map) {
      for (final e in collapsed.entries) {
        l.collapsed['${e.key}'] = (e.value as num?)?.toInt() ?? 0;
      }
    }
    l.focus.addAll([for (final f in (j['focus'] as List? ?? const [])) '$f']);
    return l;
  }

  /// The ledger carried forward on [s], or null for a session that was never
  /// compacted with a ledger (fresh, or compacted before this format).
  static CompactionLedger? of(ChatSession s) {
    final raw = s.compactionState;
    if (raw == null) return null;
    try {
      return CompactionLedger.fromJson(raw);
    } catch (_) {
      return null;
    }
  }
}
