import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/prompt_framework.dart';
import 'package:ovid_ai/core/native_plugins/rest_engine.dart';

/// AI, media & productivity integrations batch (NP4 Task 7, spec §4.5):
/// declarative [RestServiceDescriptor]s and capabilities for:
/// - OpenAI DALL·E MCP (exact middle-dot name)
/// - ElevenLabs MCP
/// - Notion Sync
/// - Google Drive MCP
/// - Stripe MCP
/// - YouTube Summarizer
/// - LangChain MCP
/// - AutoGPT Bridge
///
/// Registered via [registerAiMedia()] (wired into `registerAllNativePlugins`).

const List<RestServiceDescriptor> aiMediaDescriptors = [
  // 1. OpenAI DALL·E MCP
  RestServiceDescriptor(
    pluginName: 'OpenAI DALL·E MCP',
    baseUrl: 'https://api.openai.com/v1',
    auth: RestAuthKind.bearerHeader,
    authPrefix: 'Bearer ',
    credentialKey: 'openai_api_key',
    credentialLabel: 'OpenAI API key',
    tools: [
      RestToolDef(
        name: 'generate_image',
        description: 'Generate an image using DALL·E and return the image URL.',
        method: 'POST',
        path: '/images/generations',
        required: ['prompt'],
        jsonBodyArg: 'body',
        inputSchema: {
          'type': 'object',
          'properties': {
            'prompt': {'type': 'string'},
            'size': {'type': 'string', 'default': '1024x1024'},
          },
          'required': ['prompt'],
        },
      ),
    ],
  ),

  // 2. ElevenLabs MCP
  RestServiceDescriptor(
    pluginName: 'ElevenLabs MCP',
    baseUrl: 'https://api.elevenlabs.io/v1',
    auth: RestAuthKind.apiKeyHeader,
    authHeader: 'xi-api-key',
    credentialKey: 'api_key',
    credentialLabel: 'ElevenLabs API key',
    tools: [
      RestToolDef(
        name: 'list_voices',
        description: 'List available ElevenLabs voices.',
        method: 'GET',
        path: '/voices',
        inputSchema: {'type': 'object', 'properties': {}},
      ),
      RestToolDef(
        name: 'speak',
        description:
            'Synthesize speech using ElevenLabs TTS (capped at 2000 chars; returns base64 MP3 and byte count).',
        method: 'POST',
        path: '/text-to-speech/{voice_id}',
        required: ['text'],
        jsonBodyArg: 'body',
        inputSchema: {
          'type': 'object',
          'properties': {
            'text': {'type': 'string'},
            'voice_id': {'type': 'string', 'default': '21m00Tcm4TlvDq8ikWAM'},
          },
          'required': ['text'],
        },
      ),
    ],
  ),

  // 3. Notion Sync
  RestServiceDescriptor(
    pluginName: 'Notion Sync',
    baseUrl: 'https://api.notion.com/v1',
    auth: RestAuthKind.bearerHeader,
    authPrefix: 'Bearer ',
    credentialKey: 'api_key',
    credentialLabel: 'Notion API key',
    tools: [
      RestToolDef(
        name: 'search',
        description: 'Search Notion pages and databases.',
        method: 'POST',
        path: '/search',
        jsonBodyArg: 'body',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {'type': 'string'},
          },
        },
      ),
      RestToolDef(
        name: 'query_database',
        description: 'Query a Notion database.',
        method: 'POST',
        path: '/databases/{db_id}/query',
        required: ['db_id'],
        jsonBodyArg: 'body',
        inputSchema: {
          'type': 'object',
          'properties': {
            'db_id': {'type': 'string'},
            'filter_json': {'type': 'string'},
          },
          'required': ['db_id'],
        },
      ),
      RestToolDef(
        name: 'create_page',
        description: 'Create a new Notion page.',
        method: 'POST',
        path: '/pages',
        required: ['parent_id', 'title'],
        jsonBodyArg: 'body',
        inputSchema: {
          'type': 'object',
          'properties': {
            'parent_id': {'type': 'string'},
            'title': {'type': 'string'},
            'text': {'type': 'string'},
          },
          'required': ['parent_id', 'title'],
        },
      ),
      RestToolDef(
        name: 'get_page',
        description: 'Get a Notion page by id.',
        method: 'GET',
        path: '/pages/{id}',
        required: ['id'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
          },
          'required': ['id'],
        },
      ),
    ],
  ),

  // 4. Google Drive MCP
  RestServiceDescriptor(
    pluginName: 'Google Drive MCP',
    baseUrl: 'https://www.googleapis.com/drive/v3',
    auth: RestAuthKind.bearerHeader,
    authPrefix: 'Bearer ',
    credentialKey: 'access_token',
    credentialLabel: 'Google OAuth access token',
    tools: [
      RestToolDef(
        name: 'search',
        description: 'Search Google Drive files.',
        method: 'GET',
        path: '/files',
        queryArgs: ['q', 'pageSize'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {'type': 'string'},
            'limit': {'type': 'integer', 'default': 20},
          },
        },
      ),
      RestToolDef(
        name: 'get_file',
        description: 'Get Google Drive file metadata by id.',
        method: 'GET',
        path: '/files/{id}',
        required: ['id'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
          },
          'required': ['id'],
        },
      ),
      RestToolDef(
        name: 'download_text',
        description:
            'Download text content of a Google Drive file (or export Google Docs to plain text).',
        method: 'GET',
        path: '/files/{id}',
        required: ['id'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
          },
          'required': ['id'],
        },
      ),
      RestToolDef(
        name: 'upload_text',
        description: 'Upload a text file to Google Drive (multipart upload).',
        method: 'POST',
        path: '/files',
        required: ['name', 'text'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'text': {'type': 'string'},
            'folder_id': {'type': 'string'},
          },
          'required': ['name', 'text'],
        },
      ),
    ],
  ),

  // 5. Stripe MCP
  RestServiceDescriptor(
    pluginName: 'Stripe MCP',
    baseUrl: 'https://api.stripe.com/v1',
    auth: RestAuthKind.bearerHeader,
    authPrefix: 'Bearer ',
    credentialKey: 'secret_key',
    credentialLabel: 'Stripe secret key',
    tools: [
      RestToolDef(
        name: 'list_customers',
        description: 'List Stripe customers.',
        method: 'GET',
        path: '/customers',
        queryArgs: ['limit'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'limit': {'type': 'integer', 'default': 10},
          },
        },
      ),
      RestToolDef(
        name: 'list_invoices',
        description: 'List Stripe invoices.',
        method: 'GET',
        path: '/invoices',
        queryArgs: ['limit'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'limit': {'type': 'integer', 'default': 10},
          },
        },
      ),
      RestToolDef(
        name: 'list_charges',
        description: 'List Stripe charges.',
        method: 'GET',
        path: '/charges',
        queryArgs: ['limit'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'limit': {'type': 'integer', 'default': 10},
          },
        },
      ),
      RestToolDef(
        name: 'create_invoice',
        description: 'Create a Stripe invoice.',
        method: 'POST',
        path: '/invoices',
        required: ['customer_id'],
        formBodyArg: 'body',
        inputSchema: {
          'type': 'object',
          'properties': {
            'customer_id': {'type': 'string'},
            'description': {'type': 'string'},
            'amount_cents': {'type': 'integer'},
            'currency': {'type': 'string', 'default': 'usd'},
          },
          'required': ['customer_id'],
        },
      ),
    ],
  ),

  // 6. YouTube Summarizer
  RestServiceDescriptor(
    pluginName: 'YouTube Summarizer',
    baseUrl: 'https://www.youtube.com',
    auth: RestAuthKind.none,
    tools: [
      RestToolDef(
        name: 'get_details',
        description:
            'Fetch YouTube video details (title, author, description). Honest about captions: summarizes metadata.',
        method: 'GET',
        path: '/oembed',
        required: ['url'],
        queryArgs: ['url', 'format'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'url': {'type': 'string'},
          },
          'required': ['url'],
        },
      ),
    ],
  ),
];

// Helper base class
abstract class _AiMediaCapability implements NativePluginCapability {
  _AiMediaCapability(this.descriptor, {http.Client? client})
      : _clientOverride = client;

  final RestServiceDescriptor descriptor;
  final http.Client? _clientOverride;
  http.Client? _lazyClient;

  http.Client get client =>
      _clientOverride ?? (_lazyClient ??= http.Client());

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
  List<NativePluginTool> get tools => descriptor.tools.map((def) {
        return NativePluginTool(
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
        );
      }).toList();

  @override
  Future<void> configure(Map<String, String> values) =>
      NativePluginConfigStore.I.save(
        pluginName: pluginName,
        fields: configFields,
        values: values,
      );

  Future<String?> readConfig(String key) async {
    final stored = await NativePluginConfigStore.I.readAll(
      pluginName: pluginName,
      fields: configFields,
    );
    return stored[key];
  }

  String missingCredError([String? customKey, String? customLabel]) {
    final key = customKey ?? descriptor.credentialKey;
    final label = customLabel ?? descriptor.credentialLabel;
    return 'Configure $label first: open the Configure sheet for '
        '"${descriptor.pluginName}" and save "$key".';
  }
}

// ---------------------------------------------------------------------------
// OpenAI DALL·E MCP
// ---------------------------------------------------------------------------
class DalleCapability extends _AiMediaCapability {
  DalleCapability({super.client})
      : super(
          aiMediaDescriptors
              .firstWhere((d) => d.pluginName == 'OpenAI DALL·E MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    if (toolName != 'generate_image') {
      throw ArgumentError('Unknown tool: $toolName for plugin "$pluginName".');
    }
    final apiKey = await readConfig(descriptor.credentialKey);
    if (apiKey == null || apiKey.trim().isEmpty) return missingCredError();

    final prompt = args['prompt']?.toString().trim();
    if (prompt == null || prompt.isEmpty) {
      throw ArgumentError('Missing required argument: prompt');
    }
    final size = args['size']?.toString().trim() ?? '1024x1024';
    final timeoutSeconds = RestApiCapability.resolveTimeoutSeconds(args);

    final reqBody = jsonEncode({
      'prompt': prompt,
      'size': size,
      'n': 1,
    });

    final uri = Uri.parse('${descriptor.baseUrl}/images/generations');
    final req = http.Request('POST', uri);
    req.headers['Authorization'] = 'Bearer ${apiKey.trim()}';
    req.headers['Content-Type'] = 'application/json';
    req.body = reqBody;

    try {
      final streamed = await client.send(req).timeout(
            Duration(seconds: timeoutSeconds),
          );
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        try {
          final decoded = jsonDecode(resp.body);
          if (decoded is Map && decoded['data'] is List && (decoded['data'] as List).isNotEmpty) {
            final first = (decoded['data'] as List).first;
            if (first is Map && first['url'] != null) {
              return 'Image URL: ${first['url']}';
            }
          }
        } catch (_) {}
        return resp.body;
      }
      return 'HTTP ${resp.statusCode}\n${resp.body}';
    } on TimeoutException {
      throw FormatException(
        'Request to $uri timed out after $timeoutSeconds seconds.',
      );
    } catch (e) {
      throw FormatException('HTTP request failed: $e');
    }
  }
}

// ---------------------------------------------------------------------------
// ElevenLabs MCP
// ---------------------------------------------------------------------------
class ElevenLabsCapability extends _AiMediaCapability {
  ElevenLabsCapability({super.client})
      : super(
          aiMediaDescriptors
              .firstWhere((d) => d.pluginName == 'ElevenLabs MCP'),
        );

  static const int maxInputChars = 2000;

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    final apiKey = await readConfig(descriptor.credentialKey);
    if (apiKey == null || apiKey.trim().isEmpty) return missingCredError();

    final timeoutSeconds = RestApiCapability.resolveTimeoutSeconds(args);

    if (toolName == 'list_voices') {
      final uri = Uri.parse('${descriptor.baseUrl}/voices');
      final req = http.Request('GET', uri);
      req.headers['xi-api-key'] = apiKey.trim();
      try {
        final streamed = await client.send(req).timeout(
              Duration(seconds: timeoutSeconds),
            );
        final resp = await http.Response.fromStream(streamed);
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          return resp.body;
        }
        return 'HTTP ${resp.statusCode}\n${resp.body}';
      } on TimeoutException {
        throw FormatException(
          'Request to $uri timed out after $timeoutSeconds seconds.',
        );
      } catch (e) {
        throw FormatException('HTTP request failed: $e');
      }
    }

    if (toolName == 'speak') {
      final textRaw = args['text']?.toString().trim() ?? '';
      if (textRaw.isEmpty) {
        throw ArgumentError('Missing required argument: text');
      }
      if (textRaw.length > maxInputChars) {
        throw ArgumentError(
          'Text length (${textRaw.length}) exceeds the maximum allowed limit of $maxInputChars characters.',
        );
      }
      final voiceId = (args['voice_id']?.toString().trim().isNotEmpty ?? false)
          ? args['voice_id'].toString().trim()
          : '21m00Tcm4TlvDq8ikWAM';

      final uri = Uri.parse('${descriptor.baseUrl}/text-to-speech/$voiceId');
      final req = http.Request('POST', uri);
      req.headers['xi-api-key'] = apiKey.trim();
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode({'text': textRaw});

      try {
        final streamed = await client.send(req).timeout(
              Duration(seconds: timeoutSeconds),
            );
        final resp = await http.Response.fromStream(streamed);
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          final bytes = resp.bodyBytes;
          final b64 = base64Encode(bytes);
          return 'Synthesized ${bytes.length} bytes of audio (format: audio/mpeg).\nBase64: $b64';
        }
        return 'HTTP ${resp.statusCode}\n${resp.body}';
      } on TimeoutException {
        throw FormatException(
          'Request to $uri timed out after $timeoutSeconds seconds.',
        );
      } catch (e) {
        throw FormatException('HTTP request failed: $e');
      }
    }

    throw ArgumentError('Unknown tool: $toolName for plugin "$pluginName".');
  }
}

// ---------------------------------------------------------------------------
// Notion Sync
// ---------------------------------------------------------------------------
class NotionSyncCapability extends _AiMediaCapability {
  NotionSyncCapability({super.client})
      : super(
          aiMediaDescriptors
              .firstWhere((d) => d.pluginName == 'Notion Sync'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    final apiKey = await readConfig(descriptor.credentialKey);
    if (apiKey == null || apiKey.trim().isEmpty) return missingCredError();

    final timeoutSeconds = RestApiCapability.resolveTimeoutSeconds(args);

    Uri uri;
    String method;
    String? body;

    switch (toolName) {
      case 'search':
        uri = Uri.parse('${descriptor.baseUrl}/search');
        method = 'POST';
        final q = args['query']?.toString();
        body = jsonEncode({
          if (q != null && q.isNotEmpty) 'query': q,
        });
        break;

      case 'query_database':
        final dbId = args['db_id']?.toString().trim() ?? '';
        if (dbId.isEmpty) throw ArgumentError('Missing required argument: db_id');
        uri = Uri.parse('${descriptor.baseUrl}/databases/$dbId/query');
        method = 'POST';
        final filterJson = args['filter_json'];
        if (filterJson is Map) {
          body = jsonEncode(filterJson);
        } else if (filterJson is String && filterJson.trim().isNotEmpty) {
          try {
            body = jsonEncode(jsonDecode(filterJson));
          } catch (_) {
            body = '{}';
          }
        } else {
          body = '{}';
        }
        break;

      case 'create_page':
        final parentId = args['parent_id']?.toString().trim() ?? '';
        if (parentId.isEmpty) throw ArgumentError('Missing required argument: parent_id');
        final title = args['title']?.toString().trim() ?? '';
        if (title.isEmpty) throw ArgumentError('Missing required argument: title');
        final text = args['text']?.toString() ?? '';

        uri = Uri.parse('${descriptor.baseUrl}/pages');
        method = 'POST';
        body = jsonEncode({
          'parent': {'database_id': parentId},
          'properties': {
            'title': {
              'title': [
                {
                  'text': {'content': title}
                }
              ]
            }
          },
          if (text.isNotEmpty)
            'children': [
              {
                'object': 'block',
                'type': 'paragraph',
                'paragraph': {
                  'rich_text': [
                    {
                      'type': 'text',
                      'text': {'content': text}
                    }
                  ]
                }
              }
            ]
        });
        break;

      case 'get_page':
        final id = args['id']?.toString().trim() ?? '';
        if (id.isEmpty) throw ArgumentError('Missing required argument: id');
        uri = Uri.parse('${descriptor.baseUrl}/pages/$id');
        method = 'GET';
        break;

      default:
        throw ArgumentError('Unknown tool: $toolName for plugin "$pluginName".');
    }

    final req = http.Request(method, uri);
    req.headers['Authorization'] = 'Bearer ${apiKey.trim()}';
    req.headers['Notion-Version'] = '2022-06-28';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = body;
    }

    try {
      final streamed = await client.send(req).timeout(
            Duration(seconds: timeoutSeconds),
          );
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return resp.body;
      }
      return 'HTTP ${resp.statusCode}\n${resp.body}';
    } on TimeoutException {
      throw FormatException(
        'Request to $uri timed out after $timeoutSeconds seconds.',
      );
    } catch (e) {
      throw FormatException('HTTP request failed: $e');
    }
  }
}

// ---------------------------------------------------------------------------
// Google Drive MCP
// ---------------------------------------------------------------------------
class GoogleDriveCapability extends _AiMediaCapability {
  GoogleDriveCapability({super.client})
      : super(
          aiMediaDescriptors
              .firstWhere((d) => d.pluginName == 'Google Drive MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    final token = await readConfig(descriptor.credentialKey);
    if (token == null || token.trim().isEmpty) return missingCredError();

    final timeoutSeconds = RestApiCapability.resolveTimeoutSeconds(args);

    if (toolName == 'search') {
      final query = args['query']?.toString();
      final limit = args['limit']?.toString() ?? '20';
      final params = <String, String>{
        'pageSize': limit,
        if (query != null && query.isNotEmpty) 'q': query,
      };
      final uri = Uri.parse('${descriptor.baseUrl}/files').replace(queryParameters: params);
      return _sendSimple('GET', uri, token, timeoutSeconds);
    }

    if (toolName == 'get_file') {
      final id = args['id']?.toString().trim() ?? '';
      if (id.isEmpty) throw ArgumentError('Missing required argument: id');
      final uri = Uri.parse('${descriptor.baseUrl}/files/$id?fields=*');
      return _sendSimple('GET', uri, token, timeoutSeconds);
    }

    if (toolName == 'download_text') {
      final id = args['id']?.toString().trim() ?? '';
      if (id.isEmpty) throw ArgumentError('Missing required argument: id');
      // alt=media fetches raw content
      final uri = Uri.parse('${descriptor.baseUrl}/files/$id?alt=media');
      return _sendSimple('GET', uri, token, timeoutSeconds);
    }

    if (toolName == 'upload_text') {
      final name = args['name']?.toString().trim() ?? '';
      if (name.isEmpty) throw ArgumentError('Missing required argument: name');
      final text = args['text']?.toString() ?? '';
      final folderId = args['folder_id']?.toString().trim();

      // Google Drive multipart upload to /upload/drive/v3/files?uploadType=multipart
      final uri = Uri.parse('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart');
      final boundary = '-------314159265358979323846';

      final metadata = <String, dynamic>{
        'name': name,
        'mimeType': 'text/plain',
        if (folderId != null && folderId.isNotEmpty) 'parents': [folderId],
      };

      final bodyBuffer = StringBuffer()
        ..write('--$boundary\r\n')
        ..write('Content-Type: application/json; charset=UTF-8\r\n\r\n')
        ..write(jsonEncode(metadata))
        ..write('\r\n')
        ..write('--$boundary\r\n')
        ..write('Content-Type: text/plain\r\n\r\n')
        ..write(text)
        ..write('\r\n')
        ..write('--$boundary--\r\n');

      final req = http.Request('POST', uri);
      req.headers['Authorization'] = 'Bearer ${token.trim()}';
      req.headers['Content-Type'] = 'multipart/related; boundary=$boundary';
      req.body = bodyBuffer.toString();

      try {
        final streamed = await client.send(req).timeout(
              Duration(seconds: timeoutSeconds),
            );
        final resp = await http.Response.fromStream(streamed);
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          return resp.body;
        }
        return 'HTTP ${resp.statusCode}\n${resp.body}';
      } on TimeoutException {
        throw FormatException(
          'Request to $uri timed out after $timeoutSeconds seconds.',
        );
      } catch (e) {
        throw FormatException('HTTP request failed: $e');
      }
    }

    throw ArgumentError('Unknown tool: $toolName for plugin "$pluginName".');
  }

  Future<String> _sendSimple(String method, Uri uri, String token, int timeoutSeconds) async {
    final req = http.Request(method, uri);
    req.headers['Authorization'] = 'Bearer ${token.trim()}';
    try {
      final streamed = await client.send(req).timeout(
            Duration(seconds: timeoutSeconds),
          );
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return resp.body;
      }
      return 'HTTP ${resp.statusCode}\n${resp.body}';
    } on TimeoutException {
      throw FormatException(
        'Request to $uri timed out after $timeoutSeconds seconds.',
      );
    } catch (e) {
      throw FormatException('HTTP request failed: $e');
    }
  }
}

// ---------------------------------------------------------------------------
// Stripe MCP
// ---------------------------------------------------------------------------
class StripeCapability extends _AiMediaCapability {
  StripeCapability({super.client})
      : super(
          aiMediaDescriptors
              .firstWhere((d) => d.pluginName == 'Stripe MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    final key = await readConfig(descriptor.credentialKey);
    if (key == null || key.trim().isEmpty) return missingCredError();

    final cleanArgs = Map<String, dynamic>.from(args);
    if (toolName == 'create_invoice') {
      final customerId = cleanArgs['customer_id']?.toString().trim() ?? '';
      if (customerId.isEmpty) {
        throw ArgumentError('Missing required argument: customer_id');
      }
      final bodyMap = <String, dynamic>{
        'customer': customerId,
      };
      if (cleanArgs['description'] != null && cleanArgs['description'].toString().isNotEmpty) {
        bodyMap['description'] = cleanArgs['description'].toString();
      }
      if (cleanArgs['amount_cents'] != null) {
        bodyMap['amount'] = cleanArgs['amount_cents'];
      }
      if (cleanArgs['currency'] != null && cleanArgs['currency'].toString().isNotEmpty) {
        bodyMap['currency'] = cleanArgs['currency'].toString();
      } else {
        bodyMap['currency'] = 'usd';
      }
      cleanArgs['body'] = bodyMap;
    }

    final cap = RestApiCapability(descriptor, client: client);
    return await cap.callTool(toolName, cleanArgs);
  }
}

// ---------------------------------------------------------------------------
// YouTube Summarizer
// ---------------------------------------------------------------------------
class YouTubeSummarizerCapability extends _AiMediaCapability {
  YouTubeSummarizerCapability({super.client})
      : super(
          aiMediaDescriptors
              .firstWhere((d) => d.pluginName == 'YouTube Summarizer'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    if (toolName != 'get_details') {
      throw ArgumentError('Unknown tool: $toolName for plugin "$pluginName".');
    }

    final url = args['url']?.toString().trim() ?? '';
    if (url.isEmpty) {
      throw ArgumentError('Missing required argument: url');
    }

    final timeoutSeconds = RestApiCapability.resolveTimeoutSeconds(args);
    final oEmbedUri = Uri.parse('https://www.youtube.com/oembed').replace(
      queryParameters: {'url': url, 'format': 'json'},
    );

    try {
      final req = http.Request('GET', oEmbedUri);
      final streamed = await client.send(req).timeout(
            Duration(seconds: timeoutSeconds),
          );
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return 'HTTP ${resp.statusCode}\n${resp.body}';
      }

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final title = data['title'] ?? '(Unknown Title)';
      final author = data['author_name'] ?? '(Unknown Author)';
      final description = data['description']?.toString() ?? '';

      final honestyNotice =
          'Notice: No captions track available via oEmbed; summary generated from video metadata and description.';

      if (description.isEmpty) {
        return 'Title: $title\n'
            'Author: $author\n'
            'Description: (none provided)\n\n'
            '$honestyNotice';
      }

      return 'Title: $title\n'
          'Author: $author\n'
          'Description:\n$description\n\n'
          '$honestyNotice';
    } on TimeoutException {
      throw FormatException(
        'Request to $oEmbedUri timed out after $timeoutSeconds seconds.',
      );
    } catch (e) {
      throw FormatException('HTTP request failed: $e');
    }
  }
}

// ---------------------------------------------------------------------------
// LangChain MCP (Prompt Capability)
// ---------------------------------------------------------------------------
class LangChainMcpCapability extends NativePromptCapability {
  @override
  String get pluginName => 'LangChain MCP';

  @override
  String get taskSystemPrompt =>
      'You are an expert LangChain and LCEL architect. Design reliable, '
      'composable chains and tool-calling agent systems based on user requirements.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'chain_design',
          description:
              'Design an LCEL (LangChain Expression Language) blueprint for a task.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'task': {'type': 'string'},
            },
            'required': ['task'],
          },
        ),
        NativePluginTool(
          name: 'agent_plan',
          description:
              'Plan an agent system with tools, memory, and execution flow for a goal.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'goal': {'type': 'string'},
            },
            'required': ['goal'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  String buildPrompt(String toolName, Map<String, dynamic> args) {
    switch (toolName) {
      case 'chain_design':
        final task = args['task']?.toString().trim() ?? '';
        if (task.isEmpty) throw ArgumentError('Missing required argument: task');
        return 'Design an LCEL blueprint for the following task:\n\n'
            '${boundInput(task, maxInputChars)}\n\n'
            'Provide runnable Python/LCEL syntax, prompt components, and output parsers.';

      case 'agent_plan':
        final goal = args['goal']?.toString().trim() ?? '';
        if (goal.isEmpty) throw ArgumentError('Missing required argument: goal');
        return 'Create a detailed agent plan to achieve this goal:\n\n'
            '${boundInput(goal, maxInputChars)}\n\n'
            'Specify the agent architecture, required tool definitions, memory strategy, and control flow.';

      default:
        throw ArgumentError('Unknown tool: $toolName for plugin "$pluginName".');
    }
  }
}

// ---------------------------------------------------------------------------
// AutoGPT Bridge (Prompt Capability)
// ---------------------------------------------------------------------------
class AutoGptBridgeCapability extends NativePromptCapability {
  @override
  String get pluginName => 'AutoGPT Bridge';

  @override
  String get taskSystemPrompt =>
      'You are a multi-agent orchestration coordinator. Break down complex goals '
      'into structured, modular sub-agent delegations.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'decompose',
          description:
              'Decompose a complex goal into a structured sub-agent delegation plan.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'goal': {'type': 'string'},
            },
            'required': ['goal'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  String buildPrompt(String toolName, Map<String, dynamic> args) {
    if (toolName != 'decompose') {
      throw ArgumentError('Unknown tool: $toolName for plugin "$pluginName".');
    }
    final goal = args['goal']?.toString().trim() ?? '';
    if (goal.isEmpty) throw ArgumentError('Missing required argument: goal');

    return 'Decompose this goal into a structured sub-agent delegation plan:\n\n'
        '${boundInput(goal, maxInputChars)}\n\n'
        'Return structured JSON or bulleted roles, inputs, expected outputs, and execution order.';
  }
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
void registerAiMedia() {
  final registry = NativePluginRegistry.I;
  registry.register(DalleCapability());
  registry.register(ElevenLabsCapability());
  registry.register(NotionSyncCapability());
  registry.register(GoogleDriveCapability());
  registry.register(StripeCapability());
  registry.register(YouTubeSummarizerCapability());
  registry.register(LangChainMcpCapability());
  registry.register(AutoGptBridgeCapability());
}
