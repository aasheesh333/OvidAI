"""Host composition for the collaboration transport."""
from contextlib import contextmanager

from .api import router
from .repository import CollabError


def mount_collaboration(app, repository, lifecycle, admin, prefix='/chat'):
    def verify(token, attestation):
        return admin.verify(token, attestation, allow_disabled=False)

    @contextmanager
    def admission(claims):
        from server.account.domain import AccountError
        try:
            with lifecycle.access(claims) as uid:
                yield uid
        except AccountError as error:
            translated = CollabError(error.code)
            translated.status = error.status
            raise translated from None

    routes = router(repository, verify, admission)
    app.include_router(routes, prefix=prefix.rstrip('/') or '/')
