"""Collaboration contract: 50-member cap, single sender, creator-paid storage."""
import threading
from contextlib import contextmanager

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from server.collaboration.api import router
from server.collaboration.repository import (
    MAX_ACTIVE_MEMBERS, MAX_INVITE_USES, CollabError, CollabRepository)
from server.collaboration.tests.test_repository import Clock, message


@contextmanager
def admission(claims):
    yield claims['uid']


CLAIMS = {'owner': {'uid': 'owner'}, 'guest': {'uid': 'guest'}}


@pytest.fixture
def service(tmp_path):
    clock = Clock()
    path = tmp_path / 'collab.sqlite'
    repo = CollabRepository(path, clock=clock)

    def connect():
        app = FastAPI()
        app.include_router(router(CollabRepository(path, clock=clock),
                                  lambda uid, check: CLAIMS.get(uid, {'uid': uid}),
                                  admission), prefix='/chat')
        return TestClient(app)
    return repo, clock, connect


def headers(uid='owner'):
    return {'Authorization': f'Bearer {uid}', 'X-Firebase-AppCheck': 'check'}


def body(key, **data):
    return {'schemaVersion': 1, 'idempotencyKey': key, **data}


def create(repo):
    return repo.create_session('owner', 'create')['sessionToken']


def fill(repo, token, count):
    """Join `count` participants through one bounded link invite."""
    code = repo.create_invite('owner', token, max_uses=MAX_INVITE_USES)['inviteCode']
    for i in range(count):
        repo.join(f'u{i}', token, code)
    return code


# ----------------------------------------------------------------------
# 50-member cap
# ----------------------------------------------------------------------

def test_fiftieth_member_ok_and_fifty_first_rejected_without_partial_insert(service):
    repo, _, _ = service
    token = create(repo)
    invite = fill(repo, token, MAX_ACTIVE_MEMBERS - 1)  # owner + 49

    assert len(repo.get_state('owner', token)['members']) == MAX_ACTIVE_MEMBERS

    with pytest.raises(CollabError) as caught:
        repo.join('overflow', token, invite)
    assert (caught.value.code, caught.value.status) == ('session_full', 409)

    # No partial insert: no membership, no join event, no invite use consumed.
    with repo._connection() as db:
        assert db.execute("SELECT count(*) FROM collab_memberships WHERE uid='overflow'").fetchone()[0] == 0
        assert db.execute("SELECT uses FROM collab_invites WHERE code_hash IS NOT NULL").fetchone()[0] == 49
        assert db.execute("SELECT count(*) FROM collab_events WHERE kind='membership'").fetchone()[0] == 49
    assert len(repo.get_state('owner', token)['members']) == MAX_ACTIVE_MEMBERS


def test_two_concurrent_joins_at_49_end_at_50_never_51(service):
    repo, _, _ = service
    token = create(repo)
    fill(repo, token, MAX_ACTIVE_MEMBERS - 2)  # 49 active, one seat
    codes = [repo.create_invite('owner', token)['inviteCode'] for _ in range(2)]
    barrier, results, lock = threading.Barrier(2), [], threading.Lock()

    def worker(i):
        other = CollabRepository(repo.path, clock=repo.clock)
        barrier.wait()
        try:
            other.join(f'racer{i}', token, codes[i])
            outcome = 'ok'
        except CollabError as error:
            outcome = error.code
        with lock:
            results.append(outcome)

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert sorted(results) == ['ok', 'session_full']
    assert len(repo.get_state('owner', token)['members']) == MAX_ACTIVE_MEMBERS


def test_http_cap_is_a_typed_409(service):
    repo, _, connect = service
    token = create(repo)
    invite = fill(repo, token, MAX_ACTIVE_MEMBERS - 1)
    response = connect().post(f'/chat/{token}/members', headers=headers('guest'),
                              json=body('join', invitationCode=invite))
    assert response.status_code == 409
    assert response.json()['code'] == 'session_full'


# ----------------------------------------------------------------------
# One sender at a time
# ----------------------------------------------------------------------

def test_turn_acquire_reject_send_and_release(service):
    repo, _, _ = service
    token = create(repo)
    repo.join('guest', token, repo.create_invite('owner', token)['inviteCode'])

    turn = repo.acquire_turn('owner', token)
    assert turn['mine'] is True
    assert turn['expiresAt'].endswith('Z')

    with pytest.raises(CollabError) as caught:
        repo.acquire_turn('guest', token)
    assert caught.value.code == 'turn_taken'

    # A second sender's send is rejected while the turn is held.
    with pytest.raises(CollabError) as caught:
        repo.append('guest', token, message('guest-send'))
    assert caught.value.code == 'turn_taken'
    assert [e['eventId'] for e in repo.replay('owner', token)['events']
            if e['kind'] == 'message'] == []

    # The holder may send; the turn stays held for the rest of the turn.
    repo.append('owner', token, message('owner-send'))
    state = repo.get_state('guest', token)
    assert state['turn']['participantId'] == turn['participantId']
    assert state['turn']['mine'] is False

    assert repo.release_turn('owner', token) == {'released': True}
    assert repo.release_turn('owner', token) == {'released': False}
    assert repo.get_state('owner', token)['turn'] is None

    repo.acquire_turn('guest', token)
    repo.append('guest', token, message('guest-send'))


def test_turn_expires_so_a_dead_sender_cannot_wedge_the_session(service):
    repo, clock, _ = service
    token = create(repo)
    repo.join('guest', token, repo.create_invite('owner', token)['inviteCode'])

    repo.acquire_turn('owner', token, ttl_seconds=5)
    clock.now += 5

    assert repo.get_state('guest', token)['turn'] is None
    turn = repo.acquire_turn('guest', token)
    assert turn['mine'] is True
    repo.append('guest', token, message('after-timeout'))


def test_turn_bounds_are_validated(service):
    repo, _, _ = service
    token = create(repo)
    for ttl in (0, -1, 601, True, 1.5):
        with pytest.raises(CollabError) as caught:
            repo.acquire_turn('owner', token, ttl_seconds=ttl)
        assert caught.value.code == 'invalid_request'


def test_send_lease_releases_on_complete(service):
    repo, _, _ = service
    token = create(repo)
    repo.join('guest', token, repo.create_invite('owner', token)['inviteCode'])

    # A send that does not request a turn claims and releases a short lease.
    repo.append('owner', token, message('first'))
    repo.append('guest', token, message('second'))
    assert repo.get_state('owner', token)['turn'] is None


def test_leave_revoke_and_close_release_the_turn(service):
    repo, _, _ = service
    token = create(repo)
    member = repo.join('guest', token, repo.create_invite('owner', token)['inviteCode'])

    repo.acquire_turn('guest', token)
    repo.leave('guest', token)
    repo.acquire_turn('owner', token)
    repo.release_turn('owner', token)

    repo.join('guest', token, repo.create_invite('owner', token)['inviteCode'])
    repo.acquire_turn('guest', token)
    repo.revoke_member('owner', token, member['participantId'])
    repo.acquire_turn('owner', token)

    repo.close('owner', token)
    with repo._connection() as db:
        assert db.execute('SELECT count(*) FROM collab_turns').fetchone()[0] == 0


def test_http_turn_lock_round_trip(service):
    repo, _, connect = service
    http = connect()
    token = create(repo)
    invite = repo.create_invite('owner', token)['inviteCode']
    repo.join('guest', token, invite)

    acquired = http.post(f'/chat/{token}/turn', headers=headers('owner'), json=body('turn-1'))
    assert acquired.status_code == 200
    assert acquired.json()['turn']['mine'] is True
    assert acquired.json()['turn']['expiresAt']

    taken = http.post(f'/chat/{token}/turn', headers=headers('guest'), json=body('turn-2'))
    assert taken.status_code == 409
    assert taken.json()['code'] == 'turn_taken'

    rejected = http.post(f'/chat/{token}/events', headers=headers('guest'),
                         json=body('send', events=[message('guest')]))
    assert rejected.status_code == 409
    assert rejected.json()['code'] == 'turn_taken'

    released = http.delete(f'/chat/{token}/turn', headers=headers('owner'))
    assert released.status_code == 200
    assert released.json()['released'] is True

    now_free = http.post(f'/chat/{token}/turn', headers=headers('guest'), json=body('turn-3'))
    assert now_free.status_code == 200
    sent = http.post(f'/chat/{token}/events', headers=headers('guest'),
                     json=body('send', events=[message('guest')]))
    assert sent.status_code == 200

    assert http.delete(f'/chat/{token}/turn', headers=headers('owner')).json()['released'] is False


# ----------------------------------------------------------------------
# Creator pays storage
# ----------------------------------------------------------------------

def test_member_upload_does_not_create_a_second_quota_row(service):
    repo, _, _ = service
    token = create(repo)
    repo.join('guest', token, repo.create_invite('owner', token)['inviteCode'])

    member_view = repo.record_upload('guest', token, file_id='file-member', size_bytes=100)
    assert member_view == {'ownerUid': 'owner', 'bytesUsed': 100, 'fileCount': 1,
                           'isCreator': False}
    creator_view = repo.record_upload('owner', token, file_id='file-owner', size_bytes=50)
    assert creator_view == {'ownerUid': 'owner', 'bytesUsed': 150, 'fileCount': 2,
                            'isCreator': True}
    assert repo.storage_usage('guest', token)['bytesUsed'] == 150

    with repo._connection() as db:
        rows = [dict(row) for row in db.execute('SELECT * FROM collab_storage_usage')]
        assert len(rows) == 1
        assert rows[0]['owner_uid'] == 'owner'
        assert (rows[0]['bytes'], rows[0]['files']) == (150, 2)
        uploaders = {r['file_id']: r['uploader_uid'] for r in
                     db.execute('SELECT * FROM collab_storage_files')}
        assert uploaders == {'file-member': 'guest', 'file-owner': 'owner'}


def test_storage_quota_is_per_creator_across_sessions(service):
    repo, _, _ = service
    first = create(repo)
    second = repo.create_session('owner', 'create-2')['sessionToken']
    for token, guest in ((first, 'guest-a'), (second, 'guest-b')):
        repo.join(guest, token, repo.create_invite('owner', token)['inviteCode'])
        repo.record_upload(guest, token, file_id=f'file-{guest}', size_bytes=10)

    with repo._connection() as db:
        assert db.execute('SELECT count(*) FROM collab_storage_usage').fetchone()[0] == 1
    assert repo.storage_usage('owner', second)['bytesUsed'] == 20


def test_upload_replay_and_conflict_are_atomic(service):
    repo, _, _ = service
    token = create(repo)
    repo.join('guest', token, repo.create_invite('owner', token)['inviteCode'])

    first = repo.record_upload('guest', token, file_id='same', size_bytes=10)
    assert repo.record_upload('guest', token, file_id='same', size_bytes=10) == first
    with pytest.raises(CollabError) as caught:
        repo.record_upload('guest', token, file_id='same', size_bytes=11)
    assert caught.value.code == 'file_conflict'
    with pytest.raises(CollabError) as caught:
        repo.record_upload('owner', token, file_id='same', size_bytes=10)
    assert caught.value.code == 'file_conflict'
    assert repo.storage_usage('owner', token)['bytesUsed'] == 10

    for kwargs in ({'file_id': '', 'size_bytes': 1},
                   {'file_id': 'bad id', 'size_bytes': 1},
                   {'file_id': 'ok', 'size_bytes': -1},
                   {'file_id': 'ok', 'size_bytes': True}):
        with pytest.raises(CollabError) as caught:
            repo.record_upload('guest', token, **kwargs)
        assert caught.value.code == 'invalid_request'


def test_non_member_cannot_upload_or_read_storage(service):
    repo, _, _ = service
    token = create(repo)
    with pytest.raises(CollabError) as caught:
        repo.record_upload('stranger', token, file_id='f', size_bytes=1)
    assert caught.value.code == 'not_member'
    with pytest.raises(CollabError) as caught:
        repo.storage_usage('stranger', token)
    assert caught.value.code == 'not_member'


def test_http_member_upload_is_attributed_to_creator(service):
    repo, _, connect = service
    http = connect()
    token = create(repo)
    invite = repo.create_invite('owner', token)['inviteCode']
    repo.join('guest', token, invite)

    uploaded = http.post(f'/chat/{token}/files', headers=headers('guest'),
                         json=body('upload', fileId='file-1', sizeBytes=2048))
    assert uploaded.status_code == 200
    assert uploaded.json()['storage'] == {'ownerUid': 'owner', 'bytesUsed': 2048,
                                          'fileCount': 1, 'isCreator': False}

    seen = http.get(f'/chat/{token}/storage', headers=headers('owner'))
    assert seen.status_code == 200
    assert seen.json()['storage']['ownerUid'] == 'owner'
    assert seen.json()['storage']['bytesUsed'] == 2048


def test_owner_deletion_releases_creator_storage_rows(service):
    repo, _, _ = service
    token = create(repo)
    repo.join('guest', token, repo.create_invite('owner', token)['inviteCode'])
    repo.record_upload('guest', token, file_id='f', size_bytes=10)
    repo.delete_account('owner')
    with repo._connection() as db:
        assert db.execute('SELECT count(*) FROM collab_storage_usage').fetchone()[0] == 0
        assert db.execute('SELECT count(*) FROM collab_storage_files').fetchone()[0] == 0
