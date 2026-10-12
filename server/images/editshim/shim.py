"""Image edit adapter shim: sits between LiteLLM and an OpenAI-compatible provider.

LiteLLM api_base := http://img-edit-shim:8099/<upstream-host>/v1. Provider keys
stay in LiteLLM; the shim only forwards the Authorization header it receives and
never logs or stores it. Hosts in SHIM_JSON_EDIT_HOSTS get multipart image edits
converted to the provider's JSON edit body; everything else is a transparent
reverse proxy.
"""
import base64
import logging
import os
import re
import time
from contextlib import asynccontextmanager
from email.parser import BytesParser
from email.policy import HTTP

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response

try:
    from server.images.adapters import EDIT_PATH, request_shape
except ImportError:  # container layout: adapters.py next to shim.py
    from adapters import EDIT_PATH, request_shape

log = logging.getLogger('img-edit-shim')

HOP_BY_HOP = frozenset({
    'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'proxy-connection',
    'te', 'trailer', 'trailers', 'transfer-encoding', 'upgrade'})
# Never forwarded upstream (besides hop-by-hop): recomputed or irrelevant to the provider.
DROP_REQUEST = frozenset({'host', 'content-length', 'accept-encoding', 'cookie', 'origin', 'referer'})
DROP_RESPONSE = frozenset({'content-length', 'content-encoding'})  # httpx decodes the body
HOST_RE = re.compile(r'^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$')
UNSUPPORTED = {'error': {'code': 'unsupported_modality', 'type': 'invalid_request',
                         'message': "This provider's edit endpoint takes one image and no mask"}}


def _csv(name, default):
    return frozenset(h.strip().lower() for h in os.environ.get(name, default).split(',') if h.strip())


class Config:
    def __init__(self, allowed_hosts=None, json_edit_hosts=None, max_request_bytes=None,
                 max_response_bytes=None, timeout=None, max_concurrent=None):
        env = os.environ.get
        self.allowed_hosts = frozenset(allowed_hosts) if allowed_hosts is not None else _csv('SHIM_ALLOWED_HOSTS', 'api.inferhub.dev')
        self.json_edit_hosts = frozenset(json_edit_hosts) if json_edit_hosts is not None else _csv('SHIM_JSON_EDIT_HOSTS', 'api.inferhub.dev')
        self.max_request_bytes = int(max_request_bytes if max_request_bytes is not None else env('SHIM_MAX_REQUEST_BYTES', 25 * 1024 * 1024))
        self.max_response_bytes = int(max_response_bytes if max_response_bytes is not None else env('SHIM_MAX_RESPONSE_BYTES', 25 * 1024 * 1024))
        self.timeout = float(timeout if timeout is not None else env('SHIM_UPSTREAM_TIMEOUT', 120))
        self.max_concurrent = int(max_concurrent if max_concurrent is not None else env('SHIM_MAX_CONCURRENT', 32))


def error(status, code, message, headers=None):
    return JSONResponse({'error': {'code': code, 'type': 'invalid_request' if status < 500 else 'server_error',
                                   'message': message}}, status_code=status, headers=headers)


def valid_host(host):
    """Syntactic hostname check: lowercase DNS name, no IP/port/userinfo/path."""
    if not isinstance(host, str) or not HOST_RE.match(host) or host != host.lower():
        return False
    return not re.fullmatch(r'[0-9.]+', host) and not host.endswith(('.local', '.internal', '.localhost'))


def safe_path(path):
    if any(c in path for c in ('\\', '\x00', '?', '#')) or any(ord(c) < 32 for c in path):
        return False
    return '..' not in path.split('/') and '.' not in path.split('/')


def forward_headers(headers):
    drop = set(HOP_BY_HOP) | DROP_REQUEST
    for tok in headers.get('connection', '').split(','):
        drop.add(tok.strip().lower())
    out = {k: v for k, v in headers.items() if k.lower() not in drop}
    out['accept-encoding'] = 'identity'
    return out


def response_headers(headers):
    drop = set(HOP_BY_HOP) | DROP_RESPONSE
    for tok in headers.get('connection', '').split(','):
        drop.add(tok.strip().lower())
    out = {}
    for k, v in headers.multi_items():
        if k.lower() not in drop:
            out[k] = v if k not in out else out[k] + ', ' + v
    return out


# ---- multipart parsing (stdlib only; bodies are bounded by the request cap) ----

def parse_multipart(content_type, body):
    """Return [(name, filename, part_content_type, bytes)] or None if malformed."""
    msg = BytesParser(policy=HTTP).parsebytes(b'Content-Type: ' + content_type.encode('latin-1') + b'\r\nMIME-Version: 1.0\r\n\r\n' + body)
    if not msg.is_multipart() or msg.defects:
        return None
    parts = []
    for part in msg.iter_parts():
        name = part.get_param('name', header='content-disposition')
        if name is None:
            continue
        parts.append((name, part.get_filename(), part.get_content_type() if part.get('content-type') else None,
                      part.get_payload(decode=True) or b''))
    return parts


def sniff_mime(data):
    if data.startswith(b'\x89PNG\r\n\x1a\n'):
        return 'image/png'
    if data.startswith(b'\xff\xd8\xff'):
        return 'image/jpeg'
    if data[:4] == b'RIFF' and data[8:12] == b'WEBP':
        return 'image/webp'
    return None


def multipart_to_json_edit(content_type, body):
    """Convert a LiteLLM multipart edit into the provider JSON body.

    Returns (json_body, None) or (None, error_response).
    """
    parts = parse_multipart(content_type, body)
    if parts is None:
        return None, error(400, 'invalid_request', 'Malformed multipart body')
    fields, images, mask = {}, [], False
    for name, filename, ctype, data in parts:
        if name == 'mask' or name == 'mask[]':
            mask = True
        elif name in ('image', 'image[]'):
            images.append((filename, ctype, data))
        elif filename is None:
            fields.setdefault(name, data.decode('utf-8', 'replace'))
    if mask or len(images) > 1:
        return None, JSONResponse(UNSUPPORTED, status_code=400)
    if not images or not images[0][2]:
        return None, error(400, 'invalid_request', 'An image part is required')
    _, ctype, data = images[0]
    mime = sniff_mime(data) or (ctype if ctype and ctype.startswith('image/') else 'image/png')
    data_url = f'data:{mime};base64,' + base64.b64encode(data).decode('ascii')
    try:
        n = int(fields.get('n') or 1)
    except ValueError:
        return None, error(400, 'invalid_request', 'n must be an integer')
    if not fields.get('model') or fields.get('prompt') is None:
        return None, error(400, 'invalid_request', 'model and prompt are required')
    out = request_shape(fields['model'], 'edit', {'prompt': fields['prompt'], 'image': data_url}, fields.get('size') or None)
    if out['size'] is None:
        del out['size']
    out['n'] = n
    out['response_format'] = fields.get('response_format') or out['response_format']
    if fields.get('quality'):
        out['quality'] = fields['quality']
    return out, None


def inferhub_edit_adapter(headers, content_type, body):
    """EDIT_ADAPTERS callable: multipart -> (extra_headers, json_bytes) or error response."""
    import json
    converted, err = multipart_to_json_edit(content_type, body)
    if err is not None:
        return err
    return {'content-type': 'application/json'}, json.dumps(converted, separators=(',', ':')).encode()


def normalize_edit_response(body):
    """Fill the OpenAI-schema usage fields LiteLLM validates on image responses.

    Some providers return edits without usage.input_tokens_details (or without usage at all);
    LiteLLM then rejects a successful, already-billed provider response with a 500. Only missing
    fields are added; provider values such as usage.cost are kept untouched.
    """
    import json
    try:
        data = json.loads(body)
    except ValueError:
        return body
    if not isinstance(data, dict) or not isinstance(data.get('data'), list):
        return body

    def whole(value):
        return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0

    usage = data.get('usage') if isinstance(data.get('usage'), dict) else {}
    usage['input_tokens'] = whole(usage.get('input_tokens'))
    usage['output_tokens'] = whole(usage.get('output_tokens'))
    usage['total_tokens'] = whole(usage.get('total_tokens')) or usage['input_tokens'] + usage['output_tokens']
    details = usage.get('input_tokens_details') if isinstance(usage.get('input_tokens_details'), dict) else {}
    details['text_tokens'] = whole(details.get('text_tokens'))
    details['image_tokens'] = whole(details.get('image_tokens'))
    usage['input_tokens_details'] = details
    data['usage'] = usage
    return json.dumps(data, separators=(',', ':')).encode()


# Registry: host -> adapter. A host listed in SHIM_JSON_EDIT_HOSTS uses
# EDIT_ADAPTERS.get(host, DEFAULT_EDIT_ADAPTER). Add a JSON-only provider with a
# function (same signature) here plus its host in SHIM_JSON_EDIT_HOSTS and
# SHIM_ALLOWED_HOSTS. Multipart-capable providers just pass through.
DEFAULT_EDIT_ADAPTER = inferhub_edit_adapter
EDIT_ADAPTERS = {'api.inferhub.dev': inferhub_edit_adapter}


def create_app(config=None, transport=None):
    cfg = config or Config()
    client = httpx.AsyncClient(transport=transport, follow_redirects=False, trust_env=False,
                               timeout=httpx.Timeout(cfg.timeout))

    @asynccontextmanager
    async def lifespan(_app):
        yield
        await client.aclose()

    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    state = {'inflight': 0}
    app.state.client = client
    app.state.config = cfg

    @app.get('/healthz')
    async def healthz():
        return {'status': 'ok'}

    async def read_body(request):
        declared = request.headers.get('content-length')
        if declared and declared.isdigit() and int(declared) > cfg.max_request_bytes:
            return None
        chunks, total = [], 0
        async for chunk in request.stream():
            total += len(chunk)
            if total > cfg.max_request_bytes:
                return None
            chunks.append(chunk)
        return b''.join(chunks)

    @app.api_route('/{upstream_host}/{path:path}', methods=['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'])
    async def proxy(upstream_host: str, path: str, request: Request):
        start = time.monotonic()
        host = upstream_host.lower()
        status = 0
        try:
            if host != upstream_host or host not in cfg.allowed_hosts or not valid_host(host) or not safe_path(path):
                status = 403
                return error(403, 'forbidden_host', 'Upstream host is not allowed')
            if state['inflight'] >= cfg.max_concurrent:
                status = 503
                return error(503, 'shim_busy', 'Too many concurrent requests', {'Retry-After': '1'})
            state['inflight'] += 1
            try:
                resp = await forward(request, host, path)
            finally:
                state['inflight'] -= 1
            status = resp.status_code
            return resp
        finally:
            log.info('method=%s host=%s path=/%s status=%s latency_ms=%d', request.method, host, path, status,
                     (time.monotonic() - start) * 1000)

    async def forward(request, host, path):
        body = await read_body(request)
        if body is None:
            return error(413, 'request_too_large', 'Request body too large')
        headers = forward_headers(request.headers)
        ctype = request.headers.get('content-type', '')
        converted = False
        if (request.method == 'POST' and '/' + path == EDIT_PATH and host in cfg.json_edit_hosts
                and ctype.lower().startswith('multipart/form-data')):
            adapter = EDIT_ADAPTERS.get(host, DEFAULT_EDIT_ADAPTER)
            result = adapter(request.headers, ctype, body)
            if isinstance(result, Response):
                return result
            extra, body = result
            converted = True
            headers = {k: v for k, v in headers.items() if k.lower() != 'content-type'}
            headers.update(extra)
        url = f'https://{host}/{path}'
        if request.url.query:
            url += '?' + request.url.query
        try:
            upstream = client.build_request(request.method, url, headers=headers, content=body or None)
            up = await client.send(upstream, stream=True)
        except httpx.TimeoutException:
            return error(504, 'upstream_timeout', 'Upstream request timed out')
        except httpx.HTTPError:
            return error(502, 'upstream_error', 'Upstream request failed')
        try:
            chunks, total = [], 0
            try:
                async for chunk in up.aiter_bytes():
                    total += len(chunk)
                    if total > cfg.max_response_bytes:
                        return error(502, 'upstream_response_too_large', 'Upstream response too large')
                    chunks.append(chunk)
            except httpx.TimeoutException:
                return error(504, 'upstream_timeout', 'Upstream request timed out')
            except httpx.HTTPError:
                return error(502, 'upstream_error', 'Upstream request failed')
        finally:
            await up.aclose()
        content = b''.join(chunks)
        if converted and up.status_code == 200 and 'json' in up.headers.get('content-type', '').lower():
            content = normalize_edit_response(content)
        return Response(content=content, status_code=up.status_code, headers=response_headers(up.headers))

    return app


app = create_app()
