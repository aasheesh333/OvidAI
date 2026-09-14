import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

import 'github_service.dart';
import 'mcp_service.dart' hide McpRpcResult;

/// Result of an in-process MCP tool invocation.
class McpRpcResult {
  final dynamic value;
  final String? error;
  final bool isTimeout;

  const McpRpcResult.ok(this.value)
      : error = null,
        isTimeout = false;

  const McpRpcResult.error(String e)
      : value = null,
        error = e,
        isTimeout = false;

  const McpRpcResult.timeout()
      : value = null,
        error = null,
        isTimeout = true;

  bool get isError => error != null;
}

/// Interface for in-process pure-Dart MCP handlers.
abstract class NativeMcpHandler {
  Future<Map<String, dynamic>> initialize(Map<String, dynamic> params);
  Future<List<McpToolDef>> listTools();
  Future<McpRpcResult> callTool(String toolName, Map<String, dynamic> args);
  Future<void> dispose();
}

/// In-process GitHub MCP handler backed by the GitHub REST API.
class NativeGitHubMcpHandler implements NativeMcpHandler {
  final String? token;
  final String? Function()? tokenProvider;
  final http.Client? httpClient;

  http.Client get _client => httpClient ?? http.Client();

  NativeGitHubMcpHandler({
    this.token,
    this.tokenProvider,
    this.httpClient,
  });

  String? _resolveToken() {
    if (token != null && token!.trim().isNotEmpty) return token!.trim();
    if (tokenProvider != null) {
      final t = tokenProvider!();
      if (t != null && t.trim().isNotEmpty) return t.trim();
    }
    try {
      final t = GitHubService.I.token;
      if (t != null && t.trim().isNotEmpty) return t.trim();
    } catch (_) {}
    return null;
  }

  @override
  Future<Map<String, dynamic>> initialize(Map<String, dynamic> params) async {
    return {
      'protocolVersion': '2024-11-05',
      'capabilities': {'tools': {}},
      'serverInfo': {'name': 'github', 'version': '1.0.0'},
    };
  }

  @override
  Future<List<McpToolDef>> listTools() async {
    return [
      McpToolDef(
        name: 'search_repositories',
        description: 'Search for GitHub repositories by query.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': 'The search query.'},
            'per_page': {'type': 'integer', 'description': 'Results per page (default: 30).'},
            'page': {'type': 'integer', 'description': 'Page number.'},
          },
          'required': ['query'],
        },
      ),
      McpToolDef(
        name: 'get_file_contents',
        description: 'Get contents of a file or directory in a repository.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'owner': {'type': 'string', 'description': 'Repository owner.'},
            'repo': {'type': 'string', 'description': 'Repository name.'},
            'path': {'type': 'string', 'description': 'File path within the repository.'},
            'ref': {'type': 'string', 'description': 'Branch, tag, or commit ref.'},
          },
          'required': ['owner', 'repo', 'path'],
        },
      ),
      McpToolDef(
        name: 'create_or_update_file',
        description: 'Create or update a file in a repository.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'owner': {'type': 'string', 'description': 'Repository owner.'},
            'repo': {'type': 'string', 'description': 'Repository name.'},
            'path': {'type': 'string', 'description': 'File path within repository.'},
            'content': {'type': 'string', 'description': 'File content.'},
            'message': {'type': 'string', 'description': 'Commit message.'},
            'branch': {'type': 'string', 'description': 'Branch to commit to.'},
            'sha': {'type': 'string', 'description': 'Blob SHA if updating an existing file.'},
          },
          'required': ['owner', 'repo', 'path', 'content', 'message'],
        },
      ),
      McpToolDef(
        name: 'create_issue',
        description: 'Create an issue in a repository.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'owner': {'type': 'string', 'description': 'Repository owner.'},
            'repo': {'type': 'string', 'description': 'Repository name.'},
            'title': {'type': 'string', 'description': 'Issue title.'},
            'body': {'type': 'string', 'description': 'Issue body markdown.'},
            'labels': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'List of label names.',
            },
            'assignees': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'List of GitHub usernames.',
            },
          },
          'required': ['owner', 'repo', 'title'],
        },
      ),
      McpToolDef(
        name: 'list_issues',
        description: 'List issues in a repository.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'owner': {'type': 'string', 'description': 'Repository owner.'},
            'repo': {'type': 'string', 'description': 'Repository name.'},
            'state': {'type': 'string', 'enum': ['open', 'closed', 'all']},
            'per_page': {'type': 'integer'},
            'page': {'type': 'integer'},
          },
          'required': ['owner', 'repo'],
        },
      ),
      McpToolDef(
        name: 'get_issue',
        description: 'Get details of a specific issue.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'owner': {'type': 'string', 'description': 'Repository owner.'},
            'repo': {'type': 'string', 'description': 'Repository name.'},
            'issue_number': {'type': 'integer', 'description': 'Issue number.'},
          },
          'required': ['owner', 'repo', 'issue_number'],
        },
      ),
      McpToolDef(
        name: 'add_issue_comment',
        description: 'Add a comment to an existing issue.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'owner': {'type': 'string', 'description': 'Repository owner.'},
            'repo': {'type': 'string', 'description': 'Repository name.'},
            'issue_number': {'type': 'integer', 'description': 'Issue number.'},
            'body': {'type': 'string', 'description': 'Comment body.'},
          },
          'required': ['owner', 'repo', 'issue_number', 'body'],
        },
      ),
      McpToolDef(
        name: 'create_pull_request',
        description: 'Create a new pull request.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'owner': {'type': 'string', 'description': 'Repository owner.'},
            'repo': {'type': 'string', 'description': 'Repository name.'},
            'title': {'type': 'string', 'description': 'PR title.'},
            'head': {'type': 'string', 'description': 'Branch with changes.'},
            'base': {'type': 'string', 'description': 'Target branch to merge into.'},
            'body': {'type': 'string', 'description': 'PR body markdown.'},
          },
          'required': ['owner', 'repo', 'title', 'head', 'base'],
        },
      ),
      McpToolDef(
        name: 'list_pull_requests',
        description: 'List pull requests in a repository.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'owner': {'type': 'string', 'description': 'Repository owner.'},
            'repo': {'type': 'string', 'description': 'Repository name.'},
            'state': {'type': 'string', 'enum': ['open', 'closed', 'all']},
            'per_page': {'type': 'integer'},
            'page': {'type': 'integer'},
          },
          'required': ['owner', 'repo'],
        },
      ),
      McpToolDef(
        name: 'fork_repository',
        description: 'Fork a repository.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'owner': {'type': 'string', 'description': 'Repository owner.'},
            'repo': {'type': 'string', 'description': 'Repository name.'},
            'organization': {'type': 'string', 'description': 'Optional target organization.'},
          },
          'required': ['owner', 'repo'],
        },
      ),
      McpToolDef(
        name: 'list_commits',
        description: 'List commits in a repository.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'owner': {'type': 'string', 'description': 'Repository owner.'},
            'repo': {'type': 'string', 'description': 'Repository name.'},
            'page': {'type': 'integer'},
            'per_page': {'type': 'integer'},
          },
          'required': ['owner', 'repo'],
        },
      ),
      McpToolDef(
        name: 'get_user',
        description: 'Get profile information for a GitHub user.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'username': {'type': 'string', 'description': 'GitHub username (optional, defaults to authenticated user).'},
          },
        },
      ),
    ];
  }

  Map<String, String> _headers(String token) => {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'OvidAI/1.0',
        'Authorization': 'Bearer $token',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  McpRpcResult _toolResult(dynamic data, {bool isError = false}) {
    final text = data is String ? data : jsonEncode(data);
    return McpRpcResult.ok({
      'content': [
        {'type': 'text', 'text': text}
      ],
      'isError': isError,
    });
  }

  @override
  Future<McpRpcResult> callTool(String toolName, Map<String, dynamic> args) async {
    final authToken = _resolveToken();
    if (authToken == null) {
      return const McpRpcResult.error(
        'Please log in to GitHub or set GITHUB_TOKEN to use GitHub tools.',
      );
    }

    final headers = _headers(authToken);
    final client = _client;

    try {
      switch (toolName) {
        case 'search_repositories': {
          final q = Uri.encodeComponent(args['query'] as String? ?? '');
          final perPage = args['per_page'] ?? 30;
          final page = args['page'] ?? 1;
          final url = Uri.parse('https://api.github.com/search/repositories?q=$q&per_page=$perPage&page=$page');
          final res = await client.get(url, headers: headers);
          if (res.statusCode >= 200 && res.statusCode < 300) {
            return _toolResult(res.body);
          }
          return _toolResult('GitHub API error (${res.statusCode}): ${res.body}', isError: true);
        }

        case 'get_file_contents': {
          final owner = args['owner'] as String?;
          final repo = args['repo'] as String?;
          final path = args['path'] as String?;
          final ref = args['ref'] as String?;
          if (owner == null || repo == null || path == null) {
            return const McpRpcResult.error('Missing required arguments: owner, repo, path');
          }
          var uriStr = 'https://api.github.com/repos/$owner/$repo/contents/$path';
          if (ref != null && ref.isNotEmpty) {
            uriStr += '?ref=${Uri.encodeComponent(ref)}';
          }
          final res = await client.get(Uri.parse(uriStr), headers: headers);
          if (res.statusCode >= 200 && res.statusCode < 300) {
            final json = jsonDecode(res.body);
            if (json is Map<String, dynamic> && json['encoding'] == 'base64' && json['content'] is String) {
              final rawBase64 = (json['content'] as String).replaceAll('\n', '');
              try {
                final decoded = utf8.decode(base64Decode(rawBase64));
                return _toolResult(decoded);
              } catch (_) {
                return _toolResult(res.body);
              }
            }
            return _toolResult(res.body);
          }
          return _toolResult('GitHub API error (${res.statusCode}): ${res.body}', isError: true);
        }

        case 'create_or_update_file': {
          final owner = args['owner'] as String?;
          final repo = args['repo'] as String?;
          final path = args['path'] as String?;
          final content = args['content'] as String?;
          final message = args['message'] as String?;
          final branch = args['branch'] as String?;
          final sha = args['sha'] as String?;
          if (owner == null || repo == null || path == null || content == null || message == null) {
            return const McpRpcResult.error('Missing required arguments');
          }
          final url = Uri.parse('https://api.github.com/repos/$owner/$repo/contents/$path');
          final bodyMap = <String, dynamic>{
            'message': message,
            'content': base64Encode(utf8.encode(content)),
          };
          if (branch != null) bodyMap['branch'] = branch;
          if (sha != null) bodyMap['sha'] = sha;
          final res = await client.put(url, headers: headers, body: jsonEncode(bodyMap));
          if (res.statusCode >= 200 && res.statusCode < 300) {
            return _toolResult(res.body);
          }
          return _toolResult('GitHub API error (${res.statusCode}): ${res.body}', isError: true);
        }

        case 'create_issue': {
          final owner = args['owner'] as String?;
          final repo = args['repo'] as String?;
          final title = args['title'] as String?;
          final body = args['body'] as String?;
          final labels = args['labels'] as List?;
          final assignees = args['assignees'] as List?;
          if (owner == null || repo == null || title == null) {
            return const McpRpcResult.error('Missing required arguments: owner, repo, title');
          }
          final url = Uri.parse('https://api.github.com/repos/$owner/$repo/issues');
          final bodyMap = <String, dynamic>{'title': title};
          if (body != null) bodyMap['body'] = body;
          if (labels != null) bodyMap['labels'] = labels;
          if (assignees != null) bodyMap['assignees'] = assignees;
          final res = await client.post(url, headers: headers, body: jsonEncode(bodyMap));
          if (res.statusCode >= 200 && res.statusCode < 300) {
            return _toolResult(res.body);
          }
          return _toolResult('GitHub API error (${res.statusCode}): ${res.body}', isError: true);
        }

        case 'list_issues': {
          final owner = args['owner'] as String?;
          final repo = args['repo'] as String?;
          final state = args['state'] as String? ?? 'open';
          final perPage = args['per_page'] ?? 30;
          final page = args['page'] ?? 1;
          if (owner == null || repo == null) {
            return const McpRpcResult.error('Missing required arguments: owner, repo');
          }
          final url = Uri.parse('https://api.github.com/repos/$owner/$repo/issues?state=$state&per_page=$perPage&page=$page');
          final res = await client.get(url, headers: headers);
          if (res.statusCode >= 200 && res.statusCode < 300) {
            return _toolResult(res.body);
          }
          return _toolResult('GitHub API error (${res.statusCode}): ${res.body}', isError: true);
        }

        case 'get_issue': {
          final owner = args['owner'] as String?;
          final repo = args['repo'] as String?;
          final issueNum = args['issue_number'];
          if (owner == null || repo == null || issueNum == null) {
            return const McpRpcResult.error('Missing required arguments: owner, repo, issue_number');
          }
          final url = Uri.parse('https://api.github.com/repos/$owner/$repo/issues/$issueNum');
          final res = await client.get(url, headers: headers);
          if (res.statusCode >= 200 && res.statusCode < 300) {
            return _toolResult(res.body);
          }
          return _toolResult('GitHub API error (${res.statusCode}): ${res.body}', isError: true);
        }

        case 'add_issue_comment': {
          final owner = args['owner'] as String?;
          final repo = args['repo'] as String?;
          final issueNum = args['issue_number'];
          final body = args['body'] as String?;
          if (owner == null || repo == null || issueNum == null || body == null) {
            return const McpRpcResult.error('Missing required arguments');
          }
          final url = Uri.parse('https://api.github.com/repos/$owner/$repo/issues/$issueNum/comments');
          final res = await client.post(url, headers: headers, body: jsonEncode({'body': body}));
          if (res.statusCode >= 200 && res.statusCode < 300) {
            return _toolResult(res.body);
          }
          return _toolResult('GitHub API error (${res.statusCode}): ${res.body}', isError: true);
        }

        case 'create_pull_request': {
          final owner = args['owner'] as String?;
          final repo = args['repo'] as String?;
          final title = args['title'] as String?;
          final head = args['head'] as String?;
          final base = args['base'] as String?;
          final body = args['body'] as String?;
          if (owner == null || repo == null || title == null || head == null || base == null) {
            return const McpRpcResult.error('Missing required arguments: owner, repo, title, head, base');
          }
          final url = Uri.parse('https://api.github.com/repos/$owner/$repo/pulls');
          final bodyMap = <String, dynamic>{
            'title': title,
            'head': head,
            'base': base,
          };
          if (body != null) bodyMap['body'] = body;
          final res = await client.post(url, headers: headers, body: jsonEncode(bodyMap));
          if (res.statusCode >= 200 && res.statusCode < 300) {
            return _toolResult(res.body);
          }
          return _toolResult('GitHub API error (${res.statusCode}): ${res.body}', isError: true);
        }

        case 'list_pull_requests': {
          final owner = args['owner'] as String?;
          final repo = args['repo'] as String?;
          final state = args['state'] as String? ?? 'open';
          final perPage = args['per_page'] ?? 30;
          final page = args['page'] ?? 1;
          if (owner == null || repo == null) {
            return const McpRpcResult.error('Missing required arguments: owner, repo');
          }
          final url = Uri.parse('https://api.github.com/repos/$owner/$repo/pulls?state=$state&per_page=$perPage&page=$page');
          final res = await client.get(url, headers: headers);
          if (res.statusCode >= 200 && res.statusCode < 300) {
            return _toolResult(res.body);
          }
          return _toolResult('GitHub API error (${res.statusCode}): ${res.body}', isError: true);
        }

        case 'fork_repository': {
          final owner = args['owner'] as String?;
          final repo = args['repo'] as String?;
          final org = args['organization'] as String?;
          if (owner == null || repo == null) {
            return const McpRpcResult.error('Missing required arguments: owner, repo');
          }
          final url = Uri.parse('https://api.github.com/repos/$owner/$repo/forks');
          final bodyMap = <String, dynamic>{};
          if (org != null) bodyMap['organization'] = org;
          final res = await client.post(url, headers: headers, body: jsonEncode(bodyMap));
          if (res.statusCode >= 200 && res.statusCode < 300) {
            return _toolResult(res.body);
          }
          return _toolResult('GitHub API error (${res.statusCode}): ${res.body}', isError: true);
        }

        case 'list_commits': {
          final owner = args['owner'] as String?;
          final repo = args['repo'] as String?;
          final page = args['page'] ?? 1;
          final perPage = args['per_page'] ?? 30;
          if (owner == null || repo == null) {
            return const McpRpcResult.error('Missing required arguments: owner, repo');
          }
          final url = Uri.parse('https://api.github.com/repos/$owner/$repo/commits?page=$page&per_page=$perPage');
          final res = await client.get(url, headers: headers);
          if (res.statusCode >= 200 && res.statusCode < 300) {
            return _toolResult(res.body);
          }
          return _toolResult('GitHub API error (${res.statusCode}): ${res.body}', isError: true);
        }

        case 'get_user': {
          final username = args['username'] as String?;
          final url = (username != null && username.isNotEmpty)
              ? Uri.parse('https://api.github.com/users/$username')
              : Uri.parse('https://api.github.com/user');
          final res = await client.get(url, headers: headers);
          if (res.statusCode >= 200 && res.statusCode < 300) {
            return _toolResult(res.body);
          }
          return _toolResult('GitHub API error (${res.statusCode}): ${res.body}', isError: true);
        }

        default:
          return McpRpcResult.error('Unknown tool "$toolName" for github MCP');
      }
    } catch (e) {
      return McpRpcResult.error('GitHub request failed: $e');
    }
  }

  @override
  Future<void> dispose() async {
    if (httpClient != null) {
      httpClient!.close();
    }
  }
}

/// In-process Filesystem MCP handler operating on local files.
class NativeFilesystemMcpHandler implements NativeMcpHandler {
  final String rootPath;

  NativeFilesystemMcpHandler({String? rootPath})
      : rootPath = _canonicalize(rootPath ?? Directory.current.path);

  static String _canonicalize(String path) {
    return File(path).absolute.resolveSymbolicLinksSync();
  }

  static bool _isAbsolute(String path) {
    return path.startsWith('/') || RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path);
  }

  static String _join(String part1, String part2) {
    if (part1.endsWith('/')) return '$part1$part2';
    return '$part1/$part2';
  }

  static String _basename(String path) {
    final clean = path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
    final idx = clean.lastIndexOf('/');
    return idx >= 0 ? clean.substring(idx + 1) : clean;
  }

  static String _relative(String full, {required String from}) {
    final cleanFrom = from.endsWith('/') ? from : '$from/';
    if (full.startsWith(cleanFrom)) {
      return full.substring(cleanFrom.length);
    }
    if (full == from) return '.';
    return full;
  }

  @override
  Future<Map<String, dynamic>> initialize(Map<String, dynamic> params) async {
    return {
      'protocolVersion': '2024-11-05',
      'capabilities': {'tools': {}},
      'serverInfo': {'name': 'filesystem', 'version': '1.0.0'},
    };
  }

  @override
  Future<List<McpToolDef>> listTools() async {
    return [
      McpToolDef(
        name: 'read_file',
        description: 'Read the contents of a file.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': 'Path to the file.'},
          },
          'required': ['path'],
        },
      ),
      McpToolDef(
        name: 'write_file',
        description: 'Create or overwrite a file with given contents.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': 'Path to the file.'},
            'content': {'type': 'string', 'description': 'Content to write.'},
          },
          'required': ['path', 'content'],
        },
      ),
      McpToolDef(
        name: 'list_directory',
        description: 'List contents of a directory.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': 'Path to directory (default: root).'},
          },
        },
      ),
      McpToolDef(
        name: 'get_file_info',
        description: 'Get file or directory metadata (size, modified time, etc.).',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': 'Path to file or directory.'},
          },
          'required': ['path'],
        },
      ),
      McpToolDef(
        name: 'search_files',
        description: 'Recursively search for files matching a pattern.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': 'Starting path (default: root).'},
            'pattern': {'type': 'string', 'description': 'Filename search pattern or substring.'},
          },
          'required': ['pattern'],
        },
      ),
      McpToolDef(
        name: 'delete_file',
        description: 'Delete a file or directory.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': 'Path to delete.'},
          },
          'required': ['path'],
        },
      ),
    ];
  }

  static String _normalizePath(String path) {
    final parts = path.split(RegExp(r'[/\\]+'));
    final result = <String>[];
    for (final part in parts) {
      if (part == '' || part == '.') continue;
      if (part == '..') {
        if (result.isNotEmpty) {
          result.removeLast();
        }
      } else {
        result.add(part);
      }
    }
    final prefix = path.startsWith('/') ? '/' : '';
    return prefix + result.join('/');
  }

  String? _resolveSafe(String targetPath) {
    try {
      final joined = _isAbsolute(targetPath)
          ? targetPath
          : _join(rootPath, targetPath);

      final normalized = _normalizePath(File(joined).absolute.path);

      // Check if candidate exists to resolve symlinks
      final exists = FileSystemEntity.typeSync(normalized) != FileSystemEntityType.notFound;
      final candidate = exists ? File(normalized).resolveSymbolicLinksSync() : normalized;

      final rootWithSlash = rootPath.endsWith('/') ? rootPath : '$rootPath/';
      if (candidate == rootPath || candidate.startsWith(rootWithSlash)) {
        return candidate;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  McpRpcResult _toolResult(dynamic data, {bool isError = false}) {
    final text = data is String ? data : jsonEncode(data);
    return McpRpcResult.ok({
      'content': [
        {'type': 'text', 'text': text}
      ],
      'isError': isError,
    });
  }

  @override
  Future<McpRpcResult> callTool(String toolName, Map<String, dynamic> args) async {
    try {
      switch (toolName) {
        case 'read_file': {
          final relPath = args['path'] as String?;
          if (relPath == null) return const McpRpcResult.error('Missing path');
          final safe = _resolveSafe(relPath);
          if (safe == null) {
            return McpRpcResult.error('Access denied: path "$relPath" is outside allowed root "$rootPath"');
          }
          final file = File(safe);
          if (!await file.exists()) {
            return McpRpcResult.error('File not found: $relPath');
          }
          final content = await file.readAsString();
          return _toolResult(content);
        }

        case 'write_file': {
          final relPath = args['path'] as String?;
          final content = args['content'] as String?;
          if (relPath == null || content == null) {
            return const McpRpcResult.error('Missing path or content');
          }
          final safe = _resolveSafe(relPath);
          if (safe == null) {
            return McpRpcResult.error('Access denied: path "$relPath" is outside allowed root "$rootPath"');
          }
          final file = File(safe);
          await file.parent.create(recursive: true);
          await file.writeAsString(content);
          return _toolResult('File written successfully to $relPath');
        }

        case 'list_directory': {
          final relPath = args['path'] as String? ?? '.';
          final safe = _resolveSafe(relPath);
          if (safe == null) {
            return McpRpcResult.error('Access denied: path "$relPath" is outside allowed root "$rootPath"');
          }
          final dir = Directory(safe);
          if (!await dir.exists()) {
            return McpRpcResult.error('Directory not found: $relPath');
          }
          final list = <Map<String, dynamic>>[];
          await for (final entity in dir.list(followLinks: false)) {
            final stat = await entity.stat();
            list.add({
              'name': _basename(entity.path),
              'path': _relative(entity.path, from: rootPath),
              'isDirectory': entity is Directory,
              'size': stat.size,
              'modified': stat.modified.toIso8601String(),
            });
          }
          return _toolResult(list);
        }

        case 'get_file_info': {
          final relPath = args['path'] as String?;
          if (relPath == null) return const McpRpcResult.error('Missing path');
          final safe = _resolveSafe(relPath);
          if (safe == null) {
            return McpRpcResult.error('Access denied: path "$relPath" is outside allowed root "$rootPath"');
          }
          final stat = await FileStat.stat(safe);
          if (stat.type == FileSystemEntityType.notFound) {
            return McpRpcResult.error('Not found: $relPath');
          }
          return _toolResult({
            'path': relPath,
            'size': stat.size,
            'modified': stat.modified.toIso8601String(),
            'isDirectory': stat.type == FileSystemEntityType.directory,
            'isFile': stat.type == FileSystemEntityType.file,
            'mode': stat.modeString(),
          });
        }

        case 'search_files': {
          final relPath = args['path'] as String? ?? '.';
          final pattern = args['pattern'] as String?;
          if (pattern == null || pattern.isEmpty) {
            return const McpRpcResult.error('Missing search pattern');
          }
          final safe = _resolveSafe(relPath);
          if (safe == null) {
            return McpRpcResult.error('Access denied: path "$relPath" is outside allowed root "$rootPath"');
          }
          final dir = Directory(safe);
          if (!await dir.exists()) {
            return McpRpcResult.error('Directory not found: $relPath');
          }
          final regExp = RegExp(RegExp.escape(pattern), caseSensitive: false);
          final matches = <String>[];
          await for (final entity in dir.list(recursive: true, followLinks: false)) {
            final rel = _relative(entity.path, from: rootPath);
            if (regExp.hasMatch(_basename(entity.path)) || regExp.hasMatch(rel)) {
              matches.add(rel);
            }
          }
          return _toolResult(matches);
        }

        case 'delete_file': {
          final relPath = args['path'] as String?;
          if (relPath == null) return const McpRpcResult.error('Missing path');
          final safe = _resolveSafe(relPath);
          if (safe == null) {
            return McpRpcResult.error('Access denied: path "$relPath" is outside allowed root "$rootPath"');
          }
          final file = File(safe);
          if (await file.exists()) {
            await file.delete();
            return _toolResult('Deleted file: $relPath');
          }
          final dir = Directory(safe);
          if (await dir.exists()) {
            await dir.delete(recursive: true);
            return _toolResult('Deleted directory: $relPath');
          }
          return McpRpcResult.error('File or directory does not exist: $relPath');
        }

        default:
          return McpRpcResult.error('Unknown tool "$toolName" for filesystem MCP');
      }
    } catch (e) {
      return McpRpcResult.error('Filesystem error: $e');
    }
  }

  @override
  Future<void> dispose() async {}
}

/// In-process Fetch MCP handler for retrieving and converting web content.
class NativeFetchMcpHandler implements NativeMcpHandler {
  final http.Client? httpClient;

  http.Client get _client => httpClient ?? http.Client();

  NativeFetchMcpHandler({this.httpClient});

  @override
  Future<Map<String, dynamic>> initialize(Map<String, dynamic> params) async {
    return {
      'protocolVersion': '2024-11-05',
      'capabilities': {'tools': {}},
      'serverInfo': {'name': 'fetch', 'version': '1.0.0'},
    };
  }

  @override
  Future<List<McpToolDef>> listTools() async {
    return [
      McpToolDef(
        name: 'fetch',
        description: 'Fetch web page content and convert HTML to markdown/text.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'url': {'type': 'string', 'description': 'The URL to fetch.'},
            'max_length': {'type': 'integer', 'description': 'Maximum character length of returned text.'},
            'raw': {'type': 'boolean', 'description': 'If true, return raw content without markdown conversion.'},
          },
          'required': ['url'],
        },
      ),
    ];
  }

  static String _htmlToMarkdown(String html) {
    var s = html;
    // Strip scripts, styles, noscript
    s = s.replaceAll(RegExp(r'<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'<style\b[^<]*(?:(?!<\/style>)<[^<]*)*<\/style>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'<noscript\b[^<]*(?:(?!<\/noscript>)<[^<]*)*<\/noscript>', caseSensitive: false), '');

    // Headings
    s = s.replaceAllMapped(RegExp(r'<h([1-6])[^>]*>(.*?)</h\1>', caseSensitive: false, dotAll: true), (m) {
      final level = int.tryParse(m.group(1) ?? '1') ?? 1;
      final hashes = '#' * level;
      final content = m.group(2)?.trim() ?? '';
      return '\n\n$hashes $content\n\n';
    });

    // Links
    s = s.replaceAllMapped(RegExp(r'<a\s+[^>]*href=["' "'" r']([^"' "'" r']*)["' "'" r'][^>]*>(.*?)</a>', caseSensitive: false, dotAll: true), (m) {
      final href = m.group(1) ?? '';
      final text = m.group(2)?.trim() ?? '';
      return '[$text]($href)';
    });

    // Bold / Italics
    s = s.replaceAllMapped(RegExp(r'<(?:strong|b)>(.*?)</(?:strong|b)>', caseSensitive: false, dotAll: true), (m) {
      return '**${m.group(1)}**';
    });
    s = s.replaceAllMapped(RegExp(r'<(?:em|i)>(.*?)</(?:em|i)>', caseSensitive: false, dotAll: true), (m) {
      return '*${m.group(1)}*';
    });

    // Code & Pre
    s = s.replaceAllMapped(RegExp(r'<pre\b[^>]*>([\s\S]*?)</pre>', caseSensitive: false), (m) {
      return '\n```\n${m.group(1)?.trim()}\n```\n';
    });
    s = s.replaceAllMapped(RegExp(r'<code\b[^>]*>(.*?)</code>', caseSensitive: false, dotAll: true), (m) {
      return '`${m.group(1)}`';
    });

    // Lists
    s = s.replaceAllMapped(RegExp(r'<li\b[^>]*>(.*?)</li>', caseSensitive: false, dotAll: true), (m) {
      return '\n- ${m.group(1)?.trim()}';
    });

    // Block breaks
    s = s.replaceAll(RegExp(r'<(?:p|div|br\s*/?|tr)\b[^>]*>', caseSensitive: false), '\n');

    // Strip remaining tags
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');

    // HTML entities
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");

    // Clean whitespace
    s = s.replaceAll(RegExp(r'[ \t]+'), ' ');
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s.trim();
  }

  @override
  Future<McpRpcResult> callTool(String toolName, Map<String, dynamic> args) async {
    if (toolName != 'fetch') {
      return McpRpcResult.error('Unknown tool "$toolName" for fetch MCP');
    }

    final urlStr = args['url'] as String?;
    if (urlStr == null || urlStr.isEmpty) {
      return const McpRpcResult.error('Missing required url argument');
    }

    final raw = args['raw'] as bool? ?? false;
    final maxLength = args['max_length'] as int?;

    try {
      final uri = Uri.parse(urlStr);
      final response = await _client.get(uri, headers: {
        'User-Agent': 'Mozilla/5.0 (compatible; OvidAI/1.0)',
      });

      if (response.statusCode >= 400) {
        return McpRpcResult.ok({
          'content': [
            {'type': 'text', 'text': 'HTTP error ${response.statusCode}: ${response.reasonPhrase}'}
          ],
          'isError': true,
        });
      }

      var text = raw ? response.body : _htmlToMarkdown(response.body);

      if (maxLength != null && maxLength > 0 && text.length > maxLength) {
        text = '${text.substring(0, maxLength)}\n\n... [truncated]';
      }

      return McpRpcResult.ok({
        'content': [
          {'type': 'text', 'text': text}
        ],
        'isError': false,
      });
    } catch (e) {
      return McpRpcResult.error('Fetch error: $e');
    }
  }

  @override
  Future<void> dispose() async {
    if (httpClient != null) {
      httpClient!.close();
    }
  }
}

/// In-process Memory MCP handler providing persistent graph-based memory.
class NativeMemoryMcpHandler implements NativeMcpHandler {
  final File? storageFile;
  final Map<String, _MemoryEntity> _entities = {};
  final List<_MemoryRelation> _relations = [];
  bool _initialized = false;

  NativeMemoryMcpHandler({this.storageFile});

  Future<void> _ensureLoaded() async {
    if (_initialized) return;
    _initialized = true;
    if (storageFile != null && await storageFile!.exists()) {
      try {
        final content = await storageFile!.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        final entitiesJson = json['entities'] as List? ?? [];
        for (final item in entitiesJson) {
          if (item is Map<String, dynamic>) {
            final e = _MemoryEntity.fromJson(item);
            _entities[e.name] = e;
          }
        }
        final relationsJson = json['relations'] as List? ?? [];
        for (final item in relationsJson) {
          if (item is Map<String, dynamic>) {
            _relations.add(_MemoryRelation.fromJson(item));
          }
        }
      } catch (_) {}
    }
  }

  Future<void> _persist() async {
    if (storageFile == null) return;
    try {
      await storageFile!.parent.create(recursive: true);
      final json = {
        'entities': _entities.values.map((e) => e.toJson()).toList(),
        'relations': _relations.map((r) => r.toJson()).toList(),
      };
      await storageFile!.writeAsString(jsonEncode(json));
    } catch (_) {}
  }

  @override
  Future<Map<String, dynamic>> initialize(Map<String, dynamic> params) async {
    await _ensureLoaded();
    return {
      'protocolVersion': '2024-11-05',
      'capabilities': {'tools': {}},
      'serverInfo': {'name': 'memory', 'version': '1.0.0'},
    };
  }

  @override
  Future<List<McpToolDef>> listTools() async {
    return [
      McpToolDef(
        name: 'create_entities',
        description: 'Create multiple new entities in the knowledge graph.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'entities': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'name': {'type': 'string'},
                  'entityType': {'type': 'string'},
                  'observations': {
                    'type': 'array',
                    'items': {'type': 'string'}
                  },
                },
                'required': ['name', 'entityType', 'observations'],
              },
            },
          },
          'required': ['entities'],
        },
      ),
      McpToolDef(
        name: 'create_relations',
        description: 'Create relations between entities in the knowledge graph.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'relations': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'from': {'type': 'string'},
                  'to': {'type': 'string'},
                  'relationType': {'type': 'string'},
                },
                'required': ['from', 'to', 'relationType'],
              },
            },
          },
          'required': ['relations'],
        },
      ),
      McpToolDef(
        name: 'add_observations',
        description: 'Add observations to existing entities in the graph.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'observations': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'entityName': {'type': 'string'},
                  'contents': {
                    'type': 'array',
                    'items': {'type': 'string'}
                  },
                },
                'required': ['entityName', 'contents'],
              },
            },
          },
          'required': ['observations'],
        },
      ),
      McpToolDef(
        name: 'read_graph',
        description: 'Read the entire knowledge graph.',
        inputSchema: {
          'type': 'object',
          'properties': {},
        },
      ),
      McpToolDef(
        name: 'search_nodes',
        description: 'Search for nodes in the knowledge graph matching a query.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': 'Query string.'},
          },
          'required': ['query'],
        },
      ),
      McpToolDef(
        name: 'open_nodes',
        description: 'Retrieve specific nodes by their names along with their relations.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'names': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Names of entities to open.',
            },
          },
          'required': ['names'],
        },
      ),
    ];
  }

  McpRpcResult _toolResult(dynamic data, {bool isError = false}) {
    final text = data is String ? data : jsonEncode(data);
    return McpRpcResult.ok({
      'content': [
        {'type': 'text', 'text': text}
      ],
      'isError': isError,
    });
  }

  @override
  Future<McpRpcResult> callTool(String toolName, Map<String, dynamic> args) async {
    await _ensureLoaded();
    try {
      switch (toolName) {
        case 'create_entities': {
          final entitiesList = args['entities'] as List?;
          if (entitiesList == null) {
            return const McpRpcResult.error('Missing entities list');
          }
          final created = <_MemoryEntity>[];
          for (final raw in entitiesList) {
            if (raw is Map<String, dynamic>) {
              final name = raw['name'] as String? ?? '';
              final entityType = raw['entityType'] as String? ?? 'Concept';
              final obs = (raw['observations'] as List?)?.cast<String>() ?? [];
              if (name.isNotEmpty) {
                final existing = _entities[name];
                if (existing != null) {
                  final mergedObs = {...existing.observations, ...obs}.toList();
                  final updated = _MemoryEntity(
                    name: name,
                    entityType: entityType.isNotEmpty ? entityType : existing.entityType,
                    observations: mergedObs,
                  );
                  _entities[name] = updated;
                  created.add(updated);
                } else {
                  final entity = _MemoryEntity(
                    name: name,
                    entityType: entityType,
                    observations: obs,
                  );
                  _entities[name] = entity;
                  created.add(entity);
                }
              }
            }
          }
          await _persist();
          return _toolResult(created.map((e) => e.toJson()).toList());
        }

        case 'create_relations': {
          final relsList = args['relations'] as List?;
          if (relsList == null) {
            return const McpRpcResult.error('Missing relations list');
          }
          final added = <_MemoryRelation>[];
          for (final raw in relsList) {
            if (raw is Map<String, dynamic>) {
              final from = raw['from'] as String? ?? '';
              final to = raw['to'] as String? ?? '';
              final relationType = raw['relationType'] as String? ?? 'related_to';
              if (from.isNotEmpty && to.isNotEmpty) {
                final rel = _MemoryRelation(from: from, to: to, relationType: relationType);
                final alreadyExists = _relations.any(
                  (r) => r.from == from && r.to == to && r.relationType == relationType,
                );
                if (!alreadyExists) {
                  _relations.add(rel);
                  added.add(rel);
                }
              }
            }
          }
          await _persist();
          return _toolResult(added.map((r) => r.toJson()).toList());
        }

        case 'add_observations': {
          final obsList = args['observations'] as List?;
          if (obsList == null) {
            return const McpRpcResult.error('Missing observations list');
          }
          final modified = <_MemoryEntity>[];
          for (final raw in obsList) {
            if (raw is Map<String, dynamic>) {
              final name = raw['entityName'] as String? ?? '';
              final contents = (raw['contents'] as List?)?.cast<String>() ?? [];
              if (name.isNotEmpty && contents.isNotEmpty) {
                final existing = _entities[name];
                if (existing != null) {
                  final mergedObs = {...existing.observations, ...contents}.toList();
                  final updated = _MemoryEntity(
                    name: name,
                    entityType: existing.entityType,
                    observations: mergedObs,
                  );
                  _entities[name] = updated;
                  modified.add(updated);
                } else {
                  final entity = _MemoryEntity(
                    name: name,
                    entityType: 'Concept',
                    observations: contents,
                  );
                  _entities[name] = entity;
                  modified.add(entity);
                }
              }
            }
          }
          await _persist();
          return _toolResult(modified.map((e) => e.toJson()).toList());
        }

        case 'read_graph': {
          return _toolResult({
            'entities': _entities.values.map((e) => e.toJson()).toList(),
            'relations': _relations.map((r) => r.toJson()).toList(),
          });
        }

        case 'search_nodes': {
          final query = (args['query'] as String? ?? '').toLowerCase();
          final matchingEntities = _entities.values.where((e) {
            if (e.name.toLowerCase().contains(query)) return true;
            if (e.entityType.toLowerCase().contains(query)) return true;
            return e.observations.any((o) => o.toLowerCase().contains(query));
          }).toList();
          final matchingNames = matchingEntities.map((e) => e.name).toSet();
          final matchingRelations = _relations.where((r) {
            return matchingNames.contains(r.from) || matchingNames.contains(r.to);
          }).toList();

          return _toolResult({
            'entities': matchingEntities.map((e) => e.toJson()).toList(),
            'relations': matchingRelations.map((r) => r.toJson()).toList(),
          });
        }

        case 'open_nodes': {
          final names = ((args['names'] as List?) ?? []).cast<String>().toSet();
          final matchingEntities = _entities.values.where((e) => names.contains(e.name)).toList();
          final matchingRelations = _relations.where((r) {
            return names.contains(r.from) || names.contains(r.to);
          }).toList();

          return _toolResult({
            'entities': matchingEntities.map((e) => e.toJson()).toList(),
            'relations': matchingRelations.map((r) => r.toJson()).toList(),
          });
        }

        default:
          return McpRpcResult.error('Unknown tool "$toolName" for memory MCP');
      }
    } catch (e) {
      return McpRpcResult.error('Memory error: $e');
    }
  }

  @override
  Future<void> dispose() async {
    await _persist();
  }
}

class _MemoryEntity {
  final String name;
  final String entityType;
  final List<String> observations;

  _MemoryEntity({
    required this.name,
    required this.entityType,
    required this.observations,
  });

  factory _MemoryEntity.fromJson(Map<String, dynamic> j) => _MemoryEntity(
        name: j['name'] as String? ?? '',
        entityType: j['entityType'] as String? ?? 'Concept',
        observations: (j['observations'] as List?)?.cast<String>() ?? [],
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'entityType': entityType,
        'observations': observations,
      };
}

class _MemoryRelation {
  final String from;
  final String to;
  final String relationType;

  _MemoryRelation({
    required this.from,
    required this.to,
    required this.relationType,
  });

  factory _MemoryRelation.fromJson(Map<String, dynamic> j) => _MemoryRelation(
        from: j['from'] as String? ?? '',
        to: j['to'] as String? ?? '',
        relationType: j['relationType'] as String? ?? 'related_to',
      );

  Map<String, dynamic> toJson() => {
        'from': from,
        'to': to,
        'relationType': relationType,
      };
}
