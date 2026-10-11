"""POST /v1/reports: authenticated in-app reports of AI output and UGC."""

from contextlib import nullcontext
from typing import Literal

from fastapi import APIRouter, Depends, Header, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from .repository import ReportError

HEADERS = {'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff'}

Kind = Literal['ai_output', 'shared_conversation', 'collab_message', 'collab_participant']
Reason = Literal['sexual', 'child_safety', 'hate', 'violence', 'self_harm', 'illegal',
                 'misleading', 'privacy', 'spam', 'other']


class CreateReport(BaseModel):
    # Reporter identity comes only from the verified token, never the body.
    model_config = ConfigDict(extra='forbid')
    request_id: str = Field(pattern=r'^[A-Za-z0-9_-]{16,64}$')
    kind: Kind
    reason: Reason
    details: str = Field(default='', max_length=1000)
    excerpt: str = Field(default='', max_length=4000)
    target_id: str | None = Field(default=None, max_length=128)
    model: str | None = Field(default=None, max_length=128)


def router(repository, verify_uid, *, admission=None):
    """verify_uid(token, attestation) -> verified UID or raises."""
    routes = APIRouter(tags=['reports'])

    def reporter(authorization: str = Header(default=''),
                 x_firebase_appcheck: str = Header(default='')):
        if not authorization.startswith('Bearer ') or not authorization[7:].strip():
            raise HTTPException(401, 'authentication_required')
        try:
            uid = verify_uid(authorization[7:], x_firebase_appcheck)
        except HTTPException:
            raise
        except Exception:
            raise HTTPException(401, 'invalid_authentication') from None
        if admission is None and (not isinstance(uid, str) or not uid.strip()):
            raise HTTPException(401, 'invalid_identity')
        return uid

    @routes.post('/v1/reports', status_code=201)
    def create(body: CreateReport, uid=Depends(reporter)):
        try:
            with admission(uid) if admission else nullcontext(uid) as admitted_uid:
                result = repository.create(admitted_uid, body.model_dump())
        except ReportError as error:
            return JSONResponse({'detail': error.code}, status_code=error.status, headers=HEADERS)
        return JSONResponse({'id': result['id']}, status_code=201 if result['created'] else 200,
                            headers=HEADERS)

    return routes
