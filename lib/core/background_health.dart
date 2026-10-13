import 'package:flutter/services.dart';

import 'diag.dart';

/// Phone makers whose battery managers kill background apps beyond what
/// stock Android does. [slug] is the dontkillmyapp.com guide page.
enum OemKiller {
  xiaomi('Xiaomi', 'xiaomi', ['xiaomi', 'redmi', 'poco']),
  huawei('Huawei', 'huawei', ['huawei']),
  honor('Honor', 'huawei', ['honor']),
  oppo('Oppo', 'oppo', ['oppo']),
  realme('Realme', 'realme', ['realme']),
  oneplus('OnePlus', 'oneplus', ['oneplus']),
  vivo('Vivo', 'vivo', ['vivo', 'iqoo']),
  samsung('Samsung', 'samsung', ['samsung']),
  asus('Asus', 'asus', ['asus']),
  meizu('Meizu', 'meizu', ['meizu']),
  lenovo('Lenovo', 'lenovo', ['lenovo', 'motorola']),
  nokia('Nokia', 'nokia', ['nokia', 'hmd global']),
  sony('Sony', 'sony', ['sony']),
  transsion('Tecno / Infinix / itel', '', ['tecno', 'infinix', 'itel']);

  const OemKiller(this.label, this.slug, this.makers);

  final String label;
  final String slug;
  final List<String> makers;

  String get guideUrl =>
      slug.isEmpty ? 'https://dontkillmyapp.com/' : 'https://dontkillmyapp.com/$slug';

  /// Matches Build.MANUFACTURER first, then Build.BRAND.
  static OemKiller? detect(String manufacturer, [String brand = '']) {
    for (final raw in [manufacturer, brand]) {
      final m = raw.trim().toLowerCase();
      if (m.isEmpty) continue;
      for (final k in OemKiller.values) {
        if (k.makers.any((maker) => m == maker || m.startsWith('$maker '))) {
          return k;
        }
      }
    }
    return null;
  }
}

/// Snapshot of what decides whether Ovid survives in the background.
class BackgroundHealth {
  const BackgroundHealth({
    required this.android,
    this.sdk = 0,
    this.manufacturer = '',
    this.brand = '',
    this.notificationsAllowed = true,
    this.batteryExempt = true,
    this.exactAlarmsAllowed = true,
    this.alarmMode = 'none',
    this.keepActive = false,
  });

  /// False off Android (desktop, tests): nothing to request.
  final bool android;
  final int sdk;
  final String manufacturer;
  final String brand;
  final bool notificationsAllowed;
  final bool batteryExempt;
  final bool exactAlarmsAllowed;
  final String alarmMode;
  final bool keepActive;

  static const unavailable = BackgroundHealth(android: false);

  factory BackgroundHealth.fromMap(Map<Object?, Object?>? m) {
    if (m == null) return unavailable;
    return BackgroundHealth(
      android: true,
      sdk: (m['sdk'] as num?)?.toInt() ?? 0,
      manufacturer: '${m['manufacturer'] ?? ''}',
      brand: '${m['brand'] ?? ''}',
      notificationsAllowed: m['notificationsEnabled'] != false,
      batteryExempt: m['batteryExempt'] == true,
      exactAlarmsAllowed: m['exactAlarmsAllowed'] != false,
      alarmMode: '${m['alarmMode'] ?? 'none'}',
      keepActive: m['keepActive'] == true,
    );
  }

  OemKiller? get oem => OemKiller.detect(manufacturer, brand);

  /// Exact-alarm access is a separate grant only on Android 12+.
  bool get exactAlarmsNeedGrant => sdk >= 31;

  /// Notification permission is a runtime prompt only on Android 13+.
  bool get notificationsNeedRuntimePrompt => sdk >= 33;
}

/// One requirement row of the background-reliability card.
enum ReliabilityItem { notifications, battery, exactAlarms, oemAutostart }

enum ReliabilityState {
  /// Granted: show a tick.
  ok,

  /// Missing: show the fix button.
  actionNeeded,

  /// Cannot be detected (OEM autostart lists): show guidance + link.
  manual,
}

class ReliabilityRow {
  const ReliabilityRow(this.item, this.state);
  final ReliabilityItem item;
  final ReliabilityState state;

  @override
  bool operator ==(Object other) =>
      other is ReliabilityRow && other.item == item && other.state == state;

  @override
  int get hashCode => Object.hash(item, state);

  @override
  String toString() => '${item.name}:${state.name}';
}

/// The rows the card shows for [h] (pure; unit-tested).
List<ReliabilityRow> reliabilityRows(BackgroundHealth h) {
  if (!h.android) return const [];
  ReliabilityState of(bool ok) =>
      ok ? ReliabilityState.ok : ReliabilityState.actionNeeded;
  return [
    ReliabilityRow(ReliabilityItem.notifications, of(h.notificationsAllowed)),
    ReliabilityRow(ReliabilityItem.battery, of(h.batteryExempt)),
    ReliabilityRow(
      ReliabilityItem.exactAlarms,
      of(!h.exactAlarmsNeedGrant || h.exactAlarmsAllowed),
    ),
    if (h.oem != null)
      const ReliabilityRow(ReliabilityItem.oemAutostart, ReliabilityState.manual),
  ];
}

/// True when every detectable requirement is met.
bool backgroundReady(List<ReliabilityRow> rows) =>
    rows.every((r) => r.state != ReliabilityState.actionNeeded);

/// Reads/changes background status through the native channel. Static
/// seams let widget tests run without a platform.
class BackgroundHealthSource {
  BackgroundHealthSource._();

  static const _channel = MethodChannel('ovid/native');

  static Future<BackgroundHealth> Function() load = _load;
  static Future<void> Function(String method) invoke = _invoke;

  static void reset() {
    load = _load;
    invoke = _invoke;
  }

  static Future<BackgroundHealth> _load() async {
    try {
      final m = await _channel.invokeMapMethod<Object?, Object?>('bgStatus');
      return BackgroundHealth.fromMap(m);
    } on MissingPluginException {
      return BackgroundHealth.unavailable;
    } catch (e) {
      Diag.swallow('background_health.load', e);
      return BackgroundHealth.unavailable;
    }
  }

  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<Object?>(method);
    } on MissingPluginException {
      // Non-Android runtime.
    } catch (e) {
      Diag.swallow('background_health.$method', e);
    }
  }
}
