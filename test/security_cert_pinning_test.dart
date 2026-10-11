import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/cert_pinning.dart';

// Throwaway self-signed localhost certificate (test fixture only; never
// trusted anywhere outside this test's SecurityContext).
const _certPem = '''
-----BEGIN CERTIFICATE-----
MIIBljCCATugAwIBAgIUGjsqPJeHdvw1abUVlHAjLxCXzZkwCgYIKoZIzj0EAwIw
FDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTAxMTExMDI0M1oYDzIxMjYwOTE3
MTEwMjQzWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjO
PQMBBwNCAATpCiA4Ak7rnn1jlYOPRCqgBhWSIWnXxIFlS7c1jDtzqXJVFonLg8dG
mOyJuxGAxJGcvrgYP0xiqWn6mmvfj6m1o2kwZzAdBgNVHQ4EFgQUJ5R1stTGFHj4
YpSXnbzO7EyqqR4wHwYDVR0jBBgwFoAUJ5R1stTGFHj4YpSXnbzO7EyqqR4wDwYD
VR0TAQH/BAUwAwEB/zAUBgNVHREEDTALgglsb2NhbGhvc3QwCgYIKoZIzj0EAwID
SQAwRgIhANv9lLjmvu1MVewSq707X1gzfEYHTLW6Sy2lA4ePy1sMAiEAqLJ5JCvL
muTuB5IoYyBOaY0es8jiBVj4dRnZ6dC3Do8=
-----END CERTIFICATE-----
''';
const _keyPem = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgRZ3cZ0l/fUWahDbS
Ot6VrDrHwiZuGfBgyAkgHNawcPihRANCAATpCiA4Ak7rnn1jlYOPRCqgBhWSIWnX
xIFlS7c1jDtzqXJVFonLg8dGmOyJuxGAxJGcvrgYP0xiqWn6mmvfj6m1
-----END PRIVATE KEY-----
''';

/// `openssl x509 -pubkey | openssl pkey -pubin -outform der | sha256 | base64`
const _fixturePin = 'b1xcHSqm6II8yUlEYOVTdBcySRbzrLXD4mn+BAyrN3E=';

Uint8List _derOf(String pem) => base64.decode(
  pem
      .split('\n')
      .where((l) => l.isNotEmpty && !l.startsWith('-----'))
      .join(),
);

void main() {
  group('defaults (M7 ships OFF)', () {
    test('flag is off and the pin set is empty', () {
      expect(kCertPinningEnabled, isFalse);
      expect(kOvidSpkiPins.keys, containsAll(['api.ovidsi.com', 'ovidsi.com']));
      for (final pins in kOvidSpkiPins.values) {
        expect(pins, isEmpty, reason: 'owner must supply real SPKI pins');
      }
      final pinning = CertPinning(kOvidSpkiPins);
      expect(pinning.pinsFor('api.ovidsi.com'), isNull);
      expect(pinning.accepts('api.ovidsi.com', null), isTrue);
    });

    test('installing with the default build is a no-op', () {
      final before = HttpOverrides.current;
      installOvidCertificatePinning();
      expect(HttpOverrides.current, same(before));
    });
  });

  group('SPKI extraction', () {
    test('matches the openssl SPKI hash of the fixture certificate', () {
      expect(spkiSha256Base64(_derOf(_certPem)), _fixturePin);
    });

    test('garbage DER yields null, never a match', () {
      expect(spkiSha256Base64(Uint8List.fromList([0x30, 0x82, 0xff])), isNull);
      expect(spkiSha256Base64(Uint8List(0)), isNull);
      final pinning = CertPinning({'h.example': [_fixturePin]});
      expect(pinning.accepts('h.example', null), isFalse);
      expect(pinning.accepts('H.EXAMPLE', null), isFalse);
      expect(pinning.accepts('other.example', null), isTrue);
    });
  });

  group('live TLS', () {
    late SecureServerSocket server;
    late SecurityContext clientContext;
    var requestsSeen = 0;

    setUp(() async {
      requestsSeen = 0;
      final serverContext = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(_certPem))
        ..usePrivateKeyBytes(utf8.encode(_keyPem));
      server = await SecureServerSocket.bind('localhost', 0, serverContext);
      server.listen((socket) {
        socket.listen(
          (data) {
            requestsSeen++;
            socket.write(
              'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n'
              'Connection: close\r\n\r\nok',
            );
            unawaited(socket.close());
          },
          onError: (_) {},
        );
      }, onError: (_) {});
      clientContext = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(utf8.encode(_certPem));
    });

    tearDown(() => server.close());

    Future<String> get(CertPinning pinning) async {
      final client = HttpClient(context: clientContext);
      pinning.install(client, context: clientContext);
      try {
        final req = await client.getUrl(
          Uri.parse('https://localhost:${server.port}/account'),
        );
        req.headers.set('Authorization', 'Bearer must-not-leak');
        final res = await req.close();
        return await utf8.decodeStream(res);
      } finally {
        client.close(force: true);
      }
    }

    test('matching pin (current or backup) connects', () async {
      expect(
        await get(CertPinning({
          'localhost': ['AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=', _fixturePin],
        })),
        'ok',
      );
      expect(requestsSeen, 1);
    });

    test('mismatched pin fails before any request byte is sent', () async {
      await expectLater(
        get(CertPinning({
          'localhost': ['AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='],
        })),
        throwsA(isA<CertificatePinException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(requestsSeen, 0);
    });

    test('unpinned host is untouched', () async {
      expect(await get(CertPinning(const {})), 'ok');
    });
  });
}
