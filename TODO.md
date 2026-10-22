# Ovid Si rebuild — living TODO

**Updated:** 2026-10-22 (minimal-UI pass across every screen)
**Branch:** `feat/ovid-si-rebuild`
**Overall production readiness:** ~88 % (unchanged — the server/cloud tracks did
not move in this pass)
**UI rebuild (design system + 50 screens + shell wiring):** ~98 % — every screen
follows `docs/design/MINIMAL_UI_CONTRACT.md` and every gate below is green

Verified in this pass (2026-10-22, 05:14):

| Gate | Result |
|---|---|
| `flutter analyze` | **No issues found!** (27.3 s) |
| `flutter test` (full suite) | **4,599 passed, 0 failed, 2 skipped** (3:59) |
| 320 dp / 200 % text ratchet (`test/v2/a11y_ratchet_test.dart`) | **100 passed** (50 screens × light/dark) |
| `flutter test test/v2/navigation` | **102 passed** |
| `flutter test test/design` | **64 passed** |
| `flutter test test/v2/semantics_audit_test.dart` | **113 passed** (empty known-gaps map) |
| `flutter test test/v2/chat/live_chat_golden_test.dart` | **3 passed** |

Not run in this pass: `./gradlew :app:testDebugUnitTest`, `pytest server`, the
cloud suites, and the RevenueCat/Play consoles. The numbers that used to be
quoted here (4324 Flutter tests, 41 host tests, 1156 server tests) were from
2026-10-21 and are **not** re-asserted.

---

## Test status (read this before claiming anything works)

`flutter test` is **green**: 4,599 passed, 2 skipped, 0 failed, in 3 min 59 s.
`flutter analyze` is clean.

Two caveats, so nobody over-reads that:

- The tree is shared. Earlier in this pass the text-budget word ceiling and the
  Language & goal enabled-Continue semantics were both red; they were fixed
  during the pass by the owning work, and both are green as of the run above.
  Re-run before quoting these numbers in a release note.
- The suite is not the product. `test/v2/no_dead_controls_test.dart` and the
  header/responsive/semantics ratchets prove the *contract*, not that a service
  behind a control exists. The P1 list below is where the missing services are
  named.

---

## Track status

| Track | Covers | Done | State |
|---|---|---:|---|
| 0 | Tokens, theme, motion, components | 100 % | done; `OScreen`/`OContent`/`OBreakpoints` added |
| 5 | 50 v2 screens + gallery + shell | 98 % | minimal contract applied; all gates green |
| 1 | Isolation, memory, runtime | 88 % | engine + acceptance coverage; live multi-tenant soak pending |
| 2 | Gateway, plans, free caps | 90 % | unchanged this pass |
| 3 | Studio, browser, subagents | 92 % | browser is now live-wired; Studio diff/commit still has no client |
| 4 | Collaboration | 86 % | unchanged this pass |
| 6 | Billing, usage, account | 88 % | unchanged this pass |
| 7 | Security + launch | 80 % | unchanged this pass |
| 8 | Product completeness | 95 % | unchanged this pass |

---

## Landed in this pass (minimal UI)

### Contract
- [x] `docs/design/MINIMAL_UI_CONTRACT.md` written, with a "what changed in this
      pass" section recording the concrete decisions
- [x] One header per screen, one title line, ≤ 3 words, no repeated body heading
- [x] Text budgets enforced by `test/v2/text_budget_test.dart` (0 over-budget
      strings, banned-phrase ban, total-word ratchet)
- [x] Three responsive bands in one place (`OBreakpoints`): drawer + bottom bar
      below 600 dp, 280 dp rail 600–899, 300 dp rail 900+
- [x] Content caps ∞ / 640 / 720, with Browser at 1100 dp from 900 dp
- [x] Composer reduced to one row (`+` → permission → field → mic → send), shared
      by the home and live composers; the run status moved into the field hint
- [x] A control with no backing service is removed rather than disabled

### Screens and shell
- [x] All 50 registry entries build; 7 are sheets
- [x] Bottom navigation below 600 dp, fixed rail above it — one navigation per
      band, never two (`test/v2/app/shell_responsive_test.dart`)
- [x] Browser is live-wired: `BrowserLivePage` feeds real tabs, url, frame and
      take-control state (was a routed-empty placeholder)
- [x] Live preview can render a real frame (`V2LivePreviewData.frame`)
- [x] Studio workspace uses the searchable file tree and the line-numbered code
      viewer; Changes uses the commit sheet; Storage uses the five-way breakdown;
      Schedules uses the run timeline; Collab uses the turn banner
- [x] Every component under `lib/ui/v2/` that the parity review listed as
      unimported is now imported by a screen or route
- [x] The standalone search screen is gone; search is inline in the drawer
- [x] Zero screen-local `_Tag/_Pill/_Badge/_Card/_Section/_Header/_Chip/_Row`
      classes (`test/design/no_local_primitives_test.dart`, empty allowlist)
- [x] Structural golden for live chat (`test/v2/chat/live_chat_golden_test.dart`):
      one canonical fixture, regions asserted in visual order, composer asserted
      as one row. The repo keeps no PNG goldens, so the composition is the
      golden.
- [x] No decorative gradient and no `OShadow.glow` anywhere in `lib/ui/v2`
- [x] Paywall currency choice persists; the notification permission banner reads
      the real Android state; account-health rows with no service are hidden

### Registry
- [x] `docs/audit/SCREEN_INVENTORY.md` regenerated from the registry: 50 screens
      in 10 groups, ids/titles/summaries verbatim; gallery noted as 87 entries
      (49 of these + 38 component previews, `account` native-only)

---

## Remaining P0

Carried over from 2026-10-21 and **not re-verified in this pass** — do not quote
these as done or not-done without running the corresponding check.

- [ ] **v2 has no in-app Report/Block action.** `reportAiMessage` is wired only
      in the legacy v1 `ChatScreen` (`lib/ui/chat_screen.dart:6114`) and the
      legacy Collab/share screens; the default `V2AppShell` message menu is
      Copy/Branch/Regenerate (`lib/ui/v2/chat/live_chat_page.dart`), and the v2
      Collab pages have no Report action (owner Remove and Leave exist). Play's
      Generative-AI and UGC policies require in-app reporting — release blocker.
- [ ] RevenueCat credentials validation — waiting on Google Play permission propagation
- [ ] Play subscriptions — locked until Google reviews the first release
- [ ] Live 50-user collaboration soak (unit + PG tests pass; no live soak yet)
- [ ] Raise or remove the legacy free USD allowance (`free_daily_usd = 0.15`) so the 50M token cap is the real gate
- [ ] Register the Studio git job in BullMQ/gateway and pass the sandbox `logDir`
- [ ] Update worker `runProcessor.test.ts` for the new JSON subagent result
- [ ] Gateway schema: expose browser `fps`/`headless` additive fields
- [ ] Apply collaboration `schema_extensions.sql` in PG deployments; fix account bootstrap `max_uses 1..9`
- [ ] Run the IP-hop guard with a real GeoIP resolver + Cloudflare headers; set `IP_HOP_DATABASE_PATH`
- [ ] Live M1 alert delivery test (email/Slack) and kill-switch drill

## Remaining P1

1. [ ] **Live preview has no producer.** `V2LivePreviewData.frame` exists and
   the page renders it, but `V2StudioRoutes.livePreviewDataFor` always returns
   `V2PreviewStatus.empty` with no url, frame or expiry, so the screen never
   leaves its waiting state.
2. [ ] **Studio Changes has no diff or commit client.** `changesDataFor`
   always returns `V2ChangesStatus.empty` and `openChanges` passes no
   `onCommit`, so the commit sheet can be opened but never commits.
3. [ ] **Studio workspace counts are always zero.** `changedCount` and
   `syncCount` stay 0 because the app has no git-status source; the dock is
   therefore always empty even inside a live workspace.
4. [ ] **Response wait**: the limit itself persists (`AppState.responseTimeoutSec`,
   clamped 30–600 s, read by the cloud facade's stall window), but there is no
   auto-extend and no notify-at-limit field or watchdog consumer.
5. [ ] **Account health** has no device-review or 2FA service. The rows are now
   *hidden* rather than disabled (contract-compliant), which means the feature is
   absent from the product, not just from the UI.
6. [ ] **Connector tool manifest.** `V2ConnectorDetailData.tools` is empty for
   every catalog row (`v2ConnectorDetailForRow` passes none), so per-tool
   permissions cannot be listed until an MCP `tools/list` or a provider scope map
   exists.
7. [x] **Yearly billing period.** `V2PlanProducts.yearly` names
   `ovid_*_yearly` products, and `buyPlan`/`RevenueCatBilling.buy` now pass the
   period through; `kOvidPlayProductIds` has a distinct id per (tier, period).
   The remaining gap is console-only: the yearly SKUs do not exist in Play
   (D2), and the server map needs the yearly ids (`REVENUECAT_SETUP.md` §5).
8. [ ] **Live chat artifact tile** has no inline thumbnail, no Preview button
   and no Copy; it opens the artifact detail and offers Download.
9. [x] **Sign-in dead email form removed.** The email/password field,
   "Forgot password" and "Create account" are gone, along with the unused
   Apple hook (`onApple`). The step now offers exactly Google (filled primary)
   and phone (outlined), and `_submitEmail`/`_showEmailUnavailable` were
   deleted from `v2_onboarding_gate.dart`. Registry summaries and
   `docs/audit/SCREEN_INVENTORY.md` now match the screen.

## Remaining P2

- [ ] ARB extraction — 100 `TODO(l10n)` markers across `lib/ui/v2`
- [ ] Manual TalkBack walkthrough per screen (the automated semantics audit is
      green with an empty gap map; nobody has listened to it yet)
- [ ] Cold-start + first-token traces; crash-free/ANR dashboards
- [ ] `dart format lib/ui/v2` — 40 of 132 files differ from the formatter
- [x] `docs/play/DATA-SAFETY.md` re-verified 2026-10-22: 24-hour grace,
      `Personal info → Name: Yes`, Phone number, Photos and Web browsing
      history are all present and match the code.
- [ ] Design-defect leftovers from `docs/design/stitch/PARITY_REVIEW.md`:
      `Colors.red` in `v2_settings_actions.dart`, `OType.display` on the usage
      hero, 12 radius literals, ~18 spacing literals, one `fontSize: 13`
- [ ] Delete `test/v2/sw_probe_test.dart` — a debug probe that only `print`s
      (the analyzer stays clean because it is `// ignore`d)
- [ ] Parity gaps that need a product decision, not code: projects sort/status
      chips, memory accuracy card, schedules' total + CTA card, run stat tiles
      + upcoming queue, collab raise-priority, notification/avatar entry point
      in the top bars

---

## Play + RevenueCat setup state (2026-10-21, unchanged)

Done in the consoles:
- Play Console signed in as `aasheeshkatheriya@gmail.com` (Dhanuk Softwares, account 4722370385057181718)
- Ovid Si exists as `com.dhanuk.ovidai` (Draft, app id 4973478968349167758)
- Google Cloud project `ovid-ai`: service account `revenuecat-play@ovid-ai.iam.gserviceaccount.com` created, JSON key issued
- Google Play Android Developer API enabled on `ovid-ai`
- Play Console: service account added with *View financial data*, *Manage orders and subscriptions*, *View app information*
- RevenueCat project `Ovid Si` (`afe58e73`), Play Store app `app3f89cc64b6`; the public Play SDK key is **not** embedded — inject it with `--dart-define=OVID_REVENUECAT_GOOGLE_KEY=...` (a release without it falls back to server-verified Play Billing)
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
