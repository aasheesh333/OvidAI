import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/diag.dart';
import 'package:ovid_ai/core/secret_scrub.dart';

/// M4: MCP args/url secrets never reach logs, diagnostics or the UI.
void main() {
  group('scrubUrl', () {
    const cases = <String, String>{
      'https://user:hunter2@mcp.example.com/sse':
          'https://[redacted]@mcp.example.com/sse',
      'https://mcp.example.com/sse?token=abc123&region=eu':
          'https://mcp.example.com/sse?token=[redacted]&region=eu',
      'https://h.example/x?api_key=k&X-Api-Key=v&sig=s&code=c':
          'https://h.example/x?api_key=[redacted]&X-Api-Key=[redacted]'
          '&sig=[redacted]&code=[redacted]',
      'https://actions.example.com/mcp/sk-ak-9f8e7d6c5b4a39281706f5e4/sse':
          'https://actions.example.com/mcp/[redacted]/sse',
      'https://h.example/cb#access_token=zzz&state=1':
          'https://h.example/cb#access_token=[redacted]&state=1',
      'https://mcp.example.com/v1/my-long-descriptive-route-name':
          'https://mcp.example.com/v1/my-long-descriptive-route-name',
      'http://localhost:3000/mcp': 'http://localhost:3000/mcp',
    };
    cases.forEach((input, expected) {
      test(input, () => expect(scrubUrl(input), expected));
    });
  });

  group('scrubArgs', () {
    test('flag, assignment, header and token forms', () {
      expect(
        scrubArgs([
          '-y',
          '@acme/mcp',
          '--api-key',
          'sk-proj-abcdefghijklmnopqrstu',
          '--token=ghp_abcdefghijklmnopqrstuvwx',
          'GITHUB_PERSONAL_ACCESS_TOKEN=github_pat_1234567890abcdefghij',
          '-H',
          'Authorization: Bearer abc.def.ghi',
          'x-api-key: raw-secret',
          '--url',
          'https://u:p@h.example/s?key=1',
          '--port',
          '8080',
          'Accept: application/json',
        ]),
        [
          '-y',
          '@acme/mcp',
          '--api-key',
          kScrubbed,
          '--token=$kScrubbed',
          'GITHUB_PERSONAL_ACCESS_TOKEN=$kScrubbed',
          '-H',
          'Authorization: $kScrubbed',
          'x-api-key: $kScrubbed',
          '--url',
          'https://[redacted]@h.example/s?key=[redacted]',
          '--port',
          '8080',
          'Accept: application/json',
        ],
      );
    });

    test('bare well-known tokens are scrubbed anywhere', () {
      final out = scrubArgs([
        'sk-ant-api03-abcdefghijklmnopqrstuvwxyz',
        'xoxb-123456789012-abcdefghij',
        'AKIAABCDEFGHIJKLMNOP',
        'plain-arg',
      ]);
      expect(out.take(3), everyElement(kScrubbed));
      expect(out.last, 'plain-arg');
    });

    test('command line display', () {
      expect(
        scrubCommandLine('npx', ['-y', 'srv', '--password', 'p4ss']),
        'npx -y srv --password $kScrubbed',
      );
    });

    test('secret names', () {
      for (final n in [
        'token', 'API_KEY', 'apiKey', 'x-api-key', 'client_secret',
        'Authorization', 'password', 'pat', 'access-token', 'session',
      ]) {
        expect(isSecretName(n), isTrue, reason: n);
      }
      for (final n in ['port', 'region', 'url', 'name', 'verbose', 'model']) {
        expect(isSecretName(n), isFalse, reason: n);
      }
    });
  });

  group('logs and diagnostics', () {
    tearDown(Diag.resetForTest);

    test('Diag ring buffer never stores URL credentials or tokens', () {
      Diag.swallow(
        'mcp_service.connect',
        Exception(
          'ClientException: Connection refused, '
          'uri=https://mcp.example.com/sse?token=s3cret&x=1 '
          'auth sk-proj-abcdefghijklmnopqrstu',
        ),
      );
      final text = Diag.recent().last.error;
      expect(text, isNot(contains('s3cret')));
      expect(text, isNot(contains('sk-proj-abcdefghijklmnopqrstu')));
      expect(text, contains('token=[redacted]'));
      expect(text, contains('x=1'));
    });

  });
}
