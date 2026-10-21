import 'dart:convert';

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): extract this card's English copy during the ARB pass.

/// Load state for [SubagentSummaryCard].
enum V2SubagentSummaryStatus { loading, empty, error, ready }

/// The strict five-key JSON object a subagent returns to the main agent.
///
/// The keys match the runtime contract exactly:
/// `{status, files_modified, artifacts_created, key_findings, error_if_any}`.
/// Nothing is added or renamed, so [json] is what the main agent received.
@immutable
class V2SubagentSummaryData {
  const V2SubagentSummaryData({
    this.status = '',
    this.filesModified = const [],
    this.artifactsCreated = const [],
    this.keyFindings = const [],
    this.errorIfAny,
  });

  /// One of the runtime terminal states: `completed`, `failed`, `cancelled`
  /// or `timeout`. Kept as a string so unusual server wording is never lost.
  final String status;

  final List<String> filesModified;
  final List<String> artifactsCreated;
  final List<String> keyFindings;

  /// The failure message, or null when the run reported no error.
  final String? errorIfAny;

  /// True when [errorIfAny] carries something worth showing.
  bool get hasError => (errorIfAny ?? '').trim().isNotEmpty;

  /// The exact JSON the subagent returned, pretty-printed for display.
  String get json => const JsonEncoder.withIndent('  ').convert({
    'status': status,
    'files_modified': filesModified,
    'artifacts_created': artifactsCreated,
    'key_findings': keyFindings,
    'error_if_any': errorIfAny,
  });
}

/// Renders one subagent's strict JSON summary.
///
/// Presentational: the parent injects the already-decoded [summary] plus the
/// callbacks. The card owns only the raw-JSON reveal, which starts closed.
/// A null [summary] with [V2SubagentSummaryStatus.ready] is treated as empty.
class SubagentSummaryCard extends StatefulWidget {
  const SubagentSummaryCard({
    super.key,
    this.summary,
    this.status = V2SubagentSummaryStatus.ready,
    this.onFileTap,
    this.onArtifactTap,
    this.onRetry,
    this.errorMessage = 'We could not load the summary.',
    this.initiallyRaw = false,
  });

  final V2SubagentSummaryData? summary;
  final V2SubagentSummaryStatus status;

  /// Opens a modified file. Chips are only announced as buttons when this is
  /// non-null.
  final ValueChanged<String>? onFileTap;

  /// Opens a created artifact. Chips are only announced as buttons when this
  /// is non-null.
  final ValueChanged<String>? onArtifactTap;

  /// Reloads the summary for the error state, or checks again for the empty
  /// state.
  final VoidCallback? onRetry;

  final String errorMessage;

  /// Starts with the raw JSON visible. Only used by galleries and tests; the
  /// product default keeps raw JSON behind the toggle.
  final bool initiallyRaw;

  @override
  State<SubagentSummaryCard> createState() => _SubagentSummaryCardState();
}

class _SubagentSummaryCardState extends State<SubagentSummaryCard> {
  late bool _raw = widget.initiallyRaw;

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(
            status: widget.status == V2SubagentSummaryStatus.ready
                ? summary?.status
                : null,
          ),
          const SizedBox(height: OSpace.m),
          switch (widget.status) {
            V2SubagentSummaryStatus.loading => const _SummarySkeleton(),
            V2SubagentSummaryStatus.error => _SummaryNotice(
              icon: Icons.error_outline_rounded,
              danger: true,
              title: widget.errorMessage,
              message:
                  'The subagent may still be finishing. Try again in a moment.',
              action: OButton(
                label: 'Try again',
                icon: Icons.refresh_rounded,
                expand: true,
                onPressed: widget.onRetry,
              ),
            ),
            V2SubagentSummaryStatus.empty => _SummaryNotice(
              icon: Icons.inbox_outlined,
              title: 'No summary yet',
              message: 'A subagent sends its JSON summary when it finishes.',
              action: OButton(
                label: 'Check again',
                icon: Icons.refresh_rounded,
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: widget.onRetry,
              ),
            ),
            V2SubagentSummaryStatus.ready => _content(
              context,
              summary ?? const V2SubagentSummaryData(),
            ),
          },
        ],
      ),
    );
  }

  Widget _content(BuildContext context, V2SubagentSummaryData summary) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What the subagent returned to the main agent.',
          style: OType.caption.copyWith(color: c.textMuted),
        ),
        const SizedBox(height: OSpace.m),
        _Section(
          title: 'Files modified',
          meta: summary.filesModified.length == 1
              ? '1 file'
              : '${summary.filesModified.length} files',
          child: summary.filesModified.isEmpty
              ? _None(message: 'No files modified.')
              : Wrap(
                  spacing: OSpace.s,
                  runSpacing: OSpace.s,
                  children: [
                    for (final file in summary.filesModified)
                      _SummaryChip(
                        label: file,
                        icon: Icons.code_rounded,
                        semanticNoun: 'file',
                        onTap: widget.onFileTap == null
                            ? null
                            : () => widget.onFileTap!(file),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: OSpace.m),
        _Section(
          title: 'Artifacts created',
          meta: summary.artifactsCreated.length == 1
              ? '1 artifact'
              : '${summary.artifactsCreated.length} artifacts',
          child: summary.artifactsCreated.isEmpty
              ? _None(message: 'No artifacts created.')
              : Wrap(
                  spacing: OSpace.s,
                  runSpacing: OSpace.s,
                  children: [
                    for (final artifact in summary.artifactsCreated)
                      _SummaryChip(
                        label: artifact,
                        icon: Icons.insert_drive_file_outlined,
                        semanticNoun: 'artifact',
                        onTap: widget.onArtifactTap == null
                            ? null
                            : () => widget.onArtifactTap!(artifact),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: OSpace.m),
        _Section(
          title: 'Key findings',
          meta: summary.keyFindings.length == 1
              ? '1 finding'
              : '${summary.keyFindings.length} findings',
          child: _Findings(findings: summary.keyFindings),
        ),
        const SizedBox(height: OSpace.m),
        _Section(
          title: 'Error if any',
          child: summary.hasError
              ? _ErrorBox(message: summary.errorIfAny!.trim())
              : _None(message: 'No error reported.'),
        ),
        const SizedBox(height: OSpace.m),
        OButton(
          label: _raw ? 'Hide raw JSON' : 'Show raw JSON',
          icon: _raw ? Icons.code_off_rounded : Icons.code_rounded,
          variant: OButtonVariant.ghost,
          expand: true,
          onPressed: () => setState(() => _raw = !_raw),
        ),
        if (_raw) ...[
          const SizedBox(height: OSpace.s),
          OFadeSlide(
            delay: const Duration(milliseconds: 1),
            child: _RawJson(json: summary.json),
          ),
        ],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({this.status});

  /// Null while loading or when the summary has not arrived.
  final String? status;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Wrap(
      spacing: OSpace.s,
      runSpacing: OSpace.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ExcludeSemantics(
          child: Icon(Icons.data_object_rounded, size: 18, color: c.accent),
        ),
        Text(
          'JSON summary',
          style: OType.bodySm.copyWith(
            color: c.text,
            fontWeight: FontWeight.w600,
          ),
        ),
        const OPill(label: '≤300 tokens'),
        if (status != null)
          Semantics(
            label: 'Status: ${_statusLabel(status!)}',
            child: ExcludeSemantics(
              child: OPill(
                label: _statusLabel(status!),
                tone: _statusTone(status!),
              ),
            ),
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.meta});

  final String title;
  final String? meta;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: OSpace.s,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              title.toUpperCase(),
              style: OType.overline.copyWith(color: c.textFaint),
            ),
            if (meta != null)
              Text(meta!, style: OType.caption.copyWith(color: c.textFaint)),
          ],
        ),
        const SizedBox(height: OSpace.s),
        child,
      ],
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({
    required this.label,
    required this.icon,
    required this.semanticNoun,
    this.onTap,
  });

  final String label;
  final IconData icon;

  /// "file" or "artifact", used only for the semantic label.
  final String semanticNoun;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final content = Container(
      constraints: const BoxConstraints(minHeight: OSpace.touch),
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.s,
        vertical: OSpace.xs,
      ),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(ORadius.s),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(child: Icon(icon, size: 14, color: c.accent)),
          const SizedBox(width: OSpace.xs),
          Flexible(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: OType.mono.copyWith(color: c.textMuted),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) {
      return Semantics(label: '$semanticNoun $label', child: content);
    }
    return OPressable(
      onTap: onTap,
      semanticLabel: 'Open $semanticNoun $label',
      child: content,
    );
  }
}

class _Findings extends StatelessWidget {
  const _Findings({required this.findings});

  final List<String> findings;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    if (findings.isEmpty) return _None(message: 'No findings reported.');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < findings.length; i++) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Text(
                  '•',
                  style: OType.bodySm.copyWith(
                    color: c.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  findings[i],
                  style: OType.bodySm.copyWith(color: c.text),
                ),
              ),
            ],
          ),
          if (i < findings.length - 1) const SizedBox(height: OSpace.s),
        ],
      ],
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      container: true,
      label: 'Error: $message',
      child: ExcludeSemantics(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(OSpace.m),
          decoration: BoxDecoration(
            color: c.danger.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(ORadius.m),
            border: Border.all(color: c.danger.withValues(alpha: 0.3)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Icon(
                  Icons.error_outline_rounded,
                  size: 16,
                  color: c.danger,
                ),
              ),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  message,
                  style: OType.bodySm.copyWith(color: c.danger),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _None extends StatelessWidget {
  const _None({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Text(message, style: OType.caption.copyWith(color: c.textMuted));
  }
}

class _RawJson extends StatelessWidget {
  const _RawJson({required this.json});

  final String json;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.codeBg,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: SelectionArea(
        child: Text(json, style: OType.mono.copyWith(color: c.textMuted)),
      ),
    );
  }
}

class _SummaryNotice extends StatelessWidget {
  const _SummaryNotice({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final accent = danger ? c.danger : c.accent;
    return Container(
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Icon(icon, size: 19, color: accent),
              ),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    title,
                    style: OType.bodySm.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          Text(message, style: OType.caption.copyWith(color: c.textMuted)),
          if (action != null) ...[const SizedBox(height: OSpace.m), action!],
        ],
      ),
    );
  }
}

class _SummarySkeleton extends StatelessWidget {
  const _SummarySkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const OSkeleton(width: 96, height: 10),
        const SizedBox(height: OSpace.s),
        const OSkeleton(width: double.infinity, height: 48, radius: ORadius.s),
        const SizedBox(height: OSpace.m),
        const OSkeleton(width: 120, height: 10),
        const SizedBox(height: OSpace.s),
        const OSkeleton(width: double.infinity, height: 48, radius: ORadius.s),
        const SizedBox(height: OSpace.m),
        const OSkeleton(width: 80, height: 10),
        const SizedBox(height: OSpace.s),
        const OSkeleton(width: double.infinity, height: 14),
        const SizedBox(height: OSpace.s),
        const OSkeleton(width: 220, height: 14),
      ],
    );
  }
}

/// Plain-language label for the runtime's terminal status.
String _statusLabel(String status) {
  final raw = status.trim();
  return switch (raw.toLowerCase()) {
    'completed' => 'Completed',
    'failed' => 'Failed',
    'cancelled' || 'canceled' => 'Cancelled',
    'timeout' || 'timed_out' || 'timed out' => 'Timed out',
    'running' => 'Running',
    '' => 'No status',
    _ => raw,
  };
}

/// Colour tone for the status pill. Successful runs are green, failures red,
/// timeouts amber and cancellations neutral, matching the run timeline.
OPillTone _statusTone(String status) {
  final raw = status.trim().toLowerCase();
  if (raw == 'completed' || raw == 'success' || raw == 'succeeded') {
    return OPillTone.success;
  }
  if (raw == 'failed' || raw == 'failure' || raw == 'error') {
    return OPillTone.danger;
  }
  if (raw == 'timeout' || raw == 'timed_out' || raw == 'timed out') {
    return OPillTone.warn;
  }
  if (raw == 'running' || raw == 'working') return OPillTone.accent;
  return OPillTone.neutral;
}
