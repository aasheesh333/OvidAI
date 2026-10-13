import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/background_health.dart';
import '../core/background_notifications.dart';
import '../core/diag.dart';
import '../core/distribution.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../l10n/l10n.dart';
import 'widgets/aether_primitives.dart';

/// Onboarding/settings card for background operation: notification
/// permission, battery-optimization exemption, exact alarms and OEM
/// autostart guidance, each with a status tick and a fix button; plus the
/// "Keep Ovid active in background" switch and per-type notification
/// settings (on/off, sound, Android channel settings).
///
/// [compact] (Schedule screen): only the requirement rows, and nothing at
/// all once everything is granted.
class BackgroundReliabilityCard extends StatefulWidget {
  const BackgroundReliabilityCard({super.key, this.compact = false});

  final bool compact;

  /// Notification permission prompt; tests replace it.
  static Future<PermissionStatus> Function() requestNotifications = () =>
      Permission.notification.request();

  /// Opens a guide URL; tests replace it.
  static Future<bool> Function(Uri uri) openUrl = (uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  @visibleForTesting
  static void resetSeams() {
    requestNotifications = () => Permission.notification.request();
    openUrl = (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
    BackgroundHealthSource.reset();
  }

  @override
  State<BackgroundReliabilityCard> createState() =>
      _BackgroundReliabilityCardState();
}

class _BackgroundReliabilityCardState extends State<BackgroundReliabilityCard>
    with WidgetsBindingObserver {
  BackgroundHealth? _health;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from a system settings page: pick up the new grant.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final h = await BackgroundHealthSource.load();
    if (mounted) setState(() => _health = h);
  }

  Future<void> _fix(ReliabilityItem item) async {
    try {
      switch (item) {
        case ReliabilityItem.notifications:
          final h = _health;
          var granted = false;
          if (h != null && h.notificationsNeedRuntimePrompt) {
            granted = (await BackgroundReliabilityCard.requestNotifications())
                .isGranted;
          }
          if (!granted) {
            await BackgroundHealthSource.invoke('notifyOpenAppSettings');
          }
        case ReliabilityItem.battery:
          await BackgroundHealthSource.invoke('requestBatteryExemption');
        case ReliabilityItem.exactAlarms:
          await BackgroundHealthSource.invoke('bgRequestExactAlarm');
        case ReliabilityItem.oemAutostart:
          await BackgroundHealthSource.invoke('openAutoStartSettings');
      }
    } catch (e) {
      Diag.swallow('background_card.fix', e);
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final h = _health;
    if (h == null) return const SizedBox.shrink();
    final rows = reliabilityRows(h);
    final ready = backgroundReady(rows);
    if (widget.compact && (rows.isEmpty || ready)) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    final pending = rows
        .where((r) => r.state == ReliabilityState.actionNeeded)
        .length;
    final body = Column(
      key: const ValueKey('background-reliability-card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (rows.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.bgCardTitle, style: AetherType.title),
                const SizedBox(height: 4),
                Text(
                  ready ? l10n.bgCardReady : l10n.bgCardNeedsAttention(pending),
                  key: const ValueKey('background-reliability-summary'),
                  style: AetherType.caption,
                ),
              ],
            ),
          ),
          for (final row in rows) _row(context, h, row),
        ],
        if (!widget.compact) ...[
          if (Distribution.idleKeepAliveAvailable) const _KeepActiveSwitch(),
          const _ChannelSettings(),
        ],
      ],
    );
    return widget.compact
        ? Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: AetherCard(
              padding: const EdgeInsets.only(bottom: 8),
              child: body,
            ),
          )
        : body;
  }

  Widget _row(BuildContext context, BackgroundHealth h, ReliabilityRow row) {
    final l10n = context.l10n;
    final maker = h.oem?.label ?? '';
    final (String title, String detail) = switch (row.item) {
      ReliabilityItem.notifications => (
        l10n.bgNotificationsTitle,
        row.state == ReliabilityState.ok
            ? l10n.bgNotificationsOk
            : l10n.bgNotificationsNeeded,
      ),
      ReliabilityItem.battery => (
        l10n.bgBatteryTitle,
        row.state == ReliabilityState.ok
            ? l10n.bgBatteryOk
            : l10n.bgBatteryNeeded,
      ),
      ReliabilityItem.exactAlarms => (
        l10n.bgExactTitle,
        row.state == ReliabilityState.ok ? l10n.bgExactOk : l10n.bgExactNeeded,
      ),
      ReliabilityItem.oemAutostart => (
        l10n.bgOemTitle(maker),
        l10n.bgOemBody(maker),
      ),
    };
    final Widget status = switch (row.state) {
      ReliabilityState.ok => Icon(
        Icons.check_circle,
        size: 20,
        color: Aether.success,
        semanticLabel: l10n.bgStatusOk,
      ),
      ReliabilityState.actionNeeded => Icon(
        Icons.error_outline,
        size: 20,
        color: Aether.warn,
        semanticLabel: l10n.bgStatusNeeded,
      ),
      ReliabilityState.manual => Icon(
        Icons.info_outline,
        size: 20,
        color: Aether.textMuted,
      ),
    };
    final Widget? trailing = switch (row.state) {
      ReliabilityState.ok => null,
      ReliabilityState.actionNeeded => TextButton(
        key: ValueKey('background-fix-${row.item.name}'),
        onPressed: () => _fix(row.item),
        child: Text(l10n.bgActionAllow),
      ),
      ReliabilityState.manual => Wrap(
        children: [
          TextButton(
            key: const ValueKey('background-fix-oemAutostart'),
            onPressed: () => _fix(row.item),
            child: Text(l10n.bgActionOpen),
          ),
          TextButton(
            key: const ValueKey('background-oem-guide'),
            onPressed: () async {
              try {
                await BackgroundReliabilityCard.openUrl(
                  Uri.parse(h.oem!.guideUrl),
                );
              } catch (e) {
                Diag.swallow('background_card.guide', e);
              }
            },
            child: Text(l10n.bgActionGuide),
          ),
        ],
      ),
    };
    return ListTile(
      key: ValueKey('background-row-${row.item.name}'),
      dense: true,
      leading: status,
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        detail,
        style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
      ),
      trailing: trailing,
    );
  }
}

class _KeepActiveSwitch extends StatelessWidget {
  const _KeepActiveSwitch();

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) => SwitchListTile(
        key: const ValueKey('keep-active-switch'),
        dense: true,
        secondary: Icon(Icons.bolt_outlined, size: 19, color: Aether.textMuted),
        title: Text(
          context.l10n.bgKeepActiveTitle,
          style: const TextStyle(fontSize: 14),
        ),
        subtitle: Text(
          app.keepAliveEnabled
              ? context.l10n.bgKeepActiveOn
              : context.l10n.bgKeepActiveOff,
          style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
        ),
        value: app.keepAliveEnabled,
        activeTrackColor: Aether.accent,
        onChanged: (v) => app.keepAliveEnabled = v,
      ),
    );
  }
}

class _ChannelSettings extends StatelessWidget {
  const _ChannelSettings();

  @override
  Widget build(BuildContext context) {
    final notifier = BackgroundNotifier.I;
    final l10n = context.l10n;
    return AnimatedBuilder(
      animation: notifier,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
            child: Text(l10n.bgChannelsTitle, style: AetherType.label),
          ),
          for (final channel in OvidChannel.values)
            _ChannelTile(channel: channel, notifier: notifier),
        ],
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({required this.channel, required this.notifier});

  final OvidChannel channel;
  final BackgroundNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (String name, String hint) = switch (channel) {
      OvidChannel.agentUpdates => (l10n.bgChannelAgent, l10n.bgChannelAgentHint),
      OvidChannel.schedulerResults => (
        l10n.bgChannelSchedule,
        l10n.bgChannelScheduleHint,
      ),
      OvidChannel.backgroundStatus => (
        l10n.bgChannelStatus,
        l10n.bgChannelStatusHint,
      ),
    };
    String soundName(NotificationSound s) => switch (s) {
      NotificationSound.chime => l10n.bgSoundChime,
      NotificationSound.system => l10n.bgSoundSystem,
      NotificationSound.silent => l10n.bgSoundSilent,
    };
    final settings = notifier.settings;
    final enabled = settings.enabled[channel] ?? true;
    return Padding(
      key: ValueKey('channel-${channel.key}'),
      padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: const TextStyle(fontSize: 14)),
                    Text(
                      hint,
                      style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: ValueKey('channel-settings-${channel.key}'),
                tooltip: l10n.bgChannelSystemSettings,
                icon: Icon(Icons.tune, size: 19, color: Aether.textMuted),
                onPressed: () => notifier.openChannelSettings(channel),
              ),
              if (channel.soundConfigurable)
                Switch(
                  key: ValueKey('channel-switch-${channel.key}'),
                  value: enabled,
                  activeTrackColor: Aether.accent,
                  onChanged: (v) => notifier.setChannelEnabled(channel, v),
                ),
            ],
          ),
          if (channel.soundConfigurable && enabled)
            Row(
              children: [
                Text(l10n.bgSoundLabel, style: AetherType.caption),
                const SizedBox(width: 12),
                DropdownButton<NotificationSound>(
                  key: ValueKey('channel-sound-${channel.key}'),
                  value: settings.sounds[channel],
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final s in NotificationSound.values)
                      DropdownMenuItem(value: s, child: Text(soundName(s))),
                  ],
                  onChanged: (s) {
                    if (s != null) notifier.setChannelSound(channel, s);
                  },
                ),
              ],
            ),
        ],
      ),
    );
  }
}
