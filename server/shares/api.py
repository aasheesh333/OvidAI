"""Router factory: verified UID callback and real deployment origin are required."""

import html
import os
import re
from contextlib import nullcontext
from urllib.parse import urlsplit

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.routing import APIRoute

from .repository import ShareError
from .snapshot import CreateShare, ForkShare

HEADERS = {
    'Cache-Control': 'no-store, private, max-age=0',
    'Pragma': 'no-cache',
    'X-Robots-Tag': 'noindex, nofollow, noarchive',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; "
                               "base-uri 'none'; form-action 'none'; frame-ancestors 'none'; sandbox",
}


class ShareRoute(APIRoute):
    def get_route_handler(self):
        original = super().get_route_handler()

        async def handle(request):
            try:
                if request.method == 'POST':
                    # Bound the raw body before JSON decoding, including chunked
                    # requests and JSON whitespace/escape expansion overhead.
                    length = request.headers.get('content-length')
                    if length and (not length.isdigit() or int(length) > 1500000):
                        raise HTTPException(413, 'snapshot_too_large')
                    body = bytearray()
                    async for chunk in request.stream():
                        if len(body) + len(chunk) > 1500000:
                            raise HTTPException(413, 'snapshot_too_large')
                        body.extend(chunk)
                    request._body = bytes(body)
                response = await original(request)
            except RequestValidationError:
                # Don't echo rejected secret fields/bytes in validation errors.
                response = JSONResponse({'detail': 'invalid_snapshot'}, status_code=422)
            except ShareError as error:
                response = JSONResponse({'detail': error.code}, status_code=error.status)
            except HTTPException as error:
                response = JSONResponse({'detail': error.detail}, status_code=error.status_code)
            except Exception:
                response = JSONResponse({'detail': 'shares_unavailable'}, status_code=503)
            response.headers.update(HEADERS)
            return response
        return handle


def router(repository, verify_uid, base_url, *, admission=None):
    """verify_uid(token, attestation) -> verified nonanonymous UID or raises.

    Inject a synchronous adapter using the account architecture's verifier and
    identity policy. It must check revocation, disabled users and account fence.
    This module never accepts owner IDs or trusts claims sent by the client.
    """
    base_url = base_url.rstrip('/')
    parsed = urlsplit(base_url)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or
            parsed.password or parsed.query or parsed.fragment or
            (parsed.path and not re.fullmatch(r'(?:/[A-Za-z0-9_-]+)+', parsed.path))):
        raise ValueError('A configured HTTPS deployment base URL is required')
    routes = APIRouter(tags=['shares'], route_class=ShareRoute)

    @routes.get('/.well-known/assetlinks.json')
    def asset_links():
        fingerprint = os.environ.get('OVID_ANDROID_RELEASE_CERT_SHA256', '').strip()
        package_name = os.environ.get('OVID_ANDROID_PACKAGE_NAME', 'com.dhanuk.ovidai').strip()
        if not fingerprint or not re.fullmatch(r'(?:[0-9A-Fa-f]{2}:?){32}', fingerprint):
            return JSONResponse({'detail': 'android_release_fingerprint_not_configured'}, status_code=503)
        return JSONResponse([{
            'relation': ['delegate_permission/common.handle_all_urls'],
            'target': {
                'namespace': 'android_app',
                'package_name': package_name,
                'sha256_cert_fingerprints': [fingerprint.upper()],
            },
        }])

    def owner(authorization: str = Header(default=''),
              x_firebase_appcheck: str = Header(default='')):
        if not authorization.startswith('Bearer ') or not authorization[7:].strip():
            raise HTTPException(401, 'authentication_required')
        try:
            uid = verify_uid(authorization[7:], x_firebase_appcheck)
        except HTTPException:
            raise
        except Exception:
            raise HTTPException(401, 'invalid_authentication') from None
        if admission is None and (not isinstance(uid, str) or not uid.strip()):
            raise HTTPException(401, 'invalid_identity')
        return uid

    def receipt(value):
        return value | {'url': base_url + '/s/' + value['id']}

    @routes.post('/shares', status_code=201)
    def create(body: CreateShare, uid=Depends(owner)):
        with admission(uid) if admission else nullcontext(uid) as admitted_uid:
            return receipt(repository.create(admitted_uid, body.model_dump()))

    @routes.get('/shares')
    def list_shares(session_id: str | None = Query(default=None, max_length=128), uid=Depends(owner)):
        with admission(uid) if admission else nullcontext(uid) as admitted_uid:
            return {'shares': [receipt(row) for row in repository.list(admitted_uid, session_id)]}

    @routes.delete('/shares/{token}', status_code=204)
    def revoke(token: str, uid=Depends(owner)):
        with admission(uid) if admission else nullcontext(uid) as admitted_uid:
            repository.revoke(admitted_uid, token)
        return Response(status_code=204)

    @routes.post('/shares/{token}/fork', status_code=201)
    def fork(token: str, body: ForkShare, uid=Depends(owner)):
        with admission(uid) if admission else nullcontext(uid) as admitted_uid:
            return repository.fork(admitted_uid, token, body.model_dump())

    def public_snapshot(token):
        return repository.public(token) if re.fullmatch(r'[A-Za-z0-9_-]{43}', token) else None

    @routes.get('/s/{token}.json')
    def snapshot_json(token: str):
        snapshot = public_snapshot(token)
        if snapshot is None:
            return JSONResponse({'detail': 'share_not_found'}, status_code=404)
        return snapshot

    @routes.get('/s/{token}', response_class=HTMLResponse)
    def viewer(token: str):
        snapshot = public_snapshot(token)
        if snapshot is None:
            return HTMLResponse('<!doctype html><title>Link unavailable</title><h1>Link unavailable</h1>', status_code=404)
        rows = ''.join('<section><h2>' + ('You' if m['role'] == 'user' else 'Assistant') +
                       '</h2><pre>' + html.escape(m['content'], quote=True) + '</pre></section>'
                       for m in snapshot['messages'])
        play_store = 'https://play.google.com/store/apps/details?id=com.dhanuk.ovidai&referrer=share_token%3D' + token
        return HTMLResponse('''<!doctype html><html lang="en"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <meta name="robots" content="noindex,nofollow,noarchive"><title>Shared conversation · Ovid</title>
            <style>body{font:16px system-ui;max-width:760px;margin:40px auto;padding:0 20px;color:#202124}
            section{border-top:1px solid #ddd;padding:16px 0}h2{font-size:15px}
            pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit;line-height:1.6}</style>
            </head><body><h1>Shared conversation</h1><p>Immutable snapshot shared by an Ovid user.</p>'''
                            + rows + '<p><a rel="nofollow" href="' + play_store + '">Open in Ovid Si</a></p></body></html>')

    return routes
