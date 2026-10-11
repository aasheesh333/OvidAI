/// TLS certificate pinning for Ovid's own backend (M7) — OFF by default.
///
/// Wrong pins brick every backend call (sign-in, cloud chat, sharing,
/// billing) with no in-app recovery, so this ships disabled with an EMPTY pin
/// set. Enabling it is an owner action:
///
/// TODO(owner): before enabling, fill [kOvidSpkiPins] and build with
///   `--dart-define=OVID_CERT_PINNING=true`.
///   1. Pins are base64(SHA-256(SubjectPublicKeyInfo)) of the LEAF
///      certificate key, because dart:io exposes only the peer (leaf)
///      certificate, not the chain. Get the live one with:
///        openssl s_client -connect api.ovidsi.com:443 -servername api.ovidsi.com </dev/null \
///          | openssl x509 -pubkey -noout \
///          | openssl pkey -pubin -outform der \
///          | openssl dgst -sha256 -binary | openssl base64
///      (repeat for ovidsi.com).
///   2. Always ship at least TWO pins per host: the current key AND a backup
///      key generated now and kept offline (pin it via its CSR:
///        openssl req -in backup.csr -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl base64).
///   3. Let's Encrypt: renewals generate a NEW key unless the cert is renewed
///      with the same key (certbot `--reuse-key`, or the equivalent in Caddy's
///      storage). Without that, every 60-90 day renewal breaks the pin.
///   4. Cloudflare-proxied hosts present Cloudflare's edge certificate, whose
///      key Cloudflare rotates on its own schedule — leaf pinning is NOT
///      viable there (Cloudflare advises against pinning). Only pin hosts
///      whose TLS terminates on a key you control, or use a Cloudflare
///      custom certificate with a key you own.
///   5. Roll out pins one release ahead of any key change, and keep the
///      backup pin current.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'diag.dart';

/// Compile-time switch; default OFF. See the library TODO before enabling.
const bool kCertPinningEnabled = bool.fromEnvironment(
  'OVID_CERT_PINNING',
  defaultValue: false,
);

/// host → accepted base64 SHA-256 SPKI pins (current key + backup keys).
///
/// TODO(owner): intentionally EMPTY. A host with no pins is NOT pinned (fail
/// open) so an accidental enable without pins cannot brick the app.
const Map<String, List<String>> kOvidSpkiPins = {
  'api.ovidsi.com': <String>[
    // 'BASE64_SHA256_OF_CURRENT_LEAF_SPKI=',
    // 'BASE64_SHA256_OF_BACKUP_KEY_SPKI=',
  ],
  'ovidsi.com': <String>[
    // 'BASE64_SHA256_OF_CURRENT_LEAF_SPKI=',
    // 'BASE64_SHA256_OF_BACKUP_KEY_SPKI=',
  ],
};

/// Thrown (as the connection error) when a pinned host presents a key that
/// matches none of its pins. No request bytes have been sent at that point.
class CertificatePinException extends HandshakeException {
  CertificatePinException(String host)
    : super('Certificate pin mismatch for $host');
}

/// Pin checks for an explicit pin table (production uses [kOvidSpkiPins]).
class CertPinning {
  CertPinning(this.pins);

  final Map<String, List<String>> pins;

  /// Pins for [host] (exact match, case-insensitive), or null when the host
  /// is not pinned — including a pinned host whose pin list is empty.
  List<String>? pinsFor(String host) {
    final list = pins[host.toLowerCase()];
    return list == null || list.isEmpty ? null : list;
  }

  /// Whether [certificate]'s SPKI hash is one of [host]'s pins (true for
  /// unpinned hosts).
  bool accepts(String host, X509Certificate? certificate) {
    final expected = pinsFor(host);
    if (expected == null) return true;
    if (certificate == null) return false;
    final actual = spkiSha256Base64(certificate.der);
    return actual != null && expected.contains(actual);
  }

  /// Installs a connection factory on [client] that verifies pinned hosts
  /// right after the TLS handshake — before any request byte is written.
  /// Unpinned hosts connect exactly as dart:io would (same [context], same
  /// proxy handling). A pinned host is never reached through a proxy tunnel:
  /// the pin could not be checked there, so that connection fails closed.
  void install(HttpClient client, {SecurityContext? context}) {
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final https = uri.scheme == 'https';
      final port = uri.hasPort ? uri.port : (https ? 443 : 80);
      final pinned = https && pinsFor(uri.host) != null;
      if (proxyHost != null && proxyPort != null) {
        if (pinned) throw CertificatePinException(uri.host);
        return Socket.startConnect(proxyHost, proxyPort);
      }
      if (!pinned) {
        return https
            ? SecureSocket.startConnect(uri.host, port, context: context)
            : Socket.startConnect(uri.host, port);
      }
      final task = await SecureSocket.startConnect(
        uri.host,
        port,
        context: context,
      );
      final checked = task.socket.then<Socket>((socket) {
        if (accepts(uri.host, socket.peerCertificate)) return socket;
        socket.destroy();
        Diag.swallow('cert_pinning', 'pin mismatch for ${uri.host}');
        throw CertificatePinException(uri.host);
      });
      return ConnectionTask.fromSocket(checked, task.cancel);
    };
  }
}

/// Applies [CertPinning] to every dart:io [HttpClient] the app creates
/// (package:http's default client included).
class OvidPinningHttpOverrides extends HttpOverrides {
  OvidPinningHttpOverrides(this.pinning);

  final CertPinning pinning;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    pinning.install(client, context: context);
    return client;
  }
}

/// Call once at startup. No-op unless [kCertPinningEnabled] AND at least one
/// host has pins.
void installOvidCertificatePinning() {
  if (!kCertPinningEnabled) return;
  final pinning = CertPinning(kOvidSpkiPins);
  if (!kOvidSpkiPins.keys.any((h) => pinning.pinsFor(h) != null)) {
    Diag.swallow(
      'cert_pinning',
      'OVID_CERT_PINNING is on but no pins are configured — not pinning',
    );
    return;
  }
  HttpOverrides.global = OvidPinningHttpOverrides(pinning);
}

/// base64(SHA-256(SubjectPublicKeyInfo)) of a DER X.509 certificate, or null
/// when the DER does not parse. SPKI is the 7th element of tbsCertificate
/// (6th when the explicit [0] version is absent).
String? spkiSha256Base64(Uint8List der) {
  final spki = extractSpki(der);
  return spki == null ? null : base64.encode(sha256.convert(spki).bytes);
}

/// The raw DER bytes (tag+length+value) of the certificate's
/// SubjectPublicKeyInfo.
@visibleForTesting
Uint8List? extractSpki(Uint8List der) {
  try {
    final cert = _Der.read(der, 0);
    if (cert.tag != 0x30) return null;
    final tbs = _Der.read(der, cert.contentStart);
    if (tbs.tag != 0x30) return null;
    var offset = tbs.contentStart;
    var element = _Der.read(der, offset);
    if (element.tag == 0xa0) {
      offset = element.end; // explicit version
      element = _Der.read(der, offset);
    }
    // serialNumber, signature, issuer, validity, subject.
    for (var i = 0; i < 5; i++) {
      offset = element.end;
      element = _Der.read(der, offset);
    }
    if (element.tag != 0x30 || element.end > tbs.end) return null;
    return Uint8List.sublistView(der, element.start, element.end);
  } catch (_) {
    return null;
  }
}

class _Der {
  _Der(this.tag, this.start, this.contentStart, this.end);

  final int tag;
  final int start;
  final int contentStart;
  final int end;

  static _Der read(Uint8List b, int offset) {
    final tag = b[offset];
    var i = offset + 1;
    var length = b[i++];
    if (length & 0x80 != 0) {
      final count = length & 0x7f;
      if (count == 0 || count > 4) throw const FormatException('DER length');
      length = 0;
      for (var k = 0; k < count; k++) {
        length = (length << 8) | b[i++];
      }
    }
    final end = i + length;
    if (end > b.length) throw const FormatException('DER overrun');
    return _Der(tag, offset, i, end);
  }
}
