# ovid_ai

An AI assistant Flutter app with a production plugin and MCP (Model Context
Protocol) compatibility layer.

## Plugin formats

Ovid installs plugins from GitHub (repo, branch, tag, or commit — no silent
fallback to `main` for pinned refs), local folders, ZIP archives, npm
packages, and discovered marketplace catalogs. Adapters normalize each of the
relevant vendor formats into a single internal manifest:

| Format | Contributions |
|---|---|
| Claude Code (`*.claude-plugin/`) | Commands, skills (with supporting assets), agents, hooks, stdio MCP servers |
| Codex (`AGENTS.md`-style manifests) | Agents, skills, hooks, MCP servers where declared |
| Generic MCP | Stdio command servers and Streamable-HTTP remote servers |
| Ovid built-in | Core tools, always available |

Every install normalizes into one manifest model with namespaced contribution
ids (`plugin:<id>/command:<name>`, `…/skill:<name>`, `…/agent:<name>`,
`…/hook:<event>:<ordinal>`, `…/mcp:<server>`, and tool aliases
`mcp:<id>/<server>/<tool>`), so colliding names never shadow each other.

## Permissions and activation

- One consolidated approval sheet (requested capabilities + dependencies)
  gates every install; capability deltas on upgrade require re-approval, and
  Plugin-owned secrets never reach prompts or logs.
- Installs are transactional: partial installs and failed upgrades roll back.
- New installs are visible in the **current session immediately** for the
  installing agent; the next app restart promotes them globally. Restart
  promotion is exactly-once per boot.
- Dependencies (Node/python runtimes, per-package sandboxes) are verified
  before activation; missing runtime ⇢ `Degraded`/`Failed`, never fake
  `working`.

## MCP servers

- Stdio servers spawn inside the sandbox (if provisioned) with per-server
  env, cwd, and timeouts; Streamable-HTTP servers POST JSON-RPC directly.
  Legacy SSE transport is rejected with an explicit message.
- Plugin-owned MCP servers are mounted and connected by the plugin runtime:
  upgrade removals are disconnected, uninstall cleans up servers and secrets,
  and `tools/list_changed` triggers real rediscovery.
- Credential-dependent servers show `Needs setup: <ENV>` and never auto-spawn
  before configuration; connection state is only ever `connected` after a
  real handshake.

## Android limits

- Streamable-HTTP MCP servers work on Android (plain HTTPS).
- Stdio MCP servers need a provisioned runtime inside the on-device sandbox;
  without it the server card shows `Unsupported on this device: <reason>`
  (missing runtime/ABI) — never a fake success.
- Plugin hooks/shell commands run inside the same sandbox boundary; arbitrary
  third-party desktop binaries are not guaranteed to run on Android. Ovid
  guarantees accurate detection, not emulation.
- Plugins never bypass session permission mode, Control-mode restrictions,
  workspace containment, or Android platform security.

## Verification

`flutter analyze`, `flutter test` (all regression groups clean), and
`flutter build apk --debug` constitute the release gate, together with a
device smoke pass of install → approve → session activation → restart
promotion → disable/uninstall cleanup. Preinstalled seed truthfulness is
pinned by the audit in
`docs/superpowers/audits/2026-09-06-preinstalled-plugin-mcp-runtime.md`.
