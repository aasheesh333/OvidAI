import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from server.shares.api import router
from server.shares.repository import ShareRepository, ShareError


class SharesTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = self.directory.name + '/shares.sqlite'
        self.repo = ShareRepository(self.path)

        def verify(token, attestation):
            if token not in ('alice', 'bob') or attestation != 'app':
                raise HTTPException(401)
            return token

        app = FastAPI()
        app.include_router(router(self.repo, verify, 'https://share.example.test'))
        self.client = TestClient(app)
        self.addCleanup(self.client.close)
        self.headers = {'Authorization': 'Bearer alice', 'X-Firebase-AppCheck': 'app'}
        self.body = {'session_id': 'session-1', 'request_id': 'request-1',
                     'messages': [{'role': 'user', 'content': 'Hello'},
                                  {'role': 'assistant', 'content': '<script>alert(1)</script> **hi**'}]}

    def create(self, **changes):
        return self.client.post('/shares', headers=self.headers, json=self.body | changes)

    def test_auth_and_owner_isolation(self):
        self.assertEqual(self.client.post('/shares', json=self.body).status_code, 401)
        self.assertEqual(self.create(owner_uid='bob').status_code, 422)
        share = self.create().json()
        bob = self.headers | {'Authorization': 'Bearer bob'}
        self.assertEqual(self.client.get('/shares', headers=bob).json(), {'shares': []})
        self.assertEqual(self.client.delete('/shares/' + share['id'], headers=bob).status_code, 404)
        self.assertEqual(len(self.client.get('/shares?session_id=session-1', headers=self.headers).json()['shares']), 1)
        self.assertEqual(self.client.get('/shares?session_id=other', headers=self.headers).json(), {'shares': []})

    def test_public_escape_no_cache_revoke_and_restart(self):
        share = self.create().json()
        self.assertRegex(share['id'], r'^[A-Za-z0-9_-]{43}$')
        self.assertEqual(share['url'], 'https://share.example.test/s/' + share['id'])
        page = self.client.get('/s/' + share['id'])
        tags = []
        class Parser(HTMLParser):
            def handle_starttag(self, tag, attrs):
                tags.append(tag)
        Parser().feed(page.text)
        self.assertNotIn('script', tags)
        self.assertIn('&lt;script&gt;', page.text)
        self.assertIn("default-src 'none'", page.headers['content-security-policy'])
        self.assertIn('noindex', page.headers['x-robots-tag'])
        self.assertIn('no-store', page.headers['cache-control'])
        reopened = ShareRepository(self.path)
        self.assertEqual(reopened.public(share['id'])['messages'][0]['content'], 'Hello')
        for _ in range(2):
            response = self.client.delete('/shares/' + share['id'], headers=self.headers)
            self.assertEqual(response.status_code, 204)
            self.assertIn('no-store', response.headers['cache-control'])
        gone = self.client.get('/s/' + share['id'])
        self.assertEqual(gone.status_code, 404)
        self.assertIn('no-store', gone.headers['cache-control'])
        self.assertIsNone(reopened.public(share['id']))
        self.assertEqual(self.create().status_code, 409)

    def test_immutable_idempotent_and_concurrent(self):
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: self.create().json(), range(4)))
        self.assertEqual(len({r['id'] for r in results}), 1)
        self.body['messages'][0]['content'] = 'Edited after sharing'
        self.assertEqual(self.create().status_code, 409)
        self.assertEqual(self.repo.public(results[0]['id'])['messages'][0]['content'], 'Hello')

    def test_owner_receipts_reconcile_lost_creation_without_public_request_metadata(self):
        share = self.create().json()
        self.assertEqual(share.get('request_id'), 'request-1')
        listed = self.client.get('/shares', headers=self.headers).json()['shares']
        self.assertEqual(listed[0].get('request_id'), 'request-1')
        self.assertNotIn('request-1', self.client.get('/s/' + share['id']).text)

    def test_revoke_and_expiry_cannot_bypass_durable_receipt_budget(self):
        clock = [100.0]
        repo = ShareRepository(self.path, clock=lambda: clock[0], ttl_seconds=10)
        for i in range(1000):
            receipt = repo.create('alice', self.body | {'request_id': f'request-{i}'})
            if i % 2:
                repo.revoke('alice', receipt['id'])
            else:
                clock[0] += 10
                repo.purge_expired()
        with self.assertRaises(ShareError) as blocked:
            repo.create('alice', self.body | {'request_id': 'over-budget'})
        self.assertEqual(blocked.exception.status, 429)
        with self.assertRaises(ShareError) as replay:
            repo.create('alice', self.body)
        self.assertEqual(replay.exception.status, 409)
        self.assertIsNotNone(repo.create('bob', self.body))

    def test_allowlist_rejects_payload_fields_and_filters_internal_text(self):
        for message in [
            {'role': 'tool', 'content': 'secret'},
            {'role': 'assistant', 'content': 'text', 'thinking': 'secret'},
            {'role': 'user', 'content': 'text', 'attachments': ['bytes']},
        ]:
            self.assertEqual(self.create(messages=[message]).status_code, 422)
        for content in ['<think>private</think>', '[report from subagent sub-1]\nprivate',
                        'Background subagent sub-1 (private task) finished\nIts closing message: private',
                        'Authorization: Bearer secret-value', 'data:image/png;base64,AAAA',
                        '<system-reminder>private</system-reminder>']:
            self.assertEqual(self.create(messages=[{'role': 'user', 'content': content}]).status_code, 422)

    def test_account_cleanup_fences_future_writes(self):
        share = self.create().json()
        self.repo.delete_account('alice')
        self.repo.delete_account('alice')
        self.assertIsNone(self.repo.public(share['id']))
        self.assertEqual(self.create(request_id='later').status_code, 403)
        self.assertEqual(self.client.get('/shares', headers=self.headers).json(), {'shares': []})

    def test_expiry_and_configuration(self):
        clock = [100.0]
        repo = ShareRepository(self.directory.name + '/expiry.sqlite', clock=lambda: clock[0], ttl_seconds=10)
        share = repo.create('alice', self.body)
        clock[0] = 110
        self.assertIsNone(repo.public(share['id']))
        repo.purge_expired()
        self.assertEqual(repo.list('alice'), [])
        with self.assertRaises(ValueError):
            router(repo, lambda *_: 'alice', '')

    def test_authenticated_fork_is_idempotent_and_preserves_snapshot(self):
        share = self.create().json()
        first = self.client.post('/shares/' + share['id'] + '/fork',
                                 headers=self.headers,
                                 json={'request_id': 'fork-1'})
        self.assertEqual(first.status_code, 201)
        self.assertRegex(first.json()['session_id'], r'^[A-Za-z0-9_-]{22}$')
        replay = self.client.post('/shares/' + share['id'] + '/fork',
                                  headers=self.headers,
                                  json={'request_id': 'fork-1'})
        self.assertEqual(replay.status_code, 201)
        self.assertEqual(replay.json(), first.json())
        self.assertEqual(set(first.json()), {'session_id'})
        self.assertEqual(self.repo.public(share['id'])['messages'][0]['content'], 'Hello')

    def test_fork_rejects_expired_revoked_and_invalid_owner_requests(self):
        clock = [100.0]
        repo = ShareRepository(self.directory.name + '/fork.sqlite', clock=lambda: clock[0], ttl_seconds=10)
        app = FastAPI()
        app.include_router(router(repo, lambda token, attestation: token, 'https://share.example.test'))
        with TestClient(app) as client:
            share = repo.create('alice', self.body)
            headers = {'Authorization': 'Bearer bob', 'X-Firebase-AppCheck': 'app'}
            response = client.post('/shares/' + share['id'] + '/fork', headers=headers,
                                   json={'request_id': 'fork-1'})
            self.assertEqual(response.status_code, 201)
            alice_response = client.post('/shares/' + share['id'] + '/fork',
                                         headers=headers | {'Authorization': 'Bearer alice'},
                                         json={'request_id': 'fork-1'})
            self.assertEqual(alice_response.status_code, 201)
            self.assertNotEqual(alice_response.json(), response.json())
            clock[0] = 110
            self.assertEqual(client.post('/shares/' + share['id'] + '/fork', headers=headers,
                                         json={'request_id': 'fork-2'}).status_code, 409)
            revoked = repo.create('alice', self.body | {'request_id': 'request-2'})
            repo.revoke('alice', revoked['id'])
            self.assertEqual(client.post('/shares/' + revoked['id'] + '/fork', headers=headers,
                                         json={'request_id': 'fork-3'}).status_code, 409)
            self.assertEqual(client.post('/shares/' + share['id'] + '/fork', headers=headers,
                                         json={'request_id': 'fork-1', 'secret': 'x'}).status_code, 422)

    def test_authentication_failures_and_validation_are_not_cached_or_echoed(self):
        for path in ['/shares', '/shares/unknown']:
            response = (self.client.get(path) if path == '/shares' else self.client.delete(path))
            self.assertEqual(response.status_code, 401)
            self.assertIn('private', response.headers['cache-control'])
        response = self.create(messages=[{'role': 'user', 'content': 'secret-value', 'secret': 'secret-value'}])
        self.assertEqual(response.status_code, 422)
        self.assertNotIn('secret-value', response.text)
        response = self.client.post('/shares', headers=self.headers, content=b' ' * 1500001)
        self.assertEqual(response.status_code, 413)

    def test_failed_transaction_and_wrong_uid_callback_do_not_publish(self):
        import sqlite3
        with sqlite3.connect(self.path) as db:
            db.execute("CREATE TRIGGER fail_insert BEFORE INSERT ON shares BEGIN SELECT RAISE(ABORT, 'disk failure'); END")
        self.assertEqual(self.create().status_code, 503)
        self.assertEqual(self.repo.list('alice'), [])
        with sqlite3.connect(self.path) as db:
            db.execute('DROP TRIGGER fail_insert')
        self.assertEqual(self.create().status_code, 201)
        app = FastAPI()
        app.include_router(router(self.repo, lambda *_: {'uid': 'bob'}, 'https://share.example.test'))
        with TestClient(app) as client:
            self.assertEqual(client.post('/shares', json=self.body, headers=self.headers).status_code, 401)


if __name__ == '__main__':
    unittest.main()
