import 'dart:async';

import 'package:flutter/material.dart';

import '../core/cloud/cloud_rest.dart';
import '../core/cloud/cloud_session_store.dart';
import '../core/cloud/schedule_client.dart';
import '../core/diag.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../l10n/l10n.dart';
import 'user_error.dart';
import 'widgets/aether_confirm.dart';
import 'widgets/aether_primitives.dart';

/// Friendly copy for a failed schedule mutation. P4 errors carry a
/// user-readable `message` (spec §15), so it is surfaced verbatim; local
/// validation failures get the generic invalid copy. The raw error is logged
/// to [Diag], never shown.
String scheduleFailure(
  AppLocalizations l,
  Object error, [
  StackTrace? stack,
  String log = 'schedule_screen',
]) {
  Diag.swallow(log, error, stack);
  if (error is CloudApiException) return error.message;
  if (error is FormatException) return l.scheduleErrorInvalid;
  return friendlyError(error, l10n: l);
}

/// User-facing label for a server schedule status (FE-018: never the raw
/// enum on screen).
String scheduleStatusLabel(String status) => switch (status) {
      'pending' => 'Active',
      'paused' => 'Paused',
      'failed' => 'Failed',
      'completed' => 'Completed',
      'cancelled' => 'Cancelled',
      'running' => 'Running',
      _ => status,
    };

/// User-facing label for one occurrence's status in the run history.
String scheduleRunStatusLabel(String status) => switch (status) {
      'running' => 'Running',
      'retry_scheduled' => 'Retry scheduled',
      'succeeded' => 'Succeeded',
      'failed' => 'Failed',
      'skipped' => 'Skipped (missed)',
      _ => status,
    };

/// Which schedules the screen lists.
enum ScheduleScope { all, chat }

/// Schedules — every scheduled task on the account, server-backed (P4 REST).
///
/// Wave 5 (spec: create, pause, edit, inspect, execution history, next-run
/// countdown):
///  * Lists ALL of the user's schedules (FE-012), grouped by chat; when the
///    screen was opened from a chat a "This chat" filter is offered.
///  * "New schedule" creates one without the agent: presets (every hour,
///    daily) or a custom cron, a time zone, the task prompt, and the target
///    chat (this chat or a new dedicated one).
///  * Each task can run now, and its run history (GET /schedules/:id/runs)
///    links back to the chat that holds the output.
///  * A failed task has a real recovery path: edit it, then resume it or run
///    it once (FE-013). Editing sends only what changed (FE-017).
///  * The status strip tells the truth (FE-018/EM-020): checking, unable to
///    load, or active — never a green "active" above a load error.
///  * Live: the WS system channel (`subscribe_system`) refreshes the list
///    when a run starts or finishes (CT-014), and countdowns tick.
class ScheduleScreen extends StatefulWidget {
  /// The chat the screen was opened from (LOCAL id or server id), or null
  /// from places with no chat. Only drives the "This chat" filter and the
  /// default target of a new schedule.
  final String? sessionId;

  /// Test seam: the live-update feed (defaults to [ScheduleLiveFeed.I]).
  final ScheduleLiveFeed? liveFeed;

  const ScheduleScreen({super.key, this.sessionId, this.liveFeed});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  /// Countdown refresh cadence ("Next in 4m").
  static const Duration _tick = Duration(seconds: 30);

  /// Live events arrive in bursts (started → succeeded, several schedules at
  /// once): coalesce them into one reload.
  static const Duration _liveDebounce = Duration(milliseconds: 400);

  List<ScheduleDto> _schedules = const <ScheduleDto>[];
  bool _loading = true;
  bool _loadedOnce = false;
  String? _error;

  /// The server id of the chat the screen was opened from (null without one,
  /// or for a chat that was never sent).
  String? _chatServerId;
  bool _chatResolved = false;
  ScheduleScope _scope = ScheduleScope.all;

  /// Schedules with a run in flight (from live `schedule_run_started` until
  /// the matching succeeded/failed event or the next reload).
  final Set<String> _running = <String>{};

  /// Bumped on every reload so expanded cards refresh their run history.
  int _revision = 0;

  late final ScheduleLiveFeed _feed;
  StreamSubscription<ScheduleSystemEvent>? _liveSub;
  Timer? _liveTimer;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _feed = widget.liveFeed ?? ScheduleLiveFeed.I;
    _liveSub = _feed.events.listen(_onLiveEvent);
    _feed.start();
    _ticker = Timer.periodic(_tick, (_) {
      if (mounted) setState(() {});
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _liveTimer?.cancel();
    unawaited(_liveSub?.cancel());
    _feed.stop();
    super.dispose();
  }

  Future<String?> _resolveChat() async {
    final id = widget.sessionId;
    if (id == null || id.isEmpty) return null;
    try {
      final store = CloudSessionStore.I;
      // Waits for the id map only while it is still loading.
      await store.resolveServerSessionIdAsync(id);
      // Only a REAL server id: an unsent chat has none, and a local id must
      // never reach the wire as a schedule's target.
      return store.knownServerIdFor(id);
    } catch (e, st) {
      Diag.swallow('schedule_screen.resolve', e, st);
      return null;
    }
  }

  Future<void> _load() async {
    if (mounted) setState(() => _error = null);
    try {
      if (!_chatResolved) {
        _chatServerId = await _resolveChat();
        _chatResolved = true;
      }
      final all = await ScheduleClient.I.list(includeCancelled: true);
      if (!mounted) return;
      final opened = widget.sessionId;
      if (_chatServerId == null &&
          opened != null &&
          all.any((s) => s.sessionId == opened)) {
        // Opened with a server-native id (e.g. a schedule notification).
        _chatServerId = opened;
      }
      setState(() {
        _schedules = all;
        _loading = false;
        _loadedOnce = true;
        _revision++;
        // A reload is authoritative: a run that already finished is no
        // longer "running" (its lastResult says how it went).
        _running.removeWhere(
          (id) => !all.any((s) => s.id == id && s.status == 'pending'),
        );
      });
    } catch (e, st) {
      Diag.swallow('schedule_screen.load', e, st);
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e, l10n: context.l10n);
        _loading = false;
      });
    }
  }

  void _onLiveEvent(ScheduleSystemEvent event) {
    if (!mounted) return;
    switch (event.type) {
      case 'schedule_run_started':
        setState(() => _running.add(event.scheduleId));
      case 'schedule_run_succeeded':
      case 'schedule_run_failed':
      case 'schedule_run_paused':
      case 'schedule_deleted':
        setState(() => _running.remove(event.scheduleId));
    }
    _liveTimer?.cancel();
    _liveTimer = Timer(_liveDebounce, () => unawaited(_load()));
  }

  /// Local chat title for a server session id, when that chat is on this
  /// device.
  String? _chatTitleFor(String serverId) {
    final local = scheduleLocalSessionId(serverId);
    if (local == null) return null;
    final title = AppState.I.sessionById(local)?.title.trim() ?? '';
    return title.isEmpty ? null : title;
  }

  Future<void> _openEditor(
    BuildContext context, {
    ScheduleDto? schedule,
    ScheduleDto? template,
  }) async {
    final saved = await showAetherSheet<bool>(
      context: context,
      builder: (sheetContext) => _EditScheduleSheet(
        schedule: schedule,
        template: template,
        chatServerId: _chatServerId,
        chatTitle: _chatServerId == null ? null : _chatTitleFor(_chatServerId!),
      ),
    );
    if (!mounted) return;
    if (saved == true || schedule != null) await _load();
  }

  List<ScheduleDto> get _visible {
    if (_scope == ScheduleScope.chat && _chatServerId != null) {
      return _schedules
          .where((s) => s.sessionId == _chatServerId)
          .toList(growable: false);
    }
    return _schedules;
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    // Group by chat (the current chat first), headers only when it helps.
    final groups = <String, List<ScheduleDto>>{};
    for (final s in visible) {
      (groups[s.sessionId] ??= <ScheduleDto>[]).add(s);
    }
    final order = groups.keys.toList()
      ..sort((a, b) {
        if (a == _chatServerId) return -1;
        if (b == _chatServerId) return 1;
        return 0;
      });
    final showHeaders = order.length > 1;

    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        title: Text(context.l10n.schedulesTitle),
        actions: [
          IconButton(
            key: const ValueKey('schedule-new'),
            tooltip: context.l10n.scheduleNew,
            icon: const Icon(Icons.add),
            onPressed: () => _openEditor(context),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            _statusStrip(context),
            const SizedBox(height: 16),
            if (_chatServerId != null) ...[
              _scopeChips(),
              const SizedBox(height: 12),
            ],
            const AetherSectionTitle(eyebrow: 'Scheduled tasks'),
            const SizedBox(height: 12),
            if (_loading && !_loadedOnce)
              const Padding(
                padding: EdgeInsets.only(top: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              _errorState(context)
            else if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 32),
                child: Column(
                  children: [
                    AetherEmptyState(
                      icon: Icons.schedule,
                      title: 'No scheduled tasks',
                      message: _scope == ScheduleScope.chat
                          ? 'Nothing is scheduled in this chat. Ask the agent to schedule a task, or create one here.'
                          : 'Ask the agent to schedule a daily, recurring, or one-off task, or create one here.',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      key: const ValueKey('schedule-new-empty'),
                      onPressed: () => _openEditor(context),
                      icon: const Icon(Icons.add_alarm),
                      label: Text(context.l10n.scheduleNew),
                    ),
                  ],
                ),
              )
            else
              for (final sessionId in order) ...[
                if (showHeaders)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8, top: 4),
                    child: Text(
                      sessionId == _chatServerId
                          ? 'This chat'
                          : (_chatTitleFor(sessionId) ?? 'Scheduled chat'),
                      key: ValueKey('schedule-group-$sessionId'),
                      style: AetherType.label,
                    ),
                  ),
                for (final schedule in groups[sessionId]!) ...[
                  _TaskCard(
                    key: ValueKey(schedule.id),
                    schedule: schedule,
                    running: _running.contains(schedule.id),
                    revision: _revision,
                    onChanged: _load,
                    onEdit: () => _openEditor(context, schedule: schedule),
                    onDuplicate: () =>
                        _openEditor(context, template: schedule),
                    onRunStarted: () =>
                        setState(() => _running.add(schedule.id)),
                  ),
                  const SizedBox(height: 12),
                ],
              ],
          ],
        ),
      ),
    );
  }

  Widget _scopeChips() {
    final title = _chatTitleFor(_chatServerId!);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ChoiceChip(
          key: const ValueKey('schedule-scope-all'),
          label: Text(context.l10n.scheduleScopeAll),
          selected: _scope == ScheduleScope.all,
          onSelected: (_) => setState(() => _scope = ScheduleScope.all),
        ),
        ChoiceChip(
          key: const ValueKey('schedule-scope-chat'),
          label: Text(title == null ? 'This chat' : 'This chat · $title'),
          selected: _scope == ScheduleScope.chat,
          onSelected: (_) => setState(() => _scope = ScheduleScope.chat),
        ),
      ],
    );
  }

  Widget _errorState(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: AetherCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.scheduleLoadErrorTitle, style: AetherType.title),
            const SizedBox(height: 6),
            Text(_error!, style: AetherType.bodyMuted),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(context.l10n.actionRetry),
            ),
          ],
        ),
      ),
    );
  }

  /// FE-018 / EM-020: the strip reflects what the screen actually knows.
  Widget _statusStrip(BuildContext context) {
    final Color color;
    final bool pulsing;
    final String title;
    final String message;
    if (_error != null) {
      color = Aether.danger;
      pulsing = false;
      title = context.l10n.scheduleStripError;
      message = _loadedOnce
          ? 'Showing the last loaded schedules. Pull to refresh.'
          : 'Your schedules could not be loaded. Check the connection and retry.';
    } else if (!_loadedOnce) {
      color = Aether.textFaint;
      pulsing = false;
      title = context.l10n.scheduleStripChecking;
      message = 'Loading your scheduled tasks.';
    } else {
      final active = _schedules.where((s) => s.status == 'pending').length;
      final paused = _schedules.where((s) => s.status == 'paused').length;
      final failed = _schedules.where((s) => s.status == 'failed').length;
      color = failed > 0 ? Aether.warn : Aether.success;
      pulsing = active > 0;
      title = context.l10n.scheduleCloudActive;
      final parts = <String>[
        '$active active',
        if (paused > 0) '$paused paused',
        if (failed > 0) '$failed need review',
      ];
      message = '${parts.join(' · ')}. ${context.l10n.scheduleCloudActiveMessage}';
    }
    return AetherCard(
      key: const ValueKey('schedule-status-strip'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AetherStatusDot(color: color, pulsing: pulsing),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: AetherType.title)),
            ],
          ),
          const SizedBox(height: 10),
          Text(message, style: AetherType.caption),
        ],
      ),
    );
  }
}

/// The LOCAL chat id for a server session id, when that chat exists on this
/// device (a mapped local chat, or a server-native row kept under its own
/// id). Null when the chat has not synced here yet.
String? scheduleLocalSessionId(String serverId) {
  final app = AppState.I;
  if (app.sessionById(serverId) != null) return serverId;
  CloudSessionStore? store;
  try {
    store = CloudSessionStore.I;
  } catch (_) {
    store = null;
  }
  if (store == null) return null;
  for (final session in app.sessions) {
    if (store.knownServerIdFor(session.id) == serverId) return session.id;
  }
  return null;
}

/// Opens the chat holding a schedule's output: selects the local chat and
/// returns to the app shell. False when the chat is not on this device yet.
bool openScheduleChat(BuildContext context, String serverSessionId) {
  final local = scheduleLocalSessionId(serverSessionId);
  if (local == null) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text(
          "This chat hasn't synced to this device yet. Pull to refresh your chats, then try again.",
        ),
      ),
    );
    return false;
  }
  AppState.I.selectSession(local);
  Navigator.of(context).popUntil((route) => route.isFirst);
  return true;
}

/// Create / edit / duplicate sheet. Owns its own TextEditingController
/// lifecycle so controllers aren't disposed while the modal route is still
/// animating out.
///
///  * [schedule] set ⇒ edit: only the fields that changed are PATCHed
///    (FE-017 — a rename never reschedules).
///  * [schedule] null ⇒ create (FE-012), pre-filled from [template] when
///    duplicating; the target is [chatServerId] ("This chat") or a new
///    dedicated chat.
/// Pops `true` after a successful save.
class _EditScheduleSheet extends StatefulWidget {
  final ScheduleDto? schedule;
  final ScheduleDto? template;
  final String? chatServerId;
  final String? chatTitle;
  const _EditScheduleSheet({
    this.schedule,
    this.template,
    this.chatServerId,
    this.chatTitle,
  });

  bool get creating => schedule == null;

  @override
  State<_EditScheduleSheet> createState() => _EditScheduleSheetState();
}

class _EditScheduleSheetState extends State<_EditScheduleSheet> {
  late final TextEditingController _title;
  late final TextEditingController _description;

  /// Raw value in the trigger's stored format (HH:mm, seconds, cron expr, or
  /// a date/time). The pickers write into it; it is editable directly only
  /// under "Advanced".
  late final TextEditingController _time;
  late final TextEditingController _intervalValue;
  ScheduleIntervalUnit _intervalUnit = ScheduleIntervalUnit.minutes;
  late String _kind;

  /// IANA zone preserved from the original trigger (daily/cron). Null until a
  /// save needs one, then the device zone is resolved.
  String? _tz;
  late int _retries;
  late final Map<String, String> _draftTimes;
  String? _error;
  String? _titleError;
  String? _descriptionError;
  String? _timeError;
  bool _saving = false;

  /// Raw-text editing ("Advanced") is collapsed by default.
  bool _advanced = false;

  /// The device's IANA zone (FE-019), resolved asynchronously.
  String? _deviceTz;

  /// Create only: run in the chat the screen was opened from, or a new one.
  late bool _targetChat;

  @override
  void initState() {
    super.initState();
    final source = widget.schedule ?? widget.template;
    // A new schedule starts as "every day at 09:00" in the device zone.
    final trigger = source?.trigger ?? ScheduleTrigger.dailyAt('09:00', tz: '');
    _kind = switch (trigger.kind) {
      'daily_at' => 'daily_at',
      'every' => 'every_seconds',
      'cron' => 'cron',
      _ => 'at',
    };
    _tz = (trigger.tz?.isEmpty ?? true) ? null : trigger.tz;
    _targetChat = widget.chatServerId != null &&
        (widget.template == null ||
            widget.template!.sessionId == widget.chatServerId);
    unawaited(ScheduleClient.deviceTimeZone().then((zone) {
      if (mounted) setState(() => _deviceTz = zone);
    }));
    _title = TextEditingController(text: source?.title ?? '');
    _description = TextEditingController(text: source?.description ?? '');
    _draftTimes = {
      'daily_at': trigger.kind == 'daily_at' ? (trigger.time ?? '') : '',
      'every_seconds':
          trigger.kind == 'every' ? '${trigger.seconds ?? ''}' : '',
      'cron': trigger.kind == 'cron' ? (trigger.expr ?? '') : '',
      // Stored one-offs are UTC instants; edit them in local time.
      'at': trigger.kind == 'at' && trigger.at != null
          ? formatScheduleLocal(trigger.at!.toLocal())
          : '',
    };
    _time = TextEditingController(text: _draftTimes[_kind]);
    _intervalValue = TextEditingController();
    _syncIntervalFromRaw();
    _retries = (source?.maxRetries ?? 0).clamp(0, 3);
  }

  /// Quick presets for a new schedule (FE-012).
  void _applyPreset(String preset) {
    setState(() {
      _draftTimes[_kind] = _time.text;
      switch (preset) {
        case 'hourly':
          _kind = 'every_seconds';
          _time.text = '3600';
          _syncIntervalFromRaw();
        case 'daily':
          _kind = 'daily_at';
          _time.text = '09:00';
        case 'custom':
          _kind = 'cron';
          _time.text = _draftTimes['cron']?.isNotEmpty == true
              ? _draftTimes['cron']!
              : '0 9 * * 1-5';
      }
      _timeError = null;
      _error = null;
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _time.dispose();
    _intervalValue.dispose();
    super.dispose();
  }

  /// Raw seconds → number + unit (largest unit that divides evenly).
  void _syncIntervalFromRaw() {
    final seconds = int.tryParse(_draftTimes['every_seconds'] ?? '');
    if (_kind == 'every_seconds') {
      final raw = int.tryParse(_time.text.trim());
      if (raw != null) {
        _setInterval(raw);
        return;
      }
    }
    if (seconds != null) {
      _setInterval(seconds);
    } else {
      _intervalValue.text = '';
    }
  }

  void _setInterval(int seconds) {
    final (value, unit) = splitScheduleInterval(seconds);
    _intervalUnit = unit;
    _intervalValue.text = value;
  }

  /// Number + unit → raw seconds.
  void _syncRawFromInterval() {
    final n = num.tryParse(_intervalValue.text.trim());
    _time.text = n == null
        ? ''
        : (n * _intervalUnit.seconds).round().toString();
  }

  Future<void> _pickDailyTime() async {
    final current =
        _parseHm(_time.text.trim()) ?? const TimeOfDay(hour: 9, minute: 0);
    final picked = await showTimePicker(context: context, initialTime: current);
    if (picked == null || !mounted) return;
    setState(() {
      _time.text = '${_two(picked.hour)}:${_two(picked.minute)}';
      _timeError = null;
    });
  }

  DateTime? _oneOffLocal() {
    final text = _time.text.trim();
    if (text.isEmpty) return null;
    try {
      return ScheduleClient.parseDate(text).toLocal();
    } on FormatException {
      return null;
    }
  }

  DateTime _oneOffSeed() {
    final current = _oneOffLocal();
    if (current != null) return current;
    final now = DateTime.now().add(const Duration(hours: 1));
    return DateTime(now.year, now.month, now.day, now.hour);
  }

  Future<void> _pickOneOffDate() async {
    final seed = _oneOffSeed();
    final now = DateTime.now();
    final first = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: seed.isBefore(first) ? first : seed,
      firstDate: seed.isBefore(first)
          ? DateTime(seed.year, seed.month, seed.day)
          : first,
      lastDate: DateTime(now.year + 5, 12, 31),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _time.text = formatScheduleLocal(
        DateTime(picked.year, picked.month, picked.day, seed.hour, seed.minute),
      );
      _timeError = null;
    });
  }

  Future<void> _pickOneOffTime() async {
    final seed = _oneOffSeed();
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(seed),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _time.text = formatScheduleLocal(
        DateTime(seed.year, seed.month, seed.day, picked.hour, picked.minute),
      );
      _timeError = null;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final title = _title.text.trim();
    final description = _description.text.trim();
    final time = _time.text.trim();
    String? timeError;
    if (_kind == 'daily_at') {
      if (!RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(time)) {
        timeError = 'Pick a time of day (HH:mm, 00:00 to 23:59).';
      }
    } else if (_kind == 'every_seconds') {
      final seconds = int.tryParse(time);
      if (seconds == null) {
        timeError = 'Enter how often to run, e.g. 15 minutes.';
      } else if (seconds < minScheduleIntervalSeconds) {
        timeError = 'The shortest interval is 5 minutes.';
      }
    } else if (_kind == 'cron') {
      if (time.trim().split(RegExp(r'\s+')).length != 5) {
        timeError = 'Enter a 5-field cron expression.';
      }
    } else {
      try {
        ScheduleClient.parseDate(time);
      } on FormatException catch (e) {
        timeError = time.isEmpty ? 'Pick a date and time.' : e.message;
      }
    }
    setState(() {
      _error = null;
      _titleError = title.isEmpty ? 'Enter a title.' : null;
      _descriptionError =
          description.isEmpty ? 'Enter a task description.' : null;
      _timeError = timeError;
    });
    if (_titleError != null || _descriptionError != null || _timeError != null) {
      return;
    }
    setState(() => _saving = true);
    try {
      final ScheduleTrigger trigger;
      switch (_kind) {
        case 'daily_at':
          final tz = _tz ?? await ScheduleClient.deviceTimeZone();
          trigger = ScheduleTrigger.dailyAt(time, tz: tz);
        case 'every_seconds':
          trigger = ScheduleTrigger.every(int.parse(time));
        case 'cron':
          final tz = _tz ?? await ScheduleClient.deviceTimeZone();
          trigger = ScheduleTrigger.cron(time, tz: tz);
        default:
          trigger = ScheduleTrigger.at(
            ScheduleClient.parseDate(time).toUtc(),
          );
      }
      final existing = widget.schedule;
      if (existing == null) {
        await ScheduleClient.I.create(
          title: title,
          description: description,
          trigger: trigger,
          maxRetries: _retries,
          autonomy: widget.template?.autonomy ?? 'safe',
          sessionId: _targetChat ? widget.chatServerId : null,
        );
      } else {
        // FE-017: send only what changed — a repeated trigger would make the
        // server recompute the next run from now.
        final changedTitle = title != existing.title;
        final changedDescription = description != existing.description;
        final changedTrigger = trigger != existing.trigger;
        final changedRetries = _retries != existing.maxRetries;
        if (changedTitle ||
            changedDescription ||
            changedTrigger ||
            changedRetries) {
          await ScheduleClient.I.update(
            existing.id,
            title: changedTitle ? title : null,
            description: changedDescription ? description : null,
            trigger: changedTrigger ? trigger : null,
            maxRetries: changedRetries ? _retries : null,
          );
        }
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e, st) {
      if (mounted) {
        setState(
          () => _error =
              scheduleFailure(context.l10n, e, st, 'schedule_screen.edit'),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _timeLabel() => switch (_kind) {
    'daily_at' => 'Time HH:mm',
    'every_seconds' => 'Interval in seconds (300 or more)',
    'cron' => 'Cron expression (5 fields)',
    _ => 'Date/time YYYY-MM-DD HH:mm',
  };

  Widget _pickerButton({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) => OutlinedButton.icon(
    key: key,
    onPressed: _saving ? null : onPressed,
    icon: Icon(icon, size: 18),
    label: Text(label),
  );

  Widget _primaryTimeControl(BuildContext context) {
    final l10n = MaterialLocalizations.of(context);
    final errorText = _timeError == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _timeError!,
                key: const ValueKey('schedule-time-error'),
                style: TextStyle(color: Aether.dangerC, fontSize: 12),
              ),
            ),
          );
    switch (_kind) {
      case 'daily_at':
        final t = _parseHm(_time.text.trim());
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _pickerButton(
              key: const ValueKey('schedule-daily-time'),
              icon: Icons.schedule,
              label: t == null ? 'Pick a time' : l10n.formatTimeOfDay(t),
              onPressed: _pickDailyTime,
            ),
            const SizedBox(height: 4),
            Text(
              'Repeats every day in ${_tz ?? 'the device time zone'}.',
              style: AetherType.caption,
            ),
            _timeZoneRow(),
            ?errorText,
          ],
        );
      case 'every_seconds':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: AetherField(
                    fieldKey: const ValueKey('schedule-interval-value'),
                    label: 'Every',
                    controller: _intervalValue,
                    enabled: !_saving,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {
                      _syncRawFromInterval();
                      _timeError = null;
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<ScheduleIntervalUnit>(
                  key: const ValueKey('schedule-interval-unit'),
                  value: _intervalUnit,
                  onChanged: _saving
                      ? null
                      : (u) {
                          if (u == null) return;
                          setState(() {
                            _intervalUnit = u;
                            _syncRawFromInterval();
                            _timeError = null;
                          });
                        },
                  items: [
                    for (final u in ScheduleIntervalUnit.values)
                      DropdownMenuItem(value: u, child: Text(u.label)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(context.l10n.scheduleMinimumInterval, style: AetherType.caption),
            ?errorText,
          ],
        );
      case 'cron':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AetherField(
              fieldKey: const ValueKey('schedule-cron'),
              label: context.l10n.scheduleCronLabel,
              controller: _time,
              enabled: !_saving,
              onChanged: (_) => setState(() => _timeError = null),
              helper: context.l10n.scheduleCronHelper,
            ),
            _timeZoneRow(),
            ?errorText,
          ],
        );
      default:
        final local = _oneOffLocal();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _pickerButton(
                  key: const ValueKey('schedule-oneoff-date'),
                  icon: Icons.calendar_today_outlined,
                  label: local == null
                      ? 'Pick a date'
                      : l10n.formatMediumDate(local),
                  onPressed: _pickOneOffDate,
                ),
                _pickerButton(
                  key: const ValueKey('schedule-oneoff-time'),
                  icon: Icons.schedule,
                  label: local == null
                      ? 'Pick a time'
                      : l10n.formatTimeOfDay(TimeOfDay.fromDateTime(local)),
                  onPressed: _pickOneOffTime,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Device-local time. A time in the past runs right away.',
              style: AetherType.caption,
            ),
            ?errorText,
          ],
        );
    }
  }

  /// FE-019: the stored zone, and a one-tap switch to the device zone when
  /// they differ (after travel a daily task can follow the user).
  Widget _timeZoneRow() {
    final device = _deviceTz;
    final stored = _tz;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          Text(
            'Time zone: ${stored ?? device ?? 'device time zone'}',
            key: const ValueKey('schedule-tz'),
            style: AetherType.caption,
          ),
          if (device != null && stored != null && stored != device)
            TextButton(
              key: const ValueKey('schedule-use-device-zone'),
              onPressed: _saving ? null : () => setState(() => _tz = device),
              child: Text(context.l10n.scheduleUseDeviceZone(device)),
            ),
        ],
      ),
    );
  }

  Widget _presets() {
    Widget chip(String key, String label, String preset) => ActionChip(
          key: ValueKey('schedule-preset-$key'),
          label: Text(label),
          onPressed: _saving ? null : () => _applyPreset(preset),
        );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip('hourly', 'Every hour', 'hourly'),
        chip('daily', 'Every day at 9:00', 'daily'),
        chip('custom', 'Custom (cron)', 'custom'),
      ],
    );
  }

  Widget _target() {
    final chatLabel = widget.chatTitle == null
        ? 'This chat'
        : 'This chat · ${widget.chatTitle}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.l10n.scheduleResultsGoTo, style: AetherType.label),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (widget.chatServerId != null)
              ChoiceChip(
                key: const ValueKey('schedule-target-chat'),
                label: Text(chatLabel),
                selected: _targetChat,
                onSelected:
                    _saving ? null : (_) => setState(() => _targetChat = true),
              ),
            ChoiceChip(
              key: const ValueKey('schedule-target-new'),
              label: Text(context.l10n.scheduleTargetNewChat),
              selected: !_targetChat,
              onSelected:
                  _saving ? null : (_) => setState(() => _targetChat = false),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final creating = widget.creating;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: AetherSheet(
        title: creating ? 'New schedule' : 'Edit schedule',
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              AetherField(
                label: 'Title',
                fieldKey: const ValueKey('schedule-title'),
                controller: _title,
                enabled: !_saving,
                errorText: _titleError,
                maxLines: 1,
              ),
              const SizedBox(height: 12),
              AetherField(
                label: 'Task',
                fieldKey: const ValueKey('schedule-prompt'),
                controller: _description,
                enabled: !_saving,
                errorText: _descriptionError,
                // Keep the primary action reachable on compact viewports.
                maxLines: 2,
              ),
              const SizedBox(height: 16),
              if (creating) ...[
                _target(),
                const SizedBox(height: 16),
                Text(context.l10n.scheduleQuickStart, style: AetherType.label),
                const SizedBox(height: 6),
                _presets(),
                const SizedBox(height: 16),
              ],
              Text(context.l10n.scheduleRecurrence, style: AetherType.label),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in [
                    (value: 'at', label: 'One-off'),
                    (value: 'daily_at', label: 'Daily'),
                    (value: 'every_seconds', label: 'Interval'),
                    if (creating || widget.schedule!.trigger.kind == 'cron')
                      (value: 'cron', label: context.l10n.scheduleCron),
                  ])
                    ChoiceChip(
                      label: Text(option.label),
                      selected: _kind == option.value,
                      onSelected: _saving
                          ? null
                          : (_) => setState(() {
                              if (_kind == option.value) return;
                              _draftTimes[_kind] = _time.text;
                              _kind = option.value;
                              _time.text = _draftTimes[_kind] ?? '';
                              if (_kind == 'every_seconds') {
                                _syncIntervalFromRaw();
                              }
                              _timeError = null;
                              _error = null;
                            }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              _primaryTimeControl(context),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('schedule-advanced'),
                  onPressed: () => setState(() => _advanced = !_advanced),
                  icon: Icon(
                    _advanced ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                  ),
                  label: Text(context.l10n.scheduleAdvanced),
                ),
              ),
              if (_advanced) ...[
                AetherField(
                  fieldKey: const ValueKey('schedule-time'),
                  label: _timeLabel(),
                  controller: _time,
                  enabled: !_saving,
                  onChanged: (_) => setState(() {
                    _timeError = null;
                    if (_kind == 'every_seconds') {
                      _syncIntervalFromRaw();
                    }
                  }),
                  keyboardType: _kind == 'every_seconds'
                      ? TextInputType.number
                      : _kind == 'daily_at'
                      ? TextInputType.datetime
                      : TextInputType.text,
                  helper: switch (_kind) {
                    'daily_at' =>
                      'Repeats in the stored time zone. Follows that zone\'s DST.',
                    'every_seconds' =>
                      'Fixed interval; minimum 300 seconds (5 minutes).',
                    'cron' => 'Five fields; the server validates the expression.',
                    _ =>
                      'Device-local time unless you include Z or an offset, e.g. +05:30. Past times are due immediately.',
                  },
                ),
                const SizedBox(height: 8),
              ],
              Text(context.l10n.schedulePreview, style: AetherType.label),
              const SizedBox(height: 4),
              Text(
                _previewLabel(context),
                key: const ValueKey('schedule-preview'),
                style: AetherType.caption,
              ),
              const SizedBox(height: 16),
              AetherStepper(
                label: 'Safe retries',
                value: _retries,
                min: 0,
                max: 3,
                onChanged: (v) {
                  if (!_saving) setState(() => _retries = v);
                },
              ),
              const SizedBox(height: 6),
              Text(
                'Only failures before execution are safe to retry.',
                style: AetherType.caption,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Aether.danger,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                  FilledButton(
                    key: const ValueKey('schedule-save'),
                    onPressed: _saving ? null : _save,
                    child: Text(
                      _saving
                          ? 'Saving…'
                          : (creating ? 'Create schedule' : 'Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _previewLabel(BuildContext context) {
    final value = _time.text.trim();
    if (value.isEmpty) return 'Choose when to run to preview the next run.';
    final l10n = MaterialLocalizations.of(context);
    switch (_kind) {
      case 'daily_at':
        final t = _parseHm(value);
        return t == null
            ? 'Runs daily at $value (${_tz ?? 'device time zone'}).'
            : 'Runs daily at ${l10n.formatTimeOfDay(t)} '
                '(${_tz ?? 'device time zone'}).';
      case 'every_seconds':
        final seconds = int.tryParse(value);
        if (seconds == null) {
          return 'Runs every $value seconds after the next save.';
        }
        return 'Runs every ${describeScheduleInterval(seconds)} after the next save.';
      case 'cron':
        return "Runs on cron '$value' (${_tz ?? 'device time zone'}).";
      default:
        final local = _oneOffLocal();
        if (local == null) return 'Runs once at $value.';
        return 'Runs once on ${l10n.formatMediumDate(local)} at '
            '${l10n.formatTimeOfDay(TimeOfDay.fromDateTime(local))} (device-local time).';
    }
  }
}

String _two(int v) => v.toString().padLeft(2, '0');

TimeOfDay? _parseHm(String value) {
  final m = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$').firstMatch(value);
  if (m == null) return null;
  return TimeOfDay(hour: int.parse(m[1]!), minute: int.parse(m[2]!));
}

/// Shortest allowed interval (the server's `every` floor).
const minScheduleIntervalSeconds = 300;

enum ScheduleIntervalUnit {
  minutes('minutes', 60),
  hours('hours', 3600),
  days('days', 86400);

  const ScheduleIntervalUnit(this.label, this.seconds);
  final String label;
  final int seconds;
}

/// Seconds → (number text, unit), using the largest unit that divides
/// evenly (falls back to fractional minutes for odd raw values).
@visibleForTesting
(String, ScheduleIntervalUnit) splitScheduleInterval(int seconds) {
  for (final u in ScheduleIntervalUnit.values.reversed) {
    if (seconds > 0 && seconds % u.seconds == 0) {
      return ((seconds ~/ u.seconds).toString(), u);
    }
  }
  final minutes = seconds / 60;
  return (
    minutes == minutes.roundToDouble()
        ? minutes.round().toString()
        : minutes.toStringAsFixed(2),
    ScheduleIntervalUnit.minutes,
  );
}

/// "15 minutes", "2 hours", "1 day".
@visibleForTesting
String describeScheduleInterval(int seconds) {
  final (value, unit) = splitScheduleInterval(seconds);
  final label = value == '1'
      ? unit.label.substring(0, unit.label.length - 1)
      : unit.label;
  return '$value $label';
}

/// Local `YYYY-MM-DD HH:mm` (the parser reads a value without Z or an offset
/// as device-local time).
@visibleForTesting
String formatScheduleLocal(DateTime local) =>
    '${local.year.toString().padLeft(4, '0')}-${_two(local.month)}-${_two(local.day)} '
    '${_two(local.hour)}:${_two(local.minute)}'
    '${local.second != 0 ? ':${_two(local.second)}' : ''}';

/// Stored one-off value (usually UTC `…Z`) → editable local text. Values that
/// do not parse are returned unchanged.
@visibleForTesting
String scheduleLocalText(String stored) {
  if (stored.trim().isEmpty) return '';
  try {
    return formatScheduleLocal(
      ScheduleClient.parseDate(stored.trim()).toLocal(),
    );
  } on FormatException {
    return stored;
  }
}

/// A card representing a single server-backed scheduled task.
class _TaskCard extends StatefulWidget {
  final ScheduleDto schedule;

  /// A run of this schedule is in flight (live system event / run now).
  final bool running;

  /// Bumped by every list reload: an open run history refreshes with it.
  final int revision;
  final Future<void> Function() onChanged;
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;
  final VoidCallback onRunStarted;

  const _TaskCard({
    super.key,
    required this.schedule,
    required this.onChanged,
    required this.onEdit,
    required this.onDuplicate,
    required this.onRunStarted,
    this.running = false,
    this.revision = 0,
  });

  @override
  State<_TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<_TaskCard> {
  bool _expanded = false;
  bool _busy = false;
  String? _feedback;

  /// The run history (FE-012), loaded when the details open.
  List<ScheduleRunDto>? _runs;
  bool _runsLoading = false;
  String? _runsError;

  @override
  void didUpdateWidget(covariant _TaskCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_expanded && oldWidget.revision != widget.revision) {
      unawaited(_loadRuns());
    }
  }

  Future<void> _loadRuns() async {
    setState(() {
      _runsLoading = true;
      _runsError = null;
    });
    try {
      final runs = await ScheduleClient.I.runs(widget.schedule.id, pageSize: 20);
      if (!mounted) return;
      setState(() {
        _runs = runs;
        _runsLoading = false;
      });
    } catch (e, st) {
      if (!mounted) return;
      setState(() {
        _runsError = scheduleFailure(context.l10n, e, st, 'schedule_screen.runs');
        _runsLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = MaterialLocalizations.of(context);
    final s = widget.schedule;
    final status = s.status;
    final shownStatus =
        widget.running && status == 'pending' ? 'running' : status;
    final next = s.nextRunAt?.toLocal();
    final title = s.title.trim().isEmpty ? s.description : s.title;
    final last = s.lastResult;

    return AetherCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    AetherPill(
                      key: const ValueKey('schedule-status-pill'),
                      label: scheduleStatusLabel(shownStatus),
                      color: _statusColor(shownStatus),
                      filled: status != 'completed' && status != 'cancelled',
                    ),
                    if (last?.ranLate == true)
                      AetherPill(
                        key: const ValueKey('schedule-ran-late'),
                        label: context.l10n.scheduleRanLate,
                        color: Aether.warn,
                      ),
                    if (s.pausedReason == 'missed_beyond_grace')
                      AetherPill(
                        key: const ValueKey('schedule-missed-run'),
                        label: context.l10n.scheduleMissedRun,
                        color: Aether.warn,
                      ),
                  ],
                ),
              ),
              _menu(context, s),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            title.isEmpty ? '(empty)' : title,
            style: AetherType.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          Text(_prettyRecurrence(l, s.trigger), style: AetherType.bodyMuted),
          if (last != null) ...[
            const SizedBox(height: 6),
            Text(
              _lastResultLine(l, last),
              style: AetherType.caption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (status == 'failed' || status == 'paused') ...[
            const SizedBox(height: 8),
            Text(
              status == 'failed' ? 'Recovery needed' : _pausedLabel(s),
              style: TextStyle(
                color: _statusColor(status),
                fontWeight: FontWeight.w600,
              ),
            ),
            if (last?.message != null && last!.message!.isNotEmpty)
              Text(last.message!, style: AetherType.caption),
          ],
          if (status == 'failed') _recovery(s),
          const SizedBox(height: 4),
          Text(
            _secondary(l, shownStatus, next, last),
            key: const ValueKey('schedule-next'),
            style: AetherType.bodyMuted,
          ),
          if (_busy) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 6),
            Text('Updating schedule…', style: AetherType.caption),
          ],
          if (_feedback != null) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(_feedback!, style: AetherType.caption),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
              label: Text(_expanded ? 'Hide details' : 'Show details'),
              onPressed: () {
                setState(() => _expanded = !_expanded);
                if (_expanded) unawaited(_loadRuns());
              },
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 4),
            _details(l, s),
            const SizedBox(height: 12),
            _history(l, s),
          ],
        ],
      ),
    );
  }

  /// FE-013: a failed task is reviewed, then resumed or run once — the
  /// server accepts both after review.
  Widget _recovery(ScheduleDto s) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Review the task, fix what failed, then resume the schedule or run it once now.',
            style: AetherType.caption,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton(
                key: const ValueKey('schedule-recover-edit'),
                onPressed: _busy ? null : widget.onEdit,
                child: Text(context.l10n.scheduleRecoverEdit),
              ),
              FilledButton(
                key: const ValueKey('schedule-recover-resume'),
                onPressed: _busy
                    ? null
                    : () => _runAction(
                          () => ScheduleClient.I.update(s.id, status: 'pending'),
                        ),
                child: Text(context.l10n.scheduleRecoverResume),
              ),
              TextButton(
                key: const ValueKey('schedule-recover-run'),
                onPressed: _busy ? null : () => _runNow(s),
                child: Text(context.l10n.scheduleRecoverRunOnce),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _menu(BuildContext context, ScheduleDto s) {
    final status = s.status;
    final items = <PopupMenuEntry<String>>[
      PopupMenuItem<String>(
        value: 'edit',
        enabled: s.isEditable,
        child: Text('Edit', style: AetherType.body),
      ),
      if (s.canRunNow)
        PopupMenuItem<String>(
          value: 'run',
          child: Text(context.l10n.scheduleRunNow, style: AetherType.body),
        ),
      if (status == 'pending')
        PopupMenuItem<String>(
          value: 'pause',
          child: Text('Pause', style: AetherType.body),
        ),
      if (s.canResume)
        PopupMenuItem<String>(
          value: 'resume',
          child: Text('Resume', style: AetherType.body),
        ),
      PopupMenuItem<String>(
        value: 'duplicate',
        child: Text(context.l10n.scheduleDuplicate, style: AetherType.body),
      ),
      PopupMenuItem<String>(
        value: 'open',
        child: Text(context.l10n.scheduleOpenChat, style: AetherType.body),
      ),
      if (status != 'cancelled')
        PopupMenuItem<String>(
          value: 'cancel',
          child: Text(
            context.l10n.scheduleCancelTask,
            style: AetherType.body.copyWith(color: Aether.danger),
          ),
        ),
    ];
    return PopupMenuButton<String>(
      tooltip: 'Task actions',
      icon: Icon(Icons.more_horiz, color: Aether.textMuted),
      itemBuilder: (_) => items,
      onSelected: (choice) {
        switch (choice) {
          case 'edit':
            widget.onEdit();
          case 'run':
            _runNow(s);
          case 'pause':
            _runAction(() async {
              await ScheduleClient.I.update(s.id, status: 'paused');
            });
          case 'resume':
            _runAction(() async {
              await ScheduleClient.I.update(s.id, status: 'pending');
            });
          case 'duplicate':
            widget.onDuplicate();
          case 'open':
            openScheduleChat(context, s.sessionId);
          case 'cancel':
            _confirmCancel(context, s);
        }
      },
    );
  }

  /// FE-012: run one occurrence now (the schedule itself is unchanged).
  Future<void> _runNow(ScheduleDto s) async {
    await _runAction(
      () async {
        await ScheduleClient.I.runNow(s.id);
        widget.onRunStarted();
      },
      success: 'Started. The result appears in the chat and in Run history.',
    );
    if (mounted && _expanded) unawaited(_loadRuns());
  }

  /// Cancelling is irreversible (and stops future runs), so it confirms.
  Future<void> _confirmCancel(BuildContext context, ScheduleDto s) async {
    final l = context.l10n;
    final ok = await showAetherConfirmDialog(
      context,
      title: l.scheduleCancelTaskTitle,
      message: s.status == 'pending'
          ? l.scheduleCancelTaskRunningMessage
          : l.scheduleCancelTaskMessage,
      confirmLabel: l.scheduleCancelTask,
      cancelLabel: l.scheduleKeepTask,
    );
    if (!ok || !mounted) return;
    await _runAction(() => ScheduleClient.I.delete(s.id));
  }

  Future<void> _runAction(
    Future<void> Function() action, {
    String? success,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      await action();
      await widget.onChanged();
      if (mounted) {
        setState(() => _feedback = success ?? context.l10n.scheduleUpdated);
      }
    } catch (e, st) {
      if (mounted) {
        final l = context.l10n;
        final failure = scheduleFailure(l, e, st, 'schedule_screen.task');
        setState(() => _feedback = l.scheduleUpdateFailed(failure));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _details(MaterialLocalizations l, ScheduleDto s) {
    final next = s.nextRunAt?.toLocal();
    final last = s.lastResult;
    final finished = last?.finishedAt?.toLocal();
    final scheduledLabel =
        next != null ? _fmtInstant(l, next) : 'Not scheduled';
    final nextRunLabel = s.status == 'pending' && next != null
        ? _nextRunLabel(l, next)
        : _executionLabel(s.status);
    final tz = s.trigger.tz;
    final zoneLabel = tz != null
        ? '$tz · server-scheduled'
        : next == null
        ? 'Unavailable'
        : '${_zoneLabel(next)} · device-local display';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.l10n.scheduleDescription, style: AetherType.label),
        const SizedBox(height: 4),
        Text(
          s.description.isEmpty ? '(empty)' : s.description,
          style: AetherType.body,
        ),
        const SizedBox(height: 10),
        _detailRow('Scheduled', scheduledLabel),
        _detailRow('Time zone', zoneLabel),
        _detailRow('Recurrence', _prettyRecurrence(l, s.trigger)),
        _detailRow('Next run', nextRunLabel),
        _detailRow(
          'Last run',
          last == null
              ? 'Never run'
              : '${last.status}'
                  '${finished == null ? '' : ' · ${_fmtInstant(l, finished)}'}'
                  '${last.ranLate ? ' · ran late' : ''}',
        ),
        _detailRow(
          'Retries',
          'Up to ${s.maxRetries} · pre-execution failures only',
        ),
        _detailRow(
          'Permissions',
          s.autonomy == 'auto'
              ? 'May make changes (auto)'
              : 'Read-only (safe)',
        ),
        if (last?.message != null && last!.message!.isNotEmpty)
          _detailRow(
            last.status == 'failed' ? 'Last error' : 'Last result',
            last.message!,
          ),
        const SizedBox(height: 8),
        Text(context.l10n.scheduleRawSpec, style: AetherType.label),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Aether.codeBg,
            borderRadius: BorderRadius.circular(AetherRadius.rSm),
            border: Border.all(color: Aether.hairline),
          ),
          child: Text(_rawSpec(s.trigger), style: AetherType.mono),
        ),
      ],
    );
  }

  /// FE-012: execution history from `GET /schedules/:id/runs`.
  Widget _history(MaterialLocalizations l, ScheduleDto s) {
    final runs = _runs;
    return Column(
      key: const ValueKey('schedule-history'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(context.l10n.scheduleRunHistory, style: AetherType.label)),
            TextButton(
              key: const ValueKey('schedule-open-chat'),
              onPressed: () => openScheduleChat(context, s.sessionId),
              child: Text(context.l10n.scheduleOpenChat),
            ),
          ],
        ),
        if (_runsLoading && runs == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(minHeight: 2),
          )
        else if (_runsError != null)
          Row(
            children: [
              Expanded(child: Text(_runsError!, style: AetherType.caption)),
              TextButton(
                onPressed: () => unawaited(_loadRuns()),
                child: Text(context.l10n.actionRetry),
              ),
            ],
          )
        else if (runs == null || runs.isEmpty)
          Text(context.l10n.scheduleNoRuns, style: AetherType.caption)
        else
          for (final run in runs) _runRow(l, run),
      ],
    );
  }

  Widget _runRow(MaterialLocalizations l, ScheduleRunDto run) {
    final when = (run.startedAt ?? run.scheduledFor)?.toLocal();
    final finished = run.finishedAt?.toLocal();
    final duration = when != null && finished != null
        ? ' · took ${_fmtDuration(finished.difference(when))}'
        : '';
    final details = <String>[
      if (when != null) _fmtInstant(l, when),
      if (run.attempt > 1) 'attempt ${run.attempt}',
      if (run.ranLate) 'ran late',
    ].join(' · ');
    return Padding(
      key: ValueKey('schedule-run-${run.id}'),
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: AetherStatusDot(
              color: _runColor(run.status),
              pulsing: run.status == 'running',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${scheduleRunStatusLabel(run.status)}$duration',
                  style: AetherType.body,
                ),
                if (details.isNotEmpty)
                  Text(details, style: AetherType.caption),
                if (run.error != null && run.error!.isNotEmpty)
                  Text(run.error!, style: AetherType.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final labelText = Text(label, style: AetherType.label);
          final valueText = Text(value, style: AetherType.bodyMuted);
          if (constraints.maxWidth < 520 ||
              MediaQuery.textScalerOf(context).scale(14) > 20) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [labelText, const SizedBox(height: 4), valueText],
              ),
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 120, child: labelText),
              Expanded(child: valueText),
            ],
          );
        },
      ),
    );
  }

  String _nextRunLabel(MaterialLocalizations l, DateTime next) {
    final diff = next.difference(DateTime.now());
    if (diff.isNegative) {
      return 'Overdue by ${_fmtDuration(diff.abs())} '
          '· ${_fmtInstant(l, next)}';
    }
    return 'In ${_fmtDuration(diff)} · ${_fmtInstant(l, next)}';
  }

  String _secondary(
    MaterialLocalizations l,
    String status,
    DateTime? next,
    ScheduleLastResult? last,
  ) {
    if (status == 'running') return 'Running now · the result appears in the chat';
    if (status == 'pending' && next != null) {
      final diff = next.difference(DateTime.now());
      if (diff.isNegative) {
        return 'Overdue by ${_fmtDuration(diff.abs())} · ${_fmtInstant(l, next)}';
      }
      return 'Next in ${_fmtDuration(diff)} · ${_fmtInstant(l, next)}';
    }
    return '${_executionLabel(status)}'
        '${last != null ? ' · Last run: ${last.status}' : ''}';
  }

  String _pausedLabel(ScheduleDto s) => switch (s.pausedReason) {
    'missed_beyond_grace' => 'Missed while Ovid was offline · review and resume',
    'retries_exhausted' => 'Retries exhausted · review and resume',
    _ => 'Paused · resume to run',
  };

  Color _statusColor(String status) {
    switch (status) {
      case 'running':
        return Aether.success;
      case 'paused':
        return Aether.warn;
      case 'failed':
        return Aether.danger;
      case 'completed':
      case 'cancelled':
        return Aether.textFaint;
      case 'pending':
      default:
        return Aether.accent;
    }
  }

  Color _runColor(String status) => switch (status) {
        'succeeded' => Aether.success,
        'failed' => Aether.danger,
        'running' => Aether.accent,
        'retry_scheduled' => Aether.warn,
        _ => Aether.textFaint,
      };
}

String _lastResultLine(MaterialLocalizations l, ScheduleLastResult last) {
  final message = (last.message ?? '').trim();
  final when = last.finishedAt == null
      ? ''
      : ' · ${_fmtInstant(l, last.finishedAt!.toLocal())}';
  final late = last.ranLate ? ' · ran late' : '';
  return message.isEmpty
      ? 'Last run: ${last.status}$late$when'
      : 'Last run: ${last.status}$late · $message';
}

String _executionLabel(String status) => switch (status) {
  'paused' => 'Paused · resume to run',
  'running' => 'Execution in progress',
  'failed' => 'Failed · edit, then resume or run once',
  'completed' => 'Completed · no next run',
  'cancelled' => 'Cancelled · no next run',
  _ => 'Not scheduled',
};

String _zoneLabel(DateTime time) {
  final minutes = time.timeZoneOffset.inMinutes;
  final hours = (minutes.abs() ~/ 60).toString().padLeft(2, '0');
  final remainder = (minutes.abs() % 60).toString().padLeft(2, '0');
  final offset = 'UTC${minutes < 0 ? '-' : '+'}$hours:$remainder';
  // A runtime abbreviation is not an IANA zone ID; do not manufacture one.
  return time.timeZoneName.isEmpty ? offset : '${time.timeZoneName} ($offset)';
}

String _rawSpec(ScheduleTrigger trigger) => switch (trigger.kind) {
  'at' => 'at=${trigger.at?.toUtc().toIso8601String() ?? '—'}',
  'every' => 'every=${trigger.seconds}s',
  'daily_at' => 'daily_at=${trigger.time} tz=${trigger.tz}',
  'cron' => 'cron=${trigger.expr} tz=${trigger.tz}',
  _ => 'spec=unknown',
};

String _prettyRecurrence(MaterialLocalizations l, ScheduleTrigger trigger) =>
    switch (trigger.kind) {
      'at' => trigger.at == null
          ? 'One-off · unknown'
          : 'One-off · ${_fmtInstant(l, trigger.at!.toLocal())}',
      'every' => 'Every ${_fmtInterval(trigger.seconds ?? 0)} · fixed interval',
      'daily_at' =>
        'Daily · ${trigger.time ?? '—'} · ${trigger.tz ?? 'unknown zone'}',
      'cron' =>
        "Cron · '${trigger.expr ?? '—'}' · ${trigger.tz ?? 'unknown zone'}",
      _ => 'Unknown trigger',
    };

String _fmtInterval(int seconds) {
  if (seconds <= 0) return '0s';
  if (seconds % 86400 == 0) return '${seconds ~/ 86400} d';
  if (seconds % 3600 == 0) return '${seconds ~/ 3600} h';
  if (seconds % 60 == 0) return '${seconds ~/ 60} min';
  return '$seconds s';
}

String _fmtDuration(Duration d) {
  if (d.inDays >= 1) {
    final hours = d.inHours % 24;
    return hours == 0 ? '${d.inDays}d' : '${d.inDays}d ${hours}h';
  }
  if (d.inHours >= 1) {
    final minutes = d.inMinutes % 60;
    return minutes == 0
        ? '${d.inHours}h'
        : '${d.inHours}h ${minutes}m';
  }
  if (d.inMinutes >= 1) return '${d.inMinutes}m';
  return '${d.inSeconds}s';
}

/// Localised date + time (FE-018), with the zone so the reader knows which
/// clock it is.
String _fmtInstant(MaterialLocalizations l, DateTime dt) =>
    '${l.formatShortDate(dt)}, '
    '${l.formatTimeOfDay(TimeOfDay.fromDateTime(dt))} ${_zoneLabel(dt)}';
