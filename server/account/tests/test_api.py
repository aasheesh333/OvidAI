import unittest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from server.account.api import router
from server.account.domain import AccountError, Lifecycle
from test_lifecycle import Admin, Data, MemoryStore


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        self.now = 1000
        service = Lifecycle(self.store, Admin(), Data(), lambda: self.now)

        def verify(token, app_check, allow_disabled=False):
            if token != 'valid' or app_check != 'attested':
                raise AccountError('invalid_token', 401)
            return {'uid': 'alice', 'auth_time': self.now,
                    'firebase': {'sign_in_provider': 'password'}}

        app = FastAPI()
        app.include_router(router(service, verify))
        self.client = TestClient(app)
        self.headers = {'Authorization': 'Bearer valid', 'X-Firebase-AppCheck': 'attested'}

    def test_auth_required_and_uid_in_body_is_rejected(self):
        self.assertEqual(self.client.post('/account/deletion', json={
            'request_id': 'request-0001'}).status_code, 401)
        self.assertEqual(self.client.post('/account/deletion', headers=self.headers,
            json={'request_id': 'request-0001', 'uid': 'bob'}).status_code, 422)
        self.assertEqual(self.store.rows, {})

    def test_request_status_and_cancel_are_bound_to_verified_uid(self):
        response = self.client.post('/account/deletion', headers=self.headers,
                                    json={'request_id': 'request-0001'})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()['delete_after'], 87400)
        self.assertEqual(list(self.store.rows), ['alice'])
        self.assertEqual(self.client.get('/account/deletion', headers=self.headers)
                         .json()['state'], 'pending')
        self.now = 1001
        self.assertEqual(self.client.post('/account/login', headers=self.headers)
                         .json()['state'], 'cancelled')

    def test_missing_attestation_is_rejected(self):
        self.assertEqual(self.client.post('/account/login', headers={
            'Authorization': 'Bearer valid'}).status_code, 401)

    def test_no_public_finalize_endpoint(self):
        self.assertEqual(self.client.post('/account/finalize', headers=self.headers)
                         .status_code, 404)
