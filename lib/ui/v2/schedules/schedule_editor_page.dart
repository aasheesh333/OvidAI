import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'cadence_picker.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

enum V2ScheduleEditorStatus { loading, content, error, missing }

enum V2ScheduleFrequency { daily, weekly, custom }

@immutable
class V2ScheduleDraft {
  const V2ScheduleDraft({
    required this.prompt,
    required this.frequency,
    required this.timeLabel,
    required this.days,
    required this.timezoneLabel,
    this.title = '',
    this.cron = '',
    this.rrule = '',
    this.timezoneId = '',
    this.cadence,
  });

  final String prompt;
  final String title;
  final V2ScheduleFrequency frequency;
  final String timeLabel;
  final Set<int> days;
  final String timezoneLabel;

  /// The IANA zone the trigger is saved with.
  final String timezoneId;

  /// The validated cron expression and RRULE produced by the cadence picker.
  final String cron;
  final String rrule;

  /// The complete cadence, so the wiring layer can build the trigger without
  /// re-parsing a display string.
  final V2CadenceDraft? cadence;
}

@immutable
class V2ScheduleEditorData {
  const V2ScheduleEditorData({
    this.status = V2ScheduleEditorStatus.content,
    this.prompt = '',
    this.title = '',
    this.frequency = V2ScheduleFrequency.weekly,
    this.timeLabel = '9:00 AM',
    this.days = const <int>{1, 2, 3, 4, 5},
    this.timezoneLabel = 'Asia/Kolkata (GMT +5:30)',
    this.timezoneShort = 'IST',
    this.timezoneId = 'Asia/Kolkata',
    this.customRule = '',
    this.saving = false,
    this.now,
    this.saveError,
    this.errorMessage =
        'We could not open this schedule. Check your connection and try again.',
  });

  final V2ScheduleEditorStatus status;
  final String prompt;
  final String title;
  final V2ScheduleFrequency frequency;
  final String timeLabel;

  /// 1 = Monday … 7 = Sunday.
  final Set<int> days;
  final String timezoneLabel;
  final String timezoneShort;
  final String timezoneId;

  /// The cron expression or RRULE behind a custom cadence.
  final String customRule;

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
      frequency: frequency,
      timeLabel: timeLabel,
      days: days,
      timezoneLabel: timezoneLabel,
      timezoneShort: timezoneShort,
      timezoneId: timezoneId,
      customRule: customRule,
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
    this.onFrequencyChanged,
    this.onTimeTap,
    this.onDayToggle,
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
  final VoidCallback? onMore;
  final VoidCallback? onRetry;
  final VoidCallback? onCreateNew;

  @override
  State<ScheduleEditorPage> createState() => _ScheduleEditorPageState();
}

class _ScheduleEditorPageState extends State<ScheduleEditorPage> {
  late final TextEditingController _prompt;
  late V2CadenceDraft _cadence;
  late V2ScheduleFrequency _frequency;
  bool _promptTouched = false;
  bool _saveAttempted = false;

  @override
  void initState() {
    super.initState();
    _prompt = TextEditingController(text: widget.data.prompt);
    _frequency = widget.data.frequency;
    _cadence = _initialCadence(widget.data);
    _promptTouched = widget.data.prompt.trim().isNotEmpty;
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  /// The cadence picker has no "once" option; the editor only ever edits a
  /// recurring cadence.
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
      ? 'Write a prompt.'
      : null;

  bool get _canSave => _prompt.text.trim().isNotEmpty && _cadence.isValid;

  /// A save press is only possible when an owner can receive it. Validation
  /// still runs on press so an empty prompt explains itself instead of a
  /// silently dead button.
  bool get _canAttemptSave => widget.onSave != null && !widget.data.saving;

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
        frequency: _frequency,
        timeLabel: _cadence.timeLabel,
        days: Set<int>.unmodifiable(_cadence.days),
        timezoneLabel: _cadence.timezoneLabel,
        timezoneId: _cadence.timezoneId,
        cron: _cadence.cronExpression,
        rrule: _cadence.rrule,
        cadence: _cadence,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OScreen(
      title: 'Schedule',
      showBack: true,
      actions: [
        if (widget.onMore != null)
          OIconButton(
            icon: Icons.more_vert_rounded,
            semanticLabel: 'More options',
            onPressed: widget.onMore,
          ),
      ],
      child: OFadeSlide(
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
              message: 'It may have been deleted.',
              action: OButton(
                label: 'New schedule',
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
      padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xxl),
      children: [
        Text('Prompt', style: OType.label.copyWith(color: c.text)),
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
        CadencePicker(
          draft: _cadence,
          now: _now,
          onChanged: _onCadenceChanged,
          onTimeTap: widget.onTimeTap,
          enabled: !widget.data.saving,
        ),
        if (widget.data.saveError != null) ...[
          const SizedBox(height: OSpace.m),
          _inlineError(
            c,
            widget.data.saveError!,
            key: const ValueKey('schedule-save-error'),
          ),
        ],
        const SizedBox(height: OSpace.l),
        OButton(
          label: 'Save',
          icon: Icons.event_available_rounded,
          expand: true,
          loading: widget.data.saving,
          onPressed: _canAttemptSave ? _save : null,
        ),
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
        border: Border.all(color: _promptError == null ? c.hairline : c.danger),
      ),
      child: TextField(
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
          hintText: 'What should Ovid do?',
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
}
