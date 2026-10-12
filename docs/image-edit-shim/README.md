# Image edit shim (img-edit-shim) and provider onboarding

## Why
Some OpenAI-compatible image providers (InferHub) accept edits only as `application/json`
with a `data:` URL image. LiteLLM sends edits as `multipart/form-data`, and such a
provider answers 400 `body must be JSON`. Provider API keys must stay inside LiteLLM, so
Ovid cannot call the provider directly. The shim sits between LiteLLM and the provider,
converts the edit in flight and forwards LiteLLM's own `Authorization` header. It has no
key, stores nothing, logs only method, host, path, status and latency.

```
Ovid gateway --multipart edit--> LiteLLM --(api_base=http://img-edit-shim:8099/<host>/v1)-->
   img-edit-shim:8099 --JSON edit | transparent proxy, same Authorization--> https://<host>/v1
```
Code: `server/images/editshim/{shim,profiles}.py`. Compose block: `compose.snippet.yml`.
Scripts: `ops/image-edit-shim/{onboard_provider,check_provider,switch_api_base}.py`.

## Add a new image provider (runbook)
No code change, no restart, no secret outside LiteLLM.

1. **LiteLLM**: add the model with its base URL and key (`mode: image_generation`).
2. **Price** (mandatory): set the model's price in LiteLLM `model_info`
   (`input_cost_per_token` / `output_cost_per_token`, or `output_cost_per_image`). Unpriced
   models are never served to users (see docs/image-capabilities/README.md). After a price
   change: `POST /images/admin/refresh-prices` or wait about 5 minutes.
3. **Check**: `python ops/image-edit-shim/check_provider.py <model_name>` (read-only). It
   prints discovery, edit path (standard multipart vs shim), absent price fields, card,
   last probe failures, probe budget left and numbered next steps.
4. **Only if its edits need JSON** (symptom `body must be JSON`):
   `python ops/image-edit-shim/onboard_provider.py --host api.newprovider.com --json-edit [profile flags]`
   (dry-run); review; add `--apply`. Providers that accept standard multipart need no shim:
   `onboard_provider.py --host H --apply` just forces a re-probe.
5. **Verify** the card the script prints (state `probed`, ops, sizes, `priced: True`), or
   re-run `check_provider.py <model_name>`.

Profile flags (all optional; defaults are the InferHub shape):
`--image-format data_url|base64|url_not_supported`, `--image-field`, `--image-array`,
`--max-images N`, `--mask-field`, `--passthrough a,b`, `--model-field`, `--prompt-field`,
`--response-format-default b64_json|url|none`, `--drop-fields a,b`.

Environment for the scripts (env or `.env`): `LITELLM_BASE`, `LITELLM_MASTER_KEY`,
`OVID_GATEWAY_BASE` (gateway URL serving `/images/admin/*`), `SHIM_PROVIDERS_FILE`.
The master key is only used as the Bearer for LiteLLM and the gateway admin API. It is
never printed. Provider keys are never read or sent: the only LiteLLM write is
`PATCH /model/{id}/update {"litellm_params": {"api_base": ...}}`, followed by a re-read of
`/model/info` that must show every other field unchanged (otherwise api_base is restored).

### Example
```
$ onboard_provider.py --host api.newprovider.com --json-edit --apply
APPLY onboarding api.newprovider.com
  model np-image (n1) api_base=https://api.newprovider.com/v1
write providers file /opt/ovid-gateway/shim-providers/providers.json: api.newprovider.com -> {...}
switch np-image (n1): https://api.newprovider.com/v1 -> http://img-edit-shim:8099/api.newprovider.com/v1
reprobe np-image: HTTP 202 (queued)
card np-image:
  card state: probed   ops: edit, generate   sizes: 1024x1024
  cost: $0.0400   priced: True   cost source: per_image
probe budget: spent_24h=$0.5 cap=$5.0
rollback:
  restore .../providers.json.bak (or remove the "api.newprovider.com" entry; the shim reloads it by itself)
  switch_api_base.py --revert --apply --backup image-edit-shim-backup.json --model-name np-image
```

## Providers file (hot reload)
`SHIM_PROVIDERS_FILE` (compose mounts the DIRECTORY `/opt/ovid-gateway/shim-providers` at
`/providers`; the script replaces the file atomically). The shim re-reads it whenever its
mtime/size changes, with no restart. Env `SHIM_ALLOWED_HOSTS` / `SHIM_JSON_EDIT_HOSTS`
(default `api.inferhub.dev`, InferHub default profile) stay the base; file entries override
per host. Invalid file: the last good config stays and a WARNING is logged. File absent:
env defaults only.

```json
{"version": 1, "hosts": {
  "api.newprovider.com": {
    "allowed": true,
    "json_edit": true,
    "profile": {
      "image_field": "images",
      "image_format": "base64",
      "image_array": true,
      "max_images": 4,
      "mask_field": null,
      "extra_fields_passthrough": ["quality"],
      "model_field": "model",
      "prompt_field": "prompt",
      "response_format_default": "b64_json",
      "drop_fields": []}},
  "api.plain.com": {"allowed": true, "json_edit": false}}}
```
* `image_format`: `data_url` (`data:<mime>;base64,..`), `base64` (raw), `url_not_supported`
  (provider only takes URLs: every edit is refused with `unsupported_modality`; the gateway
  never fetches or hosts URLs).
* `image_array`: send a list; `max_images` bounds it (forced to 1 when false).
* `mask_field`: null = masks refused with 400 `unsupported_modality` (probes record inpaint
  unsupported); otherwise the mask is encoded like images under that field.
* `extra_fields_passthrough`: other form fields copied when present (default `quality`).
* `response_format_default`: used when the client sent none; null omits the field.
* `drop_fields`: removed from the final body. Omitting `profile` = the InferHub default
  (byte-identical to the previous adapter). `allowed:false` blocks a host even if the env
  allows it. Hosts not listed anywhere stay 403: the explicit allowlist is the SSRF guard.
  Standard-multipart hosts (`json_edit:false`) pass through untouched.

Replies from converted edits are normalised as before: missing `usage` token fields are
added (LiteLLM would otherwise 500), provider values such as `usage.cost` are kept.

## Behaviour
* `/{upstream_host}/{path}` for any method; host must be allowlisted and a plain lowercase
  DNS name. Always https, redirects never followed; otherwise 403 JSON.
* Everything except converted edits is proxied unchanged (incl. 503 `no_capacity`, `Retry-After`).
* Limits (env): `SHIM_MAX_REQUEST_BYTES`/`SHIM_MAX_RESPONSE_BYTES` (25 MB), `SHIM_UPSTREAM_TIMEOUT`
  (120 s), `SHIM_MAX_CONCURRENT` (32). `GET /healthz`. Internal network only; never publish 8099.

## Deploy (first time) and rollback
1. `docker build -f server/images/editshim/Dockerfile -t img-edit-shim .` (copies `adapters.py`,
   `profiles.py`, `shim.py`); merge `compose.snippet.yml`; `up -d img-edit-shim`.
2. Check health; run `switch_api_base.py` / `onboard_provider.py` dry-runs; switch ONE model, test, then the rest.
3. Rollback: `switch_api_base.py --revert --apply` (revert BEFORE stopping the shim), or fix api_base by hand in the LiteLLM UI.

## Troubleshooting
| Symptom | Cause | Fix |
|---|---|---|
| Edit fails `body must be JSON` | provider needs JSON, api_base goes straight to it | `onboard_provider.py --host H --json-edit --apply` |
| 403 `forbidden_host` | host not allowlisted | add it via `onboard_provider.py` (providers file), not by trusting hosts |
| Edit 400 `unsupported_modality` | mask / extra images / URL-only provider beyond the profile | expected; probes mark it unsupported. Raise `max_images`/set `mask_field` if the provider supports it |
| Edit 400/422 from provider after onboarding | wrong profile field names/format | adjust `onboard_provider.py` flags (re-run `--apply`), shim reloads instantly |
| Image stays `pending` | model unpriced or cost undeterminable | set price in LiteLLM; `check_provider.py` shows absent fields |
| Card stuck `inferred` | probe failing/transient/over budget | `check_provider.py` lists probe errors and budget; fix, then reprobe |
| "probe budget exhausted" | 24h spend reached `OVID_PROBE_DAILY_USD` | raise cap or wait; static card still routes generation if priced |
| 503 `no_capacity` / `image_capacity_unavailable` | provider has no capacity (cooldown) | transient; wait, or add another model |
| 503 `shim_busy` | over `SHIM_MAX_CONCURRENT` | raise limit |
| 504/502 `upstream_*` | provider slow/unreachable | check provider |
| Providers file change ignored | file bind-mounted as single file (inode replaced) | mount the directory; check shim log for "providers file rejected" |

## Tests
`python -m pytest server/images/editshim -q` (no network; fakes only).
