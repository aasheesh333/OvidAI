# RevenueCat + Play Store setup — Ovid Si

**Updated:** 2026-10-21

## Current state

### Play Console (signed in as `aasheeshkatheriya@gmail.com`)
- Developer account: **Dhanuk Softwares** (`4722370385057181718`)
- App: **Ovid Si**, package `com.dhanuk.ovidai`, app id `4973478968349167758`
- **Internal testing is Active** with release `1 (1.0.0)`, version code 1, minSdk 24, targetSdk 36
- Testers: email list **Ovid internal** with 4 addresses
  - `aasheeshkatheriya@gmail.com`
  - `aasheeshtte@gmail.com`
  - `aasheesh333@gmail.com`
  - `dipikamehar8@gmail.com`
- Join link: <https://play.google.com/apps/internaltest/4701178422766027016>

### Google Cloud (project `ovid-ai`)
- Service account `revenuecat-play@ovid-ai.iam.gserviceaccount.com` created
- JSON key issued once (not committed; keep the backup safe)
- **Google Play Android Developer API enabled**

### Play Console permissions for the service account
Account level: *View financial data*, *Manage orders and subscriptions*,
*View app information (read-only)*.
App level (Ovid Si): *View app information*, *View financial data*,
*Manage orders and subscriptions*, *View app quality*.

### RevenueCat (project `afe58e73`)
- Project **Ovid Si** (Productivity, Flutter)
- Play Store app **Ovid Si (Play Store)** (`app3f89cc64b6`), package `com.dhanuk.ovidai`
- **Test Store** app (`app7c8e2d1248`), key `test_...`
- Service account JSON uploaded
- Public SDK keys compiled into the app (`lib/core/revenuecat_billing.dart`)
- Entitlements: `go`, `plus`, `pro`
- **Test Store products** (monthly, no real charge):
  | Product ID | Name | Price |
  |---|---|---|
  | `ovid_plus_monthly` | Ovid Go | $5 |
  | `ovid_pro_monthly` | Ovid Plus | $18 |
  | `ovid_max_monthly` | Ovid Pro | $99 |
- Each product attached to its entitlement
- Default offering **`default`** with packages `$rc_monthly`, `plus`, `pro`

## Demo paywall (internal testing)

Build with:

```bash
flutter build appbundle --release --dart-define=OVID_REVENUECAT_TEST_STORE=true
```

In that build:
- `RevenueCatBilling` configures the **Test Store** key.
- The paywall and Plan & billing show a **"Test mode: purchases are simulated"** note.
- If the offering resolves, the Test Store sheet opens and grants the tier with
  no charge. If no package resolves, the service grants a clearly-labelled demo
  entitlement (`lastPurchaseWasDemo = true`) so the flow still completes.
- A production build (flag off) uses the Google Play key and the real Play
  billing flow.

Version 2 (`1.0.0+2`) of the AAB was uploaded to internal testing with this flag.

## Remaining (external, time-based)

1. **Wait for Play permission propagation** (usually minutes, up to 24 h).
   RevenueCat shows "Service account credentials need attention" until Google
   accepts the service account. Then press **Check again** in
   RevenueCat → Apps → Ovid Si (Play Store).
2. **Create Play subscriptions** (Play Console → Monetize → Products →
   Subscriptions). Product IDs must match the app and the server:

   | Tier | Product ID | Price |
   |---|---|---|
   | Go | `ovid_plus_monthly` | $5 / ₹499 |
   | Plus | `ovid_pro_monthly` | $18 / ₹1,799 |
   | Pro | `ovid_max_monthly` | $99 / ₹9,999 |

   Monetize is locked until Google reviews the first internal release
   ("unreviewed" app name). Uploading the release is done; the review is
   automatic for internal testing.
3. **Attach products to entitlements** in RevenueCat once the subscriptions
   exist:
   - `ovid_plus_monthly` → `go`
   - `ovid_pro_monthly` → `plus`
   - `ovid_max_monthly` → `pro`
4. **Create a default offering** with one package per product so
   `Purchases.getOfferings()` returns them.
5. Optional: connect **Google developer notifications** (Pub/Sub) in
   RevenueCat for real-time purchase events.

## Build

The release build is signed with the upload key in
`android/keystore.properties` (gitignored) and
`android/release-keystore.jks` (gitignored).

```bash
export PATH=/root/flutter/bin:$PATH
flutter build appbundle --release
# -> build/app/outputs/bundle/release/app-release.aab
```

`android/app/google-services.json` is required for the release build and is
gitignored (project `ovid-ai`, package `com.dhanuk.ovidai`).

## Verification in the app

`RevenueCatBilling` (`lib/core/revenuecat_billing.dart`):

- `available` is true because the public SDK key is compiled in.
- `configure()` binds the signed-in Firebase uid as the RevenueCat app user id.
- `buy(tier)` maps `3x/7x/15x` → `ovid_plus_monthly/ovid_pro_monthly/ovid_max_monthly`,
  finds the matching package, and purchases it.
- `restore()` and `currentTier()` read entitlements `go/plus/pro`.
- The Play Billing flow remains the fallback if the RevenueCat key is removed
  (`--dart-define=OVID_REVENUECAT_GOOGLE_KEY=`).
