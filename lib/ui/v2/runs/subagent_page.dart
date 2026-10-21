import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): extract this screen's English copy during the ARB pass.

enum V2SubagentStatus { loading, empty, error, ready }

enum V2SubagentLogTone { normal, success, accent }

/// One line in the subagent log preview.
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
    this.files = const [],
    this.logLines = const [],
    this.status = V2SubagentStatus.ready,
    this.errorMessage = 'We could not load this subagent.',
  });

  final String name;
  final String instanceLabel;
  final bool working;
  final double progress;
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
  final V2SubagentStatus status;
  final String errorMessage;
}

/// One subagent, its progress and its live log preview.
class SubagentPage extends StatelessWidget {
  const SubagentPage({
    super.key,
    required this.data,
    this.onStop,
    this.onViewLog,
    this.onFileTap,
    this.onBackToChat,
    this.onRetry,
  });

  final V2SubagentPageData data;
  final VoidCallback? onStop;
  final VoidCallback? onViewLog;
  final ValueChanged<String>? onFileTap;
  final VoidCallback? onBackToChat;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Subagent'),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: switch (data.status) {
            V2SubagentStatus.loading => const OSkeletonList(rows: 5),
            V2SubagentStatus.error => OErrorState(
              message: data.errorMessage,
              onRetry: onRetry,
            ),
            V2SubagentStatus.empty => _empty(context),
            V2SubagentStatus.ready => _content(context),
          },
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return OEmptyState(
      icon: Icons.smart_toy_outlined,
      title: 'No subagent is running',
      message: 'Start one from a chat. Its progress will show here.',
      action: OButton(
        label: 'Back to chat',
        icon: Icons.arrow_back_rounded,
        onPressed: onBackToChat,
      ),
    );
  }

  Widget _content(BuildContext context) {
    final c = OColors.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.m,
        OSpace.l,
        OSpace.l,
      ),
      children: [
        OFadeSlide(
          child: OStagger(
            children: [
              _HeroCard(data: data),
              const SizedBox(height: OSpace.m),
              _DetailsCard(data: data, onFileTap: onFileTap),
              const SizedBox(height: OSpace.m),
              _LogCard(data: data, onViewLog: onViewLog),
              const SizedBox(height: OSpace.l),
              OButton(
                label: 'Stop subagent',
                icon: Icons.stop_circle_outlined,
                variant: OButtonVariant.dangerFill,
                expand: true,
                onPressed: onStop,
              ),
              const SizedBox(height: OSpace.s),
              Text(
                'Stopping pauses tasks and saves your changes.',
                textAlign: TextAlign.center,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
              const SizedBox(height: OSpace.xs),
              Text(
                'Subagents cannot start other subagents.',
                textAlign: TextAlign.center,
                style: OType.caption.copyWith(color: c.textFaint),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.data});

  final V2SubagentPageData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: OSpace.s,
            runSpacing: OSpace.s,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: c.accentSoft,
                      borderRadius: BorderRadius.circular(ORadius.m),
                    ),
                    child: Icon(
                      Icons.smart_toy_rounded,
                      size: 24,
                      color: c.accent,
                    ),
                  ),
                  const SizedBox(width: OSpace.m),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          data.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: OType.h2.copyWith(color: c.text),
                        ),
                        const SizedBox(height: OSpace.xs),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.memory_rounded,
                              size: 13,
                              color: c.textMuted,
                            ),
                            const SizedBox(width: OSpace.xs),
                            Flexible(
                              child: Text(
                                data.instanceLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: OType.caption.copyWith(
                                  color: c.textMuted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              _WorkingPill(working: data.working),
            ],
          ),
          const SizedBox(height: OSpace.l),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Overall progress',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
              const SizedBox(width: OSpace.s),
              Text(
                '${(data.progress * 100).round()}%',
                style: OType.bodySm.copyWith(
                  color: c.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          OProgressBar(value: data.progress),
          const SizedBox(height: OSpace.s),
          Row(
            children: [
              Expanded(
                child: Text(
                  data.stepLabel,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
              Icon(Icons.speed_rounded, size: 14, color: c.success),
              const SizedBox(width: OSpace.xs),
              Flexible(
                child: Text(
                  data.paceLabel,
                  style: OType.caption.copyWith(
                    color: c.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WorkingPill extends StatelessWidget {
  const _WorkingPill({required this.working});

  final bool working;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    if (!working) {
      return const OPill(label: 'Paused', tone: OPillTone.neutral);
    }
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.s,
      ),
      decoration: BoxDecoration(
        color: c.accentSoft,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OPulse(
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: c.accent,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: OSpace.xs),
          Text(
            'Working',
            style: OType.caption.copyWith(
              color: c.accent,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.data, this.onFileTap});

  final V2SubagentPageData data;
  final ValueChanged<String>? onFileTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(OSpace.m),
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(ORadius.m),
              border: Border.all(color: c.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.flag_outlined, size: 15, color: c.accent),
                    const SizedBox(width: OSpace.xs),
                    Flexible(
                      child: Text(
                        'Current goal',
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: OSpace.xs),
                Text(
                  data.goal,
                  style: OType.bodySm.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          if (data.files.isNotEmpty) ...[
            const SizedBox(height: OSpace.m),
            Row(
              children: [
                Icon(Icons.edit_document, size: 15, color: c.accent),
                const SizedBox(width: OSpace.xs),
                Expanded(
                  child: Text(
                    'Files touched',
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ),
                const SizedBox(width: OSpace.s),
                Text(
                  data.files.length == 1
                      ? '1 file'
                      : '${data.files.length} files',
                  style: OType.caption.copyWith(color: c.textFaint),
                ),
              ],
            ),
            const SizedBox(height: OSpace.s),
            Wrap(
              spacing: OSpace.s,
              runSpacing: OSpace.s,
              children: [
                for (final file in data.files)
                  _FileChip(
                    name: file,
                    onTap: onFileTap == null ? null : () => onFileTap!(file),
                  ),
              ],
            ),
          ],
          const SizedBox(height: OSpace.m),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _MetricTile(
                  icon: Icons.timer_outlined,
                  label: 'Started',
                  value: data.startedLabel,
                  note: data.working
                      ? 'Working for ${data.elapsedLabel}'
                      : 'Ran for ${data.elapsedLabel}',
                ),
              ),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: _MetricTile(
                  icon: Icons.hourglass_bottom_rounded,
                  label: 'Time limit',
                  value: data.timeLimitLabel,
                  note: data.remainingLabel,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FileChip extends StatelessWidget {
  const _FileChip({required this.name, this.onTap});

  final String name;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OPressable(
      onTap: onTap,
      semanticLabel: 'File $name',
      child: Container(
        constraints: const BoxConstraints(minHeight: OSpace.touch),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.s,
          vertical: OSpace.s,
        ),
        decoration: BoxDecoration(
          color: c.surfaceRaised,
          borderRadius: BorderRadius.circular(ORadius.s),
          border: Border.all(color: c.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.code_rounded, size: 14, color: c.accent),
            const SizedBox(width: OSpace.xs),
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.mono.copyWith(color: c.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.note,
  });

  final IconData icon;
  final String label;
  final String value;
  final String note;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 15, color: c.accent),
              const SizedBox(width: OSpace.xs),
              Flexible(
                child: Text(
                  label,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.xs),
          Text(
            value,
            style: OType.bodySm.copyWith(
              color: c.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: OSpace.xs),
          Text(note, style: OType.caption.copyWith(color: c.textMuted)),
        ],
      ),
    );
  }
}

class _LogCard extends StatelessWidget {
  const _LogCard({required this.data, this.onViewLog});

  final V2SubagentPageData data;
  final VoidCallback? onViewLog;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ORadius.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(OSpace.m),
              child: Row(
                children: [
                  Icon(Icons.terminal_rounded, size: 18, color: c.accent),
                  const SizedBox(width: OSpace.s),
                  Expanded(
                    child: Text(
                      'Log preview',
                      style: OType.bodySm.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (data.working)
                    const OPill(
                      label: 'Live',
                      tone: OPillTone.success,
                      dot: true,
                    )
                  else
                    const OPill(label: 'Paused'),
                ],
              ),
            ),
            Container(
              width: double.infinity,
              color: c.codeBg,
              padding: const EdgeInsets.all(OSpace.m),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < data.logLines.length; i++) ...[
                    _LogLine(line: data.logLines[i]),
                    if (i < data.logLines.length - 1)
                      const SizedBox(height: OSpace.s),
                  ],
                  if (data.logLines.isEmpty)
                    Text(
                      'Waiting for the first line…',
                      style: OType.mono.copyWith(color: c.textFaint),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(OSpace.m),
              child: OButton(
                label: 'View full log (${data.totalLogLines} lines)',
                icon: Icons.open_in_new_rounded,
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: onViewLog,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({required this.line});

  final V2SubagentLogLine line;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final color = switch (line.tone) {
      V2SubagentLogTone.normal => c.textMuted,
      V2SubagentLogTone.success => c.success,
      V2SubagentLogTone.accent => c.accent,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('[${line.time}]', style: OType.mono.copyWith(color: c.textFaint)),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Text(line.text, style: OType.mono.copyWith(color: color)),
        ),
      ],
    );
  }
}
