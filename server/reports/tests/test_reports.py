import tempfile
import unittest

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from server.reports.api import router
from server.reports.repository import ReportError, ReportRepository


class ReportsTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.now = [1_000_000.0]
        self.repo = ReportRepository(self.directory.name + '/reports.sqlite',
                                     clock=lambda: self.now[0], daily_limit=3)

        def verify(token, attestation):
            if token not in ('alice', 'bob') or attestation != 'app':
                raise HTTPException(401)
            return token

        app = FastAPI()
        app.include_router(router(self.repo, verify))
        self.client = TestClient(app)
        self.addCleanup(self.client.close)
        self.headers = {'Authorization': 'Bearer alice', 'X-Firebase-AppCheck': 'app'}
        self.body = {'request_id': 'r' * 32, 'kind': 'ai_output', 'reason': 'hate',
                     'details': 'offensive', 'excerpt': 'bad reply', 'model': 'm1'}

    def post(self, headers=None, **changes):
        return self.client.post('/v1/reports', headers=self.headers if headers is None else headers,
                                json=self.body | changes)

    def test_requires_verified_identity(self):
        self.assertEqual(self.post(headers={}).status_code, 401)
        self.assertEqual(self.post(headers={'Authorization': 'Bearer alice'}).status_code, 401)

    def test_creates_and_replays_idempotently(self):
        first = self.post()
        self.assertEqual(first.status_code, 201)
        again = self.post()
        self.assertEqual(again.status_code, 200)
        self.assertEqual(again.json()['id'], first.json()['id'])
        queue = self.repo.open_reports()
        self.assertEqual(len(queue), 1)
        self.assertEqual(queue[0]['reason'], 'hate')
        self.assertNotIn('reporter_uid', queue[0])

    def test_rejects_unknown_fields_and_values(self):
        self.assertEqual(self.post(reporter_uid='bob').status_code, 422)
        self.assertEqual(self.post(kind='payment').status_code, 422)
        self.assertEqual(self.post(reason='nope').status_code, 422)
        self.assertEqual(self.post(excerpt='x' * 4001).status_code, 422)
        self.assertEqual(self.post(request_id='short').status_code, 422)

    def test_daily_limit_per_reporter(self):
        for index in range(3):
            self.assertEqual(self.post(request_id=f'{index}' * 20).status_code, 201)
        self.assertEqual(self.post(request_id='z' * 20).status_code, 429)
        bob = {'Authorization': 'Bearer bob', 'X-Firebase-AppCheck': 'app'}
        self.assertEqual(self.post(headers=bob, request_id='z' * 20).status_code, 201)
        self.now[0] += 86401
        self.assertEqual(self.post(request_id='y' * 20).status_code, 201)

    def test_resolve_retention_and_account_deletion(self):
        report_id = self.post().json()['id']
        self.repo.resolve(report_id, 'actioned')
        self.assertEqual(self.repo.open_reports(), [])
        with self.assertRaises(ReportError):
            self.repo.resolve(report_id, 'open')
        self.post(request_id='b' * 20)
        self.assertEqual(self.repo.delete_account('alice'), 2)
        self.post(request_id='c' * 20)
        self.now[0] += 181 * 86400
        self.assertEqual(self.repo.purge_expired(), 1)


if __name__ == '__main__':
    unittest.main()
