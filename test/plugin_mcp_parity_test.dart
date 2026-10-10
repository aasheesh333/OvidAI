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
import 'package:ovid_ai/core/secure_store.dart';
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
    AppState.mcpOAuthWriteOverrideForTest = null;
    AppState.mcpCustomMcpPersistenceOverrideForTest = null;
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
    AppState.mcpOAuthWriteOverrideForTest = null;
    AppState.mcpCustomMcpPersistenceOverrideForTest = null;
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
      final parsed = parseMcpConfig(
        jsonEncode({
          'my-server': {
            'command': 'npx',
            'args': ['-y', 'probe'],
          },
        }),
      );
      expect(parsed, hasLength(1));
      expect(parsed.first.name, 'my-server');
      expect(parsed.first.command, 'npx');
      expect(parsed.first.args, ['-y', 'probe']);
      expect(parsed.first.type, 'stdio');
    });

    test(
      'known non-server keys (inputs) are skipped, not parsed as servers',
      () {
        final parsed = parseMcpConfig(
          jsonEncode({
            'inputs': [
              {'id': 'token', 'description': 'a token'},
            ],
            'real-server': {
              'command': 'node',
              'args': ['server.js'],
            },
          }),
        );
        expect(parsed.map((s) => s.name), ['real-server']);
      },
    );
  });

  group('OAuth config parsing (item 2)', () {
    test('oauth block parses and is not treated as an unknown key', () {
      final parsed = parseMcpConfig(
        jsonEncode({
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
        }),
      );
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
      HookService.I.stdinExecutorForTest = (cmd, env, stdinJson) async => (
        0,
        jsonEncode({
          'hookSpecificOutput': {
            'updatedInput': {'command': 'ls -la'},
            'permissionDecision': 'allow',
          },
        }),
      );
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
          (0, jsonEncode({'decision': 'ask', 'reason': 'destructive command'}));
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
        payload: {
          'tool': 'Bash',
          'tool_input': {'command': 'ls'},
        },
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
    test(
      'continue:false stops later hooks and marks the result halted',
      () async {
        final ran = <String>[];
        HookService.I.stdinExecutorForTest = (cmd, env, stdinJson) async {
          ran.add(cmd);
          if (cmd == 'first') {
            return (
              0,
              jsonEncode({'continue': false, 'systemMessage': 'stop here'}),
            );
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
      },
    );

    test(
      'suppressOutput:true keeps the hook output out of the result',
      () async {
        HookService.I.stdinExecutorForTest = (cmd, env, stdinJson) async =>
            (0, jsonEncode({'suppressOutput': true}));
        registerHooks([commandHook(event: 'session_start', payload: 'quiet')]);

        final result = await HookService.I.fireDetailed('session_start', 's1');

        expect(result.output, isEmpty);
        expect(result.halted, isFalse);
      },
    );
  });

  group('an unrunnable stdio row is rejected with a reason', () {
    McpServer stdio({String command = 'npx', List<String> args = const []}) =>
        McpServer(
          name: 'dead-row',
          author: 't',
          description: 'stdio probe',
          category: 'Custom',
          command: command,
          args: args,
          custom: true,
          transport: 'stdio',
        );

    test('a package launcher with no package cannot run', () {
      // Custom rows that declare no transport DEFAULT to 'stdio', so a
      // half-entered or badly imported server persisted as `stdio · npx` with
      // no package. It cleared the transport gate, spawned a bare `npx` that
      // printed its usage and exited, and surfaced as an opaque "disconnected"
      // row with nothing telling the user what was actually wrong.
      final reason = McpService.I.unsupportedTransportReason(stdio());
      expect(reason, isNotNull);
      expect(reason, contains('package argument'));
    });

    test('flags alone are not a package', () {
      expect(
        McpService.I.unsupportedTransportReason(stdio(args: const ['-y'])),
        isNotNull,
      );
    });

    test('an empty command is rejected too', () {
      final reason = McpService.I.unsupportedTransportReason(
        stdio(command: '', args: const ['server.js']),
      );
      expect(reason, isNotNull);
      expect(reason, contains('no command'));
    });

    test('a complete launcher row still passes', () {
      expect(
        McpService.I.unsupportedTransportReason(
          stdio(args: const ['-y', '@modelcontextprotocol/server-postgres']),
        ),
        isNull,
      );
    });

    test('an absolute-path launcher is judged on its basename', () {
      expect(
        McpService.I.unsupportedTransportReason(
          stdio(command: '/usr/local/bin/npx'),
        ),
        isNotNull,
      );
    });

    test('non-launcher commands are left alone', () {
      // node/python/sh take scripts and modules in forms this cannot judge —
      // they must never be rejected by a launcher heuristic.
      expect(
        McpService.I.unsupportedTransportReason(
          stdio(command: 'node', args: const ['server.js']),
        ),
        isNull,
      );
    });

    test('native rows with no command are unaffected', () {
      // The built-in Filesystem/GitHub/Fetch/Memory rows legitimately declare
      // `command: ''` — they execute in-process instead of spawning.
      final native = McpServer(
        name: 'GitHub',
        author: 'modelcontextprotocol',
        description: 'native github',
        category: 'Official',
        command: '',
        args: const [],
        transport: 'native',
      );
      expect(McpService.I.unsupportedTransportReason(native), isNull);
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
      McpService.I.httpClientForTest = MockClient.streaming((
        request,
        bodyStream,
      ) async {
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

      final out = await McpService.I.callTool(server.canonicalId, 'ping', {});
      expect(out, contains('pong'));

      await events.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.connected, isFalse);
      expect(
        AppState.I.serviceStatusForTest('mcp:${server.canonicalId}')?.health,
        ServiceHealth.failed,
      );

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
      File(
        '${root.path}/.claude-plugin/plugin.json',
      ).writeAsStringSync(jsonEncode({'name': 'sse-plugin', 'author': 'acme'}));
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

    test(
      'normalized MCP declarations retain mount metadata without secrets',
      () async {
        final root = Directory.systemTemp.createTempSync('claude-metadata-');
        addTearDown(() {
          try {
            root.deleteSync(recursive: true);
          } catch (_) {}
        });
        Directory('${root.path}/.claude-plugin').createSync(recursive: true);
        File('${root.path}/.claude-plugin/plugin.json').writeAsStringSync(
          jsonEncode({'name': 'metadata-probe', 'author': 'acme'}),
        );
        File('${root.path}/.mcp.json').writeAsStringSync(
          jsonEncode({
            'mcpServers': {
              'remote': {
                'type': 'streamable-http',
                'url': 'https://mcp.example.com/api',
                'startup_timeout_s': 17,
                'env': {'API_KEY': 'secret-value'},
                'headers': {'Authorization': 'Bearer secret-value'},
                'oauth': {
                  'client_secret': 'oauth-secret-value',
                  'access_token': 'oauth-access-value',
                  'authorization_url': 'https://auth.example.com/authorize',
                  'token_url': 'https://auth.example.com/token',
                  'client_id': 'public-client',
                  'scopes': ['read'],
                },
              },
            },
          }),
        );

        final manifest = await const ClaudePluginAdapter().inspect(root);
        final server = manifest.mcpServers.single;

        expect(server.transport, 'http');
        expect(server.url, 'https://mcp.example.com/api');
        expect(server.startupTimeoutS, 17);
        expect(server.envNames, ['API_KEY']);
        expect(server.headerNames, ['Authorization']);
        expect(
          server.oauth?.authorizationUrl,
          'https://auth.example.com/authorize',
        );
        expect(server.oauth?.clientId, 'public-client');
        expect(jsonEncode(manifest.toJson()), isNot(contains('secret-value')));
        expect(
          jsonEncode(manifest.toJson()),
          isNot(contains('oauth-secret-value')),
        );
        expect(
          jsonEncode(manifest.toJson()),
          isNot(contains('oauth-access-value')),
        );
      },
    );

    test('file MCP declarations retain the same normalized metadata', () async {
      final root = Directory.systemTemp.createTempSync('claude-file-metadata-');
      addTearDown(() {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      });
      Directory('${root.path}/.claude-plugin').createSync(recursive: true);
      File('${root.path}/.claude-plugin/plugin.json').writeAsStringSync(
        jsonEncode({
          'name': 'file-probe',
          'author': 'acme',
          'mcpServers': 'servers.json',
        }),
      );
      File('${root.path}/servers.json').writeAsStringSync(
        jsonEncode({
          'mcpServers': {
            'stdio': {
              'command': 'node',
              'args': ['server.js'],
              'cwd': 'server',
              'startupTimeoutS': 9,
            },
          },
        }),
      );

      final manifest = await const ClaudePluginAdapter().inspect(root);
      final server = manifest.mcpServers.single;
      expect(server.transport, 'stdio');
      expect(server.command, 'node');
      expect(server.args, ['server.js']);
      expect(server.cwd, 'server');
      expect(server.startupTimeoutS, 9);
    });

    test(
      'mounts normalized metadata and cleans the OAuth sidecar on removal',
      () async {
        final app = AppState.I;
        const pluginId = 'acme/mounted-probe';
        const serverName = 'remote';
        final manifest = NormalizedPluginManifest(
          id: pluginId,
          name: 'mounted-probe',
          version: '1.0.0',
          format: PluginFormat.claudeCode,
          rootPath: '/plugins/mounted-probe',
          mcpServers: [
            PluginMcpServer(
              pluginId: pluginId,
              name: serverName,
              transport: 'http',
              url: 'https://mcp.example.com/api',
              envNames: ['API_KEY'],
              headerNames: ['Authorization'],
              oauth: const McpOAuthConfig(
                authorizationUrl: 'https://auth.example.com/authorize',
                tokenUrl: 'https://auth.example.com/token',
                clientId: 'public-client',
                scopes: ['read'],
              ),
              startupTimeoutS: 17,
            ),
          ],
        );
        await app.setMcpHeaders('$pluginId/$serverName', {
          'Authorization': 'Bearer secure-value',
        });

        expect(
          await app.mountPluginOwnedMcpServers(manifest, connect: false),
          1,
        );
        final mounted = app.mcpServers.singleWhere(
          (s) => s.canonicalId == '$pluginId/$serverName',
        );
        expect(mounted.transport, 'http');
        expect(mounted.url, 'https://mcp.example.com/api');
        expect(mounted.startupTimeoutS, 17);
        expect(mounted.requiredEnvNames, ['API_KEY']);
        expect(mounted.requiredHeaderNames, ['Authorization']);
        expect(mounted.headers, {'Authorization': 'Bearer secure-value'});
        final persisted = SharedPreferences.getInstance();
        final persistedRows = (await persisted).getStringList(
          'ovid_custom_mcp_servers_v1',
        );
        expect(persistedRows, hasLength(1));
        expect(
          jsonDecode(persistedRows!.single),
          containsPair('ownerPluginId', pluginId),
        );
        expect(
          jsonDecode(persistedRows.single),
          containsPair('transport', 'http'),
        );
        expect(
          jsonDecode(persistedRows.single),
          containsPair('startupTimeoutS', 17),
        );
        expect(persistedRows.single, isNot(contains('secure-value')));
        expect(
          McpService.I.mcpOAuthConfigFor(mounted.canonicalId)?.clientId,
          'public-client',
        );

        final updated = NormalizedPluginManifest(
          id: pluginId,
          name: 'mounted-probe',
          version: '1.1.0',
          format: PluginFormat.claudeCode,
          rootPath: manifest.rootPath,
        );
        await app.mountPluginOwnedMcpServers(updated, connect: false);
        expect(
          app.mcpServers.any((s) => s.canonicalId == '$pluginId/$serverName'),
          isFalse,
        );
        expect(McpService.I.mcpOAuthConfigFor('$pluginId/$serverName'), isNull);
        expect(await app.getMcpHeaders('$pluginId/$serverName'), isEmpty);
        expect(
          (await persisted).getStringList('ovid_custom_mcp_servers_v1'),
          isEmpty,
        );
        expect(jsonEncode(manifest.toJson()), isNot(contains('secure-value')));
      },
    );

    test(
      'failed OAuth registration restores an existing persisted row',
      () async {
        final app = AppState.I;
        const pluginId = 'acme/rollback-probe';
        const canonicalId = '$pluginId/remote';
        McpOAuthConfig? previous;
        final initial = NormalizedPluginManifest(
          id: pluginId,
          name: 'rollback-probe',
          version: '1.0.0',
          format: PluginFormat.claudeCode,
          rootPath: '/plugins/rollback-probe',
          mcpServers: [
            PluginMcpServer(
              pluginId: pluginId,
              name: 'remote',
              transport: 'http',
              url: 'https://old.example.com/mcp',
              oauth: const McpOAuthConfig(
                authorizationUrl: 'https://old.example.com/authorize',
                tokenUrl: 'https://old.example.com/token',
                clientId: 'old-client',
              ),
            ),
          ],
        );
        await app.mountPluginOwnedMcpServers(initial, connect: false);
        previous = McpService.I.mcpOAuthConfigFor(canonicalId);
        AppState.mcpOAuthWriteOverrideForTest = (id, config) async {
          if (config.clientId == 'new-client') {
            expect(
              app.mcpServers
                  .singleWhere((server) => server.canonicalId == canonicalId)
                  .url,
              'https://old.example.com/mcp',
            );
            final persisted = await SharedPreferences.getInstance();
            expect(
              persisted.getStringList('ovid_custom_mcp_servers_v1')!.single,
              contains('old.example.com'),
            );
            throw StateError('secure registration failed');
          }
        };

        final replacement = NormalizedPluginManifest(
          id: pluginId,
          name: 'rollback-probe',
          version: '2.0.0',
          format: PluginFormat.claudeCode,
          rootPath: '/plugins/rollback-probe-v2',
          mcpServers: [
            PluginMcpServer(
              pluginId: pluginId,
              name: 'remote',
              transport: 'http',
              url: 'https://new.example.com/mcp',
              oauth: const McpOAuthConfig(
                authorizationUrl: 'https://new.example.com/authorize',
                tokenUrl: 'https://new.example.com/token',
                clientId: 'new-client',
              ),
            ),
          ],
        );

        await expectLater(
          app.mountPluginOwnedMcpServers(replacement, connect: false),
          throwsStateError,
        );
        final restored = app.mcpServers.singleWhere(
          (server) => server.canonicalId == canonicalId,
        );
        expect(restored.url, 'https://old.example.com/mcp');
        expect(McpService.I.mcpOAuthConfigFor(canonicalId), same(previous));
        final prefs = await SharedPreferences.getInstance();
        final rows = prefs.getStringList('ovid_custom_mcp_servers_v1')!;
        expect(rows.single, contains('old.example.com'));
        expect(rows.single, isNot(contains('new.example.com')));
      },
    );

    test(
      'failed OAuth registration removes a new row and its secure sidecar',
      () async {
        final app = AppState.I;
        const pluginId = 'acme/new-rollback-probe';
        const canonicalId = '$pluginId/remote';
        McpService.oauthSecureStorageDisabledForTest = false;
        AppState.mcpOAuthWriteOverrideForTest = (id, config) async {
          await McpService.I.setMcpOAuthConfig(id, config);
          throw StateError('secure registration failed after write');
        };

        final manifest = NormalizedPluginManifest(
          id: pluginId,
          name: 'new-rollback-probe',
          version: '1.0.0',
          format: PluginFormat.claudeCode,
          rootPath: '/plugins/new-rollback-probe',
          mcpServers: [
            PluginMcpServer(
              pluginId: pluginId,
              name: 'remote',
              transport: 'http',
              url: 'https://new.example.com/mcp',
              oauth: const McpOAuthConfig(
                authorizationUrl: 'https://new.example.com/authorize',
                tokenUrl: 'https://new.example.com/token',
                clientId: 'new-client',
              ),
            ),
          ],
        );

        await expectLater(
          app.mountPluginOwnedMcpServers(manifest, connect: false),
          throwsStateError,
        );
        expect(
          app.mcpServers.any((server) => server.canonicalId == canonicalId),
          isFalse,
        );
        expect(McpService.I.mcpOAuthConfigFor(canonicalId), isNull);
        final secure = await ovidSecureStorage().read(
          key: 'ovid_mcp_oauth_cfg_$canonicalId',
        );
        expect(secure, isNull);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getStringList('ovid_custom_mcp_servers_v1'), isNull);
      },
    );

    test(
      'a later OAuth failure restores every owned row and sidecar',
      () async {
        final app = AppState.I;
        McpService.oauthSecureStorageDisabledForTest = false;
        const pluginId = 'acme/multi-rollback-probe';
        const firstId = '$pluginId/first';
        const secondId = '$pluginId/second';
        final old = NormalizedPluginManifest(
          id: pluginId,
          name: 'multi-rollback-probe',
          version: '1.0.0',
          format: PluginFormat.claudeCode,
          rootPath: '/plugins/multi-old',
          mcpServers: [
            PluginMcpServer(
              pluginId: pluginId,
              name: 'first',
              transport: 'http',
              url: 'https://old.example.com/first',
              envNames: ['FIRST_KEY'],
              headerNames: ['Authorization'],
              oauth: const McpOAuthConfig(
                authorizationUrl: 'https://old.example.com/authorize',
                clientId: 'old-first',
              ),
            ),
            PluginMcpServer(
              pluginId: pluginId,
              name: 'second',
              transport: 'http',
              url: 'https://old.example.com/second',
              oauth: const McpOAuthConfig(
                authorizationUrl: 'https://old.example.com/authorize',
                clientId: 'old-second',
              ),
            ),
          ],
        );
        await app.setMcpEnv(firstId, {'FIRST_KEY': 'old-secret'});
        await app.setMcpHeaders(firstId, {'Authorization': 'Bearer old'});
        await app.mountPluginOwnedMcpServers(old, connect: false);
        final prefs = await SharedPreferences.getInstance();
        final before = prefs.getStringList('ovid_custom_mcp_servers_v1');
        final oldFirst = McpService.I.mcpOAuthConfigFor(firstId);
        final oldSecond = McpService.I.mcpOAuthConfigFor(secondId);

        AppState.mcpOAuthWriteOverrideForTest = (id, config) async {
          if (config.clientId == 'new-second') {
            throw StateError('second registration failed');
          }
          await McpService.I.setMcpOAuthConfig(id, config);
        };
        final replacement = NormalizedPluginManifest(
          id: pluginId,
          name: 'multi-rollback-probe',
          version: '2.0.0',
          format: PluginFormat.claudeCode,
          rootPath: '/plugins/multi-new',
          mcpServers: [
            PluginMcpServer(
              pluginId: pluginId,
              name: 'first',
              transport: 'http',
              url: 'https://new.example.com/first',
              oauth: const McpOAuthConfig(
                authorizationUrl: 'https://new.example.com/authorize',
                clientId: 'new-first',
              ),
            ),
            PluginMcpServer(
              pluginId: pluginId,
              name: 'second',
              transport: 'http',
              url: 'https://new.example.com/second',
              oauth: const McpOAuthConfig(
                authorizationUrl: 'https://new.example.com/authorize',
                clientId: 'new-second',
              ),
            ),
          ],
        );
        await expectLater(
          app.mountPluginOwnedMcpServers(replacement, connect: false),
          throwsStateError,
        );
        expect(
          app.mcpServers
              .where((s) => s.ownerPluginId == pluginId)
              .map((s) => s.canonicalId),
          [firstId, secondId],
        );
        expect(
          app.mcpServers.firstWhere((s) => s.canonicalId == firstId).url,
          'https://old.example.com/first',
        );
        expect(await app.getMcpEnv(firstId), {'FIRST_KEY': 'old-secret'});
        expect(await app.getMcpHeaders(firstId), {
          'Authorization': 'Bearer old',
        });
        expect(McpService.I.mcpOAuthConfigFor(firstId), same(oldFirst));
        expect(McpService.I.mcpOAuthConfigFor(secondId), same(oldSecond));
        expect(prefs.getStringList('ovid_custom_mcp_servers_v1'), before);
        expect(
          (await ovidSecureStorage().read(key: 'ovid_mcp_oauth_cfg_$firstId')),
          contains('old-first'),
        );
        // Drop the in-memory registration and re-seed only the durable
        // sidecar, matching a fresh McpService after process restart.
        await McpService.I.removeMcpOAuth(firstId);
        await ovidSecureStorage().write(
          key: 'ovid_mcp_oauth_cfg_$firstId',
          value: jsonEncode(oldFirst!.toJson()),
        );
        expect(
          await McpService.I.mcpOAuthConfigForAsync(firstId),
          isNotNull,
          reason: 'restored OAuth config remains recoverable after reload',
        );
        expect(
          (await McpService.I.mcpOAuthConfigForAsync(firstId))!.clientId,
          'old-first',
        );
      },
    );

    test('persistence failure after a multi-row apply rolls back', () async {
      final app = AppState.I;
      const pluginId = 'acme/persist-rollback-probe';
      final initial = NormalizedPluginManifest(
        id: pluginId,
        name: 'persist-rollback-probe',
        version: '1.0.0',
        format: PluginFormat.claudeCode,
        rootPath: '/plugins/persist-old',
        mcpServers: [
          PluginMcpServer(
            pluginId: pluginId,
            name: 'one',
            transport: 'http',
            url: 'https://old.example.com/one',
            oauth: const McpOAuthConfig(
              authorizationUrl: 'https://old.example.com/authorize',
              clientId: 'old-one',
            ),
          ),
          PluginMcpServer(
            pluginId: pluginId,
            name: 'two',
            transport: 'http',
            url: 'https://old.example.com/two',
            oauth: const McpOAuthConfig(
              authorizationUrl: 'https://old.example.com/authorize',
              clientId: 'old-two',
            ),
          ),
        ],
      );
      await app.mountPluginOwnedMcpServers(initial, connect: false);
      final replacement = NormalizedPluginManifest(
        id: pluginId,
        name: 'persist-rollback-probe',
        version: '2.0.0',
        format: PluginFormat.claudeCode,
        rootPath: '/plugins/persist-new',
        mcpServers: [
          PluginMcpServer(
            pluginId: pluginId,
            name: 'one',
            transport: 'http',
            url: 'https://new.example.com/one',
            oauth: const McpOAuthConfig(
              authorizationUrl: 'https://new.example.com/authorize',
              clientId: 'new-one',
            ),
          ),
          PluginMcpServer(
            pluginId: pluginId,
            name: 'two',
            transport: 'http',
            url: 'https://new.example.com/two',
            oauth: const McpOAuthConfig(
              authorizationUrl: 'https://new.example.com/authorize',
              clientId: 'new-two',
            ),
          ),
        ],
      );
      AppState.mcpCustomMcpPersistenceOverrideForTest = () async {
        app.mcpServers
                .singleWhere((s) => s.canonicalId == '$pluginId/one')
                .toolTimeoutS =
            999;
        throw StateError('persistence failed');
      };
      await expectLater(
        app.mountPluginOwnedMcpServers(replacement, connect: false),
        throwsStateError,
      );
      expect(
        app.mcpServers
            .where((s) => s.ownerPluginId == pluginId)
            .map((s) => s.url),
        ['https://old.example.com/one', 'https://old.example.com/two'],
      );
      expect(
        McpService.I.mcpOAuthConfigFor('$pluginId/one')!.clientId,
        'old-one',
      );
      expect(
        McpService.I.mcpOAuthConfigFor('$pluginId/two')!.clientId,
        'old-two',
      );
    });

    test(
      'rollback restores tool timeout and leaves a failed reconnect disconnected',
      () async {
        final app = AppState.I;
        const pluginId = 'acme/live-rollback-probe';
        const id = '$pluginId/remote';
        var failReconnect = false;
        McpService.I.httpClientForTest = MockClient((request) async {
          if (failReconnect) {
            throw const SocketException('rollback endpoint unavailable');
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final result = switch (body['method']) {
            'initialize' => {
              'protocolVersion': '2024-11-05',
              'capabilities': <String, dynamic>{},
              'serverInfo': {'name': 'rollback', 'version': '1'},
            },
            'tools/list' => {'tools': <dynamic>[]},
            _ => <String, dynamic>{},
          };
          return http.Response(
            jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final initial = NormalizedPluginManifest(
          id: pluginId,
          name: 'live-rollback-probe',
          version: '1.0.0',
          format: PluginFormat.claudeCode,
          rootPath: '/plugins/live-old',
          mcpServers: [
            PluginMcpServer(
              pluginId: pluginId,
              name: 'remote',
              transport: 'http',
              url: 'https://old.example.com/mcp',
            ),
          ],
        );
        PluginContributionRegistry.I.register(
          initial,
          activation: PluginActivation.sessionActive,
        );
        addTearDown(
          () => PluginContributionRegistry.I.unregisterPlugin(pluginId),
        );
        await app.mountPluginOwnedMcpServers(initial, connect: false);
        final server = app.mcpServers.singleWhere((s) => s.canonicalId == id)
          ..toolTimeoutS = 137;
        await McpService.I.connect(server);
        server.connected = true;
        expect(McpService.I.isConnected(id), isTrue);

        AppState.mcpCustomMcpPersistenceOverrideForTest = () async {
          failReconnect = true;
          throw StateError('persistence failed');
        };
        final replacement = NormalizedPluginManifest(
          id: pluginId,
          name: 'live-rollback-probe',
          version: '2.0.0',
          format: PluginFormat.claudeCode,
          rootPath: '/plugins/live-new',
          mcpServers: [
            PluginMcpServer(
              pluginId: pluginId,
              name: 'remote',
              transport: 'http',
              url: 'https://new.example.com/mcp',
            ),
          ],
        );

        await expectLater(
          app.mountPluginOwnedMcpServers(replacement),
          throwsStateError,
        );
        final restored = app.mcpServers.singleWhere((s) => s.canonicalId == id);
        expect(restored.url, 'https://old.example.com/mcp');
        expect(restored.toolTimeoutS, 137);
        expect(restored.connected, isFalse);
        expect(McpService.I.isConnected(id), isFalse);
        expect(
          app.serviceStatusForTest('mcp:$id')?.health,
          ServiceHealth.failed,
        );
      },
    );

    test('overlapping mounts cannot roll back a later transaction', () async {
      final app = AppState.I;
      const pluginId = 'acme/serialized-mount-probe';
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      var writes = 0;
      AppState.mcpOAuthWriteOverrideForTest = (id, config) async {
        writes++;
        if (writes == 1) {
          firstStarted.complete();
          await releaseFirst.future;
          throw StateError('first transaction failed');
        }
      };
      NormalizedPluginManifest manifest(String name, String url) =>
          NormalizedPluginManifest(
            id: pluginId,
            name: 'serialized-mount-probe',
            version: name,
            format: PluginFormat.claudeCode,
            rootPath: '/plugins/$name',
            mcpServers: [
              PluginMcpServer(
                pluginId: pluginId,
                name: name,
                transport: 'http',
                url: url,
                oauth: McpOAuthConfig(
                  authorizationUrl: 'https://auth.example.com/$name',
                  clientId: name,
                ),
              ),
            ],
          );

      final first = app.mountPluginOwnedMcpServers(
        manifest('first', 'https://first.example.com'),
        connect: false,
      );
      await firstStarted.future;
      final second = app.mountPluginOwnedMcpServers(
        manifest('second', 'https://second.example.com'),
        connect: false,
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        app.mcpServers.where((s) => s.ownerPluginId == pluginId),
        isEmpty,
        reason: 'the second mount waits for the first transaction mutex',
      );
      releaseFirst.complete();
      await expectLater(first, throwsStateError);
      await second;
      expect(
        app.mcpServers.map((s) => s.canonicalId),
        contains('$pluginId/second'),
      );
    });

    test(
      'unmounting another plugin does not invalidate an in-flight mount',
      () async {
        final app = AppState.I;
        const mountingPlugin = 'acme/in-flight-mount-probe';
        const otherPlugin = 'acme/other-unmount-probe';
        final initial = NormalizedPluginManifest(
          id: mountingPlugin,
          name: mountingPlugin,
          version: '0.1.0',
          format: PluginFormat.claudeCode,
          rootPath: '/plugins/$mountingPlugin-old',
          mcpServers: [
            PluginMcpServer(
              pluginId: mountingPlugin,
              name: 'remote',
              transport: 'http',
              url: 'https://old.example.com',
            ),
          ],
        );
        await app.mountPluginOwnedMcpServers(initial, connect: false);
        final entered = Completer<void>();
        final release = Completer<void>();
        AppState.mcpOAuthWriteOverrideForTest = (id, config) async {
          entered.complete();
          await release.future;
          throw StateError('mount failed');
        };
        NormalizedPluginManifest manifest(String pluginId) =>
            NormalizedPluginManifest(
              id: pluginId,
              name: pluginId,
              version: '1.0.0',
              format: PluginFormat.claudeCode,
              rootPath: '/plugins/$pluginId',
              mcpServers: [
                PluginMcpServer(
                  pluginId: pluginId,
                  name: 'remote',
                  transport: 'http',
                  url: 'https://$pluginId.example.com',
                  oauth: McpOAuthConfig(
                    authorizationUrl: 'https://auth.example.com/$pluginId',
                    clientId: pluginId,
                  ),
                ),
              ],
            );

        final mounting = app.mountPluginOwnedMcpServers(
          manifest(mountingPlugin),
          connect: false,
        );
        await entered.future;
        final unmounting = app.unmountPluginOwnedMcpServers(
          otherPlugin,
          uninstall: true,
        );
        await Future<void>.delayed(Duration.zero);
        release.complete();

        await expectLater(mounting, throwsStateError);
        await unmounting;
        final restored = app.mcpServers.singleWhere(
          (s) => s.canonicalId == '$mountingPlugin/remote',
        );
        expect(restored.url, 'https://old.example.com');
      },
    );

    test(
      'connect false clears an existing row connection and status',
      () async {
        final app = AppState.I;
        const pluginId = 'acme/connect-false-probe';
        const id = '$pluginId/remote';
        final manifest = NormalizedPluginManifest(
          id: pluginId,
          name: 'connect-false-probe',
          version: '1.0.0',
          format: PluginFormat.claudeCode,
          rootPath: '/plugins/connect-false-probe',
          mcpServers: [
            PluginMcpServer(
              pluginId: pluginId,
              name: 'remote',
              transport: 'http',
              url: 'https://mcp.example.com',
            ),
          ],
        );
        await app.mountPluginOwnedMcpServers(manifest, connect: false);
        final server = app.mcpServers.singleWhere((s) => s.canonicalId == id);
        server.connected = true;
        app.updateServiceStatus('mcp:$id', ServiceHealth.working);

        await app.mountPluginOwnedMcpServers(manifest, connect: false);

        expect(server.connected, isFalse);
        expect(app.serviceStatusForTest('mcp:$id'), isNull);
      },
    );

    test(
      'connect false preserves reconnect intent until explicit unmount',
      () async {
        final app = AppState.I;
        final prefs = await SharedPreferences.getInstance();
        const pluginId = 'acme/connect-false-intent-probe';
        const id = '$pluginId/remote';
        final manifest = NormalizedPluginManifest(
          id: pluginId,
          name: 'connect-false-intent-probe',
          version: '1.0.0',
          format: PluginFormat.claudeCode,
          rootPath: '/plugins/connect-false-intent-probe',
          mcpServers: [
            PluginMcpServer(
              pluginId: pluginId,
              name: 'remote',
              transport: 'http',
              url: 'https://mcp.example.com',
            ),
          ],
        );
        await prefs.setStringList('ovid_mcp_connected_v1', [id]);

        await app.mountPluginOwnedMcpServers(manifest, connect: false);
        await app.persistMcpIntent();
        expect(prefs.getStringList('ovid_mcp_connected_v1'), [id]);

        await app.unmountPluginOwnedMcpServers(pluginId, uninstall: false);
        expect(prefs.getStringList('ovid_mcp_connected_v1'), isEmpty);
      },
    );

    test('unmount waits for mount rollback and wins the final state', () async {
      final app = AppState.I;
      const pluginId = 'acme/unmount-race-probe';
      const id = '$pluginId/remote';
      final initial = NormalizedPluginManifest(
        id: pluginId,
        name: 'unmount-race-probe',
        version: '1.0.0',
        format: PluginFormat.claudeCode,
        rootPath: '/plugins/unmount-race-old',
        mcpServers: [
          PluginMcpServer(
            pluginId: pluginId,
            name: 'remote',
            transport: 'http',
            url: 'https://old.example.com',
            oauth: const McpOAuthConfig(
              authorizationUrl: 'https://auth.example.com/old',
              clientId: 'old-client',
            ),
          ),
        ],
      );
      await app.mountPluginOwnedMcpServers(initial, connect: false);
      final entered = Completer<void>();
      final release = Completer<void>();
      AppState.mcpOAuthWriteOverrideForTest = (id, config) async {
        entered.complete();
        await release.future;
        throw StateError('mount failed');
      };
      final replacement = NormalizedPluginManifest(
        id: pluginId,
        name: 'unmount-race-probe',
        version: '2.0.0',
        format: PluginFormat.claudeCode,
        rootPath: '/plugins/unmount-race-new',
        mcpServers: [
          PluginMcpServer(
            pluginId: pluginId,
            name: 'remote',
            transport: 'http',
            url: 'https://new.example.com',
            oauth: const McpOAuthConfig(
              authorizationUrl: 'https://auth.example.com/new',
              clientId: 'new-client',
            ),
          ),
        ],
      );

      final mounting = app.mountPluginOwnedMcpServers(
        replacement,
        connect: false,
      );
      await entered.future;
      final unmounting = app.unmountPluginOwnedMcpServers(
        pluginId,
        uninstall: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(app.mcpServers.any((s) => s.ownerPluginId == pluginId), isTrue);

      release.complete();
      await expectLater(mounting, throwsStateError);
      await unmounting;
      expect(app.mcpServers.where((s) => s.ownerPluginId == pluginId), isEmpty);
      expect(McpService.I.mcpOAuthConfigFor(id), isNull);
      expect(app.serviceStatusForTest('mcp:$id'), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('ovid_custom_mcp_servers_v1'), isEmpty);
    });

    test(
      'legacy mount serializes with normalized unmount and preserves ownership',
      () async {
        final app = AppState.I;
        const pluginId = 'acme/legacy-race-probe';
        const serverId = '$pluginId/remote';
        final root = await Directory.systemTemp.createTemp('ovid-legacy-race-');
        AppState.pluginCacheRootOverrideForTest = root;
        addTearDown(() {
          AppState.pluginCacheRootOverrideForTest = null;
          root.deleteSync(recursive: true);
        });
        final cache = await app.pluginCacheDirFor(pluginId);
        cache.createSync(recursive: true);
        File('${cache.path}/.mcp.json').writeAsStringSync(
          jsonEncode({
            'mcpServers': {
              'remote': {
                'type': 'http',
                'url': 'https://legacy.example.com',
                'oauth': {
                  'authorization_url': 'https://auth.example.com/legacy',
                  'client_id': 'legacy-client',
                },
              },
            },
          }),
        );

        final entered = Completer<void>();
        final release = Completer<void>();
        AppState.mcpOAuthWriteOverrideForTest = (id, config) async {
          expect(id, serverId);
          expect(config.clientId, 'legacy-client');
          entered.complete();
          await release.future;
        };

        final mounting = app.mountPluginMcpServers(pluginId);
        await entered.future;
        final unmounting = app.unmountPluginOwnedMcpServers(
          pluginId,
          uninstall: true,
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          app.mcpServers.where((s) => s.ownerPluginId == pluginId),
          isEmpty,
          reason: 'normalized unmount must wait for the legacy transaction',
        );

        release.complete();
        await mounting;
        await unmounting;
        expect(
          app.mcpServers.where((s) => s.ownerPluginId == pluginId),
          isEmpty,
        );
        expect(McpService.I.mcpOAuthConfigFor(serverId), isNull);
      },
    );

    test(
      'stale mount removes OAuth sidecars for a newly declared server ID',
      () async {
        final app = AppState.I;
        const pluginId = 'acme/unmount-new-id-race-probe';
        const oldId = '$pluginId/old';
        const newId = '$pluginId/new';
        McpService.oauthSecureStorageDisabledForTest = false;
        final initial = NormalizedPluginManifest(
          id: pluginId,
          name: 'unmount-new-id-race-probe',
          version: '1.0.0',
          format: PluginFormat.claudeCode,
          rootPath: '/plugins/unmount-new-id-old',
          mcpServers: [
            PluginMcpServer(
              pluginId: pluginId,
              name: 'old',
              transport: 'http',
              url: 'https://old.example.com',
            ),
          ],
        );
        await app.mountPluginOwnedMcpServers(initial, connect: false);

        final entered = Completer<void>();
        final release = Completer<void>();
        AppState.mcpOAuthWriteOverrideForTest = (id, config) async {
          await McpService.I.setMcpOAuthConfig(id, config);
          entered.complete();
          await release.future;
          throw StateError('mount failed after OAuth registration');
        };
        final replacement = NormalizedPluginManifest(
          id: pluginId,
          name: 'unmount-new-id-race-probe',
          version: '2.0.0',
          format: PluginFormat.claudeCode,
          rootPath: '/plugins/unmount-new-id-new',
          mcpServers: [
            PluginMcpServer(
              pluginId: pluginId,
              name: 'new',
              transport: 'http',
              url: 'https://new.example.com',
              oauth: const McpOAuthConfig(
                authorizationUrl: 'https://auth.example.com/new',
                clientId: 'new-client',
              ),
            ),
          ],
        );

        final mounting = app.mountPluginOwnedMcpServers(
          replacement,
          connect: false,
        );
        await entered.future;
        final unmounting = app.unmountPluginOwnedMcpServers(
          pluginId,
          uninstall: true,
        );
        release.complete();

        await expectLater(mounting, throwsStateError);
        await unmounting;
        expect(
          app.mcpServers.where((s) => s.ownerPluginId == pluginId),
          isEmpty,
        );
        expect(McpService.I.mcpOAuthConfigFor(newId), isNull);
        expect(await McpService.I.mcpOAuthTokenFor(newId), isNull);
        expect(
          await ovidSecureStorage().read(key: 'ovid_mcp_oauth_cfg_$newId'),
          isNull,
        );
        expect(
          await ovidSecureStorage().read(key: 'ovid_mcp_oauth_$newId'),
          isNull,
        );
        expect(McpService.I.mcpOAuthConfigFor(oldId), isNull);
      },
    );
  });
}
