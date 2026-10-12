import json
import re

import httpx

import check_provider as chk
import onboard_provider as ob
from switch_api_base_test import FakeLiteLLM, MASTER, SECRET

HOST = 'api.newprovider.com'
ENV = {'LITELLM_BASE': 'http://litellm:4000', 'LITELLM_MASTER_KEY': MASTER, 'OVID_GATEWAY_BASE': 'http://gw:8080'}


class NewProviderLiteLLM(FakeLiteLLM):
    def __init__(self, prices=None):
        super().__init__()
        self.models = {'n1': self.mk('n1', 'np-image', f'https://{HOST}/v1', 'image_generation'),
                       'n2': self.mk('n2', 'inferhub-img', 'https://api.inferhub.dev/v1', 'image_generation')}
        self.models['n1']['model_info'].update(prices or {})
        self.keys = {k: SECRET for k in self.models}


class FakeGateway:
    def __init__(self, models=('np-image',), priced=True, state='probed'):
        self.calls, self.known, self.priced, self.state = [], set(models), priced, state
        self.probed_at = {m: 100 for m in models}
        self.reprobed = []

    def card(self, m):
        ops = {'generate': {'supported': True}, 'edit': {'supported': True}}
        return {'model': m, 'state': self.state, 'operations': ops, 'sizes': {'native': ['1024x1024']},
                'measured_cost_usd': 0.04, 'priced': self.priced, 'cost_source': 'per_image' if self.priced else None,
                'warnings': [] if self.priced else ["unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image)"],
                'probed_at': self.probed_at.get(m), 'probes': [{'probe': 'edit', 'ok': False, 'error_class': 'unsupported'}]}

    def __call__(self, request):
        self.calls.append((request.method, request.url.path))
        assert request.headers['authorization'] == f'Bearer {MASTER}'
        if request.url.path == '/images/admin/cards':
            return httpx.Response(200, json={'cards': [self.card(m) for m in self.known],
                                             'probe_budget': {'probe_daily_cap_usd': 5.0, 'probe_daily_left_usd': 4.5,
                                                              'probe_per_call_cap_usd': 0.5, 'probe_spend_24h_usd': 0.5}})
        if request.url.path == '/images/admin/refresh-prices':
            return httpx.Response(200, json={})
        if request.url.path == '/images/admin/reprobe':
            m = json.loads(request.content)['model']
            self.reprobed.append(m)
            self.probed_at[m] += 100
            return httpx.Response(202, json={'queued': m})
        return httpx.Response(404)


def go(tmp_path, litellm, gw, *argv, env=ENV):
    lines = []
    args = ob.parse(['--host', HOST, '--backup', str(tmp_path / 'b.json'),
                     '--providers-file', str(tmp_path / 'prov' / 'providers.json'), *argv])
    rc = ob.run(args, env, httpx.MockTransport(litellm), httpx.MockTransport(gw), out=lines.append, sleep=lambda s: None)
    return rc, lines


def test_dry_run_default_writes_and_patches_nothing(tmp_path):
    f, g = NewProviderLiteLLM(), FakeGateway()
    rc, lines = go(tmp_path, f, g, '--json-edit')
    assert rc == 0 and lines[0].startswith('DRY RUN')
    assert all(c[0] == 'GET' for c in f.calls) and g.calls == []
    assert not (tmp_path / 'prov').exists() and not (tmp_path / 'b.json').exists()
    assert any('switch np-image' in l for l in lines)


def test_apply_end_to_end_only_api_base_patched_key_never_leaks(tmp_path):
    f, g = NewProviderLiteLLM(), FakeGateway()
    before = json.loads(json.dumps(f.models))
    rc, lines = go(tmp_path, f, g, '--apply', '--json-edit', '--image-format', 'base64', '--image-array',
                   '--max-images', '3', '--image-field', 'images')
    assert rc == 0
    doc = json.loads((tmp_path / 'prov' / 'providers.json').read_text())
    entry = doc['hosts'][HOST]
    assert entry['allowed'] and entry['json_edit']
    assert entry['profile']['image_format'] == 'base64' and entry['profile']['image_array'] is True
    assert entry['profile']['max_images'] == 3 and entry['profile']['image_field'] == 'images'
    patches = [c for c in f.calls if c[0] == 'PATCH']
    assert len(patches) == 1
    assert json.loads(patches[0][2]) == {'litellm_params': {'api_base': f'http://img-edit-shim:8099/{HOST}/v1'}}
    now = f.models['n1']['litellm_params']
    assert now['api_key'] == before['n1']['litellm_params']['api_key']
    assert f.models['n2']['litellm_params']['api_base'] == 'https://api.inferhub.dev/v1'   # other host untouched
    assert g.reprobed == ['np-image']
    text = '\n'.join(lines)
    assert 'card np-image:' in text and 'card state: probed' in text and 'priced: True' in text
    assert 'rollback:' in text and '--revert --apply' in text
    blob = text + b''.join(c[2] for c in f.calls).decode() + (tmp_path / 'prov' / 'providers.json').read_text()
    assert SECRET not in blob and MASTER not in blob and 'sk-R' not in blob


def test_apply_is_idempotent_and_rollback_restores(tmp_path):
    f, g = NewProviderLiteLLM(), FakeGateway()
    go(tmp_path, f, g, '--apply', '--json-edit')
    n = len([c for c in f.calls if c[0] == 'PATCH'])
    go(tmp_path, f, g, '--apply', '--json-edit')
    assert len([c for c in f.calls if c[0] == 'PATCH']) == n
    import switch_api_base as sw
    sw.run(sw.parse(['--revert', '--apply', '--backup', str(tmp_path / 'b.json')]), ENV, httpx.MockTransport(f), out=lambda s: None)
    assert f.models['n1']['litellm_params']['api_base'] == f'https://{HOST}/v1'


def test_standard_multipart_provider_skips_shim(tmp_path):
    f, g = NewProviderLiteLLM(), FakeGateway()
    rc, lines = go(tmp_path, f, g, '--apply')
    assert rc == 0 and not [c for c in f.calls if c[0] == 'PATCH'] and not (tmp_path / 'prov').exists()
    assert g.reprobed == ['np-image']


def test_rejects_bad_hosts_profiles_and_missing_models(tmp_path):
    import pytest
    for bad in ('127.0.0.1', 'http://x.com', 'x.com:8080', 'localhost', 'a.internal', 'UPPER..com'):
        args = ob.parse(['--host', bad])
        with pytest.raises(ob.OnboardError):
            ob.run(args, ENV, httpx.MockTransport(NewProviderLiteLLM()), httpx.MockTransport(FakeGateway()), out=print)
    with pytest.raises(ob.OnboardError):
        go(tmp_path, NewProviderLiteLLM(), FakeGateway(), '--json-edit', '--max-images', '99')
    args = ob.parse(['--host', 'api.other.com'])
    with pytest.raises(ob.OnboardError):
        ob.run(args, ENV, httpx.MockTransport(NewProviderLiteLLM()), httpx.MockTransport(FakeGateway()), out=print)


def check(tmp_path, litellm, gw, model='np-image', env=ENV, *extra):
    lines = []
    args = chk.parse([model, '--providers-file', str(tmp_path / 'prov' / 'providers.json'), *extra])
    rc = chk.run(args, env, httpx.MockTransport(litellm), httpx.MockTransport(gw) if gw else None, out=lines.append)
    return rc, '\n'.join(lines)


def test_check_provider_ready_is_read_only(tmp_path):
    f, g = NewProviderLiteLLM({'output_cost_per_image': 0.04}), FakeGateway()
    rc, text = check(tmp_path, f, g)
    assert rc == 0 and 'READY' in text and 'price (LiteLLM model_info): ok via per_image' in text
    assert 'edit path: standard multipart (no shim)' in text
    assert 'probe budget left (24h): $4.5 of $5.0' in text
    assert all(c[0] == 'GET' for c in f.calls) and all(c[0] == 'GET' for c in g.calls)
    assert SECRET not in text and MASTER not in text


def test_check_provider_reports_missing_price_fields_and_next_steps(tmp_path):
    f, g = NewProviderLiteLLM(), FakeGateway(priced=False, state='inferred')
    rc, text = check(tmp_path, f, g)
    assert rc == 1 and 'NOT READY' in text
    assert 'absent fields: input_cost_per_token, output_cost_per_token, input_cost_per_image, output_cost_per_image' in text
    assert "set the model's price in LiteLLM" in text and 'refresh-prices' in text
    assert 'probe failed: edit -> unsupported' in text


def test_check_provider_flags_json_host_not_switched_and_unknown_model(tmp_path):
    f, g = NewProviderLiteLLM({'output_cost_per_image': 0.04}), FakeGateway()
    (tmp_path / 'prov').mkdir()
    (tmp_path / 'prov' / 'providers.json').write_text(json.dumps({'hosts': {HOST: {'json_edit': True}}}))
    rc, text = check(tmp_path, f, g)
    assert rc == 1 and 'body must be JSON' in text
    rc, text = check(tmp_path, f, g, model='nope')
    assert rc == 1 and 'model not found' in text
