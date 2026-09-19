import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/mcp_config_parse.dart';

void main() {
  group('interpolateMcpValue', () {
    test(r'expands ${VAR} from the supplied env', () {
      expect(
        interpolateMcpValue(r'Bearer ${TOKEN}', {'TOKEN': 'abc'}),
        'Bearer abc',
      );
    });

    test(r'expands ${VAR:-default} when the variable is unset', () {
      expect(interpolateMcpValue(r'${PORT:-8080}', const {}), '8080');
    });

    test('prefers the env value over the default', () {
      expect(interpolateMcpValue(r'${PORT:-8080}', {'PORT': '9090'}), '9090');
    });

    test(r'leaves an unknown ${VAR} intact so a gate can see it', () {
      expect(
        interpolateMcpValue(r'${GITHUB_TOKEN}', const {}),
        r'${GITHUB_TOKEN}',
      );
    });

    test('leaves the literal intact when defaults are disallowed', () {
      expect(
        interpolateMcpValue(r'${PORT:-8080}', const {}, allowDefault: false),
        r'${PORT:-8080}',
      );
    });

    test('expands several references in one value', () {
      expect(
        interpolateMcpValue(r'${A}:${B:-b}', {'A': 'a'}),
        'a:b',
      );
    });
  });

  group('parseMcpConfig applies interpolation', () {
    test('JSON args/env/url/headers/cwd are expanded', () {
      final servers = parseMcpConfig(
        r'''
{
  "mcpServers": {
    "s": {
      "command": "npx",
      "args": ["--token", "${TOKEN}"],
      "env": {"API_KEY": "${TOKEN:-fallback}"},
      "cwd": "${ROOT}/sub",
      "url": "https://${HOST}/mcp",
      "headers": {"Authorization": "Bearer ${TOKEN}"}
    }
  }
}
''',
        env: {'TOKEN': 'abc', 'ROOT': '/root', 'HOST': 'example.com'},
      ).single;
      expect(servers.args, ['--token', 'abc']);
      expect(servers.env['API_KEY'], 'abc');
      expect(servers.cwd, '/root/sub');
      expect(servers.url, 'https://example.com/mcp');
      expect(servers.headers['Authorization'], 'Bearer abc');
    });

    test('TOML args/env/url/headers/cwd are expanded', () {
      final servers = parseMcpConfig(
        r'''
[mcp_servers.s]
command = "npx"
args = ["--token", "${TOKEN}"]
cwd = "${ROOT}/sub"
url = "https://${HOST}/mcp"

[mcp_servers.s.env]
API_KEY = "${TOKEN:-fallback}"

[mcp_servers.s.headers]
Authorization = "Bearer ${TOKEN}"
''',
        env: {'TOKEN': 'abc', 'ROOT': '/root', 'HOST': 'example.com'},
      ).single;
      expect(servers.args, ['--token', 'abc']);
      expect(servers.env['API_KEY'], 'abc');
      expect(servers.cwd, '/root/sub');
      expect(servers.url, 'https://example.com/mcp');
      expect(servers.headers['Authorization'], 'Bearer abc');
    });

    test(r'unknown ${VAR} survives parsing intact', () {
      final servers = parseMcpConfig(
        r'{"mcpServers":{"s":{"command":"npx","args":["${MISSING}"]}}}',
        env: const {},
      ).single;
      expect(servers.args, [r'${MISSING}']);
    });
  });
}
