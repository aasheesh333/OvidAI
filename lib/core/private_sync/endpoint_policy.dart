/// Provider endpoint validation and canonicalization for private account sync.
///
/// Endpoint values are portable metadata, not arbitrary URLs. This validator
/// admits only absolute `https` (or explicitly allowed `http`) URLs with no
/// userinfo, fragment, control characters, or credential-shaped query keys,
/// and returns a canonical credential-free identity string.
///
/// Pure data code: no Flutter UI, HTTP, app state, or executable imports.
library;

/// Maximum canonical endpoint length in bytes (ASCII), per the v1 DTO bound.
const int maxEndpointBytes = 2048;

/// Classified reason for an endpoint rejection.
enum EndpointRejection {
  length,
  character,
  syntax,
  scheme,
  userinfo,
  fragment,
  host,
  port,
  credentialQuery,
}

const _messages = <EndpointRejection, String>{
  EndpointRejection.length: 'endpoint too long',
  EndpointRejection.character: 'endpoint contains a disallowed character',
  EndpointRejection.syntax: 'endpoint is not a valid absolute URL',
  EndpointRejection.scheme: 'endpoint scheme is not allowed',
  EndpointRejection.userinfo: 'endpoint must not contain userinfo',
  EndpointRejection.fragment: 'endpoint must not contain a fragment',
  EndpointRejection.host: 'endpoint host is invalid',
  EndpointRejection.port: 'endpoint port is invalid',
  EndpointRejection.credentialQuery:
      'endpoint query contains a credential-shaped parameter',
};

/// Rejection with a fixed, input-free message.
class EndpointRejectedException extends FormatException {
  EndpointRejectedException(this.reason) : super(_messages[reason]!);

  final EndpointRejection reason;

  @override
  String toString() => 'EndpointRejectedException: $message';
}

/// Normalized (lowercase, alphanumeric-only) query keys that are always
/// treated as credentials.
const _credentialKeysExact = <String>{
  'sig',
  'pwd',
  'jwt',
  'pass',
  'otp',
};

/// Normalized substrings that make a query key credential-shaped. Matching is
/// deliberately broad: false positives fail closed and can be lifted by an
/// explicit provider policy.
const _credentialKeyFragments = <String>[
  'key',
  'token',
  'secret',
  'auth',
  'password',
  'passwd',
  'credential',
  'signature',
  'session',
  'cookie',
  'bearer',
  'passw',
  'pwd',
  'sig',
  'jwt',
];

final _secretValues = RegExp(
  r'sk-[A-Za-z0-9_\-]{16,}'
  r'|AKIA[0-9A-Z]{16}'
  r'|gh[pousr]_[A-Za-z0-9]{20,}'
  r'|AIza[0-9A-Za-z_\-]{30,}'
  r'|xox[abprs]-[A-Za-z0-9\-]{10,}'
  r'|eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+',
);

void _checkSecretValue(String value) {
  final decoded = _fullyDecodeKey(value);
  if (_secretValues.hasMatch(decoded) ||
      RegExp(r'bearer\s', caseSensitive: false).hasMatch(decoded)) {
    _reject(EndpointRejection.credentialQuery);
  }
}

/// Provider-specific credential query keys (normalized form).
const _providerCredentialKeys = <String, Set<String>>{
  // Azure Functions style `?code=` function keys.
  'azure': {'code'},
  'azureopenai': {'code'},
};

const _supportedSchemes = <String, int>{'https': 443, 'http': 80};

/// Validates [value] and returns its canonical credential-free form.
///
/// [allowedSchemes] defaults to `https` only; adding `http` is an explicit
/// provider policy. [nonSecretQueryKeys] lists decoded query keys that a
/// provider policy has proven non-secret (compared case-insensitively).
///
/// Throws [EndpointRejectedException] on any violation.
String canonicalProviderEndpoint(
  String value,
  String providerId, {
  Set<String> allowedSchemes = const {'https'},
  Set<String> nonSecretQueryKeys = const {},
}) {
  for (var i = 0; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    if (c <= 0x20 || c >= 0x7F) _reject(EndpointRejection.character);
  }
  if (value.length > maxEndpointBytes) _reject(EndpointRejection.length);
  if (value.contains('#')) _reject(EndpointRejection.fragment);

  // scheme ":" "//" authority path-abempty [ "?" query ]
  final colon = value.indexOf(':');
  if (colon <= 0) _reject(EndpointRejection.syntax);
  final rawScheme = value.substring(0, colon);
  if (!RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*$').hasMatch(rawScheme)) {
    _reject(EndpointRejection.syntax);
  }
  final scheme = rawScheme.toLowerCase();
  final allowed = allowedSchemes.map((s) => s.toLowerCase()).toSet();
  if (!_supportedSchemes.containsKey(scheme) || !allowed.contains(scheme)) {
    _reject(EndpointRejection.scheme);
  }
  if (!value.startsWith('//', colon + 1)) _reject(EndpointRejection.syntax);

  final authorityStart = colon + 3;
  var authorityEnd = value.length;
  for (var i = authorityStart; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    if (c == 0x2F || c == 0x3F) {
      authorityEnd = i;
      break;
    }
  }
  final authority = value.substring(authorityStart, authorityEnd);
  if (authority.contains('@')) _reject(EndpointRejection.userinfo);

  final hostAndPort = _parseAuthority(authority, _supportedSchemes[scheme]!);

  final rest = value.substring(authorityEnd);
  final question = rest.indexOf('?');
  final rawPath = question >= 0 ? rest.substring(0, question) : rest;
  final rawQuery = question >= 0 ? rest.substring(question + 1) : '';

  final path = _canonicalPath(rawPath);
  final query = _canonicalQuery(rawQuery, providerId, nonSecretQueryKeys);

  final result = StringBuffer()
    ..write(scheme)
    ..write('://')
    ..write(hostAndPort)
    ..write(path);
  if (query.isNotEmpty) {
    result
      ..write('?')
      ..write(query);
  }
  final canonical = result.toString();
  if (canonical.length > maxEndpointBytes) _reject(EndpointRejection.length);
  return canonical;
}

/// True when [value] is valid and already in canonical form.
bool isCanonicalProviderEndpoint(
  String value,
  String providerId, {
  Set<String> allowedSchemes = const {'https'},
  Set<String> nonSecretQueryKeys = const {},
}) {
  try {
    return canonicalProviderEndpoint(
          value,
          providerId,
          allowedSchemes: allowedSchemes,
          nonSecretQueryKeys: nonSecretQueryKeys,
        ) ==
        value;
  } on EndpointRejectedException {
    return false;
  }
}

Never _reject(EndpointRejection reason) =>
    throw EndpointRejectedException(reason);

String _parseAuthority(String authority, int defaultPort) {
  String host;
  String? portText;
  if (authority.startsWith('[')) {
    final close = authority.indexOf(']');
    if (close < 0) _reject(EndpointRejection.host);
    host = _canonicalIpv6(authority.substring(1, close));
    final after = authority.substring(close + 1);
    if (after.isNotEmpty) {
      if (!after.startsWith(':')) _reject(EndpointRejection.host);
      portText = after.substring(1);
    }
  } else {
    final colon = authority.lastIndexOf(':');
    if (colon >= 0) {
      host = authority.substring(0, colon);
      portText = authority.substring(colon + 1);
    } else {
      host = authority;
    }
    host = _canonicalRegName(host);
  }

  var port = defaultPort;
  if (portText != null) {
    if (portText.isEmpty || !RegExp(r'^[0-9]{1,5}$').hasMatch(portText)) {
      _reject(EndpointRejection.port);
    }
    port = int.parse(portText);
    if (port < 1 || port > 65535) _reject(EndpointRejection.port);
  }
  return port == defaultPort ? host : '$host:$port';
}

String _canonicalRegName(String host) {
  if (host.isEmpty || host.length > 253) _reject(EndpointRejection.host);
  final lower = host.toLowerCase();
  final labels = lower.split('.');
  final label = RegExp(r'^[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?$');
  for (final part in labels) {
    if (!label.hasMatch(part)) _reject(EndpointRejection.host);
  }
  // A numeric final label means the host is an IPv4 address per the WHATWG
  // URL host parser; only strict dotted-quad form is accepted to avoid
  // ambiguous octal/hex/short forms.
  if (RegExp(r'^[0-9]+$').hasMatch(labels.last)) {
    if (labels.length != 4) _reject(EndpointRejection.host);
    for (final part in labels) {
      if (!RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part) ||
          int.parse(part) > 255) {
        _reject(EndpointRejection.host);
      }
    }
  }
  return lower;
}

String _canonicalIpv6(String literal) {
  List<int> bytes;
  try {
    bytes = Uri.parseIPv6Address(literal);
  } on FormatException {
    _reject(EndpointRejection.host);
  }
  if (bytes.length != 16) _reject(EndpointRejection.host);
  final groups = List<int>.generate(8, (i) => (bytes[2 * i] << 8) | bytes[2 * i + 1]);
  // RFC 5952: compress the longest run (>= 2) of zero groups, first on ties.
  var bestStart = -1;
  var bestLength = 0;
  for (var i = 0; i < 8;) {
    if (groups[i] != 0) {
      i++;
      continue;
    }
    var j = i;
    while (j < 8 && groups[j] == 0) {
      j++;
    }
    if (j - i > bestLength && j - i >= 2) {
      bestStart = i;
      bestLength = j - i;
    }
    i = j;
  }
  String hex(Iterable<int> parts) =>
      parts.map((g) => g.toRadixString(16)).join(':');
  if (bestStart < 0) return '[${hex(groups)}]';
  final head = hex(groups.sublist(0, bestStart));
  final tail = hex(groups.sublist(bestStart + bestLength));
  return '[$head::$tail]';
}

bool _isUnreserved(int c) =>
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    (c >= 0x30 && c <= 0x39) ||
    c == 0x2D ||
    c == 0x2E ||
    c == 0x5F ||
    c == 0x7E;

/// sub-delims / ":" / "@" (RFC 3986 pchar minus unreserved and pct-encoded).
bool _isPcharExtra(int c) => "!\$&'()*+,;=:@".codeUnits.contains(c);

int _hexValue(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  return -1;
}

/// Normalizes percent-encoding in one component: decodes unreserved octets,
/// uppercases the rest, and rejects encoded control or non-ASCII octets.
/// [extraAllowed] lists raw delimiter characters permitted in the component.
String _normalizePercent(String component, String extraAllowed) {
  final out = StringBuffer();
  for (var i = 0; i < component.length; i++) {
    final c = component.codeUnitAt(i);
    if (c == 0x25) {
      if (i + 2 >= component.length) _reject(EndpointRejection.syntax);
      final hi = _hexValue(component.codeUnitAt(i + 1));
      final lo = _hexValue(component.codeUnitAt(i + 2));
      if (hi < 0 || lo < 0) _reject(EndpointRejection.syntax);
      final octet = (hi << 4) | lo;
      if (octet < 0x20 || octet >= 0x7F) _reject(EndpointRejection.character);
      if (_isUnreserved(octet)) {
        out.writeCharCode(octet);
      } else {
        out
          ..write('%')
          ..write(octet.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
      i += 2;
    } else if (_isUnreserved(c) ||
        _isPcharExtra(c) ||
        extraAllowed.codeUnits.contains(c)) {
      out.writeCharCode(c);
    } else {
      _reject(EndpointRejection.syntax);
    }
  }
  return out.toString();
}

String _canonicalPath(String rawPath) {
  if (rawPath.isEmpty) return '/';
  final normalized = _normalizePercent(rawPath, '/');
  _checkSecretValue(normalized);
  for (final segment in _fullyDecodeKey(normalized).split('/')) {
    for (final parameter in segment.split(';').skip(1)) {
      if (_isCredentialKey(parameter.split('=').first, const {})) {
        _reject(EndpointRejection.credentialQuery);
      }
    }
  }
  return _removeDotSegments(normalized);
}

/// RFC 3986 section 5.2.4.
String _removeDotSegments(String path) {
  final segments = path.split('/');
  final output = <String>[];
  // segments[0] is '' for an absolute path.
  for (var i = 1; i < segments.length; i++) {
    final segment = segments[i];
    final last = i == segments.length - 1;
    if (segment == '.') {
      if (last) output.add('');
    } else if (segment == '..') {
      if (output.isNotEmpty) output.removeLast();
      if (last) output.add('');
    } else {
      output.add(segment);
    }
  }
  return '/${output.join('/')}';
}

String _canonicalQuery(
  String rawQuery,
  String providerId,
  Set<String> nonSecretQueryKeys,
) {
  if (rawQuery.isEmpty) return '';
  final allowList = nonSecretQueryKeys.map((k) => k.toLowerCase()).toSet();
  final providerKeys = _providerCredentialKeys[
          providerId.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')] ??
      const <String>{};
  final parts = <String>[];
  for (final part in rawQuery.split('&')) {
    if (part.isEmpty) continue;
    final normalized = _normalizePercent(part, '/?');
    final eq = part.indexOf('=');
    final rawKey = eq >= 0 ? part.substring(0, eq) : part;
    final decodedKey = _fullyDecodeKey(rawKey);
    _checkSecretValue(rawKey);
    if (eq >= 0) _checkSecretValue(part.substring(eq + 1));
    if (!allowList.contains(decodedKey.toLowerCase()) &&
        _isCredentialKey(decodedKey, providerKeys)) {
      _reject(EndpointRejection.credentialQuery);
    }
    parts.add(normalized);
  }
  return parts.join('&');
}

/// Repeatedly percent-decodes a query key (catching double encoding) and
/// treats `+` as a space, as form decoding would.
String _fullyDecodeKey(String rawKey) {
  var current = rawKey.replaceAll('+', ' ');
  for (var round = 0; round < 8; round++) {
    final next = _percentDecodeLenient(current.replaceAll('+', ' '));
    if (next.codeUnits.any((unit) => unit < 0x20 || unit >= 0x7f)) {
      _reject(EndpointRejection.character);
    }
    if (next == current) return current;
    current = next;
  }
  // Pathologically nested encoding is treated as credential-shaped.
  _reject(EndpointRejection.credentialQuery);
}

String _percentDecodeLenient(String value) {
  final out = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    if (c == 0x25 && i + 2 < value.length) {
      final hi = _hexValue(value.codeUnitAt(i + 1));
      final lo = _hexValue(value.codeUnitAt(i + 2));
      if (hi >= 0 && lo >= 0) {
        out.writeCharCode((hi << 4) | lo);
        i += 2;
        continue;
      }
    }
    out.writeCharCode(c);
  }
  return out.toString();
}

bool _isCredentialKey(String decodedKey, Set<String> providerKeys) {
  final normalized =
      decodedKey.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (_credentialKeysExact.contains(normalized)) return true;
  if (providerKeys.contains(normalized)) return true;
  for (final fragment in _credentialKeyFragments) {
    if (normalized.contains(fragment)) return true;
  }
  return false;
}
