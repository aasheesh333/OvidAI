import '../state.dart';
import 'compaction_ledger.dart';
import 'compaction_policy.dart';

/// Live session state snapshotted into the checkpoint's "Current state"
/// section. The same state is ALSO re-attached live on every request
/// (volatile block / system prompt). The snapshot records what was true
/// at the cut.
class CheckpointState {
  final List<Map<String, String>> todos;
  final Map<String, dynamic>? goal;
  final bool planMode;
  final String? workingFolder;
  final int retainedMessages;

  const CheckpointState({
    this.todos = const [],
    this.goal,
    this.planMode = false,
    this.workingFolder,
    this.retainedMessages = 0,
  });

  factory CheckpointState.of(ChatSession s, {int retainedMessages = 0}) =>
      CheckpointState(
        todos: List.of(s.todos),
        goal: s.goal,
        planMode: s.planMode,
        workingFolder: s.workspaceFolder,
        retainedMessages: retainedMessages,
      );
}

/// A rendered checkpoint and what it preserved (for the compaction row).
class Checkpoint {
  final String text;
  final int verbatimUsers;
  final int digestedUsers;
  final int files;
  final int actions;
  final bool narrativeAvailable;

  const Checkpoint({
    required this.text,
    required this.verbatimUsers,
    required this.digestedUsers,
    required this.files,
    required this.actions,
    required this.narrativeAvailable,
  });

  /// One line for the compaction row's collapsed state.
  String get preservedLine =>
      'kept ${verbatimUsers + digestedUsers} user message'
      '${verbatimUsers + digestedUsers == 1 ? '' : 's'}'
      '${digestedUsers > 0 ? ' ($digestedUsers digested)' : ''} · '
      '$files file${files == 1 ? '' : 's'} · '
      '$actions action${actions == 1 ? '' : 's'}'
      '${narrativeAvailable ? '' : ' · no model summary'}';
}

/// Builds, merges and renders lossless checkpoints. Pure: no I/O and no
/// provider calls. AgentService owns the model call and the state writes.
abstract final class CompactionEngine {
  /// Directive / correction cues. A sentence carrying one is an instruction
  /// and is NEVER shortened by the digest.
  static final _cue = RegExp(
    r"\b(must|never|always|don'?t|do not|doesn'?t|only|should|shouldn'?t|"
    r"prefer|instead|actually|wrong|incorrect|avoid|make sure|ensure|"
    r"remember|no longer|stop|keep|use|not|need|required?|important|"
    r"constraint|rule|please|without|except|correction|rather)\b",
    caseSensitive: false,
  );
  static final _url = RegExp(r'https?://[^\s)>\]]+');
  static final _path = RegExp(
    r'(?<![\w/])(?:~|\.{1,2})?/?(?:[\w.\-]+/)+[\w.\-]+\.\w{1,8}\b'
    r'|(?<![\w/.])[\w\-]+\.(?:dart|py|js|ts|tsx|jsx|json|ya?ml|md|txt|sh|'
    r'kt|java|swift|go|rs|c|cc|cpp|h|html|css|toml|lock|gradle|xml|csv|sql)\b',
  );

  /// The ledger for a compaction of `[from, cutoff)` on [s]. The previous
  /// ledger is carried forward and only the new span is absorbed. A session
  /// without a ledger (never compacted, or compacted by the old LLM-only
  /// path) absorbs its WHOLE retained prefix `[0, cutoff)`, and its legacy
  /// summary becomes the prior narrative.
  static CompactionLedger ledgerFor(ChatSession s, int from, int cutoff) {
    final prior = CompactionLedger.of(s);
    final end = cutoff.clamp(0, s.messages.length);
    if (prior != null) {
      prior.absorb(s.messages.sublist(from.clamp(0, end), end));
      return prior;
    }
    final l = CompactionLedger()..absorb(s.messages.sublist(0, end));
    final legacy = s.compactedSummary;
    if (legacy != null && legacy.trim().isNotEmpty) l.narrative = legacy;
    return l;
  }

  /// The narrative the next summariser call should merge into: the previous
  /// MODEL narrative only, never the rendered checkpoint, so deterministic
  /// sections are never re-summarised.
  static String priorNarrative(ChatSession s) =>
      CompactionLedger.of(s)?.narrative ?? s.compactedSummary ?? '';

  /// Finish [l] for this compaction and render it.
  static Checkpoint finalize(
    CompactionLedger l, {
    required CheckpointState state,
    required int windowTokens,
    required int folded,
    String? narrative,
    String? focus,
  }) {
    l.compactions++;
    l.foldedMessages += folded;
    final f = focus?.trim() ?? '';
    if (f.isNotEmpty) l.focus.add(f);
    final fresh = narrative?.trim() ?? '';
    if (fresh.isNotEmpty) l.narrative = fresh;
    return render(
      l,
      state: state,
      budgetTokens: CompactionPolicy.checkpointBudgetTokens(windowTokens),
      currentFocus: f,
      narrativeAvailable: fresh.isNotEmpty,
    );
  }

  // ── summariser prompt (narrative only) ────────────────────────────────

  static const narrativeSections = [
    '## Decisions',
    '## Current Work',
    '## Next Steps',
    '## Key Context',
  ];

  static String summarizerSystemPrompt({bool strict = false}) =>
      'You are the compaction engine for an AI coding agent. Another part of '
      'the system ALREADY preserves, deterministically and verbatim: every '
      'user message, the original goal, every file touched, every command '
      'and tool call with its outcome, every error, and the todo list. '
      'Do NOT restate those lists. Write only the NARRATIVE another model '
      'needs to resume the work.\n'
      '\n'
      'Output EXACTLY these Markdown sections, in order, as terse bullets. '
      'Write "(none)" for an empty section:\n'
      '\n'
      '## Decisions\n'
      '- [decision: why it was made, including approaches rejected]\n'
      '\n'
      '## Current Work\n'
      '- [precisely what was in progress at this point]\n'
      '\n'
      '## Next Steps\n'
      '- [the next actions, in line with the most recent user request; '
      'open questions for the user]\n'
      '\n'
      '## Key Context\n'
      '- [technical concepts, conventions, root causes found, data needed '
      'to continue that is not a raw list]\n'
      '\n'
      'Rules:\n'
      '- Preserve exact file paths, commands, identifiers, error strings and '
      'numbers.\n'
      '- If the user corrected the agent, record the corrected understanding.\n'
      '- If a PRIOR NARRATIVE is given, MERGE it: keep still-true decisions '
      'and context, update Current Work and Next Steps, drop only what is '
      'clearly superseded. Never shorten it into vagueness.\n'
      '- If a FOCUS is given by the user, prioritise it.\n'
      '- Do not mention summarisation or compaction. Do not call tools.'
      '${strict ? '\n\nSTRICTNESS: the previous attempt was longer than its source — halve the length.' : ''}';

  static String summarizerUserPrompt({
    required String replay,
    required String priorNarrative,
    required CompactionLedger ledger,
    String? focus,
  }) {
    final b = StringBuffer();
    final f = focus?.trim() ?? '';
    if (f.isNotEmpty) b.writeln('FOCUS (from the user): $f\n');
    if (priorNarrative.trim().isNotEmpty) {
      b
        ..writeln('PRIOR NARRATIVE (merge into it):')
        ..writeln(priorNarrative.trim())
        ..writeln();
    }
    // A short deterministic reference so the narrative stays grounded.
    if (ledger.goal != null) {
      b.writeln('Original goal: ${_clip(ledger.goal!, 600)}');
    }
    if (ledger.files.isNotEmpty) {
      b.writeln(
        'Files touched: ${ledger.files.keys.take(60).join(', ')}'
        '${ledger.files.length > 60 ? ' …' : ''}',
      );
    }
    b
      ..writeln()
      ..writeln('Conversation span to condense:')
      ..writeln()
      ..write(replay);
    return b.toString();
  }

  // ── rendering ─────────────────────────────────────────────────────────

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max - 1)}…';

  static String _indent(String s) => s.replaceAll('\n', '\n    ');

  static Map<String, String> _splitNarrative(String narrative) {
    final out = <String, String>{};
    String? head;
    final buf = StringBuffer();
    void flush() {
      final body = buf.toString().trim();
      if (body.isNotEmpty || head != null) {
        out[head ?? ''] = [
          if (out[head ?? ''] != null) out[head ?? '']!,
          body,
        ].where((x) => x.isNotEmpty).join('\n');
      }
      buf.clear();
    }

    for (final line in narrative.split('\n')) {
      final m = RegExp(r'^#{1,3}\s+(.+)$').firstMatch(line.trim());
      if (m != null) {
        flush();
        head = m.group(1)!.trim();
      } else {
        buf.writeln(line);
      }
    }
    flush();
    return out;
  }

  /// Faithful digest of an older user message: first sentence, every
  /// directive/correction sentence VERBATIM, fact-like sentences (numbers,
  /// key: value), referenced paths and URLs, and pasted code as a reference.
  static String digest(String text) {
    if (text.length <= 160) return text;
    final sentences = text
        .split(RegExp(r'(?<=[.!?])\s+|\n+'))
        .map((x) => x.trim())
        .where((x) => x.isNotEmpty && !x.startsWith('```'))
        .toList();
    final kept = <String>[];
    if (sentences.isNotEmpty) kept.add(_clip(sentences.first, 240));
    for (final x in sentences.skip(1)) {
      if (kept.contains(x)) continue;
      if (_cue.hasMatch(x)) {
        kept.add(_clip(x, 600));
      } else if (RegExp(r'\d|\w[:=]\s*\S').hasMatch(x) && x.length <= 200) {
        kept.add(x);
      }
    }
    final refs = <String>{
      ..._url.allMatches(text).map((m) => m.group(0)!),
      ..._path.allMatches(text).map((m) => m.group(0)!),
    };
    final fences = RegExp('```').allMatches(text).length ~/ 2;
    return [
      kept.join(' '),
      if (fences > 0) '[pasted $fences code block${fences == 1 ? '' : 's'}]',
      if (refs.isNotEmpty) 'refs: ${refs.take(20).join(', ')}',
    ].join(' · ');
  }

  static Checkpoint render(
    CompactionLedger l, {
    required CheckpointState state,
    required int budgetTokens,
    String currentFocus = '',
    bool narrativeAvailable = true,
  }) {
    final budget = budgetTokens * 4;
    final b = StringBuffer()
      ..writeln('# Session checkpoint')
      ..writeln(
        'Compaction #${l.compactions} · ${l.foldedMessages} earlier '
        'message${l.foldedMessages == 1 ? '' : 's'} folded (the originals '
        'remain in the user\'s visible transcript). Goal, user instructions, '
        'files, actions, errors and todos below were derived directly from '
        'the transcript and are authoritative; Decisions / Current work / '
        'Next steps / Context are the model\'s narrative.',
      )
      ..writeln();

    // Goal.
    b
      ..writeln('## Goal (original request, verbatim)')
      ..writeln(l.goal ?? '(none)')
      ..writeln();

    // User instructions & constraints.
    final users = l.userMessages.where((u) => u.text != l.goal || u.seq != 1);
    final userList = users.toList();
    final userBudget = (budget * 0.45).floor();
    final total = userList.fold<int>(0, (a, u) => a + u.text.length + 12);
    final verbatim = <int>{};
    if (total <= userBudget) {
      verbatim.addAll(userList.map((u) => u.seq));
    } else {
      var used = 0;
      for (var i = userList.length - 1; i >= 0; i--) {
        final u = userList[i];
        final recent = userList.length - i <= 3;
        if (recent || used + u.text.length <= userBudget * 0.6) {
          verbatim.add(u.seq);
          used += u.text.length;
        } else {
          break;
        }
      }
    }
    final farOver = total > userBudget * 2;
    var digested = 0;
    b.writeln('## User instructions & constraints (verbatim, chronological)');
    b.writeln(
      '(numbered in order; "digest" rows keep every instruction sentence '
      'verbatim — their full text stays in the visible transcript)',
    );
    if (userList.isEmpty) b.writeln('(no further user messages)');
    for (final u in userList) {
      final atts = u.attachments.isEmpty
          ? ''
          : '\n    [attached: ${u.attachments.join(', ')}]';
      // Short messages stay verbatim unless the section is far over budget;
      // even then the digest keeps every directive sentence verbatim.
      final keep =
          verbatim.contains(u.seq) || (u.text.length <= 280 && !farOver);
      final d = keep ? u.text : digest(u.text);
      if (d == u.text) {
        b.writeln('[#${u.seq}] ${_indent(u.text)}$atts');
      } else {
        digested++;
        b.writeln('[#${u.seq} · digest] ${_indent(d)}$atts');
      }
    }
    b.writeln();

    // Facts & data the user provided.
    final facts = <String>[];
    for (final u in l.userMessages) {
      for (final a in u.attachments) {
        facts.add('#${u.seq} attachment: $a');
      }
      final fences = RegExp('```').allMatches(u.text).length ~/ 2;
      if (fences > 0) {
        facts.add(
          '#${u.seq} pasted $fences code block${fences == 1 ? '' : 's'}',
        );
      }
      if (u.truncated) {
        facts.add('#${u.seq} pasted ${u.fullLength} chars (long paste)');
      }
      final refs = <String>{
        ..._url.allMatches(u.text).map((m) => m.group(0)!),
        ..._path.allMatches(u.text).map((m) => m.group(0)!),
      };
      if (refs.isNotEmpty) facts.add('#${u.seq} refs: ${refs.join(', ')}');
    }
    b.writeln('## Facts & data the user provided');
    if (facts.isEmpty) b.writeln('(none beyond the messages above)');
    for (final f
        in facts.length > 120 ? facts.sublist(facts.length - 120) : facts) {
      b.writeln('- $f');
    }
    if (facts.length > 120) {
      b.writeln('- (+${facts.length - 120} earlier references — see messages)');
    }
    b.writeln();

    // Files & artifacts: every created/edited/deleted path, always.
    List<String> withOp(String op) => [
      for (final e in l.files.entries)
        if (e.value.contains(op)) e.key,
    ];
    final created = withOp('created');
    final edited = withOp('edited');
    final deleted = withOp('deleted');
    final read = withOp('read');
    b.writeln('## Files & artifacts');
    if (l.files.isEmpty) b.writeln('(none)');
    if (created.isNotEmpty) b.writeln('- created: ${created.join(', ')}');
    if (edited.isNotEmpty) b.writeln('- edited: ${edited.join(', ')}');
    if (deleted.isNotEmpty) b.writeln('- deleted: ${deleted.join(', ')}');
    if (read.isNotEmpty) {
      b.writeln(
        '- read: ${read.take(60).join(', ')}'
        '${read.length > 60 ? ' (+${read.length - 60} more)' : ''}',
      );
    }
    b.writeln();

    // Actions: chronological; low-value entries collapse first.
    final actionBudget = (budget * 0.3).floor();
    String line(LedgerAction a) =>
        '#${a.seq} ${a.tool}: ${_clip(a.input, 240)} → ${a.outcome}'
        '${a.note == null ? '' : ' — ${_clip(a.note!, 200)}'}';
    final shown = List.of(l.actions);
    final localCollapsed = Map<String, int>.of(l.collapsed);
    int size() => shown.fold<int>(0, (a, x) => a + line(x).length + 1);
    final passes = <bool Function(LedgerAction)>[
      (a) => a.kind == ActionKind.reply,
      (a) => a.kind == ActionKind.read,
      (a) =>
          !a.failed &&
          (a.kind == ActionKind.shell || a.kind == ActionKind.other),
      // Successful writes/deletes last: every path stays in Files above.
      (a) =>
          !a.failed &&
          (a.kind == ActionKind.write || a.kind == ActionKind.delete),
      // Failures, subagents, MCP calls and VCS actions are never collapsed.
    ];
    for (final pass in passes) {
      var i = 0;
      while (size() > actionBudget && i < shown.length - 15) {
        if (pass(shown[i])) {
          final a = shown.removeAt(i);
          localCollapsed[a.tool] = (localCollapsed[a.tool] ?? 0) + 1;
        } else {
          i++;
        }
      }
    }
    b.writeln('## Actions taken (chronological)');
    if (localCollapsed.isNotEmpty) {
      final n = localCollapsed.values.fold<int>(0, (a, x) => a + x);
      b.writeln(
        '- ($n earlier routine action${n == 1 ? '' : 's'} collapsed: '
        '${localCollapsed.entries.map((e) => '${e.key}×${e.value}').join(', ')}; '
        'every file they touched is listed above)',
      );
    }
    if (shown.isEmpty && localCollapsed.isEmpty) b.writeln('(none)');
    for (final a in shown) {
      b.writeln('- ${line(a)}');
    }
    b.writeln();

    final n = _splitNarrative(l.narrative);
    String? pick(bool Function(String) test) {
      for (final e in n.entries) {
        if (test(e.key.toLowerCase())) return e.value;
      }
      return null;
    }

    bool isDecision(String k) => k.contains('decision');
    bool isCurrent(String k) => k.contains('current');
    bool isNext(String k) => k.contains('next') || k.contains('pending');
    bool isError(String k) => k.contains('error');
    final unavailable = l.narrative.trim().isEmpty
        ? '(model summary unavailable — rely on the user instructions and '
              'actions above)'
        : null;

    b
      ..writeln('## Decisions')
      ..writeln(pick(isDecision) ?? unavailable ?? '(none recorded)')
      ..writeln();

    // Errors & fixes: deterministic, plus any narrative explanation.
    b.writeln('## Errors & fixes');
    final errs = l.errors.length > 40
        ? l.errors.sublist(l.errors.length - 40)
        : l.errors;
    if (l.errors.length > 40) {
      b.writeln(
        '- (${l.errors.length - 40} earlier errors, all resolved or superseded)',
      );
    }
    if (errs.isEmpty) b.writeln('(none)');
    for (final e in errs) {
      b.writeln(
        '- #${e.actionSeq} ${e.tool} ${_clip(e.input, 160)}: ${e.error} → '
        '${e.fix == null ? 'UNRESOLVED at checkpoint' : 'fixed by ${e.fix}'}',
      );
    }
    final errNarr = pick(isError);
    if (errNarr != null && errNarr.trim().isNotEmpty) b.writeln(errNarr);
    b.writeln();

    // Current state.
    b.writeln('## Current state / todos');
    if (state.todos.isEmpty) {
      b.writeln('- todos: (none)');
    } else {
      b.writeln('- todos:');
      for (final t in state.todos) {
        final mark = t['status'] == 'completed'
            ? 'x'
            : t['status'] == 'in_progress'
            ? '~'
            : ' ';
        b.writeln('  - [$mark] ${t['content']}');
      }
    }
    final g = state.goal;
    if (g != null && g['objective'] != null) {
      b.writeln(
        '- active goal (${g['status'] ?? 'active'}): ${g['objective']}',
      );
    }
    b.writeln(
      '- plan mode: ${state.planMode ? 'ON (read-only planning)' : 'off'}',
    );
    if ((state.workingFolder ?? '').isNotEmpty) {
      b.writeln('- working folder: ${state.workingFolder}');
    }
    final current = pick(isCurrent);
    if (current != null) b.writeln(current);
    b.writeln(
      '- the ${state.retainedMessages} most recent message'
      '${state.retainedMessages == 1 ? '' : 's'} follow verbatim after this '
      'checkpoint',
    );
    b.writeln();

    // Next steps.
    b.writeln('## Next steps');
    final next = pick(isNext);
    if (next != null) {
      b.writeln(next);
    } else {
      final pending = state.todos.where((t) => t['status'] != 'completed');
      for (final t in pending) {
        b.writeln('- ${t['content']}');
      }
      final last = l.userMessages.isEmpty ? null : l.userMessages.last;
      b.writeln(
        last == null
            ? '- continue from the messages that follow'
            : '- continue from the latest user request (#${last.seq}) and the '
                  'messages that follow',
      );
    }
    b.writeln();

    if (l.focus.isNotEmpty) {
      b.writeln('## Compaction focus (requested by the user)');
      for (final f in l.focus) {
        b.writeln('- $f${f == currentFocus ? ' (this compaction)' : ''}');
      }
      b.writeln();
    }

    final rest = [
      for (final e in n.entries)
        if (!isDecision(e.key.toLowerCase()) &&
            !isCurrent(e.key.toLowerCase()) &&
            !isNext(e.key.toLowerCase()) &&
            !isError(e.key.toLowerCase()) &&
            e.value.trim().isNotEmpty)
          e.key.isEmpty ? e.value : '### ${e.key}\n${e.value}',
    ];
    if (rest.isNotEmpty) {
      b
        ..writeln('## Additional context')
        ..writeln(_clip(rest.join('\n\n'), (budget * 0.2).floor()))
        ..writeln();
    }

    return Checkpoint(
      text: b.toString().trimRight(),
      verbatimUsers: (l.goal == null ? 0 : 1) + userList.length - digested,
      digestedUsers: digested,
      files: l.files.length,
      actions: l.actionCount,
      narrativeAvailable: narrativeAvailable,
    );
  }
}
