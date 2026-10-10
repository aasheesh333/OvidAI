"""Injected, bounded FastAPI transport for private sync."""

from __future__ import annotations

import math
import inspect
import re
import time
import zlib
from typing import Any

from fastapi import APIRouter, Header, Query, Request
from fastapi.responses import JSONResponse, Response
from fastapi.routing import APIRoute
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException

from server.sync.canonical import canonical_bytes, decode_strict
from server.sync.dto import parse_upload
from server.sync.errors import SyncError
from server.sync.results import (parse_batch_result, parse_change_page,
                                  parse_device_enrollment, parse_state_page)

MAX_COMPRESSED_BYTES = 1024 * 1024
MAX_BATCH_BYTES = 8 * 1024 * 1024
MAX_RECORD_BYTES = 256 * 1024
MAX_RECORDS = 100
MAX_CURSOR_BYTES = 512
RECENT_AUTH_SECONDS = 5 * 60


def failure(error: SyncError, status: int | None = None) -> JSONResponse:
    return JSONResponse(error.to_wire(), status_code=status or error.status,
                        headers={"Cache-Control": "no-store"})


class SyncRoute(APIRoute):
    def get_route_handler(self):
        handler = super().get_route_handler()

        async def guarded(request):
            try:
                return await handler(request)
            except RequestValidationError:
                return failure(SyncError("invalid_request"))
            except HTTPException as error:
                return failure(SyncError("not_found" if error.status_code == 404 else "invalid_request"), error.status_code)
            except SyncError as error:
                return failure(error)
            except Exception:
                return failure(SyncError("temporarily_unavailable"), 500)

        return guarded


def bounded_id(value, code="invalid_request"):
    if type(value) is not str or re.fullmatch(r"[\x21-\x7e]{1,128}", value) is None:
        raise SyncError(code)
    return value


def bounded_name(value):
    if type(value) is not str or not 1 <= len(value) <= 128:
        raise SyncError("invalid_request")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        raise SyncError("invalid_request") from None
    return value


async def bounded_body(request):
    data = bytearray()
    async for chunk in request.stream():
        if len(data) + len(chunk) > MAX_COMPRESSED_BYTES:
            raise SyncError("payload_too_large")
        data.extend(chunk)
    return bytes(data)


def page_bounds(cursor, limit):
    try:
        parsed = int(limit)
        # Cursor ownership, format and expiry are repository decisions, after
        # durable account/device rate admission (including malformed cursors).
        if str(parsed) != limit or not 1 <= parsed <= MAX_RECORDS:
            raise ValueError()
    except (TypeError, ValueError, UnicodeError):
        raise SyncError("invalid_request") from None
    return parsed


def router(repository, verify, admission, *, clock=time.time) -> APIRouter:
    routes = APIRouter(prefix="/sync/v1", tags=["sync"], route_class=SyncRoute)

    def bootstrap(uid, device, cursor, limit):
        parameters = inspect.signature(repository.bootstrap).parameters
        if "limit" in parameters:
            return repository.bootstrap(uid, device, cursor or None,
                                        limit=limit, max_bytes=MAX_RECORD_BYTES)
        # The original repository contract has no bounds arguments. Preserve
        # its metadata and use the bounded replay contract for smaller pages.
        state = repository.bootstrap(uid, device, cursor or None)
        if limit == MAX_RECORDS:
            return state
        state = state.to_wire() if hasattr(state, "to_wire") else state
        page = repository.changes(uid, device, cursor, limit=limit,
                                  max_bytes=MAX_RECORD_BYTES)
        page = page.to_wire() if hasattr(page, "to_wire") else page
        return {**state, "records": page["records"], "currentCursor": page["nextCursor"]}

    def run(claims, operation):
        try:
            with admission(claims) as admitted:
                return operation(admitted)
        except SyncError as error:
            return failure(error, 500 if error.code == "temporarily_unavailable" else None)
        except Exception:
            return failure(SyncError("temporarily_unavailable"), 500)

    def identity(authorization: str, app_check: str, device_id: str, *, enrollment=False):
        if not authorization.startswith("Bearer ") or not authorization[7:] or not app_check:
            raise SyncError("unauthenticated")
        if not enrollment:
            bounded_id(device_id, "unauthenticated")
        try:
            claims = verify(authorization[7:], app_check)
            claimed_device = claims.get("device_id") if isinstance(claims, dict) else getattr(claims, "device_id", None)
            if device_id and claimed_device is not None and device_id != claimed_device:
                raise SyncError("unauthenticated")
            return claims
        except SyncError:
            raise
        except Exception:
            raise SyncError("unauthenticated") from None

    def response(value: Any, parser=None) -> Response:
        if value is None:
            value = {}
        if hasattr(value, "to_wire"):
            value = value.to_wire()
        elif hasattr(value, "accepted") and hasattr(value, "duplicates"):
            value = {"accepted": value.accepted, "duplicates": value.duplicates,
                     "rejected": getattr(value, "rejected", 0),
                     "conflicts": getattr(value, "conflicts", 0)}
        elif hasattr(value, "__dict__") and not isinstance(value, dict):
            value = value.__dict__
        if not isinstance(value, dict):
            raise SyncError("temporarily_unavailable")
        if parser is not None:
            try:
                cursor_field = ("nextCursor" if parser is parse_change_page else
                                "currentCursor" if parser is parse_state_page else None)
                if cursor_field is None:
                    value = parser(value).to_wire()
                else:
                    # Response DTOs use a generic 128-scalar text validator.
                    # Cursors have their own 512-byte transport contract.
                    cursor = value.get(cursor_field)
                    if type(cursor) is not str or len(cursor.encode("utf-8")) > MAX_CURSOR_BYTES:
                        raise SyncError("temporarily_unavailable")
                    value = parser({**value, cursor_field: ""}).to_wire()
                    value[cursor_field] = cursor
            except SyncError:
                raise SyncError("temporarily_unavailable") from None
        return Response(canonical_bytes({"schemaVersion": 1, **{k: v for k, v in value.items() if k != "schemaVersion"}}),
                        media_type="application/json", headers={"Cache-Control": "no-store"})

    def read_json(raw: bytes) -> dict:
        if len(raw) > MAX_COMPRESSED_BYTES:
            raise SyncError("payload_too_large")
        try:
            decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
            value = decoder.decompress(raw, MAX_BATCH_BYTES + 1)
            if not decoder.eof or decoder.unused_data or len(value) > MAX_BATCH_BYTES:
                raise SyncError("payload_too_large" if len(value) > MAX_BATCH_BYTES else "invalid_request")
        except SyncError:
            raise
        except (OSError, EOFError, zlib.error):
            raise SyncError("invalid_request") from None
        parsed = decode_strict(value)
        if type(parsed) is not dict:
            raise SyncError("invalid_request")
        return parsed

    def fresh_auth(claims) -> bool:
        if isinstance(claims, dict):
            value = claims.get("auth_time")
        else:
            value = getattr(claims, "auth_time", None)
        if type(value) not in (int, float):
            return False
        try:
            return math.isfinite(value) and 0 <= clock() - value <= RECENT_AUTH_SECONDS
        except OverflowError:
            return False

    @routes.post("/records")
    async def upload(request: Request, authorization: str = Header(default=""),
                     x_firebase_appcheck: str = Header(default=""),
                     x_sync_device_id: str = Header(default="")):
        try:
            claims = identity(authorization, x_firebase_appcheck, x_sync_device_id)
            raw = await bounded_body(request)
            body = read_json(raw)
            if set(body) != {"schemaVersion", "idempotencyKey", "records"}:
                raise SyncError("invalid_request")
            if type(body["schemaVersion"]) is not int or body["schemaVersion"] != 1:
                raise SyncError("invalid_request")
            bounded_id(body["idempotencyKey"])
            try:
                if len(canonical_bytes(body)) > MAX_BATCH_BYTES:
                    raise SyncError("payload_too_large")
            except (TypeError, ValueError):
                raise SyncError("invalid_request") from None
            records_wire = body["records"]
            if type(records_wire) is not list or len(records_wire) > MAX_RECORDS:
                raise SyncError("payload_too_large" if type(records_wire) is list else "invalid_request")
            admit_wire = getattr(repository, "admit_wire_batch", None)
            if admit_wire is not None:
                return run(claims, lambda uid: response(admit_wire(
                    uid, x_sync_device_id, body["idempotencyKey"], records_wire), parse_batch_result))
            # Compatibility for injected repositories implementing only the
            # original, validated-DTO contract.
            records = []
            for item in records_wire:
                try:
                    if len(canonical_bytes(item)) > MAX_RECORD_BYTES:
                        raise SyncError("payload_too_large")
                except (TypeError, ValueError):
                    raise SyncError("invalid_record") from None
                record = parse_upload(item)
                records.append(record)
            return run(claims, lambda uid: response(repository.admit_batch(
                uid, x_sync_device_id, body["idempotencyKey"], records), parse_batch_result))
        except SyncError as error:
            return failure(error, 500 if error.code == "temporarily_unavailable" else None)
        except Exception:
            return failure(SyncError("temporarily_unavailable"), 500)

    @routes.get("/changes")
    def changes(cursor: str = Query(default=""), limit: str = Query(default="100"),
                 authorization: str = Header(default=""),
                 x_firebase_appcheck: str = Header(default=""),
                 x_sync_device_id: str = Header(default="")):
        try:
            claims = identity(authorization, x_firebase_appcheck, x_sync_device_id)
            parsed_limit = page_bounds(cursor, limit)
            return run(claims, lambda uid: response(repository.changes(
                uid, x_sync_device_id, cursor, limit=parsed_limit, max_bytes=MAX_RECORD_BYTES), parse_change_page))
        except SyncError as error:
            return failure(error)

    @routes.get("/state")
    def state(cursor: str = Query(default=""), limit: str = Query(default="100"),
              authorization: str = Header(default=""),
              x_firebase_appcheck: str = Header(default=""),
              x_sync_device_id: str = Header(default="")):
        try:
            claims = identity(authorization, x_firebase_appcheck, x_sync_device_id)
            parsed_limit = page_bounds(cursor, limit)
            return run(claims, lambda uid: response(bootstrap(
                uid, x_sync_device_id, cursor, parsed_limit), parse_state_page))
        except SyncError as error:
            return failure(error)

    @routes.post("/devices")
    async def enroll(request: Request, authorization: str = Header(default=""),
                     x_firebase_appcheck: str = Header(default=""),
                     x_sync_device_id: str = Header(default="")):
        try:
            claims = identity(authorization, x_firebase_appcheck, x_sync_device_id, enrollment=True)
            body = decode_strict(await bounded_body(request))
            if type(body) is not dict:
                raise SyncError("invalid_request")
            if set(body) != {"consent", "deviceName", "idempotencyKey"} or body["consent"] is not True:
                raise SyncError("invalid_request")
            bounded_name(body["deviceName"])
            bounded_id(body["idempotencyKey"])
            return run(claims, lambda uid: response(repository.enroll(
                uid, body["consent"], body["deviceName"], body["idempotencyKey"]),
                parse_device_enrollment))
        except (SyncError, ValueError, TypeError) as error:
            return failure(error if isinstance(error, SyncError) else SyncError("invalid_request"))

    @routes.delete("/devices/{device_id}")
    def revoke(device_id: str, authorization: str = Header(default=""),
               x_firebase_appcheck: str = Header(default=""),
               x_sync_idempotency_key: str = Header(default=""),
               x_sync_device_id: str = Header(default="")):
        try:
            claims = identity(authorization, x_firebase_appcheck, x_sync_device_id)
            fresh_auth_value = fresh_auth(claims)
            bounded_id(device_id)
            bounded_id(x_sync_idempotency_key)
            return run(claims, lambda uid: response(repository.revoke(
                uid, x_sync_device_id, device_id, x_sync_idempotency_key, fresh_auth_value)))
        except SyncError as error:
            return failure(error)

    return routes
