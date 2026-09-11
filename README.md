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

## Startup behavior contract

- The chat shell and composer are interactive within **3 seconds** of launch,
  including with large local histories. No network, marketplace, plugin
  activation, or MCP handshake runs on the first-frame critical path; those run
  after the first frame in the background readiness queue.
- Runtime readiness has a **120-second global deadline**. Unfinished items open
  in a truthful **degraded** state with a per-item reason and `Retry`/`Disable`
  actions; the app stays usable and never blocks indefinitely. Local safety
  migration is never skipped by the deadline.
- `session_start` fires **exactly once** for every new root, implicit first,
  restored active, and subagent session, after the relevant plugin activation
  and session-visible skill mount have settled.
- Runtime-managed `skills/**/SKILL.md` contributions mount with **session
  scope**: the installing session sees them immediately, another session does
  not until the next-boot promotion, and they become global after one restart.
- Legacy installed/enabled plugins without a normalized runtime and a valid
  manifest-digest grant are disabled as **`Migration required`** and cannot
  execute legacy hooks or skills until the user runs inspect → approve →
  install. There is no silent auto-approval.
- Every plugin/MCP startup result has a durable, secret-scrubbed status:
  `Ready`, `Needs setup`, `Unsupported on this device`, `Migration required`,
  `Degraded`, `Failed`, or `Disabled`.

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

The startup/plugin-runtime release gate and its measured evidence (first-frame
budget, 120-second deadline, runtime skill + `session_start` integration, legacy
migration, APK SHA-256, and the physical-Android checklist) are recorded in
`docs/superpowers/audits/2026-09-10-startup-plugin-runtime-reliability.md`. The
physical-device smoke pass is `NOT EXECUTED` when no Android device/emulator is
attached; on-device sign-off remains open until a release owner completes that
checklist.
