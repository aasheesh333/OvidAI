"""Direct JSON image-edit transport for OpenAI-compatible providers (InferHub).

Why: the provider documents ``POST <api_base>/images/edits`` as
application/json ONLY (single ``image`` data URL; no mask, no extra images, no
background). LiteLLM can only forward edits as multipart/form-data, which the
provider rejects ("body must be JSON"). So the gateway calls the provider
directly for edits, using a dedicated key from env ``INFERHUB_API_KEY``.

Safety: https only, host must be in ``OVID_IMAGE_DIRECT_EDIT_HOSTS`` (default
``api.inferhub.dev``) and is taken from the discovered ``api_base`` (never from
a user value). The key is only ever put in the Authorization header; it is
never logged, returned or stored in a card.
"""
import logging
import os
from decimal import Decimal
from urllib.parse import urlsplit

import httpx

from .adapters import request_shape

DEFAULT_HOSTS = 'api.inferhub.dev'
_LOG = logging.getLogger('ovid.images.directedit')


def provider_model_id(litellm_model):
    """``openai/cb/gpt-image-2`` -> ``cb/gpt-image-2`` (only a leading openai/)."""
    if not isinstance(litellm_model, str):
        return None
    model = litellm_model[len('openai/'):] if litellm_model.startswith('openai/') else litellm_model
    return model or None


class DirectEdit:
    def __init__(self, api_key='', hosts=DEFAULT_HOSTS, edit_cost=None, timeout=120.0, client_factory=None):
        self._key = (api_key or '').strip()
        if isinstance(hosts, str):
            hosts = hosts.split(',')
        self.hosts = frozenset(h.strip().lower() for h in hosts if h and h.strip())
        self.edit_cost = Decimal(str(edit_cost)) if edit_cost is not None else None
        self.timeout = timeout
        self.client_factory = client_factory or (lambda **kw: httpx.Client(**kw))
        self._warned = set()

    @classmethod
    def from_env(cls, max_upstream, timeout=120.0, env=None):
        env = os.environ if env is None else env
        raw = (env.get('OVID_IMAGE_EDIT_COST_USD') or '').strip()
        try:
            cost = Decimal(raw) if raw else Decimal(str(max_upstream))
            if not cost.is_finite() or cost <= 0:
                raise ValueError()
        except Exception:  # noqa: BLE001
            _LOG.warning('OVID_IMAGE_EDIT_COST_USD invalid; using the upstream bound')
            cost = Decimal(str(max_upstream))
        # Never settle above the owner-enforced bound.
        cost = min(cost, Decimal(str(max_upstream)))
        return cls(env.get('INFERHUB_API_KEY', ''), env.get('OVID_IMAGE_DIRECT_EDIT_HOSTS') or DEFAULT_HOSTS,
                   cost, timeout)

    def _warn_once(self, reason):
        if reason not in self._warned:
            self._warned.add(reason)
            _LOG.warning('direct image edit disabled: %s', reason)

    @property
    def has_key(self):
        return bool(self._key)

    def target(self, params):
        """-> (url, provider_model_id) or None when direct edit is not allowed."""
        if not self._key:
            self._warn_once('INFERHUB_API_KEY is not set')
            return None
        params = params or {}
        base = params.get('api_base')
        model = provider_model_id(params.get('model'))
        if not isinstance(base, str) or not model:
            return None
        try:
            parts = urlsplit(base.strip())
            host = (parts.hostname or '').lower()
            port = parts.port
        except ValueError:
            return None
        if parts.scheme != 'https' or parts.username or parts.password or parts.query or parts.fragment \
                or port not in (None, 443) or not host:
            self._warn_once('api_base is not a plain https URL')
            return None
        if host not in self.hosts:
            self._warn_once(f'host {host} is not in OVID_IMAGE_DIRECT_EDIT_HOSTS')
            return None
        return f'https://{host}{parts.path.rstrip("/")}/images/edits', model

    def enabled_for(self, params):
        return self.target(params) is not None

    def post(self, params, prompt, size, image_data_url):
        """POST the documented JSON edit; returns the raw httpx.Response."""
        target = self.target(params)
        if target is None:
            raise RuntimeError('direct edit not enabled')
        url, model = target
        body = request_shape(model, 'edit', {'prompt': prompt, 'image': image_data_url}, size)
        with self.client_factory(timeout=self.timeout, follow_redirects=False) as client:
            return client.post(url, headers={'Authorization': f'Bearer {self._key}'}, json=body)

    def settlement_cost(self, response_json, bound):
        """Provider usage cost when usable (never above ``bound``), else the flat price."""
        bound = Decimal(str(bound))
        flat = min(self.edit_cost if self.edit_cost is not None else bound, bound)
        try:
            usage = response_json.get('usage') if isinstance(response_json, dict) else None
            raw = usage.get('cost') if isinstance(usage, dict) else None
            if isinstance(raw, (int, float, str)) and not isinstance(raw, bool):
                value = Decimal(str(raw))
                if value.is_finite() and value > 0:
                    return min(value, bound)
        except Exception:  # noqa: BLE001
            pass
        return flat
