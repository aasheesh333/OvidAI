"""InferHub's documented JSON image API, not multipart or chat emulation."""
import json
from decimal import Decimal

import httpx

from . import adapters
from .service import Backend, ImageError, ImageService, MAX_BYTES, UpstreamError, UpstreamNotAccepted


class InferHub:
    def __init__(self, key, client=None, contracts=None):
        self.key = key
        self.client = client or httpx.Client(timeout=120, follow_redirects=False)
        self.contracts = dict(contracts or {})

    def contract(self, backend):
        contract = self.contracts.get(backend.model)
        if contract is None:
            contract = adapters.ProviderContract(backend.model, backend.sizes, backend.edit)
            self.contracts[backend.model] = contract
        return contract

    def verify_catalog(self, backends):
        response = self.client.get('https://api.inferhub.dev/v1/models',
                                   headers={'Authorization': f'Bearer {self.key}'})
        if response.status_code != 200:
            raise ImageError()
        catalog = {row['id']: row for row in response.json().get('data', [])}
        for backend in backends:
            row = catalog.get(backend.model, {})
            if row.get('output_modality') != 'image' or (backend.edit and 'image' not in row.get('modality', '').split(',')):
                raise ImageError()
            self.contracts[backend.model] = adapters.ProviderContract(backend.model, backend.sizes, backend.edit)

    @staticmethod
    def _error_body(response):
        """Decode a bounded error body; anything else is ambiguous, not a refusal."""
        data = bytearray()
        for chunk in response.iter_bytes():
            data.extend(chunk)
            if len(data) > adapters.MAX_ERROR_BYTES:
                return None
        if not data:
            return None
        try:
            return json.loads(bytes(data))
        except (ValueError, UnicodeError):
            return None

    def __call__(self, backend, operation, payload):
        endpoint = self.contract(backend).endpoint(operation)
        with self.client.stream('POST', f'https://api.inferhub.dev{endpoint}',
                                headers={'Authorization': f'Bearer {self.key}'}, json=payload) as response:
            if response.status_code != 200:
                # Only a structured, documented pre-provider refusal is a typed
                # nonacceptance that may release/fall back. Bare 429/5xx and any
                # upstream payload rejection stay ambiguous: they may follow a
                # charge, so the reservation is preserved and never re-sent.
                if adapters.is_verified_refusal(response.status_code, self._error_body(response)):
                    raise UpstreamNotAccepted(response.status_code)
                raise UpstreamError(response.status_code)
            data = bytearray()
            for chunk in response.iter_bytes():
                data.extend(chunk)
                if len(data) > MAX_BYTES * 4 // 3 + 65536:
                    raise ImageError(502, 'invalid_image_response')
            return json.loads(data, parse_float=Decimal)


def configured_service(config_path, ledger, transport, *, enforced_max_upstream_cost):
    """Caller must enforce this cost ceiling before enabling paid traffic.

    InferHub documents live per-token asks, but no hard per-image spend cap.
    Do not treat a cheapest ask or a quality option as a maximum charge.
    """
    with open(config_path) as source:
        config = json.load(source)
    if config['alias'] != 'ovid-image' or config['base_url'] != 'https://api.inferhub.dev/v1':
        raise ValueError('Invalid private image configuration')
    backends = [Backend(row['model'], tuple(row['sizes']), row['edit']) for row in config['backends']]
    transport.verify_catalog(backends)
    return ImageService(backends, ledger, transport, enforced_max_upstream_cost)
