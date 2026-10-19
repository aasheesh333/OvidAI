# 04 — Settings and configuration audit

Scope: `lib/ui/settings_screen.dart` and the Settings sub-screens (health, backup, providers, BYOK, permissions, memory, presets, context, timeout, storage, notifications, about), `history_import_sheet.dart`, `link_safety.dart`, `aether_confirm.dart`, and the supporting `lib/core` files. Each setting was traced to the wire (`lib/core/cloud/cloud_rest.dart`, `cloud_agent_facade.dart`) and then to the server (`cloud/packages/shared/src/rest.ts`, `cloud/apps/gateway/src/routes/*`, `cloud/apps/worker/src/*`, `cloud/packages/agent-core/src/*`).

Branch `feat/ovid-cloud` @ `fdf2c5f`. This was a read-only code audit; nothing was run on the emulator. "Suspected" means the code points strongly that way but needs to be reproduced on the emulator before fixing (see memory: test before fix).

## What the client actually sends

The only per-turn fields the app puts on the wire are in `POST /sessions/:id/messages` (`cloud_rest.dart:403-421`; server schema `sendMessageBodySchema` in `shared/src/rest.ts:147`): `content`, `attachmentIds`, `clientMsgId` and `maxOutputTokens` (capped at 8192). Session create sends only `title`. `PATCH /sessions/:id` sends only `title` and `mode`. The gateway enqueues the run with `{runId, sessionId, userId, prompt, tier, attachmentIds?, maxOutputTokens?}` (`gateway/src/routes/messages.ts:309-330`). It sends no model, preset, memory flag, temperature, tool deny-list or `byokKeyId`.

| Setting (Settings row) | Persisted | Reaches server | Server honours it | Verdict |
|---|---|---|---|---|
| Theme | yes (`ovid_theme_mode`) | n/a | n/a | Works. The label is wrong (SE-022) |
| Memory | yes | **no** | worker never sets `memoryEnabled` (defaults to true) and `memoryContext` is hard-coded `""` (`agent-core/src/loop.ts:853`) | **Dead** (SE-005) |
| Share session memory | yes | **no** | no such concept server-side | **Dead** (SE-005) |
| Memory files | n/a | n/a | placeholder screen | **Misleading** (SE-006) |
| Show reasoning | yes | n/a (display only) | n/a | Works (transcript filter) |
| Export / Import backup | local | export reads the local cache; restore never uploads | n/a | **Broken for cloud chats** (SE-008, SE-009) |
| Permissions | n/a | n/a | placeholder | **Misleading** (SE-006) |
| Crash reports & analytics | yes | Firebase | n/a | Works. Copy is odd (SE-030) |
| Storage | n/a | n/a | n/a | Works. Copy is stale (SE-024) |
| Delete all data | local only | **no** | cloud chats, BYOK escrow and device token stay | **Misleading / privacy** (SE-001, SE-002, SE-003) |
| Providers (device BYOK) | secure storage | **no** | runs never use device keys or the chosen model | **Dead** (SE-004) |
| Bring your own keys (escrow) | server | stored and testable | gateway never sets `byokKeyId`, so runs never use the key | **Dead end** (SE-004) |
| Agent presets (custom deny lists, model pin, temperature) | local | **no** | server `presetById` only knows built-ins, and `presetId` is never sent | **Dead** (SE-007) |
| Context window override | yes | **no** | server compaction uses its own window (`agent-core/src/compaction/policy.ts`) | Only moves the % ring. **Misleading** (SE-012) |
| Max output tokens | yes | yes (clamped to 8192) | yes | Works, but 16K/32K are silently cut to 8K (SE-012) |
| Response wait limit | yes | no (UI watchdog only) | n/a | Display-only "Still working…" label, capped at 600 s. **Misleading** (SE-011) |
| Notifications | yes | **no** (device stays registered) | worker sends FCM `notification` payloads that Android shows without the app | **Toggle does not stop push** (SE-010) |
| Device health | n/a | `GET /health` (db + redis only) | partial | **Screen broken + shallow** (SE-013, SE-014) |
| Device integrity | n/a | native probe | n/a | Works |

---

## P0 — crash / data loss / security

### SE-001 (P0, suspected) "Delete all data" does not sign out of Firebase. The user comes back signed in on the next launch.
- **File:** `lib/core/settings_state_integration.dart:114-125` and `lib/core/firebase_service.dart:622-633`
- **Problem:** The reset's `account` store calls `FirebaseService.I.signOutLocal()`. That only clears in-memory state (`_user = null`, `notifyListeners()`). It never calls `FirebaseAuth.instance.signOut()` or `GoogleSignIn().signOut()`; compare `signOut()` at `firebase_service.dart:605-610`. The Firebase SDK keeps its persisted credential. `FirebaseAuth.instance.userChanges()` (`firebase_service.dart:187`) emits that user again on the next cold start, and possibly on the next token refresh. The account then becomes ready again and `CloudSessionStore.refreshSessions` pulls every cloud chat back. Verification (`onVerifyDeleted: !FirebaseService.I.isSignedIn`) only reads the in-memory flag, so the reset reports success.
- **Evidence:** The confirm copy promises "…and signs you out" (`settings_action_widgets.dart:155-160`). The only `FirebaseAuth.instance.signOut` call in `lib/` is in `signOut()`.
- **Fix:** After `coordinator.commit()` returns, outside the barrier, call `FirebaseAuth.instance.signOut()` and `GoogleSignIn().signOut()`, or add a barrier-safe `signOutSdk()` that skips `transitionSessionAccount`. Verify with `FirebaseAuth.instance.currentUser == null`, not with the in-memory flag.
- **Emulator:** Sign in → Settings → Delete all data → type DELETE → confirm. You land on the login screen. Force-stop the app (`adb shell am force-stop <pkg>`) and relaunch. Expected: login screen. Suspected actual: signed in, with cloud chats back in the sidebar.

### SE-002 (P0, privacy) Reset and sign-out leave the FCM device token registered. The previous account's run notifications keep arriving.
- **File:** `lib/core/cloud/push_service.dart:128-133` (register only), `lib/core/cloud/cloud_rest.dart:497-502`; the server has `DELETE /devices` (`gateway/src/routes/devices.ts`)
- **Problem:** Nothing in `lib/` calls `DELETE /devices`: not the reset, not `signOut()`, not the Notifications toggle. The worker fans out to every device registered for the uid (`worker/src/notify.ts:230-265`) with a visible `notification` payload, which Android shows while the app is in the background. On a shared or handed-over phone, the old account's titles ("Run finished: …") keep showing after "Delete all data" or a sign-out.
- **Fix:** Add `CloudRestClient.unregisterDevice(token)` and call it before the local sign-out in both `signOut()` and the reset coordinator, before the id token is dropped. Also call `FirebaseMessaging.instance.deleteToken()` during the reset.
- **Emulator:** Sign in as A and send a long task. Then do Settings → Delete all data (or sign out). Background the app and let A's run finish. Expected: no notification. Suspected actual: A's notification appears.

### SE-003 (P0/P1) "Delete all data" says it deletes your chats, but chats live in Ovid Cloud and survive. BYOK keys also survive server-side.
- **File:** `lib/ui/settings_screen.dart:175-181` (row: "Chats, keys and settings · irreversible"), `lib/ui/settings_action_widgets.dart:150-165` (dialog), `:224-245` (screen)
- **Problem:** The reset wipes only local stores (`settings_state_integration.dart:36-245`). Server sessions, messages, artifacts, schedules, shares and escrowed BYOK keys (`/byok`) stay. The dialog's small print says cloud data is not deleted, but the row subtitle and the dialog's first line ("chats and their workspaces, … API keys and tokens") say the opposite. The dialog also lists stores that no longer exist on the device: "plugins, MCP servers, … uploaded skills, browser cookies and profiles, the installed sandbox runtime". Combined with SE-001, users believe their chats are gone when they are not.
- **Fix:** Rename the action to "Clear this device". Subtitle: "Signs out and removes local cache. Your cloud chats are kept." Rewrite the dialog to list only real local stores. Add a second, clearly separate path, "Delete my cloud data / account", that links to `account_deletion_panel.dart`. Optionally offer "Also revoke my BYOK keys" (`DELETE /byok/:id` for each key).
- **Emulator:** Create two chats → Delete all data → sign back in with the same account. Expected per the copy: no chats. Actual: both chats reappear from the cloud.

---

## P1 — broken or misleading

### SE-004 (P1) Neither key screen affects runs. Device BYOK providers and escrowed BYOK keys are both unused by cloud execution.
- **Files:** `lib/ui/providers_screen.dart:224-246` (copy: "Keys are stored securely on this device and sent to your provider to authenticate requests"), `lib/ui/settings_screen.dart:207-223, 2294-2642`, `cloud/apps/gateway/src/routes/messages.ts:309-330`, `cloud/apps/worker/src/keyResolver.ts:20-26, 124-150`
- **Problem:**
  1. Device providers (Groq, OpenRouter, custom) and the model picked in chat (`AppState.setModel`) never reach the server. `sendMessage` has no model or provider field, and no `/model` is forwarded. Every run uses the server's model resolution (session `modelPin`, otherwise auto). A user who adds a Groq key and picks a Groq model is silently billed on Ovid Cloud.
  2. Escrowed keys (`POST /byok`) can be stored and tested, but the gateway never puts `byokKeyId` on the run job (the field exists in `packages/queue/src/queues.ts:77,113`). `keyResolver` step 1 is therefore unreachable.
  3. There are two overlapping entries, "Providers" (subtitle "BYOK · free & custom providers") and "Bring your own keys", each with its own key icon, and they disagree about where keys live.
- **Fix:** Short term: hide the "Your providers" section and the second entry. Keep the Ovid Cloud tile and relabel "Bring your own keys" as "Coming soon". Real fix: (a) add `model` and `byokKeyId` to `sendMessageBodySchema` and the run job, with server-side validation against the user's own keys; (b) have the chat model picker list the cloud catalog plus the user's escrowed keys; (c) delete the device-key ProvidersScreen path, so no key-shaped material stays on the device.
- **Emulator:** Settings → Providers → add a custom provider with a deliberately invalid key → select its model in chat → send "hi". If this were wired, the run would fail with an auth error. Expected actual: a normal answer from Ovid Cloud, and usage increments on the Ovid plan.

### SE-005 (P1) The "Memory" and "Share session memory" toggles are dead.
- **Files:** `lib/ui/settings_screen.dart:100-110, 606-611, 974-1006`; the only reads are in `lib/core/state.dart` (`effectiveShareSessionMemory` has no consumer outside state.dart)
- **Problem:** Neither flag is sent. The worker never sets `memoryEnabled` (`agent-core/src/loop.ts:173,575` default true), so `memory_*` tools are always on server-side, and `memoryContext` is always `""` (`loop.ts:853`). The subtitle claims "ON — personal and current-chat memory context & tools" and "OFF — saved memory context & tools disabled". Turning Memory OFF does not stop the agent from saving memories, which is a privacy expectation.
- **Fix:** Add a per-user server preference (e.g. `PATCH /account/preferences {memoryEnabled}`), have the worker read it into `LoopDeps.memoryEnabled`, and populate `memoryContext`. Until then, remove both toggles. Drop "Share session memory" entirely; cross-chat `memory_search` has no cloud equivalent.
- **Emulator:** Turn Memory OFF → new chat → "Remember that my dog is Bruno" → expand the tool rows. Expected: no `memory_save`. Suspected actual: `memory_save` runs.

### SE-006 (P1) "Memory files" and "Permissions" rows promise features; both open placeholder screens full of internal jargon.
- **Files:** `lib/ui/settings_screen.dart:112-118` ("View, edit, save, add or import Markdown memory"), `:153-169` ("Paths and hosts the agent may always access"); `lib/ui/memory_screen.dart:30-63` ("arrive with the P3 memory endpoints"); `lib/ui/permissions_screen.dart:30-63` ("until the P3/P9 grants read endpoint ships", "path or host outside its workspace")
- **Problem:** Both rows advertise features that aren't there. The screens expose roadmap codes (P3/P9) to end users. The Permissions copy still describes device paths. The server-side approval memory (`agent-core/src/approvals.ts` `forgetDenial`) has no read or reset UI.
- **Fix:** Hide both rows until their endpoints exist, or keep one "Memory" row with honest copy ("Ovid remembers facts you ask it to. Viewing and editing memory is coming soon."). Remove every "P3/P9/Task" string from user-facing text (`grep -rn "P[0-9]" lib/ui` for literals).
- **Emulator:** Open Settings → Memory files and Settings → Permissions; screenshot both.

### SE-007 (P1) The "Agent presets" screen (custom presets, denied tools, model pin, temperature) has no effect.
- **Files:** `lib/ui/settings_screen.dart:1697-2286`, `lib/core/commands.dart:224-246`; server `cloud/packages/agent-core/src/presets.ts:173-176`, `cloud/apps/worker/src/runProcessor.ts:1669,1754`
- **Problem:** `s.presetId` is set only locally (`commands.dart:239`) and is never sent. No REST field or server command sets the server's `state.presetId`. Even if one did, `presetById` only resolves `BUILT_IN_PRESETS`, so custom ids return null. The `_gatedTools` deny list (`settings_screen.dart:1907-1922`: `run_code`, `job_start`, `fs_edit`, `ralph`…) uses retired on-device tool names. The preset model picker lists device providers (see SE-004). Users who deny `run_shell` to be safe get no protection, which is a safety expectation.
- **Fix:** Hide custom presets. Wire built-in presets through the session (add `presetId` to `sessionPatchSchema`, validated against `BUILT_IN_PRESETS`). Later, add server-stored custom presets whose tool names come from the server roster (`GET /tools` or similar).
- **Emulator:** Duplicate "Standard" → deny `run_shell` → apply the preset with `/preset <id>` → ask "run `uname -a` in the shell". Expected: refused. Suspected actual: the shell runs.

### SE-008 (P1) Export only includes what this device has cached. Unopened cloud chats export empty or partial, with no warning.
- **Files:** `lib/ui/settings_backup_screen.dart:84-131, 151-185`; `lib/core/cloud/cloud_session_store.dart:13-18, 520-560`
- **Problem:** Export iterates `AppState.I.sessions`. Cloud sessions are reconciled as rows, but their messages come from the 50-message read cache, filled only when a chat is opened. A user with 40 cloud chats gets an archive with mostly empty transcripts, and the screen reports "Export complete." The attachment root is the retired `support/workspaces` sandbox directory (`:104`), so attachments are always marked unavailable.
- **Fix:** Before export, page every session's messages through `GET /sessions/:id/messages` (with progress and a cancel option), or add a server export endpoint (`POST /account/export` returning a signed R2 URL). Fetch attachments through artifact URLs. State plainly in the result how many chats and messages were exported.
- **Emulator:** Create a long chat on device B or the web, open only one chat on the emulator, then Settings → Export data → Export. Unzip with `adb pull` and compare message counts.

### SE-009 (P1) A restored backup becomes local-only chats. They never sync, and continuing one starts the model with no history.
- **Files:** `lib/ui/settings_backup_screen.dart:190-290`, `lib/core/settings_state_integration.dart:419-660`
- **Problem:** Restore publishes `restored-<hex>` sessions straight into local storage. `CloudSessionStore` leaves unmapped local sessions alone until their first send. That send then creates an empty server session, so the old transcript is visible but the model has none of it. Restored chats don't appear on other devices or the web, and "Delete all data" erases them for good. A working `POST /import/sessions` already exists (used by the history import).
- **Fix:** Route restore through `HistoryImportService`-style uploads (`POST /import/sessions` with deterministic `clientMsgId`s), then let `refreshSessions` bring the sessions back as cloud rows. Change the copy from "new, inactive chats in the current account" to "uploaded to your Ovid Cloud account".
- **Emulator:** Export, delete one chat, then Import backup. Open the restored chat and ask "what did I say first?". Expected: the model knows. Suspected actual: the model doesn't, and the chat is missing on the web.

### SE-010 (P1) Turning Notifications OFF doesn't stop cloud push. The "background runs may stop" copy is untrue.
- **Files:** `lib/ui/settings_screen.dart:1095-1105`, `lib/core/background_notifications.dart:440-470`, `cloud/apps/worker/src/notify.ts:258-265`
- **Problem:** The master toggle only gates `BackgroundNotifier.post()`, which handles foreground FCM (`onMessage`) and local posts. The worker sends FCM messages with a `notification` block on channel `ovid_<key>.chime.v1`. Android shows those itself while the app is in the background or killed, regardless of the toggle. The OFF subtitle "no status notification; background runs may stop" describes the old foreground service; cloud runs never stop because of this toggle. There is also no UI for the per-channel settings that `NotificationSettings` supports (`openChannelSettings` has no caller in `lib/ui`).
- **Fix:** On OFF, call `DELETE /devices` (or a server `notificationsEnabled` preference). On ON, re-register. New copy: "Get notified when a cloud run finishes or needs your approval." Either add per-channel rows that call `openChannelSettings` or delete the dead code.
- **Emulator:** Notifications OFF → start a 2-minute task → press Home. Expected: nothing. Suspected actual: a system notification "Run finished".

### SE-011 (P1) "Response wait limit" claims to give up, but it only changes a label, capped at 10 minutes. The preset labels are wrong.
- **Files:** `lib/ui/settings_screen.dart:241-247, 1242-1376`; `lib/core/cloud/cloud_agent_facade.dart:296-307`; `lib/core/state.dart:3700-3706`
- **Problem:**
  - The copy says "how long to wait … before giving up". The facade only flips a "Still working…" surface and clamps it to [30 s, 600 s]. The 30 min and 60 min presets and the slider up to 3600 s behave exactly like 10 min.
  - The subtitle switch labels 120 "Default — balanced", but the real default is 300. The 60 → "Quick answers" case can never appear because 60 isn't a preset, and 600, 1800 and 3600 all read "Heavy multi-tool runs".
  - The slider label shows raw seconds ("1830s").
- **Fix:** Rename to "'Still working' hint after…", offer 30 s / 1 min / 2 min / 5 min / 10 min only, and fix the default label. Alternatively, remove the setting; the server enforces its own idle ceilings.
- **Emulator:** Pick 60 minutes, then send a prompt that triggers a long silent tool call. "Still working…" appears at 10 min.

### SE-012 (P1) "Context & output" copy says the override drives auto-compaction. It only moves the client's % ring. 16K/32K output is silently capped to 8K.
- **Files:** `lib/ui/settings_screen.dart:233-239, 1379-1563`; `lib/ui/chat_screen.dart:431-434`; `lib/core/cloud/cloud_rest.dart:390-397`; `cloud/packages/shared/src/rest.ts:125`
- **Problem:** The context override isn't sent. Server compaction uses `min(0.8×window, 100k)` from its own window. The ring can show 40% while the server compacts, or 95% while it doesn't. The ring also omits the server's 100k absolute cap. The Max output 16K and 32K radios are selectable, but `min(v, 8192)` applies with no hint.
- **Fix:** Remove the context override, or send it and have the worker honour it. Make the ring use the server's threshold (`min(0.8w, 100k)`). Limit output presets to ≤8K, or show "Capped at 8K by Ovid Cloud". Shorten the row subtitle (it's 3 lines).
- **Emulator:** Select 32K output → ask for a 20k-token essay → it stops near 8k tokens. Set the context override to 32K → the ring jumps but compaction doesn't happen earlier.

### SE-013 (P1) The Device health screen has no Scaffold: no app bar, no back arrow, unthemed background, and probably the missing-Material text style.
- **File:** `lib/ui/settings_health_screen.dart:72-102` (`build` returns a bare `ListView`); pushed as a full route at `settings_screen.dart:276-283`
- **Problem:** Commit `83520411` dropped the `Scaffold(appBar: AppBar(title: Text('Device health')))`. MaterialApp's default text style for widgets without a Material ancestor is the red/yellow-underline error style, so the `AetherSectionTitle` outside the cards likely renders underlined. There is no title or back affordance, and content draws under the status bar. Tests wrap the widget in `Scaffold` (`test/settings_health_cloud_test.dart:35`), which hides the bug.
- **Fix:** Wrap the widget in `Scaffold(backgroundColor: Aether.bg, appBar: AppBar(leading: BackButton(), title: Text('Service status')), body: SafeArea(child: ListView(...)))`. Change the test host to push the route the way Settings does.
- **Emulator:** Settings → Advanced → Device health; screenshot (expect a black or transparent background with no app bar).

### SE-014 (P1) Health checks are shallow and the naming is wrong: "Device health" only pings the gateway's DB and Redis.
- **Files:** `lib/ui/settings_health_screen.dart:41-70, 130-189`; `cloud/apps/gateway/src/routes/health.ts:48-62`
- **Problem:** "All systems operational" can show while the worker, the LiteLLM/model route, the WS channel, the user's minted key or App Check are broken, which are the things that actually make runs fail. The row is called "Device health" but checks nothing on the device. The error path shows raw exception text (`'Could not reach Ovid Cloud. $e'`, `:63`). The `Diag` ring buffer, which `diag.dart:21` says "the health screen … can read", isn't shown, and there's no "Copy diagnostics" for support.
- **Fix:** Rename the row to "Service status". Add client-side checks: authenticated `GET /sessions?limit=1` (auth and App Check), WS ticket mint (`POST /auth/ticket`), `connectionFor(app)` from `OvidCloudService`, and the push token registered. Ask the server for a worker heartbeat or queue-depth check in `/health`. Add "Copy diagnostics", which copies the scrubbed `Diag.recent()` plus app and version info. Run errors through `friendlyError`.
- **Emulator:** Stop the worker container on staging (`docker stop <worker>`). The screen still says "All systems operational" while chat sends hang.

### SE-015 (P1, suspected) The history import offers "0 chats", can re-upload cloud chats as duplicates, and can't be reopened after "Skip for now".
- **Files:** `lib/ui/login_gate.dart:645-679`, `lib/core/cloud/history_import.dart:138-145, 324-370`, `lib/ui/history_import_sheet.dart:152-168, 233-240`
- **Problem:**
  - The gate shows the sheet whenever no done or skip marker exists. It never checks `plan.sessions == 0 || plan.messages == 0`, so a fresh install sees "Ready to import · 0 chats · 0 messages" (or "1 chat · 0 messages" for the auto-created empty chat).
  - `_scanSessions` reads every row in the account's session store with no filter for rows that are already server sessions. Cloud sessions reconciled by `CloudSessionStore` (ids = server UUIDs) are persisted in the same store. If a sync lands before the gate runs (reinstall with prefs wiped, or after "Delete all data", which removes the markers), the import uploads cloud chats again as new sessions.
  - "Skip for now" writes a permanent per-account marker, and no Settings entry reopens the import.
- **Fix:** Skip the sheet when `plan.messages == 0`. In `_scanSessions`, exclude sessions with a server mapping (UUIDv7 ids / `CloudSessionStore.serverIdFor`) and sessions with no importable messages. Add Settings → Data controls → "Import chats from this device" whenever local unimported rows exist. Rename "Skip for now" to "Not now", and make it really "for now": keep the marker but surface the Settings entry.
- **Emulator:** Fresh install → sign in → observe the sheet with 0 chats. Then sign in with an account that has cloud chats, clear the `ovid_cloud_import_*` prefs (`adb shell run-as <pkg> rm shared_prefs/...` or reinstall), relaunch, accept the import, and check the web for duplicated chats.

### SE-016 (P1) The cloud has live MCP and plugin APIs, but the Android app has no UI for them, and old copy still advertises them.
- **Files:** `lib/core/distribution.dart:50-51` (`cloudPlugins = false`); `cloud/apps/gateway/src/app.ts:329-332` registers `/mcp/servers`, `/mcp/catalog`, `/mcp/oauth/*` and `/plugins` inside the authenticated scope; `lib/ui/settings_screen.dart:1601` ("AI super-app: chat, agents, plugins & MCP."); `settings_action_widgets.dart:157`
- **Problem:** Commit `c344db0e` removed client-side MCP and plugins. The memory note ("Android MCP client-side") is now stale. No client calls the server routes, so Android users have no MCP at all, while About and the reset dialog still mention it. This is a parity gap against PLAN_MCP_PLUGINS_PARITY.md.
- **Fix:** Add Settings → "Connectors (MCP)", with a catalog list from `GET /mcp/catalog`, add/remove via `/mcp/servers`, and OAuth through `/mcp/oauth/start` in a Custom Tab. Gate it on a server capability flag, not a compile-time constant. Remove "plugins & MCP" from About until it ships.
- **Emulator:** Search Settings for "MCP": nothing found. `curl -H "Authorization: Bearer <idtoken>" https://<gw>/cloud/v1/mcp/catalog` returns data.

### SE-017 (P1) Removing an escrowed BYOK key needs no confirmation (it's irreversible), and the BYOK form gives poor feedback.
- **File:** `lib/ui/settings_screen.dart:2362-2378, 2485-2503, 2560-2580`
- **Problem:**
  - "Remove" calls `DELETE /byok/:id` immediately. The key "is never shown again", so a mis-tap is permanent. That breaks the `aether_confirm.dart` contract ("Every destructive action … confirms").
  - `_busy` is shared between Test and Remove, so the Test button reads "Testing…" during a remove.
  - A successful add gives no confirmation.
  - The dialog accepts any text: no https check, a free-text "Provider id" with hint `anthropic` and no list of valid ids, and the server's `endpoint_rejected` message ("not an allowed endpoint identity") surfaces as jargon.
  - The status pill shows raw `untested` / `ok` strings, and `lastTestAt` / `lastTestOk` are parsed but never shown.
- **Fix:** Confirm Remove with `showAetherConfirmDialog`. Track busy state per action (`{id: 'test'|'remove'}`). Show a "Key saved" snackbar. Use a provider dropdown with endpoint pre-fill, validate `https://` inline, map `endpoint_rejected` to "Use the provider's official HTTPS API URL", and show "Last tested 2 min ago · OK".
- **Emulator:** Settings → Bring your own keys → add a key → tap Remove. It disappears with no dialog.

### SE-018 (P1) Workspace images in agent answers never render.
- **File:** `lib/ui/link_safety.dart:244-252`
- **Problem:** `_workspaceImageFile` always returns null ("the thin client has no local workspace"). When the agent writes `chart.png` in the cloud workspace and replies with `![](chart.png)`, the user sees "Image not shown". The server already exposes `GET /sessions/:id/workspace/file`.
- **Fix:** For relative paths, resolve through the workspace-file route (or `mintArtifactUrl`) and render a capped `Image.network` with auth headers. Keep the tap-to-load rule for third-party hosts only.
- **Emulator:** Prompt "make a matplotlib chart, save as chart.png and show it inline". The answer shows "Image not shown".

---

## P2 — polish

### SE-019 (P2) The Settings tree is badly organised and has duplicate entry points.
- **File:** `lib/ui/settings_screen.dart:57-317`
- **Problem:**
  - The two key screens duplicate each other (SE-004).
  - "Export data" opens a screen titled "Export data" whose eyebrow says "Backup" and which also does Import. Its trailing button says "Backup".
  - "Device health" sits under "Advanced" with a duplicate "Health" button, so `_navTileWithAction` creates two tap targets and TalkBack reads them twice.
  - Permissions, Providers and Bring your own keys all use the same key icon.
  - The file header promises a "Studio" section that doesn't exist (`:41`).
  - There's no direct Sign out / Connections (GitHub) / Language / Schedules entry.
- **Fix:** Use these groups:
  - Account: profile, plan, usage, sign out
  - Chat: theme, show reasoning, memory
  - Models & keys: Ovid Cloud models, BYOK
  - Connections: GitHub, MCP
  - Notifications
  - Data & privacy: export/import, telemetry, storage, clear device, delete account
  - Help & about: service status, diagnostics, legal

  Make rows a single tap target with a chevron, and give each a distinct icon.

### SE-020 (P2) The Usage row subtitle is placeholder copy.
- **File:** `lib/ui/settings_screen.dart:80`. It reads "Per-client spend · OvidAI, OpenCode, [CC], Z Code", but `UsageScreen` shows only the server allowance (`usage_screen.dart:1-6`).
- **Fix:** "Today's allowance and recent spend".

### SE-021 (P2) Stale on-device copy throughout Settings.
- `settings_screen.dart:890`: "Sessions, workspaces, previews"
- `:938`: "Required by the app (sandbox, keys)"
- `:969-973`: "its own sandbox workspace"
- `settings_backup_screen.dart:410-415`: "regular attachments inside approved app workspace roots only"
- `settings_action_widgets.dart:155-162`: plugins, MCP servers, uploaded skills, sandbox runtime, browser cookies
- About `:1601`
- **Fix:** Do a copy pass to remove every sandbox/workspace/plugin/MCP/skills reference that no longer applies.

### SE-022 (P2) The theme label says "Dark (default)", but the real default is "system".
- **File:** `lib/ui/settings_screen.dart:1187` vs `lib/core/state.dart:3383` (`themeMode = 'system'`, "Fresh installs follow the OS").
- **Fix:** Use "Dark" for the dark option and "Auto (default)" for system.

### SE-023 (P2) The custom preset tile renders an empty text line.
- **File:** `settings_screen.dart:1996-2007`. For a custom preset with no model or temperature, the condition `|| isCustom` renders `Text('')`. Superseded if SE-007 hides custom presets.

### SE-024 (P2) Storage screen layout and copy.
- **File:** `settings_screen.dart:898-925`. The Cache row puts its size and a "Clear" TextButton inside the subtitle column, unlike the other rows, which use a trailing size. "Support files … not deletable here" offers no guidance. A clear action fires `_refresh()` without awaiting it, so totals briefly flash.
- **Fix:** Use a trailing `Text(size)` plus an `OutlinedButton('Clear cache')` below the list. Describe documents as "Offline chat cache".

### SE-025 (P2) "Share Ovid" hard-codes a different, unreachable URL.
- **Files:** `lib/core/native_share.dart:18-21` shares `https://dhanuk.page.gd/ovid` (hard-coded, not `LegalLinks.website`). `legal_links.dart:21-24` uses the same host. From the VPS, `curl -L` to `dhanuk.page.gd/ovid` timed out (HTTP 000), while `ovidsi.com/privacy`, `/terms` and `/delete-account` returned 200 text/html.
- **Fix:** Point both at `https://ovidsi.com` and read the share text from `LegalLinks.website`. (Suspected outage; recheck from a phone network.)

### SE-026 (P2) `kAppVersion` is a hand-maintained constant.
- **File:** `lib/core/app_info.dart:6` (`'1.0.0'`, synced by hand with pubspec `1.0.0+1`). About and Health show no build number, so support can't tell builds apart.
- **Fix:** Inject the version via `--dart-define=OVID_VERSION=$(git describe)`, or use `package_info_plus`. Show "1.0.0 (build N, <sha>)".

### SE-027 (P2) Inconsistent destructive dialogs.
- Provider remove (`providers_screen.dart:449-466`) and preset delete (`settings_screen.dart:1830-1850`) use plain `AlertDialog` with a red text button. The reset uses `AetherConfirmDialog`. The provider dialog's title says "Remove" but its button says "Delete".
- **Fix:** Use `showAetherConfirmDialog` everywhere and match the verbs.

### SE-028 (P2) The reset screen and the Permissions/Memory screens are styled inconsistently.
- `SettingsResetScreen` (`settings_action_widgets.dart:221`) and `SettingsBackupScreen` (`settings_backup_screen.dart:297`) have no `backgroundColor: Aether.bg`. `PermissionsScreen` has no explicit `BackButton`, unlike its siblings. In light theme these screens show the Material default surface.
- **Fix:** Use a shared `AetherScaffold`.

### SE-029 (P2) Settings copy isn't localized.
- Almost every string in `settings_screen.dart`, `settings_action_widgets.dart` and the BYOK and preset screens is hard-coded English, while storage, backup and providers partly use `context.l10n`. The result is mixed-language UI once another locale ships.
- **Fix:** Move the strings to ARB.

### SE-030 (P2) Telemetry toggle copy.
- **File:** `settings_screen.dart:491-496`. The ON state reads "Optional telemetry requested".
- **Fix:** "On: share crash reports and anonymous usage to help fix bugs" / "Off".

### SE-031 (P2) The Device integrity tap gives no feedback, and its warning overstates the risk.
- **File:** `settings_screen.dart:576-598`. Tapping re-probes silently. "Stored keys can be read" mostly refers to device BYOK keys that SE-004 recommends removing.
- **Fix:** Show a "Rechecked" snackbar, and adjust the copy to name the sign-in token.

### SE-032 (P2) Remote images always need a tap, with no setting.
- **File:** `link_safety.dart:195-206`. This is correct as a secure default, but power users can't opt in per host.
- **Fix:** Add "Always load images from <host>" to the tap-to-load placeholder, with a list of allowed hosts in Settings → Data & privacy.

### SE-033 (P2) Small screens and large text.
- The "Context & output" and "Response wait limit" rows have two- and three-line subtitles at 11.5 sp (`settings_screen.dart:237, 245`). Very long rows wrap to 4+ lines at 200% text scale.
- `_ByokAddDialog` puts four fields in an AlertDialog, which shrinks badly with the keyboard open on 5" screens (no `scrollable: true`, `SingleChildScrollView` only).
- The theme segmented control's fallback is handled; others aren't.
- **Fix:** Use one-line subtitles, and a full-screen route for the BYOK form.
- **Emulator:** `adb shell settings put system font_scale 2.0` on a 360×640 AVD and walk through each screen.

---

## Notes outside my area (raised here because they affect Settings)
- The chat-screen regenerate path still requires a configured device provider (`chat_screen.dart:5576-5585`), even though the cloud ignores it (see SE-004).
- `planMode` and `presetId` are local-only (`cloud_agent_facade.dart:1269-1277`, `commands.dart:239`). The chat/commands auditor should confirm whether the server ever learns about plan mode.
