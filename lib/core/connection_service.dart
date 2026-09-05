import 'dart:async';

import 'package:flutter/foundation.dart';

import 'agent_service.dart';

/// App-level connectivity signal (the connection monitor brand/connection parity): a tiny
/// reachability probe that never blocks the UI and drives the sidebar
/// chip. No new dependency — reuses HttpShim against a fast, public,
/// CDN-hosted endpoint that answers 204 with no body.
///
/// Semantics:
///   online   — last probe answered within the deadline
///   offline  — last probe failed (or never completed at startup)
///   checking — first probe still in flight
class ConnectionService extends ChangeNotifier {
  ConnectionService._() {
    // Probe on start, then only when a listener re-checks explicitly or
    // the app resumes (see probe() call sites). A periodic timer would
    // waste battery for a signal the user only reads opportunistically.
    probe();
  }

  static final ConnectionService I = ConnectionService._();

  /// Probe target: generates a 204 with no body, ~20 byte response.
  static const _probeUrl = 'https://www.gstatic.com/generate_204';

  ConnectionStatus status = ConnectionStatus.checking;
  DateTime? lastCheckedAt;

  /// One probe. Cheap; called at startup, on sidebar open, and on app
  /// resume. A probe always settles the status — never throws.
  Future<void> probe() async {
    status = ConnectionStatus.checking;
    notifyListeners();
    try {
      final r = await HttpShim.get(
        Uri.parse(_probeUrl),
        timeout: const Duration(seconds: 4),
        maxResponseBytes: 1024,
      );
      status = r.status == 204 || r.status == 200
          ? ConnectionStatus.online
          : ConnectionStatus.offline;
    } catch (_) {
      status = ConnectionStatus.offline;
    }
    lastCheckedAt = DateTime.now();
    notifyListeners();
  }
}

enum ConnectionStatus { checking, online, offline }
