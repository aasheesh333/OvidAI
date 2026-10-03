import 'dart:convert';
import 'dart:math';

/// Immutable, session-owned inline document. Persist source, never a WebView
/// controller or a URL into the browser/workspace. Only render_html creates it;
/// markdown HTML and plugin text remain inert.
class HtmlArtifact {
  static const maxPayloadBytes = 64 * 1024;
  static const maxSessionBytes = 512 * 1024;
  static const maxSessionArtifacts = 16;

  final String id;
  final String sessionId;
  final String title;
  final String html;
  final String css;
  final String javascript;
  final int height;

  const HtmlArtifact._({
    required this.id,
    required this.sessionId,
    required this.title,
    required this.html,
    required this.css,
    required this.javascript,
    required this.height,
  });

  factory HtmlArtifact.create(String sessionId, Map<String, dynamic> args) {
    if (sessionId.isEmpty || sessionId.length > 200) {
      throw const FormatException('A valid owning session is required.');
    }
    const keys = {'title', 'html', 'css', 'javascript', 'height'};
    if (args.keys.any((key) => !keys.contains(key))) {
      throw const FormatException('Unsupported render_html argument.');
    }
    String text(String key, String fallback) {
      final value = args[key] ?? fallback;
      if (value is! String) throw FormatException('$key must be a string.');
      // Check before encoding to avoid allocating arbitrarily large buffers.
      if (value.length > maxPayloadBytes) {
        throw const FormatException('Artifact exceeds 64 KiB.');
      }
      return value;
    }

    final html = text('html', '');
    final css = text('css', '');
    final js = text('javascript', '');
    final title = text('title', 'Interactive artifact').trim();
    if (html.trim().isEmpty) throw const FormatException('html is required.');
    if (title.isEmpty || title.length > 120) {
      throw const FormatException('title must contain 1–120 characters.');
    }
    final height = args['height'] ?? 320;
    if (height is! int) {
      throw const FormatException('height must be an integer.');
    }
    if (utf8.encode('$title$html$css$js').length > maxPayloadBytes) {
      throw const FormatException('Artifact exceeds 64 KiB (UTF-8).');
    }
    final random = Random.secure();
    return HtmlArtifact._(
      id: List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
      sessionId: sessionId,
      title: title,
      html: html,
      css: css,
      javascript: js,
      height: height.clamp(160, 640),
    );
  }

  int get payloadBytes => utf8.encode('$title$html$css$javascript').length;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'sessionId': sessionId,
    'title': title,
    'html': html,
    'css': css,
    'javascript': javascript,
    'height': height,
  };

  /// Corrupt/unsupported persisted artifacts fail closed; the host shows a
  /// fallback rather than executing partial or unbounded source.
  static HtmlArtifact? tryFromJson(Object? value) {
    if (value is! Map || value['version'] != 1) return null;
    final owner = value['sessionId'];
    final id = value['id'];
    if (owner is! String ||
        id is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      return null;
    }
    try {
      final parsed = HtmlArtifact.create(owner, {
        for (final key in ['title', 'html', 'css', 'javascript', 'height'])
          key: value[key],
      });
      return HtmlArtifact._(
        id: id,
        sessionId: owner,
        title: parsed.title,
        html: parsed.html,
        css: parsed.css,
        javascript: parsed.javascript,
        height: parsed.height,
      );
    } on FormatException {
      return null;
    }
  }

  /// An opaque-origin srcdoc frame, with scripts but NO same-origin privilege.
  /// The trusted wrapper has no message listener, JS bridge or user source.
  /// CSP applies before any user markup (including CSS/JS closing-tag tricks).
  /// Native WebView policy ALSO denies every navigation/resource request.
  String get sandboxDocument {
    const policy =
        "default-src 'none'; script-src 'unsafe-inline'; "
        "style-src 'unsafe-inline'; img-src data:; font-src data:; "
        "connect-src 'none'; frame-src 'none'; worker-src 'none'; "
        "object-src 'none'; base-uri 'none'; form-action 'none'; "
        "media-src 'none'; manifest-src 'none'";
    final inner =
        '<!doctype html><html><head><meta charset="utf-8">'
        '<meta http-equiv="Content-Security-Policy" content="$policy">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>html{color-scheme:light}body{margin:12px;overflow-wrap:anywhere}'
        'img,svg,canvas{max-width:100%}$css</style></head>'
        '<body>$html<script>$javascript</script></body></html>';
    final escaped = const HtmlEscape(HtmlEscapeMode.attribute).convert(inner);
    return '<!doctype html><html><head><meta charset="utf-8">'
        '<meta http-equiv="Content-Security-Policy" content="'
        "default-src 'none'; frame-src about:; script-src 'unsafe-inline'; "
        "style-src 'unsafe-inline'; img-src data:; font-src data:; "
        "base-uri 'none'; form-action 'none'\">"
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>html,body{margin:0;width:100%;height:100%;overflow:hidden}'
        'iframe{border:0;width:100%;height:100%;background:white}</style>'
        '</head><body><iframe sandbox="allow-scripts" '
        'referrerpolicy="no-referrer" srcdoc="$escaped"></iframe></body></html>';
  }
}
