# UI/UX 14-Screen Sweep — file:line audit (2026-09-06)

Read-only audit of `lib/ui/*.dart`. No code modified. Each row: `file:line | issue | severity | suggested fix`.
Severities: Critical / High / Med / Low.

---

## 1. Chat (`lib/ui/chat_screen.dart`, 5926 lines)

| file:line | issue | severity | suggested fix |
|---|---|---|---|
| chat_screen.dart:4130-4138 | Voice (mic) button is dead: `onPressed: () {}` renders a tappable affordance that does nothing. | Med | Wire to speech-to-text or remove button until implemented; Settings also advertises `Voice input / On`. |
| chat_screen.dart:1106-1107 + 4173-4186 | Approval lock bypass: `locked` disables the `TextField` (4089) and `onSubmitted` (4106), but the circular primary send button (4173-4186) calls the `onSend` closure (1107) which never checks `pendingApproval` — user can send while an approval card awaits an answer. | High | Check `AgentService.I.pendingApproval != null` at the top of the `onSend` closure and disable/grey the send button when locked. |
| chat_screen.dart:4853-4866 | Approval detail truncated at `maxLines: 8` + ellipsis; the dangerous part of a long destructive command can be cut off with no expand affordance. | Med | Make the detail text expandable (tap to expand / show full in scrollable). |
| chat_screen.dart:4613-4625 | Queue "Clear all" deletes every queued message with no confirmation and no undo. | Low | Add confirm or an undo snackbar. |
| chat_screen.dart:4177-4181 | Red Stop = `cancelAllRuns()` kills every run incl. parallel sessions/subagents — global side effect from a per-chat button, only documented in a comment. | Med | Confirm sheet ("Stop this chat" vs "Stop everything") or a tooltip stating scope. |
| chat_screen.dart:773-774 | `_bindDraft` re-invoked via `addPostFrameCallback` on every build while session non-null; harmless today but fragile ordering with paging/scroll callbacks. | Low | Bind once per session change (e.g. in `didChangeDependencies` on id change). |

## 2. Sidebar (`lib/ui/sidebar.dart`)

| file:line | issue | severity | suggested fix |
|---|---|---|---|
| sidebar.dart:332-348 | Swipe-to-delete (`Dismissible`) deletes a session immediately with no confirmation and no undo snackbar — one accidental swipe destroys chat history. | High | `confirmDismiss` dialog or undo snackbar restoring the session. |
| sidebar.dart:169-179 | Empty state only covers search-no-match (`No sessions match …`); a fresh install with zero sessions gets the same dead-end text with no "create your first session" guidance. | Med | Branch on `roots.isEmpty && q.isEmpty` → onboarding CTA that calls `newSession()`. |
| sidebar.dart:440-469 | Rename dialog Saves unconditionally; empty/blank text is passed to `renameSession` with no UI guard. | Med | Disable Save on blank input or fall back to existing title. |
| sidebar.dart:183-191 | Workspace group headers render even for users who never set workspaces (`(NO WORKSPACE)` bucket header = noise). | Low | Hide group headers when there is only one group. |

## 3. Browser (`lib/ui/browser_screen.dart`)

| file:line | issue | severity | suggested fix |
|---|---|---|---|
| browser_screen.dart:325-333 | Zero-tab state: `IndexedStack(index: activeTabIndex, children: [])` with no empty state; out-of-range index asserts in debug and users see a blank column under a live omnibar. | High | Guard: if `browserTabs.isEmpty`, show an empty state ("No tabs — new tab") + auto-create a tab. |
| browser_screen.dart:186-196 | Closing the last/active tab leaves `activeTabIndex` stale: `_activeTab` is null-guarded but the `IndexedStack` index and `_url` omnibar are not refreshed. | Med | Clamp `activeTabIndex` in `closeBrowserTab` (service) and refresh `_url` after close. |
| browser_screen.dart:219-237 | Back/forward buttons silently no-op when navigation is unavailable, with no disabled visual state. | Low | Grey out via `FutureBuilder(canGoBack)` or track nav state. |
| browser_screen.dart:74-75 | Local-preview tabs show literal `Live preview` in the omnibar — actual path/URL hidden, cannot copy. | Low | Show `tab.url` with a preview badge instead of replacing the text. |
| browser_screen.dart:357-366 | Agent dot is static despite the "pulsing while agent drives" comment — no animation. | Low | Pulse via `AnimationController` when `busy`, or fix the comment. |

## 4. Studio (`lib/ui/studio_screen.dart`)

| file:line | issue | severity | suggested fix |
|---|---|---|---|
| studio_screen.dart:54-62 | `_autoSync` swallows every exception (`catch (_) {}`): failed repo syncs are invisible — spinner stops, nothing updates, no message. | High | Surface failures with `_toast('Sync failed: $e')`. |
| studio_screen.dart:438-450 | `_openUnknownFile` opens an empty buffer on fetch failure (448) with no error — a real file looks blank/empty to the user. | Med | Toast on failure and/or open a read-only error placeholder instead of `''`. |
| studio_screen.dart:43-52 | First open auto-fires the GitHub login sheet when logged out — interruptive entry; user hasn't asked to connect yet. | Med | Show a "Connect GitHub" inline CTA in `_RepoBar` instead of an auto-modal. |
| studio_screen.dart:339-358 | Fixed 210px file pane + 240px terminal with no responsiveness; on small phones the editor is squeezed to unusable width. | Med | Collapse file pane to an overlay drawer below ~600px; make terminal height proportional. |
| studio_screen.dart:209-248 | Repo picker has no search/filter — unusable with many repos; list errors only via snackbar. | Low | Add a filter field to the repo sheet. |
| studio_screen.dart:146 | Dismissing `_offerWorkspaceFolder` (`choice == null`) silently keeps the default with no confirmation of where work happens. | Low | Toast the effective workspace on dismiss. |

## 5. Sandbox setup (`lib/ui/sandbox_setup.dart`)

| file:line | issue | severity | suggested fix |
|---|---|---|---|
| sandbox_setup.dart:348-349 | Error view puts `Expanded(_terminal())` after a `Spacer()` in the same `Column` — the two flex widgets fight; the log terminal can collapse to ~zero height when it is most needed. | Med | Replace `Spacer` with `SizedBox` or give the terminal a fixed flex + min height. |
| sandbox_setup.dart:389-399, 418-428 | Retry resets UI state but never cancels a possibly still-running `install()` future — double-install overlap risk. | Med | Track run generation / add `SandboxService.cancelInstall()` and call before retry. |
| sandbox_setup.dart:157-164, 432-438 | Close button in the error view calls `Navigator.pop` unconditionally; in `gateMode` the `PopScope` vetoes it, so the button appears dead with no explanation. | Low | Hide Close in `gateMode` error state, or explain the gate blocks exit. |
| sandbox_setup.dart:77-79 | Elapsed ticker `setState` every second rebuilds the whole screen incl. the terminal `ListView` each second during long installs. | Low | Isolate the ticker in a small `ValueListenableBuilder` around the elapsed label. |
| sandbox_setup.dart:126-131 | Comment says "7 phases" but `_phaseNames` has 9 entries — comment drift. | Low | Fix the comment. |

## 6. Settings (`lib/ui/settings_screen.dart`)

| file:line | issue | severity | suggested fix |
|---|---|---|---|
| settings_screen.dart:154-161, 185-194, 230-234, 260-261 | Nine rows look tappable but are dead (`_settingTile` hardcodes `onTap: () {}` at 296): Appearance, Language, Image generation, Voice input (`On` — contradicts the dead chat mic), Default agent, In-app browser, Sandbox status, Notifications, About. | High | Either implement, show "coming soon" feedback on tap, or render as non-interactive info rows. |
| settings_screen.dart:314-330 | Privacy-policy dialog shows the URL as plain non-tappable text — user must retype it. | Med | `SelectableText` + launch URL button (or open in the in-app browser). |
| settings_screen.dart:103-126 | Back-to-back `SectionHeader('Workspace')` / `SectionHeader('Workspace stats')` reads as a duplicate. | Low | Merge into one `Workspace` section. |
| settings_screen.dart:261 | Hardcoded `About … 0.1.0-demo` version string. | Low | Inject from `package_info_plus`. |

## 7. Health (`lib/ui/health_screen.dart`)

| file:line | issue | severity | suggested fix |
|---|---|---|---|
| health_screen.dart:81-110 | Builder only handles `report == null || checking`; if `runChecks()` throws, the screen sits on a stale/absent report with no error state. | Med | `try/catch` around `runChecks` + an error view with Retry. |
| health_screen.dart:197-229 | Repair CTA background uses the score color — red/danger-styled primary button when critical, which reads as "destructive, don't tap". | Low | Keep accent for the CTA; reserve score color for the ring/label. |

## 8. Usage (`lib/ui/usage_screen.dart`)

| file:line | issue | severity | suggested fix |
|---|---|---|---|
| usage_screen.dart:206-217 | Summary row packs 4 `Expanded` stats; long mono values (big 22px `Est. cost`) can clip/overflow on narrow screens — no `overflow`/`FittedBox` handling. | Med | `Flexible` + `FittedBox(scaling)` or `overflow: TextOverflow.ellipsis` in `_stat`. |
| usage_screen.dart:117 | Tier hardcoded to `'BYOK'` for every provider while the model carries an `'Ovid Free' | 'BYOK'` tier field — dead branch, mislabels free-tier usage. | Low | Derive tier from provider metadata (`isFree`). |

## 9. Plugins (`lib/ui/plugins_screen.dart`)

| file:line | issue | severity | suggested fix |
|---|---|---|---|
| plugins_screen.dart:177-184 | Filter with zero matches renders an empty gap under the `ALL PLUGINS` header — no empty state. | Med | `SliverToBoxAdapter` empty view ("No plugins match — clear search / add marketplace"). |
| plugins_screen.dart:51-60 | Marketplace sync failures swallowed (`catch (_)`) with only a spinner stop — same silent-failure pattern as Studio sync. | Med | Toast on failure; keep built-in catalog. |
| plugins_screen.dart:13-25 | `_toolGainsFor` hardcodes plugin-name → tool mapping; any new/renamed plugin reports no capability gain and drifts from the `AgentService` gate. | Low | Derive from a registry both sides share. |
| plugins_screen.dart:65, 121 | Category chips and the `Search 4,800+ community plugins…` hint are hardcoded marketing counts. | Low | Compute counts from the actual catalog. |

## 10. Providers (`lib/ui/providers_screen.dart`)

| file:line | issue | severity | suggested fix |
|---|---|---|---|
| providers_screen.dart:244-261 | Keystroke handler strips whitespace into `target.apiKey` and calls `refresh()` (full-list rebuild per keystroke), but the debounced persist passes the *raw unstripped* `value` — UI state and secure-store state can disagree. | Med | Persist the stripped value; debounce the `refresh()` too. |
| providers_screen.dart:222-234 | `dispose()` fires unawaited async persist (`unawaited … catchError`) — the write can be lost if the screen is torn down mid-flight. | Med | Await pending persists before dispose (flush in `deactivate` or on pause). |
| providers_screen.dart:236-242 | Custom base-URL edits mutate the provider live with no validation; typos only surface later as fetch failures. | Low | Validate `Uri` scheme on edit; inline error hint. |
| providers_screen.dart:31-32 | Non-English (Hinglish) code comment in an otherwise English codebase. | Low | Translate to English. |
| providers_screen.dart:427-439 | Model merge only adds; stale/removed model IDs linger forever (except full-empty clear). | Low | Reconcile: drop IDs absent from a successful fetch unless manually added. |

## 11. Subagent (`lib/ui/subagent_screen.dart`)

| file:line | issue | severity | suggested fix |
|---|---|---|---|
| subagent_screen.dart:96 | `_jumpToBottom()` invoked inside `build` on every rebuild — yank-scrolls the user to the bottom even when they scrolled up to read history. | Med | Only auto-follow when already at bottom (mirror chat's `_atBottom` pattern). |
| subagent_screen.dart:63-65 | Every continue shows a snackbar with `status` even on success — noisy for routine sends. | Low | Snackbar only on failure/queued states; success is evident from the transcript. |

## 12. Trajectory (`lib/ui/trajectory_screen.dart`)

| file:line | issue | severity | suggested fix |
|---|---|---|---|
| trajectory_screen.dart:30-39 | `_load` awaits two ledger reads with no `try/catch` — any ledger I/O error leaves the infinite loading spinner (110-111) forever. | Med | Catch → error view with Retry (mirror pattern used elsewhere). |
| trajectory_screen.dart:203-210 | Raw `e['t']` timestamp dumped unformatted into the subtitle. | Low | Format relative/absolute time. |

## 13. Auth (`lib/ui/auth_screen.dart`)

| file:line | issue | severity | suggested fix |
|---|---|---|---|
| auth_screen.dart:28-44 | No client-side validation — empty/garbage email + password round-trip to Firebase before any error surfaces. | Med | Validate email format + non-empty password inline before submit. |
| auth_screen.dart:163-172 | Password field has no visibility toggle. | Low | Add `obscureText` toggle icon. |
| auth_screen.dart:46-56 | `_reset` has no busy state (double-tap sends twice) and success/failure both render as identical snackbars. | Low | Disable while sending; distinct success styling. |
| auth_screen.dart:214 | Google button uses `Icons.g_mobiledata` as a stand-in "G" logo. | Low | Use a proper Google "G" asset. |

## 14. GitHub login sheet (`lib/ui/github_login_sheet.dart`)

| file:line | issue | severity | suggested fix |
|---|---|---|---|
| github_login_sheet.dart:176-184 vs 25-27 | Post-success dismiss via header X pops with `null`, so `onConnected` never fires — caller state thinks GitHub is still unconnected even though auth succeeded. | Med | Pop with `true` when `_state == done`, or hide X in done state (force Continue). |
| github_login_sheet.dart:368-372 | Error view renders raw `'$e'` exception text to users. | Low | Map to friendly messages; log the raw error. |
| github_login_sheet.dart:73-75 | One-second expiry ticker `setState`s the entire sheet. | Low | Isolate countdown text in its own widget. |
| github_login_sheet.dart:283-286 | Poll-attempt counter (`poll #N`) is debug surface in user UI. | Low | Remove or move behind a details tap. |

---

## Ranked fix list (Critical first)

No Critical issues found. Ranked by severity, then by blast radius:

1. **High** — Approval lock bypass (chat:1106 + 4173): send button ignores `pendingApproval`. Safety-gate hole.
2. **High** — Zero-tab `IndexedStack` with no empty state (browser:325): crash-risk + blank screen.
3. **High** — Swipe-to-delete with no undo (sidebar:332): irreversible data loss on mis-swipe.
4. **High** — Nine dead settings rows (settings:154-261): hub full of no-op taps.
5. **High** — Silent repo-sync failure (studio:54): errors vanish, user left staring at stale state.
6. **Med** — Stale `activeTabIndex` after tab close (browser:186).
7. **Med** — Empty-file illusion on fetch failure (studio:438).
8. **Med** — Auto-firing login modal on Studio entry (studio:43).
9. **Med** — Unresponsive 210px/240px Studio panes (studio:339).
10. **Med** — Error-view flex fight hiding the log (sandbox_setup:348).
11. **Med** — Retry without cancelling in-flight install (sandbox_setup:389).
12. **Med** — Dead mic button (chat:4130) + false `Voice input: On` (settings:161).
13. **Med** — Truncated approval detail, no expand (chat:4853).
14. **Med** — Global-kill Stop without scope disclosure (chat:4177).
15. **Med** — Fresh-install sidebar dead end (sidebar:169).
16. **Med** — Unguarded blank rename (sidebar:440).
17. **Med** — Non-tappable privacy URL (settings:314).
18. **Med** — No error state on health-check throw (health:81).
19. **Med** — Usage stat-row clipping risk (usage:206).
20. **Med** — Plugins zero-result blank gap (plugins:177).
21. **Med** — Silent marketplace-sync failure (plugins:51).
22. **Med** — API-key strip/persist mismatch + per-keystroke rebuild (providers:244).
23. **Med** — Unawaited persist in `dispose` (providers:222).
24. **Med** — Subagent build-time yank-scroll to bottom (subagent:96).
25. **Med** — Ledger-load throw = infinite spinner (trajectory:30).
26. **Med** — No client-side auth validation (auth:28).
27. **Med** — GitHub done-via-X drops `onConnected` (github_login_sheet:176 vs 25).
28. **Low** — remainder as tabled (copy, tooltips, counts, comments, formatting).
