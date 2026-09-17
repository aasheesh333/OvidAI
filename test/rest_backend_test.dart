import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/rest_descriptors_backend.dart';
import 'package:ovid_ai/core/native_plugins/rest_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Backend & data batch tests (NP4 Task 5): one MockClient-canned test per
/// tool asserting the REQUEST side (URL, method, auth header/query, secret
/// correctness), configure-first gating per service, one error passthrough,
/// and roster halves.
///
/// HTTP never leaves the process: every HTTP capability runs over
/// [MockClient]; Redis runs against a loopback [ServerSocket] fake speaking
/// real RESP bytes; Obsidian runs against a temp-dir vault.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pluginNames = [
    'Firebase MCP',
    'Supabase MCP',
    'Airtable MCP',
    'Appwrite MCP',
    'PocketBase MCP',
    'Vector DB MCP',
    'MongoDB MCP',
    'S3 MCP',
    'Redis MCP',
    'Obsidian MCP',
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NativePluginRegistry.I.clearForTest();
    registerBackend();
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

  /// Wraps the named backend HTTP capability in a MockClient-backed
  /// capability, configuring [values] through the real config store
  /// (secure-storage + prefs mocks from setUp).
  Future<NativePluginCapability> capFor(
    String pluginName,
    Future<http.Response> Function(http.Request) onRequest, {
    Map<String, String> values = const {},
  }) async {
    final client = MockClient((request) async => onRequest(request));
    late final NativePluginCapability cap;
    switch (pluginName) {
      case 'Firebase MCP':
        cap = FirebaseCapability(client: client);
      case 'Supabase MCP':
        cap = SupabaseCapability(client: client);
      case 'Airtable MCP':
        cap = AirtableCapability(client: client);
      case 'Appwrite MCP':
        cap = AppwriteCapability(client: client);
      case 'PocketBase MCP':
        cap = PocketBaseCapability(client: client);
      case 'Vector DB MCP':
        cap = VectorDbCapability(client: client);
      case 'MongoDB MCP':
        cap = MongoDbCapability(client: client);
      case 'S3 MCP':
        cap = S3Capability(client: client);
      case 'Obsidian MCP':
        cap = ObsidianCapability();
      default:
        throw ArgumentError('No backend capability: $pluginName');
    }
    if (values.isNotEmpty) await cap.configure(values);
    return cap;
  }

  group('descriptors', () {
    test('batch exposes the 10 spec-exact REST plugin names', () {
      expect(
        backendDescriptors.map((d) => d.pluginName),
        containsAll(pluginNames),
      );
      expect(backendDescriptors, hasLength(10));
    });

    test('auth schemes match spec §4.3', () {
      final byName = {for (final d in backendDescriptors) d.pluginName: d};
      expect(byName['Firebase MCP']!.auth, RestAuthKind.queryKey);
      expect(byName['Firebase MCP']!.authQueryKey, 'key');
      expect(byName['Supabase MCP']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Airtable MCP']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Appwrite MCP']!.auth, RestAuthKind.apiKeyHeader);
      expect(byName['Appwrite MCP']!.authHeader, 'X-Appwrite-Key');
      expect(byName['PocketBase MCP']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Vector DB MCP']!.auth, RestAuthKind.apiKeyHeader);
      expect(byName['Vector DB MCP']!.authHeader, 'Api-Key');
      expect(byName['MongoDB MCP']!.auth, RestAuthKind.apiKeyHeader);
      expect(byName['MongoDB MCP']!.authHeader, 'api-key');
    });

    test('fixed bases match spec §4.3', () {
      final byName = {for (final d in backendDescriptors) d.pluginName: d};
      expect(
        byName['Firebase MCP']!.baseUrl,
        'https://firestore.googleapis.com/v1',
      );
      expect(
        byName['Airtable MCP']!.baseUrl,
        'https://api.airtable.com/v0',
      );
    });

    test('tool rosters match spec §4.3', () {
      Iterable<String> toolsOf(String name) => backendDescriptors
          .firstWhere((d) => d.pluginName == name)
          .tools
          .map((t) => t.name);
      expect(
        toolsOf('Firebase MCP'),
        containsAll([
          'get_document',
          'list_documents',
          'create_document',
          'patch_document',
          'delete_document',
        ]),
      );
      expect(
        toolsOf('Supabase MCP'),
        containsAll(['select', 'insert', 'update', 'delete']),
      );
      expect(
        toolsOf('Airtable MCP'),
        containsAll([
          'list_records',
          'create_record',
          'update_record',
          'delete_record',
        ]),
      );
      expect(
        toolsOf('Appwrite MCP'),
        containsAll(['list_documents', 'create_document', 'list_users']),
      );
      expect(
        toolsOf('PocketBase MCP'),
        containsAll(['list_records', 'create_record']),
      );
      expect(
        toolsOf('Vector DB MCP'),
        containsAll(['query', 'fetch', 'stats']),
      );
      expect(
        toolsOf('MongoDB MCP'),
        containsAll(['find', 'find_one', 'insert_one']),
      );
      expect(
        toolsOf('S3 MCP'),
        containsAll([
          'list_objects',
          'get_object',
          'put_object',
          'delete_object',
          'presign_get',
        ]),
      );
      expect(
        toolsOf('Redis MCP'),
        containsAll(['get', 'set', 'del', 'keys', 'incr', 'expire']),
      );
      expect(
        toolsOf('Obsidian MCP'),
        containsAll([
          'list_notes',
          'read_note',
          'write_note',
          'append_note',
          'search_notes',
        ]),
      );
    });

    test('config fields expose secrets alongside extras', () {
      registerBackend();
      Set<String> keysOf(String name) => NativePluginRegistry.I
          .capabilityFor(name)!
          .configFields
          .map((f) => f.key)
          .toSet();
      expect(keysOf('Firebase MCP'), containsAll(['api_key', 'project_id']));
      expect(keysOf('Supabase MCP'), containsAll(['service_key', 'base_url']));
      expect(keysOf('Airtable MCP'), contains('token'));
      expect(
        keysOf('Appwrite MCP'),
        containsAll(['api_key', 'endpoint', 'project_id']),
      );
      expect(keysOf('PocketBase MCP'), containsAll(['token', 'base_url']));
      expect(keysOf('Vector DB MCP'), containsAll(['api_key', 'index_host']));
      expect(
        keysOf('MongoDB MCP'),
        containsAll(['api_key', 'data_api_base', 'data_source']),
      );
      expect(
        keysOf('S3 MCP'),
        containsAll(
            ['secret_access_key', 'access_key_id', 'region', 'bucket']),
      );
      expect(
        keysOf('Redis MCP'),
        containsAll(['host', 'port', 'password']),
      );
      expect(keysOf('Obsidian MCP'), contains('vault_root'));
    });
  });

  group('Firebase MCP', () {
    const values = {'api_key': 'fb-secret', 'project_id': 'demo-proj'};

    test('get_document keeps nested slashes with key auth', () async {
      http.Request? seen;
      final cap = await capFor(
        'Firebase MCP',
        (request) async {
          seen = request;
          return http.Response('{"name":"users/u1"}', 200);
        },
        values: values,
      );
      final out = await cap.callTool('get_document', {'path': 'users/u1'});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://firestore.googleapis.com/v1/projects/demo-proj/'
        'databases/(default)/documents/users/u1?key=fb-secret',
      );
      expect(out, contains('users/u1'));
    });

    test('list_documents GETs the collection', () async {
      http.Request? seen;
      final cap = await capFor(
        'Firebase MCP',
        (request) async {
          seen = request;
          return http.Response('{"documents":[]}', 200);
        },
        values: values,
      );
      await cap.callTool('list_documents', {'collection': 'users'});
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://firestore.googleapis.com/v1/projects/demo-proj/'
        'databases/(default)/documents/users?key=fb-secret',
      );
    });

    test('create_document POSTs wrapped fields', () async {
      http.Request? seen;
      final cap = await capFor(
        'Firebase MCP',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: values,
      );
      await cap.callTool('create_document', {
        'collection': 'users',
        'fields_json': {
          'name': {'stringValue': 'Ada'},
        },
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.path,
        '/v1/projects/demo-proj/databases/(default)/documents/users',
      );
      expect(
        jsonDecode(seen!.body) as Map,
        {
          'fields': {
            'name': {'stringValue': 'Ada'},
          },
        },
      );
    });

    test('patch_document PATCHes the nested path', () async {
      http.Request? seen;
      final cap = await capFor(
        'Firebase MCP',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: values,
      );
      await cap.callTool('patch_document', {
        'path': 'users/u1',
        'fields_json': {
          'nick': {'stringValue': 'A'},
        },
      });
      expect(seen!.method, 'PATCH');
      expect(
        seen!.url.toString(),
        contains('/documents/users/u1?key=fb-secret'),
      );
      expect(
        (jsonDecode(seen!.body) as Map)['fields'],
        {
          'nick': {'stringValue': 'A'},
        },
      );
    });

    test('delete_document DELETEs the nested path', () async {
      http.Request? seen;
      final cap = await capFor(
        'Firebase MCP',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: values,
      );
      await cap.callTool('delete_document', {'path': 'users/u1'});
      expect(seen!.method, 'DELETE');
      expect(
        seen!.url.toString(),
        contains('/documents/users/u1?key=fb-secret'),
      );
    });

    test('missing API key gates and never leaks the secret', () async {
      var called = false;
      final cap = await capFor(
        'Firebase MCP',
        (request) async {
          called = true;
          return http.Response('{}', 200);
        },
        values: {'project_id': 'demo-proj'},
      );
      final out = await cap.callTool('get_document', {'path': 'users/u1'});
      expect(out, contains('Configure Firebase API key first'));
      expect(out.contains('fb-secret'), isFalse);
      expect(called, isFalse);
    });

    test('missing project id gates before any request', () async {
      var called = false;
      final cap = await capFor(
        'Firebase MCP',
        (request) async {
          called = true;
          return http.Response('{}', 200);
        },
        values: {'api_key': 'fb-secret'},
      );
      final out = await cap.callTool('get_document', {'path': 'users/u1'});
      expect(out, contains('Configure Firebase project ID first'));
      expect(called, isFalse);
    });

    test('non-2xx errors pass through verbatim', () async {
      const body = '{"error":{"code":404,"message":"Not found."}}';
      final cap = await capFor(
        'Firebase MCP',
        (_) async => http.Response(body, 404),
        values: values,
      );
      final out = await cap.callTool('get_document', {'path': 'users/ghost'});
      expect(out, contains('404'));
      expect(out, contains(body));
    });
  });

  group('Supabase MCP', () {
    const values = {
      'service_key': 'sb-secret',
      'base_url': 'https://xyzcompany.supabase.co',
    };

    test('select passes the query map through as params', () async {
      http.Request? seen;
      final cap = await capFor(
        'Supabase MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
        values: values,
      );
      await cap.callTool('select', {
        'table': 'todos',
        'query': {'select': '*', 'done': 'eq.true'},
      });
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        startsWith('https://xyzcompany.supabase.co/rest/v1/todos'),
      );
      expect(seen!.url.queryParameters['select'], '*');
      expect(seen!.url.queryParameters['done'], 'eq.true');
      expect(seen!.headers['apikey'], 'sb-secret');
      expect(seen!.headers['Authorization'], 'Bearer sb-secret');
    });

    test('insert POSTs the row JSON with both auth headers', () async {
      http.Request? seen;
      final cap = await capFor(
        'Supabase MCP',
        (request) async {
          seen = request;
          return http.Response('{}', 201);
        },
        values: values,
      );
      await cap.callTool('insert', {
        'table': 'todos',
        'row_json': {'task': 'write tests'},
      });
      expect(seen!.method, 'POST');
      expect(seen!.url.toString(), endsWith('/rest/v1/todos'));
      expect(jsonDecode(seen!.body) as Map, {'task': 'write tests'});
      expect(seen!.headers['apikey'], 'sb-secret');
      expect(seen!.headers['Authorization'], 'Bearer sb-secret');
    });

    test('update PATCHes with filter params and patch body', () async {
      http.Request? seen;
      final cap = await capFor(
        'Supabase MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
        values: values,
      );
      await cap.callTool('update', {
        'table': 'todos',
        'query': {'id': 'eq.1'},
        'patch_json': {'done': true},
      });
      expect(seen!.method, 'PATCH');
      expect(seen!.url.queryParameters['id'], 'eq.1');
      expect(jsonDecode(seen!.body) as Map, {'done': true});
    });

    test('update without a filter map refuses', () async {
      final cap = await capFor(
        'Supabase MCP',
        (_) async => http.Response('[]', 200),
        values: values,
      );
      await expectLater(
        cap.callTool('update', {
          'table': 'todos',
          'query': <String, dynamic>{},
          'patch_json': {'done': true},
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('delete DELETEs with filter params', () async {
      http.Request? seen;
      final cap = await capFor(
        'Supabase MCP',
        (request) async {
          seen = request;
          return http.Response('[]', 200);
        },
        values: values,
      );
      await cap.callTool('delete', {
        'table': 'todos',
        'query': {'id': 'eq.9'},
      });
      expect(seen!.method, 'DELETE');
      expect(seen!.url.queryParameters['id'], 'eq.9');
    });

    test('missing service key gates and never leaks the secret', () async {
      var called = false;
      final cap = await capFor(
        'Supabase MCP',
        (request) async {
          called = true;
          return http.Response('[]', 200);
        },
        values: {'base_url': 'https://xyzcompany.supabase.co'},
      );
      final out = await cap.callTool('select', {'table': 'todos'});
      expect(out, contains('Configure Supabase service role key first'));
      expect(out.contains('sb-secret'), isFalse);
      expect(called, isFalse);
    });

    test('missing base URL gates before any request', () async {
      var called = false;
      final cap = await capFor(
        'Supabase MCP',
        (request) async {
          called = true;
          return http.Response('[]', 200);
        },
        values: {'service_key': 'sb-secret'},
      );
      final out = await cap.callTool('select', {'table': 'todos'});
      expect(out, contains('Configure Supabase project URL first'));
      expect(called, isFalse);
    });
  });

  group('Airtable MCP', () {
    const values = {'token': 'at-secret'};

    test('list_records GETs base + table with Bearer auth', () async {
      http.Request? seen;
      final cap = await capFor(
        'Airtable MCP',
        (request) async {
          seen = request;
          return http.Response('{"records":[]}', 200);
        },
        values: values,
      );
      await cap.callTool('list_records', {
        'base_id': 'app123',
        'table': 'Tasks',
      });
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://api.airtable.com/v0/app123/Tasks',
      );
      expect(seen!.headers['Authorization'], 'Bearer at-secret');
    });

    test('create_record POSTs wrapped fields', () async {
      http.Request? seen;
      final cap = await capFor(
        'Airtable MCP',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: values,
      );
      await cap.callTool('create_record', {
        'base_id': 'app123',
        'table': 'Tasks',
        'fields_json': {'Name': 'Write report'},
      });
      expect(seen!.method, 'POST');
      expect(
        jsonDecode(seen!.body) as Map,
        {
          'fields': {'Name': 'Write report'},
        },
      );
    });

    test('update_record PATCHes the record path', () async {
      http.Request? seen;
      final cap = await capFor(
        'Airtable MCP',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: values,
      );
      await cap.callTool('update_record', {
        'base_id': 'app123',
        'table': 'Tasks',
        'record_id': 'rec456',
        'fields_json': {'Status': 'Done'},
      });
      expect(seen!.method, 'PATCH');
      expect(seen!.url.toString(), endsWith('/app123/Tasks/rec456'));
      expect(
        (jsonDecode(seen!.body) as Map)['fields'],
        {'Status': 'Done'},
      );
    });

    test('delete_record DELETEs the record path', () async {
      http.Request? seen;
      final cap = await capFor(
        'Airtable MCP',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: values,
      );
      await cap.callTool('delete_record', {
        'base_id': 'app123',
        'table': 'Tasks',
        'record_id': 'rec456',
      });
      expect(seen!.method, 'DELETE');
      expect(seen!.url.toString(), endsWith('/app123/Tasks/rec456'));
    });

    test('missing token gates and never leaks the secret', () async {
      final cap = await capFor(
        'Airtable MCP',
        (_) async => http.Response('{}', 200),
      );
      final out = await cap.callTool(
        'list_records',
        {'base_id': 'app123', 'table': 'Tasks'},
      );
      expect(out, contains('Configure Airtable personal access token first'));
      expect(out.contains('at-secret'), isFalse);
    });
  });

  group('Appwrite MCP', () {
    const values = {
      'api_key': 'aw-secret',
      'endpoint': 'https://cloud.appwrite.io/v1',
      'project_id': 'proj-1',
    };

    test('list_documents GETs with project + key headers', () async {
      http.Request? seen;
      final cap = await capFor(
        'Appwrite MCP',
        (request) async {
          seen = request;
          return http.Response('{"documents":[]}', 200);
        },
        values: values,
      );
      await cap.callTool('list_documents', {
        'db_id': 'db1',
        'collection_id': 'col1',
      });
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        'https://cloud.appwrite.io/v1/databases/db1/collections/col1/documents',
      );
      expect(seen!.headers['X-Appwrite-Project'], 'proj-1');
      expect(seen!.headers['X-Appwrite-Key'], 'aw-secret');
    });

    test('create_document POSTs the data JSON', () async {
      http.Request? seen;
      final cap = await capFor(
        'Appwrite MCP',
        (request) async {
          seen = request;
          return http.Response('{}', 201);
        },
        values: values,
      );
      await cap.callTool('create_document', {
        'db_id': 'db1',
        'collection_id': 'col1',
        'data_json': {'title': 'Hello'},
      });
      expect(seen!.method, 'POST');
      expect(jsonDecode(seen!.body) as Map, {'title': 'Hello'});
      expect(seen!.headers['X-Appwrite-Project'], 'proj-1');
    });

    test('list_users GETs /users', () async {
      http.Request? seen;
      final cap = await capFor(
        'Appwrite MCP',
        (request) async {
          seen = request;
          return http.Response('{"users":[]}', 200);
        },
        values: values,
      );
      await cap.callTool('list_users', {});
      expect(seen!.url.toString(), 'https://cloud.appwrite.io/v1/users');
    });

    test('missing endpoint gates before any request', () async {
      var called = false;
      final cap = await capFor(
        'Appwrite MCP',
        (request) async {
          called = true;
          return http.Response('{}', 200);
        },
        values: {'api_key': 'aw-secret', 'project_id': 'proj-1'},
      );
      final out = await cap.callTool('list_users', {});
      expect(out, contains('Configure Appwrite endpoint first'));
      expect(called, isFalse);
    });

    test('missing project id gates before any request', () async {
      var called = false;
      final cap = await capFor(
        'Appwrite MCP',
        (request) async {
          called = true;
          return http.Response('{}', 200);
        },
        values: {
          'api_key': 'aw-secret',
          'endpoint': 'https://cloud.appwrite.io/v1',
        },
      );
      final out = await cap.callTool('list_users', {});
      expect(out, contains('Configure Appwrite project ID first'));
      expect(called, isFalse);
    });

    test('missing API key gates and never leaks the secret', () async {
      final cap = await capFor(
        'Appwrite MCP',
        (_) async => http.Response('{}', 200),
        values: {
          'endpoint': 'https://cloud.appwrite.io/v1',
          'project_id': 'proj-1',
        },
      );
      final out = await cap.callTool('list_users', {});
      expect(out, contains('Configure Appwrite API key first'));
      expect(out.contains('aw-secret'), isFalse);
    });
  });

  group('PocketBase MCP', () {
    const values = {'token': 'pb-secret', 'base_url': 'https://pb.example.com'};

    test('list_records GETs the collection records page', () async {
      http.Request? seen;
      final cap = await capFor(
        'PocketBase MCP',
        (request) async {
          seen = request;
          return http.Response('{"items":[]}', 200);
        },
        values: values,
      );
      await cap.callTool('list_records', {
        'collection': 'tasks',
        'page': 2,
      });
      expect(seen!.method, 'GET');
      expect(
        seen!.url.toString(),
        startsWith('https://pb.example.com/api/collections/tasks/records'),
      );
      expect(seen!.url.queryParameters['page'], '2');
      expect(seen!.headers['Authorization'], 'Bearer pb-secret');
    });

    test('create_record POSTs the data JSON', () async {
      http.Request? seen;
      final cap = await capFor(
        'PocketBase MCP',
        (request) async {
          seen = request;
          return http.Response('{}', 200);
        },
        values: values,
      );
      await cap.callTool('create_record', {
        'collection': 'tasks',
        'data_json': {'title': 'Hi'},
      });
      expect(seen!.method, 'POST');
      expect(jsonDecode(seen!.body) as Map, {'title': 'Hi'});
      expect(seen!.headers['Authorization'], 'Bearer pb-secret');
    });

    test('missing base URL gates before any request', () async {
      var called = false;
      final cap = await capFor(
        'PocketBase MCP',
        (request) async {
          called = true;
          return http.Response('{}', 200);
        },
        values: {'token': 'pb-secret'},
      );
      final out = await cap.callTool('list_records', {'collection': 'tasks'});
      expect(out, contains('Configure PocketBase base URL first'));
      expect(called, isFalse);
    });

    test('missing token gates and never leaks the secret', () async {
      final cap = await capFor(
        'PocketBase MCP',
        (_) async => http.Response('{}', 200),
        values: {'base_url': 'https://pb.example.com'},
      );
      final out = await cap.callTool('list_records', {'collection': 'tasks'});
      expect(out, contains('Configure PocketBase token first'));
      expect(out.contains('pb-secret'), isFalse);
    });
  });

  group('Vector DB MCP', () {
    const values = {
      'api_key': 'vec-secret',
      'index_host': 'https://my-index.svc.pinecone.io',
    };

    test('query POSTs vector + topK with Api-Key', () async {
      http.Request? seen;
      final cap = await capFor(
        'Vector DB MCP',
        (request) async {
          seen = request;
          return http.Response('{"matches":[]}', 200);
        },
        values: values,
      );
      await cap.callTool('query', {
        'vector_json': [0.1, 0.2, 0.3],
        'top_k': 5,
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://my-index.svc.pinecone.io/query',
      );
      expect(seen!.headers['Api-Key'], 'vec-secret');
      expect(
        jsonDecode(seen!.body) as Map,
        {
          'vector': [0.1, 0.2, 0.3],
          'topK': 5,
        },
      );
    });

    test('fetch POSTs the id list', () async {
      http.Request? seen;
      final cap = await capFor(
        'Vector DB MCP',
        (request) async {
          seen = request;
          return http.Response('{"vectors":{}}', 200);
        },
        values: values,
      );
      await cap.callTool('fetch', {
        'ids': ['a', 'b'],
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://my-index.svc.pinecone.io/fetch',
      );
      expect(
        jsonDecode(seen!.body) as Map,
        {
          'ids': ['a', 'b'],
        },
      );
    });

    test('stats reads index stats', () async {
      http.Request? seen;
      final cap = await capFor(
        'Vector DB MCP',
        (request) async {
          seen = request;
          return http.Response('{"dimension":3}', 200);
        },
        values: values,
      );
      final out = await cap.callTool('stats', {});
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://my-index.svc.pinecone.io/describeIndexStats',
      );
      expect(out, contains('dimension'));
    });

    test('missing index host gates before any request', () async {
      var called = false;
      final cap = await capFor(
        'Vector DB MCP',
        (request) async {
          called = true;
          return http.Response('{}', 200);
        },
        values: {'api_key': 'vec-secret'},
      );
      final out = await cap.callTool('query', {
        'vector_json': [0.1],
      });
      expect(out, contains('Configure Vector DB index host first'));
      expect(called, isFalse);
    });

    test('missing API key gates and never leaks the secret', () async {
      final cap = await capFor(
        'Vector DB MCP',
        (_) async => http.Response('{}', 200),
        values: {'index_host': 'https://my-index.svc.pinecone.io'},
      );
      final out = await cap.callTool('stats', {});
      expect(out, contains('Configure Vector DB API key first'));
      expect(out.contains('vec-secret'), isFalse);
    });
  });

  group('MongoDB MCP', () {
    const values = {
      'api_key': 'mongo-secret',
      'data_api_base': 'https://data.mongodb-api.com/app/app1/endpoint/data/v1',
      'data_source': 'Cluster0',
    };

    test('find POSTs the Data API find body', () async {
      http.Request? seen;
      final cap = await capFor(
        'MongoDB MCP',
        (request) async {
          seen = request;
          return http.Response('{"documents":[]}', 200);
        },
        values: values,
      );
      await cap.callTool('find', {
        'db': 'shop',
        'coll': 'orders',
        'filter_json': {'status': 'open'},
        'limit': 20,
      });
      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://data.mongodb-api.com/app/app1/endpoint/data/v1/action/find',
      );
      expect(seen!.headers['api-key'], 'mongo-secret');
      expect(
        jsonDecode(seen!.body) as Map,
        {
          'dataSource': 'Cluster0',
          'database': 'shop',
          'collection': 'orders',
          'filter': {'status': 'open'},
          'limit': 20,
        },
      );
    });

    test('find_one POSTs to findOne without a limit', () async {
      http.Request? seen;
      final cap = await capFor(
        'MongoDB MCP',
        (request) async {
          seen = request;
          return http.Response('{"document":{}}', 200);
        },
        values: values,
      );
      await cap.callTool('find_one', {
        'db': 'shop',
        'coll': 'orders',
        'filter_json': {'_id': 'abc'},
      });
      expect(seen!.url.toString(), endsWith('/action/findOne'));
      final payload = jsonDecode(seen!.body) as Map;
      expect(payload['filter'], {'_id': 'abc'});
      expect(payload.containsKey('limit'), isFalse);
    });

    test('insert_one POSTs the document', () async {
      http.Request? seen;
      final cap = await capFor(
        'MongoDB MCP',
        (request) async {
          seen = request;
          return http.Response('{"insertedId":"abc"}', 200);
        },
        values: values,
      );
      await cap.callTool('insert_one', {
        'db': 'shop',
        'coll': 'orders',
        'doc_json': {'item': 'book'},
      });
      expect(seen!.url.toString(), endsWith('/action/insertOne'));
      expect(
        (jsonDecode(seen!.body) as Map)['document'],
        {'item': 'book'},
      );
    });

    test('missing data source gates before any request', () async {
      var called = false;
      final cap = await capFor(
        'MongoDB MCP',
        (request) async {
          called = true;
          return http.Response('{}', 200);
        },
        values: {
          'api_key': 'mongo-secret',
          'data_api_base':
              'https://data.mongodb-api.com/app/app1/endpoint/data/v1',
        },
      );
      final out = await cap.callTool('find', {'db': 'shop', 'coll': 'orders'});
      expect(out, contains('Configure MongoDB data source first'));
      expect(called, isFalse);
    });

    test('missing Data API base gates before any request', () async {
      var called = false;
      final cap = await capFor(
        'MongoDB MCP',
        (request) async {
          called = true;
          return http.Response('{}', 200);
        },
        values: {'api_key': 'mongo-secret', 'data_source': 'Cluster0'},
      );
      final out = await cap.callTool('find', {'db': 'shop', 'coll': 'orders'});
      expect(out, contains('Configure MongoDB Data API base URL first'));
      expect(called, isFalse);
    });

    test('missing API key gates and never leaks the secret', () async {
      final cap = await capFor(
        'MongoDB MCP',
        (_) async => http.Response('{}', 200),
        values: {
          'data_api_base':
              'https://data.mongodb-api.com/app/app1/endpoint/data/v1',
          'data_source': 'Cluster0',
        },
      );
      final out = await cap.callTool('find', {'db': 'shop', 'coll': 'orders'});
      expect(out, contains('Configure MongoDB Data API key first'));
      expect(out.contains('mongo-secret'), isFalse);
    });
  });

  group('S3 MCP', () {
    const values = {
      'secret_access_key': 'aws-secret',
      'access_key_id': 'AKIDEXAMPLE',
      'region': 'us-east-1',
      'bucket': 'mybucket',
    };

    /// Recomputes the expected SigV4 header from the captured request and
    /// asserts the capability signed exactly that (URL ↔ signer consistency).
    void expectValidSignature(http.Request seen, {required String body}) {
      final amzDate = seen.headers['x-amz-date']!;
      final auth = seen.headers['Authorization']!;
      final query = Map<String, String>.from(seen.url.queryParameters);
      final expected = s3Authorization(
        accessKeyId: 'AKIDEXAMPLE',
        secretAccessKey: 'aws-secret',
        region: 'us-east-1',
        method: seen.method,
        canonicalUri: seen.url.path,
        queryParameters: query,
        headers: {
          'host': seen.url.host,
          'x-amz-date': amzDate,
        },
        payloadHash: sha256.convert(utf8.encode(body)).toString(),
        amzDate: _parseAmzDate(amzDate),
      );
      expect(auth, expected);
    }

    test('list_objects signs a GET with list-type + prefix', () async {
      http.Request? seen;
      final cap = await capFor(
        'S3 MCP',
        (request) async {
          seen = request;
          return http.Response('<ListBucketResult/>', 200);
        },
        values: values,
      );
      final out = await cap.callTool('list_objects', {'prefix': 'photos/'});
      expect(seen!.method, 'GET');
      expect(seen!.url.host, 'mybucket.s3.us-east-1.amazonaws.com');
      expect(seen!.url.path, '/');
      expect(seen!.url.queryParameters['list-type'], '2');
      expect(seen!.url.queryParameters['prefix'], 'photos/');
      expect(
        seen!.headers['Authorization'],
        startsWith('AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/'),
      );
      expect(seen!.headers['Authorization'], contains('SignedHeaders=host;'));
      expectValidSignature(seen!, body: '');
      expect(out, contains('ListBucketResult'));
    });

    test('get_object GETs the key with literal slashes', () async {
      http.Request? seen;
      final cap = await capFor(
        'S3 MCP',
        (request) async {
          seen = request;
          return http.Response('hello world', 200);
        },
        values: values,
      );
      final out = await cap.callTool('get_object', {'key': 'a/b.txt'});
      expect(seen!.method, 'GET');
      expect(seen!.url.path, '/a/b.txt');
      expectValidSignature(seen!, body: '');
      expect(out, 'hello world');
    });

    test('put_object PUTs text with a payload-signed header', () async {
      http.Request? seen;
      final cap = await capFor(
        'S3 MCP',
        (request) async {
          seen = request;
          return http.Response('', 200);
        },
        values: values,
      );
      final out = await cap.callTool('put_object', {
        'key': 'notes/hi.txt',
        'text': 'hello',
      });
      expect(seen!.method, 'PUT');
      expect(seen!.url.path, '/notes/hi.txt');
      expect(seen!.body, 'hello');
      expectValidSignature(seen!, body: 'hello');
      expect(out, contains('notes/hi.txt'));
    });

    test('delete_object DELETEs the key', () async {
      http.Request? seen;
      final cap = await capFor(
        'S3 MCP',
        (request) async {
          seen = request;
          return http.Response('', 204);
        },
        values: values,
      );
      await cap.callTool('delete_object', {'key': 'old.txt'});
      expect(seen!.method, 'DELETE');
      expect(seen!.url.path, '/old.txt');
      expectValidSignature(seen!, body: '');
    });

    test('presign_get signs purely without any network', () async {
      final cap = S3Capability(
        client: MockClient(
          (_) async => throw StateError('presign must not hit the network'),
        ),
      );
      await cap.configure(values);
      final out = await cap.callTool('presign_get', {'key': 'a/b.txt'});
      final uri = Uri.parse(out.trim());
      expect(uri.host, 'mybucket.s3.us-east-1.amazonaws.com');
      expect(uri.path, '/a/b.txt');
      expect(
        uri.queryParameters['X-Amz-Algorithm'],
        'AWS4-HMAC-SHA256',
      );
      expect(uri.queryParameters['X-Amz-Expires'], '3600');
      expect(
        uri.queryParameters['X-Amz-Credential'],
        startsWith('AKIDEXAMPLE/'),
      );
      final signature = uri.queryParameters['X-Amz-Signature'] ?? '';
      expect(signature, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('s3PresignedGetUrl is deterministic for a fixed date', () {
      final first = s3PresignedGetUrl(
        accessKeyId: 'AKIDEXAMPLE',
        secretAccessKey: 'aws-secret',
        region: 'us-east-1',
        bucket: 'mybucket',
        key: 'a/b.txt',
        amzDate: DateTime.utc(2026, 1, 2, 3, 4, 5),
      );
      final second = s3PresignedGetUrl(
        accessKeyId: 'AKIDEXAMPLE',
        secretAccessKey: 'aws-secret',
        region: 'us-east-1',
        bucket: 'mybucket',
        key: 'a/b.txt',
        amzDate: DateTime.utc(2026, 1, 2, 3, 4, 5),
      );
      expect(first, second);
      expect(first, contains('X-Amz-Date=20260102T030405Z'));
      expect(first, contains('X-Amz-Expires=3600'));
    });

    test('s3PresignedGetUrl matches the frozen SigV4 presign vector', () {
      // Known-answer vector for SigV4 query-auth presigning. Frozen input:
      // examplebucket/test.txt, us-east-1, 20130524T000000Z, expires 86400,
      // AWS documentation-style test credentials (never real secrets).
      // Expected signature e88bfc86…2633 was derived INDEPENDENTLY of the
      // Dart signer: a hand-written Python stdlib (hashlib/hmac) chain over
      // the spec canonical request, cross-checked byte-for-byte against
      // botocore's S3SigV4QueryAuth with time frozen to 2013-05-24T00:00:00Z
      // (both agree). A deterministically wrong signer would fail here.
      expect(
        s3PresignedGetUrl(
          accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
          secretAccessKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
          region: 'us-east-1',
          bucket: 'examplebucket',
          key: 'test.txt',
          expiresSeconds: 86400,
          amzDate: DateTime.utc(2013, 5, 24),
        ),
        'https://examplebucket.s3.us-east-1.amazonaws.com/test.txt'
        '?X-Amz-Algorithm=AWS4-HMAC-SHA256'
        '&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request'
        '&X-Amz-Date=20130524T000000Z'
        '&X-Amz-Expires=86400'
        '&X-Amz-SignedHeaders=host'
        '&X-Amz-Signature=e88bfc86a6838bda6e6b842bfd69edd8741f6aedb0459e1275be0713ad3e2633',
      );
    });

    test('missing secret key gates and never leaks the secret', () async {
      var called = false;
      final cap = await capFor(
        'S3 MCP',
        (request) async {
          called = true;
          return http.Response('', 200);
        },
        values: const {
          'access_key_id': 'AKIDEXAMPLE',
          'region': 'us-east-1',
          'bucket': 'mybucket',
        },
      );
      final out = await cap.callTool('list_objects', {});
      expect(out, contains('Configure AWS secret access key first'));
      expect(out.contains('aws-secret'), isFalse);
      expect(called, isFalse);
    });

    test('missing region gates before any request', () async {
      final cap = await capFor(
        'S3 MCP',
        (_) async => http.Response('', 200),
        values: const {
          'secret_access_key': 'aws-secret',
          'access_key_id': 'AKIDEXAMPLE',
          'bucket': 'mybucket',
        },
      );
      final out = await cap.callTool('list_objects', {});
      expect(out, contains('Configure AWS region first'));
    });
  });

  group('Redis MCP', () {
    test('get/set round-trip with byte-exact RESP frames', () async {
      final fake = await _FakeRedis.bind();
      addTearDown(fake.close);
      final cap = RedisCapability();
      await cap.configure({
        'host': '127.0.0.1',
        'port': '${fake.port}',
      });

      final setOut = await cap.callTool('set', {
        'key': 'greeting',
        'value': 'hello',
      });
      expect(setOut, 'OK');
      final getOut = await cap.callTool('get', {'key': 'greeting'});
      expect(getOut, 'hello-value');

      expect(
        fake.frames.singleWhere((f) => f.contains('greeting') && f.contains('SET')),
        respEncode(['SET', 'greeting', 'hello']),
      );
      expect(
        fake.frames.singleWhere((f) => f.contains('GET')),
        respEncode(['GET', 'greeting']),
      );
    });

    test('set with EX sends the expiry frame', () async {
      final fake = await _FakeRedis.bind();
      addTearDown(fake.close);
      final cap = RedisCapability();
      await cap.configure({
        'host': '127.0.0.1',
        'port': '${fake.port}',
      });
      await cap.callTool('set', {
        'key': 'session',
        'value': 'abc',
        'ex_seconds': 60,
      });
      expect(
        fake.frames.singleWhere((f) => f.contains('session')),
        respEncode(['SET', 'session', 'abc', 'EX', '60']),
      );
    });

    test('password authenticates first and del/incr/expire/keys work',
        () async {
      final fake = await _FakeRedis.bind();
      addTearDown(fake.close);
      final cap = RedisCapability();
      await cap.configure({
        'host': '127.0.0.1',
        'port': '${fake.port}',
        'password': 'pw-secret',
      });

      expect(await cap.callTool('incr', {'key': 'counter'}), '41');
      expect(await cap.callTool('expire', {
        'key': 'counter',
        'seconds': 30,
      }), '1');
      expect(await cap.callTool('del', {
        'keys': ['a', 'b'],
      }), '2');
      expect(await cap.callTool('keys', {'pattern': '*'}), 'foo\nbar');

      expect(fake.frames.first, respEncode(['AUTH', 'pw-secret']));
      expect(
        fake.frames.singleWhere((f) => f.contains('INCR')),
        respEncode(['INCR', 'counter']),
      );
      expect(
        fake.frames.singleWhere((f) => f.contains('EXPIRE')),
        respEncode(['EXPIRE', 'counter', '30']),
      );
      expect(
        fake.frames.singleWhere((f) => f.contains('DEL')),
        respEncode(['DEL', 'a', 'b']),
      );
    });

    test('unreachable server is reported honestly without leaking secrets',
        () async {
      // Reserve a loopback port, then close it so nothing listens there.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final cap = RedisCapability();
      await cap.configure({
        'host': '127.0.0.1',
        'port': '$port',
        'password': 'pw-secret',
      });
      final out = await cap.callTool('get', {'key': 'k'});
      expect(out, contains('unreachable'));
      expect(out, contains('127.0.0.1:$port'));
      expect(out.contains('pw-secret'), isFalse);
    });
  });

  group('Obsidian MCP', () {
    late Directory vault;

    setUp(() async {
      vault = await Directory.systemTemp.createTemp('obsidian_test_');
    });

    tearDown(() async {
      if (await vault.exists()) await vault.delete(recursive: true);
    });

    Future<NativePluginCapability> vaultCap() => capFor(
          'Obsidian MCP',
          (_) async => http.Response('', 500),
          values: {'vault_root': vault.path},
        );

    test('write, read, list, append, and search round-trip', () async {
      final cap = await vaultCap();
      await cap.callTool('write_note', {
        'path': 'ideas/today.md',
        'text': '# Today\nBuy milk',
      });
      await cap.callTool('write_note', {
        'path': 'ideas/todo.md',
        'text': '# Todo\nBuy MILK and eggs',
      });
      await cap.callTool('append_note', {
        'path': 'ideas/today.md',
        'text': '\nCall mom',
      });

      expect(
        await cap.callTool('read_note', {'path': 'ideas/today.md'}),
        contains('Call mom'),
      );
      final listed = await cap.callTool('list_notes', {});
      expect(listed, contains('ideas/today.md'));
      expect(listed, contains('ideas/todo.md'));
      final hits = await cap.callTool('search_notes', {'query': 'milk'});
      expect(hits, contains('ideas/today.md'));
      expect(hits, contains('ideas/todo.md'));
    });

    test('paths escaping the vault root are refused', () async {
      final cap = await vaultCap();
      await cap.callTool('write_note', {'path': 'ok.md', 'text': 'safe'});
      for (final evil in ['../escape.md', 'sub/../../escape.md']) {
        await expectLater(
          cap.callTool('read_note', {'path': evil}),
          throwsA(isA<ArgumentError>()),
          reason: evil,
        );
        await expectLater(
          cap.callTool('write_note', {'path': evil, 'text': 'x'}),
          throwsA(isA<ArgumentError>()),
          reason: evil,
        );
      }
      expect(await cap.callTool('list_notes', {}), contains('ok.md'));
    });

    test('missing vault root gates before touching the filesystem', () async {
      final cap = await capFor('Obsidian MCP', (_) async {
        return http.Response('', 500);
      });
      final out = await cap.callTool('list_notes', {});
      expect(out, contains('Configure Obsidian vault root first'));
    });
  });

  group('registration + roster', () {
    test('registerBackend registers all 10 services', () {
      registerBackend();
      for (final name in pluginNames) {
        expect(
          NativePluginRegistry.I.has(name),
          isTrue,
          reason: '$name registered',
        );
      }
    });

    test('roster half: plugin__s3_mcp__list_objects resolves', () {
      registerBackend();
      const canonical = 'plugin__s3_mcp__list_objects';
      final slug = canonical.substring('plugin__'.length).split('__').first;
      final tool = canonical.split('__').last;
      final cap = NativePluginRegistry.I.capabilityForSlug(slug);
      expect(cap, isNotNull);
      expect(cap!.pluginName, 'S3 MCP');
      expect(cap.tools.map((t) => t.name), contains(tool));
    });

    test('roster half: plugin__obsidian_mcp__list_notes resolves', () {
      registerBackend();
      const canonical = 'plugin__obsidian_mcp__list_notes';
      final slug = canonical.substring('plugin__'.length).split('__').first;
      final tool = canonical.split('__').last;
      final cap = NativePluginRegistry.I.capabilityForSlug(slug);
      expect(cap, isNotNull);
      expect(cap!.pluginName, 'Obsidian MCP');
      expect(cap.tools.map((t) => t.name), contains(tool));
    });

    test('unknown tool still throws ArgumentError', () async {
      final cap = await capFor(
        'Airtable MCP',
        (_) async => http.Response('{}', 200),
        values: const {'token': 'at-secret'},
      );
      await expectLater(
        cap.callTool('nope', {}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

/// Parses `yyyyMMddTHHmmssZ` back to a UTC [DateTime] (test-only inverse of
/// the S3 capability's date formatter).
DateTime _parseAmzDate(String value) {
  final year = int.parse(value.substring(0, 4));
  final month = int.parse(value.substring(4, 6));
  final day = int.parse(value.substring(6, 8));
  final hour = int.parse(value.substring(9, 11));
  final minute = int.parse(value.substring(11, 13));
  final second = int.parse(value.substring(13, 15));
  return DateTime.utc(year, month, day, hour, minute, second);
}

/// Minimal scripted Redis fake: Records every complete RESP frame it
/// receives (as decoded strings for byte-exact assertions) and answers one
/// canned reply per command word.
class _FakeRedis {
  _FakeRedis._(this.server);

  final ServerSocket server;
  final List<String> frames = [];
  final List<List<String>> commands = [];
  StreamSubscription<Socket>? _sub;
  final List<Socket> _sockets = [];

  int get port => server.port;

  static Future<_FakeRedis> bind() async {
    final server =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeRedis._(server);
    fake._sub = server.listen((Socket socket) {
      fake._sockets.add(socket);
      final buffer = <int>[];
      socket.listen(
        (chunk) {
          buffer.addAll(chunk);
          while (true) {
            final parsed = _tryParseFrame(buffer);
            if (parsed == null) return;
            buffer.removeRange(0, parsed.consumed);
            fake.commands.add(parsed.command);
            fake.frames.add(utf8.decode(parsed.raw));
            socket.add(utf8.encode(_replyFor(parsed.command)));
          }
        },
        onDone: () => socket.destroy(),
      );
    });
    return fake;
  }

  static String _replyFor(List<String> command) {
    if (command.isEmpty) return '+OK\r\n';
    switch (command.first.toUpperCase()) {
      case 'AUTH':
        return '+OK\r\n';
      case 'GET':
        return '\$11\r\nhello-value\r\n';
      case 'SET':
        return '+OK\r\n';
      case 'DEL':
        return ':2\r\n';
      case 'KEYS':
        return '*2\r\n\$3\r\nfoo\r\n\$3\r\nbar\r\n';
      case 'INCR':
        return ':41\r\n';
      case 'EXPIRE':
        return ':1\r\n';
      default:
        return '+OK\r\n';
    }
  }

  Future<void> close() async {
    await _sub?.cancel();
    for (final socket in _sockets) {
      socket.destroy();
    }
    await server.close();
  }
}

/// One parsed RESP array-of-bulk-strings frame.
class _ParsedFrame {
  _ParsedFrame(this.command, this.raw, this.consumed);
  final List<String> command;
  final List<int> raw;
  final int consumed;
}

/// Tries to parse one complete RESP frame at the head of [buffer]; returns
/// null while the frame is incomplete.
_ParsedFrame? _tryParseFrame(List<int> buffer) {
  int crlf(int from) {
    for (var i = from; i + 1 < buffer.length; i++) {
      if (buffer[i] == 0x0D && buffer[i + 1] == 0x0A) return i;
    }
    return -1;
  }

  if (buffer.isEmpty || buffer[0] != 0x2A) return null;
  final headEnd = crlf(0);
  if (headEnd < 0) return null;
  final count = int.tryParse(utf8.decode(buffer.sublist(1, headEnd)));
  if (count == null || count < 0) return null;
  var cursor = headEnd + 2;
  final parts = <String>[];
  for (var i = 0; i < count; i++) {
    if (cursor >= buffer.length || buffer[cursor] != 0x24) return null;
    final lenEnd = crlf(cursor);
    if (lenEnd < 0) return null;
    final length =
        int.tryParse(utf8.decode(buffer.sublist(cursor + 1, lenEnd)));
    if (length == null || length < 0) return null;
    final start = lenEnd + 2;
    if (buffer.length < start + length + 2) return null;
    parts.add(utf8.decode(buffer.sublist(start, start + length)));
    cursor = start + length + 2;
  }
  return _ParsedFrame(parts, buffer.sublist(0, cursor), cursor);
}
