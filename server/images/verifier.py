"""Mount on the existing mint FastAPI app; never edit the live verifier.

Requires the actual mint module and an admission bridge to the shared text/image
budget authority. No second account/key store or independently mintable image key.
"""
import hmac
import json
from dataclasses import dataclass
from datetime import datetime, timezone

import httpx
from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

from .service import ALIAS, ImageError, MAX_BYTES
from .catalog import PublicCatalog


@dataclass(frozen=True)
class Identity:
    uid: str
    key_id: str
    tier: str


class VerifierAuth:
    def __init__(self, mint, client=None):
        self.mint = mint
        self.client = client or httpx.Client(base_url=mint.LITELLM_BASE, timeout=15)

    def __call__(self, headers):
        mint = self.mint
        authorization = headers.get('authorization', '')
        if not authorization.lower().startswith('bearer '):
            raise ImageError(401, 'sign_in_required')
        appcheck = headers.get('x-firebase-appcheck', '')
        if mint.APPCHECK_ENABLED and not appcheck:
            raise ImageError(401, 'sign_in_required')
        mint.verify_app_check(appcheck)
        claims = mint.verify_google_id_token(authorization.split(' ', 1)[1])
        uid = claims['sub']
        if mint.is_banned(uid, 'unknown'):
            raise ImageError(403, 'image_access_denied')
        key = headers.get('x-ovid-key', '')
        current = mint.rds.get(f'user:{uid}:key')
        key_id = mint.rds.get(f'user:{uid}:keyid')
        if not key or not current or not key_id or not hmac.compare_digest(key, current):
            raise ImageError(401, 'sign_in_required')
        response = self.client.get('/key/info', params={'key': key_id},
                                   headers={'Authorization': f'Bearer {mint.LITELLM_MASTER_KEY}'})
        if response.status_code != 200:
            raise ImageError(401, 'sign_in_required')
        info = response.json().get('info', {})
        # Explicit alias scope is mandatory. Legacy keys with an unrestricted
        # model list do not silently gain paid image access.
        if info.get('blocked') or ALIAS not in (info.get('models') or []):
            raise ImageError(403, 'image_access_denied')
        if info.get('user_id') != uid or info.get('metadata', {}).get('ovid_uid') != uid:
            raise ImageError(403, 'image_access_denied')
        expires = info.get('expires')
        if expires:
            try:
                expiry = datetime.fromisoformat(expires.replace('Z', '+00:00'))
                if expiry.tzinfo is None:
                    expiry = expiry.replace(tzinfo=timezone.utc)
                if expiry <= datetime.now(timezone.utc):
                    raise ValueError()
            except (ValueError, TypeError):
                raise ImageError(401, 'sign_in_required') from None
        tier = mint.effective_tier(uid)
        if tier == 'free' and mint.free_cap_remaining(uid) <= 0:
            raise ImageError(402, 'image_limit_reached')
        return Identity(uid, key_id, tier)


def mount_images(mint, service=None, *, admission=None, auth=None, private_backends=()):
    """admission(identity) is a context manager from the shared budget ledger.

    It yields (budget_window, remaining_budget_excluding_image_ledger). It must
    reserve against concurrent text spend and commit image spend to /usage and
    the free monthly cap. Without that atomic bridge, routes stay unavailable.
    The repository has no source for that authority; do not use /key/update's
    read/modify/write spend as a substitute for an atomic ledger.
    """
    authenticate = auth or VerifierAuth(mint)
    projection = PublicCatalog(service.backends if service else private_backends,
                               lambda: service is not None and admission is not None)
    original_models = getattr(mint, '_available_models', lambda: [])
    # /usage uses this existing verifier function. Keep image costs out of it.
    mint._available_models = lambda: projection.usage(original_models())

    async def models(request: Request):
        try:
            # The existing chat catalog takes the user's virtual key. Validate
            # it through LiteLLM rather than requiring image scope for text.
            authorization = request.headers.get('authorization', '')
            if not authorization.lower().startswith('bearer '):
                raise ImageError(401, 'sign_in_required')
            async with httpx.AsyncClient(base_url=mint.LITELLM_BASE, timeout=15) as client:
                result = await client.get('/v1/models', headers={'Authorization': authorization})
            if result.status_code != 200:
                raise ImageError(401 if result.status_code in (401, 403) else 503)
            rows = [{'model': row['id']} for row in result.json().get('data', []) if isinstance(row.get('id'), str)]
            # Image capability is deliberately not advertised to a text-key
            # request. Its separate authenticated capability endpoint does so.
            catalog = projection.models(rows)
            catalog['data'] = [row for row in catalog['data'] if row['id'] != ALIAS]
            return JSONResponse(catalog, headers={'Cache-Control': 'no-store'})
        except Exception:
            return JSONResponse({'error': {'code': 'catalog_unavailable'}}, status_code=503)

    def execute(identity, request_id, operation, body):
        with admission(identity) as (window, budget):
            return service.execute(identity.uid, request_id, operation, body, budget, budget_window=window)

    async def handler(request: Request):
        try:
            if service is None or admission is None:
                raise ImageError()
            identity = await run_in_threadpool(authenticate, request.headers)
            if request.method == 'GET':
                return JSONResponse(service.catalog(), headers={'Cache-Control': 'no-store'})
            if request.headers.get('content-type', '').split(';')[0].strip() != 'application/json':
                raise ImageError(415, 'invalid_image_request')
            raw = bytearray()
            async for chunk in request.stream():
                raw.extend(chunk)
                if len(raw) > MAX_BYTES * 4 // 3 + 65536:
                    raise ImageError(413, 'image_too_large')
            try:
                body = json.loads(raw)
            except (ValueError, UnicodeError):
                raise ImageError(400, 'invalid_image_request') from None
            operation = 'edit' if request.url.path.endswith('/edits') else 'generate'
            result = await run_in_threadpool(execute, identity, request.headers.get('idempotency-key'), operation, body)
            return JSONResponse(result, headers={'Cache-Control': 'no-store'})
        except ImageError as error:
            return JSONResponse({'error': {'code': error.code}}, status_code=error.status)
        except Exception as error:
            # Never echo JWT, HTTP, database or provider errors.
            status = getattr(error, 'status_code', 503)
            status = status if status in (401, 403) else 503
            return JSONResponse({'error': {'code': 'image_access_denied' if status in (401, 403) else 'image_unavailable'}}, status_code=status)

    mint.app.add_api_route('/v1/images/capabilities', handler, methods=['GET'])
    mint.app.add_api_route('/v1/images/generations', handler, methods=['POST'])
    mint.app.add_api_route('/v1/images/edits', handler, methods=['POST'])
    mint.app.add_api_route('/v1/models', models, methods=['GET'])
