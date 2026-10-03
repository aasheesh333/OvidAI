"""InferHub's documented JSON image API, not multipart or chat emulation."""
import json

import httpx

from .service import Backend, ImageError, ImageService, MAX_BYTES, UpstreamError


class InferHub:
    def __init__(self, key, client=None):
        self.key = key
        self.client = client or httpx.Client(timeout=120, follow_redirects=False)

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

    def __call__(self, backend, operation, payload):
        endpoint = 'edits' if operation == 'edit' else 'generations'
        with self.client.stream('POST', f'https://api.inferhub.dev/v1/images/{endpoint}',
                                headers={'Authorization': f'Bearer {self.key}'}, json=payload) as response:
            if response.status_code != 200:
                if response.status_code in (502, 504):
                    # A proxy may have timed out after the provider charged.
                    # Outcome is unknown: preserve reservation, no fallback.
                    raise ImageError(409, 'image_request_pending')
                raise UpstreamError(response.status_code)
            data = bytearray()
            for chunk in response.iter_bytes():
                data.extend(chunk)
                if len(data) > MAX_BYTES * 4 // 3 + 65536:
                    raise ImageError(502, 'invalid_image_response')
            return json.loads(data)


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
