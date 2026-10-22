# Ovid Cloud — Google Play Billing verification

Server half of F-009 (Play Billing). The app buys a Play subscription, sends the
purchase token here, and **acknowledges the purchase only after this service
has verified it with Google and set the tier**. Play refunds purchases that are
not acknowledged within 3 days, so a failed verification never keeps money.

Nothing in this directory is deployed. It is a self-contained module mounted on
the existing mint FastAPI app (like `server/images`).

## Endpoints

### `POST /billing/verify`
Headers: `Authorization: Bearer <Firebase ID token>`, `X-Firebase-AppCheck` (same
as `/mint` and `/usage`). Body:

```json
{"product_id": "ovid_plus_monthly", "purchase_token": "<Play token>", "package_name": "com.dhanuk.ovidai"}
```

1. Authenticates with mint's own `verify_google_id_token` / `verify_app_check` / `is_banned`.
2. Refuses a token already bound to another UID (409 `purchase_owned_by_another_account`).
3. Reads `purchases.subscriptionsv2.get` with the service account.
4. Requires `externalAccountIdentifiers.obfuscatedExternalAccountId ==
   sha256("ovid:" + uid)` (the app sets it via `applicationUserName`).
5. Maps the line item's `productId` to a tier, upserts the token row (idempotent
   per purchase token), recomputes the user's best active purchase and writes it
   to `user:{uid}:tier` (see "Tier sink").

| Status | Body | Client action |
|---|---|---|
| 200 | `{"ok":true,"status":"active","tier":"3x","expires_at":"…Z","auto_renewing":true,"acknowledge":true}` | apply tier, `completePurchase` |
| 202 | `{"ok":false,"status":"pending","acknowledge":false}` | wait (deferred payment) |
| 200 | `{"ok":false,"status":"expired"\|"replaced"\|"revoked",…}` | do not acknowledge |
| 400 | `invalid_request` / `wrong_package` / `unknown_product` / `purchase_invalid` | do not acknowledge |
| 401 / 403 | `sign_in_required` / `account_mismatch` / `account_blocked` | do not acknowledge |
| 409 | `purchase_owned_by_another_account` | do not acknowledge |
| 503 | `billing_unavailable` / `play_unavailable` / `play_auth_failed` | retry later; do not acknowledge |

### `POST /billing/rtdn`
Pub/Sub **push** endpoint for Real-time Developer Notifications. Every
subscription notification (renewed, recovered, canceled, on hold, grace period,
paused, revoked, expired, pending-purchase-canceled, …) re-reads the token from
Google and updates the tier; `linkedPurchaseToken` marks the old token
`replaced`; `SUBSCRIPTION_REVOKED` and `voidedPurchaseNotification` (refunds)
mark it `revoked` permanently. Redeliveries are idempotent. Transient Google
errors return 503 so Pub/Sub retries; malformed/test/foreign-package messages
return 204. A token seen here before `/billing/verify` is stored unbound and is
applied when the app verifies it.

Push auth (fail-closed if neither is set):
* **Preferred:** OIDC push auth — `OVID_RTDN_AUDIENCE` (the push endpoint URL)
  and `OVID_RTDN_SERVICE_ACCOUNT` (the push subscription's service account email).
* Fallback: `OVID_RTDN_SHARED_SECRET`, appended to the push URL as `?secret=…`.

## Mint integration (exact changes)

```python
# mint.py, after `app = FastAPI(...)` and the existing helpers are defined
from server.billing.api import mount_billing
billing = mount_billing(sys.modules[__name__])  # uses mint.app, mint.rds, verify_*

@app.post('/usage')
def usage(...):
    ...
    payload.update(billing.usage_fields(uid))   # adds the fields below
    return payload
```

`billing.usage_fields(uid)` returns:

```json
{
  "billing_enabled": true,
  "plan_expires_at": "2026-11-11T08:00:00Z",
  "plan_auto_renews": true,
  "plan_product_id": "ovid_plus_monthly",
  "plans": [{"tier": "free", "features": ["…"]}, {"tier": "3x", "product_id": "ovid_plus_monthly", "features": ["…"]}, …]
}
```

`billing_enabled` is `true` only once a service account is configured
(`billing.configured`). Until then the app keeps showing "Paid plans coming
soon" (PR-1b gate). The `plan_*` fields drive "Renews on / Ends on" and `plans`
drives the per-plan feature lists (F-200).

The app additionally reads (optional, recommended) **`resets_at`** — ISO-8601 UTC
time at which the current allowance window resets (daily window for Free, end of
the 30-day pool for paid) — to render "Resets in 4h 12m" on the Usage screen
(F-204). Mint owns the window, so mint must add it next to `budget_window`.

### Tier sink
By default the service writes mint's existing Redis key:

* paid: `SET user:{uid}:tier <3x|7x|15x> EXAT <expiry + 600 s>` and
  `SET user:{uid}:tier_expires_at <expiry epoch> EXAT <same>`;
* free: `DEL user:{uid}:tier user:{uid}:tier_expires_at`.

The key expiring by itself means a missed RTDN can never leave a paid tier on
forever. `mint.effective_tier(uid)` must keep treating a missing key as `free`.
If mint needs to do more on a tier change (reset the 30-day pool on renewal,
update the LiteLLM key budget the way `/upgrade` does), define
`mint.set_user_tier(uid, tier, expires_at_epoch_or_None)`; `mount_billing`
uses it instead of the Redis sink. **Reuse the budget-update code of the test
`/upgrade` handler there**, then disable `/upgrade` (`ALLOW_TEST_UPGRADE=false`).

### Caddy
Route `/billing/*` to the mint/verifier upstream (like `/mint`, `/usage`).

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `OVID_PLAY_SERVICE_ACCOUNT_FILE` | — (unset = billing disabled) | JSON key of the Play API service account |
| `OVID_PLAY_PACKAGE` | `com.dhanuk.ovidai` | Android package name |
| `OVID_PLAY_PRODUCTS` | all six ids: `{"ovid_plus_monthly":"3x","ovid_plus_yearly":"3x","ovid_pro_monthly":"7x","ovid_pro_yearly":"7x","ovid_max_monthly":"15x","ovid_max_yearly":"15x"}` | product ID → tier (an override replaces the whole map) |
| `OVID_BILLING_DB` | `/data/ovid-billing.sqlite` | purchase-token ledger (persistent volume) |
| `OVID_RTDN_AUDIENCE`, `OVID_RTDN_SERVICE_ACCOUNT` | — | Pub/Sub OIDC push auth |
| `OVID_RTDN_SHARED_SECRET` | — | fallback push auth |
| `OVID_BILLING_REQUIRE_ACCOUNT_ID` | `true` | refuse tokens without the obfuscated account ID |

## Owner setup (Play Console / Google Cloud)

1. Play Console → Monetize → Subscriptions: create `ovid_plus_monthly`,
   `ovid_pro_monthly`, `ovid_max_monthly` (auto-renewing **monthly** base plan)
   and `ovid_plus_yearly`, `ovid_pro_yearly`, `ovid_max_yearly`
   (auto-renewing **yearly** base plan; 10 monthly payments). Prices per
   country; no free trial unless decided. IDs must match
   `OVID_PLAY_PRODUCTS` (or the defaults in `products.py`) and
   `kOvidPlayProductIds` in `lib/core/billing_products.dart`.
   In-app upgrades replace the current subscription with
   `ReplacementMode.chargeProratedPrice`; downgrades and cancellation go
   through the Play subscription centre.
2. Google Cloud: enable "Google Play Android Developer API"; create a service
   account + JSON key; in Play Console → Users and permissions invite it with
   "View financial data" and "Manage orders and subscriptions".
3. RTDN: create Pub/Sub topic (e.g. `play-rtdn`), grant
   `google-play-developer-notifications@system.gserviceaccount.com` the
   Publisher role, set it in Play Console → Monetization setup → Real-time
   developer notifications, then create a **push** subscription to
   `https://api.ovidsi.com/billing/rtdn` with OIDC auth (audience = that URL).
4. Add license testers for internal testing; test purchases renew every few
   minutes, which exercises the RTDN path.
5. Deploy, set the env vars, verify `/usage` returns `billing_enabled: true`,
   then set `ALLOW_TEST_UPGRADE=false`.

## Tests

```
pytest server/billing
```
Google is mocked (`FakePlay` / `httpx.MockTransport`); no network or credentials.
