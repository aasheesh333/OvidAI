"""Independent interpreter and contested-lock coverage for the PG authority."""
import multiprocessing
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor

import pytest

from server.collaboration.repository import CollabError
from server.collaboration.tests.test_postgres import pg_schema, pg, concurrent
from server.collaboration.tests.test_repository import Clock, message


def process_operation(arguments):
    from server.collaboration.postgres import PostgresCollabRepository
    dsn, schema, action, args, kwargs = arguments
    repo = PostgresCollabRepository(dsn=dsn, schema=schema, clock=Clock())
    try:
        return getattr(repo, action)(*args, **kwargs)
    except CollabError as error:
        return error.code


def test_independent_process_capacity_idempotency_and_signed_replay(pg):
    repo, _, _ = pg
    token = repo.create_session('owner', 'create')['sessionToken']
    codes = [repo.create_invite('owner', token)['inviteCode'] for _ in range(14)]
    args = [(repo._dsn, repo.schema, 'join', (f'guest{i}', token, code), {}) for i, code in enumerate(codes)]
    with ProcessPoolExecutor(max_workers=14, mp_context=multiprocessing.get_context('spawn')) as pool:
        results = list(pool.map(process_operation, args))
        assert sum(isinstance(r, dict) for r in results) == 9
        assert results.count('session_full') == 5
        args = [(repo._dsn, repo.schema, 'append_batch', ('owner', token, [message('same')]),
                 {'idempotency_key': 'same'})] * 14
        appended = list(pool.map(process_operation, args))
        assert all(result == appended[0] for result in appended)
    # All worker interpreters exited. A fresh process verifies the durable key.
    with ProcessPoolExecutor(max_workers=1, mp_context=multiprocessing.get_context('spawn')) as pool:
        page = pool.submit(process_operation, (repo._dsn, repo.schema, 'replay',
                           ('owner', token, appended[0]['nextCursor']), {})).result(timeout=30)
    assert page['events'] == []
    assert page['hasMore'] is False


def test_late_append_and_replay_admission_cannot_cross_rejoin(pg):
    from server.collaboration.postgres import PostgresCollabRepository
    repo, clock, _ = pg
    token = repo.create_session('owner', 'create')['sessionToken']
    code = repo.create_invite('owner', token, max_uses=9)['inviteCode']
    repo.join('guest', token, code)

    class Delayed(PostgresCollabRepository):
        def _admit_rate(self, *args):
            stamp = super()._admit_rate(*args)
            repo.leave('guest', token)
            repo.join('guest', token, code)
            return stamp

    delayed = Delayed(dsn=repo._dsn, schema=repo.schema, clock=clock)
    with pytest.raises(CollabError, match='not_member'):
        delayed.append('guest', token, message('late'))
    with pytest.raises(CollabError, match='cursor_reset'):
        delayed.replay('guest', token)
    assert all(e['eventId'] != 'late' for e in repo.replay('owner', token)['events'])


def test_parallel_owner_cleanup_with_overlapping_memberships(pg):
    repo, _, factory = pg
    tokens = [repo.create_session(f'u{i}', 'create')['sessionToken'] for i in range(6)]
    for i, token in enumerate(tokens):
        code = repo.create_invite(f'u{i}', token, max_uses=9)['inviteCode']
        for j in range(6):
            if i != j:
                repo.join(f'u{j}', token, code)
    concurrent(6, lambda i: factory().delete_account(f'u{i}'))
    with repo._connection() as db:
        for table in ('collab_sessions', 'collab_memberships', 'collab_events', 'collab_requests',
                      'collab_invites', 'collab_invite_requests', 'collab_rates'):
            assert db.execute(f'SELECT count(*) AS n FROM {table}').fetchone()['n'] == 0
        assert db.execute('SELECT count(*) AS n FROM deleted_accounts').fetchone()['n'] == 6


def test_session_lock_serializes_revocation_and_append(pg):
    repo, _, factory = pg
    created = repo.create_session('owner', 'create')
    token = created['sessionToken']
    guest = repo.join('guest', token, repo.create_invite('owner', token)['inviteCode'])
    # Hold a real row lock so a second authority cannot complete admission.
    with ThreadPoolExecutor(max_workers=1) as pool:
        with repo._transaction('owner') as db:
            session = repo._session(db, 'owner', token)
            pending = pool.submit(factory().append, 'guest', token, message('blocked'))
            generation = repo._bump_generation(db, session['session_id'])
            db.execute("UPDATE collab_memberships SET generation=%s WHERE session_id=%s", (generation, session['session_id']))
            db.execute("UPDATE collab_memberships SET status='revoked', revoked_generation=%s WHERE session_id=%s AND participant_id=%s",
                       (generation, session['session_id'], guest['participantId']))
            assert not pending.done()
        with pytest.raises(CollabError, match='not_member'):
            pending.result(timeout=20)
    assert repo.replay('owner', token)['events'][-1]['kind'] == 'membership'


def test_single_invite_use_is_atomic_across_different_uids(pg):
    repo, _, factory = pg
    token = repo.create_session('owner', 'create')['sessionToken']
    code = repo.create_invite('owner', token)['inviteCode']
    def join(i):
        try:
            return factory().join(f'u{i}', token, code)
        except CollabError as error:
            return error.code
    results = concurrent(12, join)
    assert sum(isinstance(r, dict) for r in results) == 1
    assert results.count('invite_invalid') == 11


def test_different_accounts_allocate_one_contiguous_session_sequence(pg):
    repo, _, factory = pg
    token = repo.create_session('owner', 'create')['sessionToken']
    code = repo.create_invite('owner', token, max_uses=9)['inviteCode']
    for i in range(8):
        repo.join(f'u{i}', token, code)
    def append(i):
        worker = factory()
        return [worker.append(f'u{i}', token, message(f'u{i}-{j}'))['eventSequence']
                for j in range(3)]
    results = concurrent(8, append)
    assert sorted(sequence for result in results for sequence in result) == list(range(9, 33))
    assert [e['eventSequence'] for e in factory().replay('owner', token)['events']] == list(range(1, 33))


@pytest.mark.parametrize('budget', ['rolling', 'requests', 'rate'])
def test_session_budgets_are_atomic_across_different_accounts(pg, monkeypatch, budget):
    from server.collaboration import repository as policy
    repo, _, factory = pg
    token = repo.create_session('owner', 'create')['sessionToken']
    code = repo.create_invite('owner', token, max_uses=2)['inviteCode']
    for i in range(2):
        repo.join(f'u{i}', token, code)
    expected = 'quota_exhausted'
    if budget == 'rolling':
        monkeypatch.setattr(policy, 'MAX_ROLLING_EVENTS', 3)  # two joins + one append
    elif budget == 'requests':
        monkeypatch.setattr(policy, 'MAX_REQUEST_RECORDS', 4)  # invite + two joins + one append
    else:
        for i in range(59):
            repo.append('owner', token, message(f'prior-{i}'))
        expected = 'rate_limited'
    def append(i):
        try:
            return factory().append(f'u{i}', token, message(f'contender-{i}'))
        except CollabError as error:
            return error.code
    results = concurrent(2, append)
    assert sum(isinstance(result, dict) for result in results) == 1
    assert results.count(expected) == 1
    assert sum(event['eventId'].startswith('contender-')
               for event in repo.replay('owner', token)['events']) == 1


def test_create_cleanup_race_cannot_recreate_deleted_account(pg):
    repo, _, factory = pg
    def operate(i):
        uid = f'victim{i // 2}'
        if i % 2:
            factory().delete_account(uid)
        else:
            try:
                factory().create_session(uid, 'create')
            except CollabError as error:
                assert error.code == 'account_deleted'
    concurrent(12, operate)
    with repo._connection() as db:
        assert db.execute('SELECT count(*) AS n FROM collab_sessions').fetchone()['n'] == 0
        assert db.execute('SELECT count(*) AS n FROM collab_memberships').fetchone()['n'] == 0
        assert db.execute('SELECT count(*) AS n FROM deleted_accounts').fetchone()['n'] == 6
