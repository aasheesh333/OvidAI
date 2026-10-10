from contextlib import contextmanager

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from server.account.domain import AccountError
from server.sync.runtime import mount_sync


class Repository:
    def bootstrap(self, uid, device_id, cursor=None):
        return {"schemaVersion": 1, "accountId": uid, "records": [],
                "currentCursor": "cursor-1", "enrollmentStatus": "active",
                "retentionMarkers": []}


class Admin:
    def __init__(self):
        self.calls = []

    def verify(self, token, app_check):
        self.calls.append((token, app_check))
        return {"uid": "account-1", "device_id": "device-1"}


class Lifecycle:
    def __init__(self):
        self.claims = []
        self.admitted = []

    @contextmanager
    def access(self, claims):
        self.claims.append(claims)
        self.admitted.append("account-1")
        yield "account-1"


def test_mount_sync_composes_routes_once_at_default_prefix():
    app = FastAPI()
    admin = Admin()
    lifecycle = Lifecycle()
    mount_sync(app, Repository(), lifecycle, admin)

    response = TestClient(app).get(
        "/sync/v1/state",
        headers={"Authorization": "Bearer token", "X-Firebase-AppCheck": "app-check", "X-Sync-Device-Id": "device-1"},
    )

    assert response.status_code == 200
    assert response.json()["schemaVersion"] == 1
    assert admin.calls == [("token", "app-check")]
    assert lifecycle.claims == [{"uid": "account-1", "device_id": "device-1"}]


def test_mount_sync_uses_custom_prefix_without_duplicate_default_prefix():
    app = FastAPI()
    mount_sync(app, Repository(), Lifecycle(), Admin(), prefix="/private-sync/")

    client = TestClient(app)
    response = client.get(
        "/private-sync/state",
        headers={"Authorization": "Bearer token", "X-Firebase-AppCheck": "app-check", "X-Sync-Device-Id": "device-1"},
    )

    assert response.status_code == 200
    assert client.get("/private-sync/sync/v1/state").status_code == 404


def test_mount_sync_translates_account_errors_to_http_errors():
    class FailingLifecycle:
        @contextmanager
        def access(self, claims):
            raise AccountError("account_unavailable", 403)
            yield

    app = FastAPI()
    mount_sync(app, Repository(), FailingLifecycle(), Admin())

    response = TestClient(app).get(
        "/sync/v1/state",
        headers={"Authorization": "Bearer token", "X-Firebase-AppCheck": "app-check", "X-Sync-Device-Id": "device-1"},
    )

    assert response.status_code == 403
    assert response.json()["code"] == "account_fenced"
    assert response.headers["cache-control"] == "no-store"
