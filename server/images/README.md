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
  capability/size routing, explicit 429/503 refusal fallback, no retry after an
  ambiguous transport/proxy timeout, strict input/output image decoding, and
  a persistent SQLite job ledger. Successful settlement is exactly
  `Decimal(actual_upstream_cost) * Decimal('0.30')` (70% off).
- SQLite's immediate transaction admits each UID/request ID once, detects
  payload conflicts and prevents concurrent reservation overdraw. Replay
  survives restarts and budget-window changes. Pending/uncertain jobs never
  expire or re-submit automatically. Invalid successful responses retain a
  reservation for reconciliation because they may already have been billed.
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

## Exact activation blockers

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
python -m unittest discover -s server/images/tests -v
flutter test test/image_studio_test.dart test/image_tools_integration_test.dart
```

Fixtures are explicitly fictional test backend IDs and use synthetic image
bytes; tests never submit paid upstream jobs. The server integration suite
exercises the actual FastAPI boundary, InferHub adapter, auth/key lifecycle,
catalog projection, persistent ledger, decimal discount, concurrency, retries,
edit capability filtering and malformed responses.
