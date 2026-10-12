import asyncio
import base64
import json
import logging

import httpx
import pytest
from starlette.testclient import TestClient

import shim

KEY = 'sk-SECRET-provider-key-123'
AUTH = {'Authorization': f'Bearer {KEY}'}
PNG = b'\x89PNG\r\n\x1a\n' + b'\x00fakepixels\xff'
HOST = 'api.inferhub.dev'


def make(handler, **cfg):
    calls = []

    def wrapped(request):
        calls.append(request)
        return handler(request)

    app = shim.create_app(shim.Config(**cfg), transport=httpx.MockTransport(wrapped))
    return TestClient(app), calls


def ok(request):
    return httpx.Response(200, json={'data': [{'b64_json': 'AAAA'}]})


def edit(client, files=None, data=None, host=HOST, headers=AUTH):
    files = files if files is not None else [('image', ('a.png', PNG, 'image/png'))]
    data = data if data is not None else {'model': 'cb/gpt-image-2', 'prompt': 'make it blue', 'size': '1024x1024',
                                          'n': '1', 'quality': 'high', 'background': 'transparent'}
    return client.post(f'/{host}/v1/images/edits', files=files, data=data, headers=headers)


def test_conversion_exact_body():
    c, calls = make(ok)
    r = edit(c)
    assert r.status_code == 200 and len(calls) == 1
    up = calls[0]
    assert str(up.url) == f'https://{HOST}/v1/images/edits'
    assert up.headers['content-type'] == 'application/json'
    assert json.loads(up.content) == {
        'model': 'cb/gpt-image-2', 'prompt': 'make it blue', 'size': '1024x1024', 'n': 1,
        'response_format': 'b64_json', 'quality': 'high',
        'image': 'data:image/png;base64,' + base64.b64encode(PNG).decode()}


def test_conversion_defaults_and_image_array_and_jpeg_mime():
    c, calls = make(ok)
    jpeg = b'\xff\xd8\xff\xe0abc'
    r = edit(c, files=[('image[]', ('a.bin', jpeg, 'application/octet-stream'))], data={'model': 'm', 'prompt': 'p'})
    assert r.status_code == 200
    assert json.loads(calls[0].content) == {
        'model': 'm', 'prompt': 'p', 'n': 1, 'response_format': 'b64_json',
        'image': 'data:image/jpeg;base64,' + base64.b64encode(jpeg).decode()}


def test_authorization_forwarded_exact_and_response_unchanged():
    body = b'{"data":[{"url":"x"}]}'
    c, calls = make(lambda r: httpx.Response(200, content=body, headers={'content-type': 'application/json', 'x-up': '1'}))
    r = edit(c)
    assert calls[0].headers['authorization'] == f'Bearer {KEY}'
    assert r.json()['data'] == [{'url': 'x'}] and r.headers['x-up'] == '1' and r.headers['content-type'] == 'application/json'


def test_provider_error_passthrough_on_edit():
    err = b'{"error":{"code":"no_capacity"}}'
    c, _ = make(lambda r: httpx.Response(503, content=err, headers={'content-type': 'application/json', 'Retry-After': '7'}))
    r = edit(c)
    assert r.status_code == 503 and r.content == err and r.headers['retry-after'] == '7'


@pytest.mark.parametrize('files', [
    [('image', ('a.png', PNG, 'image/png')), ('mask', ('m.png', PNG, 'image/png'))],
    [('image[]', ('a.png', PNG, 'image/png')), ('image[]', ('b.png', PNG, 'image/png'))],
    [('image', ('a.png', PNG, 'image/png')), ('image', ('b.png', PNG, 'image/png'))],
])
def test_mask_or_multi_image_is_400_without_upstream(files):
    c, calls = make(ok)
    r = edit(c, files=files)
    assert r.status_code == 400 and calls == []
    assert r.json() == {'error': {'code': 'unsupported_modality', 'type': 'invalid_request',
                                  'message': "This provider's edit endpoint takes one image and no mask"}}


def test_generations_passthrough_byte_exact_and_503_retry_after():
    payload = b'{"model":"m","prompt":"p"}'
    err = b'{"error":{"code":"no_capacity","message":"busy"}}'
    c, calls = make(lambda r: httpx.Response(503, content=err, headers={'content-type': 'application/json; charset=utf-8', 'Retry-After': '30'}))
    r = c.post(f'/{HOST}/v1/images/generations?x=1', content=payload, headers={**AUTH, 'content-type': 'application/json'})
    assert r.status_code == 503 and r.content == err and r.headers['retry-after'] == '30'
    assert r.headers['content-type'] == 'application/json; charset=utf-8'
    up = calls[0]
    assert str(up.url) == f'https://{HOST}/v1/images/generations?x=1' and up.content == payload
    assert up.headers['authorization'] == f'Bearer {KEY}' and up.headers['content-type'] == 'application/json'


def test_get_models_proxied():
    c, calls = make(lambda r: httpx.Response(200, json={'data': []}))
    assert c.get(f'/{HOST}/v1/models', headers=AUTH).status_code == 200
    assert calls[0].method == 'GET' and str(calls[0].url) == f'https://{HOST}/v1/models'


def test_non_json_host_edit_passes_multipart_through():
    c, calls = make(ok, allowed_hosts={'other.example.com'}, json_edit_hosts=set())
    r = edit(c, host='other.example.com')
    assert r.status_code == 200
    assert calls[0].headers['content-type'].startswith('multipart/form-data')
    assert PNG in calls[0].content


def test_registry_custom_adapter(monkeypatch):
    monkeypatch.setitem(shim.EDIT_ADAPTERS, 'p.example.com', lambda h, ct, body: ({'content-type': 'application/json'}, b'{"k":1}'))
    c, calls = make(ok, allowed_hosts={'p.example.com'}, json_edit_hosts={'p.example.com'})
    edit(c, host='p.example.com')
    assert calls[0].content == b'{"k":1}'


@pytest.mark.parametrize('host', ['evil.com', 'api.inferhub.dev.evil.com', '127.0.0.1', 'localhost', 'API.INFERHUB.DEV',
                                  'api.inferhub.dev:8443', 'user@api.inferhub.dev', 'api.inferhub.dev%40evil.com'])
def test_disallowed_hosts_403(host):
    c, calls = make(ok)
    r = c.get(f'/{host}/v1/models', headers=AUTH)
    assert r.status_code == 403 and calls == []
    assert r.json()['error']['code'] == 'forbidden_host' and KEY not in r.text


@pytest.mark.parametrize('host', ['http://api.inferhub.dev', '127.0.0.1', '10.0.0.5', 'a.b:99', 'u@h.com', 'localhost',
                                  'foo.internal', '[::1]', '1.2.3.4'])
def test_valid_host_rejects(host):
    assert not shim.valid_host(host)
    assert shim.valid_host('api.inferhub.dev')


def test_allowlist_cannot_enable_unsafe_host():
    c, calls = make(ok, allowed_hosts={'127.0.0.1', 'host:8080'})
    assert c.get('/127.0.0.1/v1/models').status_code == 403 and calls == []


def test_path_traversal_rejected():
    c, calls = make(ok)
    assert c.get(f'/{HOST}/v1/%2e%2e/admin', headers=AUTH).status_code == 403
    assert shim.safe_path('v1/a/../b') is False and shim.safe_path('v1/images/edits')
    assert calls == []


def test_request_body_cap():
    c, calls = make(ok, max_request_bytes=100)
    r = c.post(f'/{HOST}/v1/images/generations', content=b'x' * 101, headers=AUTH)
    assert r.status_code == 413 and calls == []
    assert c.post(f'/{HOST}/v1/images/generations', content=b'x' * 100, headers=AUTH).status_code == 200


def test_response_cap():
    c, _ = make(lambda r: httpx.Response(200, content=b'y' * 101), max_response_bytes=100)
    r = c.get(f'/{HOST}/v1/models')
    assert r.status_code == 502 and r.json()['error']['code'] == 'upstream_response_too_large'


def test_timeout_504_json():
    def boom(request):
        raise httpx.ReadTimeout('slow', request=request)
    c, _ = make(boom)
    r = c.post(f'/{HOST}/v1/images/generations', content=b'{}', headers=AUTH)
    assert r.status_code == 504 and r.json()['error']['code'] == 'upstream_timeout' and KEY not in r.text


def test_connect_error_502():
    def boom(request):
        raise httpx.ConnectError('nope', request=request)
    c, _ = make(boom)
    r = c.get(f'/{HOST}/v1/models', headers=AUTH)
    assert r.status_code == 502 and KEY not in r.text


def test_concurrency_cap():
    gate = asyncio.Event()

    async def slow(request):
        await gate.wait()
        return httpx.Response(200, json={})

    app = shim.create_app(shim.Config(max_concurrent=2), transport=httpx.MockTransport(slow))

    async def run():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://t') as ac:
            tasks = [asyncio.create_task(ac.get(f'/{HOST}/v1/models')) for _ in range(2)]
            await asyncio.sleep(0.1)
            third = await ac.get(f'/{HOST}/v1/models')
            health = await ac.get('/healthz')
            gate.set()
            done = await asyncio.gather(*tasks)
            after = await ac.get(f'/{HOST}/v1/models')
            return third, health, done, after

    third, health, done, after = asyncio.run(run())
    assert third.status_code == 503 and third.json()['error']['code'] == 'shim_busy'
    assert health.status_code == 200
    assert [d.status_code for d in done] == [200, 200] and after.status_code == 200


def test_redirects_not_followed():
    c, calls = make(lambda r: httpx.Response(302, headers={'location': 'https://evil.com/x'}))
    r = c.get(f'/{HOST}/v1/models', headers=AUTH, follow_redirects=False)
    assert r.status_code == 302 and r.headers['location'] == 'https://evil.com/x' and len(calls) == 1


def test_healthz_no_upstream():
    c, calls = make(ok)
    r = c.get('/healthz')
    assert r.status_code == 200 and calls == []


def test_hop_by_hop_headers():
    def h(request):
        return httpx.Response(200, content=b'ok', headers={'Keep-Alive': 'timeout=5', 'X-Keep': 'y', 'Connection': 'x-secret',
                                                           'x-secret': 'z', 'Transfer-Encoding-X': 'a'})
    c, calls = make(h)
    r = c.get(f'/{HOST}/v1/models', headers={**AUTH, 'Connection': 'x-hop', 'x-hop': '1', 'Keep-Alive': '1', 'TE': 'trailers',
                                              'Upgrade': 'x', 'Cookie': 'a=b', 'X-Custom': 'keep'})
    up = calls[0].headers
    for gone in ('x-hop', 'keep-alive', 'te', 'upgrade', 'cookie'):
        assert gone not in up
    assert up['x-custom'] == 'keep' and up['authorization'] == f'Bearer {KEY}' and up['host'] == HOST
    assert 'keep-alive' not in r.headers and 'x-secret' not in r.headers
    assert r.headers['x-keep'] == 'y' and r.content == b'ok'


def test_authorization_never_logged_or_in_errors(caplog):
    caplog.set_level(logging.DEBUG)
    c, _ = make(ok)
    edit(c)
    c.post(f'/{HOST}/v1/images/generations', content=b'{"prompt":"secretprompt"}', headers=AUTH)
    bad = [edit(c, host='evil.com'), edit(c, files=[('image', ('a.png', PNG, 'image/png')), ('mask', ('m.png', PNG, 'image/png'))])]
    c2, _ = make(lambda r: (_ for _ in ()).throw(httpx.ReadTimeout('t', request=r)))
    bad.append(c2.post(f'/{HOST}/v1/images/generations', content=b'{}', headers=AUTH))
    text = '\n'.join(r.getMessage() for r in caplog.records)
    assert 'method=POST host=api.inferhub.dev path=/v1/images/edits status=200' in text
    assert KEY not in text and 'secretprompt' not in text and 'Bearer' not in text
    for r in bad:
        assert KEY not in r.text and 'Bearer' not in r.text and KEY not in str(r.headers)


def test_malformed_multipart_400():
    c, calls = make(ok)
    r = c.post(f'/{HOST}/v1/images/edits', content=b'garbage', headers={**AUTH, 'content-type': 'multipart/form-data; boundary=zzz'})
    assert r.status_code == 400 and calls == []


def test_missing_image_400():
    c, calls = make(ok)
    r = edit(c, files=[('other', ('a.txt', b'x', 'text/plain'))])
    assert r.status_code == 400 and calls == []


def test_edit_response_gets_openai_usage_fields_and_keeps_provider_cost():
    provider = {'data': [{'b64_json': 'AAAA'}], 'usage': {'cost': 0.0005863455, 'input_tokens': 12, 'output_tokens': 30,
                                                          'total_tokens': 2589}}
    c, _ = make(lambda r: httpx.Response(200, json=provider))
    usage = edit(c).json()['usage']
    assert usage['cost'] == 0.0005863455 and usage['total_tokens'] == 2589
    assert usage['input_tokens'] == 12 and usage['output_tokens'] == 30
    assert usage['input_tokens_details'] == {'text_tokens': 0, 'image_tokens': 0}


def test_edit_response_without_usage_is_completed():
    c, _ = make(ok)
    body = edit(c).json()
    assert body['data'] == [{'b64_json': 'AAAA'}]
    assert body['usage'] == {'input_tokens': 0, 'output_tokens': 0, 'total_tokens': 0,
                             'input_tokens_details': {'text_tokens': 0, 'image_tokens': 0}}


def test_existing_usage_details_are_preserved():
    provider = {'data': [{'b64_json': 'AAAA'}], 'usage': {'input_tokens': 5, 'output_tokens': 7, 'total_tokens': 12,
                                                          'input_tokens_details': {'text_tokens': 3, 'image_tokens': 2}}}
    c, _ = make(lambda r: httpx.Response(200, json=provider))
    assert edit(c).json()['usage']['input_tokens_details'] == {'text_tokens': 3, 'image_tokens': 2}


def test_generations_and_non_json_and_errors_are_not_touched():
    gen = b'{"data":[{"b64_json":"AAAA"}]}'
    c, _ = make(lambda r: httpx.Response(200, content=gen, headers={'content-type': 'application/json'}))
    assert c.post(f'/{HOST}/v1/images/generations', json={'model': 'm', 'prompt': 'p'}, headers=AUTH).content == gen
    c, _ = make(lambda r: httpx.Response(200, content=b'not json', headers={'content-type': 'application/json'}))
    assert edit(c).content == b'not json'
    err = b'{"error":{"code":"no_capacity"}}'
    c, _ = make(lambda r: httpx.Response(503, content=err, headers={'content-type': 'application/json'}))
    assert edit(c).content == err
