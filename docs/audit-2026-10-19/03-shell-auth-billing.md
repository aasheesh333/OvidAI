# 03: App shell, navigation, auth, account, billing

Scope: lib/main.dart, lib/ui/{shell,app_router,sidebar,login_gate,auth_screen,auth_methods,github_login_sheet,profile_avatar,account_deletion_panel,billing_screen,usage_screen,cloud_usage_status,user_error}.dart, lib/ui/widgets/error_views.dart, lib/core/{state(account parts),account_service,account_session,auth_*,firebase_service,ovid_cloud_service,connection_service,cloud_app_check,cloud_usage_store,play_billing,distribution,reset_coordinator,secure_store,cert_pinning}.dart, lib/core/cloud/{cloud_config,push_service}.dart.
Branch feat/ovid-cloud @ fdf2c5f. Method: code read, compared against the server (cloud/apps/gateway, cloud/apps/mint), the live edge (/opt/ovid-gateway/caddy/Caddyfile, curl against api.ovidsi.com), the running containers' env, and logcat plus UI dumps from the shared emulator (/root/ovid-audit/shots, release APK). I did not drive the emulator UI myself because it is shared with the other auditors.

Severity: P0 = crash, blocked, data loss or security/privacy. P1 = broken or misleading. P2 = polish. "Suspected" means I inferred it from code and did not reproduce it.

---

## P0

### SH-001 (P0): App Check uses only Play Integrity, the gateway enforces it, and failures are unhandled. The release APK cannot use the cloud on an emulator or a sideloaded device
- **Where:** lib/core/cloud_app_check.dart:17-20,30-39; lib/core/firebase_service.dart:182-186; lib/core/cloud/cloud_rest.dart:96-108 (`authorize` lets `AppCheckUnavailable` escape); lib/core/ovid_cloud_service.dart:451-470 (the mint path swallows the same failure and sends no header).
- **Problem:** Every attestation goes through `AndroidProvider.playIntegrity`, and no debug provider exists for QA or internal builds. The production gateway runs with `APPCHECK_ENABLED=true` (container env, ovid-cloud-gateway-1 / ovid-gateway-mint-1). If Play Integrity is missing or does not recognise the app (emulator without the Play Store, an APK sideloaded outside Play, an upload-key-signed build), `CloudAppCheck.getToken` throws `AppCheckUnavailable`. `CloudHeaders.authorize` does not catch it, and callers that catch only `CloudApiException` let it escape as an unhandled async error. The user gets no explanation and Send does nothing.
- **Evidence:** logcat on the shared emulator (release APK): `ActivityManager: Unable to start service Intent { act=com.google.android.play.core.integrityservice.BIND_INTEGRITY_SERVICE ... } not found`, followed by `E flutter: Unhandled Exception: App Check could not verify this app. Restart the app and retry.` at 06:16:11. That matches shot 16-chat, where the prompt is still in the composer after Send. The two auth paths also disagree: OvidCloudService treats App Check as best-effort and sends an empty header, while CloudRestClient fails hard.
- **Fix:** (1) Add `--dart-define=OVID_APPCHECK_DEBUG=true` for internal/QA builds and use `AndroidProvider.debug` there, with the debug token registered in the Firebase console. Never ship it in the Play profile; make release_flags_test assert that. (2) In `CloudHeaders.authorize`, map `AppCheckUnavailable` to a typed `CloudApiException(status: 403, code: 'app_check_unavailable')` so every caller already handles it. (3) Show a blocking, explained banner such as "This copy of Ovid could not be verified by Google Play. Install from Google Play." with Retry, instead of failing silently. (4) Create a single `CloudAppCheck` instance. There are three today: OvidCloudService, CloudHeaders and registerProductionAccountFeatures, each of which may call `activate`.
- **Verify:** Install the release APK on a google_apis emulator, sign in and send a message. Expect the explained banner and no unhandled exception in logcat. Install a QA build with the debug provider and expect a successful send.

### SH-002 (P0): Play purchases can never be verified. /billing/verify returns 404 at the edge, and the client then says "Nothing was charged"
- **Where:** lib/core/ovid_cloud_service.dart:512-513,1120-1125; lib/core/play_billing.dart:358-393; lib/ui/billing_screen.dart:116-117; edge /opt/ovid-gateway/caddy/Caddyfile (`@mint path /mint /healthz /upgrade`, `@usage /usage`, catch-all `respond "Not found" 404`).
- **Problem:** The client posts to `https://api.ovidsi.com/billing/verify`. That path is not routed at the edge. The flip that would route it (cloud/deploy/caddy-flips/3-billing.conf) is staged but not applied. The client maps 404 to `UpgradeResult.notAvailable`, so a user who has just paid in the Play sheet reads "Paid plans are not available yet. Nothing was charged." The purchase is never acknowledged, and Google refunds it after 3 days. Restore hits the same path.
- **Evidence:** `curl -X POST https://api.ovidsi.com/billing/verify` returns `404 Not found` (Caddy catch-all). The TS mint does serve `/billing/verify` (cloud/apps/mint/src/billing/routes.ts:83), but only on 8091, which the edge does not route. The live mint (8090, old stack) has no PLAY/BILLING env.
- **Fix:** Apply caddy flip 3 (`handle /billing/* → 127.0.0.1:8091`) before shipping paid plans. On the client, treat any non-2xx from verify *after* a `purchased` status as "Payment received, confirming with Ovid... we will retry automatically" instead of "Nothing was charged". Persist the unverified token and retry on resume. Reserve the `notAvailable` copy for failures before purchase.
- **Verify:** Run a Play test purchase with a license-tester account and a test card. Expect a 200 verdict, the tier applied and the purchase acknowledged. With the route removed, expect the "confirming" copy and no "Nothing was charged".

### SH-003 (P0, privacy): Sign-out and account switch never unregister the FCM token or reconnect push and the WebSocket. A signed-out device, or account B, keeps receiving account A's chat text in notifications
- **Where:** lib/main.dart:207-218 (`_maybeStartCloud` removes its listener after the first account, so it runs once per process); lib/core/cloud/push_service.dart:106-108 (`init` runs once and is guarded by `_initialized`); lib/core/firebase_service.dart:588-611 (`signOut` never calls DELETE /devices and never disconnects the WS); lib/core/cloud/cloud_rest.dart:494-500 (the client only POSTs /devices, no DELETE).
- **Problem:** The server binds a token to whichever uid registered it last (cloud/packages/db/src/deviceRepos.ts:15-38) and offers `DELETE /devices` (gateway routes/devices.ts:35), but the client never calls it. After sign-out, A's run-completion pushes keep arriving. Each body is `notificationSummary(message, {max:180})` (cloud/apps/worker/src/notify.ts:401), i.e. A's chat content, shown on the lock screen of a signed-out or shared device. After switching to B in the same process, B is never registered (no pushes for B), and A's pushes continue until the next cold start.
- **Fix:** On sign-out and on uid change (listen to `FirebaseService` for uid transitions, not one-shot): (1) call `DELETE /devices {token}` with A's still-valid ID token *before* `FirebaseAuth.signOut`. (2) Call `FirebaseMessaging.deleteToken()` and clear the notifications A has already shown. (3) Reset `PushService._initialized` so B re-registers once ready. Keep `_maybeStartCloud` subscribed and make it uid-aware.
- **Verify:** Sign in as A, start a long run, sign out before it finishes. Expect no notification, and `devices` has no row for the token. Sign in as B and expect a `devices` row with B's uid.

### SH-004 (P0, latent): `POST /account/login` with `Content-Type: application/json` and no body is rejected by the TS gateway. Every login would stick on "Confirming your account" after the account flip
- **Where:** lib/core/account_service.dart:72-74,126-138 (`acknowledgeLogin` → `_call('/login')` sends the JSON content type with `body: null`); server cloud/apps/gateway/src/routes/account.ts:119.
- **Problem:** Fastify 5 rejects an empty body that declares application/json with `400 FST_ERR_CTP_EMPTY_JSON_BODY`. The client maps 400 to "The account server is unavailable...", so admission fails and the user is stuck on `_AccountNotReadyScreen`. This is hidden today because the edge still sends `/account/*` to the Python account-dev service on 8080. It breaks the moment caddy flip 1-account.conf moves it to the gateway, if the build has `OVID_ACCOUNT_ENABLED=true`. The gateway tests use `inject` without a content type, so they do not catch it.
- **Evidence:** Reproduced with the gateway's own fastify 5.12.7: an inject with `content-type: application/json` and an empty body returns `400 {"code":"FST_ERR_CTP_EMPTY_JSON_BODY"...}`. Without the content type it returns 200.
- **Fix:** Client: send `body: '{}'` (or omit Content-Type) when `body == null`. Server: tolerate an empty JSON body on the account routes (scoped `addContentTypeParser`, as billing does), and add a test that injects `content-type: application/json` with no payload.
- **Verify:** Point a debug build at a staging gateway with the account routes, sign in, and expect admission. Also run `curl -X POST -H 'content-type: application/json' -H 'Authorization: Bearer …' https://staging/account/login` and expect 200.

### SH-005 (P0, product): No paid plan can be bought in production
- **Where:** lib/ui/billing_screen.dart:165-181 (`_mode`); lib/core/ovid_cloud_service.dart:1396 (`billingEnabled: j['billing_enabled'] == true`).
- **Problem:** The live `/usage` is served by the old mint (8090), which has no PLAY/billing configuration, so `billing_enabled` is never true. `ALLOW_TEST_UPGRADE=false`, and release builds hide the test path (`!kReleaseMode`). Every paid card therefore shows "Coming soon", and the $5/$25/$60 plans the owner expects are unpurchasable. Combined with SH-002, this is the whole billing goal. Mostly deployment, but it blocks the feature.
- **Fix:** Release checklist gate: move `/usage`, `/mint` and `/billing/*` to the TS mint (flips 3 and 5), configure Play service-account credentials and `OVID_PLAY_PRODUCTS`, create the Play subscriptions (`ovid_plus_monthly`/`ovid_pro_monthly`/`ovid_max_monthly`, or rename them, see SH-006), and confirm `billing_enabled:true` in `/usage`.
- **Verify:** Open Plans & Billing on a Play-installed build. Expect localised prices and Subscribe buttons.

---

## P1

### SH-006 (P1): Plan names, multipliers and copy contradict the server's plan table (Free/Starter $5/Pro $25/Max $60)
- **Where:** lib/ui/billing_screen.dart:60-82 (`Plus ×3 / Pro ×7 / Max ×15`); lib/ui/sidebar.dart:886-893 (`Plus · 3×`…); lib/ui/auth_screen.dart:368-376; lib/ui/usage_screen.dart:146-149 (raw `3X`/`7X` pill); lib/core/ovid_cloud_service.dart:1237-1242 (`ovidPlanMultipliers`); lib/core/play_billing.dart:18-22.
- **Problem:** The server's plan table (cloud/apps/mint/src/planMath.ts:202-205) is Free, then **Starter** $5 (mult 3), **Pro** $25 (mult **23**), **Max** $60 (mult **43**), with aliases 3x/7x/15x. The server also sends `plan_name` in `/usage` (usage.ts:527), but the client ignores it. Users see "Plus", "Pro ×7" and "Max ×15", which undersells the paid plans by 3x and uses the wrong name. The default server feature lines in billing/products.ts:27-49 ("About 7x the Free allowance") have the same mismatch, as does the Usage screen pill showing "7X". If admin creates or renames a plan in /admin (memory: all knobs in /admin), `storedTier` can return an id the client does not know, and Billing shows "Plan unavailable" / "Plan status unavailable".
- **Fix:** Make the server authoritative. Have `/usage` return `plans:[{tier,id,name,price_usd,mult,features}]` plus `plan_name`, and render names and multipliers from it, keeping a local fallback only for offline. Fix products.ts feature copy to read from planMath. Replace the raw tier pill in Usage with `plan_name`.
- **Verify:** Set Pro mult to 23 in /admin and open Billing, Sidebar, Account and Usage. Expect all four to say "Pro" and the same multiplier and name.

### SH-007 (P1): After sign-out (or deletion), pushed routes stay on top of the login screen, and deep links or notification taps can open app screens while signed out
- **Where:** lib/main.dart:400 (`home: LoginGate(child: OvidShell())`, so the gate only swaps the *home* route); lib/core/firebase_service.dart:588-611; lib/ui/app_router.dart:466-529; lib/main.dart:243-258,280-290.
- **Problem:** Sign-out happens from Settings → Account (a pushed route), the model picker, or the providers screen. LoginGate swaps the home widget, but Settings and Account stay on the navigator above it. The user sees a signed-out Account screen, then a Settings screen for a "guest", and only reaches the login screen after pressing back several times. Separately, `AppRouter.go(SettingsRoute|BrowserRoute|ScheduleRoute)` pushes onto the root navigator with no auth check, so a notification action (`/settings`) or an in-app link while signed out opens Settings or the Browser above the login screen.
- **Fix:** In LoginGate, when `isSignedIn` flips to false, run `appNavigatorKey.currentState?.popUntil((r) => r.isFirst)` post-frame. Better, put the gate *above* the Navigator via `MaterialApp.builder`. Make `AppRouter.go` refuse anything except `SharedChatRoute` unless `FirebaseService.I.accountReady`, and queue the route until it is.
- **Verify:** Go to Settings → Account → Sign out and expect the login screen immediately, with back exiting the app. While signed out, run `adb shell am start -W -a android.intent.action.VIEW -d https://ovidsi.com/settings` (after SH-020) or fire a test notification routed to `/settings`, and expect the login screen to stay.

### SH-008 (P1): The WebSocket stays authenticated as the previous account after a switch, so B's live streaming silently fails
- **Where:** lib/main.dart:207-228 (warm-up runs once); lib/ui/shell.dart:269-293 (only `connectIfNeeded` and a disconnect on `detached`); lib/core/state.dart:1561 (`CloudAgentFacade.resetAccountStateIfInstalled()` clears facade maps but not `WsMultiplexer`).
- **Problem:** The WS ticket is minted for A's uid. After an A → B switch in the same process, the socket stays connected as A. The gateway rejects B's subscribes (`meta.userId !== uid`, gateway ws.ts:689/724), so B sees no live tokens or run updates until a reconnect or restart. Any system subscription keeps delivering A's schedule events. (Suspected for the UI symptom; the server check is confirmed.)
- **Fix:** On uid change, `await WsMultiplexer.I.disconnect()`, clear its resume cursors (prefs), and reconnect once B is `accountReady`. Do the same for `BrowserStreamClient`.
- **Verify:** Sign in as A, sign out, sign in as B, send a message. Expect streaming tokens without restarting.

### SH-009 (P1): Mint and allowance failures (device unverified, 402 free limit, session expired) only show inside the model-picker sheet
- **Where:** lib/ui/login_gate.dart:136-148 (`ensureConnected` fire-and-forget); lib/ui/chat_screen.dart:2616,2880-2915 (the only renderer of `connectionFor`, besides providers_screen.dart:321).
- **Problem:** If the login mint fails, nothing tells the user. They type, send, and get a chat-level error at best (see SH-001). `MintStatus.freeLimitReached` ("Free plan limit reached. Upgrade") and `deviceUnverified` never reach a surface with an Upgrade or Fix action. The comment at login_gate.dart:138-139 still says failure "leaves the app usable with the user's own custom providers", which is untrue for the cloud architecture.
- **Fix:** Add a shell-level status strip (like `OfflineBanner`) driven by `OvidCloudService.connectionFor(AppState.I)`: deviceUnverified shows install-from-Play copy, freeLimitReached shows a "View plans" button to Billing, and sessionExpired shows Sign in again. Update the comment.
- **Verify:** Force the mint to 402 (admin reset-usage to cap, or staging) and launch. Expect the banner with View plans.

### SH-010 (P1): The history-import sheet appears on a fresh install with "0 chats · 0 messages"
- **Where:** lib/ui/login_gate.dart:665-680.
- **Problem:** The only skip condition is `plan.alreadyImported`. A brand-new user (nothing to import) is shown a full sheet titled "Import your chats" with an "Import my chats" button and "Ready to import 0 chats · 0 messages". It then stacks with the telemetry consent dialog (shell.dart:247), giving three first-run interruptions in a row.
- **Evidence:** shots/10.xml: `"Ready to import" "0 chats · 0 messages" "Skip for now" "Import my chats"`, immediately followed by shots/11 (telemetry dialog).
- **Fix:** `if (plan.alreadyImported || plan.sessions == 0) { mark skipped; return; }`. Sequence the consent dialog after the welcome and import steps instead of attaching it in `OvidShell.initState`.
- **Verify:** Clear data, sign in with a new account. Expect no import sheet and only one consent dialog.

### SH-011 (P1): The connectivity probe targets gstatic.com, not Ovid. It can disable Send when Ovid is reachable, and it misses real outages
- **Where:** lib/core/connection_service.dart:73-103,138-151; consumers: lib/ui/shell.dart:50-98 (banner) and the composer's Send gating.
- **Problem:** "Offline" means "www.gstatic.com/generate_204 did not answer within 4 s". Networks that block or slow Google endpoints (some enterprise networks and regions) show "You're offline — messages can't be sent" while api.ovidsi.com works. When the Ovid gateway is down but Google is up, the app shows online. While online there is no periodic probe and no OS connectivity listener, so a connection lost mid-session is not detected until resume or a drawer open.
- **Fix:** Probe `https://api.ovidsi.com/cloud/v1/health` (public, already exists), fall back to gstatic only to tell "Ovid down" from "no internet", and show different copy for each. Subscribe to `connectivity_plus` changes and let the WS state feed the status too. Never hard-disable Send on a single failed probe; queue to the outbox instead (it already exists).
- **Verify:** Block gstatic in the emulator (`adb shell` iptables, or a Charles map-remote) and expect Send to still work. Stop the gateway and expect "Ovid is unreachable".

### SH-012 (P1): Account deletion does not warn about, or handle, an active Play subscription
- **Where:** lib/ui/account_deletion_panel.dart:80-145.
- **Problem:** The confirm dialog never mentions that a Google Play subscription keeps billing after the Ovid account is deleted. Play policy expects apps to tell users how to cancel. The copy also says "Local workspaces ... are not erased", a leftover from the on-device sandbox era (there are no local workspaces now).
- **Fix:** When `PlayBillingService.I.ownedTier != null` or `usage.isPaid`, show "Your Google Play subscription is not cancelled automatically" with a "Manage in Google Play" button (`playSubscriptionCenterUri`) before Request deletion. Drop the local-workspaces sentence.
- **Verify:** With a test subscription, open Account → Delete and expect the subscription warning and link.

### SH-013 (P1): Play billing state survives an account switch, so B can see A's plan and "Manage subscription"
- **Where:** lib/core/play_billing.dart:139-158,202-238 (singleton; `_owned`, `_ownedTier`, `_expiresAt` and `_loading` are never reset); lib/ui/billing_screen.dart:268-292 (`playManaged`, `expiresAt`, falling back to `_billing.*`).
- **Problem:** After A (paid) signs out and B signs in, `ownedTier`, `expiresAt` and `ownedProductId` still describe A. BillingScreen falls back to them when `/usage` is slow or missing, showing "Renews on …" and "Manage subscription" for B. `ensureLoaded` runs `restorePurchases(accountId: A)` only once per process, so B's purchases are never re-read.
- **Fix:** Listen to the FirebaseService uid. On change, clear `_owned*`, `_expiresAt`, `_autoRenewing` and `_waiting`, reset `_loading`, and call `ensureLoaded()` for B.
- **Verify:** A buys a test plan, sign out, B signs in, open Billing with airplane mode on. Expect Free with no renewal line.

### SH-014 (P1): `buy()` can hang forever and block that plan's button for the rest of the process (suspected)
- **Where:** lib/core/play_billing.dart:261-289.
- **Problem:** The Completer in `_waiting[product.id]` only resolves when the purchase stream delivers that product. If Play never delivers (sheet killed, process restarted mid-flow, or `buyNonConsumable` returns true without a later stream event), the sheet spins with PopScope blocking back, and later taps on the same plan return the same pending future.
- **Fix:** Add a timeout (for example 10 minutes) that resolves `unknown` and removes the waiter, and let the sheet offer Cancel after about 30 s.
- **Verify:** Start a purchase, force-stop the Play Store from Settings while the sheet is open, return to Ovid. Expect the sheet to recover.

### SH-015 (P1): GitHub sign-in (and any social provider other than Google) never appears in release builds
- **Where:** lib/core/auth_providers.dart:15-33 (`OVID_AUTH_SOCIAL_PROVIDERS` define); .github/workflows/build.yml:208-209 (not passed).
- **Problem:** The owner's test plan includes "login (Google / phone / GitHub)", but the release build shows only Google and Phone (shots/01-launch.xml). `lib/ui/github_login_sheet.dart` is the Studio repo connector (device flow), not app login. Users who signed up with GitHub on another surface cannot sign in, and the "Existing account help" copy does not tell them why.
- **Fix:** If GitHub login is intended, add `--dart-define=OVID_AUTH_SOCIAL_PROVIDERS=github.com` to both release commands and add a release_flags_test assertion. Enable GitHub in the Firebase console with the correct callback. If it is not intended, update the test plan.
- **Verify:** Install the release build and expect "Continue with GitHub". It should complete Firebase `signInWithProvider` and land in the shell.

### SH-016 (P1): The "Usage" entry and Usage screen copy are leftovers or wrong
- **Where:** lib/ui/settings_screen.dart:76-82 (subtitle "Per-client spend · OvidAI, OpenCode, [CC], Z Code"); lib/ui/usage_screen.dart:86-87 ("Pull to refresh", but there is no RefreshIndicator), 169-174 (`'Resets ${usage.resetsAt!.toLocal()}'` prints a raw `2026-10-19 13:45:12.000`), 58-62 (the app-bar Refresh button reads `_store.loading` outside the AnimatedBuilder, so its enabled state goes stale).
- **Fix:** Subtitle should read "Remaining allowance · today's requests and tokens". Wrap the list in `RefreshIndicator(onRefresh: …)`. Format the reset time relatively ("Resets in 5 h 12 m", or "Resets Oct 19, 1:45 PM"). Move the actions into an AnimatedBuilder on `_store`. Add a "Change plan" button linking to Billing.
- **Verify:** Open Settings → Usage, pull down, and check the reset label and the subtitle.

### SH-017 (P1): Sidebar shows "No sessions yet" while the first cloud sync is running or offline, and pull-to-refresh is unavailable when the list is empty
- **Where:** lib/ui/sidebar.dart:159-168,380-394,489-494.
- **Problem:** After login or reinstall, `refreshSessions` runs in the background while the list renders "No sessions yet", a false empty state for users who have cloud chats. The empty state is a plain `Padding`, not a scrollable, so the `RefreshIndicator` (which wraps only the populated list) cannot be pulled. Offline, it says "No sessions yet" instead of "Offline — showing cached chats". A failed refresh is swallowed silently.
- **Evidence:** shots/17-sidebar.xml shows `"No sessions yet"`.
- **Fix:** Expose `CloudSessionStore.syncing`, `offline` and `lastError`. Show a skeleton or spinner while syncing and an inline "Couldn't load chats · Retry" on error. Wrap the empty state in a `ListView` with `AlwaysScrollableScrollPhysics` inside the RefreshIndicator.
- **Verify:** Reinstall with an account that has server chats, open the drawer immediately, and expect a loading state rather than an empty one. In airplane mode, expect offline copy.

### SH-018 (P1): `signOut()` silently does nothing while an auth operation is in flight
- **Where:** lib/core/firebase_service.dart:588-590 (`if (_identity.busy) return;`); callers auth_screen.dart:113-129, login_gate.dart:528-531.
- **Problem:** If a Google or phone credential submission is pending (including a hung native picker), Sign out returns immediately. AuthScreen shows "Signing out…" then reverts, with no error. On the "Confirming your account" screen, Sign out appears dead.
- **Fix:** Return a result (or throw `AccountException('Finishing sign-in… try again in a moment')`) and show it. Also give `AuthIdentity.social` a timeout so `busy` cannot stick.
- **Verify:** Start a phone verification, then tap Sign out from the account-not-ready screen. Expect visible feedback.

### SH-019 (P1, suspected): Cold-start App Links and early notification taps can show "Chat not found" for chats that exist
- **Where:** lib/main.dart:280-319; lib/ui/app_router.dart:489-523,541-560.
- **Problem:** `getInitialLink` is handled immediately, before login and account hydration. `ChatRoute` waits at most 5 s for `CloudSessionStore.refreshSessions` (which needs an ID token), then shows "Chat not found — it may have been deleted." `ScheduleRoute` has no reconcile at all and fails straight to not-found if sessions have not hydrated yet.
- **Fix:** Queue non-share routes in a pending-route slot and drain it when `FirebaseService.accountReady && AppState.sessionAccountReady` first becomes true. Give ScheduleRoute the same reconcile path as ChatRoute.
- **Verify:** Kill the app, tap a run-complete notification for an existing chat, and expect that chat to open.

### SH-020 (P1): App Links only cover `/s/`. The `/c/`, `/schedule/`, `/settings` and `/browser` link support in AppRouter is dead, and assetlinks.json lists only the upload key
- **Where:** android/app/src/main/AndroidManifest.xml:49-54 (`pathPrefix="/s/"` only); lib/ui/app_router.dart:375-444; https://ovidsi.com/.well-known/assetlinks.json (one fingerprint, `96:D7:6A:…`, which matches the sideload APK signer).
- **Problem:** The router docs promise `https://ovidsi.com/c/<id>` links, but the OS never routes them to the app. For a Play build re-signed with Play App Signing, the Play signing certificate is not in assetlinks, so even `/s/` share links will open in the browser instead of the app (suspected, depends on the Play App Signing setup).
- **Fix:** Add the Play app-signing SHA-256 to assetlinks.json. Either add `/c/` and `/schedule/` path prefixes (and make the server serve a fallback page) or delete the dead parsing and docs.
- **Verify:** `adb shell pm get-app-links com.dhanuk.ovidai` should show `verified` for ovidsi.com on the Play build, and `am start -d https://ovidsi.com/s/<token>` should open the app.

### SH-021 (P1): The Plans screen has no prices or plan facts when Play is unavailable, and the pending-payment outcome hides retry
- **Where:** lib/ui/billing_screen.dart:183-189 (`_priceFor` returns null unless in Play mode), 136-143.
- **Problem:** Outside `_PurchaseMode.play`, users see no price at all, although the server has `price_usd` (5/25/60). With "Coming soon" everywhere they cannot tell what the plans cost. `pending` is classed as terminal (Close only), which is right. `notAvailable` after a real purchase is wrong (see SH-002).
- **Fix:** Show server `price_usd` as "from $5 / month" (labelled indicative, with Play's localised price taking over when loaded).
- **Verify:** With billing disabled, open Billing and expect indicative prices.

---

## P2

### SH-022 (P2): Raw ISO timestamps across account and deletion UI
- lib/ui/login_gate.dart:450-454 and 857-861 (`2026-10-20\n06:00:00.000 UTC`), lib/ui/auth_screen.dart:417-419, lib/ui/account_deletion_panel.dart:251. The countdown at 186-195 never ticks (no Timer). **Fix:** use one `formatDeadline()` (local time, "Oct 20, 11:30 AM (in 23 h)") and a 1-minute periodic rebuild. **Verify:** request deletion and watch the countdown change.

### SH-023 (P2): Raw exception text reaches users
- firebase_service.dart:577 (`'Could not update name: $e'`), auth_screen.dart:125 (`'Could not sign out: $error'`), account_deletion_panel.dart:69,141,165 (`e.toString()`), account_session.dart:221. **Fix:** route through `friendlyError()` / `UserError.from` (user_error.dart), with detail behind a disclosure. **Verify:** in airplane mode edit the name and expect "You appear to be offline", with no `FirebaseException`/`PlatformException` text.

### SH-024 (P2): Phone-only users see "Signed in / Signed in" or "You"
- sidebar.dart:820-828, settings_screen.dart:351-364. **Fix:** fallback order displayName → email → phoneNumber → "Ovid user". **Verify:** sign in with phone only and open the drawer and Settings.

### SH-025 (P2): Sidebar row density and accessibility
- sidebar.dart:1105-1123: every row has an always-visible red Delete icon plus a "…" button (two 40dp targets in a 288dp drawer), so titles truncate early and a destructive action sits next to Session actions. The subtitle shows the raw model id (`summary.model`, e.g. `auto`). **Fix:** keep only "…" (Rename / Share / Delete) on touch, show Delete on hover for desktop, and show a friendly model label or relative time. **Verify:** at font scale 1.3 on a 360dp-wide device, titles should show at least 20 characters.

### SH-026 (P2): Session rename reverts silently when the PATCH fails
- lib/core/state.dart:4462-4477 → cloud_agent_facade.dart:805-825 (errors only go to `Diag.swallow`). The next `refreshSessions` overwrites the local title. **Fix:** surface "Couldn't rename, retry" and keep a pending-title patch in the outbox. **Verify:** rename in airplane mode, reconnect, pull to refresh. Expect the title to persist, or an error.

### SH-027 (P2): Delete has both a confirm dialog and a 5 s undo, and is lost if the process dies inside the undo window (suspected)
- lib/ui/session_actions.dart:148-180. **Fix:** pick one. Prefer undo only, and persist the pending deletion so it commits on next launch. **Verify:** delete, force-stop within 5 s, relaunch. Expect consistent state.

### SH-028 (P2): Certificate pinning cannot work as documented for api.ovidsi.com
- lib/core/cert_pinning.dart:1-60,142-155. Pinning is off and the pins are empty, so nothing is pinned. api.ovidsi.com resolves to Cloudflare (104.21.25.51, 172.67.222.182) and presents a Let's Encrypt YE2 leaf (notAfter Jan 6 2027) that the edge rotates. Leaf-SPKI pinning as instructed in the TODO would brick the app at the next rotation, and the doc's own caveat (4) applies. **Fix:** decide on no pinning (rely on App Check plus TLS), or move to a Cloudflare custom certificate with an owned key and pin that key plus a backup. Remove the `api.ovidsi.com` entry otherwise. **Verify:** n/a until the decision is made. Run `openssl s_client` and compare the SPKI after each renewal.

### SH-029 (P2): Leftovers from the on-device architecture (dead or misleading)
- lib/core/state.dart:1803-1833,1845-1867 (`skill.mount` stage that is a no-op, an empty `if (root != null && !root.isSubagent) {}` block, `_runResumeReconnect` that does nothing, `startupSafeToReconnect`); state.dart:1387-1415 (collab turn runner that always throws a read-only notice); lib/core/reset_coordinator.dart:8-33 (`cookies` "default WebView cookie jar", `exports`, `skills`, SSH keys: stores that no longer exist on device); lib/core/secure_store.dart:3-5 (SSH keys and passwords); lib/core/distribution.dart:299-331 (constant `cloud*` gates kept only "so the surface stays greppable"); main.dart:120-153 comments; login_gate.dart:32-35,138-139 ("custom providers"); account_deletion_panel.dart:127 ("Local workspaces"); chat hero copy "the agent runs tools right here" (shots/12, chat area). **Fix:** delete the dead stages and stores and inline the constants. Update copy to "runs in Ovid Cloud". **Verify:** `flutter analyze` and the test suite stay green.

### SH-030 (P2): `restorationScopeId: 'ovid'` restores nothing
- main.dart:387-389. All pushes are `MaterialPageRoute` through `Navigator.push`, not `restorablePush`, and no screens use `RestorationMixin`. After process death the user returns to the root chat, which is fine, but the comment over-promises. **Fix:** remove the comment, or adopt `restorablePushNamed` for Settings, Billing and Usage. **Verify:** enable "Don't keep activities", open Billing, background, return.

### SH-031 (P2): Splash, welcome and consent stack on first run, and the welcome copy promises features that are not there
- login_gate.dart:617-638,809-815 ("Explore your available models, create agents, and browse the web."), shell.dart:100-210. Welcome (5 s banner), then the import sheet (SH-010), then the consent dialog appear back-to-back. **Fix:** one onboarding sequence that handles consent first (Play policy), then the optional import, then a brief welcome. **Verify:** fresh install, count the interruptions.

### SH-032 (P2): The Google button uses a generic icon
- auth_methods.dart:66-79 (`Icons.account_circle` for Google). Google branding guidelines require the official "G" mark on "Continue with Google". **Fix:** ship the official asset. **Verify:** visual check.

### SH-033 (P2): The account-not-ready screen has no Sign out until 15 s have passed
- login_gate.dart:377,456,499-531. The screen offers no action for 15 s, even when the user just wants to switch accounts. **Fix:** always show a low-emphasis "Use a different account" link. **Verify:** sign in under a slow network and expect the link immediately.

### SH-034 (P2): The on-device LiteLLM virtual key is still minted and stored, and the edge exposes LiteLLM `/v1/*` publicly
- ovid_cloud_service.dart:498,614-745,840-934. The device stores a per-user LiteLLM key, used only for the model catalog and images. The edge (`@api path /v1/*` → LiteLLM :4000) accepts that key directly, bypassing the gateway's run accounting and moderation. Spend is bounded by the per-user key budget, but this is a leftover of the client-side execution design. **Fix (plan):** serve the catalog and images through the gateway with ID-token auth, stop minting keys to the device, and restrict `/v1/chat/*` at the edge. **Verify:** after the change, `curl https://api.ovidsi.com/v1/chat/completions -H "Authorization: Bearer <device key>"` returns 404.

### SH-035 (P2): Billing UI details
- billing_screen.dart:212-217: `toolbarHeight` hack based on `scale(20) > 30`. 235-247: the AnimatedBuilder rebuilds the whole list on every FirebaseService notification. `_UsageBar` turns red below 10% with no text explaining what happens at 0. Restore shows only when Play is available, so a user on a new phone with billing loading cannot restore. **Fix:** use the standard AppBar with a `Flexible` title, add "When you run out, chats pause until <reset> or you upgrade", and always show Restore (disabled with a reason). **Verify:** font scale 2.0 on a small device, visual.

---

## Verified OK (no finding)
- Mint (`/mint`) and usage (`/usage`) routing exists at the edge. The client handles 401→403 with a forced token refresh and one retry, and 402 maps to `freeLimitReached`.
- `/account/*` paths match the server (gateway routes/account.ts). The deletion request id is stable across retries. Restore requires explicit consent `{consent:true}` (matches the server).
- `Distribution.play` / `OVID_PLAY_BUILD`, `OVID_RELEASE_FLAGS_CHECK` and `OVID_ACCOUNT_ENABLED` are threaded correctly in CI. `OVID_E2E_SKIP_LOGIN` compiles out of release (`kDebugMode &&`).
- No obfuscation-sensitive `runtimeType.toString()` or enum-name parsing in scope. `state.dart:2925` uses `runtimeType` only for hashing. Enum `.name` values sent to the server are preserved under `--obfuscate`.
- 402 `daily_limit_reached` is mapped in user_error.dart:98 (the chat-side handling belongs to another area).
- The secure storage configuration (EncryptedSharedPreferences, AES-GCM, OAEP, `resetOnError:false`) is sound.
