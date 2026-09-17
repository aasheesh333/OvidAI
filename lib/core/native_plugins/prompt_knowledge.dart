import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/prompt_framework.dart';

/// Task 3 (NP5) knowledge/productivity prompt-backed capabilities.
///
/// Each capability declares prompt templates + JSON schemas only; model
/// execution lives in `AgentService.runPromptTool`. No network, no secrets,
/// no sandbox code here — the model does the work. All user content is
/// embedded via [boundInput] so long transcripts stay within token bounds.
///
/// Two deliberate specials (brief §5):
/// * [DataAnalystCapability] precomputes column stats locally and embeds
///   them + a bounded raw sample; the model returns insights text.
/// * [CalendarTasksCapability.list_help] is static syntax help; it still
///   rides the normal sub-call (the model echoes it back) for uniformity —
///   see the tiny-model-hop comment on that tool.
/// * [MultiModelCompareCapability] encodes a `FANOUT:` envelope parsed
///   agent-side by `runPromptTool` (the plan-mandated framework exception).
void registerPromptKnowledge() {
  NativePluginRegistry.I.register(TranslateProCapability());
  NativePluginRegistry.I.register(StudyModeCapability());
  NativePluginRegistry.I.register(MeetingNotesCapability());
  NativePluginRegistry.I.register(DataAnalystCapability());
  NativePluginRegistry.I.register(IssueTriagerCapability());
  NativePluginRegistry.I.register(ReleaseNotesCapability());
  NativePluginRegistry.I.register(CalendarTasksCapability());
  NativePluginRegistry.I.register(MultiModelCompareCapability());
}

/// Returns the trimmed non-empty string for [key] or throws [ArgumentError].
String _requireArg(Map<String, dynamic> args, String key) {
  final value = args[key]?.toString().trim() ?? '';
  if (value.isEmpty) {
    throw ArgumentError('Missing required argument: $key');
  }
  return value;
}

/// Returns the trimmed optional string for [key], or [fallback] when absent.
String _optionalArg(
  Map<String, dynamic> args,
  String key,
  String fallback,
) {
  final value = args[key]?.toString().trim() ?? '';
  return value.isEmpty ? fallback : value;
}

/// Returns the 1..50 clamped count for [key], or [fallback] when absent.
int _countArg(Map<String, dynamic> args, String key, int fallback) {
  final raw = args[key]?.toString().trim() ?? '';
  if (raw.isEmpty) return fallback;
  final parsed = int.tryParse(raw);
  if (parsed == null) return fallback;
  return parsed.clamp(1, 50);
}

/// Formats a stat number without trailing noise (15.0 → `15`, 1.5 → `1.5`).
String _fmtNum(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value.toString();
}

/// Splits one CSV line on commas, honouring `"quoted"` cells (`""` = `"`).
List<String> _splitCsvLine(String line) {
  final cells = <String>[];
  final current = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
        current.write('"');
        i++;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }
    if (ch == ',' && !inQuotes) {
      cells.add(current.toString());
      current.clear();
      continue;
    }
    current.write(ch);
  }
  cells.add(current.toString());
  return cells.map((c) => c.trim()).toList();
}

/// Local column stats for [DataAnalystCapability.analyze]: header names,
/// data row count, and per-column numeric min/max/mean over parseable cells.
String _csvStats(String csvText) {
  final lines = csvText
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.isEmpty) return 'Columns: (none)\nRows: 0';
  final headers = _splitCsvLine(lines.first);
  final rows = lines.skip(1).map(_splitCsvLine).toList();
  final out = StringBuffer('Columns: ${headers.join(', ')}\n');
  out.writeln('Rows: ${rows.length}');
  for (var c = 0; c < headers.length; c++) {
    final numbers = <double>[];
    for (final row in rows) {
      if (c >= row.length) continue;
      final parsed = double.tryParse(row[c]);
      if (parsed != null) numbers.add(parsed);
    }
    if (numbers.isEmpty) {
      out.writeln('Column "${headers[c]}": non-numeric (${rows.length} values)');
      continue;
    }
    numbers.sort();
    final mean = numbers.reduce((a, b) => a + b) / numbers.length;
    out.writeln(
      'Column "${headers[c]}": numeric (n=${numbers.length}), '
      'min ${_fmtNum(numbers.first)}, max ${_fmtNum(numbers.last)}, '
      'mean ${_fmtNum(mean)}',
    );
  }
  return out.toString().trimRight();
}

// ---------------------------------------------------------------------------
// Translate Pro
// ---------------------------------------------------------------------------

class TranslateProCapability extends NativePromptCapability {
  @override
  String get pluginName => 'Translate Pro';

  @override
  String get taskSystemPrompt =>
      'You are an expert translator. Output ONLY the translation in the '
      'requested target language — no commentary, no alternatives, no '
      'explanations.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'translate',
          description: 'Translate text into the target language.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
              'target_lang': {'type': 'string'},
              'source_lang': {'type': 'string'},
            },
            'required': ['text', 'target_lang'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  String buildPrompt(String toolName, Map<String, dynamic> args) {
    if (toolName != 'translate') {
      throw ArgumentError('Unknown tool: $toolName');
    }
    final text = _requireArg(args, 'text');
    final target = _requireArg(args, 'target_lang');
    final source = _optionalArg(args, 'source_lang', '(auto-detect)');
    return 'Translate the following text into '
        '${boundInput(target, maxInputChars)}.\n'
        'Source language: ${boundInput(source, maxInputChars)}.\n'
        'Text:\n'
        '${boundInput(text, maxInputChars)}\n'
        'Output only the translation.';
  }
}

// ---------------------------------------------------------------------------
// Study Mode
// ---------------------------------------------------------------------------

class StudyModeCapability extends NativePromptCapability {
  @override
  String get pluginName => 'Study Mode';

  @override
  String get taskSystemPrompt =>
      'You are a study coach. Generate flashcards and quizzes that test '
      'understanding of the given material. Output only the study content.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'flashcards',
          description: 'Generate Q/A flashcard pairs from study text.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
              'count': {'type': 'integer'},
            },
            'required': ['text'],
          },
        ),
        NativePluginTool(
          name: 'quiz',
          description: 'Generate a multiple-choice quiz from study text.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
              'count': {'type': 'integer'},
            },
            'required': ['text'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  String buildPrompt(String toolName, Map<String, dynamic> args) {
    switch (toolName) {
      case 'flashcards':
        final text = _requireArg(args, 'text');
        final count = _countArg(args, 'count', 10);
        return 'Generate exactly $count flashcards from this material. '
            'Format each card as two lines, `Q: <question>` then '
            '`A: <answer>`, separated by a blank line.\n'
            'Material:\n'
            '${boundInput(text, maxInputChars)}';
      case 'quiz':
        final text = _requireArg(args, 'text');
        final count = _countArg(args, 'count', 5);
        return 'Generate a numbered multiple-choice quiz with exactly '
            '$count questions from this material. Each question has 4 '
            'options (A-D). End with an answer key listing the correct '
            'letter per question.\n'
            'Material:\n'
            '${boundInput(text, maxInputChars)}';
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }
}

// ---------------------------------------------------------------------------
// Meeting Notes
// ---------------------------------------------------------------------------

class MeetingNotesCapability extends NativePromptCapability {
  @override
  String get pluginName => 'Meeting Notes';

  @override
  String get taskSystemPrompt =>
      'You are a meeting-minutes assistant. Distill transcripts into '
      'concise minutes: summary, decisions, and action items with owners. '
      'Output Markdown only.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'summarize',
          description: 'Summarize a meeting transcript into minutes.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'transcript': {'type': 'string'},
            },
            'required': ['transcript'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  String buildPrompt(String toolName, Map<String, dynamic> args) {
    if (toolName != 'summarize') {
      throw ArgumentError('Unknown tool: $toolName');
    }
    final transcript = _requireArg(args, 'transcript');
    return 'Summarize this meeting transcript into minutes with three '
        'sections: Summary, Decisions (each decision on its own line), '
        'and Action items (each action item with its owner).\n'
        'Transcript:\n'
        '${boundInput(transcript, maxInputChars)}';
  }
}

// ---------------------------------------------------------------------------
// Data Analyst
// ---------------------------------------------------------------------------

class DataAnalystCapability extends NativePromptCapability {
  @override
  String get pluginName => 'Data Analyst';

  @override
  String get taskSystemPrompt =>
      'You are a data analyst. Given precomputed column stats plus a raw '
      'CSV sample, describe trends and insights in plain language. '
      'Output text only, no code.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'analyze',
          description: 'Analyze CSV data and describe trends and insights.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'csv_text': {'type': 'string'},
            },
            'required': ['csv_text'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  String buildPrompt(String toolName, Map<String, dynamic> args) {
    if (toolName != 'analyze') {
      throw ArgumentError('Unknown tool: $toolName');
    }
    final csvText = _requireArg(args, 'csv_text');
    return 'Analyze this CSV data. Precomputed column stats (computed '
        'locally, trust them):\n'
        '${_csvStats(csvText)}\n'
        'Raw sample:\n'
        '${boundInput(csvText, maxInputChars)}\n'
        'Describe the key trends and insights in plain language.';
  }
}

// ---------------------------------------------------------------------------
// Issue Triager
// ---------------------------------------------------------------------------

class IssueTriagerCapability extends NativePromptCapability {
  @override
  String get pluginName => 'Issue Triager';

  @override
  String get taskSystemPrompt =>
      'You are an issue triager. Classify bug reports with an area, '
      'severity, priority, and labels. Output only the classification lines.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'triage',
          description: 'Classify an issue with area/severity/priority/labels.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'title': {'type': 'string'},
              'body': {'type': 'string'},
            },
            'required': ['title'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  String buildPrompt(String toolName, Map<String, dynamic> args) {
    if (toolName != 'triage') {
      throw ArgumentError('Unknown tool: $toolName');
    }
    final title = _requireArg(args, 'title');
    final body = _optionalArg(args, 'body', '(no body provided)');
    return 'Triage this issue. Output exactly these four strict lines and '
        'nothing else:\n'
        'area: <component area>\n'
        'severity: <critical|high|medium|low>\n'
        'priority: <p0|p1|p2|p3>\n'
        'labels: <comma-separated labels>\n'
        'Title: ${boundInput(title, maxInputChars)}\n'
        'Body:\n'
        '${boundInput(body, maxInputChars)}';
  }
}

// ---------------------------------------------------------------------------
// Release Notes
// ---------------------------------------------------------------------------

class ReleaseNotesCapability extends NativePromptCapability {
  @override
  String get pluginName => 'Release Notes';

  @override
  String get taskSystemPrompt =>
      'You are a release-notes writer. Turn a pull-request list into '
      'user-facing highlights plus upgrade notes. Output Markdown only.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'generate',
          description: 'Generate user-facing release notes from a PR list.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'pr_list': {'type': 'string'},
            },
            'required': ['pr_list'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  String buildPrompt(String toolName, Map<String, dynamic> args) {
    if (toolName != 'generate') {
      throw ArgumentError('Unknown tool: $toolName');
    }
    final prList = _requireArg(args, 'pr_list');
    return 'Write user-facing release notes from these pull requests with '
        'two sections: Highlights (what changed for users) and Upgrade '
        'notes (breaking changes and migration steps, or "None").\n'
        'Pull requests:\n'
        '${boundInput(prList, maxInputChars)}';
  }
}

// ---------------------------------------------------------------------------
// Calendar & Tasks
// ---------------------------------------------------------------------------

class CalendarTasksCapability extends NativePromptCapability {
  @override
  String get pluginName => 'Calendar & Tasks';

  @override
  String get taskSystemPrompt =>
      'You are a reminder parser. Convert natural-language reminder text '
      'into strict JSON. Never add commentary.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'parse_reminder',
          description: 'Parse reminder text into strict reminder JSON.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
            },
            'required': ['text'],
          },
        ),
        NativePluginTool(
          name: 'list_help',
          description: 'Explain the supported reminder syntax.',
          inputSchema: {
            'type': 'object',
            'properties': {},
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  String buildPrompt(String toolName, Map<String, dynamic> args) {
    switch (toolName) {
      case 'parse_reminder':
        final text = _requireArg(args, 'text');
        return 'Parse this reminder text into STRICT JSON with exactly '
            'these keys: {"title": "<short title>", '
            '"when_text": "<when it is due, as written>"}. Output ONLY the '
            'JSON object — the outer agent feeds it to schedule_create.\n'
            'Text:\n'
            '${boundInput(text, maxInputChars)}';
      case 'list_help':
        // Static syntax help. It still rides the normal sub-call (the model
        // echoes it back) for uniformity — no special execution path.
        return 'Echo back this reminder syntax help verbatim:\n'
            'Reminders accept natural language like "Call mom tomorrow at '
            '6pm" or "Water the plants every Sunday". Use parse_reminder '
            'to convert one into JSON, then schedule_create to save it.';
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }
}

// ---------------------------------------------------------------------------
// Multi-Model Compare
// ---------------------------------------------------------------------------

class MultiModelCompareCapability extends NativePromptCapability {
  @override
  String get pluginName => 'Multi-Model Compare';

  @override
  String get taskSystemPrompt =>
      'You are a helpful assistant. Answer the user prompt directly.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'compare',
          description: 'Run one prompt across up to 3 models and compare.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'prompt': {'type': 'string'},
              'models': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
            'required': ['prompt'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  String buildPrompt(String toolName, Map<String, dynamic> args) {
    if (toolName != 'compare') {
      throw ArgumentError('Unknown tool: $toolName');
    }
    final prompt = _requireArg(args, 'prompt');
    final models = _modelsArg(args['models']);
    if (models.length > 3) {
      throw ArgumentError(
        'Multi-model compare supports at most 3 models '
        '(got ${models.length}).',
      );
    }
    // FANOUT envelope: parsed agent-side by runPromptTool (the
    // plan-mandated framework exception). Models are comma-separated
    // provider ids; empty means "session provider + recent models".
    return 'FANOUT:${models.join(',')}|${boundInput(prompt, maxInputChars)}';
  }
}

/// Normalizes the `models` arg (list, comma-separated string, or absent).
List<String> _modelsArg(Object? raw) {
  if (raw == null) return const [];
  if (raw is List) {
    return raw
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }
  return raw
      .toString()
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}
