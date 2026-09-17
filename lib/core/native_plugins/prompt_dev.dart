import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/prompt_framework.dart';

/// Task 2 (NP5) writing/dev prompt-backed capabilities.
///
/// Each capability declares prompt templates + JSON schemas only; model
/// execution lives in `AgentService.runPromptTool`. No network, no secrets,
/// no sandbox code here — the model does the work. All user content is
/// embedded via [boundInput] so long diffs stay within token bounds.
void registerPromptDev() {
  NativePluginRegistry.I.register(ReadmeWriterCapability());
  NativePluginRegistry.I.register(ChangelogGenCapability());
  NativePluginRegistry.I.register(CommitMsgHelperCapability());
  NativePluginRegistry.I.register(TestWriterCapability());
  NativePluginRegistry.I.register(CodeReviewAiCapability());
  NativePluginRegistry.I.register(GitDiffExplainCapability());
  NativePluginRegistry.I.register(PrReviewerCapability());
  NativePluginRegistry.I.register(TailwindHelperCapability());
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

// ---------------------------------------------------------------------------
// README Writer
// ---------------------------------------------------------------------------

class ReadmeWriterCapability extends NativePromptCapability {
  @override
  String get pluginName => 'README Writer';

  @override
  String get taskSystemPrompt =>
      'You are an expert technical writer. Write professional README '
      'documentation from the given repository facts. Use clear sections '
      '(overview, installation, usage, API, contributing, license). '
      'Output Markdown only.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'generate',
          description: 'Generate professional README sections from repo facts.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'repo_name': {'type': 'string'},
              'files_summary': {'type': 'string'},
              'tone': {'type': 'string'},
            },
            'required': ['repo_name'],
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
    final repoName = _requireArg(args, 'repo_name');
    final filesSummary = _optionalArg(args, 'files_summary', '(none provided)');
    final tone = _optionalArg(args, 'tone', 'neutral');
    return 'Write a professional README for the repository '
        '"${boundInput(repoName, maxInputChars)}".\n'
        'Tone: ${boundInput(tone, maxInputChars)}.\n'
        'Files summary:\n'
        '${boundInput(filesSummary, maxInputChars)}\n'
        'Include overview, installation, usage, API, contributing, '
        'and license sections.';
  }
}

// ---------------------------------------------------------------------------
// Changelog Gen
// ---------------------------------------------------------------------------

class ChangelogGenCapability extends NativePromptCapability {
  @override
  String get pluginName => 'Changelog Gen';

  @override
  String get taskSystemPrompt =>
      'You are a release-notes assistant. Convert commit messages into '
      'Keep-a-Changelog entries grouped under Added, Fixed, and Changed. '
      'Output Markdown only, no commentary.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'generate',
          description:
              'Generate Keep-a-Changelog entries from commit messages.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'commits_text': {'type': 'string'},
            },
            'required': ['commits_text'],
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
    final commits = _requireArg(args, 'commits_text');
    return 'Generate Keep-a-Changelog entries grouped under Added, Fixed, '
        'and Changed from these commits:\n'
        '${boundInput(commits, maxInputChars)}';
  }
}

// ---------------------------------------------------------------------------
// Commit Msg Helper
// ---------------------------------------------------------------------------

class CommitMsgHelperCapability extends NativePromptCapability {
  @override
  String get pluginName => 'Commit Msg Helper';

  @override
  String get taskSystemPrompt =>
      'You are a Conventional Commits assistant. Given a unified diff, '
      'write a one-line Conventional Commits summary followed by a short '
      'body. Output only the commit message.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'generate',
          description:
              'Write a Conventional Commits message for the given diff.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'diff': {'type': 'string'},
            },
            'required': ['diff'],
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
    final diff = _requireArg(args, 'diff');
    return 'Write a Conventional Commits one-liner plus a short body for '
        'this diff:\n'
        '${boundInput(diff, maxInputChars)}';
  }
}

// ---------------------------------------------------------------------------
// Test Writer
// ---------------------------------------------------------------------------

class TestWriterCapability extends NativePromptCapability {
  @override
  String get pluginName => 'Test Writer';

  @override
  String get taskSystemPrompt =>
      'You are a test-writing assistant. Given source code, write unit '
      'tests with edge cases for the stated or inferred framework. '
      'Output only test code with brief comments.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'generate',
          description: 'Write unit tests with edge cases for the given code.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'code': {'type': 'string'},
              'framework': {'type': 'string'},
            },
            'required': ['code'],
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
    final code = _requireArg(args, 'code');
    final framework = _optionalArg(args, 'framework', '(infer from the code)');
    return 'Write unit tests with edge cases for this code.\n'
        'Framework: ${boundInput(framework, maxInputChars)}.\n'
        'Code:\n'
        '${boundInput(code, maxInputChars)}';
  }
}

// ---------------------------------------------------------------------------
// Code Review AI
// ---------------------------------------------------------------------------

class CodeReviewAiCapability extends NativePromptCapability {
  @override
  String get pluginName => 'Code Review AI';

  @override
  String get taskSystemPrompt =>
      'You are a senior code reviewer. Report findings ordered by '
      'severity with suggested fixes. Be specific and reference the code.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'review',
          description: 'Review code, findings ordered by severity.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'code': {'type': 'string'},
              'focus': {'type': 'string'},
            },
            'required': ['code'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  String buildPrompt(String toolName, Map<String, dynamic> args) {
    if (toolName != 'review') {
      throw ArgumentError('Unknown tool: $toolName');
    }
    final code = _requireArg(args, 'code');
    final focus = _optionalArg(args, 'focus', '(all areas)');
    return 'Review this code. Findings ordered by severity with suggested '
        'fixes.\n'
        'Focus: ${boundInput(focus, maxInputChars)}.\n'
        'Code:\n'
        '${boundInput(code, maxInputChars)}';
  }
}

// ---------------------------------------------------------------------------
// Git Diff Explain
// ---------------------------------------------------------------------------

class GitDiffExplainCapability extends NativePromptCapability {
  @override
  String get pluginName => 'Git Diff Explain';

  @override
  String get taskSystemPrompt =>
      'You are a code explainer. Given a unified diff, write a '
      'plain-language walkthrough of what changed and why it matters.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'explain',
          description: 'Explain in plain language what a diff does.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'diff': {'type': 'string'},
            },
            'required': ['diff'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  String buildPrompt(String toolName, Map<String, dynamic> args) {
    if (toolName != 'explain') {
      throw ArgumentError('Unknown tool: $toolName');
    }
    final diff = _requireArg(args, 'diff');
    return 'Explain in plain language what this diff does, file by file:\n'
        '${boundInput(diff, maxInputChars)}';
  }
}

// ---------------------------------------------------------------------------
// PR Reviewer
// ---------------------------------------------------------------------------

class PrReviewerCapability extends NativePromptCapability {
  @override
  String get pluginName => 'PR Reviewer';

  @override
  String get taskSystemPrompt =>
      'You are a pull-request reviewer. Give inline-style findings and '
      'end with a verdict: APPROVE or NEEDS WORK with reasons.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'review',
          description:
              'Review a pull-request diff with an approve/needs-work verdict.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'pr_diff': {'type': 'string'},
              'checklist': {'type': 'string'},
            },
            'required': ['pr_diff'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  String buildPrompt(String toolName, Map<String, dynamic> args) {
    if (toolName != 'review') {
      throw ArgumentError('Unknown tool: $toolName');
    }
    final prDiff = _requireArg(args, 'pr_diff');
    final checklist = _optionalArg(args, 'checklist', '(default checks)');
    return 'Review this pull request. Give inline-style findings and end '
        'with a verdict: APPROVE or NEEDS WORK with reasons.\n'
        'Checklist: ${boundInput(checklist, maxInputChars)}.\n'
        'Diff:\n'
        '${boundInput(prDiff, maxInputChars)}';
  }
}

// ---------------------------------------------------------------------------
// Tailwind Helper
// ---------------------------------------------------------------------------

class TailwindHelperCapability extends NativePromptCapability {
  @override
  String get pluginName => 'Tailwind Helper';

  @override
  String get taskSystemPrompt =>
      'You are a Tailwind CSS assistant. Given a UI description, output '
      'the Tailwind utility classes plus minimal markup. Output code only.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'generate',
          description:
              'Generate Tailwind classes plus minimal markup from a '
              'description.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'description': {'type': 'string'},
            },
            'required': ['description'],
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
    final description = _requireArg(args, 'description');
    return 'Generate Tailwind CSS utility classes plus minimal markup for '
        'this UI description:\n'
        '${boundInput(description, maxInputChars)}';
  }
}
