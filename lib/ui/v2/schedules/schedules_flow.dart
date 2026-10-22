/// The wired Schedules flow: list → editor → run history, all backed by the
/// scheduler service through [SchedulesController].
///
/// This is the entry point the app routes should call. It is the only file in
/// `schedules/` that performs I/O; the pages stay presentational.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/cloud/schedule_client.dart';
import '../../design/o_components.dart';
import 'cadence_picker.dart';
import 'schedule_editor_page.dart';
import 'schedule_gateway.dart';
import 'schedule_runs_page.dart';
import 'schedules_controller.dart';
import 'schedules_page.dart';

/// Opens the Schedules list with live data.
class V2SchedulesFlow {
  const V2SchedulesFlow._();

  static Future<void> openSchedules(
    BuildContext context, {
    String? sessionId,
    ScheduleGateway? gateway,
  }) async {
    final controller = SchedulesController(gateway: gateway);
    await controller.load();
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            SchedulesScreen(controller: controller, sessionId: sessionId),
      ),
    );
    controller.dispose();
  }
}

/// The list screen, rebuilt from [SchedulesController] on every change.
class SchedulesScreen extends StatefulWidget {
  const SchedulesScreen({super.key, required this.controller, this.sessionId});

  final SchedulesController controller;
  final String? sessionId;

  @override
  State<SchedulesScreen> createState() => _SchedulesScreenState();
}

class _SchedulesScreenState extends State<SchedulesScreen> {
  SchedulesController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    if (_controller.status == V2SchedulesStatus.loading) {
      unawaited(_controller.load());
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    await action();
    if (!mounted) return;
    _showNotice();
  }

  void _showNotice() {
    final notice = _controller.notice;
    if (notice == null) return;
    _controller.clearNotice();
    showOSnack(context, notice);
  }

  Future<void> _openEditor({V2ScheduleItem? schedule}) async {
    final zone = await _deviceZone();
    if (!mounted) return;
    final now = DateTime.now();
    final data = schedule == null
        ? V2ScheduleEditorData(
            timezoneId: zone,
            timezoneLabel: zone,
            timezoneShort: _zoneShort(zone),
            now: now,
          )
        : _editorDataFrom(schedule, zone, now);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ScheduleEditorScreen(
          initial: data,
          onSave: (draft) => schedule == null
              ? _controller.create(draft, sessionId: widget.sessionId)
              : _controller.update(schedule.id, draft),
          onReload: schedule == null
              ? null
              : () => _reloadEditorData(schedule.id, zone),
          onDelete: schedule == null ? null : () => _deleteFromEditor(schedule),
        ),
      ),
    );
    if (!mounted) return;
    _showNotice();
  }

  Future<void> _openRuns(V2ScheduleItem schedule) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ScheduleRunsScreen(controller: _controller, schedule: schedule),
      ),
    );
  }

  /// Deletes from the editor. A rejected delete is explained while the editor
  /// is still open; the caller keeps the screen up instead of closing.
  Future<bool> _deleteFromEditor(V2ScheduleItem schedule) async {
    final deleted = await _controller.delete(schedule);
    if (!deleted && mounted) {
      final notice = _controller.notice;
      if (notice != null) {
        _controller.clearNotice();
        showOSnack(context, notice);
      }
    }
    return deleted;
  }

  /// The device zone, with a bound: a platform channel that never answers must
  /// not stop the editor from opening. Falling back to UTC keeps the schedule
  /// creatable; the saved trigger still carries a real zone everywhere else.
  Future<String> _deviceZone() => ScheduleClient.deviceTimeZone().timeout(
    const Duration(seconds: 2),
    onTimeout: () => 'UTC',
  );

  /// Re-reads one schedule for the editor's retry. Null means the row no longer
  /// exists; a failed refresh returns an error-state data so the inline message
  /// stays true instead of pretending the schedule vanished.
  Future<V2ScheduleEditorData?> _reloadEditorData(
    String id,
    String zone,
  ) async {
    await _controller.load(showLoading: false);
    if (_controller.status == V2SchedulesStatus.error) {
      return V2ScheduleEditorData(
        status: V2ScheduleEditorStatus.error,
        errorMessage: _controller.errorMessage,
      );
    }
    for (final item in _controller.items) {
      if (item.id == id) return _editorDataFrom(item, zone, DateTime.now());
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return SchedulesPage(
          data: _controller.data,
          onCreate: () => _openEditor(),
          onScheduleTap: _openRuns,
          onEdit: (schedule) => _openEditor(schedule: schedule),
          onToggle: (schedule, enabled) =>
              _act(() => _controller.setEnabled(schedule, enabled)),
          onRunNow: (schedule) => _act(() => _controller.runNow(schedule)),
          onDelete: (schedule) => _act(() => _controller.delete(schedule)),
          onRetry: () => _act(_controller.load),
        );
      },
    );
  }
}

/// The editor screen with its own saving, reloading and error state.
class ScheduleEditorScreen extends StatefulWidget {
  const ScheduleEditorScreen({
    super.key,
    required this.initial,
    required this.onSave,
    this.onReload,
    this.onDelete,
  });

  final V2ScheduleEditorData initial;
  final Future<String?> Function(V2ScheduleDraft draft) onSave;

  /// Re-reads the schedule after an error. Null means the row was deleted.
  final Future<V2ScheduleEditorData?> Function()? onReload;

  /// Deletes the schedule; true means the service accepted it.
  final Future<bool> Function()? onDelete;

  @override
  State<ScheduleEditorScreen> createState() => ScheduleEditorScreenState();
}

class ScheduleEditorScreenState extends State<ScheduleEditorScreen> {
  late V2ScheduleEditorData _data = widget.initial;
  bool _saving = false;

  Future<void> _save(V2ScheduleDraft draft) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _data = _data.copyWith(saving: true, clearSaveError: true);
    });
    final error = await widget.onSave(draft);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = false;
      _data = _data.copyWith(saving: false, saveError: error);
    });
  }

  /// Retry actually re-reads the schedule; it never leaves the screen.
  Future<void> _reload() async {
    final reload = widget.onReload;
    if (reload == null) return;
    setState(() {
      _data = V2ScheduleEditorData(
        status: V2ScheduleEditorStatus.loading,
        prompt: _data.prompt,
      );
    });
    final next = await reload();
    if (!mounted) return;
    setState(() {
      _data =
          next ??
          const V2ScheduleEditorData(status: V2ScheduleEditorStatus.missing);
    });
  }

  Future<void> _openMore() async {
    final action = await showOSheet<String>(
      context,
      title: 'Schedule',
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            OListRow(
              icon: Icons.close_rounded,
              title: 'Discard changes',
              showChevron: false,
              onTap: () => Navigator.of(sheetContext).pop('discard'),
            ),
            if (widget.onDelete != null)
              OListRow(
                icon: Icons.delete_outline_rounded,
                title: 'Delete schedule',
                danger: true,
                showChevron: false,
                onTap: () => Navigator.of(sheetContext).pop('delete'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'discard') {
      Navigator.of(context).pop();
      return;
    }
    if (action == 'delete') {
      final confirmed = await confirmDeleteSchedule(
        context,
        widget.initial.title,
      );
      if (!mounted || !confirmed) return;
      final deleted = await widget.onDelete!();
      if (!mounted) return;
      // A rejected delete keeps the editor open with the list's rollback and
      // its explanation, instead of closing as if the row were gone.
      if (deleted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScheduleEditorPage(
      data: _data,
      onSave: _save,
      onMore: _openMore,
      onRetry: widget.onReload == null ? null : _reload,
    );
  }
}

/// The run history for one schedule, loaded from the results feed.
class ScheduleRunsScreen extends StatefulWidget {
  const ScheduleRunsScreen({
    super.key,
    required this.controller,
    required this.schedule,
  });

  final SchedulesController controller;
  final V2ScheduleItem schedule;

  @override
  State<ScheduleRunsScreen> createState() => _ScheduleRunsScreenState();
}

class _ScheduleRunsScreenState extends State<ScheduleRunsScreen> {
  V2ScheduleRunsData _data = const V2ScheduleRunsData(
    status: V2ScheduleRunsStatus.loading,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _data = V2ScheduleRunsData(
        status: V2ScheduleRunsStatus.loading,
        scheduleTitle: widget.schedule.title,
      );
    });
    try {
      final rows = await widget.controller.runs(widget.schedule.id);
      if (!mounted) return;
      setState(() {
        _data = V2ScheduleRunsData.fromRuns(
          rows,
          scheduleTitle: widget.schedule.title,
        );
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _data = V2ScheduleRunsData(
          status: V2ScheduleRunsStatus.error,
          scheduleTitle: widget.schedule.title,
        );
      });
    }
  }

  Future<void> _retry(V2ScheduleRun run) async {
    await widget.controller.runNow(widget.schedule);
    if (!mounted) return;
    final notice = widget.controller.notice;
    if (notice != null) {
      widget.controller.clearNotice();
      showOSnack(context, notice);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return ScheduleRunsPage(
      data: _data,
      onRetryRun: _retry,
      onRetry: _load,
      onBackToSchedule: () => Navigator.of(context).pop(),
      onMore: _openMore,
    );
  }

  Future<void> _openMore() async {
    final action = await showOSheet<String>(
      context,
      title: 'Run history',
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            OListRow(
              icon: Icons.refresh_rounded,
              title: 'Refresh',
              showChevron: false,
              onTap: () => Navigator.of(sheetContext).pop('refresh'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'refresh') await _load();
  }
}

V2ScheduleEditorData _editorDataFrom(
  V2ScheduleItem item,
  String zone,
  DateTime now,
) {
  final cadence = item.cadence;
  return V2ScheduleEditorData(
    prompt: item.description,
    title: item.title,
    frequency: switch (cadence?.frequency) {
      V2CadenceFrequency.daily => V2ScheduleFrequency.daily,
      V2CadenceFrequency.custom => V2ScheduleFrequency.custom,
      _ => V2ScheduleFrequency.weekly,
    },
    timeLabel: cadence?.timeLabel ?? '9:00 AM',
    days: cadence?.days ?? const <int>{1, 2, 3, 4, 5},
    customRule: cadence?.customRule ?? '',
    timezoneId: cadence?.timezoneId ?? zone,
    timezoneLabel: cadence?.timezoneLabel ?? zone,
    timezoneShort: cadence?.timezoneShort ?? _zoneShort(zone),
    now: now,
  );
}

String _zoneShort(String zone) {
  final slash = zone.lastIndexOf('/');
  return slash < 0 ? zone : zone.substring(slash + 1);
}
