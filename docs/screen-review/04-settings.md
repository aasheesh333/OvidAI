# 04 — Settings

## Scope
`lib/ui/settings_screen.dart` (SettingsScreen and all private sub-screens),
`lib/ui/settings_action_widgets.dart`, `lib/ui/settings_backup_screen.dart`,
`lib/ui/settings_health_screen.dart`, `lib/ui/health_screen.dart`,
`lib/ui/permissions_screen.dart`, `lib/ui/memory_screen.dart`.
Read in full at HEAD; calls into `lib/core/` followed where needed to confirm a bug.

## Goal
Actionable fix plan for the Settings area (see README): functional bugs, missing
states, UX/a11y/perf defects, UI-visible security issues, and must-have settings
features missing vs the ChatGPT / Claude Android apps.

## Status
complete

---

## 1. SettingsScreen (hub): `settings_screen.dart:50-576`
**What it is / how reached:** The root Settings page, pushed from the shell/sidebar. It is one long `ListView` with nine premium card sections: Account, Appearance, Models, Autonomy, Studio, Backup, Health, Diagnostics and About. It holds about 30 rows. Most rows push a sub-screen through `_navTile` (L453) or `_navTileWithAction` (L481). The switch rows use `SettingsSwitchTile` (`settings_action_widgets.dart:53`).

**Findings**
- **P0 · security/privacy · `settings_screen.dart:287-295` + `settings_action_widgets.dart:146` + `core/settings_state_integration.dart:36-235`.** The "Delete all data" row promises *"Chats, keys and settings · irreversible"*. The dialog says *"Remove app-owned chats, credentials, settings and local data"*. The bound reset (`_resetAllData`) only covers the 10 `ResetStoreKind` stores: sessions, search, ledger, memory, usage, Firebase sign-out, image receipts, browser profiles/shares, private sync and collaboration. It never touches:
  - `ovidSecureStorage()`, which holds the provider API keys, GitHub token, MCP env and SSH keys
  - SharedPreferences settings
  - `providers`, `plugins`, `mcpServers`, custom presets and permission grants
  - `<docs>/skills`, the `ovid-sessions-*.json` exports in documents, the temp-dir backup ZIPs, and the default WebView cookie jar

  The legacy `deleteAllData()` (`core/state.dart:5158-5215`) did wipe secure storage, but it is no longer bound. After a "verified" reset the UI shows **"All data deleted."** (`settings_action_widgets.dart:170`) while every API key and token survives. This is a user-facing data-deletion promise the app does not keep (Play User Data policy / Data-safety "data deletion" claim). **Fix:** add `ResetStoreKind`s for `secrets` (`ovidSecureStorage().deleteAll()` plus readback `readAll().isEmpty`), `preferences` (`prefs.clear()` minus a keep-list), `providers/plugins/mcp`, `presets`, `grants`, `skills` (`<docs>/skills`), `exports` (`<docs>/ovid-sessions-*.json`), `cache` (temp dir) and `cookies` (`WebViewCookieManager().clearCookies()`). Until those land, change the copy to list exactly what is and is not removed.
- **P1 · a11y · `settings_action_widgets.dart:98-122`.** `SettingsSwitchTile` builds a plain `ListTile` with a trailing `Switch`, and there is no `MergeSemantics`. TalkBack focuses the switch as an unlabeled "Switch, off" node, separate from the title. This affects Memory, Share session memory, Show reasoning, Browser desktop, Notifications and Crash reports. **Fix:** wrap the `ListTile` in `MergeSemantics`, or rebuild it on `SwitchListTile` the way `_KeepAliveToggle` (L1127) already does.
- **P1 · functional/UX · `settings_screen.dart:337-346` + `core/agent_notification_service.dart:288-298`.** The Notifications switch only flips a pref. The subtitle says "Requested — … also require OS permission", but the tile never reads or requests `Permission.notification`. The permission is asked lazily, once per process, on the first agent run. If the user denied it (permanently denied on Android 13+), the switch still shows ON and nothing offers a way to fix it. **Fix:** read `Permission.notification.status` in the tile. When ON + denied, show "Blocked by Android — Open settings" and call `openAppSettings()`. Request the permission when the user toggles ON.
- **P1 · store-policy · `settings_screen.dart:525-575`, `1651`, `1677`.** "Privacy policy" (hub and About) and "Website" open the same URL (`https://dhanuk.page.gd/ovid` vs `…/ovid/`). That is the marketing root, not a dedicated policy document. The hub also wraps it in an extra confirm dialog. `launchUrl`'s `false`/exception result is ignored, so the tap fails silently when no browser is installed. **Fix:** host the policy at a stable dedicated path (e.g. `/ovid/privacy`) on a host that serves plain HTML without a JS challenge, so Play reviewers can load it. Drop the intermediate dialog (open directly). Check the `launchUrl` result and show a SnackBar with a copy-link fallback.
- **P1 · functional · `settings_screen.dart:183-193` vs `core/agent_service.dart:10595`.** "Share session memory" stays interactive when the Memory master switch is OFF. When it is ON, the system prompt still tells the model it "may search across all chats via memory_search", and the tool then returns "Memory is disabled in Settings." **Fix:** disable `_ShareMemoryTile` (`setter: null`, subtitle "Requires Memory") while `!memoryEnabled`, and gate the prompt line on `memoryEnabled && shareSessionMemory`.
- **P1 · UX/IA · `settings_screen.dart:68-394`.** About 30 rows sit in nine sections with no search. Developer-grade options ("Browser: desktop mode", "Device integrity", "Background keep-alive", "Context & output") sit beside everyday ones, and Billing/Usage are filed under **About**. **Fix:** re-group as ChatGPT/Claude do: Account, Personalization (theme, language, text size, memory, custom instructions), Data controls (export, backup, delete, storage), Models, Notifications, Advanced (desktop browser, keep-alive, integrity, context), About. Move Plan & Billing and Usage under Account.
- **P2 · consistency · `settings_screen.dart:491-519`.** `_navTileWithAction` pads 4 dp horizontally, while every `ListTile` row uses 16 dp. The Backup and Health rows are therefore visibly misaligned inside the same card, and the row has a redundant second tap target (the ghost button pushes the same screen). **Fix:** use `_navTile`, or use `ListTile(trailing: AetherGhostButton)` with the standard padding.
- **P2 · consistency · `settings_screen.dart:166`, `120`, `184`, `1100`.** Permissions and Providers both use `Icons.key_outlined`. Memory and Share session memory both use `Icons.psychology_outlined`. Row density is mixed (`dense: true` on some tiles, default on others). **Fix:** give each row a distinct icon (e.g. `Icons.verified_user_outlined` for Permissions, `Icons.travel_explore` for shared memory) and use one density.
- **P2 · copy · `settings_screen.dart:371`.** The Usage subtitle shows the literal placeholder "OvidAI, OpenCode, [CC], Z Code". **Fix:** use real client names, or "Spend by client".
- **P2 · copy · `settings_screen.dart:130`, `216`.** Subtitles are developer jargon ("Drives auto-compaction + the % context ring", "media queries use 1280px; fallback scale-only if channel unavailable"). **Fix:** use one plain-language line and move the detail into the sub-screen.
- **P2 · UX · `settings_screen.dart:653-708`.** Device integrity tells every user "Stored keys can be read" when root is detected. There is no next step, and the only tap action is a silent re-probe. **Fix:** add a "What this means" sheet, and show a progress/Semantics announcement on re-probe.

**Missing features (absence confirmed in code)**
- **Language picker.** `AppState.localePref`/`setLocalePref` exist (`core/state.dart:5532-5548`, restorable via backup), but there is no UI and the app has no `localizationsDelegates`/`supportedLocales`.
- **Text size / chat font.** `ovid_chat_font_scale` is only adjustable inside `chat_screen.dart`; Settings has no entry.
- **Custom instructions / "What should Ovid know about you".** No such feature exists. Memory files are the closest equivalent.
- **Orphan settings.** `autoRunSafeCommands`, `githubSync`, `workflowEnabled` and `conversationDisplay` are persisted and backed up, but no screen in `lib/ui/` exposes them (`sendWhileBusy` is only reachable inside `chat_screen.dart`).
- **Data controls.** There is no "Delete all chats" (separate from a full reset), no archived chats, and no "Clear memory" shortcut.
- **Default model selector.** There is no default-model row in the Settings hub. The model is picked per chat and `lastSelectedModel` is sticky.
- **Haptics and sound.** No haptics or sound toggles exist.
- **Open-source licenses.** There is no `showLicensePage` anywhere in `lib/`.
- **Delete account.** Not discoverable from the hub. It exists only inside `AuthScreen` (`auth_screen.dart:308`). Play requires it to be easy to find, so add a "Delete account" row under Account.

**Test to add**
- Widget test: on `SettingsScreen`, every `SettingsSwitchTile` exposes a single semantics node with label = title, `hasToggledState` and `isToggled`.
- Integration test: seed a provider key in `ovidSecureStorage`, run `SettingsActions.resetAll`, and assert `readAll()` is empty **or** that the result is reported as not `success`.

---

## 2. Theme selector (`_ThemeToggle`): `settings_screen.dart:1159-1251`
**What it is / how reached:** The Appearance card on the hub. It offers Auto/Light/Dark as an `AetherSegmentedControl`, falling back to `ChoiceChip`s below 250 dp × text scale.

**Findings**
- **P2 · missing · `settings_screen.dart:1221-1241`.** Only three modes are offered. There is no AMOLED/true-black option and no preview, both of which ChatGPT and Claude users expect. **Fix:** add a "Pure black" option that maps `Aether.bg` to `#000`, plus a small preview swatch.
- **P2 · a11y · `settings_screen.dart:1234-1242`.** The segmented control has no group label for screen readers, so "Auto, Light, Dark" is read without "Theme". **Fix:** wrap it in `Semantics(label: 'Theme', container: true)`.

No functional bugs: `_savePreference` keys match `core/state.dart:5347`, and `main.dart:156` follows OS brightness changes while in Auto mode.

**Test to add:** a golden or widget test at text scale 2.0 and 320 dp width asserting the chip fallback with no overflow.

---

## 3. AI response timeout (`_TimeoutScreen`): `settings_screen.dart:1253-1354`
**What it is / how reached:** Hub → Models → "AI response timeout". It offers radio presets (2/5/10/30/60 min, from `AppState.timeoutPresets`, `core/state.dart:5780`) plus a free slider.

**Findings**
- **P1 · perf · `settings_screen.dart:1341-1346`.** The Slider's `onChanged` calls `_savePreference` on **every drag frame**. Each call runs `SettingsActions.persist`, which does a SharedPreferences write plus `prefs.reload()` plus a readback (`core/settings_actions.dart:61-82`) and `notifyListeners()` on the whole `AppState`. That is dozens of disk round-trips per second and a full rebuild of every `AppState` listener while dragging. **Fix:** keep a local `_draft` in `onChanged` and persist only in `onChangeEnd`.
- **P1 · functional · `settings_screen.dart:1329-1337` + `core/state.dart:3798` + `core/agent_service.dart:12531-12537`.** The slider allows **5 s**. The value is used as the *first-byte* and *per-chunk idle* timeout, so any reasoning model that thinks for more than 5 s before its first token fails every turn with "no response … (first-byte timeout)". **Fix:** set the slider minimum to 30 s (and clamp in `setResponseTimeout`), and warn below 60 s.
- **P1 · copy/functional · `settings_screen.dart:1274-1276`, `138`.** The UI says "How long the agent may stream before being cut off" and "no cutoff of long answers". The core implements never-stop semantics: the value is the max *silence*, not the total stream length (`agent_service.dart:12525-12530`). Users will set 60 min believing it extends answers, which does nothing for active streams. **Fix:** retitle it "Response wait limit — how long to wait for the model to respond (or resume) before giving up".
- **P2 · functional · `settings_screen.dart:1311` vs `core/state.dart:5779`.** The 120 s preset is labelled "Default — balanced", but the actual default is `responseTimeoutSec = 300`. A fresh install therefore shows "5 minutes" selected and no "default" badge on it. **Fix:** move the "Default" subtitle to 300, and remove the unreachable `60 =>` case (60 is not in `timeoutPresets`).
- **P2 · UX · `settings_screen.dart:1329-1340`.** "Pick any number of seconds" is false: `divisions: 71` over 5–3600 gives about 50.6 s steps (5, 56, 106 …), so 60/120/300 cannot be hit exactly. The label also shows raw seconds ("3600s"). **Fix:** use a minutes-based slider (1–60, 59 divisions) and label it with `_fmt(min)`.

**Test to add:** a widget test that drags the slider and asserts that `SharedPreferences.setInt` was called exactly once (on `onChangeEnd`), and that the stored value is at least 30.

---

## 4. Context & output (`_ContextModelScreen`): `settings_screen.dart:1357-1501`
**What it is / how reached:** Hub → Models → "Context & output". It has radio lists for the context-window override (Auto, 32K…1M) and max output tokens (Auto, 2K…32K).

**Findings**
- **P1 · functional · `settings_screen.dart:1396-1399`, `1423-1426` vs `core/agent_service.dart:9402-9406`.** "Window used for compaction" is computed with `AgentService.contextWindowFor(model, providerId)`, which **ignores the user override**. Compaction actually uses `contextWindowForSession`, which returns the override when it is > 0. After the user picks 32K, the screen still says e.g. "1000K tokens". **Fix:** display `AgentService.contextWindowForSession(s)` when `s != null`, and show "(override)" or "(auto)" as the source.
- **P1 · functional · `core/state.dart:5795-5804` + `core/agent_service.dart:9865-9871`.** The override is **global and unclamped**. If a user sets 1M while chatting with a 32K/128K model, the compaction threshold becomes `min(0.8 × 1M, 100K) = 100K`. The request then exceeds the model's real window before compaction ever fires, and the provider returns context-length 400s. **Fix:** clamp the effective window to `min(override, measured/auto window)`, or make the override per model. In the UI, disable or warn on presets larger than the current model's window.
- **P2 · UX · `settings_screen.dart:1370-1377`.** Max output tops out at 32K, though current Claude/OpenAI/Gemini models allow 64K–128K output. It also offers no hint of the current model's cap (`ModelLimits.maxOutputTokens`). **Fix:** add 64K and 128K options (they are already clamped by `clampMaxOutput`, `agent_service.dart:9380`) and show "This model: up to N".
- **P2 · copy · `settings_screen.dart:1425`.** `(autoWindow / 1000).toStringAsFixed(0)` shows 32 768 as "33K", while the radio says "32K". With no active session it shows a 1M default for model "—". **Fix:** use the same `K = 1024`-aware formatter as the labels, and hide the line when `s == null`.
- **P2 · copy · `settings_screen.dart:1408-1411`.** "Values are exact deterministic choices — nothing is guessed or randomized" is internal-engineering copy. **Fix:** remove it.

**Test to add:** with override = 32768, the screen text contains "33K" **or** "32K (override)" and never the auto value. A unit test should assert that `contextWindowForSession` never exceeds the model's measured window.

---

## 5. Storage (`_StorageTile` → `_StorageScreen`): `settings_screen.dart:814-1088`
**What it is / how reached:** Hub → Backup → Storage. It measures the documents, temp and support directories, and offers Clear cache (confirmed) and Clear browser cookies.

**Findings**
- **P1 · UX/destructive · `settings_screen.dart:925-962`, `1063-1066`.** "Clear" on Browser cookies runs **immediately with no confirmation**. It logs the user out of every site in every per-session browser profile. **Fix:** add a confirm dialog like Clear cache ("Sign out of all websites in the in-app browser?").
- **P1 · copy · `settings_screen.dart:943-947`.** The success SnackBar reads "Default jar: cookies removed. 3 session profile(s) reported cleared. All-session completion cannot be verified; origin records retained for retry." That is internal state, not user copy. **Fix:** say "Signed out of websites in the in-app browser." Show the partial-failure variant only when `perProfile < profiles.length`.
- **P1 · functional · `settings_screen.dart:869-872`.** A measurement failure is swallowed: the screen renders "0 B" for every section and the total, with no error. **Fix:** keep `_error`, show "Couldn't measure storage — Retry", and show "—" instead of 0.
- **P2 · perf · `settings_screen.dart:772-794`, `857-861`.** `dirBytes` walks the docs and support trees (which contain the sandbox rootfs and workspaces, often more than 100k files) on the UI isolate's event loop. The spinner can run for tens of seconds, and the walk competes with frames. **Fix:** run it in `Isolate.run(() => dirBytes(...))` and cache the result for about 60 s.
- **P2 · layout · `settings_screen.dart:1008-1026`.** The Cache row puts the size **and** a `TextButton` inside a dense `ListTile.subtitle` Column, while every other row uses `trailing`. The result is misaligned and unusually tall. **Fix:** use `trailing: Row([Text(size), TextButton('Clear')])`, or the same `trailing` pattern as Cookies.
- **P2 · missing · `settings_screen.dart:1039-1046`.** "Support files … not deletable here" lumps the sandbox, workspaces and keys into one number. Users with a multi-GB sandbox have no way to reclaim space. **Fix:** break out "Sandbox runtime" and "Chat workspaces (per chat)", with links to Studio reinstall or delete.

**Test to add:** a widget test checking that tapping cookie "Clear" shows a dialog and that cancelling does not call `SessionBrowserProfiles.clearCookies`.

---

## 6. Export chats (`_ExportChatsScreen`): `settings_screen.dart:1503-1589`
**What it is / how reached:** Hub → Backup → "Export chats". It writes `ovid-sessions-<ts>.json` into the documents directory, then offers a "Share / save JSON" button.

**Findings**
- **P1 · privacy · `settings_screen.dart:1516-1526`.** Every export leaves a full plaintext copy of every chat in `getApplicationDocumentsDirectory()` that is never deleted. "Delete all data" does not remove these files either (see the P0 in §1), so chats survive a reset. **Fix:** write to `getTemporaryDirectory()/export-<ts>/`, delete the file after the share sheet returns, and add a cleanup on screen dispose.
- **P1 · UX · `settings_screen.dart:1529-1533`.** The SnackBar shows `/data/user/0/…/app_flutter/ovid-sessions-….json`, a private path the user cannot open. **Fix:** open the share sheet, or `FilePicker.platform.saveFile(...)` through SAF, immediately after export, and drop the path from the SnackBar.
- **P1 · perf · `settings_screen.dart:1520-1526`.** `JsonEncoder.withIndent('  ').convert(payload)` runs over every session, including tool output and compacted summaries, on the UI isolate. Heavy users get a multi-second freeze and a possible OOM, because the indented string is built in memory. **Fix:** use `Isolate.run`, with no indentation, streamed through `file.openWrite()`.
- **P1 · IA · `settings_screen.dart:279-285` vs §7.** There are two overlapping exports: this JSON export and the Portable transcript backup. The backup screen states that legacy JSON archives cannot be restored (`settings_backup_screen.dart:196`), so this export is a dead end for restore. **Fix:** merge both into one "Export data" screen with a single primary action (the ZIP backup) and "JSON (for other tools)" as a secondary format.
- **P2 · error copy · `settings_screen.dart:1537-1539`.** `'Export failed: $e'` shows a raw exception. **Fix:** show "Export failed. Free some space and try again.", and log `e` through `Diag`.
- **P2 · consistency · `settings_screen.dart:1548`, `1574-1584`.** The screen has no `backgroundColor: Aether.bg` and no `BackButton` (other sub-screens have both). The Share button sits flush under the primary button with no spacing. **Fix:** align it with the other screens and add a `SizedBox(height: 8)`.

**Test to add:** after export and share, no `ovid-sessions-*.json` remains in the documents directory.

---

## 7. About (`_AboutScreen`): `settings_screen.dart:1592-1697`
**What it is / how reached:** Hub → About → About. It shows the logo, version, tagline, Website, Privacy policy and copyright.

**Findings**
- **P1 · compliance · whole screen.** It has no "Open-source licenses" entry, and there is no `showLicensePage`/`LicensePage` anywhere in `lib/` (grep confirmed). The app bundles many MIT/BSD/Apache packages whose licenses require attribution. **Fix:** add `ListTile('Open-source licenses', onTap: () => showLicensePage(context: context, applicationName: 'Ovid AI', applicationVersion: kAppVersion))`.
- **P1 · store-policy · `settings_screen.dart:1650-1685`.** "Website" and "Privacy policy" open the same URL, as in §1. The About screen also lacks a Terms of Service link. **Fix:** use a dedicated `/privacy` URL and add a `/terms` link.
- **P2 · error handling · `settings_screen.dart:1650-1658`, `1676-1684`.** The `launchUrl` result is ignored and the call is un-awaited, so a failure is silent. **Fix:** await it, and on `false` show a SnackBar with "Copy link".
- **P2 · support · whole screen.** There is no build number, no "Send feedback / Report a problem", and no "Rate the app". **Fix:** show `kAppVersion+buildNumber` (selectable, long-press to copy) and add a Feedback row (mailto, or an in-app form attaching `Diag` logs).
- **P2 · copy · `settings_screen.dart:1627-1628`.** "Free by default" is a marketing claim beside paid Plan & Billing. **Fix:** ask the product/legal owner to confirm the wording.

**Test to add:** the About screen contains an "Open-source licenses" row that pushes `LicensePage`.

---

## 8. Skills (`SkillsScreen`): `settings_screen.dart:1704-1990`
**What it is / how reached:** Hub → Studio → Skills. It lists `.md` skills uploaded to `<docs>/skills`, supports upload (max 512 KB each), preview in a dialog, and delete with confirmation.

**Findings**
- **P1 · error state · `settings_screen.dart:1720-1733`.** `_reload()` has no try/catch. If `AgentService.I.refreshSkills()` or `getApplicationDocumentsDirectory()` throws, `_loading` stays `true` forever, the spinner never ends, and there is no retry. **Fix:** wrap it in try/catch/finally, set `_error`, and render an error state with a Retry button.
- **P1 · error handling · `settings_screen.dart:1735-1745`.** `FilePicker.platform.pickFiles` and the sync `createSync` are outside any try. A `PlatformException` (picker unavailable or permission denied) becomes an uncaught async error with no feedback. **Fix:** put a try/catch around the whole `_upload` body and show a SnackBar on error.
- **P2 · silent failure · `settings_screen.dart:1816-1822`.** A delete failure is swallowed (`Diag.swallow`), so the skill just reappears after reload with no message. **Fix:** show "Couldn't delete skill" on catch.
- **P2 · perf · `settings_screen.dart:1825-1851`.** Preview puts up to 512 KB in a single `Text` inside `SingleChildScrollView`. One huge paragraph layout janks the UI. **Fix:** split it into lines in a `ListView.builder` (or render Markdown lazily), and cap the preview at the first ~20 KB with "Show all".
- **P2 · error copy · `settings_screen.dart:1780`, `1788`.** Raw `$e` exceptions are joined into the SnackBar. **Fix:** map errors to "couldn't read file", and log the details.
- **P2 · UX.** The screen has no enable/disable toggle per skill (Claude parity), no "edit", and no search. The name is the file name, not the skill front-matter name, so a collision upload shows as `foo_1.md`. **Fix:** add a per-skill switch and show the front-matter `name`.

**Test to add:** with `refreshSkills` throwing, the screen shows an error and a Retry button rather than a spinner.

---

## 9. Agent presets (`_PresetsScreen` / `_PresetTile`): `settings_screen.dart:1992-2485`
**What it is / how reached:** Hub → Models → Agent presets. It lists the built-in and custom presets. Any preset can be duplicated as custom, and custom presets expose denied-tool chips, a plan-mode allowlist, a model pin and a temperature.

**Findings**
- **P1 · functional · `settings_screen.dart:1999-2002`, `2042-2060` + `core/presets.dart:223-245`.** The duplicate dialog exposes a free-text **Preset ID** with no validation. If the user types an existing ID such as `standard`, `code` or `plan`:
  - `saveCustom` adds a custom preset with that ID, and `byId` (`presets.dart:230-235`) checks custom presets first, so the built-in is **silently shadowed for every session**.
  - `PresetRegistry.all` then contains two entries with the same ID, so the `ListView` builds two `_PresetTile`s with an identical `ValueKey(preset.id)` (L2092). That is a duplicate-key assertion in debug and state mix-ups in release.
  - `customIds.contains('standard')` marks the built-in tile as "custom" and deletable.

  Separately, a `% 1000` suffix collision when duplicating twice silently overwrites an existing custom preset. **Fix:** remove the ID field and auto-generate `custom_<uuid>`. Failing that, validate `!PresetRegistry.all.any((p) => p.id == id)` and that the ID matches `^[a-z0-9_-]{1,40}$`, with an inline error.
- **P1 · UX · `settings_screen.dart:2041-2061`.** The duplicate gives no feedback (no SnackBar, no scroll to or expand the new preset), and the new preset is appended at the bottom of a long list. **Fix:** after save, show a SnackBar ("Created '<label>'"), scroll to the new tile and auto-expand it.
- **P1 · a11y/UX · `settings_screen.dart:2412-2438`.** The model-pin chips are the **union of every provider's model list**. With OpenRouter or another catalog that is hundreds of chips in one `Wrap`. The pin also stores only the model ID, not the provider, so the same ID on two gateways is ambiguous. **Fix:** replace the chips with a searchable model picker (reuse the chat model sheet) that stores `(providerId, model)`.
- **P2 · functional · `settings_screen.dart:2099`, `2334`, `2380`.** `onUpdate` calls `AppState.I.saveCustomPreset(updated)` without awaiting it or catching errors, so persist failures are lost silently. **Fix:** route the update through `_savePreference`-style error handling and show a SnackBar.
- **P2 · UX · `settings_screen.dart:2158-2177`.** The denied-tools editor is a hard-coded list of 18 tool IDs, with no MCP or plugin tools. Raw identifiers (`ralph`, `fs_edit`) are shown, with no descriptions. Labels and personas cannot be renamed or edited after creation. **Fix:** source the list from the live tool registry, group it, show friendly names, and add Edit label/persona.
- **P2 · async · `settings_screen.dart:1995`.** `void _duplicate(...) async` means an exception is unobserved. **Fix:** return `Future<void>`.

**Test to add:** a widget test that duplicates `standard` with ID `standard` and expects a validation error, with no change to `PresetRegistry.all.length`.

---

## 10. Background keep-alive (`_KeepAliveToggle`): `settings_screen.dart:1117-1150`, and Telemetry (`_TelemetryTile`): `settings_screen.dart:587-616`
**Findings**
- **P2 · consistency/error · `settings_screen.dart:1144` + `core/state.dart:5473-5490`.** Keep-alive writes through the `AppState.keepAliveEnabled` setter, which swallows pref failures, rather than `SettingsActions.persist`. It is the only toggle without failure feedback or "Saving…". It also does not request `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` or link to battery settings, which keep-alive actually needs. **Fix:** move it to `SettingsSwitchTile` with a `persist` setter, and add an "Allow background activity" button (`openAppSettings` / the battery-optimization intent) when ON.
- **P2 · copy · `settings_screen.dart:598-603`.** When the build has no Firebase, both subtitles read "Not configured in this build", but the switch is still rendered (disabled) and shows `consentGiven`. **Fix:** hide the row, or show "Unavailable" with no switch.

---

## 11. Delete app data (`SettingsResetScreen`): `settings_action_widgets.dart:126-239`
**What it is / how reached:** Hub → Backup → "Delete all data". It shows a status card, a danger button, a confirm dialog, then the verified reset and a result report.

**Findings**
- **P0 · data deletion scope.** See §1: the reset leaves API keys and secrets, settings, providers, MCP, presets, grants, skills, JSON exports and the cookie jar, yet reports "All data deleted." (L170).
- **P1 · destructive UX · `settings_action_widgets.dart:140-159`.** The confirm action "Delete everything" is a plain `TextButton` styled exactly like Cancel. It has no type-to-confirm and no reminder to export first. **Fix:** use a red `FilledButton`, add "Export my chats first" as a secondary action, and require typing DELETE (as ChatGPT's "Delete all chats" confirm does).
- **P2 · post-reset state · `settings_action_widgets.dart:166-174` + `settings_state_integration.dart:173-183` + `main.dart:187`.** The reset signs the user out (`FirebaseService.signOutLocal`). `SettingsScreen` is pushed on the root navigator (`sidebar.dart:291`, `chat_screen.dart:2558`), so only the `home` (`LoginGate`) swaps to `_LoginScreen` *underneath*. The Settings stack stays on top, and a signed-out user can keep browsing Providers, Plugins and similar screens. **Fix:** on success, `Navigator.of(context).popUntil((r) => r.isFirst)` and show the result as a SnackBar or banner on the login screen.
- **P2 · raw error text · `settings_action_widgets.dart:171-173`.** The incomplete-reset report prints internal store IDs and exception strings (`private-sync: StateError(...)`). **Fix:** map store IDs to user names ("Chats", "Memory", "Sync") and put raw errors behind "Details".
- **P2 · consistency · `settings_action_widgets.dart:190-191`.** The screen has no `backgroundColor: Aether.bg`. Its title "Delete app data" does not match the row "Delete all data". **Fix:** align the two.

**Test to add:** after a successful reset, the navigator returns to the root, and `ovidSecureStorage().readAll()` is empty.

---

## 12. Portable transcript backup (`SettingsBackupScreen`): `settings_backup_screen.dart:14-283`
**What it is / how reached:** Hub → Backup → "Portable transcript backup". It offers Export ZIP (transcripts plus workspace attachments), Import (validate only), Share archive, and Restore as new sessions.

**Findings**
- **P1 · dead affordance · `settings_backup_screen.dart:222`.** `Text('View backup files', style: AetherType.caption)` reads like a link or action label but has no handler. **Fix:** remove it, or make it a `TextButton` that lists previous exports in `temp/ovid-backup-*`.
- **P1 · UX/naming · `settings_backup_screen.dart:213-217`, `251-257`.** The button labelled **"Import"** only *validates*, and the real import ("Restore as new sessions") is a separate button placed after "Share archive". Users will tap Import, see "Archive valid … No data restored", and think the import failed. **Fix:** use one "Import backup…" button that validates, shows "N chats, M attachments — Restore?", and restores on confirm. Put Share next to Export.
- **P1 · capacity · `core/settings_backup_service.dart:46-51`, `190-215`, `333-340`.** The export **fails entirely** above 1000 sessions, 20 000 messages, 1 MiB in any single message, or an 8 MiB manifest or 64 MiB archive. Long-term heavy users (the 10M DAU target) cannot back up at all. The only feedback is "Operation failed during Export. No data was changed. FormatException: Too many messages." **Fix:** split the export into multiple archives (chunk by sessions), or let the user select a date range or sessions. At minimum, pre-check and tell the user which limit was hit and how to narrow the export.
- **P1 · misleading error · `settings_backup_screen.dart:35-39`.** Every failure says "No data was changed." A restore rollback failure, however, throws "Rollback could not be verified … Attachment copies retained" (`core/settings_state_integration.dart:450-459`), so data *may* have changed. The message also appends raw `$e`. **Fix:** derive the message from the error type. Say "no changes" only for pre-publish failures, and put the raw error behind "Details".
- **P2 · perf · `settings_backup_screen.dart:52`.** `service.export` (zip encoding, attachment reads, `jsonEncode`) runs on the UI isolate. **Fix:** use `Isolate.run`.
- **P2 · cleanup · `settings_backup_screen.dart:53-61`.** Each export creates a new `temp/ovid-backup-*` directory that is never removed, so plaintext transcripts linger until the user clears the cache. **Fix:** delete the previous `_exported` directory on a new export and in `dispose`.
- **P2 · UX · `settings_backup_screen.dart:107-115`.** Restore runs with no confirmation and no count of what will be added. Afterwards it says "new, inactive sessions" but gives no link to them. **Fix:** add a confirm dialog with counts and an "Open restored chats" action.
- **P2 · copy · `settings_backup_screen.dart:176-198`.** Three dense paragraphs of limits (MiB, manifest size, sessions/messages) and internal terms ("atomic state publisher", "manifest") make for poor reading. **Fix:** use one sentence plus a "Limits" expandable section.
- **P2 · a11y · `settings_backup_screen.dart:151-165`.** A live region announces the status, and a second live region (L273) also announces `_status`. TalkBack double-announces. **Fix:** keep one live region.

**Missing features:** scheduled/automatic backup (to Drive or SAF folder), and a backup that includes settings. `captureSettings` exists, but the UI never passes `settings:`, so settings are not part of the backup (the copy says this, but ChatGPT/Claude restore everything from the cloud).

**Test to add:** with 20 001 messages, Export shows a specific "too many messages — export fewer chats" message instead of a raw `FormatException`.

---

## 13. Device health (`SettingsHealthScreen`): `settings_health_screen.dart:15-527`
**What it is / how reached:** Hub → Health card → "Device health" (`settings_screen.dart:310-318`, via `_navTileWithAction` with a duplicate "Health" ghost button). On open it runs `HealthService.runChecks()` (`core/health_service.dart:271-395`). That makes 17 sequential probes: sandbox prefix, 15 sandbox commands (`bash --version`, `apt`, `python`, … `tmux -V`), a workspace write and provider configuration. Each probe has a 10 s timeout. The screen shows a score ring (0–100), a "Repair selected runtimes" card, one card per check with a checkbox on repairable failures, a repair log and a "Re-run checks" button. Repair runs `ovid-pkg install <pkgs>` through `HealthService.repair` (12 min deadline).

**Findings**
- **P1 · UX/destructive · `settings_health_screen.dart:55-59` + `core/health_service.dart:164-170`.** `dispose()` calls `cancelRepair()` when the user leaves the screen during a repair. A system-back press or swipe therefore silently kills an `ovid-pkg install` that may be minutes in. The service's own message says "completed package changes may remain", which can leave a half-installed package set or a held dpkg lock. No `PopScope` warning is shown. **Fix:** let the repair keep running in `HealthService` after pop: drop the cancel-on-dispose, show a "Repairing runtimes…" chip or notification elsewhere, and re-attach the log when the screen is reopened. If it has to stay screen-bound, wrap the screen in `PopScope(canPop: !_health.repairing)` with a "Stop repair and leave?" confirm.
- **P1 · UX/progress · `settings_health_screen.dart:74-81`, `199-203` + `core/health_service.dart:175-197`.** The worker emits only two log lines ("Repairing signed packages: …" and "Package command completed…"). `execChecked`'s stdout is not streamed to `onLine`. For an install that can take up to 12 minutes, the user sees one static line and a disabled button, with no spinner or progress bar in this screen (`_RepairControls` has no indicator, unlike `health_screen.dart:447-450`). They will assume it is hung and leave, which triggers the cancel above. **Fix:** stream installer output lines to `onLine` (use the line-streaming exec used by the Studio terminal), and add an indeterminate `LinearProgressIndicator(semanticsLabel: 'Repairing runtimes')` plus elapsed time in `_RepairControls` while `repairing`.
- **P1 · missing CTA · `core/health_service.dart:277`, `319`, `387` → rendered at `settings_health_screen.dart:189-197`.** With no sandbox installed (the default fresh-install state) the screen shows a low score and **16 near-identical cards**: "Missing — open Studio to install the sandbox." / "Unavailable without the sandbox. Open Studio to install." Provider failure says "choose a provider … in Settings → Providers". None of these has a button. The user has to back out and find Studio or Providers themselves. **Fix:** when `sandbox` fails, collapse the 15 command checks into one "Sandbox not installed" card with an "Install sandbox" button (push `SandboxSetupScreen`). Give the provider card an "Open Providers" button.
- **P1 · feature regression · whole screen vs `health_screen.dart:249-274`.** The orphaned `HealthScreen` (§14) has the **Services (MCP & plugins)** status section and the **Hard reset sandbox** action. The reachable screen has neither, so users have no in-app way to see a failed MCP server's status in one place or to recover a corrupt sandbox from Settings. **Fix:** port `_ServiceCard` and `_DangerActionsCard` (with its confirm dialog) into `SettingsHealthScreen`, then delete `health_screen.dart` (see §14).
- **P2 · copy bug · `settings_health_screen.dart:90-92` + `core/health_service.dart:50-51`.** `HealthRepairCancelled.toString()` is "Repair cancelled; completed package changes may remain. Re-run checks.", so `replaceFirst('HealthRepairCancelled: ', '')` matches nothing. The UI reads **"Repair cancelled: Repair cancelled; completed package changes may remain. Re-run checks."** **Fix:** use the fixed string `'Repair cancelled. Some packages may already be installed. Re-run checks.'`.
- **P2 · raw error text · `settings_health_screen.dart:92` and check details from `core/health_service.dart:286`, `327`, `330`, `362`.** "Repair failed: $e" shows `Bad state: Signed package repair failed (exit 100).` / `Unsupported operation: …`. Check details show enum names and raw output such as `missingConfiguration: …`, `failed: TimeoutException after 0:00:10.000000: Future not completed`, or up to 600 chars of stderr. **Fix:** map exception types to user sentences ("Couldn't install packages — check your connection and retry"). Show a short status line, and put raw output behind an expandable "Details" with a Copy button (useful for support).
- **P2 · copy/logic · `settings_health_screen.dart:276`.** `'$totalChecks of $totalChecks checks completed'` always prints "17 of 17". It carries no information and is wrong while a re-check is in flight (the stale report is shown). **Fix:** show "Last checked hh:mm · N passed" (store a timestamp in `HealthReport`), or "Checking…" while `_health.checking`.
- **P2 · copy/logic · `settings_health_screen.dart:130-138`, `284-292`.** "Needs attention" counts only `missing`/`missingConfiguration`, but the next line says "`failedChecks` of N checks need attention or recovery" using all failures. Two different numbers carry the same label. **Fix:** use one taxonomy, e.g. "Passed · Missing · Broken", where Broken = denied/unsupported/failed, and drop the redundant caption.
- **P2 · UX · `settings_health_screen.dart:168-182`, `363-384`.** `_RepairControls` always renders. When everything passes, or nothing is repairable, it still shows "Select runtimes to repair · Tick a failed runtime below… · 0 selected · 0 repairable" and a disabled primary button. **Fix:** render the card only when `repairable > 0`. Pre-select all repairable failures and offer "Repair all (N)" as the primary action, so the user doesn't have to tick each item.
- **P2 · a11y · `settings_health_screen.dart:248-273`, `511-521`.** The score ring and number expose no semantic meaning (TalkBack reads "85"). The 48 dp checkbox is the only tap target, so the card itself is not tappable. The dot colour is the only signal of status per check: there is no status word, unlike `health_screen.dart:548-558`. **Fix:** wrap the ring in `Semantics(label: 'Health score $score of 100')` and exclude its children. Make each selectable check a `CheckboxListTile`/`InkWell` over the whole card with `MergeSemantics`, and add the status label text ("Missing", "Permission denied", …).
- **P2 · perf · `settings_health_screen.dart:29-33` + `core/health_service.dart:316-332`.** Every open of the screen spawns 16 sandbox processes sequentially. On a slow or proot device that takes several seconds, and up to about 170 s worst case when probes hang (10 s timeout each). The results are not cached. **Fix:** run the probes with bounded concurrency (`Future.wait` in chunks of 4). Skip the auto-run if `lastReport` is younger than about 60 s, and show "Last checked …" with a manual refresh.
- **P2 · layout · `settings_health_screen.dart:205-210`.** "Re-run checks" sits at the very bottom, below 17 cards and the log. **Fix:** move it to an `AppBar` `IconButton(Icons.refresh, tooltip: 'Re-run checks')`, or add pull-to-refresh (`RefreshIndicator`).
- **P2 · copy · `settings_health_screen.dart:122`, `163-164`, `322`.** The title "Device health" is misleading, because it checks the Linux sandbox and AI configuration, not the device. The subtitle "A passing version probe is not proof of network access…" and the `_NoWorkerCard` text ("no cancellable runtime worker is connected") are engineering copy. (`_NoWorkerCard` is unreachable in production because `HealthService.I` always binds `_repairPackages`, `core/health_service.dart:101-105`.) **Fix:** retitle to "Sandbox & setup health", use one plain subtitle, and delete or reword the no-worker card.

**Missing features**
- "Copy diagnostics / Send to support" (a report of every check, app version and device ABI). ChatGPT/Claude have "Report a problem" with logs attached.
- A per-check "Retry" or "Fix" action (e.g. Open Providers, Install sandbox, Grant storage).
- Network/API reachability check: the screen explicitly says it doesn't test it. A "Test connection to provider" probe (models call) is the single most useful diagnostic for "AI not responding".
- MCP/plugin service health (present only in the dead `HealthScreen`).

**Test to add**
- Widget test with an injected `HealthService` whose worker never completes: start a repair, pop the route, and assert the worker's `cancellation.isCancelled == false` (after the fix), or that a confirm dialog appears.
- Widget test that cancels a repair and asserts the result text contains "Repair cancelled" exactly once.
- Widget test with `installed: () async => false` asserting a single "Install sandbox" CTA instead of 15 "Unavailable" cards.

---

## 14. Legacy device health (`HealthScreen`): `health_screen.dart:18-705`. **Confirmed unreachable**
**What it is / how reached:** It is a second, older "Device health" screen. `grep -rn "HealthScreen\b" lib/` finds **no reference outside its own file**. Settings pushes `SettingsHealthScreen` (`settings_screen.dart:316`), and no route, shell or deep link builds `HealthScreen`. Only tests import it: `test/health_premium_test.dart`, `test/ui_redesign/health_screen_test.dart`, `test/ui_finish_10_settings_test.dart:334-351`, `test/core_regression_test.dart:10623`, `12700-12727`. It is about 700 lines of dead UI kept alive by tests. Compared with the reachable screen it adds a Services (MCP/plugins) section (`L249-266`), a Hard reset sandbox action with a confirm dialog (`L135-156`, `L665-705`), status words per check, and a progress bar during repair.

**Findings**
- **P1 · dead code/IA · whole file.** Two divergent implementations of the same screen, with the same title "Device health", have to be kept in sync with `HealthService`, and CI tests assert behaviour that users can never reach (e.g. the `K6` hard-reset regression test). Meanwhile the reachable screen lacks the hard-reset and services features (see §13). **Fix:** merge: move `_ServiceCard`, `_DangerActionsCard` + `_confirmHardReset`/`_hardResetSandbox`, and the per-check status label into `SettingsHealthScreen`. Delete `health_screen.dart` and repoint its tests to `SettingsHealthScreen`.
- Defects to fix while porting (they would otherwise move across with the code):
  - **P1 · functional · `health_screen.dart:69-94`.** `_hardResetSandbox` calls `SandboxService.I.uninstall()` with no check that an agent run, Studio terminal or MCP stdio server is currently using the sandbox. Running processes lose their rootfs mid-flight. The confirm text also says "Existing app data outside the sandbox is not affected", but the per-chat workspaces under the sandbox *are* deleted and the dialog doesn't say so. **Fix:** block the reset while `AgentService` has running turns, or stop them first with a warning. List what will be lost ("installed packages, files in chat workspaces"), and use a red destructive button.
  - **P2 · state · `health_screen.dart:72-78`, `89`.** `_repairLog.add(...)` happens outside `setState`, followed by an empty `setState(() {})`. The catch path mutates state even when unmounted. A reset failure shows only `ovid: reset failed: $e` in the mono log, not in a feedback card. **Fix:** surface the failure in `_repairFeedback` with friendly copy.
  - **P2 · raw error text · `health_screen.dart:55`, `126`.** "Health checks failed: $e" and "Repair failed: $e" show raw exceptions. **Fix:** same as §13.
  - **P2 · perf · `health_screen.dart:167`.** `AnimatedBuilder` listens to all of `AppState.I` only to read `serviceStatus`, so every app-wide `notifyListeners` (including stream ticks) rebuilds the whole list. **Fix:** use `Selector`/`ValueListenableBuilder` on a dedicated `serviceStatus` notifier.
  - **P2 · a11y · `health_screen.dart:655-658`.** Each service's "Retry" re-runs *all* runtime probes, not that service's connection, and the button has no semantic label naming the service. **Fix:** call a per-service reconnect (MCP restart), and use `Semantics(label: 'Retry ${name}')`.

**Missing features:** n/a (the screen is to be deleted; its features move to §13).

**Test to add:** a static test asserting `lib/` contains no file that defines a `Widget` never referenced from `lib/` (or simply: after the merge, `health_screen.dart` no longer exists and `SettingsHealthScreen` renders a "Services" section and a "Hard reset the sandbox" button).

---

## 15. Permissions (`PermissionsScreen`): `permissions_screen.dart:31-580`
**What it is / how reached:** Hub → Autonomy card → "Permissions" (`settings_screen.dart:165-180`, subtitle "Paths and hosts the agent may always access"). The screen is read-only apart from revoke. It has three sections:
- **Autonomy:** static explanation, three non-interactive "mode" boxes, and a list of legacy global grants that are ignored at runtime.
- **Granted scopes:** path and host allow/deny decisions held by `AgentService.I.currentSession`. Each has a Revoke button and a confirm dialog.
- **Pending requests:** a permanently static card.

Revoke goes through `AgentService.revokeSessionPermissionGrant` (`core/agent_service.dart:5949-5955`) and `AppState.revokeGlobalPermissionGrant` (`core/state.dart:5761-5772`).

**Findings**
- **P1 · functional/IA · `permissions_screen.dart:190-200` + `core/agent_service.dart:1219-1224`, `5945`.** "Granted scopes" shows only the grants of `currentSession` (`_runCtx?.session ?? AppState.I.activeSession`). Grants are persisted per chat and survive restarts (copy at L76-78), so a user who has tapped "Always allow" in many chats can see **one chat's** grants at a time. To review anything else they have to open each chat and come back to Settings. The screen also never names *which* conversation it is showing. When no chat is active (`currentSession == null`) it says "No decisions for this session yet", which is false reassurance. **Fix:** list grants across all sessions, grouped by chat title (with "Open chat" and per-chat "Revoke all"), plus a global "Revoke all remembered decisions". At minimum, show "Showing: <chat title>".
- **P1 · missing/security · whole screen vs `core/agent_service.dart:5957-5963`.** Tool-level "Always allow" approvals (`_alwaysAllowedTools`) and remembered denials (`_deniedApprovals`) are held per session in memory and **not shown or revocable anywhere here**. A user who tapped "Always allow" on a shell or MCP tool cannot undo it short of killing the app. Claude Code's `/permissions` lists and edits tool allow/deny rules (`Bash(npm test:*)`, `mcp__server__tool`). **Fix:** add a "Tools allowed in this chat" section backed by a public read/revoke API on `AgentService` for `_alwaysAllowedTools` and `_deniedApprovals`. For longer-term parity, add persisted, user-editable allow/deny rules for tools and MCP servers.
- **P2 · functional/dead end · `permissions_screen.dart:107-116`, `143-155`, `202-207`.** When two grants share kind and value (e.g. one allow and one deny for the same host, or legacy duplicates), revoke is refused. The global path says "This screen cannot safely remove only the selected identity". The session path shows the wrong message: "This decision is no longer in the current session." Yet both core methods already remove **all** grants with that kind and value (`agent_service.dart:5952`, `state.dart:5763-5765`), so the guard protects nothing and leaves the entry impossible to remove. **Fix:** drop the single-identity guard and revoke by `(kind, value)` with copy like "Removes all decisions for host X". Alternatively, add identity-precise revoke methods to the core.
- **P2 · copy/trust · `permissions_screen.dart:129-130`, `165-166`.** Every *successful* revoke says "…Persistence is not confirmed; retry if it returns after reopening." The cause is that `_persistGlobalPermissionGrants` swallows write errors (`core/state.dart:5717-5727`) and `revokeSessionPermissionGrant` returns `void`. The result is that the user is told on every success that it might not have worked. **Fix:** make both core methods return a verified `bool` (persist plus readback, as `SettingsActions.persist` does) and show "Revoked access to host X" or a real error.
- **P2 · UX/false affordance · `permissions_screen.dart:59-71`, `255-278`, `347-396`.** The "Autonomy" section claims to cover "How much the agent may decide on its own", but nothing in it can be changed. The three `_AutonomyMode` boxes are styled like a selectable radio group (accent border = "active"), yet they are static text, and "All sessions (ignored)" shows up as a greyed choice. The actual autonomy/mode controls live in chat and presets. **Fix:** replace the section with one short explanation and a link to where the mode is chosen. Show the legacy list only when non-empty, with a single "Clear legacy grants" button.
- **P2 · UX · `permissions_screen.dart:86-94`, `548-572`.** "Pending requests" is empty by design and always shows the same static text. It takes up a whole section. **Fix:** remove it, or fold one sentence into the Granted-scopes empty state.
- **P2 · layout · `permissions_screen.dart:487-543`.** `_GrantRow` stacks the icon on its own line above the label, then the subtitle, then a left-aligned `TextButton`, so each grant takes about 4 lines. The `Tooltip('Revoke')` duplicates the visible label. Long paths wrap with no middle-ellipsis, and the label can't be selected or copied. **Fix:** use `ListTile(leading: icon, title: SelectableText(value, maxLines: 2), subtitle: …, trailing: IconButton(Icons.close, tooltip: 'Revoke access to …'))`.
- **P2 · copy · `permissions_screen.dart:61-65`, `246-251`, `476-478`, `574-579`.** The copy is dense policy text ("workspace-confined modes", "mode-specific restrictions still apply", "THIS session", "Host and subdomains, all ports and paths · allowed · this session, all modes"). `_label` prefixes "path"/"host" and repeats "· denied", which the subtitle already says. The hub subtitle "may always access" ignores deny decisions. **Fix:** use plain titles ("Allowed: github.com and subdomains", "Blocked: /sdcard/DCIM") and one-line subtitles, and change the hub subtitle to "Files and websites you've allowed or blocked".
- **P2 · perf · `permissions_screen.dart:50`.** `ListenableBuilder` listens to the whole of `AppState.I` and `AgentService.I`, which notify on every run, state or stream event, so the screen rebuilds and refilters on each tick while an agent runs in the background. **Fix:** listen to a narrow `ValueListenable` of grants, or use `Selector` on `session.grants.length` plus a version counter.

**Missing features**
- Android runtime permissions overview: notifications, microphone (voice input), camera/photos (attach), storage/SAF folders and battery optimisation. ChatGPT and Claude show these with "Open system settings". Today the only place they appear is scattered across chat prompts.
- Default policy controls, e.g. "Always ask before network access" or "Auto-approve read-only tools", which match Claude Code's permission modes.
- Revoke-all, and search across grants.

**Test to add**
- Widget test: seed two sessions each with a host grant and make session A active. After the fix, the screen lists both, grouped by chat title. Before the fix, document that only A is shown.
- Widget test: seed one session with an allow and a deny for the same host, tap Revoke on one, confirm, and assert both are removed and the SnackBar does not say "no longer in the current session".

---

## 16. Memory files (`MemoryScreen` + `_MemoryFileSheet`): `memory_screen.dart:29-723`
**What it is / how reached:** Hub → Autonomy card → "Memory files" (`settings_screen.dart:194-201`). It is a plain-text Markdown editor over `MemoryStore` (`core/memory_store.dart`), which allows 32 files per scope and 32 KiB per file. It has Global/Session scope chips (Session only when a chat is active), "Add file" and "Import .md" buttons, a list of file cards (pin glyph and an overflow menu with Edit/Delete), a 6–12-line monospace editor, and a bottom bar with Save, Reload and Add memory. The "Add memory file" bottom sheet asks for a filename. A `PopScope` guards unsaved edits.

**Findings**
- **P1 · privacy/missing · `memory_screen.dart:246-265`, `449-451` + `core/memory_store.dart` (no per-file delete; only `deleteSession`/`deleteAll`, L225-230).** Users **cannot delete a memory file**. The overflow "Delete" opens a dialog: "not supported by the memory store … ask an operator to remove the file off-device". The agent writes these files itself through `memory_save` (`core/agent_service.dart:8459`, `14327`), so a user who finds something they don't want remembered can only blank the file. The file name stays, the 32-file cap stays consumed, and per §1 even "Delete all data" is unclear. ChatGPT and Claude both let you delete individual memories and "Clear all memory". **Fix:** add `MemoryStore.delete(owner, name)` (refuse `MEMORY.md`, or truncate it) with a confirm dialog. Add a "Clear all memory" (global + sessions) action calling `deleteAll()`. Remove the "operator" copy.
- **P1 · data loss · `memory_screen.dart:112-131`, `242-244` + `core/memory_store.dart:152-156`.** While the user edits, an agent run can `memory_save`/append to the same file. Save then fails with raw text **"Bad state: Memory changed or revision missing. Reload before saving."** The only way out is Reload, which shows "Discard unsaved changes?" and throws away the user's edit. No merge, no "overwrite" and no copy is offered. **Fix:** on a revision conflict, show a dialog with "Keep mine (overwrite)" (re-read the revision, then save), "Use latest (discard mine)" and "Copy my text". Optionally show a diff. Also listen for store changes and show an "Updated by Ovid — Reload" banner before the user saves.
- **P1 · UX/IA · whole screen.** Memory is shown as raw files in a 12-line monospace `TextField`. No individual "memories" are listed, there is no "what Ovid remembers about you" summary, no search, and no indicator of which file was last changed by the agent. Non-technical users (the 10M DAU target) won't understand `MEMORY.md`, scopes or "32 KiB per file". **Fix:** for phase 1, show a readable list of memory entries (split `MEMORY.md` by bullet or heading) with per-item delete, and keep the raw editor behind "Edit as Markdown". Show "Last updated by Ovid · time" per file.
- **P2 · dead code · `memory_screen.dart:370-373`, `377-379`, `409-415`, `422-433` + `core/memory_store.dart:83`.** `MemoryStore.list` always includes `MEMORY.md`, so `_files.isEmpty` is never true. The empty state ("No memories yet"), the FAB and the conditional editor/bottom-bar hiding cannot be reached, and a brand-new user sees an empty `MEMORY.md` editor with no guidance. **Fix:** base the empty state on "all files empty" and show a helpful hint ("Ovid saves things you ask it to remember here. You can also add notes yourself."). Delete the unreachable branches.
- **P2 · duplicated actions · `memory_screen.dart:355-366`, `391-404`.** "Add file" (top) and "Add memory" (bottom bar) open the same sheet. "Save" is a primary button that stays enabled when nothing changed, and "Reload" is a ghost button between two primaries. **Fix:** keep a single "New file" action (an AppBar icon or a menu item), enable Save only when `_dirty`, and move Reload into an AppBar overflow.
- **P2 · raw error text · `memory_screen.dart:68`, `88`, `130`, `238`, `660`.** Every error is `'$e'`, e.g. "Bad state: notes.md already exists; read it and use replace with its revision." (an agent-facing message from `memory_store.dart:144-146`), "Bad state: The owning chat was deleted or changed." or "FileSystemException: …". **Fix:** map store errors to user copy ("A file with that name already exists", "This chat was deleted — showing Global memory"), and on an owner change automatically switch back to Global.
- **P2 · fake affordance · `memory_screen.dart:556-565`.** Every non-entry file shows an outlined pin with the tooltip "Pinning additional files is not supported yet". **Fix:** remove the pin for non-entry files and label MEMORY.md "Main".
- **P2 · state/UX · `memory_screen.dart:51`, `56`, `324-329`, `579-582`.** The "Session" chip doesn't say *which* chat (it binds `activeSessionId` at open). Each row's caption repeats "Global memory" or "Session memory", so it carries no per-file information. The screen also doesn't show when the hub's Memory master switch is OFF, so users edit memory that won't be used. **Fix:** label the chip "This chat: <title>". Use the row caption for size and last-modified ("1.2 KB · edited 2h ago"). Show a banner "Memory is off — Ovid won't use these files. Turn on" when `!memoryEnabled`.
- **P2 · editor UX · `memory_screen.dart:496-512`.** `maxLines: 12` inside an outer `SingleChildScrollView` produces nested scrolling for a file up to 32 KiB, which is awkward on phones, and there is no character/size counter toward the 32 KiB limit. **Fix:** give the editor its own route or a full-height `Expanded` editor with `expands: true`, and add a `"$bytes / 32 KB"` counter that turns red near the limit.
- **P2 · perf · `memory_screen.dart:78-90`, `112-124`, `180-185`.** `read`/`list`/`save` and the import read use synchronous file IO (`openSync`, `listSync`) on the UI isolate. That is acceptable for 32 KiB, but `_save` also calls `AppState.I.refresh()`, which rebuilds every `AppState` listener. **Fix:** make the store calls async, and drop the global `refresh()` (or notify only memory listeners).
- **P2 · a11y · `memory_screen.dart:545-617`.** The selected file is shown only by bold text and a surface tint, with no `Semantics(selected: true)`. The overflow `PopupMenuButton` has the generic tooltip "More actions" rather than one naming the file. **Fix:** add `Semantics(selected: selected, button: true, label: 'Memory file $name')` and the tooltip `'Actions for $name'`.

**Missing features**
- Per-memory delete and "Clear all memory" (above). A "Memory used in this reply" indicator in chat (ChatGPT's "Memory updated" chip linking here).
- Temporary/incognito chat that neither reads nor writes memory.
- Export of memory files: no export API, and the backup in §12 doesn't state whether memory is included.

**Test to add**
- Widget test with an injected `MemoryStore`: open `MEMORY.md`, edit, write to the same file through the store (simulating the agent), tap Save, and assert a conflict dialog that offers "Keep mine", with the user's text preserved.
- Widget test: after delete is implemented, Delete on `notes.md` with confirm removes it from the list, and `store.list(null)` no longer contains it.

---

## Group summary

**Counts (sections 1–16):** P0 = 2 (the same reset-scope defect, recorded in §1 and §11) · P1 = 40 · P2 = 65.

**Top 10 fixes (do them in this order)**
| # | Fix | Where | Priority | Effort |
|---|---|---|---|---|
| 1 | Make "Delete all data" actually delete secrets (`ovidSecureStorage().deleteAll()`), prefs, providers/MCP/plugins, presets, grants, skills, JSON exports, cache and cookies. Until then, fix the copy. Pop to root after reset. | §1, §11 | P0 | M |
| 2 | Add a per-file memory delete and "Clear all memory". Handle revision conflicts with Keep mine / Use latest instead of dropping edits. | §16 | P1 | M |
| 3 | Health: stop cancelling the repair on screen pop (or confirm first), stream installer output and show progress, and add "Install sandbox" / "Open Providers" CTAs. Port the Services and Hard-reset features in from `HealthScreen`, then delete `health_screen.dart`. | §13, §14 | P1 | M |
| 4 | Permissions: list grants across all chats, expose and revoke tool-level "Always allow" approvals, remove the single-identity guard, and return verified results. | §15 | P1 | M |
| 5 | Add an Open-source licenses page (`showLicensePage`), a dedicated Privacy policy and Terms URL, and check the `launchUrl` result. | §1, §7 | P1 | S |
| 6 | Response timeout: persist on `onChangeEnd` only, set the minimum to 30 s, fix the "Default" label, and retitle as a wait limit. | §3 | P1 | S |
| 7 | Context override: show the effective (override) window, and clamp it to the model's real window. | §4 | P1 | S |
| 8 | Export and backup hygiene: write exports to temp and delete them after sharing, run on an isolate, merge the two export screens, and turn the validate-only "Import" into a real import. Chunk large backups. | §6, §12 | P1 | M |
| 9 | Preset duplicate: auto-generate IDs (no shadowing of built-ins or duplicate keys), give feedback after creation, and add a searchable model pin. | §9 | P1 | S |
| 10 | Settings a11y and IA: wrap `SettingsSwitchTile` in `MergeSemantics`, handle notification permission state, gate Share-memory on Memory, add a cookie-clear confirm, and fix the Skills error states. Then re-group the hub (Account / Personalization / Data controls / Advanced) and add Language and Text-size rows. | §1, §5, §8 | P1 | M (a11y and fixes S, re-IA M) |

**Cross-cutting themes**
- Raw exception text (`'$e'`) reaches users on almost every screen in this group: Export, Skills, Backup, Health, Memory and Reset. Add one shared `userMessageFor(Object e)` mapper plus a "Details / Copy" disclosure.
- Heavy work runs on the UI isolate: storage walk, JSON export, ZIP backup and slider persistence. Standardise on `Isolate.run` for anything that touches more than one file.
- Copy is written for engineers ("atomic state publisher", "cancellable runtime worker", "Persistence is not confirmed"). A single copy pass across the Settings area is worth doing.
- Several screens show controls that do nothing: the dead "View backup files" text, the static Autonomy "modes", the "Pending requests" card, the pin glyphs, the Delete that cannot delete, and the unreachable `HealthScreen` and Memory empty state. Remove them or make them work.
