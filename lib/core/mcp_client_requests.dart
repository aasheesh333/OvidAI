import 'dart:async';

import 'package:flutter/foundation.dart';

import 'diag.dart';

/// MCP client capabilities (master plan Phase 2 item 3).
///
/// MCP is bidirectional: besides answering our requests, a server may send
/// requests TO the client and notifications about long-running work. Ovid used
/// to drop every inbound message that carried an `id` (an early return in the
/// notification handler), so a server's `ping` timed out and `roots/list`,
/// `sampling/createMessage` and `elicitation/create` never got an answer.
///
/// This class owns the client side of the protocol, transport-agnostic:
///  * [initializeParams] — the advertised client capabilities and protocol
///    revision (`2025-06-18`);
///  * [handle] — one server→client request in, one JSON-RPC response out;
///  * [handleNotification] — `notifications/progress` and
///    `notifications/message` (server logging) are recorded per server.
///
/// The UI-facing parts are injected: [samplingApprover] asks the user before
/// any server may use their model, [sampler] runs the approved completion,
/// [elicitor] shows the elicitation sheet, [rootsProvider] lists workspace
/// roots. Each one missing degrades to the spec's refusal shape, never a hang.
class McpClientRequests extends ChangeNotifier {
  McpClientRequests._();

  static final McpClientRequests I = McpClientRequests._();

  /// The protocol revision Ovid speaks and advertises in `initialize`.
  static const protocolVersion = '2025-06-18';

  /// Client capabilities advertised in `initialize`. Roots are a snapshot of
  /// the session workspace; Ovid does not emit `roots/list_changed`, so it
  /// honestly advertises `listChanged: false`.
  static const Map<String, dynamic> clientCapabilities = {
    'roots': {'listChanged': false},
    'sampling': <String, dynamic>{},
    'elicitation': <String, dynamic>{},
  };

  /// The `initialize` request params every transport sends.
  static Map<String, dynamic> initializeParams() => {
    'protocolVersion': protocolVersion,
    'capabilities': clientCapabilities,
    'clientInfo': {'name': 'ovid-ai', 'version': '1.0.0'},
  };

  /// JSON-RPC error codes used below.
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;

  /// MCP spec: "User rejected sampling request".
  static const int userRejected = -1;

  List<McpRoot> Function(String serverName)? rootsProvider;
  Future<bool> Function(McpSamplingRequest request)? samplingApprover;
  Future<Map<String, dynamic>?> Function(McpSamplingRequest request)? sampler;
  Future<McpElicitationResponse> Function(McpElicitationRequest request)?
  elicitor;

  /// True when [message] is a server→client REQUEST (has both `method` and
  /// `id`). Such a message must never be mistaken for the response to one of
  /// our own requests that happens to share the id.
  static bool isServerRequest(Map<String, dynamic> message) =>
      message['method'] is String && message.containsKey('id');

  /// Answer one server→client request. Always returns a complete JSON-RPC
  /// response object (`result` or `error`), never throws.
  Future<Map<String, dynamic>> handle(
    String serverName,
    Map<String, dynamic> request,
  ) async {
    final id = request['id'];
    final method = request['method'];
    final rawParams = request['params'];
    final params = rawParams is Map
        ? rawParams.cast<String, dynamic>()
        : const <String, dynamic>{};
    Map<String, dynamic> ok(Map<String, dynamic> result) => {
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    };
    Map<String, dynamic> err(int code, String message) => {
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    };
    try {
      switch (method) {
        case 'ping':
          return ok(const {});
        case 'roots/list':
          final roots = rootsProvider?.call(serverName) ?? const <McpRoot>[];
          return ok({
            'roots': [for (final r in roots) r.toJson()],
          });
        case 'sampling/createMessage':
          final req = McpSamplingRequest.parse(serverName, params);
          if (req == null) {
            return err(invalidParams, 'sampling/createMessage: invalid params');
          }
          final approve = samplingApprover;
          final run = sampler;
          if (approve == null || run == null) {
            return err(userRejected, 'User rejected sampling request');
          }
          if (!await approve(req)) {
            return err(userRejected, 'User rejected sampling request');
          }
          final result = await run(req);
          if (result == null) {
            return err(internalError, 'sampling failed');
          }
          return ok(result);
        case 'elicitation/create':
          final req = McpElicitationRequest.parse(serverName, params);
          if (req == null) {
            return err(invalidParams, 'elicitation/create: invalid params');
          }
          final ask = elicitor;
          if (ask == null) return ok(const {'action': 'cancel'});
          final response = await ask(req);
          return ok(response.validated(req).toJson());
        default:
          return err(methodNotFound, 'Method not found: $method');
      }
    } catch (e) {
      Diag.swallow('mcp_client_requests', e);
      return err(internalError, 'client error handling $method');
    }
  }

  // ── Notifications ────────────────────────────────────────────────────

  static const int _maxLogsPerServer = 200;
  final Map<String, List<McpLogEntry>> _logs = {};
  final Map<String, Map<String, McpProgress>> _progress = {};

  /// Record a `notifications/progress` or `notifications/message`. Returns
  /// true when the notification was one of those.
  bool handleNotification(String serverName, Map<String, dynamic> message) {
    final method = message['method'];
    final raw = message['params'];
    final params = raw is Map
        ? raw.cast<String, dynamic>()
        : const <String, dynamic>{};
    switch (method) {
      case 'notifications/progress':
        final token = params['progressToken'];
        final progress = params['progress'];
        if (token == null || progress is! num) return true;
        (_progress[serverName] ??= {})['$token'] = McpProgress(
          server: serverName,
          token: '$token',
          progress: progress.toDouble(),
          total: (params['total'] as num?)?.toDouble(),
          message: params['message'] as String?,
        );
        notifyListeners();
        return true;
      case 'notifications/message':
        final list = _logs[serverName] ??= [];
        list.add(
          McpLogEntry(
            server: serverName,
            level: params['level']?.toString() ?? 'info',
            logger: params['logger']?.toString(),
            data: params['data'],
            at: DateTime.now(),
          ),
        );
        if (list.length > _maxLogsPerServer) {
          list.removeRange(0, list.length - _maxLogsPerServer);
        }
        notifyListeners();
        return true;
    }
    return false;
  }

  /// Server log lines (oldest first, bounded).
  List<McpLogEntry> logsFor(String serverName) =>
      List.unmodifiable(_logs[serverName] ?? const []);

  /// Latest progress for [token] on [serverName].
  McpProgress? progressFor(String serverName, String token) =>
      _progress[serverName]?[token];

  @visibleForTesting
  void resetForTest() {
    rootsProvider = null;
    samplingApprover = null;
    sampler = null;
    elicitor = null;
    _logs.clear();
    _progress.clear();
  }
}

/// One `roots/list` entry.
class McpRoot {
  const McpRoot(this.uri, {this.name});
  final String uri;
  final String? name;

  /// A filesystem directory as a `file://` root.
  factory McpRoot.directory(String path, {String? name}) =>
      McpRoot(Uri.directory(path).toString(), name: name);

  Map<String, dynamic> toJson() => {'uri': uri, 'name': ?name};
}

/// A parsed `sampling/createMessage` request.
class McpSamplingRequest {
  const McpSamplingRequest({
    required this.server,
    required this.messages,
    required this.maxTokens,
    this.systemPrompt,
    this.temperature,
    this.modelHints = const [],
  });

  final String server;

  /// `[{role, text}]` — text content only; non-text parts are summarised.
  final List<({String role, String text})> messages;
  final int maxTokens;
  final String? systemPrompt;
  final double? temperature;
  final List<String> modelHints;

  static McpSamplingRequest? parse(String server, Map<String, dynamic> p) {
    final raw = p['messages'];
    if (raw is! List || raw.isEmpty) return null;
    final messages = <({String role, String text})>[];
    for (final m in raw) {
      if (m is! Map) return null;
      final role = m['role'];
      if (role != 'user' && role != 'assistant') return null;
      final content = m['content'];
      String text;
      if (content is Map && content['type'] == 'text') {
        text = '${content['text'] ?? ''}';
      } else if (content is Map) {
        text = '[${content['type'] ?? 'unknown'} content omitted]';
      } else if (content is List) {
        text = content
            .whereType<Map>()
            .map(
              (c) => c['type'] == 'text'
                  ? '${c['text'] ?? ''}'
                  : '[${c['type']} content omitted]',
            )
            .join('\n');
      } else {
        return null;
      }
      messages.add((role: role as String, text: text));
    }
    final maxTokens = p['maxTokens'];
    final prefs = p['modelPreferences'];
    final hints = prefs is Map && prefs['hints'] is List
        ? [
            for (final h in prefs['hints'] as List)
              if (h is Map && h['name'] is String) h['name'] as String,
          ]
        : const <String>[];
    return McpSamplingRequest(
      server: server,
      messages: messages,
      maxTokens: maxTokens is num ? maxTokens.toInt() : 1024,
      systemPrompt: p['systemPrompt'] as String?,
      temperature: (p['temperature'] as num?)?.toDouble(),
      modelHints: hints,
    );
  }

  /// What the approval prompt shows the user.
  String get preview {
    final b = StringBuffer();
    if ((systemPrompt ?? '').isNotEmpty) b.writeln('System: $systemPrompt');
    for (final m in messages) {
      b.writeln('${m.role}: ${m.text}');
    }
    final s = b.toString().trim();
    return s.length > 1500 ? '${s.substring(0, 1500)}…' : s;
  }
}

/// A parsed `elicitation/create` request (flat primitive schema per spec).
class McpElicitationRequest {
  const McpElicitationRequest({
    required this.server,
    required this.message,
    required this.fields,
    required this.required,
  });

  final String server;
  final String message;
  final List<McpElicitationField> fields;
  final Set<String> required;

  static McpElicitationRequest? parse(String server, Map<String, dynamic> p) {
    final message = p['message'];
    final schema = p['requestedSchema'];
    if (message is! String || schema is! Map) return null;
    if (schema['type'] != null && schema['type'] != 'object') return null;
    final props = schema['properties'];
    final fields = <McpElicitationField>[];
    if (props is Map) {
      for (final e in props.entries) {
        final v = e.value;
        if (v is! Map) return null;
        final type = v['type'];
        if (!const {'string', 'number', 'integer', 'boolean'}.contains(type)) {
          // The spec restricts elicitation to flat primitive properties.
          return null;
        }
        final enumValues = v['enum'];
        fields.add(
          McpElicitationField(
            name: '${e.key}',
            type: type as String,
            title: v['title'] as String?,
            description: v['description'] as String?,
            enumValues: enumValues is List
                ? [for (final x in enumValues) '$x']
                : const [],
            defaultValue: v['default'],
          ),
        );
      }
    }
    final req = schema['required'];
    return McpElicitationRequest(
      server: server,
      message: message,
      fields: fields,
      required: req is List ? {for (final r in req) '$r'} : const {},
    );
  }
}

class McpElicitationField {
  const McpElicitationField({
    required this.name,
    required this.type,
    this.title,
    this.description,
    this.enumValues = const [],
    this.defaultValue,
  });

  final String name;

  /// `string` | `number` | `integer` | `boolean`.
  final String type;
  final String? title;
  final String? description;
  final List<String> enumValues;
  final Object? defaultValue;

  String get label => (title ?? '').isNotEmpty ? title! : name;
}

/// The user's answer to an elicitation: `accept` (with [content]), `decline`
/// or `cancel`.
class McpElicitationResponse {
  const McpElicitationResponse.accept(this.content) : action = 'accept';
  const McpElicitationResponse.decline() : action = 'decline', content = null;
  const McpElicitationResponse.cancel() : action = 'cancel', content = null;

  final String action;
  final Map<String, dynamic>? content;

  /// Coerce [content] to the requested types; an accept missing a required
  /// field degrades to `cancel` rather than sending the server bad data.
  McpElicitationResponse validated(McpElicitationRequest req) {
    if (action != 'accept') return this;
    final out = <String, dynamic>{};
    for (final f in req.fields) {
      final v = content?[f.name];
      if (v == null || (v is String && v.isEmpty && f.type != 'string')) {
        if (req.required.contains(f.name)) {
          return const McpElicitationResponse.cancel();
        }
        continue;
      }
      final coerced = switch (f.type) {
        'number' => v is num ? v : num.tryParse('$v'),
        'integer' => v is int ? v : int.tryParse('$v'),
        'boolean' => v is bool ? v : '$v' == 'true',
        _ => '$v',
      };
      if (coerced == null) {
        if (req.required.contains(f.name)) {
          return const McpElicitationResponse.cancel();
        }
        continue;
      }
      if (f.enumValues.isNotEmpty && !f.enumValues.contains('$coerced')) {
        return const McpElicitationResponse.cancel();
      }
      out[f.name] = coerced;
    }
    return McpElicitationResponse.accept(out);
  }

  Map<String, dynamic> toJson() => {
    'action': action,
    if (action == 'accept') 'content': content ?? const <String, dynamic>{},
  };
}

class McpLogEntry {
  const McpLogEntry({
    required this.server,
    required this.level,
    required this.data,
    required this.at,
    this.logger,
  });

  final String server;
  final String level;
  final String? logger;
  final Object? data;
  final DateTime at;
}

class McpProgress {
  const McpProgress({
    required this.server,
    required this.token,
    required this.progress,
    this.total,
    this.message,
  });

  final String server;
  final String token;
  final double progress;
  final double? total;
  final String? message;
}
