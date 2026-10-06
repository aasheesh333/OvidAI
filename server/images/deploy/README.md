# Ovid image service — gateway deployment (mint-hosted)

Deploys the repository's `server.images` service on the **live mint FastAPI app**
and routes `/v1/images/*` + `/v1/models` to it, so the app's image contract
(`ovid-image`) works in production with the 0.30x discount, durable receipts and
idempotency — **without** hardcoding any provider.

## Design

- **Fully dashboard-customizable.** The operator adds image models in the
  LiteLLM dashboard (any provider base URL + key + price + name, `mode:
  image_generation`). This service discovers image-capable models from LiteLLM
  (`GET /model/info`) and forwards each request to LiteLLM using the caller's own
  per-user virtual key. No provider URL, model name or key is hardcoded here.
- **Budget authority = LiteLLM.** Because the request is forwarded with the
  user's key, LiteLLM itself enforces the plan window budget atomically and bills
  the dashboard price. The service layers the `ovid-image` alias, the 0.30x
  discount, and a durable SQLite ledger (idempotency, dedup, receipts) on top.
- **No `firebase_admin`.** Auth reuses the mint app's own primitives (Google ID
  token via JWKS, App Check, ban, per-UID key ownership, tier/free-cap).
- **Hidden from users.** `/v1/models` is served by the service and strips the
  private image models; only chat models appear in the app picker. The agent
  uses the image models through the `ovid-image` alias.

## Files

- `images_gateway.py` — the mount module (provider-agnostic; imports `mint`).
- `Dockerfile` — the mint image (mint.py + this module + vendored `server/images`).
- `Caddyfile.snippet` — the Caddy route that must precede the LiteLLM `/v1/*` rule.

## Deploy

1. **Vendor the image package** into the mint build context:

   ```sh
   cd /opt/ovid-gateway/verifier
   rm -rf server && mkdir -p server
   cp -r /path/to/OvidAI/server/images server/images
   touch server/__init__.py server/images/__init__.py
   rm -rf server/images/tests server/images/__pycache__
   ```

   The gateway mount imports only the provider-agnostic modules
   (`service`, `verifier`, `catalog`, `adapters`); any other module in the
   package is unused by this path and harmless if present.

2. **Copy the deploy files** next to `mint.py`:

   ```sh
   cp server/images/deploy/images_gateway.py /opt/ovid-gateway/verifier/
   cp server/images/deploy/Dockerfile          /opt/ovid-gateway/verifier/
   ```

3. **Hook the mint app** — append to the live `mint.py` (guarded so a missing
   dependency never blocks mint startup):

   ```python
   try:
       import images_gateway  # mounts /v1/images/* + /v1/models on this app
   except Exception as _image_mount_error:  # noqa: BLE001
       print(f"images_gateway import skipped: {_image_mount_error}")
   ```

4. **Persist the ledger** — give the mint service a volume for the SQLite
   ledger (`OVID_IMAGE_DB`, default `/data/ovid-images.sqlite`) in
   `docker-compose.yml`:

   ```yaml
   mint:
     volumes:
       - mintdata:/data
   volumes:
     mintdata:
   ```

5. **Route in Caddy** — paste `Caddyfile.snippet` into the public site block
   (before the LiteLLM `/v1/*` rule), then reload.

6. **Build and start**:

   ```sh
   cd /opt/ovid-gateway
   docker compose build mint
   docker compose up -d mint
   ```

## Add image models (dashboard)

LiteLLM dashboard → **Models + Endpoints → Add Model**:

- **Provider:** an OpenAI-compatible custom provider.
- **Base URL + API key:** any provider the operator chooses.
- **Mode:** `image_generation`.
- **Model name:** any name.
- **Price:** the price to bill (the app charges `price × 0.30`).

The service discovers it within ~30s (catalog cache). If no price is set, a
request is recorded `unknown` rather than fabricating a charge.

## Verify

```sh
# Public capability route must be 401 (unauthenticated), not 404.
curl -s -o /dev/null -w '%{http_code}\n' \
  https://cloud.dhanuksoftwares.com/v1/images/capabilities

# Mint logs show the discovered image models.
docker compose logs mint | grep 'Ovid images mounted'

# /v1/models (with the master key) must NOT list image models.
curl -s -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  http://127.0.0.1:8090/v1/models
```

## Security

- No provider URL, model id or API key is stored in this directory; the operator
  owns them in the LiteLLM dashboard.
- Only `LITELLM_MASTER_KEY` (from the mint environment) is read, for discovery
  and spend reads. Paid image calls use the caller's own scoped virtual key.
- The mount is idempotent and wrapped so image faults never block mint startup.
