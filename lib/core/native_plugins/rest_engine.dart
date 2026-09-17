import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:ovid_ai/core/native_plugin.dart';

/// Declarative REST framework + special engines (NP4 Task 1).
///
/// Two mechanisms share this file:
///
/// **(A) Declarative REST descriptors** (bulk of NP4): one
/// [RestServiceDescriptor] per external service (base URL + auth scheme +
/// credential fields + 2–4 curated tools). A single [RestApiCapability]
/// engine executes them: path `{arg}` substitution, auth injection per
/// [RestAuthKind], `queryArgs` → query params, `jsonBodyArg` (or
/// `formBodyArg` for Stripe-style form-encoded bodies).
///
/// **(B) Special engines**: SigV4 request signing ([s3Authorization], pure
/// Dart via `package:crypto`), a minimal Redis RESP client ([respEncode],
/// [RespClient] over `dart:io` sockets), and Obsidian vault file access
/// ([VaultFiles], `dart:io`).
///
/// Framework conventions (mirror the sibling NP2/NP3 capabilities):
/// - `timeout_seconds` on every tool: tolerant-parsed (`num` or numeric
///   `String`, else [FormatException]), default 30s, clamped 5..300s.
/// - Oversized results trimmed head+tail at 6000 chars with the exact MCP
///   omission notice.
/// - Missing credentials never fake success: tools return an exact
///   `Configure <label> first: …` message (the secret value itself never
///   appears in the message).
/// - Unknown tools and missing arguments throw [ArgumentError];
///   non-2xx HTTP responses come back verbatim with their status line.
///
/// HTTP-dependent code takes an injectable [http.Client] so tests supply a
/// `MockClient` and never touch the real network.
///
/// Placeholder substitution covers both tool paths and the descriptor base
/// URL: each `{name}` is filled from the tool args first, then from the
/// stored configuration (secret + extras) — so path-segment secrets such
/// as Telegram's `/bot{bot_token}/sendMessage` work with `auth: none`.
void registerRestServices(List<RestServiceDescriptor> services) {
  for (final service in services) {
    NativePluginRegistry.I.register(RestApiCapability(service));
  }
}

/// Authentication schemes supported by [RestApiCapability].
enum RestAuthKind {
  /// No auth material is attached. The descriptor may still declare a
  /// [RestServiceDescriptor.credentialKey] when the secret travels in the
  /// path (Telegram-style `/bot{bot_token}/…`); the configure-first gate
  /// still applies then.
  none,

  /// `Authorization: <prefix><secret>` (e.g. `Bearer `, `Bot `, `Token `).
  bearerHeader,

  /// `<authHeader>: <prefix><secret>` for vendor headers
  /// (e.g. `PRIVATE-TOKEN`, `X-Figma-Token`, `x-api-key`).
  apiKeyHeader,

  /// `?<authQueryKey>=<secret>` appended to the query string.
  queryKey,

  /// `Authorization: Basic base64(<username>:<secret>)` where `<username>`
  /// is the stored value of [RestServiceDescriptor.authUsernameKey].
  basic,
}

/// One curated endpoint on a [RestServiceDescriptor].
class RestToolDef {
  const RestToolDef({
    required this.name,
    required this.description,
    required this.method,
    required this.path,
    this.inputSchema = const {},
    this.queryArgs = const [],
    this.jsonBodyArg,
    this.formBodyArg,
    this.required = const [],
  });

  /// Tool name (suffixed to the plugin slug at registration time by the
  /// agent layer).
  final String name;
  final String description;

  /// GET/POST/PUT/PATCH/DELETE (case-insensitive; anything else is an
  /// [ArgumentError] at call time).
  final String method;

  /// Path with `{arg}` substitution from args (then stored config).
  final String path;

  /// JSON-schema-ish map for the tool; the engine always injects a
  /// `timeout_seconds` property on top.
  final Map<String, dynamic> inputSchema;

  /// Arg names forwarded as URL query parameters (skipped when absent).
  final List<String> queryArgs;

  /// Arg name holding the JSON body map (defaults to `{}` when absent).
  final String? jsonBodyArg;

  /// Arg name holding a form map, sent as
  /// `application/x-www-form-urlencoded` (Stripe-style). Mutually exclusive
  /// with [jsonBodyArg].
  final String? formBodyArg;

  /// Required arg names (missing → [ArgumentError]).
  final List<String> required;
}

/// Static description of one external REST service.
class RestServiceDescriptor {
  const RestServiceDescriptor({
    required this.pluginName,
    required this.baseUrl,
    required this.auth,
    this.authHeader,
    this.authPrefix = '',
    this.authQueryKey = '',
    this.authUsernameKey = '',
    this.credentialKey = '',
    this.credentialLabel = '',
    this.extraConfig = const [],
    required this.tools,
  });

  /// Seed-exact plugin display name (also the config namespace).
  final String pluginName;

  /// e.g. `https://slack.com/api` (trailing `/` tolerated). May contain
  /// `{configKey}` placeholders resolved from stored configuration.
  final String baseUrl;

  final RestAuthKind auth;

  /// Header name for [RestAuthKind.bearerHeader] (`Authorization`) and
  /// [RestAuthKind.apiKeyHeader] (e.g. `X-Figma-Token`).
  final String? authHeader;

  /// Prefix before the secret in the auth header (e.g. `Bearer `, `Bot `).
  final String authPrefix;

  /// Query parameter name for [RestAuthKind.queryKey] (e.g. `api_key`).
  final String authQueryKey;

  /// Extra-config key holding the username for [RestAuthKind.basic].
  final String authUsernameKey;

  /// Config key holding the secret (`''` = no credential needed).
  final String credentialKey;

  /// Human label used in the Configure sheet and the configure-first
  /// message.
  final String credentialLabel;

  /// Non-secret extras (hosts, ids, usernames).
  final List<NativePluginConfigField> extraConfig;

  final List<RestToolDef> tools;
}

/// Executes every tool of one [RestServiceDescriptor].
class RestApiCapability implements NativePluginCapability {
  RestApiCapability(this.descriptor, {http.Client? client})
      : _clientOverride = client;

  final RestServiceDescriptor descriptor;
  final http.Client? _clientOverride;
  http.Client? _lazyClient;

  /// Lazily created so capability *registration* never touches the HTTP
  /// stack — the client is only built on first actual tool use.
  http.Client get _client => _clientOverride ?? (_lazyClient ??= http.Client());

  static const int defaultTimeoutSeconds = 30;
  static const int minTimeoutSeconds = 5;
  static const int maxTimeoutSeconds = 300;

  /// Tolerant timeout parsing for LLM-supplied args: accepts [num] directly
  /// or a numeric [String] (e.g. `"10"`); anything else is a user-input
  /// error ([FormatException]). Defaults to 30s, clamped to 5..300s.
  static int resolveTimeoutSeconds(Map<String, dynamic> args) {
    final raw = args['timeout_seconds'];
    double value;
    if (raw == null) {
      value = defaultTimeoutSeconds.toDouble();
    } else if (raw is num) {
      value = raw.toDouble();
    } else {
      final parsed = double.tryParse(raw.toString().trim());
      if (parsed == null) {
        throw FormatException(
          'Invalid timeout_seconds "$raw": expected a number.',
        );
      }
      value = parsed;
    }
    if (!value.isFinite) {
      throw FormatException(
        'Invalid timeout_seconds "$raw": expected a finite number.',
      );
    }
    return value.round().clamp(minTimeoutSeconds, maxTimeoutSeconds);
  }

  @override
  String get pluginName => descriptor.pluginName;

  @override
  List<NativePluginConfigField> get configFields => [
        if (descriptor.credentialKey.isNotEmpty)
          NativePluginConfigField(
            key: descriptor.credentialKey,
            label: descriptor.credentialLabel,
            secret: true,
          ),
        ...descriptor.extraConfig,
      ];

  @override
  List<NativePluginTool> get tools => [
        for (final def in descriptor.tools)
          NativePluginTool(
            name: def.name,
            description: def.description,
            inputSchema: {
              ...def.inputSchema,
              'properties': {
                ...((def.inputSchema['properties'] as Map?) ?? const {}),
                'timeout_seconds': {
                  'type': 'number',
                  'description':
                      'Request timeout in seconds (default 30, clamped 5..300).',
                },
              },
            },
          ),
      ];

  @override
  Future<void> configure(Map<String, String> values) =>
      NativePluginConfigStore.I.save(
        pluginName: pluginName,
        fields: configFields,
        values: values,
      );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    final def = _findTool(toolName);
    for (final key in def.required) {
      final value = args[key];
      if (value == null || value.toString().trim().isEmpty) {
        throw ArgumentError('Missing required argument: $key');
      }
    }
    final timeoutSeconds = resolveTimeoutSeconds(args);
    final stored = await NativePluginConfigStore.I.readAll(
      pluginName: pluginName,
      fields: configFields,
    );
    final secret = (stored[descriptor.credentialKey] ?? '').trim();

    // Configure-first gate: any declared credential must be present before
    // the tool runs. The message names the label/key but NEVER the value.
    if (descriptor.credentialKey.isNotEmpty && secret.isEmpty) {
      return _configureFirst(
        descriptor.credentialLabel,
        descriptor.credentialKey,
      );
    }
    String username = '';
    if (descriptor.auth == RestAuthKind.basic &&
        descriptor.authUsernameKey.isNotEmpty) {
      username = (stored[descriptor.authUsernameKey] ?? '').trim();
      if (username.isEmpty) {
        return _configureFirst(
          _labelFor(descriptor.authUsernameKey),
          descriptor.authUsernameKey,
        );
      }
    }

    final uri = _buildUri(def, args, stored, secret);
    final headers = _buildHeaders(stored, secret);
    final body = _buildBody(def, args, headers);
    final method = def.method.trim().toUpperCase();
    if (!const {'GET', 'POST', 'PUT', 'PATCH', 'DELETE'}.contains(method)) {
      throw ArgumentError(
        'Unknown HTTP method "${def.method}" for tool "$toolName": '
        'expected one of GET, POST, PUT, PATCH, DELETE.',
      );
    }
    http.Response response;
    try {
      final request = http.Request(method, uri);
      request.headers.addAll(headers);
      if (body != null) request.body = body;
      final streamed = await _client.send(request).timeout(
            Duration(seconds: timeoutSeconds),
          );
      response = await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw FormatException(
        'Request to $uri timed out after $timeoutSeconds seconds.',
      );
    } catch (e) {
      throw FormatException('HTTP request failed: $e');
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return _trimOutput(response.body);
    }
    // Non-2xx bodies pass through verbatim (they carry the API's own
    // error payload, e.g. Slack's {"ok":false,…}); the status line keeps
    // success/failure unambiguous.
    return _trimOutput('HTTP ${response.statusCode}\n${response.body}');
  }

  RestToolDef _findTool(String toolName) {
    for (final def in descriptor.tools) {
      if (def.name == toolName) return def;
    }
    throw ArgumentError(
      'Unknown tool: $toolName for plugin "${descriptor.pluginName}".',
    );
  }

  String _labelFor(String key) {
    for (final field in configFields) {
      if (field.key == key) return field.label;
    }
    return key;
  }

  String _configureFirst(String label, String key) =>
      'Configure $label first: open the Configure sheet for '
      '"${descriptor.pluginName}" and save "$key".';

  /// Substitutes `{name}` from tool args first, then stored config.
  String _substitute(
    String template,
    Map<String, dynamic> args,
    Map<String, String> stored,
  ) {
    return template.replaceAllMapped(RegExp(r'\{([^}]+)\}'), (match) {
      final key = match.group(1)!;
      final fromArgs = args[key];
      if (fromArgs != null && fromArgs.toString().isNotEmpty) {
        return Uri.encodeComponent(fromArgs.toString());
      }
      final fromStored = (stored[key] ?? '').trim();
      if (fromStored.isNotEmpty) return Uri.encodeComponent(fromStored);
      throw ArgumentError('Missing required argument: $key');
    });
  }

  Uri _buildUri(
    RestToolDef def,
    Map<String, dynamic> args,
    Map<String, String> stored,
    String secret,
  ) {
    final base = _substitute(
      descriptor.baseUrl.replaceAll(RegExp(r'/+$'), ''),
      args,
      stored,
    );
    final path = _substitute(def.path, args, stored);
    var uri = Uri.parse('$base$path');
    final query = <String, String>{...uri.queryParameters};
    if (descriptor.auth == RestAuthKind.queryKey) {
      query[descriptor.authQueryKey] = secret;
    }
    for (final name in def.queryArgs) {
      final value = args[name];
      if (value == null || value.toString().isEmpty) continue;
      query[name] = value.toString();
    }
    if (query.isNotEmpty) {
      uri = uri.replace(
        queryParameters: query,
      );
    }
    return uri;
  }

  Map<String, String> _buildHeaders(
    Map<String, String> stored,
    String secret,
  ) {
    final headers = <String, String>{};
    switch (descriptor.auth) {
      case RestAuthKind.none:
      case RestAuthKind.queryKey:
        break;
      case RestAuthKind.bearerHeader:
        headers[descriptor.authHeader ?? 'Authorization'] =
            '${descriptor.authPrefix}$secret';
        break;
      case RestAuthKind.apiKeyHeader:
        headers[descriptor.authHeader ?? 'X-Api-Key'] =
            '${descriptor.authPrefix}$secret';
        break;
      case RestAuthKind.basic:
        // The configure-first gate above guarantees the username is stored
        // when [authUsernameKey] names one.
        final username =
            (stored[descriptor.authUsernameKey] ?? '').trim();
        headers['Authorization'] = _basicAuthValue(username, secret);
        break;
    }
    return headers;
  }

  String? _buildBody(
    RestToolDef def,
    Map<String, dynamic> args,
    Map<String, String> headers,
  ) {
    final method = def.method.trim().toUpperCase();
    if (method == 'GET' || method == 'HEAD') return null;
    if (def.jsonBodyArg != null && def.formBodyArg != null) {
      throw ArgumentError(
        'Tool "${def.name}" declares both jsonBodyArg and formBodyArg.',
      );
    }
    if (def.jsonBodyArg != null) {
      headers['content-type'] = 'application/json';
      return jsonEncode(_bodyJson(args[def.jsonBodyArg], def.jsonBodyArg!));
    }
    if (def.formBodyArg != null) {
      headers['content-type'] = 'application/x-www-form-urlencoded';
      return _formEncode(_bodyForm(args[def.formBodyArg], def.formBodyArg!));
    }
    return null;
  }
}

/// Builds the basic-auth header once the configure-first gate has resolved
/// the username. Kept as a helper so [RestApiCapability] stays small.
String _basicAuthValue(String username, String secret) =>
    'Basic ${base64Encode(utf8.encode('$username:$secret'))}';

dynamic _bodyJson(dynamic raw, String key) {
  if (raw == null) return {};
  if (raw is Map || raw is List) return raw;
  if (raw is String) {
    if (raw.trim().isEmpty) return {};
    try {
      return jsonDecode(raw);
    } on FormatException catch (e) {
      throw FormatException('Invalid $key JSON: ${e.message}');
    }
  }
  throw FormatException(
    'Invalid $key: expected a JSON object.',
  );
}

Map<String, dynamic> _bodyForm(dynamic raw, String key) {
  if (raw == null) return {};
  if (raw is Map) return Map<String, dynamic>.from(raw);
  throw FormatException('Invalid $key: expected an object of form fields.');
}

/// Flattens one level of nesting with Stripe-style bracket notation
/// (`metadata[key]`, `items[0]`) and percent-encodes the pairs.
String _formEncode(Map<String, dynamic> fields) {
  final flat = <String, String>{};
  void add(String prefix, dynamic value) {
    if (value is Map) {
      for (final entry in value.entries) {
        add('$prefix[${entry.key}]', entry.value);
      }
    } else if (value is List) {
      for (var i = 0; i < value.length; i++) {
        add('$prefix[$i]', value[i]);
      }
    } else {
      flat[prefix] = value?.toString() ?? '';
    }
  }

  for (final entry in fields.entries) {
    add(entry.key.toString(), entry.value);
  }
  return flat.entries
      .map(
        (e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
      )
      .join('&');
}

/// Inline cap for a tool result handed to the model. Oversized output is
/// trimmed head+tail with the exact MCP omission notice (sibling NP3
/// convention).
String _trimOutput(String text) {
  const cap = 6000;
  if (text.length <= cap) return text;
  final head = text.substring(0, cap ~/ 2);
  final tail = text.substring(text.length - cap ~/ 2);
  final omitted = text.length - cap;
  return '$head\n\n[…$omitted characters omitted — ask again with a '
      'narrower query to see the middle…]\n\n$tail';
}

// ---------------------------------------------------------------------------
// SigV4 (S3 + generic AWS services)
// ---------------------------------------------------------------------------

/// Builds an AWS Signature Version 4 `Authorization` header value.
///
/// Pure Dart over `package:crypto`. [headers] maps header names (any case)
/// to values; every entry is signed. The caller must include the matching
/// `x-amz-date` header (formatted from [amzDate]) and pass the hex-encoded
/// SHA-256 of the payload as [payloadHash] (empty body =
/// `e3b0c44…b855`). [canonicalUri] is the raw path (`/` keeps slashes
/// unescaped, other segments are percent-encoded). [service] defaults to
/// `s3` (pass e.g. `iam` for the documentation test vector).
String s3Authorization({
  required String accessKeyId,
  required String secretAccessKey,
  required String region,
  String service = 's3',
  required String method,
  required String canonicalUri,
  Map<String, String> queryParameters = const {},
  Map<String, String> headers = const {},
  required String payloadHash,
  required DateTime amzDate,
}) {
  final utc = amzDate.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final dateStamp =
      '${utc.year}${two(utc.month)}${two(utc.day)}';
  final amzDateStr =
      '${dateStamp}T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';

  final path = canonicalUri.isEmpty ? '/' : canonicalUri;
  final encodedPath =
      path.split('/').map(_sigV4Encode).join('/');

  final sortedQuery = queryParameters.entries
      .map((e) => MapEntry(_sigV4Encode(e.key), _sigV4Encode(e.value)))
      .toList()
    ..sort((a, b) {
      final byKey = a.key.compareTo(b.key);
      return byKey != 0 ? byKey : a.value.compareTo(b.value);
    });
  final canonicalQuery =
      sortedQuery.map((e) => '${e.key}=${e.value}').join('&');

  final normalized = headers.entries
      .map((e) => MapEntry(
            e.key.trim().toLowerCase(),
            e.value.trim().replaceAll(RegExp(r'\s+'), ' '),
          ))
      .toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  final canonicalHeaders =
      normalized.map((e) => '${e.key}:${e.value}\n').join();
  final signedHeaders = normalized.map((e) => e.key).join(';');

  final canonicalRequest =
      '${method.trim().toUpperCase()}\n$encodedPath\n$canonicalQuery\n'
      '$canonicalHeaders\n$signedHeaders\n$payloadHash';
  final scope = '$dateStamp/$region/$service/aws4_request';
  final stringToSign =
      'AWS4-HMAC-SHA256\n$amzDateStr\n$scope\n${_sha256Hex(canonicalRequest)}';

  List<int> key = utf8.encode('AWS4$secretAccessKey');
  for (final data in [dateStamp, region, service, 'aws4_request']) {
    key = Hmac(sha256, key).convert(utf8.encode(data)).bytes;
  }
  final signature =
      Hmac(sha256, key).convert(utf8.encode(stringToSign)).toString();
  return 'AWS4-HMAC-SHA256 Credential=$accessKeyId/$scope, '
      'SignedHeaders=$signedHeaders, Signature=$signature';
}

String _sha256Hex(String data) => sha256.convert(utf8.encode(data)).toString();

/// RFC 3986 percent-encoding for SigV4 (unreserved marks stay bare,
/// everything else becomes uppercase `%XX` over UTF-8 bytes).
String _sigV4Encode(String input) {
  final out = StringBuffer();
  for (final byte in utf8.encode(input)) {
    final c = byte;
    final unreserved = (c >= 0x41 && c <= 0x5A) || // A-Z
        (c >= 0x61 && c <= 0x7A) || // a-z
        (c >= 0x30 && c <= 0x39) || // 0-9
        c == 0x2D || // -
        c == 0x5F || // _
        c == 0x2E || // .
        c == 0x7E; // ~
    if (unreserved) {
      out.writeCharCode(c);
    } else {
      out.write('%${c.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

// ---------------------------------------------------------------------------
// RESP (minimal Redis client)
// ---------------------------------------------------------------------------

/// Encodes a command as a RESP array of bulk strings. Lengths are UTF-8
/// byte counts.
String respEncode(List<String> args) {
  final out = StringBuffer('*${args.length}\r\n');
  for (final arg in args) {
    out.write('\$${utf8.encode(arg).length}\r\n');
    out.write(arg);
    out.write('\r\n');
  }
  return out.toString();
}

/// A Redis `-ERR …` reply surfaced as an exception.
class RespError implements Exception {
  const RespError(this.message);
  final String message;
  @override
  String toString() => 'RespError: $message';
}

/// Creates a connected [Socket]. Injectable so tests can count or fake
/// connections; defaults to a real `Socket.connect` with [timeout].
typedef RespSocketFactory = Future<Socket> Function(String host, int port);

/// Minimal RESP2 client (enough for GET/SET/DEL/KEYS/INCR/EXPIRE): opens one
/// persistent connection, pipelines safely via a reply queue, and decodes
/// simple strings, errors, integers, bulk strings, and arrays.
///
/// Replies decode to [String], [int], [List], or `null` (`$-1`/`*-1`);
/// error replies throw [RespError]. Connection failures propagate the
/// underlying [SocketException] so callers can report honest
/// unavailability messages.
class RespClient {
  RespClient({
    required this.host,
    required this.port,
    this.password,
    RespSocketFactory? socketFactory,
    this.timeout = const Duration(seconds: 10),
  }) : _socketFactory = socketFactory ??
            ((host, port) => Socket.connect(host, port, timeout: timeout));

  final String host;
  final int port;
  final String? password;
  final RespSocketFactory _socketFactory;
  final Duration timeout;

  Socket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  final List<int> _incoming = [];
  final Queue<Completer<dynamic>> _pending = Queue<Completer<dynamic>>();
  bool _authed = false;
  bool _closed = false;

  /// Sends one command and completes with its decoded reply.
  Future<dynamic> command(List<String> args) async {
    if (_closed) throw StateError('RespClient is closed.');
    final socket = await _ensureConnected();
    if (!_authed && password != null && password!.isNotEmpty) {
      final reply = await _roundTrip(socket, ['AUTH', password!]);
      if (reply != 'OK') throw RespError('Redis AUTH failed: $reply');
      _authed = true;
    }
    return _roundTrip(socket, args);
  }

  /// Closes the connection; pending commands fail fast.
  Future<void> close() async {
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _socket?.close();
    } catch (_) {
      // Already gone — closing is idempotent by contract.
    }
    _socket = null;
    final pending = _pending.toList();
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('RespClient is closed.'));
      }
    }
  }

  Future<Socket> _ensureConnected() async {
    final existing = _socket;
    if (existing != null) return existing;
    late Socket socket;
    try {
      socket = await _socketFactory(host, port).timeout(timeout);
    } on TimeoutException {
      throw TimeoutException(
        'Redis connect to $host:$port timed out after $timeout.',
      );
    }
    _socket = socket;
    _subscription = socket.listen(
      _onData,
      onError: _onSocketError,
      onDone: _onSocketDone,
      cancelOnError: false,
    );
    return socket;
  }

  Future<dynamic> _roundTrip(Socket socket, List<String> args) {
    final completer = Completer<dynamic>();
    _pending.add(completer);
    socket.add(utf8.encode(respEncode(args)));
    // Flush failures surface through the socket error handler.
    unawaited(socket.flush());
    return completer.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'Redis command ${args.isEmpty ? '' : args.first} '
        'timed out after $timeout.',
      ),
    );
  }

  void _onData(Uint8List chunk) {
    _incoming.addAll(chunk);
    while (_pending.isNotEmpty) {
      final parsed = _tryParseValue(_incoming, 0);
      if (parsed == null) return; // Need more bytes.
      _incoming.removeRange(0, parsed.next);
      final completer = _pending.removeFirst();
      if (parsed.value is _RespErr) {
        completer.completeError(
          RespError((parsed.value as _RespErr).message),
        );
      } else if (!completer.isCompleted) {
        completer.complete(parsed.value);
      }
    }
  }

  void _onSocketError(Object error) {
    _socket = null;
    final pending = _pending.toList();
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }

  void _onSocketDone() {
    _socket = null;
    final pending = _pending.toList();
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(
          const SocketException.closed(),
        );
      }
    }
  }
}

class _RespErr {
  const _RespErr(this.message);
  final String message;
}

class _ParsedResp {
  const _ParsedResp(this.value, this.next);
  final dynamic value;
  final int next;
}

/// Tries to parse one RESP2 value at [offset]; returns null when the
/// buffer holds an incomplete frame.
_ParsedResp? _tryParseValue(List<int> buffer, int offset) {
  final lineEnd = _findCrlf(buffer, offset);
  if (lineEnd < 0) return null;
  if (offset >= buffer.length) return null;
  final prefix = buffer[offset];
  final line = utf8.decode(
    buffer.sublist(offset + 1, lineEnd),
    allowMalformed: true,
  );
  switch (prefix) {
    case 0x2B: // +
      return _ParsedResp(line, lineEnd + 2);
    case 0x2D: // -
      return _ParsedResp(_RespErr(line), lineEnd + 2);
    case 0x3A: // :
      return _ParsedResp(int.parse(line), lineEnd + 2);
    case 0x24: // $
      final length = int.parse(line);
      if (length == -1) return _ParsedResp(null, lineEnd + 2);
      if (length < 0) throw const FormatException('Invalid RESP bulk length.');
      final start = lineEnd + 2;
      if (buffer.length < start + length + 2) return null;
      final value = utf8.decode(
        buffer.sublist(start, start + length),
        allowMalformed: true,
      );
      return _ParsedResp(value, start + length + 2);
    case 0x2A: // *
      final count = int.parse(line);
      if (count == -1) return _ParsedResp(null, lineEnd + 2);
      if (count < 0) throw const FormatException('Invalid RESP array length.');
      var cursor = lineEnd + 2;
      final items = <dynamic>[];
      for (var i = 0; i < count; i++) {
        final item = _tryParseValue(buffer, cursor);
        if (item == null) return null;
        items.add(item.value);
        cursor = item.next;
      }
      return _ParsedResp(items, cursor);
    default:
      throw FormatException(
        'Invalid RESP prefix "${String.fromCharCode(prefix)}".',
      );
  }
}

int _findCrlf(List<int> buffer, int from) {
  for (var i = from; i + 1 < buffer.length; i++) {
    if (buffer[i] == 0x0D && buffer[i + 1] == 0x0A) return i;
  }
  return -1;
}

// ---------------------------------------------------------------------------
// Obsidian vault files
// ---------------------------------------------------------------------------

/// Minimal file-backed helper for the Obsidian vault plugin (NP4 task 5
/// wraps it in a capability). All note paths are vault-relative (`a/b.md`);
/// any path resolving outside [rootPath] — `..` escapes or absolute paths —
/// throws [ArgumentError]. Missing notes throw [ArgumentError]; other I/O
/// failures propagate their [FileSystemException].
class VaultFiles {
  VaultFiles(String root) : _rootPath = _normalizeRoot(root);

  final String _rootPath;

  String get rootPath => _rootPath;

  static String _normalizeRoot(String root) {
    var path = Directory(root).absolute.path;
    while (path.length > 1 && path.endsWith(Platform.pathSeparator)) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }

  /// Vault-relative paths of every `.md` file, sorted, `/`-separated.
  Future<List<String>> listNotes() async {
    final found = <String>[];
    await for (final entity in Directory(_rootPath).list(recursive: true)) {
      if (entity is File && entity.path.toLowerCase().endsWith('.md')) {
        found.add(_relative(entity.path));
      }
    }
    found.sort();
    return found;
  }

  Future<String> readNote(String path) async {
    final file = _resolve(path);
    if (!file.existsSync()) {
      throw ArgumentError('Note not found: "$path".');
    }
    return file.readAsString();
  }

  /// Writes (creating parents) and reports the character count.
  Future<String> writeNote(String path, String text) async {
    final file = _resolve(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
    return 'Wrote ${text.length} characters to "$path".';
  }

  /// Appends to the note (creating it and parents when missing).
  Future<String> appendNote(String path, String text) async {
    final file = _resolve(path);
    file.parent.createSync(recursive: true);
    if (file.existsSync()) {
      file.writeAsStringSync(text, mode: FileMode.append);
    } else {
      file.writeAsStringSync(text);
    }
    return 'Appended ${text.length} characters to "$path" '
        '(${file.lengthSync()} total).';
  }

  /// Case-insensitive substring search over note bodies; returns sorted
  /// vault-relative paths of matching notes.
  Future<List<String>> searchNotes(String query) async {
    if (query.trim().isEmpty) {
      throw ArgumentError('Missing required argument: query');
    }
    final needle = query.toLowerCase();
    final hits = <String>[];
    for (final relative in await listNotes()) {
      final body = await readNote(relative);
      if (body.toLowerCase().contains(needle)) hits.add(relative);
    }
    return hits;
  }

  String _relative(String absolute) {
    final prefix = '$_rootPath${Platform.pathSeparator}';
    final stripped = absolute.startsWith(prefix)
        ? absolute.substring(prefix.length)
        : absolute;
    return stripped.replaceAll(Platform.pathSeparator, '/');
  }

  File _resolve(String relative) {
    if (relative.trim().isEmpty) {
      throw ArgumentError('Missing required argument: path');
    }
    if (relative.contains('\u0000')) {
      throw ArgumentError('Invalid note path: "$relative".');
    }
    final trimmed = relative.trim();
    if (trimmed.startsWith('/') ||
        trimmed.startsWith('\\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(trimmed)) {
      throw ArgumentError(
        'Note path must be vault-relative, got: "$relative".',
      );
    }
    final rootParts = _rootPath.split(Platform.pathSeparator);
    final stack = List<String>.from(rootParts);
    for (final segment in trimmed.split(RegExp(r'[\\/]+'))) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (stack.length <= rootParts.length) {
          throw ArgumentError(
            'Note path escapes the vault root: "$relative".',
          );
        }
        stack.removeLast();
      } else {
        stack.add(segment);
      }
    }
    if (stack.length == rootParts.length) {
      throw ArgumentError('Missing required argument: path');
    }
    return File(stack.join(Platform.pathSeparator));
  }
}
