"""Isolated account routes. No public finalize route exists."""

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, ConfigDict
from .domain import AccountError


class DeleteRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    request_id: str


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
    @routes.post('/deletion/cancel')
    def login(authorization: str = Header(default=''),
              x_firebase_appcheck: str = Header(default='')):
        # Disabled-token exception is narrowly confined to cancellation.
        # Lifecycle checks the durable fence ownership and grace auth_time.
        return run(service.login, authorization, x_firebase_appcheck, True)

    return routes
