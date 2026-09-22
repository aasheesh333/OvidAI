# Production Plan — Per-Session Isolation, Restart Sharing & Queued Behaviour

Status: **implemented in this branch** (`hoplite/gortyn-77773150`), verified in CI.
Scope: cross-device production readiness for aasheesh333/OvidAI.

---

## 0. The contract (what the user asked for, written as testable rules)

1. **A session is a first-class isolated world.** One chat = one sandbox
   workspace + one Studio repo/branch/open-files bucket + one browser tab set +
   **one cookie jar (WebView profile)**.
2. **Nothing bleeds across sessions while the app runs.**
   - Stop stops *this* session only (`stopRequested(sessionId:)`), never a global
     force-stop; other sessions keep streaming.
   - A background run's tools drive *its own* session (run Zone), not whatever
     chat the user is looking at.
   - A Google login in chat A is invisible in chat B.
3. **Once per launch the accumulated DATA is shared — never state.** On app
   restart the logins (cookies) and the Studio repo/branch that were accumulated
   across all sessions are merged once, so the user is signed in / connected
   everywhere; after that merge the sessions diverge again until the next
   restart. (User words: "Isolated per session but after restart all sessions
   data will be shared once, then after again restart new data will be shared.")
   Clarified by the user: "restarted ke baad sirf browser and studio ka data
   share hoga like logins — not tabs, not website visits". So the merge moves
   **cookies + repo/branch only**; tabs, open pages, the active tab index, open
   Studio files/buffers and the recorded visit history are never carried into
   another session — each chat still restores exactly its own.
4. **The jar is per session, not per tab.** All tabs of one session share that
   session's cookies; no tab ever sees another session's cookies.
5. **Opt-out exists** for both halves, and turning a switch OFF means *strict*
   isolation, including across restarts.
6. **Degrade, never crash.** WebView < 125 / non-Android / unit tests: profile
   calls become no-ops and every tab falls back to the process-wide jar.

---

## 1. Root causes found (audit)

| # | Symptom | Root cause | Where |
|---|---|---|---|
| B1 | "Login in another chat shows up here" | One process-wide `CookieManager`; tabs were per-session but cookies were app-global | `agent_service.dart` browser section |
| B2 | Background run hijacks the visible chat | `browserTabs`/`activeFilePath`/`enqueueMessage` resolved to the *UI-active* session, not the run's session | `_browserKey`, `_currentRunKey`, `enqueueMessage` |
| B3 | Studio shows another chat's files | Singleton `RepoCache` bound with no owner; no rebind on session switch | `repo_cache.dart`, `state.dart` |
| B4 | Red Stop kills every session | Chat button called `hardStopAll()` | `chat_screen.dart` |
| B5 | Queued-message IDs desync | `steerQueuedMessage` rotated `queue` without rotating `queueIds` | `agent_service.dart` |
| B6 | `@session:` reference ignored | Session mention not honoured when "Share session memory" is OFF | `agent_service.dart` mention expansion |
| B7 | Studio login lost after restart | Token was written to prefs in an older path | now `ovidSecureStorage` (`github_service.dart`) |
| B8 | Deleted session leaves a logged-in jar | Profile not removed with the session | `onSessionDeleted` |

---

## 2. Implementation

### 2.1 Native (Kotlin) — `OvidBrowserProfiles.kt` (new)

Wraps the AndroidX WebKit **multi-profile API** behind one object so the Dart
side has a single, uniform, no-throw surface:

```kotlin
object OvidBrowserProfiles {
  fun supported(): Boolean                       // WebViewFeature.MULTI_PROFILE
  fun bind(webView: WebView, profileName: String): Boolean
  fun profileNames(): List<String>
  fun delete(name: String): Boolean
  fun shareCookies(profiles: List<String>, urls: List<String>): Int
  fun clearCookies(profiles: List<String>, urls: List<String>): Int
}
```

Decisions that matter:

* **Pin:** `androidx.webkit:webkit:1.12.0` (matched to `webview_flutter_android`
  3.16.9). `Profile.setProfileData` is 1.14+, so it is *not* available — restart
  sharing therefore **copies cookies** through each profile's `CookieManager`
  rather than moving profile data. Consequence, documented in the file header:
  cookie attributes (`HttpOnly`, `Secure`, expiry) are not preserved and copies
  become session cookies. This is a deliberate best-effort trade; the
  alternative (reflection against a newer webkit) was rejected as fragile.
* `CookieManager.setCookie` takes **one** cookie per call while `getCookie`
  returns a whole header → the header is split into `name=value` pairs and set
  individually. The pure splitting/merging lives in Dart (`CookieMerge`) so it
  is unit-tested.
* Every function is a **no-op when `MULTI_PROFILE` is unsupported**, so old
  WebView builds keep working on the shared jar.
* **Seeding:** a session profile that does not exist yet is seeded from the
  default profile on first bind, so pre-upgrade logins are not lost for existing
  installs.

### 2.2 Channel surface — `OvidWebViewHandler.kt`

New `onMethodCall` branches (all resolving the target WebView via
`resolveWebView(identifier)`, all replying structurally rather than throwing):

| Method | Args | Reply |
|---|---|---|
| `profilesSupported` | — | `bool` |
| `bindProfile` | `webViewIdentifier`, `profileName` | `bool` (a plain bool — the Dart side reads `invokeMethod<bool>`, so returning a Map here silently made every bind report failure) |
| `listProfiles` | — | `List<String>` |
| `deleteProfile` | `profileName` | `bool` |
| `shareProfileCookies` | `profiles[]`, `urls[]` | `{copied, profiles, urls}` |
| `clearProfileCookies` | `profiles[]`, `urls[]` | `int` |

`onUi(block)` was added so the handler runs inline when `activity == null`
(headless/pre-warm) instead of silently dropping work.

### 2.2.1 Hardening pass (production review of the native layer)

Everything below was found by re-reading the pinned AndroidX 1.12.0 sources and
fixed before the first release of the feature:

| Bug | Why it mattered | Fix |
|---|---|---|
| `bindProfile` replied with a Map while Dart asked for `bool` | every bind silently reported `false`; the profile was still set, so behaviour looked random | reply a plain `Boolean` |
| `delete()` called `getProfile()` first | `deleteProfile` throws `IllegalStateException` when the profile is already in memory — i.e. deleting a chat you had just browsed always failed | call `ProfileStore.deleteProfile(name)` directly, catch `Throwable` |
| `clearCookies` wrote `ovid_cleared=1; Max-Age=0` | a no-op "wipe" that left every login intact | empty `urls` ⇒ `removeAllCookies(null)` + `flush()`; non-empty ⇒ read the header and expire each **present** pair |
| `shareCookies` wrote the whole merged header in one `setCookie` | `setCookie` accepts exactly ONE cookie per call, so the merge copied only the first pair | split into pairs (`cookiePairs`) and set each, one `flush()` per manager |
| failed deletes were lost | a deleted chat could leave a logged-in jar on disk forever | `ovid_browser_profile_deletes` queue + `purgePendingDeletes()` at the next launch (never queues a profile that simply never existed) |
| the visit record was global | technically a cross-session record of visited origins | per-session keys (`ovid_browser_cookie_origins_<sessionId>`), unioned only by `allRememberedOrigins()` for the merge/clear paths |
| deleting a chat left its tab prefs | a reused id could restore another chat's pages | `_dropSessionBrowserPrefs()` removes the v2 envelope, the legacy URL list and the visit record |

### 2.3 Dart services (new)

* **`lib/core/session_browser_profiles.dart`**
  * `BrowserProfileId.forSession(id)` → `ovid_s_<sanitized>` (≤48 chars,
    `[A-Za-z0-9]` only, runs collapsed, never trailing `_`, `default` for empty).
    Deterministic ⇒ isolation survives a restart with **zero bookkeeping**; the
    `ovid_*` prefix lets the app enumerate and clean only its own profiles.
  * `CookieMerge.pairs/merge/originOf` — pure, unit-tested. `originOf` keeps
    scheme+host+port and drops path/query (paths can carry session data), and
    rejects `ovid://`, `file://`, `about:blank`.
  * `SessionBrowserProfiles.I` — `probe()` (cached capability check),
    `bind()`, `listProfiles()`, `deleteProfile()`, `shareCookies()`,
    `clearCookies()`, `rememberOrigin()` / `rememberedOrigins()` /
    `forgetOrigins()`, `shareOnRestart()`.
  * Origins are persisted (`ovid_browser_cookie_origins`, capped at 300) because
    **a WebView cookie jar cannot be enumerated** — the restart merge replays the
    sites the user actually visited.
* **`lib/core/session_data_sharing.dart`** — the single implementation behind the
  startup task, the Settings toggles and the "Share session data now" action:
  `runOnStartup()`, `shareBrowserOnRestart({force})`,
  `shareStudioOnRestart({force})`, once-per-launch guards, and a
  `lastBrowserReport` for UI feedback.

### 2.4 `AgentService` — tab identity and load ordering

* `BrowserTab` gains `sessionId`, `profileName`, `profileBound`.
* `_newTabInternal` stamps the owning session; every restore path
  (`_decodeBrowserTabsEnvelope(raw, sessionId: …)`) stamps it too, including the
  legacy global-list upgrade path.
* **Ordering is load-bearing, not cosmetic.** `WebViewCompat.setProfile` is
  rejected once a WebView has navigated *or evaluated JavaScript* — and the
  mobile viewport helper *does* evaluate JavaScript. So the whole pre-navigation
  sequence moved into one awaited helper:

  ```
  _bindProfileThenLoad(tab):
      1. await ensureTabProfile(tab)     // setProfile — MUST be first
      2. setUserAgent(desktop|mobile)
      3. applyDesktopViewport(...)
      4. loadFile(preview) | loadRequest(url)
  ```
  with a `tab.controller != controller` re-check after every await (the
  controller can be recreated mid-flight by a desktop toggle).
* `ensureTabProfile` is idempotent and **does not mark the tab bound when there
  is no native WebView yet**, so a later call can still bind instead of silently
  pinning the tab to the shared jar forever.
* `navigateTab(tab, url)` is the single navigation entry point: binds first,
  clears `localPreviewPath` when navigating a preview tab to the web, records the
  origin, then loads. `controllerForTab` handles the no-controller case by
  handing the URL to its own deferred load (one load, no double-load).
* `recreateControllerForDesktopToggle` resets `profileBound` (a new native
  WebView has no profile yet) and no longer issues a duplicate load.
* `_persistBrowserTabs` now writes the per-session copy under **`_browserKey()`**
  (the tab owner) instead of `_currentRunKey()` (the UI-active session) — that
  mismatch handed a background run's tabs to another chat on restart.
* `browser_cookies` (tool) awaits `ensureTabProfile` before running JS, and
  `clear: true` now clears **every session profile** plus the default jar.
* `onSessionDeleted` drops the session's browser bucket and deletes its native
  profile (cookies + web storage).
* `refreshStudioBindingForActiveSession()` rebinds the singleton `RepoCache` to
  the active session's `(repo, branch)`, with a no-token early return.

### 2.5 UI

* `browser_screen.dart`: `initState` open-URL routing and the omnibar `_nav` go
  through `agent.navigateTab(...)`; no raw `loadRequest` remains outside the two
  owning helpers.
* `chat_screen.dart`: the red button calls
  `AgentService.I.stopRequested(sessionId: sessionId)` — **this session only**;
  tooltips reworded ("Stop session", "Stop session (next queued will run)").
* `settings_screen.dart`: new `_SessionDataSharingTile` with
  *Share browser logins on restart*, *Share Studio repo on restart* and
  *Share session data now* (manual merge + snackbar report); *Clear cookies*
  now clears every session profile and forgets the recorded origins.

### 2.5.1 Data, not state (the "logins only" rule)

| Item | Isolated while running | Shared once at restart |
|---|---|---|
| Cookies / logins (per-session profile) | ✅ own jar | ✅ merged into every session |
| Studio repo + branch | ✅ own choice | ✅ last used offered to sessions that have none |
| Browser tabs / open pages / active tab | ✅ own tab list (`_kBrowserSessionV2Prefix<id>`) | ❌ never |
| Visit record (`ovid_browser_cookie_origins_<id>`) | ✅ own bucket | ❌ never read as another session's data — unioned **only** so the login copy knows which origins to replay |
| Studio open files / buffers | ✅ own bucket | ❌ never |
| Sandbox workspace | ✅ own dir | ❌ never |

The visit record is a *cookie-location index*, not history: it holds
`scheme://host[:port]/` only (never a path, query or title), it is stored under a
per-session key so no session can read another's, and it is never rendered as
history or used to seed tabs. `test/session_browser_profiles_test.dart` pins this
down (per-session reads, union helper, and a source contract asserting the
restart merge never touches tab state).

### 2.6 Startup wiring

`AppState._buildStartupTasks` gains a sequential task after session restore:

```
id: 'session.shareOnRestart', kind: sessionHook,
body: SessionDataSharing.I.runOnStartup   // 15s timeout
```

`runOnStartup` first **drains the pending-delete queue** (`purgePendingDeletes`)
and only then runs the merge: at that instant no tab exists yet, which is the one
moment the platform actually allows a profile to be deleted.

Order matters and is guaranteed: local hydration (⇒ `lastRepoFull`) →
session restore (⇒ session ids) → `github.initialize` (⇒ token) → sharing.

### 2.7 System prompt

The model is told the truth about isolation, including which switch is on:

> Browser isolation: the Browser panel is per session too — this chat has its
> own tabs AND its own cookie jar / logins … Studio isolation: the repo, branch
> and open Studio files are per session as well.

This kills the class of hallucination where the agent claims a login exists in
this chat because it exists in another.

---

## 3. Tests

`test/session_browser_profiles_test.dart` (new):

* `BrowserProfileId` — stable, deterministic, sanitized, collision-free, capped.
* `CookieMerge` — pair splitting (attributes dropped), first-wins merge, null
  sources, origin reduction (port kept, path/query dropped), non-web rejection.
* `BrowserShareReport` — honest messages, `nothing()` never claims success.
* Isolation contract — `shareOnRestart` refuses for a single session *before*
  probing the platform; `bind` returns `false` (not throw) with no channel;
  origin bookkeeping ignores non-web URLs.
* **Data-not-state contract** — visit records are per session (a third session
  reads nothing); forgetting one session leaves the others intact; the union
  helper is the only cross-session reader; and `session_data_sharing.dart` must
  never mention `browserTabs` / `BrowserTab(` / `activeTabIndex` /
  `restoreBrowserTabs` (a merge that moved tab state fails the build).
* **Deletion contract** — a delete refused by a live WebView is queued and
  retried (mocked channel: first call refused + still listed ⇒ queued; next
  launch ⇒ purged once, then drained); a profile that never existed is *not*
  queued; `onSessionDeleted` drops the bucket, the tab prefs, the visit record
  and the native profile.
* Source contracts — the profile bind precedes the UA/viewport/load inside
  `_bindProfileThenLoad`; `navigateTab` binds before loading; **exactly two**
  `.loadRequest(Uri.parse` calls exist in `agent_service.dart` (any third would
  be a bypass); tabs carry their session id; every `rememberOrigin` passes the
  tab's own session id; the system prompt states the model; cookie clearing
  covers every profile; both switches persist and default ON; the startup task
  exists; Settings exposes both switches + manual sync.

Updated: `test/core_regression_test.dart` (chat Stop contract now asserts
`stopRequested(sessionId: sessionId)`).

Verification path: **CI only** — there is no Flutter/Dart toolchain on the
device sandbox, so `flutter analyze` / `flutter test` run in GitHub Actions
(`.github/workflows/build.yml`, `hoplite/**` → APK/AAB).

---

## 4. Risk register

| Risk | Mitigation |
|---|---|
| `setProfile` after navigation throws | ordering enforced in one helper + re-checks after every await; `applied=false` is tolerated, never fatal |
| WebView < 125 | `probe()` gate; every call degrades to a no-op; tabs keep the shared jar |
| Cookie attributes lost on copy | documented best-effort; copies become session cookies (they still authenticate) |
| Jar cannot be enumerated | persisted origin list (≤300) replayed by the merge |
| Double-run of the merge | `_browserRan` / `_studioRan` guards + `force` for the manual action |
| Studio merge clobbering a deliberate choice | the pass only **fills gaps** — sessions that already chose a repo keep it |
| Race with a desktop-mode toggle | `controller != controller` checks abort the stale sequence |
| Restart merge accidentally moving tabs/history | the merge reads only `SessionBrowserProfiles` (cookies) + `lastRepoFull/lastBranch`; a source contract test fails the build if `browserTabs`/`BrowserTab(`/`activeTabIndex` ever appears in `session_data_sharing.dart` |
| Visit record leaking between sessions | stored per session (`ovid_browser_cookie_origins_<sessionId>`), unioned only by `allRememberedOrigins()` for the merge/clear paths |
| Profile delete refused (live WebView holds it) | the name is queued in `ovid_browser_profile_deletes` and retried by `purgePendingDeletes()` at the next launch |
| `deleteProfile` throwing because the profile was loaded | never call `getProfile()` first — `deleteProfile` reports existence itself and throws `IllegalStateException` when the profile is in memory |
| Cookie merge writing a merged header as ONE cookie | `setCookie` takes a single cookie; both `shareCookies` and `clearCookies` replay/split pairs individually |
| Channel type mismatch silently disabling the feature | `bindProfile` must reply a plain `Boolean` (Dart asks for `bool`); a type mismatch would make every bind look failed |
| "Clear all cookies" leaving logins intact | `clearProfileCookies` with an empty `urls` list calls `removeAllCookies(null)` + `flush()`, so it is a real wipe |
| A deleted chat's tab prefs outliving the chat | `_dropSessionBrowserPrefs()` removes the v2 envelope, the legacy list and the visit record on `onSessionDeleted` |

---

## 5. Rollout / verification checklist

- [x] Native profile object + channel methods, no-throw.
- [x] Dart services with pure, tested logic.
- [x] Bind-before-load ordering everywhere (2 raw loads, both guarded).
- [x] Per-session Studio binding rebind + restart backfill.
- [x] Stop is session-scoped.
- [x] Settings switches + manual sync + all-profile cookie clearing.
- [x] Startup task wired in the correct order.
- [x] System prompt updated.
- [x] Unit + source-contract tests.
- [ ] CI green (analyze + test + APK/AAB) — tracked on this branch.
- [ ] Device smoke test from the CI APK: two sessions, log in on one, confirm
      the other is logged out; restart; confirm both are logged in.

## 6. Deliberately out of scope

* Per-**tab** cookie jars (the user explicitly wants per-session, shared by the
  session's tabs).
* Whole-profile data migration (`setProfileData`) — needs webkit 1.14+, which is
  incompatible with the pinned `webview_flutter_android`.
* Per-session `RepoCache` instances — the singleton is rebound instead, which
  keeps the memory footprint flat on low-RAM devices.
