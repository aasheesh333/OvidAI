import tempfile
import threading
import unittest

from server.collaboration.events import EventRejected
from server.collaboration.repository import (
    MAX_ACTIVE_MEMBERS, CollabError, CollabRepository)


class Clock:
    def __init__(self, now=1_800_000_000.0):
        self.now = now

    def __call__(self):
        return self.now


def message(event_id, text='hello'):
    return {'schemaVersion': 1, 'eventId': event_id, 'kind': 'message', 'payload': {'text': text}}


class Base(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = self.directory.name + '/collab.sqlite'
        self.clock = Clock()
        self.repo = CollabRepository(self.path, clock=self.clock)

    def assertError(self, code, fn, *args, **kwargs):
        with self.assertRaises(CollabError) as caught:
            fn(*args, **kwargs)
        self.assertEqual(caught.exception.code, code)
        return caught.exception

    def session(self, uid='owner', request_id='create-1'):
        created = self.repo.create_session(uid, request_id)
        return created['sessionToken'], created

    def invite(self, token, uid='owner', **kwargs):
        return self.repo.create_invite(uid, token, **kwargs)['inviteCode']

    def fill(self, token, count):
        """Join `count` participants (u1..uN) through one bounded invite."""
        code = self.invite(token, max_uses=9)
        return [self.repo.join(f'u{i}', token, code) for i in range(1, count + 1)]


class CreateTest(Base):
    def test_create_returns_opaque_token_owner_and_cursor(self):
        token, created = self.session()
        self.assertRegex(token, r'^[A-Za-z0-9_-]{43}$')  # 256-bit urlsafe
        self.assertEqual(created['session']['lifecycle'], 'active')
        self.assertEqual(created['session']['schemaVersion'], 1)
        self.assertEqual(created['member']['role'], 'owner')
        self.assertEqual(created['member']['status'], 'active')
        self.assertEqual(created['session']['ownerParticipantId'], created['member']['participantId'])
        self.assertNotEqual(created['session']['sessionId'], token)
        self.assertIsInstance(created['cursor'], str)

    def test_tokens_unique(self):
        self.assertNotEqual(self.session(request_id='a')[0], self.session(request_id='b')[0])

    def test_create_request_id_is_durable_idempotent(self):
        first = self.session()[1]
        again = CollabRepository(self.path, clock=self.clock).create_session('owner', 'create-1')
        self.assertEqual(first, again)

    def test_invalid_identity_and_request_id(self):
        self.assertError('invalid_identity', self.repo.create_session, '', 'r')
        self.assertError('invalid_identity', self.repo.create_session, None, 'r')
        self.assertError('invalid_request', self.repo.create_session, 'owner', 'bad id!')

    def test_memory_database_rejected(self):
        with self.assertRaises(ValueError):
            CollabRepository(':memory:')

    def test_state_lists_active_members_for_members_only(self):
        token, created = self.session()
        self.fill(token, 2)
        state = self.repo.get_state('u1', token)
        self.assertEqual(state['session'], created['session'])
        self.assertEqual(len(state['members']), 3)
        self.assertError('not_member', self.repo.get_state, 'stranger', token)
        self.assertError('session_not_found', self.repo.get_state, 'owner', 'x' * 43)


class InviteJoinTest(Base):
    def test_join_with_invite(self):
        token, _ = self.session()
        member = self.repo.join('alice', token, self.invite(token))
        self.assertEqual((member['role'], member['status']), ('participant', 'active'))

    def test_only_owner_invites(self):
        token, _ = self.session()
        self.fill(token, 1)
        self.assertError('not_owner', self.repo.create_invite, 'u1', token)
        self.assertError('not_member', self.repo.create_invite, 'stranger', token)

    def test_single_use_invite(self):
        token, _ = self.session()
        code = self.invite(token)
        self.repo.join('alice', token, code)
        self.assertError('invite_invalid', self.repo.join, 'bob', token, code)

    def test_bounded_multi_use_invite(self):
        token, _ = self.session()
        code = self.invite(token, max_uses=2)
        self.repo.join('a', token, code)
        self.repo.join('b', token, code)
        self.assertError('invite_invalid', self.repo.join, 'c', token, code)

    def test_invite_bounds(self):
        token, _ = self.session()
        for kwargs in [{'max_uses': 0}, {'max_uses': 10}, {'max_uses': True},
                       {'ttl_seconds': 0}, {'ttl_seconds': 8 * 86400}, {'ttl_seconds': float('nan')}]:
            with self.subTest(kwargs=kwargs):
                self.assertError('invalid_request', self.repo.create_invite, 'owner', token, **kwargs)

    def test_expired_invite(self):
        token, _ = self.session()
        code = self.invite(token, ttl_seconds=60)
        self.clock.now += 60
        self.assertError('invite_invalid', self.repo.join, 'alice', token, code)

    def test_revoked_invite(self):
        token, _ = self.session()
        created = self.repo.create_invite('owner', token)
        self.repo.revoke_invite('owner', token, created['inviteId'])
        self.assertError('invite_invalid', self.repo.join, 'alice', token, created['inviteCode'])

    def test_invite_for_other_session_rejected(self):
        token, _ = self.session(request_id='a')
        other, _ = self.session(request_id='b')
        self.assertError('invite_invalid', self.repo.join, 'alice', other, self.invite(token))

    def test_reconnect_does_not_consume_slot_or_invite(self):
        token, _ = self.session()
        code = self.invite(token, max_uses=2)
        first = self.repo.join('alice', token, code)
        self.assertEqual(self.repo.join('alice', token, code), first)
        self.repo.join('bob', token, code)  # second use still available
        self.assertEqual(len(self.repo.get_state('owner', token)['members']), 3)

    def test_owner_join_is_reconnect(self):
        token, created = self.session()
        self.assertEqual(self.repo.join('owner', token, 'whatever'), created['member'])

    def test_join_emits_membership_event(self):
        token, _ = self.session()
        member = self.repo.join('alice', token, self.invite(token))
        events = self.repo.replay('owner', token)['events']
        self.assertEqual(events[-1]['kind'], 'membership')
        self.assertEqual(events[-1]['payload'], {'action': 'joined', 'participantId':
                                                 member['participantId'], 'role': 'participant'})
        self.assertEqual(events[-1]['senderParticipantId'], member['participantId'])


class CapacityTest(Base):
    def test_tenth_member_ok_eleventh_rejected(self):
        token, _ = self.session()
        self.fill(token, 9)  # owner + 9 = 10
        self.assertEqual(len(self.repo.get_state('owner', token)['members']), MAX_ACTIVE_MEMBERS)
        code = self.invite(token)
        self.assertError('session_full', self.repo.join, 'u10', token, code)
        # Failed join consumed nothing: free a slot, the same invite works.
        member = self.repo.get_state('owner', token)['members'][-1]
        self.repo.revoke_member('owner', token, member['participantId'])
        self.repo.join('u10', token, code)

    def test_leave_frees_slot(self):
        token, _ = self.session()
        self.fill(token, 9)
        self.repo.leave('u1', token)
        self.repo.join('u10', token, self.invite(token))

    def test_concurrent_joins_never_exceed_capacity(self):
        token, _ = self.session()
        self.fill(token, 5)
        codes = [self.invite(token) for _ in range(12)]
        barrier = threading.Barrier(len(codes))
        results, lock = [], threading.Lock()

        def worker(i):
            repo = CollabRepository(self.path, clock=self.clock)  # own connections
            barrier.wait()
            try:
                repo.join(f'c{i}', token, codes[i])
                outcome = 'ok'
            except CollabError as error:
                outcome = error.code
            with lock:
                results.append(outcome)

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(len(codes))]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(results.count('ok'), 4)
        self.assertEqual(results.count('session_full'), 8)
        self.assertEqual(len(self.repo.get_state('owner', token)['members']), 10)

    def test_two_concurrent_boundary_joins_one_wins(self):
        token, _ = self.session()
        self.fill(token, 8)  # 9 active
        codes = [self.invite(token), self.invite(token)]
        barrier, results = threading.Barrier(2), []

        def worker(i):
            repo = CollabRepository(self.path, clock=self.clock)
            barrier.wait()
            try:
                repo.join(f'b{i}', token, codes[i])
                results.append('ok')
            except CollabError as error:
                results.append(error.code)

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(2)]
        [t.start() for t in threads]
        [t.join() for t in threads]
        self.assertEqual(sorted(results), ['ok', 'session_full'])


class RemovalTest(Base):
    def test_owner_cannot_be_removed_or_leave(self):
        token, created = self.session()
        self.fill(token, 1)
        owner_pid = created['member']['participantId']
        self.assertError('owner_not_removable', self.repo.revoke_member, 'owner', token, owner_pid)
        self.assertError('owner_not_removable', self.repo.leave, 'owner', token)
        self.assertError('not_owner', self.repo.revoke_member, 'u1', token, owner_pid)

    def test_exactly_one_owner(self):
        token, _ = self.session()
        self.fill(token, 3)
        roles = [m['role'] for m in self.repo.get_state('owner', token)['members']]
        self.assertEqual(roles.count('owner'), 1)

    def test_participant_cannot_revoke_others(self):
        token, _ = self.session()
        a, b = self.fill(token, 2)
        self.assertError('not_owner', self.repo.revoke_member, 'u1', token, b['participantId'])

    def test_revoke_unknown_participant(self):
        token, _ = self.session()
        self.assertError('member_not_found', self.repo.revoke_member, 'owner', token, 'nope')

    def test_revoked_cannot_rejoin_with_old_invite(self):
        token, _ = self.session()
        code = self.invite(token, max_uses=5)
        member = self.repo.join('alice', token, code)
        self.repo.revoke_member('owner', token, member['participantId'])
        self.assertError('membership_revoked', self.repo.join, 'alice', token, code)
        # An invitation issued before revocation is also old.
        self.assertError('membership_revoked', self.repo.join, 'alice', token, code)

    def test_revoked_can_rejoin_with_invite_issued_after_revocation(self):
        token, _ = self.session()
        member = self.repo.join('alice', token, self.invite(token))
        stale = self.invite(token)
        self.repo.revoke_member('owner', token, member['participantId'])
        self.assertError('membership_revoked', self.repo.join, 'alice', token, stale)
        again = self.repo.join('alice', token, self.invite(token))
        self.assertEqual(again['status'], 'active')

    def test_revoked_member_cannot_read_or_append(self):
        token, _ = self.session()
        member = self.repo.join('alice', token, self.invite(token))
        self.repo.revoke_member('owner', token, member['participantId'])
        self.assertError('not_member', self.repo.append, 'alice', token, message('e1'))
        self.assertError('not_member', self.repo.replay, 'alice', token)

    def test_left_member_cannot_read_but_can_rejoin(self):
        token, _ = self.session()
        self.repo.join('alice', token, self.invite(token))
        self.repo.leave('alice', token)
        self.assertError('not_member', self.repo.replay, 'alice', token)
        self.repo.join('alice', token, self.invite(token))
        self.repo.replay('alice', token)

    def test_revoke_and_leave_emit_membership_events(self):
        token, _ = self.session()
        a, b = self.fill(token, 2)
        self.repo.leave('u1', token)
        self.repo.revoke_member('owner', token, b['participantId'])
        payloads = [e['payload'] for e in self.repo.replay('owner', token)['events'][-2:]]
        self.assertEqual(payloads, [
            {'action': 'left', 'participantId': a['participantId'], 'role': None},
            {'action': 'revoked', 'participantId': b['participantId'], 'role': None}])


class AppendTest(Base):
    def test_append_returns_server_envelope(self):
        token, created = self.session()
        out = self.repo.append('owner', token, message('e1', 'hi'))
        self.assertEqual(set(out), {'schemaVersion', 'eventId', 'sessionId', 'eventSequence',
                                    'senderParticipantId', 'kind', 'createdAt', 'payload'})
        self.assertEqual(out['sessionId'], created['session']['sessionId'])
        self.assertEqual(out['senderParticipantId'], created['member']['participantId'])
        self.assertRegex(out['createdAt'], r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$')
        self.assertEqual(out['payload'], {'text': 'hi'})

    def test_duplicate_event_id_returns_original(self):
        token, _ = self.session()
        first = self.repo.append('owner', token, message('e1'))
        self.clock.now += 5
        again = CollabRepository(self.path, clock=self.clock).append('owner', token, message('e1'))
        self.assertEqual(first, again)
        self.assertEqual(len([e for e in self.repo.replay('owner', token)['events']
                              if e['kind'] == 'message']), 1)

    def test_duplicate_event_id_with_different_content_conflicts(self):
        token, _ = self.session()
        self.fill(token, 1)
        self.repo.append('owner', token, message('e1'))
        self.assertError('event_id_conflict', self.repo.append, 'owner', token, message('e1', 'other'))
        self.assertError('event_id_conflict', self.repo.append, 'u1', token, message('e1'))

    def test_validation_runs_before_persistence(self):
        token, _ = self.session()
        bad = {'schemaVersion': 1, 'eventId': 'e1', 'kind': 'toolCall', 'payload': {}}
        with self.assertRaises(EventRejected):
            self.repo.append('owner', token, bad)
        with self.assertRaises(EventRejected):
            self.repo.append('owner', token, dict(message('e2'), senderParticipantId='spoof'))
        self.assertEqual(self.repo.replay('owner', token)['events'], [])

    def test_non_member_cannot_append_or_read(self):
        token, _ = self.session()
        self.assertError('not_member', self.repo.append, 'stranger', token, message('e1'))
        self.assertError('not_member', self.repo.replay, 'stranger', token)

    def test_unknown_session(self):
        self.assertError('session_not_found', self.repo.append, 'owner', 'x' * 43, message('e1'))
        self.assertError('session_not_found', self.repo.replay, 'owner', 'bad token')

    def test_sequences_strictly_monotonic(self):
        token, _ = self.session()
        seqs = [self.repo.append('owner', token, message(f'e{i}'))['eventSequence'] for i in range(5)]
        self.assertEqual(seqs, sorted(set(seqs)))
        self.assertEqual(seqs, list(range(seqs[0], seqs[0] + 5)))

    def test_concurrent_appends_unique_contiguous_sequences(self):
        token, _ = self.session()
        self.fill(token, 3)
        users = ['owner', 'u1', 'u2', 'u3']
        barrier, seqs, lock = threading.Barrier(len(users)), [], threading.Lock()

        def worker(uid):
            repo = CollabRepository(self.path, clock=self.clock)
            barrier.wait()
            for i in range(10):
                out = repo.append(uid, token, message(f'{uid}-{i}'))
                with lock:
                    seqs.append(out['eventSequence'])

        threads = [threading.Thread(target=worker, args=(u,)) for u in users]
        [t.start() for t in threads]
        [t.join() for t in threads]
        self.assertEqual(len(seqs), 40)
        self.assertEqual(len(set(seqs)), 40)
        all_seqs = [e['eventSequence'] for e in self.repo.replay('owner', token, limit=100)['events']]
        self.assertEqual(all_seqs, list(range(1, len(all_seqs) + 1)))

    def test_closed_session_rejects_everything(self):
        token, _ = self.session()
        self.fill(token, 1)
        self.assertError('not_owner', self.repo.close, 'u1', token)
        self.repo.close('owner', token)
        self.repo.close('owner', token)  # idempotent
        self.assertError('session_closed', self.repo.append, 'owner', token, message('e1'))
        self.assertError('session_closed', self.repo.replay, 'u1', token)
        self.assertError('session_closed', self.repo.create_invite, 'owner', token)
        self.assertError('session_closed', self.repo.join, 'u9', token, 'code')
        self.assertError('session_closed', self.repo.get_state, 'owner', token)

    def test_server_kinds_cannot_be_appended(self):
        token, _ = self.session()
        body = {'schemaVersion': 1, 'eventId': 'e1', 'kind': 'system', 'payload': {'code': 'sessionClosed'}}
        with self.assertRaises(EventRejected):
            self.repo.append('owner', token, body)


class ReplayTest(Base):
    def setUp(self):
        super().setUp()
        self.token, _ = self.session()
        for i in range(25):
            self.repo.append('owner', self.token, message(f'e{i}', f'text {i}'))

    def drain(self, **kwargs):
        seen, cursor, pages = [], None, 0
        while True:
            page = self.repo.replay('owner', self.token, cursor, **kwargs)
            pages += 1
            seen.extend(e['eventSequence'] for e in page['events'])
            cursor = page['cursor']
            if not page['hasMore']:
                return seen, cursor, pages

    def test_pages_without_gaps_or_duplicates(self):
        seen, _, pages = self.drain(limit=10)
        self.assertEqual(seen, list(range(1, 26)))
        self.assertEqual(pages, 3)

    def test_cursor_resumes_after_new_events(self):
        _, cursor, _ = self.drain(limit=100)
        self.repo.append('owner', self.token, message('late'))
        page = self.repo.replay('owner', self.token, cursor)
        self.assertEqual([e['eventId'] for e in page['events']], ['late'])
        empty = self.repo.replay('owner', self.token, page['cursor'])
        self.assertEqual((empty['events'], empty['hasMore'], empty['cursor']), ([], False, page['cursor']))

    def test_byte_bounded_pages_always_progress(self):
        seen, _, pages = self.drain(limit=100, max_bytes=1)
        self.assertEqual(seen, list(range(1, 26)))
        self.assertEqual(pages, 25)

    def test_default_page_respects_256kib(self):
        _, cursor, _ = self.drain(limit=100)
        big = 'x' * (200 * 1024)
        for i in range(3):
            self.repo.append('owner', self.token, message(f'big{i}', big))
        # Two 200 KiB events exceed one 256 KiB page: one per page.
        for expected in ['big0', 'big1', 'big2']:
            page = self.repo.replay('owner', self.token, cursor, limit=100)
            self.assertEqual([e['eventId'] for e in page['events']], [expected])
            cursor = page['cursor']
        self.assertFalse(page['hasMore'])

    def test_limits_validated(self):
        for kwargs in [{'limit': 0}, {'limit': 101}, {'limit': True}, {'max_bytes': 0},
                       {'max_bytes': 256 * 1024 + 1}]:
            with self.subTest(kwargs=kwargs):
                self.assertError('invalid_request', self.repo.replay, 'owner', self.token, None, **kwargs)

    def test_malformed_or_foreign_cursor_requires_reset(self):
        other, _ = self.session(request_id='other')
        foreign = self.repo.replay('owner', other)['cursor']
        for cursor in ['garbage', '', 'djE6eDox', foreign, 'x' * 600, 5]:
            with self.subTest(cursor=cursor):
                self.assertError('cursor_reset', self.repo.replay, 'owner', self.token, cursor)

    def test_cursor_beyond_head_requires_reset(self):
        page = self.repo.replay('owner', self.token, None, limit=100)
        import base64
        sid, _ = base64.urlsafe_b64decode(page['cursor'] + '==').decode().rsplit(':', 1)
        forged = base64.urlsafe_b64encode(f'{sid}:999'.encode()).decode().rstrip('=')
        self.assertError('cursor_reset', self.repo.replay, 'owner', self.token, forged)


class AccountDeletionTest(Base):
    def test_deletion_removes_owned_sessions_and_memberships(self):
        token, _ = self.session('owner')
        other, _ = self.session('host', 'host-1')
        self.repo.join('owner', other, self.invite(other, 'host'))
        self.repo.append('owner', token, message('e1'))
        self.repo.delete_account('owner')
        self.repo.delete_account('owner')  # idempotent
        self.assertError('account_deleted', self.repo.replay, 'owner', token)
        # Owned session is gone for everyone (tombstoned).
        self.repo.create_session('guest', 'g')
        self.assertError('session_not_found', self.repo.replay, 'guest', token)
        # Membership in another session removed; host unaffected.
        members = self.repo.get_state('host', other)['members']
        self.assertEqual([m['role'] for m in members], ['owner'])
        last = self.repo.replay('host', other)['events'][-1]
        self.assertEqual((last['kind'], last['payload']['action']), ('membership', 'left'))
        with self.repo._connection() as db:
            for table in ('sessions', 'memberships', 'invites', 'events'):
                self.assertEqual(db.execute(
                    f'SELECT count(*) FROM {table} WHERE session_id IN '
                    '(SELECT session_id FROM deleted_sessions)').fetchone()[0], 0, table)
            self.assertEqual(db.execute(
                "SELECT count(*) FROM memberships WHERE uid='owner'").fetchone()[0], 0)

    def test_late_requests_rejected_after_deletion(self):
        token, _ = self.session('owner')
        other, _ = self.session('host', 'host-1')
        code = self.invite(other, 'host')
        self.repo.delete_account('owner')
        self.assertError('account_deleted', self.repo.create_session, 'owner', 'create-1')
        self.assertError('account_deleted', self.repo.create_session, 'owner', 'new')
        self.assertError('account_deleted', self.repo.join, 'owner', other, code)
        self.assertError('account_deleted', self.repo.append, 'owner', token, message('x'))
        self.assertError('account_deleted', self.repo.close, 'owner', token)

    def test_concurrent_join_and_delete_never_resurrects(self):
        other, _ = self.session('host', 'host-1')
        code = self.invite(other, 'host')
        barrier = threading.Barrier(2)

        def join():
            barrier.wait()
            try:
                CollabRepository(self.path, clock=self.clock).join('victim', other, code)
            except CollabError:
                pass

        def delete():
            barrier.wait()
            CollabRepository(self.path, clock=self.clock).delete_account('victim')

        threads = [threading.Thread(target=join), threading.Thread(target=delete)]
        [t.start() for t in threads]
        [t.join() for t in threads]
        with self.repo._connection() as db:
            self.assertEqual(db.execute(
                "SELECT count(*) FROM memberships WHERE uid='victim'").fetchone()[0], 0)


if __name__ == '__main__':
    unittest.main()
