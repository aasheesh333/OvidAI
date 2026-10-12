# Image model capability cards and capability-based routing

The owner adds any image model to LiteLLM (model name + base URL/params).
Nothing else is configured by hand: the gateway builds a capability **card**
for the model in the background, publishes a public projection to the app, and
routes each image request only to models whose card says they can do the task.

## How a new LiteLLM image model flows through

1. **Add model** in the LiteLLM dashboard (`mode: image_generation`).
2. **Discovery** (`_Discovery`, `GET /model/info`, cached 30 s) lists it and
   computes its **fingerprint** = sha256(model name + `litellm_params.model` +
   `api_base` (trailing `/` ignored) + `custom_llm_provider`). API keys are never
   part of it and never stored.
3. Until a card exists the model is **generate-only at 1024x1024** (no edit).
   Request paths only read cards from memory; they never probe or discover.
4. The background worker (one thread, `CardManager.tick`) sees a new/changed
   fingerprint and runs:
   * **Static extraction** (`extraction.py`, no paid call) from `model_info`
     (`mode`, `supported_endpoints` such as `/v1/images/edits`,
     `supported_modalities`, `output_cost_per_image`), the raw LiteLLM cost map
     (optional `OVID_IMAGE_COSTMAP_URL`), the provider's own models API at
     `<api_base>/models` when it exists (OpenRouter-style
     `architecture.input_modalities/output_modalities`; replicate/fal/HF-style
     `input_schema.properties` such as `mask`, `image`, `aspect_ratio`) and
     low-confidence model-family name hints. Result: card `state=inferred`,
     published immediately.
   * **Active probes** (`probes.py`, only if `OVID_PROBE_KEY` is set): generate at
     the default size and up to `OVID_PROBE_MAX_SIZES` candidate sizes, edit with
     a synthetic 64x64 PNG, inpaint (alpha mask), multi-image (2 inputs),
     transparent background (verifies a real alpha channel comes back),
     variations (n=2) and a short text-in-image run; latency and cost are
     measured (`x-litellm-response-cost`, fallback: probe-key `/key/info` spend
     delta). Result: card `state=probed`.
5. The card is stored (SQLite, with history) and the **public card** appears in
   `GET /v1/images/capabilities` with a new `catalog_hash`/ETag.
6. Re-probe: fingerprint change, `OVID_PROBE_TTL_SECONDS` (default 7 days) or
   `POST /images/admin/reprobe`.

Probe results are `unsupported` (model refused the operation: capability set
absent, `source: probed`), `transient` (timeout, 429, 5xx, no_capacity: **no
verdict**, previous value kept, card not promoted to `probed`, retry with
exponential backoff 5 min .. 6 h) or `inconclusive` (e.g. "image too small":
treated like transient). Auth/budget errors abort the run.

Probe budget: concurrency 1 (process-wide lock), per-probe cap
(`OVID_PROBE_MAX_USD`, default 0.50; a probe above it stops the run), daily cap
(`OVID_PROBE_DAILY_USD`, default 5.00, summed from the probe log), plus the
LiteLLM-enforced `max_budget` of the dedicated probe key (the real backstop).

## Card schema (v1, private, JSON)

```
schema, model (internal), slug (ovid-image:img-xxxxxx), fingerprint,
state: default | declared | inferred | probed
operations: {generate, edit, inpaint, outpaint, reference_style, multi_image,
             remove_background, transparent_output, upscale, variations}
            each {supported: true|false|null, source: declared|inferred|probed,
                  confidence, [max_inputs] [max_n]}
sizes: {native[], aspect_ratios[], source, confidence}
max_n, input {max_images,max_bytes,max_pixels,formats}, output_formats
text_rendering {level none|ok|good, source, confidence}
latency_ms_p50, measured_cost_usd (private), cost_tier low|med|high (relative),
quality low|med|high, tags[], probed_at, static{sources..}, probes[] (results)
```

Trust order when merging: probed > declared > inferred. Only `supported: true`
counts for routing.

## Routing (`routing.py`, pure functions)

`pick_backends(task, cards, unavailable)`:

1. **Hard filters**: operation (generate/edit/inpaint/outpaint/reference_style/
   multi_image/remove_background/upscale), `mask` -> inpaint, >1 input ->
   multi_image (and enough `max_inputs`), `transparent_background` ->
   transparent_output, `size` in native sizes, `aspect_ratio` in native ratios.
2. **Skip** models in capacity cooldown.
3. **Score** by `preference` (`balanced|quality|speed|cost`) from quality tier,
   measured latency and cost tier; `requirements.text_rendering` adds a strong
   bonus for `text: good`; probed cards get a small bonus. Ties keep discovery
   order. Fallback on capacity refusal walks the ranked list; ledger,
   idempotency and "never resubmit an ambiguous job" semantics are unchanged.

Explicit `model` slug that cannot do the task -> `422 unsupported_image_operation`
with `error.alternatives` (slugs) and `error.unsupported` (missing capability
keys), before admission, so nothing is reserved or charged.

## API

* `GET /v1/images/capabilities` (authenticated, as before) now also returns
  `schema: 2`, `catalog_hash`, `models: [public cards]` and sends
  `ETag: "<catalog_hash>"`; `If-None-Match` -> `304`. The legacy
  `operations` map is kept for old app builds. A public card: `slug`, `tags`,
  `operations`, `sizes`, `aspect_ratios`, `max_n`, `input.max_images`,
  `output_formats`, `text_rendering`, `quality`, `speed`, `latency_p50_s`,
  `cost_tier`, `verified`. It never contains provider names, base URLs, internal
  model names, fingerprints or prices.
* `POST /v1/images/generations|edits`: `model` is `ovid-image` (auto, the old
  alias) or `ovid-image:<slug>`; optional `preference`, `requirements`
  `{operation, aspect_ratio, transparent_background, text_rendering}`; edits
  also take `mask` and `images` (extra references) as data URLs. The response
  has `model_slug`; the receipt has `model` (public slug of the model that
  served it).
* `GET /images/admin/cards`, `POST /images/admin/reprobe {"model": name|slug}`:
  `Authorization: Bearer <LITELLM_MASTER_KEY>`; full cards incl. internal names,
  probe results, history and 24 h probe spend.

## Environment

| var | default | meaning |
|---|---|---|
| `OVID_PROBE_KEY` | empty | dedicated internal LiteLLM key; empty = static cards only |
| `OVID_PROBE_MAX_USD` | 0.50 | per-probe spend cap |
| `OVID_PROBE_DAILY_USD` | 5.00 | daily probe budget |
| `OVID_PROBE_MAX_SIZES` | 4 | sizes tried per model |
| `OVID_PROBE_TTL_SECONDS` | 604800 | periodic re-probe |
| `OVID_PROBE_INTERVAL_SECONDS` | 60 | worker poll interval |
| `OVID_IMAGE_CARDS_DB` | `<dir of OVID_IMAGE_DB>/ovid-image-cards.sqlite` | card store |
| `OVID_IMAGE_COSTMAP_URL` | empty | optional raw LiteLLM cost-map JSON |
| `INFERHUB_API_KEY` | empty | provider key for DIRECT edits; empty = edits unsupported (see below) |
| `OVID_IMAGE_DIRECT_EDIT_HOSTS` | `api.inferhub.dev` | comma list of hosts direct edits may call (https only; must equal the discovered `api_base` host) |
| `OVID_IMAGE_EDIT_COST_USD` | `OVID_IMAGE_MAX_UPSTREAM_USD` (1.00) | flat upstream price a direct edit settles at (clamped to the bound) |

Probe key: create a LiteLLM team `ovid-image-probe` with `max_budget` (e.g. 20),
and a key in that team allowed only the image models, with its own `max_budget`
and `budget_duration`; export it as `OVID_PROBE_KEY`.

## Edits go directly to the provider (JSON), not through LiteLLM

InferHub documents `POST /v1/images/edits` as `application/json` only (`model,
prompt, image` = one `data:` URL, `size, n, quality, response_format`). LiteLLM
can only forward edits as multipart/form-data, which InferHub rejects with
`400 body must be JSON`. So for edits the gateway calls
`<litellm_params.api_base>/images/edits` itself with `Authorization: Bearer
$INFERHUB_API_KEY` and body (built by `adapters.request_shape`)

```json
{"model": "cb/gpt-image-2", "prompt": "...", "size": "1024x1024", "n": 1,
 "response_format": "b64_json", "image": "data:image/png;base64,..."}
```

The provider model id is `litellm_params.model` without a leading `openai/`.
Generations still go through LiteLLM. Guards: https only, host must be in
`OVID_IMAGE_DIRECT_EDIT_HOSTS` and come from the discovered `api_base`, no
redirects, no userinfo/ports/query. Provider errors map exactly like
generation (capacity cooldown on `no_capacity`, pre-provider refusal codes,
everything else ambiguous -> request stays `unknown`, never resubmitted).

**Cards.** Discovery tags each model `edit_transport = direct | none`
(part of the card fingerprint, so toggling the key re-extracts and re-probes).

* `direct`: `edit` supported (declared, later probed); `inpaint`, `multi_image`,
  `outpaint`, `reference_style`, `remove_background` are false (provider
  contract); transparent edits are refused. Masks / extra images / transparent
  edits get `422 unsupported_image_operation` with alternatives BEFORE
  admission and charging, so the app stops offering `mask_path` /
  `reference_paths`.
* `none` (no key, host not allowlisted, bad `api_base`): `edit` is false for
  the model; edit requests are a clean 422 and the key-gap is logged once.

**Probe.** The edit probe uses the same direct path with a 64x64 synthetic PNG,
one call, skipped if the flat edit price exceeds `OVID_PROBE_MAX_USD`. Any HTTP
400 that is not the structured `unsupported_modality` / `not_an_image_model`
code (and any 404/422/other) is `inconclusive`, never `unsupported`, so a
malformed probe cannot mark edit absent. No mask / multi-image probes in this
mode. Without the key the edit probe is not run.

**Billing.** LiteLLM never sees direct calls, so key-spend deltas cannot settle
them. A direct edit settles upstream at `OVID_IMAGE_EDIT_COST_USD` (default: the
owner-enforced `OVID_IMAGE_MAX_UPSTREAM_USD` bound, so users are never
under-charged and never over the bound). If the provider response carries a
usable `usage.cost`, that is used instead, capped at the bound. The user is
debited `0.30 x` that amount through the normal ledger.

**Dedicated key.** In the InferHub dashboard create a separate API key just for
Ovid edits with a low spend limit (e.g. a few USD/day), no other scopes, and
rotate it by changing the env var. The key is only read from the environment,
only sent in the Authorization header to the allowlisted host, and never logged,
stored in cards or returned.

## Failure modes

* Probe key missing/blocked/over budget: cards stay `inferred` (static); routing
  still works with their declared/inferred abilities; admin cards show
  `probe_stop`.
* Provider down during probing: transient, backoff, nothing marked absent.
* Model removed from LiteLLM: disappears from discovery and the catalog.
* Fingerprint change: the old card is not trusted (default card) until the
  background run rewrites it; history keeps the old one.
* Wrong static guess: the next probe overrides it (`source: probed`).
* Gateway restart: cards load from SQLite.

## App side

`lib/core/image_capabilities.dart` parses the cards;
`ImageStudio.refresh` does a conditional GET (ETag), `ensureFresh` makes no
network call while the 5-minute cache is fresh. `generate_image` / `edit_image`
are built from the cards: capability table, `model` enum (omit for auto),
`preference`, `requirements`, `mask_path`, `reference_paths`, plus guidance that
crop/resize/rotate/convert are local (no model) and non-native aspect ratios are
generated at the nearest size and cropped locally. Old gateways (no `models`)
keep the legacy tool schema.
