# Ovid images — repository implementation, not deployed

## Verified upstream contract (2026-10-03)

Read-only discovery used `/opt/ovid-gateway/verifier/mint.py`, the LiteLLM
configuration, authenticated local `/model/info`, and the existing encrypted
provider credential in a read-only database transaction. No credential is
included here. The configured URL is **https://api.inferhub.dev/v1**.

Sources: authenticated `GET /v1/models` and
<https://inferhub.dev/api/openapi.json> (`/v1/images/generations`,
`/v1/images/edits`, `/catalog`, `/usage/logs`). The selected actual backend IDs
are in `config.json`. Each was listed with `output_modality: image` and
`modality: text,image`. They are private server configuration, never app assets.

The documented API accepts JSON, one `image` data URL for edits, `n: 1`, and
`response_format: b64_json`. PNG bytes are inline; `usage.cost` is the actual
request charge. The four configured sizes are the API reference's pixel-size
options. They have **not** been tested on a paid image job; a model rejecting a
size produces a permanent request failure, not a fallback to a different task.
Masks, multiple input images, arbitrary custom parameters and quality controls
are intentionally not advertised because compatibility across this pool has
not been established.

## Implemented

- `service.py`: one public alias, two/three distinct private backends,
  capability/size routing, explicit refusal fallback, no retry after an
  ambiguous transport/proxy timeout, strict input/output image decoding, and
  a persistent SQLite job ledger. Successful settlement is exactly
  `Decimal(actual_upstream_cost) * Decimal('0.30')` (70% off).
  Numeric JSON costs are parsed directly into Decimal; binary floats are
  rejected at the money boundary. Multiplication, sums and budget comparisons
  preserve exact digits independently of the caller's Decimal precision.
- SQLite's immediate transaction admits each UID/request ID once, detects
  payload conflicts and prevents concurrent reservation overdraw. Replay
  survives restarts and budget-window changes. Pending/uncertain jobs never
  expire or re-submit automatically. Invalid successful responses retain a
  reservation for reconciliation because they may already have been billed.
  Bare HTTP errors (including 429 and 5xx) from InferHub are ambiguous, never
  fallback signals. Only a typed `UpstreamNotAccepted(429/503)` backed by an
  adapter's verified nonacceptance evidence permits fallback. A status code or
  Retry-After header is not such evidence; plain `UpstreamError` preserves the
  reservation. No verified nonacceptance signal is currently wired in InferHub,
  so its errors never authorize fallback or release an uncertain reservation.
- `inferhub.py`: the verified JSON API and authenticated startup catalog check;
  bounded streamed responses, no redirects or image URL fetching.
- `verifier.py`: mountable FastAPI routes using the existing Firebase/App Check
  verifier, ban checks, current per-UID key mapping and LiteLLM key validity,
  ownership, expiry and explicit `ovid-image` model scope. Every request,
  including replay, rechecks auth. No new key issuance path.
- `catalog.py`: public projections strip configured backend IDs and image
  pricing. The mount wraps the existing verifier's `_available_models` for
  `/usage` and supplies a sanitizing `/v1/models` route.
- App: capability-gated generate/edit tools, exact staged paths and grants,
  bounded decoded PNG/JPEG/WebP inputs, durable returned image files and chat
  display, local deterministic resize/crop, plan/read-only gates. No client
  billing calculation. Sign-out/account changes clear image capability cache.

## Durable receipts and retention

Successful generation/edit and replay responses include `receipt` alongside
`model` and `data`. Receipt fields are `account_id`, `request_id`, `fingerprint`,
`state` (`pending`, `unknown`, `confirmed`, `failed`) and `charged` (exact decimal
string for confirmed/failed, `null` while unresolved). Private upstream cost
and backend IDs are excluded. Confirmation describes the local durable image
ledger; activation still requires the shared authority below.

Ambiguous submission/response/settlement failures return HTTP 409 with
`image_request_pending` and a receipt. If even the unknown-state write fails,
the original durable pending admission still prevents resubmission. If commit
succeeded but its acknowledgment was lost, the receipt can already be confirmed.
Clients must preserve their original idempotency key and reconcile with
`GET /v1/images/requests/{request_id}`; this authenticated, account-scoped,
`no-store` endpoint only reads a receipt and never submits or settles work.
Production `VerifierAuth.verify_identity` retains token/App Check, ban, key
ownership/scope/expiry/revocation checks without consulting remaining free quota.
Thus an existing receipt remains readable at zero allowance; ledger deletion
and receipt expiry are still enforced. Paid POST and capability checks retain
their quota gate. Custom authentication can expose the same `verify_identity`
method for reads; otherwise its callable's checks remain authoritative. The
handler never catches and suppresses an authentication denial to bypass quota.
All image routes, including this endpoint, remain 503 without the service and
shared admission bridge. Duplicate/reordered local settlement returns the
original result and cannot overwrite a confirmed charge.

Local retention policy (constructor-overridable, persisted per completed job):
Durations must be finite positive numeric seconds, with replay retention no
longer than receipt retention; invalid policies are rejected before opening SQLite.

- Input/prompt bytes: not persisted by this module; only a payload fingerprint.
- Output replay blobs: 24 hours after settlement. Expired replay returns 410,
  even if a cleanup worker has not run. A retry never creates a replacement job.
- Public receipts/private actual cost: 90 days after completion. Receipt reads
  then return 410. `Ledger.purge_expired()` removes expired response/actual data.
- Minimal account/request/fingerprint/state/charge/window deduplication and
  accounting tombstones: retained indefinitely to prevent rebilling and preserve
  budget totals. Unresolved reservations never expire, including across windows.
- Legacy databases lacking timestamps: drop old replay blobs at migration while
  preserving paid receipts for 90 days and pending reservations indefinitely.
  Restart does not renew deadlines.

`Ledger.delete_account(verified_uid)` is the idempotent local cleanup adapter:
it removes replay blobs/private actual cost, blocks all future admission/replay
for that UID, and retains minimal billing/dedup tombstones. Already accepted
jobs can still settle their exact charge, but late output cannot be stored or
returned. A deleted account cannot proceed to another backend after a refusal.
`server.account.runtime.build()` now wires this into configured account deletion,
and `server.account.retention` supplies bounded sweeps and a repeatable timer.
See [configured deployment](../account/DEPLOYMENT.md); actual store provisioning
and host scheduling remain mandatory. SQLite logical deletion is tested; WAL/backup
retention and provider-side input/output deletion require deployment-owned
cleanup. No production reconciliation or provider deletion adapter is invented.

### Coordinated upgrade and rollback policy

**Mixed-version workers and rollback to the legacy ledger code are unsafe.**
Legacy workers do not count `unknown` reservations toward admission, do not
honor account-deletion tombstones, and ignore replay/receipt deadlines. Merely
sharing the upgraded SQLite schema does not make those workers compatible.

1. Disable paid image admission at the deployment boundary and drain all image
   workers before migration. Stop old workers and their cleanup/reconciliation
   jobs; do not run a rolling mixed-version pool against this database.
2. Preserve the authoritative database together with its consistent WAL state.
   Keep pending/unknown jobs and dedup/deletion tombstones; unresolved jobs remain
   reserved for verified reconciliation, never converted to failed for upgrade.
3. Migrate once with this version, deploy all consumers with the same state and
   tombstone semantics, and check receipt reads, deletion denial, reservation
   totals and retention before re-enabling admission through the shared authority.
4. If deployment fails, keep admission closed and roll forward to a compatible
   build. Restoring an older binary or pre-upgrade database can lose accepted-job
   deduplication, charges or deletions. Any legacy rollback requires a separately
   reviewed reconciliation/migration preserving every reservation, charge,
   tombstone and deadline; there is no automatic rollback adapter here.

## Exact activation blockers

`server.images.runtime.mount_configured_images` composes the real host's mint,
Firebase Admin, account fence, configured stores and supplied shared admission.
Read-only `GET /v1/images/requests/{request_id}/result` retrieves a retained output
and receipt at zero remaining quota without submitting/settling work. Like the
receipt GET it requires current identity/App Check/scoped key/account access and
returns 410 on expiry/deletion. See the deployment guide for the exact factory API.

**The mounted routes return 503 unless both a service and an atomic admission
bridge are supplied. No live configuration or `/opt` source was changed.**

1. **Shared spend authority:** the inspected verifier's `/usage` reads LiteLLM
   `key/info.spend`, and free monthly spend is read from Redis. There is no
   atomic image reservation/settlement API in that verifier. Supply an
   `admission(identity)` context manager backed by the shared text/image budget
   authority. It yields `(budget_window_id, budget_excluding_image_spend)` and
   must coordinate concurrent text spend, image reservations/settlements,
   window resets, `/usage`, and the free monthly cap. A read/modify/write
   `/key/update` of spend is not an atomic substitute. The implemented image
   ledger alone does **not** charge the existing LiteLLM/Redis account pool.
2. **Enforced upstream cost ceiling:** `configured_service` requires a real
   enforced maximum for reservation. The discovered API documents variable
   token charges, not a hard per-image dollar cap. A cheapest catalog ask is
   not a maximum. Establish a bounded route/admission policy before passing
   `enforced_max_upstream_cost`. Actual settlement always uses `usage.cost`;
   no price is fabricated from asks or image dimensions.
3. **Scoped keys and proxy wiring:** existing mint keys do not explicitly grant
   `ovid-image`. The key lifecycle owner must add this scope to authorized
   existing/new keys while retaining text scopes. Route `/v1/images/*` and
   `/v1/models` to the verifier ahead of Caddy's current `/v1/*` LiteLLM rule.
   Keep private image models out of public LiteLLM aliases; all paid image
   traffic must pass the new authority. Mount with `private_backends` from the
   configuration even while inactive so catalog masking is installed.
4. **Controlled validation:** no cheap image test route was configured and no
   chargeable generation/edit was run. After the above, validate generation,
   single-image editing, size behavior, cost receipts, gateway timeouts and
   shared usage on a configured bounded cheap test route before activation.

The app's local resize/crop tools work without these prerequisites. Cloud tools
remain absent until the authenticated capability endpoint confirms availability.

## Tests

Install `requirements.txt` in an isolated environment, then from repository root:

```sh
python -m unittest discover -s server/images/tests -p '*test*.py' -v
flutter test test/image_studio_test.dart test/image_tools_integration_test.dart
```

Fixtures are explicitly fictional test backend IDs and use synthetic image
bytes; tests never submit paid upstream jobs. The server integration suite
exercises the actual FastAPI boundary, InferHub adapter, auth/key lifecycle,
catalog projection, persistent ledger, decimal discount, concurrency, retries,
edit capability filtering and malformed responses.
