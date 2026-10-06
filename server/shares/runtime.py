"""Host composition retaining the account lock through repository operations."""
from contextlib import contextmanager
from urllib.parse import urlsplit

from fastapi import HTTPException

from .api import router


def mount_shares(app, repository, lifecycle, admin, base_url):
    def verify(token, attestation):
        return admin.verify(token, attestation, allow_disabled=False)

    @contextmanager
    def admission(claims):
        from server.account.domain import AccountError
        try:
            with lifecycle.access(claims) as uid:
                yield uid
        except AccountError as error:
            raise HTTPException(error.status, error.code) from None

    routes = router(repository, verify, base_url, admission=admission)
    app.include_router(routes, prefix=urlsplit(base_url.rstrip('/')).path)
