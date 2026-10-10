import json
from contextlib import contextmanager

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from server.collaboration.api import router
from server.collaboration.events import EventRejected
from server.collaboration.repository import CollabError


def event(event_id="e1", text="private text"):
    return {"schemaVersion": 1, "eventId": event_id, "kind": "message",
            "payload": {"text": text}}


class Repository:
    def __init__(self):
        self.calls = []
        self.session = {
            "sessionToken": "s" * 43,
            "session": {"schemaVersion": 1, "sessionId": "sid",
                         "ownerParticipantId": "pid-owner", "lifecycle": "active"},
            "member": {"participantId": "pid-owner", "role": "owner", "status": "active"},
            "cursor": "cursor-0",
        }

    def create_session(self, uid, request_id):
        self.calls.append(("create_session", uid, request_id))
        return self.session

    def get_state(self, uid, token):
        self.calls.append(("get_state", uid, token))
        return {"session": self.session["session"], "members": [self.session["member"]],
                "member": self.session["member"], "cursor": "cursor-0"}

    def create_invite(self, uid, token, max_uses=1, ttl_seconds=86400, idempotency_key=None):
        self.calls.append(("create_invite", uid, token, max_uses, ttl_seconds, idempotency_key))
        return {"inviteId": "invite-1", "inviteCode": "c" * 43,
                "expiresAt": "2026-10-10T12:00:00.000Z", "maxUses": max_uses}

    def join(self, uid, token, invite_code):
        self.calls.append(("join", uid, token, invite_code))
        return {"participantId": "pid-alice", "role": "participant", "status": "active"}

    def revoke_member(self, uid, token, participant_id):
        self.calls.append(("revoke_member", uid, token, participant_id))
        return None

    def append(self, uid, token, submitted):
        self.calls.append(("append", uid, token, submitted))
        return {"schemaVersion": 1, "eventId": submitted["eventId"], "sessionId": "sid",
                "eventSequence": 1, "senderParticipantId": "pid-owner",
                "kind": submitted["kind"], "createdAt": "2026-01-01T00:00:00.000Z",
                "payload": submitted["payload"]}

    def replay(self, uid, token, cursor=None, limit=100, max_bytes=256 * 1024):
        self.calls.append(("replay", uid, token, cursor, limit, max_bytes))
        return {"events": [], "cursor": cursor or "cursor-0", "hasMore": False}

    def close(self, uid, token):
        self.calls.append(("close", uid, token))
        return {**self.session["session"], "lifecycle": "closed"}


class Verifier:
    def __call__(self, token, app_check):
        if token == "bad":
            raise CollabError("invalid_identity")
        return {"uid": "verified-account"}


@contextmanager
def admission(claims):
    yield claims


@pytest.fixture
def client():
    app = FastAPI()
    repository = Repository()
    app.include_router(router(repository, Verifier(), admission), prefix="/chat")
    return TestClient(app), repository


def headers(token="good"):
    return {"Authorization": f"Bearer {token}", "X-Firebase-AppCheck": "app-check"}


def test_create_uses_verified_uid_and_no_store(client):
    http, repository = client
    response = http.post("/chat", json={"schemaVersion": 1, "requestId": "create-1",
                                         "idempotencyKey": "create-1"}, headers=headers())

    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert repository.calls == [("create_session", "verified-account", "create-1")]
    assert response.json()["sessionToken"] == "s" * 43


def test_state_membership_and_close_use_verified_uid(client):
    http, repository = client
    token = "t" * 43

    state = http.get(f"/chat/{token}", headers=headers())
    closed = http.post(f"/chat/{token}/close", json={"schemaVersion": 1,
                                                      "idempotencyKey": "close-1"}, headers=headers())

    assert state.status_code == closed.status_code == 200
    assert state.headers["cache-control"] == closed.headers["cache-control"] == "no-store"
    assert repository.calls == [("get_state", "verified-account", token),
                                ("close", "verified-account", token)]
    assert state.json()["member"] == repository.session["member"]


def test_members_route_supports_owner_invites_and_authenticated_join(client):
    http, repository = client
    token = "t" * 43

    invite = http.post(f"/chat/{token}/members",
                       json={"schemaVersion": 1, "maxUses": 2, "ttlSeconds": 60,
                             "idempotencyKey": "invite-1"}, headers=headers())
    join = http.post(f"/chat/{token}/members",
                     json={"schemaVersion": 1, "invitationCode": "invite-secret",
                           "idempotencyKey": "join-1"}, headers=headers())

    assert invite.status_code == join.status_code == 200
    assert repository.calls == [
        ("create_invite", "verified-account", token, 2, 60, "invite-1"),
        ("join", "verified-account", token, "invite-secret"),
        ("get_state", "verified-account", token),
    ]
    assert invite.headers["cache-control"] == join.headers["cache-control"] == "no-store"


def test_append_and_replay_are_bounded_and_server_fields_are_not_forwarded(client):
    http, repository = client
    token = "t" * 43
    body = {"schemaVersion": 1, "idempotencyKey": "append-1", "events": [event()]}

    appended = http.post(f"/chat/{token}/events", json=body, headers=headers())
    replayed = http.get(f"/chat/{token}/events",
                        params={"cursor": "cursor-0", "limit": "1"}, headers=headers())

    assert appended.status_code == replayed.status_code == 200
    assert repository.calls[0] == ("append", "verified-account", token, event())
    assert repository.calls[1] == ("replay", "verified-account", token,
                                   "cursor-0", 1, 256 * 1024)
    assert appended.headers["cache-control"] == replayed.headers["cache-control"] == "no-store"


def test_revoke_uses_path_participant_and_verified_uid(client):
    http, repository = client
    token = "t" * 43
    response = http.delete(f"/chat/{token}/members/pid-alice", headers=headers())

    assert response.status_code == 200
    assert repository.calls == [("revoke_member", "verified-account", token, "pid-alice")]


def test_missing_or_bad_auth_is_fixed_and_no_store(client):
    http, _ = client
    responses = [http.get("/chat/" + "t" * 43),
                 http.get("/chat/" + "t" * 43, headers=headers("bad"))]

    for response in responses:
        assert response.status_code == 401
        assert response.headers["cache-control"] == "no-store"
        assert response.json() == {"schemaVersion": 1, "code": "unauthenticated", "message": "Authentication required"}


def test_invalid_body_and_oversized_body_do_not_reach_repository(client):
    http, repository = client
    invalid = http.post("/chat", json={"schemaVersion": 1, "requestId": "x",
                                        "idempotencyKey": "x", "uid": "attacker"}, headers=headers())
    oversized = http.post("/chat", content=json.dumps({"requestId": "x", "data": "x" * (1024 * 1024)}),
                          headers={**headers(), "Content-Type": "application/json"})

    assert invalid.status_code == 400
    assert oversized.status_code == 413
    assert repository.calls == []
    assert "attacker" not in invalid.text


def test_repository_and_event_errors_are_sanitized(client):
    http, repository = client
    repository.get_state = lambda uid, token: (_ for _ in ()).throw(CollabError("not_member"))
    response = http.get("/chat/" + "t" * 43, headers=headers())
    assert response.status_code == 403
    assert response.json() == {"schemaVersion": 1, "code": "not_member", "message": "Not a session member"}

    repository.get_state = lambda uid, token: (_ for _ in ()).throw(RuntimeError("secret payload"))
    response = http.get("/chat/" + "t" * 43, headers=headers())
    assert response.status_code == 500
    assert "secret payload" not in response.text


def test_success_envelopes_are_versioned_and_use_wire_shapes(client):
    http, repository = client
    token = "t" * 43
    join = http.post(f"/chat/{token}/members", json={
        "schemaVersion": 1, "invitationCode": "invite-secret", "idempotencyKey": "join-1",
    }, headers=headers())
    replay = http.get(f"/chat/{token}/events", headers=headers())
    assert join.json() == {"schemaVersion": 1, "member": {
        "participantId": "pid-alice", "role": "participant", "status": "active",
    }, "cursor": "cursor-0"}
    assert replay.json() == {"schemaVersion": 1, "events": [],
                             "nextCursor": "cursor-0", "hasMore": False}


def test_admission_uid_is_used_without_claims_lookup():
    app = FastAPI()
    repository = Repository()

    @contextmanager
    def uid_admission(_claims):
        yield "admitted-account"

    app.include_router(router(repository, Verifier(), uid_admission), prefix="/chat")
    response = TestClient(app).get("/chat/" + "t" * 43, headers=headers())
    assert response.status_code == 200
    assert repository.calls == [("get_state", "admitted-account", "t" * 43)]


def test_lifecycle_failures_use_sanitized_collaboration_envelope():
    app = FastAPI()

    @contextmanager
    def denied(_claims):
        raise CollabError("account_deleted")
        yield

    app.include_router(router(Repository(), Verifier(), denied), prefix="/chat")
    response = TestClient(app).get("/chat/" + "t" * 43, headers=headers())
    assert response.status_code == 403
    assert response.json() == {"schemaVersion": 1, "code": "account_deleted",
                               "message": "Account is unavailable"}


def test_missing_app_check_is_rejected_before_account_operation(client):
    http, repository = client
    response = http.get("/chat/" + "t" * 43,
                        headers={"Authorization": "Bearer good"})
    assert response.status_code == 401
    assert repository.calls == []


def test_unexpected_repository_failure_is_fixed_server_error(client):
    http, repository = client
    repository.get_state = lambda uid, token: (_ for _ in ()).throw(
        RuntimeError("private sentinel"))
    response = http.get("/chat/" + "t" * 43, headers=headers())
    assert response.status_code == 500
    assert response.headers["cache-control"] == "no-store"
    assert response.json() == {"schemaVersion": 1, "code": "temporarily_unavailable",
                               "message": "The collaboration service is temporarily unavailable"}
