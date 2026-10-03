"""Shares boundary tests using real SQLite transactions and local ASGI requests."""

import copy
import sqlite3
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from html.parser import HTMLParser
from threading import Barrier, Event

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
from pydantic import ValidationError

from server.shares.api import router
from server.shares.repository import ShareError, ShareRepository
from server.shares.snapshot import CreateShare, ShareMessage


class WriteAttemptRepository(ShareRepository):
    """Signal transaction entry; SQLite still performs actual lock arbitration."""

    @contextmanager
    def _connection(self, *, write=False):
        if write:
            self.attempted.set()
        with super()._connection(write=write) as db:
            yield db


class ParallelSharesInvariants(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = directory.name + '/shares.sqlite'
        self.now = 100.0
        self.repo = ShareRepository(self.path, clock=lambda: self.now, ttl_seconds=10)
        self.body = {'session_id': 'session', 'request_id': 'request',
                     'messages': [{'role': 'user', 'content': 'Approved original'}]}

    def assert_share_error(self, code, operation):
        with self.assertRaises(ShareError) as caught:
            operation()
        self.assertEqual(caught.exception.code, code)

    def while_writer_locked(self, operation):
        repo = WriteAttemptRepository(self.path, clock=lambda: self.now, ttl_seconds=10)
        repo.attempted = Event()
        with ThreadPoolExecutor(max_workers=1) as pool:
            with sqlite3.connect(self.path) as lock:
                lock.execute('BEGIN IMMEDIATE')
                future = pool.submit(operation, repo)
                try:
                    self.assertTrue(repo.attempted.wait(5), 'worker did not attempt write')
                    self.now = 110.0
                finally:
                    lock.commit()
            return future.result(timeout=10)

    def test_expired_retry_waiting_for_write_lock_is_rejected(self):
        self.repo.create('alice', self.body)
        self.assert_share_error('request_already_used', lambda: self.while_writer_locked(
            lambda repo: repo.create('alice', self.body)))

    def test_new_snapshot_ttl_starts_after_write_lock_is_acquired(self):
        receipt = self.while_writer_locked(lambda repo: repo.create('alice', self.body))
        self.assertEqual(receipt['created_at'], 110.0)
        self.assertEqual(receipt['expires_at'], 120.0)
        self.assertIsNotNone(self.repo.public(receipt['id']))

    def test_purged_receipt_cannot_return_as_active_after_clock_rollback(self):
        receipt = self.repo.create('alice', self.body)
        self.now = 110.0
        self.repo.purge_expired()
        self.now = 105.0
        reopened = ShareRepository(self.path, clock=lambda: self.now, ttl_seconds=10)
        self.assertEqual(reopened.list('alice'), [])
        self.assertIsNone(reopened.public(receipt['id']))
        self.assert_share_error('request_already_used', lambda: reopened.create('alice', self.body))

    def test_mutated_validated_snapshot_is_revalidated_before_storage(self):
        body = CreateShare.model_validate(self.body)
        body.messages.append(ShareMessage.model_construct(role='system', content='Hidden context'))
        with self.assertRaises(ValidationError):
            self.repo.create('alice', body)
        self.assertEqual(self.repo.list('alice'), [])

    def test_constructed_private_message_is_revalidated_before_storage(self):
        body = self.body | {'messages': [ShareMessage.model_construct(
            role='assistant', content='Authorization: Bearer private-token')]}
        with self.assertRaises(ValidationError):
            self.repo.create('alice', body)
        self.assertEqual(self.repo.list('alice'), [])

    def test_nonfinite_ttl_cannot_publish_a_never_expiring_share(self):
        for ttl in [float('inf'), float('nan'), float('-inf')]:
            with self.subTest(ttl=ttl), self.assertRaises(ValueError):
                ShareRepository(self.path, ttl_seconds=ttl)

    def test_copy_is_immutable_across_input_and_output_mutations_and_restart(self):
        receipt = self.repo.create('alice', self.body)
        self.body['messages'][0]['content'] = 'Later edit'
        fetched = self.repo.public(receipt['id'])
        fetched['messages'][0]['content'] = 'Reader edit'
        reopened = ShareRepository(self.path, clock=lambda: self.now)
        self.assertEqual(reopened.public(receipt['id']), {
            'messages': [{'role': 'user', 'content': 'Approved original'}]})
        self.assert_share_error('request_already_used', lambda: reopened.create('alice', self.body))

    def test_conflicting_concurrent_requests_publish_exactly_one_snapshot(self):
        barrier = Barrier(2)
        bodies = [copy.deepcopy(self.body), self.body | {
            'messages': [{'role': 'assistant', 'content': 'Other approval'}]}]

        def publish(body):
            barrier.wait(timeout=5)
            try:
                return self.repo.create('alice', body)
            except ShareError as error:
                return error.code

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(publish, bodies))
        winners = [i for i, result in enumerate(results) if isinstance(result, dict)]
        self.assertEqual(len(winners), 1)
        winner = winners[0]
        self.assertEqual(results[1 - winner], 'request_already_used')
        self.assertEqual(self.repo.public(results[winner]['id']), {'messages': bodies[winner]['messages']})
        self.assertEqual(len(self.repo.list('alice')), 1)

    def test_same_request_and_session_are_independent_for_different_owners(self):
        alice = self.repo.create('alice', self.body)
        bob = self.repo.create('bob', self.body)
        self.assertNotEqual(alice['id'], bob['id'])
        self.assert_share_error('share_not_found', lambda: self.repo.revoke('bob', alice['id']))
        self.repo.delete_account('alice')
        self.assertEqual(self.repo.list('alice'), [])
        self.assertEqual(self.repo.list('bob'), [bob])
        self.assertIsNotNone(self.repo.public(bob['id']))

    def test_concurrent_quota_boundary_allows_only_one_new_receipt(self):
        # Seed only the already-existing quota population, never tested results;
        # one real SQLite transaction avoids 99 redundant setup fsyncs.
        with sqlite3.connect(self.path) as db:
            db.executemany('INSERT INTO shares VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)',
                           [(f'seed-{i}', 'alice', 'session', f'seed-{i}', 'seed',
                             '{"messages":[]}', 100.0, 110.0) for i in range(99)])
        barrier = Barrier(4)

        def publish(index):
            barrier.wait(timeout=5)
            try:
                return self.repo.create('alice', self.body | {'request_id': f'new-{index}'})
            except ShareError as error:
                return error.code

        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(publish, range(4)))
        self.assertEqual(sum(isinstance(value, dict) for value in results), 1)
        self.assertEqual(results.count('share_limit_reached'), 3)
        receipt = next(value for value in results if isinstance(value, dict))
        replay = self.body | {'request_id': receipt['request_id']}
        self.assertEqual(self.repo.create('alice', replay), receipt)
        self.repo.revoke('alice', receipt['id'])
        self.assertIsNotNone(self.repo.create('alice', self.body | {'request_id': 'after-revoke'}))

    def test_cleanup_racing_create_revoke_and_purge_never_restores_owner_data(self):
        receipt = self.repo.create('alice', self.body)
        bob = self.repo.create('bob', self.body)
        barrier = Barrier(4)

        def run(operation):
            barrier.wait(timeout=5)
            try:
                return operation()
            except ShareError as error:
                return error.code

        operations = [lambda: self.repo.create('alice', self.body | {'request_id': 'racing'}),
                      lambda: self.repo.revoke('alice', receipt['id']),
                      lambda: self.repo.delete_account('alice'), self.repo.purge_expired]
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(run, operations))
        self.assertTrue(isinstance(results[0], dict) or results[0] == 'account_deleted')
        self.assertIn(results[1], (None, 'share_not_found'))
        reopened = ShareRepository(self.path, clock=lambda: self.now)
        reopened.delete_account('alice')
        self.assertIsNone(reopened.public(receipt['id']))
        self.assertEqual(reopened.list('alice'), [])
        self.assert_share_error('account_deleted', lambda: reopened.create('alice', self.body))
        self.assertEqual(reopened.list('bob'), [bob])
        with sqlite3.connect(self.path) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM shares WHERE owner_uid=?',
                                        ('alice',)).fetchone()[0], 0)

    def test_concurrent_durable_quota_cannot_be_bypassed_by_revocation(self):
        with sqlite3.connect(self.path) as db:
            db.executemany('INSERT INTO shares VALUES (?, ?, ?, ?, ?, NULL, ?, ?, 1)',
                           [(f'seed-{i}', 'alice', 'session', f'seed-{i}', 'seed',
                             100.0, 110.0) for i in range(999)])
        barrier = Barrier(3)

        def publish(index):
            barrier.wait(timeout=5)
            try:
                receipt = self.repo.create('alice', self.body | {'request_id': f'last-{index}'})
                self.repo.revoke('alice', receipt['id'])
                return receipt
            except ShareError as error:
                return error.code

        with ThreadPoolExecutor(max_workers=3) as pool:
            results = list(pool.map(publish, range(3)))
        self.assertEqual(sum(isinstance(value, dict) for value in results), 1)
        self.assertEqual(results.count('share_storage_limit_reached'), 2)
        self.assertEqual(self.repo.list('alice'), [])
        self.assertIsNotNone(self.repo.create('bob', self.body))

    def test_revoke_racing_duplicate_never_republishes_and_retry_stays_terminal(self):
        receipt = self.repo.create('alice', self.body)
        barrier = Barrier(2)

        def replay():
            barrier.wait(timeout=5)
            try:
                return self.repo.create('alice', self.body)
            except ShareError as error:
                return error.code

        def revoke():
            barrier.wait(timeout=5)
            self.repo.revoke('alice', receipt['id'])

        with ThreadPoolExecutor(max_workers=2) as pool:
            replayed, revoked = pool.submit(replay), pool.submit(revoke)
            result = replayed.result(timeout=10)
            revoked.result(timeout=10)
        self.assertIn(result, (receipt, 'request_already_used'))
        self.assertIsNone(self.repo.public(receipt['id']))
        self.assertEqual(self.repo.list('alice'), [])
        self.assert_share_error('request_already_used', lambda: self.repo.create('alice', self.body))
        with sqlite3.connect(self.path) as db:
            self.assertEqual(db.execute('SELECT snapshot FROM shares WHERE token=?',
                                        (receipt['id'],)).fetchone(), (None,))

    def test_expiry_purge_preserves_fingerprint_for_conflicting_and_identical_retries(self):
        receipt = self.repo.create('alice', self.body)
        self.now = 110.0
        self.repo.purge_expired()
        self.repo.purge_expired()
        self.assertEqual(self.repo.list('alice'), [])
        self.assertIsNone(self.repo.public(receipt['id']))
        for body in (self.body, self.body | {'session_id': 'other-session'}):
            self.assert_share_error('request_already_used', lambda: self.repo.create('alice', body))
        with sqlite3.connect(self.path) as db:
            row = db.execute('SELECT snapshot, length(fingerprint) FROM shares WHERE token=?',
                             (receipt['id'],)).fetchone()
            self.assertEqual(row, (None, 64))

    def test_failed_cleanup_rolls_back_fence_and_can_be_retried(self):
        receipt = self.repo.create('alice', self.body)
        with sqlite3.connect(self.path) as db:
            db.execute("CREATE TRIGGER fail_cleanup BEFORE DELETE ON shares "
                       "BEGIN SELECT RAISE(ABORT, 'cleanup interrupted'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.repo.delete_account('alice')
        self.assertEqual(self.repo.create('alice', self.body), receipt)
        with sqlite3.connect(self.path) as db:
            db.execute('DROP TRIGGER fail_cleanup')
        self.repo.delete_account('alice')
        self.assertIsNone(self.repo.public(receipt['id']))
        self.assert_share_error('account_deleted', lambda: self.repo.create('alice', self.body))


class ParallelSharesViewer(unittest.TestCase):
    def setUp(self):
        ParallelSharesInvariants.setUp(self)

        def verify(token, attestation):
            if token not in ('alice', 'bob') or attestation != 'verified-app':
                raise HTTPException(401, 'invalid_authentication')
            return token

        app = FastAPI()
        app.include_router(router(self.repo, verify, 'https://shares.example.test/public'))
        self.client = TestClient(app)
        self.addCleanup(self.client.close)
        self.auth = {'Authorization': 'Bearer alice', 'X-Firebase-AppCheck': 'verified-app'}

    def test_hostile_content_is_literal_text_with_no_active_elements_or_resources(self):
        hostile = '</pre><script>alert(1)</script><img src="https://evil.test/pixel" onerror="x()">' \
                  '<svg onload="x()"><a href="javascript:x()">click</a></svg>' \
                  '<iframe srcdoc="bad"></iframe><style>@import "https://evil.test/css";</style>' \
                  '&lt;script&gt; **markdown** [link](https://evil.test)'
        response = self.client.post('/shares', headers=self.auth, json=self.body | {
            'messages': [{'role': 'assistant', 'content': hostile}]})
        self.assertEqual(response.status_code, 201)
        page = self.client.get('/s/' + response.json()['id'])
        self.assertEqual(page.status_code, 200)
        tags, attributes, text = [], [], []

        class Parser(HTMLParser):
            def handle_starttag(self, tag, attrs):
                tags.append(tag)
                attributes.extend(attrs)

            def handle_data(self, value):
                text.append(value)

        Parser().feed(page.text)
        self.assertFalse(set(tags) & {'script', 'img', 'svg', 'a', 'iframe', 'form', 'object'})
        self.assertFalse(any(key.startswith('on') or key in ('src', 'href', 'srcdoc')
                             for key, _ in attributes))
        self.assertIn(hostile, ''.join(text))
        self.assertIn("default-src 'none'", page.headers['content-security-policy'])
        self.assertIn("frame-ancestors 'none'", page.headers['content-security-policy'])
        self.assertIn('sandbox', page.headers['content-security-policy'])
        self.assertEqual(page.headers['referrer-policy'], 'no-referrer')

    def test_conditional_requests_cannot_serve_revoked_or_expired_content(self):
        for terminal in ('revoke', 'expiry', 'cleanup'):
            with self.subTest(terminal=terminal):
                self.now = 100.0
                response = self.client.post('/shares', headers=self.auth, json=self.body | {
                    'request_id': terminal})
                self.assertEqual(response.status_code, 201)
                token = response.json()['id']
                path = '/s/' + token
                page = self.client.get(path)
                self.assertEqual(page.status_code, 200)
                self.assertIn('no-store', page.headers['cache-control'])
                self.assertNotIn('etag', page.headers)
                self.assertNotIn('last-modified', page.headers)
                if terminal == 'revoke':
                    self.assertEqual(self.client.delete('/shares/' + token,
                                                        headers=self.auth).status_code, 204)
                elif terminal == 'expiry':
                    self.now = 110.0
                else:
                    self.repo.delete_account('alice')
                gone = self.client.get(path, headers={
                    'If-None-Match': '*', 'If-Modified-Since': 'Wed, 01 Jan 2099 00:00:00 GMT'})
                self.assertEqual(gone.status_code, 404)
                self.assertNotIn('Approved original', gone.text)
                self.assertIn('no-store', gone.headers['cache-control'])
                self.assertEqual(gone.text, self.client.get('/s/' + 'A' * 43).text)

    def test_anonymous_requests_cannot_enumerate_receipts_or_revoke(self):
        receipt = self.repo.create('alice', self.body)
        for response in [self.client.get('/shares'),
                         self.client.get('/shares?session_id=session'),
                         self.client.delete('/shares/' + receipt['id'])]:
            self.assertEqual(response.status_code, 401)
            self.assertNotIn(receipt['id'], response.text)
            self.assertIn('no-store', response.headers['cache-control'])
        bob = self.auth | {'Authorization': 'Bearer bob'}
        self.assertEqual(self.client.get('/shares', headers=bob).json(), {'shares': []})
        self.assertEqual(self.client.delete('/shares/' + receipt['id'], headers=bob).status_code, 404)
        self.assertEqual(self.client.get('/s/' + receipt['id']).status_code, 200)

    def test_configured_origin_and_public_snapshot_do_not_leak_owner_metadata(self):
        response = self.client.post('/shares', headers=self.auth | {
            'Host': 'evil.test', 'X-Forwarded-Host': 'evil.test'}, json=self.body)
        self.assertEqual(response.status_code, 201)
        receipt = response.json()
        self.assertEqual(receipt['url'], 'https://shares.example.test/public/s/' + receipt['id'])
        page = self.client.get('/s/' + receipt['id'])
        for private in ('alice', 'request', 'session'):
            self.assertNotIn(private, page.text)
        self.assertEqual(self.repo.public(receipt['id']), {
            'messages': [{'role': 'user', 'content': 'Approved original'}]})

    def test_rejected_secrets_and_byte_limit_leave_no_receipt_or_reflected_content(self):
        for messages in [
            [{'role': 'tool', 'content': 'hidden-tool-result'}],
            [{'role': 'user', 'content': 'ok', 'images': ['private-image']}],
            [{'role': 'assistant', 'content': 'api_key=private-value'}],
            [{'role': 'user', 'content': '😀' * 20000}] * 3,
        ]:
            response = self.client.post('/shares', headers=self.auth, json=self.body | {'messages': messages})
            self.assertEqual(response.status_code, 422)
            self.assertEqual(response.json(), {'detail': 'invalid_snapshot'})
            self.assertIn('no-store', response.headers['cache-control'])
        self.assertEqual(self.repo.list('alice'), [])
