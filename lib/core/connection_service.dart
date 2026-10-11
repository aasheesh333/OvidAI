import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'agent_service.dart';

/// App-level connectivity signal (the connection monitor brand/connection parity): a tiny
/// reachability probe that never blocks the UI and drives the sidebar
/// chip, the shell's offline banner and the composer's Send button. No new
/// dependency — reuses HttpShim against a fast, public, CDN-hosted endpoint
/// that answers 204 with no body.
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
    bool autoProbe = true,
    this.periodicRecheck = true,
  }) : _reach = reach ?? _defaultReach {
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
    bool periodicRecheck = false,
  }) {
    final s = ConnectionService._(
      reach: reach ?? () async => true,
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

  /// Probe target: generates a 204 with no body, ~20 byte response.
  static const _probeUrl = 'https://www.gstatic.com/generate_204';

  /// Re-check cadence while offline (none while online).
  static const offlineRecheckInterval = Duration(seconds: 30);

  static Future<bool> _defaultReach() async {
    final r = await HttpShim.get(
      Uri.parse(_probeUrl),
      timeout: const Duration(seconds: 4),
      maxResponseBytes: 1024,
    );
    return r.status == 204 || r.status == 200;
  }

  final Future<bool> Function() _reach;

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
