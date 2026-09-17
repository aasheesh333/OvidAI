import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/rest_descriptors_infra.dart';
import 'package:ovid_ai/core/native_plugins/rest_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Deploy & infra batch tests (NP4 Task 6): one MockClient-canned test per
/// tool asserting the REQUEST side (URL, method, auth header, body shape —
/// incl. Railway GraphQL bodies, Heroku's Accept header, Vercel Deploy's
/// gitSource body), configure-first gating per service, Docker's
/// unreachable-honest message, K8s 403 passthrough, and roster halves.
///
/// HTTP never leaves the process: every capability runs over [MockClient].
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pluginNames = [
    'Vercel MCP',
    'Vercel Deploy',
    'Railway MCP',
    'Heroku MCP',
    'DigitalOcean MCP',
    'Cloudflare MCP',
    'Docker MCP',
    'Kubernetes MCP',
    'Terraform MCP',
    'Zapier MCP',
    'Make.com MCP',
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NativePluginRegistry.I.clearForTest();
    registerInfra();
    // Scrub any secret stored by an earlier test so the configure-first
    // tests below observe a genuinely empty store.
    for (final name in pluginNames) {
      final cap = NativePluginRegistry.I.capabilityFor(name);
      await NativePluginConfigStore.I.clear(
        pluginName: name,
        fields: cap!.configFields,
      );
    }
    NativePluginRegistry.I.clearForTest();
  });

  tearDown(() {
    NativePluginRegistry.I.clearForTest();
  });

  /// Wraps the named infra capability in a MockClient-backed capability,
  /// configuring [values] through the real config store (secure-storage +
  /// prefs mocks from setUp).
  Future<NativePluginCapability> capFor(
    String pluginName,
    Future<http.Response> Function(http.Request) onRequest, {
    Map<String, String> values = const {},
  }) async {
    final client = MockClient((request) async => onRequest(request));
    late final NativePluginCapability cap;
    switch (pluginName) {
      case 'Vercel MCP':
        cap = VercelMcpCapability(client: client);
      case 'Vercel Deploy':
        cap = VercelDeployCapability(client: client);
      case 'Railway MCP':
        cap = RailwayCapability(client: client);
      case 'Heroku MCP':
        cap = HerokuCapability(client: client);
      case 'DigitalOcean MCP':
        cap = RestApiCapability(
          infraDescriptors.firstWhere((d) => d.pluginName == pluginName),
          client: client,
        );
      case 'Cloudflare MCP':
        cap = CloudflareCapability(client: client);
      case 'Docker MCP':
        cap = DockerCapability(client: client);
      case 'Kubernetes MCP':
        cap = KubernetesCapability(client: client);
      case 'Terraform MCP':
        cap = TerraformCapability(client: client);
      case 'Zapier MCP':
        cap = ZapierCapability(client: client);
      case 'Make.com MCP':
        cap = MakeCapability(client: client);
      default:
        throw ArgumentError('No infra capability: $pluginName');
    }
    if (values.isNotEmpty) await cap.configure(values);
    return cap;
  }

  group('descriptors', () {
    test('batch exposes the 11 spec-exact plugin names', () {
      expect(
        infraDescriptors.map((d) => d.pluginName),
        containsAll(pluginNames),
      );
      expect(infraDescriptors, hasLength(11));
    });

    test('auth schemes match spec §4.4', () {
      final byName = {for (final d in infraDescriptors) d.pluginName: d};
      expect(byName['Vercel MCP']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Vercel MCP']!.authPrefix, 'Bearer ');
      expect(byName['Vercel Deploy']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Railway MCP']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Heroku MCP']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Heroku MCP']!.authPrefix, 'Bearer ');
      expect(byName['DigitalOcean MCP']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Cloudflare MCP']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Docker MCP']!.auth, RestAuthKind.none);
      expect(byName['Kubernetes MCP']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Kubernetes MCP']!.authPrefix, 'Bearer ');
      expect(byName['Terraform MCP']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Zapier MCP']!.auth, RestAuthKind.none);
      expect(byName['Make.com MCP']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Make.com MCP']!.authPrefix, 'Token ');
    });

    test('fixed bases match spec §4.4', () {
      final byName = {for (final d in infraDescriptors) d.pluginName: d};
      expect(byName['Vercel MCP']!.baseUrl, 'https://api.vercel.com');
      expect(byName['Vercel Deploy']!.baseUrl, 'https://api.vercel.com');
      expect(
        byName['Railway MCP']!.baseUrl,
        'https://backboard.railway.app/graphql/v2',
      );
      expect(byName['Heroku MCP']!.baseUrl, 'https://api.heroku.com');
      expect(
        byName['DigitalOcean MCP']!.baseUrl,
        'https://api.digitalocean.com/v2',
      );
      expect(
        byName['Cloudflare MCP']!.baseUrl,
        'https://api.cloudflare.com/client/v4',
      );
      expect(
        byName['Terraform MCP']!.baseUrl,
        'https://app.terraform.io/api/v2',
      );
    });

    test('tool rosters match spec §4.4', () {
      Iterable<String> toolsOf(String name) => infraDescriptors
          .firstWhere((d) => d.pluginName == name)
          .tools
          .map((t) => t.name);
      expect(
        toolsOf('Vercel MCP'),
        containsAll([
          'list_projects',
          'list_deployments',
          'get_deployment',
          'list_domains',
        ]),
      );
      expect(
        toolsOf('Vercel Deploy'),
        containsAll([
          'list_deployments',
          'get_deployment',
          'create_deployment',
          'cancel_deployment',
        ]),
      );
      expect(
        toolsOf('Railway MCP'),
        containsAll(['list_projects', 'list_services', 'list_deployments']),
      );
      expect(
        toolsOf('Heroku MCP'),
        containsAll([
          'list_apps',
          'get_app',
          'list_dynos',
          'restart_dynos',
          'get_config',
        ]),
      );
      expect(
        toolsOf('DigitalOcean MCP'),
        containsAll([
          'list_droplets',
          'get_droplet',
          'list_domains',
          'list_domain_records',
        ]),
      );
      expect(
        toolsOf('Cloudflare MCP'),
        containsAll(['list_zones', 'list_dns', 'create_dns', 'delete_dns']),
      );
      expect(
        toolsOf('Docker MCP'),
        containsAll(['list_containers', 'list_images', 'inspect_container']),
      );
      expect(
        toolsOf('Kubernetes MCP'),
        containsAll([
          'list_pods',
          'list_deployments',
          'list_services',
          'get_pod',
          'pod_logs',
        ]),
      );
      expect(
        toolsOf('Terraform MCP'),
        containsAll(['list_workspaces', 'list_runs', 'create_run']),
      );
      expect(toolsOf('Zapier MCP'), containsAll(['trigger', 'trigger_with_url']));
      expect(
        toolsOf('Make.com MCP'),
        containsAll(['list_scenarios', 'run_scenario']),
      );
    });

    test('config fields expose secrets alongside extras', () {
      registerInfra();
      Set<String> keysOf(String name) => NativePluginRegistry.I
          .capabilityFor(name)!
          .configFields
          .map((f) => f.key)
          .toSet();
      expect(keysOf('Vercel MCP'), contains('token'));
      expect(keysOf('Vercel Deploy'), contains('token'));
      expect(keysOf('Railway MCP'), contains('token'));
      expect(keysOf('Heroku MCP'), contains('token'));
      expect(keysOf('DigitalOcean MCP'), contains('token'));
      expect(keysOf('Cloudflare MCP'), contains('token'));
      expect(keysOf('Docker MCP'), containsAll(['docker_host', 'api_version']));
      expect(
        keysOf('Kubernetes MCP'),
        containsAll(['bearer_token', 'api_server', 'namespace']),
      );
      expect(keysOf('Terraform MCP'), contains('token'));
      expect(keysOf('Zapier MCP'), contains('webhook_url'));
      expect(keysOf('Make.com MCP'), containsAll(['token', 'zone_base']));
    });

    test('honest scope notes live in the tool descriptions', () {
      String descriptionOf(String plugin, String tool) => infraDescriptors
          .firstWhere((d) => d.pluginName == plugin)
          .tools
          .firstWhere((t) => t.name == tool)
          .description;
      expect(
        descriptionOf('Kubernetes MCP', 'list_pods'),
        contains('Bearer-token'),
      );
      expect(
        descriptionOf('Terraform MCP', 'create_run'),
        contains('Terraform Cloud'),
      );
      expect(
        descriptionOf('Docker MCP', 'list_containers'),
        contains('daemon'),
      );
    });
  });

  group('Vercel MCP', () {
    const values = {'token': 'vercel-secret'};

    test('list_projects GETs with bearer auth', () async {
      http.Request? seen;
      final cap = await capFor(
        'Vercel MCP',
        (request) async {
          seen = request;
          return http.Response('{"projects":[]}', 200);
        },
        values: values,
      );
      final out = await cap.callTool('list_projects', {});
      expect(seen!.method, 'GET');
      expect(seen!.url.toString(), 'https://api.vercel.com/v9/projects');
      expect(seen!.headers['Authorization'], 'Bearer vercel-secret');
      expect(out, contains('projects'));
    });

    test('list_deployments maps project_id to the projectId param', () async {
      http.Request? seen;
      final cap = await capFor(
        'Vercel MCP',
        (request) async {
          seen = request;
          return http.Response('{"deployments":[]}', 200);
        },
        values: values,
      );
      await cap.callTool('list_deployments', {
        'project_id': 'prj_123',
        'limit': 5,
      });
      expect(seen!.method, 'GET');
      expect(seen!.url.path, '/v6/deployments');
      expect(seen!.url.queryParameters['projectId'], 'prj_123');
      expect(seen!.url.queryParameters['limit'], '5');
      expect(seen!.headers['Authorization'], 'Bearer vercel-secret');
    });

    test('get_deployment GETs one deployment', () async {
      http.Request? seen;
      final cap = await capFor(
        'Vercel MCP',
        (request) async {
          seen = request;
          return http.Response('{"id":"dpl_1"}', 200);
        },
        values: values,
      );
      await cap.callTool('get_deployment', {'id': 'dpl_1'});
      expect(seen!.method, 'GET');
      expect(seen!.url.toString(), 'https://api.vercel.com/v13/deployments/dpl_1');
    });

    test('list_domains GETs the account domains', () async {
      http.Request? seen;
      final cap = await capFor(
        'Vercel MCP',
        (request) async {
          seen = request;
          return http.Response('{"domains":[]}', 200);
        },
        values: values,
      );
      await cap.callTool('list_domains', {});
      expect(seen!.method, 'GET');
      expect(seen!.url.toString(), 'https://api.vercel.com/v5/domains');
    });

    test('missing token gates and never leaks the secret', () async {
      var called = false;
      final cap = await capFor(
        'Vercel MCP',
        (request) async {
          called = true;
          return http.Response('{}', 200);
        },
      );
      final out = await cap.callTool('list_projects', {});
      expect(out, contains('Configure Vercel token first'));
      expect(out.contains('vercel-secret'), isFalse);
      expect(called, isFalse);
    });
  });

  group('Vercel Deploy', () {
    const values = {'token': 'vercel-secret'};

    test('create_deployment POSTs name + gitSource with main default', () async {
      http.Request? seen;
      final cap = await capFor(
        'Vercel Deploy',
        (request) async {
          seen = request;
          return http.Response('{"id":"dpl_new"}', 200);
        },
        values: values,
      );
      await cap.callTool('create_deployment', {
        'project': 'my-site',
        'git_repo': 'acme/my-site',
      });
      expect(seen!.method, 'POST');
      expect(seen!.url.toString(), 'https://api.vercel.com/v13/deployments');
      expect(
        jsonDecode(seen!.body) as Map,
        {
          'name': 'my-site',
          'gitSource': {'type': 'github', 'repo': 'acme/my-site', 'ref': 'main'},
        },
      );
      expect(seen!.headers['Authorization'], 'Bearer vercel-secret');
    });

    test('create_deployment honors an explicit branch', () async {
      http.Request? seen;
      final cap = await capFor(
        'Vercel Deploy',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: values,
      );
      await cap.callTool('create_deployment', {
        'project': 'my-site',
        'git_repo': 'acme/my-site',
        'branch': 'staging',
      });
      expect(
        (jsonDecode(seen!.body) as Map)['gitSource'],
        {'type': 'github', 'repo': 'acme/my-site', 'ref': 'staging'},
      );
    });

    test('cancel_deployment DELETEs the deployment', () async {
      http.Request? seen;
      final cap = await capFor(
        'Vercel Deploy',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: values,
      );
      await cap.callTool('cancel_deployment', {'id': 'dpl_1'});
      expect(seen!.method, 'DELETE');
      expect(seen!.url.toString(), 'https://api.vercel.com/v13/deployments/dpl_1');
    });

    test('list_deployments maps project_id like the read API', () async {
      http.Request? seen;
      final cap = await capFor(
        'Vercel Deploy',
        (request) async {
          seen = request;
          return http.Response('{"deployments":[]}', 200);
        },
        values: values,
      );
      await cap.callTool('list_deployments', {'project_id': 'prj_9'});
      expect(seen!.url.queryParameters['projectId'], 'prj_9');
    });

    test('missing token gates and never leaks the secret', () async {
      var called = false;
      final cap = await capFor(
        'Vercel Deploy',
        (request) async {
          called = true;
          return http.Response('{}', 200);
        },
      );
      final out = await cap.callTool('cancel_deployment', {'id': 'dpl_1'});
      expect(out, contains('Configure Vercel token first'));
      expect(out.contains('vercel-secret'), isFalse);
      expect(called, isFalse);
    });

    test('non-2xx errors pass through verbatim', () async {
      const body = '{"error":{"code":"not_found","message":"Not found."}}';
      final cap = await capFor(
        'Vercel Deploy',
        (_) async => http.Response(body, 404),
        values: values,
      );
      final out = await cap.callTool('get_deployment', {'id': 'dpl_ghost'});
      expect(out, contains('404'));
      expect(out, contains(body));
    });
  });

  group('Railway MCP', () {
    const values = {'token': 'railway-secret'};

    test('list_projects POSTs a GraphQL projects query', () async {
      http.Request? seen;
      final cap = await capFor(
        'Railway MCP',
        (request) async {
          seen = request;
          return http.Response('{"data":{"projects":{"edges":[]}}}', 200);
        },
        values: values,
      );
      final out = await cap.callTool('list_projects', {});
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://backboard.railway.app/graphql/v2',
      );
      expect(seen!.headers['Authorization'], 'Bearer railway-secret');
      final body = jsonDecode(seen!.body) as Map;
      expect((body['query'] as String), contains('projects'));
      expect(out, contains('projects'));
    });

    test('list_services sends the project id as a GraphQL variable', () async {
      http.Request? seen;
      final cap = await capFor(
        'Railway MCP',
        (request) async {
          seen = request;
          return http.Response('{"data":{}}', 200);
        },
        values: values,
      );
      await cap.callTool('list_services', {'project_id': 'proj_1'});
      final body = jsonDecode(seen!.body) as Map;
      expect((body['query'] as String), contains('services'));
      expect(body['variables'], {'projectId': 'proj_1'});
    });

    test('list_deployments sends service id plus limit', () async {
      http.Request? seen;
      final cap = await capFor(
        'Railway MCP',
        (request) async {
          seen = request;
          return http.Response('{"data":{}}', 200);
        },
        values: values,
      );
      await cap.callTool('list_deployments', {
        'service_id': 'svc_1',
        'limit': 3,
      });
      final body = jsonDecode(seen!.body) as Map;
      expect((body['query'] as String), contains('deployments'));
      expect(body['variables'], {'serviceId': 'svc_1', 'first': 3});
    });

    test('missing token gates and never leaks the secret', () async {
      var called = false;
      final cap = await capFor(
        'Railway MCP',
        (request) async {
          called = true;
          return http.Response('{}', 200);
        },
      );
      final out = await cap.callTool('list_projects', {});
      expect(out, contains('Configure Railway API token first'));
      expect(out.contains('railway-secret'), isFalse);
      expect(called, isFalse);
    });
  });

  group('Heroku MCP', () {
    const values = {'token': 'heroku-secret'};

    test('list_apps sends bearer plus the Heroku Accept header', () async {
      http.Request? seen;
      final cap = await capFor(
        'Heroku MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
        values: values,
      );
      await cap.callTool('list_apps', {});
      expect(seen!.method, 'GET');
      expect(seen!.url.toString(), 'https://api.heroku.com/apps');
      expect(seen!.headers['Authorization'], 'Bearer heroku-secret');
      expect(
        seen!.headers['Accept'],
        'application/vnd.heroku+json; version=3',
      );
    });

    test('get_app GETs one app with the Accept header', () async {
      http.Request? seen;
      final cap = await capFor(
        'Heroku MCP',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: values,
      );
      await cap.callTool('get_app', {'id': 'my-app'});
      expect(seen!.url.toString(), 'https://api.heroku.com/apps/my-app');
      expect(
        seen!.headers['Accept'],
        'application/vnd.heroku+json; version=3',
      );
    });

    test('list_dynos GETs the app dynos', () async {
      http.Request? seen;
      final cap = await capFor(
        'Heroku MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
        values: values,
      );
      await cap.callTool('list_dynos', {'app_id': 'my-app'});
      expect(seen!.method, 'GET');
      expect(seen!.url.toString(), 'https://api.heroku.com/apps/my-app/dynos');
    });

    test('restart_dynos DELETEs the dyno collection', () async {
      http.Request? seen;
      final cap = await capFor(
        'Heroku MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
        values: values,
      );
      await cap.callTool('restart_dynos', {'app_id': 'my-app'});
      expect(seen!.method, 'DELETE');
      expect(seen!.url.toString(), 'https://api.heroku.com/apps/my-app/dynos');
    });

    test('get_config GETs the config vars', () async {
      http.Request? seen;
      final cap = await capFor(
        'Heroku MCP',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: values,
      );
      await cap.callTool('get_config', {'app_id': 'my-app'});
      expect(
        seen!.url.toString(),
        'https://api.heroku.com/apps/my-app/config-vars',
      );
    });

    test('missing token gates and never leaks the secret', () async {
      var called = false;
      final cap = await capFor(
        'Heroku MCP',
        (request) async {
          called = true;
          return http.Response('{}', 200);
        },
      );
      final out = await cap.callTool('list_apps', {});
      expect(out, contains('Configure Heroku API token first'));
      expect(out.contains('heroku-secret'), isFalse);
      expect(called, isFalse);
    });

    test('non-2xx errors pass through verbatim', () async {
      const body = '{"id":"unauthorized","message":"Invalid credentials."}';
      final cap = await capFor(
        'Heroku MCP',
        (_) async => http.Response(body, 401),
        values: values,
      );
      final out = await cap.callTool('list_apps', {});
      expect(out, contains('401'));
      expect(out, contains(body));
    });
  });

  group('DigitalOcean MCP', () {
    const values = {'token': 'do-secret'};

    test('list_droplets GETs with bearer auth', () async {
      http.Request? seen;
      final cap = await capFor(
        'DigitalOcean MCP',
        (request) async {
          seen = request;
          return http.Response('{"droplets":[]}', 200);
        },
        values: values,
      );
      final out = await cap.callTool('list_droplets', {});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://api.digitalocean.com/v2/droplets',
      );
      expect(seen!.headers['Authorization'], 'Bearer do-secret');
      expect(out, contains('droplets'));
    });

    test('get_droplet GETs one droplet', () async {
      http.Request? seen;
      final cap = await capFor(
        'DigitalOcean MCP',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: values,
      );
      await cap.callTool('get_droplet', {'id': '123'});
      expect(
        seen!.url.toString(),
        'https://api.digitalocean.com/v2/droplets/123',
      );
    });

    test('list_domains GETs the account domains', () async {
      http.Request? seen;
      final cap = await capFor(
        'DigitalOcean MCP',
        (request) async {
          seen = request;
          return http.Response('{"domains":[]}', 200);
        },
        values: values,
      );
      await cap.callTool('list_domains', {});
      expect(
        seen!.url.toString(),
        'https://api.digitalocean.com/v2/domains',
      );
    });

    test('list_domain_records GETs one domain records', () async {
      http.Request? seen;
      final cap = await capFor(
        'DigitalOcean MCP',
        (request) async {
          seen = request;
          return http.Response('{"domain_records":[]}', 200);
        },
        values: values,
      );
      await cap.callTool('list_domain_records', {'domain': 'example.com'});
      expect(
        seen!.url.toString(),
        'https://api.digitalocean.com/v2/domains/example.com/records',
      );
    });

    test('missing token gates and never leaks the secret', () async {
      var called = false;
      final cap = await capFor(
        'DigitalOcean MCP',
        (request) async {
          called = true;
          return http.Response('{}', 200);
        },
      );
      final out = await cap.callTool('list_droplets', {});
      expect(out, contains('Configure DigitalOcean API token first'));
      expect(out.contains('do-secret'), isFalse);
      expect(called, isFalse);
    });
  });

  group('Cloudflare MCP', () {
    const values = {'token': 'cf-secret'};

    test('list_zones GETs with bearer auth', () async {
      http.Request? seen;
      final cap = await capFor(
        'Cloudflare MCP',
        (request) async {
          seen = request;
          return http.Response('{"result":[]}', 200);
        },
        values: values,
      );
      final out = await cap.callTool('list_zones', {});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://api.cloudflare.com/client/v4/zones',
      );
      expect(seen!.headers['Authorization'], 'Bearer cf-secret');
      expect(out, contains('result'));
    });

    test('list_dns GETs one zone records', () async {
      http.Request? seen;
      final cap = await capFor(
        'Cloudflare MCP',
        (request) async {
          seen = request;
          return http.Response('{"result":[]}', 200);
        },
        values: values,
      );
      await cap.callTool('list_dns', {'zone_id': 'zone1'});
      expect(
        seen!.url.toString(),
        'https://api.cloudflare.com/client/v4/zones/zone1/dns_records',
      );
    });

    test('create_dns POSTs the record JSON', () async {
      http.Request? seen;
      final cap = await capFor(
        'Cloudflare MCP',
        (request) async {
          seen = request;
          return http.Response('{"result":{}}', 200);
        },
        values: values,
      );
      await cap.callTool('create_dns', {
        'zone_id': 'zone1',
        'type': 'A',
        'name': 'www',
        'content': '93.184.216.34',
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://api.cloudflare.com/client/v4/zones/zone1/dns_records',
      );
      expect(
        jsonDecode(seen!.body) as Map,
        {'type': 'A', 'name': 'www', 'content': '93.184.216.34'},
      );
    });

    test('delete_dns DELETEs one record', () async {
      http.Request? seen;
      final cap = await capFor(
        'Cloudflare MCP',
        (request) async {
          seen = request;
          return http.Response('{"result":{}}', 200);
        },
        values: values,
      );
      await cap.callTool('delete_dns', {
        'zone_id': 'zone1',
        'record_id': 'rec1',
      });
      expect(seen!.method, 'DELETE');
      expect(
        seen!.url.toString(),
        'https://api.cloudflare.com/client/v4/zones/zone1/dns_records/rec1',
      );
    });

    test('missing token gates and never leaks the secret', () async {
      var called = false;
      final cap = await capFor(
        'Cloudflare MCP',
        (request) async {
          called = true;
          return http.Response('{}', 200);
        },
      );
      final out = await cap.callTool('list_zones', {});
      expect(out, contains('Configure Cloudflare API token first'));
      expect(out.contains('cf-secret'), isFalse);
      expect(called, isFalse);
    });
  });

  group('Docker MCP', () {
    test('list_containers defaults all to true against the daemon', () async {
      http.Request? seen;
      final cap = await capFor(
        'Docker MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
      );
      await cap.callTool('list_containers', {});
      expect(seen!.method, 'GET');
      expect(seen!.url.host, 'localhost');
      expect(seen!.url.port, 2375);
      expect(seen!.url.path, '/v1.43/containers/json');
      expect(seen!.url.queryParameters['all'], 'true');
      // No auth material is attached for a local daemon.
      expect(seen!.headers['Authorization'], isNull);
    });

    test('list_containers honors an explicit all=false', () async {
      http.Request? seen;
      final cap = await capFor(
        'Docker MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
      );
      await cap.callTool('list_containers', {'all': false});
      expect(seen!.url.queryParameters['all'], 'false');
    });

    test('list_images GETs the image collection', () async {
      http.Request? seen;
      final cap = await capFor(
        'Docker MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
      );
      await cap.callTool('list_images', {});
      expect(seen!.url.path, '/v1.43/images/json');
    });

    test('inspect_container GETs one container', () async {
      http.Request? seen;
      final cap = await capFor(
        'Docker MCP',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
      );
      await cap.callTool('inspect_container', {'id': 'abc123'});
      expect(seen!.url.path, '/v1.43/containers/abc123/json');
    });

    test('custom docker_host reroutes the request', () async {
      http.Request? seen;
      final cap = await capFor(
        'Docker MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
        values: const {'docker_host': 'tcp://192.168.1.10:2376'},
      );
      await cap.callTool('list_images', {});
      expect(seen!.url.host, '192.168.1.10');
      expect(seen!.url.port, 2376);
    });

    test('connection-refused answers honestly instead of throwing', () async {
      final cap = await capFor(
        'Docker MCP',
        (request) async {
          throw http.ClientException('Connection refused', request.url);
        },
      );
      final out = await cap.callTool('list_containers', {});
      expect(out, contains('unreachable'));
      expect(out, contains('localhost'));
    });

    test('unix-socket daemons answer honestly as unsupported', () async {
      var called = false;
      final cap = await capFor(
        'Docker MCP',
        (request) async {
          called = true;
          return http.Response('[]', 200);
        },
        values: const {'docker_host': 'unix:///var/run/docker.sock'},
      );
      final out = await cap.callTool('list_containers', {});
      expect(out, contains('Unix-socket'));
      expect(called, isFalse);
    });
  });

  group('Kubernetes MCP', () {
    const values = {
      'bearer_token': 'k8s-secret',
      'api_server': 'https://192.168.1.100:6443',
    };

    test('list_pods GETs the default namespace with bearer auth', () async {
      http.Request? seen;
      final cap = await capFor(
        'Kubernetes MCP',
        (request) async {
          seen = request;
          return http.Response('{"items":[]}', 200);
        },
        values: values,
      );
      final out = await cap.callTool('list_pods', {});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://192.168.1.100:6443/api/v1/namespaces/default/pods',
      );
      expect(seen!.headers['Authorization'], 'Bearer k8s-secret');
      expect(out, contains('items'));
    });

    test('configured namespace reroutes pod reads', () async {
      http.Request? seen;
      final cap = await capFor(
        'Kubernetes MCP',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: {...values, 'namespace': 'prod'},
      );
      await cap.callTool('get_pod', {'name': 'web-0'});
      expect(
        seen!.url.toString(),
        'https://192.168.1.100:6443/api/v1/namespaces/prod/pods/web-0',
      );
    });

    test('list_deployments hits the apps/v1 collection', () async {
      http.Request? seen;
      final cap = await capFor(
        'Kubernetes MCP',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: values,
      );
      await cap.callTool('list_deployments', {});
      expect(
        seen!.url.toString(),
        'https://192.168.1.100:6443/apis/apps/v1/namespaces/default/deployments',
      );
    });

    test('list_services hits the core service collection', () async {
      http.Request? seen;
      final cap = await capFor(
        'Kubernetes MCP',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: values,
      );
      await cap.callTool('list_services', {});
      expect(
        seen!.url.toString(),
        'https://192.168.1.100:6443/api/v1/namespaces/default/services',
      );
    });

    test('pod_logs maps tail to tailLines', () async {
      http.Request? seen;
      final cap = await capFor(
        'Kubernetes MCP',
        (request) async {
          seen = request;
          return http.Response('log line', 200);
        },
        values: values,
      );
      await cap.callTool('pod_logs', {'name': 'web-0', 'tail': 200});
      expect(
        seen!.url.path,
        '/api/v1/namespaces/default/pods/web-0/log',
      );
      expect(seen!.url.queryParameters['tailLines'], '200');
    });

    test('missing api server gates before any request', () async {
      var called = false;
      final cap = await capFor(
        'Kubernetes MCP',
        (request) async {
          called = true;
          return http.Response('{}', 200);
        },
        values: const {'bearer_token': 'k8s-secret'},
      );
      final out = await cap.callTool('list_pods', {});
      expect(out, contains('Configure Kubernetes API server first'));
      expect(called, isFalse);
    });

    test('missing bearer token gates and never leaks the secret', () async {
      var called = false;
      final cap = await capFor(
        'Kubernetes MCP',
        (request) async {
          called = true;
          return http.Response('{}', 200);
        },
        values: const {'api_server': 'https://192.168.1.100:6443'},
      );
      final out = await cap.callTool('list_pods', {});
      expect(out, contains('Configure Kubernetes bearer token first'));
      expect(out.contains('k8s-secret'), isFalse);
      expect(called, isFalse);
    });

    test('403 bodies pass through verbatim', () async {
      const body =
          '{"kind":"Status","message":"pods is forbidden","code":403}';
      final cap = await capFor(
        'Kubernetes MCP',
        (_) async => http.Response(body, 403),
        values: values,
      );
      final out = await cap.callTool('list_pods', {});
      expect(out, contains('403'));
      expect(out, contains(body));
    });
  });

  group('Terraform MCP', () {
    const values = {'token': 'tf-secret'};

    test('list_workspaces GETs the org collection with bearer auth', () async {
      http.Request? seen;
      final cap = await capFor(
        'Terraform MCP',
        (request) async {
          seen = request;
          return http.Response('{"data":[]}', 200);
        },
        values: values,
      );
      final out = await cap.callTool('list_workspaces', {'org': 'acme'});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://app.terraform.io/api/v2/organizations/acme/workspaces',
      );
      expect(seen!.headers['Authorization'], 'Bearer tf-secret');
      expect(out, contains('data'));
    });

    test('list_runs GETs the workspace runs', () async {
      http.Request? seen;
      final cap = await capFor(
        'Terraform MCP',
        (request) async {
          seen = request;
          return http.Response('{"data":[]}', 200);
        },
        values: values,
      );
      await cap.callTool('list_runs', {'workspace_id': 'ws-1'});
      expect(
        seen!.url.toString(),
        'https://app.terraform.io/api/v2/workspaces/ws-1/runs',
      );
    });

    test('create_run POSTs the JSON:API run document', () async {
      http.Request? seen;
      final cap = await capFor(
        'Terraform MCP',
        (request) async {
          seen = request;
          return http.Response('{"data":{}}', 201);
        },
        values: values,
      );
      await cap.callTool('create_run', {
        'workspace_id': 'ws-1',
        'message': 'plan from Ovid',
        'auto_apply': true,
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://app.terraform.io/api/v2/workspaces/ws-1/runs',
      );
      expect(
        jsonDecode(seen!.body) as Map,
        {
          'data': {
            'type': 'runs',
            'attributes': {'message': 'plan from Ovid', 'auto-apply': true},
            'relationships': {
              'workspace': {
                'data': {'type': 'workspaces', 'id': 'ws-1'},
              },
            },
          },
        },
      );
    });

    test('create_run defaults to a manual run', () async {
      http.Request? seen;
      final cap = await capFor(
        'Terraform MCP',
        (request) async {
          seen = request;
          return http.Response('{"data":{}}', 201);
        },
        values: values,
      );
      await cap.callTool('create_run', {'workspace_id': 'ws-1'});
      final attributes =
          ((jsonDecode(seen!.body) as Map)['data'] as Map)['attributes'] as Map;
      expect(attributes['auto-apply'], isFalse);
    });

    test('missing token gates and never leaks the secret', () async {
      var called = false;
      final cap = await capFor(
        'Terraform MCP',
        (request) async {
          called = true;
          return http.Response('{}', 200);
        },
      );
      final out = await cap.callTool('list_workspaces', {'org': 'acme'});
      expect(out, contains('Configure Terraform Cloud API token first'));
      expect(out.contains('tf-secret'), isFalse);
      expect(called, isFalse);
    });
  });

  group('Zapier MCP', () {
    const hook = 'https://hooks.zapier.com/hooks/catch/1/abc/';
    const values = {'webhook_url': hook};

    test('trigger POSTs the payload to the webhook URL', () async {
      http.Request? seen;
      final cap = await capFor(
        'Zapier MCP',
        (request) async {
          seen = request;
          return http.Response('ok', 200);
        },
        values: values,
      );
      final out = await cap.callTool('trigger', {
        'payload_json': {'text': 'deploy done'},
      });
      expect(seen!.method, 'POST');
      expect(seen!.url.toString(), hook);
      expect(jsonDecode(seen!.body) as Map, {'text': 'deploy done'});
      expect(out, 'ok');
    });

    test('trigger accepts a JSON-encoded string payload', () async {
      http.Request? seen;
      final cap = await capFor(
        'Zapier MCP',
        (request) async {
          seen = request;
          return http.Response('ok', 200);
        },
        values: values,
      );
      await cap.callTool('trigger', {
        'payload_json': '{"text":"hi"}',
      });
      expect(jsonDecode(seen!.body) as Map, {'text': 'hi'});
    });

    test('trigger_with_url POSTs to the per-call URL', () async {
      http.Request? seen;
      final cap = await capFor(
        'Zapier MCP',
        (request) async {
          seen = request;
          return http.Response('ok', 200);
        },
      );
      await cap.callTool('trigger_with_url', {
        'url': 'https://hooks.zapier.com/hooks/catch/1/other/',
        'payload_json': {'n': 1},
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://hooks.zapier.com/hooks/catch/1/other/',
      );
      expect(jsonDecode(seen!.body) as Map, {'n': 1});
    });

    test('trigger_with_url rejects non-http URLs', () async {
      final cap = await capFor(
        'Zapier MCP',
        (_) async => http.Response('ok', 200),
        values: values,
      );
      await expectLater(
        cap.callTool('trigger_with_url', {
          'url': 'ftp://example.com/hook',
          'payload_json': {'n': 1},
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('missing webhook URL gates and never leaks the secret', () async {
      var called = false;
      final cap = await capFor(
        'Zapier MCP',
        (request) async {
          called = true;
          return http.Response('ok', 200);
        },
      );
      final out = await cap.callTool('trigger', {
        'payload_json': {'text': 'x'},
      });
      expect(out, contains('Configure Zapier webhook URL first'));
      expect(out.contains(hook), isFalse);
      expect(called, isFalse);
    });
  });

  group('Make.com MCP', () {
    const values = {'token': 'make-secret'};

    test('list_scenarios GETs the default zone with Token auth', () async {
      http.Request? seen;
      final cap = await capFor(
        'Make.com MCP',
        (request) async {
          seen = request;
          return http.Response('{"scenarios":[]}', 200);
        },
        values: values,
      );
      final out = await cap.callTool('list_scenarios', {});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://eu1.make.com/api/v2/scenarios',
      );
      expect(seen!.headers['Authorization'], 'Token make-secret');
      expect(out, contains('scenarios'));
    });

    test('custom zone_base reroutes the request', () async {
      http.Request? seen;
      final cap = await capFor(
        'Make.com MCP',
        (request) async {
          seen = request;
          return http.Response('{"scenarios":[]}', 200);
        },
        values: {...values, 'zone_base': 'https://us1.make.com/api/v2'},
      );
      await cap.callTool('list_scenarios', {});
      expect(
        seen!.url.toString(),
        'https://us1.make.com/api/v2/scenarios',
      );
    });

    test('run_scenario POSTs the payload to the scenario run path', () async {
      http.Request? seen;
      final cap = await capFor(
        'Make.com MCP',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: values,
      );
      await cap.callTool('run_scenario', {
        'id': '42',
        'payload_json': {'repo': 'acme/site'},
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://eu1.make.com/api/v2/scenarios/42/run',
      );
      expect(jsonDecode(seen!.body) as Map, {'repo': 'acme/site'});
      expect(seen!.headers['Authorization'], 'Token make-secret');
    });

    test('run_scenario works without a payload', () async {
      http.Request? seen;
      final cap = await capFor(
        'Make.com MCP',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: values,
      );
      await cap.callTool('run_scenario', {'id': '42'});
      expect(seen!.method, 'POST');
      expect(jsonDecode(seen!.body) as Map, isEmpty);
    });

    test('missing token gates and never leaks the secret', () async {
      var called = false;
      final cap = await capFor(
        'Make.com MCP',
        (request) async {
          called = true;
          return http.Response('{}', 200);
        },
      );
      final out = await cap.callTool('list_scenarios', {});
      expect(out, contains('Configure Make API token first'));
      expect(out.contains('make-secret'), isFalse);
      expect(called, isFalse);
    });
  });

  group('registration + roster', () {
    test('registerInfra registers all 11 services', () {
      registerInfra();
      for (final name in pluginNames) {
        expect(
          NativePluginRegistry.I.has(name),
          isTrue,
          reason: '$name registered',
        );
      }
    });

    test('roster half: plugin__vercel_mcp__list_projects resolves', () {
      registerInfra();
      const canonical = 'plugin__vercel_mcp__list_projects';
      final slug = canonical.substring('plugin__'.length).split('__').first;
      final tool = canonical.split('__').last;
      final cap = NativePluginRegistry.I.capabilityForSlug(slug);
      expect(cap, isNotNull);
      expect(cap!.pluginName, 'Vercel MCP');
      expect(cap.tools.map((t) => t.name), contains(tool));
    });

    test('roster half: plugin__docker_mcp__list_containers resolves', () {
      registerInfra();
      const canonical = 'plugin__docker_mcp__list_containers';
      final slug = canonical.substring('plugin__'.length).split('__').first;
      final tool = canonical.split('__').last;
      final cap = NativePluginRegistry.I.capabilityForSlug(slug);
      expect(cap, isNotNull);
      expect(cap!.pluginName, 'Docker MCP');
      expect(cap.tools.map((t) => t.name), contains(tool));
    });

    test('unknown tool still throws ArgumentError', () async {
      final cap = await capFor(
        'Heroku MCP',
        (_) async => http.Response('{}', 200),
        values: const {'token': 'heroku-secret'},
      );
      await expectLater(
        cap.callTool('nope', {}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
