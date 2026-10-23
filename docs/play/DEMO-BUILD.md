# Internal test build (demo billing)

Play monetization is not approved yet, so a store build cannot sell a plan.
This build lets the whole product be exercised — every paid surface included —
without charging anyone and without being uploadable to Play.

## The command

```bash
export PATH=/root/flutter/bin:$PATH
cd /root/.local/share/opencode/worktree/d5f2a3/ovid-si-rebuild

flutter build appbundle --release \
  --dart-define=OVID_BILLING_DEMO=true \
  --dart-define=OVID_PLAY_BUILD=true
```

For a directly installable APK (no Play overlay needed):

```bash
flutter build apk --release --dart-define=OVID_BILLING_DEMO=true
```

`OVID_PLAY_BUILD=true` adds the Play manifest overlay, so an AAB for the
**internal testing track** should carry it. It is not `OVID_PRODUCTION` — that
is the flag that forbids the demo, and only the production workflow path sets
it.

Output:
- `build/app/outputs/bundle/release/app-release.aab`
- `build/app/outputs/flutter-apk/app-release.apk`

## What the flag does

| | |
|---|---|
| Plan selection | Unlocks locally. No store call, no charge. |
| Plan name | Shows `Ovid Plus (demo)` — the marker is appended by `ovidPlanName`, so no screen can show it as real. |
| Paywall | Shows "Demo: plans unlock without a charge." |
| Plan & billing page | Same note, above the cards. |
| Everything else | Real: the tier really is set, so manual models, caps and every gated surface behave as they will for a payer. |

## Why it cannot reach production

`Distribution.billingDemo` is `OVID_BILLING_DEMO && !OVID_PRODUCTION`.

The guard is keyed on **production**, not on the Play channel, because the
internal testing track is also a Play artifact — gating on `play` would have
made the demo untestable exactly where it is used.

Two independent locks:

1. **Runtime** — `Distribution.billingDemo` is false in any artifact built with
   `OVID_PRODUCTION=true`, whatever else was passed.
2. **CI** — the production workflow path fails the build if
   `OVID_BILLING_DEMO` is set at all, so the mistake is loud rather than
   silently ignored.

Five contract tests pin this: four in `test/revenuecat_billing_test.dart`
(group "billing demo") and one in `test/release_flags_test.dart`:

1. a production artifact refuses the demo grant;
2. an internal Play track may demo (it is not production);
3. an opted-in sideload release build may grant, and the plan name says so;
4. the demo route outranks an unavailable store, so the paywall is testable;
5. the workflow refuses the demo define on the production path.

## When Play approves monetization

1. Create the six subscriptions in Play Console (see `REVENUECAT_SETUP.md`).
2. Build **without** `OVID_BILLING_DEMO`, with `OVID_PLAY_BUILD=true` and
   `OVID_PRODUCTION=true`.
3. Verify a real purchase end to end on a license-tester account.

From that point the demo flag is dead weight and should be deleted, along with
`Distribution.billingDemo` and its tests.
