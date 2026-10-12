import base64
import json
import os
import time

import httpx
from starlette.testclient import TestClient

import shim
from profiles import DEFAULT_PROFILE, ProfileError, validate_profile
import pytest

AUTH = {'Authorization': 'Bearer sk-x'}
PNG = b'\x89PNG\r\n\x1a\n' + b'\x00px'
PNG2 = b'\x89PNG\r\n\x1a\n' + b'\x01py'
B64 = base64.b64encode(PNG).decode()


def make(tmp_path, doc=None, **cfg):
    path = tmp_path / 'providers.json'
    if doc is not None:
        path.write_text(json.dumps(doc))
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(200, json={'data': [{'b64_json': 'AAAA'}]})
    app = shim.create_app(shim.Config(providers_file=str(path), **cfg), transport=httpx.MockTransport(handler))
    return TestClient(app), calls, path


def edit(c, host, files=None, data=None):
    files = files or [('image', ('a.png', PNG, 'image/png'))]
    data = data or {'model': 'm1', 'prompt': 'p', 'size': '1024x1024', 'quality': 'high', 'background': 'transparent'}
    return c.post(f'/{host}/v1/images/edits', files=files, data=data, headers=AUTH)


def rewrite(path, doc):
    path.write_text(json.dumps(doc))
    st = os.stat(path)
    os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns + 5_000_000_000))  # defeat coarse mtime


def test_default_profile_byte_identical_to_legacy():
    ct = 'multipart/form-data; boundary=XX'
    body = (b'--XX\r\nContent-Disposition: form-data; name="model"\r\n\r\nm\r\n'
            b'--XX\r\nContent-Disposition: form-data; name="prompt"\r\n\r\np\r\n'
            b'--XX\r\nContent-Disposition: form-data; name="quality"\r\n\r\nhigh\r\n'
            b'--XX\r\nContent-Disposition: form-data; name="size"\r\n\r\n1024x1024\r\n'
            b'--XX\r\nContent-Disposition: form-data; name="image"; filename="a.png"\r\nContent-Type: image/png\r\n\r\n'
            + PNG + b'\r\n--XX--\r\n')
    legacy = shim.inferhub_edit_adapter({}, ct, body)[1]
    generic = shim.profile_edit_adapter(validate_profile(None))({}, ct, body)[1]
    assert legacy == generic


def test_three_shapes_hot_reloaded(tmp_path):
    doc = {'hosts': {'a.example.com': {'json_edit': True}}}
    c, calls, path = make(tmp_path, doc, allowed_hosts=set(), json_edit_hosts=set())
    assert edit(c, 'a.example.com').status_code == 200
    assert json.loads(calls[-1].content)['image'] == 'data:image/png;base64,' + B64
    assert edit(c, 'b.example.com').status_code == 403            # unknown until the file says so
    rewrite(path, {'hosts': {
        'a.example.com': {'json_edit': True},
        'b.example.com': {'json_edit': True, 'profile': {
            'image_format': 'base64', 'image_array': True, 'max_images': 3, 'image_field': 'images',
            'response_format_default': None}},
        'c.example.com': {'json_edit': True, 'profile': {
            'image_field': 'input_image', 'model_field': 'model_id', 'prompt_field': 'text',
            'mask_field': 'mask_image', 'extra_fields_passthrough': ['background'],
            'drop_fields': ['size']}}}})
    r = edit(c, 'b.example.com', files=[('image[]', ('a.png', PNG, 'image/png')), ('image[]', ('b.png', PNG2, 'image/png'))])
    assert r.status_code == 200
    body = json.loads(calls[-1].content)
    assert body == {'model': 'm1', 'prompt': 'p', 'size': '1024x1024', 'n': 1,
                    'images': [B64, base64.b64encode(PNG2).decode()], 'quality': 'high'}
    r = edit(c, 'c.example.com', files=[('image', ('a.png', PNG, 'image/png')), ('mask', ('m.png', PNG2, 'image/png'))])
    assert r.status_code == 200
    body = json.loads(calls[-1].content)
    assert body == {'model_id': 'm1', 'text': 'p', 'n': 1, 'response_format': 'b64_json',
                    'input_image': 'data:image/png;base64,' + B64,
                    'mask_image': 'data:image/png;base64,' + base64.b64encode(PNG2).decode(),
                    'background': 'transparent'}
    assert 'usage' in r.json()   # reply normalised


def test_unsupported_modality_structured(tmp_path):
    c, calls, _ = make(tmp_path, {'hosts': {'a.example.com': {'json_edit': True},
                                            'u.example.com': {'json_edit': True, 'profile': {'image_format': 'url_not_supported'}}}},
                       allowed_hosts=set(), json_edit_hosts=set())
    for files in ([('image', ('a.png', PNG, 'image/png')), ('mask', ('m.png', PNG, 'image/png'))],
                  [('image[]', ('a.png', PNG, 'image/png')), ('image[]', ('b.png', PNG, 'image/png'))]):
        r = edit(c, 'a.example.com', files=files)
        assert r.status_code == 400 and r.json()['error']['code'] == 'unsupported_modality'
    r = edit(c, 'u.example.com')
    assert r.status_code == 400 and r.json()['error']['code'] == 'unsupported_modality'
    assert calls == []


def test_allowed_false_overrides_env_and_standard_multipart_passthrough(tmp_path):
    c, calls, _ = make(tmp_path, {'hosts': {'api.inferhub.dev': {'allowed': False},
                                            'std.example.com': {'allowed': True, 'json_edit': False}}},
                       allowed_hosts={'api.inferhub.dev'}, json_edit_hosts={'api.inferhub.dev'})
    assert edit(c, 'api.inferhub.dev').status_code == 403
    assert edit(c, 'std.example.com').status_code == 200
    assert calls[-1].headers['content-type'].startswith('multipart/form-data')


def test_bad_file_keeps_last_good_and_missing_file_falls_back(tmp_path):
    c, calls, path = make(tmp_path, {'hosts': {'a.example.com': {'json_edit': True}}},
                          allowed_hosts={'env.example.com'}, json_edit_hosts=set())
    assert edit(c, 'a.example.com').status_code == 200
    rewrite(path, {'hosts': {'a.example.com': {'json_edit': True, 'profile': {'image_format': 'tiff'}}}})
    assert edit(c, 'a.example.com').status_code == 200            # last good kept
    path.unlink()
    assert edit(c, 'a.example.com').status_code == 403
    assert edit(c, 'env.example.com').status_code == 200          # env defaults still work


def test_validate_profile_rejects_garbage():
    for bad in ({'bogus': 1}, {'max_images': 0}, {'image_field': 'a b'}, {'image_array': 'yes'},
                {'response_format_default': 'xml'}, 'str'):
        with pytest.raises(ProfileError):
            validate_profile(bad)
    assert validate_profile({'image_array': False, 'max_images': 5})['max_images'] == 1
