/// Live state for the Schedules list.
///
/// The screen stays presentational: this controller owns the rows, applies
/// optimistic changes so a toggle or a delete is visible on the next frame, and
/// rolls them back when the service rejects the change.
library;

import 'package:flutter/foundation.dart';

import '../../../core/cloud/cloud_rest.dart';
import '../../../core/cloud/schedule_client.dart';
import 'cadence_picker.dart';
import 'schedule_editor_page.dart';
import 'schedule_gateway.dart';
import 'schedules_page.dart';

const _loadErrorMessage =
    'We could not load your schedules. Check your connection and try again.';

/// Maps a saved trigger onto the editable cadence. Returns null for one-off and
/// interval triggers, which have no cadence picker representation.
V2CadenceDraft? cadenceFromTrigger(ScheduleTrigger trigger) {
  final zone = trigger.tz == null || trigger.tz!.isEmpty ? 'UTC' : trigger.tz!;
  switch (trigger.kind) {
    case 'daily_at':
      final parts = (trigger.time ?? '').split(':');
      if (parts.length < 2) return null;
      final hour = int.tryParse(parts[0]);
      final minute = int.tryParse(parts[1]);
      if (hour == null || minute == null) return null;
      return V2CadenceDraft(
        frequency: V2CadenceFrequency.daily,
        hour: hour,
        minute: minute,
        timezoneId: zone,
        timezoneLabel: zone,
        timezoneShort: _zoneShort(zone),
      );
    case 'cron':
      return cadenceFromCron(
        trigger.expr ?? '',
        timezoneId: zone,
        timezoneLabel: zone,
        timezoneShort: _zoneShort(zone),
      );
    default:
      return null;
  }
}

/// The trigger a saved draft produces, or null when the cadence cannot be sent
/// (the editor blocks saving in that case).
ScheduleTrigger? triggerFromDraft(V2ScheduleDraft draft) {
  final cadence = draft.cadence;
  if (cadence == null || !cadence.isValid) return null;
  final zone = cadence.timezoneId.isEmpty ? 'UTC' : cadence.timezoneId;
  switch (cadence.frequency) {
    case V2CadenceFrequency.daily:
      final time =
          '${cadence.hour.toString().padLeft(2, '0')}:'
          '${cadence.minute.toString().padLeft(2, '0')}';
      return ScheduleTrigger.dailyAt(time, tz: zone);
    case V2CadenceFrequency.weekly:
      return ScheduleTrigger.cron(cadence.cronExpression, tz: zone);
    case V2CadenceFrequency.custom:
      final rrule = normalizedCustomRrule(cadence.customRule);
      final cron = normalizedCustomExpression(cadence.customRule) ??
          (rrule == null ? null : rruleToCron(rrule));
      return cron == null ? null : ScheduleTrigger.cron(cron, tz: zone);
  }
}

/// A short title for a new schedule: the user's own title, else the first line
/// of the prompt.
String titleFromDraft(V2ScheduleDraft draft) {
  final explicit = draft.title.trim();
  if (explicit.isNotEmpty) return explicit;
  final firstLine = draft.prompt.trim().split('\n').first.trim();
  if (firstLine.length <= 60) return firstLine;
  return '${firstLine.substring(0, 57)}…';
}

/// A saved schedule as the list shows it, with its next run derived from the
/// real cadence rather than from a hardcoded label.
V2ScheduleItem scheduleItemFromDto(ScheduleDto dto, DateTime now) {
  final cadence = cadenceFromTrigger(dto.trigger);
  final failed =
      dto.status == 'failed' || dto.lastResult?.status == 'failed';
  return V2ScheduleItem(
    id: dto.id,
    title: dto.title.trim().isEmpty ? 'Untitled schedule' : dto.title,
    description: dto.description,
    rule: cadence != null ? describeCadence(cadence) : dto.trigger.describe(),
    nextRunAt: dto.nextRunAt?.toLocal(),
    cadence: cadence,
    enabled: dto.status == 'pending',
    lastRunFailed: failed,
    failureMessage: dto.lastResult?.message,
    createdLabel: dto.createdAt == null ? null : _dateLabel(dto.createdAt!),
  );
}

class SchedulesController extends ChangeNotifier {
  SchedulesController({
    ScheduleGateway? gateway,
    DateTime Function()? clock,
  })  : _gateway = gateway ?? const ScheduleClientGateway(),
        _clock = clock ?? DateTime.now;

  final ScheduleGateway _gateway;
  final DateTime Function() _clock;

  V2SchedulesStatus _status = V2SchedulesStatus.loading;
  List<V2ScheduleItem> _items = const <V2ScheduleItem>[];
  String _errorMessage = _loadErrorMessage;
  String? _notice;
  final Set<String> _busy = <String>{};

  V2SchedulesStatus get status => _status;
  List<V2ScheduleItem> get items => List<V2ScheduleItem>.unmodifiable(_items);
  String get errorMessage => _errorMessage;

  /// The last action's message, for a snackbar. Cleared by the flow.
  String? get notice => _notice;
  bool isBusy(String id) => _busy.contains(id);

  V2SchedulesData get data => V2SchedulesData(
        status: _status,
        schedules: _items,
        now: _clock(),
        errorMessage: _errorMessage,
      );

  void clearNotice() => _notice = null;

  Future<void> load({bool showLoading = true}) async {
    if (showLoading) {
      _status = V2SchedulesStatus.loading;
      notifyListeners();
    }
    try {
      final rows = await _gateway.list();
      final now = _clock();
      _items = <V2ScheduleItem>[
        for (final row in rows) scheduleItemFromDto(row, now),
      ];
      _status = _items.isEmpty
          ? V2SchedulesStatus.empty
          : V2SchedulesStatus.content;
      _errorMessage = _loadErrorMessage;
    } catch (error) {
      _status = V2SchedulesStatus.error;
      _errorMessage = _loadErrorMessage;
      _notice = _failure('load your schedules', error);
    }
    notifyListeners();
  }

  /// Flips the switch on the next frame, then persists it. A rejected change is
  /// rolled back so the screen never lies about the saved state.
  Future<bool> setEnabled(V2ScheduleItem item, bool enabled) async {
    final index = _indexOf(item.id);
    if (index < 0 || _busy.contains(item.id)) return false;
    final previous = _items[index];
    _replace(index, previous.copyWith(enabled: enabled));
    _busy.add(item.id);
    notifyListeners();
    try {
      await _gateway.update(item.id, status: enabled ? 'pending' : 'paused');
      _notice = enabled
          ? 'Resumed “${previous.title}”.'
          : 'Paused “${previous.title}”.';
      return true;
    } catch (error) {
      final current = _indexOf(item.id);
      if (current >= 0) _replace(current, previous);
      _notice =
          'Could not ${enabled ? 'resume' : 'pause'} “${previous.title}”. '
          '${_reason(error)}';
      return false;
    } finally {
      _busy.remove(item.id);
      notifyListeners();
    }
  }

  /// Removes the row immediately and restores it if the server refuses.
  Future<bool> delete(V2ScheduleItem item) async {
    final index = _indexOf(item.id);
    if (index < 0 || _busy.contains(item.id)) return false;
    final removed = _items[index];
    _items = <V2ScheduleItem>[..._items]..removeAt(index);
    if (_items.isEmpty) _status = V2SchedulesStatus.empty;
    _busy.add(item.id);
    notifyListeners();
    try {
      await _gateway.delete(item.id);
      _notice = 'Deleted “${removed.title}”.';
      return true;
    } catch (error) {
      final restored = <V2ScheduleItem>[..._items];
      restored.insert(index > restored.length ? restored.length : index, removed);
      _items = restored;
      _status = V2SchedulesStatus.content;
      _notice = 'Could not delete “${removed.title}”. ${_reason(error)}';
      return false;
    } finally {
      _busy.remove(item.id);
      notifyListeners();
    }
  }

  Future<bool> runNow(V2ScheduleItem item) async {    if (_busy.contains(item.id)) return false;
    _busy.add(item.id);
    notifyListeners();
    try {
      await _gateway.runNow(item.id);
      _notice = 'Started “${item.title}”. The next run is unchanged.';
      return true;
    } catch (error) {
      _notice = error is CloudApiException && error.status == 409
          ? 'That chat is already running a task. Try again when it finishes.'
          : 'Could not start “${item.title}”. ${_reason(error)}';
      return false;
    } finally {
      _busy.remove(item.id);
      notifyListeners();
    }
  }

  /// Creates a schedule from the editor and reloads so the list shows the
  /// server's own next run. Returns null on success, or the inline error.
  Future<String?> create(V2ScheduleDraft draft, {String? sessionId}) async {
    final trigger = triggerFromDraft(draft);
    if (trigger == null) {
      return 'This cadence cannot be saved yet. Pick a day or a cron rule.';
    }
    try {
      await _gateway.create(
        title: titleFromDraft(draft),
        description: draft.prompt,
        trigger: trigger,
        sessionId: sessionId,
      );
      await load(showLoading: false);
      _notice = 'Schedule created.';
      return null;
    } catch (error) {
      return _reason(error);
    }
  }

  /// Saves an edit, sending the prompt and the validated trigger.
  Future<String?> update(String id, V2ScheduleDraft draft) async {
    final trigger = triggerFromDraft(draft);
    if (trigger == null) {
      return 'This cadence cannot be saved yet. Pick a day or a cron rule.';
    }
    try {
      await _gateway.update(
        id,
        description: draft.prompt,
        trigger: trigger,
      );
      await load(showLoading: false);
      _notice = 'Schedule updated.';
      return null;
    } catch (error) {
      return _reason(error);
    }
  }

  /// The results feed for one schedule, straight from the gateway.
  Future<List<ScheduleRunDto>> runs(String id) => _gateway.runs(id);

  int _indexOf(String id) => _items.indexWhere((item) => item.id == id);
  void _replace(int index, V2ScheduleItem item) {
    final next = <V2ScheduleItem>[..._items];
    next[index] = item;
    _items = next;
  }

  String _failure(String action, Object error) =>
      'Could not $action. ${_reason(error)}';

  String _reason(Object error) {
    if (error is CloudApiException) {
      final message = error.message.trim();
      return message.isEmpty ? 'Check your connection and try again.' : message;
    }
    return 'Check your connection and try again.';
  }
}

String _zoneShort(String zone) {
  final slash = zone.lastIndexOf('/');
  return slash < 0 ? zone : zone.substring(slash + 1);
}

String _dateLabel(DateTime at) {
  const months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = at.toLocal();
  return '${months[local.month - 1]} ${local.day}, ${local.year}';
}
