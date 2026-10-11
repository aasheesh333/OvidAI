# 03 — Plugins & MCP UI

## Scope
- `lib/ui/plugins_screen.dart` (4035 lines): PluginsScreen, add-plugin sheet, PluginDetailScreen, McpDetailScreen, MCP credentials / runtime-install / JSON-editor sheets
- `lib/ui/plugin_settings_panel.dart`, `lib/ui/plugin_install_progress.dart`, `lib/ui/plugin_permission_sheet.dart`, `lib/ui/mcp_oauth_sheet.dart`
- Calls followed into `lib/core/` (mcp_service.dart, plugin_*.dart, hook_service.dart) where needed to confirm a bug.

## Goal
Product requirement: every Claude Code MCP server and plugin must work as in Claude Code (except OS-limited), and MCP/plugin usage must be tracked and visible. Check the UI against that: install flows (GitHub repo / marketplace), enable/disable, errors, status (connected/degraded/failed), OAuth, env/headers editing, per-tool listing, usage stats. Plus the general review goals in README.md (bugs, states, UX, a11y, perf, security).

Known context (not re-derived here): PostToolUse hooks are fire-and-forget; MCP server→client requests (ping/roots/sampling/elicitation) unanswered; OAuth lacks discovery/DCR and uses paste-back redirect; no per-MCP/plugin usage aggregation; grants stored in SharedPreferences.

## Status
in progress

---

## 1. PluginsScreen (library: search, chips, MCP section, plugin list, marketplaces)
**What it is / how reached:** `PluginsScreen` (`plugins_screen.dart:803-1218`), pushed from the sidebar/settings and from the startup dashboard's "Open Plugins" deep link (`focusCanonicalId`). Layout: search bar, category chips (All/Agent/MCP/Tool/Runtime), the "CONNECTED TOOLS · MCP SERVERS" section (`_McpSection`, `:2629-2694`), the Installed/Available plugin list (`PluginCard`), then marketplace cards (`_MarketplaceCard`, `:1223-1336`). The app bar has Refresh (re-syncs marketplaces) and a single "+" that opens the add sheet.

**Findings**
- **P0 · parity / missing flow · `plugins_screen.dart:2666-2675`, `:2699`.** You can't add an MCP server (stdio command, HTTP/SSE URL, or pasted `mcpServers` JSON) anywhere in the UI. The empty state says "Use + to add from GitHub", but the + sheet (`:473-693`) only fetches plugin repos and adds marketplaces. `_parseMcpConfig` (`:2699`) is used only by the test seam `parseMcpConfigForTest`, and `AppState.addCustomMcpServer` (`state.dart:9281`) is called only from the agent tool (`agent_service.dart:15098`). **User impact:** the most common Claude Code flows (`claude mcp add <name> -- npx …`, `claude mcp add --transport http <url>`, `claude mcp add-json`, importing a Claude Desktop or `.mcp.json` config) can't be done by hand. **Fix:** add an "MCP server" tab to the + sheet with three modes: Command (name, command, args, env rows), Remote (URL, transport http/sse, header rows) and Paste JSON (`parseMcpConfig`, previewing each entry and its `ignoredKeys`). Wire all three to `addCustomMcpServer`, store env through `setMcpEnv(strict:true)` and headers through `setMcpHeaders`, then call `connectMcpServer`.
- **P1 · data loss / false copy · `:1319-1327` + `state.dart:7404-7428`.** The confirm dialog for removing a marketplace says "Plugins already installed from it stay installed." In fact `removeMarketplace` calls `uninstallPlugin` on every installed plugin from that marketplace (`state.dart:7424`), which wipes its grant, secrets and dependency sandbox. **Fix:** either keep installed plugins (drop only the uninstalled catalog rows) or change the copy to "Also uninstalls N plugins: a, b, c" and list them.
- **P1 · error state · `:911-920`.** `_syncCatalogs` swallows every exception and ignores the per-repo result messages from `syncMarketplaceCatalogs`/`fetchMarketplaceCatalog`. The Refresh button therefore never reports success or failure, and offline or a bad repo shows nothing. **Fix:** collect each repo's message. Show an inline banner such as "Couldn't refresh 2 marketplaces · Retry", a last-synced time per `_MarketplaceCard`, and an offline state.
- **P1 · functional · `:1005-1012`, `:1070-1077`.** Search and category chips don't filter the MCP section. Selecting "Agent" or searching "slack" still shows every MCP card above the results, and the card count ignores MCP servers. **Fix:** filter `servers` by `_query` (name, description) and render the section only when `_cat` is `All` or `MCP`.
- **P2 · performance · `:2677-2689`, `:963-1013`.** All MCP cards are built eagerly in a `Wrap` inside a `SliverToBoxAdapter`, each with a `GlobalKey` and two `durableMcpStatus` lookups. The whole tree rebuilds on every `AppState` notification, and `installedMcpIds` calls `mcpServerForPlugin` for every plugin (O(plugins × servers)). A marketplace with hundreds of servers will jank. **Fix:** use `SliverList.builder`/`SliverGrid` for MCP cards, memoize the derived lists by an `AppState` revision counter, and narrow the listener (a `Selector` or `ValueListenable` for plugins and servers).
- **P2 · copy · `:1025`.** The hint "Search ${items.length} plugins…" uses the *filtered* count, so it shrinks as the user types or picks a chip. **Fix:** use `app.plugins.length`.
- **P2 · copy · `:2662`.** A static "LIVE" tag sits on the MCP header whatever the servers' state. **Fix:** replace it with "N connected · M need setup".
- **P2 · responsive · `:930`.** The toolbar height comes from `textScaler.scale(20) > 28 ? 104 : 64`, a hard jump. **Fix:** let the `AppBar` size itself (`toolbarHeight: null`) and put the actions in an overflow menu at large text scales.

**Missing features (vs Claude Code `/plugin` and `/mcp`)**
- Installed / Discover / Marketplaces tabs. Installed plugins and the catalog share one long list.
- Plugin **update**: there is no update check or update action (no `updatePlugin`/`updateAvailable` anywhere in `lib/ui` or `plugin_runtime.dart`), and no marketplace update or auto-update.
- An MCP status summary like `/mcp`: connected, failed, needs auth, with a one-tap Reconnect-all.
- **Usage** (product requirement): no MCP or plugin row shows call counts, last used, error rate or tokens. This is the known gap that there's no per-MCP/plugin aggregation. The list should show "N calls · last used 2h ago" per row and sort by most used.

**Test to add**
- Widget test: type "zzz" in search and assert no `McpCard` is rendered. Select the "Agent" chip and assert the MCP section is hidden.
- Widget test: removing a marketplace with one installed plugin either keeps it installed or shows the dialog listing it. The copy must match the behaviour.
- Widget test: `syncMarketplaceCatalogs` throws or returns a failure message, and the error banner is shown.

---

## 2. Add plugin / marketplace sheet (`showPluginAddSheet`)
**What it is / how reached:** the "+" in the app bar and the empty-state buttons (`:473-693`). It has one repo field with two actions: "Fetch from GitHub" (`_runSourceInstall`) and "Add marketplace" (`addMarketplace` then `fetchMarketplaceCatalog`). The marketplace list is shown below with remove buttons.

**Findings**
- **P0 · destructive, no confirm · `:673-680`.** The trash icon in "YOUR MARKETPLACES" calls `app.removeMarketplace(m)` straight away, with no confirmation (unlike `_MarketplaceCard`, `:1319`). That call uninstalls every installed plugin from the marketplace (`state.dart:7424`), so one mis-tap destroys plugins, grants and secrets. **Fix:** reuse `showDeleteConfirmationDialog` with the plugin count (see §1), or remove the duplicate list from the sheet since the screen already has marketplace cards.
- **P1 · functional · `:697-706`.** `_githubSourceFromInput` handles input differently from `AppState.normalizeMarketplace` (`state.dart:7381-7387`):
  - `github.com/o/r` (no scheme) becomes owner `github.com`, repo `o`.
  - `https://github.com/o/r.git` becomes repo `r.git`.
  - `https://github.com/o/r/tree/main/plugins/foo` loses the ref and the subdirectory, so the repo root is installed instead of the plugin, which fails or installs the wrong thing.
  - `owner/repo/extra` is silently accepted.
  - `git@github.com:o/r.git` is rejected.

  **Fix:** normalize with `normalizeMarketplace`, parse `tree/<ref>/<path>` into `GithubPluginSource(ref:, subPath:)`, accept `owner/repo@ref` and `#ref`, and reject other extra segments with a clear error.
- **P1 · validation copy · `:605-608`.** "Add marketplace" gives the same error for invalid input and for a duplicate ("…that is not already added"). **Fix:** have `addMarketplace` return a reason enum (`invalid`/`duplicate`) and show a specific message.
- **P2 · feedback · `:603-627`.** Marketplace import progress is only an "Importing…" snackbar followed by a result snackbar, and the result message can be raw parse text (`state.dart:7697-7699`, "could not parse it: $parseError"). **Fix:** show a progress row inside the sheet or the new marketplace card, and map parse errors to "marketplace.json is invalid (line N)".
- **P2 · leak · `:475`.** `repoC` (`TextEditingController`) is never disposed. **Fix:** move the sheet into a `StatefulWidget`, or dispose it in `.whenComplete`.
- **P2 · UX · `:552-561`.** There is no paste-from-clipboard affordance, no recent repos, and no `TextInputAction.go` submit. **Fix:** add `textInputAction: TextInputAction.go` and an `onSubmitted` that runs Fetch.

**Missing features:** a local or ZIP source (core supports it according to the doc comment at `:325-327`; Storage Access Framework on Android), a non-GitHub git URL, and a preview of the plugin's manifest (name, description, contributions) before the approval sheet.

**Test to add:** unit tests for `_githubSourceFromInput` covering `github.com/o/r`, `.git`, `/tree/ref/sub`, `git@…`, and three-segment input. A widget test that the sheet's remove-marketplace button requires confirmation.

---

## 3. Source install flow (`startPluginInstallForTest` / `_runSourceInstall`)
**What it is / how reached:** "Fetch from GitHub" or a row's Install button runs inspect, then the consolidated approval sheet, then `AppState.installPlugin` (`:343-422`). `_runSourceInstall` (`:716-799`) opens the live-progress sheet and reports the result in a snackbar.

**Findings**
- **P1 · raw errors · `:358`, `:777-790`.** The user sees `'source resolution failed: $e'`, `'Install crashed: $crash'` and `'Install failed: ${result.error}'` in a snackbar and in the progress summary. These are Dart exception strings (SocketException, FormatException, HTTP 404/403 rate-limit). **Fix:** add a `describeInstallFailure(Object e)` mapping (offline, repo not found or private, GitHub rate limit, so "sign in to GitHub", no plugin manifest found, dependency install failed) and keep the raw text behind a "Details" expander in the progress sheet.
- **P1 · status copy · `:782-787`.** The success text is hard-coded "restart Ovid to enable it everywhere (this session: contributions pending restart)" whatever `result.record` says, so a session-active install is described wrongly. The degraded text lists only `degradedNames` and drops `result.probeFailures` (`plugin_runtime.dart:465`). **Fix:** build the message from `result.record` (scope and `promoteOnNextBoot`) and include the probe failures.
- **P2 · orphan row · `:402`, `:426-441`.** `_catalogRowFor` adds a new `PluginItem` (with `source: null`) to `app.plugins` *before* the install. If the install fails, the row stays, and the detail screen shows it as "Not installable — this catalog row has no plugin package behind it". Even after success the row has no source, so it can never be updated or reinstalled. **Fix:** create the row only on `status != failed`, and set `source: '${owner}/${repo}'` from the inspected source.
- **P2 · lost logs · `:745-798`.** `result.logs` (`plugin_runtime.dart:468`) is never stored, and the detail screen's "Install log" shows synthetic lines (§5). **Fix:** persist the last N log lines in the activation record.
- **P2 · cancellation · `:728-743`.** Closing the progress sheet doesn't cancel the install, and the sheet has no Cancel action (see §8). That's acceptable, but the copy should say "Install continues in background".

**Test to add:** a fake `PluginRuntimeManager.inspect` throws a `SocketException`, and the snackbar shows the mapped copy, not the exception. A failed install leaves no new row in `app.plugins`.

---

## 4. PluginCard (list row)
**What it is / how reached:** one row per catalog or installed plugin (`:1338-1676`). It shows the category, format and activation badges, hook chips, author/version/installs, an availability line, the durable status, an enable Switch (installed rows only), a Delete icon, and a status glyph. Tapping the row opens `PluginDetailScreen`.

**Findings**
- **P1 · false failure status · `:1544-1564` (copied at `:1720-1737` and `:1924-1942`).** After enabling, the "probe" calls `AgentService.I.pluginToolNames`, which returns `[]` in two common cases:
  - (a) A registered Claude Code plugin that contributes only **hooks** or **MCP servers**. `toolContributionsForPlugin` keeps only `isRosterTool` (command/skill/agent; `plugin_registry.dart:158-161`, `agent_service.dart:6224-6230`).
  - (b) The enable itself failed. `enablePlugin` swallows `PluginRuntimeManager.enable` errors (`state.dart:2632-2638`) and leaves `enabled=false`, and `_pluginToolNames` returns `[]` for disabled rows (`agent_service.dart:6191`).

  Both cases write `ServiceHealth.failed`, "probe failed: contributes no agent tools, skills, hooks, or MCP servers". In case (a) that is false (the plugin does contribute hooks/MCP). In case (b) the switch silently snaps back with no message and the wrong reason. **Fix:** make `enablePlugin` return `({bool ok, String? error})`. Probe all contribution kinds (`PluginContributionRegistry` hooks and `mcpServersForSession`, not just roster tools). Show a snackbar on failure. Fold the three copies into one `_setPluginEnabled(context, plugin, bool)` helper.
- **P1 · destructive semantics · `:1576-1602`.** The Delete icon shows on **every** row, including uninstalled catalog/marketplace rows. On a catalog row it runs `uninstallPlugin` and then `app.plugins.remove`, so the catalog entry vanishes until the next marketplace sync. There are also two destructive actions with different meanings: "Delete" (uninstall and drop the row; card and detail app bar) and "Uninstall" (detail body `:2143`, keeps the row, no confirmation). **Fix:** show one "Uninstall" action, with confirmation, on installed rows only. Offer "Remove from list" only for user-added rows.
- **P2 · discoverability · `:1609-1615`.** Uninstalled rows show a non-interactive `download_outlined` glyph that looks like a button. Install is only reachable from the detail page. **Fix:** replace the glyph with an "Install" `TextButton` that runs the same `pluginInstallRouteForTest` switch as the detail page (factor that switch out of `:2005-2055`).
- **P2 · a11y · `:1534-1572`.** The Switch has no label, so TalkBack announces "Switch, on" without the plugin name. **Fix:** wrap it in `Semantics(label: 'Enable ${plugin.name}', toggled: …)` or use `MergeSemantics` with the title. The same applies to the MCP card Switch (`:3213`) and the detail switches (`:1711`, `:3381`).
- **P2 · status honesty · `:1657-1665`.** Legacy rows without a runtime id still get a green `check_circle` from the `enabled` flag alone, which contradicts the "never infer from booleans" rule this file applies elsewhere. **Fix:** show neutral `help_outline` unless a probe recorded `working`.
- **P2 · layout · `:1415-1670`.** The card stacks a 40px icon, title wrap, four text lines, a full description, and then a right-aligned control column. The description isn't clamped, so a 2,000-character marketplace description makes a very tall card. **Fix:** set `maxLines: 3` and ellipsis on the description (the full text is on the detail page).

**Test to add:** registering a hook-only plugin and toggling it on must not produce a `ServiceHealth.failed` status. Making `PluginRuntimeManager.enable` throw must show a failure snackbar with the real reason.

---

## 5. PluginDetailScreen (+ `_PluginDiagnostics`, `_EffectiveGrantRow`, `_InstallLogRow`)
**What it is / how reached:** tapping a `PluginCard` (`:1679-2213`). The app bar has an enable Switch and Delete. The body has the header, durable status box, Install/Enable/Disable button, Retry activation, Reset to defaults, Uninstall, Overview, the manifest-declared Settings (`PluginSettingsPanel`), and diagnostics: contributions, aliases, conflicts, MCP servers, hooks, dependencies, compatibility, permissions and install log (`:2221-2427`).

**Findings**
- **P1 · security / functional · `:2113-2122`.** "Reset to defaults" only sets `plugin.enabled = true` and persists. It:
  - bypasses `AppState.enablePlugin`, so `PluginRuntimeManager.enable` never runs and contributions aren't mounted while the UI says enabled;
  - bypasses the fail-closed `migrationRequired` gate (`state.dart:2639` refuses to enable such rows);
  - resets no settings at all, even though it reports "Plugin reset to defaults".

  **Fix:** remove it, or implement a real reset: clear `NativePluginConfigStore` values for `settingsFields`, then `await app.enablePlugin(plugin)` and report its result.
- **P1 · destructive, no confirm · `:2143-2151`.** "Uninstall" tears down the grant, owned secrets, the dependency sandbox and plugin-owned MCP servers (`state.dart:2489-2560`) with no confirmation and no feedback. **Fix:** use `showDeleteConfirmationDialog` with copy listing what will be removed, then show a snackbar.
- **P1 · plugin MCP not actionable · `:2310-2360`.** Plugin-owned MCP servers appear as monospace text rows only. There's no tap to open `McpDetailScreen`, no Connect, no credential entry and no tools list. **Fix:** render each owned server as a tappable `ListTile` that opens `McpDetailScreen(server: s)`, with an inline "Set up" button that calls `connectMcpServer`.
- **P1 · misleading status · `:2321-2329`.** "Needs setup: X must be configured" is shown whenever the server *declares* credentials, even after they've been stored; `missingCredentialsFor` is never checked. **Fix:** use a `FutureBuilder` on `McpService.I.missingCredentialsFor(s)`. Show the warning only for missing names, and otherwise "Credentials configured ✓" with an Edit action.
- **P1 · usage tracking, misleading · `:2385-2389`.** "Last result: … (fired N, failed M this boot)" reads `HookService.I.fired`/`failed`, which are **process-global** counters (`hook_service.dart:405-406`), but the line sits inside one plugin's diagnostics. **Fix:** keep per-plugin hook counters in `HookService` (fired, failed, last error, last fired, breaker state, keyed by `pluginId`) and show them here. Until then, label the line "all plugins".
- **P2 · feedback · `:2081-2087`.** "Retry activation" ignores the returned `PluginActivation` and has no busy state, so a double tap starts two retries. **Fix:** add a busy flag plus a snackbar showing the resulting activation.
- **P2 · fake content · `:2196-2207`, `:2190-2195`.** The "Changelog" section is placeholder text ("v… — declared by plugin manifest."). Legacy rows show "Permissions · Declared by plugin manifest" with a green verified icon, which suggests a verification that never happened. **Fix:** remove both, or show the repo's CHANGELOG.md and the real declared hooks only.
- **P2 · fake log · `:2569-2596`.** "Install log" prints three fixed lines ("staged → committed → probed") instead of the real `PluginInstallResult.logs`. **Fix:** persist the logs (see §3) and render them in `ProgressLogView` with Copy.
- **P2 · performance · `:2542-2543`, `:2575-2576`.** The `FutureBuilder` futures (secure-storage grant read, activation record) are created inside `build`, and the screen rebuilds on every `AppState` notification (`:1685-1688`). Each rebuild re-reads secure storage and flickers through the null state. **Fix:** make the widgets stateful and cache the futures in `initState`/`didUpdateWidget`.
- **P2 · a11y · `:1709-1715`.** The app-bar Switch is forced to `height: 28` with `shrinkWrap`, below the 48dp target. **Fix:** use the default tap target or move the toggle into the body.
- **P2 · permissions UX · `:2473-2533`.** "Edit permissions" can only revoke everything. There's no per-capability view with explanations or toggles, and the grant date is a raw ISO substring. **Fix:** list capabilities with the human descriptions from `plugin_permission_sheet.dart` (§9) and allow revoking a single one where the runtime supports it.

**Missing features:**
- Update to the latest version, with a version comparison against the source.
- Source/repo link and homepage.
- Contributed slash-commands/skills/agents with descriptions and a "Use in chat" action that inserts `/plugin:command`.
- Per-plugin usage: invocations of its commands/skills, hook fires and failures, MCP tool calls, last used.
- Scope (user vs project), which Claude Code exposes.

**Test to add:** tapping "Reset to defaults" on a `migrationRequired` row must not enable it. Uninstall must require confirmation. The diagnostics hook counter must be per plugin (two plugins, one failing hook, and only that plugin shows the failure).

---

## 6. McpCard + `connectMcpServer` + MCP credential sheet + runtime-install sheet
**What it is / how reached:**
- `McpCard` (`:3138-3309`) is a compact server card in the MCP section. It has a Switch (connect/disconnect), Delete, a durable status icon and a label. Tapping it opens `McpDetailScreen`, and long-pressing a custom card removes it.
- `connectMcpServer` (`:2745-2837`) runs three gates in order: the sandbox ("Sandbox needed", then Open Studio), then `_McpCredentialSheet` (`:2843-3009`) for missing credentials, with a GitHub-login shortcut, then `_McpRuntimeInstallSheet` (`:3015-3135`) for a missing node/python. After that it calls `AppState.toggleMcpServer`.

**Findings**
- **P0 · broken setup for header-auth servers · `:2871-2899` + `mcp_service.dart:1893-1908`.** `missingCredentialsFor` returns missing **env names and header names** in one list (for example `Authorization` from a plugin `.mcp.json` HTTP server's `requiredHeaderNames`). `_McpCredentialSheet._save` writes *all* the values with `setMcpEnv`. Headers are never written to `setMcpHeaders`, the only place the HTTP transport reads them (`mcp_service.dart:880`, `:1902`). The server stays "needs configuration (Authorization)" however many times the user fills in the sheet, so plugin-owned HTTP MCP servers that need an auth header **can't be set up from the UI**. **Fix:** split the list into `missingEnv`/`missingHeaders` (return a record from `missingCredentialsFor`), save each group with its own setter, and label header fields "HTTP header".
- **P1 · data loss · `:2886` + `state.dart:9808-9822`.** `setMcpEnv` *replaces* the whole env blob, but the sheet passes only the **missing** keys. Any env values already stored for that server (for example `SUPABASE_URL` when only `SUPABASE_KEY` was missing) are erased on save, and the next connect asks for them again or misbehaves. **Fix:** `final merged = {...await app.getMcpEnv(id, strict:true), ...values}; await app.setMcpEnv(id, merged, strict:true);`.
- **P1 · silent save failure · `:2885-2897`.** `setMcpEnv` is called without `strict: true`, so it swallows storage errors (`state.dart:9819-9822`). The `catch` here can never fire: a secure-storage failure pops "connected" and then fails to connect. **Fix:** pass `strict: true`, and keep the raw `$e` out of `_error` (`:2893`) by mapping it to "Couldn't save to secure storage".
- **P1 · destructive gesture, no confirm · `:3153-3155`.** Long-pressing a custom MCP card calls `AppState.I.removeMcpServer(server)` immediately. That kills the process and wipes env, headers and OAuth tokens (`state.dart:9329-9358`), with no dialog, undo or feedback. **Fix:** remove the long-press, or route it through `showDeleteConfirmationDialog` like the trash icon (`:3235-3242`).
- **P1 · no connect-result feedback · `:2836`, `state.dart:9029-9073`.** `toggleMcpServer` flips `connected = true` optimistically and connects with `unawaited`. The card switch shows ON immediately, and when the connect fails it silently flips back. The only signal is the 10.5pt status line. **Fix:** make `connectMcpServer` await `McpService.I.connect` (or return its future), show a snackbar with the mapped outcome ("Connected · 12 tools", "Needs sign-in", "Timed out: Retry"), and keep the switch in an indeterminate or busy state while connecting.
- **P2 · wrong runtime copy · `:3031`.** `_label => widget.kind == 'node' ? 'Node.js' : 'Python'`, but `missingRuntimeFor` can return `'git'` (`mcp_service.dart:1043`). A git-backed server gets "needs Python / Install Python runtime", and `ensureRuntime('git')` throws `ArgumentError` (`sandbox_service.dart:3293-3295`), which the log shows raw. **Fix:** map `git` to "Git" and add git to `ensureRuntime`, or show "Install git via Studio".
- **P2 · bypassed gate · `:2805-2810`.** The GitHub-login branch connects in `onConnected: () => toggleMcpServer(server)`, which skips the runtime gate (`:2817-2835`) that the other path enforces. A stdio GitHub server without node then burns the handshake budget and records a timeout. **Fix:** call `connectMcpServer(context, server)` again after login, which re-evaluates the gates.
- **P2 · dismiss mid-install · `:2820-2834`.** The runtime sheet can be swiped away while installing (`isDismissible` defaults to true), which returns `null`, so the server never connects even though the install keeps running. **Fix:** set `isDismissible: !installing` (wrap in `PopScope`) or offer "Connect when done".
- **P2 · secret field UX · `:2951-2971`.** Each field shows its name twice (a label `Text` and `labelText`) and has no show/hide toggle or paste helper. **Fix:** remove the duplicate label and add a visibility suffix icon.
- **P2 · copy · `:2764-2768`.** "Sandbox needed" is shown for *any* `unsupported` reason (including future non-sandbox reasons from `mcpSupportGateForTest`). **Fix:** render `unsupported` itself in the body.
- **P2 · a11y · `:3213-3219`.** The Switch has no label (see §4).

**Test to add:**
- A server with `requiredHeaderNames: ['Authorization']`: after the sheet is saved, `getMcpHeaders(id)['Authorization']` is set and `missingCredentialsFor` is empty.
- With an existing env `{A:1}` and missing `[B]`, the stored env after save is `{A:1, B:…}`.
- Long-press on a custom card doesn't remove it without confirmation.
- A `git` runtime shows "Git" copy.

---

## 7. McpDetailScreen + `_McpJsonEditorSheet`
**What it is / how reached:** tapping an `McpCard` (`:3331-3852`). The app bar has OAuth (only when a usable OAuth config exists), Edit config (pencil), connect Switch and Delete. The body has the header with durable status, a Connect/Disconnect button, an "Unsupported on this device" banner, a "Needs setup" banner, Reset config, Overview, Environment, a "Config (standard mcp.json)" preview and Runtime rows. The pencil opens `_McpJsonEditorSheet` (`:3857-4035`).

**Findings**
- **P0 · parity, no per-tool listing · whole screen `:3414-3725`.** The detail screen never shows the tools (or resources/prompts) the server advertises, their descriptions or input schemas, the last error or stderr, or any usage. The data is already there: `McpService.I.connectedTools[s.canonicalId]` (`mcp_service.dart:568-570`) and `connectedToolEntries`. Claude Code's `/mcp` view lists tools per server, and users need it to know what the model can call. **Fix:** add a "Tools (N)" section (an expandable `ListTile` per `McpToolDef` with name, description and a schema preview). Add "Resources/Prompts" when the server's capabilities advertise them. Add a "Last error" block from the durable reason or `serviceStatus['mcp:…'].detail`. Add a "Usage" block with calls, failures, average latency and last used, which needs the missing per-MCP aggregation in `McpService.callTool`.
- **P1 · stale screen · `:3339-3345`.** `_McpDetailScreenState.build` doesn't listen to `AppState`. `connectMcpServer` returns before the async connect finishes (`toggleMcpServer` is unawaited), so `setState` at `:3388`/`:3512` repaints the *optimistic* state, and the real ready/failed outcome never appears until the user leaves and comes back. **Fix:** wrap the body in `AnimatedBuilder(animation: AppState.I, …)` as `PluginDetailScreen` does (`:1685`).
- **P1 · auth headers dropped on edit · `:3838-3850` + `state.dart:9360-9385`.** `_configJsonFor` never emits `headers`, so the editor parses `headers: {}` and `updateCustomMcpServer` sets `s.headers = {}`. Ownerless (custom) servers use the in-memory `server.headers` for every request (`mcp_service.dart:1677`, `:3338`); only plugin-owned servers reload them at connect (`:879-881`). Editing *any* field of a custom HTTP server with a Bearer header therefore makes every later request unauthenticated (401) until the app restarts. Users also can't see, rotate or delete headers at all, because empty headers never call `setMcpHeaders`, so storage keeps the old token. **Fix:** emit `headers` with masked values (as `env` does at `:3846-3847`), merge masked entries back from `getMcpHeaders` on save, call `setMcpHeaders` always (empty means delete), and set `s.headers` from the merged map.
- **P1 · edit resets timeouts and allows invalid transports · `:3804-3813`, `:3896-3934`.** The editor drops `startupTimeoutS`/`toolTimeoutS` (it doesn't emit or parse them, though `updateCustomMcpServer` supports them; Claude Code's `MCP_TIMEOUT` equivalent). It accepts any `transport` string without `McpService.unsupportedTransportReason` validation (`addCustomMcpServer` checks it at `state.dart:9311-9312`, the update doesn't). It also edits **non-custom** seeds and plugin-owned servers in place, where the change is persisted (or not) inconsistently, because `_persistCustomMcpServers` writes only `custom` rows (`state.dart:9394-9396`). **Fix:** round-trip the timeouts, validate the transport before saving, and make the editor read-only for plugin-owned servers ("Managed by plugin X"). For built-in seeds, either persist the overrides or hide the pencil.
- **P1 · "Reset config" lies · `:3623-3631`.** The comment says "disconnect + clear any custom env", but the code only disconnects and then shows "MCP server config reset". Stored env, headers and OAuth tokens stay. **Fix:** confirm, then `deleteMcpEnv`, `deleteMcpHeaders` and `McpService.I.removeMcpOAuth`, then disconnect. Or rename it to "Disconnect" and remove the duplicate.
- **P1 · OAuth entry hidden for most remote servers · `:3354-3372`.** The Authorize button renders only when `mcpOAuthConfigForAsync` returns a config with `authorizationUrl` and `clientId` (`mcp_config_parse.dart:42-43`). Because there's no discovery or DCR (known), remote servers that need OAuth (Linear, Notion, Sentry, Atlassian…) show **no** sign-in affordance. A 401 just ends as "Failed". There's also no "Signed in / token expires / Sign out" state. **Fix:** after RFC 9728/8414 discovery and DCR land in core, always show "Sign in" on an `McpConnectOutcome` 401 or needs-auth, and add an auth status row with Re-authenticate and Sign out (`removeMcpOAuth`).
- **P1 · "Needs setup" banner wrong both ways · `:3546-3603`, `:3646-3669`.** It's keyed on `s.envHint != null && !s.connected`:
  - It shows for any disconnected server with an env hint, even when the credentials are stored.
  - It **never** shows for plugin-owned servers that declare `requiredEnvNames`/`requiredHeaderNames` without an `envHint`.
  - "Set up & connect" only asks for *missing* names, so stored values can't be edited from here, and the "Environment" section is a static hint.

  **Fix:** drive the banner from `missingCredentialsFor`. Add an "Environment & headers" section listing every declared and stored key with masked values, each with Edit and Delete (reusing a merged `setMcpEnv`/`setMcpHeaders`).
- **P2 · fake runtime info · `:3715-3719`.** The Runtime rows are hard-coded: "Protocol: JSON-RPC over stdio" shows even for `http`/`sse`/`native` servers, "Sandbox: Isolated · ask before network" isn't derived from anything, and "Process" shows an empty command for HTTP servers. **Fix:** derive the rows from `s.transport`/`s.url`, plus `McpService.protocolVersion`/`sessionId` (`mcp_service.dart:675-685`) when connected.
- **P2 · non-standard JSON · `:3838-3850`.** The section titled "standard mcp.json" emits `"transport"`, but Claude Code/Desktop configs use `"type"` (`stdio`|`http`|`sse`). Users who copy it into Claude Code get an ignored key. **Fix:** emit `type` (the parser already accepts both, `:3904-3905`). Also add a Copy button to the preview.
- **P2 · editor UX · `:3879-3885`, `:3901`.** Validation runs on every keystroke and shows the error immediately while typing. Only `servers.values.first` is used, so renaming the key or pasting several servers silently ignores the rest. **Fix:** debounce validation. Reject more than one entry with a clear message, or support a rename.
- **P2 · performance · `:3354-3356`.** The `FutureBuilder` future (`mcpOAuthConfigForAsync`, a secure-storage read) is created in `build`. **Fix:** cache it in `initState`.
- **P2 · a11y · `:3379-3391`.** The app-bar Switch is 28px high with `shrinkWrap`. The Connect button in the body duplicates it, so remove the app-bar switch.

**Missing features (vs Claude Code `/mcp`):**
- Reconnect, as one action rather than Disconnect then Connect.
- Per-tool allow/deny: Claude Code's permission rules work per `mcp__server__tool`.
- Server stderr/log viewer.
- Server instructions (`initialize.instructions`).
- Scope label (user/project/plugin).
- Per-server usage stats (calls, errors, last used, tokens of tool results).

**Test to add:**
- Connect fake outcome ready, and the detail screen shows "Ready" without navigation.
- Edit the config of a custom HTTP server with stored `Authorization`, save, and `s.headers` still contains `Authorization`.
- A connected server with two tools renders "Tools (2)".
- A plugin-owned server with `requiredEnvNames` and no `envHint` shows the Needs-setup banner.

