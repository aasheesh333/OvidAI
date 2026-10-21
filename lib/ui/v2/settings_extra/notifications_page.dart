import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

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
  /// renders a plain "Not available yet" row instead of a switch that would
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
  /// Kept so existing callers keep compiling.
  final bool vibration;

  /// Legacy pre-formatted range, e.g. `22:00–08:00`. The page now derives the
  /// range from [quietHoursStart]/[quietHoursEnd] (and knows about the
  /// midnight wrap), so a stale label can never disagree with the picker.
  /// Kept so existing callers keep compiling.
  final String quietHoursLabel;
  final bool quietHoursEnabled;
  final TimeOfDay quietHoursStart;
  final TimeOfDay quietHoursEnd;

  /// Per-channel sounds for the channels that can be voiced.
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

/// Notification choices: activity, security, delivery and system permission.
///
/// The screen owns a working copy of every switch. The caller still persists
/// each change through the callbacks, but the widget no longer waits for a
/// parent rebuild: a page pushed once from Settings has no listener on
/// `AppState`/`BackgroundNotifier`, so rendering straight from the injected
/// snapshot made every tap snap back to the old value.
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key, required this.data});

  final V2NotificationsPageData data;

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  late bool _master;
  late bool _sound;
  late bool _quietEnabled;
  late TimeOfDay _quietStart;
  late TimeOfDay _quietEnd;
  late List<V2NotificationSetting> _activity;
  late List<V2NotificationSetting> _security;
  late List<V2ChannelSoundSetting> _sounds;

  /// The last audible choice per channel, so turning Sound back on restores
  /// the user's pick instead of resetting every channel to the chime.
  final Map<String, V2NotificationSound> _lastAudible =
      <String, V2NotificationSound>{};

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
    if (prev == null || next.sound != prev.sound) _sound = next.sound;
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
    if (prev == null || !identical(next.security, prev.security)) {
      _security = List<V2NotificationSetting>.of(next.security);
    }
    if (prev == null || !identical(next.sounds, prev.sounds)) {
      _sounds = List<V2ChannelSoundSetting>.of(next.sounds);
      for (final channel in _sounds) {
        if (channel.value != V2NotificationSound.silent) {
          _lastAudible[channel.id] = channel.value;
        }
      }
    }
  }

  V2QuietHoursWindow get _window =>
      V2QuietHoursWindow(start: _quietStart, end: _quietEnd);

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Notifications'),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    switch (_data.status) {
      case V2NotificationsStatus.loading:
        return const OFadeSlide(child: OSkeletonList(rows: 8));
      case V2NotificationsStatus.error:
        return OErrorState(message: _data.errorMessage, onRetry: _data.onRetry);
      case V2NotificationsStatus.empty:
        return OEmptyState(
          icon: Icons.notifications_off_outlined,
          title: 'No notification settings',
          message:
              'Notification choices will appear here when your account is ready.',
          action: OButton(
            label: 'Refresh',
            icon: Icons.refresh_rounded,
            onPressed: _data.onRetry,
          ),
        );
      case V2NotificationsStatus.ready:
        return OFadeSlide(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              OSpace.screen,
              OSpace.l,
              OSpace.screen,
              OSpace.xxl,
            ),
            child: OStagger(
              children: [
                if (_data.showPermissionPrompt && !_data.notificationsBlocked)
                  _permissionPrompt(context),
                if (_data.notificationsBlocked) _blockedBanner(context),
                _masterSection(context),
                _activitySection(context),
                _securitySection(context),
                _deliverySection(context),
                _channelSoundsSection(context),
                _quietHoursSection(context),
              ],
            ),
          ),
        );
    }
  }

  Widget _blockedBanner(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Container(
        key: const ValueKey<String>('notifications-blocked-banner'),
        padding: const EdgeInsets.all(OSpace.l),
        decoration: BoxDecoration(
          color: c.warn.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(ORadius.l),
          border: Border.all(color: c.warn.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.notifications_off_outlined, size: 20, color: c.warn),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: Text(
                    'Notifications are blocked',
                    style: OType.h3.copyWith(color: c.text),
                  ),
                ),
              ],
            ),
            const SizedBox(height: OSpace.s),
            Text(
              'Ovid cannot alert you when a run or schedule finishes. '
              'Allow notifications in Android settings.',
              style: OType.bodySm.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: OSpace.m),
            OButton(
              label: 'Open Android settings',
              icon: Icons.settings_outlined,
              variant: OButtonVariant.secondary,
              expand: true,
              onPressed: _data.onOpenSystem,
            ),
          ],
        ),
      ),
    );
  }

  /// First-run rationale. The onboarding step asks the same question with the
  /// same copy; this card is the Settings-side version so a deferred prompt
  /// still explains why the permission matters.
  Widget _permissionPrompt(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: OCard(
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
                    'Get notified when Ovid Si finishes',
                    style: OType.h3.copyWith(color: c.text),
                  ),
                ),
              ],
            ),
            const SizedBox(height: OSpace.s),
            Text(
              'Ovid Si works in the cloud, so long tasks keep running after '
              'you leave the app. Turn on notifications to hear when a run '
              'finishes or needs your approval. You can change this in '
              'Settings.',
              style: OType.bodySm.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: OSpace.m),
            OButton(
              key: const ValueKey<String>('notifications-permission-allow'),
              label: 'Turn on',
              icon: Icons.notifications_active_outlined,
              expand: true,
              onPressed: _data.onAllowNotifications,
            ),
            const SizedBox(height: OSpace.s),
            OButton(
              key: const ValueKey<String>('notifications-permission-later'),
              label: 'Not now',
              variant: OButtonVariant.secondary,
              expand: true,
              onPressed: _data.onDismissPermissionPrompt,
            ),
          ],
        ),
      ),
    );
  }

  Widget _masterSection(BuildContext context) {
    return _section(
      context,
      title: 'Push notifications',
      rows: [
        _toggleRow(
          context,
          id: 'master',
          title: 'Push notifications',
          description: _master
              ? 'On: get notified when a cloud run finishes, fails or needs '
                    'your approval.'
              : 'Off: Ovid Cloud sends no notifications to your devices.',
          value: _master,
          onChanged: _data.onMasterChanged == null ? null : _setMaster,
          switchKey: const ValueKey<String>('notifications-master-switch'),
        ),
      ],
    );
  }

  void _setMaster(bool value) {
    final handler = _data.onMasterChanged;
    if (handler == null) return;
    setState(() => _master = value);
    handler(value);
  }

  Widget _activitySection(BuildContext context) {
    return _section(
      context,
      title: 'Activity',
      rows: [
        for (final setting in _activity)
          if (!setting.available)
            _unavailableRow(context, setting)
          else
            _toggleRow(
              context,
              id: setting.id,
              title: setting.title,
              description: setting.description,
              value: setting.value,
              onChanged: _data.onToggle == null
                  ? null
                  : (value) => _setSetting(setting.id, value),
              enabled: _master,
            ),
      ],
    );
  }

  Widget _securitySection(BuildContext context) {
    return _section(
      context,
      title: 'Security',
      rows: [
        for (final setting in _security)
          if (!setting.available)
            _unavailableRow(context, setting)
          else
            _toggleRow(
              context,
              id: setting.id,
              title: setting.title,
              description: setting.description,
              value: setting.value,
              onChanged: _data.onToggle == null
                  ? null
                  : (value) => _setSetting(setting.id, value),
              enabled: _master,
            ),
      ],
    );
  }

  /// A row the product cannot honour yet: readable, but with no switch that
  /// would only pretend to store the change.
  Widget _unavailableRow(BuildContext context, V2NotificationSetting setting) {
    final c = OColors.of(context);
    return ConstrainedBox(
      key: ValueKey<String>('notification-unavailable-${setting.id}'),
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.l,
          vertical: OSpace.m,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              setting.title,
              style: OType.body.copyWith(
                color: c.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              setting.description,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: OSpace.xs),
            Text(
              'Not available yet',
              style: OType.caption.copyWith(
                color: c.textFaint,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _setSetting(String id, bool value) {
    final handler = _data.onToggle;
    if (handler == null) return;
    setState(() {
      _activity = [
        for (final row in _activity)
          row.id == id ? row.copyWith(value: value) : row,
      ];
      _security = [
        for (final row in _security)
          row.id == id ? row.copyWith(value: value) : row,
      ];
    });
    handler(id, value);
  }

  Widget _deliverySection(BuildContext context) {
    return _section(
      context,
      title: 'Delivery',
      rows: [
        _toggleRow(
          context,
          id: 'sound',
          title: 'Sound',
          description: 'Play a sound for new alerts.',
          value: _sound,
          // Core stores sound per channel (there is no global flag). Drive
          // every voicable channel so the switch reaches the real setting
          // instead of a no-op `onToggle('sound')`.
          onChanged: _canSetSound ? _setSound : null,
          enabled: _master,
        ),
        // Vibration is owned by the Android notification channel, not by the
        // app: a switch here could never change the OS state, so the row
        // opens the system page that can.
        OListRow(
          key: const ValueKey<String>('notifications-vibration-row'),
          icon: Icons.vibration_rounded,
          title: 'Vibration',
          subtitle: 'Android controls vibration for Ovid notifications.',
          enabled: _data.onOpenSystem != null,
          onTap: _data.onOpenSystem,
        ),
      ],
    );
  }

  bool get _canSetSound => _data.onSoundChanged != null && _sounds.isNotEmpty;

  void _setSound(bool value) {
    final handler = _data.onSoundChanged;
    if (handler == null) return;
    final targets = <String, V2NotificationSound>{};
    for (final channel in _sounds) {
      if (value) {
        targets[channel.id] =
            _lastAudible[channel.id] ?? V2NotificationSound.chime;
      } else {
        if (channel.value != V2NotificationSound.silent) {
          _lastAudible[channel.id] = channel.value;
        }
        targets[channel.id] = V2NotificationSound.silent;
      }
    }
    setState(() {
      _sound = value;
      _sounds = [
        for (final channel in _sounds)
          channel.copyWith(value: targets[channel.id]),
      ];
    });
    targets.forEach(handler);
  }

  Widget _channelSoundsSection(BuildContext context) {
    return _section(
      context,
      title: 'Channel sounds',
      rows: [for (final setting in _sounds) _soundRow(context, setting)],
    );
  }

  Widget _soundRow(BuildContext context, V2ChannelSoundSetting setting) {
    final c = OColors.of(context);
    final channelOn = _channelEnabled(setting.id);
    final enabled =
        _data.onSoundChanged != null && channelOn && _master && _sound;
    return Padding(
      key: ValueKey<String>('sound-row-${setting.id}'),
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.l,
        vertical: OSpace.m,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            setting.title,
            style: OType.body.copyWith(
              color: channelOn ? c.text : c.textMuted,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            enabled
                ? setting.description
                : !_master
                ? '${setting.description} Turn push notifications on to pick a '
                      'sound.'
                : !channelOn
                ? '${setting.description} Turn this channel on to pick a sound.'
                : '${setting.description} Turn sound on to pick a channel '
                      'sound.',
            style: OType.caption.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: OSpace.s),
          Wrap(
            spacing: OSpace.s,
            runSpacing: OSpace.s,
            children: [
              for (final sound in V2NotificationSound.values)
                _soundChip(
                  context,
                  channelTitle: setting.title,
                  sound: sound,
                  selected: setting.value == sound,
                  enabled: enabled,
                  onSelected: () => _setChannelSound(setting.id, sound),
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _setChannelSound(String id, V2NotificationSound sound) {
    final handler = _data.onSoundChanged;
    if (handler == null) return;
    setState(() {
      _sounds = [
        for (final channel in _sounds)
          channel.id == id ? channel.copyWith(value: sound) : channel,
      ];
      if (sound == V2NotificationSound.silent) {
        if (_sounds.every((c) => c.value == V2NotificationSound.silent)) {
          _sound = false;
        }
      } else {
        _lastAudible[id] = sound;
        _sound = true;
      }
    });
    handler(id, sound);
  }

  /// Choice chip with a 48 dp target. Built locally (rather than with [OChip])
  /// so the disabled state is announced and the label can ellipsize inside a
  /// narrow 200 % text layout.
  Widget _soundChip(
    BuildContext context, {
    required String channelTitle,
    required V2NotificationSound sound,
    required bool selected,
    required bool enabled,
    required VoidCallback onSelected,
  }) {
    final c = OColors.of(context);
    final fg = !enabled ? c.textFaint : (selected ? c.accent : c.textMuted);
    return Semantics(
      // Every channel renders the same three sounds; name the channel so two
      // "Ovid chime" chips are not two indistinguishable actions.
      label: '${sound.label} for $channelTitle',
      selected: selected,
      button: true,
      enabled: enabled,
      onTap: enabled ? onSelected : null,
      child: ExcludeSemantics(
        child: OPressable(
          onTap: enabled ? onSelected : null,
          child: SizedBox(
            height: OSpace.touch,
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: Container(
                constraints: const BoxConstraints(minHeight: 34),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: selected && enabled ? c.accentSoft : c.surface,
                  borderRadius: BorderRadius.circular(ORadius.m),
                  border: Border.all(
                    color: selected && enabled
                        ? c.accentFill.withValues(alpha: 0.5)
                        : c.hairline,
                  ),
                ),
                child: Text(
                  sound.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.label.copyWith(
                    color: fg,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _quietHoursSection(BuildContext context) {
    final c = OColors.of(context);
    final window = _window;
    // The row may only open a sheet (`onQuietHours`) or may flip the stored
    // value (`onQuietHoursEnabledChanged`). Only the latter can move the
    // switch, because only it tells the page what the new value is.
    final canToggleRow =
        _data.onQuietHoursEnabledChanged != null || _data.onQuietHours != null;
    final canToggleSwitch = _data.onQuietHoursEnabledChanged != null;
    final canEditTimes = _quietEnabled;
    final subtitle = !_quietEnabled
        ? 'Off · Alerts can arrive at any time'
        : window.isEmpty
        ? 'Off · Start and end are the same time'
        : '${window.label((t) => _formatTime(context, t))} · No alerts during this time';

    return _section(
      context,
      title: 'Quiet hours',
      footer: _quietEnabled && !window.isEmpty
          ? Text(
              window.wrapsMidnight
                  ? 'Runs overnight · ${window.durationLabel}'
                  : '${window.durationLabel} window',
              key: const ValueKey<String>('quiet-hours-span'),
              style: OType.caption.copyWith(color: c.textMuted),
            )
          : null,
      rows: [
        OListRow(
          key: const ValueKey<String>('notifications-quiet-hours-row'),
          icon: Icons.dark_mode_outlined,
          title: 'Quiet hours',
          subtitle: subtitle,
          enabled: canToggleRow,
          showChevron: false,
          onTap: canToggleRow ? _toggleQuietRow : null,
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
        _timeRow(
          context,
          label: 'Start',
          time: _quietStart,
          enabled: canEditTimes,
          onChanged: _data.onQuietHoursStartChanged == null
              ? null
              : _setQuietStart,
        ),
        _timeRow(
          context,
          label: 'End',
          time: _quietEnd,
          enabled: canEditTimes,
          onChanged: _data.onQuietHoursEndChanged == null ? null : _setQuietEnd,
        ),
      ],
    );
  }

  /// Row tap: flip the switch when the caller exposes the value; otherwise
  /// let the caller open its own editor without guessing the new state.
  void _toggleQuietRow() {
    final enabledHandler = _data.onQuietHoursEnabledChanged;
    if (enabledHandler != null) {
      _setQuietEnabled(!_quietEnabled);
      return;
    }
    _data.onQuietHours?.call();
  }

  void _setQuietEnabled(bool value) {
    final enabledHandler = _data.onQuietHoursEnabledChanged;
    if (enabledHandler == null) return;
    setState(() => _quietEnabled = value);
    enabledHandler(value);
  }

  void _setQuietStart(TimeOfDay value) {
    setState(() => _quietStart = value);
    _data.onQuietHoursStartChanged?.call(value);
  }

  void _setQuietEnd(TimeOfDay value) {
    setState(() => _quietEnd = value);
    _data.onQuietHoursEndChanged?.call(value);
  }

  Widget _timeRow(
    BuildContext context, {
    required String label,
    required TimeOfDay time,
    required bool enabled,
    required ValueChanged<TimeOfDay>? onChanged,
  }) {
    final c = OColors.of(context);
    final canPick = enabled && onChanged != null;
    final value = _formatTime(context, time);
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
    final foreground = canPick ? c.text : c.textFaint;

    final labelText = Text(
      label,
      style: OType.body.copyWith(
        color: foreground,
        fontWeight: FontWeight.w500,
      ),
    );
    final valueText = Text(
      value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: OType.bodySm.copyWith(color: canPick ? c.textMuted : c.textFaint),
    );
    final chevron = canPick
        ? Icon(Icons.chevron_right_rounded, size: 18, color: c.textFaint)
        : null;

    // At large text the label and value stack: side by side they would each
    // get a sliver of a 320 dp row and paint outside it.
    final content = largeText
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.schedule_rounded, size: 18, color: foreground),
                  const SizedBox(width: OSpace.m),
                  Expanded(child: labelText),
                  ?chevron,
                ],
              ),
              const SizedBox(height: OSpace.xs),
              Padding(
                padding: const EdgeInsets.only(left: 18 + OSpace.m),
                child: valueText,
              ),
            ],
          )
        : Row(
            children: [
              Icon(Icons.schedule_rounded, size: 18, color: foreground),
              const SizedBox(width: OSpace.m),
              Expanded(child: labelText),
              const SizedBox(width: OSpace.s),
              Flexible(child: valueText),
              if (chevron != null) ...[
                const SizedBox(width: OSpace.xs),
                chevron,
              ],
            ],
          );

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: canPick
              ? () => _pickTime(
                  context,
                  label: label,
                  initial: time,
                  onPicked: onChanged,
                )
              : null,
          child: Semantics(
            label: 'Quiet hours $label, $value',
            button: true,
            enabled: canPick,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.l,
                vertical: OSpace.m,
              ),
              child: content,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickTime(
    BuildContext context, {
    required String label,
    required TimeOfDay initial,
    required ValueChanged<TimeOfDay> onPicked,
  }) async {
    final picked = await showTimePicker(
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
    if (picked != null) onPicked(picked);
  }

  String _formatTime(BuildContext context, TimeOfDay time) {
    return MaterialLocalizations.of(context).formatTimeOfDay(
      time,
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
  }

  bool _channelEnabled(String id) {
    for (final setting in _activity) {
      if (setting.id == id) return setting.value;
    }
    return true;
  }

  Widget _section(
    BuildContext context, {
    required String title,
    required List<Widget> rows,
    Widget? footer,
  }) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: title,
            padding: const EdgeInsets.only(bottom: OSpace.s),
          ),
          OCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) Divider(color: c.hairline, height: 1),
                  rows[i],
                ],
              ],
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.only(top: OSpace.s),
              child: footer,
            ),
        ],
      ),
    );
  }

  Widget _toggleRow(
    BuildContext context, {
    required String id,
    required String title,
    required String description,
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
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.l,
          vertical: OSpace.m,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: OType.body.copyWith(
                      color: enabled ? c.text : c.textFaint,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
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
