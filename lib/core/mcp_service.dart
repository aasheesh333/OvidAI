import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';
import 'package:path_provider/path_provider.dart';

import 'github_service.dart';
import 'mcp_config_parse.dart';
import 'native_mcp.dart';
import 'sandbox_service.dart';
import 'secure_store.dart';
import 'plugin_manifest.dart';
import 'plugin_registry.dart';
import 'state.dart';
import 'diag.dart';

/// Sends one Streamable-HTTP request without allowing the HTTP client to
/// replay credentials or request bodies at a redirect destination. Redirects
/// are rejected rather than followed; the configured MCP URL is the only
/// approved destination for these requests.
Future<http.Response> _sendMcpHttpRequest(
  http.Client client,
  String method,
  Uri uri,
  Map<String, String> headers, {
  String? body,
  required Duration timeout,
}) async {
  final request = http.Request(method, uri)
    ..followRedirects = false
    ..headers.addAll(headers);
  if (body != null) request.body = body;
  final response = await client.send(request).timeout(timeout);
  if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
    unawaited(response.stream.listen(null).cancel());
    throw StateError('MCP HTTP redirect rejected');
  }
  return http.Response.fromStream(response).timeout(timeout);
}

/// OAuth access token for one MCP server (item 6). Stored per-server in
/// secure storage via [McpService.storeMcpOAuthToken] — never in the
/// config file or prefs. Expired tokens are refreshed automatically when
/// the config carries a refresh token and a `token_url`.
class McpOAuthToken {
  final String accessToken;
  final String? refreshToken;
  final String tokenType;
  final DateTime? expiresAt;

  const McpOAuthToken({
    required this.accessToken,
    this.refreshToken,
    this.tokenType = 'Bearer',
    this.expiresAt,
  });

  bool get isExpired =>
      expiresAt != null &&
      DateTime.now().isAfter(expiresAt!.subtract(const Duration(seconds: 30)));

  bool get canRefresh => refreshToken != null && refreshToken!.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'token_type': tokenType,
    'expires_at': expiresAt?.toIso8601String(),
  };

  factory McpOAuthToken.fromJson(Map<String, dynamic> j) => McpOAuthToken(
    accessToken: j['access_token']?.toString() ?? '',
    refreshToken: j['refresh_token']?.toString(),
    tokenType: j['token_type']?.toString() ?? 'Bearer',
    expiresAt: switch (j['expires_at']) {
      String s => DateTime.tryParse(s),
      int ms => DateTime.fromMillisecondsSinceEpoch(ms),
      _ => null,
    },
  );

  /// Parse an OAuth token endpoint response (`access_token`, optional
  /// `refresh_token`/`token_type`/`expires_in`).
  factory McpOAuthToken.fromTokenResponse(Map<String, dynamic> j) {
    final expiresIn = j['expires_in'];
    final access = j['access_token'];
    final type = j['token_type'] ?? 'Bearer';
    if (access is! String ||
        access.isEmpty ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(access) ||
        type is! String ||
        type.toLowerCase() != 'bearer' ||
        (j.containsKey('refresh_token') && j['refresh_token'] is! String) ||
        (j.containsKey('expires_in') &&
            (expiresIn is! int || expiresIn < 0 || expiresIn > 315360000))) {
      throw const FormatException('Malformed OAuth token response');
    }
    return McpOAuthToken(
      accessToken: access,
      refreshToken: j['refresh_token'] as String?,
      tokenType: 'Bearer',
      expiresAt: expiresIn is num
          ? DateTime.now().add(Duration(seconds: expiresIn.toInt()))
          : null,
    );
  }
}

/// Browser handoff. State and the PKCE verifier stay owned by the service;
/// callers pass the complete callback URI to completeMcpOAuthAuthorization.
class McpOAuthAuthorization {
  final String authorizationUrl;
  final DateTime expiresAt;
  final McpOAuthConfig _config;
  final String _state;
  final String _verifier;
  final Object _generation;
  McpOAuthAuthorization._(
    this.authorizationUrl,
    this.expiresAt,
    this._config,
    this._state,
    this._verifier,
    this._generation,
  );
}

/// Legacy MCP SSE transport channel (GET /sse event stream + POST
/// /message endpoint — the pre-Streamable-HTTP protocol). One channel per
/// connected `sse` server:
///
///  1. `open()` GETs the SSE URL with `Accept: text/event-stream` and waits
///     for the first `event: endpoint` carrying the POST URL.
///  2. `post()` POSTs a JSON-RPC message to that endpoint.
///  3. `nextResponse(id)` awaits the SSE event whose JSON `id` matches.
///
/// The GET stream stays open for the channel's lifetime; [close] tears it
/// down. All waits are bounded by caller-supplied timeouts.
class _SseMcpChannel {
  _SseMcpChannel._(
    this._client,
    this._ownsClient,
    this._onDestinationRejected,
    this._onNotification,
    this._onClosed,
  );

  factory _SseMcpChannel({
    http.Client? client,
    required void Function(String) onDestinationRejected,
    required void Function(Map<String, dynamic>) onNotification,
    required void Function() onClosed,
  }) => _SseMcpChannel._(
    client ?? http.Client(),
    client == null,
    onDestinationRejected,
    onNotification,
    onClosed,
  );

  final http.Client _client;
  final bool _ownsClient;
  final void Function(String) _onDestinationRejected;
  final void Function(Map<String, dynamic>) _onNotification;
  final void Function() _onClosed;
  StreamSubscription<String>? _sub;

  Uri? messageEndpoint;
  bool get isOpen => messageEndpoint != null && !_closed;
  bool _closed = false;
  Uri? _configuredUrl;
  String? _destinationFailure;
  final _responseWaiters = <Completer<void>>{};

  final List<Map<String, dynamic>> _pending = [];
  Completer<void>? _waiter;
  final StringBuffer _buf = StringBuffer();

  /// Open the SSE stream and resolve the POST endpoint. Throws on
  /// non-200, on timeout waiting for the `endpoint` event, or when the
  /// stream closes early.
  Future<void> open(
    String sseUrl,
    Map<String, String> headers, {
    Duration? timeout,
  }) async {
    _configuredUrl = _parseDestination(sseUrl);
    final res = await _send('GET', _configuredUrl!, {
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-cache',
      ...headers,
    }, timeout: timeout ?? const Duration(seconds: 30));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      unawaited(res.stream.listen(null).cancel());
      _closeClient();
      throw Exception('SSE stream failed: HTTP ${res.statusCode}');
    }
    _sub = res.stream
        .transform(utf8.decoder)
        .listen(
          _onChunk,
          onError: (_) => _onDone(),
          onDone: _onDone,
          cancelOnError: true,
        );
    // The endpoint event must arrive promptly — without it nothing can be
    // posted. Bound the wait so a hanging stream can't wedge connect().
    final deadline = timeout ?? const Duration(seconds: 30);
    final start = DateTime.now();
    while (messageEndpoint == null && !_closed) {
      final elapsed = DateTime.now().difference(start);
      final left = deadline - elapsed;
      if (left.isNegative) break;
      _waiter = Completer<void>();
      try {
        await _waiter!.future.timeout(left);
      } on TimeoutException {
        break;
      } finally {
        _waiter = null;
      }
    }
    if (_destinationFailure != null) {
      throw StateError(_destinationFailure!);
    }
    if (messageEndpoint == null) {
      await close();
      throw TimeoutException(
        'SSE endpoint event not received within ${deadline.inSeconds}s',
        deadline,
      );
    }
  }

  void _onChunk(String chunk) {
    if (_closed) return;
    _buf.write(chunk);
    var text = _buf.toString();
    // SSE framing: events are separated by a blank line.
    while (true) {
      final idx = text.indexOf('\n\n');
      final idx2 = text.indexOf('\r\n\r\n');
      var sep = -1;
      var sepLen = 2;
      if (idx >= 0 && (idx2 < 0 || idx < idx2)) {
        sep = idx;
      } else if (idx2 >= 0) {
        sep = idx2;
        sepLen = 4;
      }
      if (sep < 0) break;
      final rawEvent = text.substring(0, sep);
      text = text.substring(sep + sepLen);
      _onEvent(rawEvent);
      if (_closed) break;
    }
    _buf.clear();
    _buf.write(text);
  }

  void _onEvent(String rawEvent) {
    String? eventType;
    final dataParts = <String>[];
    for (final rawLine in rawEvent.split('\n')) {
      final line = rawLine.trimRight();
      if (line.startsWith('event:')) {
        eventType = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataParts.add(line.substring(5).trim());
      }
      // `:` comments / `id:` / `retry:` are ignored.
    }
    if (dataParts.isEmpty) return;
    final data = dataParts.join('\n');
    if (eventType == 'endpoint') {
      try {
        // Always use the configured stream URL, even after a GET redirect.
        messageEndpoint = _resolveDestination(_configuredUrl!, data);
      } on StateError {
        // Refusal already closes the channel and wakes the opening waiter.
      }
      _wake();
      return;
    }
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) {
        if (!decoded.containsKey('id')) {
          _onNotification(decoded);
        } else {
          _pending.add(decoded);
        }
        _wake();
      }
    } catch (_) {
      // Non-JSON SSE data (pings, comments) — ignore.
    }
  }

  Never _rejectDestination(String reason) {
    // Do not echo server-supplied URLs: userinfo/query strings can be secrets.
    _destinationFailure = 'SSE destination rejected: $reason';
    messageEndpoint = null;
    _pending.clear();
    for (final waiter in _responseWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    unawaited(close());
    _onDestinationRejected(_destinationFailure!);
    throw StateError(_destinationFailure!);
  }

  Uri _validateDestination(Uri uri) {
    final origin = _configuredUrl!;
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.port <= 0 ||
        uri.port > 65535) {
      _rejectDestination('invalid HTTP(S) URL');
    }
    if (uri.scheme != origin.scheme ||
        uri.host != origin.host ||
        uri.port != origin.port) {
      _rejectDestination('origin must match the configured stream');
    }
    return uri;
  }

  Uri _parseDestination(String value) {
    final text = value.trim();
    if (text.isEmpty) _rejectDestination('empty URL');
    // Uri normalizes an empty userinfo away. Reject it before normalization,
    // as well as nonempty userinfo checked on the resolved URI below.
    final authority = RegExp(
      r'^(?:[a-zA-Z][a-zA-Z0-9+.-]*:)?//([^/?#]*)',
    ).firstMatch(text)?.group(1);
    if (authority?.contains('@') ?? false) {
      _rejectDestination('userinfo is not allowed');
    }
    try {
      return Uri.parse(text);
    } on FormatException {
      _rejectDestination('malformed URL');
    }
  }

  Uri _resolveDestination(Uri base, String value) =>
      _validateDestination(base.resolveUri(_parseDestination(value)));

  /// Own redirect handling rather than relying on IOClient's automatic
  /// forwarding (which cannot know which custom headers contain credentials).
  /// An unapproved transition sends nothing, including credentials or body.
  Future<http.StreamedResponse> _send(
    String method,
    Uri uri,
    Map<String, String> headers, {
    String? body,
    required Duration timeout,
  }) async {
    final clock = Stopwatch()..start();
    for (var redirects = 0; ; redirects++) {
      if (_closed) {
        throw StateError(_destinationFailure ?? 'SSE channel is not open');
      }
      _validateDestination(uri);
      final left = timeout - clock.elapsed;
      if (left <= Duration.zero) {
        throw TimeoutException('SSE request timed out');
      }
      final req = http.Request(method, uri)..followRedirects = false;
      req.headers.addAll(headers);
      if (body != null) req.body = body;
      final http.StreamedResponse res;
      try {
        res = await _client.send(req).timeout(left);
      } catch (_) {
        // An endpoint event can reject/close the channel while this request
        // is in flight. Preserve the policy error instead of a socket error.
        if (_destinationFailure != null) {
          throw StateError(_destinationFailure!);
        }
        rethrow;
      }
      if (_closed) {
        unawaited(res.stream.listen(null).cancel());
        throw StateError(_destinationFailure ?? 'SSE channel is not open');
      }
      if (!const {301, 302, 303, 307, 308}.contains(res.statusCode)) {
        return res;
      }
      // Cancel rather than drain an attacker-controlled, potentially endless
      // redirect body. Do not close an injected/shared client.
      unawaited(res.stream.listen(null).cancel());
      final location = res.headers['location'];
      if (location == null) _rejectDestination('redirect has no location');
      final next = _resolveDestination(uri, location);
      if (redirects >= 5) _rejectDestination('too many redirects');
      if (method == 'POST') {
        if (res.statusCode == 303) {
          // Match HTTP's See Other semantics; never replay a POST as a GET body.
          method = 'GET';
          body = null;
          headers = Map.of(headers)
            ..removeWhere((key, _) => key.toLowerCase() == 'content-type');
        } else if (res.statusCode != 307 && res.statusCode != 308) {
          _rejectDestination('ambiguous POST redirect');
        }
      }
      uri = next;
    }
  }

  void _wake() {
    final w = _waiter;
    if (w != null && !w.isCompleted) w.complete();
    for (final waiter in _responseWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  void _onDone() {
    _closed = true;
    _wake();
    _onClosed();
  }

  /// POST a JSON-RPC message to the resolved endpoint.
  Future<void> post(
    Map<String, dynamic> message,
    Map<String, String> headers, {
    Duration? timeout,
  }) async {
    final endpoint = messageEndpoint;
    if (endpoint == null || _closed) {
      throw StateError(_destinationFailure ?? 'SSE channel is not open');
    }
    final res = await _send(
      'POST',
      endpoint,
      {'Content-Type': 'application/json', ...headers},
      body: jsonEncode(message),
      timeout: timeout ?? const Duration(seconds: 60),
    );
    // Only the status matters; responses themselves arrive on the SSE stream.
    unawaited(res.stream.listen(null).cancel());
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw Exception(
        'authentication failed (HTTP ${res.statusCode}) — check the '
        'server\'s auth headers/token and re-connect after fixing them.',
      );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('SSE POST failed: HTTP ${res.statusCode}');
    }
  }

  /// Await the SSE event whose JSON-RPC `id` matches [id]. Returns null on
  /// timeout or when the stream closed first.
  Future<Map<String, dynamic>?> nextResponse(
    int id, {
    Duration? timeout,
  }) async {
    final deadline = DateTime.now().add(timeout ?? const Duration(seconds: 60));
    while (true) {
      if (_destinationFailure != null) throw StateError(_destinationFailure!);
      for (var i = 0; i < _pending.length; i++) {
        if (_pending[i]['id']?.toString() == id.toString()) {
          return _pending.removeAt(i);
        }
      }
      if (_closed) return null;
      final left = deadline.difference(DateTime.now());
      if (left.isNegative) return null;
      final waiter = Completer<void>();
      _waiter = waiter;
      _responseWaiters.add(waiter);
      try {
        // Policy refusal wakes every outstanding response wait, including
        // callers whose normal response waiter has since been replaced.
        await waiter.future.timeout(left);
      } on TimeoutException {
        return null;
      } finally {
        _responseWaiters.remove(waiter);
        _waiter = null;
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    _wake();
    final sub = _sub;
    _sub = null;
    if (sub != null) {
      // Cancel WITHOUT awaiting: an async* generator parked in `await for`
      // on the event stream may never acknowledge the cancellation while
      // the server keeps the stream open, and disconnect must not hang on
      // it. `_closed` already makes the channel dead; closing the owned
      // HTTP client below tears down a real socket, which unparks the
      // generator via stream-done.
      unawaited(sub.cancel());
    }
    _closeClient();
  }

  void _closeClient() {
    if (_ownsClient) {
      try {
        _client.close();
      } catch (e) {
        Diag.swallow('mcp_service', e);
      }
    }
  }
}

/// Real MCP client — connects to each server over its configured
/// transport (stdio: spawn inside the sandbox and speak JSON-RPC over
/// stdin/stdout; http: POST JSON-RPC to a Streamable-HTTP endpoint, no
/// sandbox needed), discovers tools via `tools/list`, and bridges
/// `tools/call` for the agent.
///
/// Process model (stdio): one Process per connected server, started via
/// SandboxService.spawn — servers run inside the native sandbox env.
/// Lifecycle is lazy — `connect()` spawns/dials + handshakes, `disconnect()`
/// kills/drops.
///
/// Reliability contract (matches the MCP client gateway behavior):
///   • a JSON-RPC error response surfaces as a thrown/returned error, never
///     as a successful result;
///   • a timeout surfaces as an explicit error string, never the text "null";
///   • a server that dies drops out of the connected map immediately, so
///     nothing stays "connected" with a dead pipe;
///   • `notifications/tools/list_changed` triggers a silent re-discovery
///     (stdio only — an HTTP server has no persistent notification channel
///     in the Streamable-HTTP request/response model Ovid uses);
///   • tool results are capped so a chatty server can't flood the context;
///   • PR41: an UNEXPECTED disconnect (stdio process death, or an HTTP call
///     failing with a connection-level error) schedules automatic
///     reconnection with exponential backoff — `ovid-mcp-client` parity
///     (500ms → 30s, giving up after 10 consecutive failures). A
///     user-initiated `disconnect()` never triggers this.
/// Launchers whose ONLY purpose is to fetch and run a package, so an empty
/// (or flag-only) argument list is definitively unrunnable rather than merely
/// unusual. Kept deliberately narrow — `node`, `python`, `sh` and friends take
/// scripts/modules/flags in forms this cannot judge, and must not be rejected.
const Set<String> _kPackageLauncherCommands = {'npx', 'uvx', 'bunx'};

class McpService {
  McpService._();
  static final McpService I = McpService._();

  final Map<String, _RunningServer> _running = {};
  // Sanitized terminal policy reasons, retained until explicit disconnect or
  // a new reserved attempt. Closed channels/tools are never kept advertised.
  final Map<String, String> _sseDestinationFailures = {};

  /// Connected servers and the tools they advertise.
  Map<String, List<McpToolDef>> get connectedTools => {
    for (final e in _running.entries) e.key: e.value.tools,
  };

  /// Discovered tools with their owning server identity. The agent uses this
  /// to publish canonical plugin-owned names and only-unambiguous aliases.
  List<McpConnectedTool> get connectedToolEntries => List.unmodifiable([
    for (final rs in _running.values)
      for (final tool in rs.tools) McpConnectedTool(rs.server, tool),
  ]);

  McpConnectedTool? resolveToolName(
    String toolName, {
    bool Function(McpServer server)? visible,
  }) => _resolveToolEntries(toolName, connectedToolEntries, visible: visible);

  static McpConnectedTool? _resolveToolEntries(
    String toolName,
    Iterable<McpConnectedTool> entries, {
    bool Function(McpServer server)? visible,
  }) {
    final candidates = entries
        .where((entry) => visible == null || visible(entry.server))
        .toList();
    final canonical = candidates
        .where((entry) => entry.canonicalToolName == toolName)
        .toList();
    if (canonical.length == 1) return canonical.single;
    if (canonical.length > 1) return null;
    final aliases = candidates
        .where((entry) => entry.legacyToolName == toolName)
        .toList();
    return aliases.length == 1 ? aliases.single : null;
  }

  @visibleForTesting
  static McpConnectedTool? resolveToolEntriesForTest(
    String toolName,
    Iterable<McpConnectedTool> entries,
  ) => _resolveToolEntries(toolName, entries);

  static String _providerEncode(String value) {
    final readable = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final prefix = (readable.isEmpty ? 'id' : readable);
    final boundedPrefix = prefix.length <= 27
        ? prefix
        : prefix.substring(0, 27);
    final digest = sha256
        .convert(utf8.encode(value))
        .toString()
        .substring(0, 32);
    return '${boundedPrefix}_$digest';
  }

  static String providerServerToolName(McpServer server) =>
      'mcp_${_providerEncode(server.canonicalId)}';

  /// Root-variable env for a plugin-owned server's process.
  ///
  /// Mirrors the hook runtime's contract: a bundle's MCP server may read
  /// `CLAUDE_PLUGIN_ROOT`/`PLUGIN_ROOT` itself, or shell out to a sibling
  /// script inside its own content dir. Without these the variable is unset
  /// and the server misbehaves — for every [CC]/Codex bundle that relies on it.
  static Map<String, String> _pluginRootEnv(String ownerPluginId) {
    final manifest = PluginContributionRegistry.I.manifestFor(ownerPluginId);
    final root = manifest?.rootPath ?? '';
    if (root.isEmpty) return const {};
    return {
      'CLAUDE_PLUGIN_ROOT': root,
      // Codex bundles read their own variable; without it a Codex server's
      // `${CODEX_PLUGIN_ROOT}/server.js` stays literal and never resolves.
      'CODEX_PLUGIN_ROOT': root,
      'OVID_PLUGIN_ROOT': root,
      'PLUGIN_ROOT': root,
    };
  }

  static String? _runtimeRoot(McpServer server) {
    final owner = server.ownerPluginId;
    if (owner == null) return null;
    final manifest = PluginContributionRegistry.I.manifestFor(owner);
    if (manifest == null || manifest.rootPath.isEmpty) return null;
    return Directory(manifest.rootPath).parent.path;
  }

  String _key(McpServer server) => server.canonicalId;

  String _keyForName(String serverName) {
    if (_running.containsKey(serverName)) return serverName;
    final match = AppState.I.mcpServers
        .where((s) => s.name == serverName || s.canonicalId == serverName)
        .firstOrNull;
    return match?.canonicalId ?? serverName;
  }

  bool isConnected(String serverName) {
    final rs = _running[_keyForName(serverName)];
    return rs != null && rs.handshakeDone;
  }

  /// Test seam: the MCP protocol version negotiated for [serverName]'s HTTP
  /// session (null until `initialize` completes).
  @visibleForTesting
  String? protocolVersionForTest(String serverName) =>
      _running[_keyForName(serverName)]?.protocolVersion;

  /// Test seam: capabilities advertised in [serverName]'s initialize result.
  @visibleForTesting
  Map<String, dynamic> capabilitiesForTest(String serverName) =>
      _running[_keyForName(serverName)]?.capabilities ?? const {};

  /// Test seam: the remembered `Mcp-Session-Id` for [serverName].
  @visibleForTesting
  String? httpSessionIdForTest(String serverName) =>
      _running[_keyForName(serverName)]?.sessionId;

  /// Inline cap for a tool result handed to the model. Oversized output is
  /// trimmed head+tail with an exact omission notice (spill-style).
  @visibleForTesting
  static const maxToolResultCharsForTest = _maxToolResultChars;
  static const _maxToolResultChars = 6000;

  @visibleForTesting
  static String trimResultForTest(String text) => _trimResult(text);

  static String _trimResult(String text) {
    if (text.length <= _maxToolResultChars) return text;
    final head = text.substring(0, _maxToolResultChars ~/ 2);
    final tail = text.substring(text.length - _maxToolResultChars ~/ 2);
    final omitted = text.length - _maxToolResultChars;
    return '$head\n\n[…$omitted characters omitted — ask again with a '
        'narrower query to see the middle…]\n\n$tail';
  }

  /// Decoded byte length of a base64 content block, so binary payloads can
  /// be reported by size instead of dropped. Falls back to the base64
  /// arithmetic when the data isn't valid base64.
  static int _base64ByteLength(String data) {
    try {
      return base64Decode(data).length;
    } catch (_) {
      final clean = data.replaceAll(RegExp(r'\s'), '');
      final padding = clean.endsWith('==')
          ? 2
          : clean.endsWith('=')
          ? 1
          : 0;
      final length = (clean.length * 3 ~/ 4) - padding;
      return length < 0 ? 0 : length;
    }
  }

  /// Test seam: replace the HTTP client used by the 'http' transport.
  @visibleForTesting
  http.Client? httpClientForTest;

  final Map<String, NativeMcpHandler Function(McpServer server)>
  _nativeHandlerFactories = {};

  void registerNativeHandler(
    String serverIdOrName,
    NativeMcpHandler Function(McpServer server) factory,
  ) {
    _nativeHandlerFactories[serverIdOrName.toLowerCase()] = factory;
  }

  @visibleForTesting
  void unregisterNativeHandler(String serverIdOrName) {
    _nativeHandlerFactories.remove(serverIdOrName.toLowerCase());
  }

  @visibleForTesting
  void clearNativeHandlers() {
    _nativeHandlerFactories.clear();
  }

  @visibleForTesting
  static String? memoryStoragePathOverrideForTest;

  /// Test seam: resolve (migrating the legacy shared store when present) the
  /// per-server memory store under [docsPath].
  @visibleForTesting
  static Future<File> memoryStorageFileForTest(
    String docsPath,
    McpServer server,
  ) => _resolveMemoryStorageFile(docsPath, server);

  /// Test seam: reconnect backoff timing, shortened so tests run in
  /// milliseconds instead of real seconds.
  @visibleForTesting
  static Duration reconnectInitialDelayForTest = const Duration(
    milliseconds: 500,
  );
  @visibleForTesting
  static Duration reconnectMaxDelayForTest = const Duration(seconds: 30);
  @visibleForTesting
  static int reconnectMaxAttemptsForTest = 10;

  /// Test seam: injectable clock for the complete-handshake budget so a test
  /// can advance time between initialize → initialized → tools/list and
  /// observe the remaining-time propagation.
  @visibleForTesting
  static DateTime Function() clockForTest = DateTime.now;

  /// Test seam: records the remaining budget passed to each handshake phase.
  @visibleForTesting
  static void Function(String phase, Duration timeout)?
  connectPhaseTimeoutRecorderForTest;

  /// Test seam: awaited after preflight but before transport creation, so a
  /// test can expire the deadline and prove no slot/process is leaked.
  @visibleForTesting
  static Future<void> Function()? beforeReserveHookForTest;

  static DateTime _now() => clockForTest();

  static void _recordConnectPhase(String phase, Duration timeout) =>
      connectPhaseTimeoutRecorderForTest?.call(phase, timeout);

  /// Test seam: when set, [_connectStdio] spawns the server through this
  /// instead of [SandboxService.spawn] and skips the sandbox-installed
  /// gate plus the lazy runtime ensure. Lets a test drive a REAL
  /// subprocess MCP server on the host (no Android sandbox present).
  /// Null in production — the sandbox path is untouched.
  @visibleForTesting
  static Future<Process> Function(
    List<String> argv, {
    Map<String, String>? env,
    Directory? hostWorkDir,
  })?
  spawnProcessForTest;

  /// Spawn/dial the server and perform the MCP handshake
  /// (initialize → initialized → tools/list).
  ///
  /// Returns a human-readable status string for the UI.
  Future<String> connect(McpServer server) async {
    final outcome = await connectOutcome(
      server,
      handshakeBudget: Duration(seconds: server.startupTimeoutS),
    );
    return outcome.reason ?? '"${server.name}" connected';
  }

  /// Complete-handshake startup connect with ONE budget covering credential
  /// lookup, runtime ensure, spawn/dial, initialize, initialized, and
  /// tools/list (spec §5.7). Never throws; returns a truthful outcome.
  ///
  /// The budget is `min(server.startupTimeoutS, 30s)` at the call site. A
  /// timeout removes the exact reserved slot, marks the attempt user-aborted
  /// BEFORE killing the process, closes owned transports, and never
  /// marks the handshake done — a detached late completion is ignored.
  Future<McpConnectOutcome> connectOutcome(
    McpServer server, {
    required Duration handshakeBudget,
  }) async {
    final key = _key(server);
    final deadline = _now().add(handshakeBudget);
    final existing = _running[key];
    if (existing != null) {
      if (existing.handshakeDone) {
        return McpConnectOutcome(
          McpConnectOutcomeKind.ready,
          '"${server.name}" is already connected',
        );
      }
      // A joiner's local wait budget never cancels the owner of the attempt.
      return existing.connection.future.timeout(
        handshakeBudget,
        onTimeout: () => const McpConnectOutcome(
          McpConnectOutcomeKind.failed,
          'MCP handshake timed out',
        ),
      );
    }
    // Reservation is synchronous and precedes EVERY credential/runtime wait.
    final rs = _RunningServer(server: server);
    _captureOwnership(rs);
    _running[key] = rs;
    _sseDestinationFailures.remove(key);
    _reconnectTimers.remove(key)?.cancel();

    Future<McpConnectOutcome> runAttempt() async {
      final ownerReason = _ownerInactiveReason(server);
      if (ownerReason != null) {
        return McpConnectOutcome(
          McpConnectOutcomeKind.failed,
          '"${server.name}" not active: $ownerReason',
        );
      }
      final unsupported = unsupportedTransportReason(server);
      if (unsupported != null) {
        return McpConnectOutcome(
          McpConnectOutcomeKind.unsupported,
          unsupported,
        );
      }
      final missing = await missingCredentialsFor(server);
      _requireCurrent(rs);
      if (missing.isNotEmpty) {
        final reason =
            (server.transport == 'native' &&
                (server.name.toLowerCase() == 'github' ||
                    server.canonicalId.toLowerCase() == 'github'))
            ? 'Please log in to GitHub or set GITHUB_TOKEN'
            : '"${server.name}" degraded: needs configuration (${missing.join(', ')})';
        return McpConnectOutcome(McpConnectOutcomeKind.needsSetup, reason);
      }
      if (server.ownerPluginId != null) {
        server.headers = await AppState.I.getMcpHeaders(server.canonicalId);
        _requireCurrent(rs);
      }
      // Probe only; this wait is covered by the same overall budget.
      final needRuntime = await missingRuntimeFor(server);
      _requireCurrent(rs);
      if (needRuntime != null) {
        return McpConnectOutcome(
          McpConnectOutcomeKind.needsRuntime,
          '"${server.name}" needs runtime ($needRuntime) — install runtimes, then reconnect',
        );
      }
      // Preflight may consume the whole budget; never create a transport
      // after the deadline or after this reservation has been cancelled.
      await beforeReserveHookForTest?.call();
      _requireCurrent(rs);
      if (!_now().isBefore(deadline)) {
        return const McpConnectOutcome(
          McpConnectOutcomeKind.failed,
          'MCP handshake timed out',
        );
      }
      final message = server.transport == 'http'
          ? await _connectHttp(server, rs, deadline: deadline)
          : server.transport == 'sse'
          ? await _connectSse(server, rs, deadline: deadline)
          : server.transport == 'native'
          ? await _connectNative(server, rs, deadline: deadline)
          : await _connectStdio(server, rs, deadline: deadline);
      if (identical(_running[key], rs) && rs.handshakeDone) {
        return McpConnectOutcome(McpConnectOutcomeKind.ready, message);
      }
      return McpConnectOutcome(
        rs.authenticationFailed
            ? McpConnectOutcomeKind.needsSetup
            : McpConnectOutcomeKind.failed,
        message,
      );
    }

    Future<McpConnectOutcome> attempt() async {
      try {
        return await runAttempt();
      } catch (error) {
        return McpConnectOutcome(McpConnectOutcomeKind.failed, '$error');
      }
    }

    unawaited(
      attempt().then((outcome) {
        if (!outcome.isReady) _abortStartupAttempt(server, rs);
        if (!rs.connection.isCompleted) rs.connection.complete(outcome);
      }),
    );
    return rs.connection.future.timeout(
      handshakeBudget,
      onTimeout: () {
        _abortStartupAttempt(server, rs);
        const outcome = McpConnectOutcome(
          McpConnectOutcomeKind.failed,
          'MCP handshake timed out',
        );
        if (!rs.connection.isCompleted) rs.connection.complete(outcome);
        return outcome;
      },
    );
  }

  void _requireCurrent(_RunningServer rs) {
    if (rs.userDisconnected || !identical(_running[_key(rs.server)], rs)) {
      throw StateError('connect aborted');
    }
  }

  /// Abort a budgeted startup attempt without ever marking it ready.
  void _abortStartupAttempt(McpServer server, _RunningServer rs) {
    final key = _key(server);
    if (identical(_running[key], rs)) _running.remove(key);
    // Set BEFORE kill so the stdio death watcher never schedules a reconnect.
    rs.userDisconnected = true;
    unawaited(rs.sseChannel?.close());
    rs.sseChannel = null;
    for (final client in rs.httpClients) {
      client.close();
    }
    rs.httpClients.clear();
    try {
      rs.nativeHandler?.dispose();
    } catch (e) {
      Diag.swallow('mcp_service', e);
    }
    try {
      rs.process?.kill();
    } catch (e) {
      Diag.swallow('mcp_service', e);
    }
  }

  static Duration _remainingUntil(DateTime deadline) {
    final left = deadline.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Why the owning plugin stops [server] from connecting, or null when it
  /// does not.
  ///
  /// Replaces a bare "Owning plugin is not active", which left a disconnected
  /// row with nothing actionable — and this is the message a user actually
  /// sees after the plugin-grant cascade disables an owner. Each state needs
  /// a different action: `pendingGlobal` is spec §7's "enabled, activates on
  /// restart" (the Plugins badge reads "Restart to enable everywhere"),
  /// `disabled` usually means re-approval, `failed` means look at the plugin
  /// row, and null-activation means it is not registered at all.
  static String? _ownerInactiveReason(McpServer server) {
    final owner = server.ownerPluginId;
    if (owner == null) return null;
    switch (PluginContributionRegistry.I.activationFor(owner)) {
      case PluginActivation.sessionActive:
      case PluginActivation.globalActive:
      case PluginActivation.degraded:
        return null;
      case PluginActivation.pendingGlobal:
        return 'owning plugin "$owner" is enabled but activates on restart — '
            'restart the app to connect';
      case PluginActivation.disabled:
        return 'owning plugin "$owner" is disabled';
      case PluginActivation.failed:
        return 'owning plugin "$owner" failed to activate';
      case null:
        return 'owning plugin "$owner" is not registered';
    }
  }

  static bool _ownerActive(McpServer server) =>
      _ownerInactiveReason(server) == null;

  /// Side-effect-free credential probe used by health checks: returns the
  /// declared env/header names that have no stored value. Never dials or
  /// spawns a process.
  Future<List<String>> missingCredentialsFor(McpServer server) =>
      _missingCredentials(server);

  /// Test seam: overrides the runtime probe in connect paths so tests
  /// never touch the real sandbox. Null in production.
  @visibleForTesting
  static Future<String?> Function(McpServer server)?
  missingRuntimeOverrideForTest;

  /// Language runtime (`node`/`python`) a stdio command needs, or null
  /// when the command needs none. Used by [_connectStdio] itself (single
  /// source of truth — the inline duplicate was removed) and by
  /// [missingRuntimeFor]'s eager gate.
  static String? runtimeKindForCommand(String command) {
    if (command == 'npx' || command == 'node') return 'node';
    if (command == 'uvx' ||
        command == 'uv' ||
        command == 'python' ||
        command == 'python3') {
      return 'python';
    }
    // WS2: git-backed MCP servers need the git binary — without this
    // case a missing git failed opaquely at spawn; now
    // [missingRuntimeFor] reports "needs runtime (git)" up front.
    if (command == 'git') return 'git';
    return null;
  }

  /// Runtime label a stdio server needs that is NOT installed right now,
  /// or null when nothing is missing. Fast probe — never installs. Lets
  /// callers ask for runtimes BEFORE burning the handshake budget (an
  /// apt install takes minutes; the 30s budget guaranteed a first-enable
  /// timeout). Returns null when the sandbox itself is missing — the
  /// stdio path's own sandbox error covers that case.
  Future<String?> missingRuntimeFor(
    McpServer server, {
    Future<bool> Function(String bin)? hasRuntime,
    bool? sandboxInstalled,
  }) async {
    final override = missingRuntimeOverrideForTest;
    if (override != null) return override(server);
    if (server.transport != 'stdio') return null;
    final kind = runtimeKindForCommand(server.command);
    if (kind == null) return null;
    if (!(sandboxInstalled ?? SandboxService.I.isInstalled)) return null;
    try {
      final probe = hasRuntime ?? SandboxService.I.hasRuntime;
      if (await probe(server.command)) return null;
    } catch (_) {
      return kind;
    }
    return kind;
  }

  /// Structural transport gate used by health checks: null when the transport
  /// can run on this device, otherwise the actionable unsupported reason.
  String? unsupportedTransportReason(McpServer server) {
    // 'sse' (legacy GET /sse + POST /message) is supported via
    // [_connectSse] — Streamable HTTP ('http') remains the recommended
    // transport for new servers.
    if (server.transport != 'http' &&
        server.transport != 'stdio' &&
        server.transport != 'sse' &&
        server.transport != 'native') {
      return 'Unsupported transport "${server.transport}"';
    }
    // A stdio row that can never run. Custom rows that declare no transport
    // fall back to 'stdio' (see the Plugins add/import sheet), so a
    // half-entered server — or one imported with its args dropped — persists
    // as `stdio · npx` with NO package. That row then spawned a bare `npx`,
    // which printed its usage and exited, and surfaced as an opaque handshake
    // failure on an entry that looked merely "disconnected". Reject it here,
    // where the reason actually reaches the UI, instead of burning the
    // handshake budget spawning a process that cannot work.
    if (server.transport == 'stdio') {
      final command = server.command.trim();
      if (command.isEmpty) {
        return 'stdio server has no command — set one or remove this entry';
      }
      // Basename, so an absolute path like /usr/local/bin/npx still matches.
      final launcher = command.split(RegExp(r'[\\/\s]+')).last.toLowerCase();
      final hasPackageArg = server.args.any(
        (a) => a.trim().isNotEmpty && !a.trim().startsWith('-'),
      );
      if (_kPackageLauncherCommands.contains(launcher) && !hasPackageArg) {
        return '"$command" needs a package argument '
            '(e.g. -y @scope/mcp-server) — this entry has none';
      }
    }
    return null;
  }

  // ── OAuth for hosted MCP servers (item 6) ──────────────────────────
  //
  // Browser-based OAuth flow API. Call beginMcpOAuthAuthorization, open its
  // authorizationUrl, then pass the FULL redirect URI to
  // completeMcpOAuthAuthorization. The service verifies state/redirect/PKCE
  // and owns persistence. The token is then attached as
  // `Authorization: Bearer …` to every HTTP/SSE request for that server,
  // and refreshed automatically on 401 when a refresh token exists.
  //
  // [McpServer] (state.dart) carries no oauth field, so the per-server
  // config rides in this sidecar, keyed by canonical id and persisted in
  // secure storage. The import path (`ImportedMcp.oauth`) should call
  // [setMcpOAuthConfig] when it materializes the McpServer row.

  static String _oauthTokenKey(String serverKey) => 'ovid_mcp_oauth_$serverKey';
  static String _oauthConfigKey(String serverKey) =>
      'ovid_mcp_oauth_cfg_$serverKey';

  final Map<String, McpOAuthConfig> _oauthConfigs = {};
  final Map<String, McpOAuthToken> _oauthTokens = {};
  final _oauthGenerations = <String, Object>{};
  final _oauthConfigGenerations = <String, Object>{};
  final _oauthStorageOperations = <String, Future<void>>{};
  final _oauthRefreshes = <String, Future<McpOAuthToken?>>{};
  final _oauthAttempts = <String, McpOAuthAuthorization>{};

  Object _oauthGeneration(String key) =>
      _oauthGenerations.putIfAbsent(key, Object.new);

  Object _invalidateOAuth(String key) {
    _oauthRefreshes.remove(key);
    _oauthAttempts.remove(key);
    return _oauthGenerations[key] = Object();
  }

  bool _ownsOAuth(String key, Object generation) =>
      identical(_oauthGenerations[key], generation);

  // Config persistence is fenced separately from token/attempt state: only a
  // newer config registration or a full removal may drop a queued config
  // write. Starting or cancelling an authorization attempt never does.
  Object _configGeneration(String key) =>
      _oauthConfigGenerations.putIfAbsent(key, Object.new);

  Object _invalidateOAuthConfig(String key) =>
      _oauthConfigGenerations[key] = Object();

  bool _ownsOAuthConfig(String key, Object generation) =>
      identical(_oauthConfigGenerations[key], generation);

  // Serialize reads/writes/deletes as well as fencing publication. A delete
  // must finish AFTER a platform write already in flight, before any new write.
  Future<void> _oauthStorage(String key, Future<void> Function() operation) {
    final previous = _oauthStorageOperations[key] ?? Future<void>.value();
    final next = previous.then((_) => operation());
    final settled = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _oauthStorageOperations[key] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_oauthStorageOperations[key], settled)) {
          _oauthStorageOperations.remove(key);
        }
      }),
    );
    return next;
  }

  /// Test seam: OAuth tokens never touch the real secure storage.
  @visibleForTesting
  static bool oauthSecureStorageDisabledForTest = false;

  /// Record the OAuth config for [serverKey] (a server canonical id).
  /// Persists to secure storage (client_id is not a secret; no token
  /// material is stored here).
  Future<void> setMcpOAuthConfig(
    String serverKey,
    McpOAuthConfig config,
  ) async {
    _invalidateOAuth(serverKey);
    final generation = _invalidateOAuthConfig(serverKey);
    _oauthConfigs[serverKey] = config;
    if (oauthSecureStorageDisabledForTest) return;
    await _oauthStorage(serverKey, () async {
      if (!_ownsOAuthConfig(serverKey, generation)) return;
      await ovidSecureStorage().write(
        key: _oauthConfigKey(serverKey),
        value: jsonEncode(config.toJson()),
      );
    });
  }

  /// In-memory OAuth config, or null when none was registered.
  McpOAuthConfig? mcpOAuthConfigFor(String serverKey) =>
      _oauthConfigs[serverKey];

  /// OAuth config, falling back to secure storage (survives restarts).
  Future<McpOAuthConfig?> mcpOAuthConfigForAsync(String serverKey) async {
    final generation = _configGeneration(serverKey);
    final mem = _oauthConfigs[serverKey];
    if (mem != null) return mem;
    if (oauthSecureStorageDisabledForTest) return null;
    try {
      await _oauthStorageOperations[serverKey];
      final raw = await ovidSecureStorage().read(
        key: _oauthConfigKey(serverKey),
      );
      if (raw == null || raw.isEmpty) return null;
      final cfg = McpOAuthConfig.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
      if (!_ownsOAuthConfig(serverKey, generation)) return null;
      _oauthConfigs[serverKey] = cfg;
      return cfg;
    } catch (_) {
      return null;
    }
  }

  /// Persist an OAuth token for [serverKey] (secure storage, never prefs).
  Future<void> storeMcpOAuthToken(String serverKey, McpOAuthToken token) async {
    final generation = _invalidateOAuth(serverKey);
    await _storeOAuthToken(serverKey, token, generation);
  }

  Future<bool> _storeOAuthToken(
    String serverKey,
    McpOAuthToken token,
    Object generation,
  ) async {
    if (!_ownsOAuth(serverKey, generation)) return false;
    if (!oauthSecureStorageDisabledForTest) {
      await _oauthStorage(serverKey, () async {
        if (!_ownsOAuth(serverKey, generation)) return;
        await ovidSecureStorage().write(
          key: _oauthTokenKey(serverKey),
          value: jsonEncode(token.toJson()),
        );
      });
    }
    if (!_ownsOAuth(serverKey, generation)) return false;
    _oauthTokens[serverKey] = token;
    return true;
  }

  /// Disconnect and forget all OAuth material. Call with the canonical id
  /// before deleting/replacing a server or removing its owning account/plugin.
  Future<void> removeMcpOAuth(String serverKey) async {
    // First invalidate synchronously. Even a storage operation that starts
    // while disconnect's best-effort session DELETE awaits cannot resurrect
    // the removed identity.
    _invalidateOAuth(serverKey);
    _invalidateOAuthConfig(serverKey);
    _oauthTokens.remove(serverKey);
    _oauthConfigs.remove(serverKey);
    final disconnecting = disconnect(serverKey);
    final deleting = oauthSecureStorageDisabledForTest
        ? Future<void>.value()
        : _oauthStorage(serverKey, () async {
            await ovidSecureStorage().delete(key: _oauthTokenKey(serverKey));
            await ovidSecureStorage().delete(key: _oauthConfigKey(serverKey));
          });
    await Future.wait([disconnecting, deleting]);
  }

  /// The stored OAuth token for [serverKey], or null when none / unreadable.
  Future<McpOAuthToken?> mcpOAuthTokenFor(String serverKey) async {
    final generation = _oauthGeneration(serverKey);
    final mem = _oauthTokens[serverKey];
    if (mem != null) return mem;
    if (oauthSecureStorageDisabledForTest) return null;
    try {
      await _oauthStorageOperations[serverKey];
      final raw = await ovidSecureStorage().read(
        key: _oauthTokenKey(serverKey),
      );
      if (raw == null || raw.isEmpty) return null;
      final token = McpOAuthToken.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
      if (!_ownsOAuth(serverKey, generation)) return null;
      _oauthTokens[serverKey] = token;
      return token;
    } catch (_) {
      return null;
    }
  }

  /// Drop the stored OAuth token for [serverKey] (disconnect/revoke path).
  Future<void> clearMcpOAuthToken(String serverKey) async {
    _invalidateOAuth(serverKey);
    _oauthTokens.remove(serverKey);
    if (oauthSecureStorageDisabledForTest) return;
    await _oauthStorage(serverKey, () async {
      await ovidSecureStorage().delete(key: _oauthTokenKey(serverKey));
    });
  }

  /// Begin a ten-minute, one-use S256 authorization attempt for a canonical id.
  /// Starting again invalidates the previous attempt and pending refresh writes.
  Future<McpOAuthAuthorization> beginMcpOAuthAuthorization(
    String serverKey,
  ) async {
    final generation = _invalidateOAuth(serverKey);
    final config = await mcpOAuthConfigForAsync(serverKey);
    if (!_ownsOAuth(serverKey, generation) || config == null) {
      throw StateError('OAuth configuration unavailable or replaced');
    }
    _oauthEndpoint(config.authorizationUrl);
    _oauthEndpoint(config.tokenUrl);
    final redirect = Uri.tryParse(config.redirectUri ?? '');
    if (redirect == null ||
        !redirect.hasScheme ||
        redirect.hasFragment ||
        redirect.userInfo.isNotEmpty ||
        (redirect.scheme != 'https' &&
            redirect.scheme != 'http' &&
            !redirect.hasAuthority) ||
        redirect.queryParametersAll.values.any((v) => v.length != 1) ||
        redirect.queryParameters.keys.any(
          const {'code', 'state', 'error'}.contains,
        )) {
      throw StateError('OAuth redirect URI is invalid');
    }
    final random = Random.secure();
    String nonce() => base64Url
        .encode(List.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final state = nonce();
    final verifier = nonce();
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final attempt = McpOAuthAuthorization._(
      buildMcpAuthorizeUrl(
        config: config,
        state: state,
        codeChallenge: challenge,
      ),
      _now().add(const Duration(minutes: 10)),
      config,
      state,
      verifier,
      generation,
    );
    _oauthAttempts[serverKey] = attempt;
    return attempt;
  }

  /// Validate the entire callback before exchanging, then store only if the
  /// server/config generation is still current. Invalid callbacks consume the
  /// attempt too. No callback secrets are included in exception messages.
  Future<McpOAuthToken> completeMcpOAuthAuthorization(
    String serverKey,
    String callbackUri,
  ) async {
    final attempt = _oauthAttempts.remove(serverKey);
    if (attempt == null ||
        !_ownsOAuth(serverKey, attempt._generation) ||
        !_now().isBefore(attempt.expiresAt)) {
      throw StateError('OAuth attempt expired or unavailable');
    }
    final callback = Uri.tryParse(callbackUri);
    final expected = Uri.parse(attempt._config.redirectUri!);
    if (callback == null ||
        callback.hasFragment ||
        callback.userInfo.isNotEmpty ||
        callback.scheme != expected.scheme ||
        callback.host != expected.host ||
        callback.port != expected.port ||
        callback.path != expected.path ||
        callback.queryParametersAll.values.any((v) => v.length != 1) ||
        !callback.queryParameters.keys.every(
          (key) =>
              expected.queryParameters.containsKey(key) ||
              const {'code', 'state'}.contains(key),
        ) ||
        expected.queryParameters.entries.any(
          (e) => callback.queryParameters[e.key] != e.value,
        ) ||
        callback.queryParameters['state'] != attempt._state ||
        callback.queryParameters.containsKey('error') ||
        (callback.queryParameters['code'] ?? '').isEmpty) {
      throw StateError('OAuth callback rejected');
    }
    final token = await exchangeMcpOAuthCode(
      config: attempt._config,
      code: callback.queryParameters['code']!,
      codeVerifier: attempt._verifier,
    );
    if (!await _storeOAuthToken(serverKey, token, attempt._generation)) {
      throw StateError('OAuth attempt replaced or removed');
    }
    return token;
  }

  void cancelMcpOAuthAuthorization(String serverKey) =>
      _invalidateOAuth(serverKey);

  static Uri _oauthEndpoint(String? value) {
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
      throw StateError('OAuth endpoint requires HTTPS (or loopback HTTP)');
    }
    return uri;
  }

  Future<http.Response> _postOAuth(
    http.Client client,
    String url,
    Map<String, String> fields,
  ) async {
    final request = http.Request('POST', _oauthEndpoint(url))
      ..followRedirects = false
      ..bodyFields = fields;
    final streamed = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (const {301, 302, 303, 307, 308}.contains(streamed.statusCode)) {
      unawaited(streamed.stream.listen(null).cancel());
      throw StateError('OAuth token endpoint redirected');
    }
    return await http.Response.fromStream(
      streamed,
    ).timeout(const Duration(seconds: 30));
  }

  /// Build the browser authorize URL for the OAuth flow (step 1 of the
  /// flow; the UI opens this URL and captures the redirect). [state]
  /// should be an unguessable per-attempt value the UI verifies on
  /// return. Pass [codeChallenge] for PKCE (S256).
  static String buildMcpAuthorizeUrl({
    required McpOAuthConfig config,
    required String state,
    String? codeChallenge,
  }) {
    final authUrl = config.authorizationUrl;
    if (authUrl == null || authUrl.trim().isEmpty) {
      throw ArgumentError('OAuth config has no authorization_url');
    }
    if ((config.clientId ?? '').isEmpty) {
      throw ArgumentError('OAuth config has no client_id');
    }
    final uri = Uri.parse(authUrl.trim());
    return uri
        .replace(
          queryParameters: {
            ...uri.queryParameters,
            'response_type': 'code',
            'client_id': config.clientId!,
            if ((config.redirectUri ?? '').isNotEmpty)
              'redirect_uri': config.redirectUri!,
            if (config.scopes.isNotEmpty) 'scope': config.scopes.join(' '),
            'state': state,
            if (codeChallenge != null && codeChallenge.isNotEmpty) ...{
              'code_challenge': codeChallenge,
              'code_challenge_method': 'S256',
            },
          },
        )
        .toString();
  }

  /// Exchange an authorization `code` for tokens (step 3 of the flow, after
  /// the browser redirects back). Returns the token — the caller persists
  /// it with [storeMcpOAuthToken].
  Future<McpOAuthToken> exchangeMcpOAuthCode({
    required McpOAuthConfig config,
    required String code,
    String? codeVerifier,
  }) async {
    final tokenUrl = config.tokenUrl;
    if (tokenUrl == null || tokenUrl.trim().isEmpty) {
      throw ArgumentError('OAuth config has no token_url');
    }
    final client = httpClientForTest ?? http.Client();
    try {
      final res = await _postOAuth(client, tokenUrl.trim(), {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': config.redirectUri ?? '',
        'client_id': config.clientId ?? '',
        if (codeVerifier != null && codeVerifier.isNotEmpty)
          'code_verifier': codeVerifier,
      });
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('OAuth token exchange failed: HTTP ${res.statusCode}');
      }
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if ((j['access_token']?.toString() ?? '').isEmpty) {
        throw Exception('OAuth token exchange returned no access_token');
      }
      return McpOAuthToken.fromTokenResponse(j);
    } finally {
      if (httpClientForTest == null) client.close();
    }
  }

  /// Refresh the stored token for [serverKey] via its refresh token.
  /// Returns the new token (already stored), or null when refresh is not
  /// possible/failed.
  Future<McpOAuthToken?> refreshMcpOAuthToken(String serverKey) {
    final existing = _oauthRefreshes[serverKey];
    if (existing != null) return existing;
    final generation = _oauthGeneration(serverKey);
    final future = _refreshMcpOAuthToken(serverKey, generation);
    _oauthRefreshes[serverKey] = future;
    unawaited(
      future.then((_) {
        if (identical(_oauthRefreshes[serverKey], future)) {
          _oauthRefreshes.remove(serverKey);
        }
      }),
    );
    return future;
  }

  Future<McpOAuthToken?> _refreshMcpOAuthToken(
    String serverKey,
    Object generation,
  ) async {
    final config = await mcpOAuthConfigForAsync(serverKey);
    final current = await mcpOAuthTokenFor(serverKey);
    final tokenUrl = config?.tokenUrl;
    if (!_ownsOAuth(serverKey, generation) ||
        tokenUrl == null ||
        tokenUrl.trim().isEmpty ||
        current == null ||
        !current.canRefresh) {
      return null;
    }
    final client = httpClientForTest ?? http.Client();
    try {
      final res = await _postOAuth(client, tokenUrl.trim(), {
        'grant_type': 'refresh_token',
        'refresh_token': current.refreshToken!,
        'client_id': config!.clientId ?? '',
      });
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if ((j['access_token']?.toString() ?? '').isEmpty) return null;
      final next = McpOAuthToken.fromTokenResponse(j);
      // A refresh response may omit the refresh token — keep the old one.
      final merged = next.refreshToken == null || next.refreshToken!.isEmpty
          ? McpOAuthToken(
              accessToken: next.accessToken,
              refreshToken: current.refreshToken,
              tokenType: next.tokenType,
              expiresAt: next.expiresAt,
            )
          : next;
      return await _storeOAuthToken(serverKey, merged, generation)
          ? merged
          : null;
    } catch (_) {
      return null;
    } finally {
      if (httpClientForTest == null) client.close();
    }
  }

  /// `Authorization` header for [rs]'s server from the stored OAuth token.
  /// Expired tokens refresh before use; teardown never starts a refresh.
  Future<Map<String, String>> _authHeaders(_RunningServer rs) async {
    if (rs.userDisconnected) return const {};
    var token = await mcpOAuthTokenFor(_key(rs.server));
    if (rs.userDisconnected) return const {};
    if (token != null && token.isExpired && !rs.userDisconnected) {
      _requireCurrent(rs);
      token = await refreshMcpOAuthToken(_key(rs.server));
      _requireCurrent(rs);
    }
    if (token == null || token.accessToken.isEmpty || token.isExpired) {
      return const {};
    }
    return {'Authorization': '${token.tokenType} ${token.accessToken}'};
  }

  /// Attempt one silent refresh for [rs]'s server. True when a fresh token
  /// is now stored.
  Future<bool> _tryRefreshOAuth(_RunningServer rs) async {
    _requireCurrent(rs);
    final token = await refreshMcpOAuthToken(_key(rs.server));
    _requireCurrent(rs);
    return token != null;
  }

  // ── Legacy SSE transport (item 6) ──────────────────────────────────
  //
  // GET <url> (text/event-stream) → first `event: endpoint` gives the POST
  // URL → POST each JSON-RPC message there → responses arrive as SSE
  // `data:` events correlated by `id`. Streamable HTTP ('http') stays the
  // recommended transport; 'sse' exists for servers that only speak the
  // legacy protocol.

  /// Connect a legacy-SSE server: open the event stream, resolve the POST
  /// endpoint, then run the standard MCP handshake over it.
  Future<String> _connectSse(
    McpServer server,
    _RunningServer rs, {
    DateTime? deadline,
  }) async {
    final key = _key(server);
    Duration timeoutFor() => deadline == null
        ? Duration(seconds: server.startupTimeoutS)
        : _remainingUntil(deadline);
    Duration phaseTimeout(String phase) {
      final timeout = timeoutFor();
      _recordConnectPhase(phase, timeout);
      return timeout;
    }

    Future<void> openChannel(Map<String, String> headers) async {
      _requireCurrent(rs);
      late final _SseMcpChannel channel;
      channel = _SseMcpChannel(
        client: httpClientForTest,
        onNotification: (message) => _onNotification(rs, message),
        onClosed: () => _markSseFailure(rs),
        onDestinationRejected: (reason) {
          if (!identical(rs.sseChannel, channel)) return;
          rs.sseDestinationFailure = reason;
          rs.handshakeDone = false;
          if (!identical(_running[key], rs)) return;
          _running.remove(key);
          _sseDestinationFailures[key] = reason;
          // Policy refusal is terminal for this attempt, not a transient
          // network failure that should automatically reconnect.
          _cancelReconnect(key);
        },
      );
      rs.sseChannel = channel;
      try {
        await channel.open(
          server.url!,
          headers,
          timeout: phaseTimeout('sse/open'),
        );
      } catch (_) {
        await channel.close();
        if (identical(rs.sseChannel, channel)) rs.sseChannel = null;
        rethrow;
      }
    }

    try {
      if (deadline != null && !_now().isBefore(deadline)) {
        throw TimeoutException('MCP handshake timed out', Duration.zero);
      }
      final url = server.url;
      if (url == null || url.isEmpty) {
        throw Exception('no url configured for SSE transport');
      }
      var headers = {...server.headers, ...await _authHeaders(rs)};
      try {
        await openChannel(headers);
      } catch (e) {
        // One silent OAuth refresh on auth failure, then give up (never
        // loop — the HTTP transport treats 401 the same way).
        final msg = e.toString();
        if ((msg.contains('401') || msg.contains('403')) &&
            await _tryRefreshOAuth(rs)) {
          headers = {...server.headers, ...await _authHeaders(rs)};
          await openChannel(headers);
        } else {
          rethrow;
        }
      }
      final initResult = await _rpcSse(rs, 'initialize', {
        'protocolVersion': '2024-11-05',
        'capabilities': {},
        'clientInfo': {'name': 'ovid-ai', 'version': '1.0.0'},
      }, timeout: phaseTimeout('initialize'));
      if (initResult.isTimeout) {
        throw TimeoutException('initialize timed out', timeoutFor());
      }
      if (initResult.isError) {
        throw Exception('initialize failed: ${initResult.error}');
      }
      _rememberInitializeResult(rs, initResult.value);
      await _sendNotificationSse(
        rs,
        'notifications/initialized',
        {},
        timeout: phaseTimeout('notifications/initialized'),
      );
      rs.tools =
          await _listToolsSse(rs, timeout: phaseTimeout('tools/list')) ??
          <McpToolDef>[];
      if (rs.sseDestinationFailure != null) {
        throw StateError(rs.sseDestinationFailure!);
      }
      if (!identical(_running[key], rs) ||
          rs.userDisconnected ||
          !_canPublishStatus(rs)) {
        return 'connect aborted';
      }
      rs.handshakeDone = true;
      _markConnected(
        rs,
        '"${server.name}" connected (sse) · ${rs.tools.length} tools',
      );
      _reconnectAttempts.remove(key);
      return '"${server.name}" connected (sse) · ${rs.tools.length} tools';
    } catch (e) {
      if (identical(_running[key], rs)) _running.remove(key);
      final channel = rs.sseChannel;
      if (e.toString().contains('SSE stream failed: HTTP 401') ||
          e.toString().contains('SSE stream failed: HTTP 403')) {
        rs.authenticationFailed = true;
      }
      rs.sseChannel = null;
      try {
        await channel?.close();
      } catch (e) {
        Diag.swallow('mcp_service', e);
      }
      _markDisconnected(rs, 'connect failed: $e');
      return 'connect failed: $e';
    }
  }

  /// JSON-RPC over the SSE channel: POST the message, await the SSE event
  /// with the matching `id`. Same [McpRpcResult] contract as [_rpcHttp].
  Future<McpRpcResult> _rpcSse(
    _RunningServer rs,
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) async {
    final channel = rs.sseChannel;
    if (rs.sseDestinationFailure != null) {
      return McpRpcResult._error(rs.sseDestinationFailure!);
    }
    if (channel == null || !channel.isOpen) {
      return McpRpcResult._error('SSE channel is not open');
    }
    final id = _nextId++;
    final effectiveTimeout = timeout ?? Duration(seconds: _rpcTimeoutSeconds);

    Future<void> doPost(Map<String, String> headers) => channel.post(
      {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params},
      headers,
      timeout: effectiveTimeout,
    );

    try {
      try {
        await doPost({...rs.server.headers, ...await _authHeaders(rs)});
      } catch (e) {
        // One silent OAuth refresh on auth failure, then accept the
        // outcome — mirrors the Streamable-HTTP transport.
        if (e.toString().contains('authentication failed') &&
            await _tryRefreshOAuth(rs)) {
          await doPost({...rs.server.headers, ...await _authHeaders(rs)});
        } else {
          rethrow;
        }
      }
    } catch (e) {
      if (rs.sseDestinationFailure != null) {
        return McpRpcResult._error(rs.sseDestinationFailure!);
      }
      final msg = e.toString();
      if (msg.contains('authentication failed')) {
        rs.authenticationFailed = true;
        return McpRpcResult._error(msg);
      }
      _markSseFailure(rs);
      return McpRpcResult._error('$e');
    }
    final Map<String, dynamic>? j;
    try {
      j = await channel.nextResponse(id, timeout: effectiveTimeout);
    } on StateError {
      if (rs.sseDestinationFailure != null) {
        return McpRpcResult._error(rs.sseDestinationFailure!);
      }
      rethrow;
    }
    if (rs.sseDestinationFailure != null) {
      return McpRpcResult._error(rs.sseDestinationFailure!);
    }
    if (j == null) {
      if (!channel.isOpen) {
        // The stream died mid-call — same treatment as a dead stdio pipe.
        _markSseFailure(rs);
        return McpRpcResult._error('SSE stream closed before response');
      }
      return const McpRpcResult._timeout();
    }
    if (j.containsKey('error')) {
      final err = j['error'];
      return McpRpcResult._error(
        err is Map ? '${err['message'] ?? err['code'] ?? 'error'}' : '$err',
      );
    }
    return McpRpcResult._ok(j['result']);
  }

  /// Fire-and-forget JSON-RPC notification over SSE.
  Future<void> _sendNotificationSse(
    _RunningServer rs,
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) async {
    final channel = rs.sseChannel;
    if (channel == null || !channel.isOpen) return;
    try {
      final headers = {...rs.server.headers, ...await _authHeaders(rs)};
      await channel.post(
        {'jsonrpc': '2.0', 'method': method, 'params': params},
        headers,
        timeout: timeout ?? Duration(seconds: _rpcTimeoutSeconds),
      );
    } catch (_) {
      // Notifications are fire-and-forget by design.
    }
  }

  /// `tools/list` over SSE, following `nextCursor` exactly like the HTTP
  /// and stdio variants. Malformed/incomplete catalogs fail discovery.
  Future<List<McpToolDef>?> _listToolsSse(
    _RunningServer rs, {
    Duration? timeout,
  }) => _listToolsPages(
    rs,
    (params, left) => _rpcSse(rs, 'tools/list', params, timeout: left),
    timeout: timeout,
  );

  /// An SSE server whose stream dies unexpectedly gets the same treatment
  /// as a dead stdio process / failed HTTP call: drop it and schedule an
  /// automatic reconnect (unless the user disconnected it).
  void _markSseFailure(_RunningServer rs) {
    if (!rs.handshakeDone) return;
    final key = _key(rs.server);
    if (!identical(_running[key], rs)) return; // already superseded
    _running.remove(key);
    _markDisconnected(rs, 'SSE stream disconnected unexpectedly');
    _lastDeath = (server: key, code: -1, at: DateTime.now());
    final channel = rs.sseChannel;
    rs.sseChannel = null;
    unawaited(channel?.close());
    if (!rs.userDisconnected && _canPublishStatus(rs)) {
      _scheduleReconnect(rs.server);
    }
  }

  Future<List<String>> _missingCredentials(McpServer server) async {
    // For native GitHub MCP, credentials can be fulfilled by GitHubService.I.token.
    if (server.transport == 'native' &&
        (server.name.toLowerCase() == 'github' ||
            server.canonicalId.toLowerCase() == 'github')) {
      final token = GitHubService.I.token;
      if (token != null && token.trim().isNotEmpty) {
        return const [];
      }
    }
    // Task 10 fix round 1 (finding 2): the credential gate covers BOTH
    // plugin-owned servers (requiredEnvNames/requiredHeaderNames from the
    // normalized manifest) AND ownerless servers that declare credentials
    // — bundled seeds via envHint (comma-separated env var names, e.g.
    // 'GITHUB_TOKEN' or 'SUPABASE_URL,SUPABASE_KEY'), plus any ownerless
    // row carrying requiredEnvNames. A declared credential that is absent
    // from secure storage means the server must NOT spawn (spec §10:
    // credential-dependent MCPs never auto-spawn until configured).
    // Ownerless servers with no declarations connect as before.
    final declaredEnv = <String>[
      ...server.requiredEnvNames,
      if (server.ownerPluginId == null) ...?_envHintNames(server),
    ];
    // envHint is env-only; headers come through requiredHeaderNames
    // exclusively (ownerless HTTP auth headers are set at add time).
    final declaredHeaders = server.requiredHeaderNames;
    if (declaredEnv.isEmpty && declaredHeaders.isEmpty) return const [];
    final env = await AppState.I.getMcpEnv(server.canonicalId);
    final headers = await AppState.I.getMcpHeaders(server.canonicalId);
    return [
      for (final name in declaredEnv)
        if ((env[name] ?? '').isEmpty) name,
      for (final name in declaredHeaders)
        if ((headers[name] ?? '').isEmpty) name,
    ];
  }

  /// envHint is a display hint that doubles as a credential declaration
  /// for bundled seeds: raw env var names, comma-separated. Empty/blank
  /// entries are ignored; a JSON-object hint (headers form) declares
  /// nothing here.
  static List<String>? _envHintNames(McpServer server) {
    final hint = server.envHint;
    if (hint == null ||
        hint.trim().isEmpty ||
        hint.trimLeft().startsWith('{')) {
      return null;
    }
    final names = hint
        .split(',')
        .map((n) => n.trim())
        .where((n) => n.isNotEmpty)
        .toList();
    return names.isEmpty ? null : names;
  }

  /// Per-server memory store path. The server id is sanitized with the same
  /// stable encoder used for provider tool names, so ownerless and
  /// plugin-owned servers never share a knowledge graph.
  static String _memoryStoragePath(String docsPath, McpServer server) =>
      '$docsPath/mcp-memory/${_providerEncode(server.canonicalId)}.json';

  /// Resolves the per-server memory store, seeding it once from the legacy
  /// shared `mcp_memory.json` so existing graphs survive the split. The
  /// legacy file is copied, never moved.
  static Future<File> _resolveMemoryStorageFile(
    String docsPath,
    McpServer server,
  ) async {
    final file = File(_memoryStoragePath(docsPath, server));
    final legacy = File('$docsPath/mcp_memory.json');
    if (!await file.exists() && await legacy.exists()) {
      try {
        await file.parent.create(recursive: true);
        await legacy.copy(file.path);
      } catch (e) {
        Diag.swallow('mcp_service', e);
      }
    }
    return file;
  }

  Future<NativeMcpHandler> _createNativeHandler(McpServer server) async {
    final customFactory =
        _nativeHandlerFactories[server.canonicalId.toLowerCase()] ??
        _nativeHandlerFactories[server.name.toLowerCase()];
    if (customFactory != null) {
      return customFactory(server);
    }

    final id = server.canonicalId.toLowerCase();
    final name = server.name.toLowerCase();

    if (id == 'github' || name == 'github') {
      final env = await AppState.I.getMcpEnv(server.canonicalId);
      final token = env['GITHUB_TOKEN'];
      return NativeGitHubMcpHandler(
        token: token,
        tokenProvider: () => GitHubService.I.token,
        httpClient: httpClientForTest,
      );
    }

    if (id == 'filesystem' || name == 'filesystem') {
      final root = server.cwd != null && server.cwd!.isNotEmpty
          ? server.cwd!
          : Directory.current.path;
      return NativeFilesystemMcpHandler(rootPath: root);
    }

    if (id == 'fetch' || name == 'fetch') {
      return NativeFetchMcpHandler(httpClient: httpClientForTest);
    }

    if (id == 'memory' || name == 'memory') {
      File? storageFile;
      if (memoryStoragePathOverrideForTest != null) {
        storageFile = File(memoryStoragePathOverrideForTest!);
      } else {
        try {
          final docs = await getApplicationDocumentsDirectory();
          storageFile = await _resolveMemoryStorageFile(docs.path, server);
        } catch (_) {
          storageFile = await _resolveMemoryStorageFile(
            Directory.systemTemp.path,
            server,
          );
        }
      }
      return NativeMemoryMcpHandler(storageFile: storageFile);
    }

    throw Exception('No native handler found for "${server.name}"');
  }

  Future<String> _connectNative(
    McpServer server,
    _RunningServer rs, {
    DateTime? deadline,
  }) async {
    final key = _key(server);
    Duration timeoutFor() => deadline == null
        ? Duration(seconds: server.startupTimeoutS)
        : _remainingUntil(deadline);
    Duration phaseTimeout(String phase) {
      final timeout = timeoutFor();
      _recordConnectPhase(phase, timeout);
      return timeout;
    }

    try {
      if (deadline != null && !_now().isBefore(deadline)) {
        throw TimeoutException('MCP handshake timed out', Duration.zero);
      }
      final handler = await _createNativeHandler(server);
      rs.nativeHandler = handler;
      _requireCurrent(rs);

      await handler
          .initialize({
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'clientInfo': {'name': 'ovid-ai', 'version': '1.0.0'},
          })
          .timeout(phaseTimeout('initialize'));

      final tools = await handler.listTools().timeout(
        phaseTimeout('tools/list'),
      );
      rs.tools = tools;

      if (!identical(_running[key], rs) ||
          rs.userDisconnected ||
          !_canPublishStatus(rs)) {
        await handler.dispose();
        return 'connect aborted';
      }
      rs.handshakeDone = true;
      _markConnected(
        rs,
        '"${server.name}" connected (native) · ${rs.tools.length} tools',
      );
      _reconnectAttempts.remove(key);
      return '"${server.name}" connected (native) · ${rs.tools.length} tools';
    } catch (e) {
      if (identical(_running[key], rs)) _running.remove(key);
      try {
        await rs.nativeHandler?.dispose();
      } catch (e) {
        Diag.swallow('mcp_service', e);
      }
      _markDisconnected(rs, 'connect failed: $e');
      return 'connect failed: $e';
    }
  }

  /// Upper bound for a per-server tool timeout (the range
  /// `catalog_set_mcp_timeout` advertises).
  static const _maxToolTimeoutSeconds = 600;

  static Duration _effectiveToolTimeout(
    McpServer server,
    Duration? customTimeout,
  ) {
    if (customTimeout != null) return customTimeout;
    final override = rpcTimeoutSecondsForTest;
    if (override != null) return Duration(seconds: override);
    final seconds = server.toolTimeoutS
        .clamp(1, _maxToolTimeoutSeconds)
        .toInt();
    return Duration(seconds: seconds);
  }

  @visibleForTesting
  static Duration effectiveToolTimeoutForTest(
    McpServer server, [
    Duration? customTimeout,
  ]) => _effectiveToolTimeout(server, customTimeout);

  Future<McpRpcResult> _callNativeTool(
    _RunningServer rs,
    String toolName,
    Map<String, dynamic> args, {
    Duration? timeout,
  }) async {
    final handler = rs.nativeHandler;
    if (handler == null) {
      return McpRpcResult.error('native handler not initialized');
    }
    final effectiveTimeout = _effectiveToolTimeout(rs.server, timeout);
    try {
      return await handler.callTool(toolName, args).timeout(effectiveTimeout);
    } on TimeoutException {
      return const McpRpcResult.timeout();
    } catch (e) {
      return McpRpcResult.error('$e');
    }
  }

  Future<McpRpcResult> _listNativeTools(_RunningServer rs) async {
    final handler = rs.nativeHandler;
    if (handler == null) {
      return McpRpcResult.error('native handler not initialized');
    }
    try {
      final tools = await handler.listTools();
      return McpRpcResult.ok({
        'tools': tools
            .map(
              (t) => {
                'name': t.name,
                if (t.description != null) 'description': t.description,
                if (t.inputSchema != null) 'inputSchema': t.inputSchema,
              },
            )
            .toList(),
      });
    } catch (e) {
      return McpRpcResult.error('$e');
    }
  }

  /// PR41: Streamable-HTTP transport — no process, no sandbox. Every
  /// JSON-RPC call is its own HTTP POST to [McpServer.url]; the handshake
  /// is the same three calls (initialize/initialized/tools/list) as stdio,
  /// just carried over HTTP instead of stdin/stdout.
  ///
  /// When [deadline] is supplied (startup budget) every RPC is bounded by the
  /// remaining budget instead of the per-server startup timeout.
  Future<String> _connectHttp(
    McpServer server,
    _RunningServer rs, {
    DateTime? deadline,
  }) async {
    final key = _key(server);
    Duration timeoutFor() => deadline == null
        ? Duration(seconds: server.startupTimeoutS)
        : _remainingUntil(deadline);
    Duration phaseTimeout(String phase) {
      final timeout = timeoutFor();
      _recordConnectPhase(phase, timeout);
      return timeout;
    }

    try {
      if (deadline != null && !_now().isBefore(deadline)) {
        throw TimeoutException('MCP handshake timed out', Duration.zero);
      }
      final url = server.url;
      if (url == null || url.isEmpty) {
        throw Exception('no url configured for HTTP transport');
      }
      final initResult = await _rpcHttp(rs, 'initialize', {
        'protocolVersion': '2024-11-05',
        'capabilities': {},
        'clientInfo': {'name': 'ovid-ai', 'version': '1.0.0'},
      }, timeout: phaseTimeout('initialize'));
      if (initResult.isTimeout) {
        throw TimeoutException('initialize timed out', timeoutFor());
      }
      if (initResult.isError) {
        throw Exception('initialize failed: ${initResult.error}');
      }
      _rememberInitializeResult(rs, initResult.value);
      await _sendNotificationHttp(
        rs,
        'notifications/initialized',
        {},
        timeout: phaseTimeout('notifications/initialized'),
      );
      rs.tools =
          await _listToolsHttp(rs, timeout: phaseTimeout('tools/list')) ??
          <McpToolDef>[];
      // A budget abort may have detached this attempt — never mark it ready.
      // The ownership fence covers the cases the runtime map cannot see: an
      // account transition or a plugin unmount/replacement while this
      // handshake was in flight.
      if (!identical(_running[key], rs) ||
          rs.userDisconnected ||
          !_canPublishStatus(rs)) {
        return 'connect aborted';
      }
      rs.handshakeDone = true;
      _markConnected(
        rs,
        '"${server.name}" connected (http) · ${rs.tools.length} tools',
      );
      _reconnectAttempts.remove(key);
      return '"${server.name}" connected (http) · ${rs.tools.length} tools';
    } catch (e) {
      if (identical(_running[key], rs)) _running.remove(key);
      _markDisconnected(rs, 'connect failed: $e');
      return 'connect failed: $e';
    }
  }

  /// Capture the `initialize` result's negotiated protocol version and
  /// capabilities. The version falls back to `2024-11-05` when the server
  /// omits it; the handshake success criteria are unchanged.
  static void _rememberInitializeResult(_RunningServer rs, dynamic value) {
    var version = '2024-11-05';
    if (value is Map<String, dynamic>) {
      final negotiated = value['protocolVersion'];
      if (negotiated is String && negotiated.isNotEmpty) {
        version = negotiated;
      }
      final capabilities = value['capabilities'];
      if (capabilities is Map<String, dynamic>) {
        rs.capabilities = capabilities;
      }
    }
    rs.protocolVersion = version;
  }

  /// Upper bound on `tools/list` pages, so a hostile server that always
  /// returns a `nextCursor` can't make discovery loop forever.
  static const _maxToolListPages = 50;

  /// `tools/list` over Streamable HTTP, following a non-empty `nextCursor`
  /// until the server stops paginating and merging every page. Throws on
  /// timeout/error so the handshake keeps its existing error surfacing.
  Future<List<McpToolDef>?> _listToolsHttp(
    _RunningServer rs, {
    Duration? timeout,
  }) => _listToolsPages(
    rs,
    (params, left) => _rpcHttp(rs, 'tools/list', params, timeout: left),
    timeout: timeout,
  );

  /// One aggregate time/size budget; an incomplete catalog is never published.
  Future<List<McpToolDef>> _listToolsPages(
    _RunningServer rs,
    Future<McpRpcResult> Function(Map<String, dynamic>, Duration) request, {
    Duration? timeout,
  }) async {
    final deadline = _now().add(
      timeout ?? Duration(seconds: _rpcTimeoutSeconds),
    );
    final tools = <McpToolDef>[];
    final names = <String>{};
    final cursors = <String>{};
    var bytes = 0;
    String? cursor;
    for (var page = 0; page < _maxToolListPages; page++) {
      _requireCurrent(rs);
      final left = _remainingUntil(deadline);
      if (left <= Duration.zero) throw TimeoutException('tools/list timed out');
      final res = await request({'cursor': ?cursor}, left);
      if (res.isTimeout) {
        throw TimeoutException('tools/list timed out', timeout);
      }
      if (res.isError) {
        throw Exception('tools/list failed: ${res.error}');
      }
      final payload = res.value;
      if (payload is! Map<String, dynamic>) {
        throw const FormatException('tools/list expected an object');
      }
      bytes += utf8.encode(jsonEncode(payload)).length;
      if (bytes > 4 * 1024 * 1024) {
        throw StateError('tools/list catalog exceeds byte limit');
      }
      final pageTools = payload['tools'];
      if (pageTools is! List) {
        throw const FormatException('tools/list expected a tools array');
      }
      if (tools.length + pageTools.length > 10000) {
        throw StateError('tools/list catalog exceeds tool limit');
      }
      for (final tool in pageTools) {
        if (tool is! Map<String, dynamic> ||
            tool['name'] is! String ||
            (tool['name'] as String).isEmpty ||
            !names.add(tool['name'] as String)) {
          throw const FormatException('tools/list invalid or duplicate tool');
        }
        tools.add(McpToolDef.fromJson(tool));
      }
      final next = payload['nextCursor'];
      if (next == null || next == '') break;
      if (next is! String) {
        throw const FormatException('tools/list expected a string cursor');
      }
      if (next.length > 4096 || !cursors.add(next)) {
        throw StateError('tools/list invalid or repeated cursor');
      }
      if (page + 1 == _maxToolListPages) {
        throw StateError('tools/list exceeds page limit');
      }
      cursor = next;
    }
    return tools;
  }

  /// `tools/list` over stdio, following a non-empty `nextCursor` exactly
  /// like [_listToolsHttp] so paginating servers never lose pages. Throws
  /// on timeout/error so the handshake keeps its existing error surfacing.
  Future<List<McpToolDef>> _listToolsStdio(
    _RunningServer rs, {
    Duration? timeout,
  }) => _listToolsPages(
    rs,
    (params, left) => _rpc(rs, 'tools/list', params, timeout: left),
    timeout: timeout,
  );

  Future<String> _connectStdio(
    McpServer server,
    _RunningServer rs, {
    DateTime? deadline,
  }) async {
    final key = _key(server);
    Duration timeoutFor() => deadline == null
        ? Duration(seconds: server.startupTimeoutS)
        : _remainingUntil(deadline);
    Duration phaseTimeout(String phase) {
      final timeout = timeoutFor();
      _recordConnectPhase(phase, timeout);
      return timeout;
    }

    // The ownership fence is checked here as well as before marking ready:
    // a fence trip mid-attempt (account transition, plugin unmount) must
    // kill the freshly spawned process instead of finishing the handshake.
    bool aborted() =>
        (!identical(_running[key], rs) ||
        rs.userDisconnected ||
        !_canPublishStatus(rs));
    try {
      if (deadline != null && !_now().isBefore(deadline)) {
        throw TimeoutException('MCP handshake timed out', Duration.zero);
      }
      // A stdio entry without a declared command is malformed (MCP
      // requires `command`). Fail loudly here instead of spawning an
      // unrelated default binary.
      if (server.command.trim().isEmpty) {
        throw Exception(
          'MCP server "${server.name}" declares no command — add "command" '
          '(e.g. "npx", "uvx" or "python") to its config.',
        );
      }
      // Spawn inside the native sandbox — servers are trusted code the
      // user explicitly connected, same trust level as MCP defaults.
      // A test spawn override bypasses the sandbox entirely (host CI has
      // no Android sandbox); production always takes the sandbox path.
      final sandbox = SandboxService.I;
      final testSpawn = spawnProcessForTest;
      if (testSpawn == null) {
        if (!sandbox.isInstalled || sandbox.prefixPath == null) {
          throw Exception(
            'MCP servers need the sandbox. Open Studio once to initialize it '
            '(fast native setup), then retry. If the sandbox is already '
            'initialized, this is a bug — report it.',
          );
        }
      }
      // WS2: no silent runtime installs on the MCP path — the eager
      // `missingRuntimeFor` gate in `connect`/`connectOutcome` already
      // reports "needs runtime (<kind>) — install runtimes, then
      // reconnect" before spawning. This probe is the fail-closed
      // backstop for callers that reach _connectStdio without the gate:
      // a pure `command -v` probe (never installs) that throws the same
      // actionable message. Skipped for a test spawn override: the host
      // running the test provides the runtime directly.
      final cmd = server.command;
      final kind = runtimeKindForCommand(cmd);
      if (kind != null && testSpawn == null) {
        if (!await sandbox.hasRuntime(cmd)) {
          throw Exception(
            '"${server.name}" needs runtime ($kind) — install runtimes, '
            'then reconnect',
          );
        }
      }
      // Per-server env vars (API keys etc.) from secure storage.
      final secretEnv = await AppState.I.getMcpEnv(server.canonicalId);
      final runtimeRoot = _runtimeRoot(server);
      final env = {
        if (runtimeRoot != null)
          ...SandboxService.pluginRuntimeEnv(runtimeRoot),
        if (server.ownerPluginId != null)
          ..._pluginRootEnv(server.ownerPluginId!),
        ...secretEnv,
      };
      // Optional working directory for the spawned server (best-effort:
      // only used when the resolved directory actually exists).
      final cwdDir = _resolveWorkingDirectory(server, sandbox.prefixPath);
      _requireCurrent(rs);
      // Native exec — the server command runs through the sandbox env
      // (PATH/LD_LIBRARY_PATH/LD_PRELOAD set by SandboxService.spawn).
      // A test spawn override runs the command directly on the host.
      final proc = testSpawn != null
          ? await testSpawn(
              [server.command, ...server.args],
              env: env.isEmpty ? null : env,
              hostWorkDir: cwdDir,
            )
          : await sandbox.spawn(
              [server.command, ...server.args],
              env: env.isEmpty ? null : env,
              hostWorkDir: cwdDir,
            );
      rs.process = proc;

      // Route stdout lines into the broadcast stream; drain stderr so it
      // never blocks the pipes (keep a tail for diagnostics).
      _attachStdioStreams(rs, key, proc);

      // A budget abort may have landed while the process was spawning — kill
      // it and bail without ever marking the handshake done.
      if (aborted()) {
        try {
          proc.kill();
        } catch (e) {
          Diag.swallow('mcp_service', e);
        }
        return 'connect aborted';
      }

      // Server-death watcher: the moment the process exits, drop it from
      // the connected map. Without this, a crashed server stayed
      // "connected" until the next write to its dead stdin threw.
      // PR41: a death the user didn't ask for (disconnect() sets
      // rs.userDisconnected first) schedules automatic reconnection with
      // backoff instead of just vanishing — ovid-mcp-client parity.
      unawaited(
        proc.exitCode.then((code) {
          if (identical(_running[key], rs)) {
            _running.remove(key);
            _lastDeath = (server: key, code: code, at: DateTime.now());
            if (rs.handshakeDone &&
                !rs.userDisconnected &&
                _canPublishStatus(rs)) {
              _markDisconnected(rs, 'server exited with code $code');
              _scheduleReconnect(server);
            }
          }
        }),
      );

      // ── MCP handshake ──────────────────────────────────────────────
      final initResult = await _rpc(rs, 'initialize', {
        'protocolVersion': '2024-11-05',
        'capabilities': {},
        'clientInfo': {'name': 'ovid-ai', 'version': '1.0.0'},
      }, timeout: phaseTimeout('initialize'));
      if (initResult.isTimeout) {
        throw TimeoutException('initialize timed out', timeoutFor());
      }
      if (initResult.isError) {
        throw Exception('initialize failed: ${initResult.error}');
      }
      _rememberInitializeResult(rs, initResult.value);
      _recordConnectPhase('notifications/initialized', timeoutFor());
      _sendNotification(rs, 'notifications/initialized', {});

      // ── Tool discovery (paginated like the HTTP path: a stdio server
      // returning `nextCursor` must not silently lose pages) ──────────────
      rs.tools = await _listToolsStdio(rs, timeout: phaseTimeout('tools/list'));
      if (aborted()) return 'connect aborted';
      rs.handshakeDone = true;
      _markConnected(
        rs,
        '"${server.name}" connected (stdio) · ${rs.tools.length} tools',
      );
      _reconnectAttempts.remove(key);
      return '"${server.name}" connected · ${rs.tools.length} tools';
    } catch (e) {
      if (identical(_running[key], rs)) _running.remove(key);
      try {
        rs.process?.kill();
      } catch (e) {
        Diag.swallow('mcp_service', e);
      }
      _markDisconnected(rs, 'connect failed: $e');
      return 'connect failed: $e';
    }
  }

  void _attachStdioStreams(_RunningServer rs, String key, Process process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(rs.stdoutLines.add);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(rs.stderrLines.add);
    rs.stdoutLines.stream.listen((line) {
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        _onNotification(rs, json);
      } catch (e) {
        Diag.swallow('mcp_service', e);
      }
    });
  }

  static Directory? _resolveWorkingDirectory(
    McpServer server,
    String? sandboxPrefix,
  ) {
    final cwd = server.cwd;
    if (cwd == null || cwd.isEmpty) return null;
    if (server.ownerPluginId == null) {
      final resolved = cwd.startsWith('/')
          ? cwd
          : '${sandboxPrefix ?? ''}/home/$cwd';
      final directory = Directory(resolved);
      return directory.existsSync() ? directory : null;
    }
    final runtimeRoot = _runtimeRoot(server);
    if (runtimeRoot == null || runtimeRoot.isEmpty) {
      throw StateError('owned MCP runtime root is unavailable');
    }
    final root = Directory(runtimeRoot).resolveSymbolicLinksSync();
    final requested = Directory(cwd.startsWith('/') ? cwd : '$root/$cwd');
    final resolved = requested.resolveSymbolicLinksSync();
    if (resolved != root &&
        !resolved.startsWith('$root${Platform.pathSeparator}')) {
      throw StateError('owned MCP cwd escapes plugin runtime root');
    }
    return Directory(resolved);
  }

  @visibleForTesting
  static Directory? resolveWorkingDirectoryForTest(McpServer server) =>
      _resolveWorkingDirectory(server, null);

  /// PR41: reconnect backoff timers, one per server name so a repeated
  /// crash doesn't stack multiple pending retries.
  final Map<String, Timer> _reconnectTimers = {};

  /// Consecutive failed reconnect attempts per server name. Lives on the
  /// service (not on the per-connect `_RunningServer`, which is recreated
  /// fresh every `connect()` call) so backoff keeps doubling across
  /// repeated failures instead of resetting to attempt 1 each time. Reset
  /// to 0 on any successful handshake.
  final Map<String, int> _reconnectAttempts = {};
  final Map<String, Object> _reconnectGenerations = {};

  /// Schedule an automatic reconnect for [server] after an UNEXPECTED
  /// disconnect (never called after a user-initiated `disconnect()`).
  /// Delay doubles from [reconnectInitialDelayForTest] up to
  /// [reconnectMaxDelayForTest]; gives up silently after
  /// [reconnectMaxAttemptsForTest] consecutive failures (the server stays
  /// listed but disconnected — the user can retry manually, same as
  /// today's behavior before this feature existed).
  void _scheduleReconnect(McpServer server) {
    final key = _key(server);
    final generation = _reconnectGenerations.putIfAbsent(key, Object.new);
    _reconnectTimers.remove(key)?.cancel();
    final attempt = (_reconnectAttempts[key] ?? 0) + 1;
    if (attempt > reconnectMaxAttemptsForTest) return;
    final initialMs = reconnectInitialDelayForTest.inMilliseconds;
    final maxMs = reconnectMaxDelayForTest.inMilliseconds;
    final delayMs = (initialMs * (1 << (attempt - 1))).clamp(initialMs, maxMs);
    _reconnectAttempts[key] = attempt;
    _reconnectTimers[key] = Timer(Duration(milliseconds: delayMs), () async {
      if (!identical(_reconnectGenerations[key], generation)) return;
      _reconnectTimers.remove(key);
      // The user may have manually reconnected (or removed the server)
      // while this timer was pending — never race a live connection.
      if (_running.containsKey(key)) return;
      // Task 4: look the server up by NAME, not object identity — a
      // reload replaces the McpServer instance, so `contains(server)`
      // (identity equality) would silently stop reconnects after any
      // relaunch/reload.
      final fresh = AppState.I.mcpServers
          .where((s) => s.canonicalId == key)
          .firstOrNull;
      if (fresh == null || !_ownerActive(fresh)) return;
      final outcome = await connectOutcome(
        fresh,
        handshakeBudget: Duration(seconds: fresh.startupTimeoutS),
      );
      if (identical(_reconnectGenerations[key], generation) &&
          outcome.kind == McpConnectOutcomeKind.failed &&
          !_running.containsKey(key) &&
          !_sseDestinationFailures.containsKey(key)) {
        _scheduleReconnect(fresh);
      }
    });
  }

  /// Task 4 test seam: would an automatic reconnect run for [serverName]?
  /// Reflects the name-based lookup used by [_scheduleReconnect] — true when
  /// a configured server with that name exists (identity-independent).
  @visibleForTesting
  bool reconnectEligibleForTest(String serverName) => AppState.I.mcpServers.any(
    (s) => s.name == serverName || s.canonicalId == serverName,
  );

  /// Test seam: how many reconnect attempts have been recorded for
  /// [serverName] (0 if none).
  @visibleForTesting
  int reconnectAttemptsForTest(String serverName) =>
      _reconnectAttempts[serverName] ?? 0;

  /// Test seam: is a reconnect currently scheduled for [serverName]?
  @visibleForTesting
  bool hasPendingReconnectForTest(String serverName) =>
      _reconnectTimers.containsKey(serverName);

  /// Cancel any pending reconnect for [serverName] (used by [disconnect]
  /// and available to tests for teardown).
  void _cancelReconnect(String serverName) {
    _reconnectGenerations.remove(serverName);
    _reconnectTimers.remove(serverName)?.cancel();
    _reconnectAttempts.remove(serverName);
  }

  /// Re-run tools/list after a server says its catalog changed.
  Future<void> _rediscoverTools(String serverName) async {
    final rs = _running[serverName];
    if (rs == null || !rs.handshakeDone) return;
    if (rs.rediscovering) {
      rs.rediscoverAgain = true;
      return;
    }
    rs.rediscovering = true;
    try {
      do {
        rs.rediscoverAgain = false;
        final List<McpToolDef>? merged;
        if (rs.server.transport == 'http') {
          merged = await _listToolsHttp(rs);
        } else if (rs.server.transport == 'sse') {
          merged = await _listToolsSse(rs);
        } else if (rs.server.transport == 'native') {
          final result = await _listNativeTools(rs);
          if (result.isError) return;
          merged = (result.value['tools'] as List)
              .map((t) => McpToolDef.fromJson(t as Map<String, dynamic>))
              .toList();
        } else {
          merged = await _listToolsStdio(rs);
        }
        _requireCurrent(rs);
        if (merged != null) rs.tools = merged;
      } while (rs.rediscoverAgain);
    } catch (e) {
      Diag.swallow('mcp_service', e);
    } finally {
      rs.rediscovering = false;
    }
  }

  @visibleForTesting
  Future<void> attachStdioForTest(
    McpServer server,
    Process process, {
    List<McpToolDef> initialTools = const [],
  }) async {
    final key = _key(server);
    final rs = _RunningServer(server: server)
      ..process = process
      ..handshakeDone = true
      ..tools = List.of(initialTools);
    _captureOwnership(rs);
    _running[key] = rs;
    _attachStdioStreams(rs, key, process);
    unawaited(
      process.exitCode.then((code) {
        if (!identical(_running[key], rs)) return;
        _running.remove(key);
        _lastDeath = (server: key, code: code, at: DateTime.now());
        if (rs.handshakeDone && !rs.userDisconnected && _canPublishStatus(rs)) {
          _markDisconnected(rs, 'server exited with code $code');
          _scheduleReconnect(server);
        }
      }),
    );
  }

  /// Kill a server process. Safe to call when not connected. For a
  /// Streamable-HTTP server with a remembered session, best-effort DELETE the
  /// endpoint so the server can terminate that session.
  Future<void> disconnect(String serverName) async {
    final key = _keyForName(serverName);
    _invalidateOAuth(key);
    _sseDestinationFailures.remove(key);
    final rs = _running.remove(key);
    _cancelReconnect(key);
    if (rs == null) return;
    rs.userDisconnected = true;
    if (!rs.connection.isCompleted) {
      rs.connection.complete(
        const McpConnectOutcome(
          McpConnectOutcomeKind.failed,
          'connect aborted',
        ),
      );
    }
    for (final client in rs.httpClients) {
      client.close();
    }
    rs.httpClients.clear();
    // Start the DELETE before the first await so it captures the currently
    // configured HTTP client (a test may clear the injected client between
    // this synchronous call and the request below).
    final sessionDelete = rs.server.transport == 'http' && rs.sessionId != null
        ? _deleteHttpSession(rs)
        : null;
    try {
      await rs.nativeHandler?.dispose();
    } catch (e) {
      Diag.swallow('mcp_service', e);
    }
    try {
      rs.process?.kill();
    } catch (e) {
      Diag.swallow('mcp_service', e);
    }
    try {
      await rs.sseChannel?.close();
    } catch (e) {
      Diag.swallow('mcp_service', e);
    }
    rs.sseChannel = null;
    if (sessionDelete != null) await sessionDelete;
  }

  void _onNotification(_RunningServer rs, Map<String, dynamic> message) {
    if (message.containsKey('id') ||
        !identical(_running[_key(rs.server)], rs) ||
        rs.userDisconnected) {
      return;
    }
    final method = message['method'];
    if (method == 'notifications/tools/list_changed') {
      unawaited(_rediscoverTools(_key(rs.server)));
    }
    final catalogs = switch (method) {
      'notifications/prompts/list_changed' => ['prompts/list'],
      'notifications/resources/list_changed' => [
        'resources/list',
        'resources/templates/list',
      ],
      _ => <String>[],
    };
    for (final catalog in catalogs) {
      rs.catalogVersions[catalog] = (rs.catalogVersions[catalog] ?? 0) + 1;
      rs.catalogs.remove(catalog);
    }
  }

  _RunningServer _protocolServer(String name, String capability) {
    final rs = _running[_keyForName(name)];
    if (rs == null || !rs.handshakeDone || !_ownerActive(rs.server)) {
      throw StateError('MCP server is not connected or active');
    }
    if (rs.server.transport == 'native') {
      throw UnsupportedError(
        'Native MCP $capability methods are not implemented',
      );
    }
    if (rs.capabilities[capability] is! Map) {
      throw UnsupportedError('MCP server does not advertise $capability');
    }
    return rs;
  }

  Future<Map<String, dynamic>> _protocolRequest(
    _RunningServer rs,
    String method,
    Map<String, dynamic> params,
    Duration timeout,
  ) async {
    _requireCurrent(rs);
    final result = switch (rs.server.transport) {
      'http' => await _rpcHttp(rs, method, params, timeout: timeout),
      'sse' => await _rpcSse(rs, method, params, timeout: timeout),
      _ => await _rpc(rs, method, params, timeout: timeout),
    };
    _requireCurrent(rs);
    if (result.isTimeout) throw TimeoutException('$method timed out');
    if (result.isError) throw StateError('$method failed: ${result.error}');
    final payload = result.value;
    if (payload is! Map<String, dynamic>) {
      throw FormatException('$method expected an object');
    }
    if (utf8.encode(jsonEncode(payload)).length > 4 * 1024 * 1024) {
      throw StateError('$method response exceeds byte limit');
    }
    return payload;
  }

  /// Capability-gated, bounded, atomic catalogs. Notifications evict snapshots;
  /// an in-flight invalidated snapshot is rejected, never cached or returned.
  Future<List<Map<String, dynamic>>> listPrompts(
    String serverName, {
    Duration? timeout,
    bool refresh = false,
  }) => _listCatalog(
    serverName,
    'prompts',
    'prompts/list',
    'prompts',
    'name',
    timeout,
    refresh,
  );

  Future<List<Map<String, dynamic>>> listResources(
    String serverName, {
    Duration? timeout,
    bool refresh = false,
  }) => _listCatalog(
    serverName,
    'resources',
    'resources/list',
    'resources',
    'uri',
    timeout,
    refresh,
  );

  Future<List<Map<String, dynamic>>> listResourceTemplates(
    String serverName, {
    Duration? timeout,
    bool refresh = false,
  }) => _listCatalog(
    serverName,
    'resources',
    'resources/templates/list',
    'resourceTemplates',
    'uriTemplate',
    timeout,
    refresh,
  );

  Future<List<Map<String, dynamic>>> _listCatalog(
    String name,
    String capability,
    String method,
    String field,
    String identity,
    Duration? timeout,
    bool refresh,
  ) async {
    final rs = _protocolServer(name, capability);
    if (!refresh && rs.catalogs.containsKey(method)) {
      return rs.catalogs[method]!;
    }
    final version = rs.catalogVersions[method] ?? 0;
    final deadline = _now().add(
      timeout ?? Duration(seconds: _rpcTimeoutSeconds),
    );
    final entries = <Map<String, dynamic>>[];
    final identities = <String>{};
    final cursors = <String>{};
    String? cursor;
    var bytes = 0;
    for (var page = 0; page < 50; page++) {
      final left = _remainingUntil(deadline);
      if (left <= Duration.zero) throw TimeoutException('$method timed out');
      final payload = await _protocolRequest(rs, method, {
        'cursor': ?cursor,
      }, left);
      if ((rs.catalogVersions[method] ?? 0) != version) {
        throw StateError('$method invalidated during discovery; retry');
      }
      bytes += utf8.encode(jsonEncode(payload)).length;
      if (bytes > 4 * 1024 * 1024) {
        throw StateError('$method catalog exceeds byte limit');
      }
      final items = payload[field];
      if (items is! List) {
        throw FormatException('$method expected $field array');
      }
      if (entries.length + items.length > 10000) {
        throw StateError('$method catalog exceeds item limit');
      }
      for (final item in items) {
        if (item is! Map<String, dynamic>) {
          throw FormatException('$method invalid item');
        }
        _requiredString(item, identity);
        _requiredString(item, 'name');
        _optionalString(item, 'description');
        _optionalString(item, 'title');
        if (!identities.add(item[identity] as String)) {
          throw FormatException('$method duplicate identity');
        }
        if (capability == 'prompts' && item.containsKey('arguments')) {
          final arguments = item['arguments'];
          if (arguments is! List) {
            throw const FormatException('Invalid prompt arguments');
          }
          final names = <String>{};
          for (final arg in arguments) {
            if (arg is! Map<String, dynamic>) {
              throw const FormatException('Invalid prompt argument');
            }
            _requiredString(arg, 'name');
            _optionalString(arg, 'description');
            if (!names.add(arg['name'] as String) ||
                (arg.containsKey('required') && arg['required'] is! bool)) {
              throw const FormatException(
                'Invalid or duplicate prompt argument',
              );
            }
          }
        }
        if (capability == 'resources') _optionalString(item, 'mimeType');
        entries.add(_freeze(item) as Map<String, dynamic>);
      }
      final next = payload['nextCursor'];
      if (next == null && !payload.containsKey('nextCursor')) {
        final snapshot = List<Map<String, dynamic>>.unmodifiable(entries);
        rs.catalogs[method] = snapshot;
        return snapshot;
      }
      if (next is! String ||
          next.isEmpty ||
          next.length > 4096 ||
          !cursors.add(next)) {
        throw FormatException('$method invalid or repeated cursor');
      }
      cursor = next;
    }
    throw StateError('$method exceeds page limit');
  }

  static void _requiredString(Map<String, dynamic> value, String key) {
    if (value[key] is! String || (value[key] as String).isEmpty) {
      throw FormatException('Expected nonempty $key string');
    }
  }

  static void _optionalString(Map<String, dynamic> value, String key) {
    if (value.containsKey(key) && value[key] is! String) {
      throw FormatException('Expected $key string');
    }
  }

  static dynamic _freeze(dynamic value) => switch (value) {
    Map<String, dynamic> map => Map<String, dynamic>.unmodifiable(
      map.map((k, v) => MapEntry(k, _freeze(v))),
    ),
    List list => List<dynamic>.unmodifiable(list.map(_freeze)),
    _ => value,
  };

  static void _resourceContents(dynamic value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid resource contents');
    }
    _requiredString(value, 'uri');
    _optionalString(value, 'mimeType');
    if (value.containsKey('text') == value.containsKey('blob')) {
      throw const FormatException('Resource needs exactly one text or blob');
    }
    if (value.containsKey('text')) {
      if (value['text'] is! String) {
        throw const FormatException('Invalid resource text');
      }
    } else {
      if (value['blob'] is! String) {
        throw const FormatException('Invalid resource blob');
      }
      base64Decode(value['blob'] as String);
    }
  }

  static void _promptContent(dynamic value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid prompt content');
    }
    switch (value['type']) {
      case 'text':
        if (value['text'] is! String) {
          throw const FormatException('Invalid prompt text');
        }
      case 'image':
      case 'audio':
        _requiredString(value, 'mimeType');
        _requiredString(value, 'data');
        base64Decode(value['data'] as String);
      case 'resource':
        _resourceContents(value['resource']);
      case 'resource_link':
        _requiredString(value, 'uri');
        _requiredString(value, 'name');
      default:
        throw const FormatException('Unknown prompt content type');
    }
  }

  Future<Map<String, dynamic>> getPrompt(
    String serverName,
    String name, {
    Map<String, String> arguments = const {},
    Duration? timeout,
  }) async {
    if (name.isEmpty) throw ArgumentError('Prompt name is empty');
    final rs = _protocolServer(serverName, 'prompts');
    final payload = await _protocolRequest(rs, 'prompts/get', {
      'name': name,
      'arguments': arguments,
    }, timeout ?? Duration(seconds: _rpcTimeoutSeconds));
    _optionalString(payload, 'description');
    final messages = payload['messages'];
    if (messages is! List) {
      throw const FormatException('Expected prompt messages array');
    }
    for (final message in messages) {
      if (message is! Map<String, dynamic> ||
          !const {'user', 'assistant'}.contains(message['role'])) {
        throw const FormatException('Invalid prompt message role');
      }
      _promptContent(message['content']);
    }
    return _freeze(payload) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> readResource(
    String serverName,
    String uri, {
    Duration? timeout,
  }) async {
    if (uri.isEmpty) throw ArgumentError('Resource URI is empty');
    final rs = _protocolServer(serverName, 'resources');
    final payload = await _protocolRequest(rs, 'resources/read', {
      'uri': uri,
    }, timeout ?? Duration(seconds: _rpcTimeoutSeconds));
    final contents = payload['contents'];
    if (contents is! List) {
      throw const FormatException('Expected resource contents array');
    }
    for (final content in contents) {
      _resourceContents(content);
    }
    return _freeze(payload) as Map<String, dynamic>;
  }

  /// Race [future] against [cancellation]: whichever settles first wins. A
  /// cancellation resolves the call with [McpRpcResult.cancelled] immediately
  /// instead of waiting on a stalled server, while the original future is
  /// still consumed so a late completion/error can never go unhandled.
  static Future<McpRpcResult> _withCancellation(
    Future<McpRpcResult> future,
    UtilityCancellation? cancellation,
  ) {
    if (cancellation == null) return future;
    if (cancellation.isCancelled) {
      return Future.value(const McpRpcResult.cancelled());
    }
    final completer = Completer<McpRpcResult>();
    unawaited(
      cancellation.whenCancelled.then((_) {
        if (!completer.isCompleted) {
          completer.complete(const McpRpcResult.cancelled());
        }
      }),
    );
    unawaited(
      future.then(
        (result) {
          if (!completer.isCompleted) completer.complete(result);
        },
        onError: (Object error, StackTrace stack) {
          if (!completer.isCompleted) completer.completeError(error, stack);
        },
      ),
    );
    return completer.future;
  }

  /// Call a tool on a connected server. Returns the text result.
  ///
  /// [cancellation] aborts an in-flight call the moment the token fires (a
  /// user Stop): the caller returns a cancellation error without waiting for
  /// the server, while the underlying transport still winds itself down.
  ///
  /// Server errors (JSON-RPC error, `isError: true`, timeout, dead process)
  /// come back as an explicit `MCP error: …` string so the model knows the
  /// call failed — they used to masquerade as results (or as the text
  /// "null").
  Future<String> callTool(
    String serverName,
    String toolName,
    Map<String, dynamic> args, {
    Duration? timeout,
    UtilityCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled ?? false) {
      return 'MCP error: "$toolName" on "$serverName" was cancelled.';
    }
    final key = _keyForName(serverName);
    final rs = _running[key];
    if (rs == null) {
      final refusal = _sseDestinationFailures[key];
      if (refusal != null) return 'MCP error: $refusal';
      return 'MCP error: server "$serverName" is not connected'
          '${_lastDeathOf(key)}';
    }
    final effectiveTimeout = _effectiveToolTimeout(rs.server, timeout);
    final pending = rs.server.transport == 'http'
        ? _rpcHttp(
            rs,
            'tools/call',
            {'name': toolName, 'arguments': args},
            timeout: effectiveTimeout,
            cancelOnTimeout: true,
          )
        : rs.server.transport == 'sse'
        ? _rpcSse(rs, 'tools/call', {
            'name': toolName,
            'arguments': args,
          }, timeout: effectiveTimeout)
        : rs.server.transport == 'native'
        ? _callNativeTool(rs, toolName, args, timeout: effectiveTimeout)
        : _rpc(rs, 'tools/call', {
            'name': toolName,
            'arguments': args,
          }, timeout: effectiveTimeout);
    final res = await _withCancellation(pending, cancellation);
    if (res.isCancelled) {
      return 'MCP error: "$toolName" on "$serverName" was cancelled.';
    }
    if (rs.sseDestinationFailure != null) {
      return 'MCP error: ${rs.sseDestinationFailure}';
    }
    if (res.isTimeout) {
      return 'MCP error: "$toolName" on "$serverName" timed out after '
          '${effectiveTimeout.inSeconds} s (server may be busy or dead).';
    }
    if (res.isError) {
      return 'MCP error: ${res.error}';
    }
    final payload = res.value;
    if (payload is Map<String, dynamic>) {
      final flagged = payload['isError'] as bool? ?? false;
      final content = payload['content'] as List?;
      if (content != null) {
        final parts = <String>[];
        for (final c in content) {
          if (c is! Map) continue;
          final type = c['type'];
          if (type == 'text') {
            final t = c['text'];
            if (t is String && t.trim().isNotEmpty) parts.add(t);
          } else if (type == 'resource') {
            final r = c['resource'];
            if (r is Map) {
              if (r['text'] is String) {
                parts.add('[resource] ${r['text']}');
              } else if (r['blob'] is String) {
                final mime = r['mimeType'] ?? 'application/octet-stream';
                parts.add(
                  '[resource content returned — $mime, '
                  '${_base64ByteLength(r['blob'] as String)} bytes]',
                );
              }
            }
          } else if (type == 'image') {
            // Images can't reach a text-only model context; note them so
            // the model knows something was produced.
            parts.add('[image content returned — not displayable here]');
          } else if (type == 'audio') {
            final mime = c['mimeType'] ?? 'audio/*';
            final data = c['data'];
            parts.add(
              '[audio content returned — $mime, '
              '${data is String ? _base64ByteLength(data) : 0} bytes]',
            );
          } else if (type == 'resource_link') {
            final uri = c['uri'];
            if (uri is String && uri.isNotEmpty) {
              final label =
                  c['name'] is String && (c['name'] as String).isNotEmpty
                  ? ' (${c['name']})'
                  : '';
              final description =
                  c['description'] is String &&
                      (c['description'] as String).isNotEmpty
                  ? ': ${c['description']}'
                  : '';
              final mime =
                  c['mimeType'] is String &&
                      (c['mimeType'] as String).isNotEmpty
                  ? ' [${c['mimeType']}]'
                  : '';
              parts.add('[resource link] $uri$label$description$mime');
            }
          }
        }
        final structured = payload['structuredContent'];
        if (structured != null) parts.add(jsonEncode(structured));
        final text = parts.join('\n');
        if (flagged) return 'MCP error: ${_trimResult(text)}';
        return _trimResult(text);
      }
      return _trimResult(jsonEncode(payload));
    }
    if (payload == null) return 'MCP error: empty response';
    return _trimResult('$payload');
  }

  /// Tear everything down (app exit / settings reset).
  Future<void> disconnectAll() async {
    _sseDestinationFailures.clear();
    for (final name in _running.keys.toList()) {
      await disconnect(name);
    }
  }

  /// Last known death of a server (diagnostics for "not connected").
  ({String server, int code, DateTime at})? _lastDeath;
  String _lastDeathOf(String serverName) {
    final d = _lastDeath;
    if (d == null || d.server != serverName) return '';
    final hh = d.at.hour.toString().padLeft(2, '0');
    final mm = d.at.minute.toString().padLeft(2, '0');
    return ' (its process exited with code ${d.code} at $hh:$mm)';
  }

  /// Test seam: drive ONE `callTool` round-trip against canned server
  /// replies, exercising the real line-parse + result/error/timeout paths
  /// with no process, no sandbox, and a millisecond deadline.
  @visibleForTesting
  static Future<String> callToolForTest({
    required List<String> replies,
    String method = 'tools/call',
    Duration? timeout,
    UtilityCancellation? cancellation,
  }) async {
    final harness = _McpTestHarness(replies);
    final svc = McpService._();
    final rs = _RunningServer(
      server: McpServer(
        name: 'test-server',
        author: 't',
        description: '',
        category: 'Custom',
        command: 'npx',
        args: const [],
      ),
    );
    rs.process = harness.process;
    svc._running['test-server'] = rs;
    // Deliver the canned replies the moment the request is written.
    unawaited(
      harness.requestWritten.then((_) {
        for (final line in replies) {
          rs.stdoutLines.add(line);
        }
      }),
    );
    try {
      return await svc.callTool(
        'test-server',
        'tool',
        {},
        timeout: timeout,
        cancellation: cancellation,
      );
    } finally {
      await harness.dispose();
    }
  }

  // ── internals ─────────────────────────────────────────────────────────

  int _nextId = 1;

  /// RPC deadline. Tests shorten it so timeout paths run in milliseconds
  /// instead of the production 60 s. Null in production so the per-server
  /// [McpServer.toolTimeoutS] governs tool calls; a non-null value is an
  /// explicit test override that takes precedence.
  @visibleForTesting
  static int? rpcTimeoutSecondsForTest;
  static int get _rpcTimeoutSeconds => rpcTimeoutSecondsForTest ?? 60;

  void _sendNotification(
    _RunningServer rs,
    String method,
    Map<String, dynamic> params,
  ) {
    final proc = rs.process;
    if (proc == null) return;
    // A dead pipe throws — dropping the notification is fine (it is
    // fire-and-forget; the death watcher removes the server anyway).
    try {
      proc.stdin.writeln(
        jsonEncode({'jsonrpc': '2.0', 'method': method, 'params': params}),
      );
    } catch (e) {
      Diag.swallow('mcp_service', e);
    }
  }

  /// PR41: Streamable-HTTP JSON-RPC notification — a POST that carries no
  /// `id`. Best-effort: a server may legitimately respond 202/204 with no
  /// body, or ignore the initialized notification entirely (optional per
  /// the MCP spec).
  Future<void> _sendNotificationHttp(
    _RunningServer rs,
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) async {
    final url = rs.server.url;
    if (url == null) return;
    final client = httpClientForTest ?? http.Client();
    final ownsClient = httpClientForTest == null;
    if (ownsClient) rs.httpClients.add(client);
    try {
      final authHeaders = await _authHeaders(rs);
      _requireCurrent(rs);
      final res = await _sendMcpHttpRequest(
        client,
        'POST',
        Uri.parse(url),
        {
          'Content-Type': 'application/json',
          'Accept': 'application/json, text/event-stream',
          if (rs.sessionId != null) 'Mcp-Session-Id': rs.sessionId!,
          if (rs.protocolVersion != null)
            'MCP-Protocol-Version': rs.protocolVersion!,
          ...authHeaders,
          ...rs.server.headers,
        },
        body: jsonEncode({
          'jsonrpc': '2.0',
          'method': method,
          'params': params,
        }),
        timeout: timeout ?? Duration(seconds: rs.server.startupTimeoutS),
      );
      _rememberSessionId(rs, res.headers);
    } catch (_) {
      // Notifications are fire-and-forget by design.
    } finally {
      if (ownsClient) client.close();
      rs.httpClients.remove(client);
    }
  }

  /// Best-effort `notifications/cancelled` for a request that timed out, so a
  /// busy server can stop working on it. Fire-and-forget — it never masks or
  /// replaces the timeout error the caller already surfaced.
  Future<void> _sendCancelledHttp(_RunningServer rs, int requestId) =>
      _sendNotificationHttp(rs, 'notifications/cancelled', {
        'requestId': requestId,
        'reason': 'request timed out',
      });

  /// PR41: Streamable-HTTP JSON-RPC request/response — one POST per call,
  /// same [McpRpcResult] contract as the stdio [_rpc] so every downstream
  /// consumer (callTool's content parsing, timeout/error surfacing) is
  /// transport-agnostic. A connection-level failure (can't reach the
  /// server at all — DNS, refused, timeout) is treated exactly like a
  /// stdio process death: the server drops out of `_running` and an
  /// automatic reconnect is scheduled (unless the user disconnected).
  Future<McpRpcResult> _rpcHttp(
    _RunningServer rs,
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
    bool cancelOnTimeout = false,
  }) async {
    final url = rs.server.url;
    if (url == null) {
      return McpRpcResult._error('no url configured');
    }
    final id = _nextId++;
    final client = httpClientForTest ?? http.Client();
    final ownsClient = httpClientForTest == null;
    if (ownsClient) rs.httpClients.add(client);
    try {
      var authHeaders = await _authHeaders(rs);

      // One POST attempt; factored out so a 401 can trigger a single
      // silent OAuth refresh + retry.
      Future<(http.Response, Map<String, dynamic>?)> doPost() async {
        _requireCurrent(rs);
        final res = await _sendMcpHttpRequest(
          client,
          'POST',
          Uri.parse(url),
          {
            'Content-Type': 'application/json',
            'Accept': 'application/json, text/event-stream',
            if (rs.sessionId != null) 'Mcp-Session-Id': rs.sessionId!,
            if (method != 'initialize' && rs.protocolVersion != null)
              'MCP-Protocol-Version': rs.protocolVersion!,
            ...authHeaders,
            ...rs.server.headers,
          },
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'method': method,
            'params': params,
          }),
          timeout: timeout ?? Duration(seconds: _rpcTimeoutSeconds),
        );
        _rememberSessionId(rs, res.headers);
        if (rs.userDisconnected) {
          if (rs.sessionId != null) unawaited(_deleteHttpSession(rs));
          _requireCurrent(rs);
        }
        // A single-object JSON response is the common case; a
        // "text/event-stream" response carries one or more SSE events
        // (`event:` + `data:` lines separated by blank lines). Take the
        // event whose `data` decodes to our `id` (earlier events are
        // unrelated notifications the server may have flushed first).
        final contentType = res.headers['content-type'] ?? '';
        Map<String, dynamic>? j;
        if (contentType.contains('text/event-stream')) {
          j = _parseSseResponse(res.body, id, rs: rs);
        } else if (res.body.trim().isNotEmpty) {
          try {
            j = jsonDecode(res.body) as Map<String, dynamic>;
          } catch (e) {
            Diag.swallow('mcp_service', e);
          }
        }
        return (res, j);
      }

      var (res, j) = await doPost();
      if ((res.statusCode == 401 || res.statusCode == 403) &&
          authHeaders.isNotEmpty &&
          await _tryRefreshOAuth(rs)) {
        // The stored token was stale and a refresh token existed — one
        // retry with the fresh token, then accept whatever comes back.
        authHeaders = await _authHeaders(rs);
        final retry = await doPost();
        res = retry.$1;
        j = retry.$2;
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        rs.authenticationFailed = true;
        // Authentication failure is NOT a transient connection problem —
        // reconnecting would just loop forever. Re-prompt the user to fix
        // the credential; never schedule an automatic reconnect for it.
        return McpRpcResult._error(
          'authentication failed (HTTP ${res.statusCode}) — check the '
          'server\'s auth headers/token and re-connect after fixing them.',
        );
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        // The server responded (just not successfully) — it's still up,
        // so this is a per-call error, not a connection failure. A
        // non-2xx with a JSON-RPC error body still carries a useful
        // message; fall back to the raw status when it doesn't.
        final msg = j?['error'] is Map
            ? '${(j!['error'] as Map)['message'] ?? res.statusCode}'
            : 'HTTP ${res.statusCode}';
        return McpRpcResult._error(msg);
      }
      if (j == null) return McpRpcResult._error('empty or unparsable response');
      if (j.containsKey('error')) {
        final err = j['error'];
        return McpRpcResult._error(
          err is Map ? '${err['message'] ?? err['code'] ?? 'error'}' : '$err',
        );
      }
      return McpRpcResult._ok(j['result']);
    } on TimeoutException {
      if (cancelOnTimeout) {
        // Best-effort only: the timeout error below is still the caller's
        // result, and cancellation never throws into this path.
        unawaited(_sendCancelledHttp(rs, id));
      }
      return const McpRpcResult._timeout();
    } catch (e) {
      // Connection-level failure (refused, DNS, socket) — the server is
      // effectively down; drop it and schedule a reconnect exactly like
      // an unexpected stdio process death.
      _markHttpFailure(rs);
      return McpRpcResult._error('$e');
    } finally {
      // Task 4: don't leak a client/host connection pool per call — close
      // the client we created (never the caller-injected test mock).
      if (ownsClient) client.close();
      rs.httpClients.remove(client);
    }
  }

  /// Remember a `Mcp-Session-Id` header (case-insensitive) so subsequent
  /// requests to the SAME server re-use the session (Streamable-HTTP spec).
  void _rememberSessionId(_RunningServer rs, Map<String, String> headers) {
    String? sid;
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == 'mcp-session-id') {
        sid = e.value;
        break;
      }
    }
    if (sid != null && sid.isNotEmpty) rs.sessionId = sid;
  }

  /// Best-effort HTTP DELETE terminating a Streamable-HTTP session. Never
  /// throws — a server that can't be reached still disconnects locally.
  Future<void> _deleteHttpSession(_RunningServer rs) async {
    final url = rs.server.url;
    final sessionId = rs.sessionId;
    if (url == null || sessionId == null) return;
    final injected = httpClientForTest;
    final client = injected ?? http.Client();
    try {
      final authHeaders = await _authHeaders(rs);
      await _sendMcpHttpRequest(client, 'DELETE', Uri.parse(url), {
        'Mcp-Session-Id': sessionId,
        if (rs.protocolVersion != null)
          'MCP-Protocol-Version': rs.protocolVersion!,
        ...authHeaders,
        ...rs.server.headers,
      }, timeout: Duration(seconds: rs.server.startupTimeoutS));
    } catch (_) {
      // Best-effort teardown: never let a dead endpoint block disconnect.
    } finally {
      if (injected == null) client.close();
    }
  }

  /// Parse a `text/event-stream` body into the JSON-RPC response whose `id`
  /// matches [id]. Handles `event:` lines and multi-line `data:` blocks
  /// (joined per the SSE spec). Returns null if no matching event is found.
  Map<String, dynamic>? _parseSseResponse(
    String body,
    int id, {
    _RunningServer? rs,
  }) {
    final events = body.split(RegExp(r'\r?\n\r?\n'));
    Map<String, dynamic>? response;
    for (final event in events) {
      final dataParts = <String>[];
      for (final rawLine in event.split('\n')) {
        final line = rawLine.trimRight();
        if (line.startsWith('data:')) {
          dataParts.add(line.substring(5).trim());
        }
      }
      if (dataParts.isEmpty) continue;
      final payload = dataParts.join('\n');
      try {
        final decoded = jsonDecode(payload) as Map<String, dynamic>;
        if (rs != null && !decoded.containsKey('id')) {
          _onNotification(rs, decoded);
        }
        if (decoded['id']?.toString() == id.toString()) response = decoded;
      } catch (e) {
        Diag.swallow('mcp_service', e);
      }
    }
    return response;
  }

  /// An HTTP server has no process to watch for death, so a connection-
  /// level failure on any call is this transport's equivalent signal:
  /// drop it from `_running` and schedule automatic reconnection (unless
  /// the user explicitly disconnected it). Only fires for a server that
  /// was actually UP (`handshakeDone`) — a failure during the initial
  /// handshake is an ordinary failed `connect()`, not something to
  /// "recover" from; `_connectHttp`'s own catch handles that case.
  void _markHttpFailure(_RunningServer rs) {
    if (!rs.handshakeDone) return;
    final key = _key(rs.server);
    if (!identical(_running[key], rs)) return; // already superseded
    _running.remove(key);
    _markDisconnected(rs, 'HTTP connection failed unexpectedly');
    _lastDeath = (server: key, code: -1, at: DateTime.now());
    if (!rs.userDisconnected && _canPublishStatus(rs)) {
      _scheduleReconnect(rs.server);
    }
  }

  void _markConnected(_RunningServer rs, String detail) {
    if (!_canPublishStatus(rs)) return;
    rs.server.connected = true;
    AppState.I.updateServiceStatus(
      'mcp:${rs.server.canonicalId}',
      ServiceHealth.working,
      detail: detail,
    );
  }

  void _markDisconnected(_RunningServer rs, String detail) {
    if (!_canPublishStatus(rs)) return;
    rs.server.connected = false;
    AppState.I.updateServiceStatus(
      'mcp:${rs.server.canonicalId}',
      ServiceHealth.failed,
      detail: detail,
    );
  }

  /// Capture the session token and row-registration identity a connection
  /// starts under, so its late callbacks can be fenced against account
  /// transitions and plugin unmounts. Called when the [_RunningServer]
  /// reservation is made (never mid-connect, never for harness-only
  /// servers that never publish status).
  void _captureOwnership(_RunningServer rs) {
    rs.sessionToken = AppState.I.sessionAccountToken;
    rs.rowRegistered = AppState.I.mcpServers.any(
      (s) => s.canonicalId == rs.server.canonicalId,
    );
  }

  /// True when a late callback from [rs] may still publish service status
  /// or mutate its [McpServer] row: the session that started the
  /// connection is still current, and — when the row was registered at
  /// connect time — a row with the same canonical id is still registered.
  ///
  /// The `identical(_running[key], rs)` checks in the exit/close watchers
  /// only protect the runtime map: `transitionSessionAccount` swaps the
  /// session token synchronously and plugin unmount removes the row, both
  /// without touching [_running], so without this fence a stale connection
  /// can publish into a new account or resurrect an unmounted row.
  /// Unregistered (harness) servers are never fenced, and an ordinary
  /// same-account disconnect — token unchanged, row still registered —
  /// always passes.
  bool _canPublishStatus(_RunningServer rs) {
    final token = rs.sessionToken;
    if (token == null) return true;
    if (!identical(token, AppState.I.sessionAccountToken)) return false;
    if (rs.rowRegistered) {
      final canonicalId = rs.server.canonicalId;
      if (!AppState.I.mcpServers.any((s) => s.canonicalId == canonicalId)) {
        return false;
      }
    }
    return true;
  }

  /// Send a JSON-RPC request and await the matching response (id-correlated).
  ///
  /// A JSON-RPC **error** object is unwrapped into [McpRpcResult.error] —
  /// callers can never mistake it for a result. Timeouts are flagged via
  /// [McpRpcResult.isTimeout] instead of returning null.
  Future<McpRpcResult> _rpc(
    _RunningServer rs,
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) async {
    final proc = rs.process;
    if (proc == null) {
      return McpRpcResult._error('server process not running');
    }
    final id = _nextId++;

    // Line-split stdout; responses are single-line JSON.
    final lines = rs.stdoutLines;
    final completer = Completer<McpRpcResult>();
    late final StreamSubscription sub;
    sub = lines.stream.listen((line) {
      if (completer.isCompleted) return;
      final trimmed = line.trim();
      if (trimmed.isEmpty) return;
      Map<String, dynamic>? j;
      try {
        j = jsonDecode(trimmed) as Map<String, dynamic>;
      } catch (_) {
        // A line that STARTS a JSON object/array but won't decode as a
        // complete value is a pretty-printed (multi-line) payload — stdio
        // MCP requires exactly one JSON value per line. Surface a clear
        // error instead of silently ignoring it (which read as a hang).
        if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
          completer.complete(
            McpRpcResult._error(
              'server sent pretty-printed (multi-line) JSON — the stdio '
              'MCP transport requires one JSON value per line; configure '
              'the server to emit compact single-line JSON.',
            ),
          );
          sub.cancel();
        }
        return;
      }
      // Tolerate string ids — some servers echo the id as "1" instead of 1.
      if (j['id']?.toString() == id.toString()) {
        if (j.containsKey('error')) {
          final err = j['error'];
          completer.complete(
            McpRpcResult._error(
              err is Map
                  ? '${err['message'] ?? err['code'] ?? 'error'}'
                  : '$err',
            ),
          );
        } else {
          completer.complete(McpRpcResult._ok(j['result']));
        }
        sub.cancel();
      }
    });

    // A dead stdin (server crashed mid-call) throws — surface it as an MCP
    // error rather than an uncaught exception.
    try {
      proc.stdin.writeln(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': params,
        }),
      );
    } catch (_) {
      await sub.cancel();
      return McpRpcResult._error('server pipe closed (stdin write failed)');
    }

    try {
      return await completer.future.timeout(
        timeout ?? Duration(seconds: _rpcTimeoutSeconds),
        onTimeout: () => McpRpcResult._timeout(),
      );
    } finally {
      await sub.cancel();
    }
  }
}

/// Truthful outcome of one complete MCP handshake attempt used by startup.
enum McpConnectOutcomeKind {
  ready,
  needsSetup,
  needsRuntime,
  unsupported,
  failed,
}

class McpConnectOutcome {
  const McpConnectOutcome(this.kind, [this.reason]);

  final McpConnectOutcomeKind kind;
  final String? reason;

  bool get isReady => kind == McpConnectOutcomeKind.ready;
}

/// One JSON-RPC round-trip outcome: a result, an error, or a timeout.
/// [error] is non-null iff isError; [value] is the raw result payload.
class McpRpcResult {
  final dynamic value;
  final String? error;
  final bool isTimeout;
  final bool isCancelled;
  const McpRpcResult._ok(this.value)
    : error = null,
      isTimeout = false,
      isCancelled = false;
  const McpRpcResult._error(String e)
    : value = null,
      error = e,
      isTimeout = false,
      isCancelled = false;
  const McpRpcResult._timeout()
    : value = null,
      error = null,
      isTimeout = true,
      isCancelled = false;
  const McpRpcResult.ok(this.value)
    : error = null,
      isTimeout = false,
      isCancelled = false;
  const McpRpcResult.error(String e)
    : value = null,
      error = e,
      isTimeout = false,
      isCancelled = false;
  const McpRpcResult.timeout()
    : value = null,
      error = null,
      isTimeout = true,
      isCancelled = false;
  const McpRpcResult.cancelled()
    : value = null,
      error = null,
      isTimeout = false,
      isCancelled = true;

  bool get isError => error != null;
}

/// Tool definition advertised by an MCP server (from tools/list).
class McpToolDef {
  final String name;
  final String? description;
  final Map<String, dynamic>? inputSchema;

  McpToolDef({required this.name, this.description, this.inputSchema});

  factory McpToolDef.fromJson(Map<String, dynamic> j) => McpToolDef(
    name: j['name'] as String? ?? '',
    description: j['description'] as String?,
    inputSchema: j['inputSchema'] as Map<String, dynamic>?,
  );

  /// Convert to an OpenAI function-tool schema for the agent loop.
  Map<String, dynamic> toOpenAiTool(String serverKey) => {
    'type': 'function',
    'function': {
      'name': 'mcp__${serverKey}__$name',
      'description': description ?? 'MCP tool $name',
      'parameters': inputSchema ?? {'type': 'object', 'properties': {}},
    },
  };
}

class McpConnectedTool {
  final McpServer server;
  final McpToolDef tool;

  const McpConnectedTool(this.server, this.tool);

  static String _safe(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_-]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  String get canonicalId => 'mcp:${server.canonicalId}/${tool.name}';

  String get canonicalToolName =>
      'mcp_${McpService._providerEncode(canonicalId)}';

  String get legacyToolName => 'mcp__${_safe(server.name)}__${tool.name}';

  Map<String, dynamic> toOpenAiTool({required bool canonical}) => {
    'type': 'function',
    'function': {
      'name': canonical ? canonicalToolName : legacyToolName,
      'description': tool.description ?? 'MCP tool ${tool.name}',
      'parameters': tool.inputSchema ?? {'type': 'object', 'properties': {}},
    },
  };
}

class _RunningServer {
  final McpServer server;
  final connection = Completer<McpConnectOutcome>();
  final httpClients = <http.Client>{};
  Process? process;
  NativeMcpHandler? nativeHandler;

  /// Legacy-SSE channel (`sse` transport); non-null while connected.
  _SseMcpChannel? sseChannel;
  String? sseDestinationFailure;

  bool handshakeDone = false;
  bool authenticationFailed = false;
  bool rediscovering = false;
  bool rediscoverAgain = false;
  List<McpToolDef> tools = [];
  final catalogs = <String, List<Map<String, dynamic>>>{};
  final catalogVersions = <String, int>{};
  final stdoutLines = _LineStream();
  final stderrLines = <String>[];

  /// Streamable-HTTP session id (`Mcp-Session-Id`), remembered from the
  /// initialize response and echoed on subsequent requests.
  String? sessionId;

  /// Protocol version negotiated by `initialize` (server value, or the
  /// `2024-11-05` default when the server omits it). Sent as the
  /// `MCP-Protocol-Version` header on every request after the handshake.
  String? protocolVersion;

  /// Capabilities advertised in the `initialize` result, kept for
  /// diagnostics. Empty until the handshake completes.
  Map<String, dynamic> capabilities = const {};

  /// PR41: set by [McpService.disconnect] BEFORE killing the process, so
  /// the death watcher can tell a user-initiated disconnect apart from an
  /// unexpected crash — only the latter schedules automatic reconnection.
  bool userDisconnected = false;

  /// Session ownership fence: the [AppState.sessionAccountToken] captured
  /// when this connection started. Account transitions swap the token
  /// synchronously without touching [_running], so a late stdio exit /
  /// SSE close / HTTP failure callback must re-check it before publishing
  /// status or mutating the row. Null only for harness-only servers that
  /// never publish ([McpService.callToolForTest]).
  Object? sessionToken;

  /// Whether a row for this server was registered in [AppState.mcpServers]
  /// when the connection started. A registered row that has since been
  /// unmounted (or replaced) must no longer receive status publishes, while
  /// servers that were never registered are never row-fenced.
  bool rowRegistered = false;

  _RunningServer({required this.server});
}

/// In-process Process stand-in for tests: a single request "write" on
/// stdin completes [requestWritten]; canned lines are then fed back through
/// the server's stdout stream. No process, no sandbox, no timing flake.
class _McpTestHarness {
  final _written = Completer<void>();
  Future<void> get requestWritten => _written.future;
  late final FakeMcpProcess process;

  _McpTestHarness(List<String> replies) {
    process = FakeMcpProcess(_written);
  }

  Future<void> dispose() async {}
}

/// The Process interface _rpc actually touches: stdin.writeln + exitCode.
class FakeMcpProcess implements Process {
  final Completer<void> _written;
  FakeMcpProcess(this._written);

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  IOSink get stdin => _FakeStdinSink(_written);

  @override
  Future<int> get exitCode => Future.value(0);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('FakeMcpProcess: ${invocation.memberName}');
  }
}

class _FakeStdinSink implements IOSink {
  final Completer<void> _written;
  var _lines = 0;
  _FakeStdinSink(this._written);

  @override
  void writeln([Object? object = '']) {
    _lines++;
    if (_lines >= 1 && !_written.isCompleted) _written.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('_FakeStdinSink: ${invocation.memberName}');
  }
}

/// Broadcast stream of decoded stdout lines (multiple _rpc listeners can
/// subscribe concurrently; each request filters by id).
class _LineStream {
  final _controller = StreamController<String>.broadcast();
  Stream<String> get stream => _controller.stream;
  void add(String line) => _controller.add(line);
}
