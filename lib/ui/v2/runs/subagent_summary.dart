import 'dart:convert';

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): extract this card's English copy during the ARB pass.

/// Load state for [SubagentSummaryCard].
enum V2SubagentSummaryStatus { loading, empty, error, ready }

/// Every key in the subagent's strict five-key contract.
const Set<String> v2SubagentSummaryKeys = {
  'status',
  'files_modified',
  'artifacts_created',
  'key_findings',
  'error_if_any',
};

/// The strict five-key JSON object a subagent returns to the main agent.
///
/// The keys match the runtime contract exactly:
/// `{status, files_modified, artifacts_created, key_findings, error_if_any}`.
/// Nothing is added or renamed, so [json] is what the main agent received.
///
/// [reported] lists the keys the run actually supplied. A key that was absent
/// is rendered as "Not reported" rather than as an empty value, so the screen
/// never claims a subagent reported "no files" when it said nothing at all.
@immutable
class V2SubagentSummaryData {
  const V2SubagentSummaryData({
    this.status = '',
    this.filesModified = const [],
    this.artifactsCreated = const [],
    this.keyFindings = const [],
    this.errorIfAny,
    this.reported = v2SubagentSummaryKeys,
  });

  /// One of the runtime terminal states: `completed`, `failed`, `cancelled`
  /// or `timeout`. Kept as a string so unusual server wording is never lost.
  final String status;

  final List<String> filesModified;
  final List<String> artifactsCreated;
  final List<String> keyFindings;

  /// The failure message, or null when the run reported no error.
  final String? errorIfAny;

  /// Contract keys the run supplied. Missing keys are never filled in.
  final Set<String> reported;

  bool hasField(String key) => reported.contains(key);

  bool get hasStatus => hasField('status') && status.trim().isNotEmpty;

  /// True when [errorIfAny] carries something worth showing.
  bool get hasError => (errorIfAny ?? '').trim().isNotEmpty;

  /// The exact JSON the subagent returned, pretty-printed for display.
  ///
  /// Only reported keys are emitted, so the raw view cannot invent a field.
  String get json => const JsonEncoder.withIndent('  ').convert({
    if (hasField('status')) 'status': status,
    if (hasField('files_modified')) 'files_modified': filesModified,
    if (hasField('artifacts_created')) 'artifacts_created': artifactsCreated,
    if (hasField('key_findings')) 'key_findings': keyFindings,
    if (hasField('error_if_any')) 'error_if_any': errorIfAny,
  });
}

/// Renders one subagent's strict five-field summary as five compact rows.
///
/// Presentational: the parent injects the already-decoded [summary] plus the
/// callbacks. A null [summary] with [V2SubagentSummaryStatus.ready] is treated
/// as empty.
class SubagentSummaryCard extends StatelessWidget {
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

  /// Retained for callers that used to reveal raw JSON. The minimal card shows
  /// the five fields only.
  final bool initiallyRaw;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final data = summary;
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Summary',
                  style: OType.bodySm.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (status == V2SubagentSummaryStatus.ready &&
                  data?.hasStatus == true)
                OPill(
                  label: _statusLabel(data!.status),
                  tone: _statusTone(data.status),
                ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          switch (status) {
            V2SubagentSummaryStatus.loading => const _SummarySkeleton(),
            V2SubagentSummaryStatus.error => _Notice(
              message: errorMessage,
              danger: true,
              onRetry: onRetry,
            ),
            V2SubagentSummaryStatus.empty => _Notice(
              message: 'No summary yet',
              onRetry: onRetry,
            ),
            V2SubagentSummaryStatus.ready => _fields(
              context,
              data ?? const V2SubagentSummaryData(),
            ),
          },
        ],
      ),
    );
  }

  Widget _fields(BuildContext context, V2SubagentSummaryData data) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Field(
          label: 'Status',
          child: Text(
            data.hasStatus ? _statusLabel(data.status) : _notReported,
            style: OType.bodySm.copyWith(
              color: OColors.of(context).text,
            ),
          ),
        ),
        _Field(
          label: 'Files modified',
          child: !data.hasField('files_modified')
              ? const _None(label: _notReported)
              : data.filesModified.isEmpty
              ? const _None(label: 'None')
              : Wrap(
                  spacing: OSpace.s,
                  runSpacing: OSpace.s,
                  children: [
                    for (final file in data.filesModified)
                      OChip(
                        label: file,
                        icon: Icons.code_rounded,
                        semanticLabel: onFileTap == null
                            ? 'file $file'
                            : 'Open file $file',
                        onTap: onFileTap == null
                            ? null
                            : () => onFileTap!(file),
                      ),
                  ],
                ),
        ),
        _Field(
          label: 'Artifacts created',
          child: !data.hasField('artifacts_created')
              ? const _None(label: _notReported)
              : data.artifactsCreated.isEmpty
              ? const _None(label: 'None')
              : Wrap(
                  spacing: OSpace.s,
                  runSpacing: OSpace.s,
                  children: [
                    for (final artifact in data.artifactsCreated)
                      OChip(
                        label: artifact,
                        icon: Icons.insert_drive_file_outlined,
                        semanticLabel: onArtifactTap == null
                            ? 'artifact $artifact'
                            : 'Open artifact $artifact',
                        onTap: onArtifactTap == null
                            ? null
                            : () => onArtifactTap!(artifact),
                      ),
                  ],
                ),
        ),
        _Field(
          label: 'Key findings',
          child: !data.hasField('key_findings')
              ? const _None(label: _notReported)
              : data.keyFindings.isEmpty
              ? const _None(label: 'None')
              : _Findings(findings: data.keyFindings),
        ),
        _Field(
          label: 'Error if any',
          last: true,
          child: !data.hasField('error_if_any')
              ? const _None(label: _notReported)
              : data.hasError
              ? Text(
                  data.errorIfAny!.trim(),
                  style: OType.bodySm.copyWith(
                    color: OColors.of(context).danger,
                  ),
                )
              : const _None(label: 'None'),
        ),
      ],
    );
  }
}

const String _notReported = 'Not reported';

/// One contract field: a quiet label over its value.
class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.child,
    this.last = false,
  });

  final String label;
  final Widget child;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: OSpace.s),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: OType.overline.copyWith(color: c.textFaint),
              ),
              const SizedBox(height: OSpace.xs),
              child,
            ],
          ),
        ),
        if (!last) Divider(height: 1, color: c.hairline),
      ],
    );
  }
}


class _Findings extends StatelessWidget {
  const _Findings({required this.findings});

  final List<String> findings;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
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
                  style: OType.bodySm.copyWith(color: c.accent),
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
          if (i < findings.length - 1) const SizedBox(height: OSpace.xs),
        ],
      ],
    );
  }
}

class _None extends StatelessWidget {
  const _None({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: OType.caption.copyWith(color: OColors.of(context).textMuted),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.message,
    this.onRetry,
    this.danger = false,
  });

  final String message;
  final VoidCallback? onRetry;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            message,
            style: OType.bodySm.copyWith(
              color: danger ? c.danger : c.textMuted,
            ),
          ),
        ),
        if (onRetry != null)
          OTextAction(label: 'Retry', onPressed: onRetry),
      ],
    );
  }
}

class _SummarySkeleton extends StatelessWidget {
  const _SummarySkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        OSkeleton(width: 96, height: 10),
        SizedBox(height: OSpace.s),
        OSkeleton(width: double.infinity, height: 14),
        SizedBox(height: OSpace.l),
        OSkeleton(width: 120, height: 10),
        SizedBox(height: OSpace.s),
        OSkeleton(width: double.infinity, height: 14),
        SizedBox(height: OSpace.l),
        OSkeleton(width: 80, height: 10),
        SizedBox(height: OSpace.s),
        OSkeleton(width: 220, height: 14),
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
