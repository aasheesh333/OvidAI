import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'cadence_picker.dart';

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
    this.title = '',
    this.description = '',
    this.endsAt,
    this.cron = '',
    this.rrule = '',
    this.timezoneId = '',
    this.cadence,
  });

  final String prompt;
  final String title;
  final String description;
  final V2ScheduleFrequency frequency;
  final String timeLabel;
  final Set<int> days;
  final String timezoneLabel;

  /// The IANA zone the trigger is saved with.
  final String timezoneId;

  /// Last day this schedule may run, or null when it runs until paused.
  final DateTime? endsAt;

  /// The validated cron expression and RRULE produced by the cadence picker.
  final String cron;
  final String rrule;

  /// The complete cadence, so the wiring layer can build the trigger without
  /// re-parsing a display string.
  final V2CadenceDraft? cadence;
  final bool notify;
}

@immutable
class V2ScheduleEditorData {
  const V2ScheduleEditorData({
    this.status = V2ScheduleEditorStatus.content,
    this.prompt = '',
    this.title = '',
    this.description = '',
    this.frequency = V2ScheduleFrequency.weekly,
    this.timeLabel = '9:00 AM',
    this.days = const <int>{1, 2, 3, 4, 5},
    this.timezoneLabel = 'Asia/Kolkata (GMT +5:30)',
    this.timezoneShort = 'IST',
    this.timezoneId = 'Asia/Kolkata',
    this.notify = true,
    this.endsAt,
    this.customRule = '',
    this.modelLabel = 'Auto model · ~1.2k tokens',
    this.sourceSessionTitle,
    this.sourceSessionSubtitle = 'This schedule was created from this chat.',
    this.saving = false,
    this.now,
    this.saveError,
    this.errorMessage =
        'We could not open this schedule. Check your connection and try again.',
  });

  final V2ScheduleEditorStatus status;
  final String prompt;
  final String title;

  /// A short note about what the schedule does, shown on the schedule card.
  final String description;
  final V2ScheduleFrequency frequency;
  final String timeLabel;

  /// 1 = Monday … 7 = Sunday.
  final Set<int> days;
  final String timezoneLabel;
  final String timezoneShort;
  final String timezoneId;
  final bool notify;
  final String modelLabel;

  /// The cron expression or RRULE behind a custom cadence.
  final String customRule;

  /// The last day this schedule may run; null means "until paused".
  final DateTime? endsAt;

  /// The chat this schedule belongs to. Null when the schedule has no chat yet.
  final String? sourceSessionTitle;
  final String sourceSessionSubtitle;
  final bool saving;

  /// A save failure reported by the wiring layer, shown inline.
  final String? saveError;

  /// Injectable clock for the cadence's next-run preview. Defaults to now.
  final DateTime? now;
  final String errorMessage;

  V2ScheduleEditorData copyWith({
    bool? saving,
    String? saveError,
    bool clearSaveError = false,
  }) {
    return V2ScheduleEditorData(
      status: status,
      prompt: prompt,
      title: title,
      description: description,
      frequency: frequency,
      timeLabel: timeLabel,
      days: days,
      timezoneLabel: timezoneLabel,
      timezoneShort: timezoneShort,
      timezoneId: timezoneId,
      notify: notify,
      endsAt: endsAt,
      customRule: customRule,
      modelLabel: modelLabel,
      sourceSessionTitle: sourceSessionTitle,
      sourceSessionSubtitle: sourceSessionSubtitle,
      saving: saving ?? this.saving,
      now: now,
      saveError: clearSaveError ? null : saveError ?? this.saveError,
      errorMessage: errorMessage,
    );
  }
}

/// Creates or edits one schedule. Every value comes from [data]; every change
/// is reported through a callback so the wiring layer stays the source of truth.
class ScheduleEditorPage extends StatefulWidget {
  const ScheduleEditorPage({
    super.key,
    required this.data,
    this.onSave,
    this.onPromptChanged,
    this.onDescriptionChanged,
    this.onOpenSourceSession,
    this.onFrequencyChanged,
    this.onTimeTap,
    this.onDayToggle,
    this.onTimezoneTap,
    this.onNotifyChanged,
    this.onEndsAtChanged,
    this.onImprovePrompt,
    this.onMore,
    this.onRetry,
    this.onCreateNew,
  });

  final V2ScheduleEditorData data;
  final ValueChanged<V2ScheduleDraft>? onSave;
  final ValueChanged<String>? onPromptChanged;
  final ValueChanged<String>? onDescriptionChanged;
  final VoidCallback? onOpenSourceSession;
  final ValueChanged<V2ScheduleFrequency>? onFrequencyChanged;
  final VoidCallback? onTimeTap;
  final ValueChanged<int>? onDayToggle;
  final VoidCallback? onTimezoneTap;
  final ValueChanged<bool>? onNotifyChanged;
  final ValueChanged<DateTime?>? onEndsAtChanged;
  final VoidCallback? onImprovePrompt;
  final VoidCallback? onMore;
  final VoidCallback? onRetry;
  final VoidCallback? onCreateNew;

  @override
  State<ScheduleEditorPage> createState() => _ScheduleEditorPageState();
}

class _ScheduleEditorPageState extends State<ScheduleEditorPage> {
  late final TextEditingController _prompt;
  late final TextEditingController _description;
  late V2CadenceDraft _cadence;
  late V2ScheduleFrequency _frequency;
  late bool _notify;
  DateTime? _endsAt;
  bool _promptTouched = false;
  bool _saveAttempted = false;

  @override
  void initState() {
    super.initState();
    _prompt = TextEditingController(text: widget.data.prompt);
    _description = TextEditingController(text: widget.data.description);
    _frequency = widget.data.frequency;
    _cadence = _initialCadence(widget.data);
    _notify = widget.data.notify;
    _endsAt = widget.data.endsAt;
    _promptTouched = widget.data.prompt.trim().isNotEmpty;
  }

  @override
  void dispose() {
    _prompt.dispose();
    _description.dispose();
    super.dispose();
  }

  /// The cadence picker has no "once" option; a one-off schedule starts on a
  /// daily cadence and only changes when the user picks another option.
  V2CadenceDraft _initialCadence(V2ScheduleEditorData data) {
    final time = _parseTime(data.timeLabel);
    return V2CadenceDraft(
      frequency: _cadenceFrequency(data.frequency),
      hour: time.$1,
      minute: time.$2,
      days: data.days,
      customRule: data.customRule,
      timezoneLabel: data.timezoneLabel,
      timezoneShort: data.timezoneShort,
      timezoneId: data.timezoneId,
    );
  }

  V2CadenceFrequency _cadenceFrequency(V2ScheduleFrequency frequency) =>
      switch (frequency) {
        V2ScheduleFrequency.once ||
        V2ScheduleFrequency.daily => V2CadenceFrequency.daily,
        V2ScheduleFrequency.weekly => V2CadenceFrequency.weekly,
        V2ScheduleFrequency.custom => V2CadenceFrequency.custom,
      };

  V2ScheduleFrequency _scheduleFrequency(V2CadenceFrequency frequency) =>
      switch (frequency) {
        V2CadenceFrequency.daily => V2ScheduleFrequency.daily,
        V2CadenceFrequency.weekly => V2ScheduleFrequency.weekly,
        V2CadenceFrequency.custom => V2ScheduleFrequency.custom,
      };

  /// Parses "9:00 AM" into a 24-hour hour and minute. Falls back to 9:00.
  (int, int) _parseTime(String label) {
    final match = RegExp(
      r'(\d{1,2}):(\d{2})\s*(AM|PM)',
      caseSensitive: false,
    ).firstMatch(label.trim());
    if (match == null) return (9, 0);
    var hour = int.tryParse(match.group(1)!) ?? 9;
    final minute = int.tryParse(match.group(2)!) ?? 0;
    final period = match.group(3)!.toUpperCase();
    if (period == 'PM' && hour != 12) hour += 12;
    if (period == 'AM' && hour == 12) hour = 0;
    return (hour, minute);
  }

  DateTime get _now => widget.data.now ?? DateTime.now();

  String? get _promptError =>
      _prompt.text.trim().isEmpty && (_promptTouched || _saveAttempted)
      ? 'Write the prompt Ovid should run.'
      : null;

  String? get _endsError => _cadence.endValidationError(_endsAt, _now);

  bool get _canSave =>
      _prompt.text.trim().isNotEmpty &&
      _cadence.isValid &&
      _endsError == null;

  void _onCadenceChanged(V2CadenceDraft next) {
    final previous = _cadence;
    setState(() {
      _cadence = next;
      _frequency = _scheduleFrequency(next.frequency);
    });
    if (next.frequency != previous.frequency) {
      widget.onFrequencyChanged?.call(_frequency);
    }
    if (next.days != previous.days) {
      final changed = <int>{
        ...next.days.difference(previous.days),
        ...previous.days.difference(next.days),
      };
      for (final day in changed) {
        widget.onDayToggle?.call(day);
      }
    }
  }

  Future<void> _pickEndDate() async {
    if (widget.data.saving) return;
    final now = _now;
    final firstRun = _cadence.nextRunAfter(now) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: _endsAt ?? firstRun,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 5, 12, 31),
      helpText: 'Last day this schedule may run',
    );
    if (!mounted || picked == null) return;
    setState(() {
      // End of the chosen day, so the run on that day still happens.
      _endsAt = DateTime(picked.year, picked.month, picked.day, 23, 59);
    });
    widget.onEndsAtChanged?.call(_endsAt);
  }

  void _clearEndDate() {
    setState(() => _endsAt = null);
    widget.onEndsAtChanged?.call(null);
  }

  void _save() {
    if (!_canSave) {
      // Surface the reason instead of leaving a silently disabled button.
      setState(() => _saveAttempted = true);
      return;
    }
    widget.onSave?.call(
      V2ScheduleDraft(
        prompt: _prompt.text.trim(),
        title: widget.data.title.trim(),
        description: _description.text.trim(),
        frequency: _frequency,
        timeLabel: _cadence.timeLabel,
        days: Set<int>.unmodifiable(_cadence.days),
        timezoneLabel: _cadence.timezoneLabel,
        timezoneId: _cadence.timezoneId,
        endsAt: _endsAt,
        cron: _cadence.cronExpression,
        rrule: _cadence.rrule,
        cadence: _cadence,
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
          if (widget.onMore != null)
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
            Text(
              'Required',
              style: OType.caption.copyWith(
                color: _prompt.text.trim().isEmpty ? c.danger : c.textFaint,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: OSpace.s),
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
        if (_promptError != null) ...[
          const SizedBox(height: OSpace.s),
          _inlineError(
            c,
            _promptError!,
            key: const ValueKey('schedule-prompt-error'),
          ),
        ],
        const SizedBox(height: OSpace.l),
        Text('Description', style: OType.label.copyWith(color: c.text)),
        const SizedBox(height: OSpace.s),
        _descriptionCard(c),
        const SizedBox(height: OSpace.m),
        _sourceSessionRow(c),
        const SizedBox(height: OSpace.l),
        Text('Frequency', style: OType.label.copyWith(color: c.text)),
        const SizedBox(height: OSpace.s),
        CadencePicker(
          draft: _cadence,
          now: _now,
          onChanged: _onCadenceChanged,
          onTimeTap: widget.onTimeTap,
          onTimezoneTap: widget.onTimezoneTap,
          enabled: !widget.data.saving,
        ),
        const SizedBox(height: OSpace.m),
        _endsCard(c),
        const SizedBox(height: OSpace.m),
        _notifyRow(c),
        const SizedBox(height: OSpace.l),
        if (widget.data.saveError != null) ...[
          _inlineError(
            c,
            widget.data.saveError!,
            key: const ValueKey('schedule-save-error'),
          ),
          const SizedBox(height: OSpace.s),
        ],
        OButton(
          label: 'Save schedule',
          icon: Icons.event_available_rounded,
          expand: true,
          loading: widget.data.saving,
          onPressed: widget.data.saving ? null : _save,
        ),
      ],
    );
  }

  /// The schedule's last day, with the same inline validation as the cadence.
  Widget _endsCard(OColors c) {
    final local = MaterialLocalizations.of(context);
    final label = _endsAt == null
        ? 'No end date'
        : local.formatMediumDate(_endsAt!);
    final error = _endsError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OCard(
          key: const ValueKey('schedule-ends'),
          padding: const EdgeInsets.all(OSpace.m),
          onTap: widget.data.saving ? null : _pickEndDate,
          semanticLabel: _endsAt == null
              ? 'End date, no end date. Set one.'
              : 'End date, $label. Change.',
          child: Row(
            children: [
              _rowIcon(c, Icons.event_busy_rounded),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'End date',
                      style: OType.bodySm.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      _endsAt == null
                          ? 'Runs until you pause it.'
                          : 'Last day it may run.',
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: OSpace.xs),
              Flexible(
                child: Text(
                  label,
                  maxLines: 2,
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(
                    color: c.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_endsAt != null)
                OIconButton(
                  icon: Icons.close_rounded,
                  semanticLabel: 'Clear end date',
                  size: 18,
                  onPressed: widget.data.saving ? null : _clearEndDate,
                )
              else
                Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint),
            ],
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: OSpace.s),
          _inlineError(
            c,
            error,
            key: const ValueKey('schedule-ends-error'),
          ),
        ],
      ],
    );
  }

  Widget _inlineError(OColors c, String message, {required Key key}) {
    return Semantics(
      key: key,
      liveRegion: true,
      label: message,
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                Icons.error_outline_rounded,
                size: 15,
                color: c.danger,
              ),
            ),
            const SizedBox(width: OSpace.xs),
            Expanded(
              child: Text(
                message,
                style: OType.caption.copyWith(color: c.danger),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _promptCard(OColors c) {
    return Container(
      padding: const EdgeInsets.all(OSpace.l),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(
          color: _promptError == null ? c.hairline : c.danger,
        ),
      ),
      child: Column(
        children: [
          TextField(
            controller: _prompt,
            minLines: 3,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (value) {
              setState(() => _promptTouched = true);
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
              if (widget.onImprovePrompt != null)
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

  Widget _descriptionCard(OColors c) {
    return Container(
      padding: const EdgeInsets.all(OSpace.l),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      child: TextField(
        key: const ValueKey('schedule-description'),
        controller: _description,
        minLines: 2,
        maxLines: 4,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (value) => widget.onDescriptionChanged?.call(value),
        style: OType.bodySm.copyWith(color: c.text),
        cursorColor: c.accent,
        decoration: InputDecoration(
          hintText: 'A short note about what this schedule does.',
          hintStyle: OType.bodySm.copyWith(color: c.textFaint),
          filled: false,
          isDense: true,
          contentPadding: EdgeInsets.zero,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
    );
  }

  /// Read-only link to the chat this schedule belongs to. Tapping it opens that
  /// chat; the chat itself is never edited here.
  Widget _sourceSessionRow(OColors c) {
    final title = widget.data.sourceSessionTitle;
    final linked = title != null && title.trim().isNotEmpty;
    return OCard(
      key: const ValueKey('schedule-source-session'),
      padding: const EdgeInsets.all(OSpace.m),
      onTap: linked ? widget.onOpenSourceSession : null,
      semanticLabel: linked
          ? 'Source session, $title. Open chat.'
          : 'Source session, no chat linked.',
      child: ExcludeSemantics(
        child: Row(
          children: [
            _rowIcon(c, Icons.chat_bubble_outline_rounded),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Source session',
                    style: OType.bodySm.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    linked ? title : 'No chat linked.',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
            if (linked) ...[
              const SizedBox(width: OSpace.xs),
              Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint),
            ],
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
            _rowIcon(c, Icons.notifications_active_rounded, color: c.success),
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
}
