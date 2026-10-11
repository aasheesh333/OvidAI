/// Display/log scrubbing for MCP server launch details (M4).
///
/// MCP configs routinely carry credentials inline — `--api-key sk-…`,
/// `TOKEN=…` arguments, `https://user:pass@host`, `?token=…` query strings,
/// or a bearer token baked into a URL path (`/mcp/<key>/sse`). The real values
/// still reach the spawned process / HTTP request; everything a human, a log,
/// a diagnostic export or the model READS goes through these helpers first.
library;

/// Replacement for a scrubbed value.
const String kScrubbed = '[redacted]';

const _secretNameParts = {
  'token',
  'secret',
  'password',
  'passwd',
  'passphrase',
  'apikey',
  'accesskey',
  'privatekey',
  'authorization',
  'credential',
  'cookie',
  'signature',
  'bearer',
};

const _secretNamesExact = {
  'key',
  'pat',
  'sig',
  'pw',
  'pwd',
  'pass',
  'auth',
  'code',
  'session',
  'sessionid',
  'xapikey',
};

/// Whether a flag / env / query / header NAME denotes a secret value.
bool isSecretName(String name) {
  final n = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (n.isEmpty) return false;
  if (_secretNamesExact.contains(n)) return true;
  for (final part in _secretNameParts) {
    if (n.contains(part)) return true;
  }
  return n.endsWith('key') && n.length <= 12; // apikey-ish: x-key, appkey
}

/// Well-known credential shapes, redacted wherever they appear.
final List<RegExp> _tokenPatterns = [
  RegExp(r'\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}'),
  RegExp(r'\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}'),
  RegExp(r'\bgithub_pat_[A-Za-z0-9_]{20,}'),
  RegExp(r'\bglpat-[A-Za-z0-9_-]{20,}'),
  RegExp(r'\bxox[abposr]-[A-Za-z0-9-]{10,}'),
  RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
  RegExp(r'\bAIza[0-9A-Za-z_-]{35}\b'),
  RegExp(r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'),
  RegExp(r'\b(?:hf|npm|pypi)_[A-Za-z0-9]{20,}'),
];

final RegExp _bearer = RegExp(
  r'\b(bearer|basic)\s+[^\s,;"]+',
  caseSensitive: false,
);

/// A path segment that looks like an opaque credential: long, URL-safe, and
/// mixing letters with digits (so `my-long-descriptive-route-name` survives).
bool _looksLikeToken(String segment) {
  if (segment.length < 24) return false;
  if (!RegExp(r'^[A-Za-z0-9_.~-]+$').hasMatch(segment)) return false;
  return RegExp(r'[A-Za-z]').hasMatch(segment) &&
      RegExp(r'[0-9]').hasMatch(segment);
}

String _scrubTokens(String text) {
  var out = text.replaceAllMapped(_bearer, (m) => '${m.group(1)} $kScrubbed');
  for (final p in _tokenPatterns) {
    out = out.replaceAll(p, kScrubbed);
  }
  return out;
}

final RegExp _urlPattern = RegExp(r'''[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"'<>]+''');

/// [url] with credentials removed: userinfo, secret-named query/fragment
/// parameters, token-looking path segments and well-known token shapes.
/// Works on the raw string (no re-encoding), so an unparseable URL is still
/// scrubbed best-effort.
String scrubUrl(String url) {
  var out = url;
  // userinfo: scheme://user:pass@host → scheme://[redacted]@host
  out = out.replaceFirstMapped(
    RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*://)([^/?#@\s]+)@'),
    (m) => '${m.group(1)}$kScrubbed@',
  );
  // Split off query/fragment so path scrubbing never touches them.
  final cut = out.indexOf(RegExp(r'[?#]'));
  var head = cut < 0 ? out : out.substring(0, cut);
  var tail = cut < 0 ? '' : out.substring(cut);
  final authorityEnd = RegExp(
    r'^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]*',
  ).firstMatch(head);
  final prefix = authorityEnd?.group(0) ?? '';
  final path = head.substring(prefix.length);
  head =
      prefix +
      path.split('/').map((s) => _looksLikeToken(s) ? kScrubbed : s).join('/');
  tail = tail.replaceAllMapped(
    RegExp(r'([?&#;])([^=&#;]+)=([^&#;]*)'),
    (m) => isSecretName(_decodeSafe(m.group(2)!))
        ? '${m.group(1)}${m.group(2)}=$kScrubbed'
        : m.group(0)!,
  );
  return _scrubTokens(head + tail);
}

/// Decodes a query component, tolerating malformed escapes.
String _decodeSafe(String s) {
  try {
    return Uri.decodeQueryComponent(s);
  } catch (_) {
    return s;
  }
}

/// Every URL inside [text] scrubbed with [scrubUrl], plus known token shapes.
String scrubSecretsInText(String text) => _scrubTokens(
  text.replaceAllMapped(_urlPattern, (m) => scrubUrl(m.group(0)!)),
);

/// [args] with secret values replaced: `--token X` / `--api-key=X` /
/// `-H "Authorization: Bearer X"` / `TOKEN=X` forms, URLs inside arguments,
/// and well-known token shapes. Non-secret arguments are unchanged.
List<String> scrubArgs(List<String> args) {
  final out = <String>[];
  var redactNext = false;
  var headerNext = false;
  for (final arg in args) {
    if (redactNext) {
      out.add(kScrubbed);
      redactNext = false;
      continue;
    }
    if (headerNext) {
      out.add(_scrubHeader(arg));
      headerNext = false;
      continue;
    }
    final flag = RegExp(r'^(-{1,2})([A-Za-z0-9_.-]+)(=(.*))?$').firstMatch(arg);
    if (flag != null) {
      final name = flag.group(2)!;
      if (flag.group(3) != null) {
        out.add(
          isSecretName(name)
              ? '${flag.group(1)}$name=$kScrubbed'
              : '${flag.group(1)}$name=${scrubSecretsInText(flag.group(4)!)}',
        );
        continue;
      }
      out.add(arg);
      if (name == 'H' || name.toLowerCase() == 'header') {
        headerNext = true;
      } else if (isSecretName(name)) {
        redactNext = true;
      }
      continue;
    }
    final assignment = RegExp(
      r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$',
    ).firstMatch(arg);
    if (assignment != null && isSecretName(assignment.group(1)!)) {
      out.add('${assignment.group(1)}=$kScrubbed');
      continue;
    }
    if (RegExp(r'^[A-Za-z0-9_-]+\s*:\s*\S').hasMatch(arg) &&
        !arg.contains('://')) {
      out.add(_scrubHeader(arg));
      continue;
    }
    out.add(scrubSecretsInText(arg));
  }
  return out;
}

String _scrubHeader(String header) {
  final colon = header.indexOf(':');
  if (colon <= 0) return scrubSecretsInText(header);
  final name = header.substring(0, colon).trim();
  return isSecretName(name) ? '$name: $kScrubbed' : scrubSecretsInText(header);
}

/// `command arg…` for display, with [scrubArgs] applied.
String scrubCommandLine(String command, List<String> args) =>
    [command, ...scrubArgs(args)].where((p) => p.isNotEmpty).join(' ');
