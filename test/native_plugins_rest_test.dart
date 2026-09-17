import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/rest_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Framework tests for the declarative REST engine + special engines
/// (NP4 Task 1): descriptor mapping, auth injection per kind,
/// configure-first gating, path substitution, verbatim errors, timeouts,
/// truncation, form bodies, SigV4, RESP, and Obsidian vault files.
///
/// HTTP tests use [MockClient] (NP2 established pattern) — never real
/// network, except the RESP round-trip which runs against a loopback
/// [ServerSocket] on an ephemeral port.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NativePluginRegistry.I.clearForTest();
  });

  tearDown(() {
    NativePluginRegistry.I.clearForTest();
  });

  RestServiceDescriptor simpleGet({
    String pluginName = 'Example API',
    String baseUrl = 'https://api.example.com',
    RestAuthKind auth = RestAuthKind.none,
    String? authHeader,
    String authPrefix = '',
    String authQueryKey = '',
    String authUsernameKey = '',
    String credentialKey = '',
    String credentialLabel = '',
    List<NativePluginConfigField> extraConfig = const [],
    List<RestToolDef>? tools,
  }) {
    return RestServiceDescriptor(
      pluginName: pluginName,
      baseUrl: baseUrl,
      auth: auth,
      authHeader: authHeader,
      authPrefix: authPrefix,
      authQueryKey: authQueryKey,
      authUsernameKey: authUsernameKey,
      credentialKey: credentialKey,
      credentialLabel: credentialLabel,
      extraConfig: extraConfig,
      tools: tools ??
          const [
            RestToolDef(
              name: 'get_thing',
              description: 'Fetch a thing.',
              method: 'GET',
              path: '/things',
              inputSchema: {
                'type': 'object',
                'properties': {
                  'limit': {'type': 'number'},
                },
              },
              queryArgs: ['limit'],
            ),
          ],
    );
  }

  /// Builds a capability over [descriptor] with requests captured by
  /// [onRequest], then configures [secret]/[extras] via the real config
  /// store (secure-storage + prefs mocks from setUp).
  Future<RestApiCapability> configuredCap(
    RestServiceDescriptor descriptor,
    Future<http.Response> Function(http.Request) onRequest, {
    String? secret,
    Map<String, String> extras = const {},
  }) async {
    final cap = RestApiCapability(
      descriptor,
      client: MockClient((request) async => onRequest(request)),
    );
    final values = <String, String>{...extras};
    if (secret != null && descriptor.credentialKey.isNotEmpty) {
      values[descriptor.credentialKey] = secret;
    }
    if (values.isNotEmpty) await cap.configure(values);
    return cap;
  }

  group('descriptor mapping', () {
    test('tools mirror the descriptor defs', () {
      final cap = RestApiCapability(simpleGet());
      expect(cap.pluginName, 'Example API');
      final tools = {for (final t in cap.tools) t.name: t};
      expect(tools.keys, contains('get_thing'));
      expect(
        tools['get_thing']!.description,
        contains('Fetch a thing'),
      );
    });

    test('tool schemas always carry timeout_seconds', () {
      final cap = RestApiCapability(simpleGet());
      final schema = cap.tools.single.inputSchema;
      final props = schema['properties'] as Map;
      expect(props.containsKey('timeout_seconds'), isTrue);
    });

    test('configFields are the secret credential plus extras', () {
      final cap = RestApiCapability(
        simpleGet(
          auth: RestAuthKind.bearerHeader,
          authHeader: 'Authorization',
          authPrefix: 'Bearer ',
          credentialKey: 'bot_token',
          credentialLabel: 'Bot token',
          extraConfig: const [
            NativePluginConfigField(
              key: 'workspace',
              label: 'Workspace',
            ),
          ],
        ),
      );
      final fields = {for (final f in cap.configFields) f.key: f};
      expect(fields.keys, containsAll(['bot_token', 'workspace']));
      expect(fields['bot_token']!.secret, isTrue);
      expect(fields['bot_token']!.label, 'Bot token');
      expect(fields['workspace']!.secret, isFalse);
    });

    test('auth-none descriptor without credential has no secret field', () {
      final cap = RestApiCapability(simpleGet());
      expect(cap.configFields, isEmpty);
    });

    test('unknown tool throws ArgumentError', () async {
      final cap = RestApiCapability(
        simpleGet(),
        client: MockClient((_) async => http.Response('ok', 200)),
      );
      await expectLater(
        cap.callTool('nope', {}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('registerRestServices registers one capability per descriptor', () {
      registerRestServices([
        simpleGet(pluginName: 'Alpha API'),
        simpleGet(pluginName: 'Beta API'),
      ]);
      expect(NativePluginRegistry.I.has('Alpha API'), isTrue);
      expect(NativePluginRegistry.I.has('Beta API'), isTrue);
      expect(
        NativePluginRegistry.I.capabilityForSlug('alpha_api'),
        isA<RestApiCapability>(),
      );
    });
  });

  group('auth injection', () {
    test('bearerHeader injects Authorization: Bearer <secret>', () async {
      http.Request? seen;
      final cap = await configuredCap(
        simpleGet(
          auth: RestAuthKind.bearerHeader,
          authHeader: 'Authorization',
          authPrefix: 'Bearer ',
          credentialKey: 'bot_token',
          credentialLabel: 'Bot token',
        ),
        (request) async {
          seen = request;
          return http.Response('{"ok":true}', 200);
        },
        secret: 'xoxb-123',
      );
      final out = await cap.callTool('get_thing', {});
      expect(out, contains('"ok":true'));
      expect(seen!.headers['Authorization'], 'Bearer xoxb-123');
    });

    test('apiKeyHeader injects a custom header without prefix', () async {
      http.Request? seen;
      final cap = await configuredCap(
        simpleGet(
          auth: RestAuthKind.apiKeyHeader,
          authHeader: 'X-Figma-Token',
          credentialKey: 'token',
          credentialLabel: 'Personal access token',
        ),
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        secret: 'fig-abc',
      );
      await cap.callTool('get_thing', {});
      expect(seen!.headers['X-Figma-Token'], 'fig-abc');
    });

    test('queryKey appends the secret as a query parameter', () async {
      http.Request? seen;
      final cap = await configuredCap(
        simpleGet(
          auth: RestAuthKind.queryKey,
          authQueryKey: 'api_key',
          credentialKey: 'api_key',
          credentialLabel: 'API key',
        ),
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        secret: 'cal-secret',
      );
      await cap.callTool('get_thing', {'limit': 5});
      expect(seen!.url.queryParameters['api_key'], 'cal-secret');
      expect(seen!.url.queryParameters['limit'], '5');
    });

    test('basic injects base64(username:secret)', () async {
      http.Request? seen;
      final cap = await configuredCap(
        simpleGet(
          auth: RestAuthKind.basic,
          authUsernameKey: 'account_sid',
          credentialKey: 'auth_token',
          credentialLabel: 'Auth token',
          extraConfig: const [
            NativePluginConfigField(
              key: 'account_sid',
              label: 'Account SID',
            ),
          ],
        ),
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        secret: 'tok-secret',
        extras: {'account_sid': 'AC123'},
      );
      await cap.callTool('get_thing', {});
      expect(
        seen!.headers['Authorization'],
        'Basic ${base64Encode(utf8.encode('AC123:tok-secret'))}',
      );
    });

    test('none sends no auth material', () async {
      http.Request? seen;
      final cap = RestApiCapability(
        simpleGet(),
        client: MockClient((request) async {
          seen = request;
          return http.Response('{}', 200);
        }),
      );
      await cap.callTool('get_thing', {});
      expect(seen!.headers.containsKey('Authorization'), isFalse);
      expect(seen!.url.queryParameters.containsKey('api_key'), isFalse);
    });
  });

  group('configure-first gating', () {
    test('missing creds return the configure message, secret absent', () async {
      const secret = 'super-secret-xyz-999';
      final descriptor = simpleGet(
        pluginName: 'Example API',
        auth: RestAuthKind.bearerHeader,
        authHeader: 'Authorization',
        authPrefix: 'Bearer ',
        credentialKey: 'bot_token',
        credentialLabel: 'Bot token',
      );
      final cap = RestApiCapability(
        descriptor,
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      final message = await cap.callTool('get_thing', {});
      expect(message, contains('Configure Bot token first'));
      expect(message, contains('bot_token'));
      // The secret value must never be echoed into the message.
      expect(message, isNot(contains(secret)));

      // And once configured, the same secret authenticates the request.
      http.Request? seen;
      final authed = await configuredCap(
        descriptor,
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        secret: secret,
      );
      await authed.callTool('get_thing', {});
      expect(seen!.headers['Authorization'], 'Bearer $secret');
    });

    test('missing basic username names its own field', () async {
      final cap = RestApiCapability(
        simpleGet(
          auth: RestAuthKind.basic,
          authUsernameKey: 'account_sid',
          credentialKey: 'auth_token',
          credentialLabel: 'Auth token',
          extraConfig: const [
            NativePluginConfigField(
              key: 'account_sid',
              label: 'Account SID',
            ),
          ],
        ),
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      // Secret configured but username missing: still gated.
      await cap.configure({'auth_token': 'tok'});
      final message = await cap.callTool('get_thing', {});
      expect(message, contains('Configure Account SID first'));
      expect(message, isNot(contains('tok')));
    });
  });

  group('paths, query, and bodies', () {
    test('{arg} substitution encodes the value', () async {
      http.Request? seen;
      final cap = await configuredCap(
        simpleGet(
          tools: const [
            RestToolDef(
              name: 'history',
              description: 'Channel history.',
              method: 'GET',
              path: '/channels/{channel}/history',
              inputSchema: {
                'type': 'object',
                'properties': {
                  'channel': {'type': 'string'},
                },
              },
              required: ['channel'],
            ),
          ],
        ),
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
      );
      await cap.callTool('history', {'channel': 'C123/X Y'});
      expect(
        seen!.url.toString(),
        'https://api.example.com/channels/C123%2FX%20Y/history',
      );
    });

    test('missing path arg throws ArgumentError', () async {
      final cap = RestApiCapability(
        simpleGet(
          tools: const [
            RestToolDef(
              name: 'history',
              description: 'Channel history.',
              method: 'GET',
              path: '/channels/{channel}/history',
              inputSchema: {'type': 'object'},
              required: ['channel'],
            ),
          ],
        ),
        client: MockClient((_) async => http.Response('[]', 200)),
      );
      await expectLater(
        cap.callTool('history', {}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('missing required arg throws ArgumentError', () async {
      final cap = RestApiCapability(
        simpleGet(
          tools: const [
            RestToolDef(
              name: 'send',
              description: 'Send.',
              method: 'POST',
              path: '/send',
              inputSchema: {'type': 'object'},
              required: ['to'],
            ),
          ],
        ),
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await expectLater(
        cap.callTool('send', {}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('queryArgs map to URL query params', () async {
      http.Request? seen;
      final cap = await configuredCap(
        simpleGet(),
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
      );
      await cap.callTool('get_thing', {'limit': 20});
      expect(seen!.url.queryParameters['limit'], '20');
    });

    test('jsonBodyArg sends the arg map as a JSON body', () async {
      http.Request? seen;
      final cap = await configuredCap(
        simpleGet(
          tools: const [
            RestToolDef(
              name: 'create_issue',
              description: 'Create.',
              method: 'POST',
              path: '/issues',
              inputSchema: {'type': 'object'},
              jsonBodyArg: 'fields',
            ),
          ],
        ),
        (request) async {
          seen = request;
          return http.Response('{"id":1}', 200);
        },
      );
      final out = await cap.callTool('create_issue', {
        'fields': {
          'title': 'Bug',
          'labels': ['a', 'b'],
        },
      });
      expect(out, contains('"id":1'));
      expect(seen!.method, 'POST');
      expect(seen!.headers['content-type'], contains('application/json'));
      expect(
        jsonDecode(seen!.body) as Map,
        {'title': 'Bug', 'labels': ['a', 'b']},
      );
    });

    test('jsonBodyArg defaults to an empty object', () async {
      http.Request? seen;
      final cap = await configuredCap(
        simpleGet(
          tools: const [
            RestToolDef(
              name: 'create_issue',
              description: 'Create.',
              method: 'POST',
              path: '/issues',
              inputSchema: {'type': 'object'},
              jsonBodyArg: 'fields',
            ),
          ],
        ),
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
      );
      await cap.callTool('create_issue', {});
      expect(seen!.body, '{}');
    });

    test('formBodyArg sends url-encoded bodies (Stripe style)', () async {
      http.Request? seen;
      final cap = await configuredCap(
        simpleGet(
          auth: RestAuthKind.bearerHeader,
          authHeader: 'Authorization',
          authPrefix: 'Bearer ',
          credentialKey: 'secret_key',
          credentialLabel: 'Secret key',
          tools: const [
            RestToolDef(
              name: 'create_charge',
              description: 'Charge.',
              method: 'POST',
              path: '/charges',
              inputSchema: {'type': 'object'},
              formBodyArg: 'params',
            ),
          ],
        ),
        (request) async {
          seen = request;
          return http.Response('{"paid":true}', 200);
        },
        secret: 'sk-test',
      );
      await cap.callTool('create_charge', {
        'params': {'amount': 500, 'currency': 'usd'},
      });
      expect(
        seen!.headers['content-type'],
        contains('application/x-www-form-urlencoded'),
      );
      final form = Uri.splitQueryString(seen!.body);
      expect(form, {'amount': '500', 'currency': 'usd'});
    });

    test('secret stored under credentialKey fills a path segment', () async {
      // Telegram style: the secret travels in the path, not a header.
      http.Request? seen;
      final descriptor = simpleGet(
        baseUrl: 'https://api.telegram.org',
        auth: RestAuthKind.none,
        credentialKey: 'bot_token',
        credentialLabel: 'Bot token',
        tools: const [
          RestToolDef(
            name: 'get_me',
            description: 'Bot identity.',
            method: 'GET',
            path: '/bot{bot_token}/getMe',
            inputSchema: {'type': 'object'},
          ),
        ],
      );
      final gated = RestApiCapability(
        descriptor,
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      expect(
        await gated.callTool('get_me', {}),
        contains('Configure Bot token first'),
      );
      final cap = await configuredCap(
        descriptor,
        (request) async {
          seen = request;
          return http.Response('{"ok":true}', 200);
        },
        secret: 'tok-abc',
      );
      await cap.callTool('get_me', {});
      expect(
        seen!.url.toString(),
        'https://api.telegram.org/bottok-abc/getMe',
      );
    });
  });

  group('errors, timeouts, truncation', () {
    test('non-2xx responses come back verbatim with the status', () async {
      const body = '{"ok":false,"error":"channel_not_found"}';
      final cap = RestApiCapability(
        simpleGet(),
        client: MockClient((_) async => http.Response(body, 404)),
      );
      final out = await cap.callTool('get_thing', {});
      expect(out, contains('404'));
      expect(out, contains(body));
    });

    test('HTTP 401 bodies pass through verbatim', () async {
      const body = '{"detail":"Invalid token."}';
      final cap = await configuredCap(
        simpleGet(
          auth: RestAuthKind.bearerHeader,
          authHeader: 'Authorization',
          authPrefix: 'Bearer ',
          credentialKey: 'token',
          credentialLabel: 'Token',
        ),
        (_) async => http.Response(body, 401),
        secret: 'bad-token',
      );
      final out = await cap.callTool('get_thing', {});
      expect(out, contains('401'));
      expect(out, contains(body));
    });

    test('timeout resolves: default 30, override kept, clamped 5..300',
        () {
      expect(RestApiCapability.resolveTimeoutSeconds({}), 30);
      expect(RestApiCapability.resolveTimeoutSeconds({'timeout_seconds': 60}),
          60);
      expect(RestApiCapability.resolveTimeoutSeconds({'timeout_seconds': '10'}),
          10);
      expect(RestApiCapability.resolveTimeoutSeconds({'timeout_seconds': 1}), 5);
      expect(
          RestApiCapability.resolveTimeoutSeconds({'timeout_seconds': 1000}),
          300);
      expect(
        () => RestApiCapability.resolveTimeoutSeconds({'timeout_seconds': 'x'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('slow servers surface a timeout FormatException', () async {
      final cap = RestApiCapability(
        simpleGet(),
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(seconds: 10));
          return http.Response('too late', 200);
        }),
      );
      await expectLater(
        cap.callTool('get_thing', {'timeout_seconds': 5}),
        throwsA(isA<FormatException>()),
      );
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('oversized bodies truncate with the omission notice', () async {
      final big = 'x' * 7000;
      final cap = RestApiCapability(
        simpleGet(),
        client: MockClient((_) async => http.Response(big, 200)),
      );
      final out = await cap.callTool('get_thing', {});
      expect(out.length, lessThan(big.length));
      expect(out, contains('characters omitted'));
      expect(out, contains(big.substring(0, 100)));
      expect(out, contains(big.substring(big.length - 100)));
    });
  });

  group('SigV4', () {
    test('AWS IAM documentation vector signs exactly', () {
      // docs.aws.amazon.com "Signature Version 4 signing process" example:
      // GET iam Action=ListUsers, 20150830T123600Z, AKIDEXAMPLE. Expected
      // value cross-checked against an independent Python stdlib
      // (hashlib/hmac) chain built over botocore's canonical request.
      final auth = s3Authorization(
        accessKeyId: 'AKIDEXAMPLE',
        secretAccessKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
        region: 'us-east-1',
        service: 'iam',
        method: 'GET',
        canonicalUri: '/',
        queryParameters: {
          'Action': 'ListUsers',
          'Version': '2010-05-08',
        },
        headers: {
          'content-type': 'application/x-www-form-urlencoded; charset=utf-8',
          'host': 'iam.amazonaws.com',
          'x-amz-date': '20150830T123600Z',
        },
        payloadHash:
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        amzDate: DateTime.utc(2015, 8, 30, 12, 36),
      );
      expect(
        auth,
        'AWS4-HMAC-SHA256 '
        'Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, '
        'SignedHeaders=content-type;host;x-amz-date, '
        'Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7',
      );
    });

    test('signing is deterministic and keyed', () {
      String sign(String secret) => s3Authorization(
            accessKeyId: 'AKID',
            secretAccessKey: secret,
            region: 'eu-west-1',
            method: 'GET',
            canonicalUri: '/',
            queryParameters: const {},
            headers: const {
              'host': 's3.eu-west-1.amazonaws.com',
              'x-amz-date': '20260101T000000Z',
            },
            payloadHash:
                'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
            amzDate: DateTime.utc(2026),
          );
      expect(sign('aaa'), sign('aaa'));
      expect(sign('aaa'), isNot(sign('bbb')));
      expect(sign('aaa'), startsWith('AWS4-HMAC-SHA256 Credential=AKID/'));
    });
  });

  group('RESP', () {
    test('respEncode emits byte-exact arrays of bulk strings', () {
      expect(
        respEncode(['SET', 'key', 'value']),
        '*3\r\n\$3\r\nSET\r\n\$3\r\nkey\r\n\$5\r\nvalue\r\n',
      );
      expect(respEncode([]), '*0\r\n');
      // Lengths are UTF-8 byte counts, not code-unit counts.
      expect(
        respEncode(['héllo']),
        '*1\r\n\$6\r\nhéllo\r\n',
      );
    });

    test('round-trip against a loopback fake server', () async {
      // Tiny scripted Redis: canned replies served in connection order.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final received = <String>[];
      final replies = <String>[
        '+PONG\r\n',
        '\$5\r\nhello\r\n',
        '\$-1\r\n',
        '*2\r\n\$3\r\nfoo\r\n\$3\r\nbar\r\n',
      ];
      var served = 0;
      final sub = server.listen((Socket socket) {
        final buffer = <int>[];
        Timer? flush;
        socket.listen(
          (chunk) {
            buffer.addAll(chunk);
            // Small test frames arrive whole; a short grace window absorbs
            // loopback segmentation without a full framing parser.
            flush?.cancel();
            flush = Timer(const Duration(milliseconds: 100), () {
              if (served < replies.length) {
                received.add(utf8.decode(buffer));
                buffer.clear();
                socket.add(utf8.encode(replies[served]));
                served++;
              }
            });
          },
          onDone: () {
            flush?.cancel();
            socket.destroy();
          },
        );
      });
      addTearDown(() async {
        await sub.cancel();
        await server.close();
      });

      var factories = 0;
      final client = RespClient(
        host: '127.0.0.1',
        port: server.port,
        socketFactory: (host, port) async {
          factories++;
          return Socket.connect(host, port);
        },
      );
      addTearDown(client.close);

      expect(await client.command(['PING']), 'PONG');
      expect(await client.command(['GET', 'greeting']), 'hello');
      expect(await client.command(['GET', 'missing']), isNull);
      expect(
        await client.command(['KEYS', '*']),
        ['foo', 'bar'],
      );

      // The injectable factory carried every connection.
      expect(factories, greaterThan(0));
      // The server saw byte-exact RESP frames from respEncode.
      expect(received.singleWhere((r) => r.contains('PING')), respEncode(['PING']));
      expect(
        received.singleWhere((r) => r.contains('greeting')),
        respEncode(['GET', 'greeting']),
      );
    });

    test('error replies throw RespError', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sub = server.listen((Socket socket) {
        socket.listen((_) {
          socket.add(utf8.encode('-ERR unknown command\r\n'));
        }, onDone: socket.destroy);
      });
      addTearDown(() async {
        await sub.cancel();
        await server.close();
      });
      final client = RespClient(host: '127.0.0.1', port: server.port);
      addTearDown(client.close);
      await expectLater(
        client.command(['BOGUS']),
        throwsA(isA<RespError>()),
      );
    });

    test('password authenticates before the first command', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final received = <String>[];
      final sub = server.listen((Socket socket) {
        socket.listen(
          (chunk) {
            received.add(utf8.decode(chunk));
            if (received.length == 1) {
              socket.add(utf8.encode('+OK\r\n'));
            } else {
              socket.add(utf8.encode('+OK\r\n'));
            }
          },
          onDone: socket.destroy,
        );
      });
      addTearDown(() async {
        await sub.cancel();
        await server.close();
      });
      final client = RespClient(
        host: '127.0.0.1',
        port: server.port,
        password: 's3cret',
      );
      addTearDown(client.close);
      expect(await client.command(['PING']), 'OK');
      expect(received.first, respEncode(['AUTH', 's3cret']));
    });
  });

  group('VaultFiles (Obsidian)', () {
    late Directory vault;

    setUp(() async {
      vault = await Directory.systemTemp.createTemp('vault_test_');
    });

    tearDown(() async {
      if (await vault.exists()) await vault.delete(recursive: true);
    });

    test('write, read, list, append, and search round-trip', () async {
      final files = VaultFiles(vault.path);
      await files.writeNote('ideas/today.md', '# Today\nBuy milk');
      await files.writeNote('ideas/todo.md', '# Todo\nBuy MILK and eggs');
      await files.appendNote('ideas/today.md', '\nCall mom');

      expect(await files.readNote('ideas/today.md'), contains('Call mom'));
      expect(
        await files.listNotes(),
        containsAll([
          'ideas/today.md',
          'ideas/todo.md',
        ]),
      );
      final hits = await files.searchNotes('milk');
      expect(hits, containsAll(['ideas/today.md', 'ideas/todo.md']));
      expect(await files.searchNotes('no-such-phrase'), isEmpty);
    });

    test('paths escaping the vault root are refused', () async {
      final files = VaultFiles(vault.path);
      await files.writeNote('ok.md', 'safe');
      for (final evil in [
        '../escape.md',
        'sub/../../escape.md',
        '/tmp/absolute.md',
      ]) {
        await expectLater(
          files.readNote(evil),
          throwsA(isA<ArgumentError>()),
          reason: evil,
        );
        await expectLater(
          files.writeNote(evil, 'x'),
          throwsA(isA<ArgumentError>()),
          reason: evil,
        );
        await expectLater(
          files.appendNote(evil, 'x'),
          throwsA(isA<ArgumentError>()),
          reason: evil,
        );
      }
      // The vault itself is untouched by the attempts.
      expect(await files.listNotes(), ['ok.md']);
    });

    test('reading a missing note throws ArgumentError', () async {
      final files = VaultFiles(vault.path);
      await expectLater(
        files.readNote('ghost.md'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
