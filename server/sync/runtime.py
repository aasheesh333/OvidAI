"""Host composition for the private sync API."""

from contextlib import contextmanager

from .api import failure, router
from .errors import SyncError


def mount_sync(app, repository, lifecycle, admin, prefix="/sync/v1"):
    """Mount the sync API under ``prefix`` without duplicating its router path."""
    prefix = "/" + prefix.strip("/")
    if prefix == "/":
        raise ValueError("sync prefix must not be empty")

    def verify(token, app_check):
        return admin.verify(token, app_check)

    @contextmanager
    def admission(claims):
        from server.account.domain import AccountError

        try:
            with lifecycle.access(claims) as uid:
                yield uid
        except AccountError as error:
            code = "account_fenced" if error.status == 403 else "temporarily_unavailable"
            raise SyncError(code) from None

    routes = router(repository, verify, admission)
    router_prefix = "/sync/v1"
    if prefix != router_prefix:
        for route in routes.routes:
            if hasattr(route, "path") and route.path.startswith(router_prefix):
                route.path = prefix + route.path[len(router_prefix):]
                if hasattr(route, "path_format"):
                    route.path_format = route.path
    app.include_router(routes)

    @app.middleware("http")
    async def sync_boundary(request, call_next):
        path = request.url.path
        if path != prefix and not path.startswith(prefix + "/"):
            return await call_next(request)
        try:
            result = await call_next(request)
        except Exception:
            return failure(SyncError("temporarily_unavailable"), 500)
        if result.status_code >= 400 and result.headers.get("cache-control") != "no-store":
            code = ("temporarily_unavailable" if result.status_code >= 500 else
                    "not_found" if result.status_code == 404 else "invalid_request")
            return failure(SyncError(code), result.status_code)
        result.headers["Cache-Control"] = "no-store"
        return result
