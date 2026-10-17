/**
 * Dev-platform REST descriptors — a data port of the Dart
 * `rest_descriptors_dev.dart` for the six curated dev services: GitLab,
 * Jira, Linear, Figma, Sentry, Exa (Bitbucket and Trello were cut by the
 * Task 6 lineup decision — GitHub+Jira cover the demand).
 *
 * Tool names, paths, schemas and credential labels are copied verbatim from
 * the Dart source. What the Dart file achieved with routing subclasses is
 * expressed declaratively here (documented per descriptor):
 *  - GitLab's optional self-hosted host: `{host=gitlab.com}` (the Dart
 *    `_HostRoutedCapability` rerouted to `https://<host>/api/v4`).
 *  - Jira's required per-tenant host: `https://{host}` in the baseUrl — the
 *    engine's missing-placeholder configure-first gate replaces the Dart
 *    `requireHost` branch. The Dart tool paths already carry `/rest/api/3/…`.
 */

import type { RestServiceDescriptor } from "../engine.js";

export const GITLAB_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "gitlab",
  displayName: "GitLab MCP",
  description: "GitLab projects, merge requests and issues over the REST API (gitlab.com or self-hosted).",
  baseUrl: "https://{host=gitlab.com}/api/v4",
  auth: "apiKeyHeader",
  authHeader: "PRIVATE-TOKEN",
  credentialKey: "token",
  credentialLabel: "GitLab personal access token",
  extraConfig: [
    {
      key: "host",
      label: "Self-hosted GitLab host (optional)",
      secret: false,
      hint: "Bare hostname or full URL of your self-hosted instance (e.g. git.example.com). Empty means gitlab.com.",
    },
  ],
  tools: [
    {
      name: "list_projects",
      description: "List GitLab projects (optionally filtered by search).",
      method: "GET",
      path: "/projects",
      inputSchema: {
        type: "object",
        properties: {
          search: { type: "string" },
        },
      },
      queryArgs: ["search"],
    },
    {
      name: "list_merge_requests",
      description: "List merge requests of a project (state filter).",
      method: "GET",
      path: "/projects/{project_id}/merge_requests",
      inputSchema: {
        type: "object",
        properties: {
          project_id: { type: "string" },
          state: { type: "string" },
        },
        required: ["project_id"],
      },
      queryArgs: ["state"],
      required: ["project_id"],
    },
    {
      name: "create_issue",
      description:
        "Create a project issue (title + description travel as request parameters, which GitLab accepts on this method).",
      method: "POST",
      path: "/projects/{project_id}/issues",
      inputSchema: {
        type: "object",
        properties: {
          project_id: { type: "string" },
          title: { type: "string" },
          description: { type: "string" },
        },
        required: ["project_id", "title"],
      },
      queryArgs: ["title", "description"],
      required: ["project_id", "title"],
    },
  ],
};

export const JIRA_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "jira",
  displayName: "Jira MCP",
  description: "Jira issues over the Atlassian Cloud REST API (JQL search, get, create, comment).",
  baseUrl: "https://{host}",
  auth: "basic",
  authParam: "email",
  credentialKey: "api_token",
  credentialLabel: "Jira API token",
  extraConfig: [
    {
      key: "host",
      label: "Jira host",
      secret: false,
      hint: "Your Atlassian Cloud hostname, e.g. acme.atlassian.net (scheme optional).",
    },
    {
      key: "email",
      label: "Jira email",
      secret: false,
      hint: "The Atlassian account email (basic-auth username).",
    },
  ],
  tools: [
    {
      name: "search",
      description:
        'Search issues with JQL. body is the search JSON, e.g. {"jql": "project = PROJ", "maxResults": 20}.',
      method: "POST",
      path: "/rest/api/3/search/jql",
      inputSchema: {
        type: "object",
        properties: {
          body: { type: "object" },
        },
        required: ["body"],
      },
      jsonBodyArg: "body",
      required: ["body"],
    },
    {
      name: "get_issue",
      description: "Fetch one issue by key (e.g. PROJ-123).",
      method: "GET",
      path: "/rest/api/3/issue/{key}",
      inputSchema: {
        type: "object",
        properties: {
          key: { type: "string" },
        },
        required: ["key"],
      },
      required: ["key"],
    },
    {
      name: "create_issue",
      description:
        'Create an issue. body is the Jira issue JSON, e.g. {"fields": {"project": {"key": "PROJ"}, "summary": "New bug", "issuetype": {"name": "Task"}}}.',
      method: "POST",
      path: "/rest/api/3/issue",
      inputSchema: {
        type: "object",
        properties: {
          body: { type: "object" },
        },
        required: ["body"],
      },
      jsonBodyArg: "body",
      required: ["body"],
    },
    {
      name: "add_comment",
      description: 'Comment on an issue. body is the comment JSON, e.g. {"body": "looks good"}.',
      method: "POST",
      path: "/rest/api/3/issue/{key}/comment",
      inputSchema: {
        type: "object",
        properties: {
          key: { type: "string" },
          body: { type: "object" },
        },
        required: ["key", "body"],
      },
      jsonBodyArg: "body",
      required: ["key", "body"],
    },
  ],
};

export const LINEAR_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "linear",
  displayName: "Linear Sync",
  description: "Linear issues and teams over the GraphQL API.",
  baseUrl: "https://api.linear.app/graphql",
  auth: "bearer",
  authPrefix: "Bearer ",
  credentialKey: "api_key",
  credentialLabel: "Linear API key",
  tools: [
    {
      name: "list_issues",
      description:
        'List issues via GraphQL. body is the GraphQL JSON, e.g. {"query": "query { issues(first: 20) { nodes { id title } } }"}',
      method: "POST",
      path: "",
      inputSchema: {
        type: "object",
        properties: {
          body: { type: "object" },
        },
        required: ["body"],
      },
      jsonBodyArg: "body",
      required: ["body"],
    },
    {
      name: "create_issue",
      description:
        'Create an issue via GraphQL. body is the GraphQL JSON, e.g. {"query": "mutation … issueCreate …", "variables": {"input": {"teamId": "T1", "title": "Bug"}}}.',
      method: "POST",
      path: "",
      inputSchema: {
        type: "object",
        properties: {
          body: { type: "object" },
        },
        required: ["body"],
      },
      jsonBodyArg: "body",
      required: ["body"],
    },
    {
      name: "list_teams",
      description: 'List teams via GraphQL. body is the GraphQL JSON, e.g. {"query": "query { teams { nodes { id name } } }"}',
      method: "POST",
      path: "",
      inputSchema: {
        type: "object",
        properties: {
          body: { type: "object" },
        },
        required: ["body"],
      },
      jsonBodyArg: "body",
      required: ["body"],
    },
  ],
};

export const FIGMA_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "figma",
  displayName: "Figma Bridge",
  description: "Figma files and comments over the REST API.",
  baseUrl: "https://api.figma.com/v1",
  auth: "apiKeyHeader",
  authHeader: "X-Figma-Token",
  credentialKey: "token",
  credentialLabel: "Figma personal access token",
  tools: [
    {
      name: "get_file",
      description: "Fetch a Figma file by key.",
      method: "GET",
      path: "/files/{file_key}",
      inputSchema: {
        type: "object",
        properties: {
          file_key: { type: "string" },
        },
        required: ["file_key"],
      },
      required: ["file_key"],
    },
    {
      name: "get_comments",
      description: "List the comments of a Figma file.",
      method: "GET",
      path: "/files/{file_key}/comments",
      inputSchema: {
        type: "object",
        properties: {
          file_key: { type: "string" },
        },
        required: ["file_key"],
      },
      required: ["file_key"],
    },
    {
      name: "post_comment",
      description: 'Comment on a Figma file. body is the comment JSON, e.g. {"message": "Nice work"}.',
      method: "POST",
      path: "/files/{file_key}/comments",
      inputSchema: {
        type: "object",
        properties: {
          file_key: { type: "string" },
          body: { type: "object" },
        },
        required: ["file_key", "body"],
      },
      jsonBodyArg: "body",
      required: ["file_key", "body"],
    },
  ],
};

export const SENTRY_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "sentry",
  displayName: "Sentry Watch",
  description: "Sentry issues and latest events over the REST API.",
  baseUrl: "https://sentry.io/api/0",
  auth: "bearer",
  authPrefix: "Bearer ",
  credentialKey: "auth_token",
  credentialLabel: "Sentry auth token",
  tools: [
    {
      name: "list_issues",
      description: "List the unresolved issues of an organization (project id filter).",
      method: "GET",
      path: "/organizations/{org}/issues/",
      inputSchema: {
        type: "object",
        properties: {
          org: { type: "string" },
          project: { type: "string" },
        },
        required: ["org"],
      },
      queryArgs: ["project"],
      required: ["org"],
    },
    {
      name: "get_issue",
      description: "Fetch one issue by id.",
      method: "GET",
      path: "/issues/{id}/",
      inputSchema: {
        type: "object",
        properties: {
          id: { type: "string" },
        },
        required: ["id"],
      },
      required: ["id"],
    },
    {
      name: "latest_event",
      description: "Fetch the newest event of an issue.",
      method: "GET",
      path: "/issues/{issue_id}/events/latest/",
      inputSchema: {
        type: "object",
        properties: {
          issue_id: { type: "string" },
        },
        required: ["issue_id"],
      },
      required: ["issue_id"],
    },
  ],
};

export const EXA_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "exa",
  displayName: "Exa Search MCP",
  description: "Neural web search and page contents over the Exa API.",
  baseUrl: "https://api.exa.ai",
  auth: "apiKeyHeader",
  authHeader: "x-api-key",
  credentialKey: "api_key",
  credentialLabel: "Exa API key",
  tools: [
    {
      name: "search",
      description: 'Neural web search. body is the Exa search JSON, e.g. {"query": "flutter testing", "numResults": 5}.',
      method: "POST",
      path: "/search",
      inputSchema: {
        type: "object",
        properties: {
          body: { type: "object" },
        },
        required: ["body"],
      },
      jsonBodyArg: "body",
      required: ["body"],
    },
    {
      name: "contents",
      description: 'Fetch page contents. body is the Exa contents JSON, e.g. {"ids": ["https://example.com"], "text": true}.',
      method: "POST",
      path: "/contents",
      inputSchema: {
        type: "object",
        properties: {
          body: { type: "object" },
        },
        required: ["body"],
      },
      jsonBodyArg: "body",
      required: ["body"],
    },
  ],
};

export const DEV_DESCRIPTORS: readonly RestServiceDescriptor[] = [
  GITLAB_DESCRIPTOR,
  JIRA_DESCRIPTOR,
  LINEAR_DESCRIPTOR,
  FIGMA_DESCRIPTOR,
  SENTRY_DESCRIPTOR,
  EXA_DESCRIPTOR,
];
