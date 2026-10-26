# Ovid Si

Ovid Si is an AI agent app for Android: a chat-first assistant that can also
edit code in a cloud workspace (Studio), drive a cloud browser, run scheduled
tasks, keep artifacts, and connect tools and MCP servers. The v2 client
in `lib/` is a thin client: in the shipped flow, model runs, sandboxes, git,
storage and billing verification happen on Ovid's servers (`server/`, `cloud/`).
A user can supply their own provider key (BYOK); the gateway stores it and uses
it server-side (`cloud/apps/gateway/src/routes/byok.ts`).

> **Status: internal testing only.** This is not a public release. It is on the
> Play **internal testing** track (four testers, as recorded by the owner), has
> no Play subscription created yet, and is missing several screens' backends.
> Do not describe it as launched, and do not paste release notes from it. The
> honest gap list is [`docs/audit/FEATURE_GAPS.md`](docs/audit/FEATURE_GAPS.md).

---

## Verified state (2026-10-26)

Measured at commit `b412960d` (`feat/ovid-si-rebuild`).

| Check | Result |
|---|---|
| `flutter analyze --no-pub` | 0 issues |
| `flutter test --no-pub` | 6008 passed, 2 skipped, 0 failed |
| Pre-existing skips | `release_flags_test.dart`, `ui_finish_03_account_test.dart` (environment-gated) |

**What is ON vs OFF:**

- **Voice is OFF.** `lib/core/voice_capability.dart` sets `kOvidVoiceEnabled = false`. The test harness and on-device capability probe exist, but the emulator has no usable speech locale, so there is **zero real-audio evidence**.
- **Studio live preview platform view is registered.** `ovid/studio-preview` is registered in `MainActivity.kt` (added in `b412960d`). Live preview remains **blocked** at the wiring layer because there is no preview producer / tunnel (`docs/audit/FEATURE_GAPS.md` A1).
- **FCM/deep-link fresh-process routing is proven end-to-end on an emulator** (cold/warm deep link, invalid-token negative control, notification-tap cold/warm). FCM *delivery* is blocked on `GOOGLE_APPLICATION_CREDENTIALS` and a signed-in account.
- **Authenticated acceptance has never been performed.** The signed APK was installed on an API-34 emulator and launched to sign-in without crashes; that is an install/boot smoke test only.

**Top blockers:**

1. No preview producer / tunnel for Studio live preview.
2. FCM delivery needs `GOOGLE_APPLICATION_CREDENTIALS` + a signed-in account.
3. Voice cannot be claimed as working without a device with a usable speech locale.
4. No authenticated acceptance pass has been done.

---

## Release evidence (2026-10-26)

A signed release APK was built from `b412960d` and verified with `apksigner verify -v`:

| Property | Value |
|---|---|
| File size | 35,884,740 B |
| SHA-256 | `7914a3ba644c98fa98a4f1b20d13142236ad581e08ce8574f6bd5b95253d19a1` |
| Signers | 1 |
| Signing scheme | v2-signed, **not debug** |
| Certificate SHA-256 | `96d76a02dc7da1790706bd324868273863c8bf01d3d3fbf72048483c133f7755` |
| Package | `com.dhanuk.ovidai` |
| versionName | `1.0.0` |
| versionCode | `3` |
| minSdk | 24 |
| targetSdk | 36 |
| ABIs | **x86_64 only** |

**Limitations:**

- **x86_64-only ABI.** The verified APK is **not Play-acceptable** because it ships x86_64 only. Do not call this a production artifact.
- **Historical signed-install evidence is uncorroborated.** A previously referenced signed install (`cbe92360…`, 34,612,835 B) could not be found anywhere in the repositories; treat it as uncorroborated.
- The APK installed cleanly on an API-34 emulator, launched to the sign-in screen, and showed no crashes. That is an install/boot smoke test, not authenticated acceptance.

---

## Quick start

Requirements: Flutter with Dart SDK `^3.12.2` (`pubspec.yaml`), and for a
release build an Android keystore plus `android/app/google-services.json`
(both gitignored).

```bash
flutter pub get --enforce-lockfile
flutter run                     # debug build on an attached device/emulator
```

Android identity: package `com.dhanuk.ovidai`, minSdk 24, targetSdk 36. The app
version is `1.0.0+3` (`pubspec.yaml`).

Release builds (internal testing):

```bash
flutter build appbundle --release \
  --dart-define=OVID_REVENUECAT_GOOGLE_KEY=<public Play SDK key>
```

RevenueCat keys are **not** baked in; without the define the app falls back to
plain Play Billing. The full store setup is
[`docs/play/REVENUECAT_SETUP.md`](docs/play/REVENUECAT_SETUP.md). A release
build cannot be switched to the RevenueCat Test Store — that flag is
debug/profile only.

Server and cloud components are separate deployments; the account service has
its own guide at [`server/account/DEPLOYMENT.md`](server/account/DEPLOYMENT.md).

## How to test

```bash
# Flutter unit + widget suite
flutter test --no-pub        # 6008 passed, 2 skipped at commit b412960d

# Static analysis
flutter analyze --no-pub     # 0 issues at commit b412960d

# Python tooling tests (no server dependencies)
python3 -m unittest discover -s tool -p '*_test.py'
```

For a large or loaded machine, use the bounded runner instead of a bare
`flutter test` — it owns a lock, batches files, and writes machine-readable
evidence:

```sh
python3 tool/run_flutter_suite.py \
  --flutter /absolute/path/to/flutter \
  --output /tmp/flutter-suite-unique-run \
  --lock /tmp/opencode/parallel-flutter.lock \
  --batch-size 20 --batch-timeout 300 --lock-timeout 900
```

Use a fresh output directory name with an existing parent. All local runs
sharing an SDK must use the same lock path. On manual CI dispatch,
`bounded_flutter_suite=true` selects this runner.

Cloud tests (gateway, worker, packages) run under pnpm from `cloud/`; the
`cloud` workflow provisions PostgreSQL 16 and Redis. Server tests are pytest
against `server/account/requirements.txt` plus a job-local PostgreSQL.

CI: `.github/workflows/build.yml` (Android build), `cloud.yml` (cloud tests),
`device-test.yml` (legacy debug-emulator diagnostics, manual dispatch). The
repo's living TODO claims the suites are green; re-run them before treating
that as evidence.

## Where things live

| Path | What |
|---|---|
| `lib/ui/v2/` | The shipped v2 shell: 50 screens plus the adapters in `lib/ui/v2/app/` |
| `lib/ui/design/` | The design system — tokens, theme, components, motion, contrast (`o_tokens.dart`, `o_theme.dart`, `o_components.dart`, `o_motion.dart`, `o_contrast.dart`) |
| `lib/core/` | Client services: cloud facade, billing, auth, sandbox, storage, state |
| `docs/audit/` | Current audit: `SCREEN_INVENTORY.md` (50 screens), `SCREENS_AND_FEATURES.md`, `FEATURE_GAPS.md` (what does not work, with file citations) |
| `docs/design/` | Design contracts and the Figma sheet workflow (`FIGMA_SETUP.md`, `MINIMAL_UI_CONTRACT.md`) |
| `docs/play/` | Play Console worksheets (`DATA-SAFETY.md`, `STORE-LISTING.md`, `REVENUECAT_SETUP.md`, `PLAY_COMPLIANCE_AUDIT.md`) |
| `docs/architecture/` | Scale, security and the 100 M-user plan |
| `server/` | Python account, billing, collaboration, mint and security services |
| `cloud/` | TypeScript gateway, worker, mint, browser, sandbox and storage packages |
| `tool/` | Generators and test runners (`figma_sheet.py`, `run_flutter_suite.py`, `release_*.py`) |
| `android/` | Manifest, network security config, signing config |

The design system is the only source of colour, type, spacing and motion in the
v2 UI; screens must not hard-code those values (`test/design/raw_literal_ratchet_test.dart`).

The Figma file holds all 50 screens in light and dark as editable vectors and is
regenerated from code — see [`docs/design/FIGMA_SETUP.md`](docs/design/FIGMA_SETUP.md).

---

# Behavior contracts

These are the acceptance language for the app. They describe intended behavior,
not a claim that every gap is closed: the current shortfalls are tracked screen
by screen in [`docs/audit/FEATURE_GAPS.md`](docs/audit/FEATURE_GAPS.md).

## Account and shared-data server deployment

The [account deployment guide](server/account/DEPLOYMENT.md) covers direct
PostgreSQL private-sync and selectable PostgreSQL collaboration composition,
durable account cleanup, collaboration/share routes, bounded retention and
nonsecret Docker/systemd/Caddy templates. Configured cleanup authorities remain
active when their HTTP routes are disabled. Local tests verify code behavior;
production activation and gateway integration require the deployment acceptance
steps in that guide.

Collaboration defaults to SQLite until deliberately migrated with
`LIVE_COLLABORATION_BACKEND=postgres`. PostgreSQL shares the account
database/schema, checks its persisted authority identity, and retains
cleanup/retention with HTTP disabled. The guide includes explicit schema
deployment, offline SQLite import, restart and rollback boundaries; runtime
never automatically migrates to PostgreSQL.

## Plugin formats

**Not shipped in the v2 client.** The v2 app has no plugin installer or
marketplace screen: `lib/` contains no plugin runtime or `Plugins` page, and
the Connectors screen adds catalogue entries (including built-in plugin/MCP
rows) rather than installing a plugin package. The format and activation
contract below describes the retired v1 runtime; do not cite it as a current
v2 capability.

The retired v1 runtime installed plugins from GitHub (repo, branch, tag, or
commit — no silent fallback to `main` for pinned refs) and discovered
marketplace catalogs (each marketplace is itself a GitHub repo). Its Plugins
screen had exactly one "+" which opened one sheet: fetch a plugin from GitHub,
or add a marketplace (with the existing marketplace list and remove). The core
install transaction still accepts every source type (local folder, ZIP,
npm, pasted config, direct MCP) for forward-compat; the UI offers only
the GitHub route. Adapters normalize each of the
relevant vendor formats into a single internal manifest:

| Format | Contributions |
|---|---|
| [CC] (`*.claude-plugin/`) | Commands, skills (with supporting assets), agents, hooks, stdio MCP servers |
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
- **Large histories stay cheap.** The v2 transcript is a lazy list: it builds
  only the rows in and around the viewport, so opening a 5,000-message session
  does not build the whole history. The legacy v1 transcript folds to a tail
  window (40 items in chat, 200 in a subagent transcript) with an "N earlier
  messages · scroll up" affordance. Streaming tokens repaint only the live tail
  row. Persistence coalesces rapid writes into one debounced, per-session-dirty
  encode and flushes pending writes on session switch and lifecycle pause.
- The workspace **folder picker is Studio-only**. The composer's "+" sheet has a
  **Studio folder** row that reports whether a folder is pinned and opens
  Studio; folder change/clear lives only in Studio.
- **The mode picker offers Read-Only, General, Full Access and Studio.**
  `AgentMode` has exactly those four values (`lib/core/cloud/models.dart`) and
  `v2PermissionModes` lists them (`lib/ui/v2/chat/permission_sheet.dart`).
  There is no Control mode in the shipped client. `/preset plan` also selects
  the read-only Plan policy (plan mode plus the read-only tool gate);
  approving the plan, `/plan off`, the Plan chip, or a direct mode pick
  releases the plan-owned read-only mode. `/permission read-only` selects the
  same mode as the Read-Only row.
- Parity with the DSH web reference is **structural only**: no DSH branding,
  icons, product copy, CSS token names, or other assets are copied or imported.

The chat release gate and its measured evidence (focused suites, the full
Flutter suite, `flutter analyze`, the debug APK SHA-256, and the
physical-device checklist) are recorded in
`docs/superpowers/audits/2026-09-10-chat-dsh-parity.md`. An emulator
smoke pass (install → launch → sign-in, no crashes) was done at commit
`b412960d`; authenticated on-device sign-off remains open.

## Studio and Git behavior contract

- **GitHub login persists.** After one successful login the stored token keeps
  `isLoggedIn` true across sessions and restarts. A transient profile failure
  (5xx/network/decode) keeps the token and retries in the background; only a
  real `401` clears it. Studio never re-prompts on a transient failure.
- **A new chat inherits the last selection.** Creating a session seeds the
  last-used `(repo, branch, workspace folder)` when logged in, so a restart
  does not force a fresh repo/folder selection. A folder that no longer exists
  falls back to the per-session sandbox.
- **There is no in-app Studio terminal in the v2 client.** The workspace shows
  the file tree, the open file and a sync action; the agent runs shell commands
  inside the cloud sandbox. The persistent pipe-shell tabs described in earlier
  contracts are not part of the shipped v2 UI.
- **Repo binding is `(repo, branch)`.** Branch selection is threaded end-to-end:
  tree/read/blob-SHA requests carry the branch (`?ref=`), commits target the
  branch, and a missing ref surfaces an explicit error rather than silently
  reading the default branch.
- **The package manager is honest.** `apt update` works; `apt upgrade` /
  `full-upgrade` fail loudly (non-zero, stderr) instead of silently succeeding;
  `-y`/`--yes` are options, not packages; and a native `dpkg` failure surfaces
  its real non-zero exit code.
- **Git credentials are host-scoped and ephemeral.** Agent git against
  github.com authenticates from a credential helper scoped to
  `https://github.com`, injected into the spawned process environment only. It
  is never written to `.git-credentials` or any global/system config and is
  cleared on sign-out. Server-side git jobs resolve a **per-user** GitHub token
  from that user's connector credential and fail the job when it is absent
  (`cloud/apps/worker/src/studioGit.ts`).

The Studio/Git release gate and its measured evidence (the end-to-end suite,
the full Flutter suite, `flutter analyze`, the debug APK SHA-256, and the
physical-device checklist) are recorded in
`docs/superpowers/audits/2026-09-10-studio-git-reliability.md`. An emulator
smoke pass (install → launch → sign-in, no crashes) was done at commit
`b412960d`; authenticated on-device sign-off remains open.

## Browser desktop behavior contract

**Not shipped in the v2 client.** The v2 browser viewer has no desktop/mobile or
zoom controls; it exposes attach, take-over, tap/type/scroll and tab switch
(`lib/ui/v2/browser/browser_live_page.dart`). The server still supports
`browser_resize`, but the contract below describes the retired v1 browser
surface and is not a current UI capability.

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
`docs/superpowers/audits/2026-09-10-browser-desktop.md`. An emulator
smoke pass (install → launch → sign-in, no crashes) was done at commit
`b412960d`; authenticated on-device sign-off remains open.

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
- Every MCP row, card, detail header, and diagnostics entry shows the
  durable canonical startup status plus reason (`Ready · connected`,
  `Failed · <scrubbed>`, `Needs setup`, `Disabled`); a server that never
  ran reads `Not started`, never `Connected`/`Not connected`. Connect,
  failure, credential-block, and disconnect outcomes are recorded durably
  under the server's canonical id.

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

## Control mode device actions

**Not shipped in the v2 client.** `AgentMode` has no `control` value
(`lib/core/cloud/models.dart:769`; `state.dart` records that `'control'` was
retired), the v2 picker offers Read-Only, General, Full Access and Studio, and
no Dart device tool (`device_key`, `device_scroll`, …) exists in `lib/`. The
contract below describes the retired v1 surface and is not a current
capability.

- A floating Ovid field steers the run while Control mode drives other apps:
  an accessibility overlay (no new permission), draggable by its dot handle,
  with an X that hard-stops the run and a send arrow — shown while text is
  typed — that delivers into the next AI request exactly like the composer
  send. It is shown only while a Control session is active.
- The agent's hands are human-equivalent and honestly reported: `device_key`
  (closed vocabulary `enter | volume_* | media_*`; anything else refused as
  `BAD_KEY`), `device_long_press` (default 600 ms, clamped 200–3000 ms),
  `device_scroll` (non-scrollable refused as `NOT_SCROLLABLE`; below-API
  fallbacks named), tap retries up to 3 clickable ancestors, and `device_type`
  reports `typed`/`submitted` separately with the native reason verbatim.
- Stale nodes are refused as `INVALID_NODE` (re-read hint) before anything
  touches the screen; password and non-editable targets stay refused. Stop
  cancels pending device work via a generation token
  (`cancelled: superseded by a newer run/stop`); an already-dispatched gesture
  runs to completion (Android limit, documented).

## Verification

Python tool discovery uses `python3 -m unittest discover -s tool -p '*_test.py'`.
Deployment configuration tests use the standard library; runtime integration
checks explicitly skip if their server dependencies are absent. The server CI
job installs `server/account/requirements.txt` and runs those integration checks
again, plus pytest against a job-local PostgreSQL 16 service.

CI's default Flutter `Test` step runs every tracked `test/**/*_test.dart`
file serially. New files enter that manifest when included in the commit checked
out by CI. For filesystem coverage (including local untracked/nested tests), use
the bounded runner after `flutter pub get --enforce-lockfile` (see **How to
test** above).

The runner executes batches sequentially with `--no-pub --concurrency=2 --machine`.
`inventory.json`, per-attempt logs, tree hashes and `summary.json` account for all
discovered files. Missing completion, timeout, test/protocol failure or an empty
inventory fails the run; a successful diagnostic retry does not erase a failure.
New tests appearing during execution fail coverage; concurrent source changes are
reported in `tree_changes` and require a fresh run for release evidence. The
runner's subprocess tests validate orchestration, not Flutter application behavior.

`flutter analyze`, `flutter test` (all regression groups clean), and
`flutter build apk --debug` constitute the release gate, together with a
device smoke pass of install → approve → session activation → restart
promotion → disable/uninstall cleanup. Preinstalled seed truthfulness is
pinned by the audit in
`docs/superpowers/audits/2026-09-06-preinstalled-plugin-mcp-runtime.md`.

The startup/plugin-runtime release gate and its measured evidence (first-frame
budget, 120-second deadline, runtime skill + `session_start` integration, legacy
migration, APK SHA-256, and the physical-Android checklist) are recorded in
`docs/superpowers/audits/2026-09-10-startup-plugin-runtime-reliability.md`. An
emulator smoke pass (install → launch → sign-in, no crashes) was done at
commit `b412960d`; authenticated on-device sign-off remains open.
