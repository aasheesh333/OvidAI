import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'mcp_config_parse.dart';

/// Why an MCP OAuth step failed. The sheet maps each kind to plain copy, so
/// no raw `Bad state:` text reaches the user (03 §11).
enum McpOAuthErrorKind {
  /// The user (or the authorization server) declined access
  /// (`error=access_denied` or another OAuth `error` on the callback).
  denied,

  /// The callback belongs to an older attempt (state mismatch).
  stateMismatch,

  /// The pasted text is not the redirect for this attempt (wrong address,
  /// the sign-in link itself, missing `code`, extra parameters).
  redirectMismatch,

  /// The attempt expired, was already used, or was cancelled.
  expired,

  /// The token endpoint rejected the code exchange.
  tokenExchange,

  /// The stored OAuth config is unusable (no client id, invalid redirect).
  config,

  /// Automatic discovery or dynamic client registration failed.
  discovery,

  /// The server was removed or re-configured while signing in.
  replaced,
}

/// Typed OAuth failure. Extends [StateError] so existing callers that
/// match `StateError` keep working. Messages never carry callback secrets.
class McpOAuthException extends StateError {
  McpOAuthException(this.kind, super.message, {this.status});

  final McpOAuthErrorKind kind;

  /// HTTP status for [McpOAuthErrorKind.tokenExchange] failures.
  final int? status;

  /// Whether the pending attempt is still usable after this error (the
  /// user can simply paste again).
  bool get attemptStillValid =>
      kind == McpOAuthErrorKind.redirectMismatch ||
      kind == McpOAuthErrorKind.stateMismatch;
}

/// One parsed `WWW-Authenticate: Bearer …` challenge (RFC 6750 §3 + RFC 9728
/// §5.1 `resource_metadata`).
class McpBearerChallenge {
  const McpBearerChallenge({
    this.resourceMetadata,
    this.scope,
    this.error,
    this.realm,
  });

  final String? resourceMetadata;
  final String? scope;
  final String? error;
  final String? realm;

  /// Parse the Bearer challenge out of a `WWW-Authenticate` header value.
  /// Returns null when the header carries no Bearer challenge.
  static McpBearerChallenge? parse(String? header) {
    if (header == null || header.trim().isEmpty) return null;
    final match = RegExp(
      r'(?:^|,)\s*Bearer\b',
      caseSensitive: false,
    ).firstMatch(header);
    if (match == null) return null;
    final rest = header.substring(match.end);
    final params = <String, String>{};
    final param = RegExp(
      r'''\s*,?\s*([A-Za-z0-9_\-]+)\s*=\s*("(?:[^"\\]|\\.)*"|[^\s,]+)''',
    );
    var offset = 0;
    while (offset < rest.length) {
      final m = param.matchAsPrefix(rest, offset);
      if (m == null) break;
      final name = m.group(1)!.toLowerCase();
      var value = m.group(2)!;
      if (value.startsWith('"')) {
        value = value
            .substring(1, value.length - 1)
            .replaceAllMapped(RegExp(r'\\(.)'), (x) => x.group(1)!);
      }
      // Parsing stops at the first token that is not `name=value`, which
      // is where a following challenge scheme would begin.
      params.putIfAbsent(name, () => value);
      offset = m.end;
    }
    return McpBearerChallenge(
      resourceMetadata: params['resource_metadata'],
      scope: params['scope'],
      error: params['error'],
      realm: params['realm'],
    );
  }
}

/// HTTPS (or loopback HTTP for local development) without user info or a
/// fragment — the only destinations OAuth metadata, registration and token
/// requests may go to.
Uri requireOAuthEndpoint(String? value, {String what = 'OAuth endpoint'}) {
  final uri = Uri.tryParse(value ?? '');
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      RegExp(
        r'^https?://[^/?#]*@',
        caseSensitive: false,
      ).hasMatch(value ?? '') ||
      (uri.scheme != 'https' &&
          !(uri.scheme == 'http' &&
              const {'127.0.0.1', '::1', 'localhost'}.contains(uri.host)))) {
    throw McpOAuthException(
      McpOAuthErrorKind.discovery,
      '$what requires HTTPS (or loopback HTTP)',
    );
  }
  return uri;
}

/// Automatic OAuth setup for a remote MCP server that answered 401
/// (MCP authorization spec 2025-06-18):
///
///  1. RFC 9728 protected-resource metadata — from the challenge's
///     `resource_metadata`, else the `/.well-known/oauth-protected-resource`
///     path-aware then root location.
///  2. RFC 8414 authorization-server metadata for the first listed
///     authorization server (OAuth metadata, then OpenID configuration).
///     Servers without protected-resource metadata fall back to the
///     2025-03-26 rule: the MCP origin is the authorization server, with
///     `/authorize`, `/token` and `/register` as defaults.
///  3. RFC 7591 dynamic client registration as a public client
///     (`token_endpoint_auth_method: none`, PKCE S256).
///
/// The returned config carries the RFC 8707 `resource` indicator, which
/// the service sends on the authorize, token and refresh requests.
class McpOAuthDiscovery {
  McpOAuthDiscovery({this.client, this.clientName = 'Ovid'});

  /// Injected HTTP client (tests); a private one is created otherwise.
  final http.Client? client;
  final String clientName;

  static const _timeout = Duration(seconds: 15);

  Future<McpOAuthConfig> discover({
    required String serverUrl,
    required String redirectUri,
    String? wwwAuthenticate,
  }) async {
    final server = requireOAuthEndpoint(serverUrl, what: 'MCP server URL');
    final challenge = McpBearerChallenge.parse(wwwAuthenticate);
    final httpClient = client ?? http.Client();
    try {
      // ── 1. Protected-resource metadata (RFC 9728) ────────────────────
      final prmCandidates = <Uri>[
        if ((challenge?.resourceMetadata ?? '').isNotEmpty)
          requireOAuthEndpoint(
            challenge!.resourceMetadata,
            what: 'Resource metadata URL',
          )
        else ...[
          if (server.path.isNotEmpty && server.path != '/')
            _wellKnown(server, 'oauth-protected-resource', server.path),
          _wellKnown(server, 'oauth-protected-resource', ''),
        ],
      ];
      Map<String, dynamic>? prm;
      for (final candidate in prmCandidates) {
        prm = await _getJson(httpClient, candidate);
        if (prm != null) break;
      }
      final canonicalResource = _canonicalResource(server);
      String resource = canonicalResource;
      Uri issuer;
      if (prm != null) {
        final declared = prm['resource'];
        if (declared is String && declared.isNotEmpty) {
          final declaredUri = Uri.tryParse(declared);
          if (declaredUri == null ||
              declaredUri.scheme != server.scheme ||
              declaredUri.host.toLowerCase() != server.host.toLowerCase() ||
              declaredUri.port != server.port) {
            throw McpOAuthException(
              McpOAuthErrorKind.discovery,
              'Resource metadata names a different server',
            );
          }
          resource = declared;
        }
        final servers = prm['authorization_servers'];
        final first = servers is List && servers.isNotEmpty
            ? servers.first
            : null;
        if (first is! String || first.isEmpty) {
          throw McpOAuthException(
            McpOAuthErrorKind.discovery,
            'Resource metadata lists no authorization server',
          );
        }
        issuer = requireOAuthEndpoint(first, what: 'Authorization server');
      } else {
        issuer = Uri(
          scheme: server.scheme,
          host: server.host,
          port: server.hasPort ? server.port : null,
        );
      }

      // ── 2. Authorization-server metadata (RFC 8414 / OIDC) ───────────
      final issuerPath = issuer.path == '/' ? '' : issuer.path;
      final asmCandidates = <Uri>[
        _wellKnown(issuer, 'oauth-authorization-server', issuerPath),
        _wellKnown(issuer, 'openid-configuration', issuerPath),
        if (issuerPath.isNotEmpty)
          issuer.replace(
            path:
                '${issuerPath.replaceAll(RegExp(r'/$'), '')}'
                '/.well-known/openid-configuration',
          ),
      ];
      Map<String, dynamic>? asm;
      for (final candidate in asmCandidates) {
        asm = await _getJson(httpClient, candidate);
        if (asm != null) break;
      }
      String? authorizationEndpoint;
      String? tokenEndpoint;
      String? registrationEndpoint;
      String? issuerId;
      if (asm != null) {
        final declaredIssuer = asm['issuer'];
        if (declaredIssuer is String &&
            declaredIssuer.isNotEmpty &&
            _trimSlash(declaredIssuer) != _trimSlash(issuer.toString())) {
          throw McpOAuthException(
            McpOAuthErrorKind.discovery,
            'Authorization server metadata issuer mismatch',
          );
        }
        issuerId = declaredIssuer is String && declaredIssuer.isNotEmpty
            ? declaredIssuer
            : null;
        authorizationEndpoint = asm['authorization_endpoint'] as String?;
        tokenEndpoint = asm['token_endpoint'] as String?;
        registrationEndpoint = asm['registration_endpoint'] as String?;
        final methods = asm['code_challenge_methods_supported'];
        if (methods is List && !methods.contains('S256')) {
          throw McpOAuthException(
            McpOAuthErrorKind.discovery,
            'Authorization server does not support PKCE (S256)',
          );
        }
      } else if (prm == null) {
        // 2025-03-26 fallback: default endpoints on the MCP origin.
        authorizationEndpoint = issuer.replace(path: '/authorize').toString();
        tokenEndpoint = issuer.replace(path: '/token').toString();
        registrationEndpoint = issuer.replace(path: '/register').toString();
      } else {
        throw McpOAuthException(
          McpOAuthErrorKind.discovery,
          'Authorization server metadata not found',
        );
      }
      requireOAuthEndpoint(authorizationEndpoint, what: 'Authorize endpoint');
      requireOAuthEndpoint(tokenEndpoint, what: 'Token endpoint');

      final scopes = <String>[
        ...?(challenge?.scope)
            ?.split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty),
      ];
      if (scopes.isEmpty && prm?['scopes_supported'] is List) {
        scopes.addAll([
          for (final s in prm!['scopes_supported'] as List)
            if (s is String && s.isNotEmpty) s,
        ]);
      }

      // ── 3. Dynamic client registration (RFC 7591) ────────────────────
      if (registrationEndpoint == null || registrationEndpoint.isEmpty) {
        throw McpOAuthException(
          McpOAuthErrorKind.discovery,
          'This server needs a pre-registered OAuth client — add an "oauth" '
          'block with a client_id to its config',
        );
      }
      final registration = await _register(
        httpClient,
        requireOAuthEndpoint(
          registrationEndpoint,
          what: 'Registration endpoint',
        ),
        redirectUri: redirectUri,
        scopes: scopes,
      );
      return McpOAuthConfig(
        authorizationUrl: authorizationEndpoint,
        tokenUrl: tokenEndpoint,
        clientId: registration.$1,
        clientSecret: registration.$2,
        scopes: scopes,
        redirectUri: redirectUri,
        resource: resource,
        issuer: issuerId,
        discovered: true,
      );
    } on McpOAuthException {
      rethrow;
    } on TimeoutException {
      throw McpOAuthException(
        McpOAuthErrorKind.discovery,
        'The sign-in server did not respond in time',
      );
    } catch (_) {
      throw McpOAuthException(
        McpOAuthErrorKind.discovery,
        'Could not discover how to sign in to this server',
      );
    } finally {
      if (client == null) httpClient.close();
    }
  }

  static String _trimSlash(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  /// RFC 8707 resource indicator: the server URL without query or fragment.
  static String _canonicalResource(Uri server) => Uri(
    scheme: server.scheme,
    host: server.host,
    port: server.hasPort ? server.port : null,
    path: server.path,
  ).toString();

  /// RFC 8414 §3 / RFC 9728 §3: insert the well-known segment between the
  /// host and the (path-aware) resource or issuer path.
  static Uri _wellKnown(Uri base, String name, String path) {
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '/.well-known/$name$trimmed',
    );
  }

  Future<Map<String, dynamic>?> _getJson(http.Client client, Uri uri) async {
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';
    final streamed = await client.send(request).timeout(_timeout);
    final res = await http.Response.fromStream(streamed).timeout(_timeout);
    if (res.statusCode != 200) return null;
    try {
      final decoded = jsonDecode(res.body);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } on FormatException {
      return null;
    }
  }

  Future<(String, String?)> _register(
    http.Client client,
    Uri endpoint, {
    required String redirectUri,
    required List<String> scopes,
  }) async {
    final request = http.Request('POST', endpoint)
      ..followRedirects = false
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'application/json'
      ..body = jsonEncode({
        'client_name': clientName,
        'redirect_uris': [redirectUri],
        'grant_types': ['authorization_code', 'refresh_token'],
        'response_types': ['code'],
        'token_endpoint_auth_method': 'none',
        if (scopes.isNotEmpty) 'scope': scopes.join(' '),
      });
    final streamed = await client.send(request).timeout(_timeout);
    final res = await http.Response.fromStream(streamed).timeout(_timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw McpOAuthException(
        McpOAuthErrorKind.discovery,
        'Client registration failed (HTTP ${res.statusCode})',
        status: res.statusCode,
      );
    }
    final decoded = jsonDecode(res.body);
    final clientId = decoded is Map ? decoded['client_id'] : null;
    if (clientId is! String || clientId.isEmpty) {
      throw McpOAuthException(
        McpOAuthErrorKind.discovery,
        'Client registration returned no client_id',
      );
    }
    final secret = (decoded as Map)['client_secret'];
    return (clientId, secret is String && secret.isNotEmpty ? secret : null);
  }
}
