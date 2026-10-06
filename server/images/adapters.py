"""Verified InferHub [OI] image provider adapter contracts.

Contract source (read-only, no credential, no paid request):
<https://inferhub.dev/api/openapi.json>, ``POST /v1/images/generations`` and
``POST /v1/images/edits``. The three configured backends
(``cb/gemini-2.5-flash-image``, ``cb/gemini-3.1-flash-image``,
``cb/gpt-image-2``) share this JSON shape, so one contract parameterised by the
configured model is the real contract for each of them.

This module is deliberately free of transport and storage concerns: it builds
the documented request, validates the model's advertised operation/size, and
classifies a non-2xx response into the service's typed signals. It never infers
nonacceptance from a bare HTTP status.
"""
from dataclasses import dataclass

GENERATE_PATH = '/v1/images/generations'
EDIT_PATH = '/v1/images/edits'
OPERATIONS = ('generate', 'edit')
N = 1
RESPONSE_FORMAT = 'b64_json'
MAX_ERROR_BYTES = 64 * 1024

# InferHub documents these codes as refused before any provider is tried, so no
# job can have been accepted or billed. ``validation_error`` is deliberately not
# listed: the documented 400 contract also covers "an upstream payload
# rejection", which may follow submission and therefore stays ambiguous.
PRE_PROVIDER_REFUSAL_CODES = frozenset({
    'not_an_image_model',
    'unsupported_modality',
    'unsupported_n',
})
# A *structured* gateway error on these statuses proves the gateway refused
# before routing (503 = "No provider can serve this model right now";
# 429 = rate limit). A bare status without that body may be a proxy error that
# follows a charge, so it stays ambiguous.
STRUCTURED_REFUSAL_STATUSES = frozenset({429, 503})


@dataclass(frozen=True)
class ProviderContract:
    model: str
    sizes: tuple
    edit: bool

    def __post_init__(self):
        if not isinstance(self.model, str) or not self.model:
            raise ValueError('A provider model id is required')
        if not self.sizes:
            raise ValueError('At least one provider size is required')

    def endpoint(self, operation):
        if operation == 'generate':
            return GENERATE_PATH
        if operation == 'edit' and self.edit:
            return EDIT_PATH
        raise ValueError('Unsupported image operation')

    def request(self, operation, body, size):
        if operation not in OPERATIONS or not isinstance(body, dict):
            raise ValueError('Unsupported image operation')
        if size not in self.sizes:
            raise ValueError('Unsupported image size')
        if operation == 'edit' and not self.edit:
            raise ValueError('Backend does not support image edits')
        payload = {'model': self.model, 'prompt': body.get('prompt'), 'size': size,
                   'n': N, 'response_format': RESPONSE_FORMAT}
        if operation == 'edit':
            payload['image'] = body.get('image')
        return payload


def request_shape(model, operation, body, size):
    """Canonical documented payload; the service uses this as its only shape."""
    return ProviderContract(model, (size,), operation == 'edit').request(operation, body, size)


def structured_error_code(body):
    """Return InferHub's documented ``error.code`` iff the body matches it."""
    if not isinstance(body, dict):
        return None
    error = body.get('error')
    if not isinstance(error, dict):
        return None
    code = error.get('code')
    return code if isinstance(code, str) and code else None


def is_verified_refusal(status, body):
    """True only for evidence that this attempt was refused before execution.

    A bare HTTP status is never sufficient; the caller must supply the decoded
    response body so a proxy/upstream error cannot masquerade as nonacceptance.
    """
    code = structured_error_code(body)
    if code is None:
        return False
    if status in STRUCTURED_REFUSAL_STATUSES:
        return True
    return status == 400 and code in PRE_PROVIDER_REFUSAL_CODES
