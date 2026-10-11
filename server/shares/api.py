"""Router factory: verified UID callback and real deployment origin are required."""

import base64
import hashlib
import html
import os
import re
from contextlib import nullcontext
from urllib.parse import quote, urlencode, urlsplit

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


# Constant inline script (CSP-hashed): on Android, hand the very same https
# link to the Ovid app via an intent; Chrome falls back to the Play listing
# (with the install referrer) when the app is not installed.
OPEN_APP_SCRIPT = (
    "(function(){var d=document.documentElement;"
    "if(!/Android/i.test(navigator.userAgent))return;"
    "var u='intent://'+location.host+location.pathname+'#Intent;scheme=https;package='"
    "+d.getAttribute('data-pkg')+';S.browser_fallback_url='"
    "+encodeURIComponent(d.getAttribute('data-play'))+';end';"
    "location.replace(u);})();"
)
OPEN_APP_SCRIPT_HASH = base64.b64encode(hashlib.sha256(OPEN_APP_SCRIPT.encode()).digest()).decode()
PAGE_CSP = ("default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; "
            f"script-src 'sha256-{OPEN_APP_SCRIPT_HASH}'; base-uri 'none'; "
            "form-action 'none'; frame-ancestors 'none'")
_TOKEN = re.compile(r'[A-Za-z0-9_-]{43}')


def package_name():
    value = os.environ.get('OVID_ANDROID_PACKAGE_NAME', 'com.dhanuk.ovidai').strip()
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+', value):
        raise ValueError('OVID_ANDROID_PACKAGE_NAME is not a valid Android application id')
    return value


def play_store_url(share_token, invite=None):
    referrer = {'share_token': share_token}
    if invite is not None:
        referrer['invite'] = invite
    return 'https://play.google.com/store/apps/details?' + urlencode(
        {'id': package_name(), 'referrer': urlencode(referrer)})


def landing_page(*, title, heading, lead, body, host, path, play, status=200):
    """Shared public page: readable fallback + app intent + Play Store."""
    pkg = package_name()
    intent = (f'intent://{host}{quote(path)}#Intent;scheme=https;package={pkg};'
              f'S.browser_fallback_url={quote(play, safe="")};end')
    esc = lambda value: html.escape(value, quote=True)
    page = f'''<!doctype html><html lang="en" data-pkg="{esc(pkg)}" data-play="{esc(play)}"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow,noarchive"><title>{esc(title)}</title>
<style>body{{font:16px system-ui;max-width:760px;margin:40px auto;padding:0 20px;color:#202124}}
section{{border-top:1px solid #ddd;padding:16px 0}}h2{{font-size:15px}}
pre{{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit;line-height:1.6}}
.cta{{display:flex;gap:12px;flex-wrap:wrap;margin:20px 0}}
.cta a{{padding:12px 18px;border-radius:999px;text-decoration:none;font-weight:600}}
.primary{{background:#1a73e8;color:#fff}}.secondary{{border:1px solid #1a73e8;color:#1a73e8}}</style>
<script>{OPEN_APP_SCRIPT}</script></head><body><h1>{esc(heading)}</h1><p>{esc(lead)}</p>
<div class="cta"><a class="primary" rel="nofollow" href="{esc(intent)}">Open in the Ovid app</a>
<a class="secondary" rel="nofollow" href="{esc(play)}">Get Ovid on Google Play</a></div>{body}</body></html>'''
    response = HTMLResponse(page, status_code=status)
    response.headers['Content-Security-Policy'] = PAGE_CSP
    return response


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
            page_csp = response.headers.get('content-security-policy') == PAGE_CSP
            response.headers.update(HEADERS)
            if page_csp:
                response.headers['Content-Security-Policy'] = PAGE_CSP
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
        # Comma-separated: e.g. the Play App Signing key AND the upload key.
        raw = os.environ.get('OVID_ANDROID_RELEASE_CERT_SHA256', '')
        fingerprints = [value.strip().upper() for value in raw.split(',') if value.strip()]
        if not fingerprints or not all(
                re.fullmatch(r'[0-9A-F]{2}(?::[0-9A-F]{2}){31}', value) for value in fingerprints):
            return JSONResponse({'detail': 'android_release_fingerprint_not_configured'}, status_code=503)
        response = JSONResponse([{
            'relation': ['delegate_permission/common.handle_all_urls'],
            'target': {
                'namespace': 'android_app',
                'package_name': package_name(),
                'sha256_cert_fingerprints': fingerprints,
            },
        }])
        # Google's verifier caches this; it carries no user data.
        response.headers['Cache-Control'] = 'public, max-age=3600'
        return response

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

    @routes.put('/shares/{token}')
    def update(token: str, body: CreateShare, uid=Depends(owner)):
        with admission(uid) if admission else nullcontext(uid) as admitted_uid:
            return receipt(repository.update(admitted_uid, token, body.model_dump()))

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

    public_host = urlsplit(base_url).netloc
    public_path = urlsplit(base_url).path

    @routes.get('/s/{token}', response_class=HTMLResponse)
    def viewer(token: str):
        snapshot = public_snapshot(token)
        if snapshot is None:
            return HTMLResponse('<!doctype html><title>Link unavailable</title><h1>Link unavailable</h1>'
                                '<p>This link was revoked or has expired.</p>', status_code=404)
        rows = ''.join('<section><h2>' + ('You' if m['role'] == 'user' else 'Assistant') +
                       '</h2><pre>' + html.escape(m['content'], quote=True) + '</pre></section>'
                       for m in snapshot['messages'])
        return landing_page(title='Shared conversation · Ovid', heading='Shared conversation',
                            lead='A read-only Ovid chat shared by its owner.', body=rows,
                            host=public_host, path=f'{public_path}/s/{token}',
                            play=play_store_url(token))

    @routes.get('/s/{token}/{invite}', response_class=HTMLResponse)
    def collab_invite(token: str, invite: str):
        # Reveals nothing about the session and performs no lookup: joining
        # (and the 10-member cap) is enforced by the authenticated join call.
        if not _TOKEN.fullmatch(token) or not _TOKEN.fullmatch(invite):
            return HTMLResponse('<!doctype html><title>Link unavailable</title><h1>Link unavailable</h1>',
                                status_code=404)
        return landing_page(title='Live session invite · Ovid', heading='Join a live Ovid session',
                            lead='You were invited to chat together in a live session. Each person '
                                 'uses their own model and account. Open the link in the Ovid app.',
                            body='', host=public_host, path=f'{public_path}/s/{token}/{invite}',
                            play=play_store_url(token, invite))

    return routes
