"""Isolated account routes. No public finalize route exists."""

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, ConfigDict
from .domain import AccountError


class DeleteRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    request_id: str


class RestoreRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    consent: bool


def router(service, verify):
    routes = APIRouter(prefix='/account', tags=['account'])

    def run(action, authorization, attestation, allow_disabled=False):
        try:
            if not authorization.startswith('Bearer ') or not authorization[7:]:
                raise AccountError('missing_authentication', 401)
            claims = verify(authorization[7:], attestation, allow_disabled=allow_disabled)
            return action(claims)
        except AccountError as error:
            raise HTTPException(error.status, detail=error.code) from None

    @routes.post('/deletion')
    def request(body: DeleteRequest, authorization: str = Header(default=''),
                x_firebase_appcheck: str = Header(default='')):
        return run(lambda claims: service.request(claims, body.request_id),
                   authorization, x_firebase_appcheck)

    @routes.get('/deletion')
    def status(authorization: str = Header(default=''),
               x_firebase_appcheck: str = Header(default='')):
        return run(service.status, authorization, x_firebase_appcheck)

    @routes.post('/login')
    def acknowledge_login(authorization: str = Header(default=''),
                          x_firebase_appcheck: str = Header(default='')):
        return run(service.login, authorization, x_firebase_appcheck)

    @routes.post('/deletion/cancel')
    def cancel(body: RestoreRequest, authorization: str = Header(default=''),
              x_firebase_appcheck: str = Header(default='')):
        if body.consent is not True:
            raise HTTPException(400, detail='explicit_consent_required')
        # Disabled-token exception is narrowly confined to explicit recovery.
        return run(service.cancel, authorization, x_firebase_appcheck, True)

    return routes
