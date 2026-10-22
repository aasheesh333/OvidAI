import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'subagent_summary.dart';

// TODO(l10n): extract this screen's English copy during the ARB pass.

enum V2SubagentStatus { loading, empty, error, ready }

enum V2SubagentLogTone { normal, success, accent }

/// One line in the subagent log. Retained for hosts; the page links to the
/// log instead of previewing it.
@immutable
class V2SubagentLogLine {
  const V2SubagentLogLine({
    required this.time,
    required this.text,
    this.tone = V2SubagentLogTone.normal,
  });

  final String time;
  final String text;
  final V2SubagentLogTone tone;
}

/// Immutable state for [SubagentPage].
@immutable
class V2SubagentPageData {
  const V2SubagentPageData({
    required this.name,
    required this.instanceLabel,
    required this.stepLabel,
    required this.paceLabel,
    required this.goal,
    required this.startedLabel,
    required this.elapsedLabel,
    required this.timeLimitLabel,
    required this.remainingLabel,
    required this.totalLogLines,
    this.working = true,
    this.progress = 0,
    this.progressKnown = true,
    this.files = const [],
    this.logLines = const [],
    this.logPath = '',
    this.summary,
    this.status = V2SubagentStatus.ready,
    this.errorMessage = 'We could not load this subagent.',
  });

  final String name;

  /// Retained for hosts. The page shows the status, not the runtime instance.
  final String instanceLabel;
  final bool working;
  final double progress;

  /// False when the runtime reports no progress measurement.
  final bool progressKnown;
  final String stepLabel;
  final String paceLabel;
  final String goal;
  final List<String> files;
  final String startedLabel;
  final String elapsedLabel;
  final String timeLimitLabel;
  final String remainingLabel;
  final List<V2SubagentLogLine> logLines;
  final int totalLogLines;

  /// Absolute path of the full log, e.g.
  /// `/workspace/.ovid/logs/subagent_ab12.log`.
  final String logPath;

  /// The strict JSON summary the subagent returned, when it has finished.
  final V2SubagentSummaryData? summary;

  final V2SubagentStatus status;
  final String errorMessage;
}

/// One subagent: its status, the five contract fields and one log action.
class SubagentPage extends StatelessWidget {
  const SubagentPage({
    super.key,
    required this.data,
    this.onStop,
    this.onViewLog,
    this.onReadFullLog,
    this.onFileTap,
    this.onBackToChat,
    this.onRetry,
  });

  final V2SubagentPageData data;
  final VoidCallback? onStop;
  final VoidCallback? onViewLog;

  /// Opens the full log at [V2SubagentPageData.logPath] in the device's
  /// viewer or editor. Used when the host has no in-app log viewer.
  final ValueChanged<String>? onReadFullLog;
  final ValueChanged<String>? onFileTap;
  final VoidCallback? onBackToChat;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: 'Subagent',
      subtitle: data.name.isEmpty ? null : data.name,
      padding: false,
      actions: [
        if (data.working && onStop != null)
          OIconButton(
            icon: Icons.stop_circle_outlined,
            semanticLabel: 'Stop subagent',
            onPressed: onStop,
          ),
      ],
      child: switch (data.status) {
        V2SubagentStatus.loading => const OSkeletonList(rows: 5),
        V2SubagentStatus.error => OErrorState(
          message: data.errorMessage,
          onRetry: onRetry,
        ),
        V2SubagentStatus.empty => _empty(),
        V2SubagentStatus.ready => _content(context),
      },
    );
  }

  Widget _empty() {
    return OEmptyState(
      icon: Icons.smart_toy_outlined,
      title: 'No subagent is running',
      message: 'Start one from a chat.',
      action: onBackToChat == null
          ? null
          : OButton(
              label: 'Back to chat',
              icon: Icons.arrow_back_rounded,
              onPressed: onBackToChat,
            ),
    );
  }

  Widget _content(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.m,
        OSpace.l,
        OSpace.l,
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OPill(
            label: data.working ? 'Working' : 'Paused',
            tone: data.working ? OPillTone.accent : OPillTone.neutral,
            dot: data.working,
          ),
        ),
        const SizedBox(height: OSpace.m),
        SubagentSummaryCard(
          summary: data.summary,
          status: data.summary == null
              ? V2SubagentSummaryStatus.empty
              : V2SubagentSummaryStatus.ready,
          onFileTap: onFileTap,
          onRetry: onRetry,
        ),
        if (_logAction != null) ...[
          const SizedBox(height: OSpace.l),
          _logAction!,
        ],
      ],
    );
  }

  /// One log action: the in-app viewer when wired, otherwise the file viewer.
  Widget? get _logAction {
    if (onViewLog != null) {
      return OButton(
        label: 'View log',
        icon: Icons.terminal_rounded,
        variant: OButtonVariant.secondary,
        expand: true,
        onPressed: onViewLog,
      );
    }
    if (onReadFullLog != null && data.logPath.isNotEmpty) {
      return OButton(
        label: 'View log',
        icon: Icons.terminal_rounded,
        variant: OButtonVariant.secondary,
        expand: true,
        onPressed: () => onReadFullLog!(data.logPath),
      );
    }
    return null;
  }
}
