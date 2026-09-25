import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/mcp_config_parse.dart';

/// Codex parity (2026-09-24).
///
/// Codex plugin *bundles* already worked (the adapter is real and
/// behaviour-tested). What did not work was the Codex *ecosystem config*: MCP
/// servers declared in `config.toml` under `[mcp_servers.<name>]`.
///
///   • `mountPluginMcpServers` read ONLY `.mcp.json` through a raw `jsonDecode`,
///     so a Codex plugin mounted nothing — silently.
///   • The legacy install allowlist was Claude-shaped and staged ZERO files from
///     a Codex tree (no `config.toml`, `.codex-plugin/`, `AGENTS.md`, `.agents/`).
///   • `type = "streamable-http"` — Codex's spelling of the remote transport —
///     survived parsing and then fell through to the stdio path, dying with the
///     misleading "declares no command" instead of connecting over HTTP.
///   • No marketplace discovery path matched a `.codex-plugin/` layout.
void main() {
  group('transport spellings normalise to what the connector understands', () {
    test('every streamable-http variant becomes http', () {
      for (final raw in [
        'streamable-http',
        'streamableHttp',
        'streamable_http',
        'http-streamable',
        'STREAMABLE-HTTP',
        '  streamable-http  ',
      ]) {
        expect(normalizeMcpTransport(raw), 'http', reason: raw);
      }
    });

    test('SSE spellings become sse', () {
      for (final raw in ['server-sent-events', 'server_sent_events', 'sse']) {
        expect(normalizeMcpTransport(raw), 'sse', reason: raw);
      }
    });

    test('known transports pass through unchanged', () {
      for (final raw in ['stdio', 'http', 'sse', 'native']) {
        expect(normalizeMcpTransport(raw), raw);
      }
    });
  });

  group('a Codex config.toml parses into connectable servers', () {
    const codexToml = '''
[mcp_servers.filesystem]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-filesystem", "/work"]

[mcp_servers.remote]
type = "streamable-http"
url = "https://mcp.example.com/api"

[mcp_servers.withenv]
command = "python3"
args = ["-m", "my_server"]
[mcp_servers.withenv.env]
API_KEY = "abc123"
''';

    test('stdio, remote and env-bearing servers all come through', () {
      final parsed = parseMcpConfig(codexToml, env: const {});
      final byName = {for (final p in parsed) p.name: p};

      expect(byName.keys, containsAll(['filesystem', 'remote', 'withenv']));

      final fs = byName['filesystem']!;
      expect(fs.type, 'stdio');
      expect(fs.command, 'npx');
      expect(fs.args, ['-y', '@modelcontextprotocol/server-filesystem', '/work']);

      final env = byName['withenv']!;
      expect(env.env['API_KEY'], 'abc123');
    });

    test('streamable-http resolves to the http transport, not stdio', () {
      final parsed = parseMcpConfig(codexToml, env: const {});
      final remote = parsed.firstWhere((p) => p.name == 'remote');

      expect(
        remote.type,
        'http',
        reason: 'the connector knows stdio/http/sse/native only — an '
            'unnormalised "streamable-http" falls into the stdio branch and '
            'fails with "declares no command"',
      );
      expect(remote.url, 'https://mcp.example.com/api');
      expect(remote.command, isEmpty);
    });

    test('JSON configs still parse through the same entry point', () {
      const json = '''
{"mcpServers": {"j": {"command": "node", "args": ["s.js"],
                      "transport": "streamable-http",
                      "url": "https://j.example/mcp"}}}
''';
      final parsed = parseMcpConfig(json, env: const {});
      expect(parsed.single.name, 'j');
      expect(parsed.single.type, 'http');
    });
  });

  group('production wiring reaches the Codex paths', () {
    test('plugin MCP mounting reads config.toml through the sniffer', () {
      final src = File('lib/core/state.dart').readAsStringSync();
      final body = src.substring(
        src.indexOf('Future<int> mountPluginMcpServers('),
      );
      final head = body.substring(0, body.indexOf('var mounted = 0;'));
      expect(
        head,
        contains("'.mcp.json', 'config.toml'"),
        reason: 'both declaration styles must be tried',
      );
      expect(
        head,
        contains('parseMcpConfig(raw)'),
        reason: 'must go through the format sniffer, not a raw jsonDecode',
      );
      expect(head, isNot(contains('jsonDecode(raw)')));
    });

    test('the legacy install allowlist stages Codex files', () {
      final src = File('lib/core/state.dart').readAsStringSync();
      final body = src.substring(
        src.indexOf('static bool _isLegacyPluginContentPath('),
      );
      final fn = body.substring(0, body.indexOf('\n  }'));
      for (final needle in [
        "relPath == 'config.toml'",
        "relPath == 'AGENTS.md'",
        "relPath == '.codex-plugin/plugin.json'",
        "relPath.startsWith('.agents/')",
        "relPath.startsWith('.codex/')",
      ]) {
        expect(fn, contains(needle), reason: needle);
      }
    });

    test('marketplace discovery probes Codex layouts', () {
      final src = File('lib/core/state.dart').readAsStringSync();
      expect(src, contains("'.codex-plugin/marketplace.json'"));
    });

    test('Codex workspace roots and the plugin-root variable exist', () {
      final agent = File('lib/core/agent_service.dart').readAsStringSync();
      for (final needle in [
        "/.codex/skills'",
        "/.codex/commands'",
        "/.codex/prompts'",
        "/.codex/agents'",
      ]) {
        expect(agent, contains(needle), reason: needle);
      }

      final manifest = File('lib/core/plugin_manifest.dart').readAsStringSync();
      expect(manifest, contains(r'${CODEX_PLUGIN_ROOT}'));

      // The variable must also be exported to hooks and MCP servers, or the
      // expansion resolves but the child process still cannot see it.
      expect(
        File('lib/core/hook_service.dart').readAsStringSync(),
        contains("'CODEX_PLUGIN_ROOT': root"),
      );
      expect(
        File('lib/core/mcp_service.dart').readAsStringSync(),
        contains("'CODEX_PLUGIN_ROOT': root"),
      );
    });

    test('the skill-kind matcher accepts declared .codex contributions', () {
      final src = File('lib/core/skills.dart').readAsStringSync();
      expect(src, contains("path.startsWith('.codex/commands/')"));
      expect(src, contains("path.startsWith('.codex/prompts/')"));
      expect(src, contains("path.startsWith('.codex/agents/')"));
      expect(src, contains("path.startsWith('.codex/skills/')"));
    });
  });
}
