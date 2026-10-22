import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'connector_models.dart';
import 'connector_store.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

/// What a connection test actually found.
///
/// [ok] is true only when the server answered. [unsupported] marks the cases
/// the app cannot test at all (a workspace command), so the UI can show a
/// neutral note instead of a red failure or a fake success.
@immutable
class V2ConnectorTestReport {
  const V2ConnectorTestReport({
    required this.ok,
    required this.message,
    this.statusCode,
    this.unsupported = false,
  });

  final bool ok;
  final String message;
  final int? statusCode;
  final bool unsupported;
}

/// Runs a real connection test. Implementations must never report success
/// without a server answer.
abstract class V2ConnectorProbe {
  Future<V2ConnectorTestReport> test(
    V2ConnectorConnection connection, {
    String? apiKey,
  });
}

/// Sends one real HTTP request to the connector's endpoint.
///
/// * URL connectors: a `GET` with a short timeout. The credential, when there
///   is one, travels as `Authorization: Bearer …` — the same header the setup
///   form tells the person about.
/// * Command connectors: not run from the app. The report says so instead of
///   pretending the command succeeded.
class V2HttpConnectorProbe implements V2ConnectorProbe {
  V2HttpConnectorProbe({
    this.client,
    this.timeout = const Duration(seconds: 8),
  });

  final http.Client? client;
  final Duration timeout;

  @override
  Future<V2ConnectorTestReport> test(
    V2ConnectorConnection connection, {
    String? apiKey,
  }) async {
    if (connection.isCommand) {
      return const V2ConnectorTestReport(
        ok: false,
        unsupported: true,
        message:
            'Command connectors run inside a workspace session. Ovid cannot '
            'start that command from this screen, so it was not tested.',
      );
    }

    final uri = Uri.tryParse(connection.endpoint.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return const V2ConnectorTestReport(
        ok: false,
        message: 'That endpoint is not a full http:// or https:// URL.',
      );
    }

    final httpClient = client ?? http.Client();
    final ownsClient = client == null;
    final key = apiKey?.trim() ?? '';
    // A credential is never sent in clear text to a remote host. Loopback is
    // the one exception, because a local development server cannot hold a TLS
    // certificate and the key never leaves the machine.
    if (key.isNotEmpty && uri.scheme != 'https' && !_isLoopback(uri.host)) {
      return V2ConnectorTestReport(
        ok: false,
        message:
            'That URL is not HTTPS, so the key was not sent. Use https://.',
      );
    }
    try {
      final request = http.Request('GET', uri);
      request.headers['Accept'] = 'application/json';
      if (key.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $key';
      }
      final streamed = await httpClient.send(request).timeout(timeout);
      // Drain the body so the socket can close, but the status is the answer.
      await streamed.stream.drain<void>().timeout(timeout);
      return _reportFor(
        uri,
        streamed.statusCode,
        authenticated: key.isNotEmpty,
      );
    } on TimeoutException {
      return V2ConnectorTestReport(
        ok: false,
        message:
            '${uri.host} did not answer within ${timeout.inSeconds} seconds.',
      );
    } catch (_) {
      return V2ConnectorTestReport(
        ok: false,
        message: 'Could not reach ${uri.host}. Check the address and your '
            'connection, then test again.',
      );
    } finally {
      if (ownsClient) httpClient.close();
    }
  }

  V2ConnectorTestReport _reportFor(
    Uri uri,
    int status, {
    required bool authenticated,
  }) {
    final host = uri.host;
    if (status >= 200 && status < 400) {
      return V2ConnectorTestReport(
        ok: true,
        statusCode: status,
        message: 'Reached $host — HTTP $status.',
      );
    }
    // A 405 still proves the host answered; the path just refuses GET.
    if (status == 405) {
      return V2ConnectorTestReport(
        ok: true,
        statusCode: status,
        message: 'Reached $host, but that path does not accept GET (HTTP 405).',
      );
    }
    if (status == 401 || status == 403) {
      return V2ConnectorTestReport(
        ok: false,
        statusCode: status,
        message: authenticated
            ? 'The server rejected the credential (HTTP $status).'
            : 'The server needs a credential (HTTP $status). Add one and '
                  'test again.',
      );
    }
    if (status == 404) {
      return V2ConnectorTestReport(
        ok: false,
        statusCode: status,
        message:
            'The server answered, but nothing is served at that path '
            '(HTTP 404).',
      );
    }
    if (status == 429) {
      return V2ConnectorTestReport(
        ok: false,
        statusCode: status,
        message: 'The server is rate limiting this account (HTTP 429).',
      );
    }
    if (status >= 500) {
      return V2ConnectorTestReport(
        ok: false,
        statusCode: status,
        message: 'The server answered with an error (HTTP $status).',
      );
    }
    return V2ConnectorTestReport(
      ok: false,
      statusCode: status,
      message: 'The server answered HTTP $status.',
    );
  }

  /// True for the addresses that never leave the machine.
  bool _isLoopback(String host) {
    final normalized = host.trim().toLowerCase();
    return normalized == 'localhost' ||
        normalized == '::1' ||
        normalized == '[::1]' ||
        normalized == '127.0.0.1' ||
        normalized.startsWith('127.');
  }
}

/// Reads the connector allowance from the tier the app has cached.
///
/// The cache is display-only state (`state.dart` restores it from
/// SharedPreferences); a host that has a server-confirmed tier should pass it
/// through [V2ConnectorPlan] instead. Unknown or missing values fall back to
/// Free so nothing unlocks a paid allowance by accident.
Future<V2ConnectorPlan> v2LoadConnectorPlan({
  V2ConnectorPlan? confirmed,
  Future<String?> Function()? readTier,
}) async {
  if (confirmed != null) return confirmed;
  try {
    final tier = await (readTier ?? _readCachedTier)();
    return V2ConnectorPlan.forTier(tier);
  } catch (_) {
    return V2ConnectorPlan.free;
  }
}

/// The tier `AppState.setOvidCloudTier` caches under `ovid_cloud_tier_v1`.
Future<String?> _readCachedTier() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString('ovid_cloud_tier_v1');
}
