import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:ovid_ai/core/device_control_service.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:qr/qr.dart';

/// NP2b leftover utility capabilities (NP4 Task 2): QR Generator,
/// SSH Key Manager, Mermaid Diagrams, Excalidraw Bridge, Icon Library,
/// Font Preview, and Audio Notes.
///
/// Conventions mirror the sibling NP2/NP3/NP4 capabilities:
/// - `timeout_seconds` on every network tool: tolerant-parsed (`num` or
///   numeric `String`, else [FormatException]), default 30s, clamped 5..300s.
/// - Oversized results trimmed head+tail at 6000 chars with the exact MCP
///   omission notice.
/// - Unknown tools and missing arguments throw [ArgumentError]; malformed
///   user input (bad JSON, bad URLs, bad key material, capacity overflow)
///   throws [FormatException].
/// - Network-dependent capabilities accept an injectable [http.Client] so
///   tests can supply a mock client and never touch the real network.
///
/// QR rendering uses `package:qr` for the matrix plus a minimal in-file PNG
/// encoder (grayscale, `dart:io` zlib); SSH keys use `package:cryptography`
/// (ed25519) with real OpenSSH wire encodings (`ssh-ed25519` public lines,
/// `openssh-key-v1` PEM private blocks).
void registerMiscUtilities() {
  NativePluginRegistry.I.register(QrGeneratorCapability());
  NativePluginRegistry.I.register(SshKeyManagerCapability());
  NativePluginRegistry.I.register(MermaidDiagramsCapability());
  NativePluginRegistry.I.register(ExcalidrawBridgeCapability());
  NativePluginRegistry.I.register(IconLibraryCapability());
  NativePluginRegistry.I.register(FontPreviewCapability());
  NativePluginRegistry.I.register(AudioNotesCapability());
  NativePluginRegistry.I.register(ScreenAwarenessCapability());
}

String _requireString(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) {
    throw ArgumentError('Missing required argument: $key');
  }
  return value.toString();
}

String _requireNonBlank(Map<String, dynamic> args, String key) {
  final value = _requireString(args, key);
  if (value.trim().isEmpty) {
    throw ArgumentError('Missing required argument: $key');
  }
  return value;
}

/// Tolerant integer parsing for LLM-supplied numeric args: accepts [num]
/// directly or a numeric [String] (e.g. `"10"`); anything else is a
/// user-input error ([FormatException]).
int _parseIntArg(dynamic raw, String key, int fallback) {
  if (raw == null) return fallback;
  if (raw is num) return raw.toInt();
  final parsed = int.tryParse(raw.toString().trim());
  if (parsed == null) {
    throw FormatException('Invalid $key "$raw": expected an integer.');
  }
  return parsed;
}

/// Tolerant double parsing for LLM-supplied numeric args: accepts [num]
/// directly or a numeric [String]; anything else is a user-input error
/// ([FormatException]).
double _parseDoubleArg(dynamic raw, String key, double fallback) {
  if (raw == null) return fallback;
  if (raw is num) return raw.toDouble();
  final parsed = double.tryParse(raw.toString().trim());
  if (parsed == null) {
    throw FormatException('Invalid $key "$raw": expected a number.');
  }
  return parsed;
}

/// `timeout_seconds` convention: tolerant-parsed, default 30s, clamped
/// 5..300s (sibling NP3/NP4 convention).
int _timeoutSeconds(Map<String, dynamic> args) {
  final raw = args['timeout_seconds'];
  double value;
  if (raw == null) {
    value = 30;
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
  return value.round().clamp(5, 300);
}

/// Inline cap for a tool result handed to the model. Oversized output is
/// trimmed head+tail with the exact MCP omission notice (sibling NP3/NP4
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

Uri _requireHttpUrl(String raw, String key) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null ||
      !uri.hasScheme ||
      !(uri.scheme == 'http' || uri.scheme == 'https') ||
      uri.host.isEmpty) {
    throw FormatException(
      'Invalid $key "$raw": expected an absolute http(s) URL.',
    );
  }
  return uri;
}

// ---------------------------------------------------------------------------
// Minimal PNG encoder (grayscale, 8-bit) for QR output
// ---------------------------------------------------------------------------

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >>> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

void _pngChunk(BytesBuilder out, String type, List<int> data) {
  final typeBytes = ascii.encode(type);
  final length = ByteData(4)..setUint32(0, data.length);
  out.add(length.buffer.asUint8List());
  out.add(typeBytes);
  out.add(data);
  final crc = ByteData(4)..setUint32(0, _crc32([...typeBytes, ...data]));
  out.add(crc.buffer.asUint8List());
}

/// Encodes 8-bit grayscale [pixels] (row-major, 0 = black, 255 = white)
/// as a PNG image.
Uint8List _encodePngGrayscale(int width, int height, List<int> pixels) {
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // filter type 0 (None)
    for (var x = 0; x < width; x++) {
      raw.addByte(pixels[y * width + x]);
    }
  }
  final compressed = ZLibEncoder().convert(raw.toBytes());
  final out = BytesBuilder();
  out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 0) // color type: grayscale
    ..setUint8(10, 0) // compression
    ..setUint8(11, 0) // filter
    ..setUint8(12, 0); // interlace
  _pngChunk(out, 'IHDR', ihdr.buffer.asUint8List());
  _pngChunk(out, 'IDAT', compressed);
  _pngChunk(out, 'IEND', const []);
  return out.toBytes();
}

// ---------------------------------------------------------------------------
// QR Generator
// ---------------------------------------------------------------------------

class QrGeneratorCapability implements NativePluginCapability {
  @override
  String get pluginName => 'QR Generator';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'generate',
          description:
              'Render text as a QR code PNG (base64). Refuses input beyond '
              'QR capacity instead of truncating.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
              'size': {'type': 'integer'},
              'margin': {'type': 'integer'},
            },
            'required': ['text'],
          },
        ),
        NativePluginTool(
          name: 'validate',
          description:
              'Honestly report whether text fits in a QR code (no silent '
              'truncation).',
          inputSchema: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
            },
            'required': ['text'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {
    if (values.isNotEmpty) {
      throw ArgumentError(
        'Plugin "$pluginName" has no configurable settings.',
      );
    }
  }

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'generate':
        return _generate(
          _requireString(args, 'text'),
          _parseIntArg(args['size'], 'size', 512).clamp(64, 2048),
          _parseIntArg(args['margin'], 'margin', 4).clamp(0, 16),
        );
      case 'validate':
        return _validate(_requireString(args, 'text'));
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  QrCode _buildCode(String text) {
    final payload = QrPayload.fromString(text);
    try {
      return QrCode(
        payload: payload,
        errorCorrectLevel: QrErrorCorrectLevel.low,
      );
    } on InputTooLongException catch (e) {
      throw FormatException(
        'QR capacity overflow: ${text.length} characters need '
        '${e.inputBits} bits but the largest QR code (version 40) holds '
        '${e.inputLimit} bits. Shorten the text instead of truncating.',
      );
    }
  }

  String _generate(String text, int size, int margin) {
    if (text.trim().isEmpty) {
      throw ArgumentError('Missing required argument: text');
    }
    final code = _buildCode(text);
    final image = QrImage(code);
    final modules = image.moduleCount;
    final scale = math.max(1, size ~/ (modules + 2 * margin));
    final dim = (modules + 2 * margin) * scale;
    final pixels = List<int>.filled(dim * dim, 255);
    for (var y = 0; y < modules; y++) {
      for (var x = 0; x < modules; x++) {
        if (image.isDark(y, x)) {
          final baseY = (y + margin) * scale;
          final baseX = (x + margin) * scale;
          for (var dy = 0; dy < scale; dy++) {
            for (var dx = 0; dx < scale; dx++) {
              pixels[(baseY + dy) * dim + baseX + dx] = 0;
            }
          }
        }
      }
    }
    final png = _encodePngGrayscale(dim, dim, pixels);
    return jsonEncode({
      'text': text,
      'modules': modules,
      'size_px': dim,
      'png_base64': base64Encode(png),
      'bytes': png.length,
    });
  }

  String _validate(String text) {
    if (text.isEmpty) {
      throw ArgumentError('Missing required argument: text');
    }
    try {
      final code = _buildCode(text);
      return jsonEncode({
        'fits': true,
        'length': text.length,
        'type_number': code.typeNumber,
        'modules': code.moduleCount,
        'message':
            'Fits in a version ${code.typeNumber} QR code '
            '(${code.moduleCount}x${code.moduleCount} modules).',
      });
    } on FormatException catch (e) {
      return jsonEncode({
        'fits': false,
        'length': text.length,
        'message': e.message,
      });
    }
  }
}

// ---------------------------------------------------------------------------
// SSH Key Manager
// ---------------------------------------------------------------------------

/// SSH wire-format helpers (RFC 4251 strings + OpenSSH key blobs).
List<int> _sshString(List<int> bytes) {
  final out = ByteData(4)..setUint32(0, bytes.length);
  return [...out.buffer.asUint8List(), ...bytes];
}

String _sshPublicLine(String keyType, List<int> blob, String comment) =>
    '$keyType ${base64Encode(blob)} $comment'.trim();

/// Parses an OpenSSH `"<type> <base64> [comment]"` public key line into its
/// raw blob bytes. Anything else is a user-input error ([FormatException]).
List<int> _parseSshPublicLine(String raw) {
  final parts = raw.trim().split(RegExp(r'\s+'));
  if (parts.length < 2 ||
      !(parts[0] == 'ssh-ed25519' || parts[0] == 'ssh-rsa')) {
    throw FormatException(
      'Invalid public key "$raw": expected an OpenSSH public key line '
      '("ssh-ed25519 AAAA…" or "ssh-rsa AAAA…").',
    );
  }
  try {
    return base64Decode(parts[1].replaceAll(RegExp(r'\s'), ''));
  } on FormatException {
    throw FormatException(
      'Invalid public key: the base64 body is malformed.',
    );
  }
}

/// `SHA256:<base64-no-padding>` fingerprint over the raw public blob
/// (OpenSSH `ssh-keygen -l -E sha256` shape).
String _sshFingerprint(List<int> blob) {
  final digest = crypto.sha256.convert(blob);
  final b64 = base64Encode(digest.bytes).replaceAll('=', '');
  return 'SHA256:$b64';
}

String _pemArmor(String label, List<int> der) {
  final b64 = base64Encode(der);
  final lines = <String>[];
  for (var i = 0; i < b64.length; i += 70) {
    lines.add(b64.substring(i, math.min(i + 70, b64.length)));
  }
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}

class SshKeyManagerCapability implements NativePluginCapability {
  SshKeyManagerCapability({FlutterSecureStorage? secureStorage})
      : _secure = secureStorage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _secure;

  static const _prefix = 'ssh_key_manager__';

  @override
  String get pluginName => 'SSH Key Manager';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'generate',
          description:
              'Generate an ed25519 SSH key pair. Keys are returned, never '
              'stored unless save is called.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'type': {'type': 'string'},
            },
          },
        ),
        NativePluginTool(
          name: 'save',
          description: 'Store a key pair in the vault under a name.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'name': {'type': 'string'},
              'private_key': {'type': 'string'},
              'public_key': {'type': 'string'},
            },
            'required': ['name', 'private_key', 'public_key'],
          },
        ),
        NativePluginTool(
          name: 'get',
          description: 'Retrieve a stored key pair by name.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'name': {'type': 'string'},
            },
            'required': ['name'],
          },
        ),
        NativePluginTool(
          name: 'list',
          description: 'List stored key names (without key material).',
          inputSchema: {
            'type': 'object',
            'properties': {},
          },
        ),
        NativePluginTool(
          name: 'fingerprint',
          description:
              'SHA-256 fingerprint of an OpenSSH public key line.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'public_key': {'type': 'string'},
            },
            'required': ['public_key'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {
    if (values.isNotEmpty) {
      throw ArgumentError(
        'Plugin "$pluginName" has no configurable settings.',
      );
    }
  }

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'generate':
        return _generate(
          (args['type']?.toString() ?? 'ed25519').trim().toLowerCase(),
        );
      case 'save':
        return _save(
          _requireNonBlank(args, 'name'),
          _requireString(args, 'private_key'),
          _requireString(args, 'public_key'),
        );
      case 'get':
        return _get(_requireNonBlank(args, 'name'));
      case 'list':
        return _list();
      case 'fingerprint':
        return _fingerprint(_requireString(args, 'public_key'));
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  Future<String> _generate(String type) async {
    switch (type) {
      case 'ed25519':
        return _generateEd25519();
      case 'rsa':
        throw ArgumentError(
          'RSA key generation is not supported on this device — use ed25519.',
        );
      default:
        throw ArgumentError(
          'Unknown key type "$type": expected "ed25519".',
        );
    }
  }

  Future<String> _generateEd25519() async {
    final keyPair = await Ed25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final seed = await keyPair.extractPrivateKeyBytes();
    final pubBytes = publicKey.bytes;
    final blob = [
      ..._sshString(ascii.encode('ssh-ed25519')),
      ..._sshString(pubBytes),
    ];
    final publicLine = _sshPublicLine('ssh-ed25519', blob, 'ovid-ai');
    final privatePem = _opensshV1Ed25519(seed, pubBytes, 'ovid-ai');
    return jsonEncode({
      'type': 'ed25519',
      'public_key': publicLine,
      'private_key': privatePem,
    });
  }

  /// `openssh-key-v1` container (unencrypted, cipher/kdf `none`) holding an
  /// ed25519 key: genuinely parseable by `ssh-keygen`/`ssh-add`.
  String _opensshV1Ed25519(
    List<int> seed,
    List<int> pub,
    String comment,
  ) {
    final check = math.Random.secure().nextInt(0xFFFFFFFF);
    final checkBytes = (ByteData(4)..setUint32(0, check)).buffer.asUint8List();
    final privateSection = [
      ...checkBytes,
      ...checkBytes,
      ..._sshString(ascii.encode('ssh-ed25519')),
      ..._sshString(pub),
      ..._sshString([...seed, ...pub]),
      ..._sshString(utf8.encode(comment)),
    ];
    // Block size 8 padding: bytes 1, 2, 3, ...
    final padded = privateSection.toList();
    var padByte = 1;
    while (padded.length % 8 != 0) {
      padded.add(padByte++);
    }
    final pubBlob = [
      ..._sshString(ascii.encode('ssh-ed25519')),
      ..._sshString(pub),
    ];
    final outer = [
      ...ascii.encode('openssh-key-v1\x00'),
      ..._sshString(ascii.encode('none')),
      ..._sshString(ascii.encode('none')),
      ..._sshString(const []),
      ..._uint32(1),
      ..._sshString(pubBlob),
      ..._sshString(padded),
    ];
    return _pemArmor('OPENSSH PRIVATE KEY', outer);
  }

  List<int> _uint32(int value) =>
      (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

  String _storageKey(String name) => '$_prefix$name';

  Future<String> _save(
    String name,
    String privateKey,
    String publicKey,
  ) async {
    if (privateKey.isEmpty) {
      throw ArgumentError('Missing required argument: private_key');
    }
    if (publicKey.isEmpty) {
      throw ArgumentError('Missing required argument: public_key');
    }
    await _secure.write(
      key: _storageKey(name),
      value: jsonEncode({
        'name': name,
        'private_key': privateKey,
        'public_key': publicKey,
      }),
    );
    return 'Saved SSH key "$name".';
  }

  Future<String> _get(String name) async {
    final value = await _secure.read(key: _storageKey(name));
    if (value == null) {
      throw ArgumentError('SSH key not found: "$name".');
    }
    return value;
  }

  Future<String> _list() async {
    final all = await _secure.readAll();
    final names = all.keys
        .where((k) => k.startsWith(_prefix))
        .map((k) => k.substring(_prefix.length))
        .toList()
      ..sort();
    return jsonEncode(names);
  }

  String _fingerprint(String publicKey) {
    final blob = _parseSshPublicLine(publicKey);
    return jsonEncode({
      'public_key': publicKey.trim(),
      'fingerprint': _sshFingerprint(blob),
    });
  }
}

// ---------------------------------------------------------------------------
// Mermaid Diagrams
// ---------------------------------------------------------------------------

const _mermaidHeaders = {
  'graph',
  'flowchart',
  'sequenceDiagram',
  'classDiagram',
  'stateDiagram',
  'stateDiagram-v2',
  'erDiagram',
  'gantt',
  'pie',
  'gitGraph',
  'mindmap',
  'timeline',
  'journey',
  'quadrantChart',
  'xychart-beta',
  'requirementDiagram',
  'sankey-beta',
  'C4Context',
  'c4Context',
  'block-beta',
  'packet-beta',
  'kanban',
  'architecture-beta',
  'radar-beta',
  'info',
};

class MermaidDiagramsCapability implements NativePluginCapability {
  MermaidDiagramsCapability({http.Client? client}) : _clientOverride = client;

  final http.Client? _clientOverride;
  http.Client? _lazyClient;

  /// Lazily created so capability *registration* never touches the HTTP
  /// stack — the client is only built on first actual tool use.
  http.Client get _client => _clientOverride ?? (_lazyClient ??= http.Client());

  @override
  String get pluginName => 'Mermaid Diagrams';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'validate',
          description:
              'Check Mermaid syntax: known diagram header plus balanced '
              'fences/braces.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
            },
            'required': ['text'],
          },
        ),
        NativePluginTool(
          name: 'render',
          description:
              'Render a Mermaid diagram to SVG via kroki.io (needs network; '
              'honest offline message when unreachable).',
          inputSchema: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
              'timeout_seconds': {'type': 'number'},
            },
            'required': ['text'],
          },
        ),
        NativePluginTool(
          name: 'export',
          description:
              'Return diagram source text plus its char count (no file is '
              'written).',
          inputSchema: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
              'path': {'type': 'string'},
            },
            'required': ['text'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {
    if (values.isNotEmpty) {
      throw ArgumentError(
        'Plugin "$pluginName" has no configurable settings.',
      );
    }
  }

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'validate':
        return _validate(_requireString(args, 'text'));
      case 'render':
        return _render(
          _requireString(args, 'text'),
          _timeoutSeconds(args),
        );
      case 'export':
        return _export(_requireString(args, 'text'));
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  List<String> _validationErrors(String text) {
    final errors = <String>[];
    if (text.trim().isEmpty) {
      return ['Empty diagram: provide Mermaid source text.'];
    }
    final fenceCount = RegExp('```').allMatches(text).length;
    if (fenceCount.isOdd) {
      errors.add('Unbalanced code fences: an odd number of ``` markers.');
    }
    final stripped =
        text.replaceAll(RegExp('```[\\s\\S]*?```'), '').replaceAll('```', '');
    var braces = 0, brackets = 0, parens = 0;
    for (var i = 0; i < stripped.length; i++) {
      switch (stripped[i]) {
        case '{':
          braces++;
        case '}':
          braces--;
        case '[':
          brackets++;
        case ']':
          brackets--;
        case '(':
          parens++;
        case ')':
          parens--;
      }
      if (braces < 0 || brackets < 0 || parens < 0) break;
    }
    if (braces != 0) {
      errors.add('Unbalanced braces: "{" and "}" counts differ.');
    }
    if (brackets != 0) {
      errors.add('Unbalanced brackets: "[" and "]" counts differ.');
    }
    if (parens != 0) {
      errors.add('Unbalanced parentheses: "(" and ")" counts differ.');
    }
    final firstLine = stripped
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    final header = firstLine.split(RegExp(r'\s|;')).firstWhere(
          (s) => s.isNotEmpty,
          orElse: () => '',
        );
    if (!_mermaidHeaders.contains(header)) {
      errors.add(
        'Unknown diagram type "$header": expected a Mermaid diagram header '
        'such as graph, flowchart, sequenceDiagram, classDiagram, '
        'stateDiagram, erDiagram, gantt, pie, gitGraph, or mindmap.',
      );
    }
    return errors;
  }

  String _validate(String text) {
    final errors = _validationErrors(text);
    return jsonEncode({'valid': errors.isEmpty, 'errors': errors});
  }

  Future<String> _render(String text, int timeoutSeconds) async {
    if (text.trim().isEmpty) {
      throw ArgumentError('Missing required argument: text');
    }
    const endpoint = 'https://kroki.io/mermaid/svg';
    http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse(endpoint),
            headers: {
              'Content-Type': 'text/plain',
              'Accept': 'image/svg+xml',
            },
            body: text,
          )
          .timeout(Duration(seconds: timeoutSeconds));
    } on TimeoutException {
      return 'Mermaid render is offline: the request to kroki.io timed out '
          'after $timeoutSeconds seconds with no SVG returned. Check '
          'connectivity and retry, or use the export tool to keep the '
          'diagram source.';
    } catch (e) {
      return 'Mermaid render is offline: could not reach kroki.io '
          '($e). No SVG was produced; check connectivity and retry, or use '
          'the export tool to keep the diagram source.';
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(
        'Mermaid render failed: kroki.io returned '
        'HTTP ${response.statusCode}: ${_trimOutput(response.body)}',
      );
    }
    return _trimOutput(response.body);
  }

  String _export(String text) {
    if (text.isEmpty) {
      throw ArgumentError('Missing required argument: text');
    }
    return jsonEncode({
      'text': text,
      'chars': text.length,
      'note': 'No file was written; save the text as a .mmd file yourself.',
    });
  }
}

// ---------------------------------------------------------------------------
// Excalidraw Bridge
// ---------------------------------------------------------------------------

class ExcalidrawBridgeCapability implements NativePluginCapability {
  @override
  String get pluginName => 'Excalidraw Bridge';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'stats',
          description: 'Count scene elements by type.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'json_text': {'type': 'string'},
            },
            'required': ['json_text'],
          },
        ),
        NativePluginTool(
          name: 'add_text',
          description: 'Append a text element to a scene.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'json_text': {'type': 'string'},
              'text': {'type': 'string'},
              'x': {'type': 'number'},
              'y': {'type': 'number'},
            },
            'required': ['json_text', 'text'],
          },
        ),
        NativePluginTool(
          name: 'merge',
          description: 'Concatenate the elements of two scenes.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'a_json': {'type': 'string'},
              'b_json': {'type': 'string'},
            },
            'required': ['a_json', 'b_json'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {
    if (values.isNotEmpty) {
      throw ArgumentError(
        'Plugin "$pluginName" has no configurable settings.',
      );
    }
  }

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'stats':
        return _stats(_requireString(args, 'json_text'));
      case 'add_text':
        return _addText(
          _requireString(args, 'json_text'),
          _requireString(args, 'text'),
          _parseDoubleArg(args['x'], 'x', 0),
          _parseDoubleArg(args['y'], 'y', 0),
        );
      case 'merge':
        return _merge(
          _requireString(args, 'a_json'),
          _requireString(args, 'b_json'),
        );
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  List<Map<String, dynamic>> _elementsOf(String raw, String key) {
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw FormatException('Invalid $key: not valid JSON (${e.message}).');
    }
    if (decoded is! Map) {
      throw FormatException(
        'Invalid $key: expected a JSON object with an "elements" array.',
      );
    }
    final elements = decoded['elements'];
    if (elements is! List) {
      throw FormatException(
        'Invalid $key: scene is missing an "elements" array.',
      );
    }
    return [
      for (final e in elements)
        if (e is Map) Map<String, dynamic>.from(e),
    ];
  }

  String _stats(String raw) {
    final elements = _elementsOf(raw, 'json_text');
    final byType = <String, int>{};
    for (final e in elements) {
      final type = e['type']?.toString() ?? 'unknown';
      byType[type] = (byType[type] ?? 0) + 1;
    }
    return jsonEncode({'total': elements.length, 'by_type': byType});
  }

  String _addText(String raw, String text, double x, double y) {
    final elements = _elementsOf(raw, 'json_text');
    num coord(double v) => v == v.roundToDouble() ? v.toInt() : v;
    elements.add({
      'id': 'text_${DateTime.now().microsecondsSinceEpoch}',
      'type': 'text',
      'text': text,
      'x': coord(x),
      'y': coord(y),
    });
    return jsonEncode({
      'type': 'excalidraw',
      'elements': elements,
      'total': elements.length,
    });
  }

  String _merge(String aRaw, String bRaw) {
    final a = _elementsOf(aRaw, 'a_json');
    final b = _elementsOf(bRaw, 'b_json');
    final merged = [...a, ...b];
    return jsonEncode({
      'type': 'excalidraw',
      'elements': merged,
      'total': merged.length,
    });
  }
}

// ---------------------------------------------------------------------------
// Icon Library (Iconify)
// ---------------------------------------------------------------------------

class IconLibraryCapability implements NativePluginCapability {
  IconLibraryCapability({http.Client? client}) : _clientOverride = client;

  final http.Client? _clientOverride;
  http.Client? _lazyClient;

  /// Lazily created so capability *registration* never touches the HTTP
  /// stack — the client is only built on first actual tool use.
  http.Client get _client => _clientOverride ?? (_lazyClient ??= http.Client());

  @override
  String get pluginName => 'Icon Library';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'search',
          description:
              'Search the Iconify icon set (no key needed); returns '
              'prefix:name hits with SVG URLs.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'query': {'type': 'string'},
              'limit': {'type': 'integer'},
              'timeout_seconds': {'type': 'number'},
            },
            'required': ['query'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {
    if (values.isNotEmpty) {
      throw ArgumentError(
        'Plugin "$pluginName" has no configurable settings.',
      );
    }
  }

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'search':
        return _search(
          _requireNonBlank(args, 'query'),
          _parseIntArg(args['limit'], 'limit', 20).clamp(1, 100),
          _timeoutSeconds(args),
        );
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  Future<String> _search(String query, int limit, int timeoutSeconds) async {
    final uri = Uri.https('api.iconify.design', '/search', {
      'query': query.trim(),
      'limit': '$limit',
    });
    http.Response response;
    try {
      response = await _client
          .get(uri)
          .timeout(Duration(seconds: timeoutSeconds));
    } on TimeoutException {
      return 'Icon search is offline: the request to api.iconify.design '
          'timed out after $timeoutSeconds seconds with no results. Check '
          'connectivity and retry.';
    } catch (e) {
      return 'Icon search is offline: could not reach api.iconify.design '
          '($e). Check connectivity and retry.';
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(
        'Iconify search failed: HTTP ${response.statusCode}: '
        '${_trimOutput(response.body)}',
      );
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw FormatException('Invalid Iconify response: ${e.message}.');
    }
    if (decoded is! Map) {
      throw FormatException(
        'Invalid Iconify response: expected a JSON object.',
      );
    }
    final rawIcons = decoded['icons'];
    if (rawIcons is! List) {
      throw FormatException(
        'Invalid Iconify response: missing an "icons" array.',
      );
    }
    final icons = [
      for (final entry in rawIcons)
        if (entry is String && entry.trim().isNotEmpty)
          {
            'name': entry,
            'svg_url': 'https://api.iconify.design/$entry.svg',
          }
        else if (entry is Map && entry['name'] != null)
          {
            'name': entry['name'].toString(),
            'svg_url': 'https://api.iconify.design/'
                '${entry['name']}.svg',
          },
    ];
    final total = decoded['total'];
    return _trimOutput(jsonEncode({
      'query': query.trim(),
      'total': total is num ? total.toInt() : icons.length,
      'icons': icons,
    }));
  }
}

// ---------------------------------------------------------------------------
// Font Preview (Google Fonts)
// ---------------------------------------------------------------------------

class FontPreviewCapability implements NativePluginCapability {
  FontPreviewCapability({http.Client? client}) : _clientOverride = client;

  final http.Client? _clientOverride;
  http.Client? _lazyClient;

  /// Lazily created so capability *registration* never touches the HTTP
  /// stack — the client is only built on first actual tool use.
  http.Client get _client => _clientOverride ?? (_lazyClient ??= http.Client());

  @override
  String get pluginName => 'Font Preview';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'search',
          description:
              'Search Google Fonts families by name (no key needed).',
          inputSchema: {
            'type': 'object',
            'properties': {
              'query': {'type': 'string'},
              'timeout_seconds': {'type': 'number'},
            },
            'required': ['query'],
          },
        ),
        NativePluginTool(
          name: 'preview_url',
          description:
              'Build a fonts.googleapis.com css2 preview URL for a family '
              '(open it to see the rendering; no binary is downloaded).',
          inputSchema: {
            'type': 'object',
            'properties': {
              'family': {'type': 'string'},
              'text': {'type': 'string'},
            },
            'required': ['family'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {
    if (values.isNotEmpty) {
      throw ArgumentError(
        'Plugin "$pluginName" has no configurable settings.',
      );
    }
  }

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'search':
        return _search(
          _requireNonBlank(args, 'query'),
          _timeoutSeconds(args),
        );
      case 'preview_url':
        return _previewUrl(
          _requireNonBlank(args, 'family'),
          args['text']?.toString() ?? '',
        );
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  Future<String> _search(String query, int timeoutSeconds) async {
    final uri =
        Uri.parse('https://www.googleapis.com/fonts/v1/webfonts?sort=alpha');
    http.Response response;
    try {
      response = await _client
          .get(uri)
          .timeout(Duration(seconds: timeoutSeconds));
    } on TimeoutException {
      return 'Font search is offline: the request to www.googleapis.com '
          'timed out after $timeoutSeconds seconds with no results. Check '
          'connectivity and retry.';
    } catch (e) {
      return 'Font search is offline: could not reach www.googleapis.com '
          '($e). Check connectivity and retry.';
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(
        'Google Fonts search failed: HTTP ${response.statusCode}: '
        '${_trimOutput(response.body)}',
      );
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw FormatException('Invalid Google Fonts response: ${e.message}.');
    }
    if (decoded is! Map) {
      throw FormatException(
        'Invalid Google Fonts response: expected a JSON object.',
      );
    }
    final items = decoded['items'];
    if (items is! List) {
      throw FormatException(
        'Invalid Google Fonts response: missing an "items" array.',
      );
    }
    final needle = query.trim().toLowerCase();
    final families = [
      for (final item in items)
        if (item is Map &&
            item['family'] != null &&
            item['family'].toString().toLowerCase().contains(needle))
          {
            'family': item['family'].toString(),
            if (item['category'] != null)
              'category': item['category'].toString(),
            if (item['variants'] != null) 'variants': item['variants'],
          },
    ];
    return _trimOutput(jsonEncode({
      'query': query.trim(),
      'count': families.length,
      'families': families,
    }));
  }

  String _previewUrl(String family, String text) {
    final encodedFamily = Uri.encodeQueryComponent(family.trim());
    final encodedText = Uri.encodeQueryComponent(text);
    final url = 'https://fonts.googleapis.com/css2?family=$encodedFamily'
        '${text.isEmpty ? '' : '&text=$encodedText'}';
    return url;
  }
}

// ---------------------------------------------------------------------------
// Audio Notes (Whisper transcription of a reachable audio URL)
// ---------------------------------------------------------------------------

class AudioNotesCapability implements NativePluginCapability {
  AudioNotesCapability({http.Client? client}) : _clientOverride = client;

  final http.Client? _clientOverride;
  http.Client? _lazyClient;

  /// Lazily created so capability *registration* never touches the HTTP
  /// stack — the client is only built on first actual tool use.
  http.Client get _client => _clientOverride ?? (_lazyClient ??= http.Client());

  @override
  String get pluginName => 'Audio Notes';

  @override
  List<NativePluginConfigField> get configFields => const [
        NativePluginConfigField(
          key: 'openai_api_key',
          label: 'OpenAI API key',
          secret: true,
          hint: 'Pasted on the Configure sheet; used for Whisper.',
        ),
      ];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'transcribe',
          description:
              'Transcribe an http(s)-reachable audio URL via Whisper '
              '(needs openai_api_key; URL-based only — on-device mic '
              'dictation already exists via Voice Input).',
          inputSchema: {
            'type': 'object',
            'properties': {
              'audio_url': {'type': 'string'},
              'timeout_seconds': {'type': 'number'},
            },
            'required': ['audio_url'],
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
    switch (toolName) {
      case 'transcribe':
        return _transcribe(
          _requireString(args, 'audio_url'),
          _timeoutSeconds(args),
        );
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  Future<String> _transcribe(String audioUrl, int timeoutSeconds) async {
    final uri = _requireHttpUrl(audioUrl, 'audio_url');
    final apiKey = await NativePluginConfigStore.I.read(
      pluginName: pluginName,
      key: 'openai_api_key',
      secret: true,
    );
    if ((apiKey ?? '').trim().isEmpty) {
      return 'Configure OpenAI API key first: open the Configure sheet for '
          '"Audio Notes" and save "openai_api_key".';
    }
    http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('https://api.openai.com/v1/audio/transcriptions'),
            headers: {
              'Authorization': 'Bearer ${apiKey!.trim()}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'model': 'whisper-1', 'url': uri.toString()}),
          )
          .timeout(Duration(seconds: timeoutSeconds));
    } on TimeoutException {
      return 'Audio transcription is offline: the request to '
          'api.openai.com timed out after $timeoutSeconds seconds with no '
          'transcript. Check connectivity and retry.';
    } catch (e) {
      return 'Audio transcription is offline: could not reach '
          'api.openai.com ($e). Check connectivity and retry.';
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(
        'Whisper transcription failed: HTTP ${response.statusCode}: '
        '${_trimOutput(response.body)}',
      );
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw FormatException('Invalid Whisper response: ${e.message}.');
    }
    final text = decoded is Map ? decoded['text']?.toString() ?? '' : '';
    if (text.isEmpty) {
      throw FormatException(
        'Invalid Whisper response: missing recognised "text".',
      );
    }
    return _trimOutput(text);
  }
}

class ScreenAwarenessCapability implements NativePluginCapability {
  @override
  String get pluginName => 'Screen Awareness';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'read_screen',
          description: 'Read the currently active screen UI elements and text',
          inputSchema: {
            'type': 'object',
            'properties': {
              'full': {'type': 'boolean', 'description': 'Read full window hierarchy'},
            },
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    if (toolName != 'read_screen') {
      throw ArgumentError('Unknown tool "$toolName" for $pluginName.');
    }
    // Reads screen directly via the device accessibility service bridge
    try {
      final full = args['full'] == true;
      final raw = await DeviceControlService.I.read(full: full);
      return _trimOutput(raw);
    } catch (e) {
      return 'Could not read screen: $e. Ensure Control mode and Accessibility service are enabled.';
    }
  }
}
