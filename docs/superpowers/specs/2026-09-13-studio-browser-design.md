# Studio + Browser — Design

**Date:** 2026-09-13
**Status:** Approved for implementation.

## 1. Goal

Fix Studio/browser friction: folder selection only in Studio, external-browser
GitHub device login, a login-status dot instead of "Sandbox ready" text, fresh
tabs with shared browser data across sessions, and in-app browser Google sign-in.

## 2. Outcomes

1. The sandbox/workspace folder picker is reachable only from Studio mode.
2. Studio's GitHub device login opens the **external** browser.
3. Studio shows a login-status dot: green when logged in, red when not
   (replacing the "Sandbox ready" text).
4. Browser cookies/logins are shared across all sessions; a new session starts
   with fresh (empty) tabs.
5. Google sign-in works in the in-app browser (external browser or a non-`wv` UA
   strategy).

## 3. Non-Goals

- Rewriting the browser engine.
- OAuth callback deep-links (device flow needs none).
- On-device verification without hardware.

## 4. Current Failure Model (evidence)

- Folder picker is already Studio-only in code (`studio_screen.dart:309-338`;
  entry points `:496-505`, `:418`) but is **not mode-gated** by
  `AgentMode.studio`.
- GitHub login opens `BrowserScreen(openUrl: …)` (in-app WebView) at
  `github_login_sheet.dart:257-264`; no `url_launcher` external path.
- Studio status shows text `Sandbox ready`/`Sandbox pending`
  (`studio_screen.dart:552-557`) bound to `sandboxInstalled`; login state is a
  separate `_AccountChip` that hides when logged out (`:1532-1657`).
- Browser data is already app-global (`agent_service.dart:1297-1300`); new
  sessions get a default `google.com` tab (`:1455-1457`) — not empty.
- In-app WebView mobile mode uses the stock UA (contains `; wv`), which Google
  rejects as insecure (`OvidWebViewHandler.kt`; no third-party-cookie/UA config).

## 5. Design

### 5.1 Studio-only folder picker
Gate the folder affordances on Studio mode (or make Studio the only place they
exist, which is already true) and assert no other screen opens a picker.

### 5.2 External GitHub login
Open the device-verification URI with `url_launcher`
`LaunchMode.externalApplication`.

### 5.3 Login dot
Replace the status text with a dot driven by `GitHubService.I.isLoggedIn`
(green/red). Keep the sandbox-installed signal available elsewhere.

### 5.4 Fresh tabs, shared data
Keep the global CookieManager; change new-session tab initialization to an empty
tab set (no default `google.com`). Purge deleted sessions' tab buckets/prefs.

### 5.5 Google sign-in
Prefer the external browser for OAuth; otherwise present a non-`wv` user agent
for sign-in flows and enable third-party cookies/DOM storage as required.

## 6. Testing

- Studio-only picker pins.
- External-browser launch intent pin.
- Login-dot widget test (green/red).
- New-session tab freshness + shared-cookie pin.
- UA/cookie settings pin for the in-app browser.
- Full `flutter test` + `flutter analyze` green.

## 7. Decisions

- Folder selection lives only in Studio.
- GitHub device login uses the external browser.
- Browser data shared; tabs per-session and fresh.
- Google OAuth prefers external browser.
