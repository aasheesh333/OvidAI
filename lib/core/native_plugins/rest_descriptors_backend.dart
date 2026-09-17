import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/rest_engine.dart';

/// Backend & data integrations batch (NP4 Task 5, spec §4.3): declarative
/// [RestServiceDescriptor]s for Firebase, Supabase, Airtable, Appwrite,
/// PocketBase, Vector DB (Pinecone), MongoDB (Atlas Data API), S3, Redis,
/// and Obsidian. Registered via [registerBackend()] (wired into
/// `registerAllNativePlugins`).
///
/// Body-shape convention (forced by the engine: one map arg per body):
/// scalar path/query args keep their spec names (`path`, `collection`,
/// `table`, …); endpoints that need a wrapped JSON body take scalar args
/// and the capability synthesizes the documented shape (`{"fields": …}`
/// for Firebase/Airtable, `{"vector": …, "topK": …}` for Vector query,
/// the Data-API envelope for MongoDB).
///
/// Engine gaps closed by tiny routing/synthesis capabilities (same file, no
/// engine changes):
/// * [_BackendCapability]: shared injected-client handling (production
///   lazily builds one real client, so registration never touches the HTTP
///   stack), stored-config reads, `Configure … first` messages, and
///   unknown-tool errors in the engine's exact wording.
/// * [FirebaseCapability]: nested document paths keep literal slashes. The
///   shared engine percent-encodes `{arg}` substitutions (known Task 1
///   limitation), which would corrupt Firestore resource names, so each
///   document call rewrites its path template to one placeholder per
///   segment and delegates the rest (auth/timeout/errors) to the engine.
/// * [SupabaseCapability]: reroutes the base to the configured `base_url`,
///   expands the `query` map into URL params (PostgREST passthrough), and
///   sends the same secret as both `apikey` and `Authorization: Bearer`
///   (the engine supports one auth kind — bearer — so a header-injecting
///   client adds the second). `update`/`delete` refuse an empty filter.
/// * [AirtableCapability]: wraps `fields_json` as `{"fields": …}`.
/// * [AppwriteCapability]: reroutes the base to the configured `endpoint`
///   and injects the non-secret `project_id` as `X-Appwrite-Project`.
/// * [PocketBaseCapability]: reroutes the base to `base_url` (page 1
///   default). The static user-pasted token travels as Bearer (spec §4.3).
/// * [VectorDbCapability]: reroutes the base to `index_host` (Pinecone) and
///   synthesizes the `/query` + `/fetch` bodies.
/// * [MongoDbCapability]: reroutes the base to `data_api_base`, requires
///   the `data_source` extra, and synthesizes the Data API envelopes.
///   Atlas Data API only — the self-hosted wire protocol is unsupported
///   (every tool description says so).
/// * [S3Capability]: custom SigV4 execution over [s3Authorization] (the
///   engine has no signing hook). Object keys keep literal slashes;
///   `presign_get` is pure signing (no network).
/// * [RedisCapability]: RESP execution over [RespClient] (one connection
///   per call, closed in `finally`). Unreachable servers return an honest
///   message instead of throwing.
/// * [ObsidianCapability]: file execution over [VaultFiles] against the
///   configured `vault_root` (root escapes stay [ArgumentError]).
const List<RestServiceDescriptor> backendDescriptors = [
  RestServiceDescriptor(
    pluginName: 'Firebase MCP',
    baseUrl: 'https://firestore.googleapis.com/v1',
    auth: RestAuthKind.queryKey,
    authQueryKey: 'key',
    credentialKey: 'api_key',
    credentialLabel: 'Firebase API key',
    extraConfig: [
      NativePluginConfigField(
        key: 'project_id',
        label: 'Firebase project ID',
        hint: 'The GCP project id owning the Firestore database.',
      ),
    ],
    tools: [
      RestToolDef(
        name: 'get_document',
        description:
            'Fetch one Firestore document by path, e.g. users/abc123 '
            '(Firestore only — Auth/Storage are out of scope).',
        method: 'GET',
        path: '/projects/{project_id}/databases/(default)/documents/{path}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
          'required': ['path'],
        },
        required: ['path'],
      ),
      RestToolDef(
        name: 'list_documents',
        description:
            'List the documents of a Firestore collection '
            '(Firestore only).',
        method: 'GET',
        path:
            '/projects/{project_id}/databases/(default)/documents/{collection}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'collection': {'type': 'string'},
          },
          'required': ['collection'],
        },
        required: ['collection'],
      ),
      RestToolDef(
        name: 'create_document',
        description:
            'Create a document in a collection. fields_json is the '
            'Firestore fields map, e.g. {"name": {"stringValue": "Ada"}} '
            '(Firestore only).',
        method: 'POST',
        path:
            '/projects/{project_id}/databases/(default)/documents/{collection}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'collection': {'type': 'string'},
            'fields_json': {'type': 'object'},
          },
          'required': ['collection', 'fields_json'],
        },
        jsonBodyArg: 'body',
        required: ['collection', 'fields_json'],
      ),
      RestToolDef(
        name: 'patch_document',
        description:
            'Update a Firestore document by path. fields_json is the '
            'Firestore fields map (Firestore only).',
        method: 'PATCH',
        path: '/projects/{project_id}/databases/(default)/documents/{path}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'fields_json': {'type': 'object'},
          },
          'required': ['path', 'fields_json'],
        },
        jsonBodyArg: 'body',
        required: ['path', 'fields_json'],
      ),
      RestToolDef(
        name: 'delete_document',
        description:
            'Delete a Firestore document by path (Firestore only).',
        method: 'DELETE',
        path: '/projects/{project_id}/databases/(default)/documents/{path}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
          'required': ['path'],
        },
        required: ['path'],
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Supabase MCP',
    baseUrl: '{base_url}',
    auth: RestAuthKind.bearerHeader,
    authHeader: 'Authorization',
    authPrefix: 'Bearer ',
    credentialKey: 'service_key',
    credentialLabel: 'Supabase service role key',
    extraConfig: [
      NativePluginConfigField(
        key: 'base_url',
        label: 'Supabase project URL',
        hint: 'The project REST URL, e.g. https://xyzcompany.supabase.co.',
      ),
    ],
    tools: [
      RestToolDef(
        name: 'select',
        description:
            'Select rows from a table. query is the PostgREST filter map '
            'passed through as URL params, e.g. {"select": "*", '
            '"status": "eq.done"}.',
        method: 'GET',
        path: '/rest/v1/{table}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'table': {'type': 'string'},
            'query': {'type': 'object'},
          },
          'required': ['table'],
        },
        required: ['table'],
      ),
      RestToolDef(
        name: 'insert',
        description:
            'Insert a row. row_json is the row object, e.g. '
            '{"task": "write tests"}.',
        method: 'POST',
        path: '/rest/v1/{table}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'table': {'type': 'string'},
            'row_json': {'type': 'object'},
          },
          'required': ['table', 'row_json'],
        },
        jsonBodyArg: 'row_json',
        required: ['table', 'row_json'],
      ),
      RestToolDef(
        name: 'update',
        description:
            'Update rows matching the query filter map. patch_json is the '
            'patch object. A non-empty query filter is required — '
            'unfiltered writes are refused.',
        method: 'PATCH',
        path: '/rest/v1/{table}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'table': {'type': 'string'},
            'query': {'type': 'object'},
            'patch_json': {'type': 'object'},
          },
          'required': ['table', 'query', 'patch_json'],
        },
        jsonBodyArg: 'patch_json',
        required: ['table', 'query', 'patch_json'],
      ),
      RestToolDef(
        name: 'delete',
        description:
            'Delete rows matching the query filter map. A non-empty query '
            'filter is required — unfiltered deletes are refused.',
        method: 'DELETE',
        path: '/rest/v1/{table}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'table': {'type': 'string'},
            'query': {'type': 'object'},
          },
          'required': ['table', 'query'],
        },
        required: ['table', 'query'],
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Airtable MCP',
    baseUrl: 'https://api.airtable.com/v0',
    auth: RestAuthKind.bearerHeader,
    authHeader: 'Authorization',
    authPrefix: 'Bearer ',
    credentialKey: 'token',
    credentialLabel: 'Airtable personal access token',
    tools: [
      RestToolDef(
        name: 'list_records',
        description: 'List the records of a table in a base.',
        method: 'GET',
        path: '/{base_id}/{table}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'base_id': {'type': 'string'},
            'table': {'type': 'string'},
          },
          'required': ['base_id', 'table'],
        },
        required: ['base_id', 'table'],
      ),
      RestToolDef(
        name: 'create_record',
        description:
            'Create a record. fields_json is the fields object, e.g. '
            '{"Name": "Write report"}.',
        method: 'POST',
        path: '/{base_id}/{table}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'base_id': {'type': 'string'},
            'table': {'type': 'string'},
            'fields_json': {'type': 'object'},
          },
          'required': ['base_id', 'table', 'fields_json'],
        },
        jsonBodyArg: 'body',
        required: ['base_id', 'table', 'fields_json'],
      ),
      RestToolDef(
        name: 'update_record',
        description:
            'Update a record. fields_json is the fields object.',
        method: 'PATCH',
        path: '/{base_id}/{table}/{record_id}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'base_id': {'type': 'string'},
            'table': {'type': 'string'},
            'record_id': {'type': 'string'},
            'fields_json': {'type': 'object'},
          },
          'required': ['base_id', 'table', 'record_id', 'fields_json'],
        },
        jsonBodyArg: 'body',
        required: ['base_id', 'table', 'record_id', 'fields_json'],
      ),
      RestToolDef(
        name: 'delete_record',
        description: 'Delete a record from a table.',
        method: 'DELETE',
        path: '/{base_id}/{table}/{record_id}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'base_id': {'type': 'string'},
            'table': {'type': 'string'},
            'record_id': {'type': 'string'},
          },
          'required': ['base_id', 'table', 'record_id'],
        },
        required: ['base_id', 'table', 'record_id'],
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Appwrite MCP',
    baseUrl: '{endpoint}',
    auth: RestAuthKind.apiKeyHeader,
    authHeader: 'X-Appwrite-Key',
    credentialKey: 'api_key',
    credentialLabel: 'Appwrite API key',
    extraConfig: [
      NativePluginConfigField(
        key: 'endpoint',
        label: 'Appwrite endpoint',
        hint: 'The API endpoint, e.g. https://cloud.appwrite.io/v1.',
      ),
      NativePluginConfigField(
        key: 'project_id',
        label: 'Appwrite project ID',
        hint: 'Sent as the X-Appwrite-Project header on every call.',
      ),
    ],
    tools: [
      RestToolDef(
        name: 'list_documents',
        description: 'List the documents of a collection.',
        method: 'GET',
        path: '/databases/{db_id}/collections/{collection_id}/documents',
        inputSchema: {
          'type': 'object',
          'properties': {
            'db_id': {'type': 'string'},
            'collection_id': {'type': 'string'},
          },
          'required': ['db_id', 'collection_id'],
        },
        required: ['db_id', 'collection_id'],
      ),
      RestToolDef(
        name: 'create_document',
        description:
            'Create a document. data_json is the document data, e.g. '
            '{"title": "Hello"}.',
        method: 'POST',
        path: '/databases/{db_id}/collections/{collection_id}/documents',
        inputSchema: {
          'type': 'object',
          'properties': {
            'db_id': {'type': 'string'},
            'collection_id': {'type': 'string'},
            'data_json': {'type': 'object'},
          },
          'required': ['db_id', 'collection_id', 'data_json'],
        },
        jsonBodyArg: 'data_json',
        required: ['db_id', 'collection_id', 'data_json'],
      ),
      RestToolDef(
        name: 'list_users',
        description: 'List the project users.',
        method: 'GET',
        path: '/users',
        inputSchema: {'type': 'object'},
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'PocketBase MCP',
    baseUrl: '{base_url}',
    auth: RestAuthKind.bearerHeader,
    authHeader: 'Authorization',
    authPrefix: 'Bearer ',
    credentialKey: 'token',
    credentialLabel: 'PocketBase token',
    extraConfig: [
      NativePluginConfigField(
        key: 'base_url',
        label: 'PocketBase base URL',
        hint: 'The instance URL, e.g. https://pb.example.com.',
      ),
    ],
    tools: [
      RestToolDef(
        name: 'list_records',
        description: 'List the records of a collection (paginated).',
        method: 'GET',
        path: '/api/collections/{collection}/records',
        inputSchema: {
          'type': 'object',
          'properties': {
            'collection': {'type': 'string'},
            'page': {'type': 'number'},
          },
          'required': ['collection'],
        },
        queryArgs: ['page'],
        required: ['collection'],
      ),
      RestToolDef(
        name: 'create_record',
        description:
            'Create a record. data_json is the record data, e.g. '
            '{"title": "Hi"}.',
        method: 'POST',
        path: '/api/collections/{collection}/records',
        inputSchema: {
          'type': 'object',
          'properties': {
            'collection': {'type': 'string'},
            'data_json': {'type': 'object'},
          },
          'required': ['collection', 'data_json'],
        },
        jsonBodyArg: 'data_json',
        required: ['collection', 'data_json'],
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Vector DB MCP',
    baseUrl: '{index_host}',
    auth: RestAuthKind.apiKeyHeader,
    authHeader: 'Api-Key',
    credentialKey: 'api_key',
    credentialLabel: 'Vector DB API key',
    extraConfig: [
      NativePluginConfigField(
        key: 'index_host',
        label: 'Vector DB index host',
        hint: 'The Pinecone index host URL, e.g. '
            'https://my-index.svc.pinecone.io.',
      ),
    ],
    tools: [
      RestToolDef(
        name: 'query',
        description:
            'Nearest-neighbor search (Pinecone). vector_json is the query '
            'vector array; top_k defaults to 5.',
        method: 'POST',
        path: '/query',
        inputSchema: {
          'type': 'object',
          'properties': {
            'vector_json': {'type': 'array'},
            'top_k': {'type': 'number'},
          },
          'required': ['vector_json'],
        },
        jsonBodyArg: 'body',
        required: ['vector_json'],
      ),
      RestToolDef(
        name: 'fetch',
        description:
            'Fetch vectors by id (Pinecone). ids is the id list.',
        method: 'POST',
        path: '/fetch',
        inputSchema: {
          'type': 'object',
          'properties': {
            'ids': {'type': 'array'},
          },
          'required': ['ids'],
        },
        jsonBodyArg: 'body',
        required: ['ids'],
      ),
      RestToolDef(
        name: 'stats',
        description: 'Describe index stats (Pinecone).',
        method: 'POST',
        path: '/describeIndexStats',
        inputSchema: {'type': 'object'},
        jsonBodyArg: 'body',
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'MongoDB MCP',
    baseUrl: '{data_api_base}',
    auth: RestAuthKind.apiKeyHeader,
    authHeader: 'api-key',
    credentialKey: 'api_key',
    credentialLabel: 'MongoDB Data API key',
    extraConfig: [
      NativePluginConfigField(
        key: 'data_api_base',
        label: 'MongoDB Data API base URL',
        hint: 'The Atlas Data API base, e.g. '
            'https://data.mongodb-api.com/app/…/endpoint/data/v1.',
      ),
      NativePluginConfigField(
        key: 'data_source',
        label: 'MongoDB data source',
        hint: 'The Atlas cluster name, e.g. Cluster0.',
      ),
    ],
    tools: [
      RestToolDef(
        name: 'find',
        description:
            'Find documents (Atlas Data API only — the self-hosted wire '
            'protocol is unsupported). filter_json is optional; limit '
            'defaults to 20.',
        method: 'POST',
        path: '/action/find',
        inputSchema: {
          'type': 'object',
          'properties': {
            'db': {'type': 'string'},
            'coll': {'type': 'string'},
            'filter_json': {'type': 'object'},
            'limit': {'type': 'number'},
          },
          'required': ['db', 'coll'],
        },
        jsonBodyArg: 'body',
        required: ['db', 'coll'],
      ),
      RestToolDef(
        name: 'find_one',
        description:
            'Find a single document (Atlas Data API only — the self-hosted '
            'wire protocol is unsupported).',
        method: 'POST',
        path: '/action/findOne',
        inputSchema: {
          'type': 'object',
          'properties': {
            'db': {'type': 'string'},
            'coll': {'type': 'string'},
            'filter_json': {'type': 'object'},
          },
          'required': ['db', 'coll'],
        },
        jsonBodyArg: 'body',
        required: ['db', 'coll'],
      ),
      RestToolDef(
        name: 'insert_one',
        description:
            'Insert a document. doc_json is the document (Atlas Data API '
            'only — the self-hosted wire protocol is unsupported).',
        method: 'POST',
        path: '/action/insertOne',
        inputSchema: {
          'type': 'object',
          'properties': {
            'db': {'type': 'string'},
            'coll': {'type': 'string'},
            'doc_json': {'type': 'object'},
          },
          'required': ['db', 'coll', 'doc_json'],
        },
        jsonBodyArg: 'body',
        required: ['db', 'coll', 'doc_json'],
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'S3 MCP',
    baseUrl: 'https://s3.{region}.amazonaws.com',
    auth: RestAuthKind.none,
    credentialKey: 'secret_access_key',
    credentialLabel: 'AWS secret access key',
    extraConfig: [
      NativePluginConfigField(
        key: 'access_key_id',
        label: 'AWS access key ID',
        hint: 'The public access key id (not a secret).',
      ),
      NativePluginConfigField(
        key: 'region',
        label: 'AWS region',
        hint: 'The bucket region, e.g. us-east-1.',
      ),
      NativePluginConfigField(
        key: 'bucket',
        label: 'S3 bucket',
        hint: 'The bucket name (virtual-hosted style requests).',
      ),
    ],
    tools: [
      RestToolDef(
        name: 'list_objects',
        description:
            'List objects in the bucket (SigV4-signed). prefix is optional.',
        method: 'GET',
        path: '/',
        inputSchema: {
          'type': 'object',
          'properties': {
            'prefix': {'type': 'string'},
            'timeout_seconds': {'type': 'number'},
          },
        },
      ),
      RestToolDef(
        name: 'get_object',
        description:
            'Fetch an object key (SigV4-signed). UTF-8 text under 6000 '
            'bytes is returned inline, otherwise metadata plus a '
            'presign_get hint.',
        method: 'GET',
        path: '/{key}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'key': {'type': 'string'},
            'timeout_seconds': {'type': 'number'},
          },
          'required': ['key'],
        },
        required: ['key'],
      ),
      RestToolDef(
        name: 'put_object',
        description: 'Write text to an object key (SigV4-signed).',
        method: 'PUT',
        path: '/{key}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'key': {'type': 'string'},
            'text': {'type': 'string'},
            'timeout_seconds': {'type': 'number'},
          },
          'required': ['key', 'text'],
        },
        required: ['key', 'text'],
      ),
      RestToolDef(
        name: 'delete_object',
        description: 'Delete an object key (SigV4-signed).',
        method: 'DELETE',
        path: '/{key}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'key': {'type': 'string'},
            'timeout_seconds': {'type': 'number'},
          },
          'required': ['key'],
        },
        required: ['key'],
      ),
      RestToolDef(
        name: 'presign_get',
        description:
            'Build a presigned GET URL for a key (pure SigV4 signing, no '
            'network). expires is seconds, default 3600 (max 604800).',
        method: 'GET',
        path: '/{key}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'key': {'type': 'string'},
            'expires': {'type': 'number'},
          },
          'required': ['key'],
        },
        required: ['key'],
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Redis MCP',
    baseUrl: 'redis://{host}:{port}',
    auth: RestAuthKind.none,
    extraConfig: [
      NativePluginConfigField(
        key: 'host',
        label: 'Redis host',
        hint: 'Defaults to localhost when empty.',
      ),
      NativePluginConfigField(
        key: 'port',
        label: 'Redis port',
        hint: 'Defaults to 6379 when empty.',
      ),
      NativePluginConfigField(
        key: 'password',
        label: 'Redis password',
        secret: true,
      ),
    ],
    tools: [
      RestToolDef(
        name: 'get',
        description: 'GET a key (missing keys answer (nil)).',
        method: 'GET',
        path: '/',
        inputSchema: {
          'type': 'object',
          'properties': {
            'key': {'type': 'string'},
            'timeout_seconds': {'type': 'number'},
          },
          'required': ['key'],
        },
        required: ['key'],
      ),
      RestToolDef(
        name: 'set',
        description: 'SET a key (ex_seconds adds an expiry).',
        method: 'GET',
        path: '/',
        inputSchema: {
          'type': 'object',
          'properties': {
            'key': {'type': 'string'},
            'value': {'type': 'string'},
            'ex_seconds': {'type': 'number'},
            'timeout_seconds': {'type': 'number'},
          },
          'required': ['key', 'value'],
        },
        required: ['key', 'value'],
      ),
      RestToolDef(
        name: 'del',
        description: 'DEL one or more keys (keys is a list).',
        method: 'GET',
        path: '/',
        inputSchema: {
          'type': 'object',
          'properties': {
            'keys': {'type': 'array'},
            'timeout_seconds': {'type': 'number'},
          },
          'required': ['keys'],
        },
        required: ['keys'],
      ),
      RestToolDef(
        name: 'keys',
        description: 'KEYS by pattern (use sparingly on large DBs).',
        method: 'GET',
        path: '/',
        inputSchema: {
          'type': 'object',
          'properties': {
            'pattern': {'type': 'string'},
            'timeout_seconds': {'type': 'number'},
          },
          'required': ['pattern'],
        },
        required: ['pattern'],
      ),
      RestToolDef(
        name: 'incr',
        description: 'INCR a counter key.',
        method: 'GET',
        path: '/',
        inputSchema: {
          'type': 'object',
          'properties': {
            'key': {'type': 'string'},
            'timeout_seconds': {'type': 'number'},
          },
          'required': ['key'],
        },
        required: ['key'],
      ),
      RestToolDef(
        name: 'expire',
        description: 'EXPIRE a key after seconds.',
        method: 'GET',
        path: '/',
        inputSchema: {
          'type': 'object',
          'properties': {
            'key': {'type': 'string'},
            'seconds': {'type': 'number'},
            'timeout_seconds': {'type': 'number'},
          },
          'required': ['key', 'seconds'],
        },
        required: ['key', 'seconds'],
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Obsidian MCP',
    baseUrl: 'file://{vault_root}',
    auth: RestAuthKind.none,
    extraConfig: [
      NativePluginConfigField(
        key: 'vault_root',
        label: 'Obsidian vault root',
        hint: 'The vault directory path (notes stay inside it).',
      ),
    ],
    tools: [
      RestToolDef(
        name: 'list_notes',
        description: 'List every Markdown note in the vault.',
        method: 'GET',
        path: '/',
        inputSchema: {'type': 'object'},
      ),
      RestToolDef(
        name: 'read_note',
        description: 'Read a vault note by vault-relative path.',
        method: 'GET',
        path: '/{path}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
          'required': ['path'],
        },
        required: ['path'],
      ),
      RestToolDef(
        name: 'write_note',
        description: 'Write (create or replace) a vault note.',
        method: 'GET',
        path: '/{path}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'text': {'type': 'string'},
          },
          'required': ['path', 'text'],
        },
        required: ['path', 'text'],
      ),
      RestToolDef(
        name: 'append_note',
        description: 'Append text to a vault note (created when missing).',
        method: 'GET',
        path: '/{path}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'text': {'type': 'string'},
          },
          'required': ['path', 'text'],
        },
        required: ['path', 'text'],
      ),
      RestToolDef(
        name: 'search_notes',
        description: 'Case-insensitive substring search over note bodies.',
        method: 'GET',
        path: '/',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {'type': 'string'},
          },
          'required': ['query'],
        },
        required: ['query'],
      ),
    ],
  ),
];

/// Registers the backend & data batch: the ten routing/synthesis
/// capabilities below (one per descriptor in [backendDescriptors]).
void registerBackend() {
  NativePluginRegistry.I.register(FirebaseCapability());
  NativePluginRegistry.I.register(SupabaseCapability());
  NativePluginRegistry.I.register(AirtableCapability());
  NativePluginRegistry.I.register(AppwriteCapability());
  NativePluginRegistry.I.register(PocketBaseCapability());
  NativePluginRegistry.I.register(VectorDbCapability());
  NativePluginRegistry.I.register(MongoDbCapability());
  NativePluginRegistry.I.register(S3Capability());
  NativePluginRegistry.I.register(RedisCapability());
  NativePluginRegistry.I.register(ObsidianCapability());
}

/// Shared base for the backend capabilities: injected-client handling
/// (production lazily builds one real client so registration never touches
/// the HTTP stack), stored-config reads, engine-worded `Configure … first`
/// messages, and engine-worded unknown-tool errors.
abstract class _BackendCapability extends RestApiCapability {
  _BackendCapability(super.descriptor, {super.client}) : _injected = client;

  final http.Client? _injected;
  http.Client? _lazyClient;

  http.Client _http() => _injected ?? (_lazyClient ??= http.Client());

  Future<Map<String, String>> _stored() =>
      NativePluginConfigStore.I.readAll(
        pluginName: pluginName,
        fields: configFields,
      );

  String _missingConfig(String key) {
    var label = key;
    for (final field in configFields) {
      if (field.key == key) label = field.label;
    }
    return 'Configure $label first: open the Configure sheet for '
        '"$pluginName" and save "$key".';
  }

  RestToolDef _toolDef(String toolName) {
    for (final tool in descriptor.tools) {
      if (tool.name == toolName) return tool;
    }
    throw ArgumentError(
      'Unknown tool: $toolName for plugin "$pluginName".',
    );
  }
}

/// Returns a copy of [source] pointed at [baseUrl] (used for host routing).
RestServiceDescriptor _withBase(
  RestServiceDescriptor source,
  String baseUrl,
) {
  return RestServiceDescriptor(
    pluginName: source.pluginName,
    baseUrl: baseUrl,
    auth: source.auth,
    authHeader: source.authHeader,
    authPrefix: source.authPrefix,
    authQueryKey: source.authQueryKey,
    authUsernameKey: source.authUsernameKey,
    credentialKey: source.credentialKey,
    credentialLabel: source.credentialLabel,
    extraConfig: source.extraConfig,
    tools: source.tools,
  );
}

/// Returns a copy of [source] with one tool's [path] and/or [queryArgs]
/// replaced (used for slash-preserving paths and query-map passthrough).
RestServiceDescriptor _withTool(
  RestServiceDescriptor source,
  String toolName, {
  String? path,
  List<String>? queryArgs,
}) {
  return RestServiceDescriptor(
    pluginName: source.pluginName,
    baseUrl: source.baseUrl,
    auth: source.auth,
    authHeader: source.authHeader,
    authPrefix: source.authPrefix,
    authQueryKey: source.authQueryKey,
    authUsernameKey: source.authUsernameKey,
    credentialKey: source.credentialKey,
    credentialLabel: source.credentialLabel,
    extraConfig: source.extraConfig,
    tools: [
      for (final tool in source.tools)
        if (tool.name != toolName)
          tool
        else
          RestToolDef(
            name: tool.name,
            description: tool.description,
            method: tool.method,
            path: path ?? tool.path,
            inputSchema: tool.inputSchema,
            queryArgs: queryArgs ?? tool.queryArgs,
            jsonBodyArg: tool.jsonBodyArg,
            formBodyArg: tool.formBodyArg,
            required: tool.required,
          ),
    ],
  );
}

/// Normalizes a user-pasted base URL (bare hostnames gain `https://`,
/// full URLs — including `http://localhost` — keep their scheme).
/// Returns `''` when nothing usable remains.
String _cleanBaseUrl(String raw) {
  var base = raw.trim();
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  if (base.isEmpty) return '';
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(base)) {
    base = 'https://$base';
  }
  return base;
}

/// Accepts a JSON object (or its JSON-encoded string) for [key].
Map<String, dynamic> _asJsonMap(dynamic raw, String key) {
  if (raw is Map) return Map<String, dynamic>.from(raw);
  if (raw is String) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on FormatException catch (e) {
      throw FormatException('Invalid $key JSON: ${e.message}');
    }
  }
  throw FormatException('Invalid $key: expected a JSON object.');
}

/// Tolerant integer parsing for LLM-supplied args ([num] or numeric
/// [String]); missing → [fallback]; anything else is [FormatException].
int _asInt(dynamic raw, String key, int fallback) {
  if (raw == null) return fallback;
  if (raw is int) return raw;
  if (raw is num) {
    if (!raw.isFinite) {
      throw FormatException('Invalid $key "$raw": expected a number.');
    }
    return raw.round();
  }
  final text = raw.toString().trim();
  if (text.isEmpty) return fallback;
  final parsed = int.tryParse(text) ?? double.tryParse(text)?.round();
  if (parsed == null) {
    throw FormatException('Invalid $key "$raw": expected a number.');
  }
  return parsed;
}

/// Accepts a string list (or a comma-separated / JSON-encoded string).
List<String> _asStringList(dynamic raw, String key) {
  if (raw is List) {
    return [for (final entry in raw) entry.toString()];
  }
  if (raw is String) {
    final text = raw.trim();
    if (text.startsWith('[')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is List) {
          return [for (final entry in decoded) entry.toString()];
        }
      } on FormatException catch (e) {
        throw FormatException('Invalid $key JSON: ${e.message}');
      }
      throw FormatException('Invalid $key: expected a list of ids.');
    }
    return text
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
  }
  throw FormatException('Invalid $key: expected a list of ids.');
}

/// A client wrapper that stamps extra headers (e.g. Supabase's second
/// `apikey` header, Appwrite's project header) onto every request before
/// delegating to the inner client (the engine supports one auth kind per
/// descriptor, hence the wrapper).
class _HeaderClient extends http.BaseClient {
  _HeaderClient(this._inner, this._extra);

  final http.Client _inner;
  final Map<String, String> _extra;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    for (final entry in _extra.entries) {
      request.headers[entry.key] = entry.value;
    }
    return _inner.send(request);
  }
}

/// Firebase MCP: Firestore over queryKey auth. Document paths keep literal
/// slashes (one placeholder per segment — the engine would percent-encode
/// them); create/patch wrap `fields_json` as `{"fields": …}`.
class FirebaseCapability extends _BackendCapability {
  FirebaseCapability({super.client})
      : super(
          backendDescriptors.firstWhere((d) => d.pluginName == 'Firebase MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    _toolDef(toolName);
    final stored = await _stored();
    final projectId = (stored['project_id'] ?? '').trim();
    if (projectId.isEmpty) return _missingConfig('project_id');
    var descriptor = this.descriptor;
    final newArgs = Map<String, dynamic>.from(args);
    if (toolName == 'create_document' || toolName == 'patch_document') {
      newArgs['body'] = {
        'fields': _asJsonMap(args['fields_json'], 'fields_json'),
      };
    }
    if (toolName == 'get_document' ||
        toolName == 'patch_document' ||
        toolName == 'delete_document') {
      final segments = (args['path']?.toString() ?? '')
          .split('/')
          .where((segment) => segment.isNotEmpty)
          .toList();
      if (segments.isEmpty) {
        throw ArgumentError('Missing required argument: path');
      }
      final placeholders = [
        for (var i = 0; i < segments.length; i++) '{fp$i}',
      ].join('/');
      descriptor = _withTool(
        descriptor,
        toolName,
        path: '/projects/{project_id}/databases/(default)/documents/'
            '$placeholders',
      );
      for (var i = 0; i < segments.length; i++) {
        newArgs['fp$i'] = segments[i];
      }
    }
    return RestApiCapability(descriptor, client: _http()).callTool(
      toolName,
      newArgs,
    );
  }
}

/// Supabase MCP: `base_url`-routed PostgREST over bearer auth, plus the same
/// secret as the `apikey` header. The `query` map passes through as URL
/// params; `update`/`delete` refuse an empty filter.
class SupabaseCapability extends _BackendCapability {
  SupabaseCapability({super.client})
      : super(
          backendDescriptors.firstWhere((d) => d.pluginName == 'Supabase MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    _toolDef(toolName);
    final stored = await _stored();
    final base = _cleanBaseUrl(stored['base_url'] ?? '');
    if (base.isEmpty) return _missingConfig('base_url');
    final secret = (stored['service_key'] ?? '').trim();
    var descriptor = _withBase(this.descriptor, base);
    final newArgs = Map<String, dynamic>.from(args);
    if (toolName == 'select' ||
        toolName == 'update' ||
        toolName == 'delete') {
      final expanded = <String>[];
      final query = args['query'];
      if (query is Map) {
        for (final entry in query.entries) {
          final key = entry.key.toString();
          if (key.isEmpty || newArgs.containsKey(key)) continue;
          final value = entry.value;
          if (value == null) continue;
          newArgs[key] = value is List
              ? value.map((item) => item.toString()).join(',')
              : value is Map
                  ? jsonEncode(value)
                  : value.toString();
          expanded.add(key);
        }
      }
      if ((toolName == 'update' || toolName == 'delete') &&
          expanded.isEmpty) {
        throw ArgumentError(
          'Tool "$toolName" requires a non-empty "query" filter map '
          '(unfiltered writes are refused).',
        );
      }
      if (expanded.isNotEmpty) {
        final current = descriptor.tools
            .firstWhere((tool) => tool.name == toolName)
            .queryArgs;
        descriptor = _withTool(
          descriptor,
          toolName,
          queryArgs: [...current, ...expanded],
        );
      }
    }
    final inner = _http();
    final client =
        secret.isEmpty ? inner : _HeaderClient(inner, {'apikey': secret});
    return RestApiCapability(descriptor, client: client).callTool(
      toolName,
      newArgs,
    );
  }
}

/// Airtable MCP: bearer auth against the fixed base; per-call `base_id`
/// travels in the path; create/update wrap `fields_json` as
/// `{"fields": …}`.
class AirtableCapability extends _BackendCapability {
  AirtableCapability({super.client})
      : super(
          backendDescriptors.firstWhere((d) => d.pluginName == 'Airtable MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    _toolDef(toolName);
    final newArgs = Map<String, dynamic>.from(args);
    if (toolName == 'create_record' || toolName == 'update_record') {
      newArgs['body'] = {
        'fields': _asJsonMap(args['fields_json'], 'fields_json'),
      };
    }
    return RestApiCapability(descriptor, client: _http()).callTool(
      toolName,
      newArgs,
    );
  }
}

/// Appwrite MCP: `endpoint`-routed, `X-Appwrite-Key` auth plus the
/// non-secret `project_id` as `X-Appwrite-Project` on every call.
class AppwriteCapability extends _BackendCapability {
  AppwriteCapability({super.client})
      : super(
          backendDescriptors.firstWhere((d) => d.pluginName == 'Appwrite MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    _toolDef(toolName);
    final stored = await _stored();
    final base = _cleanBaseUrl(stored['endpoint'] ?? '');
    if (base.isEmpty) return _missingConfig('endpoint');
    final projectId = (stored['project_id'] ?? '').trim();
    if (projectId.isEmpty) return _missingConfig('project_id');
    final descriptor = _withBase(this.descriptor, base);
    return RestApiCapability(
      descriptor,
      client: _HeaderClient(_http(), {'X-Appwrite-Project': projectId}),
    ).callTool(toolName, args);
  }
}

/// PocketBase MCP: `base_url`-routed collections API over the static
/// user-pasted bearer token.
class PocketBaseCapability extends _BackendCapability {
  PocketBaseCapability({super.client})
      : super(
          backendDescriptors.firstWhere(
              (d) => d.pluginName == 'PocketBase MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    _toolDef(toolName);
    final stored = await _stored();
    final base = _cleanBaseUrl(stored['base_url'] ?? '');
    if (base.isEmpty) return _missingConfig('base_url');
    final newArgs = Map<String, dynamic>.from(args);
    if (toolName == 'list_records') {
      newArgs.putIfAbsent('page', () => 1);
    }
    return RestApiCapability(
      _withBase(descriptor, base),
      client: _http(),
    ).callTool(toolName, newArgs);
  }
}

/// Vector DB MCP: Pinecone `index_host`-routed. `query` and `fetch`
/// synthesize their `{"vector": …, "topK": …}` / `{"ids": …}` bodies.
class VectorDbCapability extends _BackendCapability {
  VectorDbCapability({super.client})
      : super(
          backendDescriptors.firstWhere(
              (d) => d.pluginName == 'Vector DB MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    _toolDef(toolName);
    final stored = await _stored();
    final base = _cleanBaseUrl(stored['index_host'] ?? '');
    if (base.isEmpty) return _missingConfig('index_host');
    final newArgs = Map<String, dynamic>.from(args);
    if (toolName == 'query') {
      final rawVector = args['vector_json'];
      List<dynamic> vector;
      if (rawVector is List) {
        vector = rawVector;
      } else if (rawVector is String) {
        try {
          final decoded = jsonDecode(rawVector);
          if (decoded is! List) {
            throw FormatException(
              'Invalid vector_json: expected a number array.',
            );
          }
          vector = decoded;
        } on FormatException catch (e) {
          throw FormatException('Invalid vector_json JSON: ${e.message}');
        }
      } else {
        throw FormatException(
          'Invalid vector_json: expected a number array.',
        );
      }
      newArgs['body'] = {
        'vector': vector,
        'topK': _asInt(args['top_k'], 'top_k', 5),
      };
    } else if (toolName == 'fetch') {
      newArgs['body'] = {'ids': _asStringList(args['ids'], 'ids')};
    } else if (toolName == 'stats') {
      newArgs['body'] = <String, dynamic>{};
    }
    return RestApiCapability(
      _withBase(descriptor, base),
      client: _http(),
    ).callTool(toolName, newArgs);
  }
}

/// MongoDB MCP: Atlas Data API over the `api-key` header. Reroutes the base
/// to `data_api_base`, requires the `data_source` cluster extra, and
/// synthesizes the Data API envelopes from the scalar args.
class MongoDbCapability extends _BackendCapability {
  MongoDbCapability({super.client})
      : super(
          backendDescriptors.firstWhere((d) => d.pluginName == 'MongoDB MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    _toolDef(toolName);
    final stored = await _stored();
    final base = _cleanBaseUrl(stored['data_api_base'] ?? '');
    if (base.isEmpty) return _missingConfig('data_api_base');
    final dataSource = (stored['data_source'] ?? '').trim();
    if (dataSource.isEmpty) return _missingConfig('data_source');
    final newArgs = Map<String, dynamic>.from(args);
    final body = <String, dynamic>{
      'dataSource': dataSource,
      'database': args['db']?.toString() ?? '',
      'collection': args['coll']?.toString() ?? '',
    };
    if (toolName == 'find' || toolName == 'find_one') {
      final filter = args['filter_json'];
      if (filter != null &&
          !(filter is String && filter.trim().isEmpty)) {
        body['filter'] = _asJsonMap(filter, 'filter_json');
      }
      if (toolName == 'find') {
        body['limit'] = _asInt(args['limit'], 'limit', 20);
      }
    } else if (toolName == 'insert_one') {
      body['document'] = _asJsonMap(args['doc_json'], 'doc_json');
    }
    newArgs['body'] = body;
    return RestApiCapability(
      _withBase(descriptor, base),
      client: _http(),
    ).callTool(toolName, newArgs);
  }
}

/// S3 MCP: SigV4-signed requests over [s3Authorization] (the engine has no
/// signing hook, hence the custom execution — same timeout/verbatim/trim
/// conventions). Object keys keep literal slashes; `presign_get` is pure
/// signing and never touches the network.
class S3Capability extends _BackendCapability {
  S3Capability({super.client})
      : super(
          backendDescriptors.firstWhere((d) => d.pluginName == 'S3 MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    _toolDef(toolName);
    final stored = await _stored();
    final secret = (stored['secret_access_key'] ?? '').trim();
    if (secret.isEmpty) return _missingConfig('secret_access_key');
    final accessKeyId = (stored['access_key_id'] ?? '').trim();
    if (accessKeyId.isEmpty) return _missingConfig('access_key_id');
    final region = (stored['region'] ?? '').trim();
    if (region.isEmpty) return _missingConfig('region');
    final bucket = (stored['bucket'] ?? '').trim();
    if (bucket.isEmpty) return _missingConfig('bucket');

    if (toolName == 'presign_get') {
      final key = _requireKey(args);
      final expires = _clampExpires(_asInt(args['expires'], 'expires', 3600));
      return s3PresignedGetUrl(
        accessKeyId: accessKeyId,
        secretAccessKey: secret,
        region: region,
        bucket: bucket,
        key: key,
        expiresSeconds: expires,
        amzDate: DateTime.now().toUtc(),
      );
    }

    final timeoutSeconds = RestApiCapability.resolveTimeoutSeconds(args);
    if (toolName == 'list_objects') {
      final query = <String, String>{'list-type': '2'};
      final prefix = args['prefix']?.toString() ?? '';
      if (prefix.isNotEmpty) query['prefix'] = prefix;
      final response = await _s3Send(
        method: 'GET',
        key: '',
        query: query,
        accessKeyId: accessKeyId,
        secretAccessKey: secret,
        region: region,
        bucket: bucket,
        timeoutSeconds: timeoutSeconds,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return _trimOutput('HTTP ${response.statusCode}\n${response.body}');
      }
      return _trimOutput(response.body);
    }
    if (toolName == 'get_object') {
      final key = _requireKey(args);
      final response = await _s3Send(
        method: 'GET',
        key: key,
        accessKeyId: accessKeyId,
        secretAccessKey: secret,
        region: region,
        bucket: bucket,
        timeoutSeconds: timeoutSeconds,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return _trimOutput('HTTP ${response.statusCode}\n${response.body}');
      }
      final bytes = response.bodyBytes;
      String? text;
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        text = null;
      }
      if (text != null && bytes.length <= 6000) return text;
      final contentType = response.headers['content-type'] ?? 'unknown';
      return 'S3 object "$bucket/$key": ${bytes.length} bytes, '
          'content-type: $contentType. (Content is binary or exceeds 6000 '
          'bytes and is not inlined — call presign_get for a download URL.)';
    }
    if (toolName == 'put_object') {
      final key = _requireKey(args);
      final text = args['text']?.toString() ?? '';
      if (args['text'] == null || text.isEmpty) {
        throw ArgumentError('Missing required argument: text');
      }
      final bodyBytes = utf8.encode(text);
      final response = await _s3Send(
        method: 'PUT',
        key: key,
        bodyBytes: bodyBytes,
        contentType: 'text/plain; charset=utf-8',
        accessKeyId: accessKeyId,
        secretAccessKey: secret,
        region: region,
        bucket: bucket,
        timeoutSeconds: timeoutSeconds,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return _trimOutput('HTTP ${response.statusCode}\n${response.body}');
      }
      return 'Put ${bodyBytes.length} bytes to "$key" in bucket "$bucket".';
    }
    final key = _requireKey(args);
    final response = await _s3Send(
      method: 'DELETE',
      key: key,
      accessKeyId: accessKeyId,
      secretAccessKey: secret,
      region: region,
      bucket: bucket,
      timeoutSeconds: timeoutSeconds,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return _trimOutput('HTTP ${response.statusCode}\n${response.body}');
    }
    return 'Deleted "$key" from bucket "$bucket".';
  }

  String _requireKey(Map<String, dynamic> args) {
    final key = args['key']?.toString() ?? '';
    if (key.isEmpty) throw ArgumentError('Missing required argument: key');
    return key;
  }

  /// Sends one SigV4-signed S3 request and returns the raw response.
  Future<http.Response> _s3Send({
    required String method,
    required String key,
    Map<String, String> query = const {},
    List<int> bodyBytes = const [],
    String? contentType,
    required String accessKeyId,
    required String secretAccessKey,
    required String region,
    required String bucket,
    required int timeoutSeconds,
  }) async {
    final host = '$bucket.s3.$region.amazonaws.com';
    final rawPath = key.isEmpty ? '/' : '/$key';
    final encodedPath = key.isEmpty
        ? '/'
        : '/${key.split('/').map(_rfc3986Encode).join('/')}';
    final now = DateTime.now().toUtc();
    final amzDate = _amzDateStr(now);
    final payloadHash = sha256.convert(bodyBytes).toString();
    final authorization = s3Authorization(
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      region: region,
      method: method,
      canonicalUri: rawPath,
      queryParameters: query,
      headers: {'host': host, 'x-amz-date': amzDate},
      payloadHash: payloadHash,
      amzDate: now,
    );
    final sortedQuery = query.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final queryString = sortedQuery
        .map((e) => '${_rfc3986Encode(e.key)}=${_rfc3986Encode(e.value)}')
        .join('&');
    final uri = Uri.parse(
      'https://$host$encodedPath${queryString.isEmpty ? '' : '?$queryString'}',
    );
    final request = http.Request(method, uri);
    request.headers['x-amz-date'] = amzDate;
    request.headers['Authorization'] = authorization;
    if (contentType != null) request.headers['content-type'] = contentType;
    if (bodyBytes.isNotEmpty) request.bodyBytes = bodyBytes;
    try {
      final streamed = await _http().send(request).timeout(
            Duration(seconds: timeoutSeconds),
          );
      return await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw FormatException(
        'Request to $uri timed out after $timeoutSeconds seconds.',
      );
    } catch (e) {
      throw FormatException('HTTP request failed: $e');
    }
  }
}

/// Builds a presigned S3 GET URL (SigV4 query-string auth — pure signing,
/// no network). [amzDate] is the signing instant (callers pass "now";
/// tests pass a fixed date for determinism).
String s3PresignedGetUrl({
  required String accessKeyId,
  required String secretAccessKey,
  required String region,
  required String bucket,
  required String key,
  int expiresSeconds = 3600,
  required DateTime amzDate,
}) {
  final expires = _clampExpires(expiresSeconds);
  final utc = amzDate.toUtc();
  final dateStamp =
      '${utc.year}${_two(utc.month)}${_two(utc.day)}';
  final amzDateStr = '${dateStamp}T${_two(utc.hour)}${_two(utc.minute)}'
      '${_two(utc.second)}Z';
  final host = '$bucket.s3.$region.amazonaws.com';
  final encodedPath = '/${key.split('/').map(_rfc3986Encode).join('/')}';
  final scope = '$dateStamp/$region/s3/aws4_request';
  final query = {
    'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
    'X-Amz-Credential': '$accessKeyId/$scope',
    'X-Amz-Date': amzDateStr,
    'X-Amz-Expires': '$expires',
    'X-Amz-SignedHeaders': 'host',
  };
  final sorted = query.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  final canonicalQuery = sorted
      .map((e) => '${_rfc3986Encode(e.key)}=${_rfc3986Encode(e.value)}')
      .join('&');
  final canonicalRequest =
      'GET\n$encodedPath\n$canonicalQuery\nhost:$host\n\nhost\n'
      'UNSIGNED-PAYLOAD';
  final stringToSign = 'AWS4-HMAC-SHA256\n$amzDateStr\n$scope\n'
      '${sha256.convert(utf8.encode(canonicalRequest))}';
  List<int> signingKey = utf8.encode('AWS4$secretAccessKey');
  for (final data in [dateStamp, region, 's3', 'aws4_request']) {
    signingKey = Hmac(sha256, signingKey).convert(utf8.encode(data)).bytes;
  }
  final signature =
      Hmac(sha256, signingKey).convert(utf8.encode(stringToSign)).toString();
  return 'https://$host$encodedPath?$canonicalQuery'
      '&X-Amz-Signature=$signature';
}

/// Presigned URLs live 1s..7d per AWS (the capability clamps into range).
int _clampExpires(int seconds) => seconds.clamp(1, 604800);

String _two(int n) => n.toString().padLeft(2, '0');

String _amzDateStr(DateTime utc) {
  final u = utc.toUtc();
  return '${u.year}${_two(u.month)}${_two(u.day)}T${_two(u.hour)}'
      '${_two(u.minute)}${_two(u.second)}Z';
}

/// RFC 3986 percent-encoding for SigV4 URL building (parity with the
/// engine's private encoder: unreserved marks stay bare, everything else
/// becomes uppercase `%XX` over UTF-8 bytes). Local copy because the S3
/// capability must encode request URLs exactly the way [s3Authorization]
/// encodes the canonical request.
String _rfc3986Encode(String input) {
  final out = StringBuffer();
  for (final byte in utf8.encode(input)) {
    final unreserved = (byte >= 0x41 && byte <= 0x5A) || // A-Z
        (byte >= 0x61 && byte <= 0x7A) || // a-z
        (byte >= 0x30 && byte <= 0x39) || // 0-9
        byte == 0x2D || // -
        byte == 0x5F || // _
        byte == 0x2E || // .
        byte == 0x7E; // ~
    if (unreserved) {
      out.writeCharCode(byte);
    } else {
      out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

/// Inline cap for S3 tool results (parity with the engine's private trim:
/// head+tail at 6000 chars with the exact MCP omission notice).
String _trimOutput(String text) {
  const cap = 6000;
  if (text.length <= cap) return text;
  final head = text.substring(0, cap ~/ 2);
  final tail = text.substring(text.length - cap ~/ 2);
  final omitted = text.length - cap;
  return '$head\n\n[…$omitted characters omitted — ask again with a '
      'narrower query to see the middle…]\n\n$tail';
}

/// Redis MCP: RESP execution over [RespClient] (one connection per call,
/// closed in `finally`). No credentials are required — `host`/`port` fall
/// back to localhost/6379 and `password` is optional; unreachable servers
/// answer with an honest message instead of throwing.
class RedisCapability extends _BackendCapability {
  RedisCapability()
      : super(
          backendDescriptors.firstWhere((d) => d.pluginName == 'Redis MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    _toolDef(toolName);
    final timeoutSeconds = RestApiCapability.resolveTimeoutSeconds(args);
    final stored = await _stored();
    final rawHost = (stored['host'] ?? '').trim();
    final host = rawHost.isEmpty ? 'localhost' : rawHost;
    final port = _redisPort(stored['port']);
    final password = (stored['password'] ?? '').trim();
    final command = _redisCommand(toolName, args);
    final client = RespClient(
      host: host,
      port: port,
      password: password.isEmpty ? null : password,
      timeout: Duration(seconds: timeoutSeconds),
    );
    try {
      return _formatReply(await client.command(command));
    } on SocketException catch (e) {
      final detail = e.message.isEmpty ? e.toString() : e.message;
      return 'Redis at $host:$port is unreachable ($detail). Start the '
          'server or update "host"/"port" via Configure.';
    } on TimeoutException {
      return 'Redis command "$toolName" timed out after $timeoutSeconds '
          'seconds.';
    } on RespError catch (e) {
      return 'Redis error: ${e.message}';
    } finally {
      await client.close();
    }
  }

  int _redisPort(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return 6379;
    final port = int.tryParse(text);
    if (port == null || port <= 0 || port > 65535) {
      throw FormatException(
        'Invalid Redis port "$text": expected 1..65535.',
      );
    }
    return port;
  }

  List<String> _redisCommand(String toolName, Map<String, dynamic> args) {
    String requiredArg(String key) {
      final value = args[key]?.toString() ?? '';
      if (value.isEmpty) throw ArgumentError('Missing required argument: $key');
      return value;
    }

    switch (toolName) {
      case 'get':
        return ['GET', requiredArg('key')];
      case 'set':
        final command = ['SET', requiredArg('key'), requiredArg('value')];
        final ex = args['ex_seconds'];
        if (ex != null && ex.toString().trim().isNotEmpty) {
          command.addAll(['EX', '${_asInt(ex, 'ex_seconds', 0)}']);
        }
        return command;
      case 'del':
        final raw = args['keys'];
        final keys = raw is List
            ? raw
                .map((entry) => entry.toString())
                .where((entry) => entry.isNotEmpty)
                .toList()
            : [requiredArg('keys')];
        if (keys.isEmpty) throw ArgumentError('Missing required argument: keys');
        return ['DEL', ...keys];
      case 'keys':
        return ['KEYS', requiredArg('pattern')];
      case 'incr':
        return ['INCR', requiredArg('key')];
      case 'expire':
        final seconds = args['seconds'];
        if (seconds == null || seconds.toString().trim().isEmpty) {
          throw ArgumentError('Missing required argument: seconds');
        }
        return ['EXPIRE', requiredArg('key'), '${_asInt(seconds, 'seconds', 0)}'];
    }
    throw ArgumentError('Unknown tool: $toolName for plugin "$pluginName".');
  }

  String _formatReply(dynamic reply) {
    if (reply == null) return '(nil)';
    if (reply is List) {
      if (reply.isEmpty) return '(empty)';
      return reply.map((entry) => entry?.toString() ?? '(nil)').join('\n');
    }
    return reply.toString();
  }
}

/// Obsidian MCP: vault file execution over [VaultFiles] against the
/// configured `vault_root`. Root escapes and missing notes stay
/// [ArgumentError] (thrown, like the engine's unknown-tool errors).
class ObsidianCapability extends _BackendCapability {
  ObsidianCapability()
      : super(
          backendDescriptors.firstWhere((d) => d.pluginName == 'Obsidian MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    _toolDef(toolName);
    final stored = await _stored();
    final root = (stored['vault_root'] ?? '').trim();
    if (root.isEmpty) return _missingConfig('vault_root');
    final files = VaultFiles(root);
    try {
      switch (toolName) {
        case 'list_notes':
          final notes = await files.listNotes();
          if (notes.isEmpty) return '(no notes found)';
          return notes.join('\n');
        case 'read_note':
          return await files.readNote(_requirePath(args));
        case 'write_note':
          return await files.writeNote(
            _requirePath(args),
            args['text']?.toString() ?? '',
          );
        case 'append_note':
          return await files.appendNote(
            _requirePath(args),
            args['text']?.toString() ?? '',
          );
        case 'search_notes':
          final query = args['query']?.toString() ?? '';
          if (query.trim().isEmpty) {
            throw ArgumentError('Missing required argument: query');
          }
          final hits = await files.searchNotes(query);
          if (hits.isEmpty) return '(no matches)';
          return hits.join('\n');
      }
    } on FileSystemException catch (e) {
      return 'Obsidian vault error: ${e.message} '
          '(check "vault_root" via Configure).';
    }
    throw ArgumentError('Unknown tool: $toolName for plugin "$pluginName".');
  }

  String _requirePath(Map<String, dynamic> args) {
    final path = args['path']?.toString() ?? '';
    if (path.trim().isEmpty) {
      throw ArgumentError('Missing required argument: path');
    }
    return path;
  }
}
