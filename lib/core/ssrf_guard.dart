import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Resolves a host name to every address it maps to.
typedef SsrfHostResolver = Future<List<InternetAddress>> Function(String host);

/// Address classification and DNS-resolving SSRF checks (M3).
///
/// A literal-only check ("is the host string 10.x?") is walked around by any
/// name that RESOLVES to an internal address — a public DNS record pointing
/// at `127.0.0.1`, `169.254.169.254` or an IPv4-mapped IPv6 address. These
/// helpers resolve the name and refuse when ANY returned address is
/// non-public, so a mixed record set cannot slip one internal target in.
///
/// Remaining limit (documented, not solved here): the HTTP stack resolves
/// again when it connects, so a rebinding resolver with a near-zero TTL can
/// still swap answers between the check and the connect.
class SsrfGuard {
  SsrfGuard._();

  /// Test seam. When set, replaces system DNS. Under `flutter test` the
  /// default is NO resolution (host tests must not touch real DNS, and a
  /// real lookup never completes inside a fake-async widget test) — literal
  /// address checks still apply; tests that exercise the DNS stage install
  /// a resolver here.
  @visibleForTesting
  static SsrfHostResolver? resolverForTest;

  static final bool _underFlutterTest =
      Platform.environment['FLUTTER_TEST'] == 'true';

  static const Duration _lookupTimeout = Duration(seconds: 4);

  static SsrfHostResolver? get _resolver {
    final override = resolverForTest;
    if (override != null) return override;
    if (_underFlutterTest) return null;
    return (host) => InternetAddress.lookup(host).timeout(_lookupTimeout);
  }

  /// True for every address an agent or plugin fetch must never reach:
  ///
  /// IPv4 `0.0.0.0/8`, `10/8`, `100.64/10` (CGNAT, incl. Alibaba metadata
  /// `100.100.100.200`), `127/8`, `169.254/16` (link-local / cloud
  /// metadata), `172.16/12`, `192.0.0/24`, `192.168/16`, `198.18/15`,
  /// multicast `224/4`, reserved `240/4` and broadcast.
  ///
  /// IPv6 unspecified `::`, loopback `::1`, ULA `fc00::/7`, link-local
  /// `fe80::/10`, deprecated site-local `fec0::/10`, multicast `ff00::/8`,
  /// and every IPv6 form that embeds an IPv4 address — mapped
  /// `::ffff:a.b.c.d`, compatible `::a.b.c.d`, NAT64 `64:ff9b::/96` and
  /// 6to4 `2002::/16` — classified by the embedded IPv4.
  static bool isNonPublicAddress(InternetAddress address) {
    final b = address.rawAddress;
    if (b.length == 4) return _isNonPublicIpv4(b);
    if (b.length != 16) return true;
    var allZeroPrefix = true;
    for (var i = 0; i < 10; i++) {
      if (b[i] != 0) {
        allZeroPrefix = false;
        break;
      }
    }
    if (allZeroPrefix) {
      // ::ffff:a.b.c.d (mapped) and ::a.b.c.d (compatible; also covers
      // :: and ::1, whose embedded "IPv4" is 0.0.0.0 / 0.0.0.1).
      if ((b[10] == 0xff && b[11] == 0xff) || (b[10] == 0 && b[11] == 0)) {
        return _isNonPublicIpv4(b.sublist(12));
      }
    }
    // NAT64 well-known prefix 64:ff9b::/96.
    if (b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b) {
      var zeros = true;
      for (var i = 4; i < 12; i++) {
        if (b[i] != 0) zeros = false;
      }
      if (zeros) return _isNonPublicIpv4(b.sublist(12));
    }
    // 6to4 2002:AABB:CCDD::/48 embeds AA.BB.CC.DD.
    if (b[0] == 0x20 && b[1] == 0x02) return _isNonPublicIpv4(b.sublist(2, 6));
    if ((b[0] & 0xfe) == 0xfc) return true; // fc00::/7 ULA
    if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return true; // fe80::/10
    if (b[0] == 0xfe && (b[1] & 0xc0) == 0xc0) return true; // fec0::/10
    if (b[0] == 0xff) return true; // multicast
    return false;
  }

  static bool _isNonPublicIpv4(List<int> b) {
    final a0 = b[0], a1 = b[1];
    if (a0 == 0) return true;
    if (a0 == 10) return true;
    if (a0 == 100 && a1 >= 64 && a1 <= 127) return true;
    if (a0 == 127) return true;
    if (a0 == 169 && a1 == 254) return true;
    if (a0 == 172 && a1 >= 16 && a1 <= 31) return true;
    if (a0 == 192 && a1 == 0 && b[2] == 0) return true;
    if (a0 == 192 && a1 == 168) return true;
    if (a0 == 198 && (a1 == 18 || a1 == 19)) return true;
    if (a0 >= 224) return true; // multicast, reserved, broadcast
    return false;
  }

  /// Link-local / cloud-metadata only: `169.254/16`, `fe80::/10`, Alibaba
  /// `100.100.100.200`, and their IPv4-embedding IPv6 forms. Used where
  /// loopback and LAN stay legitimate (behind a host prompt) but metadata
  /// must be refused in every mode.
  static bool isMetadataOrLinkLocalAddress(InternetAddress address) {
    List<int> b = address.rawAddress;
    if (b.length == 16) {
      if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return true;
      final embedded = _embeddedIpv4(b);
      if (embedded == null) return false;
      b = embedded;
    }
    if (b.length != 4) return false;
    if (b[0] == 169 && b[1] == 254) return true;
    return b[0] == 100 && b[1] == 100 && b[2] == 100 && b[3] == 200;
  }

  static List<int>? _embeddedIpv4(List<int> b) {
    var zeros = true;
    for (var i = 0; i < 10; i++) {
      if (b[i] != 0) zeros = false;
    }
    if (zeros &&
        ((b[10] == 0xff && b[11] == 0xff) || (b[10] == 0 && b[11] == 0))) {
      return b.sublist(12);
    }
    if (b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b) {
      return b.sublist(12);
    }
    if (b[0] == 0x20 && b[1] == 0x02) return b.sublist(2, 6);
    return null;
  }

  /// Strips IPv6 brackets and a trailing dot.
  static String _bareHost(String host) {
    var h = host.trim().toLowerCase();
    if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
    while (h.endsWith('.')) {
      h = h.substring(0, h.length - 1);
    }
    return h;
  }

  /// Resolves [host] (a literal resolves to itself) and returns every
  /// address, or null when no resolver is active or resolution failed — a
  /// name that does not resolve cannot be connected to either.
  static Future<List<InternetAddress>?> _resolve(String host) async {
    final bare = _bareHost(host);
    if (bare.isEmpty) return null;
    final literal = InternetAddress.tryParse(bare);
    if (literal != null) return [literal];
    final resolver = _resolver;
    if (resolver == null) return null;
    try {
      return await resolver(bare);
    } catch (_) {
      return null;
    }
  }

  /// Why [host] must not be fetched, or null when every address it resolves
  /// to is public. Refuses `localhost`/`*.localhost` by name.
  static Future<String?> nonPublicHostReason(String host) async {
    final bare = _bareHost(host);
    if (bare == 'localhost' || bare.endsWith('.localhost')) {
      return 'host "$host" is a loopback name';
    }
    final addresses = await _resolve(bare) ?? const <InternetAddress>[];
    for (final a in addresses) {
      if (isNonPublicAddress(a)) {
        return 'host "$host" resolves to a non-public address (${a.address})';
      }
    }
    return null;
  }

  /// True when [host] resolves to ANY link-local / cloud-metadata address.
  static Future<bool> resolvesToMetadataOrLinkLocal(String host) async {
    final addresses = await _resolve(host) ?? const <InternetAddress>[];
    return addresses.any(isMetadataOrLinkLocalAddress);
  }
}
