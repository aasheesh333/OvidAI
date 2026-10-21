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
  });

  final String id;
  final String title;
  final String description;
  final bool value;
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
      ),
      V2NotificationSetting(
        id: 'collaboration',
        title: 'Collaboration',
        description: 'New messages in shared chats.',
      ),
    ],
    this.security = const <V2NotificationSetting>[
      V2NotificationSetting(
        id: 'new_signins',
        title: 'New sign-ins',
        description: 'When a new device signs in.',
      ),
      V2NotificationSetting(
        id: 'billing',
        title: 'Billing',
        description: 'Receipts, plan changes and payment issues.',
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
  final bool vibration;

  /// Human-readable range, e.g. `22:00–08:00`. The page keeps this label and
  /// the editable [quietHoursStart]/[quietHoursEnd] values separate so a
  /// locale-formatted label never changes the stored times.
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
class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key, required this.data});

  final V2NotificationsPageData data;

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Notifications'),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    switch (data.status) {
      case V2NotificationsStatus.loading:
        return const OFadeSlide(child: OSkeletonList(rows: 8));
      case V2NotificationsStatus.error:
        return OErrorState(message: data.errorMessage, onRetry: data.onRetry);
      case V2NotificationsStatus.empty:
        return OEmptyState(
          icon: Icons.notifications_off_outlined,
          title: 'No notification settings',
          message:
              'Notification choices will appear here when your account is ready.',
          action: OButton(
            label: 'Refresh',
            icon: Icons.refresh_rounded,
            onPressed: data.onRetry,
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
                if (data.showPermissionPrompt && !data.notificationsBlocked)
                  _permissionPrompt(context),
                if (data.notificationsBlocked) _blockedBanner(context),
                _master(context),
                _activity(context),
                _security(context),
                _delivery(context),
                _channelSounds(context),
                _quietHours(context),
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
              onPressed: data.onOpenSystem,
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
              onPressed: data.onAllowNotifications,
            ),
            const SizedBox(height: OSpace.s),
            OButton(
              key: const ValueKey<String>('notifications-permission-later'),
              label: 'Not now',
              variant: OButtonVariant.secondary,
              expand: true,
              onPressed: data.onDismissPermissionPrompt,
            ),
          ],
        ),
      ),
    );
  }

  Widget _master(BuildContext context) {
    return _section(
      context,
      title: 'Push notifications',
      rows: [
        _toggleRow(
          context,
          id: 'master',
          title: 'Push notifications',
          description: data.masterEnabled
              ? 'On: get notified when a cloud run finishes, fails or needs '
                    'your approval.'
              : 'Off: Ovid Cloud sends no notifications to your devices.',
          value: data.masterEnabled,
          onChanged: data.onMasterChanged,
          switchKey: const ValueKey<String>('notifications-master-switch'),
        ),
      ],
    );
  }

  Widget _activity(BuildContext context) {
    return _section(
      context,
      title: 'Activity',
      rows: [
        for (final setting in data.activity)
          _toggleRow(
            context,
            id: setting.id,
            title: setting.title,
            description: setting.description,
            value: setting.value,
            onChanged: data.onToggle == null
                ? null
                : (value) => data.onToggle!(setting.id, value),
            enabled: data.masterEnabled,
          ),
      ],
    );
  }

  Widget _security(BuildContext context) {
    return _section(
      context,
      title: 'Security',
      rows: [
        for (final setting in data.security)
          _toggleRow(
            context,
            id: setting.id,
            title: setting.title,
            description: setting.description,
            value: setting.value,
            onChanged: data.onToggle == null
                ? null
                : (value) => data.onToggle!(setting.id, value),
            enabled: data.masterEnabled,
          ),
      ],
    );
  }

  Widget _delivery(BuildContext context) {
    return _section(
      context,
      title: 'Delivery',
      rows: [
        _toggleRow(
          context,
          id: 'sound',
          title: 'Sound',
          description: 'Play a sound for new alerts.',
          value: data.sound,
          onChanged: data.onToggle == null
              ? null
              : (value) => data.onToggle!('sound', value),
          enabled: data.masterEnabled,
        ),
        _toggleRow(
          context,
          id: 'vibration',
          title: 'Vibration',
          description: 'Vibrate for new alerts.',
          value: data.vibration,
          onChanged: data.onToggle == null
              ? null
              : (value) => data.onToggle!('vibration', value),
          enabled: data.masterEnabled,
        ),
      ],
    );
  }

  Widget _channelSounds(BuildContext context) {
    return _section(
      context,
      title: 'Channel sounds',
      rows: [for (final setting in data.sounds) _soundRow(context, setting)],
    );
  }

  Widget _soundRow(BuildContext context, V2ChannelSoundSetting setting) {
    final c = OColors.of(context);
    final channelOn = _channelEnabled(setting.id);
    final enabled =
        data.onSoundChanged != null &&
        channelOn &&
        data.masterEnabled &&
        data.sound;
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
                : !data.masterEnabled
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
                  sound: sound,
                  selected: setting.value == sound,
                  enabled: enabled,
                  onSelected: () =>
                      data.onSoundChanged?.call(setting.id, sound),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Choice chip with a 48 dp target. Built locally (rather than with [OChip])
  /// so the disabled state is announced and the label can ellipsize inside a
  /// narrow 200 % text layout.
  Widget _soundChip(
    BuildContext context, {
    required V2NotificationSound sound,
    required bool selected,
    required bool enabled,
    required VoidCallback onSelected,
  }) {
    final c = OColors.of(context);
    final fg = !enabled ? c.textFaint : (selected ? c.accent : c.textMuted);
    return Semantics(
      label: sound.label,
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

  Widget _quietHours(BuildContext context) {
    final c = OColors.of(context);
    final enabled = data.quietHoursEnabled;
    final canToggle = data.onQuietHoursEnabledChanged != null;
    final canEditTimes = enabled;
    return _section(
      context,
      title: 'Quiet hours',
      rows: [
        OListRow(
          icon: Icons.dark_mode_outlined,
          title: 'Quiet hours',
          subtitle: enabled
              ? '${data.quietHoursLabel} · No alerts during this time'
              : 'Off · Alerts can arrive at any time',
          enabled: data.onQuietHours != null || canToggle,
          showChevron: false,
          onTap: data.onQuietHours,
          trailing: Semantics(
            label: 'Quiet hours',
            toggled: enabled,
            button: true,
            enabled: canToggle,
            onTap: canToggle
                ? () => data.onQuietHoursEnabledChanged!(!enabled)
                : null,
            child: ExcludeSemantics(
              child: Switch(
                key: const ValueKey<String>('quiet-hours-switch'),
                value: enabled,
                onChanged: data.onQuietHoursEnabledChanged,
                activeThumbColor: canToggle ? c.onAccent : c.textFaint,
                activeTrackColor: canToggle ? c.accentFill : c.surfaceRaised,
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
          time: data.quietHoursStart,
          enabled: canEditTimes,
          onChanged: data.onQuietHoursStartChanged,
        ),
        _timeRow(
          context,
          label: 'End',
          time: data.quietHoursEnd,
          enabled: canEditTimes,
          onChanged: data.onQuietHoursEndChanged,
        ),
      ],
    );
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
    for (final setting in data.activity) {
      if (setting.id == id) return setting.value;
    }
    return true;
  }

  Widget _section(
    BuildContext context, {
    required String title,
    required List<Widget> rows,
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
              onTap: handleChanged == null
                  ? null
                  : () => handleChanged(!value),
              child: ExcludeSemantics(
                child: Switch(
                  key:
                      switchKey ??
                      ValueKey<String>('notification-switch-$id'),
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
