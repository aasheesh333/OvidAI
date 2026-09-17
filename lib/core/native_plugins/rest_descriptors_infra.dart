import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/rest_engine.dart';

/// Deploy & infra integrations batch (NP4 Task 6, spec §4.4): declarative
/// [RestServiceDescriptor]s for Vercel MCP, Vercel Deploy, Railway MCP,
/// Heroku MCP, DigitalOcean MCP, Cloudflare MCP, Docker MCP, Kubernetes MCP,
/// Terraform MCP, Zapier MCP, and Make.com MCP.
///
/// Registered via [registerInfra()] (wired into `registerAllNativePlugins`).

const List<RestServiceDescriptor> infraDescriptors = [
  RestServiceDescriptor(
    pluginName: 'Vercel MCP',
    baseUrl: 'https://api.vercel.com',
    auth: RestAuthKind.bearerHeader,
    authPrefix: 'Bearer ',
    credentialKey: 'token',
    credentialLabel: 'Vercel token',
    tools: [
      RestToolDef(
        name: 'list_projects',
        description: 'List Vercel projects',
        method: 'GET',
        path: '/v9/projects',
        inputSchema: {'type': 'object', 'properties': {}},
      ),
      RestToolDef(
        name: 'list_deployments',
        description: 'List Vercel deployments',
        method: 'GET',
        path: '/v6/deployments',
        queryArgs: ['projectId', 'limit'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'project_id': {'type': 'string'},
            'limit': {'type': 'integer'},
          },
        },
      ),
      RestToolDef(
        name: 'get_deployment',
        description: 'Get one Vercel deployment by id',
        method: 'GET',
        path: '/v13/deployments/{id}',
        required: ['id'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
          },
          'required': ['id'],
        },
      ),
      RestToolDef(
        name: 'list_domains',
        description: 'List Vercel domains',
        method: 'GET',
        path: '/v5/domains',
        inputSchema: {'type': 'object', 'properties': {}},
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Vercel Deploy',
    baseUrl: 'https://api.vercel.com',
    auth: RestAuthKind.bearerHeader,
    authPrefix: 'Bearer ',
    credentialKey: 'token',
    credentialLabel: 'Vercel token',
    tools: [
      RestToolDef(
        name: 'list_deployments',
        description: 'List Vercel deployments',
        method: 'GET',
        path: '/v6/deployments',
        queryArgs: ['projectId', 'limit'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'project_id': {'type': 'string'},
            'limit': {'type': 'integer'},
          },
        },
      ),
      RestToolDef(
        name: 'get_deployment',
        description: 'Get one Vercel deployment by id',
        method: 'GET',
        path: '/v13/deployments/{id}',
        required: ['id'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
          },
          'required': ['id'],
        },
      ),
      RestToolDef(
        name: 'create_deployment',
        description: 'Trigger a new Vercel deployment from git repo',
        method: 'POST',
        path: '/v13/deployments',
        jsonBodyArg: 'body',
        inputSchema: {
          'type': 'object',
          'properties': {
            'project': {'type': 'string'},
            'git_repo': {'type': 'string'},
            'branch': {'type': 'string'},
          },
          'required': ['project', 'git_repo'],
        },
      ),
      RestToolDef(
        name: 'cancel_deployment',
        description: 'Cancel an in-progress Vercel deployment',
        method: 'DELETE',
        path: '/v13/deployments/{id}',
        required: ['id'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
          },
          'required': ['id'],
        },
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Railway MCP',
    baseUrl: 'https://backboard.railway.app/graphql/v2',
    auth: RestAuthKind.bearerHeader,
    authPrefix: 'Bearer ',
    credentialKey: 'token',
    credentialLabel: 'Railway API token',
    tools: [
      RestToolDef(
        name: 'list_projects',
        description: 'List Railway projects',
        method: 'POST',
        path: '',
        jsonBodyArg: 'body',
        inputSchema: {'type': 'object', 'properties': {}},
      ),
      RestToolDef(
        name: 'list_services',
        description: 'List Railway services for project',
        method: 'POST',
        path: '',
        jsonBodyArg: 'body',
        inputSchema: {
          'type': 'object',
          'properties': {
            'project_id': {'type': 'string'},
          },
          'required': ['project_id'],
        },
      ),
      RestToolDef(
        name: 'list_deployments',
        description: 'List Railway deployments for service',
        method: 'POST',
        path: '',
        jsonBodyArg: 'body',
        inputSchema: {
          'type': 'object',
          'properties': {
            'service_id': {'type': 'string'},
            'limit': {'type': 'integer'},
          },
          'required': ['service_id'],
        },
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Heroku MCP',
    baseUrl: 'https://api.heroku.com',
    auth: RestAuthKind.bearerHeader,
    authPrefix: 'Bearer ',
    credentialKey: 'token',
    credentialLabel: 'Heroku API token',
    tools: [
      RestToolDef(
        name: 'list_apps',
        description: 'List Heroku applications',
        method: 'GET',
        path: '/apps',
        inputSchema: {'type': 'object', 'properties': {}},
      ),
      RestToolDef(
        name: 'get_app',
        description: 'Get Heroku application details',
        method: 'GET',
        path: '/apps/{id}',
        required: ['id'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
          },
          'required': ['id'],
        },
      ),
      RestToolDef(
        name: 'list_dynos',
        description: 'List dynos for an app',
        method: 'GET',
        path: '/apps/{app_id}/dynos',
        required: ['app_id'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'app_id': {'type': 'string'},
          },
          'required': ['app_id'],
        },
      ),
      RestToolDef(
        name: 'restart_dynos',
        description: 'Restart dynos for an app',
        method: 'DELETE',
        path: '/apps/{app_id}/dynos',
        required: ['app_id'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'app_id': {'type': 'string'},
          },
          'required': ['app_id'],
        },
      ),
      RestToolDef(
        name: 'get_config',
        description: 'Get configuration variables for an app',
        method: 'GET',
        path: '/apps/{app_id}/config-vars',
        required: ['app_id'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'app_id': {'type': 'string'},
          },
          'required': ['app_id'],
        },
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'DigitalOcean MCP',
    baseUrl: 'https://api.digitalocean.com/v2',
    auth: RestAuthKind.bearerHeader,
    authPrefix: 'Bearer ',
    credentialKey: 'token',
    credentialLabel: 'DigitalOcean API token',
    tools: [
      RestToolDef(
        name: 'list_droplets',
        description: 'List DigitalOcean droplets',
        method: 'GET',
        path: '/droplets',
        inputSchema: {'type': 'object', 'properties': {}},
      ),
      RestToolDef(
        name: 'get_droplet',
        description: 'Get droplet details by id',
        method: 'GET',
        path: '/droplets/{id}',
        required: ['id'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
          },
          'required': ['id'],
        },
      ),
      RestToolDef(
        name: 'list_domains',
        description: 'List DigitalOcean domains',
        method: 'GET',
        path: '/domains',
        inputSchema: {'type': 'object', 'properties': {}},
      ),
      RestToolDef(
        name: 'list_domain_records',
        description: 'List records for domain',
        method: 'GET',
        path: '/domains/{domain}/records',
        required: ['domain'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'domain': {'type': 'string'},
          },
          'required': ['domain'],
        },
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Cloudflare MCP',
    baseUrl: 'https://api.cloudflare.com/client/v4',
    auth: RestAuthKind.bearerHeader,
    authPrefix: 'Bearer ',
    credentialKey: 'token',
    credentialLabel: 'Cloudflare API token',
    tools: [
      RestToolDef(
        name: 'list_zones',
        description: 'List Cloudflare zones',
        method: 'GET',
        path: '/zones',
        inputSchema: {'type': 'object', 'properties': {}},
      ),
      RestToolDef(
        name: 'list_dns',
        description: 'List DNS records for a zone',
        method: 'GET',
        path: '/zones/{zone_id}/dns_records',
        required: ['zone_id'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'zone_id': {'type': 'string'},
          },
          'required': ['zone_id'],
        },
      ),
      RestToolDef(
        name: 'create_dns',
        description: 'Create DNS record in a zone',
        method: 'POST',
        path: '/zones/{zone_id}/dns_records',
        jsonBodyArg: 'body',
        required: ['zone_id'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'zone_id': {'type': 'string'},
            'type': {'type': 'string'},
            'name': {'type': 'string'},
            'content': {'type': 'string'},
          },
          'required': ['zone_id', 'type', 'name', 'content'],
        },
      ),
      RestToolDef(
        name: 'delete_dns',
        description: 'Delete DNS record from a zone',
        method: 'DELETE',
        path: '/zones/{zone_id}/dns_records/{record_id}',
        required: ['zone_id', 'record_id'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'zone_id': {'type': 'string'},
            'record_id': {'type': 'string'},
          },
          'required': ['zone_id', 'record_id'],
        },
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Docker MCP',
    baseUrl: 'http://localhost:2375',
    auth: RestAuthKind.none,
    extraConfig: [
      NativePluginConfigField(
        key: 'docker_host',
        label: 'Docker host',
        hint: 'tcp://localhost:2375',
      ),
      NativePluginConfigField(
        key: 'api_version',
        label: 'API version',
        hint: 'v1.43',
      ),
    ],
    tools: [
      RestToolDef(
        name: 'list_containers',
        description: 'List containers from local/remote Docker daemon',
        method: 'GET',
        path: '/{api_version}/containers/json',
        queryArgs: ['all'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'all': {'type': 'boolean'},
          },
        },
      ),
      RestToolDef(
        name: 'list_images',
        description: 'List images from local/remote Docker daemon',
        method: 'GET',
        path: '/{api_version}/images/json',
        inputSchema: {'type': 'object', 'properties': {}},
      ),
      RestToolDef(
        name: 'inspect_container',
        description: 'Inspect container on Docker daemon',
        method: 'GET',
        path: '/{api_version}/containers/{id}/json',
        required: ['id'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
          },
          'required': ['id'],
        },
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Kubernetes MCP',
    baseUrl: '',
    auth: RestAuthKind.bearerHeader,
    authPrefix: 'Bearer ',
    credentialKey: 'bearer_token',
    credentialLabel: 'Kubernetes bearer token',
    extraConfig: [
      NativePluginConfigField(
        key: 'api_server',
        label: 'Kubernetes API server',
        hint: 'https://kubernetes:6443',
      ),
      NativePluginConfigField(
        key: 'namespace',
        label: 'Default namespace',
        hint: 'default',
      ),
    ],
    tools: [
      RestToolDef(
        name: 'list_pods',
        description: 'List pods in Kubernetes namespace (Bearer-token auth)',
        method: 'GET',
        path: '/api/v1/namespaces/{namespace}/pods',
        inputSchema: {'type': 'object', 'properties': {}},
      ),
      RestToolDef(
        name: 'get_pod',
        description: 'Get pod details by name in namespace',
        method: 'GET',
        path: '/api/v1/namespaces/{namespace}/pods/{name}',
        required: ['name'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
          },
          'required': ['name'],
        },
      ),
      RestToolDef(
        name: 'list_deployments',
        description: 'List deployments in namespace',
        method: 'GET',
        path: '/apis/apps/v1/namespaces/{namespace}/deployments',
        inputSchema: {'type': 'object', 'properties': {}},
      ),
      RestToolDef(
        name: 'list_services',
        description: 'List services in namespace',
        method: 'GET',
        path: '/api/v1/namespaces/{namespace}/services',
        inputSchema: {'type': 'object', 'properties': {}},
      ),
      RestToolDef(
        name: 'pod_logs',
        description: 'Get pod logs',
        method: 'GET',
        path: '/api/v1/namespaces/{namespace}/pods/{name}/log',
        required: ['name'],
        queryArgs: ['tailLines'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'tail': {'type': 'integer'},
          },
          'required': ['name'],
        },
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Terraform MCP',
    baseUrl: 'https://app.terraform.io/api/v2',
    auth: RestAuthKind.bearerHeader,
    authPrefix: 'Bearer ',
    credentialKey: 'token',
    credentialLabel: 'Terraform Cloud API token',
    tools: [
      RestToolDef(
        name: 'list_workspaces',
        description: 'List Terraform Cloud workspaces in organization',
        method: 'GET',
        path: '/organizations/{org}/workspaces',
        required: ['org'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'org': {'type': 'string'},
          },
          'required': ['org'],
        },
      ),
      RestToolDef(
        name: 'list_runs',
        description: 'List runs in a workspace',
        method: 'GET',
        path: '/workspaces/{workspace_id}/runs',
        required: ['workspace_id'],
        inputSchema: {
          'type': 'object',
          'properties': {
            'workspace_id': {'type': 'string'},
          },
          'required': ['workspace_id'],
        },
      ),
      RestToolDef(
        name: 'create_run',
        description: 'Create run in Terraform Cloud workspace',
        method: 'POST',
        path: '/workspaces/{workspace_id}/runs',
        required: ['workspace_id'],
        jsonBodyArg: 'body',
        inputSchema: {
          'type': 'object',
          'properties': {
            'workspace_id': {'type': 'string'},
            'message': {'type': 'string'},
            'auto_apply': {'type': 'boolean'},
          },
          'required': ['workspace_id'],
        },
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Zapier MCP',
    baseUrl: '',
    auth: RestAuthKind.none,
    credentialKey: 'webhook_url',
    credentialLabel: 'Zapier webhook URL',
    tools: [
      RestToolDef(
        name: 'trigger',
        description: 'Trigger Zapier webhook with JSON payload',
        method: 'POST',
        path: '',
        jsonBodyArg: 'payload_json',
        inputSchema: {
          'type': 'object',
          'properties': {
            'payload_json': {'type': 'object'},
          },
          'required': ['payload_json'],
        },
      ),
      RestToolDef(
        name: 'trigger_with_url',
        description: 'Trigger arbitrary webhook with URL and payload',
        method: 'POST',
        path: '',
        jsonBodyArg: 'payload_json',
        inputSchema: {
          'type': 'object',
          'properties': {
            'url': {'type': 'string'},
            'payload_json': {'type': 'object'},
          },
          'required': ['url', 'payload_json'],
        },
      ),
    ],
  ),
  RestServiceDescriptor(
    pluginName: 'Make.com MCP',
    baseUrl: 'https://eu1.make.com/api/v2',
    auth: RestAuthKind.bearerHeader,
    authPrefix: 'Token ',
    credentialKey: 'token',
    credentialLabel: 'Make API token',
    extraConfig: [
      NativePluginConfigField(
        key: 'zone_base',
        label: 'Zone API Base URL',
        hint: 'https://eu1.make.com/api/v2',
      ),
    ],
    tools: [
      RestToolDef(
        name: 'list_scenarios',
        description: 'List Make.com scenarios',
        method: 'GET',
        path: '/scenarios',
        inputSchema: {'type': 'object', 'properties': {}},
      ),
      RestToolDef(
        name: 'run_scenario',
        description: 'Run Make.com scenario',
        method: 'POST',
        path: '/scenarios/{id}/run',
        required: ['id'],
        jsonBodyArg: 'payload_json',
        inputSchema: {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
            'payload_json': {'type': 'object'},
          },
          'required': ['id'],
        },
      ),
    ],
  ),
];

abstract class _InfraCapability implements NativePluginCapability {
  final RestServiceDescriptor descriptor;
  final http.Client? _clientOverride;

  _InfraCapability(this.descriptor, {http.Client? client})
      : _clientOverride = client;

  @override
  String get pluginName => descriptor.pluginName;

  @override
  List<NativePluginConfigField> get configFields {
    final list = <NativePluginConfigField>[];
    if (descriptor.credentialKey.isNotEmpty) {
      list.add(
        NativePluginConfigField(
          key: descriptor.credentialKey,
          label: descriptor.credentialLabel,
          secret: true,
        ),
      );
    }
    list.addAll(descriptor.extraConfig);
    return list;
  }

  @override
  List<NativePluginTool> get tools => descriptor.tools
      .map(
        (t) => NativePluginTool(
          name: t.name,
          description: t.description,
          inputSchema: t.inputSchema,
        ),
      )
      .toList();

  @override
  Future<void> configure(Map<String, String> values) async {
    await NativePluginConfigStore.I.save(
      pluginName: pluginName,
      fields: configFields,
      values: values,
    );
  }

  Future<String?> readConfig(String key) async {
    final f = configFields.firstWhere(
      (c) => c.key == key,
      orElse: () => NativePluginConfigField(key: key, label: key),
    );
    return await NativePluginConfigStore.I.read(
      pluginName: pluginName,
      key: key,
      secret: f.secret,
    );
  }

  String missingCredError() {
    return 'Configure ${descriptor.credentialLabel} first: use catalog_configure_plugin '
        'or Settings -> Plugins -> $pluginName to save "${descriptor.credentialKey}".';
  }

  String missingConfigError(String label, String key) {
    return 'Configure $label first: use catalog_configure_plugin '
        'or Settings -> Plugins -> $pluginName to save "$key".';
  }
}

class VercelMcpCapability extends _InfraCapability {
  VercelMcpCapability({super.client})
      : super(
          infraDescriptors.firstWhere((d) => d.pluginName == 'Vercel MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    final token = await readConfig(descriptor.credentialKey);
    if (token == null || token.isEmpty) return missingCredError();

    final cleanArgs = Map<String, dynamic>.from(args);
    if (cleanArgs.containsKey('project_id')) {
      cleanArgs['projectId'] = cleanArgs.remove('project_id');
    }
    if (cleanArgs.containsKey('limit')) {
      cleanArgs['limit'] = cleanArgs['limit'].toString();
    }

    final cap = RestApiCapability(descriptor, client: _clientOverride);
    return await cap.callTool(toolName, cleanArgs);
  }
}

class VercelDeployCapability extends _InfraCapability {
  VercelDeployCapability({super.client})
      : super(
          infraDescriptors.firstWhere((d) => d.pluginName == 'Vercel Deploy'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    final token = await readConfig(descriptor.credentialKey);
    if (token == null || token.isEmpty) return missingCredError();

    final cleanArgs = Map<String, dynamic>.from(args);
    if (toolName == 'create_deployment') {
      final project = cleanArgs['project']?.toString();
      final gitRepo = cleanArgs['git_repo']?.toString();
      final branch = cleanArgs['branch']?.toString() ?? 'main';
      cleanArgs['body'] = {
        'name': project,
        'gitSource': {
          'type': 'github',
          'repo': gitRepo,
          'ref': branch,
        },
      };
    } else if (toolName == 'list_deployments') {
      if (cleanArgs.containsKey('project_id')) {
        cleanArgs['projectId'] = cleanArgs.remove('project_id');
      }
      if (cleanArgs.containsKey('limit')) {
        cleanArgs['limit'] = cleanArgs['limit'].toString();
      }
    }

    final cap = RestApiCapability(descriptor, client: _clientOverride);
    return await cap.callTool(toolName, cleanArgs);
  }
}

class RailwayCapability extends _InfraCapability {
  RailwayCapability({super.client})
      : super(
          infraDescriptors.firstWhere((d) => d.pluginName == 'Railway MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    final token = await readConfig(descriptor.credentialKey);
    if (token == null || token.isEmpty) return missingCredError();

    final cleanArgs = Map<String, dynamic>.from(args);
    if (toolName == 'list_projects') {
      cleanArgs['body'] = {
        'query': 'query { projects { edges { node { id name } } } }',
      };
    } else if (toolName == 'list_services') {
      final projId = cleanArgs['project_id']?.toString();
      cleanArgs['body'] = {
        'query':
            'query(\$projectId: String!) { project(id: \$projectId) { services { edges { node { id name } } } } }',
        'variables': {'projectId': projId},
      };
    } else if (toolName == 'list_deployments') {
      final svcId = cleanArgs['service_id']?.toString();
      final limit = (cleanArgs['limit'] as num?)?.toInt() ?? 10;
      cleanArgs['body'] = {
        'query':
            'query(\$serviceId: String!, \$first: Int) { service(id: \$serviceId) { deployments(first: \$first) { edges { node { id status } } } } }',
        'variables': {'serviceId': svcId, 'first': limit},
      };
    }

    final cap = RestApiCapability(descriptor, client: _clientOverride);
    return await cap.callTool(toolName, cleanArgs);
  }
}

class HerokuCapability extends _InfraCapability {
  HerokuCapability({super.client})
      : super(
          infraDescriptors.firstWhere((d) => d.pluginName == 'Heroku MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    final token = await readConfig(descriptor.credentialKey);
    if (token == null || token.isEmpty) return missingCredError();

    final client = _HeaderClient(_clientOverride ?? http.Client(), {
      'Accept': 'application/vnd.heroku+json; version=3',
    });
    final cap = RestApiCapability(descriptor, client: client);
    return await cap.callTool(toolName, args);
  }
}

class CloudflareCapability extends _InfraCapability {
  CloudflareCapability({super.client})
      : super(
          infraDescriptors.firstWhere((d) => d.pluginName == 'Cloudflare MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    final token = await readConfig(descriptor.credentialKey);
    if (token == null || token.isEmpty) return missingCredError();

    final cleanArgs = Map<String, dynamic>.from(args);
    if (toolName == 'create_dns') {
      cleanArgs['body'] = {
        'type': cleanArgs['type'],
        'name': cleanArgs['name'],
        'content': cleanArgs['content'],
      };
    }

    final cap = RestApiCapability(descriptor, client: _clientOverride);
    return await cap.callTool(toolName, cleanArgs);
  }
}

class DockerCapability extends _InfraCapability {
  DockerCapability({super.client})
      : super(
          infraDescriptors.firstWhere((d) => d.pluginName == 'Docker MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    final configuredHost = (await readConfig('docker_host'))?.trim();
    final apiVersion = (await readConfig('api_version'))?.trim() ?? 'v1.43';

    if (configuredHost != null && configuredHost.startsWith('unix://')) {
      return 'Unix-socket daemons are unsupported on this platform — configure a tcp:// host.';
    }

    String baseUrl = 'http://localhost:2375';
    if (configuredHost != null && configuredHost.isNotEmpty) {
      if (configuredHost.startsWith('tcp://')) {
        baseUrl = 'http://${configuredHost.substring(6)}';
      } else if (configuredHost.startsWith('http://') ||
          configuredHost.startsWith('https://')) {
        baseUrl = configuredHost;
      } else {
        baseUrl = 'http://$configuredHost';
      }
    }

    final cleanArgs = Map<String, dynamic>.from(args);
    cleanArgs['api_version'] = apiVersion.isNotEmpty ? apiVersion : 'v1.43';
    if (toolName == 'list_containers') {
      cleanArgs['all'] = (cleanArgs['all'] ?? true).toString();
    }

    final desc = RestServiceDescriptor(
      pluginName: descriptor.pluginName,
      baseUrl: baseUrl,
      auth: RestAuthKind.none,
      extraConfig: descriptor.extraConfig,
      tools: descriptor.tools,
    );

    try {
      final cap = RestApiCapability(desc, client: _clientOverride);
      return await cap.callTool(toolName, cleanArgs);
    } catch (e) {
      if (e is http.ClientException || e.toString().contains('Connection refused')) {
        final hostOnly = Uri.tryParse(baseUrl)?.host ?? 'localhost';
        return 'Docker daemon is unreachable on $hostOnly: ensure daemon is running and listening on TCP.';
      }
      rethrow;
    }
  }
}

class KubernetesCapability extends _InfraCapability {
  KubernetesCapability({super.client})
      : super(
          infraDescriptors.firstWhere((d) => d.pluginName == 'Kubernetes MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    final apiServer = (await readConfig('api_server'))?.trim();
    if (apiServer == null || apiServer.isEmpty) {
      return missingConfigError('Kubernetes API server', 'api_server');
    }

    final token = (await readConfig('bearer_token'))?.trim();
    if (token == null || token.isEmpty) {
      return missingCredError();
    }

    final configuredNs = (await readConfig('namespace'))?.trim();
    final ns = (configuredNs != null && configuredNs.isNotEmpty)
        ? configuredNs
        : 'default';

    final cleanArgs = Map<String, dynamic>.from(args);
    cleanArgs['namespace'] = ns;
    if (toolName == 'pod_logs') {
      if (cleanArgs.containsKey('tail')) {
        cleanArgs['tailLines'] = cleanArgs.remove('tail').toString();
      }
    }

    final desc = RestServiceDescriptor(
      pluginName: descriptor.pluginName,
      baseUrl: apiServer.endsWith('/')
          ? apiServer.substring(0, apiServer.length - 1)
          : apiServer,
      auth: RestAuthKind.bearerHeader,
      authPrefix: 'Bearer ',
      credentialKey: descriptor.credentialKey,
      credentialLabel: descriptor.credentialLabel,
      extraConfig: descriptor.extraConfig,
      tools: descriptor.tools,
    );

    final cap = RestApiCapability(desc, client: _clientOverride);
    return await cap.callTool(toolName, cleanArgs);
  }
}

class TerraformCapability extends _InfraCapability {
  TerraformCapability({super.client})
      : super(
          infraDescriptors.firstWhere((d) => d.pluginName == 'Terraform MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    final token = await readConfig(descriptor.credentialKey);
    if (token == null || token.isEmpty) return missingCredError();

    final cleanArgs = Map<String, dynamic>.from(args);
    if (toolName == 'create_run') {
      final wsId = cleanArgs['workspace_id']?.toString() ?? '';
      final msg = cleanArgs['message']?.toString();
      final autoApply = cleanArgs['auto_apply'] == true;
      final Map<String, dynamic> attrs = {'auto-apply': autoApply};
      if (msg != null) attrs['message'] = msg;
      cleanArgs['body'] = {
        'data': {
          'type': 'runs',
          'attributes': attrs,
          'relationships': {
            'workspace': {
              'data': {'type': 'workspaces', 'id': wsId},
            },
          },
        },
      };
    }

    final cap = RestApiCapability(descriptor, client: _clientOverride);
    return await cap.callTool(toolName, cleanArgs);
  }
}

class ZapierCapability extends _InfraCapability {
  ZapierCapability({super.client})
      : super(
          infraDescriptors.firstWhere((d) => d.pluginName == 'Zapier MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    if (toolName == 'trigger_with_url') {
      final url = args['url']?.toString() ?? '';
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        throw ArgumentError('URL must be http or https: $url');
      }
      final payload = _parsePayload(args['payload_json']);
      final client = _clientOverride ?? http.Client();
      final res = await client.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );
      return res.body;
    } else if (toolName == 'trigger') {
      final hookUrl = (await readConfig('webhook_url'))?.trim();
      if (hookUrl == null || hookUrl.isEmpty) {
        return missingCredError();
      }
      final payload = _parsePayload(args['payload_json']);
      final client = _clientOverride ?? http.Client();
      final res = await client.post(
        Uri.parse(hookUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );
      return res.body;
    }
    throw ArgumentError('Unknown tool: $toolName');
  }

  Map<String, dynamic> _parsePayload(dynamic p) {
    if (p == null) return {};
    if (p is Map) return Map<String, dynamic>.from(p);
    if (p is String) {
      try {
        final decoded = jsonDecode(p);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return {'payload': p};
  }
}

class MakeCapability extends _InfraCapability {
  MakeCapability({super.client})
      : super(
          infraDescriptors.firstWhere((d) => d.pluginName == 'Make.com MCP'),
        );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    final token = await readConfig(descriptor.credentialKey);
    if (token == null || token.isEmpty) return missingCredError();

    final configuredZone = (await readConfig('zone_base'))?.trim();
    final baseUrl = (configuredZone != null && configuredZone.isNotEmpty)
        ? (configuredZone.endsWith('/')
            ? configuredZone.substring(0, configuredZone.length - 1)
            : configuredZone)
        : descriptor.baseUrl;

    final cleanArgs = Map<String, dynamic>.from(args);
    if (toolName == 'run_scenario') {
      final p = cleanArgs['payload_json'];
      if (p is Map) {
        cleanArgs['payload_json'] = p;
      } else if (p is String && p.isNotEmpty) {
        try {
          cleanArgs['payload_json'] = jsonDecode(p);
        } catch (_) {
          cleanArgs['payload_json'] = {};
        }
      } else {
        cleanArgs['payload_json'] = {};
      }
    }

    final desc = RestServiceDescriptor(
      pluginName: descriptor.pluginName,
      baseUrl: baseUrl,
      auth: descriptor.auth,
      authPrefix: descriptor.authPrefix,
      credentialKey: descriptor.credentialKey,
      credentialLabel: descriptor.credentialLabel,
      extraConfig: descriptor.extraConfig,
      tools: descriptor.tools,
    );

    final cap = RestApiCapability(desc, client: _clientOverride);
    return await cap.callTool(toolName, cleanArgs);
  }
}

class _HeaderClient extends http.BaseClient {
  final http.Client _inner;
  final Map<String, String> _headers;

  _HeaderClient(this._inner, this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _inner.send(request);
  }
}

void registerInfra() {
  final registry = NativePluginRegistry.I;
  registry.register(VercelMcpCapability());
  registry.register(VercelDeployCapability());
  registry.register(RailwayCapability());
  registry.register(HerokuCapability());
  registry.register(RestApiCapability(
    infraDescriptors.firstWhere((d) => d.pluginName == 'DigitalOcean MCP'),
  ));
  registry.register(CloudflareCapability());
  registry.register(DockerCapability());
  registry.register(KubernetesCapability());
  registry.register(TerraformCapability());
  registry.register(ZapierCapability());
  registry.register(MakeCapability());
}
