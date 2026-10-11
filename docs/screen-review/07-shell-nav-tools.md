# 07 — Shell, navigation and tool screens

**Scope:** `lib/main.dart` (app root, deep links), `lib/ui/shell.dart` (OvidShell, consent dialog),
`lib/ui/sidebar.dart` (SessionsSidebar: list, search, chat actions, delete confirm),
`lib/ui/startup_progress_panel.dart`, `lib/ui/browser_screen.dart` (tabs / WebViews),
`lib/ui/schedule_screen.dart` (+ edit sheet), `lib/ui/trajectory_screen.dart`, `lib/ui/subagent_screen.dart`.
Supporting `lib/core/` code was followed where a finding depends on it.

**Goal:** see `README.md` — production-readiness fix plan for ~10M DAU Android; navigation architecture
(no router, back handling, deep links, state restoration), tablet/foldable layouts, chat list scale,
search, offline indicator, WebView memory, timers.

**Status:** in progress

Known context: the per-token streaming rebuild storm is being fixed on `perf/streaming-rebuilds`;
referenced, not re-derived, here.

---
## 1. App root and navigation architecture — `lib/main.dart`

**What it is / how reached:** `main()` initialises `AppState`, applies the persisted theme and runs
`OvidApp`. `OvidApp` is a `MaterialApp(home: LoginGate(child: OvidShell()))` with a single global
`appNavigatorKey`. It also listens for `https://ovidsi.com/s/<token>` App Links (`app_links`), install
referrer and deferred links, and pushes `SharedConversationScreen` imperatively.

**Navigation architecture (as-is):** there is no router and there are no named routes. Every screen is an
imperative `Navigator.push(MaterialPageRoute(...))` from wherever it is opened (sidebar, chat header,
settings). The only deep link is the share viewer. There is no `restorationScopeId` and no
`RestorationMixin` anywhere in `lib/` (grep is empty), so Android process death (common at 10M DAU on
low-RAM devices) always relaunches on the chat root. Draft composer text, open sheets and the
browser/schedule screens are lost. App `targetSdk = 28` (`android/app/build.gradle*:119`), so the
predictive-back gesture does not apply today. Back handling therefore relies entirely on Flutter defaults,
and only seven sheets/dialogs use `PopScope`, none of them in this group.

**Findings**
- **P1 · functional · `lib/main.dart:72,122,133`**: `_openedTokens` remembers every share token that was
  ever opened in the process and drops any later link with the same token. If a user opens a shared
  link, goes back, then taps the same link again in WhatsApp or Gmail, nothing happens. *Fix:* dedupe only
  in-flight opens (`_pendingTokens`) plus the initial link vs. the first stream event. For example, keep
  `_lastOpened = (token, DateTime)` and ignore repeats within about 2 s, or check whether the top route is
  already `SharedConversationScreen(token)` before pushing.
- **P1 · functional · `lib/main.dart:131-137`**: when `openShareWithNavigator` returns false
  (navigator not ready), `_openShare` re-schedules itself through `addPostFrameCallback`. That only runs if
  some other frame is scheduled, so a cold-start link can sit unopened until the user touches the screen.
  If the navigator never becomes available, it keeps retrying once per frame with no limit. *Fix:* call
  `SchedulerBinding.instance.scheduleFrame()` alongside the retry, cap retries (for example 10), and log
  through `Diag` when the cap is reached.
- **P1 · navigation · `lib/main.dart:187`**: the share route is pushed above `LoginGate`, but any other
  deep-link target (open chat X, open Schedule, a notification for session Y) has no route. The
  notification "select session" channel (`lib/core/agent_notification_service.dart:265-269`) only calls
  `AppState.selectSession(sid)`. If Settings, Browser or a sheet is on top, the chat the user tapped never
  becomes visible, and a `sid` for a deleted chat sets `activeSessionId` to a session that does not exist.
  *Fix:* add a small `AppRouter` (go_router or a hand-rolled `onGenerateRoute`) with routes `/`,
  `/c/:sessionId`, `/s/:token`, `/settings`, `/schedule/:sid`, and `/browser`. Route notification taps and
  App Links through it (`popUntil(isFirst)` then select). Validate `sid` with `sessionById` and fall back
  to a "chat not found" snackbar.
- **P1 · state restoration · `lib/main.dart:182`**: no `restorationScopeId` is set, so the OS restores
  nothing after process death. *Fix:* set `restorationScopeId: 'ovid'` on `MaterialApp` and use
  `restorablePush` for the tool screens. As a minimum, persist the active session id (already done) and the
  composer draft per session.
- **P2 · error handling · `lib/main.dart:93`**: `uriLinkStream` errors are swallowed with an empty
  handler, which leaves no field signal when App Links break. *Fix:* `Diag.swallow('deeplink.stream', e)`.
- **P2 · theming · `lib/main.dart:182-188`**: only `theme:` is passed; dark mode is a global mutable
  `Aether.dark` that rebuilds the whole `MaterialApp`. No `darkTheme` or `themeMode` is set, so system
  dark mode does not animate, and a theme toggle drops the `Hero`/route-transition state. This is covered in
  more depth by group 08 (`theme.dart`). *Fix:* pass both `theme` and `darkTheme` and drive `themeMode`.
- **P2 · lifecycle duplication · `lib/main.dart:148-153` vs `lib/ui/shell.dart:123-171`**: two
  `WidgetsBindingObserver`s split the resume work (`wakeSchedules` here; reconnect and overlay in the shell).
  Ordering between them is undefined, and a resume before login runs the root half only. *Fix:* move all
  lifecycle side effects into one `AppLifecycleCoordinator` in core and unit-test it.

**Missing features:** deep links into a specific chat (`/c/<id>`) and into "new chat with prompt"
(Android share-target text → new chat). ChatGPT and Claude both accept shared text and images. No
`android:autoVerify` coverage for `www.` host variants (only `ovidsi.com`, manifest line 87).

**Test to add:** a widget test that sends the same `/s/<token>` URI twice, with a pop in between, and
expects two pushes. A test where the navigator key is null for N frames and then attaches, expecting the
link to open without a pointer event. A notification `onSelectSession` test with Settings pushed, expecting
the chat route to be visible.

---

## 2. OvidShell and telemetry consent dialog — `lib/ui/shell.dart`

**What it is / how reached:** this is `LoginGate`'s child. On widths of 840 dp or more it renders a
permanent `SessionsSidebar` plus a 1 px divider plus `ChatScreen`. Below 840 dp the sidebar is a 288 dp
`Drawer`. It shows a non-dismissible "history isn't being saved" banner, owns app-lifecycle → MCP, overlay
and persistence wiring, and shows the one-time Firebase telemetry consent `AlertDialog`.

**Findings**
- **P1 · functional · `lib/ui/shell.dart:79,101-105,173-206`**: the consent dialog can stack two or three
  times. `_maybeAskConsent` runs once post-frame (line 81) and again from every `FirebaseService`
  notification (line 79). `FirebaseService` notifies several times during startup:
  `firebase_service.dart:177` (init done), `:227` (`_onUser`), `:271` (account login retry). There is no
  "dialog showing" guard, and `consentAsked` only flips when a button is pressed, so each callback that
  lands before the user answers pushes another dialog. *Fix:* add `bool _consentShowing`; return early if
  it is set, set it before `showDialog`, and clear it in `.whenComplete`. Remove the listener after the
  first successful show.
- **P1 · compliance · `lib/ui/shell.dart:176`**: `showDialog` is barrier-dismissible and back-dismissible
  by default. Dismissing records nothing, so the user is asked again on every launch, and on every Firebase
  notify in the same session. *Fix:* use `barrierDismissible: false` and wrap the dialog in
  `PopScope(canPop: false)`, or treat a dismiss as "No thanks" (`fb.setConsent(false)`).
- **P2 · copy/compliance · `lib/ui/shell.dart:183-186`**: the dialog says "See our privacy policy for
  details" but has no link. *Fix:* add a `TextButton('Privacy policy')` that opens the policy URL in a
  Custom Tab.
- **P2 · perf/battery · `lib/ui/shell.dart:93-98`**: `Timer.periodic(3 s)` polls
  `AppState.lastSessionPersistFailed` for the app's whole life, including while backgrounded. The flag is
  set in `state.dart:2902-2906` and `:4973`. *Fix:* make the flag a `ValueNotifier<bool>` (or notify from
  the write path) and listen to it; drop the timer.
- **P2 · navigation · `lib/ui/shell.dart:107-110`**: `_revealControlChat` ignores its `sessionId` and runs
  `popUntil(isFirst)` on the root navigator. When a Control run finishes, it pops whatever the user has open
  (Settings mid-edit, an MCP OAuth sheet, a share viewer) with no warning. *Fix:* only pop routes that are
  not `PopScope(canPop:false)` (use `maybePop` in a loop) and skip it when the user returned to the app
  manually during the run.
- **P2 · lifecycle · `lib/ui/shell.dart:151-158`**: `inactive` is treated like `paused` and calls
  `setAppForegrounded(false)`. Pulling down the notification shade, a permission dialog or a split-screen
  focus change all fire `inactive`, which flashes the device-control overlay on top of Ovid itself
  (`agent_service.dart:1883-1892` shows it whenever the active session is in `control` mode). *Fix:* handle
  `inactive` with the flush only. Show the overlay on `paused`/`hidden`.
- **P2 · tablet/foldable · `lib/ui/shell.dart:210`**: there is a single breakpoint at 840 dp. A Galaxy Z
  Fold inner display in portrait (~673 dp) and 7–8" tablets in portrait (600–800 dp) get the phone drawer,
  and the chat column runs edge to edge at 700+ dp. There is no `DisplayFeature`/hinge handling, so in
  landscape book posture the chat column straddles the hinge. *Fix:* use three breakpoints. Below 600 dp,
  keep the drawer. From 600 to 840 dp, use a collapsible rail or a 72 dp icon rail that expands to 288 dp.
  At 840 dp and above, use the permanent sidebar. Read `MediaQuery.displayFeaturesOf` and use
  `TwoPane`-style placement (sidebar on one side of the hinge, chat on the other). Cap the transcript at
  about 760 dp (verify `chat_layout.dart`, group 01).
- **P2 · UX · `lib/ui/shell.dart:218-224`**: the wide layout has no way to collapse the sidebar (ChatGPT
  and Claude tablets both allow it). *Fix:* add a `_sidebarOpen` state with a toggle in the chat app bar,
  persisted.

**Missing features:** a global offline banner. Connectivity is shown only as the sidebar chip, so on
phones the user never sees "offline" unless they open the drawer (see §3). There is no app-wide
`SnackBar` for background run completion, and no `ScaffoldMessenger` routing for notifications while on
another route.

**Test to add:** a test where `FirebaseService` notifies three times before the first frame settles,
expecting exactly one `AlertDialog`. A test that barrier-dismisses the dialog and expects `consentAsked`
to be persisted (or the dialog not to be dismissible). A test for the lifecycle `inactive` state that
expects no `showDeviceOverlay`.

---
## 3. SessionsSidebar — list, search, chat actions, rename, delete confirm — `lib/ui/sidebar.dart`

**What it is / how reached:** this is the drawer on phones (hamburger or edge swipe) and the permanent
288 dp column on screens of 840 dp or wider. It contains the gradient header (logo, connection chip,
avatar, name, plan pill), "New session", "Search sessions", a flat session list (tap selects; long-press
or ⋯ opens Share / Rename / Regenerate title; a trash icon and swipe both open the delete confirm), and
footer navigation (Schedule, Trajectory, Settings).

**Findings**
- **P0 · perf/scale · `lib/ui/sidebar.dart:177-233`**: the session list is a `SingleChildScrollView`
  holding a `Column` with **every** root session, so nothing is lazy. That `Column` sits inside
  `AnimatedBuilder(animation: AppState.I)`, which notifies on every streamed token (see the note at
  `main.dart:64-67`). Each token re-runs `rootSessions` (`state.dart:6060`, a fresh
  `where(...).toList()` over all sessions), the lowercase filter over all titles, and rebuilds every
  `_SessionTile`. With 2,000 chats that is 2,000 tile builds per token, and on wide layouts the sidebar is
  always mounted. *Fix:* replace it with
  `CustomScrollView`/`ListView.builder(itemCount, itemExtent ~56, findChildIndexCallback)`, keyed by
  `ValueKey(session.id)`. Drive it from a narrow `ValueListenable<List<SessionSummary>>`
  (id, title, model, updatedAt, hasImage) that core only bumps when list membership, order, titles or busy
  flags change, not on token deltas. Reference `perf/streaming-rebuilds` (commit `394a331`), which only
  fixes the chat bubble and `subagent_screen.dart`; the sidebar is **not** covered there.
- **P0 · perf/scale · `lib/ui/sidebar.dart:567-570,626-628`**: each `_SessionTile` has its own
  `AnimatedBuilder(animation: AgentService.I)`, and its build runs
  `session.messages.any((m) => m.kind == MsgKind.imageGen)`. That is a linear scan of the entire
  transcript of every chat on every `AgentService` notify (per token while streaming, plus the
  `AppState` rebuild above). Cost is O(total messages across all chats) per token. *Fix:* cache
  `hasImage` on `ChatSession` (set when an imageGen message is appended or loaded). Replace the per-tile
  `AgentService` listener with a `Selector`-style `ValueListenableBuilder` on a per-session `busy`
  notifier (`AgentService.busyListenable(sessionId)`), so only the tile whose busy flag flips rebuilds.
- **P1 · data scale · `lib/core/state.dart:4245-4330` (feeds this list)**: all chats, with all messages,
  are stored as one SharedPreferences `StringList` (`_kSessions`) and fully decoded into `sessions`. The
  sidebar therefore needs every transcript in RAM just to show titles. At thousands of chats this is
  slow startup (whole-blob decode), OOM risk on 2–3 GB devices, and SharedPreferences write
  amplification. *Fix (cross-group, data layer):* move to an indexed store (sqflite/drift). Keep a
  `sessions` table (id, title, model, created_at, updated_at, pinned, archived, has_image, parent_id) and
  page messages per session on open. The sidebar reads only the summary table, paged.
- **P1 · UX/ordering · `lib/ui/sidebar.dart:212-215`, `lib/core/state.dart:6314`**: chats are listed
  "flat, in stored order", which is creation order (`sessions.insert(0, s)` on create; nothing moves a
  chat to the top on new activity, and `ChatSession` has `createdAt` only, `state.dart:1323`, with no
  `updatedAt`). Continuing an old conversation leaves it buried, which differs from ChatGPT and Claude
  (most-recent activity first, with Today / Yesterday / Previous 7 days / Older headers). *Fix:* add
  `updatedAt` (touched on send and on reply complete), sort by it, and render sticky date-group headers in
  the sliver list.
- **P1 · functional · `lib/ui/sidebar.dart:582,772-776`**: `AppState.deleteSession` is `async` and can
  throw (`StateError('Settings operation in progress.')`, `state.dart:6410`). It also awaits private-sync
  outbox work (`state.dart:6418-6441`, `production.dart:700-707` serialised behind any export) **before**
  it removes the session. Both call sites fire and forget, so: (a) errors become unhandled zone errors with
  no user message; (b) after a swipe, `Dismissible` has finished dismissing while the session is still in
  `rootSessions`. Debug builds then hit "A dismissed Dismissible widget is still part of the tree" on
  every per-token rebuild; release builds show a zero-height ghost row. If the call returns early
  (account switch, `state.dart:6439`) or throws, the chat stays invisible but undeleted until restart.
  *Fix:* do the optimistic removal first. Add `AppState.hideSessionPending(id)`, which removes the session
  from the summary list synchronously, then await the durable delete in a `try`. On failure, re-insert it
  and show a `SnackBar('Couldn't delete chat — try again')`. Await the result in `_confirmDelete` and
  catch errors there.
- **P1 · UX · `lib/ui/sidebar.dart:748-751,772-776`**: delete is permanent and offers no Undo. *Fix:* use
  soft delete plus a 5 s "Chat deleted · Undo" `SnackBar`, and commit the destructive cleanup
  (`_scheduleSessionDeletion`) only after the snackbar closes. Add an **Archive** action (ChatGPT parity),
  which is safer than delete for most users.
- **P1 · search · `lib/ui/sidebar.dart:110,184-197`**: search matches only `title` and `model` (so
  searching "gpt" lists every chat on that model, which is noise). It never searches message text, even
  though `SessionSearch` exists in core (`lib/core/session_search.dart`, used only by the agent tool at
  `agent_service.dart:16313`). Each keystroke filters the whole list synchronously, with no debounce, on
  the UI isolate. *Fix:* debounce for 200 ms. Search titles first, then message content through an
  index (FTS5 in the store above, or `SessionSearch` on a background isolate). Show snippet rows with the
  match highlighted, and drop `model` from the match.
- **P1 · offline indicator · `lib/ui/sidebar.dart:362-379,915-986`, `lib/core/connection_service.dart:17-22`**:
  connectivity is a probe that runs only at process start and on a manual chip tap. The doc comment says
  "on sidebar open, and on app resume", but the only call site is `sidebar.dart:943`. Opening the drawer
  and resuming the app never re-probe. So (a) "online" is stale for the whole session, and (b) on phones
  the chip is only visible inside the closed drawer. With `compact` set and text scale > 20/14, the chip
  is not rendered at all (line 362 shows it when ≤ 20; line 375 needs `!compact`). *Fix:* subscribe to
  `connectivity_plus` (`onConnectivityChanged`) and re-probe on change and on resume. Surface offline as
  a thin global banner in `OvidShell` (and disable Send with "You're offline"). Always render the chip in
  compact mode (dot only).
- **P2 · a11y · `lib/ui/sidebar.dart:697-712`**: per row, the ⋯ and trash `IconButton`s use
  `VisualDensity.compact`, which gives a 40×40 dp target (< 48 dp), and they sit 0 dp apart next to the
  row's own tap target. The always-visible red trash icon on every row is a mis-tap hazard. ChatGPT and
  Claude hide delete behind the menu. *Fix:* remove the inline trash button (keep swipe plus the ⋯ menu
  "Delete"), and give ⋯ a 48 dp target.
- **P2 · a11y · `lib/ui/sidebar.dart:938-941`**: the connection chip's Semantics label is static
  ("Connection status — tap to re-check"), so the status text depends on the child merge. *Fix:* use
  `label: 'Connection: $label'`, `hint: 'Double tap to re-check'`, and `excludeSemantics: true`.
- **P2 · a11y · `lib/ui/sidebar.dart:576-720`**: swipe-to-delete has no accessible equivalent other than
  the trash button (which the P2 above proposes removing). *Fix:* add
  `Semantics(customSemanticsActions: {CustomSemanticsAction(label:'Delete'): ..., 'Rename': ...})` on the
  row, and add "Delete" to the ⋯ sheet.
- **P2 · UX · `lib/ui/sidebar.dart:837-854`**: "Regenerate title" reports failure whenever the new title
  equals the old one, and does not catch exceptions from `regenerateSessionTitle` (unhandled future).
  *Fix:* return a result enum from core and wrap the call in `try`.
- **P2 · UX · `lib/ui/sidebar.dart:856-909`**: Rename has no `maxLength` (a 10 KB paste becomes the title
  and the persisted key) and does not trim the selection. *Fix:* set `maxLength: 120`, use
  `TextSelection(0, len)` on open, and add a `PopScope`-safe controller (already disposed in
  `whenComplete`).
- **P2 · UX · `lib/ui/sidebar.dart:94-99`**: "New session" always inserts a new empty chat. Tapping it
  repeatedly, or tapping it while the active chat is already empty, piles up "New chat" rows
  (`state.dart:6293-6328` does no dedupe). *Fix:* if the active session has 0 messages, just select it and
  close the drawer.
- **P2 · copy · `lib/ui/sidebar.dart:92,113,162,271,879`**: the sidebar mixes "session" and "chat"
  ("New session", "Search sessions", "Delete chat", "Rename session"), and "Trajectory — event ledger"
  is engineering jargon. *Fix:* use "New chat", "Search chats", "Rename chat", and rename Trajectory to
  "Activity log" (keep the test keys).
- **P2 · state · `lib/ui/sidebar.dart:39`**: the search query lives in `_SessionsSidebarState`. On
  phones the drawer is disposed on close, so the query resets every time it is opened. That may be
  intended, but on wide-to-narrow rotation the wide sidebar's state is lost as well. *Fix:* hoist the
  query into a small controller owned by `OvidShell`.

**Missing features (vs ChatGPT / Claude mobile):** pin chat, archive, date grouping, recency ordering,
full-text search with snippets, multi-select delete, "Projects/folders", Undo on delete, an unread or
"finished while away" badge (only "running" exists), and an empty state with a call to action for
first-time users (currently plain grey text, `sidebar.dart:198-210`).

**Test to add:** a perf test with 3,000 sessions × 50 messages that streams 200 tokens and asserts that
`_SessionTile` builds per token are ≤ 1 (count with a build-counter key) and frame build time is < 8 ms.
A test where swipe-delete runs while `_settingsBusy` is true, expecting a snackbar and the row restored
with no `FlutterError`. A test where private sync is enrolled and the outbox is slow, expecting the row
to disappear immediately. A search test that matches message body text.

---
## 4. StartupProgressPanel — `lib/ui/startup_progress_panel.dart`

**What it is / how reached:** a non-blocking readiness strip pinned under the chat header
(`chat_screen.dart:1417-1435`, height-capped by `panelCap` and scrollable). It has a 3 px progress bar and
a "Finishing setup · X of Y" toggle, which expands to one row per `StartupCoordinator` item with Install,
Retry, Disable and Open Plugins actions. It hides itself once every item is ready, disabled or skipped.

**Findings**
- **P1 · UX · `lib/ui/startup_progress_panel.dart:43-50,174-177`**: `unsupported` (plus `degraded`,
  `needsSetup` and `migrationRequired`) counts as a "problem", so on a device where an item is permanently
  *Unsupported on this device* the strip, with its red dot, appears on **every launch forever**. It cannot
  be dismissed, and the user cannot act on it (no Retry for `unsupported`, `startupItemCanRetry` lines
  25-28). This is permanent chrome above every chat for a whole device class. *Fix:* treat `unsupported`
  as benign-terminal (show it only inside Settings → Health). Add a "Dismiss until next change" action
  that stores the snapshot fingerprint and stays hidden until the set of problem items changes.
- **P2 · copy · `lib/ui/startup_progress_panel.dart:198,224`**: when every item is terminal but some
  failed, the header still reads "Finishing setup · 7 of 8", which suggests progress is still happening.
  *Fix:* when `allTerminal && anyProblem`, show "1 item needs attention" instead.
- **P2 · errors · `lib/ui/startup_progress_panel.dart:466-472`** with
  `lib/core/startup_coordinator.dart:502,559`: `item.reason` is `redactStartupError(error.toString())`,
  which is a raw Dart exception string (for example `PlatformException(...)`, `SocketException: ...`)
  shown to end users. *Fix:* map known error classes to friendly copy in core (`reasonForUser`). Keep the
  raw string behind a "Details" expander or in Health/diagnostics only.
- **P2 · a11y · `lib/ui/startup_progress_panel.dart:200-208,486-491,507-511`**: the toggle row is about
  28 dp tall (6 dp vertical padding with 12.5 sp text), and every action button uses
  `minimumSize: Size(0, 30)` with `VisualDensity.compact`. All of these are under the 48 dp minimum.
  *Fix:* set `minimumSize: Size(48, 48)` and
  `materialTapTargetSize: MaterialTapTargetSize.padded`, and give the toggle `ConstrainedBox(minHeight: 48)`.
- **P2 · code health · `lib/ui/startup_progress_panel.dart:149-176`**: `_wasIncomplete` and `_expanded`
  are mutated inside the `AnimatedBuilder` builder (state change during build). It works today, but it is
  fragile, because a rebuild from any parent re-runs the side effects. *Fix:* listen to the coordinator in
  `initState` and compute collapse transitions in the listener with `setState`.
- **P2 · a11y · `lib/ui/startup_progress_panel.dart:211-221`**: the red warning dot has no semantics, so
  "needs attention" is never announced. *Fix:* append ", needs attention" to the toggle's Semantics label
  when `anyProblem` is true.

**Missing features:** a link from the panel to Settings → Health for full diagnostics, and an Undo for
"Disable" (it is immediate and has no confirmation).

**Test to add:** a test where a coordinator has one `unsupported` item and the rest are `ready`, expecting
the panel to render `SizedBox.shrink` (after the fix). A tap-target test asserting each action is at least
48×48. A test that a failed item shows friendly copy, not `Exception:`.

---
## 5. BrowserScreen — tabs, omnibar, WebViews — `lib/ui/browser_screen.dart`

**What it is / how reached:** the chat header browser icon (`chat_screen.dart:1326`) and in-chat link taps
(`chat_screen.dart:8675`, `BrowserScreen.open(url:)`). It is a full-screen route with an AppBar
(agent dot, desktop/mobile toggle, open externally, new tab), a horizontal tab strip (when there is more
than one tab), an omnibar with Back/Forward/Reload, a held-popup bar, a progress bar, and an
`IndexedStack` of `WebViewWidget`s. Tabs and controllers belong to `AgentService` per session
(`agent_service.dart:2859-2885`), so pages survive closing the screen and the agent drives the same tabs.

**Findings**
- **P1 · WebView memory · `lib/ui/browser_screen.dart:558-577`, `lib/core/agent_service.dart:2859,3164-3168,4214-4231`**:
  1. The `IndexedStack` builds a live `WebViewWidget` (an Android platform view) for **every** tab of
     the session at once.
  2. `controllerForTab` creates a native WebView per tab (`tab.controller ??=`) that is kept in
     `_sessionBrowsers` for **every session** whose browser was ever opened or driven by the agent. It
     is released only when the chat is deleted (`agent_service.dart:905`).
  3. Neither `newBrowserTab` nor agent tab creation has a cap.

  Each Android WebView costs tens of MB plus a platform-view surface, so a heavy user with 10 chats ×
  3 tabs holds 30 native WebViews and gets OOM-killed on 3–4 GB devices. This also kills any running
  agent. *Fix:*
  - Render only the active tab's `WebViewWidget`. Show a thumbnail or placeholder for the others, and
    keep their controllers only while within an LRU window.
  - Add an `LruWebViewPool(maxLive: 3)` in core. Evicting a tab persists URL and title, nulls
    `tab.controller` and calls `loadRequest('about:blank')` first; the tab is recreated lazily on
    select.
  - Cap tabs per session at about 10, with an "Close oldest tab?" prompt.
  - Respond to `didHaveMemoryPressure` by evicting every non-active controller.
- **P1 · perf · `lib/ui/browser_screen.dart:86,111-120,263-267`**: the screen listens to the whole
  `AgentService` (which notifies per streamed token, see `perf/streaming-rebuilds`). Each notification
  runs `setState`, which rebuilds the AppBar, tab strip and omnibar, plus
  `_refreshHistoryAvailability()`, which makes **two platform-channel calls** (`canGoBack` and
  `canGoForward`). Every build also schedules another post-frame refresh (lines 263-267), adding two more
  calls. While any chat streams, the open browser makes about 4 method-channel round trips per token.
  *Fix:* listen to a narrow `BrowserTabsListenable` (tab list, active index, url, title, loading,
  progress, popups) that core notifies only on browser events. Refresh history from the WebView's
  `onUrlChange` and `onPageFinished`, not from `build`.
- **P1 · back handling · `lib/ui/browser_screen.dart:268-271`**: there is no `PopScope`, so Android
  system back (and the AppBar `BackButton`) closes the whole browser instead of going back one page. Every
  mobile browser and Chrome Custom Tabs go back in history first. *Fix:* wrap the Scaffold in
  `PopScope(canPop: !_canGoBack, onPopInvokedWithResult: (didPop, _) { if (!didPop) controller.goBack(); })`.
  Keep the AppBar ✕/back closing the screen, and use an X icon to make that clear.
- **P1 · security/UI · `lib/ui/browser_screen.dart:169-173,464-476`**: when not editing, the omnibar shows
  the **page `<title>`** in place of the URL, next to a green lock that appears whenever the URL starts
  with `https` (line 466). A page at `https://evil.example` titled "Sign in – Google Accounts" therefore
  shows "Sign in – Google Accounts" with a green lock, which is a phishing aid. The agent also navigates
  autonomously, so users rely on this bar to know where they are. *Fix:* always show the registrable
  domain (host with the eTLD+1 emphasised) in the omnibar. Put the title in the tab chip only. Show the
  lock as neutral grey, not "success" green, and add a "Not secure" label for `http`.
- **P2 · functional · `lib/ui/browser_screen.dart:65-66,407-430`**: `_canGoBack` and `_canGoForward` are
  computed but never used. Back and Forward are enabled whenever a controller exists, so they look
  tappable on a fresh tab and silently do nothing. *Fix:* use
  `onPressed: _canGoBack ? ... : null` (the same for forward).
- **P2 · functional · `lib/ui/browser_screen.dart:17-28`**: `normalizeBrowserUrl` treats bare IPs
  (`192.168.1.1`, `10.0.2.2:8080`) as search queries (the regex needs an alphabetic TLD), and upgrades
  `localhost:3000` to `https://`, which breaks local dev servers that Studio users run on plain HTTP.
  *Fix:* accept IPv4 and `[IPv6]` hosts with an optional port. Use `http://` for `localhost`, `127.*`,
  `10.*`, `192.168.*` and `*.local`. Add the cases to `normalizeBrowserUrl` tests.
- **P2 · UX · `lib/ui/browser_screen.dart:290`**: the "Agent is driving this tab" dot uses
  `agent.browserBusy || agent.busy`. `busy` is true for *any* active-session run, so a plain chat reply
  marks the browser as agent-controlled. *Fix:* use `browserBusy` (or a per-tab `agentDriving` flag)
  only.
- **P2 · UX · `lib/ui/browser_screen.dart:850-856`**: when the popup URL has no host (for example
  `about:blank`, or a relative path), `Uri.host` is `''` and the bar shows "Popup held: " with nothing
  after it. *Fix:* fall back to `last` when the host is empty, truncated to 60 chars.
- **P2 · code health · `lib/ui/browser_screen.dart:735-830`**: `externalSignInProvider` and its host
  tables are dead in production. They are referenced only by `test/control_gestures_overlay_test.dart`,
  and the comment says navigation "never displays a proactive sign-in notice". *Fix:* either wire them up
  to offer "Continue in Chrome" on Google, Microsoft or Apple sign-in pages (useful, since Google blocks
  embedded OAuth), or move them to core or delete them.
- **P2 · a11y · `lib/ui/browser_screen.dart:314-321`**: tab chips are `Semantics(selected, button)` with no
  label beyond the truncated title and no position. *Fix:* use the label
  `'Tab ${i+1} of $n: ${_tabLabel(t)}'`.
- **P2 · tablet · `lib/ui/browser_screen.dart:224-225`**: actions stack into a second AppBar row only
  for narrow widths. Tablets get one long row, but tab overflow has no "all tabs" overview. *Fix:* add a
  tab-count button that opens a grid switcher (Chrome-style) once there are more than 4 tabs.

**Missing features:** find in page, share page, a tab switcher grid, a reader view, history, bookmarks
(probably out of scope), a per-site "clear cookies" option (exists per session in core but has no UI
here), and a "Stop agent" control inside the browser while the agent is driving it.

**Test to add:** a widget test that opens the browser with 5 tabs and asserts only one `WebViewWidget` is
in the tree (after the fix). A test with a fake controller where `canGoBack=true`, expecting system back
to call `goBack` and keep the route. A test where the title is "Google" and the host is `evil.example`,
expecting the omnibar text to contain `evil.example`. A perf test that sends 100 `AgentService`
notifications with no browser change, expecting `canGoBack` to be called 0 times.

---
