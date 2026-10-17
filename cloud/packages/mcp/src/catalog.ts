/**
 * The curated MCP catalog — THE lineup decision (spec §16 builder's latitude).
 *
 * 20 curated servers = 4 native (`github, filesystem, fetch, memory`) + 16
 * REST (dev: `gitlab, jira, linear, figma, sentry, exa`; data: `notion,
 * google-drive, airtable, supabase, firebase, mongodb, s3`; comms: `slack,
 * discord, telegram`).
 *
 * **Excluded, with reasons:** bitbucket/trello (GitHub+Jira cover the
 * demand); stripe (money surface is P9's); the whole infra family —
 * vercel/railway/heroku/digitalocean/cloudflare/docker/kubernetes/terraform/
 * zapier/make (write-heavy deploy/mutate actions on the Free tier are an
 * incident risk; revisit as a post-launch curated expansion); redis (raw TCP
 * RESP client from the worker to arbitrary user hosts — SSRF surface beyond
 * HTTP; excluded until a jailed proxy exists); obsidian (local-vault concept
 * doesn't exist in cloud workspaces); dall-e/elevenlabs/youtube (billable
 * media generation belongs to P9's images pipeline); firebase-adjacent niches
 * appwrite/pocketbase/vector-db (low usage); cal.com/twilio/whatsapp
 * (cost/PII-heavy comms); discord-bot-builder (duplicate of discord).
 *
 * `CURATED_MANIFEST` is pure data — the gateway serves it without
 * instantiating a single handler. The Task 5 handler modules export `*_TOOLS`
 * name lists, not tool defs, so the four native tool tables are mirrored
 * here verbatim and pinned drift-free against each live handler's
 * `listTools()` by a parity test in catalog.test.ts.
 *
 * `createCuratedCatalog` instantiates each handler EXACTLY ONCE (lazily,
 * memoized per id) — one shared singleton per curated server per worker
 * process. Per-user data (decrypted secrets, workspace, SSRF-guarded fetch)
 * is injected per call through McpCallContext, never stored on the handler.
 */

import type { McpToolDef } from "./client.js";
import type { NativeMcpHandler } from "./transports/native.js";
import type { GuardedFetch } from "./ssrf.js";
import type { WorkspaceFiles } from "./workspace.js";
import { createRestHandler, restToolDefs, type CredentialField } from "./rest/engine.js";
import { CURATED_DESCRIPTORS } from "./rest/descriptors/index.js";
import { createS3Handler, createGoogleDriveHandler } from "./rest/descriptors/data.js";
import { createFetchHandler } from "./native/fetch.js";
import { createFilesystemHandler } from "./native/filesystem.js";
import { createMemoryHandler } from "./native/memory.js";
import { createGitHubHandler } from "./native/github.js";

export interface CatalogManifestEntry {
  curatedId: string;
  displayName: string;
  description: string;
  credentialFields: CredentialField[];
  tools: McpToolDef[];
}

/** The 20 curated ids, pinned, in this order. */
export const CURATED_IDS: readonly string[] = [
  "github",
  "filesystem",
  "fetch",
  "memory",
  "gitlab",
  "jira",
  "linear",
  "figma",
  "sentry",
  "exa",
  "notion",
  "google-drive",
  "airtable",
  "supabase",
  "firebase",
  "mongodb",
  "s3",
  "slack",
  "discord",
  "telegram",
];

// ---------------------------------------------------------------------------
// Native tool-def mirrors (Task 5 modules own the live tables; these copies
// are byte-for-byte the same defs and parity-pinned by catalog.test.ts)
// ---------------------------------------------------------------------------

const FETCH_TOOL_DEFS: readonly McpToolDef[] = [
  {
    name: "fetch",
    description: "Fetch web page content and convert HTML to markdown/text.",
    inputSchema: {
      type: "object",
      properties: {
        url: { type: "string", description: "The URL to fetch." },
        max_length: { type: "integer", description: "Maximum character length of returned text." },
        raw: { type: "boolean", description: "If true, return raw content without markdown conversion." },
      },
      required: ["url"],
    },
  },
];

const FILESYSTEM_TOOL_DEFS: readonly McpToolDef[] = [
  {
    name: "read_file",
    description: "Read the contents of a file.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Path to the file." },
      },
      required: ["path"],
    },
  },
  {
    name: "write_file",
    description: "Create or overwrite a file with given contents.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Path to the file." },
        content: { type: "string", description: "Content to write." },
      },
      required: ["path", "content"],
    },
  },
  {
    name: "create_or_update_file",
    description: "Create or update a file with given contents.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Path to the file." },
        content: { type: "string", description: "Content to write." },
      },
      required: ["path", "content"],
    },
  },
  {
    name: "delete_file",
    description: "Delete a file or directory.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Path to delete." },
      },
      required: ["path"],
    },
  },
  {
    name: "list_directory",
    description: "List contents of a directory.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Path to directory (default: root)." },
      },
    },
  },
  {
    name: "get_file_info",
    description: "Get file or directory metadata (size, modified time, etc.).",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Path to file or directory." },
      },
      required: ["path"],
    },
  },
  {
    name: "search_files",
    description: "Recursively search for files matching a pattern.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Starting path (default: root)." },
        pattern: { type: "string", description: "Filename search pattern or substring." },
      },
      required: ["pattern"],
    },
  },
];

const MEMORY_TOOL_DEFS: readonly McpToolDef[] = [
  {
    name: "create_entities",
    description: "Create multiple new entities in the knowledge graph.",
    inputSchema: {
      type: "object",
      properties: {
        entities: {
          type: "array",
          items: {
            type: "object",
            properties: {
              name: { type: "string" },
              entityType: { type: "string" },
              observations: {
                type: "array",
                items: { type: "string" },
              },
            },
            required: ["name", "entityType", "observations"],
          },
        },
      },
      required: ["entities"],
    },
  },
  {
    name: "create_relations",
    description: "Create relations between entities in the knowledge graph.",
    inputSchema: {
      type: "object",
      properties: {
        relations: {
          type: "array",
          items: {
            type: "object",
            properties: {
              from: { type: "string" },
              to: { type: "string" },
              relationType: { type: "string" },
            },
            required: ["from", "to", "relationType"],
          },
        },
      },
      required: ["relations"],
    },
  },
  {
    name: "add_observations",
    description: "Add observations to existing entities in the graph.",
    inputSchema: {
      type: "object",
      properties: {
        observations: {
          type: "array",
          items: {
            type: "object",
            properties: {
              entityName: { type: "string" },
              contents: {
                type: "array",
                items: { type: "string" },
              },
            },
            required: ["entityName", "contents"],
          },
        },
      },
      required: ["observations"],
    },
  },
  {
    name: "read_graph",
    description: "Read the entire knowledge graph.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "search_nodes",
    description: "Search for nodes in the knowledge graph matching a query.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Query string." },
      },
      required: ["query"],
    },
  },
  {
    name: "open_nodes",
    description: "Retrieve specific nodes by their names along with their relations.",
    inputSchema: {
      type: "object",
      properties: {
        names: {
          type: "array",
          items: { type: "string" },
          description: "Names of entities to open.",
        },
      },
      required: ["names"],
    },
  },
];

const GITHUB_TOOL_DEFS: readonly McpToolDef[] = [
  {
    name: "search_repositories",
    description: "Search for GitHub repositories by query.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "The search query." },
        per_page: { type: "integer", description: "Results per page (default: 30)." },
        page: { type: "integer", description: "Page number." },
      },
      required: ["query"],
    },
  },
  {
    name: "get_file_contents",
    description: "Get contents of a file or directory in a repository.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string", description: "Repository owner." },
        repo: { type: "string", description: "Repository name." },
        path: { type: "string", description: "File path within the repository." },
        ref: { type: "string", description: "Branch, tag, or commit ref." },
      },
      required: ["owner", "repo", "path"],
    },
  },
  {
    name: "create_or_update_file",
    description: "Create or update a file in a repository.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string", description: "Repository owner." },
        repo: { type: "string", description: "Repository name." },
        path: { type: "string", description: "File path within repository." },
        content: { type: "string", description: "File content." },
        message: { type: "string", description: "Commit message." },
        branch: { type: "string", description: "Branch to commit to." },
        sha: { type: "string", description: "Blob SHA if updating an existing file." },
      },
      required: ["owner", "repo", "path", "content", "message"],
    },
  },
  {
    name: "create_issue",
    description: "Create an issue in a repository.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string", description: "Repository owner." },
        repo: { type: "string", description: "Repository name." },
        title: { type: "string", description: "Issue title." },
        body: { type: "string", description: "Issue body markdown." },
        labels: {
          type: "array",
          items: { type: "string" },
          description: "List of label names.",
        },
        assignees: {
          type: "array",
          items: { type: "string" },
          description: "List of GitHub usernames.",
        },
      },
      required: ["owner", "repo", "title"],
    },
  },
  {
    name: "list_issues",
    description: "List issues in a repository.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string" },
        repo: { type: "string" },
        state: { type: "string", enum: ["open", "closed", "all"] },
        per_page: { type: "integer" },
        page: { type: "integer" },
      },
      required: ["owner", "repo"],
    },
  },
  {
    name: "get_issue",
    description: "Get details of a specific issue.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string", description: "Repository owner." },
        repo: { type: "string", description: "Repository name." },
        issue_number: { type: "integer", description: "Issue number." },
      },
      required: ["owner", "repo", "issue_number"],
    },
  },
  {
    name: "add_issue_comment",
    description: "Add a comment to an existing issue.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string", description: "Repository owner." },
        repo: { type: "string", description: "Repository name." },
        issue_number: { type: "integer", description: "Issue number." },
        body: { type: "string", description: "Comment body." },
      },
      required: ["owner", "repo", "issue_number", "body"],
    },
  },
  {
    name: "create_pull_request",
    description: "Create a new pull request.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string", description: "Repository owner." },
        repo: { type: "string", description: "Repository name." },
        title: { type: "string", description: "PR title." },
        head: { type: "string", description: "Branch with changes." },
        base: { type: "string", description: "Target branch to merge into." },
        body: { type: "string", description: "PR body markdown." },
      },
      required: ["owner", "repo", "title", "head", "base"],
    },
  },
  {
    name: "list_pull_requests",
    description: "List pull requests in a repository.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string" },
        repo: { type: "string" },
        state: { type: "string", enum: ["open", "closed", "all"] },
        per_page: { type: "integer" },
        page: { type: "integer" },
      },
      required: ["owner", "repo"],
    },
  },
  {
    name: "fork_repository",
    description: "Fork a repository.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string", description: "Repository owner." },
        repo: { type: "string", description: "Repository name." },
        organization: { type: "string", description: "Optional target organization." },
      },
      required: ["owner", "repo"],
    },
  },
  {
    name: "list_commits",
    description: "List commits in a repository.",
    inputSchema: {
      type: "object",
      properties: {
        owner: { type: "string" },
        repo: { type: "string" },
        page: { type: "integer" },
        per_page: { type: "integer" },
      },
      required: ["owner", "repo"],
    },
  },
  {
    name: "get_user",
    description: "Get profile information for a GitHub user.",
    inputSchema: {
      type: "object",
      properties: {
        username: {
          type: "string",
          description: "GitHub username (optional, defaults to authenticated user).",
        },
      },
    },
  },
];

// ---------------------------------------------------------------------------
// The manifest (pure data, module load, no handler construction)
// ---------------------------------------------------------------------------

interface NativeManifestSpec {
  displayName: string;
  description: string;
  credentialFields: CredentialField[];
  tools: readonly McpToolDef[];
}

const NATIVE_SPECS: Record<string, NativeManifestSpec> = {
  github: {
    displayName: "GitHub",
    description: "GitHub repositories, issues, PRs and files over the REST API.",
    credentialFields: [{ key: "GITHUB_TOKEN", label: "GitHub token", secret: true }],
    tools: GITHUB_TOOL_DEFS,
  },
  filesystem: {
    displayName: "Filesystem",
    description: "Read, write, search and delete files in the user's cloud workspace.",
    credentialFields: [],
    tools: FILESYSTEM_TOOL_DEFS,
  },
  fetch: {
    displayName: "Fetch",
    description: "Fetch web pages as markdown/text through the SSRF-guarded gateway.",
    credentialFields: [],
    tools: FETCH_TOOL_DEFS,
  },
  memory: {
    displayName: "Memory",
    description: "A per-user knowledge graph persisted in the user's workspace.",
    credentialFields: [],
    tools: MEMORY_TOOL_DEFS,
  },
};

function restManifestEntry(id: string): CatalogManifestEntry {
  const d = CURATED_DESCRIPTORS.find((x) => x.curatedId === id);
  if (d === undefined) throw new Error(`curated descriptor missing: ${id}`);
  const credentialFields: CredentialField[] = [];
  if (d.credentialKey !== "") {
    credentialFields.push({ key: d.credentialKey, label: d.credentialLabel, secret: true });
  }
  credentialFields.push(...(d.extraConfig ?? []));
  return {
    curatedId: d.curatedId,
    displayName: d.displayName,
    description: d.description,
    credentialFields,
    tools: restToolDefs(d),
  };
}

function manifestEntry(id: string): CatalogManifestEntry {
  const native = NATIVE_SPECS[id];
  if (native !== undefined) {
    return {
      curatedId: id,
      displayName: native.displayName,
      description: native.description,
      credentialFields: [...native.credentialFields],
      tools: native.tools.map((t) => ({ ...t, inputSchema: { ...t.inputSchema } })),
    };
  }
  return restManifestEntry(id);
}

export const CURATED_MANIFEST: readonly CatalogManifestEntry[] = CURATED_IDS.map(manifestEntry);

// ---------------------------------------------------------------------------
// The catalog (one handler instance per curated server, shared by all users)
// ---------------------------------------------------------------------------

export interface CatalogEntry extends CatalogManifestEntry {
  handler: NativeMcpHandler;
}

export interface CuratedCatalog {
  entries(): readonly CatalogEntry[];
  get(curatedId: string): CatalogEntry | undefined;
}

export interface CuratedCatalogDeps {
  /** Kept for the pinned seam: REST/native handlers source their fetch from
   * ctx.fetchImpl per call; the worker's ctxProvider injects this one. */
  fetchImpl: GuardedFetch;
  /** Same rule as fetchImpl: filesystem/memory reach the workspace through
   * ctx.workspace (the Task 16 worker seam adapts @ovid/sandbox to it). */
  workspace: WorkspaceFiles;
  githubApiBase?: string;
  /** Test seam: per-id handler factory overrides (the singleton-proof test
   * wraps a factory with a construction counter). */
  handlerOverrides?: Partial<Record<string, () => NativeMcpHandler>>;
}

export function createCuratedCatalog(deps: CuratedCatalogDeps): CuratedCatalog {
  const cache = new Map<string, CatalogEntry>();

  function defaultFactory(id: string): NativeMcpHandler {
    switch (id) {
      case "github":
        return createGitHubHandler({ apiBase: deps.githubApiBase });
      case "filesystem":
        return createFilesystemHandler();
      case "fetch":
        return createFetchHandler();
      case "memory":
        return createMemoryHandler();
      case "s3":
        return createS3Handler();
      case "google-drive":
        return createGoogleDriveHandler();
      default: {
        const d = CURATED_DESCRIPTORS.find((x) => x.curatedId === id);
        if (d === undefined) throw new Error(`unknown curated id: ${id}`);
        return createRestHandler(d);
      }
    }
  }

  function entry(id: string): CatalogEntry {
    let cached = cache.get(id);
    if (cached === undefined) {
      const override = deps.handlerOverrides?.[id];
      const handler = override !== undefined ? override() : defaultFactory(id);
      cached = { ...manifestEntry(id), handler };
      cache.set(id, cached);
    }
    return cached;
  }

  return {
    entries(): readonly CatalogEntry[] {
      return CURATED_IDS.map(entry);
    },
    get(curatedId: string): CatalogEntry | undefined {
      return CURATED_IDS.includes(curatedId) ? entry(curatedId) : undefined;
    },
  };
}
