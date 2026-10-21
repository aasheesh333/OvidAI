import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/format.dart';
import '../../../core/state.dart';
import '../runs/run_trajectory_page.dart';
import '../runs/subagent_page.dart';

/// Routes for the run surfaces (trajectory and subagent detail).
///
/// A subagent is a real [ChatSession] parented to the chat that dispatched it,
/// so both screens are built from that session's own transcript and analytics.
/// Anything the session does not record is shown as not reported; no token
/// counts, durations or progress values are invented.
class V2RunRoutes {
  const V2RunRoutes._();

  /// Shown when a session carries no analytics for the value.
  static const String notReported = 'Not reported';

  static Future<void> openTrajectory(
    BuildContext context,
    String sessionId,
  ) async {
    final data = trajectoryDataFor(AppState.I.sessionById(sessionId));
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RunTrajectoryPage(data: data),
      ),
    );
  }

  static Future<void> openSubagent(
    BuildContext context,
    String sessionId,
  ) async {
    final data = subagentDataFor(AppState.I.sessionById(sessionId));
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SubagentPage(data: data),
      ),
    );
  }

  /// Maps a real session onto the trajectory screen.
  ///
  /// A missing session is an error; a session with no recorded steps is empty.
  @visibleForTesting
  static V2RunTrajectoryPageData trajectoryDataFor(ChatSession? session) {
    if (session == null) {
      return const V2RunTrajectoryPageData(
        title: 'Run',
        runLabel: '',
        prompt: '',
        model: '',
        tokensLabel: notReported,
        durationLabel: notReported,
        status: V2RunTrajectoryStatus.error,
        errorMessage: 'This run is no longer available.',
      );
    }

    final steps = <V2RunStep>[
      for (final message in session.messages) ?_stepFor(message),
    ];
    if (steps.isEmpty) {
      return V2RunTrajectoryPageData(
        title: session.title,
        runLabel: '',
        prompt: _firstUserPrompt(session),
        model: session.model,
        tokensLabel: _tokensLabel(session),
        durationLabel: _durationLabel(session),
        status: V2RunTrajectoryStatus.empty,
      );
    }

    return V2RunTrajectoryPageData(
      title: session.title,
      runLabel: steps.length == 1 ? '1 step' : '${steps.length} steps',
      prompt: _firstUserPrompt(session),
      model: session.model,
      tokensLabel: _tokensLabel(session),
      durationLabel: _durationLabel(session),
      steps: steps,
    );
  }

  /// Maps a real subagent session onto the subagent screen.
  ///
  /// A root chat has no subagent to show (empty); a missing session is an
  /// error.
  @visibleForTesting
  static V2SubagentPageData subagentDataFor(
    ChatSession? session, {
    DateTime? now,
  }) {
    if (session == null) {
      return const V2SubagentPageData(
        name: 'Subagent',
        instanceLabel: '',
        stepLabel: '',
        paceLabel: '',
        goal: '',
        startedLabel: '',
        elapsedLabel: '',
        timeLimitLabel: notReported,
        remainingLabel: '',
        totalLogLines: 0,
        status: V2SubagentStatus.error,
        errorMessage: 'This subagent is no longer available.',
      );
    }
    if (!session.isSubagent) {
      return V2SubagentPageData(
        name: session.title,
        instanceLabel: '',
        stepLabel: '',
        paceLabel: '',
        goal: '',
        startedLabel: '',
        elapsedLabel: '',
        timeLimitLabel: notReported,
        remainingLabel: '',
        totalLogLines: 0,
        status: V2SubagentStatus.empty,
      );
    }

    final state = session.agentState;
    final working = state == 'running';
    final logLines = _logLines(session);
    final clock = now ?? DateTime.now();
    final end = working ? clock : session.lastActivityAt;
    final elapsed = end.difference(session.createdAt);

    return V2SubagentPageData(
      name: (session.agentLabel ?? '').trim().isEmpty
          ? session.title
          : session.agentLabel!.trim(),
      instanceLabel: session.model,
      working: working,
      progress: state == 'finished' ? 1 : 0,
      stepLabel: _agentStateLabel(state),
      paceLabel: '',
      goal: session.title,
      files: _filesFrom(session),
      startedLabel: _timeOfDay(session.createdAt),
      elapsedLabel: formatCompactDuration(
        elapsed.isNegative ? Duration.zero : elapsed,
      ),
      timeLimitLabel: notReported,
      remainingLabel: '',
      logLines: logLines,
      totalLogLines: logLines.length,
    );
  }

  // ---------------------------------------------------------------------------
  // Mapping helpers
  // ---------------------------------------------------------------------------

  static V2RunStep? _stepFor(Message message) {
    final id = message.privateSyncId;
    final content = message.content.trim();
    switch (message.kind) {
      case MsgKind.text:
      case MsgKind.streaming:
        if (content.isEmpty) return null;
        final assistant = message.role == 'assistant';
        return V2RunStep(
          id: id,
          title: assistant ? 'Assistant' : 'You',
          detail: cleanTruncate(content, 400),
          durationLabel: _elapsedLabel(message.elapsedMs),
          kind: V2RunStepKind.message,
        );
      case MsgKind.reasoning:
        if (content.isEmpty) return null;
        return V2RunStep(
          id: id,
          title: 'Thinking',
          detail: cleanTruncate(content, 400),
          durationLabel: _elapsedLabel(message.elapsedMs),
          kind: V2RunStepKind.plan,
        );
      case MsgKind.tool:
        final name = (message.toolName ?? '').trim();
        final title = (message.toolTitle ?? '').trim();
        final summary = (message.toolSummary ?? '').trim();
        final detail = message.toolDetail?.trim() ?? '';
        return V2RunStep(
          id: id,
          title: title.isNotEmpty ? title : (name.isNotEmpty ? name : 'Tool'),
          detail: summary.isNotEmpty ? summary : cleanTruncate(content, 400),
          durationLabel: _elapsedLabel(message.elapsedMs),
          kind: _toolKind(name),
          fileName: _toolFile(message),
          expandedDetail: detail.isEmpty ? null : cleanTruncate(detail, 2000),
        );
      case MsgKind.turnTail:
        if (content.isEmpty) return null;
        return V2RunStep(
          id: id,
          title: 'Run update',
          detail: cleanTruncate(content, 400),
          durationLabel: '',
          kind: V2RunStepKind.finish,
        );
      case MsgKind.compact:
        if (content.isEmpty) return null;
        return V2RunStep(
          id: id,
          title: 'Compacted context',
          detail: cleanTruncate(content, 400),
          durationLabel: '',
          kind: V2RunStepKind.plan,
        );
      case MsgKind.imageGen:
        return V2RunStep(
          id: id,
          title: 'Generated image',
          detail: cleanTruncate(content, 400),
          durationLabel: _elapsedLabel(message.elapsedMs),
          kind: V2RunStepKind.preview,
        );
      case MsgKind.htmlArtifact:
        return V2RunStep(
          id: id,
          title: 'Created page',
          detail: cleanTruncate(content, 400),
          durationLabel: _elapsedLabel(message.elapsedMs),
          kind: V2RunStepKind.write,
        );
    }
  }

  static V2RunStepKind _toolKind(String toolName) {
    final name = toolName.toLowerCase();
    if (name.contains('search') ||
        name.contains('grep') ||
        name.contains('glob') ||
        name.contains('read') ||
        name.contains('web') ||
        name.contains('fetch')) {
      return V2RunStepKind.search;
    }
    if (name.contains('preview') ||
        name.contains('browser') ||
        name.contains('screenshot')) {
      return V2RunStepKind.preview;
    }
    if (name.contains('finish') || name.contains('complete')) {
      return V2RunStepKind.finish;
    }
    return V2RunStepKind.write;
  }

  /// The file a tool step wrote, when the tool card records one. Read-only
  /// tools carry a path too, so only mutating tools count as writes.
  static String? _toolFile(Message message) {
    final name = (message.toolName ?? '').toLowerCase();
    final writes = name.contains('write') ||
        name.contains('edit') ||
        name.contains('create') ||
        name.contains('append') ||
        name.contains('replace') ||
        name.contains('delete') ||
        name.contains('move');
    if (!writes) return null;
    final input = message.toolInput;
    if (input != null && input.isNotEmpty) {
      final path = _pathFromToolInput(input);
      if (path != null) return path;
    }
    return null;
  }

  static String? _pathFromToolInput(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      for (final key in const ['path', 'file', 'file_path', 'filename']) {
        final value = decoded[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
    } catch (_) {
      // A malformed tool input is not a path.
    }
    return null;
  }

  static List<String> _filesFrom(ChatSession session) {
    final files = <String>[];
    for (final message in session.messages) {
      if (message.kind != MsgKind.tool) continue;
      final path = _toolFile(message);
      if (path != null && !files.contains(path)) files.add(path);
    }
    return files;
  }

  /// The most recent tool rows, shown as the log preview.
  static List<V2SubagentLogLine> _logLines(ChatSession session) {
    final tools = [
      for (final message in session.messages)
        if (message.kind == MsgKind.tool) message,
    ];
    const preview = 5;
    final tail = tools.length <= preview
        ? tools
        : tools.sublist(tools.length - preview);
    return [
      for (final message in tail)
        V2SubagentLogLine(
          time: _timeOfDaySeconds(message.time),
          text: _toolLogText(message),
          tone: switch (message.toolState) {
            'ok' => V2SubagentLogTone.success,
            'error' => V2SubagentLogTone.accent,
            _ => V2SubagentLogTone.normal,
          },
        ),
    ];
  }

  static String _toolLogText(Message message) {
    final summary = (message.toolSummary ?? '').trim();
    if (summary.isNotEmpty) return summary;
    final title = (message.toolTitle ?? '').trim();
    if (title.isNotEmpty) return title;
    final name = (message.toolName ?? '').trim();
    return name.isEmpty ? 'Tool' : name;
  }

  static String _firstUserPrompt(ChatSession session) {
    for (final message in session.messages) {
      if (message.role == 'user' && message.content.trim().isNotEmpty) {
        return cleanTruncate(message.content.trim(), 400);
      }
    }
    return '';
  }

  static String _tokensLabel(ChatSession session) {
    final total = session.analytics.inputTokens + session.analytics.outputTokens;
    return total <= 0 ? notReported : '${formatCompactCount(total)} tokens';
  }

  static String _durationLabel(ChatSession session) {
    final ms = session.analytics.llmMs + session.analytics.toolMs;
    return ms <= 0
        ? notReported
        : formatCompactDuration(Duration(milliseconds: ms));
  }

  static String _elapsedLabel(int? ms) =>
      ms == null || ms <= 0 ? '' : formatCompactDuration(Duration(milliseconds: ms));

  static String _agentStateLabel(String? state) => switch (state) {
    'running' => 'Working',
    'finished' => 'Finished',
    'stopped' => 'Stopped',
    'failed' => 'Failed',
    _ => 'State not reported',
  };

  static String _timeOfDay(DateTime at) {
    final local = at.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  static String _timeOfDaySeconds(DateTime at) {
    final local = at.toLocal();
    final s = local.second.toString().padLeft(2, '0');
    return '${_timeOfDay(local)}:$s';
  }
}
