import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/mcp_config_parse.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/plugin_adapters.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/state.dart';

/// Claude Code plugin/MCP parity: wrapperless `.mcp.json`, OAuth config
/// parsing, `PreToolUse` `updatedInput` extraction, `if` predicates,
/// `continue:false` halting, legacy SSE transport support, the OAuth flow
/// API, and inline `.claude-plugin/plugin.json` components.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.createForTest();
    HookService.I.resetForTest();
    // OAuth token/config storage never touches the real secure storage.
    McpService.oauthSecureStorageDisabledForTest = true;
  });

  tearDown(() async {
    for (final s in List<McpServer>.of(AppState.I.mcpServers)) {
      await McpService.I.disconnect(s.canonicalId);
    }
    McpService.I.httpClientForTest = null;
    McpService.rpcTimeoutSecondsForTest = null;
    McpService.oauthSecureStorageDisabledForTest = false;
    HookService.I.resetForTest();
    AppState.resetTestInstance();
  });

  NormalizedPluginManifest registerHooks(List<PluginHook> hooks) {
    final m = NormalizedPluginManifest(
      id: 'acme/parity-probe',
      name: 'parity-probe',
      version: '1.0.0',
      format: PluginFormat.claudeCode,
      rootPath: '/plugin',
      hooks: List.unmodifiable(hooks),
    );
    PluginContributionRegistry.I.register(
      m,
      activation: PluginActivation.sessionActive,
      immediateSessionId: 's1',
    );
    addTearDown(() => PluginContributionRegistry.I.unregisterPlugin(m.id));
    return m;
  }

  PluginHook commandHook({
    required String event,
    required String payload,
    int ordinal = 0,
    Map<String, dynamic> unknownFields = const {},
  }) => PluginHook(
    pluginId: 'acme/parity-probe',
    event: event,
    ordinal: ordinal,
    type: 'command',
    payload: payload,
    timeoutS: 5,
    unknownFields: unknownFields,
  );

  group('wrapperless .mcp.json (item 2)', () {
    test('top-level server map without an mcpServers wrapper parses', () {
      final parsed = parseMcpConfig(jsonEncode({
        'my-server': {
          'command': 'npx',
          'args': ['-y', 'probe'],
        },
      }));
      expect(parsed, hasLength(1));
      expect(parsed.first.name, 'my-server');
      expect(parsed.first.command, 'npx');
      expect(parsed.first.args, ['-y', 'probe']);
      expect(parsed.first.type, 'stdio');
    });

    test('known non-server keys (inputs) are skipped, not parsed as servers',
        () {
      final parsed = parseMcpConfig(jsonEncode({
        'inputs': [
          {'id': 'token', 'description': 'a token'},
        ],
        'real-server': {'command': 'node', 'args': ['server.js']},
      }));
      expect(parsed.map((s) => s.name), ['real-server']);
    });
  });

  group('OAuth config parsing (item 2)', () {
    test('oauth block parses and is not treated as an unknown key', () {
      final parsed = parseMcpConfig(jsonEncode({
        'mcpServers': {
          'oauth-server': {
            'type': 'http',
            'url': 'https://mcp.example.com/mcp',
            'oauth': {
              'authorization_url': 'https://auth.example.com/authorize',
              'token_url': 'https://auth.example.com/token',
              'client_id': 'ovid-client',
              'scopes': ['read', 'write'],
            },
          },
        },
      }));
      expect(parsed, hasLength(1));
      final oauth = parsed.first.oauth;
      expect(oauth, isNotNull);
      expect(oauth!.authorizationUrl, 'https://auth.example.com/authorize');
      expect(oauth.tokenUrl, 'https://auth.example.com/token');
      expect(oauth.clientId, 'ovid-client');
      expect(oauth.scopes, ['read', 'write']);
      expect(parsed.first.ignoredKeys, isNot(contains('oauth')));
    });
  });

  group('PreToolUse updatedInput (item 5)', () {
    test('hookSpecificOutput.updatedInput is extracted and allows', () async {
      HookService.I.stdinExecutorForTest = (cmd, env, stdinJson) async =>
          (0, jsonEncode({
            'hookSpecificOutput': {
              'updatedInput': {'command': 'ls -la'},
              'permissionDecision': 'allow',
            },
          }));
      registerHooks([commandHook(event: 'pre_tool', payload: 'rewrite')]);

      final gate = await HookService.I.fireGate(
        'pre_tool',
        's1',
        payload: {
          'tool': 'Bash',
          'tool_input': {'command': 'ls'},
        },
      );

      expect(gate.decision, HookDecision.allow);
      expect(gate.allowed, isTrue);
      expect(gate.updatedInput, {'command': 'ls -la'});
    });

    test('permissionDecision "ask" surfaces as HookDecision.ask', () async {
      HookService.I.stdinExecutorForTest = (cmd, env, stdinJson) async =>
          (0, jsonEncode({
            'decision': 'ask',
            'reason': 'destructive command',
          }));
      registerHooks([commandHook(event: 'pre_tool', payload: 'asker')]);

      final gate = await HookService.I.fireGate(
        'pre_tool',
        's1',
        payload: {
          'tool': 'Bash',
          'tool_input': {'command': 'rm -rf /tmp/x'},
        },
      );

      expect(gate.decision, HookDecision.ask);
      expect(gate.allowed, isFalse, reason: 'allowed is true only for allow');
      expect(gate.deniedByPlugin, isNotNull);
      expect(gate.reason, contains('destructive'));
    });

    test('exit code 2 still denies', () async {
      HookService.I.stdinExecutorForTest = (cmd, env, stdinJson) async =>
          (2, 'nope');
      registerHooks([commandHook(event: 'pre_tool', payload: 'denier')]);

      final gate = await HookService.I.fireGate(
        'pre_tool',
        's1',
        payload: {'tool': 'Bash', 'tool_input': {'command': 'ls'}},
      );

      expect(gate.decision, HookDecision.deny);
      expect(gate.allowed, isFalse);
    });
  });

  group('hook "if" predicates (item 7)', () {
    test('ToolName(arg-pattern) matches and mismatches', () {
      const payload = {
        'tool': 'Bash',
        'tool_input': {'command': 'git commit -m "wip"'},
      };
      expect(
        HookService.ifPredicateMatches('Bash(git commit:*)', payload),
        isTrue,
      );
      expect(
        HookService.ifPredicateMatches('Bash(rm -rf:*)', payload),
        isFalse,
      );
      expect(HookService.ifPredicateMatches('Read', payload), isFalse);
      expect(HookService.ifPredicateMatches('*', payload), isTrue);
    });

    test('a non-matching "if" skips the hook end-to-end', () async {
      var ran = false;
      HookService.I.stdinExecutorForTest = (cmd, env, stdinJson) async {
        ran = true;
        return (0, '{}');
      };
      registerHooks([
        commandHook(
          event: 'pre_tool',
          payload: 'guarded',
          unknownFields: const {'if': 'Bash(rm -rf:*)'},
        ),
      ]);

      await HookService.I.fireGate(
        'pre_tool',
        's1',
        payload: {
          'tool': 'Bash',
          'tool_input': {'command': 'ls'},
        },
      );

      expect(ran, isFalse, reason: '"if" predicate did not match');
    });

    test('a matching "if" lets the hook run', () async {
      var ran = false;
      HookService.I.stdinExecutorForTest = (cmd, env, stdinJson) async {
        ran = true;
        return (0, '{}');
      };
      registerHooks([
        commandHook(
          event: 'pre_tool',
          payload: 'guarded',
          unknownFields: const {'if': 'Bash(ls:*)'},
        ),
      ]);

      await HookService.I.fireGate(
        'pre_tool',
        's1',
        payload: {
          'tool': 'Bash',
          'tool_input': {'command': 'ls /tmp'},
        },
      );

      expect(ran, isTrue);
    });
  });

  group('output contract: continue:false halting (item 9)', () {
    test('continue:false stops later hooks and marks the result halted',
        () async {
      final ran = <String>[];
      HookService.I.stdinExecutorForTest = (cmd, env, stdinJson) async {
        ran.add(cmd);
        if (cmd == 'first') {
          return (0, jsonEncode({
            'continue': false,
            'systemMessage': 'stop here',
          }));
        }
        return (0, 'second output');
      };
      registerHooks([
        commandHook(event: 'session_start', payload: 'first', ordinal: 0),
        commandHook(event: 'session_start', payload: 'second', ordinal: 1),
      ]);

      final result = await HookService.I.fireDetailed('session_start', 's1');

      expect(ran, ['first'], reason: 'second hook must not run');
      expect(result.halted, isTrue);
      expect(result.systemMessages, ['stop here']);
    });

    test('suppressOutput:true keeps the hook output out of the result',
        () async {
      HookService.I.stdinExecutorForTest = (cmd, env, stdinJson) async =>
          (0, jsonEncode({'suppressOutput': true}));
      registerHooks([commandHook(event: 'session_start', payload: 'quiet')]);

      final result = await HookService.I.fireDetailed('session_start', 's1');

      expect(result.output, isEmpty);
      expect(result.halted, isFalse);
    });
  });

  group('legacy SSE transport (item 6)', () {
    McpServer sseServer() => McpServer(
      name: 'sse-probe',
      author: 't',
      description: 'legacy sse probe',
      category: 'Custom',
      command: '',
      custom: true,
      transport: 'sse',
      url: 'https://sse.test/sse',
    );

    test('sse is a supported transport, not an unsupported one', () {
      expect(McpService.I.unsupportedTransportReason(sseServer()), isNull);
    });

    test('full handshake + tool call over legacy SSE', () async {
      final events = StreamController<String>();
      addTearDown(() => events.close());
      McpService.I.httpClientForTest =
          MockClient.streaming((request, bodyStream) async {
        if (request.method == 'GET') {
          // The endpoint event arrives split across chunks — the channel
          // must reassemble it from its buffer.
          final stream = () async* {
            yield 'event: endpoint\n';
            yield 'data: https://sse.test/message\n\n';
            await for (final e in events.stream) {
              yield e;
            }
          }();
          return http.StreamedResponse(
            stream.transform(utf8.encoder),
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        final body = request is http.Request
            ? request.body
            : await bodyStream.bytesToString();
        final msg = jsonDecode(body) as Map<String, dynamic>;
        final id = msg['id'];
        Map<String, dynamic>? result;
        switch (msg['method']) {
          case 'initialize':
            result = {
              'protocolVersion': '2024-11-05',
              'capabilities': {},
              'serverInfo': {'name': 'sse-probe', 'version': '1'},
            };
          case 'tools/list':
            result = {
              'tools': [
                {
                  'name': 'ping',
                  'description': 'ping tool',
                  'inputSchema': {'type': 'object'},
                },
              ],
            };
          case 'tools/call':
            result = {
              'content': [
                {'type': 'text', 'text': 'pong'},
              ],
            };
        }
        if (result != null) {
          events.add(
            'data: ${jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result})}\n\n',
          );
        }
        return http.StreamedResponse(const Stream<List<int>>.empty(), 202);
      });

      final server = sseServer();
      final status = await McpService.I.connect(server);
      expect(status, contains('connected (sse)'));
      expect(McpService.I.isConnected(server.canonicalId), isTrue);

      final out = await McpService.I.callTool(
        server.canonicalId,
        'ping',
        {},
      );
      expect(out, contains('pong'));

      await McpService.I.disconnect(server.canonicalId);
      expect(McpService.I.isConnected(server.canonicalId), isFalse);
    });
  });

  group('OAuth flow API (item 6)', () {
    const config = McpOAuthConfig(
      authorizationUrl: 'https://auth.example.com/authorize',
      tokenUrl: 'https://auth.example.com/token',
      clientId: 'ovid-client',
      scopes: ['read'],
      redirectUri: 'ovid://oauth/callback',
    );

    test('buildMcpAuthorizeUrl carries the OAuth parameters', () {
      final url = McpService.buildMcpAuthorizeUrl(
        config: config,
        state: 'state-123',
        codeChallenge: 'challenge-abc',
      );
      final uri = Uri.parse(url);
      expect(uri.host, 'auth.example.com');
      expect(uri.queryParameters['response_type'], 'code');
      expect(uri.queryParameters['client_id'], 'ovid-client');
      expect(uri.queryParameters['redirect_uri'], 'ovid://oauth/callback');
      expect(uri.queryParameters['scope'], 'read');
      expect(uri.queryParameters['state'], 'state-123');
      expect(uri.queryParameters['code_challenge'], 'challenge-abc');
      expect(uri.queryParameters['code_challenge_method'], 'S256');
    });

    test('exchange + store + read round-trips a token', () async {
      McpService.I.httpClientForTest = MockClient((request) async {
        expect(request.url.host, 'auth.example.com');
        return http.Response(
          jsonEncode({
            'access_token': 'access-1',
            'refresh_token': 'refresh-1',
            'token_type': 'Bearer',
            'expires_in': 3600,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final token = await McpService.I.exchangeMcpOAuthCode(
        config: config,
        code: 'auth-code-1',
        codeVerifier: 'verifier-1',
      );
      expect(token.accessToken, 'access-1');
      expect(token.canRefresh, isTrue);
      expect(token.isExpired, isFalse);

      await McpService.I.storeMcpOAuthToken('sse-probe', token);
      final back = await McpService.I.mcpOAuthTokenFor('sse-probe');
      expect(back?.accessToken, 'access-1');

      await McpService.I.clearMcpOAuthToken('sse-probe');
      expect(await McpService.I.mcpOAuthTokenFor('sse-probe'), isNull);
    });
  });

  group('Claude adapter inline plugin.json components (item 10)', () {
    test('inline hooks, mcpServers and custom dirs are read', () async {
      final root = Directory.systemTemp.createTempSync('claude-inline-');
      addTearDown(() {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      });
      Directory('${root.path}/.claude-plugin').createSync(recursive: true);
      File('${root.path}/.claude-plugin/plugin.json').writeAsStringSync(
        jsonEncode({
          'name': 'inline-probe',
          'author': 'acme',
          'hooks': {
            'PreToolUse': [
              {
                'matcher': 'Bash',
                'hooks': [
                  {'type': 'command', 'command': 'echo inline'},
                ],
              },
            ],
          },
          'mcpServers': {
            'probe-mcp': {
              'command': 'npx',
              'args': ['-y', 'probe'],
            },
          },
          'commands': './my-commands',
        }),
      );
      Directory('${root.path}/my-commands').createSync();
      File(
        '${root.path}/my-commands/deploy.md',
      ).writeAsStringSync('# deploy\n\nDeploy things.\n');

      final manifest = await const ClaudePluginAdapter().inspect(root);

      expect(
        manifest.hooks.any(
          (h) => h.event == 'pre_tool' && h.payload == 'echo inline',
        ),
        isTrue,
        reason: 'inline plugin.json hooks are adapted',
      );
      expect(
        manifest.mcpServers.any((s) => s.name == 'probe-mcp'),
        isTrue,
        reason: 'inline plugin.json mcpServers are adapted',
      );
      expect(
        manifest.commands.any((c) => c.name == 'deploy'),
        isTrue,
        reason: 'custom component dir is scanned',
      );
      // Handled keys must not be duplicated into unknownFields.
      for (final k in manifest.unknownFields.keys) {
        expect(
          ['hooks', 'mcpServers', 'commands', 'skills', 'agents'].contains(k),
          isFalse,
          reason: 'handled key "$k" leaked into unknownFields',
        );
      }
    });

    test('an sse mcpServer from a plugin .mcp.json is accepted', () async {
      final root = Directory.systemTemp.createTempSync('claude-sse-');
      addTearDown(() {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      });
      Directory('${root.path}/.claude-plugin').createSync(recursive: true);
      File('${root.path}/.claude-plugin/plugin.json').writeAsStringSync(
        jsonEncode({'name': 'sse-plugin', 'author': 'acme'}),
      );
      File('${root.path}/.mcp.json').writeAsStringSync(
        jsonEncode({
          'mcpServers': {
            'legacy-sse': {'type': 'sse', 'url': 'https://sse.example.com/sse'},
          },
        }),
      );

      final manifest = await const ClaudePluginAdapter().inspect(root);

      expect(
        manifest.mcpServers.any((s) => s.name == 'legacy-sse'),
        isTrue,
        reason: 'sse servers are no longer rejected at adapt time',
      );
      expect(
        manifest.compatibility.any(
          (i) =>
              i.severity == CompatibilitySeverity.required &&
              i.message.contains('SSE'),
        ),
        isFalse,
        reason: 'no required-severity SSE rejection issue',
      );
    });
  });
}
