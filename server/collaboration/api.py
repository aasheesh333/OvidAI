"""Authenticated, bounded HTTP transport for private collaboration sessions."""

from __future__ import annotations

import json
import inspect
import re
import zlib
from typing import Any

from fastapi import APIRouter, Header, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.routing import APIRoute

from .events import EventRejected, canonical_bytes
from .repository import CollabError, MAX_BATCH_BYTES

MAX_BODY_BYTES = 1024 * 1024
MAX_EVENTS = 100
MAX_CURSOR_BYTES = 512
MAX_REPLAY_EVENTS = 100
MAX_REPLAY_BYTES = 256 * 1024

_MESSAGES = {
    "unauthenticated": "Authentication required",
    "invalid_identity": "Authentication required",
    "invalid_request": "Invalid request",
    "not_member": "Not a session member",
    "not_owner": "Owner permission required",
    "invite_invalid": "Invitation is invalid",
    "membership_revoked": "Membership is revoked",
    "session_not_found": "Session not found",
    "member_not_found": "Member not found",
    "session_closed": "Session is closed",
    "session_full": "Session is full",
    "owner_not_removable": "Owner cannot be removed",
    "event_id_conflict": "Event conflicts with an existing event",
    "request_already_used": "Request was already used",
    "cursor_reset": "Replay cursor must be reset",
    "account_deleted": "Account is unavailable",
    "account_deletion_pending": "Account is unavailable",
    "unsupported_identity": "Authentication required",
    "temporarily_unavailable": "The collaboration service is temporarily unavailable",
    "rate_limited": "Collaboration rate limit exceeded",
    "quota_exhausted": "Collaboration quota exceeded",
    "payload_too_large": "Collaboration payload is too large",
    "invite_not_found": "Invitation not found",
}
_ERROR_CODES = frozenset(_MESSAGES)


class _PayloadTooLarge(Exception):
    pass


def router(repository, verifier, admission, *, prefix="") -> APIRouter:
    def failure(code: str, status: int | None = None):
        if code == "invalid_identity":
            code = "unauthenticated"
        return JSONResponse(
            {"schemaVersion": 1, "code": code,
             "message": _MESSAGES.get(code, "Invalid request")},
            status_code=status or 400,
            headers={"Cache-Control": "no-store"},
        )

    class CollaborationRoute(APIRoute):
        def get_route_handler(self):
            original = super().get_route_handler()

            async def handle_validation(request: Request):
                try:
                    return await original(request)
                except RequestValidationError:
                    return failure("invalid_request")

            return handle_validation

    routes = APIRouter(prefix=prefix, tags=["collaboration"],
                       route_class=CollaborationRoute)

    def value(claims: Any, name: str):
        result = claims.get(name) if isinstance(claims, dict) else getattr(claims, name, None)
        if type(result) is not str or not result:
            raise CollabError("invalid_identity")
        return result

    def authenticate(authorization: str, app_check: str):
        if (not authorization.startswith("Bearer ") or not authorization[7:] or
                not isinstance(app_check, str) or not app_check):
            raise CollabError("invalid_identity")
        try:
            return verifier(authorization[7:], app_check)
        except CollabError:
            raise
        except Exception:
            raise CollabError("invalid_identity") from None

    def call(claims, operation):
        with admission(claims) as admitted:
            uid = admitted if isinstance(admitted, str) else value(admitted, "uid")
            return operation(uid)

    def ok(body=None):
        return JSONResponse({"schemaVersion": 1, **(body or {})},
                            headers={"Cache-Control": "no-store"})

    async def body(request: Request):
        raw = bytearray()
        encoding = request.headers.get('content-encoding', 'identity').lower()
        if encoding not in ('identity', 'gzip'):
            raise CollabError('invalid_request')
        async for chunk in request.stream():
            if len(raw) + len(chunk) > MAX_BODY_BYTES:
                raise _PayloadTooLarge
            raw.extend(chunk)
        if encoding == 'gzip':
            try:
                decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
                raw = decoder.decompress(raw, MAX_BATCH_BYTES + 1)
                if len(raw) > MAX_BATCH_BYTES or decoder.unconsumed_tail:
                    raise _PayloadTooLarge
                if not decoder.eof or decoder.unused_data:
                    raise CollabError('invalid_request')
            except zlib.error:
                raise CollabError('invalid_request') from None
        try:
            parsed = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError, RecursionError):
            raise CollabError("invalid_request") from None
        if type(parsed) is not dict:
            raise CollabError("invalid_request")
        if (type(parsed.get("schemaVersion")) is not int or
                parsed["schemaVersion"] != 1 or
                type(parsed.get("idempotencyKey")) is not str or
                not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', parsed["idempotencyKey"])):
            raise CollabError("invalid_request")
        if len(canonical_bytes(parsed)) > MAX_BATCH_BYTES:
            raise _PayloadTooLarge
        return parsed

    async def handle(action):
        try:
            result = action()
            if inspect.isawaitable(result):
                result = await result
            return result
        except EventRejected:
            return failure("invalid_request")
        except _PayloadTooLarge:
            return failure("invalid_request", 413)
        except CollabError as error:
            status = getattr(error, "status", 400)
            code = error.code
            if code == "payload_too_large":
                status = 413
            return failure(code, status)
        except (TypeError, ValueError, KeyError, AttributeError, RuntimeError):
            return failure("temporarily_unavailable", 500)
        except Exception:
            return failure("temporarily_unavailable", 500)

    def auth_action(authorization, app_check, operation):
        claims = authenticate(authorization, app_check)
        return call(claims, operation)

    @routes.post("")
    async def create(request: Request, authorization: str = Header(default=""),
                     x_firebase_appcheck: str = Header(default="")):
        return await handle(lambda: _create(request, authorization, x_firebase_appcheck))

    async def _create(request, authorization, app_check):
        claims = authenticate(authorization, app_check)
        data = await body(request)
        if (set(data) != {"schemaVersion", "requestId", "idempotencyKey"} or
                data["schemaVersion"] != 1 or
                type(data["requestId"]) is not str or
                type(data["idempotencyKey"]) is not str or
                data["requestId"] != data["idempotencyKey"]):
            raise CollabError("invalid_request")
        result = call(claims, lambda uid: repository.create_session(uid, data["requestId"]))
        return ok({"schemaVersion": 1, **result})

    @routes.get("/{session_token}")
    async def state(session_token: str, authorization: str = Header(default=""),
              x_firebase_appcheck: str = Header(default="")):
        return await handle(lambda: ok(auth_action(authorization, x_firebase_appcheck,
                                                    lambda uid: {"schemaVersion": 1,
                                                                 **repository.get_state(uid, session_token)})))

    @routes.post("/{session_token}/members")
    async def members(session_token: str, request: Request,
                      authorization: str = Header(default=""),
                      x_firebase_appcheck: str = Header(default="")):
        return await handle(lambda: _members(session_token, request, authorization, x_firebase_appcheck))

    async def _members(token, request, authorization, app_check):
        claims = authenticate(authorization, app_check)
        data = await body(request)
        keys = set(data)
        if (keys == {"schemaVersion", "invitationCode", "idempotencyKey"} and
                data["schemaVersion"] == 1 and
                type(data["invitationCode"]) is str and
                type(data["idempotencyKey"]) is str):
            def join_operation(uid):
                return repository.join(uid, token, data["invitationCode"],
                                       idempotency_key=data["idempotencyKey"], with_cursor=True)
            return ok(call(claims, join_operation))
        if (keys <= {"schemaVersion", "maxUses", "ttlSeconds", "idempotencyKey"} and
                "schemaVersion" in keys and "idempotencyKey" in keys and
                data["schemaVersion"] == 1 and type(data["idempotencyKey"]) is str):
            max_uses = data.get("maxUses", 1)
            ttl = data.get("ttlSeconds", 86400)
            if type(max_uses) is not int or type(ttl) is not int:
                raise CollabError("invalid_request")
            return ok({"schemaVersion": 1, **call(claims, lambda uid: repository.create_invite(
                 uid, token, max_uses=max_uses, ttl_seconds=ttl,
                 idempotency_key=data["idempotencyKey"]))})
        raise CollabError("invalid_request")

    @routes.delete("/{session_token}/members/me")
    async def leave(session_token: str, authorization: str = Header(default=""),
                    x_firebase_appcheck: str = Header(default="")):
        return await handle(lambda: ok(auth_action(
            authorization, x_firebase_appcheck, lambda uid: repository.leave(uid, session_token))))

    @routes.delete("/{session_token}/members/{participant_id}")
    async def revoke(session_token: str, participant_id: str,
               authorization: str = Header(default=""),
               x_firebase_appcheck: str = Header(default="")):
        return await handle(lambda: ok(auth_action(
            authorization, x_firebase_appcheck,
            lambda uid: repository.revoke_member(uid, session_token, participant_id))))

    @routes.post("/{session_token}/events")
    async def append(session_token: str, request: Request,
                     authorization: str = Header(default=""),
                     x_firebase_appcheck: str = Header(default="")):
        return await handle(lambda: _append(session_token, request, authorization, x_firebase_appcheck))

    async def _append(token, request, authorization, app_check):
        claims = authenticate(authorization, app_check)
        data = await body(request)
        if (set(data) != {"schemaVersion", "idempotencyKey", "events"} or
                data["schemaVersion"] != 1 or type(data["idempotencyKey"]) is not str):
            raise CollabError("invalid_request")
        events = data["events"]
        if type(events) is not list or not 1 <= len(events) <= MAX_EVENTS:
            raise CollabError("invalid_request")
        result = call(claims, lambda uid: repository.append_batch(
            uid, token, events, idempotency_key=data["idempotencyKey"]))
        return ok(result)

    @routes.get("/{session_token}/events")
    async def replay(session_token: str, cursor: str | None = Query(default=None),
               limit: int = Query(default=100, ge=1, le=100),
               authorization: str = Header(default=""),
               x_firebase_appcheck: str = Header(default="")):
        def operation(uid):
            if cursor is not None and len(cursor.encode()) > MAX_CURSOR_BYTES:
                raise CollabError("cursor_reset")
            result = repository.replay(uid, session_token, cursor, limit=limit,
                                       max_bytes=MAX_REPLAY_BYTES)
            return {"schemaVersion": 1, "events": result["events"],
                    "nextCursor": result["cursor"], "hasMore": result["hasMore"]}
        return await handle(lambda: ok(auth_action(authorization, x_firebase_appcheck, operation)))

    @routes.post("/{session_token}/close")
    async def close(session_token: str, request: Request,
                    authorization: str = Header(default=""),
               x_firebase_appcheck: str = Header(default="")):
        return await handle(lambda: _close(session_token, request, authorization,
                                            x_firebase_appcheck))

    async def _close(token, request, authorization, app_check):
        claims = authenticate(authorization, app_check)
        data = await body(request)
        if set(data) != {"schemaVersion", "idempotencyKey"} or data["schemaVersion"] != 1 or type(data["idempotencyKey"]) is not str:
            raise CollabError("invalid_request")
        return ok({"session": call(claims, lambda uid: repository.close(
            uid, token, idempotency_key=data["idempotencyKey"]))})

    return routes
