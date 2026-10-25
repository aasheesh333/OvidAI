/// Fail-closed static rich-content rendering.
///
/// Model SVG is parsed as XML, never inserted into an HTML/WebView node. The
/// only hand-off to Android is sanitized XML (or Mermaid source) and the only
/// value accepted back is PNG bytes. No URL, cookie, credential, or interactive
/// document crosses this boundary.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:xml/xml.dart';

import '../state.dart';
import 'cloud_rest.dart';
import 'models.dart';

const String _svgNamespace = 'http://www.w3.org/2000/svg';
const int _maxStaticSvgBytes = 1024 * 1024;

/// Elements needed by ordinary vector drawings. Anything active, unknown, or
/// HTML-like is rejected rather than handed to a rasterizer to "see what it
/// does". In particular, links and animation have no meaning in a static image.
const Set<String> _staticSvgElements = <String>{
  'svg',
  'g',
  'defs',
  'symbol',
  'use',
  'path',
  'rect',
  'circle',
  'ellipse',
  'line',
  'polyline',
  'polygon',
  'text',
  'tspan',
  'textPath',
  'title',
  'desc',
  'style',
  'clipPath',
  'mask',
  'pattern',
  'marker',
  'linearGradient',
  'radialGradient',
  'stop',
  'image',
};

const Set<String> _urlAttributes = <String>{
  'href',
  'src',
  'data',
  'poster',
  'action',
  'formaction',
};

/// Validates and returns one standalone static SVG document.
///
/// The default SVG namespace is optional; foreign/prefixed namespaces are not.
/// Only local fragment references and raster `data:image/...` payloads are
/// accepted. Remote URLs, executable data documents, event attributes,
/// animation, raw HTML containers, DTDs and CSS URL loads throw
/// [FormatException]. This function performs no I/O.
String sanitizeStaticSvg(String input) {
  if (input.isEmpty || input.length > _maxStaticSvgBytes) {
    throw const FormatException('Invalid static SVG');
  }
  // XML declarations are unnecessary for this small interchange format. A
  // blanket PI/DTD refusal also covers xml-stylesheet and external entities.
  if (input.contains('<?') ||
      RegExp(
        r'<!\s*(?:DOCTYPE|ENTITY)',
        caseSensitive: false,
      ).hasMatch(input)) {
    throw const FormatException('Active SVG declaration');
  }

  final XmlDocument document;
  try {
    document = XmlDocument.parse(input);
  } on Object {
    throw const FormatException('Malformed SVG');
  }
  final root = document.rootElement;
  _validateElement(root, isRoot: true);
  for (final element in root.descendants.whereType<XmlElement>()) {
    _validateElement(element);
  }
  return root.toXmlString();
}

void _validateElement(XmlElement element, {bool isRoot = false}) {
  final name = element.name;
  if ((name.prefix?.isNotEmpty ?? false) ||
      (isRoot && name.local != 'svg') ||
      !_staticSvgElements.contains(name.local)) {
    throw const FormatException('Unsafe SVG element or namespace');
  }

  for (final attribute in element.attributes) {
    final attributeName = attribute.name;
    final local = attributeName.local;
    final lower = local.toLowerCase();
    if ((attributeName.prefix?.isNotEmpty ?? false) || lower.startsWith('on')) {
      throw const FormatException('Unsafe SVG attribute or namespace');
    }
    if (lower == 'xmlns') {
      if (attribute.value != _svgNamespace) {
        throw const FormatException('Foreign SVG namespace');
      }
      continue;
    }

    final value = attribute.value;
    if (_urlAttributes.contains(lower) && !_safeStaticReference(value)) {
      throw const FormatException('External or executable SVG reference');
    }
    final active = _normalizedActiveText(value);
    if (lower == 'style' && _containsActiveCssMotion(active)) {
      throw const FormatException('Active SVG CSS motion');
    }
    if (active.contains('url(') ||
        active.contains('@import') ||
        active.contains('expression(') ||
        active.contains('javascript:') ||
        active.contains('data:text/') ||
        active.contains('data:image/svg') ||
        active.contains('https:') ||
        active.contains('http:') ||
        active.contains('file:') ||
        active.contains('content:') ||
        active.startsWith('//')) {
      throw const FormatException('Active SVG attribute');
    }
  }

  if (name.local == 'style') {
    final active = _normalizedActiveText(element.innerText);
    if (_containsActiveCssMotion(active, stylesheet: true)) {
      throw const FormatException('Active SVG CSS motion');
    }
    if (active.contains('url(') ||
        active.contains('@import') ||
        active.contains('expression(') ||
        active.contains('javascript:') ||
        active.contains('https:') ||
        active.contains('http:') ||
        active.contains('file:') ||
        active.contains('content:') ||
        active.contains('//')) {
      throw const FormatException('External or active SVG CSS');
    }
  }
}

bool _containsActiveCssMotion(String normalized, {bool stylesheet = false}) {
  if (stylesheet && RegExp(r'@(?:-[a-z]+-)?keyframes').hasMatch(normalized)) {
    return true;
  }
  return RegExp(
    r'(?:^|[;{])(?:-[a-z]+-)?(?:animation|transition)(?:-[a-z]+)?:',
  ).hasMatch(normalized);
}

bool _safeStaticReference(String raw) {
  final value = raw.replaceAll(RegExp(r'[\x00-\x20\x7f]+'), '').toLowerCase();
  if (value.isEmpty) return false;
  if (value.startsWith('#') && value.length > 1) {
    return !value.contains(RegExp("[\\s<>\"']"));
  }
  return RegExp(
    r'^data:image/(?:png|jpeg|gif|webp);base64,[a-z0-9+/]+={0,2}$',
  ).hasMatch(value);
}

/// Normalizes CSS escapes, comments, entities already decoded by XML, control
/// characters and whitespace before looking for active constructs. This is a
/// detection normalization only; the returned SVG retains its original text.
String _normalizedActiveText(String raw) {
  var text = raw.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  text = text.replaceAllMapped(
    RegExp(r'\\(?:([0-9a-fA-F]{1,6})[\t\n\r ]?|(.))'),
    (match) {
      final hex = match.group(1);
      if (hex == null) return match.group(2) ?? '';
      final code = int.tryParse(hex, radix: 16);
      if (code == null || code == 0 || code > 0x10ffff) return '';
      return String.fromCharCode(code);
    },
  );
  return text.replaceAll(RegExp(r'[\x00-\x20\x7f]+'), '').toLowerCase();
}

enum MessageAttachmentAvailability { pending, ready, unavailable }

/// A user attachment with actual gateway identity and upload state.
///
/// A local path is not proof of upload completion. Only an accepted gateway
/// attachment ID is eligible for a fresh signed URL. The subclass preserves
/// the base model used elsewhere without changing shared state ownership.
final class RichMessageAttachment extends MessageAttachment {
  RichMessageAttachment({
    this.id,
    required super.name,
    required super.size,
    MessageAttachmentAvailability? availability,
    super.path,
    super.url,
  }) : availability =
           availability ??
           (id != null
               ? MessageAttachmentAvailability.ready
               : path != null
               ? MessageAttachmentAvailability.pending
               : MessageAttachmentAvailability.unavailable);

  factory RichMessageAttachment.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'];
    final id = rawId is String && rawId.isNotEmpty ? rawId : null;
    return RichMessageAttachment(
      id: id,
      name: json['name'] as String? ?? 'file',
      size: (json['size'] as num?)?.toInt() ?? 0,
      availability: MessageAttachmentAvailability.values
          .asNameMap()[json['availability']],
      path: json['path'] as String?,
      url: json['url'] as String?,
    );
  }

  final String? id;
  final MessageAttachmentAvailability availability;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    ...super.toJson(),
    if (id != null) 'id': id,
    'availability': availability.name,
  };
}

/// Decodes cached messages and restores rich attachment identity/state. The
/// server history decoder constructs these same rows before they are cached.
Message richMessageFromJson(Map<String, dynamic> json) {
  final message = Message.fromJson(json);
  final rawAttachments = json['attachments'];
  if (rawAttachments is List) {
    message.attachments = <MessageAttachment>[
      for (final attachment in rawAttachments)
        if (attachment is Map)
          RichMessageAttachment.fromJson(Map<String, dynamic>.from(attachment)),
    ];
  }
  return message;
}

/// Signed attachment URLs are minted only on user activation, never persisted.
extension RichAttachmentActions on CloudRestClient {
  Future<MintedArtifactUrl> mintAttachmentCdnUrl(
    String sessionId,
    String attachmentId, {
    bool download = false,
  }) async {
    return MintedArtifactUrl.fromJson(
      await getJson(
        '/sessions/$sessionId/attachments/$attachmentId/cdn-url',
        query: <String, String>{if (download) 'download': '1'},
      ),
    );
  }
}

/// Bounded settled-content memoization keyed by stable message identity.
///
/// A streaming message never invokes [parser]: incomplete fences/tables must
/// not trigger rich parsing or highlighting on every delta. Content is part of
/// the entry check because live projection rows mutate in place before they
/// settle. The UI owns the typed parser; this core cache has no UI dependency.
final class SettledContentCache<T> {
  SettledContentCache({required this.parser, this.limit = 256})
    : assert(limit > 0);

  final List<T> Function(Message message) parser;
  final int limit;
  final Map<String, ({String content, List<T> blocks})> _entries =
      <String, ({String content, List<T> blocks})>{};

  List<T> blocksFor(Message message) {
    if (message.kind == MsgKind.streaming) {
      return List<T>.empty(growable: false);
    }
    final id = message.privateSyncId;
    final cached = _entries.remove(id);
    if (cached != null && cached.content == message.content) {
      _entries[id] = cached;
      return cached.blocks;
    }
    final parsed = parser(message);
    _entries[id] = (content: message.content, blocks: parsed);
    if (_entries.length > limit) _entries.remove(_entries.keys.first);
    return parsed;
  }
}

/// Native, offscreen PNG rendering for settled rich content.
abstract final class StaticRichContentRenderer {
  static const MethodChannel channel = MethodChannel(
    'ovid/static-rich-content',
  );

  /// Renders sanitized SVG to pixels. Sanitization deliberately happens before
  /// the platform call, so hostile input cannot reach a WebView at all.
  static Future<Uint8List> renderSvgPng(
    String svg, {
    String? requestId,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final sanitized = sanitizeStaticSvg(svg);
    return _render(
      'renderSvgPng',
      <String, Object?>{'svg': sanitized},
      requestId: requestId ?? _nextRequestId(),
      timeout: timeout,
    );
  }

  /// Renders Mermaid 11.4.1, vendored in the app, in Android's offline strict
  /// offscreen renderer. Source is data, never an interactive HTML document.
  static Future<Uint8List> renderMermaidPng(
    String source, {
    String? requestId,
    Duration timeout = const Duration(seconds: 15),
  }) {
    if (source.trim().isEmpty || source.length > 256 * 1024) {
      return Future<Uint8List>.error(
        const FormatException('Invalid Mermaid source'),
      );
    }
    return _render(
      'renderMermaidPng',
      <String, Object?>{'source': source},
      requestId: requestId ?? _nextRequestId(),
      timeout: timeout,
    );
  }

  static int _requestSequence = 0;
  static String _nextRequestId() {
    _requestSequence++;
    return 'static-rich-${DateTime.now().microsecondsSinceEpoch}-$_requestSequence';
  }

  static final Map<String, Completer<void>> _renderCancellations =
      <String, Completer<void>>{};

  static Future<bool> cancelRender(String requestId) async {
    final cancellation = _renderCancellations[requestId];
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.completeError(
        PlatformException(code: 'cancelled', message: 'Render cancelled'),
      );
    }
    try {
      final outcome = await channel.invokeMethod<dynamic>(
        'cancelRenderPng',
        <String, Object?>{'requestId': requestId},
      );
      if (outcome is! bool) {
        throw StateError(
          'Static renderer cancellation did not return a boolean outcome',
        );
      }
      return outcome;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // An unregistered renderer has no native work left to cancel.
      return false;
    }
  }

  static Future<Uint8List> _render(
    String method,
    Map<String, Object?> arguments, {
    required String requestId,
    required Duration timeout,
  }) async {
    final cancellation = Completer<void>();
    _renderCancellations[requestId] = cancellation;
    final dynamic result;
    try {
      result = await Future.any<dynamic>(<Future<dynamic>>[
        channel.invokeMethod<dynamic>(method, <String, Object?>{
          ...arguments,
          'requestId': requestId,
          'timeoutMs': timeout.inMilliseconds,
        }),
        cancellation.future,
      ]).timeout(timeout);
    } on TimeoutException {
      await cancelRender(requestId);
      rethrow;
    } finally {
      _renderCancellations.remove(requestId);
    }
    if (result is Uint8List && _hasPngSignature(result)) return result;
    if (result is List<int>) {
      final bytes = Uint8List.fromList(result);
      if (_hasPngSignature(bytes)) return bytes;
    }
    throw StateError('Static renderer did not return PNG pixels');
  }

  static bool _hasPngSignature(Uint8List bytes) =>
      bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x0a &&
      bytes[6] == 0x1a &&
      bytes[7] == 0x0a;
}
