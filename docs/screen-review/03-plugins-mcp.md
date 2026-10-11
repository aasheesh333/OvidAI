# 03 — Plugins & MCP UI

## Scope
- `lib/ui/plugins_screen.dart` (4035 lines): PluginsScreen, add-plugin sheet, PluginDetailScreen, McpDetailScreen, MCP credentials / runtime-install / JSON-editor sheets
- `lib/ui/plugin_settings_panel.dart`, `lib/ui/plugin_install_progress.dart`, `lib/ui/plugin_permission_sheet.dart`, `lib/ui/mcp_oauth_sheet.dart`
- Calls followed into `lib/core/` (mcp_service.dart, plugin_*.dart, hook_service.dart) where needed to confirm a bug.

## Goal
Product requirement: every Claude Code MCP server and plugin must work as in Claude Code (except OS-limited), and MCP/plugin usage must be tracked and visible. Check the UI against that: install flows (GitHub repo / marketplace), enable/disable, errors, status (connected/degraded/failed), OAuth, env/headers editing, per-tool listing, usage stats. Plus the general review goals in README.md (bugs, states, UX, a11y, perf, security).

Known context (not re-derived here): PostToolUse hooks are fire-and-forget; MCP server→client requests (ping/roots/sampling/elicitation) unanswered; OAuth lacks discovery/DCR and uses paste-back redirect; no per-MCP/plugin usage aggregation; grants stored in SharedPreferences.

## Status
complete (sections 1–11 + group summary)

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

---

## 8. PluginSettingsPanel (`plugin_settings_panel.dart`, 313 lines)
**What it is / how reached:** the schema-driven settings form inside `PluginDetailScreen` under "Settings" (`plugins_screen.dart:2169-2183`). It renders only when the plugin is installed, has a `runtimeId`, and `PluginContributionRegistry.settingsFieldsForPlugin` returns fields. Each manifest field `{key,label,secret,hint}` becomes a `TextField`, masked when `secret`. One "Save settings" button writes every field through `NativePluginConfigStore` (secrets go to secure storage, the rest to SharedPreferences). There is no WebView and no plugin code, which is good.

**Findings**
- **P1 · dead feature · `plugin_settings_panel.dart:112-116` + `plugin_registry.dart:355-371`.** Nothing in `lib/core` ever reads the values saved for an *installed* plugin. `settingsFieldsForSession` has no callers. `NativePluginConfigStore.read/readAll` is only called by native capabilities (`rest_engine.dart:271`, `misc_utilities.dart:1434`, …). No env or `${user_config.*}` substitution reaches the plugin's hooks, MCP servers or commands. The user enters an API key, sees "Settings saved", and the plugin still behaves as if it were unconfigured. Claude Code's plugin `userConfig` values are substituted into MCP/hook config and exported to plugin processes. **Fix:** at activation, resolve the plugin's settings with `readAll(pluginName: runtimeId, …)` and inject them as `CLAUDE_PLUGIN_OPTION_<KEY>` env (plus `${user_config.<key>}` substitution) into the plugin's MCP server env/headers and hook process env. Re-mount the plugin when `onSaved` fires (the detail screen passes no `onSaved` today, `plugins_screen.dart:2178-2181`). Until that's wired, hide the section or label it "Not yet used by this plugin".
- **P1 · security / privacy · uninstall path (`state.dart:2489-2560`) vs `native_plugin.dart:135-147`.** `NativePluginConfigStore.clear` is never called from `uninstallPlugin` or anywhere else (grep finds no callers). Plugin secrets entered here stay in secure storage after uninstall, and a later plugin that slugifies to the same namespace inherits them (next finding). **Fix:** call `NativePluginConfigStore.I.clear(pluginName: runtimeId, fields: configFieldsForSettings(fields))` in `uninstallPlugin`. Mention "Saved settings will be deleted" in the uninstall confirmation (§5).
- **P1 · security · namespace collision · `native_plugin.dart:161-168`, `:69-73`.** Storage keys are `native_plugin_<slugify(pluginName)>__<key>`, and `slugify` collapses every non-alphanumeric run to `_`. Different plugins can share one namespace: `acme/foo-bar` and `acme-foo/bar` both become `acme_foo_bar`, and an installed plugin can collide with a native capability's display name (for example a `native/json` plugin vs native "Native JSON"). A malicious plugin can declare a field with the same key as another plugin's secret and have the stored secret pre-filled into its own settings form, ready to read once settings injection exists. **Fix:** namespace installed-plugin settings by a collision-free encoding of the canonical id, such as `plugin_cfg_<base64url(runtimeId)>__<key>`, kept separate from the native-capability namespace. Migrate existing keys once.
- **P1 · crash · `:63-65`, `:152`.** Controllers are created once in `initState` from `widget.fields`, and there's no `didUpdateWidget`. `PluginDetailScreen` rebuilds on every `AppState` notification and re-reads `settingsFieldsForPlugin` (`plugins_screen.dart:1697-1701`). If the manifest's field set changes while the screen is open (re-register after Retry activation or an update), `_controllers[field.key]!` throws a null-check error and the detail page turns red. **Fix:** add `didUpdateWidget` to dispose removed controllers, create new ones and reload. Also give the panel `key: ValueKey(runtimeId + fieldKeys.join(','))` at the call site.
- **P2 · data semantics · `:105-107`.** Every field is saved, and a cleared field writes `""` instead of deleting the value. There is no "required" marker, no validation (URL, number), and no per-field "Clear". Plugins can't tell "unset" from "empty". **Fix:** delete keys whose trimmed value is empty. Extend `PluginSettingsField` with `required`, `type` (string/number/bool/url/enum) and `default`, render the matching controls, and block Save until required fields are filled.
- **P2 · raw errors · `:94`, `:121`.** `'Could not read saved settings: $e'` and `'Could not save settings: $e'` show `PlatformException(...)`/`ArgumentError` text. **Fix:** use fixed copy ("Couldn't access secure storage on this device. Try again.") and log the raw error.
- **P2 · secret UX · `:259-262`.** Secret fields have no show/hide toggle. The stored secret is loaded in plaintext into the controller (`:86`) and can be revealed by copy/paste on some keyboards. Typing a new value means select-all and retype blind. **Fix:** don't load secret values. Show "•••• saved (ends in 1a2b)" with Replace and Remove actions, and add a visibility toggle while typing.
- **P2 · stale "saved" state · `:155`.** `_saved` resets on edit, but there's no unsaved-changes guard. Leaving the detail page with edits discards them silently. **Fix:** track dirty state and confirm on pop (`PopScope`), or autosave on field blur.
- **P2 · a11y / copy · `:243-249`, `:267`.** The `hintText` repeats the label inside the field. The "SECRET" pill and lock icon are announced as separate nodes, not as part of the field label. **Fix:** remove `hintText` or use a real example value. Wrap the label row in `MergeSemantics` or put "secret" into `InputDecoration.labelText`.
- **P2 · scope gap · `plugins_screen.dart:1697`.** The settings form only shows for installed runtime plugins. Native capabilities that declare `configFields` (`misc_utilities.dart:1405`, `rest_engine.dart:251`, `sandbox_utilities.dart:424`) can only be configured through the agent's configure tool (`agent_service.dart:15210-15233`), not by hand. **Fix:** render `PluginSettingsPanel(pluginName: capability.pluginName, fields: capability.configFields)` on native plugin rows too.

**Missing features:** settings that are actually used by the plugin (env/substitution, see the first finding); typed fields (bool, enum, number); defaults and "Reset to defaults" wired to `clear` (see §5 "Reset to defaults"); prompting for required settings at install time, as Claude Code does for `userConfig` on enable; and a "Configured / Needs configuration" status on the card.

**Test to add:**
- Widget test: pump the panel with fields `[a]`, then rebuild with `[a, b]`. There must be no exception and field `b` must render.
- Unit test: `slugify('acme/foo-bar') != slugify('acme-foo/bar')` for the new settings namespace, or the keys differ.
- Integration test: uninstalling a plugin with a saved secret makes `readAll` return `{}`.
- Clearing a field and saving removes the stored key.

---

## 9. Plugin install progress sheet (`plugin_install_progress.dart`, 333 lines)
**What it is / how reached:** `PluginInstallProgressSheet` is a modal bottom sheet opened by `_runSourceInstall` (`plugins_screen.dart:725-743`) *before* inspect/approval/install start. It has a phase label with a spinner, a linear progress bar (determinate during the byte fetch), a 220px terminal-style `ProgressLogView` with 48px follow-mode, and a result card once `finish` is called. The secondary action "Close — install continues" dismisses it while the install keeps running. `PluginInstallProgress` is the `ChangeNotifier` controller (300-line / 2,000-char cap). `fetchProgressLabel` formats byte progress.

**Findings**
- **P1 · flow order / misleading state · `plugins_screen.dart:725-743` vs `:384-395`.** The sheet titled "Installing <name>" opens before the capability approval. `showPluginPermissionSheet` then stacks a second modal sheet on top of it, so the user is asked to *approve* an install the UI already says is running. If they decline, the progress sheet underneath reads "Install cancelled — nothing was changed." with a red error icon (`ok:false`), which looks like a failure. **Fix:** show "Fetching <repo>…" inline (or in a small "Inspecting" sheet), close it, show the approval sheet, and open the progress sheet only after `accepted == true`. Render a cancelled result in neutral style (a third state, not `ok:false`).
- **P1 · status honesty · `:67-73` + `plugins_screen.dart:785-794`.** `finish` has only `ok` true/false. A `degraded` install (installed, some dependencies failed) is passed as `ok:false`, so the sheet shows a red error icon, a red progress bar and a "Close" button for a plugin that *is* installed. The phase label is also never updated at finish, so a green check can sit next to "Installing dependencies…". **Fix:** use an `InstallOutcome {success, degraded, failed, cancelled}` enum with amber styling for degraded. Set the phase to "Installed" / "Installed with warnings" / "Failed" in `finish`. Add a "Open plugin" primary action on success or degraded that pushes `PluginDetailScreen`.
- **P2 · raw errors · `:316` via `plugins_screen.dart:777-790`.** The summary card renders `Install crashed: $e` / `Install failed: source resolution failed: SocketException…` verbatim (see §3). **Fix:** show mapped copy in the card and keep the raw error as the last log line.
- **P2 · performance · `:35`, `:58-62`, `:119`, `:213-215`.** Every `line()` call fires `notifyListeners`, which rebuilds the whole sheet. `lines` returns a fresh `List.unmodifiable` copy (up to 300 strings) per build, and `didUpdateWidget` runs `listEquals` over it. With chatty `npm install` output (hundreds of lines per second) that is roughly O(300) copy+compare per line on the UI thread, which janks on low-end devices. **Fix:** coalesce notifications to at most one per frame (schedule with `SchedulerBinding.scheduleFrameCallback` or a 50ms timer), expose a `revision` int instead of copying, and compare revisions in `didUpdateWidget`. Rebuild only the log via a `ListenableBuilder` scoped to it.
- **P2 · no copy / share of log · `:153-163`.** Log lines are plain `Text`, so they can't be selected or copied. When an install fails, users can't paste the error into a bug report or chat. **Fix:** wrap the log in `SelectionArea` and add "Copy log" (and on failure "Ask Ovid to fix", which inserts the log into chat).
- **P2 · lost after dismiss · `:243-244`, `plugins_screen.dart:795-797`.** After "Close — install continues", the only remaining signal is one snackbar at the end. There's no way back to the live log, no progress on the plugin card, and the controller is never disposed. Concurrent installs each get an orphan controller. **Fix:** keep active installs in an `InstallQueue` on `AppState`, show an "Installing… 42%" chip on the `PluginCard`/detail page that reopens the sheet, and dispose the controller when the queue entry is cleared.
- **P2 · no cancel · `:228-247`.** There's no way to abort a slow or stuck fetch or dependency install (for example an npm postinstall hanging). **Fix:** thread a `CancelToken` through `inspect`/`installPlugin` and add a "Cancel install" destructive action that discards staging.
- **P2 · a11y · `:256-281`, `:298-325`.** Phase changes and the final result aren't announced to TalkBack. The 16px spinner has no semantics label. **Fix:** `Semantics(liveRegion: true)` on the phase row and the result card. Use `SemanticsService.announce` on finish.
- **P2 · layout / indentation · `:220-331`.** The `SingleChildScrollView`, `MediaQuery.removeViewInsets` and `AetherSheet` nesting is mis-indented. The 220px fixed log height takes most of a landscape phone's height, and on tablets it looks tiny. **Fix:** size the log with `LayoutBuilder` (for example `clamp(160, 0.4 * maxHeight, 420)`) and run `dart format`.

**Missing features:** a downloads/installs activity list (recent installs with outcome and log); a per-step checklist (Fetch → Verify manifest → Approve → Install dependencies → Probe → Activate) instead of free-form phases; and an estimated size before download.

**Test to add:**
- Widget test: drive the flow with the approval sheet declined. The progress sheet must not have been shown, or must show a neutral "Cancelled" state, not an error.
- `finish(degraded)` renders the amber state and the phase reads "Installed with warnings".
- Push 5,000 lines in a loop and assert at most N rebuilds per frame (`tester.binding` frame count). The buffer stays at 300.

---

## 10. Plugin permission / approval sheet (`plugin_permission_sheet.dart`, 360 lines)
**What it is / how reached:** `showPluginPermissionSheet` is called from `startPluginInstallForTest` (`plugins_screen.dart:388`) whenever no effective grant exists for the manifest digest, so on a first install or when an update changes the manifest. It is non-dismissible (`isDismissible:false`, `enableDrag:false`, `PopScope(canPop: !_saving)`). It shows the name, version and id, then capability rows (enum name, reason, env var names, manifest source path), the dependency packages, a fine-print line, an error card and an "Access summary" card. Accept saves a `PluginPermissionGrant` (all inferred capabilities plus env-read names) and returns `true`. Cancel returns `false`.

**Findings**
- **P1 · security disclosure · `:181-230` + `plugin_dependency_service.dart:260-262`, `:323`.** npm/pip lifecycle scripts (`postinstall` etc.) are allowed whenever the grant includes `shellExecute`, which is usually granted because a hook or command runs a shell. The sheet lists dependencies as "name version (npm)" and never says that accepting also lets those packages' install scripts run arbitrary code on the device. **Fix:** when `shellExecute` is requested and deps exist, add an explicit row "Runs install scripts from N packages (npm postinstall)". Better, make it a separate opt-in checkbox stored as its own capability (`dependencies.scripts`), so a hook's shell grant doesn't silently cover third-party install scripts.
- **P1 · security / trust · `:116-150`.** The sheet never shows *where* the plugin comes from: no repo URL or owner, no ref or commit, no marketplace name, no "unverified source" warning, no file count or size. Claude Code shows a trust warning before installing plugins ("make sure you trust…"). A typosquatted repo looks identical to the real one. **Fix:** pass `PluginInspection.source` into the sheet. Show `owner/repo@ref (commit abc1234)`, the marketplace (or "Direct from GitHub — not from a marketplace you added") and a warning banner for unknown sources. Make the repo tappable to open it in the browser.
- **P1 · all-or-nothing consent · `:57-67`.** Accept grants *every* inferred capability. The user can't decline a risky one (for example `deviceControl`, `hooksBlock` or `networkConnect`) and still install the rest. That is coarser than Claude Code's per-tool permission rules and Android's own permission model. **Fix:** show a toggle per capability for those the runtime can enforce independently (hooks, MCP servers, network). Persist the subset and let the runtime skip contributions whose capability was declined, marking them "disabled by you" on the detail page.
- **P2 · grant persists after failed install · `:57-68` vs `plugins_screen.dart:409-421`.** The grant is saved on Accept, before the install runs. If the install then fails, the grant stays, and a later install of the same digest (or a different source that produces the same manifest digest) reuses it silently with no prompt (`effectiveGrant`, `plugins_screen.dart:376-379`). **Fix:** return the grant from the sheet and commit it only after `installPlugin` succeeds, or revoke it in the failure branch.
- **P2 · copy / jargon · `:316-319`.** The capability title is the raw enum name (`shellExecute`, `hooksBlock`, `mcpRegister`, `sessionWrite`). It isn't localizable and means nothing to most users. **Fix:** map it to human titles with a risk level ("Run shell commands · High", "Block or change your actions · High", "Read this chat · Medium"). Sort by risk and colour high-risk rows amber or red rather than the uniform accent.
- **P2 · copy order · `:260-279`.** The "Access summary" card says "Each item below shows the manifest path…", but it is rendered *below* every item, after the fine print. It also counts MCP servers that aren't listed anywhere in the sheet. **Fix:** move the summary to the top (under the header) as a one-line "N permissions · M MCP servers · K packages" and list the MCP servers by name and URL or command, since network endpoints matter for consent.
- **P2 · misleading icons · `:195-200`.** Required deps use `download_outlined` and optional deps use `download_done_outlined`, a "done" glyph that reads as "already installed". **Fix:** use the same download icon for both and an "Optional" pill for optional deps.
- **P2 · raw error · `:74`.** `'Could not save the grant: $e'` shows the `StateError`/`PlatformException` text. **Fix:** "Couldn't save your approval. Check storage and try again." and log the raw error.
- **P2 · a11y · `:298-343`.** Each capability card is several unmerged semantics nodes (icon, title, reason, path). The decorative icons have no `excludeSemantics`. Accept and Cancel come after a long scroll with no hint of how many items there are. **Fix:** use `MergeSemantics` per row, `ExcludeSemantics` on decorative icons, and pin the action bar (sticky footer) so Accept is always visible but only enabled after the list has been shown, which also prevents a blind accept.
- **P2 · layout / format · `:89-286`.** The same mis-indented `SingleChildScrollView` → `removeViewInsets` → `AetherSheet` nesting as §9, so the actions scroll away with the content on long lists. **Fix:** put a scrollable body and a pinned footer in a `DraggableScrollableSheet` and run `dart format`.
- **P2 · update diff · whole sheet.** On an update, where the digest changed, the sheet shows the full list again with no indication of what is *new* compared with the previous grant. Users rubber-stamp it. **Fix:** load the previous grant for `pluginId` and badge added capabilities, env names, deps and servers with "NEW" (and removed ones struck through).

**Missing features:** Claude Code-style trust prompt and source verification; per-capability decline; a "View manifest / files" link (`.mcp.json`, `hooks/hooks.json`) before approving; and a changed-permissions diff on update.

**Test to add:**
- A manifest with `shellExecute` and one npm dependency renders the "install scripts" disclosure row.
- The sheet renders the source repo and ref when given a GitHub inspection.
- Accept, then a forced install failure, leaves `effectiveGrant` null.
- An update with one new capability shows a single "NEW" badge.

---

## 11. MCP OAuth sheet (`mcp_oauth_sheet.dart`, 329 lines)
**What it is / how reached:** `showMcpOAuthSheet` opens from the lock icon in the `McpDetailScreen` app bar (`plugins_screen.dart:3354-3371`). That icon appears only when `mcpOAuthConfigForAsync` returns a usable static config (see §7). The sheet calls `beginMcpOAuthAuthorization` (S256 PKCE, 10-minute one-use attempt, `mcp_service.dart:1311-1357`), shows the authorization URL with Copy, offers "Open browser" (external browser), then asks the user to paste the *full redirect URL* into a "Callback URL" field and tap Complete (`completeMcpOAuthAuthorization`, `mcp_service.dart:1362-1397`). It is non-dismissible, and back runs `_cancel`.

**Findings**
- **P1 · parity / broken on mobile · whole flow `:246-293`.** The paste-back design (a known gap) is very hard to complete on Android. The user must sign in in Chrome, land on a redirect page that often errors or 404s, select the full address-bar URL (Chrome shows a truncated host on mobile), switch back and paste. While the app is in the background Android may kill it, and the in-memory `_oauthAttempts` (PKCE verifier and state) is lost, so the paste then fails with "OAuth attempt expired or unavailable". Most users of remote MCP servers (Linear, Notion, Sentry, GitHub remote) can't finish sign-in. **Fix:** register a verified App Link (`https://<ovid-domain>/oauth/mcp/callback`) or a custom scheme intent filter. Use Custom Tabs (`flutter_custom_tabs` / `flutter_web_auth_2`) to capture the redirect automatically. Persist the pending attempt (state, verifier, expiry) in secure storage so it survives process death. Keep paste-back only as an "Having trouble?" fallback.
- **P1 · consumed attempt, retry dead-ends · `:150-176` + `mcp_service.dart:1366-1395`.** `completeMcpOAuthAuthorization` removes the attempt *before* validating, so any rejected paste (typo, the user pasted the auth URL instead of the callback, `error=access_denied`, wrong redirect) consumes it. The sheet stays on the same ready view with the old URL and says "review the callback and retry". Every retry then fails with "OAuth attempt expired or unavailable" until the user cancels and reopens. There's also no sign of the 10-minute expiry. **Fix:** on any completion failure, automatically start a new attempt (`_begin()`) and tell the user "Link refreshed — open the browser again". Show an expiry countdown, or restart automatically when expired.
- **P1 · no result handling · `plugins_screen.dart:3364-3369`.** The `Future<bool?>` from `showMcpOAuthSheet` is ignored. After a successful sign-in the server isn't reconnected, no snackbar confirms it, and the detail screen doesn't refresh (it doesn't listen to `AppState`, §7). The user has to guess that they should toggle Disconnect/Connect. **Fix:** `if (await showMcpOAuthSheet(...) == true) { show "Signed in to X"; await connectMcpServer(context, s); setState(...) }`. Show "Signed in · expires in …" with Sign out (`clearMcpOAuthToken`) on the detail page.
- **P2 · raw / unhelpful errors · `:119`, `:172`, `:233-236`.** The begin error shows `Bad state: OAuth redirect URI is invalid` / `OAuth configuration unavailable or replaced`. The completion error is always the generic `Could not complete authorization: Bad state: OAuth callback rejected`, whether the cause was user denial (`error=access_denied`), a state mismatch, a redirect mismatch, or a token-endpoint HTTP failure. **Fix:** make core throw a typed `McpOAuthError{kind: denied|stateMismatch|redirectMismatch|expired|tokenExchange(status)|config}` and map each to copy: "You declined access", "That link is from an older attempt", "Paste the URL you were redirected to, not the sign-in link", and so on.
- **P2 · invisible phase · `:201-204`.** `_phase` ("Browser opened — waiting for callback", "Completion failed — …") is only a `Semantics` label and is never rendered, so sighted users get no status after tapping Open browser. **Fix:** render `_phase` as a status row (icon and text) above the URL card, keeping `liveRegion`.
- **P2 · snackbars hidden · `:142-147`, `:318-321`.** "Could not open the browser." and "Authorization URL copied." go to the root `ScaffoldMessenger`, which paints *behind* the modal bottom-sheet barrier, so they're effectively invisible. **Fix:** show the feedback inline (phase row, or a "Copied ✓" icon swap on the copy button).
- **P2 · security hygiene · `:267-276`.** The callback field (which contains a live authorization `code`) uses `AetherField` defaults: keyboard suggestions and autocorrect stay on, so Gboard can learn the code, and the copied auth URL and pasted callback remain on the clipboard. **Fix:** set `autocorrect:false`, `enableSuggestions:false` and `keyboardType: TextInputType.url`, clear the field on completion, and offer a one-tap "Paste" button (`Clipboard.getData`) so the user doesn't long-press a three-line field.
- **P2 · copy · `:250-255`.** The instructions don't warn that the redirect page may show an error or blank page (normal for paste-back), which is the point where most users abandon. **Fix:** "After you sign in, the browser may show an error page — that's expected. Copy the address from the address bar and paste it here." Include a small illustration or step list.
- **P2 · layout · `:191-221`.** `AetherSheet` body has no `viewInsets` padding (unlike §9/§10), so with the keyboard open on the callback field the Complete button and field can sit under the IME on small phones. **Fix:** wrap in `Padding(bottom: MediaQuery.viewInsetsOf(context).bottom)` like the other sheets.

**Missing features (vs Claude Code `/mcp` auth):**
- Automatic OAuth discovery (RFC 9728 protected-resource metadata, then RFC 8414) and Dynamic Client Registration, so the sheet works without a hand-written `oauth` block (known core gap).
- Automatic redirect capture.
- Token status: signed in, expiry and scopes, plus Re-authenticate and Sign out.
- Automatic reconnect after auth.
- Automatic launch of this sheet when a connect returns 401 or `WWW-Authenticate`.

**Test to add:**
- Widget test with a fake service whose `completeAuthorization` throws once: the sheet calls `beginAuthorization` again (two calls), and a second Complete with a valid URI pops `true`.
- `McpDetailScreen`: when the sheet pops `true`, `connect` is invoked.
- `_phase` text is visible after Open browser.
- The callback `TextField` has `enableSuggestions == false`.

---

## Group summary

**Counts (sections 1–11):** P0 = 4 (§1 no add-MCP UI, §2 marketplace removal with no confirm that uninstalls plugins, §6 header credentials never saved, §7 no per-tool listing) · P1 = 36 · P2 = 58. Sections 8–11 (this pass) added 0 P0, 12 P1 and 27 P2.

**Top 10 fixes, in order**
| # | Fix | Sections | Effort |
|---|---|---|---|
| 1 | **Add MCP server UI** (Command / Remote URL / Paste JSON) wired to `addCustomMcpServer` + `setMcpEnv/Headers` + connect. Biggest Claude Code parity hole. | §1 | M |
| 2 | **Fix MCP credentials sheet**: split env vs header names and save headers through `setMcpHeaders`, merge with existing env instead of replacing, `strict:true`. Plus the custom-server editor round-tripping `headers` and timeouts. Unblocks every header-auth HTTP server and stops silent 401s after an edit. | §6, §7 | S |
| 3 | **Make every destructive action confirm and tell the truth**: sheet marketplace trash, long-press MCP remove, detail "Uninstall", "Reset config", "Reset to defaults" (currently bypasses the migration gate and enables without mounting). Fix the marketplace-removal copy. | §1, §2, §4, §5, §6, §7 | S |
| 4 | **Usage tracking + per-tool listing**: per-MCP and per-plugin counters in `McpService.callTool` and `HookService` (calls, failures, latency, last used), shown as "Tools (N)" and usage blocks on the detail screens and "N calls · last used" on cards. Product requirement. | §1, §5, §7 | L |
| 5 | **OAuth that works on Android**: App Link / Custom Tabs redirect capture, persisted PKCE attempt, auto-restart after a failed paste, reconnect on success, typed errors. Then discovery and DCR in core so the sign-in entry shows for any 401. | §7, §11 | L |
| 6 | **Plugin settings actually used and isolated**: inject saved values into plugin MCP/hook env (`CLAUDE_PLUGIN_OPTION_*`, `${user_config.*}`), clear them on uninstall, use a collision-free namespace keyed by canonical id, add `didUpdateWidget` (crash fix). | §8 | M |
| 7 | **Honest enable/connect feedback**: `enablePlugin` returns a result, probe all contribution kinds (fixes the false "failed" for hook- and MCP-only plugins), await connect and show the outcome, and make `McpDetailScreen` listen to `AppState`. | §4, §6, §7 | M |
| 8 | **Install flow order and outcome states**: approval before the progress sheet; success / degraded / failed / cancelled states; mapped errors with raw text under Details; persisted install logs; an "Installing…" chip that reopens the sheet. Remove the orphan catalog row on failure. | §3, §9 | M |
| 9 | **Consent sheet hardening**: show source repo, ref and commit plus a trust warning; disclose npm install scripts separately from `shellExecute`; human capability names with risk levels; commit the grant only after a successful install; NEW badges on update. | §10 | M |
| 10 | **Input parsing, search and a11y sweep**: `_githubSourceFromInput` (`tree/ref/sub`, `.git`, `git@`), search and chip filtering of MCP cards, Switch semantics labels, 48dp app-bar switches, live regions on progress and OAuth phases. | §1, §2, §4, §9, §11 | S |

**Suggested PR order:** 2 → 3 → 6 (crash and secret cleanup part) → 7 → 1 → 8 → 9 → 10 → 4 → 5. Small, high-severity data and security fixes go first. The two L items (usage aggregation, OAuth redirect capture) need core work and should land with the master plan's "MCP/plugin parity + usage tracking" PR.
