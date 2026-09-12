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
- Runtime readiness has a **120-second global deadline**. An item still running
  at the deadline opens in a truthful **degraded** state; a queued non-local
  item becomes **skipped**. Both carry a per-item reason and `Retry`, and
  plugin/MCP rows offer `Disable`; the app stays usable and never blocks
  indefinitely. Local safety migration is never skipped by the deadline.
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
- Every normalized runtime plugin/MCP startup result has a durable,
  secret-scrubbed status: `Ready`, `Needs setup`, `Unsupported on this device`,
  `Migration required`, `Degraded`, `Failed`, or `Disabled`. Legacy
  migration-required rows surface the same `Migration required` state and a
  scrubbed reason from their own persisted row marker; they are not stored
  under the canonical runtime status store.

## Chat behavior contract

- The transcript, docks, and composer share **one centered, capped readable
  column** (`clamp(680px, 64% of the chat pane, 920px)`); the composer card is
  32px wider than the column and never exceeds the viewport. On a narrow phone
  the column collapses to the pane width and stays centered.
- Reasoning and tool output render as **compact disclosures that are collapsed
  by default** (28px/30px summary rows with a rotating chevron) and expand in
  place to a full-column, muted body with no heavy border. Nothing is
  auto-expanded.
- **Large histories are bounded.** A session folds only the tail window needed
  for display (40 folded items in chat, 200 in a subagent transcript) and shows
  an "N earlier messages · scroll up" affordance for the rest; opening a
  5,000-message session does not fold the whole history. Streaming tokens
  repaint only the live tail row and do not re-fold the transcript. Persistence
  coalesces rapid writes into one debounced, per-session-dirty encode and
  flushes pending writes on session switch and lifecycle pause.
- The workspace **folder picker is Studio-only**. The chat composer's folder
  chip shows the pinned folder read-only and opens Studio; folder change/clear
  lives only in Studio.
- **Read-Only is not a direct mode pick.** The mode pickers offer General, Full
  Access, Studio, and Control. `/preset plan` selects the read-only Plan policy
  (plan mode plus the read-only tool gate); approving the plan, `/plan off`, the
  Plan chip, or a direct mode pick releases the plan-owned read-only mode.
  `/permission read-only` remains functional but unadvertised for compatibility
  with existing sessions.
- Parity with the DSH web reference is **structural only**: no DSH branding,
  icons, product copy, CSS token names, or other assets are copied or imported.

The chat release gate and its measured evidence (focused suites, the full
876-test Flutter suite, `flutter analyze`, the debug APK SHA-256, and the
physical-device checklist) are recorded in
`docs/superpowers/audits/2026-09-10-chat-dsh-parity.md`. The physical-device
smoke pass is `NOT EXECUTED` when no Android device/emulator is attached;
on-device sign-off remains open until a release owner completes that checklist.

## Studio and Git behavior contract

- **GitHub login persists.** After one successful login the stored token keeps
  `isLoggedIn` true across sessions and restarts. A transient profile failure
  (5xx/network/decode) keeps the token and retries in the background; only a
  real `401` clears it. Studio never re-prompts on a transient failure.
- **A new chat inherits the last selection.** Creating a session seeds the
  last-used `(repo, branch, workspace folder)` when logged in, so a restart
  does not force a fresh repo/folder selection. A folder that no longer exists
  falls back to the per-session sandbox.
- **The Studio terminal is persistent and streaming.** Each terminal tab owns
  an independent pipe shell: shell state (`cd`, exports) survives across
  commands, output streams as it happens, and stdin is supported. It is a pipe
  shell, not a full TTY (no job control or terminal escape handling).
- **Repo binding is `(repo, branch)`.** Branch selection is threaded end-to-end:
  tree/read/blob-SHA requests carry the branch (`?ref=`), commits target the
  branch, and a missing ref surfaces an explicit error rather than silently
  reading the default branch.
- **The package manager is honest.** `apt update` works; `apt upgrade` /
  `full-upgrade` fail loudly (non-zero, stderr) instead of silently succeeding;
  `-y`/`--yes` are options, not packages; and a native `dpkg` failure surfaces
  its real non-zero exit code.
- **Git credentials are host-scoped and ephemeral.** Terminal/agent git against
  github.com authenticates from a credential helper scoped to
  `https://github.com`, injected into the spawned process environment only. It
  is never written to `.git-credentials` or any global/system config and is
  cleared on sign-out.

The Studio/Git release gate and its measured evidence (the end-to-end suite,
the full Flutter suite, `flutter analyze`, the debug APK SHA-256, and the
physical-device checklist) are recorded in
`docs/superpowers/audits/2026-09-10-studio-git-reliability.md`. The
physical-device pass is `NOT EXECUTED` when no Android device/emulator is
attached; on-device sign-off remains open until a release owner completes that
checklist.

## Browser desktop behavior contract

- **Desktop mode stays readable.** Desktop is a desktop UA plus the wide
  viewport for desktop layouts, without overview-mode auto-fit and without a
  device-derived CSS shrink. Text renders at full size by default.
- **Visual zoom is user-controlled.** The injected page scale is `userZoom`
  only (default 1.0, clamped 0.5–2.0). Toggling desktop/mobile never changes
  it, and `browser_resize` drives the layout viewport width without shrinking
  readable content.
- **Each tab keeps its own mode.** Toggling one tab's desktop/mobile (or
  resizing it) targets that tab's WebView only and never changes another tab.
- **Per-tab mode and zoom persist.** Each tab's `desktopMode` and `userZoom`
  restore across restarts (missing values fall back to the global default and
  1.0; out-of-range zoom clamps).

The Browser Desktop release gate and its measured evidence (the end-to-end
parity suite, the full Flutter suite, `flutter analyze`, and the
physical-device checklist) are recorded in
`docs/superpowers/audits/2026-09-10-browser-desktop.md`. The debug APK build
in that gate fails on the missing `google-services.json` and the
physical-device pass is `NOT EXECUTED` when no Android device/emulator is
attached; on-device sign-off remains open until a release owner completes
those items.

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
