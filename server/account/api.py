"""Isolated account routes. No public finalize route exists."""

from fastapi import APIRouter, Header, HTTPException, Request
from pydantic import BaseModel, ConfigDict
from .domain import AccountError


class DeleteRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    request_id: str


class RestoreRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    consent: bool


class UnblockRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    reason: str


def router(service, verify):
    routes = APIRouter(prefix='/account', tags=['account'])

    def run(action, authorization, attestation, http_request=None, allow_disabled=False):
        try:
            if not authorization.startswith('Bearer ') or not authorization[7:]:
                raise AccountError('missing_authentication', 401)
            claims = verify(authorization[7:], attestation, allow_disabled=allow_disabled)
            if http_request is not None:
                service.observe(claims, http_request)
            return action(claims)
        except AccountError as error:
            raise HTTPException(error.status, detail=error.code) from None

    @routes.post('/deletion')
    def request_deletion(body: DeleteRequest, http_request: Request,
                         authorization: str = Header(default=''),
                         x_firebase_appcheck: str = Header(default='')):
        return run(lambda claims: service.request(claims, body.request_id),
                   authorization, x_firebase_appcheck, http_request)

    @routes.get('/deletion')
    def status(http_request: Request, authorization: str = Header(default=''),
               x_firebase_appcheck: str = Header(default='')):
        return run(service.status, authorization, x_firebase_appcheck, http_request)

    @routes.post('/login')
    def acknowledge_login(http_request: Request, authorization: str = Header(default=''),
                          x_firebase_appcheck: str = Header(default='')):
        return run(service.login, authorization, x_firebase_appcheck, http_request)

    @routes.post('/deletion/cancel')
    def cancel(body: RestoreRequest, http_request: Request,
               authorization: str = Header(default=''),
               x_firebase_appcheck: str = Header(default='')):
        if body.consent is not True:
            raise HTTPException(400, detail='explicit_consent_required')
        # Disabled-token exception is narrowly confined to explicit recovery.
        return run(service.cancel, authorization, x_firebase_appcheck, http_request, True)

    @routes.post('/security/{uid}/sessions/{session_id}/unblock')
    def unblock(uid: str, session_id: str, body: UnblockRequest, http_request: Request,
                authorization: str = Header(default=''),
                x_firebase_appcheck: str = Header(default='')):

        def action(claims):
            # Firebase custom claims are the admin boundary; a normal account
            # cannot override another account's block.
            if claims.get('admin') is not True:
                raise AccountError('admin_required', 403)
            if not 1 <= len(body.reason.strip()) <= 500:
                raise AccountError('invalid_reason', 400)
            return service.unblock_session(
                uid, session_id, actor=claims['uid'], reason=body.reason.strip())

        return run(action, authorization, x_firebase_appcheck, http_request)

    return routes
