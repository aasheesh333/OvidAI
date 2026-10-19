import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'cloud/cloud_config.dart';

/// App-level connectivity signal: a tiny reachability probe that never
/// blocks the UI and drives the sidebar chip, the shell's offline banner and
/// the outbox (SH-011). It asks the question that matters — "can we reach
/// OVID?" — by GETting the public gateway health route
/// (`https://api.ovidsi.com/cloud/v1/health`). Any HTTP answer from Ovid
/// (200 ok, or 503 degraded) counts as reachable: sends then go through the
/// outbox, which retries by itself. Only when Ovid does not answer at all is
/// a public CDN endpoint asked, purely to tell "no internet" from "Ovid is
/// unreachable" for the banner copy.
///
/// Semantics:
///   online   — last probe answered within the deadline
///   offline  — last probe failed (or never completed at startup)
///   checking — a probe is in flight ([offline] keeps the last settled
///              answer meanwhile, so the banner does not flicker)
///
/// When to probe: at start, on app resume and drawer open (wired by the
/// shell), on a chip tap, and every [offlineRecheckInterval] — but only
/// while offline, so a healthy connection costs no battery.
class ConnectionService extends ChangeNotifier {
  ConnectionService._({
    Future<bool> Function()? reach,
    Future<bool> Function()? internetReach,
    bool autoProbe = true,
    this.periodicRecheck = true,
  })  : _reach = reach ?? _defaultReach,
        _internetReach = internetReach ??
            (reach != null
                ? (() async => false)
                : () async {
                    final s = await _get(_internetProbeUrl);
                    return s == 204 || s == 200;
                  }) {
    if (autoProbe) probe();
  }

  /// Test instance: never touches the network. [reach] answers each probe
  /// (defaults to "reachable"); [status] seeds the current state. The
  /// offline re-check timer is off unless [periodicRecheck] is set, so
  /// widget tests do not end with a pending timer.
  @visibleForTesting
  factory ConnectionService.forTest({
    ConnectionStatus status = ConnectionStatus.online,
    Future<bool> Function()? reach,
    Future<bool> Function()? internetReach,
    bool periodicRecheck = false,
  }) {
    final s = ConnectionService._(
      reach: reach ?? () async => true,
      internetReach: internetReach,
      autoProbe: false,
      periodicRecheck: periodicRecheck,
    );
    s._settle(status);
    return s;
  }

  static ConnectionService? _instance;
  static ConnectionService get I => _instance ??= _isFlutterTest
      // Widget tests have no network (HttpClient answers 400), which would
      // read as "offline" and disable Send in every chat test. Tests opt in
      // to connectivity behaviour via [debugInstance] instead.
      ? ConnectionService.forTest()
      : ConnectionService._();

  static bool get _isFlutterTest {
    try {
      return Platform.environment['FLUTTER_TEST'] == 'true';
    } catch (_) {
      return false;
    }
  }

  /// Swap the process instance (tests). Null restores lazy production init.
  @visibleForTesting
  static set debugInstance(ConnectionService? value) {
    _instance?._timer?.cancel();
    _instance = value;
  }

  /// Primary probe: Ovid's own public health route.
  static String get ovidProbeUrl => '${CloudConfig.restBase}/health';

  /// Secondary probe, only consulted when Ovid did not answer: tells "no
  /// internet at all" from "Ovid is unreachable".
  static const _internetProbeUrl = 'https://www.gstatic.com/generate_204';

  /// Re-check cadence while offline (none while online).
  static const offlineRecheckInterval = Duration(seconds: 30);

  /// True when the last failed probe found the internet up but Ovid
  /// unreachable (the banner says so instead of "you're offline").
  bool ovidUnreachable = false;

  static Future<bool> _defaultReach() async {
    // Ovid answering at all (200 ok or 503 degraded) is "reachable".
    final status = await _get(ovidProbeUrl);
    return status != null && (status == 200 || status == 503);
  }

  /// Status code of a bounded GET, or null when nothing answered.
  static Future<int?> _get(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 4));
      // Deliberately no redirect guard: both targets are FIXED URLs that
      // answer directly.
      final response =
          await request.close().timeout(const Duration(seconds: 4));
      // Drain at most 1 KiB so an unexpected body can never grow the probe.
      var read = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 4))) {
        read += chunk.length;
        if (read >= 1024) break;
      }
      return response.statusCode;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  final Future<bool> Function() _reach;
  final Future<bool> Function() _internetReach;

  /// Whether to re-probe every [offlineRecheckInterval] while offline.
  final bool periodicRecheck;
  Timer? _timer;
  Future<void>? _inFlight;

  ConnectionStatus status = ConnectionStatus.checking;
  DateTime? lastCheckedAt;
  bool _offline = false;

  /// Whether the last settled probe failed. Stays true while a re-check is
  /// in flight so the UI does not flash "online" between probes.
  bool get offline => _offline;

  /// One probe. Cheap; concurrent calls share the in-flight probe. A probe
  /// always settles the status — never throws.
  Future<void> probe() => _inFlight ??= _probe().whenComplete(() {
    _inFlight = null;
  });

  Future<void> _probe() async {
    status = ConnectionStatus.checking;
    notifyListeners();
    var ok = false;
    try {
      ok = await _reach();
    } catch (_) {
      ok = false;
    }
    var internetUp = false;
    if (!ok) {
      try {
        internetUp = await _internetReach();
      } catch (_) {
        internetUp = false;
      }
    }
    ovidUnreachable = !ok && internetUp;
    _settle(ok ? ConnectionStatus.online : ConnectionStatus.offline);
  }

  void _settle(ConnectionStatus next) {
    status = next;
    if (next != ConnectionStatus.checking) {
      _offline = next == ConnectionStatus.offline;
      lastCheckedAt = DateTime.now();
    }
    if (_offline && periodicRecheck) {
      _timer ??= Timer.periodic(offlineRecheckInterval, (_) => probe());
    } else {
      _timer?.cancel();
      _timer = null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

enum ConnectionStatus { checking, online, offline }
