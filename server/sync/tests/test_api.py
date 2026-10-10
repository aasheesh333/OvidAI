import gzip
import json
from contextlib import contextmanager

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from server.sync.dto import UploadRecord
from server.sync.errors import SyncError
from server.sync.api import router


RECORD = {
    "schemaVersion": 1,
    "recordId": "message-1",
    "sourceDeviceId": "device-a",
    "recordType": "transcript",
    "conversationId": "conversation-1",
    "createdAt": "2026-01-01T00:00:00Z",
    "revision": 1,
    "payload": {
        "messageId": "message-1",
        "parentMessageId": None,
        "kind": "user",
        "text": "private text",
        "providerMetadataRecordId": None,
        "requestPurpose": None,
        "displayTitle": None,
    },
}


class Repository:
    def __init__(self):
        self.calls = []

    def admit_batch(self, uid, device_id, idempotency_key, records):
        self.calls.append(("admit_batch", uid, device_id, idempotency_key, records))
        return {"schemaVersion": 1, "results": []}

    def changes(self, uid, device_id, cursor, limit=100, max_bytes=262144):
        self.calls.append(("changes", uid, device_id, cursor, limit, max_bytes))
        return {"schemaVersion": 1, "records": [], "nextCursor": "cursor-2", "hasMore": False}

    def bootstrap(self, uid, device_id, cursor=None):
        self.calls.append(("bootstrap", uid, device_id, cursor))
        return {"schemaVersion": 1, "accountId": uid, "records": [],
                "currentCursor": "cursor-1", "enrollmentStatus": "active",
                "retentionMarkers": []}

    def enroll(self, uid, consent, device_name, idempotency_key):
        self.calls.append(("enroll", uid, consent, device_name, idempotency_key))
        return {"schemaVersion": 1, "deviceId": "device-b", "deviceName": device_name,
                "createdAt": "2026-10-08T12:00:00Z", "status": "active"}

    def revoke(self, uid, requester_device_id, target_device_id, idempotency_key=None,
               fresh_auth=False):
        self.calls.append(("revoke", uid, requester_device_id, target_device_id,
                           idempotency_key, fresh_auth))
        return None


class Verifier:
    def __call__(self, token, app_check):
        if token == "bad":
            raise SyncError("unauthenticated")
        return {"uid": "account-1", "device_id": "device-a", "fresh_auth": token == "fresh"}


@contextmanager
def admission(claims):
    yield claims


@pytest.fixture
def client():
    app = FastAPI()
    repository = Repository()
    app.include_router(router(repository, Verifier(), admission))
    return TestClient(app), repository


def headers(token="token"):
    return {"Authorization": f"Bearer {token}", "X-Firebase-AppCheck": "app-check",
            "X-Sync-Device-Id": "device-a"}


def test_upload_parses_gzip_and_passes_only_verified_identity(client):
    http, repository = client
    body = gzip.compress(json.dumps({
        "schemaVersion": 1,
        "idempotencyKey": "batch-1",
        "records": [RECORD],
    }).encode())

    response = http.post("/sync/v1/records", content=body,
                         headers={**headers(), "Content-Encoding": "gzip"})

    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert response.json() == {"schemaVersion": 1, "results": []}
    call = repository.calls[-1]
    assert call[1:4] == ("account-1", "device-a", "batch-1")
    assert isinstance(call[4][0], UploadRecord)
    assert call[4][0].payload.text == "private text"


def test_upload_rejects_non_gzip_and_never_echoes_body(client):
    http, _ = client
    sentinel = "secret-request-body-sentinel"
    response = http.post("/sync/v1/records", content=sentinel.encode(), headers=headers())

    assert response.status_code == 400
    assert response.headers["cache-control"] == "no-store"
    assert response.json()["code"] == "invalid_request"
    assert sentinel not in response.text


def test_upload_rejects_oversized_record_before_repository(client):
    http, repository = client
    oversized = {**RECORD, "payload": {**RECORD["payload"], "text": "x" * 262145}}
    body = gzip.compress(json.dumps({"schemaVersion": 1, "idempotencyKey": "b",
                                     "records": [oversized]}).encode())
    response = http.post("/sync/v1/records", content=body,
                         headers={**headers(), "Content-Encoding": "gzip"})
    assert response.status_code == 413
    assert repository.calls == []


def test_changes_and_state_are_bounded_and_no_store(client):
    http, repository = client
    changes = http.get("/sync/v1/changes", params={"cursor": "cursor-1", "limit": "100"},
                       headers=headers())
    state = http.get("/sync/v1/state", headers=headers())

    assert changes.status_code == state.status_code == 200
    assert changes.headers["cache-control"] == state.headers["cache-control"] == "no-store"
    assert changes.json()["schemaVersion"] == state.json()["schemaVersion"] == 1
    assert repository.calls[0][4:] == (100, 262144)


def test_enroll_and_revoke_use_verified_device_and_fixed_error(client):
    http, repository = client
    enrolled = http.post("/sync/v1/devices", json={
        "consent": True, "deviceName": "tablet", "idempotencyKey": "enroll-1"
    }, headers=headers())
    revoked = http.delete("/sync/v1/devices/device-b",
                          headers={**headers("fresh"), "X-Sync-Idempotency-Key": "revoke-1"})

    assert enrolled.status_code == revoked.status_code == 200
    assert enrolled.json() == {"schemaVersion": 1, "deviceId": "device-b",
                               "deviceName": "tablet", "createdAt": "2026-10-08T12:00:00Z",
                               "status": "active"}
    assert repository.calls[-1] == ("revoke", "account-1", "device-a", "device-b",
                                    "revoke-1", True)


def test_missing_or_bad_auth_is_sanitized_for_every_route(client):
    http, _ = client
    response = http.get("/sync/v1/state", headers=headers("bad"))
    missing = http.get("/sync/v1/state")
    for result in (response, missing):
        assert result.status_code == 401
        assert set(result.json()) == {"schemaVersion", "code", "message", "retryAfterSeconds"}
        assert result.headers["cache-control"] == "no-store"


def test_unknown_request_fields_and_supplied_account_are_rejected(client):
    http, repository = client
    response = http.post("/sync/v1/devices", json={
        "consent": True, "deviceName": "x", "idempotencyKey": "k",
        "accountId": "attacker-account",
    }, headers=headers())
    assert response.status_code == 400
    assert repository.calls == []


def test_unexpected_repository_failure_is_fixed_temporary_error(client):
    http, repository = client
    repository.changes = lambda *args, **kwargs: (_ for _ in ()).throw(
        RuntimeError("private sentinel"))
    response = http.get("/sync/v1/changes", headers=headers())
    assert response.status_code == 500
    assert response.headers["cache-control"] == "no-store"
    assert response.json() == {
        "schemaVersion": 1,
        "code": "temporarily_unavailable",
        "message": "The sync service is temporarily unavailable.",
        "retryAfterSeconds": None,
    }


@pytest.mark.parametrize("method,path,body,name", [
    ("get", "/sync/v1/state", None, "bootstrap"),
    ("get", "/sync/v1/changes", None, "changes"),
    ("post", "/sync/v1/devices", {"consent": True, "deviceName": "phone",
                                  "idempotencyKey": "enroll"}, "enroll"),
    ("delete", "/sync/v1/devices/device-b", None, "revoke"),
])
def test_all_repository_failures_are_fixed_safe_500(client, method, path, body, name):
    http, repository = client
    setattr(repository, name, lambda *args, **kwargs: (_ for _ in ()).throw(OSError("secret")))
    kwargs = {"headers": {**headers(), "X-Sync-Idempotency-Key": "revoke"}}
    if body is not None:
        kwargs["json"] = body
    response = getattr(http, method)(path, **kwargs)
    assert response.status_code == 500
    assert response.headers["cache-control"] == "no-store"
    assert response.json() == SyncError("temporarily_unavailable").to_wire()


def test_malformed_repository_state_is_not_forwarded(client):
    http, repository = client
    repository.bootstrap = lambda *args: {"schemaVersion": 1, "secret": "private"}
    response = http.get("/sync/v1/state", headers=headers())
    assert response.status_code == 500
    assert response.json() == SyncError("temporarily_unavailable").to_wire()


def test_empty_memory_state_carries_verified_account():
    from server.sync.memory import InMemorySyncRepository
    repository = InMemorySyncRepository()
    repository.register_device("account-1", "device-a")
    app = FastAPI()
    app.include_router(router(repository, Verifier(), admission))
    response = TestClient(app).get("/sync/v1/state", headers=headers())
    assert response.status_code == 200
    assert response.json()["accountId"] == "account-1"
    assert response.json()["records"] == []
