import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ovid_ai/core/native_plugins/rest_descriptors_backend.dart';
import 'package:ovid_ai/core/native_plugins/rest_engine.dart';
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The backend & data batch wraps `RestApiCapability` for seven routing /
/// synthesis capabilities. Each wrapper accepted a `UtilityCancellation?
/// cancellation` token but dropped it on the floor, so a Stop could never
/// reach the engine's inner call. These tests prove the token is now
/// forwarded to the inner call (and that the public signatures keep it).
class _RecordingRestApiCapability extends RestApiCapability {
  _RecordingRestApiCapability(super.descriptor, {super.client});

  String? seenTool;
  UtilityCancellation? seenCancellation;

  @override
  Future<String> callTool(
    String toolName,
    Map<String, dynamic> args, {
    UtilityCancellation? cancellation,
  }) async {
    seenTool = toolName;
    seenCancellation = cancellation;
    return 'recorded:$toolName';
  }
}

/// Common surface the seam subclasses expose to the harness.
abstract class _SeamWrapper {
  _RecordingRestApiCapability? get recorder;
  Future<void> configure(Map<String, String> values);
  Future<String> callTool(
    String toolName,
    Map<String, dynamic> args, {
    UtilityCancellation? cancellation,
  });
}

class _SeamFirebase extends FirebaseCapability implements _SeamWrapper {
  @override
  _RecordingRestApiCapability? recorder;

  @override
  RestApiCapability buildRestApiCapability(
    RestServiceDescriptor descriptor, {
    http.Client? client,
  }) =>
      recorder = _RecordingRestApiCapability(descriptor, client: client);
}

class _SeamSupabase extends SupabaseCapability implements _SeamWrapper {
  @override
  _RecordingRestApiCapability? recorder;

  @override
  RestApiCapability buildRestApiCapability(
    RestServiceDescriptor descriptor, {
    http.Client? client,
  }) =>
      recorder = _RecordingRestApiCapability(descriptor, client: client);
}

class _SeamAirtable extends AirtableCapability implements _SeamWrapper {
  @override
  _RecordingRestApiCapability? recorder;

  @override
  RestApiCapability buildRestApiCapability(
    RestServiceDescriptor descriptor, {
    http.Client? client,
  }) =>
      recorder = _RecordingRestApiCapability(descriptor, client: client);
}

class _SeamAppwrite extends AppwriteCapability implements _SeamWrapper {
  @override
  _RecordingRestApiCapability? recorder;

  @override
  RestApiCapability buildRestApiCapability(
    RestServiceDescriptor descriptor, {
    http.Client? client,
  }) =>
      recorder = _RecordingRestApiCapability(descriptor, client: client);
}

class _SeamPocketBase extends PocketBaseCapability implements _SeamWrapper {
  @override
  _RecordingRestApiCapability? recorder;

  @override
  RestApiCapability buildRestApiCapability(
    RestServiceDescriptor descriptor, {
    http.Client? client,
  }) =>
      recorder = _RecordingRestApiCapability(descriptor, client: client);
}

class _SeamVectorDb extends VectorDbCapability implements _SeamWrapper {
  @override
  _RecordingRestApiCapability? recorder;

  @override
  RestApiCapability buildRestApiCapability(
    RestServiceDescriptor descriptor, {
    http.Client? client,
  }) =>
      recorder = _RecordingRestApiCapability(descriptor, client: client);
}

class _SeamMongoDb extends MongoDbCapability implements _SeamWrapper {
  @override
  _RecordingRestApiCapability? recorder;

  @override
  RestApiCapability buildRestApiCapability(
    RestServiceDescriptor descriptor, {
    http.Client? client,
  }) =>
      recorder = _RecordingRestApiCapability(descriptor, client: client);
}

class _Case {
  const _Case(this.build, this.values, this.tool, this.args);

  final _SeamWrapper Function() build;
  final Map<String, String> values;
  final String tool;
  final Map<String, dynamic> args;
}

const _cases = <String, _Case>{
  'Firebase MCP': _Case(
    _SeamFirebase.new,
    {'api_key': 'fb-secret', 'project_id': 'demo-proj'},
    'list_documents',
    {'collection': 'users'},
  ),
  'Supabase MCP': _Case(
    _SeamSupabase.new,
    {'service_key': 'sb-secret', 'base_url': 'https://xyzcompany.supabase.co'},
    'select',
    {'table': 'todos'},
  ),
  'Airtable MCP': _Case(
    _SeamAirtable.new,
    {'token': 'at-secret'},
    'list_records',
    {'base_id': 'app123', 'table': 'Tasks'},
  ),
  'Appwrite MCP': _Case(
    _SeamAppwrite.new,
    {
      'api_key': 'aw-secret',
      'endpoint': 'https://cloud.appwrite.io/v1',
      'project_id': 'proj-1',
    },
    'list_users',
    <String, dynamic>{},
  ),
  'PocketBase MCP': _Case(
    _SeamPocketBase.new,
    {'token': 'pb-secret', 'base_url': 'https://pb.example.com'},
    'list_records',
    {'collection': 'tasks'},
  ),
  'Vector DB MCP': _Case(
    _SeamVectorDb.new,
    {'api_key': 'vec-secret', 'index_host': 'https://my-index.svc.pinecone.io'},
    'stats',
    <String, dynamic>{},
  ),
  'MongoDB MCP': _Case(
    _SeamMongoDb.new,
    {
      'api_key': 'mongo-secret',
      'data_api_base':
          'https://data.mongodb-api.com/app/app1/endpoint/data/v1',
      'data_source': 'Cluster0',
    },
    'find',
    {'db': 'shop', 'coll': 'orders'},
  ),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sourcePath = 'lib/core/native_plugins/rest_descriptors_backend.dart';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('cancellation forwarding (behavioral)', () {
    test('every wrapper forwards the exact token to the inner call', () async {
      for (final entry in _cases.entries) {
        final cap = entry.value.build();
        await cap.configure(entry.value.values);

        final token = UtilityCancellation();
        final out = await cap.callTool(
          entry.value.tool,
          entry.value.args,
          cancellation: token,
        );

        expect(out, 'recorded:${entry.value.tool}', reason: entry.key);
        expect(cap.recorder, isNotNull, reason: entry.key);
        expect(cap.recorder!.seenTool, entry.value.tool, reason: entry.key);
        expect(
          identical(cap.recorder!.seenCancellation, token),
          isTrue,
          reason: '${entry.key}: the wrapper token must reach the inner call',
        );
      }
    });

    test('a null token is passed through unchanged', () async {
      for (final entry in _cases.entries) {
        final cap = entry.value.build();
        await cap.configure(entry.value.values);

        await cap.callTool(entry.value.tool, entry.value.args);

        expect(cap.recorder, isNotNull, reason: entry.key);
        expect(cap.recorder!.seenCancellation, isNull, reason: entry.key);
      }
    });
  });

  group('cancellation forwarding (source)', () {
    test('every RestApiCapability delegation forwards the token', () {
      final src = File(sourcePath).readAsStringSync();
      final delegations = RegExp(
        r'return buildRestApiCapability\((.*?)\)\.callTool\((.*?)\);',
        dotAll: true,
      ).allMatches(src).toList();

      expect(
        delegations,
        hasLength(7),
        reason: 'expected the seven delegating backend wrappers',
      );
      for (final match in delegations) {
        expect(
          match.group(2)!,
          contains('cancellation: cancellation'),
          reason: 'the inner call must receive the wrapper token:\n$match',
        );
      }
    });

    test('each delegating wrapper callTool accepts a cancellation token', () {
      final src = File(sourcePath).readAsStringSync();
      final wrappers = RegExp(
        r'Future<String> callTool\(\s*String toolName,\s*'
        r'Map<String, dynamic> args, \{\s*UtilityCancellation\? cancellation,',
        dotAll: true,
      ).allMatches(src);
      expect(
        wrappers.length,
        greaterThanOrEqualTo(7),
        reason: 'every concrete delegating wrapper must accept the token',
      );
    });
  });
}
