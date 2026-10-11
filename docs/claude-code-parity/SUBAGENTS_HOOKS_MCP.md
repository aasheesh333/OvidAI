# Subagents, hooks and MCP: Claude Code parity

Owner requirement: "Hooks, MCP and all features of subagents must be like Claude
Code. A subagent does its work with the relevant plugins' hooks, skills and MCP,
and a subagent cannot trigger another subagent."

Reference: code.claude.com/docs/en/sub-agents, /hooks, /mcp, /skills and
/plugins-reference (fetched 2026-10-11). Where the docs and the owner disagree,
the owner wins. Nesting is the only such case: Claude Code allows nesting up to a
depth limit, but the owner's rule is no nesting at all.

## Gap table

| Area | Before this branch | Claude Code | Status |
|---|---|---|---|
| Plugin `agents/*.md` runs as a real subagent | Yes (own session, persona, model) | Same | kept |
| `tools:` omitted = inherit all (incl. MCP) | Yes | Same | kept |
| `tools:` with Claude Code names (`Read, Grep`) | Exact match on native names only, so `Read` granted nothing | CC names | **done** (`ClaudeCodeTools.nativeToolsFor`) |
| `tools:` MCP patterns `mcp__srv`, `mcp__srv__*`, `mcp__*` (deny) | No | Yes | **done** (`SubagentToolPolicy`) |
| `disallowedTools` | Ignored | Removes tool (a specifier removes the whole tool) | **done** (stored as `!entry`) |
| Child roster shows only the granted tools | Spawn tools hidden; `allowed_tools` enforced only at dispatch | Roster filtered | **done** (roster and gate share one policy) |
| `model:` `inherit` / alias / full id | Value passed through, so `inherit` became a literal model id | Resolved | **done** (`resolveSubagentModel`) |
| `skills:` preload (full content) | Ignored | Preloaded into context | **done** (appended to the child persona) |
| Skills discoverable via the Skill tool | Child catalog inherits the parent's plugin activations | Same | kept |
| Invoke a definition by `subagent_type` (Agent/Task tool) | Only via the plugin contribution tool | `Agent(subagent_type)` | **done** (`dispatch_agent.subagent_type`) |
| No nesting: spawn tool absent | `dispatch_agent`/`workflow`/`ralph` hidden | Withheld at the depth limit | **done**, and plugin agent contribution tools are also hidden and refused |
| No nesting: runtime reject | 3 layers (gate, roster, spawn site) | n/a | kept, with a test |
| Approvals inside a subagent | Auto-approved; destructive commands auto-denied | Passed through to the user and named after the subagent | **done** (labelled `[subagent sub-N · type · label]`, queued behind an open card) |
| PreToolUse/PostToolUse fire for subagent tool calls | Yes (lineage activation) | Same matcher semantics | kept |
| Hook input `agent_id` / `agent_type` | Missing | Present inside a subagent | **done** (`HookService.agentIdentityResolver`) |
| Hook `session_id` / `transcript_path` inside a subagent | The child's | The main session's (`agent_transcript_path` = child) | **done** (child id kept as `ovid_session_id`) |
| SubagentStart `additionalContext` | Ignored | Added to the subagent's context | **done** |
| SubagentStart/Stop matcher on agent type | Matcher ignored (matched everything) | Matches `agent_type`. A scoped `plugin:agent` matcher is an unanchored regex | **done** |
| SubagentStop exit 2 blocks | Yes (bounded to 3) | Yes | kept |
| SubagentStop JSON `decision:block` + reason | Ignored | Blocks; the reason is the next instruction | **done** |
| SubagentStop fields `last_assistant_message`, `stop_hook_active`, `agent_transcript_path` | Missing | Present | **done** |
| `Stop` fires only for the main agent | Fired for children too | Main agent only | **done** |
| Subagent frontmatter `hooks`, `mcpServers`, `permissionMode` | Not supported | Ignored for plugin subagents, supported for user/project agents | not applicable: Ovid's agent definitions come from plugins, where CC ignores these fields too |
| `maxTurns`, `isolation: worktree`, `memory`, `background` field | Not supported | Supported | not done (out of scope) |
| MCP calls from a subagent | Work; recorded without attribution | Respect `tools` | **done**: scoped by policy and attributed per `agent_type` in `ToolUsageStore.agentCalls` |
| PostToolUse awaited | Fire-and-forget | Awaited | **done** |
| PostToolUse full `tool_input` + untruncated `tool_response` | No input; response cut to 400 chars | Full | **done** (env copy stays bounded) |
| PostToolUse `decision:block` / exit 2 / `additionalContext` / `updatedToolOutput` | Ignored | Honoured | **done** (appended to / replaces the tool result) |
| Tool-name aliasing Bash/Read/Write/Edit | Matcher only | n/a | kept |
| Aliasing Glob, Grep, WebFetch, WebSearch, Agent+Task, TodoWrite, Skill | No | n/a | **done** |
| MultiEdit / NotebookEdit | No | NotebookEdit edits one cell (`replace`/`insert`/`delete`). MultiEdit is the older multi-replace tool, no longer in the current tools table | **done**: native `multi_edit` (`{file_path, edits[]}`, sequential, all-or-nothing, unique unless `replace_all`) and `notebook_edit` (`{notebook_path, cell_id, new_source, cell_type, edit_mode}`, keeps notebook/cell metadata and outputs). Same gates as `fs_edit`: read-before-write, CAS, path grants, approval, diff card, RepoCache/Studio, Read-Only refusal. Plan mode refuses them (not allowlisted). CC aliases for matchers, stdin and `tools:` |
| CC stdin: CC `tool_name` + CC `tool_input` keys | Native name and keys | CC shape | **done** for command hooks of `claudeCode`-format plugins (native name kept as `ovid_tool_name`, native keys kept alongside). Prompt/agent hooks keep native stdin |
| `updatedInput` CC → native (`file_path`→`path`, ...) | Merged verbatim | n/a | **done** |
| Write vs Edit on create | `fs_edit create` → Write | Same | kept |
| MCP `initialize` capabilities + protocol `2025-06-18` | `2024-11-05`, `{}` | Current revision | **done** (stdio, HTTP, SSE; native in-process handlers unchanged) |
| Server→client `ping` | Dropped (the early return on `id`) | Answered | **done** |
| `roots/list` | Dropped | Workspace roots | **done** (active session's working folder; `listChanged:false`) |
| `sampling/createMessage` with user approval | Dropped | Supported | **done** (asked in every mode, Full Access included) |
| `elicitation/create` via a sheet | Dropped | Supported | **done** (`McpElicitationSheet`) |
| Server request with the same id as our pending request | Mistaken for our response | Distinct | **done** (stdio, HTTP SSE body, legacy SSE) |
| `notifications/progress`, `notifications/message` | Ignored | Handled | **done**: every `tools/call` sends `_meta.progressToken`. Progress goes to the live tool card and restarts the HTTP response timeout. Log lines are kept per server |
| Server request mid-stream over Streamable HTTP | n/a | Answered while the POST stream is open | **done**: the `text/event-stream` POST response is parsed incrementally (`McpSseParser`). Requests are answered at once on the same `Mcp-Session-Id`, and the event with our id resolves the call |

## Design notes

- `lib/core/claude_code_tools.dart` holds the single translation table. It is
  pure and used both ways: native to CC for matchers and stdin, CC to native for
  `updatedInput` and `tools:`.
- `lib/core/subagent_tools.dart` holds `SubagentToolPolicy`, which the roster and
  the dispatch gate both use. It also holds `SubagentScope`, a Zone identity that
  the usage store reads, so MCP and plugin usage is attributed without importing
  the agent service. It also has the model resolution and frontmatter list
  parsing.
- `disallowedTools` is persisted inside the existing `agentAllowedTools` list
  with a `!` prefix. No session schema change is needed, and cold-resumed
  children keep their scope.
- `lib/core/mcp_client_requests.dart` handles the client side of MCP for any
  transport. The approval, sampling, roots and elicitation hooks are injected:
  the agent service wires the first three, the app shell wires the sheet.
