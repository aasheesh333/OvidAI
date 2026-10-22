import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import '../settings/settings_rows.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

enum V2NotificationsStatus { loading, ready, empty, error }

/// One switch-controlled notification category.
@immutable
class V2NotificationSetting {
  const V2NotificationSetting({
    required this.id,
    required this.title,
    required this.description,
    this.value = true,
    this.available = true,
  });

  final String id;
  final String title;
  final String description;
  final bool value;

  /// False when nothing in the product backs this row yet. The page then
  /// renders the channel as plain information instead of a switch that would
  /// flip and silently forget the change.
  final bool available;

  V2NotificationSetting copyWith({bool? value}) => V2NotificationSetting(
    id: id,
    title: title,
    description: description,
    value: value ?? this.value,
    available: available,
  );
}

/// The sound a channel may use. Mirrors `NotificationSound` in
/// `core/background_notifications.dart`; the page stays free of core imports
/// and the caller maps these values onto [OvidChannel] settings.
enum V2NotificationSound {
  chime('Ovid chime'),
  system('System'),
  silent('Silent');

  const V2NotificationSound(this.label);

  final String label;
}

/// One channel's sound choice.
///
/// The page now shows a single sound for every channel, but the injected data
/// stays per channel because that is how core stores it.
@immutable
class V2ChannelSoundSetting {
  const V2ChannelSoundSetting({
    required this.id,
    required this.title,
    required this.description,
    this.value = V2NotificationSound.chime,
  });

  /// Matches the channel key (`agent_updates`, `scheduler_results`).
  final String id;
  final String title;
  final String description;
  final V2NotificationSound value;

  V2ChannelSoundSetting copyWith({V2NotificationSound? value}) =>
      V2ChannelSoundSetting(
        id: id,
        title: title,
        description: description,
        value: value ?? this.value,
      );
}

/// A quiet-hours window that knows about the midnight wrap.
///
/// `22:00–06:00` is the common case and is NOT an invalid range: the window
/// runs from 22:00 through midnight and ends at 06:00 the next morning.
/// `start == end` is a zero-length window (core treats it as "off"); it must
/// never be rendered as "all day".
@immutable
class V2QuietHoursWindow {
  const V2QuietHoursWindow({required this.start, required this.end});

  final TimeOfDay start;
  final TimeOfDay end;

  int get startMinutes => start.hour * 60 + start.minute;
  int get endMinutes => end.hour * 60 + end.minute;

  /// True when the window ends on the following day (22:00–06:00).
  bool get wrapsMidnight => endMinutes < startMinutes;

  /// A zero-length window means quiet hours never apply.
  bool get isEmpty => startMinutes == endMinutes;

  /// Window length in minutes, accounting for the midnight wrap.
  int get durationMinutes {
    if (isEmpty) return 0;
    return wrapsMidnight
        ? (24 * 60) - startMinutes + endMinutes
        : endMinutes - startMinutes;
  }

  String get durationLabel {
    final minutes = durationMinutes;
    if (minutes == 0) return '0 min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '$m min';
    if (m == 0) return '$h h';
    return '$h h $m min';
  }

  /// Whether [time] falls inside the window (wrap-aware).
  bool contains(TimeOfDay time) {
    if (isEmpty) return false;
    final minute = time.hour * 60 + time.minute;
    if (wrapsMidnight) return minute >= startMinutes || minute < endMinutes;
    return minute >= startMinutes && minute < endMinutes;
  }

  String label(String Function(TimeOfDay) format) =>
      '${format(start)}–${format(end)}';
}

/// Injected state for the Notifications screen.
@immutable
class V2NotificationsPageData {
  const V2NotificationsPageData({
    this.status = V2NotificationsStatus.ready,
    this.notificationsBlocked = false,
    this.masterEnabled = true,
    this.showPermissionPrompt = false,
    this.activity = const <V2NotificationSetting>[
      V2NotificationSetting(
        id: 'run_finished',
        title: 'Run finished',
        description: 'When Ovid completes a task.',
      ),
      V2NotificationSetting(
        id: 'schedule_results',
        title: 'Schedule results',
        description: 'When a scheduled run finishes.',
      ),
      V2NotificationSetting(
        id: 'shares_invites',
        title: 'Shares and invites',
        description: 'When someone shares a chat or invites you.',
        available: false,
      ),
      V2NotificationSetting(
        id: 'collaboration',
        title: 'Collaboration',
        description: 'New messages in shared chats.',
        available: false,
      ),
    ],
    this.security = const <V2NotificationSetting>[
      V2NotificationSetting(
        id: 'new_signins',
        title: 'New sign-ins',
        description: 'When a new device signs in.',
        available: false,
      ),
      V2NotificationSetting(
        id: 'billing',
        title: 'Billing',
        description: 'Receipts, plan changes and payment issues.',
        available: false,
      ),
    ],
    this.sound = true,
    this.vibration = true,
    this.quietHoursLabel = '22:00–08:00',
    this.quietHoursEnabled = true,
    this.quietHoursStart = const TimeOfDay(hour: 22, minute: 0),
    this.quietHoursEnd = const TimeOfDay(hour: 8, minute: 0),
    this.sounds = const <V2ChannelSoundSetting>[
      V2ChannelSoundSetting(
        id: 'agent_updates',
        title: 'Agent updates',
        description: 'Runs that finish, need input or approval.',
      ),
      V2ChannelSoundSetting(
        id: 'scheduler_results',
        title: 'Scheduled results',
        description: 'Scheduled runs that finish or fail.',
      ),
    ],
    this.onToggle,
    this.onMasterChanged,
    this.onAllowNotifications,
    this.onDismissPermissionPrompt,
    this.onQuietHours,
    this.onQuietHoursEnabledChanged,
    this.onQuietHoursStartChanged,
    this.onQuietHoursEndChanged,
    this.onSoundChanged,
    this.onOpenSystem,
    this.onRetry,
    this.errorMessage = 'We could not load your notification settings.',
  });

  final V2NotificationsStatus status;
  final bool notificationsBlocked;

  /// The account-wide push switch. On by default: a new account should hear
  /// about a finished run without hunting for this screen.
  final bool masterEnabled;

  /// True on the first visit, before Android has been asked. The page shows
  /// the permission rationale instead of a bare switch.
  final bool showPermissionPrompt;
  final List<V2NotificationSetting> activity;
  final List<V2NotificationSetting> security;
  final bool sound;

  /// Legacy field: vibration is a property of the Android notification
  /// channel, not of the account, so there is no app-side value to toggle.
  /// Kept so existing callers keep compiling; the page no longer renders it.
  final bool vibration;

  /// Legacy pre-formatted range, e.g. `22:00–08:00`. The page derives the
  /// range from [quietHoursStart]/[quietHoursEnd] (and knows about the
  /// midnight wrap), so a stale label can never disagree with the picker.
  /// Kept so existing callers keep compiling.
  final String quietHoursLabel;
  final bool quietHoursEnabled;
  final TimeOfDay quietHoursStart;
  final TimeOfDay quietHoursEnd;

  /// Per-channel sounds. The page shows one choice and writes it to every
  /// channel, because core stores sound per channel.
  final List<V2ChannelSoundSetting> sounds;

  /// Called with the row id and the requested value.
  final void Function(String id, bool value)? onToggle;

  /// Called with the new value of the account-wide switch.
  final ValueChanged<bool>? onMasterChanged;

  /// Accepts the first-run notification prompt.
  final VoidCallback? onAllowNotifications;

  /// Defers the first-run prompt; it comes back from Settings.
  final VoidCallback? onDismissPermissionPrompt;
  final VoidCallback? onQuietHours;
  final ValueChanged<bool>? onQuietHoursEnabledChanged;
  final ValueChanged<TimeOfDay>? onQuietHoursStartChanged;
  final ValueChanged<TimeOfDay>? onQuietHoursEndChanged;

  /// Called with the channel id and the requested sound.
  final void Function(String id, V2NotificationSound sound)? onSoundChanged;
  final VoidCallback? onOpenSystem;
  final VoidCallback? onRetry;
  final String errorMessage;
}

/// Notification choices: one master switch, four channels, quiet hours and a
/// single sound for every channel.
///
/// The screen owns a working copy of every switch. The caller still persists
/// each change through the callbacks, but the widget does not wait for a
/// parent rebuild: a page pushed once from Settings has no listener on
/// `AppState`/`BackgroundNotifier`.
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key, required this.data});

  final V2NotificationsPageData data;

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  late bool _master;
  late bool _quietEnabled;
  late TimeOfDay _quietStart;
  late TimeOfDay _quietEnd;
  late List<V2NotificationSetting> _activity;
  late List<V2ChannelSoundSetting> _sounds;
  late V2NotificationSound _soundChoice;

  V2NotificationsPageData get _data => widget.data;

  @override
  void initState() {
    super.initState();
    _adopt(_data, null);
  }

  @override
  void didUpdateWidget(covariant NotificationsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.data, widget.data)) {
      _adopt(widget.data, oldWidget.data);
    }
  }

  /// Copies the caller's state, but only fields the caller actually changed:
  /// a rebuild with the same snapshot (for example the permission check's
  /// `setState`) must not undo an optimistic tap.
  void _adopt(V2NotificationsPageData next, V2NotificationsPageData? prev) {
    if (prev == null || next.masterEnabled != prev.masterEnabled) {
      _master = next.masterEnabled;
    }
    if (prev == null || next.quietHoursEnabled != prev.quietHoursEnabled) {
      _quietEnabled = next.quietHoursEnabled;
    }
    if (prev == null || next.quietHoursStart != prev.quietHoursStart) {
      _quietStart = next.quietHoursStart;
    }
    if (prev == null || next.quietHoursEnd != prev.quietHoursEnd) {
      _quietEnd = next.quietHoursEnd;
    }
    if (prev == null || !identical(next.activity, prev.activity)) {
      _activity = List<V2NotificationSetting>.of(next.activity);
    }
    if (prev == null || !identical(next.sounds, prev.sounds)) {
      _sounds = List<V2ChannelSoundSetting>.of(next.sounds);
    }
    if (prev == null || next.sound != prev.sound) {
      _soundChoice = _initialSound(next);
    }
  }

  /// One value for every channel: the common value when they agree, the
  /// chime when they do not, and Silent when sound is off.
  V2NotificationSound _initialSound(V2NotificationsPageData data) {
    if (!data.sound) return V2NotificationSound.silent;
    final values = data.sounds.map((channel) => channel.value).toSet();
    if (values.length == 1) return values.first;
    return V2NotificationSound.chime;
  }

  V2QuietHoursWindow get _window =>
      V2QuietHoursWindow(start: _quietStart, end: _quietEnd);

  @override
  Widget build(BuildContext context) {
    return OScreen(title: 'Notifications', child: _body(context));
  }

  Widget _body(BuildContext context) {
    final status = switch (_data.status) {
      V2NotificationsStatus.loading => OStatus.loading,
      V2NotificationsStatus.error => OStatus.error,
      V2NotificationsStatus.empty => OStatus.empty,
      V2NotificationsStatus.ready => OStatus.content,
    };
    return OStateView(
      status: status,
      errorMessage: _data.errorMessage,
      onRetry: _data.onRetry,
      emptyTitle: 'No notification settings',
      emptyBody: 'Choices appear when your account is ready.',
      emptyActionLabel: 'Refresh',
      onEmptyAction: _data.onRetry,
      skeletonRows: 8,
      child: _content(context),
    );
  }

  Widget _content(BuildContext context) {
    final sections = <Widget>[
      if (_data.showPermissionPrompt && !_data.notificationsBlocked)
        _permissionPrompt(context),
      if (_data.notificationsBlocked) _blockedBanner(context),
      _channelsCard(context),
      _quietHoursCard(context),
      _soundCard(context),
    ];
    return ListView.builder(
      padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.xxl),
      itemCount: sections.length,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(bottom: OSpace.l),
        child: sections[index],
      ),
    );
  }

  Widget _blockedBanner(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      key: const ValueKey<String>('notifications-blocked-banner'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.notifications_off_outlined, size: 20, color: c.warn),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  'Notifications are blocked',
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.xs),
          Text(
            'Allow notifications in Android settings.',
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: OSpace.m),
          OButton(
            label: 'Open settings',
            icon: Icons.settings_outlined,
            variant: OButtonVariant.secondary,
            onPressed: _data.onOpenSystem,
          ),
        ],
      ),
    );
  }

  /// First-run rationale. The onboarding step asks the same question with the
  /// same copy; this card is the Settings-side version.
  Widget _permissionPrompt(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      key: const ValueKey<String>('notifications-permission-prompt'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.notifications_active_outlined,
                size: 22,
                color: c.accent,
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Text(
                  'Get notified when a run finishes',
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.xs),
          Text(
            'Ovid keeps working after you leave the app.',
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: OSpace.m),
          OButton(
            key: const ValueKey<String>('notifications-permission-allow'),
            label: 'Turn on',
            onPressed: _data.onAllowNotifications,
          ),
          const SizedBox(height: OSpace.s),
          OButton(
            key: const ValueKey<String>('notifications-permission-later'),
            label: 'Not now',
            variant: OButtonVariant.secondary,
            onPressed: _data.onDismissPermissionPrompt,
          ),
        ],
      ),
    );
  }

  Widget _channelsCard(BuildContext context) {
    final rows = <Widget>[
      _toggleRow(
        context,
        id: 'master',
        title: 'Push notifications',
        value: _master,
        onChanged: _data.onMasterChanged == null ? null : _setMaster,
        switchKey: const ValueKey<String>('notifications-master-switch'),
      ),
      // A channel the product cannot honour yet is removed, not shown as a
      // switch that would only pretend to store the change.
      for (final setting in _activity)
        if (setting.available)
          _toggleRow(
            context,
            id: setting.id,
            title: setting.title,
            value: setting.value,
            onChanged: _data.onToggle == null
                ? null
                : (value) => _setSetting(setting.id, value),
            enabled: _master,
          ),
    ];
    return V2SettingsRowList(rows: rows);
  }

  void _setMaster(bool value) {
    final handler = _data.onMasterChanged;
    if (handler == null) return;
    setState(() => _master = value);
    handler(value);
  }

  void _setSetting(String id, bool value) {
    final handler = _data.onToggle;
    if (handler == null) return;
    setState(() {
      _activity = [
        for (final row in _activity)
          row.id == id ? row.copyWith(value: value) : row,
      ];
    });
    handler(id, value);
  }

  Widget _quietHoursCard(BuildContext context) {
    final c = OColors.of(context);
    final window = _window;
    final canToggle =
        _data.onQuietHoursEnabledChanged != null || _data.onQuietHours != null;
    final canToggleSwitch = _data.onQuietHoursEnabledChanged != null;
    final canEdit =
        _data.onQuietHoursStartChanged != null ||
        _data.onQuietHoursEndChanged != null;
    final range = _quietEnabled && !window.isEmpty
        ? window.label((time) => _formatTime(context, time))
        : 'Off';

    return V2SettingsRowList(rows: [
      V2SettingsRow(
        key: const ValueKey<String>('notifications-quiet-hours-row'),
        icon: Icons.dark_mode_outlined,
        title: 'Quiet hours',
        subtitle: range,
        enabled: canToggle || canEdit,
        showChevron: false,
        onTap: canToggle || canEdit
            ? () => _onQuietRowTap(context)
            : null,
        trailing: Semantics(
          label: 'Quiet hours',
          toggled: _quietEnabled,
          button: true,
          enabled: canToggleSwitch,
          onTap: canToggleSwitch
              ? () => _setQuietEnabled(!_quietEnabled)
              : null,
          child: ExcludeSemantics(
            child: Switch(
              key: const ValueKey<String>('quiet-hours-switch'),
              value: _quietEnabled,
              onChanged: canToggleSwitch ? _setQuietEnabled : null,
              activeThumbColor: canToggleSwitch ? c.onAccent : c.textFaint,
              activeTrackColor: canToggleSwitch
                  ? c.accentFill
                  : c.surfaceRaised,
              inactiveThumbColor: c.textFaint,
              inactiveTrackColor: c.surfaceRaised,
              trackOutlineColor: WidgetStatePropertyAll(c.hairlineStrong),
              materialTapTargetSize: MaterialTapTargetSize.padded,
            ),
          ),
        ),
      ),
    ]);
  }

  /// Row tap: turn quiet hours on when it is off, edit the range when the
  /// caller exposes the two times, otherwise let the caller open its editor.
  void _onQuietRowTap(BuildContext context) {
    if (!_quietEnabled) {
      if (_data.onQuietHoursEnabledChanged != null) {
        _setQuietEnabled(true);
        return;
      }
      if (_data.onQuietHours != null) {
        _data.onQuietHours!.call();
        return;
      }
    }
    if (_data.onQuietHoursStartChanged != null ||
        _data.onQuietHoursEndChanged != null) {
      _editQuietHours(context);
      return;
    }
    _data.onQuietHours?.call();
  }

  /// The range editor: one sheet, two rows, so the page keeps a single row.
  Future<void> _editQuietHours(BuildContext context) async {
    var start = _quietStart;
    var end = _quietEnd;
    await showOSheet<void>(
      context,
      title: 'Quiet hours',
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            OListRow(
              key: const ValueKey<String>('quiet-hours-start'),
              icon: Icons.schedule_rounded,
              title: 'Start',
              subtitle: _formatTime(context, start),
              showChevron: false,
              onTap: () async {
                final picked = await _pickTime(
                  context,
                  label: 'Start',
                  initial: start,
                );
                if (picked == null) return;
                setSheetState(() => start = picked);
                _setQuietStart(picked);
              },
            ),
            OListRow(
              key: const ValueKey<String>('quiet-hours-end'),
              icon: Icons.schedule_rounded,
              title: 'End',
              subtitle: _formatTime(context, end),
              showChevron: false,
              onTap: () async {
                final picked = await _pickTime(
                  context,
                  label: 'End',
                  initial: end,
                );
                if (picked == null) return;
                setSheetState(() => end = picked);
                _setQuietEnd(picked);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _setQuietEnabled(bool value) {
    final handler = _data.onQuietHoursEnabledChanged;
    if (handler == null) return;
    setState(() => _quietEnabled = value);
    handler(value);
  }

  void _setQuietStart(TimeOfDay value) {
    setState(() => _quietStart = value);
    _data.onQuietHoursStartChanged?.call(value);
  }

  void _setQuietEnd(TimeOfDay value) {
    setState(() => _quietEnd = value);
    _data.onQuietHoursEndChanged?.call(value);
  }

  Future<TimeOfDay?> _pickTime(
    BuildContext context, {
    required String label,
    required TimeOfDay initial,
  }) async {
    return showTimePicker(
      context: context,
      initialTime: initial,
      helpText: 'Quiet hours $label',
      // Input entry is keyboard/screen-reader friendly and stays inside a
      // 320 dp dialog; the dial needs far more room at 200 % text.
      initialEntryMode: TimePickerEntryMode.input,
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.6,
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }

  String _formatTime(BuildContext context, TimeOfDay time) {
    return MaterialLocalizations.of(context).formatTimeOfDay(
      time,
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
  }

  Widget _soundCard(BuildContext context) {
    final canPick =
        _master && _data.onSoundChanged != null && _sounds.isNotEmpty;
    return V2SettingsRowList(rows: [
      V2SettingsRow(
        key: const ValueKey<String>('notifications-sound-row'),
        icon: Icons.volume_up_outlined,
        title: 'Sound',
        subtitle: _soundChoice.label,
        enabled: canPick,
        onTap: canPick ? () => _pickSound(context) : null,
      ),
    ]);
  }

  Future<void> _pickSound(BuildContext context) async {
    final choice = await showOSheet<V2NotificationSound>(
      context,
      title: 'Sound',
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final sound in V2NotificationSound.values)
            OListRow(
              key: ValueKey<String>('sound-choice-${sound.name}'),
              title: sound.label,
              showChevron: false,
              onTap: () => Navigator.pop(sheetContext, sound),
              trailing: sound == _soundChoice
                  ? Icon(
                      Icons.check_rounded,
                      size: 20,
                      color: OColors.of(sheetContext).accent,
                    )
                  : null,
            ),
        ],
      ),
    );
    if (choice != null) _setSound(choice);
  }

  void _setSound(V2NotificationSound sound) {
    final handler = _data.onSoundChanged;
    if (handler == null) return;
    setState(() {
      _soundChoice = sound;
      _sounds = [
        for (final channel in _sounds) channel.copyWith(value: sound),
      ];
    });
    for (final channel in _sounds) {
      handler(channel.id, sound);
    }
  }

  Widget _toggleRow(
    BuildContext context, {
    required String id,
    required String title,
    required bool value,
    ValueChanged<bool>? onChanged,
    bool enabled = true,
    Key? switchKey,
  }) {
    final c = OColors.of(context);
    final canChange = enabled && onChanged != null;
    final handleChanged = canChange ? onChanged : null;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: OSpace.m),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.body.copyWith(
                  color: enabled ? c.text : c.textFaint,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: OSpace.s),
            Semantics(
              label: title,
              toggled: value,
              enabled: canChange,
              onTap: handleChanged == null ? null : () => handleChanged(!value),
              child: ExcludeSemantics(
                child: Switch(
                  key: switchKey ?? ValueKey<String>('notification-switch-$id'),
                  value: value,
                  onChanged: handleChanged,
                  // A disabled switch keeps the "on" position but must not
                  // look tappable, so it falls back to the muted palette.
                  activeThumbColor: canChange ? c.onAccent : c.textFaint,
                  activeTrackColor: canChange ? c.accentFill : c.surfaceRaised,
                  inactiveThumbColor: c.textFaint,
                  inactiveTrackColor: c.surfaceRaised,
                  trackOutlineColor: WidgetStatePropertyAll(c.hairlineStrong),
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
