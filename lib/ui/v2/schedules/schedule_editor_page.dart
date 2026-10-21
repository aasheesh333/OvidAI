import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

enum V2ScheduleEditorStatus { loading, content, error, missing }

enum V2ScheduleFrequency { once, daily, weekly, custom }

@immutable
class V2ScheduleDraft {
  const V2ScheduleDraft({
    required this.prompt,
    required this.frequency,
    required this.timeLabel,
    required this.days,
    required this.timezoneLabel,
    required this.notify,
  });

  final String prompt;
  final V2ScheduleFrequency frequency;
  final String timeLabel;
  final Set<int> days;
  final String timezoneLabel;
  final bool notify;
}

@immutable
class V2ScheduleEditorData {
  const V2ScheduleEditorData({
    this.status = V2ScheduleEditorStatus.content,
    this.prompt = '',
    this.frequency = V2ScheduleFrequency.weekly,
    this.timeLabel = '9:00 AM',
    this.days = const <int>{1, 2, 3, 4, 5},
    this.timezoneLabel = 'Asia/Kolkata (GMT +5:30)',
    this.timezoneShort = 'IST',
    this.notify = true,
    this.modelLabel = 'Auto model · ~1.2k tokens',
    this.saving = false,
    this.errorMessage = 'We could not open this schedule. Check your connection and try again.',
  });

  final V2ScheduleEditorStatus status;
  final String prompt;
  final V2ScheduleFrequency frequency;
  final String timeLabel;

  /// 1 = Monday … 7 = Sunday.
  final Set<int> days;
  final String timezoneLabel;
  final String timezoneShort;
  final bool notify;
  final String modelLabel;
  final bool saving;
  final String errorMessage;
}

/// Creates or edits one schedule. Every value comes from [data]; every change
/// is reported through a callback so the wiring layer stays the source of truth.
class ScheduleEditorPage extends StatefulWidget {
  const ScheduleEditorPage({
    super.key,
    required this.data,
    this.onSave,
    this.onPromptChanged,
    this.onFrequencyChanged,
    this.onTimeTap,
    this.onDayToggle,
    this.onTimezoneTap,
    this.onNotifyChanged,
    this.onImprovePrompt,
    this.onMore,
    this.onRetry,
    this.onCreateNew,
  });

  final V2ScheduleEditorData data;
  final ValueChanged<V2ScheduleDraft>? onSave;
  final ValueChanged<String>? onPromptChanged;
  final ValueChanged<V2ScheduleFrequency>? onFrequencyChanged;
  final VoidCallback? onTimeTap;
  final ValueChanged<int>? onDayToggle;
  final VoidCallback? onTimezoneTap;
  final ValueChanged<bool>? onNotifyChanged;
  final VoidCallback? onImprovePrompt;
  final VoidCallback? onMore;
  final VoidCallback? onRetry;
  final VoidCallback? onCreateNew;

  @override
  State<ScheduleEditorPage> createState() => _ScheduleEditorPageState();
}

class _ScheduleEditorPageState extends State<ScheduleEditorPage> {
  late final TextEditingController _prompt;
  late V2ScheduleFrequency _frequency;
  late Set<int> _days;
  late bool _notify;

  @override
  void initState() {
    super.initState();
    _prompt = TextEditingController(text: widget.data.prompt);
    _frequency = widget.data.frequency;
    _days = {...widget.data.days};
    _notify = widget.data.notify;
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  bool get _canSave {
    if (_prompt.text.trim().isEmpty) return false;
    if (_frequency == V2ScheduleFrequency.weekly && _days.isEmpty) return false;
    return true;
  }

  void _setFrequency(V2ScheduleFrequency frequency) {
    setState(() => _frequency = frequency);
    widget.onFrequencyChanged?.call(frequency);
  }

  void _toggleDay(int day) {
    setState(() {
      if (_days.contains(day)) {
        _days.remove(day);
      } else {
        _days.add(day);
      }
    });
    widget.onDayToggle?.call(day);
  }

  void _save() {
    widget.onSave?.call(
      V2ScheduleDraft(
        prompt: _prompt.text.trim(),
        frequency: _frequency,
        timeLabel: widget.data.timeLabel,
        days: Set<int>.unmodifiable(_days),
        timezoneLabel: widget.data.timezoneLabel,
        notify: _notify,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OScaffold(
      appBar: OAppBar(
        title: 'Schedule editor',
        actions: [
          OIconButton(
            icon: Icons.more_vert_rounded,
            semanticLabel: 'More options',
            onPressed: widget.onMore,
          ),
        ],
      ),
      body: OFadeSlide(
        child: OAnimatedSwap(
          child: switch (widget.data.status) {
            V2ScheduleEditorStatus.loading => const OSkeletonList(rows: 6),
            V2ScheduleEditorStatus.error => OErrorState(
              message: widget.data.errorMessage,
              onRetry: widget.onRetry,
            ),
            V2ScheduleEditorStatus.missing => OEmptyState(
              icon: Icons.event_busy_rounded,
              title: 'Schedule not found',
              message:
                  'It may have been deleted. You can make a new one in a few taps.',
              action: OButton(
                label: 'Create a schedule',
                icon: Icons.add_rounded,
                onPressed: widget.onCreateNew,
              ),
            ),
            V2ScheduleEditorStatus.content => _content(c),
          },
        ),
      ),
    );
  }

  Widget _content(OColors c) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xxl,
      ),
      children: [
        Row(
          children: [
            Expanded(
              flex: 2,
              child: Text(
                'Task prompt',
                style: OType.label.copyWith(color: c.text),
              ),
            ),
            Icon(Icons.auto_awesome_rounded, size: 14, color: c.accent),
            const SizedBox(width: OSpace.xs),
            Flexible(
              child: Text(
                'Natural instructions',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ),
          ],
        ),
        const SizedBox(height: OSpace.s),
        _promptCard(c),
        const SizedBox(height: OSpace.l),
        Text(
          'Frequency',
          style: OType.label.copyWith(color: c.text),
        ),
        const SizedBox(height: OSpace.s),
        _frequencyControl(c),
        const SizedBox(height: OSpace.m),
        _timeRow(c),
        if (_frequency == V2ScheduleFrequency.weekly) ...[
          const SizedBox(height: OSpace.m),
          _daysCard(c),
        ],
        const SizedBox(height: OSpace.m),
        _timezoneRow(c),
        const SizedBox(height: OSpace.m),
        _notifyRow(c),
        const SizedBox(height: OSpace.m),
        _preview(c),
        const SizedBox(height: OSpace.l),
        OButton(
          label: 'Save schedule',
          icon: Icons.event_available_rounded,
          expand: true,
          loading: widget.data.saving,
          onPressed: _canSave && !widget.data.saving ? _save : null,
        ),
        const SizedBox(height: OSpace.m),
        Text(
          'Runs in the cloud, even when your phone is off.',
          textAlign: TextAlign.center,
          style: OType.caption.copyWith(color: c.textMuted),
        ),
      ],
    );
  }

  Widget _promptCard(OColors c) {
    return Container(
      padding: const EdgeInsets.all(OSpace.l),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        children: [
          TextField(
            controller: _prompt,
            minLines: 3,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (value) {
              setState(() {});
              widget.onPromptChanged?.call(value);
            },
            style: OType.bodySm.copyWith(color: c.text),
            cursorColor: c.accent,
            decoration: InputDecoration(
              hintText:
                  'e.g. Check top Product Hunt launches every morning, summarize the key features, and save a markdown file.',
              hintStyle: OType.bodySm.copyWith(color: c.textFaint),
              filled: false,
              isDense: true,
              contentPadding: EdgeInsets.zero,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
          ),
          const SizedBox(height: OSpace.m),
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: OSpace.m,
                      vertical: OSpace.xs,
                    ),
                    decoration: BoxDecoration(
                      color: c.surfaceAlt,
                      borderRadius: BorderRadius.circular(ORadius.pill),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: c.success,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: OSpace.xs),
                        Flexible(
                          child: Text(
                            widget.data.modelLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: OType.caption.copyWith(color: c.textMuted),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: OSpace.s),
              OIconButton(
                icon: Icons.auto_fix_high_rounded,
                semanticLabel: 'Improve prompt',
                size: 20,
                onPressed: widget.onImprovePrompt,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _frequencyControl(OColors c) {
    return Container(
      padding: const EdgeInsets.all(OSpace.xs),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        children: [
          for (var i = 0; i < V2ScheduleFrequency.values.length; i++) ...[
            if (i > 0) const SizedBox(width: OSpace.xs),
            Expanded(
              child: _frequencyButton(c, V2ScheduleFrequency.values[i]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _frequencyButton(OColors c, V2ScheduleFrequency frequency) {
    final selected = _frequency == frequency;
    return MergeSemantics(
      child: Semantics(
        label: _frequencyLabel(frequency),
        button: true,
        selected: selected,
        child: OPressable(
          onTap: () => _setFrequency(frequency),
          child: AnimatedContainer(
            duration: OMotion.fast,
            curve: OMotion.standard,
            height: OSpace.touch,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? c.accentFill : Colors.transparent,
              borderRadius: BorderRadius.circular(ORadius.s),
            ),
            child: ExcludeSemantics(
              child: Text(
                _frequencyLabel(frequency),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.label.copyWith(
                  color: selected ? c.onAccent : c.textMuted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _timeRow(OColors c) {
    return OCard(
      padding: const EdgeInsets.all(OSpace.m),
      onTap: widget.onTimeTap,
      semanticLabel: 'Run time, ${widget.data.timeLabel}. Change.',
      child: ExcludeSemantics(
        child: Wrap(
          spacing: OSpace.m,
          runSpacing: OSpace.s,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _rowIcon(c, Icons.schedule_rounded),
                const SizedBox(width: OSpace.m),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Run time',
                        style: OType.bodySm.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'When it starts',
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.m,
                vertical: OSpace.s,
              ),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(ORadius.s),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      widget.data.timeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.bodySm.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: OSpace.xs),
                  Icon(
                    Icons.expand_more_rounded,
                    size: 18,
                    color: c.textMuted,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _daysCard(OColors c) {
    return OCard(
      padding: const EdgeInsets.all(OSpace.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: Text(
                  'REPEAT DAYS',
                  style: OType.overline.copyWith(color: c.textMuted),
                ),
              ),
              Icon(Icons.event_repeat_rounded, size: 14, color: c.success),
              const SizedBox(width: OSpace.xs),
              Flexible(
                child: Text(
                  _daysHeadline(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(
                    color: c.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final day in const [1, 2, 3, 4, 5, 6, 7]) ...[
                  _dayChip(c, day),
                  if (day != 7) const SizedBox(width: OSpace.s),
                ],
              ],
            ),
          ),
          const SizedBox(height: OSpace.m),
          Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 15, color: c.accent),
              const SizedBox(width: OSpace.xs),
              Expanded(
                child: Text(
                  _daysSummary(),
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dayChip(OColors c, int day) {
    final selected = _days.contains(day);
    return MergeSemantics(
      child: Semantics(
        label: _dayName(day),
        button: true,
        selected: selected,
        child: OPressable(
          onTap: () => _toggleDay(day),
          child: AnimatedContainer(
            duration: OMotion.fast,
            curve: OMotion.standard,
            width: OSpace.touch,
            height: OSpace.touch,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? c.accentFill : c.surfaceAlt,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? c.accentFill : c.hairline,
              ),
            ),
            child: ExcludeSemantics(
              child: Text(
                _dayInitial(day),
                style: OType.label.copyWith(
                  color: selected ? c.onAccent : c.textMuted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _timezoneRow(OColors c) {
    return OCard(
      padding: const EdgeInsets.all(OSpace.m),
      onTap: widget.onTimezoneTap,
      semanticLabel: 'Timezone, ${widget.data.timezoneLabel}. Change.',
      child: ExcludeSemantics(
        child: Row(
          children: [
            _rowIcon(c, Icons.public_rounded),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Timezone',
                    style: OType.bodySm.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    widget.data.timezoneLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
            Text(
              widget.data.timezoneShort,
              style: OType.caption.copyWith(
                color: c.textMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: OSpace.xs),
            Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint),
          ],
        ),
      ),
    );
  }

  Widget _notifyRow(OColors c) {
    return OCard(
      padding: const EdgeInsets.all(OSpace.m),
      child: MergeSemantics(
        child: Row(
          children: [
            _rowIcon(
              c,
              Icons.notifications_active_rounded,
              color: c.success,
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Notify me when finished',
                      style: OType.bodySm.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'Send a push alert with a short summary.',
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
            ),
            Semantics(
              label:
                  'Notify me when finished. Send a push alert with a short summary.',
              toggled: _notify,
              child: Switch(
                value: _notify,
                onChanged: (value) {
                  setState(() => _notify = value);
                  widget.onNotifyChanged?.call(value);
                },
                activeThumbColor: c.onAccent,
                activeTrackColor: c.accentFill,
                inactiveThumbColor: c.textFaint,
                inactiveTrackColor: c.surfaceRaised,
                trackOutlineColor: WidgetStatePropertyAll(c.hairlineStrong),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rowIcon(OColors c, IconData icon, {Color? color}) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Icon(icon, size: 20, color: color ?? c.accent),
    );
  }

  Widget _preview(OColors c) {
    final base = OType.bodySm.copyWith(color: c.text);
    final highlight = OType.bodySm.copyWith(
      color: c.accent,
      fontWeight: FontWeight.w600,
    );
    return OCard(
      accent: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: c.accentSoft,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.auto_awesome_rounded, size: 17, color: c.accent),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SCHEDULE PREVIEW',
                  style: OType.overline.copyWith(color: c.accent),
                ),
                const SizedBox(height: OSpace.xs),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: 'Ovid will run this ', style: base),
                      TextSpan(text: _frequencyPhrase(), style: highlight),
                      TextSpan(text: ' at ', style: base),
                      TextSpan(text: widget.data.timeLabel, style: highlight),
                      TextSpan(
                        text: ' and message you the result.',
                        style: base,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _frequencyPhrase() {
    if (_frequency == V2ScheduleFrequency.once) return 'once';
    if (_frequency == V2ScheduleFrequency.daily) return 'every day';
    if (_frequency == V2ScheduleFrequency.custom) {
      return 'on your custom schedule';
    }
    if (_days.isEmpty) return 'on the days you pick';
    if (_days.length == 7) return 'every day';
    if (_isWeekdays) return 'every weekday';
    if (_isWeekend) return 'every weekend';
    if (_days.length == 1) return 'every ${_dayName(_days.first)}';
    return 'every ${_joinDayNames()}';
  }

  String _daysHeadline() {
    if (_isWeekdays) return 'Runs Mon – Fri';
    if (_isWeekend) return 'Runs Sat – Sun';
    if (_days.length == 7) return 'Runs every day';
    if (_days.isEmpty) return 'Pick at least one day';
    return 'Runs ${_days.length} days a week';
  }

  String _daysSummary() {
    if (_days.isEmpty) return 'Pick at least one day for this schedule to run.';
    if (_isWeekdays) return 'Runs on weekdays (Mon – Fri).';
    if (_isWeekend) return 'Runs on weekends (Sat – Sun).';
    if (_days.length == 7) return 'Runs every day of the week.';
    return 'Runs on ${_joinDayNames()}.';
  }

  bool get _isWeekdays =>
      _days.length == 5 &&
      _days.contains(1) &&
      _days.contains(2) &&
      _days.contains(3) &&
      _days.contains(4) &&
      _days.contains(5);

  bool get _isWeekend => _days.length == 2 && _days.contains(6) && _days.contains(7);

  String _joinDayNames() {
    final names = _days.toList()..sort();
    final labels = names.map(_dayName).toList();
    if (labels.length == 1) return labels.first;
    if (labels.length == 2) return '${labels[0]} and ${labels[1]}';
    return '${labels.sublist(0, labels.length - 1).join(', ')} and ${labels.last}';
  }

  String _frequencyLabel(V2ScheduleFrequency frequency) => switch (frequency) {
    V2ScheduleFrequency.once => 'Once',
    V2ScheduleFrequency.daily => 'Daily',
    V2ScheduleFrequency.weekly => 'Weekly',
    V2ScheduleFrequency.custom => 'Custom',
  };

  String _dayName(int day) => switch (day) {
    1 => 'Monday',
    2 => 'Tuesday',
    3 => 'Wednesday',
    4 => 'Thursday',
    5 => 'Friday',
    6 => 'Saturday',
    _ => 'Sunday',
  };

  String _dayInitial(int day) => switch (day) {
    1 => 'M',
    2 => 'T',
    3 => 'W',
    4 => 'T',
    5 => 'F',
    6 => 'S',
    _ => 'S',
  };
}
