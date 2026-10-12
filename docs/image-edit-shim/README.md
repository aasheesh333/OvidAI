# Image edit shim (img-edit-shim)

## Why
Some OpenAI-compatible image providers (InferHub) accept edits only as
`application/json` with a single `data:` URL image. LiteLLM sends edits as
`multipart/form-data`, and InferHub answers 400 `body must be JSON`. Provider API
keys must stay inside LiteLLM, so Ovid cannot call the provider directly. The shim
sits between LiteLLM and the provider, converts the edit in flight, and forwards
LiteLLM's own `Authorization` header. The shim has no key, stores nothing, and
logs only method, host, path, status and latency. The gateway needs no change.

## Architecture
```
Ovid gateway --multipart edit--> LiteLLM --(api_base=http://img-edit-shim:8099/api.inferhub.dev/v1)-->
   img-edit-shim:8099 --JSON edit / transparent proxy, same Authorization--> https://api.inferhub.dev/v1
```
Code: `server/images/editshim/shim.py`. Compose block: `server/images/editshim/compose.snippet.yml`.
Switch script: `ops/image-edit-shim/switch_api_base.py`.

## Behaviour
* `/{upstream_host}/{path}` for any method. The host must be in `SHIM_ALLOWED_HOSTS`
  (default `api.inferhub.dev`) and be a plain lowercase DNS name (no IP, port, userinfo).
  It is always called over https and redirects are never followed. Otherwise 403 JSON.
* `POST /<host>/v1/images/edits` multipart, host in `SHIM_JSON_EDIT_HOSTS`: body becomes
  `{model, prompt, [size], n (default 1), response_format (default b64_json), [quality], image: "data:<mime>;base64,..."}`.
  `background` is ignored. A `mask` part or more than one image returns 400
  `unsupported_modality` without calling the provider. Probes record inpaint and
  multi_image as unsupported.
* Everything else is proxied unchanged (method, path, query, body, status, headers, body),
  including provider errors such as 503 `no_capacity` and `Retry-After`.
  Hop-by-hop headers are dropped.
* Limits (env): `SHIM_MAX_REQUEST_BYTES` and `SHIM_MAX_RESPONSE_BYTES` (25 MB, 413 or 502),
  `SHIM_UPSTREAM_TIMEOUT` (120 s, 504), `SHIM_MAX_CONCURRENT` (32, 503 `shim_busy`).
  `GET /healthz` makes no upstream call. There is no CORS.
* Network: internal docker network only. Do NOT publish port 8099.

## Deploy order
1. Build and start the shim (`docker build -f server/images/editshim/Dockerfile -t img-edit-shim .`; merge the compose block; `up -d img-edit-shim`), on the network LiteLLM shares.
2. Verify: `docker exec <litellm> python -c "import urllib.request;print(urllib.request.urlopen('http://img-edit-shim:8099/healthz').read())"` or the container healthcheck is healthy.
3. Dry-run: `python ops/image-edit-shim/switch_api_base.py` (reads `LITELLM_BASE`, `LITELLM_MASTER_KEY` from env or `.env`). Review the plan.
4. Switch ONE model: `... --apply --model-name <name>`. The original api_base is recorded in `image-edit-shim-backup.json` (mode 600, no keys).
5. Test through LiteLLM with a throwaway virtual key: one generation and one edit (single image, no mask). Check the shim log shows status 200 for both.
6. Switch the rest: `... --apply`.

## LiteLLM update call (key preservation)
`PATCH /model/{model_id}/update` with `{"litellm_params": {"api_base": "<url>"}}`. This is
LiteLLM's partial update (only supplied fields change, the stored encrypted key is kept).
`POST /model/update` is avoided because it can replace `litellm_params`, and `/model/info`
only returns a redacted key, so the key could not be re-sent. LiteLLM is not installed in
the dev venv, so this behaviour could not be read from source here. The script therefore
verifies it at runtime. After each update it re-reads `/model/info`, requires the model to
be listed with the new api_base and every other `litellm_params` field (including the
redacted key mask) unchanged, and otherwise restores api_base and aborts. This is why you
switch ONE model first and test it before switching the rest.

## Rollback
* `python ops/image-edit-shim/switch_api_base.py --revert --apply` restores the recorded originals (omit `--apply` to preview).
* If the shim is down, revert first. Stopping the shim alone does not restore service.
* Fallback: set api_base back by hand in the LiteLLM UI.

## Failure modes
* Shim down or unhealthy: image generation AND edits fail for every switched model (LiteLLM gets connection errors). Run with `restart: unless-stopped`, alert on health, revert on prolonged outage.
* 503 `shim_busy`: more than `SHIM_MAX_CONCURRENT` in flight. Raise the limit or add capacity.
* 504 `upstream_timeout` / 502 `upstream_error`: provider slow or unreachable.
* 403 `forbidden_host`: model api_base host not in `SHIM_ALLOWED_HOSTS`.
* 413 / 502 `upstream_response_too_large`: raise the caps.

## Monitoring
`docker logs img-edit-shim` shows `method=POST host=... path=/v1/images/edits status=200 latency_ms=...`.
Alert on healthcheck failures and on a rise in 5xx. Headers and bodies are never logged.

## Adding another provider/host
1. Add the host to `SHIM_ALLOWED_HOSTS` (and, if it takes JSON-only edits, to `SHIM_JSON_EDIT_HOSTS`).
2. If its JSON edit shape differs from InferHub's, add a function
   `adapter(headers, content_type, body) -> (extra_headers, json_bytes) | Response` and register it in
   `EDIT_ADAPTERS['host'] = adapter` in `shim.py`. Hosts without an entry use the InferHub-shaped default.
3. Providers that accept multipart edits need nothing beyond the allowlist and pass through.
4. Run `switch_api_base.py --allowed-hosts host1,host2` for their models.

## Tests
`python -m pytest server/images/editshim -q` (no network; fakes only).
