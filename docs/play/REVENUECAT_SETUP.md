# RevenueCat + Play Store setup — Ovid Si

**Updated:** 2026-10-22. Console facts below were recorded by the owner on
2026-10-21 and cannot be verified from the repository — they are marked
**(console)**. Code facts are cited to a file and were re-checked on
2026-10-22.

## Current state

> **BLOCKER before enabling RevenueCat in production (verified 2026-10-22).**
> The client treats a RevenueCat purchase as *pending server confirmation*:
> `applyPurchasedPlan` re-reads `/usage`, and only a server-named tier unlocks
> (`lib/core/revenuecat_billing.dart`). The server learns about a purchase from
> `/billing/verify` (Play purchase token) or `/billing/rtdn`
> (`server/billing/api.py`). RevenueCat purchases never reach either: the SDK
> owns the Play flow and the app does not forward a token, and there is no
> RevenueCat webhook in this repo (`grep -rni revenuecat cloud server` finds
> only `cloud/apps/gateway/src/planGate.ts` comments). A RevenueCat purchase
> would therefore be charged by Google Play and **never unlock the plan**.
> Before shipping with `OVID_REVENUECAT_GOOGLE_KEY`, either add a RevenueCat
> webhook that maps `INITIAL_PURCHASE`/`RENEWAL`/`CANCELLATION`/`EXPIRATION` to
> the server's purchase ledger, or ship without the key so
> `PlayBillingService` (server-verified) handles purchases. Do not advertise
> paid plans until one of those is true.
>
> **The client now fails closed (2026-10-22).** With the key compiled in but no
> webhook, `RevenueCatBilling.buy` refuses to open the store sheet and the
> paywall / Plan & billing CTA is disabled with a real reason, so nobody can be
> charged for a plan that cannot unlock. Play Billing wins whenever it is
> available. See §5b.

### Play Console (signed in as `aasheeshkatheriya@gmail.com`) **(console)**
- Developer account: **Dhanuk Softwares** (`4722370385057181718`)
- App: **Ovid Si**, package `com.dhanuk.ovidai`, app id `4973478968349167758`
- **Internal testing is Active** with release `1 (1.0.0)`, version code 1,
  minSdk 24, targetSdk 36
- Testers: email list **Ovid internal** with 4 addresses
  - `aasheeshkatheriya@gmail.com`
  - `aasheeshtte@gmail.com`
  - `aasheesh333@gmail.com`
  - `dipikamehar8@gmail.com`
- Join link: <https://play.google.com/apps/internaltest/4701178422766027016>

### Google Cloud (project `ovid-ai`) **(console)**
- Service account `revenuecat-play@ovid-ai.iam.gserviceaccount.com` created
- JSON key issued once (not committed; keep the backup safe)
- **Google Play Android Developer API enabled**

### Play Console permissions for the service account **(console)**
Account level: *View financial data*, *Manage orders and subscriptions*,
*View app information (read-only)*.
App level (Ovid Si): *View app information*, *View financial data*,
*Manage orders and subscriptions*, *View app quality*.

### RevenueCat (project `afe58e73`) **(console)**
- Project **Ovid Si** (Productivity, Flutter)
- Play Store app **Ovid Si (Play Store)** (`app3f89cc64b6`), package `com.dhanuk.ovidai`
- **Test Store** app (`app7c8e2d1248`), key `test_...`
- Service account JSON uploaded
- Entitlements: `go`, `plus`, `pro`
- **Test Store products** (monthly, no real charge):
  | Product ID | Name | Price |
  |---|---|---|
  | `ovid_plus_monthly` | Ovid Go | $5 |
  | `ovid_pro_monthly` | Ovid Plus | $18 |
  | `ovid_max_monthly` | Ovid Pro | $99 |
- Default offering **`default`** with packages `$rc_monthly`, `plus`, `pro`
- **No Play (non-Test-Store) product exists yet**, monthly or yearly. That is
  why nothing is purchasable in the internal-test build today
  (`docs/audit/FEATURE_GAPS.md` D1/D2).

### What the code does (verified 2026-10-22)

- **SDK keys are not baked in.** Both are `String.fromEnvironment` with empty
  defaults (`lib/core/revenuecat_billing.dart`). A release build must pass
  `--dart-define=OVID_REVENUECAT_GOOGLE_KEY=...` or RevenueCat stays disabled
  and the Play Billing path is used.
- **A release build refuses the Test Store**, even when the define is present
  (`resolveRevenueCatConfig`, `releaseMode` branch). The Test Store flag is
  debug/profile only.
- Entitlement mapping: `go` → `3x`, `plus` → `7x`, `pro` → `15x`
  (`kRevenueCatEntitlements`).
- Product mapping, including yearly:
  `3x` → `ovid_plus_monthly` / `ovid_plus_yearly`,
  `7x` → `ovid_pro_monthly` / `ovid_pro_yearly`,
  `15x` → `ovid_max_monthly` / `ovid_max_yearly`
  (`lib/core/billing_products.dart`, `kOvidPlayProductIds`).
- A yearly request never falls back to the monthly package: `_packageFor`
  returns `null` for a yearly product id that is not in the offering, and
  `buy()` reports `UpgradeResult.notAvailable` with "Yearly billing is not
  available for this plan yet." (`lib/core/revenuecat_billing.dart`).
- **The server product map now includes both periods.** `server/billing/products.py`
  `DEFAULT_PRODUCTS` and `cloud/apps/mint/src/billing/products.ts`
  `DEFAULT_PRODUCTS` list the three monthly ids **and** the three yearly ids
  (`ovid_plus_yearly` / `ovid_pro_yearly` / `ovid_max_yearly`). `evaluate()`
  still rejects an unknown product with a typed `400 unknown_product`, so any
  new SKU must be added to both maps before it is sold. An override
  (`OVID_PLAY_PRODUCTS`) replaces the defaults entirely: if you use it, it must
  list all six ids.

### Demo paywall (debug/profile only)

```bash
flutter build apk --debug \
  --dart-define=OVID_REVENUECAT_TEST_STORE=true \
  --dart-define=OVID_REVENUECAT_TEST_STORE_KEY=test_...
```

In that build:
- `RevenueCatBilling` configures the **Test Store** key.
- The paywall and Plan & billing show a **"Test mode: purchases are simulated"** note.
- If the offering resolves, the Test Store sheet opens and grants the tier with
  no charge. If no package resolves, the service grants a clearly-labelled demo
  entitlement (`lastPurchaseWasDemo = true`) so the flow still completes.
- A **release** build ignores the Test Store define and uses the Google Play
  key; if that key is missing, RevenueCat is disabled and Play Billing is used.

> The previous revision of this document said to build the AAB with
> `--release --dart-define=OVID_REVENUECAT_TEST_STORE=true`. That cannot work:
> release builds strip the Test Store. Any internal-test build that must show
> a purchase uses a real Play license-tester account instead.

## Remaining (external, time-based)

### 1. Wait for Play permission propagation, then validate the service account

RevenueCat shows "Service account credentials need attention" until Google
accepts the service account. This is usually minutes, up to 24 h.

- Open RevenueCat → Apps → **Ovid Si (Play Store)** → press **Check again**.
- Green means RevenueCat can call the Play Developer API.
- Then make one real purchase with a license tester and confirm RevenueCat
  records it (this is FEATURE_GAPS D4: credentials not yet validated end to
  end).

### 2. Create the Play subscriptions

Play Console → **Monetize → Products → Subscriptions**. Product IDs must match
`lib/core/billing_products.dart` and `server/billing/products.py` exactly.

Monthly (still missing — D1):

| Tier | Product ID | Price |
|---|---|---|
| Go | `ovid_plus_monthly` | $5 / ₹499 |
| Plus | `ovid_pro_monthly` | $18 / ₹1,799 |
| Pro | `ovid_max_monthly` | $99 / ₹9,999 |

Yearly (the three SKUs this document exists for — D2). **Yearly price = 10
monthly payments**, matching the prices the UI already shows
(`lib/ui/v2/settings/plan_billing_page.dart`: `yearlyUsd` 50 / 180 / 990,
`yearlyInr` 4990 / 17990 / 99990):

| Tier | Product ID | US price | India price |
|---|---|---|---|
| Go | `ovid_plus_yearly` | **$50** | **₹4,990** |
| Plus | `ovid_pro_yearly` | **$180** | **₹17,990** |
| Pro | `ovid_max_yearly` | **$990** | **₹99,990** |

For each yearly SKU:

1. **Create subscription** → product ID above.
2. Add a **base plan**: auto-renewing, billing period **yearly (P1Y)**,
   **Active**. A subscription with no active base plan is not purchasable.
3. Set the US price and the India price in the base plan. Play converts other
   regions automatically; check the round numbers above are what a tester
   sees.
4. Leave the base plan's offer/trial fields empty unless a product decision
   says otherwise; the app has no trial copy.
5. Activate the subscription. Play may require the app to have a reviewed
   release before Monetize unlocks — internal testing review is automatic, but
   an "unreviewed" app name can keep Monetize locked for a while.

### 3. Add the products to RevenueCat

RevenueCat → **Products** → **+** → Google Play product:

1. Import each of the six product ids (three monthly, three yearly) with the
   package `com.dhanuk.ovidai`.
2. **Attach each product to its entitlement:**

   | Product | Entitlement |
   |---|---|
   | `ovid_plus_monthly`, `ovid_plus_yearly` | `go` |
   | `ovid_pro_monthly`, `ovid_pro_yearly` | `plus` |
   | `ovid_max_monthly`, `ovid_max_yearly` | `pro` |

   An entitlement with no product never unlocks, and a product with no
   entitlement grants nothing — both failures look like "purchase succeeded,
   plan unchanged" in the app.
3. Add one package per product to the **`default`** offering. Package
   identifiers are free-form; the app matches by **product id** first, so the
   product id is what has to be right. A monthly package may also be found by
   the conventional `$rc_monthly` / `monthly` identifier, but a yearly product
   must be present by exact id.
4. The app's yearly guard needs the yearly product to be present in the
   offering; otherwise the toggle correctly reports "not available".

### 4. Build the release with the Play SDK key

```bash
flutter build appbundle --release \
  --dart-define=OVID_REVENUECAT_GOOGLE_KEY=<public Play SDK key>
```

Without the define, `kRevenueCatGoogleKey` is empty and the app falls back to
plain Play Billing (verification still happens server-side). Do not pass the
Test Store define: a release build ignores it by design. A release command that
still contains `OVID_REVENUECAT_TEST_STORE=true` is misconfigured even though
the resolver refuses it — rebuild clean before uploading.

### 5. Keep the server product map in step with the store

The default map now lists all six ids, so a yearly purchase verifies without
an environment override. Two rules:

- If you set `OVID_PLAY_PRODUCTS`, it **replaces** the defaults: include all
  six ids, monthly and yearly.
- Adding a seventh SKU later means updating `server/billing/products.py`,
  `cloud/apps/mint/src/billing/products.ts` **and**
  `lib/core/billing_products.dart` in the same change. A missing id means Play
  charges the card, `/billing/verify` answers `400 unknown_product`, the app
  does not acknowledge, and Google refunds the purchase.

```bash
# Only if you need an override; this is the complete six-id map.
OVID_PLAY_PRODUCTS='{
  "ovid_plus_monthly":"3x","ovid_plus_yearly":"3x",
  "ovid_pro_monthly":"7x","ovid_pro_yearly":"7x",
  "ovid_max_monthly":"15x","ovid_max_yearly":"15x"
}'
```

### 5b. Fixing the RevenueCat blocker (implementation notes)

This is the detail behind the blocker at the top of this file. The client only
unlocks after `GET /usage` names the paid tier
(`lib/core/revenuecat_billing.dart` `applyPurchasedPlan` → `refreshServerTier`).
Today the **only** code that sets a tier is the Google Play path:
`POST /billing/verify` (`server/billing/api.py`, `cloud/apps/mint/src/billing/service.ts`)
and the Play RTDN handler. Both need the Play **purchase token**, which the
RevenueCat SDK purchase does not hand to the app (its
`StoreTransaction.transactionIdentifier` is the Play order id, not the token).

Consequence with `OVID_REVENUECAT_GOOGLE_KEY` compiled in: RevenueCat charges
the card, the client shows "Payment received. Plan unlocks after confirmation",
and the confirmation never arrives.

Two acceptable fixes (pick one before shipping a release with the RevenueCat
key):

> **Client fail-closed gate (2026-10-22).** Until one of the two fixes below
> exists, `lib/core/revenuecat_billing.dart` refuses to start a RevenueCat
> purchase: `RevenueCatBilling.buy` returns `notAvailable` with
> `kRevenueCatUnconfirmedReason`, and `resolveBillingRoute` disables the paywall
> / Plan & billing CTA. The Play path wins whenever it is available. The
> RevenueCat path is re-enabled only by compiling with
> `--dart-define=OVID_REVENUECAT_SERVER_CONFIRMATION=true` after the webhook in
> fix 1 is deployed and verified end to end.

1. **RevenueCat webhook (designed path).** Add
   `cloud/apps/mint/src/billing/revenuecatWebhook.ts` + a route:
   - verify the `Authorization` header against a shared secret
     (`OVID_REVENUECAT_WEBHOOK_SECRET`, fail closed, constant-time compare);
   - map `entitlement_ids` (`go`/`plus`/`pro`) to `3x`/`7x`/`15x` and ignore
     unknown ids;
   - set the tier from `expiration_at_ms` (never from the request body's
     `tier`), keep access on `CANCELLATION` until expiry, revoke on
     `EXPIRATION`/`REFUND`;
   - dedupe on `event.id` so a redelivered event is idempotent;
   - then configure the webhook URL + secret in the RevenueCat console.
2. **Purchase through Play Billing only.** Keep RevenueCat for entitlement
   display, but make the release build buy through
   `PlayBillingService` so `/billing/verify` binds the token and sets the tier.

Until one is done, a release build **without** the RevenueCat key (Play
Billing path) is the only configuration that reliably unlocks a purchase.

### 6. Validate end to end

> This step only passes after the server-confirmation blocker at the top of this
> file is closed. With the current code, a RevenueCat purchase is charged but
> the tier stays unchanged; the Play Billing fallback (no RevenueCat key) does
> reach `/billing/verify`.

1. Install the release build on a license-tester account.
2. Buy each yearly SKU once; confirm the tier unlocks, and confirm the server
   recorded `product_id` = the yearly id (not the monthly one).
3. `restore()` must return the same tier from the `go`/`plus`/`pro`
   entitlements.
4. Cancel in Play → confirm the account **keeps the plan until the paid period
   ends** and is downgraded only at `expiryTime` (RTDN path,
   `server/billing/api.py` `notify` + `domain.evaluate`: CANCELED is an
   entitled state). `plan_auto_renews` must flip to false immediately.
5. Only then update `docs/play/DATA-SAFETY.md` §2 from "No today" to **Yes**
   for Purchase history.

### 7. Optional: real-time developer notifications

Connect **Google developer notifications** (Pub/Sub) in RevenueCat for
real-time purchase events. The server's own RTDN endpoint already exists
(`server/billing/api.py`), so this is a latency improvement, not a
requirement.

## Build

The release build is signed with the upload key in
`android/keystore.properties` (gitignored) and
`android/release-keystore.jks` (gitignored). The keystore credentials are
owner-blocked (FEATURE_GAPS D6).

```bash
export PATH=/root/flutter/bin:$PATH
flutter build appbundle --release \
  --dart-define=OVID_REVENUECAT_GOOGLE_KEY=<public Play SDK key>
# -> build/app/outputs/bundle/release/app-release.aab
```

`android/app/google-services.json` is required for the release build and is
gitignored (project `ovid-ai`, package `com.dhanuk.ovidai`).

## Verification in the app

`RevenueCatBilling` (`lib/core/revenuecat_billing.dart`):

- `available` depends on a non-empty SDK key compiled into the build.
- `configure()` binds the signed-in Firebase uid as the RevenueCat app user id.
- `buy(tier, {period})` maps `3x/7x/15x` (and monthly/yearly) →
  `ovid_plus_monthly/ovid_pro_monthly/ovid_max_monthly` or
  `ovid_plus_yearly/ovid_pro_yearly/ovid_max_yearly`, finds the matching
  package, and purchases it. A yearly request never falls back to a monthly
  package.
- `restore()` and `currentTier()` read entitlements `go/plus/pro`.
  `restore()` reports **nothing to restore** (the store answered, no active
  entitlement) separately from a **failed** restore (network/SDK error), so the
  paywall banner never says "nothing found" when it simply could not ask.
- The paywall and Plan & billing show the **store's localised price** when the
  Play catalogue has answered, and disable a period Play does not sell with a
  real reason. The canonical table (Go $5/₹499, Plus $18/₹1,799, Pro
  $99/₹9,999, yearly = 10 monthly payments) is only the fallback.
- The Play Billing flow remains the fallback if the RevenueCat key is removed
  (`--dart-define=OVID_REVENUECAT_GOOGLE_KEY=`).

## What is still unverified

- Whether the Play service account is accepted right now (console state).
- Whether Monetize is unlocked for this app (console state).
- Whether the three monthly subscriptions exist (FEATURE_GAPS D1 says no).
- The uploaded build number on the internal track (console state; the repo is
  at `1.0.0+3`).
