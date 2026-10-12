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
import logging
import math
import os
import re
import time
from collections import OrderedDict
from contextlib import contextmanager
from decimal import Decimal
from threading import Lock

import httpx
from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

import mint
from server.images.service import (
    ALIAS, MAX_BYTES, ImageError, Ledger, SIZES, discounted, money, validate_image,
    capacity_retry_seconds,
)
from server.images.adapters import PRE_PROVIDER_REFUSAL_CODES, structured_error_code
from server.images.admin import mount_admin
from server.images.capabilities import (
    PUBLIC_SCHEMA, catalog_hash, default_card, legacy_card, public_card,
)
from server.images.cardmanager import CardManager, Discovered
from server.images.cardstore import CardStore
from server.images import costing
from server.images.directedit import DirectEdit
from server.images.probes import LiteLLMProbeTransport, ProbeRunner
from server.images.routing import alternatives, parse_model, pick_backends, task_from_request, missing
from server.images.verifier import VerifierAuth, mount_images

LITELLM_BASE = os.environ.get("LITELLM_BASE", "http://litellm:4000")
LITELLM_MASTER_KEY = os.environ["LITELLM_MASTER_KEY"]
DB_PATH = os.environ.get("OVID_IMAGE_DB", "/data/ovid-images.sqlite")
MAX_UPSTREAM_USD = Decimal(os.environ.get("OVID_IMAGE_MAX_UPSTREAM_USD", "1.00"))
HTTP_TIMEOUT = float(os.environ.get("OVID_IMAGE_TIMEOUT", "120"))
# Capability cards (background extraction + probes; see docs/image-capabilities).
CARDS_DB = os.environ.get("OVID_IMAGE_CARDS_DB", os.path.join(os.path.dirname(DB_PATH), "ovid-image-cards.sqlite"))
PROBE_KEY = os.environ.get("OVID_PROBE_KEY", "")          # dedicated internal key; empty = static cards only
PROBE_PER_CALL_USD = float(os.environ.get("OVID_PROBE_MAX_USD", "0.50"))
PROBE_DAILY_USD = float(os.environ.get("OVID_PROBE_DAILY_USD", "5.00"))
PROBE_MAX_SIZES = int(os.environ.get("OVID_PROBE_MAX_SIZES", "4"))
PROBE_TTL = float(os.environ.get("OVID_PROBE_TTL_SECONDS", str(7 * 24 * 3600)))
PROBE_INTERVAL = float(os.environ.get("OVID_PROBE_INTERVAL_SECONDS", "60"))
# Edits bypass LiteLLM (it can only send multipart; the provider accepts JSON only).
# Needs INFERHUB_API_KEY; see server/images/deploy/README.md. Never logged/returned.
DIRECT_EDIT = DirectEdit.from_env(MAX_UPSTREAM_USD, HTTP_TIMEOUT)
COSTMAP_URL = os.environ.get("OVID_IMAGE_COSTMAP_URL", "")  # optional raw LiteLLM cost-map JSON
_CATALOG_TTL = 30.0
_MAX_COOLDOWNS = 256
_LOG = logging.getLogger(__name__)


def _capacity_rejected(response, model):
    """Recognize only the upstream's explicit pre-dispatch no-capacity contract.

    Generic 5xx, timeouts and proxy HTML are ambiguous and must never trigger a
    second paid attempt. LiteLLM sometimes wraps the structured upstream error
    in a message; accept only that exact, model-bound first line, not substrings.
    """
    if response.status_code != 503:
        return False
    try:
        error = response.json()['error']
        if not isinstance(error, dict):
            return False
        if error.get('type') == 'no_capacity' or error.get('code') == 'no_capacity':
            return True
        message = error.get('message')
        if not isinstance(message, str) or not message:
            return False
        return re.fullmatch(
            r'(?:litellm\.ServiceUnavailableError: )?'
            r'(?:ServiceUnavailableError: )?(?:OpenAIException - )?'
            r'no available provider for ' + re.escape(model) +
            r' \(all offers exhausted or in cooldown\); try again shortly',
            message.splitlines()[0],
        ) is not None
    except (ValueError, KeyError, TypeError):
        return False


class _Backend:
    """A discovered image model; carries no provider identity.

    `card` is the capability card (None for legacy callers: a card is then
    synthesized from the declared sizes/edit flag)."""
    __slots__ = ("model", "sizes", "edit", "card", "params")

    def __init__(self, model, sizes, edit, card=None, params=None):
        self.model, self.sizes, self.edit = model, tuple(sizes), edit
        self.card = card
        self.params = params or {}   # identity-only litellm_params (no credentials)


def _backend_card(backend):
    return getattr(backend, "card", None) or legacy_card(backend.model, backend.sizes, backend.edit)


def _backend_from_card(card):
    from server.images.capabilities import supports
    sizes = tuple((card.get("sizes") or {}).get("native") or ("1024x1024",))
    return _Backend(card["model"], sizes, supports(card, "edit"), card)


class _Discovery:
    """Image-capable models from the LiteLLM dashboard catalog (cached).

    Discovery only LISTS models. Capabilities come from cards the background
    CardManager fills; until a model has a card it is generate-only/1024x1024.
    """

    def __init__(self, manager=None, direct_edit=None):
        self.direct_edit = direct_edit
        self._at = 0.0
        self._found = []
        self.manager = manager

    def discovered(self, force=False):
        if not force and time.time() - self._at < _CATALOG_TTL and self._found:
            return self._found
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
                    params = row.get("litellm_params", {}) or {}
                    # Keep only identity fields; credentials are never stored.
                    identity = {k: params.get(k) for k in
                                ("model", "api_base", "custom_llm_provider") if params.get(k)}
                    direct = self.direct_edit or DIRECT_EDIT
                    identity["edit_transport"] = "direct" if direct.enabled_for(identity) else "none"
                    found.append(Discovered(name, identity, info))
        except Exception as error:  # noqa: BLE001
            print(f"image discovery: model/info error: {error}")
            if self._found:
                return self._found
        self._at, self._found = time.time(), found
        if self.manager is not None:
            self.manager.observe(found)
        return found

    def backends(self):
        found = self.discovered()
        if self.manager is None:
            return [_Backend(d.name, ("1024x1024",), False, default_card(d.name), d.params) for d in found]
        out = []
        for d in found:
            card = dict(self.manager.card(d.name, d.params))
            card["edit_transport"] = d.params.get("edit_transport")
            backend = _backend_from_card(card)
            backend.params = d.params
            out.append(backend)
        return out

    def params_of(self, model):
        return next((d.params for d in self._found if d.name == model), None)


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


def _fetch_model_info():
    headers = {"Authorization": f"Bearer {LITELLM_MASTER_KEY}"}
    with httpx.Client(base_url=LITELLM_BASE, timeout=15) as client:
        response = client.get("/model/info", headers=headers)
    if response.status_code != 200:
        raise RuntimeError("model/info unavailable")
    return costing.parse_model_info(response.json())


_PRICES = costing.PriceBook(_fetch_model_info, ttl=300.0)
SPEND_RETRY_SECONDS = float(os.environ.get("OVID_IMAGE_SPEND_RETRY_SECONDS", "1.5"))


class LiteLLMImageService:
    def __init__(self, discovery, ledger, *, clock=time.monotonic, direct_edit=None):
        self.discovery, self.ledger = discovery, ledger
        self.direct_edit = direct_edit
        self.clock = clock
        # Process-local, bounded negative readiness cache. Catalog refreshes do
        # not prove recovery. Only explicit no_capacity populates this cache.
        self._cooldowns = OrderedDict()
        self._cooldown_lock = Lock()

    @property
    def backends(self):
        return self.discovery.backends()

    def cards(self):
        from server.images.capabilities import assign_cost_tiers, clone, finalize
        cards = [clone(_backend_card(b)) for b in self.backends]
        assign_cost_tiers(cards)
        for card in cards:
            finalize(card)
        return cards

    def catalog(self):
        backends = self.backends
        delays = [self._retry_after(b.model) for b in backends]
        if delays and all(delays):
            raise ImageError(503, 'image_capacity_unavailable', retry_after_seconds=min(delays))
        cards = self.cards()
        public = [public_card(c) for c in cards]
        # Legacy field kept for app builds that predate model cards.
        operations = {op: sorted({size for c in public if op in c['operations'] for size in c['sizes']})
                      for op in ('generate', 'edit')}
        # Static routing support is not proof of usable provider capacity.
        return {"model": ALIAS, "operations": operations, "availability": "unknown",
                "schema": PUBLIC_SCHEMA, "catalog_hash": catalog_hash(public), "models": public}

    def _retry_after(self, model):
        with self._cooldown_lock:
            now = self.clock()
            for key, until in list(self._cooldowns.items()):
                if until <= now:
                    del self._cooldowns[key]
            until = self._cooldowns.get(model)
            return max(1, math.ceil(until - now)) if until is not None else 0

    def _capacity_refused(self, model, seconds):
        with self._cooldown_lock:
            until = self.clock() + capacity_retry_seconds(seconds)
            self._cooldowns[model] = max(until, self._cooldowns.get(model, until))
            self._cooldowns.move_to_end(model)
            while len(self._cooldowns) > _MAX_COOLDOWNS:
                self._cooldowns.popitem(last=False)

    def execute(self, account, request, operation, body, budget, *, budget_window="default"):
        if not isinstance(request, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{8,128}", request):
            raise ImageError(400, "invalid_request_id")
        if operation not in ("generate", "edit") or not isinstance(body, dict):
            raise ImageError(400, "invalid_image_request")
        allowed = {"model", "prompt", "size", "requirements", "preference"} | \
            ({"image", "mask", "images"} if operation == "edit" else set())
        if set(body) - allowed:
            raise ImageError(400, "invalid_image_request")
        try:
            slug = parse_model(body.get("model"))
            task = task_from_request(operation, body)
        except ValueError:
            raise ImageError(400, "invalid_image_request") from None
        prompt, size = body.get("prompt"), body.get("size", "1024x1024")
        if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 8000 or \
                (body.get("size") is not None and size not in SIZES and not (slug or task.size)):
            raise ImageError(400, "invalid_image_request")
        image_b64 = image_mime = mask_raw = None
        extra_images = []
        if operation == "edit":
            image_b64, image_mime = _data_url(body.get("image"))
            validate_image(image_b64, image_mime)
            if body.get("mask") is not None:
                m_b64, m_mime = _data_url(body["mask"])
                validate_image(m_b64, m_mime)
                mask_raw = base64.b64decode(m_b64)
            for extra in (body.get("images") or []):
                e_b64, e_mime = _data_url(extra)
                validate_image(e_b64, e_mime)
                extra_images.append((base64.b64decode(e_b64), e_mime))
        cards = self.cards()
        chosen = None
        if slug is not None:
            chosen = next((c for c in cards if c["slug"] == slug), None)
            if chosen is None or missing(chosen, task):
                # Nothing was admitted or charged yet: a clear, actionable 422.
                raise ImageError(422, "unsupported_image_operation", detail={
                    "model": slug, "alternatives": alternatives(task, cards),
                    **({"unsupported": missing(chosen, task)} if chosen else {"reason": "unknown_model"})})
            ranked = [chosen]
        else:
            ranked = pick_backends(task, cards)
            if not ranked:
                raise ImageError(422, "unsupported_image_operation", detail={"alternatives": []})
        by_model = {b.model: b for b in self.backends}
        candidates = [by_model[c["model"]] for c in ranked if c["model"] in by_model]
        slugs = {c["model"]: c["slug"] for c in ranked}
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
        all_capacity = True
        for backend in candidates:
            self.ledger.receipt(account, request)
            if self._retry_after(backend.model):
                continue
            card = next(c for c in ranked if c["model"] == backend.model)
            direct = operation == "edit" and card.get("edit_transport") == "direct"
            before = _key_spend(key_id) if key_id and not direct else None
            try:
                req_size = task.size or (card["sizes"]["native"] or ["1024x1024"])[0]
                result = self._forward(key, backend, operation, prompt, req_size, image_b64, image_mime,
                                       mask=mask_raw, extra=extra_images,
                                       transparent=task.transparent or task.operation == "remove_background")
                result["model_slug"] = slugs[backend.model]
            except _NotServed as error:
                last_status = error.status
                if error.reason == 'no_capacity':
                    self._capacity_refused(backend.model, error.retry_after_seconds)
                else:
                    all_capacity = False
                _LOG.info('image_attempt_rejected status=%s reason=%s', error.status, error.reason)
                continue  # Explicit, allowlisted pre-dispatch refusal only.
            except Exception:
                raise self._unknown(account, request, fingerprint) from None
            flat = result.pop("_settle", None)
            headers, usage = result.pop("_headers", None), result.pop("_usage", None)
            actual, source = flat, "flat" if flat is not None else None
            if flat is None:
                actual, source = costing.determine_cost(
                    headers=headers, usage=usage, prices=lambda m=backend.model: _PRICES.get(m),
                    spend_before=before, spend_read=(lambda: _key_spend(key_id)) if key_id else None,
                    spend_wait=SPEND_RETRY_SECONDS, spend_poll=SPEND_RETRY_SECONDS,
                    bound=MAX_UPSTREAM_USD)
            _LOG.info("image_cost source=%s model=%s actual=%s", source or "none", backend.model, actual)
            if actual is None or actual <= 0:
                # No dashboard price recorded the spend: keep the reservation
                # for reconciliation rather than fabricating a charge.
                raise self._unknown(account, request, fingerprint)
            try:
                return self.ledger.settle(account, request, actual, result, served_model=slugs[backend.model])
            except ImageError:
                raise
            except Exception:
                raise self._unknown(account, request, fingerprint) from None
        self.ledger.fail(account, request)
        if all_capacity:
            delays = [self._retry_after(b.model) for b in candidates]
            raise ImageError(503, 'image_capacity_unavailable',
                             retry_after_seconds=max(1, min(delays)),
                             receipt=self.ledger.receipt(account, request))
        raise ImageError(503 if last_status == 503 or last_status is None else 502, "image_unavailable",
                         receipt=self.ledger.receipt(account, request))

    def _forward(self, key, backend, operation, prompt, size, image_b64, image_mime, *,
                 mask=None, extra=(), transparent=False):
        headers = {"Authorization": f"Bearer {key}"}
        direct = operation == "edit" and (getattr(backend, "card", None) or {}).get("edit_transport") == "direct"
        if direct:
            engine = self.direct_edit or DIRECT_EDIT
            if mask or extra or transparent:   # defence in depth; routing refuses these earlier
                raise ImageError(422, "unsupported_image_operation")
            response = engine.post(backend.params, prompt, size, f"data:{image_mime};base64,{image_b64}")
            if response.status_code in (401, 402, 403):
                # Our provider credential/credit, not the user's: operator action needed.
                _LOG.error("image provider rejected the gateway credential status=%s", response.status_code)
        else:
            response = self._litellm_forward(headers, backend, operation, prompt, size, image_b64,
                                             image_mime, mask, extra, transparent)
        if _capacity_rejected(response, backend.model):
            raise _NotServed(response.status_code, 'no_capacity',
                             capacity_retry_seconds(response.headers.get('Retry-After')))
        if response.status_code == 400:
            try:
                code = structured_error_code(response.json())
            except ValueError:
                code = None
            if code in PRE_PROVIDER_REFUSAL_CODES:
                raise _NotServed(response.status_code, code)
        if response.status_code != 200:
            raise ImageError(502, "image_unavailable")
        data = response.json()
        rows = data.get("data") if isinstance(data, dict) else None
        if not isinstance(rows, list) or len(rows) != 1 or not rows[0].get("b64_json"):
            raise ImageError(502, "invalid_image_response")
        encoded = rows[0]["b64_json"]
        mime = validate_image(encoded)
        result = {"model": ALIAS, "data": [{"b64_json": encoded, "mime_type": mime}]}
        if direct:
            # LiteLLM never saw this call, so its key-spend delta cannot settle it.
            result["_settle"] = engine.settlement_cost(data, MAX_UPSTREAM_USD)
        else:
            result["_headers"], result["_usage"] = response.headers, data.get("usage")
        return result

    def _litellm_forward(self, headers, backend, operation, prompt, size, image_b64, image_mime,
                         mask, extra, transparent):
        with httpx.Client(base_url=LITELLM_BASE, timeout=HTTP_TIMEOUT, follow_redirects=False) as client:
            if operation == "generate":
                body = {"model": backend.model, "prompt": prompt, "size": size,
                        "n": 1, "response_format": "b64_json"}
                if transparent:
                    body["background"] = "transparent"
                response = client.post("/v1/images/generations", headers=headers, json=body)
            else:
                raw = base64.b64decode(image_b64)
                data = {"model": backend.model, "prompt": prompt, "size": size, "n": "1"}
                if transparent:
                    data["background"] = "transparent"
                inputs = [raw] + [e[0] for e in extra]
                mimes = [image_mime] + [e[1] for e in extra]
                name = "image[]" if len(inputs) > 1 else "image"
                files = [(name, ("image.png" if i == 0 else f"image{i}.png", blob, mime)) for i, (blob, mime) in enumerate(zip(inputs, mimes))]
                if mask:
                    files.append(("mask", ("mask.png", mask, "image/png")))
                response = client.post("/v1/images/edits", headers=headers, data=data, files=files)
        return response

    def _unknown(self, account, request, fingerprint):
        receipt = {"account_id": account, "request_id": request,
                   "fingerprint": fingerprint, "state": "unknown", "charged": None}
        try:
            self.ledger.unknown(account, request)
            receipt = self.ledger.receipt(account, request)
        except Exception:  # noqa: BLE001
            pass
        return ImageError(409, "image_request_pending", receipt=receipt)


def _data_url(value):
    match = re.fullmatch(r"data:(image/(?:png|jpeg|webp));base64,([A-Za-z0-9+/=]+)", value) \
        if isinstance(value, str) else None
    if not match:
        raise ImageError(400, "invalid_image")
    return match[2], match[1]


class _NotServed(Exception):
    def __init__(self, status, reason, retry_after_seconds=None):
        self.status, self.reason = status, reason
        self.retry_after_seconds = retry_after_seconds


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


def _fetch_json(url):
    """Background-only helper: provider models listing / cost map. Short, bounded."""
    with httpx.Client(timeout=15, follow_redirects=False) as client:
        response = client.get(url)
    if response.status_code != 200 or len(response.content) > 8 * 1024 * 1024:
        return None
    return response.json()


def _cost_map():
    if not COSTMAP_URL:
        return None
    try:
        return _fetch_json(COSTMAP_URL)
    except Exception:  # noqa: BLE001
        return None


def build_card_manager(params_for=None):
    store = CardStore(CARDS_DB)
    runner = None
    if PROBE_KEY:
        runner = ProbeRunner(
            LiteLLMProbeTransport(LITELLM_BASE, PROBE_KEY, master_key=LITELLM_MASTER_KEY,
                                  direct=DIRECT_EDIT, params_for=params_for),
            store, per_probe_cap=PROBE_PER_CALL_USD, daily_cap=PROBE_DAILY_USD, max_sizes=PROBE_MAX_SIZES)
    return CardManager(store, runner, fetch_json=_fetch_json, cost_map=_cost_map, ttl=PROBE_TTL)


def mount():
    if getattr(mint.app.state, "ovid_images_mounted", False):
        return
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    discovery = _Discovery(None)
    manager = build_card_manager(discovery.params_of)
    discovery.manager = manager
    service = LiteLLMImageService(discovery, Ledger(DB_PATH))
    mount_images(mint, service, admission=admission, auth=VerifierAuth(mint))
    mount_admin(mint.app, manager, LITELLM_MASTER_KEY, wake=manager.wake)
    # Extraction and probes run here, never on a user request.
    manager.start(lambda: discovery.discovered(force=True), interval=PROBE_INTERVAL)
    mint.app.state.ovid_images_mounted = True
    print(f"Ovid images mounted: alias={ALIAS} image_models={[b.model for b in service.backends]} "
          f"probes={'on' if PROBE_KEY else 'off (static cards only)'} "
          f"direct_edit={'on' if DIRECT_EDIT.has_key else 'off (INFERHUB_API_KEY unset: edits unsupported)'}")


try:
    mount()
except Exception as error:  # noqa: BLE001 - never block mint startup on images
    print(f"Ovid images mount failed (mint continues): {error}")
