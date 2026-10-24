import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/cloud/trajectory_projection.dart';
import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): extract this card's English copy during the ARB pass.

/// Load state for [SubagentSummaryCard].
enum V2SubagentSummaryStatus { loading, empty, error, ready }

/// The visible mark for a contract value the run never supplied.
///
/// Missing is missing: the card shows this dash, never a guess and never a
/// sentence that pretends the subagent reported an empty list.
const String v2SubagentMissingValue = '—';

/// How a missing contract value is read aloud. The dash itself is not spoken.
const String v2SubagentNotReported = 'Not reported';

/// A run's real state.
///
/// [unknown] is a state, not a placeholder: a run that has not reported a
/// terminal status is never treated as [completed].
enum V2SubagentRunStatus {
  unknown,
  running,
  completed,
  failed,
  cancelled,
  timedOut,
}

/// Maps the runtime's status wording onto [V2SubagentRunStatus].
///
/// Only wording the runtime can actually emit is mapped; anything else stays
/// [V2SubagentRunStatus.unknown] so it can be shown verbatim.
V2SubagentRunStatus v2SubagentRunStatusOf(String? raw) {
  return switch ((raw ?? '').trim().toLowerCase()) {
    'completed' || 'success' || 'succeeded' => V2SubagentRunStatus.completed,
    'failed' || 'failure' || 'error' => V2SubagentRunStatus.failed,
    'cancelled' || 'canceled' || 'stopped' => V2SubagentRunStatus.cancelled,
    'timeout' || 'timed_out' || 'timed out' => V2SubagentRunStatus.timedOut,
    'running' ||
    'working' ||
    'in progress' ||
    'in_progress' => V2SubagentRunStatus.running,
    _ => V2SubagentRunStatus.unknown,
  };
}

/// The one visible label for a run status.
String v2SubagentRunStatusLabel(V2SubagentRunStatus status) {
  return switch (status) {
    V2SubagentRunStatus.unknown => v2SubagentMissingValue,
    V2SubagentRunStatus.running => 'Running',
    V2SubagentRunStatus.completed => 'Completed',
    V2SubagentRunStatus.failed => 'Failed',
    V2SubagentRunStatus.cancelled => 'Cancelled',
    V2SubagentRunStatus.timedOut => 'Timed out',
  };
}

/// Label for a status string as the runtime reported it.
///
/// Contract wording is normalised; unusual wording is shown verbatim rather
/// than replaced, because it is real data. An absent status reads as a dash.
String v2SubagentReportedStatusLabel(String? raw) {
  final text = (raw ?? '').trim();
  if (text.isEmpty) return v2SubagentMissingValue;
  final status = v2SubagentRunStatusOf(text);
  return status == V2SubagentRunStatus.unknown
      ? text
      : v2SubagentRunStatusLabel(status);
}

/// Colour tone for a run status: success green, failure red, timeout amber,
/// cancellation neutral, matching the run timeline.
OPillTone v2SubagentRunStatusTone(V2SubagentRunStatus status) {
  return switch (status) {
    V2SubagentRunStatus.completed => OPillTone.success,
    V2SubagentRunStatus.failed => OPillTone.danger,
    V2SubagentRunStatus.timedOut => OPillTone.warn,
    V2SubagentRunStatus.running => OPillTone.accent,
    V2SubagentRunStatus.cancelled ||
    V2SubagentRunStatus.unknown => OPillTone.neutral,
  };
}

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
/// renders as [v2SubagentMissingValue] rather than as an empty value, so the
/// screen never claims a subagent reported "no files" when it said nothing at
/// all.
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

/// Renders one subagent's strict five-field summary.
///
/// Presentational: the parent injects the already-decoded [summary] plus the
/// callbacks. A null [summary] in [V2SubagentSummaryStatus.ready] is treated as
/// empty, never as five blank fields.
class SubagentSummaryCard extends StatelessWidget {
  const SubagentSummaryCard({
    super.key,
    this.summary,
    this.status = V2SubagentSummaryStatus.ready,
    this.showStatus = true,
    this.onFileTap,
    this.onArtifactTap,
    this.onRetry,
    this.errorMessage = 'We could not load the summary.',
  });

  final V2SubagentSummaryData? summary;
  final V2SubagentSummaryStatus status;

  /// Whether the card renders the contract's Status field.
  ///
  /// The subagent screen shows the live run status itself (it also has a real
  /// status before any summary exists), so it turns this copy off and the
  /// status is never read twice.
  final bool showStatus;

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

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final data = summary;
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Summary',
            style: OType.bodySm.copyWith(
              color: c.text,
              fontWeight: FontWeight.w600,
            ),
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
            V2SubagentSummaryStatus.ready =>
              data == null
                  ? _Notice(message: 'No summary yet', onRetry: onRetry)
                  : _fields(context, data),
          },
        ],
      ),
    );
  }

  Widget _fields(BuildContext context, V2SubagentSummaryData data) {
    final c = OColors.of(context);
    final statusLabel = v2SubagentReportedStatusLabel(data.status);
    final findings = data.hasField('key_findings')
        ? data.keyFindings
        : const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showStatus)
          _Field(
            label: 'Status',
            valueLabel: data.hasStatus ? statusLabel : v2SubagentNotReported,
            child: data.hasStatus
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: OPill(
                      label: statusLabel,
                      tone: v2SubagentRunStatusTone(
                        v2SubagentRunStatusOf(data.status),
                      ),
                    ),
                  )
                : const _ValueText(v2SubagentMissingValue),
          ),
        _Field(
          label: 'Files modified',
          valueLabel: !data.hasField('files_modified')
              ? v2SubagentNotReported
              : data.filesModified.isEmpty
              ? 'None'
              : null,
          child: !data.hasField('files_modified')
              ? const _ValueText(v2SubagentMissingValue)
              : data.filesModified.isEmpty
              ? const _ValueText('None')
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
          valueLabel: !data.hasField('artifacts_created')
              ? v2SubagentNotReported
              : data.artifactsCreated.isEmpty
              ? 'None'
              : null,
          child: !data.hasField('artifacts_created')
              ? const _ValueText(v2SubagentMissingValue)
              : data.artifactsCreated.isEmpty
              ? const _ValueText('None')
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
          valueLabel: !data.hasField('key_findings')
              ? v2SubagentNotReported
              : findings.isEmpty
              ? 'None'
              : null,
          child: !data.hasField('key_findings')
              ? const _ValueText(v2SubagentMissingValue)
              : findings.isEmpty
              ? const _ValueText('None')
              : _Findings(findings: findings),
        ),
        _Field(
          label: 'Error if any',
          last: true,
          valueLabel: !data.hasField('error_if_any')
              ? v2SubagentNotReported
              : data.hasError
              ? data.errorIfAny!.trim()
              : 'None',
          child: !data.hasField('error_if_any')
              ? const _ValueText(v2SubagentMissingValue)
              : data.hasError
              ? Text(
                  data.errorIfAny!.trim(),
                  style: OType.bodySm.copyWith(color: c.danger),
                )
              : const _ValueText('None'),
        ),
      ],
    );
  }
}

/// Read-only presentation of the canonical six-key §6.3 report. This is kept
/// separate from the legacy five-field preview card so a legacy list-shaped
/// `key_findings` value can never be mistaken for the canonical string.
class TrajectoryReportCard extends StatelessWidget {
  const TrajectoryReportCard({super.key, required this.report});

  final TrajectoryReport report;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    Widget label(String text) =>
        Text(text, style: OType.overline.copyWith(color: c.textFaint));
    Widget value(String text, {bool mono = false, Color? color}) => Text(
      text,
      style: (mono ? OType.mono : OType.bodySm).copyWith(
        color: color ?? c.text,
      ),
    );
    Widget field(String name, Widget child) => Padding(
      padding: const EdgeInsets.only(bottom: OSpace.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          label(name),
          const SizedBox(height: OSpace.xs),
          child,
        ],
      ),
    );

    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Canonical report',
            style: OType.bodySm.copyWith(
              color: c.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: OSpace.m),
          field('SUBAGENT ID', value(report.subagentId, mono: true)),
          field('STATUS', value(v2SubagentReportedStatusLabel(report.status))),
          field(
            'FILES MODIFIED',
            value(
              report.filesModified.isEmpty
                  ? 'None'
                  : report.filesModified.join(', '),
              mono: true,
            ),
          ),
          field(
            'ARTIFACTS CREATED',
            value(
              report.artifactsCreated.isEmpty
                  ? 'None'
                  : report.artifactsCreated.join(', '),
              mono: true,
            ),
          ),
          field('KEY FINDINGS', value(report.keyFindings)),
          field(
            'ERROR IF ANY',
            value(
              report.errorIfAny?.trim().isNotEmpty ?? false
                  ? report.errorIfAny!.trim()
                  : 'None',
              color: report.errorIfAny?.trim().isNotEmpty ?? false
                  ? c.danger
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// One contract field: a quiet label over its value.
///
/// When [valueLabel] is set the field is a single accessibility node reading
/// "label: value". Fields whose value is a control (a file chip) leave it null
/// so the chip keeps its own tap target.
class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.child,
    this.valueLabel,
    this.last = false,
  });

  final String label;
  final Widget child;
  final String? valueLabel;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final body = Padding(
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
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (valueLabel == null)
          body
        else
          Semantics(
            container: true,
            label: '$label: $valueLabel',
            excludeSemantics: true,
            child: body,
          ),
        if (!last) Divider(height: 1, color: c.hairline),
      ],
    );
  }
}

/// Long findings are previewed at three lines; the full text is one tap away.
class _Findings extends StatefulWidget {
  const _Findings({required this.findings});

  final List<String> findings;

  @override
  State<_Findings> createState() => _FindingsState();
}

class _FindingsState extends State<_Findings> {
  /// Above this length a finding is previewed instead of printed whole.
  static const int _previewChars = 160;

  final Set<int> _expanded = <int>{};

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < widget.findings.length; i++) ...[
          _finding(context, c, i, widget.findings[i]),
          if (i < widget.findings.length - 1) const SizedBox(height: OSpace.s),
        ],
      ],
    );
  }

  Widget _finding(BuildContext context, OColors c, int index, String finding) {
    final expanded = _expanded.contains(index);
    final capped =
        finding.length > _previewChars || '\n'.allMatches(finding).length >= 3;
    final collapsed = capped && !expanded;
    final text = Text(
      finding,
      maxLines: collapsed ? 3 : null,
      overflow: collapsed ? TextOverflow.ellipsis : TextOverflow.clip,
      style: OType.bodySm.copyWith(color: c.text),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Text('•', style: OType.bodySm.copyWith(color: c.accent)),
        ),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (collapsed)
                Semantics(
                  // The preview is visual only: a screen reader gets the whole
                  // finding, not the three-line cut.
                  label: finding,
                  excludeSemantics: true,
                  child: text,
                )
              else
                text,
              if (capped)
                OTextAction(
                  label: expanded ? 'Show less' : 'Show more',
                  onPressed: () => setState(() {
                    if (expanded) {
                      _expanded.remove(index);
                    } else {
                      _expanded.add(index);
                    }
                  }),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ValueText extends StatelessWidget {
  const _ValueText(this.label);

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
  const _Notice({required this.message, this.onRetry, this.danger = false});

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
        if (onRetry != null) OTextAction(label: 'Retry', onPressed: onRetry),
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
