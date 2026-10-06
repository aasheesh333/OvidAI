"""Production host factory; no mint, budget authority or deployment path invented."""
import json
from contextlib import contextmanager
from dataclasses import dataclass

from .inferhub import configured_service
from .service import Backend, ImageError
from .verifier import VerifierAuth, mount_images


@dataclass(frozen=True)
class AccountIdentity:
    uid: str
    key_id: str
    tier: str
    claims: dict


def mount_configured_images(mint, lifecycle, admin, stores, config_path, *,
                            transport=None, admission=None,
                            enforced_max_upstream_cost=None, key_client=None):
    """Mount on the actual mint app with its shared admission context manager.

    `stores` must be the same validated object used for account composition.
    Missing paid prerequisites still install private catalog masking and 503
    image routes. No upstream catalog call occurs in that inactive state.
    """
    if stores is not lifecycle.data.stores:
        raise ValueError('Image serving and account cleanup must share authorities')
    with open(config_path, encoding='utf-8') as source:
        config = json.load(source)
    if config['alias'] != 'ovid-image' or config['base_url'] != 'https://api.inferhub.dev/v1':
        raise ValueError('Invalid private image configuration')
    backends = [Backend(row['model'], tuple(row['sizes']), row['edit']) for row in config['backends']]
    active = (getattr(mint, 'APPCHECK_ENABLED', False) is True and
              transport is not None and callable(admission) and
              enforced_max_upstream_cost is not None)
    if not active:
        mount_images(mint, private_backends=backends, auth=lambda headers: None)
        return None

    key_auth = VerifierAuth(mint, key_client)

    class Auth:
        def verify_identity(self, headers):
            try:
                authorization = headers.get('authorization', '')
                if not authorization.lower().startswith('bearer '):
                    raise ValueError()
                claims = admin.verify(authorization.split(' ', 1)[1],
                                      headers.get('x-firebase-appcheck', ''), allow_disabled=False)
                from server.account.domain import identity
                uid = identity(claims)
                verified = key_auth.verify_identity(headers)
                if verified.uid != uid:
                    raise ValueError()
                return AccountIdentity(uid, verified.key_id, verified.tier, claims)
            except ImageError:
                raise
            except Exception:
                raise ImageError(401, 'sign_in_required') from None

        def __call__(self, headers):
            verified = self.verify_identity(headers)
            if verified.tier == 'free' and mint.free_cap_remaining(verified.uid) <= 0:
                raise ImageError(402, 'image_limit_reached')
            return verified

    @contextmanager
    def account_access(verified):
        from server.account.domain import AccountError
        try:
            with lifecycle.access(verified.claims) as uid:
                if uid != verified.uid:
                    raise ImageError(403, 'image_access_denied')
                yield
        except AccountError as error:
            raise ImageError(error.status, error.code) from None

    service = configured_service(config_path, stores.images, transport,
                                 enforced_max_upstream_cost=enforced_max_upstream_cost)
    mount_images(mint, service, admission=admission, auth=Auth(),
                 account_access=account_access, private_backends=backends)
    return service
