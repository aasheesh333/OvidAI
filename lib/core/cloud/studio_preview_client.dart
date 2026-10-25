import 'package:flutter/foundation.dart';

import 'cloud_rest.dart';
import 'cloud_session_store.dart';

/// The two preview policies the native renderer supports.
enum StudioPreviewKind {
  staticSite('static'),
  devServer('dev_server');

  const StudioPreviewKind(this.wireValue);

  final String wireValue;
}

enum StudioPreviewStatus {
  starting,
  running,
  stopping,
  stopped,
  failed,
  expired,
}

/// A server-issued project/start-script capability for preview creation.
///
/// The current public gateway has no capability route, so production cannot
/// construct one and the preview start control stays hidden. When that route
/// exists, parse its response instead of inventing a default `dev` script.
@immutable
class StudioPreviewRegistration {
  const StudioPreviewRegistration._({
    required this.projectDir,
    required this.startScriptId,
  });

  final String projectDir;
  final String startScriptId;

  static StudioPreviewRegistration? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final projectDir = raw['projectDir'];
    final startScriptId = raw['startScriptId'];
    if (projectDir is! String || startScriptId is! String) return null;
    try {
      _validateProjectDir(projectDir);
    } on StudioPreviewException {
      return null;
    }
    if (!_validScriptId(startScriptId)) return null;
    return StudioPreviewRegistration._(
      projectDir: projectDir,
      startScriptId: startScriptId,
    );
  }
}

/// Public, non-sensitive preview registration metadata.
///
/// There is deliberately no host, port, upstream, command, ticket, or cookie
/// field here. Private process addressing never crosses the gateway boundary.
@immutable
class StudioPreview {
  const StudioPreview({
    required this.id,
    required this.kind,
    required this.status,
    required this.generation,
    required this.expiresAt,
    required this.lastAccessAt,
    required this.logAvailable,
  });

  final String id;
  final StudioPreviewKind kind;
  final StudioPreviewStatus status;
  final int? generation;
  final DateTime? expiresAt;
  final DateTime? lastAccessAt;
  final bool? logAvailable;

  factory StudioPreview.fromJson(
    Map<String, dynamic> json, {
    String? expectedSessionId,
  }) {
    final id = json['id'] ?? json['previewId'];
    final kind = json['kind'];
    final status = json['status'];
    final responseSessionId = json['sessionId'];
    if (id is! String || !_validPreviewId(id)) {
      throw const StudioPreviewException(
        'invalid_response',
        'Ovid Cloud returned an invalid preview registration.',
      );
    }
    if (expectedSessionId != null &&
        responseSessionId is String &&
        responseSessionId != expectedSessionId) {
      throw const StudioPreviewException(
        'cross_tenant',
        'That preview is not available.',
      );
    }
    final parsedKind = switch (kind) {
      'static' => StudioPreviewKind.staticSite,
      'dev_server' => StudioPreviewKind.devServer,
      _ => null,
    };
    final parsedStatus = switch (status) {
      'starting' => StudioPreviewStatus.starting,
      'running' => StudioPreviewStatus.running,
      'stopping' => StudioPreviewStatus.stopping,
      'stopped' => StudioPreviewStatus.stopped,
      'failed' => StudioPreviewStatus.failed,
      'expired' => StudioPreviewStatus.expired,
      _ => null,
    };
    if (parsedKind == null || parsedStatus == null) {
      throw const StudioPreviewException(
        'invalid_response',
        'Ovid Cloud returned an invalid preview registration.',
      );
    }
    final generation = json['generation'];
    return StudioPreview(
      id: id,
      kind: parsedKind,
      status: parsedStatus,
      generation: generation is num ? generation.toInt() : null,
      expiresAt: _dateOrNull(json['expiresAt']),
      lastAccessAt: _dateOrNull(json['lastAccessAt']),
      logAvailable: json['logAvailable'] is bool
          ? json['logAvailable'] as bool
          : null,
    );
  }
}

/// A single-use launch grant. It lives only in memory until the native view
/// consumes it; the clean URL is the only URL shown or copied by the UI.
@immutable
class StudioPreviewLaunch {
  const StudioPreviewLaunch._({
    required this.launchUrl,
    required this.ticketExpiresAt,
    required this.cookieExpiresAt,
  });

  final String launchUrl;
  final DateTime ticketExpiresAt;
  final DateTime cookieExpiresAt;

  factory StudioPreviewLaunch.fromJson(Map<String, dynamic> json) {
    final url = json['launchUrl'];
    final ticketExpiry = _dateOrNull(json['ticketExpiresAt']);
    final cookieExpiry = _dateOrNull(json['cookieExpiresAt']);
    if (url is! String || ticketExpiry == null || cookieExpiry == null) {
      throw const StudioPreviewException(
        'invalid_launch',
        'Ovid Cloud returned an invalid preview launch.',
      );
    }
    _validateLaunchUrl(url);
    return StudioPreviewLaunch._(
      launchUrl: url,
      ticketExpiresAt: ticketExpiry,
      cookieExpiresAt: cookieExpiry,
    );
  }

  /// The post-exchange address contains no ticket and no Ovid API authority.
  String cleanUrl(String previewId) {
    if (!_validPreviewId(previewId)) {
      throw const StudioPreviewException(
        'invalid_preview',
        'That preview is not available.',
      );
    }
    final exchange = Uri.parse(launchUrl);
    return Uri(
      scheme: 'https',
      host: exchange.host,
      path: '/preview/${Uri.encodeComponent(previewId)}/',
    ).toString();
  }
}

@immutable
class StudioPreviewOpen {
  const StudioPreviewOpen({required this.preview, required this.launch});

  final StudioPreview preview;

  /// Null while starting/stopping or after a terminal status. A frame may only
  /// be created for a running registration with a fresh, valid launch grant.
  final StudioPreviewLaunch? launch;
}

/// Safe preview failure. Upstream response bodies and URLs are never retained.
class StudioPreviewException implements Exception {
  const StudioPreviewException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class _PreviewRegistration {
  const _PreviewRegistration({
    required this.localSessionId,
    required this.serverSessionId,
    required this.projectDir,
  });

  final String localSessionId;
  final String serverSessionId;
  final String projectDir;
}

/// Thin client for session-scoped preview registration and ticket routes.
///
/// A preview id can be used only after this client received it from `create`.
/// This prevents callers from turning an arbitrary id into a cross-tenant
/// probe. Tickets are never cached, persisted, logged, or attached to refresh
/// requests; the native WebView exchanges each one exactly once.
class StudioPreviewClient {
  StudioPreviewClient({CloudRestClient? rest, CloudSessionStore? sessions})
    : _rest = rest ?? CloudRestClient.I,
      // ignore: prefer_initializing_formals
      _sessions = sessions;

  static StudioPreviewClient? _instance;

  static StudioPreviewClient get I => _instance ??= StudioPreviewClient();

  @visibleForTesting
  static void installForTest(StudioPreviewClient? client) => _instance = client;

  final CloudRestClient _rest;
  final CloudSessionStore? _sessions;
  final Map<String, _PreviewRegistration> _registrations =
      <String, _PreviewRegistration>{};

  CloudSessionStore get _store => _sessions ?? CloudSessionStore.I;

  Future<StudioPreview> create(
    String sessionId, {
    required String projectDir,
    required String startScriptId,
  }) async {
    _validateProjectDir(projectDir);
    if (!_validScriptId(startScriptId)) {
      throw const StudioPreviewException(
        'invalid_script',
        'Choose a registered preview start script.',
      );
    }
    return _guarded(() async {
      final serverId = await _requireServerId(sessionId);
      final json = await _rest.postJson(
        '/studio/sessions/$serverId/previews',
        body: <String, Object>{
          'projectDir': projectDir,
          'startScriptId': startScriptId,
        },
      );
      final preview = StudioPreview.fromJson(json, expectedSessionId: serverId);
      _registrations[preview.id] = _PreviewRegistration(
        localSessionId: sessionId,
        serverSessionId: serverId,
        projectDir: projectDir,
      );
      return preview;
    });
  }

  Future<StudioPreviewOpen> open(String previewId) => _open(previewId);

  /// Always mints a fresh ticket for a running preview. No earlier ticket is
  /// read or reused, including when the previous launch failed.
  Future<StudioPreviewOpen> refresh(String previewId) => _open(previewId);

  Future<StudioPreviewOpen> _open(String previewId) {
    return _guarded(() async {
      final registration = _registration(previewId);
      final base =
          '/studio/sessions/${registration.serverSessionId}/previews/$previewId';
      final json = await _rest.getJson(base);
      final preview = StudioPreview.fromJson(
        json,
        expectedSessionId: registration.serverSessionId,
      );
      if (preview.status != StudioPreviewStatus.running) {
        return StudioPreviewOpen(preview: preview, launch: null);
      }
      final launchJson = await _rest.postJson('$base/ticket');
      return StudioPreviewOpen(
        preview: preview,
        launch: StudioPreviewLaunch.fromJson(launchJson),
      );
    });
  }

  Future<void> stop(String previewId) {
    return _guarded(() async {
      final registration = _registration(previewId);
      await _rest.postJson(
        '/studio/sessions/${registration.serverSessionId}/previews/$previewId/stop',
      );
      _registrations.remove(previewId);
    });
  }

  /// Stops registrations rooted at a deleted workspace project. A sibling
  /// such as `app2` never matches the `app` boundary.
  Future<void> stopProject(String projectDir) async {
    final ids = <String>[
      for (final entry in _registrations.entries)
        if (entry.value.projectDir == projectDir ||
            entry.value.projectDir.startsWith('$projectDir/'))
          entry.key,
    ];
    await _stopAll(ids);
  }

  /// Hibernation cleanup for this app's session-scoped registrations.
  Future<void> stopAll() => _stopAll(_registrations.keys.toList());

  Future<void> _stopAll(List<String> previewIds) async {
    Object? firstError;
    for (final previewId in previewIds) {
      try {
        await stop(previewId);
      } catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) throw firstError;
  }

  _PreviewRegistration _registration(String previewId) {
    if (!_validPreviewId(previewId)) {
      throw const StudioPreviewException(
        'invalid_preview',
        'That preview is not available.',
      );
    }
    final registration = _registrations[previewId];
    if (registration == null) {
      throw const StudioPreviewException(
        'unknown_preview',
        'That preview is not registered to this Studio session.',
      );
    }
    return registration;
  }

  Future<String> _requireServerId(String sessionId) async {
    final store = _store;
    await store.resolveServerSessionIdAsync(sessionId);
    final serverId = store.knownServerIdFor(sessionId);
    if (serverId == null) {
      throw const StudioPreviewException(
        'no_server_session',
        'Open Studio from a cloud chat to start a preview.',
      );
    }
    return serverId;
  }

  Future<T> _guarded<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on StudioPreviewException {
      rethrow;
    } on CloudApiException catch (error) {
      final code = switch (error.code) {
        'preview_denied' ||
        'ticket_replay' ||
        'cross_tenant' ||
        'no_server_session' ||
        'preview_unavailable' => error.code,
        'not_found' => 'preview_denied',
        _ => 'preview_failed',
      };
      final message = switch (code) {
        'preview_unavailable' =>
          'Live preview is not available on this deployment.',
        'no_server_session' =>
          'Open Studio from a cloud chat to start a preview.',
        'ticket_replay' =>
          'That preview ticket was already used. Refresh to continue.',
        _ => 'The preview request did not finish. Try again.',
      };
      throw StudioPreviewException(code, message);
    }
  }
}

void _validateProjectDir(String projectDir) {
  final valid =
      projectDir.length <= 512 &&
      projectDir.isNotEmpty &&
      projectDir == projectDir.trim() &&
      !projectDir.startsWith('/') &&
      !projectDir.contains('\\') &&
      !projectDir.contains('\u0000') &&
      (projectDir == '.' ||
          projectDir
              .split('/')
              .every(
                (segment) =>
                    segment.isNotEmpty && segment != '.' && segment != '..',
              ));
  if (!valid) {
    throw const StudioPreviewException(
      'invalid_project',
      'Choose a registered workspace project folder.',
    );
  }
}

bool _validPreviewId(String value) =>
    value.length <= 128 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

bool _validScriptId(String value) =>
    value.length <= 64 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

DateTime? _dateOrNull(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

void _validateLaunchUrl(String value) {
  final uri = Uri.tryParse(value);
  final query = uri?.queryParametersAll;
  final valid =
      value.length <= 4096 &&
      uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      !uri.hasPort &&
      uri.userInfo.isEmpty &&
      uri.fragment.isEmpty &&
      uri.path == '/preview/exchange' &&
      query != null &&
      query.length == 1 &&
      query['ticket']?.length == 1 &&
      (query['ticket']?.single.isNotEmpty ?? false) &&
      (query['ticket']?.single.length ?? 0) <= 512;
  if (!valid) {
    throw const StudioPreviewException(
      'invalid_launch',
      'Ovid Cloud returned an invalid preview launch.',
    );
  }
}
