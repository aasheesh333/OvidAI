"""Provider-agnostic Ovid image routes mounted on the live mint FastAPI app.

Everything the operator can change lives in the LiteLLM dashboard: which image
models exist, their upstream provider base URL + key, and their price. This
module hardcodes NO provider, URL or model name. It discovers image-capable
models from the LiteLLM catalog and forwards each request to LiteLLM using the
caller's own per-user virtual key, so LiteLLM itself enforces the plan budget
(atomic, dashboard-owned) and bills the dashboard price.

Layered on top: the `ovid-image` public alias contract the app expects, the
0.30x discount, and a durable SQLite ledger for idempotency, dedup and receipts
(reused from server.images.service.Ledger).

Auth reuses the mint primitives (Google ID token, App Check, ban, per-UID key
ownership, tier/free-cap) via VerifierAuth — no firebase_admin, no second store.
"""
import base64
import hashlib
import json
import os
import re
import time
from contextlib import contextmanager
from decimal import Decimal

import httpx
from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

import mint
from server.images.service import (
    ALIAS, MAX_BYTES, ImageError, Ledger, SIZES, discounted, money, validate_image,
)
from server.images.verifier import VerifierAuth, mount_images

LITELLM_BASE = os.environ.get("LITELLM_BASE", "http://litellm:4000")
LITELLM_MASTER_KEY = os.environ["LITELLM_MASTER_KEY"]
DB_PATH = os.environ.get("OVID_IMAGE_DB", "/data/ovid-images.sqlite")
MAX_UPSTREAM_USD = Decimal(os.environ.get("OVID_IMAGE_MAX_UPSTREAM_USD", "1.00"))
HTTP_TIMEOUT = float(os.environ.get("OVID_IMAGE_TIMEOUT", "120"))
_CATALOG_TTL = 30.0


class _Backend:
    """A discovered image model; carries no provider identity."""
    __slots__ = ("model", "sizes", "edit")

    def __init__(self, model, sizes, edit):
        self.model, self.sizes, self.edit = model, tuple(sizes), edit


class _Discovery:
    """Image-capable models from the LiteLLM dashboard catalog (cached)."""

    def __init__(self):
        self._at = 0.0
        self._backends = []

    def backends(self):
        if time.time() - self._at < _CATALOG_TTL and self._backends:
            return self._backends
        found = []
        try:
            headers = {"Authorization": f"Bearer {LITELLM_MASTER_KEY}"}
            with httpx.Client(base_url=LITELLM_BASE, timeout=10) as client:
                response = client.get("/model/info", headers=headers)
            if response.status_code == 200:
                for row in response.json().get("data", []):
                    name = row.get("model_name") or ""
                    info = row.get("model_info", {}) or {}
                    mode = info.get("mode")
                    modality = info.get("output_modality")
                    if not name or (mode != "image_generation" and modality != "image"):
                        continue
                    # Dashboard models do not declare sizes reliably; advertise
                    # the documented contract sizes and let the upstream reject.
                    found.append(_Backend(name, SIZES, True))
        except Exception as error:  # noqa: BLE001
            print(f"image discovery: model/info error: {error}")
        self._at, self._backends = time.time(), found
        return found


def _user_key(uid):
    return mint.rds.get(f"user:{uid}:key")


def _key_spend(key_id):
    try:
        headers = {"Authorization": f"Bearer {LITELLM_MASTER_KEY}"}
        with httpx.Client(base_url=LITELLM_BASE, timeout=15) as client:
            response = client.get("/key/info", headers=headers, params={"key": key_id})
        if response.status_code == 200:
            return float(response.json().get("info", {}).get("spend", 0.0) or 0.0)
    except Exception as error:  # noqa: BLE001
        print(f"image cost: key/info error: {error}")
    return None


class LiteLLMImageService:
    def __init__(self, discovery, ledger):
        self.discovery, self.ledger = discovery, ledger

    @property
    def backends(self):
        return self.discovery.backends()

    def catalog(self):
        available = bool(self.backends)
        operations = {"generate": list(SIZES), "edit": list(SIZES)} if available else {"generate": [], "edit": []}
        return {"model": ALIAS, "operations": operations}

    def execute(self, account, request, operation, body, budget, *, budget_window="default"):
        if not isinstance(request, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{8,128}", request):
            raise ImageError(400, "invalid_request_id")
        if operation not in ("generate", "edit") or not isinstance(body, dict):
            raise ImageError(400, "invalid_image_request")
        allowed = {"model", "prompt", "size"} | ({"image"} if operation == "edit" else set())
        if set(body) - allowed or body.get("model") != ALIAS:
            raise ImageError(400, "invalid_image_request")
        prompt, size = body.get("prompt"), body.get("size", "1024x1024")
        if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 8000 or size not in SIZES:
            raise ImageError(400, "invalid_image_request")
        image_b64 = image_mime = None
        if operation == "edit":
            match = re.fullmatch(r"data:(image/(?:png|jpeg|webp));base64,([A-Za-z0-9+/=]+)", body.get("image") or "")
            if not match:
                raise ImageError(400, "invalid_image")
            image_mime, image_b64 = match[1], match[2]
            validate_image(image_b64, image_mime)
        candidates = self.backends
        if not candidates:
            raise ImageError(503, "image_unavailable")
        fingerprint = hashlib.sha256(
            json.dumps([operation, body], sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        replay = self.ledger.begin(account, request, fingerprint,
                                   discounted(MAX_UPSTREAM_USD), budget, budget_window)
        if replay is not None:
            return replay
        key = _user_key(account)
        if not key:
            raise ImageError(401, "sign_in_required")
        key_id = mint.rds.get(f"user:{account}:keyid")
        last_status = None
        for backend in candidates:
            self.ledger.receipt(account, request)
            before = _key_spend(key_id) if key_id else None
            try:
                result = self._forward(key, backend, operation, prompt, size, image_b64, image_mime)
            except _NotServed as error:
                last_status = error.status
                continue  # model not served / not found: nothing was billed
            except Exception:
                raise self._unknown(account, request, fingerprint) from None
            after = _key_spend(key_id) if key_id else None
            actual = None
            if before is not None and after is not None and after > before:
                actual = money(str(after - before))
            if actual is None or actual <= 0:
                # No dashboard price recorded the spend: keep the reservation
                # for reconciliation rather than fabricating a charge.
                raise self._unknown(account, request, fingerprint)
            try:
                return self.ledger.settle(account, request, actual, result)
            except ImageError:
                raise
            except Exception:
                raise self._unknown(account, request, fingerprint) from None
        self.ledger.fail(account, request)
        raise ImageError(502 if last_status else 503, "image_unavailable",
                         receipt=self.ledger.receipt(account, request))

    def _forward(self, key, backend, operation, prompt, size, image_b64, image_mime):
        headers = {"Authorization": f"Bearer {key}"}
        with httpx.Client(base_url=LITELLM_BASE, timeout=HTTP_TIMEOUT, follow_redirects=False) as client:
            if operation == "generate":
                response = client.post("/v1/images/generations", headers=headers, json={
                    "model": backend.model, "prompt": prompt, "size": size,
                    "n": 1, "response_format": "b64_json",
                })
            else:
                raw = base64.b64decode(image_b64)
                response = client.post(
                    "/v1/images/edits", headers=headers,
                    data={"model": backend.model, "prompt": prompt, "size": size, "n": "1"},
                    files={"image": ("image.png", raw, image_mime)},
                )
        if response.status_code in (400, 404):
            raise _NotServed(response.status_code)
        if response.status_code != 200:
            raise ImageError(502, "image_unavailable")
        data = response.json()
        rows = data.get("data") if isinstance(data, dict) else None
        if not isinstance(rows, list) or len(rows) != 1 or not rows[0].get("b64_json"):
            raise ImageError(502, "invalid_image_response")
        encoded = rows[0]["b64_json"]
        mime = validate_image(encoded)
        return {"model": ALIAS, "data": [{"b64_json": encoded, "mime_type": mime}]}

    def _unknown(self, account, request, fingerprint):
        receipt = {"account_id": account, "request_id": request,
                   "fingerprint": fingerprint, "state": "unknown", "charged": None}
        try:
            self.ledger.unknown(account, request)
            receipt = self.ledger.receipt(account, request)
        except Exception:  # noqa: BLE001
            pass
        return ImageError(409, "image_request_pending", receipt=receipt)


class _NotServed(Exception):
    def __init__(self, status):
        self.status = status


@contextmanager
def admission(identity):
    """Budget context for the mount. LiteLLM enforces the per-user key budget on
    the forwarded call; this supplies the ledger's per-request reservation bound
    from the same plan window and subtracts current text spend."""
    uid = identity.uid
    tier = mint.effective_tier(uid)
    budget, window = mint.tier_budget(uid, tier)
    if tier == "free" and mint.free_cap_remaining(uid) <= 0:
        raise ImageError(402, "image_limit_reached")
    remaining = float(budget) - (_key_spend(mint.rds.get(f"user:{uid}:keyid")) or 0.0)
    if remaining <= 0:
        raise ImageError(402, "image_limit_reached")
    yield (f"{uid}:{window}", Decimal(str(remaining)))


def mount():
    if getattr(mint.app.state, "ovid_images_mounted", False):
        return
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    service = LiteLLMImageService(_Discovery(), Ledger(DB_PATH))
    mount_images(mint, service, admission=admission, auth=VerifierAuth(mint))
    mint.app.state.ovid_images_mounted = True
    print(f"Ovid images mounted: alias={ALIAS} image_models={[b.model for b in service.backends]}")


try:
    mount()
except Exception as error:  # noqa: BLE001 - never block mint startup on images
    print(f"Ovid images mount failed (mint continues): {error}")
