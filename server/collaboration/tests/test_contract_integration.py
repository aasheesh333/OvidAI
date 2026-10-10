"""HTTP contracts exercised against restartable SQLite authority."""
import base64
import gzip
import json
import threading
from contextlib import contextmanager

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from server.collaboration.api import router
from server.collaboration.repository import CollabRepository, CollabError
from server.collaboration.tests.test_repository import Clock, message


@contextmanager
def admission(claims):
    yield claims


@pytest.fixture
def service(tmp_path):
    clock = Clock()
    path = tmp_path / 'collab.sqlite'
    repo = CollabRepository(path, clock=clock)
    def connect():
        app = FastAPI()
        app.include_router(router(CollabRepository(path, clock=clock),
                                  lambda uid, check: {'uid': uid}, admission), prefix='/chat')
        return TestClient(app)
    return repo, clock, connect


def headers(uid='owner'):
    return {'Authorization': f'Bearer {uid}', 'X-Firebase-AppCheck': 'check'}


def post(http, path, key, **data):
    return http.post(path, headers=headers(), json={
        'schemaVersion': 1, 'idempotencyKey': key, **data})


def test_http_batch_conflict_rolls_back_events_sequence_and_request(service):
    repo, clock, connect = service
    http = connect()
    token = post(http, '/chat', 'create', requestId='create').json()['sessionToken']
    route = f'/chat/{token}/events'
    first = post(http, route, 'first', events=[message('existing')])
    assert first.status_code == 200
    rejected = post(http, route, 'batch', events=[message('new'), message('existing', 'conflict')])
    assert rejected.status_code == 409
    assert [e['eventId'] for e in repo.replay('owner', token)['events']] == ['existing']
    accepted = post(http, route, 'batch', events=[message('new'), message('last')])
    assert [e['eventSequence'] for e in accepted.json()['events']] == [2, 3]
    clock.now += 2
    assert post(connect(), route, 'batch', events=[message('new'), message('last')]).json() == accepted.json()
    assert post(http, route, 'batch', events=[message('different')]).status_code == 409
    cursor = accepted.json()['nextCursor']
    assert http.get(route, headers=headers(), params={'cursor': cursor}).status_code == 200
    legacy = base64.urlsafe_b64encode(
        f"v1:{accepted.json()['events'][0]['sessionId']}:0".encode()).decode().rstrip('=')
    assert http.get(route, headers=headers(), params={'cursor': legacy}).status_code == 410


def test_http_join_invite_retry_leave_rejoin_and_cursor_binding(service):
    repo, clock, connect = service
    http = connect()
    token = repo.create_session('owner', 'create')['sessionToken']
    route = f'/chat/{token}/members'
    invite = post(http, route, 'invite', maxUses=3, ttlSeconds=60)
    assert invite.status_code == 200
    assert post(connect(), route, 'invite', maxUses=3, ttlSeconds=60).json() == invite.json()
    assert post(http, route, 'invite', maxUses=2).status_code == 409
    body = {'schemaVersion': 1, 'idempotencyKey': 'join', 'invitationCode': invite.json()['inviteCode']}
    joined = http.post(route, headers=headers('guest'), json=body)
    assert joined.status_code == 200
    assert connect().post(route, headers=headers('guest'), json=body).json() == joined.json()
    assert http.post(route, headers=headers('guest'), json={**body, 'invitationCode': 'different'}).status_code == 409
    cursor = joined.json()['cursor']
    events = f'/chat/{token}/events'
    assert http.get(events, headers=headers(), params={'cursor': cursor}).status_code == 410
    left = http.delete(route + '/me', headers=headers('guest'))
    assert left.json()['member']['status'] == 'left'
    assert http.get(events, headers=headers('guest')).status_code == 403
    # A retry of the old join cannot undo a leave.
    assert http.post(route, headers=headers('guest'), json=body).status_code == 409
    again = http.post(route, headers=headers('guest'), json={**body, 'idempotencyKey': 'rejoin'})
    assert again.status_code == 200
    assert http.get(events, headers=headers('guest'), params={'cursor': cursor}).status_code == 410
    revoked = http.delete(route + '/' + joined.json()['member']['participantId'], headers=headers())
    assert revoked.json()['member']['status'] == 'revoked'
    assert http.get(events, headers=headers('guest')).status_code == 403
    owner_cursor = repo.get_state('owner', token)['cursor']
    clock.now += 86401
    assert http.get(events, headers=headers(), params={'cursor': owner_cursor}).status_code == 410


def test_durable_append_replay_rates_and_window_recovery(service):
    repo, clock, connect = service
    token = repo.create_session('owner', 'create')['sessionToken']
    http = connect()
    route = f'/chat/{token}/events'
    for i in range(60):
        assert post(http, route, f'r{i}', events=[message(f'e{i}')]).status_code == 200
    limited = post(connect(), route, 'limited', events=[message('limited')])
    assert limited.status_code == 429
    assert limited.json()['code'] == 'rate_limited'
    for _ in range(120):
        assert http.get(route, headers=headers()).status_code == 200
    assert connect().get(route, headers=headers()).status_code == 429
    clock.now += 60
    assert post(connect(), route, 'limited', events=[message('limited')]).status_code == 200
    assert http.get(route, headers=headers()).status_code == 200


def test_quota_atomicity_lifecycle_admission_and_cleanup(service, monkeypatch):
    from server.collaboration import repository as module
    repo, clock, connect = service
    token = repo.create_session('owner', 'create')['sessionToken']
    invite = repo.create_invite('owner', token, idempotency_key='invite')
    repo.join('guest', token, invite['inviteCode'], idempotency_key='join')
    monkeypatch.setattr(module, 'MAX_ROLLING_EVENTS', 3)
    repo.append_batch('owner', token, [message('a'), message('b')], idempotency_key='a')
    with pytest.raises(CollabError, match='quota_exhausted'):
        repo.append_batch('owner', token, [message('c'), message('d')], idempotency_key='b')
    clock.now += 86400
    repo.append_batch('owner', token, [message('c')], idempotency_key='b')
    monkeypatch.setattr(module, 'MAX_RETAINED_BYTES', 1)
    with pytest.raises(CollabError, match='quota_exhausted'):
        repo.append_batch('owner', token, [message('d')], idempotency_key='c')
    repo.leave('guest', token)
    repo.close('owner', token)
    repo.delete_account('owner')
    with repo._connection() as db:
        tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'collab_%'")]
        for table in tables:
            columns = {r[1] for r in db.execute(f'PRAGMA table_info({table})')}
            if 'session_id' in columns:
                assert db.execute(f'SELECT count(*) FROM {table}').fetchone()[0] == 0, table


def test_cursor_cannot_be_forged_or_reused_after_leave(service):
    repo, clock, _ = service
    token = repo.create_session('owner', 'create')['sessionToken']
    code = repo.create_invite('owner', token, max_uses=3)['inviteCode']
    repo.join('guest', token, code)
    cursor = repo.replay('guest', token)['cursor']
    repo.leave('guest', token)
    repo.join('guest', token, code)
    with pytest.raises(CollabError, match='cursor_reset'):
        repo.replay('guest', token, cursor)
    with pytest.raises(CollabError, match='cursor_reset'):
        repo.replay('guest', token, cursor[:-4] + 'AAAA')


def test_compressed_body_and_decompressed_limits_are_atomic(service):
    repo, clock, connect = service
    token = repo.create_session('owner', 'create')['sessionToken']
    http = connect()
    route = f'/chat/{token}/events'
    def compressed(events):
        return http.post(route, headers={**headers(), 'Content-Encoding': 'gzip',
                                          'Content-Type': 'application/json'}, content=gzip.compress(json.dumps({
            'schemaVersion': 1, 'idempotencyKey': 'compressed', 'events': events}).encode()))
    accepted = compressed([message(f'e{i}', 'x' * (200 * 1024)) for i in range(8)])
    assert accepted.status_code == 200
    assert len(accepted.json()['events']) == 8
    rejected = compressed([message(f'large{i}', 'x' * (200 * 1024)) for i in range(45)])
    assert rejected.status_code == 413
    assert len(repo.replay('owner', token)['events']) == 1
    with repo._connection() as db:
        assert db.execute('SELECT count(*) FROM collab_events').fetchone()[0] == 8


def test_concurrent_same_batch_returns_one_result_and_quota_charged_once(service):
    repo, clock, connect = service
    token = repo.create_session('owner', 'create')['sessionToken']
    clients = [connect(), connect()]
    barrier = threading.Barrier(2)
    results = []
    def run(http):
        barrier.wait()
        results.append(post(http, f'/chat/{token}/events', 'batch', events=[message('a'), message('b')]))
    threads = [threading.Thread(target=run, args=(http,)) for http in clients]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=10)
        assert not thread.is_alive()
    assert [r.status_code for r in results] == [200, 200]
    assert results[0].json() == results[1].json()
    with repo._connection() as db:
        assert db.execute('SELECT count(*) FROM collab_events').fetchone()[0] == 2
        assert db.execute('SELECT count(*) FROM collab_requests').fetchone()[0] == 1


def test_idempotency_budget_rolls_back_batch_and_invite_allocation(service, monkeypatch):
    from server.collaboration import repository as module
    repo, clock, _ = service
    token = repo.create_session('owner', 'create')['sessionToken']
    monkeypatch.setattr(module, 'MAX_REQUEST_RESULT_BYTES', 1)
    with pytest.raises(CollabError, match='quota_exhausted'):
        repo.append_batch('owner', token, [message('a')], idempotency_key='batch')
    with pytest.raises(CollabError, match='quota_exhausted'):
        repo.create_invite('owner', token, idempotency_key='invite')
    with repo._connection() as db:
        for table in ('collab_requests', 'collab_events', 'collab_invites', 'collab_invite_requests'):
            assert db.execute(f'SELECT count(*) FROM {table}').fetchone()[0] == 0
        assert db.execute('SELECT next_sequence FROM collab_sessions').fetchone()[0] == 1


def test_authorized_failed_requests_count_toward_durable_rate(service):
    repo, clock, connect = service
    token = repo.create_session('owner', 'create')['sessionToken']
    http = connect()
    route = f'/chat/{token}/events'
    assert post(http, route, 'a', events=[message('a')]).status_code == 200
    for i in range(59):
        assert post(http, route, f'conflict{i}', events=[message('a', 'conflict')]).status_code == 409
    assert post(connect(), route, 'b', events=[message('b')]).status_code == 429
    for _ in range(120):
        assert http.get(route, headers=headers(), params={'cursor': 'bad'}).status_code == 410
    assert connect().get(route, headers=headers()).status_code == 429


def test_leave_retry_is_idempotent_and_nonowner_deletion_cleans_request_data(service):
    repo, clock, connect = service
    token = repo.create_session('owner', 'create')['sessionToken']
    invite = repo.create_invite('owner', token)
    repo.join('guest', token, invite['inviteCode'], idempotency_key='join')
    repo.append_batch('guest', token, [message('a')], idempotency_key='batch')
    http = connect()
    route = f'/chat/{token}/members/me'
    left = http.delete(route, headers=headers('guest'))
    assert http.delete(route, headers=headers('guest')).json() == left.json()
    repo.delete_account('guest')
    with repo._connection() as db:
        assert db.execute("SELECT count(*) FROM collab_requests WHERE uid='guest'").fetchone()[0] == 0
    assert repo.get_state('owner', token)['member']['role'] == 'owner'


def test_late_append_admission_cannot_cross_membership_rejoin(service):
    repo, clock, _ = service
    token = repo.create_session('owner', 'create')['sessionToken']
    code = repo.create_invite('owner', token, max_uses=2)['inviteCode']
    repo.join('guest', token, code)

    class DelayedRepository(CollabRepository):
        def _admit_rate(self, *args):
            admitted = super()._admit_rate(*args)
            repo.leave('guest', token)
            repo.join('guest', token, code)
            return admitted

    delayed = DelayedRepository(repo.path, clock=clock)
    with pytest.raises(CollabError, match='not_member'):
        delayed.append_batch('guest', token, [message('late')], idempotency_key='late')
    assert all(e['eventId'] != 'late' for e in repo.replay('owner', token)['events'])


def test_cleanup_retry_removes_legacy_orphan_invite_requests(service):
    repo, clock, _ = service
    token = repo.create_session('owner', 'create')['sessionToken']
    sid = repo.get_state('owner', token)['session']['sessionId']
    repo.delete_account('owner')
    # Simulate rows left by the previous cleanup implementation.
    with repo._connection(write=True) as db:
        db.execute('INSERT INTO collab_invite_requests VALUES (?, ?, ?, ?)',
                   (sid, 'owner', 'legacy', 'legacy-invite'))
    repo.delete_account('owner')
    with repo._connection() as db:
        assert db.execute('SELECT count(*) FROM collab_invite_requests').fetchone()[0] == 0


def test_state_returns_sequence_zero_membership_and_history_boundary(service):
    repo, clock, connect = service
    created = repo.create_session('owner', 'create')
    token = created['sessionToken']
    code = repo.create_invite('owner', token, max_uses=2)['inviteCode']
    member = repo.join('guest', token, code)
    repo.append('guest', token, message('before-leave'))
    repo.leave('guest', token)
    repo.join('guest', token, code)
    state = connect().get(f'/chat/{token}', headers=headers('guest')).json()
    assert state['member'] == member
    assert len(state['members']) == 2
    assert state['initialMembers'] == [created['member']]
    assert state['replayThroughSequence'] == 4
    page = connect().get(f'/chat/{token}/events', headers=headers('guest'),
                         params={'cursor': state['cursor']}).json()
    assert [e['eventSequence'] for e in page['events']] == [1, 2, 3, 4]
