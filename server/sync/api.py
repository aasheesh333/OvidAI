"""Injected, bounded FastAPI transport for private sync."""

from __future__ import annotations

import json
import zlib
from typing import Any

from fastapi import APIRouter, Header, Query, Request
from fastapi.responses import JSONResponse

from server.sync.canonical import canonical_bytes
from server.sync.dto import parse_upload
from server.sync.errors import SyncError
from server.sync.results import (parse_batch_result, parse_change_page,
                                  parse_device_enrollment, parse_state_page)

MAX_COMPRESSED_BYTES = 1024 * 1024
MAX_BATCH_BYTES = 8 * 1024 * 1024
MAX_RECORD_BYTES = 256 * 1024
MAX_RECORDS = 100
MAX_CURSOR_BYTES = 512


def router(repository, verify, admission) -> APIRouter:
    routes = APIRouter(prefix="/sync/v1", tags=["sync"])

    def failure(error: SyncError, status: int | None = None) -> JSONResponse:
        return JSONResponse(error.to_wire(), status_code=status or error.status,
                            headers={"Cache-Control": "no-store"})

    def run(claims, operation):
        try:
            with admission(claims) as admitted:
                return operation(admitted)
        except SyncError as error:
            return failure(error, 500 if error.code == "temporarily_unavailable" else None)
        except Exception:
            return failure(SyncError("temporarily_unavailable"), 500)

    def identity(authorization: str, app_check: str, device_id: str):
        if not authorization.startswith("Bearer ") or not authorization[7:]:
            raise SyncError("unauthenticated")
        try:
            claims = verify(authorization[7:], app_check)
            claimed_device = claims.get("device_id") if isinstance(claims, dict) else getattr(claims, "device_id", None)
            if type(device_id) is not str or not device_id or device_id != claimed_device:
                raise SyncError("unauthenticated")
            return claims
        except SyncError:
            raise
        except Exception:
            raise SyncError("unauthenticated") from None

    def response(value: Any, parser=None) -> JSONResponse:
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
                value = parser(value).to_wire()
            except SyncError:
                raise SyncError("temporarily_unavailable") from None
        return JSONResponse({"schemaVersion": 1, **{k: v for k, v in value.items() if k != "schemaVersion"}},
                            headers={"Cache-Control": "no-store"})

    def read_json(raw: bytes) -> dict:
        if len(raw) > MAX_COMPRESSED_BYTES:
            raise SyncError("payload_too_large")
        try:
            decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
            value = decoder.decompress(raw, MAX_BATCH_BYTES + 1)
            if len(value) <= MAX_BATCH_BYTES and not decoder.eof:
                value += decoder.flush(MAX_BATCH_BYTES + 1 - len(value))
            if not decoder.eof or decoder.unused_data or len(value) > MAX_BATCH_BYTES:
                raise SyncError("payload_too_large" if len(value) > MAX_BATCH_BYTES else "invalid_request")
        except SyncError:
            raise
        except (OSError, EOFError, zlib.error):
            raise SyncError("invalid_request") from None
        try:
            parsed = json.loads(value)
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise SyncError("invalid_request") from None
        if type(parsed) is not dict:
            raise SyncError("invalid_request")
        return parsed

    def claims_value(claims, name):
        if isinstance(claims, dict):
            value = claims.get(name)
        else:
            value = getattr(claims, name, None)
        if type(value) is not str or not value:
            raise SyncError("unauthenticated")
        return value

    @routes.post("/records")
    async def upload(request: Request, authorization: str = Header(default=""),
                     x_firebase_appcheck: str = Header(default=""),
                     x_sync_device_id: str = Header(default="")):
        try:
            claims = identity(authorization, x_firebase_appcheck, x_sync_device_id)
            raw = await request.body()
            body = read_json(raw)
            if set(body) != {"schemaVersion", "idempotencyKey", "records"}:
                raise SyncError("invalid_request")
            if body["schemaVersion"] != 1 or type(body["idempotencyKey"]) is not str:
                raise SyncError("invalid_request")
            records_wire = body["records"]
            if type(records_wire) is not list or len(records_wire) > MAX_RECORDS:
                raise SyncError("payload_too_large" if type(records_wire) is list else "invalid_request")
            records = []
            for item in records_wire:
                try:
                    if len(canonical_bytes(item)) > MAX_RECORD_BYTES:
                        raise SyncError("payload_too_large")
                except (TypeError, ValueError):
                    raise SyncError("invalid_record") from None
                record = parse_upload(item)
                records.append(record)
            uid = claims_value(claims, "uid")
            device_id = claims_value(claims, "device_id")
            return run(claims, lambda _: response(repository.admit_batch(
                uid, device_id, body["idempotencyKey"], records), parse_batch_result))
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
            try:
                parsed_limit = int(limit)
            except (TypeError, ValueError):
                raise SyncError("invalid_request") from None
            if type(limit) is not str or str(parsed_limit) != limit or not 1 <= parsed_limit <= 100 or len(cursor.encode()) > MAX_CURSOR_BYTES:
                raise SyncError("invalid_request")
            uid, device = claims_value(claims, "uid"), claims_value(claims, "device_id")
            return run(claims, lambda _: response(repository.changes(
                uid, device, cursor, limit=parsed_limit, max_bytes=MAX_RECORD_BYTES), parse_change_page))
        except SyncError as error:
            return failure(error)

    @routes.get("/state")
    def state(authorization: str = Header(default=""),
              x_firebase_appcheck: str = Header(default=""),
              x_sync_device_id: str = Header(default="")):
        try:
            claims = identity(authorization, x_firebase_appcheck, x_sync_device_id)
            uid, device = claims_value(claims, "uid"), claims_value(claims, "device_id")
            return run(claims, lambda _: response(repository.bootstrap(uid, device), parse_state_page))
        except SyncError as error:
            return failure(error)

    @routes.post("/devices")
    async def enroll(request: Request, authorization: str = Header(default=""),
                     x_firebase_appcheck: str = Header(default=""),
                     x_sync_device_id: str = Header(default="")):
        try:
            claims = identity(authorization, x_firebase_appcheck, x_sync_device_id)
            try:
                body = await request.json()
            except (ValueError, UnicodeDecodeError):
                raise SyncError("invalid_request") from None
            if type(body) is not dict:
                raise SyncError("invalid_request")
            if set(body) != {"consent", "deviceName", "idempotencyKey"} or body["consent"] is not True:
                raise SyncError("invalid_request")
            uid = claims_value(claims, "uid")
            return run(claims, lambda _: response(repository.enroll(
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
            uid = claims_value(claims, "uid")
            requester = claims_value(claims, "device_id")
            fresh_auth = claims.get("fresh_auth", False) if isinstance(claims, dict) else getattr(claims, "fresh_auth", False)
            if not x_sync_idempotency_key:
                raise SyncError("invalid_request")
            return run(claims, lambda _: response(repository.revoke(
                uid, requester, device_id, x_sync_idempotency_key, fresh_auth)))
        except SyncError as error:
            return failure(error)

    return routes
