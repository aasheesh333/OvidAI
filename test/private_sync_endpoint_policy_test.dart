import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/private_sync/endpoint_policy.dart';

String canon(String value, {String providerId = 'openai', Set<String>? schemes, Set<String>? nonSecretQueryKeys}) =>
    canonicalProviderEndpoint(
      value,
      providerId,
      allowedSchemes: schemes ?? const {'https'},
      nonSecretQueryKeys: nonSecretQueryKeys ?? const {},
    );

Matcher rejectedFor(EndpointRejection reason) => throwsA(
    isA<EndpointRejectedException>().having((e) => e.reason, 'reason', reason));

void main() {
  group('canonicalization', () {
    final cases = <String, String>{
      'https://api.example.com/v1': 'https://api.example.com/v1',
      'https://api.example.com': 'https://api.example.com/',
      'HTTPS://API.Example.COM/V1': 'https://api.example.com/V1',
      'https://api.example.com:443/v1': 'https://api.example.com/v1',
      'https://api.example.com:0443/v1': 'https://api.example.com/v1',
      'https://api.example.com:8443/v1': 'https://api.example.com:8443/v1',
      'https://api.example.com/a/./b/../c': 'https://api.example.com/a/c',
      'https://api.example.com/%7euser/%2e%2e/x': 'https://api.example.com/x',
      'https://api.example.com/%7Euser': 'https://api.example.com/~user',
      'https://api.example.com/a%2fb': 'https://api.example.com/a%2Fb',
      'https://api.example.com/v1?': 'https://api.example.com/v1',
      'https://api.example.com/v1?api-version=2024-01-01':
          'https://api.example.com/v1?api-version=2024-01-01',
      'https://api.example.com/v1?b=2&&a=1&': 'https://api.example.com/v1?b=2&a=1',
      'https://api.example.com/v1?q=%7e%3d': 'https://api.example.com/v1?q=~%3D',
      'https://[2001:DB8::1]/v1': 'https://[2001:db8::1]/v1',
      'https://[::1]:443/': 'https://[::1]/',
      'https://127.0.0.1:8080/x': 'https://127.0.0.1:8080/x',
    };
    cases.forEach((input, expected) {
      test(input, () {
        expect(canon(input), expected);
        // Idempotent: canonical output is a fixed point.
        expect(canon(expected), expected);
      });
    });

    test('http requires an explicit provider scheme policy', () {
      expect(() => canon('http://localhost:11434/v1'),
          rejectedFor(EndpointRejection.scheme));
      expect(canon('http://localhost:80/v1', schemes: {'http', 'https'}),
          'http://localhost/v1');
      expect(canon('HTTP://LOCALHOST:11434/v1', schemes: {'http'}),
          'http://localhost:11434/v1');
    });

    test('non-secret query keys may be allowed by provider policy', () {
      expect(
        canon('https://api.example.com/v1?token_type=public',
            nonSecretQueryKeys: {'token_type'}),
        'https://api.example.com/v1?token_type=public',
      );
    });

    test('isCanonicalProviderEndpoint', () {
      expect(isCanonicalProviderEndpoint('https://api.example.com/v1', 'openai'), isTrue);
      expect(isCanonicalProviderEndpoint('https://API.example.com/v1', 'openai'), isFalse);
      expect(isCanonicalProviderEndpoint('https://u:p@api.example.com/', 'openai'), isFalse);
    });
  });

  group('rejection', () {
    test('not absolute or unsupported scheme', () {
      for (final v in ['', '/v1', 'api.example.com/v1', '//api.example.com/', 'ftp://x.com/',
        'file:///etc/passwd', 'javascript:alert(1)', 'https:/api.example.com', 'https:api.example.com']) {
        expect(() => canon(v), throwsA(isA<EndpointRejectedException>()), reason: v);
      }
      expect(() => canon('ftp://x.com/'), rejectedFor(EndpointRejection.scheme));
    });

    test('userinfo in any form', () {
      for (final v in [
        'https://user:pass@api.example.com/',
        'https://user@api.example.com/',
        'https://@api.example.com/',
        'https://:pw@api.example.com/',
        'https://a%40b@api.example.com/',
      ]) {
        expect(() => canon(v), rejectedFor(EndpointRejection.userinfo), reason: v);
      }
    });

    test('fragments, even empty', () {
      expect(() => canon('https://api.example.com/v1#x'), rejectedFor(EndpointRejection.fragment));
      expect(() => canon('https://api.example.com/v1#'), rejectedFor(EndpointRejection.fragment));
    });

    test('control characters, whitespace and non-ASCII, raw or percent-encoded', () {
      for (final v in [
        'https://api.example.com/v1\n',
        ' https://api.example.com/v1',
        'https://api.example.com/v 1',
        'https://api.example.com/\u0000',
        'https://api.example.com/\u007f',
        'https://api.example.com/\t',
        'https://api.example.com/%0a',
        'https://api.example.com/v1?a=%00',
        'https://api.example.com/%7F',
        'https://api.ex\u00e4mple.com/',
        'https://api.example.com/caf\u00e9',
      ]) {
        expect(() => canon(v), rejectedFor(EndpointRejection.character), reason: v);
      }
    });

    test('credential-shaped query keys, case and encoding variants', () {
      for (final v in [
        'https://api.example.com/v1?key=abc',
        'https://api.example.com/v1?KEY=abc',
        'https://api.example.com/v1?api_key=abc',
        'https://api.example.com/v1?apiKey=abc',
        'https://api.example.com/v1?Api-Key=abc',
        'https://api.example.com/v1?x-api-key=abc',
        'https://api.example.com/v1?token=abc',
        'https://api.example.com/v1?access_token=abc',
        'https://api.example.com/v1?refresh_token=abc',
        'https://api.example.com/v1?secret=abc',
        'https://api.example.com/v1?client_secret=abc',
        'https://api.example.com/v1?auth=abc',
        'https://api.example.com/v1?Authorization=abc',
        'https://api.example.com/v1?password=abc',
        'https://api.example.com/v1?sig=abc',
        'https://api.example.com/v1?X-Amz-Signature=abc',
        'https://api.example.com/v1?X-Amz-Credential=abc',
        'https://api.example.com/v1?X-Amz-Security-Token=abc',
        'https://api.example.com/v1?ok=1&token=abc',
        'https://api.example.com/v1?token',
        'https://api.example.com/v1?%6Bey=abc',
        'https://api.example.com/v1?%4B%45%59=abc',
        'https://api.example.com/v1?%256Bey=abc',
        'https://api.example.com/v1?api%5Fkey=abc',
        'https://api.example.com/v1?api+key=abc',
        'https://api.example.com/v1?to%6Ben=abc',
      ]) {
        expect(() => canon(v), rejectedFor(EndpointRejection.credentialQuery), reason: v);
      }
    });

    test('provider-specific credential keys', () {
      expect(canon('https://x.example.com/?code=1', providerId: 'openai'),
          'https://x.example.com/?code=1');
      expect(() => canon('https://x.example.com/?code=1', providerId: 'azure'),
          rejectedFor(EndpointRejection.credentialQuery));
    });

    test('allow-listed key does not permit other credential keys', () {
      expect(
        () => canon('https://api.example.com/v1?token_type=public&key=x',
            nonSecretQueryKeys: {'token_type'}),
        rejectedFor(EndpointRejection.credentialQuery),
      );
    });

    test('malformed host, port and escapes', () {
      for (final v in [
        'https:///v1',
        'https://:443/v1',
        'https://api.example.com:/v1',
        'https://api.example.com:0/v1',
        'https://api.example.com:65536/v1',
        'https://api.example.com:12a/v1',
        'https://api..example.com/',
        'https://-api.example.com/',
        'https://api.example.com./',
        'https://api_x.example.com/',
        'https://api%2eexample.com/',
        'https://[::1/',
        'https://[zz::1]/',
        'https://${'a' * 64}.com/',
        'https://api.example.com/%zz',
        'https://api.example.com/%4',
        'https://api.example.com/v1?a=%',
        'https://api.example.com/a\\b',
        'https://api.example.com/<x>',
        'https://api.example.com/v1?a=%FF',
      ]) {
        expect(() => canon(v), throwsA(isA<EndpointRejectedException>()), reason: v);
      }
    });

    test('length bound of 2048 bytes', () {
      final base = 'https://api.example.com/';
      final ok = base + 'a' * (2048 - base.length);
      expect(canon(ok), ok);
      expect(() => canon('${ok}a'), rejectedFor(EndpointRejection.length));
    });

    test('error text never echoes the input', () {
      try {
        canon('https://user:SENTINEL@api.example.com/?token=SENTINEL');
        fail('expected rejection');
      } on EndpointRejectedException catch (e) {
        expect(e.toString(), isNot(contains('SENTINEL')));
        expect(e.message, isNot(contains('SENTINEL')));
        expect(e.source, isNull);
      }
    });
  });
}
