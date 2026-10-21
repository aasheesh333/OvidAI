import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

enum V2SchedulesStatus { loading, content, empty, error }

@immutable
class V2ScheduleItem {
  const V2ScheduleItem({
    required this.id,
    required this.title,
    required this.description,
    required this.rule,
    this.nextRun,
    this.enabled = true,
    this.lastRunFailed = false,
    this.failureMessage,
  });

  final String id;
  final String title;
  final String description;

  /// Plain-English rule, e.g. "Every weekday at 9:00 AM".
  final String rule;

  /// Plain-English next run, e.g. "Tomorrow, 9:00 AM".
  final String? nextRun;
  final bool enabled;
  final bool lastRunFailed;
  final String? failureMessage;
}

@immutable
class V2SchedulesData {
  const V2SchedulesData({
    this.status = V2SchedulesStatus.content,
    this.schedules = const <V2ScheduleItem>[],
    this.errorMessage = 'We could not load your schedules. Check your connection and try again.',
  });

  final V2SchedulesStatus status;
  final List<V2ScheduleItem> schedules;
  final String errorMessage;
}

/// All of the user's recurring tasks, with a plain-English rule per card.
class SchedulesPage extends StatelessWidget {
  const SchedulesPage({
    super.key,
    required this.data,
    this.onScheduleTap,
    this.onScheduleMenu,
    this.onToggle,
    this.onRetryRun,
    this.onCreate,
    this.onRetry,
    this.onMore,
  });

  final V2SchedulesData data;
  final ValueChanged<V2ScheduleItem>? onScheduleTap;
  final ValueChanged<V2ScheduleItem>? onScheduleMenu;
  final void Function(V2ScheduleItem schedule, bool enabled)? onToggle;
  final ValueChanged<V2ScheduleItem>? onRetryRun;
  final VoidCallback? onCreate;
  final VoidCallback? onRetry;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OScaffold(
      appBar: OAppBar(
        title: 'Schedules',
        actions: [
          OIconButton(
            icon: Icons.more_vert_rounded,
            semanticLabel: 'More options',
            onPressed: onMore,
          ),
        ],
      ),
      body: OFadeSlide(
        child: OAnimatedSwap(
          child: switch (data.status) {
            V2SchedulesStatus.loading => const OSkeletonList(rows: 5),
            V2SchedulesStatus.error => OErrorState(
              message: data.errorMessage,
              onRetry: onRetry,
            ),
            V2SchedulesStatus.empty => _empty(c),
            V2SchedulesStatus.content => data.schedules.isEmpty
                ? _empty(c)
                : _content(c),
          },
        ),
      ),
    );
  }

  Widget _empty(OColors c) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xxl,
      ),
      children: [
        _explainer(c),
        const SizedBox(height: OSpace.xl),
        OEmptyState(
          icon: Icons.calendar_month_rounded,
          title: 'No schedules yet',
          message:
              'Ovid can work while you sleep. Set a task to run on its own, and the result will be waiting for you.',
          action: OButton(
            label: 'Create a schedule',
            icon: Icons.add_rounded,
            onPressed: onCreate,
          ),
        ),
      ],
    );
  }

  Widget _content(OColors c) {
    final active = data.schedules.where((s) => s.enabled).length;
    final rules = data.schedules.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xxl,
      ),
      children: [
        _explainer(c),
        const SizedBox(height: OSpace.l),
        OSectionHeader(
          label: 'Active schedules ($active)',
          padding: EdgeInsets.zero,
          trailing: Text(
            '$rules total ${rules == 1 ? 'rule' : 'rules'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ),
        const SizedBox(height: OSpace.m),
        OStagger(
          children: [
            for (final schedule in data.schedules) _card(c, schedule),
          ],
        ),
      ],
    );
  }

  Widget _explainer(OColors c) {
    return OCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(ORadius.m),
            ),
            child: Icon(
              Icons.notifications_active_rounded,
              size: 20,
              color: c.accent,
            ),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ovid can work while you sleep',
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
                const SizedBox(height: OSpace.xs),
                Text(
                  'Runs a task on a schedule, browses or writes code, and tells you when it is done.',
                  style: OType.bodySm.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(OColors c, V2ScheduleItem schedule) {
    final onTap = onScheduleTap;
    final onMenu = onScheduleMenu;
    final onToggleSchedule = onToggle;
    final onRetry = onRetryRun;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.m),
      child: OCard(
        onTap: onTap == null ? null : () => onTap(schedule),
        semanticLabel: '${schedule.title}. ${schedule.rule}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _status(c, schedule),
                      const SizedBox(height: OSpace.xs),
                      Text(
                        schedule.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: OType.bodyStrong.copyWith(color: c.text),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        schedule.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: OType.bodySm.copyWith(color: c.textMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: OSpace.s),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MergeSemantics(
                      child: Semantics(
                        label: 'Turn ${schedule.title} on or off',
                        toggled: schedule.enabled,
                        enabled: onToggleSchedule != null,
                        child: Switch(
                          value: schedule.enabled,
                          onChanged: onToggleSchedule == null
                              ? null
                              : (value) => onToggleSchedule(schedule, value),
                          thumbColor: WidgetStateProperty.resolveWith(
                            (states) => states.contains(WidgetState.disabled)
                                ? c.textFaint
                                : (schedule.enabled
                                      ? c.onAccent
                                      : c.textFaint),
                          ),
                          trackColor: WidgetStateProperty.resolveWith(
                            (states) =>
                                states.contains(WidgetState.disabled) ||
                                    !schedule.enabled
                                ? c.surfaceRaised
                                : c.accentFill,
                          ),
                          trackOutlineColor: WidgetStatePropertyAll(
                            c.hairlineStrong,
                          ),
                        ),
                      ),
                    ),
                    OIconButton(
                      icon: Icons.more_vert_rounded,
                      semanticLabel: 'More options for ${schedule.title}',
                      size: 18,
                      onPressed: onMenu == null
                          ? null
                          : () => onMenu(schedule),
                    ),
                  ],
                ),
              ],
            ),
            if (schedule.rule.isNotEmpty) ...[
              const SizedBox(height: OSpace.m),
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
                        Icon(
                          Icons.schedule_rounded,
                          size: 16,
                          color: c.accent,
                        ),
                        const SizedBox(width: OSpace.s),
                        Expanded(
                          child: Text(
                            schedule.rule,
                            style: OType.bodySm.copyWith(color: c.text),
                          ),
                        ),
                      ],
                    ),
                    if (schedule.enabled && schedule.nextRun != null) ...[
                      const SizedBox(height: OSpace.s),
                      Row(
                        children: [
                          Icon(
                            Icons.update_rounded,
                            size: 16,
                            color: c.success,
                          ),
                          const SizedBox(width: OSpace.s),
                          Expanded(
                            child: Text(
                              schedule.nextRun!,
                              style: OType.caption.copyWith(
                                color: c.success,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
            if (schedule.lastRunFailed) ...[
              const SizedBox(height: OSpace.m),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(OSpace.m),
                decoration: BoxDecoration(
                  color: c.danger.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(ORadius.m),
                  border: Border.all(
                    color: c.danger.withValues(alpha: 0.30),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.error_outline_rounded,
                          size: 18,
                          color: c.danger,
                        ),
                        const SizedBox(width: OSpace.s),
                        Expanded(
                          child: Text(
                            schedule.failureMessage ??
                                'Last run failed. Your rule is still saved.',
                            style: OType.caption.copyWith(color: c.danger),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: OSpace.s),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: OButton(
                        label: 'Retry',
                        variant: OButtonVariant.danger,
                        onPressed: onRetry == null
                            ? null
                            : () => onRetry(schedule),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _status(OColors c, V2ScheduleItem schedule) {
    if (schedule.lastRunFailed) {
      return _statusLine(c, c.danger, 'Action needed');
    }
    if (!schedule.enabled) {
      return const OPill(label: 'Paused');
    }
    return _statusLine(c, c.success, 'Running active');
  }

  Widget _statusLine(OColors c, Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: OSpace.xs),
        Flexible(
          child: Text(
            label,
            style: OType.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
