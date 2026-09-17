import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/rest_descriptors_dev.dart';
import 'package:ovid_ai/core/native_plugins/rest_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Dev-platforms batch tests (NP4 Task 4): one MockClient-canned test per
/// tool asserting the REQUEST side (URL, method, auth header/query, secret
/// correctness), configure-first gating per service, one error passthrough,
/// and roster halves.
///
/// HTTP never leaves the process: every capability runs over [MockClient].
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pluginNames = [
    'GitLab MCP',
    'Bitbucket MCP',
    'Jira MCP',
    'Trello MCP',
    'Linear Sync',
    'Figma Bridge',
    'Sentry Watch',
    'Exa Search MCP',
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NativePluginRegistry.I.clearForTest();
    registerDevPlatforms();
    // Scrub any secret stored by an earlier test so the configure-first
    // tests below observe a genuinely empty store. Scrub via the
    // REGISTERED capabilities (their configFields are the union of secrets
    // + extras, which matters for the routed Bitbucket/Trello/host caps).
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

  /// Wraps the named dev descriptor/capability in a MockClient-backed
  /// capability, configuring [values] through the real config store
  /// (secure-storage + prefs mocks from setUp).
  Future<RestApiCapability> capFor(
    String pluginName,
    Future<http.Response> Function(http.Request) onRequest, {
    Map<String, String> values = const {},
  }) async {
    late final RestApiCapability cap;
    final client = MockClient((request) async => onRequest(request));
    switch (pluginName) {
      case 'GitLab MCP':
        cap = GitLabCapability(client: client);
      case 'Bitbucket MCP':
        cap = BitbucketCapability(client: client);
      case 'Jira MCP':
        cap = JiraCapability(client: client);
      case 'Trello MCP':
        cap = TrelloCapability(client: client);
      default:
        final descriptor = devDescriptors.firstWhere(
          (d) => d.pluginName == pluginName,
          orElse: () =>
              throw ArgumentError('No dev descriptor: $pluginName'),
        );
        cap = RestApiCapability(descriptor, client: client);
    }
    if (values.isNotEmpty) await cap.configure(values);
    return cap;
  }

  group('descriptors', () {
    test('batch exposes the 8 spec-exact REST plugin names', () {
      expect(
        devDescriptors.map((d) => d.pluginName),
        containsAll(pluginNames),
      );
      expect(devDescriptors, hasLength(8));
    });

    test('bases and auth schemes match spec §4.2', () {
      final byName = {for (final d in devDescriptors) d.pluginName: d};
      expect(byName['GitLab MCP']!.baseUrl, 'https://gitlab.com/api/v4');
      expect(byName['GitLab MCP']!.auth, RestAuthKind.apiKeyHeader);
      expect(byName['GitLab MCP']!.authHeader, 'PRIVATE-TOKEN');
      expect(
        byName['Bitbucket MCP']!.baseUrl,
        'https://api.bitbucket.org/2.0',
      );
      expect(byName['Bitbucket MCP']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Jira MCP']!.baseUrl, 'https://{host}');
      expect(byName['Jira MCP']!.auth, RestAuthKind.basic);
      expect(byName['Trello MCP']!.baseUrl, 'https://api.trello.com/1');
      expect(byName['Trello MCP']!.auth, RestAuthKind.queryKey);
      expect(byName['Trello MCP']!.authQueryKey, 'token');
      expect(
        byName['Linear Sync']!.baseUrl,
        'https://api.linear.app/graphql',
      );
      expect(byName['Linear Sync']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Figma Bridge']!.baseUrl, 'https://api.figma.com/v1');
      expect(byName['Figma Bridge']!.auth, RestAuthKind.apiKeyHeader);
      expect(byName['Figma Bridge']!.authHeader, 'X-Figma-Token');
      expect(byName['Sentry Watch']!.baseUrl, 'https://sentry.io/api/0');
      expect(byName['Sentry Watch']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Exa Search MCP']!.baseUrl, 'https://api.exa.ai');
      expect(byName['Exa Search MCP']!.auth, RestAuthKind.apiKeyHeader);
      expect(byName['Exa Search MCP']!.authHeader, 'x-api-key');
    });

    test('tool rosters match spec §4.2', () {
      Iterable<String> toolsOf(String name) => devDescriptors
          .firstWhere((d) => d.pluginName == name)
          .tools
          .map((t) => t.name);
      expect(
        toolsOf('GitLab MCP'),
        containsAll(['list_projects', 'list_merge_requests', 'create_issue']),
      );
      expect(
        toolsOf('Bitbucket MCP'),
        containsAll(['list_repos', 'list_pullrequests', 'get_pullrequest']),
      );
      expect(
        toolsOf('Jira MCP'),
        containsAll(['search', 'get_issue', 'create_issue', 'add_comment']),
      );
      expect(
        toolsOf('Trello MCP'),
        containsAll(['list_boards', 'list_lists', 'list_cards', 'create_card']),
      );
      expect(
        toolsOf('Linear Sync'),
        containsAll(['list_issues', 'create_issue', 'list_teams']),
      );
      expect(
        toolsOf('Figma Bridge'),
        containsAll(['get_file', 'get_comments', 'post_comment']),
      );
      expect(
        toolsOf('Sentry Watch'),
        containsAll(['list_issues', 'get_issue', 'latest_event']),
      );
      expect(
        toolsOf('Exa Search MCP'),
        containsAll(['search', 'contents']),
      );
    });

    test('config fields expose secrets alongside host/username extras', () {
      registerDevPlatforms();
      Set<String> keysOf(String name) => NativePluginRegistry.I
          .capabilityFor(name)!
          .configFields
          .map((f) => f.key)
          .toSet();
      expect(keysOf('GitLab MCP'), containsAll(['token', 'host']));
      expect(
        keysOf('Bitbucket MCP'),
        containsAll(['token', 'username', 'app_password']),
      );
      expect(
        keysOf('Jira MCP'),
        containsAll(['api_token', 'email', 'host']),
      );
      expect(keysOf('Trello MCP'), containsAll(['api_token', 'api_key']));
    });
  });

  group('GitLab MCP', () {
    test('list_projects GETs /projects with PRIVATE-TOKEN auth', () async {
      http.Request? seen;
      final cap = await capFor(
        'GitLab MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
        values: {'token': 'gl-secret'},
      );
      await cap.callTool('list_projects', {'search': 'ovid'});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        startsWith('https://gitlab.com/api/v4/projects'),
      );
      expect(seen!.headers['PRIVATE-TOKEN'], 'gl-secret');
      expect(seen!.url.queryParameters['search'], 'ovid');
      expect(seen!.headers.containsKey('Authorization'), isFalse);
    });

    test('list_merge_requests substitutes the project path segment',
        () async {
      http.Request? seen;
      final cap = await capFor(
        'GitLab MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
        values: {'token': 'gl-secret'},
      );
      await cap.callTool('list_merge_requests', {
        'project_id': 42,
        'state': 'opened',
      });
      expect(
        seen!.url.toString(),
        startsWith(
          'https://gitlab.com/api/v4/projects/42/merge_requests',
        ),
      );
      expect(seen!.url.queryParameters['state'], 'opened');
      expect(seen!.headers['PRIVATE-TOKEN'], 'gl-secret');
    });

    test('create_issue POSTs project issues with title+description', () async {
      http.Request? seen;
      final cap = await capFor(
        'GitLab MCP',
        (request) async {
          seen = request;
          return http.Response('{"id":1}', 201);
        },
        values: {'token': 'gl-secret'},
      );
      await cap.callTool('create_issue', {
        'project_id': 42,
        'title': 'Bug',
        'description': 'broken',
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        startsWith('https://gitlab.com/api/v4/projects/42/issues'),
      );
      expect(seen!.url.queryParameters['title'], 'Bug');
      expect(seen!.url.queryParameters['description'], 'broken');
    });

    test('host override reroutes to the self-hosted base', () async {
      http.Request? seen;
      final cap = await capFor(
        'GitLab MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
        values: {'token': 'gl-secret', 'host': 'git.example.com'},
      );
      await cap.callTool('list_projects', {});
      expect(
        seen!.url.toString(),
        startsWith('https://git.example.com/api/v4/projects'),
      );
      expect(seen!.headers['PRIVATE-TOKEN'], 'gl-secret');
    });

    test('host override tolerates scheme + trailing slash', () async {
      http.Request? seen;
      final cap = await capFor(
        'GitLab MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
        values: {'token': 'gl-secret', 'host': 'https://git.example.com/'},
      );
      await cap.callTool('list_projects', {});
      expect(
        seen!.url.toString(),
        startsWith('https://git.example.com/api/v4/projects'),
      );
    });

    test('missing token names the label, never the secret', () async {
      final cap = await capFor(
        'GitLab MCP',
        (_) async => http.Response('[]', 200),
      );
      final out = await cap.callTool('list_projects', {});
      expect(out, contains('Configure GitLab personal access token first'));
      expect(out, contains('"GitLab MCP"'));
      expect(out, contains('token'));
      expect(out.contains('gl-secret'), isFalse);
    });

    test('GitLab error body passes through verbatim with status', () async {
      const body = '{"message":"404 Project Not Found"}';
      final cap = await capFor(
        'GitLab MCP',
        (_) async => http.Response(body, 404),
        values: {'token': 'gl-secret'},
      );
      final out = await cap.callTool('list_projects', {});
      expect(out, contains('404'));
      expect(out, contains(body));
    });
  });

  group('Bitbucket MCP', () {
    test('bearer token is preferred when set', () async {
      http.Request? seen;
      final cap = await capFor(
        'Bitbucket MCP',
        (request) async {
          seen = request;
          return http.Response('{"values":[]}', 200);
        },
        values: {'token': 'bb-token-secret'},
      );
      await cap.callTool('list_repos', {'workspace': 'acme'});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://api.bitbucket.org/2.0/repositories/acme',
      );
      expect(seen!.headers['Authorization'], 'Bearer bb-token-secret');
    });

    test('bearer wins when both token and app password are set', () async {
      http.Request? seen;
      final cap = await capFor(
        'Bitbucket MCP',
        (request) async {
          seen = request;
          return http.Response('{"values":[]}', 200);
        },
        values: {
          'token': 'bb-token-secret',
          'username': 'alice',
          'app_password': 'bb-app-secret',
        },
      );
      await cap.callTool('list_repos', {'workspace': 'acme'});
      expect(seen!.headers['Authorization'], 'Bearer bb-token-secret');
    });

    test('falls back to basic auth without a token', () async {
      http.Request? seen;
      final cap = await capFor(
        'Bitbucket MCP',
        (request) async {
          seen = request;
          return http.Response('{"values":[]}', 200);
        },
        values: {'username': 'alice', 'app_password': 'bb-app-secret'},
      );
      await cap.callTool('list_pullrequests', {
        'workspace': 'acme',
        'repo': 'ovid',
      });
      expect(
        seen!.url.toString(),
        'https://api.bitbucket.org/2.0/repositories/acme/ovid/pullrequests',
      );
      expect(
        seen!.headers['Authorization'],
        'Basic ${base64Encode(utf8.encode('alice:bb-app-secret'))}',
      );
    });

    test('get_pullrequest substitutes workspace/repo/id', () async {
      http.Request? seen;
      final cap = await capFor(
        'Bitbucket MCP',
        (request) async {
          seen = request;
          return http.Response('{"id":7}', 200);
        },
        values: {'token': 'bb-token-secret'},
      );
      await cap.callTool('get_pullrequest', {
        'workspace': 'acme',
        'repo': 'ovid',
        'id': 7,
      });
      expect(
        seen!.url.toString(),
        'https://api.bitbucket.org/2.0/repositories/acme/ovid/pullrequests/7',
      );
      expect(seen!.headers['Authorization'], 'Bearer bb-token-secret');
    });

    test('missing app password gates on the secret label', () async {
      final cap = await capFor(
        'Bitbucket MCP',
        (_) async => http.Response('{}', 200),
        values: {'username': 'alice'},
      );
      final out = await cap.callTool('list_repos', {'workspace': 'acme'});
      expect(out, contains('Configure Bitbucket app password first'));
      expect(out, contains('app_password'));
      expect(out.contains('bb-app-secret'), isFalse);
    });

    test('missing username gates on the username field', () async {
      final cap = await capFor(
        'Bitbucket MCP',
        (_) async => http.Response('{}', 200),
        values: {'app_password': 'bb-app-secret'},
      );
      final out = await cap.callTool('list_repos', {'workspace': 'acme'});
      expect(out, contains('Configure Bitbucket username first'));
      expect(out, contains('username'));
    });
  });

  group('Jira MCP', () {
    test('get_issue GETs the issue with basic-auth encoding', () async {
      http.Request? seen;
      final cap = await capFor(
        'Jira MCP',
        (request) async {
          seen = request;
          return http.Response('{"key":"PROJ-1"}', 200);
        },
        values: {
          'host': 'acme.atlassian.net',
          'email': 'alice@example.com',
          'api_token': 'jira-secret',
        },
      );
      await cap.callTool('get_issue', {'key': 'PROJ-1'});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://acme.atlassian.net/rest/api/3/issue/PROJ-1',
      );
      expect(
        seen!.headers['Authorization'],
        'Basic ${base64Encode(utf8.encode('alice@example.com:jira-secret'))}',
      );
    });

    test('host accepts a full URL with scheme and path', () async {
      http.Request? seen;
      final cap = await capFor(
        'Jira MCP',
        (request) async {
          seen = request;
          return http.Response('{"key":"PROJ-1"}', 200);
        },
        values: {
          'host': 'https://acme.atlassian.net/',
          'email': 'alice@example.com',
          'api_token': 'jira-secret',
        },
      );
      await cap.callTool('get_issue', {'key': 'PROJ-1'});
      expect(
        seen!.url.toString(),
        'https://acme.atlassian.net/rest/api/3/issue/PROJ-1',
      );
    });

    test('search POSTs the JQL JSON body', () async {
      http.Request? seen;
      final cap = await capFor(
        'Jira MCP',
        (request) async {
          seen = request;
          return http.Response('{"issues":[]}', 200);
        },
        values: {
          'host': 'acme.atlassian.net',
          'email': 'alice@example.com',
          'api_token': 'jira-secret',
        },
      );
      await cap.callTool('search', {
        'body': {'jql': 'project = PROJ', 'maxResults': 20},
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://acme.atlassian.net/rest/api/3/search/jql',
      );
      expect(
        jsonDecode(seen!.body) as Map,
        {'jql': 'project = PROJ', 'maxResults': 20},
      );
    });

    test('add_comment POSTs to the issue comments node', () async {
      http.Request? seen;
      final cap = await capFor(
        'Jira MCP',
        (request) async {
          seen = request;
          return http.Response('{"id":"1"}', 201);
        },
        values: {
          'host': 'acme.atlassian.net',
          'email': 'alice@example.com',
          'api_token': 'jira-secret',
        },
      );
      await cap.callTool('add_comment', {
        'key': 'PROJ-1',
        'body': {'body': 'looks good'},
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://acme.atlassian.net/rest/api/3/issue/PROJ-1/comment',
      );
      expect(jsonDecode(seen!.body) as Map, {'body': 'looks good'});
    });

    test('create_issue POSTs the fields JSON body', () async {
      http.Request? seen;
      final cap = await capFor(
        'Jira MCP',
        (request) async {
          seen = request;
          return http.Response('{"key":"PROJ-2"}', 201);
        },
        values: {
          'host': 'acme.atlassian.net',
          'email': 'alice@example.com',
          'api_token': 'jira-secret',
        },
      );
      await cap.callTool('create_issue', {
        'body': {
          'fields': {
            'project': {'key': 'PROJ'},
            'summary': 'New bug',
            'issuetype': {'name': 'Task'},
          },
        },
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://acme.atlassian.net/rest/api/3/issue',
      );
      final payload = jsonDecode(seen!.body) as Map;
      expect((payload['fields'] as Map)['summary'], 'New bug');
    });

    test('missing host gates before any request', () async {
      var called = false;
      final cap = await capFor(
        'Jira MCP',
        (_) async {
          called = true;
          return http.Response('{}', 200);
        },
        values: {'email': 'alice@example.com', 'api_token': 'jira-secret'},
      );
      final out = await cap.callTool('get_issue', {'key': 'PROJ-1'});
      expect(out, contains('Configure Jira host first'));
      expect(out, contains('host'));
      expect(called, isFalse);
    });

    test('missing API token gates and never leaks the secret', () async {
      final cap = await capFor(
        'Jira MCP',
        (_) async => http.Response('{}', 200),
        values: {'host': 'acme.atlassian.net', 'email': 'alice@example.com'},
      );
      final out = await cap.callTool('get_issue', {'key': 'PROJ-1'});
      expect(out, contains('Configure Jira API token first'));
      expect(out, contains('api_token'));
      expect(out.contains('jira-secret'), isFalse);
    });
  });

  group('Trello MCP', () {
    test('list_boards sends both key and token query params', () async {
      http.Request? seen;
      final cap = await capFor(
        'Trello MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
        values: {'api_key': 'trello-key-value', 'api_token': 'trello-secret'},
      );
      await cap.callTool('list_boards', {});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        startsWith('https://api.trello.com/1/members/me/boards'),
      );
      expect(seen!.url.queryParameters['key'], 'trello-key-value');
      expect(seen!.url.queryParameters['token'], 'trello-secret');
      expect(seen!.headers.containsKey('Authorization'), isFalse);
    });

    test('list_lists substitutes the board path segment', () async {
      http.Request? seen;
      final cap = await capFor(
        'Trello MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
        values: {'api_key': 'trello-key-value', 'api_token': 'trello-secret'},
      );
      await cap.callTool('list_lists', {'board_id': 'B1'});
      expect(
        seen!.url.toString(),
        startsWith('https://api.trello.com/1/boards/B1/lists'),
      );
      expect(seen!.url.queryParameters['key'], 'trello-key-value');
      expect(seen!.url.queryParameters['token'], 'trello-secret');
    });

    test('list_cards substitutes the list path segment', () async {
      http.Request? seen;
      final cap = await capFor(
        'Trello MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
        values: {'api_key': 'trello-key-value', 'api_token': 'trello-secret'},
      );
      await cap.callTool('list_cards', {'list_id': 'L1'});
      expect(
        seen!.url.toString(),
        startsWith('https://api.trello.com/1/lists/L1/cards'),
      );
      expect(seen!.url.queryParameters['key'], 'trello-key-value');
    });

    test('create_card POSTs card params with key+token', () async {
      http.Request? seen;
      final cap = await capFor(
        'Trello MCP',
        (request) async {
          seen = request;
          return http.Response('{"id":"C1"}', 200);
        },
        values: {'api_key': 'trello-key-value', 'api_token': 'trello-secret'},
      );
      await cap.callTool('create_card', {
        'idList': 'L1',
        'name': 'Ship it',
        'desc': 'do the thing',
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        startsWith('https://api.trello.com/1/cards'),
      );
      expect(seen!.url.queryParameters['idList'], 'L1');
      expect(seen!.url.queryParameters['name'], 'Ship it');
      expect(seen!.url.queryParameters['desc'], 'do the thing');
      expect(seen!.url.queryParameters['key'], 'trello-key-value');
      expect(seen!.url.queryParameters['token'], 'trello-secret');
    });

    test('missing API key gates before any request', () async {
      var called = false;
      final cap = await capFor(
        'Trello MCP',
        (_) async {
          called = true;
          return http.Response('[]', 200);
        },
        values: {'api_token': 'trello-secret'},
      );
      final out = await cap.callTool('list_boards', {});
      expect(out, contains('Configure Trello API key first'));
      expect(out, contains('api_key'));
      expect(called, isFalse);
    });

    test('missing API token gates and never leaks the secret', () async {
      final cap = await capFor(
        'Trello MCP',
        (_) async => http.Response('[]', 200),
        values: {'api_key': 'trello-key-value'},
      );
      final out = await cap.callTool('list_boards', {});
      expect(out, contains('Configure Trello API token first'));
      expect(out, contains('api_token'));
      expect(out.contains('trello-secret'), isFalse);
    });
  });

  group('Linear Sync', () {
    test('list_issues POSTs the GraphQL body with bare auth', () async {
      http.Request? seen;
      final cap = await capFor(
        'Linear Sync',
        (request) async {
          seen = request;
          return http.Response('{"data":{}}', 200);
        },
        values: {'api_key': 'lin-secret'},
      );
      await cap.callTool('list_issues', {
        'body': {
          'query': 'query { issues(first: 20) { nodes { id title } } }',
        },
      });
      expect(seen!.method, 'POST');
      expect(seen!.url.toString(), 'https://api.linear.app/graphql');
      // Spec §4.2: `Authorization: <api_key>` — no Bearer prefix.
      expect(seen!.headers['Authorization'], 'lin-secret');
      final payload = jsonDecode(seen!.body) as Map;
      expect(payload['query'], contains('issues'));
    });

    test('create_issue POSTs query + variables', () async {
      http.Request? seen;
      final cap = await capFor(
        'Linear Sync',
        (request) async {
          seen = request;
          return http.Response('{"data":{}}', 200);
        },
        values: {'api_key': 'lin-secret'},
      );
      await cap.callTool('create_issue', {
        'body': {
          'query':
              'mutation CreateIssue(\$input: IssueCreateInput!) { issueCreate(input: \$input) { issue { id } } }',
          'variables': {
            'input': {'teamId': 'T1', 'title': 'Bug'},
          },
        },
      });
      expect(seen!.method, 'POST');
      expect(seen!.url.toString(), 'https://api.linear.app/graphql');
      final payload = jsonDecode(seen!.body) as Map;
      expect(payload['query'], contains('issueCreate'));
      expect(
        ((payload['variables'] as Map)['input'] as Map)['teamId'],
        'T1',
      );
    });

    test('list_teams POSTs the teams query', () async {
      http.Request? seen;
      final cap = await capFor(
        'Linear Sync',
        (request) async {
          seen = request;
          return http.Response('{"data":{}}', 200);
        },
        values: {'api_key': 'lin-secret'},
      );
      await cap.callTool('list_teams', {
        'body': {
          'query': 'query { teams { nodes { id name } } }',
        },
      });
      expect(seen!.method, 'POST');
      expect(seen!.headers['Authorization'], 'lin-secret');
      expect(
        (jsonDecode(seen!.body) as Map)['query'],
        contains('teams'),
      );
    });

    test('missing API key gates and never leaks the secret', () async {
      final cap = await capFor(
        'Linear Sync',
        (_) async => http.Response('{}', 200),
      );
      final out = await cap.callTool('list_teams', {
        'body': {
          'query': 'query { teams { nodes { id } } }',
        },
      });
      expect(out, contains('Configure Linear API key first'));
      expect(out, contains('api_key'));
      expect(out.contains('lin-secret'), isFalse);
    });
  });

  group('Figma Bridge', () {
    test('get_file GETs the file node with X-Figma-Token', () async {
      http.Request? seen;
      final cap = await capFor(
        'Figma Bridge',
        (request) async {
          seen = request;
          return http.Response('{"name":"Design"}', 200);
        },
        values: {'token': 'fig-secret'},
      );
      await cap.callTool('get_file', {'file_key': 'abc123'});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://api.figma.com/v1/files/abc123',
      );
      expect(seen!.headers['X-Figma-Token'], 'fig-secret');
      expect(seen!.headers.containsKey('Authorization'), isFalse);
    });

    test('get_comments GETs the file comments', () async {
      http.Request? seen;
      final cap = await capFor(
        'Figma Bridge',
        (request) async {
          seen = request;
          return http.Response('{"comments":[]}', 200);
        },
        values: {'token': 'fig-secret'},
      );
      await cap.callTool('get_comments', {'file_key': 'abc123'});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://api.figma.com/v1/files/abc123/comments',
      );
      expect(seen!.headers['X-Figma-Token'], 'fig-secret');
    });

    test('post_comment POSTs the message JSON', () async {
      http.Request? seen;
      final cap = await capFor(
        'Figma Bridge',
        (request) async {
          seen = request;
          return http.Response('{"id":"9"}', 200);
        },
        values: {'token': 'fig-secret'},
      );
      await cap.callTool('post_comment', {
        'file_key': 'abc123',
        'body': {'message': 'Nice work'},
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://api.figma.com/v1/files/abc123/comments',
      );
      expect(jsonDecode(seen!.body) as Map, {'message': 'Nice work'});
      expect(seen!.headers['X-Figma-Token'], 'fig-secret');
    });

    test('missing token gates and never leaks the secret', () async {
      final cap = await capFor(
        'Figma Bridge',
        (_) async => http.Response('{}', 200),
      );
      final out = await cap.callTool('get_file', {'file_key': 'abc123'});
      expect(out, contains('Configure Figma personal access token first'));
      expect(out.contains('fig-secret'), isFalse);
    });
  });

  group('Sentry Watch', () {
    test('list_issues GETs org issues with Bearer auth', () async {
      http.Request? seen;
      final cap = await capFor(
        'Sentry Watch',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
        values: {'auth_token': 'sen-secret'},
      );
      await cap.callTool('list_issues', {'org': 'my-org', 'project': '123'});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        startsWith('https://sentry.io/api/0/organizations/my-org/issues/'),
      );
      expect(seen!.url.queryParameters['project'], '123');
      expect(seen!.headers['Authorization'], 'Bearer sen-secret');
    });

    test('get_issue GETs the issue node', () async {
      http.Request? seen;
      final cap = await capFor(
        'Sentry Watch',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: {'auth_token': 'sen-secret'},
      );
      await cap.callTool('get_issue', {'id': '456'});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://sentry.io/api/0/issues/456/',
      );
      expect(seen!.headers['Authorization'], 'Bearer sen-secret');
    });

    test('latest_event GETs the newest event for the issue', () async {
      http.Request? seen;
      final cap = await capFor(
        'Sentry Watch',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: {'auth_token': 'sen-secret'},
      );
      await cap.callTool('latest_event', {'issue_id': '456'});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://sentry.io/api/0/issues/456/events/latest/',
      );
    });

    test('missing auth token gates and never leaks the secret', () async {
      final cap = await capFor(
        'Sentry Watch',
        (_) async => http.Response('{}', 200),
      );
      final out = await cap.callTool('list_issues', {'org': 'my-org'});
      expect(out, contains('Configure Sentry auth token first'));
      expect(out.contains('sen-secret'), isFalse);
    });
  });

  group('Exa Search MCP', () {
    test('search POSTs the query JSON with x-api-key', () async {
      http.Request? seen;
      final cap = await capFor(
        'Exa Search MCP',
        (request) async {
          seen = request;
          return http.Response('{"results":[]}', 200);
        },
        values: {'api_key': 'exa-secret'},
      );
      await cap.callTool('search', {
        'body': {'query': 'flutter testing', 'numResults': 5},
      });
      expect(seen!.method, 'POST');
      expect(seen!.url.toString(), 'https://api.exa.ai/search');
      expect(seen!.headers['x-api-key'], 'exa-secret');
      expect(
        jsonDecode(seen!.body) as Map,
        {'query': 'flutter testing', 'numResults': 5},
      );
    });

    test('contents POSTs ids + text flag', () async {
      http.Request? seen;
      final cap = await capFor(
        'Exa Search MCP',
        (request) async {
          seen = request;
          return http.Response('{"results":[]}', 200);
        },
        values: {'api_key': 'exa-secret'},
      );
      await cap.callTool('contents', {
        'body': {
          'ids': ['https://example.com'],
          'text': true,
        },
      });
      expect(seen!.method, 'POST');
      expect(seen!.url.toString(), 'https://api.exa.ai/contents');
      expect(seen!.headers['x-api-key'], 'exa-secret');
      final payload = jsonDecode(seen!.body) as Map;
      expect(payload['ids'], ['https://example.com']);
      expect(payload['text'], isTrue);
    });

    test('missing API key gates and never leaks the secret', () async {
      final cap = await capFor(
        'Exa Search MCP',
        (_) async => http.Response('{}', 200),
      );
      final out = await cap.callTool('search', {
        'body': {'query': 'x'},
      });
      expect(out, contains('Configure Exa API key first'));
      expect(out.contains('exa-secret'), isFalse);
    });
  });

  group('registration + roster', () {
    test('registerDevPlatforms registers all 8 services', () {
      registerDevPlatforms();
      for (final name in pluginNames) {
        expect(
          NativePluginRegistry.I.has(name),
          isTrue,
          reason: '$name registered',
        );
      }
    });

    test('roster half: plugin__gitlab_mcp__list_projects resolves', () {
      registerDevPlatforms();
      const canonical = 'plugin__gitlab_mcp__list_projects';
      final slug = canonical.substring('plugin__'.length).split('__').first;
      final tool = canonical.split('__').last;
      final cap = NativePluginRegistry.I.capabilityForSlug(slug);
      expect(cap, isNotNull);
      expect(cap!.pluginName, 'GitLab MCP');
      expect(cap.tools.map((t) => t.name), contains(tool));
    });

    test('roster half: plugin__linear_sync__list_issues resolves', () {
      registerDevPlatforms();
      const canonical = 'plugin__linear_sync__list_issues';
      final slug = canonical.substring('plugin__'.length).split('__').first;
      final tool = canonical.split('__').last;
      final cap = NativePluginRegistry.I.capabilityForSlug(slug);
      expect(cap, isNotNull);
      expect(cap!.pluginName, 'Linear Sync');
      expect(cap.tools.map((t) => t.name), contains(tool));
    });

    test('unknown tool still throws ArgumentError', () async {
      final cap = await capFor(
        'GitLab MCP',
        (_) async => http.Response('{}', 200),
        values: {'token': 'gl-secret'},
      );
      await expectLater(
        cap.callTool('nope', {}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
