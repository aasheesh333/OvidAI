import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diag.dart';
import 'state.dart';

/// User-facing notifications for work that finishes while Ovid is not on
/// screen: agent runs (finished / needs input / needs approval), scheduled
/// task results and long jobs (image batches, sandbox setup).
///
/// Posting goes through the `ovid/native` channel (OvidNotifications.kt).
/// Android channel sounds are immutable, so each (channel, sound) pair has
/// its own id — [NotificationChannelIds] mirrors the Kotlin formula.

/// The three Ovid notification channels.
enum OvidChannel {
  agentUpdates('agent_updates', ChannelImportance.high, NotificationSound.chime),
  schedulerResults(
    'scheduler_results',
    ChannelImportance.normal,
    NotificationSound.chime,
  ),
  backgroundStatus(
    'background_status',
    ChannelImportance.low,
    NotificationSound.silent,
  );

  const OvidChannel(this.key, this.importance, this.defaultSound);

  /// Wire key shared with Kotlin (`OvidNotifications.AGENT` etc.).
  final String key;
  final ChannelImportance importance;
  final NotificationSound defaultSound;

  /// The status channel is always silent and cannot be re-voiced.
  bool get soundConfigurable => this != OvidChannel.backgroundStatus;
}

enum ChannelImportance { low, normal, high }

/// `chime` is Ovid's own synthesized sound (res/raw/ovid_chime.wav, built by
/// tool/gen_notification_sound.py); `system` is the device default.
enum NotificationSound { chime, system, silent }

class NotificationChannelIds {
  const NotificationChannelIds._();

  static const version = 'v1';

  /// Channels created by older builds; deleted on first configure.
  static const legacy = ['ovid_agent_channel', 'ovid_schedule'];

  static String id(OvidChannel channel, NotificationSound sound) =>
      'ovid_${channel.key}.${sound.name}.$version';

  /// Variants that must not exist once [active] is chosen for [channel].
  static List<String> stale(OvidChannel channel, NotificationSound active) => [
    for (final s in NotificationSound.values)
      if (s != active) id(channel, s),
  ];
}

/// What happened.
enum OvidNotificationKind {
  agentFinished(OvidChannel.agentUpdates),
  agentFailed(OvidChannel.agentUpdates),
  agentNeedsInput(OvidChannel.agentUpdates),
  agentNeedsApproval(OvidChannel.agentUpdates),
  jobDone(OvidChannel.agentUpdates),
  scheduleSucceeded(OvidChannel.schedulerResults),
  scheduleFailed(OvidChannel.schedulerResults);

  const OvidNotificationKind(this.channel);
  final OvidChannel channel;
}

/// App routes a notification tap opens (parsed by `AppRouter.parse`).
class NotificationRoutes {
  const NotificationRoutes._();
  static String chat(String sessionId) => '/c/$sessionId';
  static String schedule(String sessionId) => '/schedule/$sessionId';
  static const home = '/';
  static const settings = '/settings';
}

/// One-line, length-capped summary of model output for a notification body.
String notificationSummary(String text, {int max = 140}) {
  var s = text
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' [code] ')
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
      .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAll(RegExp(r'[*_`#>]+'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (s.length > max) {
    final cut = s.substring(0, max - 1);
    final space = cut.lastIndexOf(' ');
    s = '${(space > max * 0.6 ? cut.substring(0, space) : cut).trimRight()}…';
  }
  return s;
}

/// A notification ready to post.
class OvidNotification {
  OvidNotification({
    required this.kind,
    required this.title,
    required this.body,
    required this.route,
    this.sessionId,
    String? key,
  }) : key = key ?? '${kind.channel.key}:${sessionId ?? route}';

  final OvidNotificationKind kind;
  final String title;
  final String body;
  final String route;
  final String? sessionId;

  /// Stable identity: a newer notification for the same key replaces the
  /// older one instead of stacking (one per session per channel).
  final String key;

  OvidChannel get channel => kind.channel;

  /// Android notification id in [2000, 2000 + 1<<20), stable across runs
  /// (FNV-1a; `String.hashCode` is not stable between processes).
  int get id {
    var h = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      h ^= unit;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return 2000 + (h & 0xfffff);
  }

  Map<String, Object?> toPlatformArgs() => {
    'channel': channel.key,
    'id': id,
    'title': title,
    'body': body,
    'route': route,
  };

  factory OvidNotification.agentFinished({
    required String sessionId,
    required String sessionTitle,
    required String reply,
    int images = 0,
  }) {
    if (images > 0) {
      return OvidNotification(
        kind: OvidNotificationKind.jobDone,
        title: images == 1 ? 'Image ready' : '$images images ready',
        body: _withTitle(sessionTitle, notificationSummary(reply)),
        route: NotificationRoutes.chat(sessionId),
        sessionId: sessionId,
        key: 'agent:$sessionId',
      );
    }
    return OvidNotification(
      kind: OvidNotificationKind.agentFinished,
      title: 'Ovid finished',
      body: _withTitle(
        sessionTitle,
        reply.trim().isEmpty ? 'The reply is ready.' : notificationSummary(reply),
      ),
      route: NotificationRoutes.chat(sessionId),
      sessionId: sessionId,
      key: 'agent:$sessionId',
    );
  }

  factory OvidNotification.agentFailed({
    required String sessionId,
    required String sessionTitle,
    required String error,
  }) => OvidNotification(
    kind: OvidNotificationKind.agentFailed,
    title: 'Ovid stopped with an error',
    body: _withTitle(sessionTitle, notificationSummary(error)),
    route: NotificationRoutes.chat(sessionId),
    sessionId: sessionId,
    key: 'agent:$sessionId',
  );

  factory OvidNotification.needsInput({
    required String sessionId,
    required String sessionTitle,
    required String summary,
    required bool question,
  }) => OvidNotification(
    kind: question
        ? OvidNotificationKind.agentNeedsInput
        : OvidNotificationKind.agentNeedsApproval,
    title: question ? 'Ovid has a question' : 'Ovid needs your approval',
    body: _withTitle(sessionTitle, notificationSummary(summary)),
    route: NotificationRoutes.chat(sessionId),
    sessionId: sessionId,
    key: 'agent:$sessionId',
  );

  factory OvidNotification.scheduleResult({
    required String sessionId,
    required String prompt,
    required bool success,
    String? summary,
    String? error,
  }) => OvidNotification(
    kind: success
        ? OvidNotificationKind.scheduleSucceeded
        : OvidNotificationKind.scheduleFailed,
    title: success
        ? 'Scheduled task done: ${notificationSummary(prompt, max: 48)}'
        : 'Scheduled task failed: ${notificationSummary(prompt, max: 48)}',
    body: success
        ? ((summary ?? '').trim().isEmpty
              ? 'Tap to see the result.'
              : notificationSummary(summary!))
        : notificationSummary(error ?? 'Unknown error'),
    route: NotificationRoutes.schedule(sessionId),
    sessionId: sessionId,
    key: 'schedule:$sessionId:${prompt.hashCode}',
  );

  factory OvidNotification.jobDone({
    required String title,
    required String body,
    String route = NotificationRoutes.home,
    required String key,
  }) => OvidNotification(
    kind: OvidNotificationKind.jobDone,
    title: title,
    body: notificationSummary(body),
    route: route,
    key: key,
  );

  static String _withTitle(String sessionTitle, String text) {
    final t = sessionTitle.trim();
    return t.isEmpty ? text : '$t — $text';
  }
}

/// Where a notification ends up.
enum NotificationDelivery {
  /// Posted to the Android shade (app backgrounded/closed).
  system,

  /// App in the foreground: shown in-app (snackbar), never duplicated.
  inApp,

  /// Not shown: master switch or channel off, or the user is already
  /// looking at that chat.
  suppressed,
}

/// Pure routing decision (unit-tested).
NotificationDelivery decideDelivery({
  required OvidNotification notification,
  required bool masterEnabled,
  required bool channelEnabled,
  required bool appInForeground,
  required String? visibleSessionId,
}) {
  if (!masterEnabled || !channelEnabled) return NotificationDelivery.suppressed;
  if (!appInForeground) return NotificationDelivery.system;
  if (notification.sessionId != null &&
      notification.sessionId == visibleSessionId) {
    return NotificationDelivery.suppressed;
  }
  return NotificationDelivery.inApp;
}

/// Per-channel user settings (on/off + sound).
class NotificationSettings {
  NotificationSettings({
    Map<OvidChannel, bool>? enabled,
    Map<OvidChannel, NotificationSound>? sounds,
    this.quietHoursEnabled = false,
    this.quietHoursStartMinutes = 22 * 60,
    this.quietHoursEndMinutes = 8 * 60,
  }) : enabled = {for (final c in OvidChannel.values) c: enabled?[c] ?? true},
       sounds = {
         for (final c in OvidChannel.values)
           c: c.soundConfigurable
               ? (sounds?[c] ?? c.defaultSound)
               : NotificationSound.silent,
       };

  final Map<OvidChannel, bool> enabled;
  final Map<OvidChannel, NotificationSound> sounds;

  /// Quiet hours suppress SYSTEM notifications only; in-app notices still
  /// appear because the user is already looking at the app.
  bool quietHoursEnabled;
  int quietHoursStartMinutes;
  int quietHoursEndMinutes;

  static const quietHoursEnabledKey = 'ovid_notify_quiet_enabled';
  static const quietHoursStartKey = 'ovid_notify_quiet_start';
  static const quietHoursEndKey = 'ovid_notify_quiet_end';

  /// True when [now] falls inside the window. Handles a window that wraps
  /// midnight (22:00–08:00).
  bool inQuietHours(DateTime now) {
    if (!quietHoursEnabled) return false;
    final minute = now.hour * 60 + now.minute;
    final start = quietHoursStartMinutes.clamp(0, 1439);
    final end = quietHoursEndMinutes.clamp(0, 1439);
    if (start == end) return false;
    if (start < end) return minute >= start && minute < end;
    return minute >= start || minute < end;
  }

  static String enabledKey(OvidChannel c) => 'ovid_notify_enabled_${c.key}';
  static String soundKey(OvidChannel c) => 'ovid_notify_sound_${c.key}';

  static NotificationSettings fromPrefs(SharedPreferences p) =>
      NotificationSettings(
        enabled: {
          for (final c in OvidChannel.values)
            c: p.getBool(enabledKey(c)) ?? true,
        },
        sounds: {
          for (final c in OvidChannel.values)
            c:
                NotificationSound.values
                    .where((s) => s.name == p.getString(soundKey(c)))
                    .firstOrNull ??
                c.defaultSound,
        },
        quietHoursEnabled: p.getBool(quietHoursEnabledKey) ?? false,
        quietHoursStartMinutes: p.getInt(quietHoursStartKey) ?? 22 * 60,
        quietHoursEndMinutes: p.getInt(quietHoursEndKey) ?? 8 * 60,
      );

  Future<void> save(SharedPreferences p) async {
    for (final c in OvidChannel.values) {
      await p.setBool(enabledKey(c), enabled[c]!);
      await p.setString(soundKey(c), sounds[c]!.name);
    }
    await p.setBool(quietHoursEnabledKey, quietHoursEnabled);
    await p.setInt(quietHoursStartKey, quietHoursStartMinutes);
    await p.setInt(quietHoursEndKey, quietHoursEndMinutes);
  }

  /// The channel ids that should exist for these settings.
  Map<OvidChannel, String> get activeChannelIds => {
    for (final c in OvidChannel.values) c: NotificationChannelIds.id(c, sounds[c]!),
  };

  Map<String, Object?> toPlatformArgs() => {
    'sounds': {
      for (final c in OvidChannel.values)
        if (c.soundConfigurable) c.key: sounds[c]!.name,
    },
    'enabled': {for (final c in OvidChannel.values) c.key: enabled[c]!},
  };
}

/// Posts notifications, honouring the user's settings and foreground state.
class BackgroundNotifier extends ChangeNotifier {
  BackgroundNotifier._();
  static final BackgroundNotifier I = BackgroundNotifier._();

  static const _channel = MethodChannel('ovid/native');

  NotificationSettings settings = NotificationSettings();

  /// Foreground test: the UI is resumed. A headless engine (booted by the
  /// service after the app was killed) has no lifecycle state → background.
  @visibleForTesting
  bool Function()? foregroundOverrideForTest;

  bool get appInForeground {
    final override = foregroundOverrideForTest;
    if (override != null) return override();
    try {
      return WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    } catch (_) {
      return false; // no binding: not a visible UI
    }
  }

  /// Installed by main.dart: shows an in-app banner with an Open action.
  void Function(OvidNotification notification)? inAppPresenter;

  /// Calls the platform; tests replace it to record calls.
  @visibleForTesting
  Future<Object?> Function(String method, Object? args)? invokeOverrideForTest;

  Future<Object?> _invoke(String method, [Object? args]) {
    final override = invokeOverrideForTest;
    if (override != null) return override(method, args);
    return _channel.invokeMethod<Object?>(method, args);
  }

  @visibleForTesting
  final List<OvidNotification> postedForTest = [];

  @visibleForTesting
  void resetForTest() {
    settings = NotificationSettings();
    foregroundOverrideForTest = null;
    invokeOverrideForTest = null;
    inAppPresenter = null;
    postedForTest.clear();
    _loaded = false;
  }

  bool _loaded = false;

  /// Loads settings and (re)creates the channels natively. Safe to repeat.
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      settings = NotificationSettings.fromPrefs(prefs);
      _loaded = true;
    } catch (e) {
      Diag.swallow('notify.prefs', e);
    }
    await _configure();
  }

  Future<void> _configure() async {
    try {
      await _invoke('notifyConfigure', settings.toPlatformArgs());
    } on MissingPluginException {
      // Desktop/tests: no Android notifications.
    } catch (e) {
      Diag.swallow('notify.configure', e);
    }
  }

  Future<void> setChannelEnabled(OvidChannel channel, bool on) async {
    settings.enabled[channel] = on;
    await _persistAndConfigure();
  }

  Future<void> setChannelSound(OvidChannel channel, NotificationSound sound) async {
    if (!channel.soundConfigurable) return;
    settings.sounds[channel] = sound;
    await _persistAndConfigure();
  }

  /// Quiet hours suppress system notifications only. Minutes are from
  /// midnight; the window may wrap past midnight.
  Future<void> setQuietHours({
    required bool enabled,
    int? startMinutes,
    int? endMinutes,
  }) async {
    settings.quietHoursEnabled = enabled;
    if (startMinutes != null) {
      settings.quietHoursStartMinutes = startMinutes.clamp(0, 1439);
    }
    if (endMinutes != null) {
      settings.quietHoursEndMinutes = endMinutes.clamp(0, 1439);
    }
    await _persistAndConfigure();
  }

  Future<void> _persistAndConfigure() async {
    notifyListeners();
    try {
      await settings.save(await SharedPreferences.getInstance());
    } catch (e) {
      Diag.swallow('notify.prefs', e);
    }
    await _configure();
  }

  /// Opens Android's own settings page for [channel] (vibration, DND, …).
  Future<void> openChannelSettings(OvidChannel channel) async {
    try {
      await _invoke('notifyOpenChannelSettings', {'channel': channel.key});
    } catch (e) {
      Diag.swallow('notify.channel_settings', e);
    }
  }

  /// Routes [n] per [decideDelivery]. Never throws.
  Future<NotificationDelivery> post(OvidNotification n) async {
    if (!_loaded) {
      try {
        settings = NotificationSettings.fromPrefs(
          await SharedPreferences.getInstance(),
        );
        _loaded = true;
      } catch (e) {
        Diag.swallow('notify.prefs', e);
      }
    }
    bool master;
    String? visible;
    try {
      master = AppState.I.notificationsEnabled;
      visible = AppState.I.activeSessionId;
    } catch (_) {
      master = true;
      visible = null;
    }
    var delivery = decideDelivery(
      notification: n,
      masterEnabled: master,
      channelEnabled: settings.enabled[n.channel] ?? true,
      appInForeground: appInForeground,
      visibleSessionId: visible,
    );
    if (delivery == NotificationDelivery.system &&
        settings.inQuietHours(DateTime.now())) {
      delivery = NotificationDelivery.suppressed;
    }
    switch (delivery) {
      case NotificationDelivery.suppressed:
        break;
      case NotificationDelivery.inApp:
        try {
          inAppPresenter?.call(n);
        } catch (e) {
          Diag.swallow('notify.in_app', e);
        }
      case NotificationDelivery.system:
        postedForTest.add(n);
        try {
          await _invoke('notifyPost', n.toPlatformArgs());
        } on MissingPluginException {
          // Non-Android runtime.
        } catch (e) {
          Diag.swallow('notify.post', e);
        }
    }
    return delivery;
  }

  /// Removes a posted notification (e.g. the approval was answered).
  Future<void> cancel(OvidNotification n) async {
    try {
      await _invoke('notifyCancel', {'id': n.id});
    } on MissingPluginException {
      // Non-Android runtime.
    } catch (e) {
      Diag.swallow('notify.cancel', e);
    }
  }
}
