/// Pure helpers for showing users where a link really goes.
///
/// Model and tool output is attacker-influenced (prompt injection through
/// web pages, MCP results and files), so every surface that opens a URL from
/// it, or shows the address of a page the agent navigated to, uses these to
/// display the real host: userinfo stripped (`https://bank.com@evil.tld`),
/// punycode decoded but flagged (`xn--pple-43d.com`), and the registrable
/// domain (eTLD+1) separated from the subdomains a phisher controls.
library;

/// A URL as it should be presented before opening it.
class SafeLink {
  /// The URL with any `user:pass@` part removed. This is what gets opened.
  final Uri uri;

  /// Host in ASCII (punycode) form, lowercased, without a trailing dot.
  final String asciiHost;

  /// Host with punycode labels decoded to Unicode.
  final String displayHost;

  /// True when the original URL carried userinfo (`something@host`), the
  /// classic trick for making `evil.tld` look like `bank.com`.
  final bool hadUserInfo;

  const SafeLink({
    required this.uri,
    required this.asciiHost,
    required this.displayHost,
    required this.hadUserInfo,
  });

  /// True when the host contains an internationalized (punycode) label, so
  /// the Unicode form may imitate another domain.
  bool get isIdn => asciiHost != displayHost;

  bool get isWeb => uri.scheme == 'http' || uri.scheme == 'https';

  /// The registrable domain (eTLD+1) of [displayHost].
  String get registrableDomain => registrableDomainOf(displayHost);
}

/// Parses [raw] into a [SafeLink], or null when it is not a usable absolute
/// URL. With [webOnly] (tool output), anything but http/https is rejected.
SafeLink? safeLinkFrom(String raw, {bool webOnly = false}) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || !uri.hasScheme) return null;
  final scheme = uri.scheme.toLowerCase();
  final web = scheme == 'http' || scheme == 'https';
  if (webOnly && !web) return null;
  if (web && uri.host.isEmpty) return null;
  final hadUserInfo = uri.userInfo.isNotEmpty;
  final clean = hadUserInfo ? _withoutUserInfo(uri) : uri;
  var host = clean.host.toLowerCase();
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  return SafeLink(
    uri: clean,
    asciiHost: host,
    displayHost: _displayHost(host),
    hadUserInfo: hadUserInfo,
  );
}

Uri _withoutUserInfo(Uri uri) => Uri(
  scheme: uri.scheme,
  host: uri.host,
  port: uri.hasPort ? uri.port : null,
  path: uri.path,
  query: uri.hasQuery ? uri.query : null,
  fragment: uri.hasFragment ? uri.fragment : null,
);

String _displayHost(String host) {
  var h = host;
  // Dart percent-encodes a raw Unicode host; show it decoded (it still
  // differs from the ASCII form, so it is flagged like a punycode host).
  if (h.contains('%')) {
    try {
      h = Uri.decodeComponent(h);
    } on ArgumentError {
      return host;
    }
  }
  return decodeIdnHost(h);
}

/// Decodes each `xn--` label of [host]; labels that fail to decode are kept
/// as-is (an undecodable label is shown in its raw, suspicious form).
String decodeIdnHost(String host) {
  if (!host.contains('xn--')) return host;
  return host
      .split('.')
      .map((label) {
        if (!label.startsWith('xn--')) return label;
        try {
          return punycodeDecode(label.substring(4));
        } on FormatException {
          return label;
        }
      })
      .join('.');
}

/// RFC 3492 punycode decoder for a single label (without the `xn--` prefix).
String punycodeDecode(String input) {
  const base = 36, tMin = 1, tMax = 26, initialBias = 72, initialN = 128;
  final output = <int>[];
  final b = input.lastIndexOf('-');
  if (b > 0) {
    for (final cu in input.substring(0, b).codeUnits) {
      if (cu >= 0x80) throw const FormatException('non-basic code point');
      output.add(cu);
    }
  }
  var i = 0, n = initialN, bias = initialBias;
  var pos = b > 0 ? b + 1 : 0;
  while (pos < input.length) {
    final oldI = i;
    var w = 1;
    for (var k = base; ; k += base) {
      if (pos >= input.length) throw const FormatException('truncated');
      final digit = _punyDigit(input.codeUnitAt(pos++));
      if (digit >= base) throw const FormatException('bad digit');
      i += digit * w;
      final t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias);
      if (digit < t) break;
      w *= base - t;
      if (w > 0x7fffffff) throw const FormatException('overflow');
    }
    bias = _punyAdapt(i - oldI, output.length + 1, oldI == 0);
    n += i ~/ (output.length + 1);
    if (n > 0x10ffff) throw const FormatException('overflow');
    i %= output.length + 1;
    output.insert(i, n);
    i++;
  }
  return String.fromCharCodes(output);
}

int _punyDigit(int cp) {
  if (cp >= 0x30 && cp <= 0x39) return cp - 22; // 0-9 → 26-35
  if (cp >= 0x41 && cp <= 0x5a) return cp - 0x41; // A-Z
  if (cp >= 0x61 && cp <= 0x7a) return cp - 0x61; // a-z
  return 36;
}

int _punyAdapt(int delta, int numPoints, bool first) {
  const base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700;
  delta = first ? delta ~/ damp : delta ~/ 2;
  delta += delta ~/ numPoints;
  var k = 0;
  while (delta > ((base - tMin) * tMax) ~/ 2) {
    delta ~/= base - tMin;
    k += base;
  }
  return k + ((base - tMin + 1) * delta) ~/ (delta + skew);
}

/// Common multi-label public suffixes. Not the full Public Suffix List, but
/// it covers the country second-level domains users meet most, so
/// `accounts.google.co.uk` reads as `google.co.uk`, not `co.uk`.
const _multiLabelSuffixes = <String>{
  'co.uk',
  'org.uk',
  'ac.uk',
  'gov.uk',
  'ltd.uk',
  'plc.uk',
  'me.uk',
  'co.in',
  'net.in',
  'org.in',
  'gov.in',
  'ac.in',
  'edu.in',
  'firm.in',
  'gen.in',
  'ind.in',
  'nic.in',
  'res.in',
  'com.au',
  'net.au',
  'org.au',
  'edu.au',
  'gov.au',
  'co.nz',
  'org.nz',
  'govt.nz',
  'co.jp',
  'ne.jp',
  'or.jp',
  'ac.jp',
  'go.jp',
  'co.kr',
  'or.kr',
  'com.br',
  'net.br',
  'gov.br',
  'com.cn',
  'net.cn',
  'org.cn',
  'gov.cn',
  'com.hk',
  'com.sg',
  'com.my',
  'com.tw',
  'com.mx',
  'com.ar',
  'com.tr',
  'com.sa',
  'com.pk',
  'com.bd',
  'com.np',
  'com.lk',
  'com.ng',
  'com.eg',
  'co.za',
  'co.id',
  'co.il',
  'co.th',
  'co.ke',
  'github.io',
  'gitlab.io',
  'pages.dev',
  'vercel.app',
  'netlify.app',
  'herokuapp.com',
  'web.app',
  'firebaseapp.com',
  'appspot.com',
  'blogspot.com',
  'azurewebsites.net',
  'cloudfront.net',
};

/// The registrable domain (eTLD+1) of [host]: the part a site owner
/// actually registered. IP literals and single-label hosts are returned
/// unchanged.
String registrableDomainOf(String host) {
  var h = host.toLowerCase();
  if (h.endsWith('.')) h = h.substring(0, h.length - 1);
  if (h.isEmpty || h.contains(':') || RegExp(r'^[\d.]+$').hasMatch(h)) {
    return h;
  }
  final labels = h.split('.');
  if (labels.length <= 2) return h;
  final lastTwo = labels.sublist(labels.length - 2).join('.');
  final take = _multiLabelSuffixes.contains(lastTwo) ? 3 : 2;
  if (labels.length <= take) return h;
  return labels.sublist(labels.length - take).join('.');
}

/// True when markdown link [text] claims a destination other than [link]'s
/// host: `[google.com](https://evil.example)`. Text that does not look like
/// a URL or domain at all ("docs", "click here") is not a claim.
bool linkTextMisleads(String text, SafeLink link) {
  final t = text.trim().toLowerCase();
  if (t.isEmpty) return false;
  final claimed = _claimedHost(t);
  if (claimed == null) return false;
  String strip(String h) => h.startsWith('www.') ? h.substring(4) : h;
  final real = strip(link.asciiHost);
  final realDisplay = strip(link.displayHost);
  final c = strip(claimed);
  return c != real && c != realDisplay;
}

String? _claimedHost(String text) {
  final withScheme = RegExp(r'^[a-z][a-z0-9+.-]*://').hasMatch(text)
      ? text
      : null;
  if (withScheme != null) {
    final u = Uri.tryParse(withScheme);
    if (u == null || u.host.isEmpty) return null;
    return u.host.toLowerCase();
  }
  final m = RegExp(
    r'^(?:www\.)?[\p{L}\p{N}-]+(?:\.[\p{L}\p{N}-]+)*\.[\p{L}]{2,}(?:[/:?#]\S*)?$',
    unicode: true,
  ).firstMatch(text);
  if (m == null) return null;
  final hostPart = text.split(RegExp(r'[/:?#]')).first;
  return hostPart;
}
