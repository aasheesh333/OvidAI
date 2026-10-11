# 07 — Shell, navigation and tool screens

**Scope:** `lib/main.dart` (app root, deep links), `lib/ui/shell.dart` (OvidShell, consent dialog),
`lib/ui/sidebar.dart` (SessionsSidebar: list, search, chat actions, delete confirm),
`lib/ui/startup_progress_panel.dart`, `lib/ui/browser_screen.dart` (tabs / WebViews),
`lib/ui/schedule_screen.dart` (+ edit sheet), `lib/ui/trajectory_screen.dart`, `lib/ui/subagent_screen.dart`.
Supporting `lib/core/` code was followed where a finding depends on it.

**Goal:** see `README.md` — production-readiness fix plan for ~10M DAU Android; navigation architecture
(no router, back handling, deep links, state restoration), tablet/foldable layouts, chat list scale,
search, offline indicator, WebView memory, timers.

**Status:** complete (sections 1–8 + group summary)

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
## 6. ScheduleScreen and Edit schedule sheet — `lib/ui/schedule_screen.dart`

**What it is / how reached:** reached only from the sidebar footer "Schedule" row
(`lib/ui/sidebar.dart:250-262`), which is disabled when there is no active session. It is a per-session
list: a background-execution status card (headline, constraint notes, Stop/Resume button), then one
`_TaskCard` per entry in `session.schedules` (status pill, prompt, recurrence, next run, an overflow menu
with Edit / Pause / Resume / Cancel, and expandable details with raw spec). Edit opens
`_EditScheduleSheet` (prompt, One-off / Daily / Interval chips, free-text time field, preview, retries
stepper 0–3). Tasks can only be *created* by asking the agent. Mutations go to
`AgentService.editSchedule` (`agent_service.dart:20873`) and `ScheduleCoordinator.cancelTask/resumeTask`
(`schedule_coordinator.dart:360-379`).

**Findings**
- **P1 · functional/destructive · `lib/ui/schedule_screen.dart:149-158`, `lib/core/agent_notification_service.dart:100-110`**:
  "Stop background execution" calls `AgentNotificationService.stopBackground`, which also calls
  `AgentService.I.cancelAllRuns()`, the global panic stop. One tap on a per-chat Schedule screen therefore
  cancels **every in-flight chat reply in every session** (plus device-control actions and voice input) and
  pauses **every scheduled task in every session**, with no confirmation. The label suggests it only
  affects background scheduling. *Fix:* show a confirm dialog that states the scope ("This pauses all
  scheduled tasks in all chats and stops any running agent replies"). Better, split the actions: a
  schedules-only stop (`AgentService.stopScheduledBackground`) here, and keep the panic stop in the
  notification and global Stop.
- **P1 · functional · `lib/core/schedule_coordinator.dart:346-357`, `lib/core/agent_service.dart:20867-20871`, `lib/ui/schedule_screen.dart:115-118`**:
  Stop sets every pending or running task to `paused` with error "Background execution stopped by user".
  Resume only clears the `stopped` flag; it never returns those tasks to `pending`. After Stop → Resume the
  strip says "Background execution active" with a pulsing green dot while **nothing will ever run** until
  the user finds each task, in each chat, and taps Resume. Daily reminders silently stop. *Fix:* on resume,
  re-pend tasks whose `error == 'Background execution stopped by user'` (recomputing `fireAt` for
  recurring ones so they do not all fire at once), or show a "Resume N paused tasks" prompt after Resume.
- **P1 · copy/errors · `lib/ui/schedule_screen.dart:41,266,559`**: errors are shown as raw `'$e'`, so the
  user sees "Bad state: Resume background execution first", "Bad state: Pause the task before editing",
  "FormatException: Use YYYY-MM-DD HH:mm or ISO-8601 with offset", or platform exceptions. *Fix:* map the
  known `StateError` / `FormatException` cases to friendly copy plus an inline action (for example a
  "Resume background" button on the first one), log the raw error through `Diag`, and show a generic
  "Couldn't update the schedule. Try again." otherwise.
- **P1 · destructive UX · `lib/ui/schedule_screen.dart:524-528,542-543`**: Cancel is irreversible (Resume is
  not offered for `cancelled`) and runs immediately from the overflow menu with no confirm and no undo. If
  the task is running, it also kills the run (`cancelTask` → `cancel(sessionId)`). *Fix:* show a confirm
  dialog, or a SnackBar with Undo that restores the previous status. Use the label "Cancel task" in the
  danger colour.
- **P1 · UX/input · `lib/ui/schedule_screen.dart:328-343,210-217`**: time is free-text only: `HH:mm` for
  daily, **seconds** for interval, and an ISO string for one-off. A one-off is pre-filled with the stored
  `fireAt`, which is a UTC ISO string such as `2026-10-11T04:30:00.000Z`, so a user in IST sees a time 5.5 h
  off and must reason about `Z`. Typing ISO dates on a phone keyboard is error-prone. ChatGPT Tasks and
  Google Calendar use pickers. *Fix:* use `showTimePicker` for Daily, `showDatePicker` + `showTimePicker`
  for One-off (pre-filled with the **local** time), and a number + unit dropdown (minutes / hours / days,
  minimum 5 min) for Interval. Keep the text field only as an "Advanced" option.
- **P2 · functional · `lib/core/agent_service.dart:20873-20893`, `lib/ui/schedule_screen.dart:509-513`**:
  Edit is enabled for `completed`, `cancelled`, `paused` and `failed` tasks, and `editSchedule` replaces
  the task with a fresh `create()` result whose status is `pending`. Saving a paused task therefore
  silently un-pauses it. Saving a completed one-off with its old (past) time re-runs it immediately, since
  past times are "due immediately". The replacement also drops `lastStatus`, `finishedAt` and `attempt`,
  so run history is lost. *Fix:* keep the previous status unless the user taps "Save and resume", reject
  past one-off times on edit (or ask "Run now?"), and carry over the history fields.
- **P2 · stale UI · `lib/ui/schedule_screen.dart:27-30,671-686`**: there is no ticker, so "Next in 5m"
  stays the same until some unrelated state change happens. Left open, it can read "Next in 2m" long after
  the task ran. Conversely, any streamed token anywhere triggers a refresh (see next item), so the timer
  behaves inconsistently. *Fix:* add a `Timer.periodic(1 min)` that only runs while the route is current
  and `TickerMode.of(context)` is true. Tests can disable it with an injectable clock or flag rather than
  dropping the ticker.
- **P2 · perf · `lib/ui/schedule_screen.dart:50-52`**: `AnimatedBuilder` listens to the whole
  `AppState` + `AgentService`, so the full screen (every card, every `LayoutBuilder` detail row) rebuilds
  per streamed token while any chat is streaming (see `perf/streaming-rebuilds`). *Fix:* listen to a
  schedule-specific notifier (`agent.schedules` / `_schedulesChanged`) plus the notification-service
  background flag only.
- **P2 · UX/accuracy · `lib/ui/schedule_screen.dart:115-127`**: the headline shows "Background execution
  active" with a pulsing green dot even when keep-alive or notifications are off (the notes below say
  tasks may not run), when there are no tasks, or when every task is paused. *Fix:* use three states:
  "Active" (green), "Limited" (amber, when keep-alive or notifications are off or a constraint exists), and
  "Paused". Do not pulse when nothing is scheduled.
- **P2 · l10n · `lib/ui/schedule_screen.dart:776-789,448-451`**: `_fmtInstant` hard-codes English month
  names and 12-hour time, ignoring the device 24-hour setting (`MediaQuery.alwaysUse24HourFormat`) and
  locale. The status pill shows raw lowercase keys (`pending`, `failed`). *Fix:* use `intl`
  `DateFormat.yMMMd().add_jm()` / `MaterialLocalizations.formatTimeOfDay`, and map status keys to
  display labels ("Scheduled", "Running", "Paused", "Failed", "Done", "Cancelled").
- **P2 · data growth · `lib/ui/schedule_screen.dart:63-92`**: completed and cancelled tasks are never
  removed (there is no delete action and no auto-prune), and the list is a non-lazy `ListView(children:)`.
  An "every 5 min" agent experiment or many one-offs grow the list, and `session.schedules`, without limit.
  *Fix:* add "Delete" for completed or cancelled tasks, plus "Clear finished", auto-prune finished
  one-offs after 30 days, and use `ListView.builder`.
- **P2 · a11y · `lib/ui/schedule_screen.dart:448-456,530-533`**: the status is conveyed by pill colour
  plus a raw word. The overflow button tooltip is the generic "Task actions", without naming the task.
  The card has no merged semantics, so TalkBack reads the pill, prompt, recurrence and countdown as four
  separate stops. *Fix:* wrap the header in `Semantics(label: 'Task: $prompt, $statusLabel, $secondary')`
  and use a tooltip such as `'Actions for $prompt'`.
- **P2 · UX · `lib/ui/schedule_screen.dart:292-300`**: the prompt field is capped at `maxLines: 2`, so
  editing a multi-paragraph task prompt happens in a 2-line window. Saving also stores `_prompt.text`
  untrimmed (`:260`). *Fix:* use `minLines: 2, maxLines: 6` inside the already-scrollable sheet, and
  trim on save.
- **P2 · UX · `lib/ui/schedule_screen.dart:153-158`**: the Stop/Resume button has no busy state, so a
  double tap fires two overlapping `stopBackground`/`resumeBackground` calls (the generation counter
  absorbs it, but the user sees no feedback for the native round trip). *Fix:* disable the button and
  show a spinner while the call is pending.

**Missing features:** a create-task flow in the UI ("New task" FAB with prompt + picker; ChatGPT Tasks
has one), "Run now", a global "All scheduled tasks" view across chats (today the user must open each chat
to find its schedules, and the screen is unreachable without an active session), a run history per task
with links to the produced messages, notification-on-completion toggles per task, and a
deep link from the completion notification to the task.

**Test to add:** a widget test that taps "Stop background execution" while a fake foreground run is
active, expecting a confirm dialog and, after cancel, the run still active. A coordinator test: stop →
resume → the formerly pending tasks are `pending` again. A test that `resumeTask` throwing
`StateError` shows friendly copy without "Bad state". A test that editing a paused task keeps it paused.
A golden for `_fmtInstant` with `alwaysUse24HourFormat: true`.

---
## 7. TrajectoryScreen — event ledger — `lib/ui/trajectory_screen.dart`

**What it is / how reached:** the sidebar footer row "Trajectory — event ledger"
(`lib/ui/sidebar.dart:270-281`), enabled only with an active session. It loads the session's append-only
JSONL ledger (`SessionLedger.read` + `projection`, `lib/core/session_ledger.dart:237,351`) and shows a
stats card (turns, tool calls, wall / LLM / tool time, top tools) followed by a `SliverList.builder` of
event cards (timestamp, `#seq · title`, outcome, detail, "View details" → raw JSON dialog). A Reload
action is in the AppBar. It is a power-user / debugging view.

**Findings**
- **P1 · functional/data · `lib/core/session_ledger.dart:369-371`, `lib/ui/trajectory_screen.dart:194,225`**:
  "LLM time" is always **0s**. The projection only sums `llm` events, but no code appends an `llm` event
  (all `SessionLedger.I.append` call sites write `turn_start`, `turn_end`, `tool_start`, `tool_end`,
  `checkpoint`, `approval` or `note`). The real figure is in `turn_end.llmMs` (`agent_service.dart:11503`).
  Users and support therefore get a wrong cost/latency picture. *Fix:* in `projection`, add `turn_end.llmMs`
  (and use `turn_end.toolMs` as a cross-check), or start emitting `llm` events. Add a projection unit test.
- **P1 · perf/memory · `lib/ui/trajectory_screen.dart:41-42`, `lib/core/session_ledger.dart:351-352`**:
  opening the screen scans and decodes the **entire ledger twice** (`read()`, then `projection()` calls
  `read()` again), and keeps every decoded event map in memory. The ledger is never truncated, so a
  long-lived agent chat (thousands of tool calls, plus large `error` strings) means seconds of spinner and
  tens of MB of maps on low-end devices. Every Reload repeats both scans. `read()` already supports
  `offset/limit` paging, but the screen does not use it. *Fix:* compute the projection from the events
  already read (a pure `SessionProjection.fromEvents(events)`), or have the isolate return both in one
  pass. Page the list: load the newest 200 and fetch more on scroll.
- **P2 · error handling · `lib/core/session_ledger.dart:259-261`, `lib/ui/trajectory_screen.dart:49-55,242-253,341-350`**:
  `SessionLedger.read` catches **everything** and returns `[]`, so the screen's error and Retry states are
  unreachable. A corrupt, unreadable or permission-denied ledger shows "No ledger records yet. Events are
  recorded as you run the agent", which is false. When the error path does run, it shows raw `'$e'`.
  *Fix:* let `read` surface I/O errors (or return a result type with `error`), show "Couldn't read this
  chat's history" with Retry, and log the raw error to `Diag`.
- **P2 · functional · `lib/ui/trajectory_screen.dart:152`, `lib/core/agent_service.dart:21954-21958`**:
  recovery `note` events store their text under the key `note`, but `_detailFor` reads `text` or
  `message`. The one note kind the app writes ("recovered N tool rows as UNKNOWN") therefore renders as a
  bare red "Note" with no explanation. *Fix:* read `e['note'] ?? e['text'] ?? e['message']`.
- **P2 · functional · `lib/ui/trajectory_screen.dart:78-136`**: `approval` events (7 call sites:
  user-approved, user-denied, hook-denied and plan-mode-denied tool calls) are not mapped. They render
  with the raw title "approval", a hollow-circle icon, faint colour, no detail, and no outcome, even
  though these are the most security-relevant records in the ledger. *Fix:* add an `approval` case:
  title "Approval: $tool", outcome "Approved" / "Denied by you / by plugin hook $plugin / by plan mode",
  shield icon, danger colour when `ok == false`, and show `note`.
- **P2 · UX · `lib/ui/trajectory_screen.dart:295`**: timestamps are the raw stored ISO-8601 UTC string
  (`2026-10-11T04:31:22.123Z`) in 11pt faint mono. *Fix:* show local time (`HH:mm:ss`), add a date
  divider per day, and keep the raw value in the details dialog.
- **P2 · UX · `lib/ui/trajectory_screen.dart:193,224`, `lib/core/session_ledger.dart:376-378`**:
  "Wall time" is `lastTurnEnd − firstTurnStart`, which includes all idle time between visits, so a chat
  used on Monday and Friday shows "Wall time 4d" next to "LLM time 0s". *Fix:* sum per-turn durations
  (`turn_end.t − matching turn_start.t`), and label it "Active time".
- **P2 · UX · `lib/ui/trajectory_screen.dart:254-332`**: events are listed oldest-first with no filter,
  search or jump-to-latest, so in a long session the user must scroll thousands of cards to reach the most
  recent failure. The screen is also not live: it does not refresh while the agent runs. *Fix:* order
  newest-first (or auto-scroll to the end), add filter chips (All / Failures / Tools / Approvals) and a
  search box, and subscribe to a ledger-append notifier for the session (or auto-refresh while
  `busyFor(sessionId)`).
- **P2 · a11y/tap targets · `lib/ui/trajectory_screen.dart:283-322`**: only the small "View details"
  `TextButton` is tappable, not the card. Its `Semantics(label:)` replaces the button text, so TalkBack
  never says "View details" and the timestamp and `#seq` are read as separate stops. *Fix:* make the whole
  card an `InkWell` with `Semantics(button: true, label: summary, hint: 'Opens details')`, and
  `ExcludeSemantics` on the inner texts.
- **P2 · perf/UX · `lib/ui/trajectory_screen.dart:58-76`**: the details dialog renders
  `JsonEncoder.withIndent` of the whole event in a single `SelectableText` inside `AlertDialog(scrollable)`.
  A very large `error` string (stack traces, HTML bodies) lays out as one huge paragraph and janks, and
  there is no Copy button. *Fix:* cap the displayed JSON at about 20 KB with "Show all", add a "Copy JSON"
  action, and use a full-screen dialog on phones.
- **P2 · copy · `lib/ui/sidebar.dart:274`, `lib/ui/trajectory_screen.dart:218,141`**: "Trajectory — event
  ledger", "Session stats (ledger projection)" and "model request · N rows" are engineering jargon shown
  in the main sidebar to every user. *Fix:* rename to "Activity log" / "Run history" in the sidebar, use
  "Chat stats" and "Sent N messages to the model", or move the entry under Settings → Developer.
- **P2 · UX · `lib/ui/trajectory_screen.dart:367,378`**: the title reads `AppState.I.sessionById` once
  in `build` without listening, so a rename does not update it, and the font size is hard-coded to 14
  instead of the theme's AppBar style. *Fix:* use `AnimatedBuilder(AppState.I)` for the title only, and
  drop the hard-coded size.

**Missing features:** export or share the ledger (JSON or text, for support tickets), a per-turn grouping
(collapse the tool calls under each turn), a token and cost column per turn (the ledger already records
turns, and this is where Claude Code-style `/cost` usage tracking would surface), tap-through from an event
to the corresponding chat message, and filters for failures and approvals.

**Test to add:** a projection unit test with two `turn_end` events carrying `llmMs: 1000`, expecting LLM
time 2 s. A widget test feeding a `note` event `{note: 'recovered 2 tool rows'}`, expecting that text. An
`approval` event with `ok: false, deniedBy: 'hook'`, expecting "Denied" and a non-generic icon. A test
where `SessionLedger.read` throws, expecting the "Couldn't read" state with Retry (after the fix). A test
that opening the screen performs one ledger scan, not two.

---
## 8. SubagentScreen and subagent catalog sheet — `lib/ui/subagent_screen.dart`

**What it is / how reached:** a subagent is a real child session. `SubagentScreen.open` is called from the
subagent card in the chat transcript (`chat_screen.dart:3391`), from the lineage breadcrumb, and from the
catalog sheet. The screen shows: an AppBar (agent label, descendants button with count badge, Stop while
running), a horizontal lineage breadcrumb, a status strip (state pill, elapsed, "N rows", queued count,
continuable / one-shot, lock icon with allowed tools), the reused `ChatTranscript`, a jump-to-latest
button, and a composer. The composer is read-only for one-shot children and sends follow-ups through
`AgentService.continueSubagent` for continuable ones. `showSubagentCatalog` is a bottom sheet listing the
children (`_CatalogCard`: status dot, label, state pill, runtime, Stop, rows / mode / grandchildren).

**Findings**
- **P1 · perf · `lib/ui/subagent_screen.dart:122-124,148,560-561`**: the whole screen, including the
  full `ChatTranscript`, the lineage (which walks `lineageOf`) and the status strip, is inside an
  `AnimatedBuilder` on all of `AppState` + `AgentService`. Every build also schedules a post-frame
  `_jumpToBottom` callback. While **any** session streams or any subagent emits, the entire child
  transcript rebuilds and a scroll callback is queued per notification. Subagent fan-out (several children
  streaming at once) is exactly when this screen is open. The catalog sheet has the same listener.
  `perf/streaming-rebuilds` removes the per-token `AppState.refresh`, but `AgentService.notifyListeners`
  still fires on every `_emit`. *Fix:* scope the builder to the session (`Selector`-style listenable for
  `s.id`: messages length, busy, agentState, queued count), let `ChatTranscript` listen to
  `liveBubbleTicks` itself, and call `_jumpToBottom` only when the message count or the live bubble length
  changes.
- **P2 · navigation · `lib/ui/subagent_screen.dart:279-282`**: tapping a *subagent* ancestor in the
  breadcrumb **pushes** a new `SubagentScreen` instead of popping back to it. Walking Root › A › B, tap A,
  tap into B again, and so on builds an unbounded stack (each with its own whole-app `AnimatedBuilder`),
  and Back walks through every duplicate. *Fix:* if a route for that ancestor is already on the stack,
  `popUntil` it (give routes `RouteSettings(name: 'subagent/$id')`). Otherwise use `pushReplacement`
  so breadcrumbs never deepen the stack.
- **P2 · copy/code health · `lib/ui/subagent_screen.dart:102-109`, `lib/core/agent_service.dart:21859-21905`**:
  `continueSubagent` returns **model-facing tool strings**, and the UI both shows them verbatim in a
  SnackBar ("queued as the next turn for sub-12", "resumed sub-12", "message is empty", the concurrency
  refusal written for the model) and decides whether to clear the draft by matching string prefixes. A
  wording change in core silently breaks draft clearing. *Fix:* return a typed result
  (`enum ContinueOutcome { queued, resumed, refusedOneShot, refusedBusyCap, accountSwitching, empty }`
  plus a detail), keep the string form for the tool layer only, and map outcomes to user copy ("Queued —
  the agent will pick this up after its current step", "Agent resumed", "Too many agents running — stop
  one and try again"). Also replace the raw `'Could not send follow-up: $e'` (`:113`).
- **P2 · a11y/tap targets · `lib/ui/subagent_screen.dart:167-176,207-234,318-341,513-541`**: the AppBar
  Stop, the descendants button and the composer Stop/Send all use `VisualDensity.compact` (40×40 dp). The
  jump-to-latest button is about 36×28 dp. The count badge is 8.5pt white on accent and sits on top of the
  icon. *Fix:* drop `compact` on primary actions (or wrap them in a 48×48 `SizedBox`), make the jump
  button a `FloatingActionButton.small` (40 dp visual with a 48 dp target), use
  `Badge.count(count: ...)` from Material 3 so the count is read as part of the button's semantics
  ("Subagents, 3").
- **P2 · a11y/contrast · `lib/ui/subagent_screen.dart:287-298,394,458`**: breadcrumb labels are 10.5pt in
  `textFaint`, the status line is 11pt `textMuted`, and the read-only note is 11.5pt `textFaint`. These are
  hard-coded sizes that do not use the type scale and are likely below 4.5:1 contrast on `Aether.bg`
  (see `08` theme contrast notes). *Fix:* use `AetherType.caption` / `label` tokens with a minimum 12sp
  and a contrast-checked colour.
- **P2 · UX · `lib/ui/subagent_screen.dart:396-404`**: the subagent's allowed-tool restriction is
  shown only as a 13 dp lock icon with a `Tooltip`, which on Android appears only on long press of a
  non-interactive icon. Most users never see which tools the agent may use, and TalkBack does not reach
  it. The child's original task prompt is also not shown anywhere except inside the transcript. *Fix:*
  add a tappable "Task & permissions" chip that opens a sheet with the dispatch prompt, the allowed tools,
  the mode and the parent.
- **P2 · copy · `lib/ui/subagent_screen.dart:368,391,636-637`**: "N rows", raw state keys (`finished`,
  `stopping`), "one-shot" / "continuable", and raw `session.mode` in the catalog are internal terms.
  *Fix:* use "N messages", display labels ("Done", "Stopping…", "Failed", "Stopped"), "Single task" /
  "Accepts follow-ups", and the mode's display name.
- **P2 · UX/stale · `lib/ui/subagent_screen.dart:367,632-634`**: elapsed time is computed in `build` and
  only advances when some notification happens, so a quiet running child (a long tool call) shows a
  frozen timer. *Fix:* a 1 s ticker while `running`, scoped to the elapsed `Text` only.
- **P2 · UI · `lib/ui/subagent_screen.dart:640-643`**: `_CatalogCard` wraps an `AetherCard` (a decorated
  container) in an `InkWell` with no `Material` between them, so the ripple paints *under* the card's
  opaque background and taps give no visual feedback. The card also has no `Semantics(button: true)`
  label. *Fix:* use `Material(color: transparent)` + `Ink` decoration inside the card, or give
  `AetherCard` an `onTap`. Add a semantics label ("$label, $state, $runtime").
- **P2 · UX · `lib/ui/subagent_screen.dart:175,249,695`**: Stop acts immediately from three places, with
  no "Stopping…" state on the button. A repeated tap re-invokes `stopSubagentRun`, and the pill can read
  `running` until the run settles. *Fix:* show `stopping` optimistically, disable the Stop buttons
  until the state changes, and add an Undo-free confirmation only for children that have run longer than
  about 1 minute (losing work).
- **P2 · layout · `lib/ui/subagent_screen.dart:580-602`**: the catalog is a `shrinkWrap` `ListView` with
  eager `children`. That is fine for a few children, but a coordinator that fans out 20+ agents lays out
  every card each notification. *Fix:* use `ListView.builder` and `DraggableScrollableSheet`.

**Missing features:** "Copy result" / "Send result to parent chat", a final-result summary card pinned at
the top for finished children, a per-child token and cost figure (Claude Code shows per-subagent usage),
"Stop all subagents" in the catalog, a tree view of nested descendants (the catalog shows only direct
children, and "N sub" is not tappable), and a way to open the catalog from the root chat header (today
`showSubagentCatalog` is only reachable from inside a subagent that has children).

**Test to add:** a widget test that opens Root › A › B, taps A in the breadcrumb, and asserts the navigator
stack depth decreases (after the fix). A test that `continueSubagent` returning a refusal keeps the draft
and shows user copy without "sub-" ids. A tap-target test (`meetsGuideline(androidTapTargetGuideline)`)
on the screen while running. A rebuild-count test: 50 `AgentService` notifications for another session
cause 0 rebuilds of the child `ChatTranscript`.

---
## Group summary

**Totals (sections 1–8):** 2 × P0, 25 × P1, 58 × P2.

**Themes.** (1) Whole-app listeners: the sidebar, browser, schedule and subagent screens all rebuild on
every `AppState`/`AgentService` notification. (2) No router, no restoration and no deep-link targets beyond
share. (3) Destructive actions with no confirm or undo (chat delete, schedule cancel, "Stop background",
which is actually a global panic stop). (4) Raw exception and model-facing strings shown to users.
(5) Data-scale limits: the SharedPreferences session blob, full ledger reads, unbounded WebViews.

**Top 10 fixes, in order**
| # | Fix | Sections | Sev | Effort |
|---|---|---|---|---|
| 1 | Make the sidebar list lazy (`ListView.builder`) and driven by a narrow session-summary notifier; cache `hasImage` and use a per-session busy listenable instead of per-tile `AgentService` listeners | 3 | P0 | M |
| 2 | Narrow the listeners in Browser, Schedule, Subagent (and the catalog sheet) to screen-specific notifiers; stop history refresh from `build` and per-build `_jumpToBottom` | 5, 6, 8 | P1 | M |
| 3 | "Stop background execution": confirm dialog plus schedules-only stop (no `cancelAllRuns`); on Resume re-pend tasks paused by Stop | 6 | P1 | S |
| 4 | Optimistic chat delete with try/catch and "Undo" snackbar (and Archive); confirm/undo for schedule Cancel | 3, 6 | P1 | M |
| 5 | WebView LRU pool (max 3 live), render only the active tab, cap tabs per session; `PopScope` back-in-history; omnibar shows the host, not the page title | 5 | P1 | M |
| 6 | Add an `AppRouter` (`/c/:id`, `/s/:token`, `/schedule/:sid`, …), route notification taps and App Links through it, validate ids; set `restorationScopeId` and persist composer drafts; fix share-link dedupe and the post-frame retry | 1 | P1 | L |
| 7 | Telemetry consent: single-show guard and non-dismissible (or dismiss = decline) | 2 | P1 | S |
| 8 | Replace raw `'$e'` / model-facing strings with mapped user copy (Schedule, Trajectory, Subagent `continueSubagent` typed result, startup panel) | 4, 6, 7, 8 | P1 | S |
| 9 | Trajectory correctness and scale: sum `turn_end.llmMs` for LLM time, one-pass projection, paged reads, surface read errors, render `approval` and `note` events | 7 | P1 | S |
| 10 | Sidebar ordering and search: `updatedAt` with recency sort and date headers; debounced content search through `SessionSearch` or FTS; live connectivity re-probe with a visible offline banner | 3 | P1 | M (L with the SQLite store) |

**Order rationale:** 1–2 are pure perf wins with no UX change and unblock 10M-DAU low-end devices.
Ship them right after `perf/streaming-rebuilds`. Items 3, 7 and 8 are small, high-trust fixes and can go in
one PR. Items 4 and 5 are medium, self-contained PRs. Item 6 (router and restoration) is the largest
refactor and should land before more deep-link features. Item 10 depends on the SQLite history migration
in the master plan (`00-master-plan.md`) for content search at scale. Schedule time pickers (section 6),
the tap-target and contrast sweep (sections 4, 5, 8) and the remaining P2s can follow as a UX/a11y batch.
