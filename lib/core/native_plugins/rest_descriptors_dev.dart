import 'package:http/http.dart' as http;
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/rest_engine.dart';

/// Dev-platform integrations batch (NP4 Task 4, spec §4.2): declarative
/// [RestServiceDescriptor]s for GitLab, Bitbucket, Jira, Trello, Linear,
/// Figma, Sentry, and Exa. Executed by [RestApiCapability] (plus the small
/// routing subclasses below); registered via [registerDevPlatforms()]
/// (wired into `registerAllNativePlugins`).
///
/// Body-shape convention (forced by the engine: one map arg per body):
/// scalar path/query args keep their spec names (`project_id`, `org`,
/// `file_key`, …); endpoints that need a JSON body take a single map arg
/// (`body`) whose shape is documented on the tool — the GraphQL tools
/// (Linear, Jira `search`) carry `{"query": "…", "variables": {…}}`, Jira
/// `create_issue` carries `{"fields": {…}}`, Figma `post_comment` carries
/// `{"message": "…"}`, Exa carries its `{"query": …, "numResults": …}` /
/// `{"ids": […], "text": …}` payloads. GitLab `create_issue` and Trello
/// `create_card` keep pure scalars because both APIs honestly accept the
/// parameters as URL query arguments on the create call.
///
/// Engine gaps closed by tiny routing capabilities (same file, no engine
/// changes):
/// * [GitLabCapability]/[JiraCapability] (via [_HostRoutedCapability]):
///   the `host` extra reroutes the base URL (scheme/path-tolerant, so a
///   pasted `https://…/` URL and a bare hostname both work). GitLab's host
///   is optional (empty = `gitlab.com`); Jira's is required (every tenant
///   has its own domain) and missing-host returns the usual
///   `Configure … first` message instead of sending anywhere.
/// * [BitbucketCapability]: bearer `Authorization: Bearer <token>` when a
///   token is configured, otherwise basic `username:app_password` (the
///   engine supports one auth kind per descriptor, hence the routing).
/// * [TrelloCapability]: the engine's [RestAuthKind.queryKey] carries one
///   param (`token`), so the non-secret `api_key` travels as an injected
///   `key` query arg on every tool (missing key = `Configure … first`).
const List<RestServiceDescriptor> devDescriptors = [
  RestServiceDescriptor(
    pluginName: 'GitLab MCP',
    baseUrl: 'https://gitlab.com/api/v4',
    auth: RestAuthKind.apiKeyHeader,
    authHeader: 'PRIVATE-TOKEN',
    credentialKey: 'token',
    credentialLabel: 'GitLab personal access token',
    extraConfig: [
      NativePluginConfigField(
        key: 'host',
        label: 'Self-hosted GitLab host (optional)',
        hint: 'Bare hostname or full URL of your self-hosted instance '
            '(e.g. git.example.com). Empty means gitlab.com.',
      ),
    ],
    tools: [
      RestToolDef(
        name: 'list_projects',
        description: 'List GitLab projects (optionally filtered by search).',
        method: 'GET',
        path: '/projects',
        inputSchema: {
          'type': 'object',
          'properties': {
            'search': {'type': 'string'},
          },
        },
        queryArgs: ['search'],
      ),
      RestToolDef(
        name: 'list_merge_requests',
        description: 'List merge requests of a project (state filter).',
        method: 'GET',
        path: '/projects/{project_id}/merge_requests',
        inputSchema: {
          'type': 'object',
          'properties': {
            'project_id': {'type': 'string'},
            'state': {'type': 'string'},
          },
          'required': ['project_id'],
        },
        queryArgs: ['state'],
        required: ['project_id'],
      ),
      RestToolDef(
        name: 'create_issue',
        description:
            'Create a project issue (title + description travel as request '
            'parameters, which GitLab accepts on this method).',
        method: 'POST',
        path: '/projects/{project_id}/issues',
        inputSchema: {
          'type': 'object',
          'properties': {
            'project_id': {'type': 'string'},
            'title': {'type': 'string'},
            'description': {'type': 'string'},
          },
          'required': ['project_id', 'title'],
        },
        queryArgs: ['title', 'description'],
        required: ['project_id', 'title'],
      ),
    ],
  ),
  // Canonical Bitbucket descriptor (bearer variant): the tools/paths shared
  // by both auth routes. [BitbucketCapability] picks this descriptor when a
  // token is configured, else the basic variant below.
  RestServiceDescriptor(
    pluginName: 'Bitbucket MCP',
    baseUrl: 'https://api.bitbucket.org/2.0',
    auth: RestAuthKind.bearerHeader,
    authHeader: 'Authorization',
    authPrefix: 'Bearer ',
    credentialKey: 'token',
    credentialLabel: 'Bitbucket API token',
    tools: _bitbucketTools,
  ),
  RestServiceDescriptor(
    pluginName: 'Jira MCP',
    baseUrl: 'https://{host}',
    auth: RestAuthKind.basic,
    authUsernameKey: 'email',
    credentialKey: 'api_token',
    credentialLabel: 'Jira API token',
    extraConfig: [
      NativePluginConfigField(
        key: 'host',
        label: 'Jira host',
        hint: 'Your Atlassian Cloud hostname, e.g. acme.atlassian.net '
            '(scheme optional).',
      ),
      NativePluginConfigField(
        key: 'email',
        label: 'Jira email',
        hint: 'The Atlassian account email (basic-auth username).',
      ),
    ],
    tools: [
      RestToolDef(
        name: 'search',
        description:
            'Search issues with JQL. body is the search JSON, e.g. '
            '{"jql": "project = PROJ", "maxResults": 20}.',
        method: 'POST',
        path: '/rest/api/3/search/jql',
        inputSchema: {
          'type': 'object',
          'properties': {
            'body': {'type': 'object'},
          },
          'required': ['body'],
        },
        jsonBodyArg: 'body',
        required: ['body'],
      ),
      RestToolDef(
        name: 'get_issue',
        description: 'Fetch one issue by key (e.g. PROJ-123).',
        method: 'GET',
        path: '/rest/api/3/issue/{key}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'key': {'type': 'string'},
          },
          'required': ['key'],
        },
        required: ['key'],
      ),
      RestToolDef(
        name: 'create_issue',
        description:
            'Create an issue. body is the Jira issue JSON, e.g. {"fields": '
            '{"project": {"key": "PROJ"}, "summary": "New bug", '
            '"issuetype": {"name": "Task"}}}.',
        method: 'POST',
        path: '/rest/api/3/issue',
        inputSchema: {
          'type': 'object',
          'properties': {
            'body': {'type': 'object'},
          },
          'required': ['body'],
        },
        jsonBodyArg: 'body',
        required: ['body'],
      ),
      RestToolDef(
        name: 'add_comment',
        description:
            'Comment on an issue. body is the comment JSON, e.g. '
            '{"body": "looks good"}.',
        method: 'POST',
        path: '/rest/api/3/issue/{key}/comment',
        inputSchema: {
          'type': 'object',
          'properties': {
            'key': {'type': 'string'},
            'body': {'type': 'object'},
          },
          'required': ['key', 'body'],
        },
        jsonBodyArg: 'body',
        required: ['key', 'body'],
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Trello MCP',
    baseUrl: 'https://api.trello.com/1',
    auth: RestAuthKind.queryKey,
    authQueryKey: 'token',
    credentialKey: 'api_token',
    credentialLabel: 'Trello API token',
    extraConfig: [
      NativePluginConfigField(
        key: 'api_key',
        label: 'Trello API key',
        hint: 'The public application key from trello.com/app-key '
            '(travels as the key query param).',
      ),
    ],
    tools: [
      RestToolDef(
        name: 'list_boards',
        description: 'List the boards of the token owner.',
        method: 'GET',
        path: '/members/me/boards',
        inputSchema: {'type': 'object'},
        queryArgs: ['key'],
      ),
      RestToolDef(
        name: 'list_lists',
        description: 'List the lists of a board.',
        method: 'GET',
        path: '/boards/{board_id}/lists',
        inputSchema: {
          'type': 'object',
          'properties': {
            'board_id': {'type': 'string'},
          },
          'required': ['board_id'],
        },
        queryArgs: ['key'],
        required: ['board_id'],
      ),
      RestToolDef(
        name: 'list_cards',
        description: 'List the cards of a list.',
        method: 'GET',
        path: '/lists/{list_id}/cards',
        inputSchema: {
          'type': 'object',
          'properties': {
            'list_id': {'type': 'string'},
          },
          'required': ['list_id'],
        },
        queryArgs: ['key'],
        required: ['list_id'],
      ),
      RestToolDef(
        name: 'create_card',
        description:
            'Create a card (idList + name + desc travel as request '
            'parameters, which Trello accepts on this method; idList is '
            'the target list id).',
        method: 'POST',
        path: '/cards',
        inputSchema: {
          'type': 'object',
          'properties': {
            'idList': {'type': 'string'},
            'name': {'type': 'string'},
            'desc': {'type': 'string'},
          },
          'required': ['idList', 'name'],
        },
        queryArgs: ['key', 'idList', 'name', 'desc'],
        required: ['idList', 'name'],
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Linear Sync',
    baseUrl: 'https://api.linear.app/graphql',
    auth: RestAuthKind.bearerHeader,
    authHeader: 'Authorization',
    credentialKey: 'api_key',
    credentialLabel: 'Linear API key',
    tools: [
      RestToolDef(
        name: 'list_issues',
        description:
            'List issues via GraphQL. body is the GraphQL JSON, e.g. '
            '{"query": "query { issues(first: 20) { nodes { id title } } }"}',
        method: 'POST',
        path: '',
        inputSchema: {
          'type': 'object',
          'properties': {
            'body': {'type': 'object'},
          },
          'required': ['body'],
        },
        jsonBodyArg: 'body',
        required: ['body'],
      ),
      RestToolDef(
        name: 'create_issue',
        description:
            'Create an issue via GraphQL. body is the GraphQL JSON, e.g. '
            '{"query": "mutation … issueCreate …", "variables": {"input": '
            '{"teamId": "T1", "title": "Bug"}}}.',
        method: 'POST',
        path: '',
        inputSchema: {
          'type': 'object',
          'properties': {
            'body': {'type': 'object'},
          },
          'required': ['body'],
        },
        jsonBodyArg: 'body',
        required: ['body'],
      ),
      RestToolDef(
        name: 'list_teams',
        description:
            'List teams via GraphQL. body is the GraphQL JSON, e.g. '
            '{"query": "query { teams { nodes { id name } } }"}',
        method: 'POST',
        path: '',
        inputSchema: {
          'type': 'object',
          'properties': {
            'body': {'type': 'object'},
          },
          'required': ['body'],
        },
        jsonBodyArg: 'body',
        required: ['body'],
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Figma Bridge',
    baseUrl: 'https://api.figma.com/v1',
    auth: RestAuthKind.apiKeyHeader,
    authHeader: 'X-Figma-Token',
    credentialKey: 'token',
    credentialLabel: 'Figma personal access token',
    tools: [
      RestToolDef(
        name: 'get_file',
        description: 'Fetch a Figma file by key.',
        method: 'GET',
        path: '/files/{file_key}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'file_key': {'type': 'string'},
          },
          'required': ['file_key'],
        },
        required: ['file_key'],
      ),
      RestToolDef(
        name: 'get_comments',
        description: 'List the comments of a Figma file.',
        method: 'GET',
        path: '/files/{file_key}/comments',
        inputSchema: {
          'type': 'object',
          'properties': {
            'file_key': {'type': 'string'},
          },
          'required': ['file_key'],
        },
        required: ['file_key'],
      ),
      RestToolDef(
        name: 'post_comment',
        description:
            'Comment on a Figma file. body is the comment JSON, e.g. '
            '{"message": "Nice work"}.',
        method: 'POST',
        path: '/files/{file_key}/comments',
        inputSchema: {
          'type': 'object',
          'properties': {
            'file_key': {'type': 'string'},
            'body': {'type': 'object'},
          },
          'required': ['file_key', 'body'],
        },
        jsonBodyArg: 'body',
        required: ['file_key', 'body'],
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Sentry Watch',
    baseUrl: 'https://sentry.io/api/0',
    auth: RestAuthKind.bearerHeader,
    authHeader: 'Authorization',
    authPrefix: 'Bearer ',
    credentialKey: 'auth_token',
    credentialLabel: 'Sentry auth token',
    tools: [
      RestToolDef(
        name: 'list_issues',
        description:
            'List the unresolved issues of an organization (project id '
            'filter).',
        method: 'GET',
        path: '/organizations/{org}/issues/',
        inputSchema: {
          'type': 'object',
          'properties': {
            'org': {'type': 'string'},
            'project': {'type': 'string'},
          },
          'required': ['org'],
        },
        queryArgs: ['project'],
        required: ['org'],
      ),
      RestToolDef(
        name: 'get_issue',
        description: 'Fetch one issue by id.',
        method: 'GET',
        path: '/issues/{id}/',
        inputSchema: {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
          },
          'required': ['id'],
        },
        required: ['id'],
      ),
      RestToolDef(
        name: 'latest_event',
        description: 'Fetch the newest event of an issue.',
        method: 'GET',
        path: '/issues/{issue_id}/events/latest/',
        inputSchema: {
          'type': 'object',
          'properties': {
            'issue_id': {'type': 'string'},
          },
          'required': ['issue_id'],
        },
        required: ['issue_id'],
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Exa Search MCP',
    baseUrl: 'https://api.exa.ai',
    auth: RestAuthKind.apiKeyHeader,
    authHeader: 'x-api-key',
    credentialKey: 'api_key',
    credentialLabel: 'Exa API key',
    tools: [
      RestToolDef(
        name: 'search',
        description:
            'Neural web search. body is the Exa search JSON, e.g. '
            '{"query": "flutter testing", "numResults": 5}.',
        method: 'POST',
        path: '/search',
        inputSchema: {
          'type': 'object',
          'properties': {
            'body': {'type': 'object'},
          },
          'required': ['body'],
        },
        jsonBodyArg: 'body',
        required: ['body'],
      ),
      RestToolDef(
        name: 'contents',
        description:
            'Fetch page contents. body is the Exa contents JSON, e.g. '
            '{"ids": ["https://example.com"], "text": true}.',
        method: 'POST',
        path: '/contents',
        inputSchema: {
          'type': 'object',
          'properties': {
            'body': {'type': 'object'},
          },
          'required': ['body'],
        },
        jsonBodyArg: 'body',
        required: ['body'],
      ),
    ],
  ),
];

/// Tools shared by both Bitbucket auth variants (same endpoints either way).
const List<RestToolDef> _bitbucketTools = [
  RestToolDef(
    name: 'list_repos',
    description: 'List the repositories of a workspace.',
    method: 'GET',
    path: '/repositories/{workspace}',
    inputSchema: {
      'type': 'object',
      'properties': {
        'workspace': {'type': 'string'},
      },
      'required': ['workspace'],
    },
    required: ['workspace'],
  ),
  RestToolDef(
    name: 'list_pullrequests',
    description: 'List the pull requests of a repository.',
    method: 'GET',
    path: '/repositories/{workspace}/{repo}/pullrequests',
    inputSchema: {
      'type': 'object',
      'properties': {
        'workspace': {'type': 'string'},
        'repo': {'type': 'string'},
      },
      'required': ['workspace', 'repo'],
    },
    required: ['workspace', 'repo'],
  ),
  RestToolDef(
    name: 'get_pullrequest',
    description: 'Fetch one pull request by id.',
    method: 'GET',
    path: '/repositories/{workspace}/{repo}/pullrequests/{id}',
    inputSchema: {
      'type': 'object',
      'properties': {
        'workspace': {'type': 'string'},
        'repo': {'type': 'string'},
        'id': {'type': 'string'},
      },
      'required': ['workspace', 'repo', 'id'],
    },
    required: ['workspace', 'repo', 'id'],
  ),
];

/// Bitbucket basic-auth variant (fallback when no bearer token is set).
const RestServiceDescriptor _bitbucketBasic = RestServiceDescriptor(
  pluginName: 'Bitbucket MCP',
  baseUrl: 'https://api.bitbucket.org/2.0',
  auth: RestAuthKind.basic,
  authUsernameKey: 'username',
  credentialKey: 'app_password',
  credentialLabel: 'Bitbucket app password',
  extraConfig: [
    NativePluginConfigField(
      key: 'username',
      label: 'Bitbucket username',
      hint: 'The Bitbucket account username (basic-auth username).',
    ),
  ],
  tools: _bitbucketTools,
);

/// Registers the dev-platforms batch: plain [RestApiCapability]s for
/// Linear, Figma, Sentry, and Exa plus the routing capabilities for
/// GitLab, Bitbucket, Jira, and Trello.
void registerDevPlatforms() {
  registerRestServices([
    for (final descriptor in devDescriptors)
      if (descriptor.pluginName == 'Linear Sync' ||
          descriptor.pluginName == 'Figma Bridge' ||
          descriptor.pluginName == 'Sentry Watch' ||
          descriptor.pluginName == 'Exa Search MCP')
        descriptor,
  ]);
  NativePluginRegistry.I.register(GitLabCapability());
  NativePluginRegistry.I.register(BitbucketCapability());
  NativePluginRegistry.I.register(JiraCapability());
  NativePluginRegistry.I.register(TrelloCapability());
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

/// Strips scheme, path, and surrounding whitespace from a pasted host value
/// so both `acme.atlassian.net` and `https://acme.atlassian.net/` route to
/// the same base URL. Returns `''` when nothing usable remains.
String _cleanHost(String raw) {
  var host = raw.trim().replaceFirst(
        RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'),
        '',
      );
  final slash = host.indexOf('/');
  if (slash >= 0) host = host.substring(0, slash);
  return host.trim();
}

/// Base for capabilities whose base URL follows a configured `host` extra:
/// [baseSuffix] is appended after the host (`/api/v4` for GitLab, `''` for
/// Jira). When [requireHost] is false an empty host keeps the descriptor's
/// default base (host is an override); when true an empty host returns the
/// usual `Configure … first` message and never sends a request.
abstract class _HostRoutedCapability extends RestApiCapability {
  _HostRoutedCapability(
    super.descriptor, {
    super.client,
    required this.baseSuffix,
    required this.requireHost,
  }) : _client = client;

  final http.Client? _client;
  final String baseSuffix;
  final bool requireHost;

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    final stored = await NativePluginConfigStore.I.readAll(
      pluginName: pluginName,
      fields: configFields,
    );
    final host = _cleanHost(stored['host'] ?? '');
    if (host.isEmpty) {
      if (!requireHost) {
        return RestApiCapability(
          descriptor,
          client: _client,
        ).callTool(toolName, args);
      }
      final label = configFields
          .firstWhere((field) => field.key == 'host')
          .label;
      return 'Configure $label first: open the Configure sheet for '
          '"$pluginName" and save "host".';
    }
    return RestApiCapability(
      _withBase(descriptor, 'https://$host$baseSuffix'),
      client: _client,
    ).callTool(toolName, args);
  }
}

/// GitLab MCP: `PRIVATE-TOKEN` auth against gitlab.com by default, rerouted
/// to `https://<host>/api/v4` when the optional host extra is set.
class GitLabCapability extends _HostRoutedCapability {
  GitLabCapability({super.client})
      : super(
          devDescriptors.firstWhere((d) => d.pluginName == 'GitLab MCP'),
          baseSuffix: '/api/v4',
          requireHost: false,
        );
}

/// Jira MCP: basic `email:api_token` auth against the required `host`
/// tenant (there is no default Jira base URL).
class JiraCapability extends _HostRoutedCapability {
  JiraCapability({super.client})
      : super(
          devDescriptors.firstWhere((d) => d.pluginName == 'Jira MCP'),
          baseSuffix: '',
          requireHost: true,
        );
}

/// Bitbucket MCP: bearer `Authorization: Bearer <token>` when a token is
/// configured, otherwise basic `username:app_password`.
class BitbucketCapability extends RestApiCapability {
  BitbucketCapability({super.client})
      : _client = client,
        super(
          devDescriptors.firstWhere((d) => d.pluginName == 'Bitbucket MCP'),
        );

  final http.Client? _client;

  @override
  List<NativePluginConfigField> get configFields => const [
        NativePluginConfigField(
          key: 'token',
          label: 'Bitbucket API token',
          secret: true,
        ),
        NativePluginConfigField(
          key: 'username',
          label: 'Bitbucket username',
          hint: 'The Bitbucket account username (basic-auth username).',
        ),
        NativePluginConfigField(
          key: 'app_password',
          label: 'Bitbucket app password',
          secret: true,
        ),
      ];

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    final stored = await NativePluginConfigStore.I.readAll(
      pluginName: pluginName,
      fields: configFields,
    );
    final token = (stored['token'] ?? '').trim();
    final delegate = token.isNotEmpty
        ? RestApiCapability(descriptor, client: _client)
        : RestApiCapability(_bitbucketBasic, client: _client);
    return delegate.callTool(toolName, args);
  }
}

/// Trello MCP: the engine's queryKey auth carries `token`; the non-secret
/// `api_key` is injected as the `key` query arg on every tool call.
class TrelloCapability extends RestApiCapability {
  TrelloCapability({super.client})
      : super(
          devDescriptors.firstWhere((d) => d.pluginName == 'Trello MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    final stored = await NativePluginConfigStore.I.readAll(
      pluginName: pluginName,
      fields: configFields,
    );
    final key = (stored['api_key'] ?? '').trim();
    if (key.isEmpty) {
      final label = configFields
          .firstWhere((field) => field.key == 'api_key')
          .label;
      return 'Configure $label first: open the Configure sheet for '
          '"$pluginName" and save "api_key".';
    }
    return super.callTool(toolName, {...args, 'key': key});
  }
}
