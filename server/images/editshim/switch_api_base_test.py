import argparse
import json
import re

import httpx
import pytest

import switch_api_base as sw

SECRET = 'sk-REAL-PROVIDER-KEY'
MASTER = 'sk-master-xyz'


class FakeLiteLLM:
    """Mimics /model/info (api_key redacted) and PATCH /model/{id}/update (partial merge)."""

    def __init__(self, drop_key_on_patch=False):
        self.calls = []
        self.drop = drop_key_on_patch
        self.models = {
            'id1': self.mk('id1', 'gpt-image-2', 'https://api.inferhub.dev/v1', 'image_generation'),
            'id2': self.mk('id2', 'other-img', 'https://api.openai.com/v1', 'image_generation'),
            'id3': self.mk('id3', 'chat', 'https://api.inferhub.dev/v1', 'chat'),
            'id4': self.mk('id4', 'edit-img', 'https://api.inferhub.dev/v1', 'image_edit'),
        }
        self.keys = {k: SECRET for k in self.models}

    @staticmethod
    def mk(mid, name, base, mode):
        return {'model_name': name, 'litellm_params': {'api_base': base, 'model': 'openai/cb/x', 'api_key': 'sk-R***'},
                'model_info': {'id': mid, 'mode': mode}}

    def __call__(self, request):
        self.calls.append((request.method, request.url.path, request.content))
        assert request.headers['authorization'] == f'Bearer {MASTER}'
        if request.method == 'GET' and request.url.path == '/model/info':
            return httpx.Response(200, json={'data': list(self.models.values())})
        m = re.fullmatch(r'/model/(\w+)/update', request.url.path)
        if request.method == 'PATCH' and m:
            body = json.loads(request.content)
            self.models[m[1]]['litellm_params'].update(body['litellm_params'])
            if self.drop:
                self.models[m[1]]['litellm_params']['api_key'] = None
            return httpx.Response(200, json={'ok': True})
        return httpx.Response(404, json={'detail': f'{SECRET}'})


def args(tmp_path, *extra):
    a = sw.parse(['--backup', str(tmp_path / 'b.json'), *extra])
    return a


ENV = {'LITELLM_BASE': 'http://litellm:4000', 'LITELLM_MASTER_KEY': MASTER}


def run(fake, tmp_path, *extra):
    lines = []
    n = sw.run(args(tmp_path, *extra), ENV, httpx.MockTransport(fake), out=lines.append)
    return n, lines


def base(fake, mid):
    return fake.models[mid]['litellm_params']['api_base']


def test_dry_run_default_writes_nothing(tmp_path):
    f = FakeLiteLLM()
    n, lines = run(f, tmp_path)
    assert n == 2 and lines[0].startswith('DRY RUN')
    assert all(c[0] == 'GET' for c in f.calls)
    assert not (tmp_path / 'b.json').exists()
    assert any('id1' in l and 'http://img-edit-shim:8099/api.inferhub.dev/v1' in l for l in lines)
    assert any('skip other-img' in l for l in lines)


def test_apply_switches_only_api_base_and_never_sends_or_prints_key(tmp_path, capsys):
    f = FakeLiteLLM()
    before = json.loads(json.dumps(f.models))
    n, lines = run(f, tmp_path, '--apply')
    assert n == 2
    for mid in ('id1', 'id4'):
        assert base(f, mid) == 'http://img-edit-shim:8099/api.inferhub.dev/v1'
    assert base(f, 'id2') == 'https://api.openai.com/v1' and base(f, 'id3') == 'https://api.inferhub.dev/v1'
    for mid, m in f.models.items():
        a, b = dict(m['litellm_params']), dict(before[mid]['litellm_params'])
        a.pop('api_base'), b.pop('api_base')
        assert a == b and m['model_info'] == before[mid]['model_info']
    patches = [c for c in f.calls if c[0] == 'PATCH']
    assert len(patches) == 2
    for _, path, body in patches:
        assert json.loads(body) == {'litellm_params': {'api_base': 'http://img-edit-shim:8099/api.inferhub.dev/v1'}}
    blob = b''.join(c[2] for c in f.calls).decode() + '\n'.join(lines) + (tmp_path / 'b.json').read_text()
    assert SECRET not in blob and 'api_key' not in blob and 'sk-R' not in blob and MASTER not in blob
    assert json.loads((tmp_path / 'b.json').read_text()) == {'id1': 'https://api.inferhub.dev/v1', 'id4': 'https://api.inferhub.dev/v1'}
    assert oct((tmp_path / 'b.json').stat().st_mode & 0o777) == '0o600'


def test_apply_single_model_and_idempotent(tmp_path):
    f = FakeLiteLLM()
    assert run(f, tmp_path, '--apply', '--model-name', 'gpt-image-2')[0] == 1
    assert base(f, 'id4') == 'https://api.inferhub.dev/v1'
    assert run(f, tmp_path, '--apply', '--model-name', 'gpt-image-2')[0] == 0
    assert json.loads((tmp_path / 'b.json').read_text()) == {'id1': 'https://api.inferhub.dev/v1'}


def test_revert_dry_run_then_apply(tmp_path):
    f = FakeLiteLLM()
    run(f, tmp_path, '--apply')
    n, lines = run(f, tmp_path, '--revert')
    assert n == 2 and base(f, 'id1') == 'http://img-edit-shim:8099/api.inferhub.dev/v1'
    n, _ = run(f, tmp_path, '--revert', '--apply')
    assert n == 2
    assert base(f, 'id1') == 'https://api.inferhub.dev/v1' and base(f, 'id4') == 'https://api.inferhub.dev/v1'
    assert json.loads((tmp_path / 'b.json').read_text()) == {}
    assert run(f, tmp_path, '--revert', '--apply')[0] == 0


def test_aborts_and_restores_if_other_field_changes(tmp_path):
    f = FakeLiteLLM(drop_key_on_patch=True)
    with pytest.raises(sw.SwitchError, match='fields other than api_base changed'):
        run(f, tmp_path, '--apply', '--model-name', 'gpt-image-2')
    assert base(f, 'id1') == 'https://api.inferhub.dev/v1'  # restore attempted
    assert [c[0] for c in f.calls].count('PATCH') == 2


def test_error_does_not_echo_body(tmp_path):
    def bad(request):
        return httpx.Response(500, text=SECRET)
    with pytest.raises(sw.SwitchError) as e:
        sw.run(args(tmp_path), ENV, httpx.MockTransport(bad), out=lambda s: None)
    assert SECRET not in str(e.value)


def test_requires_env(tmp_path):
    with pytest.raises(sw.SwitchError):
        sw.run(args(tmp_path), {}, out=lambda s: None)


def test_load_env_file_and_env_precedence(tmp_path):
    p = tmp_path / '.env'
    p.write_text('# c\nLITELLM_BASE="http://a:4000"\nLITELLM_MASTER_KEY=k1\nOTHER=x\n')
    assert sw.load_env(str(p), {'LITELLM_MASTER_KEY': 'k2'}) == {'LITELLM_BASE': 'http://a:4000', 'LITELLM_MASTER_KEY': 'k2'}


@pytest.mark.parametrize('base_', ['http://api.inferhub.dev/v1', 'https://api.inferhub.dev:8443/v1', 'https://u@api.inferhub.dev/v1',
                                   'https://evil.com/v1', None])
def test_shim_url_rejects_unsafe(base_):
    assert sw.shim_url(base_, 'http://s:8099', {'api.inferhub.dev'}) is None
