# RevenueCat + Play Store setup — Ovid Si

**Updated:** 2026-10-22. Console facts below were recorded by the owner on
2026-10-21 and cannot be verified from the repository — they are marked
**(console)**. Code facts are cited to a file and were re-checked on
2026-10-22.

## Current state

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
- **The server's default product map has no yearly ids.**
  `server/billing/products.py` `DEFAULT_PRODUCTS` lists only the three monthly
  products, and `evaluate()` rejects a product it does not know with a typed
  `400 unknown_product` (`server/billing/domain.py`). A yearly purchase will
  therefore fail server verification until the mapping is extended — see
  step 5.

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
Test Store define: a release build ignores it by design.

### 5. Extend the server product map with the yearly ids

This is required for a yearly purchase to unlock anything. The server maps
Play product → tier from `OVID_PLAY_PRODUCTS`, defaulting to monthly only
(`server/billing/products.py`):

```bash
OVID_PLAY_PRODUCTS='{
  "ovid_plus_monthly":"3x","ovid_plus_yearly":"3x",
  "ovid_pro_monthly":"7x","ovid_pro_yearly":"7x",
  "ovid_max_monthly":"15x","ovid_max_yearly":"15x"
}'
```

Set this on the billing service before the yearly SKUs go live. Without it,
`evaluate()` raises `400 unknown_product` and the app shows a purchase error
even though Play charged the card.

### 6. Validate end to end

1. Install the release build on a license-tester account.
2. Buy each yearly SKU once; confirm the tier unlocks, and confirm the server
   recorded `product_id` = the yearly id (not the monthly one).
3. `restore()` must return the same tier from the `go`/`plus`/`pro`
   entitlements.
4. Cancel in Play → confirm the RTDN path downgrades the account
   (`server/billing/api.py` `notify`).
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
- The Play Billing flow remains the fallback if the RevenueCat key is removed
  (`--dart-define=OVID_REVENUECAT_GOOGLE_KEY=`).

## What is still unverified

- Whether the Play service account is accepted right now (console state).
- Whether Monetize is unlocked for this app (console state).
- Whether the three monthly subscriptions exist (FEATURE_GAPS D1 says no).
- The uploaded build number on the internal track (console state; the repo is
  at `1.0.0+3`).
