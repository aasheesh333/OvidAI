# Ovid Si rebuild — living TODO

**Updated:** 2026-10-21 (28-agent audit wave landed)
**Branch:** `feat/ovid-si-rebuild`
**Overall production readiness:** ~88 %
**UI rebuild (design system + 51 screens + shell wiring):** ~99 %

Verified now:
- `flutter analyze` → **No issues found**
- `flutter test` → **4324 passed, 0 failed** (2 skipped)
- Android host tests (`./gradlew :app:testDebugUnitTest`) → **41 passed**
- `python3 -m pytest server -q` → **1156 passed, 138 skipped**
- Cloud: gateway **450**, agent-core **767**, browser **320**, sandbox **372**, worker **216**, mint **296**
- 320 dp / 200 % text ratchet → **102 passed** (51 screens × light/dark)

---

## Track status

| Track | Covers | Done | State |
|---|---|---:|---|
| 0 | Tokens, theme, motion, components | 100 % | done |
| 5 | 51 v2 screens + gallery + shell | 99 % | audited, wired, ratcheted; inline sidebar search replaces the search screen |
| 1 | Isolation, memory, runtime | 88 % | engine + acceptance coverage; live multi-tenant soak pending |
| 2 | Gateway, plans, free caps | 90 % | 50M/24h + 1.5B/30d + M1 alert delivery + admin kill switch landed |
| 3 | Studio, browser, subagents | 92 % | credential helper, queue wiring, sandbox logs, fps/headless, 300-token JSON |
| 4 | Collaboration | 86 % | 50 cap, turn lock, creator storage, PG migrations + deployment test |
| 6 | Billing, usage, account | 88 % | Play Billing + RevenueCat (Test Store demo live) |
| 7 | Security + launch | 80 % | IP-hop GeoIP/PG/fail-closed, M1 runbook, kill-switch drill documented |
| 8 | Product completeness | 95 % | @mentions, attachments, voice + persisted language, app lock, permissions banner |

---

## Landed in this wave

### App
- [x] Onboarding gate: splash → welcome → language/goal → sign-in → paywall → app, mounted behind `OVID_UI_V2`
- [x] Email sign-in tells the truth ("not available yet"); Google + phone wired
- [x] Paywall purchase callback → Play Billing tier mapping (`go/plus/pro` → `3x/7x/15x`)
- [x] App lock: hashed PIN (salted SHA-256, secure storage), 2 min timeout, 5-attempt cooldown, biometrics hook, settings page
- [x] Composer: `@` session/project mentions, attachments (max 5, 8 MB), voice in Hindi/Hinglish/Punjabi/Tamil
- [x] `onSubmit` carries text + attachments + session/project refs into `runTask`
- [x] Chat menu: actions, run details, Studio, share
- [x] Shared memory page with scopes, retention and "forget"
- [x] Notification quiet hours (midnight wrap) + per-channel sound
- [x] Project rename/delete with confirmation
- [x] Share link revoke
- [x] Gallery separated behind `OVID_UI_GALLERY`
- [x] Route builders: trajectory, subagent, collab live/members, Studio workspace/branch/changes/preview
- [x] Inline sidebar search over sessions + projects; the standalone search screen is gone
- [x] Persistent bottom nav (`lib/ui/v2/app/bottom_nav.dart`)
- [x] Gallery: interactive Auto/manual picker (Free/Go vs Plus/Pro) and a chat variant that names the answering model
- [x] Sheet previews get a real height bound so list rows render instead of collapsing

### Server
- [x] Free caps: 50M tokens/24 h + 1.5B/30 d, hard ceilings, no pool, typed 429 with reset time
- [x] M1: $0.50/user/day alert once, global kill switch (`OVID_PAID_MODELS_KILL_SWITCH`)
- [x] Collab: 50-member cap (race-safe), single-sender turn lock, creator-paid storage ledger
- [x] IP-hop: impossible-travel + country-burst detection, session block, one email per event, admin unblock

### Cloud
- [x] Subagent: 50/root cap, no nesting, append-only log, strict 300-token JSON, 8 h timeout
- [x] Studio: ephemeral `GIT_ASKPASS` helper, token never in `.git/config`/argv/logs, sync + stash switch
- [x] Browser: agent-only tabs, 3–5 fps newest-frame-wins, 45 s → headless, human-like input

---

## Remaining P0

- [x] Release-signed AAB built and published to **internal testing** (`1 (1.0.0)`, minSdk 24)
- [x] Testers added (4 emails in the "Ovid internal" list)
- [ ] RevenueCat credentials validation — waiting on Google Play permission propagation
- [ ] Play subscriptions — locked until Google reviews the first release
- [x] RevenueCat Test Store: products, entitlements, default offering, demo paywall build
- [ ] Live 50-user collaboration soak (unit + PG tests pass; no live soak yet)
- [ ] Raise or remove the legacy free USD allowance (`free_daily_usd = 0.15`) so the 50M token cap is the real gate
- [ ] Register the Studio git job in BullMQ/gateway and pass the sandbox `logDir`
- [ ] Update worker `runProcessor.test.ts` for the new JSON subagent result
- [ ] Gateway schema: expose browser `fps`/`headless` additive fields
- [ ] Apply collaboration `schema_extensions.sql` in PG deployments; fix account bootstrap `max_uses 1..9`
- [ ] Run the IP-hop guard with a real GeoIP resolver + Cloudflare headers; set `IP_HOP_DATABASE_PATH`
- [ ] Live M1 alert delivery test (email/Slack) and kill-switch drill

## Remaining P1

- [ ] Schedules screen: `v2_work_routes.dart` still passes null for create/toggle/run-now, so the list is read-only (`V2SchedulesFlow.openSchedules` exists and is unused there)
- [ ] Collab live/members still have no entry point from the shell (`V2CollabRoutes.openLive`/`openMembers` exist)
- [ ] Live preview has no app-side client: `livePreviewDataFor` supplies no frame, URL or expiry, so the screen stays in its honest waiting state
- [ ] Studio changes/commit: no app-side diff or commit client, so "Commit & push" is disabled
- [ ] `_responseWait` auto-extend / notify-at-limit have no persisted field in `AppState` and no watchdog consumer
- [ ] Account health device/2FA actions are null (no device or 2FA service)
- [ ] Connector catalog rows carry no tool manifest, so per-tool permissions stay empty until an MCP `tools/list` or provider scope map exists
- [ ] Yearly billing: `kOvidPlayProducts` has monthly base plans only, so a yearly selection still charges monthly
- [ ] `paywall_page` currency toggle is view-only (no persistence, no billing effect)
- [ ] Notification permission banner wired to the Android state

## Remaining P2

- [ ] ARB extraction (every screen has `TODO(l10n)`)
- [ ] Full TalkBack walkthrough per screen
- [ ] Cold-start + first-token traces; crash-free/ANR dashboards
- [ ] `dart format lib/ui/v2`
- [ ] Remove local `OPill`/`_Tag` workarounds now that the shared pill is fixed
- [ ] `docs/play/DATA-SAFETY.md` still says a 7-day deletion grace (code is 24 h) and "Name: No"

---

## Play + RevenueCat setup state (2026-10-21)

Done in the consoles:
- Play Console signed in as `aasheeshkatheriya@gmail.com` (Dhanuk Softwares, account 4722370385057181718)
- Ovid Si exists as `com.dhanuk.ovidai` (Draft, app id 4973478968349167758)
- Google Cloud project `ovid-ai`: service account `revenuecat-play@ovid-ai.iam.gserviceaccount.com` created, JSON key issued
- Google Play Android Developer API enabled on `ovid-ai`
- Play Console: service account added with *View financial data*, *Manage orders and subscriptions*, *View app information*
- RevenueCat project `Ovid Si` (`afe58e73`), Play Store app `app3f89cc64b6`, public SDK key embedded
- RevenueCat entitlements created: `go`, `plus`, `pro`
- Internal testing release `2 (1.0.0)` published and **Active**; testers list "Ovid internal" (4 emails)
- Version bumped to `1.0.0+3` for the next internal upload (AAB not uploaded yet)
- **Production track is empty — the app is NOT live to the public**
- Release AAB built with the upload key (`android/keystore.properties`, gitignored)
- minSdk raised 23 → 24 (Play automatic protection requirement)
- Full setup runbook: `docs/play/REVENUECAT_SETUP.md`

Blocked on the owner:
- Release keystore password + alias + cert SHA-256 (needed for a signed AAB)
- After the first internal-testing upload: create Play subscriptions `ovid_plus_monthly`, `ovid_pro_monthly`, `ovid_max_monthly`, then add them in RevenueCat and attach to entitlements

## Verify

```bash
export PATH=/root/flutter/bin:$PATH
tool/verify_v2.sh          # analyze + design + v2 + ratchet + full suite

# UI v2 app
flutter run --dart-define=OVID_UI_V2=true
# Screen gallery
flutter run --dart-define=OVID_UI_GALLERY=true

# Backend
python3 -m pytest server -q
```
